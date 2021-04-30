package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
	"sync"
)

var reImportFileTable = regexp.MustCompile(`/([a-z]+)\.json$`)

func initializePeersWithImport(localConfig *Config, waitGroupPeers *sync.WaitGroup, waitGroupInit *sync.WaitGroup, shutdownChannel chan bool, importFile string) (err error) {
	stat, err := os.Stat(importFile)
	if err != nil {
		return fmt.Errorf("cannot read %s: %s", importFile, err)
	}

	PeerMapLock.RLock()
	peerSize := len(PeerMapOrder)
	PeerMapLock.RUnlock()
	if peerSize > 0 {
		log.Warnf("reload from import file is not possible")
		return
	}

	var peers []*Peer
	switch mode := stat.Mode(); {
	case mode.IsDir():
		peers, err = importPeersFromDir(localConfig, waitGroupPeers, shutdownChannel, importFile)
	case mode.IsRegular():
		peers, err = importPeersFromTar(localConfig, waitGroupPeers, shutdownChannel, importFile)
	}
	if err != nil {
		return fmt.Errorf("import failed: %s", err)
	}

	PeerMapNew := make(map[string]*Peer)
	PeerMapOrderNew := make([]string, 0)
	for i := range peers {
		p := peers[i]

		// finish peer import
		err = p.data.SetReferences()
		if err != nil {
			return fmt.Errorf("failed to set references: %s", err)
		}

		PeerMapNew[p.ID] = p
		PeerMapOrderNew = append(PeerMapOrderNew, p.ID)
	}

	PeerMapLock.Lock()
	PeerMapOrder = PeerMapOrderNew
	PeerMap = PeerMapNew
	PeerMapLock.Unlock()

	nodeAccessor = NewNodes(localConfig, []string{}, "", waitGroupInit, shutdownChannel)
	return
}

func importPeersFromDir(localConfig *Config, waitGroupPeers *sync.WaitGroup, shutdownChannel chan bool, folder string) (peers []*Peer, err error) {
	// TODO: implement
	return
}

func importPeersFromTar(localConfig *Config, waitGroupPeers *sync.WaitGroup, shutdownChannel chan bool, tarFile string) (peers []*Peer, err error) {
	f, err := os.Open(tarFile)
	if err != nil {
		err = fmt.Errorf("cannot read %s: %s", tarFile, err)
		return
	}
	defer f.Close()

	gzf, err := gzip.NewReader(f)
	if err != nil {
		err = fmt.Errorf("gzip error %s: %s", tarFile, err)
		return
	}

	tarReader := tar.NewReader(gzf)
	for {
		header, err := tarReader.Next()

		if err == io.EOF {
			break
		}

		if err != nil {
			return nil, fmt.Errorf("gzip/tarball error %s: %s", tarFile, err)
		}

		switch header.Typeflag {
		case tar.TypeDir:
		case tar.TypeReg:
			peers, err = importPeerFromTar(peers, header, tarReader, localConfig, waitGroupPeers, shutdownChannel)
			if err != nil {
				return nil, fmt.Errorf("gzip/tarball error %s in file %s: %s", tarFile, header.Name, err)
			}
		default:
			return nil, fmt.Errorf("gzip/tarball error %s: unsupported type in file %s: %c", tarFile, header.Name, header.Typeflag)
		}
	}

	return
}

func importPeerFromTar(peers []*Peer, header *tar.Header, tarReader io.Reader, localConfig *Config, waitGroupPeers *sync.WaitGroup, shutdownChannel chan bool) ([]*Peer, error) {
	filename := header.Name
	log.Debugf("reading %s", filename)
	matches := reImportFileTable.FindStringSubmatch(filename)
	if len(matches) != 2 {
		log.Warnf("no idea what to do with file: %s", filename)
	}
	table, rows, columns, err := importTarFile(matches[1], tarReader, header.Size)
	if err != nil {
		return peers, fmt.Errorf("import error: %s", err)
	}
	colIndex := make(map[string]int)
	for i, col := range columns {
		colIndex[col.Name] = i
	}
	var p *Peer
	if len(peers) > 0 {
		p = peers[len(peers)-1]
	}
	if table.Name == TableSites {
		if len(rows) != 1 {
			return peers, fmt.Errorf("wrong number of site rows in %s, expected 1 but got: %d", filename, len(rows))
		}

		// new peer export starting
		con := &Connection{
			Name:    interface2stringNoDedup(rows[0][colIndex["peer_name"]]),
			ID:      interface2stringNoDedup(rows[0][colIndex["peer_key"]]),
			Source:  []string{interface2stringNoDedup(rows[0][colIndex["addr"]])},
			Section: interface2stringNoDedup(rows[0][colIndex["section"]]),
			Flags:   interface2stringlist(rows[0][colIndex["flags"]]),
		}
		p = NewPeer(localConfig, con, waitGroupPeers, shutdownChannel)
		peers = append(peers, p)
		log.Infof("restoring peer %s (%s) from %s", p.Name, p.ID, strings.Replace(filename, "sites.json", "*.json", 1))

		p.Status[PeerState] = PeerStatus(interface2int(rows[0][colIndex["status"]]))
		p.Status[LastUpdate] = interface2int64(rows[0][colIndex["last_update"]])
		p.Status[LastError] = interface2stringNoDedup(rows[0][colIndex["last_error"]])
		p.Status[LastOnline] = interface2int64(rows[0][colIndex["last_online"]])
		p.Status[Queries] = interface2int64(rows[0][colIndex["queries"]])
		p.Status[ResponseTime] = interface2float64(rows[0][colIndex["response_time"]])
		p.data = NewDataStoreSet(p)
	}
	if table.Virtual != nil {
		return peers, nil
	}
	if p != nil && p.isOnline() {
		store := NewDataStore(table, p)
		store.DataSet = p.data
		err = store.InsertData(rows, columns, false)
		if err != nil {
			return peers, fmt.Errorf("failed to insert data: %s", err)
		}
		p.data.Set(table.Name, store)
	}
	return peers, nil
}

func importTarFile(tableName string, tarReader io.Reader, size int64) (table *Table, rows ResultSet, columns ColumnList, err error) {
	for _, t := range Objects.Tables {
		if strings.EqualFold(t.Name.String(), tableName) {
			table = t
		}
	}
	if table == nil {
		err = fmt.Errorf("no table found by name: %s", tableName)
		return
	}
	data := make([]byte, 0, size)
	buf := bytes.NewBuffer(data)
	read, err := io.Copy(buf, tarReader)
	if err != nil && !errors.Is(err, io.EOF) {
		err = fmt.Errorf("read error: %s", err)
		return
	}
	if read != size {
		err = fmt.Errorf("expected size %d but got %d", size, read)
		return
	}
	rows, err = NewResultSet(buf.Bytes())
	if err != nil {
		err = fmt.Errorf("parse error: %s", err)
		return
	}
	if len(rows) == 0 {
		err = fmt.Errorf("missing column header")
		return
	}
	columnRow := rows[0]
	rows = rows[1:]
	for i := range columnRow {
		col := table.GetColumn(interface2stringNoDedup(columnRow[i]))
		if col == nil {
			err = fmt.Errorf("no column found by name: %s", columnRow[i])
			return
		}
		columns = append(columns, col)
	}
	return
}

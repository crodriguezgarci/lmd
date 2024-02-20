#!/usr/bin/make -f

LAMPDDIR=lmd
MAKE:=make
SHELL:=bash
GOVERSION:=$(shell \
    go version | \
    awk -F'go| ' '{ split($$5, a, /\./); printf ("%04d%04d", a[1], a[2]); exit; }' \
)
# also update README.md when changing minumum version
MINGOVERSION:=00010021
MINGOVERSIONSTR:=1.21
BUILD:=$(shell git rev-parse --short HEAD)
# see https://github.com/go-modules-by-example/index/blob/master/010_tools/README.md
# and https://github.com/golang/go/wiki/Modules#how-can-i-track-tool-dependencies-for-a-module
TOOLSFOLDER=$(shell pwd)/tools
export GOBIN := $(TOOLSFOLDER)
export PATH := $(GOBIN):$(PATH)
GO=go

all: build

tools: versioncheck vendor dump
	$(GO) mod download
	set -e; for DEP in $(shell grep "_ " buildtools/tools.go | awk '{ print $$2 }'); do \
		( cd buildtools && $(GO) install $$DEP ) ; \
	done
	$(GO) mod tidy
	( cd buildtools && $(GO) mod tidy )
	# pin these dependencies
	( cd buildtools && $(GO) get github.com/golangci/golangci-lint@latest )
	$(GO) mod vendor

updatedeps: versioncheck
	$(MAKE) clean
	$(MAKE) tools
	$(GO) mod download
	set -e; for DEP in $(shell grep "_ " buildtools/tools.go | awk '{ print $$2 }'); do \
		( cd buildtools && $(GO) get $$DEP ) ; \
	done
	( cd buildtools && $(GO) get -u )
	$(GO) mod download
	$(GO) get -u ./...
	$(GO) get -t -u ./...
	$(MAKE) cleandeps

cleandeps:
	$(GO) mod tidy
	( cd buildtools && $(GO) mod tidy )

vendor:
	$(GO) mod download
	$(GO) mod tidy
	$(GO) mod vendor

dump:
	if [ $(shell grep -r Dump $(LAMPDDIR)/*.go | grep -v $(LAMPDDIR)/dump.go | grep -v httputil | wc -l) -ne 0 ]; then \
		sed -i.bak -e 's/\/\/go:build.*/\/\/ :build with debug functions/' -e 's/\/\/ +build.*/\/\/ build with debug functions/' $(LAMPDDIR)/dump.go; \
	else \
		sed -i.bak -e 's/\/\/ :build.*/\/\/go:build ignore/' -e 's/\/\/ build.*/\/\/ +build ignore/' $(LAMPDDIR)/dump.go; \
	fi
	rm -f $(LAMPDDIR)/dump.go.bak

build: vendor
	cd $(LAMPDDIR) && go build -ldflags "-s -w -X main.Build=$(BUILD)"

# run build watch, ex. with tracing: make build-watch -- -vv
build-watch: vendor
	ls $(LAMPDDIR)/*.go | entr -sr "$(MAKE) && ./lmd/lmd $(filter-out $@,$(MAKECMDGOALS))"

# run build watch with other build targets, ex.: make build-watch-make -- build-windows-amd64
build-watch-make: vendor
	ls $(LAMPDDIR)/*.go | entr -sr "$(MAKE) $(filter-out $@,$(MAKECMDGOALS))"

build-linux-amd64: vendor
	cd $(LAMPDDIR) && GOOS=linux GOARCH=amd64 go build -ldflags "-s -w -X main.Build=$(BUILD)" -o lmd.linux.amd64

debugbuild: fmt dump vendor
	cd $(LAMPDDIR) && go build -race -ldflags "-X main.Build=$(BUILD)" -gcflags "-d=checkptr=0"

devbuild: debugbuild

test: vendor
	cd $(LAMPDDIR) && go test -timeout 300s -short -v | ../t/test_counter.sh
	rm -f lmd/mock*.sock
	if grep -rn TODO: lmd/; then exit 1; fi
	if grep -rn Dump lmd/*.go | grep -v dump.go | grep -v httputil; then exit 1; fi

# test with filter
testf: vendor
	cd $(LAMPDDIR) && go test -v -timeout 300s -run "$(filter-out $@,$(MAKECMDGOALS))"

longtest: vendor
	cd $(LAMPDDIR) && go test -timeout 300s -v | ../t/test_counter.sh
	rm -f lmd/mock*.sock

citest: vendor
	rm -f lmd/mock*.sock
	#
	# Checking gofmt errors
	#
	if [ $$(cd $(LAMPDDIR) && gofmt -s -l . | wc -l) -gt 0 ]; then \
		echo "found format errors in these files:"; \
		cd $(LAMPDDIR) && gofmt -s -l .; \
		exit 1; \
	fi
	#
	# Checking TODO items
	#
	if grep -rn TODO: lmd/; then exit 1; fi
	#
	# Checking remaining debug calls
	#
	if grep -rn Dump lmd/*.go | grep -v dump.go | grep -v httputil; then exit 1; fi
	#
	# Run other subtests
	#
	$(MAKE) golangci
	-$(MAKE) govulncheck
	$(MAKE) fmt
	#
	# Normal test cases
	#
	cd $(LAMPDDIR) && go test -timeout 300s -v | ../t/test_counter.sh
	#
	# Benchmark tests
	#
	cd $(LAMPDDIR) && go test -timeout 300s -v -bench=B\* -run=^$$ . -benchmem
	#
	# Race rondition tests
	#
	$(MAKE) racetest
	#
	# All CI tests successfull
	#
	go mod tidy

benchmark: fmt
	cd $(LAMPDDIR) && go test -timeout 300s -ldflags "-s -w -X main.Build=$(BUILD)" -v -bench=B\* -benchtime 10s -run=^$$ . -benchmem

racetest: fmt
	cd $(LAMPDDIR) && go test -timeout 300s -race -short -v -gcflags "-d=checkptr=0"

covertest: fmt
	cd $(LAMPDDIR) && go test -timeout 300s -v -coverprofile=cover.out
	cd $(LAMPDDIR) && go tool cover -func=cover.out
	cd $(LAMPDDIR) && go tool cover -html=cover.out -o coverage.html

coverweb: fmt
	cd $(LAMPDDIR) && go test -timeout 300s -v -coverprofile=cover.out
	cd $(LAMPDDIR) && go tool cover -html=cover.out

clean:
	rm -f $(LAMPDDIR)/lmd
	rm -f $(LAMPDDIR)/cover.out
	rm -f $(LAMPDDIR)/coverage.html
	rm -f $(LAMPDDIR)/*.sock
	rm -f lmd-*.html
	rm -rf vendor
	rm -rf $(TOOLSFOLDER)

GOVET=go vet -all
fmt: generate tools
	cd $(LAMPDDIR) && gofmt -w -s *.go .
	cd $(LAMPDDIR) && ./tools/gofumpt -w .
	cd $(LAMPDDIR) && ./tools/gci write . --skip-generated
	cd $(LAMPDDIR) && goimports -w .

generate: tools
	cd $(LAMPDDIR) && go generate

versioncheck:
	@[ $$( printf '%s\n' $(GOVERSION) $(MINGOVERSION) | sort | head -n 1 ) = $(MINGOVERSION) ] || { \
		echo "**** ERROR:"; \
		echo "**** LMD requires at least golang version $(MINGOVERSIONSTR) or higher"; \
		echo "**** this is: $$(go version)"; \
		exit 1; \
	}

golangci: tools
	#
	# golangci combines a few static code analyzer
	# See https://github.com/golangci/golangci-lint
	#
	golangci-lint run $(LAMPDDIR)/...

govulncheck: tools
	govulncheck ./...

version:
	OLDVERSION="$(shell grep "VERSION =" $(LAMPDDIR)/main.go | awk '{print $$3}' | tr -d '"')"; \
	NEWVERSION=$$(dialog --stdout --inputbox "New Version:" 0 0 "v$$OLDVERSION") && \
		NEWVERSION=$$(echo $$NEWVERSION | sed "s/^v//g"); \
		if [ "v$$OLDVERSION" = "v$$NEWVERSION" -o "x$$NEWVERSION" = "x" ]; then echo "no changes"; exit 1; fi; \
		sed -i -e 's/VERSION =.*/VERSION = "'$$NEWVERSION'"/g' $(LAMPDDIR)/main.go

zip: clean
	CGO_ENABLED=0 $(MAKE) build
	VERSION="$(shell grep "VERSION =" $(LAMPDDIR)/main.go | awk '{print $$3}' | tr -d '"')"; \
		COMMITS="$(shell git rev-list $$(git describe --tags --abbrev=0)..HEAD --count)"; \
		DATE="$(shell LC_TIME=C date +%Y-%m-%d)"; \
		FILE="$$(printf "%s+git~%03d~%s_%s" $${VERSION} $${COMMITS} $(BUILD) $${DATE})"; \
		rm -f lmd-$$FILE.gz; \
		mv lmd/lmd lmd-$$FILE; \
		gzip -9 lmd-$$FILE; \
		ls -la lmd-$$FILE.gz; \
		echo "lmd-$$FILE.gz created";

// Code generated by "stringer -type=DataType"; DO NOT EDIT.

package main

import "strconv"

func _() {
	// An "invalid array index" compiler error signifies that the constant values have changed.
	// Re-run the stringer command to generate them again.
	var x [1]struct{}
	_ = x[StringCol-1]
	_ = x[StringListCol-2]
	_ = x[IntCol-3]
	_ = x[IntListCol-4]
	_ = x[Int64Col-5]
	_ = x[FloatCol-6]
	_ = x[HashMapCol-7]
	_ = x[CustomVarCol-8]
	_ = x[ServiceMemberListCol-9]
	_ = x[InterfaceListCol-10]
	_ = x[StringLargeCol-11]
}

const _DataType_name = "StringColStringListColIntColIntListColInt64ColFloatColHashMapColCustomVarColServiceMemberListColInterfaceListColStringLargeCol"

var _DataType_index = [...]uint8{0, 9, 22, 28, 38, 46, 54, 64, 76, 96, 112, 126}

func (i DataType) String() string {
	i -= 1
	if i >= DataType(len(_DataType_index)-1) {
		return "DataType(" + strconv.FormatInt(int64(i+1), 10) + ")"
	}
	return _DataType_name[_DataType_index[i]:_DataType_index[i+1]]
}

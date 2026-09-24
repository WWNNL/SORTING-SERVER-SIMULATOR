class_name PyObjects
extends RefCounted
## 虚拟服务器上 Python 子集的运行时值对象。
##
## 这里刻意用独立类而不是裸 Array：目标数组的每一次读写下标都要被记录下来
## 去驱动左侧可视化，而裸 Array 在 GDScript 里没法可靠地按引用比对
## （`==` 比较的是内容）。


## 列表 / 数组。排序的目标数组就是它。
class PyList extends RefCounted:
	var items: Array = []
	var is_target := false  ## 本次运行的目标数组，读写会被埋点记录

	func _init(vals: Array = []) -> void:
		items = vals

	func size() -> int:
		return items.size()

	func text() -> String:
		var parts := PackedStringArray()
		for v in items:
			parts.append(PyObjects.repr(v))
		return "[" + ", ".join(parts) + "]"


## range() 的返回值。惰性区间，不占内存槽。
class PyRange extends RefCounted:
	var start := 0
	var stop := 0
	var step := 1

	func _init(s := 0, e := 0, st := 1) -> void:
		start = s
		stop = e
		step = st

	func size() -> int:
		if step == 0:
			return 0
		if step > 0:
			return maxi(0, (stop - start + step - 1) / step)
		return maxi(0, (start - stop - step - 1) / -step)

	func text() -> String:
		return "range(%d, %d, %d)" % [start, stop, step]


## 用户定义的函数。code 是已编译好的指令数组。
class PyFunc extends RefCounted:
	var name := ""
	var params := PackedStringArray()
	var code: Array = []
	var line := 0

	func _init(n := "", p := PackedStringArray(), c: Array = [], l := 0) -> void:
		name = n
		params = p
		code = c
		line = l

	func text() -> String:
		return "<函数 %s>" % name


## 内置函数引用（len/range/...）。只作为值存在，调用时由 VM 派发。
class PyBuiltin extends RefCounted:
	var name := ""

	func _init(n := "") -> void:
		name = n

	func text() -> String:
		return "<内置函数 %s>" % name


## 统一的字符串表示，用于控制台输出与错误信息。
static func repr(v: Variant) -> String:
	if v == null:
		return "None"
	if v is bool:
		return "True" if v else "False"
	if v is PyList:
		return v.text()
	if v is PyRange:
		return v.text()
	if v is PyFunc:
		return v.text()
	if v is PyBuiltin:
		return v.text()
	if v is float:
		if absf(v) < 1e15 and is_equal_approx(v, roundf(v)):
			return str(int(v))
		return str(v)
	if v is Array:
		var parts := PackedStringArray()
		for e in v:
			parts.append(repr(e))
		return "[" + ", ".join(parts) + "]"
	return str(v)


## 真值判定，对齐 Python 语义。
static func truthy(v: Variant) -> bool:
	if v == null:
		return false
	if v is bool:
		return v
	if v is int:
		return v != 0
	if v is float:
		return v != 0.0
	if v is String:
		return not (v as String).is_empty()
	if v is PyList:
		return not v.items.is_empty()
	if v is PyRange:
		return v.size() > 0
	if v is Array:
		return not (v as Array).is_empty()
	return true

class_name PyCompiler
extends RefCounted
## AST -> 线性指令序列。
##
## 编译成扁平指令而不是直接树遍历求值，是为了让"暂停/单步/限速"变得自然：
## CPU 速度就是每秒执行多少条指令，暂停就是停止取指，完全对得上游戏设定。

var code: Array = []
var functions: Dictionary = {}
var errors: Array = []
var failed := false

var _loops: Array = []
var _temp_top := 0


func compile(ast: Dictionary) -> Dictionary:
	code = []
	functions = {}
	errors = []
	failed = false
	_loops = []
	_temp_top = 0

	_body(ast["body"])
	if not failed:
		_e("HALT", null, null, 0)

	return {"ok": not failed, "code": code, "functions": functions, "errors": errors}


# ---------------------------------------------------------------- 语句

func _body(stmts: Array) -> void:
	for s in stmts:
		if failed:
			return
		_stmt(s)


func _stmt(n: Dictionary) -> void:
	if failed:
		return
	var line: int = n.get("line", 0)

	match String(n["t"]):
		"Expr":
			_expr(n["value"])
			_e("POP", null, null, line)
		"Assign":
			_assign(n)
		"AugAssign":
			_augassign(n)
		"Return":
			if n["value"] == null:
				_e("CONST", null, null, line)
			else:
				_expr(n["value"])
			_e("RETURN", null, null, line)
		"If":
			_if_stmt(n)
		"While":
			_while_stmt(n)
		"For":
			_for_stmt(n)
		"FunctionDef":
			_funcdef(n)
		"Break":
			if _loops.is_empty():
				_err("break 只能写在循环里面", line)
				return
			var lp: Dictionary = _loops[-1]
			lp["breaks"].append(_e("JUMP", -1, null, line))
		"Continue":
			if _loops.is_empty():
				_err("continue 只能写在循环里面", line)
				return
			_e("JUMP", int((_loops[-1] as Dictionary)["cont"]), null, line)
		"Pass":
			pass
		_:
			_err("不支持的语句类型 '%s'" % n["t"], line)


func _if_stmt(n: Dictionary) -> void:
	var line: int = n["line"]
	_expr(n["cond"])
	var j_false := _e("JUMP_FALSE", -1, null, line)
	_body(n["body"])
	var orelse: Array = n["orelse"]
	if orelse.is_empty():
		_patch(j_false, code.size())
		return
	var j_end := _e("JUMP", -1, null, line)
	_patch(j_false, code.size())
	_body(orelse)
	_patch(j_end, code.size())


func _while_stmt(n: Dictionary) -> void:
	var line: int = n["line"]
	var start := code.size()
	_expr(n["cond"])
	var j_out := _e("JUMP_FALSE", -1, null, line)
	_loops.append({"cont": start, "breaks": []})
	_body(n["body"])
	var lp: Dictionary = _loops.pop_back()
	_e("JUMP", start, null, line)
	_patch(j_out, code.size())
	for b in lp["breaks"]:
		_patch(int(b), code.size())


func _for_stmt(n: Dictionary) -> void:
	var line: int = n["line"]
	_expr(n["iter"])
	_e("GET_ITER", null, null, line)
	var iter_pos := code.size()
	_e("FOR_ITER", -1, null, line)
	_store_from_stack(n["target"])
	_loops.append({"cont": iter_pos, "breaks": []})
	_body(n["body"])
	var lp: Dictionary = _loops.pop_back()
	_e("JUMP", iter_pos, null, line)
	var end := code.size()
	_patch(iter_pos, end)
	for b in lp["breaks"]:
		_patch(int(b), end)


func _funcdef(n: Dictionary) -> void:
	var line: int = n["line"]
	var saved_code := code
	var saved_loops := _loops
	var saved_temp := _temp_top

	code = []
	_loops = []
	_temp_top = 0

	var params := PackedStringArray()
	for p in n["params"]:
		params.append(String(p["id"]))

	_body(n["body"])
	if not failed:
		_e("CONST", null, null, line)
		_e("RETURN", null, null, line)

	var fn := PyObjects.PyFunc.new(String(n["name"]), params, code, line)

	code = saved_code
	_loops = saved_loops
	_temp_top = saved_temp

	functions[String(n["name"])] = fn
	_e("CONST", fn, null, line)
	_e("STORE", String(n["name"]), null, line)


func _assign(n: Dictionary) -> void:
	var line: int = n["line"]
	var targets: Array = n["targets"]

	if targets.size() == 1 and String((targets[0] as Dictionary)["t"]) == "Name":
		_expr(n["value"])
		_e("STORE", String((targets[0] as Dictionary)["id"]), null, line)
		return

	_expr(n["value"])

	if targets.size() == 1:
		_store_from_stack(targets[0])
		return

	var tmp := _alloc_temp()
	_e("STORE_TMP", tmp, null, line)
	for t in targets:
		_store_from_temp(t, tmp)
	_free_temp()


func _augassign(n: Dictionary) -> void:
	var line: int = n["line"]
	var t: Dictionary = n["target"]
	var op := String(n["op"])

	if String(t["t"]) == "Name":
		_e("LOAD", String(t["id"]), null, line)
		_expr(n["value"])
		_e("BINOP", op, null, line)
		_e("STORE", String(t["id"]), null, line)
	elif String(t["t"]) == "Subscript":
		_expr(t["obj"])
		_expr(t["idx"])
		_expr(n["value"])
		_e("INDEX_AUG", op, null, line)
	else:
		_err("增强赋值的目标必须是变量或数组元素", line)


## 栈顶已经是要赋的值，把它存进目标。
func _store_from_stack(t: Dictionary) -> void:
	var line: int = t.get("line", 0)
	match String(t["t"]):
		"Name":
			_e("STORE", String(t["id"]), null, line)
		"Subscript":
			var tmp := _alloc_temp()
			_e("STORE_TMP", tmp, null, line)
			_expr(t["obj"])
			_expr(t["idx"])
			_e("LOAD_TMP", tmp, null, line)
			_e("INDEX_SET", null, null, line)
			_free_temp()
		"Tuple":
			var elts: Array = t["elts"]
			var base := _temp_top
			for _k in elts.size():
				_alloc_temp()
			_e("UNPACK", base, elts.size(), line)
			for k in elts.size():
				_store_from_temp(elts[k], base + k)
			for _k in elts.size():
				_free_temp()
		_:
			_err("不能给这个表达式赋值", line)


## 值在临时槽 tmp 里，把它存进目标。
func _store_from_temp(t: Dictionary, tmp: int) -> void:
	if failed:
		return
	var line: int = t.get("line", 0)
	if String(t["t"]) == "Name":
		_e("LOAD_TMP", tmp, null, line)
		_e("STORE", String(t["id"]), null, line)
	else:
		_e("LOAD_TMP", tmp, null, line)
		_store_from_stack(t)


# ---------------------------------------------------------------- 表达式

func _expr(n: Variant) -> void:
	if failed or n == null:
		return
	var node: Dictionary = n
	var line: int = node.get("line", 0)

	match String(node["t"]):
		"Num", "Str", "Const":
			_e("CONST", node["v"], null, line)
		"Name":
			_e("LOAD", String(node["id"]), null, line)
		"List":
			var elts: Array = node["elts"]
			for e in elts:
				_expr(e)
			_e("BUILD_LIST", elts.size(), null, line)
		"Tuple":
			var elts: Array = node["elts"]
			for e in elts:
				_expr(e)
			_e("BUILD_TUPLE", elts.size(), null, line)
		"BinOp":
			_expr(node["l"])
			_expr(node["r"])
			_e("BINOP", String(node["op"]), null, line)
		"UnaryOp":
			_expr(node["e"])
			_e("UNARY", String(node["op"]), null, line)
		"BoolOp":
			_boolop(node)
		"Compare":
			_compare(node)
		"Call":
			_call(node)
		"Attr":
			# 这台服务器的值没有可读属性：数组方法只能"调用"，不能"取出来"。
			# 早期版本在这里发了一条 LOAD_ATTR，而 VM 根本没实现它，玩家拿到的是
			# "内部错误：未知指令" —— 看不懂也无从下手。改成编译期就给出中文说明。
			# 注意：方法调用不走这里（见 _call），所以 a.append(x) 完全不受影响。
			_err("本服务器的值没有属性可读（.%s）。数组方法要直接调用，写成 a.%s(...)"
				% [String(node["attr"]), String(node["attr"])], line)
		"Subscript":
			_expr(node["obj"])
			_expr(node["idx"])
			_e("INDEX_GET", null, null, line)
		_:
			_err("不支持的表达式类型 '%s'" % node["t"], line)


func _boolop(n: Dictionary) -> void:
	var line: int = n["line"]
	var is_and := String(n["op"]) == "and"
	var jump_op := "JUMP_FALSE_KEEP" if is_and else "JUMP_TRUE_KEEP"
	var values: Array = n["values"]
	var jumps: Array = []
	for k in values.size():
		_expr(values[k])
		if k < values.size() - 1:
			jumps.append(_e(jump_op, -1, null, line))
	for j in jumps:
		_patch(int(j), code.size())


func _compare(n: Dictionary) -> void:
	var line: int = n["line"]
	var ops: Array = n["ops"]
	var comps: Array = n["comparators"]

	if ops.size() == 1:
		_expr(n["l"])
		_expr(comps[0])
		_e("CMP", String(ops[0]), null, line)
		return

	# 链式比较 a < b < c：中间值必须留住，借临时槽实现
	var base := _temp_top
	var t0 := _alloc_temp()
	_expr(n["l"])
	_e("STORE_TMP", t0, null, line)
	var prev := t0
	var jumps: Array = []
	for k in ops.size():
		var tk := _alloc_temp()
		_expr(comps[k])
		_e("STORE_TMP", tk, null, line)
		_e("LOAD_TMP", prev, null, line)
		_e("LOAD_TMP", tk, null, line)
		_e("CMP", String(ops[k]), null, line)
		jumps.append(_e("JUMP_FALSE", -1, null, line))
		prev = tk
	_e("CONST", true, null, line)
	var j_end := _e("JUMP", -1, null, line)
	var l_false := code.size()
	for j in jumps:
		_patch(int(j), l_false)
	_e("CONST", false, null, line)
	_patch(j_end, code.size())
	while _temp_top > base:
		_free_temp()


func _call(n: Dictionary) -> void:
	var line: int = n["line"]
	var f: Dictionary = n["func"]
	var args: Array = n["args"]

	if String(f["t"]) == "Attr":
		_expr(f["obj"])
		for a in args:
			_expr(a)
		_e("CALL_METHOD", String(f["attr"]), args.size(), line)
	else:
		_expr(f)
		for a in args:
			_expr(a)
		_e("CALL", args.size(), null, line)


# ---------------------------------------------------------------- 工具

func _e(op: String, a: Variant = null, b: Variant = null, line: int = 0) -> int:
	code.append({"op": op, "a": a, "b": b, "line": line})
	return code.size() - 1


func _patch(at: int, target: int) -> void:
	if at >= 0 and at < code.size():
		(code[at] as Dictionary)["a"] = target


func _alloc_temp() -> int:
	var t := _temp_top
	_temp_top += 1
	return t


func _free_temp() -> void:
	_temp_top = maxi(0, _temp_top - 1)


func _err(msg: String, line: int) -> void:
	if failed:
		return
	failed = true
	errors.append({"line": line, "msg": msg})

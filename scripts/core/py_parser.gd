class_name PyParser
extends RefCounted
## 递归下降解析器：token 流 -> AST（用 Dictionary 表示）。
##
## AST 节点统一带 "t"（类型）和 "line"（行号），行号一路带到编译产物里，
## 这样运行时错误才能指回玩家写的那一行。

var toks: Array = []
var pos := 0
var errors: Array = []
var failed := false
var _no_in := false  ## 解析 for 的循环变量时，禁止把 in 当成比较运算符

const CMP_OPS := ["==", "!=", "<", ">", "<=", ">="]
const AUG_OPS := ["+=", "-=", "*=", "/=", "//=", "%=", "**="]


func parse(src: String) -> Dictionary:
	var lex := PyLexer.new()
	var lexed := lex.tokenize(src)
	errors = []
	for e in lexed["errors"]:
		errors.append(e)
	toks = lexed["tokens"]
	pos = 0
	failed = not errors.is_empty()

	var body: Array = []
	while not failed and not _at_tok(PyLexer.T_EOF):
		for s in _statement():
			body.append(s)

	return {
		"ok": not failed,
		"ast": {"t": "Module", "body": body, "line": 1},
		"errors": errors,
	}


# ---------------------------------------------------------------- 语句

func _statement() -> Array:
	if _at("def"):
		return [_funcdef()]
	if _at("if"):
		return [_if_stmt()]
	if _at("while"):
		return [_while_stmt()]
	if _at("for"):
		return [_for_stmt()]
	return _simple_stmt()


func _simple_stmt() -> Array:
	var out: Array = []
	while not failed:
		out.append(_small_stmt())
		if _at(";"):
			_next()
			continue
		break
	if _at_tok(PyLexer.T_NEWLINE):
		_next()
	elif not _at_tok(PyLexer.T_EOF):
		_err("这一行结尾多了东西", _line())
	return out


func _small_stmt() -> Dictionary:
	var line := _line()
	if _at("return"):
		_next()
		if _at_tok(PyLexer.T_NEWLINE) or _at(";") or _at_tok(PyLexer.T_EOF):
			return {"t": "Return", "value": null, "line": line}
		return {"t": "Return", "value": _testlist(), "line": line}
	if _at("break"):
		_next()
		return {"t": "Break", "line": line}
	if _at("continue"):
		_next()
		return {"t": "Continue", "line": line}
	if _at("pass"):
		_next()
		return {"t": "Pass", "line": line}
	return _expr_stmt()


func _expr_stmt() -> Dictionary:
	var line := _line()
	var first := _testlist()

	for op in AUG_OPS:
		if _at(op):
			_next()
			var value := _testlist()
			_check_target(first, line)
			return {
				"t": "AugAssign", "target": first, "op": op.substr(0, op.length() - 1),
				"value": value, "line": line,
			}

	if _at("="):
		var parts: Array = [first]
		while _at("="):
			_next()
			parts.append(_testlist())
		var value: Dictionary = parts.pop_back()
		for t in parts:
			_check_target(t, line)
		return {"t": "Assign", "targets": parts, "value": value, "line": line}

	return {"t": "Expr", "value": first, "line": line}


func _check_target(t: Dictionary, line: int) -> void:
	match t.get("t", ""):
		"Name", "Subscript":
			pass
		"Tuple":
			for e in t["elts"]:
				_check_target(e, line)
		_:
			_err("等号左边必须是变量或数组元素，不能是表达式", line)


func _suite() -> Array:
	var body: Array = []
	if _at_tok(PyLexer.T_NEWLINE):
		_next()
		if not _at_tok(PyLexer.T_INDENT):
			_err("这里需要一段缩进的代码块", _line())
			return body
		_next()
		while not failed and not _at_tok(PyLexer.T_DEDENT) and not _at_tok(PyLexer.T_EOF):
			for s in _statement():
				body.append(s)
		if _at_tok(PyLexer.T_DEDENT):
			_next()
	else:
		for s in _simple_stmt():
			body.append(s)
	return body


func _funcdef() -> Dictionary:
	var line := _line()
	_next()  # def
	var name := ""
	if _at_tok(PyLexer.T_NAME):
		name = _peek()["v"]
		_next()
	else:
		_err("def 后面要跟函数名", line)
	_expect("(")
	var params: Array = []
	var guard := 0
	while not _at(")") and not failed:
		if _at_tok(PyLexer.T_NAME):
			params.append({"t": "Name", "id": _peek()["v"], "line": _line()})
			_next()
		else:
			_err("参数必须是变量名", _line())
			break
		if _at(","):
			_next()
		else:
			break
		guard += 1
		if guard > 64:
			_err("参数太多", line)
			break
	_expect(")")
	_expect(":")
	var body := _suite()
	return {"t": "FunctionDef", "name": name, "params": params, "body": body, "line": line}


func _if_stmt() -> Dictionary:
	var line := _line()
	_next()  # if / elif
	var cond := _expr()
	_expect(":")
	var body := _suite()
	var orelse: Array = []
	if _at("elif"):
		orelse = [_if_stmt()]
	elif _at("else"):
		_next()
		_expect(":")
		orelse = _suite()
	return {"t": "If", "cond": cond, "body": body, "orelse": orelse, "line": line}


func _while_stmt() -> Dictionary:
	var line := _line()
	_next()
	var cond := _expr()
	_expect(":")
	var body := _suite()
	return {"t": "While", "cond": cond, "body": body, "line": line}


func _for_stmt() -> Dictionary:
	var line := _line()
	_next()
	_no_in = true
	var target := _testlist()
	_no_in = false
	if not _at("in"):
		_err("for 语句需要写成 for 变量 in 序列:", line)
	else:
		_next()
	var it := _expr()
	_expect(":")
	var body := _suite()
	return {"t": "For", "target": target, "iter": it, "body": body, "line": line}


# ---------------------------------------------------------------- 表达式

func _testlist() -> Dictionary:
	var line := _line()
	var first := _expr()
	if not _at(","):
		return first
	var elts: Array = [first]
	var guard := 0
	while _at(","):
		_next()
		if _at("=") or _at("in") or _at(")") or _at("]") or _at(":") or _at(";") \
				or _at_tok(PyLexer.T_NEWLINE) or _at_tok(PyLexer.T_EOF):
			break
		elts.append(_expr())
		guard += 1
		if guard > 256:
			_err("列表太长", line)
			break
	return {"t": "Tuple", "elts": elts, "line": line}


func _expr() -> Dictionary:
	return _or_test()


func _or_test() -> Dictionary:
	var line := _line()
	var left := _and_test()
	if not _at("or"):
		return left
	var values: Array = [left]
	while _at("or"):
		_next()
		values.append(_and_test())
	return {"t": "BoolOp", "op": "or", "values": values, "line": line}


func _and_test() -> Dictionary:
	var line := _line()
	var left := _not_test()
	if not _at("and"):
		return left
	var values: Array = [left]
	while _at("and"):
		_next()
		values.append(_not_test())
	return {"t": "BoolOp", "op": "and", "values": values, "line": line}


func _not_test() -> Dictionary:
	var line := _line()
	if _at("not"):
		_next()
		return {"t": "UnaryOp", "op": "not", "e": _not_test(), "line": line}
	return _comparison()


func _comparison() -> Dictionary:
	var line := _line()
	var left := _arith()
	var ops: Array = []
	var comparators: Array = []
	while not failed and _peek()["t"] == PyLexer.T_OP:
		var op: String = _peek()["v"]
		var is_cmp := CMP_OPS.has(op)
		if op == "in" and not _no_in:
			is_cmp = true
		if not is_cmp:
			break
		_next()
		ops.append(op)
		comparators.append(_arith())
	if ops.is_empty():
		return left
	return {"t": "Compare", "l": left, "ops": ops, "comparators": comparators, "line": line}


func _arith() -> Dictionary:
	var line := _line()
	var left := _term()
	while not failed and (_at("+") or _at("-")):
		var op: String = _peek()["v"]
		_next()
		left = {"t": "BinOp", "op": op, "l": left, "r": _term(), "line": line}
	return left


func _term() -> Dictionary:
	var line := _line()
	var left := _factor()
	while not failed and (_at("*") or _at("/") or _at("//") or _at("%")):
		var op: String = _peek()["v"]
		_next()
		left = {"t": "BinOp", "op": op, "l": left, "r": _factor(), "line": line}
	return left


func _factor() -> Dictionary:
	var line := _line()
	if _at("-") or _at("+"):
		var op: String = _peek()["v"]
		_next()
		return {"t": "UnaryOp", "op": op, "e": _factor(), "line": line}
	return _power()


func _power() -> Dictionary:
	var line := _line()
	var base := _trailers(_atom())
	if _at("**"):
		_next()
		return {"t": "BinOp", "op": "**", "l": base, "r": _factor(), "line": line}
	return base


func _atom() -> Dictionary:
	var tk: Dictionary = _peek()
	var line: int = tk["line"]

	match int(tk["t"]):
		PyLexer.T_NUM:
			_next()
			return {"t": "Num", "v": tk["v"], "line": line}
		PyLexer.T_STR:
			_next()
			return {"t": "Str", "v": tk["v"], "line": line}
		PyLexer.T_NAME:
			_next()
			return {"t": "Name", "id": tk["v"], "line": line}

	var v: String = tk["v"]
	if v == "True":
		_next()
		return {"t": "Const", "v": true, "line": line}
	if v == "False":
		_next()
		return {"t": "Const", "v": false, "line": line}
	if v == "None":
		_next()
		return {"t": "Const", "v": null, "line": line}

	if v == "(":
		_next()
		if _at(")"):
			_next()
			return {"t": "Tuple", "elts": [], "line": line}
		var first := _expr()
		if _at(","):
			var elts: Array = [first]
			var guard := 0
			while _at(","):
				_next()
				if _at(")"):
					break
				elts.append(_expr())
				guard += 1
				if guard > 256:
					_err("元组太长", line)
					break
			_expect(")")
			return {"t": "Tuple", "elts": elts, "line": line}
		_expect(")")
		return first

	if v == "[":
		_next()
		var elts: Array = []
		var guard := 0
		while not _at("]") and not failed:
			elts.append(_expr())
			if _at(","):
				_next()
			else:
				break
			guard += 1
			if guard > 256:
				_err("列表太长", line)
				break
		_expect("]")
		return {"t": "List", "elts": elts, "line": line}

	_err("这里应该是一个表达式，但读到了 '%s'" % (v if not v.is_empty() else "行尾"), line)
	return {"t": "Const", "v": null, "line": line}


func _trailers(node: Dictionary) -> Dictionary:
	var guard := 0
	while not failed:
		guard += 1
		if guard > 64:
			break
		if _at("("):
			var line := _line()
			_next()
			var args: Array = []
			var g2 := 0
			while not _at(")") and not failed:
				args.append(_expr())
				if _at(","):
					_next()
				else:
					break
				g2 += 1
				if g2 > 64:
					_err("参数太多", line)
					break
			_expect(")")
			node = {"t": "Call", "func": node, "args": args, "line": line}
		elif _at("["):
			var line := _line()
			_next()
			var idx := _expr()
			_expect("]")
			node = {"t": "Subscript", "obj": node, "idx": idx, "line": line}
		elif _at("."):
			var line := _line()
			_next()
			if _at_tok(PyLexer.T_NAME):
				var attr: String = _peek()["v"]
				_next()
				node = {"t": "Attr", "obj": node, "attr": attr, "line": line}
			else:
				_err("'.' 后面要跟方法名", line)
				break
		else:
			break
	return node


# ---------------------------------------------------------------- 工具

func _peek() -> Dictionary:
	if pos < toks.size():
		return toks[pos]
	return {"t": PyLexer.T_EOF, "v": "", "line": _line()}


func _next() -> void:
	if pos < toks.size():
		pos += 1


func _at(v: String) -> bool:
	var tk := _peek()
	return int(tk["t"]) == PyLexer.T_OP and String(tk["v"]) == v


func _at_tok(t: int) -> bool:
	return int(_peek()["t"]) == t


func _expect(v: String) -> void:
	if _at(v):
		_next()
	else:
		_err("这里应该是 '%s'" % v, _line())


func _line() -> int:
	return int(_peek()["line"])


func _err(msg: String, line: int) -> void:
	if failed:
		return
	failed = true
	errors.append({"line": line, "msg": msg})

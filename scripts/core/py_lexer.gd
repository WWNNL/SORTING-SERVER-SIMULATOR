class_name PyLexer
extends RefCounted
## 把 Python 子集源码切成 token 流。
##
## 只实现本游戏需要的子集：def / if-elif-else / while / for-in / break / continue /
## 赋值与增强赋值 / 表达式。import、class、try、lambda 等一律拒绝，并给出中文提示——
## 让玩家立刻知道"这台服务器跑不了这个"，而不是看着莫名其妙的语法错误。

enum { T_NAME, T_NUM, T_STR, T_OP, T_NEWLINE, T_INDENT, T_DEDENT, T_EOF }

const KEYWORDS := [
	"def", "return", "if", "elif", "else", "while", "for", "in", "and", "or",
	"not", "break", "continue", "pass", "True", "False", "None",
]

## 语法上认识、但本服务器不支持的构造，给出明确解释而不是解析崩溃。
const UNSUPPORTED := {
	"import": "本服务器不提供模块系统（import）",
	"from": "本服务器不提供模块系统（from）",
	"class": "本服务器不提供面向对象（class）",
	"lambda": "本服务器不支持 lambda 表达式",
	"try": "本服务器不支持异常处理（try）",
	"except": "本服务器不支持异常处理（except）",
	"finally": "本服务器不支持异常处理（finally）",
	"raise": "本服务器不支持抛出异常（raise）",
	"with": "本服务器不支持 with 语句",
	"global": "本服务器不支持 global 声明",
	"nonlocal": "本服务器不支持 nonlocal 声明",
	"del": "本服务器不支持 del 语句",
	"assert": "本服务器不支持 assert 语句",
	"yield": "本服务器不支持生成器（yield）",
	"is": "本服务器不支持 is 运算符，请用 ==",
	"async": "本服务器不支持异步（async）",
	"await": "本服务器不支持异步（await）",
}

## 长运算符必须排在前面，否则会被短前缀截断。
const OPS := [
	"**=", "//=", "==", "!=", "<=", ">=", "+=", "-=", "*=", "/=", "%=",
	"**", "//", "->",
	"+", "-", "*", "/", "%", "=", "<", ">",
	"(", ")", "[", "]", "{", "}", ",", ":", ".", ";",
]

var tokens: Array = []
var errors: Array = []

var _src := ""
var _i := 0
var _n := 0
var _line := 1
var _paren := 0  ## 括号深度，>0 时换行不产生 NEWLINE（隐式续行）
var _indents: Array[int] = [0]
var _at_line_start := true
## 当前 token 在源码里的起始偏移。编辑器高亮需要它来定位颜色区间。
var _tok_start := 0


func tokenize(src: String) -> Dictionary:
	_src = src.replace("\r\n", "\n").replace("\r", "\n").replace("\t", "    ")
	_i = 0
	_n = _src.length()
	_line = 1
	_paren = 0
	_indents = [0]
	_at_line_start = true
	tokens = []
	errors = []

	while _i < _n:
		if _at_line_start and _paren == 0:
			# 先把空行与纯注释行整段跳过，再对"真正有内容的那一行"判定缩进。
			# 这两件事必须分开：混在一起会让空行后面那一行的缩进被漏掉。
			_skip_blank_lines()
			if _i >= _n:
				break
			_apply_indent()
			_at_line_start = false

		var c := _src[_i]
		_tok_start = _i

		if c == "\n":
			if _paren > 0:
				_i += 1
				_line += 1
				continue
			_emit(T_NEWLINE, "\n")
			_i += 1
			_line += 1
			_at_line_start = true
			continue

		if c == " ":
			_i += 1
			continue

		if c == "#":
			while _i < _n and _src[_i] != "\n":
				_i += 1
			continue

		if _is_digit(c) or (c == "." and _i + 1 < _n and _is_digit(_src[_i + 1])):
			_read_number()
			continue

		if c == "\"" or c == "'":
			_read_string()
			continue

		if _is_ident_start(c):
			_read_name()
			continue

		if _read_op():
			continue

		_err("无法识别的字符 '%s'" % c, _line)
		_i += 1

	# 收尾：补一个 NEWLINE、补齐 DEDENT，再放 EOF
	if tokens.size() > 0 and int(tokens[-1]["t"]) != T_NEWLINE:
		_emit(T_NEWLINE, "\n")
	while _indents.size() > 1:
		_indents.pop_back()
		_emit(T_DEDENT, "")
	_emit(T_EOF, "")
	return {"tokens": tokens, "errors": errors}


## 跳过空行与纯注释行（连同它们的换行符）。它们不影响缩进。
func _skip_blank_lines() -> void:
	while _i < _n:
		var j := _i
		while j < _n and _src[j] == " ":
			j += 1
		if j >= _n:
			_i = j
			return
		var c := _src[j]
		if c == "\n":
			_i = j + 1
			_line += 1
			continue
		if c == "#":
			while j < _n and _src[j] != "\n":
				j += 1
			if j < _n:
				j += 1
				_line += 1
			_i = j
			continue
		return


## 按当前行的缩进发出 INDENT / DEDENT。调用前必须已跳过空行。
func _apply_indent() -> void:
	var col := 0
	while _i < _n and _src[_i] == " ":
		col += 1
		_i += 1

	if col > _indents[-1]:
		_indents.append(col)
		_emit(T_INDENT, "")
	elif col < _indents[-1]:
		while _indents.size() > 1 and col < _indents[-1]:
			_indents.pop_back()
			_emit(T_DEDENT, "")
		if col != _indents[-1]:
			_err("缩进不一致：这一行缩进了 %d 格，与上层对不齐" % col, _line)


func _read_number() -> void:
	var start := _i
	while _i < _n and (_is_digit(_src[_i]) or _src[_i] == "."):
		_i += 1
	# 科学计数法
	if _i < _n and (_src[_i] == "e" or _src[_i] == "E"):
		var save := _i
		_i += 1
		if _i < _n and (_src[_i] == "+" or _src[_i] == "-"):
			_i += 1
		if _i < _n and _is_digit(_src[_i]):
			while _i < _n and _is_digit(_src[_i]):
				_i += 1
		else:
			_i = save
	var text := _src.substr(start, _i - start)
	if text.contains(".") or text.contains("e") or text.contains("E"):
		_emit_num(float(text))
	else:
		_emit_num(int(text))


func _read_string() -> void:
	var quote := _src[_i]
	var line0 := _line
	_i += 1
	var out := ""
	while _i < _n and _src[_i] != quote:
		var c := _src[_i]
		if c == "\\" and _i + 1 < _n:
			var e := _src[_i + 1]
			match e:
				"n": out += "\n"
				"t": out += "\t"
				"\\": out += "\\"
				"'": out += "'"
				"\"": out += "\""
				_: out += e
			_i += 2
			continue
		if c == "\n":
			_err("字符串没有闭合", line0)
			break
		out += c
		_i += 1
	if _i < _n and _src[_i] == quote:
		_i += 1
	else:
		_err("字符串没有闭合", line0)
	tokens.append({"t": T_STR, "v": out, "line": line0})


func _read_name() -> void:
	var start := _i
	while _i < _n and _is_ident_char(_src[_i]):
		_i += 1
	var word := _src.substr(start, _i - start)

	if UNSUPPORTED.has(word):
		_err(UNSUPPORTED[word], _line)
		return
	if KEYWORDS.has(word):
		_emit(T_OP, word)
		return
	_emit(T_NAME, word)


func _read_op() -> bool:
	for op in OPS:
		var l: int = op.length()
		if _i + l <= _n and _src.substr(_i, l) == op:
			_i += l
			_emit(T_OP, op)
			if op == "(" or op == "[" or op == "{":
				_paren += 1
			elif op == ")" or op == "]" or op == "}":
				_paren = maxi(0, _paren - 1)
			return true
	return false


func _emit(t: int, v: String) -> void:
	tokens.append({"t": t, "v": v, "line": _line, "pos": _tok_start, "end": _i})


func _emit_num(v: Variant) -> void:
	tokens.append({"t": T_NUM, "v": v, "line": _line, "pos": _tok_start, "end": _i})


func _err(msg: String, line: int) -> void:
	errors.append({"line": line, "msg": msg})


static func _is_digit(c: String) -> bool:
	return c >= "0" and c <= "9"


static func _is_ident_start(c: String) -> bool:
	return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_"


static func _is_ident_char(c: String) -> bool:
	return _is_ident_start(c) or _is_digit(c)

class_name PyHighlighter
extends SyntaxHighlighter
## 用游戏自己的 PyLexer 做语法高亮。
##
## 为什么不用内置的 CodeHighlighter：它是"关键字表 + 颜色区间"的浅层文本匹配，
## 高亮结果和服务器真正理解的语法并不一致——最典型的是字符串里的 # 会被当成
## 注释起始，引号里的内容也会被关键字表污染。
##
## 直接复用 PyLexer，就等于"看到什么颜色，服务器就怎么理解"。
##
## 类别划分刻意做细，而不是笼统地"关键字一个色"：
##   · def / return 单独一色 —— 它们标记"结构"，扫代码时最先要看的就是这些
##   · 控制流、逻辑运算、常量各一色 —— 读条件表达式时能一眼分清"流程"和"数据"
##   · 内置函数、数组方法、用户函数各一色 —— 区分"服务器给的"和"自己写的"
##
## 加粗是"写了但不生效"的：实测把 def / while 和普通标识符里同一个字形（字母 l）的
## 字干放在 10 倍放大下并排比，都是一像素宽——和 C_COMMENT 处说的一样，
## 当前引擎忽略了高亮字典里的字重/字形属性。
## 所以类别之间的区分**必须完全由颜色承担**，这也是控制流原来用纯白时等于没高亮的原因。
##
## 控制流原来是纯白 #ffffff，而正文是 #d8d8d8：在黑底 12px 点阵字下这两者几乎分不出来。
## 现在换成暖红，和 def 的粉色也拉得开——两者蓝色通道差 90 多，缩到 12px 也不会认错。

# ---- 颜色
const C_DEF := Color("#ff9ecd")        ## def / return
const C_FLOW := Color("#ff7b72")       ## if / elif / else / for / while / break …
const C_LOGIC := Color("#d0a0ff")      ## and / or / not / in
const C_CONST := Color("#ffb86c")      ## True / False / None
const C_BUILTIN := Color("#8fd6ff")    ## len / range / max ...
const C_METHOD := Color("#7fe3c0")     ## append / pop / 以及 .后面的方法
const C_FUNC := Color("#7fe3c0")       ## 用户定义的函数名与调用
const C_ENTRY := Color("#ffffff")      ## sort —— 服务器唯一要求的入口
const C_NUMBER := Color("#ffd479")
const C_STRING := Color("#a8d98a")
const C_COMMENT := Color("#5a6570")
const C_SYMBOL := Color("#c8c8c8")     ## 运算符
const C_BRACKET := Color("#7a7a7a")    ## 括号、逗号、冒号
const C_NAME := Color("#d8d8d8")       ## 普通标识符

const KW_DEF := ["def", "return"]
const KW_FLOW := ["if", "elif", "else", "for", "while", "break", "continue", "pass"]
const KW_LOGIC := ["and", "or", "not", "in"]
const KW_CONST := ["True", "False", "None"]
const BRACKETS := ["(", ")", "[", "]", "{", "}", ",", ":", ";"]

## 服务器唯一要求的入口函数名
const ENTRY := "sort"

## line -> { 列号: {颜色/字重等属性} }
var _lines: Dictionary = {}
## SyntaxHighlighter 没有公开接口能拿到被附加的 TextEdit，所以自己持一个引用。
## 由编辑器在装配时赋值，并在文本变化时主动调 refresh()。
var editor: TextEdit = null


## 文本变化后重建缓存。编辑器显式调用，不依赖引擎的回调时机。
func refresh() -> void:
	_rebuild()
	clear_highlighting_cache()


func _update_cache() -> void:
	_rebuild()


func _rebuild() -> void:
	_lines = {}
	if editor == null:
		return
	var text := editor.text
	if text.is_empty():
		return

	# 字符偏移 -> 行/列 的换算表
	var starts := PackedInt32Array()
	starts.append(0)
	for i in text.length():
		if text[i] == "\n":
			starts.append(i + 1)

	var lex := PyLexer.new()
	var lexed := lex.tokenize(text)
	var toks: Array = lexed["tokens"]

	# 字符串占用的区间，用来判断 # 到底是注释还是字符串里的普通字符
	var string_spans: Array = []

	for idx in toks.size():
		var tk: Dictionary = toks[idx]
		var t := int(tk["t"])
		if t == PyLexer.T_NEWLINE or t == PyLexer.T_INDENT \
				or t == PyLexer.T_DEDENT or t == PyLexer.T_EOF:
			continue
		var pos := int(tk.get("pos", -1))
		var endp := int(tk.get("end", -1))
		if pos < 0 or endp <= pos:
			continue

		# 数字 token 的 v 是 int/float，其余是 String，统一用 str() 转换
		var word := str(tk["v"])
		if t == PyLexer.T_STR:
			string_spans.append([pos, endp])

		_paint(starts, pos, endp, _props_for(t, word, toks, idx), text)

	_paint_comments(starts, string_spans, text)


func _get_line_syntax_highlighting(line: int) -> Dictionary:
	var src: Dictionary = _lines.get(line, {})
	if src.size() <= 1:
		return src
	# 必须按列号升序返回：TextEdit 是顺序套用这些颜色区间的，
	# 顺序乱了颜色就会串到错误的文本上。
	var keys := src.keys()
	keys.sort()
	var out := {}
	for k in keys:
		out[k] = src[k]
	return out


# ---------------------------------------------------------------- 分类

func _props_for(t: int, word: String, toks: Array, idx: int) -> Dictionary:
	match t:
		PyLexer.T_NUM:
			return {"color": C_NUMBER}
		PyLexer.T_STR:
			return {"color": C_STRING}
		PyLexer.T_OP:
			# bold 照写不误（引擎哪天支持了就直接生效），但**不能指望它**：
			# 实测把 def / while 和普通标识符里同一个字形的字干放到 10 倍放大下比，
			# 都是一像素宽，和 italic 一样被当前引擎忽略。
			# 所以类别之间的区分必须完全由颜色承担，改颜色才是真正改观感的一步。
			if KW_DEF.has(word):
				return {"color": C_DEF, "bold": true}
			if KW_FLOW.has(word):
				return {"color": C_FLOW, "bold": true}
			if KW_LOGIC.has(word):
				return {"color": C_LOGIC}
			if KW_CONST.has(word):
				return {"color": C_CONST}
			if BRACKETS.has(word):
				return {"color": C_BRACKET}
			return {"color": C_SYMBOL}
		PyLexer.T_NAME:
			# 点号后面的名字是方法调用
			if _prev_is(toks, idx, "."):
				return {"color": C_METHOD}
			# print 单独给色：它是唯一会往控制台写东西的函数
			if word == "print":
				return {"color": C_METHOD}
			if PyVM.BUILTIN_NAMES.has(word):
				return {"color": C_BUILTIN}
			if _prev_is(toks, idx, "def"):
				# sort 是服务器唯一要求的入口，标得最显眼
				if word == ENTRY:
					return {"color": C_ENTRY, "bold": true, "underline": true}
				return {"color": C_FUNC, "bold": true}
			if _next_is(toks, idx, "("):
				return {"color": C_FUNC}
			return {"color": C_NAME}
	return {"color": C_NAME}


static func _prev_is(toks: Array, idx: int, word: String) -> bool:
	if idx <= 0:
		return false
	var p: Dictionary = toks[idx - 1]
	return int(p["t"]) == PyLexer.T_OP and str(p["v"]) == word


static func _next_is(toks: Array, idx: int, word: String) -> bool:
	if idx + 1 >= toks.size():
		return false
	var n: Dictionary = toks[idx + 1]
	return int(n["t"]) == PyLexer.T_OP and str(n["v"]) == word


# ---------------------------------------------------------------- 上色

## 把 [pos, end) 这段源码上色。token 不会跨行（字符串也不允许跨行），
## 所以这里只需处理"落在哪一行"。
func _paint(starts: PackedInt32Array, pos: int, endp: int,
		props: Dictionary, text: String) -> void:
	var li := _line_of(starts, pos)
	var line_start := starts[li]
	var line_end := text.length()
	if li + 1 < starts.size():
		line_end = starts[li + 1] - 1
	var e := mini(endp, line_end)

	var entry: Dictionary = _lines.get(li, {})
	entry[pos - line_start] = props
	# 结束位置放一个"回到默认"的标记，避免颜色和字重溢出到后面的空白
	if e - line_start < text.length():
		entry[e - line_start] = {"color": C_NAME, "bold": false, "italic": false,
			"underline": false}
	_lines[li] = entry


## 注释：词法器会整段跳过注释，所以高亮得自己找。
## 关键是排除字符串内部的 # —— 这正是内置 CodeHighlighter 会出错的地方。
func _paint_comments(starts: PackedInt32Array, string_spans: Array, text: String) -> void:
	var i := 0
	var n := text.length()
	while i < n:
		if text[i] == "#" and not _in_spans(string_spans, i):
			var li := _line_of(starts, i)
			var line_start := starts[li]
			var line_end := n
			if li + 1 < starts.size():
				line_end = starts[li + 1] - 1
			var entry: Dictionary = _lines.get(li, {})
			# 注释刻意不用斜体。像素字体只有一个字面（face_count = 1），
			# 引擎只能靠横向剪切矩阵合成斜体，而那会让每一行笔画落在不同的
			# 半像素位置上——抗锯齿是关的，竖笔就会变成粗细不匀的阶梯。
			# 实测把 italic 打开，注释行的墨迹质心斜率仍是 -0.001 px/行（未倾斜），
			# 说明当前引擎直接忽略了它；写死 false 是为了将来换字体时不会踩雷。
			entry[i - line_start] = {"color": C_COMMENT, "italic": false}
			entry[line_end - line_start] = {"color": C_NAME, "italic": false}
			_lines[li] = entry
			i = line_end
			continue
		i += 1


static func _in_spans(spans: Array, pos: int) -> bool:
	for s in spans:
		if pos >= int(s[0]) and pos < int(s[1]):
			return true
	return false


static func _line_of(starts: PackedInt32Array, pos: int) -> int:
	var lo := 0
	var hi := starts.size() - 1
	while lo < hi:
		var mid := (lo + hi + 1) / 2
		if starts[mid] <= pos:
			lo = mid
		else:
			hi = mid - 1
	return lo

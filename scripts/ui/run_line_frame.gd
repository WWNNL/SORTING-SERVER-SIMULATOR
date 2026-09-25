class_name RunLineFrame
extends Control
## 编辑器里的"现在跑到第几行"白框 —— 和左侧可视化里框住当前元素的白框同一套语言：
## 1px 白描边 + 一个指向这一行的指示三角，跟着执行位置走。
##
## 三角放在**行尾右侧**而不是装订线里：装订线是行号的地盘，
## 三角压上去正好盖住行号（两位数时盖得严严实实），而右边通常是空的。
##
## 它挂在 CodeEdit **内部**（作为子节点），所以坐标天然就是编辑器的局部坐标，
## 而且会画在文本之上；不需要自己去算装订线宽度、内边距和滚动偏移——
## 几何信息全部来自 TextEdit.get_rect_at_line_column()。
##
## 两个前提：
##   · 折行关闭（wrap_mode = NONE）：每行等高，行与行之间不会有高度歧义。
##   · get_rect_at_line_column() 只对**可见行**有效，返回空矩形；
##     所以换行以后要按需要滚动到目标行，再取矩形（见 _follow）。

const PAD_L := 4.0      ## 左边留一点，但别伸进装订线的行号里
const PAD_R := 10.0     ## 右边多留一点，免得边框贴着最后一个字（见 _line_width）
const PAD_Y := 1.0
const MIN_W := 30.0     ## 空行也得框得出一个看得见的方框
const EDGE := 4.0       ## 离编辑器右边缘留一点，别把滚动条圈进去
const TAB_SPACES := 4   ## 和编辑器的 indent_size 一致，只在量宽度时用

var editor: TextEdit = null

## 要框住的行号，1 起（和 VM 的行号一致）。0 表示不显示。
var _line := 0
var _rect := Rect2()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	set_anchors_preset(Control.PRESET_FULL_RECT)


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	set_process(true)


## 框住某一行。line <= 0 等价于隐藏。
func show_line(line: int) -> void:
	if line <= 0:
		clear()
		return
	var changed := line != _line
	_line = line
	visible = true
	if changed:
		_follow()
		_refresh_rect()
		queue_redraw()


func clear() -> void:
	if not visible and _line == 0:
		return
	_line = 0
	_rect = Rect2()
	visible = false
	queue_redraw()


func current_line() -> int:
	return _line


# ---------------------------------------------------------------- 几何

func _process(_delta: float) -> void:
	if not visible or editor == null or not is_visible_in_tree():
		return
	# 玩家自己滚动、窗口缩放、字号变化都会让矩形变位置，逐帧比一下最省心：
	# 只有真的变了才重画，而重画的是这个覆盖层本身，不会带着文本一起重绘。
	var r := _line_rect()
	if r == _rect:
		return
	_rect = r
	queue_redraw()


func _refresh_rect() -> void:
	_rect = _line_rect()


## 目标行的矩形（编辑器局部坐标）。行不可见或越界时返回空矩形。
func _line_rect() -> Rect2:
	if editor == null or _line <= 0:
		return Rect2()
	var li := _line - 1
	if li < 0 or li >= editor.get_line_count():
		return Rect2()

	var head := editor.get_rect_at_line_column(li, 0)
	if head.size.y <= 0:
		return Rect2()   # 这一行不在可视范围里

	var text := editor.get_line(li)
	var x0 := float(head.position.x) - PAD_L
	var limit := maxf(x0 + MIN_W, _content_right() - EDGE)
	# 行比可视区还宽时会被 limit 截住，白框一路顶到文本区右边界
	var x1 := clampf(float(head.position.x) + _line_width(text) + PAD_R,
		x0 + MIN_W, limit)
	# 上下也夹在编辑器范围内：首行（y = -1）和贴着下边缘的那一行，
	# 否则会被编辑器的裁剪吃掉一条边，看着像边框缺了一块。
	var y0 := maxf(0.0, float(head.position.y) - PAD_Y)
	var y1 := minf(size.y, float(head.position.y) + float(head.size.y) + PAD_Y)
	return Rect2(x0, y0, x1 - x0, y1 - y0)


## 这一行正文实际画出来有多宽（像素）。
##
## 不能拿 get_rect_at_line_column(行, 行末列) 当行尾：TextEdit 的每个光标位置都是
## 整数像素，逐字累加下来会比真正画出来的文本短一截——实测 12 个字符短 4px、
## 28 个字符（含中文）短 12px，正好差一个全角字。白框右边框于是压在最后一个字上，
## 中文注释行最明显。改成用编辑器当前字体量字符串宽度：绘制走的就是这套字形排版，
## 量出来即视觉上的行尾。
func _line_width(text: String) -> float:
	if editor == null:
		return 0.0
	var font: Font = editor.get_theme_font("font")
	if font == null:
		return 0.0
	var font_size: int = editor.get_theme_font_size("font_size")
	# 制表符按编辑器的缩进宽度展开，否则量出来比画出来的短
	var measure := text.replace("\t", " ".repeat(TAB_SPACES))
	return font.get_string_size(measure, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x


## 文本区域的右边界（编辑器局部坐标）。竖滚动条是浮在右边缘上的，
## 白框和三角都不该压到它身上。
func _content_right() -> float:
	var limit := size.x
	if editor != null:
		var sb := editor.get_v_scroll_bar()
		if sb != null and sb.position.x > 0.0:
			limit = minf(limit, sb.position.x)
	return limit


## 让目标行进入视野。只在这一行本来就在视野外时才滚动——
## 玩家正自己翻代码的时候，不该被运行位置抢走滚动条。
##
## 注意单位：TextEdit.scroll_vertical 是**行**，不是像素
## （实测设 3 之后 get_first_visible_line() 就是 3）。写成"行 × 行高"那种
## 像素换算会被 clamp 到最底部，画面看着像"跳到最后一行"。
func _follow() -> void:
	if editor == null or _line <= 0:
		return
	var li := _line - 1
	var first := editor.get_first_visible_line()
	var last := editor.get_last_full_visible_line()
	if li >= first and li <= last:
		return
	var visible := maxi(1, editor.get_visible_line_count())
	editor.scroll_vertical = maxi(0, li - visible / 2)


# ---------------------------------------------------------------- 绘制

func _draw() -> void:
	if _rect.size.y <= 0.0:
		return
	draw_rect(_rect, Prts.WHITE, false, 1.0)

	# 行尾右侧的指示三角，指向这一行（装订线那侧会让出来给行号）
	var cx := _rect.position.x + _rect.size.x + 6.0
	if cx + 3.0 > _content_right() - EDGE:
		# 这一行太长，右边没地方了：只留白框。宁可少一个点缀，
		# 也不要让三角压到代码或滚动条上。
		return
	var cy := _rect.position.y + _rect.size.y * 0.5
	draw_colored_polygon(PackedVector2Array([
		Vector2(cx + 3.0, cy - 4.0),
		Vector2(cx + 3.0, cy + 4.0),
		Vector2(cx - 3.0, cy),
	]), Prts.WHITE)
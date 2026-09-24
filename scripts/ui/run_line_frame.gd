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

const PAD_X := 4.0      ## 白框比文字起点再往外留一点，免得贴着字符
const PAD_Y := 1.0
const MIN_W := 30.0     ## 空行也得框得出一个看得见的方框
const EDGE := 4.0       ## 离编辑器右边缘留一点，别把滚动条圈进去

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
	var tail := editor.get_rect_at_line_column(li, text.length())
	var x0 := float(head.position.x) - PAD_X
	var limit := maxf(x0 + MIN_W, _content_right() - EDGE)
	# 行尾量不到有两种情况，含义完全不同：
	#   · 空行：tail 与 head 重合，交给下面的 clamp 撑到 MIN_W
	#   · 行比可视区还宽：行尾那一列根本不在可见范围内，get_rect_at_line_column 返回空。
	#     这时要一路框到文本区右边界，否则白框会缩成一个几十像素的小方块，
	#     看着像"框错了行"。
	var x1 := limit
	if tail.size.y > 0:
		x1 = float(tail.position.x) + PAD_X
	x1 = clampf(x1, x0 + MIN_W, limit)
	var y := float(head.position.y) - PAD_Y
	return Rect2(x0, y, x1 - x0, float(head.size.y) + PAD_Y * 2.0)


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
class_name Prts
extends RefCounted
## PRTS 风格的黑白像素主题。
##
## 设计约束（刻意保持严格）：
##   · 只用黑、白、灰，没有彩色。层级靠明度、细线和留白拉开。
##   · 全部直角，边框 1px，禁用抗锯齿。
##   · 交互反馈靠"反白"（按下时整块变白、文字变黑），而不是变色。
##   · 字体关闭抗锯齿 + 网格对齐，得到点阵观感。

# ---------------------------------------------------------------- 调色板

const BG := Color("#000000")
const PANEL := Color("#080808")
const RAISED := Color("#101010")
const HOVER := Color("#1a1a1a")
const LINE := Color("#242424")
const LINE_HI := Color("#3d3d3d")
const LINE_WHITE := Color("#ffffff")
const DIM := Color("#565656")
const TEXT := Color("#9a9a9a")
const TEXT_HI := Color("#d8d8d8")
const WHITE := Color("#ffffff")
const BLACK := Color("#000000")
## 指示框角标的"未运行"颜色。不能用 LINE_HI（#3d3d3d）——在黑底上几乎看不见，
## 玩家会以为这个框根本不存在。要暗，但必须一眼能看见。
const FRAME_IDLE := Color("#6a6a6a")

# 可视化用色
const BAR := Color("#2e2e2e")
const BAR_SETTLED := Color("#6a6a6a")
const BAR_HOT := Color("#ffffff")

## 字号只有 12 / 24 / 36 三个合法值。
##
## Fusion Pixel 12px 的字形画在 12px 网格上，在设计尺寸下轮廓点坐标全是整数。
## 只有整数倍字号能保住这个对齐；非整数倍会把轮廓点推到半像素上，而抗锯齿
## 是关的，于是笔画宽度在 1px / 2px 之间跳，密集汉字里细笔画甚至会整条消失。
## 实测（font_get_glyph_contours，"国"字 32 个轮廓点里偏离整数网格的点数）：
##     10px → 27   11px → 27   12px → 0    14px → 25   16px → 25
##     18px → 24   20px → 25   24px → 0    30px → 24   36px → 0
## 所以小字号统一用 12。要拉开层级就靠颜色（DIM / TEXT / TEXT_HI / WHITE）
## 和字间距（spaced_font），不要再动字号——动了就回到糊的状态。
##
## 换字号等于换字体：10px 网格的字体只在 10/20/30 上对齐，12px 网格的只在
## 12/24/36 上对齐。两者不能共用同一套字号常量，PIXEL_FONT_PATH 换哪个，
## 这里的三个数字就要跟着换。
const FS_TINY := 12
const FS_SMALL := 12
const FS_BODY := 12
const FS_BIG := 24
const FS_HUGE := 36


# ---------------------------------------------------------------- 字体

## 项目自带的像素字体。Fusion Pixel 12px，中文点阵，专为 12px 设计，
## 在 12 / 24 / 36 这种整数倍字号下最锐利。
## 同族的 10px 变体还在 assets/font 下（旧版用的），但 12px 网格的字号常量
## 喂给它只会全糊，不要混用。
const PIXEL_FONT_PATH := "res://assets/font/fusion-pixel-12px-proportional-zh_hans.ttf"


static func make_font() -> Font:
	var f: Font = load(PIXEL_FONT_PATH)
	if f is FontFile:
		var ff: FontFile = f
		# 像素字体必须关抗锯齿、关亚像素定位，否则每个笔画边缘都会糊出一圈灰
		ff.antialiasing = TextServer.FONT_ANTIALIASING_NONE
		ff.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
		ff.hinting = TextServer.HINTING_NONE
		ff.force_autohinter = false
		ff.multichannel_signed_distance_field = false
		return ff

	# 保底：万一资源被挪走，退回系统宋体（同样是点阵观感）
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray([
		"SimSun", "宋体", "NSimSun", "MS Gothic", "Microsoft YaHei", "sans-serif",
	])
	sf.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	sf.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	sf.hinting = TextServer.HINTING_NORMAL
	sf.force_autohinter = true
	sf.allow_system_fallback = true
	sf.multichannel_signed_distance_field = false
	return sf


## 带字间距的变体，用于小节标题那类"拉开一点"的文字。
static func spaced_font(base: Font, gap: int) -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = base
	fv.spacing_glyph = gap
	return fv


# ---------------------------------------------------------------- 样式盒

static func flat(bg: Color, border: Color = Color(0, 0, 0, 0), bw: int = 0,
		pad_h := 0, pad_v := 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(0)
	sb.anti_aliasing = false
	if bw > 0:
		sb.border_color = border
		sb.set_border_width_all(bw)
	sb.content_margin_left = pad_h
	sb.content_margin_right = pad_h
	sb.content_margin_top = pad_v
	sb.content_margin_bottom = pad_v
	return sb


static func flat_lr(bg: Color, border: Color, left: int, right: int,
		pad_h := 0, pad_v := 0) -> StyleBoxFlat:
	var sb := flat(bg, border, 0, pad_h, pad_v)
	sb.border_color = border
	sb.border_width_left = left
	sb.border_width_right = right
	return sb


static func empty(pad_h := 0, pad_v := 0) -> StyleBoxEmpty:
	var sb := StyleBoxEmpty.new()
	sb.content_margin_left = pad_h
	sb.content_margin_right = pad_h
	sb.content_margin_top = pad_v
	sb.content_margin_bottom = pad_v
	return sb


# ---------------------------------------------------------------- 主题

static func build_theme() -> Theme:
	var t := Theme.new()
	var font := make_font()

	t.default_font = font
	t.default_font_size = FS_BODY

	_theme_panels(t)
	_theme_buttons(t)
	_theme_labels(t)
	_theme_tabs(t)
	_theme_inputs(t)
	_theme_lists(t)
	_theme_code_edit(t)
	_theme_sliders(t)
	_theme_misc(t)
	return t


## 滑条。默认主题的轨道是圆角胶囊、滑块是圆形图标，和这里的直角黑白完全不搭，
## 所以轨道做成和 ProgressBar 同一种"凹槽"，滑块换成纯白方块。
##
## 注意轨道的粗细：Slider 是把轨道样式盒按**最小高度**居中画的
## （不是铺满控件高度），而样式盒的最小高度来自 content margin 与边框的较大者。
## 所以凹槽的厚度必须用 content margin 给（这里上下各 4 = 8px），
## 只写 custom_minimum_size 或者指望它被拉伸都只会得到一条 1px 的线。
static func _theme_sliders(t: Theme) -> void:
	t.set_stylebox("slider", "HSlider", flat(RAISED, LINE, 1, 0, 4))
	t.set_stylebox("grabber_area", "HSlider", flat(TEXT_HI, Color(0, 0, 0, 0), 0, 0, 4))
	t.set_stylebox("grabber_area_highlight", "HSlider",
		flat(WHITE, Color(0, 0, 0, 0), 0, 0, 4))
	t.set_icon("grabber", "HSlider", square_grabber(Vector2i(6, 14), WHITE))
	t.set_icon("grabber_highlight", "HSlider", square_grabber(Vector2i(6, 14), WHITE))
	t.set_icon("grabber_disabled", "HSlider", square_grabber(Vector2i(6, 14), DIM))
	t.set_constant("center_grabber", "HSlider", 1)


## 生成一个纯色方块贴图。滑块的形状来自图标而不是样式盒，
## 不生成一个的话默认主题会画一个圆角胶囊，破坏直角黑白的统一。
static func square_grabber(size: Vector2i, color: Color) -> ImageTexture:
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	img.fill(color)
	return ImageTexture.create_from_image(img)


## 代码补全弹框。默认主题是圆角浅色，和这里的直角黑白完全不搭。
static func _theme_code_edit(t: Theme) -> void:
	t.set_color("completion_background_color", "CodeEdit", RAISED)
	t.set_color("completion_selected_color", "CodeEdit", WHITE)
	t.set_color("completion_existing_color", "CodeEdit", Color(1, 1, 1, 0.10))
	t.set_color("completion_scroll_color", "CodeEdit", LINE_HI)
	t.set_color("completion_scroll_hovered_color", "CodeEdit", TEXT)
	t.set_color("completion_font_color", "CodeEdit", TEXT_HI)
	t.set_constant("completion_lines", "CodeEdit", 8)
	t.set_constant("completion_max_width", "CodeEdit", 42)
	t.set_constant("completion_scroll_width", "CodeEdit", 6)


static func _theme_panels(t: Theme) -> void:
	t.set_stylebox("panel", "PanelContainer", flat(PANEL, LINE, 1))
	t.set_stylebox("panel", "Panel", flat(PANEL, LINE, 1))
	t.set_stylebox("panel", "PopupPanel", flat(RAISED, LINE_HI, 1))
	t.set_stylebox("panel", "TabContainer", flat(PANEL, LINE, 1))


static func _theme_buttons(t: Theme) -> void:
	var types := ["Button", "OptionButton", "CheckBox", "MenuButton"]
	for ty in types:
		t.set_stylebox("normal", ty, flat(RAISED, LINE, 1, 10, 5))
		t.set_stylebox("hover", ty, flat(HOVER, LINE_WHITE, 1, 10, 5))
		t.set_stylebox("pressed", ty, flat(WHITE, WHITE, 1, 10, 5))
		t.set_stylebox("disabled", ty, flat(PANEL, LINE, 1, 10, 5))
		t.set_stylebox("focus", ty, empty(10, 5))
		t.set_color("font_color", ty, TEXT)
		t.set_color("font_hover_color", ty, WHITE)
		t.set_color("font_pressed_color", ty, BLACK)
		t.set_color("font_disabled_color", ty, Color("#3a3a3a"))
		t.set_color("font_focus_color", ty, WHITE)
		t.set_font_size("font_size", ty, FS_SMALL)


static func _theme_labels(t: Theme) -> void:
	t.set_color("font_color", "Label", TEXT)
	t.set_font_size("font_size", "Label", FS_BODY)
	t.set_color("default_color", "RichTextLabel", TEXT)
	t.set_font_size("normal_font_size", "RichTextLabel", FS_SMALL)
	t.set_stylebox("normal", "RichTextLabel", empty())


static func _theme_tabs(t: Theme) -> void:
	t.set_stylebox("panel", "TabContainer", flat(PANEL, LINE, 1))
	t.set_stylebox("tabbar_background", "TabContainer", flat(BG, Color(0, 0, 0, 0), 0))
	t.set_stylebox("tab_unselected", "TabContainer", flat(BG, LINE, 1, 14, 7))
	t.set_stylebox("tab_hovered", "TabContainer", flat(HOVER, LINE_HI, 1, 14, 7))
	# 选中页顶部一条 2px 白线，是 PRTS 最典型的"当前项"标记
	t.set_stylebox("tab_selected", "TabContainer",
		flat_lr(PANEL, LINE, 0, 0, 14, 7))
	var sel := t.get_stylebox("tab_selected", "TabContainer") as StyleBoxFlat
	sel.border_width_top = 2
	sel.border_color = LINE
	sel.border_blend = false
	t.set_stylebox("tab_selected", "TabContainer", sel)
	t.set_color("font_unselected_color", "TabContainer", DIM)
	t.set_color("font_hovered_color", "TabContainer", TEXT_HI)
	t.set_color("font_selected_color", "TabContainer", WHITE)
	t.set_font_size("font_size", "TabContainer", FS_SMALL)


static func _theme_inputs(t: Theme) -> void:
	t.set_stylebox("normal", "LineEdit", flat(RAISED, LINE, 1, 8, 4))
	t.set_stylebox("focus", "LineEdit", flat(RAISED, WHITE, 1, 8, 4))
	t.set_stylebox("read_only", "LineEdit", flat(PANEL, LINE, 1, 8, 4))
	t.set_color("font_color", "LineEdit", TEXT_HI)
	t.set_color("font_placeholder_color", "LineEdit", DIM)
	t.set_color("caret_color", "LineEdit", WHITE)
	t.set_color("selection_color", "LineEdit", Color("#444444"))
	t.set_font_size("font_size", "LineEdit", FS_SMALL)

	t.set_stylebox("normal", "TextEdit", flat(BG, LINE, 1))
	t.set_stylebox("focus", "TextEdit", flat(BG, LINE_HI, 1))
	t.set_stylebox("read_only", "TextEdit", flat(BG, LINE, 1))
	t.set_color("font_color", "TextEdit", TEXT_HI)
	t.set_color("caret_color", "TextEdit", WHITE)
	t.set_color("selection_color", "TextEdit", Color("#3a3a3a"))
	t.set_color("current_line_color", "TextEdit", Color("#101010"))
	t.set_color("line_number_color", "TextEdit", Color("#454545"))
	t.set_color("font_size", "TextEdit", FS_SMALL)
	t.set_font_size("font_size", "TextEdit", FS_SMALL)


static func _theme_lists(t: Theme) -> void:
	t.set_stylebox("panel", "ItemList", flat(BG, LINE, 1))
	t.set_stylebox("focus", "ItemList", empty())
	t.set_stylebox("cursor", "ItemList", empty())
	t.set_stylebox("cursor_unfocused", "ItemList", empty())
	t.set_stylebox("selected", "ItemList", flat(WHITE, WHITE, 0))
	t.set_stylebox("selected_focus", "ItemList", flat(WHITE, WHITE, 0))
	t.set_stylebox("hovered", "ItemList", flat(HOVER, Color(0, 0, 0, 0), 0))
	t.set_color("font_color", "ItemList", TEXT)
	t.set_color("font_selected_color", "ItemList", BLACK)
	t.set_color("font_hovered_color", "ItemList", WHITE)
	t.set_font_size("font_size", "ItemList", FS_SMALL)

	t.set_stylebox("panel", "PopupMenu", flat(RAISED, LINE_HI, 1))
	t.set_stylebox("hover", "PopupMenu", flat(WHITE, WHITE, 0))
	t.set_color("font_color", "PopupMenu", TEXT)
	t.set_color("font_hover_color", "PopupMenu", BLACK)
	t.set_color("font_separator_color", "PopupMenu", DIM)
	t.set_font_size("font_size", "PopupMenu", FS_SMALL)


static func _theme_misc(t: Theme) -> void:
	t.set_stylebox("background", "ProgressBar", flat(RAISED, LINE, 1))
	t.set_stylebox("fill", "ProgressBar", flat(TEXT_HI, Color(0, 0, 0, 0), 0))
	t.set_color("font_color", "ProgressBar", BLACK)
	t.set_font_size("font_size", "ProgressBar", FS_TINY)

	t.set_stylebox("scroll", "VScrollBar", flat(BG, Color(0, 0, 0, 0), 0))
	t.set_stylebox("grabber", "VScrollBar", flat(LINE, Color(0, 0, 0, 0), 0))
	t.set_stylebox("grabber_highlight", "VScrollBar", flat(LINE_HI, Color(0, 0, 0, 0), 0))
	t.set_stylebox("grabber_pressed", "VScrollBar", flat(TEXT, Color(0, 0, 0, 0), 0))
	t.set_stylebox("scroll", "HScrollBar", flat(BG, Color(0, 0, 0, 0), 0))
	t.set_stylebox("grabber", "HScrollBar", flat(LINE, Color(0, 0, 0, 0), 0))
	t.set_stylebox("grabber_highlight", "HScrollBar", flat(LINE_HI, Color(0, 0, 0, 0), 0))
	t.set_stylebox("grabber_pressed", "HScrollBar", flat(TEXT, Color(0, 0, 0, 0), 0))

	t.set_stylebox("separator", "HSeparator", flat(LINE, Color(0, 0, 0, 0), 0))
	t.set_constant("separation", "HSeparator", 1)
	t.set_stylebox("separator", "VSeparator", flat(LINE, Color(0, 0, 0, 0), 0))
	t.set_constant("separation", "VSeparator", 1)

	t.set_constant("separation", "HBoxContainer", 6)
	t.set_constant("separation", "VBoxContainer", 6)
	t.set_constant("h_separation", "GridContainer", 6)
	t.set_constant("v_separation", "GridContainer", 6)


# ---------------------------------------------------------------- 控件工厂

static func label(text: String, size := FS_BODY, color := TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


static func dim_label(text: String, size := FS_TINY) -> Label:
	return label(text, size, DIM)


## 小节标题：左侧一条白色竖杠 + 标题 + 右侧延伸到底的细线
static func section(text: String, base_font: Font = null) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var tick := ColorRect.new()
	tick.color = WHITE
	tick.custom_minimum_size = Vector2(2, 12)
	tick.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(tick)

	var l := label(text, FS_SMALL, TEXT_HI)
	if base_font != null:
		l.add_theme_font_override("font", spaced_font(base_font, 2))
	row.add_child(l)

	var rule := ColorRect.new()
	rule.color = LINE
	rule.custom_minimum_size = Vector2(0, 1)
	rule.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rule.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(rule)
	return row


## 键值行：左键右值，值默认右对齐
static func kv(key: String, value: String, value_color := TEXT_HI) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var k := label(key, FS_SMALL, DIM)
	k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(k)
	var v := label(value, FS_SMALL, value_color)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(v)
	return row


static func spacer() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return c


static func hline() -> ColorRect:
	var r := ColorRect.new()
	r.color = LINE
	r.custom_minimum_size = Vector2(0, 1)
	return r


static func vline() -> ColorRect:
	var r := ColorRect.new()
	r.color = LINE
	r.custom_minimum_size = Vector2(1, 0)
	r.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return r


static func button(text: String, min_width := 0) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	if min_width > 0:
		b.custom_minimum_size = Vector2(min_width, 0)
	return b


static func pad(inner: Control, h: int, v: int) -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", h)
	m.add_theme_constant_override("margin_right", h)
	m.add_theme_constant_override("margin_top", v)
	m.add_theme_constant_override("margin_bottom", v)
	m.add_child(inner)
	return m


static func panel(inner: Control, h := 10, v := 8) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", flat(PANEL, LINE, 1))
	p.add_child(pad(inner, h, v))
	return p


## 千分位格式化，狗狗币数额用
static func comma(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return ("-" if n < 0 else "") + out


## 带一位小数的千分位格式化。
## 货币读数统一用这个形状（Ð1,234.0），和电费行 "Ð%.1f" 保持一致——
## 界面上两个钱数一个带小数一个不带，看起来像两种单位。
static func comma1(v: float) -> String:
	var a := absf(v)
	var whole := int(floor(a))
	var frac := int(round((a - float(whole)) * 10.0))
	# 四舍五入可能把 9.96 推到 10.0，得进位，否则会印出 ".10"
	if frac >= 10:
		whole += 1
		frac = 0
	return ("-" if v < 0.0 else "") + comma(whole) + ".%d" % frac


## 只在颜色真的变化时才写主题覆盖。
##
## add_theme_color_override 会触发 NOTIFICATION_THEME_CHANGED 并让控件重新解析
## 主题、重绘。运行中每帧无条件调用是纯浪费——实测这是脚本侧最大的单项开销。
## cache 由调用方持有，key 用稳定的字符串。
static func set_color_cached(target: Control, key: String, color: Color,
		cache: Dictionary) -> void:
	if cache.has(key) and cache[key] == color:
		return
	cache[key] = color
	target.add_theme_color_override("font_color", color)

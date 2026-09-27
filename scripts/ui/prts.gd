class_name Prts
extends RefCounted
## PRTS 风格的黑白像素主题。
##
## PRTS 是世界观里那套 AI 数据库系统的名字——玩家是它底下的一个 agent，
## 分管排序优化单元。这套主题就是它的界面：冷、直角、只有黑白灰。
## 界面文案里出现 PRTS 的地方都是"系统在说话"（开机横幅、报错弹窗）。
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

## 字号只有 12 / 24 / 36 三个合法值。要拉开层级就靠颜色（DIM / TEXT / TEXT_HI /
## WHITE）和字间距（spaced_font），不要再动字号——动了就回到糊的状态。
##
## 这不是审美选择，是点阵字体的硬约束：Fusion Pixel 12px 的字形**画在 12px 网格上**，
## 设计尺寸下轮廓点坐标全是整数，每个笔画正好落在像素格上。只有整数倍字号能保住
## 这个对齐；非整数倍会把轮廓点推到半像素上，而抗锯齿是关的，于是笔画宽度在
## 1px / 2px 之间跳，密集汉字里细笔画甚至会整条消失。实测（font_get_glyph_contours，
## "国"字 32 个轮廓点里偏离整数网格的点数）：
##     10px → 27   11px → 27   12px → 0    14px → 25   16px → 25
##     18px → 24   20px → 25   24px → 0    30px → 24   36px → 0
##
## 换字号等于换字体：10px 网格的变体只在 10/20/30 上对齐，12px 网格的只在
## 12/24/36 上对齐。两者不能共用同一套字号常量，UI_FONT_PATH 换哪个，
## 这里三个数字就要跟着换。
##
## 12 是**布局基准**：按钮宽度、顶栏指标格、控制行的余量全是按它量出来的，
## 改它等于把界面重排一遍（每改一次都要重跑一遍余量测量）。
## 24 / 36 只用在狗狗币那种大号读数上。
const FS_TINY := 12
const FS_SMALL := 12
const FS_BODY := 12
const FS_BIG := 24
const FS_HUGE := 36


# ---------------------------------------------------------------- 字体

## 界面字体：Fusion Pixel 12px，中文点阵字体，**随项目分发**（assets/font 下）。
##
## 为什么是点阵字体而不是轮廓字体——两条路都实测过，结论是硬约束：
## 汉字等宽，笔画数不影响格子大小，所以复杂字能不能看清，只取决于"字面高度够不够
## 把笔画和间隙分开"。实测「重」有 7 条横画 + 6 道间隙 = 13 个特征要各占至少
## 1 像素，而它的字面高度是：
##     12px → 10.8px   13 > 10.8，分不开
##     14px → 12.6px   13 > 12.6，分不开（间隙最深只能掉到峰值的 30%，肉眼就是没间隙）
##     16px → 15.0px   13 < 15，刚够，但上半部仍会粘连（间隙掉到 12%）
##     20px → 18.0px   到这里才真正笔画分明
## 轮廓字体要 18~20px 才能解开「重」，而这个界面是 12~16px 的密度，塞不下。
## 点阵字体绕开了这个不等式：字形是**人手按像素画的**，哪个像素亮由设计者决定，
## 12px 下「重」的横画本来就是分开的。代价是只有 12/24/36 三个合法字号
## （见上面 FS_BODY 的说明），笔画也比轮廓字体粗、方。
##
## 用自带文件而不是系统字体：系统上装没装、装的是哪个版本都不由我们说了算，
## 而字宽会直接影响布局（下面一堆固定宽度都是按它量出来的）。
##
## 试过又换掉的字体（记在这里，免得下次再走一遍）：
##   · 思源黑体（Source Han Sans）可变字体——平滑、大字号好看，但小字号解不开复杂字。
##     文件还留着，见下面的 SANS_FONT_PATH。
##   · 代码单独用等宽字体（Cascadia Mono + 宋体）——列对齐更好，但 12px 下宋体的
##     中文注释开着抗锯齿会发虚。系统字体，不用留文件。
##   · 同族的 Fusion Pixel 10px 变体（旧版用的）——已经删掉了，它只在 10/20/30
##     上对齐，和现在的 12px 网格不通用。
const UI_FONT_PATH := "res://assets/font/fusion-pixel-12px-proportional-zh_hans.ttf"
## 上面那套轮廓字体，想换回去就让 body_font() 去 load 它（记得连 FS_ 常量一起换）
const SANS_FONT_PATH := "res://assets/font/SourceHanSansCN-VF.ttf"

## 点阵字体缺字时兜底用的系统字体（生僻字、玩家自己起的怪名字）。
## 也要关抗锯齿：兜底的那几个字要是平滑的，和周围一圈点阵字格格不入。
const UI_FONT_FAMILIES := ["SimSun", "宋体", "NSimSun", "Microsoft YaHei", "sans-serif"]

static var _body_font: Font = null


static func make_font() -> Font:
	return body_font()


## 正文字体（主题默认字体）。
static func body_font() -> Font:
	if _body_font == null:
		_body_font = _pixel_font()
	return _body_font


## 大号读数用的字体。点阵字体只有一套字形，没有第二档字重可换，所以就是正文那份。
## 留着这个函数是为了让调用方不用关心界面字体到底有几档。
static func display_font() -> Font:
	return body_font()


## 界面字：Fusion Pixel 12px 点阵字体。
##
## 渲染设置全是"别动它"：
##   · 抗锯齿关——点阵字体的笔画边缘本来就是硬的，开抗锯齿会在每个笔画周围
##     糊出一圈灰，那圈灰正是"发虚"的来源。
##   · hinting 关——hinting 是给轮廓字体做网格对齐用的，对已经画在网格上的
##     点阵字形只会帮倒忙。
##   · 亚像素定位关——每个字形都从整像素开始画，字距不会有半像素的抖动。
##
## oversampling 留 0（= 跟随视口）：这个字体在 12/24/36 上都是整数网格，所以
## 窗口按整数倍放大时，让引擎按 24/36 光栅化仍然是锐利的点阵；反过来，在这里
## 写死一个非整数倍、或者让画布去拉伸一份 12px 的光栅，边缘就会糊。
## 这也是**不能**沿用轮廓字体那套超采样（FONT_OVERSAMPLING）的原因：
## 2 倍超采样等于对点阵字形做 2×2 均值滤波，正好把硬边缘抹平。
static func _pixel_font() -> Font:
	# 抗锯齿 / 亚像素定位 / hinting 是 **FontFile** 上的属性，FontVariation 没有这几个
	# （踩过一次：设在 FontVariation 上会报 "Invalid assignment of property 'antialiasing'"，
	# 结果是字体整个变 null、界面上所有字消失）。所以设在 base 上，
	# load 带缓存，两次拿到的是同一个对象。
	var base: FontFile = load(UI_FONT_PATH)
	base.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	base.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	base.hinting = TextServer.HINTING_NONE
	base.force_autohinter = false
	base.multichannel_signed_distance_field = false
	base.oversampling = 0.0
	# 缺字（生僻字、玩家自己起的怪名字）交给系统字体，别显示成方框
	var fb := SystemFont.new()
	fb.font_names = PackedStringArray(UI_FONT_FAMILIES)
	fb.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	fb.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	fb.hinting = TextServer.HINTING_NORMAL
	fb.force_autohinter = true
	fb.multichannel_signed_distance_field = false
	base.fallbacks = [fb]
	return base


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
	# TooltipPanel 是 popup 提示自己的类型（和 PopupPanel 是两套）。不写它的话，
	# 提示框会去用默认主题那份——圆角、浅色，鼠标停在文件行上时一眼就看得出来。
	# 之前只有 PopupPanel 被覆盖，靠"找不到 TooltipPanel 就退回类名 PopupPanel"兜着，
	# 但那是巧合，不如写清楚。
	t.set_stylebox("panel", "TooltipPanel", flat(RAISED, LINE_HI, 1))
	t.set_color("font_color", "TooltipLabel", TEXT_HI)
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
		# 悬停+按下也是反白状态，文字得跟着变黑，否则白底上还是白字
		t.set_color("font_hover_pressed_color", ty, BLACK)
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
	t.set_stylebox("tab_disabled", "TabContainer", flat(PANEL, LINE, 1, 14, 7))
	# 键盘焦点框一律不要：这套界面不用焦点环表示位置（按钮那边也是 empty）
	t.set_stylebox("tab_focus", "TabContainer", empty(14, 7))
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
	# "同名变量全部高亮"的底色（光标停在变量名上时全文里同名的都亮）。
	# 要比选中色 #3a3a3a 更暗一档：真去框选一段时，选中范围才是最强的那一层。
	# 默认主题那支是淡青色，在这套黑白灰里格外扎眼。
	t.set_color("word_highlighted_color", "TextEdit", Color("#242424"))
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
	# "选中项被鼠标指着"是**另外两个**样式盒，名字叫 hovered_selected /
	# hovered_selected_focus。不写它们的话会落到默认主题那份——半透明白、圆角，
	# 于是光标停在选中的文件行上时，那一行会变成一块带圆角的灰白方块。
	# 这里跟 selected 保持一致：选中的行本来就靠反白表示当前项，
	# 悬停没必要再叠一层（阶段页的 _on_row_hover 也是这么处理的）。
	t.set_stylebox("hovered_selected", "ItemList", flat(WHITE, WHITE, 0))
	t.set_stylebox("hovered_selected_focus", "ItemList", flat(WHITE, WHITE, 0))
	t.set_color("font_color", "ItemList", TEXT)
	t.set_color("font_selected_color", "ItemList", BLACK)
	t.set_color("font_hovered_color", "ItemList", WHITE)
	# 同上：反白行上的文字必须跟着变黑，默认那份是浅色
	t.set_color("font_hovered_selected_color", "ItemList", BLACK)
	t.set_color("guide_color", "ItemList", LINE)
	t.set_color("scroll_hint_color", "ItemList", LINE_HI)
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
	t.set_stylebox("scroll_focus", "VScrollBar", flat(BG, Color(0, 0, 0, 0), 0))
	t.set_stylebox("grabber", "VScrollBar", flat(LINE, Color(0, 0, 0, 0), 0))
	t.set_stylebox("grabber_highlight", "VScrollBar", flat(LINE_HI, Color(0, 0, 0, 0), 0))
	t.set_stylebox("grabber_pressed", "VScrollBar", flat(TEXT, Color(0, 0, 0, 0), 0))
	t.set_stylebox("scroll", "HScrollBar", flat(BG, Color(0, 0, 0, 0), 0))
	t.set_stylebox("scroll_focus", "HScrollBar", flat(BG, Color(0, 0, 0, 0), 0))
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
	# 这里原来会给大号读数换一档更细的字重（轮廓字体时代的事）。点阵字体只有
	# 一套字形，换不了，所以不再挂 font 覆盖——少一次 add_theme_font_override
	# 就少一次 NOTIFICATION_THEME_CHANGED 重解析（见 set_color_cached 的说明）。
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


## 指定颜色的 1px 横线。hline() 固定用主题的 LINE，报错弹窗那种红分隔线用这个。
static func rule(color: Color) -> ColorRect:
	var r := ColorRect.new()
	r.color = color
	r.custom_minimum_size = Vector2(0, 1)
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

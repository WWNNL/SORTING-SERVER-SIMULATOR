class_name TitleScreen
extends Control
## 标题屏：进程打开后的第一屏，"系统之外"的最外层。
##
## 画面是一间渲染出来的服务器机厅（Blender 建模渲染的两张底图，见
## assets/title/）——玩家接下来要接进去的就是这批机器，故事从"看见机房"
## 开始。鼠标是对焦环：指到哪儿，哪儿清晰，别处化开（shader 里的景深混合）；
## 整幅图还会跟着鼠标轻微反向漂移（视差），机厅的进深才立得住。
##
## 菜单只有两项，登入 / 退出：
##   登入  翻块退场到全黑，交棒给开机自检（BootSequence 从黑屏起步，接得上）。
##   退出  直接退出程序。标题屏没有可以丢的进度（存档实时落盘），
##         不做二次确认——多按一次才退得到的标题屏只会让人觉得卡。
##
## 与接入屏（LoginScreen）同一套视觉语言：硬切不淡入淡出、入场/退场都是
## 整屏横向翻块、元素按时刻落下。这是"还没进系统"的最外层，z_index 700，
## 压住接入屏（600）、开机自检（500）、ESC 菜单（400）与报错弹窗（300）。
##
## 没有声音：这一屏是静的，和接入屏同一个理由——第一声应该是开机自检的低频嗡鸣。

## 按了「登入」，退场也播完了。Main 接这个信号同步挂上开机自检。
signal login_confirmed

# ---------------------------------------------------------------- 时间轴

## 入场翻块：每条带子露出的基准时刻（之后逐条错开）
const T_FLIP_IN := 0.30
## 各元素落下的时刻（硬切）。都是从 t=0 起算的绝对时刻，
## 所以它们必须一个比一个晚、且都晚于第一块翻开的时刻。
const T_BRAND := 0.52
const T_TITLE := 0.68
const T_MENU := 0.84
const T_FOOT := 1.00

## 翻块条数与高度占比。和接入屏同一种"不等分才像排版"的思路，比例略错开——
## 两段转场摆在一起时才不像同一张图在重播。加起来必须是 1.0，不能留缝。
const BAND_COUNT := 5
const BAND_RATIOS := [0.18, 0.24, 0.30, 0.16, 0.12]
## 相邻条带翻开的间隔（入场/退场共用）
const BAND_GAP := 0.05

## 退场翻块基准时长 + 末尾留白。退场自上而下翻（和入场反方向，
## "又发生了一件事"）；翻完停一小拍再交棒，黑屏落定才有"关掉了"的分量。
const T_FLIP_OUT := 0.30
const T_OUT_HOLD := 0.10

## 鼠标焦点的平滑速度（1/秒的混合系数基准）。太小跟手发黏，太大视差发飘。
const FOCUS_SMOOTH := 5.0
## 对焦点的待机游移幅度（uv）。鼠标不动时画面也不是死的——
## 像有人还扶着云台，幅度压到几乎察觉不到才对。
const SWAY := Vector2(0.012, 0.009)

## 单帧最多按多少秒推进（和接入屏/自检同一个规矩：宁慢勿跳）。
const MAX_STEP_DELTA := 0.10

enum { ST_IN, ST_OUT }

var _state := ST_IN
var _t := 0.0
var _finished := false
## 鼠标焦点的平滑值（uv）与目标值
var _focus := Vector2(0.5, 0.5)
var _focus_target := Vector2(0.5, 0.5)
## 真的收到过鼠标移动才跟随鼠标。测试（headless 里鼠标永远在原点）
## 和"还没动过鼠标的开局"都靠 set_focus_target / 初始中心顶着。
var _mouse_seen := false
## 菜单当前选中项（键盘 ↑↓ / 鼠标悬停都会改它）
var _sel := 0

var _mat: ShaderMaterial = null
var _bg: TextureRect = null
var _fader: Control = null
var _ui: Control = null
var _blocks := {}
var _buttons: Array = []
var _ticks: Array = []
var _readout: Label = null
var _cursor: ColorRect = null
var _spaced_font: FontVariation = null

# ---------------------------------------------------------------- 生命周期

func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# 压住接入屏（600）及以下：标题屏是"系统之外"的最外层
	z_index = 700
	mouse_filter = Control.MOUSE_FILTER_STOP


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	if theme == null:
		theme = Prts.build_theme()
	_spaced_font = Prts.spaced_font(Prts.body_font(), 6)
	_build()
	set_process(true)


## 推进时间轴。_process 只是转调它，测试直接按秒推进，不用等真实帧。
func advance(delta: float) -> void:
	if _finished:
		return
	_t += delta
	if _state == ST_OUT and _t >= out_total():
		_finish()
		return
	_sync_timeline()
	_follow_mouse(delta)
	if _fader != null:
		# 翻块层跟着时间轴走：入场按 t_in 逐条揭底，退场按 t_out 逐条盖上
		if _state == ST_OUT:
			_fader.t_out = _t
		else:
			_fader.t_in = _t
		_fader.queue_redraw()


func _process(delta: float) -> void:
	advance(minf(delta, MAX_STEP_DELTA))


func is_finished() -> bool:
	return _finished


func state() -> int:
	return _state


func elapsed() -> float:
	return _t


# ================================================================ 界面搭建

func _build() -> void:
	# ---- 背景：机厅渲染图 + 景深/视差 shader
	_bg = TextureRect.new()
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	# expand + keep aspect covered：窗口比例被 stretch 拉开时裁边不变形
	_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_bg.texture = load("res://assets/title/server_hall_sharp.png")
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://scripts/ui/title_bg.gdshader")
	var blur: Texture2D = load("res://assets/title/server_hall_blur.png")
	if blur != null:
		_mat.set_shader_parameter("blur_tex", blur)
	_bg.material = _mat
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	# ---- 全屏四角角标：PRTS 的画框
	PrtsFrame.attach(self, 18, 2, Prts.FRAME_IDLE, false)

	# ---- 前景 UI
	_ui = Control.new()
	_ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_ui)

	# 左上：品牌。和接入屏同一个牌位，只是底换成了机厅。
	var brand := VBoxContainer.new()
	brand.add_theme_constant_override("separation", 2)
	brand.position = Vector2(72.0, 60.0)
	brand.add_child(Prts.label("PRTS", Prts.FS_HUGE, Prts.WHITE))
	brand.add_child(Prts.dim_label("SORTING SERVER SIMULATOR"))
	_ui.add_child(brand)
	_blocks["brand"] = brand

	# 左中：小节线 + 游戏名 + 署名 + 菜单 + 提示。纵向锚在 40% 高度上，
	# 窗口比例被 stretch 拉开时跟着中线走，不写死像素。
	var block := VBoxContainer.new()
	block.add_theme_constant_override("separation", 10)
	block.anchor_left = 0.0
	block.anchor_top = 0.40
	block.anchor_right = 0.0
	block.anchor_bottom = 0.40
	block.offset_left = 72.0
	block.offset_right = 72.0 + ITEM_W
	_ui.add_child(block)
	_blocks["title"] = block

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	var tick := ColorRect.new()
	tick.color = Prts.WHITE
	tick.custom_minimum_size = Vector2(3, 20)
	tick.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(tick)
	head.add_child(Prts.dim_label("外部接入终端 // ACCESS TERMINAL"))
	block.add_child(head)

	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 10)
	var big := Prts.label("能工智人 · 数据库", Prts.FS_HUGE, Prts.WHITE)
	big.add_theme_font_override("font", _spaced_font)
	name_row.add_child(big)
	block.add_child(name_row)
	block.add_child(Prts.dim_label("排序服务器模拟 · 排序单元 SORT-01"))

	# 菜单：登入 / 退出。间距拉开让每一项都站得住。
	block.add_child(_make_gap(26.0))
	var menu := VBoxContainer.new()
	menu.add_theme_constant_override("separation", 10)
	for i in ITEM_LABELS.size():
		menu.add_child(_make_item(i))
	block.add_child(menu)
	_blocks["menu"] = menu

	# 提示行放进同一个块里，间距由布局排，不手写偏移
	var hint := Prts.dim_label("↑ ↓ 选择　·　回车确认　·　鼠标直接点")
	block.add_child(_make_gap(14.0))
	block.add_child(hint)
	_blocks["hint"] = hint

	# 左下：待机状态行 + 块状光标（全屏唯一的"呼吸"，说明终端活着）
	var status := HBoxContainer.new()
	status.add_theme_constant_override("separation", 8)
	status.anchor_left = 0.0
	status.anchor_top = 1.0
	status.anchor_right = 0.0
	status.anchor_bottom = 1.0
	status.offset_left = 72.0
	status.offset_top = -64.0
	status.offset_right = 72.0
	status.offset_bottom = -64.0
	_cursor = ColorRect.new()
	_cursor.color = Prts.WHITE
	_cursor.custom_minimum_size = Vector2(9, 14)
	_cursor.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	status.add_child(_cursor)
	status.add_child(_shadowed(Prts.dim_label("PRTS 控制台待机 // 等待接入指令")))
	_ui.add_child(status)
	_blocks["status"] = status

	# 右下：相机读数（跟着视差走，让"镜头在动"变得可读）+ 版本署名
	var readout_box := VBoxContainer.new()
	readout_box.add_theme_constant_override("separation", 2)
	readout_box.anchor_left = 1.0
	readout_box.anchor_top = 1.0
	readout_box.anchor_right = 1.0
	readout_box.anchor_bottom = 1.0
	readout_box.offset_left = -372.0
	readout_box.offset_top = -84.0
	readout_box.offset_right = -72.0
	readout_box.offset_bottom = -84.0
	_readout = _shadowed(Prts.dim_label("CAM·014   X +0.00   Y +0.00"))
	_readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_readout.custom_minimum_size = Vector2(300, 0)
	readout_box.add_child(_readout)
	var ver := _shadowed(Prts.dim_label("PRTS OS 0.1 · 排序单元 SORT-01"))
	ver.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	ver.custom_minimum_size = Vector2(300, 0)
	readout_box.add_child(ver)
	_ui.add_child(readout_box)
	_blocks["readout"] = readout_box

	# ---- 翻块层：入场/退场都画在这里，必须在所有孩子之上
	_fader = Fader.new()
	_fader.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fader.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fader)

	_sync_timeline()
	_apply_sel()


## 菜单的两项。文案两字之间留一个空格（和 ESC 菜单的「设 置」同一种排法）。
const ITEM_LABELS := ["登 入", "退 出"]
const ITEM_W := 300.0
const ITEM_H := 46.0


func _make_item(i: int) -> Control:
	var b := Prts.button(ITEM_LABELS[i])
	b.custom_minimum_size = Vector2(ITEM_W, ITEM_H)
	b.add_theme_font_size_override("font_size", Prts.FS_BIG)
	b.add_theme_font_override("font", _spaced_font)
	b.pressed.connect(_on_item_pressed.bind(i))
	b.mouse_entered.connect(_on_item_hover.bind(i))
	_buttons.append(b)
	var t := ColorRect.new()
	t.color = Prts.WHITE
	t.custom_minimum_size = Vector2(4, ITEM_H - 16.0)
	t.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	t.visible = false
	_ticks.append(t)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 0)
	row.add_child(t)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(b)
	# HBox 自己不吃鼠标，悬停判定交给按钮
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return row


func _make_gap(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c


## 压在照片底子上的角落文字：加一圈 1px 硬边黑投影。
## 点阵字体本来就是硬边，投影跟着硬，不会糊成一团灰。
func _shadowed(l: Label) -> Label:
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	return l


# ================================================================ 选择与确认

## 键盘/鼠标共用的选中态。选中项整块反白 + 左侧一条白杠——
## 反白是这套主题的"当前项"，白杠只是给它多一个落点。
func select(i: int) -> void:
	_sel = clampi(i, 0, ITEM_LABELS.size() - 1)
	_apply_sel()


func select_next() -> void:
	select((_sel + 1) % ITEM_LABELS.size())


func select_prev() -> void:
	select((_sel - 1 + ITEM_LABELS.size()) % ITEM_LABELS.size())


func selected() -> int:
	return _sel


func _on_item_hover(i: int) -> void:
	if _state == ST_IN:
		select(i)


func _on_item_pressed(i: int) -> void:
	if _state != ST_IN:
		return
	select(i)
	confirm()


## 确认当前项。登入走退场交棒；退出直接结束进程。
func confirm() -> void:
	if _state != ST_IN or _t < ready_at():
		return
	if _sel == 0:
		_state = ST_OUT
		_t = 0.0
		_ui.visible = false
	else:
		get_tree().quit()


## 测试与脚本用：不等 ready_at 直接走登入退场。
func confirm_login_for_test() -> void:
	if _state != ST_IN:
		return
	_sel = 0
	_state = ST_OUT
	_t = 0.0
	_ui.visible = false


func _apply_sel() -> void:
	for i in _buttons.size():
		var b: Button = _buttons[i]
		var on := i == _sel
		(_ticks[i] as ColorRect).visible = on
		if on:
			b.add_theme_stylebox_override("normal", Prts.flat(Prts.WHITE, Prts.WHITE, 1))
			b.add_theme_color_override("font_color", Prts.BLACK)
			b.add_theme_color_override("font_hover_color", Prts.BLACK)
		else:
			b.remove_theme_stylebox_override("normal")
			b.remove_theme_color_override("font_color")
			b.remove_theme_color_override("font_hover_color")


# ================================================================ 输入

## 键盘：↑↓/WS 选择，回车/空格确认。标题屏是最外层，键都归它；
## 鼠标事件不碰——按钮自己接。菜单落定（T_MENU 之后）才认输入，
## 不然入场翻块还没走完就能盲选，选了个看不见的东西。
func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_mouse_seen = true
	if _state != ST_IN or _t < ready_at() or not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if k.echo or not k.pressed:
		return
	match k.keycode:
		KEY_UP, KEY_W:
			select_prev()
			get_viewport().set_input_as_handled()
		KEY_DOWN, KEY_S:
			select_next()
			get_viewport().set_input_as_handled()
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			confirm()
			get_viewport().set_input_as_handled()


# ================================================================ 鼠标焦点

## 测试与脚本用：直接给定对焦目标（uv），跳过取鼠标。
func set_focus_target(uv: Vector2) -> void:
	_focus_target = Vector2(clampf(uv.x, 0.0, 1.0), clampf(uv.y, 0.0, 1.0))


func focus() -> Vector2:
	return _focus


## 对焦点朝目标平滑过去，再加一点待机游移，一起喂给 shader。
func _follow_mouse(delta: float) -> void:
	if _state == ST_IN and _mouse_seen:
		_focus_target = Vector2(
			clampf(get_global_mouse_position().x / maxf(get_viewport_rect().size.x, 1.0), 0.0, 1.0),
			clampf(get_global_mouse_position().y / maxf(get_viewport_rect().size.y, 1.0), 0.0, 1.0))
	var k := clampf(delta * FOCUS_SMOOTH, 0.0, 1.0)
	_focus = _focus.lerp(_focus_target, k)
	var sway := Vector2(sin(_t * 0.10), cos(_t * 0.073)) * SWAY
	if _mat != null:
		_mat.set_shader_parameter("focus", _focus + sway)
	if _readout != null:
		var d := _focus - Vector2(0.5, 0.5)
		var txt := "CAM·014   X %+.2f   Y %+.2f" % [d.x * 2.0, d.y * 2.0]
		if _readout.text != txt:
			_readout.text = txt


# ================================================================ 时间轴（纯函数）

## 菜单可以接受输入的时刻：最后一块翻完、菜单落下之后。
static func ready_at() -> float:
	return maxf(T_MENU, in_total())


## 入场第 i 条带露出的时刻（自上而下）。
static func in_band_time(i: int) -> float:
	return T_FLIP_IN + float(i) * BAND_GAP


## 退场第 i 条带盖上的时刻（自下而上，方向和入场相反）。
static func out_band_time(i: int) -> float:
	return T_FLIP_OUT + float(BAND_COUNT - 1 - i) * BAND_GAP


static func in_total() -> float:
	return in_band_time(BAND_COUNT - 1)


## 退场走完（可以交棒）的时刻：翻块 + 收尾停拍。
static func out_total() -> float:
	return out_band_time(0) + T_OUT_HOLD


## 屏幕横向切成几条带。入场/退场翻的就是它们。
## 不等分才像排版（和接入屏同一条审美），加起来必须是 1.0。
static func band_rects(w: float, h: float) -> Array:
	var out: Array = []
	var y := 0.0
	for r in BAND_RATIOS:
		var bh := h * float(r)
		out.append(Rect2(0.0, y, w, bh))
		y += bh
	return out


# ---------------------------------------------------------------- 内部同步

## 按时刻切换各元素的可见性（硬切，不淡入）。退场一开始整块 UI 直接藏，
## 翻块盖上来的时候底下不该再有东西闪。
func _sync_timeline() -> void:
	if _ui == null:
		return
	if _state == ST_OUT:
		_ui.visible = false
		return
	_blocks["brand"].visible = _t >= T_BRAND
	_blocks["title"].visible = _t >= T_TITLE
	_blocks["menu"].visible = _t >= T_MENU
	_blocks["hint"].visible = _t >= T_MENU
	_blocks["status"].visible = _t >= T_FOOT
	_blocks["readout"].visible = _t >= T_FOOT
	if _cursor != null:
		# 1.1 秒一个周期的慢闪：像终端待机，不像在催人
		_cursor.visible = fmod(_t, 1.1) < 0.75


func _finish() -> void:
	if _finished:
		return
	_finished = true
	login_confirmed.emit()
	# Main 在信号里同步挂开机自检（黑屏交黑屏，晚一帧会闪出主界面），这里自己退场
	queue_free()


# ================================================================ 翻块层

class Fader:
	extends Control
	## 入场/退场的整屏翻块。不持主屏引用，靠每帧喂时刻——测试里也可以单喂。
	## t_in < 0 表示入场已走完不再画；t_out >= 0 表示退场进行中。

	var t_in := -1.0
	var t_out := -1.0

	func _draw() -> void:
		var w := size.x
		var h := size.y
		if w < 64.0 or h < 64.0:
			return
		var rects := TitleScreen.band_rects(w, h)
		if t_out >= 0.0:
			# 退场：自下而上盖上纯黑。最后一条盖完整个屏就是黑的，
			# 正好把"交棒给自检"的那一帧焊在黑上。
			for i in rects.size():
				if t_out >= TitleScreen.out_band_time(i):
					draw_rect(rects[i], Prts.BLACK)
			return
		if t_in >= 0.0:
			# 入场：开局整屏黑，带子按时刻逐条消失（自上而下）。
			for i in rects.size():
				if t_in < TitleScreen.in_band_time(i):
					draw_rect(rects[i], Prts.BLACK)

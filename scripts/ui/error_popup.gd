class_name ErrorPopup
extends Control
## 报错弹窗：控制台出现 error 时从屏幕正中浮现，点空白处（或 Esc）关掉，关的时候沉下去。
##
## 风格照 PRTS：直角、1px 细边、四角一段又粗又长的角标（PrtsFrame）。
## 整套界面是黑白灰，红色只留给这一处——错误提示是唯一值得破例的地方，
## 编辑器语法高亮的调色板同样是 Prts 之外的一套，道理一样。
##
## 动画是手写的进度驱动，没用 Tween：这个项目里所有动画都是这么写的
## （见 viz_view 的飞行元素、RunLineFrame 的平滑滑动），时间常数和曲线一眼看得全，
## 也好和别处的节奏对齐。不播动画时 set_process(false)，一帧都不多花。

# ---------------------------------------------------------------- 配色
## 全界面唯一的彩色，只给错误用
const C_RED := Color("#ff4d4f")
const C_RED_DIM := Color("#5a1416")     ## 面板描边，暗一档，别抢角标
const C_PANEL := Color("#0d0506")       ## 底色：黑里透一点红
const C_BODY := Color("#e8d8d8")        ## 正文，比平时的 TEXT_HI 再暖一点
const VEIL := Color(0, 0, 0, 0.55)      ## 背景压暗

# ---------------------------------------------------------------- 尺寸
const PANEL_W := 560.0
const PANEL_MIN_H := 140.0
const MARGIN := 60.0                    ## 面板离屏幕边缘至少留这么多
const PAD_H := 24.0                     ## 面板内左右留白（_layout 量正文宽度要用）

# ---------------------------------------------------------------- 动画
## 浮现：短、快、从下方一点点升上来
const IN_TIME := 0.18
const IN_RISE := 14.0
const IN_SCALE := 0.86
## 沉入水中：慢、越沉越快、过半才开始淡出（否则看不见"沉"这个动作），
## 顺便左右摆一点点——像水里的折射，而不是自由落体
const OUT_TIME := 0.52
const OUT_SINK := 96.0
const OUT_SCALE := 0.95
const OUT_WOBBLE := 3.0
const OUT_WOBBLE_CYCLES := 1.6

enum { ST_HIDDEN, ST_IN, ST_SHOWN, ST_OUT }

var _panel: PanelContainer
var _frame: PrtsFrame
var _title: Label
var _body: Label
var _state := ST_HIDDEN
var _t := 0.0
## 居中位置（不含动画偏移）
var _base_pos := Vector2.ZERO
## 当前这一帧的动画姿态 (scale, dy, dx)，重排布局时要原样再套一次
var _pose := Vector3(1.0, 0.0, 0.0)


func _init() -> void:
	# 铺满整个窗口、吃掉所有点击：这样"点其他区域关闭"才有地方可点，
	# 弹窗开着的时候下面的界面也不会被误触。
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false
	# 压住补全弹框（它用 200）
	z_index = 300


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	resized.connect(_layout)
	_build()
	set_process(false)
	# 先躲在隐藏状态里把版排一次。
	# Label 的自动折行高度是按它**当前**宽度量出来的：第一次显示时才排的话，
	# 它那时还是 0 宽，会量出"一个字符一行"的几百像素高度，
	# 弹窗就变成一个又窄又高的长条（实测 560×518 而不是 560×140）。
	# 先排过一遍，之后每次换文案就都能量准了。
	call_deferred("_prime_layout")


func _prime_layout() -> void:
	_layout()
	# 第二遍：这时容器已经按目标宽度把正文排过版了，量出来的是准的
	_layout()


func _build() -> void:
	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", Prts.flat(C_PANEL, C_RED_DIM, 1))
	# 点在面板上不算"点其他区域"，所以这里要吃掉鼠标事件
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	var tick := ColorRect.new()
	tick.color = C_RED
	tick.custom_minimum_size = Vector2(3, 14)
	tick.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(tick)
	_title = Prts.label("", Prts.FS_BODY, C_RED)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title)
	head.add_child(Prts.label("SYSTEM ALERT", Prts.FS_TINY, C_RED_DIM))
	col.add_child(head)

	col.add_child(Prts.rule(C_RED_DIM))

	_body = Prts.label("", Prts.FS_BODY, C_BODY)
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(_body)

	var foot := HBoxContainer.new()
	var hint := Prts.dim_label("点击空白处或按 Esc 关闭　·　完整日志见「运行状况」页")
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(hint)
	col.add_child(foot)

	_panel.add_child(Prts.pad(col, 24, 20))

	# 四角粗角标：PRTS 最有辨识度的那一笔，这里加粗加长、换成红色
	_frame = PrtsFrame.new()
	_frame.bracket_len = 26
	_frame.thickness = 5
	_frame.bracket_color = C_RED
	_frame.border_color = C_RED_DIM
	_panel.add_child(_frame)


# ---------------------------------------------------------------- 对外接口

func is_open() -> bool:
	return _state != ST_HIDDEN


## 显示一条错误。已经开着的话直接换内容并重新浮现一次（当作"又报了一个"）。
func show_error(title: String, message: String) -> void:
	_title.text = title
	_body.text = message
	visible = true
	_layout()
	_state = ST_IN
	_t = 0.0
	modulate.a = 0.0
	_apply_pose(IN_SCALE, IN_RISE, 0.0)
	set_process(true)


## 关掉（播下沉动画）。已经关了就什么都不做。
func close() -> void:
	if _state == ST_HIDDEN or _state == ST_OUT:
		return
	_state = ST_OUT
	_t = 0.0
	set_process(true)


# ---------------------------------------------------------------- 布局与动画

func _layout() -> void:
	if _panel == null:
		return
	var area := size
	if area.x < 100.0 or area.y < 100.0:
		area = get_viewport_rect().size
	var w := minf(PANEL_W, maxf(320.0, area.x - MARGIN * 2.0))
	# 先给定宽度：正文是自动折行的，得先知道宽度才知道要几行。
	# 这里必须**主动**把正文的宽度设成目标宽度：Label 的最小高度是按它当前宽度量出来的，
	# 容器还没排版时它的宽度是 0，于是一个字符一行、报出几百像素的最小高度，
	# 弹窗就变成一个又窄又高的长条。设完宽度它会自己重新排版，再问就准了。
	_panel.size.x = w
	_body.size.x = w - PAD_H * 2.0
	_panel.size.y = maxf(PANEL_MIN_H, _panel.get_combined_minimum_size().y)
	_base_pos = ((area - _panel.size) * 0.5).floor()
	_panel.pivot_offset = _panel.size * 0.5
	# 重排之后把当前姿态再套一次：正在播动画时窗口被缩放，也不会跳回原位
	_apply_pose(_pose.x, _pose.y, _pose.z)


func _apply_pose(scale: float, dy: float, dx: float) -> void:
	_pose = Vector3(scale, dy, dx)
	_panel.scale = Vector2(scale, scale)
	_panel.position = _base_pos + Vector2(dx, dy)


func _process(delta: float) -> void:
	match _state:
		ST_IN:
			_t += delta
			var p := clampf(_t / IN_TIME, 0.0, 1.0)
			var e := 1.0 - pow(1.0 - p, 3.0)          # ease-out：出来得快，落位稳
			modulate.a = e
			_apply_pose(lerpf(IN_SCALE, 1.0, e), lerpf(IN_RISE, 0.0, e), 0.0)
			if p >= 1.0:
				_state = ST_SHOWN
				_apply_pose(1.0, 0.0, 0.0)
				set_process(false)
		ST_OUT:
			_t += delta
			var p := clampf(_t / OUT_TIME, 0.0, 1.0)
			var sink := OUT_SINK * p * p               # ease-in：越沉越快
			var wobble := sin(p * TAU * OUT_WOBBLE_CYCLES) * OUT_WOBBLE * (1.0 - p)
			# 前一半保持不透明，后一半才淡出：得先看见它沉下去
			modulate.a = 1.0 - clampf((p - 0.5) / 0.5, 0.0, 1.0)
			_apply_pose(lerpf(1.0, OUT_SCALE, p), sink, wobble)
			if p >= 1.0:
				_state = ST_HIDDEN
				visible = false
				modulate.a = 1.0
				_apply_pose(1.0, 0.0, 0.0)
				set_process(false)
		_:
			set_process(false)


# ---------------------------------------------------------------- 输入

func _draw() -> void:
	# 背景压暗。整个节点会被 modulate 淡入淡出，所以这里画一层就够
	draw_rect(Rect2(Vector2.ZERO, size), VEIL)


func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.pressed:
		accept_event()
		close()


func _input(event: InputEvent) -> void:
	if _state == ST_HIDDEN:
		return
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if k.pressed and not k.echo and k.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		close()
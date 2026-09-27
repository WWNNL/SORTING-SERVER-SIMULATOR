class_name ErrorPopup
extends Control
## 报错弹窗：控制台出现 error 时在屏幕正中亮起来，点空白处（或 Esc）关掉。
##
## 风格照 PRTS：直角、1px 细边、四角一段又粗又长的角标（PrtsFrame）。
## 整套界面是黑白灰，红色只留给这一处——错误提示是唯一值得破例的地方，
## 编辑器语法高亮的调色板同样是 Prts 之外的一套，道理一样。
##
## 动画是"故障灯"式的一串硬闪：进场前密后疏、以亮收尾（灯管折腾几下终于亮起来），
## 退场同样硬闪、以灭收尾（彻底坏了）。面板本身**不位移也不缩放**——
## 坏掉的是灯，不是这块板子，让它一边淡入一边往上飘反而像"加载中"。
## 亮度曲线是手写的关键帧数组，不挂 Tween：这个项目的动画都是这么写的
## （见 viz_view 的飞行元素、RunLineFrame 的平滑滑动），参数一眼看得全。
## 不播动画时 set_process(false)，一帧都不多花。

# ---------------------------------------------------------------- 配色
## 全界面唯一的彩色，只给错误用
const C_RED := Color("#ff4d4f")
const C_RED_DIM := Color("#5a1416")     ## 面板描边，暗一档，别抢角标
const C_PANEL := Color("#0d0506")       ## 底色：黑里透一点红
const C_BODY := Color("#e8d8d8")        ## 正文，比平时的 TEXT_HI 再暖一点

# ---------------------------------------------------------------- 尺寸
const PANEL_W := 560.0
const PANEL_MIN_H := 140.0
const MARGIN := 60.0                    ## 面板离屏幕边缘至少留这么多
const PAD_H := 24.0                     ## 面板内左右留白（_layout 量正文宽度要用）

# ---------------------------------------------------------------- 动画
## 故障灯的闪法：一串 [时刻占比, 亮度] 关键帧，按"保持到下一帧"取值。
## 硬切才像坏掉的灯管；在关键帧之间做插值就变成渐入渐出，那是"加载中"的语汇。
##
## **退场表是唯一的模板**（FLICKER_OUT），进场表由它按时间镜像生成（见 _ready）。
## 两边因此永远对称：改退场，进场自动跟着变，不会只改一边。
##
## 退场：亮着 → 黑 → 亮 → 黑 → 亮 → 黑 → 亮 → 灭透。
## 起手那下不算"闪"，之后三下回光；关键是**黑的间隔本身递减**，
## 只让"回光之间的周期"变短是不够的——感知到的节奏主要是黑的那段有多长：
## 四段黑 80 / 60 / 45 / 35 ms（0.2000 / 0.1500 / 0.1125 / 0.0875），总共 0.40s。
const FLICKER_OUT := [
	[0.0000, 1.00],
	[0.2250, 0.00],
	[0.4250, 1.00],   ## 回光一
	[0.5000, 0.00],
	[0.6500, 1.00],   ## 回光二
	[0.7250, 0.00],
	[0.8375, 1.00],   ## 回光三
	[0.9125, 0.00],
	[1.0000, 0.00],
]
## 进出场总时长。镜像关系要求两边一样长。
const FLICKER_TIME := 0.40

enum { ST_HIDDEN, ST_IN, ST_SHOWN, ST_OUT }

var _panel: PanelContainer
var _frame: PrtsFrame
var _title: Label
var _body: Label
var _state := ST_HIDDEN
var _t := 0.0
## 居中位置（不含动画偏移）
var _base_pos := Vector2.ZERO
## 进场关键帧：由退场表按时间镜像生成（见 _ready），这里存下来给 _process 用
var _flicker_in: Array = []


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
	_flicker_in = mirror_in_time(FLICKER_OUT)
	set_process(false)
	# 先躲在隐藏状态里把版排一次。
	# Label 的自动折行高度是按它**当前**宽度量出来的：第一次显示时才排的话，
	# 它那时还是 0 宽，会量出"一个字符一行"的几百像素高度，
	# 弹窗就变成一个又窄又高的长条（实测 560×518 而不是 560×140）。
	# 先排过一遍，之后每次换文案就都能量准了。
	call_deferred("_prime_layout")


## 把一张关键帧表按**时间**倒过来：新段起点 = 1 - 原段终点，亮度原样不动。
## 于是"亮着→闪三下→灭透"镜像成"黑着→闪三下→亮住"：亮的收尾接上亮的起手，
## 两边在时间轴上互为倒放。
##
## 注意必须按**段**翻，不能只翻关键帧的时刻：关键帧的值是作用于"它到下一个关键帧之间"的，
## 只翻时刻会让每段的归属错位一格——实测开场会平白多出 30ms 的黑。
##
## 进场那串的节奏因此是退场的倒放：黑 35 → 45 → 60 → 80 ms（越来越慢，像灯管越闪越稳），
## 退场则是黑 80 → 60 → 45 → 35 ms（越闪越急，最后灭透）。这是刻意的对称。
static func mirror_in_time(pattern: Array) -> Array:
	var out: Array = []
	for i in pattern.size():
		var t0 := float(pattern[i][0])
		var t1 := 1.0 if i + 1 >= pattern.size() else float(pattern[i + 1][0])
		if t1 <= t0:
			continue
		out.append([1.0 - t1, float(pattern[i][1])])
	if out.is_empty():
		return out
	out.reverse()
	# 末尾补一个保持点，让表格自解释（flicker_at 本来也会保持最后一个值）
	var last: Array = out[-1]
	out.append([1.0, float(last[1])])
	return out


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
	# 署名是系统名而不是泛指的 "SYSTEM"：这弹窗是 PRTS 在报警
	head.add_child(Prts.label("PRTS ALERT", Prts.FS_TINY, C_RED_DIM))
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


## 显示一条错误。已经开着的话直接换内容并重新闪一次（当作"又报了一个"）。
func show_error(title: String, message: String) -> void:
	_title.text = title
	_body.text = message
	visible = true
	_layout()
	_state = ST_IN
	_t = 0.0
	modulate.a = 0.0
	set_process(true)


## 关掉（播退场的那串硬闪）。已经关了就什么都不做。
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
	# 面板不位移也不缩放：闪的是灯，不是板子。这里只把位置摆正。
	_panel.scale = Vector2.ONE
	_panel.position = _base_pos


## 按关键帧取亮度。保持到下一帧（硬切），不做插值。
static func flicker_at(pattern: Array, p: float) -> float:
	var v := 0.0
	for k in pattern:
		if p >= float(k[0]):
			v = float(k[1])
		else:
			break
	return v


func _process(delta: float) -> void:
	match _state:
		ST_IN:
			_t += delta
			var p := clampf(_t / FLICKER_TIME, 0.0, 1.0)
			modulate.a = flicker_at(_flicker_in, p)
			if p >= 1.0:
				_state = ST_SHOWN
				modulate.a = 1.0
				set_process(false)
		ST_OUT:
			_t += delta
			var p := clampf(_t / FLICKER_TIME, 0.0, 1.0)
			modulate.a = flicker_at(FLICKER_OUT, p)
			if p >= 1.0:
				_state = ST_HIDDEN
				visible = false
				modulate.a = 1.0
				set_process(false)
		_:
			set_process(false)


# ---------------------------------------------------------------- 输入

## 只在面板上画东西，铺满全屏的这层是**完全透明**的：
## 它只负责吃鼠标事件（点别处关闭、弹窗开着时点不到底下的界面）。
## 刻意不做背景压暗：这套界面本来就是黑的，压暗只会把旁边的面板一起弄脏，
## 看着像画面出问题，而不是"这里有个弹窗"。
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
class_name TabDragGhost
extends Control
## 拖动标签页时跟着光标走的那张小卡片。
##
## 为什么要"另外画一张"而不是让真标签跟着走：TabBar 没有给单个标签设偏移的接口。
## 真标签会随着拖动实时换位置（见 main._on_tab_bar_input），再叠上这张卡片，
## 看起来就是"卡片跟手、下面的标签在让位"。
##
## 卡片比光标慢一点点（FOLLOW_TAU 很小）——不是死贴着，那一点滞后才是"跟手"的手感；
## 死贴反而像原生的拖拽影，没有重量。拾起时抬一下、松手时缩着淡出，
## 这两个小动效负责说清"拿起来了 / 放回去了"。
##
## 和其它动画一样手写进度，不挂 Tween；静止下来就 set_process(false)。

## 跟随的时间常数：越小越贴手。滞后距离 = 光标速度 × 这个值，
## 0.02 在常见的手速（约 1000~2000 px/s）下是 20~40px 的拖尾——看得见"有重量"，
## 又不会让人觉得卡片掉了队（0.045 时实测拖尾 65px 以上，像没跟上）。
const FOLLOW_TAU := 0.02
const SNAP_PX := 0.6          ## 离目标这么近就直接吸附，免得永远差零点几像素
const IN_TIME := 0.09         ## 拾起
const IN_SCALE := 0.90
const OUT_TIME := 0.12        ## 放下
const OUT_SCALE := 0.96

enum { ST_HIDDEN, ST_IN, ST_FOLLOW, ST_OUT }

var _panel: PanelContainer
var _label: Label
var _pos := Vector2.ZERO      ## 当前画在哪（卡片中心）
var _target := Vector2.ZERO   ## 光标在哪
var _scale := 1.0
var _t := 0.0
var _state := ST_HIDDEN


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 压住补全弹框（200），但低于报错弹窗（300）
	z_index = 250
	visible = false


func _ready() -> void:
	_panel = PanelContainer.new()
	# 借主题里"标签悬停"的那套样式（RAISED 底 + 白描边 + 同样的内边距），
	# 尺寸也就和真标签一致，抬起来看着就是那个标签本身
	_panel.add_theme_stylebox_override("panel", Prts.flat(Prts.RAISED, Prts.WHITE, 1, 14, 7))
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)

	_label = Prts.label("", Prts.FS_SMALL, Prts.WHITE)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_label)
	set_process(false)


func is_dragging() -> bool:
	return _state != ST_HIDDEN


## 拾起一个标签。tab_size 用真标签的尺寸，卡片和它一样大。
func pick_up(title: String, tab_size: Vector2, at: Vector2) -> void:
	_label.text = title
	custom_minimum_size = tab_size
	size = tab_size
	pivot_offset = tab_size * 0.5
	_pos = at
	_target = at
	_state = ST_IN
	_t = 0.0
	_scale = IN_SCALE
	modulate.a = 0.0
	visible = true
	_apply()
	set_process(true)


## 光标移动。拾起动画还没播完也照样更新目标，卡片会一边出现一边跟上。
func follow(at: Vector2) -> void:
	if _state == ST_HIDDEN or _state == ST_OUT:
		return
	_target = at
	set_process(true)


## 松手：缩着淡出。真标签已经在它该在的位置上了。
func drop() -> void:
	if _state == ST_HIDDEN or _state == ST_OUT:
		return
	_state = ST_OUT
	_t = 0.0
	set_process(true)


func _apply() -> void:
	position = (_pos - size * 0.5).floor()
	scale = Vector2(_scale, _scale)


func _process(delta: float) -> void:
	match _state:
		ST_IN:
			_t += delta
			var p := clampf(_t / IN_TIME, 0.0, 1.0)
			var e := 1.0 - pow(1.0 - p, 3.0)
			modulate.a = e
			_scale = lerpf(IN_SCALE, 1.0, e)
			if p >= 1.0:
				_state = ST_FOLLOW
			_follow_step(delta)
		ST_FOLLOW:
			if not _follow_step(delta):
				set_process(false)     # 停下来就别再逐帧跑了，下次 follow() 会再唤醒
		ST_OUT:
			_t += delta
			var p := clampf(_t / OUT_TIME, 0.0, 1.0)
			modulate.a = 1.0 - p
			_scale = lerpf(1.0, OUT_SCALE, p)
			_follow_step(delta)
			if p >= 1.0:
				_state = ST_HIDDEN
				visible = false
				modulate.a = 1.0
				_scale = 1.0
				set_process(false)
		_:
			set_process(false)
	_apply()


## 往光标逼近一步。返回是否还在动（没动就不用继续逐帧处理了）。
func _follow_step(delta: float) -> bool:
	if _pos.distance_to(_target) < SNAP_PX:
		_pos = _target
		return false
	_pos = _pos.lerp(_target, 1.0 - exp(-delta / FOLLOW_TAU))
	return true
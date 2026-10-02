class_name TitleStreams
extends Control
## 开始菜单里"活着的那一层"：机柜上零星明灭的指示灯。
##
## 背景图是烘死的，机房本身不会动；菜单要"活着"就得有一层实时的东西。
## 指示灯按固定种子摇位置，每次开机一模一样；各自按不同频率明灭，
## 让静止的机柜看着还在跑。加法混合（画在机房之上就是"发光"），
## 而且**跟着焦点走**：离焦的灯画得更大更淡，和背景的景深是同一套语言。
##
## 早先这层还有四条沿灯线流动的荧光虚线，后来去掉了——写实渲染的机房
## 本身灯线已经很密，再叠流光就是满屏斜杠。

## 灭点（占屏宽 / 屏高）。和 TitleBackdrop.VP 是同一个点，必须一致。
const VP := TitleBackdrop.VP

## 颜色：冷白为主，蓝的给机柜上靠蓝的那几颗。
const C_WHITE := Color(0.86, 0.94, 1.0)
const C_BLUE := Color(0.35, 0.66, 1.0)

## 离焦时灯被"糊"开的上限（像素）
const BLUR_MAX := 9.0

## 机柜上的指示灯：位置按固定种子摇，每次开机一模一样
const DOT_COUNT := 18
const DOT_SEED := 0x5354524d     # "STRM"
## 指示灯只出现在两侧机柜区，中间是通道，不能有
## （灭点在 x=0.556，两侧机柜墙从它旁边一直铺到画面边缘）
const DOT_X := [Vector2(0.03, 0.40), Vector2(0.60, 0.97)]
const DOT_Y := Vector2(0.28, 0.72)

var _t := 0.0
var _focus := 0.35
var _offset := Vector2.ZERO
var _dots: Array = []


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 加法混合：画在黑底上就是"发光"。用 CanvasItemMaterial 而不是在
	# _draw 里逐条设混合模式——Godot 4 没有 draw_set_blend_mode 了。
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = mat


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build_dots()
	set_process(true)


func _process(delta: float) -> void:
	advance(delta)


## 推进时间。_process 只是转调它，测试可以直接按秒推进。
func advance(delta: float) -> void:
	_t += maxf(delta, 0.0)
	queue_redraw()


func set_focus(f: float) -> void:
	_focus = f


## 跟着机房的远景层一起平移，指示灯才不会从机柜上滑开。
## 名字刻意不叫 set_offset：Control 自带一个 set_offset(side, offset)（锚点偏移），
## 同名会被解析成父类那个、参数对不上，整个脚本编译不过。
func set_parallax(v: Vector2) -> void:
	_offset = v


func elapsed() -> float:
	return _t


# ================================================================ 纯函数（可测）

## 离焦时灯的模糊量：和背景同一套景深语言（对焦深度处为 0）。
static func dot_blur(depth: float, focus: float) -> float:
	return blur_for_depth(depth, focus, BLUR_MAX)


static func blur_for_depth(depth: float, focus: float, blur_max: float) -> float:
	return blur_max * absf(depth - focus)


# ================================================================ 绘制

func _draw() -> void:
	if size.x < 64.0 or size.y < 64.0:
		return
	# 整层跟着机房层平移（由 TitleScreen 每帧喂进来）
	draw_set_transform(_offset, 0.0, Vector2.ONE)
	_draw_dots()
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## 机柜上的指示灯：位置固定、各自按不同频率明灭。
## 它们让静止的机柜看着还在跑，数量刻意压得很少（多了就是一片噪点）。
func _draw_dots() -> void:
	for i in _dots.size():
		var d: Dictionary = _dots[i]
		var pos: Vector2 = d["pos"]
		var depth := float(d["depth"])
		var rate := float(d["rate"])
		var phase := float(d["phase"])
		var blink := sin(_t * rate + phase)
		if blink <= 0.0:
			continue
		var a := blink * blink * 0.85
		var blur := dot_blur(depth, _focus)
		var p := Vector2(pos.x * size.x, pos.y * size.y)
		var r := (1.6 + blur * 0.5) * float(d["size"])
		var col: Color = C_BLUE if bool(d["blue"]) else C_WHITE
		var soft := a / (1.0 + blur * 0.35)
		draw_rect(Rect2(p - Vector2(r, r) * 2.4, Vector2(r, r) * 4.8),
			Color(col.r, col.g, col.b, soft * 0.10))
		draw_rect(Rect2(p - Vector2(r, r) * 1.4, Vector2(r, r) * 2.8),
			Color(col.r, col.g, col.b, soft * 0.30))
		draw_rect(Rect2(p - Vector2(r, r) * 0.5, Vector2(r, r)), Color(col.r, col.g, col.b, soft))


func _build_dots() -> void:
	_dots = []
	var rng := RandomNumberGenerator.new()
	rng.seed = DOT_SEED
	for i in DOT_COUNT:
		var side: Vector2 = DOT_X[i % DOT_X.size()]
		var x := rng.randf_range(side.x, side.y)
		var y := rng.randf_range(DOT_Y.x, DOT_Y.y)
		# 深度就用背景那套代理：离灭点线越远越近
		var dy := y - VP.y
		var depth := (dy / (1.0 - VP.y)) if dy >= 0.0 else (-dy / VP.y)
		_dots.append({
			"pos": Vector2(x, y),
			"depth": clampf(depth, 0.0, 1.0),
			"rate": rng.randf_range(0.7, 3.1),
			"phase": rng.randf_range(0.0, TAU),
			"size": rng.randf_range(0.7, 1.5),
			"blue": rng.randf() < 0.6,
		})

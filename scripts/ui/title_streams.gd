class_name TitleStreams
extends Control
## 开始菜单里"流动的光"：沿着机房的灯线往镜头方向跑的数据流、几颗游标、
## 以及机柜上零星闪着的指示灯。
##
## 背景图是烘死的，机房本身不会动；菜单要"活着"就得有一层实时的东西。
## 这层全是自绘的荧光线条，加法混合（画在机房之上就是"发光"），
## 而且**跟着焦点走**：离焦的线画得更粗更淡，和背景的景深是同一套语言。
##
## 线条的位置不是随便画的：灭点和方向都对着渲染那台相机的透视，
## 每条线都压在背景里已有的灯线上——天花两条白色主灯带（往上），
## 加上这两条灯带在地板上的反射线（往下，反射里带着冷蓝），
## 所以流过去的光看着像"从那些灯里出来的"。
##
## 深度直接用**线上的位置**：贴着灭点那端最远、往画面边缘走越来越近。
## 于是对焦到远处时，只有灭点附近那一段是锐的，靠近镜头的一段糊掉——
## 这正是透视画面里该有的样子。

## 灭点（占屏宽 / 屏高）。和 TitleBackdrop.VP 是同一个点，必须一致。
const VP := TitleBackdrop.VP

## 数据流的一条线：从灭点出发的方向（占屏比）、亮度、速度、虚线根数。
##
## 四条线**必须压在背景已有的灯线上**（天花两条、地板反射两条），方向是
## 照着渲染那台相机投影算的：灯带在画面顶边交于 x=0.412 / 0.700，
## 反射线在底边交于 x=0.405 / 0.708，都从灭点 (0.556, 0.485) 出发，
## 再往外延 8% 让虚线能滑出画面。流过去的光要像是"从那些灯里出来的"。
## 早先还加过"机柜顶"的线，背景里找不到对应的灯，看着就是凭空划过去
## 的斜杠——删掉了。
const LINES := [
	{"dir": Vector2(-0.1634, 0.5562), "bright": 0.78, "speed": 0.16, "dashes": 9, "w": 2.0},
	{"dir": Vector2(0.1640, 0.5562), "bright": 0.78, "speed": 0.16, "dashes": 9, "w": 2.0},
	{"dir": Vector2(-0.1561, -0.5238), "bright": 0.95, "speed": 0.13, "dashes": 8, "w": 1.7},
	{"dir": Vector2(0.1551, -0.5238), "bright": 0.95, "speed": 0.13, "dashes": 8, "w": 1.7},
]
## 每条虚线的长度（像素，指 u=1 处）。实际长度按透视的局部斜率缩放：
## 贴着灭点的地方几乎缩成一个点，往镜头这边才拉长。直接给"参数长度"的话，
## 近处那几段会被拉成两三百像素的长条（第一版就是这样，满屏斜杠）。
const DASH_PX := 34.0
## 线被拉长的指数：透视压缩。1.0 = 等距（看着像一张平面图），
## 1.7 才是"越远越密"。
const PERSP := 1.7
## 颜色：冷白为主，靠蓝的那几条给地面。
const C_WHITE := Color(0.86, 0.94, 1.0)
const C_BLUE := Color(0.35, 0.66, 1.0)

## 离焦时线被"糊"开的上限（像素）
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


## 跟着机房的远景层一起平移，流光才不会从背景的灯带上滑开。
## 名字刻意不叫 set_offset：Control 自带一个 set_offset(side, offset)（锚点偏移），
## 同名会被解析成父类那个、参数对不上，整个脚本编译不过。
func set_parallax(v: Vector2) -> void:
	_offset = v


func elapsed() -> float:
	return _t


# ================================================================ 纯函数（可测）

## 第 k 条虚线此刻在线上什么位置（0 = 灭点，1 = 画面边缘）。
## 相位按线速推进，走到头从 0 重来。
static func dash_u(k: int, count: int, phase: float) -> float:
	if count <= 0:
		return 0.0
	return fposmod(float(k) / float(count) + phase, 1.0)


## 线上参数 u 对应的**屏幕占比**长度。指数就是透视压缩：
## u 是均匀推进的时间参数，屏幕上的位置得按 1/距离 压过来。
static func persp(u: float) -> float:
	return pow(clampf(u, 0.0, 1.0), PERSP)


## 透视在 u 处的局部斜率：单位参数对应多少屏幕占比长度。
## 虚线长度按它缩放，才能"远小近大"。
static func persp_slope(u: float) -> float:
	return PERSP * pow(maxf(u, 0.001), PERSP - 1.0)


## 虚线的两端亮度：刚出现和快消失时淡出，免得 wrap 的时候"啪"地跳一下。
static func dash_alpha(u: float) -> float:
	return smoothstep(0.0, 0.12, u) * smoothstep(1.0, 0.72, u)


## 线上某点的屏幕坐标（像素）。u 是参数，不是屏幕占比。
static func line_point(screen: Vector2, dir: Vector2, u: float) -> Vector2:
	var vp := Vector2(VP.x * screen.x, VP.y * screen.y)
	return vp + Vector2(dir.x * screen.x, dir.y * screen.y) * persp(u)


## 这一点的深度：贴着灭点最远（0），越往画面边缘越近（1）。
static func depth_at(u: float) -> float:
	return clampf(persp(u), 0.0, 1.0)


# ================================================================ 绘制

func _draw() -> void:
	if size.x < 64.0 or size.y < 64.0:
		return
	# 整层跟着机房层平移（由 TitleScreen 每帧喂进来）
	draw_set_transform(_offset, 0.0, Vector2.ONE)
	_draw_dots()
	_draw_lines()
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_lines() -> void:
	for i in LINES.size():
		var line: Dictionary = LINES[i]
		var dir: Vector2 = line["dir"]
		var bright := float(line["bright"])
		var speed := float(line["speed"])
		var count := int(line["dashes"])
		var w := float(line["w"])
		var col := C_BLUE if i < 2 else C_WHITE
		var phase := _t * speed

		for k in count:
			var u := dash_u(k, count, phase)
			var a := dash_alpha(u) * bright * (1.0 - 0.55 * persp(u))
			if a <= 0.004:
				continue
			var p0 := line_point(size, dir, u)
			# 虚线长度按局部斜率缩放（远小近大），方向沿线的屏幕方向
			var along := Vector2(dir.x * size.x, dir.y * size.y).normalized()
			var p1 := p0 + along * DASH_PX * persp_slope(u)
			# 离焦：线画得更粗、更淡。和背景是同一套景深语言。
			var blur := TitleBackdrop.blur_for_depth(depth_at(u), _focus, BLUR_MAX)
			_draw_glow(p0, p1, col, a, w + blur * 0.9, blur)


## 一段发光的线：一条主线 + 两层很淡的粗线当光晕。
## 层数不能省——只有一层是一条带毛边的线，不是"发光"（接入屏的波形同理）。
func _draw_glow(p0: Vector2, p1: Vector2, col: Color, a: float, w: float,
		blur: float) -> void:
	var soft := a / (1.0 + blur * 0.35)
	draw_line(p0, p1, Color(col.r, col.g, col.b, soft * 0.16), w * 3.2)
	draw_line(p0, p1, Color(col.r, col.g, col.b, soft * 0.34), w * 1.7)
	draw_line(p0, p1, Color(col.r, col.g, col.b, soft), w)


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
		var blur := TitleBackdrop.blur_for_depth(depth, _focus, BLUR_MAX)
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

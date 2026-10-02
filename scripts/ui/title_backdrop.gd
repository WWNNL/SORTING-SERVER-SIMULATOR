class_name TitleBackdrop
extends Control
## 开始菜单的背景：两层 Blender 烘的机房图 + 鼠标驱动的视差与景深。
##
## 为什么是两层而不是一张：菜单要有"镜头随鼠标微动"的纵深，一张平图做不到——
## 贴着镜头的那层（前景剪影）必须能相对机房滑开。机房本体内部不再分层：
## 机柜是坐在地上的，把地面和机柜拆到两层里，滑动时接缝和倒影会露馅。
##
## 深度从哪来：这两张图都没有深度缓冲，但机房是**透视**的，画面纵坐标基本
## 就等于深度（贴着灭点最远、画面上下两端最近）。着色器拿这个当深度代理，
## 于是"对焦"变成一个可以直接算的量：|深度 − 焦点|。
##
## 鼠标的两个分量各管一件事，合起来就是"镜头在动"：
##   左右 → 视差：远景滑得少、近景滑得多
##   上下 → 对焦：鼠标往上对远处，往下对近处（画面上下两端一起糊，中间清楚）
##
## 全自绘之外的东西很少：两个 TextureRect 挂同一个着色器，参数不同而已。

## 灭点在画面上的位置（占屏宽 / 屏高）。这是**算**出来的，不是估的：
## Blender 里那台相机是 40mm、yaw 4°、pitch 2°，水平半视角 24.2°、垂直 14.2°，
## 灭点因此偏右 tan4°/tan24.2° × 0.5 ≈ 7.8%、偏上 6.9%。
## 值必须和 tools/blender/server_room.py 里的相机对上：改那边就要改这里。
const VP := Vector2(0.578, 0.435)

const ROOM_TEX := "res://assets/title/title_room.png"
const FORE_TEX := "res://assets/title/title_fore.png"

## 过扫描：图比屏幕大一圈。视差会让图层滑动，不留余量就会滑出边缘。
const OVERSCAN := 1.14

## 视差幅度（像素，按 1600×900 基准）。两层差 3.5 倍，纵深才立得住。
const PARALLAX_FAR := 12.0
const PARALLAX_NEAR := 42.0
## 鼠标平滑速度（每秒衰减到 e^-speed）。直接跟手会抖，太慢又像拖不动。
const SMOOTH_SPEED := 6.0

## 焦点深度的取值范围。鼠标在最上方 = 对焦最远（灭点），最下方 = 对焦最近。
## 上限就是 1.0（画面下沿）：前景剪影的深度在它之外（1.35），
## 所以那层**永远带一点离焦**——贴着镜头的东西本来就不该全清楚，
## 而且它是一块块黑剪影，全清楚时看着就是几根硬邦邦的黑柱子。
const FOCUS_MIN := 0.0
const FOCUS_MAX := 1.0
## 两层各自的离焦模糊上限（像素）。前景离镜头最近，离焦时该糊得最狠。
const BLUR_ROOM := 7.0
const BLUR_FORE := 20.0
## 前景剪影的固定深度：整层都在镜头前面，不参与"按屏内位置估深度"。
## 1.35 比焦点上限还远一档，保证它始终糊着（见 FOCUS_MAX）。
const FORE_DEPTH := 1.35

## 两个图层各自的一点调色。机房那层压一点、染一点蓝；
## 前景那层纯当剪影，压得更暗（它是框，不是景）。
const ROOM_GAIN := 1.06
const ROOM_TINT := Color(0.92, 0.97, 1.0)
const FORE_GAIN := 0.72
const FORE_TINT := Color(0.80, 0.88, 1.0)
## 暗角与扫描线。菜单是要读字的，这两样都只给一点点：
## 暗角 0.30 够把四角压下去，扫描线 0.05 是"这台机器在发光"的笔触。
const VIGNETTE := 0.30
const SCANLINE := 0.05

## 左半边的压暗层。机柜上那些荧光条很亮，菜单文字直接压上去会看不清；
## 一层从左往右淡出的黑是最省事也最不打扰画面的办法。
const SCRIM_LEFT_ALPHA := 0.62
const SCRIM_LEFT_WIDTH := 0.78
const SCRIM_BOTTOM_ALPHA := 0.55
const SCRIM_BOTTOM_HEIGHT := 0.22

var _room: TextureRect
var _fore: TextureRect
var _scrim_l: TextureRect
var _scrim_b: TextureRect

## 鼠标目标位置与平滑后的位置，都是 0~1 的屏幕占比
var _target := Vector2(0.5, 0.5)
var _mouse := Vector2(0.5, 0.5)
## 测试里关掉：headless 没有真鼠标，位置永远是 (0,0)
var follow_mouse := true

var _base_room := Rect2()
var _base_fore := Rect2()
var _last_size := Vector2.ZERO
var _fade := 1.0
var _focus := 0.35


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# 背景不吃鼠标：悬停与点击都归 TitleScreen 管
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build()
	set_process(true)


func _process(delta: float) -> void:
	if follow_mouse and is_inside_tree():
		var vp := get_viewport()
		if vp != null and size.x > 1.0 and size.y > 1.0:
			_target = (vp.get_mouse_position() / size).clamp(Vector2.ZERO, Vector2.ONE)
	advance(delta)


## 推进平滑并应用到图层。_process 只是转调它，测试可以直接按秒推进，
## 不用等真实帧、也不用真的移动鼠标。
func advance(delta: float) -> void:
	# 布局还没算出来的那几帧 size 是 0，_apply 会直接返回。等它第一次有效时
	# 直接落位——不这样的话，镜头会从屏幕正中"滑"到鼠标那儿（第一帧就看得见）。
	var first := _last_size == Vector2.ZERO
	# 指数衰减：帧率变了手感也不变（按帧数插值的话，120fps 下会快一倍）
	var k := 1.0 - exp(-SMOOTH_SPEED * maxf(delta, 0.0))
	_mouse = _mouse.lerp(_target, k)
	_apply()
	if first and _last_size != Vector2.ZERO:
		_mouse = _target
		_apply()


## 直接落到目标位置，不做平滑。测试用。
func settle() -> void:
	_mouse = _target
	_apply()


func set_mouse_target(v: Vector2) -> void:
	_target = v.clamp(Vector2.ZERO, Vector2.ONE)


## 转场用：整层淡出。0 = 全黑（底下就是黑底），1 = 正常。
func set_fade(v: float) -> void:
	_fade = clampf(v, 0.0, 1.0)
	_apply()


func fade() -> float:
	return _fade


## 当前焦点深度。鼠标越靠下越大（对得越近）。
func focus() -> float:
	return _focus


## 平滑后的鼠标位置（0~1）。测试核对"鼠标动了、镜头跟着动"用。
func smoothed_mouse() -> Vector2:
	return _mouse


## 某一层当前的偏移（像素）。i = 0 远景、1 近景。
func layer_offset(i: int) -> Vector2:
	return _room.position - _base_room.position if i == 0 else _fore.position - _base_fore.position


## 某一层当前的离焦模糊半径（像素）。测试核对"焦点变化真的改变了模糊量"用。
## 远景那层用画面中线（0.5）当代表深度——它整层铺满屏幕，深度是逐像素算的，
## 对外只能报一个"中段"的值。
func layer_blur(i: int) -> float:
	var mat := (_room.material if i == 0 else _fore.material) as ShaderMaterial
	var depth := FORE_DEPTH if i == 1 else 0.5
	return blur_for_depth(depth, _focus, float(mat.get_shader_parameter("blur_max")))


# ================================================================ 纯函数（可测）

## 焦点深度：鼠标纵坐标（0 = 屏幕最上，1 = 最下）映射到 [FOCUS_MIN, FOCUS_MAX]。
static func focus_from_mouse(y: float) -> float:
	return lerpf(FOCUS_MIN, FOCUS_MAX, clampf(y, 0.0, 1.0))


## 离焦模糊半径：离焦点越远越糊。
static func blur_for_depth(depth: float, focus: float, blur_max: float) -> float:
	return blur_max * absf(depth - focus)


## 视差偏移：鼠标往右，画面往左（镜头在往右转）。
## weight 是这一层的纵深权重——远景小、近景大，这就是纵深的来源。
static func parallax_offset(mouse: Vector2, weight: float, amount: float) -> Vector2:
	return (Vector2(0.5, 0.5) - mouse) * amount * weight


## 过扫描之后图层该占多大。居中放大，四边各留出 OVERSCAN 的余量。
static func layer_rect(screen: Vector2, overscan: float) -> Rect2:
	var s := screen * overscan
	return Rect2((screen - s) * 0.5, s)


# ================================================================ 内部

func _build() -> void:
	_room = _make_layer(ROOM_TEX)
	_fore = _make_layer(FORE_TEX)
	_scrim_l = _make_scrim(true)
	_scrim_b = _make_scrim(false)


func _make_layer(path: String) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = load(path)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var mat := ShaderMaterial.new()
	mat.shader = load("res://assets/shaders/title_layer.gdshader")
	tr.material = mat
	add_child(tr)
	return tr


## 压暗层：一张渐变纹理拉满。左边缘最黑、往右淡出；底边同理。
func _make_scrim(left: bool) -> TextureRect:
	var grad := Gradient.new()
	if left:
		grad.colors = PackedColorArray([
			Color(0, 0, 0, SCRIM_LEFT_ALPHA), Color(0, 0, 0, SCRIM_LEFT_ALPHA * 0.45),
			Color(0, 0, 0, 0.0)])
	else:
		grad.colors = PackedColorArray([
			Color(0, 0, 0, 0.0), Color(0, 0, 0, SCRIM_BOTTOM_ALPHA * 0.5),
			Color(0, 0, 0, SCRIM_BOTTOM_ALPHA)])
	grad.offsets = PackedFloat32Array([0.0, 0.5, 1.0])

	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill_from = Vector2(0, 0)
	tex.fill_to = Vector2(1, 0) if left else Vector2(0, 1)

	var tr := TextureRect.new()
	tr.texture = tex
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(tr)
	return tr


func _apply() -> void:
	if _room == null or size.x < 2.0 or size.y < 2.0:
		return
	if size != _last_size:
		_last_size = size
		_base_room = layer_rect(size, OVERSCAN)
		_base_fore = layer_rect(size, OVERSCAN * 1.06)   # 近景再放大一点，滑得更开
		_scrim_l.position = Vector2.ZERO
		_scrim_l.size = Vector2(size.x * SCRIM_LEFT_WIDTH, size.y)
		_scrim_b.position = Vector2(0.0, size.y * (1.0 - SCRIM_BOTTOM_HEIGHT))
		_scrim_b.size = Vector2(size.x, size.y * SCRIM_BOTTOM_HEIGHT)

	_focus = focus_from_mouse(_mouse.y)

	var off_room := parallax_offset(_mouse, 0.32, PARALLAX_FAR)
	var off_fore := parallax_offset(_mouse, 1.0, PARALLAX_NEAR)
	_room.position = _base_room.position + off_room
	_room.size = _base_room.size
	_fore.position = _base_fore.position + off_fore
	_fore.size = _base_fore.size

	var room_mat := _room.material as ShaderMaterial
	room_mat.set_shader_parameter("focus", _focus)
	room_mat.set_shader_parameter("blur_max", BLUR_ROOM)
	room_mat.set_shader_parameter("depth_fixed", -1.0)
	room_mat.set_shader_parameter("horizon", VP.y)
	room_mat.set_shader_parameter("screen_size", size)
	room_mat.set_shader_parameter("gain", ROOM_GAIN)
	room_mat.set_shader_parameter("tint", ROOM_TINT)
	room_mat.set_shader_parameter("vignette", VIGNETTE)
	room_mat.set_shader_parameter("scanline", SCANLINE)
	room_mat.set_shader_parameter("pixel", 2.0)
	room_mat.set_shader_parameter("fade", _fade)

	var fore_mat := _fore.material as ShaderMaterial
	fore_mat.set_shader_parameter("focus", _focus)
	fore_mat.set_shader_parameter("blur_max", BLUR_FORE)
	fore_mat.set_shader_parameter("depth_fixed", FORE_DEPTH)
	fore_mat.set_shader_parameter("horizon", VP.y)
	fore_mat.set_shader_parameter("screen_size", size)
	fore_mat.set_shader_parameter("gain", FORE_GAIN)
	fore_mat.set_shader_parameter("tint", FORE_TINT)
	fore_mat.set_shader_parameter("vignette", 0.0)
	fore_mat.set_shader_parameter("scanline", 0.0)
	fore_mat.set_shader_parameter("pixel", 2.0)
	fore_mat.set_shader_parameter("fade", _fade)

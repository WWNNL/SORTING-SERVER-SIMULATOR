class_name TitleBackdrop
extends Control
## 开始菜单的背景：实时渲染的 3D 机房 + 鼠标驱动的视差与景深。
##
## 机房本体是 Blender 建模的服务器机厅（assets/title/server_hall.glb），装在
## SubViewport 里每帧实时渲染，再经由 title_layer.gdshader 上屏。视差不再是
## "整幅画面在滑"——是镜头真的在走道里横移：近处的机柜滑得多、远处的少，
## 纵深是几何给的，不是效果调出来的。机柜指示灯的明灭由导出时写进顶点色的
## 三元组驱动（led_blink.gdshader），三组 LED（蓝/白/青）各配一份材质。
##
## 景深仍是深度代理：渲染出来的画面依然没有深度缓冲，但机房是**透视**的，
## 画面纵坐标基本就等于深度（贴着灭点最远、画面上下两端最近），着色器照旧
## 拿"离灭点线的距离"当深度代理，"对焦"于是还是那个可以直接算的量。
##
## 相机和当年烘图的那台是同一台（30mm、走道中央、瞄准走道尽头——Blender 的
## Z-up 已折算成 Godot 的 Y-up，见 CAM_POS / CAM_AIM / CAM_FOV），灭点位置
## 因此不变：景深代理和标题屏"右侧留灭点"的版面都不受换渲染方式的影响。
##
## 鼠标的两个分量各管一件事，合起来就是"镜头在动"：
##   左右 → 视差：镜头在走道里横移（画面朝反向滑）
##   上下 → 对焦：鼠标往上对远处，往下对近处（画面上下两端一起糊，中间清楚）
##
## 对外的结构：一个 SubViewport（3D 世界）+ 一个 TextureRect（挂着色器上屏）
## + 两层压暗。

## 渲染分辨率：与内容画布同尺寸。试过半分辨率再放大，LED 和几何细节全是
## 软的，叠加景深模糊之后整个画面发糊——分辨率给足，锐度才有保证；
## 像素颗粒感改由着色器的 2px 量化提供（见 _apply 的 pixel），不靠放大。
const VIEW_SIZE := Vector2i(1600, 900)

const HALL_SCENE := "res://assets/title/server_hall.glb"

## 相机：位置与瞄准点（Godot 坐标，Y-up）。等价于 Blender 里那台
## (0, -7.6, 1.38)、瞄准 (-1.05, 8.0, 1.22) 的相机：x 不动，y/z 互换、z 取反。
const CAM_POS := Vector3(0.0, 1.38, 7.6)
const CAM_AIM := Vector3(-1.05, 1.22, -8.0)
## 垂直视场角。30mm 镜头、36mm 传感器（16:9）→ 2·atan(0.6·9/16) ≈ 37.35°。
## Godot 的 fov 是垂直口径（默认 KEEP_HEIGHT），正好对上。
const CAM_FOV := 37.35

## 灭点在画面上的位置（占屏宽 / 屏高）。这是**算**出来的，不是估的：
## 相机水平半视角 31.0°、垂直 18.6°，灭点偏右 5.6%、偏上 1.5%。
## 相机参数改了就要改这里（景深代理引用它）。
const VP := Vector2(0.556, 0.485)

## 视差幅度：镜头在走道里横移的米数。±0.3m 是"站在原地侧了侧身"——
## 太小像没动，太大就走出了走道中线，机柜会怼到脸上。
const PARALLAX_M := 0.3
## 屏幕像素口径的视差（1600×900 基准）：layer_offset 对外报的就是它，
## 量级和旧版"整幅滑动"一致（标题屏和其他层对它的认知不用改）。
const PARALLAX_ROOM := 24.0
## 鼠标平滑速度（每秒衰减到 e^-speed）。直接跟手会抖，太慢又像拖不动。
const SMOOTH_SPEED := 6.0

## 焦点深度的取值范围。鼠标在最上方 = 对焦最远（灭点），最下方 = 对焦最近。
## 上限就是 1.0（画面下沿）。
const FOCUS_MIN := 0.0
const FOCUS_MAX := 1.0
## 离焦模糊上限（源图纹素 = 画布像素，渲染是 1:1 上屏）。
## 7px ≈ 旧版烘图（3200×1800）12 纹素的屏上观感（0.57 屏像素/纹素）。
const BLUR_ROOM := 7.0

## 机房的一点调色。画面本身是冷调，这里整体压暗一档——
## 菜单是"还没开灯的机房"，画面要暗得能容下反白的高亮块；
## 只微微染一点蓝，不提亮。
const ROOM_GAIN := 0.78
const ROOM_TINT := Color(0.92, 0.97, 1.0)
## 指示灯明灭深度（0~1），喂给 LED 材质。0.9 = 灭的时候留一点底亮。
const BLINK_STRENGTH := 0.9
## 三组 LED 的灯色。Blender 里就是这三种材质，名字即颜色。
const LED_TINTS := {
	"led_blue": Color(0.25, 0.5, 1.0),
	"led_white": Color(0.85, 0.92, 1.0),
	"led_cyan": Color(0.35, 0.9, 1.0),
}

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

var _viewport: SubViewport
var _rig: Node3D
var _cam: Camera3D
var _led_mats: Array[ShaderMaterial] = []
var _view: TextureRect
var _scrim_l: TextureRect
var _scrim_b: TextureRect

## 鼠标目标位置与平滑后的位置，都是 0~1 的屏幕占比
var _target := Vector2(0.5, 0.5)
var _mouse := Vector2(0.5, 0.5)
## 测试里关掉：headless 没有真鼠标，位置永远是 (0,0)
var follow_mouse := true

var _last_size := Vector2.ZERO
var _fade := 1.0
var _focus := 0.35
## 累计秒数：喂给 LED 材质的 time_s，驱动指示灯明灭
var _t := 0.0


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
	_t += maxf(delta, 0.0)
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


## 机房层当前的偏移（屏幕像素口径）。镜头横移本身是米制的，
## 这里折算回旧版"整幅滑动"的像素量级，给需要像素口径的人（测试、
## 想跟着背景一起滑的层）。
func layer_offset(_i: int) -> Vector2:
	return parallax_offset(_mouse, 1.0, PARALLAX_ROOM)


## 机房层当前的离焦模糊半径（纹素）。测试核对"焦点变化真的改变了模糊量"用。
## 这层铺满屏幕、深度是逐像素算的，对外只能报一个"中段"的值。
func layer_blur(_i: int) -> float:
	var mat := _view.material as ShaderMaterial
	return blur_for_depth(0.5, _focus, float(mat.get_shader_parameter("blur_max")))


# ================================================================ 纯函数（可测）

## 焦点深度：鼠标纵坐标（0 = 屏幕最上，1 = 最下）映射到 [FOCUS_MIN, FOCUS_MAX]。
static func focus_from_mouse(y: float) -> float:
	return lerpf(FOCUS_MIN, FOCUS_MAX, clampf(y, 0.0, 1.0))


## 离焦模糊半径：离焦点越远越糊。
static func blur_for_depth(depth: float, focus: float, blur_max: float) -> float:
	return blur_max * absf(depth - focus)


## 视差偏移：鼠标往右，画面往左（镜头在往右转）。
## weight 留着当纵深权重——真 3D 里纵深是自动的，这个量只服务对外接口。
static func parallax_offset(mouse: Vector2, weight: float, amount: float) -> Vector2:
	return (Vector2(0.5, 0.5) - mouse) * amount * weight


# ================================================================ 内部

func _build() -> void:
	_build_world()
	_view = _make_view()
	_scrim_l = _make_scrim(true)
	_scrim_b = _make_scrim(false)


## 3D 世界：环境 + 灯 + 机房 + 相机，全装在 SubViewport 里。
func _build_world() -> void:
	_viewport = SubViewport.new()
	_viewport.size = VIEW_SIZE
	_viewport.own_world_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)

	var world := Node3D.new()
	_viewport.add_child(world)

	# 环境：机房是"还没开灯"的暗调，环境光给一点冷蓝就够；
	# 雾把走道尽头压进黑里（密度压低，只留纵深暗示，多了画面发灰发糊）；
	# glow 接 LED 和荧光条的发光，强度压住——halo 一宽就是"没对上焦"。
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.008, 0.012, 0.02)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.45, 0.6, 0.85)
	env.ambient_light_energy = 0.4
	env.fog_enabled = true
	env.fog_light_color = Color(0.02, 0.035, 0.07)
	env.fog_density = 0.02
	env.glow_enabled = true
	env.glow_intensity = 0.45
	env.glow_bloom = 0.03
	env.glow_hdr_threshold = 1.0
	var we := WorldEnvironment.new()
	we.environment = env
	world.add_child(we)

	# 主光：从天上斜下来的冷光，把机柜顶和走道地面扫出一点方向感
	var sun := DirectionalLight3D.new()
	sun.light_color = Color(0.7, 0.82, 1.0)
	sun.light_energy = 0.4
	sun.rotation_degrees = Vector3(-38.0, 0.0, 0.0)
	world.add_child(sun)

	# 走道尽头的一点蓝辉光：画面的灭点方向有东西在亮，纵深才不闷
	var far_glow := OmniLight3D.new()
	far_glow.position = Vector3(0.0, 2.4, -13.0)
	far_glow.light_color = Color(0.5, 0.72, 1.0)
	far_glow.light_energy = 4.0
	far_glow.omni_range = 34.0
	world.add_child(far_glow)

	var hall: Node3D = (load(HALL_SCENE) as PackedScene).instantiate()
	world.add_child(hall)
	for mesh_name in LED_TINTS:
		var mi := hall.find_child(String(mesh_name), true, false) as MeshInstance3D
		if mi == null:
			push_warning("TitleBackdrop: 机房里找不到 %s" % mesh_name)
			continue
		var mat := ShaderMaterial.new()
		mat.shader = load("res://assets/shaders/led_blink.gdshader")
		mat.set_shader_parameter("tint", LED_TINTS[mesh_name])
		mat.set_shader_parameter("blink_strength", BLINK_STRENGTH)
		mi.material_override = mat
		_led_mats.append(mat)

	# 相机挂在一个 rig 下：rig 定在基准位姿，视差就是相机在 rig 局部空间里
	# 沿 X（走道的横向）平移。look_at 之后 rig 的 −Z 指向走道尽头。
	_rig = Node3D.new()
	world.add_child(_rig)
	_rig.position = CAM_POS
	_rig.look_at(CAM_AIM)
	_cam = Camera3D.new()
	_cam.fov = CAM_FOV
	_rig.add_child(_cam)
	_cam.current = true


func _make_view() -> TextureRect:
	var tr := TextureRect.new()
	# 铺满背景层。没人会替它算尺寸（压暗层的尺寸在 _apply 里显式设，
	# 这个要是也不设，就是一块 0×0 的空气——背景整个透明，主界面透出来）
	tr.set_anchors_preset(Control.PRESET_FULL_RECT)
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _viewport != null:
		tr.texture = _viewport.get_texture()

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
	if _view == null or size.x < 2.0 or size.y < 2.0:
		return
	if size != _last_size:
		_last_size = size
		_scrim_l.position = Vector2.ZERO
		_scrim_l.size = Vector2(size.x * SCRIM_LEFT_WIDTH, size.y)
		_scrim_b.position = Vector2(0.0, size.y * (1.0 - SCRIM_BOTTOM_HEIGHT))
		_scrim_b.size = Vector2(size.x, size.y * SCRIM_BOTTOM_HEIGHT)

	_focus = focus_from_mouse(_mouse.y)

	# 视差本体：镜头在走道里横移（rig 的局部 X）。近处机柜滑得多、远处少，
	# 纵深是几何给的。
	if _cam != null:
		var off_m := parallax_offset(_mouse, 1.0, PARALLAX_M)
		_cam.position = Vector3(off_m.x, 0.0, 0.0)

	var mat := _view.material as ShaderMaterial
	mat.set_shader_parameter("focus", _focus)
	mat.set_shader_parameter("blur_max", BLUR_ROOM)
	mat.set_shader_parameter("depth_fixed", -1.0)
	mat.set_shader_parameter("horizon", VP.y)
	mat.set_shader_parameter("screen_size", size)
	mat.set_shader_parameter("gain", ROOM_GAIN)
	mat.set_shader_parameter("tint", ROOM_TINT)
	mat.set_shader_parameter("vignette", VIGNETTE)
	mat.set_shader_parameter("scanline", SCANLINE)
	# 像素颗粒：2 画布像素一格，和点阵字同一种颗粒（渲染本身 1:1，
	# 颗粒感全靠这个量化提供）
	mat.set_shader_parameter("pixel", 2.0)
	mat.set_shader_parameter("fade", _fade)

	# LED 的时钟。三组灯共享一个 time_s，相位靠顶点色岔开。
	for m in _led_mats:
		m.set_shader_parameter("time_s", _t)

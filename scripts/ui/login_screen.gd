class_name LoginScreen
extends Control
## 接入屏：进游戏前的第一屏，PRTS 的"外部系统"。
##
## 两屏，一白一黑，靠整屏**横向色带翻转**切换（不是淡入淡出）：
##
##   白屏  身份确认：左上角品牌 + 四个小方块，中央一个打勾的圈、ID CONFIRMED、
##         身份信息确认中。，下面一张证件卡用虚线连到数据库图标。
##         这是"登入"那一屏，等玩家按一下。
##   黑屏  处理中：一条发光波形横贯画面，中央大号百分比 + 进度条 +
##         START PROCESSING / 开始读取权限…，数字从 0 走到 100。
##         走满就把画面翻成纯黑，交给开机自检（它从黑屏起步，接得上）。
##
## 白屏刻意是**暖白**（不是纯白），和游戏内的纯黑冷白拉开距离：
## 这是"系统之外"，进去之后才是 PRTS 的地盘。
##
## 没有声音：这一段是静的，紧接着开机自检的低频嗡鸣才会响起来。

## 登入完成（退场也播完了）。Main 接这个信号挂上开机自检。
signal finished

# ---------------------------------------------------------------- 时间轴

## 白屏：黑 → 暖白的翻块（分块见 bands）
const T_IN := 0.30
## 白屏上各元素落下的时刻（硬切，不淡入）
const T_BRAND := 0.34
const T_CENTER := 0.46
const T_PIPS := 0.54
const T_FOOT := 0.62
## 四个小方块之间错开多久
const PIP_GAP := 0.22
const PIP_COUNT := 4

## 色带条数与高度占比。两张表要对得上（BAND_COUNT 是 BAND_RATIOS 的长度）——
## 翻块结束的时刻是从它们算出来的，对不上就会算错（见 T_FLIP_DONE）。
const BAND_COUNT := 5
const BAND_RATIOS := [0.14, 0.22, 0.30, 0.18, 0.16]
## 一条色带与下一条之间错开多久（三个翻块阶段共用）
const BAND_GAP := 0.045

## 按下去之后：白 → 黑的翻块 → 百分比从 0 走到 100 → 停一下 → 翻黑
const T_FLIP := 0.36
## 翻块全部走完的时刻。计数必须等它：不然最后一条带子还白着，白字的百分比
## 已经画上去了——白字压白底，等于看不见。
const T_FLIP_DONE := T_FLIP + BAND_GAP * (BAND_COUNT - 1)
const T_COUNT := 1.60
const T_DONE_HOLD := 0.30
## 最后翻成纯黑（自检的底色），然后交棒
const T_OUT := 0.26

## 单帧最多按多少秒推进。异常长的一帧（拖窗口、系统卡顿、外部阻塞）会把整段
## 时间轴一次性推过去——这一屏"闪一下就没了"。宁可慢一点，也不要跳
## （和 Main 里给 VM 步进预算截断 delta 是同一个道理）。
const MAX_STEP_DELTA := 0.10

# ---------------------------------------------------------------- 配色
## 白屏是暖白：这套 OS 开场是"外面"，游戏里是纯黑冷白，两边要分得开。
const LIGHT_BG := Color("#e9e7e3")
## 白屏上游走的虚线
const LIGHT_DASH := Color("#c7c3bc")
const INK := Color("#111111")
const INK_SOFT := Color("#8b8781")
## 黑屏底色（比游戏内的纯黑浅一点，这样"翻成纯黑"那一步看得出来）
const DARK_BG := Color("#161616")
const DARK_LINE := Color("#3a3a3a")
const DARK_TEXT := Color("#e8e8e8")

# ---------------------------------------------------------------- 版面
const PAD := 72.0             ## 四周留白
## 中央那组东西的位置：横向以屏幕中线为准，纵向略低于中线
const CENTER_Y := 0.52
const RING_X := -200.0        ## 打勾的圈，相对中线
const RING_R := 36.0
const DIV_X := -140.0         ## 竖分隔线
const TEXT_X := -120.0        ## 两行字的左边界
## 黑屏中央：百分比 + 进度条那一组的半宽
const BAR_HALF := 150.0
## 波形的行进速度（弧度/秒）。主波 3.0 大约每秒走 0.35 个屏宽——
## 一段 2.4 秒的处理里它刚好从画面一头走到另一头，看得出来在流，
## 又不至于快到晃眼。次级分量是它的 0.37 倍（见 wave_y）。
const WAVE_SPEED := 3.0

enum { ST_LIGHT, ST_DARK, ST_OUT }

var _state := ST_LIGHT
var _t := 0.0
var _finished := false
var _title_font: FontVariation = null
var _caps_font: FontVariation = null


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# 压住报错弹窗（300）与开机动画（500）：接入屏是这一屏最上层的浮层
	z_index = 600
	mouse_filter = Control.MOUSE_FILTER_STOP


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# 拉字距的变体：品牌行和 START PROCESSING 那种"拉开的大写"要用
	_title_font = Prts.spaced_font(Prts.body_font(), 2)
	_caps_font = Prts.spaced_font(Prts.body_font(), 3)
	set_process(true)


func _process(delta: float) -> void:
	advance(minf(delta, MAX_STEP_DELTA))


## 推进时间轴。_process 只是转调它，测试可以直接按秒推进，不用等真实帧。
func advance(delta: float) -> void:
	if _finished:
		return
	_t += delta
	match _state:
		ST_LIGHT:
			# 等玩家按一下。_t 只用来走出场和点那四个小方块。
			pass
		ST_DARK:
			if _t >= dark_total():
				_state = ST_OUT
				_t = 0.0
		ST_OUT:
			if _t >= T_OUT:
				_finish()
				return
	queue_redraw()


## 接入。白屏上的"登入"：切到黑屏，百分比开始走。
## 只有白屏那一屏认这个动作——已经进黑屏了再按只是"跳过计数"（见 _input）。
func login() -> void:
	if _state != ST_LIGHT:
		return
	_state = ST_DARK
	_t = 0.0
	queue_redraw()


func is_finished() -> bool:
	return _finished


## 已播时长、当前相位、白屏那四个小方块点亮了几个。测试与调试用。
func elapsed() -> float:
	return _t


func state() -> int:
	return _state


func pip_count() -> int:
	return pips_at(_t)


# ================================================================ 时间轴（纯函数）

## 黑屏那一屏走完要多久：翻块 + 计数 + 停。
static func dark_total() -> float:
	return T_FLIP_DONE + T_COUNT + T_DONE_HOLD


## 黑屏的百分比。计数从翻块全部走完之后才开始，两端夹住。
static func percent_at(elapsed: float) -> int:
	var t := elapsed - T_FLIP_DONE
	return clampi(int(round(100.0 * clampf(t / T_COUNT, 0.0, 1.0))), 0, 100)


## 白屏那四个小方块点亮了几个。出场之后一个一个点起来，点满就停住
## （玩家什么时候按都行，不能让他看着一个空框等）。
static func pips_at(elapsed: float) -> int:
	var t := elapsed - T_PIPS
	if t < 0.0:
		return 0
	return clampi(int(floor(t / PIP_GAP)) + 1, 0, PIP_COUNT)


## 黑屏百分比下面那行中文。分三段而不是一句话挂到底：
## 数字在走，字也跟着换，才像"真的在读东西"。
static func status_for(percent: int) -> String:
	if percent < 40:
		return "开始读取权限…"
	if percent < 80:
		return "正在装载算法库…"
	return "排序单元就绪"


# ================================================================ 分块

## 屏幕横向切成几条色带。翻块（黑→白、白→黑、黑→纯黑）翻的就是它们。
##
## 高度刻意不等分：等分看着像测试图，不等分才像排版。加起来必须是 1.0——
## 留一条缝或叠上一条，底下的主界面就会从缝里透出来（见 test_login）。
static func bands(w: float, h: float) -> Array:
	var out: Array = []
	var y := 0.0
	for r in BAND_RATIOS:
		var bh := h * float(r)
		out.append(Rect2(0.0, y, w, bh))
		y += bh
	return out


## 一条色带这一帧该是什么颜色。
##
## 三个翻块阶段共用一个写法：每条带子有自己的时刻，到点了就整条硬切。
## 出场从上往下翻，白→黑从下往上翻（方向反过来，看着才像"又发生了一件事"），
## 收尾再从上往下翻成纯黑。
func _band_color(i: int) -> Color:
	var n := float(bands(size.x, size.y).size())
	var idx := float(i)
	match _state:
		ST_LIGHT:
			return LIGHT_BG if _t >= T_IN + BAND_GAP * idx else Prts.BLACK
		ST_DARK:
			return DARK_BG if _t >= T_FLIP + BAND_GAP * (n - 1.0 - idx) else LIGHT_BG
		_:
			return Prts.BLACK if _t >= BAND_GAP * idx else DARK_BG


# ================================================================ 输入

## 接入屏期间把所有输入都吃掉（含鼠标移动）：底下的界面正在被盖住，
## 让它收到一半输入、再被盖住，只会在结束时留下一堆悬停状态。
##
## 白屏：任意键/点击 = 登入。
## 黑屏：任意键 = 把计数推到底（"看过了，别等了"）。再按不会跳过交棒——
## 最后那 0.56 秒是给自检留的接口，跳过它会闪一下底下的主界面。
func _input(event: InputEvent) -> void:
	if _finished:
		return
	var pressed := false
	if event is InputEventKey:
		var k := event as InputEventKey
		pressed = k.pressed and not k.echo
	elif event is InputEventMouseButton:
		pressed = (event as InputEventMouseButton).pressed
	elif event is InputEventJoypadButton:
		pressed = (event as InputEventJoypadButton).pressed
	elif event is InputEventScreenTouch:
		pressed = (event as InputEventScreenTouch).pressed
	get_viewport().set_input_as_handled()
	if not pressed:
		return
	match _state:
		ST_LIGHT:
			login()
		ST_DARK:
			_t = maxf(_t, T_FLIP_DONE + T_COUNT)


func _finish() -> void:
	if _finished:
		return
	_finished = true
	finished.emit()
	# 自己消失。注意 Main 是在 finished 里**同步**挂上开机自检的：
	# 晚一帧的话，接入屏已经销毁、自检还没建，会闪一下底下的主界面。
	queue_free()


# ================================================================ 绘制

func _draw() -> void:
	var w := size.x
	var h := size.y
	if w < 64.0 or h < 64.0:
		return
	var font := Prts.body_font()

	# 先铺满黑：带子之间**不能有缝**（缝里会透出底下的主界面）
	draw_rect(Rect2(-12.0, -12.0, w + 24.0, h + 24.0), Prts.BLACK)

	var bs := bands(w, h)
	for i in bs.size():
		draw_rect(bs[i], _band_color(i))

	match _state:
		ST_LIGHT:
			_draw_light(w, h, font)
		ST_DARK:
			_draw_dark(w, h, font)


# ---------------------------------------------------------------- 白屏

func _draw_light(w: float, h: float, font: Font) -> void:
	# 游走的虚线：版面的骨架，把大片空白串起来，又不喧宾夺主。
	# 两条就够——三条叠在一起会织成一张网，把中央那组东西淹掉。
	_draw_wander(w, h, 0.0, 0.0)
	_draw_wander(w, h, 2.6, 1.4)

	_draw_brand(font)
	_draw_ident(w, h, font)
	_draw_foot(w, h, font)


## 游走的虚线。参考里那几条"没有起点也没有终点"的弧线是这版版面的骨架：
## 把大片空白串起来，又不喧宾夺主。用一条李萨如曲线（两个不同频率的正弦
## 分别当 x 与 y）沿路径打点——比存素材省事，也不怕分辨率变化。
func _draw_wander(w: float, h: float, phase: float, wobble: float) -> void:
	var steps := 560
	for i in steps:
		if i % 4 != 0:
			continue     # 隔三个画一个 = 虚线（画密了是一张网，不是虚线）
		var t := TAU * float(i) / float(steps)
		var p := Vector2(
			w * (0.5 + 0.47 * sin(t + phase)),
			h * (0.5 + 0.45 * sin(2.0 * t + phase * 1.7 + wobble)))
		draw_rect(Rect2(roundf(p.x), roundf(p.y), 2.0, 2.0), LIGHT_DASH)


## 左上角：品牌 + 四个小方块。方块是"检查项"的记号，一个一个点亮。
func _draw_brand(font: Font) -> void:
	if _t < T_BRAND:
		return
	var x := PAD
	draw_string(_title_font, Vector2(x, 96.0), "PRTS",
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_HUGE, INK)
	draw_string(font, Vector2(x, 120.0), "SORTING SERVER SIMULATOR",
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_SMALL, INK)
	# "排序单元"黑、"SORT-01"灰——参考里 TANGENT 黑、OS 灰就是这个分工
	draw_string(font, Vector2(x, 152.0), "排序单元", HORIZONTAL_ALIGNMENT_LEFT,
		-1.0, Prts.FS_BIG, INK)
	var kw := font.get_string_size("排序单元", HORIZONTAL_ALIGNMENT_LEFT, -1.0,
		Prts.FS_BIG).x
	draw_string(font, Vector2(x + kw + 10.0, 152.0), "SORT-01",
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_BIG, INK_SOFT)

	var lit := pips_at(_t)
	for i in PIP_COUNT:
		var r := Rect2(x + float(i) * 22.0, 170.0, 13.0, 13.0)
		if i < lit:
			draw_rect(r, INK)
		else:
			draw_rect(r, INK, false, 2.0)


## 中央：打勾的圈 + ID CONFIRMED / 身份信息确认中。 + 证件卡 --- 数据库。
func _draw_ident(w: float, h: float, font: Font) -> void:
	if _t < T_CENTER:
		return
	var cx := w * 0.5
	var cy := h * CENTER_Y

	# 打勾的圈
	var ring := Vector2(cx + RING_X, cy)
	draw_arc(ring, RING_R, 0.0, TAU, 48, INK, 5.0)
	var chk := PackedVector2Array([
		ring + Vector2(-15.0, 1.0), ring + Vector2(-4.0, 13.0), ring + Vector2(17.0, -13.0)])
	draw_polyline(chk, INK, 5.0)

	# 竖分隔线
	draw_rect(Rect2(cx + DIV_X, cy - 34.0, 1.0, 68.0), INK_SOFT)

	draw_string(_title_font, Vector2(cx + TEXT_X, cy - 8.0), "ID CONFIRMED",
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_BIG, INK)
	draw_string(font, Vector2(cx + TEXT_X, cy + 18.0), "身份信息确认中。",
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_SMALL, INK_SOFT)

	# 证件卡 --- 数据库
	var card := Rect2(cx + TEXT_X, cy + 40.0, 30.0, 22.0)
	draw_rect(card, INK, false, 2.0)
	draw_rect(Rect2(card.position.x + 5.0, card.position.y + 5.0, 8.0, 8.0), INK)
	draw_rect(Rect2(card.position.x + 17.0, card.position.y + 6.0, 9.0, 2.0), INK)
	draw_rect(Rect2(card.position.x + 17.0, card.position.y + 11.0, 9.0, 2.0), INK)

	var dy := card.position.y + card.size.y * 0.5
	var dx0 := card.position.x + card.size.x + 8.0
	var dx1 := dx0 + 96.0
	var dx := dx0
	while dx < dx1:
		draw_rect(Rect2(roundf(dx), roundf(dy), 5.0, 2.0), INK_SOFT)
		dx += 10.0

	_draw_cylinder(Vector2(dx1 + 26.0, dy - 2.0), 18.0, 8.0)
	_draw_burst(Vector2(dx1 + 26.0, dy - 30.0))


## 数据库图标：上下两个椭圆 + 两条竖边 + 两道分隔弧。只画轮廓，不填色。
func _draw_cylinder(c: Vector2, rx: float, ry: float) -> void:
	draw_polyline(_ellipse(c + Vector2(0.0, -16.0), rx, ry), INK, 2.0)
	draw_polyline(_ellipse(c + Vector2(0.0, 16.0), rx, ry), INK, 2.0)
	draw_rect(Rect2(c.x - rx, c.y - 16.0, 2.0, 32.0), INK)
	draw_rect(Rect2(c.x + rx - 2.0, c.y - 16.0, 2.0, 32.0), INK)
	for k in [1, 2]:
		draw_polyline(_ellipse(c + Vector2(0.0, -16.0 + 32.0 * float(k) / 3.0), rx, ry),
			INK_SOFT, 1.0)


func _ellipse(c: Vector2, rx: float, ry: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 25:
		var a := TAU * float(i) / 24.0
		pts.append(Vector2(c.x + cos(a) * rx, c.y + sin(a) * ry))
	return pts


## 数据库图标上方那个放射小火花。缓慢转，是这一屏唯一的动效——
## 别的地方都静着，它一转就说明"机器在做事"。
func _draw_burst(c: Vector2) -> void:
	var spin := _t * 0.9
	for i in 8:
		var a := TAU * float(i) / 8.0 + spin
		var ln := 6.0 + 4.0 * sin(_t * 3.0 + float(i))
		draw_line(c + Vector2(cos(a), sin(a)) * 3.0,
			c + Vector2(cos(a), sin(a)) * (3.0 + ln), INK, 2.0)


## 右下角：单元署名 + 一条小进度条（跟着四个小方块走）。
func _draw_foot(w: float, h: float, font: Font) -> void:
	if _t < T_FOOT:
		return
	draw_string(font, Vector2(w - PAD - 260.0, h - 74.0), "PRTS // 排序单元 SORT-01",
		HORIZONTAL_ALIGNMENT_RIGHT, 260.0, Prts.FS_SMALL, INK_SOFT)
	var bar := Rect2(w - PAD - 220.0, h - 58.0, 220.0, 5.0)
	draw_rect(bar, LIGHT_DASH)
	var pct := float(pips_at(_t)) / float(PIP_COUNT)
	draw_rect(Rect2(bar.position.x, bar.position.y, bar.size.x * pct, bar.size.y), INK)
	draw_rect(Rect2(bar.position.x + bar.size.x * pct - 1.0, bar.position.y - 4.0, 2.0, 13.0), INK)
	draw_string(font, Vector2(w - PAD - 290.0, h - 60.0), "%d%%" % int(round(pct * 100.0)),
		HORIZONTAL_ALIGNMENT_RIGHT, 30.0, Prts.FS_SMALL, INK)

	# 提示：这一屏在等玩家按一下。闪得不急不缓，别像在催人。
	if _state == ST_LIGHT and fmod(_t, 1.4) < 1.0:
		draw_string(font, Vector2(PAD, h - 58.0), "按任意键接入 PRTS",
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_SMALL, INK_SOFT)


# ---------------------------------------------------------------- 黑屏

func _draw_dark(w: float, h: float, font: Font) -> void:
	# 等五条带子全部翻完再画内容。翻块还在走的时候画上去，白字会浮在还没翻
	# 过来的浅色带子上——白字压白底，等于看不见（开机动画的标题也踩过同一脚）。
	if _t < T_FLIP_DONE:
		return
	_draw_glow_wave(w, h)
	_draw_process(w, h, font)


## 横贯画面的发光波形。一条主线 + 三层很淡的粗线当光晕——
## 比真去做辉光后处理省事得多，这套 GL Compatibility 下也稳。
## 光晕要叠够层数：只有一层的话是一根带毛边的线，不是"发光"。
func _draw_glow_wave(w: float, h: float) -> void:
	var pts := PackedVector2Array()
	var steps := 160
	for i in steps + 1:
		var u := float(i) / float(steps)
		pts.append(Vector2(w * u, wave_y(u, h, _t)))
	for glow in [[16.0, 0.04], [9.0, 0.07], [4.0, 0.12], [2.0, 0.85]]:
		draw_polyline(pts, Color(1.0, 1.0, 1.0, float(glow[1])), float(glow[0]))


## 波形上某一点的 y（u 是横向占比 0~1）。
##
## 波形是**走的**：给相位加一个随时间递增的项，波峰就沿着 x 一路推过去。
## 两个分量用不同的速度（主波快、次级慢），叠出来的形状会边走边变形——
## 同速的话整条只是平移，看着像一张图在滑，不像"信号在流"。
##
## 抽成纯函数（只吃占比、屏高、时刻）：动画对不对得**量**得出来——
## 光看两张截图说不清"它真的在动"，还是我截图时手抖了一下。
static func wave_y(u: float, h: float, t: float) -> float:
	return h * 0.5 + sin(t * 0.7) * h * 0.006 \
		+ sin(u * TAU * 1.35 + 0.6 + t * WAVE_SPEED) * h * 0.075 \
		+ sin(u * TAU * 0.8 + 1.9 + t * WAVE_SPEED * 0.37) * h * 0.010


## 中央：大号百分比 + 进度条 + START PROCESSING / 中文状态。
func _draw_process(w: float, h: float, font: Font) -> void:
	var cx := w * 0.5
	var cy := h * 0.5
	var pct := percent_at(_t)
	var x0 := cx - BAR_HALF

	# 百分比。数字大、百分号小且抬高——参考里就是这么排的
	var num := str(pct)
	var nw := font.get_string_size(num, HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_HUGE).x
	draw_string(font, Vector2(x0, cy - 26.0), num, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
		Prts.FS_HUGE, Prts.WHITE)
	draw_string(font, Vector2(x0 + nw + 4.0, cy - 26.0), "%",
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_BIG, DARK_TEXT)

	# 进度条：槽 + 白填充 + 头部一个小方块（参考里那条有个游标）
	var bar := Rect2(x0, cy - 2.0, BAR_HALF * 2.0, 6.0)
	draw_rect(bar, DARK_LINE)
	var fw := bar.size.x * float(pct) / 100.0
	draw_rect(Rect2(bar.position.x, bar.position.y, fw, bar.size.y), Prts.WHITE)
	draw_rect(Rect2(bar.position.x + fw - 3.0, bar.position.y - 7.0, 5.0, 5.0), Prts.WHITE)

	draw_string(_caps_font, Vector2(x0, cy + 30.0), "START PROCESSING",
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_SMALL, Prts.WHITE)
	draw_string(font, Vector2(x0, cy + 54.0), status_for(pct),
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_SMALL, DARK_TEXT)

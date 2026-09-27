class_name LoginScreen
extends Control
## 登入界面：进游戏前的第一屏，PRTS 接入终端。
##
## 位置在开机自检**之前**：先登入（你是谁、有没有权限），再自检（这台机器
## 现在什么状态），最后才进界面。少了这一屏，玩家一开游戏就直接坐在控制台前，
## 世界观里"要先接入系统"这一层就没了。
##
## 画面是**几块大色块拼出来的**：左边一整块白色当招牌，右边黑底分三块信息区。
## 出场和退场都是这几块**自己一块块翻色**——出场先把白块一块块拼起来（中间有
## 一瞬间整屏全白），再一块块翻黑把版面刻出来；退场反过来，一块块翻白、停一下、
## 再一块块翻黑，最后交给开机自检（它从黑屏起步，接得上）。
##
## 刻意不做淡入淡出：这套界面是硬边的，渐隐渐现立刻显得软——和 ErrorPopup 的
## 硬闪、开机动画的硬切是同一条规矩，这里连转场也是硬的，只是把"硬"做成了
## 大块面。
##
## 没有声音：这一段是静的，紧接着开机自检的低频嗡鸣才会响起来。
## 先静一段再让机器出声，比全程都有声音更压得住。

## 登入完成（退场也播完了）。Main 接这个信号挂上开机自检。
signal finished

# ---------------------------------------------------------------- 时间轴

## 出场总时长：黑屏 → 白块一块块拼起来 → 一块块翻黑 → 内容落下 → 可以登入
const T_INTRO := 0.92
## 出场里每一块之间错开多久（拼白块和翻黑块共用这个节奏）
const BLOCK_GAP := 0.10
## 左块（白招牌）先亮，右栏三块随后跟上
const INTRO_LEFT_AT := 0.08
const INTRO_RIGHT_AT := 0.14
## 整屏全白之后，右栏三块从这个时刻起一块块翻回黑。
## 要留出空档：三块白拼齐是 0.34，这里要是也写 0.34，整屏全白那一瞬间
## 就只有 0 秒——玩家永远看不到"整屏白"那一下，白拼得再齐也白拼。
const INTRO_CARVE_AT := 0.44
## 三块都翻黑、版面刻出来的时刻。内容一律等它——早一帧画上去，
## 浅灰的小标题和角标会浮在整屏全白的画面上，像印错了一层。
const INTRO_CARVE_DONE := INTRO_CARVE_AT + BLOCK_GAP * 2.0
## 单帧最多按多少秒推进。异常长的一帧（拖窗口、系统卡顿、外部阻塞）会把整段
## 时间轴一次性推过去——自检"闪一下就没了"、登入直接跳过整段转场。
## 宁可慢一点，也不要跳（和 Main 里给 VM 步进预算截断 delta 是同一个道理）。
const MAX_STEP_DELTA := 0.10

## 白块上的内容、右栏的键值行、按钮，各自从什么时候出现（硬切，不淡入）
const INTRO_LEFT_TEXT_AT := INTRO_CARVE_DONE
const INTRO_ROWS_AT := INTRO_CARVE_DONE + 0.04
const ROW_GAP := 0.05
const INTRO_BUTTON_AT := 0.86

## 退场总时长：内容清空 → 一块块翻白 → 停一下 → 一块块翻黑
const T_OUT := 0.80
## 内容（字与按钮）先清掉，再开始翻块
const OUT_CLEAR := 0.06
## 翻白：从右下往左上，一块块来
const OUT_WHITE_AT := 0.10
const OUT_WHITE_GAP := 0.09
## 整屏全白之后停一下，再翻黑（正序，左上先黑）
const OUT_HOLD := 0.12
const OUT_BLACK_GAP := 0.07

# ---------------------------------------------------------------- 配色

## 白块上的次级文字。整套界面只有黑白灰，白底上的"暗"就用中灰。
const INK_DIM := Color("#555555")

# ---------------------------------------------------------------- 版面
## 左白块占多宽（其余是右栏）。这个比例同时也是**分块线**：
## 转场时翻的就是这几块，版面本身和转场是同一套格子。
const LEFT_W := 0.42
## 右栏内容离分块线的左边距、离屏幕右边的右边距
const RIGHT_PAD_L := 72.0
const RIGHT_PAD_R := 72.0
## 左块里文字离块左边的距离（占屏宽）
const LEFT_PAD := 0.06

enum { ST_INTRO, ST_READY, ST_OUT }

var _btn: Button = null
## 右栏的键值行（[{key, value}, ...]），_ready 里取一次就定住——
## 数字来自存档，登入这几十秒里不会变，没必要每帧重取。
var _rows: Array = []
var _title_font: FontVariation = null
var _sub_font: FontVariation = null

var _state := ST_INTRO
var _t := 0.0
var _finished := false


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# 压住报错弹窗（300）与开机动画（500）：登入是这一屏最上层的浮层
	z_index = 600
	mouse_filter = Control.MOUSE_FILTER_STOP


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_title_font = Prts.spaced_font(Prts.body_font(), 8)
	_sub_font = Prts.spaced_font(Prts.body_font(), 4)
	_rows = _build_rows()
	_build_button()
	resized.connect(_layout)
	_layout()
	set_process(true)


func _process(delta: float) -> void:
	advance(minf(delta, MAX_STEP_DELTA))


## 推进时间轴。_process 只是转调它，测试可以直接按秒推进，不用等真实帧。
func advance(delta: float) -> void:
	if _finished:
		return
	_t += delta
	match _state:
		ST_INTRO:
			if _t >= T_INTRO:
				_enter_ready()
		ST_OUT:
			if _t >= T_OUT:
				_finish()
				return
	_refresh_button()
	queue_redraw()


## 登入。切到退场相位：内容清掉、几块大色块一块块翻白，停一下再翻回黑，
## 最后交给开机自检。只有"就绪"之后才认——出场还没播完就按键不算登入
## （那一下是跳过出场，见 _input）。
func login() -> void:
	if _state != ST_READY:
		return
	_state = ST_OUT
	_t = 0.0
	_refresh_button()
	queue_redraw()


func is_finished() -> bool:
	return _finished


## 已播时长与当前相位。测试用：不必去读私有字段。
func elapsed() -> float:
	return _t


func state() -> int:
	return _state


# ================================================================ 分块

## 屏幕的四个分块（左白块 + 右栏三段）。出场/退场翻的就是它们——
## 版面本身由这几块拼出来，转场翻的也是同一套格子，不另做一套特效。
##
## 做成静态纯函数（只吃宽高）：测试可以拿真实的 1600×900 验"拼满、不重叠"，
## 而这正是最要命的一条——留一条缝，底下的主界面就会从缝里透出来。
static func blocks(w: float, h: float) -> Array:
	var lw := w * LEFT_W
	return [
		Rect2(0.0, 0.0, lw, h),
		Rect2(lw, 0.0, w - lw, h * 0.30),
		Rect2(lw, h * 0.30, w - lw, h * 0.42),
		Rect2(lw, h * 0.72, w - lw, h * 0.28),
	]


## 一块在这一帧该是什么颜色。
##
## 出场：左块先白，右栏三块跟着白（一瞬间整屏全白），再一块块翻回黑。
## 退场：倒序翻白（右下先白），停一下，正序翻黑。
func _block_color(i: int) -> Color:
	if _state == ST_INTRO:
		if i == 0:
			return Prts.WHITE if _t >= INTRO_LEFT_AT else Prts.BLACK
		if _t < INTRO_RIGHT_AT + BLOCK_GAP * float(i - 1):
			return Prts.BLACK
		if _t < INTRO_CARVE_AT + BLOCK_GAP * float(i - 1):
			return Prts.WHITE
		return Prts.BLACK

	if _state == ST_READY:
		# 就绪时的块色就是版面本身：左块白、右栏黑。这一支不能漏——
		# 漏了会掉进退场的时间轴，就绪时整屏被算成黑，白块和上面的黑字全没了。
		return Prts.WHITE if i == 0 else Prts.BLACK

	# 退场
	var last := float(blocks(size.x, size.y).size() - 1)
	var white_at := OUT_WHITE_AT + OUT_WHITE_GAP * (last - float(i))
	var black_at := OUT_WHITE_AT + OUT_WHITE_GAP * last + OUT_HOLD + OUT_BLACK_GAP * float(i)
	if _t >= black_at:
		return Prts.BLACK
	if _t >= white_at:
		return Prts.WHITE
	return Prts.WHITE if i == 0 else Prts.BLACK


## 内容（白块上的字、右栏的键值行、按钮）现在该不该画。
## 退场一开始就把内容清掉：翻块的时候画面上只剩色块。
func _content_visible() -> bool:
	if _state == ST_OUT:
		return _t < OUT_CLEAR
	return true


# ================================================================ 版面与交互

func _build_button() -> void:
	_btn = Prts.button("登入系统")
	_btn.custom_minimum_size = Vector2(0, 56)
	# 24px 是点阵字体的合法字号（12 的整数倍），也是这套界面里第二大的字
	_btn.add_theme_font_size_override("font_size", Prts.FS_BIG)
	_btn.pressed.connect(login)
	_btn.visible = false
	add_child(_btn)


## 按钮摆右栏下方。界面其余部分都是 _draw 画的，只有按钮是真控件
## （要它自己的悬停/按下反白），所以位置得自己算。
func _layout() -> void:
	if _btn == null:
		return
	var w := size.x
	var h := size.y
	var x0 := w * LEFT_W + RIGHT_PAD_L
	_btn.position = Vector2(roundf(x0), roundf(h * 0.58))
	_btn.size = Vector2(roundf(minf(360.0, w - RIGHT_PAD_R - x0)), 56.0)


## 出场还没播完时，按钮不出现也不吃点击。
func _refresh_button() -> void:
	if _btn == null:
		return
	var want := _state == ST_READY or (_state == ST_INTRO and _t >= INTRO_BUTTON_AT)
	if _btn.visible != want:
		_btn.visible = want


func _enter_ready() -> void:
	_state = ST_READY
	_t = T_INTRO
	_refresh_button()
	queue_redraw()


## 右栏的键值行。数字取自真实存档（和开机自检同一套取法），
## 取不到 autoload 就退回"一台新机器"——headless 测试里就是这种情况。
func _build_rows() -> Array:
	var game: Variant = null
	if is_inside_tree():
		game = get_node_or_null("/root/Game")
	var runs := 0
	var cleared := 0
	if game != null:
		runs = int((game.stats as Dictionary).get("runs", 0))
		cleared = int(game.cleared)
	return rows_for(runs, cleared, ServerSpec.stage_count())


## 键值行的文案。纯函数（不碰 Game），测试可以直接喂数字进来。
static func rows_for(runs: int, cleared: int, stages: int) -> Array:
	return [
		["单元", "SORT-01"],
		["权限", "待确认"],
		["运行记录", "%s 次" % Prts.comma(runs)],
		["已通过", "%d / %d 关" % [cleared, stages]],
	]


func rows() -> Array:
	return _rows


# ================================================================ 输入

## 登入界面期间把所有输入都吃掉（含鼠标移动）：底下的界面正在被盖住，
## 让它收到一半输入、再被盖住，只会在登入结束时留下一堆悬停状态。
##
## 鼠标左键**不算登入**（要按就按那个按钮，见 _build_button）；键盘/手柄/
## 触摸任意键算——终端前的"按任意键继续"。
func _input(event: InputEvent) -> void:
	if _finished:
		return
	var any_key := false
	var mouse_click := false
	if event is InputEventKey:
		var k := event as InputEventKey
		any_key = k.pressed and not k.echo
	elif event is InputEventMouseButton:
		mouse_click = (event as InputEventMouseButton).pressed
	elif event is InputEventJoypadButton:
		any_key = (event as InputEventJoypadButton).pressed
	elif event is InputEventScreenTouch:
		any_key = (event as InputEventScreenTouch).pressed
	get_viewport().set_input_as_handled()

	if _state == ST_INTRO:
		# 出场没播完：这一下只是"跳过出场"，不算登入。快进到就绪，
		# 玩家想看的就是那一屏，别让他白按一次。
		if any_key or mouse_click:
			_enter_ready()
		return
	if any_key:
		login()


func _finish() -> void:
	if _finished:
		return
	_finished = true
	finished.emit()
	# 自己消失。注意 Main 是在 finished 里**同步**挂上开机自检的：
	# 晚一帧的话，登入已经销毁、自检还没建，会闪一下底下的主界面。
	queue_free()


# ================================================================ 绘制

func _draw() -> void:
	var w := size.x
	var h := size.y
	if w < 64.0 or h < 64.0:
		return
	var font := Prts.body_font()
	var show_content := _content_visible()

	# 先铺满黑：块与块之间**不能有缝**（缝里会透出底下的主界面），
	# 底下垫一层黑，万一某块算小了也看不出来。
	draw_rect(Rect2(-12.0, -12.0, w + 24.0, h + 24.0), Prts.BLACK)

	var bs := blocks(w, h)
	for i in bs.size():
		draw_rect(bs[i], _block_color(i))

	if not show_content:
		return
	_draw_left(w, h, font)
	_draw_right(w, h, font)
	_draw_chrome(w, h, font)


# ---------------------------------------------------------------- 左白块

## 左边那一整块白：招牌。白底黑字，只放最少的字——
## 这一块的作用是"色块"本身，字多了就变成一张卡片了。
func _draw_left(w: float, h: float, font: Font) -> void:
	if _state == ST_INTRO and _t < INTRO_LEFT_TEXT_AT:
		return
	var x := w * LEFT_PAD
	var base := h * 0.40

	draw_string(_title_font, Vector2(roundf(x), roundf(base)), "PRTS",
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_HUGE, Prts.BLACK)
	draw_rect(Rect2(roundf(x), roundf(base) + 18.0, w * LEFT_W - x - w * 0.06, 2.0),
		Prts.BLACK)
	draw_string(font, Vector2(roundf(x), roundf(base) + 56.0), "排序单元接入终端",
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_BIG, Prts.BLACK)
	draw_string(_sub_font, Vector2(roundf(x), roundf(base) + 84.0), "SORTING UNIT ACCESS",
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_SMALL, INK_DIM)

	# 底部的条码 + 编号：机器可读的那一套，也把白块下半部的空白填住
	_draw_barcode(roundf(x), h * 0.76, w * LEFT_W - x - w * 0.06)
	draw_string(font, Vector2(roundf(x), h * 0.86), "SORT-01 · BUILD 4.7.2",
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_SMALL, Prts.BLACK)


## 机器可读的编号条。固定种子：图案每次开机一样，它是这块版面的装饰，
## 每次都不一样只会显得像噪点。
func _draw_barcode(x: float, y: float, w: float) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x534f5254     # "SORT"
	var cx := x
	while cx < x + w:
		var bw := float(rng.randi_range(2, 6))
		if rng.randf() < 0.28:
			bw = 1.0
		draw_rect(Rect2(roundf(cx), roundf(y), bw, 26.0), Prts.BLACK)
		cx += bw + float(rng.randi_range(2, 5))


# ---------------------------------------------------------------- 右栏

## 右栏：接入终端的本体。小节标题 + 键值行 + 登入按钮，
## 外面套一圈 PRTS 的四角角标（和可视化面板、报错弹窗同一个装饰）。
func _draw_right(w: float, h: float, font: Font) -> void:
	if not _right_visible():
		return
	var x0 := w * LEFT_W + RIGHT_PAD_L
	var x1 := w - RIGHT_PAD_R
	var head := h * 0.16

	# 四角角标把整栏框住。_draw_brackets 是和 PrtsFrame 共用的那一份
	# （以前开机动画里抄过一遍，抄错了下面两个角——所以现在只有一份实现）。
	PrtsFrame.draw_brackets(self, Rect2(x0 - 40.0, h * 0.12, (x1 - x0) + 80.0, h * 0.60),
		24.0, 3.0, Prts.FRAME_IDLE)

	# 小节标题：左边一条白竖杠 + 标题 + 右边延伸到底的细线（同 Prts.section）
	draw_rect(Rect2(roundf(x0), roundf(head) - 12.0, 3.0, 14.0), Prts.WHITE)
	draw_string(font, Vector2(roundf(x0) + 12.0, roundf(head)), "接入终端 · ACCESS TERMINAL",
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_SMALL, Prts.TEXT_HI)
	draw_rect(Rect2(roundf(x0), roundf(head) + 14.0, x1 - x0, 1.0), Prts.LINE)

	# 键值行：左键右值，一行行往下落（每行自己的时刻，硬切）
	for i in _rows.size():
		if _state == ST_INTRO and _t < INTRO_ROWS_AT + ROW_GAP * float(i):
			continue
		var y := h * 0.26 + 30.0 * float(i)
		var row: Array = _rows[i]
		draw_string(font, Vector2(roundf(x0), roundf(y)), String(row[0]),
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_SMALL, Prts.DIM)
		draw_string(font, Vector2(roundf(x0), roundf(y)), String(row[1]),
			HORIZONTAL_ALIGNMENT_RIGHT, x1 - x0, Prts.FS_SMALL, Prts.WHITE)

	# 按钮下面的提示 + 闪动的光标（"可以按了"的信号）
	if not _hint_visible():
		return
	var hy := h * 0.58 + 56.0 + 30.0
	draw_string(font, Vector2(roundf(x0), roundf(hy)), "点击按钮，或按任意键",
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_SMALL, Prts.DIM)
	if _state == ST_READY and _blink_on():
		draw_rect(Rect2(roundf(x0) + 190.0, roundf(hy) - 11.0, 6.0, 12.0), Prts.WHITE)



## 右栏（角标、小节标题、细线、键值行）等三块都翻黑之后才画。
func _right_visible() -> bool:
	return _state != ST_INTRO or _t >= INTRO_CARVE_DONE


## 提示行和光标跟着按钮一起出现，退场一开始就跟内容一起清掉。
func _hint_visible() -> bool:
	return _state == ST_READY or _t >= INTRO_BUTTON_AT


## 角上的小字：右上角是当前时间（真取系统时间——这台终端是"活"的），
## 右下角是授权提示。两处跟着右栏的内容一起出现，之后一直在——
## 只在出场相位画的话，一进就绪时钟就没了，像画面掉了一块。
func _draw_chrome(w: float, h: float, font: Font) -> void:
	if _state == ST_INTRO and _t < INTRO_ROWS_AT:
		return
	draw_string(font, Vector2(w - RIGHT_PAD_R - 240.0, 44.0), _now_text(),
		HORIZONTAL_ALIGNMENT_RIGHT, 240.0, Prts.FS_SMALL, Prts.DIM)
	draw_string(font, Vector2(w - RIGHT_PAD_R - 240.0, h - 22.0), "仅授权单元可接入",
		HORIZONTAL_ALIGNMENT_RIGHT, 240.0, Prts.FS_SMALL, Prts.LINE_HI)


static func _now_text() -> String:
	var d := Time.get_datetime_dict_from_system()
	return "%04d-%02d-%02d %02d:%02d:%02d" % [
		int(d["year"]), int(d["month"]), int(d["day"]),
		int(d["hour"]), int(d["minute"]), int(d["second"])]


func _blink_on() -> bool:
	return fmod(_t, 1.0) < 0.55

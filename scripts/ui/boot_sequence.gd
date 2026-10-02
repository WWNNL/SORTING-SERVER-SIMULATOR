class_name BootSequence
extends Control
## 开机自检动画：启动时压在界面上播一遍的 PRTS 冷启动流程，播完自己销毁。
##
## 为什么要有它：这个世界观里玩家是 PRTS 底下的一个排序单元，"直接进界面"
## 等于跳过了"你是谁、在谁的地盘上"这一层。自检把它补上——机器先自报家门、
## 逐项检查**你真实的硬件和存档**，最后确认权限、宣布开始监控。
##
## 压迫感来自三处，缺一不可：
##   · 冷冰冰的真实数据：念的是你攒下的家当（Game 里的档位、文件、进度），
##     不是写死的文案。第二次开机它会念出你现在的配置，像这台机器认识你。
##   · 不喘气的节奏：每行 0.2 秒，来不及读完但看得见关键词；中间插三处故障
##     （横向撕裂、整块错位、乱码），红字警告配四下硬闪。
##   · 声音：低频嗡鸣一路升调铺到底，见 BootAudio。
##
## 全自绘（_draw），不用 Label：故障效果要逐字换字、整块错位、横向撕裂，
## 控件树上做不到（和 VizView / PrtsFrame 同一条路子）。
##
## 整段约 5 秒，任意键/鼠标随时可跳过——跳过也走收束相位，仍然给一个干脆的收尾。

## 播完了。Main 接这个信号把引用清掉。
signal finished

# ---------------------------------------------------------------- 配色

## 红只给"警报"用。整套界面是黑白灰（见 Prts），红是报错弹窗的语言，
## 而自检里那两条警告属于同一类——系统在报警，不是在报错。色值跟 ErrorPopup 取齐。
const C_RED := Color("#ff4d4f")
const C_RED_DIM := Color("#5a1416")

# ---------------------------------------------------------------- 时间轴

## 黑屏静默→通电。刻意留一段全黑：上来就噼里啪啦，玩家还没坐稳，
## 压迫感反而被"热闹"冲淡。
const T_POWER := 0.30
## 自检日志第一行出现
const T_LOG := 0.55
## 行间隔。0.2 秒是"来不及读完、但看得见关键词"的节奏——
## 再快就只是一片闪，再慢就没有机器一路推进的劲儿。
const LINE_GAP := 0.20
## 单行逐字打完的时长
const LINE_TYPE := 0.11
## 警示拍：红框拍到位 + 四下硬闪 + 蜂鸣
const T_ALERT_HOLD := 0.85
## 标题停留
const T_TITLE_HOLD := 0.95
## 收束：白闪 → 纵向塌成一条线
const T_CUT := 0.35
## 收束里白闪占多久、塌陷占多久（塌完剩一点时间让那条线停一下再消失）
const CUT_FLASH := 0.06
const CUT_SQUASH := 0.24
## 收束末尾留下的线的高度（占屏高的比例）。塌到 0 就什么都看不见了，
## 留 5‰（900px 下 4.5px）才有"关机时那一条亮线"的样子。
const SQUASH_MIN := 0.005

## 警示拍的四下硬闪。关键帧按"保持到下一帧"取值，不做插值——
## 硬切才像警报灯，插值就成了渐入渐出（那是"加载中"的语汇，见 ErrorPopup）。
const ALERT_FLASH := [
	[0.00, 0.00], [0.05, 0.16], [0.09, 0.02], [0.20, 0.20], [0.26, 0.00],
	[0.48, 0.12], [0.54, 0.00], [0.78, 0.06], [0.84, 0.00], [1.00, 0.00],
]


## 单帧最多按多少秒推进。异常长的一帧（拖窗口、系统卡顿、外部阻塞）会把整段
## 时间轴一次性推过去——自检"闪一下就没了"、登入直接跳过整段转场。
## 宁可慢一点，也不要跳（和 Main 里给 VM 步进预算截断 delta 是同一个道理）。
const MAX_STEP_DELTA := 0.10

## 故障窗口的时刻是**算**出来的（落在某几行的落字瞬间上），见 _schedule_glitches
const GLITCH_SPAN := [0.14, 0.10, 0.30]   ## 三处故障各自的时长
## 乱码用的字符。只用 ASCII：点阵中文字体里没有制表符和方块，
## 混进来会掉到系统字体兜底上，字形风格当场就花了。
const SCRAMBLE := "#%*/\\<>|_+=~^"

# ---------------------------------------------------------------- 尺寸
## 布局全按屏占比算，不写死像素：这套界面在 1600×900 上量过，
## 但窗口是可缩放的，写死的话换个分辨率日志块就贴边了。
const LOG_X0 := 0.09          ## 日志块左边距
const LOG_X1 := 0.91          ## 右侧状态列的右边界
## 日志块顶部。11 行日志必须整个待在**标题框上方**：标题框是居中的
## （上沿在中线往上 65px），日志要是不挪上去，最后两行和警示框就会
## 压在标题框上。所以它比"看着顺眼"的位置更靠上一点。
const LOG_TOP := 0.12
const LOG_LINE_H := 22.0      ## 行高（12px 字 + 10px 行距）
const STATUS_W := 0.22        ## 状态列宽度（占屏宽）
## 标题框：基线在框顶下方 46px、框高 130px（36px 标题 + 白线 + 副标题 + 小字）。
## 这两个数一起决定框的位置——框心对齐屏幕中线，见 _draw_title。
const TITLE_BOX_H := 130.0
const TITLE_BASELINE_IN := 46.0

var _lines: Array = []
## 三处故障：[起始时刻, 时长]
var _glitches: Array = []
## 标题下那行副标题用的拉字距字体（每帧新建一个 FontVariation 太浪费）
var _sub_font: FontVariation = null
var _audio: BootAudio = null

var _t := 0.0
var _finished := false
## 已经放过嗒声的行数，以及三个单次拟音放过没有
var _cued := 0
var _alert_cued := false
var _thump_cued := false
var _cut_cued := false

## 本帧的故障状态：抖动偏移与撕裂带（[y, 高, 横向错位]）。
## 在 advance 里按帧算一次，_draw 直接用——_draw 一帧可能被调多次，
## 在里面摇骰子的话同一帧的两次绘制会长得不一样。
var _glitch := false
var _shake := Vector2.ZERO
var _bands: Array = []
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# 压住报错弹窗（300）：开机动画期间它就是最上层
	z_index = 500
	# 吃掉所有鼠标事件：动画期间底下的界面不该被点到
	mouse_filter = Control.MOUSE_FILTER_STOP


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_sub_font = Prts.spaced_font(Prts.body_font(), 5)
	prepare(_facts_from_game())
	_audio = BootAudio.new()
	_audio.name = "BootAudio"
	add_child(_audio)
	_audio.start()
	set_process(true)


func _process(delta: float) -> void:
	advance(minf(delta, MAX_STEP_DELTA))


## 推进时间轴。_process 只是转调它，测试可以直接按秒推进，不用等真实帧。
func advance(delta: float) -> void:
	if _finished:
		return
	_t += delta
	_cue()
	if _t >= end_time():
		_finish()
		return
	_update_jitter()
	queue_redraw()


## 跳过。不直接结束——跳到收束相位，仍然给一个干脆的收尾（白闪 + 塌成一条线）。
## 玩家按了键就是想走，但"啪"一下直接消失会像游戏崩了；0.35 秒的收束既不拖沓，
## 又让这次开机有个交代。
func skip() -> void:
	if _finished or _t >= cut_time():
		return
	_t = cut_time()
	if _audio != null:
		_audio.stop_hum()
		_audio.play_cut()
	_cut_cued = true
	_update_jitter()
	queue_redraw()


func is_finished() -> bool:
	return _finished


## 已播时长与自检行数。测试用：不必去读私有字段。
func elapsed() -> float:
	return _t


func line_count() -> int:
	return _lines.size()


## 故障窗口（[起始时刻, 时长]）。测试用：验它们都落在日志相位里。
func glitch_windows() -> Array:
	return _glitches


# ================================================================ 时间轴

## 第 i 行的出现时刻
func line_time(i: int) -> float:
	return T_LOG + LINE_GAP * float(i)


## 自检日志播完的时刻 = 警示拍开始
func alert_time() -> float:
	return line_time(_lines.size())


func title_time() -> float:
	return alert_time() + T_ALERT_HOLD


func cut_time() -> float:
	return title_time() + T_TITLE_HOLD


func end_time() -> float:
	return cut_time() + T_CUT


## 逐字打完一行的时长。"loud"行（最后那句"监控已启用"）几乎是砸出来的，
## 不打字——它是一句通告，不是一条检查结果。
func _type_time(i: int) -> float:
	if i < 0 or i >= _lines.size():
		return LINE_TYPE
	return LINE_TYPE * (0.18 if String((_lines[i] as Dictionary)["kind"]) == "loud" else 1.0)


## 正在落字的行号，-1 表示当前没有（每行在 LINE_GAP 内打完，打完到下一行
## 出现之间有个空档，光标在那时候闪）。
func _typing_index() -> int:
	for i in _lines.size():
		if _t >= line_time(i) and _t < line_time(i) + _type_time(i):
			return i
	return -1


## 红色警告行的下标（框住它和它后面那行）
func _alert_index() -> int:
	for i in range(_lines.size() - 1, -1, -1):
		if String((_lines[i] as Dictionary)["kind"]) == "alert":
			return i
	return maxi(0, _lines.size() - 1)


## 装配时间轴。做成显式入口（而不是全塞在 _ready 里）是为了测试：
## 测试可以喂一组假数据，不用真的去读存档、也不用进场景树。
func prepare(facts: Dictionary) -> void:
	_lines = boot_lines(facts)
	_schedule_glitches()
	_t = 0.0
	_cued = 0
	_alert_cued = false
	_thump_cued = false
	_cut_cued = false
	_finished = false
	_glitch = false
	_shake = Vector2.ZERO
	_bands = []
	# 固定种子：故障的样子每次开机都一样。这是演出的固定动作，
	# 随机只会让"这次开机看起来坏了没有"变成抽签，也让截图没法复现。
	_rng.seed = 0x424f4f54     # "BOOT"


## 三处故障的时刻。刻意落在某几行的落字瞬间上，而不是均匀分布：
## 均匀分布会变成节拍器，玩家两下就摸清了；落在落字上像是
## "读到这一行的时候，机器打了个趔趄"。
func _schedule_glitches() -> void:
	_glitches = []
	var n := _lines.size()
	if n <= 0:
		return
	_glitches.append([line_time(int(n * 0.36)), GLITCH_SPAN[0]])
	_glitches.append([line_time(int(n * 0.72)), GLITCH_SPAN[1]])
	# 最大的一次盖住那条红字警告
	_glitches.append([line_time(_alert_index()), GLITCH_SPAN[2]])


# ================================================================ 自检日志

## 念出来的数字全部来自真实的存档与硬件。这是"这台机器认识你"的来源——
## 写死的文案做不到这一点：第二次开机它会念出你现在攒下的家当。
##
## 这里刻意用 /root/Game 动态取，而不是直接写全局名 Game：headless 测试
## （godot --script）里没有 autoload，写了全局名的脚本连编译都过不去，
## 测试也就加载不了它。取不到就退回一组"裸机"默认值（C-01 + 512B + 40W）。
func _facts_from_game() -> Dictionary:
	var game: Variant = null
	if is_inside_tree():
		game = get_node_or_null("/root/Game")
	if game == null:
		return {
			"ram": 512, "disk": 512, "psu": 40, "draw": 23, "cpu": 60,
			"files": 0, "unlocked": 0, "saved": false, "cleared": 0,
			"stages": ServerSpec.stage_count(),
		}
	return {
		"ram": game.ram_bytes(),
		"disk": game.disk_bytes(),
		"psu": game.psu_watts(),
		"draw": game.total_draw(),
		"cpu": game.cpu_rate(),
		"files": game.files.size(),
		"unlocked": game.unlocked_count(),
		"saved": FileAccess.file_exists(String(game.SAVE_PATH)),
		"cleared": game.cleared,
		"stages": ServerSpec.stage_count(),
	}


## 自检日志的文案。纯函数（不碰 Game），测试可以直接喂一组数字进来，
## 包括"没有存档 + 供电不足"这种真机上要攒很久才碰得到的组合。
##
## 每行是 {text, status, kind}：
##   sys    常规检查项，点线把左边的项目名和右边的结果连起来
##   alert  红色警告行
##   loud   不逐字打、直接砸出来的白字行（最后那句通告）
static func boot_lines(f: Dictionary) -> Array:
	var psu := int(f.get("psu", 0))
	var draw := int(f.get("draw", 0))
	var head := psu - draw
	var lines: Array = []
	lines.append({"text": "PRTS KERNEL 4.7.2 · 排序单元 SORT-01", "status": "", "kind": "sys"})
	lines.append({"text": "内存自检", "kind": "sys",
		"status": "%s B 可用" % Prts.comma(int(f.get("ram", 0)))})
	lines.append({"text": "硬盘自检", "kind": "sys",
		"status": "%s B 可用" % Prts.comma(int(f.get("disk", 0)))})
	lines.append({"text": "电源自检", "kind": "sys",
		"status": "%s W 额定" % Prts.comma(psu)})
	# 供电不足时不另起一行报错，就把这一行染红：负载分配本来就是"这项检查"，
	# 结果不合格自然该是红的。真到开机失败，进界面后主控台还会再报一次。
	lines.append({"text": "负载分配", "kind": "sys" if head >= 0 else "alert",
		"status": ("%s W / 余量 %s W" % [Prts.comma(draw), Prts.comma(head)]) if head >= 0
			else ("%s W / 超出 %s W" % [Prts.comma(draw), Prts.comma(-head)])})
	lines.append({"text": "处理器", "kind": "sys",
		"status": "%s 步 / 秒" % Prts.comma(int(f.get("cpu", 0)))})
	lines.append({"text": "算法库", "kind": "sys",
		"status": "%d 个文件 · 已解锁 %d" % [int(f.get("files", 0)), int(f.get("unlocked", 0))]})
	lines.append({"text": "存档", "kind": "sys",
		"status": "已读取" if bool(f.get("saved", false)) else "未找到 · 已初始化"})
	lines.append({"text": "阶段进度", "kind": "sys",
		"status": "已通过 %d / %d" % [int(f.get("cleared", 0)), int(f.get("stages", 0))]})
	lines.append({"text": "单元权限已确认", "status": "[!]", "kind": "alert"})
	lines.append({"text": "监控已启用。", "status": "", "kind": "loud"})
	return lines


# ================================================================ 故障

func _glitch_on() -> bool:
	for g in _glitches:
		if _t >= float(g[0]) and _t < float(g[0]) + float(g[1]):
			return true
	return false


## 按帧摇一次骰子：抖动偏移 + 故障期间的一到两条撕裂带。
##
## 抖动有三个来源，都是"画面被震了一下"这同一件事：
##   · 故障窗口：1~2px，像信号抖了一下
##   · 警示硬闪：3px，闪是灯、抖是震动，两样一起才像"这机器出事了"
##   · 标题砸下：落定后 0.1 秒的重抖，给那声闷响一个落点
## 再大就不像信号问题，像画面在乱跳了。
func _update_jitter() -> void:
	_glitch = _glitch_on()
	_bands = []
	if _glitch:
		_shake = Vector2(float(_rng.randi_range(-2, 2)), float(_rng.randi_range(-1, 2)))
	elif _alert_wash() > 0.10:
		_shake = Vector2(float(_rng.randi_range(-3, 3)), float(_rng.randi_range(-2, 2)))
	elif _t >= title_time() and _t < title_time() + 0.10:
		_shake = Vector2(float(_rng.randi_range(-3, 3)), float(_rng.randi_range(-2, 2)))
	else:
		_shake = Vector2.ZERO
		return
	if not _glitch:
		return
	var span := _log_height()
	for _i in _rng.randi_range(1, 2):
		var by := _log_top() + _rng.randf_range(-14.0, span + 14.0)
		var bh := _rng.randf_range(6.0, 20.0)
		var xo := float(_rng.randi_range(6, 18))
		if _rng.randf() < 0.5:
			xo = -xo
		_bands.append([by, bh, xo])


## 这一行落在哪条撕裂带里（不在任何带里就返回空数组）
func _band_at(y: float) -> Array:
	for b in _bands:
		if y >= float(b[0]) - LOG_LINE_H * 0.5 and y <= float(b[0]) + float(b[1]) + LOG_LINE_H * 0.5:
			return b
	return []


# ================================================================ 拟音

## 按时间轴放声音。每声只放一次，用 _cued / _xxx_cued 记账——
## 放在 advance 里而不是 _draw 里：_draw 一帧可能被调多次，声音会叠。
func _cue() -> void:
	if _audio == null:
		return
	while _cued < _lines.size() and _t >= line_time(_cued):
		_audio.play_tick()
		_cued += 1
	if not _alert_cued and _t >= alert_time():
		_alert_cued = true
		_audio.play_buzz()
	if not _thump_cued and _t >= title_time():
		_thump_cued = true
		_audio.play_thump()
	if not _cut_cued and _t >= cut_time():
		_cut_cued = true
		_audio.play_cut()
		_audio.stop_hum()


func _finish() -> void:
	if _finished:
		return
	_finished = true
	if _audio != null:
		_audio.stop_all()
	finished.emit()
	# 自己消失：挂着它的地方不用记着"播完要清掉"。
	queue_free()


# ================================================================ 输入

## 动画期间把所有输入都吃掉（含鼠标移动）：底下的界面正在被盖住，
## 让它先收到一半输入、再被盖住，只会在动画结束时留下一堆悬停状态。
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
	if pressed:
		skip()


# ================================================================ 绘制

func _draw() -> void:
	var w := size.x
	var h := size.y
	if w < 64.0 or h < 64.0:
		return
	var font := Prts.body_font()

	# 收束：整幅画面纵向塌成一条线（老式关机）。变换放在最前面，背景也跟着塌——
	# 塌掉的地方是**不画**的，底下的主界面因此自己露出来。
	var squash := _squash()
	var off := Vector2(0.0, h * (1.0 - squash) * 0.5) + _shake
	if squash < 1.0 or _shake != Vector2.ZERO:
		draw_set_transform(off, 0.0, Vector2(1.0, squash))

	# 背景比屏幕画大一圈：抖动是整屏变换，刚好铺满的话会有一条边露出底下的主界面
	draw_rect(Rect2(-12.0, -12.0, w + 24.0, h + 24.0), Prts.BG)

	if _t >= T_POWER:
		_draw_scanlines(w, h)
		_draw_chrome(w, h, font)

	var fade := _log_fade()
	if _t >= T_LOG and not _lines.is_empty():
		_draw_log(w, font, fade)
	if _t >= alert_time() and not _lines.is_empty():
		_draw_alert(w, font, fade)
	if _t >= title_time():
		_draw_title(w, h, font)

	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	# 警示硬闪压在内容之上、白闪之下
	var wash := _alert_wash()
	if wash > 0.0:
		draw_rect(Rect2(0.0, 0.0, w, h), Color(C_RED.r, C_RED.g, C_RED.b, wash))
	var flash := _flash()
	if flash > 0.0:
		draw_rect(Rect2(0.0, 0.0, w, h), Color(1.0, 1.0, 1.0, flash))


## CRT 扫描线：每 3px 一条 1px 的极暗白线。纯黑背景太"干净"了，像没通电。
func _draw_scanlines(w: float, h: float) -> void:
	var c := Color(1.0, 1.0, 1.0, 0.035)
	var y := 0.0
	while y < h:
		draw_rect(Rect2(0.0, y, w, 1.0), c)
		y += 3.0


## 点线：把项目名和右边的结果连起来。用点而不是虚线字符——
## 字符宽度在比例字体里对不齐列，点线能精确控制到像素。
##
## 点的大小和间距跟着窗口倍率走（窗口 = 1600×900 画布的整数倍，见 GameSettings）：
## 1× 是 1px 点 / 4px 距，2× 是 2px 点 / 8px 距，3× 是 3px / 12px。不跟着走的话，
## 高分辨率下 1px 的点夹在按倍率放大的字里细成一根刺，点线断得看不出是"线"。
func _draw_dotted(from_x: float, to_x: float, y: float, color: Color) -> void:
	if to_x - from_x < 16.0:
		return
	var metric := dotted_metrics(_window_factor())
	var x := ceilf(from_x)
	while x < to_x:
		draw_rect(Rect2(x, y, metric.x, metric.y), color)
		x += metric.y


## 窗口倍率：窗口宽 / 内容画布宽。设置里 2× 分辨率就是 2.0，拖拽出非整数倍时
## 取整数部分（点要落在整像素格上，nearest 放大才是方的）。
func _window_factor() -> float:
	var base := get_viewport().get_visible_rect().size.x
	return DisplayServer.window_get_size().x / maxf(base, 1.0)


## 点线的一组几何：(点的大小, 点距)，都按内容像素算。纯函数，测试用。
static func dotted_metrics(factor: float) -> Vector2:
	var size := maxf(1.0, floorf(factor))
	return Vector2(size, 4.0 * size)


## 标题起来之后把自检日志压暗：它退成背景，画面主体交给标题。
func _log_fade() -> float:
	var t := _t - title_time()
	if t <= 0.0:
		return 1.0
	return lerpf(1.0, 0.42, clampf(t / 0.18, 0.0, 1.0))


static func _dim(c: Color, f: float) -> Color:
	return Color(c.r * f, c.g * f, c.b * f, c.a)


func _log_top() -> float:
	return size.y * LOG_TOP


func _log_height() -> float:
	return float(_lines.size()) * LOG_LINE_H


# ---------------------------------------------------------------- 日志块

func _draw_log(w: float, font: Font, fade: float) -> void:
	var x0 := w * LOG_X0
	var x1 := w * LOG_X1
	var status_w := w * STATUS_W
	var typing := _typing_index()
	var head := _log_top() + _shake.y

	# 读头：正在落字的那一行下面一条亮线，跟着一行行往下走。
	# 机器"正在读这一行"的感觉全靠它。
	if typing >= 0:
		var ry := head + float(typing) * LOG_LINE_H + 8.0
		draw_rect(Rect2(x0 - 14.0, ry, (x1 - x0) + 28.0, 1.0),
			_dim(Color(1.0, 1.0, 1.0, 0.30), fade))

	for i in _lines.size():
		# 还没到这一行的时间就什么都不画：正文、点线、右侧结果是一起出现的，
		# 只让正文逐字打、结果却整列先摆在那儿，等于把答案提前漏了。
		if _t < line_time(i):
			break
		var y := head + float(i) * LOG_LINE_H
		if _band_at(y).is_empty():
			_draw_log_line(i, typing, Vector2(_shake.x, 0.0), x0, x1, status_w, y, font, fade)

	# 撕裂带：带里的行整块横向错位，带子的上下沿拉一条贯穿全屏的亮线——
	# 那是"扫描同步坏了"最省笔墨也最好认的画法。
	for b in _bands:
		var by := float(b[0])
		var bh := float(b[1])
		for i in _lines.size():
			if _t < line_time(i):
				break
			var y := head + float(i) * LOG_LINE_H
			if y >= by - LOG_LINE_H * 0.5 and y <= by + bh + LOG_LINE_H * 0.5:
				_draw_log_line(i, typing, Vector2(_shake.x + float(b[2]), 0.0),
					x0, x1, status_w, y, font, fade)
		var edge := _dim(Color(1.0, 1.0, 1.0, 0.22), fade)
		draw_rect(Rect2(0.0, by, w, 1.0), edge)
		draw_rect(Rect2(0.0, by + bh, w, 1.0), edge)


func _draw_log_line(i: int, typing: int, off: Vector2, x0: float, x1: float,
		status_w: float, y: float, font: Font, fade: float) -> void:
	var line: Dictionary = _lines[i]
	var kind := String(line["kind"])
	var shown := _typed_text(String(line["text"]), i)
	var col := Prts.TEXT_HI
	if kind == "alert":
		col = C_RED
	elif kind == "loud":
		col = Prts.WHITE
	col = _dim(col, fade)

	var px := x0 + off.x
	var py := y + off.y
	# 行首小方块：终端里"这一行是机器吐出来的"的记号
	draw_rect(Rect2(px - 12.0, py - 11.0, 5.0, 11.0), _dim(Prts.LINE_HI, fade))
	draw_string(font, Vector2(px, py), shown, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
		Prts.FS_SMALL, col)
	var tw := font.get_string_size(shown, HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_SMALL).x

	# 光标块：正在打的这一行后面是实的，全都打完以后变成闪的
	if i == typing or (i == _lines.size() - 1 and _t >= alert_time() and _blink_on()):
		draw_rect(Rect2(px + tw + 3.0, py - 11.0, 6.0, 11.0), _dim(Prts.WHITE, fade))

	var status := String(line["status"])
	if status.is_empty():
		return
	var sx := x1 - status_w
	_draw_dotted(px + tw + 14.0, sx - 12.0, py - 4.0, _dim(Prts.LINE_HI, fade))
	var scol := Prts.TEXT_HI
	if kind == "alert":
		scol = C_RED
	elif kind == "loud":
		scol = Prts.WHITE
	draw_string(font, Vector2(sx, py), status, HORIZONTAL_ALIGNMENT_RIGHT, status_w,
		Prts.FS_SMALL, _dim(scol, fade))


## 已经打出来的字。故障期间按比例换成符号：全换掉就成了另一行字，
## 保留空格和一部分原字，才看得出是"这行出问题了"而不是"换了一行"。
func _typed_text(text: String, i: int) -> String:
	var tt := _type_time(i)
	var p := 1.0 if tt <= 0.0 else clampf((_t - line_time(i)) / tt, 0.0, 1.0)
	var shown := text.substr(0, int(round(p * float(text.length()))))
	if not _glitch or shown.is_empty():
		return shown
	var out := ""
	for k in shown.length():
		var c := shown[k]
		if c == " " or _rng.randf() > 0.45:
			out += c
		else:
			out += SCRAMBLE[_rng.randi_range(0, SCRAMBLE.length() - 1)]
	return out


func _blink_on() -> bool:
	return fmod(_t, 0.5) < 0.30


# ---------------------------------------------------------------- 警示

## 框住红字那两行。角标从外面 24px 处"拍"到位，位置量化成 4px 一档——
## 机械动作就该是一格一格跳，滑动看着像淡入。
func _draw_alert(w: float, font: Font, fade: float) -> void:
	var p := clampf((_t - alert_time()) / 0.18, 0.0, 1.0)
	var off := roundf(24.0 * (1.0 - p) / 4.0) * 4.0
	var box := _alert_rect(w).grow(off)
	# 1px 暗红描边 + 粗红角标，和报错弹窗同一套框（那边是 PrtsFrame 的 border + bracket）
	draw_rect(box, _dim(C_RED_DIM, fade), false, 1.0)
	PrtsFrame.draw_brackets(self, box, 22.0, 3.0, _dim(C_RED, fade))
	# 署名放在框**下面**：框的上沿正好压着上一行日志，写在上边会和它叠在一起
	# （实测"阶段进度"那一行被盖掉一半）。框下是空的，放这儿谁也不碰。
	var ly := box.position.y + box.size.y + 16.0
	if _blink_on():
		draw_rect(Rect2(box.position.x, ly - 9.0, 6.0, 6.0), _dim(C_RED, fade))
	draw_string(font, Vector2(box.position.x + 14.0, ly), "PRTS ALERT",
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_SMALL, _dim(C_RED, fade))


func _alert_rect(w: float) -> Rect2:
	var x0 := w * LOG_X0
	var x1 := w * LOG_X1
	var y0 := _log_top() + float(_alert_index()) * LOG_LINE_H - 16.0
	var y1 := _log_top() + float(_lines.size()) * LOG_LINE_H + 8.0
	return Rect2(x0 - 22.0, y0, (x1 - x0) + 44.0, y1 - y0)


func _alert_wash() -> float:
	if _t < alert_time() or _t >= title_time():
		return 0.0
	var p := clampf((_t - alert_time()) / T_ALERT_HOLD, 0.0, 1.0)
	var v := 0.0
	for k in ALERT_FLASH:
		if p >= float(k[0]):
			v = float(k[1])
		else:
			break
	return v


# ---------------------------------------------------------------- 标题

func _draw_title(w: float, h: float, font: Font) -> void:
	var t := _t - title_time()
	var cx := w * 0.5
	var title := "能工智人 · 数据库"
	var tw := font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_HUGE).x
	var x := roundf(cx - tw * 0.5)

	var sub := "PRTS · SORTING SERVER SIMULATOR"
	var sub_font: Font = _sub_font if _sub_font != null else font
	var sw := sub_font.get_string_size(sub, HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_SMALL).x

	# 标题块整体在屏幕正中：先按内容定框、框心对齐中线，再往框里摆字。
	# （原来是先定标题基线、框跟着基线走，于是整个框偏在中线下面。）
	var bw := maxf(tw, sw) * 0.5 + 44.0
	var ty := roundf(h * 0.5 - TITLE_BOX_H * 0.5 + TITLE_BASELINE_IN)

	# 头 0.12 秒先落两遍错位的灰字（CRT 失同步的重影），再把白字压上去：
	# 0.06 秒一跳，两帧就收敛，像信号"对上"了。
	if t < 0.12:
		var g := 4.0 if t < 0.06 else 2.0
		draw_string(font, Vector2(x - g, ty), title, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
			Prts.FS_HUGE, Prts.LINE_HI)
		draw_string(font, Vector2(x + g, ty), title, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
			Prts.FS_HUGE, Prts.LINE_HI)
	draw_string(font, Vector2(x, ty), title, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
		Prts.FS_HUGE, Prts.WHITE)

	# 标题下一条从中心展开的白线
	var rp := clampf((t - 0.05) / 0.16, 0.0, 1.0)
	var half := tw * 0.5 * rp
	draw_rect(Rect2(cx - half, ty + 16.0, half * 2.0, 1.0), Prts.WHITE)

	if t >= 0.10:
		draw_string(sub_font, Vector2(roundf(cx - sw * 0.5), ty + 44.0), sub,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_SMALL, Prts.TEXT_HI)
	if t >= 0.18:
		# 居中要自己算左边界：draw_string 的 width 是从 pos.x 起算的，
		# 直接给 pos.x = 屏幕中线会变成"在右半边里居中"（小字因此偏右压住角标）。
		var note := "排序单元 SORT-01 · 权限已确认 · 开始监控"
		var nw := font.get_string_size(note, HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_SMALL).x
		draw_string(font, Vector2(roundf(cx - nw * 0.5), ty + 72.0), note,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_SMALL, Prts.DIM)

	# 角标从外面拍到位（和警示框同一套动作语言）。框的宽窄跟着内容走，
	# 不跟着屏幕走：内容 400px 却框出 1300px，看着像个空盒子。
	var bp := clampf((t - 0.02) / 0.20, 0.0, 1.0)
	var boff := roundf(26.0 * (1.0 - bp) / 6.0) * 6.0
	PrtsFrame.draw_brackets(self,
		Rect2(cx - bw, ty - TITLE_BASELINE_IN, bw * 2.0, TITLE_BOX_H).grow(boff),
		26.0, 4.0, Prts.WHITE)


# ---------------------------------------------------------------- 顶栏与角标

func _draw_chrome(w: float, h: float, font: Font) -> void:
	var p := clampf(_t / cut_time(), 0.0, 1.0)

	# 顶部进度条：2px，随自检推进从左往右填，每 10% 一格刻度
	draw_rect(Rect2(0.0, 0.0, w, 2.0), Prts.LINE)
	draw_rect(Rect2(0.0, 0.0, roundf(w * p), 2.0), Prts.WHITE)
	for i in range(1, 10):
		draw_rect(Rect2(roundf(w * 0.1 * float(i)), 2.0, 1.0, 4.0), Prts.LINE_HI)

	draw_string(font, Vector2(w - 220.0, 36.0), "自检 %d%%" % int(round(p * 100.0)),
		HORIZONTAL_ALIGNMENT_RIGHT, 200.0, Prts.FS_SMALL, Prts.DIM)
	draw_string(font, Vector2(24.0, h - 22.0), "UNIT SORT-01 · 冷启动",
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_SMALL, Prts.DIM)

	# 跳过提示 1 秒后才出现：一上来就写"按任意键跳过"显得急着让人走，
	# 而这段动画的全部意义就是让人先看它一眼。
	if _t >= 1.0 and not _finished and fmod(_t, 1.2) < 0.85:
		draw_string(font, Vector2(w - 244.0, h - 22.0), "按任意键跳过",
			HORIZONTAL_ALIGNMENT_RIGHT, 220.0, Prts.FS_SMALL, Prts.LINE_HI)


# ---------------------------------------------------------------- 收束

## 收束开头的白闪。硬切：全白 → 压到 0.25 → 归零。
func _flash() -> float:
	var t := _t - cut_time()
	if t < 0.0 or t >= CUT_FLASH + 0.04:
		return 0.0
	if t < CUT_FLASH:
		return 1.0
	return 0.25


## 纵向压缩比。曲线用 1-p²：起步慢、越塌越快，和显像管断电时一个样。
func _squash() -> float:
	var t := _t - cut_time() - CUT_FLASH
	if t <= 0.0:
		return 1.0
	var p := clampf(t / CUT_SQUASH, 0.0, 1.0)
	return maxf(SQUASH_MIN, 1.0 - p * p)

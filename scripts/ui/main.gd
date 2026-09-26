extends Control
## 主场景：组装界面、驱动运行状态机、校验资源、结算电费与阶段进度。
##
## 运行模型：VM 每次只跑一小批指令，"CPU 速度"就是每秒给多少预算。
## 这个循环是整个游戏的节拍器。

signal run_state_changed(state: int)
signal run_tick(info: Dictionary)
signal console_line(text: String, kind: String)

enum { ST_IDLE, ST_RUNNING, ST_PAUSED, ST_DONE, ST_ERROR }

const MAX_CONSOLE := 300
## 内存预检给变量留的余量（按变量个数算，最终会乘 8 字节）
const RAM_HEADROOM_VARS := 8
## 单帧最多按多少秒折算指令预算。
##
## 步数预算 = CPU速度 × delta。如果某一帧异常长（拖窗口、系统卡顿、
## 外部阻塞），下一帧会一次性放出几万条指令，可视化瞬间涌入海量事件，
## 表现出来就是"突然卡一下"。把 delta 截断，宁可少跑一点，也不要暴冲。
const MAX_STEP_DELTA := 0.05
## 单帧指令数硬上限（按 MAX_STEP_DELTA 和最高 CPU 档算，留一倍余量）
const MAX_STEPS_PER_FRAME := 13000
## 标签页：按住后移动超过这么多像素才算拖动，否则算点击。
## 单点一下也会走"按下"这条路，没有这个门槛就会看到卡片闪一下。
const TAB_DRAG_THRESHOLD := 6.0

const STATE_NAMES := {
	ST_IDLE: "待机", ST_RUNNING: "运行中", ST_PAUSED: "已暂停",
	ST_DONE: "已完成", ST_ERROR: "故障",
}

var _vm: PyVM = null
var _state := ST_IDLE
var _step_accum := 0.0
## 逐行档（滑条最左）的"下一行该在哪一秒走"的累计器
var _line_accum := 0.0
var _elapsed := 0.0
var _run_n := 0
var _run_stage := 0
var _run_id := 0
var _sorted_target: Array = []
var _console: Array = []
## 上一次真正执行到的行号。用来把 VM 偶尔报出的 0 挡掉（见 current_exec_line）
var _last_exec_line := 0
## 正在跑的这一次是从哪个文件编译出来的。按名字记：文件增删会让下标挪位，
## 名字是唯一的（Game._unique_name 保证）。切换编辑的文件不影响它。
var _run_file_name := ""

## 电费：本次任务累计产生多少、其中已从余额扣掉多少
var _bill_accrued := 0.0
var _bill_paid := 0.0
var _pay_accum := 0.0

# --- 界面引用
var _viz: VizView
var _viz_frame: PrtsFrame
var _coin_label: Label
var _chip := {}
var _btn_run: Button
var _btn_pause: Button
var _btn_step: Button
var _btn_stop: Button
var _step_pending := false
var _stat := {}
var _stage_title: Label
var _stage_detail: Label
var _stage_badge: Label
var _file_label: Label
var _btn_audio: Button
var _audio: SortAudio
## 主题颜色覆盖的缓存，避免每帧重复触发主题重解析
var _color_cache := {}
var _tabs: TabContainer
var _tab_files: TabFiles
var _tab_stages: TabStages
var _tab_status: TabStatus
var _tab_upgrade: TabUpgrade
var _tab_editor: TabEditor
var _error_popup: ErrorPopup
## 正在被拖动的标签页（null = 没在拖）。拖动期间只搬页面，松手才写盘。
var _tab_drag_child: Node = null
## 按下时记下的位置与标签下标，用来判断这一下到底是"点击"还是"拖动"
var _tab_press_pos := Vector2.ZERO
var _tab_press_index := -1
## 拖动时跟着光标走的那张小卡片（见 TabDragGhost）
var _tab_ghost: TabDragGhost


func _ready() -> void:
	theme = Prts.build_theme()

	_audio = SortAudio.new()
	_audio.name = "SortAudio"
	add_child(_audio)

	_build()

	Game.coins_changed.connect(_on_coins_changed)
	Game.tiers_changed.connect(_refresh_hardware)
	Game.speed_changed.connect(_refresh_hardware_chips_only)
	Game.stage_changed.connect(_on_stage_changed)
	_tabs.tab_changed.connect(_on_tab_changed)

	_refresh_hardware()
	_on_coins_changed(Game.coins)
	_refresh_stage()
	_update_file_label()

	log_line("虚拟服务器已就绪。", "sys")
	if Game.power_ok():
		log_line("供电正常：整机 %dW / 电源 %dW。运行期间按 %dW 实时计电费。"
			% [Game.total_draw(), Game.psu_watts(), Game.total_draw()], "sys")
	else:
		log_line("供电不足：整机需要 %dW，电源只有 %dW。请到「升级配置」处理。"
			% [Game.total_draw(), Game.psu_watts()], "error")
	log_line("服务器会调用 sort(a)，请让 a 变成升序。", "sys")
	log_line("按「运行」生成题目并开始。", "sys")

	# 开局不生成题目：数据只在点「运行」时才产生
	_clear_task()
	_emit_state()


# ================================================================ 界面搭建

func _build() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = Prts.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	root.add_child(_build_topbar())

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 0)
	root.add_child(body)

	var left := _build_left()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 1.34
	body.add_child(left)

	var div := ColorRect.new()
	div.color = Prts.LINE
	div.custom_minimum_size = Vector2(1, 0)
	body.add_child(div)

	var right := _build_right()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_stretch_ratio = 1.0
	body.add_child(right)

	# 报错弹窗放在最后一个：它就是"最上层"，压住补全框和所有标签页
	_error_popup = ErrorPopup.new()
	add_child(_error_popup)

	# 拖动标签页时跟手的小卡片。靠 z_index 压住补全框、但低于报错弹窗，所以加在弹窗之前。
	_tab_ghost = TabDragGhost.new()
	add_child(_tab_ghost)


func _build_topbar() -> Control:
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", Prts.flat(Prts.PANEL, Prts.LINE, 0))
	pc.custom_minimum_size = Vector2(0, 58)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 0)
	pc.add_child(row)

	# ---- 左上角：狗狗币
	var coin_box := VBoxContainer.new()
	coin_box.add_theme_constant_override("separation", 1)
	coin_box.add_child(Prts.dim_label("DOGECOIN"))
	var coin_line := HBoxContainer.new()
	coin_line.add_theme_constant_override("separation", 5)
	coin_line.add_child(Prts.label("Ð", Prts.FS_BIG, Prts.WHITE))
	_coin_label = Prts.label("0", Prts.FS_BIG, Prts.WHITE)
	coin_line.add_child(_coin_label)
	coin_box.add_child(coin_line)
	row.add_child(Prts.pad(coin_box, 16, 0))

	row.add_child(Prts.vline())

	# ---- 中部：状态指标
	var chips := HBoxContainer.new()
	chips.add_theme_constant_override("separation", 0)
	_chip["power"] = _make_chip("供电", "0W / 0W", 108)
	# 处理器单独一格：滑条可以在额定速度以下调速，不显示出来玩家不知道自己在跑多快
	_chip["cpu"] = _make_chip("处理器", "0 步 / 秒", 118)
	_chip["ram"] = _make_chip("内存", "0 / 0 B", 108)
	_chip["disk"] = _make_chip("硬盘", "0 / 0 B", 108)
	_chip["state"] = _make_chip("状态", "待机", 88)
	for k in ["power", "cpu", "ram", "disk", "state"]:
		chips.add_child(_chip[k]["root"])
	row.add_child(chips)

	row.add_child(Prts.spacer())

	# ---- 右侧：标题
	var title := VBoxContainer.new()
	title.add_theme_constant_override("separation", 1)
	var t1 := Prts.label("能工智人 · 数据库", Prts.FS_BODY, Prts.TEXT_HI)
	t1.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	title.add_child(t1)
	var sub := Prts.dim_label("SORTING SERVER SIMULATOR")
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	title.add_child(sub)
	row.add_child(Prts.pad(title, 16, 0))

	return pc


func _make_chip(caption: String, value: String, width := 112) -> Dictionary:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 1)
	box.custom_minimum_size = Vector2(width, 0)
	box.add_child(Prts.dim_label(caption))
	var v := Prts.label(value, Prts.FS_SMALL, Prts.TEXT_HI)
	box.add_child(v)
	var root := Prts.pad(box, 14, 0)
	return {"root": root, "value": v}


func _build_left() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)

	var viz_wrap := PanelContainer.new()
	viz_wrap.add_theme_stylebox_override("panel", Prts.flat(Prts.BG, Prts.LINE, 1))
	viz_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_viz = VizView.new()
	_viz.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_viz.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_viz.custom_minimum_size = Vector2(240, 220)
	viz_wrap.add_child(_viz)

	var frame := PrtsFrame.new()
	frame.bracket_len = 12
	frame.thickness = 2
	frame.bracket_color = Prts.FRAME_IDLE
	viz_wrap.add_child(frame)
	_viz_frame = frame

	box.add_child(viz_wrap)
	box.add_child(_build_controls())
	return box


func _build_controls() -> Control:
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", Prts.flat(Prts.PANEL, Prts.LINE, 0))

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)

	# ---- 当前阶段
	var stage_row := HBoxContainer.new()
	stage_row.add_theme_constant_override("separation", 10)
	_stage_title = Prts.label("阶段", Prts.FS_SMALL, Prts.WHITE)
	stage_row.add_child(_stage_title)
	_stage_detail = Prts.dim_label("", Prts.FS_TINY)
	_stage_detail.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	stage_row.add_child(_stage_detail)
	stage_row.add_child(Prts.spacer())
	_stage_badge = Prts.label("", Prts.FS_TINY, Prts.TEXT)
	stage_row.add_child(_stage_badge)
	col.add_child(stage_row)

	col.add_child(Prts.hline())

	# ---- 统计行
	var stats := HBoxContainer.new()
	stats.add_theme_constant_override("separation", 0)
	_stat["cmp"] = _make_chip("比较次数", "0", 96)
	_stat["ops"] = _make_chip("数组读写", "0", 96)
	_stat["steps"] = _make_chip("执行步数", "0", 96)
	_stat["time"] = _make_chip("已用时间", "0.0s", 96)
	_stat["bill"] = _make_chip("本次电费", "Ð0.0", 96)
	for k in ["cmp", "ops", "steps", "time", "bill"]:
		stats.add_child(_stat[k]["root"])
	col.add_child(stats)

	col.add_child(Prts.hline())

	# ---- 按钮行
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	_btn_run = Prts.button("> 运行", 96)
	_btn_run.pressed.connect(_on_run_pressed)
	row.add_child(_btn_run)

	_btn_pause = Prts.button("|| 暂停", 96)
	_btn_pause.pressed.connect(_on_pause_pressed)
	row.add_child(_btn_pause)

	_btn_step = Prts.button(">| 单步", 96)
	_btn_step.pressed.connect(_on_step_pressed)
	row.add_child(_btn_step)

	_btn_stop = Prts.button("X 停止", 96)
	_btn_stop.pressed.connect(_on_stop_pressed)
	row.add_child(_btn_stop)

	row.add_child(Prts.vline())

	# ---- 左下角：当前正在运行的算法文件
	# 注意别开 clip_text：那会把 Label 的最小宽度压成 0，HBox 就不给它空间了
	_file_label = Prts.label("", Prts.FS_SMALL, Prts.WHITE)
	_file_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_file_label.custom_minimum_size = Vector2(160, 0)
	row.add_child(_file_label)

	row.add_child(Prts.spacer())

	_btn_audio = Prts.button("音效：开", 92)
	_btn_audio.pressed.connect(_on_audio_toggled)
	row.add_child(_btn_audio)

	var hint := Prts.dim_label("电费按整机功率实时扣除")
	hint.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(hint)

	col.add_child(row)
	pc.add_child(Prts.pad(col, 10, 8))
	return pc


func _on_audio_toggled() -> void:
	if _audio == null:
		return
	_audio.set_enabled(not _audio.enabled)
	_btn_audio.text = "音效：开" if _audio.enabled else "音效：关"
	_btn_audio.add_theme_color_override("font_color",
		Prts.TEXT if _audio.enabled else Prts.DIM)
	log_line("音效已%s。" % ("开启" if _audio.enabled else "关闭"), "sys")


func _update_file_label() -> void:
	if _file_label == null:
		return
	if Game.files.is_empty():
		_file_label.text = "—"
		return
	# 跑起来以后以"正在跑的是谁"为准：这时候玩家可能已经翻去编辑别的文件了，
	# 标签再显示"当前算法"会让人以为运行也跟着换了。
	if run_active() and not _run_file_name.is_empty():
		_file_label.text = "运行中：%s" % _run_file_name
		Prts.set_color_cached(_file_label, "file", Prts.WHITE, _color_cache)
		return
	var i := clampi(Game.current_file, 0, Game.files.size() - 1)
	var f: Dictionary = Game.files[i]
	var unlocked := Game.is_unlocked(i)
	_file_label.text = "当前算法：%s%s" % [
		String(f["name"]), "" if unlocked else "（未解锁）"]
	Prts.set_color_cached(_file_label, "file",
		Prts.WHITE if unlocked else Prts.DIM, _color_cache)


func _build_right() -> Control:
	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.clip_tabs = false

	_tab_files = TabFiles.new()
	_tab_files.main = self
	_tab_files.name = "服务器文件"
	_tabs.add_child(_tab_files)

	_tab_stages = TabStages.new()
	_tab_stages.main = self
	_tab_stages.name = "算法阶段"
	_tabs.add_child(_tab_stages)

	_tab_status = TabStatus.new()
	_tab_status.main = self
	_tab_status.name = "运行状况"
	_tabs.add_child(_tab_status)

	_tab_upgrade = TabUpgrade.new()
	_tab_upgrade.main = self
	_tab_upgrade.name = "升级配置"
	_tabs.add_child(_tab_upgrade)

	_tab_editor = TabEditor.new()
	_tab_editor.main = self
	_tab_editor.name = "Python 编辑器"
	_tabs.add_child(_tab_editor)

	# 标签页可以拖着换位置（自己接鼠标，不用 TabBar 自带的 drag_to_rearrange，
	# 原因见 _on_tab_bar_input 的说明）
	_tabs.get_tab_bar().gui_input.connect(_on_tab_bar_input)
	_apply_tab_order(Game.tab_order)
	# 顺序表为空时 _apply_tab_order 会直接返回，提示得单独给一次
	_hint_tabs_draggable()

	return _tabs


# ---------------------------------------------------------------- 标签页顺序

## 拖动标签换位置。
##
## **不用** TabBar 自带的 `drag_to_rearrange`：它只动标签、不动页面，两边从此各说各话——
## 实测拖完是"标签写着 A、点开却是 B 的页面"；而 TabContainer 又只按**子节点**刷新标签，
## 所以想"照着标签顺序重排页面"会每帧自己转一圈（实测标题在五个页之间循环）。
##
## 自己接鼠标反而简单：按下只记下"可能被拖的是哪一页"，鼠标**真的移动了**才开始拖，
## 鼠标经过别的标签时就把**页面**搬过去，标签栏随后跟着子节点刷新——顺序只有一个来源，
## 永远对得上，也不需要逐帧核对。拖动过程中不写盘，松手才存。
##
## 为什么要等移动：单点一下也会走"按下"这条路。要是按下就抬起卡片，点一下标签
## 就会看到卡片闪一下、还白写一次盘——点击和拖动必须分开。
func _on_tab_bar_input(event: InputEvent) -> void:
	var bar := _tabs.get_tab_bar()
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_tab_press_pos = mb.position
			_tab_press_index = bar.get_tab_idx_at_point(mb.position)
			_tab_drag_child = null
		else:
			if _tab_drag_child != null:
				_tab_drag_child = null
				if _tab_ghost != null:
					_tab_ghost.drop()
				Game.tab_order = _tab_child_order()
				Game.save_game()
			_tab_press_index = -1
		return

	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		# 松手之后照样会收到移动事件，只认"按住不放"的那些
		if _tab_press_index < 0 or not (mm.button_mask & MOUSE_BUTTON_MASK_LEFT):
			return
		var at := _tab_event_global(bar, mm.position)
		if _tab_drag_child == null:
			# 还在地板里：这点抖动算点击，不算拖动
			if mm.position.distance_to(_tab_press_pos) < TAB_DRAG_THRESHOLD:
				return
			_tab_drag_child = _tabs.get_child(clampi(_tab_press_index, 0,
				_tabs.get_child_count() - 1))
			if _tab_drag_child != null and _tab_ghost != null:
				_tab_ghost.pick_up(bar.get_tab_title(_tab_press_index),
					bar.get_tab_rect(_tab_press_index).size, at)
			return     # 起步这一帧只把卡片抬起来，先不急着换位
		if _tab_ghost != null:
			_tab_ghost.follow(at)
		var to := bar.get_tab_idx_at_point(mm.position)
		if to >= 0 and to != _tab_drag_child.get_index():
			_move_tab_page(_tab_drag_child, to)


## gui_input 给的是控件局部坐标，转成全局的好让浮层定位
func _tab_event_global(bar: TabBar, local: Vector2) -> Vector2:
	return bar.get_global_rect().position + local


## 把某一页搬到指定位置。正在看的那一页跟着走，不会被搬走。
func _move_tab_page(child: Node, to: int) -> void:
	var keep := _tabs.get_child(clampi(_tabs.current_tab, 0, _tabs.get_child_count() - 1))
	_tabs.move_child(child, clampi(to, 0, _tabs.get_child_count() - 1))
	if keep != null:
		_tabs.current_tab = keep.get_index()


## 页面顺序（页名）。页面是唯一的顺序来源，标签栏只是它的投影。
func _tab_child_order() -> Array:
	var out: Array = []
	for c in _tabs.get_children():
		out.append(String(c.name))
	return out


## 按名字把页面重排成给定顺序。认不出的名字跳过，没提到的页一律留在最后——
## 老存档、以后增删标签页都靠这个兜底，不会因为顺序表过时就漏掉某一页。
func _apply_tab_order(order: Array) -> void:
	if _tabs == null or order.is_empty():
		return
	var by_name := {}
	for c in _tabs.get_children():
		by_name[String(c.name)] = c
	var placed := {}
	var i := 0
	for n in order:
		var key := String(n)
		if by_name.has(key) and not placed.has(key):
			placed[key] = true
			_tabs.move_child(by_name[key], i)
			i += 1
	for c in _tabs.get_children():
		var key := String(c.name)
		if not placed.has(key):
			placed[key] = true
			_tabs.move_child(c, i)
			i += 1
	_hint_tabs_draggable()


## 标签栏没有别的视觉线索，只能靠悬停提示告诉玩家"这里能拖"
func _hint_tabs_draggable() -> void:
	var bar := _tabs.get_tab_bar()
	for i in bar.tab_count:
		bar.set_tab_tooltip(i, "拖动可以调整标签页顺序")


# ================================================================ 对外接口

func current_code() -> String:
	if _tab_editor != null:
		return _tab_editor.get_code()
	return Game.current_code()


func log_line(text: String, kind := "sys") -> void:
	_console.append({"text": text, "kind": kind})
	if _console.size() > MAX_CONSOLE:
		_console.pop_front()
	console_line.emit(text, kind)
	# 报错除了进控制台，还要在屏幕正中弹一次——控制台在"运行状况"页里，
	# 玩家很可能正在看别的地方，光写日志等于没提示。
	if kind == "error":
		_popup_error(text)


## 把一条错误拆成标题 + 正文。
##
## 控制台里的错误文案是这几种形状："运行故障 · 第 5 行：…"、"语法错误 → 第 2 行 …"、
## "无法开机：整机需要 80W…"。取第一个分隔符前的一小段当标题，剩下的当正文；
## 没有分隔符（或前缀过长）就整句当正文，标题给个通用的。
## 这样不用在几十个报错点上都加标题参数，也不会漏掉将来新增的报错。
static func error_title_and_body(text: String) -> Array:
	for sep in [" · ", " → ", "："]:
		var i := text.find(sep)
		if i > 0 and i <= 12:
			return [text.substr(0, i), text.substr(i + sep.length())]
	return ["错误", text]


func _popup_error(text: String) -> void:
	if _error_popup == null:
		return
	var parts := error_title_and_body(text)
	_error_popup.show_error(String(parts[0]), String(parts[1]))


## 报错弹窗当前是否开着（测试与外部查询用）。
func error_popup() -> ErrorPopup:
	return _error_popup


func get_console() -> Array:
	return _console


func get_state() -> int:
	return _state


func state_name() -> String:
	return String(STATE_NAMES.get(_state, "?"))


## 当前正在执行的源码行（1 起），用来在编辑器里框出运行位置。0 = 没有可框的行。
##
## 只回答"该框哪一行"，不管怎么画：运行/暂停时跟着 VM 的取指位置走，
## 出错时停在出错那一行（比停在崩溃前的最后一条指令更有用），
## 跑完或待机就没有可框的行了。
##
## 编辑器上显示的文件不是正在跑的那个时返回 0：VM 的行号属于它当初编译的那份代码，
## 套到另一个文件上只会框错行。
##
## 注意 VM 的取指位置**会短暂地报 0**：刚进入一个函数时新栈帧的 pc 还是 0
## （引导代码那几条指令的行号也是 0）。这种 0 不当成"没得框"，而是保持上一行——
## 否则每进一次函数白框就消失再出现，滑不动、还闪。
func current_exec_line() -> int:
	if _vm == null or _run_file_name.is_empty():
		return 0
	match _state:
		ST_RUNNING, ST_PAUSED:
			if not is_running_file_current():
				return 0
			var line := _vm.current_line()
			if line > 0:
				_last_exec_line = line
			return _last_exec_line
		ST_ERROR:
			return int(_vm.error["line"])
	return 0


## 有没有正在跑的这一次（运行中或已暂停）。暂停也算：那一局还活着。
func run_active() -> bool:
	return _state == ST_RUNNING or _state == ST_PAUSED


## 正在运行的文件名。空字符串表示当前没有运行。
func running_file_name() -> String:
	return _run_file_name


## 编辑器上显示的是不是正在运行的那个文件。行号只有对得上文件才有意义。
func is_running_file_current() -> bool:
	return not _run_file_name.is_empty() and current_file_name() == _run_file_name


func current_file_name() -> String:
	if Game.files.is_empty():
		return ""
	var i := clampi(Game.current_file, 0, Game.files.size() - 1)
	return String((Game.files[i] as Dictionary)["name"])


## 正在运行的文件在列表里的下标。文件被删掉或改名就找不到，返回 -1。
func running_file_index() -> int:
	if _run_file_name.is_empty():
		return -1
	for i in Game.files.size():
		if String(Game.files[i]["name"]) == _run_file_name:
			return i
	return -1


func get_vm() -> PyVM:
	return _vm


func get_bill() -> Dictionary:
	return {"accrued": _bill_accrued, "paid": _bill_paid}


func get_run_info() -> Dictionary:
	var info := {
		"n": _run_n, "run_id": _run_id, "elapsed": _elapsed, "stage": _run_stage,
		"steps": 0, "comparisons": 0, "reads": 0, "writes": 0,
		"ops": 0, "ram": 0, "status": state_name(),
		"bill": _bill_accrued, "bill_paid": _bill_paid,
		"budget": Game.stage_ops_budget(),
	}
	if _vm != null:
		info["steps"] = _vm.steps
		info["comparisons"] = _vm.comparisons
		info["reads"] = _vm.reads
		info["writes"] = _vm.writes
		info["ops"] = _vm.reads + _vm.writes
		info["ram"] = _vm.ram_usage()
	return info


func reload_editor() -> void:
	if _tab_editor != null:
		_tab_editor.load_from_game()
	_update_file_label()


## 切换算法文件。
##
## 运行途中切换**不打断**正在跑的那一次：跑的是当初编译好的那份代码、属于那个文件，
## 切过去只是换个文件编辑/查看。题目、可视化、计时、电费都保持原样——
## 否则玩家一翻别的文件，正在看的这一局就没了。
## 正在运行的文件在文件列表里带一个转圈的小方框（见 RunSpinner）。
##
## force：新建/复制文件时必须传 true。那两个动作在 Game 里已经把 current_file
## 指到新文件了，这里再比一次 index == current_file 就会提前返回，编辑器于是
## 还停在上一个文件的代码上——玩家一敲键盘就把旧代码写进了新文件。
func switch_file(index: int, force := false) -> void:
	if index < 0 or index >= Game.files.size():
		return
	if index == Game.current_file and not force:
		_update_file_label()
		return
	if not Game.is_unlocked(index):
		log_line("%s 还没解锁，先去「服务器文件」里解锁。"
			% String((Game.files[index] as Dictionary)["name"]), "warn")
		return

	var name := String((Game.files[index] as Dictionary)["name"])
	Game.current_file = index
	reload_editor()
	_update_file_label()
	# 文件页的选中行跟着走（用户从列表点进来时本来就对，这里是给
	# 新建/复制/解锁这些"从别处切过来"的路径兜底）
	if _tab_files != null:
		_tab_files.refresh()
	Game.save_game()

	if run_active():
		log_line("已切换到 %s。正在运行的仍是 %s，不受影响；再点「运行」才会换算法。"
			% [name, _run_file_name], "sys")


## 打断当前这一局，不结算、不留成绩。用于"编辑器换到别的文件后又点了运行/单步"——
## 那是玩家明确要换算法跑，不是想接着看旧的。
func interrupt_run(reason: String) -> void:
	if not run_active() and _vm == null:
		return
	var was := _run_file_name
	if _vm != null:
		_vm.status = "halted"
		_vm.halted_reason = reason
	_clear_task()
	_state = ST_IDLE
	_emit_state()
	if not was.is_empty():
		log_line("已打断 %s 的运行：%s。" % [was, reason], "warn")


func _on_tab_changed(idx: int) -> void:
	var c := _tabs.get_child(idx)
	if c != null and c.has_method("refresh"):
		c.call("refresh")


## 跳到某一页。按**节点身份**找下标，绝不写死序号——
## 标签页可以拖动排序，写死的下标在玩家挪过页序之后就会指到别的页面上
## （双击算法文件跳编辑器就踩过这个坑：原来写的是 current_tab = 4）。
func show_tab(page: Node) -> void:
	if page == null or _tabs == null:
		return
	var i := page.get_index()
	if i >= 0 and i < _tabs.get_tab_count():
		_tabs.current_tab = i


## 换一个阶段来挑战。只能选已经通过的阶段（或当前进度那一关）。
##
## 和切换算法文件同理：阶段换了，旧题目就作废，必须把当前这次跑停掉，
## 否则可视化上跑的还是上一个阶段的数据规模。
func select_stage(index: int) -> void:
	if not Game.can_select_stage(index):
		log_line("阶段 %02d 还没解锁，先把当前这关过了。" % (index + 1), "warn")
		return
	if index == Game.stage_index():
		return

	if _vm != null and (_state == ST_RUNNING or _state == ST_PAUSED):
		_vm.status = "halted"
		_vm.halted_reason = "切换阶段"
		log_line("已结束当前运行，换阶段。", "sys")

	Game.select_stage(index)
	# 换了阶段，旧题目作废。新题目等玩家点「运行」时再生成。
	_clear_task()
	_state = ST_IDLE
	_emit_state()
	_refresh_stage()

	var s := Game.stage_info()
	if Game.is_replay():
		log_line("已回到阶段 %02d「%s」重刷：%d 个元素，效率预算 %d。收益照给，进度不动。"
			% [index + 1, String(s.get("algo", "")), int(s.get("n", 0)),
				int(s.get("ops", 0))], "sys")
	else:
		log_line("已回到当前进度：阶段 %02d「%s」· %d 个元素 · 效率预算 %d。"
			% [index + 1, String(s.get("algo", "")), int(s.get("n", 0)),
				int(s.get("ops", 0))], "sys")


# ================================================================ 运行控制

func _on_run_pressed() -> void:
	# 编辑器换到别的文件以后再点「运行」，意思是"跑这个新算法"：
	# 先把旧的那一局打断（不结算），再从新文件重新开局。
	if run_active() and not is_running_file_current():
		interrupt_run("换用 %s" % current_file_name())
	match _state:
		ST_RUNNING:
			return
		ST_PAUSED:
			_state = ST_RUNNING
			_emit_state()
		_:
			if _prepare_run():
				_state = ST_RUNNING
				_step_accum = 0.0
				_emit_state()


func _on_pause_pressed() -> void:
	if _state == ST_RUNNING:
		_state = ST_PAUSED
		_emit_state()


func _on_stop_pressed() -> void:
	if _vm == null:
		return
	if _state == ST_RUNNING or _state == ST_PAUSED:
		log_line("已手动停止本次运行。", "warn")
	_clear_task()
	_state = ST_IDLE
	_emit_state()


## 单步：没有题目（或上一局已结束）就先生成一局并停住，之后每次只推进一条指令。
## 和「运行」同一条规矩：编辑器换到别的文件时，单步也从新文件重新开局。
func _on_step_pressed() -> void:
	if run_active() and not is_running_file_current():
		interrupt_run("换用 %s" % current_file_name())
	if _vm == null or _state == ST_DONE or _state == ST_ERROR:
		if not _prepare_run():
			return
		_state = ST_PAUSED
		_emit_state()
		return
	_step_pending = true
	if _state == ST_RUNNING:
		_state = ST_PAUSED
	_emit_state()


func _on_stage_changed(_index: int) -> void:
	_refresh_stage()
	# 刻意不清题目：阶段推进是"通关"的结果，玩家需要看到刚才那一局的成绩。
	# 新阶段的题目等下次点「运行」时再生成。


## 清掉当前题目。
##
## 数据只在点「运行」时才生成：这样"开始一局"是一个明确的动作，
## 也避免了改代码、换算法、换阶段时后台悄悄生成一堆没人看的排列。
func _clear_task() -> void:
	_vm = null
	_step_pending = false
	_run_n = 0
	_bill_accrued = 0.0
	_bill_paid = 0.0
	_pay_accum = 0.0
	_elapsed = 0.0
	_step_accum = 0.0
	_line_accum = 0.0
	_last_exec_line = 0
	_run_file_name = ""
	if _viz != null:
		_viz.clear()
	_update_stat_labels(get_run_info())
	_refresh_hardware_chips_only()
	_update_file_label()


## 装配一次运行。任何一项资源不满足都在这里拦下来，并给出可执行的建议。
func _prepare_run() -> bool:
	var code := current_code()
	if code.strip_edges().is_empty():
		log_line("代码是空的。先写一个 sort 函数。", "error")
		return false

	# 1) 供电
	if not Game.power_ok():
		log_line("无法开机：整机需要 %dW，电源只有 %dW。请升级电源，或降回低功耗部件。"
			% [Game.total_draw(), Game.psu_watts()], "error")
		return false

	# 2) 硬盘
	var bytes := code.to_utf8_buffer().size()
	if bytes > Game.disk_bytes():
		log_line("硬盘空间不足：源码 %d 字节，本机只有 %d 字节。请精简代码或升级硬盘。"
			% [bytes, Game.disk_bytes()], "error")
		return false

	# 3) 语法与编译
	var parser := PyParser.new()
	var parsed := parser.parse(code)
	if not parsed["ok"]:
		log_line("语法错误 → " + _fmt_errors(parsed["errors"]), "error")
		_state = ST_ERROR
		_emit_state()
		return false

	var compiler := PyCompiler.new()
	var compiled := compiler.compile(parsed["ast"])
	if not compiled["ok"]:
		log_line("编译错误 → " + _fmt_errors(compiled["errors"]), "error")
		_state = ST_ERROR
		_emit_state()
		return false

	var fns: Dictionary = compiled["functions"]
	var entry := "sort"
	if not fns.has(entry):
		if fns.size() == 1:
			entry = String(fns.keys()[0])
			log_line("没有找到 sort 函数，改用唯一的函数 %s()。" % entry, "warn")
		else:
			log_line("没有找到 sort 函数。服务器会调用 sort(a)，请定义 def sort(a):", "error")
			_state = ST_ERROR
			_emit_state()
			return false

	# 4) 内存。数据规模由阶段决定，装不下就只能去升内存。
	_run_stage = Game.stage_index()
	_run_n = Game.stage_n()
	var need := ServerSpec.ram_need_bytes(_run_n, RAM_HEADROOM_VARS)
	if need > Game.ram_bytes():
		log_line("内存不足：%d 个元素至少需要 %d 字节，本机只有 %d 字节。请升级内存。"
			% [_run_n, need, Game.ram_bytes()], "error")
		return false

	# 5) 生成任务数据。刻意用"有重复值的随机数"而不是 1..n 的排列，
	#    否则 for i in range(n): a[i] = i + 1 就能骗过判题。
	_run_id += 1
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%d-%d-%d-%d" % [_run_id, _run_stage, _run_n, Time.get_ticks_usec()])
	var vals: Array = []
	var hi := maxi(20, _run_n)
	for _i in _run_n:
		vals.append(rng.randi_range(1, hi))
	_sorted_target = vals.duplicate()
	_sorted_target.sort()

	var arr := PyObjects.PyList.new(vals)
	_vm = PyVM.new()
	_vm.setup(compiled, arr, entry, Game.ram_bytes(), 100000 + _run_n * _run_n * 200)
	_vm.start()
	# 这一次运行属于此刻编辑器里的文件；之后随便切文件都不会影响它
	_run_file_name = current_file_name()
	_last_exec_line = 0

	_viz.set_array(arr.items, _sorted_target)
	_viz.set_caption("阶段 %02d · 任务 #%d" % [_run_stage + 1, _run_id])
	_elapsed = 0.0
	_step_accum = 0.0
	_bill_accrued = 0.0
	_bill_paid = 0.0
	_pay_accum = 0.0

	log_line("任务 #%d 已装载（%s）：阶段 %02d「%s」· %d 个元素 · 效率预算 %d 次数组读写 · CPU %d 步/秒。"
		% [_run_id, _run_file_name, _run_stage + 1,
			String(Game.stage_info().get("algo", "")),
			_run_n, Game.stage_ops_budget(), Game.cpu_speed()], "sys")

	_refresh_hardware_chips_only()
	_update_stat_labels(get_run_info())
	_update_file_label()
	_refresh_stage()
	return true


static func _fmt_errors(errors: Array) -> String:
	var parts := PackedStringArray()
	for e in errors:
		parts.append("第 %d 行 %s" % [e["line"], e["msg"]])
	return "；".join(parts)


func _emit_state() -> void:
	_refresh_buttons()
	run_state_changed.emit(_state)
	if _chip.has("state"):
		var l: Label = _chip["state"]["value"]
		l.text = state_name()
		var sc := Prts.WHITE if _state == ST_RUNNING else (
			Prts.TEXT_HI if _state != ST_ERROR else Prts.TEXT)
		Prts.set_color_cached(l, "state", sc, _color_cache)
	# 运行指示框：可视化区和编辑器区的角标同步点亮
	var running := _state == ST_RUNNING
	if _viz_frame != null:
		_viz_frame.bracket_color = Prts.WHITE if running else Prts.FRAME_IDLE
		_viz_frame.queue_redraw()
	if _tab_editor != null:
		_tab_editor.set_running(running)
	# 「当前算法 / 运行中」两种标签跟着状态切换
	_update_file_label()


func _refresh_buttons() -> void:
	if _btn_run == null:
		return
	_btn_run.disabled = _state == ST_RUNNING
	_btn_pause.disabled = _state != ST_RUNNING
	_btn_step.disabled = _state == ST_RUNNING
	_btn_stop.disabled = _vm == null or (_state != ST_RUNNING and _state != ST_PAUSED)


# ================================================================ 主循环

func _process(delta: float) -> void:
	if _vm == null:
		return

	# 单步：无论当前什么状态都只推进一条指令
	if _step_pending:
		_step_pending = false
		_vm.run_batch(1)
		_consume_events()
		if _vm.status != "running":
			_finish_run()
		else:
			_emit_tick()
		return

	if _state != ST_RUNNING:
		return

	# 截断异常长帧，避免指令暴冲（见 MAX_STEP_DELTA 的说明）
	var dt := minf(delta, MAX_STEP_DELTA)

	_elapsed += dt
	_accrue_power_bill(dt)

	var still_running := true
	if Game.is_frame_step():
		# 逐行档：1 行/秒。每过一秒把"当前这一行"推进完，指示框一行一行地走，
		# 肉眼跟得上。纯按指令走（1 步/秒）一行要好几秒才换；一帧一行又太快、
		# 指示框像在乱窜——一秒一行才是"看得最清楚"的那一档。
		_step_accum = 0.0
		_line_accum += dt
		var guard := 0
		while _line_accum >= 1.0 and guard < 8:
			_line_accum -= 1.0
			var ln := _vm.current_line()
			var g2 := 0
			while _vm.current_line() == ln and g2 < 128:
				_vm.run_batch(1)
				g2 += 1
			guard += 1
		still_running = _vm.status == "running"
	else:
		_step_accum += float(Game.cpu_speed()) * dt
		var budget := int(_step_accum)
		if budget <= 0:
			_emit_tick()
			return
		# 再兜一层：单帧指令数硬上限
		if budget > MAX_STEPS_PER_FRAME:
			budget = MAX_STEPS_PER_FRAME
			_step_accum = 0.0
		else:
			_step_accum -= float(budget)
		still_running = _vm.run_batch(budget)

	_consume_events()
	if still_running:
		_emit_tick()
	else:
		_finish_run()


## 电费按整机功率实时扣。扣到 0 为止——刻意不做成"余额不足就禁止运行"，
## 那会让玩家在 0 币时彻底卡死。所以电费只会吃掉盈余，不会挡路。
func _accrue_power_bill(delta: float) -> void:
	var cost := float(Game.total_draw()) * delta * ServerSpec.POWER_RATE
	if cost <= 0.0:
		return
	_bill_accrued += cost
	_pay_accum += cost
	if _pay_accum >= 1.0:
		var whole := int(_pay_accum)
		_pay_accum -= float(whole)
		_bill_paid += float(Game.pay_power(whole))


func _consume_events() -> void:
	var ev := _vm.drain_events()
	if ev.is_empty():
		return
	for e in ev:
		match String(e.get("t", "")):
			"print":
				log_line(String(e["text"]), "out")
			"read":
				# 音效跟着"当前选中的元素"走：值越大音越高
				_audio.play_value(int(e["v"]), _viz.max_value())
	_viz.apply_events(ev)


func _emit_tick() -> void:
	var info := get_run_info()
	run_tick.emit(info)
	_update_stat_labels(info)


func _update_stat_labels(info: Dictionary) -> void:
	if _stat.is_empty():
		return
	(_stat["cmp"]["value"] as Label).text = Prts.comma(int(info["comparisons"]))
	(_stat["ops"]["value"] as Label).text = Prts.comma(int(info["ops"]))
	(_stat["steps"]["value"] as Label).text = Prts.comma(int(info["steps"]))
	(_stat["time"]["value"] as Label).text = "%.1fs" % float(info["elapsed"])
	(_stat["bill"]["value"] as Label).text = "Ð%.1f" % float(info["bill"])
	_update_stage_badge(int(info["ops"]))


func _finish_run() -> void:
	var info := get_run_info()
	_update_stat_labels(info)
	Game.stats["runs"] = int(Game.stats["runs"]) + 1

	if _vm.status == "error":
		_state = ST_ERROR
		Game.stats["failed"] = int(Game.stats["failed"]) + 1
		log_line("运行故障 · 第 %d 行：%s" % [_vm.error["line"], _vm.error["msg"]], "error")
	elif _vm.status == "done":
		_resolve_success()
	else:
		_state = ST_IDLE
		log_line("运行中止：%s" % _vm.halted_reason, "warn")

	Game.save_game()
	_emit_state()
	_emit_tick()
	if _tab_status != null:
		_tab_status.refresh()
	if _tab_stages != null:
		_tab_stages.refresh()


func _resolve_success() -> void:
	var arr: Array = _vm.target.items
	if not _is_sorted(arr):
		_state = ST_ERROR
		Game.stats["failed"] = int(Game.stats["failed"]) + 1
		log_line("运行结束了，但数组并没有排好序 —— 检查一下算法逻辑。", "error")
		return

	var ops := _vm.reads + _vm.writes
	var budget := Game.stage_ops_budget()
	var passed := ops <= budget
	var base := ServerSpec.reward(_run_n, ops)
	var bonus := 0
	if passed:
		bonus = int(round(float(base) * (ServerSpec.BONUS_MULTIPLIER - 1.0)))

	Game.grant(base + bonus)
	Game.stats["completed"] = int(Game.stats["completed"]) + 1
	# 成绩记在**正在运行的那个文件**名下，不是现在编辑器里显示的那个——
	# 玩家完全可以在跑的时候翻去改别的算法。
	Game.record_result(running_file_index(), _run_n, ops, base + bonus)
	Game.record_stage(_run_stage, ops, _run_n)
	_state = ST_DONE

	log_line("排序完成 · %s · %d 个元素 / %d 步 / %d 次比较 / %d 次数组读写 → 奖励 Ð%s"
		% [_run_file_name, _run_n, _vm.steps, _vm.comparisons, ops, Prts.comma(base)], "ok")
	log_line("本次电费 Ð%.1f（整机 %dW × %.1f 秒）。" % [_bill_accrued, Game.total_draw(), _elapsed], "sys")

	if not passed:
		log_line("效率未达标：用了 %d 次数组读写，预算是 %d。优化算法才能解锁下一阶段。"
			% [ops, budget], "warn")
		return

	if bonus > 0:
		log_line("效率达标，额外奖励 Ð%s。" % Prts.comma(bonus), "ok")

	var was_stage := _run_stage
	# 先记下这是不是重刷：clear_stage 推进进度后会把选择复位，"是不是重刷"就看不出来了
	var was_replay := was_stage < Game.frontier_index()
	if Game.clear_stage(was_stage):
		var nxt := Game.stage_info()
		log_line("阶段 %02d 通过 —— 解锁阶段 %02d「%s」· %d 个元素 · 效率预算 %d。"
			% [was_stage + 1, Game.stage_index() + 1, String(nxt.get("algo", "")),
				int(nxt.get("n", 0)), int(nxt.get("ops", 0))], "ok")
	elif was_replay:
		log_line("阶段 %02d 重刷达标：成绩已记录，进度停在阶段 %02d。"
			% [was_stage + 1, Game.frontier_index() + 1], "sys")
	elif Game.is_final_stage():
		log_line("已经是最后一个阶段，可以反复挑战刷收益。", "sys")


static func _is_sorted(a: Array) -> bool:
	for i in range(1, a.size()):
		if int(a[i - 1]) > int(a[i]):
			return false
	return true


# ================================================================ 顶栏与阶段

func _on_coins_changed(coins: int) -> void:
	if _coin_label != null:
		# 带一位小数，和「本次电费 Ð0.0」保持同一种货币读数形状。
		# 注意 coins 是整数，所以小数位恒为 .0——它在这里是排版，不是精度。
		_coin_label.text = Prts.comma1(float(coins))


func _refresh_stage() -> void:
	if _stage_title == null:
		return
	var s := Game.stage_info()
	var replay := Game.is_replay()
	_stage_title.text = "%s · %s%s" % [
		String(s.get("name", "")), String(s.get("algo", "")),
		"（重刷）" if replay else ""]
	Prts.set_color_cached(_stage_title, "stage_title",
		Prts.TEXT_HI if replay else Prts.WHITE, _color_cache)
	_stage_detail.text = "%d 个元素　·　效率预算 %d 次数组读写　·　已通过 %d / %d 关" % [
		int(s.get("n", 0)), int(s.get("ops", 0)), Game.cleared, ServerSpec.stage_count()]
	_update_stage_badge(-1)


func _update_stage_badge(ops: int) -> void:
	if _stage_badge == null:
		return
	var budget := Game.stage_ops_budget()
	var state := ""
	var text := ""
	var color := Prts.DIM
	if ops < 0:
		state = "idle"
		text = "预算 %d" % budget
	elif ops <= budget:
		state = "pass"
		text = "已达标 %d / %d" % [ops, budget]
		color = Prts.WHITE
	else:
		state = "over"
		text = "超出预算 %d / %d" % [ops, budget]
		color = Prts.TEXT

	# 文字每帧都在变，但颜色只在"待机/达标/超预算"切换时才需要改。
	if _stage_badge.text != text:
		_stage_badge.text = text
	Prts.set_color_cached(_stage_badge, "badge:" + state, color, _color_cache)


func _refresh_hardware() -> void:
	_refresh_hardware_chips_only()
	if _tab_status != null:
		_tab_status.refresh()
	if _tab_upgrade != null:
		_tab_upgrade.refresh()
	if _tab_editor != null:
		_tab_editor.refresh_meters()


## 只刷新顶栏指标。编辑器每次按键都会调它，所以绝不能回头去刷编辑器（会递归）。
func _refresh_hardware_chips_only() -> void:
	if _chip.is_empty():
		return
	var draw := Game.total_draw()
	var psu := Game.psu_watts()
	var pl: Label = _chip["power"]["value"]
	pl.text = "%dW / %dW" % [draw, psu]
	Prts.set_color_cached(pl, "power", Prts.TEXT_HI if draw <= psu else Prts.WHITE, _color_cache)

	var cl: Label = _chip["cpu"]["value"]
	var now := Game.cpu_speed()
	var rated := Game.cpu_rate()
	if Game.is_frame_step():
		# 逐行档：最低速度 = 1 行/秒
		cl.text = "1 行 / %s 步 / 秒" % Prts.comma(rated)
		Prts.set_color_cached(cl, "cpu", Prts.WHITE, _color_cache)
	elif now >= rated:
		cl.text = "%s 步 / 秒" % Prts.comma(now)
	else:
		# 调速后写成"当前 / 额定"，一眼看出是滑条压下来的还是硬件就这么多
		cl.text = "%s / %s 步 / 秒" % [Prts.comma(now), Prts.comma(rated)]
		Prts.set_color_cached(cl, "cpu", Prts.TEXT_HI if now >= rated else Prts.WHITE,
			_color_cache)

	var rl: Label = _chip["ram"]["value"]
	var used := 0
	if _vm != null:
		used = _vm.ram_usage()
	rl.text = "%d / %d B" % [used, Game.ram_bytes()]

	var dl: Label = _chip["disk"]["value"]
	var code := current_code()
	dl.text = "%d / %d B" % [code.to_utf8_buffer().size(), Game.disk_bytes()]

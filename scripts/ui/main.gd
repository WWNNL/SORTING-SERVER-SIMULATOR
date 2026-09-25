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

const STATE_NAMES := {
	ST_IDLE: "待机", ST_RUNNING: "运行中", ST_PAUSED: "已暂停",
	ST_DONE: "已完成", ST_ERROR: "故障",
}

var _vm: PyVM = null
var _state := ST_IDLE
var _step_accum := 0.0
var _elapsed := 0.0
var _run_n := 0
var _run_stage := 0
var _run_id := 0
var _sorted_target: Array = []
var _console: Array = []
## 上一次真正执行到的行号。用来把 VM 偶尔报出的 0 挡掉（见 current_exec_line）
var _last_exec_line := 0

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

	return _tabs


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
## 注意 VM 的取指位置**会短暂地报 0**：刚进入一个函数时新栈帧的 pc 还是 0
## （引导代码那几条指令的行号也是 0）。这种 0 不当成"没得框"，而是保持上一行——
## 否则每进一次函数白框就消失再出现，滑不动、还闪。
func current_exec_line() -> int:
	if _vm == null:
		return 0
	match _state:
		ST_RUNNING, ST_PAUSED:
			var line := _vm.current_line()
			if line > 0:
				_last_exec_line = line
			return _last_exec_line
		ST_ERROR:
			return int(_vm.error["line"])
	return 0


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
## 运行途中切换必须先把当前这次跑停掉，并重新生成排列——否则可视化上跑的还是
## 旧算法的数据，看起来就像"换了代码却没生效"。
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
	var was_active := _state == ST_RUNNING or _state == ST_PAUSED
	if _vm != null and was_active:
		_vm.status = "halted"
		_vm.halted_reason = "切换算法"
		log_line("已结束当前运行，换用 %s。" % name, "sys")

	Game.current_file = index
	reload_editor()

	# 换了算法，旧题目作废。新题目等玩家点「运行」时再生成。
	_clear_task()
	_state = ST_IDLE
	_emit_state()
	Game.save_game()


func _on_tab_changed(idx: int) -> void:
	var c := _tabs.get_child(idx)
	if c != null and c.has_method("refresh"):
		c.call("refresh")


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
func _on_step_pressed() -> void:
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
	_last_exec_line = 0
	if _viz != null:
		_viz.clear()
	_update_stat_labels(get_run_info())
	_refresh_hardware_chips_only()


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

	_viz.set_array(arr.items, _sorted_target)
	_viz.set_caption("阶段 %02d · 任务 #%d" % [_run_stage + 1, _run_id])
	_elapsed = 0.0
	_step_accum = 0.0
	_bill_accrued = 0.0
	_bill_paid = 0.0
	_pay_accum = 0.0

	log_line("任务 #%d 已装载：阶段 %02d「%s」· %d 个元素 · 效率预算 %d 次数组读写 · CPU %d 步/秒。"
		% [_run_id, _run_stage + 1, String(Game.stage_info().get("algo", "")),
			_run_n, Game.stage_ops_budget(), Game.cpu_speed()], "sys")

	_refresh_hardware_chips_only()
	_update_stat_labels(get_run_info())
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

	var still_running := _vm.run_batch(budget)
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
	Game.record_result(Game.current_file, _run_n, ops, base + bonus)
	Game.record_stage(_run_stage, ops, _run_n)
	_state = ST_DONE

	log_line("排序完成 · %d 个元素 / %d 步 / %d 次比较 / %d 次数组读写 → 奖励 Ð%s"
		% [_run_n, _vm.steps, _vm.comparisons, ops, Prts.comma(base)], "ok")
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
	if now >= rated:
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

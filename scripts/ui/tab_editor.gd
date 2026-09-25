class_name TabEditor
extends VBoxContainer
## Python 编辑器：写算法的地方。
##
## 每次按键都会跑一遍词法+语法+编译，把错误立刻显示在底部——
## 这样玩家在按"运行"之前就知道代码有没有问题，不用反复试错。

var main: Control

var _edit: PyCodeEdit
var _status: Label
var _byte_text: Label
var _byte_bar: ProgressBar
var _caret_text: Label
var _loading := false
var _flash_left := 0.0
var _highlighter: PyHighlighter
var _frame: PrtsFrame
var _run_line: RunLineFrame
var _completion: CompletionPopup
var _candidates: Array = []
## 刚确认过一个候选，接下来这次 text_changed 不要再自动弹框
var _suppress_completion := false


func _ready() -> void:
	add_theme_constant_override("separation", 0)
	# 补全框挂在 Main 上，靠 z_index 压在所有面板之上
	_completion = CompletionPopup.new()
	main.add_child(_completion)
	_build()
	# 运行位置的更新跟着运行节拍走：运行中每帧一次，状态切换时补一次
	main.run_tick.connect(_on_run_tick)
	main.run_state_changed.connect(func(_s): _sync_run_line())
	load_from_game()


func _build() -> void:
	# ---- 工具条
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", Prts.flat(Prts.PANEL, Prts.LINE, 0))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var b_run := Prts.button("> 运行")
	b_run.pressed.connect(func(): main._on_run_pressed())
	row.add_child(b_run)

	var b_stop := Prts.button("X 停止")
	b_stop.pressed.connect(func(): main._on_stop_pressed())
	row.add_child(b_stop)

	row.add_child(Prts.vline())

	_caret_text = Prts.dim_label("行 1，列 1")
	_caret_text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_caret_text)

	row.add_child(Prts.spacer())

	_byte_text = Prts.label("0 / 0 B", Prts.FS_TINY, Prts.TEXT)
	_byte_text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_byte_text)

	_byte_bar = ProgressBar.new()
	_byte_bar.custom_minimum_size = Vector2(110, 8)
	_byte_bar.show_percentage = false
	_byte_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_byte_bar)

	bar.add_child(Prts.pad(row, 10, 7))
	add_child(bar)

	# ---- 代码区
	var wrap := PanelContainer.new()
	wrap.add_theme_stylebox_override("panel", Prts.flat(Prts.BG, Prts.LINE, 1))
	wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_edit = PyCodeEdit.new()
	_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_edit.custom_minimum_size = Vector2(0, 200)
	_edit.gutters_draw_line_numbers = true
	_edit.gutters_zero_pad_line_numbers = false
	_edit.highlight_current_line = true
	# 光标停在一个变量名上（或选中一段文字）时，全文里同名的都跟着亮起来。
	# 这是引擎自带的能力，不用自己扫文本；配色见 prts.gd 的 word_highlighted_color
	# （默认那支是淡青色，和这套黑白灰不搭）。
	_edit.highlight_all_occurrences = true
	_edit.indent_automatic = true
	# Python 不接受制表符混排，所以 Tab 一律展开成 4 个空格
	_edit.indent_use_spaces = true
	_edit.indent_size = 4
	_edit.wrap_mode = TextEdit.LINE_WRAPPING_NONE
	_edit.minimap_draw = false
	_edit.draw_tabs = false
	_edit.caret_blink = true
	_edit.syntax_highlighter = _make_highlighter()
	# 自建补全。CodeEdit 自带的那个在 4.7 上不工作，见 CompletionPopup 的说明。
	_edit.code_completion_enabled = false
	# 拦截按键必须用 gui_input 信号：它是"先发信号再调虚函数"，
	# 在这里 accept_event() 就能抢在 TextEdit 把 Tab 当缩进吃掉之前拿到它。
	_edit.gui_input.connect(_on_edit_gui_input)
	_edit.add_theme_font_size_override("font_size", Prts.FS_BODY)
	_edit.text_changed.connect(_on_text_changed)
	_edit.caret_changed.connect(_on_caret_changed)
	# 运行位置白框挂在编辑器内部：这样它拿到的就是编辑器局部坐标，
	# 也会画在文本之上（子节点后画），不必自己算装订线与滚动偏移。
	_run_line = RunLineFrame.new()
	_run_line.editor = _edit
	_edit.add_child(_run_line)
	wrap.add_child(_edit)

	var frame := PrtsFrame.new()
	frame.bracket_len = 12
	frame.thickness = 2
	frame.bracket_color = Prts.FRAME_IDLE
	wrap.add_child(frame)
	_frame = frame

	add_child(wrap)

	# ---- 状态行：第一行语法状态，第二行快捷键提示
	# 原来挤在一行里：状态标签被快捷键提示压到只剩 115px（实测与文字
	# 等宽、零余量），语法报错一长就被 clip 裁掉。拆成两行各放得下。
	var foot := PanelContainer.new()
	foot.add_theme_stylebox_override("panel", Prts.flat(Prts.PANEL, Prts.LINE, 0))
	var foot_col := VBoxContainer.new()
	foot_col.add_theme_constant_override("separation", 2)
	_status = Prts.label("", Prts.FS_TINY, Prts.DIM)
	_status.clip_text = true
	foot_col.add_child(_status)
	var keys := Prts.dim_label("Tab 缩进　·　输入时自动补全　·　Ctrl+Space 手动补全　·　Ctrl+S 保存　·　Ctrl+Enter 运行")
	foot_col.add_child(keys)
	foot.add_child(Prts.pad(foot_col, 10, 4))
	add_child(foot)


func _make_highlighter() -> SyntaxHighlighter:
	# 用游戏自己的词法器做高亮，而不是内置 CodeHighlighter 的浅层文本匹配。
	# 好处是编辑器里的颜色和服务器真正理解的语法完全一致。
	_highlighter = PyHighlighter.new()
	_highlighter.editor = _edit
	return _highlighter


# ---------------------------------------------------------------- 对外接口

func get_code() -> String:
	return _edit.text if _edit != null else ""


## 运行指示框：正在跑的时候角标点亮，和左侧可视化面板保持一致。
## 这样不切回可视化页也能一眼看出服务器是不是在跑。
func set_running(on: bool) -> void:
	if _frame == null:
		return
	_frame.bracket_color = Prts.WHITE if on else Prts.FRAME_IDLE
	_frame.queue_redraw()
	_sync_run_line()


## 把"现在执行到哪一行"交给白框。
## 该框哪一行由 Main 判断（运行时跟着取指走、出错停在出错行、跑完不框），
## 这里只负责传达。
func _sync_run_line() -> void:
	if _run_line == null:
		return
	_run_line.show_line(main.current_exec_line())


func _on_run_tick(_info: Dictionary) -> void:
	_sync_run_line()


func load_from_game() -> void:
	if _edit == null:
		return
	_loading = true
	_edit.text = Game.current_code()
	_edit.set_caret_line(0)
	_edit.set_caret_column(0)
	_loading = false
	if _highlighter != null:
		_highlighter.refresh()
	# 换了文件，行号全部作废：等下一次运行时重新框
	if _run_line != null:
		_run_line.clear()
	refresh_meters()
	_check_syntax()
	_on_caret_changed()


func refresh_meters() -> void:
	if _edit == null:
		return
	var bytes := _edit.text.to_utf8_buffer().size()
	var limit := Game.disk_bytes()
	_byte_text.text = "%d / %d B" % [bytes, limit]
	_byte_text.add_theme_color_override("font_color", Prts.TEXT if bytes <= limit else Prts.WHITE)
	_byte_bar.max_value = maxi(1, limit)
	_byte_bar.value = mini(bytes, limit)
	if main != null:
		main._refresh_hardware_chips_only()


# ---------------------------------------------------------------- 事件

func _on_text_changed() -> void:
	if _loading:
		return
	Game.set_current_code(_edit.text)
	# 代码变了，"本文件里的标识符"这批候选就过期了
	_candidates = []
	if _highlighter != null:
		_highlighter.refresh()
	refresh_meters()
	_check_syntax()

	# 刚确认过候选，别立刻又弹出来
	if _suppress_completion:
		_suppress_completion = false
		return

	# 边打字边弹：前缀够长才打扰，够短就自动收起来
	var prefix := _edit.word_before_caret()
	if _completion != null and _completion.is_open():
		_open_completion(true)
	elif prefix.length() >= 2:
		_open_completion(true)


func _on_caret_changed() -> void:
	if _caret_text != null:
		_caret_text.text = "行 %d，列 %d" % [_edit.get_caret_line() + 1, _edit.get_caret_column() + 1]
	# 光标挪了，弹框跟着挪；挪到不该弹的位置就自己收起来
	if _completion != null and _completion.is_open() and not _suppress_completion:
		_open_completion(true)


func _shortcut_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if not k.pressed or k.echo:
		return

	# Ctrl+Space 是各家编辑器弹补全的通用快捷键。
	# 注意 Tab 收不到：CodeEdit 在 _gui_input 阶段就把 Tab 处理掉了
	# （补全框开着时用来确认候选，否则用来缩进），轮不到快捷输入阶段。
	if k.ctrl_pressed and k.keycode == KEY_SPACE:
		_open_completion(false)
		get_viewport().set_input_as_handled()
		return

	if not k.ctrl_pressed:
		return

	if k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER:
		main._on_run_pressed()
		get_viewport().set_input_as_handled()
	elif k.keycode == KEY_S:
		_save_now()
		get_viewport().set_input_as_handled()


## 键盘拦截。补全框开着时接管 Tab/Enter/方向键/Esc；
## 没开时，Tab 在标识符后面弹补全，其余情况放行给 TextEdit 做缩进。
func _on_edit_gui_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if not k.pressed or k.echo:
		return

	if _completion != null and _completion.is_open():
		match k.keycode:
			KEY_TAB, KEY_ENTER, KEY_KP_ENTER:
				_accept_completion()
				_edit.accept_event()
				return
			KEY_UP:
				_completion.move_selection(-1)
				_edit.accept_event()
				return
			KEY_DOWN:
				_completion.move_selection(1)
				_edit.accept_event()
				return
			KEY_ESCAPE:
				_close_completion()
				_edit.accept_event()
				return
		return

	if k.keycode == KEY_TAB and not k.shift_pressed \
			and not k.ctrl_pressed and not k.alt_pressed:
		if _edit.has_word_before_caret():
			_open_completion(false)
			_edit.accept_event()


## 打开补全框。auto=true 表示是"边打字边弹"，前缀太短就不打扰。
func _open_completion(auto: bool) -> void:
	if _edit == null or _completion == null:
		return
	var prefix := _edit.word_before_caret()
	if auto and prefix.length() < 2:
		_close_completion()
		return
	var items := _filtered_candidates(prefix)
	if items.is_empty():
		_close_completion()
		return
	_completion.open(items, _caret_popup_pos(), main)


func _close_completion() -> void:
	if _completion != null:
		_completion.close()


## 光标右下角的位置，转成 Main 的局部坐标
func _caret_popup_pos() -> Vector2:
	var r := _edit.get_rect_at_line_column(_edit.get_caret_line(), _edit.get_caret_column())
	var g := _edit.global_position + Vector2(r.position) + Vector2(0, _edit.get_line_height())
	return main.get_global_transform().affine_inverse() * g


func _accept_completion() -> void:
	if _completion == null or not _completion.is_open():
		return
	var it := _completion.selected_item()
	_close_completion()
	if it.is_empty():
		return
	# 把光标前那个半截单词替换成候选
	var line := _edit.get_caret_line()
	var start := _edit.word_start_before_caret()
	_suppress_completion = true
	_edit.select(line, start, line, _edit.get_caret_column())
	_edit.insert_text_at_caret(String(it["insert"]))
	_edit.deselect()
	_edit.grab_focus()


## 候选全集：这台服务器认识的所有名字
func _all_candidates() -> Array:
	if not _candidates.is_empty():
		return _candidates
	var out: Array = []
	var seen := {}
	for kw in PyLexer.KEYWORDS:
		if seen.has(kw):
			continue
		seen[kw] = true
		out.append({"text": kw, "insert": kw, "color": _kw_color(kw), "hint": "关键字"})
	for b in PyVM.BUILTIN_NAMES:
		if seen.has(b):
			continue
		seen[b] = true
		out.append({"text": b, "insert": b + "(",
			"color": PyHighlighter.C_BUILTIN, "hint": "内置函数"})
	for m in PyVM.LIST_METHODS:
		if seen.has(m):
			continue
		seen[m] = true
		out.append({"text": m, "insert": m + "(",
			"color": PyHighlighter.C_METHOD, "hint": "数组方法"})
	for id in _collect_identifiers():
		if seen.has(id):
			continue
		seen[id] = true
		out.append({"text": id, "insert": id,
			"color": PyHighlighter.C_NAME, "hint": "本文件"})
	return out


## 按前缀过滤。前缀匹配排前面，包含匹配排后面。
func _filtered_candidates(prefix: String) -> Array:
	var all := _all_candidates()
	if prefix.is_empty():
		return all
	var p := prefix.to_lower()
	var head: Array = []
	var tail: Array = []
	for it in all:
		var t := String(it["text"]).to_lower()
		if t.begins_with(p):
			head.append(it)
		elif t.contains(p):
			tail.append(it)
	head.append_array(tail)
	return head


static func _kw_color(kw: String) -> Color:
	if PyHighlighter.KW_DEF.has(kw):
		return PyHighlighter.C_DEF
	if PyHighlighter.KW_LOGIC.has(kw):
		return PyHighlighter.C_LOGIC
	if PyHighlighter.KW_CONST.has(kw):
		return PyHighlighter.C_CONST
	return PyHighlighter.C_FLOW


## 收集当前代码里出现过的标识符，让补全能提示玩家自己起的名字
func _collect_identifiers() -> PackedStringArray:
	var out := PackedStringArray()
	if _edit == null:
		return out
	var lex := PyLexer.new()
	var lexed := lex.tokenize(_edit.text)
	var seen := {}
	for tk in lexed["tokens"]:
		if int(tk["t"]) != PyLexer.T_NAME:
			continue
		var w := str(tk["v"])
		if seen.has(w) or PyVM.BUILTIN_NAMES.has(w):
			continue
		seen[w] = true
		out.append(w)
	return out


## Ctrl+S。代码平时就是自动存进内存的，这里做的是明确落盘 + 给个反馈，
## 让玩家有"我保存过了"的确定感。
func _save_now() -> void:
	Game.set_current_code(_edit.text)
	Game.save_game()
	_flash("已保存到磁盘")
	main.log_line("已保存 %s（%d 字节）" % [
		String(Game.files[Game.current_file]["name"]) if not Game.files.is_empty() else "算法",
		_edit.text.to_utf8_buffer().size()], "ok")


func _flash(text: String) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", Prts.WHITE)
	_flash_left = 1.4


func _process(delta: float) -> void:
	if _flash_left <= 0.0:
		return
	_flash_left -= delta
	if _flash_left <= 0.0:
		_check_syntax()


## 每次改动都完整跑一遍前端，这样错误在按运行之前就暴露出来
func _check_syntax() -> void:
	var code := _edit.text
	if code.strip_edges().is_empty():
		_set_status("等待输入", Prts.DIM)
		return

	var parser := PyParser.new()
	var parsed := parser.parse(code)
	if not parsed["ok"]:
		var e: Dictionary = parsed["errors"][0]
		_set_status("第 %d 行：%s" % [e["line"], e["msg"]], Prts.WHITE)
		return

	var compiler := PyCompiler.new()
	var compiled := compiler.compile(parsed["ast"])
	if not compiled["ok"]:
		var e2: Dictionary = compiled["errors"][0]
		_set_status("第 %d 行：%s" % [e2["line"], e2["msg"]], Prts.WHITE)
		return

	var fns: Dictionary = compiled["functions"]
	if fns.is_empty():
		_set_status("语法正常，但没有定义任何函数。服务器需要 def sort(a):", Prts.TEXT_HI)
		return
	if not fns.has("sort"):
		_set_status("语法正常，但没有 sort 函数（运行时会尝试用唯一的函数）。", Prts.TEXT_HI)
		return
	_set_status("语法正常 · sort() 已就绪", Prts.TEXT)


func _set_status(text: String, color: Color) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", color)

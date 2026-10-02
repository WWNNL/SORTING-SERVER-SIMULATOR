class_name EscMenu
extends Control
## ESC 菜单：玩家随时按 Esc 呼出的系统层。
##
## 四个页面，一层面板共用一个背板，切换就是换可见性（这套界面没有淡入淡出）：
##
##   根页        系统菜单：设置 / 重置进度 / 退出系统 三项。
##   设置页      TabContainer 两个页签——「视频设置」是空壳（只摆结构），
##               「系统设置」是功能页：音效开关 + 主音量，改了就写盘。
##   重置确认    破坏性动作必须过一道确认；确认后交 Main.reset_progress() 执行。
##   退出确认    确认后直接退出程序。
##
## 打开时把整棵树暂停（get_tree().paused）：菜单是"世界停了"的语义，
## 正在跑的那一局、电费累计、循环模式都得一起停。自己设 PROCESS_MODE_ALWAYS，
## 暂停期间输入和 UI 都还活着。
##
## 层级：z_index 400。压住报错弹窗（300），让位给开机自检（500）、接入屏（600）
## 和标题屏（700）——那三段是"还没进系统"，菜单不该出现（见 _can_open）。
##
## 红色只留给报错弹窗，所以确认重置也是黑白灰：层级靠文案把话说死，
## 不靠颜色制造紧张（见 error_popup 的配色说明）。

enum Page { PAGE_ROOT, PAGE_SETTINGS, PAGE_RESET, PAGE_QUIT }

const PANEL_W := 470.0
## 根菜单三个条目的最小高度
const ITEM_H := 36.0
## 背板压暗浓度。报错弹窗刻意不压暗（它只是"出事了"），菜单压暗：
## 它是暂停世界的语义层，底下那屏这时候不该再抢注意力。
const BACKDROP_ALPHA := 0.78

var main: Control = null

var _open := false
var _page := Page.PAGE_ROOT
## 音量滑条拖动后有没有还没落盘的值（关菜单时兜底写一次，见 _flush_volume）
var _volume_dirty := false

var _pages := {}
var _btn_audio: Button
var _volume_slider: HSlider
var _volume_label: Label
var _res_option: OptionButton


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# 压住报错弹窗（300），让位给开机（500）/接入（600）/标题屏（700）
	z_index = 400
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	# 菜单开着时整棵树是暂停的，输入与 UI 必须继续工作
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build()


# ================================================================ 界面搭建

func _build() -> void:
	# 背板：压暗 + 吃掉点击。点背板 = 关菜单（和 Esc 一个意思）。
	var backdrop := ColorRect.new()
	backdrop.color = Color(Prts.BLACK, BACKDROP_ALPHA)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	backdrop.gui_input.connect(_on_backdrop_input)
	add_child(backdrop)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	# 转发点击给背板：CenterContainer 只管摆位置，不该截胡鼠标
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Prts.flat(Prts.PANEL, Prts.LINE_HI, 1))
	panel.custom_minimum_size = Vector2(PANEL_W, 0)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	center.add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	panel.add_child(Prts.pad(col, 20, 16))

	_pages[Page.PAGE_ROOT] = _build_root_page()
	_pages[Page.PAGE_SETTINGS] = _build_settings_page()
	_pages[Page.PAGE_RESET] = _confirm_page("重置进度",
		"将清空狗狗币、硬件升级、阶段进度、算法文件与全部统计成绩。\n\n此操作无法撤销。",
		"确认重置", _on_reset_confirmed)
	_pages[Page.PAGE_QUIT] = _confirm_page("退出系统",
		"确定要断开与 PRTS 的连接并退出程序吗？\n进度已自动保存，下次接入时会恢复。",
		"确认退出", _on_quit_confirmed)
	for p in _pages.values():
		p.visible = false
		col.add_child(p)
	_show_page()


## 页头：白竖杠 + 标题 + 右侧的 Esc 提示。四页共用一个形状。
func _header(title: String, hint: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var tick := ColorRect.new()
	tick.color = Prts.WHITE
	tick.custom_minimum_size = Vector2(3, 14)
	tick.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(tick)
	row.add_child(Prts.label(title, Prts.FS_BODY, Prts.TEXT_HI))
	row.add_child(Prts.spacer())
	row.add_child(Prts.dim_label(hint))
	return row


func _build_root_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 10)
	page.add_child(_header("系统菜单", "ESC 关闭"))
	page.add_child(Prts.hline())

	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 8)
	list.add_child(_menu_item("设 置", _go_settings))
	list.add_child(_menu_item("重置进度", _go_reset))
	list.add_child(_menu_item("退出系统", _go_quit))
	page.add_child(list)

	var foot := Prts.dim_label("PRTS · SORTING SERVER SIMULATOR")
	foot.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	page.add_child(foot)
	return page


## 根菜单的一个条目。整行反白已经是这套主题的"当前项"，不再加图标或箭头。
func _menu_item(text: String, cb: Callable) -> Button:
	var b := Prts.button(text)
	b.custom_minimum_size = Vector2(0, ITEM_H)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(cb)
	return b


func _build_settings_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 10)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	var back := Prts.button("< 返回", 76)
	back.pressed.connect(_go_root)
	head.add_child(back)
	head.add_child(Prts.label("设置", Prts.FS_BODY, Prts.TEXT_HI))
	head.add_child(Prts.spacer())
	head.add_child(Prts.dim_label("ESC 关闭"))
	page.add_child(head)
	page.add_child(Prts.hline())

	var tabs := TabContainer.new()
	tabs.custom_minimum_size = Vector2(0, 236)
	tabs.add_child(_build_video_tab())
	tabs.add_child(_build_system_tab())
	page.add_child(tabs)
	return page


## 视频设置：分辨率是功能项；显示模式、垂直同步还是壳——
## 一个灰掉的假开关只会让人觉得"坏了"，一行说明才像"还没到站"。
func _build_video_tab() -> Control:
	var wrap := MarginContainer.new()
	wrap.add_theme_constant_override("margin_left", 16)
	wrap.add_theme_constant_override("margin_right", 16)
	wrap.add_theme_constant_override("margin_top", 12)
	wrap.add_theme_constant_override("margin_bottom", 12)
	wrap.name = "视频设置"

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	box.add_child(_build_resolution_row())
	box.add_child(Prts.spacer())

	var l1 := Prts.label("界面按基准 1600 × 900 整倍缩放，字体随之放大",
		Prts.FS_TINY, Prts.TEXT)
	l1.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(l1)
	var l2 := Prts.dim_label("显示模式 · 垂直同步 开发中")
	l2.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(l2)
	wrap.add_child(box)
	return wrap


## 分辨率行。预设**全部列出、不过滤**：装不上的选了就真的开那么大的窗口
## （超出屏幕的部分在屏外，菜单面板永远居中，随时能改回来）。
## 选完立即生效并落盘，所见即所选。
func _build_resolution_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var cap := Prts.label("分辨率", Prts.FS_SMALL, Prts.DIM)
	cap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(cap)
	row.add_child(Prts.spacer())

	_res_option = OptionButton.new()
	_res_option.focus_mode = Control.FOCUS_NONE
	_res_option.custom_minimum_size = Vector2(170, 0)
	for r in GameSettings.RESOLUTIONS:
		_res_option.add_item("%d × %d（%d 倍）" % [r.x, r.y,
			r.x / GameSettings.BASE_RESOLUTION.x])
	_res_option.item_selected.connect(_on_resolution_selected)
	row.add_child(_res_option)
	_sync_resolution_option()
	return row


## 按当前生效值回显下拉框。下拉项与 GameSettings.RESOLUTIONS 一一对应。
func _sync_resolution_option() -> void:
	if _res_option == null:
		return
	var idx := GameSettings.RESOLUTIONS.find(GameSettings.video_size)
	_res_option.select(maxi(idx, 0))


func _on_resolution_selected(idx: int) -> void:
	if idx < 0 or idx >= GameSettings.RESOLUTIONS.size():
		return
	GameSettings.video_size = GameSettings.RESOLUTIONS[idx]
	GameSettings.save()
	GameSettings.apply_resolution()
	_sync_resolution_option()


func _build_system_tab() -> Control:
	var wrap := MarginContainer.new()
	wrap.add_theme_constant_override("margin_left", 16)
	wrap.add_theme_constant_override("margin_right", 16)
	wrap.add_theme_constant_override("margin_top", 12)
	wrap.add_theme_constant_override("margin_bottom", 12)
	wrap.name = "系统设置"

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	box.add_child(_build_audio_row())
	box.add_child(Prts.hline())
	box.add_child(_build_volume_row())
	box.add_child(Prts.spacer())
	box.add_child(Prts.dim_label("设置会自动保存，下次启动时生效。"))
	wrap.add_child(box)
	return wrap


## 音效行。开关动作交给 Main.set_audio_enabled——控制行那个「音效」按钮
## 和这里是同一个开关的两张脸，只能有一个写入口（见 sync_audio）。
func _build_audio_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var cap := Prts.label("音效", Prts.FS_SMALL, Prts.DIM)
	cap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(cap)
	row.add_child(Prts.spacer())
	_btn_audio = Prts.button("音效：开", 92)
	_btn_audio.pressed.connect(_on_audio_toggled)
	row.add_child(_btn_audio)
	_refresh_audio()
	return row


func _build_volume_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var cap := Prts.label("主音量", Prts.FS_SMALL, Prts.DIM)
	cap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(cap)

	_volume_slider = HSlider.new()
	_volume_slider.min_value = 0
	_volume_slider.max_value = 100
	_volume_slider.step = 1
	_volume_slider.value = roundf(GameSettings.volume * 100.0)
	# 鼠标驱动的界面：焦点环这套主题本来就不画（按钮也是 FOCUS_NONE）
	_volume_slider.focus_mode = Control.FOCUS_NONE
	_volume_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_volume_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_volume_slider.custom_minimum_size = Vector2(150, 0)
	_volume_slider.value_changed.connect(_on_volume_changed)
	_volume_slider.drag_ended.connect(_on_volume_drag_ended)
	row.add_child(_volume_slider)

	_volume_label = Prts.label("%d%%" % _volume_slider.value, Prts.FS_SMALL, Prts.TEXT_HI)
	_volume_label.custom_minimum_size = Vector2(46, 0)
	_volume_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_volume_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_volume_label)
	return row


## 确认页：重置和退出共用一个形状，只有文案、按钮字和"确认之后做什么"不同。
func _confirm_page(title: String, body: String, yes_text: String,
		on_yes: Callable) -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 10)
	page.add_child(_header(title, "ESC 取消"))
	page.add_child(Prts.hline())

	var text := Prts.label(body, Prts.FS_BODY, Prts.TEXT_HI)
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.add_child(text)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.add_child(Prts.spacer())
	var cancel := Prts.button("取消", 92)
	cancel.pressed.connect(_go_root)
	row.add_child(cancel)
	var yes := Prts.button(yes_text, 110)
	yes.pressed.connect(on_yes)
	row.add_child(yes)
	page.add_child(row)
	return page


# ================================================================ 页面切换

func _go_page(p: int) -> void:
	_page = p
	_show_page()


func _go_root() -> void:
	_go_page(Page.PAGE_ROOT)


func _go_settings() -> void:
	_go_page(Page.PAGE_SETTINGS)


func _go_reset() -> void:
	_go_page(Page.PAGE_RESET)


func _go_quit() -> void:
	_go_page(Page.PAGE_QUIT)


func _show_page() -> void:
	for k in _pages:
		(_pages[k] as Control).visible = k == _page


func current_page() -> int:
	return _page


## 某一页的根控件。测试核对"四页互斥可见"用。
func page_control(p: int) -> Control:
	return _pages.get(p)


## 「音效」按钮当前文案。测试核对开关同步用。
func audio_button_text() -> String:
	return _btn_audio.text if _btn_audio != null else ""


# ================================================================ 开关与输入

func is_open() -> bool:
	return _open


## 标题屏 / 开机自检 / 接入屏还在播的时候不开菜单：那是"还没进系统"的阶段，
## 它们自己也在吃输入（_input 里全吃掉），菜单不该跟它们抢。
func _can_open() -> bool:
	if main == null:
		return true
	return main.login() == null and main.boot() == null and main.title() == null


func open_menu() -> void:
	if _open or not _can_open():
		return
	_open = true
	_page = Page.PAGE_ROOT
	_show_page()
	visible = true
	get_tree().paused = true


func close_menu() -> void:
	if not _open:
		return
	_open = false
	_flush_volume()
	visible = false
	get_tree().paused = false


## 音量拖完还没落盘的兜底：drag_ended 理论上总会来，
## 但"拖到一半菜单被关掉"这种路径不该丢设置。
func _flush_volume() -> void:
	if not _volume_dirty:
		return
	_volume_dirty = false
	GameSettings.save()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	# 长按 Esc 会连发 echo：不挡住的话菜单开了又关、关了又开
	if k.echo:
		return
	if not k.is_action_pressed("ui_cancel"):
		return
	if _open:
		get_viewport().set_input_as_handled()
		close_menu()
		return
	if _can_open():
		get_viewport().set_input_as_handled()
		open_menu()


func _on_backdrop_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			accept_event()
			close_menu()


# ================================================================ 设置项

## 控制行「音效」按钮切换后同步按钮文案（Main.set_audio_enabled 调）。
## 菜单这边只改 UI 不写盘：写盘只有一个入口，两边才不会各存各的。
func sync_audio(on: bool) -> void:
	if _btn_audio != null:
		_btn_audio.text = "音效：开" if on else "音效：关"


func _refresh_audio() -> void:
	if _btn_audio != null:
		_btn_audio.text = "音效：开" if GameSettings.audio_enabled else "音效：关"


func _on_audio_toggled() -> void:
	var on := not GameSettings.audio_enabled
	if main != null:
		main.set_audio_enabled(on)
		return
	# 没有主界面可挂（独立实例/测试）：自己写盘，行为保持一致
	GameSettings.audio_enabled = on
	GameSettings.save()
	_refresh_audio()


func _on_volume_changed(v: float) -> void:
	GameSettings.volume = clampf(v / 100.0, 0.0, 1.0)
	GameSettings.apply_volume()
	if _volume_label != null:
		_volume_label.text = "%d%%" % int(round(v))
	_volume_dirty = true


func _on_volume_drag_ended(changed: bool) -> void:
	if changed:
		_volume_dirty = false
		GameSettings.save()


func _on_reset_confirmed() -> void:
	if main != null:
		main.reset_progress()
	close_menu()


func _on_quit_confirmed() -> void:
	get_tree().quit()

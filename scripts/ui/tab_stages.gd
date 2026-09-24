class_name TabStages
extends VBoxContainer
## 算法阶段：数据规模的来源，同时也是重刷入口。
##
## 数据规模由阶段决定，而阶段由通关进度解锁。已经通过的阶段可以点开重刷：
## 收益照给、成绩照记，但不会再推进进度（也不会把进度往回退）。

var main: Control

var _summary: Label
var _hint: Label
var _pick: Label
var _rows_box: VBoxContainer
var _dirty := true


func _ready() -> void:
	add_theme_constant_override("separation", 10)
	_build()
	Game.stage_changed.connect(func(_i): refresh())
	set_process(true)
	refresh()


func _process(_delta: float) -> void:
	if not _dirty:
		return
	# 重建整个阶段列表会销毁并新建上百个节点，不可见时别做。
	# _dirty 保持为真，切回这一页时再补。
	if not is_visible_in_tree():
		return
	_dirty = false
	_rebuild()


func refresh() -> void:
	_dirty = true


func _build() -> void:
	add_child(Prts.pad(Prts.section("阶段进度", get_theme_default_font()), 12, 10))

	var head := VBoxContainer.new()
	head.add_theme_constant_override("separation", 5)
	_summary = Prts.label("", Prts.FS_BODY, Prts.TEXT_HI)
	head.add_child(_summary)
	_hint = Prts.label("", Prts.FS_SMALL, Prts.TEXT)
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	head.add_child(_hint)
	_pick = Prts.dim_label("", Prts.FS_TINY)
	_pick.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	head.add_child(_pick)
	add_child(Prts.panel(head, 12, 10))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", 4)
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rows_box)


func _rebuild() -> void:
	if _rows_box == null:
		return
	for c in _rows_box.get_children():
		c.queue_free()

	var frontier := Game.frontier_index()
	var total := ServerSpec.stage_count()
	var replay := Game.is_replay()
	_summary.text = "已通过 %d / %d 关　·　当前挑战：%s%s" % [
		Game.cleared, total, String(Game.stage_info().get("name", "")),
		"（重刷）" if replay else ""]
	_hint.text = String(Game.stage_info().get("hint", ""))
	_pick.text = "点一下任意一关就能换过去。已经通过的关卡可以重刷：收益照给、成绩照记，但进度不动。" if frontier > 0 else \
		"通过第一关之后，就能回到这里重刷任意已通过的关卡。"

	for i in total:
		_rows_box.add_child(_make_row(i, frontier))


func _make_row(i: int, frontier: int) -> Control:
	var s := ServerSpec.stage(i)
	var passed := i < frontier
	var active := i == Game.stage_index()
	var selectable := Game.can_select_stage(i)

	var bg := Prts.RAISED if active else Prts.PANEL
	var border := Prts.WHITE if active else Prts.LINE
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", Prts.flat(bg, border, 1))
	if selectable:
		# 只有能选的关卡吃鼠标事件；锁着的行不要变成"看起来能点但没反应"。
		pc.mouse_filter = Control.MOUSE_FILTER_STOP
		pc.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		pc.gui_input.connect(_on_row_input.bind(i, pc))
		pc.mouse_entered.connect(_on_row_hover.bind(pc, i, active, true))
		pc.mouse_exited.connect(_on_row_hover.bind(pc, i, active, false))
	else:
		pc.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var idx_color := Prts.WHITE if active else (Prts.TEXT if passed else Color("#3a3a3a"))
	var idx := Prts.label("%02d" % (i + 1), Prts.FS_SMALL, idx_color)
	idx.custom_minimum_size = Vector2(26, 0)
	row.add_child(idx)

	var name_col := VBoxContainer.new()
	name_col.add_theme_constant_override("separation", 1)
	name_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var name_color := Prts.WHITE if active else (Prts.TEXT if passed else Color("#454545"))
	name_col.add_child(Prts.label(String(s["algo"]), Prts.FS_SMALL, name_color))
	name_col.add_child(Prts.dim_label("%d 个元素" % int(s["n"]), Prts.FS_TINY))
	row.add_child(name_col)

	var budget_col := VBoxContainer.new()
	budget_col.add_theme_constant_override("separation", 1)
	budget_col.custom_minimum_size = Vector2(130, 0)
	budget_col.add_child(Prts.dim_label("效率预算"))
	var best := Game.stage_best_ops(i)
	var btext := "%d 次读写" % int(s["ops"])
	if best > 0:
		# 规模变过以后旧成绩不再可比，标出来而不是混进同一行数字里
		var bn := Game.stage_best_size(i)
		if bn == int(s["n"]):
			btext += "　最好 %d" % best
		elif bn == 0:
			btext += "　旧记录 %d" % best
		else:
			btext += "　最好 %d（%d 个元素时）" % [best, bn]
	var bl := Prts.label(btext, Prts.FS_TINY, Prts.TEXT if passed or active else Color("#454545"))
	budget_col.add_child(bl)
	row.add_child(budget_col)

	var status := Prts.label("", Prts.FS_TINY, Prts.DIM)
	status.custom_minimum_size = Vector2(58, 0)
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	if active:
		status.text = "重刷中" if passed else "进行中"
		status.add_theme_color_override("font_color", Prts.WHITE)
	elif passed:
		status.text = "已通过"
		status.add_theme_color_override("font_color", Prts.TEXT)
	else:
		status.text = "未解锁"
		status.add_theme_color_override("font_color", Color("#3a3a3a"))
	row.add_child(status)

	pc.add_child(Prts.pad(row, 10, 8))
	return pc


# ---------------------------------------------------------------- 选择

func _on_row_input(event: InputEvent, i: int, pc: PanelContainer) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	pc.accept_event()
	main.select_stage(i)


## 悬停反馈。已经选中的行本来就有白边，不要再叠一层。
func _on_row_hover(pc: PanelContainer, i: int, active: bool, on: bool) -> void:
	if active:
		return
	if on:
		pc.add_theme_stylebox_override("panel", Prts.flat(Prts.HOVER, Prts.LINE_HI, 1))
	else:
		pc.add_theme_stylebox_override("panel", Prts.flat(Prts.PANEL, Prts.LINE, 1))

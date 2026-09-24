class_name TabStages
extends VBoxContainer
## 算法阶段：数据规模的来源。
##
## 数据规模不可选，它由通关进度决定。每一关的效率预算都卡在
## "必须换更好的算法"的位置上，所以这个列表实际上是一张算法课程表。

var main: Control

var _summary: Label
var _hint: Label
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

	var cur := Game.stage_index()
	var total := ServerSpec.stage_count()
	_summary.text = "已通过 %d / %d 关　·　当前：%s" % [
		Game.cleared, total, String(Game.stage_info().get("name", ""))]
	_hint.text = String(Game.stage_info().get("hint", ""))

	for i in total:
		_rows_box.add_child(_make_row(i, cur))


func _make_row(i: int, cur: int) -> Control:
	var s := ServerSpec.stage(i)
	var passed := i < Game.cleared
	var active := i == cur
	var locked := i > cur

	var bg := Prts.RAISED if active else Prts.PANEL
	var border := Prts.WHITE if active else Prts.LINE
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", Prts.flat(bg, border, 1))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

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
		btext += "　最好 %d" % best
	var bl := Prts.label(btext, Prts.FS_TINY, Prts.TEXT if not locked else Color("#454545"))
	budget_col.add_child(bl)
	row.add_child(budget_col)

	var status := Prts.label("", Prts.FS_TINY, Prts.DIM)
	status.custom_minimum_size = Vector2(58, 0)
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	if passed:
		status.text = "已通过"
		status.add_theme_color_override("font_color", Prts.TEXT)
	elif active:
		status.text = "进行中"
		status.add_theme_color_override("font_color", Prts.WHITE)
	else:
		status.text = "未解锁"
		status.add_theme_color_override("font_color", Color("#3a3a3a"))
	row.add_child(status)

	pc.add_child(Prts.pad(row, 10, 8))
	return pc

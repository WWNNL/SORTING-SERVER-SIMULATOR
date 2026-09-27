class_name CompletionPopup
extends PanelContainer
## 代码补全提示框。
##
## 没有用 CodeEdit 自带的补全：实测在 Godot 4.7 上它连弹框节点都不会创建
## （update_code_completion_options / request_code_completion 都试过，
## 整棵场景树里搜不到任何 Popup）。自己做一个反而更可控——
## 能完全按 PRTS 的直角黑白风格来，键位行为也由自己定。
##
## 它是 Main 的直接子节点，靠 z_index 压在最上层。

const MAX_ROWS := 9
## 行高和名字列宽都是按 12px 正文量的。字号变了按比例换算，见 _px()。
const ROW_HEIGHT := 19
const NAME_WIDTH := 96

var _box: VBoxContainer
var _rows: Array = []          ## [{root, name_label}]
var _items: Array = []
var _sel := 0
var _open := false
## 当前字号。默认跟正文，代码区 Ctrl+滚轮放大时由 TabEditor 通知改（见 set_font_size）
var _font_size := Prts.FS_SMALL
## open() 传进来的那个父控件，重新贴位置时要用（见 _clamp）
var _parent: Control


func _init() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 200
	add_theme_stylebox_override("panel", Prts.flat(Prts.RAISED, Prts.WHITE, 1))

	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 1)
	pad.add_theme_constant_override("margin_right", 1)
	pad.add_theme_constant_override("margin_top", 3)
	pad.add_theme_constant_override("margin_bottom", 3)
	add_child(pad)

	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 0)
	pad.add_child(_box)


func is_open() -> bool:
	return _open


func selected_item() -> Dictionary:
	if _sel < 0 or _sel >= _items.size():
		return {}
	return _items[_sel]


func item_count() -> int:
	return _items.size()


func selected_index() -> int:
	return _sel


## 12px 下量的尺寸，换算到当前字号
func _px(v: float) -> int:
	return int(round(v * float(_font_size) / float(Prts.FS_SMALL)))


## 跟着代码区的缩放走。
##
## 补全框挂在 Main 上（靠 z_index 压层），不是编辑器的子节点，所以它**不会**
## 自己继承编辑器的字号——代码放大到 24px 而候选还停在 12px 的话，弹框会小得
## 和旁边对不上。由 TabEditor 在换档时显式通知（见 _zoom_code）。
func set_font_size(px: int) -> void:
	if px == _font_size:
		return
	_font_size = px
	if not _open:
		return
	# 正开着就重建一次：候选行是按字号铺的，尺寸会变，所以要重算尺寸并重新夹回窗口内。
	# 位置本身由调用方用 reposition() 贴到新光标处——字号变了光标在屏幕上的位置也会变。
	_rebuild()
	var m := get_combined_minimum_size()
	size = Vector2(maxf(m.x, 150.0), m.y)
	_clamp(_parent)


## 贴到新的锚点（全局/画布坐标）。缩放后光标位置会变，弹框要跟着挪。
func reposition(at: Vector2) -> void:
	if not _open:
		return
	position = at
	_clamp(_parent)


## 打开并把候选铺出来。at 是全局（画布）坐标。
func open(items: Array, at: Vector2, parent: Control) -> void:
	_items = items
	_parent = parent
	if _items.is_empty():
		close()
		return
	_sel = 0
	_rebuild()
	# 让容器立刻算出尺寸，不等下一帧（等一帧会看到弹框先闪到错误位置）
	var m := get_combined_minimum_size()
	size = Vector2(maxf(m.x, 150.0), m.y)
	position = at
	_clamp(parent)
	visible = true
	_open = true


func close() -> void:
	visible = false
	_open = false
	_items = []
	_sel = 0


func move_selection(delta: int) -> void:
	if not _open or _items.is_empty():
		return
	_sel = wrapi(_sel + delta, 0, _items.size())
	_apply_selection()


func _rebuild() -> void:
	for c in _box.get_children():
		c.queue_free()
	_rows.clear()

	var shown := mini(_items.size(), MAX_ROWS)
	for i in shown:
		var it: Dictionary = _items[i]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)

		var name_label := Prts.label(String(it.get("text", "")), _font_size,
			it.get("color", Prts.TEXT_HI))
		name_label.custom_minimum_size = Vector2(_px(NAME_WIDTH), _px(ROW_HEIGHT - 4))
		row.add_child(name_label)

		var hint := Prts.dim_label(String(it.get("hint", "")), _font_size)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(hint)

		var holder := PanelContainer.new()
		holder.add_theme_stylebox_override("panel",
			Prts.flat(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, _px(8), 1))
		holder.add_child(row)
		_box.add_child(holder)
		_rows.append({"root": holder, "name": name_label})

	if _items.size() > shown:
		_box.add_child(Prts.dim_label("… 还有 %d 项，继续输入可缩小范围"
			% (_items.size() - shown), _font_size))

	_apply_selection()


func _apply_selection() -> void:
	for i in _rows.size():
		var r: Dictionary = _rows[i]
		var holder: PanelContainer = r["root"]
		var name_label: Label = r["name"]
		if i == _sel:
			# 选中项整条反白，和全局的交互语言保持一致
			holder.add_theme_stylebox_override("panel",
				Prts.flat(Prts.WHITE, Prts.WHITE, 0, _px(8), 1))
			name_label.add_theme_color_override("font_color", Prts.BLACK)
		else:
			holder.add_theme_stylebox_override("panel",
				Prts.flat(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, _px(8), 1))
			name_label.add_theme_color_override("font_color",
				(_items[i] as Dictionary).get("color", Prts.TEXT_HI))


## 别让弹框跑到窗口外面去
func _clamp(parent: Control) -> void:
	if parent == null:
		return
	var area := parent.size
	position.x = clampf(position.x, 0.0, maxf(0.0, area.x - size.x))
	position.y = clampf(position.y, 0.0, maxf(0.0, area.y - size.y))

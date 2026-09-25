class_name TabFiles
extends VBoxContainer
## 服务器文件：算法源码的管理、切换与解锁。
##
## 算法库里有一部分需要花狗狗币解锁。锁着的文件仍然显示在列表里，
## 但选中它不会切换运行目标——玩家能看见"有什么"，只是还用不了。
##
## 正在运行的文件那一行末尾会转一个方框小图标（RunSpinner）：运行不属于
## "当前编辑的文件"，切去改别的算法时它继续跑，这个图标就是那件事的可见证据。

var main: Control

var _list: ItemList
var _name_edit: LineEdit
var _info: VBoxContainer
var _stat_line: Label
var _detail: Label
var _btn_delete: Button
var _btn_unlock: Button
## 运行指示器。挂在 ItemList 内部，坐标就是行矩形那一套局部坐标。
var _spinner: RunSpinner


func _ready() -> void:
	add_theme_constant_override("separation", 10)
	_build()
	Game.files_changed.connect(_refresh_list)
	Game.coins_changed.connect(func(_c): _refresh_info(Game.current_file))
	_refresh_list()
	set_process(true)


func _process(_delta: float) -> void:
	# 这一页不可见时什么都不做；行会随列表滚动，所以每帧对一次位置
	if not is_visible_in_tree():
		return
	_sync_spinner()


## 把转圈图标摆到"正在运行的那一行"的右端。没有运行、或那一行滚出视野就藏起来。
func _sync_spinner() -> void:
	if _spinner == null:
		return
	var idx: int = main.running_file_index()
	if idx < 0 or not main.run_active():
		_spinner.visible = false
		return
	var row: Rect2 = _list.get_item_rect(idx)
	# 滚出可视区时 get_item_rect 仍会给坐标，自己判一下
	if row.size.y <= 0.0 or row.position.y + row.size.y < 0.0 \
			or row.position.y > _list.size.y:
		_spinner.visible = false
		return
	# 暂停时定格（不转）并压暗：转与不转本身就是"在跑 / 停住了"的信号
	_spinner.spinning = main.get_state() == main.ST_RUNNING
	_spinner.dim = not _spinner.spinning
	# 选中行是反白白底，点要换成深色才看得见
	_spinner.light = _list.get_selected_items().has(idx)
	_spinner.position = Vector2(
		_list.size.x - _spinner.size.x - 10.0,
		row.position.y + (row.size.y - _spinner.size.y) * 0.5)
	_spinner.visible = true


func _build() -> void:
	add_child(Prts.pad(Prts.section("算法文件", get_theme_default_font()), 12, 10))

	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.custom_minimum_size = Vector2(0, 150)
	_list.allow_reselect = true
	_list.item_selected.connect(_on_selected)
	_list.item_activated.connect(_on_activated)
	add_child(_list)

	_spinner = RunSpinner.new()
	_spinner.visible = false
	_list.add_child(_spinner)

	# 名称输入框 + 操作按钮。用内联输入而不是弹窗，操作更快也更符合极简调性。
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "新文件名"
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.text_submitted.connect(_on_submit_name)
	row.add_child(_name_edit)

	var b_new := Prts.button("新建")
	b_new.pressed.connect(_on_new)
	row.add_child(b_new)

	var b_dup := Prts.button("复制")
	b_dup.pressed.connect(_on_duplicate)
	row.add_child(b_dup)

	var b_ren := Prts.button("重命名")
	b_ren.pressed.connect(_on_rename)
	row.add_child(b_ren)

	_btn_delete = Prts.button("删除")
	_btn_delete.pressed.connect(_on_delete)
	row.add_child(_btn_delete)

	add_child(Prts.pad(row, 12, 0))

	# 选中文件的详情 + 解锁
	_info = VBoxContainer.new()
	_info.add_theme_constant_override("separation", 5)
	add_child(Prts.panel(_info, 12, 10))

	_stat_line = Prts.label("", Prts.FS_SMALL, Prts.TEXT_HI)
	_info.add_child(_stat_line)

	_detail = Prts.dim_label("", Prts.FS_TINY)
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info.add_child(_detail)

	_btn_unlock = Prts.button("解锁", 120)
	_btn_unlock.pressed.connect(_on_unlock)
	_info.add_child(_btn_unlock)


func refresh() -> void:
	_refresh_list()


func _refresh_list() -> void:
	if _list == null:
		return
	var keep := clampi(Game.current_file, 0, maxi(0, Game.files.size() - 1))
	_list.clear()
	for i in Game.files.size():
		var f: Dictionary = Game.files[i]
		var unlocked := Game.is_unlocked(i)
		var label := String(f["name"])
		if not unlocked:
			label += "　·　未解锁 Ð%d" % int(f.get("cost", 0))
		_list.add_item(label)
		if not unlocked:
			_list.set_item_custom_fg_color(i, Prts.DIM)
	if _list.item_count > 0:
		_list.select(keep)
	_refresh_info(keep)


func _refresh_info(idx: int) -> void:
	if Game.files.is_empty():
		_stat_line.text = "没有算法文件"
		_detail.text = ""
		_btn_delete.disabled = true
		_btn_unlock.visible = false
		return

	idx = clampi(idx, 0, Game.files.size() - 1)
	var f: Dictionary = Game.files[idx]
	var code := String(f["code"])
	var bytes := code.to_utf8_buffer().size()
	var limit := Game.disk_bytes()
	var fits := bytes <= limit
	var unlocked := Game.is_unlocked(idx)
	var cost := int(f.get("cost", 0))

	if unlocked:
		_stat_line.text = "%d 字节 / %d 字节上限" % [bytes, limit]
		_stat_line.add_theme_color_override("font_color",
			Prts.TEXT_HI if fits else Prts.WHITE)
	else:
		_stat_line.text = "未解锁　·　需要 Ð%d" % cost
		_stat_line.add_theme_color_override("font_color", Prts.TEXT)

	var lines := code.split("\n").size()
	var parts := PackedStringArray()
	parts.append("%d 行" % lines)
	if unlocked:
		var best_n := int(f["best_n"])
		if best_n > 0:
			parts.append("最佳记录：%d 个元素 / %d 次读写" % [best_n, int(f["best_ops"])])
		else:
			parts.append("尚无成功记录")
		if not fits:
			parts.append("⚠ 超出硬盘容量，无法运行")
	else:
		parts.append("解锁后可以查看源码、修改，并作为运行目标")
	_detail.text = "　·　".join(parts)

	_btn_delete.disabled = Game.files.size() <= 1
	_btn_unlock.visible = not unlocked
	_btn_unlock.text = "解锁  Ð%s" % Prts.comma(cost)
	_btn_unlock.disabled = Game.coins < cost


func _on_selected(idx: int) -> void:
	if idx < 0 or idx >= Game.files.size():
		return
	if not Game.is_unlocked(idx):
		# 锁着的文件只是"看"，不切换运行目标
		_refresh_info(idx)
		return
	if idx != Game.current_file:
		main.switch_file(idx)
	_refresh_info(idx)


func _on_activated(idx: int) -> void:
	if idx < 0 or idx >= Game.files.size():
		return
	if not Game.is_unlocked(idx):
		_on_unlock()
		return
	# 双击直接跳到编辑器（标签页顺序：文件 / 阶段 / 状况 / 升级 / 编辑器）
	main._tabs.current_tab = 4


func _on_unlock() -> void:
	var idx := Game.current_file if _list != null else 0
	if _list != null and _list.get_selected_items().size() > 0:
		idx = int(_list.get_selected_items()[0])
	var r := Game.unlock_file(idx)
	main.log_line(String(r["msg"]), "ok" if bool(r["ok"]) else "error")
	if bool(r["ok"]):
		main.switch_file(idx)
	_refresh_list()


func _on_submit_name(_text: String) -> void:
	_on_new()


func _on_new() -> void:
	var name := _name_edit.text.strip_edges()
	if name.is_empty():
		name = "新算法.py"
	Game.new_file(name, "# 在这里写你的排序算法\n# 服务器会调用 sort(a)，把 a 排成升序\ndef sort(a):\n    return a\n")
	_name_edit.text = ""
	# force：Game.new_file 已经把 current_file 设成新文件了，
	# 不带 force 会被 switch_file 的"同一个文件"判断挡掉，编辑器不会重载。
	main.switch_file(Game.files.size() - 1, true)
	main.log_line("已新建 %s" % name, "sys")


func _on_duplicate() -> void:
	var idx := Game.current_file
	if idx < 0 or idx >= Game.files.size():
		return
	var name := String((Game.files[idx] as Dictionary)["name"])
	Game.duplicate_file(idx)
	main.switch_file(Game.files.size() - 1, true)
	main.log_line("已复制 %s" % name, "sys")


func _on_rename() -> void:
	var name := _name_edit.text.strip_edges()
	if name.is_empty():
		main.log_line("先在输入框里填新名字，再点重命名。", "warn")
		return
	var idx := Game.current_file
	if idx < 0 or idx >= Game.files.size():
		return
	var old := String((Game.files[idx] as Dictionary)["name"])
	Game.rename_file(idx, name)
	_name_edit.text = ""
	main.log_line("已把 %s 重命名为 %s" % [old, name], "sys")


func _on_delete() -> void:
	var idx := Game.current_file
	if idx < 0 or idx >= Game.files.size():
		return
	var name := String((Game.files[idx] as Dictionary)["name"])
	# 正在跑的那份代码已经在内存里，删掉文件不会打断它——但成绩也没地方记了
	var was_running: bool = main.running_file_name() == name
	if not Game.delete_file(idx):
		main.log_line("至少要保留一个算法文件。", "warn")
		return
	main.reload_editor()
	main.log_line("已删除 %s" % name, "sys")
	if was_running:
		main.log_line("删掉的正是正在运行的文件：这一局会继续跑完，但成绩不再记入任何文件。",
			"warn")

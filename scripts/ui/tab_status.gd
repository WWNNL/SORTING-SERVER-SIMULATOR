class_name TabStatus
extends VBoxContainer
## 运行状况：资源占用、变量监视、控制台。

var main: Control

var _rows := {}
var _bars := {}
var _bar_text := {}
var _vars_box: VBoxContainer
var _console: RichTextLabel
var _dirty := true
var _slow_pending := false
var _slow_accum := 0.0
## 主题颜色覆盖的缓存，避免每帧重复触发主题重解析
var _color_cache := {}

const KIND_COLOR := {
	"sys": "#6a6a6a", "out": "#9a9a9a", "ok": "#ffffff",
	"warn": "#c8c8c8", "error": "#ffffff",
}
const KIND_MARK := {
	"sys": "·", "out": ">", "ok": "+", "warn": "!", "error": "×",
}


func _ready() -> void:
	add_theme_constant_override("separation", 0)
	_build()
	main.run_tick.connect(_on_tick)
	main.run_state_changed.connect(func(_s): refresh())
	main.console_line.connect(_on_console)
	set_process(true)
	refresh()


func _process(delta: float) -> void:
	# 标签页不可见时什么都不做。省下的不只是几个标签的文字更新，
	# 主要是 _update_slow 里重建变量节点和控制台富文本的开销。
	# _dirty 保持为真，切回来的那一帧会自动补上。
	if not is_visible_in_tree():
		return

	if _dirty:
		_dirty = false
		_update_fast()
		_slow_pending = true

	if not _slow_pending:
		return
	# 变量表和控制台要重建节点，代价高得多。运行中每帧重建会让节点数疯涨，
	# 所以单独限流到 4 次/秒。
	_slow_accum += delta
	if _slow_accum >= 0.25:
		_slow_accum = 0.0
		_slow_pending = false
		_update_slow()


func refresh() -> void:
	_dirty = true


func _on_tick(_info: Dictionary) -> void:
	_dirty = true


func _on_console(_text: String, _kind: String) -> void:
	_dirty = true


func _build() -> void:
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(col)

	# ---- 运行指标
	col.add_child(Prts.pad(Prts.section("运行指标", get_theme_default_font()), 12, 10))
	var grid := VBoxContainer.new()
	grid.add_theme_constant_override("separation", 4)
	for key in [
		["state", "状态"], ["stage", "当前阶段"], ["n", "元素数量"],
		["steps", "执行步数"], ["cmp", "比较次数"], ["ops", "数组读写"],
		["budget", "效率预算"], ["time", "已用时间"],
		["bill", "本次电费"], ["bill_rate", "耗电成本"],
		["paid_total", "累计电费"], ["depth", "调用深度"], ["line", "当前行"],
	]:
		var row := Prts.kv(key[1], "—")
		_rows[key[0]] = row.get_child(1)
		grid.add_child(row)
	col.add_child(Prts.panel(grid, 12, 10))

	# ---- 资源条
	col.add_child(Prts.pad(Prts.section("资源占用", get_theme_default_font()), 12, 10))
	var res := VBoxContainer.new()
	res.add_theme_constant_override("separation", 9)
	for key in [["power", "电源"], ["ram", "内存"], ["disk", "硬盘"]]:
		res.add_child(_make_meter(key[0], key[1]))
	col.add_child(Prts.panel(res, 12, 10))

	# ---- 变量监视
	col.add_child(Prts.pad(Prts.section("变量监视", get_theme_default_font()), 12, 10))
	_vars_box = VBoxContainer.new()
	_vars_box.add_theme_constant_override("separation", 3)
	col.add_child(Prts.panel(_vars_box, 12, 10))

	# ---- 控制台
	col.add_child(Prts.pad(Prts.section("控制台", get_theme_default_font()), 12, 10))
	_console = RichTextLabel.new()
	_console.bbcode_enabled = true
	_console.scroll_following = true
	_console.custom_minimum_size = Vector2(0, 170)
	_console.selection_enabled = true
	_console.fit_content = false
	_console.add_theme_font_size_override("normal_font_size", Prts.FS_SMALL)
	col.add_child(Prts.panel(_console, 10, 8))


func _make_meter(key: String, caption: String) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)

	var head := HBoxContainer.new()
	var l := Prts.dim_label(caption)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(l)
	var t := Prts.label("—", Prts.FS_TINY, Prts.TEXT)
	head.add_child(t)
	box.add_child(head)

	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(0, 8)
	bar.show_percentage = false
	bar.max_value = 1
	bar.value = 0
	box.add_child(bar)

	_bars[key] = bar
	_bar_text[key] = t
	return box


# ---------------------------------------------------------------- 刷新

func _update_fast() -> void:
	var info: Dictionary = main.get_run_info()
	var vm: PyVM = main.get_vm()

	_put("state", main.state_name())
	_put("stage", "%s · %s" % [
		String(Game.stage_info().get("name", "")), String(Game.stage_info().get("algo", ""))])
	_put("n", "%d 个" % int(info["n"]))
	_put("steps", Prts.comma(int(info["steps"])))
	_put("cmp", Prts.comma(int(info["comparisons"])))
	_put("ops", Prts.comma(int(info["ops"])))
	_put("budget", "%d 次读写" % int(info["budget"]))
	_put("time", "%.1f s" % float(info["elapsed"]))
	_put("bill", "Ð%.2f" % float(info["bill"]))
	_put("bill_rate", "Ð%.2f / 秒" % (float(Game.total_draw()) * ServerSpec.POWER_RATE))
	_put("paid_total", "Ð%s" % Prts.comma(int(Game.stats.get("power_paid", 0))))
	_put("depth", "—" if vm == null else str(vm.call_depth()))
	_put("line", "—" if vm == null else str(vm.current_line()))

	_update_power()
	_update_ram(info)
	_update_disk()


func _update_slow() -> void:
	_update_vars(main.get_vm())
	_update_console()


## 注意：不能叫 _set —— 那是 Object 的虚方法，签名会对不上。
func _put(key: String, text: String) -> void:
	var l: Label = _rows.get(key)
	if l != null:
		l.text = text


func _update_power() -> void:
	var draw := Game.total_draw()
	var psu := Game.psu_watts()
	var bar: ProgressBar = _bars["power"]
	var t: Label = _bar_text["power"]
	bar.max_value = maxi(1, psu)
	bar.value = mini(draw, psu)
	t.text = "%d / %d W" % [draw, psu]
	Prts.set_color_cached(t, "power", Prts.TEXT if draw <= psu else Prts.WHITE, _color_cache)


func _update_ram(info: Dictionary) -> void:
	var used := int(info["ram"])
	var total := Game.ram_bytes()
	var bar: ProgressBar = _bars["ram"]
	var t: Label = _bar_text["ram"]
	bar.max_value = maxi(1, total)
	bar.value = mini(used, total)
	t.text = "%d / %d B" % [used, total]
	Prts.set_color_cached(t, "ram", Prts.TEXT if used <= total else Prts.WHITE, _color_cache)


func _update_disk() -> void:
	var used: int = main.current_code().to_utf8_buffer().size()
	var total := Game.disk_bytes()
	var bar: ProgressBar = _bars["disk"]
	var t: Label = _bar_text["disk"]
	bar.max_value = maxi(1, total)
	bar.value = mini(used, total)
	t.text = "%d / %d B" % [used, total]
	Prts.set_color_cached(t, "disk", Prts.TEXT if used <= total else Prts.WHITE, _color_cache)


func _update_vars(vm: PyVM) -> void:
	for c in _vars_box.get_children():
		c.queue_free()

	if vm == null:
		_vars_box.add_child(Prts.dim_label("尚未运行"))
		return

	var live := vm.live_vars()
	if live.is_empty():
		_vars_box.add_child(Prts.dim_label("当前没有活动变量"))
		return

	var keys := live.keys()
	keys.sort()
	var shown := 0
	for k in keys:
		if shown >= 14:
			_vars_box.add_child(Prts.dim_label("… 还有 %d 个变量" % (keys.size() - shown)))
			break
		var row := Prts.kv(String(k), _brief(live[k]))
		_vars_box.add_child(row)
		shown += 1


static func _brief(v: Variant) -> String:
	var s := PyObjects.repr(v)
	if s.length() > 42:
		s = s.substr(0, 39) + "…"
	return s


func _update_console() -> void:
	if _console == null:
		return
	var lines: Array = main.get_console()
	var sb := PackedStringArray()
	for e in lines:
		var kind := String(e["kind"])
		var color := String(KIND_COLOR.get(kind, "#9a9a9a"))
		var mark := String(KIND_MARK.get(kind, "·"))
		sb.append("[color=%s]%s %s[/color]" % [color, mark, _escape(String(e["text"]))])
	_console.text = "\n".join(sb)


static func _escape(s: String) -> String:
	return s.replace("[", "［").replace("]", "］")

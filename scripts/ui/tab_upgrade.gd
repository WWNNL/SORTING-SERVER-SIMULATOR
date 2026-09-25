class_name TabUpgrade
extends VBoxContainer
## 升级配置：四个部件各自一张卡。
##
## 关键体验：买之前就能看到"买完之后整机功耗变成多少、会不会超电源"，
## 否则玩家只会觉得莫名其妙停机。

var main: Control

var _power_bar: ProgressBar
var _power_text: Label
var _power_hint: Label
var _cards := {}
## 主题颜色覆盖的缓存，避免拖滑条时反复触发主题重解析
var _color_cache := {}


func _ready() -> void:
	add_theme_constant_override("separation", 10)
	_build()
	Game.tiers_changed.connect(refresh)
	Game.speed_changed.connect(_refresh_speed)
	Game.coins_changed.connect(func(_c): refresh())
	refresh()


func _build() -> void:
	add_child(Prts.pad(Prts.section("整机功耗", get_theme_default_font()), 12, 10))

	var head := VBoxContainer.new()
	head.add_theme_constant_override("separation", 5)
	_power_text = Prts.label("", Prts.FS_BODY, Prts.TEXT_HI)
	head.add_child(_power_text)

	_power_bar = ProgressBar.new()
	_power_bar.custom_minimum_size = Vector2(0, 10)
	_power_bar.show_percentage = false
	head.add_child(_power_bar)

	_power_hint = Prts.dim_label("", Prts.FS_TINY)
	_power_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	head.add_child(_power_hint)

	add_child(Prts.panel(head, 12, 10))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(col)

	for part in ServerSpec.PARTS:
		var card := _make_card(part)
		_cards[part] = card
		col.add_child(card["root"])


func _make_card(part: String) -> Dictionary:
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", Prts.flat(Prts.RAISED, Prts.LINE, 1))

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 7)

	var title_row := HBoxContainer.new()
	var name_l := Prts.label(_part_name(part), Prts.FS_SMALL, Prts.TEXT_HI)
	name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(name_l)
	var tier_l := Prts.dim_label("", Prts.FS_TINY)
	title_row.add_child(tier_l)
	col.add_child(title_row)

	col.add_child(Prts.hline())

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 10)

	var cur_box := VBoxContainer.new()
	cur_box.add_theme_constant_override("separation", 2)
	cur_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cur_box.add_child(Prts.dim_label("当前"))
	var cur_v := Prts.label("", Prts.FS_SMALL, Prts.TEXT)
	cur_box.add_child(cur_v)
	var cur_w := Prts.dim_label("", Prts.FS_TINY)
	cur_box.add_child(cur_w)
	body.add_child(cur_box)

	var arrow := Prts.dim_label("→", Prts.FS_SMALL)
	arrow.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	body.add_child(arrow)

	var nxt_box := VBoxContainer.new()
	nxt_box.add_theme_constant_override("separation", 2)
	nxt_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nxt_box.add_child(Prts.dim_label("升级后"))
	var nxt_v := Prts.label("", Prts.FS_SMALL, Prts.WHITE)
	nxt_box.add_child(nxt_v)
	var nxt_w := Prts.dim_label("", Prts.FS_TINY)
	nxt_box.add_child(nxt_w)
	body.add_child(nxt_box)

	col.add_child(body)

	var card := {
		"root": pc, "tier": tier_l, "cur_v": cur_v, "cur_w": cur_w,
		"nxt_v": nxt_v, "nxt_w": nxt_w, "btn": null,
		"speed_box": null, "speed_slider": null, "speed_value": null, "speed_hint": null,
	}

	# 处理器多一条运行速度滑条：硬件只决定上限，滑条负责当下跑多快。
	if part == "cpu":
		var block := _make_speed_block()
		for k in block:
			card[k] = block[k]
		col.add_child(block["speed_box"])

	var btn := Prts.button("升级", 96)
	btn.pressed.connect(_on_buy.bind(part))
	col.add_child(btn)
	card["btn"] = btn

	pc.add_child(Prts.pad(col, 12, 10))
	return card


## 运行速度滑条。只允许往下调（上限是硬件额定速度），
## 所以它是"看得更清楚"的工具，不是变快的捷径。
func _make_speed_block() -> Dictionary:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)

	box.add_child(Prts.hline())

	var head := HBoxContainer.new()
	var cap := Prts.dim_label("运行速度")
	cap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(cap)
	var value := Prts.label("", Prts.FS_SMALL, Prts.TEXT_HI)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	head.add_child(value)
	box.add_child(head)

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = SPEED_STEP
	slider.value = 1.0
	slider.custom_minimum_size = Vector2(0, 14)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	# 和按钮一致：键盘焦点框在这套直角界面里只会多出一圈脏线
	slider.focus_mode = Control.FOCUS_NONE
	slider.value_changed.connect(_on_speed_changed)
	# 拖动过程中每帧写盘不值得，松手再存
	slider.drag_ended.connect(_on_speed_drag_ended)
	# 滚轮与 Shift+拖动这两个微调通道要自己接鼠标（引擎只认普通拖动）
	slider.gui_input.connect(_on_speed_input)
	box.add_child(slider)

	var hint := Prts.dim_label("", Prts.FS_TINY)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(hint)

	return {"speed_box": box, "speed_slider": slider, "speed_value": value, "speed_hint": hint}


# ---------------------------------------------------------------- 速度滑条

## 位置步长。位置空间一格 0.0002，在 100% 处折算约 0.09 个百分点，
## 越往低端越细（对数映射的本来目的）——0.1% 的颗粒度在整条上都够用。
const SPEED_STEP := 0.0002
## Shift 按住时指针每动 1px 折算的位置增量 = 常规的 1/8：
## 常规拖动在右端 1px 约 0.7pp（像素分辨率摆在那），Shift 后约 0.09pp，
## 正是"0.1% 微调"的颗粒度。除以像素分辨率本身，粗细不随滑条宽度变。
const FINE_DIV := 8.0

## 拖动状态：按下即接管（点哪儿跳哪儿、拖着 1:1 跟手），
## 拖动中按住 Shift 变 1/8 细调、松开 Shift 回到 1:1，松手结束并存盘。
var _dragging := false
var _drag_anchor_px := 0.0
var _drag_anchor_val := 0.0

## 微调通道（gui_input 信号先于控件自身的处理，要抢的话 accept_event）：
##   · 滚轮：一格 = SPEED_STEP，悬停即用，不用点进去
##   · 左键：接管整个拖动（引擎的 drag_ended 不再触发，存盘在松手里补）
func _on_speed_input(event: InputEvent) -> void:
	var card: Dictionary = _cards.get("cpu", {})
	var slider: HSlider = card.get("speed_slider") as HSlider
	if slider == null:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		# 滚轮在 Godot 4 里也是 InputEventMouseButton，只是按键下标是轮子
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			var dir := 1.0 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
			slider.value = clampf(slider.value + dir * SPEED_STEP, 0.0, 1.0)
			slider.accept_event()
			return
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_dragging = true
			_drag_anchor_px = mb.position.x
			# 点哪儿跳哪儿，和引擎原本的按压行为一致
			slider.value = clampf(mb.position.x / maxf(slider.size.x, 1.0), 0.0, 1.0)
			_drag_anchor_val = slider.value
			slider.accept_event()
		else:
			if _dragging:
				_dragging = false
				# 拖动不经过引擎的 drag_ended，这里补上"松手才存盘"
				_on_speed_drag_ended(true)
			slider.accept_event()
		return
	if event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		var per_px := 1.0 / maxf(slider.size.x, 1.0)
		if mm.shift_pressed:
			per_px /= FINE_DIV
		slider.value = clampf(
			_drag_anchor_val + (mm.position.x - _drag_anchor_px) * per_px,
			0.0, 1.0)
		slider.accept_event()


## 滑条位置（0~1）↔ 速度比例。用对数映射：额定 130000 步/秒时，
## 线性滑条最左边的 1% 就要跨越 1300 步，低端根本没法微调。
## 下限是"1 步/秒"对应的比例（Game.min_cpu_ratio），不是固定 1%：
## 升满后滑条底部就是 1 步/秒，不是 1300。
static func ratio_to_pos(r: float) -> float:
	return log(r / Game.min_cpu_ratio()) / log(1.0 / Game.min_cpu_ratio())


static func pos_to_ratio(p: float) -> float:
	return Game.min_cpu_ratio() * pow(1.0 / Game.min_cpu_ratio(), p)


func _on_speed_changed(pos: float) -> void:
	# 值变了 Game 会发 speed_changed，界面在那里统一刷新，这里不重复刷。
	Game.set_cpu_ratio(pos_to_ratio(pos))


func _on_speed_drag_ended(_changed: bool) -> void:
	Game.save_game()


func _refresh_speed() -> void:
	var card: Dictionary = _cards.get("cpu", {})
	if card.is_empty() or card.get("speed_slider") == null:
		return
	var slider: HSlider = card["speed_slider"]
	var value: Label = card["speed_value"]
	# 用 no_signal 回写位置：否则 refresh 会反过来触发 value_changed，
	# 把浮点误差写进 Game.cpu_ratio。
	slider.set_value_no_signal(ratio_to_pos(Game.cpu_ratio))

	var now := Game.cpu_speed()
	var rated := Game.cpu_rate()
	value.text = "%s 步 / 秒" % Prts.comma(now)
	Prts.set_color_cached(value, "speed", Prts.WHITE if now >= rated else Prts.TEXT_HI,
		_color_cache)
	# 一位小数才看得见 0.1% 的颗粒度；末尾教一下微调手势。
	# 最低档是 1 步/秒，报百分比反而看不懂（0.0%），这里报步/秒。
	(card["speed_hint"] as Label).text = \
		"额定 %s 步 / 秒，当前 %s 步 / 秒。调慢只是看得更清楚：同一份工作耗时变长，总电费反而更高。拖动时按住 Shift 可 0.1%% 微调。" % [
			Prts.comma(rated), Prts.comma(now)]


func refresh() -> void:
	if _cards.is_empty():
		return

	var draw := Game.total_draw()
	var psu := Game.psu_watts()
	_power_text.text = "整机功耗 %d W　/　电源容量 %d W" % [draw, psu]
	_power_bar.max_value = maxi(1, psu)
	_power_bar.value = mini(draw, psu)

	var head := psu - draw
	if head < 0:
		_power_hint.text = "超出 %d W —— 服务器无法开机。升级电源，或把某个部件降回去。" % (-head)
		_power_hint.add_theme_color_override("font_color", Prts.WHITE)
	else:
		_power_hint.text = "剩余余量 %d W。注意：升级任何部件都会增加功耗。" % head
		_power_hint.add_theme_color_override("font_color", Prts.DIM)

	for part in ServerSpec.PARTS:
		_refresh_card(part)
	_refresh_speed()


func _refresh_card(part: String) -> void:
	var card: Dictionary = _cards[part]
	var cur := Game.tier_of(part)
	var cur_spec := ServerSpec.spec(part, cur)
	var is_max := ServerSpec.is_max(part, cur)

	(card["tier"] as Label).text = String(cur_spec["name"])
	(card["cur_v"] as Label).text = _stat_text(part, cur_spec)
	(card["cur_w"] as Label).text = _watt_text(part, cur_spec)

	var btn: Button = card["btn"]
	if is_max:
		(card["nxt_v"] as Label).text = "已到顶"
		(card["nxt_v"] as Label).add_theme_color_override("font_color", Prts.DIM)
		(card["nxt_w"] as Label).text = ""
		btn.text = "已是最高规格"
		btn.disabled = true
		return

	var nxt_spec := ServerSpec.spec(part, cur + 1)
	var cost := ServerSpec.next_cost(part, cur)
	(card["nxt_v"] as Label).text = _stat_text(part, nxt_spec)
	(card["nxt_v"] as Label).add_theme_color_override("font_color", Prts.WHITE)
	(card["nxt_w"] as Label).text = _watt_text(part, nxt_spec)

	btn.text = "升级  Ð%s" % Prts.comma(cost)
	btn.disabled = Game.coins < cost

	# 这一级买下去会不会把电源撑爆？提前在卡片上标出来。
	if part != "psu":
		var new_draw := draw_with(part, cur + 1)
		if new_draw > Game.psu_watts():
			(card["nxt_w"] as Label).text += "　⚠ 将超出电源"
			(card["nxt_w"] as Label).add_theme_color_override("font_color", Prts.TEXT_HI)


func draw_with(part: String, tier: int) -> int:
	var cpu := Game.tier_of("cpu")
	var ram := Game.tier_of("ram")
	var disk := Game.tier_of("disk")
	match part:
		"cpu": cpu = tier
		"ram": ram = tier
		"disk": disk = tier
	return ServerSpec.total_draw(cpu, ram, disk)


func _on_buy(part: String) -> void:
	var r := Game.buy(part)
	main.log_line(String(r["msg"]), "ok" if bool(r["ok"]) else "error")
	refresh()


static func _part_name(part: String) -> String:
	match part:
		"cpu": return "处理器"
		"ram": return "内存"
		"disk": return "硬盘"
		"psu": return "电源"
	return part


static func _stat_text(part: String, spec: Dictionary) -> String:
	match part:
		"cpu": return "%d 步 / 秒" % int(spec["speed"])
		"ram": return "%d 字节" % int(spec["bytes"])
		"disk": return "%d 字节" % int(spec["bytes"])
		"psu": return "%d W" % int(spec["watts"])
	return ""


static func _watt_text(part: String, spec: Dictionary) -> String:
	if part == "psu":
		return "供电上限"
	return "耗电 %d W" % int(spec["watts"])

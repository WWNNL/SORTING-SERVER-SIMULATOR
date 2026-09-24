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


func _ready() -> void:
	add_theme_constant_override("separation", 10)
	_build()
	Game.tiers_changed.connect(refresh)
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

	var btn := Prts.button("升级", 96)
	btn.pressed.connect(_on_buy.bind(part))
	col.add_child(btn)

	pc.add_child(Prts.pad(col, 12, 10))
	return {
		"root": pc, "tier": tier_l, "cur_v": cur_v, "cur_w": cur_w,
		"nxt_v": nxt_v, "nxt_w": nxt_w, "btn": btn,
	}


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

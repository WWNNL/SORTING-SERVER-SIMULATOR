class_name PrtsFrame
extends Control
## 面板四角的 L 形角标 —— PRTS 界面最有辨识度的装饰。
##
## 用法：add_child 到任意 Control 上，锚点铺满，它会自己忽略鼠标事件。

var bracket_len := 10
var thickness := 2
var bracket_color := Prts.WHITE
var border_color := Prts.LINE
var draw_border := true
var draw_hatch := false
var hatch_color := Color(1, 1, 1, 0.03)


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	resized.connect(queue_redraw)


func _draw() -> void:
	var w := size.x
	var h := size.y
	if w < 4.0 or h < 4.0:
		return

	if draw_border:
		draw_rect(Rect2(0, 0, w, h), border_color, false, 1.0)

	if draw_hatch:
		# 45 度斜线填充，用来暗示"这里是空的 / 未启用"
		var step := 8
		var span := int(w + h)
		var k := 0
		while k < span:
			draw_line(Vector2(k, 0), Vector2(k - h, h), hatch_color, 1.0)
			k += step

	if bracket_len <= 0:
		return

	var L := float(bracket_len)
	var T := float(thickness)
	var x1 := w - L
	var y1 := h - L

	# 左上
	draw_rect(Rect2(0, 0, L, T), bracket_color)
	draw_rect(Rect2(0, 0, T, L), bracket_color)
	# 右上
	draw_rect(Rect2(x1, 0, L, T), bracket_color)
	draw_rect(Rect2(w - T, 0, T, L), bracket_color)
	# 左下
	draw_rect(Rect2(0, h - T, L, T), bracket_color)
	draw_rect(Rect2(0, y1, T, L), bracket_color)
	# 右下
	draw_rect(Rect2(x1, h - T, L, T), bracket_color)
	draw_rect(Rect2(w - T, y1, T, L), bracket_color)


## 便捷挂载
static func attach(target: Control, blen := 10, thick := 2,
		color := Prts.WHITE, border := true) -> PrtsFrame:
	var f := PrtsFrame.new()
	f.bracket_len = blen
	f.thickness = thick
	f.bracket_color = color
	f.draw_border = border
	target.add_child(f)
	return f

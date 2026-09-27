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

	draw_brackets(self, Rect2(0, 0, w, h), float(bracket_len), float(thickness), bracket_color)


## 四角 L 形角标。每个角是"一条贴边的横臂 + 一条贴边的竖臂"——
## 横臂的 y 必须用**边线减厚度**（下边就是 bottom - thick），不能写成
## "下边 - 臂长"：那样下面两个角的横臂会浮到角上方 20 多像素，和竖臂接不上，
## 看起来就是"下面的角画错了"（开机动画里手抄过一遍，就抄错在这里）。
##
## 做成静态函数是为了给"不是 PrtsFrame 的绘制方"用：开机动画和登入界面的
## 角标位置每帧都在动（会拍入、会跟着色块走），挂不了控件，只能自己在 _draw
## 里画。传 CanvasItem 进来而不是在类里画，就是为这个。
static func draw_brackets(ci: CanvasItem, r: Rect2, blen: float, thick: float,
		color: Color) -> void:
	var left := r.position.x
	var top := r.position.y
	var right := r.position.x + r.size.x
	var bottom := r.position.y + r.size.y
	for seg in [
		Rect2(left, top, blen, thick),
		Rect2(left, top, thick, blen),
		Rect2(right - blen, top, blen, thick),
		Rect2(right - thick, top, thick, blen),
		Rect2(left, bottom - thick, blen, thick),
		Rect2(left, bottom - blen, thick, blen),
		Rect2(right - blen, bottom - thick, blen, thick),
		Rect2(right - thick, bottom - blen, thick, blen),
	]:
		ci.draw_rect(seg, color)


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

class_name RunSpinner
extends Control
## "这个文件正在跑"的小指示器：一个由点组成的口字形，亮点绕着它转圈。
##
## 为什么是点阵方框而不是常见的圆弧转圈：这套界面全是直角、1px 细线和关掉的抗锯齿，
## 圆弧在这里既糊又不搭。点落在方框上，天然对齐像素网格，也不需要任何贴图。
##
## 它只管自己转，放在哪儿、什么时候显示由调用方决定。

## 方框每条边上的点数（含两端角点）。3 → 每边 3 点，四角不重复，共 8 点。
const DOTS_PER_SIDE := 3
## 转一圈的秒数
const PERIOD := 1.6
## 亮点后面拖几个点的尾巴。0 就只剩一个亮点在跳，看着像卡顿。
const TAIL := 4.0
const DOT := 2          ## 一个点的边长（像素）
const INSET := 1.0      ## 离控件边缘留一点

## 是否在转。暂停时置 false：定格住也是一种状态表达。
var spinning := true
## 压暗显示（暂停时用），比换一套颜色省事，也不会跳出黑白灰
var dim := false
## 所在行的底色是不是浅色。列表选中行是**反白**的白底，
## 白点画上去等于没画，所以浅底要整体换成深色点。
var light := false

var _phase := 0.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(14, 14)
	size = custom_minimum_size


func _ready() -> void:
	set_process(true)


func _process(delta: float) -> void:
	if not spinning or not is_visible_in_tree():
		return
	_phase = fmod(_phase + delta / PERIOD, 1.0)
	queue_redraw()


func dot_count() -> int:
	return DOTS_PER_SIDE * 4 - 4


## 第 i 个点在方框上的位置（顺时针，从左上角开始）。返回的是像素坐标。
func _dot_pos(i: int, n: int) -> Vector2:
	var per := DOTS_PER_SIDE - 1               ## 每边的间隔数
	var side := i / per
	var step := i % per
	var gx := 0
	var gy := 0
	match side:
		0:  # 上边：左 → 右
			gx = step
			gy = 0
		1:  # 右边：上 → 下
			gx = per
			gy = step
		2:  # 下边：右 → 左
			gx = per - step
			gy = per
		_:  # 左边：下 → 上
			gx = 0
			gy = per - step
	var span := maxf(1.0, minf(size.x, size.y) - INSET * 2.0 - float(DOT))
	var cell := span / float(per)
	return Vector2(INSET + float(gx) * cell, INSET + float(gy) * cell)


func _draw() -> void:
	var n := dot_count()
	if n <= 0:
		return
	var weak := Prts.TEXT if light else Prts.DIM
	var peak := Prts.BLACK if light else Prts.WHITE
	# 亮点的位置跟着相位绕圈，后面的点按"落后几格"依次变暗
	var head := int(floor(_phase * float(n))) % n
	for i in n:
		var age := (head - i + n) % n
		var w := clampf(1.0 - float(age) / TAIL, 0.0, 1.0)
		var c := weak.lerp(peak, w)
		if dim:
			c = c.darkened(0.45) if not light else c.lightened(0.35)
		draw_rect(Rect2(_dot_pos(i, n), Vector2(DOT, DOT)), c)
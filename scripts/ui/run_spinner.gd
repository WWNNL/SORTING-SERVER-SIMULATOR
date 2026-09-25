class_name RunSpinner
extends Control
## "这个文件正在跑"的小指示器：一个由点组成的口字形，亮点绕着它转圈。
##
## 为什么是点阵方框而不是常见的圆弧转圈：这套界面全是直角、1px 细线和关掉的抗锯齿，
## 圆弧在这里既糊又不搭。点落在方框上，天然对齐像素网格，也不需要任何贴图。
##
## 亮点按**周长上的连续位置**算亮度，而不是"第几个点整格点亮"：
## 后者在 8 个点上每 200ms 才跳一格，看着是一顿一顿的步进；
## 前者逐帧连续变化，读起来才是一道平滑流动的亮带。
##
## 它只管自己转，放在哪儿、什么时候显示由调用方决定。

## 方框每条边上的点数（含两端角点）。4 → 四角 + 每边两个内点，共 12 点。
## 点越多，亮带被采样得越细，流动越顺；太少就会重新看出步进感。
const DOTS_PER_SIDE := 4
## 转一圈的秒数
const PERIOD := 1.6
## 亮带尾巴的长度，占整个周长的比例。0 就只剩一个亮点在跳，看着像卡顿。
const TAIL := 0.32
## 头**前方**的渐亮长度，同样按周长比例。
## 没有它就会出现"点被头扫到时从暗直接跳到最亮"的爆闪——实测每帧跳变量高达 1.0，
## 视觉上就是一顿一顿地闪。加上这段渐亮，亮度曲线在头的位置左右连续。
const LEAD := 0.14
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
	custom_minimum_size = Vector2(16, 16)
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


## 第 i 个点当前的亮度（0~1）。绘制用它，测试也用它看连续性，不依赖截图。
##
## 点沿周长均匀分布，所以第 i 个点的周长位置就是 i / count。
## age = 头到它的周长距离：0 = 正被头罩着，1 = 头马上要绕到它。
## 头后面按 TAIL 衰减、头前面按 LEAD 渐亮，两头在 age = 0 / 1 处都收敛到 1，
## 所以整条曲线连续——不会出现"被扫到时突然点亮"的爆闪。
func dot_brightness(i: int, n := 0) -> float:
	var count := n if n > 0 else dot_count()
	if count <= 0:
		return 0.0
	var dot_t := float(i) / float(count)
	var age := fposmod(_phase - dot_t, 1.0)
	if age <= TAIL:
		return clampf(1.0 - age / TAIL, 0.0, 1.0)
	return clampf(1.0 - (1.0 - age) / LEAD, 0.0, 1.0)


## 全部点的亮度，供外部观察/测试。
func dot_brightness_all() -> Array:
	var n := dot_count()
	var out: Array = []
	for i in n:
		out.append(dot_brightness(i, n))
	return out


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
	for i in n:
		var w := dot_brightness(i, n)
		var c := weak.lerp(peak, w)
		if dim:
			c = c.darkened(0.45) if not light else c.lightened(0.35)
		draw_rect(Rect2(_dot_pos(i, n), Vector2(DOT, DOT)), c)
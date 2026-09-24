class_name VizView
extends Control
## 左侧排序可视化：一根柱子一个元素。
##
## 表达三件事：
##   · 选中 —— 这一瞬间被读取的元素，白框圈出 + 顶部小三角
##   · 移动 —— 元素飞向它的新位置，画成一道抛物线，落点用基线上的短横标出
##   · 归位 —— 已经落在最终位置上的元素，用亮灰区分
##
## 性能上最关键的一点：**动画时长必须跟着事件频率走**。
## 2600 步/秒时冒泡排序每秒产生约 180 次移动，如果固定用 0.2 秒时长，
## 稳态会有 36 个元素同时在飞，缓冲区长期满载、动画集合每帧剧烈变化，
## 画面就会"抖"。这里改成按事件速率反推时长，把在飞数量稳定在二十来个。

const PAD_X := 10.0
const PAD_TOP := 10.0
const LABEL_PAD_TOP := 26.0  ## 标数值时顶部要多留一行
const AXIS_H := 20.0

## 同帧最多标出几个落点。全标出来的话会有几十条方框叠在一起，
## 看着就像一堆没刷新掉的细线。
const MAX_TARGETS := 6
## 元素飞行时长。刻意用固定值，不做"按事件速率反推时长"那一套——
## 那样在高速时会把时长压到几十毫秒，元素一闪而过，看起来只是抖。
## 现在是控制**入场数量**：少数元素完整飞完全程，整体呈现为平滑的流动。
const MOVE_DURATION := 0.17
## 同时在飞的元素上限
const MAX_INFLIGHT := 20
## 同帧最多点亮多少个下标。高速运行时每秒上千次读写，全点亮会糊成一片白，
## 反而什么都看不出来。
const MAX_HOT := 26

var values: Array = []
var sorted_target: Array = []
var caption := ""

var _hot: Dictionary = {}      ## 下标 -> 高亮强度
var _moves: Array = []         ## 飞行中的元素 {from, to, v, t}
var _selected := -1            ## 当前选中的元素（最近被读取的下标）
var _selected_ttl := 0.0
var _max_value := 1
var _settled_count := 0

## 诊断用：本帧收到的移动事件数、被丢掉的数量
var _moves_seen := 0
var _moves_dropped := 0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true


func _ready() -> void:
	set_process(true)


func set_array(vals: Array, target: Array) -> void:
	values = vals
	sorted_target = target
	_hot.clear()
	_moves.clear()
	_selected = -1
	_max_value = 1
	for v in vals:
		_max_value = maxi(_max_value, int(v))
	_recount_settled()
	queue_redraw()


func clear() -> void:
	values = []
	sorted_target = []
	_hot.clear()
	_moves.clear()
	_selected = -1
	_settled_count = 0
	queue_redraw()


func set_caption(text: String) -> void:
	caption = text
	queue_redraw()


func settled_count() -> int:
	return _settled_count


func moving_count() -> int:
	return _moves.size()


## 当前数组里的最大值。音效按它把元素值归一化成音高。
func max_value() -> int:
	return _max_value


## 当前选中的元素下标，-1 表示没有
func selected_index() -> int:
	return _selected


func move_duration() -> float:
	return MOVE_DURATION


## 本帧收到的移动事件数 / 被丢弃的数量，供性能观察用
func move_stats() -> Dictionary:
	return {"seen": _moves_seen, "dropped": _moves_dropped, "inflight": _moves.size()}


## 消费一批可视化事件
func apply_events(events: Array) -> void:
	if events.is_empty():
		return

	# 先把这一批归类，再统一限流。直接边遍历边写状态的话，
	# 高速运行时会把成百上千个下标一次性点成白色。
	var move_batch: Array = []
	var hot_batch: Array = []
	var seen := {}

	for e in events:
		match String(e.get("t", "")):
			"read":
				var i := int(e["i"])
				_selected = i
				_selected_ttl = 0.40
				if not seen.has(i):
					seen[i] = true
					hot_batch.append(i)
			"cmp":
				for idx in (e["idx"] as Array):
					var j := int(idx)
					if not seen.has(j):
						seen[j] = true
						hot_batch.append(j)
			"write":
				var w := int(e["i"])
				if not seen.has(w):
					seen[w] = true
					hot_batch.append(w)
			"move":
				move_batch.append(e)
				var to_i := int(e["to"])
				if not seen.has(to_i):
					seen[to_i] = true
					hot_batch.append(to_i)

	_moves_seen = move_batch.size()
	_moves_dropped = 0
	_ingest_moves(move_batch)
	_ingest_hot(hot_batch)
	_recount_settled()


## 动画限流：控制入场数量，超出的均匀抽样丢掉。
## 被丢掉的元素不会有动画，但柱子本身早就画在目标格上了，所以不会"回弹"。
func _ingest_moves(batch: Array) -> void:
	var n := batch.size()
	if n == 0:
		return
	var room := MAX_INFLIGHT - _moves.size()
	if room <= 0:
		_moves_dropped = n
		return
	if n <= room:
		for e in batch:
			_push_move(int(e["from"]), int(e["to"]), e["v"])
		return

	# 均匀抽样，而不是取前 room 个——取开头会让动画明显偏向数组左半边
	var step := float(n) / float(room)
	var k := 0.0
	for _t in room:
		var e: Dictionary = batch[int(k)]
		_push_move(int(e["from"]), int(e["to"]), e["v"])
		k += step
	_moves_dropped = n - room


## 高亮限流：均匀抽样 + 按密度压低强度。
## 密集活动表现成"柔和的辉光"，而不是"整块全白"。
func _ingest_hot(batch: Array) -> void:
	var n := batch.size()
	if n == 0:
		return
	var take := mini(n, MAX_HOT)
	var intensity := clampf(sqrt(float(take) / float(n)), 0.30, 1.0)
	if take == n:
		for i in batch:
			_hot[int(i)] = intensity
		return
	var step := float(n) / float(take)
	var k := 0.0
	for _t in take:
		_hot[int(batch[int(k)])] = intensity
		k += step


func _push_move(from_i: int, to_i: int, v: Variant) -> void:
	if from_i == to_i or from_i < 0 or to_i < 0:
		return
	for m in _moves:
		if int(m["from"]) == from_i and int(m["to"]) == to_i:
			m["t"] = 0.0
			return
	if _moves.size() >= MAX_INFLIGHT:
		_moves.pop_front()
	_moves.append({"from": from_i, "to": to_i, "v": v, "t": 0.0})


func _process(delta: float) -> void:
	var dirty := false

	if not _moves.is_empty():
		var keep: Array = []
		for m in _moves:
			var t := float(m["t"]) + delta
			if t < MOVE_DURATION:
				m["t"] = t
				keep.append(m)
		_moves = keep
		dirty = true

	if _selected >= 0:
		_selected_ttl -= delta
		if _selected_ttl <= 0.0:
			_selected = -1
		dirty = true

	if not _hot.is_empty():
		var next := {}
		for k in _hot:
			var h := float(_hot[k]) * 0.74
			if h > 0.07:
				next[k] = h
		_hot = next
		_trim_hot()
		dirty = true

	if dirty:
		queue_redraw()


## 高亮集合的总量上限。
##
## 单帧限流只约束"这一帧新增多少"，但 _hot 是跨帧累积衰减的：
## 每帧新增 26 个、活 5 帧，稳态就会有 130 个下标同时亮着——
## 256 个元素里一半在发光，看着就是一片糊。这里再兜一道总量上限，
## 只保留最亮的（也就是最新的），让辉光聚焦在算法当前活动的位置。
func _trim_hot() -> void:
	var limit := MAX_HOT * 3
	if _hot.size() <= limit:
		return
	var keys := _hot.keys()
	keys.sort_custom(func(a, b): return float(_hot[a]) > float(_hot[b]))
	var keep := {}
	for i in limit:
		keep[keys[i]] = _hot[keys[i]]
	_hot = keep


func _recount_settled() -> void:
	_settled_count = 0
	if sorted_target.size() != values.size():
		return
	for i in values.size():
		if int(values[i]) == int(sorted_target[i]):
			_settled_count += 1


# ---------------------------------------------------------------- 绘制

func _draw() -> void:
	var w := size.x
	var h := size.y
	draw_rect(Rect2(0, 0, w, h), Prts.BG)

	var n := values.size()
	if n <= 0:
		_draw_placeholder(w, h)
		return

	var base_y := h - AXIS_H
	var span := w - PAD_X * 2.0
	if span < 8.0:
		return

	var label_mode := n <= 20 and (span / float(n)) >= 16.0
	var pad_top := LABEL_PAD_TOP if label_mode else PAD_TOP
	var usable := base_y - pad_top
	if usable < 4.0:
		return

	var font := get_theme_default_font()
	var gap := 1 if span / float(n) >= 3.0 else 0

	_draw_bars(n, span, gap, base_y, usable, font, label_mode)
	_draw_move_targets(n, span, gap, base_y)
	_draw_selection(n, span, gap, base_y, pad_top)
	_draw_flying(n, span, gap, base_y, usable)
	_draw_axis(w, base_y, n, span)


func _bar_width(i: int, n: int, span: float, gap: int) -> float:
	var x0 := PAD_X + span * float(i) / float(n)
	var x1 := PAD_X + span * float(i + 1) / float(n)
	return maxf(1.0, x1 - x0 - gap)


func _bar_x(i: int, n: int, span: float) -> float:
	return PAD_X + span * float(i) / float(n)


func _bar_height(v: float, usable: float) -> int:
	return maxi(1, int(round((v / float(maxi(1, _max_value))) * usable)))


func _draw_bars(n: int, span: float, gap: int, base_y: float,
		usable: float, font: Font, label_mode: bool) -> void:
	for i in n:
		var x0 := int(_bar_x(i, n, span))
		var bw := int(_bar_width(i, n, span, gap))
		var bh := _bar_height(float(values[i]), usable)
		var y := int(base_y) - bh

		var c := Prts.BAR
		var heat := float(_hot.get(i, 0.0))
		if i == _selected:
			# 选中的元素由白框标记，这里刻意不让它跟着 _hot 变白。
			# read 事件同时把下标塞进了 hot_batch，单次事件的强度算出来是 1.0，
			# 柱子会被涂成纯白 #ffffff——而白框也是 #ffffff，框就整个消失了：
			# 右边缘落在柱子内部、上下边缘落在柱子根部，全白对白，只剩左边
			# 那一条线露在黑底上，看起来只是柱子多了个边，读不出"框"。
			# 压回最暗柱色，白框才立得住，柱子高度也还看得见。
			c = Prts.BAR
		elif heat > 0.0:
			c = Prts.BAR.lerp(Prts.BAR_HOT, clampf(heat, 0.0, 1.0))
		elif sorted_target.size() == n and int(values[i]) == int(sorted_target[i]):
			c = Prts.BAR_SETTLED

		draw_rect(Rect2(x0, y, bw, bh), c)

		if label_mode and font != null:
			draw_string(font, Vector2(x0, y - 5), str(int(values[i])),
				HORIZONTAL_ALIGNMENT_CENTER, bw, 11, Prts.DIM)


## 飞行中元素的落点：只在基线上画一小段白色短横，而不是贯穿全高的方框。
## 贯穿全高的框在高速运行时会有几十条叠在一起，看起来就像没刷新掉的细线。
func _draw_move_targets(n: int, span: float, gap: int, base_y: float) -> void:
	if _moves.is_empty():
		return
	var drawn := {}
	var count := 0
	for k in range(_moves.size() - 1, -1, -1):
		if count >= MAX_TARGETS:
			break
		var m: Dictionary = _moves[k]
		var to_i := int(m["to"])
		if to_i < 0 or to_i >= n or drawn.has(to_i):
			continue
		drawn[to_i] = true
		count += 1
		var x0 := int(_bar_x(to_i, n, span))
		var bw := int(_bar_width(to_i, n, span, gap))
		draw_rect(Rect2(x0, base_y - 3, bw, 3), Prts.WHITE)


## 选中的元素：整列白框 + 顶部小三角。同时只会有一个，不会造成视觉噪声。
func _draw_selection(n: int, span: float, gap: int, base_y: float, pad_top: float) -> void:
	if _selected < 0 or _selected >= n:
		return
	var x0 := int(_bar_x(_selected, n, span))
	var bw := int(_bar_width(_selected, n, span, gap))
	draw_rect(Rect2(x0, pad_top, bw, base_y - pad_top), Prts.WHITE, false, 1.0)

	var cx := float(x0) + float(bw) * 0.5
	var ty := pad_top - 4.0
	draw_colored_polygon(PackedVector2Array([
		Vector2(cx - 4.0, ty - 5.0),
		Vector2(cx + 4.0, ty - 5.0),
		Vector2(cx, ty),
	]), Prts.WHITE)


## 正在飞的元素。抛物线抬起，让"在搬运"这件事一眼可辨。
func _draw_flying(n: int, span: float, gap: int, base_y: float, usable: float) -> void:
	for m in _moves:
		var from_i := int(m["from"])
		var to_i := int(m["to"])
		if from_i < 0 or from_i >= n or to_i < 0 or to_i >= n:
			continue
		var p := clampf(float(m["t"]) / MOVE_DURATION, 0.0, 1.0)
		var e := 1.0 - pow(1.0 - p, 3.0)  # ease-out：起步快、落位稳

		var x := lerpf(_bar_x(from_i, n, span), _bar_x(to_i, n, span), e)
		var lift := sin(p * PI) * 26.0
		var bh := _bar_height(float(m["v"]), usable)
		var bw := int(_bar_width(to_i, n, span, gap))
		var y := int(base_y) - bh - int(lift)

		draw_rect(Rect2(int(x), y, bw, bh), Prts.WHITE)


func _draw_placeholder(w: float, h: float) -> void:
	var font := get_theme_default_font()
	draw_string(font, Vector2(0, h * 0.5), "按「运行」生成题目",
		HORIZONTAL_ALIGNMENT_CENTER, w, 12, Prts.DIM)


func _draw_axis(w: float, base_y: float, n: int, span: float) -> void:
	draw_line(Vector2(PAD_X - 2, base_y + 0.5), Vector2(w - PAD_X + 2, base_y + 0.5),
		Prts.LINE_HI, 1.0)

	# 刻度画在基线下方。原来那版是贯穿全高的网格线，而柱子之间有 1px 缝隙，
	# 网格线正好从缝隙里透出来，形成一条条贯穿画面的细线——看起来像渲染残留。
	var i := 8
	while i < n:
		draw_rect(Rect2(int(_bar_x(i, n, span)), int(base_y) + 2, 1, 4), Prts.LINE_HI)
		i += 8

	var font := get_theme_default_font()
	if font == null:
		return
	var fs := 11

	draw_string(font, Vector2(PAD_X, PAD_TOP + 9), str(_max_value),
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Prts.DIM)

	var pct := 0 if n <= 0 else int(round(100.0 * float(_settled_count) / float(n)))
	draw_string(font, Vector2(PAD_X, size.y - 5),
		"已归位 %d / %d  (%d%%)" % [_settled_count, n, pct],
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Prts.TEXT)

	if not caption.is_empty():
		# 右对齐 + 显式宽度，不去自己量文字宽度（中英混排 + 系统字体回退会算不准）
		draw_string(font, Vector2(PAD_X, size.y - 5), caption,
			HORIZONTAL_ALIGNMENT_RIGHT, w - PAD_X - 16.0, fs, Prts.DIM)

extends SceneTree
## 开始菜单（TitleScreen）的逻辑体检。headless 运行：
##   godot --headless --path <项目> --script res://tests/test_title.gd
##
## 只测**能测的那一半**：色带几何与翻黑顺序、收场时间轴、菜单的选中/命中/两项的
## 去向、背景的视差与景深算法、流光的几何。画面（机房那两张图、发光线、
## 反白条的样子）要靠实机看，headless 里既没有绘制也没有窗口。
##
## 覆盖的坑：
##   · 色带留缝或重叠——底下的主界面会从缝里透出来（和接入屏同一条）。
##   · 收场没播完就交棒 / 播完了不交棒——前者会闪一下主界面，后者卡在黑屏。
##   · 点「退出」却走了登入那条路（或者反过来）——两个动作共用一条收场路径，
##     只有 _quit_armed 分得开，搞错就是"点了退出反而进游戏"。
##   · 收场中还能再点一次——出现第二次收场，信号发两遍。
##   · 视差方向反了 / 近景比远景滑得少——"纵深"就成了"画面整体在抖"。
##   · 焦点算法没把"对焦处的模糊"降到 0——永远糊着，等于没有对焦。

var _pass := 0
var _fail := 0


func _initialize() -> void:
	_run()


## _initialize 里挂进 root 的节点要等第一帧才真正进树、才跑 _ready
## （--script 模式的时序）。先等一帧，TitleScreen 的界面搭建才算完成。
func _run() -> void:
	await process_frame

	print("=== 能工智人·数据库 / 开始菜单测试 ===\n")

	_test_bands()
	_test_timeline()
	_test_menu()
	_test_quit_vs_login()
	_test_backdrop_math()
	_test_streams()
	await _test_screen_tree()

	print("\n=== 通过 %d / 失败 %d ===" % [_pass, _fail])
	quit(1 if (_fail > 0 or _pass == 0) else 0)


func _test(name: String, ok: bool, detail := "") -> void:
	if ok:
		_pass += 1
		print("  [OK]   %s%s" % [name, ("  —— " + detail) if detail != "" else ""])
	else:
		_fail += 1
		print("  [FAIL] %s%s" % [name, ("  —— " + detail) if detail != "" else ""])


# ---------------------------------------------------------------- 色带几何

## 真实窗口是 1600×936（视口 1600×900，aspect=expand 让高度多出一点）。
const SIZES := [Vector2(1600, 900), Vector2(1600, 936)]


func _test_bands() -> void:
	for sz in SIZES:
		var bs := TitleScreen.bands(sz.x, sz.y)
		var area := 0.0
		var overlaps := false
		var out_of_screen := false
		var full_width := true
		for i in bs.size():
			var r: Rect2 = bs[i]
			area += r.size.x * r.size.y
			if not is_equal_approx(r.position.x, 0.0) or not is_equal_approx(r.size.x, sz.x):
				full_width = false
			if r.position.y < -0.01 or r.end.y > sz.y + 0.01:
				out_of_screen = true
			for j in range(i + 1, bs.size()):
				if r.intersects(bs[j]):
					overlaps = true
		_test("色带拼满 %d×%d、互不重叠" % [int(sz.x), int(sz.y)],
			bs.size() >= 4 and is_equal_approx(area, sz.x * sz.y)
				and not overlaps and not out_of_screen,
			"%d 条，面积 %.0f / %.0f" % [bs.size(), area, sz.x * sz.y])
		_test("每条都是整宽（翻色要横贯画面）", full_width, "%d 条" % bs.size())

	# 从下往上翻：最下面那条最早黑，最上面那条最晚
	_test("色带从下往上翻",
		TitleScreen.band_black(5, 0.0) and not TitleScreen.band_black(0, 0.0)
			and not TitleScreen.band_black(0, TitleScreen.wipe_done() - 0.01)
			and TitleScreen.band_black(0, TitleScreen.wipe_done()),
		"t=0 只黑最下一条，t=wipe_done 全黑")


# ---------------------------------------------------------------- 时间轴

func _test_timeline() -> void:
	var t := TitleScreen.new()
	_test("开局是主状态、未结束", t.state() == 0 and not t.is_finished())
	_test("收场总时长 > 翻完的时刻",
		TitleScreen.total_time() > TitleScreen.wipe_done(),
		"%.2fs / %.2fs" % [TitleScreen.total_time(), TitleScreen.wipe_done()])

	var got: Array = []
	t.finished.connect(func(): got.append("login"))
	t.activate(0)
	_test("点登入进入收场状态", t.state() == 1, "state=%d" % t.state())
	t.advance(TitleScreen.total_time() * 0.5)
	_test("收场中途不算结束", got.is_empty() and not t.is_finished())
	# 收场已经开始了，这时候再点另一项不该有第二次收场（信号会发两遍）
	t.activate(1)
	t.advance(TitleScreen.total_time())
	_test("收场走完发出 finished，且只发一次", got == ["login"], "信号 %s" % str(got))
	t.free()


# ---------------------------------------------------------------- 菜单

func _test_menu() -> void:
	var t := TitleScreen.new()
	t.size = Vector2(1600, 900)
	_test("正好两个选项", t.item_count() == 2,
		"%s / %s" % [t.item_label(0), t.item_label(1)])
	_test("两项是登入与退出",
		t.item_label(0).replace(" ", "") == "登入"
			and t.item_label(1).replace(" ", "") == "退出")

	# 上下移动要能转圈，不能卡在某一头
	t.move_selection(-1)
	_test("往上越界回到最后一项", t.selected() == 1, "选中 %d" % t.selected())
	t.move_selection(1)
	_test("往下越界回到第一项", t.selected() == 0, "选中 %d" % t.selected())

	# 命中测试：两项的矩形不能重叠，空白处不能命中
	var r0 := t.item_rect(0)
	var r1 := t.item_rect(1)
	_test("两项菜单条不重叠", not r0.intersects(r1),
		"%s / %s" % [str(r0), str(r1)])
	_test("条内命中、条外不命中",
		t.item_at(r0.get_center()) == 0 and t.item_at(r1.get_center()) == 1
			and t.item_at(Vector2(r0.position.x, r0.position.y - 40.0)) == -1)
	_test("命中之后选中项跟着变",
		t.hover(1) and t.selected() == 1 and not t.hover(1))
	t.free()


# ---------------------------------------------------------------- 两个动作的去向

func _test_quit_vs_login() -> void:
	var t := TitleScreen.new()
	var got: Array = []
	t.finished.connect(func(): got.append("login"))
	t.quit_requested.connect(func(): got.append("quit"))
	t.activate(1)
	t.advance(TitleScreen.total_time() + 0.01)
	_test("点退出走退出那条路（不发 finished）", got == ["quit"], "信号 %s" % str(got))
	t.free()

	var t2 := TitleScreen.new()
	var got2: Array = []
	t2.finished.connect(func(): got2.append("login"))
	t2.quit_requested.connect(func(): got2.append("quit"))
	t2.activate_selected()      # 默认选中第一项 = 登入
	t2.advance(TitleScreen.total_time() + 0.01)
	_test("回车确认走登入那条路", got2 == ["login"], "信号 %s" % str(got2))
	t2.free()


# ---------------------------------------------------------------- 视差与景深

func _test_backdrop_math() -> void:
	# 鼠标越靠下，焦点越近（数值越大）
	_test("焦点随鼠标上下单调",
		TitleBackdrop.focus_from_mouse(0.0) < TitleBackdrop.focus_from_mouse(0.5)
			and TitleBackdrop.focus_from_mouse(0.5) < TitleBackdrop.focus_from_mouse(1.0),
		"%.2f → %.2f" % [TitleBackdrop.focus_from_mouse(0.0),
			TitleBackdrop.focus_from_mouse(1.0)])

	# 对焦处必须完全不糊，越远越糊
	var b := TitleBackdrop.blur_for_depth(0.5, 0.5, 8.0)
	var b2 := TitleBackdrop.blur_for_depth(0.9, 0.5, 8.0)
	_test("对焦处不糊、离焦越远越糊",
		is_zero_approx(b) and b2 > b and is_equal_approx(
			TitleBackdrop.blur_for_depth(0.1, 0.5, 8.0), b2),
		"对焦 %.1f / 偏离 %.1f" % [b, b2])

	# 视差：鼠标往右，画面往左；近景滑得比远景多
	var far := TitleBackdrop.parallax_offset(Vector2(1.0, 0.5), 0.32, 12.0)
	var near := TitleBackdrop.parallax_offset(Vector2(1.0, 0.5), 1.0, 42.0)
	_test("鼠标往右、画面往左", far.x < 0.0 and near.x < 0.0,
		"远景 %.1fpx / 近景 %.1fpx" % [far.x, near.x])
	_test("近景滑得比远景多", absf(near.x) > absf(far.x) * 2.0,
		"%.1f vs %.1f" % [absf(near.x), absf(far.x)])
	_test("鼠标居中时不偏",
		TitleBackdrop.parallax_offset(Vector2(0.5, 0.5), 1.0, 42.0) == Vector2.ZERO)

	# 过扫描：图必须比屏幕大，否则视差一滑就露出边缘
	var screen := Vector2(1600, 900)
	var rect := TitleBackdrop.layer_rect(screen, TitleBackdrop.OVERSCAN)
	var margin := (rect.size.x - screen.x) * 0.5
	_test("背景图比屏幕大一圈且居中",
		rect.size.x > screen.x and rect.size.y > screen.y
			and is_equal_approx(rect.position.x, -margin)
			and is_equal_approx(rect.position.y, -(rect.size.y - screen.y) * 0.5),
		"过扫描 %.0f%%、四边各留 %.0fpx" % [(TitleBackdrop.OVERSCAN - 1.0) * 100.0, margin])
	_test("过扫描够覆盖最大视差", margin >= TitleBackdrop.PARALLAX_NEAR,
		"余量 %.0fpx / 近景最大 %.0fpx" % [margin, TitleBackdrop.PARALLAX_NEAR])


# ---------------------------------------------------------------- 流光

func _test_streams() -> void:
	# 虚线位置要在 0~1 之间转圈
	var ok_range := true
	var wrapped := false
	for k in 9:
		var u := TitleStreams.dash_u(k, 7, 0.31)
		if u < 0.0 or u >= 1.0:
			ok_range = false
		if k > 0 and u < TitleStreams.dash_u(k - 1, 7, 0.31):
			wrapped = true
	_test("虚线位置在 0~1 之间且会回绕", ok_range and wrapped)

	# 透视压缩：u 越大，屏幕上的位置增长越快（远处挤、近处疏）
	_test("透视压缩：越远越密",
		TitleStreams.persp(0.0) == 0.0 and TitleStreams.persp(1.0) == 1.0
			and TitleStreams.persp(0.5) < 0.5
			and TitleStreams.persp(0.9) - TitleStreams.persp(0.8)
				> TitleStreams.persp(0.2) - TitleStreams.persp(0.1),
		"persp(0.5)=%.2f" % TitleStreams.persp(0.5))

	# 两端淡出：不然 wrap 的一瞬间会"啪"地跳一下
	_test("虚线两端淡出",
		is_zero_approx(TitleStreams.dash_alpha(0.0))
			and TitleStreams.dash_alpha(0.3) > 0.9
			and is_zero_approx(TitleStreams.dash_alpha(1.0)),
		"中段 %.2f" % TitleStreams.dash_alpha(0.3))

	# u = 0 就是灭点本身
	var screen := Vector2(1600, 900)
	var vp := Vector2(TitleStreams.VP.x * screen.x, TitleStreams.VP.y * screen.y)
	_test("线的起点就是灭点",
		TitleStreams.line_point(screen, Vector2(-0.3, 0.6), 0.0).is_equal_approx(vp),
		str(vp))

	# 深度：贴着灭点最远
	_test("深度：灭点处最远、边缘最近",
		TitleStreams.depth_at(0.0) == 0.0 and TitleStreams.depth_at(1.0) == 1.0)

	# 灭点必须和背景那一层对上（两处各写一遍，写歪了流光就不在灯带上了）
	_test("流光的灭点和背景一致", TitleStreams.VP == TitleBackdrop.VP)


# ---------------------------------------------------------------- 挂进树

func _test_screen_tree() -> void:
	var t := TitleScreen.new()
	root.add_child(t)
	await process_frame
	_test("挂进树之后有背景层与流光层",
		t.get_child_count() >= 2 and t.find_child("*", true, false) != null)

	# 背景的鼠标跟随：headless 没有真鼠标，喂一个目标进去、推进平滑
	var bd: TitleBackdrop = t.get_child(0)
	bd.follow_mouse = false
	bd.size = Vector2(1600, 900)
	bd.set_mouse_target(Vector2(1.0, 0.2))
	for i in 40:
		bd.advance(1.0 / 60.0)
	var fore_far := bd.layer_blur(1)
	_test("鼠标靠上 → 对焦到远处（模糊量小）",
		bd.focus() < 0.35 and bd.layer_offset(1).x < 0.0,
		"焦点 %.2f / 近景偏移 %.1fpx" % [bd.focus(), bd.layer_offset(1).x])

	bd.set_mouse_target(Vector2(0.0, 1.0))
	for i in 40:
		bd.advance(1.0 / 60.0)
	# 对焦到近处时近景要明显变清楚，但**始终留一点离焦**：
	# 它贴着镜头，深度在焦点范围之外（见 FOCUS_MAX / FORE_DEPTH）。
	_test("鼠标靠下 → 近景明显变清楚、且始终带一点离焦",
		bd.layer_blur(1) < fore_far * 0.5 and bd.layer_blur(1) > 0.0,
		"远景对焦时 %.1fpx → 近景对焦时 %.1fpx" % [fore_far, bd.layer_blur(1)])
	_test("鼠标靠下 → 远景的中段（灭点附近）最清楚",
		TitleBackdrop.blur_for_depth(0.5, bd.focus(), TitleBackdrop.BLUR_ROOM)
			< bd.layer_blur(1),
		"远景 %.1fpx / 近景 %.1fpx" % [
			TitleBackdrop.blur_for_depth(0.5, bd.focus(), TitleBackdrop.BLUR_ROOM),
			bd.layer_blur(1)])

	# 转场淡出：整层透明 = 露出底下的纯黑
	bd.set_fade(0.0)
	_test("转场能把背景淡掉", is_zero_approx(bd.fade()))

	t.free()

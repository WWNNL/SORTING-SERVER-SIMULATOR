extends SceneTree
## 开始菜单（TitleScreen）的逻辑体检。headless 运行：
##   godot --headless --path <项目> --script res://tests/test_title.gd
##
## 只测**能测的那一半**：色带几何与翻黑顺序、收场时间轴、菜单的选中/命中/两项的
## 去向、背景的视差与景深算法、指示灯层的深度语言。画面（机房那张图、
## 发光的指示灯、反白条的样子）要靠实机看，headless 里既没有绘制也没有窗口。
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

	# 视差：鼠标往右，画面往左；偏移随幅度与权重线性缩放
	# （单层机房：整幅一起滑，权重留给将来真要再拆层时用）
	var off := TitleBackdrop.parallax_offset(Vector2(1.0, 0.5), 1.0, 24.0)
	var half := TitleBackdrop.parallax_offset(Vector2(1.0, 0.5), 0.5, 24.0)
	_test("鼠标往右、画面往左", off.x < 0.0,
		"偏移 %.1fpx" % off.x)
	_test("偏移随权重线性缩放", is_equal_approx(half.x, off.x * 0.5),
		"权重 1.0 %.1fpx / 0.5 %.1fpx" % [off.x, half.x])
	_test("鼠标居中时不偏",
		TitleBackdrop.parallax_offset(Vector2(0.5, 0.5), 1.0, 24.0) == Vector2.ZERO)

	# 过扫描：图必须比屏幕大，否则视差一滑就露出边缘
	var screen := Vector2(1600, 900)
	var rect := TitleBackdrop.layer_rect(screen, TitleBackdrop.OVERSCAN)
	var margin := (rect.size.x - screen.x) * 0.5
	_test("背景图比屏幕大一圈且居中",
		rect.size.x > screen.x and rect.size.y > screen.y
			and is_equal_approx(rect.position.x, -margin)
			and is_equal_approx(rect.position.y, -(rect.size.y - screen.y) * 0.5),
		"过扫描 %.0f%%、四边各留 %.0fpx" % [(TitleBackdrop.OVERSCAN - 1.0) * 100.0, margin])
	_test("过扫描够覆盖最大视差", margin >= TitleBackdrop.PARALLAX_ROOM,
		"余量 %.0fpx / 最大视差 %.0fpx" % [margin, TitleBackdrop.PARALLAX_ROOM])


# ---------------------------------------------------------------- 指示灯层

func _test_streams() -> void:
	# 灭点必须和背景那一层对上（指示灯的深度代理从它算起）
	_test("指示灯层的灭点和背景一致", TitleStreams.VP == TitleBackdrop.VP)

	# 指示灯的离焦语言和背景是同一套：对焦深度处为 0，离得越远越糊
	_test("指示灯对焦处不糊、离焦越远越糊",
		is_zero_approx(TitleStreams.dot_blur(0.4, 0.4))
			and TitleStreams.dot_blur(0.9, 0.4) > TitleStreams.dot_blur(0.6, 0.4),
		"对焦 0.0 / 偏近 %.1f / 偏远 %.1f" % [
			TitleStreams.dot_blur(0.6, 0.4), TitleStreams.dot_blur(0.9, 0.4)])


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
	var blur_far := bd.layer_blur(0)
	_test("鼠标靠上 → 对焦到远处、画面往左滑",
		bd.focus() < 0.35 and bd.layer_offset(0).x < 0.0,
		"焦点 %.2f / 偏移 %.1fpx" % [bd.focus(), bd.layer_offset(0).x])

	bd.set_mouse_target(Vector2(0.0, 1.0))
	for i in 40:
		bd.advance(1.0 / 60.0)
	# 单层机房按"中段深度 0.5"报告模糊量：对焦远处（0.2）时中段离焦 0.3，
	# 对焦近处（1.0）时离焦 0.5——所以靠下时中段反而更糊，灭点附近才锐。
	_test("鼠标靠下 → 焦点移到近处、中段更糊",
		bd.focus() > 0.9 and bd.layer_blur(0) > blur_far,
		"靠上时 %.1fpx → 靠下时 %.1fpx" % [blur_far, bd.layer_blur(0)])
	# 单层深度代理的硬性质：模糊在**对焦深度**处为 0，往两端都变糊——
	# 靠下对焦时灭点（最远端）糊得最狠，这和透视画面的直觉一致。
	_test("模糊在对焦深度处为 0、两端都更糊",
		is_zero_approx(TitleBackdrop.blur_for_depth(bd.focus(), bd.focus(),
				TitleBackdrop.BLUR_ROOM))
			and TitleBackdrop.blur_for_depth(0.0, bd.focus(), TitleBackdrop.BLUR_ROOM)
				> TitleBackdrop.blur_for_depth(0.5, bd.focus(), TitleBackdrop.BLUR_ROOM),
		"对焦处 0 / 灭点 %.1fpx / 中段 %.1fpx" % [
			TitleBackdrop.blur_for_depth(0.0, bd.focus(), TitleBackdrop.BLUR_ROOM),
			TitleBackdrop.blur_for_depth(0.5, bd.focus(), TitleBackdrop.BLUR_ROOM)])

	# 转场淡出：整层透明 = 露出底下的纯黑
	bd.set_fade(0.0)
	_test("转场能把背景淡掉", is_zero_approx(bd.fade()))

	t.free()

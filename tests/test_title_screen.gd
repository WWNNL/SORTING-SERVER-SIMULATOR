extends SceneTree
## 标题屏的逻辑体检。headless 运行：
##   godot --headless --path <项目> --script res://tests/test_title_screen.gd
##
## 只测**能测的那一半**：时间轴、翻块几何、选择与确认、交棒信号、对焦平滑。
## 画面（机厅底图、景深、视差、反白）要靠实机看，headless 没有绘制。
##
## 覆盖的坑：
##   · 交棒不同步——login_confirmed 发出去时自检还没挂上，中间会闪出主界面。
##   · 翻块比例加起来不是 1.0——带子之间留缝，底下的主界面从缝里透出来。
##   · 退场方向和入场一样——两段转场摆在一起像同一段在重播。
##   · 选择下标越界/死循环——select 的夹取和 wrap 各验一遍。

var _pass := 0
var _fail := 0


func _initialize() -> void:
	_run()


## _initialize 里挂进 root 的节点要等第一帧才真正进树、才跑 _ready
## （--script 模式的时序）。先等一帧，标题屏的界面搭建才算完成。
func _run() -> void:
	await process_frame

	print("=== 能工智人·数据库 / 标题屏测试 ===\n")

	_test_layers()
	_test_bands()
	_test_timeline()
	_test_selection()
	_test_login_handoff()
	_test_focus_smooth()

	print("\n=== 通过 %d / 失败 %d ===" % [_pass, _fail])
	quit(1 if (_fail > 0 or _pass == 0) else 0)


# ---------------------------------------------------------------- 层级

func _test_layers() -> void:
	var t: TitleScreen = _fresh()
	_test("标题屏压住整棵浮层栈（z 700）", t.z_index == 700,
		"接入屏 600 / 自检 500 / 菜单 400 / 报错 300 都在它下面")
	t.free()


# ---------------------------------------------------------------- 翻块几何

func _test_bands() -> void:
	var rects := TitleScreen.band_rects(1600.0, 900.0)
	_test("带子条数与表长一致", rects.size() == TitleScreen.BAND_COUNT,
		"%d 条" % rects.size())

	# 高度加起来必须是整屏：留一条缝，主界面就会从缝里透出来
	var total := 0.0
	var contiguous := true
	var last_bottom := 0.0
	for r in rects:
		total += (r as Rect2).size.y
		if not is_equal_approx((r as Rect2).position.y, last_bottom):
			contiguous = false
		last_bottom = (r as Rect2).position.y + (r as Rect2).size.y
	_test("带子高度加起来是整屏", is_equal_approx(total, 900.0),
		"合计 %.1f" % total)
	_test("带子首尾相接不留缝", contiguous, "上一条的下沿 = 下一条的上沿")


# ---------------------------------------------------------------- 时间轴

func _test_timeline() -> void:
	# 入场自上而下：下面的带子晚于上面的露出
	var in_rising := true
	for i in range(1, TitleScreen.BAND_COUNT):
		if TitleScreen.in_band_time(i) <= TitleScreen.in_band_time(i - 1):
			in_rising = false
	_test("入场自上而下逐条露出", in_rising, "和接入屏同一个方向")

	# 退场自下而上：方向必须反过来，不然两段转场像在重播
	var out_falling := true
	for i in range(1, TitleScreen.BAND_COUNT):
		if TitleScreen.out_band_time(i) >= TitleScreen.out_band_time(i - 1):
			out_falling = false
	_test("退场方向与入场相反（自下而上）", out_falling, "白→黑反向才像'又发生了一件事'")

	_test("入场总时长 = 最后一条露出的时刻",
		is_equal_approx(TitleScreen.in_total(),
			TitleScreen.T_FLIP_IN + TitleScreen.BAND_GAP * float(TitleScreen.BAND_COUNT - 1)),
		"纯函数算出，别再手改一处漏一处")
	_test("退场总时长 = 翻块 + 收尾停拍",
		is_equal_approx(TitleScreen.out_total(),
			TitleScreen.T_FLIP_OUT + TitleScreen.BAND_GAP * float(TitleScreen.BAND_COUNT - 1)
				+ TitleScreen.T_OUT_HOLD),
		"交棒要等黑屏落定")
	_test("菜单输入门槛 = max(菜单落下, 入场走完)",
		is_equal_approx(TitleScreen.ready_at(),
			maxf(TitleScreen.T_MENU, TitleScreen.in_total())),
		"翻块没走完不能盲选")


# ---------------------------------------------------------------- 选择

func _test_selection() -> void:
	var t: TitleScreen = _fresh()

	_test("初始选中「登 入」", t.selected() == 0, "标题屏第一动作永远是进游戏")
	t.select_next()
	_test("下一个是「退 出」", t.selected() == 1, "0 → 1")
	t.select_next()
	_test("选择向下回绕到「登 入」", t.selected() == 0, "1 → 0")
	t.select_prev()
	_test("选择向上回绕到「退 出」", t.selected() == 1, "0 → 1（反向）")
	t.select(5)
	_test("越界下标夹回合法范围", t.selected() == 1, "select(5) → 1")
	t.select(-3)
	_test("负下标夹回 0", t.selected() == 0, "select(-3) → 0")

	t.free()


# ---------------------------------------------------------------- 登入交棒

func _test_login_handoff() -> void:
	var t: TitleScreen = _fresh()
	var got := [false]
	t.login_confirmed.connect(func() -> void: got[0] = true)

	t.confirm_login_for_test()
	_test("确认登入后进入退场相位", t.state() == TitleScreen.ST_OUT, "ST_IN → ST_OUT")
	_test("退场中途不发信号", not got[0], "信号只该在黑屏落定那刻发")

	# 一步跨过退场：信号发出、屏幕自毁
	t.advance(TitleScreen.out_total() + 0.01)
	_test("黑屏落定才发 login_confirmed", got[0], "Main 在信号里同步挂开机自检")
	_test("播完自毁", not is_instance_valid(t) or t.is_finished(), "queue_free 已排队/完成")

	if is_instance_valid(t):
		t.free()


# ---------------------------------------------------------------- 对焦平滑

func _test_focus_smooth() -> void:
	var t: TitleScreen = _fresh()

	# 平滑值从中心出发，朝目标靠拢但不瞬移
	t.set_focus_target(Vector2(0.9, 0.1))
	t.advance(0.016)
	var f := t.focus()
	_test("对焦点朝目标平滑移动（不瞬移）",
		f.x > 0.5 and f.x < 0.9 and f.y < 0.5 and f.y > 0.1,
		"一步只走一部分：(%0.2f, %0.2f)" % [f.x, f.y])

	# 目标越界要夹回 0~1：视差的位移余量是按这个范围留的
	t.set_focus_target(Vector2(9.0, -4.0))
	t.advance(1.0)
	f = t.focus()
	_test("目标越界夹回 0~1",
		f.x <= 1.0 and f.y >= 0.0,
		"(%0.2f, %0.2f)" % [f.x, f.y])

	t.free()


# ---------------------------------------------------------------- 工具

func _fresh() -> TitleScreen:
	var t: TitleScreen = TitleScreen.new()
	# _run 已经等过一帧，root 在树里：add_child 会同步跑完 _ready（界面搭建在内）
	root.add_child(t)
	return t


func _test(name: String, ok: bool, detail: String) -> void:
	if ok:
		_pass += 1
		print("  [通过] %-30s %s" % [name, detail])
		return
	_fail += 1
	print("  [失败] %-30s %s" % [name, detail])

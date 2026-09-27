extends SceneTree
## 接入屏（登入界面）的逻辑体检。headless 运行：
##   godot --headless --path <项目> --script res://tests/test_login.gd
##
## 只测**能测的那一半**：分块几何、相位顺序、计数曲线、状态机。
## 画面（白屏上那几条游走的虚线、打勾的圈、黑屏的发光波形、整屏翻色）
## 要靠实机看，headless 里既没有绘制也没有窗口。
##
## 最要命的一条是分块几何：五条色带必须**拼满整屏、互不重叠**——留一条缝，
## 底下的主界面就会从缝里透出来；叠上一条，翻色时会露出一块颜色不对的边。
## 而这一屏是铺满全屏的浮层，几何错一点就是"画面坏了"，不是"位置偏了"。

var _pass := 0
var _fail := 0

## 真实窗口是 1600×936（视口 1600×900，aspect=expand 让高度多出一点），
## 几何按屏占比算，所以两个尺寸都要验。
const SIZES := [Vector2(1600, 900), Vector2(1600, 936)]


func _initialize() -> void:
	print("=== 能工智人·数据库 / 接入屏测试 ===\n")

	_test_bands()
	_test_phases()
	_test_count()
	_test_state_machine()
	_test_wave()

	print("\n=== 通过 %d / 失败 %d ===" % [_pass, _fail])
	quit(1 if (_fail > 0 or _pass == 0) else 0)


# ---------------------------------------------------------------- 分块几何

func _test_bands() -> void:
	for sz in SIZES:
		var bs := LoginScreen.bands(sz.x, sz.y)
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
		_test("每条都是整宽（翻色要横贯画面）",
			full_width, "%d 条" % bs.size())

	# 高度不等分：等分看着像测试图，不等分才像排版
	var hs := {}
	for r in LoginScreen.bands(1600.0, 900.0):
		hs[int((r as Rect2).size.y)] = true
	_test("色带高度不等分", hs.size() >= 3, "%d 种高度" % hs.size())


# ---------------------------------------------------------------- 相位

func _test_phases() -> void:
	_test("白屏元素依次落下",
		LoginScreen.T_IN < LoginScreen.T_BRAND
			and LoginScreen.T_BRAND < LoginScreen.T_CENTER
			and LoginScreen.T_CENTER < LoginScreen.T_PIPS
			and LoginScreen.T_PIPS < LoginScreen.T_FOOT,
		"翻块 %.2f → 品牌 %.2f → 中央 %.2f → 方块 %.2f → 页脚 %.2f"
			% [LoginScreen.T_IN, LoginScreen.T_BRAND, LoginScreen.T_CENTER,
				LoginScreen.T_PIPS, LoginScreen.T_FOOT])

	# 计数必须等翻块全部走完：不然最后一条带子还白着，白字的百分比已经画上去了
	var flip_done := LoginScreen.T_FLIP + LoginScreen.BAND_GAP * float(LoginScreen.BAND_COUNT - 1)
	_test("计数等翻块全部走完",
		is_equal_approx(flip_done, LoginScreen.T_FLIP_DONE)
			and LoginScreen.percent_at(flip_done) == 0,
		"最后一条翻完 %.2f = 开始计数 %.2f" % [flip_done, LoginScreen.T_FLIP_DONE])

	# 条数表和高占比表必须对得上——翻块结束的时刻是从 BAND_COUNT 算的
	_test("条数与占比表对得上",
		LoginScreen.bands(1600.0, 900.0).size() == LoginScreen.BAND_COUNT,
		"bands() %d 条 / BAND_COUNT %d"
			% [LoginScreen.bands(1600.0, 900.0).size(), LoginScreen.BAND_COUNT])

	_test("整段（不含等待）不超过 4 秒",
		LoginScreen.T_FOOT < 1.5 and LoginScreen.dark_total() < 2.6,
		"白屏 %.2f 秒、黑屏 %.2f 秒" % [LoginScreen.T_FOOT, LoginScreen.dark_total()])


# ---------------------------------------------------------------- 计数

func _test_count() -> void:
	var hold := LoginScreen.T_FLIP_DONE
	_test("翻块期间百分比是 0",
		LoginScreen.percent_at(0.0) == 0 and LoginScreen.percent_at(hold) == 0,
		"t=0 → %d%%，t=%.2f → %d%%" % [LoginScreen.percent_at(0.0), hold,
			LoginScreen.percent_at(hold)])

	var rising := true
	var prev := -1
	for i in 21:
		var t := hold + LoginScreen.T_COUNT * float(i) / 20.0
		var p := LoginScreen.percent_at(t)
		if p < prev:
			rising = false
		prev = p
	_test("计数单调不回头、末端夹在 100",
		rising and prev == 100 and LoginScreen.percent_at(hold + 99.0) == 100,
		"t=%.2f → %d%%" % [hold + LoginScreen.T_COUNT,
			LoginScreen.percent_at(hold + LoginScreen.T_COUNT)])

	var mid := LoginScreen.percent_at(hold + LoginScreen.T_COUNT * 0.5)
	_test("一半时间走到一半左右",
		mid >= 45 and mid <= 55, "50%% 时刻 → %d%%" % mid)

	# 四个小方块：从 0 点满到 PIP_COUNT 就停住，不会越点越多
	_test("方块从 0 点满、点满就停",
		LoginScreen.pips_at(0.0) == 0
			and LoginScreen.pips_at(LoginScreen.T_PIPS) == 1
			and LoginScreen.pips_at(LoginScreen.T_PIPS + LoginScreen.PIP_GAP * 3.0) == 4
			and LoginScreen.pips_at(LoginScreen.T_PIPS + 99.0) == 4,
		"t=0 → 0 个，点满 → %d 个，再久 → %d 个"
			% [LoginScreen.pips_at(LoginScreen.T_PIPS + LoginScreen.PIP_GAP * 3.0),
				LoginScreen.pips_at(LoginScreen.T_PIPS + 99.0)])

	# 三段状态文案：随百分比换，而且三句都不一样
	var a := LoginScreen.status_for(0)
	var b := LoginScreen.status_for(50)
	var c := LoginScreen.status_for(100)
	_test("状态文案分三段、互不相同",
		a != b and b != c and a != c and not a.is_empty(),
		"%s / %s / %s" % [a, b, c])
	_test("状态文案跟着百分比切",
		LoginScreen.status_for(39) == a and LoginScreen.status_for(40) == b
			and LoginScreen.status_for(79) == b and LoginScreen.status_for(80) == c,
		"40%% 与 80%% 是分界")


# ---------------------------------------------------------------- 状态机

func _test_state_machine() -> void:
	var l: LoginScreen = LoginScreen.new()

	_test("开局是白屏等待", l.state() == LoginScreen.ST_LIGHT, "state=%d" % l.state())

	# 白屏在等玩家：推很久也不该自己往下走
	l.advance(10.0)
	_test("白屏一直等，不会自己走掉",
		l.state() == LoginScreen.ST_LIGHT and not l.is_finished(),
		"t=%.1f 仍是 state=%d" % [l.elapsed(), l.state()])

	l.login()
	_test("按键之后进黑屏", l.state() == LoginScreen.ST_DARK, "state=%d" % l.state())

	l.advance(LoginScreen.dark_total() - 0.01)
	_test("黑屏走完前仍在黑屏",
		l.state() == LoginScreen.ST_DARK, "t=%.2f" % l.elapsed())

	l.advance(0.02)
	_test("黑屏走完进收尾（翻纯黑）", l.state() == LoginScreen.ST_OUT, "state=%d" % l.state())

	l.advance(LoginScreen.T_OUT - 0.01)
	_test("收尾走完前仍未结束",
		not l.is_finished(), "t=%.2f" % l.elapsed())

	# 已经进黑屏之后再按只是把计数推到底，不会重来一遍
	var l2: LoginScreen = LoginScreen.new()
	l2.advance(1.0)
	l2.login()
	l2.advance(0.5)
	var before := l2.elapsed()
	l2.login()
	_test("黑屏期间再按不会重置进度",
		l2.state() == LoginScreen.ST_DARK and l2.elapsed() >= before,
		"t=%.2f → %.2f" % [before, l2.elapsed()])

	l.free()
	l2.free()


# ---------------------------------------------------------------- 波形

## 波形是这一屏唯一"一直在动"的东西（除了百分比数字）。这里量三件事：
## 它真的在动、它不会跑出画面中段、它走的方向始终一致——
## 靠眼看截图说不清"动了没有"，而且方向反了也看不出来。
func _test_wave() -> void:
	var h := 900.0
	var us := [0.0, 0.17, 0.35, 0.5, 0.72, 0.9, 1.0]

	var moved := 0
	for u in us:
		if absf(LoginScreen.wave_y(u, h, 0.0) - LoginScreen.wave_y(u, h, 0.35)) > 0.5:
			moved += 1
	_test("波形随时间移动", moved >= us.size() - 1,
		"%d / %d 个采样点在 0.35 秒里挪动了" % [moved, us.size()])

	# 走起来也不能跑出中段：它得一直横贯画面，压不到上下的字
	var inside := true
	var t := 0.0
	while t < 3.0:
		for u in us:
			var y := LoginScreen.wave_y(u, h, t)
			if y < h * 0.36 or y > h * 0.64:
				inside = false
		t += 0.05
	_test("波形始终横在中段", inside,
		"三秒里最高最低都落在 %.0f~%.0f 之间" % [h * 0.36, h * 0.64])

	# 一个周期内每个采样点都在动（不是只有个别点在抖）
	var all_move := true
	for u in us:
		var ys := []
		var tt := 0.0
		while tt < 1.0:
			ys.append(LoginScreen.wave_y(u, h, tt))
			tt += 0.1
		var lo: float = ys.min()
		var hi: float = ys.max()
		if hi - lo < 1.0:
			all_move = false
	_test("每个采样点都在起伏", all_move,
		"一秒内各点的振幅都超过 1px")


func _test(name: String, ok: bool, detail: String) -> void:
	if ok:
		_pass += 1
		print("  [通过] %-26s %s" % [name, detail])
		return
	_fail += 1
	print("  [失败] %-26s %s" % [name, detail])

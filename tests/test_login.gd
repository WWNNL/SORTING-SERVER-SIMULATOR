extends SceneTree
## 登入界面的逻辑体检。headless 运行：
##   godot --headless --path <项目> --script res://tests/test_login.gd
##
## 只测**能测的那一半**：分块几何、相位时长、状态机、文案。
## 画面（白块拼起来、一块块翻黑、整屏翻白再翻黑）和输入要靠实机看，
## headless 里既没有绘制也没有窗口。
##
## 最要命的一条是分块几何：留一条缝、或者两块叠上，底下的主界面就会从缝里
## 透出来（或叠出一块颜色不对的边）——而这一屏是**铺满整屏**的浮层，
## 几何错一点就是"画面坏了"，不是"位置偏了"。

var _pass := 0
var _fail := 0

## 真实窗口是 1600×936（视口 1600×900，aspect=expand 让高度多出一点），
## 几何按屏占比算，所以两个尺寸都要验。
const SIZES := [Vector2(1600, 900), Vector2(1600, 936)]


func _initialize() -> void:
	print("=== 能工智人·数据库 / 登入界面测试 ===\n")

	_test_blocks()
	_test_phases()
	_test_state_machine()
	_test_rows()

	print("\n=== 通过 %d / 失败 %d ===" % [_pass, _fail])
	quit(1 if (_fail > 0 or _pass == 0) else 0)


# ---------------------------------------------------------------- 分块几何

func _test_blocks() -> void:
	for sz in SIZES:
		var bs := LoginScreen.blocks(sz.x, sz.y)
		var area := 0.0
		var overlaps := false
		var out_of_screen := false
		for i in bs.size():
			var r: Rect2 = bs[i]
			area += r.size.x * r.size.y
			if r.position.x < -0.01 or r.position.y < -0.01 \
					or r.end.x > sz.x + 0.01 or r.end.y > sz.y + 0.01:
				out_of_screen = true
			for j in range(i + 1, bs.size()):
				if r.intersects(bs[j]):
					overlaps = true
		_test("分块拼满 %d×%d、互不重叠" % [int(sz.x), int(sz.y)],
			bs.size() >= 4 and is_equal_approx(area, sz.x * sz.y)
				and not overlaps and not out_of_screen,
			"%d 块，面积 %.0f / %.0f" % [bs.size(), area, sz.x * sz.y])

	# 左白块必须是**整条**：它是招牌，被切成两半就不成样子了
	var b: Rect2 = LoginScreen.blocks(1600.0, 900.0)[0]
	_test("左白块占满整高",
		is_equal_approx(b.position.y, 0.0) and is_equal_approx(b.size.y, 900.0)
			and is_equal_approx(b.position.x, 0.0),
		"%.0f×%.0f @ (%.0f, %.0f)" % [b.size.x, b.size.y, b.position.x, b.position.y])


# ---------------------------------------------------------------- 时间轴

func _test_phases() -> void:
	_test("出场不到 1.5 秒",
		LoginScreen.T_INTRO > 0.4 and LoginScreen.T_INTRO < 1.5,
		"%.2f 秒（要够看清几块色块翻完，又不能让人干等）" % LoginScreen.T_INTRO)
	_test("退场不到 1.2 秒",
		LoginScreen.T_OUT > 0.5 and LoginScreen.T_OUT < 1.2,
		"%.2f 秒" % LoginScreen.T_OUT)

	# 出场里"整屏全白"的那一瞬间：三块白要全部拼上，才轮到翻黑
	var last_white := LoginScreen.INTRO_RIGHT_AT + LoginScreen.BLOCK_GAP * 2.0
	_test("白块拼齐之后才翻黑",
		last_white < LoginScreen.INTRO_CARVE_AT,
		"最后一块白 %.2f → 第一块翻黑 %.2f" % [last_white, LoginScreen.INTRO_CARVE_AT])

	# 内容要在翻黑之后才出现，否则字会被"翻黑"那一下盖掉又冒出来
	_test("文字在翻块之后才落下",
		LoginScreen.INTRO_LEFT_TEXT_AT >= LoginScreen.INTRO_CARVE_AT
			and LoginScreen.INTRO_ROWS_AT >= LoginScreen.INTRO_CARVE_AT + LoginScreen.BLOCK_GAP * 2.0,
		"左块文字 %.2f、右栏 %.2f" % [LoginScreen.INTRO_LEFT_TEXT_AT, LoginScreen.INTRO_ROWS_AT])

	# 退场：翻白要全部走完，才轮到停一下、再翻黑
	var white_done := LoginScreen.OUT_WHITE_AT + LoginScreen.OUT_WHITE_GAP * 3.0
	var black_start := white_done + LoginScreen.OUT_HOLD
	_test("翻白走完再翻黑",
		black_start > white_done and black_start + LoginScreen.OUT_BLACK_GAP * 3.0 < LoginScreen.T_OUT,
		"翻白到 %.2f、停 %.2f、翻黑到 %.2f、结束 %.2f"
			% [white_done, LoginScreen.OUT_HOLD, black_start + LoginScreen.OUT_BLACK_GAP * 3.0,
				LoginScreen.T_OUT])


# ---------------------------------------------------------------- 状态机

func _test_state_machine() -> void:
	var l: LoginScreen = LoginScreen.new()

	_test("开局是出场相位", l.state() == LoginScreen.ST_INTRO, "state=%d" % l.state())

	# 出场没播完时按"登入"不算数——那一下是跳过出场（见 _input），不是登入
	l.login()
	_test("出场期间登入不生效",
		l.state() == LoginScreen.ST_INTRO,
		"state=%d（必须等按钮出现）" % l.state())

	l.advance(LoginScreen.T_INTRO - 0.01)
	_test("出场没走完仍是出场",
		l.state() == LoginScreen.ST_INTRO, "t=%.2f" % l.elapsed())

	l.advance(0.02)
	_test("出场走完进就绪",
		l.state() == LoginScreen.ST_READY, "t=%.2f" % l.elapsed())

	l.login()
	_test("就绪之后登入切到退场",
		l.state() == LoginScreen.ST_OUT, "state=%d" % l.state())

	l.advance(LoginScreen.T_OUT - 0.01)
	_test("退场走完前仍未结束",
		not l.is_finished() and l.state() == LoginScreen.ST_OUT, "t=%.2f" % l.elapsed())

	l.free()


# ---------------------------------------------------------------- 文案

func _test_rows() -> void:
	var rows := LoginScreen.rows_for(0, 0, 11)
	_test("键值行够撑起右栏", rows.size() >= 4, "%d 行" % rows.size())

	var shaped := true
	for r in rows:
		if not (r is Array) or (r as Array).size() != 2:
			shaped = false
		elif String((r as Array)[0]).is_empty() or String((r as Array)[1]).is_empty():
			shaped = false
	_test("每行都是键 + 值", shaped, "字段齐全")

	var joined := _join(rows)
	_test("权限一栏写着待确认",
		joined.contains("待确认"), "登入前不该自称已授权")

	var big := LoginScreen.rows_for(1234, 10, 11)
	_test("运行次数按千分位写",
		_join(big).contains("1,234 次"), "1234 → 1,234 次")
	_test("进度写成 已通过 x / y 关",
		_join(big).contains("10 / 11 关"), "10 / 11 关")


func _join(rows: Array) -> String:
	var parts := PackedStringArray()
	for r in rows:
		parts.append("%s %s" % [String((r as Array)[0]), String((r as Array)[1])])
	return " | ".join(parts)


func _test(name: String, ok: bool, detail: String) -> void:
	if ok:
		_pass += 1
		print("  [通过] %-26s %s" % [name, detail])
		return
	_fail += 1
	print("  [失败] %-26s %s" % [name, detail])

extends SceneTree
## 存档比例回归测试。headless 运行：
##   godot --headless --path <项目> --script res://tests/test_save.gd
##
## 刻意只测纯逻辑，**不读写 user://save.json**——测试绝不能覆盖玩家真正的存档，
## 所以这里既不 save_game() 也不 load_game()，只调它们共用的那条夹取规则。
##
## 覆盖的坑：滑条最左的"逐行档"比例是 1/额定速度（C-256 时 7.7e-6），
## 而存档读取一度用固定 1% 当下限，于是逐行档存进盘、下次开游戏读回来
## 被抬到 1300 步/秒，玩家会以为档位丢了。下限必须跟着硬件档位走。

var _pass := 0
var _fail := 0

const GameScript := preload("res://scripts/core/game_state.gd")


func _initialize() -> void:
	print("=== 能工智人·数据库 / 存档比例测试 ===\n")

	# ---- 夹取规则本身
	_test("下限随额定速度变化，不是固定值",
		GameScript.clamp_saved_ratio(1e-3, 130000) == 1e-3
			and is_equal_approx(GameScript.clamp_saved_ratio(1e-6, 60), 1.0 / 60.0),
		"C-256 保留 1e-3；C-01 把 1e-6 抬到 1/60=%.4f" % (1.0 / 60.0))
	_test("坏数据抬到下限、上限夹到 1.0",
		is_equal_approx(GameScript.clamp_saved_ratio(0.0, 130000), 1.0 / 130000.0)
			and is_equal_approx(GameScript.clamp_saved_ratio(-5.0, 130000), 1.0 / 130000.0)
			and GameScript.clamp_saved_ratio(2.0, 130000) == 1.0,
		"0 和负值 → 1 步/秒；2.0 → 跑满")

	# ---- 正面用例：逐行档存进盘、读回来还是逐行档
	# tiers 用玩家实际会到达的档位，两个极端各测一次
	var hi = _game_with_cpu(8)   # C-256，额定 130,000 步/秒
	var frame: float = hi.min_cpu_ratio()
	hi.cpu_ratio = GameScript.clamp_saved_ratio(frame, hi.cpu_rate())
	_test("C-256：逐行档读回来仍是逐行档",
		hi.cpu_ratio == frame and hi.is_frame_step(),
		"比例=%s，cpu_speed=%d 步/秒，额定=%d" % [hi.cpu_ratio, hi.cpu_speed(), hi.cpu_rate()])

	var lo = _game_with_cpu(0)   # C-01，额定 60 步/秒
	var frame_lo: float = lo.min_cpu_ratio()
	lo.cpu_ratio = GameScript.clamp_saved_ratio(frame_lo, lo.cpu_rate())
	_test("C-01：逐行档读回来仍是逐行档",
		lo.cpu_ratio == frame_lo and lo.is_frame_step(),
		"比例=%.4f，cpu_speed=%d 步/秒" % [lo.cpu_ratio, lo.cpu_speed()])

	# 坏数据（手改存档 / 旧版本的 0）读回来落在逐行档，而不是某个中间档
	hi.cpu_ratio = GameScript.clamp_saved_ratio(0.0, hi.cpu_rate())
	_test("坏数据读回来落在逐行档",
		hi.is_frame_step(),
		"比例=%s" % hi.cpu_ratio)

	# ---- 老存档照旧：1% 不是逐行档，仍按 1300 步/秒跑
	# （玩家现有的存档就是这个值，改动不该悄悄把它变成逐行档）
	hi.cpu_ratio = GameScript.clamp_saved_ratio(0.01, hi.cpu_rate())
	_test("旧存档的 1% 保持原样、不误判为逐行档",
		hi.cpu_ratio == 0.01 and not hi.is_frame_step() and hi.cpu_speed() == 1300,
		"比例=%.4f，cpu_speed=%d 步/秒" % [hi.cpu_ratio, hi.cpu_speed()])

	print("\n=== 通过 %d / 失败 %d ===" % [_pass, _fail])
	# 这两个是手动 new 出来的 Node，不在场景树里，得自己还回去（否则退出时报泄漏）
	hi.free()
	lo.free()
	quit(1 if _fail > 0 else 0)


## 造一个只用于算比例的状态对象。不进场景树，_ready 不会跑，所以不碰存档文件。
## 返回类型留空（脚本没有 class_name）：调用方拿到的是动态值，属性都按动态访问。
func _game_with_cpu(tier: int):
	var g = GameScript.new()
	g.tiers = {"cpu": tier, "ram": 0, "disk": 0, "psu": 0}
	g.cpu_ratio = 1.0
	return g


func _test(name: String, ok: bool, detail: String) -> void:
	if ok:
		_pass += 1
		print("  [通过] %-26s %s" % [name, detail])
		return
	_fail += 1
	print("  [失败] %-26s %s" % [name, detail])

extends SceneTree
## 门槛余量体检。headless 运行：
##   godot --headless --path <项目> --script res://tests/test_margin.gd
##
## test_balance.gd 用单个种子回答"这一关大概要多少读写"，但它看不到余量：
## 只要门槛落在两个算法的分布重叠区里，就会出现"该过的过不去、该拦的拦不住"
## 的抽签式关卡。这个工具对每一关跑多个随机种子，把每个算法的读写分布
## （最小 / 中位 / 最大）和通过率摆出来，用来判断门槛是否落在真正的空档里。
##
## 分位数是门槛的定值依据：改任何算法的实现或调任何门槛之后，都应该重跑一遍。
## SEEDS 调大结果更稳，代价是更慢（11 关 × 11 个算法 × SEEDS 次运行）。

const SEEDS := 12

## 点名算法通过率低于这个值就在结尾提醒。
## 注意 STAGES 里的 algo 是"课程表"标签而不是硬性要求（阶段 10 的"内省排序"
## 在算法库里根本不存在），所以这里只提醒、不算失败。
const NAMESAKE_WARN := 0.80


func _initialize() -> void:
	print("=== 门槛余量体检（每关 %d 个随机种子）===\n" % SEEDS)

	var script: GDScript = load("res://scripts/core/game_state.gd")
	var lib: Array = script.get_script_constant_map()["LIBRARY"]
	var names := PackedStringArray()
	for e in lib:
		names.append(String(e["name"]).replace(".py", ""))

	var warns: Array = []
	var broke := 0

	print("通过率矩阵（预算内 = 过关）：")
	_header(names)
	print("-".repeat(24 + 7 * names.size()))
	for i in ServerSpec.stage_count():
		var s := ServerSpec.stage(i)
		var n := int(s["n"])
		var budget := int(s["ops"])
		var cells := PackedStringArray()
		var lines: Array = []
		for e in lib:
			var r := _sample(String(e["code"]), n)
			if not r["ok"]:
				broke += 1
				cells.append("%6s" % "失败")
				continue
			var vals: Array = r["ops"]
			vals.sort()
			var passed := 0
			for v in vals:
				if int(v) <= budget:
					passed += 1
			var rate := float(passed) / float(vals.size())
			cells.append("%5.0f%%" % (rate * 100.0))
			lines.append({
				"name": String(e["name"]).replace(".py", ""),
				"lo": int(vals[0]), "mid": _pct(vals, 0.5), "hi": int(vals[-1]),
				"rate": rate,
			})
		print("%-14s %5d %6d %s" % [String(s["name"]), n, budget, " ".join(cells)])
		_check_namesake(String(s["algo"]), lines, budget, warns)

	# ---- 点名算法余量
	print("\n点名算法的余量（最小 / 中位 / 最大，对比预算）：")
	print("阶段        算法        预算     最小     中位     最大    通过率")
	print("-".repeat(64))
	for i in ServerSpec.stage_count():
		var s := ServerSpec.stage(i)
		var algo := String(s["algo"])
		if not names.has(algo):
			continue
		var r := _sample(_code_of(lib, algo), int(s["n"]))
		if not r["ok"]:
			continue
		var vals: Array = r["ops"]
		vals.sort()
		var budget := int(s["ops"])
		var passed := 0
		for v in vals:
			if int(v) <= budget:
				passed += 1
		print("%-10s %-11s %-8d %-8s %-8s %-8s %.0f%%" % [
			String(s["name"]), algo, budget, Prts.comma(int(vals[0])),
			Prts.comma(_pct(vals, 0.5)), Prts.comma(int(vals[-1])),
			100.0 * float(passed) / float(vals.size())])

	if not warns.is_empty():
		print("\n提醒：点名算法在自己的阶段上通过率偏低（门槛可能压在重叠区里）：")
		for w in warns:
			print("  · %s" % String(w))

	print("\n=== 算法实现失败 %d 个；门槛提醒 %d 条 ===" % [broke, warns.size()])
	quit(1 if broke > 0 else 0)


static func _header(names: PackedStringArray) -> void:
	var line := "%-14s %5s %6s" % ["阶段", "规模", "预算"]
	for nm in names:
		line += "%6s" % nm.substr(0, 2)
	print(line)


static func _code_of(lib: Array, algo: String) -> String:
	for e in lib:
		if String(e["name"]).replace(".py", "") == algo:
			return String(e["code"])
	return ""


func _check_namesake(algo: String, lines: Array, budget: int, warns: Array) -> void:
	for l in lines:
		if String(l["name"]) != algo:
			continue
		if float(l["rate"]) < NAMESAKE_WARN:
			warns.append("%s：只要 %.0f%% 的随机数据能过关（%s~%s，中位 %s，预算 %d）" % [
				algo, float(l["rate"]) * 100.0, Prts.comma(int(l["lo"])),
				Prts.comma(int(l["hi"])), Prts.comma(int(l["mid"])), budget])


static func _pct(sorted_vals: Array, q: float) -> int:
	var i := int(round(q * float(sorted_vals.size() - 1)))
	return int(sorted_vals[clampi(i, 0, sorted_vals.size() - 1)])


## 跑 SEEDS 次随机数据，返回每次的读写总量。
func _sample(code: String, n: int) -> Dictionary:
	var parser := PyParser.new()
	var parsed := parser.parse(code)
	if not parsed["ok"]:
		return {"ok": false}
	var comp := PyCompiler.new()
	var compiled := comp.compile(parsed["ast"])
	if not compiled["ok"]:
		return {"ok": false}

	var out: Array = []
	var hi := maxi(20, n)
	for k in SEEDS:
		var rng := RandomNumberGenerator.new()
		rng.seed = 77003 + k * 104729 + n
		var vals: Array = []
		for _i in n:
			vals.append(rng.randi_range(1, hi))

		var arr := PyObjects.PyList.new(vals)
		var vm := PyVM.new()
		vm.setup(compiled, arr, "sort", 1 << 30, 100000 + n * n * 400)
		vm.start()

		var guard := 0
		while vm.run_batch(50000):
			guard += 1
			if guard > 40000:
				return {"ok": false}
		if vm.status == "error":
			return {"ok": false}
		# 顺手确认结果正确，门槛调过头不会掩盖算法本身的错误
		var got: Array = arr.items
		for i in range(1, got.size()):
			if int(got[i - 1]) > int(got[i]):
				return {"ok": false}
		out.append(vm.reads + vm.writes)
	return {"ok": true, "ops": out}
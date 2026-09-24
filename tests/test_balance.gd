extends SceneTree
## 数值平衡体检。headless 运行：
##   godot --headless --path <项目> --script res://tests/test_balance.gd
##
## 回答两个问题：
##   1. 每一关的效率门槛，是否真的卡在"必须换更好的算法"的位置上？
##   2. 收益 / 电费 / 升级成本 三者能否滚得起来？

const ALGOS := [
	["冒泡", "def sort(a):\n    n = len(a)\n    for i in range(n):\n        for j in range(n - 1 - i):\n            if a[j] > a[j + 1]:\n                a[j], a[j + 1] = a[j + 1], a[j]\n    return a\n"],
	["选择", "def sort(a):\n    n = len(a)\n    for i in range(n):\n        m = i\n        for j in range(i + 1, n):\n            if a[j] < a[m]:\n                m = j\n        if m != i:\n            a[i], a[m] = a[m], a[i]\n    return a\n"],
	["插入", "def sort(a):\n    n = len(a)\n    for i in range(1, n):\n        key = a[i]\n        j = i - 1\n        while j >= 0 and a[j] > key:\n            a[j + 1] = a[j]\n            j -= 1\n        a[j + 1] = key\n    return a\n"],
	["快排", "def sort(a):\n    qs(a, 0, len(a) - 1)\n    return a\n\ndef qs(a, lo, hi):\n    if lo >= hi:\n        return\n    p = part(a, lo, hi)\n    qs(a, lo, p - 1)\n    qs(a, p + 1, hi)\n\ndef part(a, lo, hi):\n    pivot = a[hi]\n    i = lo\n    for j in range(lo, hi):\n        if a[j] <= pivot:\n            a[i], a[j] = a[j], a[i]\n            i += 1\n    a[i], a[hi] = a[hi], a[i]\n    return i\n"],
]

## 每关的参考硬件（用来估算耗时与电费）：CPU 等级、整机功率
const REF_CPU := 4       ## C-16 四核，2600 步/秒
const REF_DRAW := 74     ## 8 主板 + 50 CPU + 11 内存 + 5 硬盘


func _initialize() -> void:
	print("=== 数值平衡体检 ===\n")

	var cache := {}
	print("阶段  规模   预算    冒泡      选择      插入      快排     过关所需")
	print("-".repeat(78))

	for i in ServerSpec.stage_count():
		var s := ServerSpec.stage(i)
		var n := int(s["n"])
		var budget := int(s["ops"])
		var cells := PackedStringArray()
		var passing := PackedStringArray()
		for algo in ALGOS:
			var key := "%s:%d" % [algo[0], n]
			if not cache.has(key):
				cache[key] = _run(algo[1], n)
			var r: Dictionary = cache[key]
			if not r["ok"]:
				cells.append("  失败  ")
				continue
			var ops := int(r["reads"]) + int(r["writes"])
			var mark := "✓" if ops <= budget else "✗"
			cells.append("%s%-7s" % [mark, Prts.comma(ops)])
			if ops <= budget:
				passing.append(algo[0])
		var need := "无" if passing.is_empty() else "、".join(passing)
		print("%02d    %-6d %-7d %s %s" % [i + 1, n, budget, " ".join(cells), need])

	# ---- 收益与电费
	print("\n收益 / 电费 / 耗时（参考配置：CPU %d 步/秒，整机 %dW）"
		% [ServerSpec.spec("cpu", REF_CPU)["speed"], REF_DRAW])
	print("阶段  规模   算法   读写      奖励Ð    额外Ð    电费Ð    耗时      净收益Ð")
	print("-".repeat(78))

	for i in ServerSpec.stage_count():
		var s := ServerSpec.stage(i)
		var n := int(s["n"])
		var budget := int(s["ops"])
		var key := "快排:%d" % n
		if not cache.has(key):
			cache[key] = _run(ALGOS[3][1], n)
		var r: Dictionary = cache[key]
		if not r["ok"]:
			continue
		var ops := int(r["reads"]) + int(r["writes"])
		var base := ServerSpec.reward(n, ops)
		var bonus := int(round(float(base) * (ServerSpec.BONUS_MULTIPLIER - 1.0))) if ops <= budget else 0
		var secs := float(r["steps"]) / float(ServerSpec.spec("cpu", REF_CPU)["speed"])
		var bill := ServerSpec.power_bill(REF_DRAW, secs)
		print("%02d    %-6d 快排   %-9s %-8d %-8d %-8.1f %-9s %d" % [
			i + 1, n, Prts.comma(ops), base, bonus, bill,
			"%.1f 秒" % secs, base + bonus - int(round(bill))])

	# ---- 起步节奏
	var r8 := _run(ALGOS[0][1], 8)
	var ops8 := int(r8["reads"]) + int(r8["writes"])
	var g8 := ServerSpec.reward(8, ops8) + int(round(float(ServerSpec.reward(8, ops8)) * 0.5))
	var secs8 := float(r8["steps"]) / 60.0
	var bill8 := ServerSpec.power_bill(23, secs8)
	print("\n起步节奏：第 1 关用冒泡，耗时 %.1f 秒，电费 Ð%.1f，奖励 Ð%d，净赚 Ð%d"
		% [secs8, bill8, g8, g8 - int(round(bill8))])
	for part in ServerSpec.PARTS:
		var cost := ServerSpec.next_cost(part, 0)
		print("  %-6s 首级升级 Ð%-6d 需要约 %d 次第 1 关任务"
			% [part, cost, ceili(float(cost) / float(maxi(1, g8 - int(round(bill8)))))])

	# ---- 硬盘门槛
	print("\n硬盘门槛（起始 512 字节）：")
	for algo in ALGOS:
		var bytes := (algo[1] as String).to_utf8_buffer().size()
		print("  %-5s %4d 字节  %s" % [algo[0], bytes, "可运行" if bytes <= 512 else "需要升级硬盘"])

	quit(0)


func _run(code: String, n: int) -> Dictionary:
	var parser := PyParser.new()
	var parsed := parser.parse(code)
	if not parsed["ok"]:
		return {"ok": false}
	var comp := PyCompiler.new()
	var compiled := comp.compile(parsed["ast"])
	if not compiled["ok"]:
		return {"ok": false}

	var rng := RandomNumberGenerator.new()
	rng.seed = 12345 + n
	var vals: Array = []
	var hi := maxi(20, n)
	for _i in n:
		vals.append(rng.randi_range(1, hi))

	var arr := PyObjects.PyList.new(vals)
	var vm := PyVM.new()
	vm.setup(compiled, arr, "sort", 1 << 30, 100000 + n * n * 200)
	vm.start()

	var guard := 0
	while vm.run_batch(50000):
		guard += 1
		if guard > 20000:
			return {"ok": false}
	if vm.status == "error":
		return {"ok": false}

	return {"ok": true, "reads": vm.reads, "writes": vm.writes, "steps": vm.steps}

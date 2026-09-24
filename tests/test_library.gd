extends SceneTree
## 算法库验证。headless 运行：
##   godot --headless --path <项目> --script res://tests/test_library.gd
##
## 库里每一个算法都要在多个规模上真的把数组排对，否则不能发给玩家。
## 同时打印每个算法的读写量与字节数，方便和阶段预算对照。

const SIZES := [8, 16, 32, 64, 128]


func _initialize() -> void:
	print("=== 算法库验证 ===\n")

	var script: GDScript = load("res://scripts/core/game_state.gd")
	var lib: Array = script.get_script_constant_map()["LIBRARY"]

	var fails := 0
	print("算法              解锁Ð   字节   " + _size_header())
	print("-".repeat(76))

	for entry in lib:
		var name := String(entry["name"]).replace(".py", "")
		var code := String(entry["code"])
		var cost := int(entry["cost"])
		var bytes := code.to_utf8_buffer().size()

		var cells := PackedStringArray()
		var bad := ""
		for n in SIZES:
			var r := _run(code, n)
			if not r["ok"]:
				cells.append("  ✗   ")
				bad = "n=%d：%s" % [n, r["error"]]
				continue
			var ops := int(r["reads"]) + int(r["writes"])
			cells.append("%-6s" % Prts.comma(ops))

		var mark := "  " if bad.is_empty() else "✗ "
		if not bad.is_empty():
			fails += 1
		print("%s%-16s %-8d %-5d %s" % [mark, name, cost, bytes, " ".join(cells)])
		if not bad.is_empty():
			print("      └─ %s" % bad)

	print("\n阶段预算对照（预算值来自 ServerSpec.STAGES）：")
	print("阶段  规模   预算    " + "  ".join(_algo_short_names(lib)))
	print("-".repeat(76))
	for i in ServerSpec.stage_count():
		var s := ServerSpec.stage(i)
		var n := int(s["n"])
		var budget := int(s["ops"])
		var cells := PackedStringArray()
		for entry in lib:
			var r := _run(String(entry["code"]), n)
			if not r["ok"]:
				cells.append("  -   ")
				continue
			var ops := int(r["reads"]) + int(r["writes"])
			cells.append("%s%-5s" % ["✓" if ops <= budget else "✗", Prts.comma(ops)])
		print("%02d    %-6d %-6d %s" % [i + 1, n, budget, " ".join(cells)])

	print("\n=== 失败 %d / 共 %d 个算法 ===" % [fails, lib.size()])
	quit(1 if fails > 0 else 0)


static func _size_header() -> String:
	var parts := PackedStringArray()
	for n in SIZES:
		parts.append("%-6s" % ("n=%d" % n))
	return " ".join(parts)


static func _algo_short_names(lib: Array) -> PackedStringArray:
	var parts := PackedStringArray()
	for e in lib:
		parts.append(String(e["name"]).replace(".py", "").substr(0, 2))
	return parts


func _run(code: String, n: int) -> Dictionary:
	var parser := PyParser.new()
	var parsed := parser.parse(code)
	if not parsed["ok"]:
		var e: Dictionary = parsed["errors"][0]
		return {"ok": false, "error": "第 %d 行 %s" % [e["line"], e["msg"]]}

	var comp := PyCompiler.new()
	var compiled := comp.compile(parsed["ast"])
	if not compiled["ok"]:
		var e2: Dictionary = compiled["errors"][0]
		return {"ok": false, "error": "第 %d 行 %s" % [e2["line"], e2["msg"]]}

	var rng := RandomNumberGenerator.new()
	rng.seed = 777 + n
	var vals: Array = []
	var hi := maxi(20, n)
	for _i in n:
		vals.append(rng.randi_range(1, hi))
	var original := vals.duplicate()

	var arr := PyObjects.PyList.new(vals)
	var vm := PyVM.new()
	# 内存给足，这里只验证算法正确性，不验证资源门槛
	vm.setup(compiled, arr, "sort", 1 << 30, 100000 + n * n * 400)
	vm.start()

	var guard := 0
	while vm.run_batch(50000):
		guard += 1
		if guard > 40000:
			return {"ok": false, "error": "超时（疑似死循环）"}

	if vm.status == "error":
		return {"ok": false, "error": "第 %d 行 %s" % [vm.error["line"], vm.error["msg"]]}

	var out: Array = arr.items
	for i in range(1, out.size()):
		if int(out[i - 1]) > int(out[i]):
			return {"ok": false, "error": "结果没有排好序"}

	var expected := original.duplicate()
	expected.sort()
	if out != expected:
		return {"ok": false, "error": "元素被改动或丢失"}

	return {"ok": true, "reads": vm.reads, "writes": vm.writes, "steps": vm.steps}

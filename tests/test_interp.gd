extends SceneTree
## 解释器冒烟测试。headless 运行：
##   godot --headless --path <项目> --script res://tests/test_interp.gd
##
## 覆盖：四种排序算法（含递归与辅助数组）、错误路径、可视化埋点。

var _pass := 0
var _fail := 0


func _initialize() -> void:
	print("=== 能工智人·数据库 / 解释器测试 ===\n")

	_test("冒泡排序", BUBBLE)
	_test("选择排序", SELECTION)
	_test("插入排序", INSERTION)
	_test("快速排序（递归+辅助函数）", QUICK)
	_test("归并排序（递归+辅助数组）", MERGE)

	_test_expr("基础表达式与运算", "def sort(a):\n    x = 2 + 3 * 4\n    y = 10 // 3\n    z = 10 % 3\n    w = 2 ** 5\n    print(x, y, z, w)\n    return a\n", ["x=14", "y=3", "z=1", "w=32"])
	_test_expr("布尔与链式比较", "def sort(a):\n    n = len(a)\n    ok = 1 < 2 < 3\n    bad = 1 < 2 > 5\n    print(ok, bad)\n    return a\n", ["ok=True", "bad=False"])
	_test_expr("负数下标", "def sort(a):\n    print(a[-1], a[-2])\n    return a\n", [])

	_test_error("未定义变量", "def sort(a):\n    return q\n", "还没有定义")
	_test_error("下标越界", "def sort(a):\n    return a[999]\n", "越界")
	_test_error("禁用内置排序", "def sort(a):\n    a.sort()\n    return a\n", "禁用了内置排序")
	_test_error("不支持的语法 import", "import os\ndef sort(a):\n    return a\n", "模块系统")
	_test_error("死循环", "def sort(a):\n    while True:\n        pass\n", "死循环")

	# 循环体里提前 return：栈是各帧共用的，返回时若不收回本帧留下的东西，
	# 循环的迭代器会漏给调用方，下一次调用就会拿它当函数用（曾经真的这么炸）。
	# 断言按**下标**写，不依赖 _make_array 生成的具体数值。
	_test_log("for 里提前 return",
		"def hit(a, n):\n    for i in range(len(a)):\n        if i == n:\n            return i * 10\n    return -1\ndef sort(a):\n    print(hit(a, 3), hit(a, 99))\n    return a\n",
		"30 -1")
	_test_log("while 里提前 return",
		"def hit(a, n):\n    i = len(a) - 1\n    while i >= 0:\n        if i == n:\n            return i * 10\n        i -= 1\n    return -1\ndef sort(a):\n    print(hit(a, 3), hit(a, 99))\n    return a\n",
		"30 -1")
	# 提前 return 之后调用方还要继续用栈上的东西，别被顺手清掉
	_test_log("提前 return 后调用方继续运算",
		"def hit(a, n):\n    for i in range(len(a)):\n        if i == n:\n            return 1\n    return 0\ndef sort(a):\n    print(hit(a, 3) + hit(a, 99) * 10)\n    return a\n",
		"1")

	# random 模块
	_test_permutation("random.shuffle 只重排不换元素",
		"def sort(a):\n    random.shuffle(a)\n    return a\n")
	_test_shuffle_events("random.shuffle 有读有写有移动",
		"def sort(a):\n    random.shuffle(a)\n    return a\n")
	_test_log("random.seed 可复现",
		"def sort(a):\n    random.seed(7)\n    x = random.randint(1, 1000000)\n    random.seed(7)\n    y = random.randint(1, 1000000)\n    random.seed(8)\n    z = random.randint(1, 1000000)\n    print(x == y, x != z)\n    return a\n",
		"True True")
	_test_error("random 不存在的成员",
		"def sort(a):\n    random.nope(a)\n    return a\n", "random 没有方法")
	_test_error("shuffle 要数组",
		"def sort(a):\n    random.shuffle(3)\n    return a\n", "shuffle() 需要 1 个参数")

	_test_events("可视化埋点", BUBBLE)
	_test_moves("冒泡：每次交换 = 2 次移动", BUBBLE, 2, true)
	_test_moves("选择：每次交换 = 2 次移动", SELECTION, 2, true)
	# 插入排序的"元素本来就在原位、写回自己"不算移动，所以只能要求 moves <= writes
	_test_moves("插入：右移记 1 次移动", INSERTION, 1, false)
	_test_ram_bytes("内存按字节计", BUBBLE)

	print("\n=== 通过 %d / 失败 %d ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


# ---------------------------------------------------------------- 用例

const BUBBLE := "def sort(a):\n    n = len(a)\n    for i in range(n):\n        for j in range(n - 1 - i):\n            if a[j] > a[j + 1]:\n                a[j], a[j + 1] = a[j + 1], a[j]\n    return a\n"

const SELECTION := "def sort(a):\n    n = len(a)\n    for i in range(n):\n        m = i\n        for j in range(i + 1, n):\n            if a[j] < a[m]:\n                m = j\n        if m != i:\n            a[i], a[m] = a[m], a[i]\n    return a\n"

const INSERTION := "def sort(a):\n    n = len(a)\n    for i in range(1, n):\n        key = a[i]\n        j = i - 1\n        while j >= 0 and a[j] > key:\n            a[j + 1] = a[j]\n            j -= 1\n        a[j + 1] = key\n    return a\n"

const QUICK := "def sort(a):\n    qs(a, 0, len(a) - 1)\n    return a\n\ndef qs(a, lo, hi):\n    if lo >= hi:\n        return\n    p = part(a, lo, hi)\n    qs(a, lo, p - 1)\n    qs(a, p + 1, hi)\n\ndef part(a, lo, hi):\n    pivot = a[hi]\n    i = lo\n    for j in range(lo, hi):\n        if a[j] <= pivot:\n            a[i], a[j] = a[j], a[i]\n            i += 1\n    a[i], a[hi] = a[hi], a[i]\n    return i\n"

const MERGE := "def sort(a):\n    n = len(a)\n    if n <= 1:\n        return a\n    mid = n // 2\n    left = []\n    right = []\n    for i in range(mid):\n        left.append(a[i])\n    for i in range(mid, n):\n        right.append(a[i])\n    sort(left)\n    sort(right)\n    i = 0\n    j = 0\n    k = 0\n    while i < len(left) and j < len(right):\n        if left[i] <= right[j]:\n            a[k] = left[i]\n            i += 1\n        else:\n            a[k] = right[j]\n            j += 1\n        k += 1\n    while i < len(left):\n        a[k] = left[i]\n        i += 1\n        k += 1\n    while j < len(right):\n        a[k] = right[j]\n        j += 1\n        k += 1\n    return a\n"


func _test(name: String, code: String, n := 24) -> void:
	var data := _make_array(n)
	var r := _run(code, data)
	if not r["ok"]:
		_fail += 1
		print("  [失败] %s —— %s" % [name, r["error"]])
		return
	var sorted_data: Array = r["array"]
	if not _is_sorted(sorted_data):
		_fail += 1
		print("  [失败] %s —— 结果没有排好序：%s" % [name, str(sorted_data)])
		return
	# 排序必须是原地置换：元素集合要和原数组一致，不能凭空多出或丢掉元素
	var expected := data.duplicate()
	expected.sort()
	if sorted_data != expected:
		_fail += 1
		print("  [失败] %s —— 元素被改动或丢失" % name)
		return
	_pass += 1
	print("  [通过] %-22s 步数=%-8d 比较=%-7d 读写=%-7d" % [
		name, r["steps"], r["comparisons"], r["reads"] + r["writes"]])


func _test_expr(name: String, code: String, _checks: Array) -> void:
	var data := _make_array(8)
	var r := _run(code, data)
	if not r["ok"]:
		_fail += 1
		print("  [失败] %s —— %s" % [name, r["error"]])
		return
	_pass += 1
	print("  [通过] %-22s 输出=%s" % [name, str(r["log"])])


## 洗牌类操作的回归：结果必须是原数组的一个**排列**（元素一个不少、且真的打乱）。
func _test_permutation(name: String, code: String) -> void:
	var data := _make_array(10)
	var r := _run(code, data)
	if not r["ok"]:
		_fail += 1
		print("  [失败] %s —— %s" % [name, r["error"]])
		return
	var want := data.duplicate()
	want.sort()
	var got := (r["array"] as Array).duplicate()
	got.sort()
	if got != want:
		_fail += 1
		print("  [失败] %s —— 元素变了（洗牌只能重排，不能换元素）" % name)
		return
	if r["array"] == data:
		_fail += 1
		print("  [失败] %s —— 洗了和没洗一样" % name)
		return
	_pass += 1
	print("  [通过] %-22s 10 个元素洗成排列" % name)


## 洗牌必须走带埋点的通道：有读、有写、有移动事件——可视化与效率预算才看得见它。
func _test_shuffle_events(name: String, code: String) -> void:
	var data := _make_array(10)
	var parser := PyParser.new()
	var parsed := parser.parse(code)
	var comp := PyCompiler.new()
	var compiled := comp.compile(parsed["ast"])
	var arr := PyObjects.PyList.new(data)
	var vm := PyVM.new()
	vm.setup(compiled, arr, "sort", 100000, 4000000)
	vm.start()
	var ev := {}
	while vm.run_batch(4000):
		for e in vm.drain_events():
			ev[e["t"]] = int(ev.get(e["t"], 0)) + 1
	for e in vm.drain_events():
		ev[e["t"]] = int(ev.get(e["t"], 0)) + 1
	if vm.status == "error":
		_fail += 1
		print("  [失败] %s —— %s" % [name, vm.error["msg"]])
		return
	var reads := int(ev.get("read", 0))
	var writes := int(ev.get("write", 0))
	var moves := int(ev.get("move", 0))
	if reads <= 0 or writes <= 0 or moves <= 0:
		_fail += 1
		print("  [失败] %s —— 洗牌没有产出读/写/移动：%s" % [name, str(ev)])
		return
	_pass += 1
	print("  [通过] %-22s 读=%d 写=%d 移动=%d" % [name, reads, writes, moves])


## 断言 print 出来的内容（用 " " 连接）。比只断言"跑得通"更能抓住返回值错乱的问题。
func _test_log(name: String, code: String, expected: String) -> void:
	var r := _run(code, _make_array(8))
	if not r["ok"]:
		_fail += 1
		print("  [失败] %s —— %s" % [name, r["error"]])
		return
	var got: String = " ".join(PackedStringArray(r["log"]))
	if got != expected:
		_fail += 1
		print("  [失败] %s —— 期望 '%s'，实际 '%s'" % [name, expected, got])
		return
	_pass += 1
	print("  [通过] %-22s 输出=%s" % [name, got])


func _test_error(name: String, code: String, needle: String) -> void:
	var r := _run(code, _make_array(8))
	if r["ok"]:
		_fail += 1
		print("  [失败] %s —— 本应报错，却跑完了" % name)
		return
	if not String(r["error"]).contains(needle):
		_fail += 1
		print("  [失败] %s —— 错误信息不含 '%s'，实际：%s" % [name, needle, r["error"]])
		return
	_pass += 1
	print("  [通过] %-22s 正确拦截：%s" % [name, r["error"]])


func _test_events(name: String, code: String) -> void:
	var data := _make_array(12)
	var parser := PyParser.new()
	var parsed := parser.parse(code)
	var comp := PyCompiler.new()
	var compiled := comp.compile(parsed["ast"])
	var arr := PyObjects.PyList.new(data)
	var vm := PyVM.new()
	vm.setup(compiled, arr, "sort", 100000, 4000000)
	vm.start()
	var ev := {}
	while vm.run_batch(4000):
		for e in vm.drain_events():
			ev[e["t"]] = int(ev.get(e["t"], 0)) + 1
	for e in vm.drain_events():
		ev[e["t"]] = int(ev.get(e["t"], 0)) + 1
	if int(ev.get("cmp", 0)) <= 0 or int(ev.get("write", 0)) <= 0 or int(ev.get("read", 0)) <= 0:
		_fail += 1
		print("  [失败] %s —— 埋点事件不足：%s" % [name, str(ev)])
		return
	_pass += 1
	print("  [通过] %-22s 事件=%s" % [name, str(ev)])


## 移动事件是可视化动画的唯一数据来源，必须严格验证：
##   · 每条移动的 from/to 都合法且不相同
##   · 移动次数不能多于写入次数
##   · strict 时要求 moves == writes：交换类算法的每一次写入都是真实搬运
##     （插入排序不满足，因为"元素本来就在原位、写回自己"确实没有移动）
func _test_moves(name: String, code: String, per_op: int, strict: bool) -> void:
	var n := 20
	var data := _make_array(n)
	var parser := PyParser.new()
	var parsed := parser.parse(code)
	if not parsed["ok"]:
		_fail += 1
		print("  [失败] %s —— 语法错误" % name)
		return
	var comp := PyCompiler.new()
	var compiled := comp.compile(parsed["ast"])
	if not compiled["ok"]:
		_fail += 1
		print("  [失败] %s —— 编译错误" % name)
		return

	var arr := PyObjects.PyList.new(data)
	var vm := PyVM.new()
	vm.setup(compiled, arr, "sort", 1 << 30, 4000000)
	vm.start()

	var moves := 0
	var writes := 0
	var bad := 0
	while vm.run_batch(4000):
		for e in vm.drain_events():
			match String(e["t"]):
				"move":
					moves += 1
					var f := int(e["from"])
					var t := int(e["to"])
					if f == t or f < 0 or t < 0 or f >= n or t >= n:
						bad += 1
				"write":
					writes += 1
	for e in vm.drain_events():
		match String(e["t"]):
			"move":
				moves += 1
			"write":
				writes += 1

	if bad > 0:
		_fail += 1
		print("  [失败] %s —— 有 %d 条移动事件的下标非法" % [name, bad])
		return
	if moves <= 0:
		_fail += 1
		print("  [失败] %s —— 一条移动事件都没产生" % [name])
		return
	if moves % per_op != 0:
		_fail += 1
		print("  [失败] %s —— 移动 %d 次，不是每次操作 %d 次的整数倍" % [name, moves, per_op])
		return
	if strict and moves != writes:
		_fail += 1
		print("  [失败] %s —— 移动 %d 次 ≠ 写入 %d 次，说明有写入没被识别成移动"
			% [name, moves, writes])
		return
	if moves > writes:
		_fail += 1
		print("  [失败] %s —— 移动 %d 次多于写入 %d 次" % [name, moves, writes])
		return
	_pass += 1
	var extra := "" if strict else "（%d 次原地写回未计为移动）" % (writes - moves)
	print("  [通过] %-22s 移动=%-5d 写入=%-5d%s" % [name, moves, writes, extra])


## 内存以字节计：每个数字（含数组元素与变量引用）8 字节
func _test_ram_bytes(name: String, code: String) -> void:
	var n := 16
	var parser := PyParser.new()
	var parsed := parser.parse(code)
	var comp := PyCompiler.new()
	var compiled := comp.compile(parsed["ast"])
	var arr := PyObjects.PyList.new(_make_array(n))
	var vm := PyVM.new()
	vm.setup(compiled, arr, "sort", 1 << 30, 4000000)
	vm.start()

	var peak := 0
	while vm.run_batch(2000):
		peak = maxi(peak, vm.ram_usage())
	peak = maxi(peak, vm.ram_usage())

	if peak < n * 8:
		_fail += 1
		print("  [失败] %s —— 峰值 %d 字节，连数组本身（%d 字节）都不够" % [name, peak, n * 8])
		return
	if peak % 8 != 0:
		_fail += 1
		print("  [失败] %s —— 峰值 %d 不是 8 的整数倍" % [name, peak])
		return
	_pass += 1
	print("  [通过] %-22s 峰值内存=%d 字节（数组本身 %d 字节）" % [name, peak, n * 8])


# ---------------------------------------------------------------- 工具
func _run(code: String, data: Array) -> Dictionary:
	var parser := PyParser.new()
	var parsed := parser.parse(code)
	if not parsed["ok"]:
		return {"ok": false, "error": _fmt(parsed["errors"])}

	var comp := PyCompiler.new()
	var compiled := comp.compile(parsed["ast"])
	if not compiled["ok"]:
		return {"ok": false, "error": _fmt(compiled["errors"])}

	var arr := PyObjects.PyList.new(data.duplicate())
	var vm := PyVM.new()
	vm.setup(compiled, arr, "sort", 100000, 4000000)
	vm.start()

	var guard := 0
	while vm.run_batch(20000):
		guard += 1
		if guard > 5000:
			return {"ok": false, "error": "测试自身超时"}

	if vm.status == "error":
		return {"ok": false, "error": "第 %d 行：%s" % [vm.error["line"], vm.error["msg"]]}

	return {
		"ok": true,
		"array": arr.items,
		"steps": vm.steps,
		"comparisons": vm.comparisons,
		"reads": vm.reads,
		"writes": vm.writes,
		"log": vm.log_lines,
	}


func _fmt(errors: Array) -> String:
	var parts := PackedStringArray()
	for e in errors:
		parts.append("第 %d 行：%s" % [e["line"], e["msg"]])
	return " / ".join(parts)


func _make_array(n: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20240924
	var a: Array = []
	for i in n:
		a.append(i + 1)
	for i in range(n - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t: Variant = a[i]
		a[i] = a[j]
		a[j] = t
	return a


static func _is_sorted(a: Array) -> bool:
	for i in range(1, a.size()):
		if a[i - 1] > a[i]:
			return false
	return true

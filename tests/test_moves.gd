extends SceneTree
## 移动埋点在"重复值"下的体检。headless 运行：
##   godot --headless --path <项目> --script res://tests/test_moves.gd
##
## 背景：py_vm 用"值 -> 最近一次出现的下标"（_prov）推断元素从哪儿搬到了哪儿。
## 插入排序会把元素先存进变量、再写回数组，中间隔着跳转，只有用值做键才追得到，
## 所以这个设计是刻意的（见 py_vm.gd 里 _prov 的说明）。代价是数组里有重复值时，
## 来源下标可能指向另一个等值元素。
##
## 既有的 test_interp.gd 用的是"1..n 的排列"，一个重复值都没有，正好绕开了这个
## 风险；而游戏真实生成的题目刻意带大量重复值（randi_range(1, max(20, n))）。
##
## 这里用一个镜像数组跟住每一次写入，把每条 move 事件拿去核对三件事：
##
##   1) 有根：来源下标必须是这个值真的被读到/写到过的地方。
##      这是唯一一条"不该被打破"的不变量——它保证动画不会凭空捏造出发点。
##   2) 合法：下标在范围内、from ≠ to、移动次数不超过写入次数。
##   3) 来源槽此刻是否已经放了别的值（记作"已刷新"）。
##      这条**不是**缺陷指标，只是诊断读数，原因见下：
##        · 交换 a[i], a[j] = a[j], a[i] 会产生两条移动，第二条发出时
##          伙伴的那次写入已经把来源槽刷新了 —— 所以交换族的比值恒为 50%，
##          和有没有重复值无关。
##        · 提起-写回族（插入/希尔/归并）的元素先被提到变量或临时数组里，
##          原槽随后被移位覆盖，比值随算法而变。
##      真正会出问题的是它**失控**（比如来源永远指向"上一次写入的下标"，
##      比值会顶到 100%），所以这里只设一个宽松上限当回归闸门。

const MAX_STEPS := 4000000

## 交换族：每次操作两条移动，第二条的来源槽必然已被伙伴写入刷新
const SWAP_FAMILY := ["冒泡排序", "选择排序", "鸡尾酒排序", "梳排序",
	"快速排序", "三路快排", "堆排序"]
## 排列数据下"移动 == 写入"必须成立的算法（无原地自交换、无提起-写回）
const STRICT_FAMILY := ["冒泡排序", "选择排序", "鸡尾酒排序", "梳排序"]
## 已刷新比例的回归上限。交换族的结构下限就是 50%，留一点余量。
const REFILLED_LIMIT := 0.60

## 数据形态
const MODE_DUP := 0      ## 游戏真实分布：值域 1..max(20, n)
const MODE_TWO := 1      ## 只有两种取值
const MODE_FLAT := 2     ## 全部相同
const MODE_PERM := 3     ## 1..n 的排列（无重复值）

var _pass := 0
var _fail := 0


func _initialize() -> void:
	print("=== 移动埋点 / 重复值体检 ===\n")

	var script: GDScript = load("res://scripts/core/game_state.gd")
	var lib: Array = script.get_script_constant_map()["LIBRARY"]

	_section("大量重复值（游戏真实分布）", MODE_DUP, 32)
	_section("只有两种取值（等值元素最易互相冒名）", MODE_TWO, 32)
	_section("全部相同（极端：谁都不需要搬）", MODE_FLAT, 12)
	_section("无重复值的排列（对照：test_interp 用的形态）", MODE_PERM, 32)

	print("\n=== 通过 %d / 失败 %d ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _section(title: String, mode: int, n: int) -> void:
	print("\n---- %s" % title)
	print("算法        读      写      移动    无根   已刷新   越界   判定")
	print("-".repeat(72))

	var script: GDScript = load("res://scripts/core/game_state.gd")
	var lib: Array = script.get_script_constant_map()["LIBRARY"]
	for entry in lib:
		var name := String(entry["name"]).replace(".py", "")
		var vals := _make_data(n, mode, String(entry["name"]).length())
		var r := _trace(String(entry["code"]), vals)
		if not String(r["error"]).is_empty():
			_fail += 1
			print("%-10s 运行失败：%s" % [name, r["error"]])
			continue

		var verdict := _judge(name, mode, r)
		if verdict.begins_with("[通过]"):
			_pass += 1
		var moves := int(r["moves"])
		var ratio := 0.0 if moves == 0 else float(r["refilled"]) / float(moves)
		print("%-10s %-7s %-7s %-7s %-6s %-8s %-6s %s" % [
			name, Prts.comma(int(r["reads"])), Prts.comma(int(r["writes"])),
			Prts.comma(moves), Prts.comma(int(r["unrooted"])),
			"%.0f%%" % (ratio * 100.0), Prts.comma(int(r["bad"])), verdict])


func _judge(name: String, mode: int, r: Dictionary) -> String:
	if not bool(r["sorted"]) or not bool(r["same_multiset"]):
		_fail += 1
		return "[失败] 排序结果不对"

	if int(r["bad"]) > 0:
		_fail += 1
		return "[失败] 有 %d 条移动的下标非法或原地打转" % int(r["bad"])
	if int(r["unrooted"]) > 0:
		_fail += 1
		return "[失败] 有 %d 条移动的来源下标从未持有过该值" % int(r["unrooted"])

	var moves := int(r["moves"])
	var writes := int(r["writes"])
	if moves > writes:
		_fail += 1
		return "[失败] 移动 %d 次多于写入 %d 次" % [moves, writes]

	var ratio := 0.0 if moves == 0 else float(r["refilled"]) / float(moves)
	if ratio > REFILLED_LIMIT:
		_fail += 1
		return "[失败] 已刷新比例 %.0f%% 超过上限 %.0f%%" % [
			ratio * 100.0, REFILLED_LIMIT * 100.0]

	# 排列数据 + 纯交换算法：每次写入都必须是真实搬运
	if mode == MODE_PERM and STRICT_FAMILY.has(name):
		if moves != writes:
			_fail += 1
			return "[失败] 移动 %d ≠ 写入 %d" % [moves, writes]
		return "[通过] 移动 == 写入"

	if moves == 0:
		return "[通过] 无移动"

	if SWAP_FAMILY.has(name):
		return "[通过] 交换族上限 50%（第二条移动的来源已被伙伴写入刷新）"
	return "[通过] 提起-写回：来源被移位覆盖属预期"


# ---------------------------------------------------------------- 追踪

## 跑一遍算法，同时用镜像数组跟住每次写入，逐条核对 move 事件。
func _trace(code: String, vals: Array) -> Dictionary:
	var out := {
		"reads": 0, "writes": 0, "moves": 0, "refilled": 0, "unrooted": 0,
		"bad": 0, "sorted": false, "same_multiset": false, "error": "",
	}

	var parser := PyParser.new()
	var parsed := parser.parse(code)
	if not parsed["ok"]:
		out["error"] = "语法错误"
		return out
	var comp := PyCompiler.new()
	var compiled := comp.compile(parsed["ast"])
	if not compiled["ok"]:
		out["error"] = "编译错误"
		return out

	var arr := PyObjects.PyList.new(vals.duplicate())
	var vm := PyVM.new()
	vm.setup(compiled, arr, "sort", 1 << 30, MAX_STEPS)
	vm.start()

	var mirror: Array = vals.duplicate()
	## "下标|值" -> 这个值确实在这个下标上被读到/写到过
	var rooted := {}
	var n := vals.size()
	var guard := 0
	while true:
		var running := vm.run_batch(4000)
		_consume(vm.drain_events(), mirror, rooted, n, out)
		if not running:
			break
		guard += 1
		if guard > 40000:
			out["error"] = "超时（疑似死循环）"
			return out
	_consume(vm.drain_events(), mirror, rooted, n, out)

	if vm.status == "error":
		out["error"] = "第 %d 行 %s" % [vm.error["line"], vm.error["msg"]]
		return out

	var got: Array = arr.items
	out["sorted"] = _is_sorted(got)
	var a := got.duplicate()
	var b: Array = vals.duplicate()
	a.sort()
	b.sort()
	out["same_multiset"] = a == b
	return out


func _consume(events: Array, mirror: Array, rooted: Dictionary, n: int,
		out: Dictionary) -> void:
	for e in events:
		match String(e.get("t", "")):
			"read":
				out["reads"] = int(out["reads"]) + 1
				rooted[_key(int(e["i"]), e["v"])] = true
			"write":
				out["writes"] = int(out["writes"]) + 1
				mirror[int(e["i"])] = e["v"]
				rooted[_key(int(e["i"]), e["v"])] = true
			"move":
				out["moves"] = int(out["moves"]) + 1
				var f := int(e["from"])
				var t := int(e["to"])
				var v: Variant = e["v"]
				if f < 0 or t < 0 or f >= n or t >= n or f == t:
					out["bad"] = int(out["bad"]) + 1
					continue
				# 1) 有根：这个值确实在 from 上出现过
				if not rooted.has(_key(f, v)):
					out["unrooted"] = int(out["unrooted"]) + 1
				# 3) 诊断：来源槽此刻是不是已经放了别的值
				if int(mirror[f]) != int(v):
					out["refilled"] = int(out["refilled"]) + 1


static func _key(i: int, v: Variant) -> String:
	return "%d|%d" % [i, int(v)]


# ---------------------------------------------------------------- 数据

func _make_data(n: int, mode: int, salt: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210 + n * 131 + salt
	var out: Array = []
	match mode:
		MODE_TWO:
			for _i in n:
				out.append(5 if rng.randf() < 0.5 else 9)
		MODE_FLAT:
			for _i in n:
				out.append(7)
		MODE_PERM:
			for i in n:
				out.append(i + 1)
			for i in range(n - 1, 0, -1):
				var j := rng.randi_range(0, i)
				var t: Variant = out[i]
				out[i] = out[j]
				out[j] = t
		_:
			# 和 main.gd 及各测试一致：值域 1..max(20, n)
			var hi := maxi(20, n)
			for _i in n:
				out.append(rng.randi_range(1, hi))
	return out


static func _is_sorted(a: Array) -> bool:
	for i in range(1, a.size()):
		if int(a[i - 1]) > int(a[i]):
			return false
	return true
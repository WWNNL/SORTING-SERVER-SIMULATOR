class_name PyVM
extends RefCounted
## 虚拟服务器上的 Python 子集执行器。
##
## 设计要点：执行是"可暂停的"——run_batch() 一次只跑固定条数的指令就返回，
## 于是 CPU 速度 = 每秒允许执行多少条指令，暂停 = 停止取指，单步 = 预算给 1。
## 同时它对目标数组的每一次读写做埋点，产出可视化事件。

const BUILTIN_NAMES := [
	"len", "range", "min", "max", "abs", "int", "float", "str", "bool",
	"print", "sum", "list",
]

## 数组方法白名单。刻意不提供 sort / sorted —— 那是游戏的核心禁令。
const LIST_METHODS := [
	"append", "pop", "insert", "remove", "index", "count",
	"reverse", "extend", "copy", "clear",
]

const MAX_CALL_DEPTH := 128

var module_code: Array = []
var functions: Dictionary = {}
var globals: Dictionary = {}
var frames: Array = []
var stack: Array = []

## random 模块的值（一个带标记的字典）。玩家写 random.shuffle(a)、
## random.randint(lo, hi)、random.seed(n)。放进 globals，玩家可以自己改掉它（标准行为）。
## 随机数由 VM 私有的 _rng 提供，每次 setup 重新随机，保证每局都不同。
var random_module: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var builtins: Dictionary = {}

var status := "ready"  ## ready / running / done / error
var error := {"line": 0, "msg": ""}
var halted_reason := ""

var steps := 0
var comparisons := 0
var reads := 0
var writes := 0
var max_steps := 4000000

var target: PyObjects.PyList = null
var ram_limit := 0

var events: Array = []
var log_lines: Array = []
## 最近读过的 (下标, 值)。用于推断"这个元素被搬到哪儿去了"：
## 交换是"先读两处、再写两处"，把读到的值和写入的值对上，就知道谁搬到了谁的位置。
var recent_reads: Array = []
## 值 -> 它最近一次是从哪个下标读出来的。用于判断"这个元素搬到了哪里"。
## 之所以不只用 recent_reads：插入排序会把元素先存进变量 key，再写回数组，
## 中间隔着跳转，靠"最近读过什么"是追不到的。用值做键就能穿过变量中转。
var _prov: Dictionary = {}

const READ_WINDOW := 6


func _init() -> void:
	for b in BUILTIN_NAMES:
		builtins[b] = PyObjects.PyBuiltin.new(b)


## 装配一次运行：把模块指令装好，并生成一段引导代码去调用玩家的排序函数。
func setup(compiled: Dictionary, arr: PyObjects.PyList, entry: String,
		ram_cap: int, step_cap: int) -> void:
	module_code = compiled["code"]
	functions = compiled["functions"]
	globals = {}
	# 每次运行重新掷一次种子：同一段代码两局的结果不一样
	_rng.randomize()
	globals["random"] = random_module
	stack = []
	frames = []
	events = []
	log_lines = []
	recent_reads = []
	_prov = {}
	steps = 0
	comparisons = 0
	reads = 0
	writes = 0
	status = "ready"
	error = {"line": 0, "msg": ""}
	halted_reason = ""

	target = arr
	target.is_target = true
	ram_limit = ram_cap
	max_steps = step_cap

	# 模块代码必须先跑完（这样 def 才会执行、函数才会进入全局作用域），
	# 然后接上引导序列去调用玩家的排序函数。早期版本直接丢弃模块代码，
	# 结果 sort 永远是未定义的。
	var boot: Array = module_code.duplicate()
	if not boot.is_empty() and String((boot[-1] as Dictionary)["op"]) == "HALT":
		boot.pop_back()
	boot.append({"op": "LOAD", "a": entry, "b": null, "line": 0})
	boot.append({"op": "CONST", "a": arr, "b": null, "line": 0})
	boot.append({"op": "CALL", "a": 1, "b": null, "line": 0})
	boot.append({"op": "POP", "a": null, "b": null, "line": 0})
	boot.append({"op": "HALT", "a": null, "b": null, "line": 0})
	module_code = boot


func start() -> void:
	frames = [{
		"code": module_code, "pc": 0, "scope": globals, "temps": [], "name": "<模块>",
		"base": 0,
	}]
	status = "running"


func drain_events() -> Array:
	var e := events
	events = []
	return e


func current_line() -> int:
	if frames.is_empty():
		return 0
	var f: Dictionary = frames[-1]
	var c: Array = f["code"]
	var pc: int = f["pc"]
	if pc > 0 and pc - 1 < c.size():
		return int((c[pc - 1] as Dictionary).get("line", 0))
	return 0


func call_depth() -> int:
	return frames.size()


# ---------------------------------------------------------------- 执行循环

## 最多执行 budget 条指令。返回 true 表示还在运行。
func run_batch(budget: int) -> bool:
	if status != "running":
		return false

	var done := 0
	while done < budget:
		if status != "running":
			break
		if frames.is_empty():
			status = "done"
			halted_reason = "程序结束"
			break

		var f: Dictionary = frames[-1]
		var c: Array = f["code"]
		var pc: int = f["pc"]

		if pc >= c.size():
			_do_return(null)
			done += 1
			continue

		var ins: Dictionary = c[pc]
		f["pc"] = pc + 1
		_exec(ins, f)
		# 语句/控制流边界处清空读窗口。交换是"先读两处、再写两处"，
		# 读写之间不会夹着跳转，所以按跳转切分既能保住同一条语句里的读写配对，
		# 又能避免跨迭代的陈旧读值造成假的"元素移动"。
		match String(ins["op"]):
			"STORE", "POP", "JUMP", "JUMP_FALSE", "JUMP_TRUE_KEEP", "JUMP_FALSE_KEEP", "FOR_ITER":
				recent_reads.clear()
		steps += 1
		done += 1

		if steps > max_steps:
			_fail("运行步数超过上限（%d 步），疑似死循环" % max_steps, int(ins.get("line", 0)))
			break

	return status == "running"


func _exec(ins: Dictionary, f: Dictionary) -> void:
	var line: int = ins.get("line", 0)

	match String(ins["op"]):
		"CONST":
			stack.append(ins["a"])

		"LOAD":
			var name := String(ins["a"])
			var sc: Dictionary = f["scope"]
			if sc.has(name):
				stack.append(sc[name])
			elif globals.has(name):
				stack.append(globals[name])
			elif builtins.has(name):
				stack.append(builtins[name])
			else:
				_fail("变量 '%s' 还没有定义就被使用了" % name, line)

		"STORE":
			if stack.is_empty():
				_fail("内部错误：赋值时栈是空的", line)
				return
			var name := String(ins["a"])
			var v: Variant = stack.pop_back()
			(f["scope"] as Dictionary)[name] = v
			recent_reads.clear()
			_check_ram(line)
		"LOAD_TMP":
			var t: Array = f["temps"]
			var k: int = ins["a"]
			if k < 0 or k >= t.size():
				_fail("内部错误：临时槽越界", line)
				return
			stack.append(t[k])

		"STORE_TMP":
			if stack.is_empty():
				_fail("内部错误：暂存时栈是空的", line)
				return
			var t: Array = f["temps"]
			var k: int = ins["a"]
			while t.size() <= k:
				t.append(null)
			t[k] = stack.pop_back()

		"POP":
			if not stack.is_empty():
				stack.pop_back()

		"BINOP":
			if stack.size() < 2:
				_fail("内部错误：运算数不足", line)
				return
			var r: Variant = stack.pop_back()
			var l: Variant = stack.pop_back()
			var res: Variant = _binop(l, r, String(ins["a"]), line)
			if status != "running":
				return
			stack.append(res)

		"UNARY":
			if stack.is_empty():
				_fail("内部错误：运算数不足", line)
				return
			var v: Variant = stack.pop_back()
			var res: Variant = _unary(v, String(ins["a"]), line)
			if status != "running":
				return
			stack.append(res)

		"CMP":
			if stack.size() < 2:
				_fail("内部错误：比较运算数不足", line)
				return
			var r: Variant = stack.pop_back()
			var l: Variant = stack.pop_back()
			comparisons += 1
			var res: Variant = _compare(l, r, String(ins["a"]), line)
			if status != "running":
				return
			if target != null and not recent_reads.is_empty():
				# 只取最近两次读作为"正在比较的两个位置"
				var idxs: Array = []
				var start := maxi(0, recent_reads.size() - 2)
				for k in range(start, recent_reads.size()):
					var ri := int((recent_reads[k] as Dictionary)["i"])
					if not idxs.has(ri):
						idxs.append(ri)
				if not idxs.is_empty():
					events.append({"t": "cmp", "idx": idxs})
			# 刻意不清空 recent_reads：紧接着的赋值还要靠它判断元素搬去了哪里
			stack.append(res)

		"INDEX_GET":
			if stack.size() < 2:
				_fail("内部错误：下标访问操作数不足", line)
				return
			var idx: Variant = stack.pop_back()
			var obj: Variant = stack.pop_back()
			_index_get(obj, idx, line)

		"INDEX_SET":
			if stack.size() < 3:
				_fail("内部错误：下标赋值操作数不足", line)
				return
			var val: Variant = stack.pop_back()
			var idx: Variant = stack.pop_back()
			var obj: Variant = stack.pop_back()
			_index_set(obj, idx, val, line)

		"INDEX_AUG":
			if stack.size() < 3:
				_fail("内部错误：增强赋值操作数不足", line)
				return
			var val: Variant = stack.pop_back()
			var idx: Variant = stack.pop_back()
			var obj: Variant = stack.pop_back()
			_index_aug(obj, idx, val, String(ins["a"]), line)

		"BUILD_LIST":
			_build_seq(int(ins["a"]))

		"BUILD_TUPLE":
			_build_seq(int(ins["a"]))

		"UNPACK":
			var base: int = ins["a"]
			var cnt: int = ins["b"]
			if stack.is_empty():
				_fail("内部错误：解包时栈是空的", line)
				return
			var seq: Variant = stack.pop_back()
			var items: Array = _seq_items(seq, line)
			if status != "running":
				return
			if items.size() != cnt:
				_fail("解包数量对不上：左边要 %d 个值，右边给了 %d 个" % [cnt, items.size()], line)
				return
			var t: Array = f["temps"]
			while t.size() < base + cnt:
				t.append(null)
			for k in cnt:
				t[base + k] = items[k]

		"JUMP":
			f["pc"] = int(ins["a"])

		"JUMP_FALSE":
			if stack.is_empty():
				_fail("内部错误：条件栈是空的", line)
				return
			if not PyObjects.truthy(stack.pop_back()):
				f["pc"] = int(ins["a"])

		"JUMP_FALSE_KEEP":
			if stack.is_empty():
				_fail("内部错误：条件栈是空的", line)
				return
			if not PyObjects.truthy(stack[-1]):
				f["pc"] = int(ins["a"])
			else:
				stack.pop_back()

		"JUMP_TRUE_KEEP":
			if stack.is_empty():
				_fail("内部错误：条件栈是空的", line)
				return
			if PyObjects.truthy(stack[-1]):
				f["pc"] = int(ins["a"])
			else:
				stack.pop_back()

		"GET_ITER":
			if stack.is_empty():
				_fail("内部错误：没有可迭代对象", line)
				return
			var obj: Variant = stack.pop_back()
			stack.append(_make_iter(obj, line))

		"FOR_ITER":
			_for_iter(f, int(ins["a"]), line)

		"CALL":
			_do_call(int(ins["a"]), line)

		"CALL_METHOD":
			_do_call_method(String(ins["a"]), int(ins["b"]), line)

		"RETURN":
			var rv: Variant = stack.pop_back() if not stack.is_empty() else null
			_do_return(rv)

		"HALT":
			status = "done"
			halted_reason = "程序结束"

		_:
			_fail("内部错误：未知指令 '%s'" % ins["op"], line)


# ---------------------------------------------------------------- 调用

func _do_call(nargs: int, line: int) -> void:
	if stack.size() < nargs + 1:
		_fail("内部错误：调用参数不足", line)
		return
	var args: Array = []
	for _k in nargs:
		args.push_front(stack.pop_back())
	var fn: Variant = stack.pop_back()

	if fn is PyObjects.PyFunc:
		var pf: PyObjects.PyFunc = fn
		if args.size() != pf.params.size():
			_fail("函数 %s 需要 %d 个参数，实际给了 %d 个"
				% [pf.name, pf.params.size(), args.size()], line)
			return
		if frames.size() >= MAX_CALL_DEPTH:
			_fail("调用栈太深（超过 %d 层），内存槽不够了" % MAX_CALL_DEPTH, line)
			return
		var scope := {}
		for k in pf.params.size():
			scope[pf.params[k]] = args[k]
		frames.append({
			"code": pf.code, "pc": 0, "scope": scope, "temps": [], "name": pf.name,
			# 进这一帧时栈的高度。返回时要把栈收回这里，见 _do_return。
			"base": stack.size(),
		})
		_check_ram(line)
	elif fn is PyObjects.PyBuiltin:
		var r: Variant = _call_builtin((fn as PyObjects.PyBuiltin).name, args, line)
		if status != "running":
			return
		stack.append(r)
	else:
		_fail("'%s' 不是函数，不能调用" % PyObjects.repr(fn), line)


func _do_call_method(mname: String, nargs: int, line: int) -> void:
	if stack.size() < nargs + 1:
		_fail("内部错误：方法调用参数不足", line)
		return
	var args: Array = []
	for _k in nargs:
		args.push_front(stack.pop_back())
	var obj: Variant = stack.pop_back()

	if mname == "sort":
		_fail("服务器禁用了内置排序 sort()，请自己写排序逻辑", line)
		return
	if mname == "sorted":
		_fail("服务器禁用了内置排序 sorted()，请自己写排序逻辑", line)
		return

	if obj is PyObjects.PyList:
		var r: Variant = _call_list_method(obj, mname, args, line)
		if status != "running":
			return
		stack.append(r)
		return

	if obj == random_module:
		var r2: Variant = _call_random_method(mname, args, line)
		if status != "running":
			return
		stack.append(r2)
		return

	if obj is PyObjects.PyRange and mname == "index":
		stack.append(null)
		return

	_fail("类型 %s 没有方法 '%s'" % [_type_name(obj), mname], line)


func _call_list_method(lst: PyObjects.PyList, mname: String, args: Array, line: int) -> Variant:
	var items: Array = lst.items
	match mname:
		"append":
			if args.size() != 1:
				_fail("append() 需要 1 个参数", line)
				return null
			items.append(args[0])
			return null
		"pop":
			if items.is_empty():
				_fail("pop() 时数组已经是空的", line)
				return null
			if args.is_empty():
				return items.pop_back()
			var i := _norm_index(lst, args[0], line)
			if i < 0:
				return null
			return items.pop_at(i)
		"insert":
			if args.size() != 2:
				_fail("insert() 需要 2 个参数", line)
				return null
			if not _is_int(args[0]):
				_fail("insert() 的第一个参数必须是整数下标", line)
				return null
			var i := clampi(int(args[0]), 0, items.size())
			items.insert(i, args[1])
			return null
		"remove":
			if args.size() != 1:
				_fail("remove() 需要 1 个参数", line)
				return null
			var k := items.find(args[0])
			if k < 0:
				_fail("remove() 找不到值 %s" % PyObjects.repr(args[0]), line)
				return null
			items.remove_at(k)
			return null
		"index":
			if args.size() != 1:
				_fail("index() 需要 1 个参数", line)
				return null
			var k := items.find(args[0])
			if k < 0:
				_fail("index() 找不到值 %s" % PyObjects.repr(args[0]), line)
				return null
			return k
		"count":
			if args.size() != 1:
				_fail("count() 需要 1 个参数", line)
				return null
			var c := 0
			for v in items:
				if _eq(v, args[0]):
					c += 1
			return c
		"reverse":
			items.reverse()
			return null
		"extend":
			if args.size() != 1:
				_fail("extend() 需要 1 个参数", line)
				return null
			var src := _seq_items(args[0], line)
			if status != "running":
				return null
			items.append_array(src)
			return null
		"copy":
			return PyObjects.PyList.new(items.duplicate())
		"clear":
			items.clear()
			return null
	_fail("数组没有方法 '%s'。可用：%s" % [mname, ", ".join(LIST_METHODS)], line)
	return null


func _call_random_method(mname: String, args: Array, line: int) -> Variant:
	match mname:
		"shuffle":
			if args.size() != 1 or not (args[0] is PyObjects.PyList):
				_fail("shuffle() 需要 1 个参数（要洗的数组）", line)
				return null
			var lst := args[0] as PyObjects.PyList
			# Fisher–Yates：从后往前，每步跟它前面随机一个位置交换。
			# 交换走**带埋点**的下标通道，和 a[i], a[j] = a[j], a[i] 完全同一口径：
			# 两次读 + 两次写 + 两个 move 事件——左侧可视化才看得到洗牌过程，
			# 效率预算里也才会把洗牌的开销算进去。
			for k in range(lst.items.size() - 1, 0, -1):
				var j := _rng.randi_range(0, k)
				_index_get(lst, k, line)
				var vk: Variant = stack.pop_back()
				_index_get(lst, j, line)
				var vj: Variant = stack.pop_back()
				_index_set(lst, k, vj, line)
				_index_set(lst, j, vk, line)
			return null
		"randint":
			if args.size() != 2 or not _is_int(args[0]) or not _is_int(args[1]):
				_fail("randint() 需要 2 个整数参数（含两端）", line)
				return null
			var lo := int(args[0])
			var hi := int(args[1])
			if hi < lo:
				_fail("randint() 的下界不能大于上界", line)
				return null
			return _rng.randi_range(lo, hi)
		"seed":
			if args.size() != 1 or not _is_int(args[0]):
				_fail("seed() 需要 1 个整数参数", line)
				return null
			_rng.seed = int(args[0])
			return null
	_fail("random 没有方法 '%s'。可用：shuffle、randint、seed" % mname, line)
	return null


func _call_builtin(name: String, args: Array, line: int) -> Variant:
	match name:
		"len":
			if args.size() != 1:
				_fail("len() 需要 1 个参数", line)
				return null
			var a: Variant = args[0]
			if a is PyObjects.PyList:
				return (a as PyObjects.PyList).items.size()
			if a is PyObjects.PyRange:
				return (a as PyObjects.PyRange).size()
			if a is String:
				return (a as String).length()
			if a is Array:
				return (a as Array).size()
			_fail("len() 不支持类型 %s" % _type_name(a), line)
			return null

		"range":
			var s := 0
			var e := 0
			var st := 1
			if args.size() == 1:
				if not _is_int(args[0]):
					_fail("range() 的参数必须是整数", line)
					return null
				e = int(args[0])
			elif args.size() == 2:
				if not _is_int(args[0]) or not _is_int(args[1]):
					_fail("range() 的参数必须是整数", line)
					return null
				s = int(args[0])
				e = int(args[1])
			elif args.size() == 3:
				if not _is_int(args[0]) or not _is_int(args[1]) or not _is_int(args[2]):
					_fail("range() 的参数必须是整数", line)
					return null
				s = int(args[0])
				e = int(args[1])
				st = int(args[2])
				if st == 0:
					_fail("range() 的步长不能为 0", line)
					return null
			else:
				_fail("range() 需要 1~3 个参数，实际给了 %d 个" % args.size(), line)
				return null
			return PyObjects.PyRange.new(s, e, st)

		"min", "max":
			var pool: Array = []
			if args.size() == 1:
				pool = _seq_items(args[0], line)
				if status != "running":
					return null
			else:
				pool = args
			if pool.is_empty():
				_fail("%s() 收到了空序列" % name, line)
				return null
			var is_min := name == "min"
			var best: Variant = pool[0]
			for k in range(1, pool.size()):
				var cand: Variant = pool[k]
				var better: Variant = _lt(cand, best, line) if is_min else _lt(best, cand, line)
				if status != "running":
					return null
				if PyObjects.truthy(better):
					best = cand
			return best

		"abs":
			if args.size() != 1 or not _is_num(args[0]):
				_fail("abs() 需要 1 个数字参数", line)
				return null
			return absf(float(args[0])) if args[0] is float else absi(int(args[0]))

		"int":
			if args.size() != 1:
				_fail("int() 需要 1 个参数", line)
				return null
			if args[0] is int:
				return int(args[0])
			if args[0] is float:
				return int(args[0])
			if args[0] is bool:
				return 1 if args[0] else 0
			if args[0] is String:
				return int((args[0] as String).strip_edges())
			_fail("int() 无法转换 %s" % _type_name(args[0]), line)
			return null

		"float":
			if args.size() != 1:
				_fail("float() 需要 1 个参数", line)
				return null
			if args[0] is int or args[0] is float:
				return float(args[0])
			if args[0] is bool:
				return 1.0 if args[0] else 0.0
			if args[0] is String:
				return float((args[0] as String).strip_edges())
			_fail("float() 无法转换 %s" % _type_name(args[0]), line)
			return null

		"str":
			if args.size() != 1:
				_fail("str() 需要 1 个参数", line)
				return null
			return PyObjects.repr(args[0])

		"bool":
			if args.size() != 1:
				_fail("bool() 需要 1 个参数", line)
				return null
			return PyObjects.truthy(args[0])

		"sum":
			if args.size() != 1:
				_fail("sum() 需要 1 个参数", line)
				return null
			var pool := _seq_items(args[0], line)
			if status != "running":
				return null
			var total: Variant = 0
			for v in pool:
				total = _binop(total, v, "+", line)
				if status != "running":
					return null
			return total

		"list":
			if args.size() != 1:
				_fail("list() 需要 1 个参数", line)
				return null
			var pool := _seq_items(args[0], line)
			if status != "running":
				return null
			return PyObjects.PyList.new(pool)

		"print":
			var parts := PackedStringArray()
			for a in args:
				parts.append(PyObjects.repr(a))
			var text := " ".join(parts)
			log_lines.append(text)
			if log_lines.size() > 200:
				log_lines.pop_front()
			events.append({"t": "print", "text": text})
			return null

	_fail("未知的内置函数 '%s'" % name, line)
	return null


func _do_return(val: Variant) -> void:
	if frames.size() <= 1:
		frames.clear()
		status = "done"
		halted_reason = "程序结束"
		return
	# 栈是各帧共用的，而函数可能带着东西就返回了——最典型的是 for 循环：
	# 迭代器在循环期间一直躺在栈上，循环体里 `return` 就会把它留在那儿，
	# 于是调用方多出一个"看不见的"栈顶，下一次调用就会拿它当函数用
	# （实测报错：'{ "src": …, "i": 1 }' 不是函数，不能调用）。
	# 所以返回前把栈收回到本帧进入时的高度，只留下返回值。
	var base := int(frames[-1].get("base", 0))
	frames.pop_back()
	while stack.size() > base:
		stack.pop_back()
	stack.append(val)


# ---------------------------------------------------------------- 下标与序列

func _index_get(obj: Variant, idx: Variant, line: int) -> void:
	if obj is PyObjects.PyList:
		var lst: PyObjects.PyList = obj
		var i := _norm_index(lst, idx, line)
		if i < 0:
			return
		var got: Variant = lst.items[i]
		stack.append(got)
		reads += 1
		if lst.is_target:
			recent_reads.append({"i": i, "v": got})
			while recent_reads.size() > READ_WINDOW:
				recent_reads.pop_front()
			_prov[got] = i
			# 带上值：音效要按"被选中元素的大小"决定音高
			events.append({"t": "read", "i": i, "v": got})
		return
	if obj is PyObjects.PyRange:
		var rg: PyObjects.PyRange = obj
		var i := _norm_index(rg, idx, line)
		if i < 0:
			return
		stack.append(rg.start + i * rg.step)
		return
	if obj is String:
		var s: String = obj
		if not _is_int(idx):
			_fail("字符串下标必须是整数", line)
			return
		var i := int(idx)
		if i < 0:
			i += s.length()
		if i < 0 or i >= s.length():
			_fail("字符串下标越界：%d" % int(idx), line)
			return
		stack.append(s[i])
		return
	if obj is Array:
		var a: Array = obj
		if not _is_int(idx):
			_fail("下标必须是整数", line)
			return
		var i := int(idx)
		if i < 0:
			i += a.size()
		if i < 0 or i >= a.size():
			_fail("下标越界：%d" % int(idx), line)
			return
		stack.append(a[i])
		return
	_fail("类型 %s 不支持下标访问" % _type_name(obj), line)


func _index_set(obj: Variant, idx: Variant, val: Variant, line: int) -> void:
	if obj is PyObjects.PyList:
		var lst: PyObjects.PyList = obj
		var i := _norm_index(lst, idx, line)
		if i < 0:
			return
		lst.items[i] = val
		writes += 1
		if lst.is_target:
			events.append({"t": "write", "i": i, "v": val})
			# 写进来的值如果之前是从数组别处读出来的，那它就是"搬到了这里"
			if _prov.has(val):
				var src := int(_prov[val])
				if src != i:
					events.append({"t": "move", "from": src, "to": i, "v": val})
			_prov[val] = i
		return
	if obj is Array:
		var a: Array = obj
		if not _is_int(idx):
			_fail("下标必须是整数", line)
			return
		var i := int(idx)
		if i < 0:
			i += a.size()
		if i < 0 or i >= a.size():
			_fail("下标越界：%d" % int(idx), line)
			return
		a[i] = val
		return
	_fail("类型 %s 不支持下标赋值" % _type_name(obj), line)


func _index_aug(obj: Variant, idx: Variant, val: Variant, op: String, line: int) -> void:
	if obj is PyObjects.PyList:
		var lst: PyObjects.PyList = obj
		var i := _norm_index(lst, idx, line)
		if i < 0:
			return
		var nv: Variant = _binop(lst.items[i], val, op, line)
		if status != "running":
			return
		lst.items[i] = nv
		reads += 1
		writes += 1
		if lst.is_target:
			events.append({"t": "write", "i": i, "v": nv})
			_prov[nv] = i
		return
	_fail("类型 %s 不支持下标增强赋值" % _type_name(obj), line)


func _norm_index(obj: Variant, idx: Variant, line: int) -> int:
	if not _is_int(idx):
		_fail("数组下标必须是整数，收到 %s" % PyObjects.repr(idx), line)
		return -1
	var raw := int(idx)
	var n := 0
	if obj is PyObjects.PyList:
		n = (obj as PyObjects.PyList).items.size()
	elif obj is PyObjects.PyRange:
		n = (obj as PyObjects.PyRange).size()
	var i := raw
	if i < 0:
		i += n
	if i < 0 or i >= n:
		_fail("数组下标越界：%d（数组长度 %d）" % [raw, n], line)
		return -1
	return i


func _seq_items(v: Variant, line: int) -> Array:
	if v is PyObjects.PyList:
		return (v as PyObjects.PyList).items.duplicate()
	if v is PyObjects.PyRange:
		var rg: PyObjects.PyRange = v
		var out: Array = []
		if rg.step > 0:
			var i := rg.start
			while i < rg.stop:
				out.append(i)
				i += rg.step
		else:
			var i := rg.start
			while i > rg.stop:
				out.append(i)
				i += rg.step
		return out
	if v is Array:
		return (v as Array).duplicate()
	if v is String:
		var out: Array = []
		for i in (v as String).length():
			out.append((v as String)[i])
		return out
	_fail("类型 %s 不能展开成序列" % _type_name(v), line)
	return []


## 构造序列。元组和列表在这个子集里是同一个东西：UNPACK（a, b = b, a）和
## BUILD_* 都按 PyList 处理，所以两种写法只差一个标记，不必分两条路径。
func _build_seq(count: int) -> void:
	if stack.size() < count:
		_fail("内部错误：构造序列时栈不足", 0)
		return
	var out: Array = []
	for _k in count:
		out.push_front(stack.pop_back())
	stack.append(PyObjects.PyList.new(out))


func _make_iter(obj: Variant, line: int) -> Dictionary:
	if obj is PyObjects.PyList or obj is PyObjects.PyRange or obj is Array or obj is String:
		var start_i := 0
		if obj is PyObjects.PyRange:
			start_i = (obj as PyObjects.PyRange).start
		return {"src": obj, "i": start_i}
	_fail("类型 %s 不能被 for 遍历" % _type_name(obj), line)
	return {"src": null, "i": 0}


func _for_iter(f: Dictionary, end: int, line: int) -> void:
	if stack.is_empty():
		_fail("内部错误：迭代器丢失", line)
		return
	var it: Dictionary = stack[-1]
	var src: Variant = it["src"]
	var i: int = it["i"]
	var done := false
	var val: Variant = null

	if src is PyObjects.PyRange:
		var rg: PyObjects.PyRange = src
		if rg.step > 0:
			if i >= rg.stop:
				done = true
			else:
				val = i
				i += rg.step
		else:
			if i <= rg.stop:
				done = true
			else:
				val = i
				i += rg.step
	elif src is PyObjects.PyList:
		var lst: PyObjects.PyList = src
		if i >= lst.items.size():
			done = true
		else:
			val = lst.items[i]
			i += 1
	elif src is Array:
		var a: Array = src
		if i >= a.size():
			done = true
		else:
			val = a[i]
			i += 1
	elif src is String:
		var s: String = src
		if i >= s.length():
			done = true
		else:
			val = s[i]
			i += 1
	else:
		done = true

	if done:
		stack.pop_back()
		f["pc"] = end
	else:
		it["i"] = i
		stack.append(val)


# ---------------------------------------------------------------- 运算

func _binop(l: Variant, r: Variant, op: String, line: int) -> Variant:
	if op == "+":
		if l is String and r is String:
			return (l as String) + (r as String)
		if l is PyObjects.PyList and r is PyObjects.PyList:
			var out: Array = (l as PyObjects.PyList).items.duplicate()
			out.append_array((r as PyObjects.PyList).items)
			return PyObjects.PyList.new(out)
	if (l is PyObjects.PyList) and op == "*" and _is_int(r):
		var out: Array = []
		for _k in int(r):
			out.append_array((l as PyObjects.PyList).items)
		return PyObjects.PyList.new(out)

	if not _is_num(l) or not _is_num(r):
		_fail("不能对 %s 和 %s 做 '%s' 运算" % [_type_name(l), _type_name(r), op], line)
		return null

	var both_int := (l is int) and (r is int)
	var a := float(l)
	var b := float(r)

	match op:
		"+":
			return (int(a) + int(b)) if both_int else (a + b)
		"-":
			return (int(a) - int(b)) if both_int else (a - b)
		"*":
			return (int(a) * int(b)) if both_int else (a * b)
		"/":
			if b == 0.0:
				_fail("除以零", line)
				return null
			return a / b
		"//":
			if b == 0.0:
				_fail("除以零", line)
				return null
			var q := floorf(a / b)
			return int(q) if both_int else q
		"%":
			if b == 0.0:
				_fail("对零取模", line)
				return null
			var m := a - floorf(a / b) * b
			return int(m) if both_int else m
		"**":
			var p := pow(a, b)
			if both_int and b >= 0.0:
				return int(p)
			return p
	_fail("不支持的运算符 '%s'" % op, line)
	return null


func _unary(v: Variant, op: String, line: int) -> Variant:
	match op:
		"not":
			return not PyObjects.truthy(v)
		"-":
			if v is int:
				return -int(v)
			if v is float:
				return -float(v)
			_fail("不能对 %s 取负" % _type_name(v), line)
			return null
		"+":
			if _is_num(v):
				return v
			_fail("不能对 %s 取正" % _type_name(v), line)
			return null
	_fail("不支持的一元运算符 '%s'" % op, line)
	return null


func _compare(l: Variant, r: Variant, op: String, line: int) -> Variant:
	match op:
		"==":
			return _eq(l, r)
		"!=":
			return not _eq(l, r)
		"<":
			return _lt(l, r, line)
		">":
			return _lt(r, l, line)
		"<=":
			return not PyObjects.truthy(_lt(r, l, line)) if status == "running" else null
		">=":
			return not PyObjects.truthy(_lt(l, r, line)) if status == "running" else null
		"in":
			var pool := _seq_items(r, line)
			if status != "running":
				return null
			for v in pool:
				if _eq(v, l):
					return true
			return false
	_fail("不支持的比较运算符 '%s'" % op, line)
	return null


func _eq(l: Variant, r: Variant) -> bool:
	if l == null or r == null:
		return l == null and r == null
	if _is_num(l) and _is_num(r):
		return is_equal_approx(float(l), float(r)) if (l is float or r is float) else int(l) == int(r)
	if l is PyObjects.PyList and r is PyObjects.PyList:
		var a: Array = (l as PyObjects.PyList).items
		var b: Array = (r as PyObjects.PyList).items
		if a.size() != b.size():
			return false
		for k in a.size():
			if not _eq(a[k], b[k]):
				return false
		return true
	return l == r


func _lt(l: Variant, r: Variant, line: int) -> Variant:
	if _is_num(l) and _is_num(r):
		return float(l) < float(r)
	if l is String and r is String:
		return (l as String) < (r as String)
	_fail("不能比较 %s 和 %s 的大小" % [_type_name(l), _type_name(r)], line)
	return null


# ---------------------------------------------------------------- 资源

func _check_ram(line: int) -> void:
	if ram_limit <= 0:
		return
	var used := ram_usage()
	if used > ram_limit:
		_fail("内存溢出：需要 %d 字节，本机只有 %d 字节" % [used, ram_limit], line)


## 当前内存占用，单位是字节。一个数字（或一个数组引用）算 8 字节。
##
## 目标数组按元素个数计，每个变量计一个引用，玩家自建的辅助数组同样按元素计——
## 归并排序因此天然比冒泡更吃内存，这个取舍是刻意保留的。
func ram_usage() -> int:
	var values := 0
	if target != null:
		values += target.items.size()
	for scope in _all_scopes():
		var sc: Dictionary = scope
		for key in sc:
			var v: Variant = sc[key]
			# 函数和内置函数是"代码"，占的是硬盘不是内存，不能算进来
			if v is PyObjects.PyFunc or v is PyObjects.PyBuiltin:
				continue
			values += 1
			if v is PyObjects.PyList and not is_same(v, target):
				values += (v as PyObjects.PyList).items.size()
	return values * ServerSpec.BYTES_PER_VALUE


func _all_scopes() -> Array:
	var out: Array = [globals]
	for k in range(1, frames.size()):
		out.append(frames[k]["scope"])
	return out


func live_vars() -> Dictionary:
	var out := {}
	for k in globals:
		if globals[k] is PyObjects.PyFunc or globals[k] is PyObjects.PyBuiltin:
			continue
		out[k] = globals[k]
	if frames.size() > 1:
		var f: Dictionary = frames[-1]
		var sc: Dictionary = f["scope"]
		for k in sc:
			out["%s.%s" % [f["name"], k]] = sc[k]
	return out


func _fail(msg: String, line: int) -> void:
	if status == "error":
		return
	status = "error"
	error = {"line": line, "msg": msg}


static func _is_num(v: Variant) -> bool:
	return (v is int) or (v is float)


static func _is_int(v: Variant) -> bool:
	return (v is int) or (v is float and is_equal_approx(float(v), roundf(float(v))))


static func _type_name(v: Variant) -> String:
	if v == null:
		return "None"
	if v is bool:
		return "布尔值"
	if v is int or v is float:
		return "数字"
	if v is String:
		return "字符串"
	if v is PyObjects.PyList:
		return "数组"
	if v is PyObjects.PyRange:
		return "range"
	if v is PyObjects.PyFunc:
		return "函数"
	if v is PyObjects.PyBuiltin:
		return "内置函数"
	if v is Array:
		return "数组"
	return "未知类型"

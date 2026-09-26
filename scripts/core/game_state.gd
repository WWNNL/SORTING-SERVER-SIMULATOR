extends Node
## 全局游戏状态。注册为 Autoload，名字是 Game。
##
## 这里只放"跨标签页共享"的东西：狗狗币、硬件等级、算法文件、任务规模。
## 具体的运行控制交给 Main 场景，避免状态和界面互相纠缠。

signal coins_changed(coins: int)
signal tiers_changed()
signal files_changed()
signal stage_changed(index: int)
## 运行速度变了。刻意不复用 tiers_changed：拖滑条并没有换硬件，
## 不该把整页硬件卡片和编辑器的资源条全部重建一遍。
signal speed_changed()

const SAVE_PATH := "user://save.json"
const ENTRY := "sort"

## 存档里比例的下限（防旧数据/手滑存出负值）。滑条真正的下限是
## min_cpu_ratio()：定成"恰好还能跑出 1 步/秒"——固定 1% 的话，
## 升满 C-256 后最低档是 1300 步/秒，根本看不清运行轨迹。
const MIN_CPU_RATIO := 0.01

## CPU 滑条的最低比例 = 1 / 额定速度：任何档位的滑条底部都是 1 步/秒。
## cpu_speed 有 1 的下限兜底，比这更低的比例没有意义。
func min_cpu_ratio() -> float:
	return 1.0 / maxf(float(cpu_rate()), 1.0)


## 滑条最低档 = "逐帧放映"：运行每帧只推进一条指令，画面一帧一步。
## 一秒一步的 1 步/秒反而看不出轨迹（一秒才跳一下，谈不上"轨迹"），
## 逐帧播放才是"看得最清楚"的那一档。
func is_frame_step() -> bool:
	return cpu_ratio <= min_cpu_ratio()

var coins := 0
var tiers := {"cpu": 0, "ram": 0, "disk": 0, "psu": 0}
## 已通关的阶段数量。进度所在的阶段 = min(cleared, 最后一关)，
## 所以数据规模不可选——它完全由进度决定（重刷旧关卡不会改动它）。
var cleared := 0
## 玩家选中的阶段下标，-1 表示"跟着进度走"。
## 只能选已经通过的阶段或当前进度那一关；重刷照样给收益，
## 但既不推进进度，也不会把进度往回退。
var stage_sel := -1
## CPU 运行速度比例，1.0 = 跑满额定速度。滑条只允许往下调：
## 上限由硬件决定，否则"升级处理器"就失去意义了。
var cpu_ratio := 1.0
## 右侧标签页的顺序（存的是页名）。玩家拖动标签就能调整，顺序记进存档，
## 下次开游戏还是自己排的样子；表里出现不认识的页名时由界面那边兜底。
var tab_order: Array = []
## 每个阶段的历史最好成绩：阶段下标 -> 最少的数组读写次数
var stage_best := {}
## 上面那条成绩是在多大的数据规模下取得的。
## 阶段改过 n 之后旧成绩就不再可比，所以显示时要标出来，而不是当成同一回事。
var stage_best_n := {}
var files: Array = []
var current_file := 0
var stats := {
	"runs": 0,
	"completed": 0,
	"failed": 0,
	"total_earned": 0,
	"power_paid": 0,
	"best_reward": 0,
}

var _loaded := false


func _ready() -> void:
	load_game()
	if files.is_empty():
		_seed_starter_files()


# ---------------------------------------------------------------- 硬件

func tier_of(part: String) -> int:
	return int(tiers.get(part, 0))


## CPU 的额定速度，由硬件等级决定。
func cpu_rate() -> int:
	return int(ServerSpec.spec("cpu", tier_of("cpu"))["speed"])


## 当前实际允许的每秒指令数（滑条按比例降速）。
##
## 调慢只是"看得更清楚"，不是收益上的捷径：同一份工作的总耗电
## = 功率 × 耗时，调慢以后耗时变长，总电费反而更高；
## 而效率门槛只看数组读写次数，与速度无关。
func cpu_speed() -> int:
	var rated := cpu_rate()
	if cpu_ratio >= 1.0:
		return rated
	return clampi(int(round(float(rated) * cpu_ratio)), 1, rated)


func cpu_percent() -> int:
	return int(round(cpu_ratio * 100.0))


func set_cpu_ratio(r: float) -> void:
	var clamped := clampf(r, min_cpu_ratio(), 1.0)
	if is_equal_approx(clamped, cpu_ratio):
		return
	cpu_ratio = clamped
	speed_changed.emit()


func ram_bytes() -> int:
	return int(ServerSpec.spec("ram", tier_of("ram"))["bytes"])


func disk_bytes() -> int:
	return int(ServerSpec.spec("disk", tier_of("disk"))["bytes"])


func psu_watts() -> int:
	return int(ServerSpec.spec("psu", tier_of("psu"))["watts"])


func total_draw() -> int:
	return ServerSpec.total_draw(tier_of("cpu"), tier_of("ram"), tier_of("disk"))


func power_headroom() -> int:
	return psu_watts() - total_draw()


func power_ok() -> bool:
	return power_headroom() >= 0


## 购买下一级。返回 {ok: bool, msg: String}
func buy(part: String) -> Dictionary:
	if not ServerSpec.PARTS.has(part):
		return {"ok": false, "msg": "未知部件"}

	var cur := tier_of(part)
	if ServerSpec.is_max(part, cur):
		return {"ok": false, "msg": "%s 已经是最高规格" % _part_label(part)}

	var cost := ServerSpec.next_cost(part, cur)
	if coins < cost:
		return {"ok": false, "msg": "狗狗币不足，还差 %d" % (cost - coins)}

	# 先算买完之后会不会供电不足——超了也允许买，但要让玩家清楚后果
	coins -= cost
	tiers[part] = cur + 1

	coins_changed.emit(coins)
	tiers_changed.emit()
	save_game()

	var msg := "%s 已升级到 %s" % [_part_label(part), ServerSpec.spec(part, cur + 1)["name"]]
	if not power_ok():
		msg += "。警告：整机功耗 %dW 已超出电源 %dW，服务器无法开机" % [total_draw(), psu_watts()]
	return {"ok": true, "msg": msg}


static func _part_label(part: String) -> String:
	match part:
		"cpu": return "处理器"
		"ram": return "内存"
		"disk": return "硬盘"
		"psu": return "电源"
	return part


# ---------------------------------------------------------------- 收益

func award(n: int, ops: int) -> int:
	var gain := ServerSpec.reward(n, ops)
	if gain <= 0:
		return 0
	coins += gain
	stats["total_earned"] = int(stats["total_earned"]) + gain
	if gain > int(stats["best_reward"]):
		stats["best_reward"] = gain
	coins_changed.emit(coins)
	return gain


## 直接发钱（用于效率达标奖励等已经算好的数额）
func grant(amount: int) -> void:
	if amount <= 0:
		return
	coins += amount
	stats["total_earned"] = int(stats["total_earned"]) + amount
	if amount > int(stats["best_reward"]):
		stats["best_reward"] = amount
	coins_changed.emit(coins)


func spend(amount: int) -> bool:
	if coins < amount:
		return false
	coins -= amount
	coins_changed.emit(coins)
	return true


# ---------------------------------------------------------------- 算法文件

## 算法文件统一带这个后缀。文件列表是按"文件"列出来的，不带后缀看着不像个文件
## （玩家新建时输入"1145"就会得到一个叫"1145"的东西）。
const EXT := ".py"


## 补上 .py 后缀。已经有了就不重复加（大小写不敏感，玩家写 .PY 也认）。
static func with_ext(name: String) -> String:
	var clean := name.strip_edges()
	if clean.is_empty():
		return clean
	if clean.to_lower().ends_with(EXT):
		return clean
	return clean + EXT


## 在扩展名**前面**插一段后缀："冒泡排序.py" + " 副本" → "冒泡排序 副本.py"。
## 直接拼在后面会得到"冒泡排序.py 副本"，看着又不像 Python 文件了，
## 而且列表里排在一起时会和真正的 .py 分家。
static func insert_before_ext(name: String, suffix: String) -> String:
	if name.to_lower().ends_with(EXT):
		return name.substr(0, name.length() - EXT.length()) + suffix + EXT
	return name + suffix


func current_code() -> String:
	if files.is_empty():
		return ""
	var i := clampi(current_file, 0, files.size() - 1)
	return String(files[i]["code"])


func set_current_code(code: String) -> void:
	if files.is_empty():
		return
	var i := clampi(current_file, 0, files.size() - 1)
	if String(files[i]["code"]) == code:
		return
	files[i]["code"] = code
	# 刻意不发 files_changed：编辑器每敲一个字都会调这里，
	# 发信号会让文件列表跟着重建，既闪烁又浪费。
	# 文件页的刷新交给切标签页时触发。


## 新建的文件和算法库里的条目保持同一套字段，存档里就不会出现两种形状。
func _blank_file(name: String, code: String, cost: int) -> Dictionary:
	return {
		"name": name, "code": code,
		"cost": cost, "unlocked": cost <= 0,
		"best_ops": 0, "best_reward": 0, "best_n": 0,
	}


## 新建算法文件。名字在这里统一补 .py 并去重，所有入口（新建按钮、将来的别的调用）
## 都走这一条，不用各自记得补。
func new_file(name: String, code := "") -> int:
	var clean := with_ext(name)
	if clean.is_empty():
		clean = with_ext("新算法")
	files.append(_blank_file(_unique_name(clean), code, 0))
	current_file = files.size() - 1
	files_changed.emit()
	save_game()
	return current_file


func duplicate_file(index: int) -> int:
	if index < 0 or index >= files.size():
		return -1
	var src: Dictionary = files[index]
	files.append(_blank_file(
		_unique_name(insert_before_ext(String(src["name"]), " 副本")),
		String(src["code"]), 0))
	current_file = files.size() - 1
	files_changed.emit()
	save_game()
	return current_file


func delete_file(index: int) -> bool:
	if files.size() <= 1:
		return false
	if index < 0 or index >= files.size():
		return false
	files.remove_at(index)
	current_file = clampi(current_file, 0, files.size() - 1)
	files_changed.emit()
	save_game()
	return true


## 重命名。同样补 .py——老存档里可能有"1145"这种没后缀的名字，
## 玩家把它改回来是最自然的修法，这条路上也得补，否则会觉得"改了还是没后缀"。
## 重名不拦（玩家可能就想这么叫），由调用方给出提示。
func rename_file(index: int, name: String) -> void:
	if index < 0 or index >= files.size():
		return
	var clean := with_ext(name)
	if clean.is_empty():
		return
	files[index]["name"] = clean
	files_changed.emit()
	save_game()


## 这个名字是不是已经被**别的**文件占了（重命名时用来提醒）
func name_taken_by_other(name: String, index: int) -> bool:
	for i in files.size():
		if i != index and String(files[i]["name"]) == name:
			return true
	return false


func record_result(index: int, n: int, ops: int, gain: int) -> void:
	if index < 0 or index >= files.size():
		return
	var f: Dictionary = files[index]
	var best_ops := int(f["best_ops"])
	# ops 只在同一规模下才可比
	if int(f["best_n"]) != n or best_ops == 0 or ops < best_ops:
		if int(f["best_n"]) != n:
			f["best_ops"] = ops
			f["best_n"] = n
		elif ops < best_ops:
			f["best_ops"] = ops
	if gain > int(f["best_reward"]):
		f["best_reward"] = gain
	files_changed.emit()


## 重名时加序号。序号插在扩展名前面："新算法.py" → "新算法 2.py"，
## 不然后缀就成了"新算法.py 2"。
func _unique_name(base: String) -> String:
	var name := base
	var k := 2
	while _name_taken(name):
		name = insert_before_ext(base, " %d" % k)
		k += 1
	return name


func _name_taken(name: String) -> bool:
	for f in files:
		if String(f["name"]) == name:
			return true
	return false


# ---------------------------------------------------------------- 阶段进度

## 进度所在的阶段：已通关的数量就是它的下标，所以它永远指向"下一关"。
## 通关最后一关后停在那里，可以反复刷收益。
func frontier_index() -> int:
	return clampi(cleared, 0, ServerSpec.stage_count() - 1)


## 当前要挑战的阶段。默认跟着进度，玩家也可以挑一个已通过的阶段重刷。
func stage_index() -> int:
	if stage_sel < 0:
		return frontier_index()
	return clampi(stage_sel, 0, frontier_index())


## 现在是不是在重刷旧关卡（不推进进度的那一种）。
func is_replay() -> bool:
	return stage_index() < frontier_index()


## 这个阶段能不能选。已经通过的阶段和当前进度那一关都可以，往后的不行。
func can_select_stage(i: int) -> bool:
	return i >= 0 and i < ServerSpec.stage_count() and i <= frontier_index()


## 选中一个阶段来挑战。返回是否真的换了。选当前进度那一关等于"回到进度"。
func select_stage(i: int) -> bool:
	if not can_select_stage(i):
		return false
	if i == stage_index():
		return false
	stage_sel = -1 if i >= frontier_index() else i
	stage_changed.emit(cleared)
	save_game()
	return true


## 回到"跟着进度走"。
func follow_progress() -> bool:
	if stage_sel < 0:
		return false
	stage_sel = -1
	stage_changed.emit(cleared)
	save_game()
	return true


func stage_info() -> Dictionary:
	return ServerSpec.stage(stage_index())


func stage_n() -> int:
	return int(stage_info().get("n", 8))


func stage_ops_budget() -> int:
	return int(stage_info().get("ops", 999999))


## 进度是不是已经到最后一关（没有下一关可解锁了）。
func is_final_stage() -> bool:
	return frontier_index() >= ServerSpec.stage_count() - 1


## 完成一次任务后推进进度。返回是否真的解锁了新阶段。
##
## 判据是"进度那一关"而不是"玩家选中的那一关"：重刷旧关卡时
## index != frontier_index()，于是这里直接返回 false——既不加进度，
## 也绝不会把 cleared 往回写。
func clear_stage(index: int) -> bool:
	if index != frontier_index():
		return false
	if is_final_stage():
		return false
	cleared = index + 1
	stage_sel = -1
	stage_changed.emit(cleared)
	save_game()
	return true


## 记一次成绩。只有同一数据规模下的成绩才互相比较：
## 规模变了（阶段调整过 n）就重新开始记，否则会拿 32 个元素的旧纪录
## 去和 40 个元素的门槛并列显示，看着像"这一关变难了"。
func record_stage(index: int, ops: int, n: int) -> void:
	var key := str(index)
	if int(stage_best_n.get(key, 0)) != n or not stage_best.has(key):
		stage_best[key] = ops
		stage_best_n[key] = n
		return
	if ops < int(stage_best[key]):
		stage_best[key] = ops


func stage_best_ops(index: int) -> int:
	return int(stage_best.get(str(index), 0))


## 上面那条成绩的数据规模。0 表示老存档里的记录，规模未知。
func stage_best_size(index: int) -> int:
	return int(stage_best_n.get(str(index), 0))


## 电费扣款。余额扣到 0 为止，返回实际扣掉多少。
## 刻意不做成"余额不足就禁止运行"——那会让玩家在 0 币时彻底卡死。
func pay_power(amount: int) -> int:
	if amount <= 0:
		return 0
	var paid := mini(amount, coins)
	if paid <= 0:
		return 0
	coins -= paid
	stats["power_paid"] = int(stats["power_paid"]) + paid
	coins_changed.emit(coins)
	return paid


# ---------------------------------------------------------------- 存档

func save_game() -> void:
	var data := {
		"coins": coins,
		"tiers": tiers,
		"cleared": cleared,
		"stage_sel": stage_sel,
		"cpu_ratio": cpu_ratio,
		"tab_order": tab_order,
		"stage_best": stage_best,
		"stage_best_n": stage_best_n,
		"files": files,
		"current_file": current_file,
		"stats": stats,
	}
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		# 沙箱或权限问题下写不进去很正常，不该因此崩掉游戏
		push_warning("存档写入失败（错误码 %d），本次进度不会保留" % FileAccess.get_open_error())
		return
	f.store_string(JSON.stringify(data, "  "))
	f.close()


func load_game() -> void:
	_loaded = true
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return
	var d: Dictionary = parsed

	coins = int(d.get("coins", 0))
	cleared = clampi(int(d.get("cleared", 0)), 0, ServerSpec.stage_count() - 1)
	current_file = int(d.get("current_file", 0))
	# 老存档没有这两个字段：默认"跟着进度走 + 跑满速度"
	stage_sel = clampi(int(d.get("stage_sel", -1)), -1, frontier_index())
	cpu_ratio = clampf(float(d.get("cpu_ratio", 1.0)), MIN_CPU_RATIO, 1.0)
	tab_order = []
	if d.get("tab_order") is Array:
		for n in (d["tab_order"] as Array):
			tab_order.append(String(n))

	if d.get("stage_best") is Dictionary:
		stage_best = {}
		for k in (d["stage_best"] as Dictionary):
			stage_best[str(k)] = int((d["stage_best"] as Dictionary)[k])
	# 老存档只存了成绩、没存规模：留 0 表示"规模未知"，界面上会标成旧记录
	stage_best_n = {}
	if d.get("stage_best_n") is Dictionary:
		for k in (d["stage_best_n"] as Dictionary):
			stage_best_n[str(k)] = int((d["stage_best_n"] as Dictionary)[k])

	if d.get("tiers") is Dictionary:
		for p in ServerSpec.PARTS:
			tiers[p] = clampi(int((d["tiers"] as Dictionary).get(p, 0)), 0, ServerSpec.max_tier(p))
	if d.get("stats") is Dictionary:
		for k in stats:
			stats[k] = int((d["stats"] as Dictionary).get(k, stats[k]))
	if d.get("files") is Array:
		files = []
		for e in (d["files"] as Array):
			if not (e is Dictionary):
				continue
			var ed: Dictionary = e
			files.append({
				"name": String(ed.get("name", "未命名")),
				"code": String(ed.get("code", "")),
				"cost": int(ed.get("cost", 0)),
				# 老存档没有这个字段，默认当作已解锁，免得玩家的文件突然被锁上
				"unlocked": bool(ed.get("unlocked", true)),
				"best_ops": int(ed.get("best_ops", 0)),
				"best_reward": int(ed.get("best_reward", 0)),
				"best_n": int(ed.get("best_n", 0)),
			})
	# 补齐后来版本新增的算法
	_ensure_library_complete()
	current_file = clampi(current_file, 0, maxi(0, files.size() - 1))


func reset_all() -> void:
	coins = 0
	tiers = {"cpu": 0, "ram": 0, "disk": 0, "psu": 0}
	cleared = 0
	stage_sel = -1
	cpu_ratio = 1.0
	tab_order = []
	stage_best = {}
	stage_best_n = {}
	current_file = 0
	stats = {
		"runs": 0, "completed": 0, "failed": 0, "total_earned": 0,
		"power_paid": 0, "best_reward": 0,
	}
	files = []
	_seed_starter_files()
	coins_changed.emit(coins)
	tiers_changed.emit()
	stage_changed.emit(cleared)
	files_changed.emit()
	speed_changed.emit()
	save_game()


# ---------------------------------------------------------------- 算法库

func _seed_starter_files() -> void:
	files = []
	for entry in LIBRARY:
		files.append(_blank_file(String(entry["name"]), String(entry["code"]),
			int(entry["cost"])))
	current_file = 0
	files_changed.emit()
	save_game()


## 老存档里没有后来新增的算法。按名字补齐，缺的按未解锁处理。
func _ensure_library_complete() -> void:
	var have := {}
	for f in files:
		have[String(f["name"])] = true
	var added := false
	for entry in LIBRARY:
		var nm := String(entry["name"])
		if have.has(nm):
			continue
		files.append(_blank_file(nm, String(entry["code"]), int(entry["cost"])))
		added = true
	if added:
		files_changed.emit()


func is_unlocked(index: int) -> bool:
	if index < 0 or index >= files.size():
		return false
	return bool((files[index] as Dictionary).get("unlocked", true))


func file_cost(index: int) -> int:
	if index < 0 or index >= files.size():
		return 0
	return int((files[index] as Dictionary).get("cost", 0))


func unlocked_count() -> int:
	var c := 0
	for i in files.size():
		if is_unlocked(i):
			c += 1
	return c


## 花狗狗币解锁一个算法文件。返回 {ok, msg}
func unlock_file(index: int) -> Dictionary:
	if index < 0 or index >= files.size():
		return {"ok": false, "msg": "无效的文件"}
	var f: Dictionary = files[index]
	if bool(f.get("unlocked", true)):
		return {"ok": false, "msg": "这个算法已经解锁了"}
	var cost := int(f.get("cost", 0))
	if coins < cost:
		return {"ok": false, "msg": "狗狗币不足，还差 Ð%d" % (cost - coins)}
	coins -= cost
	f["unlocked"] = true
	coins_changed.emit(coins)
	files_changed.emit()
	save_game()
	return {"ok": true, "msg": "已解锁 %s" % String(f["name"])}


const LIBRARY := [
	{
		"name": "冒泡排序.py", "cost": 0,
		"code": "# 冒泡排序：相邻两两比较，大的往后冒\n# 最直观，但比较次数是 n 的平方量级\n\ndef sort(a):\n    n = len(a)\n    for i in range(n):\n        for j in range(n - 1 - i):\n            if a[j] > a[j + 1]:\n                a[j], a[j + 1] = a[j + 1], a[j]\n    return a\n",
	},
	{
		"name": "选择排序.py", "cost": 0,
		"code": "# 选择排序：每轮找出最小值，放到前面\n\ndef sort(a):\n    n = len(a)\n    for i in range(n):\n        m = i\n        for j in range(i + 1, n):\n            if a[j] < a[m]:\n                m = j\n        if m != i:\n            a[i], a[m] = a[m], a[i]\n    return a\n",
	},
	{
		"name": "插入排序.py", "cost": 0,
		"code": "# 插入排序：像理牌一样，把每张牌插到该在的位置\n# 数据越接近有序，它越快\n\ndef sort(a):\n    n = len(a)\n    for i in range(1, n):\n        key = a[i]\n        j = i - 1\n        while j >= 0 and a[j] > key:\n            a[j + 1] = a[j]\n            j -= 1\n        a[j + 1] = key\n    return a\n",
	},
	{
		"name": "鸡尾酒排序.py", "cost": 0,
		"code": "# 鸡尾酒排序：冒泡的双向版\n# 一趟从左往右，一趟从右往左。\n# 注意：随机数据下它和冒泡的读写量几乎一样，只在\"小元素卡在末尾\"时才占便宜\n\ndef sort(a):\n    lo = 0\n    hi = len(a) - 1\n    while lo < hi:\n        for i in range(lo, hi):\n            if a[i] > a[i + 1]:\n                a[i], a[i + 1] = a[i + 1], a[i]\n        hi -= 1\n        for i in range(hi, lo, -1):\n            if a[i - 1] > a[i]:\n                a[i - 1], a[i] = a[i], a[i - 1]\n        lo += 1\n    return a\n",
	},
	{
		"name": "梳排序.py", "cost": 80,
		"code": "# 梳排序：先用大间隔比较，再逐步收窄到 1\n# 间隔每次乘 10/13，能很快把尾部的小元素带到前面\n# 代码几乎和冒泡一样短，效果却好得多——最划算的一步\n\ndef sort(a):\n    n = len(a)\n    gap = n\n    swapped = True\n    while gap > 1 or swapped:\n        gap = gap * 10 // 13\n        if gap < 1:\n            gap = 1\n        swapped = False\n        for i in range(n - gap):\n            if a[i] > a[i + gap]:\n                a[i], a[i + gap] = a[i + gap], a[i]\n                swapped = True\n    return a\n",
	},
	{
		"name": "希尔排序.py", "cost": 200,
		"code": "# 希尔排序：带间隔的插入排序\n# 先用大间隔让元素大步跳跃，再逐步缩小间隔收尾\n\ndef sort(a):\n    n = len(a)\n    gap = n // 2\n    while gap > 0:\n        for i in range(gap, n):\n            key = a[i]\n            j = i\n            while j >= gap and a[j - gap] > key:\n                a[j] = a[j - gap]\n                j -= gap\n            a[j] = key\n        gap = gap // 2\n    return a\n",
	},
	{
		"name": "归并排序.py", "cost": 400,
		"code": "# 归并排序：分治 + 额外缓冲区\n# 时间稳定在 n log n，代价是需要一块辅助内存（本机很吃这个）\n# 注意：这个文件 767 字节，起始硬盘只有 512 字节，得先升硬盘\n\ndef sort(a):\n    ms(a, 0, len(a) - 1)\n    return a\n\ndef ms(a, lo, hi):\n    if lo >= hi:\n        return\n    mid = (lo + hi) // 2\n    ms(a, lo, mid)\n    ms(a, mid + 1, hi)\n    tmp = []\n    i = lo\n    j = mid + 1\n    while i <= mid and j <= hi:\n        if a[i] <= a[j]:\n            tmp.append(a[i])\n            i += 1\n        else:\n            tmp.append(a[j])\n            j += 1\n    while i <= mid:\n        tmp.append(a[i])\n        i += 1\n    while j <= hi:\n        tmp.append(a[j])\n        j += 1\n    for k in range(len(tmp)):\n        a[lo + k] = tmp[k]\n",
	},
	{
		"name": "三路快排.py", "cost": 700,
		"code": "# 三路快排：把数组分成 小于 / 等于 / 大于 三段\n# 重复值很多的时候，比普通快排少做大量无用比较\n\ndef sort(a):\n    qs3(a, 0, len(a) - 1)\n    return a\n\ndef qs3(a, lo, hi):\n    if lo >= hi:\n        return\n    pivot = a[lo]\n    lt = lo\n    i = lo + 1\n    gt = hi\n    while i <= gt:\n        if a[i] < pivot:\n            a[lt], a[i] = a[i], a[lt]\n            lt += 1\n            i += 1\n        elif a[i] > pivot:\n            a[i], a[gt] = a[gt], a[i]\n            gt -= 1\n        else:\n            i += 1\n    qs3(a, lo, lt - 1)\n    qs3(a, gt + 1, hi)\n",
	},
	{
		"name": "快速排序.py", "cost": 1100,
		"code": "# 快速排序：选一个基准值，把数组分成两半递归处理\n# 原地排序，不需要额外内存，平均 n log n\n# 本机综合表现最好的通用排序之一\n\ndef sort(a):\n    qs(a, 0, len(a) - 1)\n    return a\n\ndef qs(a, lo, hi):\n    if lo >= hi:\n        return\n    p = part(a, lo, hi)\n    qs(a, lo, p - 1)\n    qs(a, p + 1, hi)\n\ndef part(a, lo, hi):\n    pivot = a[hi]\n    i = lo\n    for j in range(lo, hi):\n        if a[j] <= pivot:\n            a[i], a[j] = a[j], a[i]\n            i += 1\n    a[i], a[hi] = a[hi], a[i]\n    return i\n",
	},
	{
		"name": "堆排序.py", "cost": 1800,
		"code": "# 堆排序：先把数组整理成大顶堆，再逐个把堆顶换到末尾\n# 不需要额外内存，而且最坏情况也是 n log n\n# 代价是常数偏大，读写量比快排多一些\n\ndef sort(a):\n    n = len(a)\n    i = n // 2 - 1\n    while i >= 0:\n        sift(a, i, n)\n        i -= 1\n    i = n - 1\n    while i > 0:\n        a[0], a[i] = a[i], a[0]\n        sift(a, 0, i)\n        i -= 1\n    return a\n\ndef sift(a, root, end):\n    while True:\n        child = root * 2 + 1\n        if child >= end:\n            return\n        if child + 1 < end and a[child + 1] > a[child]:\n            child += 1\n        if a[root] >= a[child]:\n            return\n        a[root], a[child] = a[child], a[root]\n        root = child\n",
	},
	{
		"name": "计数排序.py", "cost": 3000,
		"code": "# 计数排序：不比较，直接统计每个值出现了几次\n# 时间接近线性，读写量只有快排的十分之一\n# 但值域有多大就要多少内存——本机最吃内存的算法，也是最强的一张牌\n\ndef sort(a):\n    n = len(a)\n    hi = max(a)\n    cnt = []\n    for i in range(hi + 1):\n        cnt.append(0)\n    for i in range(n):\n        cnt[a[i]] += 1\n    k = 0\n    for v in range(hi + 1):\n        c = cnt[v]\n        while c > 0:\n            a[k] = v\n            k += 1\n            c -= 1\n    return a\n",
	},
]

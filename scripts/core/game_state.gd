extends Node
## 全局游戏状态。注册为 Autoload，名字是 Game。
##
## 这里只放"跨标签页共享"的东西：狗狗币、硬件等级、算法文件、任务规模。
## 具体的运行控制交给 Main 场景，避免状态和界面互相纠缠。

signal coins_changed(coins: int)
signal tiers_changed()
signal files_changed()
signal stage_changed(index: int)

const SAVE_PATH := "user://save.json"
const ENTRY := "sort"

var coins := 0
var tiers := {"cpu": 0, "ram": 0, "disk": 0, "psu": 0}
## 已通关的阶段数量。当前阶段 = min(cleared, 最后一关)，
## 所以数据规模不可选——它完全由进度决定。
var cleared := 0
## 每个阶段的历史最好成绩：阶段下标 -> 最少的数组读写次数
var stage_best := {}
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


func cpu_speed() -> int:
	return int(ServerSpec.spec("cpu", tier_of("cpu"))["speed"])


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


func new_file(name: String, code := "") -> int:
	if name.strip_edges().is_empty():
		name = _unique_name("新算法")
	files.append(_blank_file(name, code, 0))
	current_file = files.size() - 1
	files_changed.emit()
	save_game()
	return current_file


func duplicate_file(index: int) -> int:
	if index < 0 or index >= files.size():
		return -1
	var src: Dictionary = files[index]
	files.append(_blank_file(_unique_name(String(src["name"]) + " 副本"),
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


func rename_file(index: int, name: String) -> void:
	if index < 0 or index >= files.size():
		return
	var clean := name.strip_edges()
	if clean.is_empty():
		return
	files[index]["name"] = clean
	files_changed.emit()
	save_game()


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


func _unique_name(base: String) -> String:
	var name := base
	var k := 2
	while _name_taken(name):
		name = "%s %d" % [base, k]
		k += 1
	return name


func _name_taken(name: String) -> bool:
	for f in files:
		if String(f["name"]) == name:
			return true
	return false


# ---------------------------------------------------------------- 阶段进度

## 当前阶段下标。通关最后一关后停在最后一关，可以反复刷收益。
func stage_index() -> int:
	return clampi(cleared, 0, ServerSpec.stage_count() - 1)


func stage_info() -> Dictionary:
	return ServerSpec.stage(stage_index())


func stage_n() -> int:
	return int(stage_info().get("n", 8))


func stage_ops_budget() -> int:
	return int(stage_info().get("ops", 999999))


func is_final_stage() -> bool:
	return stage_index() >= ServerSpec.stage_count() - 1


## 完成一次任务后推进进度。返回是否真的解锁了新阶段。
func clear_stage(index: int) -> bool:
	if index != stage_index():
		return false
	if is_final_stage():
		return false
	cleared = index + 1
	stage_changed.emit(cleared)
	save_game()
	return true


func record_stage(index: int, ops: int) -> void:
	var key := str(index)
	if not stage_best.has(key) or ops < int(stage_best[key]):
		stage_best[key] = ops


func stage_best_ops(index: int) -> int:
	return int(stage_best.get(str(index), 0))


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
		"stage_best": stage_best,
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

	if d.get("stage_best") is Dictionary:
		stage_best = {}
		for k in (d["stage_best"] as Dictionary):
			stage_best[str(k)] = int((d["stage_best"] as Dictionary)[k])

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
	stage_best = {}
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

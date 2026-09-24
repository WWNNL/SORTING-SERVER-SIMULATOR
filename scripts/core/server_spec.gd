class_name ServerSpec
extends RefCounted
## 虚拟服务器的硬件规格表、阶段阶梯与数值规则。
##
## 四个部件互相牵制是核心玩法：升级 CPU / 内存 / 硬盘都会增加功耗，
## 而运行期间按功率实时扣电费。所以玩家不能只堆一项，必须成套升级，
## 而且"用烂算法跑大数据"会真的烧钱。

## 主板基础功耗，任何配置都要付
const BASE_DRAW := 8

## 内存计量单位：一个数字（或一个数组引用）占 8 字节。
## 数组按"元素个数 × 8"计，所以 n=256 的目标数组本身就要 2 KB。
const BYTES_PER_VALUE := 8

## 电费费率：每瓦每秒 0.01 狗狗币。
## 运行期间实时从余额里扣，扣到 0 为止（不会负，也不会因此禁止运行）。
const POWER_RATE := 0.01

## CPU：决定每秒能执行多少条指令。同时也是最大的耗电户。
const CPU := [
	{"name": "C-01 单核", "speed": 60, "watts": 8, "cost": 0},
	{"name": "C-02 单核", "speed": 150, "watts": 14, "cost": 25},
	{"name": "C-04 双核", "speed": 400, "watts": 22, "cost": 75},
	{"name": "C-08 四核", "speed": 1000, "watts": 34, "cost": 220},
	{"name": "C-16 四核", "speed": 2600, "watts": 50, "cost": 650},
	{"name": "C-32 八核", "speed": 7000, "watts": 72, "cost": 1900},
	{"name": "C-64 八核", "speed": 18000, "watts": 100, "cost": 5600},
	{"name": "C-128 十六核", "speed": 48000, "watts": 140, "cost": 16500},
	{"name": "C-256 十六核", "speed": 130000, "watts": 190, "cost": 48000},
]

## 内存：以字节为单位。目标数组每个元素 8 字节，每个变量 8 字节，
## 玩家自建的辅助数组同样按元素计——归并排序因此天然更吃内存。
const RAM := [
	{"name": "R-512B", "bytes": 512, "watts": 4, "cost": 0},
	{"name": "R-1K", "bytes": 1024, "watts": 7, "cost": 30},
	{"name": "R-2K", "bytes": 2048, "watts": 11, "cost": 90},
	{"name": "R-4K", "bytes": 4096, "watts": 17, "cost": 280},
	{"name": "R-8K", "bytes": 8192, "watts": 25, "cost": 800},
	{"name": "R-16K", "bytes": 16384, "watts": 36, "cost": 2400},
	{"name": "R-32K", "bytes": 32768, "watts": 50, "cost": 7000},
]

## 硬盘：源码允许的字节数。写得越长越需要升级。
const DISK := [
	{"name": "D-512", "bytes": 512, "watts": 3, "cost": 0},
	{"name": "D-1K", "bytes": 1024, "watts": 5, "cost": 35},
	{"name": "D-2K", "bytes": 2048, "watts": 8, "cost": 110},
	{"name": "D-4K", "bytes": 4096, "watts": 12, "cost": 320},
	{"name": "D-8K", "bytes": 8192, "watts": 17, "cost": 900},
	{"name": "D-16K", "bytes": 16384, "watts": 24, "cost": 2600},
	{"name": "D-32K", "bytes": 32768, "watts": 33, "cost": 7500},
]

## 电源：总功耗上限。不够就停机。
const PSU := [
	{"name": "P-40", "watts": 40, "cost": 0},
	{"name": "P-65", "watts": 65, "cost": 50},
	{"name": "P-100", "watts": 100, "cost": 150},
	{"name": "P-160", "watts": 160, "cost": 420},
	{"name": "P-240", "watts": 240, "cost": 1100},
	{"name": "P-340", "watts": 340, "cost": 3200},
	{"name": "P-480", "watts": 480, "cost": 9000},
]

const PARTS := ["cpu", "ram", "disk", "psu"]

## 阶段阶梯。数据规模不可选——它由进度决定，随解锁的阶段逐级变大。
##
## ops 是数组读写次数的上限（效率门槛）。这个门槛是刻意卡在"必须换更好的算法"
## 的位置上：n=16 起冒泡就过不去了，n=48 起插入排序也过不去，只能上 O(n log n)。
## 门槛值来自实测（见 tests/test_balance.gd）。
const STAGES := [
	{"name": "阶段 01", "algo": "任意排序", "n": 8, "ops": 200,
		"hint": "先把流程跑通：定义 def sort(a)，让 a 变成升序。"},
	{"name": "阶段 02", "algo": "冒泡排序", "n": 12, "ops": 300,
		"hint": "相邻两两比较，大的往后冒。这个规模冒泡还撑得住。"},
	{"name": "阶段 03", "algo": "选择排序", "n": 16, "ops": 350,
		"hint": "冒泡在这里已经超预算了（实测 476 次读写）。每轮直接找最小值。"},
	{"name": "阶段 04", "algo": "插入排序", "n": 24, "ops": 500,
		"hint": "选择排序也到极限了（实测 640）。插入排序能把读写压到 409。"},
	{"name": "阶段 05", "algo": "希尔排序", "n": 32, "ops": 800,
		"hint": "O(n²) 的三种都过不去这一关。开始考虑带间隔的插入，或者分治。"},
	{"name": "阶段 06", "algo": "归并排序", "n": 48, "ops": 1500,
		"hint": "插入排序实测 1845，超了。需要真正的 O(n log n)。"},
	{"name": "阶段 07", "algo": "快速排序", "n": 64, "ops": 1700,
		"hint": "归并需要额外一块内存，硬盘也可能不够。原地快排更省。"},
	{"name": "阶段 08", "algo": "三路快排", "n": 96, "ops": 2600,
		"hint": "预算开始咬人了，得在基准值选择上做文章。"},
	{"name": "阶段 09", "algo": "堆排序", "n": 128, "ops": 4200,
		"hint": "内存要 2K 才装得下这个数组。别忘了先升内存。"},
	{"name": "阶段 10", "algo": "内省排序", "n": 192, "ops": 6400,
		"hint": "小数组用插入排序收尾，能省下大量递归开销。"},
	{"name": "阶段 11", "algo": "极限排序", "n": 256, "ops": 8200,
		"hint": "终局。2 KB 的数组 + 递归栈，内存至少要 4K。"},
]


static func stage_count() -> int:
	return STAGES.size()


static func stage(i: int) -> Dictionary:
	if STAGES.is_empty():
		return {}
	return STAGES[clampi(i, 0, STAGES.size() - 1)]


static func table(part: String) -> Array:
	match part:
		"cpu": return CPU
		"ram": return RAM
		"disk": return DISK
		"psu": return PSU
	return []


static func spec(part: String, tier: int) -> Dictionary:
	var t := table(part)
	if t.is_empty():
		return {}
	return t[clampi(tier, 0, t.size() - 1)]


static func max_tier(part: String) -> int:
	return table(part).size() - 1


static func is_max(part: String, tier: int) -> bool:
	return tier >= max_tier(part)


static func next_cost(part: String, tier: int) -> int:
	if is_max(part, tier):
		return -1
	return int(spec(part, tier + 1)["cost"])


## 某个部件在指定等级下的功耗（电源自身不耗电）
static func watts(part: String, tier: int) -> int:
	if part == "psu":
		return 0
	return int(spec(part, tier)["watts"])


## 总功耗 = 主板 + CPU + 内存 + 硬盘
static func total_draw(cpu: int, ram: int, disk: int) -> int:
	return BASE_DRAW + watts("cpu", cpu) + watts("ram", ram) + watts("disk", disk)


## 收益。主导项是数据规模 n —— 规模越大给得越多。
## 效率系数只做 0.4~1.0 的调节：算法越接近比较排序的理论下界，拿得越多。
##
## 之所以保留效率项而不是纯粹按 n 给钱：否则"用冒泡跑大数据"和"用快排跑大数据"
## 收益完全一样，游戏就没有优化算法的理由了。电费会惩罚慢算法，但那是时间成本，
## 这里再补一层直接激励。
static func reward(n: int, ops: int) -> int:
	if ops <= 0 or n <= 1:
		return 0
	var ideal := float(n) * (log(float(n)) / log(2.0))
	var eff := clampf(2.0 * ideal / float(ops), 0.05, 1.0)
	var base := pow(float(n), 1.4) * 1.2
	return maxi(1, int(round(base * (0.4 + 0.6 * eff))))


## 达成效率门槛的额外奖励倍数
const BONUS_MULTIPLIER := 1.5


## 跑完一次任务要付的电费（狗狗币）。功率 × 秒数 × 费率。
static func power_bill(watts_total: int, seconds: float) -> float:
	return maxf(0.0, float(watts_total) * seconds * POWER_RATE)


## 内存需求估算：目标数组 + 变量余量，单位字节。
static func ram_need_bytes(n: int, var_slots: int) -> int:
	return (n + var_slots) * BYTES_PER_VALUE

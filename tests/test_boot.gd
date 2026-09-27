extends SceneTree
## 开机自检动画的逻辑体检。headless 运行：
##   godot --headless --path <项目> --script res://tests/test_boot.gd
##
## 只测**能测的那一半**：时间轴、文案、跳过。画面（故障撕裂、警示硬闪、
## 纵向收束）和声音要靠实机看/听，headless 里既没有绘制也没有音频设备。
##
## 覆盖的坑：
##   · 相位顺序反了——比如行数变多之后警示拍排到日志前面，动画会跳着播。
##   · 逐字打的时长超过行距——两行会同时在打字，光标和读头会打架。
##   · 文案没跟着 facts 走——"供电不足"这种状态在真机上要攒很久才碰得到，
##     不在这里喂一组假数据就永远没验过。

var _pass := 0
var _fail := 0

## 一组"什么都没有"的默认存档：C-01 / 512B 内存 / 512B 硬盘 / 40W 电源。
## 整机 8+8+4+3 = 23W，余量 17W，供电正常。
const FACTS_OK := {
	"ram": 512, "disk": 512, "psu": 40, "draw": 23, "cpu": 60,
	"files": 11, "unlocked": 3, "saved": true, "cleared": 0, "stages": 11,
}
## 供电不足：升了 CPU 没升电源，整机 73W 超出 40W 电源
const FACTS_OVER := {
	"ram": 2048, "disk": 1024, "psu": 40, "draw": 73, "cpu": 2600,
	"files": 11, "unlocked": 5, "saved": false, "cleared": 4, "stages": 11,
}


func _initialize() -> void:
	print("=== 能工智人·数据库 / 开机自检动画测试 ===\n")

	_test_lines()
	_test_timeline()
	_test_skip()

	print("\n=== 通过 %d / 失败 %d ===" % [_pass, _fail])
	# 一条都没跑起来（比如被测脚本自己没编译过）也算失败：
	# 否则"0 通过 0 失败"看起来是绿的，其实什么都没验。
	quit(1 if (_fail > 0 or _pass == 0) else 0)


# ---------------------------------------------------------------- 文案

func _test_lines() -> void:
	var ok: Array = BootSequence.boot_lines(FACTS_OK)
	_test("自检项够撑起一段压迫感", ok.size() >= 10, "%d 行" % ok.size())
	_test("行都有 text/status/kind",
		_all_lines_shaped(ok), "字段齐全")

	var joined := _join(ok)
	_test("常规存档念成「已读取」",
		joined.contains("已读取") and not joined.contains("未找到"),
		"存档一行")
	_test("供电正常念余量",
		joined.contains("余量 17 W") and not joined.contains("超出"),
		"40W 电源 - 23W 整机 = 17W")
	_test("数字按千分位写",
		_join(BootSequence.boot_lines(FACTS_OVER)).contains("2,600 步 / 秒"),
		"C-16 的额定速度")

	# 供电不足：同一行要变红，而不是另起一行报错
	var over: Array = BootSequence.boot_lines(FACTS_OVER)
	var load_row := _find(over, "负载分配")
	_test("供电不足时负载分配整行报警",
		String(load_row.get("kind", "")) == "alert"
			and String(load_row.get("status", "")).contains("超出 33 W"),
		"整机 73W / 电源 40W → 超出 33W")
	_test("没有存档就念「未找到」",
		_join(over).contains("未找到 · 已初始化"),
		"首次开机的分支")

	var kinds := {}
	for l in ok:
		kinds[String(l["kind"])] = true
	_test("有红字警告、也有砸出来的通告",
		kinds.has("alert") and kinds.has("loud"),
		"kind: alert + loud")


# ---------------------------------------------------------------- 时间轴

func _test_timeline() -> void:
	var seq: BootSequence = BootSequence.new()
	seq.prepare(FACTS_OK)

	var n := seq.line_count()
	_test("相位顺序：日志 → 警示 → 标题 → 收束",
		BootSequence.T_LOG < seq.alert_time() and seq.alert_time() < seq.title_time()
			and seq.title_time() < seq.cut_time() and seq.cut_time() < seq.end_time(),
		"日志 %.2f / 警示 %.2f / 标题 %.2f / 收束 %.2f / 结束 %.2f"
			% [seq.alert_time(), seq.alert_time(), seq.title_time(), seq.cut_time(), seq.end_time()])

	var total := seq.end_time()
	_test("整段时长在 4~7 秒之间",
		total >= 4.0 and total <= 7.0,
		"%.2f 秒（短了没有压迫感，长了每次开机都烦）" % total)

	var rising := true
	for i in range(1, n):
		if seq.line_time(i) <= seq.line_time(i - 1):
			rising = false
	_test("行时刻严格递增", rising, "%d 行，间隔 %.2f 秒" % [n, BootSequence.LINE_GAP])

	# 逐字打完必须落在下一行出现之前，否则两行同时打字
	var gap_ok := BootSequence.LINE_TYPE <= BootSequence.LINE_GAP
	_test("逐字时长不超过行距", gap_ok,
		"打字 %.2f / 行距 %.2f 秒" % [BootSequence.LINE_TYPE, BootSequence.LINE_GAP])

	_test("日志播完正好接上警示拍",
		is_equal_approx(seq.alert_time(), seq.line_time(n)),
		"第 %d 行 %.2f → 警示 %.2f" % [n, seq.line_time(n), seq.alert_time()])

	# 故障窗口必须落在日志相位里：跑到警示拍或标题上，就会和红框、标题抢注意力
	var inside := true
	for g in seq.glitch_windows():
		if float(g[0]) < BootSequence.T_LOG 				or float(g[0]) + float(g[1]) > seq.alert_time():
			inside = false
	_test("三处故障都落在日志相位内",
		inside and seq.glitch_windows().size() == 3,
		"%d 处：%s" % [seq.glitch_windows().size(), str(seq.glitch_windows())])

	seq.free()


# ---------------------------------------------------------------- 跳过

func _test_skip() -> void:
	var seq: BootSequence = BootSequence.new()
	seq.prepare(FACTS_OK)

	# 推到日志中间：还没结束，行已经在往外吐
	seq.advance(2.0)
	_test("推进到日志中段仍未结束",
		not seq.is_finished() and seq.elapsed() >= 2.0 and seq.elapsed() < seq.alert_time(),
		"t=%.2f，警示拍在 %.2f" % [seq.elapsed(), seq.alert_time()])

	seq.skip()
	_test("跳过落在收束相位",
		seq.elapsed() >= seq.cut_time() and not seq.is_finished(),
		"t=%.2f / 收束 %.2f" % [seq.elapsed(), seq.cut_time()])

	# 收束只有 0.35 秒：跳过之后不能拖
	seq.advance(BootSequence.T_CUT - 0.01)
	_test("收束走完就结束", not seq.is_finished(), "t=%.2f" % seq.elapsed())

	seq.free()


# ---------------------------------------------------------------- 工具

func _all_lines_shaped(lines: Array) -> bool:
	for l in lines:
		if not (l is Dictionary):
			return false
		if not (l.has("text") and l.has("status") and l.has("kind")):
			return false
		if String(l["text"]).is_empty():
			return false
	return true


func _join(lines: Array) -> String:
	var parts := PackedStringArray()
	for l in lines:
		parts.append("%s %s" % [String(l["text"]), String(l["status"])])
	return " | ".join(parts)


func _find(lines: Array, text: String) -> Dictionary:
	for l in lines:
		if String(l["text"]) == text:
			return l
	return {}


func _test(name: String, ok: bool, detail: String) -> void:
	if ok:
		_pass += 1
		print("  [通过] %-26s %s" % [name, detail])
		return
	_fail += 1
	print("  [失败] %-26s %s" % [name, detail])

extends SceneTree
## ESC 菜单的逻辑体检。headless 运行：
##   godot --headless --path <项目> --script res://tests/test_esc_menu.gd
##
## 只测**能测的那一半**：开关与暂停、页面切换、Esc 输入、音效同步、设置持久化。
## 画面（层级、背板压暗、与报错弹窗/开机动画的叠加）要靠实机看，headless 没有绘制。
##
## 覆盖的坑：
##   · 关菜单忘了解除暂停——整局从此冻住，比崩溃还像"游戏坏了"。
##   · 长按 Esc 连发 echo——菜单开了又关、关了又开，像在抽搐。
##   · 开机/接入屏还活着时菜单能被呼出——盖不住它们（z 400 < 500/600），
##     却把世界暂停了，画面会卡在自检动画的半截上。
##   · 设置持久化读回坏值——手改过的 settings.cfg 不该把音量抬出 0~1。

var _pass := 0
var _fail := 0

## 测试专用的设置文件。绝不碰玩家的 user://settings.cfg。
const TEST_CFG := "user://test_esc_settings.cfg"


func _initialize() -> void:
	_run()


## _initialize 里挂进 root 的节点要等第一帧才真正进树、才跑 _ready
## （--script 模式的时序）。先等一帧，EscMenu 的界面搭建才算完成。
func _run() -> void:
	await process_frame

	print("=== 能工智人·数据库 / ESC 菜单测试 ===\n")

	_test_open_close()
	_test_esc_input()
	_test_pages()
	_test_audio_sync()
	_test_settings_persist()
	_test_resolution()

	# 收尾：把静态值放回默认，免得影响同一进程里后来的测试
	GameSettings.audio_enabled = true
	GameSettings.volume = 1.0
	GameSettings.video_size = GameSettings.BASE_RESOLUTION
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_CFG))

	print("\n=== 通过 %d / 失败 %d ===" % [_pass, _fail])
	quit(1 if (_fail > 0 or _pass == 0) else 0)


# ---------------------------------------------------------------- 开关与暂停

func _test_open_close() -> void:
	var menu: EscMenu = _fresh_menu()

	menu.open_menu()
	_test("打开后可见、记为打开、页面回到根",
		menu.visible and menu.is_open() and menu.current_page() == EscMenu.Page.PAGE_ROOT,
		"visible=%s page=%d" % [str(menu.visible), menu.current_page()])
	_test("打开时整棵树暂停",
		paused,
		"运行中的一局、电费、循环都得跟着停")
	_test("重复 open_menu 不抖动", menu.is_open() and paused, "二次打开是空操作")

	menu._go_page(EscMenu.Page.PAGE_RESET)
	menu.close_menu()
	_test("关闭后隐藏、解除暂停",
		not menu.visible and not menu.is_open() and not paused,
		"忘了解除暂停整局就冻住了")
	menu.open_menu()
	_test("下次打开回到根页（不留在确认页）",
		menu.current_page() == EscMenu.Page.PAGE_ROOT,
		"重开还停在「确认重置」会把人吓到")
	menu.close_menu()

	menu.free()


# ---------------------------------------------------------------- Esc 输入

func _test_esc_input() -> void:
	var menu: EscMenu = _fresh_menu()

	# 关着：Esc = 打开
	_press_esc(menu)
	_test("Esc 打开菜单", menu.is_open() and paused, "第一次按")

	# 开着：Esc = 关闭
	_press_esc(menu)
	_test("再按 Esc 关闭菜单", not menu.is_open() and not paused, "第二次按")

	# 长按连发的 echo 不参与开关
	var echo := InputEventKey.new()
	echo.keycode = KEY_ESCAPE
	echo.physical_keycode = KEY_ESCAPE
	echo.pressed = true
	echo.echo = true
	menu._unhandled_input(echo)
	_test("echo 事件不触发开关", not menu.is_open() and not paused,
		"长按 Esc 不能让菜单抽搐")

	# 普通按键不开菜单
	var other := InputEventKey.new()
	other.keycode = KEY_A
	other.pressed = true
	menu._unhandled_input(other)
	_test("普通按键不开菜单", not menu.is_open(), "防止任何键都能呼出")

	menu.free()


func _press_esc(menu: EscMenu) -> void:
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.physical_keycode = KEY_ESCAPE
	ev.pressed = true
	menu._unhandled_input(ev)


# ---------------------------------------------------------------- 页面切换

func _test_pages() -> void:
	var menu: EscMenu = _fresh_menu()
	menu.open_menu()

	menu._go_page(EscMenu.Page.PAGE_SETTINGS)
	_test("设置页可进", menu.current_page() == EscMenu.Page.PAGE_SETTINGS, "根页 → 设置")
	menu._go_root()
	_test("返回根页", menu.current_page() == EscMenu.Page.PAGE_ROOT, "设置 → 根页")

	menu._go_page(EscMenu.Page.PAGE_QUIT)
	_test("退出确认页可进", menu.current_page() == EscMenu.Page.PAGE_QUIT, "根页 → 退出确认")
	menu._go_root()

	# 四页互斥可见：走到任何一页，另外三页都得藏起来
	var one_each := true
	for p in [EscMenu.Page.PAGE_ROOT, EscMenu.Page.PAGE_SETTINGS,
			EscMenu.Page.PAGE_RESET, EscMenu.Page.PAGE_QUIT]:
		menu._go_page(p)
		for q in [EscMenu.Page.PAGE_ROOT, EscMenu.Page.PAGE_SETTINGS,
				EscMenu.Page.PAGE_RESET, EscMenu.Page.PAGE_QUIT]:
			var ctl: Control = menu.page_control(q)
			if ctl == null or ctl.visible != (q == p):
				one_each = false
	_test("任意时刻恰好一页可见", one_each, "4×4 全组合走查")

	menu.close_menu()
	menu.free()


# ---------------------------------------------------------------- 音效同步

func _test_audio_sync() -> void:
	var menu: EscMenu = _fresh_menu()

	menu.sync_audio(false)
	_test("sync_audio(false) 后按钮念「关」",
		menu.audio_button_text() == "音效：关", "Main 的按钮切换会同步到这里")
	menu.sync_audio(true)
	_test("sync_audio(true) 后按钮念「开」",
		menu.audio_button_text() == "音效：开", "来回都要对")

	menu.free()


# ---------------------------------------------------------------- 设置持久化

func _test_settings_persist() -> void:
	# 先把可能存在的测试文件清掉，从"没有文件"这个已知状态出发
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_CFG))

	GameSettings.audio_enabled = false
	GameSettings.volume = 0.37
	GameSettings.video_size = GameSettings.RESOLUTIONS[1]   # 3200×1800，2 倍
	GameSettings.save(TEST_CFG)
	GameSettings.audio_enabled = true
	GameSettings.volume = 1.0
	GameSettings.video_size = GameSettings.BASE_RESOLUTION
	GameSettings.load(TEST_CFG)
	_test("存进盘的值原样读回来",
		not GameSettings.audio_enabled and is_equal_approx(GameSettings.volume, 0.37)
			and GameSettings.video_size == GameSettings.RESOLUTIONS[1],
		"音效关 + 音量 37% + 3200×1800")

	# 手改过的坏值：音量夹回 0~1，分辨率只认预设表里的
	var cf := ConfigFile.new()
	cf.set_value("system", "audio_enabled", true)
	cf.set_value("system", "volume", 5.0)
	cf.set_value("video", "width", 1234)
	cf.set_value("video", "height", 567)
	cf.save(TEST_CFG)
	GameSettings.volume = 0.5
	GameSettings.load(TEST_CFG)
	_test("坏值夹回 0~1", is_equal_approx(GameSettings.volume, 1.0), "volume=5 → 1.0")
	_test("怪尺寸回退基准",
		GameSettings.video_size == GameSettings.BASE_RESOLUTION,
		"1234×567 不在预设表里")

	GameSettings.volume = 0.0
	GameSettings.apply_volume()
	_test("音量 0 = Master 静音",
		AudioServer.is_bus_mute(0), "linear_to_db(0) 是负无穷，得显式哑掉")
	GameSettings.volume = 0.5
	GameSettings.apply_volume()
	_test("音量回抬后解除静音", not AudioServer.is_bus_mute(0), "不然拉回来也没声")


# ---------------------------------------------------------------- 分辨率

func _test_resolution() -> void:
	# 预设表本身的自洽：都是基准的整数倍，且严格递增
	var all_multiples := true
	var rising := true
	for i in GameSettings.RESOLUTIONS.size():
		var r: Vector2i = GameSettings.RESOLUTIONS[i]
		if r.x % GameSettings.BASE_RESOLUTION.x != 0 or r.y % GameSettings.BASE_RESOLUTION.y != 0:
			all_multiples = false
		if i > 0 and GameSettings.RESOLUTIONS[i - 1].x >= r.x:
			rising = false
	_test("预设全是基准的整数倍", all_multiples,
		"点阵字体只有 12/24/36，字随窗口放大只有整倍一条路")
	_test("预设按宽度严格递增且不低于基准", rising,
		"下拉框的顺序与范围；基准是排版下限")
	_test("基准本身在预设表里",
		GameSettings.RESOLUTIONS.has(GameSettings.BASE_RESOLUTION),
		"1 倍档永远存在")

	# 坏值兜底：只含音效/音量的老设置文件（没有 video 字段）→ 分辨率回基准
	var old_cf := ConfigFile.new()
	old_cf.set_value("system", "audio_enabled", true)
	old_cf.set_value("system", "volume", 0.8)
	old_cf.save(TEST_CFG)
	GameSettings.video_size = GameSettings.RESOLUTIONS[1]
	GameSettings.load(TEST_CFG)
	_test("缺 video 字段回退基准",
		GameSettings.video_size == GameSettings.BASE_RESOLUTION, "老设置文件不含分辨率")


# ---------------------------------------------------------------- 工具

func _fresh_menu() -> EscMenu:
	var menu: EscMenu = EscMenu.new()
	root.add_child(menu)
	return menu


func _test(name: String, ok: bool, detail: String) -> void:
	if ok:
		_pass += 1
		print("  [通过] %-26s %s" % [name, detail])
		return
	_fail += 1
	print("  [失败] %-26s %s" % [name, detail])

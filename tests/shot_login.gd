extends SceneTree
## 实机截图工具（不是测试）：接入屏在不同窗口尺寸下的虚线表现。
##   godot --path <项目> --script res://tests/shot_login.gd
##
## 接入屏是预案（INTRO_SHOW_LOGIN=false 时不播），这里直接实例化它来看画面。
## 三个窗口尺寸各截一张：基准 1600×900、整倍 3200×1800、非整倍 2400×1350。

const SIZES := [
	["base_1600x900", Vector2i(1600, 900)],
	["x2_3200x1800", Vector2i(3200, 1800)],
	["x15_2400x1350", Vector2i(2400, 1350)],
]


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame

	var login: LoginScreen = LoginScreen.new()
	root.add_child(login)
	await create_timer(1.2).timeout     # 等白屏元素全部落定

	for s in SIZES:
		DisplayServer.window_set_size(s[1])
		await create_timer(0.5).timeout  # 等布局与重绘稳定
		await _shot("/tmp/login_%s.png" % s[0])
		print("saved ", "/tmp/login_%s.png" % s[0],
			"  viewport=", root.get_visible_rect().size,
			" scale=", root.content_scale_factor)

	quit(0)


func _shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	img.save_png(path)

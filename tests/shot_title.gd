extends SceneTree
## 实机截图工具（不是测试，不会在 CI 里跑）：
##   godot --path <项目> --script res://tests/shot_title.gd
##
## 开真窗口走一遍入场流程，四个时点各存一张 PNG 到 /tmp：
##   1 标题屏入场落定（默认对焦在画面中心）
##   2 对焦点挪到右上（景深与视差应该肉眼可见地变了）
##   3 确认登入、穿过开机自检后的主界面（验证交棒不闪不破）
##   4 再来一张主界面稳定态
##
## 产物给人工/视觉检查用；脚本自己不判断对错，退出码恒为 0。

const SHOT_1 := "/tmp/title_1_default.png"
const SHOT_2 := "/tmp/title_2_focus.png"
const SHOT_3 := "/tmp/title_3_main.png"


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame

	var main: Control = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)

	# 1) 标题屏入场（翻块 + 元素落定 ~1s）走完
	await create_timer(1.8).timeout
	await _shot(SHOT_1)

	# 2) 对焦点挪到右上角，等平滑追上
	var title: TitleScreen = main.title()
	if title != null:
		title.set_focus_target(Vector2(0.84, 0.22))
		await create_timer(1.2).timeout
		await _shot(SHOT_2)

		# 3) 确认登入 → 翻黑 → 自检（约 5 秒）→ 主界面
		title.confirm()
		await create_timer(7.5).timeout
		await _shot(SHOT_3)

	print("shots saved: %s %s %s" % [SHOT_1, SHOT_2, SHOT_3])
	quit(0)


func _shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	img.save_png(path)
	print("saved ", path)

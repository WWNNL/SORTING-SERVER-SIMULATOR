extends SceneTree
## 实机截图工具（不是测试，不会在 CI 里跑）：
##   godot --path <项目> --script res://tests/shot_title.gd
##
## 开真窗口走一遍开始菜单流程，四个时点各存一张 PNG 到 /tmp：
##   1 开始菜单默认态（对焦在画面中段）
##   2 鼠标挪到右上（对焦远处 + 视差，景深应该肉眼可见地变了）
##   3 鼠标挪到右下（对焦近处，画面底部变实、远处糊开）
##   4 确认登入、穿过开机自检后的主界面（验证交棒不闪不破）
##
## 产物给人工/视觉检查用；脚本自己不判断对错，退出码恒为 0。

const SHOT_1 := "/tmp/title_1_default.png"
const SHOT_2 := "/tmp/title_2_focus_far.png"
const SHOT_3 := "/tmp/title_3_focus_near.png"
const SHOT_4 := "/tmp/title_4_main.png"


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame

	var main: Control = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)

	# 开始菜单是 main 的一个子节点（Main 没有暴露访问器，按类型找）
	var titles := main.find_children("*", "TitleScreen", false, false)
	if titles.is_empty():
		print("TitleScreen not found!")
		quit(1)
		return
	var title: TitleScreen = titles[0]
	var backdrop: TitleBackdrop = title.get_child(0)

	# 1) 背景与流光落定
	await create_timer(1.5).timeout
	await _shot(SHOT_1)

	# 2) 对焦远处（鼠标靠上偏右），等平滑追上
	backdrop.follow_mouse = false
	backdrop.set_mouse_target(Vector2(0.85, 0.12))
	await create_timer(1.2).timeout
	await _shot(SHOT_2)

	# 3) 对焦近处（鼠标靠下偏右）
	backdrop.set_mouse_target(Vector2(0.85, 0.95))
	await create_timer(1.2).timeout
	await _shot(SHOT_3)

	# 4) 确认登入 → 色带翻黑 → 自检（约 5 秒）→ 主界面
	title.activate(0)
	await create_timer(7.5).timeout
	await _shot(SHOT_4)

	print("shots saved: %s %s %s %s" % [SHOT_1, SHOT_2, SHOT_3, SHOT_4])
	quit(0)


func _shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	img.save_png(path)
	print("saved ", path)

class_name GameSettings
extends RefCounted
## 系统设置（ESC 菜单 → 设置 → 系统设置）的持久化。
##
## 和玩家进度（Game / save.json）刻意分开：这是"这台机器怎么表现"，
## 不是"玩家玩到哪儿了"。重置进度不该动它，删存档也不该丢它。
##
## 刻意用静态字段而不是实例：音效开关的三个写入口（控制行按钮、ESC 菜单、
## 开局读盘）改的都是同一份，静态字段让"当前值"全局只有一处。
## Prts._body_font 也是这么做的。

const DEFAULT_PATH := "user://settings.cfg"

const SECTION := "system"
const KEY_AUDIO := "audio_enabled"
const KEY_VOLUME := "volume"

const SECTION_VIDEO := "video"
const KEY_WIDTH := "width"
const KEY_HEIGHT := "height"

## 基准分辨率 = 设计分辨率（project.godot 的 viewport 尺寸）。
## 整套排版按它量死（底部控制行最小内容 ~817px，见 main.gd 控制行的实测注释），
## 而且**永远固定**在这里——窗口只是把这张画面整倍放大，字体才跟着窗口变大。
const BASE_RESOLUTION := Vector2i(1600, 900)

## 窗口分辨率 = 设计分辨率的整数倍，全部列出、不做屏幕过滤。
##
## 点阵字体只有 12/24/36 三个合法字号（见 prts.gd 的实测说明），所以"字随窗口
## 放大"只有整数倍一条路：窗口把 1600×900 的画面按整数倍 nearest 放大
## （blit 固定 GL_NEAREST），2 倍就是像素 2×2，字体、按钮、边框一起变大，一丝不糊。
## **刻意不提供 1.5 倍这类中间档**：12px 字形放大 1.5 倍必然半像素糊边；
## 而保持字号不放大的话（渲染基准跟到窗口），就只剩"窗口大了字没大"一片空白
## ——两版都实测过，都不是玩家要的"分辨率"。
const RESOLUTIONS: Array[Vector2i] = [
	Vector2i(1600, 900),
	Vector2i(3200, 1800),
	Vector2i(4800, 2700),
]

## 音效总开关。真正的开关动作走 Main.set_audio_enabled（按钮、弹窗、菜单三处同步），
## 这里只存"上次是多少"。
static var audio_enabled := true
## 主音量 0.0 ~ 1.0（0 = 静音）。
static var volume := 1.0
## 窗口分辨率。load 校验过，一定是 RESOLUTIONS 里的值。
static var video_size := BASE_RESOLUTION


## 从盘上读。文件不存在、字段缺失、坏值都按默认处理。
## 刻意**只读不应用**：音量、分辨率何时生效由调用方决定
## （测试里也读这个文件，不该顺手去动真实的窗口和音频总线）。
## path 留空用默认位置；测试传自己的文件名，绝不碰玩家的设置。
static func load(path := DEFAULT_PATH) -> void:
	var cf := ConfigFile.new()
	if cf.load(path) != OK:
		return
	audio_enabled = bool(cf.get_value(SECTION, KEY_AUDIO, true))
	volume = clampf(float(cf.get_value(SECTION, KEY_VOLUME, 1.0)), 0.0, 1.0)
	var saved := Vector2i(int(cf.get_value(SECTION_VIDEO, KEY_WIDTH, 0)),
		int(cf.get_value(SECTION_VIDEO, KEY_HEIGHT, 0)))
	# 只认预设表里的值：手改过的怪尺寸直接回默认，不喂给窗口
	video_size = saved if RESOLUTIONS.has(saved) else BASE_RESOLUTION


## 把窗口设成 video_size 并居中。渲染基准**不碰**——它永远固定在设计分辨率，
## 窗口多大都是把 1600×900 的画面整倍放大（见 RESOLUTIONS 的说明）：
## 基准一旦跟到窗口，字体就不放大了（上一版踩过：窗口大了字没大）。
static func apply_resolution() -> void:
	DisplayServer.window_set_size(video_size)
	var screen := DisplayServer.screen_get_usable_rect(
		DisplayServer.window_get_current_screen())
	if screen.size.x > 0 and screen.size.y > 0:
		DisplayServer.window_set_position(screen.position + (screen.size - video_size) / 2)


## 写盘。写失败不当回事（和存档同一待遇）：沙箱或权限问题下丢的只是
## "下次开机还记得"，不该因此崩掉游戏。
static func save(path := DEFAULT_PATH) -> void:
	var cf := ConfigFile.new()
	cf.set_value(SECTION, KEY_AUDIO, audio_enabled)
	cf.set_value(SECTION, KEY_VOLUME, volume)
	cf.set_value(SECTION_VIDEO, KEY_WIDTH, video_size.x)
	cf.set_value(SECTION_VIDEO, KEY_HEIGHT, video_size.y)
	cf.save(path)


## 把音量应用到 Master 总线。0 视作静音（直接哑掉总线），
## 其余换算成分贝——linear_to_db(0) 是负无穷，得在下面垫一个下限。
static func apply_volume() -> void:
	var bus := AudioServer.get_bus_index("Master")
	if bus < 0:
		return
	AudioServer.set_bus_mute(bus, volume <= 0.001)
	AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(volume, 0.001)))


## 注销用户用：把内存里的设置拍回默认值。只动字段；音量总线、窗口
## 要不要跟着拍回去由调用方调 apply_volume / apply_resolution 决定——
## 和 load 的"只读不应用"是同一条规矩。
static func reset_defaults() -> void:
	audio_enabled = true
	volume = 1.0
	video_size = BASE_RESOLUTION

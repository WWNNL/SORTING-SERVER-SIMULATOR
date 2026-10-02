class_name TitleScreen
extends Control
## 开始菜单：进游戏前的第一屏，两个选项——登入 / 退出。
##
## 这是整套界面里唯一一屏"看得见机房"的地方，所以它承担的是世界观的门面：
## 玩家不是"点了一个按钮开始游戏"，而是站在 PRTS 的机柜通道口，决定接不接进去。
## 背景是 Blender 烘的写实机房（assets/title/title_room.png），
## 上面压着一层实时明灭的机柜指示灯（TitleStreams），镜头随鼠标微动、焦点随
## 鼠标上下走（TitleBackdrop）。三样东西的分工写在各自文件的开头。
##
## 版面刻意偏左：右边留给灭点，文字全在左边的暗部。
## 左边的机柜本身很亮（一排荧光条），所以背景层自带一层从左往右淡出的压暗
## （TitleBackdrop 的压暗层），文字才压得住。
##
## 全自绘，不用 Button：菜单只有两项，需要的是"整行反白 + 左边一条竖标"
## 这种精确到像素的排版，控件树反而绕。代价是命中测试要自己写（见 item_at）。
##
## 流程：登入 → 播一段收场（色带翻黑，和接入屏同一种语汇）→ 交棒给开机自检；
## 退出 → 同样的收场 → 请求退出。两个动作都走同一条收场路径，
## 差别只在最后那句状态文案和交棒对象。
##
## 声音只用两声：悬停的嗒声和收场的下滑音（借用 BootAudio 的合成音，
## 嗡鸣不用——那是开机自检的）。音效开关关掉时一声不响。

## 收场播完，该进游戏了。Main 接这个信号挂上开机自检。
signal finished
## 收场播完，该退出了。Main 接这个信号去退程序——这一屏自己不认识应用生命周期。
signal quit_requested

enum { ST_MAIN, ST_LOGIN, ST_QUIT, ST_DONE }

## 开始菜单的音效音量。BootAudio 的默认音量是给自检定的——tick -14dB 是
## "十几声连着来"的背景嗒声；菜单里总共就两三个音，还压着一段静音的机房，
## 得站到台前来：嗒声提 9dB、收场提 4dB（波形峰值离满幅还远，不会削波）。
const TICK_DB := -5.0
const CUT_DB := -3.0

## 菜单两项。文案中间留空格是这套界面的老写法（ESC 菜单的「设 置」也是这样）。
const ITEMS := [
	{"label": "登 入", "note": "接入 PRTS 排序单元"},
	{"label": "退 出", "note": "断开连接，退出程序"},
]

# ---------------------------------------------------------------- 版面（占屏比）

const PAD := 0.045          ## 左右留白
const BRAND_Y := 0.107      ## PRTS 的基线
const TITLE_Y := 0.415      ## 主标题基线
const MENU_Y := 0.545       ## 第一项菜单的顶边
const ITEM_W := 0.205       ## 菜单条宽度
const ITEM_H := 50.0
const ITEM_GAP := 6.0
## 菜单条左边比正文再往外让一点：反白块比文字宽出来一截才像"一行"，
## 而不是"一块贴字的色块"。
const ITEM_BLEED := 10.0
const TEXT_INSET := 26.0

# ---------------------------------------------------------------- 时间轴

## 收场：色带从下往上翻黑（和接入屏白→黑那一手是同一套语汇）。
## 每条带子整条硬切（不淡入），带子之间错开 BAND_GAP，全部翻完再停 T_HOLD 交棒。
const BAND_COUNT := 6
const BAND_GAP := 0.05
const T_HOLD := 0.22
## 单帧最多按多少秒推进。异常长的一帧（拖窗口、系统卡顿）会把整段收场
## 一次性推过去——玩家看到的就是"闪一下就没了"（和自检、接入屏同一条规矩）。
const MAX_STEP_DELTA := 0.10

var _state := ST_MAIN
var _t := 0.0
var _hover := 0
var _done := false
## 这一次收场通向哪里：true = 退出，false = 登入。
## 在 _begin 里记下，因为 _finish 的时候 _state 已经不重要了（都是收场）。
var _quit_armed := false
var _title_font: FontVariation = null
var _audio: BootAudio = null

var _backdrop: TitleBackdrop
var _streams: TitleStreams
## 菜单层。自绘都画在它身上（原因见 _draw_ui 的说明）。
var _ui: Control


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# 压住报错弹窗（300）、ESC 菜单（400）、开机自检（500）、接入屏（600）：
	# 开始菜单是玩家看到的第一屏，也永远是最上层。
	z_index = 700
	mouse_filter = Control.MOUSE_FILTER_STOP


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_title_font = Prts.spaced_font(Prts.body_font(), 2)

	_backdrop = TitleBackdrop.new()
	add_child(_backdrop)

	_streams = TitleStreams.new()
	add_child(_streams)

	# 菜单层挂在最后 = 画在最上面。父节点自己的 _draw 是先于所有子节点画的，
	# 菜单要是画在 TitleScreen 自己身上，会被背景和流光整个盖住（踩过）。
	_ui = Control.new()
	_ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.draw.connect(_draw_ui)
	add_child(_ui)

	_audio = BootAudio.new()
	_audio.name = "TitleAudio"
	add_child(_audio)

	# 鼠标位置不用在这里喂：背景层每帧自己读视口鼠标，
	# 第一帧布局算出来时它会直接落位（见 TitleBackdrop.advance）。
	set_process(true)
	_redraw()


## 重画菜单层。背景和流光各自在自己的 _process 里刷新。
func _redraw() -> void:
	if _ui != null:
		_ui.queue_redraw()


func _process(delta: float) -> void:
	advance(minf(delta, MAX_STEP_DELTA))
	# 流光跟着机房的远景层一起平移、并跟随同一个焦点：
	# 它画在背景之上，两边要是各走各的，光就"浮"在机柜外面了。
	if _backdrop != null and _streams != null:
		_streams.set_parallax(_backdrop.layer_offset(0))
		_streams.set_focus(_backdrop.focus())


## 推进时间轴。_process 只是转调它，测试可以直接按秒推进，不用等真实帧。
func advance(delta: float) -> void:
	if _done:
		return
	_t += delta
	match _state:
		ST_LOGIN, ST_QUIT:
			if _t >= total_time():
				_finish()
				return
	_redraw()


# ================================================================ 时间轴（纯函数）

## 色带全部翻完的时刻（最上面那条翻黑的时候）
static func wipe_done() -> float:
	return BAND_GAP * float(BAND_COUNT - 1)


## 收场总共多久：翻完 + 停一下
static func total_time() -> float:
	return wipe_done() + T_HOLD


## 第 i 条色带（i = 0 是最上面那条）此刻翻黑了没有。
## 从下往上翻：越靠下翻得越早。玩家盯着的是画面中上部的菜单，
## 从下面翻上来"先收走地面"，和接入屏白→黑的方向一致。
static func band_black(i: int, elapsed: float) -> bool:
	return elapsed >= BAND_GAP * float(BAND_COUNT - 1 - i)


## 色带的几何：等高横切，拼满整屏、互不重叠（和接入屏的 bands 同一条要求——
## 留缝会透出底下的主界面，叠上会露出颜色不对的边）。
static func bands(w: float, h: float) -> Array:
	var out: Array = []
	var bh := h / float(BAND_COUNT)
	for i in BAND_COUNT:
		out.append(Rect2(0.0, bh * float(i), w, bh))
	return out


# ================================================================ 菜单

func item_count() -> int:
	return ITEMS.size()


func item_label(i: int) -> String:
	if i < 0 or i >= ITEMS.size():
		return ""
	return String((ITEMS[i] as Dictionary)["label"])


func selected() -> int:
	return _hover


func state() -> int:
	return _state


func is_finished() -> bool:
	return _done


## 上下移动选择。转圈：在最后一项再往下就回到第一项。
## 只在主状态认——收场已经开始之后再按键不该还有反应。
func move_selection(delta: int) -> void:
	if _state != ST_MAIN or delta == 0:
		return
	var n := ITEMS.size()
	_hover = posmod(_hover + delta, n)
	_tick()
	_redraw()


## 某一项菜单条的矩形（屏幕坐标）。命中测试与绘制共用同一份几何——
## 两处各算一遍的话，鼠标点和画出来的框迟早会对不上。
func item_rect(i: int) -> Rect2:
	var w := size.x * ITEM_W
	var h := ITEM_H
	var x := size.x * PAD - ITEM_BLEED
	var y := size.y * MENU_Y + (h + ITEM_GAP) * float(i)
	return Rect2(x, y, w + ITEM_BLEED, h)


## 鼠标落在哪一项上。-1 = 都不在（点在空白处不该误触发）。
func item_at(pos: Vector2) -> int:
	for i in ITEMS.size():
		if item_rect(i).has_point(pos):
			return i
	return -1


## 选中某一项（悬停）。返回是否真的变了。
func hover(i: int) -> bool:
	if i < 0 or i >= ITEMS.size() or i == _hover:
		return false
	_hover = i
	_tick()
	_redraw()
	return true


func activate(i: int) -> void:
	if _state != ST_MAIN or i < 0 or i >= ITEMS.size():
		return
	hover(i)
	_begin(ST_LOGIN if i == 0 else ST_QUIT)


func activate_selected() -> void:
	activate(_hover)


# ================================================================ 状态机

func _begin(next: int) -> void:
	_state = next
	_quit_armed = next == ST_QUIT
	_t = 0.0
	# 收场音：下滑音。嗡鸣不用（那是开机自检的），这里只要一个干脆的收束。
	if _audio != null and GameSettings.audio_enabled:
		_audio.play_cut(CUT_DB)
	_redraw()


func _finish() -> void:
	if _done:
		return
	_done = true
	_state = ST_DONE
	if _audio != null:
		_audio.stop_all()
	# 交棒：登入交给 Main 挂开机自检，退出交给 Main 退程序。
	# 这一屏自己 queue_free——挂着它的地方不用记着"播完要清掉"。
	if _quit_armed:
		quit_requested.emit()
	else:
		finished.emit()
	queue_free()


func _tick() -> void:
	if _audio != null and GameSettings.audio_enabled:
		_audio.play_tick(TICK_DB)


# ================================================================ 输入

## 开始菜单期间把所有输入都吃掉（含鼠标移动）：底下那一屏（还没露面的主界面）
## 收到一半输入只会在结束时留下一堆悬停状态——和自检、接入屏同一条规矩。
##
## 主状态：上下/WS 选，回车/空格确认，鼠标悬停即选中、点击即确认。
## 收场中：只吃输入，什么都不做（这时候再点一下，不该有第二次反应）。
func _input(event: InputEvent) -> void:
	if _done:
		return
	var handled := true
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo:
			_key(k)
	elif event is InputEventMouseMotion:
		if _state == ST_MAIN:
			hover(item_at((event as InputEventMouseMotion).position))
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and _state == ST_MAIN:
			var i := item_at(mb.position)
			if i >= 0:
				activate(i)
	elif event is InputEventJoypadButton:
		var jb := event as InputEventJoypadButton
		if jb.pressed and _state == ST_MAIN:
			if jb.button_index == JOY_BUTTON_DPAD_UP:
				move_selection(-1)
			elif jb.button_index == JOY_BUTTON_DPAD_DOWN:
				move_selection(1)
			elif jb.button_index == JOY_BUTTON_A:
				activate_selected()
	else:
		handled = false
	if handled:
		get_viewport().set_input_as_handled()


func _key(k: InputEventKey) -> void:
	if _state != ST_MAIN:
		return
	if k.is_action_pressed("ui_up") or k.keycode == KEY_W:
		move_selection(-1)
	elif k.is_action_pressed("ui_down") or k.keycode == KEY_S:
		move_selection(1)
	elif k.is_action_pressed("ui_accept") or k.keycode == KEY_ENTER \
			or k.keycode == KEY_KP_ENTER or k.keycode == KEY_SPACE:
		activate_selected()


# ================================================================ 绘制

## 菜单层的自绘。**不能**画在 TitleScreen 自己的 _draw 里：父节点自己的绘制
## 先于所有子节点，画在那儿会被背景和流光整个盖住（实测第一版菜单一个字都看不见）。
## 所以单开一个 _ui 子节点、挂在最后，再把它的 draw 信号接到这里。
func _draw_ui() -> void:
	var w := size.x
	var h := size.y
	if w < 64.0 or h < 64.0:
		return
	var font := Prts.body_font()

	_draw_brand(w, font)
	_draw_head(w, h, font)
	_draw_menu(w, h, font)
	_draw_foot(w, h, font)

	if _state == ST_LOGIN or _state == ST_QUIT:
		_draw_wipe(w, h)
		_draw_note(w, h, font)


## 左上角：品牌。和接入屏同一套署名，只是这里已经进到"PRTS 的地盘"了——
## 所以是冷白黑底，不是接入屏那种暖白。
func _draw_brand(w: float, font: Font) -> void:
	var x := w * PAD
	var y := size.y * BRAND_Y
	_ui.draw_string(_title_font, Vector2(x, y), "PRTS",
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_HUGE, Prts.WHITE)
	_ui.draw_string(font, Vector2(x, y + 24.0), "SORTING SERVER SIMULATOR",
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_SMALL, Prts.TEXT_HI)
	_ui.draw_rect(Rect2(x, y + 38.0, 268.0, 1.0), Prts.LINE)


## 主标题块：大标题 + 一条从中心展开的白线 + 一行说明。
func _draw_head(w: float, h: float, font: Font) -> void:
	var x := w * PAD
	var y := h * TITLE_Y
	var title := "能工智人 · 数据库"
	_ui.draw_string(font, Vector2(x, y), title, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
		Prts.FS_HUGE, Prts.WHITE)
	var tw := font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_HUGE).x
	# 线只画到标题宽度：拉满整屏就成了一条分隔线，不是"标题的下划线"。
	# +22 是量出来的：36px 点阵字的字脚到基线以下还有几个像素，+14 会压着字脚。
	_ui.draw_rect(Rect2(x, y + 22.0, tw, 1.0), Prts.WHITE)
	_ui.draw_string(font, Vector2(x, y + 44.0), "排序单元 SORT-01 · 外部接入终端",
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_SMALL, Prts.TEXT_HI)


## 两项菜单。选中的整条反白（这套界面里"当前项"就是这个写法），
## 未选中的只有左边一条竖标——两项目标不用加图标或箭头。
func _draw_menu(w: float, h: float, font: Font) -> void:
	var x := w * PAD
	for i in ITEMS.size():
		var r := item_rect(i)
		var label := String((ITEMS[i] as Dictionary)["label"])
		var note := String((ITEMS[i] as Dictionary)["note"])
		var on := i == _hover
		if on:
			_ui.draw_rect(r, Prts.WHITE)
			_ui.draw_string(font, Vector2(r.position.x + TEXT_INSET, r.position.y + 34.0),
				label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_BIG, Prts.BLACK)
			_ui.draw_string(font, Vector2(r.position.x + TEXT_INSET + 96.0,
				r.position.y + 33.0), note, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
				Prts.FS_SMALL, Prts.BLACK)
		else:
			# 竖标：白色 2px，是这套界面里"可选项"的记号（Prts.section 同款）
			_ui.draw_rect(Rect2(x - ITEM_BLEED, r.position.y + 16.0, 2.0, 18.0), Prts.LINE_HI)
			_ui.draw_string(font, Vector2(r.position.x + TEXT_INSET, r.position.y + 34.0),
				label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_BIG, Prts.TEXT_HI)
			_ui.draw_string(font, Vector2(r.position.x + TEXT_INSET + 96.0,
				r.position.y + 33.0), note, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
				Prts.FS_SMALL, Prts.DIM)


## 页脚：左边念存档（这台机器认识你），右边是操作提示与署名。
func _draw_foot(w: float, h: float, font: Font) -> void:
	var f := facts()
	var x := w * PAD
	var y := h - 74.0
	var line1: String
	var line2: String
	if bool(f["saved"]):
		line1 = "存档：已通过 %d / %d 关 · 算法库 %d 个文件" % [
			int(f["cleared"]), int(f["stages"]), int(f["files"])]
		line2 = "狗狗币 Ð%s · 累计完成 %d 次排序" % [
			Prts.comma1(float(f["coins"])), int(f["runs"])]
	else:
		line1 = "存档：未找到 · 接入后初始化"
		line2 = "狗狗币 Ð0.0 · 尚无成绩记录"
	_ui.draw_string(font, Vector2(x, y), line1, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
		Prts.FS_SMALL, Prts.TEXT)
	_ui.draw_string(font, Vector2(x, y + 24.0), line2, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
		Prts.FS_SMALL, Prts.DIM)

	var rx := w - w * PAD
	_ui.draw_string(font, Vector2(rx - 420.0, y), "W / S 选择 · Enter 确认 · 也可直接点",
		HORIZONTAL_ALIGNMENT_RIGHT, 420.0, Prts.FS_SMALL, Prts.DIM)
	_ui.draw_string(font, Vector2(rx - 420.0, y + 24.0), "PRTS // 外部接入终端",
		HORIZONTAL_ALIGNMENT_RIGHT, 420.0, Prts.FS_SMALL, Prts.LINE_HI)

	# 右上角的状态：一个方块光标 + 一行字。方块是画的，不是字形——
	# 点阵字体里没有方块符号，混进来会掉到系统字体上，字形风格当场就花。
	var sx := rx - 200.0
	_ui.draw_string(font, Vector2(sx, size.y * BRAND_Y), "外部接入 · 待操作",
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_SMALL, Prts.TEXT_HI)
	if fmod(_t, 1.2) < 0.72:
		_ui.draw_rect(Rect2(sx - 14.0, size.y * BRAND_Y - 10.0, 6.0, 11.0), Prts.WHITE)


## 收场：色带从下往上翻黑。
func _draw_wipe(w: float, h: float) -> void:
	var bs := bands(w, h)
	for i in bs.size():
		if band_black(i, _t):
			_ui.draw_rect(bs[i], Prts.BLACK)


## 收场时那句状态文案，压在色带之上：屏幕已经黑了大半，
## 这行字是"机器还在说话"的最后一句。
func _draw_note(w: float, h: float, font: Font) -> void:
	var p := clampf((_t - wipe_done() * 0.55) / 0.22, 0.0, 1.0)
	if p <= 0.0:
		return
	var text := "正在建立连接…" if _state == ST_LOGIN else "正在断开连接…"
	var col := Prts.TEXT_HI
	col.a = p
	_ui.draw_string(font, Vector2(w * PAD, h - 48.0), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, Prts.FS_BODY, col)


# ================================================================ 存档

## 念出来的数字全部来自真实的存档。开始菜单是"这台机器认识你"的第一处——
## 写死的文案做不到这一点。取不到 Game（headless 测试里没有 autoload）
## 就退回"裸机"默认值，和 BootSequence 的处理一致。
func facts() -> Dictionary:
	var game: Variant = null
	if is_inside_tree():
		game = get_node_or_null("/root/Game")
	if game == null:
		return {"saved": false, "cleared": 0, "stages": ServerSpec.stage_count(),
			"files": 0, "coins": 0.0, "runs": 0}
	return {
		"saved": FileAccess.file_exists(String(game.SAVE_PATH)),
		"cleared": int(game.cleared),
		"stages": ServerSpec.stage_count(),
		"files": game.files.size(),
		"coins": float(game.coins),
		"runs": int(game.stats["completed"]),
	}

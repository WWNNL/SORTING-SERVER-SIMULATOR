class_name BootAudio
extends Node
## 开机自检的拟音。和 SortAudio 一样全部现场合成（AudioStreamWAV），
## 仓库里不出现任何音频文件——这几个声音都是"一条包络 + 一两个振荡器"，
## 合成比找素材快，也不会有采样边界爆音。
##
## 五个声音各有分工，合起来是"机器醒来 → 逐行自检 → 报警 → 砸下标题 → 关机收束"：
##   hum    低频嗡鸣 + 一路缓慢升调的电流声，铺满整段自检。压迫感的地基：
##          它一直在，音高一直在涨，玩家不会注意它，但关掉会立刻觉得空。
##   tick   每行自检落字的一声嗒。音量刻意小（-14dB）：十几声连着来，
##          响一点就从"机器在跑"变成"有人在敲键盘"。
##          开始菜单借用它当悬停音时嫌这个音量太小（那边总共两三个音），
##          play_tick/play_cut 都收一个可选的 volume_db，由调用方改档。
##   buzz   警示拍的双音蜂鸣。波形不在这个文件里——报错弹窗也要响同一个声音，
##          所以它被抽成了 AlertTone，两处共用。
##   thump  标题砸下时的闷响：频率从 90Hz 滑到 35Hz，尾巴拖长，
##          是整段里最重的一下。
##   cut    收束时的下滑音（老电视关机那一声）。跳过时也用它收尾。
##
## 采样率跟 SortAudio 一致（22050）：全是低频和噪声，再高只是白占内存
## （hum 有 6 秒，是这里面最大的一条，也就 260KB）。

const RATE := 22050

## 各声音的基准音量（dB）。这里定平衡，波形里只定形状——
## 调"哪个响一点"改这几个数就行，不用回头改采样。
## （buzz 不在这张表里：它的音量和波形一起放在 AlertTone，两处共用。）
const HUM_DB := -7.0
const TICK_DB := -14.0
const THUMP_DB := -4.0
const CUT_DB := -7.0

## 嗡鸣的淡出时长。直接 stop() 会在波形中间硬切出一个爆音
## （低频尤其明显），所以停之前先把音量压下去。
const FADE := 0.10

var _hum: AudioStreamPlayer
var _tick: AudioStreamPlayer
var _buzz: AudioStreamPlayer
var _thump: AudioStreamPlayer
var _cut: AudioStreamPlayer

## 正在淡出的剩余时间，< 0 表示没在淡出
var _fade := -1.0


func _ready() -> void:
	_hum = _player(_hum_wav(), HUM_DB)
	_tick = _player(_tick_wav(), TICK_DB)
	_buzz = _player(AlertTone.stream(), AlertTone.VOLUME_DB)
	_thump = _player(_thump_wav(), THUMP_DB)
	_cut = _player(_cut_wav(), CUT_DB)
	set_process(false)


func _process(delta: float) -> void:
	if _fade < 0.0:
		set_process(false)
		return
	_fade -= delta
	if _fade <= 0.0:
		_fade = -1.0
		if _hum != null:
			_hum.stop()
			_hum.volume_db = HUM_DB
		set_process(false)
		return
	if _hum != null:
		_hum.volume_db = lerpf(-60.0, HUM_DB, _fade / FADE)


# ---------------------------------------------------------------- 对外

## 开机。嗡鸣从这里一直响到收束（或跳过）。
func start() -> void:
	if _hum != null:
		_hum.volume_db = HUM_DB
		_hum.play()


## 停掉嗡鸣（带一小段淡出）。
func stop_hum() -> void:
	if _hum == null or not _hum.playing:
		return
	_fade = FADE
	set_process(true)


func play_tick(volume_db := TICK_DB) -> void:
	if _tick != null:
		_tick.volume_db = volume_db
	_play(_tick)


func play_buzz() -> void:
	_play(_buzz)


func play_thump() -> void:
	_play(_thump)


func play_cut(volume_db := CUT_DB) -> void:
	if _cut != null:
		_cut.volume_db = volume_db
	_play(_cut)


func stop_all() -> void:
	_fade = -1.0
	set_process(false)
	for p in [_hum, _tick, _buzz, _thump, _cut]:
		if p != null and p.playing:
			p.stop()
	if _hum != null:
		_hum.volume_db = HUM_DB


## 每一路一个播放器、一次只响一声：这几个声音都是"事件"而不是持续声源，
## 同时最多重叠两三个，不需要 SortAudio 那种轮转池。
func _play(p: AudioStreamPlayer) -> void:
	if p == null:
		return
	# 嗒声每次换一点音高，十几声连着来才不会像节拍器
	if p == _tick:
		p.pitch_scale = randf_range(0.88, 1.18)
	p.play()


func _player(wav: AudioStreamWAV, db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = wav
	p.bus = "Master"
	p.volume_db = db
	add_child(p)
	return p


# ---------------------------------------------------------------- 波形

## 低频嗡鸣。三层叠起来：55Hz 基音、82.5Hz 五度、一路从 140Hz 升到 280Hz
## 的电流声；再压一层很轻的白噪（机器底噪）。
##
## 升调那层是这段的"压迫感引擎"：整段自检里它一直在涨，玩家说不出哪里变了，
## 但到标题砸下时情绪已经被推到顶。相位是**累加**出来的（ph += 2πf/RATE），
## 直接写 sin(2πf(t)·t) 会因为频率本身在变而算错相位，听上去忽快忽慢。
##
## 尾巴 0.5 秒自带淡出：正常播到收束时不会有断口，提前 stop 也有 stop_hum 兜着。
func _hum_wav() -> AudioStreamWAV:
	var dur := 6.0
	var count := int(RATE * dur)
	var data := PackedByteArray()
	data.resize(count * 2)

	var ph_rise := 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x50525453     # "PRTS"，固定种子：每次开机的底噪完全一样
	for i in count:
		var t := float(i) / float(RATE)

		# 起手 0.7 秒淡入（"通电"），收尾 0.5 秒淡出
		var env := 1.0
		if t < 0.7:
			env = t / 0.7
		elif t > dur - 0.5:
			env = (dur - t) / 0.5
		# 缓慢起伏，像机器在呼吸
		var swell := 0.82 + 0.18 * sin(TAU * 0.13 * t)

		var base := sin(TAU * 55.0 * t) * 0.60 + sin(TAU * 82.5 * t) * 0.22
		var f_rise := 140.0 * pow(2.0, t / dur)
		ph_rise += TAU * f_rise / float(RATE)
		var rise := sin(ph_rise) * 0.07
		var noise := rng.randf_range(-1.0, 1.0) * 0.045

		var s := (base + rise + noise) * env * swell * 0.5
		data.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 32767.0))
	return _wav(data)


## 落字的嗒声：30ms 的噪声脉冲 + 一点 1.2kHz 的"木味"。
## 起音 1.5ms 淡入，否则每一声都带一个"啪"。
func _tick_wav() -> AudioStreamWAV:
	var dur := 0.03
	var count := int(RATE * dur)
	var data := PackedByteArray()
	data.resize(count * 2)

	var rng := RandomNumberGenerator.new()
	rng.seed = 0x5449434b     # "TICK"
	for i in count:
		var t := float(i) / float(RATE)
		var env := exp(-70.0 * t / dur)
		if t < 0.0015:
			env *= t / 0.0015
		var s := (rng.randf_range(-1.0, 1.0) * 0.7 + sin(TAU * 1200.0 * t) * 0.3) * env * 0.5
		data.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 32767.0))
	return _wav(data)


## 砸标题的闷响：90Hz 滑到 35Hz 的正弦，指数衰减，前 15ms 叠一小段噪声当"撞击"。
func _thump_wav() -> AudioStreamWAV:
	var dur := 0.55
	var count := int(RATE * dur)
	var data := PackedByteArray()
	data.resize(count * 2)

	var ph := 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x48554d50     # "HUMP"
	for i in count:
		var t := float(i) / float(RATE)
		var f := lerpf(90.0, 35.0, clampf(t / dur, 0.0, 1.0))
		ph += TAU * f / float(RATE)
		var env := exp(-6.0 * t / dur)
		if t < 0.004:
			env *= t / 0.004
		var hit := rng.randf_range(-1.0, 1.0) * 0.35 * exp(-90.0 * t)
		var s := (sin(ph) * 0.85 + hit) * env * 0.75
		data.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 32767.0))
	return _wav(data)


## 收束的下滑音：500Hz 一路滑到 70Hz，快衰减。
func _cut_wav() -> AudioStreamWAV:
	var dur := 0.30
	var count := int(RATE * dur)
	var data := PackedByteArray()
	data.resize(count * 2)

	var ph := 0.0
	for i in count:
		var t := float(i) / float(RATE)
		var f := 500.0 * pow(0.14, t / dur)
		ph += TAU * f / float(RATE)
		var env := exp(-8.0 * t / dur)
		if t < 0.002:
			env *= t / 0.002
		var s := sin(ph) * env * 0.5
		data.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 32767.0))
	return _wav(data)


## 16 位单声道。和 SortAudio._make_tone 用的是同一套参数。
func _wav(data: PackedByteArray) -> AudioStreamWAV:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = data
	return wav

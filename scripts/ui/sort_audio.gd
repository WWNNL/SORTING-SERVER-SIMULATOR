class_name SortAudio
extends Node
## 排序音效：按"当前选中的元素"的值发出对应音高。
##
## 实现上只生成一条正弦短音，靠 pitch_scale 变调覆盖整个音域——比预生成
## 几十条采样省内存，切换音高时也不会有采样边界爆音。
##
## 音阶刻意用五声音阶而不是连续频率映射：连续映射在密集比较时听感就是一片
## 刺耳噪声，而五声音阶任意两个音同时响都不会难听，越乱越像"数据在流动"。

const SAMPLE_RATE := 22050
const BASE_FREQ := 220.0        ## A3
const DURATION := 0.16
const POOL_SIZE := 16
## 最短发声间隔。高速运行时每秒有上千次读取，不限制会糊成噪音。
const MIN_INTERVAL := 0.042

## 五声音阶的半音偏移，覆盖三个八度
const SCALE := [0, 2, 4, 7, 9, 12, 14, 16, 19, 21, 24, 26, 28, 31, 33, 36]

var enabled := true

var _stream: AudioStreamWAV
var _players: Array[AudioStreamPlayer] = []
var _next := 0
var _cooldown := 0.0
var _played := 0
var _last_pitch := 1.0


func _ready() -> void:
	_stream = _make_tone()
	for _i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.stream = _stream
		p.bus = "Master"
		add_child(p)
		_players.append(p)
	set_process(true)


func _process(delta: float) -> void:
	if _cooldown > 0.0:
		_cooldown -= delta


## 按元素值发声。v 落在 [1, max_v] 里，映射到五声音阶的一级。
func play_value(v: int, max_v: int) -> void:
	if not enabled or _stream == null or _players.is_empty():
		return
	if _cooldown > 0.0:
		return
	_cooldown = MIN_INTERVAL

	var frac := 0.0
	if max_v > 1:
		frac = clampf(float(v - 1) / float(max_v - 1), 0.0, 1.0)
	var idx := int(round(frac * float(SCALE.size() - 1)))
	_last_pitch = pow(2.0, float(SCALE[idx]) / 12.0)

	var p := _players[_next]
	_next = (_next + 1) % _players.size()
	p.pitch_scale = _last_pitch
	p.play()
	_played += 1


func notes_played() -> int:
	return _played


func last_pitch() -> float:
	return _last_pitch


func set_enabled(on: bool) -> void:
	enabled = on
	if not on:
		stop_all()


func stop_all() -> void:
	for p in _players:
		if p.playing:
			p.stop()


## 生成一条带指数衰减包络的正弦短音
func _make_tone() -> AudioStreamWAV:
	var count := int(SAMPLE_RATE * DURATION)
	var data := PackedByteArray()
	data.resize(count * 2)  # 16 位单声道

	for i in count:
		var t := float(i) / float(SAMPLE_RATE)
		var env := exp(-6.0 * t / DURATION)
		# 起音处淡入几毫秒，否则每次触发都会"啪"一声
		if t < 0.004:
			env *= t / 0.004
		var s := sin(TAU * BASE_FREQ * t) * env * 0.45
		data.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 32767.0))

	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SAMPLE_RATE
	wav.stereo = false
	wav.data = data
	return wav

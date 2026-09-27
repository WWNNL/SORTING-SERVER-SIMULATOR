class_name AlertTone
extends RefCounted
## PRTS 的警报音：233Hz 与 247Hz 两个方波相加（拍频 14Hz），再叠一层 11Hz 的硬断续。
##
## 方波而不是正弦：蜂鸣器/警报器就是方波的音色，正弦太"干净"，在这套冷硬的
## 黑白界面里会显得温柔。两个音只差 14Hz 是刻意的——靠拍频制造那种粗糙的
## "灯管在响"的听感，而不是一个干净的和声。
##
## 单独一个文件是因为这段音有**两处**要用：开机自检的警示拍，和游戏内的报错弹窗。
## 两处必须是同一个声音——玩家在开机时听到的那声"出事了"，报错时再听到一次，
## 才认得出是同一个警报。
##
## 和 SortAudio / BootAudio 一样现场合成，仓库里不出现音频文件。

const RATE := 22050
const DURATION := 0.55
const F1 := 233.0        ## 主音
const F2 := 247.0        ## 与主音相差 14Hz，拍频就是"警报"的粗糙感
const CHOP := 11.0       ## 硬断续的频率
const AMP := 0.42
## 播放音量。两处（开机警示拍、报错弹窗）都用这个值——它是同一个声音，
## 音量分头写就会慢慢跑偏，一处调大之后另一处还留在原地。
const VOLUME_DB := -6.0

static var _cached: AudioStreamWAV = null


## 警报波形。带缓存：两处各要一次、波形完全一样，没必要合成两遍
## （和 Prts.body_font 的缓存一个路子）。
static func stream() -> AudioStreamWAV:
	if _cached == null:
		_cached = _build()
	return _cached


static func _build() -> AudioStreamWAV:
	var count := int(RATE * DURATION)
	var data := PackedByteArray()
	data.resize(count * 2)

	for i in count:
		var t := float(i) / float(RATE)
		# 起音 6ms 淡入（否则每声都带一个"啪"），收尾 0.12 秒淡出
		var env := 1.0
		if t < 0.006:
			env = t / 0.006
		elif t > DURATION - 0.12:
			env = (DURATION - t) / 0.12
		var chop := 1.0 if sin(TAU * CHOP * t) > 0.0 else 0.55
		var sq := _square(TAU * F1 * t) * 0.5 + _square(TAU * F2 * t) * 0.5
		var s := sq * chop * env * AMP
		data.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 32767.0))
	return _wav(data)


static func _square(ph: float) -> float:
	return 1.0 if sin(ph) > 0.0 else -1.0


## 16 位单声道。和 SortAudio._make_tone 用的是同一套参数。
static func _wav(data: PackedByteArray) -> AudioStreamWAV:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = data
	return wav

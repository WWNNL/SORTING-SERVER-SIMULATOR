class_name PyCodeEdit
extends CodeEdit
## CodeEdit 的薄封装，只提供"光标周围的单词"这类查询。
##
## 键盘拦截没有写在这里，而是由编辑器连接 `gui_input` 信号来做。
## 原因是 GDScript 继承不了 C++ 的 `gui_input` 虚函数：一旦重写 `_gui_input`，
## 就再也调不回 TextEdit 自己的输入处理（super 里根本没有这个函数），
## 整个编辑器的输入会全废。
##
## 好在 Godot 的 `Control::_call_gui_input` 是**先发信号、再调虚函数**的
## （源码注释写明了就是为了让外部能截获并 accept_event），
## 所以在 `gui_input` 信号里处理按键、再 `accept_event()`，就能抢在
## TextEdit 把 Tab 当缩进吃掉之前拿到它。

## 光标左边紧挨着的是不是标识符字符
func has_word_before_caret() -> bool:
	var line := get_line(get_caret_line())
	var col := get_caret_column()
	if col <= 0 or col > line.length():
		return false
	return is_word_char(line[col - 1])


## 光标前那个单词的起始列
func word_start_before_caret() -> int:
	var line := get_line(get_caret_line())
	var col := get_caret_column()
	var start := col
	while start > 0 and is_word_char(line[start - 1]):
		start -= 1
	return start


## 光标前那个半截单词
func word_before_caret() -> String:
	var line := get_line(get_caret_line())
	var start := word_start_before_caret()
	return line.substr(start, get_caret_column() - start)


static func is_word_char(c: String) -> bool:
	return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") \
		or (c >= "0" and c <= "9") or c == "_"

extends SceneTree
## 把图标 SVG 按整数倍光栅化成 PNG（tools/build_icons.sh 调用，不单独使用）。
##
## 用法：
##   godot --headless --path <项目> --script tools/rasterize_icon.gd -- \
##       <svg路径> <网格边长> <输出目录> <尺寸,尺寸,...>
##
## 注意 Image.load_svg_from_string 的 scale 是乘在 SVG **固有尺寸**（width/height
## 属性）上的，不是相对 viewBox 的倍率。所以这里先从 SVG 里读出固有边长，再算
## scale = 目标尺寸 / 固有边长。调用方保证目标尺寸是网格边长的整数倍——非整数倍
## 会把像素画的边缘糊掉，这正是 .ico/.icns 要按尺寸挑 SVG 的原因。

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 4:
		print("usage: -- <svg> <grid> <outdir> <size,size,...>")
		quit(1)
		return

	var svg_path := args[0]
	var grid := int(args[1])
	var out_dir := args[2]
	var sizes := args[3].split(",")

	var svg := FileAccess.get_file_as_string(svg_path)
	if svg.is_empty():
		print("cannot read ", svg_path)
		quit(1)
		return

	var re := RegEx.create_from_string('width="([0-9]+)"')
	var m := re.search(svg)
	if m == null:
		print("no width attribute in ", svg_path)
		quit(1)
		return
	var box := float(m.get_string(1))

	DirAccess.make_dir_recursive_absolute(out_dir)

	for s in sizes:
		var size := int(s)
		if size % grid != 0:
			print("WARNING: %d is not a multiple of the %dpx grid" % [size, grid])
		var img := Image.new()
		var err := img.load_svg_from_string(svg, float(size) / box)
		if err != OK:
			print("load_svg failed at %d: %d" % [size, err])
			quit(1)
			return
		if img.get_width() != size:
			print("ERROR: asked %d, got %d" % [size, img.get_width()])
			quit(1)
			return
		var out := "%s/icon_%d.png" % [out_dir, size]
		img.save_png(out)
		print("  %4dpx -> %s" % [size, out])
	quit(0)

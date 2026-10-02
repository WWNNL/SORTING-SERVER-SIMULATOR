shader_type canvas_item;
render_mode blend_mix, unshaded;

// 开始菜单的背景分层。机房是 Blender 烘的两张图（远景 / 近景剪影），
// 这个着色器负责把"静态的一张图"变成"能对焦、能跟着鼠标晃的镜头画面"。
//
// 三件事：
//   1. 景深。真做景深要深度缓冲，而这张图根本没有深度——但它是**透视**的：
//      画面上的纵坐标基本就等于深度（贴着灭点最远，画面上下两端最近）。
//      所以拿"离灭点线的距离"当深度代理，就能做出"焦点跟着鼠标上下走"的
//      对焦效果：鼠标往上 = 对远处，画面底部糊；往下 = 对近处，远处糊。
//   2. 像素化。这套界面是 12px 点阵字，背景太"高清"反而像贴了张照片。
//      量化到 2 像素一格之后，和点阵字是同一个语汇。
//   3. 调色。增益/染色/暗角/扫描线，以及转场用的 fade。
//
// 模糊用的是黄金角螺旋取样的 16 抽头。单帧只跑一次、只在菜单上跑，
// 开销可以忽略；比起真正的两趟高斯，一个 pass 里就能把半径开到十几像素。

// 当前焦点深度：0 = 最远（灭点），1 = 最近（画面上下两端）
uniform float focus : hint_range(0.0, 1.5) = 0.3;
// 这一层离焦时的最大模糊半径（像素）
uniform float blur_max = 6.0;
// 固定深度（>= 0 时忽略深度代理）。前景剪影用它：那一层整层都在镜头前面。
uniform float depth_fixed = -1.0;
// 灭点的纵坐标（占屏高）。来自 Blender 里的相机参数。
uniform float horizon = 0.435;
// 屏幕尺寸（像素）。用来把 FRAGCOORD 换算成屏幕坐标。
uniform vec2 screen_size = vec2(1600.0, 900.0);
// 像素块边长（<= 1 表示不量化）
uniform float pixel = 2.0;
uniform float gain = 1.0;
uniform vec3 tint = vec3(1.0);
uniform float lift = 0.0;
uniform float vignette = 0.0;
uniform float scanline = 0.0;
// 转场：整层淡出到透明（底下是纯黑）
uniform float fade = 1.0;

const float GOLDEN = 2.39996323;
const int TAPS = 16;

void fragment() {
	vec2 uv = UV;
	if (pixel > 1.0) {
		vec2 q = TEXTURE_PIXEL_SIZE * pixel;
		uv = (floor(uv / q) + 0.5) * q;
	}

	// 深度代理：离灭点线越远越近。上下分开归一化，两端都到 1.0——
	// 天花板靠近镜头的那一段和地面靠近镜头的那一段，深度是对称的。
	vec2 sp = FRAGCOORD.xy / screen_size;
	float dy = sp.y - horizon;
	float proxy = dy >= 0.0 ? dy / max(0.001, 1.0 - horizon) : -dy / max(0.001, horizon);
	float depth = depth_fixed >= 0.0 ? depth_fixed : clamp(proxy, 0.0, 1.0);

	float blur_px = blur_max * abs(depth - focus);

	// 模糊内联在 fragment 里，**不能**抽成 blur_at(uv, r) 那样的辅助函数：
	// canvas_item 的 TEXTURE 是只注入 fragment 作用域的，写进函数体里
	// 编译期就报 "Unknown identifier: TEXTURE"（踩过）。
	vec4 col;
	if (blur_px < 0.4) {
		col = texture(TEXTURE, uv);
	} else {
		vec2 r = TEXTURE_PIXEL_SIZE * blur_px;
		col = texture(TEXTURE, uv) * 1.5;
		float wsum = 1.5;
		for (int i = 0; i < TAPS; i++) {
			float t = (float(i) + 0.5) / float(TAPS);
			float a = float(i) * GOLDEN;
			vec2 off = vec2(cos(a), sin(a)) * sqrt(t) * r;
			float w = 1.0 - 0.7 * t;
			col += texture(TEXTURE, uv + off) * w;
			wsum += w;
		}
		col /= wsum;
	}

	col.rgb = col.rgb * gain * tint + lift;

	// 暗角：四周压暗，把注意力收到中间
	vec2 c = sp - vec2(0.5);
	col.rgb *= clamp(1.0 - vignette * dot(c, c) * 2.6, 0.0, 1.0);

	// CRT 扫描线：每 3px 一条。和开机自检用的是同一种笔触。
	if (scanline > 0.0) {
		col.rgb *= 1.0 - scanline * step(1.0, mod(FRAGCOORD.y, 3.0));
	}

	col.a *= fade;
	COLOR = col;
}

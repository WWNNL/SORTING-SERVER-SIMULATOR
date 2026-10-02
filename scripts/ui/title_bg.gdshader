shader_type canvas_item;
// 标题屏背景：服务器机厅渲染图的双层混合。
//
// 两张图来自同一个 Blender 相机的两次渲染：sharp 是全清晰的底图，
// blur 是同一构图的模糊版（高斯 + 缩半）。混合权重按"离对焦点多远"算——
// 对焦点跟着鼠标走，近处清晰、远处化开，就是"对焦跟随鼠标"的景深。
//
// 视差也在这里做：整幅图围绕中心轻微缩放、再往鼠标的反方向挪一点，
// 鼠标动的时候背景像隔着一层玻璃在晃，机厅的进深才立得起来。
// 图比视口大出这一圈余量，怎么挪都不会露出边。

uniform sampler2D blur_tex : source_color, filter_linear;
// 对焦点（uv，0~1）。由 TitleScreen 每帧喂平滑后的鼠标位置。
uniform vec2 focus = vec2(0.5, 0.5);
// 对焦圈半径与过渡带宽：圈里全清晰，圈外全模糊，中间是焦外渐变。
uniform float focus_radius = 0.30;
uniform float focus_softness = 0.75;

void fragment() {
	// 视差：先围绕中心收 4.4%（留出位移余量），再往对焦点的反方向挪。
	vec2 centered = UV - vec2(0.5);
	vec2 shift = (vec2(0.5) - focus) * 0.018;
	vec2 uv = centered * 0.956 + vec2(0.5) + shift;

	vec3 sharp = texture(TEXTURE, uv).rgb;
	vec3 soft = texture(blur_tex, uv).rgb;

	// 对焦跟随：离对焦点越远越糊。距离按 16:9 的横向拉伸校正，
	// 不然焦点圈在横向上会被压扁成椭圆。
	float aspect = 16.0 / 9.0;
	vec2 dvec = (UV - focus) * vec2(aspect, 1.0);
	float d = length(dvec);
	float far = smoothstep(focus_radius, focus_radius + focus_softness, d);
	vec3 col = mix(sharp, soft, far);

	// 暗角：四角压一点，视线往中间收。
	float vig = smoothstep(1.15, 0.30, distance(UV, vec2(0.5, 0.47)) * 1.25);
	col *= mix(0.52, 1.0, vig);
	// 左侧再压一档：标题和菜单都在左边，底子暗下去字才立得住。
	col *= mix(0.80, 1.0, smoothstep(0.0, 0.45, UV.x));

	COLOR = vec4(col, 1.0);
}

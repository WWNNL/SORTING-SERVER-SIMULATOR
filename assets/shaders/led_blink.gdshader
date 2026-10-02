shader_type spatial;
render_mode shadows_disabled, ambient_light_disabled;

// 机柜指示灯的明灭。LED 在 Blender 导出时把每颗灯的（相位, 是否闪烁, 频率）
// 写进了顶点色 COLOR_0：r = 相位 0~1，g = 参与闪烁（约四成半的灯常亮，其余
// 恒亮），b = 频率 0~1（映射到 1.5~4.5Hz）。同一颗灯的所有顶点共享一个三元组，
// 所以整颗灯一明一暗，不会出现半颗灯自己跟自己打架。
//
// 三组灯（蓝/白/青）共用这一个 shader，颜色由 tint 给出（TitleBackdrop 按
// 网格名各配一份材质）。明灭是对 75% 深度的硬切——服务器指示灯是"亮/灭"，
// 不是呼吸；这套语言和烘图版的判定式一脉相承。

// 灯色。三组各配：蓝 / 白 / 青。
uniform vec3 tint = vec3(0.3, 0.6, 1.0);
// 秒（TitleBackdrop 每帧喂）。所有灯共享一个时钟，相位靠顶点色岔开。
uniform float time_s = 0.0;
// 亮态的发光强度。要压过 1.0，environment 的 glow 才接得住它。
uniform float brightness : hint_range(0.0, 8.0) = 2.6;
// 明灭深度：1.0 = 全灭，0.9 = 留一点底亮，像隔着雾看。
uniform float blink_strength : hint_range(0.0, 1.0) = 0.9;

varying vec4 v_col;

void vertex() {
	// 顶点色在 fragment 里不直接可读（spatial 的 COLOR 是输出），过一道 varying
	v_col = COLOR;
}

void fragment() {
	float gate = step(0.5, v_col.g);
	float rate = 1.5 + 3.0 * v_col.b;
	float phase = v_col.r * TAU;
	float wave = 0.5 + 0.5 * sin(time_s * rate + phase);
	float k = 1.0 - blink_strength * gate * (0.75 - 0.75 * wave * wave);
	// 不能用 unshaded：那个模式下光照整段跳过，EMISSION 一起被忽略，
	// 输出永远是 ALBEDO（这里是纯黑）。走正常光照，ALBEDO 给 0，
	// 颜色全部走 EMISSION——不受灯光影响，glow 也接得住 >1 的亮度。
	ALBEDO = vec3(0.0);
	EMISSION = tint * brightness * k;
}

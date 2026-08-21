shader_type spatial;
render_mode blend_mix, unshaded, cull_back, depth_draw_never, shadows_disabled;

// 贴在地面上的 blob 阴影 —— 参考图里那种"烘出来的接触 AO"。
//
// 剖面是**程序生成**的，不用贴图。第一版用了一张 (1-r)^1.7 再高斯模糊的
// alpha 图，结果是"渲染了但看不见"：浓的部分正好被物体本身压在底下，
// 露在外面那一圈 alpha 只有 0.08。用常数 alpha=0.8 做对照才定位到 ——
// 同一块地面常数 alpha 压到 125，真实贴图只压到 186（未遮挡 193）。
// 之前以为看到的 blob，其实全是方向光的真实投影。
//
// 所以剖面要反过来：**中心到 core 半径是实心的，只有最外一圈虚**。
// 这样物体边缘那一圈才是最浓的，读起来才像接触阴影而不是一团雾。
//
// 程序生成还有个好处：core / strength 直接可调，不用重新生成贴图。

uniform vec3 shadow_color : source_color = vec3(0.32, 0.20, 0.13);
uniform float strength = 0.5;
uniform float core = 0.55;      // 实心区半径（0-1，1 是四边形的内切圆）

void fragment() {
	float r = length(UV - vec2(0.5)) * 2.0;
	ALBEDO = shadow_color;
	ALPHA = (1.0 - smoothstep(core, 1.0, r)) * strength;
}

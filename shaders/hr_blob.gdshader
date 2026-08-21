shader_type spatial;
render_mode blend_mix, unshaded, cull_back, depth_draw_never, shadows_disabled;

// 贴在地面上的 blob 阴影。
//
// 参考图里树和石头下面的影子是**软的椭圆团块**：居中在物体正下方、
// 没有方向偏移、边缘非常虚。那不是投影阴影，是贴片。
// 手机游戏几乎都这么做 —— 便宜、可控，而且在分档着色的平面风格里
// 比真实阴影贴图干净得多（真影子会把纯色块切出硬边）。
//
// 用普通 alpha 混合而不是 blend_mul：blend_mul 那一版渲染出来是**硬边方块**，
// 而调试输出证明贴图的 alpha 是正常的径向渐变 —— 说明问题出在混合模式上，
// 不值得为此深挖。alpha 混合的行为直接可预期，代价只是它是"染色"不是"压暗"，
// 在单一底色的场地上没有区别。

uniform sampler2D blob : source_color, filter_linear_mipmap, repeat_disable;
uniform vec3 shadow_color : source_color = vec3(0.32, 0.20, 0.13);
uniform float strength = 0.5;

void fragment() {
	ALBEDO = shadow_color;
	ALPHA = texture(blob, UV).a * strength;
}

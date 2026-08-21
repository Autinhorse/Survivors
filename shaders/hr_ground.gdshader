shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled;

// 风格 "hellrider" 的地面：**方格铺地 + 平面着色**，没有任何纹理。
//
// 参考图量出来的：地面 90% 的像素只用十来种颜色，一半以上的画面是纯色块，
// 而这些"多种颜色"其实是**同一色相下的几档明暗**
// （褐色区实测 rgb(116,83,60) / (139,104,76) / (157,112,78) / (183,136,91)）。
// 所以地面不是贴图，是**逐格随机取一档亮度**。
//
// 参考图用的是 45° 菱形网格（等距投影的产物）。本项目是正交轴向的方形世界，
// 所以这里用**轴向方格**，不做菱形旋转。
//
// 关键在于**格子边界必须是硬的**：一旦插值，整个风格就散了。
// 所以格子索引用 floor() 取，颜色在格内是常数。

uniform vec3 tile_a : source_color = vec3(0.455, 0.325, 0.235);
uniform vec3 tile_b : source_color = vec3(0.718, 0.533, 0.357);
uniform float tile_size = 4.0;          // 米
uniform float tile_steps = 4.0;         // 明暗分几档
uniform float tile_bias = 0.42;         // 偏向暗档还是亮档

// 路面：踩出来的土路，同样是硬边的格子，只是换一组颜色
uniform vec3 path_a : source_color = vec3(0.310, 0.216, 0.153);
uniform vec3 path_b : source_color = vec3(0.404, 0.290, 0.204);
uniform sampler2D path_mask : hint_default_black, filter_linear, repeat_disable;
uniform vec2 path_uv_origin = vec2(-60.0, -60.0);
uniform float path_uv_size = 120.0;

// 平面着色的光照分档。参考图里同一块石头只有 3-4 个明确的亮度台阶，
// 没有连续渐变 —— 所以把 N·L 量化。
uniform float light_steps = 3.0;
uniform float light_floor = 0.55;       // 最暗的一档有多暗

varying vec3 w_pos;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void vertex() {
	w_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 cell = floor(w_pos.xz / tile_size);
	float h = hash21(cell);
	// 量化到 tile_steps 档，格与格之间才是明确的台阶而不是噪声
	float step_i = floor(h * tile_steps) / max(tile_steps - 1.0, 1.0);
	step_i = pow(step_i, tile_bias * 2.0);

	vec2 puv = (w_pos.xz - path_uv_origin) / path_uv_size;
	float on_path = texture(path_mask, puv).r;

	vec3 ground = mix(tile_a, tile_b, step_i);
	vec3 path = mix(path_a, path_b, step_i);
	ALBEDO = mix(ground, path, on_path);
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}

void light() {
	float nl = clamp(dot(NORMAL, LIGHT), 0.0, 1.0);
	// 分档：连续的 Lambert 会让平面着色的干净感消失
	nl = floor(nl * light_steps) / max(light_steps - 1.0, 1.0);
	DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * ATTENUATION
			* mix(light_floor, 1.0, nl);
}

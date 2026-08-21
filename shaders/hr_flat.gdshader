shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled;

// 风格 "hellrider" 的通用平面着色：颜色来自**顶点色**，光照**分档**。
//
// 这个风格里所有道具（房屋、石头、树、桥）都是这一个材质：
// 没有贴图、没有法线扰动、没有三平面 —— 上一个风格花了大力气做的那一层，
// 在这里必须全部关掉，否则一眼就不是这个风格了。
//
// 唯一要做对的是**光照台阶**：参考图里同一块石头只有 3-4 个明确的亮度级，
// 台阶之间是硬边。连续的 Lambert 会让整个画面"软"下来，风格就散了。

uniform float light_steps = 3.0;
uniform float light_floor = 0.52;
uniform float tint = 1.0;               // 顶点色的权重，0 = 用 base_color
uniform vec3 base_color : source_color = vec3(0.6, 0.6, 0.6);
// 顶面提亮一点点：参考图的低模石头顶面明显比推导出来的更亮，
// 是美术手动提的，不是物理光照的结果
uniform float top_boost = 0.10;

varying float v_up;

void vertex() {
	v_up = clamp(normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz).y, 0.0, 1.0);
}

void fragment() {
	ALBEDO = mix(base_color, COLOR.rgb, tint) * (1.0 + top_boost * v_up);
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}

void light() {
	float nl = clamp(dot(NORMAL, LIGHT), 0.0, 1.0);
	nl = floor(nl * light_steps) / max(light_steps - 1.0, 1.0);
	DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * ATTENUATION
			* mix(light_floor, 1.0, nl);
}

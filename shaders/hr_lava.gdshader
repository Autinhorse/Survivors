shader_type spatial;
render_mode cull_back, unshaded;

// 熔岩带：这个风格最强的识别元素，也是最"平面设计"的一块。
//
// 参考图里它由三层构成，缺一层都不像：
//   1. 场地边缘的**锯齿轮廓**（几何，见 scripts/environment/HellField.gd）
//   2. 紧贴轮廓的**亮边**（两道：内侧亮橙，外侧橙）
//   3. 外面一大片**方块色块场**，两三档红，越往外越暗
//      （参考图是菱形，那是等距投影的产物 —— 我们用轴向正方形）
// 再加上飘着的金色小方块（另一层，见 layout）。
//
// unshaded：熔岩是自发光的，不参与场景光照。
// 这也顺带让它在任何机位下都保持同样的饱和度。

uniform vec3 rim_inner : source_color = vec3(1.000, 0.780, 0.290);
uniform vec3 rim_outer : source_color = vec3(0.976, 0.322, 0.192);
uniform vec3 lava_hot : source_color = vec3(0.969, 0.251, 0.224);
uniform vec3 lava_mid : source_color = vec3(0.871, 0.204, 0.255);
uniform vec3 lava_cold : source_color = vec3(0.553, 0.133, 0.216);

uniform float rim_inner_w = 0.55;       // 米
uniform float rim_outer_w = 1.30;
uniform float block_size = 4.0;         // 明暗方块的边长，要和 HellMap 的 cell 一致
uniform float fade_dist = 26.0;         // 多远褪到最暗
uniform float pulse_speed = 0.6;

// UV.x 携带**到场地边缘的距离（米）**，由 HellField.gd 写入。
// 用距离而不是世界坐标，是为了让亮边宽度在任何一条边上都一致。
varying vec2 uv;
varying vec3 w_pos;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void vertex() {
	uv = UV;
	w_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float d = uv.x;

	// **轴向的正方形色块，不是 45° 菱形。**
	// 参考图的菱形是等距投影的产物；我们是正面 90° 的世界，
	// 见 styles/hellrider/README.md「四条不能破的规则」第 4 条。
	// 这一层和熔岩的几何格**同一个格**（HellMap.gd 的 cell），
	// 所以明暗方块和方块几何是对齐的，不会出现"色块横跨两个方块"。
	vec2 cell = floor(w_pos.xz / block_size);
	float h = hash21(cell);

	float t = clamp(d / fade_dist, 0.0, 1.0);
	vec3 lava = mix(lava_hot, lava_mid, clamp(t * 1.6, 0.0, 1.0));
	lava = mix(lava, lava_cold, clamp(t * 1.6 - 0.6, 0.0, 1.0));
	// 逐格明暗：两档就够，多了就碎
	lava *= mix(0.90, 1.10, step(0.5, h));

	// 亮边
	float pulse = 0.94 + 0.06 * sin(TIME * pulse_speed + h * 6.283);
	vec3 col = lava;
	col = mix(col, rim_outer, step(d, rim_outer_w));
	col = mix(col, rim_inner * pulse, step(d, rim_inner_w));

	ALBEDO = col;
	EMISSION = col * 0.35;
}

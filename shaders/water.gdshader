shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// 湍急山涧的水面。
//
// 实测参考图的水面区域（放大到像素级 + 统计）：
//     平均 RGB (158, 136, 123)，亮度中位数 139
//     亮于 170 的像素只占 **10.7%**
// 也就是说：**底子是中等色调的水，白沫只占约一成面积，而且是极细的点。**
//
// 我先后错了两次，都记在这里：
//   1) 做成"深青色平静水面 + 岸边一圈泡沫" —— 完全没有急流感
//   2) 矫枉过正做成"整片白" —— 白沫面积到了 60-80%，成了一条白带子
// 正确的是介于两者之间，而且**白沫的特征尺寸要极小**（约 10 cm，
// 在 gameplay 机位下是 2-3 像素）。特征给大了就变成"奶流"，
// 给到半米以上就是电视雪花。

uniform sampler2D wave_noise : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D fleck_noise : hint_default_white, filter_linear_mipmap, repeat_enable;

uniform vec3 water_bright : source_color = vec3(0.52, 0.53, 0.55);
uniform vec3 water_dark : source_color = vec3(0.22, 0.27, 0.30);
uniform vec3 foam_color : source_color = vec3(0.88, 0.89, 0.90);

uniform float flow_speed = 0.9;
uniform float fleck_scale = 1.25;      // 白沫点的密度：特征约 10 cm
uniform float swell_scale = 0.10;      // 大尺度明暗起伏
uniform float streak_stretch = 3.5;
uniform float foam_threshold = 0.66;   // 越高白沫越少
uniform float foam_softness = 0.10;
uniform float bank_foam = 0.22;
uniform float normal_strength = 0.45;
uniform float base_alpha = 0.95;

// 河心线参数（与生成器一致）：用世界坐标算离河心的距离，
// 而不是网格 UV —— 河面由许多片拼成，每片 UV 映射不同，用 UV 会出现拼接缝。
uniform float river_x0 = 10.0;
uniform float river_slope = 0.28;
uniform float river_amp = 2.6;
uniform float river_freq = 0.085;
uniform float river_half = 3.75;

varying vec3 w_pos;

void vertex() {
	w_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// 沿流向拉长：白沫点被拉成短划，流向才读得出来
	vec2 fuv = vec2(w_pos.x, w_pos.z / streak_stretch) * fleck_scale
			+ vec2(0.0, -TIME * flow_speed);
	float fleck = texture(fleck_noise, fuv).r;

	// 大尺度起伏：让水面有明暗区块，不是均质噪声
	vec2 suv = w_pos.xz * swell_scale + vec2(0.0, -TIME * flow_speed * 0.25);
	float swell = texture(wave_noise, suv).r;

	float centre = river_x0 + river_slope * w_pos.z
			+ river_amp * sin(w_pos.z * river_freq);
	float across = clamp(abs(w_pos.x - centre) / river_half, 0.0, 1.4);
	across += (texture(wave_noise, w_pos.xz * 0.35).r - 0.5) * 0.45;
	float edge = smoothstep(1.0 - bank_foam, 1.05, across);

	// 白沫：只占一成左右面积
	float foam = smoothstep(foam_threshold, foam_threshold + foam_softness,
			fleck + swell * 0.18 + edge * 0.35);

	vec3 water = mix(water_dark, water_bright, swell * 0.7 + fleck * 0.3);
	ALBEDO = mix(water, foam_color, foam);

	float e = 0.03;
	float hx = texture(fleck_noise, fuv + vec2(e, 0.0)).r
			- texture(fleck_noise, fuv - vec2(e, 0.0)).r;
	float hz = texture(fleck_noise, fuv + vec2(0.0, e)).r
			- texture(fleck_noise, fuv - vec2(0.0, e)).r;
	NORMAL_MAP = normalize(vec3(-hx, -hz, 0.45)) * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = normal_strength;

	ALPHA = base_alpha;
	ROUGHNESS = mix(0.34, 0.85, foam);
	SPECULAR = mix(0.40, 0.15, foam);
	METALLIC = 0.0;
}

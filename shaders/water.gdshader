shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// 湍急山涧的水面。
//
// **流向来自网格 UV，不是世界坐标。** 之前用世界坐标滚动噪声，
// 水流永远朝同一个世界方向 —— 河道一拐弯就能看见水从一侧河岸流出、
// 流进对岸。静帧看不出来，跑起来一眼就是错的。
// 现在水面是沿河道生成的一条带（scripts/environment/RiverSurface.gd）：
//   UV.x   横向归一化，河道边界恰好是 0 和 1
//   UV.y   顺流坐标，按 ds/宽度 累加
//   UV2.x  横向米制坐标（保持纹理横向密度恒定）
// UV.y 的累加方式使得**恒定的滚动速度自动得到"窄处流得快、宽处流得慢"**，
// 着色器本身不需要知道河宽 —— 那是流量守恒 Q = 宽 × 深 × 流速 的直接结果。
//
// 色调按实测参考图对齐：平均 RGB (158,136,123)、亮度中位数 139、
// **亮于 170 的像素只占 10.7%** —— 底子是中等色调的水，白沫只占约一成面积
// 且特征极细（约 10 cm，在 gameplay 机位下 2-3 像素）。

uniform sampler2D wave_noise : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D fleck_noise : hint_default_white, filter_linear_mipmap, repeat_enable;

uniform vec3 water_bright : source_color = vec3(0.365, 0.376, 0.392);
uniform vec3 water_dark : source_color = vec3(0.169, 0.212, 0.239);
uniform vec3 foam_color : source_color = vec3(0.804, 0.816, 0.827);

uniform float flow_speed = 0.35;
uniform float fleck_scale = 2.2;       // 白沫点密度（UV 空间）
uniform float swell_scale = 0.35;      // 大尺度明暗起伏
uniform float streak_stretch = 2.5;    // 沿流向拉长的倍数
uniform float foam_threshold = 0.78;
uniform float foam_softness = 0.075;

// 岸边浪花。
//
// 之前这层"消失"了，原因不是没写，而是**落在了看不见的地方**：
// UV.x 的 0/1 对应河道的名义宽度，而地形挖槽的圆柱半径带 ±10% 抖动，
// 窄处的实际水面边界在 across≈0.9，泡沫带却从 0.945 才开始 —— 整条埋进了地形。
// 而且它只以 0.35 的权重参与白沫阈值，本身压不过阈值。
// 现在改成独立的一层，向内延伸得足够远，并直接叠加而不是参与阈值。
uniform float bank_width = 0.34;      // 从水边向内延伸多少（UV.x 单位）
uniform float bank_strength = 0.85;
uniform float bank_break = 0.55;      // 打碎浪花边缘的噪声强度
uniform float bank_churn = 1.6;       // 浪花自身的翻涌速度
uniform float normal_strength = 0.45;
uniform float base_alpha = 0.95;

void fragment() {
	// 顺流坐标：UV.y 已经在网格里按 ds/宽度 累加过
	float flow = UV.y - TIME * flow_speed;
	vec2 fuv = vec2(UV2.x, flow / streak_stretch) * fleck_scale;
	vec2 suv = vec2(UV2.x, flow) * swell_scale;

	float fleck = texture(fleck_noise, fuv).r;
	float swell = texture(wave_noise, suv).r;

	// 河道内的细白沫
	float foam = smoothstep(foam_threshold, foam_threshold + foam_softness,
			fleck + swell * 0.18);

	// 岸边浪花：水撞石头的地方最白。作为**独立的一层**叠加，
	// 而不是参与上面的阈值 —— 参与阈值的话永远压不过去。
	float across = abs(UV.x - 0.5) * 2.0;
	float churn = texture(fleck_noise,
			vec2(UV2.x * 1.3, flow * 0.6 - TIME * flow_speed * bank_churn)).r;
	// 用噪声打碎浪花的内边界，否则是一条平行于河岸的干净白带
	float bank_edge = across + (churn - 0.5) * bank_break;
	float bank = smoothstep(1.0 - bank_width, 1.0 - bank_width * 0.25, bank_edge);
	bank *= bank_strength * (0.55 + 0.45 * churn);
	foam = clamp(foam + bank, 0.0, 1.0);

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

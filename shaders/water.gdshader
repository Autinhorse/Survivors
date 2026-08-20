shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// 湍急山涧，不是平静河面。
//
// 放大参考图后最关键的一点：**河面基本是白的**。那是一条翻涌的白水急流，
// 深色水只在泡沫的缝隙里露出来。先前做成"深青色水面 + 岸边一圈泡沫"，
// 方向就是错的 —— 再怎么调参数也到不了那个观感。
//
// 所以这里反过来：以白沫为底，用噪声"挖"出深色缝隙；缝隙沿水流方向拉长，
// 于是流向本身成为可读的信息。
//
// 依旧刻意不用 DEPTH_TEXTURE / SCREEN_TEXTURE（§18 只要求"从 gameplay 相机
// 看起来可信"），Mobile 渲染器上更安全也更便宜。

uniform sampler2D wave_noise : hint_default_white, filter_linear_mipmap, repeat_enable;

uniform vec3 foam_color : source_color = vec3(0.88, 0.90, 0.90);
uniform vec3 shallow_color : source_color = vec3(0.30, 0.42, 0.42);
uniform vec3 deep_color : source_color = vec3(0.08, 0.14, 0.17);

uniform float flow_speed = 0.55;
uniform float streak_stretch = 5.5;   // 噪声沿流向拉长的倍数
uniform float wave_scale = 0.22;
uniform float foam_coverage = 0.62;   // 越大白沫越满
uniform float foam_softness = 0.28;
uniform float bank_foam = 0.30;       // 岸边额外加白：水撞石头的地方最白
uniform float normal_strength = 0.8;
uniform float base_alpha = 0.94;

// 河心线参数（与生成器保持一致）。用世界坐标算"离河心多远"，
// 而不是用网格 UV —— 河面是由许多片拼起来的，每片 UV 映射不同，
// 用 UV 会在拼接处产生一道道直线接缝。
uniform float river_x0 = 10.0;
uniform float river_slope = 0.28;
uniform float river_amp = 2.6;
uniform float river_freq = 0.085;
uniform float river_half = 3.75;

varying vec3 w_pos;

float wave(vec2 p) {
	return texture(wave_noise, p).r;
}

void vertex() {
	w_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// 沿流向拉长的采样：缝隙因此是长条而不是斑点，流向可读
	vec2 uv_a = vec2(w_pos.x, w_pos.z / streak_stretch) * wave_scale
			+ vec2(0.0, -TIME * flow_speed);
	vec2 uv_b = vec2(w_pos.x, w_pos.z / (streak_stretch * 0.55)) * wave_scale * 2.1
			+ vec2(0.11, -TIME * flow_speed * 1.7);

	float n = wave(uv_a) * 0.62 + wave(uv_b) * 0.38;

	// 岸边：水撞石头，白沫最厚。用世界坐标而非 UV，拼接处才不会有接缝。
	float centre = river_x0 + river_slope * w_pos.z
			+ river_amp * sin(w_pos.z * river_freq);
	float across = clamp(abs(w_pos.x - centre) / river_half, 0.0, 1.4);
	across += (wave(w_pos.xz * 0.4) - 0.5) * 0.5;      // 打碎岸线
	float edge = smoothstep(1.0 - bank_foam, 1.0, across);

	// 以白沫为底，用噪声挖出缝隙
	float foam = smoothstep(foam_coverage - foam_softness,
			foam_coverage + foam_softness, n + edge * 0.5);

	vec3 water = mix(deep_color, shallow_color, n);
	ALBEDO = mix(water, foam_color, foam);

	// 法线：白沫处起伏更强
	float e = 0.02;
	float hx = wave(uv_a + vec2(e, 0.0)) - wave(uv_a - vec2(e, 0.0));
	float hz = wave(uv_a + vec2(0.0, e)) - wave(uv_a - vec2(0.0, e));
	NORMAL_MAP = normalize(vec3(-hx, -hz, 0.30)) * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = normal_strength * (0.4 + foam);

	ALPHA = clamp(base_alpha + foam * 0.06, 0.0, 1.0);
	// 白沫粗糙，深水才反光
	ROUGHNESS = mix(0.30, 0.92, foam);
	SPECULAR = mix(0.42, 0.12, foam);
	METALLIC = 0.0;
}

shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Terrain surface for the benchmark ground CSG.
//
// World-space projection (not UVs): the ground is CSG, so its UVs are per-face
// and unusable.  Flat areas get a grass/dirt blend driven by two noise octaves;
// anything steep (gorge walls, cliff faces) fades to rock, so the same material
// covers ground and cliff without a second pass.

uniform sampler2D macro_noise : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D detail_noise : hint_default_white, filter_linear_mipmap, repeat_enable;
// Fine grass texture + the bump derived from it.  The reference art draws the
// open field as a textured plane -- 3D blades at this camera distance cost a
// third of the scene's triangle budget and read as noise anyway.
uniform sampler2D grass_detail : hint_default_white, filter_linear_mipmap, repeat_enable;

uniform vec3 grass_dark : source_color = vec3(0.16, 0.22, 0.07);
uniform vec3 grass_light : source_color = vec3(0.42, 0.44, 0.16);
uniform vec3 dirt_color : source_color = vec3(0.40, 0.29, 0.17);
uniform vec3 rock_color : source_color = vec3(0.26, 0.23, 0.20);

uniform float macro_scale = 0.022;
uniform float detail_scale = 0.30;
uniform float grass_scale = 1.15;      // texture repeats per metre
uniform float grass_contrast = 0.55;
uniform float bump_strength = 2.2;
uniform float bump_epsilon = 0.09;
uniform float rock_scale = 0.14;      // 岩壁细节的横向密度
uniform float rock_stretch = 4.5;     // 竖向拉伸倍数 = 层理
uniform float rock_contrast = 0.95;
uniform float rock_bump = 1.8;
uniform float dirt_threshold = 0.66;
uniform float slope_grass = 0.82;   // normal.y above this = fully ground
uniform float slope_rock = 0.48;    // normal.y below this = fully rock

varying vec3 w_pos;
varying vec3 w_nrm;

float rock_height(vec2 uv) {
	return texture(detail_noise, uv).r * 0.65
			+ texture(detail_noise, uv * 3.3 + vec2(0.37, 0.11)).r * 0.35;
}


void vertex() {
	w_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	w_nrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	float macro = texture(macro_noise, w_pos.xz * macro_scale).r;
	float detail = texture(detail_noise, w_pos.xz * detail_scale).r;

	// Fine grass texture: three taps give both the colour break-up and the
	// gradient used for the bump, so the whole blade layer costs 3 samples
	// instead of 100k triangles.
	vec2 guv = w_pos.xz * grass_scale;
	float g0 = texture(grass_detail, guv).r;
	float gx = texture(grass_detail, guv + vec2(bump_epsilon, 0.0)).r;
	float gz = texture(grass_detail, guv + vec2(0.0, bump_epsilon)).r;
	float blades = (g0 - 0.5) * grass_contrast;

	// grass: two tones broken up by every octave so it never reads as flat paint
	float g = clamp(macro * 1.5 - 0.25 + (detail - 0.5) * 0.45 + blades, 0.0, 1.0);
	vec3 grass = mix(grass_dark, grass_light, g);

	// worn dirt where the macro noise peaks
	float dirt_mask = smoothstep(dirt_threshold, dirt_threshold + 0.14,
			macro + (detail - 0.5) * 0.18);
	vec3 flat_surf = mix(grass, dirt_color * (0.82 + 0.36 * detail), dirt_mask);

	// 岩壁：竖直投影，层理横着走。
	// 两个倍频而不是一个 —— 单octave 的平滑值噪声在这个尺度下几乎看不出来。
	vec2 ruv = vec2((w_pos.x + w_pos.z) * rock_scale,
			w_pos.y * rock_scale * rock_stretch);
	float rh0 = rock_height(ruv);
	float rhx = rock_height(ruv + vec2(bump_epsilon, 0.0));
	float rhy = rock_height(ruv + vec2(0.0, bump_epsilon));
	vec3 rock = rock_color * (1.0 - rock_contrast * 0.5 + rock_contrast * rh0);

	float slope = clamp((w_nrm.y - slope_rock) / (slope_grass - slope_rock), 0.0, 1.0);
	slope = smoothstep(0.0, 1.0, slope);

	ALBEDO = mix(rock, flat_surf, slope);
	ROUGHNESS = mix(0.78, 1.0, slope);
	SPECULAR = 0.15;

	// Bump from the grass gradient, applied only where the surface is flat
	// enough to actually be grass.  This is what replaces the geometry: it is
	// the light catching the blade tops, not the blades themselves.
	vec3 bumped = normalize(vec3(-(gx - g0) * bump_strength, 1.0,
			-(gz - g0) * bump_strength));
	vec3 wn_flat = normalize(mix(w_nrm, bumped, 0.85));

	// 岩壁的法线扰动。**这一条才是岩壁看着像块平板的真正原因** ——
	// 之前 bumped 是按 slope 混进去的，而岩壁处 slope=0，
	// 于是它拿到的是 CSG 圆柱插值出来的、完全光滑的几何法线。
	// 在墙面自身的切平面里推法线（不是世界 XZ），斜墙才不会被拉扁。
	vec3 t_h = cross(vec3(0.0, 1.0, 0.0), w_nrm);
	float t_len = length(t_h);
	vec3 wn_rock = w_nrm;
	if (t_len > 0.001) {
		t_h /= t_len;
		vec3 t_v = normalize(cross(w_nrm, t_h));
		wn_rock = normalize(w_nrm - (t_h * (rhx - rh0) + t_v * (rhy - rh0))
				* rock_bump);
	}

	vec3 wn = normalize(mix(wn_rock, wn_flat, slope));
	NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);
}

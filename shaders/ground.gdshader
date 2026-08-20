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
uniform float dirt_threshold = 0.66;
uniform float slope_grass = 0.82;   // normal.y above this = fully ground
uniform float slope_rock = 0.48;    // normal.y below this = fully rock

varying vec3 w_pos;
varying vec3 w_nrm;

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

	// cliffs: project vertically so strata run horizontally on the gorge walls
	float strata = texture(detail_noise,
			vec2((w_pos.x + w_pos.z) * 0.12, w_pos.y * 0.55)).r;
	vec3 rock = rock_color * (0.70 + 0.75 * strata);

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
	vec3 wn = normalize(mix(w_nrm, bumped, slope * 0.85));
	NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);
}

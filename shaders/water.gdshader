shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// River surface (doc section 18: no fluid sim -- scrolling normals, fresnel,
// simple transparency, foam).  Deliberately avoids DEPTH_TEXTURE/SCREEN_TEXTURE
// so it stays cheap and safe on the Mobile renderer; the foam band is derived
// from the mesh UV instead of from scene depth.

uniform sampler2D wave_noise : hint_default_white, filter_linear_mipmap, repeat_enable;

uniform vec3 shallow_color : source_color = vec3(0.16, 0.34, 0.34);
uniform vec3 deep_color : source_color = vec3(0.04, 0.11, 0.16);
uniform vec3 foam_color : source_color = vec3(0.85, 0.90, 0.92);

uniform float wave_scale = 0.35;
uniform float flow_speed = 0.10;
uniform float normal_strength = 1.6;
uniform float base_alpha = 0.78;
uniform float bank_foam = 0.36;      // width of the foam band at the banks
uniform float streak_amount = 0.45;  // moving whitewater streaks

varying vec3 w_pos;

float wave(vec2 p) {
	return texture(wave_noise, p).r;
}

void vertex() {
	w_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 uv1 = w_pos.xz * wave_scale + vec2(0.13, 1.0) * TIME * flow_speed;
	vec2 uv2 = w_pos.xz * wave_scale * 1.9 + vec2(-0.07, 1.0) * TIME * flow_speed * 1.7;

	// derive a tangent-space normal from the height field
	float e = 0.030;
	float hx = (wave(uv1 + vec2(e, 0.0)) - wave(uv1 - vec2(e, 0.0)))
			+ 0.55 * (wave(uv2 + vec2(e, 0.0)) - wave(uv2 - vec2(e, 0.0)));
	float hz = (wave(uv1 + vec2(0.0, e)) - wave(uv1 - vec2(0.0, e)))
			+ 0.55 * (wave(uv2 + vec2(0.0, e)) - wave(uv2 - vec2(0.0, e)));
	NORMAL_MAP = normalize(vec3(-hx, -hz, 0.25)) * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = normal_strength;

	float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 4.0);

	// foam: a band along both banks (UV.x runs across the channel) plus
	// fast-moving streaks so the river reads as flowing, not as a puddle
	// break the bank line with noise: a perfectly straight foam edge reads as a
	// painted stripe, not as water meeting rock
	float across = abs(UV.x - 0.5) * 2.0;
	across += (wave(w_pos.xz * 0.45 + vec2(0.0, TIME * flow_speed * 0.5)) - 0.5) * 0.55;
	float edge = smoothstep(1.0 - bank_foam, 1.0 + bank_foam * 0.5, across);
	float streaks = smoothstep(0.70, 0.96,
			wave(w_pos.xz * vec2(0.11, 0.045) + vec2(0.0, TIME * flow_speed * 2.0)));
	float foam = clamp(edge + streaks * streak_amount * (0.35 + edge), 0.0, 1.0);

	vec3 water = mix(deep_color, shallow_color, 0.28 + 0.5 * fres);
	ALBEDO = mix(water, foam_color, foam);
	ALPHA = clamp(base_alpha + fres * 0.15 + foam * 0.35, 0.0, 1.0);
	ROUGHNESS = mix(0.34, 0.85, foam);
	METALLIC = 0.0;
	SPECULAR = mix(0.28, 0.15, foam);
}

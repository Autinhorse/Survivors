shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_disabled;

// Dirt roads and worn yards.  These are flat boxes laid on the ground; without
// this they read as obvious rectangles.  A noise-perturbed radial mask eats the
// edges so each patch blends into the grass, and overlapping patches merge into
// a continuous track.

uniform sampler2D detail_noise : hint_default_white, filter_linear_mipmap, repeat_enable;

uniform vec3 dirt_dark : source_color = vec3(0.26, 0.19, 0.11);
uniform vec3 dirt_light : source_color = vec3(0.46, 0.34, 0.20);
uniform float noise_scale = 0.45;
uniform float edge_softness = 0.45;
uniform float edge_break = 0.55;    // how ragged the outline is
uniform float coverage = 0.72;      // higher = patch reaches closer to its box

varying vec3 w_pos;

void vertex() {
	w_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float n = texture(detail_noise, w_pos.xz * noise_scale).r;
	float n2 = texture(detail_noise, w_pos.xz * noise_scale * 3.1).r;

	vec2 c = (UV - 0.5) * 2.0;
	float d = length(c) + (n - 0.5) * edge_break;
	float mask = 1.0 - smoothstep(coverage, coverage + edge_softness, d);

	ALBEDO = mix(dirt_dark, dirt_light, clamp(n * 0.7 + n2 * 0.5, 0.0, 1.0));
	ALPHA = mask;
	ROUGHNESS = 1.0;
}

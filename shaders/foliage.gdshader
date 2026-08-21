shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_disabled;

// Canopies and bushes: per-object wind sway plus noise break-up, so a scaled
// sphere stops reading as a scaled sphere.  Sway phase comes from the object's
// world origin, so neighbouring plants never move in lockstep.

uniform sampler2D detail_noise : hint_default_white, filter_linear_mipmap, repeat_enable;

uniform vec3 leaf_dark : source_color = vec3(0.10, 0.16, 0.05);
uniform vec3 leaf_light : source_color = vec3(0.30, 0.38, 0.13);
uniform float noise_scale = 0.55;
uniform float wind_strength = 0.10;
uniform float wind_speed = 1.1;
uniform float ao_strength = 0.45;   // darken the underside for volume
uniform float sway_height = 4.4;    // model height the sway ramps over
uniform float use_vertex_colour = 0.0;

varying vec3 w_pos;
varying float v_up;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	float phase = origin.x * 0.7 + origin.z * 0.9;
	float sway = sin(TIME * wind_speed + phase) + 0.4 * sin(TIME * wind_speed * 1.7 + phase * 1.3);
	// sway grows towards the top of the crown
	float h = clamp(VERTEX.y / sway_height, 0.15, 1.0);
	VERTEX.x += sway * wind_strength * h;
	VERTEX.z += sway * wind_strength * 0.6 * h;

	w_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_up = clamp(normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz).y * 0.5 + 0.5, 0.0, 1.0);
}

void fragment() {
	float n = texture(detail_noise, w_pos.xz * noise_scale + w_pos.y * 0.15).r;
	// use_vertex_colour: 资产把每个叶簇的颜色烘进了顶点色（见
	// tools/gen_assets_blender.py），这样"一个材质 + 一个着色器"就能同时
	// 保住颜色多样性和风摆。为 0 时退回 leaf_dark/leaf_light 的双色混合。
	vec3 leaf = mix(leaf_dark, leaf_light, clamp(n * 1.3 - 0.15, 0.0, 1.0));
	leaf = mix(leaf, COLOR.rgb * (0.82 + 0.36 * n), use_vertex_colour);
	ALBEDO = leaf * mix(1.0 - ao_strength, 1.0, v_up);
	ROUGHNESS = 1.0;
}

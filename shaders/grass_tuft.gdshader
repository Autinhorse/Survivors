shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_disabled, shadows_disabled;

// Ground decoration tufts, drawn as one MultiMesh (see
// scripts/environment/GrassField.gd).  No alpha textures: the blades are real
// (tiny) geometry, which keeps it off the transparency/overdraw path entirely --
// the exact cost the doc (section 15) warns about.
//
// INSTANCE_CUSTOM carries per-instance variation:
//   .r = colour jitter, .g = height jitter, .b = phase jitter

uniform vec3 base_color : source_color = vec3(0.12, 0.17, 0.05);
uniform vec3 tip_color : source_color = vec3(0.45, 0.47, 0.17);
uniform vec3 dry_color : source_color = vec3(0.52, 0.45, 0.18);
uniform float wind_strength = 0.16;
uniform float wind_speed = 1.6;
uniform float fade_start = 46.0;   // shrink distant tufts instead of popping
uniform float fade_end = 66.0;

varying float v_h;
varying float v_dry;

void vertex() {
	float phase = INSTANCE_CUSTOM.b * 6.283 + MODEL_MATRIX[3].x * 0.4 + MODEL_MATRIX[3].z * 0.3;
	v_h = clamp(VERTEX.y / 0.45, 0.0, 1.0);
	v_dry = INSTANCE_CUSTOM.r;

	VERTEX.y *= 0.75 + 0.5 * INSTANCE_CUSTOM.g;

	float gust = sin(TIME * wind_speed + phase) + 0.45 * sin(TIME * wind_speed * 2.3 + phase * 1.7);
	VERTEX.x += gust * wind_strength * v_h * v_h;
	VERTEX.z += gust * wind_strength * 0.5 * v_h * v_h;

	// distance fade: scale to zero rather than clipping, so the edge is invisible
	float d = length((MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz);
	float f = 1.0 - smoothstep(fade_start, fade_end, d);
	VERTEX *= f;
}

void fragment() {
	// Blades are vertical faces with an upward normal.  Under cull_disabled the
	// back faces get their normal flipped to point DOWN, which makes half of
	// every tuft unlit and near-black.  Force the ground normal instead, so the
	// clutter is lit exactly like the terrain it sits on.
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);

	vec3 green = mix(base_color, tip_color, v_h);
	ALBEDO = mix(green, dry_color, v_dry * 0.55 * v_h);
	ROUGHNESS = 1.0;
}

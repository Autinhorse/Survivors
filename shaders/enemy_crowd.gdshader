shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Data-oriented crowd unit: the whole enemy (body / head / gun / two legs) is
// ONE merged mesh drawn by ONE MultiMesh, and the mechanical animation happens
// here instead of on the CPU (doc section 7).
//
// Per-vertex authoring data, baked when the merged mesh is built:
//   COLOR.rgb  albedo tint (body red vs metal grey) -- avoids needing a second
//              surface, which would cost a second draw call
//   UV2.x      leg sign: -1 = left leg, +1 = right leg, 0 = not a leg
//   UV2.y      bob weight: 1 on the parts that ride the body bob
//
// Per-instance data:
//   INSTANCE_CUSTOM.r  animation phase, so the crowd never swings in lockstep
//   INSTANCE_CUSTOM.g  0 = alive, 1 = dead/hidden (collapsed to zero scale)
//
// The CPU therefore writes ONE transform per unit per frame and nothing else.

uniform float swing_speed = 6.0;
uniform float swing_amount = 0.55;
uniform float bob_amount = 0.05;
uniform float hip_height = 0.52;
uniform float metal_roughness = 0.45;
uniform float metal_metallic = 0.35;

void vertex() {
	float phase = INSTANCE_CUSTOM.r * 6.283185;
	float swing = sin(TIME * swing_speed + phase);

	float leg = UV2.x;
	if (abs(leg) > 0.5) {
		// rotate the leg about the hip, in the unit's local space
		float a = swing * swing_amount * sign(leg);
		vec3 p = VERTEX - vec3(0.0, hip_height, 0.0);
		float c = cos(a);
		float s = sin(a);
		p = vec3(p.x, p.y * c - p.z * s, p.y * s + p.z * c);
		VERTEX = p + vec3(0.0, hip_height, 0.0);
	}
	VERTEX.y += UV2.y * abs(swing) * bob_amount;
}

void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = metal_roughness;
	METALLIC = metal_metallic;
}

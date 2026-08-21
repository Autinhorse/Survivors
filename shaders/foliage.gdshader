shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_disabled;

// 树冠和灌木：细枝干 + 叶片贴片。
//
// 参考图的树冠中间是透光的，能看见底下的地面和影子。实体几何做不到这件事 ——
// 试过光滑球体，也试过凸包叶簇堆积，都是"一坨"。所以叶子改成挂在枝头的四边形，
// 采样叶片图集（tools/gen_leaf_atlas.py 生成）做 **alpha 裁剪**。
//
// 裁剪而不是混合：走不透明通道，不用排序、阴影自动正确、没有透明层的填充开销。
// §15 点名的 overdraw 风险主要来自 alpha 混合，裁剪基本不沾。
//
// 一个网格里同时有木头和叶片，靠**顶点色的 alpha** 区分：
//   COLOR.a = 1  叶片贴片 -> 采样图集，做裁剪
//   COLOR.a = 0  实体枝干 -> 强制不透明
// COLOR.rgb 则是这株植物的色系（深绿/黄绿/红褐/紫花），
// 所以一张灰度图集能长出所有变体。

uniform sampler2D leaf_atlas : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D detail_noise : hint_default_white, filter_linear_mipmap, repeat_enable;

uniform vec3 leaf_dark : source_color = vec3(0.10, 0.16, 0.05);
uniform vec3 leaf_light : source_color = vec3(0.30, 0.38, 0.13);
uniform float noise_scale = 0.55;
uniform float wind_strength = 0.10;
uniform float wind_speed = 1.1;
uniform float ao_strength = 0.45;   // darken the underside for volume
uniform float sway_height = 4.4;    // model height the sway ramps over
uniform float use_vertex_colour = 0.0;
uniform float use_atlas = 0.0;
uniform float alpha_cut = 0.38;
// 叶片法线往世界上方偏：贴片本身朝向是随机的，纯用贴片法线会让同一棵树上
// 相邻叶子明暗乱跳。偏向上方之后受光柔和，和参考图一致。
uniform float normal_flatten = 0.62;

varying vec3 w_pos;
varying float v_up;
varying float v_leaf;

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
	v_leaf = COLOR.a;
}

void fragment() {
	vec4 atlas = texture(leaf_atlas, UV);
	// 木头永远不透明；叶片按图集裁剪
	float leaf_px = v_leaf * use_atlas;
	ALPHA = mix(1.0, atlas.a, leaf_px);
	ALPHA_SCISSOR_THRESHOLD = alpha_cut;

	float n = texture(detail_noise, w_pos.xz * noise_scale + w_pos.y * 0.15).r;
	// use_vertex_colour: 资产把每株植物的色系烘进了顶点色（见
	// tools/gen_assets_blender.py），这样"一个材质 + 一个着色器"就能同时
	// 保住颜色多样性和风摆。为 0 时退回 leaf_dark/leaf_light 的双色混合。
	vec3 leaf = mix(leaf_dark, leaf_light, clamp(n * 1.3 - 0.15, 0.0, 1.0));
	leaf = mix(leaf, COLOR.rgb * (0.82 + 0.36 * n), use_vertex_colour);
	// 图集的 RGB 存的是叶片自身的明暗（不是颜色），乘上去才有一片片的层次
	leaf *= mix(1.0, atlas.r * 1.35, leaf_px);
	ALBEDO = leaf * mix(1.0 - ao_strength, 1.0, v_up);

	vec3 up_view = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	NORMAL = normalize(mix(NORMAL, up_view, normal_flatten * leaf_px));
	ROUGHNESS = 1.0;
}

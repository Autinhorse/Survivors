shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// 建筑等硬表面道具的表面细节。
//
// 起因：实测目标图与我们"同一块平面内部去掉光照低频后的亮度起伏"，
// 屋顶 14.6% vs 12.2%、墙面 18.9% vs 13.6% —— 每个面都是一块均匀色板。
// 而且查下来，房屋是 GLB 实例、没有 material_override，
// 生成器里那套 MAT["wall"]/MAT["roof"] 根本没作用到它们身上。
//
// 做法和 ground.gdshader 的岩壁分支一样：**在着色器里按世界坐标取噪声，
// 并从噪声梯度算法线扰动**。好处是不需要 UV、不需要切线 ——
// 程序化生成的网格（凸包、CSG）本来就没有 UV，Godot 没 UV 就生成不了切线，
// StandardMaterial3D 的法线贴图在那些网格上是静默失效的。
//
// 投影方式：**在表面自身的切平面里做平面投影**，不是三平面混合。
// 建筑全是平面四边形，同一个面内投影连续、密度恒定；相邻面的坐标系不同会有缝，
// 但那里本来就是硬边，看不出来。比三平面便宜，也没有混合带的模糊。
//
// 颜色来自顶点色（每个部件的颜色在 Blender 里烘进去，见 gen_assets_blender.py），
// 所以整栋房子是**一个材质、一次 draw call**，而不是原来的 8 个材质槽。
// COLOR.a 选择用哪一套细节参数：0 = 石/灰泥，1 = 木/茅草。

uniform sampler2D detail_noise : hint_default_white, filter_linear_mipmap, repeat_enable;

// 两套参数，按 COLOR.a 混合：0 = 石/灰泥，1 = 木/茅草。
//
// **尺度必须按屏幕像素算，不能凭感觉。** detail_noise 的频率是 0.035 cycles/texel、
// 256 texel，所以特征波长 = 0.1117 / scale 米；游戏机位是 29 px/m，
// 于是屏幕上的特征尺寸 ≈ 3.24 / scale 像素。
//   scale 2.20 -> 1.5 px   全被抗锯齿平均掉，等于没做
//   scale 0.55 -> 5.9 px   看得见
// 中间试过一版 scale 2.2/4.6，测出来纹理度反而掉回改前水平 —— 就是这个原因。
// 再往前一版屋顶像豹纹，问题不在尺度（那版是 5.9 px，正合适），在对比度太高。
uniform float scale_stone = 0.55;    // repeats per metre
uniform float scale_wood = 0.75;
uniform float contrast_stone = 0.30;
uniform float contrast_wood = 0.22;
uniform float bump_stone = 1.10;
uniform float bump_wood = 0.90;
uniform float epsilon = 0.06;
uniform float surface_roughness = 0.94;

varying vec3 w_pos;
varying vec3 w_nrm;

void vertex() {
	w_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	w_nrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 n = normalize(w_nrm);
	// 表面自身的切平面基。n 竖直时 cross 退化，退回 X 轴。
	vec3 th = cross(vec3(0.0, 1.0, 0.0), n);
	float tl = length(th);
	th = tl > 0.001 ? th / tl : vec3(1.0, 0.0, 0.0);
	vec3 tv = normalize(cross(n, th));

	float sc = mix(scale_stone, scale_wood, COLOR.a);
	float contrast = mix(contrast_stone, contrast_wood, COLOR.a);
	float bump = mix(bump_stone, bump_wood, COLOR.a);
	vec2 uv = vec2(dot(w_pos, th), dot(w_pos, tv)) * sc;
	float h0 = texture(detail_noise, uv).r;
	float hx = texture(detail_noise, uv + vec2(epsilon, 0.0)).r;
	float hy = texture(detail_noise, uv + vec2(0.0, epsilon)).r;

	ALBEDO = COLOR.rgb * (1.0 - contrast * 0.5 + contrast * h0);
	vec3 pn = normalize(n - (th * (hx - h0) + tv * (hy - h0)) * bump);
	NORMAL = normalize((VIEW_MATRIX * vec4(pn, 0.0)).xyz);
	ROUGHNESS = surface_roughness;
	SPECULAR = 0.20;
}

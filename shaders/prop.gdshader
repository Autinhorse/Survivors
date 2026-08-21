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
// 可外部编辑的贴图。资产在 Blender 侧铺了按米的平面投影 UV
// （gen_assets_blender.py 的 uv_planar），所以这里直接按 UV 取样。
// use_uv_tex = 0 时完全不影响原来的世界坐标程序化路径。
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform float use_uv_tex = 0.0;
uniform float uv_tex_scale = 1.0;
uniform float uv_tex_strength = 1.0;
// 贴图自身的平均色（生成器从 PNG 算出来填进来）。
// 按它归一化之后，贴图**只贡献偏离平均的部分** —— 花纹、结疤、你画上去的脏污，
// 整体色调仍然由顶点色控制。否则一张暖色木纹会把所有木件都拉成橙色，
// 而且用户把整张图调暗一档，场景里所有木头就跟着暗一档，很难控制。
uniform vec3 uv_tex_mean = vec3(1.0);
// 第二张贴图，由 COLOR.a 选择（0 = 石/灰泥，1 = 木/茅草）。
// 一个物件只有一个材质（顶点色方案的代价），所以两种表面的贴图
// 只能在着色器里选。多一次取样，换掉了拆材质带来的额外 draw call。
uniform sampler2D albedo_tex_b : source_color, filter_linear_mipmap, repeat_enable;
uniform vec3 uv_tex_mean_b = vec3(1.0);
uniform float uv_tex_scale_b = 1.0;
// UV 是在资产的**局部**尺寸上铺的（uv_planar），实例被缩放之后
// 纹理密度会跟着变：石头的实例缩放在 0.7-1.9 之间，密度差近 3 倍，
// 小石头上就出现大块斑。打开这个开关，UV 乘上实例的缩放量，
// 纹理密度就变成按世界米恒定。
uniform float uv_world_density = 0.0;
// 贴图的取样方式。
//
// UV 平面投影（默认）适合**平面为主**的资产：房屋、桥板、梁柱。
// 它还能控制方向（茅草顺坡、木纹顺长边），三平面做不到这一点。
//
// 但它在**凸包**上不能用：uv_planar 是逐面按法线主轴投影的，
// 相邻面的投影轴不同，UV 在每条棱上都断开。面少的盒子看不出来，
// 二十多个面的石头就成了一身错位的豹纹斑。
// 石头改走世界空间三平面：跨面连续，而且天然按世界米取样，
// 实例缩放也不影响密度。代价是 3 次取样。
uniform float use_triplanar = 0.0;
uniform float triplanar_scale = 0.8;
uniform float triplanar_sharpness = 4.0;

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

	// 实例缩放量（取 X 轴基向量的长度；这些资产都是等比缩放的）
	float inst = mix(1.0, length(MODEL_MATRIX[0].xyz), uv_world_density);
	float sc = mix(scale_stone, scale_wood, COLOR.a);
	float contrast = mix(contrast_stone, contrast_wood, COLOR.a);
	float bump = mix(bump_stone, bump_wood, COLOR.a);
	vec2 uv = vec2(dot(w_pos, th), dot(w_pos, tv)) * sc;
	float h0 = texture(detail_noise, uv).r;
	float hx = texture(detail_noise, uv + vec2(epsilon, 0.0)).r;
	float hy = texture(detail_noise, uv + vec2(0.0, epsilon)).r;

	vec3 base = COLOR.rgb * (1.0 - contrast * 0.5 + contrast * h0);
	// 外部贴图叠在顶点色之上：贴图给花纹，顶点色给每个部件的色调，
	// 两者相乘 —— 这样一张木纹图能长出深浅不同的所有木件。
	vec2 uv_a = UV * uv_tex_scale * inst;
	vec2 uv_b = UV * uv_tex_scale_b * inst;
	vec3 tex_a = texture(albedo_tex, uv_a).rgb;
	vec3 tex_b = texture(albedo_tex_b, uv_b).rgb;
	if (use_triplanar > 0.5) {
		vec3 bl = pow(abs(n), vec3(triplanar_sharpness));
		bl /= max(bl.x + bl.y + bl.z, 0.001);
		vec3 p = w_pos * triplanar_scale;
		tex_a = texture(albedo_tex, p.zy).rgb * bl.x
				+ texture(albedo_tex, p.xz).rgb * bl.y
				+ texture(albedo_tex, p.xy).rgb * bl.z;
		tex_b = tex_a;
	}
	tex_a /= max(uv_tex_mean, vec3(0.001));
	tex_b /= max(uv_tex_mean_b, vec3(0.001));
	vec3 tex = mix(tex_a, tex_b, COLOR.a);
	tex = mix(vec3(1.0), tex, uv_tex_strength);
	ALBEDO = mix(base, base * tex, use_uv_tex);
	vec3 pn = normalize(n - (th * (hx - h0) + tv * (hy - h0)) * bump);
	NORMAL = normalize((VIEW_MATRIX * vec4(pn, 0.0)).xyz);
	ROUGHNESS = surface_roughness;
	SPECULAR = 0.20;
}

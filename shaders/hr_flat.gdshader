shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled;

// 风格 "hellrider" 的通用平面着色：颜色来自**顶点色**，光照**分档**。
//
// 这个风格里所有道具（房屋、石头、树、桥）都是这一个材质：
// 没有贴图、没有法线扰动、没有三平面 —— 上一个风格花了大力气做的那一层，
// 在这里必须全部关掉，否则一眼就不是这个风格了。
//
// 唯一要做对的是**光照台阶**：参考图里同一块石头只有 3-4 个明确的亮度级，
// 台阶之间是硬边。连续的 Lambert 会让整个画面"软"下来，风格就散了。

uniform float light_steps = 3.0;
uniform float light_floor = 0.52;
// 半 Lambert 的权重。0 = clamp(dot(N,L),0,1)，1 = dot*0.5+0.5。
//
// **这是暗面读不出朝向的根因**：clamp 把所有背光面（不管朝 90° 还是 180°）
// 压成同一个值，一块石头的整个背面因此是一整片死平的色块。
// 量出来只有 2 个色阶、暗侧内部跨度 0.015 —— 基本没有层次。
// 参考图里暗面是**成组朝一个方向**的，明显分得出深浅。
uniform float light_wrap = 0.85;
// 档内的连续微分：同一档里朝向不同的面仍然拉开一点点。
// 只给很小的量 —— 台阶的硬边是这个风格的骨架，不能软掉。
uniform float face_tilt = 0.10;
// 台阶在最终亮度里占的比重，其余走连续的 N·L。
//
// **这一项是给"相邻面色差要和法线差成比例"兜底的。** floor() 量化天生
// 违反这条规则：两个法线只差 5° 的面，只要 N·L 跨过档位阈值就硬差一整档。
// 片元着色器看不到邻面，改不了这件事，只能给非比例的那部分**加上限**：
// 跳变最大 step_weight/(steps-1)，剩下的 (1-step_weight) 严格正比于法线差。
// 真正的邻面约束在 Blender 端做（face_relax），那里才有拓扑。
uniform float step_weight = 0.80;
// "位置低的面更暗"的**硬约束**。COLOR.a 里烘着这个面在自己那块几何里的
// 相对高度（0 底 1 顶），这里拿它给 N·L 封顶：低处的面再怎么朝光也亮不
// 过这个上限，高处的面不受影响。
//
// 为什么不能只在顶点色里压暗：光是运行时算的，烘进 RGB 的偏置只改反照率。
// 量过 —— 一个朝光的下部面能比它上面那个背光的面亮 4.28 倍，几个百分点的
// 反照率偏置根本压不住。封顶是**单调**的，直接消掉这种倒挂。
uniform float low_cap = 0.30;
uniform float tint = 1.0;               // 顶点色的权重，0 = 用 base_color
uniform vec3 base_color : source_color = vec3(0.6, 0.6, 0.6);
// 顶面提亮一点点：参考图的低模石头顶面明显比推导出来的更亮，
// 是美术手动提的，不是物理光照的结果
uniform float top_boost = 0.10;

// **地面分区的余色**：物体按自己**原点**落在哪个地面分区里，整体提亮或压暗
// 一点点，让它和脚下的地面属于同一"格调"。
//
// 两条必须守住的：
//   1. 按**物体原点**取格，不是按片元 —— 按片元取的话一条格线会把一块石头
//      从中间切开，那正是这个风格最怕的东西。
//   2. 下面这套取法（格子大小、朝向、偏移、档数）必须和 hr_ground 里
//      **逐字相同**，否则物体和它脚下的地面会落在不同档上，反而更乱。
// 参数默认 0，只有 flat 材质打开；水面和单位不吃这个。
uniform float zone_tint = 0.0;
uniform float tile_size = 2.6;
uniform float zone_size_mul = 5.0;
uniform float zone_steps = 3.0;
uniform float zone_jitter = 1.5;   // 分区边界在细格上浮动几格
uniform float lattice_deg = 0.0;   // 轴向。见 hr_ground 里那段

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

vec2 lattice(vec2 xz) {
	float a = radians(lattice_deg);
	float c = cos(a);
	float s = sin(a);
	return vec2(c * xz.x - s * xz.y, s * xz.x + c * xz.y);
}

float zone_step(vec2 xz) {
	// 分区边界要**跟着细格走**，不能是一条直线。
	// 把两张图的对比度都拉到 3 倍看：参考图里同一档是几块相邻菱形连成的
	// 不规则一片；我们第一版的分区是规整的大菱形，一条笔直的长边横穿整幅
	// 画面 —— 那是这一层唯一露馅的地方。
	// 做法：先落到细格上，给每个细格一个随机偏移，**再**除以 zone_size_mul。
	// 于是边界在细格上下浮动 zone_jitter 格，读出来就是不规则的一团。
	vec2 f = floor(lattice(xz) / tile_size);
	vec2 j = vec2(hash21(f + 91.0), hash21(f + 137.0)) - 0.5;
	vec2 zone = floor((f + j * zone_jitter) / zone_size_mul);
	float zh = hash21(zone + 17.0);
	return floor(zh * zone_steps) / max(zone_steps - 1.0, 1.0);
}

varying float v_up;
varying float v_zone;
// COLOR 在 light() 里读不到（只有 fragment 能读），用 varying 递过去
varying float v_h;

void vertex() {
	v_up = clamp(normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz).y, 0.0, 1.0);
	v_h = COLOR.a;
	// MODEL_MATRIX 的第四列就是物体原点的世界坐标；MultiMesh 下它是**实例**的
	// 变换，所以散布出来的每一件也各自取自己的格
	v_zone = zone_step(MODEL_MATRIX[3].xz);
}

void fragment() {
	ALBEDO = mix(base_color, COLOR.rgb, tint) * (1.0 + top_boost * v_up)
			* (1.0 + zone_tint * (v_zone - 0.5) * 2.0);
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}

void light() {
	float d = dot(NORMAL, LIGHT);
	float nl = mix(clamp(d, 0.0, 1.0), d * 0.5 + 0.5, light_wrap);
	nl = min(nl, low_cap + (1.0 - low_cap) * v_h);
	float q = floor(nl * light_steps) / max(light_steps - 1.0, 1.0);
	float shade = mix(nl, clamp(q, 0.0, 1.0), step_weight);
	float lit = mix(light_floor, 1.0, shade)
			* (1.0 + face_tilt * (nl - 0.5) * 2.0);
	DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * ATTENUATION * lit;
}

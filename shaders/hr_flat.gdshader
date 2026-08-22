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

// ------------------------------------------------------------ 面的明暗 --
// **一条规则**：面的亮度只由面法线和光照方向的**夹角 θ** 决定，
// 再加一点点逐面随机；外加一条高度封顶（见 low_cap）。
//
// 这里用 θ 本身，不是 cos θ（`dot`）。`dot` 在接近 90° 的地方压得很扁 ——
// 朝向差 20° 的两个侧面 cos 只差 0.06，分档之后挤进同一档。θ 是均匀的，
// 每一档覆盖同样宽的一段朝向。
//
// 上一版为了补 `dot` 的这个毛病，叠了三条规则：半 Lambert（把背光面摊开）、
// 档内连续微分、step_weight（限制量化造成的非比例跳变）。θ 天然就是摊开的，
// 三条补丁全部删掉了。实测两者的 侧/顶 打平（0.88 对 0.85），
// 但面与面的台阶更干脆：上一版大石头的整个前面糊成一片亮块。
//
// 方向的约定：Godot 的 LIGHT 是**指向光源**的方向，所以夹角**小** = 迎光 = 亮。
// 若按"光的传播方向"算就是夹角大 = 迎光，同一件事换个符号。
uniform float light_steps = 3.0;        // 分几档
uniform float light_floor = 0.52;       // 最暗那一档
// **档位瞄准的 θ 区间 —— 这一条决定了暗面够不够暗。**
//
// 把四档摊在整个半球（0-180°）上是错的：40° 俯角的相机看得见的面基本止步于
// θ ≈ 105°，再往后就朝下了。量过 `rock_big` 在场景光下的 62 个面：
//
//   档 3 (1.000)  面积  6.4%   θ  12-30°
//   档 2 (0.733)  面积 23.2%   θ  30-55°
//   档 1 (0.467)  面积 31.5%   θ  64-102°   <- 相机看到的最暗就到这儿
//   档 0 (0.200)  面积 38.9%   θ 106-140°   <- 其中 33% 是底面，根本看不见
//
// 也就是说**最暗那一档在画面上是浪费掉的**，可见的暗面只能拿到 0.467。
// 这就是"石头暗面不够深"的根因 —— 不是那些面差几度没跨过边界（量过，
// 它们离边界还有 10-19°），是这把尺子的量程根本没对准画面。
//
// 收到 12-105° 之后，侧/顶 从 0.86 变成 0.68；参考图两块石头是 0.59 / 0.72。
//
// 上一版这里是个 gamma（把边界往迎光侧挪）。窗口能做到 gamma 做的事，
// 而且是**可解释的**（两个端点就是"最亮的面"和"看得见的最暗的面"），
// 所以 gamma 删掉了。
uniform float light_theta_lo = 12.0;
uniform float light_theta_hi = 105.0;
// 逐面随机，加在**分档之前** —— 所以它是去拨动档位，不是给颜色加噪声。
// 参考图的树冠上相邻面的深浅不完全跟随光照方向，有一部分是美术手给的差异。
uniform float light_jitter = 0.06;
// "位置低的面更暗"的**硬约束**。COLOR.a 里烘着这个面在自己那块几何里的
// 相对高度（0 底 1 顶），这里拿它给 θ 的亮度封顶：低处的面再怎么朝光也亮不
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
// 默认 0，只有 flat 材质打开；水面和单位不吃这个。
uniform float zone_tint = 0.0;
uniform float tile_size = 2.6;
uniform float zone_size_mul = 5.0;
uniform float zone_steps = 3.0;
uniform float zone_jitter = 1.5;   // 分区边界在细格上浮动几格
uniform float lattice_deg = 0.0;   // 轴向。见 hr_ground 里那段

const float PI_ = 3.14159265;

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
// 逐面随机。平面着色下 NORMAL 在一个面上是常数，所以拿它做哈希就等于逐面。
// 用**模型空间**的法线：同一个面无论实例转到哪个 yaw 都拿到同一个随机数，
// 于是同一块石头的花纹不会因为摆放角度而变。
varying float v_rnd;
// COLOR 在 light() 里读不到（只有 fragment 能读），用 varying 递过去
varying float v_h;

void vertex() {
	v_up = clamp(normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz).y, 0.0, 1.0);
	v_h = COLOR.a;
	// MODEL_MATRIX 的第四列就是物体原点的世界坐标；MultiMesh 下它是**实例**的
	// 变换，所以散布出来的每一件也各自取自己的格
	v_zone = zone_step(MODEL_MATRIX[3].xz);
	v_rnd = hash21(NORMAL.xy * 13.0 + NORMAL.z * 37.0) - 0.5;
}

void fragment() {
	ALBEDO = mix(base_color, COLOR.rgb, tint) * (1.0 + top_boost * v_up)
			* (1.0 + zone_tint * (v_zone - 0.5) * 2.0);
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}

void light() {
	// **不能在 light() 里写 return** —— Godot 直接判编译错误
	// （"Using 'return' in the 'light' processor function is incorrect"），
	// 而且编译失败在画面上是**静默**的：材质退回默认白，所有用 hr_flat 的
	// 东西一起变成白模，很容易误读成"算法算错了"。踩过一次。
	//
	// th = 法线和"指向光源"的夹角；t = 1 在窗口的亮端，0 在暗端
	float th = degrees(acos(clamp(dot(NORMAL, LIGHT), -1.0, 1.0)));
	float t = clamp((light_theta_hi - th)
			/ max(light_theta_hi - light_theta_lo, 1.0), 0.0, 1.0);
	t = clamp(t + light_jitter * v_rnd, 0.0, 1.0);
	t = min(t, low_cap + (1.0 - low_cap) * v_h);
	float q = clamp(floor(t * light_steps)
			/ max(light_steps - 1.0, 1.0), 0.0, 1.0);
	DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * ATTENUATION
			* mix(light_floor, 1.0, q);
}

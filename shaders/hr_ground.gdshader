shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled;

// 风格 "hellrider" 的地面：**方格铺地 + 平面着色**，没有任何纹理。
//
// 参考图量出来的：地面 90% 的像素只用十来种颜色，一半以上的画面是纯色块，
// 而这些"多种颜色"其实是**同一色相下的几档明暗**
// （褐色区实测 rgb(116,83,60) / (139,104,76) / (157,112,78) / (183,136,91)）。
// 所以地面不是贴图，是**逐格随机取一档亮度**。
//
// 参考图用的是 45° 菱形网格（等距投影的产物）。本项目是正交轴向的方形世界，
// 所以这里用**轴向方格**，不做菱形旋转。
//
// 关键在于**格子边界必须是硬的**：一旦插值，整个风格就散了。
// 所以格子索引用 floor() 取，颜色在格内是常数。

uniform vec3 tile_a : source_color = vec3(0.455, 0.325, 0.235);
uniform vec3 tile_b : source_color = vec3(0.718, 0.533, 0.357);
uniform float tile_size = 4.0;          // 米
uniform float tile_steps = 4.0;         // 明暗分几档
uniform float tile_bias = 0.42;         // 偏向暗档还是亮档

// **低频分区**：格子之上再套一层大得多的格，用它选底色。
//
// 为什么需要这一层（量出来的，不是看出来的）：取参考图 zone_green_open 里
// 一块 750x310、不含任何物体的纯地面，
//
//              总 std   半幅块均值 std   最亮/最暗色块亮度比
//   参考          5.54          3.04              1.12
//   我们（旧）    3.26          1.36              1.036
//
// 总量差一倍，**大尺度差得更多**。也就是说细格的密度大致是对的，
// 缺的是"整片地不一样亮"。参考图里亮暗档之间色相 0.253->0.266、
// 饱和度 0.386->0.398 基本不动 —— 纯粹是明度阶梯，所以这里仍然只在
// tile_a..tile_b 之间取值，不引入新色相。
uniform float zone_size_mul = 5.0;      // 分区边长 = tile_size 的几倍
uniform float zone_steps = 3.0;         // 分区分几档
uniform float zone_weight = 0.55;       // 分区在 a..b 跨度里占的比重，其余归细格
uniform float zone_jitter = 1.5;   // 分区边界在细格上浮动几格

// 色格的朝向。**默认 0，就是轴向，不要改。**
//
// 参考图是 45° 菱形，那是等距投影的产物；本项目是正面 90°、正方轴向的世界，
// 格线就该是水平竖直的。这条是定过的（见 styles/hellrider/README.md
// "三条不能破的规则"），试过 45° 一次，是错的。
//
// 留这个 uniform 只是为了让"格线朝向"这件事在代码里是显式的，不是隐含在
// floor(w_pos.xz) 里。轴向格子会不会读成棋盘，靠的是 zone_weight 和
// zone_jitter，不是靠转角度。
uniform float lattice_deg = 0.0;

// 路面：踩出来的土路，同样是硬边的格子，只是换一组颜色
uniform vec3 path_a : source_color = vec3(0.310, 0.216, 0.153);
uniform vec3 path_b : source_color = vec3(0.404, 0.290, 0.204);
uniform sampler2D path_mask : hint_default_black, filter_linear, repeat_disable;
uniform vec2 path_uv_origin = vec2(-60.0, -60.0);
uniform float path_uv_size = 120.0;

// 平面着色的光照分档。参考图里同一块石头只有 3-4 个明确的亮度台阶，
// 没有连续渐变 —— 所以把 N·L 量化。
uniform float light_steps = 3.0;
uniform float light_floor = 0.55;       // 最暗的一档有多暗

varying vec3 w_pos;

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

// 低频分区的档位。**hr_flat 里有一份一模一样的**：道具要和它脚下的地面
// 落在同一档上，两边的取法必须逐字相同（格子大小、朝向、偏移、档数）。
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

void vertex() {
	w_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 cell = floor(lattice(w_pos.xz) / tile_size);
	float h = hash21(cell);
	// 量化到 tile_steps 档，格与格之间才是明确的台阶而不是噪声
	float step_i = floor(h * tile_steps) / max(tile_steps - 1.0, 1.0);
	step_i = pow(step_i, tile_bias * 2.0);

	// 低频分区：同一套 floor+hash，只是格子大 zone_size_mul 倍。
	// 偏移 17.0 是为了让它和细格的哈希不相关 —— 不偏移的话两层会在
	// 分区边界上同相，边界一下子就看得见了。
	float zone_i = zone_step(w_pos.xz);
	step_i = mix(step_i, zone_i, zone_weight);

	vec2 puv = (w_pos.xz - path_uv_origin) / path_uv_size;
	float on_path = texture(path_mask, puv).r;

	vec3 ground = mix(tile_a, tile_b, step_i);
	vec3 path = mix(path_a, path_b, step_i);
	ALBEDO = mix(ground, path, on_path);
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}

void light() {
	float nl = clamp(dot(NORMAL, LIGHT), 0.0, 1.0);
	// 分档：连续的 Lambert 会让平面着色的干净感消失
	nl = floor(nl * light_steps) / max(light_steps - 1.0, 1.0);
	DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * ATTENUATION
			* mix(light_floor, 1.0, nl);
}

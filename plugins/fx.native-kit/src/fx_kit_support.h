#ifndef FX_KIT_SUPPORT_H
#define FX_KIT_SUPPORT_H
// fx.native-kit 五个算子族共用的东西：参数取值、蒙版表示法、邻域算子、噪点。
//
// 为什么这些放在**这个扩展里**、而不去 include pixels.native 的源码：
// 两份扩展必须能各自编译、各自分发 —— 头文件路径一旦互相依赖，
// 就变成「删掉 pixels.native 这份就编不出来」，那还是把两个插件粘在一起了。
// 代价是几百行重复；换来的是任何一个插件目录都能单独删、单独更新。
//
// 参数一律容错读：JSON 里的颜色是 "#rrggbb" 字符串，连线驱动过来的是 Color，
// 关键帧采出来的是 float。C++ 侧不认识 FxPortType，只能自己认这三种形态。

#include "common/image_access.h"
#include "common/pixel_math.h"
#include "common/prelude.h"

namespace fx {

// ---------------- 参数取值 ----------------

/// 取一个键；缺键返回 NIL 型 Variant（godot-cpp 的 Dictionary 没有 getptr）。
inline Variant lookup(const Dictionary &p, const char *key) {
	String k(key);
	if (!p.has(k)) {
		return Variant();
	}
	return p[k];
}

inline double num(const Dictionary &p, const char *key, double fallback) {
	Variant v = lookup(p, key);
	switch (v.get_type()) {
		case Variant::INT:
			return double(int64_t(v));
		case Variant::FLOAT:
			return double(v);
		case Variant::BOOL:
			return bool(v) ? 1.0 : 0.0;
		default:
			return fallback;
	}
}

inline int32_t i32(const Dictionary &p, const char *key, int32_t fallback) {
	Variant v = lookup(p, key);
	switch (v.get_type()) {
		case Variant::INT:
			return int32_t(int64_t(v));
		case Variant::FLOAT:
			return int32_t(std::llround(double(v)));
		case Variant::BOOL:
			return bool(v) ? 1 : 0;
		default:
			return fallback;
	}
}

inline bool flag(const Dictionary &p, const char *key, bool fallback) {
	Variant v = lookup(p, key);
	switch (v.get_type()) {
		case Variant::BOOL:
			return bool(v);
		case Variant::INT:
			return int64_t(v) != 0;
		case Variant::FLOAT:
			return double(v) != 0.0;
		default:
			return fallback;
	}
}

inline String text(const Dictionary &p, const char *key, const char *fallback) {
	Variant v = lookup(p, key);
	if (v.get_type() != Variant::STRING) {
		return String(fallback);
	}
	return String(v);
}

/// 颜色参数三种形态都收：Color、`#rrggbb` 字符串、以及缺省。
inline Color color(const Dictionary &p, const char *key, const Color &fallback) {
	Variant v = lookup(p, key);
	if (v.get_type() == Variant::COLOR) {
		return Color(v);
	}
	if (v.get_type() == Variant::STRING) {
		String s = String(v);
		if (Color::html_is_valid(s)) {
			return Color::html(s);
		}
	}
	return fallback;
}

/// 向量参数：Vector2 或 [x, y] 数组（工程文件里存的是数组）。
inline Vector2 vec2(const Dictionary &p, const char *key, const Vector2 &fallback) {
	Variant v = lookup(p, key);
	if (v.get_type() == Variant::VECTOR2) {
		return Vector2(v);
	}
	if (v.get_type() == Variant::ARRAY) {
		Array a = Array(v);
		if (a.size() >= 2) {
			return Vector2(double(a[0]), double(a[1]));
		}
	}
	return fallback;
}

// ---------------- 图像进出 ----------------

inline Ref<Image> input_image(const Dictionary &inputs, const char *key) {
	Variant v = lookup(inputs, key);
	if (v.get_type() != Variant::OBJECT) {
		return Ref<Image>();
	}
	Ref<Image> img = Ref<Image>(v);
	return as_rgba(img);
}

inline Ref<Image> first_image(const Dictionary &inputs) {
	return input_image(inputs, "image");
}

inline Vector2i canvas_of(const Dictionary &env) {
	Variant v = lookup(env, "canvas");
	if (v.get_type() != Variant::VECTOR2I) {
		return Vector2i(128, 128);
	}
	return Vector2i(v);
}

inline Dictionary image_out(const Ref<Image> &img) {
	Dictionary out;
	out["image"] = img;
	return out;
}

inline Dictionary empty_out() {
	Dictionary out;
	out["image"] = Ref<Image>();
	return out;
}

// ---------------- 像素层小工具 ----------------

inline double luma_of(double r, double g, double b) {
	return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/// 取值模式：0=luma 1=red 2=green 3=blue 4=alpha 5=max。
/// 循环外先转成整数 —— 在循环里写 `mode == String("red")` 会让每个像素构造一次 String，
/// 实测把 channel.extract 从 0.6 ms 拖到 8.6 ms（192×108）。
enum PickMode { PICK_LUMA = 0, PICK_RED = 1, PICK_GREEN = 2, PICK_BLUE = 3, PICK_ALPHA = 4, PICK_MAX = 5 };

inline int pick_mode(const String &name) {
	if (name == String("red")) {
		return PICK_RED;
	}
	if (name == String("green")) {
		return PICK_GREEN;
	}
	if (name == String("blue")) {
		return PICK_BLUE;
	}
	if (name == String("alpha")) {
		return PICK_ALPHA;
	}
	if (name == String("max")) {
		return PICK_MAX;
	}
	return PICK_LUMA;
}

inline double pick_value(const Color &c, int mode) {
	switch (mode) {
		case PICK_RED:
			return c.r;
		case PICK_GREEN:
			return c.g;
		case PICK_BLUE:
			return c.b;
		case PICK_ALPHA:
			return c.a;
		case PICK_MAX:
			return std::max(double(c.r), std::max(double(c.g), double(c.b)));
		default:
			return luma_of(c.r, c.g, c.b);
	}
}

/// 屏幕色的主色通道：0=R 1=G 2=B。去溢色只压这一个通道。
inline int dominant_channel(const Color &c) {
	if (c.g >= c.r && c.g >= c.b) {
		return 1;
	}
	if (c.b >= c.r && c.b >= c.g) {
		return 2;
	}
	return 0;
}

/// 把一条通道压回另外两条的最大值（去溢色的核心动作）。
inline void crush(Color &c, int channel, double strength) {
	if (strength <= 0.0) {
		return;
	}
	if (channel == 1) {
		double excess = std::max(0.0, double(c.g) - std::max(double(c.r), double(c.b)));
		c.g = float(double(c.g) - excess * strength);
	} else if (channel == 2) {
		double excess = std::max(0.0, double(c.b) - std::max(double(c.r), double(c.g)));
		c.b = float(double(c.b) - excess * strength);
	} else {
		double excess = std::max(0.0, double(c.r) - std::max(double(c.g), double(c.b)));
		c.r = float(double(c.r) - excess * strength);
	}
}

/// 半透明边缘去色：按 (1 - alpha) 的比例朝灰度靠，专治彩边。
inline void desat_edge(Color &c, double amount) {
	if (amount <= 0.0) {
		return;
	}
	double gray = luma_of(c.r, c.g, c.b);
	c.r = float(double(c.r) + (gray - double(c.r)) * amount);
	c.g = float(double(c.g) + (gray - double(c.g)) * amount);
	c.b = float(double(c.b) + (gray - double(c.b)) * amount);
}

/// 蒙版视图：`(v,v,v,v)` —— RGB 与 alpha 是同一个值。
/// 只写 alpha、RGB 留白会让按亮度读的下游看到「全保留」，而且不报错。
inline void write_matte(uint8_t *d, size_t i, double value) {
	uint8_t v = clamp_byte(value * 255.0 + 0.5);
	d[i] = v;
	d[i + 1] = v;
	d[i + 2] = v;
	d[i + 3] = v;
}

// ---------------- 蒙版（float 平面） ----------------

/// 蒙版从哪来：alpha 全不透明时退到亮度（与 GDScript 侧同一判定）。
inline std::vector<float> matte_plane(const Ref<Image> &img) {
	int w = img->get_width();
	int h = img->get_height();
	PackedByteArray data = img->get_data();
	const uint8_t *s = data.ptr();
	bool opaque = true;
	for (size_t i = 3; i < size_t(data.size()); i += 4) {
		if (s[i] != 255) {
			opaque = false;
			break;
		}
	}
	std::vector<float> out(size_t(w) * h);
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			size_t i = (size_t(y) * w + x) * 4;
			if (opaque) {
				out[size_t(y) * w + x] = float(luma_of(norm_byte(s[i]),
						norm_byte(s[i + 1]), norm_byte(s[i + 2])));
			} else {
				out[size_t(y) * w + x] = float(norm_byte(s[i + 3]));
			}
		}
	}
	return out;
}

inline Ref<Image> matte_image(int w, int h, const std::vector<float> &matte, double opacity,
		bool invert) {
	PackedByteArray data;
	data.resize(w * h * 4);
	uint8_t *d = data.ptrw();
	for (size_t i = 0; i < matte.size(); i++) {
		double v = matte[i];
		if (invert) {
			v = 1.0 - v;
		}
		v = std::clamp(v * opacity, 0.0, 1.0);
		write_matte(d, i * 4, v);
	}
	return Image::create_from_data(w, h, false, Image::FORMAT_RGBA8, data);
}

/// 方形结构元的一维极值（可分离：X、Y 各做一次即等价于方块）。
/// 用极值而不是排序窗口：半径 r 的代价是 O(2r)，收到 16 也不会卡。
inline std::vector<float> extreme_sep(const std::vector<float> &src, int w, int h, int radius,
		bool keep_min) {
	if (radius <= 0) {
		return src;
	}
	std::vector<float> mid(src.size());
	for (int y = 0; y < h; y++) {
		int row = y * w;
		for (int x = 0; x < w; x++) {
			float value = src[size_t(row + x)];
			for (int k = std::max(0, x - radius); k <= std::min(w - 1, x + radius); k++) {
				float other = src[size_t(row + k)];
				value = keep_min ? std::min(value, other) : std::max(value, other);
			}
			mid[size_t(row + x)] = value;
		}
	}
	std::vector<float> out(src.size());
	for (int x = 0; x < w; x++) {
		for (int y = 0; y < h; y++) {
			float value = mid[size_t(y) * w + x];
			for (int k = std::max(0, y - radius); k <= std::min(h - 1, y + radius); k++) {
				float other = mid[size_t(k) * w + x];
				value = keep_min ? std::min(value, other) : std::max(value, other);
			}
			out[size_t(y) * w + x] = value;
		}
	}
	return out;
}

/// 盒式模糊（可分离，边界钳位）。羽化用它 —— 视觉上就是"软化边缘"。
inline std::vector<float> box_blur_sep(const std::vector<float> &src, int w, int h, int radius) {
	if (radius <= 0) {
		return src;
	}
	double span = double(radius * 2 + 1);
	std::vector<float> mid(src.size());
	for (int y = 0; y < h; y++) {
		int row = y * w;
		for (int x = 0; x < w; x++) {
			double sum = 0.0;
			for (int k = -radius; k <= radius; k++) {
				sum += src[size_t(row + std::clamp(x + k, 0, w - 1))];
			}
			mid[size_t(row + x)] = float(sum / span);
		}
	}
	std::vector<float> out(src.size());
	for (int x = 0; x < w; x++) {
		for (int y = 0; y < h; y++) {
			double sum = 0.0;
			for (int k = -radius; k <= radius; k++) {
				sum += mid[size_t(std::clamp(y + k, 0, h - 1)) * w + x];
			}
			out[size_t(y) * w + x] = float(sum / span);
		}
	}
	return out;
}

/// 确定性噪点。同一个 (x, y, seed) 永远同一个值 —— 颗粒才能进跨帧缓存。
inline double noise01(int x, int y, int seed) {
	return h01(int64_t(x) * 374761393 + int64_t(y) * 668265263 + int64_t(seed) * 2246822519LL, 0);
}

} // namespace fx

#endif // FX_KIT_SUPPORT_H

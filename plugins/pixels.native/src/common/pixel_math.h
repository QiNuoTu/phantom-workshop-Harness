#ifndef FX_NATIVE_PIXEL_MATH_H
#define FX_NATIVE_PIXEL_MATH_H
// 逐像素算术的**唯一**来源：取整、归一化、HSV、平滑步、整数哈希。
//
// 这一层存在的理由不是「复用」，而是**精度契约只能有一份**：
// 同一个 `pack_round` 如果每个 family 各写一遍，GDScript 与 C++ 的逐字节一致性
// 就会变成「看谁写的」。所有函数都直接对应 GDScript 侧的一行，注释里写明对应谁。

#include "common/prelude.h"

namespace fx {

inline double norm_byte(int p) {
	return double(p) / 255.0;
}

/// 与 GDScript 的 `int(x * 255.0 + 0.5)` 等价（x 恒在 [0,1]）。
inline uint8_t pack_unit(double v) {
	double q = v * 255.0 + 0.5;
	if (q <= 0.0) {
		return 0;
	}
	if (q >= 255.0) {
		return 255;
	}
	return uint8_t(int(q));
}

/// 与 GDScript 的 `int(round(clamp(x, 0, 1) * 255.0))` 等价。
inline uint8_t pack_round(double v) {
	double q = std::clamp(v, 0.0, 1.0) * 255.0;
	return uint8_t(int(std::round(q)));
}

/// 与 Image::_set_color_at_ofs 对 RGBA8 的写法一致：截断（不是四舍五入）。
inline uint8_t pack_trunc(double v) {
	double q = v * 255.0;
	if (q <= 0.0) {
		return 0;
	}
	if (q >= 255.0) {
		return 255;
	}
	return uint8_t(int(q));
}

/// 走 `get_pixel`/`set_pixel` 的算子要额外穿过 Color 的 **float32**：
/// 读进来是 `float(byte) / 255.0f`，写出去先落 float 再乘 255.0。
/// 少了这两步，盒式模糊这类「两次量化」的算子会零星差 1。
inline double norm_byte_f32(int p) {
	return double(float(p) / 255.0f);
}

inline uint8_t pack_trunc_f32(double v) {
	double q = double(float(v)) * 255.0;
	if (q <= 0.0) {
		return 0;
	}
	if (q >= 255.0) {
		return 255;
	}
	return uint8_t(int(q));
}

inline uint8_t clamp_byte(double v) {
	if (v <= 0.0) {
		return 0;
	}
	if (v >= 255.0) {
		return 255;
	}
	return uint8_t(int(v));
}

/// Godot 的 Color::get_hsv —— **float** 精度，与引擎逐位一致。
inline void rgb_to_hsv(float r, float g, float b, float &h, float &s, float &v) {
	float mx = std::max(r, std::max(g, b));
	float mn = std::min(r, std::min(g, b));
	v = mx;
	s = 0.0f;
	h = 0.0f;
	float delta = mx - mn;
	if (delta != 0.0f) {
		s = delta / mx;
		if (r == mx) {
			h = (g - b) / delta;
		} else if (g == mx) {
			h = 2.0f + (b - r) / delta;
		} else {
			h = 4.0f + (r - g) / delta;
		}
		h *= 60.0f;
		if (h < 0.0f) {
			h += 360.0f;
		}
		h /= 360.0f; // GDScript 的 `Color.h` 是 0..1
	}
}

/// Godot 的 Color::from_hsv —— **float** 精度。
inline void hsv_to_rgb(float h, float s, float v, float &r, float &g, float &b) {
	if (s == 0.0f) {
		r = g = b = v;
		return;
	}
	float hh = std::fmod(h * 360.0f, 360.0f);
	if (hh < 0.0f) {
		hh += 360.0f;
	}
	float h6 = hh / 60.0f;
	int i = int(h6);
	float f = h6 - float(i);
	float p = v * (1.0f - s);
	float q = v * (1.0f - s * f);
	float t = v * (1.0f - s * (1.0f - f));
	switch (i) {
		case 0: r = v; g = t; b = p; break;
		case 1: r = q; g = v; b = p; break;
		case 2: r = p; g = v; b = t; break;
		case 3: r = p; g = q; b = v; break;
		case 4: r = t; g = p; b = v; break;
		default: r = v; g = p; b = q; break;
	}
}

inline double fposmod1(double v) {
	double m = std::fmod(v, 1.0);
	return m < 0.0 ? m + 1.0 : m;
}

inline double fposmod(double v, double m) {
	double r = std::fmod(v, m);
	return r < 0.0 ? r + m : r;
}

/// 与 `FxMath.h01(a, b)` 逐字一致：int64 环绕 + **算术**右移。
/// 这两点都不能省 —— 换成无符号右移，噪声图案会整片变样。
inline double h01(int64_t a, int64_t b) {
	uint64_t n = uint64_t(a) * 374761393ULL + uint64_t(b) * 668265263ULL;
	n = (n ^ uint64_t(int64_t(n) >> 13)) * 1274126177ULL;
	n = n ^ uint64_t(int64_t(n) >> 16);
	return double(n & 0x7FFFFFFFULL) / 2147483647.0;
}

/// 与 `FxPixelKit.smoothstep(a, b, x)` 逐字一致：
/// 分母用 `max(b - a, 0.00001)` 兜底，所以 a >= b 时不会算出 NaN。
inline double smoothstep(double a, double b, double x) {
	double t = std::clamp((x - a) / std::max(b - a, 0.00001), 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}

/// `Color::lerp` 在引擎里是 **float** 精度，照抄才不会在色带边缘翻格。
inline float lerp_f(float from, float to, double weight) {
	return from + (to - from) * float(weight);
}

} // namespace fx

#endif // FX_NATIVE_PIXEL_MATH_H

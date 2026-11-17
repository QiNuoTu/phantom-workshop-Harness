#include "point_ops.h"

#include "common/counters.h"
#include "common/image_access.h"
#include "common/pixel_math.h"
#include "common/row_runner.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;
using namespace fx;

void FxNativePoint::_bind_methods() {
	ClassDB::bind_method(D_METHOD("hue", "src", "shift", "saturation", "value", "threads"),
			&FxNativePoint::hue, DEFVAL(1));
	ClassDB::bind_method(D_METHOD("tint", "src", "color", "amount", "preserve_luma", "threads"),
			&FxNativePoint::tint, DEFVAL(1));
	ClassDB::bind_method(D_METHOD("bright", "src", "threshold", "threads"),
			&FxNativePoint::bright, DEFVAL(1));
	ClassDB::bind_method(D_METHOD("levels", "src", "brightness", "contrast", "gamma", "threads"),
			&FxNativePoint::levels, DEFVAL(1));
	ClassDB::bind_method(D_METHOD("threshold_map", "src", "cutoff", "softness", "use_luma", "color", "threads"),
			&FxNativePoint::threshold_map, DEFVAL(1));
	ClassDB::bind_method(D_METHOD("ramp_three", "src", "shadow", "mid", "high", "midpoint", "amount", "threads"),
			&FxNativePoint::ramp_three, DEFVAL(1));
	ClassDB::bind_method(D_METHOD("invert", "src", "threads"),
			&FxNativePoint::invert, DEFVAL(1));
	ClassDB::bind_method(D_METHOD("chromatic", "src", "offset", "threads"),
			&FxNativePoint::chromatic, DEFVAL(1));
	ClassDB::bind_method(D_METHOD("alpha_tint", "src", "color", "opacity", "threads"),
			&FxNativePoint::alpha_tint, DEFVAL(1));
	ClassDB::bind_method(D_METHOD("recolor", "src", "palette", "palette_amount", "tint", "tint_amount", "alpha", "threads"),
			&FxNativePoint::recolor, DEFVAL(1));
	// 统计读数也走绑定：桥只用基础类型，诊断面板与测试都靠它。
	// 计数器是进程级的（见 common/counters.h），所以任一族的 stats 都是全局数。
	ClassDB::bind_method(D_METHOD("stats"), &FxNativePoint::stats);
	ClassDB::bind_method(D_METHOD("reset_stats"), &FxNativePoint::reset_stats);
}

Ref<Image> FxNativePoint::hue(const Ref<Image> &p_src, double p_shift, double p_sat,
		double p_val, int p_threads) {
	Ref<Image> src = as_rgba(p_src);
	if (src.is_null()) {
		return Ref<Image>();
	}
	int w = src->get_width();
	int h = src->get_height();
	PackedByteArray in = src->get_data();
	PackedByteArray out;
	out.resize(in.size());
	const uint8_t *s = in.ptr();
	uint8_t *d = out.ptrw();
	count_call((long long)w * h);
	for_rows(h, w, p_threads, [&](int y0, int y1) {
		size_t begin = size_t(y0) * w * 4;
		size_t end = size_t(y1) * w * 4;
		for (size_t i = begin; i < end; i += 4) {
			// Color 构造是 float：先按 double 归一化，再落到 float。
			float cr = float(norm_byte(s[i]));
			float cg = float(norm_byte(s[i + 1]));
			float cb = float(norm_byte(s[i + 2]));
			float hh, ss, vv;
			rgb_to_hsv(cr, cg, cb, hh, ss, vv);
			// 加减与 clamp 回到 double（GDScript 侧是 double），再交给 from_hsv 的 float 形参。
			double nh = fposmod1(double(hh) + p_shift);
			double ns = std::clamp(double(ss) + p_sat, 0.0, 1.0);
			double nv = std::clamp(double(vv) + p_val, 0.0, 1.0);
			float orr, ogg, obb;
			hsv_to_rgb(float(nh), float(ns), float(nv), orr, ogg, obb);
			d[i] = pack_unit(double(orr));
			d[i + 1] = pack_unit(double(ogg));
			d[i + 2] = pack_unit(double(obb));
			d[i + 3] = s[i + 3];
		}
	});
	return make_image(w, h, out);
}


Ref<Image> FxNativePoint::tint(const Ref<Image> &p_src, const Color &p_color, double p_amount,
		bool p_preserve_luma, int p_threads) {
	Ref<Image> src = as_rgba(p_src);
	if (src.is_null()) {
		return Ref<Image>();
	}
	int w = src->get_width();
	int h = src->get_height();
	PackedByteArray in = src->get_data();
	PackedByteArray out;
	out.resize(in.size());
	const uint8_t *s = in.ptr();
	uint8_t *d = out.ptrw();
	const double tr = double(p_color.r), tg = double(p_color.g), tb = double(p_color.b);
	const double tint_luma = std::max(0.2126 * tr + 0.7152 * tg + 0.0722 * tb, 0.001);
	const float weight = float(p_amount); // Color::lerp 的权参是 float
	const bool preserve = p_preserve_luma;
	count_call((long long)w * h);
	for_rows(h, w, p_threads, [&](int y0, int y1) {
		size_t begin = size_t(y0) * w * 4;
		size_t end = size_t(y1) * w * 4;
		for (size_t i = begin; i < end; i += 4) {
			double r = norm_byte(s[i]);
			double g = norm_byte(s[i + 1]);
			double b = norm_byte(s[i + 2]);
			// `Color(c.r * tint.r, ...)`：double 乘完再落 float。
			float nr, ng, nb;
			if (preserve) {
				double l = 0.2126 * r + 0.7152 * g + 0.0722 * b;
				nr = float(std::clamp(tr * l / tint_luma, 0.0, 1.0));
				ng = float(std::clamp(tg * l / tint_luma, 0.0, 1.0));
				nb = float(std::clamp(tb * l / tint_luma, 0.0, 1.0));
			} else {
				nr = float(r * tr);
				ng = float(g * tg);
				nb = float(b * tb);
			}
			// Color::lerp 在 float 里做：from + (to - from) * weight。
			float cr = float(r);
			float cg = float(g);
			float cb = float(b);
			float lr = cr + (nr - cr) * weight;
			float lg = cg + (ng - cg) * weight;
			float lb = cb + (nb - cb) * weight;
			// 注意这里是**截断**不是四舍五入：GDScript 版走 `out.set_pixel(...)`，
			// 而 Image::_set_color_at_ofs 对 RGBA8 做的是 `uint8_t(CLAMP(r*255,0,255))`。
			// 差这一步就会有约 1/4 的字节差 1（四舍五入 vs 截断）。
			d[i] = pack_trunc(double(lr));
			d[i + 1] = pack_trunc(double(lg));
			d[i + 2] = pack_trunc(double(lb));
			d[i + 3] = s[i + 3];
		}
	});
	return make_image(w, h, out);
}


Ref<Image> FxNativePoint::bright(const Ref<Image> &p_src, double p_threshold, int p_threads) {
	Ref<Image> src = as_rgba(p_src);
	if (src.is_null()) {
		return Ref<Image>();
	}
	int w = src->get_width();
	int h = src->get_height();
	PackedByteArray in = src->get_data();
	PackedByteArray out;
	out.resize(in.size());
	const uint8_t *s = in.ptr();
	uint8_t *d = out.ptrw();
	const double hi = std::min(p_threshold + 0.25, 1.0);
	const double inv = 1.0 / std::max(hi - p_threshold, 0.00001);
	count_call((long long)w * h);
	for_rows(h, w, p_threads, [&](int y0, int y1) {
		size_t begin = size_t(y0) * w * 4;
		size_t end = size_t(y1) * w * 4;
		for (size_t i = begin; i < end; i += 4) {
			double l = 0.2126 * norm_byte(s[i]) + 0.7152 * norm_byte(s[i + 1]) +
					0.0722 * norm_byte(s[i + 2]);
			double t = std::clamp((l - p_threshold) * inv, 0.0, 1.0);
			double keep = t * t * (3.0 - 2.0 * t);
			d[i] = clamp_byte(double(s[i]) * keep + 0.5);
			d[i + 1] = clamp_byte(double(s[i + 1]) * keep + 0.5);
			d[i + 2] = clamp_byte(double(s[i + 2]) * keep + 0.5);
			d[i + 3] = clamp_byte(double(s[i + 3]) * keep + 0.5);
		}
	});
	return make_image(w, h, out);
}


Ref<Image> FxNativePoint::levels(const Ref<Image> &p_src, double p_brightness,
		double p_contrast, double p_gamma, int p_threads) {
	Ref<Image> src = as_rgba(p_src);
	if (src.is_null()) {
		return Ref<Image>();
	}
	int w = src->get_width();
	int h = src->get_height();
	PackedByteArray in = src->get_data();
	PackedByteArray out;
	out.resize(in.size());
	const uint8_t *s = in.ptr();
	uint8_t *d = out.ptrw();
	const double inv_gamma = 1.0 / std::max(p_gamma, 0.05);
	uint8_t lut[256];
	for (int i = 0; i < 256; i++) {
		double v = (norm_byte(i) - 0.5) * p_contrast + 0.5 + p_brightness;
		v = std::clamp(v, 0.0, 1.0);
		v = std::pow(v, inv_gamma);
		lut[i] = pack_round(v);
	}
	count_call((long long)w * h);
	for_rows(h, w, p_threads, [&](int y0, int y1) {
		size_t begin = size_t(y0) * w * 4;
		size_t end = size_t(y1) * w * 4;
		for (size_t i = begin; i < end; i += 4) {
			d[i] = lut[s[i]];
			d[i + 1] = lut[s[i + 1]];
			d[i + 2] = lut[s[i + 2]];
			d[i + 3] = s[i + 3];
		}
	});
	return make_image(w, h, out);
}


Ref<Image> FxNativePoint::threshold_map(const Ref<Image> &p_src, double p_cutoff,
		double p_softness, bool p_use_luma, const Color &p_color, int p_threads) {
	Ref<Image> src = as_rgba(p_src);
	if (src.is_null()) {
		return Ref<Image>();
	}
	int w = src->get_width();
	int h = src->get_height();
	PackedByteArray in = src->get_data();
	PackedByteArray out;
	out.resize(in.size());
	out.fill(0);
	const uint8_t *s = in.ptr();
	uint8_t *d = out.ptrw();
	const uint8_t cr = pack_round(double(p_color.r));
	const uint8_t cg = pack_round(double(p_color.g));
	const uint8_t cb = pack_round(double(p_color.b));
	const double ca = double(pack_round(double(p_color.a)));
	const double lo = p_cutoff - p_softness;
	const double hi = p_cutoff + p_softness;
	const bool hard = p_softness <= 0.0001;
	const bool use_luma = p_use_luma;
	count_call((long long)w * h);
	for_rows(h, w, p_threads, [&](int y0, int y1) {
		size_t begin = size_t(y0) * w * 4;
		size_t end = size_t(y1) * w * 4;
		for (size_t i = begin; i < end; i += 4) {
			double value;
			if (use_luma) {
				value = (0.2126 * double(s[i]) + 0.7152 * double(s[i + 1]) +
								0.0722 * double(s[i + 2])) /
						255.0;
			} else {
				value = double(s[i + 3]) / 255.0;
			}
			double k;
			if (hard) {
				k = value >= p_cutoff ? 1.0 : 0.0;
			} else {
				k = smoothstep(lo, hi, value);
			}
			if (k <= 0.0) {
				continue; // 输出画布本来就是全 0，与 GDScript 的 `continue` 等价
			}
			d[i] = cr;
			d[i + 1] = cg;
			d[i + 2] = cb;
			d[i + 3] = uint8_t(int(std::round(ca * k)));
		}
	});
	return make_image(w, h, out);
}


Ref<Image> FxNativePoint::ramp_three(const Ref<Image> &p_src, const Color &p_shadow,
		const Color &p_mid, const Color &p_high, double p_midpoint, double p_amount,
		int p_threads) {
	Ref<Image> src = as_rgba(p_src);
	if (src.is_null()) {
		return Ref<Image>();
	}
	int w = src->get_width();
	int h = src->get_height();
	PackedByteArray in = src->get_data();
	PackedByteArray out;
	out.resize(in.size());
	const uint8_t *s = in.ptr();
	uint8_t *d = out.ptrw();
	const float sr = p_shadow.r, sg = p_shadow.g, sb = p_shadow.b;
	const float mr = p_mid.r, mg = p_mid.g, mb = p_mid.b;
	const float hr = p_high.r, hg = p_high.g, hb = p_high.b;
	const double mid = p_midpoint;
	const double inv_hi = 1.0 / std::max(1.0 - mid, 0.001);
	count_call((long long)w * h);
	for_rows(h, w, p_threads, [&](int y0, int y1) {
		size_t begin = size_t(y0) * w * 4;
		size_t end = size_t(y1) * w * 4;
		for (size_t i = begin; i < end; i += 4) {
			const float cr = float(norm_byte(s[i]));
			const float cg = float(norm_byte(s[i + 1]));
			const float cb = float(norm_byte(s[i + 2]));
			const double l = 0.2126 * double(cr) + 0.7152 * double(cg) + 0.0722 * double(cb);
			float tr, tg, tb;
			if (l <= mid) {
				const double t = std::clamp(l / mid, 0.0, 1.0);
				tr = lerp_f(sr, mr, t);
				tg = lerp_f(sg, mg, t);
				tb = lerp_f(sb, mb, t);
			} else {
				const double t = std::clamp((l - mid) * inv_hi, 0.0, 1.0);
				tr = lerp_f(mr, hr, t);
				tg = lerp_f(mg, hg, t);
				tb = lerp_f(mb, hb, t);
			}
			d[i] = clamp_byte((double(cr) + (double(tr) - double(cr)) * p_amount) * 255.0 + 0.5);
			d[i + 1] = clamp_byte((double(cg) + (double(tg) - double(cg)) * p_amount) * 255.0 + 0.5);
			d[i + 2] = clamp_byte((double(cb) + (double(tb) - double(cb)) * p_amount) * 255.0 + 0.5);
			d[i + 3] = s[i + 3];
		}
	});
	return make_image(w, h, out);
}

// ===================== 程序化生成 =====================


Ref<Image> FxNativePoint::invert(const Ref<Image> &p_src, int p_threads) {
	Ref<Image> src = as_rgba(p_src);
	if (src.is_null()) {
		return Ref<Image>();
	}
	int w = src->get_width();
	int h = src->get_height();
	PackedByteArray in = src->get_data();
	PackedByteArray out;
	out.resize(in.size());
	const uint8_t *s = in.ptr();
	uint8_t *d = out.ptrw();
	count_call((long long)w * h);
	for_rows(h, w, p_threads, [&](int y0, int y1) {
		size_t begin = size_t(y0) * w * 4;
		size_t end = size_t(y1) * w * 4;
		for (size_t i = begin; i < end; i += 4) {
			d[i] = uint8_t(255 - s[i]);
			d[i + 1] = uint8_t(255 - s[i + 1]);
			d[i + 2] = uint8_t(255 - s[i + 2]);
			d[i + 3] = s[i + 3];
		}
	});
	return make_image(w, h, out);
}


Ref<Image> FxNativePoint::chromatic(const Ref<Image> &p_src, int p_offset, int p_threads) {
	Ref<Image> src = as_rgba(p_src);
	if (src.is_null()) {
		return Ref<Image>();
	}
	int w = src->get_width();
	int h = src->get_height();
	PackedByteArray in = src->get_data();
	PackedByteArray out;
	out.resize(in.size());
	const uint8_t *s = in.ptr();
	uint8_t *d = out.ptrw();
	const int off = p_offset;
	count_call((long long)w * h);
	for_rows(h, w, p_threads, [&](int y0, int y1) {
		for (int y = y0; y < y1; y++) {
			const size_t row = size_t(y) * w * 4;
			for (int x = 0; x < w; x++) {
				const size_t i = row + size_t(x) * 4;
				const uint8_t *r = s + row + size_t(std::clamp(x + off, 0, w - 1)) * 4;
				const uint8_t *b = s + row + size_t(std::clamp(x - off, 0, w - 1)) * 4;
				d[i] = r[0];
				d[i + 1] = s[i + 1];
				d[i + 2] = b[2];
				d[i + 3] = s[i + 3];
			}
		}
	});
	return make_image(w, h, out);
}


Ref<Image> FxNativePoint::alpha_tint(const Ref<Image> &p_src, const Color &p_color,
		double p_opacity, int p_threads) {
	Ref<Image> src = as_rgba(p_src);
	if (src.is_null()) {
		return Ref<Image>();
	}
	int w = src->get_width();
	int h = src->get_height();
	PackedByteArray in = src->get_data();
	PackedByteArray out;
	out.resize(in.size());
	const uint8_t *s = in.ptr();
	uint8_t *d = out.ptrw();
	const uint8_t cr = pack_round(double(p_color.r));
	const uint8_t cg = pack_round(double(p_color.g));
	const uint8_t cb = pack_round(double(p_color.b));
	count_call((long long)w * h);
	for_rows(h, w, p_threads, [&](int y0, int y1) {
		size_t begin = size_t(y0) * w * 4;
		size_t end = size_t(y1) * w * 4;
		for (size_t i = begin; i < end; i += 4) {
			const double a = norm_byte(s[i + 3]) * p_opacity;
			d[i] = cr;
			d[i + 1] = cg;
			d[i + 2] = cb;
			d[i + 3] = pack_round(std::clamp(a, 0.0, 1.0));
		}
	});
	return make_image(w, h, out);
}


Ref<Image> FxNativePoint::recolor(const Ref<Image> &p_src, const PackedColorArray &p_palette,
		double p_palette_amount, const Color &p_tint, double p_tint_amount, double p_alpha,
		int p_threads) {
	Ref<Image> src = as_rgba(p_src);
	if (src.is_null()) {
		return Ref<Image>();
	}
	int w = src->get_width();
	int h = src->get_height();
	PackedByteArray in = src->get_data();
	PackedByteArray out;
	out.resize(in.size());
	const uint8_t *s = in.ptr();
	uint8_t *d = out.ptrw();
	const int palette_count = p_palette.size();
	const bool use_palette = palette_count >= 2 && p_palette_amount > 0.0;
	const bool use_tint = p_tint_amount > 0.0;
	const double palette_span = double(std::max(palette_count - 1, 0));
	// 调色板很小（个位到几十项），整份拷出来比每像素过一次 Variant 索引快得多。
	std::vector<Color> palette;
	if (use_palette) {
		palette.reserve(palette_count);
		for (int i = 0; i < palette_count; i++) {
			palette.push_back(p_palette[i]);
		}
	}
	const float tr = p_tint.r, tg = p_tint.g, tb = p_tint.b;
	count_call((long long)w * h);
	for_rows(h, w, p_threads, [&](int y0, int y1) {
		size_t begin = size_t(y0) * w * 4;
		size_t end = size_t(y1) * w * 4;
		for (size_t i = begin; i < end; i += 4) {
			const uint8_t a_byte = s[i + 3];
			if (a_byte == 0) {
				// GDScript 侧对全透明像素直接 continue，字节原样保留。
				d[i] = s[i];
				d[i + 1] = s[i + 1];
				d[i + 2] = s[i + 2];
				d[i + 3] = 0;
				continue;
			}
			Color c(float(norm_byte(s[i])), float(norm_byte(s[i + 1])),
					float(norm_byte(s[i + 2])), float(norm_byte(a_byte)));
			if (use_palette) {
				const double l = std::clamp(0.2126 * double(c.r) + 0.7152 * double(c.g) +
												0.0722 * double(c.b),
						0.0, 1.0);
				const int index = std::clamp(int(std::round(l * palette_span)), 0, palette_count - 1);
				const Color &t = palette[size_t(index)];
				c = c.lerp(Color(t.r, t.g, t.b, c.a), float(p_palette_amount));
			}
			if (use_tint) {
				c = c.lerp(Color(float(double(c.r) * double(tr)), float(double(c.g) * double(tg)),
								  float(double(c.b) * double(tb)), c.a),
						float(p_tint_amount));
			}
			d[i] = pack_round(double(c.r));
			d[i + 1] = pack_round(double(c.g));
			d[i + 2] = pack_round(double(c.b));
			// GDScript 是 `color.a *= alpha`：先在 double 里乘，再落回 float32。
			d[i + 3] = pack_round(double(float(double(c.a) * p_alpha)));
		}
	});
	return make_image(w, h, out);
}

Dictionary FxNativePoint::stats() {
	return fx::stats();
}

void FxNativePoint::reset_stats() {
	fx::reset();
}

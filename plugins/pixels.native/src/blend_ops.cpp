#include "blend_ops.h"

#include "common/counters.h"
#include "common/image_access.h"
#include "common/pixel_math.h"
#include "common/row_runner.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;
using namespace fx;

void FxNativeBlend::_bind_methods() {
	ClassDB::bind_method(D_METHOD("bloom_add", "base", "glow", "amount", "threads"),
			&FxNativeBlend::bloom_add, DEFVAL(1));
	ClassDB::bind_method(D_METHOD("mask_image", "src", "mask", "channel", "invert", "softness", "opacity", "threads"),
			&FxNativeBlend::mask_image, DEFVAL(1));
	ClassDB::bind_method(D_METHOD("blend", "base", "top", "rect", "at", "mode", "opacity", "threads"),
			&FxNativeBlend::blend, DEFVAL(1));
	ClassDB::bind_method(D_METHOD("composite_add", "color", "light", "size", "light_k", "threads"),
			&FxNativeBlend::composite_add, DEFVAL(1));
	ClassDB::bind_method(D_METHOD("paint_blobs", "size", "background", "data"),
			&FxNativeBlend::paint_blobs);
	// 统计读数也走绑定：桥只用基础类型，诊断面板与测试都靠它。
	// 计数器是进程级的（见 common/counters.h），所以任一族的 stats 都是全局数。
	ClassDB::bind_method(D_METHOD("stats"), &FxNativeBlend::stats);
	ClassDB::bind_method(D_METHOD("reset_stats"), &FxNativeBlend::reset_stats);
}

Ref<Image> FxNativeBlend::bloom_add(const Ref<Image> &p_base, const Ref<Image> &p_glow,
		double p_amount, int p_threads) {
	Ref<Image> base = as_rgba(p_base);
	Ref<Image> glow = as_rgba(p_glow);
	if (base.is_null() || glow.is_null()) {
		return Ref<Image>();
	}
	if (base->get_size() != glow->get_size()) {
		return Ref<Image>();
	}
	int w = base->get_width();
	int h = base->get_height();
	PackedByteArray in = base->get_data();
	PackedByteArray gl = glow->get_data();
	PackedByteArray out;
	out.resize(in.size());
	const uint8_t *s = in.ptr();
	const uint8_t *g = gl.ptr();
	uint8_t *d = out.ptrw();
	count_call((long long)w * h);
	for_rows(h, w, p_threads, [&](int y0, int y1) {
		size_t begin = size_t(y0) * w * 4;
		size_t end = size_t(y1) * w * 4;
		for (size_t i = begin; i < end; i += 4) {
			d[i] = clamp_byte(double(s[i]) + double(g[i]) * p_amount + 0.5);
			d[i + 1] = clamp_byte(double(s[i + 1]) + double(g[i + 1]) * p_amount + 0.5);
			d[i + 2] = clamp_byte(double(s[i + 2]) + double(g[i + 2]) * p_amount + 0.5);
			d[i + 3] = s[i + 3];
		}
	});
	return make_image(w, h, out);
}


Ref<Image> FxNativeBlend::mask_image(const Ref<Image> &p_src, const Ref<Image> &p_mask,
		int p_channel, bool p_invert, double p_softness, double p_opacity, int p_threads) {
	Ref<Image> src = as_rgba(p_src);
	if (src.is_null()) {
		return Ref<Image>();
	}
	// 遮罩也要转成 RGBA8：算子里传进来的可能是灰度/压缩图，通道偏移与 alpha 都跟格式有关。
	Ref<Image> mask_rgba = p_mask.is_null() ? Ref<Image>() : as_rgba(p_mask);
	if (!p_mask.is_null() && mask_rgba.is_null()) {
		return Ref<Image>();
	}
	int w = src->get_width();
	int h = src->get_height();
	int mw = mask_rgba.is_null() ? w : mask_rgba->get_width();
	int mh = mask_rgba.is_null() ? h : mask_rgba->get_height();
	if (mw <= 0 || mh <= 0) {
		return Ref<Image>();
	}
	PackedByteArray mb = mask_rgba.is_null() ? PackedByteArray() : mask_rgba->get_data();
	if (mask_rgba.is_null()) {
		// 与 GDScript 侧一致：没接遮罩就是一张**全透明**画布（FxPixelKit.canvas），
		// alpha=0 → 结果整张透明。不是「全遮挡」（255）—— 这两者差一个反相。
		mb.resize(w * h * 4);
		mb.fill(0);
	}
	PackedByteArray in = src->get_data();
	PackedByteArray out;
	out.resize(in.size());
	const uint8_t *s = in.ptr();
	const uint8_t *m = mb.ptr();
	uint8_t *d = out.ptrw();
	const double lo = 0.5 - p_softness * 0.5;
	const double hi = 0.5 + p_softness * 0.5;
	const double soft_span = std::max(hi - lo, 0.00001);
	const bool invert = p_invert;
	const int channel = p_channel;
	count_call((long long)w * h);
	for_rows(h, w, p_threads, [&](int y0, int y1) {
		for (int y = y0; y < y1; y++) {
			int my = std::clamp(int(double(y) / std::max(double(h), 1.0) * double(mh)), 0, mh - 1);
			size_t dst_row = size_t(y) * w * 4;
			for (int x = 0; x < w; x++) {
				int mx = std::clamp(int(double(x) / std::max(double(w), 1.0) * double(mw)), 0, mw - 1);
				const uint8_t *mc = m + (size_t(my) * mw + mx) * 4;
				double value = 0.0;
				switch (channel) {
					case 1: value = norm_byte(mc[0]); break;
					case 2: value = norm_byte(mc[1]); break;
					case 3: value = norm_byte(mc[2]); break;
					case 4:
						value = 0.2126 * norm_byte(mc[0]) + 0.7152 * norm_byte(mc[1]) +
								0.0722 * norm_byte(mc[2]);
						break;
					default: value = norm_byte(mc[3]); break;
				}
				if (invert) {
					value = 1.0 - value;
				}
				if (p_softness > 0.0) {
					double t = std::clamp((value - lo) / soft_span, 0.0, 1.0);
					value = t * t * (3.0 - 2.0 * t);
				}
				size_t i = dst_row + size_t(x) * 4;
				d[i] = s[i];
				d[i + 1] = s[i + 1];
				d[i + 2] = s[i + 2];
				d[i + 3] = pack_round(norm_byte(s[i + 3]) * value * p_opacity);
			}
		}
	});
	return make_image(w, h, out);
}


void FxNativeBlend::blend(const Ref<Image> &p_base, const Ref<Image> &p_top, const Rect2i &p_rect,
		const Vector2i &p_at, int p_mode, double p_opacity, int p_threads) {
	if (p_base.is_null() || p_top.is_null()) {
		return;
	}
	int dw = p_base->get_width();
	int dh = p_base->get_height();
	int sw = p_top->get_width();
	int sh = p_top->get_height();
	if (dw <= 0 || dh <= 0 || sw <= 0 || sh <= 0) {
		return;
	}
	PackedByteArray dd = p_base->get_data();
	PackedByteArray sd = p_top->get_data();
	if (dd.size() != dw * dh * 4 || sd.size() != sw * sh * 4) {
		return;
	}
	uint8_t *dst = dd.ptrw();
	const uint8_t *src = sd.ptr();
	const bool normal_only = p_mode <= 0;
	const int mode = p_mode;
	const int rx = p_rect.position.x;
	const int ry = p_rect.position.y;
	const int rw = p_rect.size.x;
	const int rh = p_rect.size.y;
	const int ax = p_at.x;
	const int ay = p_at.y;
	const int stride_s = sw * 4;
	const int stride_d = dw * 4;
	count_call((long long)rw * rh);
	for_rows(dh, dw, p_threads, [&](int y0, int y1) {
		int row_begin = std::max(y0, ay);
		int row_end = std::min(y1, ay + rh);
		for (int y = row_begin; y < row_end; y++) {
			int local_y = y - ay;
			const uint8_t *sp = src + (size_t(ry + local_y) * stride_s + size_t(rx) * 4);
			uint8_t *dp = dst + (size_t(y) * stride_d + size_t(ax) * 4);
			int count = std::min(rw, dw - ax);
			for (int x = 0; x < count; x++) {
				double sa = norm_byte(sp[3]) * p_opacity;
				if (sa <= 0.002) {
					sp += 4;
					dp += 4;
					continue;
				}
				double da = norm_byte(dp[3]);
				double oa = sa + da * (1.0 - sa);
				if (oa <= 0.0001) {
					dp[0] = dp[1] = dp[2] = dp[3] = 0;
					sp += 4;
					dp += 4;
					continue;
				}
				double sr = norm_byte(sp[0]);
				double sg = norm_byte(sp[1]);
				double sb = norm_byte(sp[2]);
				double dr = norm_byte(dp[0]);
				double dg = norm_byte(dp[1]);
				double db = norm_byte(dp[2]);
				double br = sr, bg = sg, bb = sb;
				if (!normal_only) {
					switch (mode) {
						case 1:
							br = std::min(dr + sr, 1.0);
							bg = std::min(dg + sg, 1.0);
							bb = std::min(db + sb, 1.0);
							break;
						case 2:
							br = dr * sr;
							bg = dg * sg;
							bb = db * sb;
							break;
						case 3:
							br = 1.0 - (1.0 - dr) * (1.0 - sr);
							bg = 1.0 - (1.0 - dg) * (1.0 - sg);
							bb = 1.0 - (1.0 - db) * (1.0 - sb);
							break;
						case 4:
							br = dr < 0.5 ? 2.0 * dr * sr : 1.0 - 2.0 * (1.0 - dr) * (1.0 - sr);
							bg = dg < 0.5 ? 2.0 * dg * sg : 1.0 - 2.0 * (1.0 - dg) * (1.0 - sg);
							bb = db < 0.5 ? 2.0 * db * sb : 1.0 - 2.0 * (1.0 - db) * (1.0 - sb);
							break;
						case 5:
							br = std::max(dr - sr, 0.0);
							bg = std::max(dg - sg, 0.0);
							bb = std::max(db - sb, 0.0);
							break;
						default:
							break;
					}
				}
				double k = sa / oa;
				double kb = da * (1.0 - sa) / oa;
				dp[0] = pack_round(br * k + dr * kb);
				dp[1] = pack_round(bg * k + dg * kb);
				dp[2] = pack_round(bb * k + db * kb);
				dp[3] = pack_round(oa);
				sp += 4;
				dp += 4;
			}
		}
	});
	// 合成是**原地写回**：调用方的 Image 已经是副本，语义与 _blend_bytes 一致。
	const_cast<Image *>(p_base.ptr())->set_data(dw, dh, false, Image::FORMAT_RGBA8, dd);
}

// ===================== 邻域 / 卷积 =====================


Ref<Image> FxNativeBlend::composite_add(const PackedByteArray &p_color,
		const PackedInt32Array &p_light, const Vector2i &p_size, double p_light_k,
		int p_threads) {
	int w = p_size.x;
	int h = p_size.y;
	if (w <= 0 || h <= 0) {
		return Ref<Image>();
	}
	if (p_color.size() < w * h * 4 || p_light.size() < w * h * 3) {
		return Ref<Image>();
	}
	const uint8_t *c = p_color.ptr();
	// 光缓冲是 int32：加性光可以叠到 255 以上，截断在下面的 min(...,255) 里做。
	const int32_t *l = p_light.ptr();
	PackedByteArray out;
	out.resize(w * h * 4);
	out.fill(0);
	uint8_t *d = out.ptrw();
	count_call((long long)w * h);
	for_rows(h, w, p_threads, [&](int y0, int y1) {
		for (int y = y0; y < y1; y++) {
			for (int x = 0; x < w; x++) {
				const size_t i = size_t(y) * w + x;
				const size_t ci = i * 4;
				const size_t li = i * 3;
				const double ca = norm_byte(c[ci + 3]);
				const double lr = std::min(double(l[li]) * p_light_k, 255.0);
				const double lg = std::min(double(l[li + 1]) * p_light_k, 255.0);
				const double lb = std::min(double(l[li + 2]) * p_light_k, 255.0);
				const double peak = std::max(lr, std::max(lg, lb));
				const double oa = std::max(ca, peak / 255.0);
				if (oa <= 0.0) {
					continue; // 输出画布已是全 0，与 `continue` 等价
				}
				d[ci] = clamp_byte((double(c[ci]) * ca + lr) / oa);
				d[ci + 1] = clamp_byte((double(c[ci + 1]) * ca + lg) / oa);
				d[ci + 2] = clamp_byte((double(c[ci + 2]) * ca + lb) / oa);
				d[ci + 3] = clamp_byte(std::clamp(oa, 0.0, 1.0) * 255.0);
			}
		}
	});
	return make_image(w, h, out);
}


Ref<Image> FxNativeBlend::paint_blobs(const Vector2i &p_size, const Color &p_background,
		const PackedFloat32Array &p_data) {
	int w = p_size.x;
	int h = p_size.y;
	if (w <= 0 || h <= 0) {
		return Ref<Image>();
	}
	// 背景填充与 Image::fill 一致：通道 * 255.0（double）后**截断**落字节。
	PackedByteArray buf;
	buf.resize(w * h * 4);
	const uint8_t bg[4] = {
		pack_trunc(double(p_background.r)),
		pack_trunc(double(p_background.g)),
		pack_trunc(double(p_background.b)),
		pack_trunc(double(p_background.a)),
	};
	uint8_t *d = buf.ptrw();
	for (size_t i = 0; i < size_t(w) * h * 4; i += 4) {
		d[i] = bg[0];
		d[i + 1] = bg[1];
		d[i + 2] = bg[2];
		d[i + 3] = bg[3];
	}
	const float *data = p_data.ptr();
	const int count = p_data.size() / 9;
	for (int b = 0; b < count; b++) {
		const float *e = data + b * 9;
		const double cx = double(e[0]);
		const double cy = double(e[1]);
		const double radius = std::max(0.5, double(e[2]));
		const double strength = std::clamp(double(e[3]), 0.0, 1.0);
		const double core = std::clamp(double(e[4]), 0.01, 1.0);
		const double tr = double(e[5]), tg = double(e[6]), tb = double(e[7]);
		const double ta = double(e[8]);
		const int x0 = std::clamp(int(std::floor(cx - radius)), 0, w - 1);
		const int x1 = std::clamp(int(std::ceil(cx + radius)), 0, w - 1);
		const int y0 = std::clamp(int(std::floor(cy - radius)), 0, h - 1);
		const int y1 = std::clamp(int(std::ceil(cy + radius)), 0, h - 1);
		const double core_radius = core * radius;
		for (int y = y0; y <= y1; y++) {
			const double dy = double(y) - cy;
			for (int x = x0; x <= x1; x++) {
				const double dx = double(x) - cx;
				const double dist = std::sqrt(dx * dx + dy * dy);
				if (dist > radius) {
					continue;
				}
				const double fall = 1.0 - smoothstep(core_radius, radius, dist);
				const double add = fall * strength;
				if (add <= 0.002) {
					continue;
				}
				uint8_t *p = d + (size_t(y) * w + x) * 4;
				const double da = norm_byte(p[3]);
				const double oa = std::min(1.0, da + add * ta);
				const double denom = std::max(oa, 0.001);
				p[0] = pack_round((norm_byte(p[0]) * da + tr * add * ta) / denom);
				p[1] = pack_round((norm_byte(p[1]) * da + tg * add * ta) / denom);
				p[2] = pack_round((norm_byte(p[2]) * da + tb * add * ta) / denom);
				p[3] = pack_round(oa);
			}
		}
	}
	count_call((long long)w * h);
	return Image::create_from_data(w, h, false, Image::FORMAT_RGBA8, buf);
}

Dictionary FxNativeBlend::stats() {
	return fx::stats();
}

void FxNativeBlend::reset_stats() {
	fx::reset();
}

#include "warp_ops.h"

#include "common/counters.h"
#include "common/image_access.h"
#include "common/pixel_math.h"
#include "common/row_runner.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;
using namespace fx;

void FxNativeWarp::_bind_methods() {
	ClassDB::bind_method(D_METHOD("wave", "src", "amplitude", "omega", "phase", "axis_mode", "threads"),
			&FxNativeWarp::wave, DEFVAL(1));
	ClassDB::bind_method(D_METHOD("remap", "src", "coords", "threads"),
			&FxNativeWarp::remap, DEFVAL(1));
	ClassDB::bind_method(D_METHOD("affine", "src", "offset", "scale", "rotation_deg", "anchor", "wrap_mode", "threads"),
			&FxNativeWarp::affine, DEFVAL(1));
	// 统计读数也走绑定：桥只用基础类型，诊断面板与测试都靠它。
	// 计数器是进程级的（见 common/counters.h），所以任一族的 stats 都是全局数。
	ClassDB::bind_method(D_METHOD("stats"), &FxNativeWarp::stats);
	ClassDB::bind_method(D_METHOD("reset_stats"), &FxNativeWarp::reset_stats);
}

Ref<Image> FxNativeWarp::wave(const Ref<Image> &p_src, double p_amplitude, double p_omega,
		double p_phase, int p_axis_mode, int p_threads) {
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
	// axis_mode：0 = 沿 X 位移（表按 y）、1 = both（表按 x，y 附加 0.6 倍）、2 = 沿 Y 位移（表按 x）
	const bool by_y = p_axis_mode == 0;
	const bool both = p_axis_mode == 1;
	std::vector<double> table(by_y ? h : w);
	for (int i = 0; i < (int)table.size(); i++) {
		table[i] = std::sin(double(i) * p_omega + p_phase) * p_amplitude;
	}
	const double *tab = table.data();
	count_call((long long)w * h);
	for_rows(h, w, p_threads, [&](int y0, int y1) {
		for (int y = y0; y < y1; y++) {
			double sy_shift = by_y ? tab[y] : 0.0;
			uint8_t *row = d + size_t(y) * w * 4;
			for (int x = 0; x < w; x++) {
				double shift = by_y ? sy_shift : tab[x];
				double ux = double(x);
				double uy = double(y);
				if (by_y || both) {
					ux += shift;
				}
				if (both) {
					uy += shift * 0.6;
				} else if (!by_y) {
					uy += shift;
				}
				sample_bilinear(s, w, h, ux, uy, row + x * 4);
			}
		}
	});
	return make_image(w, h, out);
}


Ref<Image> FxNativeWarp::remap(const Ref<Image> &p_src, const PackedFloat32Array &p_coords,
		int p_threads) {
	Ref<Image> src = as_rgba(p_src);
	if (src.is_null()) {
		return Ref<Image>();
	}
	int w = src->get_width();
	int h = src->get_height();
	if (p_coords.size() < w * h * 2) {
		return Ref<Image>();
	}
	PackedByteArray in = src->get_data();
	PackedByteArray out;
	out.resize(in.size());
	const uint8_t *s = in.ptr();
	uint8_t *d = out.ptrw();
	const float *coords = p_coords.ptr();
	count_call((long long)w * h);
	for_rows(h, w, p_threads, [&](int y0, int y1) {
		for (int y = y0; y < y1; y++) {
			const float *c = coords + size_t(y) * w * 2;
			uint8_t *row = d + size_t(y) * w * 4;
			for (int x = 0; x < w; x++) {
				sample_bilinear(s, w, h, double(c[x * 2]), double(c[x * 2 + 1]), row + x * 4);
			}
		}
	});
	return make_image(w, h, out);
}


Ref<Image> FxNativeWarp::affine(const Ref<Image> &p_src, const Vector2 &p_offset,
		const Vector2 &p_scale, double p_rotation_deg, const Vector2 &p_anchor, int p_wrap_mode,
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
	out.fill(0);
	const uint8_t *s = in.ptr();
	uint8_t *d = out.ptrw();
	double sx_scale = double(p_scale.x);
	double sy_scale = double(p_scale.y);
	if (std::abs(sx_scale) < 0.0001) {
		sx_scale = 0.0001;
	}
	if (std::abs(sy_scale) < 0.0001) {
		sy_scale = 0.0001;
	}
	const double cx = double(p_anchor.x) * double(w);
	const double cy = double(p_anchor.y) * double(h);
	const double rad = p_rotation_deg * 0.017453292519943295;
	const double cs = std::cos(rad);
	const double sn = std::sin(rad);
	const double inv_sx = 1.0 / sx_scale;
	const double inv_sy = 1.0 / sy_scale;
	const double ox = double(p_offset.x);
	const double oy = double(p_offset.y);
	const int wrap = p_wrap_mode; // 0 = transparent, 1 = repeat, 2 = clamp
	count_call((long long)w * h);
	for_rows(h, w, p_threads, [&](int y0, int y1) {
		for (int y = y0; y < y1; y++) {
			const double py = double(y) + 0.5 - cy - oy;
			uint8_t *row = d + size_t(y) * w * 4;
			for (int x = 0; x < w; x++) {
				const double px = double(x) + 0.5 - cx - ox;
				int sx = int(std::floor((px * cs + py * sn) * inv_sx + cx));
				int sy = int(std::floor((-px * sn + py * cs) * inv_sy + cy));
				if (wrap == 1) {
					sx = ((sx % w) + w) % w;
					sy = ((sy % h) + h) % h;
				} else if (wrap == 2) {
					sx = std::clamp(sx, 0, w - 1);
					sy = std::clamp(sy, 0, h - 1);
				} else if (sx < 0 || sy < 0 || sx >= w || sy >= h) {
					continue;
				}
				const uint8_t *sp = s + (size_t(sy) * w + sx) * 4;
				uint8_t *dp = row + x * 4;
				// 与 GDScript 的 `if src[si+3] > 0` 对齐：全透明源像素保持
				// (0,0,0,0)，不拷 RGB —— 否则「透明处藏着颜色」会在下游预乘时露出来。
				if (sp[3] > 0) {
					dp[0] = sp[0];
					dp[1] = sp[1];
					dp[2] = sp[2];
					dp[3] = sp[3];
				}
			}
		}
	});
	return make_image(w, h, out);
}

Dictionary FxNativeWarp::stats() {
	return fx::stats();
}

void FxNativeWarp::reset_stats() {
	fx::reset();
}

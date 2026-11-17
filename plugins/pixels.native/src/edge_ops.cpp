#include "edge_ops.h"

#include "common/counters.h"
#include "common/image_access.h"
#include "common/pixel_math.h"
#include "common/row_runner.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;
using namespace fx;

void FxNativeEdge::_bind_methods() {
	ClassDB::bind_method(D_METHOD("outline_alpha", "src", "thickness", "inside", "threshold", "color", "threads"),
			&FxNativeEdge::outline_alpha, DEFVAL(1));
	ClassDB::bind_method(D_METHOD("box_blur", "src", "radius", "threads"),
			&FxNativeEdge::box_blur, DEFVAL(1));
	// 统计读数也走绑定：桥只用基础类型，诊断面板与测试都靠它。
	// 计数器是进程级的（见 common/counters.h），所以任一族的 stats 都是全局数。
	ClassDB::bind_method(D_METHOD("stats"), &FxNativeEdge::stats);
	ClassDB::bind_method(D_METHOD("reset_stats"), &FxNativeEdge::reset_stats);
}

Ref<Image> FxNativeEdge::outline_alpha(const Ref<Image> &p_src, int p_thickness, bool p_inside,
		double p_threshold, const Color &p_color, int p_threads) {
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
	const int t = std::clamp(p_thickness, 1, 16);
	// 与 GDScript 侧同一组 8 邻域方向（顺序也一致，方便逐字节排查）。
	const int dxs[8] = { t, -t, 0, 0, t, -t, t, -t };
	const int dys[8] = { 0, 0, t, -t, t, t, -t, -t };
	const bool inside = p_inside;
	const double e0 = p_threshold;
	const double inv_e = 1.0 / 0.15;
	// Color 的通道是 float32：先落到 double 再用，与 GDScript 里 `color[c]` 的取值一致。
	const double cr = double(p_color.r);
	const double cg = double(p_color.g);
	const double cb = double(p_color.b);
	count_call((long long)w * h);
	for_rows(h, w, p_threads, [&](int y0, int y1) {
		for (int y = y0; y < y1; y++) {
			const size_t row = size_t(y) * w * 4;
			for (int x = 0; x < w; x++) {
				const size_t i = row + size_t(x) * 4;
				const double own = norm_byte(s[i + 3]);
				double edge = 0.0;
				for (int k = 0; k < 8; k++) {
					const int nx = std::clamp(x + dxs[k], 0, w - 1);
					const int ny = std::clamp(y + dys[k], 0, h - 1);
					const double na = norm_byte(s[(size_t(ny) * w + nx) * 4 + 3]);
					edge = inside ? std::max(edge, own - na) : std::max(edge, na - own);
				}
				const double st = std::clamp((edge - e0) * inv_e, 0.0, 1.0);
				const double strength = st * st * (3.0 - 2.0 * st);
				const double out_a = inside ? std::max(own, strength * own) : std::max(own, strength);
				d[i] = pack_round(norm_byte(s[i]) + (cr - norm_byte(s[i])) * strength);
				d[i + 1] = pack_round(norm_byte(s[i + 1]) + (cg - norm_byte(s[i + 1])) * strength);
				d[i + 2] = pack_round(norm_byte(s[i + 2]) + (cb - norm_byte(s[i + 2])) * strength);
				d[i + 3] = pack_round(out_a);
			}
		}
	});
	return make_image(w, h, out);
}

/// 可分离盒式模糊（滑动窗）。两趟都把中间结果**量化回字节**，
/// 因为 GDScript 版的中间图就是一张 Image —— 少这一次量化，第二趟就会差 1。


Ref<Image> FxNativeEdge::box_blur(const Ref<Image> &p_src, int p_radius, int p_threads) {
	Ref<Image> src = as_rgba(p_src);
	if (src.is_null()) {
		return Ref<Image>();
	}
	int w = src->get_width();
	int h = src->get_height();
	int r = std::clamp(p_radius, 0, 128);
	if (r <= 0) {
		return src;
	}
	PackedByteArray in = src->get_data();
	const uint8_t *s = in.ptr();
	const double window = double(r * 2 + 1);
	count_call(2LL * w * h);

	PackedByteArray tmp;
	tmp.resize(in.size());
	uint8_t *t = tmp.ptrw();
	for_rows(h, w, p_threads, [&](int y0, int y1) {
		for (int y = y0; y < y1; y++) {
			const size_t row = size_t(y) * w * 4;
			double ar = 0.0, ag = 0.0, ab = 0.0, aa = 0.0;
			for (int k = -r; k <= r; k++) {
				const uint8_t *p = s + row + size_t(std::clamp(k, 0, w - 1)) * 4;
				ar += norm_byte_f32(p[0]);
				ag += norm_byte_f32(p[1]);
				ab += norm_byte_f32(p[2]);
				aa += norm_byte_f32(p[3]);
			}
			for (int x = 0; x < w; x++) {
				uint8_t *q = t + row + size_t(x) * 4;
				q[0] = pack_trunc_f32(ar / window);
				q[1] = pack_trunc_f32(ag / window);
				q[2] = pack_trunc_f32(ab / window);
				q[3] = pack_trunc_f32(aa / window);
				const uint8_t *lp = s + row + size_t(std::clamp(x - r, 0, w - 1)) * 4;
				const uint8_t *ep = s + row + size_t(std::clamp(x + r + 1, 0, w - 1)) * 4;
				ar += norm_byte_f32(ep[0]) - norm_byte_f32(lp[0]);
				ag += norm_byte_f32(ep[1]) - norm_byte_f32(lp[1]);
				ab += norm_byte_f32(ep[2]) - norm_byte_f32(lp[2]);
				aa += norm_byte_f32(ep[3]) - norm_byte_f32(lp[3]);
			}
		}
	});

	PackedByteArray out;
	out.resize(in.size());
	uint8_t *d = out.ptrw();
	// 第二趟按**列**滑窗。借 for_rows 的切分器时把「行数」传宽度 w：
	// 每块的像素量不变，线程数估算仍然正确。
	for_rows(w, h, p_threads, [&](int x0, int x1) {
		for (int x = x0; x < x1; x++) {
			const size_t col = size_t(x) * 4;
			double ar = 0.0, ag = 0.0, ab = 0.0, aa = 0.0;
			for (int k = -r; k <= r; k++) {
				const uint8_t *p = t + size_t(std::clamp(k, 0, h - 1)) * w * 4 + col;
				ar += norm_byte_f32(p[0]);
				ag += norm_byte_f32(p[1]);
				ab += norm_byte_f32(p[2]);
				aa += norm_byte_f32(p[3]);
			}
			for (int y = 0; y < h; y++) {
				uint8_t *q = d + size_t(y) * w * 4 + col;
				q[0] = pack_trunc_f32(ar / window);
				q[1] = pack_trunc_f32(ag / window);
				q[2] = pack_trunc_f32(ab / window);
				q[3] = pack_trunc_f32(aa / window);
				const uint8_t *lp = t + size_t(std::clamp(y - r, 0, h - 1)) * w * 4 + col;
				const uint8_t *ep = t + size_t(std::clamp(y + r + 1, 0, h - 1)) * w * 4 + col;
				ar += norm_byte_f32(ep[0]) - norm_byte_f32(lp[0]);
				ag += norm_byte_f32(ep[1]) - norm_byte_f32(lp[1]);
				ab += norm_byte_f32(ep[2]) - norm_byte_f32(lp[2]);
				aa += norm_byte_f32(ep[3]) - norm_byte_f32(lp[3]);
			}
		}
	});
	return make_image(w, h, out);
}

// ===================== 点运算（查表族）=====================

Dictionary FxNativeEdge::stats() {
	return fx::stats();
}

void FxNativeEdge::reset_stats() {
	fx::reset();
}

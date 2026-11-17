#include "gen_ops.h"

#include "common/counters.h"
#include "common/image_access.h"
#include "common/pixel_math.h"
#include "common/row_runner.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;
using namespace fx;

void FxNativeGen::_bind_methods() {
	ClassDB::bind_method(D_METHOD("gradient_fill", "size", "mode", "a", "b", "angle_deg", "center", "scale", "softness", "threads"),
			&FxNativeGen::gradient_fill, DEFVAL(1));
	ClassDB::bind_method(D_METHOD("radial_spokes", "size", "count", "spin", "width", "length", "intensity", "center", "color", "threads"),
			&FxNativeGen::radial_spokes, DEFVAL(1));
	ClassDB::bind_method(D_METHOD("radial_ring", "size", "phase", "max_radius", "width", "intensity", "center", "ring_color", "core_color", "threads"),
			&FxNativeGen::radial_ring, DEFVAL(1));
	ClassDB::bind_method(D_METHOD("shape_field", "size", "kind", "fill", "bg", "radius", "feather", "sides", "center", "rotation_deg", "aspect", "threads"),
			&FxNativeGen::shape_field, DEFVAL(1));
	ClassDB::bind_method(D_METHOD("noise_field", "size", "cell", "density", "a", "b", "seed", "threads"),
			&FxNativeGen::noise_field, DEFVAL(1));
	// 统计读数也走绑定：桥只用基础类型，诊断面板与测试都靠它。
	// 计数器是进程级的（见 common/counters.h），所以任一族的 stats 都是全局数。
	ClassDB::bind_method(D_METHOD("stats"), &FxNativeGen::stats);
	ClassDB::bind_method(D_METHOD("reset_stats"), &FxNativeGen::reset_stats);
}

Ref<Image> FxNativeGen::gradient_fill(const Vector2i &p_size, int p_mode, const Color &p_a,
		const Color &p_b, double p_angle_deg, const Vector2 &p_center, double p_scale,
		double p_softness, int p_threads) {
	int w = p_size.x;
	int h = p_size.y;
	if (w <= 0 || h <= 0) {
		return Ref<Image>();
	}
	Ref<Image> img = blank_image(w, h);
	PackedByteArray buf = img->get_data();
	uint8_t *dst = buf.ptrw();
	const double rad = p_angle_deg * 0.017453292519943295;
	const double dirx = std::cos(rad);
	const double diry = std::sin(rad);
	const double cx = double(p_center.x);
	const double cy = double(p_center.y);
	const double inv_w = 1.0 / std::max(double(w), 1.0);
	const double inv_h = 1.0 / std::max(double(h), 1.0);
	const float ar = p_a.r, ag = p_a.g, ab = p_a.b, aa = p_a.a;
	const float br = p_b.r, bg = p_b.g, bb = p_b.b, ba = p_b.a;
	const double soft = p_softness;
	const int mode = p_mode;
	count_call((long long)w * h);
	for_rows(h, w, p_threads, [&](int y0, int y1) {
		for (int y = y0; y < y1; y++) {
			const double ny = (double(y) * inv_h - cy) * p_scale;
			uint8_t *row = dst + size_t(y) * w * 4;
			for (int x = 0; x < w; x++) {
				const double nx = (double(x) * inv_w - cx) * p_scale;
				double t;
				if (mode == 1) {
					t = std::clamp(std::sqrt(nx * nx + ny * ny) * 2.0, 0.0, 1.0);
				} else if (mode == 2) {
					t = fposmod1(std::atan2(ny, nx) / 6.283185307179586 + 0.5);
				} else {
					t = std::clamp(nx * dirx + ny * diry + 0.5, 0.0, 1.0);
				}
				if (soft > 0.0) {
					t = smoothstep(0.5 - soft * 0.5, 0.5 + soft * 0.5, t);
				}
				const double tt = std::clamp(t, 0.0, 1.0);
				uint8_t *p = row + size_t(x) * 4;
				p[0] = pack_unit(double(ar) + (double(br) - double(ar)) * tt);
				p[1] = pack_unit(double(ag) + (double(bg) - double(ag)) * tt);
				p[2] = pack_unit(double(ab) + (double(bb) - double(ab)) * tt);
				p[3] = pack_unit(double(aa) + (double(ba) - double(aa)) * tt);
			}
		}
	});
	return Image::create_from_data(w, h, false, Image::FORMAT_RGBA8, buf);
}


Ref<Image> FxNativeGen::radial_spokes(const Vector2i &p_size, int p_count, double p_spin,
		double p_width, double p_length, double p_intensity, const Vector2 &p_center,
		const Color &p_color, int p_threads) {
	int w = p_size.x;
	int h = p_size.y;
	if (w <= 0 || h <= 0) {
		return Ref<Image>();
	}
	PackedByteArray buf;
	buf.resize(w * h * 4);
	uint8_t *dst = buf.ptrw();
	const double inv_w = 1.0 / std::max(double(w), 1.0);
	const double inv_h = 1.0 / std::max(double(h), 1.0);
	const double cx = double(p_center.x);
	const double cy = double(p_center.y);
	const double count = double(p_count);
	const double spin = p_spin;
	const double width = p_width;
	const double falloff_a = p_length * 0.4;
	const double falloff_b = p_length;
	// rays 的径向衰减与辐条宽度都是常量，颜色整张图一样：只在最后按 alpha 打包。
	const uint8_t cr = pack_round(double(p_color.r));
	const uint8_t cg = pack_round(double(p_color.g));
	const uint8_t cb = pack_round(double(p_color.b));
	count_call((long long)w * h);
	for_rows(h, w, p_threads, [&](int y0, int y1) {
		for (int y = y0; y < y1; y++) {
			const double dy = double(y) * inv_h - cy;
			uint8_t *row = dst + size_t(y) * w * 4;
			for (int x = 0; x < w; x++) {
				const double dx = (double(x) * inv_w - cx) * 1.6;
				const double dist = std::sqrt(dx * dx + dy * dy);
				const double angle = fposmod1(std::atan2(dy, dx) / 6.283185307179586 * count + spin);
				const double spoke = 1.0 - smoothstep(0.0, width, std::min(angle, 1.0 - angle));
				const double falloff = 1.0 - smoothstep(falloff_a, falloff_b, dist);
				const double core = 1.0 - smoothstep(0.0, 0.16, dist);
				const double alpha = std::clamp((spoke * falloff * 0.8 + core) * p_intensity,
						0.0, 1.0);
				uint8_t *p = row + size_t(x) * 4;
				p[0] = cr;
				p[1] = cg;
				p[2] = cb;
				p[3] = pack_round(alpha);
			}
		}
	});
	return Image::create_from_data(w, h, false, Image::FORMAT_RGBA8, buf);
}


Ref<Image> FxNativeGen::radial_ring(const Vector2i &p_size, double p_phase,
		double p_max_radius, double p_width, double p_intensity, const Vector2 &p_center,
		const Color &p_ring_color, const Color &p_core_color, int p_threads) {
	int w = p_size.x;
	int h = p_size.y;
	if (w <= 0 || h <= 0) {
		return Ref<Image>();
	}
	PackedByteArray buf;
	buf.resize(w * h * 4);
	uint8_t *dst = buf.ptrw();
	const double inv_w = 1.0 / std::max(double(w), 1.0);
	const double inv_h = 1.0 / std::max(double(h), 1.0);
	const double cx = double(p_center.x);
	const double cy = double(p_center.y);
	const double r = p_phase * p_max_radius;
	const double fade = 1.0 - p_phase * 0.55;
	const double width = std::max(p_width, 0.001);
	const double core_span = r * 0.6 + 0.01;
	const double core_fade = (1.0 - p_phase) * 0.6;
	const float kr = p_ring_color.r, kg = p_ring_color.g, kb = p_ring_color.b;
	const float ir = p_core_color.r, ig = p_core_color.g, ib = p_core_color.b;
	count_call((long long)w * h);
	for_rows(h, w, p_threads, [&](int y0, int y1) {
		for (int y = y0; y < y1; y++) {
			const double dy = double(y) * inv_h - cy;
			uint8_t *row = dst + size_t(y) * w * 4;
			for (int x = 0; x < w; x++) {
				const double dx = (double(x) * inv_w - cx) * 1.6;
				const double dist = std::sqrt(dx * dx + dy * dy);
				const double ring = 1.0 - smoothstep(0.0, width, std::abs(dist - r));
				const double core = (1.0 - smoothstep(0.0, core_span, dist)) * core_fade;
				const double energy = std::clamp((ring + core) * fade * p_intensity, 0.0, 1.0);
				const double mix = std::clamp(ring / std::max(ring + core, 0.001), 0.0, 1.0);
				uint8_t *p = row + size_t(x) * 4;
				p[0] = pack_round(double(lerp_f(ir, kr, mix)));
				p[1] = pack_round(double(lerp_f(ig, kg, mix)));
				p[2] = pack_round(double(lerp_f(ib, kb, mix)));
				p[3] = pack_round(energy);
			}
		}
	});
	return Image::create_from_data(w, h, false, Image::FORMAT_RGBA8, buf);
}


Ref<Image> FxNativeGen::shape_field(const Vector2i &p_size, int p_kind, const Color &p_fill,
		const Color &p_bg, double p_radius, double p_feather, int p_sides,
		const Vector2 &p_center, double p_rotation_deg, double p_aspect, int p_threads) {
	int w = p_size.x;
	int h = p_size.y;
	if (w <= 0 || h <= 0) {
		return Ref<Image>();
	}
	PackedByteArray buf;
	buf.resize(w * h * 4);
	uint8_t *dst = buf.ptrw();
	const double inv_w = 1.0 / std::max(double(w), 1.0);
	const double inv_h = 1.0 / std::max(double(h), 1.0);
	const double rad = p_rotation_deg * 0.017453292519943295;
	const double cs = std::cos(rad);
	const double sn = std::sin(rad);
	const double seg = 6.283185307179586 / double(std::clamp(p_sides, 3, 16));
	const double feather = std::max(p_feather, 0.0001);
	const double inv_feather = 1.0 / (2.0 * feather);
	const double radius = std::max(p_radius, 0.001);
	const double cx = double(p_center.x);
	const double cy = double(p_center.y);
	const int kind = p_kind;
	const float fr = p_fill.r, fg = p_fill.g, fb = p_fill.b, fa = p_fill.a;
	const float br = p_bg.r, bg = p_bg.g, bb = p_bg.b, ba = p_bg.a;
	count_call((long long)w * h);
	for_rows(h, w, p_threads, [&](int y0, int y1) {
		for (int y = y0; y < y1; y++) {
			const double py = (double(y) * inv_h - cy) * 2.0;
			uint8_t *row = dst + size_t(y) * w * 4;
			for (int x = 0; x < w; x++) {
				const double px = (double(x) * inv_w - cx) * 2.0 * p_aspect;
				const double rx = px * cs - py * sn;
				const double ry = px * sn + py * cs;
				const double dist = std::sqrt(rx * rx + ry * ry);
				double d;
				switch (kind) {
					case 1:
						d = std::abs(dist - radius) - radius * 0.16;
						break;
					case 2: {
						const double qx = std::abs(rx) - radius;
						const double qy = std::abs(ry) - radius;
						d = std::sqrt(std::max(qx, 0.0) * std::max(qx, 0.0) +
									  std::max(qy, 0.0) * std::max(qy, 0.0)) +
								std::min(std::max(qx, qy), 0.0);
						break;
					}
					case 3:
						d = (std::abs(rx) + std::abs(ry)) - radius;
						break;
					case 4:
						d = std::max(std::abs(rx) * 0.866 + ry * 0.5, -ry) - radius * 0.7;
						break;
					case 5: {
						const double ang = std::atan2(ry, rx);
						const double bump = std::cos(fposmod(ang, seg) - seg * 0.5);
						d = dist - radius * (0.55 + 0.45 * bump);
						break;
					}
					default:
						d = dist - radius;
						break;
				}
				const double st = std::clamp((d + feather) * inv_feather, 0.0, 1.0);
				const double coverage = 1.0 - st * st * (3.0 - 2.0 * st);
				uint8_t *p = row + size_t(x) * 4;
				p[0] = pack_unit(double(lerp_f(br, fr, coverage)));
				p[1] = pack_unit(double(lerp_f(bg, fg, coverage)));
				p[2] = pack_unit(double(lerp_f(bb, fb, coverage)));
				p[3] = pack_unit(double(lerp_f(ba, fa, coverage)));
			}
		}
	});
	return Image::create_from_data(w, h, false, Image::FORMAT_RGBA8, buf);
}


Ref<Image> FxNativeGen::noise_field(const Vector2i &p_size, int p_cell, double p_density,
		const Color &p_a, const Color &p_b, int64_t p_seed, int p_threads) {
	int w = p_size.x;
	int h = p_size.y;
	if (w <= 0 || h <= 0) {
		return Ref<Image>();
	}
	const int cell = std::clamp(p_cell, 1, 128);
	PackedByteArray buf;
	buf.resize(w * h * 4);
	uint8_t *d = buf.ptrw();
	const uint8_t ca[4] = { pack_trunc(double(p_a.r)), pack_trunc(double(p_a.g)),
		pack_trunc(double(p_a.b)), pack_trunc(double(p_a.a)) };
	const uint8_t cb[4] = { pack_trunc(double(p_b.r)), pack_trunc(double(p_b.g)),
		pack_trunc(double(p_b.b)), pack_trunc(double(p_b.a)) };
	count_call((long long)w * h);
	for_rows(h, w, p_threads, [&](int y0, int y1) {
		for (int y = y0; y < y1; y++) {
			const int by = y / cell;
			uint8_t *row = d + size_t(y) * w * 4;
			for (int x = 0; x < w; x++) {
				const int bx = x / cell;
				// GDScript 侧是 `int(float(x) / float(cell))`：正数下与整除同义。
				const double r = h01(int64_t(bx) + p_seed * 131, int64_t(by) + p_seed * 17);
				const uint8_t *src = r < p_density ? cb : ca;
				uint8_t *p = row + size_t(x) * 4;
				p[0] = src[0];
				p[1] = src[1];
				p[2] = src[2];
				p[3] = src[3];
			}
		}
	});
	return Image::create_from_data(w, h, false, Image::FORMAT_RGBA8, buf);
}

Dictionary FxNativeGen::stats() {
	return fx::stats();
}

void FxNativeGen::reset_stats() {
	fx::reset();
}

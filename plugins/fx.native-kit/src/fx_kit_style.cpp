#include "fx_kit_style.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;
using namespace fx;

void FxKitStyle::_bind_methods() {
	ClassDB::bind_method(D_METHOD("fx_exec", "inputs", "params", "env"), &FxKitStyle::fx_exec);
}

/// 亮度平面：一次算完，后面全部按下标读。
static std::vector<float> luma_plane(const uint8_t *s, int w, int h) {
	std::vector<float> plane(size_t(w) * h);
	size_t n = size_t(w) * h;
	for (size_t k = 0; k < n; k++) {
		size_t i = k * 4;
		plane[k] = float(luma_of(norm_byte(s[i]), norm_byte(s[i + 1]), norm_byte(s[i + 2])));
	}
	return plane;
}

/// Sobel 梯度平面（0~1 量级），边界钳位、不回绕（回绕会在画面边上留一条假边）。
static std::vector<float> gradient_plane(const std::vector<float> &plane, int w, int h) {
	std::vector<float> out(size_t(w) * h);
	for (int y = 0; y < h; y++) {
		int y0 = std::max(y - 1, 0) * w;
		int y1 = y * w;
		int y2 = std::min(y + 1, h - 1) * w;
		for (int x = 0; x < w; x++) {
			int x0 = std::max(x - 1, 0);
			int x2 = std::min(x + 1, w - 1);
			double gx = (double(plane[y0 + x2]) + 2.0 * double(plane[y1 + x2]) + double(plane[y2 + x2])) -
					(double(plane[y0 + x0]) + 2.0 * double(plane[y1 + x0]) + double(plane[y2 + x0]));
			double gy = (double(plane[y2 + x0]) + 2.0 * double(plane[y2 + x]) + double(plane[y2 + x2])) -
					(double(plane[y0 + x0]) + 2.0 * double(plane[y0 + x]) + double(plane[y0 + x2]));
			out[size_t(y1 + x)] = float(std::sqrt(gx * gx + gy * gy) * 0.25);
		}
	}
	return out;
}

// ================= 1. 查找边缘 =================

static Dictionary op_find_edges(const Dictionary &inputs, const Dictionary &p) {
	Ref<Image> src = first_image(inputs);
	if (src.is_null()) {
		return empty_out();
	}
	int w = src->get_width();
	int h = src->get_height();
	double strength = std::clamp(num(p, "strength", 1.0), 0.0, 8.0);
	int mode = 0; // 0=mono 1=color 2=invert
	{
		String name = text(p, "mode", "mono");
		mode = name == String("color") ? 1 : (name == String("invert") ? 2 : 0);
	}
	double amount = std::clamp(num(p, "amount", 1.0), 0.0, 1.0);
	if (amount <= 0.0001) {
		return image_out(src->duplicate());
	}
	PackedByteArray in = src->get_data();
	const uint8_t *s = in.ptr();
	std::vector<float> edges = gradient_plane(luma_plane(s, w, h), w, h);

	PackedByteArray out;
	out.resize(in.size());
	uint8_t *d = out.ptrw();
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			size_t i = (size_t(y) * w + x) * 4;
			double edge = std::clamp(double(edges[size_t(y) * w + x]) * strength, 0.0, 1.0);
			double r = edge;
			double g = edge;
			double b = edge;
			if (mode == 1) {
				r = edge * norm_byte(s[i]);
				g = edge * norm_byte(s[i + 1]);
				b = edge * norm_byte(s[i + 2]);
			} else if (mode == 2) {
				r = 1.0 - edge;
				g = r;
				b = r;
			}
			d[i] = pack_round(norm_byte(s[i]) + (r - norm_byte(s[i])) * amount);
			d[i + 1] = pack_round(norm_byte(s[i + 1]) + (g - norm_byte(s[i + 1])) * amount);
			d[i + 2] = pack_round(norm_byte(s[i + 2]) + (b - norm_byte(s[i + 2])) * amount);
			d[i + 3] = s[i + 3];
		}
	}
	return image_out(make_image(w, h, out));
}

// ================= 2. 浮雕 =================

static Dictionary op_emboss(const Dictionary &inputs, const Dictionary &p) {
	Ref<Image> src = first_image(inputs);
	if (src.is_null()) {
		return empty_out();
	}
	int w = src->get_width();
	int h = src->get_height();
	double angle = Math::deg_to_rad(num(p, "angle", 45.0));
	double strength = std::clamp(num(p, "strength", 1.0), 0.0, 4.0);
	bool keep_color = flag(p, "keep_color", false);
	double amount = std::clamp(num(p, "amount", 1.0), 0.0, 1.0);
	if (amount <= 0.0001) {
		return image_out(src->duplicate());
	}
	int ox = int(std::lround(std::cos(angle)));
	int oy = int(std::lround(std::sin(angle)));
	if (ox == 0 && oy == 0) {
		ox = 1;
	}
	PackedByteArray in = src->get_data();
	const uint8_t *s = in.ptr();
	std::vector<float> plane = luma_plane(s, w, h);

	PackedByteArray out;
	out.resize(in.size());
	uint8_t *d = out.ptrw();
	for (int y = 0; y < h; y++) {
		int front_row = std::clamp(y + oy, 0, h - 1) * w;
		int back_row = std::clamp(y - oy, 0, h - 1) * w;
		for (int x = 0; x < w; x++) {
			size_t i = (size_t(y) * w + x) * 4;
			double front = plane[size_t(front_row + std::clamp(x + ox, 0, w - 1))];
			double back = plane[size_t(back_row + std::clamp(x - ox, 0, w - 1))];
			double value = std::clamp(0.5 + (front - back) * strength * 0.5, 0.0, 1.0);
			double r = value;
			double g = value;
			double b = value;
			if (keep_color) {
				r = std::clamp(norm_byte(s[i]) * value * 2.0, 0.0, 1.0);
				g = std::clamp(norm_byte(s[i + 1]) * value * 2.0, 0.0, 1.0);
				b = std::clamp(norm_byte(s[i + 2]) * value * 2.0, 0.0, 1.0);
			}
			d[i] = pack_round(norm_byte(s[i]) + (r - norm_byte(s[i])) * amount);
			d[i + 1] = pack_round(norm_byte(s[i + 1]) + (g - norm_byte(s[i + 1])) * amount);
			d[i + 2] = pack_round(norm_byte(s[i + 2]) + (b - norm_byte(s[i + 2])) * amount);
			d[i + 3] = s[i + 3];
		}
	}
	return image_out(make_image(w, h, out));
}

// ================= 3. 卡通 =================

static Dictionary op_cartoon(const Dictionary &inputs, const Dictionary &p) {
	Ref<Image> src = first_image(inputs);
	if (src.is_null()) {
		return empty_out();
	}
	int w = src->get_width();
	int h = src->get_height();
	double levels = std::clamp(double(i32(p, "levels", 5)), 2.0, 16.0);
	double edge_strength = std::clamp(num(p, "edge_strength", 0.6), 0.0, 2.0);
	double smooth = std::clamp(num(p, "smooth", 0.25), 0.0, 0.9);
	double amount = std::clamp(num(p, "amount", 1.0), 0.0, 1.0);
	if (amount <= 0.0001) {
		return image_out(src->duplicate());
	}
	PackedByteArray in = src->get_data();
	const uint8_t *s = in.ptr();
	std::vector<float> plane = luma_plane(s, w, h);
	std::vector<float> edges;
	if (edge_strength > 0.0) {
		edges = gradient_plane(plane, w, h);
	}
	double steps = levels - 1.0;

	PackedByteArray out;
	out.resize(in.size());
	uint8_t *d = out.ptrw();
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			size_t i = (size_t(y) * w + x) * 4;
			double l = std::clamp(double(plane[size_t(y) * w + x]), 0.0001, 1.0);
			// 平涂：亮度量化后按比例缩放，色相保持不变。
			double position = l * steps;
			double low = std::floor(position);
			double fraction = position - low;
			fraction = smoothstep(0.5 - smooth * 0.5, 0.5 + smooth * 0.5, fraction);
			double want = (low + fraction) / steps;
			double scale = want / l;
			double r = std::clamp(norm_byte(s[i]) * scale, 0.0, 1.0);
			double g = std::clamp(norm_byte(s[i + 1]) * scale, 0.0, 1.0);
			double b = std::clamp(norm_byte(s[i + 2]) * scale, 0.0, 1.0);
			if (edge_strength > 0.0) {
				double edge = std::clamp(double(edges[size_t(y) * w + x]) * edge_strength, 0.0, 1.0);
				r *= (1.0 - edge);
				g *= (1.0 - edge);
				b *= (1.0 - edge);
			}
			d[i] = pack_round(norm_byte(s[i]) + (r - norm_byte(s[i])) * amount);
			d[i + 1] = pack_round(norm_byte(s[i + 1]) + (g - norm_byte(s[i + 1])) * amount);
			d[i + 2] = pack_round(norm_byte(s[i + 2]) + (b - norm_byte(s[i + 2])) * amount);
			d[i + 3] = s[i + 3];
		}
	}
	return image_out(make_image(w, h, out));
}

// ================= 4. 半调 =================

static Dictionary op_halftone(const Dictionary &inputs, const Dictionary &p) {
	Ref<Image> src = first_image(inputs);
	if (src.is_null()) {
		return empty_out();
	}
	int w = src->get_width();
	int h = src->get_height();
	int cell = std::clamp(i32(p, "cell", 4), 2, 32);
	double angle = Math::deg_to_rad(num(p, "angle", 45.0));
	bool line_mode = text(p, "mode", "dot") == String("line");
	bool invert = flag(p, "invert", false);
	double contrast = std::clamp(num(p, "contrast", 1.4), 0.2, 4.0);
	double amount = std::clamp(num(p, "amount", 1.0), 0.0, 1.0);
	if (amount <= 0.0001) {
		return image_out(src->duplicate());
	}
	PackedByteArray in = src->get_data();
	const uint8_t *s = in.ptr();
	std::vector<float> plane = luma_plane(s, w, h);
	double cos_a = std::cos(angle);
	double sin_a = std::sin(angle);
	double half_cell = double(cell) * 0.5;
	double cell_f = double(cell);

	PackedByteArray out;
	out.resize(in.size());
	uint8_t *d = out.ptrw();
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			size_t i = (size_t(y) * w + x) * 4;
			double l = plane[size_t(y) * w + x];
			if (invert) {
				l = 1.0 - l;
			}
			l = std::clamp((l - 0.5) * contrast + 0.5, 0.0, 1.0);
			// 旋转到网点坐标系，取格内局部坐标。
			double px = double(x) * cos_a + double(y) * sin_a;
			double py = -double(x) * sin_a + double(y) * cos_a;
			double lx = fposmod(px, cell_f) - half_cell;
			double ly = fposmod(py, cell_f) - half_cell;
			double ink = 0.0;
			if (line_mode) {
				ink = std::fabs(ly) <= l * half_cell ? 1.0 : 0.0;
			} else {
				ink = std::sqrt(lx * lx + ly * ly) <= half_cell * std::sqrt(l) ? 1.0 : 0.0;
			}
			double value = 1.0 - ink;
			d[i] = pack_round(norm_byte(s[i]) + (value - norm_byte(s[i])) * amount);
			d[i + 1] = pack_round(norm_byte(s[i + 1]) + (value - norm_byte(s[i + 1])) * amount);
			d[i + 2] = pack_round(norm_byte(s[i + 2]) + (value - norm_byte(s[i + 2])) * amount);
			d[i + 3] = s[i + 3];
		}
	}
	return image_out(make_image(w, h, out));
}

// ================= 5. 胶片颗粒 =================

/// 颗粒是**静态**的：同 seed 每帧一样 → 进得了跨帧缓存，播放不重算。
static Dictionary op_grain(const Dictionary &inputs, const Dictionary &p) {
	Ref<Image> src = first_image(inputs);
	if (src.is_null()) {
		return empty_out();
	}
	int w = src->get_width();
	int h = src->get_height();
	double amount = std::clamp(num(p, "amount", 0.25), 0.0, 1.0);
	int cell = std::clamp(i32(p, "size", 1), 1, 16);
	int seed = i32(p, "seed", 1);
	bool mono = flag(p, "mono", true);
	if (amount <= 0.0001) {
		return image_out(src->duplicate());
	}
	PackedByteArray in = src->get_data();
	const uint8_t *s = in.ptr();
	PackedByteArray out;
	out.resize(in.size());
	uint8_t *d = out.ptrw();
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			size_t i = (size_t(y) * w + x) * 4;
			int gx = x / cell;
			int gy = y / cell;
			double noise = (noise01(gx, gy, seed) - 0.5) * amount;
			double noise_g = mono ? noise : (noise01(gx, gy, seed + 17) - 0.5) * amount;
			double noise_b = mono ? noise : (noise01(gx, gy, seed + 31) - 0.5) * amount;
			d[i] = pack_round(std::clamp(norm_byte(s[i]) + noise, 0.0, 1.0));
			d[i + 1] = pack_round(std::clamp(norm_byte(s[i + 1]) + noise_g, 0.0, 1.0));
			d[i + 2] = pack_round(std::clamp(norm_byte(s[i + 2]) + noise_b, 0.0, 1.0));
			d[i + 3] = s[i + 3];
		}
	}
	return image_out(make_image(w, h, out));
}

Dictionary FxKitStyle::fx_exec(const Dictionary &inputs, const Dictionary &params,
		const Dictionary &env) {
	String op = text(env, "op", "");
	if (op == String("style.find_edges")) {
		return op_find_edges(inputs, params);
	}
	if (op == String("style.emboss")) {
		return op_emboss(inputs, params);
	}
	if (op == String("style.cartoon")) {
		return op_cartoon(inputs, params);
	}
	if (op == String("style.halftone")) {
		return op_halftone(inputs, params);
	}
	if (op == String("style.grain")) {
		return op_grain(inputs, params);
	}
	return empty_out();
}

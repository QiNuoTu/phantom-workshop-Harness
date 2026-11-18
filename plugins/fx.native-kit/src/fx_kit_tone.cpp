#include "fx_kit_tone.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;
using namespace fx;

void FxKitTone::_bind_methods() {
	ClassDB::bind_method(D_METHOD("fx_exec", "inputs", "params", "env"), &FxKitTone::fx_exec);
}

static double quantize(double value, double levels) {
	double steps = std::max(levels - 1.0, 1.0);
	return std::round(std::clamp(value, 0.0, 1.0) * steps) / steps;
}

/// 台阶平滑：在量化台阶之间做一段 S 形过渡（赛璐璐的手绘边），smooth=0 时不动。
static double smooth_step_value(double value, double levels, double smooth) {
	if (smooth <= 0.0001) {
		return value;
	}
	double step = 1.0 / std::max(levels - 1.0, 1.0);
	double base = std::floor(value / step) * step;
	double t = (value - base) / step;
	t = smoothstep(0.5 - smooth * 0.5, 0.5 + smooth * 0.5, t);
	return base + t * step;
}

// ================= 1. 色调分离 Pro =================

/// 按亮度量化会保住色相（赛璐璐上色要的就是这个）；按 RGB 量化才是像素风。
static Dictionary op_posterize_pro(const Dictionary &inputs, const Dictionary &p) {
	Ref<Image> src = first_image(inputs);
	if (src.is_null()) {
		return empty_out();
	}
	int w = src->get_width();
	int h = src->get_height();
	double levels = std::clamp(double(i32(p, "levels", 6)), 2.0, 64.0);
	String mode = text(p, "mode", "luma");
	double smooth = std::clamp(num(p, "smooth", 0.0), 0.0, 0.9);
	double dither = std::clamp(num(p, "dither", 0.0), 0.0, 1.0);
	double amount = std::clamp(num(p, "amount", 1.0), 0.0, 1.0);
	if (amount <= 0.0001) {
		return image_out(src->duplicate());
	}
	bool rgb_mode = mode == String("rgb");

	PackedByteArray in = src->get_data();
	PackedByteArray out;
	out.resize(in.size());
	const uint8_t *s = in.ptr();
	uint8_t *d = out.ptrw();
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			size_t i = (size_t(y) * w + x) * 4;
			Color c(norm_byte(s[i]), norm_byte(s[i + 1]), norm_byte(s[i + 2]), norm_byte(s[i + 3]));
			double bias = 0.0;
			if (dither > 0.0) {
				bias = (noise01(x, y, 11) - 0.5) * dither / std::max(levels - 1.0, 1.0);
			}
			Color target = c;
			if (rgb_mode) {
				target.r = float(quantize(double(c.r) + bias, levels));
				target.g = float(quantize(double(c.g) + bias, levels));
				target.b = float(quantize(double(c.b) + bias, levels));
			} else {
				double l = std::clamp(luma_of(c.r, c.g, c.b) + bias, 0.0001, 1.0);
				double want = smooth_step_value(l, levels, smooth);
				double scale = want / l;
				target.r = float(std::clamp(double(c.r) * scale, 0.0, 1.0));
				target.g = float(std::clamp(double(c.g) * scale, 0.0, 1.0));
				target.b = float(std::clamp(double(c.b) * scale, 0.0, 1.0));
			}
			d[i] = pack_round(double(c.r) + (double(target.r) - double(c.r)) * amount);
			d[i + 1] = pack_round(double(c.g) + (double(target.g) - double(c.g)) * amount);
			d[i + 2] = pack_round(double(c.b) + (double(target.b) - double(c.b)) * amount);
			d[i + 3] = s[i + 3];
		}
	}
	return image_out(make_image(w, h, out));
}

// ================= 2. 调色板量化 =================

/// 亮度每过一档换一个颜色：**硬边不插值**，2 色剪影、4 色海报。
static Dictionary op_palette(const Dictionary &inputs, const Dictionary &p) {
	Ref<Image> src = first_image(inputs);
	if (src.is_null()) {
		return empty_out();
	}
	int w = src->get_width();
	int h = src->get_height();
	int steps = std::clamp(i32(p, "steps", 3), 2, 4);
	Color colors[4] = {
		color(p, "c1", Color(0, 0, 0)),
		color(p, "c2", Color(0.25, 0.37, 0.62)),
		color(p, "c3", Color(0.91, 0.69, 0.42)),
		color(p, "c4", Color(1, 0.96, 0.87)),
	};
	double smooth = std::clamp(num(p, "smooth", 0.0), 0.0, 0.9);
	double amount = std::clamp(num(p, "amount", 1.0), 0.0, 1.0);
	bool invert = flag(p, "invert", false);
	if (amount <= 0.0001) {
		return image_out(src->duplicate());
	}
	double steps_f = double(steps);

	PackedByteArray in = src->get_data();
	PackedByteArray out;
	out.resize(in.size());
	const uint8_t *s = in.ptr();
	uint8_t *d = out.ptrw();
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			size_t i = (size_t(y) * w + x) * 4;
			Color c(norm_byte(s[i]), norm_byte(s[i + 1]), norm_byte(s[i + 2]), norm_byte(s[i + 3]));
			double l = luma_of(c.r, c.g, c.b);
			if (invert) {
				l = 1.0 - l;
			}
			// 亮度 0~1 均分成 steps 段：每段一种颜色。
			// 乘的是 steps 而不是 steps-1 —— 后者会让最亮一档只在 l==1 时出现，
			// 于是"两色黑白"永远只有黑。
			double position = std::clamp(l, 0.0, 0.9999) * steps_f;
			int low = std::clamp(int(std::floor(position)), 0, steps - 1);
			int high = std::clamp(low + 1, 0, steps - 1);
			double fraction = position - double(low);
			Color mapped = colors[low];
			if (smooth > 0.0) {
				double t = smoothstep(0.5 - smooth * 0.5, 0.5 + smooth * 0.5, fraction);
				mapped = colors[low].lerp(colors[high], float(t));
			}
			d[i] = pack_round(double(c.r) + (double(mapped.r) - double(c.r)) * amount);
			d[i + 1] = pack_round(double(c.g) + (double(mapped.g) - double(c.g)) * amount);
			d[i + 2] = pack_round(double(c.b) + (double(mapped.b) - double(c.b)) * amount);
			d[i + 3] = s[i + 3];
		}
	}
	return image_out(make_image(w, h, out));
}

// ================= 3. 专业色阶 =================

static Dictionary op_levels_pro(const Dictionary &inputs, const Dictionary &p) {
	Ref<Image> src = first_image(inputs);
	if (src.is_null()) {
		return empty_out();
	}
	int w = src->get_width();
	int h = src->get_height();
	double in_black = std::clamp(num(p, "in_black", 0.0), 0.0, 0.98);
	double in_white = std::clamp(num(p, "in_white", 1.0), 0.02, 1.0);
	if (in_white <= in_black) {
		in_white = std::min(1.0, in_black + 0.02);
	}
	double gamma = std::clamp(num(p, "gamma", 1.0), 0.1, 10.0);
	double out_black = std::clamp(num(p, "out_black", 0.0), 0.0, 1.0);
	double out_white = std::clamp(num(p, "out_white", 1.0), 0.0, 1.0);
	String channel = text(p, "channel", "rgb");
	double amount = std::clamp(num(p, "amount", 1.0), 0.0, 1.0);
	if (amount <= 0.0001) {
		return image_out(src->duplicate());
	}
	double inv_range = 1.0 / std::max(in_white - in_black, 0.0001);
	double inv_gamma = 1.0 / gamma;
	int only = -1;
	if (channel == String("red")) {
		only = 0;
	} else if (channel == String("green")) {
		only = 1;
	} else if (channel == String("blue")) {
		only = 2;
	}

	PackedByteArray in = src->get_data();
	PackedByteArray out;
	out.resize(in.size());
	const uint8_t *s = in.ptr();
	uint8_t *d = out.ptrw();
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			size_t i = (size_t(y) * w + x) * 4;
			for (int k = 0; k < 3; k++) {
				if (only >= 0 && only != k) {
					d[i + k] = s[i + k];
					continue;
				}
				double before = norm_byte(s[i + k]);
				double v = std::clamp((before - in_black) * inv_range, 0.0, 1.0);
				v = std::pow(v, inv_gamma);
				v = out_black + v * (out_white - out_black);
				d[i + k] = pack_round(before + (v - before) * amount);
			}
			d[i + 3] = s[i + 3];
		}
	}
	return image_out(make_image(w, h, out));
}

// ================= 4. 分离色调 =================

static Dictionary op_split_tone(const Dictionary &inputs, const Dictionary &p) {
	Ref<Image> src = first_image(inputs);
	if (src.is_null()) {
		return empty_out();
	}
	int w = src->get_width();
	int h = src->get_height();
	Color shadow = color(p, "shadow", Color(0.23, 0.29, 0.55));
	Color highlight = color(p, "highlight", Color(1, 0.85, 0.63));
	double balance = std::clamp(num(p, "balance", 0.5), 0.05, 0.95);
	double amount = std::clamp(num(p, "amount", 1.0), 0.0, 1.0);
	if (amount <= 0.0001) {
		return image_out(src->duplicate());
	}

	PackedByteArray in = src->get_data();
	PackedByteArray out;
	out.resize(in.size());
	const uint8_t *s = in.ptr();
	uint8_t *d = out.ptrw();
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			size_t i = (size_t(y) * w + x) * 4;
			Color c(norm_byte(s[i]), norm_byte(s[i + 1]), norm_byte(s[i + 2]), norm_byte(s[i + 3]));
			double l = luma_of(c.r, c.g, c.b);
			Color out_c = c;
			if (l < balance) {
				double weight = (1.0 - l / balance) * amount * 0.9;
				out_c.r = float(double(c.r) + (double(c.r) * double(shadow.r) * 2.0 - double(c.r)) * weight);
				out_c.g = float(double(c.g) + (double(c.g) * double(shadow.g) * 2.0 - double(c.g)) * weight);
				out_c.b = float(double(c.b) + (double(c.b) * double(shadow.b) * 2.0 - double(c.b)) * weight);
			} else {
				double weight = ((l - balance) / std::max(1.0 - balance, 0.001)) * amount * 0.9;
				double tr = 1.0 - (1.0 - double(c.r)) * (1.0 - double(highlight.r));
				double tg = 1.0 - (1.0 - double(c.g)) * (1.0 - double(highlight.g));
				double tb = 1.0 - (1.0 - double(c.b)) * (1.0 - double(highlight.b));
				out_c.r = float(double(c.r) + (tr - double(c.r)) * weight);
				out_c.g = float(double(c.g) + (tg - double(c.g)) * weight);
				out_c.b = float(double(c.b) + (tb - double(c.b)) * weight);
			}
			d[i] = pack_round(out_c.r);
			d[i + 1] = pack_round(out_c.g);
			d[i + 2] = pack_round(out_c.b);
			d[i + 3] = s[i + 3];
		}
	}
	return image_out(make_image(w, h, out));
}

// ================= 5. 色温 / 自然饱和 =================

static Dictionary op_temperature(const Dictionary &inputs, const Dictionary &p) {
	Ref<Image> src = first_image(inputs);
	if (src.is_null()) {
		return empty_out();
	}
	int w = src->get_width();
	int h = src->get_height();
	double temp = std::clamp(num(p, "temperature", 0.0), -100.0, 100.0) / 100.0;
	double tint = std::clamp(num(p, "tint", 0.0), -100.0, 100.0) / 100.0;
	double vibrance = std::clamp(num(p, "vibrance", 0.0), -1.0, 1.0);
	double saturation = std::clamp(num(p, "saturation", 0.0), -1.0, 1.0);
	double amount = std::clamp(num(p, "amount", 1.0), 0.0, 1.0);
	if (amount <= 0.0001) {
		return image_out(src->duplicate());
	}

	PackedByteArray in = src->get_data();
	PackedByteArray out;
	out.resize(in.size());
	const uint8_t *s = in.ptr();
	uint8_t *d = out.ptrw();
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			size_t i = (size_t(y) * w + x) * 4;
			Color c(norm_byte(s[i]), norm_byte(s[i + 1]), norm_byte(s[i + 2]), norm_byte(s[i + 3]));
			Color out_c = c;
			// 色温：暖 = 抬红压蓝；色调：绿 ↔ 品红。
			out_c.r = float(std::clamp(double(c.r) + temp * 0.18 - tint * 0.06, 0.0, 1.0));
			out_c.b = float(std::clamp(double(c.b) - temp * 0.18 - tint * 0.06, 0.0, 1.0));
			out_c.g = float(std::clamp(double(c.g) + tint * 0.12, 0.0, 1.0));
			if (std::fabs(saturation) > 0.0001) {
				double l = luma_of(out_c.r, out_c.g, out_c.b);
				out_c.r = float(std::clamp(l + (double(out_c.r) - l) * (1.0 + saturation), 0.0, 1.0));
				out_c.g = float(std::clamp(l + (double(out_c.g) - l) * (1.0 + saturation), 0.0, 1.0));
				out_c.b = float(std::clamp(l + (double(out_c.b) - l) * (1.0 + saturation), 0.0, 1.0));
			}
			if (std::fabs(vibrance) > 0.0001) {
				float hh, ss, vv;
				rgb_to_hsv(out_c.r, out_c.g, out_c.b, hh, ss, vv);
				// 自然饱和：低饱和度提得多，已经很艳的几乎不动。
				double room = 1.0 - std::clamp(double(ss), 0.0, 1.0);
				double next = std::clamp(double(ss) + room * vibrance, 0.0, 1.0);
				Color shifted = Color::from_hsv(hh, float(next), vv, out_c.a);
				out_c = shifted;
			}
			d[i] = pack_round(double(c.r) + (double(out_c.r) - double(c.r)) * amount);
			d[i + 1] = pack_round(double(c.g) + (double(out_c.g) - double(c.g)) * amount);
			d[i + 2] = pack_round(double(c.b) + (double(out_c.b) - double(c.b)) * amount);
			d[i + 3] = s[i + 3];
		}
	}
	return image_out(make_image(w, h, out));
}

// ================= 6. 曲线（LUT） =================
//
// 控制点由 UI 写成 `[[x, y], …]`（升序、端点固定）。这里按**分段线性**采样成 256 级 LUT：
//   · 采样规则必须与控件 `_sample_at()` 一致，否则"画的和算的不是一条线"；
//   · 区间外取端点值（不外推）：外推会把过曝的高光拉到负数；
//   · 点序不合法（x 不升序）就排序，而不是报错 —— 工程文件可能被手改过。

static std::vector<double> curve_lut(const Dictionary &p) {
	std::vector<double> lut(256);
	std::vector<std::pair<double, double>> points;
	Variant raw = lookup(p, "points");
	if (raw.get_type() == Variant::ARRAY) {
		Array arr = Array(raw);
		for (int i = 0; i < arr.size(); i++) {
			Variant item = arr[i];
			if (item.get_type() != Variant::ARRAY) {
				continue;
			}
			Array pair = Array(item);
			if (pair.size() < 2) {
				continue;
			}
			double x = std::clamp(double(pair[0]), 0.0, 1.0);
			double y = std::clamp(double(pair[1]), 0.0, 1.0);
			points.emplace_back(x, y);
		}
	}
	if (points.size() < 2) {
		for (int i = 0; i < 256; i++) {
			lut[size_t(i)] = double(i) / 255.0;
		}
		return lut;
	}
	std::sort(points.begin(), points.end(),
			[](const std::pair<double, double> &a, const std::pair<double, double> &b) {
				return a.first < b.first;
			});
	for (int i = 0; i < 256; i++) {
		double x = double(i) / 255.0;
		if (x <= points.front().first) {
			lut[size_t(i)] = points.front().second;
			continue;
		}
		if (x >= points.back().first) {
			lut[size_t(i)] = points.back().second;
			continue;
		}
		for (size_t k = 1; k < points.size(); k++) {
			if (x > points[k].first) {
				continue;
			}
			double x0 = points[k - 1].first;
			double x1 = points[k].first;
			double span = std::max(x1 - x0, 0.000001);
			double u = std::clamp((x - x0) / span, 0.0, 1.0);
			lut[size_t(i)] = points[k - 1].second + (points[k].second - points[k - 1].second) * u;
			break;
		}
	}
	return lut;
}

static Dictionary op_curves(const Dictionary &inputs, const Dictionary &p) {
	Ref<Image> src = first_image(inputs);
	if (src.is_null()) {
		return empty_out();
	}
	int w = src->get_width();
	int h = src->get_height();
	std::vector<double> lut = curve_lut(p);
	String channel = text(p, "channel", "rgb");
	double amount = std::clamp(num(p, "amount", 1.0), 0.0, 1.0);
	if (amount <= 0.0001) {
		return image_out(src->duplicate());
	}
	int only = -1; // -1 = 三通道
	if (channel == String("red")) {
		only = 0;
	} else if (channel == String("green")) {
		only = 1;
	} else if (channel == String("blue")) {
		only = 2;
	}

	PackedByteArray in = src->get_data();
	PackedByteArray out;
	out.resize(in.size());
	const uint8_t *s = in.ptr();
	uint8_t *d = out.ptrw();
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			size_t i = (size_t(y) * w + x) * 4;
			for (int k = 0; k < 3; k++) {
				if (only >= 0 && only != k) {
					d[i + k] = s[i + k];
					continue;
				}
				double before = norm_byte(s[i + k]);
				double after = lut[size_t(std::clamp(int(before * 255.0 + 0.5), 0, 255))];
				d[i + k] = pack_round(before + (after - before) * amount);
			}
			d[i + 3] = s[i + 3];
		}
	}
	return image_out(make_image(w, h, out));
}

Dictionary FxKitTone::fx_exec(const Dictionary &inputs, const Dictionary &params,
		const Dictionary &env) {
	String op = text(env, "op", "");
	if (op == String("tone.posterize_pro")) {
		return op_posterize_pro(inputs, params);
	}
	if (op == String("tone.palette")) {
		return op_palette(inputs, params);
	}
	if (op == String("tone.levels_pro")) {
		return op_levels_pro(inputs, params);
	}
	if (op == String("tone.split_tone")) {
		return op_split_tone(inputs, params);
	}
	if (op == String("tone.temperature")) {
		return op_temperature(inputs, params);
	}
	if (op == String("tone.curves")) {
		return op_curves(inputs, params);
	}
	return empty_out();
}

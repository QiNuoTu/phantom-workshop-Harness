#include "fx_kit_mask.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;
using namespace fx;

void FxKitMask::_bind_methods() {
	ClassDB::bind_method(D_METHOD("fx_exec", "inputs", "params", "env"), &FxKitMask::fx_exec);
}

/// 圆角矩形的有符号距离：内部为负、外部为正。羽化就是在这个距离上取一段斜坡。
static double sd_round_box(double px, double py, double half_w, double half_h, double radius) {
	double qx = std::fabs(px) - (half_w - radius);
	double qy = std::fabs(py) - (half_h - radius);
	double outside = std::sqrt(std::max(qx, 0.0) * std::max(qx, 0.0) +
			std::max(qy, 0.0) * std::max(qy, 0.0));
	double inside = std::min(std::max(qx, qy), 0.0);
	return outside + inside - radius;
}

/// 覆盖度：feather = 0 时是硬边（没有过渡带），否则在 ±feather/2 内做平滑过渡。
static double cover(double distance, double feather) {
	if (feather <= 0.0001) {
		return distance <= 0.0 ? 1.0 : 0.0;
	}
	return 1.0 - smoothstep(-feather * 0.5, feather * 0.5, distance);
}

// ================= 1. 矩形蒙版 =================

static Dictionary op_rect(const Dictionary &p, const Dictionary &env) {
	Vector2i canvas = canvas_of(env);
	int w = canvas.x;
	int h = canvas.y;
	Vector2 position = vec2(p, "position", Vector2(0, 0));
	Vector2 box = vec2(p, "size", Vector2(w, h));
	double roundness = std::clamp(num(p, "roundness", 0.0), 0.0, 1.0);
	double feather_px = std::max(num(p, "feather", 0.0), 0.0);
	double expand = num(p, "expand", 0.0);
	bool invert = flag(p, "invert", false);
	double opacity = std::clamp(num(p, "opacity", 1.0), 0.0, 1.0);

	double half_w = std::max(double(box.x), 0.0) * 0.5;
	double half_h = std::max(double(box.y), 0.0) * 0.5;
	double center_x = double(position.x) + half_w;
	double center_y = double(position.y) + half_h;
	double radius = std::min(half_w, half_h) * roundness;

	std::vector<float> matte(size_t(w) * h);
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			double d = sd_round_box(double(x) + 0.5 - center_x, double(y) + 0.5 - center_y,
					half_w, half_h, radius) - expand;
			matte[size_t(y) * w + x] = float(cover(d, feather_px));
		}
	}
	return image_out(matte_image(w, h, matte, opacity, invert));
}

// ================= 2. 椭圆蒙版 =================

static Dictionary op_ellipse(const Dictionary &p, const Dictionary &env) {
	Vector2i canvas = canvas_of(env);
	int w = canvas.x;
	int h = canvas.y;
	Vector2 center = vec2(p, "center", Vector2(w * 0.5, h * 0.5));
	Vector2 radius = vec2(p, "radius", Vector2(w * 0.35, h * 0.35));
	double rotation = Math::deg_to_rad(num(p, "rotation", 0.0));
	double feather_px = std::max(num(p, "feather", 0.0), 0.0);
	double expand = num(p, "expand", 0.0);
	bool invert = flag(p, "invert", false);
	double opacity = std::clamp(num(p, "opacity", 1.0), 0.0, 1.0);

	double rx = std::max(double(radius.x), 1.0) + expand;
	double ry = std::max(double(radius.y), 1.0) + expand;
	double cos_r = std::cos(rotation);
	double sin_r = std::sin(rotation);
	double scale = std::min(rx, ry);

	std::vector<float> matte(size_t(w) * h);
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			double dx = double(x) + 0.5 - double(center.x);
			double dy = double(y) + 0.5 - double(center.y);
			double lx = dx * cos_r + dy * sin_r;
			double ly = -dx * sin_r + dy * cos_r;
			double e = std::sqrt((lx / rx) * (lx / rx) + (ly / ry) * (ly / ry));
			matte[size_t(y) * w + x] = float(cover((e - 1.0) * scale, feather_px));
		}
	}
	return image_out(matte_image(w, h, matte, opacity, invert));
}

// ================= 3. 蒙版布尔 =================

/// 相加 / 相减 / 相交 / 排除。尺寸不同时对齐到 A（美工在 512 画布上做 128 蒙版很常见，
/// 那不该报错）。
static Dictionary op_boolean(const Dictionary &inputs, const Dictionary &p, const Dictionary &env) {
	Ref<Image> a = input_image(inputs, "a");
	Ref<Image> b = input_image(inputs, "b");
	if (a.is_null() && b.is_null()) {
		Vector2i canvas = canvas_of(env);
		return image_out(blank_image(canvas.x, canvas.y));
	}
	int w = 0;
	int h = 0;
	std::vector<float> left;
	if (!a.is_null()) {
		w = a->get_width();
		h = a->get_height();
		left = matte_plane(a);
	} else {
		w = b->get_width();
		h = b->get_height();
		left.assign(size_t(w) * h, 0.0f);
	}
	std::vector<float> right(size_t(w) * h, 0.0f);
	if (!b.is_null()) {
		int bw = b->get_width();
		int bh = b->get_height();
		std::vector<float> raw = matte_plane(b);
		for (int y = 0; y < h; y++) {
			for (int x = 0; x < w; x++) {
				int sx = std::clamp(x * bw / std::max(w, 1), 0, bw - 1);
				int sy = std::clamp(y * bh / std::max(h, 1), 0, bh - 1);
				right[size_t(y) * w + x] = raw[size_t(sy) * bw + sx];
			}
		}
	}
	// 运算模式先转整数：在循环里比较 String 会让每个像素构造一次字符串。
	// 实测把 mask.boolean 从 5.5 ms 拖到 0.4 ms（192×108）。
	int mode = 0; // 0=add 1=subtract 2=intersect 3=exclude
	{
		String name = text(p, "mode", "add");
		mode = name == String("subtract") ? 1 : (name == String("intersect") ? 2
			: (name == String("exclude") ? 3 : 0));
	}
	double opacity = std::clamp(num(p, "opacity", 1.0), 0.0, 1.0);
	bool invert = flag(p, "invert", false);

	std::vector<float> out(size_t(w) * h);
	for (size_t i = 0; i < out.size(); i++) {
		double av = left[i];
		double bv = right[i];
		if (mode == 1) {
			out[i] = float(av * (1.0 - bv));
		} else if (mode == 2) {
			out[i] = float(std::min(av, bv));
		} else if (mode == 3) {
			out[i] = float(std::fabs(av - bv));
		} else {
			out[i] = float(std::clamp(av + bv, 0.0, 1.0));
		}
	}
	return image_out(matte_image(w, h, out, opacity, invert));
}

// ================= 4. 亮度转蒙版 =================

static Dictionary op_from_luma(const Dictionary &inputs, const Dictionary &p) {
	Ref<Image> src = first_image(inputs);
	if (src.is_null()) {
		return empty_out();
	}
	int w = src->get_width();
	int h = src->get_height();
	double black = std::clamp(num(p, "black", 0.15), 0.0, 0.99);
	double white = std::clamp(num(p, "white", 0.85), 0.01, 1.0);
	if (white <= black) {
		white = std::min(1.0, black + 0.02);
	}
	bool invert = flag(p, "invert", false);
	double opacity = std::clamp(num(p, "opacity", 1.0), 0.0, 1.0);
	double inv_range = 1.0 / std::max(white - black, 0.0001);

	PackedByteArray in = src->get_data();
	const uint8_t *s = in.ptr();
	std::vector<float> matte(size_t(w) * h);
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			size_t i = (size_t(y) * w + x) * 4;
			double l = luma_of(norm_byte(s[i]), norm_byte(s[i + 1]), norm_byte(s[i + 2]));
			matte[size_t(y) * w + x] = float(std::clamp((l - black) * inv_range, 0.0, 1.0));
		}
	}
	return image_out(matte_image(w, h, matte, opacity, invert));
}

// ================= 5. 蒙版柔化 =================

/// 羽化 + 扩张/收缩 + 伽马。参数全默认时**逐字节返回原图**。
static Dictionary op_feather(const Dictionary &inputs, const Dictionary &p) {
	Ref<Image> src = first_image(inputs);
	if (src.is_null()) {
		return empty_out();
	}
	int w = src->get_width();
	int h = src->get_height();
	int radius = std::clamp(i32(p, "radius", 0), 0, 64);
	int expand = std::clamp(i32(p, "expand", 0), -32, 32);
	double gamma = std::clamp(num(p, "gamma", 1.0), 0.2, 4.0);
	if (radius == 0 && expand == 0 && std::fabs(gamma - 1.0) < 0.0001) {
		return image_out(src->duplicate());
	}
	std::vector<float> matte = matte_plane(src);
	if (radius > 0) {
		matte = box_blur_sep(matte, w, h, radius);
	}
	if (expand != 0) {
		int distance = std::abs(expand);
		matte = extreme_sep(matte, w, h, distance, expand > 0);
	}
	if (std::fabs(gamma - 1.0) >= 0.0001) {
		double inv = 1.0 / gamma;
		for (size_t i = 0; i < matte.size(); i++) {
			matte[i] = float(std::pow(std::clamp(double(matte[i]), 0.0, 1.0), inv));
		}
	}
	return image_out(matte_image(w, h, matte, 1.0, false));
}

// ================= 6. 暗角蒙版 =================

/// 中心留 (0,0) 表示"自动取画布中心"——尺寸改了不用重摆。
static Dictionary op_vignette(const Dictionary &p, const Dictionary &env) {
	Vector2i canvas = canvas_of(env);
	int w = canvas.x;
	int h = canvas.y;
	Vector2 center = vec2(p, "center", Vector2(0, 0));
	if (center.x == 0.0 && center.y == 0.0) {
		center = Vector2(w * 0.5, h * 0.5);
	}
	double radius = std::clamp(num(p, "radius", 0.75), 0.05, 3.0);
	double softness = std::clamp(num(p, "softness", 0.45), 0.001, 1.0);
	bool invert = flag(p, "invert", false);
	double opacity = std::clamp(num(p, "opacity", 1.0), 0.0, 1.0);
	double falloff = double(std::min(w, h)) * radius * 0.5;
	double inner = falloff * (1.0 - softness);
	double outer = std::max(falloff, inner + 0.001);

	std::vector<float> matte(size_t(w) * h);
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			double dx = double(x) + 0.5 - double(center.x);
			double dy = double(y) + 0.5 - double(center.y);
			double d = std::sqrt(dx * dx + dy * dy);
			matte[size_t(y) * w + x] = float(1.0 - smoothstep(inner, outer, d));
		}
	}
	return image_out(matte_image(w, h, matte, opacity, invert));
}

Dictionary FxKitMask::fx_exec(const Dictionary &inputs, const Dictionary &params,
		const Dictionary &env) {
	String op = text(env, "op", "");
	if (op == String("mask.rect")) {
		return op_rect(params, env);
	}
	if (op == String("mask.ellipse")) {
		return op_ellipse(params, env);
	}
	if (op == String("mask.boolean")) {
		return op_boolean(inputs, params, env);
	}
	if (op == String("mask.from_luma")) {
		return op_from_luma(inputs, params);
	}
	if (op == String("mask.feather")) {
		return op_feather(inputs, params);
	}
	if (op == String("mask.vignette")) {
		return op_vignette(params, env);
	}
	return empty_out();
}

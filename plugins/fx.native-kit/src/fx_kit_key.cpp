#include "fx_kit_key.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;
using namespace fx;

void FxKitKey::_bind_methods() {
	ClassDB::bind_method(D_METHOD("fx_exec", "inputs", "params", "env"), &FxKitKey::fx_exec);
}

// ================= 1. 专业绿幕抠像 =================
//
// 按**色度**距离出 alpha：色相为主、饱和与明度为辅。
// 不用纯 RGB 距离的原因：绿幕素材的亮度分布很宽（阴影接近黑），
// RGB 距离会把阴影判成"不是绿"，人身上于是多出黑洞；
// 色度距离对亮度不敏感，阴影照样是绿、照样被抠掉。

static Dictionary op_chroma_pro(const Dictionary &inputs, const Dictionary &p) {
	Ref<Image> src = first_image(inputs);
	if (src.is_null()) {
		return empty_out();
	}
	int w = src->get_width();
	int h = src->get_height();
	Color screen = color(p, "screen", Color(0, 1, 0));
	double balance = std::clamp(num(p, "balance", 0.0), -1.0, 1.0);
	double black = std::clamp(num(p, "black", 0.18), 0.0, 0.95);
	double white = std::clamp(num(p, "white", 0.62), 0.02, 1.0);
	if (white <= black) {
		white = std::min(1.0, black + 0.02);
	}
	double shrink = std::clamp(num(p, "shrink", 0.0), 0.0, 0.9);
	double soften = std::clamp(num(p, "soften", 0.12), 0.0, 1.0);
	double spill = std::clamp(num(p, "despill", 0.6), 0.0, 1.0);
	double edge = std::clamp(num(p, "edge", 0.0), 0.0, 1.0);
	bool invert = flag(p, "invert", false);
	bool matte_view = text(p, "view", "result") == String("matte");

	int screen_channel = dominant_channel(screen);
	double hue_weight = 1.0 + balance * 0.75;
	double sat_weight = 1.0 - balance * 0.4;
	double inv_range = 1.0 / std::max(white - black, 0.0001);
	double inv_shrink = 1.0 / std::max(1.0 - shrink, 0.0001);
	double screen_h = screen.get_h();
	double screen_s = screen.get_s();
	double screen_v = screen.get_v();

	PackedByteArray in = src->get_data();
	PackedByteArray out;
	out.resize(in.size());
	const uint8_t *s = in.ptr();
	uint8_t *d = out.ptrw();
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			size_t i = (size_t(y) * w + x) * 4;
			Color c(norm_byte(s[i]), norm_byte(s[i + 1]), norm_byte(s[i + 2]), norm_byte(s[i + 3]));
			// 一次 rgb→hsv，不要 get_h/get_s/get_v 各算一次（那是三倍的换算）。
			float ch_r, ch_s, ch_v;
			rgb_to_hsv(c.r, c.g, c.b, ch_r, ch_s, ch_v);
			double dh = std::fabs(fposmod(double(ch_r) - screen_h + 0.5, 1.0) - 0.5) / 0.5;
			double ds = std::fabs(double(ch_s) - screen_s) * sat_weight;
			double dv = std::fabs(double(ch_v) - screen_v) * 0.5;
			double dist = std::sqrt(dh * dh * hue_weight + ds * ds + dv * dv);
			double alpha = std::clamp((dist - black) * inv_range, 0.0, 1.0);
			if (soften > 0.0001) {
				alpha = smoothstep(0.5 - soften * 0.5, 0.5 + soften * 0.5, alpha);
			}
			if (shrink > 0.0) {
				alpha = std::clamp((alpha - shrink) * inv_shrink, 0.0, 1.0);
			}
			if (invert) {
				alpha = 1.0 - alpha;
			}
			if (matte_view) {
				write_matte(d, i, alpha);
				continue;
			}
			Color out_c = c;
			crush(out_c, screen_channel, spill * (1.0 - alpha));
			desat_edge(out_c, edge * (1.0 - alpha));
			d[i] = pack_round(out_c.r);
			d[i + 1] = pack_round(out_c.g);
			d[i + 2] = pack_round(out_c.b);
			d[i + 3] = pack_round(double(c.a) * alpha);
		}
	}
	return image_out(make_image(w, h, out));
}

// ================= 2. 亮度键 =================

static Dictionary op_luma(const Dictionary &inputs, const Dictionary &p) {
	Ref<Image> src = first_image(inputs);
	if (src.is_null()) {
		return empty_out();
	}
	int w = src->get_width();
	int h = src->get_height();
	String channel = text(p, "channel", "luma");
	double black = std::clamp(num(p, "black", 0.3), 0.0, 0.99);
	double white = std::clamp(num(p, "white", 0.6), 0.01, 1.0);
	if (white <= black) {
		white = std::min(1.0, black + 0.02);
	}
	bool invert = flag(p, "invert", false);
	bool matte_view = text(p, "view", "result") == String("matte");
	double inv_range = 1.0 / std::max(white - black, 0.0001);
	int pick = 0; // 0=luma 1=red 2=green 3=blue 4=alpha 5=max
	if (channel == String("red")) {
		pick = 1;
	} else if (channel == String("green")) {
		pick = 2;
	} else if (channel == String("blue")) {
		pick = 3;
	} else if (channel == String("alpha")) {
		pick = 4;
	} else if (channel == String("max")) {
		pick = 5;
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
			double value = luma_of(c.r, c.g, c.b);
			switch (pick) {
				case 1: value = c.r; break;
				case 2: value = c.g; break;
				case 3: value = c.b; break;
				case 4: value = c.a; break;
				case 5: value = std::max(double(c.r), std::max(double(c.g), double(c.b))); break;
				default: break;
			}
			double alpha = std::clamp((value - black) * inv_range, 0.0, 1.0);
			if (invert) {
				alpha = 1.0 - alpha;
			}
			if (matte_view) {
				write_matte(d, i, alpha);
			} else {
				d[i] = s[i];
				d[i + 1] = s[i + 1];
				d[i + 2] = s[i + 2];
				d[i + 3] = pack_round(double(c.a) * alpha);
			}
		}
	}
	return image_out(make_image(w, h, out));
}

// ================= 3. 差值键 =================

static Dictionary op_diff(const Dictionary &inputs, const Dictionary &p) {
	Ref<Image> src = first_image(inputs);
	if (src.is_null()) {
		return empty_out();
	}
	int w = src->get_width();
	int h = src->get_height();
	Ref<Image> bg = input_image(inputs, "background");
	double tolerance = std::clamp(num(p, "tolerance", 0.08), 0.0, 1.0);
	double softness = std::max(num(p, "softness", 0.12), 0.0001);
	double spill = std::clamp(num(p, "despill", 0.5), 0.0, 1.0);
	Vector2 offset = vec2(p, "offset", Vector2(0, 0));
	bool invert = flag(p, "invert", false);
	bool matte_view = text(p, "view", "result") == String("matte");

	int bw = w;
	int bh = h;
	PackedByteArray bbuf;
	if (bg.is_null()) {
		bbuf.resize(w * h * 4);
		bbuf.fill(0);
	} else {
		bw = bg->get_width();
		bh = bg->get_height();
		bbuf = bg->get_data();
	}
	// 背景主色：去溢色时压哪个通道，取背景的平均色即可（背景就是"被抠掉的那些颜色"）。
	double sum[3] = { 0.0, 0.0, 0.0 };
	{
		const uint8_t *b = bbuf.ptr();
		size_t n = size_t(bw) * bh;
		size_t step = std::max<size_t>(1, n / 512);
		size_t count = 0;
		for (size_t k = 0; k < n; k += step) {
			size_t i = k * 4;
			sum[0] += norm_byte(b[i]);
			sum[1] += norm_byte(b[i + 1]);
			sum[2] += norm_byte(b[i + 2]);
			count++;
		}
		if (count > 0) {
			sum[0] /= double(count);
			sum[1] /= double(count);
			sum[2] /= double(count);
		}
	}
	int screen_channel = dominant_channel(Color(sum[0], sum[1], sum[2], 1.0));
	double scale_x = double(bw) / std::max(1, w);
	double scale_y = double(bh) / std::max(1, h);
	double inv_soft = 1.0 / softness;

	PackedByteArray in = src->get_data();
	PackedByteArray out;
	out.resize(in.size());
	const uint8_t *s = in.ptr();
	const uint8_t *b = bbuf.ptr();
	uint8_t *d = out.ptrw();
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			size_t i = (size_t(y) * w + x) * 4;
			Color c(norm_byte(s[i]), norm_byte(s[i + 1]), norm_byte(s[i + 2]), norm_byte(s[i + 3]));
			int tx = std::clamp(int((double(x) + offset.x) * scale_x), 0, bw - 1);
			int ty = std::clamp(int((double(y) + offset.y) * scale_y), 0, bh - 1);
			size_t bi = (size_t(ty) * bw + tx) * 4;
			double dr = std::fabs(double(c.r) - norm_byte(b[bi]));
			double dg = std::fabs(double(c.g) - norm_byte(b[bi + 1]));
			double db = std::fabs(double(c.b) - norm_byte(b[bi + 2]));
			double dist = std::max(dr, std::max(dg, db));
			double alpha = std::clamp((dist - tolerance) * inv_soft, 0.0, 1.0);
			if (invert) {
				alpha = 1.0 - alpha;
			}
			if (matte_view) {
				write_matte(d, i, alpha);
				continue;
			}
			Color out_c = c;
			crush(out_c, screen_channel, spill * (1.0 - alpha));
			d[i] = pack_round(out_c.r);
			d[i + 1] = pack_round(out_c.g);
			d[i + 2] = pack_round(out_c.b);
			d[i + 3] = pack_round(double(c.a) * alpha);
		}
	}
	return image_out(make_image(w, h, out));
}

// ================= 4. 颜色范围 =================

static Dictionary op_color_range(const Dictionary &inputs, const Dictionary &p) {
	Ref<Image> src = first_image(inputs);
	if (src.is_null()) {
		return empty_out();
	}
	int w = src->get_width();
	int h = src->get_height();
	Color target = color(p, "target", Color(0, 1, 0));
	double hue_range = std::clamp(num(p, "hue_range", 0.06), 0.001, 0.5);
	double sat_range = std::clamp(num(p, "sat_range", 0.35), 0.001, 1.0);
	double luma_range = std::clamp(num(p, "luma_range", 0.45), 0.001, 1.0);
	double softness = std::max(num(p, "softness", 0.08), 0.0001);
	double spill = std::clamp(num(p, "despill", 0.5), 0.0, 1.0);
	bool invert = flag(p, "invert", false);
	bool matte_view = text(p, "view", "result") == String("matte");
	int screen_channel = dominant_channel(target);
	double inv_soft = 1.0 / softness;
	double target_h = target.get_h();
	double target_s = target.get_s();
	double target_v = target.get_v();

	PackedByteArray in = src->get_data();
	PackedByteArray out;
	out.resize(in.size());
	const uint8_t *s = in.ptr();
	uint8_t *d = out.ptrw();
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			size_t i = (size_t(y) * w + x) * 4;
			Color c(norm_byte(s[i]), norm_byte(s[i + 1]), norm_byte(s[i + 2]), norm_byte(s[i + 3]));
			float ch_r, ch_s, ch_v;
			rgb_to_hsv(c.r, c.g, c.b, ch_r, ch_s, ch_v);
			double dh = std::fabs(fposmod(double(ch_r) - target_h + 0.5, 1.0) - 0.5) / hue_range;
			double ds = std::fabs(double(ch_s) - target_s) / sat_range;
			double dv = std::fabs(double(ch_v) - target_v) / luma_range;
			double score = std::max(dh, std::max(ds, dv));
			double alpha = std::clamp((score - 1.0) * inv_soft, 0.0, 1.0);
			if (invert) {
				alpha = 1.0 - alpha;
			}
			if (matte_view) {
				write_matte(d, i, alpha);
				continue;
			}
			Color out_c = c;
			crush(out_c, screen_channel, spill * (1.0 - alpha));
			d[i] = pack_round(out_c.r);
			d[i + 1] = pack_round(out_c.g);
			d[i + 2] = pack_round(out_c.b);
			d[i + 3] = pack_round(double(c.a) * alpha);
		}
	}
	return image_out(make_image(w, h, out));
}

// ================= 5. 蒙版清理 =================

static Dictionary op_matte_clean(const Dictionary &inputs, const Dictionary &p) {
	Ref<Image> src = first_image(inputs);
	if (src.is_null()) {
		return empty_out();
	}
	int w = src->get_width();
	int h = src->get_height();
	int shrink = std::clamp(i32(p, "shrink", 0), -32, 32);
	int feather_px = std::clamp(i32(p, "feather", 0), 0, 64);
	double denoise = std::clamp(num(p, "denoise", 0.0), 0.0, 1.0);
	bool fill = flag(p, "fill_holes", false);
	bool invert = flag(p, "invert", false);
	bool matte_view = text(p, "view", "matte") != String("result");

	std::vector<float> matte = matte_plane(src);
	if (shrink > 0) {
		matte = extreme_sep(matte, w, h, shrink, true);
	} else if (shrink < 0) {
		matte = extreme_sep(matte, w, h, -shrink, false);
	}
	if (fill) {
		// 闭运算：先扩张再收缩，填掉 1~2 像素的针孔，不改外轮廓。
		matte = extreme_sep(extreme_sep(matte, w, h, 1, false), w, h, 1, true);
	}
	if (feather_px > 0) {
		matte = box_blur_sep(matte, w, h, feather_px);
	}
	if (denoise > 0.0) {
		double lo = 0.5 - denoise * 0.5;
		double hi = 0.5 + denoise * 0.5;
		for (size_t i = 0; i < matte.size(); i++) {
			matte[i] = float(smoothstep(lo, hi, matte[i]));
		}
	}

	PackedByteArray in = src->get_data();
	PackedByteArray out;
	out.resize(in.size());
	const uint8_t *s = in.ptr();
	uint8_t *d = out.ptrw();
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			size_t i = (size_t(y) * w + x) * 4;
			double alpha = matte[size_t(y) * w + x];
			if (invert) {
				alpha = 1.0 - alpha;
			}
			if (matte_view) {
				write_matte(d, i, alpha);
			} else {
				d[i] = s[i];
				d[i + 1] = s[i + 1];
				d[i + 2] = s[i + 2];
				d[i + 3] = clamp_byte(alpha * 255.0 + 0.5);
			}
		}
	}
	return image_out(make_image(w, h, out));
}

// ================= 6. 去溢色 =================

static Dictionary op_despill(const Dictionary &inputs, const Dictionary &p) {
	Ref<Image> src = first_image(inputs);
	if (src.is_null()) {
		return empty_out();
	}
	int w = src->get_width();
	int h = src->get_height();
	double strength = std::clamp(num(p, "strength", 0.8), 0.0, 1.0);
	String mode = text(p, "mode", "auto");
	bool preserve = flag(p, "preserve_luma", false);
	bool alpha_only = flag(p, "alpha_only", false);

	PackedByteArray in = src->get_data();
	const uint8_t *s = in.ptr();
	int channel = 1;
	if (mode == String("green")) {
		channel = 1;
	} else if (mode == String("blue")) {
		channel = 2;
	} else if (mode == String("red")) {
		channel = 0;
	} else if (mode == String("magenta")) {
		channel = 3;
	} else {
		double sum[3] = { 0.0, 0.0, 0.0 };
		size_t n = size_t(w) * h;
		size_t step = std::max<size_t>(1, n / 512);
		size_t count = 0;
		for (size_t k = 0; k < n; k += step) {
			size_t i = k * 4;
			sum[0] += norm_byte(s[i]);
			sum[1] += norm_byte(s[i + 1]);
			sum[2] += norm_byte(s[i + 2]);
			count++;
		}
		channel = dominant_channel(Color(sum[0] / double(std::max<size_t>(count, 1)),
				sum[1] / double(std::max<size_t>(count, 1)),
				sum[2] / double(std::max<size_t>(count, 1)), 1.0));
	}

	PackedByteArray out;
	out.resize(in.size());
	uint8_t *d = out.ptrw();
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			size_t i = (size_t(y) * w + x) * 4;
			Color c(norm_byte(s[i]), norm_byte(s[i + 1]), norm_byte(s[i + 2]), norm_byte(s[i + 3]));
			if (alpha_only && c.a >= 0.999) {
				d[i] = s[i];
				d[i + 1] = s[i + 1];
				d[i + 2] = s[i + 2];
				d[i + 3] = s[i + 3];
				continue;
			}
			Color out_c = c;
			if (channel == 3) {
				// 品红溢色：红与蓝同时高于绿。
				double excess = std::min(std::max(0.0, double(c.r) - double(c.g)),
						std::max(0.0, double(c.b) - double(c.g)));
				out_c.r = float(double(c.r) - excess * strength);
				out_c.b = float(double(c.b) - excess * strength);
			} else {
				crush(out_c, channel, strength);
			}
			if (preserve) {
				// 去溢色会压掉一点亮度：把差额补回三个通道，明暗结构不变。
				double delta = luma_of(c.r, c.g, c.b) - luma_of(out_c.r, out_c.g, out_c.b);
				out_c.r = float(std::clamp(double(out_c.r) + delta, 0.0, 1.0));
				out_c.g = float(std::clamp(double(out_c.g) + delta, 0.0, 1.0));
				out_c.b = float(std::clamp(double(out_c.b) + delta, 0.0, 1.0));
			}
			d[i] = pack_round(out_c.r);
			d[i + 1] = pack_round(out_c.g);
			d[i + 2] = pack_round(out_c.b);
			d[i + 3] = s[i + 3];
		}
	}
	return image_out(make_image(w, h, out));
}

// ================= 分派 =================

Dictionary FxKitKey::fx_exec(const Dictionary &inputs, const Dictionary &params,
		const Dictionary &env) {
	String op = text(env, "op", "");
	if (op == String("key.chroma_pro")) {
		return op_chroma_pro(inputs, params);
	}
	if (op == String("key.luma")) {
		return op_luma(inputs, params);
	}
	if (op == String("key.diff")) {
		return op_diff(inputs, params);
	}
	if (op == String("key.color_range")) {
		return op_color_range(inputs, params);
	}
	if (op == String("key.matte_clean")) {
		return op_matte_clean(inputs, params);
	}
	if (op == String("key.despill")) {
		return op_despill(inputs, params);
	}
	return empty_out();
}

#include "fx_kit_channel.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;
using namespace fx;

void FxKitChannel::_bind_methods() {
	ClassDB::bind_method(D_METHOD("fx_exec", "inputs", "params", "env"), &FxKitChannel::fx_exec);
}

/// 通道名两种写法都收：工程里可能写着 "green"，节点下拉给的是 "g"。
static int channel_letter(const String &value) {
	if (value == String("r") || value == String("red")) {
		return 0;
	}
	if (value == String("g") || value == String("green")) {
		return 1;
	}
	if (value == String("b") || value == String("blue")) {
		return 2;
	}
	if (value == String("a") || value == String("alpha")) {
		return 3;
	}
	return -1;
}

// ================= 1. 分离通道 =================

/// 输出**灰度图**（R=G=B=取到的值，A=255）：接任何下游都直观。
static Dictionary op_extract(const Dictionary &inputs, const Dictionary &p) {
	Ref<Image> src = first_image(inputs);
	if (src.is_null()) {
		return empty_out();
	}
	int w = src->get_width();
	int h = src->get_height();
	int mode = pick_mode(text(p, "channel", "luma"));
	bool invert = flag(p, "invert", false);
	double amount = std::clamp(num(p, "amount", 1.0), 0.0, 1.0);

	PackedByteArray in = src->get_data();
	PackedByteArray out;
	out.resize(in.size());
	const uint8_t *s = in.ptr();
	uint8_t *d = out.ptrw();
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			size_t i = (size_t(y) * w + x) * 4;
			Color c(norm_byte(s[i]), norm_byte(s[i + 1]), norm_byte(s[i + 2]), norm_byte(s[i + 3]));
			double v = pick_value(c, mode);
			if (invert) {
				v = 1.0 - v;
			}
			v *= amount;
			uint8_t byte = pack_round(v);
			d[i] = byte;
			d[i + 1] = byte;
			d[i + 2] = byte;
			d[i + 3] = 255;
		}
	}
	return image_out(make_image(w, h, out));
}

// ================= 2. 合并通道 =================

/// 四张图 → 一张彩色图。不接的通道按「0 / alpha=1」处理，只接三根线也能出图。
static Dictionary op_combine(const Dictionary &inputs, const Dictionary &p, const Dictionary &env) {
	int mode = pick_mode(text(p, "mode", "red"));
	const char *keys[4] = { "r", "g", "b", "a" };
	Ref<Image> parts[4];
	PackedByteArray buffers[4];
	const uint8_t *ptr[4] = { nullptr, nullptr, nullptr, nullptr };
	int widths[4] = { 0, 0, 0, 0 };
	int heights[4] = { 0, 0, 0, 0 };
	int w = 0;
	int h = 0;
	for (int k = 0; k < 4; k++) {
		parts[k] = input_image(inputs, keys[k]);
		if (parts[k].is_null()) {
			continue;
		}
		widths[k] = parts[k]->get_width();
		heights[k] = parts[k]->get_height();
		buffers[k] = parts[k]->get_data();
		ptr[k] = buffers[k].ptr();
		if (w == 0) {
			w = widths[k];
			h = heights[k];
		}
	}
	if (w == 0) {
		Vector2i canvas = canvas_of(env);
		w = canvas.x;
		h = canvas.y;
	}

	PackedByteArray out;
	out.resize(w * h * 4);
	uint8_t *d = out.ptrw();
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			size_t i = (size_t(y) * w + x) * 4;
			double values[4] = { 0.0, 0.0, 0.0, 1.0 };
			for (int k = 0; k < 4; k++) {
				if (ptr[k] == nullptr) {
					continue;
				}
				int sx = std::clamp(x * widths[k] / std::max(w, 1), 0, widths[k] - 1);
				int sy = std::clamp(y * heights[k] / std::max(h, 1), 0, heights[k] - 1);
				size_t si = (size_t(sy) * widths[k] + sx) * 4;
				Color c(norm_byte(ptr[k][si]), norm_byte(ptr[k][si + 1]),
						norm_byte(ptr[k][si + 2]), norm_byte(ptr[k][si + 3]));
				values[k] = pick_value(c, mode);
			}
			d[i] = pack_round(values[0]);
			d[i + 1] = pack_round(values[1]);
			d[i + 2] = pack_round(values[2]);
			d[i + 3] = pack_round(values[3]);
		}
	}
	return image_out(make_image(w, h, out));
}

// ================= 3. 通道混合器 =================

static Dictionary op_mixer(const Dictionary &inputs, const Dictionary &p) {
	Ref<Image> src = first_image(inputs);
	if (src.is_null()) {
		return empty_out();
	}
	int w = src->get_width();
	int h = src->get_height();
	double rr = num(p, "rr", 1.0);
	double rg = num(p, "rg", 0.0);
	double rb = num(p, "rb", 0.0);
	double gr = num(p, "gr", 0.0);
	double gg = num(p, "gg", 1.0);
	double gb = num(p, "gb", 0.0);
	double br = num(p, "br", 0.0);
	double bg = num(p, "bg", 0.0);
	double bb = num(p, "bb", 1.0);
	bool mono = flag(p, "mono", false);
	double amount = std::clamp(num(p, "amount", 1.0), 0.0, 1.0);

	PackedByteArray in = src->get_data();
	PackedByteArray out;
	out.resize(in.size());
	const uint8_t *s = in.ptr();
	uint8_t *d = out.ptrw();
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			size_t i = (size_t(y) * w + x) * 4;
			Color c(norm_byte(s[i]), norm_byte(s[i + 1]), norm_byte(s[i + 2]), norm_byte(s[i + 3]));
			double r = double(c.r) * rr + double(c.g) * rg + double(c.b) * rb;
			double g = double(c.r) * gr + double(c.g) * gg + double(c.b) * gb;
			double b = double(c.r) * br + double(c.g) * bg + double(c.b) * bb;
			if (mono) {
				double l = luma_of(r, g, b);
				r = l;
				g = l;
				b = l;
			}
			r = std::clamp(r, 0.0, 1.0);
			g = std::clamp(g, 0.0, 1.0);
			b = std::clamp(b, 0.0, 1.0);
			d[i] = pack_round(double(c.r) + (r - double(c.r)) * amount);
			d[i + 1] = pack_round(double(c.g) + (g - double(c.g)) * amount);
			d[i + 2] = pack_round(double(c.b) + (b - double(c.b)) * amount);
			d[i + 3] = s[i + 3];
		}
	}
	return image_out(make_image(w, h, out));
}

// ================= 4. 设置透明度 =================

static Dictionary op_set_alpha(const Dictionary &inputs, const Dictionary &p, const Dictionary &env) {
	Ref<Image> src = first_image(inputs);
	if (src.is_null()) {
		return empty_out();
	}
	int w = src->get_width();
	int h = src->get_height();
	Ref<Image> mask = input_image(inputs, "source");
	if (mask.is_null()) {
		mask = src;
	}
	int mw = mask->get_width();
	int mh = mask->get_height();
	int mode_channel = pick_mode(text(p, "channel", "alpha"));
	bool invert = flag(p, "invert", false);
	double amount = std::clamp(num(p, "amount", 1.0), 0.0, 1.0);
	int blend = 0; // 0=replace 1=multiply 2=add
	{
		String name = text(p, "mode", "replace");
		blend = name == String("multiply") ? 1 : (name == String("add") ? 2 : 0);
	}

	PackedByteArray in = src->get_data();
	PackedByteArray mbuf = mask->get_data();
	PackedByteArray out;
	out.resize(in.size());
	const uint8_t *s = in.ptr();
	const uint8_t *m = mbuf.ptr();
	uint8_t *d = out.ptrw();
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			size_t i = (size_t(y) * w + x) * 4;
			int mx = std::clamp(x * mw / std::max(w, 1), 0, mw - 1);
			int my = std::clamp(y * mh / std::max(h, 1), 0, mh - 1);
			size_t mi = (size_t(my) * mw + mx) * 4;
			Color mc(norm_byte(m[mi]), norm_byte(m[mi + 1]), norm_byte(m[mi + 2]),
					norm_byte(m[mi + 3]));
			double value = pick_value(mc, mode_channel);
			if (invert) {
				value = 1.0 - value;
			}
			double own = norm_byte(s[i + 3]);
			double result = value;
			if (blend == 1) {
				result = own * value;
			} else if (blend == 2) {
				result = std::clamp(own + value, 0.0, 1.0);
			}
			result = own + (result - own) * amount;
			d[i] = s[i];
			d[i + 1] = s[i + 1];
			d[i + 2] = s[i + 2];
			d[i + 3] = pack_round(result);
		}
	}
	return image_out(make_image(w, h, out));
}

// ================= 5. 通道错位 =================

/// 红往 +offset、蓝往 -offset：方向对称，画面中心不偏。
/// `amount = 0` 时**原图返回**（连字节都不碰）——「关掉」必须真的关掉。
static Dictionary op_shift(const Dictionary &inputs, const Dictionary &p) {
	Ref<Image> src = first_image(inputs);
	if (src.is_null()) {
		return empty_out();
	}
	int w = src->get_width();
	int h = src->get_height();
	Vector2 offset = vec2(p, "offset", Vector2(2, 0));
	double amount = std::clamp(num(p, "amount", 1.0), 0.0, 1.0);
	if (amount <= 0.0001 || (offset.x == 0.0 && offset.y == 0.0)) {
		return image_out(src->duplicate());
	}
	int dx = int(std::lround(offset.x * amount));
	int dy = int(std::lround(offset.y * amount));

	PackedByteArray in = src->get_data();
	PackedByteArray out = in.duplicate();
	const uint8_t *s = in.ptr();
	uint8_t *d = out.ptrw();
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			size_t i = (size_t(y) * w + x) * 4;
			int rx = x - dx;
			int ry = y - dy;
			int bx = x + dx;
			int by = y + dy;
			if (rx >= 0 && ry >= 0 && rx < w && ry < h) {
				d[i] = s[(size_t(ry) * w + rx) * 4];
			}
			if (bx >= 0 && by >= 0 && bx < w && by < h) {
				d[i + 2] = s[(size_t(by) * w + bx) * 4 + 2];
			}
		}
	}
	return image_out(make_image(w, h, out));
}

// ================= 6. 通道交换 =================

static Dictionary op_swap(const Dictionary &inputs, const Dictionary &p) {
	Ref<Image> src = first_image(inputs);
	if (src.is_null()) {
		return empty_out();
	}
	int w = src->get_width();
	int h = src->get_height();
	const char *keys[4] = { "r_from", "g_from", "b_from", "a_from" };
	const char *defaults[4] = { "r", "g", "b", "a" };
	int pick[4];
	for (int k = 0; k < 4; k++) {
		pick[k] = channel_letter(text(p, keys[k], defaults[k]));
	}

	PackedByteArray in = src->get_data();
	PackedByteArray out;
	out.resize(in.size());
	const uint8_t *s = in.ptr();
	uint8_t *d = out.ptrw();
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			size_t i = (size_t(y) * w + x) * 4;
			for (int k = 0; k < 4; k++) {
				d[i + k] = pick[k] < 0 ? 0 : s[i + pick[k]];
			}
		}
	}
	return image_out(make_image(w, h, out));
}

Dictionary FxKitChannel::fx_exec(const Dictionary &inputs, const Dictionary &params,
		const Dictionary &env) {
	String op = text(env, "op", "");
	if (op == String("channel.extract")) {
		return op_extract(inputs, params);
	}
	if (op == String("channel.combine")) {
		return op_combine(inputs, params, env);
	}
	if (op == String("channel.mixer")) {
		return op_mixer(inputs, params);
	}
	if (op == String("channel.set_alpha")) {
		return op_set_alpha(inputs, params, env);
	}
	if (op == String("channel.shift")) {
		return op_shift(inputs, params);
	}
	if (op == String("channel.swap")) {
		return op_swap(inputs, params);
	}
	return empty_out();
}

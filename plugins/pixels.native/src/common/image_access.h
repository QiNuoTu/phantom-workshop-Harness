#ifndef FX_NATIVE_IMAGE_ACCESS_H
#define FX_NATIVE_IMAGE_ACCESS_H
// 进出 Image 的三个动作：转 RGBA8、建图、双线性采样。
//
// `as_rgba` 只在格式不对时复制；已经是 RGBA8 时直接返回同一个 Ref，
// 所以「上游刚算完的原生图」不会被抄一遍 —— 这条是热路径上省下来的最大一笔。

#include "common/pixel_math.h"
#include "common/prelude.h"

namespace fx {

inline Ref<Image> as_rgba(const Ref<Image> &img) {
	if (img.is_null() || img->get_width() == 0 || img->get_height() == 0) {
		return Ref<Image>();
	}
	if (img->get_format() == Image::FORMAT_RGBA8 && !img->is_compressed()) {
		return img;
	}
	Ref<Image> copy;
	copy.instantiate();
	copy->copy_from(img);
	if (copy->is_compressed()) {
		copy->decompress();
	}
	copy->convert(Image::FORMAT_RGBA8);
	return copy;
}

inline Ref<Image> make_image(int w, int h, const PackedByteArray &data) {
	return Image::create_from_data(w, h, false, Image::FORMAT_RGBA8, data);
}

/// 空 RGBA8 画布（全 0）。生成器要往里写，不能借用 Image::create_empty 的未初始化内存。
inline Ref<Image> blank_image(int w, int h) {
	PackedByteArray data;
	data.resize(w * h * 4);
	data.fill(0);
	return Image::create_from_data(w, h, false, Image::FORMAT_RGBA8, data);
}

/// 双线性采样一个像素（与 FxPixelKit.sample_rows 逐字一致，权重用 double）。
inline void sample_bilinear(const uint8_t *src, int w, int h, double px, double py, uint8_t *out) {
	int x0 = int(std::floor(px));
	int y0 = int(std::floor(py));
	x0 = std::clamp(x0, 0, w - 1);
	y0 = std::clamp(y0, 0, h - 1);
	int x1 = std::min(x0 + 1, w - 1);
	int y1 = std::min(y0 + 1, h - 1);
	double fx = std::clamp(px - double(x0), 0.0, 1.0);
	double fy = std::clamp(py - double(y0), 0.0, 1.0);
	const uint8_t *i00 = src + (size_t(y0) * w + x0) * 4;
	const uint8_t *i10 = src + (size_t(y0) * w + x1) * 4;
	const uint8_t *i01 = src + (size_t(y1) * w + x0) * 4;
	const uint8_t *i11 = src + (size_t(y1) * w + x1) * 4;
	double w00 = (1.0 - fx) * (1.0 - fy);
	double w10 = fx * (1.0 - fy);
	double w01 = (1.0 - fx) * fy;
	double w11 = fx * fy;
	for (int c = 0; c < 4; c++) {
		double v = double(i00[c]) * w00 + double(i10[c]) * w10 + double(i01[c]) * w01 +
				double(i11[c]) * w11 + 0.5;
		out[c] = clamp_byte(v);
	}
}

} // namespace fx

#endif // FX_NATIVE_IMAGE_ACCESS_H

#ifndef FX_NATIVE_POINT_OPS_H
#define FX_NATIVE_POINT_OPS_H
// hue、tint、bright、levels、threshold_map、ramp_three、invert、chromatic、alpha_tint、recolor
//
// 这一族是**一个组件**：注册成独立的类，由插件 `pixels.native` 在激活时把它
// 交给 `FxNativeBridge`，停用时撤回绑定。所以「删掉这一族」不需要动别的族，
// 也不需要动任何 GDScript —— 桥查不到就回落脚本实现。

#include "common/prelude.h"

namespace godot {

class FxNativePoint : public RefCounted {
	GDCLASS(FxNativePoint, RefCounted)

protected:
	static void _bind_methods();

public:
	Ref<Image> hue(const Ref<Image> &p_src, double p_shift, double p_sat, double p_val,
			int p_threads = 1);

	Ref<Image> tint(const Ref<Image> &p_src, const Color &p_color, double p_amount,
			bool p_preserve_luma, int p_threads = 1);

	Ref<Image> bright(const Ref<Image> &p_src, double p_threshold, int p_threads = 1);

	// ---- 点运算（查表族）----
	Ref<Image> levels(const Ref<Image> &p_src, double p_brightness, double p_contrast,
			double p_gamma, int p_threads = 1);

	Ref<Image> threshold_map(const Ref<Image> &p_src, double p_cutoff, double p_softness,
			bool p_use_luma, const Color &p_color, int p_threads = 1);

	Ref<Image> ramp_three(const Ref<Image> &p_src, const Color &p_shadow, const Color &p_mid,
			const Color &p_high, double p_midpoint, double p_amount, int p_threads = 1);

	Ref<Image> invert(const Ref<Image> &p_src, int p_threads = 1);

	/// RGB 三通道横向错切（色差 / 色散）。
	Ref<Image> chromatic(const Ref<Image> &p_src, int p_offset, int p_threads = 1);

	/// 只保留 alpha、RGB 换成常量色（阴影层用）。opacity 乘在 alpha 上。
	Ref<Image> alpha_tint(const Ref<Image> &p_src, const Color &p_color, double p_opacity,
			int p_threads = 1);

	/// 调色板重映射 + 染色 + 透明度（pixelfx 序列帧用）。
	/// 调色板按亮度取整索引，所以是「N 色 LUT」而不是连续渐变。
	Ref<Image> recolor(const Ref<Image> &p_src, const PackedColorArray &p_palette,
			double p_palette_amount, const Color &p_tint, double p_tint_amount, double p_alpha,
			int p_threads = 1);

	Dictionary stats();
	void reset_stats();
};

} // namespace godot

#endif // FX_NATIVE_POINT_OPS_H

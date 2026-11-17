#ifndef FX_NATIVE_GEN_OPS_H
#define FX_NATIVE_GEN_OPS_H
// gradient_fill、radial_spokes、radial_ring、shape_field、noise_field
//
// 这一族是**一个组件**：注册成独立的类，由插件 `pixels.native` 在激活时把它
// 交给 `FxNativeBridge`，停用时撤回绑定。所以「删掉这一族」不需要动别的族，
// 也不需要动任何 GDScript —— 桥查不到就回落脚本实现。

#include "common/prelude.h"

namespace godot {

class FxNativeGen : public RefCounted {
	GDCLASS(FxNativeGen, RefCounted)

protected:
	static void _bind_methods();

public:
	// ---- 程序化生成 ----
	Ref<Image> gradient_fill(const Vector2i &p_size, int p_mode, const Color &p_a,
			const Color &p_b, double p_angle_deg, const Vector2 &p_center, double p_scale,
			double p_softness, int p_threads = 1);

	Ref<Image> radial_spokes(const Vector2i &p_size, int p_count, double p_spin,
			double p_width, double p_length, double p_intensity, const Vector2 &p_center,
			const Color &p_color, int p_threads = 1);

	Ref<Image> radial_ring(const Vector2i &p_size, double p_phase, double p_max_radius,
			double p_width, double p_intensity, const Vector2 &p_center,
			const Color &p_ring_color, const Color &p_core_color, int p_threads = 1);

	Ref<Image> shape_field(const Vector2i &p_size, int p_kind, const Color &p_fill,
			const Color &p_bg, double p_radius, double p_feather, int p_sides,
			const Vector2 &p_center, double p_rotation_deg, double p_aspect,
			int p_threads = 1);

	/// 块状噪声：每 cell×cell 一格，按哈希在两种颜色间二选一。
	Ref<Image> noise_field(const Vector2i &p_size, int p_cell, double p_density,
			const Color &p_a, const Color &p_b, int64_t p_seed, int p_threads = 1);

	Dictionary stats();
	void reset_stats();
};

} // namespace godot

#endif // FX_NATIVE_GEN_OPS_H

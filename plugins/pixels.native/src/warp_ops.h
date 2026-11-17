#ifndef FX_NATIVE_WARP_OPS_H
#define FX_NATIVE_WARP_OPS_H
// wave、remap、affine
//
// 这一族是**一个组件**：注册成独立的类，由插件 `pixels.native` 在激活时把它
// 交给 `FxNativeBridge`，停用时撤回绑定。所以「删掉这一族」不需要动别的族，
// 也不需要动任何 GDScript —— 桥查不到就回落脚本实现。

#include "common/prelude.h"

namespace godot {

class FxNativeWarp : public RefCounted {
	GDCLASS(FxNativeWarp, RefCounted)

protected:
	static void _bind_methods();

public:
	Ref<Image> wave(const Ref<Image> &p_src, double p_amplitude, double p_omega,
			double p_phase, int p_axis_mode, int p_threads = 1);

	Ref<Image> remap(const Ref<Image> &p_src, const PackedFloat32Array &p_coords,
			int p_threads = 1);

	Ref<Image> affine(const Ref<Image> &p_src, const Vector2 &p_offset, const Vector2 &p_scale,
			double p_rotation_deg, const Vector2 &p_anchor, int p_wrap_mode, int p_threads = 1);

	Dictionary stats();
	void reset_stats();
};

} // namespace godot

#endif // FX_NATIVE_WARP_OPS_H

#ifndef FX_NATIVE_BLEND_OPS_H
#define FX_NATIVE_BLEND_OPS_H
// bloom_add、mask_image、blend、composite_add、paint_blobs
//
// 这一族是**一个组件**：注册成独立的类，由插件 `pixels.native` 在激活时把它
// 交给 `FxNativeBridge`，停用时撤回绑定。所以「删掉这一族」不需要动别的族，
// 也不需要动任何 GDScript —— 桥查不到就回落脚本实现。

#include "common/prelude.h"

namespace godot {

class FxNativeBlend : public RefCounted {
	GDCLASS(FxNativeBlend, RefCounted)

protected:
	static void _bind_methods();

public:
	Ref<Image> bloom_add(const Ref<Image> &p_base, const Ref<Image> &p_glow, double p_amount,
			int p_threads = 1);

	Ref<Image> mask_image(const Ref<Image> &p_src, const Ref<Image> &p_mask, int p_channel,
			bool p_invert, double p_softness, double p_opacity, int p_threads = 1);

	void blend(const Ref<Image> &p_base, const Ref<Image> &p_top, const Rect2i &p_rect,
			const Vector2i &p_at, int p_mode, double p_opacity, int p_threads = 1);

	/// 「颜色缓冲 + 加性光缓冲」合成成一张图。color 是 RGBA8 字节，light 是 RGB 的 int32
	/// （加性光会叠到 255 以上，字节存不下）。VfxEngine 用它收尾。
	Ref<Image> composite_add(const PackedByteArray &p_color, const PackedInt32Array &p_light,
			const Vector2i &p_size, double p_light_k, int p_threads = 1);

	/// 稀疏光点叠加。`p_data` 每 9 个 float 一个光点：
	/// x, y, radius, strength, core, r, g, b, a。**串行**执行：
	/// 重叠光点要按顺序累积，切开就会算错。
	Ref<Image> paint_blobs(const Vector2i &p_size, const Color &p_background,
			const PackedFloat32Array &p_data);

	Dictionary stats();
	void reset_stats();
};

} // namespace godot

#endif // FX_NATIVE_BLEND_OPS_H

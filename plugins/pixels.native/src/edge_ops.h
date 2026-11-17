#ifndef FX_NATIVE_EDGE_OPS_H
#define FX_NATIVE_EDGE_OPS_H
// outline_alpha、box_blur
//
// 这一族是**一个组件**：注册成独立的类，由插件 `pixels.native` 在激活时把它
// 交给 `FxNativeBridge`，停用时撤回绑定。所以「删掉这一族」不需要动别的族，
// 也不需要动任何 GDScript —— 桥查不到就回落脚本实现。

#include "common/prelude.h"

namespace godot {

class FxNativeEdge : public RefCounted {
	GDCLASS(FxNativeEdge, RefCounted)

protected:
	static void _bind_methods();

public:
	// ---- 邻域 / 卷积 ----
	Ref<Image> outline_alpha(const Ref<Image> &p_src, int p_thickness, bool p_inside,
			double p_threshold, const Color &p_color, int p_threads = 1);

	Ref<Image> box_blur(const Ref<Image> &p_src, int p_radius, int p_threads = 1);

	Dictionary stats();
	void reset_stats();
};

} // namespace godot

#endif // FX_NATIVE_EDGE_OPS_H

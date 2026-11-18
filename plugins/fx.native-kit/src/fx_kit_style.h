#ifndef FX_KIT_STYLE_H
#define FX_KIT_STYLE_H
// 风格化族：style.find_edges / emboss / cartoon / halftone / grain
//
// 全部基于亮度平面：先算一遍 `std::vector<float>`，再在循环里按下标读。
// 每像素调 8 次 luma 的版本在 GDScript 里是 100 ms/格，这里是 0.2 ms 量级。

#include "fx_kit_support.h"

namespace godot {

class FxKitStyle : public RefCounted {
	GDCLASS(FxKitStyle, RefCounted)

protected:
	static void _bind_methods();

public:
	Dictionary fx_exec(const Dictionary &inputs, const Dictionary &params, const Dictionary &env);
};

} // namespace godot

#endif // FX_KIT_STYLE_H

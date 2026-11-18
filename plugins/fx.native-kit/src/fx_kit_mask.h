#ifndef FX_KIT_MASK_H
#define FX_KIT_MASK_H
// 蒙版族：mask.rect / ellipse / boolean / from_luma / feather / vignette
//
// 表示法：蒙版写成 `(v,v,v,v)` —— RGB 与 alpha 同一个值。
// 于是同一张图既能被按 alpha 读的下游用，也能被按亮度读的下游用。

#include "fx_kit_support.h"

namespace godot {

class FxKitMask : public RefCounted {
	GDCLASS(FxKitMask, RefCounted)

protected:
	static void _bind_methods();

public:
	Dictionary fx_exec(const Dictionary &inputs, const Dictionary &params, const Dictionary &env);
};

} // namespace godot

#endif // FX_KIT_MASK_H

#ifndef FX_KIT_KEY_H
#define FX_KIT_KEY_H
// 抠像族：key.chroma_pro / key.luma / key.diff / key.color_range / key.matte_clean / key.despill
//
// 一个类一个族：编不出来或被停用时只影响这 6 个算子。
// 所有算子都是**纯函数**（不持跨帧状态），所以可以声明 thread_safe。

#include "fx_kit_support.h"

namespace godot {

class FxKitKey : public RefCounted {
	GDCLASS(FxKitKey, RefCounted)

protected:
	static void _bind_methods();

public:
	/// 窄 ABI 唯一入口：`env["op"]` 决定走哪个算子。
	Dictionary fx_exec(const Dictionary &inputs, const Dictionary &params, const Dictionary &env);
};

} // namespace godot

#endif // FX_KIT_KEY_H

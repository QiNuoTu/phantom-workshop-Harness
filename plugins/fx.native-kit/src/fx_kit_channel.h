#ifndef FX_KIT_CHANNEL_H
#define FX_KIT_CHANNEL_H
// 通道族：channel.extract / combine / mixer / set_alpha / shift / swap

#include "fx_kit_support.h"

namespace godot {

class FxKitChannel : public RefCounted {
	GDCLASS(FxKitChannel, RefCounted)

protected:
	static void _bind_methods();

public:
	Dictionary fx_exec(const Dictionary &inputs, const Dictionary &params, const Dictionary &env);
};

} // namespace godot

#endif // FX_KIT_CHANNEL_H

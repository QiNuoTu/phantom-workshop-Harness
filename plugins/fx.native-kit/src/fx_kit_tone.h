#ifndef FX_KIT_TONE_H
#define FX_KIT_TONE_H
// 色调族：tone.posterize_pro / palette / levels_pro / split_tone / temperature

#include "fx_kit_support.h"

namespace godot {

class FxKitTone : public RefCounted {
	GDCLASS(FxKitTone, RefCounted)

protected:
	static void _bind_methods();

public:
	Dictionary fx_exec(const Dictionary &inputs, const Dictionary &params, const Dictionary &env);
};

} // namespace godot

#endif // FX_KIT_TONE_H

#include <gdextension_interface.h>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

#include "fx_kit_channel.h"
#include "fx_kit_key.h"
#include "fx_kit_mask.h"
#include "fx_kit_style.h"
#include "fx_kit_tone.h"

using namespace godot;

// 五个算子族各注册成一个独立的类。
//
// 为什么不是「一个什么都会的 FxKit」：
//   · 一族编不出来时，只丢那 5~6 个算子，其余四族照常绑定；
//   · 归属清楚 —— 停用插件只撤回自己绑的那些算子；
//   · 每个类的 fx_exec 只做分派，分派错了一眼能看出来。
static void fx_kit_init_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(FxKitKey);
	GDREGISTER_CLASS(FxKitChannel);
	GDREGISTER_CLASS(FxKitMask);
	GDREGISTER_CLASS(FxKitTone);
	GDREGISTER_CLASS(FxKitStyle);
}

static void fx_kit_uninit_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C" {

GDExtensionBool GDE_EXPORT fx_native_kit_library_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		const GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_object(p_get_proc_address, p_library, r_initialization);
	init_object.register_initializer(fx_kit_init_module);
	init_object.register_terminator(fx_kit_uninit_module);
	init_object.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_object.init();
}
}

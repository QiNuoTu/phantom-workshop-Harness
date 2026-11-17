#include <gdextension_interface.h>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

#include "blend_ops.h"
#include "edge_ops.h"
#include "gen_ops.h"
#include "point_ops.h"
#include "warp_ops.h"

using namespace godot;

// 五个算子族各注册成一个独立的类，不再有「一个什么都懂的 FxPixelNative」。
//
// 为什么拆成五个而不是一个：GDScript 侧按族取用（桥里每个函数自己找自己那族），
// 所以哪一族编不出来、或者被插件停用，只影响那几个算子，其余照常走原生。
// 一个巨型类的反例是：任何一处签名改动都会让整条原生路径一起失效。
static void fx_native_init_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(FxNativePoint);
	GDREGISTER_CLASS(FxNativeWarp);
	GDREGISTER_CLASS(FxNativeBlend);
	GDREGISTER_CLASS(FxNativeEdge);
	GDREGISTER_CLASS(FxNativeGen);
}

static void fx_native_uninit_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C" {

GDExtensionBool GDE_EXPORT pixels_native_library_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		const GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_object(p_get_proc_address, p_library, r_initialization);
	init_object.register_initializer(fx_native_init_module);
	init_object.register_terminator(fx_native_uninit_module);
	init_object.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_object.init();
}
}

#ifndef FX_NATIVE_PRELUDE_H
#define FX_NATIVE_PRELUDE_H
// 各 family 的实现文件共用的标准库与 godot-cpp 前置。
// 放在一处的原因：这五个算子族都要 PackedByteArray / Image / Color，
// 而每个文件各自 include 十几行只会让「谁依赖什么」更难看出来。

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/rect2i.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

// 五个 family 的实现都在 `namespace fx` 里，直接写 `Dictionary` / `Ref<Image>`
// 比逐处 `godot::` 前缀轻得多。带进来一次就够了 —— 之前每个 .cpp 各写一行，
// 结果公共头（counters.h / image_access.h）先于那一行被包含，编译期全是不明所以的
// 「缺少类型说明符」。这是拆分时最容易踩、也最没有提示的一处。
using namespace godot;

#endif // FX_NATIVE_PRELUDE_H

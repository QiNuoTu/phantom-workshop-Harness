#!/usr/bin/env bash
# 构建原生像素内核（Windows / MSVC，直接用 cl.exe，不经 SCons）。
#
#   bash plugins/pixels.native/build.sh [template_debug|template_release] [--regen]
#
# 为什么不用 SCons 作默认路径：
#   1. SCons 探测 MSVC 要调 reg.exe，某些环境把它列进黑名单，一调就整步失败；
#   2. 它每次按签名判断 godot-cpp 是否要重编，签名一变就重编 ~1000 个文件，
#      而本插件只有 6 个翻译单元 —— 为了编 6 个文件重编整个 godot-cpp 不划算；
#   3. godot-cpp 的 `gen/` 是生成物，SCons 会先删后写，批量删除容易被策略拦。
#   SConstruct 仍保留（`python -m SCons ...` 可用），供 CI / 干净机器使用。
#
# 前置：
#   · godot-cpp 源码（默认 C:/pw/godot-cpp，可 GODOT_CPP=<路径> 覆盖）
#   · 已用 SCons 编过一次 godot-cpp，静态库在 C:/pw/build/native（LIB_DIR 可改）
#   · MSVC + Windows SDK（版本可用 MSVC_VER / SDK_VER 覆盖）
#
# 产物：native/pixels_native<后缀>.dll + pixels_native.gdextension（由 .in 生成）
set -euo pipefail

TARGET="${1:-template_debug}"
REGEN="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "${HERE}"

GODOT_CPP="${GODOT_CPP:-C:/pw/godot-cpp}"
LIB_DIR="${LIB_DIR:-C:/pw/build/native}"
API_VERSION="${API_VERSION:-4.7}"
MSVC_VER="${MSVC_VER:-14.39.33519}"
SDK_VER="${SDK_VER:-10.0.22621.0}"
VS_ROOT="${VS_ROOT:-C:/Program Files/Microsoft Visual Studio/2022/Community}"
SDK_ROOT="${SDK_ROOT:-C:/Program Files (x86)/Windows Kits/10}"

CL="${VS_ROOT}/VC/Tools/MSVC/${MSVC_VER}/bin/Hostx64/x64/cl.exe"
LINK="${VS_ROOT}/VC/Tools/MSVC/${MSVC_VER}/bin/Hostx64/x64/link.exe"
INCLUDE_MSVC="${VS_ROOT}/VC/Tools/MSVC/${MSVC_VER}/include"
LIB_MSVC="${VS_ROOT}/VC/Tools/MSVC/${MSVC_VER}/lib/x64"
SDK_INC="${SDK_ROOT}/Include/${SDK_VER}"
SDK_LIB="${SDK_ROOT}/Lib/${SDK_VER}"

[ -x "${CL}" ] || { echo "找不到 cl.exe：${CL}" >&2; exit 1; }
[ -d "${GODOT_CPP}" ] || { echo "找不到 godot-cpp：${GODOT_CPP}" >&2; exit 1; }

BUILD="build"
GEN="${BUILD}"
OBJ="${BUILD}/obj"
mkdir -p "${OBJ}" native

# ---- 1) 生成 godot-cpp 绑定头 ----
# 缺了它连 <godot_cpp/classes/image.hpp> 都打不开。`gen/` 是生成物，不提交，
# 也不能指望别人手上有 —— 所以由脚本按需生成（约 5 秒）。
if [ "${REGEN}" = "--regen" ] || [ ! -d "${GEN}/gen/include/godot_cpp/classes" ]; then
	echo "生成绑定（api ${API_VERSION}）…"
	MSYS2_ARG_CONV_EXCL="*" python - "${GODOT_CPP}" "${GEN}" "${API_VERSION}" <<'PY'
import sys
root, out, api = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, root)
from binding_generator import generate_bindings
generate_bindings(
    "%s/gdextension/extension_api-%s.json" % (root, api.replace(".", "-")),
    "%s/gdextension/gdextension_interface.json" % root,
    True, "64", "single", out,
)
PY
fi

# ---- 2) 编译 ----
# 三个必须的开关，少一个都会以「看不懂的样子」失败：
#   -Zc:__cplusplus      MSVC 默认把 __cplusplus 报成 199711L，godot-cpp 用 static_assert 卡 C++17
#   -DTYPED_METHOD_BIND  与 godot-cpp 的编译开关一致，否则绑定模板对不上（_gdeUnexistingClass）
#   -MT                  godot-cpp 静态库是 /MT 编的，用 /MD 会 LNK2038 运行库不匹配
DEFINES=(-DTYPED_METHOD_BIND -DNDEBUG -DDISABLE_DEPRECATED)
if [ "${TARGET}" = "template_debug" ]; then
	DEFINES+=(-DDEBUG_ENABLED)
fi

INCLUDES=(
	-I"${GEN}/gen/include"
	-I"${GODOT_CPP}/include"
	-I"src"
	-I"${INCLUDE_MSVC}"
	-I"${SDK_INC}/ucrt" -I"${SDK_INC}/um" -I"${SDK_INC}/shared"
)

echo "编译 ${TARGET}（api ${API_VERSION}）…"
for src in src/*.cpp; do
	name="$(basename "${src}" .cpp)"
	MSYS2_ARG_CONV_EXCL="*" VSLANG=1033 "${CL}" -nologo -c -utf-8 -std:c++17 -Zc:__cplusplus \
		-EHsc -MT -O2 "${DEFINES[@]}" "${INCLUDES[@]}" \
		-Fo"${OBJ}/${name}.obj" "${src}" > "${OBJ}/${name}.log" 2>&1 || {
		echo "编译失败：${name}" >&2
		iconv -f GBK -t UTF-8 "${OBJ}/${name}.log" 2>/dev/null | grep -i error | head -10 >&2 \
			|| tail -10 "${OBJ}/${name}.log" >&2
		exit 1
	}
done

# ---- 3) 链接 ----
SUFFIX=".windows.${TARGET}.x86_64"
OUT_DLL="native/pixels_native${SUFFIX}.dll"
MSYS2_ARG_CONV_EXCL="*" VSLANG=1033 "${LINK}" -nologo -DLL \
	-OUT:"${OUT_DLL}" -IMPLIB:"native/pixels_native${SUFFIX}.lib" \
	-LIBPATH:"${LIB_DIR}" -LIBPATH:"${LIB_MSVC}" \
	-LIBPATH:"${SDK_LIB}/ucrt/x64" -LIBPATH:"${SDK_LIB}/um/x64" \
	"${OBJ}"/*.obj "libgodot-cpp${SUFFIX}.lib" > "${BUILD}/link.log" 2>&1 || {
	echo "链接失败" >&2
	iconv -f GBK -t UTF-8 "${BUILD}/link.log" 2>/dev/null | grep -i error | head -10 >&2
	exit 1
}

# ---- 4) 描述文件跟产物走 ----
# 反过来（描述在、库不在）引擎每次启动都会刷「GDExtension dynamic library not found」。
cp pixels_native.gdextension.in pixels_native.gdextension
ls -l "${OUT_DLL}"
echo "完成：${OUT_DLL}（描述文件已落地）"

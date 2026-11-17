#!/usr/bin/env bash
# 运行时冒烟：**开窗**跑，抓 headless 抓不到的那一半。
#
# 为什么需要它：`tools/run_tests.sh` 全部在 --headless 下跑，
# 那里不执行 _draw()、不建纹理、预渲染线程常被跳过。于是「多条预渲染线程
# 共用一个有状态的引擎实例」这类问题永远不会红 —— 真机上表现为
#   SCRIPT ERROR: Out of bounds get index '...' (on base: 'PackedByteArray')
# 而且画面会静默错色。这个脚本把「打开工程 → 逐节点改参 → 显示倍率 →
# 播放 → 导出 → 存盘读回」跑一遍，并**把引擎级报错也当失败**。
#
# 用法：bash tools/smoke.sh [--headless]   （--headless 只用于排查，不算通过）
set -uo pipefail

GODOT="${GODOT:-godot}"
if ! command -v "$GODOT" >/dev/null 2>&1; then
  GODOT="D:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe"
fi

MODE=(--path .)
if [ "${1:-}" = "--headless" ]; then
  MODE=(--headless --path .)
fi

LOG="$(mktemp)"
set +e
"$GODOT" "${MODE[@]}" --script res://tests/runtime_smoke.gd >"$LOG" 2>&1
code=$?
set -e

ok=$(grep -cE '^  ok ' "$LOG" || true)
bad=$(grep -cE 'FAIL:' "$LOG" || true)
# 引擎级报错：GDScript 抓不到别的脚本抛的 SCRIPT ERROR，只能靠日志兜底。
engine_errors=$(grep -cE 'SCRIPT ERROR|Out of bounds|Invalid access to property' "$LOG" || true)

grep -E '^  ok |FAIL:|运行时冒烟' "$LOG"
echo "----"
echo "断言 ${ok} 条，失败 ${bad} 条，引擎级报错 ${engine_errors} 条，退出码 ${code}"
if [ "$engine_errors" -gt 0 ]; then
  echo "---- 引擎级报错（前 20 行）----"
  grep -nE 'SCRIPT ERROR|Out of bounds|Invalid access to property' "$LOG" | head -20
fi
# 删临时日志失败不算失败：某些沙箱会拦截 rm（例如把 Windows 临时路径判成非法），
# 那与「冒烟有没有过」无关。`set -e` 下不加 `|| true` 会让整个门禁假红。
rm -f "$LOG" 2>/dev/null || true

[ "$bad" -eq 0 ] && [ "$engine_errors" -eq 0 ] && [ "$code" -eq 0 ]

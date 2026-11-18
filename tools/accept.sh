#!/usr/bin/env bash
# 实机验收：**开窗**跑「调色抠像」验收工程，验 28 个原生算子真的能跑。
#
# 与 tools/smoke.sh 的分工：
#   smoke.sh  —— 拿「示范工程」验**整机行为**（改参、显示倍率、播放、导出、存盘读回、
#                插件启停、画布切换）。它关心的是外壳与渲染管线；
#   accept.sh —— 拿「调色抠像」验**这套插件**（每个节点都有定义与算子、首帧无告警、
#                播放推进、导出落盘）。它关心的是插件本身。
#
# 两个都要跑：只跑 smoke 会漏掉"新节点拖进去没画面"，只跑 accept 会漏掉"整机被拖坏"。
#
# 用法：bash tools/accept.sh [--headless]   （--headless 只用于排查，不算通过）
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
"$GODOT" "${MODE[@]}" --script res://tests/runtime_accept_lookdev.gd >"$LOG" 2>&1
code=$?
set -e

ok=$(grep -cE '^  ok ' "$LOG" || true)
bad=$(grep -cE 'FAIL:' "$LOG" || true)
engine_errors=$(grep -cE 'SCRIPT ERROR|Out of bounds|Invalid access to property' "$LOG" || true)

grep -E '^  ok |FAIL:|实机验收' "$LOG"
echo "----"
echo "断言 ${ok} 条，失败 ${bad} 条，引擎级报错 ${engine_errors} 条，退出码 ${code}"
if [ "$engine_errors" -gt 0 ]; then
  echo "---- 引擎级报错（前 20 行）----"
  grep -nE 'SCRIPT ERROR|Out of bounds|Invalid access to property' "$LOG" | head -20
fi
rm -f "$LOG" 2>/dev/null || true

[ "$bad" -eq 0 ] && [ "$engine_errors" -eq 0 ] && [ "$code" -eq 0 ]

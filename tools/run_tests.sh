#!/usr/bin/env bash
# 全量无头回归：14 套，逐套打印断言数与失败数。
# 用法：bash tools/run_tests.sh [--only test_kernel,test_graph_core]
set -uo pipefail

GODOT="${GODOT:-godot}"
if ! command -v "$GODOT" >/dev/null 2>&1; then
  # Windows 上把 Steam 版引擎路径写进来，或者 export GODOT=... 再跑。
  GODOT="D:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe"
fi
if [ ! -x "$GODOT" ] && ! command -v "$GODOT" >/dev/null 2>&1; then
  echo "找不到 Godot，可执行文件请用环境变量指定：GODOT=/path/to/godot bash tools/run_tests.sh" >&2
  exit 2
fi

SUITES=(test_kernel test_graph_core test_editor_ui test_plugins test_pixelfx test_text \
        test_math_flow test_plugin_lifecycle test_shell_ui test_interactions \
        test_platform test_io test_project test_architecture)

if [ "${1:-}" = "--only" ] && [ -n "${2:-}" ]; then
  IFS=',' read -r -a SUITES <<< "$2"
fi

total=0
failed=0
for suite in "${SUITES[@]}"; do
  log="$(mktemp)"
  "$GODOT" --headless --path . --script "res://tests/${suite}.gd" >"$log" 2>&1
  ok=$(grep -cE '^  ok ' "$log")
  bad=$(grep -cE 'FAIL:' "$log")
  total=$((total + ok))
  failed=$((failed + bad))
  printf '%-24s ok=%-4s fail=%s\n' "$suite" "$ok" "$bad"
  if [ "$bad" -gt 0 ]; then
    grep -E 'FAIL:' "$log" | sed 's/^/    /'
  fi
  rm -f "$log"
done

echo "----"
echo "断言 ${total} 条，失败 ${failed} 条"
[ "$failed" -eq 0 ]

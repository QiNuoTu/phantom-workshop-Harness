#!/usr/bin/env bash
# 全量无头回归：21 套，逐套打印断言数与失败数。
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
        test_platform test_io test_project test_architecture test_cache_trace test_preview_roots \
        test_core_compile test_res_scale test_pixel_parallel test_pixel_native \
        test_invalidation test_dynamic_quality test_render_canvas_binding \
        test_fx_ae_pack test_fx_budget)

if [ "${1:-}" = "--only" ] && [ -n "${2:-}" ]; then
  IFS=',' read -r -a SUITES <<< "$2"
fi

total=0
failed=0
crashed=0
for suite in "${SUITES[@]}"; do
  log="$(mktemp)"
  "$GODOT" --headless --path . --script "res://tests/${suite}.gd" >"$log" 2>&1
  code=$?
  ok=$(grep -cE '^  ok ' "$log")
  bad=$(grep -cE 'FAIL:' "$log")
  total=$((total + ok))
  failed=$((failed + bad))
  # 退出码也要看：断言全过、打印了「全部通过」，然后**在退出阶段 SIGSEGV** ——
  # 这种套件其实已经坏了（静态表活过脚本类），只是所有 FAIL 都来不及打印。
  # 从前只看 FAIL 行，于是三个套件（test_io / test_res_scale / test_pixel_parallel）
  # 静默崩溃了很久，连带断言数在 1357–1359 之间飘。
  if [ "$code" -ne 0 ]; then
    crashed=$((crashed + 1))
  fi
  printf '%-24s ok=%-4s fail=%-3s exit=%s\n' "$suite" "$ok" "$bad" "$code"
  if [ "$bad" -gt 0 ]; then
    grep -E 'FAIL:' "$log" | sed 's/^/    /'
  fi
  if [ "$code" -ne 0 ] && [ "$bad" -eq 0 ]; then
    # 没有 FAIL 却有非零退出码：多半是退出阶段崩了，把最后几行打出来当线索。
    echo "    （无失败断言但退出码 ${code}；日志尾部）"
    tail -5 "$log" | sed 's/^/    /'
  fi
  rm -f "$log"
done

echo "----"
echo "断言 ${total} 条，失败 ${failed} 条，异常退出 ${crashed} 个"
# 落一份机器可读的结论：tools/check_docs.py 靠它核对 README 里的断言数，
# 否则「文档写 1210、实际 1270」这种事只能靠人肉发现（已发生过两次）。
printf '{"assertions": %d, "failed": %d, "crashed": %d, "suites": %d}\n' \
	"$total" "$failed" "$crashed" "${#SUITES[@]}" > "$(dirname "${BASH_SOURCE[0]}")/.last_tests.json"
[ "$failed" -eq 0 ] && [ "$crashed" -eq 0 ]

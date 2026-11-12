# CLAUDE.md

给在这个仓库里工作的 AI 协作者（Claude Code / Codex / WorkBuddy …）的约定。
人类贡献者请先读 [CONTRIBUTING.md](CONTRIBUTING.md)。

---

## 项目一句话

Godot **4.7.2** 的节点式 2D 特效工坊。基座 `scripts/graph/`（8.9k 行）只提供机制，
其余 39 个插件在 `plugins/`。核心设计来自论文
*[A Programming Paradigm for Spatiotemporal Composability](https://arxiv.org/abs/2608.25512)*：
空间（图）与时间（帧）正交，只在 `core.render` 组合。

---

## 常用命令

```bash
GODOT="D:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe"

# 全量回归（14 套，逐套打印断言数；改完必须全绿）
bash tools/run_tests.sh

# 单套
"$GODOT" --headless --path . --script res://tests/test_editor_ui.gd

# 语法检查单个脚本
"$GODOT" --headless --path . --check-only --script res://plugins/core.render/fx_render_service.gd

# 新增/移动 class_name 脚本后**必须**重建类缓存，否则无头报 "not declared"
"$GODOT" --headless --path . --editor --quit

# 装配诊断（插件 / 节点 / 面板 / 设置 / 语言包 / 缓存位置）
"$GODOT" --headless --path . -- --fx-diagnose

# 带显示：播放在真实工程上验收（会占窗口，看起来像卡住是正常的）
"$GODOT" --path . --script res://tests/_probe_playback.gd
```

引擎不在 PATH 里。Linux 上把 `GODOT` 换成 `godot`。

---

## 文件地图（先看这几处）

| 想改什么 | 去哪里 |
| --- | --- |
| 文档撤销 / 内容身份 / 批处理 | `scripts/graph/kernel/fx_document_store.gd` |
| 图能力契约（provider 必须实现的方法） | `scripts/graph/kernel/fx_graph_access.gd` |
| 呈现器契约（基座侧空实现） | `scripts/graph/kernel/fx_render_host.gd` |
| 插件扫描 / 依赖 / 可逆账本 | `scripts/graph/plugins/fx_plugin_host.gd`、`fx_registry.gd` |
| 外壳 / 停靠 / 菜单 / 状态栏 | `scripts/graph/ui/fx_shell.gd` |
| 图语义与求值器 | `plugins/core.graph/`（`fx_graph_runner.gd`、`fx_ops_*`） |
| 渲染编排 / 帧缓存 / 预渲染 | `plugins/core.render/`（`fx_render_service.gd` 是枢纽） |
| 时间轴 UI / 时钟 | `plugins/editor.timeline/`、`plugins/core.timeline/` |
| 蓝图编辑器 | `plugins/editor.graph/` |
| GPU compute 算子 | `plugins/render.gpu/` |

---

## 必须先知道的 8 条不变量

1. **基座零插件类名。** `scripts/graph/**` 不许出现 `FxRenderService` / `FxFrameCache` /
   `FxGraphDoc` / `FxCatalog` 等；`tests/test_architecture.gd` 有静态断言。
   需要能力 → 加基座契约（如 `FxRenderHost`），插件去实现，缺失时用空实现。
2. **界面零图领域符号。** `editor.*` 只 inject `graph.facade` / `node_picker.broker`。
3. **节点类型只在插件里。** 禁止 `if type == "..."`；行为写在 `nodes*.json` + op 表。
4. **文档写入只走 `FxDocumentStore.mutate / apply_param / apply_path`**，
   批量 `begin_batch()` → `commit_batch()`（**没有** `end_batch`）。
   `mutate` 在「写前 == 写后」时必须完全静默：不记撤销点、不 bump、不广播。
5. **内容身份 = 世代 × 2²⁰ + 修订号**（`content_key()`）。换工程、改参数会变；
   拖节点（纯 `positions`）不会。**不要**用 `revision()` 当快照键（`attach()` 会归零）。
6. **播放只读缓存 + 帧号每 process 至多 +1。** 播放期禁 `set_time()`（会广播 131ms/帧），
   用 `set_time_silent()` + `time_ticked`。
7. **归档看「算它的那一档质量」**：`quality=0`（播放档）的结果只能进伴随层（黄），
   绝不能标绿。绿 = 与导出一致的精确帧。
8. **结果必须带 `epoch + doc_key`**，不匹配整个丢弃（连缓存都不写）。

---

## 测试纪律

- 行为改动 → 必须有断言，且断言总数不能减少。
- 性能结论 → **只认** `examples/demo/示范工程.fxproj`（103 节点 / 192×108 / 60 帧），
  给改前 / 改后数字，禁止用小案例。
- 带显示的探针（`tests/_probe_*.gd`、`capture_ui.gd`）会占满主线程连续渲染，
  看起来像卡死；跑之前先告诉用户，别连着跑多个。
- 无头安全：`--headless` 的 `test_*`、`_probe_fp2.gd`、`_profile_demo.gd`。

---

## 踩过的坑（别踩第二次）

| 坑 | 事实 |
| --- | --- |
| 新增 `class_name` 后无头跑测试报未声明 | 必须先 `--headless --editor --quit` 重建类缓存 |
| lambda 里计数永远是 0 | GDScript 对 `int` 是值捕获，计数放 `Array` |
| `Vector2 != Array` 直接抛错 | 跨类型比较先 `typeof` 短路 |
| `.gd` 是 CRLF | Python 改写要按行 `rstrip('\r')`，跨行 lambda 头单独处理 |
| 主 RenderingDevice 不能 `submit()/sync()` | compute 只能在渲染线程调；用 `RenderingServer.call_on_render_thread` + 批量合流 |
| 每像素 `Callable.call()` 很贵 | 用 `FxPixelKit.generate_batch / map_batch / remap_batch`，循环写进 lambda |
| 标尺全绿但底栏还停在旧数 | 归档后要 `_emit_cache()`（带 0.25s 节流） |
| 拖动节点导致整段缓存作废 | 布局键（`positions` / `size` / `selection` / `time`）不算内容 |

---

## 交付前自检

```bash
bash tools/run_tests.sh     # 必须 0 失败
"$GODOT" --headless --path . -- --fx-diagnose | tail -20   # 插件/节点/设置数量对得上
```

- [ ] 断言总数没有减少，没有为了让测试过而放宽断言
- [ ] 没有把插件类名/id 写进基座
- [ ] 新增设置项有 `applies` / `order`，按钮型用 `kind:"action"`
- [ ] 注释解释了「为什么」，而不是复述代码
- [ ] 改动涉及性能时，PR 里带示范工程的改前/改后数字

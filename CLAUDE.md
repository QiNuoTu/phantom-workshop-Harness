# CLAUDE.md

给在这个仓库里工作的 AI 协作者（Claude Code / Codex / WorkBuddy …）的约定。
人类贡献者请先读 [CONTRIBUTING.md](CONTRIBUTING.md)。

---

## 项目一句话

Godot **4.7.2** 的节点式 2D 特效工坊。基座 `scripts/graph/`（9.3k 行）只提供机制，
其余 42 个插件在 `plugins/`。核心设计来自论文
*[A Programming Paradigm for Spatiotemporal Composability](https://arxiv.org/abs/2608.25512)*：
空间（图）与时间（帧）正交，只在 `core.render` 组合。

---

## 常用命令

```bash
GODOT="D:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe"

# 全量回归（23 套，逐套打印断言数；改完必须全绿）—— 全部在 --headless 下跑
bash tools/run_tests.sh

# 运行时冒烟（**开窗**）：headless 看不见的那一半（_draw / 纹理 / 预渲染线程 / GPU）
# 引擎级报错也算失败，不只看断言
bash tools/smoke.sh

# 单套
"$GODOT" --headless --path . --script res://tests/test_editor_ui.gd

# 语法检查单个脚本
"$GODOT" --headless --path . --check-only --script res://plugins/core.render/fx_render_service.gd

# 新增/移动 class_name 脚本后**必须**重建类缓存，否则无头报 "not declared"
"$GODOT" --headless --path . --editor --quit

# 装配诊断（插件 / 节点 / 面板 / 设置 / 语言包 / 缓存位置）
"$GODOT" --headless --path . -- --fx-diagnose

# 归因诊断（把问题判给内核 / 具体插件 / 装配；内核数不为 0 就先修内核）
# IR / 剪枝报告（core.compile）：DAG、类型检查、常量折叠、Live/Dead
"$GODOT" --headless --path . -- --fx-diagnose --fx-run=diag.blame

# 缓存归因（谁让帧缓存重建 / 失效、要了多大一档；--fx-arg=reset 先清空再统计）
"$GODOT" --headless --path . -- --fx-diagnose --fx-run=diag.cache --fx-arg=reset

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
| IR 编译 / 剪枝 / 帧段 | `plugins/core.compile/`（`fx_ir_compiler.gd`） |
| 归因诊断（内核 / 插件 / 装配） | `plugins/editor.diagnostics/`（`fx_blame.gd`） |
| 原生像素内核（C++） | `plugins/pixels.native/`（`src/{point,warp,blend,edge,gen}_ops.cpp`） |
| 原生桥（GDScript 侧唯一入口） | `plugins/core.pixels/fx_native_bridge.gd` |

---

## 必须先知道的 9 条不变量

1. **基座零插件类名。** `scripts/graph/**` 不许出现 `FxRenderService` / `FxFrameCache` /
   `FxGraphDoc` / `FxCatalog` 等。
   ⚠️ `tests/test_architecture.gd` 用的是**白名单**，只证明「列出来的那些没被引用」；
   真正的检查是 `--fx-run=diag.blame`（扫全部插件 `class_name`），**合并前必须是内核 0 条**。
   值归一化走基座 `FxValue`；算子表这类运行时派生表由插件实现
   `FxGraphAccess.reset_runtime_tables()`，基座只喊一声。
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
9. **失效按档位，不按「谁调的」**：`invalidate("content" | "derived" | "display", source)`。
   设置项的代价由**声明者**用 `impact` 给出，基座只转达 —— 别在基座里维护设置 id 白名单。
   要改缓存行为之前，先跑 `diag.cache` 看清现在的重建来自哪里。
10. **换桶是破坏性的，之后必须补算当前帧。** `prepare()` 会把每一格 `fill(STATE_EMPTY)`；
    只重建不补算，表现就是「预览空一下，碰一下界面才回来」。
    `_refill_after_rebuild` 保证补**一次**，不许多次（否则退化成每帧重算）。
11. **内容指纹只收「能改变输出像素」的字段。** 位置、尺寸、折叠状态、分组框矩形都不收。
    新增文档字段时先问一句：改它会让画面变吗？不会就别让它进 `content_of()`。
12. **节点读数按类型画，分派只有一个点。** 卡片读数走 `FxNodeValueGauge.kind_of()`
    （端口类型 → 画法：曲线/坐标/色块/灯/文本），它不认识节点类型；新增节点不用改它。
    读数**不受 `capture_previews` 约束**（那个开关省的是缩图，读数几乎不花钱），
    只在「显示签名」变化时重绘，值没变不追加采样。
13. **绘制代码无头不执行。** `--headless` 下 `_draw()` 不会跑，所以改了绘制
    **必须开窗验一次**（`godot --path . --script res://tests/_probe_gauge_shot.gd`），
    不能拿「测试全绿」当「画对了」。
14. **归因要能指认到具体节点。** `diag.cache` 的 `变了：节点~blur` 靠 `detail_of()`
    与桶事件的 `detail_before/after`；只报「图变了」等于没报。
    另外：指纹变了而修订号没变 = 有人绕过 `mutate()/attach()` 直接改文档字典，判 `error`。
15. **降分辨率只允许发生在中间过程。** `res_scale` 的语义是「本节点及其上游按倍率求值」，
    **输出尺寸与导出尺寸永远不变**。输出节点与汇点（`evaluate_always`）必须拒绝降档；
    共享上游若还被 1.0 路径消费，必须按 1.0 算（否则一条旁支会悄悄拉低主干精度）。
16. **像素单位的参数必须声明 `unit: "px"`。** 执行器按它乘 `ctx.eval_scale`，
    插件新增像素参数只要打上这个单位就自动正确；不声明的话，降档会变成「效果变了」
    而不是「画质略降」。比例量（`scale` / `anchor` / 角度）**不要**标成 px。
17. **GDScript 里最贵的是「内层小循环」和「函数调用」，不是算法。**
    逐像素循环里 `for c in range(3)` 展开成三行、`int(round(x))` 换成 `int(x + 0.5)`、
    `lerpf` 链换成「权重一次算完」、能走引擎 C++（`Color.from_hsv` 之类）就别自己写。
    实测这些改动（1.21×）比行内并行（1.34×）还值钱。
18. **改逐像素循环必须与串行「逐字节」比对。** 切片差一行、读写索引没分开，
    画面只在某些尺寸上烂一点点，肉眼很难发现。`tests/test_pixel_parallel.gd`
    用 25/37/101 行这种除不尽的尺寸钉这件事。
19. **`FxPixelParallel` 只在主线程启用。** 预渲染已经按帧并行，worker 里再提交子任务
    会把池占满（互相等子任务＝死锁）。怀疑「并行之后不对」时先 `FX_NO_PARALLEL=1` 关掉它。
    计数器 `parallel_calls` / `serial_calls` 是判断「真的并行了没」的唯一依据。
20. **加速路径有两条，谁都不许改变语义。** GPU（`render.gpu` 的 compute 着色器）与
    原生内核（插件 `pixels.native` 自带的 GDExtension）都是**可选覆盖**：不可用时
    必须回落原 GDScript 实现，画面一致。新增算子时先写 GDScript 版，再考虑覆盖。
    原生内核与 GDScript 的**逐字节一致**由 `tests/test_pixel_native.gd` 钉住
    （它把 `FxNativeBridge.set_enabled(false/true)` 各跑一遍同一算子再比 `get_data()`）。
21. **原生扩展的边界是「通用图元」，不是节点。** 五个族类（`FxNativePoint/Warp/Blend/
    Edge/Gen`）只认像素、矩形、通道号这些哑参数，不认 `image.bloom` 之类的节点类型；
    节点语义仍在插件里。`FxNativeBridge` 是唯一入口，按**族**取实例并用
    `ClassDB.instantiate`（直接写类名会在扩展缺席时**解析期**报「标识符不存在」）。
    族缺一不可怕：缺哪族只有那几个算子回落 GDScript，`abi_report()` 会报逐族实况。
22. **线程数由调用方显式传。** 主线程可以多线程，预渲染工作线程传 1 ——
    它们本来就按帧并行，再各自开满线程只会互相抢核。
23. **构建原生扩展优先走 `plugins/pixels.native/build.sh`（直接 cl，不经 SCons）。**
    SCons 探测 MSVC 要调 `reg.exe`（可能被策略拦），且签名一变就重编整个 godot-cpp。
    三个开关少一个都会以看不懂的样子失败：`-Zc:__cplusplus` / `-DTYPED_METHOD_BIND` / `-MT`。
    godot-cpp 仍需放在纯 ASCII 路径（默认 `C:/pw/godot-cpp`），原因见脚本顶部注释。
24. **改求值尺寸时先想「谁在读 `ctx.canvas`」。** 生成器读它决定输出尺寸，滤镜跟随输入图。
    所以降档只需换画布 + 换输入图，**不要去改算子**；反过来，任何「输出尺寸」的改动
    都要在这个模型里自洽，否则会出现「算子跳回全尺寸」的诡异表现。
25. **「节点专有」这条线划在几何上，不划在参数名上。** 判断一个公式该不该进内核，
    问的不是「它属于哪个节点」，而是「换一个节点来调它还说不说得通」。
    `rays` / `shockwave` 的参数绑着节点，但它们的本体是「周期性角度场 × 径向衰减」
    与「以 phase 为半径的环」—— 所以进内核的是 `radial_spokes` / `radial_ring`，
    不是 `rays`。第九轮按前一种判据把它们拒了，第十轮按后一种判据收回来。
26. **位宽要按「有没有构造 `Color`」分两档。** 直接读字节的路径（`float(buf[i]) / 255.0`）
    是 double；走 `get_pixel` / `set_pixel` 的路径要先落 float32（读是
    `float(byte)/255.0f`，写是 `uint8_t(double(float(c.r)) * 255.0)`）。
    `box_blur` 就是漏了这一步，半径 1/3/8 三档逐字节比对全差 1。
27. **整型哈希必须照抄「int64 环绕 + 算术右移」。** `FxMath.h01` 在 C++ 里要写
    `uint64_t(int64_t(n) >> 13)`；写成无符号右移不会崩、不会报错，只是图案整片变样。
    这类错误只有逐字节比对能抓。
28. **性能数字必须标测量口径。** 「开窗」比「无头」稳定多 40 ms（显示服务器与脚本
    抢主线程），混着比会得出「优化后变慢了」的错误结论。要 A/B 就用 `FX_GPU=0` /
    `FX_NATIVE=0` 在同一口径下量，不要跨口径比较。

29. **启动错误必须声明归属。** `FxBoot.error(where, msg, scope)` 的 `scope` 取
    `kernel` / `assembly` / `plugin:<id>`；不声明就退回「看文本里有没有插件痕迹」，
    那条规则会把装配问题判成内核缺陷（`plugins/pixels.native` 缺清单那一次就是）。
    加新的启动步骤时，顺手写清这一步属于谁。
30. **headless 绿不等于能跑。** 无头下不执行 `_draw()`、不建纹理、预渲染线程常被跳过；
    「多条线程共用一个有状态的引擎实例」这类问题只会在开窗时炸（真机表现是
    `Out of bounds get index ... on base: 'PackedByteArray'`，画面还会静默错色）。
    所以交付前必须跑 `bash tools/smoke.sh`，它把「打开工程 → 逐节点改参 → 显示倍率 →
    播放 → 导出 → 存盘读回」走一遍，并把**引擎级报错**也当失败。
31. **按节点缓存的引擎/执行器必须自己保证并发安全。** 它们挂在静态表里，会被
    2–6 条预渲染线程共用。要么每线程一个实例，要么内部加锁 + 一次性换缓冲
    （`VfxEngine` 就是这么修的）；别指望"配方很少改，应该不会撞上"。
32. **缓存里的东西必须自带出处。** 帧缓存除了「算好了」还要记「算它的是哪份文档」
    （`FxFrameCache.identity` + `accepts()`）。桶按指纹重建，但指纹是合成哈希，
    预渲染线程与主线程又是并发的 —— 少了这层身份，第 N 版文档的帧会带着绿标
    活到第 N+1 版，屏幕停在一张谁也不认领的旧图上，而且不报错。
    新增任何「按内容缓存、跨线程分发」的东西，照这个模式来。
33. **测试/诊断脚本动过的插件必须还原。** `FxPluginHost.set_enabled()` 会写
    `user://plugins.cfg`（用户设置，本来就该持久化）。脚本里临时停用插件、半路
    失败没还原，下一次跑测试就是「配方节点不见了」这种毫不相干的红。
    `runtime_smoke` 现在记下并还原它碰过的插件；新脚本照做。
34. **文档数字必须由脚本核对。** `python tools/check_docs.py` 从代码取数
    （版本 / 插件数 / 节点数 / 套件数 / 基座行数 / 断言数）比对 README 与 docs，
    不一致返回非 0。`tools/run_tests.sh` 收尾会写 `tools/.last_tests.json` 供它读。
    **改完代码先跑它**，别手改数字对不上再手改一遍。
35. **同一份事实只有一个存放处。** 节点参数若声明 `binds`（画布宽/高就是这样），
    它读的是文档里那一处的值，**文档里永远存 0**：写它 = 写 `meta.canvas`，
    由 `FxGraphAccess.doc_apply_path` 接管，任何写入方（界面 / 脚本 / 探针）都绕不过。
    两个来源的代价不是「有点不一致」，是**每一帧都被尺寸闸门丢掉**：画面卡死、
    不报错、日志干净（`docs/架构.md` §5.1）。`diag.blame` 第 7 条判据盯这件事。
36. **时间推进只读缓存，不排求值。** 拖时间轴 / 上一帧 / 下一帧都是纯 `time` 变化：
    这一格有精确帧就直接贴（`_serve_cached_time`），没有才排一次实时求值。
    在途结果算的是别的时刻时，**归档但不上屏**，否则拖完会往回跳一帧。
    参数面板的时间刷新同理：只碰打了关键帧 / 被连线驱动的行 —— 其余几百个控件
    每动一格重设一遍，实测一步 110 ms，那才是「拖不动」的大头。
37. **静态表不许活过脚本类；「断言全过然后 exit 139」就是它。** `FxBoot.listen` 的
    回调常常捕获脚本自身，`FxPluginHost.shutdown()` 第一步必须 `forget_listeners()`；
    测试套件退出前一律 `shutdown()`（不 shutdown 的两个套件静默崩了很久）。
    `tools/run_tests.sh` 现在**看退出码**，只看 `FAIL:` 行会漏掉整类崩溃。
38. **工程格式只认 `SUPPORTED_VERSIONS` 里那一个号。** `host_version` 不在表里的包
    在读之前就拒绝（不要「问一句仍要加载」：新语义解释旧字段＝静默读坏）；
    没有版本号的包照常打开（没有 ≠ 不符）。`ZIPPacker` 是追加写，覆盖保存必须走
    「写 `.tmp` → 删旧 → 改名」。

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
| 探针里改了设置，别的套件全线失败 | 设置**落盘**在 `user://settings.cfg`：`quality.operator<1` 会让所有「精确帧」断言挂掉。探针改完必须 `FxSettings.reset()` |
| 归因日志里某字段「凭空消失」 | `FxCacheTrace.record(kind, data)` 会写 `data["kind"]`；传进去的字典里别再叫 `kind`（档位用 `tier`） |
| 换工程后剪枝把新节点剪没了 | `compile_plan` 只绑定节点 id 集合（`ids_hash`）；求值器 `_plan_matches()` 失配会整份作废，别把计划当长期缓存 |
| 停用 `core.compile` 后行为变了 | 计划为空时 `FxGraphRunner` 必须走原分支；渲染服务只认能力键 `graph.compile`，不许直接引用 `FxIRCompiler` |
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
bash tools/run_tests.sh      # 必须 0 失败（headless）
bash tools/smoke.sh          # 必须 0 失败 + 0 引擎级报错（开窗，约 30s）
python tools/check_docs.py   # 必须返回 0（版本/插件数/断言数与代码一致）
"$GODOT" --headless --path . -- --fx-diagnose --fx-run=diag.blame | tail -4  # 内核 0 条
"$GODOT" --headless --path . -- --fx-diagnose | tail -20
```

- [ ] 断言总数没有减少，没有为了让测试过而放宽断言
- [ ] 没有把插件类名/id 写进基座
- [ ] 新增设置项有 `applies` / `order`，按钮型用 `kind:"action"`
- [ ] 注释解释了「为什么」，而不是复述代码
- [ ] 改动涉及性能时，PR 里带示范工程的改前/改后数字

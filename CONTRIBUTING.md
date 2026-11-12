# 参与贡献

先谢谢你愿意花时间。这个项目的门槛不在「会不会 GDScript」，而在**边界感**：
每个东西都应该待在它该待的层里。下面把这些约定写清楚，照着做基本不会被返工。

---

## 1. 环境

| 需要 | 版本 / 说明 |
| --- | --- |
| Godot | **4.7.2**（标准版即可，纯 GDScript，无 .NET 依赖） |
| 系统 | Windows 10+ / Linux / macOS（开发与实测主要在 Windows） |
| 显卡 | 可选。GPU 算子需要支持 compute 的显卡；没有会自动退回 CPU |

```bash
git clone <this-repo> phantom-workshop
cd phantom-workshop
godot --path .                       # 启动工作台
bash tools/run_tests.sh              # 14 套无头回归
```

`tools/run_tests.sh` 默认找 `godot`，找不到会退回 Windows 上的 Steam 版路径。
也可以自己指定：`GODOT=/path/to/godot bash tools/run_tests.sh`。

---

## 2. 三条不变量（最重要）

违反这三条，代码再漂亮也会被打回 —— 它们由 `tests/test_architecture.gd` 静态断言守着。

1. **基座不出现插件类名。**
   `scripts/graph/**` 里不许写 `FxRenderService` / `FxFrameCache` / `FxGraphDoc` 这类名字，
   也不许 `PluginClass.new()` 兜底。需要能力就加**基座契约**（参考 `FxRenderHost`），
   由插件去实现；插件缺失时用空实现顶上。
   > 判据不是「停用后不崩」，而是「删掉插件目录后基座仍能编译」。

2. **界面不出现图领域符号。**
   编辑器只 `inject` 基座代理键（`graph.facade`、`node_picker.broker`），
   不认识 `FxCatalog` / `FxGraphDoc` / 文档容器。

3. **节点类型只活在插件里。**
   执行器与 UI 里禁止 `if type == "image.blur"`。节点行为写在各插件的
   `nodes*.json` + op 表里；端口表唯一入口是 `FxCatalog.ports(def, params)`。

写新功能前先问一句：**这东西是「机制」还是「策略」？**
机制进基座（且只以契约形式），策略进插件。

---

## 3. 代码风格

- **GDScript 4**，tab 缩进（与现有文件一致），类型尽量标注。
- 注释写**为什么**，不写「这行在赋值」。中文注释，术语保留英文（broker / fiber / coeffect）。
- 插件贡献的 `Callable` 必须是**静态函数**（`static func`），不要捕获实例 ——
  热重载撤回时静态表不能吊着旧对象。
- 插件之间的依赖写在 `plugin.json` 的 `inject` 里；**不要**直接引用别的插件的类。
- 新增设置项要写 `applies`（`runtime` / `ui` / `none`）与 `order`；
  按钮型入口用 `"kind": "action"`，不要把动作伪装成开关。
- 译文放 `plugins/<id>/locales/<locale>.json`，键名全局唯一；
  `core.i18n` 只放外壳文案，不要塞领域词。

---

## 4. 测试要求

**任何行为改动都要有断言。** 没有断言的修复等于没修 —— 下一轮会被人改回去。

| 改动类型 | 需要补的 |
| --- | --- |
| 基座契约 / 代理 | `tests/test_kernel.gd` 或 `test_architecture.gd` |
| 图语义 / 文档 | `tests/test_graph_core.gd` |
| 编辑器 UI / 时间轴 / 缓存 | `tests/test_editor_ui.gd` |
| 插件生命周期 / 启停 | `tests/test_plugin_lifecycle.gd` |
| 导出 / 工程文件 / IO | `test_project.gd` / `test_io.gd` |
| 像素算子 | `test_pixelfx.gd`（逐字节比对，别只看「看起来对」） |

跑完必须**全绿**，且断言数不能减少：

```
test_kernel              ok=28   fail=0
test_graph_core          ok=51   fail=0
...
断言 998 条，失败 0 条
```

### 性能改动

- 只认 `examples/demo/示范工程.fxproj`（103 节点 / 192×108 / 60 帧）。
  **不许**用小案例、空图或 `image.solid` 报「快了 10 倍」。
- PR 里给**改前 / 改后**两个数字，注明机器与是否带显示。
- 带显示的探针（`tests/_probe_*.gd`）会真的加载 103 节点工程并播放，
  看起来像卡死是正常的；提交前请自己跑一遍，别在 CI 或别人机器上盲跑。

---

## 5. 写一个插件

最小插件只有两个文件：

```
plugins/my.thing/
├── plugin.json     # id / name / version / inject / runtime_plugin
└── plugin.gd       # extends FxPlugin，按需覆盖贡献方法
```

```gdscript
extends FxPlugin

func nodes() -> Array[String]:
	return ["nodes.json"]

func ops() -> Dictionary:
	return {&"my.op": MyOps.run}
```

步骤与字段说明见 **[docs/插件开发手册.md](docs/插件开发手册.md)**。提交前自检：

- [ ] 停用这个插件，工作台仍能启动、其余功能不受影响
- [ ] 重新启用后能力完整恢复（账本能撤回干净）
- [ ] 没有在基座里留下自己的类名或 id
- [ ] 素材放 `plugins/<id>/assets/`（带 `.gdignore`），用 `FxResourceRoot.resolve()`
- [ ] 至少一条断言覆盖它的贡献

---

## 6. 提交与 PR

- 一个 PR 一件事。重构和功能分开，**不要混在同一个 diff 里**。
- 提交信息用中文或英文都行，格式：`模块: 做了什么`（例：`render: 播放档急件不再标绿`）。
- PR 描述里写清：**动机 / 改了什么 / 怎么验证的（命令 + 数字）**。
- 不要提交 `.godot/`、`dist/`、`fx_cache/`、导出产物、以及编辑器自动生成的备份文件
  （`examples/demo/示范工程/示范工程_*.fxgraph`）。
- 不要为了让测试过而放宽断言；要改语义就同时改断言并说明理由。

---

## 7. 常见坑

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 无头报 `not declared in the current scope` | 新增/移动了 `class_name` 脚本，类缓存没重建 | `godot --headless --path . --editor --quit` |
| 计数器在 lambda 里永远是 0 | GDScript 的 lambda 对 `int` 是**值捕获** | 把计数放进 `Array` / `Dictionary` |
| `Invalid operands 'Vector2' and 'Array'` | 跨类型 `!=` 直接抛错 | 先 `typeof` 短路再比较 |
| 改了 `.gd` 但 Python 脚本改坏了缩进 | 仓库里的 `.gd` 是 CRLF | 按行处理时 `rstrip('\r')`，跨行 lambda 头单独处理 |
| 播放时标尺有绿格但画面是糊的 | 把播放档（quality=0）结果当精确帧归档了 | 归档时看「算它的那一档质量」，不是「此刻在不在播」 |
| 停播后画面回退到旧帧 | 在途旧 job 覆盖了新画面 | 结果必须带 `epoch + doc_key`，不匹配整个丢弃 |

---

## 8. 行为准则

- 对事不对人。review 里可以尖锐，但不许人身攻击。
- 不确定就先开 issue 讨论，别憋一个 2000 行的 PR。
- 别人的时间也是时间：PR 描述写清楚，能省掉三轮来回。

---

<div align="center">
  <sub>MIT © 幻像工坊 contributors</sub>
</div>

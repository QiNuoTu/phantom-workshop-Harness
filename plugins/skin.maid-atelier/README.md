# 深海女仆工坊（皮肤插件）

由 `smalltailqwq/dsh-client-ui-skin-maid-atelier` **移植概念**而来，不是代码直译：
原插件是 Cordis/React 的 Web 客户端皮肤（注入 CSS/DOM），这里是 Godot 的 `FxSkin`
子类 + 版本化选项协议。

## 移植了什么

- 配色：深海蓝 `#0b1b33`、陶瓷白 `#f4f1e8`、长春花蓝 `#8a9cff`、柔金 `#c5a468`；
  亮 / 暗两套变体。
- 版本化自定义选项协议 v2（对应原 `exposeSkinCustomization()`）：
  `variant`、`background_brightness`、`show_lace`、`simple_process`、
  `banner_height`、`accent`、`accent_targets`（带 `visibleWhen`）、`sfw_schedule`。
- **分层贴图映射**（本轮新增）：宫殿背景（亮/暗）、双女仆立绘、Q 版侧栏、
  顶部蕾丝、底部花边带与纹章、侧栏垂幔，按 `docs/preview.webp` 的构图还原。
  新增选项：`show_artwork / show_characters / show_trim / show_chibi / show_swag /
  artwork_opacity / character_opacity / character_scale`。
- 没有贴图包时自动回落到 `FxMaidLace` 自绘几何花边 + 不透明面板，软件照常可用。

## 贴图是怎么进软件的（外部资源根）

贴图**不打进 PCK**，而是作为可安装 / 可卸载的外部资源包：

```
assets/
  manifest.json          语义名 → 原包 hash 文件名的映射与体积
  palace_light.webp      亮色宫殿背景
  palace_dark.webp       暗色宫殿背景
  maid_left.webp         左立绘（透明背景）
  maid_right.webp        右立绘（透明背景）
  chibi.webp             Q 版侧栏
  top_lace.webp          顶部蕾丝
  bottom_trim.webp       底部花边带
  crest.webp             底部金色纹章
  swag.webp              侧栏垂幔
  lace_tile.png          蕾丝重复纹理
  settings_frame.webp    设置框装饰
  preview.webp           原 Web 皮肤整体效果截图（构图参考 / 管理器预览）
  NOTICE.md              完整署名链
  LICENSE-ARTWORK.txt    CC BY-NC-SA 4.0 正文
  .gdignore              让 Godot 不把该目录打进 PCK
```

运行时顺序：`skins()` entry 声明 `texture_root` + `textures` 映射 →
`FxShell._apply_skin()` 调 `FxSkinTextureLibrary.load_set()` →
`FxResourceRoot.resolve()` 按 `res://` → `<exe 同级>` → `user://` → 附加根 找文件 →
`Image.load_from_file()`（WebP/PNG）→ `ImageTexture` → `skin.set_textures()` →
`skin.texture_layers` 声明式布局 → 通用 `FxSkinTextureLayer` 绘制。

`tools/package_windows.gd` 会把 `plugins/skin.maid-atelier/assets/` 原样镜像到便携目录。
**删掉该目录，皮肤自动降级为纯色 + 自绘花边，不会崩。**

`preview.webp` 是合成后的效果图，不能直接当分层贴图用，因此只用于构图参考与
皮肤管理器的预览卡片；运行时用的是上面这些原始分层素材。

## 许可与署名（重要）

原包代码为 MIT；**全部美术资源（AI 生成及加工的图片、ICO）为
CC BY-NC-SA 4.0，禁止商业性使用**，完整创作链见 `assets/NOTICE.md`：

1. 一创「上善」—— 鲸鱼娘角色形象原作者（Pixiv 62155430）；
2. 二创「ZipZipPipe」—— 加入 DeepSeek 元素的女仆鲸鱼娘二次设计（Pixiv 18604994）；
3. 三创「Small-tailqwq」—— DeepSeek 元素再设计。

本轮按使用要求，把原包 `assets/runtime/` 的分层素材**语义化重命名**后放入上述外部
资源根，并随附完整署名链与许可正文。它们**仅作为可卸载的外部资源提供，未打进 PCK**。

> 商业发行前必须移除整个 `plugins/skin.maid-atelier/assets/` 目录；届时皮肤自动回落到
> 自绘几何花边（本文件与布局代码只是 MIT 概念移植，不含受许可约束的图片字节）。

## 使用

「窗口 → 皮肤管理…」（`Ctrl+Shift+K`）打开管理器 → 选择「深海女仆工坊」→
右侧顶部可看到效果预览图，下面调整选项。选项按 skinId 持久化到 `user://layout.cfg`。

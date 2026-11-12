# 第三方素材与许可

本仓库的**代码**以 [MIT](LICENSE) 发布。下面这些目录里的美术与字体资源来自第三方，
各自遵循原许可 —— MIT **不覆盖**它们。

它们都是**可卸载的外部资源**：目录里带 `.gdignore`，不打进 PCK，运行期按
「内置 → 便携 → 用户」三个插件根扫描。删掉对应目录软件照常启动。

| 路径 | 来源 | 许可 | 说明 |
| --- | --- | --- | --- |
| `plugins/core.asset/assets/handcrafted/**` | [patch-gg/pixelfx](https://github.com/patch-gg/pixelfx) | **MIT** | 244 套手绘像素特效素材；上游 README 明确「code and effects, MIT, commercial included」 |
| `plugins/core.text/assets/fonts/HarmonyOS Sans/**` | HarmonyOS Sans | **HarmonyOS Sans Font License** | 目录内自带 `LICENSE.txt`，分发时请原样保留 |
| `plugins/skin.maid-atelier/assets/**` | 见该目录 `NOTICE.md` | **CC BY-NC-SA 4.0** | 三层衍生：上善（鲸鱼娘）→ ZipZipPipe（女仆鲸鱼娘）→ Small-tailqwq（本皮肤）。**禁止商业使用**；商业发行前请删除整个目录 |

## 商业发行注意

- `skin.maid-atelier` 的美术是 **CC BY-NC-SA 4.0**：可以自由分享、修改，
  但**不得用于商业目的**，且衍生作品必须同样以 CC BY-NC-SA 4.0 发布。
  需要商业发行时：删除 `plugins/skin.maid-atelier/assets/`（皮肤会自动回落为纯色/几何装饰，不会崩）。
- HarmonyOS Sans 允许免费商用，但要求随附许可文本；`LICENSE.txt` 已随目录提供，请勿删除。
- pixelfx 为 MIT，保留其署名即可。

## 素材替换

想换成自己的素材：把文件放进对应插件的 `assets/` 下，或用
`FxResourceRoot` 注册新的资源根；插件中心里停用不用的素材插件即可。

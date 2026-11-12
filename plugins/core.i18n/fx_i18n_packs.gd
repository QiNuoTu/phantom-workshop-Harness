class_name FxI18nPacks
extends RefCounted
## 软件界面文案（外壳 chrome）的译文。
##
## 这里**只放基座自己显示的文案**：菜单栏、工具栏、停靠标签、窗口壳、布局动作、
## 状态栏。任何插件注册的东西（面板标题、设置项、命令、皮肤名、节点名……）的译文
## 属于那个插件自己，放在 `plugins/<id>/locales/<locale>.json`，由插件宿主在加载时
## 自动登记——基座不认识具体插件，core.i18n 也永远不会去读别的插件目录。

const EN := {
	"幻像工坊 · 插件化工作台": "Phantom Workshop · Plugin Workbench",
	"窗口": "Window",
	"视图": "View",
	"文件": "File",
	"播放": "Playback",
	"暂停": "Pause",
	"导出": "Export",
	"皮肤": "Skin",
	"全部重新停靠": "Redock all",
	"全部展开": "Expand all",
	"全部折叠": "Collapse all",
	"折叠": "Collapse",
	"重置布局": "Reset layout",
	"停靠样式": "Dock style",
	"默认": "Default",
	"默认深色": "Default dark",
	"工具栏": "Toolbar",
	"精简": "Compact",
	"完整": "Full",
	"隐藏": "Hidden",
	"左侧": "Left",
	"中央": "Center",
	"右侧": "Right",
	"底部": "Bottom",
	"⧉ 分离为浮动窗口": "⧉ Detach to floating window",
	"× 关闭此面板": "× Close panel",
	"面板操作与插件注入功能": "Panel actions & injected features",
	"⧉ 分离": "⧉ Detach",
	"⤓ 停靠": "⤓ Redock",
	"重新停靠到原来的区域": "Redock to original area",
}

const JA := {
	"幻像工坊 · 插件化工作台": "幻像工房 · プラグインワークベンチ",
	"窗口": "ウィンドウ",
	"视图": "表示",
	"文件": "ファイル",
	"播放": "再生",
	"暂停": "一時停止",
	"导出": "書き出し",
	"皮肤": "スキン",
	"全部重新停靠": "すべて再ドック",
	"折叠": "折りたたむ",
	"重置布局": "レイアウトをリセット",
	"停靠样式": "ドックスタイル",
	"默认": "既定",
	"默认深色": "既定（ダーク）",
	"工具栏": "ツールバー",
	"精简": "コンパクト",
	"完整": "全表示",
	"隐藏": "非表示",
	"左侧": "左",
	"中央": "中央",
	"右侧": "右",
	"底部": "下",
	"⧉ 分离": "⧉ 分離",
	"⤓ 停靠": "⤓ 再ドック",
}

static func locales() -> Array[Dictionary]:
	# 语言清单与「源语言」定义；en_US / ja_JP 只含基座界面词条。
	# 各插件会在同一 locale 上叠加自己目录里的包（FxI18n 按 order 合并）。
	return [
		{"locale": "zh_CN", "name": "简体中文（源语言）", "entries": {}, "order": 0},
		{"locale": "en_US", "name": "English (US)", "entries": EN, "order": 10},
		{"locale": "ja_JP", "name": "日本語", "entries": JA, "order": 20},
	]

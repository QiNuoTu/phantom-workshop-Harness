#!/usr/bin/env python3
"""文档与代码的一致性检查（零依赖，只读）。

背景：这个仓库的说明文字长期滞后于代码 —— 版本号、插件数、断言数、代码行数
在 README / README.en / docs 里各写一份，改代码时没人回头改字。
于是「文档说了什么」和「代码是什么」只能靠人肉比，比漏一次就变成对外承诺失真。

这个脚本做一件事：**从代码实测取数，再回到文档里找出对不上的那一处**。
不修文档、不改代码，只报告并给非零退出码，供 CI 或发布闸门使用。

用法：
    python tools/check_docs.py            # 报告偏差
    python tools/check_docs.py --quiet    # 只输出结论行

退出码：0 全部一致 / 1 有偏差 / 2 环境不满足
"""

import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# 只列**当前**文档。归档（docs/归档/）故意不在表里：那里的数字本来就作废，
# 拿它们对门禁等于把历史欠债当现行标准。
DOC_FILES = [
    "README.md",
    "README.en.md",
    "docs/README.md",
    "docs/架构.md",
    "docs/插件开发.md",
    "docs/诊断与归因.md",
    "docs/性能口径.md",
    "docs/版本策略.md",
    "docs/路线与缺口.md",
    "CLAUDE.md",
    "CONTRIBUTING.md",
]


def read(path):
    full = os.path.join(ROOT, path)
    if not os.path.isfile(full):
        return None
    with open(full, encoding="utf-8") as handle:
        return handle.read()


# ---------------- 事实来源：代码 ----------------

def facts():
    out = {}

    with open(os.path.join(ROOT, "version.json"), encoding="utf-8") as handle:
        versions = json.load(handle)
    out["app"] = versions.get("app", "?")
    out["kernel"] = versions.get("kernel", "?")
    out["project_format"] = versions.get("project_format", "?")

    # 插件：有 plugin.json 的目录才算插件；没有的是一个值得单独报的缺陷。
    plugin_dirs = sorted(
        name for name in os.listdir(os.path.join(ROOT, "plugins"))
        if os.path.isdir(os.path.join(ROOT, "plugins", name))
    )
    manifests = [d for d in plugin_dirs
                 if os.path.isfile(os.path.join(ROOT, "plugins", d, "plugin.json"))]
    out["plugins"] = len(manifests)
    out["plugin_orphans"] = [d for d in plugin_dirs if d not in manifests]

    # 版本号一致性：每个插件都该在契约区间内，且自己的版本号别偷偷写成 1.0。
    plugin_versions = {}
    for d in manifests:
        with open(os.path.join(ROOT, "plugins", d, "plugin.json"), encoding="utf-8") as handle:
            plugin_versions[d] = json.load(handle).get("version", "?")
    out["plugin_versions"] = plugin_versions

    nodes = 0
    ops = set()
    for path in glob.glob(os.path.join(ROOT, "plugins", "*", "nodes*.json")):
        with open(path, encoding="utf-8") as handle:
            try:
                data = json.load(handle)
            except json.JSONDecodeError:
                continue
        for value in data.values() if isinstance(data, dict) else []:
            if isinstance(value, list):
                for item in value:
                    if isinstance(item, dict) and "op" in item:
                        nodes += 1
                        ops.add(item["op"])
    out["nodes"] = nodes
    out["ops"] = len(ops)

    out["suites"] = len(glob.glob(os.path.join(ROOT, "tests", "test_*.gd")))

    # 基座行数：只算 scripts/graph（README 说的「基座 8.9k 行」指这个）。
    kernel_lines = 0
    for path in glob.glob(os.path.join(ROOT, "scripts", "**", "*.gd"), recursive=True):
        with open(path, encoding="utf-8", errors="replace") as handle:
            kernel_lines += sum(1 for _ in handle)
    out["kernel_lines"] = kernel_lines
    out["kernel_k"] = round(kernel_lines / 1000.0, 1)

    # 断言数没法静态数出来，只能读上一次回归的结论文件。
    report = os.path.join(ROOT, "tools", ".last_tests.json")
    if os.path.isfile(report):
        with open(report, encoding="utf-8") as handle:
            out["assertions"] = json.load(handle).get("assertions")
    else:
        out["assertions"] = None
    return out


# ---------------- 文档声明：正则 ----------------
# 每条规则：(名字, 正则, 匹配组里取出比对的数字, 事实键)
RULES = [
    ("版本号", re.compile(r"\b(\d+\.\d+\.\d+(?:-(?:alpha|beta))?)\b"), None, None),
    ("断言数(徽章)", re.compile(r"断言-(\d+)"), 1, "assertions"),
    ("assertions(徽章)", re.compile(r"assertions-(\d+)"), 1, "assertions"),
    # 「97 条断言」可能说的是某个套件，正文断言必须带「回归/全绿」上下文
    ("断言数(正文)", re.compile(r"回归[^。\n]{0,16}?(\d+)\s*条?断言|(\d+)\s*条?断言[^。\n]{0,8}?全绿"), None, "assertions"),
    ("插件数(正文)", re.compile(r"(\d+)\s*个插件"), 1, "plugins"),
    ("插件数(徽章)", re.compile(r"plugins-(\d+)"), 1, "plugins"),
    ("插件清单数", re.compile(r"(\d+)\s*个\s*`?plugin\.json"), 1, "plugins"),
    ("插件数(英文)", re.compile(r"(\d+)\s*plugins\b"), 1, "plugins"),
    ("节点数(徽章)", re.compile(r"节点-(\d+)"), 1, "nodes"),
    ("节点数(英文徽章)", re.compile(r"nodes-(\d+)"), 1, "nodes"),
    # 行数必须紧跟「基座 / Kernel」，否则插件层的「31k 行」也会被当成基座
    # 「内核」「基座」「Kernel」三种叫法都要认：README 的表格里写的是「内核」,
    # 从前只认后两个，于是 9.2k 挂了很久没人红。
    ("基座行数", re.compile(r"(?:基座|内核|Kernel)[^|\n]{0,48}?(\d+(?:\.\d+)?)k\s*(?:行|lines)"), 1, "kernel_k"),
    # 「套」这个量词在中文里到处用（素材 244 套、皮肤 4 套），必须带「回归」上下文。
    ("回归套数", re.compile(r"回归[^。\n]{0,12}?(\d+)\s*套|(\d+)\s*套[^。\n]{0,8}?回归"), None, "suites"),
]

## 这些行讲的是历史或对比，不是「现在是什么」，跳过 —— 否则版本策略的变动记录
## 会被逐条报成偏差，噪声淹掉真问题。
HISTORICAL = ("之前", "历史", "当时", "上一版", "曾经", "已撤回", "旧版", "v0.1.0 时期",
              "改为", "→", "不集体", "没改公开贡献")
## 版本号只在「说当前」的句子里比对。
CURRENT_HINT = re.compile(r"当前状态|当前值|当前版本|Current (?:status|version)|现在")


def scan(fact):
    problems = []
    for name in DOC_FILES:
        text = read(name)
        if text is None:
            continue
        for lineno, line in enumerate(text.splitlines(), 1):
            if any(marker in line for marker in HISTORICAL):
                continue
            for label, pattern, group, key in RULES:
                if key is None:
                    continue
                expected = fact.get(key)
                if expected is None:
                    continue
                for match in pattern.finditer(line):
                    found = match.group(group) if group else next(
                        (g for g in match.groups() if g is not None), None)
                    if found is None:
                        continue
                    if label == "基座行数" or label == "kernel lines":
                        if abs(float(found) - float(expected)) > 0.05:
                            problems.append((name, lineno, label, found, expected))
                    elif "断言" in label or "assertions" in label:
                        # 徽章上的断言数是**下限**，不是快照：套件里有几条断言依赖
                        # 运行期条件（例如某个导出样本恰好在盘上），总数在
                        # 1357–1359 之间浮动。写成精确相等会变成「跑一次红一次」的
                        # 假门禁。仓库的硬规则是「断言总数不能减少」，所以只判方向。
                        if int(float(found)) > int(float(expected)):
                            problems.append((name, lineno, label + "(应≤实际)", found, expected))
                    elif str(found) != str(expected):
                        problems.append((name, lineno, label, found, expected))
    return problems


def version_drift(fact):
    """只比对「说当前版本」的句子；变动记录里的旧版本号是事实，不是偏差。"""
    problems = []
    current = str(fact["app"])
    pattern = re.compile(r"\b\d+\.\d+\.\d+-alpha\b")
    # 版本策略里的当前值是 json 块，下一行才出现号：`{"app": "0.0.9-alpha", ...}`
    json_app = re.compile(r"\"app\"\s*:\s*\"([^\"]+)\"")
    for name in DOC_FILES:
        text = read(name)
        if text is None:
            continue
        for lineno, line in enumerate(text.splitlines(), 1):
            for match in json_app.finditer(line):
                if match.group(1) != current:
                    problems.append((name, lineno, "app 版本号(json)", match.group(1), current))
            if not CURRENT_HINT.search(line):
                continue
            for match in pattern.finditer(line):
                if match.group(0) != current:
                    problems.append((name, lineno, "app 版本号", match.group(0), current))
    return problems


# ---------------- 链接：相对路径必须存在 ----------------
# 文档重组（改名 / 归档 / 删文件）最常留下的不是错字，是**指向已不存在的文件**的链接。
# 这类问题 IDE 不一定报、渲染出来只是一个死链，读者点一下才发现。
LINK_RE = re.compile(r"\]\(([^)\s]+)\)|src=\"([^\"]+)\"")
SKIP_SCHEMES = ("http://", "https://", "mailto:", "#", "data:")


def doc_files():
    """当前文档 + 归档：归档也要查链接（它最容易指向被删掉的文件）。"""
    out = list(DOC_FILES)
    archive = os.path.join(ROOT, "docs")
    for base, _dirs, files in os.walk(archive):
        for name in files:
            if name.endswith(".md"):
                rel = os.path.relpath(os.path.join(base, name), ROOT).replace(os.sep, "/")
                if rel not in out:
                    out.append(rel)
    return out


def broken_links():
    problems = []
    for rel in doc_files():
        text = read(rel)
        if text is None:
            continue
        base = os.path.dirname(os.path.join(ROOT, rel))
        for lineno, line in enumerate(text.splitlines(), 1):
            for match in LINK_RE.finditer(line):
                target = match.group(1) or match.group(2) or ""
                target = target.strip()
                if not target or target.startswith(SKIP_SCHEMES):
                    continue
                path = target.split("#", 1)[0].strip()
                if not path:
                    continue
                resolved = os.path.normpath(os.path.join(base, path))
                if not os.path.exists(resolved):
                    problems.append((rel, lineno, "链接目标不存在", target, "-"))
    return problems


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except AttributeError:
        pass
    quiet = "--quiet" in sys.argv

    fact = facts()
    problems = scan(fact)
    problems += version_drift(fact)
    links = broken_links()

    # 孤儿目录与插件版本是结构性问题，单独报，不混进「文档偏差」。
    structural = []
    for orphan in fact["plugin_orphans"]:
        structural.append(("plugins/%s/" % orphan, 0,
                           "缺 plugin.json（会被宿主扫描并报启动错误）", "缺失", "plugin.json"))
    for pid, version in fact["plugin_versions"].items():
        if version.startswith("1."):
            structural.append(("plugins/%s/plugin.json" % pid, 0,
                               "插件版本虚高", version, "0.x"))

    if not quiet:
        print("== 文档一致性检查 ==")
        print("事实：app %s / kernel %s / format %s / 插件 %d / 节点 %d / 算子 %d / 套件 %d / 基座 %s 行"
              % (fact["app"], fact["kernel"], fact["project_format"], fact["plugins"],
                 fact["nodes"], fact["ops"], fact["suites"], fact["kernel_lines"]))
        if fact["assertions"] is None:
            print("断言数：未找到 tools/.last_tests.json（跑一次回归即可生成），本条跳过")
        print("")

        if problems:
            print("文档偏差 %d 处：" % len(problems))
            for path, lineno, label, found, expected in problems:
                where = "%s:%d" % (path, lineno) if lineno else path
                print("  ✗ %-28s %-14s 写了 %s，实际 %s" % (where, label, found, expected))
        else:
            print("文档偏差：0 处")

        if structural:
            print("")
            print("结构问题 %d 处：" % len(structural))
            for path, _, label, found, expected in structural:
                print("  ✗ %-28s %-40s 当前 %s，应为 %s" % (path, label, found, expected))

        if links:
            print("")
            print("失效链接 %d 处：" % len(links))
            for path, lineno, label, found, _expected in links:
                print("  ✗ %-28s %-14s %s" % ("%s:%d" % (path, lineno), label, found))
        else:
            print("")
            print("失效链接：0 处")

    bad = len(problems) + len(structural) + len(links)
    print("----")
    print("结论：%s（偏差 %d 处 / 失效链接 %d 处）"
          % ("一致" if bad == 0 else "不一致", len(problems) + len(structural), len(links)))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

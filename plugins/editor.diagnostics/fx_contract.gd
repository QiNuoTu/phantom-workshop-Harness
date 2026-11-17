class_name FxContract
extends RefCounted
## 版本约束：内核契约、插件、工程格式各用一套版本号，谁都不冒充谁。
##
## 为什么需要它：`provide` 里写的 "1.0" 只是字符串，依赖只按**键名**匹配，
## 于是「接口改了但键没改」在运行时才不会报错（论文 §6.6 interface drift）。
## 这里给出一个可执行的最小约束语法，供诊断工具与插件宿主共用。
##
## 支持语法（空格分隔多条，全部满足才算通过）：
##   "*" / ""          不约束
##   "0.1.0"           精确相等
##   ">=0.1.0"         比较
##   "<0.2.0"
##   "^0.1.0"          0.x 锁次版本（>=0.1.0 <0.2.0）；>=1.0 锁主版本
##   "~1.2.3"          锁次版本（>=1.2.3 <1.3.0）
##
## 只看数字段：预发布后缀（-alpha / -beta）参与显示，不参与比较。

const WILDCARD := "*"


## "0.1.0-alpha" -> [0, 1, 0]
static func parse(text: String) -> Array:
	var clean := text.strip_edges()
	if clean.begins_with("v") or clean.begins_with("V"):
		clean = clean.substr(1)
	var dash := clean.find("-")
	if dash >= 0:
		clean = clean.substr(0, dash)
	var plus := clean.find("+")
	if plus >= 0:
		clean = clean.substr(0, plus)
	var parts := clean.split(".", false)
	var out: Array = []
	for i in range(3):
		var piece := String(parts[i]) if i < parts.size() else "0"
		out.append(int(piece) if piece.is_valid_int() else 0)
	return out


## -1 / 0 / 1
static func compare(a: String, b: String) -> int:
	var left := parse(a)
	var right := parse(b)
	for i in range(3):
		var x := int(left[i])
		var y := int(right[i])
		if x == y:
			continue
		return 1 if x > y else -1
	return 0


static func is_valid(text: String) -> bool:
	var clean := text.strip_edges().trim_prefix("v")
	if clean.is_empty():
		return false
	var parts := clean.split(".", false)
	if parts.is_empty() or parts.size() > 3:
		return false
	for piece in parts:
		if not String(piece).is_valid_int():
			return false
	return true


## 版本是否落在约束表达式的允许区间里。
static func satisfies(version: String, expr: String) -> bool:
	var text := expr.strip_edges()
	if text.is_empty() or text == WILDCARD:
		return true
	# 允许写成 ">=0.1.0 <0.2.0" 或 ">=0.1.0,<0.2.0"
	text = text.replace(",", " ")
	for clause in text.split(" ", false):
		if not _clause(version, String(clause).strip_edges()):
			return false
	return true


static func _clause(version: String, clause: String) -> bool:
	if clause.is_empty() or clause == WILDCARD:
		return true
	for op in [">=", "<=", ">", "<", "=", "^", "~"]:
		if clause.begins_with(op):
			var target := clause.substr(op.length()).strip_edges()
			if not is_valid(target):
				return false
			return _compare_clause(version, target, op)
	# 裸版本号视为精确相等
	return is_valid(clause) and compare(version, clause) == 0


static func _compare_clause(version: String, target: String, op: String) -> bool:
	var cmp := compare(version, target)
	match op:
		">=":
			return cmp >= 0
		"<=":
			return cmp <= 0
		">":
			return cmp > 0
		"<":
			return cmp < 0
		"=":
			return cmp == 0
		"^":
			return cmp >= 0 and compare(version, upper_bound(target, true)) < 0
		"~":
			return cmp >= 0 and compare(version, upper_bound(target, false)) < 0
	return false


## 上界：caret 在 0.x 时锁次版本（0.1.0 -> 0.2.0），否则锁主版本（1.2.3 -> 2.0.0）；
## tilde 一律锁次版本（1.2.3 -> 1.3.0）。
static func upper_bound(target: String, caret: bool) -> String:
	var v := parse(target)
	var major := int(v[0])
	var minor := int(v[1])
	if caret and major > 0:
		return "%d.0.0" % (major + 1)
	return "%d.%d.0" % [major, minor + 1]


## 便于在诊断里显示：把约束说成一句人话。
static func describe(expr: String) -> String:
	var text := expr.strip_edges()
	if text.is_empty() or text == WILDCARD:
		return "任意版本"
	return text

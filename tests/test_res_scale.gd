extends SceneTree
## 逐层分辨率档（res_scale）：把「按 AE 逻辑降分辨率换性能」钉成可复算的断言。
##
## 语义（见 FxGraphDoc.res_scale_of 的注释）：
##   声明者 N(s) 要求「N 及其全部上游」按 s 求值，输出在交给下游时还原到下游的空间。
##   传播遇另一个声明者即停 —— 区段模型，对应 AE 的「每个图层一个分辨率」。
##
## 这里钉的四件事，少一件这个功能就是不可信的：
##   1. 没声明时**逐像素**等于旧行为（不是「差不多」）；
##   2. 降档后**输出尺寸不变**（否则交付的画面就小了，「所见即所得」破了）；
##   3. 输出节点 / 汇点**拒绝**声明（防的是导出文件变小）；
##   4. 共享上游**不被拖下水**（一条旁支降档不能悄悄拉低主干精度）。
##
## 运行：
##   godot --headless --path . --script res://tests/test_res_scale.gd

var failures: Array[String] = []


func _initialize() -> void:
	print("== 逐层分辨率档测试 ==")
	FxPluginHost.ensure()
	FxCatalog.ensure_loaded()

	_test_doc_api()
	_test_no_declaration_is_identical()
	_test_declaration_keeps_output_size()
	_test_sink_refuses()
	_test_section_boundary()
	_test_shared_upstream()

	print("-- 逐层分辨率档：%d 条断言，%d 条失败" % [_count, failures.size()])
	for item in failures:
		print("FAIL: %s" % item)
	_quit(0 if failures.is_empty() else 1)


var _count: int = 0


## ---- 1. 文档层：倍率是「倍率」不是「档位号」 ----
func _test_doc_api() -> void:
	_check(FxGraphDoc.res_scale_of({}) == 1.0, "没写 res_scale 时是全分辨率")
	_check(FxGraphDoc.res_scale_of({"res_scale": 1.0}) == 1.0, "显式 1.0 等于没声明")
	_check(is_equal_approx(FxGraphDoc.res_scale_of({"res_scale": 0.5}), 0.5),
		"0.5 就是「边长一半」（像素成本 1/4）")
	_check(FxGraphDoc.res_scale_of({"res_scale": 0.0}) == 1.0, "0 视为未声明，不是「全缩没」")
	_check(FxGraphDoc.res_scale_of({"res_scale": -2.0}) == 1.0, "负数是垃圾值，回落到 1.0")
	_check(is_equal_approx(FxGraphDoc.res_scale_of({"res_scale": 0.01}), 0.125),
		"过小的值夹到下限 0.125（再小就没法判断画面）")
	_check(FxGraphDoc.res_scale_of({"res_scale": "half"}) == 1.0,
		"字符串垃圾值回落到 1.0，不崩")
	_check(FxGraphDoc.has_res_scale({"res_scale": 0.5})
			and not FxGraphDoc.has_res_scale({"res_scale": 1.0}),
		"has_res_scale 只认真的降了档的节点")

	# 像素单位的参数必须跟着档位换算，否则「降画质」变成「改效果」。
	# 判据是 nodes.json 里已有的 `unit: "px"`，基座不认识具体参数名。
	var doc := _chain({"blur": 0.5})
	(doc["nodes"] as Array)[1]["params"]["radius"] = 4.0
	var runner := FxGraphRunner.new()
	var result := runner.run(doc, 0.0)
	var params: Dictionary = (result.get("node_params", {}) as Dictionary).get("blur", {})
	_check(int(params.get("radius", -1)) == 2,
		"0.5 档下 radius=4 换成 2（看起来一样的糊度，实得 %s）" % str(params.get("radius")))
	var plain_runner := FxGraphRunner.new()
	var plain := plain_runner.run(_chain({}), 0.0)
	var plain_blur: Dictionary = (plain.get("node_params", {}) as Dictionary).get("blur", {})
	_check(int(plain_blur.get("radius", -1)) == 1,
		"全分辨率下 radius 不被改动（旧行为逐字不变）")


## ---- 2. 没声明 = 与旧行为逐像素一致 ----
func _test_no_declaration_is_identical() -> void:
	var plain := _chain({})
	var explicit := _chain({"blur": 1.0})
	var a := _render(plain)
	var b := _render(explicit)
	_check(a != null and b != null, "两条链都能渲染")
	if a == null or b == null:
		return
	_check(_same_pixels(a, b), "缺省与显式 1.0 逐像素相同（写 1.0 不该改变画面）")
	var report: Dictionary = _report(plain)
	_check((report.get("effective", {}) as Dictionary).is_empty(),
		"没有声明时没有任何节点生效降档（这条路径零成本）")


## ---- 3. 声明 0.5：上游跟着降，输出尺寸不变 ----
func _test_declaration_keeps_output_size() -> void:
	var full := _chain({})
	var half := _chain({"blur": 0.5})
	var a := _render(full)
	var b := _render(half)
	if a == null or b == null:
		_check(false, "降档链能渲染")
		return
	_check(b.get_width() == a.get_width() and b.get_height() == a.get_height(),
		"降档后输出仍是 %dx%d（实得 %dx%d）" % [a.get_width(), a.get_height(),
			b.get_width(), b.get_height()])
	var effective: Dictionary = (_report(half).get("effective", {}) as Dictionary)
	_check(effective.has("blur"), "声明者自己在该档求值")
	_check(is_equal_approx(float(effective.get("grad", 1.0)), 0.5),
		"上游 grad 跟着降（这才省得到上游成本）")
	_check(not effective.has("tint"), "输出节点不降档（tint 仍是全分辨率）")
	# 纯缩放误差（这条链没有像素单位的参数）：平均差应该很小。
	var diff := _mean_diff(a, b)
	_check(diff < 8.0, "0.5 档的画质损失在可接受范围（平均差 %.2f/255）" % diff)
	_check(diff > 0.0001, "确实走了降采样路径（不是「设了没生效」）")


## ---- 4. 汇点 / 输出节点拒绝声明 ----
func _test_sink_refuses() -> void:
	var doc := _chain({"tint": 0.25})
	var report: Dictionary = _report(doc)
	_check((report.get("refused", []) as Array).has("tint"),
		"输出节点拒绝分辨率档（否则交付的画面就不是全尺寸）")
	_check(not (report.get("effective", {}) as Dictionary).has("tint"),
		"被拒绝的节点不出现在生效列表里")


## ---- 5. 区段边界：上游的声明不被下游的声明覆盖 ----
func _test_section_boundary() -> void:
	# grad -0.25-> blur -0.5-> tint(out)
	var doc := _chain({"grad": 0.25, "blur": 0.5})
	var effective: Dictionary = (_report(doc).get("effective", {}) as Dictionary)
	_check(is_equal_approx(float(effective.get("grad", 1.0)), 0.25),
		"grad 保留自己声明的 0.25（下游的 0.5 不覆盖它）")
	_check(is_equal_approx(float(effective.get("blur", 1.0)), 0.5),
		"blur 按自己声明的 0.5 求值")
	var image := _render(doc)
	_check(image != null and image.get_width() == 128,
		"两段降档串联后输出仍是 128 宽（尺寸不会累积错）")


## ---- 6. 共享上游：旁支降档不能拉低主干精度 ----
func _test_shared_upstream() -> void:
	# grad 同时供给 blur(0.5，旁支) 与 tint(主干，1.0)
	var doc := FxGraphDoc.create("共享上游")
	_add_node(doc, "grad", "image.gradient", {})
	_add_node(doc, "blur", "image.blur", {"radius": 1.0}, 0.5)
	_add_node(doc, "tint", "image.tint", {"amount": 1.0})
	_link(doc, "grad", "image", "blur", "image")
	_link(doc, "grad", "image", "tint", "image")
	doc["output"] = "tint"
	var effective: Dictionary = (_report(doc).get("effective", {}) as Dictionary)
	_check(not effective.has("grad") or float(effective.get("grad", 1.0)) >= 0.999,
		"grad 还被全分辨率主干消费，所以按 1.0 算（实得 %s）"
			% str(effective.get("grad", 1.0)))
	_check(is_equal_approx(float(effective.get("blur", 1.0)), 0.5),
		"blur 自己仍按 0.5 求值（在边界缩放上游的大图）")


# ================= 构造 =================

## 一条 3 节点链：grad → blur → tint(out)。scales 给节点 id → 倍率。
func _chain(scales: Dictionary) -> Dictionary:
	var doc := FxGraphDoc.create("分辨率档")
	_add_node(doc, "grad", "image.gradient", {}, float(scales.get("grad", 1.0)))
	_add_node(doc, "blur", "image.blur", {"radius": 1.0}, float(scales.get("blur", 1.0)))
	_add_node(doc, "tint", "image.tint", {"amount": 1.0}, float(scales.get("tint", 1.0)))
	_link(doc, "grad", "image", "blur", "image")
	_link(doc, "blur", "image", "tint", "image")
	doc["output"] = "tint"
	return doc


func _add_node(doc: Dictionary, id: String, type: String, params: Dictionary,
		scale: float = 1.0) -> void:
	var node := {"id": id, "type": type, "params": params}
	if scale < 0.999:
		node["res_scale"] = scale
	(doc["nodes"] as Array).append(node)


func _link(doc: Dictionary, from: String, from_port: String, to: String, to_port: String) -> void:
	(doc["edges"] as Array).append({
		"from": from, "from_port": from_port, "to": to, "to_port": to_port})


func _render(doc: Dictionary) -> Image:
	var runner := FxGraphRunner.new()
	var result := runner.run(doc, 0.0)
	var image: Variant = result.get("image")
	return image if image is Image else null


func _report(doc: Dictionary) -> Dictionary:
	var runner := FxGraphRunner.new()
	runner.run(doc, 0.0)
	return runner.scale_report


# ================= 断言 =================

func _same_pixels(a: Image, b: Image) -> bool:
	if a.get_width() != b.get_width() or a.get_height() != b.get_height():
		return false
	if a.get_format() != b.get_format():
		return false
	return a.get_data() == b.get_data()


func _mean_diff(a: Image, b: Image) -> float:
	if a.get_width() != b.get_width() or a.get_height() != b.get_height():
		return 255.0
	var total := 0.0
	var count := 0
	for y in range(a.get_height()):
		for x in range(a.get_width()):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			total += (absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0
			count += 1
	if count == 0:
		return 0.0
	return total / float(count) * 255.0


func _check(condition: bool, label: String) -> void:
	_count += 1
	if condition:
		print("  ok  %s" % label)
	else:
		failures.append(label)
		print("  FAIL: %s" % label)


func _quit(code: int) -> void:
	# 插件表是静态的：不清就退出，引擎会在 shutdown 阶段崩（而且只看退出码才知道）。
	FxPluginHost.shutdown()
	quit(code)

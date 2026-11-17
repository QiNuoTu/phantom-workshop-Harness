extends SceneTree
## 预览根与独立尺寸：把用户报的四个现象钉成可复算的断言。
##
##   · 生成器节点可以自己定输出尺寸，不必只吃文档画布；
##   · 不连输出的旁支节点也能拿到预览（图像 / 数值都算）；
##   · 数值节点能显示「本帧算出来是多少」；
##   · preview_roots 是**唯一**让旁支进入求值的开关，也就是剪枝的活节点根集合。
##
## 运行：
##   godot --headless --path . --script res://tests/test_preview_roots.gd

var failures: Array[String] = []


func _initialize() -> void:
	print("== 预览根 / 独立尺寸 / 数值读数测试 ==")
	FxPluginHost.ensure()
	FxCatalog.ensure_loaded()
	var doc := FxGraphDoc.create("预览根测试")
	(doc["nodes"] as Array).append({
		"id": "g", "type": "image.gradient",
		"params": {"out_width": 64, "out_height": 32},
	})
	(doc["nodes"] as Array).append({
		"id": "g2", "type": "image.gradient", "params": {},
	})
	(doc["nodes"] as Array).append({
		"id": "m", "type": "math.number",
		"params": {"op": "add", "a": 2.0, "b": 3.0},
	})
	doc["output"] = ""   # 故意不接输出链：三个节点全是「旁支」

	# ---- 1. 生成器自己的尺寸 ----
	var probe := FxGraphRunner.new()
	var g := probe.evaluate_node(doc, "g", 0.0)
	var g_image: Variant = g.get("image")
	_check(g_image is Image, "生成器节点产出 Image")
	if g_image is Image:
		_check((g_image as Image).get_width() == 64
				and (g_image as Image).get_height() == 32,
			"out_width/out_height 生效：64×32，而不是文档画布的 128×128")

	var g2 := probe.evaluate_node(doc, "g2", 0.0)
	var g2_image: Variant = g2.get("image")
	if g2_image is Image:
		_check((g2_image as Image).get_width() == 128
				and (g2_image as Image).get_height() == 128,
			"不填尺寸时保持旧语义：跟随文档画布 128×128（向后兼容）")

	# ---- 2. 没有预览根：旁支不参与求值（这正是剪枝要保留的边界）----
	var bare := FxGraphRunner.new()
	bare.capture_previews = true
	var bare_result := bare.run(doc, 0.0)
	var bare_values: Dictionary = bare_result.get("node_values", {})
	var bare_previews: Dictionary = bare_result.get("previews", {})
	_check(not bare_values.has("m") and not bare_previews.has("g2"),
		"没有预览根时，旁支节点不被求值（不是偶发看不见预览）")

	# ---- 3. 有预览根：图像与数值都能看见 ----
	var rooted := FxGraphRunner.new()
	rooted.capture_previews = true
	rooted.preview_limit = 96
	rooted.preview_roots = ["m", "g2"]
	var result := rooted.run(doc, 0.0)
	var values: Dictionary = result.get("node_values", {})
	var previews: Dictionary = result.get("previews", {})
	_check(previews.has("g2"), "未连输出的图像旁支，进了 preview_roots 就有预览")
	_check(values.has("m"), "未连输出的数值旁支，进了 preview_roots 就有读数")
	if values.has("m"):
		var samples: Array = values["m"] if values["m"] is Array else []
		_check(not samples.is_empty(), "读数是结构化样本数组（不是一行拼好的文本）")
		var sample: Dictionary = samples[0] if not samples.is_empty() else {}
		_check(String(sample.get("type", "")) == "number",
			"样本带端口类型（number），界面据此画曲线而不是一行灰字")
		_check(sample.has("port") and sample.has("value"),
			"样本带端口 id 与原值（界面要按类型自己画）")
		var text := String(sample.get("text", ""))
		_check(text.contains("5"), "数值节点显示 2+3 的结果（实得 %s）" % text)
		_check(not text.contains("{"), "读数是一行短文本，不是整张字典 dumping")
	if not values.has("g2"):
		_check(true, "图像节点不占用数值读数通道")
	else:
		_check(false, "图像节点不该写进数值读数")

	# ---- 4. 有图像输出的节点不会误报「无输出」----
	var with_image := FxGraphRunner.new()
	with_image.capture_previews = true
	with_image.preview_roots = ["g"]
	var r4 := with_image.run(doc, 0.0)
	_check(not (r4.get("node_values", {}) as Dictionary).has("g"),
		"有图像输出的节点不写数值读数")

	# ---- 5. 播放期白名单裁剪不该挡住展开的旁支 ----
	var scoped := FxGraphRunner.new()
	scoped.capture_previews = true
	scoped.preview_nodes = {"out": true}   # 模拟 quality.preview_scope = selection_output
	scoped.preview_roots = ["g2", "m"]
	var r5 := scoped.run(doc, 0.0)
	_check((r5.get("previews", {}) as Dictionary).has("g2"),
		"播放期白名单裁剪下，展开的图像旁支仍有预览")
	_check((r5.get("node_values", {}) as Dictionary).has("m"),
		"播放期白名单裁剪下，展开的数值旁支仍有读数")

	# ---- 6. 关掉小图不该连读数一起关掉 ----
	# capture_previews 省的是「缩小一张图」，读数只是几个 Variant。
	# 旧实现把两者绑死，播放期一关小图，数值节点卡片就整片空白。
	var no_preview := FxGraphRunner.new()
	no_preview.capture_previews = false
	no_preview.preview_roots = ["m", "g2"]
	var r6 := no_preview.run(doc, 0.0)
	_check((r6.get("node_values", {}) as Dictionary).has("m"),
		"capture_previews=false 时数值读数仍然有")
	_check(not (r6.get("previews", {}) as Dictionary).has("g2"),
		"capture_previews=false 时不出小图（开关仍然管用）")

	_quit(0 if failures.is_empty() else 1)


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  ok  ", label)
	else:
		failures.append(label)
		push_error("FAIL: " + label)


func _quit(code: int = 0) -> void:
	FxPluginHost.shutdown()
	quit(code)

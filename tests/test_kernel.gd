extends SceneTree
## 范式内核自测：可逆效果、反应式余效果、撤销/重做。
## 对应论文 Section 3.1 / 3.2 / 5.1。

var failures: Array[String] = []


func _initialize() -> void:
	print("== 范式内核自测 ==")
	_test_effects()
	_test_coeffects()
	_test_retire()
	_test_store_undo()
	print("----")
	if failures.is_empty():
		print("内核自测全部通过")
		_quit(0)
	else:
		print("失败 %d 项：" % failures.size())
		for item in failures:
			print("  - ", item)
		_quit(1)


func _test_effects() -> void:
	var ctx := FxContext.new()
	ctx.set_value("a", 1)
	var disposed := [0]
	var activated := [0]
	var component := FxComponent.make(["a"], func(_c: FxContext, _cfg: Dictionary, scope: FxEffectScope) -> void:
		activated[0] += 1
		scope.add(func() -> void: disposed[0] += 1)
	, Callable(), "probe")
	var fiber := ctx.use(component)
	_check(fiber.active, "依赖满足时组件激活")
	_check(activated[0] == 1, "apply 执行一次")
	ctx.set_value("a", 2)
	_check(fiber.active, "依赖值变化仍保持激活")
	ctx.set_value("a", null)
	_check(not fiber.active, "依赖撤销后组件卸载")
	_check(disposed[0] == 1, "卸载时逆操作执行一次")
	fiber.dispose()
	_check(disposed[0] == 1, "重复卸载不重复执行逆操作")


func _test_coeffects() -> void:
	var ctx := FxContext.new()
	ctx.set_value("x", 0)
	var seen: Array = []
	var component := FxComponent.make(["x"], Callable(),
		func(_c: FxContext, keys: Array) -> void: seen.append(keys.duplicate()), "listener")
	var fiber := ctx.use(component)
	ctx.set_value("x", 1)
	ctx.set_value("y", 9)
	_check(seen.size() == 1, "只有 inject 中的键变化才通知（实际 %d 次）" % seen.size())
	_check(seen.size() > 0 and (seen[0] as Array).has("x"), "通知携带变化的键")
	fiber.dispose()


func _test_retire() -> void:
	var ctx := FxContext.new()
	ctx.set_value("k", 1)
	var runs := [0]
	var component := FxComponent.make([], func(_c: FxContext, _cfg: Dictionary, scope: FxEffectScope) -> void:
		runs[0] += 1
		# 模拟插件：apply 里写一个 coeffect 键，逆操作会 notify 所有 fiber。
		scope.add(ctx.set_value("provided.by.fiber", true))
	, Callable(), "retire probe")
	var fiber := ctx.use(component)
	_check(fiber.active and runs[0] == 1, "无依赖 fiber 激活一次")
	fiber.retire()
	_check(not fiber.active, "O-Retire 把 target 置为 ⊥，fiber 进入 INACTIVE")
	ctx.notify(["k", "provided.by.fiber"])
	ctx.set_value("k", 2)
	_check(not fiber.active and runs[0] == 1, "退休后任何 notify 都不会让它复活")
	fiber.dispose()


func _test_store_undo() -> void:
	# 基座的文档存储只管「可逆效果」：文档长什么样、节点怎么加都是图插件的事。
	# 所以这里用最朴素的字典验证撤销/重做/批量，图语义的断言在 test_graph_core。
	var store := FxDocumentStore.new()
	store.attach({"values": {"a": 1, "b": 2}})
	_check(int(store.doc["values"]["a"]) == 1, "装载文档")
	store.mutate(func(d: Dictionary) -> void:
		(d["values"] as Dictionary)["a"] = 5
	, ["doc"], "")
	_check(int(store.doc["values"]["a"]) == 5, "写入生效")
	_check(store.can_undo(), "产生撤销点")
	store.undo()
	_check(int(store.doc["values"]["a"]) == 1, "撤销恢复旧值")
	store.redo()
	_check(int(store.doc["values"]["a"]) == 5, "重做恢复新值")

	# 批量：一次手势里的多次修改只留一个撤销点。
	store.begin_batch()
	for i in range(3):
		store.mutate(func(d: Dictionary) -> void:
			(d["values"] as Dictionary)["b"] = 10 + i
		, ["doc"], "")
	store.commit_batch(["doc"])
	_check(int(store.doc["values"]["b"]) == 12, "批量写入全部生效")
	store.undo()
	_check(int(store.doc["values"]["b"]) == 2, "批量合成一个撤销点")

	# merge_key：同一手势的连续修改共用最早快照。
	store.mutate(func(d: Dictionary) -> void:
		(store.doc["values"] as Dictionary)["a"] = 7
	, ["doc"], "same")
	store.mutate(func(d: Dictionary) -> void:
		(store.doc["values"] as Dictionary)["a"] = 9
	, ["doc"], "same")
	store.undo()
	_check(int(store.doc["values"]["a"]) != 9, "同 key 合并只回退一次")


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  ok  ", label)
	else:
		failures.append(label)
		push_error("FAIL: " + label)


## 无头脚本退出前必须卸载插件注册表：静态表里的 Callable 不能活过脚本类。
func _quit(code: int = 0) -> void:
	FxPluginHost.shutdown()
	quit(code)

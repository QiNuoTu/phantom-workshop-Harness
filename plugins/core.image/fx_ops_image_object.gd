class_name FxOpsImageObject
extends RefCounted
## 图像对象节点：把端口里的图像包成可查询对象，再读回它的属性与像素。
##
## 三个算子都只做「值转换」，不改像素内容：
##   image.object  裸图像 → 对象（同时直通图像 + 各项属性）
##   image.info    对象   → 属性 + 拆包后的裸图像
##   image.pixel   对象   → 指定坐标的颜色与 RGBA 分量
##
## 因为 FxPortType 允许 image_object ↔ image 双向互连并自动转换，
## `image.object` 的输出可以直接接到任何已有图像节点，不需要改老算子。

static func ops() -> Dictionary:
	return {
		&"image.object": FxOpsImageObject.pack,
		&"image.info": FxOpsImageObject.info,
		&"image.pixel": FxOpsImageObject.pixel,
	}


static func pack(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, _params: Dictionary) -> Dictionary:
	var image: Image = FxImageObject.unwrap(inputs.get("image"))
	if image == null:
		image = _blank(ctx)
	var object := FxImageObject.wrap(image)
	return _info_of(object)


static func info(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, _params: Dictionary) -> Dictionary:
	var value: Variant = inputs.get("object")
	var object: FxImageObject = null
	if value is FxImageObject:
		object = value as FxImageObject
	else:
		object = FxImageObject.wrap(FxImageObject.unwrap(value))
	if not object.is_valid():
		object = FxImageObject.wrap(_blank(ctx))
	return _info_of(object)


static func pixel(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var value: Variant = inputs.get("object")
	var object: FxImageObject = null
	if value is FxImageObject:
		object = value as FxImageObject
	else:
		object = FxImageObject.wrap(FxImageObject.unwrap(value))
	if not object.is_valid():
		object = FxImageObject.wrap(_blank(ctx))
	var x: int = FxPortType.as_int(params.get("x", 0), 0)
	var y: int = FxPortType.as_int(params.get("y", 0), 0)
	var color: Color = object.pixel_at(x, y)
	return {
		"color": color,
		"r": color.r,
		"g": color.g,
		"b": color.b,
		"a": color.a,
	}


static func _info_of(object: FxImageObject) -> Dictionary:
	return {
		"object": object,
		"image": object.image,
		"width": float(object.width),
		"height": float(object.height),
		"format": float(object.format),
		"data_size": float(object.pixel_data().size()),
		"pixels": float(object.pixel_count),
	}


static func _blank(ctx: FxEvalContext) -> Image:
	var image: Image = Image.create_empty(maxi(1, ctx.canvas.x), maxi(1, ctx.canvas.y),
		false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	return image

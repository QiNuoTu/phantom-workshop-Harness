class_name FxImageObject
extends Resource
## 图像值对象：一张 Image + 可以直接查询的属性与像素数据。
##
## 以前端口里流动的是裸 Image，下游只能「拿去画」，想读宽高/格式/像素
## 就得另起一套节点。这里把图像包成有字段、有方法的对象，端口里就能同时
## 传图像和它的元数据；`FxPortType.cast_value()` 负责在对象与裸 Image 之间
## 无损转换，所以老节点一个都不用改，对象输出可以直接接到任何图像输入。
##
## 生命周期：每次求值新建一个轻量对象，只持有 Image 引用；像素数据按需复制，
## 不会在播放时每帧把整张图再拷一份。

@export var image: Image = null
@export var width: int = 0
@export var height: int = 0
@export var format: int = 0
@export var pixel_count: int = 0

var _pixel_data: PackedByteArray = PackedByteArray()
var _data_cached: bool = false


static func wrap(p_image: Image) -> FxImageObject:
	var object := FxImageObject.new()
	if p_image == null:
		return object
	object.image = p_image
	object.width = p_image.get_width()
	object.height = p_image.get_height()
	object.format = int(p_image.get_format())
	object.pixel_count = object.width * object.height
	return object


## 端口转换用的「拆包」：裸 Image、对象、贴图都认，认不出返回 null。
static func unwrap(value: Variant) -> Image:
	if value is Image:
		return value as Image
	if value is FxImageObject:
		return (value as FxImageObject).image as Image
	if value is ImageTexture:
		return (value as ImageTexture).get_image()
	return null


func is_valid() -> bool:
	return image != null and width > 0 and height > 0


## RGBA8 字节流，懒加载：只有真正要读数据时才复制一次。
func pixel_data() -> PackedByteArray:
	if not _data_cached:
		_pixel_data = image.get_data() if image != null else PackedByteArray()
		_data_cached = true
	return _pixel_data


func pixel_at(x: int, y: int) -> Color:
	if not is_valid():
		return Color(0, 0, 0, 0)
	return image.get_pixel(clampi(x, 0, width - 1), clampi(y, 0, height - 1))


func describe() -> String:
	return "%d×%d · %d 格式 · %d 字节" % [width, height, format, pixel_data().size()]

extends Node
## 房屋生成器（Autoload 名字：BuildingGenerator）
##
## 地图上要摆一栋「某文化圈的房子」时，如果图鉴里还没有这张图，就排个队让 AI 画一张。
## 提示词只描述「什么风格、什么户型」，尺寸/摆放由代码算；画好后交给 PropLibrary 存盘入库。
##
## 和立绘生成器同一套生图配置（由 LlmConfig 下发），也是串行队列：一次只画一张，
## 画完再画下一张，免得并发请求互相排队超时。
##
## 房屋按「文化圈 × 变体」编号（house_qingshi_a 之类），一共 9 个文化圈 × 3 个变体，
## 数量有限，所以画完一轮之后进游戏就都是现成的，不会无限花钱。

signal queue_changed
signal building_failed(id: String, reason: String)

## 单次请求超时（秒）
const API_TIMEOUT := 90.0

## 房屋素材统一风格：星露谷式的正视 + 微俯视——正面墙完全正对镜头，同时看到屋顶顶面，
## 门永远朝画面正下方，左右严格对称。不要等距/斜 45 度/四分之三侧视，也不要纯正俯视
## （那样只剩屋顶看不到墙）。
## 注意：早前这里写的是「俯视伪四分之三视角」，模型把「四分之三」理解成把房子绕竖轴转了 45°，
## 于是画出能看到侧墙的斜房子（青石镇 B 就是这个毛病），故改成把「正视、对称、屋脊水平、
## 不得出现侧墙」写死。
const STYLE_PROMPT := "2D 游戏建筑素材，单栋小房屋，星露谷物语风格：正面墙完全正对镜头（标准正视图，左右严格对称，屋脊是一条水平线），镜头略微俯视因而只能额外看到屋顶顶面；绝对看不到任何侧墙（左墙、右墙都不可见），房屋绝不允许绕竖轴转动或斜置。不是等距视角、不是斜45度、不是斜角透视、不是四分之三侧视。平涂赛璐璐上色，清晰深色描边，正面墙平整，正中一扇木门（带门框和门前一小级台阶），门两侧方形十字格窗，屋檐下压一道阴影线，房屋底部有一圈深色地基色带贴地，门朝向画面正下方，房屋完整不裁剪、不出画面，纯色亮绿色背景（#00FF00），背景干净无杂物，无地面投影，无文字，无水印，无边框，无人物"
const NEGATIVE_PROMPT := "模糊，畸变，多栋房子，成排建筑，人物，动物，文字，水印，签名，复杂背景，风景，写实照片，3D渲染，等距视角，斜45度，斜角透视，四分之三侧视，四分之三视角，能看到侧墙，出现侧墙，屋脊倾斜，房屋倾斜，房屋绕竖轴旋转，左右不对称，鸟瞰图，纯正俯视（只看见屋顶看不见正面墙），屋顶被掀开，剖面图，门开在侧面，门朝画面上方，现代高楼，玻璃幕墙，科幻，机甲，室内"

## 城市楼房的素材风格：和村庄民居同一套视角与上色，但更高大、更气派、砖石基座。
## 要求「气派但仍是这座城镇的样式」，免得 AI 画成现代高楼或玻璃幕墙。
const CITY_STYLE_PROMPT := "2D 游戏建筑素材，单栋气派的城镇楼房，星露谷物语风格：正面墙完全正对镜头（标准正视图，左右严格对称，屋脊是一条水平线），镜头略微俯视因而只能额外看到屋顶顶面；绝对看不到任何侧墙（左墙、右墙都不可见），楼房绝不允许绕竖轴转动或斜置。不是等距视角、不是斜45度、不是斜角透视、不是四分之三侧视。平涂赛璐璐上色，清晰深色描边，楼体两到三层、比普通民居明显更高大，底层砖石基座、上层木构或抹灰墙，屋檐明显挑出并压一道阴影，正面上下两排方形格窗，正中一扇带门框和台阶的宽木门，墙角和窗框有简洁的装饰线脚，气派讲究但仍然符合这座城镇的传统样式而不是现代建筑，房屋底部有一圈深色地基色带贴地，门朝向画面正下方，房屋完整不裁剪、不出画面，纯色亮绿色背景（#00FF00），背景干净无杂物，无地面投影，无文字，无水印，无边框，无人物"
const CITY_NEGATIVE_PROMPT := "模糊，畸变，多栋房子，成排建筑，联排街区，人物，动物，文字，水印，签名，复杂背景，风景，写实照片，3D渲染，等距视角，斜45度，斜角透视，四分之三侧视，四分之三视角，能看到侧墙，出现侧墙，屋脊倾斜，楼房倾斜，房屋绕竖轴旋转，左右不对称，鸟瞰图，纯正俯视（只看见屋顶看不见正面墙），屋顶被掀开，剖面图，门开在侧面，门朝画面上方，现代摩天楼，玻璃幕墙，霓虹灯，写字楼，科幻，机甲，室内"

## 通天福地仙宫主殿的素材风格：比民居更高大的东方仙宫殿宇，与福地那套绯色 + 白玉 + 暖金
## 的配色一致。仍然沿用同一套「正视、对称、看不到侧墙」的取景，保证和别的建筑摆在一起不出戏。
const TIANFU_STYLE_PROMPT := "2D 游戏建筑素材，单栋宏伟的东方仙宫殿宇，星露谷物语风格：正面墙完全正对镜头（标准正视图，左右严格对称，屋脊与檐口是水平线），镜头略微俯视因而只能额外看到屋顶顶面；绝对看不到任何侧墙（左墙、右墙都不可见），宫殿绝不允许绕竖轴转动或斜置。不是等距视角、不是斜45度、不是斜角透视、不是四分之三侧视。平涂赛璐璐上色，清晰深色描边：多层白玉台基层层收进如莲花宝座，绯色琉璃瓦重檐飞翘，正中一道垂落的绯色纱幔作殿门、两侧朱红廊柱与雕花格窗，殿顶是一枚绯色圆穹顶、顶上立一颗暖金宝顶，檐角垂着金色流苏，殿身点缀金饰珠翠，整座殿宇富丽而旖旎、比普通民居明显更高大，宫殿底部有一圈深色地基色带贴地，建筑完整不裁剪、不出画面，纯色亮绿色背景（#00FF00），背景干净无杂物，无地面投影，无文字，无水印，无边框，无人物"
const TIANFU_NEGATIVE_PROMPT := "模糊，畸变，多栋建筑，成排宫殿，人物，动物，文字，水印，签名，复杂背景，风景，写实照片，3D渲染，等距视角，斜45度，斜角透视，四分之三侧视，四分之三视角，能看到侧墙，出现侧墙，屋脊倾斜，建筑倾斜，建筑绕竖轴旋转，左右不对称，鸟瞰图，纯正俯视（只看见屋顶看不见正面墙），屋顶被掀开，剖面图，门开在侧面，门朝画面上方，西式教堂，哥特尖顶，现代高楼，玻璃幕墙，科幻，机甲，室内，残缺破损"

## 功能性建筑（锻造台 / 商铺 / 客栈 / 藏书阁 / 拍卖行 / 告示板 / 药铺 / 马厩 / 赌坊）的素材风格：
## 沿用和民居同一套取景（正视、对称、看不到侧墙），但主体是「一件功能设施或小铺面」而不是住人的房子，
## 炉台、货摊、木牌、擂台这类东西得一眼认出用途，所以不套「小房屋」那套门 / 窗的构图要求。
const FACILITY_STYLE_PROMPT := "2D 游戏地图素材，单个功能性建筑或工作设施，星露谷物语风格：正面完全正对镜头（标准正视图，左右基本对称），镜头略微俯视因而能看到顶面；绝对看不到侧墙，设施不允许绕竖轴转动或斜置。不是等距视角、不是斜45度、不是斜角透视、不是四分之三侧视。平涂赛璐璐上色，清晰深色描边，结构紧凑、一眼就能看出用途，设施底部有一圈深色地基色带贴地，设施完整不裁剪、不出画面，纯色亮绿色背景（#00FF00），背景干净无杂物，无地面投影，无文字，无水印，无边框，无人物"

## 9 种功能建筑各自长什么样（村庄版：朴素实用）
const FACILITY_HINTS := {
	"forge": "一座露天锻造工坊：石砌炉台里燃着橙红炉火，旁边立着铁砧与淬火水槽，墙上挂着几把铁锤",
	"shop": "一间带布质雨棚的货摊：木台面上摆满货品，棚边垂着一面幌子",
	"inn": "一间客栈铺面：门口挑出一面酒旗幌子，门前有一级木台阶",
	"library": "一座藏书阁：檐下比民居多挑出一层，门前立着书架，堆着成摞书卷",
	"auction": "一座拍卖行：石砌台基上撑起顶棚，顶上挑着一枚金色招牌",
	"board": "一块告示板：两根木柱撑起一块木板，板上钉着几张告示纸",
	"clinic": "一间药铺：门前挂着一只药葫芦招牌，门旁摆着药柜",
	"stable": "一间马厩：敞开的木棚里堆着干草，棚前立着拴马桩",
	"arena": "一座露天擂台：一方石砌台面，四角插着旗帜",
}

## 城市版：同样一件事，城里更气派（只对 4 种有城市别名的做区分，其余沿用村庄版）
const FACILITY_CITY_HINTS := {
	"board": "一面任务榜：两块石座托起一大块公告板，板上钉满委托告示",
	"clinic": "一间医馆：青砖门面、檐下悬壶，门前摆着一排药柜",
	"stable": "一座驿站：高大的木造车马棚，棚下停着一辆马车",
	"arena": "一座竞技场：石砌看台围出比试场地，四角插着旗帜",
}

## 这些功能建筑本身就是「房子」，才谈得上屋顶样式；
## 炉台 / 货摊 / 木牌 / 擂台这些露天设施不套屋顶，免得 AI 硬给告示板加个屋檐。
const FACILITY_ROOFED: Array[String] = ["inn", "library", "clinic", "stable"]

## 屋顶形状（CultureData.house_shape_of 的返回值）→ 给 AI 看的中文描述
const ROOF_HINTS := {
	"curved": "中原飞檐，屋檐微微上翘",
	"gable": "陡坡尖顶",
	"dome": "圆穹顶",
	"thatch": "茅草缓坡顶",
	"spire": "高瘦尖塔顶",
	"hip": "四坡顶，带一道平脊",
	"crystal": "水晶尖簇顶",
	"flat": "平顶厚板",
	"canopy": "树冠般圆润的宽顶",
}

## 大地图散落的树的素材风格：单棵独立的植被，正视微俯视，和建筑同一套取景语言，
## 这样树和房子摆在一起不会两种画风。要求「单独一棵」，免得 AI 画成一片森林。
const TREE_STYLE_PROMPT := "2D 游戏场景植被素材，单独一棵树，星露谷物语风格：正面完全正对镜头、左右基本对称，镜头略微俯视因而能同时看到树冠的正面与顶面，树冠圆润饱满、有成簇的叶片团和明暗层次，树干在正中、笔直，树根处只有一小撮深色泥土贴地。画面里只有这一棵树（绝不允许出现第二棵、成排树、树林或森林），不要地平线、不要地面铺满、不要远景。平涂赛璐璐上色，清晰深色描边，整棵树完整不裁剪、不出画面，纯色亮绿色背景（#00FF00），背景干净无杂物，无地面投影，无文字，无水印，无边框，无人物"

## 三种树各自的形状
const TREE_HINTS := {
	"a": "一棵高瘦的针叶松树：塔形树冠层层叠叠由阔到尖，针叶浓密，树干挺拔",
	"b": "一棵高大的阔叶乔木：树冠是一个饱满圆润的大球形，枝叶繁茂",
	"c": "一丛低矮的灌木树：没有明显树干，只有一团圆滚滚的矮树冠",
}

const TREE_NEGATIVE_PROMPT := "模糊，畸变，多棵树，两棵树，成排树，树林，森林，灌木丛连成一片，人物，动物，小屋，建筑，文字，水印，签名，复杂背景，风景，地平线，山，天空，写实照片，3D渲染，等距视角，斜45度，斜角透视，四分之三侧视，鸟瞰图，纯正俯视（只看见树顶看不见树干），被裁剪，出画面，剖面图，枯树，落叶，雪"

# ---------------------------------------------------------------- 配置（由 LlmConfig 下发）

## off = 关掉 AI 房屋（用程序化房子）；api = 走接口
var mode := "off"
var provider := "siliconflow"
var api_base := ""
var api_key := ""
var model := ""
var size := ""
## 生成后自动抠掉绿幕背景（开着房子才不会有绿方块底）
var remove_bg := true

# ---------------------------------------------------------------- 内部状态

var _http: HTTPRequest
var _dl_http: HTTPRequest

var _busy := false
var _pending: Dictionary = {}
## 排队等着的：Array[{id, culture, variant, force}]
var _queue: Array[Dictionary] = []
## 本局出现过的房子：id -> {culture, variant}
var _wanted: Dictionary = {}
## 画失败的：id -> 原因
var _failed: Dictionary = {}


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = API_TIMEOUT
	add_child(_http)
	_http.request_completed.connect(_on_image_completed)

	_dl_http = HTTPRequest.new()
	_dl_http.timeout = API_TIMEOUT
	add_child(_dl_http)
	_dl_http.request_completed.connect(_on_download_completed)

	_load_config()


func _load_config() -> void:
	if has_node("/root/LlmConfig"):
		LlmConfig.apply_image_to(self)


# ---------------------------------------------------------------- 对外查询

func is_on() -> bool:
	return mode == "api" and api_key.strip_edges() != "" and api_base.strip_edges() != ""


func pending_count() -> int:
	return _queue.size() + (1 if _busy else 0)


func failure_reason(id: String) -> String:
	return str(_failed.get(id, ""))


func is_queued(id: String) -> bool:
	if str(_pending.get("id", "")) == id:
		return true
	for item in _queue:
		if str(item.get("id", "")) == id:
			return true
	return false


## 地图上出现了一栋还没画过的房子（民居 / 功能建筑 / 树）→ 排队去画。已经有图就不动。
func request(id: String) -> bool:
	var facility := PropLibrary.is_facility_id(id)
	var tree := PropLibrary.is_tree_id(id)
	if not facility and not tree and not PropLibrary.is_building_id(id):
		return false
	if not _wanted.has(id):
		_wanted[id] = _wanted_of(id, facility, tree)
	if _has_texture(id):
		return false
	return enqueue(id, false)


## 这个 id 在磁盘上有没有现成的图（民居/功能建筑走建筑图鉴，树走树图鉴）
func _has_texture(id: String) -> bool:
	if PropLibrary.is_tree_id(id):
		return PropLibrary.has_tree_texture(id)
	return PropLibrary.has_building_texture(id)


## 把 id 拆成出图要用的字段：功能建筑带 kind，民居带 variant，树带 tree 标记。
func _wanted_of(id: String, facility: bool, tree: bool = false) -> Dictionary:
	if tree:
		var tinfo := PropLibrary.parse_tree_id(id)
		return {
			"culture": str(tinfo.get("culture", "")),
			"variant": str(tinfo.get("variant", "")),
			"tier": "tree",
			"tree": true,
		}
	if facility:
		var finfo := PropLibrary.parse_facility_id(id)
		return {
			"culture": str(finfo.get("culture", "")),
			"kind": str(finfo.get("kind", "")),
			"tier": str(finfo.get("tier", "village")),
		}
	var info := PropLibrary.parse_building_id(id)
	return {
		"culture": str(info.get("culture", "")),
		"variant": str(info.get("variant", "")),
		"tier": str(info.get("tier", "village")),
	}


## 排进队列。force=true 时无视已有图，重画覆盖。
func enqueue(id: String, force: bool = false) -> bool:
	if not is_on():
		return false
	if not force and _has_texture(id):
		return false
	if is_queued(id):
		return false
	if not _wanted.has(id):
		return false
	var item: Dictionary = _wanted[id].duplicate()
	item["id"] = id
	item["force"] = force
	_queue.append(item)
	_failed.erase(id)
	queue_changed.emit()
	call_deferred("_pump")
	return true


# ---------------------------------------------------------------- 队列

func _pump() -> void:
	if _busy or _queue.is_empty():
		return
	if not is_on():
		_queue.clear()
		queue_changed.emit()
		return
	_busy = true
	_pending = _queue.pop_front()
	queue_changed.emit()
	_call_image(_pending)


func _finish(ok: bool, reason: String) -> void:
	var id := str(_pending.get("id", ""))
	if not ok and id != "":
		_failed[id] = reason
		push_warning("[BuildingGenerator] 画失败 %s：%s" % [id, reason])
		building_failed.emit(id, reason)
	_pending = {}
	_busy = false
	queue_changed.emit()
	call_deferred("_pump")


# ---------------------------------------------------------------- 发请求

func _call_image(d: Dictionary) -> void:
	var prompt := _build_prompt(d)
	var body := _build_body(prompt, d)
	var url := "%s/images/generations" % api_base.strip_edges().trim_suffix("/")
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer %s" % api_key.strip_edges(),
	])
	var err := _http.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		_finish(false, "请求发不出去：%s" % error_string(err))


## 这个是城市楼房吗
func _is_city(d: Dictionary) -> bool:
	return str(d.get("tier", "village")) == "city"


## 这是不是通天福地的仙宫主殿
func _is_tianfu(d: Dictionary) -> bool:
	return str(d.get("culture", "")) == "tianfu"


## 该用哪份负向提示词
func _negative_for(d: Dictionary) -> String:
	if bool(d.get("tree", false)):
		return TREE_NEGATIVE_PROMPT
	if _is_tianfu(d):
		return TIANFU_NEGATIVE_PROMPT
	return CITY_NEGATIVE_PROMPT if _is_city(d) else NEGATIVE_PROMPT


func _build_body(prompt: String, d: Dictionary = {}) -> Dictionary:
	if provider == "ark_plan":
		return {
			"model": model,
			"prompt": prompt,
			"size": size,
			"response_format": "b64_json",
			"output_format": "png",
			"watermark": false,
		}
	if provider == "dashscope":
		return {
			"model": model,
			"prompt": prompt,
			"size": size,
			"negative_prompt": _negative_for(d),
			"response_format": "b64_json",
		}
	return {
		"model": model,
		"prompt": prompt,
		"negative_prompt": _negative_for(d),
		"image_size": size,
		"batch_size": 1,
		"output_format": "png",
	}


func _on_image_completed(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if _pending.is_empty():
		return
	var text := body.get_string_from_utf8()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		_finish(false, "返回的不是 JSON（HTTP %d）" % code)
		return
	if code < 200 or code >= 300:
		_finish(false, "HTTP %d：%s" % [code, _error_message(parsed)])
		return
	var got := _first_image(parsed)
	if got.has("b64"):
		_store_base64(str(got["b64"]))
	elif got.has("url"):
		_download(str(got["url"]))
	else:
		_finish(false, "返回里没有图片：%s" % text.substr(0, 200))


func _first_image(parsed: Dictionary) -> Dictionary:
	for key in ["data", "images"]:
		var arr = parsed.get(key, null)
		if typeof(arr) != TYPE_ARRAY or (arr as Array).is_empty():
			continue
		var first = (arr as Array)[0]
		if typeof(first) == TYPE_DICTIONARY:
			if (first as Dictionary).has("b64_json"):
				return {"b64": (first as Dictionary)["b64_json"]}
			if (first as Dictionary).has("url"):
				return {"url": (first as Dictionary)["url"]}
		elif typeof(first) == TYPE_STRING and key == "images":
			return {"url": first}
	return {}


func _error_message(parsed: Dictionary) -> String:
	for key in ["message", "error", "msg", "detail"]:
		var v = parsed.get(key, null)
		if typeof(v) == TYPE_DICTIONARY:
			return str((v as Dictionary).get("message", str(v)))
		if v != null:
			return str(v)
	return JSON.stringify(parsed).substr(0, 200)


func _download(url: String) -> void:
	var err := _dl_http.request(url, PackedStringArray(), HTTPClient.METHOD_GET)
	if err != OK:
		_finish(false, "下载图片失败：%s" % error_string(err))


func _on_download_completed(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if _pending.is_empty():
		return
	if code < 200 or code >= 300:
		_finish(false, "下载图片 HTTP %d" % code)
		return
	_decode_and_store(body)


func _store_base64(b64: String) -> void:
	var raw := Marshalls.base64_to_raw(b64)
	if raw.is_empty():
		_finish(false, "base64 解不出来")
		return
	_decode_and_store(raw)


# ---------------------------------------------------------------- 解码 / 处理 / 入库

func _decode_and_store(bytes: PackedByteArray) -> void:
	var img := _decode_image(bytes)
	if img == null:
		_finish(false, "图片格式读不出来")
		return
	_store(img)


func _decode_image(bytes: PackedByteArray) -> Image:
	var img := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	if bytes.size() >= 8 and bytes[0] == 0x89 and bytes[1] == 0x50:
		err = img.load_png_from_buffer(bytes)
	elif bytes.size() >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8:
		err = img.load_jpg_from_buffer(bytes)
	else:
		err = img.load_png_from_buffer(bytes)
	if err == OK:
		return img
	img = Image.new()
	if img.load_jpg_from_buffer(bytes) == OK:
		return img
	return null


func _store(img: Image) -> void:
	var prepared := _prepare(img)
	if prepared == null:
		_finish(false, "图片处理失败")
		return
	var d := _pending
	var id := str(d.get("id", ""))
	var meta := {"provider": provider, "model": model, "tier": str(d.get("tier", "village"))}
	var saved: bool
	if bool(d.get("tree", false)):
		saved = PropLibrary.register_tree(id, prepared, meta)
	else:
		saved = PropLibrary.register_building(id, prepared, meta)
	if saved:
		_finish(true, "")
	else:
		_finish(false, "写盘失败")


## 统一处理成游戏里好用的图：RGBA8 → 缩到 384 以内 → 抠掉绿幕背景
func _prepare(img: Image) -> Image:
	var out := Image.new()
	out.copy_from(img)
	if out.get_format() != Image.FORMAT_RGBA8:
		out.convert(Image.FORMAT_RGBA8)
	var w := out.get_width()
	var h := out.get_height()
	if w <= 0 or h <= 0:
		return null
	var longest := maxi(w, h)
	if longest > 384:
		var k := 384.0 / float(longest)
		out.resize(maxi(1, int(round(w * k))), maxi(1, int(round(h * k))), Image.INTERPOLATE_LANCZOS)
	if remove_bg:
		_key_out_background(out)
	return out


## 用四角取样抠掉纯色背景；四角差太多（AI 画了复杂背景）就原样留着
func _key_out_background(img: Image) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var corners := [
		img.get_pixel(0, 0), img.get_pixel(w - 1, 0),
		img.get_pixel(0, h - 1), img.get_pixel(w - 1, h - 1),
	]
	var key := Color(0.0, 0.0, 0.0)
	for c in corners:
		key += c
	key /= 4.0
	for c in corners:
		var diff := Vector3(c.r - key.r, c.g - key.g, c.b - key.b).length()
		if diff > 0.30:
			return
	var keyv := Vector3(key.r, key.g, key.b)
	var tol := 0.16
	var soft := tol * 2.0
	for y in h:
		for x in w:
			var px := img.get_pixel(x, y)
			var dist := Vector3(px.r - keyv.x, px.g - keyv.y, px.b - keyv.z).length()
			if dist <= tol:
				img.set_pixel(x, y, Color(px.r, px.g, px.b, 0.0))
			elif dist < soft:
				var a: float = (dist - tol) / (soft - tol)
				img.set_pixel(x, y, Color(px.r, px.g, px.b, px.a * a))


# ---------------------------------------------------------------- 提示词

func _build_prompt(d: Dictionary) -> String:
	if bool(d.get("tree", false)):
		return _build_tree_prompt(d)
	var cid := str(d.get("culture", ""))
	var variant := str(d.get("variant", ""))
	var kind := str(d.get("kind", ""))
	var facility := kind != ""
	var city := _is_city(d)
	var tianfu := _is_tianfu(d)
	var lines: Array[String] = []
	if facility:
		lines.append(FACILITY_STYLE_PROMPT)
	else:
		lines.append(TIANFU_STYLE_PROMPT if tianfu else (CITY_STYLE_PROMPT if city else STYLE_PROMPT))
	if facility:
		lines.append("设施档次：%s" % ("城镇版（比村庄版更气派讲究，但仍是本聚落的传统样式）" if city else "村庄版（朴素实用、体量不大）"))
		var hint := str(FACILITY_CITY_HINTS.get(kind, "")) if city else ""
		if hint == "":
			hint = str(FACILITY_HINTS.get(kind, ""))
		if hint != "":
			lines.append("设施：%s（%s）" % [str(PropLibrary.FACILITY_KIND_NAMES.get(kind, kind)), hint])
	elif tianfu:
		lines.append("建筑档次：通天福地的仙宫主殿（全世界仅此一座，比任何民居都宏伟，绯色琉璃瓦、白玉台基与暖金宝顶）")
	elif city:
		lines.append("建筑档次：城镇楼房（比村庄民居更高大、更气派，但仍是本聚落的传统样式）")
	if cid != "" and has_node("/root/CultureData"):
		var cname := CultureData.culture_name_of(cid)
		if cname != "":
			lines.append("所属聚落：%s" % cname)
		var style := CultureData.style_of(cid)
		if style != "":
			lines.append("世界风格参考：%s" % style)
		# 露天设施（炉台 / 货摊 / 告示板 / 擂台）不套屋顶，免得 AI 硬给告示板加屋檐
		if not facility or FACILITY_ROOFED.has(kind):
			var roof: String = str(ROOF_HINTS.get(CultureData.house_shape_of(cid), ""))
			if roof != "":
				lines.append("屋顶样式：%s" % roof)
	# 福地仙宫只有一座、功能建筑各是一类独立设施，都不参与「同村多栋要有差异」，就不给户型变体
	if variant != "" and not tianfu and not facility:
		lines.append("户型变体：%s（与同一聚落的其它房屋外形要有差异）" % variant.to_upper())
	if facility:
		lines.append("构图要求：单个设施居中、正面朝向画面正下方，顶部在上、地基在下，结构完整不裁剪、不出画面")
	else:
		lines.append("构图要求：单栋正立、门在正面正中且朝向画面正下方，屋顶在上、地基在下，左右对称")
	return "。".join(lines)


## 树的提示词：只描述「哪个文化圈、哪种树形」，构图交给代码摆。
func _build_tree_prompt(d: Dictionary) -> String:
	var cid := str(d.get("culture", ""))
	var variant := str(d.get("variant", ""))
	var lines: Array[String] = [TREE_STYLE_PROMPT]
	var hint := str(TREE_HINTS.get(variant, ""))
	if hint != "":
		lines.append("树种：%s" % hint)
	if cid != "" and has_node("/root/CultureData"):
		var cname := CultureData.culture_name_of(cid)
		if cname != "":
			lines.append("所属聚落：%s（树形与叶色要符合这个地方的风土）" % cname)
		var style := CultureData.style_of(cid)
		if style != "":
			lines.append("世界风格参考：%s" % style)
	lines.append("构图要求：整棵树居中、完整不裁剪，树干在正中，树冠在上、树根在下")
	return "。".join(lines)

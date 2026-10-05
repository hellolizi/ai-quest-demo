extends Node
## 立绘生成器（Autoload 名字：PortraitGenerator）
##
## 拿 NPC 的「名字 + 文化圈 + 外观 token」拼成提示词，调文生图接口画一张全身立绘，
## 缩到游戏用的小尺寸、抠掉背景，再交给 PortraitLibrary 存盘入库。
##
## 同时支持两家（设置里下拉切换，配置由 LlmConfig 下发）：
##   硅基流动 siliconflow   POST /v1/images/generations，返回 images[].url，要再下载一次
##   火山方舟 ark_plan      POST /api/plan/v3/images/generations，返回 data[].b64_json，省一次下载
##
## 串行队列：一次只发一个请求，画完再发下一个。文生图接口都挺慢的（十几秒），
## 并发发出去只会互相排队超时，串着来最稳。

signal queue_changed
signal portrait_failed(tag: String, reason: String)

## 单次请求超时（秒）。文生图比文本慢得多，给足时间。
const API_TIMEOUT := 90.0

## 立绘统一风格：好扣背景的纯色绿幕 + 干净的赛璐璐平涂
const STYLE_PROMPT := "2D 游戏角色全身立绘，正面略微四分之三站姿，双脚并拢站直，双手自然下垂，日式赛璐璐平涂上色，清晰描边，三头身，纯色亮绿色背景（#00FF00），背景干净无杂物，无地面阴影，人物完整不出画面，无文字，无水印，无边框"
const NEGATIVE_PROMPT := "模糊，畸变，多余的手，多余的腿，多个人，文字，水印，签名，复杂背景，风景，写实照片，3D 渲染，现代服装，科幻，机甲，武器，坐姿，躺卧"

# ---------------------------------------------------------------- 配置（由 LlmConfig 下发）

## off = 关掉 AI 立绘（用程序化小人）；api = 走接口
var mode := "off"
var provider := "siliconflow"
var api_base := ""
var api_key := ""
var model := ""
var size := ""
## 生成后自动抠掉绿幕背景（强烈建议开，不然游戏里就是个方框）
var remove_bg := true

# ---------------------------------------------------------------- 内部状态

var _http: HTTPRequest
var _dl_http: HTTPRequest

var _busy := false
## 正在画的那一个请求的上下文
var _pending: Dictionary = {}
## 排队等着画的：Array[{tag, force, ...}]
var _queue: Array[Dictionary] = []
## 所有「本局游戏里出现过、需要立绘的」NPC：tag -> {name, role, culture, appearance}
var _wanted: Dictionary = {}
## 画失败的：tag -> 原因（界面上可以显示「上次为什么失败」）
var _failed_tags: Dictionary = {}


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


## 跟其它生成器一样，在自己的 _ready 里把配置从 LlmConfig 拉过来
func _load_config() -> void:
	if has_node("/root/LlmConfig"):
		LlmConfig.apply_image_to(self)


# ---------------------------------------------------------------- 对外查询

func is_on() -> bool:
	return mode == "api" and api_key.strip_edges() != "" and api_base.strip_edges() != ""


func wanted_tags() -> Array:
	return _wanted.keys()


func has_wanted(tag: String) -> bool:
	return _wanted.has(tag)


func descriptor(tag: String) -> Dictionary:
	return _wanted.get(tag, {})


func is_queued(tag: String) -> bool:
	if _pending.get("tag", "") == tag:
		return true
	for item in _queue:
		if item.get("tag", "") == tag:
			return true
	return false


func pending_count() -> int:
	return _queue.size() + (1 if _busy else 0)


## 还需要画的张数（含被玩家停用、等着补齐的）
func missing_count() -> int:
	var n := 0
	for tag in _wanted.keys():
		if not PortraitLibrary.is_enabled(tag):
			n += 1
	return n


func failure_reason(tag: String) -> String:
	return str(_failed_tags.get(tag, ""))


# ---------------------------------------------------------------- 对外请求

## NPC 进场时报到：记下「这个人需要立绘」，没有就排队去画。
## 已经有图（不管启用还是停用）就不自动重画——尊重玩家在立绘库里的选择。
## look 非空时用它当「外貌」原文（敌人按族给的写法比 token 拼出来的更贴切）；
## 为空则沿用 appearance 拼出的描述。
func request(tag: String, npc_name: String, role: String, culture_id: String, appearance: Dictionary, tier: String = "", look: String = "") -> void:
	_wanted[tag] = {
		"name": npc_name,
		"role": role,
		"culture": culture_id,
		"tier": tier,
		"look": look,
		"appearance": CharacterSprite.sanitize_appearance(appearance),
	}
	if PortraitLibrary.has(tag):
		return
	enqueue(tag, false)


## 强制（重新）画一张。force=true 时会无视已有图，覆盖旧图。
func enqueue(tag: String, force: bool = false) -> bool:
	if not is_on():
		return false
	if not force and PortraitLibrary.has(tag):
		return false
	if is_queued(tag):
		return false
	if not _wanted.has(tag):
		return false
	var item: Dictionary = _wanted[tag].duplicate()
	item["tag"] = tag
	item["force"] = force
	_queue.append(item)
	_failed_tags.erase(tag)
	queue_changed.emit()
	call_deferred("_pump")
	return true


## 单独重画某一张（立绘库界面上的「重画」按钮）
func regenerate(tag: String) -> bool:
	if not _wanted.has(tag):
		# 界面上重画时，用库里已有的元信息把描述补回来
		var entry := PortraitLibrary.get_entry(tag)
		if entry.is_empty():
			return false
		_wanted[tag] = {
			"name": str(entry.get("name", "")),
			"role": str(entry.get("role", "")),
			"culture": str(entry.get("culture", "")),
			"tier": str(entry.get("tier", "")),
			"look": str(entry.get("look", "")),
			"appearance": entry.get("appearance", {}),
		}
	return enqueue(tag, true)


## 「补齐」：把所有还没画出来 / 被停用 的都排上队强制重画一遍。
## 返回排进去的张数。
func refill() -> int:
	var n := 0
	for tag in _wanted.keys():
		if PortraitLibrary.is_enabled(tag):
			continue
		if is_queued(tag):
			continue
		if enqueue(tag, true):
			n += 1
	return n


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
	var tag := str(_pending.get("tag", ""))
	if not ok and tag != "":
		_failed_tags[tag] = reason
		push_warning("[PortraitGenerator] 画失败 %s：%s" % [tag, reason])
		portrait_failed.emit(tag, reason)
	_pending = {}
	_busy = false
	queue_changed.emit()
	call_deferred("_pump")


# ---------------------------------------------------------------- 发请求

func _call_image(d: Dictionary) -> void:
	var prompt := _build_prompt(d)
	var body := _build_body(prompt)
	var url := "%s/images/generations" % api_base.strip_edges().trim_suffix("/")
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer %s" % api_key.strip_edges(),
	])
	var err := _http.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		_finish(false, "请求发不出去：%s" % error_string(err))


## 两家的参数名不一样：硅基流动要 image_size，方舟要 size；
## 方舟还支持直接返回 base64，省掉再下载一次。
func _build_body(prompt: String) -> Dictionary:
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
			"negative_prompt": NEGATIVE_PROMPT,
			"response_format": "b64_json",
		}
	return {
		"model": model,
		"prompt": prompt,
		"negative_prompt": NEGATIVE_PROMPT,
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


## 兼容两家不同的返回结构：方舟是 data[0].b64_json / data[0].url，硅基流动是 images[0].url
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


## 硅基流动只给 url，得再拉一次图
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


## 按文件头魔数判断 png / jpeg，比看扩展名靠谱
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
	# 兜底：两种都试一遍
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
	var meta := {
		"name": str(d.get("name", "")),
		"role": str(d.get("role", "")),
		"culture": str(d.get("culture", "")),
		"tier": str(d.get("tier", "")),
		"look": str(d.get("look", "")),
		"appearance": d.get("appearance", {}),
		"provider": provider,
		"model": model,
	}
	if PortraitLibrary.register(str(d.get("tag", "")), prepared, meta):
		_finish(true, "")
	else:
		_finish(false, "写盘失败")


## 统一处理成游戏里好用的图：RGBA8 → 缩到 256 以内 → 抠掉绿幕背景
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
	if longest > 256:
		var k := 256.0 / float(longest)
		out.resize(maxi(1, int(round(w * k))), maxi(1, int(round(h * k))), Image.INTERPOLATE_LANCZOS)
	if remove_bg:
		_key_out_background(out)
	return out


## 用四角取样抠掉纯色背景：四个角颜色差不多才认为是「干净的纯色背景」，
## 不然（比如 AI 画了复杂背景）就原样留着，别把人物抠花了。
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

	# 四角互相差太多 → 背景不是纯色，直接放弃抠图
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
	var appearance: Dictionary = d.get("appearance", {})
	var name := str(d.get("name", ""))
	var role := str(d.get("role", ""))
	var culture := str(d.get("culture", ""))

	var lines: Array[String] = [STYLE_PROMPT]
	var who := name
	if role != "":
		who = "%s（%s）" % [name, role] if name != "" else role
	if who != "":
		lines.append("角色：%s" % who)
	var looks := str(d.get("look", ""))
	if looks == "":
		looks = CharacterSprite.describe_cn(appearance)
	if looks != "":
		lines.append("外貌：%s" % looks)
	var style := ""
	var dress := ""
	if culture != "" and has_node("/root/CultureData"):
		style = CultureData.style_of(culture)
		dress = CultureData.dress_of(culture)
	if style != "":
		lines.append("世界风格参考：%s" % style)
	if dress != "":
		lines.append("该地区标准打扮：%s" % dress)
		lines.append("服装款式须符合上述地区打扮，外貌里的衣服颜色作为这套装扮的主色")
	# 通天福地的住客衣料极少：再单独强调一遍，免得模型自作主张把人裹严实
	if culture == "tianfu":
		lines.append("着装要求：走极致性感的路线——深V低胸、露肩露背、纤腰镂空、高开衩，薄纱半透、肌肤若隐若现，尽量展现曼妙身段，别画成裹得严实的端庄正装")
		lines.append("肤色要求：一身雪白细腻的冷白皮，白皙透亮、白得发光，绝不要小麦色、古铜色或任何暖棕色调")
	# 城里的居民穿得更讲究：不点这一句，画出来跟村里人没差别
	var tier_cn := CharacterSprite.tier_cn(str(d.get("tier", "")))
	if tier_cn != "":
		lines.append("身份档次：%s" % tier_cn)
	return "。".join(lines)

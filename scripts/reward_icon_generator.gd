extends Node
## 奖励图标生成器（Autoload 名字：RewardIconGenerator）
##
## 任务奖励要配一张小图标：拿奖励名拼提示词，调文生图接口画一张方形小图，
## 缩到游戏用的小尺寸、抠掉绿幕背景，再交给 RewardLibrary 存盘入库。
##
## 复用策略（跟 RewardLibrary 配合，越靠前越省钱）：
##   1. 归类词典：金/金币/金子/金块… 都归到 cat_gold，直接共用，不重画；
##   2. 别名记忆：库里某张图记过这个名字，直接复用；
##   3. 语义兜底：前两层都没命中，就把「已有图标清单 + 新奖励名」丢给文字模型，
##      让它判断能不能复用既有的一张图；能就用别名记下来，不能才新画一张。
##
## 注意：本生成器只接收 LlmConfig 的**生图**那套配置（IMAGE_TARGETS）。
## 语义兜底要用的文字模型配置，运行时直接从 LlmConfig 现读，避免字段互相覆盖。

signal queue_changed
signal icon_failed(tag: String, reason: String)

## 单次生图请求超时（秒）
const API_TIMEOUT := 90.0
## 语义兜底那次文字请求超时（秒）
const TEXT_TIMEOUT := 30.0

## 图标统一风格：好扣背景的纯色绿幕 + 单个物品居中的平涂
const STYLE_PROMPT := "2D 游戏道具图标，单个物品居中，正面视角，日式赛璐璐平涂上色，清晰描边，纯色亮绿色背景（#00FF00），背景干净无杂物，无阴影，无文字，无水印，无边框，方形构图"
const NEGATIVE_PROMPT := "模糊，畸变，多个物品，人物，手，文字，水印，签名，复杂背景，风景，写实照片，3D 渲染，边框，地面阴影"

## 语义兜底的系统提示词：只让它回一个既有标签或 NEW
const MATCH_SYSTEM := "你在帮一个游戏判断「新奖励能不能复用已有图标」。下面会给你现有图标清单（每行的格式是「标签（类别）：用过的名字」）和一个新奖励名。如果能用其中某个图标代表它，就只回复那个标签本身（例如 cat_gold）；如果都不合适，只回复 NEW。不要解释，不要多余文字。"

## 图标处理后的最长边
const ICON_MAX := 160

# ---------------------------------------------------------------- 配置（由 LlmConfig 下发）

## off = 关（界面上用程序绘制占位）；api = 走接口
var mode := "off"
var provider := "siliconflow"
var api_base := ""
var api_key := ""
var model := ""
## 平台原始尺寸参数（仅方舟会用；硅基流动的图标一律正方形）
var size := ""
var remove_bg := true

# ---------------------------------------------------------------- 内部状态

var _http: HTTPRequest
var _dl_http: HTTPRequest
var _text_http: HTTPRequest

var _busy := false
var _pending: Dictionary = {}
## 排队等着画的：Array[{tag, name, category, force}]
var _queue: Array[Dictionary] = []
## 本局出现过、需要图标的：tag -> {name, category}
var _wanted: Dictionary = {}
## 画失败的：tag -> 原因
var _failed_tags: Dictionary = {}

## 已经问过文字模型的奖励名（归一化后）：避免同一个名字反复问
var _asked: Dictionary = {}
## 等文字模型判断的：Array[{text, force}]
var _match_queue: Array[Dictionary] = []
var _matching := false
var _match_pending: Dictionary = {}


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = API_TIMEOUT
	add_child(_http)
	_http.request_completed.connect(_on_image_completed)

	_dl_http = HTTPRequest.new()
	_dl_http.timeout = API_TIMEOUT
	add_child(_dl_http)
	_dl_http.request_completed.connect(_on_download_completed)

	_text_http = HTTPRequest.new()
	_text_http.timeout = TEXT_TIMEOUT
	add_child(_text_http)
	_text_http.request_completed.connect(_on_match_completed)

	_load_config()


func _load_config() -> void:
	if has_node("/root/LlmConfig"):
		LlmConfig.apply_image_to(self)


# ---------------------------------------------------------------- 对外查询

func is_on() -> bool:
	return mode == "api" and api_key.strip_edges() != "" and api_base.strip_edges() != ""


func is_queued(tag: String) -> bool:
	if str(_pending.get("tag", "")) == tag:
		return true
	for item in _queue:
		if str(item.get("tag", "")) == tag:
			return true
	return false


func pending_count() -> int:
	return _queue.size() + (1 if _busy else 0)


func failure_reason(tag: String) -> String:
	return str(_failed_tags.get(tag, ""))


## 文字模型这套配置够不够用（够才做语义兜底）
func _can_ask_llm() -> bool:
	var lc := get_node_or_null("/root/LlmConfig")
	if lc == null:
		return false
	return str(lc.mode) == "llm" and str(lc.api_key).strip_edges() != "" \
		and str(lc.api_base).strip_edges() != ""


# ---------------------------------------------------------------- 对外请求

## 保证某个奖励名最终能用上图标。返回它对应的标签（可能暂时还没有图）。
## 调用点：任务生成 / 接受时预热，任务完成时补一次。
func request(text: String, force: bool = false) -> String:
	var t := text.strip_edges()
	if t == "":
		return ""

	var cat := RewardLibrary.category_of(t)
	if cat != "":
		# 有大类 → 直接按大类共用，天然能复用「金子 / 金块」
		return _need("cat_%s" % cat, t, cat, force)

	# 没有大类：先看本地库里有没有能复用的
	var hit := RewardLibrary.resolve(t)
	if hit != "":
		RewardLibrary.add_alias(hit, t)
		if force and is_on():
			_need(hit, t, "", true)
		return hit

	# 本地判不了：若文字模型可用，交给它判断能否复用既有图
	if _can_ask_llm() and not _asked.has(RewardLibrary._normalize(t)):
		_enqueue_match(t, force)
		return RewardLibrary.canonical_tag(t)

	# 兜底：用字面标签新画一张
	return _need(RewardLibrary.canonical_tag(t), t, "", force)


## 直接用固定标签 + 外观描述画一张图（不走归类词典、不做语义兜底）。
## 用途：武器、材料这类「有固定 id、每样都长相不同」的资源。
## 图标就存在 res://generated/rewards/<tag>/icon.png，下次进游戏直接复用。
func request_named(tag: String, name: String, hint: String = "", force: bool = false) -> String:
	var t := tag.strip_edges()
	if t == "":
		return ""
	if _wanted.has(t):
		_wanted[t]["name"] = name
		_wanted[t]["hint"] = hint
	else:
		_wanted[t] = {"name": name, "category": "", "hint": hint}
	if RewardLibrary.has(t) and not force:
		RewardLibrary.add_alias(t, name)
		return t
	if is_on():
		enqueue(t, force)
	return t


## 记下「这个标签要画」，需要就排队。返回标签。
func _need(tag: String, text: String, cat: String, force: bool) -> String:
	if tag == "":
		return ""
	if _wanted.has(tag):
		_wanted[tag]["name"] = text
		_wanted[tag]["category"] = cat
	else:
		_wanted[tag] = {"name": text, "category": cat}
	if RewardLibrary.has(tag) and not force:
		RewardLibrary.add_alias(tag, text)
		return tag
	if is_on():
		enqueue(tag, force)
	return tag


func enqueue(tag: String, force: bool = false) -> bool:
	if not is_on():
		return false
	if not force and RewardLibrary.has(tag):
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


# ---------------------------------------------------------------- 生图队列

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
		push_warning("[RewardIconGenerator] 画失败 %s：%s" % [tag, reason])
		icon_failed.emit(tag, reason)
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


## 图标一律要方形：硅基流动给固定 1024x1024，方舟/百炼沿用全局 size
func _icon_size() -> String:
	if provider == "ark_plan":
		var s := size.strip_edges()
		return s if s != "" else "1K"
	if provider == "dashscope":
		var s2 := size.strip_edges()
		return s2 if s2 != "" else "1024x1024"
	return "1024x1024"


## 两家的参数名不一样：硅基流动要 image_size，方舟要 size 且能直接回 base64
func _build_body(prompt: String) -> Dictionary:
	if provider == "ark_plan":
		return {
			"model": model,
			"prompt": prompt,
			"size": _icon_size(),
			"response_format": "b64_json",
			"output_format": "png",
			"watermark": false,
		}
	if provider == "dashscope":
		return {
			"model": model,
			"prompt": prompt,
			"size": _icon_size(),
			"negative_prompt": NEGATIVE_PROMPT,
			"response_format": "b64_json",
		}
	return {
		"model": model,
		"prompt": prompt,
		"negative_prompt": NEGATIVE_PROMPT,
		"image_size": _icon_size(),
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
	var name := str(d.get("name", ""))
	var meta := {
		"name": name,
		"category": str(d.get("category", "")),
		"aliases": [name] if name != "" else [],
		"provider": provider,
		"model": model,
	}
	if RewardLibrary.register(str(d.get("tag", "")), prepared, meta):
		_finish(true, "")
	else:
		_finish(false, "写盘失败")


## 统一处理成游戏里好用的图：RGBA8 → 缩到 ICON_MAX 以内 → 抠掉绿幕背景
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
	if longest > ICON_MAX:
		var k := float(ICON_MAX) / float(longest)
		out.resize(maxi(1, int(round(w * k))), maxi(1, int(round(h * k))), Image.INTERPOLATE_LANCZOS)
	if remove_bg:
		_key_out_background(out)
	return out


## 用四角取样抠掉纯色背景：四角颜色差不多才认为是「干净的纯色背景」，
## 不然（比如 AI 画了复杂背景）就原样留着，别把物品抠花了。
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


# ---------------------------------------------------------------- 语义兜底（问文字模型）


## 把「这个新名字能不能复用已有图」丢进串行队列
func _enqueue_match(text: String, force: bool) -> void:
	var n := RewardLibrary._normalize(text)
	if n == "" or _asked.has(n):
		return
	_asked[n] = true
	_match_queue.append({"text": text, "force": force})
	call_deferred("_pump_match")


func _pump_match() -> void:
	if _matching or _match_queue.is_empty():
		return
	# 文字模型不可用：直接退回用字面标签画
	if not _can_ask_llm():
		while not _match_queue.is_empty():
			var it: Dictionary = _match_queue.pop_front()
			_need(RewardLibrary.canonical_tag(str(it.get("text", ""))), str(it.get("text", "")), "", bool(it.get("force", false)))
		return
	_matching = true
	_match_pending = _match_queue.pop_front()
	_call_match(str(_match_pending.get("text", "")))


func _call_match(text: String) -> void:
	var lc := get_node_or_null("/root/LlmConfig")
	if lc == null:
		_finish_match("")
		return
	var url := "%s/chat/completions" % str(lc.api_base).strip_edges().trim_suffix("/")
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer %s" % str(lc.api_key).strip_edges(),
	])
	var user := "已有图标：\n%s\n\n新的奖励名：%s\n它能不能复用上面某个图标？" % [
		RewardLibrary.catalog_for_llm(), text,
	]
	var body := {
		"model": str(lc.model),
		"temperature": 0.0,
		"messages": [
			{"role": "system", "content": MATCH_SYSTEM},
			{"role": "user", "content": user},
		],
	}
	var err := _text_http.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		_finish_match("")


func _on_match_completed(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if _match_pending.is_empty():
		return
	var reply := ""
	if code >= 200 and code < 300:
		var parsed = JSON.parse_string(body.get_string_from_utf8())
		reply = _extract_reply(parsed)
	_finish_match(reply)


## 拿模型的回复做决定：命中既有标签就用别名复用，否则用字面标签画一张
func _finish_match(reply: String) -> void:
	var text := str(_match_pending.get("text", ""))
	var force := bool(_match_pending.get("force", false))
	_match_pending = {}
	_matching = false
	var tag := _parse_tag(reply)
	if tag != "" and RewardLibrary.has(tag):
		RewardLibrary.add_alias(tag, text)
		if force and is_on():
			_need(tag, text, str(RewardLibrary.get_entry(tag).get("category", "")), true)
	else:
		_need(RewardLibrary.canonical_tag(text), text, "", force)
	call_deferred("_pump_match")


func _extract_reply(parsed: Variant) -> String:
	if typeof(parsed) != TYPE_DICTIONARY:
		return ""
	var choices = (parsed as Dictionary).get("choices", null)
	if typeof(choices) != TYPE_ARRAY or (choices as Array).is_empty():
		return ""
	var first = (choices as Array)[0]
	if typeof(first) != TYPE_DICTIONARY:
		return ""
	var msg = (first as Dictionary).get("message", null)
	if typeof(msg) == TYPE_DICTIONARY:
		return str((msg as Dictionary).get("content", ""))
	return ""


## 从模型回复里解析出一个「库里确实存在」的标签；NEW 或说不清都返回空串
func _parse_tag(reply: String) -> String:
	var r := reply.strip_edges()
	if r == "":
		return ""
	if r.to_upper().begins_with("NEW"):
		return ""
	for t in RewardLibrary.all_tags():
		var ts := str(t)
		if ts != "" and r.contains(ts):
			return ts
	return ""


# ---------------------------------------------------------------- 提示词

func _build_prompt(d: Dictionary) -> String:
	var name := str(d.get("name", ""))
	var cat := str(d.get("category", ""))
	var hint := str(d.get("hint", ""))
	var lines: Array[String] = [STYLE_PROMPT]
	if name != "":
		lines.append("物品：%s" % name)
	if hint != "":
		lines.append("外观：%s" % hint)
	var label := RewardLibrary.category_label(cat)
	if label != "":
		lines.append("类别参考：%s" % label)
	return "。".join(lines)

extends Node
## 攻击动作序列帧生成器（Autoload 名字：AttackSheetGenerator）
##
## 和 WalkSheetGenerator 同一套做法：一次让 AI 画一整张「3 行 × 4 列 = 12 格」的
## 攻击序列帧（3 个朝向 × 4 个关键帧：蓄力 → 挥出 → 命中 → 收招），
## 出图后代码切格、逐格摆正、抠掉绿幕、按统一包围盒裁剪，
## 再交给 PortraitLibrary 存进角色文件夹的 attack/ 子目录。
##
## 只落盘 down / up / left 三个朝向；right 播放时由 left 水平翻转得到，省一半图。
##
## 目的：让主角挥击时「有动作」，而不是滑过去。
## 与走路帧共用同一个 tag（同一个角色），因此也共用那张立绘当参考图，
## 保证攻击帧里的还是同一个人。走路帧不会因此重画。
##
## 串行队列：一次只画一个角色，画完再画下一个（文生图慢，串着来最稳）。

signal queue_changed
signal attack_failed(tag: String, reason: String)

## 单次请求超时（秒）。12 格一张图比单张立绘慢，给更足的时间。
const API_TIMEOUT := 240.0

## 喂给模型的构图底图：绿底 + 深绿格线 + 每格中心品红十字
const USE_TEMPLATE := true
const TEMPLATE_SIZE := 1024
## 切格时每边内缩这么多像素，避开模型画进成品的格线
const CELL_INSET := 10
## 每行 4 帧
const FRAME_COLS := 4
## 行 = 朝向，从上到下。只画 3 个朝向，right 由 left 翻转得到。
const ROWS := [
	{"id": "down", "cn": "朝下（正面，脸朝镜头）", "side": false},
	{"id": "up", "cn": "朝上（背面，背对镜头）", "side": false},
	{"id": "left", "cn": "朝左（侧面，面朝画面左侧）", "side": true},
]
## 需要落盘的朝向（right 不落盘，读盘时内存翻转）
const STORED_DIRS := ["down", "up", "left"]
## 统一裁剪后最长边不超过这个值，控制内存占用
const MAX_SIDE := 256

const NEGATIVE_PROMPT := "多个不同角色，人物不一致，脸不一样，换了个人，换脸，换了衣服，颜色不一致，身高不一致，格数错误，格子重叠，跨格，角色贴边，角色出格，角色大小不一，四格姿势完全相同，相邻两格一模一样，四格都站着不动，走路，迈步，跑步，抬腿，屈膝抬腿，双腿向画面左右两侧张开，外八字，内八字，劈叉，侧踢，横向迈步，大幅抬腿，武器外形不一致，武器时有时无，双手空空，模糊，畸变，多余的手，多余的胳膊，多条手臂，文字，水印，签名，复杂背景，风景，写实照片，3D 渲染"

# ---------------------------------------------------------------- 配置（由 LlmConfig 下发）

## off = 关掉 AI 攻击帧（挥击只显示程序化白光弧）；api = 走接口
var mode := "off"
var provider := "siliconflow"
var api_base := ""
var api_key := ""
var model := ""
var size := ""
var remove_bg := true

# ---------------------------------------------------------------- 内部状态

var _http: HTTPRequest
var _dl_http: HTTPRequest

var _busy := false
var _pending: Dictionary = {}
var _queue: Array[Dictionary] = []
## tag -> {name, role, culture, appearance}
var _wanted: Dictionary = {}
var _failed_tags: Dictionary = {}
## 构图底图 data URL（懒生成，只做一次）
var _template_url := ""


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


func is_queued(tag: String) -> bool:
	if _pending.get("tag", "") == tag:
		return true
	for item in _queue:
		if item.get("tag", "") == tag:
			return true
	return false


func pending_count() -> int:
	return _queue.size() + (1 if _busy else 0)


func failure_reason(tag: String) -> String:
	return str(_failed_tags.get(tag, ""))


# ---------------------------------------------------------------- 对外请求

## 报到：记下「这个人需要攻击帧」，没有就排队去画。
## look 非空时用它当「外貌」原文（敌人按族给的写法），为空则沿用 appearance 拼出的描述。
## weapon_cn 是攻击帧里那把兵器的中文名（缺省「短剑」），让坏人拿上自己那把兵器。
func request(tag: String, npc_name: String, role: String, culture_id: String, appearance: Dictionary, look: String = "", weapon_cn: String = "") -> void:
	_wanted[tag] = {
		"name": npc_name,
		"role": role,
		"culture": culture_id,
		"look": look,
		"weapon_cn": weapon_cn,
		"appearance": CharacterSprite.sanitize_appearance(appearance),
	}
	if PortraitLibrary.has_attack(tag):
		return
	enqueue(tag, false)


func enqueue(tag: String, force: bool = false) -> bool:
	if not is_on():
		return false
	if not force and PortraitLibrary.has_attack(tag):
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
		push_warning("[AttackSheetGenerator] 画失败 %s：%s" % [tag, reason])
		attack_failed.emit(tag, reason)
	_pending = {}
	_busy = false
	queue_changed.emit()
	call_deferred("_pump")


# ---------------------------------------------------------------- 发请求

func _call_image(d: Dictionary) -> void:
	var prompt := _build_sheet_prompt(d)
	var ref := _reference_data_url(str(d.get("tag", "")))
	var body := _build_body(prompt, ref)
	var url := "%s/images/generations" % api_base.strip_edges().trim_suffix("/")
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer %s" % api_key.strip_edges(),
	])
	var err := _http.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		_finish(false, "请求发不出去：%s" % error_string(err))


## 两家参数名不一样：硅基流动要 image_size，方舟要 size；方舟直接返回 base64。
func _build_body(prompt: String, ref: String) -> Dictionary:
	if provider == "ark_plan":
		var body := {
			"model": model,
			"prompt": prompt,
			"size": size,
			"response_format": "b64_json",
			"output_format": "png",
			"watermark": false,
		}
		if ref != "":
			body["image"] = ref
		return body
	if provider == "dashscope":
		var body_ds := {
			"model": model,
			"prompt": prompt,
			"size": size,
			"negative_prompt": NEGATIVE_PROMPT,
			"response_format": "b64_json",
		}
		if ref != "":
			body_ds["image"] = ref
		return body_ds
	var body_sf := {
		"model": model,
		"prompt": prompt,
		"negative_prompt": NEGATIVE_PROMPT,
		"image_size": size,
		"batch_size": 1,
		"output_format": "png",
	}
	if ref != "":
		body_sf["image"] = ref
	return body_sf


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
	_process_and_store(img)


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


func _process_and_store(img: Image) -> void:
	var frames := _slice(img)
	if frames.is_empty():
		_finish(false, "切格失败（图里找不到角色）")
		return
	var d := _pending
	var meta := {
		"name": str(d.get("name", "")),
		"role": str(d.get("role", "")),
		"culture": str(d.get("culture", "")),
		"look": str(d.get("look", "")),
		"weapon_cn": str(d.get("weapon_cn", "")),
		"appearance": d.get("appearance", {}),
		"provider": provider,
		"model": model,
	}
	if PortraitLibrary.register_attack(str(d.get("tag", "")), frames, meta):
		_finish(true, "")
	else:
		_finish(false, "写盘失败")


# ---------------------------------------------------------------- 切格 / 摆正 / 抠绿 / 裁剪

## 把整张 3×4 的图切成「down/up/left 各 4 帧」：
## 逐格量包围盒 → 居中 + 脚底对齐 → 抠掉绿幕 → 按统一包围盒裁到同尺寸。
func _slice(sheet: Image) -> Dictionary:
	var img := Image.new()
	img.copy_from(sheet)
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	if w <= 0 or h <= 0:
		return {}

	var cw := int(w / FRAME_COLS)
	var ch := int(h / ROWS.size())
	var iw := cw - CELL_INSET * 2
	var ih := ch - CELL_INSET * 2
	if iw <= 0 or ih <= 0:
		return {}
	var key := _bg_key(img)
	## 脚底统一落在这条线上（留一点下边距）
	var baseline := int(ih * 0.92)

	## 先摆正 + 抠绿，得到透明底的若干格
	var cells: Dictionary = {}
	var all_cells: Array = []
	for r in ROWS.size():
		var dir_id: String = ROWS[r]["id"]
		var row_frames: Array = []
		for c in FRAME_COLS:
			var cell := img.get_region(Rect2i(c * cw + CELL_INSET, r * ch + CELL_INSET, iw, ih))
			var m := _measure_cell(cell, key)
			var fixed := _align_cell(cell, key, baseline, m)
			_key_out(fixed, key)
			row_frames.append(fixed)
			all_cells.append(fixed)
		cells[dir_id] = row_frames

	## 12 格统一包围盒：保证每帧裁出来尺寸一致、脚底线一致
	var box := _union_box(all_cells)
	if box.is_empty():
		return {}
	var crop := Rect2i(box["x"], box["y"], box["w"], box["h"])
	for dir_id in cells.keys():
		var out_row: Array = []
		for c in (cells[dir_id] as Array).size():
			var one = (cells[dir_id] as Array)[c].get_region(crop)
			one = _fit_max(one, MAX_SIDE)
			out_row.append(one)
		cells[dir_id] = out_row
	return cells


## 所有非透明像素的并集包围盒；找不到就返回空字典
func _union_box(images: Array) -> Dictionary:
	var min_x := 1 << 30
	var min_y := 1 << 30
	var max_x := -1
	var max_y := -1
	for img in images:
		if img == null:
			continue
		var w: int = (img as Image).get_width()
		var h: int = (img as Image).get_height()
		for y in h:
			for x in w:
				if (img as Image).get_pixel(x, y).a <= 0.15:
					continue
				min_x = mini(min_x, x)
				min_y = mini(min_y, y)
				max_x = maxi(max_x, x)
				max_y = maxi(max_y, y)
	if max_x < 0 or max_y < 0:
		return {}
	return {"x": min_x, "y": min_y, "w": max_x - min_x + 1, "h": max_y - min_y + 1}


## 把整格的绿幕键色抠成透明（带一点软边）
func _key_out(img: Image, key: Color) -> void:
	var w := img.get_width()
	var h := img.get_height()
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


## 等比缩到最长边不超过 max_side（已经够小就不动）
func _fit_max(img: Image, max_side: int) -> Image:
	var w := img.get_width()
	var h := img.get_height()
	var longest := maxi(w, h)
	if longest <= max_side or longest <= 0:
		return img
	var k := float(max_side) / float(longest)
	img.resize(maxi(1, int(round(w * k))), maxi(1, int(round(h * k))), Image.INTERPOLATE_LANCZOS)
	return img


# ---------------------------------------------------------------- 对齐算法（与 WalkSheetGenerator 一致）

## 取四角均值当「绿幕」键色
func _bg_key(img: Image) -> Color:
	var w := img.get_width()
	var h := img.get_height()
	var pts := [Vector2i(2, 2), Vector2i(w - 3, 2), Vector2i(2, h - 3), Vector2i(w - 3, h - 3)]
	var r := 0.0
	var g := 0.0
	var b := 0.0
	for p in pts:
		var c := img.get_pixel(p.x, p.y)
		r += c.r
		g += c.g
		b += c.b
	return Color(r / 4.0, g / 4.0, b / 4.0)


func _is_bg(px: Color, key: Color) -> bool:
	var dr := px.r - key.r
	var dg := px.g - key.g
	var db := px.b - key.b
	return sqrt(dr * dr + dg * dg + db * db) <= 0.20


## 量一格：包围盒 + 上半身横向锚点。found=false 表示整格都是背景。
func _measure_cell(cell: Image, key: Color) -> Dictionary:
	var w := cell.get_width()
	var h := cell.get_height()
	var min_run := maxi(2, int(w * 0.005))
	var row_cnt := PackedInt32Array()
	row_cnt.resize(h)
	var col_cnt := PackedInt32Array()
	col_cnt.resize(w)
	for y in h:
		for x in w:
			if _is_bg(cell.get_pixel(x, y), key):
				continue
			row_cnt[y] += 1
			col_cnt[x] += 1

	var min_x := w
	var max_x := -1
	var min_y := h
	var max_y := -1
	for y in h:
		if row_cnt[y] >= min_run:
			min_y = mini(min_y, y)
			max_y = maxi(max_y, y)
	for x in w:
		if col_cnt[x] >= min_run:
			min_x = mini(min_x, x)
			max_x = maxi(max_x, x)
	if max_x < 0 or max_y < 0:
		return {"found": false}

	## 横向锚点取整个包围盒的中心（攻击时武器会伸出去，上半身锚点会把角色拽偏）
	var anchor_x := (min_x + max_x) * 0.5
	return {
		"found": true,
		"min_x": min_x, "max_x": max_x, "min_y": min_y, "max_y": max_y,
		"anchor_x": anchor_x,
	}


## 把一格里的角色摆正：横向按包围盒中心对齐到格子中线，纵向把脚底压到基线
func _align_cell(cell: Image, key: Color, baseline: int, m: Dictionary) -> Image:
	var w := cell.get_width()
	var h := cell.get_height()
	var out := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	out.fill(key)
	if not m["found"]:
		return cell

	var min_x: int = m["min_x"]
	var max_x: int = m["max_x"]
	var min_y: int = m["min_y"]
	var max_y: int = m["max_y"]
	var anchor_x: float = m["anchor_x"]

	var dx := int(round(w * 0.5 - anchor_x))
	var dy := int(round(float(baseline) - float(max_y)))
	dx = clampi(dx, -min_x, w - 1 - max_x)
	dy = clampi(dy, -min_y, h - 1 - max_y)

	for y in range(min_y, max_y + 1):
		for x in range(min_x, max_x + 1):
			var px := cell.get_pixel(x, y)
			if _is_bg(px, key):
				continue
			out.set_pixel(x + dx, y + dy, px)
	return out


# ---------------------------------------------------------------- 模板底图

## 绿底 + 深绿格线 + 每格中心品红十字，作为 image 参数喂给模型
func _template_data_url() -> String:
	if _template_url != "":
		return _template_url
	_template_url = "data:image/png;base64,%s" % Marshalls.raw_to_base64(_make_template(TEMPLATE_SIZE).save_png_to_buffer())
	return _template_url


## 喂给模型的参考图：底图上每格中央再贴上该角色已有的立绘。
## 目的：让模型直接看到这个人长什么样，攻击帧里保持同一张脸 / 同一套衣服。
func _reference_data_url(tag: String) -> String:
	if not USE_TEMPLATE:
		return ""
	if tag == "" or not has_node("/root/PortraitLibrary"):
		return _template_data_url()
	if not PortraitLibrary.has(tag):
		return _template_data_url()
	var portrait := Image.load_from_file(PortraitLibrary.path_for(tag))
	if portrait == null:
		return _template_data_url()
	var img := _make_template(TEMPLATE_SIZE)
	if not _stamp_portrait(img, portrait):
		return _template_data_url()
	return "data:image/png;base64,%s" % Marshalls.raw_to_base64(img.save_png_to_buffer())


## 把立绘（透明底）按格居中贴满整张底图，每格一个。返回 false 表示立绘不可用。
func _stamp_portrait(canvas: Image, portrait: Image) -> bool:
	if portrait.get_width() <= 0 or portrait.get_height() <= 0:
		return false
	if portrait.get_format() != Image.FORMAT_RGBA8:
		portrait.convert(Image.FORMAT_RGBA8)
	var rows := ROWS.size()
	var cw := int(canvas.get_width() / FRAME_COLS)
	var ch := int(canvas.get_height() / rows)
	## 缩到格子高度的 66%，四周留充足绿边，别贴到格线
	var target_h := maxi(1, int(ch * 0.66))
	var p := portrait
	var pw := p.get_width()
	var ph := p.get_height()
	if ph > target_h:
		p = Image.new()
		p.copy_from(portrait)
		var k := float(target_h) / float(ph)
		p.resize(maxi(1, int(round(pw * k))), target_h, Image.INTERPOLATE_LANCZOS)
		pw = p.get_width()
		ph = p.get_height()
	if pw > cw - CELL_INSET * 2:
		var k2 := float(cw - CELL_INSET * 2) / float(pw)
		p = Image.new()
		p.copy_from(portrait)
		p.resize(maxi(1, int(round(pw * k2))), maxi(1, int(round(ph * k2))), Image.INTERPOLATE_LANCZOS)
		pw = p.get_width()
		ph = p.get_height()
	for r in rows:
		for c in FRAME_COLS:
			var ox := c * cw + (cw - pw) / 2
			var oy := r * ch + (ch - ph) / 2
			for y in ph:
				for x in pw:
					var px := p.get_pixel(x, y)
					if px.a <= 0.02:
						continue
					canvas.set_pixel(ox + x, oy + y, px)
	return true


func _make_template(size: int) -> Image:
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 1, 0))

	var rows := ROWS.size()
	var cw := int(size / FRAME_COLS)
	var ch := int(size / rows)
	var line := Color(0, 0.45, 0)
	var mark := Color(1, 0, 1)

	for i in range(1, FRAME_COLS):
		img.fill_rect(Rect2i(i * cw - 1, 0, 2, size), line)
	for i in range(1, rows):
		img.fill_rect(Rect2i(0, i * ch - 1, size, 2), line)

	var arm := 14
	var th := 4
	for r in rows:
		for c in FRAME_COLS:
			var cx := c * cw + cw / 2
			var cy := r * ch + ch / 2
			img.fill_rect(Rect2i(cx - arm, cy - th / 2, arm * 2, th), mark)
			img.fill_rect(Rect2i(cx - th / 2, cy - arm, th, arm * 2), mark)

	return img


# ---------------------------------------------------------------- 提示词

## 单张 3 行 × 4 列 = 12 格；角色长相按外观 token 动态拼，和立绘用的是同一份身份。
func _build_sheet_prompt(d: Dictionary) -> String:
	var appearance: Dictionary = d.get("appearance", {})
	var name := str(d.get("name", ""))
	var role := str(d.get("role", ""))
	var culture := str(d.get("culture", ""))
	var tag_id := str(d.get("tag", ""))
	## 参考底图里是否已经贴上了这个角色的立绘（决定提示词里要不要强调「保持是同一个人」）
	var has_ref := USE_TEMPLATE and tag_id != "" and has_node("/root/PortraitLibrary") and PortraitLibrary.has(tag_id)

	## 行序描述直接从 ROWS 生成，避免两处写死对不上
	var parts: Array = []
	for i in ROWS.size():
		parts.append("第 %d 行：%s" % [i + 1, ROWS[i]["cn"]])
	var rows_desc := "；".join(parts) + "。"

	## 攻击帧里那把兵器：坏人按自己的兵器画，NPC / 主角默认短剑
	var wp := str(d.get("weapon_cn", ""))
	if wp == "":
		wp = "短剑"

	## 按朝向给挥砍方向：正面朝镜头劈、背面只见手臂、侧面朝画面左侧劈
	var down_rule := "正面（朝下）：角色面朝镜头，双脚站在原地不动，双手握着一把%s，从画面一侧（或头顶上方）朝镜头正前方的下方斜劈而下。" % wp
	var up_rule := "背面（朝上）：角色背对镜头，双腿站定不动，从背后只见两只手臂在身体两侧一前一后地挥动，%s随手臂挥出。" % wp
	var side_rule := "侧面（朝左）：角色面朝画面左侧、露出侧脸，双脚站定不动，%s从右上方朝左前方斜劈而下，手臂与身体一起前倾发力。" % wp

	var rows_n: int = ROWS.size()
	var total: int = rows_n * FRAME_COLS

	var tpl_note := ""
	if USE_TEMPLATE:
		tpl_note = "\n【按我给的底图排布 - 必须严格照做】\n" \
			+ "我会同时给你一张已经画好 %d 行 %d 列格线、并且每格正中央有一个小十字标记的底图。\n" % [rows_n, FRAME_COLS] \
			+ "请严格保持这张底图的 %d 行 %d 列布局：每一格画一个角色，角色的身体中心要正好落在该格中心的十字标记上，\n" % [rows_n, FRAME_COLS] \
			+ "角色不要越过格线、不要跨到隔壁格。绿色背景保持纯绿，格线位置保持不变。" \
			+ "不要把小十字标记画进成品里。\n"
		if has_ref:
			tpl_note += "【最重要 - 必须还是同一个人】底图每一格的中央已经画好了这位角色现在的样子。" \
				+ "你必须让每一格画出来的人跟底图里那个人长得一模一样：同一张脸、同一个发型和发色、同一套服装的款式和颜色、" \
				+ "同样的体型和身高。绝对不允许换人、换脸、换衣服、改颜色。你只允许改变他的手臂与武器的挥动姿势以及上身前倾的程度，画出下面要求的攻击姿态。\n"

	## 角色一致性：跟立绘用同一份外观描述，两张图看上去才像同一个人
	var who := str(d.get("look", ""))
	if who == "":
		who = CharacterSprite.describe_cn(appearance)
	if who == "":
		who = "一个年轻冒险者"
	var who_line := who
	if name != "":
		var tag := name
		if role != "":
			tag = "%s（%s）" % [name, role]
		who_line = "%s，%s" % [tag, who]
	var id_line := "%d 个格子必须是同一个角色：%s。" % [total, who_line]
	var culture_line := ""
	if culture != "" and has_node("/root/CultureData"):
		var style := CultureData.style_of(culture)
		var dress := CultureData.dress_of(culture)
		if style != "":
			culture_line += "世界风格参考：%s。" % style
		if dress != "":
			culture_line += "该地区标准打扮：%s，服装款式须符合这套打扮。" % dress

	var text := """一张 2D 游戏角色的攻击动作序列帧图（Sprite Sheet）。
整张图均匀分成 %d 行 %d 列、共 %d 个大小完全相同的格子。格子之间留有清晰的绿色间隔，互不重叠。
【最重要的一条】每一格里只画一个角色，角色必须落在该格的正中央：左右居中、上下居中，四周留出充足空白，
角色不贴边、不出格、不跨格、不被切掉。%d 个格子的角色大小必须一致。%s

%d 行 = %d 个朝向，从上到下：%s

每一行从左到右的 4 格，是同一个朝向「原地挥砍一次」的 4 个连续关键帧：
第 1 格：蓄力——稳稳站在原地，把短剑举到身体的一侧（或举过肩、举到脑后），上身微微后仰、扭转蓄势；
第 2 格：挥出——手臂带动短剑朝正前方快速挥出，上身明显前倾、转身发力，短剑伸展到离身体最远处；
第 3 格：命中——短剑挥到终点（正前方），姿势定格在幅度最大的那一瞬，表情用力；
第 4 格：收招——短剑收回身侧，上身直回，姿势接近站立待机。
【铁律】四格必须是同一次挥砍的四个不同阶段，绝不能四格一模一样，也绝不能画成走路或跑步；
四格里双脚的位置基本不动、始终稳稳站在原处。

【动作方向 - 必须严格照做】
%s
%s
%s

【腿部 - 必须严格照做】
所有格子都是「原地挥砍」，双脚必须稳稳踏在原地、左右间距保持不变，
绝对不允许迈步、走路、跑步、抬腿、屈膝抬腿、劈叉、双腿向画面左右张开。

【角色一致性】
%s%s
完全相同的脸、发型、发色、服装款式和颜色，三头身比例，身高大小完全一致，只是手臂与武器的姿势不同。
四格里手里的短剑外形必须保持一致，不能时有时无、不能两手空空。
每一格角色头顶到脚底的总高度必须完全一样，头不要上下浮动。

2D 游戏美术风格，日式赛璐璐平涂上色，清晰描边，三头身（Q 版比例，头大身小），画面干净利落，不要写实到照片级。
整张图绝对不要出现：走路、迈步、跑步、抬腿、四格动作完全相同、武器外形不一致、两手空空、
多余的手或胳膊、多条手臂、畸形的手、模糊、噪点、文字、水印、边框、地面阴影、多余的装饰。
纯色亮绿色背景（#00FF00），背景干净无杂物，无地面阴影，无文字，无水印，无边框，无网格线以外的装饰。""" \
		% [rows_n, FRAME_COLS, total, total, tpl_note, rows_n, rows_n, rows_desc,
			down_rule, up_rule, side_rule, id_line, culture_line]
	# 模板正文里默认写的是「短剑」；换了兵器就整段替换掉
	if wp != "短剑":
		text = text.replace("短剑", wp)
	return text

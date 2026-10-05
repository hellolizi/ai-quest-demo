extends Node
## 场景布置器（Autoload 名字：SceneDecorator）
## 让 AI 决定「一个地点周围该摆些什么、摆在哪个方位」，再由代码翻译成真实坐标。
##
## 和地点生成同样的思路：生成 → 校验 → 重试 → 兜底。
## 注意：AI 只说「摆什么、朝哪个方位、离多远」（近/中/远），
## 具体坐标、朝向、缩放开销全部由代码算，并且要过一遍校验
## （不落进溪流、不挡住从村子过来的路、不压到别的地点、不和已有道具重叠）。

signal props_placed(location_id: String, props: Array)

const MAX_RETRY := 1
## 一个地点最多接受 AI 给几条布置、最终最多摆几件道具
const MAX_ENTRIES := 8
const MAX_PLACEMENTS := 24

## 方位 → 单位向量。索引与 DIRECTIONS 一一对应。
const DIRECTIONS := ["北", "东北", "东", "东南", "南", "西南", "西", "西北"]
const DIR_VECTORS := [
	Vector2(0, -1), Vector2(1, -1), Vector2(1, 0), Vector2(1, 1),
	Vector2(0, 1), Vector2(-1, 1), Vector2(-1, 0), Vector2(-1, -1),
]
## 近/中/远 三档，指离地点中心多少像素
const RINGS := {"近": 200.0, "中": 330.0, "远": 470.0}

## 南边的溪流（和 world_map.gd 保持一致），别把道具摆到水里
const RIVER_Y := 1010.0
const RIVER_H := 90.0
## 两件道具之间的最小间距
const MIN_GAP := 74.0
## 道具离「村子→该地点」这条路至少留出的距离，保证玩家一定走得过去
const PATH_CLEAR := 88.0

const ORGANIC_SHAPES := ["tree", "bush", "grass", "rock", "ore"]

var mode := "mock"
var api_base := "https://api.openai.com/v1"
var api_key := ""
var model := "gpt-4o-mini"

var _http: HTTPRequest
var _pending_ctx: Dictionary = {}
var _pending_loc: Dictionary = {}
var _decorated: Dictionary = {}
var _placed: Array[Dictionary] = []
## 每个地点最终摆好的道具（含真实坐标），读档时靠它把场景原样还原
var _placements_by_loc: Dictionary = {}
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.request_completed.connect(_on_request_completed)
	add_child(_http)
	_load_config()
	# AI 之后每造出一个新地点，就顺手给它布置一番
	LocationGenerator.location_created.connect(decorate)


func _load_config() -> void:
	# 配置统一由 LlmConfig 下发（res:// 默认 + user:// 玩家设置）
	LlmConfig.apply_to(self)
	print("[SceneDecorator] 布置模式 = %s" % mode)


# ---------------------------------------------------------------- 对外入口

## 给开局就存在的地点做一次布置。用离线模板，不花接口调用、瞬间完成。
## 已经布置过的地点（例如从存档里恢复的）直接跳过，免得重复铺一遍。
func decorate_existing() -> void:
	for loc in WorldData.LOCATIONS:
		var loc_id := str(loc.get("id", ""))
		if loc_id == "" or _decorated.has(loc_id):
			continue
		_finalize(loc, _mock_layout(loc))


## 把读档恢复的布置重新发出去，让道具层照原样画一遍。
## （读档发生在启动时，道具层还没开始铺场景，所以这里只负责重放已存的。）
func replay_saved() -> void:
	for loc_id in _placements_by_loc:
		props_placed.emit(str(loc_id), _placements_by_loc[loc_id])


## 让 AI 给某个地点布置场景。同一个地点只布置一次。
func decorate(loc: Dictionary) -> void:
	var loc_id := str(loc.get("id", ""))
	if loc_id == "" or _decorated.has(loc_id):
		return
	_decorated[loc_id] = true
	_pending_loc = loc
	_pending_ctx = {"attempt": 0}
	if mode == "llm" and api_key != "":
		_call_llm(_pending_ctx)
	else:
		_finalize(loc, _mock_layout(loc))


func is_decorated(loc_id: String) -> bool:
	return _decorated.has(loc_id)


# ---------------------------------------------------------------- LLM 模式

func _system_prompt() -> String:
	return """你是一个 2D 冒险游戏的场景布置器。
你只能输出一个 JSON 对象，不要输出任何解释文字，也不要使用 markdown 代码块。
JSON 的字段必须严格如下：
- props: 数组，每一项描述「在这个地点摆什么、摆在哪个方位」，字段为：
  - id: 字符串，必须是下面道具清单里的 id，绝对不允许自己编造道具
  - direction: 字符串，相对该地点中心的方位，必须是：北、东北、东、东南、南、西南、西、西北
  - ring: 字符串，离地点中心的远近，必须是：近、中、远
  - count: 数字，同类道具成簇摆放的数量，1 到 6

要求：
1. 布置必须贴合这个地点的类型和描述（矿洞旁堆矿石、林子旁有树、水边有船、废墟旁有塌石）；
2. 最多给 8 条，不要把清单里的道具全用一遍，也不要把某一种铺满整个场地；
3. 不要把所有东西都堆在同一个方位，要围着地点铺开。

世界观：%s 不要引入现代或科幻元素。
可以使用的道具：
%s""" % [CultureData.worldview_block(), PropLibrary.prompt_list()]


func _call_llm(ctx: Dictionary) -> void:
	var user_prompt := """地点名称：%s
地点类型：%s
地点描述：%s

请为这个地点摆放一批道具。""" % [
		str(_pending_loc.get("name", "")),
		str(_pending_loc.get("kind", "")),
		str(_pending_loc.get("desc", "")),
	]
	if ctx.has("fix_hint"):
		user_prompt += "\n\n上一次生成不合格，原因：%s\n请严格按字段要求重新生成一次。" % ctx["fix_hint"]

	var payload := {
		"model": model,
		"messages": [
			{"role": "system", "content": _system_prompt()},
			{"role": "user", "content": user_prompt},
		],
		"temperature": 1.0,
		"response_format": {"type": "json_object"},
	}
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer " + api_key,
	])
	var err := _http.request(
		api_base + "/chat/completions",
		headers,
		HTTPClient.METHOD_POST,
		JSON.stringify(payload)
	)
	if err != OK:
		push_warning("[SceneDecorator] 请求发起失败(%d)，回退离线模板" % err)
		_finalize(_pending_loc, _mock_layout(_pending_loc))


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		var detail := body.get_string_from_utf8().left(300)
		push_warning("[SceneDecorator] LLM 调用失败(result=%d, code=%d)：%s" % [result, response_code, detail])
		_finalize(_pending_loc, _mock_layout(_pending_loc))
		return

	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("choices"):
		push_warning("[SceneDecorator] LLM 返回结构异常，回退离线模板")
		_finalize(_pending_loc, _mock_layout(_pending_loc))
		return

	var content := str(parsed["choices"][0]["message"]["content"])
	var data = JSON.parse_string(_extract_json(content))
	if typeof(data) != TYPE_DICTIONARY:
		_retry_or_fallback("模型返回的内容不是合法 JSON 对象")
		return

	var problem := _validation_error(data)
	if problem != "":
		_retry_or_fallback(problem)
		return

	_finalize(_pending_loc, data)


func _retry_or_fallback(reason: String) -> void:
	var attempt := int(_pending_ctx.get("attempt", 0))
	if attempt < MAX_RETRY:
		_pending_ctx["attempt"] = attempt + 1
		_pending_ctx["fix_hint"] = reason
		push_warning("[SceneDecorator] 布置不合格（%s），让模型重试一次" % reason)
		_call_llm(_pending_ctx)
		return
	push_warning("[SceneDecorator] 重试仍不合格（%s），回退离线模板" % reason)
	_finalize(_pending_loc, _mock_layout(_pending_loc))


## 有的模型会把 JSON 包在 ```json ... ``` 里，这里剥掉
func _extract_json(raw: String) -> String:
	var text := raw.strip_edges()
	if text.begins_with("```"):
		var first_newline := text.find("\n")
		if first_newline != -1:
			text = text.substr(first_newline + 1)
		if text.ends_with("```"):
			text = text.substr(0, text.length() - 3)
	return text.strip_edges()


# ---------------------------------------------------------------- 校验

## 返回空字符串表示通过，否则返回中文原因
func _validation_error(data: Dictionary) -> String:
	var items = data.get("props", null)
	if typeof(items) != TYPE_ARRAY or items.is_empty():
		return "props 必须是一个非空数组"
	if items.size() > MAX_ENTRIES:
		return "最多只能给 %d 条布置" % MAX_ENTRIES
	var known := PropLibrary.ids()
	for item in items:
		if typeof(item) != TYPE_DICTIONARY:
			return "props 里的每一项都必须是对象"
		var id := str(item.get("id", "")).strip_edges()
		if not known.has(id):
			return "道具 id「%s」不在清单里，只能填：%s" % [id, ", ".join(known)]
		if not DIRECTIONS.has(str(item.get("direction", "")).strip_edges()):
			return "direction 必须是：%s" % "、".join(PackedStringArray(DIRECTIONS))
		if not RINGS.has(str(item.get("ring", "")).strip_edges()):
			return "ring 必须是：近、中、远"
		if item.has("count") and not (typeof(item["count"]) == TYPE_INT or typeof(item["count"]) == TYPE_FLOAT):
			return "count 必须是数字"
	return ""


# ---------------------------------------------------------------- 落点

## 从期望方位出发，顺时针扫 8 个方向、近中远三档距离，找到第一个合规的落点。
## 一场下来都找不到就返回 null（这块地方已经满了）。
func _find_spot(dir_idx: int, ring_name: String, loc: Dictionary) -> Variant:
	var center: Vector2 = loc["pos"]
	for di in DIRECTIONS.size():
		var d: Vector2 = DIR_VECTORS[_wrap8(dir_idx + di)].normalized()
		for r in _ring_order(ring_name):
			var p: Vector2 = center + d * r
			if _is_spot_ok(p, loc):
				return p
	return null


## 先试 AI 想要的那一档，再退而求其次试另外两档
func _ring_order(ring_name: String) -> Array:
	var names: Array = ["近", "中", "远"]
	var i := names.find(ring_name)
	if i <= 0:
		return [RINGS["近"], RINGS["中"], RINGS["远"]]
	var out: Array = [RINGS[names[i]]]
	names.remove_at(i)
	for n in names:
		out.append(RINGS[n])
	return out


func _is_spot_ok(p: Vector2, _loc: Dictionary) -> bool:
	# 别摆到溪流或海里
	if absf(p.y - RIVER_Y) < RIVER_H + 46.0:
		return false
	if p.y > RegionGenerator.SEA_SHORE_Y - 46.0:
		return false
	# 别挡住任何一条从村子出去的路（村子自己也要避开所有岔路）
	var village: Vector2 = WorldData.by_id("village")["pos"]
	for other in WorldData.LOCATIONS:
		if str(other["id"]) == "village":
			continue
		if _dist_to_segment(p, village, other["pos"]) < PATH_CLEAR:
			return false
	# 别压到其它地点身上
	for other in WorldData.LOCATIONS:
		if p.distance_to(other["pos"]) < 170.0:
			return false
	# 别和已经摆好的东西挤在一起
	for placed in _placed:
		if p.distance_to(placed["pos"]) < MIN_GAP:
			return false
	return true


func _dist_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var t := 0.0
	if ab.length_squared() > 0.0:
		t = clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return p.distance_to(a + ab * t)


func _wrap8(i: int) -> int:
	return ((i % 8) + 8) % 8


# ---------------------------------------------------------------- 离线模板

## 每种地点一套朴素的布置，保证不联网也能立刻看到效果
func _mock_layout(loc: Dictionary) -> Dictionary:
	var layouts := {
		"village": [
			{"id": "crate", "direction": "南", "ring": "近", "count": 2},
			{"id": "barrel", "direction": "东南", "ring": "近", "count": 2},
			{"id": "signpost", "direction": "西南", "ring": "近", "count": 1},
		],
		"mine": [
			{"id": "ore", "direction": "东南", "ring": "近", "count": 3},
			{"id": "boulder", "direction": "东北", "ring": "中", "count": 2},
			{"id": "crate", "direction": "西南", "ring": "中", "count": 1},
		],
		"shrine": [
			{"id": "campfire", "direction": "南", "ring": "近", "count": 1},
			{"id": "bush", "direction": "东南", "ring": "中", "count": 3},
			{"id": "grass", "direction": "西北", "ring": "中", "count": 3},
		],
		"forest": [
			{"id": "pine", "direction": "北", "ring": "远", "count": 4},
			{"id": "bush", "direction": "西南", "ring": "中", "count": 3},
			{"id": "grass", "direction": "东", "ring": "近", "count": 3},
		],
		"ruin": [
			{"id": "boulder", "direction": "西", "ring": "中", "count": 2},
			{"id": "crate", "direction": "南", "ring": "近", "count": 2},
			{"id": "grass", "direction": "北", "ring": "中", "count": 3},
		],
		"bridge": [
			{"id": "grass", "direction": "北", "ring": "中", "count": 3},
			{"id": "signpost", "direction": "北", "ring": "近", "count": 1},
		],
	}
	var kind := str(loc.get("kind", ""))
	if not layouts.has(kind):
		return {"props": [
			{"id": "bush", "direction": "北", "ring": "中", "count": 2},
			{"id": "grass", "direction": "南", "ring": "近", "count": 3},
		]}
	return {"props": layouts[kind]}


# ---------------------------------------------------------------- 落地

## 把「摆什么、哪个方位、离多远」翻译成真实坐标，逐个校验后发出去
func _finalize(loc: Dictionary, data: Dictionary) -> void:
	var loc_id := str(loc.get("id", ""))
	if loc_id == "":
		return
	_decorated[loc_id] = true
	_rng.seed = hash(loc_id)

	var placements: Array[Dictionary] = []
	var entries = data.get("props", [])
	if typeof(entries) != TYPE_ARRAY:
		entries = []
	for item in entries:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var id := str(item.get("id", "")).strip_edges()
		var prop := PropLibrary.by_id(id)
		if prop.is_empty():
			continue
		var ring_name := str(item.get("ring", "中")).strip_edges()
		var base_idx := DIRECTIONS.find(str(item.get("direction", "北")).strip_edges())
		if base_idx < 0:
			base_idx = 0
		var count := clampi(int(item.get("count", 1)), 1, 6)
		for i in count:
			if placements.size() >= MAX_PLACEMENTS:
				break
			var idx := base_idx
			if i > 0:
				# 同一簇里的多件东西左右错开摆，免得叠在一起
				var step := (i + 1) / 2
				idx = _wrap8(base_idx + (step if i % 2 == 1 else -step))
			var spot = _find_spot(idx, ring_name, loc)
			if spot == null:
				continue
			var p: Vector2 = spot
			var organic: bool = ORGANIC_SHAPES.has(str(prop.get("shape", "")))
			placements.append({
				"prop_id": id,
				"pos": p,
				"rot": _rng.randf_range(-0.12, 0.12) if organic else 0.0,
				"scale": _rng.randf_range(0.9, 1.12) if organic else 1.0,
				"size": prop.get("size", Vector2(64, 64)),
				"solid": bool(prop.get("solid", false)),
			})
			_placed.append({"pos": p})

	_placements_by_loc[loc_id] = placements
	props_placed.emit(loc_id, placements)


# ---------------------------------------------------------------- 存档

## 把每个地点摆好的道具落档（坐标拆成 x/y），读档时照原样还原。
func to_save() -> Dictionary:
	var out := {}
	for loc_id in _placements_by_loc:
		out[str(loc_id)] = _serialize_placements(_placements_by_loc[loc_id])
	return {"placements": out}


## 读档：恢复各地点已摆好的道具，并标记这些地点「已布置过」，
## 避免 decorate_existing 再用离线模板重铺一遍。真实坐标直接取自存档，
## 不再重新走一遍校验（否则 RNG 会给出不一样的结果）。
func from_save(data: Dictionary) -> void:
	_decorated.clear()
	_placed.clear()
	_placements_by_loc.clear()
	var placements = data.get("placements", {})
	if typeof(placements) != TYPE_DICTIONARY:
		return
	for loc_id in placements:
		var items = placements[loc_id]
		if typeof(items) != TYPE_ARRAY:
			continue
		var arr := _deserialize_placements(items)
		var key := str(loc_id)
		_placements_by_loc[key] = arr
		_decorated[key] = true
		for p in arr:
			_placed.append({"pos": p["pos"]})


func _serialize_placements(arr: Array) -> Array:
	var out: Array = []
	for item in arr:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var p: Vector2 = item.get("pos", Vector2.ZERO)
		var s: Vector2 = item.get("size", Vector2(64, 64))
		out.append({
			"prop_id": str(item.get("prop_id", "")),
			"pos": {"x": p.x, "y": p.y},
			"rot": float(item.get("rot", 0.0)),
			"scale": float(item.get("scale", 1.0)),
			"size": {"x": s.x, "y": s.y},
			"solid": bool(item.get("solid", false)),
		})
	return out


func _deserialize_placements(arr: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for item in arr:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var prop_id := str(item.get("prop_id", ""))
		if prop_id == "":
			continue
		var size := _to_vec2(item.get("size", {}))
		if size == Vector2.ZERO:
			size = Vector2(64, 64)
		out.append({
			"prop_id": prop_id,
			"pos": _to_vec2(item.get("pos", {})),
			"rot": float(item.get("rot", 0.0)),
			"scale": float(item.get("scale", 1.0)),
			"size": size,
			"solid": bool(item.get("solid", false)),
		})
	return out


func _to_vec2(d) -> Vector2:
	if typeof(d) == TYPE_DICTIONARY:
		return Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))
	return Vector2.ZERO

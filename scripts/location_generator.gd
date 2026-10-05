extends Node
## 地点生成器（Autoload 名字：LocationGenerator）
## 让 AI 在世界上「造」出一个新地点，并把它真正加进 WorldData 与地图。
##
## 「MC 式区块」思路：先挑一块目标区域（RegionGenerator 的 Voronoi 区域），
## 再用该区域所属文化圈的 types 收窄可生成的类型（金合欢丛林只长金合欢村庄），
## 最后把地点落在这块区域里。于是「什么地形出什么聚落、说什么话」自然对齐。
##
## 关键约束（和任务生成同样的思路：生成 → 校验 → 重试 → 兜底）：
##   1. kind 只能是该区域文化圈 kinds_of() 里的值，否则地图画不出来 / 与地形不符；
##   2. 新地点不能重名（母村名字因此永不被顶替）；
##   3. 落点由我们自己算，保证在区域里、不越过溪流、不和已有地点挤在一起。
## id 一律是「区域格坐标 + 格内序号」，例如 mine_3_-2_01。

signal location_created(loc: Dictionary)
signal location_failed(reason: String)

const MAX_RETRY := 1
const PX_PER_METER := 20.0

## 8 个方向（原始向量，用时归一化）。也用于 _direction_of 的罗盘换算。
const DIR_VECTORS := [
	Vector2(0, -1), Vector2(1, -1), Vector2(1, 0), Vector2(1, 1),
	Vector2(0, 1), Vector2(-1, 1), Vector2(-1, 0), Vector2(-1, -1),
]

## 挑目标区域：只在出生点附近这个半径内的区域里找。够大能一直往外长，
## 又不会远到玩家这辈子走不到。
const TARGET_RADIUS := 4400.0
## 在区域内找落点时，从种子点中心向外尝试的半径档（格边长约 1100）。
const SPOT_TRIES := [0.0, 130.0, 280.0, 450.0, 640.0]

## 溪流（中心线 y=1010、半宽 90）。新地点不能落进水里，两岸都行。
const RIVER_Y := 1010.0
const RIVER_H := 90.0
## 新地点之间、以及和已有地点之间的最小间距
const MIN_SPACING := 340.0

## ---- 流式预生成（MC 式「走到哪生成哪」）----
## 玩家周围这个半径内的区域，会被提前检查、提前生成。它远大于玩家一眼能看到的范围，
## 所以等玩家真走过去时，房子和人早就摆好了。
const STREAM_RADIUS := 3200.0
## 每隔这么久扫一次玩家周围的区块（秒）
const STREAM_INTERVAL := 0.7
## 每次最多往生成队列里塞几个新地点，避免一帧之内堆爆
const STREAM_MAX_PER_TICK := 3
## 每个区块是不是「聚落」——由世界种子 + 格子坐标确定，同一世界永远一致。
const SETTLE_CHANCE := 0.14
const SALT_SETTLE := 918273551

## 城市：村子恰好落在平原上时，有多大机会升级成城市。
## 城镇要养得起工匠与市集，只有在平原上才立得住；村庄则哪儿都能长（丘陵、山脚都行）。
const CITY_CHANCE := 0.55
const SALT_CITY := 4477123

## 坏人据点别贴着出生点长——一出村就被一伙人围打，体验太差。
## 落点离母村太近就把据点降级成废墟（保留原名）。
const CAMP_MIN_FROM_HOME := 1500.0

## ---- 通天福地（全世界独一份的秘境）----
## 固定 id / 名字 / 选址盐值。位置由世界种子 + 盐值确定，同一世界永远落在同一处。
const TIANFU_ID := "tianfu_landmark"
const TIANFU_NAME := "通天福地"
const SALT_TIANFU := 761109337
const TIANFU_MIN_DIST := 2600.0
const TIANFU_MAX_DIST := 4200.0

## 离线兜底用的地点池
const MOCK_POOL := [
	{"name": "野猪岭", "kind": "forest", "desc": "村外的小山岭，据说入秋之后野猪成群。"},
	{"name": "枯井", "kind": "ruin", "desc": "一口早就不出水的枯井，井壁上刻着看不清的字。"},
	{"name": "羊肠道", "kind": "bridge", "desc": "两崖之间架起的窄木桥，风大时晃得厉害。"},
	{"name": "无名神龛", "kind": "shrine", "desc": "路边一座小神龛，香灰是新的，却从没见人来拜过。"},
	{"name": "塌方矿口", "kind": "mine", "desc": "早年塌方被封死的矿口，缝隙里还能看见微光。"},
	{"name": "老槐树林", "kind": "forest", "desc": "一片老槐树，树身粗得两个人才能合抱。"},
	{"name": "石碾场", "kind": "ruin", "desc": "废弃的打谷场，只剩一个裂了的石碾。"},
	{"name": "望乡台", "kind": "shrine", "desc": "高处一块平坦的石头，从这儿能望见整座村子。"},
	{"name": "小石村", "kind": "village", "desc": "路边一个安安静静的小村子，几户人家，一口老井。"},
	{"name": "黑风寨", "kind": "camp", "desc": "山道边一伙强人扎的寨子，夜里常有火光。"},
	{"name": "断刃营", "kind": "camp", "desc": "一群亡命徒的营盘，栅栏外插满了断掉的兵器。"},
	{"name": "鸦巢", "kind": "camp", "desc": "树上挂满黑鸦的匪寨，据说进去的人没几个出来。"},
]

var mode := "mock"
var api_base := "https://api.openai.com/v1"
var api_key := ""
var model := "gpt-4o-mini"

var _http: HTTPRequest
var _pending_ctx: Dictionary = {}
var _rng := RandomNumberGenerator.new()

## 生成队列（LLM 模式串行消费，mock 模式一次性跑完）。
## 每条 {npc_name, attempt, culture, cell}。
var _queue: Array[Dictionary] = []
## LLM 模式下一次只发一个请求，免得同时开出好几条 HTTP。
var _busy := false

## 流式：玩家最近一次上报的位置 / 朝向
var _player_pos := Vector2.ZERO
var _player_dir := Vector2(0.0, -1.0)
var _player_ready := false
var _stream_acc := 0.0
## 已经处理过的区块（生成过地点的，或确认过「这格没有聚落」的）——不再重复处理
var _done_cells: Dictionary = {}
## 上一次看到的 WorldData 地点数，用来在数量变化时把它们所在的格子补进 _done_cells
var _seen_loc_count := -1


func _ready() -> void:
	_rng.randomize()
	_http = HTTPRequest.new()
	_http.request_completed.connect(_on_request_completed)
	add_child(_http)
	_load_config()


func _load_config() -> void:
	# 配置统一由 LlmConfig 下发（res:// 默认 + user:// 玩家设置）
	LlmConfig.apply_to(self)
	print("[LocationGenerator] 地点模式 = %s" % mode)


# ---------------------------------------------------------------- 流式入口

## 玩家每帧把位置报过来。据此更新「人在哪、往哪走」，_process 里据此预生成。
func report_player_position(pos: Vector2) -> void:
	if not _player_ready:
		_player_ready = true
		_player_pos = pos
		return
	var delta := pos - _player_pos
	if delta.length_squared() > 1.0:
		_player_dir = delta.normalized()
	_player_pos = pos


func _process(delta: float) -> void:
	if not _player_ready:
		return
	_stream_acc += delta
	if _stream_acc < STREAM_INTERVAL:
		return
	_stream_acc = 0.0
	_stream()


## 扫一遍玩家周围的区块：把「有聚落但还没生成」的格子排队生成，正前方的优先。
func _stream() -> void:
	_sync_done_cells()
	var pending: Array = []
	for region in RegionGenerator.regions_in_radius(_player_pos, STREAM_RADIUS):
		var cell: Vector2i = region["cell"]
		if _done_cells.has(cell):
			continue
		# 这格天生不长聚落 → 记下来，以后不用再算
		if not _cell_has_settlement(cell):
			_done_cells[cell] = true
			continue
		# 有聚落但落点被占了（离已有地点太近）→ 也记下来（地点只会越加越多，不会再腾出空位）
		if _find_spot_in_cell(cell) == null:
			_done_cells[cell] = true
			continue
		pending.append(region)
	if pending.is_empty():
		return
	pending.sort_custom(_stream_score)
	var n := 0
	for region in pending:
		if n >= STREAM_MAX_PER_TICK:
			break
		_enqueue(region["cell"], "")
		n += 1
	if n > 0:
		print("[LocationGenerator] 视野内预生成 %d 个新地点（玩家 %s）" % [n, str(_player_pos.round())])


## 排序：正前方、离得近的先排前（分越小越靠前）
func _stream_score(a: Dictionary, b: Dictionary) -> bool:
	return _stream_rank(a) < _stream_rank(b)


func _stream_rank(region: Dictionary) -> float:
	var v: Vector2 = (region["center"] as Vector2) - _player_pos
	var d := v.length()
	var ahead := 0.0
	if d > 1.0:
		ahead = v.dot(_player_dir) / d   # 正前方 = 1，正后方 = -1
	return d - ahead * STREAM_RADIUS * 0.6


## 这一格是不是聚落（纯由世界种子 + 格子坐标决定，可复现）
func _cell_has_settlement(cell: Vector2i) -> bool:
	return RegionGenerator.rng_for(cell, SALT_SETTLE).randf() < SETTLE_CHANCE


## 把「已经存在的地点」所在的格子补记进 _done_cells（读档 / 基础地点天然占坑）
func _sync_done_cells() -> void:
	var count := WorldData.LOCATIONS.size()
	if count == _seen_loc_count:
		return
	_seen_loc_count = count
	for loc in WorldData.LOCATIONS:
		var pos: Vector2 = loc["pos"]
		_done_cells[RegionGenerator.cell_at(pos)] = true


## 外部入口之一：NPC 闲聊时打听一个新地点（在出生点附近挑一块空区域）
func request_location(npc_name: String = "村民") -> void:
	# 先挑一块目标区域；地点归哪个文化圈，由这块区域的风格决定
	var cell = _pick_target_cell()
	if cell == null:
		_fail("附近暂时找不到合适的地方再添新地点了")
		return
	_enqueue(cell, npc_name)


## 外部入口之二：主线终局用。指定某块区域强行生成一个地点，
## 好让「剧情指向的地方」在任务发出的那一刻就已经真实存在（发任务即承诺）。
## 返回 false 表示这块区域现在没法落地（已经在队列里 / 没有空位）。
func request_location_at(cell: Vector2i) -> bool:
	if _done_cells.has(cell):
		return false
	if _find_spot_in_cell(cell) == null:
		return false
	_enqueue(cell, "", true)
	return true


## 通天福地：全世界独一份的秘境，开局就确定性地落地，永远只有一处。
## 不走 LLM 队列——它是「事先就存在」的地方（发任务即承诺），位置由世界种子决定，
## 同一存档每次进游戏都落在同一处。已经在世界上就直接返回（天然幂等）。
func ensure_tianfu() -> Dictionary:
	if WorldData.has_id(TIANFU_ID):
		return WorldData.by_id(TIANFU_ID)
	var pos := _tianfu_pos()
	var origin := _origin()
	var loc := {
		"id": TIANFU_ID,
		"name": TIANFU_NAME,
		"kind": "tianfu",
		"culture": "tianfu",
		"pos": pos,
		"desc": "传说藏在云海尽头的通天福地：白玉阶、琉璃瓦，遍地奇珍异宝，住着的都是绝色美人，见者有份。",
		"direction": _direction_of(pos - origin),
		"distance_m": int(pos.distance_to(origin) / PX_PER_METER),
	}
	if not WorldData.add_location(loc):
		return {}
	_done_cells[RegionGenerator.cell_at(pos)] = true
	location_created.emit(loc)
	print("[LocationGenerator] 通天福地落在 %s，位于出生点%s约 %d 米" % [str(pos.round()), loc["direction"], loc["distance_m"]])
	return loc


## 通天福地选址：先确定性挑一块远景空地；万一挑不到，再绕着出生点一圈圈外扩兜底。
func _tianfu_pos() -> Vector2:
	var cell = pick_far_cell(TIANFU_MIN_DIST, TIANFU_MAX_DIST, SALT_TIANFU, [])
	if cell != null:
		var spot = _find_spot_in_cell(cell)
		if spot != null:
			return spot
	return _tianfu_fallback_pos()


## 兜底选址：从出生点向外螺旋找第一块可用空地，保证福地一定存在于世上。
func _tianfu_fallback_pos() -> Vector2:
	var origin := _origin()
	for ring in range(1, 80):
		var r := float(ring) * 240.0
		for i in 12:
			var a := TAU * float(i) / 12.0 + float(ring) * 0.5
			var p: Vector2 = origin + Vector2(cos(a), sin(a)) * r
			if _spot_ok(p, RegionGenerator.cell_at(p)):
				return p
	return origin + Vector2(0.0, -TIANFU_MIN_DIST)


## 在「距出生点 min_dist ~ max_dist 像素」的环带里，确定性地挑一块能落地的区域。
## 用世界种子做种子：同一个世界、同一个 salt 永远挑到同一块地，读档也不会变。
## used 里是本次已经挑走的格子，避免三站挑到同一处。
func pick_far_cell(min_dist: float, max_dist: float, salt: int, used: Array) -> Variant:
	var origin := _origin()
	var rng := RandomNumberGenerator.new()
	rng.seed = int(RegionGenerator.world_seed) ^ salt
	for _i in 160:
		var ang := rng.randf() * TAU
		var r := rng.randf_range(min_dist, max_dist)
		var p: Vector2 = origin + Vector2(cos(ang), sin(ang)) * r
		var cell := RegionGenerator.cell_at(p)
		if _done_cells.has(cell) or used.has(cell):
			continue
		var spot = _find_spot_in_cell(cell)
		if spot == null:
			continue
		# 落点要真的落在环带里（种子点可能被挤到环带外）
		var d: float = (spot as Vector2).distance_to(origin)
		if d < min_dist or d > max_dist:
			continue
		return cell
	return null


## 把一块区域排进生成队列（立刻标成「处理过」，避免重复）。
## story=true 表示这是主线终局的地点：主场景不会自动给它安排住客，
## 由剧情导演按终局链自己指定人，并把它标出来。
func _enqueue(cell: Vector2i, npc_name: String = "", story: bool = false) -> void:
	if _done_cells.has(cell):
		return
	_done_cells[cell] = true
	var cid := str(RegionGenerator.region_of_cell(cell)["culture"])
	_queue.append({
		"npc_name": npc_name,
		"attempt": 0,
		"culture": cid,
		"cell": cell,
		"story": story,
	})
	_pump()


## 消费队列。mock 模式一次性跑完（地点当场就位）；LLM 模式串行、一次一个请求。
func _pump() -> void:
	if _busy or _queue.is_empty():
		return
	if mode == "llm" and api_key != "":
		_busy = true
		_pending_ctx = _queue.pop_front()
		_call_llm(_pending_ctx)
		return
	while not _queue.is_empty():
		_pending_ctx = _queue.pop_front()
		_finalize(_mock_location())
	_pending_ctx = {}


## 一个地点生成完毕（LLM 模式用）：收尾并继续消费队列
func _finish(data: Dictionary) -> void:
	_finalize(data)
	_busy = false
	_pending_ctx = {}
	call_deferred("_pump")


# ---------------------------------------------------------------- LLM 模式

func _system_prompt() -> String:
	var cid := str(_pending_ctx.get("culture", CultureData.current_id))
	var kinds: Array = CultureData.kinds_of(cid)
	return """你是一个 2D 冒险游戏的世界地图生成器。
你只能输出一个 JSON 对象，不要输出任何解释文字，也不要使用 markdown 代码块。
JSON 的字段必须严格如下：
- name: 字符串，新地点的名字（中文，2-6 个字，要有画面感）
- kind: 字符串，必须是下面这些类型之一：%s
- desc: 字符串，1-3 句中文描述，说明这里是什么样子、有什么传闻

这个地方的样子：%s
世界观：%s 不要引入现代或科幻元素。
要求：新地点要能和现有的地点共存，不要和已有地点重名（尤其是别和当地的村子同名），也不要只是换了个说法的同一个地方。
世界上现有的地点：
%s""" % [
		"、".join(PackedStringArray(kinds)),
		CultureData.style_of(cid),
		CultureData.worldview_of(cid),
		WorldData.prompt_list(),
	]


func _call_llm(ctx: Dictionary) -> void:
	var npc_name := str(ctx.get("npc_name", ""))
	var user_prompt := ""
	if npc_name == "":
		# 流式：玩家走到了世界上一片新区域，凭空为这里生成一个地点
		user_prompt = "玩家走到了一片此前从未有人踏足的区域，请为这里凭空生成一个新的地点。"
	else:
		user_prompt = "%s在村口跟你闲聊，提到附近还有个地方——请据此生成一个新的地点。" % npc_name
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
		push_warning("[LocationGenerator] 请求发起失败(%d)，回退 mock" % err)
		_finish(_mock_location())


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		var detail := body.get_string_from_utf8().left(300)
		push_warning("[LocationGenerator] LLM 调用失败(result=%d, code=%d)：%s" % [result, response_code, detail])
		_finish(_mock_location())
		return

	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("choices"):
		push_warning("[LocationGenerator] LLM 返回结构异常，回退 mock")
		_finish(_mock_location())
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

	_finish(data)


func _retry_or_fallback(reason: String) -> void:
	var attempt := int(_pending_ctx.get("attempt", 0))
	if attempt < MAX_RETRY:
		_pending_ctx["attempt"] = attempt + 1
		_pending_ctx["fix_hint"] = reason
		push_warning("[LocationGenerator] 生成不合格（%s），让模型重试一次" % reason)
		_call_llm(_pending_ctx)
		return
	push_warning("[LocationGenerator] 重试仍不合格（%s），回退离线模板" % reason)
	_finish(_mock_location())


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
	var cid := str(_pending_ctx.get("culture", CultureData.current_id))
	var name := str(data.get("name", "")).strip_edges()
	if name == "":
		return "缺少 name 字段"
	if WorldData.has_name(name):
		return "地点名「%s」已经存在了，请换一个不一样的名字" % name
	var kinds: Array = CultureData.kinds_of(cid)
	var kind := str(data.get("kind", "")).strip_edges()
	if not kinds.has(kind):
		return "kind 只能是这片地区会出现的类型：%s" % "、".join(PackedStringArray(kinds))
	if str(data.get("desc", "")).strip_edges() == "":
		return "缺少 desc 字段"
	return ""


# ---------------------------------------------------------------- 选区域 / 找落点

## 挑一块目标区域（返回它的格子坐标）。优先挑「中心还没被占、也没被溪流穿过」的区域。
func _pick_target_cell() -> Variant:
	var origin := _origin()
	var candidates: Array = []
	for region in RegionGenerator.regions_in_radius(origin, TARGET_RADIUS):
		var cell: Vector2i = region["cell"]
		var center: Vector2 = region["center"]
		if _in_water(center):
			continue
		if _done_cells.has(cell):
			continue
		if _find_spot_in_cell(cell) == null:
			continue
		candidates.append(cell)
	if candidates.is_empty():
		return null
	return candidates[_rng.randi() % candidates.size()]


## 这一点是不是落在水里（溪流带，或最南端的大海；只算水，两岸不算）
func _in_water(p: Vector2) -> bool:
	return absf(p.y - RIVER_Y) < RIVER_H + 60.0 or RegionGenerator.is_sea(p)


## 在某块区域里找一个空落点：先试种子点本身，再绕着它一圈圈往外试。
## 落点必须仍属于这块区域（cell_at == cell），否则会「名不副实」——
## 地图按目标区域的风格画它，人却站在隔壁区域的地界上。
func _find_spot_in_cell(cell: Vector2i) -> Variant:
	var center := RegionGenerator.seed_point(cell)
	if _spot_ok(center, cell):
		return center
	for i in DIR_VECTORS.size():
		var d: Vector2 = DIR_VECTORS[i].normalized()
		for r in SPOT_TRIES:
			var rr := float(r)
			if rr <= 0.0:
				continue
			var p: Vector2 = center + d * rr
			if _spot_ok(p, cell):
				return p
	return null


func _spot_ok(p: Vector2, cell: Vector2i) -> bool:
	return RegionGenerator.cell_at(p) == cell and _is_spot_free(p)


func _is_spot_free(p: Vector2) -> bool:
	# 别把新地点造到水里
	if _in_water(p):
		return false
	# 也别把聚落盖在高山上（山是天然屏障，人烟留在平地与丘陵）
	if RegionGenerator.is_highland(p):
		return false
	for loc in WorldData.LOCATIONS:
		if p.distance_to(loc["pos"]) < MIN_SPACING:
			return false
	return true


## 出生点（母村）的坐标，用作「附近」的圆心
func _origin() -> Vector2:
	var home := WorldData.by_id(CultureData.HOME_ID)
	if home.is_empty():
		return Vector2.ZERO
	var p: Vector2 = home.get("pos", Vector2.ZERO)
	return p


## 把「相对出生点的方向」翻译成中文方位（和 HUD 罗盘用的是同一套换算）
func _direction_of(v: Vector2) -> String:
	var names := ["东", "东南", "南", "西南", "西", "西北", "北", "东北"]
	var idx := int(round(v.angle() / (PI / 4.0)))
	return names[((idx % 8) + 8) % 8]


# ---------------------------------------------------------------- 离线模板

func _mock_location() -> Dictionary:
	var cid := str(_pending_ctx.get("culture", CultureData.current_id))
	var kinds: Array = CultureData.kinds_of(cid)
	var pool: Array[Dictionary] = []
	for item in MOCK_POOL:
		if not kinds.has(str(item["kind"])):
			continue
		if WorldData.has_name(str(item["name"])):
			continue
		pool.append(item)
	if not pool.is_empty():
		return pool[_rng.randi() % pool.size()].duplicate()
	# 池子用完了（或这个 biome 没有池子里的类型）→ 用词根现拼一个不重名的
	var kind := str(kinds[_rng.randi() % kinds.size()])
	for n in range(1, 200):
		var candidate := CultureData.compose_name(cid, kind, _rng.randi() + n)
		if not WorldData.has_name(candidate):
			return {"name": candidate, "kind": kind, "desc": "当地人偶尔提起的一处地方，没几个人真去过。"}
	return {"name": "无名之地", "kind": kind, "desc": "一处没什么人记得的地方。"}


# ---------------------------------------------------------------- 落地

func _finalize(data: Dictionary) -> void:
	var cell = _pending_ctx.get("cell", null)
	if typeof(cell) != TYPE_VECTOR2I:
		_fail("内部错误：没有选中目标区域")
		return
	var spot = _find_spot_in_cell(cell)
	if spot == null:
		_fail("这片区域已经排满了，暂时造不出新地点")
		return

	var pos: Vector2 = spot
	var origin := _origin()
	var kind := str(data.get("kind", "ruin")).strip_edges()
	var loc_name := str(data.get("name", "无名之地")).strip_edges()
	# 城市只在平原上立得住；村子恰好落在平原时才有机会升级成城市。
	# 村庄本身任何地形都能生成，不动。
	if kind == "village" and _can_be_city(pos, cell):
		kind = "city"
		loc_name = _city_name(loc_name, cell)
	# 坏人据点不能贴着出生点长：太近就降级成废墟（名字留着），免得玩家一出村就挨打
	if kind == "camp" and pos.distance_to(origin) < CAMP_MIN_FROM_HOME:
		kind = "ruin"
	var loc := {
		"id": _region_id(kind, cell),
		"name": loc_name,
		"kind": kind,
		"culture": str(_pending_ctx.get("culture", CultureData.current_id)),
		"pos": pos,
		"desc": str(data.get("desc", "")).strip_edges(),
		# 下面两个字段只用于界面显示：方位按真实落点算，避免和实际位置对不上
		"direction": _direction_of(pos - origin),
		"distance_m": int(pos.distance_to(origin) / PX_PER_METER),
	}
	# 主线终局的地点：主场景不自动给它安排住客，由剧情导演按终局链指定人
	if bool(_pending_ctx.get("story", false)):
		loc["story"] = true
	if not WorldData.add_location(loc):
		_fail("地点「%s」没能加进世界（可能重名或类型不合法）" % loc["name"])
		return
	location_created.emit(loc)


## id = 「类型 + 区域格坐标 + 格内序号」，例如 mine_3_-2_01
func _region_id(kind: String, cell: Vector2i) -> String:
	var id := ""
	for n in range(1, 1000):
		id = "%s_%d_%d_%02d" % [kind, cell.x, cell.y, n]
		if not WorldData.has_id(id):
			return id
	return id


## 城市只长在平原上：地形必须正好是 plain，再按确定性随机决定要不要升级。
## 用 rng_for(cell, salt) 保证同一格结果一致（换个存档、重进游戏都一样）。
func _can_be_city(p: Vector2, cell: Vector2i) -> bool:
	if RegionGenerator.terrain_at(p) != "plain":
		return false
	var rng := RegionGenerator.rng_for(cell, SALT_CITY)
	return rng.randf() < CITY_CHANCE


## 把村名末尾的「村/屯/坞/寨」换成城名后缀（城/镇/邑/府）。
## 名字不合规则就不改，宁可保留原名也不硬套。
func _city_name(name: String, cell: Vector2i) -> String:
	if name.length() < 2:
		return name
	var last := name.substr(name.length() - 1, 1)
	if not ["村", "屯", "坞", "寨"].has(last):
		return name
	var suffixes: Array = CultureData.KIND_SUFFIX.get("city", ["城"])
	var rng := RegionGenerator.rng_for(cell, SALT_CITY + 7)
	var pick := str(suffixes[rng.randi() % suffixes.size()])
	return name.substr(0, name.length() - 1) + pick


func _fail(reason: String) -> void:
	push_warning("[LocationGenerator] %s" % reason)
	location_failed.emit(reason)

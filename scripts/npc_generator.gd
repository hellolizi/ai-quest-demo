extends Node
## NPC 生成器（Autoload 名字：NpcGenerator）
## 让 AI 在世界里「造」出一个新 NPC，把他安置到某个已有地点（也就是他的住处）。
##
## 和地点/任务生成走同一条管线：生成 → 校验 → 重试 → 兜底。
## AI 只负责「编内容」（名字、身份、性格、开场白），站位由代码算，保证他一定站得住、
## 而且不会和世界上已经有的人重名。

signal npc_created(npc: Dictionary)
signal npc_failed(reason: String)

const MAX_RETRY := 1
const GREETINGS_MAX := 8
## 站位：绕着住处一圈一圈往外排，每圈 6 个。
## 用环状分布而不是固定几个槽位，一个地方住得下多少人都不重叠。
const RING_PER := 6
const RING_BASE_RADIUS := 130.0
const RING_GAP := 92.0

## 离线兜底用的 NPC 池。kind 表示「住在哪种地方的人更合适」。
const MOCK_POOL := [
	{"name": "矿工 石根", "kind": "mine", "role": "矿洞里的老矿工",
		"personality": "嗓门大、爱吹牛，讲起矿脉的事就手舞足蹈，其实胆子和老鼠差不多。",
		"greetings": ["嘿！别往深处走，昨儿才塌过一截。", "你也来找矿？我劝你省省力气。", "这山肚子里的门道，我闭着眼都摸得清。", "听，滴水声变了——要坏事。"]},
	{"name": "庙祝 云隐", "kind": "shrine", "role": "守着山腰小庙的人",
		"personality": "半句不离因果，说话绕弯子，看似出尘其实心里记挂着村里每个人。",
		"greetings": ["来了，就坐。茶凉了，心别凉。", "你说的事，我听见了，山也听见了。", "香火断过三年，人心里那盏倒还亮着。", "别急着问结果，先问问自己为什么来。"]},
	{"name": "樵夫 阿禾", "kind": "forest", "role": "进山砍柴的樵夫",
		"personality": "憨厚话多，怕黑又嘴硬，一进林子就忍不住东张西望。",
		"greetings": ["这林子白天也瘆人，你咋一个人来？", "我砍我的柴，你走你的道，别走散。", "听见没？风一停，鸟也不叫了。", "要我说，天黑前一定得出去。"]},
	{"name": "磨坊主 老周", "kind": "ruin", "role": "守着一座塌了半边的旧磨坊",
		"personality": "絮叨而固执，坚信磨坊还会重新转起来，总念叨着当年粮车排到村口。",
		"greetings": ["这磨坊啊，从前一天能磨三十担。", "风车停了，可风还在——会转的。", "你别笑我，我等的不是风，是人回来。", "东边那面墙，雨一大就渗水，唉。"]},
	{"name": "守桥人 石老", "kind": "bridge", "role": "看管断石桥的老翁",
		"personality": "沉默寡言，做事一板一眼，认定了要守的桥就死活不肯离。",
		"greetings": ["桥断了一半，可我还在。", "过桥慢些，脚下的石头会咬人。", "夜里水声大，别在桥上待着。", "你要去哪边？说一声，我给你看着。"]},
	{"name": "货郎 三顺", "kind": "village", "role": "走村串户的货郎",
		"personality": "精明热情、嘴皮子极溜，开口就是价钱，可熟人赊账他从不催。",
		"greetings": ["来来来，看看我这担子！", "价钱好说，先看货。", "这条道我走了十年，哪儿有坑我门儿清。", "要是没带钱，记我账上，不急。"]},
	{"name": "织妇 芦花", "kind": "village", "role": "在村口织布的女人",
		"personality": "温柔心细，耳朵极灵，全村的大小事都从她织机声里传出去。",
		"greetings": ["坐会儿吧，我把这寸布织完。", "线断了能接，人走散了可就难了。", "你衣角的线头松了，来，我替你缝上。", "村里的事，风一吹，我这织机先知道。"]},
	{"name": "游医 半夏", "kind": "shrine", "role": "背着药箱四处行医的人",
		"personality": "爽利直率，救人不问身份，就是嘴上从不让人，见你逞强就要数落两句。",
		"greetings": ["伸手，我看你气色就知道你几夜没睡好。", "别硬撑，硬撑的都没好下场。", "药我给你，钱你有就付，没有就欠着。", "外伤好治，心上的伤，得自己肯说。"]},
]

var mode := "mock"
var api_base := "https://api.openai.com/v1"
var api_key := ""
var model := "gpt-4o-mini"

var _http: HTTPRequest
## 正在生成的那一条（单请求时管线只认它）
var _pending_ctx: Dictionary = {}
## 排队等待生成的地点。一个地方可能一次要住好几个人，
## 而 HTTP 请求一次只能跑一条，所以排队串行处理，避免互相覆盖。
var _queue: Array[Dictionary] = []
var _busy := false
## 世界上已经存在的 NPC 名字，避免生成同名的人
var _known_names: Array[String] = []
## 名字 -> 身份，喂给 AI 时让它知道世上都有什么样的人（关系也更有由头）
var _known_roles: Dictionary = {}

## 运行时新增的 NPC 档案（存档用）。读档后由 main.gd 逐一生成到场景里。
var dynamic_npcs: Array[Dictionary] = []


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.request_completed.connect(_on_request_completed)
	add_child(_http)
	_load_config()


func _load_config() -> void:
	# 配置统一由 LlmConfig 下发（res:// 默认 + user:// 玩家设置）
	LlmConfig.apply_to(self)
	print("[NpcGenerator] 角色模式 = %s" % mode)


# ---------------------------------------------------------------- 名字登记

## 主场景启动时，把场上已有的 NPC 名字登记进来（含读档回来的），避免重名
func note_name(npc_name: String, role: String = "") -> void:
	var n := npc_name.strip_edges()
	if n == "":
		return
	if not _known_names.has(n):
		_known_names.append(n)
	var r := role.strip_edges()
	if r != "" and str(_known_roles.get(n, "")) == "":
		_known_roles[n] = r
	NpcRelations.register(n)


func is_name_used(npc_name: String) -> bool:
	return _known_names.has(npc_name.strip_edges())


## 登记一个「预先写好」的 NPC（不经过 AI 生成），并让他立刻入场。
## 通天福地的住客就是手写固定的，不该被 AI 换掉，也要能随存档一起留下。
## data 需要 name / role / personality / greetings，可选 home_id / home_name / culture / offset / appearance。
func register_authored(data: Dictionary) -> void:
	var npc_name := str(data.get("name", "")).strip_edges()
	if npc_name == "" or is_name_used(npc_name):
		return
	var npc := data.duplicate(true)
	npc["name"] = npc_name
	npc["role"] = str(npc.get("role", "村民")).strip_edges()
	npc["personality"] = str(npc.get("personality", "")).strip_edges()
	npc["greetings"] = _normalize_greetings(npc.get("greetings", []))
	if npc["role"] == "" or npc["personality"] == "" or (npc["greetings"] as Array).is_empty():
		return
	var cid := str(npc.get("culture", CultureData.current_id))
	var tier := str(npc.get("tier", ""))
	if tier == "":
		tier = CharacterSprite.tier_for_kind(_kind_of(str(npc.get("home_id", ""))))
	npc["tier"] = tier
	# 长相：没有自带外观就按名字稳定推导（同一个人每次长得一样），绝色池由 culture 决定
	npc["appearance"] = CharacterSprite.merge_appearance(
		CharacterSprite.derive_appearance(npc_name, cid, tier),
		npc.get("appearance", null),
	)
	# 站位统一成 {x, y} 字典，和 AI 生成的 NPC 保持一致，存 JSON 也稳妥
	var off = npc.get("offset", null)
	if typeof(off) == TYPE_VECTOR2:
		npc["offset"] = {"x": off.x, "y": off.y}
	elif typeof(off) != TYPE_DICTIONARY:
		npc["offset"] = {"x": 0.0, "y": 0.0}
	dynamic_npcs.append(npc)
	note_name(npc_name, str(npc["role"]))
	npc_created.emit(npc)


# ---------------------------------------------------------------- 外部入口

## 让 AI 给某个地点安排一个住客。home 是 WorldData 里的一个地点字典。
## 可以连续调用：请求会排队串行处理，一个地点要住几个人就调几次。
func request_npc(home: Dictionary) -> void:
	if home.is_empty() or not home.has("pos"):
		home = WorldData.by_id("village")
	_queue.append({"home": home, "attempt": 0})
	_pump()


## 从队列里取一条出来跑（当前没事干时才动）
func _pump() -> void:
	if _busy or _queue.is_empty():
		return
	_busy = true
	_pending_ctx = _queue.pop_front()
	if mode == "llm" and api_key != "":
		_call_llm(_pending_ctx)
	else:
		_finish(_mock_npc(_home_ctx()))


## 一条生成的终点：无论成功、重试失败还是兜底，都要走这里，
## 好把队列推进到下一条。
func _finish(data: Dictionary) -> void:
	_finalize(data)
	_busy = false
	_pending_ctx = {}
	# 延后一拍再跑下一条，避免在信号回调里递归调用
	call_deferred("_pump")


# ---------------------------------------------------------------- LLM 模式

func _system_prompt() -> String:
	var home := _home_ctx()
	var cid := str(home.get("culture", CultureData.current_id))
	var city_rule := ""
	if CharacterSprite.tier_for_kind(str(home.get("kind", ""))) == "city":
		city_rule = """
5. 这里是城市，居民穿着要更讲究体面：衣服优先 purple / teal / blue / gray，配饰优先 cape / scarf，发型优先 bun / braid / hat，体型优先 normal / slim，别选太寒酸的搭配。"""
	return """你是一个 2D 冒险游戏的角色生成器。
你只能输出一个 JSON 对象，不要输出任何解释文字，也不要使用 markdown 代码块。
JSON 的字段必须严格如下：
- name: 字符串，中文名字或称呼，2-8 个字，要带身份感（例如「货郎 三顺」）
- role: 字符串，这个人的身份/职业，4-12 个字
- personality: 字符串，1-2 句中文，写清楚这个人的性格和说话习惯
- greetings: 字符串数组，3-6 条开场白，每条 5-30 个汉字，语气必须符合上面的性格
- appearance: 对象，这个人的长相，六个字段的值都必须从下面的选项里挑一个：
  - skin（肤色）: pale | tan | brown | dark
  - hair（发色）: black | brown | blond | gray | white | red
  - hair_style（发型）: short | long | bun | bald | ponytail | braid | hat
  - clothes（衣服）: red | blue | green | yellow | brown | purple | gray | orange | teal
  - build（体型）: slim | normal | stout
  - accessory（配饰）: none | scarf | cape | apron | pack
- relations: 数组，这个人和「世界上已经有的人」沾的旧关系，0-2 条，可以为空数组。每条是对象：
  - target: 字符串，必须是上面「世界上已经有的人」里出现过的一个名字，一字不差
  - kind: 字符串，只能从这些里挑一个：亲属 | 师徒 | 邻居 | 同乡 | 旧识 | 同行 | 生意往来 | 对头
  - note: 字符串，一句话（12-30 字）说明这段关系的由来，要用第三人称写（「他」「她」或直接说事），
    这样从他俩谁嘴里说出来都讲得通。例如「早年在外乡一起讨过生活，后来才各奔东西」。
    只挑真的讲得通的关系，别硬凑；宁可为空数组。

世界观：%s 不要引入现代或科幻元素。
要求：
1. 这个人要住在下面给出的地点，身份和这个地方要搭得上；
2. 性格必须鲜明、和别人不一样，不要写成千篇一律的老好人；
3. 开场白要口语化，能听出这个人的脾气，不要客套话；
4. 长相要跟身份、性格相称（比如矿工多半 stout、樵夫多半穿 brown/green）。%s

他要住的地方：%s（%s）：%s
世界上已经有的人（不要重名，也不要写成雷同的性格）：
%s""" % [
		CultureData.worldview_of(cid),
		city_rule,
		str(home.get("name", CultureData.village_name())),
		str(home.get("kind", "village")),
		str(home.get("desc", "")),
		_known_names_block(),
	]


func _home_ctx() -> Dictionary:
	var home = _pending_ctx.get("home", {})
	return home if typeof(home) == TYPE_DICTIONARY else {}


func _known_names_block() -> String:
	if _known_names.is_empty():
		return "（暂时还没有别人）"
	var lines: PackedStringArray = []
	for n in _known_names:
		var r := str(_known_roles.get(n, "")).strip_edges()
		if r == "":
			lines.append("- " + n)
		else:
			lines.append("- %s（%s）" % [n, r])
	return "\n".join(lines)


func _call_llm(ctx: Dictionary) -> void:
	var user_prompt := "请给上面这个地方生成一个住在这里的新角色。"
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
		push_warning("[NpcGenerator] 请求发起失败(%d)，回退 mock" % err)
		_finish(_mock_npc(_home_ctx()))


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		var detail := body.get_string_from_utf8().left(300)
		push_warning("[NpcGenerator] LLM 调用失败(result=%d, code=%d)：%s" % [result, response_code, detail])
		_finish(_mock_npc(_home_ctx()))
		return

	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("choices"):
		push_warning("[NpcGenerator] LLM 返回结构异常，回退 mock")
		_finish(_mock_npc(_home_ctx()))
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
		push_warning("[NpcGenerator] 生成不合格（%s），让模型重试一次" % reason)
		_call_llm(_pending_ctx)
		return
	push_warning("[NpcGenerator] 重试仍不合格（%s），回退离线模板" % reason)
	_finish(_mock_npc(_home_ctx()))


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
	var npc_name := str(data.get("name", "")).strip_edges()
	if npc_name == "":
		return "缺少 name 字段"
	if is_name_used(npc_name):
		return "已经有一个叫「%s」的人了，请换一个不一样的名字" % npc_name
	if str(data.get("role", "")).strip_edges() == "":
		return "缺少 role 字段"
	if str(data.get("personality", "")).strip_edges() == "":
		return "缺少 personality 字段"
	var g = data.get("greetings", null)
	if typeof(g) != TYPE_ARRAY or (g as Array).is_empty():
		return "缺少 greetings 字段，或者它不是非空数组"
	for item in (g as Array):
		if str(item).strip_edges() == "":
			return "greetings 里出现了空句子，每一条都要是一句话"
	return ""


# ---------------------------------------------------------------- 离线模板

func _mock_npc(home: Dictionary) -> Dictionary:
	var kind := str(home.get("kind", ""))
	var pool: Array[Dictionary] = []
	for item in MOCK_POOL:
		if not is_name_used(str(item["name"])):
			pool.append(item)
	for item in pool:
		if str(item["kind"]) == kind:
			return item.duplicate(true)
	if not pool.is_empty():
		return pool[randi() % pool.size()].duplicate(true)
	# 池子也用完了，就随便挑一个并加个编号，保证世界能一直加人
	var base: Dictionary = MOCK_POOL[randi() % MOCK_POOL.size()].duplicate(true)
	base["name"] = "%s·%d" % [base["name"], dynamic_npcs.size() + 1]
	return base


# ---------------------------------------------------------------- 落地

## 第 index 个新 NPC 相对住处的站位：绕着住处一圈圈往外排
func _home_offset(index: int) -> Vector2:
	var ring := floori(index / float(RING_PER))
	var slot := index % RING_PER
	var radius := RING_BASE_RADIUS + ring * RING_GAP
	var angle := TAU * float(slot) / float(RING_PER) + float(ring) * 0.52
	return Vector2(cos(angle), sin(angle)) * radius


func _finalize(data: Dictionary) -> void:
	var npc_name := str(data.get("name", "")).strip_edges()
	if npc_name == "" or is_name_used(npc_name):
		var reason := "生成的角色名字不可用，换一个名字再试试"
		push_warning("[NpcGenerator] %s" % reason)
		npc_failed.emit(reason)
		return

	var home := _home_ctx()
	var cid := str(home.get("culture", CultureData.current_id))
	var tier := CharacterSprite.tier_for_kind(str(home.get("kind", "")))
	var off: Vector2 = _home_offset(dynamic_npcs.size())
	# 名字相同的角色每次进游戏都长得一样；AI 给了外观就按 AI 的来。
	# 城里的居民（tier=city）从更讲究的穿着池里挑。
	var appearance := CharacterSprite.merge_appearance(
		CharacterSprite.derive_appearance(npc_name, cid, tier),
		data.get("appearance", null),
	)
	var npc := {
		"name": npc_name,
		"role": str(data.get("role", "村民")).strip_edges(),
		"personality": str(data.get("personality", "")).strip_edges(),
		"greetings": _normalize_greetings(data.get("greetings", [])),
		"home_id": str(home.get("id", "village")),
		"home_name": str(home.get("name", CultureData.village_name())),
		"culture": cid,
		"tier": tier,
		"offset": {"x": off.x, "y": off.y},
		"appearance": appearance,
	}
	dynamic_npcs.append(npc)
	note_name(npc_name, str(npc["role"]))
	_apply_relations(npc_name, data.get("relations", []))
	npc_created.emit(npc)


## 把 AI 给出的 relations 落进关系网：只认已经登记过的人、双向去重。
## AI 没给（或给的全不可用）时，兜底帮这个新 NPC 至少在村里牵上一条线。
func _apply_relations(self_name: String, raw) -> void:
	NpcRelations.register(self_name)
	var applied := 0
	if typeof(raw) == TYPE_ARRAY:
		for item in (raw as Array):
			if typeof(item) != TYPE_DICTIONARY:
				continue
			var d: Dictionary = item
			var target := str(d.get("target", "")).strip_edges()
			if target == "" or target == self_name or not NpcRelations.is_registered(target):
				continue
			var kind := NpcRelations.sanitize_kind(str(d.get("kind", "")))
			var note := str(d.get("note", "")).strip_edges()
			if note == "":
				note = NpcRelations.note_for(kind)
			if NpcRelations.link(self_name, target, kind, note):
				applied += 1
	if applied == 0:
		_auto_relations(self_name)


## 兜底：从世上已登记的人里挑一个，用世界种子稳定地牵一条关系
func _auto_relations(self_name: String) -> void:
	for n in NpcRelations.known_names():
		if n == self_name:
			continue
		var kind := NpcRelations.auto_kind(self_name, n)
		if NpcRelations.link(self_name, n, kind, NpcRelations.note_for(kind)):
			return


func _normalize_greetings(raw) -> Array:
	var out: Array = []
	if typeof(raw) != TYPE_ARRAY:
		return out
	for item in (raw as Array):
		var t := str(item).strip_edges().strip_escapes()
		if t == "":
			continue
		out.append(t)
		if out.size() >= GREETINGS_MAX:
			break
	return out


# ---------------------------------------------------------------- 存档

func to_save() -> Dictionary:
	return {"npcs": dynamic_npcs.duplicate(true)}


func from_save(data: Dictionary) -> void:
	dynamic_npcs = []
	_known_names = []
	_known_roles = {}
	var list = data.get("npcs", [])
	if typeof(list) != TYPE_ARRAY:
		return
	for item in list:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var npc := _deserialize_npc(item)
		if npc.is_empty():
			continue
		dynamic_npcs.append(npc)
		note_name(str(npc["name"]), str(npc["role"]))


func _deserialize_npc(item: Dictionary) -> Dictionary:
	var npc_name := str(item.get("name", "")).strip_edges()
	if npc_name == "" or is_name_used(npc_name):
		return {}
	var role := str(item.get("role", "")).strip_edges()
	var personality := str(item.get("personality", "")).strip_edges()
	if role == "" or personality == "":
		return {}
	var greetings := _normalize_greetings(item.get("greetings", []))
	if greetings.is_empty():
		return {}
	var ox := 0.0
	var oy := 0.0
	var off = item.get("offset", {})
	if typeof(off) == TYPE_DICTIONARY:
		ox = float(off.get("x", 0.0))
		oy = float(off.get("y", 0.0))
	var cid := str(item.get("culture", CultureData.current_id))
	var home_id := str(item.get("home_id", "village"))
	# 档次：优先用存档里记的；老存档没有就从住处类型反推
	var tier := str(item.get("tier", ""))
	if tier == "":
		tier = CharacterSprite.tier_for_kind(_kind_of(home_id))
	# 老存档没有 appearance 字段，就从名字重新推导，长相依旧稳定
	var appearance := CharacterSprite.merge_appearance(
		CharacterSprite.derive_appearance(npc_name, cid, tier),
		item.get("appearance", null),
	)
	return {
		"name": npc_name,
		"role": role,
		"personality": personality,
		"greetings": greetings,
		"home_id": home_id,
		"home_name": str(item.get("home_name", CultureData.village_name())),
		"culture": cid,
		"tier": tier,
		"offset": {"x": ox, "y": oy},
		"appearance": appearance,
	}


## 地点 id → 地点类型（找不到就返回空串）。用来反推某个 NPC 住在哪种地方。
func _kind_of(loc_id: String) -> String:
	if loc_id == "":
		return ""
	var loc := WorldData.by_id(loc_id)
	return str(loc.get("kind", ""))

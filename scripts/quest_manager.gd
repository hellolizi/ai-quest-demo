extends Node
## 任务生成器（Autoload 名字：QuestManager）
## 两种模式：
##   mock —— 离线模板生成，不需要联网、不需要 Key
##   llm  —— 调用兼容 OpenAI 格式的大模型接口生成任务
##
## 约束：任务的目标地点必须是 WorldData 里真实存在的地点，
## 否则玩家会拿到一个「根本走不到」的任务。生成时会校验，不合格就重试，再不行回退模板。
##
## 支持同时进行多个任务：`quests` 是全部任务的流水，`active_quests()` 是手上还没做完的。
## HUD / 地图箭头只跟 `tracked_quest` 走，按 T 可以在几件任务之间轮换导航。

signal quest_generated(quest: Dictionary)
signal quest_accepted(quest: Dictionary)
## 玩家把事办完了，但还没回委托人那里复命
signal quest_reached(quest: Dictionary)
signal quest_completed(quest: Dictionary)
## 当前导航指向的任务变了（接受新任务、按 T 切换、追踪的任务状态变化）
signal tracked_changed(quest: Dictionary)

const MAX_RETRY := 1
## 玩家走到离目标地点多近就算「到达」（像素，20 像素约合 1 米）
const ARRIVE_RADIUS := 120.0
## 任务目标必须落在玩家周围这个距离以内（像素）。20 像素约合 1 米，10000 像素就是 500 米。
## 太远的目标玩家很难走到，所以生成时只从玩家附近的地点里挑。
const MAX_TARGET_DISTANCE := 10000.0
## 像素 / 米的换算，仅用来生成给模型 / 玩家的中文提示
const PX_PER_METER := 20.0
## 战斗类任务：在目标地点这个半径内击败的敌人，才计入任务进度（像素）
const COMBAT_RADIUS := 600.0

var mode := "mock"
var api_base := "https://api.openai.com/v1"
var api_key := ""
var model := "gpt-4o-mini"

## 所有生成过的任务（流水账），每项都是一件任务
var quests: Array[Dictionary] = []
## 当前 HUD / 箭头指向的任务；它和 quests 里的元素是同一个字典引用
var tracked_quest: Dictionary = {}
## 玩家最近一次上报的位置（player.gd 每帧经 try_complete_at 报进来）。
## 生成任务时用它筛出「玩家附近、能走到」的目标地点。
var player_position := Vector2.ZERO

var _http: HTTPRequest
var _queue: Array[Dictionary] = []
var _current: Dictionary = {}
var _busy := false
var _pumping := false


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.request_completed.connect(_on_request_completed)
	add_child(_http)
	_load_config()


func _load_config() -> void:
	# 配置统一由 LlmConfig 下发（res:// 默认 + user:// 玩家设置），
	# 设置界面保存后会 broadcast 回来重新执行，实现热更新
	LlmConfig.apply_to(self)
	print("[QuestManager] 生成模式 = %s" % mode)


## 外部唯一入口：请 NPC 生成一个任务。
## rich = true 表示这位 NPC 来自通天福地：出手极阔，奖励给得比寻常 NPC 多得多。
func request_quest(npc_name: String, npc_role: String, npc_personality: String = "", rich: bool = false) -> void:
	# 同一个 NPC 攒着的请求只保留最新的一条，避免连点按钮排出一长串
	_remove_queued(npc_name)
	_queue.append({
		"npc_name": npc_name,
		"npc_role": npc_role,
		"npc_personality": npc_personality,
		"rich": rich,
		"profile": PlayerProfile.to_dict(),
		"attempt": 0,
	})
	_pump()


# ---------------------------------------------------------------- 任务状态

## 玩家手上还没做完的任务（已接受、未完成）
func active_quests() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for q in quests:
		if bool(q.get("accepted", false)) and not bool(q.get("completed", false)):
			out.append(q)
	return out


## 玩家点「接受任务」时调用
func accept_quest(quest: Dictionary) -> void:
	if quest.is_empty():
		return
	quest["accepted"] = true
	# 刚接手的任务默认就是导航目标，玩家不用手动切
	_set_tracked(quest)
	PlayerProfile.record_quest_accepted(str(quest.get("title", "")))
	quest_accepted.emit(quest)


## 按 T 在多件任务之间轮换导航目标；有「待复命」的会优先跳过去
func cycle_tracked() -> void:
	var list := active_quests()
	if list.is_empty():
		if not tracked_quest.is_empty():
			_set_tracked({})
		return
	for q in list:
		if bool(q.get("reached", false)) and q != tracked_quest:
			_set_tracked(q)
			return
	var idx := list.find(tracked_quest)
	if idx == -1:
		_set_tracked(list[0])
	else:
		_set_tracked(list[(idx + 1) % list.size()])


func _set_tracked(quest: Dictionary) -> void:
	tracked_quest = quest
	tracked_changed.emit(tracked_quest)


## 完成一件任务后，自动把导航切到下一件（优先待复命的）
func _pick_next_tracked() -> Dictionary:
	var list := active_quests()
	for q in list:
		if bool(q.get("reached", false)):
			return q
	return list[0] if not list.is_empty() else {}


## 当前追踪目标应该去哪：先去目标地点，办完事之后改指委托人
func tracked_position() -> Variant:
	if tracked_quest.is_empty():
		return null
	return _quest_position(tracked_quest)


func _quest_position(quest: Dictionary) -> Variant:
	if bool(quest.get("reached", false)):
		var npc_name := str(quest.get("source_npc", ""))
		if npc_name != "":
			var npc_pos = NpcMemory.position_of(npc_name)
			if npc_pos != null:
				return npc_pos
		if WorldData.has_id("village"):
			return WorldData.by_id("village")["pos"]
		return null
	var id := str(quest.get("target_location", ""))
	if id == "" or not WorldData.has_id(id):
		return null
	return WorldData.by_id(id)["pos"]


## 当前这一步该去哪，给 HUD 显示的文案
func tracked_label() -> String:
	if tracked_quest.is_empty():
		return ""
	if bool(tracked_quest.get("reached", false)):
		return "回去找 %s 复命" % str(tracked_quest.get("source_npc", "委托人"))
	var need := int(tracked_quest.get("combat", 0))
	if need > 0:
		return "清剿 %s（击败敌人 %d/%d）" % [
			WorldData.name_of(str(tracked_quest.get("target_location", ""))),
			mini(int(tracked_quest.get("defeated", 0)), need),
			need,
		]
	return "前往 %s" % WorldData.name_of(str(tracked_quest.get("target_location", "")))


func has_active_quest() -> bool:
	return not active_quests().is_empty()


## 这个 NPC 手上有没有「玩家已经办完、等着复命」的任务。有就返回那件任务，没有返回空字典
func reportable_quest_for(npc_name: String) -> Dictionary:
	for q in quests:
		if (bool(q.get("accepted", false))
				and bool(q.get("reached", false))
				and not bool(q.get("completed", false))
				and str(q.get("source_npc", "")) == npc_name):
			return q
	return {}


## 玩家每帧把位置报进来。走到目标地点附近只算「办完事了」，不直接发奖励——
## 要回到委托人那里复命（report_quest）才算完成。
## 返回 true 表示「这一帧刚刚到达某个目标」，方便调用方做提示。
func try_complete_at(pos: Vector2) -> bool:
	# 顺便记下玩家位置：生成任务时要靠它把目标地点限制在玩家 500 米以内
	player_position = pos
	var just_reached := false
	for quest in active_quests():
		if bool(quest.get("reached", false)):
			continue
		var target = _quest_position(quest)
		if target == null:
			continue
		var target_pos: Vector2 = target
		if pos.distance_to(target_pos) > ARRIVE_RADIUS:
			continue
		# 战斗类任务：光走到地方不算完，得先把这里的坏人清干净
		var need := int(quest.get("combat", 0))
		if need > 0 and int(quest.get("defeated", 0)) < need:
			continue
		if _mark_reached(quest):
			just_reached = true
	return just_reached


## 把一件任务标成「目标已办完，等回复命」。返回 false 表示它本来就已经办完了。
func _mark_reached(quest: Dictionary) -> bool:
	if bool(quest.get("reached", false)):
		return false
	# quest 与 quests 里存的是同一个字典引用，改这里日志里也会同步显示
	quest["reached"] = true
	PlayerProfile.record_event("办完了「%s」的事，该回去找 %s 复命了" % [
		str(quest.get("title", "任务")),
		str(quest.get("source_npc", "委托人")),
	])
	quest_reached.emit(quest)
	if quest == tracked_quest:
		tracked_changed.emit(tracked_quest)
	return true


## 玩家打死了一个敌人：只有「还没办完、且目标就在这里」的战斗类任务才记一笔。
## 在别处刷怪不算数，免得玩家不去据点也能糊弄过去。
func notify_enemy_defeated(pos: Vector2) -> void:
	for quest in active_quests():
		if bool(quest.get("reached", false)):
			continue
		if int(quest.get("combat", 0)) <= 0:
			continue
		var target = _quest_position(quest)
		if target == null:
			continue
		var target_pos: Vector2 = target
		if pos.distance_to(target_pos) > COMBAT_RADIUS:
			continue
		quest["defeated"] = int(quest.get("defeated", 0)) + 1
		if quest == tracked_quest:
			tracked_changed.emit(tracked_quest)


## 玩家回到委托人面前复命：这时才结算奖励、涨好感、写进世界记忆、并让 AI 重写对玩家的印象。
func report_quest(quest: Dictionary, npc_role: String = "", npc_personality: String = "") -> bool:
	if quest.is_empty() or not bool(quest.get("reached", false)) or bool(quest.get("completed", false)):
		return false

	quest["completed"] = true

	var reward_gold := 0
	var rewards = quest.get("rewards", {})
	if typeof(rewards) == TYPE_DICTIONARY:
		reward_gold = int(rewards.get("gold", 0))

	var title := str(quest.get("title", ""))
	var npc_name := str(quest.get("source_npc", ""))
	PlayerProfile.record_quest_completed(reward_gold, title)
	# 写进「世界记忆」，让别的 NPC 之后也隐约知道玩家做过这件事
	WorldState.record_quest(quest)

	if npc_name != "":
		NpcMemory.change_affinity(npc_name, 10, "完成了「%s」" % title)
		NpcMemory.request_impression(npc_name, npc_role, npc_personality,
			"玩家刚帮你完成了「%s」这件事" % title)

	# 追踪的这件做完了，把导航自动切到下一件（没有就清空）
	if quest == tracked_quest:
		_set_tracked(_pick_next_tracked())

	quest_completed.emit(quest)
	return true


# ---------------------------------------------------------------- 请求队列

func _remove_queued(npc_name: String) -> void:
	for i in range(_queue.size() - 1, -1, -1):
		if str(_queue[i].get("npc_name", "")) == npc_name:
			_queue.remove_at(i)


func _pump() -> void:
	if _pumping:
		return
	_pumping = true
	while not _busy and not _queue.is_empty():
		_current = _queue.pop_front()
		if mode == "llm" and api_key != "":
			_busy = true
			_call_llm()                       # 异步，回调里再继续排队
		else:
			_finalize(_mock_quest(_current)) # 离线：立刻出结果，继续处理下一个
	_pumping = false
	if not _busy and not _queue.is_empty():
		_pump()


# ---------------------------------------------------------------- 候选地点

## 任务目标的候选地点：玩家周围 MAX_TARGET_DISTANCE 以内、且不是母村（"village"）的地方。
## 附近一个都没有时，退回离玩家最近的那个地点，保证任务永远有目标可指。
func _target_candidates() -> Array[Dictionary]:
	var nearby: Array[Dictionary] = []
	var nearest: Dictionary = {}
	var nearest_dist := INF
	for loc in WorldData.LOCATIONS:
		if str(loc.get("id", "")) == "village":
			continue
		var pos = loc.get("pos", null)
		if typeof(pos) != TYPE_VECTOR2:
			nearby.append(loc)
			continue
		var p: Vector2 = pos
		var d := player_position.distance_to(p)
		if d <= MAX_TARGET_DISTANCE:
			nearby.append(loc)
		if d < nearest_dist:
			nearest_dist = d
			nearest = loc
	if nearby.is_empty() and not nearest.is_empty():
		nearby.append(nearest)
	return nearby


## 把候选地点拼成喂给大模型的清单（格式与 WorldData.prompt_list 一致）
func _prompt_list(locs: Array[Dictionary]) -> String:
	var lines: PackedStringArray = []
	for loc in locs:
		lines.append("- %s（%s）：%s" % [loc["id"], loc["name"], loc["desc"]])
	return "\n".join(lines)


# ---------------------------------------------------------------- LLM 模式

func _call_llm() -> void:
	var candidates := _target_candidates()
	var system_prompt := """你是一个 2D 冒险游戏的任务生成器。
你只能输出一个 JSON 对象，不要输出任何解释文字，也不要使用 markdown 代码块。
JSON 的字段必须严格如下：
- title: 字符串，任务标题（中文，不超过 12 字）
- type: 字符串，只能是 "main" 或 "side"
- target_location: 字符串，必须是下面地点清单里的 id，绝对不允许自己编造地点
- description: 字符串，2-4 句中文描述。必须是这个 NPC 亲口说出他/她遇到了什么麻烦、需要玩家帮什么忙（第一人称或直接引语），并写出目标地点的名字
- stages: 数组，每一项是 {"goal": "这一步玩家要做什么"}，至少两步，最后一步必须是「回到 NPC 处复命」
- rewards: 对象，例如 {"gold": 100, "item": "物品名"}
- combat: 整数，0 表示普通任务；大于 0 表示这是一件「清剿 / 夺回」类任务，玩家要在目标地点击败这么多敌人（最多 8）。只有当目标地点是一处坏人据点时才允许大于 0，其余情况一律填 0
- fits_profile_because: 字符串，用一句中文说明为什么这个任务适合当前玩家。只能依据「玩家行为画像」里已经写明的事实来写，不许编造，也不要照搬画像里的原始数字

关于「移动距离」的措辞：只有当玩家行为画像里 traveled_far 为 true 时，才可以说玩家「走过远路 / 移动距离长」；traveled_far 为 false 时，绝对不许说玩家移动距离过长或走了很多路，只能说他的活动范围还小、基本在村子附近。

世界观：%s 不要引入现代或科幻元素。
下面这些地点都在玩家附近（%d 米以内），任务是玩家走得到的地方，只能从这里选，绝对不许编造或选更远的地点：
%s""" % [CultureData.worldview_block(), int(MAX_TARGET_DISTANCE / PX_PER_METER), _prompt_list(candidates)]

	# 玩家在开局定下的结局：让支线也朝这个方向铺垫，而不是各写各的。
	# 措辞刻意保持低调——支线要往这条线上靠，但不能直接喊出结局、也不许抢主线的活。
	var goal := StoryDirector.goal_theme()
	if goal != "":
		system_prompt += "\n这位玩家在开局就定下了自己想要的结局：%s。支线任务要顺着这个方向铺垫，让 NPC 的难处和玩家要去的地方能接上这条线；但不要直接喊出结局，也不要把支线写成主线。" % goal

	var user_prompt := """NPC：%s（%s）
NPC 的性格：%s
玩家行为画像：%s
%s

请为这个 NPC 生成一个支线任务。要求：
1. 任务的起因、措辞要贴合这个 NPC 的性格，不要写成千篇一律的万能任务；
2. 不同的 NPC、不同的请求，应该得到明显不同的任务，不要每次都给出同一个任务；
3. 目标地点必须是上面清单里的 id；
4. 任务的起因要是这个 NPC 自己遇到的难处，像他/她亲口在向玩家求助，而不是旁白式的说明；
5. 玩家把这个 NPC 的事办完之后，要回到这个 NPC 这里复命，所以 stages 的最后一步必须写成回访复命；
6. 不要重复玩家最近已经办过的那些事，换一件新的难处；
7. 目标地点若是坏人据点，可以写成「清剿 / 夺回 / 护送」类任务：这时 combat 填一个大于 0 的数（不超过 8），stages 第一步要写明要干什么（例如「击败据点里的坏人」）；其余任务的 combat 一律填 0。""" % [
		_current.get("npc_name", "村民"),
		_current.get("npc_role", "村民"),
		str(_current.get("npc_personality", "")).strip_edges(),
		JSON.stringify(_current.get("profile", {})),
		WorldState.summary(),
	]
	# 通天福地的住客：让模型把奖励写得格外丰厚
	if bool(_current.get("rich", false)):
		user_prompt += "\n8. 这位 NPC 来自「通天福地」——一处富得流油的秘境。他/她出手极其阔绰：rewards.gold 至少 600，rewards.item 要写明一件珍奇的礼物（例如金珠、美玉、华服、名贵香料），不要用「谢礼」这种泛泛的说法。"
	if _current.has("fix_hint"):
		user_prompt += "\n\n上一次生成不合格，原因：%s\n请严格按字段要求重新生成一次。" % _current["fix_hint"]

	var payload := {
		"model": model,
		"messages": [
			{"role": "system", "content": system_prompt},
			{"role": "user", "content": user_prompt},
		],
		"temperature": 0.9,
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
		push_warning("[QuestManager] 请求发起失败(%d)，回退 mock" % err)
		_finalize(_mock_quest(_current))
		_pump()


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if _current.is_empty():
		return
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		# 把接口返回的原始错误也打出来，方便排查 Key / 模型名 / 参数问题
		var detail := body.get_string_from_utf8().left(300)
		push_warning("[QuestManager] LLM 调用失败(result=%d, code=%d)：%s" % [result, response_code, detail])
		_finalize(_mock_quest(_current))
		_pump()
		return

	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("choices"):
		push_warning("[QuestManager] LLM 返回结构异常，回退 mock")
		_finalize(_mock_quest(_current))
		_pump()
		return

	var content := str(parsed["choices"][0]["message"]["content"])
	var quest = JSON.parse_string(_extract_json(content))
	if typeof(quest) != TYPE_DICTIONARY:
		_retry_or_fallback("模型返回的内容不是合法 JSON 对象")
		return

	var problem := _validation_error(quest)
	if problem != "":
		_retry_or_fallback(problem)
		return

	if not quest.has("source_npc"):
		quest["source_npc"] = _current.get("npc_name", "")
	_finalize(quest)
	_pump()


## 校验不通过时：先给模型一次改正的机会，还不行就用离线模板兜底
func _retry_or_fallback(reason: String) -> void:
	var attempt := int(_current.get("attempt", 0))
	if attempt < MAX_RETRY:
		_current["attempt"] = attempt + 1
		_current["fix_hint"] = reason
		push_warning("[QuestManager] 生成不合格（%s），让模型重试一次" % reason)
		_call_llm()
		return
	push_warning("[QuestManager] 重试仍不合格（%s），回退离线模板" % reason)
	_finalize(_mock_quest(_current))
	_pump()


# ---------------------------------------------------------------- 校验

## 返回空字符串表示通过，否则返回中文原因
func _validation_error(quest: Dictionary) -> String:
	if not quest.has("title") or str(quest["title"]).strip_edges() == "":
		return "缺少 title 字段"
	if not quest.has("description") or str(quest["description"]).strip_edges() == "":
		return "缺少 description 字段"
	if typeof(quest.get("stages", null)) != TYPE_ARRAY:
		return "stages 字段必须是数组"

	var loc := str(quest.get("target_location", "")).strip_edges()
	if loc == "":
		return "缺少 target_location 字段"
	if not WorldData.has_id(loc):
		var allowed: PackedStringArray = []
		for l in _target_candidates():
			allowed.append(str(l["id"]))
		return "target_location「%s」不存在，只能填：%s" % [loc, ", ".join(allowed)]
	var loc_pos = WorldData.by_id(loc).get("pos", null)
	if typeof(loc_pos) == TYPE_VECTOR2:
		var target_pos: Vector2 = loc_pos
		if player_position.distance_to(target_pos) > MAX_TARGET_DISTANCE:
			return "target_location「%s」离玩家超过 %d 米，太远了；只能选玩家附近的地点" % [
				loc, int(MAX_TARGET_DISTANCE / PX_PER_METER)
			]
	return ""


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


# ---------------------------------------------------------------- 离线模板

func _mock_quest(ctx: Dictionary) -> Dictionary:
	var profile: Dictionary = ctx.get("profile", {})
	var dominant: String = str(profile.get("dominant_trait", "exploration"))
	var npc_name: String = str(ctx.get("npc_name", "村民"))
	var personality: String = str(ctx.get("npc_personality", "")).strip_edges()

	# 从「玩家附近、村子之外」的真实地点里随机挑一个当目标，保证目标在 500 米内走得到
	var candidates := _target_candidates()
	if candidates.is_empty():
		# 万一世界上还没有村外地点，退回母村，至少让任务能生成
		candidates.append(WorldData.by_id("village"))
	var loc: Dictionary = candidates[randi() % candidates.size()]
	var loc_id := str(loc.get("id", "mine"))
	var loc_name := str(loc.get("name", "村外"))

	# 起因文案与标题各随机抽一条，避免每个 NPC、每次请求都弹同一段话
	var reasons := [
		"%s说，%s那边最近有些不对劲，想请个靠得住的人跑一趟。" % [npc_name, loc_name],
		"%s把你叫住，说自己在%s落下了件东西，希望有人帮忙取回来。" % [npc_name, loc_name],
		"%s压低声音告诉你，%s深处有些不太寻常的动静。" % [npc_name, loc_name],
		"%s提起，自己一直想去%s看看，可实在走不开，只好拜托你。" % [npc_name, loc_name],
	]
	# 玩家定过结局时，补一条朝那个方向铺垫的起因，让支线也沾点主线味
	var goal := StoryDirector.goal_theme()
	if goal != "":
		reasons.append("%s听说了你心里想去的地方，说%s或许能让你离「%s」更近一步。" % [npc_name, loc_name, goal])
	var titles := [
		"%s的托付" % loc_name,
		"去%s跑一趟" % loc_name,
		"%s的老心事" % npc_name,
	]
	# 目标是坏人据点时，有一半机会变成「清剿」类任务：光走到不算，要把人清干净
	var combat := 0
	if str(loc.get("kind", "")) == "camp" and randi() % 2 == 0:
		combat = 3
	var stages := [
		{"goal": "前往%s" % loc_name},
		{"goal": "办完事后回到%s处复命" % npc_name},
	]
	var gold := 50 + (randi() % 6) * 10
	if combat > 0:
		reasons.append("%s说，%s那伙坏人越闹越凶，想请你替乡亲们把他们清剿了。" % [npc_name, loc_name])
		reasons.append("%s神色不安地提到，%s被一伙坏人占了，问你敢不敢去打上一场。" % [npc_name, loc_name])
		titles.append("清剿%s" % loc_name)
		stages[0] = {"goal": "前往%s，击败那里的坏人（%d 个）" % [loc_name, combat]}
		gold += 40

	# 通天福地的住客出手阔绰，谢礼也讲究（赏钱在 _finalize 里统一抬高）
	var item_name := "福地的厚赏" if bool(ctx.get("rich", false)) else "%s的谢礼" % npc_name
	return {
		"type": "side",
		"source_npc": npc_name,
		"target_location": loc_id,
		"title": str(titles[randi() % titles.size()]),
		"description": str(reasons[randi() % reasons.size()]),
		"stages": stages,
		"combat": combat,
		"rewards": {"gold": gold, "item": item_name},
		"fits_profile_because": "离线模式：%s的性格是「%s」，玩家近期行为倾向是「%s」。" % [npc_name, personality, dominant],
	}


# ---------------------------------------------------------------- 落地

func _finalize(quest: Dictionary) -> void:
	var ctx := _current
	_current = {}
	_busy = false
	quest["id"] = "quest_%03d" % (quests.size() + 1)
	quest["type"] = quest.get("type", "side")
	quest["source_npc"] = quest.get("source_npc", ctx.get("npc_name", ""))
	quest["accepted"] = false
	quest["reached"] = false
	quest["completed"] = false
	# 战斗类任务：combat>0 表示要在目标地点击败这么多敌人；defeated 是当前进度
	quest["combat"] = clampi(int(quest.get("combat", 0)), 0, 8)
	quest["defeated"] = maxi(0, int(quest.get("defeated", 0)))
	# 通天福地的住客：标记出来，奖励统一抬到远高于寻常 NPC 的水平
	if bool(ctx.get("rich", false)):
		quest["rich"] = true
		_boost_rich_rewards(quest)
	quests.append(quest)
	quest_generated.emit(quest)


## 通天福地住客的奖励兜底：不管走 LLM 还是 mock，赏钱都抬到远高于寻常 NPC 的水平。
## 只在下限没达到时才抬高，避免模型已经给足了还再翻几倍。
func _boost_rich_rewards(quest: Dictionary) -> void:
	var rewards = quest.get("rewards", {})
	if typeof(rewards) != TYPE_DICTIONARY:
		rewards = {}
	var gold := int((rewards as Dictionary).get("gold", 0))
	if gold < 600:
		gold = gold * 4 + 400
	(rewards as Dictionary)["gold"] = gold
	var item := str((rewards as Dictionary).get("item", "")).strip_edges()
	if item == "":
		(rewards as Dictionary)["item"] = "福地的厚赏"
	quest["rewards"] = rewards


# ---------------------------------------------------------------- 存档

func to_save() -> Dictionary:
	var list: Array = []
	for q in quests:
		list.append(q.duplicate(true))
	return {
		"quests": list,
		"tracked_id": str(tracked_quest.get("id", "")),
	}


func from_save(data: Dictionary) -> void:
	quests.clear()
	var raw = data.get("quests", [])
	if typeof(raw) == TYPE_ARRAY:
		for q in raw:
			if typeof(q) == TYPE_DICTIONARY:
				quests.append(q)
	# 按 id 找回被追踪那件任务的引用：必须是 quests 里的同一个字典，
	# 否则改它的 reached / completed 时日志里看不到变化
	tracked_quest = {}
	var tracked_id := str(data.get("tracked_id", ""))
	if tracked_id != "":
		for q in quests:
			if str(q.get("id", "")) == tracked_id:
				tracked_quest = q
				break
	if tracked_quest.is_empty():
		tracked_quest = _pick_next_tracked()

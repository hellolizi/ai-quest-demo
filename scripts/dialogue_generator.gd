extends Node
## NPC 台词生成器（Autoload 名字：DialogueGenerator）
## 让大模型按「这个 NPC 的性格 + 玩家最近的所作所为」现编一句台词。
##
## 和任务生成同样的思路：生成 → 校验 → 重试 → 兜底。
## 在此之上还解决了几个体验问题：
##   1. 请求排队：一次只发一个 HTTP 请求，其余排队；不会因为前一个没回来就把后一个丢掉；
##   2. 请求超时：卡住的请求会被掐掉，队列不会永远堵死；
##   3. 预生成缓存：玩家靠近 NPC 时就提前备一句，真正开口时秒回，不会出现「先说本地句、再被 AI 句替换」的跳变；
##   4. 台词不丢：玩家提前关掉对话时，已经生成好的那句会被收回缓存，下次进来直接用；
##   5. 防重复：同一个 NPC 最近说过的话会被记下来，既写进 prompt，也在校验和本地兜底里生效。

## mood 是这个 NPC 说这句话时的情绪：友好 / 中立 / 不悦。
## 玩家自由说话时，NPC 的情绪会反过来影响好感度（见 dialogue_ui）。
signal line_ready(npc_name: String, text: String, mood: String)

const MAX_RETRY := 1
## 一句台词的硬上限（prompt 里要求 60 字以内，这里留点余量做兜底校验）
const MAX_LEN := 90
## 每个 NPC 记住最近说过的几句，用来防重复。
## 必须不小于本地兜底池（8 句），否则连说几句就会开始重复。
const RECENT_KEEP := 8
## 单个 HTTP 请求的超时（秒）。没有它，卡住的请求会把整条队列堵死
const REQUEST_TIMEOUT := 15.0

var mode := "mock"
var api_base := "https://api.openai.com/v1"
var api_key := ""
var model := "gpt-4o-mini"

var _http: HTTPRequest
var _queue: Array[Dictionary] = []     # 等待发出的请求
var _current: Dictionary = {}          # 正在处理的那个请求
var _busy := false                     # 是否有请求在路上
var _pumping := false                  # 防止 _pump 重入
var _recent: Dictionary = {}           # npc_name -> Array[String]  已经说出口的
var _cache: Dictionary = {}            # npc_name -> Array[String]  提前备好、还没说的
var _waiters: Dictionary = {}          # npc_name -> true           有人在等这一句
## 每个请求一个自增编号，用来分清「回来的这句是不是玩家此刻真正在等的那句」
var _req_seq := 0
## npc_name -> req_id  玩家此刻真正在等的那一次请求（预取不算，见 request_line）
var _want: Dictionary = {}


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = REQUEST_TIMEOUT
	_http.request_completed.connect(_on_request_completed)
	add_child(_http)
	_load_config()


func _load_config() -> void:
	# 配置统一由 LlmConfig 下发（res:// 默认 + user:// 玩家设置）
	LlmConfig.apply_to(self)
	print("[DialogueGenerator] 台词模式 = %s" % mode)


# ---------------------------------------------------------------- 对外入口

## 玩家靠近 NPC 时先备一句。等真正开口时就能秒回，也避免「先本地句、再被替换」的跳变。
func prefetch(npc_name: String, npc_role: String, personality: String, fallback: PackedStringArray) -> void:
	if _cached_count(npc_name) > 0 or _is_queued(npc_name):
		return
	_enqueue(npc_name, npc_role, personality, fallback, "")


## 请这个 NPC 说一句。缓存里有就立刻用；没有就先排一单，回来之后再补上。
## topic 不为空时表示「玩家主动说了什么」，这句要就着它回答，也不会占用开场白的缓存。
## free 为 true 表示 topic 是玩家自己敲的原话（自由输入），而不是预设话题。
func request_line(npc_name: String, npc_role: String, personality: String, fallback: PackedStringArray, topic: String = "", free := false) -> void:
	if topic == "":
		var cached := _pop_cache(npc_name)
		if cached != "":
			_say(npc_name, cached)
			prefetch(npc_name, npc_role, personality, fallback)
			return

	# 已经在路上的「一模一样」的请求：不重复发一单，只登记这次是谁在等
	var reuse := _reuse_request(npc_name, topic)
	if reuse > 0:
		_waiters[npc_name] = true
		_want[npc_name] = reuse
		return

	# 队列里还压着这个 NPC 的另一单（还没发出去）：直接改成这次要问的，省一次调用
	var upgraded := _upgrade_queued_request(npc_name, npc_role, personality, fallback, topic, free)
	if upgraded > 0:
		_waiters[npc_name] = true
		_want[npc_name] = upgraded
		_pump()
		return

	# 否则新排一单。必须先登记 _waiters/_want 再入队：
	# 离线模式下 _pump 会同步把结果 _deliver 出来，晚一步就会被误判成「过期的」
	var rid := _next_req_id()
	_waiters[npc_name] = true
	_want[npc_name] = rid
	_enqueue(npc_name, npc_role, personality, fallback, topic, free, rid)


## 玩家关掉了对话：没等到的那句会留在缓存里，下次进来直接能用
func drop_waiter(npc_name: String) -> void:
	_waiters.erase(npc_name)
	_want.erase(npc_name)


## 每个请求一个自增编号
func _next_req_id() -> int:
	_req_seq += 1
	return _req_seq


## 路上有没有「同一个 NPC、同一个话题」的请求？有就复用，别再发一单
func _reuse_request(npc_name: String, topic: String) -> int:
	if str(_current.get("npc_name", "")) == npc_name and str(_current.get("topic", "")) == topic:
		return int(_current.get("req_id", 0))
	for item in _queue:
		if str(item.get("npc_name", "")) == npc_name and str(item.get("topic", "")) == topic:
			return int(item.get("req_id", 0))
	return 0


## 队列里还没发出去的同 NPC 请求，改成这次真正要问的内容
func _upgrade_queued_request(npc_name: String, npc_role: String, personality: String, fallback: PackedStringArray, topic: String, free: bool) -> int:
	for i in range(_queue.size()):
		var item: Dictionary = _queue[i]
		if str(item.get("npc_name", "")) != npc_name:
			continue
		item["npc_role"] = npc_role
		item["personality"] = personality
		item["fallback"] = fallback
		item["topic"] = topic
		item["free"] = free
		item["attempt"] = 0
		item.erase("fix_hint")
		_queue[i] = item
		return int(item.get("req_id", 0))
	return 0


## 台词暂时用不上（比如玩家先点了别的按钮），收回缓存备着
func stash(npc_name: String, line: String) -> void:
	var text := line.strip_edges()
	if text == "":
		return
	var arr: Array = _cache.get(npc_name, [])
	if arr.has(text):
		return
	arr.append(text)
	_cache[npc_name] = arr


## 这个 NPC 最近说过的话
func recent_lines(npc_name: String) -> Array:
	return _recent.get(npc_name, [])


## 这个 NPC 已经备好、还没说的台词
func cached_lines(npc_name: String) -> Array:
	return _cache.get(npc_name, [])


# ---------------------------------------------------------------- 队列

func _enqueue(npc_name: String, npc_role: String, personality: String, fallback: PackedStringArray, topic: String, free := false, req_id := 0) -> void:
	if req_id == 0:
		req_id = _next_req_id()
	_queue.append({
		"npc_name": npc_name,
		"npc_role": npc_role,
		"personality": personality,
		"fallback": fallback,
		"topic": topic,
		"free": free,
		"attempt": 0,
		"req_id": req_id,
	})
	_pump()


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
			_deliver(_pick_local())           # 离线：立刻出结果，继续处理下一个
	_pumping = false
	if not _busy and not _queue.is_empty():
		_pump()


func _cached_count(npc_name: String) -> int:
	var arr = _cache.get(npc_name, [])
	return (arr as Array).size()


func _is_queued(npc_name: String) -> bool:
	if str(_current.get("npc_name", "")) == npc_name:
		return true
	for item in _queue:
		if str(item.get("npc_name", "")) == npc_name:
			return true
	return false


# ---------------------------------------------------------------- LLM 模式

func _system_prompt() -> String:
	return """你是一个 2D 冒险游戏里的 NPC 台词生成器。
你只能输出一个 JSON 对象，不要输出任何解释文字，也不要使用 markdown 代码块。
JSON 的字段必须严格如下：
- line: 字符串，这个 NPC 现在对玩家说的中文台词，1~2 句，不超过 60 字
- mood: 字符串，只能是 "友好" / "中立" / "不悦" 三个值之一，表示你说这句话时的情绪

要求：
1. 必须完全按这个 NPC 的性格和身份说话，让不同 NPC 的台词一眼就能认出是谁说的；
2. 要像真人随口说的话，可以带口头禅、语气词、停顿，不要写成念说明书；
3. 只写「说出口的话」，不要写「他说……」这类旁白，也不要用引号把整句话包起来；
4. 不要提到 AI、模型、游戏、系统、选项；
5. 不要把玩家的行为数据照搬进台词（比如「你走了 3000 像素」「你交谈了 5 次」这种），要化成自然的关心或打趣；
6. 每个 NPC 可以有符合自己身份的口头禅或句式，但不要每句都用同一句口头禅；
7. 一定不要和「他最近已经说过的话」重复，也不要只是换几个字；
8. 玩家对你说的话，会体现在 mood 里：他这话让你受用就是「友好」，平常就是「中立」，冒犯到你、或者让你为难就是「不悦」；
9. 如果玩家心里正奔着一个结局，你可以让台词顺着那个方向自然流露半句，但绝对不要直接喊出结局，也不要提到「结局」「主线」这类说法。

世界观：%s 不要引入现代或科幻元素。""" % CultureData.worldview_block()


func _call_llm() -> void:
	var name := str(_current.get("npc_name", "村民"))
	var profile := PlayerProfile.to_dict()

	var recent: Array = _recent.get(name, [])
	var recent_block := ""
	if not recent.is_empty():
		var lines: PackedStringArray = []
		for r in recent:
			lines.append("  - " + str(r))
		recent_block = "\n\n他最近已经说过下面这些话，这次绝对不能重复：\n" + "\n".join(lines)

	var events: Array = profile.get("recent_events", [])
	var event_block := ""
	if not events.is_empty():
		var lines2: PackedStringArray = []
		for e in events:
			lines2.append("  - " + str(e))
		event_block = "\n\n玩家最近做过的事：\n" + "\n".join(lines2)

	var quest_block := ""
	var active_list: Array[Dictionary] = QuestManager.active_quests()
	if not active_list.is_empty():
		var first: Dictionary = active_list[0]
		if active_list.size() == 1:
			quest_block = "\n\n玩家身上还有一个没做完的任务：「%s」（去%s）。可以顺口提一句，但不要喧宾夺主。" % [
				str(first.get("title", "任务")),
				WorldData.name_of(str(first.get("target_location", ""))),
			]
		else:
			quest_block = "\n\n玩家身上还有 %d 件没做完的事，其中一件是「%s」。可以顺口提一句，但不要喧宾夺主。" % [
				active_list.size(),
				str(first.get("title", "任务")),
			]

	# 玩家心里奔着的结局：让台词能自然朝那个方向靠，但别点破
	var goal_block := ""
	var goal_theme := StoryDirector.goal_theme()
	if goal_theme.strip_edges() != "":
		goal_block = "\n\n玩家心里似乎奔着这样一个方向：%s。可以顺着这个方向说半句，但不要直接点破，也不要提「结局」。" % goal_theme

	# 这个世界最近发生过什么——让 NPC 也「听说」玩家做过的事
	var world_block := ""
	var world_summary := WorldState.summary()
	if world_summary.strip_edges() != "":
		world_block = "\n\n" + world_summary

	# 这个 NPC 认识的人、跟他们是什么关系——聊到相关的人时可以自然带一句
	var relation_block := ""
	var relation_desc := NpcRelations.describe(name)
	if relation_desc.strip_edges() != "":
		relation_block = "\n\n" + relation_desc

	# 这个 NPC 对玩家的记忆（好感、印象、关键记忆）——有上限，不会越聊越长
	var memory_block := ""
	var memory_desc := NpcMemory.describe(name)
	if memory_desc.strip_edges() != "":
		memory_block = "\n\n" + memory_desc

	# 玩家这次主动说了什么：预设话题，还是自由输入的原话
	var topic_block := ""
	var topic := str(_current.get("topic", "")).strip_edges()
	if topic != "":
		if bool(_current.get("free", false)):
			topic_block = "\n\n玩家刚刚亲口对你说：「%s」\n请就着他这句话作出回应：可以顺着聊、可以反问，但不要答非所问，也不要长篇大论。" % topic
		else:
			topic_block = "\n\n玩家这次主动问的是：%s\n请就着这个话题回答，不要答非所问，也不要顺便扯到别的事情上。" % topic

	var user_prompt := """NPC：%s（%s）
这个 NPC 的性格：%s%s

玩家画像：%s%s%s%s%s%s%s%s

请写出这个 NPC 现在会对玩家说的一句话。""" % [
		name,
		str(_current.get("npc_role", "村民")),
		str(_current.get("personality", "")).strip_edges(),
		relation_block,
		str(profile.get("summary", "")),
		memory_block,
		recent_block,
		event_block,
		quest_block,
		world_block,
		goal_block,
		topic_block,
	]
	if _current.has("fix_hint"):
		user_prompt += "\n\n上一次生成不合格，原因：%s\n请严格按要求重新生成一次。" % _current["fix_hint"]

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
		push_warning("[DialogueGenerator] 请求发起失败(%d)，回退本地台词" % err)
		_deliver(_pick_local())
		_pump()


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if _current.is_empty():
		return
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		var detail := body.get_string_from_utf8().left(300)
		push_warning("[DialogueGenerator] LLM 调用失败(result=%d, code=%d)：%s" % [result, response_code, detail])
		_deliver(_pick_local())
		_pump()
		return

	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("choices"):
		push_warning("[DialogueGenerator] LLM 返回结构异常，回退本地台词")
		_deliver(_pick_local())
		_pump()
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

	_deliver(str(data["line"]), _normalize_mood(data.get("mood", "")))
	_pump()


func _retry_or_fallback(reason: String) -> void:
	var attempt := int(_current.get("attempt", 0))
	if attempt < MAX_RETRY:
		_current["attempt"] = attempt + 1
		_current["fix_hint"] = reason
		push_warning("[DialogueGenerator] 台词不合格（%s），让模型重试一次" % reason)
		_call_llm()
		return
	push_warning("[DialogueGenerator] 重试仍不合格（%s），回退本地台词" % reason)
	_deliver(_pick_local())
	_pump()


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


func _validation_error(data: Dictionary) -> String:
	var line := str(data.get("line", "")).strip_edges()
	if line == "":
		return "缺少 line 字段，或者 line 是空的"
	if line.contains("```"):
		return "line 里不要出现 markdown 代码块符号"
	if line.length() > MAX_LEN:
		return "line 太长了（%d 字），请压到 60 字以内" % line.length()
	var npc_name := str(_current.get("npc_name", ""))
	var seen: Array = _seen_lines(npc_name)
	if seen.has(line):
		return "line 和最近说过、或者已经备好的话重复了，请换一句"
	return ""


# ---------------------------------------------------------------- 落地

## 本地台词池里挑一句：优先挑没说过、也没备过的那句，全用过了就随机挑。
## 兜底台词只是「AI 不可用」时的保险，所以每个 NPC 都备了足够多句，离线也不容易听腻。
func _pick_local() -> String:
	var pool: PackedStringArray = _current.get("fallback", PackedStringArray())
	if pool.is_empty():
		return "你好，旅行者。"
	var npc_name := str(_current.get("npc_name", ""))
	var seen: Array = _seen_lines(npc_name)
	var fresh: PackedStringArray = []
	for line in pool:
		if not seen.has(str(line)):
			fresh.append(str(line))
	if fresh.is_empty():
		fresh = pool
	return str(fresh[randi() % fresh.size()])


## 这个 NPC 已经「说过」+「备好」的所有台词，用于去重
func _seen_lines(npc_name: String) -> Array:
	var seen: Array = _recent.get(npc_name, []).duplicate()
	seen.append_array(_cache.get(npc_name, []))
	return seen


## 一个请求有了结果：有人在等就直接说出来，没人等就先存进缓存
## （话题台词不进开场白缓存，否则下次搭话会突然冒出一句答非所问的话）
func _deliver(text: String, mood: String = "中立") -> void:
	var ctx := _current
	_current = {}
	_busy = false
	var npc_name := str(ctx.get("npc_name", ""))
	var line := text.strip_edges().strip_escapes()
	if line == "":
		line = "你好，旅行者。"
	# 只有「回来的这一单正是玩家此刻在等的那一单」才直接说出口。
	# 预取的、或者玩家已经改问别的而作废的那一单，都不能抢着说，否则就是答非所问。
	var rid := int(ctx.get("req_id", 0))
	var is_latest := int(_want.get(npc_name, 0)) == rid and bool(_waiters.get(npc_name, false))
	if is_latest:
		_waiters.erase(npc_name)
		_want.erase(npc_name)
		_say(npc_name, line, mood)
	elif str(ctx.get("topic", "")) == "":
		# 没人等的开场白：收回缓存，下次搭话直接用
		_push_cache(npc_name, line)
	# 过期的提问结果（玩家已经改问别的了）直接丢弃


## 模型偶尔会漏填 mood 或填成别的词，这里统一收敛成三个值之一
func _normalize_mood(raw) -> String:
	var m := str(raw).strip_edges()
	if m == "友好" or m == "不悦":
		return m
	return "中立"


func _say(npc_name: String, line: String, mood: String = "中立") -> void:
	_push_recent(npc_name, line)
	line_ready.emit(npc_name, line, mood)


func _pop_cache(npc_name: String) -> String:
	var arr: Array = _cache.get(npc_name, [])
	if arr.is_empty():
		return ""
	var line := str(arr.pop_front())
	if arr.is_empty():
		_cache.erase(npc_name)
	else:
		_cache[npc_name] = arr
	return line


func _push_cache(npc_name: String, line: String) -> void:
	if line == "" or _seen_lines(npc_name).has(line):
		return
	var arr: Array = _cache.get(npc_name, [])
	arr.append(line)
	_cache[npc_name] = arr


func _push_recent(npc_name: String, line: String) -> void:
	var arr: Array = _recent.get(npc_name, [])
	arr.append(line)
	while arr.size() > RECENT_KEEP:
		arr.remove_at(0)
	_recent[npc_name] = arr

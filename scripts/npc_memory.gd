extends Node
## NPC 记忆与好感（Autoload 名字：NpcMemory）
##
## 这里解决一个关键问题：AI 是有上下文上限的，如果每次都把「你跟这个 NPC 说过的所有话」
## 塞进请求，聊得越久请求越长，迟早会爆掉，而且又慢又贵。
##
## 做法是给每个 NPC 只留一份**有上限**的记忆档案：
##   印象 1 句 + 关键记忆最多 5 条 + 关系等级
## 每次发给 AI 的描述长度是恒定的，玩 1000 次也不会变长。
## 核心原则：让 AI 做「总结」，而不是让 AI 读全部历史。
##
## 好感度由本地规则算（聊天 +1、完成任务 +10），AI 只在关键节点重写「印象」这一句话。

signal impression_changed(npc_name: String)

const MAX_RETRY := 1
## 每个 NPC 最多记住几件关于玩家的事，超了就丢最早的
const MEMORIES_KEEP := 5
## 印象的长度上限（prompt 里要求 20 字以内，这里留点余量做兜底校验）
const IMPRESSION_MAX_LEN := 40
const REQUEST_TIMEOUT := 15.0

## 关系等级门槛（好感度 0~100）
const LEVEL_FAMILIAR := 15
const LEVEL_TRUST := 40

var mode := "mock"
var api_base := "https://api.openai.com/v1"
var api_key := ""
var model := "gpt-4o-mini"

## npc_name -> {"affinity": int, "impression": String, "memories": Array[String]}
var _states: Dictionary = {}
## npc_name -> Vector2
var _positions: Dictionary = {}

var _http: HTTPRequest
var _queue: Array[Dictionary] = []
var _current: Dictionary = {}
var _busy := false
var _pumping := false


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = REQUEST_TIMEOUT
	_http.request_completed.connect(_on_request_completed)
	add_child(_http)
	_load_config()


func _load_config() -> void:
	# 配置统一由 LlmConfig 下发（res:// 默认 + user:// 玩家设置），
	# 设置界面保存后会 broadcast 回来重新执行，实现热更新
	LlmConfig.apply_to(self)
	print("[NpcMemory] 印象模式 = %s" % mode)


# ---------------------------------------------------------------- 位置注册

## 主场景启动时把每个 NPC 的位置登记进来，复命时要用它指路
func register(npc_name: String, pos: Vector2) -> void:
	if npc_name == "":
		return
	_positions[npc_name] = pos
	_state(npc_name)


func position_of(npc_name: String) -> Variant:
	return _positions.get(npc_name, null)


# ---------------------------------------------------------------- 好感 / 印象

func affinity(npc_name: String) -> int:
	return int(_state(npc_name).get("affinity", 0))


func impression(npc_name: String) -> String:
	return str(_state(npc_name).get("impression", ""))


func memories(npc_name: String) -> Array:
	return (_state(npc_name).get("memories", []) as Array).duplicate()


## 所有 NPC 的好感总和（主线用它衡量玩家「在村里攒下多少情谊」）
func affinity_total() -> int:
	var total := 0
	for key in _states:
		total += int((_states[key] as Dictionary).get("affinity", 0))
	return total


## 生疏 / 脸熟 / 熟络 / 信赖
func level_of(npc_name: String) -> String:
	var a := affinity(npc_name)
	if a >= LEVEL_TRUST:
		return "信赖"
	if a >= LEVEL_FAMILIAR:
		return "熟络"
	if a >= 1:
		return "脸熟"
	return "生疏"


## 给界面显示的「关系」标签
func label_of(npc_name: String) -> String:
	return "关系：%s（好感 %d）" % [level_of(npc_name), affinity(npc_name)]


## 喂给 AI 的紧凑描述——长度恒定，不会随聊天次数增长
func describe(npc_name: String) -> String:
	var st := _state(npc_name)
	var lines: PackedStringArray = []
	lines.append("你和这个玩家目前的关系：%s（好感度 %d/100）" % [level_of(npc_name), affinity(npc_name)])
	var imp := str(st.get("impression", "")).strip_edges()
	if imp != "":
		lines.append("你对他的印象：%s" % imp)
	var mems: Array = st.get("memories", [])
	if not mems.is_empty():
		lines.append("你记得关于他的几件事：")
		for m in mems:
			lines.append("  - " + str(m))
	return "\n".join(lines)


## 好感度增减；memory 不为空时同时记下一件关于玩家的事
func change_affinity(npc_name: String, delta: int, memory: String = "") -> void:
	if npc_name == "":
		return
	var st := _state(npc_name)
	var before := int(st.get("affinity", 0))
	var after := clampi(before + delta, 0, 100)
	st["affinity"] = after
	_states[npc_name] = st
	if memory != "":
		add_memory(npc_name, memory)
	if after != before or memory != "":
		impression_changed.emit(npc_name)


## 记一件关于玩家的事，超过上限就丢最早的
func add_memory(npc_name: String, text: String) -> void:
	var t := text.strip_edges()
	if t == "":
		return
	var st := _state(npc_name)
	var mems: Array = st.get("memories", [])
	if mems.has(t):
		return
	mems.append(t)
	while mems.size() > MEMORIES_KEEP:
		mems.remove_at(0)
	st["memories"] = mems
	_states[npc_name] = st


# ---------------------------------------------------------------- 印象重写（AI）

## 关键节点（聊够几次、完成一个任务）请 AI 把印象重写一句。
## 不频繁，而且同一个 NPC 攒着的请求只保留最新的一条，不会堆积。
func request_impression(npc_name: String, npc_role: String, personality: String, trigger: String) -> void:
	if npc_name == "":
		return
	_remove_queued(npc_name)
	_queue.append({
		"npc_name": npc_name,
		"npc_role": npc_role,
		"personality": personality,
		"trigger": trigger,
		"attempt": 0,
	})
	_pump()


func _state(npc_name: String) -> Dictionary:
	var st = _states.get(npc_name, null)
	if typeof(st) != TYPE_DICTIONARY:
		st = {"affinity": 0, "impression": "", "memories": []}
		_states[npc_name] = st
	return st


# ---------------------------------------------------------------- 队列

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
			_call_llm()                     # 异步，回调里再继续排队
		else:
			_deliver(_fallback_impression())
	_pumping = false
	if not _busy and not _queue.is_empty():
		_pump()


# ---------------------------------------------------------------- LLM 模式

func _system_prompt() -> String:
	return """你是一个 2D 冒险游戏里的 NPC 内心状态更新器。
你只能输出一个 JSON 对象，不要输出任何解释文字，也不要使用 markdown 代码块。
JSON 的字段必须严格如下：
- impression: 字符串，这个 NPC 现在对玩家的印象，一句话，不超过 20 个汉字

要求：
1. 必须符合这个 NPC 的性格；
2. 要体现给出的关系和记忆：越熟越亲近、越具体，但不要吹捧；
3. 不要出现数字，不要提到 AI、模型、游戏、系统、好感度这些词。

世界观：%s 不要引入现代或科幻元素。""" % CultureData.worldview_block()


func _call_llm() -> void:
	var name := str(_current.get("npc_name", "村民"))
	var user_prompt := """NPC：%s（%s）
这个 NPC 的性格：%s

%s

刚刚发生的事：%s

请重写这个 NPC 现在对玩家的印象。""" % [
		name,
		str(_current.get("npc_role", "村民")),
		str(_current.get("personality", "")).strip_edges(),
		describe(name),
		str(_current.get("trigger", "")),
	]
	if _current.has("fix_hint"):
		user_prompt += "\n\n上一次生成不合格，原因：%s\n请严格按要求重新生成一次。" % _current["fix_hint"]

	var payload := {
		"model": model,
		"messages": [
			{"role": "system", "content": _system_prompt()},
			{"role": "user", "content": user_prompt},
		],
		"temperature": 0.8,
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
		push_warning("[NpcMemory] 请求发起失败(%d)，回退本地印象" % err)
		_deliver(_fallback_impression())
		_pump()


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if _current.is_empty():
		return
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		var detail := body.get_string_from_utf8().left(300)
		push_warning("[NpcMemory] LLM 调用失败(result=%d, code=%d)：%s" % [result, response_code, detail])
		_deliver(_fallback_impression())
		_pump()
		return

	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("choices"):
		push_warning("[NpcMemory] LLM 返回结构异常，回退本地印象")
		_deliver(_fallback_impression())
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

	_deliver(str(data["impression"]))
	_pump()


func _retry_or_fallback(reason: String) -> void:
	var attempt := int(_current.get("attempt", 0))
	if attempt < MAX_RETRY:
		_current["attempt"] = attempt + 1
		_current["fix_hint"] = reason
		push_warning("[NpcMemory] 印象不合格（%s），让模型重试一次" % reason)
		_call_llm()
		return
	push_warning("[NpcMemory] 重试仍不合格（%s），回退本地印象" % reason)
	_deliver(_fallback_impression())
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
	var imp := str(data.get("impression", "")).strip_edges()
	if imp == "":
		return "缺少 impression 字段，或者它是空的"
	if imp.contains("```"):
		return "impression 里不要出现 markdown 代码块符号"
	if imp.length() > IMPRESSION_MAX_LEN:
		return "impression 太长了（%d 字），请压到 20 字以内" % imp.length()
	return ""


# ---------------------------------------------------------------- 落地

## AI 不可用时的本地印象：按关系等级给一句
func _fallback_impression() -> String:
	var name := str(_current.get("npc_name", ""))
	match level_of(name):
		"信赖":
			return "是个靠得住、信得过的老朋友"
		"熟络":
			return "打过不少照面，算个熟人了"
		"脸熟":
			return "见过几回，看着还算顺眼"
		_:
			return "一个刚来村里的陌生面孔"


func _deliver(text: String) -> void:
	var ctx := _current
	_current = {}
	_busy = false
	var name := str(ctx.get("npc_name", ""))
	var imp := text.strip_edges().strip_escapes()
	if name == "" or imp == "":
		return
	var st := _state(name)
	st["impression"] = imp
	_states[name] = st
	impression_changed.emit(name)


# ---------------------------------------------------------------- 存档

## 只存「好感 / 印象 / 记忆」这三样；NPC 坐标（_positions）不入档，
## 读档后由 main.gd 在场景就绪时重新登记。
func to_save() -> Dictionary:
	return {"states": _states.duplicate(true)}


func from_save(data: Dictionary) -> void:
	_states = {}
	var raw = data.get("states", {})
	if typeof(raw) == TYPE_DICTIONARY:
		for key in raw:
			var st = raw[key]
			if typeof(st) != TYPE_DICTIONARY:
				continue
			_states[str(key)] = {
				"affinity": clampi(int(st.get("affinity", 0)), 0, 100),
				"impression": str(st.get("impression", "")),
				"memories": _to_string_array(st.get("memories", [])),
			}
	for npc_name in _states:
		impression_changed.emit(str(npc_name))


func _to_string_array(raw) -> Array:
	var out: Array = []
	if typeof(raw) == TYPE_ARRAY:
		for item in raw:
			out.append(str(item))
	return out

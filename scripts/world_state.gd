extends Node
## 世界状态（Autoload 名字：WorldState）
##
## 记录玩家在这个世界里做过的大事，让 NPC 的台词、后续的任务能「记得」发生了什么。
## 和 NpcMemory 一样，这里只保留**有上限**的摘要：无论玩多久，喂给 AI 的内容长度恒定。
## 这也是「让世界有无限种结局」的地基——世界会记住你做过什么。

signal world_changed

## 最多记住几件大事，超了就丢最早的
const EVENTS_KEEP := 8

## 累计完成的任务数
var completed_count := 0
## 玩家做过的大事，每项形如 {"kind", "title", "npc", "target"}
var events: Array[Dictionary] = []
## 通用开关，供以后扩展（例如某个地点是否已经解锁）
var flags: Dictionary = {}


## 一件任务完成时调用，把它写进世界记忆
func record_quest(quest: Dictionary) -> void:
	events.append({
		"kind": "quest",
		"title": str(quest.get("title", "任务")),
		"npc": str(quest.get("source_npc", "")),
		"target": WorldData.name_of(str(quest.get("target_location", ""))),
	})
	while events.size() > EVENTS_KEEP:
		events.remove_at(0)
	completed_count += 1
	world_changed.emit()


func set_flag(key: String, value = true) -> void:
	if key == "":
		return
	flags[key] = value
	world_changed.emit()


func flag(key: String, default_value = null):
	return flags.get(key, default_value)


## 喂给 AI 的世界摘要——长度恒定，不会随游玩时间增长
func summary() -> String:
	if events.is_empty():
		return ""
	var lines: PackedStringArray = []
	lines.append("这个世界最近发生的事（玩家一共办成过 %d 件事）：" % completed_count)
	for e in events:
		var npc := str(e.get("npc", ""))
		var title := str(e.get("title", "某事"))
		if npc != "":
			lines.append("  - 玩家曾帮「%s」办成了「%s」" % [npc, title])
		else:
			lines.append("  - 玩家曾办成了「%s」" % title)
	return "\n".join(lines)


# ---------------------------------------------------------------- 存档

func to_save() -> Dictionary:
	return {
		"completed_count": completed_count,
		"events": events.duplicate(true),
		"flags": flags.duplicate(true),
	}


func from_save(data: Dictionary) -> void:
	completed_count = int(data.get("completed_count", 0))
	events.clear()
	var raw = data.get("events", [])
	if typeof(raw) == TYPE_ARRAY:
		for e in raw:
			if typeof(e) == TYPE_DICTIONARY:
				events.append(e)
	while events.size() > EVENTS_KEEP:
		events.remove_at(0)
	flags = {}
	var f = data.get("flags", {})
	if typeof(f) == TYPE_DICTIONARY:
		flags = f.duplicate(true)
	world_changed.emit()

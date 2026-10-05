extends Node
## NPC 之间的关系网（Autoload 名字：NpcRelations）
##
## 世界里的 NPC 不应该是互不相干的陌生人：一个 NPC 可以认识另一个 NPC，
## 他们之间可能沾着亲戚、有师承、是邻居、同乡、旧识、同行、做买卖，或者是对头。
##
## 两个约束：
##   1. 关系是**对称**的：A 认识 B，B 也就认识 A。所以存的时候两边各写一条，
##      一方的存档坏掉也不会让关系变成单向。
##   2. 关系有**上限**：每个 NPC 最多记 MAX_PER_NPC 条，避免大模型一高兴就把
##      所有人跟所有人扯上关系，prompt 长度也就不会失控。
##
## 关系的由来（note）要求用第三人称写，这样从哪一方的视角看都读得通。

signal relations_changed(npc_name: String)

## 关系种类（封闭枚举，AI 只能从里面挑；不在里面的会被收敛成「旧识」）
const KINDS := ["亲属", "师徒", "邻居", "同乡", "旧识", "同行", "生意往来", "对头"]
const DEFAULT_KIND := "旧识"
## 每个 NPC 最多记几条关系
const MAX_PER_NPC := 4
## note 的长度上限
const NOTE_MAX_LEN := 40

## 关系种类对应的中性说明（AI 不可用时的兜底）
const MOCK_NOTES := {
	"亲属": "沾着远房亲戚",
	"师徒": "早年跟着学过一手",
	"邻居": "住处离得不远，抬头不见低头见",
	"同乡": "是从同一个地方迁来的",
	"旧识": "早些年打过不少交道",
	"同行": "吃的是同一碗饭，彼此知根知底",
	"生意往来": "常有买卖上的来往",
	"对头": "为些旧事一直不太对付",
}

## 世界上被登记过的人（关系网里出现过的名字都算）
var _names: Array[String] = []
## npc_name -> Array[Dictionary]，每项 {target, kind, note}
var _relations: Dictionary = {}


# ---------------------------------------------------------------- 名字登记

## 登记一个「世上存在的人」。NPC 一生成/读档/开局就会被登记，
## 之后关系网里才允许出现这个名字。
func register(npc_name: String) -> void:
	var n := npc_name.strip_edges()
	if n == "" or _names.has(n):
		return
	_names.append(n)


func known_names() -> Array[String]:
	return _names.duplicate()


func is_registered(npc_name: String) -> bool:
	return _names.has(npc_name.strip_edges())


# ---------------------------------------------------------------- 关系

## 记下 A 和 B 的关系（双向写入，已存在则跳过）。
## 任一方关系数已达上限，或者两人本来就是关系，返回 false。
func link(a: String, b: String, kind: String, note: String = "") -> bool:
	var na := a.strip_edges()
	var nb := b.strip_edges()
	if na == "" or nb == "" or na == nb:
		return false
	if _linked(na, nb):
		return false
	if _count_of(na) >= MAX_PER_NPC or _count_of(nb) >= MAX_PER_NPC:
		return false
	var k := sanitize_kind(kind)
	var n := _clean_note(note)
	register(na)
	register(nb)
	_append(na, nb, k, n)
	_append(nb, na, k, n)
	relations_changed.emit(na)
	relations_changed.emit(nb)
	return true


## 这个 NPC 认得的所有人
func relations_of(npc_name: String) -> Array:
	var arr = _relations.get(npc_name.strip_edges(), [])
	if typeof(arr) != TYPE_ARRAY:
		return []
	return (arr as Array).duplicate(true)


func has_relations(npc_name: String) -> bool:
	return not relations_of(npc_name).is_empty()


## 两个人之间是什么关系（没有就返回空字符串）
func kind_of(a: String, b: String) -> String:
	var na := a.strip_edges()
	var nb := b.strip_edges()
	var arr = _relations.get(na, [])
	if typeof(arr) != TYPE_ARRAY:
		return ""
	for item in (arr as Array):
		if typeof(item) == TYPE_DICTIONARY and str((item as Dictionary).get("target", "")) == nb:
			return str((item as Dictionary).get("kind", ""))
	return ""


## 无向关系的条数（一对算一条），探针与统计用
func total_links() -> int:
	var n := 0
	for key in _relations:
		var arr = _relations[key]
		if typeof(arr) == TYPE_ARRAY:
			n += (arr as Array).size()
	return n / 2


## 喂给 AI 的紧凑描述：这个 NPC 认得谁、跟他是什么关系。
## 有上限，不会随关系变多把 prompt 撑爆。
func describe(npc_name: String) -> String:
	var rels := relations_of(npc_name)
	if rels.is_empty():
		return ""
	var lines: PackedStringArray = []
	lines.append("你在这个世上认得的人（聊到合适的话题时可以顺口提一句，别提得生硬）：")
	for item in rels:
		var target := str(item.get("target", ""))
		var kind := str(item.get("kind", ""))
		var note := str(item.get("note", "")).strip_edges()
		if note == "":
			lines.append("  - %s（%s）" % [target, kind])
		else:
			lines.append("  - %s（%s）：%s" % [target, kind, note])
	return "\n".join(lines)


# ---------------------------------------------------------------- 兜底补网

## 让每个已登记的人至少认得 min_per 个人。AI 没接入、或者读的是老存档时，
## 靠它也能有一张街坊关系网，不至于满村陌生人。
## 返回新建立了多少条关系。可反复调用，不会重复连线。
func ensure_links(min_per: int = 1) -> int:
	var names := known_names()
	if names.size() < 2:
		return 0
	var added := 0
	var n := names.size()
	for i in n:
		var a := names[i]
		if _count_of(a) >= min_per:
			continue
		for step in range(1, n):
			var b := names[(i + step) % n]
			if b == a or _linked(a, b):
				continue
			var kind := auto_kind(a, b)
			if link(a, b, kind, note_for(kind)):
				added += 1
			break
	return added


## 由两个人名 + 世界种子稳定地挑一种关系（同一个世界里同一对永远是同一种关系）
func auto_kind(a: String, b: String) -> String:
	var rng := RandomNumberGenerator.new()
	rng.seed = absi(hash(a.strip_edges())) * 31 + absi(hash(b.strip_edges())) + RegionGenerator.world_seed
	return str(KINDS[rng.randi_range(0, KINDS.size() - 1)])


func note_for(kind: String) -> String:
	return str(MOCK_NOTES.get(sanitize_kind(kind), ""))


## 把任意字符串收敛成合法的关系种类
func sanitize_kind(raw: String) -> String:
	var k := raw.strip_edges()
	if KINDS.has(k):
		return k
	return DEFAULT_KIND


# ---------------------------------------------------------------- 存档

func to_save() -> Dictionary:
	return {
		"names": _names.duplicate(),
		"relations": _relations.duplicate(true),
	}


func from_save(data: Dictionary) -> void:
	_names = []
	_relations = {}
	var raw_names = data.get("names", [])
	if typeof(raw_names) == TYPE_ARRAY:
		for item in (raw_names as Array):
			register(str(item))
	var raw = data.get("relations", {})
	if typeof(raw) != TYPE_DICTIONARY:
		return
	for key in (raw as Dictionary):
		var a := str(key).strip_edges()
		if a == "":
			continue
		register(a)
		var src = raw[key]
		if typeof(src) != TYPE_ARRAY:
			continue
		var kept: Array = []
		for item in (src as Array):
			if typeof(item) != TYPE_DICTIONARY:
				continue
			var d: Dictionary = item
			var target := str(d.get("target", "")).strip_edges()
			if target == "" or target == a or _has_target(kept, target):
				continue
			if kept.size() >= MAX_PER_NPC:
				break
			register(target)
			kept.append({
				"target": target,
				"kind": sanitize_kind(str(d.get("kind", ""))),
				"note": _clean_note(str(d.get("note", ""))),
			})
		_relations[a] = kept
	for npc_name in _names:
		relations_changed.emit(str(npc_name))


# ---------------------------------------------------------------- 内部

func _append(a: String, b: String, kind: String, note: String) -> void:
	var arr = _relations.get(a, [])
	if typeof(arr) != TYPE_ARRAY:
		arr = []
	arr.append({"target": b, "kind": kind, "note": note})
	_relations[a] = arr


func _count_of(npc_name: String) -> int:
	var arr = _relations.get(npc_name, [])
	if typeof(arr) != TYPE_ARRAY:
		return 0
	return (arr as Array).size()


func _linked(a: String, b: String) -> bool:
	var arr = _relations.get(a, [])
	if typeof(arr) != TYPE_ARRAY:
		return false
	for item in (arr as Array):
		if typeof(item) == TYPE_DICTIONARY and str((item as Dictionary).get("target", "")) == b:
			return true
	return false


func _has_target(arr: Array, target: String) -> bool:
	for item in arr:
		if typeof(item) == TYPE_DICTIONARY and str((item as Dictionary).get("target", "")) == target:
			return true
	return false


func _clean_note(note: String) -> String:
	return note.strip_edges().strip_escapes().left(NOTE_MAX_LEN)

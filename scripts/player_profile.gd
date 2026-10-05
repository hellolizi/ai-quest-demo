extends Node
## 玩家行为画像：记录玩家的行为，并聚合成可供 AI 使用的画像数据。
## 这是一个 Autoload（全局单例），名字叫 PlayerProfile，其它脚本可直接访问。

## 生命 / 装备 / 背包发生变化时广播，HUD 与界面据此刷新
signal hp_changed(hp: int, max_hp: int)
signal died
signal weapon_changed(id: String)
signal gold_changed(amount: int)

var distance_traveled := 0.0          # 累计移动距离（像素）
var talks: Dictionary = {}            # 每个 NPC 的交谈次数  npc_name -> count
var total_talks := 0                  # 总交谈次数
var quests_accepted := 0              # 已接受的任务数
var quests_completed := 0             # 已完成的任务数
var gold := 0                         # 累计获得的金币
var play_time := 0.0                  # 游戏时长（秒）
var ui_open := false                  # 对话界面是否打开（打开时禁止移动）
var recent_events: Array[String] = [] # 最近做过的事（给 NPC 台词用，让 NPC「记得」玩家）
const RECENT_EVENTS_KEEP := 6

# ---------------------------------------------------------------- 语言与道具

## 通译符：带在身上就能听懂外语；也能转赠给别人，让别人听懂你的话
const TRANSLATOR_ID := "translator"
const TRANSLATOR_NAME := "通译符"
## 跟当地人学几次算掌握一门语言
const LESSONS_TO_LEARN := 3

var native_language := ""                 # 母语（出生文化圈的语言）
var known_languages: Array[String] = []   # 已经学会的语言
var _lessons: Dictionary = {}             # lang -> 已学次数
var items: Dictionary = {}                # 道具 id -> 数量
var gifted_npcs: Array[String] = []       # 收过你通译符的 NPC 名字
var spouse := ""                          # 伴侣的 NPC 名字（空=未婚）


## 记一件玩家刚做过的事，供 NPC 台词参考
func record_event(text: String) -> void:
	var t := text.strip_edges()
	if t == "":
		return
	recent_events.append(t)
	while recent_events.size() > RECENT_EVENTS_KEEP:
		recent_events.remove_at(0)


func _process(delta: float) -> void:
	play_time += delta


func add_distance(amount: float) -> void:
	distance_traveled += amount


func record_talk(npc_name: String) -> void:
	talks[npc_name] = int(talks.get(npc_name, 0)) + 1
	total_talks += 1


## 和某个 NPC 一共聊过几次（好感/印象刷新节奏用）
func talk_count(npc_name: String) -> int:
	return int(talks.get(npc_name, 0))


func record_quest_accepted(title: String = "") -> void:
	quests_accepted += 1
	if title != "":
		record_event("接下了「%s」这个任务" % title)


## 任务完成时调用，把金币结算进画像（武器带「任务金币 +N%」时按比例加成）
func record_quest_completed(reward_gold: int, title: String = "") -> void:
	quests_completed += 1
	var bonus := weapon_effect("gold_bonus", 0.0)
	var total := reward_gold
	if reward_gold > 0 and bonus > 0.0:
		total = int(round(float(reward_gold) * (1.0 + bonus)))
	add_gold(total)
	if title != "":
		record_event("完成了「%s」，拿到了 %d 枚金币" % [title, total])


# ---------------------------------------------------------------- 生命与战斗

## 空手基础血量 / 基础攻击（不含武器加成）
const BASE_MAX_HP := 100
const BASE_ATTACK := 6

var hp := BASE_MAX_HP                 # 当前血量
var equipped_weapon := ""             # 当前装备的武器 id（空=空手）
var owned_weapons: Array[String] = [] # 已拥有的武器 id 列表

## 复活点：在客栈睡过之后改成那家客栈；没设过就回本乡出生点。
## 存成 {x,y} 而不是 Vector2，为的是能直接进 JSON 存档。
var respawn_point: Dictionary = {}
var respawn_name := ""


## 在客栈住下：把这里记成往后的复活点
func set_respawn(pos: Vector2, place_name: String = "") -> void:
	respawn_point = {"x": pos.x, "y": pos.y}
	respawn_name = place_name
	if place_name != "":
		record_event("在%s住下，把这里记成了落脚点" % place_name)


## 倒下后该送回哪里：设过复活点就回客栈，否则回本乡出生点
func respawn_pos() -> Vector2:
	if respawn_point.is_empty():
		return CultureData.spawn_point()
	return Vector2(float(respawn_point.get("x", 0.0)), float(respawn_point.get("y", 0.0)))


## 装备某把武器后，它提供的某个效果数值（没有则返回 default）
func weapon_effect(key: String, default: float = 0.0) -> float:
	if equipped_weapon == "":
		return default
	var w = WeaponData.get_weapon(equipped_weapon)
	if typeof(w) != TYPE_DICTIONARY:
		return default
	var effects = w.get("effects", {})
	if typeof(effects) == TYPE_DICTIONARY and effects.has(key):
		return float(effects[key])
	return default


## 血量上限 = 基础 + 武器加成
func max_hp() -> int:
	return int(round(BASE_MAX_HP + weapon_effect("max_hp", 0.0)))


## 攻击力 = 基础 + 武器伤害（伤害是武器的顶层字段，不在 effects 里）
func attack_power() -> int:
	var dmg := 0.0
	if equipped_weapon != "":
		var w = WeaponData.get_weapon(equipped_weapon)
		if typeof(w) == TYPE_DICTIONARY:
			dmg = float(w.get("damage", 0))
	return int(round(BASE_ATTACK + dmg))


## 是不是已经拥有这把武器
func has_weapon(id: String) -> bool:
	return id != "" and owned_weapons.has(id)


## 获得一把武器（自动记入画像事件）
func add_weapon(id: String) -> bool:
	if id == "" or has_weapon(id):
		return false
	owned_weapons.append(id)
	var w = WeaponData.get_weapon(id)
	var wname := str(w.get("name", id)) if typeof(w) == TYPE_DICTIONARY else id
	record_event("得到了武器「%s」" % wname)
	return true


## 装备武器（必须先拥有）；传空串表示卸下
func equip_weapon(id: String) -> bool:
	if id != "" and not has_weapon(id):
		return false
	equipped_weapon = id
	if hp > max_hp():
		hp = max_hp()
	weapon_changed.emit(equipped_weapon)
	hp_changed.emit(hp, max_hp())
	return true


## 失去一把武器（拍卖行卖掉时用）。装备中的不能丢，返回是否成功。
func remove_weapon(id: String) -> bool:
	if id == "" or not has_weapon(id) or id == equipped_weapon:
		return false
	owned_weapons.erase(id)
	return true


## 增加金币（正数）
func add_gold(amount: int) -> void:
	if amount <= 0:
		return
	gold += amount
	gold_changed.emit(gold)


## 花掉金币，够才扣，返回是否成功
func spend_gold(amount: int) -> bool:
	if amount <= 0:
		return true
	if gold < amount:
		return false
	gold -= amount
	gold_changed.emit(gold)
	return true


## 受到伤害：扣掉防御后结算，归零则广播死亡
func take_damage(amount: int) -> void:
	var dmg := amount - int(weapon_effect("defense", 0.0))
	if dmg < 1:
		dmg = 1
	hp -= dmg
	if hp <= 0:
		hp = 0
		hp_changed.emit(hp, max_hp())
		died.emit()
		return
	hp_changed.emit(hp, max_hp())


## 回血（不超过上限）
func heal(amount: int) -> void:
	if amount <= 0:
		return
	hp = mini(max_hp(), hp + amount)
	hp_changed.emit(hp, max_hp())


## 倒下后复活：回满血（由主场景在玩家死亡时调用）
func revive() -> void:
	hp = max_hp()
	hp_changed.emit(hp, max_hp())


# ---------------------------------------------------------------- 移动距离标准

## 距离尺度：与 LocationGenerator.PX_PER_METER 保持一致（20 像素约合 1 米）
const PX_PER_METER := 20.0
## 「走过远路」的标准（米）。累计移动不到这个数，任何地方都不许说玩家「移动距离过长 / 走了很多路」。
const FAR_DISTANCE_M := 80.0
## 「踏遍周边」的标准（米），比 FAR 高一档
const ROAM_DISTANCE_M := 180.0


## 累计移动距离换算成米
func distance_m() -> int:
	return int(distance_traveled / PX_PER_METER)


## 累计移动是否已经够格被称作「走过远路 / 移动距离长」
func traveled_far() -> bool:
	return distance_traveled / PX_PER_METER >= FAR_DISTANCE_M


## 用带标准的措辞描述移动距离。
## 不把原始像素数直接交给 AI，否则它会没有尺度参照、随口说玩家「距离过长」。
func travel_phrase() -> String:
	var meters := distance_traveled / PX_PER_METER
	if meters >= ROAM_DISTANCE_M:
		return "已经走过很远的路，几乎踏遍了周边的每条道路"
	if meters >= FAR_DISTANCE_M:
		return "已经走过不少远路"
	return "活动范围还很小，基本没离开过村子附近"


## 把原始行为换算成 0~1 的维度值，方便喂给 AI
func traits() -> Dictionary:
	return {
		"exploration": clampf(distance_traveled / 4000.0, 0.0, 1.0),
		"social": clampf(float(total_talks) / 12.0, 0.0, 1.0),
		"persistence": clampf(play_time / 300.0, 0.0, 1.0),
	}


## 当前最突出的行为倾向
func dominant_trait() -> String:
	var t := traits()
	var best := "exploration"
	var best_value := -1.0
	for key in t:
		if t[key] > best_value:
			best_value = t[key]
			best = key
	return best


## 导出给任务生成器使用的画像
func to_dict() -> Dictionary:
	return {
		"distance_traveled": int(distance_traveled),
		"distance_m": distance_m(),
		"traveled_far": traveled_far(),
		"travel_description": travel_phrase(),
		"total_talks": total_talks,
		"talks_by_npc": talks.duplicate(),
		"quests_accepted": quests_accepted,
		"quests_completed": quests_completed,
		"gold": gold,
		"play_seconds": int(play_time),
		"traits": traits(),
		"dominant_trait": dominant_trait(),
		"recent_events": recent_events.duplicate(),
		"summary": _summary(),
	}


func _summary() -> String:
	var t := traits()
	var text := "该玩家%s，与 NPC 交谈 %d 次，已完成 %d 个任务。" % [
		travel_phrase(), total_talks, quests_completed,
	]
	if t["exploration"] > 0.6:
		text += "明显偏好四处探索。"
	elif t["social"] > 0.6:
		text += "明显偏好与 NPC 社交互动。"
	else:
		text += "行为模式较为常规。"
	return text


# ---------------------------------------------------------------- 语言

## 会不会这门语言（空语言=没有语言隔阂，算会）
func knows_language(lang: String) -> bool:
	if lang == "":
		return true
	if lang == native_language:
		return true
	return known_languages.has(lang)


## 直接掌握一门语言（母语也可以在这里登记）
func learn_language(lang: String) -> void:
	if lang == "" or knows_language(lang):
		return
	known_languages.append(lang)
	record_event("学会了%s" % CultureData.language_name(lang))


## 跟当地人学一次；学满 LESSONS_TO_LEARN 次自动掌握。返回当前已学次数
func add_lesson(lang: String) -> int:
	if lang == "":
		return 0
	var count := int(_lessons.get(lang, 0)) + 1
	_lessons[lang] = count
	if count >= LESSONS_TO_LEARN:
		learn_language(lang)
	return count


func lesson_count(lang: String) -> int:
	return int(_lessons.get(lang, 0))


# ---------------------------------------------------------------- 道具

func has_item(id: String) -> bool:
	return int(items.get(id, 0)) > 0


func add_item(id: String, count: int = 1) -> void:
	if id == "" or count <= 0:
		return
	items[id] = int(items.get(id, 0)) + count


func remove_item(id: String, count: int = 1) -> bool:
	var have := int(items.get(id, 0))
	if have < count:
		return false
	var left := have - count
	if left > 0:
		items[id] = left
	else:
		items.erase(id)
	return true


func has_translator() -> bool:
	return has_item(TRANSLATOR_ID)


func npc_has_translator(npc_name: String) -> bool:
	return gifted_npcs.has(npc_name)


## 把通译符送给某个 NPC：他从此能听懂你的话，你也就听得懂他回的话
func gift_translator(npc_name: String) -> bool:
	if npc_name == "" or not has_translator():
		return false
	remove_item(TRANSLATOR_ID, 1)
	if not gifted_npcs.has(npc_name):
		gifted_npcs.append(npc_name)
	record_event("把通译符送给了%s" % npc_name)
	return true


## 能不能听懂某个文化圈、某个 NPC 说的话
func understands(culture_id: String, npc_name: String) -> bool:
	var lang := CultureData.language_of_culture(culture_id)
	if lang == "":
		return true
	if knows_language(lang):
		return true
	# 身上带着通译符，听谁都懂
	if has_translator():
		return true
	# 把通译符送给了这个人，他就会改用你的话说
	if gifted_npcs.has(npc_name):
		return true
	return false


# ---------------------------------------------------------------- 婚姻

## 是否已经成婚
func is_married() -> bool:
	return spouse != ""


## 向某个 NPC 求婚成功：记下这个人作为伴侣。已经有伴侣时不再改。返回是否成功。
func marry(npc_name: String) -> bool:
	var name := npc_name.strip_edges()
	if name == "" or is_married():
		return false
	spouse = name
	record_event("和%s结成了伴侣" % name)
	return true


## 新游戏：母语是出生地的语言，开局祖传一枚通译符
func new_game() -> void:
	native_language = CultureData.language_of_culture(CultureData.current_id)
	known_languages.clear()
	_lessons.clear()
	items.clear()
	gifted_npcs.clear()
	spouse = ""
	hp = BASE_MAX_HP
	equipped_weapon = ""
	owned_weapons.clear()
	respawn_point = {}
	respawn_name = ""
	add_item(TRANSLATOR_ID, 1)


# ---------------------------------------------------------------- 存档

## 读档后 ui_open 必须是 false（对话界面默认是关的），所以不入档
func to_save() -> Dictionary:
	return {
		"distance_traveled": distance_traveled,
		"talks": talks.duplicate(),
		"total_talks": total_talks,
		"quests_accepted": quests_accepted,
		"quests_completed": quests_completed,
		"gold": gold,
		"play_time": play_time,
		"recent_events": recent_events.duplicate(),
		"native_language": native_language,
		"known_languages": known_languages.duplicate(),
		"lessons": _lessons.duplicate(),
		"items": items.duplicate(),
		"gifted_npcs": gifted_npcs.duplicate(),
		"spouse": spouse,
		"hp": hp,
		"equipped_weapon": equipped_weapon,
		"owned_weapons": owned_weapons.duplicate(),
		"respawn_point": respawn_point.duplicate(),
		"respawn_name": respawn_name,
	}


func from_save(data: Dictionary) -> void:
	distance_traveled = float(data.get("distance_traveled", 0.0))
	var t = data.get("talks", {})
	talks = t.duplicate() if typeof(t) == TYPE_DICTIONARY else {}
	total_talks = int(data.get("total_talks", 0))
	quests_accepted = int(data.get("quests_accepted", 0))
	quests_completed = int(data.get("quests_completed", 0))
	gold = int(data.get("gold", 0))
	play_time = float(data.get("play_time", 0.0))
	recent_events.clear()
	var ev = data.get("recent_events", [])
	if typeof(ev) == TYPE_ARRAY:
		for e in ev:
			recent_events.append(str(e))
	while recent_events.size() > RECENT_EVENTS_KEEP:
		recent_events.remove_at(0)
	native_language = str(data.get("native_language", ""))
	known_languages.clear()
	var kl = data.get("known_languages", [])
	if typeof(kl) == TYPE_ARRAY:
		for item in (kl as Array):
			known_languages.append(str(item))
	var ls = data.get("lessons", {})
	_lessons = ls.duplicate() if typeof(ls) == TYPE_DICTIONARY else {}
	var it = data.get("items", {})
	items = it.duplicate() if typeof(it) == TYPE_DICTIONARY else {}
	gifted_npcs.clear()
	var gn = data.get("gifted_npcs", [])
	if typeof(gn) == TYPE_ARRAY:
		for item in (gn as Array):
			gifted_npcs.append(str(item))
	spouse = str(data.get("spouse", ""))
	owned_weapons.clear()
	var ow = data.get("owned_weapons", [])
	if typeof(ow) == TYPE_ARRAY:
		for item in (ow as Array):
			var wid := str(item)
			if wid != "" and not owned_weapons.has(wid):
				owned_weapons.append(wid)
	equipped_weapon = str(data.get("equipped_weapon", ""))
	if equipped_weapon != "" and not has_weapon(equipped_weapon):
		equipped_weapon = ""
	var rp = data.get("respawn_point", {})
	respawn_point = rp.duplicate() if typeof(rp) == TYPE_DICTIONARY else {}
	respawn_name = str(data.get("respawn_name", ""))
	hp = int(data.get("hp", BASE_MAX_HP))
	if hp <= 0:
		hp = max_hp()
	hp = clampi(hp, 1, max_hp())

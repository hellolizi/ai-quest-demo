extends Node
## 武器 / 材料数据（Autoload 名字：WeaponData）
##
## 三类东西都在这里定义：
##   1. 预设结局武器：4 条预设主线各一把，走完对应结局就能拿到，带独特的具体效果；
##   2. 锻造武器：村子 / 城市的锻造台都能造，城市更贵但品质更好；
##   3. 锻造 / 掉落用的材料：矿石、木料、兽皮、晶石……
##
## 效果（effects）都是有具体数值加成的，玩家装上就能感受到：
##   max_hp      生命上限 +N
##   speed       移动速度 +N（像素/秒）
##   range       攻击距离 +N
##   defense     每次受到伤害 -N
##   lifesteal   造成伤害的 N（0~1）比例回血
##   crit        暴击率 +N（0~1），暴击打出双倍伤害
##   affinity    与 NPC 的好感增长 +N（0~1）
##   gold_bonus  任务金币收益 +N（0~1）
##   atk_speed   攻击间隔缩短 N（秒）

signal changed

## 运行时注册的武器：玩家自定义的现代结局需要一把「预先没存过的」枪械，
## 就用这里现造一把（图标交给生图 AI 画）。预设 / 锻造武器都不进这里。
var _dynamic: Dictionary = {}

## 图标统一走 RewardLibrary：武器 -> weapon_<id>，材料 -> mat_<id>
const WEAPON_TAG_PREFIX := "weapon_"
const MATERIAL_TAG_PREFIX := "mat_"

## 锻造品质：村庄 = 便宜、品质低；城市 = 更贵、品质好
const QUALITY := {
	"village": {"suffix": "_v", "label": "粗制", "damage_mul": 0.8, "price_mul": 1.0},
	"city": {"suffix": "_c", "label": "精锻", "damage_mul": 1.35, "price_mul": 2.5},
}

## 材料表：id -> {name, hint}（hint 是给生图 AI 的外观描述）
const MATERIALS := {
	"ore_iron": {"name": "铁矿", "hint": "一块灰黑色的铁矿石，带金属光泽，棱角分明"},
	"ore_copper": {"name": "铜矿", "hint": "一块红棕色的铜矿石，表面有氧化绿斑"},
	"wood": {"name": "木料", "hint": "一捆削好的木料，浅棕色木质纹理清晰"},
	"leather": {"name": "兽皮", "hint": "一张鞣制过的兽皮，粗糙的棕色皮革，边角卷起"},
	"crystal": {"name": "晶石", "hint": "一块半透明的淡蓝色晶石，内部微微发光"},
}

## 4 把预设结局武器：ending 字段与 StoryDirector.ENDING_NAMES 对齐
const PRESET := {
	"warden_blade": {
		"name": "守望之刃",
		"ending": "warden",
		"kind": "长剑",
		"tier": 4,
		"damage": 22,
		"effects": {"max_hp": 60, "defense": 3},
		"hint": "一把厚重的宽刃长剑，银灰色剑身，护手刻着炊烟与屋檐的纹路，剑柄缠褐色皮革，正面竖立",
	},
	"wanderer_bow": {
		"name": "远行之弓",
		"ending": "wanderer",
		"kind": "长弓",
		"tier": 4,
		"damage": 17,
		"effects": {"speed": 45, "range": 60},
		"hint": "一把轻巧的木质长弓，弓身有长途跋涉的磨损痕迹，弓弦紧绷，斜靠着一支羽箭，正面",
	},
	"bridge_hammer": {
		"name": "架桥之锤",
		"ending": "bridge",
		"kind": "战锤",
		"tier": 4,
		"damage": 26,
		"effects": {"affinity": 0.5, "gold_bonus": 0.3},
		"hint": "一把沉重的大锤，锤头由木与铁箍合成，缠着粗麻绳，像是能敲进桥桩的样子，正面",
	},
	"hermit_dagger": {
		"name": "独行之匕",
		"ending": "hermit",
		"kind": "匕首",
		"tier": 4,
		"damage": 15,
		"effects": {"lifesteal": 0.3, "crit": 0.2},
		"hint": "一把细长的短匕，暗银色刀刃，刀柄朴素无纹，透着冷意，正面",
	},
}

## 可锻造武器的基础样式：村/城锻造共用同一套图纸，只是品质不同
const FORGE_BASE := {
	"iron_sword": {
		"name": "铁剑",
		"kind": "长剑",
		"damage": 12,
		"effects": {},
		"hint": "一把朴素的直刃铁剑，简单护手，铁质剑柄，正面竖立",
		"materials": {"ore_iron": 3, "wood": 1},
		"gold": 40,
	},
	"hunt_bow": {
		"name": "猎弓",
		"kind": "长弓",
		"damage": 10,
		"effects": {"range": 30},
		"hint": "一把简易的木质猎弓，弓身弯曲，麻绳弓弦，正面",
		"materials": {"wood": 4, "leather": 1},
		"gold": 35,
	},
	"hand_axe": {
		"name": "手斧",
		"kind": "斧",
		"damage": 14,
		"effects": {"crit": 0.1},
		"hint": "一把单手小斧，铁质斧刃，木制短柄，斧背厚重，正面",
		"materials": {"ore_iron": 2, "wood": 2},
		"gold": 45,
	},
	"copper_spear": {
		"name": "铜矛",
		"kind": "长矛",
		"damage": 13,
		"effects": {"range": 40},
		"hint": "一把铜头长矛，矛尖泛红铜色，长木杆，正面斜立",
		"materials": {"ore_copper": 3, "wood": 2},
		"gold": 50,
	},
}

## 现代结局关键词：玩家输入这类结局时，主线会用到枪械（枪械交生图 AI 现画）
const MODERN_KEYWORDS := [
	"现代", "枪", "手枪", "步枪", "火器", "科技", "都市", "未来", "赛博", "机甲", "飞船",
	"科学", "电子", "机器",
]

## 材料基准价（村庄价）；城市进货更贵，见 shop_materials
const MATERIAL_PRICE := {
	"wood": 6, "leather": 8, "ore_iron": 10, "ore_copper": 14, "crystal": 25,
}

## 商铺进货清单：村庄只卖最常见的三样，城市货更全（含稀有的铜矿、晶石）
const SHOP_KINDS := {
	"village": ["wood", "leather", "ore_iron"],
	"city": ["wood", "leather", "ore_iron", "ore_copper", "crystal"],
}

## 各类武器「打一下到能打第二下」的基准间隔（秒），照现实里这类武器的使用节奏定：
##   匕首最快（贴身快速连刺）；长剑适中（一记劈砍再回架）；
##   长矛要收杆再刺、斧与战锤抡起来沉重；长弓要重新搭箭拉弦；
##   手枪是半自动点射、节奏偏快；步枪要拉栓 / 换弹匣；
##   能量枪打完要重新充能，间隔最长。
## 数值全集中在这一张表里，想调手感只改这里。
const KIND_COOLDOWN := {
	"匕首": 0.30,
	"长剑": 0.55,
	"长矛": 0.75,
	"斧": 0.85,
	"战锤": 0.95,
	"长弓": 1.10,
	"手枪": 0.60,
	"步枪": 1.40,
	"能量枪": 1.60,
}

## 空手 / 认不出的武器类型，用的默认间隔（等于空手挥拳的节奏）
const DEFAULT_COOLDOWN := 0.55


# ---------------------------------------------------------------- 查询

## 这是不是一把「预设结局武器」
func is_preset(id: String) -> bool:
	return PRESET.has(id)


## 某个武器类型（kind）的基准攻击间隔（秒）；认不出就用空手间隔
func cooldown_for_kind(kind: String) -> float:
	return float(KIND_COOLDOWN.get(kind, DEFAULT_COOLDOWN))


## 某把武器的基准攻击间隔（秒）。空手 / 认不出的 id 都返回空手间隔。
func base_cooldown(id: String) -> float:
	if id.strip_edges() == "":
		return DEFAULT_COOLDOWN
	var w := get_weapon(id)
	if w.is_empty():
		return DEFAULT_COOLDOWN
	return cooldown_for_kind(str(w.get("kind", "")))


## 注册一把运行时现造的武器（重复注册会覆盖）
func register_weapon(id: String, data: Dictionary) -> void:
	if id.strip_edges() == "":
		return
	_dynamic[id.strip_edges()] = data.duplicate(true)
	changed.emit()


## 这个 id 现在能不能取到武器数据
func has_weapon_id(id: String) -> bool:
	return not get_weapon(id).is_empty()


## 现代结局：按玩家写的关键词现造一把枪械，并排给生图 AI 画图标。
## 返回武器 id；不是现代结局（或文本为空）返回空串。
func ensure_modern_weapon(text: String) -> String:
	var t := text.strip_edges()
	if not is_modern_goal(t):
		return ""
	var name := "制式手枪"
	var kind := "手枪"
	var hint := "一把现代半自动手枪，黑色金属枪身，握把有防滑纹，侧面视角"
	if t.contains("步枪") or t.contains("火器"):
		name = "制式步枪"
		kind = "步枪"
		hint = "一把现代突击步枪，黑色枪身配金属弹匣，侧面视角"
	elif t.contains("机甲") or t.contains("机器") or t.contains("赛博"):
		name = "脉冲手枪"
		kind = "能量枪"
		hint = "一把科幻能量手枪，枪身有蓝色发光凹槽，金属配深色聚合物，侧面视角"
	elif t.contains("未来") or t.contains("飞船") or t.contains("科技") or t.contains("电子"):
		name = "脉冲步枪"
		kind = "能量枪"
		hint = "一把未来感十足的能量步枪，银白色枪身带蓝色光带，侧面视角"
	var id := "modern_gun"
	register_weapon(id, {
		"name": name,
		"kind": kind,
		"tier": 4,
		"damage": 24,
		"effects": {"range": 90, "crit": 0.15},
		"quality": "modern",
		"quality_label": "现代",
		"icon_tag": WEAPON_TAG_PREFIX + id,
		"hint": hint,
	})
	# 图标交给生图 AI（预先没存过的东西，正是生图 AI 的兜底职责）
	var gen := get_node_or_null("/root/RewardIconGenerator")
	if gen != null and gen.has_method("request_named"):
		gen.request_named(WEAPON_TAG_PREFIX + id, name, hint)
	return id


## 这个结局 id 对应的预设武器 id；没有就返回空串
func preset_id_for_ending(ending_id: String) -> String:
	for id in PRESET.keys():
		if str(PRESET[id].get("ending", "")) == ending_id:
			return str(id)
	return ""


## 拿一把武器的完整数据（已按锻造品质折算过数值）。没有返回 {}。
func get_weapon(id: String) -> Dictionary:
	var key := id.strip_edges()
	if key == "":
		return {}
	# 运行时现造的武器（比如枪械）优先
	if _dynamic.has(key):
		var d: Dictionary = _dynamic[key].duplicate(true)
		d["id"] = key
		if not d.has("icon_tag"):
			d["icon_tag"] = WEAPON_TAG_PREFIX + key
		return d
	if PRESET.has(key):
		var w: Dictionary = PRESET[key].duplicate(true)
		w["id"] = key
		w["quality"] = "preset"
		w["quality_label"] = "传说"
		w["icon_tag"] = WEAPON_TAG_PREFIX + key
		return w
	# 锻造武器：<base>_v / <base>_c
	for q in QUALITY.keys():
		var suf := str(QUALITY[q]["suffix"])
		if not key.ends_with(suf):
			continue
		var base_id := key.substr(0, key.length() - suf.length())
		if not FORGE_BASE.has(base_id):
			continue
		var b: Dictionary = FORGE_BASE[base_id].duplicate(true)
		var mul := float(QUALITY[q]["damage_mul"])
		b["id"] = key
		b["base_id"] = base_id
		b["name"] = "%s%s" % [str(QUALITY[q]["label"]), str(b["name"])]
		b["damage"] = maxi(1, int(round(float(b["damage"]) * mul)))
		b["tier"] = 2 if q == "village" else 3
		b["quality"] = q
		b["quality_label"] = str(QUALITY[q]["label"])
		b["icon_tag"] = WEAPON_TAG_PREFIX + base_id
		return b
	return {}


## 所有武器的 id 清单（4 把预设 + 村/城两档锻造）
func all_ids() -> Array[String]:
	var out: Array[String] = []
	for id in PRESET.keys():
		out.append(str(id))
	for q in QUALITY.keys():
		for base_id in FORGE_BASE.keys():
			out.append("%s%s" % [base_id, str(QUALITY[q]["suffix"])])
	return out


## 所有武器的完整数据清单（用于图鉴 / 界面）
func all_weapons() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id in all_ids():
		var w := get_weapon(id)
		if not w.is_empty():
			out.append(w)
	return out


## 锻造台给的清单：facility_kind = "village" / "city"
func forge_options(facility_kind: String) -> Array[Dictionary]:
	var q := "city" if facility_kind == "city" else "village"
	var out: Array[Dictionary] = []
	for base_id in FORGE_BASE.keys():
		var id := "%s%s" % [base_id, str(QUALITY[q]["suffix"])]
		var w := get_weapon(id)
		if not w.is_empty():
			out.append(w)
	return out


## 锻造一把武器要花多少钱、多少材料
func forge_cost(base_id: String, facility_kind: String) -> Dictionary:
	if not FORGE_BASE.has(base_id):
		return {}
	var q := "city" if facility_kind == "city" else "village"
	var b: Dictionary = FORGE_BASE[base_id]
	var gold := int(round(float(b.get("gold", 0)) * float(QUALITY[q]["price_mul"])))
	var mats: Dictionary = {}
	var src: Dictionary = b.get("materials", {})
	for mid in src.keys():
		var n := int(src[mid])
		if q == "city":
			n += 1  # 城市要更多、更好的料
		mats[str(mid)] = n
	return {"gold": gold, "materials": mats, "quality": q}


## 商铺卖的材料清单：facility_kind = "village" / "city"
## 村庄卖常见材料、价格低；城市货更全、单价更高。
func shop_materials(facility_kind: String) -> Array[Dictionary]:
	var kind := "city" if facility_kind == "city" else "village"
	var out: Array[Dictionary] = []
	for mid in SHOP_KINDS[kind]:
		var m := str(mid)
		var price := int(MATERIAL_PRICE.get(m, 10))
		if kind == "city":
			price = int(round(float(price) * 1.6))
		out.append({"id": m, "name": material_name(m), "price": price})
	return out


## 商铺直接卖的成品武器：只有城市商铺卖（好货），村里只卖材料。
## 价格按「城市锻造成本 × 1.8」算，比自己攒料锻要贵——花钱买省事。
func shop_weapons(facility_kind: String) -> Array[Dictionary]:
	if facility_kind != "city":
		return []
	var out: Array[Dictionary] = []
	for base_id in FORGE_BASE.keys():
		var w := get_weapon("%s%s" % [base_id, str(QUALITY["city"]["suffix"])])
		if w.is_empty():
			continue
		var cost := forge_cost(str(base_id), "city")
		w["price"] = int(round(float(cost.get("gold", 0)) * 1.8))
		out.append(w)
	return out


# ---------------------------------------------------------------- 拍卖行收购价

## 拍卖行收材料：按基准价六折（低于任何商铺售价，不存在低买高卖的空子）
func sell_material_price(material_id: String) -> int:
	var base := int(MATERIAL_PRICE.get(material_id, 0))
	return maxi(1, int(round(float(base) * 0.6)))


## 拍卖行收武器：按伤害折算；预设结局武器是主线信物，不回收（返回 0）
func sell_weapon_price(id: String) -> int:
	if is_preset(id):
		return 0
	var w := get_weapon(id)
	if w.is_empty():
		return 0
	return maxi(5, int(round(float(w.get("damage", 0)) * 3.0)))


# ---------------------------------------------------------------- 材料

func is_material(id: String) -> bool:
	return MATERIALS.has(id)


func material_name(id: String) -> String:
	if MATERIALS.has(id):
		return str(MATERIALS[id]["name"])
	return str(id)


func material_hint(id: String) -> String:
	if MATERIALS.has(id):
		return str(MATERIALS[id]["hint"])
	return ""


func material_tag(id: String) -> String:
	return MATERIAL_TAG_PREFIX + str(id)


func all_material_ids() -> Array[String]:
	var out: Array[String] = []
	for id in MATERIALS.keys():
		out.append(str(id))
	return out


# ---------------------------------------------------------------- 描述

## 把武器的数值 + 效果渲染成一句中文说明（界面上直接显示）
func describe(w: Dictionary) -> String:
	if w.is_empty():
		return ""
	var parts: Array[String] = ["伤害 %d" % int(w.get("damage", 0))]
	if w.has("kind"):
		parts.append("攻击间隔 %.2f 秒" % cooldown_for_kind(str(w["kind"])))
	var e: Dictionary = w.get("effects", {})
	if e.has("max_hp"):
		parts.append("生命上限 +%d" % int(e["max_hp"]))
	if e.has("speed"):
		parts.append("移动速度 +%d" % int(e["speed"]))
	if e.has("range"):
		parts.append("攻击距离 +%d" % int(e["range"]))
	if e.has("defense"):
		parts.append("每次受伤 -%d" % int(e["defense"]))
	if e.has("lifesteal"):
		parts.append("吸血 %d%%" % int(round(float(e["lifesteal"]) * 100.0)))
	if e.has("crit"):
		parts.append("暴击率 +%d%%" % int(round(float(e["crit"]) * 100.0)))
	if e.has("affinity"):
		parts.append("好感增长 +%d%%" % int(round(float(e["affinity"]) * 100.0)))
	if e.has("gold_bonus"):
		parts.append("任务金币 +%d%%" % int(round(float(e["gold_bonus"]) * 100.0)))
	if e.has("atk_speed"):
		parts.append("攻击间隔 -%.2f 秒" % float(e["atk_speed"]))
	return "，".join(parts)


## 玩家输入的目标结局里有没有现代元素（有的话要用枪械）
func is_modern_goal(text: String) -> bool:
	var t := text.strip_edges()
	if t == "":
		return false
	for kw in MODERN_KEYWORDS:
		if t.contains(str(kw)):
			return true
	return false


# ---------------------------------------------------------------- 存档

## 运行时现造的武器要跟着存档走，否则读档后「现代结局拿到的那把枪」就没了。
func to_save() -> Dictionary:
	return {"dynamic": _dynamic.duplicate(true)}


func from_save(data: Dictionary) -> void:
	_dynamic.clear()
	var d = data.get("dynamic", {})
	if typeof(d) == TYPE_DICTIONARY:
		for k in d.keys():
			if typeof(d[k]) == TYPE_DICTIONARY:
				_dynamic[str(k)] = (d[k] as Dictionary).duplicate(true)
	changed.emit()

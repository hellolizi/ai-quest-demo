extends Node
## 坏人（敌人）数据表：种族 + 武器。
##
## 坏人分两类：地球人（人类匪帮）与非地球人（奇幻种族）。
## 每个种族给定外观配色、体型、血量、速度、可用武器池。
## 武器沿用 WeaponData 已有的 6 种中世纪类型（长弓算远程），
## 这样「坏人有很多种、武器有很多种」由「8 族 × 6 武器」的组合满足，
## 又不破坏世界观（地点提示词里禁止现代 / 科幻元素）。

## 远程武器：站在距离外放箭，不贴脸
const RANGED_KINDS := ["长弓"]

## 各武器的有效攻击距离（像素）。近战要贴到身边，长弓可以在很远处放箭。
const KIND_RANGE := {
	"匕首": 34.0,
	"长剑": 48.0,
	"长矛": 66.0,
	"斧": 50.0,
	"战锤": 54.0,
	"长弓": 300.0,
}
const DEFAULT_RANGE := 46.0

## 各武器的一次伤害（配合 WeaponData.cooldown_for_kind 的间隔：重武器慢而痛）
const KIND_DAMAGE := {
	"匕首": 6,
	"长剑": 9,
	"长矛": 11,
	"斧": 12,
	"战锤": 14,
	"长弓": 8,
}
const DEFAULT_DAMAGE := 9

## 生成守兵时，抽到「地球人」的概率；其余为非地球种族。
const HUMAN_CHANCE := 0.65

## 8 个种族。body/accent 是程序化绘制的配色，scale 是体型缩放。
## weapons 是该族会用的武器池（只能从上面 6 种里挑）。
const RACES: Dictionary = {
	"bandit": {
		"name": "山贼", "species": "人类", "human": true,
		"desc": "盘踞在商道旁的地痞，见财起意。",
		"body": Color(0.45, 0.32, 0.22), "accent": Color(0.78, 0.26, 0.20),
		"scale": 1.0, "hp": 26, "speed": 96.0,
		"weapons": ["匕首", "长剑", "斧"],
		"tokens": {"skin": "brown", "hair": "black", "hair_style": "short", "clothes": "brown", "build": "normal", "accessory": "none"},
	},
	"mercenary": {
		"name": "佣兵", "species": "人类", "human": true,
		"desc": "拿钱办事的老兵，甲胄比谁都齐整。",
		"body": Color(0.34, 0.36, 0.42), "accent": Color(0.85, 0.72, 0.35),
		"scale": 1.05, "hp": 34, "speed": 92.0,
		"weapons": ["长剑", "长矛", "斧"],
		"tokens": {"skin": "tan", "hair": "brown", "hair_style": "short", "clothes": "gray", "build": "normal", "accessory": "cape"},
	},
	"raider": {
		"name": "掠袭者", "species": "人类", "human": true,
		"desc": "骑着快马四处劫掠的亡命徒。",
		"body": Color(0.40, 0.24, 0.22), "accent": Color(0.90, 0.45, 0.25),
		"scale": 1.0, "hp": 28, "speed": 108.0,
		"weapons": ["匕首", "长矛", "长弓"],
		"tokens": {"skin": "brown", "hair": "black", "hair_style": "ponytail", "clothes": "red", "build": "normal", "accessory": "cape"},
	},
	"scavenger": {
		"name": "拾荒者", "species": "人类", "human": true,
		"desc": "在废墟里翻捡破烂的瘦小身影，被惹急了会拼命。",
		"body": Color(0.42, 0.40, 0.30), "accent": Color(0.65, 0.60, 0.35),
		"scale": 0.92, "hp": 20, "speed": 102.0,
		"weapons": ["匕首", "长剑"],
		"tokens": {"skin": "tan", "hair": "brown", "hair_style": "hat", "clothes": "brown", "build": "slim", "accessory": "pack"},
	},
	"greenskin": {
		"name": "绿皮蛮兵", "species": "兽人", "human": false,
		"desc": "皮肤粗糙发绿的蛮族，块头比人高出一头。",
		"body": Color(0.32, 0.46, 0.24), "accent": Color(0.72, 0.82, 0.30),
		"scale": 1.2, "hp": 40, "speed": 88.0,
		"weapons": ["斧", "战锤", "长矛"],
		"tokens": {"skin": "dark", "hair": "black", "hair_style": "bald", "clothes": "green", "build": "stout", "accessory": "none"},
	},
	"lizard": {
		"name": "蜥鳞游猎", "species": "蜥人", "human": false,
		"desc": "覆盖着鳞片的猎手，动作极快，善用投掷与弓。",
		"body": Color(0.24, 0.42, 0.40), "accent": Color(0.85, 0.80, 0.35),
		"scale": 1.02, "hp": 26, "speed": 116.0,
		"weapons": ["匕首", "长矛", "长弓"],
		"tokens": {"skin": "brown", "hair": "black", "hair_style": "bald", "clothes": "teal", "build": "slim", "accessory": "pack"},
	},
	"golem": {
		"name": "石傀", "species": "构装体", "human": false,
		"desc": "由岩石与古纹拼成的沉默卫士，慢，但极难打碎。",
		"body": Color(0.42, 0.42, 0.45), "accent": Color(0.45, 0.80, 0.85),
		"scale": 1.28, "hp": 58, "speed": 70.0,
		"weapons": ["战锤", "斧"],
		"tokens": {"skin": "pale", "hair": "gray", "hair_style": "bald", "clothes": "gray", "build": "stout", "accessory": "none"},
	},
	"wraith": {
		"name": "虚影", "species": "幽影", "human": false,
		"desc": "半透明的一团怨念，飘忽不定，靠近了才看得真切。",
		"body": Color(0.36, 0.30, 0.50), "accent": Color(0.72, 0.60, 0.95),
		"scale": 1.04, "hp": 22, "speed": 104.0,
		"weapons": ["匕首", "长弓"],
		"tokens": {"skin": "pale", "hair": "white", "hair_style": "long", "clothes": "purple", "build": "slim", "accessory": "cape"},
	},
}

## 每族的「长相」中文描述：喂给生图提示词，让 AI 一眼画出这是哪一路的坏人。
## 人类种族也写出族别与打扮特征，非人类种族重点写肤色 / 体型 / 非人特征。
## 注意：别写手持武器——立绘和走路帧是空手的，武器交给攻击帧表现。
const RACE_LOOK: Dictionary = {
	"bandit": "人类山贼，皮肤黝黑粗糙，粗布短打，头上缠着破旧头巾，腰间系布带，面相凶悍，一副见财起意的凶相",
	"mercenary": "人类佣兵，身披整齐的深色皮甲与金属肩甲，护腕护胫齐全，束发，神情冷峻，是个训练有素的老兵",
	"raider": "人类掠袭者，穿轻便皮衣、外披一件沾尘的短斗篷，头发在脑后束起，身形精悍，一副常年策马劫掠的亡命相",
	"scavenger": "人类拾荒者，瘦小佝偻，裹着补丁摞补丁的破布衣，戴着一顶褪色兜帽，背着一只鼓鼓囊囊的旧布袋",
	"greenskin": "绿皮兽人蛮兵，兽人，皮肤粗糙发绿，嘴里露出獠牙，块头比人高出一头，肩宽背厚，腰围兽皮，形象凶蛮",
	"lizard": "蜥人游猎，浑身覆盖青绿色鳞片，拖着一条长尾，竖瞳，身形精瘦敏捷，腰缠布条，背上斜背着投矛的皮套",
	"golem": "石傀，由灰色岩石与发光古纹拼成的沉默卫士，没有五官只有两条发光的眼缝，身形魁梧笨重，行动迟缓",
	"wraith": "幽影，半透明的淡紫色怨念形体，边缘像烟一样飘散，看不清五官，只有两点幽幽的光，整体飘忽不定",
}


func race_ids() -> Array:
	return RACES.keys()


## 取某个种族的数据；未知 id 回退到山贼
func race(rid: String) -> Dictionary:
	var r = RACES.get(rid, null)
	if typeof(r) == TYPE_DICTIONARY:
		return r
	return RACES["bandit"]


func is_ranged_kind(kind: String) -> bool:
	return RANGED_KINDS.has(kind)


func kind_range(kind: String) -> float:
	return float(KIND_RANGE.get(kind, DEFAULT_RANGE))


func kind_damage(kind: String) -> int:
	return int(KIND_DAMAGE.get(kind, DEFAULT_DAMAGE))


## 出手间隔直接沿用武器表（和玩家用同一套「现实武器节奏」）
func cooldown_for_kind(kind: String) -> float:
	return WeaponData.cooldown_for_kind(kind)


## 随机抽一个守兵的种族 id：多数是地球人，少数是非地球人
func roll_race_id(rng: RandomNumberGenerator) -> String:
	if rng.randf() < HUMAN_CHANCE:
		var humans := ["bandit", "mercenary", "raider", "scavenger"]
		return str(humans[rng.randi() % humans.size()])
	var others := ["greenskin", "lizard", "golem", "wraith"]
	return str(others[rng.randi() % others.size()])


## 造一个守兵：随机种族 + 该族武器池里的一件 + 血量 / 掉落金币
func roll_guard(rng: RandomNumberGenerator) -> Dictionary:
	return build_guard(roll_race_id(rng), rng)


func build_guard(rid: String, rng: RandomNumberGenerator) -> Dictionary:
	var r := race(rid)
	var ws: Array = r.get("weapons", ["长剑"])
	var weapon := str(ws[rng.randi() % ws.size()])
	var hp := maxi(8, int(r.get("hp", 26)) + rng.randi_range(-3, 6))
	return {
		"race": rid,
		"race_name": str(r.get("name", "匪徒")),
		"species": str(r.get("species", "人类")),
		"weapon": weapon,
		"hp": hp,
		"gold": rng.randi_range(6, 22),
	}


# ---------------------------------------------------------------- AI 生图用的派生信息

## 这一族在生图提示词里的长相描述（立绘 / 走路 / 攻击帧共用同一份）
func look_cn(rid: String) -> String:
	return str(RACE_LOOK.get(rid, str(race(rid).get("desc", ""))))


## 这一族稳定的外观 token：用来算 tag，也当程序化兜底
func appearance_for(rid: String) -> Dictionary:
	return CharacterSprite.sanitize_appearance(race(rid).get("tokens", {}))


## 立绘 / 走路 / 攻击帧上写的名字
func display_name(rid: String) -> String:
	return "敌人 " + str(race(rid).get("name", "匪徒"))


## 武器中文名（攻击帧提示词里替换「短剑」；缺省就用短剑）
func weapon_cn(kind: String) -> String:
	return kind if kind != "" else "短剑"

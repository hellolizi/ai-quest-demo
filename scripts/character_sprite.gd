class_name CharacterSprite
extends Node2D
## 程序化小人：把一组「外观 token」画成一个小人，并支持行走 / 待机动画。
##
## 原点在脚底（feet at origin），小人往上方生长（y 为负）。
## 这是「程序化 + AI 立绘」结合方案里离线的那半边：不联网也能有人样，
## 将来若配置了文生图接口，再拿 AI 立绘盖在这上面即可。
##
## 外观 token（全部是小写字符串）：
##   skin      肤色：pale | tan | brown | dark
##   hair      发色：black | brown | blond | gray | white | red
##   hair_style 发型：short | long | bun | bald | ponytail | braid | hat
##   clothes   衣服：red | blue | green | yellow | brown | purple | gray | orange | teal
##   build     体型：slim | normal | stout
##   accessory 配饰：none | scarf | cape | apron | pack

# ---------------------------------------------------------------- 配色 / 参数表

const SKIN_COLORS := {
	"pale": Color(0.97, 0.86, 0.75),
	"tan": Color(0.91, 0.75, 0.58),
	"brown": Color(0.73, 0.54, 0.37),
	"dark": Color(0.47, 0.33, 0.24),
}

const HAIR_COLORS := {
	"black": Color(0.13, 0.12, 0.14),
	"brown": Color(0.37, 0.25, 0.16),
	"blond": Color(0.86, 0.73, 0.38),
	"gray": Color(0.62, 0.62, 0.64),
	"white": Color(0.90, 0.90, 0.92),
	"red": Color(0.72, 0.33, 0.21),
}

const CLOTH_COLORS := {
	"red": Color(0.78, 0.29, 0.27),
	"blue": Color(0.29, 0.46, 0.78),
	"green": Color(0.33, 0.60, 0.39),
	"yellow": Color(0.85, 0.72, 0.27),
	"brown": Color(0.53, 0.39, 0.25),
	"purple": Color(0.56, 0.37, 0.70),
	"gray": Color(0.55, 0.56, 0.60),
	"orange": Color(0.86, 0.53, 0.23),
	"teal": Color(0.25, 0.62, 0.62),
}

const HAIR_STYLES := ["short", "long", "bun", "bald", "ponytail", "braid", "hat"]
const ACCESSORIES := ["none", "scarf", "cape", "apron", "pack"]

## 各文化圈的「长相偏好」：有这一层，同一片地方来的人看上去才像一伙的。
## 每个字段是一份候选池；池子缺项或为空时该字段退回全局池。
## 注意：这里只能用常量与 static，不能在编译期碰 autoload。
const CULTURE_LOOKS := {
	"qingshi": {
		"skin": ["tan", "pale", "brown"], "hair": ["black", "brown", "gray"],
		"hair_style": ["short", "bun", "braid", "hat"], "clothes": ["blue", "teal", "green", "gray"],
		"accessory": ["none", "apron", "pack"], "build": ["normal", "slim", "stout"],
	},
	"anvil": {
		"skin": ["pale", "tan", "brown"], "hair": ["black", "brown", "blond", "gray"],
		"hair_style": ["short", "bald", "ponytail"], "clothes": ["gray", "brown", "red", "orange"],
		"accessory": ["apron", "none", "pack"], "build": ["stout", "normal"],
	},
	"dune": {
		"skin": ["tan", "brown", "dark"], "hair": ["black", "brown"],
		"hair_style": ["hat", "short", "bald"], "clothes": ["yellow", "orange", "brown", "gray"],
		"accessory": ["scarf", "cape", "none"], "build": ["slim", "normal"],
	},
	"isles": {
		"skin": ["tan", "brown", "dark"], "hair": ["black", "brown"],
		"hair_style": ["short", "ponytail", "long", "hat"], "clothes": ["blue", "teal", "gray"],
		"accessory": ["none", "pack", "scarf"], "build": ["slim", "normal"],
	},
	"frost": {
		"skin": ["pale", "tan"], "hair": ["blond", "white", "gray", "red", "black"],
		"hair_style": ["long", "braid", "hat", "short"], "clothes": ["blue", "purple", "gray"],
		"accessory": ["cape", "scarf", "none"], "build": ["stout", "normal"],
	},
	"steppe": {
		"skin": ["tan", "brown"], "hair": ["black", "brown", "red"],
		"hair_style": ["ponytail", "braid", "hat", "short"], "clothes": ["brown", "orange", "red", "yellow"],
		"accessory": ["cape", "scarf", "pack"], "build": ["normal", "stout"],
	},
	"sky": {
		"skin": ["pale", "tan"], "hair": ["white", "blond", "gray"],
		"hair_style": ["long", "bun", "braid", "short"], "clothes": ["purple", "gray", "blue"],
		"accessory": ["cape", "none"], "build": ["slim", "normal"],
	},
	"ember": {
		"skin": ["brown", "dark", "tan"], "hair": ["black", "red", "brown"],
		"hair_style": ["bald", "short", "ponytail"], "clothes": ["red", "orange", "brown", "gray"],
		"accessory": ["apron", "pack", "none"], "build": ["stout", "normal"],
	},
	"grove": {
		"skin": ["tan", "pale", "brown"], "hair": ["brown", "blond", "black", "red"],
		"hair_style": ["long", "braid", "ponytail", "bun"], "clothes": ["green", "brown", "teal", "yellow"],
		"accessory": ["none", "cape", "scarf"], "build": ["slim", "normal"],
	},
	# 通天福地的人「个个绝色」：一律瘦削身段、一身雪白肌肤，挑最惹眼的发色与最艳丽的衣着。
	# 这一池只管好看，不管地域辨识度——福地本就是超脱常理的地方。
	"tianfu": {
		"skin": ["pale"], "hair": ["black", "blond", "white", "red"],
		"hair_style": ["long", "braid", "ponytail", "bun"], "clothes": ["purple", "red", "teal", "yellow"],
		"accessory": ["cape", "scarf", "none"], "build": ["slim"],
	},
}

## 城市档次的「穿着升级」：聚落越大，居民穿得越讲究，但仍在本地的样式之内。
## 只覆盖需要升级的字段，肤色 / 发色沿用该文化圈的偏好，保住「一方水土」的辨识度。
## 升级方向：颜色挑更贵气的（紫 / 青 / 蓝 / 灰），配饰挑更体面的（斗篷 / 围巾），
## 发型挑更利落的（发髻 / 麻花辫），体型避开过胖。
const CITY_LOOKS := {
	"qingshi": {
		"clothes": ["blue", "teal", "purple", "gray"], "hair_style": ["bun", "braid", "short"],
		"accessory": ["scarf", "cape", "none"], "build": ["normal", "slim"],
	},
	"anvil": {
		"clothes": ["gray", "purple", "red", "blue"], "hair_style": ["short", "ponytail", "bun"],
		"accessory": ["cape", "scarf", "none"], "build": ["normal", "stout"],
	},
	"dune": {
		"clothes": ["purple", "teal", "yellow", "blue"], "hair_style": ["hat", "bun", "short"],
		"accessory": ["cape", "scarf"], "build": ["normal", "slim"],
	},
	"isles": {
		"clothes": ["blue", "teal", "purple", "gray"], "hair_style": ["long", "bun", "hat"],
		"accessory": ["cape", "none"], "build": ["normal", "slim"],
	},
	"frost": {
		"clothes": ["blue", "purple", "teal"], "hair_style": ["bun", "braid", "long"],
		"accessory": ["cape", "scarf"], "build": ["normal", "stout"],
	},
	"steppe": {
		"clothes": ["purple", "red", "teal", "orange"], "hair_style": ["braid", "bun", "hat"],
		"accessory": ["cape", "scarf"], "build": ["normal", "stout"],
	},
	"sky": {
		"clothes": ["purple", "blue", "teal", "yellow"], "hair_style": ["long", "bun", "braid"],
		"accessory": ["cape", "none"], "build": ["slim", "normal"],
	},
	"ember": {
		"clothes": ["red", "purple", "orange", "gray"], "hair_style": ["short", "bun", "ponytail"],
		"accessory": ["cape", "none"], "build": ["normal", "stout"],
	},
	"grove": {
		"clothes": ["green", "purple", "teal", "yellow"], "hair_style": ["braid", "bun", "long"],
		"accessory": ["cape", "scarf"], "build": ["slim", "normal"],
	},
}

## 文化圈没有专门的城市版本时，用这套通行的「城里人」升级池。
const CITY_DEFAULT := {
	"clothes": ["purple", "teal", "blue", "gray"],
	"hair_style": ["bun", "braid", "short", "hat"],
	"accessory": ["cape", "scarf", "none"],
	"build": ["normal", "slim"],
}

## 档次的中文补充描述，拼生图提示词用。城里人要多点一句「更讲究」，
## 不然画出来跟村里人一个样。注意别写太夸张，城市也不该穿得花里胡哨。
const TIER_CN := {
	"city": "城市居民，衣着用料与剪裁更讲究体面，配饰精致，但仍是本地的传统样式，不华丽夸张",
}

## 体型：w = 躯干宽度，torso_h = 躯干高度，leg_w = 腿粗
const BUILDS := {
	"slim": {"w": 15.0, "torso_h": 17.0, "leg_w": 4.0},
	"normal": {"w": 19.0, "torso_h": 18.0, "leg_w": 5.0},
	"stout": {"w": 24.0, "torso_h": 19.0, "leg_w": 6.5},
}

const DEFAULT_APPEARANCE := {
	"skin": "tan",
	"hair": "black",
	"hair_style": "short",
	"clothes": "blue",
	"build": "normal",
	"accessory": "none",
}

## 腿长：脚底(0) 到 胯部
const LEG_LEN := 14.0
## 走路一步的时间步进速度
const WALK_SPEED := 9.0
## AI 立绘显示高度（像素）。小人整体约 48px 高，立绘略高一点更醒目。
const PORTRAIT_H := 54.0
## AI 走路帧的显示高度（像素），跟立绘取差不多，切换时不跳
const WALK_H := 54.0
## 走路帧播放速度（帧/秒）。4 帧循环，8 帧/秒看着轻快不抽搐。
const WALK_FPS := 8.0
## AI 攻击帧的显示高度（像素），跟走路帧取一样，切换时不跳
const ATTACK_H := 54.0
## 攻击帧播放速度（帧/秒）。4 帧挥砍一次，12 帧/秒看着利落不拖沓。
const ATTACK_FPS := 12.0

# ---------------------------------------------------------------- 状态

## 当前外观（已 sanitize）
var appearance: Dictionary = DEFAULT_APPEARANCE.duplicate()

var _skin := "tan"
var _hair := "black"
var _hair_style := "short"
var _clothes := "blue"
var _build := "normal"
var _accessory := "none"

var _moving := false
var _facing := 1.0
var _walk_time := 0.0
var _idle_time := 0.0

## AI 立绘（有就顶掉程序化小人）。null 表示还没生成 / 没用上。
var _portrait: Texture2D = null

## AI 走路帧：{方向("down"/"up"/"left"/"right"): Array[Texture2D]}。空表示还没生成。
var _walk: Dictionary = {}
## 当前朝向（4 向）。没有走路帧时，这个只用来决定要不要沿用旧的左右镜像。
var _dir := "down"
## 走路帧播放计时（秒），只在移动时累加
var _anim_time := 0.0

## AI 攻击帧：{方向("down"/"up"/"left"/"right"): Array[Texture2D]}。空表示还没生成。
var _attack: Dictionary = {}
## 正在播攻击动作（播完自动复位）
var _attacking := false
## 攻击动作播放计时（秒），只在播放中累加
var _attack_time := 0.0


# ---------------------------------------------------------------- 立绘

## 贴上一张 AI 立绘。传 null 等于清掉，回退成程序化小人。
func set_portrait(tex: Texture2D) -> void:
	_portrait = tex
	queue_redraw()


func has_portrait() -> bool:
	return _portrait != null


func clear_portrait() -> void:
	set_portrait(null)


# ---------------------------------------------------------------- 走路帧

## 贴上一组 AI 走路帧：{方向: Array[Texture2D]}。传空字典等于清掉，回退成程序化小人。
## 四个朝向都齐了就不再靠节点 scale.x 镜像，把它归位成 1，免得又翻一次。
func set_walk_frames(frames: Dictionary) -> void:
	_walk = frames if frames != null else {}
	if not _walk.is_empty():
		_facing = 1.0
		scale.x = 1.0
	queue_redraw()


func has_walk() -> bool:
	return not _walk.is_empty()


func clear_walk_frames() -> void:
	set_walk_frames({})


## 当前朝向的 4 帧（没有就返回空数组）
func _frames_for_dir() -> Array:
	var arr = _walk.get(_dir, null)
	return arr if arr is Array else []


## 按方向向量更新朝向。有走路帧就切到对应朝向的序列；没有走路帧时沿用旧的左右镜像
## （只在横向移动时翻转，跟以前一样）。
func set_facing_vec(v: Vector2) -> void:
	if is_zero_approx(v.x) and is_zero_approx(v.y):
		return
	_dir = _dir_from_vec(v)
	if _walk.is_empty():
		var s := signf(v.x)
		if not is_zero_approx(s) and s != _facing:
			_facing = s
			scale.x = _facing


## 方向向量 → 四向之一：横向分量更大就算左右，否则按纵向分上下。
static func _dir_from_vec(v: Vector2) -> String:
	if absf(v.x) > absf(v.y):
		return "right" if v.x > 0.0 else "left"
	return "down" if v.y >= 0.0 else "up"


# ---------------------------------------------------------------- 攻击帧

## 贴上一组 AI 攻击帧：{方向: Array[Texture2D]}。传空字典等于清掉，回退成白光弧兜底。
func set_attack_frames(frames: Dictionary) -> void:
	_attack = frames if frames != null else {}
	queue_redraw()


func has_attack() -> bool:
	return not _attack.is_empty()


func clear_attack_frames() -> void:
	set_attack_frames({})


## 某一朝向的攻击 4 帧（没有就返回空数组）
func _frames_for_attack_dir(dir_name: String) -> Array:
	var arr = _attack.get(dir_name, null)
	return arr if arr is Array else []


## 挥击一次：从第 0 帧开始，按当前朝向播一遍攻击序列（传 dir_name 可指定方向）。
## 没有攻击帧时什么都不发生，调用方照旧走白光弧。
func play_attack(dir_name: String = "") -> void:
	if _attack.is_empty():
		return
	var d := dir_name if dir_name != "" else _dir
	if _frames_for_attack_dir(d).is_empty():
		return
	if dir_name != "":
		_dir = dir_name
	_attacking = true
	_attack_time = 0.0
	queue_redraw()


# ---------------------------------------------------------------- 外观

## 设置外观：非法 token 会被换成默认值，不会报错
func set_appearance(data) -> void:
	appearance = sanitize_appearance(data)
	_skin = appearance["skin"]
	_hair = appearance["hair"]
	_hair_style = appearance["hair_style"]
	_clothes = appearance["clothes"]
	_build = appearance["build"]
	_accessory = appearance["accessory"]
	queue_redraw()


func set_moving(m: bool) -> void:
	if m == _moving:
		return
	_moving = m
	if _moving:
		# 每次起步都从第 0 帧（接触帧）开始，循环更自然
		_anim_time = 0.0
	else:
		_walk_time = 0.0
	queue_redraw()


# ---------------------------------------------------------------- 生成 / 校验

## 把任意输入整理成一份「一定合法」的外观
static func sanitize_appearance(raw) -> Dictionary:
	var out := DEFAULT_APPEARANCE.duplicate()
	if typeof(raw) != TYPE_DICTIONARY:
		return out
	for key in out.keys():
		var v := str((raw as Dictionary).get(key, "")).strip_edges().to_lower()
		if v != "" and _token_ok(key, v):
			out[key] = v
	return out


## 在 base 之上叠加 raw 里合法的字段（非法字段忽略）。
## 用于「AI 只给了一半外观字段」的情况：给到的用 AI 的，没给到的沿用 base。
static func merge_appearance(base: Dictionary, raw) -> Dictionary:
	var out := sanitize_appearance(base)
	if typeof(raw) != TYPE_DICTIONARY:
		return out
	for key in out.keys():
		var v := str((raw as Dictionary).get(key, "")).strip_edges().to_lower()
		if v != "" and _token_ok(key, v):
			out[key] = v
	return out


## 由一段文字（一般用 NPC 名字）稳定地推导出一份外观：
## 同一个人每次进游戏都长得一样，不同人之间又各不相同。
## 给了 culture_id 时，各项优先从该文化圈的候选池里挑，于是「一方水土养一方人」。
## 给了 tier（"city"）时，在文化圈偏好之上再叠一层「更讲究」的城市池子。
static func derive_appearance(seed_text: String, culture_id: String = "", tier: String = "") -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(seed_text)
	var look := _look_for(culture_id, tier)
	var out := {
		"skin": _pick_pool(look, "skin", SKIN_COLORS.keys(), rng),
		"hair": _pick_pool(look, "hair", HAIR_COLORS.keys(), rng),
		"hair_style": _pick_pool(look, "hair_style", HAIR_STYLES, rng),
		"clothes": _pick_pool(look, "clothes", CLOTH_COLORS.keys(), rng),
		"build": _pick_pool(look, "build", BUILDS.keys(), rng),
		"accessory": _pick_pool(look, "accessory", ACCESSORIES, rng),
	}
	return out


## 地点类型（location kind）→ 聚落档次 token。城里的居民穿着更高级。
static func tier_for_kind(kind: String) -> String:
	return "city" if kind == "city" else ""


## 档次对应的中文补充描述（没有就返回空串）。
static func tier_cn(tier: String) -> String:
	return str(TIER_CN.get(tier, ""))


## 组合出「这个文化圈 + 这个档次」的候选池：
## 城市档在该文化圈的偏好之上，再叠一层更讲究的池子（只覆盖列出来的字段）。
static func _look_for(culture_id: String, tier: String) -> Dictionary:
	var base: Dictionary = CULTURE_LOOKS.get(culture_id, {})
	if tier != "city":
		return base
	var city: Dictionary = CITY_LOOKS.get(culture_id, CITY_DEFAULT)
	var out := base.duplicate(true)
	for k in city.keys():
		out[k] = city[k]
	return out


## 优先从文化圈候选池挑；池子缺这一项或为空、或挑出来的 token 不合法时，退回全局池。
static func _pick_pool(look: Dictionary, key: String, fallback: Array, rng: RandomNumberGenerator) -> String:
	var pool: Array = look.get(key, [])
	if not pool.is_empty():
		var v := _pick(pool, rng)
		if _token_ok(key, v):
			return v
	return _pick(fallback, rng)


static func _token_ok(key: String, val: String) -> bool:
	match key:
		"skin":
			return SKIN_COLORS.has(val)
		"hair":
			return HAIR_COLORS.has(val)
		"hair_style":
			return HAIR_STYLES.has(val)
		"clothes":
			return CLOTH_COLORS.has(val)
		"build":
			return BUILDS.has(val)
		"accessory":
			return ACCESSORIES.has(val)
	return false


static func _pick(pool: Array, rng: RandomNumberGenerator) -> String:
	if pool.is_empty():
		return ""
	return str(pool[rng.randi_range(0, pool.size() - 1)])


# ---------------------------------------------------------------- 中文描述

## token -> 中文描述，用来拼 AI 生图的提示词。
## 注意：这里的用词是给「画画的人」看的，别写太抽象的词。
const TOKEN_CN := {
	"skin": {
		"pale": "白皙肤色", "tan": "小麦色皮肤", "brown": "棕色皮肤", "dark": "深棕色皮肤",
	},
	"hair": {
		"black": "黑发", "brown": "棕发", "blond": "金发",
		"gray": "灰白发", "white": "银白发", "red": "红发",
	},
	"hair_style": {
		"short": "短发", "long": "披肩长发", "bun": "发髻", "bald": "光头",
		"ponytail": "马尾辫", "braid": "麻花辫", "hat": "戴着斗笠",
	},
	"clothes": {
		"red": "红色衣服", "blue": "蓝色衣服", "green": "绿色衣服", "yellow": "黄色衣服",
		"brown": "棕褐色衣服", "purple": "紫色衣服", "gray": "灰色衣服",
		"orange": "橙色衣服", "teal": "青色衣服",
	},
	"build": {
		"slim": "身材瘦削", "normal": "身材匀称", "stout": "体态丰满",
	},
	"accessory": {
		"none": "", "scarf": "系着围巾", "cape": "披着斗篷",
		"apron": "系着围裙", "pack": "背着行囊",
	},
}

## 把一份外观描述成一句中文，供生图提示词拼接。空字段会被跳过。
static func describe_cn(raw) -> String:
	var app := sanitize_appearance(raw)
	var parts: Array[String] = []
	for key in ["skin", "hair", "hair_style", "build", "clothes", "accessory"]:
		var table: Dictionary = TOKEN_CN.get(key, {})
		var text: String = str(table.get(app.get(key, ""), ""))
		if text != "":
			parts.append(text)
	return "，".join(parts)


# ---------------------------------------------------------------- 动画驱动

func _process(delta: float) -> void:
	if _moving:
		_walk_time = fmod(_walk_time + delta * WALK_SPEED, TAU)
		if not _walk.is_empty():
			_anim_time += delta
	if _attacking:
		_attack_time += delta
		var n := _frames_for_attack_dir(_dir).size()
		if n > 0 and int(_attack_time * ATTACK_FPS) >= n:
			_attacking = false
			_attack_time = 0.0
	_idle_time += delta
	queue_redraw()


# ---------------------------------------------------------------- 绘制

func _draw() -> void:
	var build: Dictionary = BUILDS.get(_build, BUILDS["normal"])
	var w: float = build["w"]
	var torso_h: float = build["torso_h"]
	var leg_w: float = build["leg_w"]

	var skin: Color = SKIN_COLORS[_skin]
	var hair: Color = HAIR_COLORS[_hair]
	var cloth: Color = CLOTH_COLORS[_clothes]
	var eye := Color(0.12, 0.10, 0.10)

	var swing := 0.0
	var bob := 0.0
	if _moving:
		swing = sin(_walk_time)
		bob = -abs(sin(_walk_time)) * 1.6
	else:
		bob = sin(_idle_time * 2.2) * 0.6

	var tb := -LEG_LEN + bob          # 躯干底（胯）
	var tt := tb - torso_h            # 躯干顶（肩）
	var r: float = w * 0.42           # 头半径
	var head := Vector2(0.0, tt - r - 1.0)

	_draw_shadow(w)

	# 挥击就一瞬间：正在播攻击动作就优先画攻击帧，压过走路 / 立绘
	if _attacking and _draw_attack():
		return
	# 有 AI 走路帧：走起来就播当前朝向的序列帧（影子留着，脚感更实）
	if _moving and not _walk.is_empty() and _draw_walk():
		return
	# 有 AI 立绘就直接贴立绘，程序化小人整个让位
	if _portrait != null:
		_draw_portrait(bob, swing)
		return
	# 没立绘但有走路帧：静止也画第 0 帧兜底
	if not _walk.is_empty() and _draw_walk():
		return

	# 披风 / 背包这类在身后的配饰先画
	if _accessory == "cape":
		draw_colored_polygon(PackedVector2Array([
			Vector2(-w * 0.5, tt), Vector2(w * 0.5, tt),
			Vector2(w * 0.62, tb + 6.0), Vector2(-w * 0.62, tb + 6.0),
		]), cloth.darkened(0.22))
	if _accessory == "pack":
		draw_rect(Rect2(Vector2(w * 0.28, tt + 3.0), Vector2(w * 0.38, torso_h * 0.8)), cloth.darkened(0.35))

	# 腿：左右交替前后摆
	var hip_y := tb - 2.0
	_draw_leg(-w * 0.22 + swing * 3.5, hip_y, leg_w, skin)
	_draw_leg(w * 0.22 - swing * 3.5, hip_y, leg_w, skin)

	# 躯干：上宽下窄的梯形，比纯方块有肩膀
	draw_colored_polygon(PackedVector2Array([
		Vector2(-w * 0.45, tb + 1.0), Vector2(w * 0.45, tb + 1.0),
		Vector2(w * 0.5, tt), Vector2(-w * 0.5, tt),
	]), cloth)

	# 围裙 / 围巾这类贴身的配饰
	if _accessory == "apron":
		draw_colored_polygon(PackedVector2Array([
			Vector2(-w * 0.28, tb - 2.0), Vector2(w * 0.28, tb - 2.0),
			Vector2(w * 0.22, tt + torso_h * 0.45), Vector2(-w * 0.22, tt + torso_h * 0.45),
		]), Color(0.92, 0.90, 0.84))
	var neck_y := tt + 1.0
	if _accessory == "scarf":
		draw_rect(Rect2(Vector2(-w * 0.34, neck_y - 1.0), Vector2(w * 0.68, 4.0)), CLOTH_COLORS["red"])

	# 手臂：与腿反相摆动
	var arm_swing := -swing * 3.0
	var arm_len := torso_h * 0.85
	draw_line(Vector2(-w * 0.48, tt + 2.0), Vector2(-w * 0.52 + arm_swing, tt + arm_len), skin, leg_w * 0.8, true)
	draw_line(Vector2(w * 0.48, tt + 2.0), Vector2(w * 0.52 - arm_swing, tt + arm_len), skin, leg_w * 0.8, true)

	# 头 + 五官 + 头发
	draw_circle(head, r, skin)
	draw_circle(head + Vector2(-r * 0.34, -r * 0.02), 1.1, eye)
	draw_circle(head + Vector2(r * 0.34, -r * 0.02), 1.1, eye)
	_draw_hair(head, r, hair, cloth)


func _draw_shadow(w: float) -> void:
	draw_set_transform(Vector2(0.0, 0.0), 0.0, Vector2(1.0, 0.36))
	draw_circle(Vector2.ZERO, w * 0.72, Color(0.0, 0.0, 0.0, 0.16))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## 把立绘等比缩到 PORTRAIT_H 高，底边贴着脚底原点。
## 走动时上下颠一下 + 轻轻侧倾，静止时缓口气，立绘就有「在走路」的感觉了。
## 左右翻转由节点自己的 scale.x 负责，这里不做镜像。
func _draw_portrait(bob: float, swing: float) -> void:
	var sz := _portrait.get_size()
	if sz.x <= 0.0 or sz.y <= 0.0:
		return
	var k := PORTRAIT_H / sz.y
	var draw_size := Vector2(sz.x * k, PORTRAIT_H)
	var tilt: float = swing * 0.035 if _moving else sin(_idle_time * 1.6) * 0.012
	draw_set_transform(Vector2(0.0, bob), tilt, Vector2.ONE)
	draw_texture_rect(_portrait, Rect2(Vector2(-draw_size.x * 0.5, -draw_size.y), draw_size), false)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## 画当前朝向的走路帧：移动时按时间循环播放，静止时画第 0 帧（站姿）。
## 返回 false 表示当前朝向没有可用帧，调用方继续走立绘 / 程序化兜底。
## 左右镜像交给帧数据自己（right 由 left 翻转而来），这里不再动 scale。
func _draw_walk() -> bool:
	var frames := _frames_for_dir()
	if frames.is_empty():
		return false
	var tex: Texture2D = frames[0]
	if _moving:
		var idx := int(_anim_time * WALK_FPS) % frames.size()
		tex = frames[idx]
	if tex == null:
		return false
	var sz := tex.get_size()
	if sz.x <= 0.0 or sz.y <= 0.0:
		return false
	var k := WALK_H / sz.y
	var ds := Vector2(sz.x * k, WALK_H)
	draw_texture_rect(tex, Rect2(Vector2(-ds.x * 0.5, -ds.y), ds), false)
	return true


## 画当前朝向的攻击帧：按时间推帧（不循环，播完停在最后一帧由 _process 复位）。
## 返回 false 表示当前朝向没有可用帧，调用方继续走下面的兜底。
func _draw_attack() -> bool:
	var frames := _frames_for_attack_dir(_dir)
	if frames.is_empty():
		return false
	var idx := int(_attack_time * ATTACK_FPS)
	if idx >= frames.size():
		idx = frames.size() - 1
	var tex: Texture2D = frames[idx]
	if tex == null:
		return false
	var sz := tex.get_size()
	if sz.x <= 0.0 or sz.y <= 0.0:
		return false
	var k := ATTACK_H / sz.y
	var ds := Vector2(sz.x * k, ATTACK_H)
	draw_texture_rect(tex, Rect2(Vector2(-ds.x * 0.5, -ds.y), ds), false)
	return true


func _draw_leg(x: float, hip_y: float, leg_w: float, skin: Color) -> void:
	var foot := Vector2(x, 0.0)
	draw_line(Vector2(x, hip_y), foot, skin.darkened(0.12), leg_w, true)
	# 鞋子：脚下一个小小的横向色块，让人看得出是脚
	draw_rect(Rect2(Vector2(x - leg_w * 0.9, -2.6), Vector2(leg_w * 1.8, 2.6)), Color(0.28, 0.22, 0.18))


func _draw_hair(head: Vector2, r: float, hair: Color, cloth: Color) -> void:
	match _hair_style:
		"bald":
			# 光头：只在耳侧留两撮，避免完全没头发显得太秃
			draw_circle(head + Vector2(-r * 0.95, r * 0.15), r * 0.28, hair)
			draw_circle(head + Vector2(r * 0.95, r * 0.15), r * 0.28, hair)
			return
		"hat":
			# 斗笠：一个大梯形帽檐
			draw_colored_polygon(PackedVector2Array([
				Vector2(-r * 1.5, head.y - r * 0.35), Vector2(r * 1.5, head.y - r * 0.35),
				Vector2(r * 0.55, head.y - r * 1.25), Vector2(-r * 0.55, head.y - r * 1.25),
			]), cloth.darkened(0.15))
			draw_rect(Rect2(Vector2(-r * 1.5, head.y - r * 0.5), Vector2(r * 3.0, r * 0.22)), cloth.darkened(0.3))
			return

	# 其余发型都先盖一顶「头发帽」
	draw_circle(head + Vector2(0.0, -r * 0.22), r * 1.04, hair)
	draw_circle(head + Vector2(0.0, r * 0.34), r * 0.92, SKIN_COLORS[_skin])

	match _hair_style:
		"long":
			draw_rect(Rect2(Vector2(-r * 1.05, head.y), Vector2(r * 0.5, r * 2.4)), hair)
			draw_rect(Rect2(Vector2(r * 0.55, head.y), Vector2(r * 0.5, r * 2.4)), hair)
		"bun":
			draw_circle(head + Vector2(0.0, -r * 1.15), r * 0.42, hair)
		"ponytail":
			draw_rect(Rect2(Vector2(r * 0.8, head.y - r * 0.2), Vector2(r * 0.34, r * 2.0)), hair)
		"braid":
			draw_circle(head + Vector2(r * 0.95, head.y + r * 0.4), r * 0.26, hair)
			draw_circle(head + Vector2(r * 0.95, head.y + r * 0.95), r * 0.24, hair)
			draw_circle(head + Vector2(r * 0.95, head.y + r * 1.45), r * 0.22, hair)

extends Node
## 道具资产库（Autoload 名字：PropLibrary）
## 这里登记「世界里能摆出来的东西」。AI 布景时只能从这份清单里挑。
##
## 想换成自己的美术资源，只要把图片按 id 命名丢进 res://assets/props/ 就行：
##     res://assets/props/pine.png   →  自动替换掉 pine 现在用的占位图形
## 图片缺失时用代码画的占位图形顶上，所以没有美术也能先跑通。
##
## size 是该道具的「视觉外框」像素尺寸，用来缩放贴图、生成碰撞体。

const TEXTURE_DIR := "res://assets/props"

## 一条道具：id（也是贴图文件名）、名字、分类、外框尺寸、占位画法、是否阻挡玩家
const PROPS: Array[Dictionary] = [
	# 植被
	{"id": "pine", "name": "松树", "category": "植被", "size": Vector2(72, 110), "shape": "tree", "solid": true},
	{"id": "bush", "name": "灌木", "category": "植被", "size": Vector2(64, 48), "shape": "bush", "solid": false},
	{"id": "grass", "name": "草丛", "category": "植被", "size": Vector2(56, 40), "shape": "grass", "solid": false},
	# 山石矿物
	{"id": "boulder", "name": "巨石", "category": "山石", "size": Vector2(88, 64), "shape": "rock", "solid": true},
	{"id": "ore", "name": "矿石堆", "category": "山石", "size": Vector2(56, 46), "shape": "ore", "solid": false},
	# 建筑
	{"id": "house", "name": "木屋", "category": "建筑", "size": Vector2(120, 96), "shape": "house", "solid": true},
	{"id": "well", "name": "水井", "category": "建筑", "size": Vector2(76, 78), "shape": "well", "solid": true},
	{"id": "fence", "name": "木栅栏", "category": "建筑", "size": Vector2(120, 60), "shape": "fence", "solid": true},
	{"id": "signpost", "name": "木牌", "category": "建筑", "size": Vector2(60, 100), "shape": "signpost", "solid": true},
	# 器物
	{"id": "barrel", "name": "木桶", "category": "器物", "size": Vector2(46, 56), "shape": "barrel", "solid": true},
	{"id": "crate", "name": "木箱", "category": "器物", "size": Vector2(54, 52), "shape": "crate", "solid": true},
	{"id": "campfire", "name": "营火", "category": "器物", "size": Vector2(64, 48), "shape": "fire", "solid": false},
	# 水边
	{"id": "boat", "name": "小船", "category": "水边", "size": Vector2(150, 60), "shape": "boat", "solid": true},
]

# ---------------------------------------------------------------- 建筑图鉴
## 房屋按「档次 × 文化圈 × 变体」编号，id 形如 house_<文化圈>_<变体>（村庄民居）
## 或 city_<文化圈>_<变体>（城市楼房），例如 house_qingshi_a / city_qingshi_a。
## 每个文化圈每档有 3 个变体（a/b/c），同一个村子的房子才不会千篇一律。
## 城市楼房比村庄民居更高大气派，尺寸也更大一圈（见 CITY_BUILDING_SIZE）。
## AI 画好的房屋图缓存在 res://generated/buildings/ 下（就在项目文件夹里），重启游戏仍在；
## 没有图就用代码画的占位房子顶上。

## 建筑图鉴的落盘目录与索引
const BUILDING_DIR := "res://generated/buildings"
const BUILDING_INDEX := "res://generated/buildings/index.json"
## 建筑合成 id 的前缀：村庄民居用 house_，城市楼房用 city_
const VILLAGE_PREFIX := "house_"
const CITY_PREFIX := "city_"
## 每个文化圈的房屋变体
const BUILDING_VARIANTS: Array[String] = ["a", "b", "c"]
## 建筑贴图的「视觉外框」尺寸：城市楼房更高大一圈
const BUILDING_SIZE := Vector2(140, 118)
const CITY_BUILDING_SIZE := Vector2(176, 156)

## 通天福地仙宫主殿的专属建筑 id。福地不在常规文化圈里，不参与 building_ids() 的
## 遍历（那里固定是 9 文化圈 × 3 变体 × 2 档 = 54 个 id），单独用这一个固定 id 生成 / 贴图。
const TIANFU_PALACE_ID := "house_tianfu_a"

# ---------------------------------------------------------------- 功能建筑图鉴
## 功能性建筑（锻造台 / 商铺 / 客栈 / 藏书阁 / 拍卖行 / 告示板 / 药铺 / 马厩 / 赌坊）
## 的 AI 贴图，id 形如 facility_<文化圈>_<种类>_<档次>，例如
## facility_qingshi_forge_village / facility_qingshi_arena_city。
## 它和民居不是同一套编号，**不进 building_ids()**（那里固定 9 文化圈 × 3 变体 × 2 档 = 54），
## 但贴图同样落在 BUILDING_DIR，共用同一份索引与内存缓存，画法（抠绿幕、缩放）也一致。
const FACILITY_PREFIX := "facility_"

## 9 种功能性建筑：与 world_map.FACILITY_NAMES 的键、scripts/facility.gd 的 kind 一一对应
const FACILITY_KINDS: Array[String] = [
	"forge", "shop", "inn", "library", "auction", "board", "clinic", "stable", "arena",
]

## 功能建筑种类的中文名（只用于图鉴索引里记个人名；界面显示仍走 world_map 的命名表）
const FACILITY_KIND_NAMES := {
	"forge": "锻造台", "shop": "商铺", "inn": "客栈",
	"library": "藏书阁", "auction": "拍卖行",
	"board": "告示板", "clinic": "药铺", "stable": "马厩", "arena": "赌坊",
}

## 功能建筑贴图的「视觉外框」尺寸：村里的小巧些，城里的更大一圈
const FACILITY_VILLAGE_SIZE := Vector2(112, 104)
const FACILITY_CITY_SIZE := Vector2(150, 132)

## 建筑图鉴有变化（新画好一张 / 删掉一张）时发出，地图据此换图。
signal buildings_changed

## id -> {culture, variant, name, created_at}
var _buildings: Dictionary = {}
## id -> Texture2D（内存缓存，免得每次进游戏都重新读盘）
var _building_textures: Dictionary = {}

# ---------------------------------------------------------------- 植被（树）图鉴
## 大地图上散落的树：以前是纯代码画的色块，现在可以用 AI 画的贴图顶上，
## id 形如 tree_<文化圈>_<变体>，例如 tree_qingshi_a。
## 贴图落在 TREE_DIR（和建筑分开放，方便单独重画），不参与建筑图鉴的编号。

const TREE_DIR := "res://generated/trees"
const TREE_PREFIX := "tree_"
## 每个文化圈的树变体：a = 针叶高树，b = 阔叶大树，c = 矮树丛
const TREE_VARIANTS: Array[String] = ["a", "b", "c"]
## 每种变体贴图的「视觉外框」尺寸（摆到地图上时按它等比缩放）
const TREE_SIZES := {
	"a": Vector2(78, 122),
	"b": Vector2(98, 112),
	"c": Vector2(70, 78),
}

## 树贴图有变化时发出（目前只有离线批量生图会用到）
signal trees_changed

## id -> Texture2D（内存缓存）
var _tree_textures: Dictionary = {}


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(BUILDING_DIR)
	DirAccess.make_dir_recursive_absolute(TREE_DIR)
	_load_building_index()


# ---------------------------------------------------------------- 建筑：id 解析

## 某一档（village / city）建筑 id 的前缀
static func tier_prefix(tier: String) -> String:
	return CITY_PREFIX if tier == "city" else VILLAGE_PREFIX


## 这一档建筑贴图的视觉外框尺寸（城市楼房更高大）
static func building_size_of(tier: String) -> Vector2:
	return CITY_BUILDING_SIZE if tier == "city" else BUILDING_SIZE


## 由文化圈 + 变体（+ 档次）合成建筑 id：
##   ("qingshi", "a")          -> "house_qingshi_a"（村庄民居）
##   ("qingshi", "a", "city")  -> "city_qingshi_a"（城市楼房）
static func building_id(cid: String, variant: String, tier: String = "village") -> String:
	return "%s%s_%s" % [tier_prefix(tier), cid, variant]


## 这个 id 是不是「建筑图鉴」里的房子（村庄民居或城市楼房都算）
static func is_building_id(id: String) -> bool:
	if not id.begins_with(VILLAGE_PREFIX) and not id.begins_with(CITY_PREFIX):
		return false
	var parsed := parse_building_id(id)
	return parsed["culture"] != "" and parsed["variant"] != ""


## 拆建筑 id：
##   "house_qingshi_a" -> {"culture": "qingshi", "variant": "a", "tier": "village"}
##   "city_qingshi_a"  -> {"culture": "qingshi", "variant": "a", "tier": "city"}
static func parse_building_id(id: String) -> Dictionary:
	var tier := "village"
	var body := ""
	if id.begins_with(CITY_PREFIX):
		tier = "city"
		body = id.substr(CITY_PREFIX.length())
	elif id.begins_with(VILLAGE_PREFIX):
		body = id.substr(VILLAGE_PREFIX.length())
	else:
		return {"culture": "", "variant": "", "tier": tier}
	var cut := body.rfind("_")
	if cut <= 0:
		return {"culture": "", "variant": "", "tier": tier}
	return {"culture": body.substr(0, cut), "variant": body.substr(cut + 1), "tier": tier}


## 某个文化圈在某一档的全部房屋变体 id
static func building_ids_of(cid: String, tier: String = "village") -> PackedStringArray:
	var out := PackedStringArray()
	for v in BUILDING_VARIANTS:
		out.append(building_id(cid, v, tier))
	return out


## 由坐标稳定地挑一个变体：同一个位置每次都是同一栋房
static func variant_at(pos: Vector2) -> String:
	var key := "%d_%d" % [roundi(pos.x), roundi(pos.y)]
	return BUILDING_VARIANTS[absi(hash(key)) % BUILDING_VARIANTS.size()]


# ---------------------------------------------------------------- 植被（树）：id 解析

## 由文化圈 + 变体合成树 id：("qingshi", "a") -> "tree_qingshi_a"
static func tree_id(cid: String, variant: String) -> String:
	return "%s%s_%s" % [TREE_PREFIX, cid, variant]


## 这个 id 是不是一张树贴图
static func is_tree_id(id: String) -> bool:
	if not id.begins_with(TREE_PREFIX):
		return false
	var parsed := parse_tree_id(id)
	return parsed["culture"] != "" and parsed["variant"] != ""


## 拆树 id："tree_qingshi_a" -> {"culture": "qingshi", "variant": "a"}
static func parse_tree_id(id: String) -> Dictionary:
	if not id.begins_with(TREE_PREFIX):
		return {"culture": "", "variant": ""}
	var body := id.substr(TREE_PREFIX.length())
	var cut := body.rfind("_")
	if cut <= 0:
		return {"culture": "", "variant": ""}
	return {"culture": body.substr(0, cut), "variant": body.substr(cut + 1)}


## 某种变体贴图的视觉外框尺寸
static func tree_size_of(variant: String) -> Vector2:
	return TREE_SIZES.get(variant, Vector2(84, 110))


## 由坐标稳定地挑一个树变体：同一个位置每次都是同一种树
static func tree_variant_at(pos: Vector2) -> String:
	var key := "%d_%d" % [roundi(pos.x), roundi(pos.y)]
	return TREE_VARIANTS[absi(hash(key + "_tree")) % TREE_VARIANTS.size()]


## 某个文化圈的全部树变体 id
static func tree_ids_of(cid: String) -> PackedStringArray:
	var out := PackedStringArray()
	for v in TREE_VARIANTS:
		out.append(tree_id(cid, v))
	return out


## 房屋规格：大 / 中 / 小三种体量。大房子占地大、室内也大；高房子带二层。
const HOUSE_SPECS := {
	"small": {"label": "小屋", "scale": 0.80, "room": Vector2(360, 300)},
	"medium": {"label": "民居", "scale": 1.00, "room": Vector2(520, 420)},
	"large": {"label": "大宅", "scale": 1.28, "room": Vector2(720, 560)},
}


## 由坐标确定性地抽一份房屋规格：同一栋房每次进游戏都一样。
## tier = "city" 时城市楼房一律至少两层，且不出现「小屋」这一档（城市没有太寒酸的房子）。
## 返回 {size_class, label, scale, room, floors, tall}：
##   size_class：small / medium / large（决定室外体量与室内面积）
##   room：室内房间的像素尺寸（大房子室内更大）
##   floors：1 或 2；tall 为 true 时二层可上楼（矮房子一律只有一层）
static func house_spec(pos: Vector2, tier: String = "village") -> Dictionary:
	var key := "%d_%d" % [roundi(pos.x), roundi(pos.y)]
	var h := absi(hash(key + "_spec"))
	var rs := h % 100
	var cls := "small"
	if rs >= 80:
		cls = "large"
	elif rs >= 40:
		cls = "medium"
	if tier == "city" and cls == "small":
		cls = "medium"
	var rt := (h / 100) % 100
	var tall := false
	match cls:
		"large":
			tall = rt < 75
		"medium":
			tall = rt < 40
		_:
			tall = false
	if tier == "city":
		tall = true
	var base: Dictionary = HOUSE_SPECS[cls]
	var sc := float(base["scale"]) * (1.12 if tall else 1.0)
	return {
		"size_class": cls,
		"label": str(base["label"]),
		"scale": sc,
		"room": base["room"],
		"floors": 2 if tall else 1,
		"tall": tall,
	}


## 全部文化圈、全部档次的房屋变体 id（村庄民居 + 城市楼房）
func building_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for cid in CultureData.all_ids():
		out.append_array(building_ids_of(str(cid), "village"))
		out.append_array(building_ids_of(str(cid), "city"))
	return out


## 某个文化圈某一档的变体列表（供 UI / 校验用）
func building_variants_of(cid: String, tier: String = "village") -> PackedStringArray:
	return building_ids_of(cid, tier)


func variant_of_id(id: String) -> String:
	return str(parse_building_id(id).get("variant", ""))


func culture_of_building(id: String) -> String:
	return str(parse_building_id(id).get("culture", ""))


## 这栋房是哪一档：village（村庄民居）/ city（城市楼房）
func tier_of_building(id: String) -> String:
	return str(parse_building_id(id).get("tier", "village"))


func _building_name(cid: String, variant: String, tier: String = "village") -> String:
	if cid == "tianfu":
		return "通天福地仙宫"
	var base := CultureData.culture_name_of(cid)
	if base == "":
		base = cid
	if tier == "city":
		return "%s城宅%s" % [base, variant.to_upper()]
	return "%s民居%s" % [base, variant.to_upper()]


# ---------------------------------------------------------------- 功能建筑：id 解析

## 功能建筑贴图的视觉外框尺寸（城里的更大一圈）
static func facility_size_of(tier: String) -> Vector2:
	return FACILITY_CITY_SIZE if tier == "city" else FACILITY_VILLAGE_SIZE


## 由文化圈 + 种类（+ 档次）合成功能建筑 id：
##   ("qingshi", "forge")         -> "facility_qingshi_forge_village"
##   ("qingshi", "arena", "city") -> "facility_qingshi_arena_city"
static func facility_id(cid: String, kind: String, tier: String = "village") -> String:
	return "%s%s_%s_%s" % [FACILITY_PREFIX, cid, kind, tier]


## 这个 id 是不是「功能建筑图鉴」里的设施
static func is_facility_id(id: String) -> bool:
	if not id.begins_with(FACILITY_PREFIX):
		return false
	var parsed := parse_facility_id(id)
	return parsed["culture"] != "" and parsed["kind"] != ""


## 拆功能建筑 id：
##   "facility_qingshi_forge_village" -> {"culture": "qingshi", "kind": "forge", "tier": "village"}
##   "facility_qingshi_arena_city"    -> {"culture": "qingshi", "kind": "arena", "tier": "city"}
## 解析失败返回三个空串。
static func parse_facility_id(id: String) -> Dictionary:
	var empty := {"culture": "", "kind": "", "tier": ""}
	if not id.begins_with(FACILITY_PREFIX):
		return empty
	var body := id.substr(FACILITY_PREFIX.length())
	var cut := body.rfind("_")
	if cut <= 0:
		return empty
	var tier := body.substr(cut + 1)
	if tier != "village" and tier != "city":
		return empty
	body = body.substr(0, cut)
	cut = body.rfind("_")
	if cut <= 0:
		return empty
	var kind := body.substr(cut + 1)
	if not FACILITY_KINDS.has(kind):
		return empty
	return {"culture": body.substr(0, cut), "kind": kind, "tier": tier}


## 某个文化圈某一档的全部功能建筑 id
static func facility_ids_of(cid: String, tier: String = "village") -> PackedStringArray:
	var out := PackedStringArray()
	for kind in FACILITY_KINDS:
		out.append(facility_id(cid, kind, tier))
	return out


## 全部文化圈 × 9 种 × 2 档的功能建筑 id（9 × 9 × 2 = 162）
func facility_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for cid in CultureData.all_ids():
		out.append_array(facility_ids_of(str(cid), "village"))
		out.append_array(facility_ids_of(str(cid), "city"))
	return out


func _facility_name(cid: String, kind: String, tier: String = "village") -> String:
	var base := CultureData.culture_name_of(cid)
	if base == "":
		base = cid
	var label := str(FACILITY_KIND_NAMES.get(kind, kind))
	return "%s%s%s" % [base, label, "（城）" if tier == "city" else ""]


# ---------------------------------------------------------------- 建筑：落盘

func building_texture_path(id: String) -> String:
	return "%s/%s.png" % [BUILDING_DIR, id]


func has_building_texture(id: String) -> bool:
	if _building_textures.has(id):
		return true
	var path := building_texture_path(id)
	return FileAccess.file_exists(path)


func building_texture(id: String) -> Texture2D:
	if _building_textures.has(id):
		return _building_textures[id]
	var path := building_texture_path(id)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.new()
	if img.load(path) != OK:
		return null
	var tex := ImageTexture.create_from_image(img)
	_building_textures[id] = tex
	return tex


## 功能建筑贴图：与民居共用同一份落盘目录 / 索引 / 内存缓存，只是 id 前缀不同
func has_facility_texture(id: String) -> bool:
	return has_building_texture(id)


func facility_texture(id: String) -> Texture2D:
	return building_texture(id)


## 把 AI 画好的房屋 / 功能建筑图登记进图鉴（image 为空表示只登记索引）
func register_building(id: String, image: Image, meta: Dictionary = {}) -> bool:
	var facility := is_facility_id(id)
	if not facility and not is_building_id(id):
		return false
	var info := parse_facility_id(id) if facility else parse_building_id(id)
	var dir := DirAccess.open(BUILDING_DIR)
	if dir == null:
		return false
	if image != null:
		if image.save_png(building_texture_path(id)) != OK:
			return false
		_building_textures.erase(id)
	var entry := {
		"culture": info["culture"],
		"variant": str(info.get("variant", "")),
		"tier": info["tier"],
		"name": (_facility_name(str(info["culture"]), str(info["kind"]), str(info["tier"]))
			if facility
			else _building_name(str(info["culture"]), str(info["variant"]), str(info["tier"]))),
		"created_at": Time.get_datetime_string_from_system(),
	}
	if facility:
		entry["kind"] = info["kind"]
		entry["facility"] = true
	for k in meta.keys():
		entry[k] = meta[k]
	_buildings[id] = entry
	_save_building_index()
	buildings_changed.emit()
	return true


func all_building_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for id in _buildings.keys():
		out.append(str(id))
	return out


func _load_building_index() -> void:
	_buildings.clear()
	if FileAccess.file_exists(BUILDING_INDEX):
		var f := FileAccess.open(BUILDING_INDEX, FileAccess.READ)
		if f != null:
			var txt := f.get_as_text()
			f.close()
			var parsed = JSON.parse_string(txt)
			if parsed is Dictionary:
				_buildings = parsed


func _save_building_index() -> void:
	var f := FileAccess.open(BUILDING_INDEX, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(_buildings, "\t"))
	f.close()


# ---------------------------------------------------------------- 植被（树）：落盘

## 全部文化圈 × 全部变体的树 id（9 × 3 = 27）
func tree_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for cid in CultureData.all_ids():
		for v in TREE_VARIANTS:
			out.append(tree_id(cid, v))
	return out


func tree_texture_path(cid: String, variant: String) -> String:
	return "%s/%s.png" % [TREE_DIR, tree_id(cid, variant)]


## 这个文化圈的这个变体有没有贴图
func has_tree_texture_of(cid: String, variant: String) -> bool:
	var id := tree_id(cid, variant)
	if _tree_textures.has(id):
		return true
	return FileAccess.file_exists(tree_texture_path(cid, variant))


## 完整树 id（tree_xxx_y）有没有贴图
func has_tree_texture(id: String) -> bool:
	if not is_tree_id(id):
		return false
	var p := parse_tree_id(id)
	return has_tree_texture_of(str(p["culture"]), str(p["variant"]))


## 取树贴图；没有就返回 null（调用方退回程序化画的树）
func tree_texture(cid: String, variant: String) -> Texture2D:
	var id := tree_id(cid, variant)
	if _tree_textures.has(id):
		return _tree_textures[id]
	var path := tree_texture_path(cid, variant)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.new()
	if img.load(path) != OK:
		return null
	var tex := ImageTexture.create_from_image(img)
	_tree_textures[id] = tex
	return tex


## 把 AI 画好的树贴图登记入库
func register_tree(id: String, image: Image, _meta: Dictionary = {}) -> bool:
	if not is_tree_id(id):
		return false
	var p := parse_tree_id(id)
	DirAccess.make_dir_recursive_absolute(TREE_DIR)
	if image != null:
		if image.save_png(tree_texture_path(str(p["culture"]), str(p["variant"]))) != OK:
			return false
		_tree_textures.erase(id)
	trees_changed.emit()
	return true


func all() -> Array[Dictionary]:
	return PROPS


func by_id(id: String) -> Dictionary:
	for p in PROPS:
		if str(p["id"]) == id:
			return p
	if is_facility_id(id):
		var finfo := parse_facility_id(id)
		var fcid := str(finfo["culture"])
		var kind := str(finfo["kind"])
		var ftier := str(finfo["tier"])
		return {
			"id": id,
			"name": _facility_name(fcid, kind, ftier),
			"category": "建筑",
			"size": facility_size_of(ftier),
			"shape": "facility",
			"solid": true,
			"facility": true,
			"culture": fcid,
			"kind": kind,
			"tier": ftier,
		}
	if is_building_id(id):
		var info := parse_building_id(id)
		var cid := str(info["culture"])
		var variant := str(info["variant"])
		var tier := str(info["tier"])
		return {
			"id": id,
			"name": _building_name(cid, variant, tier),
			"category": "建筑",
			"size": building_size_of(tier),
			"shape": "house",
			"solid": true,
			"building": true,
			"culture": cid,
			"variant": variant,
			"tier": tier,
		}
	return {}


func ids() -> PackedStringArray:
	var out := PackedStringArray()
	for p in PROPS:
		out.append(str(p["id"]))
	return out


func size_of(id: String) -> Vector2:
	var p := by_id(id)
	return p.get("size", Vector2(64, 64))


func is_solid(id: String) -> bool:
	return bool(by_id(id).get("solid", false))


# ---------------------------------------------------------------- 贴图

func texture_path(id: String) -> String:
	return "%s/%s.png" % [TEXTURE_DIR, id]


## 这个道具是不是已经有美术资源了（建筑 / 功能建筑走图鉴缓存）
func has_texture(id: String) -> bool:
	if is_building_id(id) or is_facility_id(id):
		return has_building_texture(id)
	return ResourceLoader.exists(texture_path(id))


func texture_of(id: String) -> Texture2D:
	if is_building_id(id) or is_facility_id(id):
		return building_texture(id)
	if not has_texture(id):
		return null
	return load(texture_path(id)) as Texture2D


## 喂给大模型的「可用道具清单」，按分类分行，方便模型理解
func prompt_list() -> String:
	var by_category: Dictionary = {}
	for p in PROPS:
		var c := str(p["category"])
		if not by_category.has(c):
			by_category[c] = []
		by_category[c].append("%s(%s)" % [p["id"], p["name"]])
	var lines: PackedStringArray = []
	for c in by_category.keys():
		lines.append("【%s】%s" % [c, "、".join(PackedStringArray(by_category[c]))])
	return "\n".join(lines)

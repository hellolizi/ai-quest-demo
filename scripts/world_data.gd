extends Node
## 世界地图数据（Autoload 名字：WorldData）
## 这里登记的是世界上「真实存在、玩家真的能走到」的地点。
## 任务生成器只能引用这些地点，否则 AI 会编出根本不存在的地方。
##
## 地点有两个来源：
##   1. 基础地点：按当前文化圈（CultureData.current_id）在 set_culture() 里生成，
##      「家」固定 id = "village"、坐标 (0,0)，名字/样式/描述随文化圈变；
##   2. 运行时由 LocationGenerator 让 AI 生成的新地点，通过 add_location() 加进来，
##      各自带着所属文化圈（culture 字段）——不同文化圈的地方说的话不一样。
##
## 新游戏时 CultureData.new_game() 会随机挑一个文化圈并调 set_culture() 重建基础地点。

## 有新地点被加进世界时发出，地图靠它把新地点画出来
signal location_added(loc: Dictionary)

## 地图渲染器目前画得出的地点类型。AI 生成新地点时只能从这里挑，
## 否则会造出一个「地图上没有对应画法」的空地点。
## village 也可以生成——同风格的村落可以有很多个，但名字绝不与母村重名
## （靠 has_name 拦重名），母村本体则固定 id = "village"、坐标 (0,0)。
## city 只做内部升级用：AI 的 kinds 里没有它，它由「村子落在平原上」升级而来
## （见 LocationGenerator._finalize），这里登记是为了让 add_location 放行。
## camp 是坏人据点，AI 的 kinds 里由 CultureData.kinds_of 统一补上，这里登记放行。
## tianfu 是独一无二的「通天福地」秘境：全世界只会有一处，由 LocationGenerator.ensure_tianfu()
## 在开局时确定性地落地，不属于任何常规文化圈，AI 不会生成它，这里登记放行。
const ALLOWED_KINDS := ["village", "city", "mine", "shrine", "forest", "ruin", "bridge", "camp", "tianfu"]

## 家园 6 个固定地标的坐标（母村永远在原点）。id 与 CultureData.home_sites 对应。
## 这些坐标只属于「出生文化圈的家园」，野外的同风格聚落由 LocationGenerator 另找地方。
const HOME_LAYOUT := {
	"village": Vector2(0, 0),
	"mine": Vector2(-200, -1000),
	"shrine": Vector2(900, -850),
	"forest": Vector2(1200, -150),
	"mill": Vector2(-1100, 100),
	"bridge": Vector2(150, 1000),
}

## 当前世界上的全部地点（基础 + 运行时新增）
var LOCATIONS: Array[Dictionary] = []


## 开局基础地点数量。存档只记录「运行时新增」的地点：
## 基础地点本来就能按文化圈重建，不需要重复存；读档时也只把新增的接回去。
var _base_count := 0


func _ready() -> void:
	# 启动时先按默认文化圈建好基础地点；读档/新游戏会再调 set_culture 覆盖
	set_culture(CultureData.current_id)


## 按某个文化圈重建基础地点。会清空所有运行时新增的地点。
## 坐标来自 HOME_LAYOUT（母村固定在原点），CultureData.home_sites 只给名字/类型/描述。
func set_culture(cid: String) -> void:
	LOCATIONS.clear()
	var i := 0
	for loc in CultureData.home_sites(cid):
		var sid := str(loc.get("id", ""))
		var pos: Vector2 = HOME_LAYOUT.get(sid, _home_fallback(i))
		LOCATIONS.append({
			"id": sid,
			"name": str(loc.get("name", "")),
			"kind": str(loc.get("kind", "")),
			"pos": pos,
			"desc": str(loc.get("desc", "")),
			"culture": cid,
		})
		i += 1
	_base_count = LOCATIONS.size()


## HOME_LAYOUT 里没登记的地标用兜底坐标（绕着原点排一圈），保证永远不会落在原点扎堆
func _home_fallback(i: int) -> Vector2:
	var a := TAU * float(i) / 6.0
	return Vector2(cos(a), sin(a)) * 1100.0


func by_id(id: String) -> Dictionary:
	for loc in LOCATIONS:
		if loc["id"] == id:
			return loc
	return {}


func has_id(id: String) -> bool:
	return not by_id(id).is_empty()


func name_of(id: String) -> String:
	var loc := by_id(id)
	return str(loc.get("name", "未知地点"))


## 某个地点属于哪个文化圈；没标注就当作当前文化圈
func culture_of(id: String) -> String:
	var loc := by_id(id)
	if loc.is_empty():
		return CultureData.current_id
	return str(loc.get("culture", CultureData.current_id))


## 运行时新冒出来的地点有几处（主线用它衡量玩家「把世界走大了多少」）
func runtime_count() -> int:
	return maxi(0, LOCATIONS.size() - _base_count)


## 世界上是否已经有一个叫这个名字的地点（避免 AI 生成重名的地方）
func has_name(loc_name: String) -> bool:
	for loc in LOCATIONS:
		if str(loc["name"]) == loc_name:
			return true
	return false


## 运行时新增一个地点。校验不过就拒绝，返回是否成功。
func add_location(loc: Dictionary) -> bool:
	var id := str(loc.get("id", "")).strip_edges()
	var loc_name := str(loc.get("name", "")).strip_edges()
	var kind := str(loc.get("kind", ""))
	if id == "" or has_id(id):
		return false
	if loc_name == "" or has_name(loc_name):
		return false
	if not ALLOWED_KINDS.has(kind):
		return false
	if not loc.has("pos"):
		return false
	loc["id"] = id
	loc["name"] = loc_name
	loc["kind"] = kind
	loc["desc"] = str(loc.get("desc", "")).strip_edges()
	if not loc.has("culture") or str(loc["culture"]) == "":
		loc["culture"] = CultureData.current_id
	LOCATIONS.append(loc)
	location_added.emit(loc)
	return true


## 喂给大模型的「可用地点清单」
func prompt_list() -> String:
	var lines: PackedStringArray = []
	for loc in LOCATIONS:
		lines.append("- %s（%s）：%s" % [loc["id"], loc["name"], loc["desc"]])
	return "\n".join(lines)


# ---------------------------------------------------------------- 存档

## 只把「运行时新增」的地点（_base_count 之后的部分）落档，
## 坐标拆成 x/y 两个数，免得 JSON 里出现没法还原的向量字符串。
func to_save() -> Dictionary:
	var out: Array = []
	for i in range(_base_count, LOCATIONS.size()):
		var loc: Dictionary = LOCATIONS[i]
		var pos: Vector2 = loc["pos"]
		out.append({
			"id": str(loc["id"]),
			"name": str(loc["name"]),
			"kind": str(loc["kind"]),
			"culture": str(loc.get("culture", "")),
			"pos": {"x": pos.x, "y": pos.y},
			"desc": str(loc.get("desc", "")),
			"direction": str(loc.get("direction", "")),
			"distance_m": int(loc.get("distance_m", 0)),
		})
	return {"locations": out}


## 读档：把存档里的动态地点接回世界。
## 读档只在启动时发生，那时主场景地图还没建好，所以这里不发 location_added 信号——
## world_map 会在自己的 _ready 里遍历 LOCATIONS，把包括这些在内的地点全画出来。
func from_save(data: Dictionary) -> void:
	# 先清掉上一次可能残留的动态地点，避免重复读档时越堆越多
	while LOCATIONS.size() > _base_count:
		LOCATIONS.remove_at(LOCATIONS.size() - 1)
	var list = data.get("locations", [])
	if typeof(list) != TYPE_ARRAY:
		return
	for item in list:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var loc := _deserialize_location(item)
		if not loc.is_empty():
			LOCATIONS.append(loc)


func _deserialize_location(item: Dictionary) -> Dictionary:
	var id := str(item.get("id", "")).strip_edges()
	var loc_name := str(item.get("name", "")).strip_edges()
	var kind := str(item.get("kind", "")).strip_edges()
	# 存档可能被手改坏，这里按和 add_location 一样的规矩复核一遍
	if id == "" or has_id(id):
		return {}
	if loc_name == "" or has_name(loc_name):
		return {}
	if not ALLOWED_KINDS.has(kind):
		return {}
	var pd = item.get("pos", {})
	if typeof(pd) != TYPE_DICTIONARY:
		return {}
	var cid := str(item.get("culture", CultureData.current_id))
	if cid == "":
		cid = CultureData.current_id
	return {
		"id": id,
		"name": loc_name,
		"kind": kind,
		"culture": cid,
		"pos": Vector2(float(pd.get("x", 0.0)), float(pd.get("y", 0.0))),
		"desc": str(item.get("desc", "")),
		"direction": str(item.get("direction", "")),
		"distance_m": int(item.get("distance_m", 0)),
	}

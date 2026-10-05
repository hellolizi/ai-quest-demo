extends Node2D
## 主场景：把 NPC 的交谈请求转给对话界面，并处理任务日志的开关。
## 另外负责「让世界自己长人」：打听出新地点后，让 AI 给那地方安排一个住客；
## 读档时，把存档里记着的新 NPC 重新生成到各自的住处。

@onready var _dialogue_ui: Control = $UI/DialogueUI
@onready var _quest_log_ui: Control = $UI/QuestLogUI
@onready var _story_ui: Control = $UI/StoryUI
@onready var _portrait_ui: Control = $UI/PortraitLibraryUI
@onready var _world: Node = $World
@onready var _props: Node2D = $Props

## 场景里 NPC 用的是同一个 PackedScene
const NPC_SCENE := "res://scenes/npc.tscn"

## 进屋时现搭的室内场景脚本
const INTERIOR_SCRIPT := preload("res://scripts/interior.gd")

## 锻造台 / 商铺界面脚本（运行时挂在 $UI 下，走近按 E 打开）
const FACILITY_UI_SCRIPT := preload("res://scripts/facility_ui.gd")

## 左上角常驻 HUD（血量 / 金币 / 当前武器）
const HUD_SCRIPT := preload("res://scripts/hud.gd")

## 全局 UI 主题（统一暗色 + 暖金外观）
const UI_THEME_SCRIPT := preload("res://scripts/ui_theme.gd")

## 当前这间屋子的室内场景（在室内时才有值，出门即销毁）
var _interior: Node2D = null

## 锻造台 / 商铺界面（一直挂着，打开时才显示）
var _facility_ui: Control = null

## 左上角常驻 HUD（血量 / 金币 / 当前武器 + 拾取提示）
var _hud: Control = null

## 通天福地一口宝箱里的东西：一大笔金币 + 各色锻造材料。
## 福地「物资多到数不清」，开一口就够用很久；四口全开是笔横财。
const TIANFU_CHEST_LOOT := {
	"gold": 500,
	"ore_iron": 20,
	"ore_copper": 16,
	"wood": 20,
	"leather": 16,
	"crystal": 8,
}

## 每种地方住多少人：城市人最多，村子次之，荒野/废墟这种地方几乎没人。
## 没列到的类型默认 1 个。
const POPULATION := {
	"city": 8,
	"village": 5,
	"shrine": 2,
	"mine": 1,
	"forest": 1,
	"ruin": 1,
	"bridge": 1,
}


func _ready() -> void:
	# 出生点随文化圈而定——每个玩家开局站的地方都不一样
	_place_player()
	# 起始乡亲也随文化圈而定，所以每个人开局遇到的人、听到的话都不同
	_spawn_starting_npcs()
	# 读档回来的 NPC：逐个重新生成，站回他们各自住的地方
	NpcGenerator.npc_created.connect(_on_npc_created)
	for data in NpcGenerator.dynamic_npcs:
		_spawn_npc(data)
	# 打听出一个新地点之后，顺手让 AI 给这地方安排一个住客
	LocationGenerator.location_created.connect(_on_location_created)
	# 通天福地：全世界独一份的秘境，开局就确定性地落到地图上，住客随即入场
	LocationGenerator.ensure_tianfu()
	# 让街坊之间互相认识：每个 NPC 至少牵上一条关系，不至于满村陌生人
	# （AI 生成的新 NPC 自带关系，这里主要兜住起始乡亲和老存档）
	NpcRelations.ensure_links(1)
	# 主线起步。放在这里而不是 StoryDirector 自己的 _ready 里：
	# 那时读档还没发生，不知道存档已经推到第几章了。
	StoryDirector.boot()
	# 走到门口按 E 进屋：世界地图只管报告「有人敲门」，搭屋子和搬人在这里做
	_world.house_entered.connect(_on_house_entered)
	# 走到锻造台 / 商铺前按 E 使用：界面一直挂着，用的时候才显示
	_world.facility_used.connect(_on_facility_used)
	# 走到宝箱前按 E 开采：福地的「物资多到数不清」就靠这里兑现
	_world.treasure_opened.connect(_on_treasure_opened)
	_facility_ui = FACILITY_UI_SCRIPT.new()
	_facility_ui.name = "FacilityUI"
	# 马厩 / 驿站付了脚力钱：把玩家直接送到目的地聚落
	_facility_ui.travel_requested.connect(_on_travel_requested)
	$UI.add_child(_facility_ui)
	# 左上角常驻 HUD（血量 / 金币 / 当前武器，按 I 换武器）
	_hud = HUD_SCRIPT.new()
	_hud.name = "HUD"
	$UI.add_child(_hud)
	# 统一 UI 外观：给 UI 层下每个界面挂上同一套主题（挂完，之后新建的面板/按钮自动同款）
	UI_THEME_SCRIPT.apply($UI)
	# 被野物咬死：回满血并送回出生点，不至于卡在死亡状态
	PlayerProfile.died.connect(_on_player_died)


## 玩家倒下：回满血，送回复活点（在客栈住过就是那家客栈，否则是本乡出生点）。
## 若在屋里就先原地复活，别把人扔到屋外。
func _on_player_died() -> void:
	PlayerProfile.revive()
	if _interior != null:
		return
	var player := _world.get_node_or_null("Player")
	if player == null:
		return
	player.position = PlayerProfile.respawn_pos()
	if player.has_method("reset_camera"):
		player.reset_camera()


## 使用锻造台 / 商铺：把这座建筑的上下文交给界面。
func _on_facility_used(info: Dictionary) -> void:
	if _facility_ui == null or _interior != null:
		return
	_facility_ui.open(info)


## 开采通天福地的宝箱：一口给一大笔金币与各色材料。同一口只发一次，
## 靠 WorldState 里的开关记账——读档回来箱子还是空的，不会刷第二遍。
func _on_treasure_opened(info: Dictionary) -> void:
	if _interior != null:
		return
	var flag_key := "tianfu_chest_%s" % str(info.get("id", ""))
	if bool(WorldState.flag(flag_key, false)):
		_hud_toast("这口宝箱已经见底了。")
		return
	WorldState.set_flag(flag_key, true)
	var gold := int(TIANFU_CHEST_LOOT.get("gold", 0))
	if gold > 0:
		PlayerProfile.add_gold(gold)
	var parts: PackedStringArray = []
	for mid in ["ore_iron", "ore_copper", "wood", "leather", "crystal"]:
		var n := int(TIANFU_CHEST_LOOT.get(mid, 0))
		if n > 0:
			PlayerProfile.add_item(mid, n)
			parts.append("%s×%d" % [WeaponData.material_name(mid), n])
	_hud_toast("开启宝箱：金币 +%d，%s" % [gold, ",".join(parts)])


## 让 HUD 弹一条拾取 / 奖励提示。HUD 还没建好或被换掉时静默跳过。
func _hud_toast(text: String) -> void:
	if _hud != null and _hud.has_method("toast"):
		_hud.toast(text)


## 马厩 / 驿站把玩家送到别的聚落：直接挪坐标，摄像机跟上。
## 在屋里时不该收到（界面在屋外才开），保险起见还是先挡一道。
func _on_travel_requested(dest: Vector2) -> void:
	if _interior != null:
		return
	var player := _world.get_node_or_null("Player")
	if player == null:
		return
	player.position = dest
	if player.has_method("reset_camera"):
		player.reset_camera()


## 进屋：现搭一间屋里场景，把玩家从 World 挪进去，并藏起屋外的世界。
func _on_house_entered(info: Dictionary) -> void:
	if _interior != null:
		return
	var player := _world.get_node_or_null("Player")
	if player == null:
		return
	_interior = INTERIOR_SCRIPT.new()
	_interior.name = "Interior"
	add_child(_interior)
	_interior.set_player(player)
	_interior.exit_requested.connect(_on_interior_exit_requested)
	# 先搭好屋子，才能知道进门该站在哪
	_interior.build(info)
	# 藏起屋外：世界与摆件整体隐藏，NPC 等仍在原地待命，出门即恢复
	_world.visible = false
	_props.visible = false
	player.reparent(_interior)
	player.position = _interior.spawn_pos
	if player.has_method("reset_camera"):
		player.reset_camera()
	InteriorManager.enter(info)


## 出门：把玩家送回屋外门口，拆掉屋里场景，恢复世界显示。
func _on_interior_exit_requested() -> void:
	if _interior == null:
		return
	var player := _interior.get_node_or_null("Player")
	if player == null:
		player = get_tree().get_first_node_in_group("player")
	var back: Vector2 = InteriorManager.house_pos + Vector2(0.0, 40.0)
	if player != null:
		player.reparent(_world)
		player.position = back
		if player.has_method("reset_camera"):
			player.reset_camera()
	_interior.queue_free()
	_interior = null
	_world.visible = true
	_props.visible = true
	InteriorManager.exit()


## 把玩家摆到当前文化圈的出生点上
func _place_player() -> void:
	var player := _world.get_node_or_null("Player")
	if player != null:
		player.position = CultureData.spawn_point()


## 生成出生地的起始乡亲。数据来自 CultureData，所以换一个文化圈就是另一批人。
func _spawn_starting_npcs() -> void:
	var cid := CultureData.current_id
	for raw in CultureData.starting_npcs():
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = (raw as Dictionary).duplicate()
		entry["home_id"] = CultureData.HOME_ID
		entry["home_name"] = CultureData.village_name()
		entry["culture"] = cid
		_spawn_npc(entry, false)


func _wire_npc(npc: Node) -> void:
	npc.talk_requested.connect(_on_npc_talk_requested)
	# 玩家走近 / 走远某个 NPC：把这个人交给 HUD 显示简略状态栏
	npc.focus_changed.connect(_on_npc_focus_changed)
	# 记下每个 NPC 的坐标，任务「待复命」时导航箭头才知道该指向哪
	NpcMemory.register(npc.npc_name, npc.global_position)
	# 登记名字，避免之后 AI 又生成一个同名的人
	NpcGenerator.note_name(npc.npc_name, npc.npc_role)


## 玩家进入某个 NPC 的交互范围 / 离开：HUD 右侧亮出或收起那个人的状态栏
func _on_npc_focus_changed(npc: Node, focused: bool) -> void:
	if _hud == null:
		return
	if focused:
		_hud.set_npc_focus(npc)
	elif _hud.npc_focus() == npc:
		_hud.clear_npc_focus()


func _on_location_created(loc: Dictionary) -> void:
	# 通天福地：住客是手写固定的绝色美人，不走 AI 生成，也不走通用人口管线
	if str(loc.get("kind", "")) == "tianfu":
		_spawn_tianfu_residents(loc)
		return
	# 主线终局的地点：住客由剧情导演按终局链亲自指定，这里不插手
	if bool(loc.get("story", false)):
		return
	# 一个地方住几个人，看它是哪种地方：村子热闹，荒野冷清
	var count := int(POPULATION.get(str(loc.get("kind", "village")), 1))
	for _i in count:
		NpcGenerator.request_npc(loc)


## 通天福地的住客：读文化数据里写好的名单，逐条登记入场。
## 他们本就住在仙宫里，所以不再各自盖屋（见 _spawn_npc 里对 tianfu 的特判）。
func _spawn_tianfu_residents(loc: Dictionary) -> void:
	var culture := CultureData.get_culture("tianfu")
	var list = culture.get("npcs", [])
	if typeof(list) != TYPE_ARRAY:
		return
	for raw in (list as Array):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = (raw as Dictionary).duplicate(true)
		entry["home_id"] = str(loc.get("id", ""))
		entry["home_name"] = str(loc.get("name", "通天福地"))
		entry["culture"] = "tianfu"
		NpcGenerator.register_authored(entry)


func _on_npc_created(data: Dictionary) -> void:
	_spawn_npc(data)


## 把一个 NPC 档案变成场景里真实站着的人：摆到住处旁，并给他盖一间小屋。
## announce=false 表示这是开局就认识的老乡，不必再弹「你认识了一个新朋友」。
func _spawn_npc(data: Dictionary, announce: bool = true) -> void:
	var scene: PackedScene = load(NPC_SCENE)
	var npc: Node2D = scene.instantiate()
	npc.npc_name = str(data.get("name", "村民"))
	npc.npc_role = str(data.get("role", "村民"))
	npc.personality = str(data.get("personality", ""))
	npc.greetings = PackedStringArray(_to_strings(data.get("greetings", [])))
	# 这个人说哪国话：留空或没有就沿用玩家所在文化圈
	var cid := str(data.get("culture", CultureData.current_id))
	npc.culture_id = cid
	# 聚落档次：城里的居民穿着更讲究。档案里记了就用，没记就从住处类型反推。
	var tier := str(data.get("tier", ""))
	if tier == "":
		tier = CharacterSprite.tier_for_kind(_home_kind(data))
	npc.tier = tier
	# 长相：档案里带了就用档案的，没带就按名字稳定推导一个（同一个人每次长得一样）
	var app = data.get("appearance", null)
	if typeof(app) != TYPE_DICTIONARY:
		app = CharacterSprite.derive_appearance(npc.npc_name, cid, tier)
	npc.set_appearance(app)
	npc.position = _home_pos(data) + _offset_of(data)
	_world.add_child(npc)
	_wire_npc(npc)
	# 住处画成一间小屋，让他有个「家」可回（小屋也随他的文化圈换风格）
	# 通天福地的住客本就住在仙宫里，不再各自盖屋，免得把福地的景致压塌
	if npc.culture_id != "tianfu":
		_world.add_npc_home(npc.position, npc.culture_id)
	if announce:
		_dialogue_ui.note_new_npc(npc.npc_name, npc.npc_role, str(data.get("home_name", "")))


func _home_pos(data: Dictionary) -> Vector2:
	var loc := WorldData.by_id(str(data.get("home_id", "")))
	if loc.is_empty():
		loc = WorldData.by_id("village")
	if loc.is_empty():
		return Vector2.ZERO
	return loc["pos"] as Vector2


## 这个 NPC 住在哪种地方（city / village / mine……）。查不到就当村子。
func _home_kind(data: Dictionary) -> String:
	var loc := WorldData.by_id(str(data.get("home_id", "")))
	return str(loc.get("kind", ""))


func _offset_of(data: Dictionary) -> Vector2:
	var off = data.get("offset", null)
	# 起始乡亲的 offset 是 Vector2，AI 动态生成的 NPC 的 offset 是 {x,y} 字典，两种都要认
	if typeof(off) == TYPE_VECTOR2:
		return off
	if typeof(off) == TYPE_DICTIONARY:
		return Vector2(float(off.get("x", 0.0)), float(off.get("y", 0.0)))
	return Vector2.ZERO


func _to_strings(raw) -> Array:
	var out: Array = []
	if typeof(raw) == TYPE_ARRAY:
		for s in (raw as Array):
			var t := str(s).strip_edges()
			if t != "":
				out.append(t)
	return out


func _on_npc_talk_requested(npc: Node) -> void:
	PlayerProfile.record_talk(npc.npc_name)
	# 主线终局链可能正等着「去见某个人」——搭话即视为履约
	StoryDirector.note_talk(npc.npc_name)
	# 每次搭话都涨一点好感，让 NPC 的「印象」随相处慢慢变化
	# 武器的「好感增长 +N%」在这里体现：本来 +1，带上加成就能 +2
	var affinity_gain := 1 + int(round(PlayerProfile.weapon_effect("affinity", 0.0)))
	NpcMemory.change_affinity(npc.npc_name, affinity_gain)
	# 每聊满 3 次，让 AI 根据这段关系重写一句对玩家的印象（关键节点才调，避免刷爆上下文）
	var count := PlayerProfile.talk_count(npc.npc_name)
	if count > 0 and count % 3 == 0:
		NpcMemory.request_impression(
			npc.npc_name, npc.npc_role, npc.personality,
			"玩家已经来找你聊过 %d 次了" % count,
		)
	_dialogue_ui.open(npc)


func _unhandled_input(event: InputEvent) -> void:
	# 对话开着时不抢键盘，Q / T 交给对话界面自己处理
	if PlayerProfile.ui_open:
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_Q:
			get_viewport().set_input_as_handled()
			_quest_log_ui.toggle()
		KEY_J:
			get_viewport().set_input_as_handled()
			_story_ui.toggle()
		KEY_T:
			# 身上有多件任务时，按 T 轮换左上角箭头指向的那件
			get_viewport().set_input_as_handled()
			QuestManager.cycle_tracked()
		KEY_P:
			# 立绘库：挑图 / 淘汰 / 补齐
			get_viewport().set_input_as_handled()
			_portrait_ui.toggle()

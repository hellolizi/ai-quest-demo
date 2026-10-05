extends Node
## 存档系统（Autoload 名字：SaveSystem）
##
## 把玩家画像、任务进度、每个 NPC 的好感/印象/记忆、世界记忆，
## 以及「AI 造出来的地点」和「这些地点上的场景布置」写进 user://save.json。
## 这样「好感、印象、世界记忆、AI 生成的新地点一关游戏就清零」的问题就解决了。
##
## 存档时机：定时自动存 + 每完成一个任务存 + 关窗口时存。
## 注意：NPC 的坐标（NpcMemory._positions）不入档，读档后由 main.gd 重新登记。

const SAVE_PATH := "user://save.json"
const SAVE_VERSION := 3
const AUTOSAVE_INTERVAL := 20.0

## 只有从开始菜单「新游戏 / 继续」进来之后才为 true。
## 这样直接跑主场景（开发调试）不会误存、也不会覆盖玩家存档。
var active := false

var _timer := 0.0
## 读档过程中不要触发自动存档，避免把半截数据写回去
var _loading := false


func _ready() -> void:
	# 读档交给开始菜单发起（新游戏 / 继续），这里只挂上「完成任务就存」的钩子
	QuestManager.quest_completed.connect(_on_quest_completed)


func _process(delta: float) -> void:
	if not active or _loading:
		return
	_timer += delta
	if _timer >= AUTOSAVE_INTERVAL:
		_timer = 0.0
		save_game()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and active:
		save_game()


func _on_quest_completed(_quest: Dictionary) -> void:
	save_game()


func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)


func save_game() -> void:
	if not active or _loading:
		return
	var data := {
		"version": SAVE_VERSION,
		"region": RegionGenerator.to_save(),
		"culture": CultureData.to_save(),
		"profile": PlayerProfile.to_save(),
		"weapons": WeaponData.to_save(),
		"quests": QuestManager.to_save(),
		"memory": NpcMemory.to_save(),
		"relations": NpcRelations.to_save(),
		"world": WorldState.to_save(),
		"world_data": WorldData.to_save(),
		"decorator": SceneDecorator.to_save(),
		"npcs": NpcGenerator.to_save(),
		"story": StoryDirector.to_save(),
	}
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("[SaveSystem] 存档写入失败：%s" % error_string(FileAccess.get_open_error()))
		return
	f.store_string(JSON.stringify(data))
	f.close()


func load_game() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return
	var raw := f.get_as_text()
	f.close()
	var data = JSON.parse_string(raw)
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("[SaveSystem] 存档解析失败，忽略")
		return
	if int(data.get("version", 0)) != SAVE_VERSION:
		push_warning("[SaveSystem] 存档版本不一致，忽略")
		return

	_loading = true
	# 世界种子要在重建地点之前恢复：之后地点落在哪个区域，全看它
	var region = data.get("region", {})
	if typeof(region) == TYPE_DICTIONARY:
		RegionGenerator.from_save(region)
	# 先定文化圈、按它重建基础地点，之后各种数据才有「地方」可依附
	var culture = data.get("culture", {})
	if typeof(culture) == TYPE_DICTIONARY:
		CultureData.from_save(culture)
	WorldData.set_culture(CultureData.current_id)
	# 现造的武器（如现代结局的枪械）要在玩家画像之前恢复，装备栏才认得出这把枪
	var weapons = data.get("weapons", {})
	if typeof(weapons) == TYPE_DICTIONARY:
		WeaponData.from_save(weapons)
	var profile = data.get("profile", {})
	if typeof(profile) == TYPE_DICTIONARY:
		PlayerProfile.from_save(profile)
	var quests = data.get("quests", {})
	if typeof(quests) == TYPE_DICTIONARY:
		QuestManager.from_save(quests)
	var memory = data.get("memory", {})
	if typeof(memory) == TYPE_DICTIONARY:
		NpcMemory.from_save(memory)
	var world = data.get("world", {})
	if typeof(world) == TYPE_DICTIONARY:
		WorldState.from_save(world)
	# 地点要在布置之前恢复：布置是按地点 id 存的，先有地点更直观
	var world_data = data.get("world_data", {})
	if typeof(world_data) == TYPE_DICTIONARY:
		WorldData.from_save(world_data)
	var decorator = data.get("decorator", {})
	if typeof(decorator) == TYPE_DICTIONARY:
		SceneDecorator.from_save(decorator)
	# NPC 之间的关系网：要在 NPC 档案之前恢复，这样随后 NpcGenerator 登记名字时
	# 名字已经在了（老存档没有这个字段时，这里清空，之后由 main.gd 的 ensure_links 兜底补网）
	var relations = data.get("relations", {})
	if typeof(relations) == TYPE_DICTIONARY:
		NpcRelations.from_save(relations)
	# 新住进世界的 NPC：读回来之后由 main.gd 按 home_id 重新生成到住处旁
	var npcs = data.get("npcs", {})
	if typeof(npcs) == TYPE_DICTIONARY:
		NpcGenerator.from_save(npcs)
	# 主线进度：读到第几章、看过的结局（界面自己按状态刷新，不依赖信号）
	var story = data.get("story", {})
	if typeof(story) == TYPE_DICTIONARY:
		StoryDirector.from_save(story)
	_loading = false
	print("[SaveSystem] 已读取存档：%s" % SAVE_PATH)


## 新游戏：清掉旧存档，把所有模块退回空白状态，然后随机挑一个文化圈出生。
func start_new_game() -> void:
	_loading = true
	delete_save()
	# 各个模块用一份空档各自重置（各家的 from_save 都会先清空自己）
	PlayerProfile.from_save({})
	WeaponData.from_save({})
	QuestManager.from_save({})
	NpcMemory.from_save({})
	NpcRelations.from_save({})
	WorldState.from_save({})
	SceneDecorator.from_save({})
	NpcGenerator.from_save({})
	StoryDirector.from_save({})
	# 随机定一个文化圈；玩家和世界都按它铺开，所以每个人开局都不一样
	CultureData.new_game()
	PlayerProfile.new_game()
	# 再掷一颗新的世界种子：这个世界的区域布局从此固定下来
	RegionGenerator.randomize_world_seed()
	WorldData.from_save({})
	_loading = false
	active = true
	_timer = 0.0
	save_game()
	print("[SaveSystem] 新游戏：出生在 %s" % CultureData.village_name())


## 继续游戏：有存档才读得进来，读成功返回 true
func continue_game() -> bool:
	if not has_save():
		return false
	load_game()
	active = true
	_timer = 0.0
	return true


func delete_save() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(SAVE_PATH)

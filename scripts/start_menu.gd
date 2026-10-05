extends Control
## 开始菜单：新游戏 / 继续 / 设置 / 退出。
##
## 「设置」是玩家唯一该填 API Key 的地方：填完写进 user://llm_config.cfg 并立刻生效，
## 玩家不需要（也不该）去手动改游戏目录里的 llm_config.cfg。

const MAIN_SCENE := "res://scenes/main.tscn"
## 玩家自己写结局时先进加载场景：现场编主线、铺终局落点、写第一章都要时间
const LOADING_SCENE := "res://scenes/loading.tscn"
## 主角的外观 / 名字 / 文化键都定义在 player.gd 里（唯一来源），
## 这里读它的常量，好让「进游戏前先画主角立绘」用的是同一份身份。
const PlayerScript := preload("res://scripts/player.gd")

@onready var _menu: VBoxContainer = $Panel/Menu
@onready var _new_btn: Button = $Panel/Menu/NewGameBtn
@onready var _continue_btn: Button = $Panel/Menu/ContinueBtn
@onready var _settings_btn: Button = $Panel/Menu/SettingsBtn
@onready var _quit_btn: Button = $Panel/Menu/QuitBtn
@onready var _hint: Label = $Panel/Hint

@onready var _settings_panel: Panel = $SettingsPanel
@onready var _mode_opt: OptionButton = $SettingsPanel/Scroll/Box/ModeRow/ModeOpt
@onready var _base_edit: LineEdit = $SettingsPanel/Scroll/Box/BaseRow/BaseEdit
@onready var _key_edit: LineEdit = $SettingsPanel/Scroll/Box/KeyRow/KeyEdit
@onready var _reveal_btn: Button = $SettingsPanel/Scroll/Box/KeyRow/RevealBtn
@onready var _model_edit: LineEdit = $SettingsPanel/Scroll/Box/ModelRow/ModelEdit
@onready var _msg: Label = $SettingsPanel/Scroll/Box/Msg
@onready var _save_btn: Button = $SettingsPanel/Btns/SaveBtn
@onready var _back_btn: Button = $SettingsPanel/Btns/BackBtn

# ---- AI 立绘那一套控件 ----
@onready var _image_mode_opt: OptionButton = $SettingsPanel/Scroll/Box/ImageModeRow/ImageModeOpt
@onready var _provider_opt: OptionButton = $SettingsPanel/Scroll/Box/ProviderRow/ProviderOpt
@onready var _image_base_edit: LineEdit = $SettingsPanel/Scroll/Box/ImageBaseRow/ImageBaseEdit
@onready var _image_key_edit: LineEdit = $SettingsPanel/Scroll/Box/ImageKeyRow/ImageKeyEdit
@onready var _image_reveal_btn: Button = $SettingsPanel/Scroll/Box/ImageKeyRow/ImageRevealBtn
@onready var _image_model_edit: LineEdit = $SettingsPanel/Scroll/Box/ImageModelRow/ImageModelEdit
@onready var _image_size_edit: LineEdit = $SettingsPanel/Scroll/Box/ImageSizeRow/ImageSizeEdit
@onready var _remove_bg_check: CheckBox = $SettingsPanel/Scroll/Box/RemoveBgRow/RemoveBgCheck

# ---- 开局「结局设定」那一套控件 ----
@onready var _goal_panel: Panel = $GoalPanel
@onready var _goal_preset_box: VBoxContainer = $GoalPanel/Scroll/Box/PresetBox
@onready var _goal_custom_edit: TextEdit = $GoalPanel/Scroll/Box/CustomEdit
@onready var _goal_custom_btn: Button = $GoalPanel/Scroll/Box/CustomBtn
@onready var _goal_msg: Label = $GoalPanel/Scroll/Box/Msg
@onready var _goal_skip_btn: Button = $GoalPanel/Btns/SkipBtn
@onready var _goal_back_btn: Button = $GoalPanel/Btns/BackBtn

## 下拉里平台选项的顺序，跟 ProviderOpt 的 item id 一一对应
const PROVIDER_ORDER := ["siliconflow", "ark_plan", "dashscope"]


func _ready() -> void:
	_new_btn.pressed.connect(_on_new)
	_continue_btn.pressed.connect(_on_continue)
	_settings_btn.pressed.connect(_open_settings)
	_quit_btn.pressed.connect(_on_quit)
	_save_btn.pressed.connect(_on_save_settings)
	_back_btn.pressed.connect(_close_settings)
	_reveal_btn.pressed.connect(_toggle_key_visible)
	_image_reveal_btn.pressed.connect(_toggle_image_key_visible)
	# 玩家换平台时，自动把该平台的默认地址/模型/尺寸填进去，省得自己查文档
	_provider_opt.item_selected.connect(_on_provider_selected)
	# 开局结局设定
	_build_goal_presets()
	_goal_custom_btn.pressed.connect(_on_goal_custom)
	_goal_skip_btn.pressed.connect(_on_goal_skip)
	_goal_back_btn.pressed.connect(_close_goal)
	_settings_panel.visible = false
	_goal_panel.visible = false
	_continue_btn.disabled = not SaveSystem.has_save()
	_refresh_hint()


func _refresh_hint() -> void:
	var mode_text := "在线大模型" if LlmConfig.mode == "llm" else "离线模板"
	var portrait_text := "关闭"
	if LlmConfig.image_mode == "api":
		var preset: Dictionary = LlmConfig.IMAGE_PRESETS.get(LlmConfig.image_provider, {})
		portrait_text = "开启（%s）" % str(preset.get("label", LlmConfig.image_provider))
	_hint.text = "当前模式：%s　·　模型：%s　·　AI 立绘：%s\nKey 请在「设置」里填写" % [
		mode_text, LlmConfig.model, portrait_text,
	]


# ---------------------------------------------------------------- 菜单按钮

func _on_new() -> void:
	_open_goal()


func _on_continue() -> void:
	if SaveSystem.continue_game():
		_enter_game(MAIN_SCENE)
	else:
		_continue_btn.disabled = true


func _on_quit() -> void:
	get_tree().quit()


# ---------------------------------------------------------------- 开局：结局设定

## 按 StoryDirector 给的预设，动态摆出几个按钮（预设改了这里自动跟着变）
func _build_goal_presets() -> void:
	for g in StoryDirector.PRESET_GOALS:
		var b := Button.new()
		b.custom_minimum_size = Vector2(0, 54)
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		b.text = "%s　%s" % [str(g.get("name", "")), str(g.get("desc", ""))]
		b.pressed.connect(_on_goal_preset.bind(str(g.get("id", ""))))
		_goal_preset_box.add_child(b)


func _open_goal() -> void:
	_settings_panel.visible = false
	_goal_msg.text = ""
	_goal_custom_edit.text = ""
	_goal_panel.visible = true


func _close_goal() -> void:
	_goal_panel.visible = false
	_refresh_hint()


func _on_goal_preset(id: String) -> void:
	_start_new_game("preset", id, "")


func _on_goal_custom() -> void:
	var t := _goal_custom_edit.text.strip_edges()
	if t == "":
		_goal_msg.text = "先写一句你想要的结局。"
		return
	# 自定义结局要现场编主线、铺落点、写第一章，走加载场景边加载边报进度
	_start_new_game("custom", "", t, LOADING_SCENE)


func _on_goal_skip() -> void:
	_start_new_game("", "", "")


## 开局顺序不能反：start_new_game() 会把各模块（含 StoryDirector）清空，
## 所以必须「先重置 → 再定结局 → 再存一次档」，否则结局会被清掉。
## scene 决定进哪个场景：自定义结局走加载场景，其余直接进主场景。
func _start_new_game(kind: String, preset: String, custom: String, scene: String = MAIN_SCENE) -> void:
	SaveSystem.start_new_game()
	if kind == "preset":
		StoryDirector.set_goal_preset(preset)
	elif kind == "custom":
		StoryDirector.set_goal_custom(custom)
	SaveSystem.save_game()
	# 世界与结局都定好了，进游戏前先把这一带的人画出来
	_enter_game(scene)


## 进游戏前的总入口：把要画的人与房屋排进生成器的后台队列，然后立刻切场景。
## 生图不在进游戏前阻塞——队列在后台继续跑，图一落盘 NPC 就自动换上
## （PortraitLibrary.changed / walk_changed），玩家不用盯着进度条等。
## scene != MAIN_SCENE（自定义结局走加载场景）时不排队：那边的 NPC 还没影呢。
func _enter_game(scene: String) -> void:
	if scene == MAIN_SCENE:
		_queue_preload_jobs()
	get_tree().change_scene_to_file(scene)


## 把「出生点附近的人（含主角）+ 当前文化圈的房屋」排进各生成器的后台队列。
## 生图关着、或都已经有图时，这一步什么都不做。
func _queue_preload_jobs() -> void:
	if not _preload_useful():
		return
	var people := _all_people()
	# 立绘与走路帧各排各的队列（两个生成器并行，互不阻塞）
	for job in _missing_portrait_jobs(people):
		PortraitGenerator.request(
			job["tag"], job["name"], job["role"], job["cid"], job["app"], job.get("tier", "")
		)
	for job in _missing_walk_jobs(people):
		WalkSheetGenerator.request(
			job["tag"], job["name"], job["role"], job["cid"], job["app"]
		)
	# 房屋也一并排队：当前文化圈就 3 个变体，画完一轮后进游戏全是现成的
	for bid in _missing_building_jobs():
		BuildingGenerator.request(bid)


## 生图开着、且生成器在，才值得等
func _preload_useful() -> bool:
	if has_node("/root/PortraitGenerator") and PortraitGenerator.is_on():
		return true
	if has_node("/root/WalkSheetGenerator") and WalkSheetGenerator.is_on():
		return true
	if has_node("/root/BuildingGenerator") and BuildingGenerator.is_on():
		return true
	return false


## 收集「出生点附近的人」：主角 + 起始乡亲 + 存档里的动态 NPC。
## 每人一份 {tag_key, name, role, cid, app}，够两个生成器各算出自己的标签。
func _all_people() -> Array:
	var people: Array = []
	# 主角：标签用固定的 player 文化键，生图提示词用玩家当前所在文化圈
	_append_person(
		people, PlayerScript.PORTRAIT_NAME, "主角",
		PlayerScript.PORTRAIT_CULTURE_KEY, CultureData.current_id,
		PlayerScript.PLAYER_APPEARANCE, ""
	)
	# 起始乡亲：档案里没带外观就按名字稳定推导一个（与 main.gd 生成时一致）
	for raw in CultureData.starting_npcs():
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = raw
		var cid := CultureData.current_id
		var nm := str(d.get("name", ""))
		var app = d.get("appearance", null)
		if typeof(app) != TYPE_DICTIONARY:
			app = CharacterSprite.derive_appearance(nm, cid)
		_append_person(people, nm, str(d.get("role", "")), cid, cid, app, "")
	# 读档回来的动态 NPC
	if has_node("/root/NpcGenerator"):
		for raw in NpcGenerator.dynamic_npcs:
			if typeof(raw) != TYPE_DICTIONARY:
				continue
			var d: Dictionary = raw
			var cid := str(d.get("culture", CultureData.current_id))
			var nm := str(d.get("name", ""))
			var tier := str(d.get("tier", ""))
			if tier == "":
				tier = CharacterSprite.tier_for_kind(_kind_of(str(d.get("home_id", ""))))
			var app = d.get("appearance", null)
			if typeof(app) != TYPE_DICTIONARY:
				app = CharacterSprite.derive_appearance(nm, cid, tier)
			_append_person(people, nm, str(d.get("role", "")), cid, cid, app, tier)
	return people


## 按聚落 id 查它的类型（"city"/"village"/…），查不到返回空串。
func _kind_of(loc_id: String) -> String:
	if loc_id == "" or not has_node("/root/WorldData"):
		return ""
	var loc = WorldData.by_id(loc_id)
	if typeof(loc) != TYPE_DICTIONARY:
		return ""
	return str(loc.get("kind", ""))


## 登记一个人。tag_key 用来算标签（主角用固定键），cid 用于生图提示词。
func _append_person(people: Array, nm: String, role: String, tag_key: String, cid: String, app, tier: String = "") -> void:
	var name := nm.strip_edges()
	if name == "":
		return
	people.append({
		"tag_key": tag_key, "name": name, "role": role,
		"cid": cid, "app": CharacterSprite.sanitize_appearance(app),
		"tier": tier,
	})


## 还没立绘的人。已经有图的会被跳过，所以第二次进游戏通常秒进。
func _missing_portrait_jobs(people: Array) -> Array:
	var jobs: Array = []
	for p in people:
		var tag := PortraitLibrary.tag_for(p["name"], p["tag_key"], p["app"])
		if PortraitLibrary.has(tag):
			continue
		jobs.append({"tag": tag, "name": p["name"], "role": p["role"], "cid": p["cid"], "app": p["app"], "tier": p.get("tier", "")})
	return jobs


## 还没走路帧的人。已经有帧的跳过，走路帧比立绘慢，重进时省最多时间。
func _missing_walk_jobs(people: Array) -> Array:
	var jobs: Array = []
	for p in people:
		var tag := PortraitLibrary.tag_for(p["name"], p["tag_key"], p["app"])
		if PortraitLibrary.has_walk(tag):
			continue
		jobs.append({"tag": tag, "name": p["name"], "role": p["role"], "cid": p["cid"], "app": p["app"]})
	return jobs


## 当前文化圈还没画过的房屋变体。开局世界只有一个文化圈，就 3 个变体（a/b/c），
## 都是有限组合，画完一轮后进游戏时房屋就全是 AI 图，不会再退回程序化占位。
func _missing_building_jobs() -> Array:
	var jobs: Array = []
	if not has_node("/root/BuildingGenerator") or not BuildingGenerator.is_on():
		return jobs
	var cid := CultureData.current_id
	for variant in PropLibrary.BUILDING_VARIANTS:
		var bid := PropLibrary.building_id(cid, variant)
		if PropLibrary.has_building_texture(bid):
			continue
		jobs.append(bid)
	return jobs


# ---------------------------------------------------------------- 设置

func _open_settings() -> void:
	_mode_opt.select(0 if LlmConfig.mode == "llm" else 1)
	_base_edit.text = LlmConfig.api_base
	_key_edit.text = LlmConfig.api_key
	# 每次打开都先恢复隐藏，避免 Key 明晃晃地露在外面
	_key_edit.secret = true
	_reveal_btn.text = "显示"
	_model_edit.text = LlmConfig.model
	# 立绘那一套：把上次保存的值填回去
	_image_mode_opt.select(0 if LlmConfig.image_mode == "api" else 1)
	var pi := PROVIDER_ORDER.find(LlmConfig.image_provider)
	_provider_opt.select(pi if pi >= 0 else 0)
	_image_base_edit.text = LlmConfig.image_api_base
	_image_key_edit.text = LlmConfig.image_api_key
	_image_key_edit.secret = true
	_image_reveal_btn.text = "显示"
	_image_model_edit.text = LlmConfig.image_model
	_image_size_edit.text = LlmConfig.image_size
	_remove_bg_check.button_pressed = LlmConfig.image_remove_bg
	_msg.text = "Key 会存到 user://llm_config.cfg，不会写进游戏文件。"
	_settings_panel.visible = true


func _close_settings() -> void:
	_settings_panel.visible = false
	_refresh_hint()


func _on_save_settings() -> void:
	var mode := "llm" if _mode_opt.selected == 0 else "mock"
	if mode == "llm" and _key_edit.text.strip_edges() == "":
		_msg.text = "在线模式需要填写 API Key。"
		return
	var ok := LlmConfig.save_settings(mode, _base_edit.text, _key_edit.text, _model_edit.text)
	# 立绘是独立开关，即使文本走离线也允许单独开着；两边一次写盘，互不覆盖
	var image_mode := "api" if _image_mode_opt.selected == 0 else "off"
	if image_mode == "api" and _image_key_edit.text.strip_edges() == "":
		_msg.text = "开了 AI 立绘就得填生图 Key（也可以把立绘关掉）。"
		return
	ok = LlmConfig.save_image_settings(
		image_mode,
		PROVIDER_ORDER[clampi(_provider_opt.selected, 0, PROVIDER_ORDER.size() - 1)],
		_image_base_edit.text, _image_key_edit.text,
		_image_model_edit.text, _image_size_edit.text,
		_remove_bg_check.button_pressed) and ok
	if ok:
		_msg.text = "已保存，立即生效。"
	else:
		_msg.text = "保存失败：user:// 目录不可写。"


## 换平台时自动带出该平台的默认地址/模型/尺寸，省得玩家自己查文档
func _on_provider_selected(idx: int) -> void:
	if idx < 0 or idx >= PROVIDER_ORDER.size():
		return
	var preset: Dictionary = LlmConfig.IMAGE_PRESETS.get(PROVIDER_ORDER[idx], {})
	if preset.is_empty():
		return
	_image_base_edit.text = str(preset.get("base", ""))
	_image_model_edit.text = str(preset.get("model", ""))
	_image_size_edit.text = str(preset.get("size", ""))


## 立绘 Key 的显示/隐藏切换
func _toggle_image_key_visible() -> void:
	_image_key_edit.secret = not _image_key_edit.secret
	_image_reveal_btn.text = "显示" if _image_key_edit.secret else "隐藏"


## 点一下在「星号隐藏」和「明文显示」之间切换，方便核对 Key
func _toggle_key_visible() -> void:
	_key_edit.secret = not _key_edit.secret
	_reveal_btn.text = "显示" if _key_edit.secret else "隐藏"


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE):
		return
	if _goal_panel.visible:
		get_viewport().set_input_as_handled()
		_close_goal()
	elif _settings_panel.visible:
		get_viewport().set_input_as_handled()
		_close_settings()

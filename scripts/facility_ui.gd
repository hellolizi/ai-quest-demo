extends Control
## 功能性建筑界面（走近按 E 打开）。
##
## 界面全是代码搭的：内容随武器 / 材料 / 语言表变化，写成场景文件反而更麻烦。
##   锻造台：列出这个聚落品质档的 4 张图纸，花「金币 + 材料」造武器，造好直接装上。
##   商铺：村庄卖常见材料（便宜），城市卖全套材料 + 精锻成品武器（好货、更贵）。
##   客栈：住一晚回满血，并把这家客栈设成往后的复活点。
##   藏书阁：花金币学各文化圈的语言（学完就听得懂），另有只读的地点图鉴。
##   拍卖行：把多余的材料、备用武器换成金币（预设结局武器是主线信物，不回收）。
##   告示板 / 任务榜：以告示板的名义张榜招人，也接下板上挂着的委托、办完领赏。
##   药铺 / 医馆：花钱治伤；城里医馆出手更足，一次回满。
##   马厩 / 驿站：花钱雇脚力，把你送到别的聚落；城里驿站四通八达。
##   赌坊 / 竞技场：村口赌坊押大小碰运气，城里擂台比试赢彩头。

## 关闭时广播，main.gd 用来恢复状态（目前主要靠 PlayerProfile.ui_open）
signal closed
## 马厩 / 驿站要送玩家去别处：main.gd 收到后把玩家挪过去
signal travel_requested(dest: Vector2)

## 当前这座建筑的上下文：{kind, settlement_kind, name, pos, settlement_id, settlement_name, board_owner?}
var _ctx: Dictionary = {}

var _title: Label
var _gold: Label
var _list: VBoxContainer
var _status: Label
## 告示板正在等 QuestManager 出一张新的悬赏（联网生成时是异步的）
var _board_pending := false

## 客栈住一晚的价钱：城市更贵
const INN_PRICE := {"village": 15, "city": 30}
## 藏书阁学一门语言的价钱
const LEARN_LANGUAGE_PRICE := 100
## 药铺 / 医馆的价钱与效果：城里医馆一次回满，乡下药铺只回一小截
const CLINIC_PRICE := {"village": 12, "city": 30}
const CLINIC_HEAL := 40
## 马厩 / 驿站：按路程计钱，两头封顶
const STABLE_MIN_PRICE := 10
const STABLE_MAX_PRICE := 120
const STABLE_PRICE_PER_PX := 1.0 / 240.0
## 赌坊：押一注、赢了翻倍
const GAMBLE_BET := 10
const GAMBLE_WIN := 20
## 竞技场：报名费与彩头，胜算随攻击力涨
const ARENA_FEE := 40
const ARENA_PRIZE := 120
## 告示板：同时最多挂这么多委托；贴榜时以这个身份请 QuestManager 生成任务
const BOARD_MAX_OPEN := 3
const BOARD_ROLE := "委托发布人"
const BOARD_PERSONALITY := "公事公办，只认赏钱不认人"

## 地点图鉴里的类型显示名（没有的就直接显示 kind 原文）
const LOCATION_KIND_NAMES := {
	"village": "村庄", "city": "城市", "forest": "林地", "shrine": "神龛",
	"mill": "磨坊", "bridge": "桥", "ruin": "遗迹", "cave": "洞穴",
}


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false
	_build()
	PlayerProfile.gold_changed.connect(_on_gold_changed)
	# 告示板面板要跟着任务状态走：新张榜、接手、复命都得刷新板上的委托
	QuestManager.quest_generated.connect(_on_quest_changed)
	QuestManager.quest_accepted.connect(_on_quest_changed)
	QuestManager.quest_reached.connect(_on_quest_changed)
	QuestManager.quest_completed.connect(_on_quest_changed)


# ---------------------------------------------------------------- 开关

func open(info: Dictionary) -> void:
	_ctx = info
	visible = true
	PlayerProfile.ui_open = true
	_status.text = ""
	_rebuild()


func close() -> void:
	visible = false
	PlayerProfile.ui_open = false
	closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		close()


func _on_gold_changed(_amount: int) -> void:
	if visible:
		_gold.text = "金币：%d" % PlayerProfile.gold


## 任务状态变了：告示板正开着就重画一遍板上的委托
func _on_quest_changed(quest: Dictionary) -> void:
	var owner := str(_ctx.get("board_owner", ""))
	if owner != "" and str(quest.get("source_npc", "")) == owner:
		_board_pending = false
	if visible and str(_ctx.get("kind", "")) == "board":
		_rebuild()


# ---------------------------------------------------------------- 搭界面

func _build() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var panel := Panel.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(680, 520)
	panel.size = Vector2(680, 520)
	panel.position = Vector2(-340, -260)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel)

	_title = Label.new()
	_title.position = Vector2(24.0, 16.0)
	_title.add_theme_font_size_override("font_size", 22)
	panel.add_child(_title)

	_gold = Label.new()
	_gold.position = Vector2(24.0, 50.0)
	_gold.add_theme_color_override("font_color", Color(0.95, 0.85, 0.5))
	panel.add_child(_gold)

	var close_btn := Button.new()
	close_btn.text = "关闭 (Esc)"
	close_btn.position = Vector2(576.0, 18.0)
	close_btn.size = Vector2(84, 32)
	close_btn.pressed.connect(close)
	panel.add_child(close_btn)

	var scroll := ScrollContainer.new()
	scroll.position = Vector2(20.0, 86.0)
	scroll.size = Vector2(640, 390)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)

	_list = VBoxContainer.new()
	_list.custom_minimum_size = Vector2(620, 0)
	_list.add_theme_constant_override("separation", 8)
	scroll.add_child(_list)

	_status = Label.new()
	_status.position = Vector2(24.0, 484.0)
	_status.size = Vector2(640, 26)
	_status.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
	panel.add_child(_status)


# ---------------------------------------------------------------- 刷新

func _rebuild() -> void:
	if _list == null:
		return
	_clear_list()
	var kind := str(_ctx.get("kind", "forge"))
	var settle := str(_ctx.get("settlement_kind", "village"))
	var where := "城市" if settle == "city" else "村庄"
	var fac_name := str(_ctx.get("name", ""))
	_gold.text = "金币：%d" % PlayerProfile.gold
	match kind:
		"inn":
			_title.text = "客栈（%s）" % where
			_rebuild_inn(settle)
		"library":
			_title.text = "藏书阁（%s）" % where
			_rebuild_library()
		"auction":
			_title.text = "拍卖行（%s）" % where
			_rebuild_auction()
		"forge":
			_title.text = "锻造台（%s）" % where
			for w in WeaponData.forge_options(settle):
				_list.add_child(_weapon_row(w, settle, true))
		"board":
			_title.text = "%s（%s）" % [fac_name if fac_name != "" else "告示板", where]
			_rebuild_board(settle)
		"clinic":
			_title.text = "%s（%s）" % [fac_name if fac_name != "" else "药铺", where]
			_rebuild_clinic(settle)
		"stable":
			_title.text = "%s（%s）" % [fac_name if fac_name != "" else "马厩", where]
			_rebuild_stable(settle)
		"arena":
			_title.text = "%s（%s）" % [fac_name if fac_name != "" else "赌坊", where]
			_rebuild_arena(settle)
		_:
			_title.text = "商铺（%s）" % where
			for m in WeaponData.shop_materials(settle):
				_list.add_child(_material_row(m, settle))
			for w in WeaponData.shop_weapons(settle):
				_list.add_child(_weapon_row(w, settle, false))


## 清空列表。必须先 remove_child 再 queue_free：只 queue_free 的话旧节点要等到帧末才消失，
## 赶上信号触发的重建（例如告示板贴完榜）就会出现一帧新旧内容叠在一起。
func _clear_list() -> void:
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()


func _material_row(m: Dictionary, _settle: String) -> Control:
	var row := _row_frame()
	var icon := _icon(WeaponData.material_tag(str(m["id"])))
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 2)
	box.add_child(_label(str(m["name"]), 18, Color(0.95, 0.95, 0.95)))
	var price := int(m["price"])
	box.add_child(_label("价格：%d 金" % price, 14, Color(0.8, 0.82, 0.86)))
	row.add_child(icon)
	row.add_child(box)

	var btn := Button.new()
	btn.text = "购买"
	btn.custom_minimum_size = Vector2(88, 40)
	btn.disabled = PlayerProfile.gold < price
	btn.pressed.connect(_on_buy_material.bind(m))
	row.add_child(btn)
	return row


func _weapon_row(w: Dictionary, settle: String, is_forge: bool) -> Control:
	var row := _row_frame()
	var icon := _icon(str(w.get("icon_tag", "")))
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 2)
	box.add_child(_label(str(w.get("name", "?")), 18, Color(0.95, 0.95, 0.95)))
	box.add_child(_label(WeaponData.describe(w), 13, Color(0.72, 0.85, 0.95)))
	row.add_child(icon)
	row.add_child(box)

	var btn := Button.new()
	btn.text = "锻造" if is_forge else "购买"
	btn.custom_minimum_size = Vector2(88, 40)
	if is_forge:
		var cost := WeaponData.forge_cost(str(w.get("base_id", "")), settle)
		box.add_child(_label(_cost_text(cost), 13, Color(0.85, 0.8, 0.6)))
		btn.disabled = not _can_forge(cost)
		btn.pressed.connect(_on_forge.bind(w, cost))
	else:
		var price := int(w.get("price", 0))
		box.add_child(_label("价格：%d 金" % price, 13, Color(0.85, 0.8, 0.6)))
		btn.disabled = PlayerProfile.gold < price
		btn.pressed.connect(_on_buy_weapon.bind(w))
	row.add_child(btn)
	return row


# ---------------------------------------------------------------- 交易

func _cost_text(cost: Dictionary) -> String:
	var parts: Array[String] = ["花费：%d 金" % int(cost.get("gold", 0))]
	var mats: Dictionary = cost.get("materials", {})
	for mid in mats.keys():
		parts.append("%s×%d" % [WeaponData.material_name(str(mid)), int(mats[mid])])
	return "　".join(parts)


func _can_forge(cost: Dictionary) -> bool:
	if PlayerProfile.gold < int(cost.get("gold", 0)):
		return false
	var mats: Dictionary = cost.get("materials", {})
	for mid in mats.keys():
		if int(PlayerProfile.items.get(str(mid), 0)) < int(mats[mid]):
			return false
	return true


func _on_forge(w: Dictionary, cost: Dictionary) -> void:
	if not _can_forge(cost):
		_status.text = "金币或材料不够。"
		return
	PlayerProfile.spend_gold(int(cost.get("gold", 0)))
	var mats: Dictionary = cost.get("materials", {})
	for mid in mats.keys():
		PlayerProfile.remove_item(str(mid), int(mats[mid]))
	PlayerProfile.add_weapon(str(w["id"]))
	PlayerProfile.equip_weapon(str(w["id"]))
	_status.text = "锻造成功，已装备：%s" % str(w.get("name", ""))
	_rebuild()


func _on_buy_material(m: Dictionary) -> void:
	var price := int(m["price"])
	if not PlayerProfile.spend_gold(price):
		_status.text = "金币不够。"
		return
	PlayerProfile.add_item(str(m["id"]), 1)
	_status.text = "买下 %s ×1" % str(m["name"])
	_rebuild()


func _on_buy_weapon(w: Dictionary) -> void:
	var price := int(w.get("price", 0))
	if not PlayerProfile.spend_gold(price):
		_status.text = "金币不够。"
		return
	PlayerProfile.add_weapon(str(w["id"]))
	PlayerProfile.equip_weapon(str(w["id"]))
	_status.text = "买下并装备：%s" % str(w.get("name", ""))
	_rebuild()


# ---------------------------------------------------------------- 客栈

## 客栈只做一件事：住一晚。回满血，并把这家客栈设成往后的复活点。
func _rebuild_inn(settle: String) -> void:
	var price := int(INN_PRICE.get(settle, 15))

	var row := _row_frame()
	row.add_child(_icon(""))
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 2)
	box.add_child(_label("住一晚", 18, Color(0.95, 0.95, 0.95)))
	box.add_child(_label("价格：%d 金　回满生命，并把这里设为复活点" % price, 13, Color(0.85, 0.8, 0.6)))
	row.add_child(box)
	var btn := Button.new()
	btn.text = "住宿"
	btn.custom_minimum_size = Vector2(88, 40)
	btn.disabled = PlayerProfile.gold < price
	btn.pressed.connect(_on_stay.bind(price))
	row.add_child(btn)
	_list.add_child(row)

	var here := str(_ctx.get("name", "客栈"))
	_list.add_child(_hint_label("当前生命：%d / %d　当前落脚点：%s" % [
		PlayerProfile.hp, PlayerProfile.max_hp(),
		PlayerProfile.respawn_name if PlayerProfile.respawn_name != "" else "本乡出生点",
	]))
	_list.add_child(_hint_label("住下之后若在野外倒下，会在%s醒来。" % here))


func _on_stay(price: int) -> void:
	if not PlayerProfile.spend_gold(price):
		_status.text = "金币不够。"
		return
	PlayerProfile.heal(PlayerProfile.max_hp())
	var pos: Vector2 = _ctx.get("pos", Vector2.ZERO)
	PlayerProfile.set_respawn(pos + Vector2(0, 64), str(_ctx.get("name", "客栈")))
	_status.text = "一觉睡到天亮，生命已回满，这里成了你的落脚点。"
	_rebuild()


# ---------------------------------------------------------------- 藏书阁

## 藏书阁：上半是「学外语」，下半是「地点图鉴」（只读）。
func _rebuild_library() -> void:
	_list.add_child(_section_label("学外语"))
	var seen := {}
	for cid in CultureData.all_ids():
		var lang := CultureData.language_of_culture(cid)
		if lang == "" or seen.has(lang):
			continue
		seen[lang] = true
		if PlayerProfile.knows_language(lang):
			_list.add_child(_known_language_row(cid, lang))
		else:
			_list.add_child(_learn_language_row(cid, lang))

	_list.add_child(_section_label("地点图鉴"))
	for loc in WorldData.LOCATIONS:
		_list.add_child(_codex_row(loc))


func _learn_language_row(cid: String, lang: String) -> Control:
	var row := _row_frame()
	row.add_child(_icon(""))
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 2)
	box.add_child(_label("%s · %s" % [CultureData.culture_name_of(cid), CultureData.language_name_of(cid)], 18, Color(0.95, 0.95, 0.95)))
	box.add_child(_label("价格：%d 金　学会后听得懂此地人说话" % LEARN_LANGUAGE_PRICE, 13, Color(0.85, 0.8, 0.6)))
	row.add_child(box)
	var btn := Button.new()
	btn.text = "学习"
	btn.custom_minimum_size = Vector2(88, 40)
	btn.disabled = PlayerProfile.gold < LEARN_LANGUAGE_PRICE
	btn.pressed.connect(_on_learn_language.bind(cid, lang))
	row.add_child(btn)
	return row


func _known_language_row(cid: String, _lang: String) -> Control:
	var row := _row_frame()
	row.add_child(_icon(""))
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 2)
	box.add_child(_label("%s · %s" % [CultureData.culture_name_of(cid), CultureData.language_name_of(cid)], 18, Color(0.85, 0.9, 0.85)))
	box.add_child(_label("已掌握", 13, Color(0.6, 0.9, 0.6)))
	row.add_child(box)
	var tag := _label("已会", 15, Color(0.6, 0.9, 0.6))
	tag.custom_minimum_size = Vector2(88, 40)
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(tag)
	return row


func _codex_row(loc: Dictionary) -> Control:
	var row := _row_frame()
	row.add_child(_icon(""))
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 2)
	var kind := str(loc.get("kind", ""))
	box.add_child(_label("%s（%s）" % [str(loc.get("name", "")), str(LOCATION_KIND_NAMES.get(kind, kind))], 17, Color(0.95, 0.95, 0.95)))
	var desc := _label(str(loc.get("desc", "")), 13, Color(0.8, 0.82, 0.86))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(560, 0)
	box.add_child(desc)
	row.add_child(box)
	return row


func _on_learn_language(cid: String, lang: String) -> void:
	if not PlayerProfile.spend_gold(LEARN_LANGUAGE_PRICE):
		_status.text = "金币不够。"
		return
	PlayerProfile.learn_language(lang)
	_status.text = "在藏书阁翻书，学会了%s（%s）。" % [CultureData.language_name_of(cid), CultureData.language_name(lang)]
	_rebuild()


# ---------------------------------------------------------------- 拍卖行

## 拍卖行：收多余的材料与备用武器，换成金币。
## 预设结局武器是主线信物（sell_weapon_price 返回 0），装备中的也不许卖。
func _rebuild_auction() -> void:
	_list.add_child(_section_label("材料"))
	var any_material := false
	for mid in WeaponData.all_material_ids():
		var count := int(PlayerProfile.items.get(mid, 0))
		if count <= 0:
			continue
		any_material = true
		_list.add_child(_sell_material_row(mid, count))
	if not any_material:
		_list.add_child(_hint_label("身上没有可以出手的材料。"))

	_list.add_child(_section_label("武器"))
	var any_weapon := false
	for wid in PlayerProfile.owned_weapons:
		var price := WeaponData.sell_weapon_price(wid)
		if price <= 0:
			continue
		any_weapon = true
		_list.add_child(_sell_weapon_row(wid, price, wid == PlayerProfile.equipped_weapon))
	if not any_weapon:
		_list.add_child(_hint_label("没有可以出手的备用武器（装备中的和主线信物都不回收）。"))


func _sell_material_row(mid: String, count: int) -> Control:
	var price := WeaponData.sell_material_price(mid)
	var row := _row_frame()
	row.add_child(_icon(WeaponData.material_tag(mid)))
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 2)
	box.add_child(_label("%s ×%d" % [WeaponData.material_name(mid), count], 18, Color(0.95, 0.95, 0.95)))
	box.add_child(_label("收购价：%d 金 / 个" % price, 13, Color(0.85, 0.8, 0.6)))
	row.add_child(box)

	var btn := Button.new()
	btn.text = "卖 1"
	btn.custom_minimum_size = Vector2(78, 40)
	btn.pressed.connect(_on_sell_material.bind(mid, 1))
	row.add_child(btn)
	if count > 1:
		var all_btn := Button.new()
		all_btn.text = "全卖"
		all_btn.custom_minimum_size = Vector2(78, 40)
		all_btn.pressed.connect(_on_sell_material.bind(mid, count))
		row.add_child(all_btn)
	return row


func _sell_weapon_row(wid: String, price: int, equipped: bool) -> Control:
	var w := WeaponData.get_weapon(wid)
	var row := _row_frame()
	row.add_child(_icon(str(w.get("icon_tag", ""))))
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 2)
	box.add_child(_label("%s%s" % [str(w.get("name", wid)), "（装备中）" if equipped else ""], 18, Color(0.95, 0.95, 0.95)))
	box.add_child(_label("%s　收购价：%d 金" % [WeaponData.describe(w), price], 13, Color(0.85, 0.8, 0.6)))
	row.add_child(box)

	var btn := Button.new()
	btn.text = "卖出"
	btn.custom_minimum_size = Vector2(78, 40)
	btn.disabled = equipped
	btn.pressed.connect(_on_sell_weapon.bind(wid, price))
	row.add_child(btn)
	return row


func _on_sell_material(mid: String, count: int) -> void:
	var have := int(PlayerProfile.items.get(mid, 0))
	if count <= 0 or have <= 0:
		return
	count = mini(count, have)
	if not PlayerProfile.remove_item(mid, count):
		return
	var gain := WeaponData.sell_material_price(mid) * count
	PlayerProfile.add_gold(gain)
	_status.text = "卖出 %s ×%d，进账 %d 金。" % [WeaponData.material_name(mid), count, gain]
	_rebuild()


func _on_sell_weapon(wid: String, price: int) -> void:
	if not PlayerProfile.remove_weapon(wid):
		_status.text = "这件不能出手（装备中的和主线信物都不回收）。"
		return
	PlayerProfile.add_gold(price)
	var w := WeaponData.get_weapon(wid)
	_status.text = "卖出「%s」，进账 %d 金。" % [str(w.get("name", wid)), price]
	_rebuild()


# ---------------------------------------------------------------- 告示板 / 任务榜

## 告示板（村）/ 任务榜（城）：这里是「委托发布人」自己的板子。
## 玩家可以在这块板上张榜请人办事（以板子的名义让 QuestManager 生成任务），
## 也可以接下板上挂着的委托，办完回来领赏。
func _rebuild_board(_settle: String) -> void:
	var owner := _board_owner()
	_list.add_child(_hint_label("这块板子挂在「%s」名下，专发那些只认赏钱、不认人的活计。" % owner))
	var open_quests := _board_open_quests(owner)
	_list.add_child(_section_label("板上的委托（%d / %d）" % [open_quests.size(), BOARD_MAX_OPEN]))
	if open_quests.is_empty():
		_list.add_child(_hint_label("板上空空如也，眼下没有贴出来的委托。"))
	for q in open_quests:
		_list.add_child(_board_quest_row(q))

	var row := _row_frame()
	row.add_child(_icon(""))
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 2)
	box.add_child(_label("贴一张悬赏", 18, Color(0.95, 0.95, 0.95)))
	box.add_child(_label("以告示板的名义张榜招人，赏钱由公中出。", 13, Color(0.85, 0.8, 0.6)))
	row.add_child(box)
	var btn := Button.new()
	btn.text = "张榜"
	btn.custom_minimum_size = Vector2(88, 40)
	btn.disabled = open_quests.size() >= BOARD_MAX_OPEN or _board_pending
	btn.pressed.connect(_on_post_bounty)
	row.add_child(btn)
	_list.add_child(row)


func _board_owner() -> String:
	return str(_ctx.get("board_owner", ""))


## 这块板上还没了结的委托（含没接的、接了没办完的；办完复命后就从板上撤下）
func _board_open_quests(owner: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if owner == "":
		return out
	for q in QuestManager.quests:
		if str(q.get("source_npc", "")) == owner and not bool(q.get("completed", false)):
			out.append(q)
	return out


func _board_quest_row(q: Dictionary) -> Control:
	var row := _row_frame()
	row.add_child(_icon(""))
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 2)
	box.add_child(_label(str(q.get("title", "委托")), 18, Color(0.95, 0.95, 0.95)))
	var desc := _label(str(q.get("description", "")), 13, Color(0.8, 0.82, 0.86))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(420, 0)
	box.add_child(desc)
	var reward := 0
	var rewards: Variant = q.get("rewards", {})
	if typeof(rewards) == TYPE_DICTIONARY:
		reward = int(rewards.get("gold", 0))
	box.add_child(_label("赏钱：%d 金　目标：%s" % [
		reward, WorldData.name_of(str(q.get("target_location", ""))),
	], 13, Color(0.85, 0.8, 0.6)))
	row.add_child(box)

	if not bool(q.get("accepted", false)):
		var btn := Button.new()
		btn.text = "接下"
		btn.custom_minimum_size = Vector2(88, 40)
		btn.pressed.connect(_on_accept_bounty.bind(q))
		row.add_child(btn)
	elif bool(q.get("reached", false)):
		var btn := Button.new()
		btn.text = "领赏"
		btn.custom_minimum_size = Vector2(88, 40)
		btn.pressed.connect(_on_report_bounty.bind(q))
		row.add_child(btn)
	else:
		var tag := _label("进行中", 15, Color(0.9, 0.8, 0.5))
		tag.custom_minimum_size = Vector2(88, 40)
		tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(tag)
	return row


func _on_post_bounty() -> void:
	var owner := _board_owner()
	if owner == "" or _board_pending or _board_open_quests(owner).size() >= BOARD_MAX_OPEN:
		return
	_board_pending = true
	QuestManager.request_quest(owner, BOARD_ROLE, BOARD_PERSONALITY)
	_status.text = "你把一张悬赏贴上了板子，等有人来揭。"
	_rebuild()


func _on_accept_bounty(q: Dictionary) -> void:
	QuestManager.accept_quest(q)
	_status.text = "你揭了「%s」这张榜。" % str(q.get("title", "委托"))


func _on_report_bounty(q: Dictionary) -> void:
	if QuestManager.report_quest(q, BOARD_ROLE, BOARD_PERSONALITY):
		_status.text = "你把办成的凭据交回板上，领了赏钱。"
	else:
		_status.text = "这件事还没办完，领不了赏。"


# ---------------------------------------------------------------- 药铺 / 医馆

## 药铺（村）：花小钱回一小截血。医馆（城）：花多点钱直接回满。
func _rebuild_clinic(settle: String) -> void:
	var city := settle == "city"
	var price := int(CLINIC_PRICE.get(settle, 12))
	if city:
		_list.add_child(_hint_label("城里医馆的大夫手稳药足，一剂下去就能把人治好。"))
	else:
		_list.add_child(_hint_label("乡下药铺货色有限，只能抓副药缓一缓伤势。"))

	var row := _row_frame()
	row.add_child(_icon(""))
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 2)
	box.add_child(_label("诊治" if city else "抓药", 18, Color(0.95, 0.95, 0.95)))
	box.add_child(_label("价格：%d 金　%s" % [
		price, "回满生命" if city else "回复 %d 点生命" % CLINIC_HEAL,
	], 13, Color(0.85, 0.8, 0.6)))
	row.add_child(box)
	var btn := Button.new()
	btn.text = "诊治" if city else "抓药"
	btn.custom_minimum_size = Vector2(88, 40)
	btn.disabled = PlayerProfile.gold < price or PlayerProfile.hp >= PlayerProfile.max_hp()
	btn.pressed.connect(_on_clinic.bind(price, city))
	row.add_child(btn)
	_list.add_child(row)

	_list.add_child(_hint_label("当前生命：%d / %d" % [PlayerProfile.hp, PlayerProfile.max_hp()]))


func _on_clinic(price: int, city: bool) -> void:
	if not PlayerProfile.spend_gold(price):
		_status.text = "金币不够。"
		return
	PlayerProfile.heal(PlayerProfile.max_hp() if city else CLINIC_HEAL)
	_status.text = "一剂药下去，浑身轻快了不少。" if city else "抓了副药，伤势缓和了些。"
	_rebuild()


# ---------------------------------------------------------------- 马厩 / 驿站

## 马厩（村）：只有几匹脚力，能把你送回本乡。驿站（城）：四通八达，哪个聚落都能去。
## 车马钱按路程算，两头封顶。
func _rebuild_stable(settle: String) -> void:
	var city := settle == "city"
	var from_id := str(_ctx.get("settlement_id", ""))
	if city:
		_list.add_child(_hint_label("驿站备着快马，跑一趟按路程计钱，远近的聚落都送得到。"))
	else:
		_list.add_child(_hint_label("乡下马厩只有几匹脚力，能把你送回本乡。"))
	_list.add_child(_section_label("可去之处"))
	var any := false
	for loc in _travel_destinations(settle, from_id):
		_list.add_child(_travel_row(loc))
		any = true
	if not any:
		_list.add_child(_hint_label("眼下没有别的去处。"))


## 可去的聚落：驿站能去所有村庄与城市（除自己所在的那座），马厩只回本乡。
func _travel_destinations(settle: String, from_id: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for loc in WorldData.LOCATIONS:
		var kind := str(loc.get("kind", ""))
		if kind != "village" and kind != "city":
			continue
		if typeof(loc.get("pos", null)) != TYPE_VECTOR2:
			continue
		var lid := str(loc.get("id", ""))
		if lid == from_id:
			continue
		if settle != "city" and lid != "village":
			continue
		out.append(loc)
	return out


func _travel_row(loc: Dictionary) -> Control:
	var to_pos: Vector2 = loc["pos"]
	var from_pos: Vector2 = _ctx.get("pos", Vector2.ZERO)
	var dist := from_pos.distance_to(to_pos)
	var price := _travel_price(dist)

	var row := _row_frame()
	row.add_child(_icon(""))
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 2)
	box.add_child(_label(str(loc.get("name", "")), 18, Color(0.95, 0.95, 0.95)))
	box.add_child(_label("路程约 %d 里　车马钱：%d 金" % [int(dist / 20.0), price], 13, Color(0.85, 0.8, 0.6)))
	row.add_child(box)
	var btn := Button.new()
	btn.text = "前往"
	btn.custom_minimum_size = Vector2(88, 40)
	btn.disabled = PlayerProfile.gold < price
	btn.pressed.connect(_on_travel.bind(to_pos + Vector2(0, 70), price))
	row.add_child(btn)
	return row


## 车马钱：底价 + 每 240 像素 1 金，上下封顶
func _travel_price(dist: float) -> int:
	var raw := STABLE_MIN_PRICE + int(dist * STABLE_PRICE_PER_PX)
	return clampi(raw, STABLE_MIN_PRICE, STABLE_MAX_PRICE)


func _on_travel(dest: Vector2, price: int) -> void:
	if not PlayerProfile.spend_gold(price):
		_status.text = "金币不够。"
		return
	travel_requested.emit(dest)
	close()


# ---------------------------------------------------------------- 赌坊 / 竞技场

## 赌坊（村）：押一注，赢了一赔二，全看手气。
## 竞技场（城）：交报名费上台比试，胜算随攻击力涨，赢了拿一笔彩头。
func _rebuild_arena(settle: String) -> void:
	var city := settle == "city"
	var row := _row_frame()
	row.add_child(_icon(""))
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 2)
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(88, 40)
	if city:
		_list.add_child(_hint_label("竞技场的擂台上，赢了有彩头，输了报名钱就打了水漂。"))
		box.add_child(_label("上台比试", 18, Color(0.95, 0.95, 0.95)))
		box.add_child(_label("报名：%d 金　胜算约 %d%%　赢了得 %d 金" % [
			ARENA_FEE, int(round(_arena_win_chance() * 100.0)), ARENA_PRIZE,
		], 13, Color(0.85, 0.8, 0.6)))
		btn.text = "报名"
		btn.disabled = PlayerProfile.gold < ARENA_FEE
		btn.pressed.connect(_on_arena)
	else:
		_list.add_child(_hint_label("赌坊里就一张骰桌，押大押小，全凭手气。"))
		box.add_child(_label("押一把", 18, Color(0.95, 0.95, 0.95)))
		box.add_child(_label("押注：%d 金　赢了得 %d 金" % [GAMBLE_BET, GAMBLE_WIN], 13, Color(0.85, 0.8, 0.6)))
		btn.text = "押注"
		btn.disabled = PlayerProfile.gold < GAMBLE_BET
		btn.pressed.connect(_on_gamble)
	row.add_child(box)
	row.add_child(btn)
	_list.add_child(row)
	_list.add_child(_hint_label("当前生命：%d / %d" % [PlayerProfile.hp, PlayerProfile.max_hp()]))


## 擂台胜算：攻击力越高越有把握，但总留着一两成翻车的余地
func _arena_win_chance() -> float:
	var atk := float(PlayerProfile.attack_power())
	return clampf(atk / (atk + 14.0), 0.2, 0.85)


func _on_gamble() -> void:
	if not PlayerProfile.spend_gold(GAMBLE_BET):
		_status.text = "金币不够。"
		return
	if randi() % 2 == 0:
		PlayerProfile.add_gold(GAMBLE_WIN)
		_status.text = "骰盅一开，你押中了，赢了 %d 金。" % GAMBLE_WIN
	else:
		_status.text = "骰盅一开，押错了，输掉 %d 金。" % GAMBLE_BET
	_rebuild()


func _on_arena() -> void:
	if not PlayerProfile.spend_gold(ARENA_FEE):
		_status.text = "金币不够。"
		return
	if randf() < _arena_win_chance():
		PlayerProfile.add_gold(ARENA_PRIZE)
		_status.text = "擂台上你撑到了最后，夺得彩头 %d 金。" % ARENA_PRIZE
	else:
		_status.text = "对手技高一筹，你败下阵来，报名钱打了水漂。"
	_rebuild()


# ---------------------------------------------------------------- 小零件

func _section_label(text: String) -> Label:
	return _label(text, 16, Color(0.95, 0.85, 0.5))


func _hint_label(text: String) -> Label:
	return _label(text, 14, Color(0.6, 0.62, 0.68))

## 一行的底板：横向排布 icon + 文字 + 按钮，自绘圆角底色。
## 用自绘而不是 PanelContainer，是因为 PanelContainer 会把每个直接子节点都撑满整块，
## 里面的图标/文字/按钮会全叠在一起。
class RowBox extends HBoxContainer:
	var bg: StyleBoxFlat
	var _pad_r: Control
	var _fixing := false

	func _init() -> void:
		add_theme_constant_override("separation", 12)
		# 左右各留一段空白当内边距（自绘 stylebox 的 content margin 对子节点无效）
		var pad_l := Control.new()
		pad_l.custom_minimum_size = Vector2(10, 0)
		pad_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(pad_l)
		_pad_r = Control.new()
		_pad_r.custom_minimum_size = Vector2(10, 0)
		_pad_r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_pad_r)
		child_entered_tree.connect(_on_child_entered)
		resized.connect(queue_redraw)

	func _notification(what: int) -> void:
		# 子节点多半是在这一行还没进场景树时就加进来的，那时 child_entered_tree 不会响，
		# 所以再挂一条「子节点顺序变了」的通知来兜底。
		if what == NOTIFICATION_CHILD_ORDER_CHANGED:
			call_deferred("_fixup_all")

	func _on_child_entered(_node: Node) -> void:
		call_deferred("_fixup_all")

	## 子节点在交叉轴上居中，别被拉伸成整行高；右内边距永远排在最末。
	func _fixup_all() -> void:
		if _fixing or _pad_r == null or not is_instance_valid(_pad_r):
			return
		_fixing = true
		for c in get_children():
			if c != _pad_r and c is Control:
				(c as Control).size_flags_vertical = Control.SIZE_SHRINK_CENTER
		if _pad_r.get_index() != get_child_count() - 1:
			move_child(_pad_r, get_child_count() - 1)
		_fixing = false

	func _draw() -> void:
		if bg != null:
			draw_style_box(bg, Rect2(Vector2.ZERO, size))


func _row_frame() -> HBoxContainer:
	var row := RowBox.new()
	row.custom_minimum_size = Vector2(620, 74)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.13, 0.16, 0.9)
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	row.bg = style
	return row


func _icon(tag: String) -> TextureRect:
	var tr := TextureRect.new()
	tr.custom_minimum_size = Vector2(56, 56)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	if tag != "":
		tr.texture = RewardLibrary.get_texture(tag)
	return tr


func _label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l

extends Control
## 左上角 HUD：玩家的详细状态（生命 / 金币 / 武器 / 路程 / 任务 / 伴侣 / 语言）。
## 按 H 才展开这块状态栏（默认收起，免得挡住地图上的东西）。
## 玩家走近某个 NPC 时，右上方额外亮出一块简略的 NPC 状态栏（名字 / 身份 / 关系）。
## 按 I 轮换已拥有的武器（含空手），换完立刻能在「武器」一行看到数值变化。

const BG := Color(0.07, 0.08, 0.11, 0.66)

## 玩家面板（按 H 开关）
var _player_panel: Panel
var _gold_text: Label
var _weapon_text: Label
var _dist_text: Label
var _quest_text: Label
var _spouse_text: Label
var _lang_text: Label
var _hp_bar: ProgressBar
var _hp_text: Label
var _bar_fill: StyleBoxFlat

## NPC 面板（玩家靠近某人才显示）
var _npc_panel: Panel
var _npc_name_text: Label
var _npc_role_text: Label
var _npc_rel_text: Label
var _npc_extra_text: Label
## 当前盯着的 NPC（玩家在谁的交互范围里）；没有就是 null
var _npc: Node = null

var _toast: Label
var _toast_timer := 0.0


func _ready() -> void:
	anchors_preset = Control.PRESET_TOP_LEFT
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_build_player_panel()
	_build_npc_panel()

	# 拾取 / 奖励提示条：平时藏着，弹出来几秒后自动淡出（由 main.gd 调用 toast()）
	_toast = _label(self, Vector2(16, 214), 15, Color(1.0, 0.93, 0.66))
	_toast.size = Vector2(440, 30)
	_toast.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_toast.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_toast.add_theme_constant_override("outline_size", 6)
	_toast.visible = false

	PlayerProfile.hp_changed.connect(_refresh_hp)
	PlayerProfile.gold_changed.connect(_refresh_gold)
	PlayerProfile.weapon_changed.connect(_refresh_weapon)
	_refresh_hp(PlayerProfile.hp, PlayerProfile.max_hp())
	_refresh_gold(PlayerProfile.gold)
	_refresh_weapon(PlayerProfile.equipped_weapon)
	_refresh_profile()


## 左上：玩家详细状态面板（默认收起，按 H 展开）
func _build_player_panel() -> void:
	var panel := Panel.new()
	panel.position = Vector2(16, 16)
	panel.size = Vector2(340, 190)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", _panel_style())
	panel.visible = false
	_player_panel = panel
	add_child(panel)

	var title := _label(panel, Vector2(14, 8), 14, Color(0.85, 0.86, 0.92))
	title.text = "生命"

	_hp_bar = ProgressBar.new()
	_hp_bar.position = Vector2(14, 30)
	_hp_bar.size = Vector2(312, 20)
	_hp_bar.show_percentage = false
	_hp_bar.min_value = 0.0
	_hp_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg_sb := StyleBoxFlat.new()
	bg_sb.bg_color = Color(0.20, 0.11, 0.12)
	bg_sb.set_corner_radius_all(4)
	_bar_fill = StyleBoxFlat.new()
	_bar_fill.bg_color = Color(0.76, 0.24, 0.24)
	_bar_fill.set_corner_radius_all(4)
	_hp_bar.add_theme_stylebox_override("background", bg_sb)
	_hp_bar.add_theme_stylebox_override("fill", _bar_fill)
	panel.add_child(_hp_bar)

	_hp_text = _label(panel, Vector2(14, 30), 13, Color(1, 1, 1, 0.9))
	_hp_text.size = Vector2(312, 20)
	_hp_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hp_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

	_gold_text = _label(panel, Vector2(14, 56), 14, Color(0.95, 0.83, 0.42))
	_weapon_text = _label(panel, Vector2(14, 78), 13, Color(0.78, 0.85, 1.0))
	_dist_text = _label(panel, Vector2(14, 100), 13, Color(0.80, 0.88, 0.82))
	_quest_text = _label(panel, Vector2(14, 122), 13, Color(0.86, 0.80, 0.96))
	_spouse_text = _label(panel, Vector2(14, 144), 13, Color(0.98, 0.72, 0.80))
	_lang_text = _label(panel, Vector2(14, 166), 13, Color(0.78, 0.90, 0.94))


## 右上：NPC 简略状态面板（默认隐藏，玩家靠近某人才显示）
func _build_npc_panel() -> void:
	_npc_panel = Panel.new()
	_npc_panel.position = Vector2(368, 16)
	_npc_panel.size = Vector2(320, 108)
	_npc_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_npc_panel.add_theme_stylebox_override("panel", _panel_style())
	_npc_panel.visible = false
	add_child(_npc_panel)

	_npc_name_text = _label(_npc_panel, Vector2(14, 8), 15, Color(0.96, 0.90, 0.70))
	_npc_role_text = _label(_npc_panel, Vector2(14, 34), 13, Color(0.80, 0.82, 0.88))
	_npc_rel_text = _label(_npc_panel, Vector2(14, 60), 13, Color(0.80, 0.90, 0.82))
	_npc_extra_text = _label(_npc_panel, Vector2(14, 84), 13, Color(0.90, 0.78, 0.84))
	_npc_extra_text.size = Vector2(292, 20)
	_npc_extra_text.clip_text = true


func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = BG
	sb.set_corner_radius_all(8)
	return sb


func _label(parent: Node, pos: Vector2, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.position = pos
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


# ---------------------------------------------------------------- NPC 状态栏

## 玩家走进某个 NPC 的交互范围：亮出他的简略状态栏
func set_npc_focus(npc: Node) -> void:
	_npc = npc
	if _npc_panel != null:
		_npc_panel.visible = true
	_refresh_npc()


## 玩家离开：收起 NPC 状态栏
func clear_npc_focus() -> void:
	_npc = null
	if _npc_panel != null:
		_npc_panel.visible = false


## 当前盯着的 NPC（供 main.gd 判断「走远的是不是他本人」）
func npc_focus() -> Node:
	return _npc


func _refresh_npc() -> void:
	if _npc == null or not is_instance_valid(_npc):
		clear_npc_focus()
		return
	var name: String = str(_npc.npc_name)
	var role: String = str(_npc.npc_role)
	_npc_name_text.text = name
	_npc_role_text.text = "身份  %s" % role
	_npc_rel_text.text = NpcMemory.label_of(name)
	if PlayerProfile.spouse == name:
		_npc_extra_text.text = "与你结为伴侣"
		_npc_extra_text.add_theme_color_override("font_color", Color(0.98, 0.72, 0.80))
		return
	var imp := NpcMemory.impression(name)
	if imp.strip_edges() == "":
		imp = "还没什么交情"
	elif imp.length() > 16:
		imp = imp.substr(0, 16) + "…"
	_npc_extra_text.text = "印象  %s" % imp
	_npc_extra_text.add_theme_color_override("font_color", Color(0.86, 0.86, 0.90))


# ---------------------------------------------------------------- 提示条

## 弹一条提示（拾取 / 奖励 / 系统消息）。文字会盖住旧的一条，几秒后自动淡出。
func toast(text: String) -> void:
	if _toast == null:
		return
	_toast.text = text
	_toast.modulate.a = 1.0
	_toast.visible = true
	_toast_timer = 3.2


func _process(delta: float) -> void:
	# 路程 / 任务 / 伴侣 / 语言这几项没有信号，逐帧读一遍保持最新
	_refresh_profile()
	if _npc != null and is_instance_valid(_npc):
		_refresh_npc()

	if _toast_timer <= 0.0:
		return
	_toast_timer -= delta
	if _toast_timer <= 0.8:
		_toast.modulate.a = maxf(0.0, _toast_timer / 0.8)
	if _toast_timer <= 0.0:
		_toast.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if PlayerProfile.ui_open:
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if event.keycode == KEY_I:
		get_viewport().set_input_as_handled()
		_cycle_weapon()
	elif event.keycode == KEY_H:
		get_viewport().set_input_as_handled()
		toggle()


## 展开 / 收起左上角那块玩家状态栏（默认收起，免得挡住地图）
func toggle() -> void:
	if _player_panel != null:
		_player_panel.visible = not _player_panel.visible


## 在「已拥有的武器 + 空手」之间轮换
func _cycle_weapon() -> void:
	var list := PlayerProfile.owned_weapons
	if list.is_empty():
		return
	var idx := list.find(PlayerProfile.equipped_weapon) + 1
	if idx >= list.size():
		PlayerProfile.equip_weapon("")
	else:
		PlayerProfile.equip_weapon(str(list[idx]))


func _refresh_hp(hp: int, mx: int) -> void:
	_hp_bar.max_value = maxi(1, mx)
	_hp_bar.value = hp
	_hp_text.text = "%d / %d" % [hp, mx]
	# 血量越低条越红，一眼看得出危险
	var ratio := float(hp) / float(maxi(1, mx))
	_bar_fill.bg_color = Color(0.76, 0.24 + 0.28 * (1.0 - ratio), 0.22)


func _refresh_gold(amount: int) -> void:
	_gold_text.text = "金币  %d" % amount


func _refresh_weapon(id: String) -> void:
	var atk := PlayerProfile.attack_power()
	if id == "":
		_weapon_text.text = "武器  空手 · 攻击 %d（按 I 换）" % atk
		return
	var w = WeaponData.get_weapon(id)
	var nm := id
	if typeof(w) == TYPE_DICTIONARY:
		nm = str(w.get("name", id))
	_weapon_text.text = "武器  %s · 攻击 %d（按 I 换）" % [nm, atk]


## 逐帧刷新：路程 / 任务进度 / 伴侣 / 语言
func _refresh_profile() -> void:
	if _dist_text == null:
		return
	_dist_text.text = "路程  %d 米" % PlayerProfile.distance_m()
	_quest_text.text = "任务  进行中 %d · 已完成 %d" % [
		QuestManager.active_quests().size(), PlayerProfile.quests_completed,
	]
	if PlayerProfile.is_married():
		_spouse_text.text = "伴侣  %s" % PlayerProfile.spouse
	else:
		_spouse_text.text = "伴侣  未婚"
	var lang_text := "语言  %s" % CultureData.language_name(PlayerProfile.native_language)
	if PlayerProfile.native_language == "":
		lang_text = "语言  未定"
	var learned := PlayerProfile.known_languages.size()
	if learned > 0:
		lang_text += " · 另通 %d 门" % learned
	_lang_text.text = lang_text

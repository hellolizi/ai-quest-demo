extends Control
## 任务完成提示条（右下角）
##
## 复命交差那一刻弹出：任务名 + 每条奖励的图标、名字、数量，停几秒后淡出。
## 图标没画好（没开生图 Key / 还在画）就先显示一个占位方块（奖励名首字），
## 图一入库 RewardLibrary 会广播 changed，这里立刻把占位换成真图。
##
## 整个界面是代码搭的——内容完全由奖励条目决定，写成场景反而更麻烦。

## 图标方块边长
const CARD := 46.0
## 停留秒数（淡出前）
const HOLD := 4.0
## 淡出时长
const FADE := 0.6

@onready var _box: PanelContainer = $Box
@onready var _title: Label = $Box/Margin/Rows/Title
@onready var _quest: Label = $Box/Margin/Rows/QuestTitle
@onready var _items: VBoxContainer = $Box/Margin/Rows/Items

## 本次要展示的奖励条目（来自 RewardLibrary.items_of_rewards）
var _rows: Array = []
var _quest_title := ""
var _hide := 0.0


func _ready() -> void:
	_box.visible = false
	_box.modulate.a = 0.0
	_style()
	_title.add_theme_font_size_override("font_size", 15)
	_title.add_theme_color_override("font_color", Color(1.0, 0.86, 0.42))
	_quest.add_theme_color_override("font_color", Color(0.8, 0.83, 0.88))
	QuestManager.quest_generated.connect(_prewarm)
	QuestManager.quest_accepted.connect(_prewarm)
	QuestManager.quest_completed.connect(_on_completed)
	RewardLibrary.changed.connect(_refresh_icons)


func _style() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.1, 0.12, 0.92)
	sb.set_corner_radius_all(10)
	sb.set_border_width_all(1)
	sb.border_color = Color(1.0, 1.0, 1.0, 0.14)
	sb.set_content_margin_all(0.0)
	_box.add_theme_stylebox_override("panel", sb)


# ---------------------------------------------------------------- 预热

## 任务一生成 / 一接受，就先把奖励图标排上队画，等复命时大概率已经有图了
func _prewarm(quest: Dictionary) -> void:
	for it in RewardLibrary.items_of_rewards(quest.get("rewards", {})):
		RewardIconGenerator.request(str(it.get("text", "")))


# ---------------------------------------------------------------- 完成弹条

func _on_completed(quest: Dictionary) -> void:
	_quest_title = str(quest.get("title", "任务"))
	_rows = RewardLibrary.items_of_rewards(quest.get("rewards", {}))
	# 顺手再请求一次，确保该画的都在队列里
	for it in _rows:
		RewardIconGenerator.request(str(it.get("text", "")))
	_rebuild()
	_show()


func _show() -> void:
	_box.visible = true
	var tw := create_tween()
	tw.tween_property(_box, "modulate:a", 1.0, 0.25)
	_hide = HOLD


func _process(delta: float) -> void:
	if not _box.visible or _hide <= 0.0:
		return
	_hide -= delta
	if _hide > 0.0:
		return
	var tw := create_tween()
	tw.tween_property(_box, "modulate:a", 0.0, FADE)
	tw.tween_callback(func() -> void: _box.visible = false)


## 某张图标刚入库：把占位换成真图
func _refresh_icons() -> void:
	if _box.visible:
		_rebuild()


# ---------------------------------------------------------------- 搭行

func _rebuild() -> void:
	if _items == null:
		return
	for c in _items.get_children():
		c.queue_free()
	_quest.text = _quest_title
	if _rows.is_empty():
		var lbl := Label.new()
		lbl.text = "奖励已发放"
		_items.add_child(lbl)
		return
	for it in _rows:
		_items.add_child(_make_row(it))


func _make_row(it: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var text := str(it.get("text", ""))
	var amount := int(it.get("amount", 0))
	var tag := RewardLibrary.resolve(text)
	if tag == "":
		tag = RewardLibrary.canonical_tag(text)
	row.add_child(_make_icon(RewardLibrary.get_texture(tag), text))

	var col := VBoxContainer.new()
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.add_theme_constant_override("separation", 0)
	var name_lbl := Label.new()
	name_lbl.text = text
	col.add_child(name_lbl)
	if amount > 0:
		var amt := Label.new()
		amt.text = "×%d" % amount
		amt.add_theme_color_override("font_color", Color(0.85, 0.78, 0.5))
		col.add_child(amt)
	row.add_child(col)
	return row


func _make_icon(tex: Texture2D, text: String) -> Control:
	var box := Panel.new()
	box.custom_minimum_size = Vector2(CARD, CARD)
	box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.17, 0.2, 0.9)
	sb.set_corner_radius_all(8)
	sb.set_border_width_all(1)
	sb.border_color = Color(1.0, 1.0, 1.0, 0.12)
	box.add_theme_stylebox_override("panel", sb)
	if tex != null:
		var tr := TextureRect.new()
		tr.texture = tex
		tr.set_anchors_preset(Control.PRESET_FULL_RECT)
		tr.offset_left = 3.0
		tr.offset_top = 3.0
		tr.offset_right = -3.0
		tr.offset_bottom = -3.0
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		box.add_child(tr)
	else:
		var ph := Label.new()
		ph.text = text.substr(0, 1) if text != "" else "?"
		ph.set_anchors_preset(Control.PRESET_FULL_RECT)
		ph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		ph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		ph.add_theme_color_override("font_color", Color(0.9, 0.9, 0.95, 0.7))
		box.add_child(ph)
	return box

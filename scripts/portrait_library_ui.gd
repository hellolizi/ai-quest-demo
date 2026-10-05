extends Control
## 立绘库（游戏里按 P 打开）
##
## 把 AI 画过的每一张立绘摆出来，玩家可以逐张「采用 / 停用」：
##   停用 = 游戏里立刻看不到这张图（换回程序化小人），但文件原封不动留在硬盘上，
##          以后想用随时点「启用」回来。
## 「重画」会给这个人重新生成一张（会覆盖掉旧图）。
## 「补齐缺少的立绘」把还没画出来 / 被停用的那些一次排队重画。
##
## 界面全是代码搭的——内容完全由库里有多少张图决定，写成场景文件反而更麻烦。

## 每张卡的宽度
const CARD_W := 150.0
## 缩略图高度
const THUMB_H := 130.0

var _grid: GridContainer
var _stats: Label
var _empty: Label


func _ready() -> void:
	visible = false
	_build()
	PortraitLibrary.changed.connect(_rebuild)
	PortraitGenerator.queue_changed.connect(_update_stats)


# ---------------------------------------------------------------- 开关

func open() -> void:
	visible = true
	# 打开界面时锁住玩家移动（跟对话、任务日志一个机制）
	PlayerProfile.ui_open = true
	_rebuild()


func close() -> void:
	visible = false
	PlayerProfile.ui_open = false


func toggle() -> void:
	if visible:
		close()
	else:
		open()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	# 打开时 PlayerProfile.ui_open 为 true，main.gd 会拦掉 P，所以这里自己也要能关
	if event.keycode == KEY_ESCAPE or event.keycode == KEY_P:
		get_viewport().set_input_as_handled()
		close()


# ---------------------------------------------------------------- 搭界面

func _build() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var panel := Panel.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 56.0
	panel.offset_top = 34.0
	panel.offset_right = -56.0
	panel.offset_bottom = -34.0
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel)

	var title := Label.new()
	title.text = "立绘库"
	title.add_theme_font_size_override("font_size", 22)
	title.position = Vector2(20.0, 14.0)
	panel.add_child(title)

	_stats = Label.new()
	_stats.position = Vector2(20.0, 48.0)
	_stats.add_theme_color_override("font_color", Color(0.78, 0.8, 0.84))
	panel.add_child(_stats)

	var refill := Button.new()
	refill.text = "补齐缺少的立绘"
	refill.tooltip_text = "把还没画出来、以及被停用的人物一次排队重画（重画会替换旧图）"
	refill.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	refill.offset_left = -300.0
	refill.offset_top = 16.0
	refill.offset_right = -110.0
	refill.offset_bottom = 48.0
	refill.pressed.connect(_on_refill)
	panel.add_child(refill)

	var close_btn := Button.new()
	close_btn.text = "关闭 (Esc)"
	close_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	close_btn.offset_left = -100.0
	close_btn.offset_top = 16.0
	close_btn.offset_right = -20.0
	close_btn.offset_bottom = 48.0
	close_btn.pressed.connect(close)
	panel.add_child(close_btn)

	var hint := Label.new()
	hint.text = "停用的立绘只是不在游戏里显示，文件仍留在：%s" % PortraitLibrary.dir_path()
	hint.add_theme_color_override("font_color", Color(0.62, 0.64, 0.7))
	hint.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	hint.offset_left = 20.0
	hint.offset_top = -30.0
	hint.offset_right = -20.0
	hint.offset_bottom = -8.0
	panel.add_child(hint)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.offset_left = 20.0
	scroll.offset_top = 80.0
	scroll.offset_right = -20.0
	scroll.offset_bottom = -40.0
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)

	_grid = GridContainer.new()
	_grid.columns = 5
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", 12)
	_grid.add_theme_constant_override("v_separation", 12)
	scroll.add_child(_grid)

	_empty = Label.new()
	_empty.text = "还没有任何立绘。\n\n在设置里填好生图平台的 Key 并开启「AI 立绘」，进游戏后每个人的立绘会自动生成。"
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.set_anchors_preset(Control.PRESET_FULL_RECT)
	_empty.offset_top = 80.0
	_empty.offset_bottom = -40.0
	_empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(_empty)


# ---------------------------------------------------------------- 刷新

func _rebuild() -> void:
	if _grid == null:
		return
	for c in _grid.get_children():
		c.queue_free()
	var tags := PortraitLibrary.all_tags()
	tags.sort()
	for tag in tags:
		var t := str(tag)
		_grid.add_child(_make_card(t))
	_empty.visible = tags.is_empty()
	_update_stats()


func _update_stats() -> void:
	if _stats == null:
		return
	var parts: Array[String] = [
		"共 %d 张" % PortraitLibrary.total_count(),
		"采用 %d 张" % PortraitLibrary.enabled_count(),
		"停用 %d 张" % PortraitLibrary.disabled_count(),
	]
	var missing := PortraitGenerator.missing_count()
	if missing > 0:
		parts.append("还差 %d 张没画" % missing)
	var pending := PortraitGenerator.pending_count()
	if pending > 0:
		parts.append("正在画 %d 张…" % pending)
	_stats.text = "　·　".join(parts)


func _make_card(tag: String) -> Control:
	var entry := PortraitLibrary.get_entry(tag)
	var enabled := PortraitLibrary.is_enabled(tag)

	var card := VBoxContainer.new()
	card.custom_minimum_size = Vector2(CARD_W, 0.0)
	card.add_theme_constant_override("separation", 4)

	var thumb := TextureRect.new()
	thumb.custom_minimum_size = Vector2(CARD_W, THUMB_H)
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumb.texture = PortraitLibrary.get_texture(tag)
	# 停用的图压暗，一眼看出「这张没在用」
	thumb.modulate = Color(1.0, 1.0, 1.0, 1.0) if enabled else Color(0.45, 0.45, 0.5, 0.8)
	card.add_child(thumb)

	var name_lbl := Label.new()
	name_lbl.text = "%s（%s）" % [str(entry.get("name", "?")), str(entry.get("role", ""))]
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_lbl.custom_minimum_size = Vector2(CARD_W, 0.0)
	card.add_child(name_lbl)

	var state := Label.new()
	state.text = "已采用" if enabled else "已停用（游戏里不显示）"
	state.add_theme_color_override(
		"font_color", Color(0.55, 0.85, 0.55) if enabled else Color(0.85, 0.6, 0.6)
	)
	card.add_child(state)

	var row := HBoxContainer.new()
	var toggle := Button.new()
	toggle.text = "停用" if enabled else "启用"
	toggle.tooltip_text = "停用后游戏里就看不到这张立绘了，文件仍然保留"
	toggle.pressed.connect(func() -> void: PortraitLibrary.set_enabled(tag, not enabled))
	row.add_child(toggle)

	var redraw := Button.new()
	redraw.text = "重画"
	redraw.disabled = not PortraitGenerator.is_on()
	redraw.tooltip_text = "重新生成一张（会替换掉这张旧图）" if PortraitGenerator.is_on() else "需要先在设置里开启 AI 立绘"
	redraw.pressed.connect(func() -> void: PortraitGenerator.regenerate(tag))
	row.add_child(redraw)
	card.add_child(row)

	return card


func _on_refill() -> void:
	var n := PortraitGenerator.refill()
	if n <= 0:
		_stats.text = "没有需要补齐的立绘。"

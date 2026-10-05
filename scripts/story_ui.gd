extends Control
## 主线界面：按 J 开关。
## 平时显示当前章节（开头 + 本章目标 + 三条进度）；
## 走到结局时改成显示结局，并给一个「再走一程」的按钮开新一轮。

@onready var _title: Label = $Panel/Title
@onready var _text: RichTextLabel = $Panel/Text
@onready var _close_btn: Button = $Panel/Buttons/CloseBtn
@onready var _cycle_btn: Button = $Panel/Buttons/CycleBtn


func _ready() -> void:
	visible = false
	_close_btn.pressed.connect(close)
	_cycle_btn.pressed.connect(_on_cycle_pressed)
	StoryDirector.chapter_started.connect(_on_chapter_started)
	StoryDirector.chapter_completed.connect(_on_story_changed)
	StoryDirector.ending_reached.connect(_on_ending_reached)
	StoryDirector.story_changed.connect(_on_story_changed)
	refresh()
	# 读档回来的情况：StoryDirector 的状态在主场景 _ready 之前就填好了，
	# 那次 chapter_started 信号我们没听到，所以这里按状态自己弹一次。
	if StoryDirector.chapter > 0:
		_popup()


func toggle() -> void:
	if visible:
		close()
	else:
		_popup()


func close() -> void:
	visible = false
	PlayerProfile.ui_open = false


func _popup() -> void:
	visible = true
	PlayerProfile.ui_open = true
	refresh()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		# 界面开着时 ui_open 是 true，main.gd 不再接管键盘，所以这里的 J 得自己收
		if event.keycode == KEY_ESCAPE or event.keycode == KEY_J:
			get_viewport().set_input_as_handled()
			close()


func _on_chapter_started(_chapter: Dictionary) -> void:
	_popup()


func _on_ending_reached(_ending: Dictionary) -> void:
	_popup()


func _on_story_changed(_arg = null) -> void:
	if visible:
		refresh()


func _on_cycle_pressed() -> void:
	StoryDirector.begin_new_cycle()


# ---------------------------------------------------------------- 显示

func refresh() -> void:
	if StoryDirector.finished and not StoryDirector.ending.is_empty():
		_render_ending(StoryDirector.ending)
		return
	_cycle_btn.visible = false
	if StoryDirector.chapter <= 0 or StoryDirector.chapter_data.is_empty():
		_title.text = "主线"
		_text.text = "[i]故事还没开始。[/i]"
		return
	_render_chapter(StoryDirector.chapter_data)


func _render_chapter(chapter: Dictionary) -> void:
	_title.text = str(chapter.get("title", "主线"))
	var lines: PackedStringArray = []
	# 这一轮走的是哪条主线弧、现在到第几幕（一章正对一幕）
	var arc := StoryDirector.arc_title()
	var act := str(chapter.get("act", "")).strip_edges()
	var fi := StoryDirector.current_final_index()
	if arc != "" or act != "" or fi >= 0:
		var head := ""
		if arc != "":
			head = "主线《%s》" % _escape(arc)
		if fi >= 0:
			if head != "":
				head += "　"
			head += "终局 · 第 %d 站（%s）" % [fi + 1, _escape(str(chapter.get("name", "")))]
		elif act != "":
			if head != "":
				head += "　"
			head += "第 %d 幕（%s）" % [int(chapter.get("index", 0)), _escape(act)]
		lines.append("[color=#f0d27a]%s[/color]" % head)
		var beat := str(chapter.get("beat", "")).strip_edges()
		if beat != "":
			lines.append("[color=gray][i]%s[/i][/color]" % _escape(beat))
		lines.append("")
	var intro := str(chapter.get("intro", "")).strip_edges()
	if intro == "":
		lines.append("[i]……[/i]")
	else:
		lines.append(_escape(intro))
	var goal := StoryDirector.goal_summary()
	if goal != "":
		lines.append("")
		lines.append("[color=#f0d27a]奔向的结局：%s[/color]" % _escape(goal))
	# 终极目标与「最后一程」三站的推进：去哪、见谁、走到没走到
	if StoryDirector.has_ultimate_goal():
		lines.append("")
		lines.append("[color=#f0d27a]终极目标《%s》[/color]" % _escape(StoryDirector.ultimate_goal_title()))
		var gdesc := StoryDirector.ultimate_goal_desc()
		if gdesc != "":
			lines.append("[color=gray]%s[/color]" % _escape(gdesc))
		var steps := StoryDirector.ultimate_steps()
		var cur := StoryDirector.current_final_index()
		for i in range(steps.size()):
			if typeof(steps[i]) != TYPE_DICTIONARY:
				continue
			var st: Dictionary = steps[i]
			var st_done := bool(st.get("done", false))
			var mark := "[color=#8fd18f]✓[/color]" if st_done else ("[color=#f0d27a]→[/color]" if i == cur else "[color=gray]·[/color]")
			var who := str(st.get("npc_name", ""))
			var tail := "，见 %s" % _escape(who) if who != "" else ""
			lines.append("  %s 第 %d 站 %s：往%s约 %d 米，到%s%s" % [
				mark, i + 1, _escape(str(st.get("name", ""))),
				_escape(str(st.get("direction", ""))), int(st.get("distance_m", 0)),
				_escape(str(st.get("location_name", ""))), tail,
			])
	lines.append("")
	lines.append("[b]本章目标[/b]  %s" % _escape(str(chapter.get("goal", ""))))
	lines.append("")
	lines.append("[b]本章促成的事[/b]")
	if StoryDirector.milestones.is_empty():
		lines.append("  [color=gray]还没有——去替村里人办成一件托付你的事。[/color]")
	else:
		for m in StoryDirector.milestones:
			if typeof(m) == TYPE_DICTIONARY:
				lines.append("  [color=#8fd18f]✓[/color] %s" % _escape(_milestone_line(m)))
	lines.append("")
	lines.append("[b]进度[/b]")
	for row in StoryDirector.progress_rows():
		var mark := "[color=#8fd18f]✓[/color]" if bool(row["done"]) else "[color=gray]·[/color]"
		lines.append("  %s %s：%d / %d" % [
			mark, str(row["label"]), int(row["now"]), int(row["need"]),
		])
	lines.append("")
	lines.append("[color=gray]按 J 随时看主线；把上面这几样做齐，故事就往下走一章。[/color]")
	_text.text = "\n".join(lines)


## 一条里程碑的短描述，如「去溪边跑一趟（委托人 阿岩 · 溪边）」
func _milestone_line(m: Dictionary) -> String:
	var title := str(m.get("title", "")).strip_edges()
	var npc := str(m.get("npc", "")).strip_edges()
	var place := str(m.get("place", "")).strip_edges()
	var tail: PackedStringArray = []
	if npc != "":
		tail.append("委托人 %s" % npc)
	if place != "":
		tail.append(place)
	if tail.is_empty():
		return title
	return "%s（%s）" % [title, " · ".join(tail)]


func _render_ending(ending: Dictionary) -> void:
	_title.text = "结局 · %s" % str(ending.get("title", ""))
	_cycle_btn.visible = true
	var lines: PackedStringArray = []
	lines.append("[color=#f0d27a]【%s】[/color]" % _escape(str(ending.get("type_name", ""))))
	lines.append("")
	lines.append(_escape(str(ending.get("text", ""))))
	var epilogue := str(ending.get("epilogue", "")).strip_edges()
	if epilogue != "":
		lines.append("")
		lines.append("[i]%s[/i]" % _escape(epilogue))
	# 结局武器：走完这条线拿到的唯一一把武器（预设 = 对应那把；现代结局 = 现造的枪械）
	var wid := str(ending.get("weapon_id", ""))
	var w := WeaponData.get_weapon(wid)
	if not w.is_empty():
		lines.append("")
		lines.append("[color=#f0d27a][b]获得武器：《%s》[/b][/color]（%s）" % [
			_escape(str(w.get("name", ""))), _escape(str(w.get("kind", ""))),
		])
		lines.append("[color=#8fd18f]%s[/color]" % _escape(WeaponData.describe(w)))
		lines.append("[color=gray]已经装备在身上了。[/color]")
	# 把这一程走过的章节列出来，让结局跟玩家真正走过的那条线对得上
	if not StoryDirector.chapter_log.is_empty():
		lines.append("")
		lines.append("[b]这一程走过的路[/b]")
		for entry in StoryDirector.chapter_log:
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			var e: Dictionary = entry
			var ms: Array = e.get("milestones", [])
			var tail := "（促成 %d 件事）" % ms.size() if not ms.is_empty() else ""
			lines.append("  · %s%s" % [_escape(str(e.get("title", ""))), tail])
	lines.append("")
	lines.append("[color=gray]按「再走一程」，故事从第一章重新开始——世界和你走过的路都还在。[/color]")
	_text.text = "\n".join(lines)


func _escape(text: String) -> String:
	return text.replace("[", "[lb]")

extends Control
## 任务日志：按 Q 开关，列出所有已经生成的任务。

@onready var _text: RichTextLabel = $Panel/Text


func _ready() -> void:
	visible = false
	QuestManager.quest_generated.connect(_on_quest_changed)
	QuestManager.quest_accepted.connect(_on_quest_changed)
	QuestManager.quest_reached.connect(_on_quest_changed)
	QuestManager.quest_completed.connect(_on_quest_changed)
	QuestManager.tracked_changed.connect(_on_quest_changed)
	refresh()


func toggle() -> void:
	visible = not visible
	if visible:
		refresh()


func _on_quest_changed(_quest: Dictionary) -> void:
	if visible:
		refresh()


func refresh() -> void:
	if QuestManager.quests.is_empty():
		_text.text = "[i]暂无任务。去和 NPC 聊聊，问问他们有什么要帮忙的。[/i]"
		return

	var tracked_id := str(QuestManager.tracked_quest.get("id", ""))
	var lines: PackedStringArray = []
	if QuestManager.active_quests().size() > 1:
		lines.append("[color=gray]身上有好几件任务：按 T 切换左上角的导航目标。[/color]")
		lines.append("")
	for quest in QuestManager.quests:
		var status: String
		if quest.get("completed", false):
			status = "[color=#8fd18f]已完成[/color]"
		elif quest.get("reached", false):
			status = "[color=#6fe3a0]待复命[/color]"
		elif quest.get("accepted", false):
			status = "[color=#f0d27a]进行中[/color]"
		else:
			status = "[color=gray]未接受[/color]"
		# 当前导航指向的那件任务加个 ▶ 标记，和左上角 HUD 对应
		var is_tracked := tracked_id != "" and str(quest.get("id", "")) == tracked_id
		var mark := "[color=#f0d27a]▶[/color] " if is_tracked else ""
		if is_tracked:
			status += "  [color=#f0d27a]（导航中）[/color]"
		lines.append("%s[b]%s[/b]  [color=gray](%s)[/color]  %s" % [
			mark,
			quest.get("title", "未命名"),
			quest.get("type", "side"),
			status,
		])
		lines.append("目标地点：%s" % WorldData.name_of(str(quest.get("target_location", ""))))
		lines.append(str(quest.get("description", "")))
		if quest.has("fits_profile_because"):
			lines.append("[color=#7f9dff]生成理由：%s[/color]" % quest["fits_profile_because"])
		lines.append("")
		_text.text = "\n".join(lines)

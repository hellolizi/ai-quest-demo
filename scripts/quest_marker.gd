extends Node2D
## 任务标记：在地图上「当前追踪任务」的目标地点上方显示一个上下浮动的箭头。
## 身上有多件任务时，标记跟着按 T 切换的追踪目标走。

@onready var _visual: Node2D = $Visual

var _t := 0.0


func _ready() -> void:
	visible = false
	QuestManager.tracked_changed.connect(_on_tracked_changed)
	# 读档进来时可能已经有一件追踪中的任务
	_on_tracked_changed(QuestManager.tracked_quest)


## 追踪目标变了：把标记挪到目标地点；事情办完了就改指委托人
func _on_tracked_changed(quest: Dictionary) -> void:
	if quest.is_empty():
		visible = false
		return
	if bool(quest.get("reached", false)):
		var npc_name := str(quest.get("source_npc", ""))
		var npc_pos = NpcMemory.position_of(npc_name) if npc_name != "" else null
		if npc_pos == null:
			visible = false
			return
		global_position = npc_pos
		$Visual/Name.text = "找%s复命" % npc_name
	else:
		var id := str(quest.get("target_location", ""))
		if not WorldData.has_id(id):
			visible = false
			return
		global_position = WorldData.by_id(id)["pos"]
		$Visual/Name.text = WorldData.name_of(id)
	_t = 0.0
	visible = true


func _process(delta: float) -> void:
	if not visible:
		return
	_t += delta
	_visual.position.y = -110.0 + sin(_t * 3.0) * 12.0

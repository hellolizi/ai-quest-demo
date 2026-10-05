extends Control
## 任务导航 HUD：跟着「当前追踪的那件任务」走，显示目标地点、方位箭头和距离。
## 箭头直接由 _draw() 按角度画出来，因此不依赖任何美术资源。
## 身上有多件任务时，按 T 可以在它们之间轮换追踪目标（见 QuestManager.cycle_tracked）。

const PX_PER_METER := 20.0
const ARROW_CENTER := Vector2(318, 100)

@onready var _panel: Panel = $Panel
@onready var _title: Label = $Panel/Title
@onready var _target: Label = $Panel/Target
@onready var _distance: Label = $Panel/Distance

var _player: Node2D = null
var _angle := 0.0
## 事办完了、等玩家回委托人那里复命
var _reached := false
## 正在显示「已完成 + 奖励」的那几秒，这期间不跟着追踪目标变化
var _flash := false
var _hide_countdown := 0.0


func _ready() -> void:
	_panel.visible = false
	QuestManager.tracked_changed.connect(_on_tracked_changed)
	QuestManager.quest_completed.connect(_on_quest_completed)
	# 读档进来时可能已经有一件追踪中的任务，这里补一次初始化
	_on_tracked_changed(QuestManager.tracked_quest)


## 追踪目标变了（接受新任务、按 T 切换、事情办完改指委托人）：整体刷新面板
func _on_tracked_changed(quest: Dictionary) -> void:
	if _flash:
		return
	if quest.is_empty():
		_panel.visible = false
		return
	_reached = bool(quest.get("reached", false))
	if _reached:
		_title.text = "待复命：%s" % str(quest.get("title", "任务"))
	else:
		_title.text = "进行中：%s" % str(quest.get("title", "未命名任务"))
	var label := QuestManager.tracked_label()
	_target.text = label if label != "" else "目标地点：未知"
	_distance.text = "距离：—"
	_panel.visible = true
	queue_redraw()


## 任务完成：显示一小段「已完成 + 奖励」，箭头消失，几秒后再跟回追踪目标
func _on_quest_completed(quest: Dictionary) -> void:
	_flash = true
	_reached = false
	_title.text = "已完成：%s" % quest.get("title", "任务")
	_target.text = _reward_text(quest)
	_distance.text = ""
	_hide_countdown = 4.0
	_panel.visible = true
	queue_redraw()


func _reward_text(quest: Dictionary) -> String:
	var rewards = quest.get("rewards", {})
	var parts: PackedStringArray = []
	if typeof(rewards) == TYPE_DICTIONARY:
		for key in rewards:
			parts.append("%s: %s" % [key, str(rewards[key])])
	if parts.is_empty():
		return "奖励已发放"
	return "奖励已发放  " + ", ".join(parts)


func _process(delta: float) -> void:
	if not _panel.visible:
		return
	if _flash:
		_hide_countdown -= delta
		if _hide_countdown <= 0.0:
			_flash = false
			# 几秒后再跟回当前追踪的任务（没有就隐藏面板）
			_on_tracked_changed(QuestManager.tracked_quest)
		return
	var target = QuestManager.tracked_position()
	if target == null:
		return
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player")
		if _player == null:
			return
	var to_target: Vector2 = target - _player.global_position
	_angle = to_target.angle()
	_distance.text = "距离：%d 米（%s）" % [
		int(to_target.length() / PX_PER_METER),
		_compass(to_target),
	]
	queue_redraw()


func _draw() -> void:
	if not _panel.visible or _flash:
		return
	# 箭头基础形状朝向 +X（正东），按当前角度旋转
	var base := PackedVector2Array([
		Vector2(16, 0), Vector2(-10, 13), Vector2(-4, 0), Vector2(-10, -13),
	])
	var points := PackedVector2Array()
	for p in base:
		points.append(ARROW_CENTER + p.rotated(_angle))
	# 待复命时箭头转成绿色，和「去找目标」的黄色区分开
	var color := Color(0.45, 0.95, 0.55) if _reached else Color(1.0, 0.85, 0.35)
	draw_colored_polygon(points, color)


## 把方向转成中文方位。注意屏幕坐标 y 轴向下，所以 +y 是「南」。
func _compass(v: Vector2) -> String:
	if v.length() < 20.0:
		return "已经到达"
	var names := ["东", "东南", "南", "西南", "西", "西北", "北", "东北"]
	var idx := int(round(v.angle() / (PI / 4.0))) % 8
	if idx < 0:
		idx += 8
	return names[idx]

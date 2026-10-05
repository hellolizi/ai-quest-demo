extends Area2D
## 宝箱交互区：玩家站进去会出提示，按 E 开启。
##
## 它只管「谁站在跟前、有没有按 E」；发什么奖励、记不记账由 main.gd 监听 opened 后决定。
## 通天福地里的几口宝箱都挂一个——福地的「物资多到数不清」就靠它们兑现。

## 有玩家按了 E。info 里带着这口箱子的身份（见 setup）。
signal opened(info: Dictionary)

## 完整身份信息：{id, pos, name}
var info: Dictionary = {}

var _player_in_range := false
var _opened := false
var _prompt: Label


## 塞进这口箱子的属性（加入场景树之前调用即可）
func setup(chest_info: Dictionary) -> void:
	info = chest_info


func _ready() -> void:
	monitorable = false
	# 这口箱子开过没有：读 WorldState 里的开关，读档回来也不会又变成满的
	_opened = bool(WorldState.flag(_flag_key(), false))
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 56.0
	shape.shape = circle
	shape.position = Vector2(0.0, 6.0)
	add_child(shape)
	_prompt = Label.new()
	_prompt.text = "已开启" if _opened else "按 E 开启"
	_prompt.size = Vector2(160, 28)
	_prompt.position = Vector2(-80, 44)
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.add_theme_font_size_override("font_size", 18)
	_prompt.add_theme_color_override("font_color", Color(1.0, 0.94, 0.72))
	_prompt.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_prompt.add_theme_constant_override("outline_size", 5)
	_prompt.z_index = 20
	_prompt.visible = false
	add_child(_prompt)
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _flag_key() -> String:
	return "tianfu_chest_%s" % str(info.get("id", ""))


func _on_body_entered(body: Node2D) -> void:
	if body.name == "Player":
		_player_in_range = true
		_prompt.visible = true


func _on_body_exited(body: Node2D) -> void:
	if body.name == "Player":
		_player_in_range = false
		_prompt.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if _opened or not _player_in_range or PlayerProfile.ui_open:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_E:
		get_viewport().set_input_as_handled()
		_opened = true
		if _prompt != null:
			_prompt.text = "已开启"
		opened.emit(info)

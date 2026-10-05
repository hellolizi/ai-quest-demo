extends Area2D
## 房屋门口：玩家站到门前这一小圈里会冒出提示，按 E 请求进屋。
##
## 每栋房子盖的时候都会在门的位置挂一个。它只管「谁站在门口、有没有按 E」，
## 真正切到室内场景由 main.gd 监听 enter_requested 后来做。

## 有玩家在门口按了 E。info 里带着这栋房的全部身份（见 setup）。
signal enter_requested(info: Dictionary)

## 门所在的世界坐标（即这栋房在地面上的锚点）
var house_pos := Vector2.ZERO
## 交给室内场景的信息：{bid, cid, spec, pos}
var info: Dictionary = {}

var _player_in_range := false
var _prompt: Label


## 塞进这栋房的身份信息（加入场景树之前调用即可）
func setup(house_info: Dictionary) -> void:
	info = house_info


func _ready() -> void:
	monitorable = false
	# 门前那一小圈：玩家一踏进来就出提示
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 30.0
	shape.shape = circle
	shape.position = Vector2(0.0, 14.0)
	add_child(shape)
	# 提示牌放在门前的地面上，免得压住房子本身
	_prompt = Label.new()
	_prompt.text = "按 E 进入"
	_prompt.size = Vector2(160, 28)
	_prompt.position = Vector2(-80, 38)
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.add_theme_font_size_override("font_size", 18)
	_prompt.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	_prompt.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_prompt.add_theme_constant_override("outline_size", 5)
	_prompt.z_index = 20
	_prompt.visible = false
	add_child(_prompt)
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _on_body_entered(body: Node2D) -> void:
	if body.name == "Player":
		_player_in_range = true
		_prompt.visible = true


func _on_body_exited(body: Node2D) -> void:
	if body.name == "Player":
		_player_in_range = false
		_prompt.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if not _player_in_range or PlayerProfile.ui_open:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_E:
		get_viewport().set_input_as_handled()
		enter_requested.emit(info)

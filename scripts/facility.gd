extends Area2D
## 功能性建筑（锻造台 / 商铺）的交互区：玩家站进去会出提示，按 E 请求使用。
##
## 每座村子 / 城市的地标建好后都会挂一个。它只管「谁站在跟前、有没有按 E」，
## 真正打开界面、扣钱扣料由 main.gd 监听 use_requested 后来做。

## 有玩家按了 E。info 里带着这座功能建筑的全部身份（见 setup）。
signal use_requested(info: Dictionary)

## 功能类型：
##   "forge" 锻造台 / "shop" 商铺 / "inn" 客栈 / "library" 藏书阁 / "auction" 拍卖行
##   "board" 告示板 / "clinic" 药铺 / "stable" 马厩 / "arena" 赌坊
var kind := "forge"
## 所在聚落类型："village" 村 / "city" 城（决定价格与品质）
var settlement_kind := "village"
## 完整身份信息：{kind, settlement_kind, pos, name, settlement_id, settlement_name, board_owner?}
var info: Dictionary = {}

var _player_in_range := false
var _prompt: Label


## 塞进这座建筑的属性（加入场景树之前调用即可）
func setup(facility_info: Dictionary) -> void:
	info = facility_info
	kind = str(facility_info.get("kind", kind))
	settlement_kind = str(facility_info.get("settlement_kind", settlement_kind))


func _ready() -> void:
	monitorable = false
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 42.0
	shape.shape = circle
	shape.position = Vector2(0.0, 18.0)
	add_child(shape)
	_prompt = Label.new()
	match kind:
		"forge": _prompt.text = "按 E 锻造"
		"shop": _prompt.text = "按 E 购买"
		"inn": _prompt.text = "按 E 住宿"
		"library": _prompt.text = "按 E 查阅"
		"auction": _prompt.text = "按 E 交易"
		"board": _prompt.text = "按 E 接委托" if settlement_kind == "city" else "按 E 看告示"
		"clinic": _prompt.text = "按 E 诊治" if settlement_kind == "city" else "按 E 抓药"
		"stable": _prompt.text = "按 E 传驿" if settlement_kind == "city" else "按 E 牵马"
		"arena": _prompt.text = "按 E 比试" if settlement_kind == "city" else "按 E 下注"
		_: _prompt.text = "按 E 使用"
	_prompt.size = Vector2(160, 28)
	_prompt.position = Vector2(-80, 40)
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
		use_requested.emit(info)

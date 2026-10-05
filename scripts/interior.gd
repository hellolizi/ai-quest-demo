extends Node2D
## 室内场景：进屋时由 main.gd 现搭出来的一间（或两间）屋子。
##
## 房间多大、有没有二层，全部来自这栋房的规格（PropLibrary.house_spec）：
##   room   —— 房间像素尺寸，大房子室内大、小房子室内小
##   floors —— 1 或 2，高房子多一层，靠楼梯上下
## 四壁都是真碰撞体，把玩家关在屋里；门口画一扇门，站过去按 E 出去。
## 两层不在同一个位置：二层整体往上挪一大截单独摆，互不遮挡、碰撞也不会打架。

signal exit_requested()

const WALL := 18.0            # 墙厚
const DOOR_GAP := 84.0        # 门在墙上占的宽度
const ROOM_PAD := 1400.0      # 楼层之间隔开多远
const STAIR_INSET := 96.0     # 楼梯离屋角多远

const C_FLOOR := Color(0.44, 0.33, 0.21)
const C_FLOOR_LINE := Color(0.35, 0.26, 0.16)
const C_WALL := Color(0.27, 0.20, 0.14)
const C_WALL_EDGE := Color(0.17, 0.12, 0.08)
const C_DOOR := Color(0.30, 0.21, 0.13)
const C_RUG := Color(0.52, 0.25, 0.22)
const C_RUG2 := Color(0.28, 0.38, 0.46)
const C_FURN := Color(0.48, 0.35, 0.22)
const C_WOOD := Color(0.40, 0.28, 0.17)
const C_WOOD_LIGHT := Color(0.56, 0.41, 0.26)
const C_BED := Color(0.70, 0.66, 0.58)
const C_METAL := Color(0.44, 0.46, 0.49)
const C_PAPER := Color(0.86, 0.82, 0.68)
const C_FIRE := Color(0.86, 0.46, 0.18)
const C_STAIR := Color(0.42, 0.35, 0.26)

## 玩家一进门要站的位置（门内侧，室内局部坐标）
var spawn_pos := Vector2.ZERO

var _room := Vector2(520, 420)
var _floors := 1
var _player: Node2D = null
var _hotspots: Array = []
var _active_hotspot: Dictionary = {}


## main.gd 在 build 之前先指明玩家是谁，楼梯才知道该把谁挪上楼
func set_player(p: Node2D) -> void:
	_player = p


## 按这栋房的规格把屋子搭出来。info 里带 spec（体量/层数/房间尺寸）。
func build(info: Dictionary) -> void:
	var spec: Dictionary = info.get("spec", {})
	_room = spec.get("room", Vector2(520, 420))
	_floors = int(spec.get("floors", 1))
	_build_level(0)
	if _floors >= 2:
		_build_level(1)
	# 进门站在门内侧一点，别一进来就踩在门口那圈反复触发
	spawn_pos = Vector2(0.0, _room.y * 0.5 - 96.0)


# ---------------------------------------------------------------- 单层房间

## 往某个节点里塞一块纯色矩形（地板、墙、家具都用它拼）
func _rect(parent: Node2D, rect: Rect2, color: Color, z: int) -> Polygon2D:
	var quad := PackedVector2Array([
		rect.position,
		rect.position + Vector2(rect.size.x, 0.0),
		rect.position + rect.size,
		rect.position + Vector2(0.0, rect.size.y),
	])
	var node := Polygon2D.new()
	node.polygon = quad
	node.color = color
	node.z_index = z
	parent.add_child(node)
	return node


func _build_level(index: int) -> void:
	var level := Node2D.new()
	level.name = "Floor%d" % (index + 1)
	level.position = Vector2(0.0, -float(index) * (_room.y + ROOM_PAD))
	add_child(level)
	var half := _room * 0.5
	_draw_floor(level, half)
	_build_walls(level, half)
	_draw_furniture(level, half, index)
	if index == 0:
		_draw_door(level, half)
		_add_hotspot(level, Vector2(0.0, half.y - 34.0), 46.0, "按 E 出去", func(): exit_requested.emit())
	if _floors >= 2:
		var stair_pos := Vector2(half.x - STAIR_INSET, -half.y + STAIR_INSET)
		_draw_stair(level, stair_pos)
		if index == 0:
			_add_hotspot(level, stair_pos, 48.0, "按 E 上楼", func(): _go_floor(1))
		else:
			_add_hotspot(level, stair_pos, 48.0, "按 E 下楼", func(): _go_floor(0))


func _draw_floor(level: Node2D, half: Vector2) -> void:
	_rect(level, Rect2(-half, _room), C_FLOOR, -20)
	# 地板木纹：横着铺几道细线，免得地面是一整块死板纯色
	var step := 48.0
	var count := int(_room.y / step)
	for i in range(1, count):
		var y := -half.y + i * step
		var line := Line2D.new()
		line.points = PackedVector2Array([Vector2(-half.x, y), Vector2(half.x, y)])
		line.width = 2.0
		line.default_color = C_FLOOR_LINE
		line.z_index = -19
		level.add_child(line)


## 四面墙：都是真碰撞体，把玩家关在屋里；门只是画在墙上的装饰，墙上不留缺口。
func _build_walls(level: Node2D, half: Vector2) -> void:
	var w := _room.x + WALL * 2.0
	var h := _room.y + WALL * 2.0
	_wall(level, Rect2(-half.x - WALL, -half.y - WALL, w, WALL))          # 上
	_wall(level, Rect2(-half.x - WALL, half.y, w, WALL))                  # 下
	_wall(level, Rect2(-half.x - WALL, -half.y - WALL, WALL, h))          # 左
	_wall(level, Rect2(half.x, -half.y - WALL, WALL, h))                  # 右


func _wall(level: Node2D, rect: Rect2) -> void:
	_rect(level, rect, C_WALL, -18)
	# 靠屋里的一侧压一道更暗的边，做出墙的厚度
	_rect(level, Rect2(rect.position + Vector2(0.0, rect.size.y - 5.0), Vector2(rect.size.x, 5.0)), C_WALL_EDGE, -17)
	var body := StaticBody2D.new()
	var shape := CollisionShape2D.new()
	var rs := RectangleShape2D.new()
	rs.size = rect.size
	shape.shape = rs
	body.position = rect.position + rect.size * 0.5
	body.add_child(shape)
	level.add_child(body)


## 门画在下墙正中，只是视觉标记；出门靠门前那圈按 E
func _draw_door(level: Node2D, half: Vector2) -> void:
	_rect(level, Rect2(Vector2(-DOOR_GAP * 0.5, half.y - 3.0), Vector2(DOOR_GAP, WALL + 6.0)), C_DOOR, -16)


func _draw_stair(level: Node2D, pos: Vector2) -> void:
	# 一段台阶：几级由宽到窄的横板
	for i in 4:
		var w := 96.0 - i * 16.0
		_rect(level, Rect2(pos + Vector2(-w * 0.5, i * 14.0 - 28.0), Vector2(w, 12.0)), C_STAIR, -15)


## 家具按楼层摆：一层是起居室，二层是储物/书房，两层各不相同。
func _draw_furniture(level: Node2D, half: Vector2, index: int) -> void:
	if index == 0:
		_draw_living_room(level, half)
	else:
		_draw_study(level, half)


## 一层起居室：地毯 + 床 + 壁炉 + 餐桌椅 + 木柜 + 散落的小凳和木桶
func _draw_living_room(level: Node2D, half: Vector2) -> void:
	# 地毯：屋中偏下，进门第一眼就看得到（双色双层，不再是死板一块）
	_rect(level, Rect2(Vector2(-half.x + 70.0, half.y * 0.06), Vector2(_room.x - 140.0, 116.0)), C_RUG, -16)
	_rect(level, Rect2(Vector2(-half.x + 84.0, half.y * 0.06 + 12.0), Vector2(_room.x - 168.0, 92.0)), C_RUG.lightened(0.14), -15)
	# 床（左上）：床架 + 床垫 + 枕头 + 被角
	var bx := -half.x + 30.0
	var by := -half.y + 34.0
	_rect(level, Rect2(Vector2(bx, by), Vector2(104.0, 62.0)), C_WOOD, -14)
	_rect(level, Rect2(Vector2(bx + 6.0, by + 6.0), Vector2(92.0, 50.0)), C_BED, -13)
	_rect(level, Rect2(Vector2(bx + 12.0, by + 10.0), Vector2(34.0, 22.0)), Color(0.94, 0.92, 0.86), -12)
	_rect(level, Rect2(Vector2(bx + 52.0, by + 34.0), Vector2(44.0, 18.0)), C_RUG, -12)
	# 壁炉（贴上方墙）
	_rect(level, Rect2(Vector2(56.0, -half.y + WALL + 4.0), Vector2(100.0, 36.0)), C_WALL_EDGE, -14)
	_rect(level, Rect2(Vector2(66.0, -half.y + WALL + 12.0), Vector2(80.0, 24.0)), C_FIRE.darkened(0.38), -13)
	_rect(level, Rect2(Vector2(80.0, -half.y + WALL + 19.0), Vector2(52.0, 12.0)), C_FIRE, -12)
	# 餐桌（右中）+ 两把椅子
	var tx := half.x - 152.0
	var ty := half.y - 154.0
	_rect(level, Rect2(Vector2(tx - 22.0, ty + 16.0), Vector2(18.0, 30.0)), C_WOOD, -14)
	_rect(level, Rect2(Vector2(tx + 108.0, ty + 16.0), Vector2(18.0, 30.0)), C_WOOD, -14)
	_rect(level, Rect2(Vector2(tx, ty), Vector2(104.0, 62.0)), C_WOOD, -14)
	_rect(level, Rect2(Vector2(tx + 6.0, ty + 6.0), Vector2(92.0, 50.0)), C_WOOD_LIGHT, -13)
	# 木柜（右上角偏下，避开楼梯口）
	_rect(level, Rect2(Vector2(half.x - 72.0, -half.y + 122.0), Vector2(52.0, 78.0)), C_WOOD.darkened(0.20), -14)
	_rect(level, Rect2(Vector2(half.x - 64.0, -half.y + 134.0), Vector2(36.0, 4.0)), C_METAL, -13)
	_rect(level, Rect2(Vector2(half.x - 64.0, -half.y + 164.0), Vector2(36.0, 4.0)), C_METAL, -13)
	# 一个小凳 + 一只木桶：散在左下、右下
	_rect(level, Rect2(Vector2(-half.x + 44.0, half.y - 74.0), Vector2(30.0, 30.0)), C_WOOD_LIGHT, -14)
	_rect(level, Rect2(Vector2(half.x - 48.0, half.y - 62.0), Vector2(28.0, 34.0)), C_WOOD.darkened(0.30), -14)


## 二层储物/书房：冷色地毯 + 两座书架 + 书桌椅 + 木箱堆 + 墙上挂画 + 木桶
func _draw_study(level: Node2D, half: Vector2) -> void:
	# 地毯：换个冷色，一眼就知道「上楼了」
	_rect(level, Rect2(Vector2(-half.x + 96.0, 24.0), Vector2(_room.x - 192.0, 96.0)), C_RUG2, -16)
	_rect(level, Rect2(Vector2(-half.x + 110.0, 36.0), Vector2(_room.x - 220.0, 72.0)), C_RUG2.lightened(0.12), -15)
	# 书架：沿左墙排两座，每座三层书
	var sx := -half.x + 26.0
	for i in 2:
		var sy := -half.y + 56.0 + i * 100.0
		_rect(level, Rect2(Vector2(sx, sy), Vector2(46.0, 88.0)), C_WOOD.darkened(0.24), -14)
		for r in 3:
			_rect(level, Rect2(Vector2(sx + 5.0, sy + 9.0 + r * 27.0), Vector2(36.0, 17.0)), C_PAPER, -13)
			_rect(level, Rect2(Vector2(sx + 9.0, sy + 12.0 + r * 27.0), Vector2(6.0, 11.0)), C_RUG, -12)
	# 书桌 + 椅子（右上，避开楼梯口）
	var dx := half.x - 164.0
	var dy := -half.y + 92.0
	_rect(level, Rect2(Vector2(dx, dy), Vector2(96.0, 56.0)), C_WOOD, -14)
	_rect(level, Rect2(Vector2(dx + 8.0, dy + 8.0), Vector2(80.0, 40.0)), C_WOOD_LIGHT, -13)
	_rect(level, Rect2(Vector2(dx + 30.0, dy + 14.0), Vector2(32.0, 22.0)), C_PAPER, -12)
	_rect(level, Rect2(Vector2(dx + 38.0, dy + 62.0), Vector2(24.0, 28.0)), C_WOOD, -14)
	# 木箱堆（右下）
	_rect(level, Rect2(Vector2(half.x - 122.0, half.y - 152.0), Vector2(54.0, 54.0)), C_WOOD, -14)
	_rect(level, Rect2(Vector2(half.x - 66.0, half.y - 130.0), Vector2(44.0, 32.0)), C_WOOD.darkened(0.22), -14)
	_rect(level, Rect2(Vector2(half.x - 118.0, half.y - 96.0), Vector2(40.0, 40.0)), C_WOOD_LIGHT, -14)
	# 墙上挂画（上方墙两幅）
	_rect(level, Rect2(Vector2(-64.0, -half.y + WALL + 10.0), Vector2(58.0, 42.0)), C_WOOD, -14)
	_rect(level, Rect2(Vector2(-58.0, -half.y + WALL + 16.0), Vector2(46.0, 30.0)), C_RUG2.lightened(0.22), -13)
	_rect(level, Rect2(Vector2(16.0, -half.y + WALL + 12.0), Vector2(46.0, 34.0)), C_WOOD, -14)
	_rect(level, Rect2(Vector2(22.0, -half.y + WALL + 18.0), Vector2(34.0, 22.0)), C_FIRE.lightened(0.15), -13)
	# 木桶（左下角）
	_rect(level, Rect2(Vector2(-half.x + 30.0, half.y - 76.0), Vector2(30.0, 40.0)), C_WOOD.darkened(0.32), -14)


# ---------------------------------------------------------------- 楼层切换

func _go_floor(index: int) -> void:
	if _player == null:
		return
	var half := _room * 0.5
	var stair_pos := Vector2(half.x - STAIR_INSET, -half.y + STAIR_INSET)
	var offset := Vector2(0.0, -float(index) * (_room.y + ROOM_PAD))
	# 落在楼梯口旁边，别正好压在触发圈里来回弹
	_player.position = offset + stair_pos + Vector2(-74.0, 44.0)
	if _player.has_method("reset_camera"):
		_player.reset_camera()


# ---------------------------------------------------------------- 交互

func _add_hotspot(parent: Node2D, pos: Vector2, radius: float, text: String, action: Callable) -> void:
	var area := Area2D.new()
	area.position = pos
	area.monitorable = false
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = radius
	shape.shape = circle
	area.add_child(shape)
	parent.add_child(area)
	var label := _make_prompt(parent, pos + Vector2(-80.0, -46.0), text)
	var entry := {"area": area, "label": label, "action": action}
	_hotspots.append(entry)
	area.body_entered.connect(_on_hotspot_enter.bind(entry))
	area.body_exited.connect(_on_hotspot_exit.bind(entry))


func _make_prompt(parent: Node2D, pos: Vector2, text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.size = Vector2(160, 28)
	label.position = pos
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("outline_size", 5)
	label.z_index = 30
	label.visible = false
	parent.add_child(label)
	return label


func _on_hotspot_enter(body: Node2D, entry: Dictionary) -> void:
	if body.name == "Player":
		entry["label"].visible = true
		_active_hotspot = entry


func _on_hotspot_exit(body: Node2D, entry: Dictionary) -> void:
	if body.name == "Player":
		entry["label"].visible = false
		if _active_hotspot.get("area", null) == entry["area"]:
			_active_hotspot = {}


func _unhandled_input(event: InputEvent) -> void:
	if _active_hotspot.is_empty() or PlayerProfile.ui_open:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_E:
		get_viewport().set_input_as_handled()
		var action: Callable = _active_hotspot["action"]
		action.call()

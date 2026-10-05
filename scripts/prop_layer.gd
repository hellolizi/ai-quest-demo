extends Node2D
## 道具层（挂在 main.tscn 的 Props 节点上）
## 监听 SceneDecorator 的布置结果，把每件道具真正实例化到地图上。
##
## 有美术资源就贴图，没有就用代码画的占位图形顶上，所以「导入资源即生效」。
## 阻挡玩家的道具（solid）会额外挂一个碰撞体；摆放位置在 SceneDecorator 里
## 已经校验过（不落水、不挡路、不压地点、不重叠），这里只管画出来。

## 负数 z，保证道具画在地面/小路之上、玩家（z=0）之下
const Z_PROPS := -1

const C_TRUNK := Color(0.28, 0.20, 0.13)
const C_TREE := Color(0.13, 0.34, 0.19)
const C_TREE_DARK := Color(0.10, 0.26, 0.15)
const C_LEAF := Color(0.20, 0.40, 0.22)
const C_ROCK := Color(0.36, 0.37, 0.36)
const C_ROCK_DARK := Color(0.24, 0.25, 0.25)
const C_ORE := Color(0.55, 0.62, 0.68)
const C_WOOD := Color(0.46, 0.35, 0.25)
const C_WOOD_DARK := Color(0.32, 0.23, 0.16)
const C_ROOF := Color(0.55, 0.24, 0.18)
const C_STONE := Color(0.42, 0.43, 0.42)
const C_WATER := Color(0.15, 0.30, 0.46)
const C_FIRE := Color(0.93, 0.52, 0.16)
const C_PAPER := Color(0.80, 0.74, 0.58)


func _ready() -> void:
	# 先接信号，再让布置器铺开局地点，免得错过第一批 props_placed
	SceneDecorator.props_placed.connect(_on_props_placed)
	# 读档恢复的布置先原样画出来，再给没布置过的地点用离线模板补上
	SceneDecorator.replay_saved()
	SceneDecorator.decorate_existing()


func _on_props_placed(location_id: String, props: Array) -> void:
	for item in props:
		if typeof(item) == TYPE_DICTIONARY:
			_spawn(location_id, item)


# ---------------------------------------------------------------- 实例化

func _spawn(location_id: String, item: Dictionary) -> void:
	var id := str(item.get("prop_id", ""))
	if id == "":
		return
	var size: Vector2 = item.get("size", Vector2(64, 64))

	var root := Node2D.new()
	root.name = "%s_%s" % [location_id, id]
	root.position = item.get("pos", Vector2.ZERO)
	root.rotation = float(item.get("rot", 0.0))
	root.z_index = Z_PROPS
	add_child(root)

	var tex := PropLibrary.texture_of(id)
	if tex != null:
		_add_sprite(root, tex, size)
	else:
		_draw_prop(root, str(PropLibrary.by_id(id).get("shape", "")), size)

	if bool(item.get("solid", false)):
		_add_collision(root, size)

	var s := float(item.get("scale", 1.0))
	if s != 1.0:
		root.scale = Vector2(s, s)


## 有贴图时按 size.x 等比缩放，并让贴图底边落在摆放点上
func _add_sprite(root: Node2D, tex: Texture2D, size: Vector2) -> void:
	var spr := Sprite2D.new()
	spr.texture = tex
	spr.scale = Vector2.ONE * (size.x / maxf(float(tex.get_width()), 1.0))
	spr.offset = Vector2(0.0, -float(tex.get_height()) * 0.5)
	root.add_child(spr)


## 实心道具给一个底部居中的矩形碰撞体，别挡住路（摆放时已保证不在路上）
func _add_collision(root: Node2D, size: Vector2) -> void:
	var shape := RectangleShape2D.new()
	shape.size = Vector2(size.x * 0.7, size.y * 0.7)
	var cs := CollisionShape2D.new()
	cs.shape = shape
	cs.position = Vector2(0.0, -size.y * 0.35)
	var body := StaticBody2D.new()
	body.add_child(cs)
	root.add_child(body)


func _poly(root: Node2D, points: PackedVector2Array, color: Color) -> void:
	var p := Polygon2D.new()
	p.polygon = points
	p.color = color
	root.add_child(p)


# ---------------------------------------------------------------- 占位画法
# 全部以「底边在 y=0、向上到 y=-size.y」的局部坐标来画，
# 和贴图的底边对齐方式保持一致。

func _draw_prop(root: Node2D, shape: String, size: Vector2) -> void:
	match shape:
		"tree":
			_draw_tree(root, size)
		"bush":
			_draw_bush(root, size)
		"grass":
			_draw_grass(root, size)
		"rock":
			_draw_rock(root, size)
		"ore":
			_draw_ore(root, size)
		"house":
			_draw_house(root, size)
		"well":
			_draw_well(root, size)
		"fence":
			_draw_fence(root, size)
		"signpost":
			_draw_signpost(root, size)
		"barrel":
			_draw_barrel(root, size)
		"crate":
			_draw_crate(root, size)
		"fire":
			_draw_fire(root, size)
		"boat":
			_draw_boat(root, size)
		_:
			_draw_bush(root, size)


func _draw_tree(root: Node2D, s: Vector2) -> void:
	var w := s.x
	var h := s.y
	_poly(root, PackedVector2Array([
		Vector2(-w * 0.09, 0), Vector2(w * 0.09, 0),
		Vector2(w * 0.09, -h * 0.36), Vector2(-w * 0.09, -h * 0.36),
	]), C_TRUNK)
	_poly(root, PackedVector2Array([
		Vector2(-w * 0.50, -h * 0.28), Vector2(w * 0.50, -h * 0.28), Vector2(0, -h * 0.74),
	]), C_TREE)
	_poly(root, PackedVector2Array([
		Vector2(-w * 0.40, -h * 0.54), Vector2(w * 0.40, -h * 0.54), Vector2(0, -h),
	]), C_TREE_DARK)


func _draw_bush(root: Node2D, s: Vector2) -> void:
	var w := s.x
	var h := s.y
	_poly(root, PackedVector2Array([
		Vector2(-w * 0.50, 0), Vector2(-w * 0.26, -h * 0.86), Vector2(-w * 0.02, -h * 0.52),
		Vector2(w * 0.26, -h * 0.90), Vector2(w * 0.50, 0),
	]), C_TREE)
	_poly(root, PackedVector2Array([
		Vector2(-w * 0.24, -h * 0.10), Vector2(0, -h * 0.82), Vector2(w * 0.26, -h * 0.16),
	]), C_LEAF)


func _draw_grass(root: Node2D, s: Vector2) -> void:
	var w := s.x
	var h := s.y
	for i in 5:
		var x := -w * 0.40 + w * 0.80 * float(i) / 4.0
		var color := C_LEAF if i % 2 == 0 else C_TREE
		_poly(root, PackedVector2Array([
			Vector2(x - w * 0.06, 0), Vector2(x + w * 0.06, 0), Vector2(x + w * 0.02, -h),
		]), color)


func _draw_rock(root: Node2D, s: Vector2) -> void:
	var w := s.x
	var h := s.y
	_poly(root, PackedVector2Array([
		Vector2(-w * 0.50, 0), Vector2(-w * 0.34, -h * 0.66), Vector2(0, -h),
		Vector2(w * 0.34, -h * 0.62), Vector2(w * 0.50, 0),
	]), C_ROCK)
	_poly(root, PackedVector2Array([
		Vector2(-w * 0.30, 0), Vector2(-w * 0.16, -h * 0.46),
		Vector2(w * 0.12, -h * 0.40), Vector2(w * 0.08, 0),
	]), C_ROCK_DARK)


func _draw_ore(root: Node2D, s: Vector2) -> void:
	var w := s.x
	var h := s.y
	_poly(root, PackedVector2Array([
		Vector2(-w * 0.50, 0), Vector2(0, -h), Vector2(w * 0.50, 0),
	]), C_ROCK_DARK)
	for off in [Vector2(-w * 0.20, -h * 0.30), Vector2(w * 0.14, -h * 0.48), Vector2(-w * 0.02, -h * 0.14)]:
		_poly(root, PackedVector2Array([
			off + Vector2(-w * 0.11, h * 0.10), off + Vector2(0, -h * 0.12),
			off + Vector2(w * 0.11, h * 0.10),
		]), C_ORE)


func _draw_house(root: Node2D, s: Vector2) -> void:
	var w := s.x
	var h := s.y
	_poly(root, PackedVector2Array([
		Vector2(-w * 0.42, 0), Vector2(w * 0.42, 0),
		Vector2(w * 0.42, -h * 0.52), Vector2(-w * 0.42, -h * 0.52),
	]), C_WOOD)
	_poly(root, PackedVector2Array([
		Vector2(-w * 0.50, -h * 0.48), Vector2(0, -h), Vector2(w * 0.50, -h * 0.48),
	]), C_ROOF)
	_poly(root, PackedVector2Array([
		Vector2(w * 0.08, 0), Vector2(w * 0.30, 0),
		Vector2(w * 0.30, -h * 0.30), Vector2(w * 0.08, -h * 0.30),
	]), C_WOOD_DARK)


func _draw_well(root: Node2D, s: Vector2) -> void:
	var w := s.x
	var h := s.y
	_poly(root, PackedVector2Array([
		Vector2(-w * 0.46, 0), Vector2(w * 0.46, 0),
		Vector2(w * 0.38, -h * 0.40), Vector2(-w * 0.38, -h * 0.40),
	]), C_STONE)
	_poly(root, PackedVector2Array([
		Vector2(-w * 0.24, -h * 0.36), Vector2(w * 0.24, -h * 0.36),
		Vector2(w * 0.20, -h * 0.44), Vector2(-w * 0.20, -h * 0.44),
	]), C_WATER)
	for sx in [-1.0, 1.0]:
		_poly(root, PackedVector2Array([
			Vector2(sx * w * 0.34 - w * 0.05, -h * 0.34), Vector2(sx * w * 0.34 + w * 0.05, -h * 0.34),
			Vector2(sx * w * 0.34 + w * 0.05, -h * 0.82), Vector2(sx * w * 0.34 - w * 0.05, -h * 0.82),
		]), C_WOOD_DARK)
	_poly(root, PackedVector2Array([
		Vector2(-w * 0.46, -h * 0.78), Vector2(0, -h), Vector2(w * 0.46, -h * 0.78),
	]), C_ROOF)


func _draw_fence(root: Node2D, s: Vector2) -> void:
	var w := s.x
	var h := s.y
	for i in 4:
		var x := -w * 0.45 + w * 0.90 * float(i) / 3.0
		_poly(root, PackedVector2Array([
			Vector2(x - w * 0.03, 0), Vector2(x + w * 0.03, 0),
			Vector2(x + w * 0.03, -h * 0.88), Vector2(x - w * 0.03, -h * 0.88),
		]), C_WOOD_DARK)
	for y in [-h * 0.72, -h * 0.42]:
		_poly(root, PackedVector2Array([
			Vector2(-w * 0.50, y), Vector2(w * 0.50, y),
			Vector2(w * 0.50, y + h * 0.10), Vector2(-w * 0.50, y + h * 0.10),
		]), C_WOOD)


func _draw_signpost(root: Node2D, s: Vector2) -> void:
	var w := s.x
	var h := s.y
	_poly(root, PackedVector2Array([
		Vector2(-w * 0.05, 0), Vector2(w * 0.05, 0),
		Vector2(w * 0.05, -h * 0.92), Vector2(-w * 0.05, -h * 0.92),
	]), C_WOOD_DARK)
	_poly(root, PackedVector2Array([
		Vector2(-w * 0.46, -h * 0.86), Vector2(w * 0.46, -h * 0.86),
		Vector2(w * 0.46, -h * 0.56), Vector2(-w * 0.46, -h * 0.56),
	]), C_WOOD)
	_poly(root, PackedVector2Array([
		Vector2(-w * 0.34, -h * 0.80), Vector2(w * 0.34, -h * 0.80),
		Vector2(w * 0.34, -h * 0.62), Vector2(-w * 0.34, -h * 0.62),
	]), C_PAPER)


func _draw_barrel(root: Node2D, s: Vector2) -> void:
	var w := s.x
	var h := s.y
	_poly(root, PackedVector2Array([
		Vector2(-w * 0.46, 0), Vector2(w * 0.46, 0),
		Vector2(w * 0.50, -h * 0.50), Vector2(w * 0.40, -h), Vector2(-w * 0.40, -h),
		Vector2(-w * 0.50, -h * 0.50),
	]), C_WOOD)
	for y in [-h * 0.28, -h * 0.72]:
		_poly(root, PackedVector2Array([
			Vector2(-w * 0.48, y), Vector2(w * 0.48, y),
			Vector2(w * 0.48, y + h * 0.09), Vector2(-w * 0.48, y + h * 0.09),
		]), C_WOOD_DARK)


func _draw_crate(root: Node2D, s: Vector2) -> void:
	var w := s.x
	var h := s.y
	_poly(root, PackedVector2Array([
		Vector2(-w * 0.46, 0), Vector2(w * 0.46, 0),
		Vector2(w * 0.46, -h * 0.92), Vector2(-w * 0.46, -h * 0.92),
	]), C_WOOD)
	_poly(root, PackedVector2Array([
		Vector2(-w * 0.46, -h * 0.92), Vector2(w * 0.46, -h * 0.92),
		Vector2(w * 0.46, -h * 0.84), Vector2(-w * 0.46, -h * 0.84),
	]), C_WOOD_DARK)
	for sx in [-1.0, 1.0]:
		_poly(root, PackedVector2Array([
			Vector2(sx * w * 0.08, -h * 0.80), Vector2(sx * w * 0.16, -h * 0.12),
			Vector2(sx * w * 0.24, -h * 0.12), Vector2(sx * w * 0.16, -h * 0.80),
		]), C_WOOD_DARK)


func _draw_fire(root: Node2D, s: Vector2) -> void:
	var w := s.x
	var h := s.y
	for a in [0.5, -0.5]:
		var log_pts := PackedVector2Array([
			Vector2(-w * 0.40, -h * 0.10), Vector2(w * 0.40, -h * 0.10),
			Vector2(w * 0.40, -h * 0.02), Vector2(-w * 0.40, -h * 0.02),
		])
		var rotated := PackedVector2Array()
		for p in log_pts:
			rotated.append(p.rotated(a) + Vector2(0, -h * 0.10))
		_poly(root, rotated, C_TRUNK)
	_poly(root, PackedVector2Array([
		Vector2(-w * 0.22, -h * 0.10), Vector2(0, -h), Vector2(w * 0.22, -h * 0.10),
	]), C_FIRE)


func _draw_boat(root: Node2D, s: Vector2) -> void:
	var w := s.x
	var h := s.y
	_poly(root, PackedVector2Array([
		Vector2(-w * 0.50, -h * 0.62), Vector2(w * 0.50, -h * 0.62),
		Vector2(w * 0.34, 0), Vector2(-w * 0.34, 0),
	]), C_WOOD)
	_poly(root, PackedVector2Array([
		Vector2(-w * 0.50, -h * 0.62), Vector2(w * 0.50, -h * 0.62),
		Vector2(w * 0.50, -h * 0.50), Vector2(-w * 0.50, -h * 0.50),
	]), C_WOOD_DARK)
	_poly(root, PackedVector2Array([
		Vector2(-w * 0.26, -h * 0.50), Vector2(w * 0.26, -h * 0.50),
		Vector2(w * 0.26, -h * 0.36), Vector2(-w * 0.26, -h * 0.36),
	]), C_PAPER)

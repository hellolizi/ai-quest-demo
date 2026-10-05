extends Node2D
## 根据 WorldData 里的地点数据，在运行时把地图画出来（无限世界 · 玩家局部窗口版）。
##
## 世界是无限大的，不可能一次画完：所以地面与溪流是「跟着玩家走」的一整块，
## 区域色块和草木则只维护玩家附近的一小片——走进去就建，走远了就卸。
## 想加一个新地点，只需要往 WorldData 里加一条，这里会自动补上地标和小路。

const RIVER_Y := 1010.0        # 南部溪流的中心线
const RIVER_H := 90.0          # 溪流半宽

const C_GRASS := Color(0.16, 0.24, 0.17)
const C_PATH := Color(0.35, 0.29, 0.20)
const C_WATER := Color(0.15, 0.30, 0.46)
const C_SAND := Color(0.72, 0.64, 0.44)
const C_TREE := Color(0.13, 0.34, 0.19)
const C_TREE_DARK := Color(0.10, 0.26, 0.15)
const C_TRUNK := Color(0.28, 0.20, 0.13)
const C_ROCK := Color(0.36, 0.37, 0.36)
const C_ROCK_DARK := Color(0.24, 0.25, 0.25)
const C_HOUSE := Color(0.46, 0.35, 0.25)
const C_ROOF := Color(0.55, 0.24, 0.18)
const C_CAVE := Color(0.05, 0.05, 0.06)
const C_DECK := Color(0.42, 0.32, 0.22)
const C_SHRINE := Color(0.52, 0.20, 0.18)
const C_HILL := Color(0.19, 0.27, 0.19)
const C_MTN := Color(0.35, 0.35, 0.34)
const C_MTN_DARK := Color(0.23, 0.23, 0.23)
const C_SNOW := Color(0.90, 0.92, 0.95)

## 地面块（连同溪流）以玩家为中心，半边这么长。走起来永远看不到边。
const GROUND_HALF := 4200.0
## 玩家周围这个半径内的区域才画色块、才撒草木
const VIEW_RADIUS := 2000.0
## 草木按「瓦片」为单位铺：每块瓦片边长这么大，进视野才建、出视野才卸
const DECOR_TILE := 1000.0
## 玩家移动后，最多隔这么久检查一次视野（节流）
const VIEW_INTERVAL := 0.25
## 小路最长画这么长；无限世界里旧的地点可能远在天边，太长的路就不画了
const PATH_MAX_LEN := 3000.0

## 撒树 / 撒石的密度（每平方像素的期望个数）
const TREE_DENSITY := 1.0 / 46000.0
const ROCK_DENSITY := 1.0 / 152000.0
## 草木瓦片的随机盐（与世界种子一起决定每块瓦片上长什么）
const DECOR_SALT := 0x5EED

## 山体按「瓦片」为单位铺：每块瓦片边长这么大，进视野才建、出视野才卸。
## 比草木瓦片大一些——山是大地形，不必切得太碎，节点数也更少。
const MTN_TILE := 520.0
## 每块山体瓦片里的子采样数：MTN_SUB×MTN_SUB 个点决定这一块上长哪几座山。
const MTN_SUB := 3
## 山体瓦片的随机盐（与世界种子一起决定每块瓦片上山的抖动）
const MTN_SALT := 0x7A11
## 山体层：压在地面/区域色块/道路之上，树(−1)与房子(−1)之下
const MTN_Z := -5

## 区域可视化：把 Voronoi 区域按所属文化圈的草色画成色块 + 描边。
const SHOW_REGIONS := true
## 色块层次：压在地面(−20)之上，溪流(−12)/道路(−10)之下
const REGION_FILL_Z := -19
## 色块透明度：透出底下的草皮纹理，不至于糊成一整片死板纯色
const REGION_FILL_ALPHA := 0.48
const REGION_EDGE_Z := -18
const REGION_LABEL_Z := 5

## 程序生成的平铺草皮贴图边长（越小颗粒越密，像素也越省）
const GRASS_TEX_SIZE := 128

## 门口的交互区脚本（每栋房子门前挂一个，按 E 进屋）
const HOUSE_DOOR_SCRIPT := preload("res://scripts/house_door.gd")

## 锻造台 / 商铺的交互区脚本（每座聚落的地标建好后挂一个，按 E 使用）
const FACILITY_SCRIPT := preload("res://scripts/facility.gd")

## 宝箱的交互区脚本（通天福地里摆几口，走近按 E 开启）
const TREASURE_SCRIPT := preload("res://scripts/treasure_chest.gd")

## 野外敌人脚本（废墟 / 矿口 / 林子里的野物，打死掉锻造材料）
const ENEMY_SCRIPT := preload("res://scripts/enemy.gd")

## 房子/设施的实心碰撞体只占贴图最底下这一截（占整高的比例），当作「地基 / 占地」。
## 上面的屋顶与楼层不挡人——玩家才能绕到房子侧面、走到房子后面去。
## 配合 World 的 Y 排序：走到房子北面时房子会把玩家挡住，看起来就是一栋有厚度的
## 立体房子，而不是一堵平面的墙。
const HOUSE_FOOT_RATIO := 0.34
const FACILITY_FOOT_RATIO := 0.34
## 碰撞体的最小高度：太小的贴图（比如告示板）也得有一块像样的地基挡人。
const FOOT_MIN_HEIGHT := 16.0

## 从门口铺一条小岔路接到最近的主路：门口正前方先铺一截「门前小路」，
## 再斜着连到主路上最近的一点。附近没主路（荒野孤屋）就不铺。
const DOOR_STUB_LEN := 30.0
## 主路离得太远就不拉岔路了，免得拖出一条横穿半个聚落的长线
const DOOR_SPUR_MAX_LEN := 620.0

## 玩家在某个房子门口按了 E，请求进屋。info 见 PropLibrary.house_spec。
signal house_entered(info: Dictionary)

## 玩家在锻造台 / 商铺前按了 E，请求使用。info 见 facility.gd.setup。
signal facility_used(info: Dictionary)

## 玩家在宝箱前按了 E，请求开启。info 见 treasure_chest.gd.setup。
signal treasure_opened(info: Dictionary)

## 当前文化圈的调色板。全图元素（地面、撒树、撒石、道路）都按它上色。
var _palette: Dictionary = {}

## 跟着玩家走的几大块
var _ground: Polygon2D
var _river: Polygon2D
var _beach: Polygon2D
var _sea: Polygon2D

## 地图上所有房子：每条 {node, bid, cid}。建筑图鉴里有新图到货时，按它原地换图。
var _house_nodes: Array = []

## 通天福地的主殿：每条 {node, visual, pos, textured, house, roof, gold, gold_deep}。
## 仙宫贴图到货时，按它原地换图（和 _house_nodes 一个道理，只是尺寸与配色单独一套）。
var _tianfu_palaces: Array = []

## bid -> 贴图房的实心碰撞矩形（本地坐标）。按 id 缓存，免得每栋房都重算一遍 alpha 包围盒。
var _house_solid_cache: Dictionary = {}

## 地图上所有功能性建筑：每条 {node, visual, fid, cid, kind, tier, pal, textured}。
## 功能建筑图鉴里有新图到货时，按它原地换图（和 _house_nodes 一个道理）。
var _facility_nodes: Array = []

## 所有小路的折线（世界坐标，每条一组）。NPC 会挑一条离自己最近的路，沿路走一段。
var _paths: Array = []

## 玩家附近已建好的区域色块：Vector2i 格子 -> [fill, edge, label]
var _region_nodes: Dictionary = {}
## 玩家附近已建好的草木瓦片：Vector2i 瓦片 -> Array[Node]
var _decor_nodes: Dictionary = {}
## 玩家附近已建好的山体瓦片：Vector2i 瓦片 -> Array[Node]
var _terrain_nodes: Dictionary = {}

## 上一次重建视野时玩家的位置 / 计时器
var _last_view_pos := Vector2(INF, INF)
var _view_acc := 0.0


## 从调色板取一个颜色，取不到就用兜底常量
func _col(pal: Dictionary, key: String, fallback: Color) -> Color:
	var c = pal.get(key, null)
	if typeof(c) == TYPE_COLOR:
		return c
	return fallback


## 某种建筑风格的屋顶多边形（原点在地基顶部中央）
func _roof_shape(shape: String) -> PackedVector2Array:
	match shape:
		"gable":
			# 尖顶陡坡：一个高高的三角
			return PackedVector2Array([Vector2(-38, -18), Vector2(0, -58), Vector2(38, -18)])
		"dome":
			# 圆顶：用多个点围出一个扁圆
			var pts := PackedVector2Array()
			for i in 9:
				var a := PI + PI * float(i) / 8.0
				pts.append(Vector2(cos(a) * 36.0, -18.0 + sin(a) * 34.0))
			return pts
		"thatch":
			# 茅草缓顶：又宽又矮，两檐往下垂
			return PackedVector2Array([Vector2(-46, -12), Vector2(-28, -32), Vector2(0, -44), Vector2(28, -32), Vector2(46, -12)])
		"spire":
			# 尖塔：又高又瘦的陡尖
			return PackedVector2Array([Vector2(-24, -18), Vector2(0, -82), Vector2(24, -18)])
		"hip":
			# 四坡顶：梯形缓坡，顶上留一道平脊
			return PackedVector2Array([Vector2(-40, -16), Vector2(-20, -42), Vector2(20, -42), Vector2(40, -16)])
		"crystal":
			# 水晶尖簇：高低错落的一丛尖顶
			return PackedVector2Array([Vector2(-38, -16), Vector2(-22, -48), Vector2(-8, -28), Vector2(0, -62), Vector2(8, -30), Vector2(22, -50), Vector2(38, -16)])
		"flat":
			# 平顶：一块又宽又厚的平顶板
			return PackedVector2Array([Vector2(-44, -14), Vector2(-44, -30), Vector2(44, -30), Vector2(44, -14)])
		"canopy":
			# 树冠顶：宽阔圆润、两梢微微上翘
			return PackedVector2Array([Vector2(-48, -10), Vector2(-34, -30), Vector2(-16, -42), Vector2(0, -46), Vector2(16, -42), Vector2(34, -30), Vector2(48, -10)])
		_:
			# curved：中原飞檐，略微外扩的缓坡
			return PackedVector2Array([Vector2(-36, -18), Vector2(0, -48), Vector2(36, -18)])


func _ready() -> void:
	_palette = CultureData.palette_of(CultureData.current_id)
	_ground = _build_ground()
	_river = _build_river()
	_beach = _build_beach()
	_sea = _build_sea()
	_build_paths()
	for loc in WorldData.LOCATIONS:
		_build_location(loc)
	# 一进游戏就把玩家附近的区域 / 草木建好（不能等第一帧 _process）
	var p := _player_pos()
	_last_view_pos = p
	_follow(p)
	_refresh_view(p)
	# AI 之后每造出一个新地点，就实时把它画到地图上
	WorldData.location_added.connect(add_location_visual)
	# 建筑图鉴里新画好的房屋图到货时，把地图上对应的房子换成贴图
	PropLibrary.buildings_changed.connect(_refresh_house_textures)


func _process(delta: float) -> void:
	# 玩家在屋里时世界整体被藏起来，这里不必再跟着他刷新区块
	if InteriorManager.active:
		return
	var p := _player_pos()
	# 地面/溪流每帧跟着玩家走（很便宜）
	_follow(p)
	# 区域色块 / 草木按节流 + 位移阈值重建
	_view_acc += delta
	if _view_acc < VIEW_INTERVAL:
		return
	_view_acc = 0.0
	if p.distance_squared_to(_last_view_pos) < 100.0:
		return
	_last_view_pos = p
	_refresh_view(p)


## 地面块、溪流、沙滩、海面重新居中到玩家脚下（这几块横向跟着玩家走，纵向是固定世界坐标）
func _follow(p: Vector2) -> void:
	if is_instance_valid(_ground):
		_ground.position = p
		if _ground.texture != null:
			# 节点挪了，uv 得反向补正到新的世界坐标，草皮纹理才不会跟着玩家滑动
			_ground.uv = _world_uv(_ground.polygon, p)
	if is_instance_valid(_river):
		_river.position = Vector2(p.x, 0.0)
	if is_instance_valid(_beach):
		_beach.position = Vector2(p.x, 0.0)
	if is_instance_valid(_sea):
		_sea.position = Vector2(p.x, 0.0)


## 玩家在哪：优先取 World 下的 Player，其次取 group 里的玩家
func _player_pos() -> Vector2:
	var node := get_node_or_null("Player")
	if node is Node2D:
		return (node as Node2D).global_position
	var in_group := get_tree().get_first_node_in_group("player")
	if in_group is Node2D:
		return (in_group as Node2D).global_position
	return Vector2.ZERO


## 重建玩家附近的一片：区域色块 + 山体 + 草木瓦片
func _refresh_view(p: Vector2) -> void:
	_refresh_regions(p)
	_refresh_terrain(p)
	_refresh_decor(p)


# ---------------------------------------------------------------- 区域色块（增量建 / 卸）

func _refresh_regions(p: Vector2) -> void:
	if not SHOW_REGIONS:
		return
	var live: Dictionary = {}
	for region in RegionGenerator.regions_in_radius(p, VIEW_RADIUS):
		var cell: Vector2i = region["cell"]
		live[cell] = true
		if not _region_nodes.has(cell):
			_region_nodes[cell] = _draw_region(cell, region)
	for cell in _region_nodes.keys():
		if live.has(cell):
			continue
		var center: Vector2 = RegionGenerator.region_of_cell(cell)["center"]
		if center.distance_to(p) > VIEW_RADIUS + RegionGenerator.CELL * 2.5:
			_free_nodes(_region_nodes[cell])
			_region_nodes.erase(cell)


## 画出单个区域的色块 / 描边 / 名字。返回 [fill, edge, label]，算不出多边形则返回 []
func _draw_region(cell: Vector2i, region: Dictionary) -> Array:
	var center: Vector2 = region["center"]
	var half := Vector2(RegionGenerator.CELL, RegionGenerator.CELL) * 2.0
	var cover := Rect2(center - half, half * 2.0)
	var poly: PackedVector2Array = RegionGenerator.cell_polygon(cell, cover)
	if poly.size() < 3:
		return []
	var cid := str(region["culture"])
	var pal := CultureData.palette_of(cid)
	var fill := _poly(poly, _region_fill(pal, cell), Vector2.ZERO, REGION_FILL_Z)
	var edge := _outline(poly, _region_edge(pal), REGION_EDGE_Z)
	var label := _region_label(cid, center)
	return [fill, edge, label]


## 区域填色：以文化圈草色为底，再按格子给一点明度差，
## 这样相邻的两个「同文化圈」区域也能看出分界，不至于糊成一整片。
func _region_fill(pal: Dictionary, cell: Vector2i) -> Color:
	var base := _col(pal, "grass", C_GRASS)
	var k := float(absi(cell.x * 73856093 + cell.y * 19349663) % 1000) / 1000.0
	var c: Color = base.lightened(0.04 + k * 0.12)
	# 半透明：透出底下的草皮纹理，只当作「区域归属」的淡淡色偏，而不是盖死地面的色块
	c.a = REGION_FILL_ALPHA
	return c


## 区域边线颜色：把草色压暗，用作分界线
func _region_edge(pal: Dictionary) -> Color:
	return _col(pal, "grass", C_GRASS).darkened(0.6)


## 画一条首尾相接的折线（多边形描边）
func _outline(points: PackedVector2Array, color: Color, z: int, width := 5.0) -> Line2D:
	var loop := PackedVector2Array(points)
	loop.append(points[0])
	var line := Line2D.new()
	line.points = loop
	line.width = width
	line.default_color = color
	line.z_index = z
	add_child(line)
	return line


func _region_label(cid: String, pos: Vector2) -> Label:
	var label := Label.new()
	label.text = str(CultureData.get_culture(cid).get("name", cid))
	label.size = Vector2(220, 28)
	label.position = pos - Vector2(110, 14)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.75))
	label.add_theme_constant_override("outline_size", 4)
	label.z_index = REGION_LABEL_Z
	add_child(label)
	return label


# ---------------------------------------------------------------- 草木瓦片（增量建 / 卸）

func _refresh_decor(p: Vector2) -> void:
	var base := _decor_tile_of(p)
	var span := int(ceil(VIEW_RADIUS / DECOR_TILE))
	var live: Dictionary = {}
	for dy in range(-span, span + 1):
		for dx in range(-span, span + 1):
			var tile := base + Vector2i(dx, dy)
			if _tile_center(tile).distance_to(p) > VIEW_RADIUS + DECOR_TILE:
				continue
			live[tile] = true
			if not _decor_nodes.has(tile):
				_decor_nodes[tile] = _draw_decor_tile(tile)
	for tile in _decor_nodes.keys():
		if live.has(tile):
			continue
		if _tile_center(tile).distance_to(p) > VIEW_RADIUS + DECOR_TILE * 1.5:
			_free_nodes(_decor_nodes[tile])
			_decor_nodes.erase(tile)


## 一块瓦片铺上树和石头。随机源由「世界种子 + 瓦片坐标」决定，走回头路看到的是一样的。
func _draw_decor_tile(tile: Vector2i) -> Array:
	var nodes: Array = []
	var rng := RegionGenerator.rng_for(tile, DECOR_SALT)
	var origin := Vector2(tile.x, tile.y) * DECOR_TILE
	var half := DECOR_TILE * 0.5
	var tree_target := int(DECOR_TILE * DECOR_TILE * TREE_DENSITY)
	var placed := 0
	var tries := 0
	while placed < tree_target and tries < tree_target * 8:
		tries += 1
		var p := origin + Vector2(rng.randf(), rng.randf()) * DECOR_TILE
		if _is_occupied(p):
			continue
		nodes.append(_tree(p, rng.randf_range(0.7, 1.35), _palette))
		placed += 1
	var rock_target := int(DECOR_TILE * DECOR_TILE * ROCK_DENSITY)
	placed = 0
	tries = 0
	while placed < rock_target and tries < rock_target * 8:
		tries += 1
		var p := origin + Vector2(rng.randf(), rng.randf()) * DECOR_TILE
		if _is_occupied(p):
			continue
		var s := rng.randf_range(14.0, 30.0)
		nodes.append(_poly(PackedVector2Array([
			Vector2(-s, -s * 0.7), Vector2(s, -s * 0.7), Vector2(s * 1.2, s * 0.7), Vector2(-s * 1.2, s * 0.7),
		]), _col(_palette, "rock", C_ROCK), p, -1))
		placed += 1
	return nodes


func _decor_tile_of(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x / DECOR_TILE), floori(p.y / DECOR_TILE))


func _tile_center(tile: Vector2i) -> Vector2:
	return (Vector2(tile.x, tile.y) + Vector2(0.5, 0.5)) * DECOR_TILE


## 释放一串节点
func _free_nodes(arr: Array) -> void:
	for i in arr.size():
		var n: Node = arr[i]
		if is_instance_valid(n):
			n.queue_free()


## 新地点出现后，把它附近几块瓦片里的草木清掉重建（重建时会避开新地点）。
## 只重建「当前在视野里、已经建过」的瓦片：新地点常常先在前方视野外生成，
## 那些瓦片等玩家走近时 _refresh_decor 自然会按新地点重新铺，不必现在白建一遍。
func _free_decor_near(pos: Vector2) -> void:
	var base := _decor_tile_of(pos)
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var tile := base + Vector2i(dx, dy)
			if not _decor_nodes.has(tile):
				continue
			_free_nodes(_decor_nodes[tile])
			_decor_nodes.erase(tile)
			_decor_nodes[tile] = _draw_decor_tile(tile)


# ---------------------------------------------------------------- 山体瓦片（增量建 / 卸）

## 山不是画出来的贴图，而是照着 RegionGenerator 的「海拔场」铺出来的：
## 每块瓦片里取 MTN_SUB×MTN_SUB 个子采样点，问 RegionGenerator 这儿是什么地形，
## 是丘陵就放一个小丘、是山/峰就垒一座山，平原就空着。走回头山还是那座山。
func _refresh_terrain(p: Vector2) -> void:
	var base := _mtn_tile_of(p)
	var span := int(ceil(VIEW_RADIUS / MTN_TILE))
	var live: Dictionary = {}
	for dy in range(-span, span + 1):
		for dx in range(-span, span + 1):
			var tile := base + Vector2i(dx, dy)
			if _mtn_center(tile).distance_to(p) > VIEW_RADIUS + MTN_TILE:
				continue
			live[tile] = true
			if not _terrain_nodes.has(tile):
				_terrain_nodes[tile] = _draw_terrain_tile(tile)
	for tile in _terrain_nodes.keys():
		if live.has(tile):
			continue
		if _mtn_center(tile).distance_to(p) > VIEW_RADIUS + MTN_TILE * 1.5:
			_free_nodes(_terrain_nodes[tile])
			_terrain_nodes.erase(tile)


## 铺一块山体瓦片：子采样点判定地形，丘陵画丘、山与峰垒山。返回这一块建出的节点。
func _draw_terrain_tile(tile: Vector2i) -> Array:
	var nodes: Array = []
	var rng := RegionGenerator.rng_for(tile, MTN_SALT)
	var origin := Vector2(tile.x, tile.y) * MTN_TILE
	var step := MTN_TILE / float(MTN_SUB)
	for iy in MTN_SUB:
		for ix in MTN_SUB:
			# 子采样点：格心 + 抖动，避免整座山排成整齐的方阵
			var local := (Vector2(float(ix), float(iy)) + Vector2(0.5, 0.5)) * step
			local += Vector2(rng.randf_range(-0.3, 0.3), rng.randf_range(-0.3, 0.3)) * step
			var p := origin + local
			var kind := RegionGenerator.terrain_at(p)
			if kind == "plain":
				continue
			var e := RegionGenerator.elevation_at(p)
			if kind == "hill":
				_terrain_hill(nodes, p, step * rng.randf_range(0.6, 0.95))
				continue
			# 山 / 峰：越高越大；峰再加一顶雪
			var k := clampf((e - RegionGenerator.LEVEL_MOUNTAIN) / (1.0 - RegionGenerator.LEVEL_MOUNTAIN), 0.0, 1.0)
			_terrain_mountain(nodes, p, step * lerpf(0.85, 1.5, k), kind == "peak")
	return nodes


func _mtn_tile_of(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x / MTN_TILE), floori(p.y / MTN_TILE))


func _mtn_center(tile: Vector2i) -> Vector2:
	return (Vector2(tile.x, tile.y) + Vector2(0.5, 0.5)) * MTN_TILE


## 一座山：深色背光山体 + 亮面，峰再加雪顶
func _terrain_mountain(nodes: Array, pos: Vector2, s: float, snowy: bool) -> void:
	nodes.append(_poly(PackedVector2Array([
		Vector2(-s, s * 0.5), Vector2(-s * 0.35, -s * 0.7),
		Vector2(0.0, -s), Vector2(s * 0.5, -s * 0.5), Vector2(s, s * 0.5),
	]), C_MTN_DARK, pos, MTN_Z))
	nodes.append(_poly(PackedVector2Array([
		Vector2(0.0, -s), Vector2(s * 0.5, -s * 0.5), Vector2(s, s * 0.5), Vector2(0.0, s * 0.5),
	]), C_MTN, pos, MTN_Z + 1))
	if snowy:
		nodes.append(_poly(PackedVector2Array([
			Vector2(-s * 0.22, -s * 0.6), Vector2(0.0, -s),
			Vector2(s * 0.2, -s * 0.56), Vector2(0.0, -s * 0.42),
		]), C_SNOW, pos, MTN_Z + 2))


## 一座丘陵：贴地的浅色圆丘
func _terrain_hill(nodes: Array, pos: Vector2, s: float) -> void:
	nodes.append(_poly(PackedVector2Array([
		Vector2(-s, s * 0.42), Vector2(-s * 0.5, -s * 0.3), Vector2(0.0, -s * 0.5),
		Vector2(s * 0.55, -s * 0.28), Vector2(s, s * 0.42),
	]), C_HILL, pos, MTN_Z))


# ---------------------------------------------------------------- 运行时新增地点

## 运行时新增一个地点：补一条就近的小路，画出地标，并把落点附近的草木清掉重建。
func add_location_visual(loc: Dictionary) -> void:
	_build_path(loc)
	_build_location(loc)
	_free_decor_near(loc["pos"] as Vector2)


# ---------------------------------------------------------------- 基础工具

## 画一个多边形。z 越大越靠上层；地面/景物用负数，保证角色永远在它们前面。
func _poly(points: PackedVector2Array, color: Color, pos := Vector2.ZERO, z := 0) -> Polygon2D:
	var p := Polygon2D.new()
	p.polygon = points
	p.color = color
	p.position = pos
	p.z_index = z
	add_child(p)
	return p


## 往指定的父节点里画多边形。房子用容器装起来，贴图到货后整块换掉才方便。
func _poly_in(parent: Node2D, points: PackedVector2Array, color: Color, z := 0) -> Polygon2D:
	var p := Polygon2D.new()
	p.polygon = points
	p.color = color
	p.z_index = z
	parent.add_child(p)
	return p


## 在地点上写名字，让玩家一眼看到「这里叫什么」
func _place_label(text: String, pos: Vector2) -> void:
	var label := Label.new()
	label.text = text
	label.size = Vector2(220, 32)
	label.position = pos - Vector2(110, 170)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 22)
	label.add_theme_color_override("font_color", Color(0.95, 0.94, 0.86))
	label.add_theme_color_override("font_outline_color", Color(0.05, 0.07, 0.05))
	label.add_theme_constant_override("outline_size", 6)
	label.z_index = 10
	add_child(label)


# ---------------------------------------------------------------- 地形

func _build_ground() -> Polygon2D:
	# 一块以原点为中心、边长 GROUND_HALF*2 的草地；_follow 每帧把它挪到玩家脚下。
	# 底下再平铺一层程序生成的草皮纹理（纯色草地太死板，加点绒感和草叶细节）。
	var quad := PackedVector2Array([
		Vector2(-GROUND_HALF, -GROUND_HALF),
		Vector2(GROUND_HALF, -GROUND_HALF),
		Vector2(GROUND_HALF, GROUND_HALF),
		Vector2(-GROUND_HALF, GROUND_HALF),
	])
	var ground := _poly(quad, Color.WHITE, Vector2.ZERO, -20)
	ground.texture = _grass_texture()
	ground.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	ground.uv = _world_uv(quad, Vector2.ZERO)
	return ground


## 程序生成一小块可平铺的草皮贴图：草色底 + 逐像素明暗噪点 + 一小撮草叶。
## 一张会平铺的贴图顶替纯色，地面才有草地的绒感，而不是一整块死绿。
func _grass_texture() -> ImageTexture:
	var n := GRASS_TEX_SIZE
	var img := Image.create_empty(n, n, false, Image.FORMAT_RGBA8)
	var base := _col(_palette, "grass", C_GRASS)
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x9A55
	# 底色打底，再逐像素抖一点明暗，做出草绒的颗粒感
	for y in n:
		for x in n:
			var k := rng.randf()
			if k > 0.5:
				img.set_pixel(x, y, base.lightened(0.02 + k * 0.10))
			else:
				img.set_pixel(x, y, base.darkened(0.02 + (1.0 - k) * 0.10))
	# 随机点一些短竖线当草叶，深浅交错，让近看时有细节
	for i in int(n * n / 42):
		var bx := rng.randi_range(0, n - 1)
		var by := rng.randi_range(0, n - 4)
		var bright := rng.randf() > 0.5
		var bc := base.lightened(0.16 + rng.randf() * 0.12) if bright else base.darkened(0.10 + rng.randf() * 0.10)
		for j in rng.randi_range(2, 4):
			img.set_pixel(bx, by + j, bc)
	return ImageTexture.create_from_image(img)


## 把多边形顶点换成「世界锚定」的贴图 uv：顶点局部坐标加上节点当前位置，就是它的世界坐标。
## 地面块每帧跟着玩家走，若 uv 用默认的局部坐标，纹理就会跟着人一起滑；
## 显式写世界坐标后，草皮在世界上原地不动，看上去才是「地面」而非「贴在人脚下的布」。
func _world_uv(quad: PackedVector2Array, offset: Vector2) -> PackedVector2Array:
	var uv := PackedVector2Array()
	uv.resize(quad.size())
	for i in quad.size():
		uv[i] = quad[i] + offset
	return uv


## 横贯视野的溪流（局部坐标，_follow 里只跟 x 走）
func _build_river() -> Polygon2D:
	return _poly(PackedVector2Array([
		Vector2(-GROUND_HALF, RIVER_Y - RIVER_H),
		Vector2(GROUND_HALF, RIVER_Y - RIVER_H),
		Vector2(GROUND_HALF, RIVER_Y + RIVER_H),
		Vector2(-GROUND_HALF, RIVER_Y + RIVER_H),
	]), C_WATER, Vector2.ZERO, -12)


## 世界最南端的大海：从海岸线一路向南铺满（纵向世界坐标，横向跟着玩家走）。
## 海面盖在地面与区域色块之上、道路之下，压在溪流同一层。
func _build_sea() -> Polygon2D:
	var shore: float = RegionGenerator.SEA_SHORE_Y
	var south := shore + GROUND_HALF * 2.0
	return _poly(PackedVector2Array([
		Vector2(-GROUND_HALF, shore),
		Vector2(GROUND_HALF, shore),
		Vector2(GROUND_HALF, south),
		Vector2(-GROUND_HALF, south),
	]), C_WATER, Vector2.ZERO, -12)


## 海岸线以北的一条沙滩，夹在陆地与海面之间，让海岸一眼可辨
func _build_beach() -> Polygon2D:
	var shore: float = RegionGenerator.SEA_SHORE_Y
	var w: float = RegionGenerator.BEACH_W
	return _poly(PackedVector2Array([
		Vector2(-GROUND_HALF, shore - w),
		Vector2(GROUND_HALF, shore - w),
		Vector2(GROUND_HALF, shore),
		Vector2(-GROUND_HALF, shore),
	]), C_SAND, Vector2.ZERO, -13)


# ---------------------------------------------------------------- 道路

func _build_paths() -> void:
	for loc in WorldData.LOCATIONS:
		_build_path(loc)


## 从「离它最近的已有地点」拉一条小路过来。母村自己不用画；
## 路太远（超过 PATH_MAX_LEN）就不画，免得无限世界里拖出一条通天的长线。
## 路线交给 RegionGenerator 寻路：绕开高山，从桥过河，绝不穿山穿水；
## 万一找不到路就干脆不画这条。
func _build_path(loc: Dictionary) -> void:
	if str(loc.get("id", "")) == CultureData.HOME_ID:
		return
	var target: Vector2 = loc["pos"]
	var from := _nearest_pos(target, str(loc.get("id", "")))
	if from.distance_squared_to(target) < 1.0 or from.distance_to(target) > PATH_MAX_LEN:
		return
	var pts: PackedVector2Array = RegionGenerator.find_path(from, target)
	if pts.size() < 2:
		return
	var line := Line2D.new()
	line.points = pts
	line.width = 48.0
	line.default_color = _col(_palette, "path", C_PATH)
	line.z_index = -10
	add_child(line)
	# 记下这条折线，NPC 才能沿着路走而不是凭空乱窜
	_paths.append(pts)


## 离 p 最近的一条小路折线（世界坐标）。NPC 用它决定「出门遛弯」往哪走。
## 没有路（比如荒野孤屋）时返回空数组，NPC 就只在住处附近溜达。
func nearest_road_path(p: Vector2) -> PackedVector2Array:
	var best := PackedVector2Array()
	var best_d := INF
	for path in _paths:
		var d := INF
		for q in path:
			var dd: float = p.distance_squared_to(q)
			if dd < d:
				d = dd
		if d < best_d:
			best_d = d
			best = path
	return best


## 离 target 最近的其它地点位置（排除 exclude_id 本身）
func _nearest_pos(target: Vector2, exclude_id: String) -> Vector2:
	var best := target
	var best_d := INF
	for loc in WorldData.LOCATIONS:
		if str(loc["id"]) == exclude_id:
			continue
		var d: float = target.distance_to(loc["pos"])
		if d < best_d:
			best_d = d
			best = loc["pos"]
	return best


## 主路折线上离 p 最近的一点（顶点和线段内部都算）。没有主路时返回 Vector2.INF。
func _nearest_road_point(p: Vector2) -> Vector2:
	var best := Vector2.INF
	var best_d := INF
	for path in _paths:
		var n: int = path.size()
		for i in n:
			var q: Vector2 = path[i]
			var d: float = p.distance_squared_to(q)
			if d < best_d:
				best_d = d
				best = q
			if i + 1 < n:
				var proj: Vector2 = Geometry2D.get_closest_point_to_segment(p, q, path[i + 1])
				var pd: float = p.distance_squared_to(proj)
				if pd < best_d:
					best_d = pd
					best = proj
	return best


## 从门口铺一条小岔路接到最近的主路，门就「对着路」了。
## 先朝门口正前方（南）铺一小截「门前小路」，再斜着连到主路上最近的一点；
## 附近没有主路（荒野孤屋）、或主路太远，就干脆不铺。
func _build_door_spur(door_pos: Vector2) -> void:
	if _paths.is_empty():
		return
	var target := _nearest_road_point(door_pos)
	if not target.is_finite() or door_pos.distance_to(target) > DOOR_SPUR_MAX_LEN:
		return
	var line := Line2D.new()
	line.points = PackedVector2Array([
		door_pos, door_pos + Vector2(0.0, DOOR_STUB_LEN), target,
	])
	line.width = 26.0
	line.default_color = _col(_palette, "path", C_PATH)
	line.z_index = -10
	add_child(line)


# ---------------------------------------------------------------- 各类地标

func _build_location(loc: Dictionary) -> void:
	var pos: Vector2 = loc["pos"]
	var cid := str(loc.get("culture", CultureData.current_id))
	var pal := CultureData.palette_of(cid)
	var shape := CultureData.house_shape_of(cid)
	# 他乡的地点：先垫一层那个文化圈的草色地块，一眼看出「这儿不是本乡」
	if cid != CultureData.current_id:
		_poly(PackedVector2Array([
			Vector2(-230, -230), Vector2(230, -230), Vector2(230, 230), Vector2(-230, 230),
		]), _col(pal, "grass", C_GRASS), pos, -11)
	match str(loc["kind"]):
		"village":
			_build_village(loc, pos, cid)
		"city":
			_build_city(loc, pos, cid)
		"mine":
			_build_mine(pos, pal)
		"shrine":
			_build_shrine(pos, pal, shape)
		"forest":
			_build_forest(pos, pal)
		"ruin":
			_build_ruin(pos, pal)
		"bridge":
			_build_bridge(pos, pal)
		"camp":
			_build_camp(pos, pal)
		"tianfu":
			_build_tianfu(loc, pos, pal)
	_place_label(str(loc["name"]), pos)


## 给新住进世界的 NPC 盖一间小屋，让「住处」在地图上看得到。
## 小屋按这个 NPC 所属文化圈的样子盖（颜色 + 屋顶形状都可能不同）。
func add_npc_home(pos: Vector2, cid: String = "") -> void:
	var culture := cid if cid != "" else CultureData.current_id
	_house(pos, culture)


## 盖一栋房子。房屋按「档次 × 文化圈 × 变体」编号，变体由坐标稳定决定，
## 所以同一个位置每次进游戏都是同一栋；有 AI 画好的图就贴图，没有就程序化画。
## tier = "village" 是村庄民居，"city" 是城市楼房（更高大气派，走 city_ 前缀的独立图鉴）。
## 同时按坐标抽一份「体量规格」：大房子占地大、室内也大，高房子带二层。
## 门前挂一个交互区，玩家走近按 E 就能进屋。
func _house(pos: Vector2, cid: String, tier: String = "village") -> void:
	var variant := PropLibrary.variant_at(pos)
	var bid := PropLibrary.building_id(cid, variant, tier)
	var spec := PropLibrary.house_spec(pos, tier)
	var holder := Node2D.new()
	holder.position = pos
	# 不设 z_index：World 开了 Y 排序，房子与玩家/敌人按脚下位置交错遮挡，
	# 走到房子北面时房子会盖住玩家，房子才有「立体」的厚度感。
	add_child(holder)
	# 视觉层单独放一个容器：换贴图时整层重画，不会连门口那圈交互区一起误删
	var visual := Node2D.new()
	visual.name = "Visual"
	visual.scale = Vector2.ONE * float(spec.get("scale", 1.0))
	holder.add_child(visual)
	var entry := {
		"node": holder, "bid": bid, "cid": cid, "tier": tier, "spec": spec,
		"visual": visual, "textured": false,
	}
	_house_nodes.append(entry)
	_make_door(holder, pos, cid, bid, spec)
	# 门口铺一条小岔路连到主路：门就「对着路」了
	_build_door_spur(pos + Vector2(0.0, 14.0))
	_fill_house(entry)
	# 图鉴里还没这张图就排个队让 AI 画（生图关掉时这步什么都不做）
	if has_node("/root/BuildingGenerator"):
		BuildingGenerator.request(bid)


## 在门前挂一个交互区，玩家站上去按 E 请求进屋。
func _make_door(holder: Node2D, pos: Vector2, cid: String, bid: String, spec: Dictionary) -> void:
	var door := HOUSE_DOOR_SCRIPT.new()
	door.name = "Door"
	door.house_pos = pos
	door.setup({"bid": bid, "cid": cid, "spec": spec, "pos": pos})
	door.enter_requested.connect(_on_house_door_entered)
	holder.add_child(door)


func _on_house_door_entered(info: Dictionary) -> void:
	house_entered.emit(info)


## 把一栋房子的图形填进视觉层：有图鉴贴图就贴图，否则按变体程序化画一栋。
## 顺便在视觉层里放一个碰撞体：房子从此是实心的，玩家不能穿墙而过。
## 碰撞体只占房子底部的一小截「地基」，屋顶不挡人，玩家可以绕到房子后面走。
## 注意：碰撞体必须在这里建，因为换贴图时会把整个视觉层清空重画。
func _fill_house(entry: Dictionary) -> void:
	var visual: Node2D = entry["visual"]
	for c in visual.get_children():
		c.queue_free()
	entry["textured"] = false
	var bid := str(entry["bid"])
	var tier := str(entry.get("tier", PropLibrary.tier_of_building(bid)))
	var city := tier == "city"
	var tex := PropLibrary.building_texture(bid)
	if tex != null and tex.get_width() > 0 and tex.get_height() > 0:
		var sp := Sprite2D.new()
		sp.texture = tex
		var sz := PropLibrary.building_size_of(tier)
		# 等比缩放：整张图按原比例塞进视觉外框，不再横向拉宽、纵向压扁。
		# AI 出的房屋图长宽比不一（有 384x384，也有 256x384、384x256），
		# 以前直接按 (sz.x/w, sz.y/h) 拉伸，正方形图会被纵向压扁约 16%。
		var fit: float = minf(sz.x / float(tex.get_width()), sz.y / float(tex.get_height()))
		var disp := Vector2(float(tex.get_width()), float(tex.get_height())) * fit
		sp.scale = Vector2(fit, fit)
		# 贴图底边中点对齐到容器原点，房子才「站」在地面上
		sp.position = Vector2(0.0, -disp.y * 0.5)
		visual.add_child(sp)
		entry["textured"] = true
		# 贴图房：碰撞体只占贴图底部的一小截当「地基」，屋顶与楼层不挡人。
		# 这样玩家能绕到房子侧面、走到房子后面；配合 Y 排序，走到北面时房子
		# 会挡住玩家，房子看起来就是有厚度的立体物件，而不是一堵平面墙。
		_add_house_solid(visual, _textured_house_solid(bid, tex, fit))
		return
	_draw_house(visual, bid)
	if city:
		# 程序化城市楼：楼体高到 y=-104、底边在 y=24，碰撞只取底部一截当地基
		_add_house_solid(visual, Rect2(Vector2(-48.0, -34.0), Vector2(96.0, 36.0)))
	else:
		# 程序化民居：底边在 y=24、门在 y∈[2,24]，碰撞只取底部一截（底边压到门楣 y=2）
		var half := 32.0 if PropLibrary.variant_of_id(bid) == "c" else 28.0
		_add_house_solid(visual, Rect2(
			Vector2(-half - 2.0, -36.0),
			Vector2((half + 2.0) * 2.0, 38.0),
		))


## 贴图房的实心碰撞矩形（房子的本地坐标，底边在容器原点上方）。
func _textured_house_solid(bid: String, tex: Texture2D, fit: float) -> Rect2:
	return _textured_solid(bid, tex, fit, HOUSE_FOOT_RATIO)


## 贴图建筑的实心碰撞矩形（本地坐标）。只取贴图最底下的一截（占整高 ratio）
## 当地基/占地，上面的屋顶与楼层不挡人，玩家才能绕到侧面和后面走。
## 取贴图里非透明部分的外框（alpha 包围盒）定宽度与底边，结果按 key 缓存。
func _textured_solid(key: String, tex: Texture2D, fit: float, ratio: float) -> Rect2:
	if _house_solid_cache.has(key):
		return _house_solid_cache[key]
	var w := float(tex.get_width())
	var h := float(tex.get_height())
	# 贴图里真正画了东西的那块（透明边距不算）。取不到就退回整张贴图。
	var used := Rect2i(0, 0, tex.get_width(), tex.get_height())
	var img := tex.get_image()
	if img != null:
		var r := img.get_used_rect()
		if r.size.x > 0 and r.size.y > 0:
			used = r
	# 像素坐标 -> 本地坐标：贴图底边中点对齐容器原点，故左上角逐像素为
	# ((px - w/2) * fit, (py - h) * fit)。
	var full_h := float(used.size.y) * fit
	var bottom := (float(used.position.y + used.size.y) - h) * fit
	var foot_h := maxf(full_h * ratio, FOOT_MIN_HEIGHT)
	var rect := Rect2(
		Vector2((float(used.position.x) - w * 0.5) * fit, bottom - foot_h),
		Vector2(float(used.size.x) * fit, foot_h),
	)
	_house_solid_cache[key] = rect
	return rect


## 程序化功能建筑的兜底实心碰撞矩形：同样只取底部一截当地基（底边仍压在设施基线附近），
## 上面的结构不挡人，玩家能绕到设施后面。
func _procedural_facility_solid(tier: String) -> Rect2:
	if tier == "city":
		return Rect2(Vector2(-72.0, 4.0), Vector2(144.0, 36.0))
	return Rect2(Vector2(-62.0, -6.0), Vector2(124.0, 36.0))


## 给房子挂一块实心碰撞（挂在视觉层里，跟着房子的缩放一起缩放）
func _add_house_solid(visual: Node2D, rect: Rect2) -> void:
	var body := StaticBody2D.new()
	body.name = "Solid"
	var shape := CollisionShape2D.new()
	var rs := RectangleShape2D.new()
	rs.size = rect.size
	shape.shape = rs
	shape.position = rect.position + rect.size * 0.5
	body.add_child(shape)
	visual.add_child(body)


## 没有贴图时用代码画的占位房。村庄民居三个变体在宽窄、门窗、烟囱上略有差别；
## 城市楼房走 _draw_city_house，画成更高大的两层楼。
func _draw_house(holder: Node2D, bid: String) -> void:
	var cid := PropLibrary.culture_of_building(bid)
	var variant := PropLibrary.variant_of_id(bid)
	var pal := CultureData.palette_of(cid)
	var shape := CultureData.house_shape_of(cid)
	if PropLibrary.tier_of_building(bid) == "city":
		_draw_city_house(holder, pal, shape, variant)
		return
	var wide := variant == "c"
	var half := 32.0 if wide else 28.0
	# 本体
	_poly_in(holder, PackedVector2Array([
		Vector2(-half, -18), Vector2(half, -18), Vector2(half, 24), Vector2(-half, 24),
	]), _col(pal, "house", C_HOUSE), -2)
	# 门
	_poly_in(holder, PackedVector2Array([
		Vector2(-7, 24), Vector2(7, 24), Vector2(7, 2), Vector2(-7, 2),
	]), _col(pal, "trunk", C_TRUNK), -1)
	# 屋顶：按文化圈的屋顶形状来
	_poly_in(holder, _roof_shape(shape), _col(pal, "roof", C_ROOF), -1)
	# 变体 b / c 加一扇窗
	if variant != "a":
		_poly_in(holder, PackedVector2Array([
			Vector2(half - 20, -4), Vector2(half - 6, -4), Vector2(half - 6, 12), Vector2(half - 20, 12),
		]), Color(0.88, 0.83, 0.58), -1)
	# 变体 c 再加一根烟囱
	if variant == "c":
		_poly_in(holder, PackedVector2Array([
			Vector2(half - 18, -46), Vector2(half - 8, -46), Vector2(half - 8, -16), Vector2(half - 18, -16),
		]), _col(pal, "roof", C_ROOF), -1)


## 城市楼房的程序化画法：比民居高一大截的两层小楼。
## 一层石砌基座 + 拱形宽门，二层带一排窗，屋檐挑出并压线脚，顶上照样用本文化圈的屋顶形状。
func _draw_city_house(holder: Node2D, pal: Dictionary, shape: String, variant: String) -> void:
	var half := 46.0
	# 一层：砖石基座
	_poly_in(holder, PackedVector2Array([
		Vector2(-half, 24), Vector2(half, 24), Vector2(half, -22), Vector2(-half, -22),
	]), _col(pal, "rock_dark", C_ROCK_DARK), -3)
	# 二层：比一层收进一点，用房屋主色，形成层次
	_poly_in(holder, PackedVector2Array([
		Vector2(-half + 4.0, -22), Vector2(half - 4.0, -22), Vector2(half - 4.0, -74), Vector2(-half + 4.0, -74),
	]), _col(pal, "house", C_HOUSE), -3)
	# 两层之间的挑檐线脚
	_poly_in(holder, PackedVector2Array([
		Vector2(-half - 6.0, -20), Vector2(half + 6.0, -20), Vector2(half + 6.0, -30), Vector2(-half - 6.0, -30),
	]), _col(pal, "roof", C_ROOF), -2)
	# 正中宽门
	_poly_in(holder, PackedVector2Array([
		Vector2(-12, 24), Vector2(12, 24), Vector2(12, -6), Vector2(-12, -6),
	]), _col(pal, "trunk", C_TRUNK).darkened(0.12), -2)
	# 一层门两侧的窗
	for wx in [-28.0, 28.0]:
		_poly_in(holder, PackedVector2Array([
			Vector2(wx - 8, 12), Vector2(wx + 8, 12), Vector2(wx + 8, -4), Vector2(wx - 8, -4),
		]), Color(0.88, 0.83, 0.58), -2)
	# 二层一排窗
	for wx in [-28.0, 0.0, 28.0]:
		_poly_in(holder, PackedVector2Array([
			Vector2(wx - 8, -42), Vector2(wx + 8, -42), Vector2(wx + 8, -60), Vector2(wx - 8, -60),
		]), Color(0.88, 0.83, 0.58), -2)
	# 屋顶：把本文化圈的屋顶形状整体抬到二层顶上，并略微放大
	_poly_in(holder, _roof_shape_at(shape, -56.0, 1.24), _col(pal, "roof", C_ROOF), -1)
	# 变体 c 添一根烟囱
	if variant == "c":
		_poly_in(holder, PackedVector2Array([
			Vector2(half - 22, -104), Vector2(half - 8, -104), Vector2(half - 8, -72), Vector2(half - 22, -72),
		]), _col(pal, "roof", C_ROOF), -1)


## 屋顶多边形整体平移 + 横向缩放（城市楼房要把屋顶抬到二层之上）
func _roof_shape_at(shape: String, dy: float, spread: float = 1.0) -> PackedVector2Array:
	var pts := _roof_shape(shape)
	var out := PackedVector2Array()
	for p in pts:
		out.append(Vector2(p.x * spread, p.y + dy))
	return out


## 建筑图鉴里有新图到货时，把地图上对应 id 的房子换成贴图（已经贴了图的跳过）。
func _refresh_house_textures() -> void:
	# 新图到货：旧贴图的碰撞尺寸可能变了，缓存作废重算
	_house_solid_cache.clear()
	for entry in _house_nodes:
		var holder = entry["node"]
		if not is_instance_valid(holder):
			continue
		if bool(entry.get("textured", false)):
			continue
		if PropLibrary.has_building_texture(str(entry["bid"])):
			_fill_house(entry)
	for entry in _tianfu_palaces:
		var holder = entry["node"]
		if not is_instance_valid(holder):
			continue
		if bool(entry.get("textured", false)):
			continue
		if PropLibrary.has_building_texture(PropLibrary.TIANFU_PALACE_ID):
			_paint_tianfu_palace(entry)
	for entry in _facility_nodes:
		var holder = entry["node"]
		if not is_instance_valid(holder):
			continue
		if bool(entry.get("textured", false)):
			continue
		if PropLibrary.has_facility_texture(str(entry["fid"])):
			_fill_facility(entry)


func _build_village(loc: Dictionary, pos: Vector2, cid: String) -> void:
	# 注意：第三间房原本在 (30,76)，加上房子碰撞体后正好盖住玩家出生点（各文化圈约 (0,40~60)），
	# 一开局就会被顶在墙里。往下挪开，给出生点留出一条干净的空地。
	for off in [Vector2(-100, -46), Vector2(70, -80), Vector2(30, 132), Vector2(-120, 70)]:
		_house(pos + off, cid)
	# 村口的石堆
	var pal := CultureData.palette_of(cid)
	for off in [Vector2(180, 30), Vector2(-190, -30)]:
		_poly(PackedVector2Array([
			Vector2(-22, -16), Vector2(22, -16), Vector2(28, 16), Vector2(-28, 16),
		]), _col(pal, "rock", C_ROCK), pos + off, -1)
	# 功能性建筑按这个村子的规模摆：小村可能只有锻造台和商铺，大村才齐全
	_place_facilities(loc, pos, cid, "village")


## 城市：只有平原上升级出来的村子才会走这里。比村子大一圈：中央广场 + 环形房屋 + 市集。
func _build_city(loc: Dictionary, pos: Vector2, cid: String) -> void:
	var pal := CultureData.palette_of(cid)
	# 中央广场：一块铺石地面，让城市一眼就和村子不一样
	_poly(PackedVector2Array([
		Vector2(-210, 150), Vector2(210, 150), Vector2(210, -150), Vector2(-210, -150),
	]), _col(pal, "rock", C_ROCK).darkened(0.18), pos, -6)
	# 环城一圈房子（比村子多，间距也更大；走城市楼房图鉴，比村庄民居更高大气派）
	for off in [
		Vector2(-260, -70), Vector2(-40, -190), Vector2(180, -150),
		Vector2(280, 40), Vector2(150, 210), Vector2(-140, 230), Vector2(-300, 90),
	]:
		_house(pos + off, cid, "city")
	# 广场两侧的市集石柱
	for off in [Vector2(-130, 24), Vector2(130, 24)]:
		_poly(PackedVector2Array([
			Vector2(-14, 40), Vector2(14, 40), Vector2(14, -66), Vector2(-14, -66),
		]), _col(pal, "rock", C_ROCK), pos + off, -1)
	# 城市规模最大：功能建筑最齐全，且全是城市版本（更气派、功能更强）
	_place_facilities(loc, pos, cid, "city")


## 功能性建筑的名字：村庄一套（朴素），城市另有一套（更讲究）。
const FACILITY_NAMES := {
	"forge": "锻造台", "shop": "商铺", "inn": "客栈",
	"library": "藏书阁", "auction": "拍卖行",
	"board": "告示板", "clinic": "药铺", "stable": "马厩", "arena": "赌坊",
}
## 城市版的名字：同样一件事，城里叫法就不一样
const FACILITY_CITY_NAMES := {
	"board": "任务榜", "clinic": "医馆", "stable": "驿站", "arena": "竞技场",
}

## 聚落规模 → 这个聚落会有的功能性建筑种类。规模越大种类越多；最小的地方可能什么都没有。
## 每种建筑每个聚落最多一座（见 _place_facilities）。
const FACILITY_BY_SCALE := {
	1: ["forge", "shop"],
	2: ["forge", "shop", "inn", "library", "board", "clinic"],
	3: ["forge", "shop", "inn", "library", "auction", "board", "clinic", "stable", "arena"],
}

## 各功能建筑相对聚落中心的落位（村庄）。都摆在房子外围，互不重叠。
const FACILITY_VILLAGE_LAYOUT := {
	"forge": Vector2(200, 122), "shop": Vector2(-212, 132),
	"inn": Vector2(0, -178), "library": Vector2(212, -118),
	"board": Vector2(-310, -150), "clinic": Vector2(310, -150),
	"stable": Vector2(-310, 160), "arena": Vector2(310, 160),
	"auction": Vector2(0, 210),
}
## 各功能建筑相对聚落中心的落位（城市）。城更大，功能建筑摊在外圈。
const FACILITY_CITY_LAYOUT := {
	"forge": Vector2(105, 115), "shop": Vector2(-105, 115),
	"inn": Vector2(-165, -95), "library": Vector2(165, -95),
	"auction": Vector2(0, 150),
	"board": Vector2(-440, 140), "clinic": Vector2(440, 140),
	"stable": Vector2(-440, -140), "arena": Vector2(440, -140),
}


## 聚落规模：城市最大（3），母村次之（2），其它村庄按 id 稳定取 1~3。
## 小村子可能只有锻造台和商铺，大村子则五脏俱全；同一个村子每次进游戏规模都一样。
func _settlement_scale(loc: Dictionary, settlement_kind: String) -> int:
	if settlement_kind == "city":
		return 3
	if str(loc.get("id", "")) == "village":
		return 2
	return 1 + abs(hash(str(loc.get("id", "")))) % 3


## 功能建筑的名字：城市版优先，没有就退回村庄版
func _facility_name(kind: String, settlement_kind: String) -> String:
	if settlement_kind == "city" and FACILITY_CITY_NAMES.has(kind):
		return str(FACILITY_CITY_NAMES[kind])
	return str(FACILITY_NAMES.get(kind, "设施"))


## 按聚落规模决定摆哪些功能性建筑、各摆在哪儿（每种最多一座）。
func _place_facilities(loc: Dictionary, pos: Vector2, cid: String, settlement_kind: String) -> void:
	var scale := _settlement_scale(loc, settlement_kind)
	var kinds: Array = FACILITY_BY_SCALE.get(scale, FACILITY_BY_SCALE[1])
	var layout: Dictionary = FACILITY_CITY_LAYOUT if settlement_kind == "city" else FACILITY_VILLAGE_LAYOUT
	for kind in kinds:
		var k := str(kind)
		var off: Vector2 = layout.get(k, Vector2.ZERO)
		_facility(loc, pos + off, cid, k, settlement_kind)


## 摆一座功能性建筑：有 AI 画好的图就贴图，没有就程序化画个地面上的结构；
## 再挂一圈交互区，走近按 E 使用。
## 告示板 / 任务榜比较特殊：它得先以「委托发布人」的身份登记位置，任务复命时才知道该指回哪儿。
func _facility(loc: Dictionary, pos: Vector2, cid: String, kind: String, settlement_kind: String) -> void:
	var pal := CultureData.palette_of(cid)
	var tier := "city" if settlement_kind == "city" else "village"
	var fid := PropLibrary.facility_id(cid, kind, tier)
	var holder := Node2D.new()
	holder.position = pos
	# 同样不设 z_index，交给 World 的 Y 排序，玩家能绕到设施后面走
	add_child(holder)
	# 视觉层单独放一个容器：换贴图时整层重画，不会连交互区一起误删
	var visual := Node2D.new()
	visual.name = "Visual"
	holder.add_child(visual)
	var entry := {
		"node": holder, "visual": visual, "fid": fid, "cid": cid,
		"kind": kind, "tier": tier, "pal": pal, "textured": false,
	}
	_facility_nodes.append(entry)
	_fill_facility(entry)
	var fac_name := _facility_name(kind, settlement_kind)
	var info := {
		"kind": kind,
		"settlement_kind": settlement_kind,
		"pos": pos,
		"name": fac_name,
		"settlement_id": str(loc.get("id", "")),
		"settlement_name": str(loc.get("name", "")),
	}
	if kind == "board":
		var owner := "%s%s" % [str(loc.get("name", "")), fac_name]
		info["board_owner"] = owner
		NpcMemory.register(owner, pos)
	var fac := FACILITY_SCRIPT.new()
	fac.name = "Facility"
	fac.setup(info)
	fac.use_requested.connect(_on_facility_used)
	holder.add_child(fac)
	# 图鉴里还没这张图就排个队让 AI 画（生图关掉时这步什么都不做）
	if has_node("/root/BuildingGenerator"):
		BuildingGenerator.request(fid)


## 把一座功能建筑的图形填进视觉层：有图鉴贴图就贴图，否则程序化画一个。
## 顺便放一个实心碰撞体：碰撞体只占底部一截地基，玩家能绕到设施后面走，也走得到跟前按 E。
func _fill_facility(entry: Dictionary) -> void:
	var visual: Node2D = entry["visual"]
	for c in visual.get_children():
		c.queue_free()
	entry["textured"] = false
	var fid := str(entry["fid"])
	var tier := str(entry.get("tier", "village"))
	var tex := PropLibrary.facility_texture(fid)
	if tex != null and tex.get_width() > 0 and tex.get_height() > 0:
		var sp := Sprite2D.new()
		sp.texture = tex
		var sz := PropLibrary.facility_size_of(tier)
		var fit: float = minf(sz.x / float(tex.get_width()), sz.y / float(tex.get_height()))
		var disp := Vector2(float(tex.get_width()), float(tex.get_height())) * fit
		sp.scale = Vector2(fit, fit)
		# 贴图底边中点对齐到容器原点，设施才「站」在地面上
		sp.position = Vector2(0.0, -disp.y * 0.5)
		visual.add_child(sp)
		entry["textured"] = true
		_add_house_solid(visual, _textured_solid(fid, tex, fit, FACILITY_FOOT_RATIO))
		return
	_draw_facility(visual, entry["pal"], str(entry["kind"]), tier == "city")
	_add_house_solid(visual, _procedural_facility_solid(tier))


## 各类功能性建筑在地图上的样子（都是程序化画的贴地结构）。
## city=true 时先垫一圈更宽的石砌台基 + 四角金铆钉，一眼看出城里的比村里的气派。
func _draw_facility(holder: Node2D, pal: Dictionary, kind: String, city: bool) -> void:
	if city:
		_poly_in(holder, PackedVector2Array([
			Vector2(-70, 40), Vector2(70, 40), Vector2(64, -46), Vector2(-64, -46),
		]), _col(pal, "rock_dark", C_ROCK_DARK), -4)
		for cx in [-60.0, 60.0]:
			for cy in [-38.0, 32.0]:
				_poly_in(holder, PackedVector2Array([
					Vector2(cx - 4, cy + 4), Vector2(cx + 4, cy + 4), Vector2(cx + 4, cy - 4), Vector2(cx - 4, cy - 4),
				]), Color(0.95, 0.82, 0.35), -3)
	match kind:
		"inn":
			# 客栈：民居大小 + 门口挂一面幌子
			_poly_in(holder, PackedVector2Array([
				Vector2(-44, 22), Vector2(44, 22), Vector2(44, -26), Vector2(-44, -26),
			]), _col(pal, "house", C_HOUSE), -3)
			_poly_in(holder, PackedVector2Array([
				Vector2(-54, -26), Vector2(54, -26), Vector2(40, -52), Vector2(-40, -52),
			]), _col(pal, "roof", C_ROOF), -2)
			_poly_in(holder, PackedVector2Array([
				Vector2(-10, 22), Vector2(10, 22), Vector2(10, -6), Vector2(-10, -6),
			]), _col(pal, "trunk", C_TRUNK), -2)
			# 门前挂的客店幌子
			_poly_in(holder, PackedVector2Array([
				Vector2(26, 18), Vector2(46, 18), Vector2(46, -4), Vector2(26, -4),
			]), Color(0.86, 0.72, 0.34), -1)
		"library":
			# 藏书阁：比民居高一层檐，正面排着书架
			_poly_in(holder, PackedVector2Array([
				Vector2(-40, 22), Vector2(40, 22), Vector2(40, -34), Vector2(-40, -34),
			]), _col(pal, "house", C_HOUSE), -3)
			_poly_in(holder, PackedVector2Array([
				Vector2(-50, -34), Vector2(50, -34), Vector2(36, -58), Vector2(-36, -58),
			]), _col(pal, "shrine", C_SHRINE), -2)
			for i in 3:
				var x := -24.0 + float(i) * 20.0
				_poly_in(holder, PackedVector2Array([
					Vector2(x, 14), Vector2(x + 10, 14), Vector2(x + 10, -18), Vector2(x, -18),
				]), Color(0.62, 0.44, 0.28), -2)
		"auction":
			# 拍卖行：一座台基 + 顶棚，顶上挑一枚金币招牌
			_poly_in(holder, PackedVector2Array([
				Vector2(-56, 24), Vector2(56, 24), Vector2(48, 4), Vector2(-48, 4),
			]), _col(pal, "rock_dark", C_ROCK_DARK), -3)
			_poly_in(holder, PackedVector2Array([
				Vector2(-20, 6), Vector2(20, 6), Vector2(20, -22), Vector2(-20, -22),
			]), _col(pal, "trunk", C_TRUNK), -2)
			_poly_in(holder, PackedVector2Array([
				Vector2(-46, -22), Vector2(46, -22), Vector2(34, -46), Vector2(-34, -46),
			]), Color(0.74, 0.56, 0.22), -1)
			_poly_in(holder, PackedVector2Array([
				Vector2(0, -50), Vector2(11, -60), Vector2(0, -70), Vector2(-11, -60),
			]), Color(0.95, 0.82, 0.35), -1)
		"forge":
			# 锻造台：石砧 + 铁砧 + 炉火
			_poly_in(holder, PackedVector2Array([
				Vector2(-46, 26), Vector2(46, 26), Vector2(38, -6), Vector2(-38, -6),
			]), _col(pal, "rock_dark", C_ROCK_DARK), -3)
			_poly_in(holder, PackedVector2Array([
				Vector2(-20, -6), Vector2(20, -6), Vector2(14, -30), Vector2(-14, -30),
			]), _col(pal, "rock", C_ROCK), -2)
			_poly_in(holder, PackedVector2Array([
				Vector2(24, -6), Vector2(40, -6), Vector2(40, -24), Vector2(24, -24),
			]), Color(0.85, 0.4, 0.15), -1)
		"board":
			# 告示板 / 任务榜：两根立柱撑起一块木板，板上贴着委托告示
			for px in [-42.0, 42.0]:
				_poly_in(holder, PackedVector2Array([
					Vector2(px - 4, 34), Vector2(px + 4, 34), Vector2(px + 4, -30), Vector2(px - 4, -30),
				]), _col(pal, "trunk", C_TRUNK), -2)
			_poly_in(holder, PackedVector2Array([
				Vector2(-52, -8), Vector2(52, -8), Vector2(52, -50), Vector2(-52, -50),
			]), Color(0.66, 0.50, 0.32), -1)
			# 板上钉的告示纸：城里榜大，贴得更多
			var sheets: Array = [Vector2(-30, 0), Vector2(2, 0), Vector2(30, 0)] if city else [Vector2(-18, 0), Vector2(16, 0)]
			for sp in sheets:
				var sx: float = sp.x
				_poly_in(holder, PackedVector2Array([
					Vector2(sx - 9, -14), Vector2(sx + 9, -14), Vector2(sx + 9, -44), Vector2(sx - 9, -44),
				]), Color(0.94, 0.92, 0.84), 0)
		"clinic":
			# 药铺 / 医馆：一间铺面，门前挂一只药葫芦
			_poly_in(holder, PackedVector2Array([
				Vector2(-42, 24), Vector2(42, 24), Vector2(42, -30), Vector2(-42, -30),
			]), _col(pal, "house", C_HOUSE), -3)
			_poly_in(holder, PackedVector2Array([
				Vector2(-50, -30), Vector2(50, -30), Vector2(38, -52), Vector2(-38, -52),
			]), _col(pal, "roof", C_ROOF), -2)
			_poly_in(holder, PackedVector2Array([
				Vector2(-10, 24), Vector2(10, 24), Vector2(10, -6), Vector2(-10, -6),
			]), _col(pal, "trunk", C_TRUNK), -2)
			# 门旁挑出的药葫芦招牌（上细下圆两截）
			_poly_in(holder, PackedVector2Array([
				Vector2(22, 4), Vector2(30, 4), Vector2(30, -6), Vector2(22, -6),
			]), Color(0.78, 0.60, 0.22), -1)
			_poly_in(holder, PackedVector2Array([
				Vector2(18, -6), Vector2(34, -6), Vector2(34, -22), Vector2(18, -22),
			]), Color(0.86, 0.70, 0.28), -1)
		"stable":
			# 马厩 / 驿站：一间敞棚，棚前拴马桩上系着马
			_poly_in(holder, PackedVector2Array([
				Vector2(-46, 22), Vector2(46, 22), Vector2(46, -18), Vector2(-46, -18),
			]), _col(pal, "trunk", C_TRUNK), -3)
			_poly_in(holder, PackedVector2Array([
				Vector2(-58, -18), Vector2(58, -18), Vector2(42, -46), Vector2(-42, -46),
			]), _col(pal, "roof", C_ROOF), -2)
			# 棚里堆的干草
			_poly_in(holder, PackedVector2Array([
				Vector2(-40, 18), Vector2(-16, 18), Vector2(-20, -2), Vector2(-36, -2),
			]), Color(0.80, 0.70, 0.30), -2)
			# 拴马桩 + 马形剪影
			_poly_in(holder, PackedVector2Array([
				Vector2(26, 34), Vector2(32, 34), Vector2(32, -6), Vector2(26, -6),
			]), _col(pal, "trunk", C_TRUNK), -2)
			_poly_in(holder, PackedVector2Array([
				Vector2(20, 18), Vector2(44, 18), Vector2(48, 8), Vector2(30, 6), Vector2(18, 12),
			]), Color(0.42, 0.30, 0.22), -1)
		"arena":
			if city:
				# 竞技场：一座石砌擂台，四角插着红旗
				_poly_in(holder, PackedVector2Array([
					Vector2(-56, 24), Vector2(56, 24), Vector2(56, -30), Vector2(-56, -30),
				]), _col(pal, "rock", C_ROCK), -3)
				_poly_in(holder, PackedVector2Array([
					Vector2(-44, 12), Vector2(44, 12), Vector2(44, -20), Vector2(-44, -20),
				]), _col(pal, "rock_dark", C_ROCK_DARK), -2)
				for cx in [-58.0, 58.0]:
					for cy in [-34.0, 28.0]:
						_poly_in(holder, PackedVector2Array([
							Vector2(cx - 2, cy), Vector2(cx + 2, cy), Vector2(cx + 2, cy - 26), Vector2(cx - 2, cy - 26),
						]), _col(pal, "trunk", C_TRUNK), -1)
						_poly_in(holder, PackedVector2Array([
							Vector2(cx + 2, cy - 26), Vector2(cx + 18, cy - 20), Vector2(cx + 2, cy - 14),
						]), _col(pal, "shrine", C_SHRINE), 0)
			else:
				# 赌坊：一张蒙布的赌桌，两副骰盅
				_poly_in(holder, PackedVector2Array([
					Vector2(-48, 22), Vector2(48, 22), Vector2(48, -10), Vector2(-48, -10),
				]), _col(pal, "trunk", C_TRUNK), -3)
				_poly_in(holder, PackedVector2Array([
					Vector2(-42, 14), Vector2(42, 14), Vector2(42, -4), Vector2(-42, -4),
				]), Color(0.62, 0.20, 0.18), -2)
				for dx in [-18.0, 18.0]:
					_poly_in(holder, PackedVector2Array([
						Vector2(dx - 12, -4), Vector2(dx + 12, -4), Vector2(dx + 10, -20), Vector2(dx - 10, -20),
					]), Color(0.88, 0.80, 0.56), -1)
		_:
			# 商铺：一张带雨棚的货摊
			_poly_in(holder, PackedVector2Array([
				Vector2(-52, 24), Vector2(52, 24), Vector2(52, -4), Vector2(-52, -4),
			]), _col(pal, "trunk", C_TRUNK), -2)
			_poly_in(holder, PackedVector2Array([
				Vector2(-58, -4), Vector2(58, -4), Vector2(44, -34), Vector2(-44, -34),
			]), _col(pal, "roof", C_ROOF), -1)


func _on_facility_used(info: Dictionary) -> void:
	facility_used.emit(info)



func _build_mine(pos: Vector2, pal: Dictionary) -> void:
	# 贴地的一圈低矮碎石崖（无限世界里不再堆一座大山，免得挡住远处的地形）
	_poly(PackedVector2Array([
		Vector2(-175, 48), Vector2(-120, -14), Vector2(-40, -40),
		Vector2(60, -30), Vector2(140, 8), Vector2(175, 48),
	]), _col(pal, "rock_dark", C_ROCK_DARK), pos, -4)
	# 洞口
	_poly(PackedVector2Array([
		Vector2(-38, 48), Vector2(-38, 2), Vector2(0, -22),
		Vector2(38, 2), Vector2(38, 48),
	]), _col(pal, "cave", C_CAVE), pos, -3)
	# 洞口两侧支撑木
	_poly(PackedVector2Array([Vector2(-48, 48), Vector2(-38, 48), Vector2(-38, -6), Vector2(-48, 2)]), _col(pal, "trunk", C_TRUNK), pos, -2)
	_poly(PackedVector2Array([Vector2(38, 48), Vector2(48, 48), Vector2(48, 2), Vector2(38, -6)]), _col(pal, "trunk", C_TRUNK), pos, -2)
	# 洞口外散落的矿石
	for off in [Vector2(-110, 60), Vector2(120, 64), Vector2(-70, 84)]:
		_poly(PackedVector2Array([
			Vector2(-14, -10), Vector2(14, -10), Vector2(18, 10), Vector2(-18, 10),
		]), _col(pal, "rock", C_ROCK), pos + off, -1)
	# 矿口有野物守着，打死掉矿石
	_spawn_enemies(pos, ["ore_iron", "ore_iron", "ore_copper"], 2)


func _build_shrine(pos: Vector2, pal: Dictionary, shape: String) -> void:
	# 台基
	_poly(PackedVector2Array([
		Vector2(-90, 60), Vector2(90, 60), Vector2(70, 30), Vector2(-70, 30),
	]), _col(pal, "rock", C_ROCK), pos, -3)
	# 庙身
	_poly(PackedVector2Array([
		Vector2(-56, 30), Vector2(56, 30), Vector2(56, -30), Vector2(-56, -30),
	]), _col(pal, "house", C_HOUSE), pos, -2)
	# 庙顶：按文化圈的屋顶形状来
	var roof := _roof_shape(shape)
	var pts := PackedVector2Array()
	for p in roof:
		pts.append(Vector2(p.x * 2.2, -30.0 + p.y * 1.5))
	_poly(pts, _col(pal, "shrine", C_SHRINE), pos, -1)
	# 石灯
	for off in [Vector2(-120, 40), Vector2(120, 40)]:
		_poly(PackedVector2Array([
			Vector2(-12, 24), Vector2(12, 24), Vector2(12, -24), Vector2(-12, -24),
		]), _col(pal, "rock", C_ROCK), pos + off, -1)


func _build_forest(pos: Vector2, pal: Dictionary) -> void:
	# 无限世界里不再堆一圈「环状密林」，改成一片贴地散开的树林。
	# 用坐标播种，同一个位置每次进游戏长出来的树都一样。
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector2i(roundi(pos.x), roundi(pos.y)))
	for i in 30:
		var a := rng.randf() * TAU
		var radius := sqrt(rng.randf()) * 250.0
		_tree(pos + Vector2(cos(a), sin(a)) * radius, rng.randf_range(0.9, 1.45), pal)
	# 林子里藏着野物，打死掉木料与兽皮
	_spawn_enemies(pos, ["wood", "wood", "leather"], 3)


func _build_ruin(pos: Vector2, pal: Dictionary) -> void:
	# 破墙：三段高度不一的墙
	_poly(PackedVector2Array([Vector2(-70, 40), Vector2(-30, 40), Vector2(-30, -40), Vector2(-70, -14)]), _col(pal, "rock", C_ROCK), pos, -2)
	_poly(PackedVector2Array([Vector2(-20, 40), Vector2(24, 40), Vector2(24, -10), Vector2(-20, 4)]), _col(pal, "rock", C_ROCK), pos, -2)
	_poly(PackedVector2Array([Vector2(34, 40), Vector2(74, 40), Vector2(74, -56), Vector2(34, -30)]), _col(pal, "rock", C_ROCK), pos, -2)
	# 停转的风车：中心柱 + 四片叶
	_poly(PackedVector2Array([Vector2(-8, 40), Vector2(8, 40), Vector2(8, -90), Vector2(-8, -90)]), _col(pal, "trunk", C_TRUNK), pos, -1)
	for i in 4:
		var a := TAU * float(i) / 4.0 + PI / 4.0
		var blade := PackedVector2Array([Vector2(-10, 0), Vector2(10, 0), Vector2(10, -62), Vector2(-10, -62)])
		var rotated := PackedVector2Array()
		for p in blade:
			rotated.append(p.rotated(a) + Vector2(0, -90))
		_poly(rotated, _col(pal, "trunk", C_TRUNK), pos, -1)
	# 废墟里游荡的野物，偶尔掉晶石
	_spawn_enemies(pos, ["crystal", "ore_iron"], 2)


## 在野外地点周围放几只敌人。掉什么按地点给：矿口出矿石、林子出木料兽皮、废墟出晶石。
func _spawn_enemies(pos: Vector2, drops: Array, count: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector2i(roundi(pos.x), roundi(pos.y))) + 991
	for _i in count:
		var a := rng.randf() * TAU
		var radius := rng.randf_range(130.0, 270.0)
		var enemy := ENEMY_SCRIPT.new()
		var hp := 24 + int(rng.randf_range(0.0, 3.0)) * 6
		var drop: Dictionary = {}
		if not drops.is_empty():
			drop = {
				"id": str(drops[rng.randi() % drops.size()]),
				"count": 1 + int(rng.randf_range(0.0, 1.99)),
			}
		enemy.setup(hp, drop)
		enemy.position = pos + Vector2(cos(a), sin(a)) * radius
		add_child(enemy)


func _build_bridge(pos: Vector2, pal: Dictionary) -> void:
	# 桥面：南北向跨过溪流
	_poly(PackedVector2Array([
		Vector2(-58, -150), Vector2(58, -150), Vector2(58, 150), Vector2(-58, 150),
	]), _col(pal, "deck", C_DECK), pos, -8)
	# 两侧石栏
	for sx in [-1.0, 1.0]:
		_poly(PackedVector2Array([
			Vector2(sx * 58, -150), Vector2(sx * 74, -150),
			Vector2(sx * 74, 150), Vector2(sx * 58, 150),
		]), _col(pal, "rock", C_ROCK), pos, -7)
	# 桥中间的断口
	_poly(PackedVector2Array([
		Vector2(-26, 10), Vector2(26, 10), Vector2(18, 46), Vector2(-18, 46),
	]), C_WATER, pos, -6)


# ---------------------------------------------------------------- 通天福地

## 主殿的视觉外框。原程序化绘制里殿身 x∈[-56, 56]、穹顶最宽约 ±70，
## 自底边 y=26 到宝顶 y≈-209，取整成 150×240 作为贴图的等比缩放框。
const PALACE_SIZE := Vector2(150.0, 240.0)
## 主殿底边贴地的 y：容器原点往下这么多就是地面。
const PALACE_BASE_Y := 26.0

## 全世界独一份的秘境「通天福地」：暖玫瑰色的仙宫圆盘，白玉为阶、绯纱作殿，
## 暖金灯柱环列、成堆的宝箱与金珠散落一地，漫天花瓣浮动。处处透着一股撩人的富庶。
## 位置由 ensure_tianfu() 确定性选出，这里只管把它画得配得上「福地」二字。
func _build_tianfu(loc: Dictionary, pos: Vector2, pal: Dictionary) -> void:
	var rose := _col(pal, "grass", Color(0.30, 0.17, 0.24))
	var roof_col := _col(pal, "roof", Color(0.74, 0.26, 0.46))
	var house_col := _col(pal, "house", Color(0.70, 0.52, 0.46))
	# 白玉 / 暖金两个福地专属色，调色板里没有就地取近似
	var jade := Color(0.93, 0.91, 0.86)
	var jade_dim := Color(0.79, 0.77, 0.73)
	var gold := Color(1.0, 0.82, 0.40)
	var gold_deep := Color(0.82, 0.60, 0.22)

	# 暖玫瑰地面：三层同心圆盘，越往中心越亮，托出一座「浮在云上的仙台」
	_poly(_disc(330.0, 56), rose.darkened(0.16), pos, -10)
	_poly(_disc(272.0, 56), rose, pos, -9)
	_poly(_disc(216.0, 56), rose.lightened(0.16), pos, -8)
	# 四条暖金御道，从中心通向四方
	for i in 4:
		var a := TAU * float(i) / 4.0
		var dir := Vector2(cos(a), sin(a))
		var side := Vector2(-dir.y, dir.x) * 20.0
		_poly(PackedVector2Array([
			dir * 60.0 + side, dir * 300.0 + side, dir * 300.0 - side, dir * 60.0 - side,
		]), gold_deep.lightened(0.20), pos, -7)

	# 三层白玉圆台，层层收小，像一朵浮在盘上的莲花座
	_poly(_disc(158.0, 8), jade_dim, pos, -6)
	_poly(_disc(146.0, 8), jade, pos, -5)
	_poly(_disc(112.0, 8), jade_dim, pos, -5)
	_poly(_disc(102.0, 8), jade, pos, -4)
	_poly(_disc(76.0, 8), jade_dim, pos, -4)
	_poly(_disc(68.0, 8), jade, pos, -3)

	# 主殿：优先用 AI 画好的仙宫贴图，没有就程序化画一座（图鉴到货后原地换图）
	_fill_tianfu_palace(pos, house_col, roof_col, gold, gold_deep)

	# 四角小亭：各自一座白玉台、四根暖金柱、一顶绯色圆顶
	for corner in [Vector2(-196, -128), Vector2(196, -128), Vector2(-196, 152), Vector2(196, 152)]:
		_pavilion(pos + corner, jade, jade_dim, gold, roof_col)

	# 八根暖金灯柱，环列在圆台外圈，柱头一盏暖灯
	for i in 8:
		var a := TAU * float(i) / 8.0 + PI / 8.0
		_lamp_post(pos + Vector2(cos(a), sin(a)) * 190.0, jade_dim, gold)

	# 成堆的宝贝：四个宝箱，散在各处。每口都挂一圈交互区，走近按 E 就能开采。
	_treasure_chest(loc, 0, pos + Vector2(232, 44), gold, gold_deep)
	_treasure_chest(loc, 1, pos + Vector2(-238, -18), gold, gold_deep)
	_treasure_chest(loc, 2, pos + Vector2(104, 236), gold, gold_deep)
	_treasure_chest(loc, 3, pos + Vector2(-142, 224), gold, gold_deep)
	# 满地散落的金珠与钱串，越看越像「物资多到数不清」
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector2i(roundi(pos.x), roundi(pos.y))) + 761109337
	for i in 44:
		var a := rng.randf() * TAU
		var radius := 150.0 + sqrt(rng.randf()) * 160.0
		var at := pos + Vector2(cos(a), sin(a)) * radius
		_poly(_disc(rng.randf_range(3.0, 7.0), 7), gold.lerp(Color(1, 1, 1), rng.randf() * 0.5), at, -2)
	# 漫天飘落的花瓣，浮在整座福地之上
	for i in 40:
		var a := rng.randf() * TAU
		var radius := sqrt(rng.randf()) * 320.0
		var at := pos + Vector2(cos(a), sin(a)) * radius + Vector2(0, rng.randf_range(-40.0, 40.0))
		var s := rng.randf_range(3.0, 6.0)
		var petal := Color(1.0, 0.62, 0.78, rng.randf_range(0.35, 0.75))
		var rot := rng.randf() * TAU
		var shape := PackedVector2Array([
			Vector2(-s, 0), Vector2(0, -s * 1.6), Vector2(s, 0), Vector2(0, s * 0.6),
		])
		var rotated := PackedVector2Array()
		for p in shape:
			rotated.append(p.rotated(rot))
		_poly(rotated, petal, at, 4)


## 摆一座福地主殿：建一个容器当视觉层，有 AI 画好的仙宫贴图就贴，没有就程序化画一座。
## 故意不挂碰撞体：花魁云绯的站位偏移 (0,-20) 落在殿身矩形内，加实心会把 NPC 和玩家卡死。
func _fill_tianfu_palace(at: Vector2, house_col: Color, roof_col: Color, gold: Color, gold_deep: Color) -> void:
	var holder := Node2D.new()
	holder.position = at
	holder.z_index = 0
	add_child(holder)
	var visual := Node2D.new()
	visual.name = "Visual"
	holder.add_child(visual)
	var entry := {
		"node": holder, "visual": visual, "pos": at, "textured": false,
		"house": house_col, "roof": roof_col, "gold": gold, "gold_deep": gold_deep,
	}
	_tianfu_palaces.append(entry)
	_paint_tianfu_palace(entry)
	# 图鉴里还没这张图就排个队让 AI 画（生图关掉时这步什么都不做）
	# 注意：out of tree 时不能对绝对路径用 has_node，否则会刷一条报错
	if is_inside_tree() and has_node("/root/BuildingGenerator"):
		BuildingGenerator.request(PropLibrary.TIANFU_PALACE_ID)


## 按图鉴里的仙宫贴图重画主殿视觉层；没图就退回程序化画法。
func _paint_tianfu_palace(entry: Dictionary) -> void:
	var visual: Node2D = entry["visual"]
	for c in visual.get_children():
		c.queue_free()
	entry["textured"] = false
	var tex := PropLibrary.building_texture(PropLibrary.TIANFU_PALACE_ID)
	if tex != null and tex.get_width() > 0 and tex.get_height() > 0:
		var sp := Sprite2D.new()
		sp.texture = tex
		# 等比缩放：整张图按原比例塞进 PALACE_SIZE 外框，不横向拉宽、不纵向压扁
		var fit: float = minf(PALACE_SIZE.x / float(tex.get_width()), PALACE_SIZE.y / float(tex.get_height()))
		var disp := Vector2(float(tex.get_width()), float(tex.get_height())) * fit
		sp.scale = Vector2(fit, fit)
		# 贴图底边对齐殿基：容器原点往下 PALACE_BASE_Y 就是地面
		sp.position = Vector2(0.0, PALACE_BASE_Y - disp.y * 0.5)
		sp.z_index = -2
		visual.add_child(sp)
		entry["textured"] = true
		return
	_draw_tianfu_palace(visual, entry["house"], entry["roof"], entry["gold"], entry["gold_deep"])


## 没有贴图时的程序化仙宫：绯色殿身 + 绯纱殿门 + 高穹顶 + 暖金宝顶。
## 全部画进视觉层容器，坐标就是容器本地坐标（容器原点在殿基中心）。
func _draw_tianfu_palace(visual: Node2D, house_col: Color, roof_col: Color, gold: Color, gold_deep: Color) -> void:
	# 殿身：绯色的殿宇，前后收一收做成八角楼阁的样子
	_poly_in(visual, PackedVector2Array([
		Vector2(-56, 26), Vector2(56, 26), Vector2(52, 6), Vector2(46, -92), Vector2(-46, -92), Vector2(-52, 6),
	]), house_col.darkened(0.24), -3)
	_poly_in(visual, PackedVector2Array([
		Vector2(-44, -20), Vector2(44, -20), Vector2(44, -92), Vector2(-44, -92),
	]), house_col, -2)
	# 殿门：垂着一道绯色纱幔
	_poly_in(visual, PackedVector2Array([
		Vector2(-18, 26), Vector2(18, 26), Vector2(16, -26), Vector2(-16, -26),
	]), roof_col.darkened(0.10), -1)
	_poly_in(visual, PackedVector2Array([
		Vector2(-13, 26), Vector2(13, 26), Vector2(11, -22), Vector2(-11, -22),
	]), Color(0.98, 0.72, 0.80, 0.55), 0)
	# 穹顶：把 dome 形状拔高放大，罩住整个殿身
	var pts := PackedVector2Array()
	for p in _roof_shape("dome"):
		pts.append(Vector2(p.x * 1.95, -92.0 + (p.y + 18.0) * 2.15))
	_poly_in(visual, pts, roof_col, -1)
	# 顶上一颗暖金宝顶 + 一颗圆珠
	_poly_in(visual, PackedVector2Array([
		Vector2(-7, -166), Vector2(7, -166), Vector2(4, -198), Vector2(-4, -198),
	]), gold_deep, -1)
	var bead := PackedVector2Array()
	for p in _disc(11.0, 12):
		bead.append(p + Vector2(0, -198))
	_poly_in(visual, bead, gold, 0)


## 一座白玉小亭：圆台 + 四根暖金柱 + 一顶绯纱圆顶。
func _pavilion(at: Vector2, jade: Color, jade_dim: Color, gold: Color, roof_col: Color) -> void:
	_poly(_disc(52.0, 8), jade_dim, at, -4)
	_poly(_disc(44.0, 8), jade, at, -3)
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			_poly(PackedVector2Array([
				Vector2(sx * 30.0 - 4, sy * 22.0), Vector2(sx * 30.0 + 4, sy * 22.0),
				Vector2(sx * 26.0 + 4, -34.0), Vector2(sx * 26.0 - 4, -34.0),
			]), gold, at, -2)
	_poly(PackedVector2Array([
		Vector2(-58, -34), Vector2(58, -34), Vector2(44, -74), Vector2(-44, -74),
	]), roof_col, at, -1)
	_poly(_disc(9.0, 10), gold, at + Vector2(0, -74), 0)


## 一根暖金灯柱：细柱 + 柱头一盏发光的暖灯。远处看就是一簇暖金的亮点。
func _lamp_post(at: Vector2, post_col: Color, gold: Color) -> void:
	_poly(PackedVector2Array([
		Vector2(-4, 26), Vector2(4, 26), Vector2(3, -30), Vector2(-3, -30),
	]), post_col, at, -2)
	# 灯罩的暖光晕
	_poly(_disc(13.0, 12), Color(1.0, 0.86, 0.52, 0.30), at + Vector2(0, -36), 1)
	_poly(_disc(7.0, 12), gold, at + Vector2(0, -36), 2)
	_poly(_disc(3.5, 10), Color(1.0, 0.97, 0.86), at + Vector2(0, -36), 3)


## 摆一口福地宝箱：先把它画出来，再挂一圈交互区，走近按 E 开采。
## index 只用来给这口箱子一个稳定的编号（搭配据点 id 就是全局唯一的箱子身份）。
func _treasure_chest(loc: Dictionary, index: int, at: Vector2, gold: Color, gold_deep: Color) -> void:
	_chest(at, gold, gold_deep)
	var holder := Node2D.new()
	holder.name = "Treasure"
	holder.position = at
	holder.z_index = 1
	add_child(holder)
	var chest := TREASURE_SCRIPT.new()
	chest.name = "TreasureChest"
	chest.setup({
		"id": "%s_%d" % [str(loc.get("id", "tianfu")), index],
		"pos": at,
		"name": "%s的宝箱" % str(loc.get("name", "通天福地")),
	})
	chest.opened.connect(_on_treasure_opened)
	holder.add_child(chest)


## 玩家在宝箱前按了 E：往上报，发奖与记账由 main.gd 负责。
func _on_treasure_opened(info: Dictionary) -> void:
	treasure_opened.emit(info)


## 一个宝箱：绯木箱身 + 暖金包边 + 箱盖上一道弧 + 锁扣。gold/gold_deep 只是配色。
func _chest(at: Vector2, gold: Color, gold_deep: Color) -> void:
	var wood := Color(0.46, 0.26, 0.20)
	_poly(PackedVector2Array([
		Vector2(-24, 20), Vector2(24, 20), Vector2(24, -8), Vector2(-24, -8),
	]), wood, at, 1)
	# 箱盖：一个上凸的弧
	var lid := PackedVector2Array()
	for i in 9:
		var a := PI + PI * float(i) / 8.0
		lid.append(Vector2(cos(a) * 24.0, -8.0 + sin(a) * 14.0))
	_poly(lid, wood.lightened(0.12), at, 2)
	# 暖金包边与竖带
	_poly(PackedVector2Array([Vector2(-25, 12), Vector2(25, 12), Vector2(25, 18), Vector2(-25, 18)]), gold_deep, at, 3)
	_poly(PackedVector2Array([Vector2(-4, 20), Vector2(4, 20), Vector2(4, -20), Vector2(-4, -20)]), gold, at, 3)
	# 锁扣
	_poly(PackedVector2Array([Vector2(-6, 2), Vector2(6, 2), Vector2(6, -6), Vector2(-6, -6)]), gold, at, 4)
	# 箱口溢出来的一点金光
	_poly(_disc(30.0, 12), Color(1.0, 0.85, 0.45, 0.16), at + Vector2(0, -4), 0)


## 以原点为圆心、半径 r 的正 n 边形（用来拼圆盘 / 圆台 / 珠子）。
func _disc(r: float, n: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in n:
		var a := TAU * float(i) / float(n) - PI / 2.0
		pts.append(Vector2(cos(a) * r, sin(a) * r))
	return pts


# ---------------------------------------------------------------- 坏人据点

## 坏人据点：一圈木栅栏围着几顶帐篷，中间一堆篝火、一座瞭望塔、一面旗。
## 里面的守兵由 EnemyData 定种族与武器——地球人 / 非地球人混编，靠得近就打。
func _build_camp(pos: Vector2, pal: Dictionary) -> void:
	# 被踩秃的泥地
	_poly(PackedVector2Array([
		Vector2(-190, -70), Vector2(-140, -150), Vector2(-30, -180),
		Vector2(90, -170), Vector2(180, -90), Vector2(190, 40),
		Vector2(130, 150), Vector2(0, 180), Vector2(-120, 150), Vector2(-185, 60),
	]), Color(0.42, 0.34, 0.24), pos, -4)
	# 一圈尖木桩，南边留个营门
	var fence := Color(0.40, 0.28, 0.17)
	for i in 30:
		var a := TAU * float(i) / 30.0
		if absf(a - PI * 0.5) < 0.34:
			continue
		var foot := pos + Vector2(cos(a), sin(a)) * 172.0
		_poly(PackedVector2Array([
			Vector2(-5, 20), Vector2(5, 20), Vector2(5, -20), Vector2(0, -30), Vector2(-5, -20),
		]), fence, foot, -2)
	_tent(pos + Vector2(-78, -26), pal)
	_tent(pos + Vector2(78, 10), pal)
	_build_watchtower(pos + Vector2(2, -96), pal)
	_build_campfire(pos + Vector2(-2, 48))
	_build_banner(pos + Vector2(112, -70))
	_spawn_camp_guards(pos)


## 一顶帐篷：三角布面 + 深色门帘 + 门口一圈压石
func _tent(at: Vector2, pal: Dictionary) -> void:
	_poly(PackedVector2Array([
		Vector2(-42, 34), Vector2(42, 34), Vector2(0, -34),
	]), Color(0.55, 0.30, 0.24), at, -1)
	_poly(PackedVector2Array([
		Vector2(-14, 34), Vector2(14, 34), Vector2(0, 6),
	]), Color(0.22, 0.15, 0.11), at, 0)
	_poly(PackedVector2Array([
		Vector2(-46, 34), Vector2(46, 34), Vector2(46, 40), Vector2(-46, 40),
	]), _col(pal, "trunk", C_TRUNK), at, -1)


## 瞭望塔：四根斜腿撑起一个平台与顶棚
func _build_watchtower(at: Vector2, pal: Dictionary) -> void:
	var wood := _col(pal, "trunk", C_TRUNK)
	_poly(PackedVector2Array([Vector2(-30, 60), Vector2(-22, 60), Vector2(-12, -40), Vector2(-18, -40)]), wood, at, -1)
	_poly(PackedVector2Array([Vector2(22, 60), Vector2(30, 60), Vector2(18, -40), Vector2(12, -40)]), wood, at, -1)
	_poly(PackedVector2Array([Vector2(-30, -40), Vector2(30, -40), Vector2(30, -52), Vector2(-30, -52)]), Color(0.46, 0.32, 0.20), at, 0)
	_poly(PackedVector2Array([Vector2(-34, -52), Vector2(34, -52), Vector2(24, -78), Vector2(-24, -78)]), Color(0.50, 0.26, 0.20), at, 0)


## 篝火：一圈围石 + 两跳火苗
func _build_campfire(at: Vector2) -> void:
	for i in 6:
		var a := TAU * float(i) / 6.0
		_poly(PackedVector2Array([Vector2(-8, 6), Vector2(8, 6), Vector2(6, -6), Vector2(-6, -6)]),
			Color(0.36, 0.36, 0.38), at + Vector2(cos(a), sin(a)) * 22.0, -1)
	_poly(PackedVector2Array([Vector2(-13, 8), Vector2(13, 8), Vector2(0, -24)]), Color(1.0, 0.52, 0.18), at, 1)
	_poly(PackedVector2Array([Vector2(-7, 4), Vector2(7, 4), Vector2(0, -15)]), Color(1.0, 0.85, 0.40), at, 2)


## 一面破旗：木杆 + 三角旗
func _build_banner(at: Vector2) -> void:
	_poly(PackedVector2Array([Vector2(-3, 42), Vector2(3, 42), Vector2(3, -62), Vector2(-3, -62)]), Color(0.34, 0.24, 0.15), at, 0)
	_poly(PackedVector2Array([Vector2(3, -60), Vector2(42, -50), Vector2(3, -30)]), Color(0.68, 0.18, 0.16), at, 0)


## 据点里的守兵：4~6 人，种族 / 武器从 EnemyData 里抽。
## 掉锻造材料 + 一点金币；靠得近就会主动打过来（见 enemy.gd 的 GUARD_AGGRO）。
func _spawn_camp_guards(pos: Vector2) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector2i(roundi(pos.x), roundi(pos.y))) + 31337
	var count := 4 + rng.randi() % 3
	var drops := ["ore_iron", "wood", "leather", "ore_copper", "crystal"]
	for _i in count:
		var guard := EnemyData.roll_guard(rng)
		var enemy := ENEMY_SCRIPT.new()
		var drop: Dictionary = {
			"id": str(drops[rng.randi() % drops.size()]),
			"count": 1 + rng.randi() % 2,
		}
		enemy.setup(int(guard["hp"]), drop, str(guard["race"]), str(guard["weapon"]), int(guard["gold"]))
		var a := rng.randf() * TAU
		var radius := rng.randf_range(60.0, 150.0)
		enemy.position = pos + Vector2(cos(a), sin(a)) * radius
		add_child(enemy)


## 一棵树：一个容器装着影子 + 树干 + 一簇圆润的树冠，方便整棵建 / 卸。
## 树冠用好几个圆形团叠出来（暗色打底、亮色提亮），比原先几个三角色块有层次得多。
func _tree(pos: Vector2, scale: float, pal: Dictionary) -> Node2D:
	var holder := Node2D.new()
	holder.position = pos
	holder.z_index = -1
	add_child(holder)
	# 图鉴里有 AI 画的树就贴图，没有就退回程序化画的一簇树冠。
	# 按坐标稳定地挑变体、按这个位置所属文化圈挑那套树，同一棵树每次进游戏都一样。
	var cid := RegionGenerator.culture_at(pos)
	var variant := PropLibrary.tree_variant_at(pos)
	var tex := PropLibrary.tree_texture(cid, variant)
	if tex != null:
		var sz := PropLibrary.tree_size_of(variant)
		var fit: float = minf(sz.x / float(tex.get_width()), sz.y / float(tex.get_height())) * scale
		var disp := Vector2(float(tex.get_width()), float(tex.get_height())) * fit
		var sp := Sprite2D.new()
		sp.texture = tex
		sp.scale = Vector2(fit, fit)
		sp.position = Vector2(0.0, -disp.y * 0.5)
		holder.add_child(sp)
		return holder
	var trunk := _col(pal, "trunk", C_TRUNK)
	var leaf := _col(pal, "tree", C_TREE)
	var leaf_dark := _col(pal, "tree_dark", C_TREE_DARK)
	# 每棵树按坐标稳定地深浅错开一点，成片时不会像复制粘贴
	var v := float(abs(hash(Vector2i(pos))) % 1000) / 1000.0
	leaf = leaf.darkened(v * 0.14)
	leaf_dark = leaf_dark.darkened(v * 0.10)
	var leaf_light := leaf.lightened(0.16)
	# 地上的影子：让树「站」在地上，而不是浮着
	_poly_in(holder, _scaled(_canopy(Vector2(0, 22), 20.0, 0.32, 10), scale), Color(0, 0, 0, 0.15), -1)
	# 树干：根部略粗、往上收
	_poly_in(holder, _scaled([Vector2(-7, 24), Vector2(7, 24), Vector2(5, -18), Vector2(-5, -18)], scale), trunk, 0)
	# 树冠：两团暗色在后面打底，中间一团正色
	_poly_in(holder, _scaled(_canopy(Vector2(-13, -24), 20.0, 0.90, 11), scale), leaf_dark, 0)
	_poly_in(holder, _scaled(_canopy(Vector2(13, -26), 19.0, 0.90, 11), scale), leaf_dark, 0)
	_poly_in(holder, _scaled(_canopy(Vector2(0, -38), 21.0, 0.92, 12), scale), leaf, 0)
	# 前面两团亮的，做出受光的层次
	_poly_in(holder, _scaled(_canopy(Vector2(-9, -46), 17.0, 0.90, 11), scale), leaf, 0)
	_poly_in(holder, _scaled(_canopy(Vector2(9, -50), 15.0, 0.90, 11), scale), leaf_light, 0)
	_poly_in(holder, _scaled(_canopy(Vector2(-2, -60), 12.0, 0.90, 10), scale), leaf_light, 0)
	return holder


## 一个圆润的树冠团：把圆按 n 等分取样，y 方向压扁 squash 倍，看起来像一簇叶子。
func _canopy(c: Vector2, r: float, squash := 0.9, n := 12) -> Array:
	var pts: Array = []
	for i in n:
		var a := TAU * float(i) / float(n)
		pts.append(c + Vector2(cos(a) * r, sin(a) * r * squash))
	return pts


func _scaled(points: Array, scale: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in points:
		out.append(p * scale)
	return out


## 这个位置是否已经被地点、溪流或高山占用（树 / 石要避开）
func _is_occupied(p: Vector2) -> bool:
	for loc in WorldData.LOCATIONS:
		if p.distance_to(loc["pos"]) < 260.0:
			return true
	if absf(p.y - RIVER_Y) < RIVER_H + 90.0:
		return true
	# 海里与紧挨海岸的沙滩边缘不长树也不撒石
	if RegionGenerator.is_sea(p) or p.y > RegionGenerator.SEA_SHORE_Y - RegionGenerator.BEACH_W * 0.4:
		return true
	# 山上不长树也不撒石（省得草木浮在山体外侧）
	if RegionGenerator.is_highland(p):
		return true
	return false

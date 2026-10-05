extends Node
## 世界区域生成器（Autoload 名字：RegionGenerator）
##
## 世界是「无限大地图」：没有边界，走到哪里都有地。整张地图被切成无数个
## Voronoi 区域——每个区域是「离某个种子点最近的一片地」，形状不规则、大小随机。
##
## 三条规则：
##   1. 无限铺排：把世界按 CELL 边长切成无限网格，每个格子放一个种子点
##      （位置在格内随机抖动）。于是种子点无限多、区域也无限多。
##   2. 风格随机：每个区域从 CultureData 的 9 个文化圈里随机抽一个，
##      抽签结果 = hash(世界种子, 区域格子坐标)。同一个区域永远是同一种风格。
##   3. 一切由种子决定：同一颗世界种子 → 永远长出同一张地图，不必把整张地图写进存档，
##      档案里只要记一个 world_seed 即可。
##
## 本文件目前只是「骨架」：只负责算「某点在哪个区域 / 那个区域是什么风格 / 区域多大」，
## 还不管渲染与地点摆放；流式加载、区域内撒地点留到后续步骤接。
##
## 在此之上还多了一层**地形 / 海拔**：世界不是一望无际的平地，而是有大片平原、
## 缓坡丘陵和高耸的山脉。和区域一样，地形也完全由世界种子决定——同一颗种子
## 走到哪、哪座山多高，永远是同一个样子，存档里依旧只要一颗种子。

## 网格边长：每个格子放一个 Voronoi 种子点。格子越大，区域越大越稀疏。
const CELL := 1100.0
## 种子点在格内的随机偏移幅度（格边长的比例）。必须 < 0.5，
## 否则「最近的种子点」可能跑到隔壁格子外面，3×3 邻域搜索就找不全了。
const JITTER := 0.42

## 空间哈希的三个乘数（Earth mover 那套经典常数），保证不同格子 / 不同用途互不串味
const HASH_X := 73856093
const HASH_Y := 19349663
const SALT_JITTER := 2654435761    # 算种子点位置用的盐
const SALT_STYLE := 83492791       # 抽文化圈用的盐

## 地形：用一层比区域更大的方格做「平滑值噪声」当海拔。格子越大山越大、越疏。
const TERRAIN_CELL := 1800.0
const SALT_TERRAIN := 45238921     # 大尺度山系
const SALT_TERRAIN2 := 918273645   # 细尺度起伏（叠加在上一层之上）
## 出生地要压平：这样玩家一睁眼一定站在好走的平原上，不会被山困住。
const SPAWN_FLAT_RADIUS := 1300.0
const SPAWN_BLEND_RADIUS := 2800.0
const SPAWN_FLAT_LEVEL := 0.34
## 海拔分层阈值（0~1 的值噪声）
const LEVEL_HILL := 0.56
const LEVEL_MOUNTAIN := 0.70
const LEVEL_PEAK := 0.84

## 溪流：一条横贯世界的水带（中心线 y、半宽）。深水对玩家和寻路都是不可通行的。
## 全项目以这里为准；world_map / location_generator / scene_decorator 的画法与摆放都按它对齐。
const RIVER_Y := 1010.0
const RIVER_H := 90.0
## 桥面豁免：以 bridge 地点为原点的一块南北向矩形，落在里面的水面可以通行。
const BRIDGE_HALF_W := 58.0
const BRIDGE_HALF_L := 150.0

## 海：世界最南端一片没有对岸的大海。海岸线（y = SEA_SHORE_Y）及其以南全是水，
## 和很高的山一样是硬边界——玩家只能沿着海岸线绕行，不能下海。
const SEA_SHORE_Y := 4000.0
## 海岸线以北这么宽的一条是沙滩（能走），再往北才是普通陆地。
const BEACH_W := 300.0
## 海床 / 海岸的海拔：压得很低，保证海里与沙滩上不会冒出高山巨石。
const SEA_LEVEL := 0.22

## 寻路网格的参数：格子边长、起终点外扩的余量、单次最多建多少格（超了就放弃，免得卡顿）
const NAV_CELL := 100.0
const NAV_MARGIN := 500.0
const NAV_MAX_POINTS := 6000
## 寻路的四个「前向」方向（右、下、右下、右上），反向由双向连接补齐；
## 斜向只在两个正交邻格都可走时才连，避免从障碍的角缝里穿过去。
const NAV_DIRS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(1, -1)]
## 找不到可走格时的哨兵
const NAV_INVALID := Vector2i(2147483647, 2147483647)

## 世界种子。同一颗种子 = 同一张地图；换一颗 = 换一个全新的世界。
var world_seed: int = 0

## 已经算过的区域：Vector2i 格子坐标 -> 区域字典
## （骨架阶段不做淘汰；等接流式加载时，再按玩家距离清理远处的）
var _cache: Dictionary = {}


# ---------------------------------------------------------------- 区域坐标

## 一个世界坐标落在哪个「网格格子」里（纯数学，不涉及种子点）
func grid_cell_of(pos: Vector2) -> Vector2i:
	return Vector2i(floori(pos.x / CELL), floori(pos.y / CELL))


## 某个格子的 Voronoi 种子点（世界坐标）
func seed_point(cell: Vector2i) -> Vector2:
	var rng := _rng_for(cell, SALT_JITTER)
	var jitter := Vector2(rng.randf_range(-JITTER, JITTER), rng.randf_range(-JITTER, JITTER))
	return (Vector2(cell.x, cell.y) + Vector2(0.5, 0.5)) * CELL + jitter * CELL


## 任意一点落在哪个区域 —— 返回那个区域所属的格子坐标。
## 做法：连同周围 3×3 一起算，选离它最近的那个种子点。JITTER < 0.5 保证找得到。
func cell_at(pos: Vector2) -> Vector2i:
	var base := grid_cell_of(pos)
	var best := base
	var best_d := INF
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var c := base + Vector2i(dx, dy)
			var d := pos.distance_squared_to(seed_point(c))
			if d < best_d:
				best_d = d
				best = c
	return best


## 一个区域在 rect 范围内的「地块多边形」——把 rect 用一圈邻居的垂直平分线切出来，
## 就是该 Voronoi 区域落在这片范围内的形状。world_map 用它画区域色块。
## rect 之外的形状不关心，所以从 rect 起裁，天然就只覆盖「看得见的那部分」。
func cell_polygon(cell: Vector2i, rect: Rect2) -> PackedVector2Array:
	var pts: Array = [
		rect.position,
		rect.position + Vector2(rect.size.x, 0.0),
		rect.position + rect.size,
		rect.position + Vector2(0.0, rect.size.y),
	]
	var s := seed_point(cell)
	# 5×5 邻域足够定出一个格子的真实边界；JITTER < 0.5 时更远的种子点切不进来
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			if dx == 0 and dy == 0:
				continue
			pts = _clip_half_plane(pts, s, seed_point(cell + Vector2i(dx, dy)))
			if pts.size() < 3:
				return PackedVector2Array()
	var out := PackedVector2Array()
	for p in pts:
		out.append(p)
	return out


# ---------------------------------------------------------------- 区域数据

## 取一个区域的完整信息（带缓存）
func region_of_cell(cell: Vector2i) -> Dictionary:
	if _cache.has(cell):
		return _cache[cell]
	var ids := CultureData.all_ids()
	var rng := _rng_for(cell, SALT_STYLE)
	var culture := str(ids[rng.randi_range(0, ids.size() - 1)])
	var data := {
		"cell": cell,
		"center": seed_point(cell),
		"culture": culture,
		"radius": _estimate_radius(cell),
	}
	_cache[cell] = data
	return data


## 任意一点所在区域
func region_at(pos: Vector2) -> Dictionary:
	return region_of_cell(cell_at(pos))


## 任意一点所在区域属于哪个文化圈
func culture_at(pos: Vector2) -> String:
	return str(region_at(pos)["culture"])


## 任意一点所在区域的建筑风格描述（可直接喂给 AI）
func style_at(pos: Vector2) -> String:
	return CultureData.style_of(culture_at(pos))


## 区域尺度参考：到最近邻种子点距离的一半，约等于这个 Voronoi 单元的半径。
## 各区域之间这个值不一样 → 「区域大小是随机的」。
func _estimate_radius(cell: Vector2i) -> float:
	var p := seed_point(cell)
	var best := INF
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			if dx == 0 and dy == 0:
				continue
			best = minf(best, p.distance_to(seed_point(cell + Vector2i(dx, dy))))
	return best * 0.5


## 取一颗「世界种子 + 格子坐标 + 用途盐」决定的确定性随机源。
## 地表骨架（某格是不是聚落、撒什么草木）都靠它，保证同一世界走回头路看到的是同一片地。
func rng_for(cell: Vector2i, salt: int) -> RandomNumberGenerator:
	return _rng_for(cell, salt)


## 玩家附近的一片区域（后续流式加载按它决定「附近该显示哪些区域」）
func regions_in_radius(pos: Vector2, radius: float) -> Array:
	var span := int(ceil(radius / CELL)) + 1
	var base := grid_cell_of(pos)
	var out: Array = []
	for dy in range(-span, span + 1):
		for dx in range(-span, span + 1):
			var region := region_of_cell(base + Vector2i(dx, dy))
			if (region["center"] as Vector2).distance_to(pos) <= radius + CELL:
				out.append(region)
	return out


# ---------------------------------------------------------------- 地形 / 海拔

## 任意一点的海拔（0~1）。越大越高：低于 LEVEL_HILL 是平原，往上依次是丘陵、山、峰。
## 纯函数、只认世界种子，所以同一个位置永远算出同一个高度。
func elevation_at(pos: Vector2) -> float:
	# 两个八度的平滑值噪声叠加：大尺度定「山在哪」，细尺度让山脊不那么规整
	var big := _value_noise(pos, TERRAIN_CELL, SALT_TERRAIN)
	var detail := _value_noise(pos, TERRAIN_CELL * 0.5, SALT_TERRAIN2)
	var e := big * 0.72 + detail * 0.28
	# 出生地压平：半径内一律是低地，往外一段距离再平滑过渡到自然高度
	var r := pos.length()
	if r < SPAWN_FLAT_RADIUS:
		return SPAWN_FLAT_LEVEL
	if r < SPAWN_BLEND_RADIUS:
		var t := (r - SPAWN_FLAT_RADIUS) / (SPAWN_BLEND_RADIUS - SPAWN_FLAT_RADIUS)
		return lerpf(SPAWN_FLAT_LEVEL, e, t)
	# 海岸下沉：临近海岸线的一段平滑压到海平面以下，海里与沙滩上不会长出高山
	if pos.y > SEA_SHORE_Y - BEACH_W:
		var s := clampf((pos.y - (SEA_SHORE_Y - BEACH_W)) / BEACH_W, 0.0, 1.0)
		return lerpf(e, SEA_LEVEL, s)
	return e


## 任意一点属于哪种地形：plain（平原）/ hill（丘陵）/ mountain（山）/ peak（高峰）
func terrain_at(pos: Vector2) -> String:
	var e := elevation_at(pos)
	if e >= LEVEL_PEAK:
		return "peak"
	if e >= LEVEL_MOUNTAIN:
		return "mountain"
	if e >= LEVEL_HILL:
		return "hill"
	return "plain"


## 是不是「不好走的山」（山或峰）。地点、草木都会避开它。
func is_highland(pos: Vector2) -> bool:
	var t := terrain_at(pos)
	return t == "mountain" or t == "peak"


## 是不是深水（纯几何判断，不含桥梁豁免）：溪流的水带，或最南端的大海
func is_water(pos: Vector2) -> bool:
	if absf(pos.y - RIVER_Y) <= RIVER_H:
		return true
	return is_sea(pos)


## 是不是在海里（海岸线及其以南全是）
func is_sea(pos: Vector2) -> bool:
	return pos.y >= SEA_SHORE_Y


## 是否踩在桥面上：以某个 bridge 地点为原点的一块南北向矩形，落在里面的水面可以通行。
func _is_bridge_deck(pos: Vector2) -> bool:
	for loc in WorldData.LOCATIONS:
		if str(loc.get("kind", "")) != "bridge":
			continue
		var p: Vector2 = loc.get("pos", Vector2.ZERO)
		var d := pos - p
		if absf(d.x) <= BRIDGE_HALF_W and absf(d.y) <= BRIDGE_HALF_L:
			return true
	return false


## 这个点能不能走：深水（桥面除外）与高山挡路，其余平原 / 丘陵都放行。
func is_blocking(pos: Vector2) -> bool:
	if is_water(pos) and not _is_bridge_deck(pos):
		return true
	return is_highland(pos)


# ---------------------------------------------------------------- 寻路

## 从 from 走到 to 的一条可通行折线（世界坐标）：绕开深水（从桥过河）与高山。
## 被完全围死或范围太大时返回空数组，调用方据此放弃（宁可不画路，也不穿山穿水）。
func find_path(from: Vector2, to: Vector2) -> PackedVector2Array:
	var empty := PackedVector2Array()
	if from.distance_squared_to(to) < 1.0:
		return empty
	var lo := Vector2(minf(from.x, to.x), minf(from.y, to.y)) - Vector2(NAV_MARGIN, NAV_MARGIN)
	var hi := Vector2(maxf(from.x, to.x), maxf(from.y, to.y)) + Vector2(NAV_MARGIN, NAV_MARGIN)
	var c0 := Vector2i(floori(lo.x / NAV_CELL), floori(lo.y / NAV_CELL))
	var c1 := Vector2i(floori(hi.x / NAV_CELL), floori(hi.y / NAV_CELL))
	var w := c1.x - c0.x + 1
	var h := c1.y - c0.y + 1
	if w <= 0 or h <= 0 or w * h > NAV_MAX_POINTS:
		return empty

	# 1) 逐格采样「能不能走」
	var open := {}
	for iy in h:
		for ix in w:
			var id := c0 + Vector2i(ix, iy)
			if not _cell_blocked(_nav_center(id)):
				open[id] = true

	# 2) 建寻路图：相邻可走格连边（斜向不许切角）
	var astar := AStar2D.new()
	var idx := {}
	var next_id := 0
	for key in open.keys():
		var id: Vector2i = key
		idx[id] = next_id
		astar.add_point(next_id, _nav_center(id))
		next_id += 1
	for key in open.keys():
		var id: Vector2i = key
		var i := int(idx[id])
		for d in NAV_DIRS:
			var nid: Vector2i = id + d
			if not open.has(nid):
				continue
			if d.x != 0 and d.y != 0:
				if not open.has(id + Vector2i(d.x, 0)) or not open.has(id + Vector2i(0, d.y)):
					continue
			astar.connect_points(i, int(idx[nid]), true)

	# 3) 起终点各自吸附到最近的可走格，再问一条路径
	var a := _nearest_open(open, from)
	var b := _nearest_open(open, to)
	if a == NAV_INVALID or b == NAV_INVALID:
		return empty
	var path := astar.get_point_path(int(idx[a]), int(idx[b]))
	if path.size() < 2:
		return empty
	# 首尾换成真实坐标，路才贴到地点上
	path[0] = from
	path[path.size() - 1] = to
	return path


## 一个网格格子的中心世界坐标
func _nav_center(id: Vector2i) -> Vector2:
	return (Vector2(id) + Vector2(0.5, 0.5)) * NAV_CELL


## 一格是否被挡：格心 + 四角内缩采样，避免细障碍从格缝里漏过去
func _cell_blocked(center: Vector2) -> bool:
	if is_blocking(center):
		return true
	var q := NAV_CELL * 0.35
	return (
		is_blocking(center + Vector2(q, q)) or
		is_blocking(center + Vector2(-q, q)) or
		is_blocking(center + Vector2(q, -q)) or
		is_blocking(center + Vector2(-q, -q))
	)


## 离 pos 最近的一个可走格（从它所在格往外一圈圈找）；找不到返回 NAV_INVALID
func _nearest_open(open: Dictionary, pos: Vector2) -> Vector2i:
	var base := Vector2i(floori(pos.x / NAV_CELL), floori(pos.y / NAV_CELL))
	if open.has(base):
		return base
	for r in range(1, 9):
		var best := NAV_INVALID
		var best_d := INF
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if absi(dx) != r and absi(dy) != r:
					continue
				var id := base + Vector2i(dx, dy)
				if not open.has(id):
					continue
				var d := _nav_center(id).distance_squared_to(pos)
				if d < best_d:
					best_d = d
					best = id
		if best != NAV_INVALID:
			return best
	return NAV_INVALID


## 平滑值噪声：把平面按 cell_size 切格，格点上是确定性的随机值，
## 点值用 smoothstep 双线性插值，得到连续、没有硬边的起伏。
func _value_noise(pos: Vector2, cell_size: float, salt: int) -> float:
	var fx := pos.x / cell_size
	var fy := pos.y / cell_size
	var x0 := floori(fx)
	var y0 := floori(fy)
	var tx := _smooth(fx - float(x0))
	var ty := _smooth(fy - float(y0))
	var v00 := _hash01(Vector2i(x0, y0), salt)
	var v10 := _hash01(Vector2i(x0 + 1, y0), salt)
	var v01 := _hash01(Vector2i(x0, y0 + 1), salt)
	var v11 := _hash01(Vector2i(x0 + 1, y0 + 1), salt)
	return lerpf(lerpf(v00, v10, tx), lerpf(v01, v11, tx), ty)


## 格点上的确定性随机值（0~1）。
## 用整数雪崩哈希而不是「新建一个 RNG」——寻路 / 地形要大量采样，
## 每点都 new 一个 RNG 太贵；这里纯整数运算，快很多，且同样只认世界种子。
func _hash01(cell: Vector2i, salt: int) -> float:
	var h: int = world_seed
	h = (h ^ (cell.x * HASH_X) ^ (cell.y * HASH_Y) ^ salt) & 0xFFFFFFFF
	h = (h ^ (h >> 16)) & 0xFFFFFFFF
	h = (h * 0x7FEB352D) & 0xFFFFFFFF
	h = (h ^ (h >> 15)) & 0xFFFFFFFF
	h = (h * 0x846CA68B) & 0xFFFFFFFF
	h = (h ^ (h >> 16)) & 0xFFFFFFFF
	return float(h) / 4294967296.0


## smoothstep：让插值在格点附近变缓，去掉噪声的格子感
func _smooth(t: float) -> float:
	return t * t * (3.0 - 2.0 * t)


# ---------------------------------------------------------------- 世界种子

## 换一颗世界种子（会清空缓存，重新开始长地图）
func set_world_seed(s: int) -> void:
	if s == world_seed and not _cache.is_empty():
		return
	world_seed = s
	_cache.clear()


## 随便挑一颗新种子（新游戏用）
func randomize_world_seed() -> int:
	set_world_seed(int(Time.get_unix_time_from_system()) ^ randi())
	return world_seed


func cached_count() -> int:
	return _cache.size()


# ---------------------------------------------------------------- 存档

func to_save() -> Dictionary:
	return {"world_seed": world_seed}


func from_save(data: Dictionary) -> void:
	set_world_seed(int(data.get("world_seed", 0)))


# ---------------------------------------------------------------- 内部

## 用「到 a 比到 b 更近」这个半平面去裁多边形（Sutherland–Hodgman 单边裁剪）。
## 反复对所有邻居裁一遍，剩下的就是 a 的 Voronoi 单元。
func _clip_half_plane(poly: Array, a: Vector2, b: Vector2) -> Array:
	var mid := (a + b) * 0.5
	var n := (b - a).normalized()   # 朝 b 的外法线
	var out: Array = []
	var count := poly.size()
	for i in count:
		var p: Vector2 = poly[i]
		var q: Vector2 = poly[(i + 1) % count]
		var sp := (p - mid).dot(n)
		var sq := (q - mid).dot(n)
		if sp <= 0.0:
			out.append(p)
		if (sp < 0.0 and sq > 0.0) or (sp > 0.0 and sq < 0.0):
			out.append(p.lerp(q, sp / (sp - sq)))
	return out


## 用「世界种子 + 格子坐标 + 用途盐」拼出一颗确定性的随机源。
## 同格子同用途永远得到同一串随机数 → 地图可复现。
func _rng_for(cell: Vector2i, salt: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed ^ (cell.x * HASH_X) ^ (cell.y * HASH_Y) ^ salt
	return rng

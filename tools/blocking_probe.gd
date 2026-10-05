extends SceneTree
## 一次性验证工具：地形阻挡与寻路（RegionGenerator.is_water / is_blocking / find_path）
## 用法：godot --headless --path . --script res://tools/blocking_probe.gd
##
## 纯只读：只改内存里的世界种子，不写任何存档文件、不发任何网络请求。

var _rg                       # RegionGenerator
var _wd                       # WorldData
var _fail := 0
var _lines: PackedStringArray = []

const SEED := 20261004
const SCAN_STEP := 200.0
const SCAN_HALF := 22000.0


func _initialize() -> void:
	_run()


func _log(s: String) -> void:
	print(s)
	_lines.append(s)


func _ok(cond: bool, msg: String) -> void:
	if cond:
		_log("  [PASS] " + msg)
	else:
		_fail += 1
		_log("  [FAIL] " + msg)


## 折线的中间点（去掉首尾）里有没有被挡住的
func _interior_blocked(path: PackedVector2Array) -> bool:
	for i in range(1, path.size() - 1):
		if _rg.is_blocking(path[i]):
			return true
	return false


func _run() -> void:
	await process_frame
	_rg = root.get_node_or_null("RegionGenerator")
	_wd = root.get_node_or_null("WorldData")
	if _rg == null or _wd == null:
		_log("[probe] 缺少 RegionGenerator / WorldData autoload")
		quit(1)
		return
	_rg.set_world_seed(SEED)

	_section_spawn()
	_section_river()
	_section_bridge()
	_section_mountain()
	_section_path()
	_section_sea()

	if _fail == 0:
		_log("== 全部通过 ==")
		quit(0)
	else:
		_log("== 失败 %d 项 ==" % _fail)
		quit(1)


# ---------------------------------------------------------------- 1. 出生地好走

func _section_spawn() -> void:
	_log("== 1. 出生地与基础地点都能站人 ==")
	_ok(not _rg.is_blocking(Vector2.ZERO), "原点可以通行")
	_ok(not _rg.is_water(Vector2.ZERO), "原点不是水")
	var bad := ""
	for loc in _wd.LOCATIONS:
		if str(loc.get("kind", "")) == "bridge":
			continue
		if _rg.is_blocking(loc["pos"]):
			bad = str(loc.get("id", "?"))
	_ok(bad == "", "全部非桥基础地点可通行%s" % ("" if bad == "" else "（被挡：%s）" % bad))


# ---------------------------------------------------------------- 2. 溪流挡路

func _section_river() -> void:
	_log("== 2. 深水挡路 ==")
	_ok(_rg.is_water(Vector2(0.0, _rg.RIVER_Y)), "溪流中心是水")
	_ok(_rg.is_blocking(Vector2(0.0, _rg.RIVER_Y)), "溪流中心挡路")
	# 远离桥的一段深水也必须挡
	var far := Vector2(6000.0, _rg.RIVER_Y)
	_ok(_rg.is_water(far) and _rg.is_blocking(far), "远处深水（x=6000）同样挡路")
	# 北岸滩地可以走
	var bank := Vector2(0.0, _rg.RIVER_Y - _rg.RIVER_H - 40.0)
	_ok(not _rg.is_water(bank) and not _rg.is_blocking(bank), "溪流北岸滩地可通行")


# ---------------------------------------------------------------- 3. 桥可通行

func _section_bridge() -> void:
	_log("== 3. 桥面可通行 ==")
	var bridge := {}
	for loc in _wd.LOCATIONS:
		if str(loc.get("kind", "")) == "bridge":
			bridge = loc
			break
	if bridge.is_empty():
		_ok(false, "世界里找不到 bridge 地点")
		return
	var bp: Vector2 = bridge["pos"]
	# 桥正中（正好落在水带上）应该能走
	_ok(_rg.is_water(bp), "桥中心落在水带上")
	_ok(not _rg.is_blocking(bp), "桥中心可以通行")
	# 桥两端接岸
	_ok(not _rg.is_blocking(bp + Vector2(0.0, -_rg.BRIDGE_HALF_L)), "桥北端接岸可通行")
	_ok(not _rg.is_blocking(bp + Vector2(0.0, _rg.BRIDGE_HALF_L)), "桥南端接岸可通行")
	# 桥旁边的水（离开桥面）仍然挡
	var beside := Vector2(bp.x + 300.0, _rg.RIVER_Y)
	_ok(_rg.is_blocking(beside), "桥旁边的水仍然挡路")


# ---------------------------------------------------------------- 4. 高山挡 / 丘陵可走

func _section_mountain() -> void:
	_log("== 4. 高山挡路、丘陵可通行 ==")
	var hill := Vector2(INF, INF)
	var high := Vector2(INF, INF)
	var span := int((SCAN_HALF * 2.0) / SCAN_STEP)
	for ix in range(span + 1):
		if hill.x != INF and high.x != INF:
			break
		var x := -SCAN_HALF + float(ix) * SCAN_STEP
		for iy in range(span + 1):
			var p := Vector2(x, -SCAN_HALF + float(iy) * SCAN_STEP)
			var t: String = _rg.terrain_at(p)
			if hill.x == INF and t == "hill":
				hill = p
			if high.x == INF and (t == "mountain" or t == "peak"):
				high = p
			if hill.x != INF and high.x != INF:
				break
	_ok(hill.x != INF, "采样里找到丘陵")
	_ok(high.x != INF, "采样里找到高山")
	if hill.x != INF:
		_ok(not _rg.is_blocking(hill), "丘陵（%s）可以通行" % str(hill))
	if high.x != INF:
		_ok(_rg.is_highland(high) and _rg.is_blocking(high), "高山（%s）挡住去路" % str(high))


# ---------------------------------------------------------------- 5. 寻路

func _section_path() -> void:
	_log("== 5. 寻路绕行 ==")

	# 5a 河两岸：必须走桥
	var north := Vector2(0.0, _rg.RIVER_Y - 400.0)
	var south := Vector2(0.0, _rg.RIVER_Y + 400.0)
	var cross: PackedVector2Array = _rg.find_path(north, south)
	_ok(cross.size() >= 2, "北岸 → 南岸找得到一条路（%d 点）" % cross.size())
	if cross.size() >= 2:
		_ok(not _interior_blocked(cross), "过河路线不穿山不涉水")
		var used_bridge := false
		for i in range(1, cross.size() - 1):
			if _rg.is_water(cross[i]) and not _rg.is_blocking(cross[i]):
				used_bridge = true
		_ok(used_bridge, "过河路线确实是踩着桥面过去的")
		var end_y: float = cross[cross.size() - 1].y
		_ok(end_y > _rg.RIVER_Y + _rg.RIVER_H, "路线终点到达南岸（y=%.0f）" % end_y)

	# 5b 绕山：在山体两侧各取一点，路线不许从山里穿过
	var high := Vector2(INF, INF)
	var span := int((SCAN_HALF * 2.0) / SCAN_STEP)
	for ix in range(span + 1):
		if high.x != INF:
			break
		var x := -SCAN_HALF + float(ix) * SCAN_STEP
		for iy in range(span + 1):
			var p := Vector2(x, -SCAN_HALF + float(iy) * SCAN_STEP)
			if _rg.is_highland(p):
				high = p
				break
	if high.x == INF:
		_ok(false, "找不到高山，无法验证绕山")
	else:
		var a := high + Vector2(-1400.0, 0.0)
		var b := high + Vector2(1400.0, 0.0)
		if _rg.is_blocking(a) or _rg.is_blocking(b):
			_log("  [SKIP] 山两侧取点落进了障碍，换个位置再验")
			a = high + Vector2(0.0, -1400.0)
			b = high + Vector2(0.0, 1400.0)
		var detour: PackedVector2Array = _rg.find_path(a, b)
		if detour.size() < 2:
			_log("  [SKIP] 这两点之间没有可走的路（被完全围死），跳过")
		else:
			var straight := a.distance_to(b)
			var walked := 0.0
			for i in range(detour.size() - 1):
				walked += detour[i].distance_to(detour[i + 1])
			_ok(not _interior_blocked(detour), "绕山路线不穿山（%d 点）" % detour.size())
			_ok(walked >= straight - 1.0, "绕行路程 ≥ 直线距离（%.0f ≥ %.0f）" % [walked, straight])

	# 5c 母村 → 桥：一条真实存在的路
	var home := Vector2.ZERO
	var bridge := Vector2.ZERO
	for loc in _wd.LOCATIONS:
		var kind := str(loc.get("kind", ""))
		if kind == "village":
			home = loc["pos"]
		elif kind == "bridge":
			bridge = loc["pos"]
	var hb: PackedVector2Array = _rg.find_path(home, bridge)
	_ok(hb.size() >= 2, "母村 → 桥 找得到路（%d 点）" % hb.size())
	if hb.size() >= 2:
		_ok(not _interior_blocked(hb), "母村到桥的路不穿山不涉水")


# ---------------------------------------------------------------- 6. 海域

func _section_sea() -> void:
	_log("== 6. 海是硬边界 ==")
	# 深海：一定是水、一定挡路
	var deep := Vector2(0.0, _rg.SEA_SHORE_Y + 200.0)
	_ok(_rg.is_sea(deep) and _rg.is_water(deep), "海岸线以南是海水")
	_ok(_rg.is_blocking(deep), "深海挡路")
	var far_deep := Vector2(8000.0, _rg.SEA_SHORE_Y + 600.0)
	_ok(_rg.is_sea(far_deep) and _rg.is_blocking(far_deep), "远处深海（x=8000）同样挡路")
	# 沙滩（海岸线以北）：能走
	var beach := Vector2(0.0, _rg.SEA_SHORE_Y - 150.0)
	_ok(not _rg.is_water(beach), "海岸线以北的沙滩不是水")
	_ok(not _rg.is_blocking(beach), "沙滩可以通行")
	# 海岸下沉：海里压得很低，不会因为地形长出高山（挡路是因为水，不是因为山）
	_ok(not _rg.is_highland(deep), "海里不长高山")
	# 硬边界：从内陆走不到深海（海把整条去路堵死，不是绕一绕就能过去）
	var inland := Vector2(0.0, _rg.RIVER_Y - 400.0)
	var to_deep: PackedVector2Array = _rg.find_path(inland, Vector2(0.0, _rg.SEA_SHORE_Y + 2000.0))
	_ok(to_deep.size() == 0, "陆地 → 深海 没有通路（海是硬边界）")
	# 沿陆地走到海岸边：有路，且不涉水（终点停在海岸线以北）
	var coast := Vector2(0.0, _rg.SEA_SHORE_Y - 200.0)
	var to_coast: PackedVector2Array = _rg.find_path(Vector2.ZERO, coast)
	_ok(to_coast.size() >= 2, "母村 → 海岸边 找得到路（%d 点）" % to_coast.size())
	if to_coast.size() >= 2:
		_ok(not _interior_blocked(to_coast), "去海边的路不穿山不涉水")
		var end_y: float = to_coast[to_coast.size() - 1].y
		_ok(end_y < _rg.SEA_SHORE_Y, "路线终点停在海岸线以北（y=%.0f）" % end_y)

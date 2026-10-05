extends SceneTree
## 一次性验证工具：区域边界可视化（第 2 步）
## 用法：godot --headless --path . --script res://tools/region_viz_probe.gd
##
## 验证两件事：
##   A. Voronoi 地块多边形（RegionGenerator.cell_polygon）算得对不对
##      —— 随机撒点，点必须落在「它所属格子」的多边形里，且不在相邻格子的多边形里；
##   B. world_map 真的把区域色块画出来了（色块 / 描边数量 > 0），且无脚本报错。

const COVER := Rect2(-3000, -3000, 6000, 6000)

var _rg
var _fail := 0


func _initialize() -> void:
	_run()


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("  [PASS] " + msg)
	else:
		_fail += 1
		print("  [FAIL] " + msg)


func _run() -> void:
	await process_frame
	_rg = root.get_node_or_null("RegionGenerator")
	if _rg == null:
		push_error("[probe] 缺少 RegionGenerator autoload")
		quit(1)
		return
	_rg.set_world_seed(424242)

	_test_polygons()
	await _test_render()

	print("----------------------------------------")
	if _fail == 0:
		print("全部通过")
	else:
		print("失败 %d 项" % _fail)
	quit(0 if _fail == 0 else 1)


func _test_polygons() -> void:
	print("== A. Voronoi 地块多边形 ==")
	var c0: Vector2i = _rg.grid_cell_of(COVER.position)
	var c1: Vector2i = _rg.grid_cell_of(COVER.position + COVER.size)
	var cells: Array = []
	for cy in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			cells.append(Vector2i(cx, cy))

	var bad_count := 0
	var min_area := INF
	var max_area := 0.0
	for cell in cells:
		var poly: PackedVector2Array = _rg.cell_polygon(cell, COVER)
		if poly.size() < 3:
			bad_count += 1
			continue
		var a := _area(poly)
		min_area = minf(min_area, a)
		max_area = maxf(max_area, a)
	_ok(bad_count == 0, "全 %d 个格子都切出了合法多边形（失败 %d）" % [cells.size(), bad_count])
	print("     多边形面积：min %.0f / max %.0f（世界种子 424242）" % [min_area, max_area])
	_ok(max_area > min_area * 1.05, "不同区域面积确实有差异（形状/大小随机）")

	# 随机撒点：点必须落在自己格子的多边形里
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261004
	var inside_fail := 0
	var neighbor_fail := 0
	var samples := 2000
	var test_rect := COVER.grow(-60.0)   # 避开贴边点，边界归属本来就有歧义
	for i in samples:
		var p := Vector2(
			rng.randf_range(test_rect.position.x, test_rect.position.x + test_rect.size.x),
			rng.randf_range(test_rect.position.y, test_rect.position.y + test_rect.size.y)
		)
		var cell: Vector2i = _rg.cell_at(p)
		var poly: PackedVector2Array = _rg.cell_polygon(cell, COVER)
		if not Geometry2D.is_point_in_polygon(p, poly):
			inside_fail += 1
			if inside_fail <= 3:
				print("     落在自家多边形外: 点%s 格%s" % [str(p), str(cell)])
		# 交叉检查：不该落进相邻格子的多边形
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nb: PackedVector2Array = _rg.cell_polygon(cell + d, COVER)
			if nb.size() >= 3 and Geometry2D.is_point_in_polygon(p, nb):
				neighbor_fail += 1
				break
	_ok(inside_fail == 0, "%d 个随机点全部落在所属区域多边形内（失败 %d）" % [samples, inside_fail])
	_ok(neighbor_fail == 0, "%d 个随机点没有一个落进相邻区域（失败 %d）" % [samples, neighbor_fail])

	# 取一格，肉眼检查点数量与坐标范围
	var probe_cell := Vector2i(0, 0)
	var probe_poly: PackedVector2Array = _rg.cell_polygon(probe_cell, COVER)
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for v in probe_poly:
		mn = mn.min(v)
		mx = mx.max(v)
	_ok(probe_poly.size() >= 3, "格(0,0) 多边形有 %d 个顶点" % probe_poly.size())
	print("     格(0,0) 包围盒: %s ~ %s（种子点 %s）" % [str(mn), str(mx), str(_rg.seed_point(probe_cell))])


func _test_render() -> void:
	print("== B. world_map 画出区域色块 ==")
	var map_script = load("res://scripts/world_map.gd")
	if map_script == null:
		_ok(false, "world_map.gd 加载失败")
		return
	var map = map_script.new()
	root.add_child(map)
	await process_frame
	await process_frame
	var fills := 0
	var edges := 0
	for child in map.get_children():
		if child is Polygon2D and child.z_index == int(map.REGION_FILL_Z):
			fills += 1
		elif child is Line2D and child.z_index == int(map.REGION_EDGE_Z):
			edges += 1
	_ok(fills > 0, "画出 %d 块区域色块" % fills)
	_ok(edges == fills, "描边数量与色块一致：%d / %d" % [edges, fills])
	map.queue_free()


func _area(poly: PackedVector2Array) -> float:
	var s := 0.0
	var n := poly.size()
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		s += a.x * b.y - b.x * a.y
	return absf(s) * 0.5

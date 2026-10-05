extends SceneTree
## 冒烟测试：真正加载 main.tscn 跑一遍，验证「走到哪生成哪」在完整游戏里成立。
## 用法：godot --headless --path . --script res://tools/boot_walk_probe.gd
##
## 覆盖 region_probe / stream_probe / region_viz_probe 都没碰到的整合路径：
##   main.tscn 能起来 → player 每帧上报位置 → 流式生成的地点被 world_map 立刻画出来
##   → 玩家越走越远时，地图的「区域色块 / 草木」窗口大小始终受控（不会随走远而爆炸）。
##
## 纯只读：只在内存里改 WorldData，不写任何存档 / 缓存文件。

var _cul
var _wd
var _lg
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
	_cul = root.get_node_or_null("CultureData")
	_wd = root.get_node_or_null("WorldData")
	_lg = root.get_node_or_null("LocationGenerator")
	_rg = root.get_node_or_null("RegionGenerator")
	for n in [_cul, _wd, _lg, _rg]:
		if n == null:
			push_error("[probe] 缺少 autoload 节点")
			quit(1)
			return

	# 全线离线：凡是会调大模型 / 生图的生成器都切 mock / 关闭
	for gen_name in ["LocationGenerator", "SceneDecorator", "NpcGenerator", "DialogueGenerator", "StoryDirector", "BuildingGenerator", "PortraitGenerator"]:
		var gen = root.get_node_or_null(gen_name)
		if gen == null:
			continue
		if "mode" in gen:
			gen.mode = "mock"
		if "image_mode" in gen:
			gen.image_mode = "off"

	var packed: PackedScene = load("res://scenes/main.tscn")
	var scene = packed.instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame

	var world = scene.get_node_or_null("World")
	var player = scene.get_node_or_null("World/Player")
	_ok(world != null, "main.tscn 加载成功，World 节点存在")
	_ok(player != null, "Player 存在（World 的子节点）")
	if world == null or player == null:
		quit(1)
		return

	var wm = load("res://scripts/world_map.gd")

	# ---- 1. 地图骨架：地面跟随块 + 区域色块 ----
	print("== 1. 地图骨架 ==")
	var has_ground := false
	var has_river := false
	var has_fill := false
	for c in world.get_children():
		if c is Polygon2D and c.z_index == -20:
			has_ground = true
		if c is Polygon2D and c.z_index == -12:
			has_river = true
		if c is Polygon2D and c.z_index == int(wm.REGION_FILL_Z):
			has_fill = true
	_ok(has_ground, "建出了跟随玩家的地面块")
	_ok(has_river, "建出了横贯视野的溪流")
	_ok(has_fill, "建出了区域色块")

	# ---- 2. player.gd 每帧上报位置（流式入口接通）----
	print("== 2. 玩家位置上报 ==")
	player.global_position = Vector2(0.0, 40.0)
	await physics_frame
	await physics_frame
	_ok(bool(_lg._player_ready), "玩家位置已上报给 LocationGenerator")

	# ---- 3. 走到远处 → 流式生成 + 地图立刻画出来 ----
	print("== 3. 走到哪生成哪（含地图即时呈现）==")
	var before_locs: int = _wd.LOCATIONS.size()
	var before_kids: int = world.get_child_count()
	# 走一个远处的陆地（往北，远离最南端的大海）
	var far := Vector2(7000.0, -5000.0)
	player.global_position = far
	await physics_frame
	_lg.report_player_position(far)
	var ticks := 0
	while _wd.LOCATIONS.size() - before_locs < 3 and ticks < 60:
		_lg._stream()
		await process_frame
		ticks += 1
	await process_frame
	var made: int = _wd.LOCATIONS.size() - before_locs
	_ok(made >= 3, "玩家走到远处后流式生出至少 3 个新地点（实际 %d）" % made)
	_ok(world.get_child_count() > before_kids,
		"新地点一出现地图就把它画好了（世界子节点 %d → %d）" % [before_kids, world.get_child_count()])

	var near := true
	var far_d := 0.0
	for i in range(before_locs, _wd.LOCATIONS.size()):
		var loc: Dictionary = _wd.LOCATIONS[i]
		var lp: Vector2 = loc["pos"]
		var d: float = lp.distance_to(far)
		far_d = maxf(far_d, d)
		if d > float(_lg.STREAM_RADIUS) + 2.0 * float(_rg.CELL):
			near = false
	_ok(near, "新地点都长在玩家附近（最远 %.0f）" % far_d)

	# ---- 4. 越走越远：区域 / 草木窗口大小必须受控 ----
	print("== 4. 无限行走时渲染窗口受控 ==")
	var max_regions := 0
	var max_decor := 0
	var pos := far
	for step in 24:
		pos += Vector2(1500.0, -700.0)
		player.global_position = pos
		world._refresh_view(pos)
		await process_frame
		max_regions = maxi(max_regions, (world._region_nodes as Dictionary).size())
		max_decor = maxi(max_decor, (world._decor_nodes as Dictionary).size())
	print("  （走了 24 段后：区域色块窗口峰值 %d，草木瓦片窗口峰值 %d，世界子节点 %d）"
		% [max_regions, max_decor, world.get_child_count()])
	_ok(max_regions < 200, "区域色块窗口不随走远而堆积（峰值 %d）" % max_regions)
	_ok(max_decor < 80, "草木瓦片窗口不随走远而堆积（峰值 %d）" % max_decor)
	_ok(world.get_child_count() < 20000, "整张地图的节点数仍受控（%d）" % world.get_child_count())

	print("")
	if _fail == 0:
		print("== 全部通过 ==")
		quit(0)
	else:
		print("== 失败 %d 项 ==" % _fail)
		quit(1)

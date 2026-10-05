extends SceneTree
## 一次性验证工具：MC 式「走到哪生成哪」的流式预生成
## 用法：godot --headless --path . --script res://tools/stream_probe.gd
##
## 验证四件事：
##   1. 生成由「玩家位置」驱动，而不是靠 NPC 对话触发；
##   2. 新地点长在玩家身边，而不是永远围着固定的母村原点；
##   3. 提前量足够——预生成半径远大于视野，玩家走过去时内容早已就位；
##   4. 确定性——同一片地不会重复生成，同一世界的聚落骨架可复现。
##
## 纯只读：只在内存里改 WorldData，不写任何存档 / 缓存文件。

var _cul
var _wd
var _rg
var _lg
var _dec
var _fail := 0
var _created: Array = []


func _initialize() -> void:
	_run()


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("  [PASS] " + msg)
	else:
		_fail += 1
		print("  [FAIL] " + msg)


func _on_created(loc: Dictionary) -> void:
	_created.append(loc)


func _run() -> void:
	await process_frame
	_cul = root.get_node_or_null("CultureData")
	_wd = root.get_node_or_null("WorldData")
	_rg = root.get_node_or_null("RegionGenerator")
	_lg = root.get_node_or_null("LocationGenerator")
	_dec = root.get_node_or_null("SceneDecorator")
	for n in [_cul, _wd, _rg, _lg]:
		if n == null:
			push_error("[probe] 缺少 autoload 节点")
			quit(1)
			return

	# 纯离线验证：强制 mock，避免真去调大模型接口
	_lg.mode = "mock"
	if _dec != null:
		_dec.mode = "mock"
	# 固定世界种子 + 重置世界，保证结果可复现
	_rg.set_world_seed(20261004)
	_wd.set_culture(_cul.current_id)
	_lg._done_cells.clear()
	_lg._seen_loc_count = -1
	if not _lg.location_created.is_connected(_on_created):
		_lg.location_created.connect(_on_created)

	_section_params()
	_section_stream_at_origin()
	_section_follow_player()
	_section_determinism()

	print("")
	if _fail == 0:
		print("== 全部通过 ==")
		quit(0)
	else:
		print("== 失败 %d 项 ==" % _fail)
		quit(1)


# ---------------------------------------------------------------- 1. 参数 / 朝向

func _section_params() -> void:
	print("== 1. 流式参数与朝向 ==")
	_ok(float(_lg.STREAM_RADIUS) >= 3000.0, "预生成半径 %.0f（够玩家走十几秒，AI 才来得及）" % float(_lg.STREAM_RADIUS))
	_ok(float(_lg.STREAM_RADIUS) > 2000.0, "预生成半径 > 视野半径 2000")
	_ok(float(_lg.SETTLE_CHANCE) > 0.0 and float(_lg.SETTLE_CHANCE) < 1.0,
		"每格「是不是聚落」的概率在 (0,1) 之间（%.2f）" % float(_lg.SETTLE_CHANCE))

	# 聚落骨架：同一格反复问，答案必须一样（世界可复现）
	var cell := Vector2i(3, -2)
	var a: bool = _lg._cell_has_settlement(cell)
	var b: bool = _lg._cell_has_settlement(cell)
	_ok(a == b, "同一格的聚落判定可复现（结果 %s）" % str(a))

	# 朝向：玩家往右走，_player_dir 应变成 (1,0)
	_lg.report_player_position(Vector2.ZERO)
	_lg.report_player_position(Vector2(100.0, 0.0))
	var dir: Vector2 = _lg._player_dir
	_ok(dir.distance_to(Vector2(1.0, 0.0)) < 0.01, "向右走时朝向 ≈ (1,0)（实际 %s）" % str(dir))


# ---------------------------------------------------------------- 2. 站着不动也有内容

func _section_stream_at_origin() -> void:
	print("== 2. 玩家站在某处 → 周围自动生成（全程没有 NPC 对话）==")
	var before: int = _wd.LOCATIONS.size()
	_created.clear()
	var pos := Vector2(0.0, 0.0)
	_lg.report_player_position(pos - Vector2(1.0, 0.0))
	_lg.report_player_position(pos)
	# 手动多跑几轮流式扫描（等价于游戏里每 0.7s 自动扫一次）
	var ticks := 0
	while _wd.LOCATIONS.size() - before < 3 and ticks < 40:
		_lg._stream()
		ticks += 1
	var made: int = _wd.LOCATIONS.size() - before
	print("  （%d 轮扫描后新增 %d 个地点）" % [ticks, made])
	_ok(made >= 3, "走到新地方就自动生出至少 3 个新地点（实际 %d）" % made)
	_ok(_created.size() == made, "location_created 信号次数与新增数一致（%d / %d）" % [_created.size(), made])

	var near := true
	var far := 0.0
	for loc in _created:
		var lp: Vector2 = loc["pos"]
		var d: float = lp.distance_to(pos)
		far = maxf(far, d)
		if d > float(_lg.STREAM_RADIUS) + 2.0 * float(_rg.CELL):
			near = false
	_ok(near, "新地点都长在玩家附近（最远 %.0f）" % far)


# ---------------------------------------------------------------- 3. 走到哪生成哪

func _section_follow_player() -> void:
	print("== 3. 玩家走远 → 新地点跟着长到新地方（不再固定母村附近）==")
	var before: int = _wd.LOCATIONS.size()
	_created.clear()
	var far_pos := Vector2(9000.0, 6000.0)   # 离母村 10000px 以上，早就出了最初那片视野
	_lg.report_player_position(far_pos - Vector2(1.0, 0.0))
	_lg.report_player_position(far_pos)
	var ticks := 0
	while _wd.LOCATIONS.size() - before < 2 and ticks < 60:
		_lg._stream()
		ticks += 1
	var made: int = _wd.LOCATIONS.size() - before
	print("  （%d 轮扫描后新增 %d 个地点）" % [ticks, made])
	_ok(made >= 2, "玩家走到远方，那里也能生成新地点（实际 %d）" % made)

	var near_new := true
	var min_d := INF
	for loc in _created:
		var lp: Vector2 = loc["pos"]
		var d: float = lp.distance_to(far_pos)
		min_d = minf(min_d, d)
		if d > float(_lg.STREAM_RADIUS) + 2.0 * float(_rg.CELL):
			near_new = false
	_ok(near_new, "远方新地点都长在玩家新位置附近")
	_ok(min_d < float(_lg.STREAM_RADIUS), "远方新地点离玩家小于预生成半径，走过去即可见（最近 %.0f）" % min_d)


# ---------------------------------------------------------------- 4. 确定性

func _section_determinism() -> void:
	print("== 4. 确定性：同一片地不重复生成、id 唯一 ==")
	var n0: int = _wd.LOCATIONS.size()
	for i in 10:
		_lg._stream()
	var n1: int = _wd.LOCATIONS.size()
	_ok(n1 >= n0, "重复扫描地点数只增不减（%d → %d）" % [n0, n1])

	var seen := {}
	var dup := false
	for loc in _wd.LOCATIONS:
		var id := str(loc["id"])
		if seen.has(id):
			dup = true
		seen[id] = true
	_ok(not dup, "全图地点 id 唯一（共 %d 个）" % _wd.LOCATIONS.size())

	var home: Dictionary = _wd.by_id(str(_cul.HOME_ID))
	var hp: Vector2 = home.get("pos", Vector2(999, 999))
	_ok(not home.is_empty() and hp == Vector2.ZERO, "母村仍在原点，没被流式生成顶掉")
	_ok(_wd.by_id(str(_cul.HOME_ID))["name"] == _cul.village_name(), "母村名字未变：%s" % _cul.village_name())

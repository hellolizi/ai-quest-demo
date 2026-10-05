extends SceneTree
## 一次性验证工具：地形 / 海拔分层（RegionGenerator.elevation_at / terrain_at）
## 用法：godot --headless --path . --script res://tools/terrain_probe.gd
##
## 纯只读：只改内存里的世界种子，不写任何存档文件。

var _rg                       # RegionGenerator
var _fail := 0
var _lines: PackedStringArray = []

const STEP := 250.0           # 采样步长（px）
const HALF := 25000.0         # 采样范围：以原点为中心 ±HALF


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


func _run() -> void:
	await process_frame
	_rg = root.get_node_or_null("RegionGenerator")
	if _rg == null:
		_log("[probe] 缺少 RegionGenerator autoload")
		quit(1)
		return
	_rg.set_world_seed(20261004)

	_section_spawn()
	_section_sample()
	_section_deterministic()
	_section_continuity()

	if _fail == 0:
		_log("== 全部通过 ==")
		quit(0)
	else:
		_log("== 失败 %d 项 ==" % _fail)
		quit(1)


# ---------------------------------------------------------------- 1. 出生地压平

func _section_spawn() -> void:
	_log("== 1. 出生地压平为平原 ==")
	var e0: float = _rg.elevation_at(Vector2.ZERO)
	_ok(is_equal_approx(e0, float(_rg.SPAWN_FLAT_LEVEL)),
		"原点海拔 = SPAWN_FLAT_LEVEL（实际 %.3f）" % e0)
	_ok(_rg.terrain_at(Vector2.ZERO) == "plain", "原点地形是 plain")
	# 母村与几个基础地点都在压平半径内，必须好走
	var sites := [
		Vector2.ZERO,
		Vector2(-200.0, -1000.0),
		Vector2(900.0, -850.0),
		Vector2(1200.0, -150.0),
		Vector2(-1100.0, 100.0),
		Vector2(150.0, 1000.0),
	]
	var all_plain := true
	for s in sites:
		if _rg.terrain_at(s) != "plain":
			all_plain = false
	_ok(all_plain, "所有基础地点都落在平原上（不会被山压住）")


# ---------------------------------------------------------------- 2. 地形占比

func _section_sample() -> void:
	_log("== 2. 采样地形分布（步长 %.0f，范围 ±%.0f）==" % [STEP, HALF])
	var counts := {"plain": 0, "hill": 0, "mountain": 0, "peak": 0}
	var total := 0
	var max_e := 0.0
	var min_e := 1.0
	var span := int((HALF * 2.0) / STEP)
	for ix in range(span + 1):
		var x := -HALF + float(ix) * STEP
		for iy in range(span + 1):
			var y := -HALF + float(iy) * STEP
			var pos := Vector2(x, y)
			var e: float = _rg.elevation_at(pos)
			max_e = maxf(max_e, e)
			min_e = minf(min_e, e)
			counts[_rg.terrain_at(pos)] += 1
			total += 1
	var plain_pct := 100.0 * float(counts["plain"]) / float(total)
	var hill_pct := 100.0 * float(counts["hill"]) / float(total)
	var mtn_pct := 100.0 * float(counts["mountain"]) / float(total)
	var peak_pct := 100.0 * float(counts["peak"]) / float(total)
	_log("  样本 %d：平原 %.1f%% / 丘陵 %.1f%% / 山 %.1f%% / 峰 %.1f%%（海拔 %.3f~%.3f）" % [
		total, plain_pct, hill_pct, mtn_pct, peak_pct, min_e, max_e])
	_ok(plain_pct >= 35.0, "平原是主体（≥35%%，实际 %.1f%%）" % plain_pct)
	_ok(hill_pct > 0.0, "有丘陵（%.1f%%）" % hill_pct)
	_ok(mtn_pct + peak_pct > 0.0, "有高山（山+峰 %.1f%%）" % (mtn_pct + peak_pct))
	_ok(mtn_pct + peak_pct < 45.0, "高山不是多数（<45%%，实际 %.1f%%）" % (mtn_pct + peak_pct))
	_ok(max_e > float(_rg.LEVEL_PEAK), "采样里出现了峰级海拔（最高 %.3f）" % max_e)


# ---------------------------------------------------------------- 3. 确定性

func _section_deterministic() -> void:
	_log("== 3. 同一位置永远算出同一高度 ==")
	var probes := [Vector2(3333.0, -1234.0), Vector2(-5000.0, 8000.0), Vector2(20000.0, 20000.0)]
	var same := true
	for p in probes:
		for _i in 3:
			var a: float = _rg.elevation_at(p)
			var b: float = _rg.elevation_at(p)
			if not is_equal_approx(a, b):
				same = false
	_ok(same, "重复采样同一坐标，海拔完全一致")
	# 换种子应当改变地形（除非恰好撞上，概率极低）。
	# 取点必须在陆地上：海岸线以南（海里）海拔被强行压到 SEA_LEVEL，换种子也不变。
	var before: float = _rg.elevation_at(Vector2(9000.0, -9000.0))
	_rg.set_world_seed(777)
	var after: float = _rg.elevation_at(Vector2(9000.0, -9000.0))
	_rg.set_world_seed(20261004)
	_ok(not is_equal_approx(before, after), "换世界种子后地形改变（%.3f → %.3f）" % [before, after])


# ---------------------------------------------------------------- 4. 连续性

func _section_continuity() -> void:
	_log("== 4. 海拔连续（没有断崖式跳变）==")
	var max_delta := 0.0
	var nx := int(12000.0 / 100.0)
	var ny := int(12000.0 / 300.0)
	for ix in range(nx + 1):
		var x := -6000.0 + float(ix) * 100.0
		for iy in range(ny + 1):
			var y := -6000.0 + float(iy) * 300.0
			var a: float = _rg.elevation_at(Vector2(x, y))
			var b: float = _rg.elevation_at(Vector2(x + 100.0, y))
			max_delta = maxf(max_delta, absf(a - b))
	_ok(max_delta < 0.2, "相邻 100px 的海拔差 < 0.2（最大 %.3f）" % max_delta)

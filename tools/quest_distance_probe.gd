extends SceneTree
## 一次性验证工具：任务目标必须落在玩家附近（MAX_TARGET_DISTANCE = 500 米 = 10000px）
## 用法：godot --headless --path . --script res://tools/quest_distance_probe.gd
##
## 纯只读：只在内存里改 WorldData / QuestManager，不写任何存档 / 缓存文件。

var _wd                       # WorldData
var _qm                       # QuestManager
var _fail := 0
var _lines: PackedStringArray = []

const SAMPLES := 30
const REPORT_PATH := "res://tools/_quest_probe_report.txt"


func _initialize() -> void:
	_run()


func _log(s: String) -> void:
	print(s)
	_lines.append(s)


func _write_report() -> void:
	var f := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines))
		f.close()


func _ok(cond: bool, msg: String) -> void:
	if cond:
		_log("  [PASS] " + msg)
	else:
		_fail += 1
		_log("  [FAIL] " + msg)


func _run() -> void:
	await process_frame
	_wd = root.get_node_or_null("WorldData")
	_qm = root.get_node_or_null("QuestManager")
	for n in [_wd, _qm]:
		if n == null:
			_log("[probe] 缺少 autoload 节点")
			_write_report()
			quit(1)
			return

	# 纯离线验证：强制 mock，避免真去调大模型接口
	_qm.mode = "mock"

	_section_const()
	_section_position()
	_section_near_spawn()
	_section_moved_player()
	_section_validation()
	_section_fallback()

	if _fail == 0:
		_log("== 全部通过 ==")
		_write_report()
		quit(0)
	else:
		_log("== 失败 %d 项 ==" % _fail)
		_write_report()
		quit(1)


# ---------------------------------------------------------------- 1. 常量

func _section_const() -> void:
	_log("== 1. 距离常量：500 米 = 10000px ==")
	_ok(is_equal_approx(float(_qm.MAX_TARGET_DISTANCE), 10000.0),
		"MAX_TARGET_DISTANCE = 10000px（实际 %s）" % str(_qm.MAX_TARGET_DISTANCE))
	_ok(is_equal_approx(float(_qm.MAX_TARGET_DISTANCE) / float(_qm.PX_PER_METER), 500.0),
		"换算成米 = 500 米")


# ---------------------------------------------------------------- 2. 位置上报

func _section_position() -> void:
	_log("== 2. try_complete_at 会记录玩家位置 ==")
	_qm.try_complete_at(Vector2(1234.0, -567.0))
	var p: Vector2 = _qm.player_position
	_ok(p == Vector2(1234.0, -567.0), "player_position 已更新为 (1234,-567)（实际 %s）" % str(p))


# ---------------------------------------------------------------- 3. 出生点附近生成

func _section_near_spawn() -> void:
	_log("== 3. 玩家在母村附近，生成 %d 个任务：目标全部 ≤ 500 米且非母村 ==" % SAMPLES)
	_qm.try_complete_at(Vector2.ZERO)
	var origin := Vector2.ZERO
	var worst := 0.0
	var all_inside := true
	var all_non_village := true
	var created := 0
	for i in SAMPLES:
		var before: int = int(_qm.quests.size())
		_qm.request_quest("测试村民%d" % i, "村民")
		if _qm.quests.size() <= before:
			continue
		created += 1
		var q: Dictionary = _qm.quests[_qm.quests.size() - 1]
		var tid := str(q.get("target_location", ""))
		if tid == "village":
			all_non_village = false
		if not _wd.has_id(tid):
			all_inside = false
			continue
		var pos: Vector2 = _wd.by_id(tid)["pos"]
		var d := origin.distance_to(pos)
		worst = maxf(worst, d)
		if d > float(_qm.MAX_TARGET_DISTANCE):
			all_inside = false
	_log("  （实际生成 %d / %d，最远 %.0fpx）" % [created, SAMPLES, worst])
	_ok(created == SAMPLES, "每个请求都生成了任务")
	_ok(all_inside, "所有任务目标都在玩家 10000px 内")
	_ok(all_non_village, "没有任务把母村当成目标")


# ---------------------------------------------------------------- 4. 玩家移动后

func _section_moved_player() -> void:
	_log("== 4. 玩家换到别处，候选地点随位置收缩 ==")
	var spots: Array[Vector2] = [
		Vector2(9000.0, 0.0),
		Vector2(0.0, 9000.0),
		Vector2(40000.0, -40000.0),
	]
	for spot in spots:
		_qm.try_complete_at(spot)
		var cands: Array = _qm._target_candidates()
		# 这个位置本身有没有 500 米内的非村地点
		var any_within := false
		for loc in _wd.LOCATIONS:
			if str(loc.get("id", "")) == "village":
				continue
			if spot.distance_to(loc["pos"] as Vector2) <= float(_qm.MAX_TARGET_DISTANCE):
				any_within = true
				break
		if any_within:
			var all_inside := cands.size() > 0
			for c in cands:
				var pos: Vector2 = (c as Dictionary)["pos"]
				if spot.distance_to(pos) > float(_qm.MAX_TARGET_DISTANCE):
					all_inside = false
			_ok(all_inside,
				"玩家 %s：候选 %d 个，全部在 10000px 内" % [str(spot), cands.size()])
		else:
			# 附近一个地点都没有时，允许缩成「最近的那一个」兜底
			_ok(cands.size() == 1,
				"玩家 %s：附近无地点，缩成 1 个兜底候选（实际 %d）" % [str(spot), cands.size()])

	# 玩家在 (9000,0) 时，mill 在 (-1100,100) 距离约 10158px，应被排除
	_qm.try_complete_at(Vector2(9000.0, 0.0))
	var has_mill := false
	for c in _qm._target_candidates():
		if str((c as Dictionary).get("id", "")) == "mill":
			has_mill = true
	_ok(not has_mill, "玩家在 (9000,0) 时，超过 500 米的 mill 被排除")


# ---------------------------------------------------------------- 5. 校验

func _section_validation() -> void:
	_log("== 5. _validation_error 距离校验 ==")
	_qm.try_complete_at(Vector2.ZERO)
	# 造一个离出生点 50000px 的临时地点（只在内存里，进程结束即消失）
	var far_id := "bridge_9_9_99"
	var added: bool = bool(_wd.add_location({
		"id": far_id, "name": "探针远方桥", "kind": "bridge",
		"pos": Vector2(50000.0, 0.0), "desc": "探针临时地点",
	}))
	_ok(added, "成功加入一个 50000px 外的临时地点用于校验")

	var far_quest := {
		"title": "远方", "description": "测试", "stages": [{"goal": "去"}],
		"target_location": far_id,
	}
	_ok(str(_qm._validation_error(far_quest)) != "", "远于 500 米的目标被校验拒绝")

	var near_quest := {
		"title": "近处", "description": "测试", "stages": [{"goal": "去"}],
		"target_location": "mine",
	}
	_ok(str(_qm._validation_error(near_quest)) == "", "500 米内的目标通过校验")

	var bad_quest := {
		"title": "不存在", "description": "测试", "stages": [{"goal": "去"}],
		"target_location": "no_such_place",
	}
	_ok(str(_qm._validation_error(bad_quest)) != "", "不存在的地点仍被拒绝")


# ---------------------------------------------------------------- 6. 附近无候选时兜底

func _section_fallback() -> void:
	_log("== 6. 玩家远离所有地点时，退回最近的地点 ==")
	var far := Vector2(1000000.0, 1000000.0)
	_qm.try_complete_at(far)
	var cands: Array = _qm._target_candidates()
	_ok(cands.size() == 1, "附近一个都没有时，候选缩成最近的那一个（实际 %d）" % cands.size())
	if cands.size() == 1:
		var nearest_id := str((cands[0] as Dictionary).get("id", ""))
		var best_id := ""
		var best_d := INF
		for loc in _wd.LOCATIONS:
			if str(loc.get("id", "")) == "village":
				continue
			var pos: Vector2 = loc["pos"]
			var d := far.distance_to(pos)
			if d < best_d:
				best_d = d
				best_id = str(loc["id"])
		_ok(nearest_id == best_id, "兜底候选确实是离玩家最近的地点（%s）" % nearest_id)

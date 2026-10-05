extends SceneTree
## 离线完整通关探针：全程 mode = "mock"，不连任何 API、不写存档，
## 把 4 条预设主线（warden 守望乡里 / wanderer 走向远方 / bridge 架起桥梁 / hermit 独自远游）
## 从「发任务即承诺」一路推到结局，并逐项断言：
##   1. 开局就把终局三站的真实地点 + 要见的人落实到世界上；
##   2. 逐章靠真实动作（接任务 → 走到 → 复命 → 涨好感 → 添新地点）达标推进；
##   3. 终局章真的去见了那一站的人；
##   4. 结局类型 == 预设、走满 8 章、对应传说武器到手并装备。
##
## 用法：godot --headless --path . --script res://tools/playthrough_probe.gd

var _sd                       # StoryDirector
var _qm                       # QuestManager
var _lg                       # LocationGenerator
var _ng                       # NpcGenerator
var _nm                       # NpcMemory
var _wd                       # WorldData
var _pp                       # PlayerProfile
var _wdta                     # WeaponData
var _cd                       # CultureData
var _rg                       # RegionGenerator
var _dec                      # SceneDecorator

var _fail := 0
var _quest_seq := 0

const PRESETS := ["warden", "wanderer", "bridge", "hermit"]


func _initialize() -> void:
	_run()


func _log(s: String) -> void:
	print(s)


func _ok(cond: bool, msg: String) -> void:
	if cond:
		_log("  [PASS] " + msg)
	else:
		_fail += 1
		_log("  [FAIL] " + msg)


func _grab(n: String):
	var node = root.get_node_or_null(n)
	if node == null:
		_log("[probe] 缺少 autoload：" + n)
	return node


func _run() -> void:
	await process_frame
	_sd = _grab("StoryDirector")
	_qm = _grab("QuestManager")
	_lg = _grab("LocationGenerator")
	_ng = _grab("NpcGenerator")
	_nm = _grab("NpcMemory")
	_wd = _grab("WorldData")
	_pp = _grab("PlayerProfile")
	_wdta = _grab("WeaponData")
	_cd = _grab("CultureData")
	_rg = _grab("RegionGenerator")
	_dec = _grab("SceneDecorator")
	if _sd == null or _qm == null or _lg == null or _ng == null or _nm == null \
			or _wd == null or _pp == null or _wdta == null or _cd == null or _rg == null \
			or _dec == null:
		quit(1)
		return

	# 纯离线：所有生成器都退回本地模板，绝不发起网络请求
	_sd.mode = "mock"
	_qm.mode = "mock"
	_lg.mode = "mock"
	_ng.mode = "mock"
	_nm.mode = "mock"
	_dec.mode = "mock"

	_log("== 离线完整通关探针（全程 mode=mock，不联网）==")
	_log("文化圈 = %s   世界种子 = %d" % [_cd.current_id, int(_rg.world_seed)])

	for preset in PRESETS:
		await _play_preset(preset)

	_log("")
	if _fail == 0:
		_log("== 4 条预设主线全部完整通关 ==")
		quit(0)
	else:
		_log("== 失败 %d 项 ==" % _fail)
		quit(1)


# ---------------------------------------------------------------- 单条主线

func _play_preset(preset: String) -> void:
	_log("")
	_log("──────────────── 主线 %s（%s）────────────────" % [preset, _sd.preset_name(preset)])
	_reset_all()
	_quest_seq = 0

	_ok(_sd.set_goal_preset(preset), "玩家选定预设结局「%s」" % _sd.preset_name(preset))
	# boot() → lock_arc() → _try_start_ultimate_goal()：发任务即承诺
	_sd.boot()

	# 等异步链把三站真实地点 + 人落实出来（_on_commit_npc 走 call_deferred，需要几帧）
	var wait := 0
	while wait < 90:
		wait += 1
		await process_frame
		if _sd.has_ultimate_goal() and _sd.chapter > 0:
			break

	_ok(_sd.has_ultimate_goal(), "开局即落实终极目标（ultimate_goal 非空）")
	var steps: Array = _sd.ultimate_steps()
	_ok(steps.size() == 3, "终极目标恰有 3 站（实为 %d）" % steps.size())
	if steps.size() != 3:
		return

	# 三站必须都是「真实存在的地方 + 真实存在的人」
	var grounded := true
	for i in range(steps.size()):
		var st: Dictionary = steps[i]
		var lid := str(st.get("location_id", ""))
		var place := str(st.get("location_name", ""))
		var who := str(st.get("npc_name", ""))
		var here: bool = lid != "" and bool(_wd.has_id(lid))
		var known: bool = who != "" and bool(_ng.is_name_used(who))
		grounded = grounded and here and known
		_log("        第 %d 站：往%s走约 %d 米 → %s（id=%s，已在世界：%s），去见 %s（已在世界：%s）" % [
			i + 1, str(st.get("direction", "")), int(st.get("distance_m", 0)),
			place, lid, here, who, known,
		])
	_ok(grounded, "三站地点与人开局就已真实存在（不是走到那里才现生成）")

	# 逐章推进
	var guard := 0
	var last_ch := -1
	var stall := 0
	while not _sd.finished and guard < 80:
		guard += 1
		if _sd.chapter <= 0:
			await process_frame
			continue
		if _sd.chapter == last_ch:
			stall += 1
		else:
			stall = 0
			last_ch = _sd.chapter
		if stall > 6:
			_ok(false, "主线卡在第 %d 章推进不动" % _sd.chapter)
			break
		await _satisfy_chapter(_sd.chapter)

	await process_frame
	await process_frame

	# 结局断言
	var pid := str(_wdta.preset_id_for_ending(preset))
	_ok(_sd.finished, "主线推到结局（finished=true）")
	_ok(str(_sd.ending.get("type", "")) == preset,
		"结局类型 == %s（实为 %s）" % [preset, str(_sd.ending.get("type", ""))])
	_ok(_sd.chapter_log.size() >= _sd.MAX_CHAPTERS,
		"走满 %d 章（chapter_log 记录 %d 章）" % [_sd.MAX_CHAPTERS, _sd.chapter_log.size()])
	_ok(pid != "" and _pp.has_weapon(pid), "结局武器已到手：%s" % pid)
	_ok(_pp.equipped_weapon == pid, "结局武器已装备：%s" % _pp.equipped_weapon)
	_log("        结局：%s（%s）｜武器：%s" % [
		str(_sd.ending.get("title", "")), str(_sd.ending.get("type_name", "")), pid,
	])


# ---------------------------------------------------------------- 逐章驱动

## 把第 ch 章的要求一条条做满，触发主线推进
func _satisfy_chapter(ch: int) -> void:
	_ensure_locations(ch)
	_ensure_final_talk(ch)
	var guard := 0
	while not _sd.finished and _sd.chapter == ch and guard < 200:
		guard += 1
		if _requirements_met(ch):
			break
		_complete_one_quest()
		await process_frame
		_ensure_locations(ch)
		_ensure_final_talk(ch)
	# 给 call_deferred 排队的 _check_progress 一点时间推进章节
	for _i in range(4):
		await process_frame


func _requirements_met(ch: int) -> bool:
	var req: Dictionary = _sd._requirement_for(ch)
	if _pp.quests_completed < int(req["quests_completed"]):
		return false
	if _nm.affinity_total() < int(req["affinity_total"]):
		return false
	if _wd.runtime_count() < int(req["new_locations"]):
		return false
	if _sd.milestones.size() < int(req["milestones"]):
		return false
	return true


## 补足「走出来的新地方」：请游方的人打听新地点（mock 下当场落地）
func _ensure_locations(ch: int) -> void:
	var req: Dictionary = _sd._requirement_for(ch)
	var need := int(req["new_locations"])
	var guard := 0
	while _wd.runtime_count() < need and guard < 60:
		guard += 1
		var before: int = _wd.LOCATIONS.size()
		_lg.request_location("探针游方")
		if _wd.LOCATIONS.size() == before:
			break


## 终局章：真的去「见」这一站要见的人（搭一次话）
func _ensure_final_talk(ch: int) -> void:
	var fi: int = _sd._final_step_index(ch)
	if fi < 0:
		return
	var steps: Array = _sd.ultimate_steps()
	if fi >= steps.size():
		return
	var st: Dictionary = steps[fi]
	var who := str(st.get("npc_name", ""))
	if who == "" or bool(st.get("done", false)):
		return
	_pp.record_talk(who)
	_sd.note_talk(who)


## 完整走一遍一件支线：接任务 → 走到目标 → 清怪（若需）→ 回去复命。
## 每次用一个全新的委托人名，保证每件任务都算一条新里程碑。
func _complete_one_quest() -> void:
	_quest_seq += 1
	var who := "探针脚夫%d" % _quest_seq
	_qm.request_quest(who, "村民", "话不多")
	if _qm.quests.is_empty():
		return
	var q: Dictionary = _qm.quests.back()
	var loc: Dictionary = _wd.by_id(str(q.get("target_location", "")))
	if loc.is_empty():
		return
	_qm.accept_quest(q)
	var pos: Vector2 = loc.get("pos", Vector2.ZERO)
	_qm.player_position = pos
	var need := int(q.get("combat", 0))
	for _i in range(need):
		_qm.notify_enemy_defeated(pos)
	_qm.try_complete_at(pos)
	_qm.report_quest(q, "村民", "话不多")


# ---------------------------------------------------------------- 复位

## 把整个世界 + 全部生成器状态复位到「全新开局」，好让 4 条主线互不干扰
func _reset_all() -> void:
	# —— 剧情导演
	_sd.mode = "mock"
	_sd.clear_goal()
	_sd.ultimate_goal = {}
	_sd._commit = {}
	_sd.chapter = 0
	_sd.chapter_data = {}
	_sd.chapter_log.clear()
	_sd.milestones.clear()
	_sd.ending = {}
	_sd.endings_seen.clear()
	_sd.finished = false
	_sd.cycle = 1
	_sd.goal_step = 0
	_sd.goal_kind = ""
	_sd.goal_preset = ""
	_sd.goal_custom = ""
	_sd.arc_key = ""
	_sd.custom_arc = []
	_sd.custom_arc_title = ""
	_sd._busy = false
	_sd._checking = false
	_sd._ctx = {}
	_sd._prepare = {}
	# —— 玩家画像
	_pp.distance_traveled = 0.0
	_pp.talks.clear()
	_pp.total_talks = 0
	_pp.quests_accepted = 0
	_pp.quests_completed = 0
	_pp.gold = 0
	_pp.recent_events.clear()
	_pp.new_game()
	# —— NPC 记忆
	_nm.mode = "mock"
	_nm._states.clear()
	_nm._positions.clear()
	_nm._queue.clear()
	_nm._current = {}
	_nm._busy = false
	_nm._pumping = false
	# —— NPC 生成器
	_ng.mode = "mock"
	_ng.dynamic_npcs.clear()
	_ng._known_names.clear()
	_ng._known_roles.clear()
	_ng._queue.clear()
	_ng._busy = false
	_ng._pending_ctx = {}
	# —— 任务管理
	_qm.mode = "mock"
	_qm.quests.clear()
	_qm.tracked_quest = {}
	_qm._queue.clear()
	_qm._current = {}
	_qm._busy = false
	_qm._pumping = false
	_qm.player_position = Vector2.ZERO
	# —— 地点生成器（先把队列与占坑清干净）
	_lg.mode = "mock"
	_lg._queue.clear()
	_lg._busy = false
	_lg._pending_ctx = {}
	_lg._done_cells.clear()
	_lg._seen_loc_count = -1
	# —— 场景布置器（也要纯离线：只铺本地模板，绝不发网络请求）
	_dec.mode = "mock"
	_dec._decorated.clear()
	_dec._placed.clear()
	_dec._placements_by_loc.clear()
	_dec._pending_ctx = {}
	_dec._pending_loc = {}
	# —— 世界：重建基础地点，再把基础地点的格子补记进占坑表
	_wd.set_culture(_cd.current_id)
	_lg._sync_done_cells()

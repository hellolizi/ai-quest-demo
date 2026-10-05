extends SceneTree
## 一次性验证工具：主线「目标结局」系统（StoryDirector 的预设 / 自定义结局）
## 用法：godot --headless --path . --script res://tools/story_goal_probe.gd
##
## 纯离线：强制 mode = "mock"，不联网、不写任何存档文件（只用 to_save/from_save 在内存里往返）。

var _sd                        # StoryDirector
var _fail := 0


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


func _run() -> void:
	await process_frame
	_sd = root.get_node_or_null("StoryDirector")
	if _sd == null:
		_log("[probe] 缺少 StoryDirector autoload")
		quit(1)
		return
	# 纯离线，避免真去调大模型接口
	_sd.mode = "mock"

	_section_default()
	_section_preset()
	_section_bad_input()
	_section_custom()
	_section_mock_ending()
	_section_finalize()
	_section_save_roundtrip()
	_section_sanitize()
	_section_clear()
	_section_goal_theme()
	_section_quest_goal()
	_section_dialogue_goal_rule()
	_section_arc_shape()
	_section_lock_arc()
	_section_beat_alignment()
	_section_milestones()
	_section_log_and_recap()
	await _section_ultimate_commit()
	_section_ultimate_progress()
	_section_ultimate_save()
	_section_ultimate_guards()
	await _section_custom_prepare()
	_section_arc_sanitize()
	await _section_llm_smoke()

	_sd.clear_goal()
	if _fail == 0:
		_log("== 全部通过 ==")
		quit(0)
	else:
		_log("== 失败 %d 项 ==" % _fail)
		quit(1)


# ---------------------------------------------------------------- 1. 默认无目标
func _section_default() -> void:
	_log("[1] 默认无目标")
	_sd.clear_goal()
	_ok(not _sd.has_goal(), "has_goal() 为 false")
	_ok(_sd.goal_summary() == "", "goal_summary() 为空")
	_ok(_sd.goal_block() == "", "goal_block() 为空")
	# 没设定时，结局类型交回代码按行为数据判定
	_ok(_sd._ending_type_for_player() == _sd._pick_ending_type(), "_ending_type_for_player() 回退到数据判定")


# ---------------------------------------------------------------- 2. 预设目标
func _section_preset() -> void:
	_log("[2] 预设目标")
	_ok(_sd.set_goal_preset("warden"), "set_goal_preset(\"warden\") 成功")
	_ok(_sd.has_goal(), "has_goal() 为 true")
	_ok(_sd.goal_kind == "preset", "goal_kind 为 preset")
	_ok(_sd.goal_summary() == "守望乡里", "goal_summary() 为「守望乡里」")
	_ok(_sd._ending_type_for_player() == "warden", "_ending_type_for_player() 为 warden")
	var blk: String = _sd.goal_block()
	_ok(blk.find("守望乡里") != -1, "goal_block() 提到「守望乡里」")
	_ok(blk.find("留下") != -1, "goal_block() 带上预设的描述")
	# 每个预设都能选
	for g in _sd.PRESET_GOALS:
		var id := str(g.get("id", ""))
		_ok(_sd.set_goal_preset(id), "预设 %s 可选" % id)
		_ok(_sd._ending_type_for_player() == id, "预设 %s 决定结局类型" % id)


# ---------------------------------------------------------------- 3. 非法输入
func _section_bad_input() -> void:
	_log("[3] 非法输入被拒")
	var before: String = _sd.goal_summary()
	_ok(not _sd.set_goal_preset("bogus"), "不存在的预设 id 被拒")
	_ok(not _sd.set_goal_preset("custom"), "custom 不是预设（应被拒）")
	_ok(_sd.goal_summary() == before, "被拒后状态不变")
	_ok(not _sd.set_goal_custom("   "), "空白自定义结局被拒")


# ---------------------------------------------------------------- 4. 自定义结局
func _section_custom() -> void:
	_log("[4] 自定义结局")
	_ok(_sd.set_goal_custom("  我想带着全村人搬到海边住。  "), "set_goal_custom() 成功")
	_ok(_sd.goal_kind == "custom", "goal_kind 为 custom")
	_ok(_sd.goal_preset == "", "设自定义后预设被清空")
	_ok(_sd.has_goal(), "has_goal() 为 true")
	_ok(_sd.goal_summary() == "我想带着全村人搬到海边住。", "goal_summary() 去掉了首尾空格")
	_ok(_sd._ending_type_for_player() == "custom", "_ending_type_for_player() 为 custom")
	_ok(_sd.goal_block().find("我想带着全村人搬到海边住。") != -1, "goal_block() 带上玩家原话")


# ---------------------------------------------------------------- 5. 离线兜底结局
func _section_mock_ending() -> void:
	_log("[5] 离线兜底结局")
	_sd.set_goal_custom("我想带着全村人搬到海边住。")
	var ce: Dictionary = _sd._mock_ending()
	_ok(str(ce.get("title", "")) == "如愿", "自定义结局标题为「如愿」")
	_ok(str(ce.get("text", "")).find("我想带着全村人搬到海边住。") != -1, "自定义结局正文用玩家原话")
	_ok(str(ce.get("epilogue", "")) != "", "自定义结局有收尾语")

	_sd.set_goal_preset("wanderer")
	var pe: Dictionary = _sd._mock_ending()
	_ok(str(pe.get("title", "")) == "远行的人", "预设结局用对应模板（wanderer → 远行的人）")


# ---------------------------------------------------------------- 6. 接入最终结局
func _section_finalize() -> void:
	_log("[6] 结局类型接入 _finalize_ending")
	_sd.set_goal_custom("我想带着全村人搬到海边住。")
	_sd._finalize_ending({"title": "归海", "text": "正文", "epilogue": "尾声"})
	_ok(str(_sd.ending.get("type", "")) == "custom", "结局 type 为 custom")
	_ok(str(_sd.ending.get("type_name", "")) == "心愿", "结局 type_name 为「心愿」")
	_ok(str(_sd.ending.get("title", "")) == "归海", "结局标题取自生成内容")
	_sd.finished = false
	_sd.ending = {}


# ---------------------------------------------------------------- 7. 存档往返
func _section_save_roundtrip() -> void:
	_log("[7] 存档往返")
	_sd.set_goal_custom("我要一个人走到路的尽头。")
	var data: Dictionary = _sd.to_save()
	_ok(data.has("goal_kind") and data.has("goal_preset") and data.has("goal_custom"), "to_save() 带上 goal 三个字段")

	# 打乱内存状态，再读回来
	_sd.clear_goal()
	_ok(not _sd.has_goal(), "清空后 has_goal() 为 false")
	_sd.from_save(data)
	_ok(_sd.goal_kind == "custom", "读档后 goal_kind 恢复")
	_ok(_sd.goal_summary() == "我要一个人走到路的尽头。", "读档后自定义结局恢复")
	_ok(_sd._ending_type_for_player() == "custom", "读档后结局类型仍为 custom")

	# 预设往返
	_sd.set_goal_preset("bridge")
	var data2: Dictionary = _sd.to_save()
	_sd.clear_goal()
	_sd.from_save(data2)
	_ok(_sd.goal_kind == "preset" and _sd.goal_preset == "bridge", "预设结局限定往返一致")
	_ok(_sd.goal_summary() == "架起桥梁", "预设结局名恢复")


# ---------------------------------------------------------------- 8. 坏数据收敛
func _section_sanitize() -> void:
	_log("[8] 坏数据收敛")
	_sd.from_save({"goal_kind": "preset", "goal_preset": "bogus"})
	_ok(not _sd.has_goal(), "非法预设 id 被收敛为未设定")
	_ok(_sd.goal_preset == "", "非法预设 id 被清空")

	_sd.from_save({"goal_kind": "custom", "goal_custom": "   "})
	_ok(not _sd.has_goal(), "空白自定义结局被收敛为未设定")

	_sd.from_save({"goal_kind": "whatever", "goal_preset": "warden", "goal_custom": "x"})
	_ok(not _sd.has_goal(), "未知 goal_kind 被收敛为未设定")
	_ok(_sd.goal_preset == "" and _sd.goal_custom == "", "未知 goal_kind 下残留字段被清空")

	_sd.from_save({})
	_ok(not _sd.has_goal(), "老存档（无 goal 字段）当作未设定")


# ---------------------------------------------------------------- 9. 清空后回退
func _section_clear() -> void:
	_log("[9] clear_goal() 后回退数据判定")
	_sd.set_goal_preset("hermit")
	_ok(_sd.has_goal(), "设定后 has_goal() 为 true")
	_sd.clear_goal()
	_ok(not _sd.has_goal(), "清空后 has_goal() 为 false")
	_ok(_sd.goal_summary() == "", "清空后 goal_summary() 为空")
	_ok(_sd._ending_type_for_player() == _sd._pick_ending_type(), "清空后结局类型回退到数据判定")


# ---------------------------------------------------------------- 10. goal_theme（供支线/台词用）
func _section_goal_theme() -> void:
	_log("[10] goal_theme() 供支线/台词复用")
	_sd.clear_goal()
	_ok(_sd.goal_theme() == "", "未设定时 goal_theme() 为空串")

	_sd.set_goal_custom("  我想带着全村人搬到海边住。  ")
	_ok(_sd.goal_theme() == "我想带着全村人搬到海边住。", "自定义时返回玩家原话（去空格）")

	_sd.set_goal_preset("wanderer")
	var t: String = _sd.goal_theme()
	_ok(t.find("走向远方") != -1, "预设时带上结局名")
	_ok(t.find("不停下脚步") != -1, "预设时带上结局描述")
	# 支线用的措辞不该出现「每一章」这种主线口吻
	_ok(t.find("每一章") == -1, "支线用的 goal_theme() 不含主线口吻")


# ---------------------------------------------------------------- 11. 离线支线带结局
func _section_quest_goal() -> void:
	_log("[11] 离线支线任务朝结局铺垫")
	var qm = root.get_node_or_null("QuestManager")
	if qm == null:
		_ok(false, "缺少 QuestManager autoload")
		return
	var theme := "我想带着全村人搬到海边住。"
	_sd.set_goal_custom(theme)

	# 离线模板是从理由池里随机抽的，多抽几次，至少要出现一次带结局的那条
	var ctx := {"npc_name": "阿岩", "npc_role": "村民", "npc_personality": "热心", "profile": {}}
	var hit := false
	for i in range(60):
		var q: Dictionary = qm._mock_quest(ctx)
		if str(q.get("description", "")).find(theme) != -1:
			hit = true
			break
	_ok(hit, "设了结局后，离线支线里出现了朝结局铺垫的起因")

	# 没设结局时，池子里不该再冒出这条
	_sd.clear_goal()
	var leaked := false
	for i in range(60):
		var q2: Dictionary = qm._mock_quest(ctx)
		if str(q2.get("description", "")).find(theme) != -1:
			leaked = true
			break
	_ok(not leaked, "没设结局时不会出现结局专属起因")


# ---------------------------------------------------------------- 12. 台词系统提示带结局规则
func _section_dialogue_goal_rule() -> void:
	_log("[12] 台词系统提示包含「别喊出结局」规则")
	var dg = root.get_node_or_null("DialogueGenerator")
	if dg == null:
		_ok(false, "缺少 DialogueGenerator autoload")
		return
	var sp: String = dg._system_prompt()
	_ok(sp.find("结局") != -1, "系统提示里提到了结局")
	_ok(sp.find("不要直接喊出结局") != -1, "系统提示要求不要直接喊出结局")
	_ok(sp.find("主线") != -1, "系统提示要求别把它当主线说")


# ---------------------------------------------------------------- 13. 主线弧完整性
func _section_arc_shape() -> void:
	_log("[13] 四条预设主线弧 + 通用弧的完整度")
	var table: Dictionary = _sd.STORY_ARCS
	var acts_ok := ["起", "承", "转", "合"]
	for g in _sd.PRESET_GOALS:
		var id := str(g.get("id", ""))
		_ok(table.has(id), "预设 %s 有对应主线弧" % id)
		if not table.has(id):
			continue
		var arc: Dictionary = table[id]
		var acts: Array = arc.get("acts", [])
		_ok(str(arc.get("title", "")) != "", "预设 %s 的弧有名字" % id)
		_ok(acts.size() == _sd.MAX_CHAPTERS, "预设 %s 的弧正好 %d 幕" % [id, _sd.MAX_CHAPTERS])
		var fields_ok := true
		var acts_covered := {}
		for a in acts:
			for f in ["act", "name", "intro", "goal", "beat"]:
				if typeof(a) != TYPE_DICTIONARY or str((a as Dictionary).get(f, "")).strip_edges() == "":
					fields_ok = false
			if typeof(a) == TYPE_DICTIONARY:
				acts_covered[str((a as Dictionary).get("act", ""))] = true
		_ok(fields_ok, "预设 %s 每一幕五个字段都齐" % id)
		# 起承转合都要出现
		var all_acts := true
		for k in acts_ok:
			if not acts_covered.has(k):
				all_acts = false
		_ok(all_acts, "预设 %s 的弧覆盖起承转合" % id)
	# 通用弧同样要有 8 幕、字段齐全
	_ok(_sd.GENERIC_ARC.size() == _sd.MAX_CHAPTERS, "通用弧正好 %d 幕" % _sd.MAX_CHAPTERS)
	var gen_ok := true
	for a in _sd.GENERIC_ARC:
		for f in ["act", "name", "intro", "goal", "beat"]:
			if str((a as Dictionary).get(f, "")).strip_edges() == "":
				gen_ok = false
	_ok(gen_ok, "通用弧每一幕五个字段都齐")


# ---------------------------------------------------------------- 14. 弧的锁定
func _section_lock_arc() -> void:
	_log("[14] arc_key 锁定：预设走对应弧，自定义/未定走通用弧")
	_sd.set_goal_preset("warden")
	_sd.arc_key = ""
	_sd.lock_arc()
	_ok(_sd.arc_key == "warden", "选守望 → 锁定 warden 弧")
	_ok(_sd.arc_title() == "归处", "warden 弧的名字是「归处」")

	_sd.set_goal_preset("bridge")
	_ok(_sd.arc_key == "bridge", "改选架桥 → arc_key 跟着变成 bridge")

	_sd.set_goal_custom("我想去看海。")
	_ok(_sd.arc_key == "generic", "自定义结局 → 走通用弧")

	_sd.clear_goal()
	_ok(_sd.arc_key == "generic", "未定结局 → 走通用弧")
	_ok(_sd.arc_title() == "", "通用弧没有专属名字")

	# 锁一次就不再变（中途若被清空也能重新锁回来）
	_sd.set_goal_preset("hermit")
	_sd.lock_arc()
	var first: String = _sd.arc_key
	_sd.lock_arc()
	_ok(_sd.arc_key == first, "lock_arc() 幂等，不会改来改去")


# ---------------------------------------------------------------- 15. 章节落在弧上的那一幕
func _section_beat_alignment() -> void:
	_log("[15] 每一章都正对弧上的那一幕（离线兜底）")
	for g in _sd.PRESET_GOALS:
		var id := str(g.get("id", ""))
		_sd.set_goal_preset(id)
		var acts: Array = (_sd.STORY_ARCS[id] as Dictionary).get("acts", [])
		var aligned := true
		var acts_seen := {}
		for n in range(1, _sd.MAX_CHAPTERS + 1):
			_sd.chapter = n
			var beat: Dictionary = _sd.current_beat()
			var mock: Dictionary = _sd._mock_chapter(n)
			if str(beat.get("name", "")) != str(mock.get("name", "")):
				aligned = false
			if str(mock.get("name", "")) != str((acts[n - 1] as Dictionary).get("name", "")):
				aligned = false
			acts_seen[str(beat.get("act", ""))] = true
		_ok(aligned, "预设 %s：current_beat / _mock_chapter 与弧逐幕一致" % id)
		var all_acts := true
		for k in ["起", "承", "转", "合"]:
			if not acts_seen.has(k):
				all_acts = false
		_ok(all_acts, "预设 %s：八章走完覆盖起承转合" % id)
	# 超出八章会绕回弧首（可以无限往下写）
	_sd.set_goal_preset("warden")
	_sd.chapter = _sd.MAX_CHAPTERS + 1
	_ok(str(_sd.current_beat().get("name", "")) == "生分的门槛", "第 9 章绕回第 1 幕")


# ---------------------------------------------------------------- 16. 支线反馈进主线判定
func _section_milestones() -> void:
	_log("[16] 支线完成 → 记里程碑 → 成为过章门槛")
	_sd.clear_goal()
	_sd.chapter = 0
	_sd.milestones = []
	# quest_completed 信号会带着任务字典进来，_on_progress 据此记一条里程碑
	_sd._on_progress({"title": "替老人把信送到镇上", "source_npc": "阿岩", "target_location": ""})
	_ok(_sd.milestones.size() == 1, "完成一个支线 → 记下一条里程碑")
	_ok(str((_sd.milestones[0] as Dictionary).get("npc", "")) == "阿岩", "里程碑记下了委托人")
	# 同名同委托人只记一次
	_sd._on_progress({"title": "替老人把信送到镇上", "source_npc": "阿岩", "target_location": ""})
	_ok(_sd.milestones.size() == 1, "同一件事重复完成不会重复记")
	# 换一个人/换一件事是新的一条
	_sd._on_progress({"title": "把走丢的鸡找回来", "source_npc": "东家", "target_location": ""})
	_ok(_sd.milestones.size() == 2, "另一件事会再记一条")
	# 没有任务的空进展不能记成里程碑
	_sd._on_progress()
	_sd._on_progress("随便一个字符串")
	_ok(_sd.milestones.size() == 2, "非任务进展不会误记里程碑")

	# 门槛行：进度表里必须有「本章促成的事」，且随里程碑达标
	var found := false
	for row in _sd.progress_rows():
		if str(row["label"]) == "本章促成的事":
			found = true
			_ok(bool(row["done"]), "里程碑够 1 条时该门槛达标")
	_ok(found, "进度表里有「本章促成的事」这一行")

	# 一件不成时，整章判定过不去（即使别的数字都够）
	# 把另外三项都顶到远超门槛，只留「本章促成的事」这一项卡着，看主线到底认不认支线
	var pp = root.get_node_or_null("PlayerProfile")
	var wd = root.get_node_or_null("WorldData")
	var nm = root.get_node_or_null("NpcMemory")
	if pp == null or wd == null or nm == null:
		_ok(false, "缺少 PlayerProfile / WorldData / NpcMemory autoload")
		return
	var saved_q: int = pp.quests_completed
	var saved_locs: Array = wd.LOCATIONS.duplicate(true)
	var saved_base: int = wd._base_count
	var saved_states: Dictionary = nm._states.duplicate(true)
	pp.quests_completed = 999
	wd.LOCATIONS.clear()
	wd._base_count = 0
	for i in range(50):
		wd.LOCATIONS.append({"id": "probe%d" % i, "name": "探针地%d" % i})
	nm._states = {"probe": {"affinity": 100000}}
	_sd.chapter = 1
	_sd.milestones = []
	_ok(not _sd.chapter_done(), "别的都够、本章一件支线都没促成时，过不了章")
	_sd.milestones = [{"title": "促成了一件", "npc": "某人", "place": ""}]
	_ok(_sd.chapter_done(), "补上一件支线后，本章随即达标可过")
	pp.quests_completed = saved_q
	wd.LOCATIONS.clear()
	for loc in saved_locs:
		wd.LOCATIONS.append(loc)
	wd._base_count = saved_base
	nm._states = saved_states
	_sd.chapter = 0
	_sd.milestones = []


# ---------------------------------------------------------------- 17. 章节回顾 / 结局回顾 / 存档往返
func _section_log_and_recap() -> void:
	_log("[17] 走过的章节 → 结局回顾；新字段存档往返")
	var pp = root.get_node_or_null("PlayerProfile")
	if pp == null:
		_ok(false, "缺少 PlayerProfile autoload")
		return
	_sd.set_goal_preset("warden")
	_sd.chapter = 8
	_sd.milestones = [{"title": "守过这一夜", "npc": "全村人", "place": ""}]
	var beat: Dictionary = _sd.current_beat()
	_sd.chapter_log = [
		{"cycle": 1, "chapter": 1, "title": "第 1 章 · 生分的门槛", "name": "生分的门槛", "act": "起",
			"milestones": [{"title": "替老人把信送到镇上", "npc": "阿岩", "place": ""}]},
	]
	var saved_q: int = pp.quests_completed
	pp.quests_completed = 3
	var recap: String = _sd._recap_line()
	_ok(recap.find("办成了 3 件事") != -1, "_recap_line() 报出办成的事数")
	_ok(recap.find("阿岩") != -1, "_recap_line() 点出托付过玩家的人")
	var journey: String = _sd._journey_block()
	_ok(journey.find("生分的门槛") != -1, "_journey_block() 带上走过的章节")
	_ok(str(beat.get("name", "")) != "", "第 8 章正对弧上第 8 幕（守到天亮）")
	pp.quests_completed = saved_q

	# 新字段存档往返
	var data: Dictionary = _sd.to_save()
	_ok(data.has("arc_key") and data.has("milestones") and data.has("chapter_log"), "to_save() 带上三个新字段")
	_sd.arc_key = ""
	_sd.milestones = []
	_sd.chapter_log = []
	_sd.from_save(data)
	_ok(_sd.arc_key == "warden", "读档后 arc_key 恢复")
	_ok(_sd.milestones.size() == 1, "读档后本章里程碑恢复")
	_ok(_sd.chapter_log.size() == 1, "读档后章节回顾恢复")

	# 坏数据收敛
	_sd.from_save({"arc_key": "bogus"})
	_ok(_sd.arc_key == "", "非法 arc_key 被收敛为空（交给 lock_arc 重算）")
	_sd.from_save({"arc_key": "generic"})
	_ok(_sd.arc_key == "generic", "generic 是合法弧键")
	_sd.from_save({"milestones": [{"title": "ok"}, {"nope": 1}, "x", {"title": "  "}]})
	_ok(_sd.milestones.size() == 1, "里程碑坏数据被逐项过滤")
	_sd.from_save({"chapter_log": ["x", {"title": "y"}, 3]})
	_ok(_sd.chapter_log.size() == 1, "章节回顾坏数据被逐项过滤")


# ---------------------------------------------------------------- 19. 终局链：发任务即承诺
## 预设结局开局，就把终极目标的三站真实落点落实下来：
## 地点真的进了 WorldData、人真的在 NpcGenerator 登记过，台词里点的名字都是世上真有的。
func _section_ultimate_commit() -> void:
	_log("[19] 终局链：发任务即承诺（真实地点 + 真实的人）")
	var lg = root.get_node_or_null("LocationGenerator")
	var ng = root.get_node_or_null("NpcGenerator")
	var wd = root.get_node_or_null("WorldData")
	var pp = root.get_node_or_null("PlayerProfile")
	var sd2 = root.get_node_or_null("SceneDecorator")
	if lg == null or ng == null or wd == null or pp == null:
		_ok(false, "缺少 LocationGenerator / NpcGenerator / WorldData / PlayerProfile autoload")
		return
	var saved_lg_mode: String = lg.mode
	var saved_ng_mode: String = ng.mode
	var saved_dec_mode: String = sd2.mode if sd2 != null else ""
	lg.mode = "mock"
	ng.mode = "mock"
	# SceneDecorator 监听着 location_created：地点一落地它就会去布置，也让它离线走兜底
	if sd2 != null:
		sd2.mode = "mock"

	# 清成全新一局，再用预设结局起点
	_sd.ultimate_goal = {}
	_sd.goal_step = 0
	_sd._commit = {}
	_sd.chapter = 0
	_sd.finished = false
	_sd._busy = false
	_sd.set_goal_preset("warden")

	_ok(_sd._try_start_ultimate_goal(), "预设结局开局 → 启动终局链（挑得到三块远地）")
	# mock 下地点同步回调、人走 call_deferred，多等几帧让承诺状态机跑完
	for i in range(12):
		await process_frame

	_ok(_sd.has_ultimate_goal(), "终局链落实 → 有了终极目标")
	var steps: Array = _sd.ultimate_steps()
	_ok(steps.size() == int(_sd.FINAL_STEPS), "终局链正好 %d 站" % int(_sd.FINAL_STEPS))
	_ok(_sd.ultimate_goal_title() != "", "终极目标有名字")
	_ok(_sd.ultimate_goal_desc() != "", "终极目标有含义")
	_ok(str(_sd.ultimate_goal.get("type", "")) == "warden", "终极目标类型为 warden")

	var dists: Array = _sd.FINAL_DISTANCES_M
	var band: float = float(_sd.FINAL_DIST_BAND_M)
	var last_d := -1.0
	for i in range(steps.size()):
		var st: Dictionary = steps[i]
		var lid := str(st.get("location_id", ""))
		var lname := str(st.get("location_name", ""))
		var who := str(st.get("npc_name", ""))
		var d := float(st.get("distance_m", 0))
		_ok(lid != "" and wd.has_id(lid), "第 %d 站：地点真的在世上（%s）" % [i + 1, lid])
		_ok(lname != "" and lname == wd.name_of(lid), "第 %d 站：站名与世上地点一致（%s）" % [i + 1, lname])
		_ok(who != "" and ng.is_name_used(who), "第 %d 站：要见的人真的在世上（%s）" % [i + 1, who])
		_ok(d >= float(dists[i]) - band and d <= float(dists[i]) + band,
			"第 %d 站：距离落在 %d 米一带（实 %.0f）" % [i + 1, int(dists[i]), d])
		_ok(d > last_d, "第 %d 站：比上一站更远" % (i + 1))
		last_d = d
		_ok(str(st.get("direction", "")) != "", "第 %d 站：给了方位" % (i + 1))
		var line := str(st.get("line", ""))
		_ok(line.contains(lname) and line.contains(who), "第 %d 站：台词点出了真实地点与人" % (i + 1))
		_ok(int(st.get("talk_base", -1)) == pp.talk_count(who), "第 %d 站：履约基线记的是当前交谈次数" % (i + 1))
		_ok(not bool(st.get("done", true)), "第 %d 站：开局还没见人，未完成" % (i + 1))

	lg.mode = saved_lg_mode
	ng.mode = saved_ng_mode
	if sd2 != null:
		sd2.mode = saved_dec_mode


# ---------------------------------------------------------------- 20. 终局章推进与硬门槛
func _section_ultimate_progress() -> void:
	_log("[20] 终局章：落点对齐 + 硬门槛（真见到人才算过）")
	if not _sd.has_ultimate_goal():
		_ok(false, "前置终局链缺失，无法测推进")
		return
	var pp = root.get_node_or_null("PlayerProfile")
	var nm = root.get_node_or_null("NpcMemory")
	var wd = root.get_node_or_null("WorldData")
	if pp == null or nm == null or wd == null:
		_ok(false, "缺少 PlayerProfile / NpcMemory / WorldData autoload")
		return
	var steps: Array = _sd.ultimate_steps()

	# 第 6/7/8 章分别正对终局链第 1/2/3 站
	for n in [6, 7, 8]:
		_sd.chapter = n
		var fi: int = _sd.current_final_index()
		_ok(fi == n - 6, "第 %d 章正对终局链第 %d 站" % [n, n - 5])
		var mc: Dictionary = _sd._mock_chapter(n)
		_ok(str(mc.get("name", "")) == str((steps[fi] as Dictionary).get("name", "")),
			"第 %d 章的幕名取自终局链那一站" % n)

	var saved_talks: Dictionary = pp.talks.duplicate(true)
	var saved_total: int = pp.total_talks
	var saved_q: int = pp.quests_completed
	var saved_states: Dictionary = nm._states.duplicate(true)
	var saved_locs: Array = wd.LOCATIONS.duplicate(true)
	var saved_base: int = wd._base_count

	# 除「终局 · 去见 X」外，其余门槛全顶到远超标准
	var who0 := str((steps[0] as Dictionary).get("npc_name", ""))
	# 用当章真正的门槛值，别写死——节奏调参后这里要跟着走
	pp.quests_completed = int(_sd._requirement_for(6).get("quests_completed", 6))
	# 走出来的新地方也要顶够：清掉运行时地点，塞一批探针地点，把 runtime_count 顶到门槛之上
	wd.LOCATIONS.clear()
	wd._base_count = 0
	var need_locs: int = int(_sd._requirement_for(6).get("new_locations", 6))
	for i in range(need_locs + 4):
		wd.LOCATIONS.append({"id": "probe_up%d" % i, "name": "探针地%d" % i})
	nm._states = {"probe": {"affinity": 100000}}
	_sd.chapter = 6
	_sd.milestones = [{"title": "促成了一件", "npc": "某人", "place": ""}]
	for s in steps:
		(s as Dictionary)["done"] = false
	_sd.goal_step = 0

	var gate_label := ""
	var others_ok := true
	for row in _sd.progress_rows():
		if str(row["label"]).begins_with("终局 · 去见"):
			gate_label = str(row["label"])
			_ok(not bool(row["done"]), "终局硬门槛：还没去见人 → 该行未达标")
			_ok(str(row["label"]).contains(who0), "终局硬门槛行点出了要见的人")
		elif not bool(row["done"]):
			others_ok = false
	_ok(gate_label != "", "终局章进度表里多出「终局 · 去见 …」一行")
	_ok(others_ok, "其余门槛都能达标（只有终局门槛卡着）")
	_ok(not _sd.chapter_done(), "人没去见 → 本章过不去")

	# 真去见了 → 这一站算过，章节随之达标
	(steps[0] as Dictionary)["done"] = true
	_sd._sync_final_steps()
	_ok(_sd.goal_step == 1, "见完第 1 站 → 推进到第 2 站")
	_ok(_sd.chapter_done(), "终局门槛一过，本章随即达标")

	# note_talk 入口：真搭过话 → 这一站自动算履约；其余门槛未达时章节不误推进
	var who0b := str((steps[0] as Dictionary).get("npc_name", ""))
	(steps[0] as Dictionary)["done"] = false
	(steps[0] as Dictionary)["talk_base"] = pp.talk_count(who0b)
	_sd.goal_step = 0
	pp.quests_completed = 0
	nm._states = {}
	_sd.milestones = []
	_sd.chapter = 6
	pp.record_talk(who0b)
	_sd.note_talk(who0b)
	_ok(bool((steps[0] as Dictionary).get("done", false)), "搭过话 → 第 1 站自动算履约")
	_ok(_sd.goal_step == 1, "搭过话 → 推进到第 2 站")
	_ok(_sd.chapter == 6, "其余门槛未达时，章节不会误推进")

	pp.talks = saved_talks
	pp.total_talks = saved_total
	pp.quests_completed = saved_q
	nm._states = saved_states
	wd.LOCATIONS.clear()
	for loc in saved_locs:
		wd.LOCATIONS.append(loc)
	wd._base_count = saved_base
	_sd.milestones = []
	_sd.chapter = 1


# ---------------------------------------------------------------- 21. 终局链存档往返 + 坏数据收敛
func _section_ultimate_save() -> void:
	_log("[21] 终局链存档往返 + 坏数据收敛")
	var wd = root.get_node_or_null("WorldData")
	if wd == null:
		_ok(false, "缺少 WorldData autoload")
		return
	var gg: Dictionary = _sd.ultimate_goal.duplicate(true)
	var step0: int = _sd.goal_step
	var data: Dictionary = _sd.to_save()
	_ok(data.has("ultimate_goal") and data.has("goal_step"), "to_save() 带上 ultimate_goal / goal_step")

	_sd.ultimate_goal = {}
	_sd.goal_step = 0
	_sd.from_save(data)
	_ok(_sd.has_ultimate_goal(), "读档后终局链恢复")
	_ok(_sd.ultimate_steps().size() == int(_sd.FINAL_STEPS), "读档后三站齐全")
	_ok(_sd.goal_step == step0, "读档后 goal_step 恢复")
	_ok(str(_sd.ultimate_goal.get("name", "")) == str(gg.get("name", "")), "读档后终极目标名不变")

	# 坏数据一律收敛成「没有终局链」
	var bad: Array = [
		null,
		{"type": "bogus", "name": "x", "steps": [{"location_id": "nope"}]},
		{"type": "warden", "name": "", "steps": [{"location_id": "nope"}]},
		{"type": "warden", "name": "x"},
		{"type": "warden", "name": "x", "steps": "不是数组"},
		{"type": "warden", "name": "x", "steps": [{"location_id": "世上没有的地"}]},
	]
	for i in range(bad.size()):
		_ok(_sd._sanitize_ultimate(bad[i]).is_empty(), "坏终极目标数据被收敛（第 %d 组）" % (i + 1))
	# 合法数据能过
	var got: Dictionary = _sd._sanitize_ultimate(gg)
	_ok(not got.is_empty(), "合法终极目标数据能通过校验")
	_ok((got.get("steps", []) as Array).size() == int(_sd.FINAL_STEPS), "校验后三站仍在")

	_sd.ultimate_goal = gg
	_sd.goal_step = step0


# ---------------------------------------------------------------- 22. 终局链守卫
func _section_ultimate_guards() -> void:
	_log("[22] 终局链守卫：不自造、幂等、章节落点边界、新一轮复位")
	var snap: Dictionary = _sd.to_save()
	var kept: Dictionary = _sd.ultimate_goal.duplicate(true)

	# 自定义结局：也会启动终局链（心愿同样要落到真地点、真人身上）。
	# 完整的落实 + 预备流程在「自定义结局预备」一节单测，这里只确认资格判定放行 custom。
	_sd.ultimate_goal = {}
	_sd._commit = {}
	_sd.set_goal_custom("我想去看海。")
	_ok(not _sd._goal_template().is_empty(), "自定义结局有终局模板（会启动终局链，不再被挡）")
	_sd.clear_goal()
	_sd.ultimate_goal = {}
	_sd._commit = {}
	_ok(not _sd._try_start_ultimate_goal(), "没定结局不会启动终局链")

	# 已经有终局链 → 再启动是幂等的（返回 false，不重建）
	_sd.set_goal_preset("warden")
	_sd.ultimate_goal = kept.duplicate(true)
	_sd._commit = {}
	_ok(not _sd._try_start_ultimate_goal(), "已有终局链时再启动返回 false（幂等）")
	_ok(_sd.ultimate_steps().size() == int(_sd.FINAL_STEPS), "幂等调用不破坏已有终局链")

	# 章节 → 终局站索引的边界
	_ok(_sd._final_step_index(5) == -1, "第 5 章还没进终局链")
	_ok(_sd._final_step_index(6) == 0, "第 6 章 = 终局链第 1 站")
	_ok(_sd._final_step_index(8) == 2, "第 8 章 = 终局链第 3 站")
	_ok(_sd._final_step_index(9) == -1, "第 9 章超出终局链")

	# 开新一轮：进度清空、章节回到第 1 章
	var before_cycle: int = _sd.cycle
	_sd.chapter = 8
	_sd.begin_new_cycle()
	_ok(_sd.cycle == before_cycle + 1, "新一轮 → cycle 加一")
	_ok(_sd.goal_step == 0, "新一轮 → 终局进度清零")
	_ok(_sd.chapter == 1, "新一轮 → 章节回到第 1 章")
	var all_false := true
	for s in _sd.ultimate_steps():
		if bool((s as Dictionary).get("done", false)):
			all_false = false
	_ok(all_false, "新一轮 → 三站都回到未完成")

	# 恢复现场
	_sd.from_save(snap)


# ---------------------------------------------------------------- 23. 自定义结局：现场编弧 + 加载期预备
## 玩家自己写结局时，先在加载场景里把这一程预备好：
##   0 编主线 → 1 铺终局三站 → 2 写第一章 → 3 收尾
## 这里离线跑一遍，确认进度信号按序报全、八幕弧真有 8 幕、终局链落到真人真地上、第一章真写出来。
func _section_custom_prepare() -> void:
	_log("[23] 自定义结局：现场编八幕弧 + 加载期预备")
	var lg = root.get_node_or_null("LocationGenerator")
	var ng = root.get_node_or_null("NpcGenerator")
	var wd = root.get_node_or_null("WorldData")
	var sd2 = root.get_node_or_null("SceneDecorator")
	if lg == null or ng == null or wd == null:
		_ok(false, "缺少 LocationGenerator / NpcGenerator / WorldData autoload")
		return
	var saved_lg: String = lg.mode
	var saved_ng: String = ng.mode
	var saved_dec: String = sd2.mode if sd2 != null else ""
	lg.mode = "mock"
	ng.mode = "mock"
	if sd2 != null:
		sd2.mode = "mock"

	var snap: Dictionary = _sd.to_save()

	# 清成全新一局，定下自定义结局
	_sd.ultimate_goal = {}
	_sd.goal_step = 0
	_sd._commit = {}
	_sd._prepare = {}
	_sd.chapter = 0
	_sd.finished = false
	_sd._busy = false
	_sd.custom_arc = []
	_sd.custom_arc_title = ""
	_sd.set_goal_custom("我想带着全村人搬到海边住。")

	# 录下预备过程的进度信号，事后核对顺序
	var steps: Array = []
	var done_flags: Array = []
	var cb_progress := func(step: int, _text: String) -> void:
		steps.append(step)
	var cb_finished := func(ok: bool) -> void:
		done_flags.append(ok)
	_sd.prepare_progress.connect(cb_progress)
	_sd.prepare_finished.connect(cb_finished)

	_sd.prepare_custom_ending()
	# 离线（mock）下：编弧是同步的，终局落实与第一章写作经 call_deferred 跑完，多等几帧
	for i in range(20):
		await process_frame
		if _sd._prepare.is_empty():
			break

	_sd.prepare_progress.disconnect(cb_progress)
	_sd.prepare_finished.disconnect(cb_finished)

	# 进度信号按 0→1→2→3 报齐，最后 ok=true
	_ok(steps.size() >= 4, "预备进度至少报了 4 步")
	_ok(int(steps[0]) == 0 and int(steps[steps.size() - 1]) == 3, "预备进度从「编主线」走到「收尾」")
	var monotonic := true
	for i in range(1, steps.size()):
		if int(steps[i]) < int(steps[i - 1]):
			monotonic = false
	_ok(monotonic, "预备进度只增不减")
	_ok(done_flags.size() == 1 and bool(done_flags[0]), "预备完成信号 ok=true")

	# 现场编出来的八幕弧
	_ok(_sd.custom_arc.size() == int(_sd.MAX_CHAPTERS), "自定义弧正好 8 幕")
	_ok(_sd.custom_arc_title != "", "自定义弧有名字")
	_ok(_sd.current_arc().size() == _sd.custom_arc.size(), "current_arc() 走的是这条自定义弧")
	var act_ok := true
	for a in _sd.custom_arc:
		var ad: Dictionary = a
		if str(ad.get("name", "")) == "" or str(ad.get("intro", "")) == "" or str(ad.get("goal", "")) == "":
			act_ok = false
	_ok(act_ok, "自定义弧每一幕 name/intro/goal 齐全")

	# 终局链：三站都落到真人真地上，类型是 custom
	_ok(_sd.has_ultimate_goal(), "自定义结局也建起了终局链")
	var usteps: Array = _sd.ultimate_steps()
	_ok(usteps.size() == int(_sd.FINAL_STEPS), "自定义终局链正好 %d 站" % int(_sd.FINAL_STEPS))
	_ok(str(_sd.ultimate_goal.get("type", "")) == "custom", "自定义终极目标类型为 custom")
	for i in range(usteps.size()):
		var lid := str((usteps[i] as Dictionary).get("location_id", ""))
		var who := str((usteps[i] as Dictionary).get("npc_name", ""))
		_ok(lid != "" and wd.has_id(lid), "自定义第 %d 站：地点真的在世上" % (i + 1))
		_ok(who != "" and ng.is_name_used(who), "自定义第 %d 站：要见的人真的在世上" % (i + 1))

	# 第一章已经写好，加载动画这才收尾
	_ok(_sd.chapter == 1, "预备结束时停在第 1 章")
	_ok(not _sd.chapter_data.is_empty(), "第 1 章已经写好内容")
	_ok(_sd._prepare.is_empty(), "预备状态已清空（不会再重复走）")

	# 再叫一次：已经推进过 → 直接 ok=true，不重编
	var again: Array = []
	var cb2 := func(ok: bool) -> void:
		again.append(ok)
	_sd.prepare_finished.connect(cb2)
	_sd.prepare_custom_ending()
	_sd.prepare_finished.disconnect(cb2)
	_ok(again.size() == 1 and bool(again[0]), "已经推进过时，再预备直接放行")

	# 预设结局不走预备（用现成模板，秒进主场景）
	_sd.set_goal_preset("warden")
	var nr: Array = []
	var cb3 := func(ok: bool) -> void:
		nr.append(ok)
	_sd.prepare_finished.connect(cb3)
	_sd.prepare_custom_ending()
	_sd.prepare_finished.disconnect(cb3)
	_ok(nr.size() == 1 and not bool(nr[0]), "预设结局不走预备（ok=false，直接进主场景）")

	# 恢复现场
	_sd.from_save(snap)
	lg.mode = saved_lg
	ng.mode = saved_ng
	if sd2 != null:
		sd2.mode = saved_dec


# ---------------------------------------------------------------- 24. 自定义弧的校验与容错
func _section_arc_sanitize() -> void:
	_log("[24] 自定义弧校验：坏数据一律退回通用弧")
	var ok_arc: Dictionary = _sd._mock_arc()
	_ok(not _sd._sanitize_arc(ok_arc).is_empty(), "合规的八幕数据能过校验")
	_ok(_sd._sanitize_arc(null).is_empty(), "null 被拒")
	_ok(_sd._sanitize_arc({"acts": "不是数组"}).is_empty(), "acts 不是数组被拒")
	_ok(_sd._sanitize_arc({"acts": []}).is_empty(), "空 acts 被拒")
	# 少一幕 → 被拒（必须整整 8 幕）
	var short_acts: Array = (ok_arc.get("acts", []) as Array).duplicate(true)
	short_acts.remove_at(0)
	_ok(_sd._sanitize_arc({"title": "残缺", "acts": short_acts}).is_empty(), "只有 7 幕被拒")
	# 某一幕缺字段 → 被拒
	var bacts: Array = (ok_arc.get("acts", []) as Array).duplicate(true)
	(bacts[2] as Dictionary)["goal"] = ""
	_ok(_sd._sanitize_arc({"title": "缺字段", "acts": bacts}).is_empty(), "某一幕缺 goal 被拒")
	# 没写标题 → 兜底成「心愿」；没写 act → 按起承转合自动补全
	var noact: Dictionary = _sd._sanitize_arc({
		"title": "  ",
		"acts": (ok_arc.get("acts", []) as Array).duplicate(true),
	})
	_ok(str(noact.get("title", "")) == "心愿", "标题为空时兜底成「心愿」")
	var got_acts: Array = noact.get("acts", [])
	_ok(got_acts.size() == int(_sd.MAX_CHAPTERS) and str((got_acts[0] as Dictionary).get("act", "")) != "",
		"缺 act 时按起承转合自动补全")


# ---------------------------------------------------------------- 18. LLM 路径冒烟（不联网）
## 用非法地址，让 HTTPRequest 在发起阶段就直接失败并同步回退，不产生任何网络请求。
## 这样既走了一遍 prompt 拼接，又不依赖网络；如果 prompt 的格式化参数数目对不上，
## _call_llm 会在拼接处报错中断，_current 不会被清空 —— 下面的断言正是用来抓这种低级错误。
func _section_llm_smoke() -> void:
	_log("[18] LLM 路径冒烟（非法地址，不联网）")
	var qm = root.get_node_or_null("QuestManager")
	var dg = root.get_node_or_null("DialogueGenerator")
	if qm == null or dg == null:
		_ok(false, "缺少 QuestManager / DialogueGenerator autoload")
		return
	_sd.set_goal_custom("我想带着全村人搬到海边住。")

	qm.mode = "llm"
	qm.api_key = "probe"
	qm.api_base = "not-a-url"
	var before: int = qm.quests.size()
	qm.request_quest("探针甲", "村民", "爱打听")
	var q_ok := false
	for i in range(20):
		await create_timer(0.2).timeout
		if qm.quests.size() > before or qm._current.is_empty():
			q_ok = true
			break
	_ok(q_ok, "支线 LLM 路径走通并回退兜底（任务落地，没卡在拼 prompt）")

	dg.mode = "llm"
	dg.api_key = "probe"
	dg.api_base = "not-a-url"
	dg.request_line("探针乙", "村民", "沉默寡言", PackedStringArray(["……"]))
	var d_ok := false
	for i in range(20):
		await create_timer(0.2).timeout
		if dg._current.is_empty():
			d_ok = true
			break
	_ok(d_ok, "台词 LLM 路径走通并回退兜底（_current 已清空，没卡在拼 prompt）")

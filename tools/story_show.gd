extends SceneTree
## 展示工具：把 4 条预设主线（每条 8 幕，起承转合俱全）连结局、连终极目标与三站终局链
## 一起打印出来给人看。
## 用法：godot --headless --path . --script res://tools/story_show.gd
##
## 纯离线：只读 StoryDirector 的常量与离线生成结果，不联网、不写存档。
## 唯一会「动手」的地方：为了展示真实的终局落点，会以 mock 方式真跑一次
## 「发任务即承诺」（三站地点与人落地后原样读出），跑完立刻还原现场。

var _sd   # StoryDirector
var _pp   # PlayerProfile


func _initialize() -> void:
	_run()


func _line(s: String = "") -> void:
	print(s)


func _run() -> void:
	await process_frame
	_sd = root.get_node_or_null("StoryDirector")
	if _sd == null:
		_line("[show] 缺少 StoryDirector autoload")
		quit(1)
		return
	_pp = root.get_node_or_null("PlayerProfile")
	_sd.mode = "mock"

	await _show_arc("warden")
	await _show_arc("wanderer")
	await _show_arc("bridge")
	await _show_arc("hermit")
	_show_generic()
	_show_feedback_demo()

	quit(0)


func _show_arc(key: String) -> void:
	var table: Dictionary = _sd.STORY_ARCS
	if not table.has(key):
		return
	var arc: Dictionary = table[key]
	var acts: Array = arc.get("acts", [])
	_line("")
	_line("════════════════════════════════════════════════════════════")
	_line("预设主线《%s》　（奔向的结局：%s）" % [
		str(arc.get("title", "")), str(_sd.ENDING_NAMES.get(key, "")),
	])
	_line("共 %d 幕，起—承—转—合：" % acts.size())
	_line("════════════════════════════════════════════════════════════")
	for i in range(acts.size()):
		var a: Dictionary = acts[i]
		_line("")
		_line("第 %d 幕（%s）· %s" % [i + 1, str(a.get("act", "")), str(a.get("name", ""))])
		_line("  戏眼：%s" % str(a.get("beat", "")))
		_line("  开头：%s" % str(a.get("intro", "")))
		_line("  目标：%s" % str(a.get("goal", "")))
	_line("")
	_line("—— 这一程的结局：")
	_show_ending_for(key)
	await _show_ultimate_for(key)


## 让 StoryDirector 以该预设结局生成一次离线结局正文（含玩家做过的回顾）
func _show_ending_for(key: String) -> void:
	var saved_kind: String = _sd.goal_kind
	var saved_preset: String = _sd.goal_preset
	var saved_arc: String = _sd.arc_key
	_sd.goal_kind = "preset"
	_sd.goal_preset = key
	_sd.arc_key = key
	var e: Dictionary = _sd._mock_ending()
	_line("  《%s》" % str(e.get("title", "")))
	_line("  %s" % str(e.get("text", "")).replace("\n", "\n  "))
	_line("  %s" % str(e.get("epilogue", "")))
	_sd.goal_kind = saved_kind
	_sd.goal_preset = saved_preset
	_sd.arc_key = saved_arc


## 展示这条预设主线的「终极目标」与三站终局链（真实落点）。
## 做法：以 mock 方式真启动一次「发任务即承诺」，让三站的地点与人落地，再原样读出来。
## 这就是用户红线要的效果——任务指向的地方和人，在任务发出的那一刻就已经在地图上了。
func _show_ultimate_for(key: String) -> void:
	var lg = root.get_node_or_null("LocationGenerator")
	var ng = root.get_node_or_null("NpcGenerator")
	var dec = root.get_node_or_null("SceneDecorator")
	var saved_lg: String = lg.mode if lg != null else ""
	var saved_ng: String = ng.mode if ng != null else ""
	var saved_dec: String = dec.mode if dec != null else ""
	# 生成终局地点会触发 SceneDecorator 布置，全部走离线兜底，别真发网络请求
	if lg != null:
		lg.mode = "mock"
	if ng != null:
		ng.mode = "mock"
	if dec != null:
		dec.mode = "mock"

	# 保存现场，展示完原样还原
	var saved_kind: String = _sd.goal_kind
	var saved_preset: String = _sd.goal_preset
	var saved_arc: String = _sd.arc_key
	var saved_chapter: int = _sd.chapter
	var saved_finished: bool = _sd.finished
	var saved_goal: Dictionary = _sd.ultimate_goal
	var saved_step: int = _sd.goal_step
	var saved_commit: Dictionary = _sd._commit
	var saved_busy: bool = _sd._busy

	_sd.goal_kind = "preset"
	_sd.goal_preset = key
	_sd.arc_key = key
	_sd.ultimate_goal = {}
	_sd.goal_step = 0
	_sd._commit = {}
	_sd._busy = false
	_sd.chapter = 0
	_sd.finished = false

	var ok: bool = _sd._try_start_ultimate_goal()
	if ok:
		# 三站要一站一站落实（每站先出地点、再安排人），给足帧数
		for i in range(16):
			await process_frame

	_line("")
	_line("—— 终极目标（这一程最终要走到的地方，开局就已经钉在地图上了）：")
	if not ok or not _sd.has_ultimate_goal():
		_line("  （这一套没能落实出落点：世界太挤或挑到了海里，会退回普通弧线）")
	else:
		_line("  《%s》" % _sd.ultimate_goal_title())
		_line("  %s" % _sd.ultimate_goal_desc())
		var steps: Array = _sd.ultimate_steps()
		var first_ch: int = _sd.MAX_CHAPTERS - steps.size() + 1
		_line("  终局链 %d 站（前 %d 章走完才启程；第 %d~%d 章一站一站去）：" % [
			steps.size(), first_ch - 1, first_ch, _sd.MAX_CHAPTERS,
		])
		for st in steps:
			var s: Dictionary = st
			var who := str(s.get("npc_name", ""))
			_line("    第 %d 站（%s）· 往%s，约 %d 米 → %s" % [
				int(s.get("no", 0)), str(s.get("name", "")),
				str(s.get("direction", "")), int(s.get("distance_m", 0)),
				str(s.get("location_name", "")),
			])
			if who != "":
				_line("        要见的人：%s" % who)
			_line("        台词：「%s」" % str(s.get("line", "")))

	# 还原现场
	_sd.goal_kind = saved_kind
	_sd.goal_preset = saved_preset
	_sd.arc_key = saved_arc
	_sd.chapter = saved_chapter
	_sd.finished = saved_finished
	_sd.ultimate_goal = saved_goal
	_sd.goal_step = saved_step
	_sd._commit = saved_commit
	_sd._busy = saved_busy
	if lg != null:
		lg.mode = saved_lg
	if ng != null:
		ng.mode = saved_ng
	if dec != null:
		dec.mode = saved_dec


func _show_generic() -> void:
	var acts: Array = _sd.GENERIC_ARC
	_line("")
	_line("════════════════════════════════════════════════════════════")
	_line("通用主线　（玩家自己写结局、或没定结局时走这条）")
	_line("共 %d 幕：" % acts.size())
	_line("════════════════════════════════════════════════════════════")
	for i in range(acts.size()):
		var a: Dictionary = acts[i]
		_line("  第 %d 幕（%s）· %s —— %s" % [
			i + 1, str(a.get("act", "")), str(a.get("name", "")), str(a.get("beat", "")),
		])


## 演示「支线反馈到主线判定、并写进结局」：
## 走《归处》这条线，每章替 NPC 办成两件事（记成里程碑），走完再看结局怎么把这些事收进去。
func _show_feedback_demo() -> void:
	_line("")
	_line("════════════════════════════════════════════════════════════")
	_line("支线如何反馈到主线 —— 以《归处》走一遍为例")
	_line("════════════════════════════════════════════════════════════")

	var saved_kind: String = _sd.goal_kind
	var saved_preset: String = _sd.goal_preset
	var saved_arc: String = _sd.arc_key
	var saved_chapter: int = _sd.chapter
	var saved_ms: Array = _sd.milestones
	var saved_log: Array = _sd.chapter_log
	var saved_done: int = _pp.quests_completed if _pp != null else 0

	_sd.goal_kind = "preset"
	_sd.goal_preset = "warden"
	_sd.arc_key = "warden"
	_sd.milestones = []
	_sd.chapter_log = []
	# 八章、每章两件支线（正好对上现在的节奏：一章要办成两件事），两件都记成里程碑；
	# 每章走完把里程碑收进章节回顾，好让结局的「这一程」小结把它们收进去。
	var quests := [
		["替村口老人把话带到镇上", "阿岩"],
		["替磨坊主把卡住的石磨盘撬开", "磨坊主 老周"],
		["把熄了的老炉重新生上火", "炉边的老人"],
		["把打翻的酱缸扶回墙根", "酱坊的伙计"],
		["寻回断桥边上丢失的绳子", "脚夫"],
		["把桥头松了的木桩夯实", "守桥人 石老"],
		["替东家找回走丢的鸡", "东家"],
		["把晒场的谷子赶在雨前收拢", "晒场的老人"],
		["赶在雨前垒住要塌的坡", "村里的老把式"],
		["把进山的小路重新踩出来", "带队的老猎户"],
		["把要走的人家劝回来半户", "搬家的妇人"],
		["替新来的人家搭起灶台", "新来的妇人"],
		["把祠堂的灯一盏盏点上", "守祠堂的人"],
		["把族谱上记错的名字改回来", "管族谱的老先生"],
		["守过这一夜，等天亮", "全村人"],
		["天亮后陪大伙把村口的路扫干净", "全村人"],
	]
	var per_chapter: int = int(_sd.QUESTS_PER_CHAPTER)
	if _pp != null:
		_pp.quests_completed = 0
	var idx := 0
	for n in range(1, int(_sd.MAX_CHAPTERS) + 1):
		_sd.chapter = n
		_sd.milestones = []
		var titles: PackedStringArray = []
		for k in range(per_chapter):
			var q: Array = quests[idx]
			idx += 1
			_sd._remember_milestone({"title": str(q[0]), "source_npc": str(q[1]), "target_location": ""})
			titles.append(str(q[0]))
			if _pp != null:
				_pp.quests_completed += 1
		var beat: Dictionary = _sd.current_beat()
		_line("第 %d 章·%s ｜ 支线「%s」→ 本章促成 %d 件" % [
			n, str(beat.get("name", "")), "、".join(titles), _sd.milestones.size(),
		])
		_sd.chapter_log.append({
			"cycle": 1, "chapter": n,
			"title": "第 %d 章 · %s" % [n, str(beat.get("name", ""))],
			"name": str(beat.get("name", "")),
			"act": str(beat.get("act", "")),
			"milestones": _sd.milestones.duplicate(true),
		})

	_line("")
	_line("走完八章后的判定进度（本章促成的事，就是支线对主线的门槛）：")
	for row in _sd.progress_rows():
		_line("  %s %s：%d / %d" % [
			"✓" if bool(row["done"]) else "·", str(row["label"]), int(row["now"]), int(row["need"]),
		])
	_line("")
	_line("结局把这一程做过的事收了进去：")
	var e: Dictionary = _sd._mock_ending()
	_line("  《%s》" % str(e.get("title", "")))
	_line("  %s" % str(e.get("text", "")).replace("\n", "\n  "))

	# 还原现场
	_sd.goal_kind = saved_kind
	_sd.goal_preset = saved_preset
	_sd.arc_key = saved_arc
	_sd.chapter = saved_chapter
	_sd.milestones = saved_ms
	_sd.chapter_log = saved_log
	if _pp != null:
		_pp.quests_completed = saved_done

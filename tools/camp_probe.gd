extends SceneTree
## 一次性验证工具：坏人据点 / 种族 / 武器 / 靠近即攻击 / 清剿支线（只读，不发网络请求）
## 用法：godot --headless --path . --script res://tools/camp_probe.gd

const ENEMY_SCRIPT_PATH := "res://scripts/enemy.gd"

var _ed                      # EnemyData
var _wp                      # WeaponData
var _cd                      # CultureData
var _wd                      # WorldData
var _qm                      # QuestManager
var _pp                      # PlayerProfile
var _enemy_script            # enemy.gd；必须在 autoload 就绪后 load——探针编译期早于 autoload 注册，preload 会把 enemy.gd 编坏
var _fail := 0
var _lines: PackedStringArray = []


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
	_ed = root.get_node_or_null("EnemyData")
	_wp = root.get_node_or_null("WeaponData")
	_cd = root.get_node_or_null("CultureData")
	_wd = root.get_node_or_null("WorldData")
	_qm = root.get_node_or_null("QuestManager")
	_pp = root.get_node_or_null("PlayerProfile")
	if _ed == null or _wp == null or _cd == null or _wd == null or _qm == null or _pp == null:
		_log("[probe] 缺少必要 autoload")
		quit(1)
		return
	_enemy_script = load(ENEMY_SCRIPT_PATH)
	if _enemy_script == null:
		_log("[probe] enemy.gd 加载失败")
		quit(1)
		return

	_section_races()
	_section_guard()
	_section_weapons()
	_section_kinds()
	_section_camp_build()
	_section_guard_setup()
	_section_combat_quest()

	if _fail == 0:
		_log("== 全部通过 ==")
		quit(0)
	else:
		_log("== 失败 %d 项 ==" % _fail)
		quit(1)


func _section_races() -> void:
	_log("== 1. 坏人种族表 ==")
	_ok(_ed.RACES.size() == 8, "共 8 个种族（实际 %d）" % _ed.RACES.size())
	var humans := 0
	var others := 0
	var bad := ""
	for rid in _ed.race_ids():
		var r: Dictionary = _ed.race(str(rid))
		if str(r.get("name", "")) == "" or str(r.get("species", "")) == "":
			bad = str(rid)
		if not r.has("body") or not r.has("accent") or not r.has("scale"):
			bad = str(rid)
		if int(r.get("hp", 0)) <= 0 or float(r.get("speed", 0.0)) <= 0.0:
			bad = str(rid)
		if (r.get("weapons", []) as Array).is_empty():
			bad = str(rid)
		if bool(r.get("human", false)):
			humans += 1
		else:
			others += 1
	_ok(bad == "", "每个种族字段齐全%s" % ("" if bad == "" else "，异常：%s" % bad))
	_ok(humans >= 1, "有地球人种族（%d 个）" % humans)
	_ok(others >= 1, "有非地球人种族（%d 个）" % others)
	# 未知 id 要能回退
	_ok(not _ed.race("nobody").is_empty(), "未知种族 id 回退到默认")


func _section_guard() -> void:
	_log("== 2. 随机守兵 ==")
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261004
	var ok_race := true
	var ok_weapon := true
	var ok_hp := true
	var ok_gold := true
	var seen_races := {}
	for _i in 200:
		var g: Dictionary = _ed.roll_guard(rng)
		if not _ed.race_ids().has(str(g.get("race", ""))):
			ok_race = false
		var rid := str(g.get("race", ""))
		seen_races[rid] = true
		var ws: Array = (_ed.race(rid).get("weapons", []) as Array)
		if not ws.has(str(g.get("weapon", ""))):
			ok_weapon = false
		if int(g.get("hp", 0)) < 8:
			ok_hp = false
		if int(g.get("gold", -1)) < 0:
			ok_gold = false
	_ok(ok_race, "roll_guard 只返回合法种族")
	_ok(ok_weapon, "守兵的武器都出自该族武器池")
	_ok(ok_hp, "守兵血量 >= 8")
	_ok(ok_gold, "守兵掉落金币 >= 0")
	_ok(seen_races.size() >= 4, "200 次抽样覆盖到多种族（%d 种）" % seen_races.size())


func _section_weapons() -> void:
	_log("== 3. 武器数据 ==")
	var kinds := ["匕首", "长剑", "长矛", "斧", "战锤", "长弓"]
	for k in kinds:
		_ok(_ed.kind_range(k) > 0.0, "%s 有有效攻击距离 %.0f" % [k, _ed.kind_range(k)])
		_ok(_ed.kind_damage(k) > 0, "%s 有伤害 %d" % [k, _ed.kind_damage(k)])
		_ok(_ed.cooldown_for_kind(k) == _wp.cooldown_for_kind(k),
			"%s 出手间隔与武器表一致（%.2f）" % [k, _ed.cooldown_for_kind(k)])
	_ok(_ed.is_ranged_kind("长弓"), "长弓算远程")
	_ok(not _ed.is_ranged_kind("长剑"), "长剑算近战")
	# 每族的武器都必须是我们认识的 6 种之一
	var unknown := ""
	for rid in _ed.race_ids():
		for w in (_ed.race(str(rid)).get("weapons", []) as Array):
			if not kinds.has(str(w)):
				unknown = str(w)
	_ok(unknown == "", "所有种族武器都在 6 种之内%s" % ("" if unknown == "" else "，异常：%s" % unknown))


func _section_kinds() -> void:
	_log("== 4. camp 类型全链路 ==")
	_ok(_wd.ALLOWED_KINDS.has("camp"), "WorldData 允许 camp 类型")
	_ok(_cd.kinds_of("qingshi").has("camp"), "文化圈的 kinds_of 会补上 camp")
	# 连调两次，长度不能变（不能污染原始数据）
	var a: int = _cd.kinds_of("qingshi").size()
	var b: int = _cd.kinds_of("qingshi").size()
	_ok(a == b, "kinds_of 不污染原始数据（两次都是 %d 项）" % a)
	# camp 要能真的落地
	var lid := "probe_camp_1"
	var ok: bool = _wd.add_location({
		"id": lid, "name": "探针匪寨", "kind": "camp",
		"pos": Vector2(8000, -8000), "desc": "探针用",
	})
	_ok(ok and _wd.has_id(lid), "camp 地点能通过校验落地")
	var ok2: bool = _wd.add_location({
		"id": "probe_bad_1", "name": "探针非法点", "kind": "not_a_kind",
		"pos": Vector2(0, 0), "desc": "x",
	})
	_ok(not ok2, "非法类型依旧被拒")


func _section_camp_build() -> void:
	_log("== 5. 据点渲染 + 守兵生成 ==")
	var WM := load("res://scripts/world_map.gd")
	var wm = WM.new()   # 故意不进场景树：避免触发真实生图
	var pal: Dictionary = _cd.palette_of("qingshi")
	var before: int = wm.get_child_count()
	wm._build_camp(Vector2(50000, -50000), pal)
	var after: int = wm.get_child_count()
	_ok(after > before, "据点建出了一批节点（%d → %d）" % [before, after])
	# 统计挂在据点下的守兵
	var guards := 0
	var valid := 0
	for c in wm.get_children():
		if c.get_script() == _enemy_script:
			guards += 1
			if str(c.race_id) != "" and str(c.weapon_kind) != "":
				valid += 1
	_ok(guards >= 4, "据点里至少 4 名守兵（实际 %d）" % guards)
	_ok(valid == guards, "守兵都带上了种族与武器（%d/%d）" % [valid, guards])
	wm.free()


func _section_guard_setup() -> void:
	_log("== 6. 守兵属性接线 ==")
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var g: Dictionary = _ed.build_guard("lizard", rng)
	var e = _enemy_script.new()
	e.setup(int(g["hp"]), {}, "lizard", "长弓", 5)
	_ok(e.race_id == "lizard", "种族记下了：%s" % e.race_id)
	_ok(e.race_name == "蜥鳞游猎", "种族名取到了：%s" % e.race_name)
	_ok(e.species == "蜥人", "物种取到了：%s" % e.species)
	_ok(e.weapon_kind == "长弓", "武器记下了：%s" % e.weapon_kind)
	_ok(e._ranged, "长弓守兵被标成远程")
	_ok(e._attack_damage == _ed.kind_damage("长弓"), "远程伤害取自武器表（%d）" % e._attack_damage)
	_ok(e._aggro == e.GUARD_AGGRO, "守兵用更大的仇恨半径（%.0f）" % e._aggro)
	_ok(e.gold_drop == 5, "掉落金币写入了（%d）" % e.gold_drop)
	# 近战守兵不该是远程
	var e2 = _enemy_script.new()
	e2.setup(30, {}, "golem", "战锤", 3)
	_ok(not e2._ranged, "石傀战锤是近战")
	_ok(e2._attack_damage > _ed.kind_damage("匕首"), "战锤比匕首痛（%d > %d）" % [e2._attack_damage, _ed.kind_damage("匕首")])
	# 野物分支不受影响
	var e3 = _enemy_script.new()
	e3.setup(30, {"id": "ore_iron", "count": 1})
	_ok(e3.race_id == "" and not e3._ranged, "不传种族时仍是野物")
	e.free()
	e2.free()
	e3.free()


func _section_combat_quest() -> void:
	_log("== 7. 清剿支线 ==")
	# 造一个真地点当目标
	_wd.add_location({
		"id": "probe_camp_q", "name": "探针清剿点", "kind": "camp",
		"pos": Vector2(1234, -4321), "desc": "探针用",
	})
	var quest := {
		"type": "side", "source_npc": "探针委托人",
		"target_location": "probe_camp_q", "title": "清剿探针清剿点",
		"description": "探针", "stages": [{"goal": "前往"}],
		"combat": 3, "rewards": {"gold": 90},
	}
	_qm._finalize(quest)
	_ok(int(quest.get("combat", -1)) == 3, "combat 字段保留（%d）" % int(quest.get("combat", -1)))
	_ok(int(quest.get("defeated", -1)) == 0, "defeated 初始为 0")
	# combat 上限被夹紧
	var q2 := {"combat": 99, "target_location": "probe_camp_q", "source_npc": "x"}
	_qm._finalize(q2)
	_ok(int(q2.get("combat", -1)) == 8, "combat 被夹到上限 8（%d）" % int(q2.get("combat", -1)))
	# 接任务 → 目标点还没到 → 打不够 3 个不能算完成
	_qm.accept_quest(quest)
	var target: Vector2 = _wd.by_id("probe_camp_q")["pos"]
	_ok(_qm.try_complete_at(target) == false, "一个敌人都没打，站在据点里也不算完成")
	# 远处打死敌人不计数
	_qm.notify_enemy_defeated(target + Vector2(2000, 0))
	_ok(int(quest.get("defeated", 0)) == 0, "在远处刷怪不计数")
	# 就地打死 3 个
	_qm.notify_enemy_defeated(target)
	_qm.notify_enemy_defeated(target)
	_ok(int(quest.get("defeated", 0)) == 2, "打了 2 个记 2 笔（%d）" % int(quest.get("defeated", 0)))
	_qm.notify_enemy_defeated(target)
	_ok(int(quest.get("defeated", 0)) == 3, "打了 3 个记满（%d）" % int(quest.get("defeated", 0)))
	# 记满了再回去，才算「办完」
	_qm.try_complete_at(target)
	_ok(bool(quest.get("reached", false)), "清剿 3 个后任务进入「待复命」")
	# 标签文案
	_qm._set_tracked(quest)
	var label: String = _qm.tracked_label()
	_ok(label.find("清剿") >= 0 or label.find("复命") >= 0, "HUD 文案贴合战斗任务：%s" % label)

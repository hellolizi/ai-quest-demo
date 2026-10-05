extends SceneTree
## 一次性验证工具：坏人（8 族）的 AI 美术数据与提示词。
## 用法：godot --headless --path . --script res://tools/enemy_art_probe.gd
##
## 纯只读：不写任何存档 / 缓存文件，也不会发起真实生图请求。

var _ed                       # EnemyData
var _pg                       # PortraitGenerator
var _wg                       # WalkSheetGenerator
var _ag                       # AttackSheetGenerator
var _pl                       # PortraitLibrary
var _cs                       # character_sprite.gd
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
	_ed = root.get_node_or_null("EnemyData")
	_pg = root.get_node_or_null("PortraitGenerator")
	_wg = root.get_node_or_null("WalkSheetGenerator")
	_ag = root.get_node_or_null("AttackSheetGenerator")
	_pl = root.get_node_or_null("PortraitLibrary")
	if _ed == null or _pg == null or _wg == null or _ag == null or _pl == null:
		push_error("[probe] 缺少 autoload（EnemyData/PortraitGenerator/WalkSheet/AttackSheet/PortraitLibrary）")
		quit(1)
		return
	_cs = load("res://scripts/character_sprite.gd")
	if _cs == null:
		push_error("[probe] 加载 character_sprite.gd 失败")
		quit(1)
		return

	var rids: Array = _ed.race_ids()

	print("== 1. 8 族各有长相描述 / 外观 token / 展示名 ==")
	_ok(rids.size() == 8, "种族共 8 个（实际 %d）" % rids.size())
	for rid in rids:
		var s := str(rid)
		var look: String = _ed.look_cn(s)
		var app: Dictionary = _ed.appearance_for(s)
		var nm: String = _ed.display_name(s)
		_ok(look.strip_edges() != "", "%s 有长相描述" % s)
		_ok(app.size() == 6, "%s 外观 token 完整（6 项，实际 %d）" % [s, app.size()])
		_ok(nm.strip_edges() != "", "%s 有展示名（%s）" % [s, nm])
		var tokens: Dictionary = _ed.race(s).get("tokens", {})
		var same := true
		for k in tokens.keys():
			if str(app.get(k, "")) != str(tokens[k]):
				same = false
		_ok(same, "%s token 都是合法值（sanitize 没有替换）" % s)

	print("== 2. 每族 tag 稳定、互不相同 ==")
	var tags: Dictionary = {}
	var all_unique := true
	for rid in rids:
		var s := str(rid)
		var app: Dictionary = _ed.appearance_for(s)
		var nm: String = _ed.display_name(s)
		var t1: String = _pl.tag_for(nm, "", app)
		var t2: String = _pl.tag_for(nm, "", app.duplicate(true))
		_ok(t1 == t2, "%s tag 可复现（%s）" % [s, t1])
		if tags.has(t1):
			all_unique = false
		tags[t1] = s
	_ok(all_unique and tags.size() == 8, "8 族 tag 互不相同（%d 个）" % tags.size())

	print("== 3. 立绘提示词带上该族的长相 ==")
	var rid0 := str(rids[0])
	var look0: String = _ed.look_cn(rid0)
	var app0: Dictionary = _ed.appearance_for(rid0)
	var nm0: String = _ed.display_name(rid0)
	var p_prompt: String = _pg._build_prompt({
		"name": nm0, "role": str(_ed.race(rid0).get("species", "")),
		"culture": "", "tier": "", "look": look0, "appearance": app0,
	})
	_ok(p_prompt.contains(look0), "立绘提示词含 look 原文")
	_ok(p_prompt.contains(nm0), "立绘提示词含展示名")

	print("== 4. 走路提示词带上该族的长相 ==")
	var w_prompt: String = _wg._build_sheet_prompt({
		"name": nm0, "role": "", "culture": "", "tag": "",
		"look": look0, "appearance": app0,
	})
	_ok(w_prompt.contains(look0), "走路提示词含 look 原文")

	print("== 5. 攻击提示词：按武器替换「短剑」 ==")
	var wp: String = _ed.weapon_cn("长矛")
	_ok(wp == "长矛", "weapon_cn 透传（%s）" % wp)
	_ok(_ed.weapon_cn("") == "短剑", "weapon_cn 缺省为短剑")
	var a_prompt: String = _ag._build_sheet_prompt({
		"name": nm0, "role": "", "culture": "", "tag": "",
		"look": look0, "weapon_cn": wp, "appearance": app0,
	})
	_ok(a_prompt.contains("长矛"), "攻击提示词含指定兵器（长矛）")
	_ok(not a_prompt.contains("短剑"), "攻击提示词不再出现默认短剑")
	var a_default: String = _ag._build_sheet_prompt({
		"name": "玩家", "role": "主角", "culture": "", "tag": "",
		"look": "", "weapon_cn": "", "appearance": app0,
	})
	_ok(a_default.contains("短剑"), "不传武器时仍用短剑（NPC / 主角路径不变）")

	print("== 6. 每族武器名都能算出来 ==")
	for rid in rids:
		var ws: Array = _ed.race(str(rid)).get("weapons", [])
		var ok := ws.size() > 0
		for w in ws:
			if _ed.weapon_cn(str(w)).strip_edges() == "":
				ok = false
		_ok(ok, "%s 的武器池都能取到中文名" % rid)

	print("== 7. enemy.gd 运行时：守兵挂上 AI 美术、野物不变 ==")
	## 关掉三个生成器，免得探针真的去发网络请求
	_pg.mode = "off"
	_wg.mode = "off"
	_ag.mode = "off"
	var enemy_script = load("res://scripts/enemy.gd")
	if enemy_script == null:
		_fail += 1
		print("  [FAIL] 加载 enemy.gd 失败")
	else:
		var guard = enemy_script.new()
		guard.setup(30, {}, "bandit", "长剑", 5)
		root.add_child(guard)
		await process_frame
		_ok(str(guard.get("_art_tag")) != "", "守兵算出了美术 tag（%s）" % str(guard.get("_art_tag")))
		_ok(guard.get("_sprite") != null, "守兵挂了 CharacterSprite")
		_ok(guard.get("_look_root") != null and bool(guard.get("_look_root").visible),
			"磁盘上还没有图 → 先显示程序化外观")
		_ok(guard.get("_sprite") != null and not bool(guard.get("_sprite").visible),
			"还没有图 → AI 精灵先隐藏")
		_ok(str(guard.get("_art_tag")) == _pl.tag_for(
			_ed.display_name("bandit"), "", _ed.appearance_for("bandit")),
			"运行时 tag 与数据推导一致")
		guard.queue_free()

		var beast = enemy_script.new()
		beast.setup(20, {}, "", "", 0)
		root.add_child(beast)
		await process_frame
		_ok(beast.get("_art_tag") == "" and beast.get("_sprite") == null,
			"野物（race_id 为空）不请求 AI 图，仍用原外观")
		beast.queue_free()

	print("")
	if _fail == 0:
		print("[enemy_art_probe] 全部通过")
	else:
		print("[enemy_art_probe] 失败 %d 项" % _fail)
	quit(_fail)

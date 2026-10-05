extends SceneTree
## 一次性验证工具：通天福地（独家文化圈 / 独家地点 / 住客 / 全链路，只读，不发网络请求）
## 用法：godot --headless --path . --script res://tools/tianfu_probe.gd

var _cd                      # CultureData
var _wd                      # WorldData
var _lg                      # LocationGenerator
var _ng                      # NpcGenerator
var _cs                      # CharacterSprite（脚本，非 autoload）
var _ws                      # WorldState
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
	_cd = root.get_node_or_null("CultureData")
	_wd = root.get_node_or_null("WorldData")
	_lg = root.get_node_or_null("LocationGenerator")
	_ng = root.get_node_or_null("NpcGenerator")
	if _cd == null or _wd == null or _lg == null or _ng == null:
		_log("[probe] 缺少必要 autoload")
		quit(1)
		return
	# 全程离线：别让生成器去联网
	_lg.mode = "mock"
	_ng.mode = "mock"
	_cs = load("res://scripts/character_sprite.gd")
	_ws = root.get_node_or_null("WorldState")

	_section_culture()
	_section_location()
	_section_render()
	_section_residents()
	_section_chest()
	_section_persist()

	if _fail == 0:
		_log("== 全部通过 ==")
		quit(0)
	else:
		_log("== 失败 %d 项 ==" % _fail)
		quit(1)


func _section_culture() -> void:
	_log("== 1. 文化圈登记 ==")
	_ok(_cd.exists("tianfu"), "CultureData 里有 tianfu 文化圈")
	_ok(not _cd.all_ids().has("tianfu"), "all_ids() 排除 tianfu（不参与随机出生 / 区域分配）")
	var c: Dictionary = _cd.get_culture("tianfu")
	_ok(str(c.get("name", "")) == "通天福地", "名字是「通天福地」")
	_ok(str(c.get("language", "")) == "", "无语言隔阂（language 为空）")
	_ok((c.get("npcs", []) as Array).size() == 5, "手写住客 5 位（实际 %d）" % (c.get("npcs", []) as Array).size())
	# 五位住客字段齐全
	var bad := ""
	for npc in (c.get("npcs", []) as Array):
		for key in ["name", "role", "personality", "greetings", "offset"]:
			if not (npc as Dictionary).has(key):
				bad = "%s 缺 %s" % [str((npc as Dictionary).get("name", "?")), key]
	_ok(bad == "", "住客字段齐全%s" % ("" if bad == "" else "，异常：%s" % bad))


func _section_location() -> void:
	_log("== 2. 地点类型 + 独家落地 ==")
	_ok(_wd.ALLOWED_KINDS.has("tianfu"), "WorldData 允许 tianfu 类型")
	var loc1: Dictionary = _lg.ensure_tianfu()
	_ok(not loc1.is_empty(), "ensure_tianfu() 建出了福地")
	_ok(str(loc1.get("id", "")) == _lg.TIANFU_ID, "id 固定为 %s" % _lg.TIANFU_ID)
	_ok(str(loc1.get("kind", "")) == "tianfu", "kind 是 tianfu")
	_ok(str(loc1.get("name", "")) == "通天福地", "名字是通天福地")
	# 再调一次不能造出第二个
	var loc2: Dictionary = _lg.ensure_tianfu()
	_ok(str(loc2.get("id", "")) == str(loc1.get("id", "")), "重复调用返回同一个福地")
	var count := 0
	for loc in _wd.LOCATIONS:
		if str(loc.get("kind", "")) == "tianfu":
			count += 1
	_ok(count == 1, "全世界只有一处通天福地（实际 %d）" % count)
	# 位置要离出生点够远（福地是「找到」的，不该在门口）
	var origin: Vector2 = _wd.by_id("village")["pos"] if not _wd.by_id("village").is_empty() else Vector2.ZERO
	var d: float = (loc1["pos"] as Vector2).distance_to(origin)
	_ok(d >= _lg.TIANFU_MIN_DIST - 1.0, "福地离出生点 >= %.0f（实际 %.0f）" % [_lg.TIANFU_MIN_DIST, d])


func _section_render() -> void:
	_log("== 3. 绘制分支 ==")
	var WM := load("res://scripts/world_map.gd")
	var wm = WM.new()   # 故意不进场景树，避免触发真实生图
	var pal: Dictionary = _cd.palette_of("tianfu")
	var before: int = wm.get_child_count()
	wm._build_tianfu({"id": "tianfu_landmark", "name": "通天福地"}, Vector2(60000, -60000), pal)
	var after: int = wm.get_child_count()
	_ok(after > before, "福地建出了一批节点（%d → %d）" % [before, after])
	# _disc 顶点数正确
	_ok(wm._disc(10.0, 8).size() == 8, "_disc 生成 8 边形")
	wm.free()


func _section_residents() -> void:
	_log("== 4. 住客入场 ==")
	var before: int = _ng.dynamic_npcs.size()
	var loc: Dictionary = _wd.by_id(_lg.TIANFU_ID)
	var c: Dictionary = _cd.get_culture("tianfu")
	var seen_names := {}
	for raw in (c.get("npcs", []) as Array):
		var entry: Dictionary = (raw as Dictionary).duplicate(true)
		entry["home_id"] = str(loc.get("id", ""))
		entry["home_name"] = str(loc.get("name", ""))
		entry["culture"] = "tianfu"
		_ng.register_authored(entry)
		seen_names[str(entry["name"])] = true
	var added: int = _ng.dynamic_npcs.size() - before
	_ok(added == 5, "登记了 5 位住客（实际 %d）" % added)
	# 名字不重复、且都在 dynamic_npcs 里
	var names := {}
	var dup := ""
	for npc in _ng.dynamic_npcs:
		var n := str(npc.get("name", ""))
		if names.has(n):
			dup = n
		names[n] = true
	_ok(dup == "", "住客不重名%s" % ("" if dup == "" else "，重复：%s" % dup))
	# 外观：福地住客一律 slim 身段
	var non_slim := ""
	for npc in _ng.dynamic_npcs:
		if str(npc.get("culture", "")) != "tianfu":
			continue
		var app: Dictionary = npc.get("appearance", {})
		if str(app.get("build", "")) != "slim":
			non_slim = str(npc.get("name", ""))
	_ok(non_slim == "", "福地住客都是 slim 身段%s" % ("" if non_slim == "" else "，异常：%s" % non_slim))
	# 再登记一次同名不该重复
	_ng.register_authored({"name": "花魁 云绯", "role": "x", "personality": "y", "greetings": ["z"], "culture": "tianfu"})
	_ok(_ng.dynamic_npcs.size() == before + 5, "重名住客被拒，不重复登记")


## 福地宝箱：摆得出、id 唯一、按一次 E 只发一次、开过的箱子重建后仍是空的
func _section_chest() -> void:
	_log("== 5. 宝箱开采 ==")
	var WM := load("res://scripts/world_map.gd")
	var wm = WM.new()
	var pal: Dictionary = _cd.palette_of("tianfu")
	wm._build_tianfu({"id": "tianfu_landmark", "name": "通天福地"}, Vector2(80000, 80000), pal)
	var chests: Array = []
	for child in wm.get_children():
		for sub in child.get_children():
			if sub is Area2D:
				chests.append(sub)
	_ok(chests.size() == 4, "福地摆出 4 口可开采的宝箱（实际 %d）" % chests.size())
	var ids := {}
	var dup := ""
	for c in chests:
		var id := str((c.info as Dictionary).get("id", ""))
		if ids.has(id):
			dup = id
		ids[id] = true
	_ok(dup == "", "宝箱 id 唯一%s" % ("" if dup == "" else "，重复：%s" % dup))
	wm.free()

	# 交互：按一次 E 发 opened，再按不再发（一口箱子只能开一次）
	var Chest := load("res://scripts/treasure_chest.gd")
	var chest = Chest.new()
	chest.setup({"id": "probe_box", "pos": Vector2.ZERO, "name": "试箱"})
	root.add_child(chest)
	var hits: Array = []
	chest.opened.connect(func(info): hits.append(info))
	chest._player_in_range = true
	var ev := InputEventKey.new()
	ev.keycode = KEY_E
	ev.pressed = true
	chest._unhandled_input(ev)
	chest._unhandled_input(ev)
	_ok(hits.size() == 1, "一口箱子只发一次 opened（实际 %d）" % hits.size())
	_ok(not hits.is_empty() and str((hits[0] as Dictionary).get("id", "")) == "probe_box", "opened 带回箱子身份")
	chest.queue_free()

	# 记账后再建同一口箱子：应直接是「已开启」，且开不了第二次
	_ws.set_flag("tianfu_chest_probe_box", true)
	var again = Chest.new()
	again.setup({"id": "probe_box", "pos": Vector2.ZERO, "name": "试箱"})
	root.add_child(again)
	_ok(again._opened, "读 WorldState 记账：开过的箱子重建后仍是已开启")
	var more: Array = []
	again.opened.connect(func(info): more.append(info))
	again._player_in_range = true
	again._unhandled_input(ev)
	_ok(more.is_empty(), "已开启的箱子按 E 不再发奖")
	again.queue_free()
	_ws.set_flag("tianfu_chest_probe_box", false)


func _section_persist() -> void:
	_log("== 6. 存档往返 ==")
	var snap: Dictionary = _ng.to_save()
	var kept: int = _ng.dynamic_npcs.size()
	_ng.from_save(snap)
	_ok(_ng.dynamic_npcs.size() == kept, "读档后住客数量不变（%d）" % _ng.dynamic_npcs.size())
	var tianfu_kept := 0
	for npc in _ng.dynamic_npcs:
		if str(npc.get("culture", "")) == "tianfu":
			tianfu_kept += 1
	_ok(tianfu_kept == 5, "读档后通天福地住客仍是 5 位（实际 %d）" % tianfu_kept)

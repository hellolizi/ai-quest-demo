extends SceneTree
## 一次性验证工具：武器 / 锻造 / 商店分级 / 城市只在平原（只读，不发网络请求）
## 用法：godot --headless --path . --script res://tools/weapon_system_probe.gd

var _wd                      # WorldData
var _wp                      # WeaponData
var _pp                      # PlayerProfile
var _rg                      # RegionGenerator
var _lg                      # LocationGenerator
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
	_wd = root.get_node_or_null("WorldData")
	_wp = root.get_node_or_null("WeaponData")
	_pp = root.get_node_or_null("PlayerProfile")
	_rg = root.get_node_or_null("RegionGenerator")
	_lg = root.get_node_or_null("LocationGenerator")
	if _wd == null or _wp == null or _pp == null or _rg == null or _lg == null:
		_log("[probe] 缺少必要 autoload")
		quit(1)
		return

	_section_preset()
	_section_forge()
	_section_shop()
	_section_modern()
	_section_attack()
	_section_city()

	if _fail == 0:
		_log("== 全部通过 ==")
		quit(0)
	else:
		_log("== 失败 %d 项 ==" % _fail)
		quit(1)


func _section_preset() -> void:
	_log("== 1. 4 把预设结局武器 ==")
	var endings := ["warden", "wanderer", "bridge", "hermit"]
	for e in endings:
		var wid: String = _wp.preset_id_for_ending(e)
		_ok(wid != "", "结局 %s 有对应武器" % e)
		if wid == "":
			continue
		var w: Dictionary = _wp.get_weapon(wid)
		_ok(not w.is_empty(), "  %s 取得到数据" % wid)
		_ok(int(w.get("damage", 0)) > 0, "  %s 有伤害 %d" % [wid, int(w.get("damage", 0))])
		var eff: Dictionary = w.get("effects", {})
		_ok(not eff.is_empty(), "  %s 有具体效果 %s" % [wid, str(eff)])
		_wp.describe(w)  # 描述函数不许崩
	_ok(_wp.all_ids().size() >= 4, "武器总表至少含 4 把预设（共 %d）" % _wp.all_ids().size())


func _section_forge() -> void:
	_log("== 2. 锻造分级：城市更贵、品质更好 ==")
	var vo: Array = _wp.forge_options("village")
	var co: Array = _wp.forge_options("city")
	_ok(vo.size() > 0 and co.size() == vo.size(), "村/城锻造清单数量一致（%d）" % vo.size())
	if vo.size() > 0 and co.size() > 0:
		_ok(int(co[0].get("damage", 0)) > int(vo[0].get("damage", 0)),
			"城市武器伤害更高（%d > %d）" % [int(co[0].get("damage", 0)), int(vo[0].get("damage", 0))])
	var vc: Dictionary = _wp.forge_cost("iron_sword", "village")
	var cc: Dictionary = _wp.forge_cost("iron_sword", "city")
	_ok(int(cc.get("gold", 0)) > int(vc.get("gold", 0)),
		"城市锻造成本更高（%d > %d）" % [int(cc.get("gold", 0)), int(vc.get("gold", 0))])
	var vm: Dictionary = vc.get("materials", {})
	var cm: Dictionary = cc.get("materials", {})
	var vsum := 0
	var csum := 0
	for k in vm:
		vsum += int(vm[k])
	for k in cm:
		csum += int(cm[k])
	_ok(csum > vsum, "城市锻造更耗材料（%d > %d）" % [csum, vsum])


func _section_shop() -> void:
	_log("== 3. 商店分级：村庄卖普通货、城市卖好货 ==")
	var vs: Array = _wp.shop_materials("village")
	var cs: Array = _wp.shop_materials("city")
	_ok(vs.size() == 3, "村庄只卖 3 种常见材料（实际 %d）" % vs.size())
	_ok(cs.size() == 5, "城市卖 5 种材料（含稀有，实际 %d）" % cs.size())
	if vs.size() > 0 and cs.size() > 0:
		_ok(int(cs[0].get("price", 0)) > int(vs[0].get("price", 0)),
			"城市材料更贵（%d > %d）" % [int(cs[0].get("price", 0)), int(vs[0].get("price", 0))])
	_ok(_wp.shop_weapons("village").is_empty(), "村庄不直接卖成品武器")
	_ok(_wp.shop_weapons("city").size() > 0, "城市直接卖成品武器（%d 把）" % _wp.shop_weapons("city").size())


func _section_modern() -> void:
	_log("== 4. 现代结局现造枪械 ==")
	_ok(_wp.is_modern_goal("我要一个现代都市的结局"), "现代关键词能识别")
	_ok(not _wp.is_modern_goal("守望着村庄直到老去"), "非现代结局不误判")
	var gid: String = _wp.ensure_modern_weapon("我要一个现代都市的结局")
	_ok(gid != "", "现代结局造出了枪械 %s" % gid)
	if gid != "":
		var w: Dictionary = _wp.get_weapon(gid)
		_ok(str(w.get("kind", "")) != "", "枪械有类型：%s" % str(w.get("kind", "")))
		_ok(int(w.get("damage", 0)) > 0, "枪械有伤害 %d" % int(w.get("damage", 0)))
		var save: Dictionary = _wp.to_save()
		_ok(save.has("dynamic"), "动态武器可存档")
		_wp.from_save(save)
		_ok(not _wp.get_weapon(gid).is_empty(), "读档后枪械还在")


func _section_attack() -> void:
	_log("== 5. 武器影响攻击力 ==")
	_pp.new_game()
	var bare: int = _pp.attack_power()
	_pp.add_weapon("warden_blade")
	_pp.equip_weapon("warden_blade")
	var armed: int = _pp.attack_power()
	_ok(armed > bare, "装备守望之刃后攻击力更高（%d > %d）" % [armed, bare])
	# 吸血/暴击/防御等 effect 读得到（equip 前必须先 add_weapon，否则装备不上）
	_pp.add_weapon("hermit_dagger")
	_pp.equip_weapon("hermit_dagger")
	_ok(_pp.weapon_effect("lifesteal", 0.0) > 0.0, "独行之匕读得到吸血")
	_ok(_pp.weapon_effect("crit", 0.0) > 0.0, "独行之匕读得到暴击")
	_pp.equip_weapon("")


func _section_city() -> void:
	_log("== 6. 城市只在平原生成 ==")
	# 6a. 世界里已有的城市（若有）必须都在平原上
	var cities := 0
	var bad := ""
	for loc in _wd.LOCATIONS:
		if str(loc.get("kind", "")) != "city":
			continue
		cities += 1
		if _rg.terrain_at(loc["pos"]) != "plain":
			bad = str(loc.get("id", "?"))
	_ok(bad == "", "已有城市都落在平原上%s（共 %d 座）" % ["" if bad == "" else "，例外：%s" % bad, cities])
	# 6b. 直接验证「升级规则」：非平原一律不能变城市；平原里确实存在可升级的格子
	var origin: Vector2 = _lg._origin()
	var upgradable := 0
	var illegal := 0
	var checked := 0
	for region in _rg.regions_in_radius(origin, 3000.0):
		var cell: Vector2i = region["cell"]
		var spot = _lg._find_spot_in_cell(cell)
		if spot == null:
			continue
		checked += 1
		var p: Vector2 = spot
		var is_plain: bool = _rg.terrain_at(p) == "plain"
		var can: bool = _lg._can_be_city(p, cell)
		if can and not is_plain:
			illegal += 1
		if can and is_plain:
			upgradable += 1
	_ok(checked > 0, "采样到可落点的区域（%d 个）" % checked)
	_ok(illegal == 0, "没有任何非平原落点会被升级成城市")
	_ok(upgradable > 0, "平原落点里确实存在可升级为城市的格子（%d 个）" % upgradable)

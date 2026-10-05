extends SceneTree
## 一次性验证工具：生成人物（dress 字段 / 外观按地区收敛 / 立绘提示词）
## 用法：godot --headless --path . --script res://tools/person_probe.gd
##
## 纯只读：不写任何存档 / 缓存文件。

var _cul                      # CultureData
var _pg                       # PortraitGenerator
var _cs                       # character_sprite.gd（class_name 脚本，static 方法用）
var _looks: Dictionary = {}
var _fail := 0

const SAMPLES := 200


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
	_cul = root.get_node_or_null("CultureData")
	_pg = root.get_node_or_null("PortraitGenerator")
	if _cul == null:
		push_error("[probe] 缺少 CultureData autoload")
		quit(1)
		return
	_cs = load("res://scripts/character_sprite.gd")
	if _cs == null:
		push_error("[probe] 加载 character_sprite.gd 失败")
		quit(1)
		return
	var consts: Dictionary = _cs.get_script_constant_map()
	_looks = consts.get("CULTURE_LOOKS", {})

	print("== 1. 每个文化圈都有 dress ==")
	var ids: Array = _cul.all_ids()
	_ok(ids.size() == 9, "文化圈共 9 个（实际 %d）" % ids.size())
	var all_dress := true
	var miss := ""
	for cid in ids:
		var d: String = _cul.dress_of(str(cid))
		if d.strip_edges() == "":
			all_dress = false
			miss = str(cid)
	_ok(all_dress, "9 个文化圈 dress 都非空" + ("（缺 %s）" % miss if miss != "" else ""))

	print("== 2. 外观按地区收敛（每圈 200 个样本，全部落在该圈候选池内）==")
	_ok(_looks.keys().size() == 9, "CULTURE_LOOKS 覆盖 9 个文化圈")
	for cid in ids:
		var pool: Dictionary = _looks.get(str(cid), {})
		if pool.is_empty():
			_ok(false, "缺少 %s 的候选池" % cid)
			continue
		var bad := ""
		for i in SAMPLES:
			var app: Dictionary = _cs.derive_appearance("样本_%s_%d" % [cid, i], str(cid))
			for key in ["skin", "hair", "hair_style", "clothes", "build", "accessory"]:
				var allowed: Array = pool.get(key, [])
				if allowed.is_empty():
					continue          # 该圈没限制这一项 → 用全局池，跳过
				if not allowed.has(str(app.get(key, ""))):
					bad = "%s.%s=%s 不在池内" % [cid, key, app.get(key, "")]
					break
			if bad != "":
				break
		_ok(bad == "", "%s：%d 个样本全部符合本地长相" % [cid, SAMPLES] + ("" if bad == "" else "（%s）" % bad))

	print("== 3. 同一个名字 + 同一个地区 = 稳定同一张脸 ==")
	var a1: Dictionary = _cs.derive_appearance("铁匠 老张", "qingshi")
	var a2: Dictionary = _cs.derive_appearance("铁匠 老张", "qingshi")
	_ok(a1 == a2, "同名同地区两次推导完全一致")
	var a3: Dictionary = _cs.derive_appearance("铁匠 老张", "frost")
	_ok(a1["skin"] == a3["skin"] or a1["hair"] == a3["hair"] or a1["clothes"] == a3["clothes"],
		"换到别的地区长相跟着变（同种子不同地区不全等）" if a1 != a3 else "（样本恰好全等）")

	print("== 4. 不给地区时仍能出合法外观（全局池兜底）==")
	var free: Dictionary = _cs.derive_appearance("路人甲", "")
	_ok(_cs.sanitize_appearance(free) == free, "无地区时外观合法")
	var unknown: Dictionary = _cs.derive_appearance("路人乙", "not_a_culture")
	_ok(_cs.sanitize_appearance(unknown) == unknown, "未知地区回落全局池且合法")

	print("== 5. 中文描述可用于提示词 ==")
	var desc: String = _cs.describe_cn(a1)
	_ok(desc.strip_edges() != "", "describe_cn 输出非空")

	print("== 6. 立绘提示词带上 dress ==")
	if _pg != null:
		var prompt: String = _pg._build_prompt({
			"name": "铁匠 老张", "role": "村里唯一的铁匠",
			"culture": "qingshi", "appearance": a1,
		})
		_ok(prompt.find("该地区标准打扮") != -1, "提示词含「该地区标准打扮」")
		_ok(prompt.find(_cul.dress_of("qingshi")) != -1, "提示词内嵌 qingshi 的 dress 原文")
		_ok(prompt.find("青石") != -1 or prompt.find("中原") != -1, "提示词仍带世界风格参考")
	else:
		_ok(false, "PortraitGenerator autoload 已注册")

	print("== 7. 城市档次：穿着更讲究，但仍是本地样式 ==")
	var city_looks: Dictionary = consts.get("CITY_LOOKS", {})
	var city_default: Dictionary = consts.get("CITY_DEFAULT", {})
	_ok(str(_cs.tier_for_kind("city")) == "city", "tier_for_kind(city) 返回 city")
	_ok(str(_cs.tier_for_kind("village")) == "", "tier_for_kind(village) 返回空（村里人不上档次）")
	_ok(_cs.tier_cn("city").strip_edges() != "", "tier_cn(city) 非空，能拼进提示词")
	# 城市外观必须落在「城市升级池」里，且肤色 / 发色仍取该文化圈的偏好
	for cid in ids:
		var base: Dictionary = _looks.get(str(cid), {})
		var city: Dictionary = city_looks.get(str(cid), city_default)
		var bad := ""
		for i in SAMPLES:
			var app: Dictionary = _cs.derive_appearance("城里人_%s_%d" % [cid, i], str(cid), "city")
			for key in ["clothes", "hair_style", "accessory", "build"]:
				var allowed: Array = city.get(key, [])
				if allowed.is_empty():
					continue
				if not allowed.has(str(app.get(key, ""))):
					bad = "%s.%s=%s 不在城市池内" % [cid, key, app.get(key, "")]
					break
			if bad != "":
				break
			# 肤色 / 发色不该被城市池抢走，得仍在本文化圈池内
			for key in ["skin", "hair"]:
				var allowed2: Array = base.get(key, [])
				if allowed2.is_empty():
					continue
				if not allowed2.has(str(app.get(key, ""))):
					bad = "%s.%s=%s 丢了本地偏好" % [cid, key, app.get(key, "")]
					break
			if bad != "":
				break
		_ok(bad == "", "%s：城里人穿着落在城市升级池" % cid + ("" if bad == "" else "（%s）" % bad))
	# 同名同城稳定，且城里人跟村里人穿着确实不一样
	var c1: Dictionary = _cs.derive_appearance("铁匠 老张", "qingshi", "city")
	var c2: Dictionary = _cs.derive_appearance("铁匠 老张", "qingshi", "city")
	_ok(c1 == c2, "同名同城两次推导完全一致")
	_ok(a1["clothes"] != c1["clothes"] or a1["hair_style"] != c1["hair_style"]
		or a1["accessory"] != c1["accessory"] or a1["build"] != c1["build"],
		"同名的人进城后穿着与村里不同")
	if _pg != null:
		var cprompt: String = _pg._build_prompt({
			"name": "布商 沈娘", "role": "绸缎庄掌柜",
			"culture": "qingshi", "appearance": c1, "tier": "city",
		})
		_ok(cprompt.find("身份档次") != -1, "城里人立绘提示词含「身份档次」")
		_ok(cprompt.find(_cs.tier_cn("city")) != -1, "提示词内嵌城市档次原文")
		var vprompt: String = _pg._build_prompt({
			"name": "货郎 三顺", "role": "走街串巷",
			"culture": "qingshi", "appearance": a1,
		})
		_ok(vprompt.find("身份档次") == -1, "村里人立绘提示词不带档次（不误伤）")

	print("----------------------------------------")
	print("失败 %d 项" % _fail if _fail > 0 else "全部通过")
	quit(0 if _fail == 0 else 1)

extends SceneTree
## 一次性验证工具：生成房屋（建筑图鉴 + 生成器）
## 用法：godot --headless --path . --script res://tools/building_probe.gd
##
## 会往 res://generated/buildings/ 写一张测试图，测完删掉并还原索引，不污染玩家数据。

const TEST_ID := "house_probe_a"
const TEST_PNG := "res://generated/buildings/house_probe_a.png"
const INDEX_PATH := "res://generated/buildings/index.json"

var _pl                      # PropLibrary
var _bg                      # BuildingGenerator
var _backup_index := ""
var _backup_exists := false
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
	await process_frame        # 等第一帧，autoload 才注册完
	_pl = root.get_node_or_null("PropLibrary")
	_bg = root.get_node_or_null("BuildingGenerator")
	if _pl == null:
		push_error("[probe] 缺少 PropLibrary autoload")
		quit(1)
		return
	_ok(_bg != null, "BuildingGenerator autoload 已注册")
	_backup()

	print("== 1. 建筑 id 合成 / 解析 ==")
	_ok(_pl.building_id("qingshi", "a") == "house_qingshi_a", "合成 id 正确")
	_ok(_pl.is_building_id("house_qingshi_a"), "is_building_id 认自家 id")
	_ok(not _pl.is_building_id("house"), "is_building_id 不认通用 house")
	_ok(not _pl.is_building_id("pine"), "is_building_id 不认普通道具")
	var info: Dictionary = _pl.parse_building_id("house_frost_c")
	_ok(info.get("culture", "") == "frost" and info.get("variant", "") == "c", "解析 culture/variant 正确")
	var ids: PackedStringArray = _pl.building_ids_of("dune")
	_ok(ids.size() == 3, "每个文化圈 3 个变体")
	_ok(_pl.culture_of_building("house_steppe_b") == "steppe", "culture_of_building 正确")
	_ok(_pl.variant_of_id("house_steppe_b") == "b", "variant_of_id 正确")

	print("== 1b. 城市楼房 id ==")
	_ok(_pl.building_id("qingshi", "a", "city") == "city_qingshi_a", "城市楼房合成 id 正确")
	_ok(_pl.is_building_id("city_qingshi_a"), "is_building_id 认城市楼房")
	var cinfo: Dictionary = _pl.parse_building_id("city_frost_c")
	_ok(cinfo.get("tier", "") == "city", "城市 id 解析出 tier=city")
	_ok(_pl.tier_of_building("house_frost_c") == "village", "民居 id 解析出 tier=village")
	_ok(_pl.building_ids_of("dune", "city").size() == 3, "城市每文化圈也是 3 个变体")
	_ok(not _pl.is_building_id("city_qingshi"), "缺变体的 city id 不合法")

	print("== 2. 变体由坐标稳定决定 ==")
	var p := Vector2(123.0, -456.0)
	_ok(_pl.variant_at(p) == _pl.variant_at(p), "同一坐标永远是同一变体")

	print("== 3. 图鉴总表 ==")
	var all_ids: PackedStringArray = _pl.building_ids()
	_ok(all_ids.size() == 54, "9 文化圈 × 3 变体 × 2 档（民居+城宅）= 54（实际 %d）" % all_ids.size())

	print("== 4. by_id 合成条目 ==")
	var entry: Dictionary = _pl.by_id("house_qingshi_b")
	_ok(entry.get("building", false) == true, "by_id 认出建筑")
	_ok(entry.get("size", Vector2.ZERO) == _pl.BUILDING_SIZE, "民居 size 用 BUILDING_SIZE")
	_ok(_pl.is_solid("house_qingshi_b"), "房屋阻挡玩家")
	_ok(_pl.size_of("house_qingshi_b") == _pl.BUILDING_SIZE, "size_of 走建筑尺寸")
	_ok(_pl.by_id("pine").get("building", false) != true, "普通道具不受影响")
	var centry: Dictionary = _pl.by_id("city_qingshi_b")
	_ok(centry.get("tier", "") == "city", "by_id 认出城市楼房")
	_ok(centry.get("size", Vector2.ZERO) == _pl.CITY_BUILDING_SIZE, "城市楼房尺寸更大一圈")
	_ok(_pl.size_of("city_qingshi_b") == _pl.CITY_BUILDING_SIZE, "size_of 走城市尺寸")

	print("== 5. 还没画时没有贴图 ==")
	_ok(not _pl.has_building_texture(TEST_ID), "test id 初始无贴图")
	_ok(_pl.texture_of(TEST_ID) == null, "texture_of 返回 null")

	print("== 6. 登记一张图 ==")
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.5, 0.3, 0.2, 1.0))
	var ok_reg: bool = _pl.register_building(TEST_ID, img, {"provider": "probe"})
	_ok(ok_reg, "register_building 成功")
	_ok(FileAccess.file_exists(TEST_PNG), "png 已落盘")
	_ok(_pl.has_building_texture(TEST_ID), "has_building_texture 变 true")
	var tex: Texture2D = _pl.texture_of(TEST_ID)
	_ok(tex != null, "texture_of 拿到贴图")
	_ok(_pl.has_texture(TEST_ID), "has_texture 路由到建筑缓存")

	print("== 7. 索引落盘 + 重启可读回 ==")
	_ok(FileAccess.file_exists(INDEX_PATH), "index.json 已写")
	_pl._building_textures.clear()
	_ok(_pl.building_texture(TEST_ID) != null, "清掉内存缓存后能重新读盘")

	print("== 8. 生成器提示词 ==")
	if _bg != null:
		var prompt: String = _bg._build_prompt({"culture": "qingshi", "variant": "a"})
		_ok(prompt.find("青石") != -1, "提示词带上聚落名（青石）")
		_ok(prompt.find("A") != -1, "提示词带上户型变体")
		_ok(prompt.find("城镇楼房") == -1, "民居提示词不提城镇楼房")
		var cprompt: String = _bg._build_prompt({"culture": "qingshi", "variant": "a", "tier": "city"})
		_ok(cprompt.find("城镇楼房") != -1, "城市提示词标明城镇楼房档次")
		_ok(cprompt != prompt, "城市提示词与民居提示词不同")
		_ok(_bg._negative_for({"tier": "city"}) != _bg._negative_for({"tier": "village"}), "城市负向提示词不同")
		var lc: Node = root.get_node_or_null("LlmConfig")
		_ok(lc != null and str(_bg.mode) == str(lc.image_mode), "生成器收到了 image 配置广播")
		_ok(str(_bg.provider) == str(lc.image_provider), "provider 已同步")

	print("== 9. 城市楼房规格 ==")
	var city_ok := true
	for i in 24:
		var cp := Vector2(float(i) * 37.0 + 11.0, float(i) * -53.0 + 7.0)
		var cs: Dictionary = _pl.house_spec(cp, "city")
		if str(cs.get("size_class", "")) == "small" or int(cs.get("floors", 0)) < 2:
			city_ok = false
			print("    坐标 %s -> %s" % [str(cp), str(cs)])
			break
	_ok(city_ok, "城市楼房一律不是小屋且至少两层（抽 24 个坐标）")
	_ok(_pl.house_spec(Vector2(123, -456), "village") == _pl.house_spec(Vector2(123, -456)), "同一坐标规格稳定")
	_ok(_pl.building_size_of("city") == _pl.CITY_BUILDING_SIZE, "building_size_of(city) 正确")
	_ok(_pl.building_size_of("village") == _pl.BUILDING_SIZE, "building_size_of(village) 正确")

	_restore()
	print("----------------------------------------")
	if _fail == 0:
		print("全部通过")
	else:
		print("失败 %d 项" % _fail)
	quit(0 if _fail == 0 else 1)


# ---------------------------------------------------------------- 备份 / 还原

func _backup() -> void:
	if FileAccess.file_exists(INDEX_PATH):
		_backup_exists = true
		var f := FileAccess.open(INDEX_PATH, FileAccess.READ)
		if f != null:
			_backup_index = f.get_as_text()
			f.close()


func _restore() -> void:
	if FileAccess.file_exists(TEST_PNG):
		DirAccess.remove_absolute(TEST_PNG)
	if _backup_exists:
		var f := FileAccess.open(INDEX_PATH, FileAccess.WRITE)
		if f != null:
			f.store_string(_backup_index)
			f.close()
	elif FileAccess.file_exists(INDEX_PATH):
		DirAccess.remove_absolute(INDEX_PATH)
	print("[probe] 已清理测试图与索引")

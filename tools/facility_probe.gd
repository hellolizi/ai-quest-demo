extends SceneTree
## 一次性验证工具：功能性建筑（锻造台 / 商铺 / 客栈 / 藏书阁 / 拍卖行 /
## 告示板 / 药铺 / 马厩 / 赌坊）的规模分级、村城分层命名、落位与界面行布局。
## 只读，不发网络请求。
## 用法：godot --headless --path . --script res://tools/facility_probe.gd
##
## 说明：world_map 是「不进场景树」直接数设施节点的，所以日志里出现的
## "get_node() with absolute paths from outside the active scene tree"
## 只是这种离线数法的副产品（_house 里的 has_node("/root/BuildingGenerator")），不是游戏 bug。

var _cd                      # CultureData
var _wd                      # WorldData
var _wp                      # WeaponData
var _pp                      # PlayerProfile
var _nm                      # NpcMemory
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
	_cd = root.get_node_or_null("CultureData")
	_wd = root.get_node_or_null("WorldData")
	_wp = root.get_node_or_null("WeaponData")
	_pp = root.get_node_or_null("PlayerProfile")
	_nm = root.get_node_or_null("NpcMemory")
	if _cd == null or _wd == null or _wp == null or _pp == null or _nm == null:
		_log("[probe] 缺少必要 autoload")
		quit(1)
		return

	await _section_tables()
	_section_naming()
	_section_scale()
	_section_placement()
	_section_board()
	await _section_ui()

	if _fail == 0:
		_log("== 全部通过 ==")
		quit(0)
	else:
		_log("== 失败 %d 项 ==" % _fail)
		quit(1)


# ---------------------------------------------------------------- 0. 静态表
#
# 规模表、落位表、命名表是「配置」，先做自洽性检查：
# 规模越大种类只增不减、每种只出现一次、每个 kind 都有落位和名字。

func _section_tables() -> void:
	_log("== 0. 配置表自洽 ==")
	await process_frame
	var wm = load("res://scripts/world_map.gd").new()
	var by_scale: Dictionary = wm.FACILITY_BY_SCALE
	var v_layout: Dictionary = wm.FACILITY_VILLAGE_LAYOUT
	var c_layout: Dictionary = wm.FACILITY_CITY_LAYOUT
	var names: Dictionary = wm.FACILITY_NAMES

	_ok(by_scale.has(1) and by_scale.has(2) and by_scale.has(3), "规模表覆盖 1/2/3 三档")

	# 只增不减（子集关系）且每档内部无重复
	var subset12 := _is_subset(by_scale[1], by_scale[2])
	var subset23 := _is_subset(by_scale[2], by_scale[3])
	_ok(subset12, "规模 1 的种类 ⊆ 规模 2")
	_ok(subset23, "规模 2 的种类 ⊆ 规模 3")
	_ok(_no_dup(by_scale[1]) and _no_dup(by_scale[2]) and _no_dup(by_scale[3]),
		"每档内 kinds 无重复（每种建筑每聚落最多 1 座）")
	_ok((by_scale[3] as Array).size() == 9, "规模 3 共 9 种：%s" % str(by_scale[3]))

	# 9 种建筑在村庄 / 城市两套落位里都要有位置，且都要有名字
	var all_kinds: Array = by_scale[3]
	var layout_ok := true
	var name_ok := true
	for k in all_kinds:
		if not v_layout.has(k) or not c_layout.has(k):
			layout_ok = false
		if not names.has(k):
			name_ok = false
	_ok(layout_ok, "村庄 / 城市两套落位覆盖全部 9 种")
	_ok(name_ok, "命名表覆盖全部 9 种")

	var city_names: Dictionary = wm.FACILITY_CITY_NAMES
	var city_subset := true
	for k in city_names.keys():
		if not names.has(k):
			city_subset = false
	_ok(city_subset, "城市别名都是已知的 kind")
	_ok(city_names.size() == 4, "4 种建筑有城市别名（告示板/药铺/马厩/赌坊）")

	wm.free()


# ---------------------------------------------------------------- 1. 村城分层命名

func _section_naming() -> void:
	_log("== 1. 村城分层命名 ==")
	var wm = load("res://scripts/world_map.gd").new()
	_ok(wm._facility_name("forge", "village") == "锻造台", "村庄锻造台")
	_ok(wm._facility_name("forge", "city") == "锻造台", "城市锻造台（无别名时沿用）")
	_ok(wm._facility_name("board", "village") == "告示板", "村庄：告示板")
	_ok(wm._facility_name("board", "city") == "任务榜", "城市：告示板 → 任务榜")
	_ok(wm._facility_name("clinic", "village") == "药铺", "村庄：药铺")
	_ok(wm._facility_name("clinic", "city") == "医馆", "城市：药铺 → 医馆")
	_ok(wm._facility_name("stable", "village") == "马厩", "村庄：马厩")
	_ok(wm._facility_name("stable", "city") == "驿站", "城市：马厩 → 驿站")
	_ok(wm._facility_name("arena", "village") == "赌坊", "村庄：赌坊")
	_ok(wm._facility_name("arena", "city") == "竞技场", "城市：赌坊 → 竞技场")
	wm.free()


# ---------------------------------------------------------------- 2. 规模判定

func _section_scale() -> void:
	_log("== 2. 聚落规模 ==")
	var wm = load("res://scripts/world_map.gd").new()
	_ok(wm._settlement_scale({"id": "city_x"}, "city") == 3, "城市规模 = 3")
	_ok(wm._settlement_scale({"id": "village"}, "village") == 2, "母村规模 = 2")
	# 同一个 id 两次结果必须一致（存读档后不能变样）
	_ok(wm._settlement_scale({"id": "foo_bar"}, "village") == wm._settlement_scale({"id": "foo_bar"}, "village"),
		"同一村庄规模稳定")
	# 村庄规模落在 1~3
	var found := {}
	var bad := false
	for i in range(1, 200):
		var sid := "probe_v_%d" % i
		var s: int = wm._settlement_scale({"id": sid}, "village")
		if s < 1 or s > 3:
			bad = true
		found[s] = true
	_ok(not bad, "所有村庄规模都在 1~3")
	_ok(found.has(1) and found.has(2) and found.has(3),
		"村庄规模能取到 1/2/3（小村到大村都有）：%s" % str(found.keys()))
	wm.free()


# ---------------------------------------------------------------- 3. 落位

func _section_placement() -> void:
	_log("== 3. 设施落位（村 / 城 / 小村） ==")
	var wm_script = load("res://scripts/world_map.gd")
	var cid: String = _cd.current_id

	# 3a. 母村（规模 2）：6 种
	var v = wm_script.new()
	v._build_village({"id": "village", "name": "青石村"}, Vector2(900000.0, 900000.0), cid)
	var village := _count_facilities(v)
	_log("  母村设施：%s" % str(village))
	_ok(int(village.get("forge", 0)) == 1 and int(village.get("shop", 0)) == 1, "母村有锻造台 + 商铺")
	_ok(int(village.get("inn", 0)) == 1 and int(village.get("library", 0)) == 1, "母村有客栈 + 藏书阁")
	_ok(int(village.get("board", 0)) == 1 and int(village.get("clinic", 0)) == 1, "母村有告示板 + 药铺")
	_ok(int(village.get("auction", 0)) == 0, "母村没有拍卖行（那是城市货）")
	_ok(int(village.get("stable", 0)) == 0 and int(village.get("arena", 0)) == 0, "母村没有马厩 / 赌坊")
	var total_v := 0
	for k in village.keys():
		total_v += int(village[k])
	_ok(total_v == 6, "母村共 6 座设施（实际 %d）" % total_v)
	v.free()

	# 3b. 城市（规模 3）：9 种齐全
	var c = wm_script.new()
	c._build_city({"id": "probe_city", "kind": "city", "name": "青石城"}, Vector2(-900000.0, -900000.0), cid)
	var city := _count_facilities(c)
	_log("  城市设施：%s" % str(city))
	var all_ok := true
	for k in ["forge", "shop", "inn", "library", "auction", "board", "clinic", "stable", "arena"]:
		if int(city.get(k, 0)) != 1:
			all_ok = false
	_ok(all_ok, "城市 9 种设施各 1 座")
	var total_c := 0
	for k in city.keys():
		total_c += int(city[k])
	_ok(total_c == 9, "城市共 9 座设施（实际 %d）" % total_c)
	c.free()

	# 3c. 最小的村庄（规模 1）：只有 2 种
	var small_id := _find_scale(wm_script, 1)
	var s = wm_script.new()
	s._build_village({"id": small_id, "name": "小村"}, Vector2(0.0, 900000.0), cid)
	var small := _count_facilities(s)
	_log("  小村（%s）设施：%s" % [small_id, str(small)])
	var small_total := 0
	for k in small.keys():
		small_total += int(small[k])
	_ok(int(small.get("forge", 0)) == 1 and int(small.get("shop", 0)) == 1, "小村有锻造台 + 商铺")
	_ok(small_total == 2, "小村只有 2 座设施（实际 %d）" % small_total)
	s.free()

	# 3d. 大村庄（规模 3）：9 种齐全，且是村庄版本（用村庄落位）
	var big_id := _find_scale(wm_script, 3)
	var b = wm_script.new()
	b._build_village({"id": big_id, "name": "大村"}, Vector2(0.0, -900000.0), cid)
	var big := _count_facilities(b)
	_log("  大村（%s）设施：%s" % [big_id, str(big)])
	var big_all := true
	for k in ["forge", "shop", "inn", "library", "auction", "board", "clinic", "stable", "arena"]:
		if int(big.get(k, 0)) != 1:
			big_all = false
	_ok(big_all, "规模 3 的村庄也能凑齐 9 种（村庄版外观不会成为死代码）")
	b.free()


# ---------------------------------------------------------------- 4. 告示板身份

func _section_board() -> void:
	_log("== 4. 告示板：委托发布人身份 ==")
	var wm = load("res://scripts/world_map.gd").new()
	wm._build_city({"id": "probe_city", "kind": "city", "name": "青石城"}, Vector2(500000.0, 500000.0), _cd.current_id)
	var board = null
	for n in wm.find_children("Facility", "Area2D", true, false):
		if str(n.get("kind")) == "board":
			board = n
			break
	_ok(board != null, "城市里找得到告示板")
	if board != null:
		var info: Dictionary = board.get("info")
		var want := "青石城任务榜"
		_ok(str(info.get("board_owner", "")) == want, "board_owner = 聚落名 + 城市别名（%s）" % str(info.get("board_owner", "")))
		_ok(str(info.get("settlement_id", "")) == "probe_city", "info.settlement_id 写对了")
		_ok(typeof(info.get("pos", null)) == TYPE_VECTOR2, "info.pos 是个坐标")
		_ok(_nm.position_of(want) != null, "委托发布人已在 NpcMemory 登记位置")
	wm.free()


# ---------------------------------------------------------------- 5. 界面行布局 + 车马钱

func _section_ui() -> void:
	_log("== 5. 界面：行布局不重叠 + 车马钱 ==")
	var script = load("res://scripts/facility_ui.gd")
	_ok(script != null, "facility_ui.gd 能加载（编译通过）")
	if script == null:
		return
	var ui = script.new()

	# 5a. 车马钱：底价 10、封顶 120、线性
	_ok(ui._travel_price(0.0) == 10, "车马钱底价 = 10")
	_ok(ui._travel_price(240.0) == 11, "每 240 像素 +1（240 → 11）")
	_ok(ui._travel_price(999999.0) == 120, "车马钱封顶 = 120")

	# 5b. 驿站四通八达 / 马厩只回本乡
	var city_dests: Array = ui._travel_destinations("city", "probe_from")
	var city_ok := true
	for loc in city_dests:
		var k := str(loc.get("kind", ""))
		if k != "village" and k != "city":
			city_ok = false
	_ok(city_ok and city_dests.size() > 0, "驿站只列村庄 / 城市（%d 个去处）" % city_dests.size())
	var village_dests: Array = ui._travel_destinations("village", "probe_from")
	var only_home := true
	for loc in village_dests:
		if str(loc.get("id", "")) != "village":
			only_home = false
	_ok(only_home, "马厩只送本乡（%d 个去处）" % village_dests.size())

	# 5c. 行布局：图标 / 文字 / 按钮必须横向错开，不能层层叠满
	var host := VBoxContainer.new()
	host.size = Vector2(700, 200)
	root.add_child(host)
	var row = ui._row_frame()
	_ok(row is HBoxContainer, "_row_frame 返回横向容器（不再是会把子节点撑满的 PanelContainer）")
	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(56, 56)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(Label.new())
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(88, 40)
	row.add_child(icon)
	row.add_child(box)
	row.add_child(btn)
	host.add_child(row)
	for _i in 4:
		await process_frame
	_log("  row=%s icon=%s box=%s btn=%s" % [
		str(row.size), str(icon.position), str(box.position), str(btn.position)])
	_ok(icon.position.x < box.position.x and box.position.x < btn.position.x,
		"顺序：图标 → 文字 → 按钮（x 递增）")
	_ok(icon.size.y <= 60, "图标没被拉成整行高（高=%d）" % int(icon.size.y))
	_ok(btn.position.x + btn.size.x <= row.size.x - 5,
		"按钮右侧留出了内边距（按钮右缘 %.0f ≤ 行宽 %.0f - 5）" % [btn.position.x + btn.size.x, row.size.x])

	ui.free()
	host.queue_free()


# ---------------------------------------------------------------- 小工具

func _is_subset(a, b) -> bool:
	var set_b := {}
	for x in b:
		set_b[str(x)] = true
	for x in a:
		if not set_b.has(str(x)):
			return false
	return true


func _no_dup(a) -> bool:
	var seen := {}
	for x in a:
		if seen.has(str(x)):
			return false
		seen[str(x)] = true
	return true


## 找一个规模为 want 的村庄 id（用于「小村 / 大村」用例）
func _find_scale(wm_script, want: int) -> String:
	var probe = wm_script.new()
	for i in range(1, 400):
		var sid := "probe_v_%d" % i
		if int(probe._settlement_scale({"id": sid}, "village")) == want:
			probe.free()
			return sid
	probe.free()
	return "probe_v_1"


## 数一数这棵树里各 kind 的设施各有几座（按脚本认，别把门 / 碰撞体也算进去）
func _count_facilities(root_node: Node) -> Dictionary:
	var out := {}
	var fac_script = load("res://scripts/facility.gd")
	for n in root_node.find_children("*", "Area2D", true, false):
		if n.get_script() != fac_script:
			continue
		var k := str(n.get("kind"))
		out[k] = int(out.get(k, 0)) + 1
	return out

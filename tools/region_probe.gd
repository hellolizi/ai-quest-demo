extends SceneTree
## 一次性验证工具：区域化地点生成（CultureData 去坐标 / WorldData 固定母村 / LocationGenerator 按区域生成）
## 用法：godot --headless --path . --script res://tools/region_probe.gd
##
## 纯只读：只在内存里改 WorldData，不写任何存档 / 缓存文件。

var _cul                      # CultureData
var _wd                       # WorldData
var _rg                       # RegionGenerator
var _lg                       # LocationGenerator
var _dec                      # SceneDecorator
var _fail := 0

const SAMPLES := 30


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
	_wd = root.get_node_or_null("WorldData")
	_rg = root.get_node_or_null("RegionGenerator")
	_lg = root.get_node_or_null("LocationGenerator")
	_dec = root.get_node_or_null("SceneDecorator")
	for n in [_cul, _wd, _rg, _lg]:
		if n == null:
			push_error("[probe] 缺少 autoload 节点")
			quit(1)
			return

	# 纯离线验证：强制 mock，避免真去调大模型接口
	_lg.mode = "mock"
	if _dec != null:
		_dec.mode = "mock"

	var ids: Array = _cul.all_ids()
	_section_home_sites(ids)
	_section_home_layout(ids)
	_section_kinds(ids)
	_section_compose(ids)
	_section_generate()

	print("")
	if _fail == 0:
		print("== 全部通过 ==")
		quit(0)
	else:
		print("== 失败 %d 项 ==" % _fail)
		quit(1)


# ---------------------------------------------------------------- 1. home_sites

func _section_home_sites(ids: Array) -> void:
	print("== 1. 每个文化圈的 home_sites：不带坐标、含 village ==")
	_ok(ids.size() == 9, "文化圈共 9 个（实际 %d）" % ids.size())
	var no_pos := true
	var has_village := true
	var bad := ""
	for cid in ids:
		var sites: Array = _cul.home_sites(str(cid))
		if sites.is_empty():
			no_pos = false
			bad = "%s 空" % cid
			continue
		var found_v := false
		for s in sites:
			if (s as Dictionary).has("pos"):
				no_pos = false
				bad = "%s 仍带 pos" % cid
			if str((s as Dictionary).get("kind", "")) == "village":
				found_v = true
		if not found_v:
			has_village = false
			bad = "%s 缺 village" % cid
	_ok(no_pos, "9 个文化圈 home_sites 都已去掉写死坐标" + ("（%s）" % bad if bad != "" else ""))
	_ok(has_village, "9 个文化圈 home_sites 都含一个 village")


# ---------------------------------------------------------------- 2. HOME_LAYOUT

func _section_home_layout(ids: Array) -> void:
	print("== 2. WorldData.HOME_LAYOUT：母村固定在原点，9 个文化圈都能重建 ==")
	var layout: Dictionary = _wd.HOME_LAYOUT
	var cover := true
	var miss := ""
	for cid in ids:
		for s in _cul.home_sites(str(cid)):
			var sid := str((s as Dictionary).get("id", ""))
			if not layout.has(sid):
				cover = false
				miss = sid
	_ok(cover, "HOME_LAYOUT 覆盖所有地标 id" + ("（缺 %s）" % miss if miss != "" else ""))

	var all_ok := true
	for cid in ids:
		_wd.set_culture(str(cid))
		var v: Dictionary = _wd.by_id(_cul.HOME_ID)
		if v.is_empty():
			all_ok = false
			continue
		var vpos: Vector2 = v["pos"]
		if vpos != Vector2.ZERO:
			all_ok = false
		if _wd.LOCATIONS.size() != 6:
			all_ok = false
	_ok(all_ok, "9 个文化圈重建后：母村 id=village 且坐标 (0,0)，基础地点 6 个")

	_wd.set_culture(_cul.current_id)
	var v2: Dictionary = _wd.by_id(_cul.HOME_ID)
	_ok(not v2.is_empty() and str(v2["name"]) == _cul.village_name(), "母村名字 = %s" % _cul.village_name())


# ---------------------------------------------------------------- 3. kinds_of

func _section_kinds(ids: Array) -> void:
	print("== 3. kinds_of：非空、含 village、都在 ALLOWED_KINDS 内 ==")
	var all_ok := true
	var bad := ""
	var allowed: Array = _wd.ALLOWED_KINDS
	for cid in ids:
		var k: Array = _cul.kinds_of(str(cid))
		if k.is_empty() or not k.has("village"):
			all_ok = false
			bad = str(cid)
			continue
		for kind in k:
			if not allowed.has(str(kind)):
				all_ok = false
				bad = "%s 的 %s" % [cid, kind]
	_ok(all_ok, "9 个文化圈 kinds 非空且含 village，且全部可被地图渲染" + ("（%s）" % bad if bad != "" else ""))
	_ok(allowed.has("village"), "ALLOWED_KINDS 已放行 village")


# ---------------------------------------------------------------- 4. compose_name

func _section_compose(ids: Array) -> void:
	print("== 4. compose_name：稳定、非空 ==")
	var all_ok := true
	for cid in ids:
		for kind in _cul.kinds_of(str(cid)):
			var a: String = str(_cul.compose_name(str(cid), str(kind), 17))
			var b: String = str(_cul.compose_name(str(cid), str(kind), 17))
			if a == "" or a != b:
				all_ok = false
	_ok(all_ok, "同一（文化圈, 类型, salt）结果稳定且非空")


# ---------------------------------------------------------------- 5. 实际生成

func _section_generate() -> void:
	print("== 5. 模拟生成 %d 个新地点（mock 模式）==" % SAMPLES)
	_wd.set_culture(_cul.current_id)
	var home_name: String = str(_cul.village_name())

	var re := RegEx.new()
	re.compile("^(village|mine|shrine|forest|ruin|bridge)_-?[0-9]+_-?[0-9]+_[0-9]{2}$")

	var created := 0
	var id_ok := true
	var culture_ok := true
	var kind_ok := true
	var river_ok := true
	var name_ok := true
	var ids_seen := {}
	for i in SAMPLES:
		var before: int = int(_wd.LOCATIONS.size())
		_lg.request_location("测试村民")
		if _wd.LOCATIONS.size() <= before:
			continue
		var loc: Dictionary = _wd.LOCATIONS[_wd.LOCATIONS.size() - 1]
		created += 1
		var id := str(loc["id"])
		var kind := str(loc["kind"])
		var cid := str(loc["culture"])
		var pos: Vector2 = loc["pos"]
		var nm := str(loc["name"])
		if re.search(id) == null or not id.begins_with(kind + "_"):
			id_ok = false
		if ids_seen.has(id):
			id_ok = false
		ids_seen[id] = true
		if _rg.culture_at(pos) != cid:
			culture_ok = false
		if not _cul.kinds_of(cid).has(kind):
			kind_ok = false
		if absf(pos.y - _lg.RIVER_Y) < _lg.RIVER_H + 60.0:
			river_ok = false
		if nm == "" or nm == home_name:
			name_ok = false

	print("  （实际成功生成 %d / %d）" % [created, SAMPLES])
	_ok(created >= 20, "至少生成 20 个新地点（实际 %d）" % created)
	_ok(id_ok, "新地点 id 形如 <kind>_<gx>_<gy>_<nn> 且唯一")
	_ok(culture_ok, "新地点的 culture 与它所在区域的风格一致")
	_ok(kind_ok, "新地点的 kind 属于该区域文化圈允许的类型")
	_ok(river_ok, "新地点都不落在溪流带里")
	_ok(name_ok, "新地点名字非空且不与母村重名")

	# 母村唯一性
	var village_count := 0
	for loc in _wd.LOCATIONS:
		if str(loc["id"]) == _cul.HOME_ID:
			village_count += 1
	_ok(village_count == 1, "全图 id=village 的地点恰好 1 个（实际 %d）" % village_count)
	_ok(_wd.by_id(_cul.HOME_ID)["pos"] == Vector2.ZERO, "母村仍在原点 (0,0)")
	_ok(_wd.by_id(_cul.HOME_ID)["name"] == home_name, "母村名字未被顶替，仍是 %s" % home_name)

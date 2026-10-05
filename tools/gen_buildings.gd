extends SceneTree
## 预生成房屋素材（**真实调用生图接口，会花钱**）。
## 用法：
##   godot --headless --path . --script res://tools/gen_buildings.gd
##   godot --headless --path . --script res://tools/gen_buildings.gd -- --dry    （只看缺哪些，不生成）
##   godot --headless --path . --script res://tools/gen_buildings.gd -- --force  （连已有的也重画覆盖）
##   godot --headless --path . --script res://tools/gen_buildings.gd -- --city   （连城市楼房也一起补）
##   godot --headless --path . --script res://tools/gen_buildings.gd -- --facility （只补功能性建筑：9 文化圈 × 9 种 × 2 档 = 162 张）
##   godot --headless --path . --script res://tools/gen_buildings.gd -- --facility --culture=qingshi （只补某个文化圈的 18 张）
##
## 默认只补「村庄民居」（9 个文化圈 × 3 个变体 = 27 张）+ 通天福地仙宫主殿 1 张。
## 已经有图的会自动跳过、不重复花钱。
## 生成结果落在 res://generated/buildings/<id>.png，之后不管开几个存档都直接复用。

var _pl                      # PropLibrary
var _bg                      # BuildingGenerator
var _fail := 0
var _force := false
var _dry := false
var _city := false
var _facility := false
var _culture := ""           # 非空时只补这个文化圈


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame        # 等第一帧，autoload 才注册完
	_pl = root.get_node_or_null("PropLibrary")
	_bg = root.get_node_or_null("BuildingGenerator")
	if _pl == null or _bg == null:
		push_error("[gen_buildings] 缺少 PropLibrary / BuildingGenerator autoload")
		quit(1)
		return

	print("== 生图配置 ==")
	print("  mode=%s provider=%s model=%s" % [str(_bg.mode), str(_bg.provider), str(_bg.model)])
	if not _bg.is_on():
		push_error("[gen_buildings] 生图接口没开（llm_config.cfg 的 [image] 段），不生成")
		quit(1)
		return

	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s == "--force":
			_force = true
		elif s == "--dry":
			_dry = true
		elif s == "--city":
			_city = true
		elif s == "--facility":
			_facility = true
		elif s.begins_with("--culture="):
			_culture = s.substr("--culture=".length())

	_bg.building_failed.connect(_on_failed)

	# 收集要画的 id：--facility 只补功能建筑，否则补民居（默认村庄，--city 时连城市一起）
	var tasks := PackedStringArray()
	if _facility:
		for id in _pl.facility_ids():
			if _culture != "" and str(_pl.parse_facility_id(id).get("culture", "")) != _culture:
				continue
			tasks.append(id)
	else:
		for id in _pl.building_ids():
			var tier: String = _pl.tier_of_building(id)
			if tier == "city" and not _city:
				continue
			tasks.append(id)
		# 通天福地仙宫主殿：独一份，不在 building_ids()（那里固定 9 文化圈 × 3 变体 × 2 档）里
		tasks.append(_pl.TIANFU_PALACE_ID)

	print("== 房屋清单：共 %d 个 id（已存在且没 --force 的会自动跳过）==" % tasks.size())
	var todo := 0
	for id in tasks:
		var exists: bool = _pl.has_building_texture(id)
		if _force or not exists:
			todo += 1
		print("  %s  %s" % ["[有]" if exists else "[缺]", id])
		if not _dry:
			_bg.request(id)          # 登记进 _wanted；已有图时它不会入队
			if _force:
				_bg.enqueue(id, true)  # --force：无视已有图，重画覆盖
	print("  本次实际要画：%d 张" % todo)

	if _dry:
		print("[dry] 只检查不生成，退出")
		quit(0)
		return
	if todo == 0:
		print("都已经有了，无需生成")
		quit(0)
		return

	# 等生图队列排空（单张最多 90 秒，整体给足 60 分钟）
	var last := -1
	var t0 := Time.get_ticks_msec()
	while _bg.pending_count() > 0 and Time.get_ticks_msec() - t0 < 3600000:
		var left: int = _bg.pending_count()
		if left != last:
			last = left
			print("  ...队列剩余 %d 张（已用 %d 秒）" % [left, int((Time.get_ticks_msec() - t0) / 1000.0)])
		await process_frame

	if _bg.pending_count() > 0:
		push_warning("[gen_buildings] 超时退出，仍有 %d 张没画完" % _bg.pending_count())

	print("== 校验落盘 ==")
	for id in tasks:
		if _pl.has_building_texture(id):
			print("  [PASS] %s 已入库" % id)
		else:
			_fail += 1
			var why: String = _bg.failure_reason(id)
			print("  [FAIL] %s 缺图%s" % [id, "" if why == "" else "（%s）" % why])

	print("----------------------------------------")
	if _fail == 0:
		print("全部通过：%d 张房屋素材已生成并落盘" % tasks.size())
	else:
		print("失败 %d / %d 张" % [_fail, tasks.size()])
	quit(0 if _fail == 0 else 1)


func _on_failed(id: String, reason: String) -> void:
	print("  [x] 画失败 %s：%s" % [id, reason])

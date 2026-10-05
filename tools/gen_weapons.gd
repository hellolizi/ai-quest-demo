extends SceneTree
## 预生成武器 / 材料的图标（**真实调用生图接口，会花钱**）。
## 用法：
##   godot --headless --path . --script res://tools/gen_weapons.gd
##   godot --headless --path . --script res://tools/gen_weapons.gd -- --force   （覆盖重画）
##
## 生成结果落在 res://generated/rewards/weapon_<id>/icon.png 与 mat_<id>/icon.png，
## 之后不管开几个存档都直接复用，不再重复生成、不再花钱。

var _lib                      # RewardLibrary
var _gen                      # RewardIconGenerator
var _wd                       # WeaponData
var _fail := 0
var _force := false
var _dry := false
var _done := 0


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
	_lib = root.get_node_or_null("RewardLibrary")
	_gen = root.get_node_or_null("RewardIconGenerator")
	_wd = root.get_node_or_null("WeaponData")
	if _lib == null or _gen == null or _wd == null:
		push_error("[gen_weapons] 缺少 RewardLibrary / RewardIconGenerator / WeaponData autoload")
		quit(1)
		return

	print("== 生图配置 ==")
	print("  mode=%s provider=%s model=%s" % [str(_gen.mode), str(_gen.provider), str(_gen.model)])
	if not _gen.is_on():
		push_error("[gen_weapons] 生图接口没开（llm_config.cfg 的 [image] 段），不生成")
		quit(1)
		return

	for a in OS.get_cmdline_user_args():
		if str(a) == "--force":
			_force = true
		elif str(a) == "--dry":
			_dry = true

	_lib.changed.connect(_on_lib_changed)

	# 收集要画的东西：所有武器的图标标签 + 所有材料的图标标签（标签去重）
	var tasks: Array[Dictionary] = []
	var seen := {}
	for id in _wd.all_ids():
		var w: Dictionary = _wd.get_weapon(id)
		if w.is_empty():
			continue
		_add_task(tasks, seen, str(w.get("icon_tag", "")), str(w.get("name", "")), str(w.get("hint", "")))
	for mid in _wd.all_material_ids():
		_add_task(tasks, seen, _wd.material_tag(mid), _wd.material_name(mid), _wd.material_hint(mid))

	print("== 需要生成 %d 张图（已存在且没 --force 的会自动跳过）==" % tasks.size())
	var todo := 0
	for t in tasks:
		var exists: bool = _lib.has(str(t["tag"]))
		if _force or not exists:
			todo += 1
		print("  %s  %s" % ["[有]" if exists else "[缺]", str(t["tag"])])
		if not _dry:
			_gen.request_named(str(t["tag"]), str(t["name"]), str(t["hint"]), _force)
	print("  本次实际要画：%d 张" % todo)

	if _dry:
		print("[dry] 只检查不生成，退出")
		quit(0)
		return

	# 等生图队列排空（最多等 15 分钟）
	var t0 := Time.get_ticks_msec()
	while _gen.pending_count() > 0 and Time.get_ticks_msec() - t0 < 900000:
		await process_frame

	print("== 校验落盘 ==")
	for t in tasks:
		var tag := str(t["tag"])
		_ok(_lib.has(tag), "%s 已入库（%s）" % [tag, str(t["name"])])

	print("----------------------------------------")
	if _fail == 0:
		print("全部通过：武器 / 材料图标已全部生成并落盘")
	else:
		print("失败 %d 项" % _fail)
	quit(0 if _fail == 0 else 1)


func _add_task(tasks: Array[Dictionary], seen: Dictionary, tag: String, name: String, hint: String) -> void:
	if tag == "" or seen.has(tag):
		return
	seen[tag] = true
	tasks.append({"tag": tag, "name": name, "hint": hint})


func _on_lib_changed() -> void:
	_done += 1
	print("  [%d] 完成一张，队列剩余 %d" % [_done, _gen.pending_count()])

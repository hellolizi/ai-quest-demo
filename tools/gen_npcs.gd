extends SceneTree
## 预生成 NPC 立绘 + 走路帧（**真实调用生图接口，会花钱**）。
## 用法：
##   godot --headless --path . --script res://tools/gen_npcs.gd
##   ... -- --dry             （只看缺哪些，不生成）
##   ... -- --force           （连已有的也重画覆盖）
##   ... -- --portrait-only   （只补立绘）
##   ... -- --walk-only       （只补走路帧）
##
## 覆盖 9 个常规文化圈的全部起始乡亲（每圈 4 人）+ 通天福地的 5 位住客 + 主角。
## 主角的标签用固定文化键 "player"，各文化圈共用一张，通常早已画好。
## 已经有图的会自动跳过、不重复花钱。
## 立绘与走路帧走两个生成器，各自串行、彼此并行。

const CharSprite := preload("res://scripts/character_sprite.gd")

var _player_script           # 运行时 load，避免 preload 编译期解析 autoload 报错
var _cd                      # CultureData
var _lib                     # PortraitLibrary
var _pg                      # PortraitGenerator
var _wg                      # WalkSheetGenerator
var _fail := 0
var _force := false
var _dry := false
var _portrait := true
var _walk := true


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame        # 等第一帧，autoload 才注册完
	_cd = root.get_node_or_null("CultureData")
	_lib = root.get_node_or_null("PortraitLibrary")
	_pg = root.get_node_or_null("PortraitGenerator")
	_wg = root.get_node_or_null("WalkSheetGenerator")
	if _cd == null or _lib == null or _pg == null or _wg == null:
		push_error("[gen_npcs] 缺少 CultureData / PortraitLibrary / PortraitGenerator / WalkSheetGenerator autoload")
		quit(1)
		return
	_player_script = load("res://scripts/player.gd")
	if _player_script == null:
		push_error("[gen_npcs] 载入 res://scripts/player.gd 失败")
		quit(1)
		return

	print("== 生图配置 ==")
	print("  立绘 mode=%s provider=%s model=%s" % [str(_pg.mode), str(_pg.provider), str(_pg.model)])
	print("  走路 mode=%s provider=%s model=%s" % [str(_wg.mode), str(_wg.provider), str(_wg.model)])
	if not _pg.is_on() and not _wg.is_on():
		push_error("[gen_npcs] 生图接口没开（llm_config.cfg 的 [image] 段），不生成")
		quit(1)
		return

	for a in OS.get_cmdline_user_args():
		match str(a):
			"--force":
				_force = true
			"--dry":
				_dry = true
			"--portrait-only":
				_walk = false
			"--walk-only":
				_portrait = false

	var people := _all_people()
	print("== 人物清单：共 %d 人（立绘 %s / 走路帧 %s）==" % [
		people.size(),
		"补" if _portrait else "跳过",
		"补" if _walk else "跳过",
	])

	var p_jobs: Array = []
	var w_jobs: Array = []
	for p in people:
		var tag := str(p["tag"])
		var has_p: bool = _lib.has(tag)
		var has_w: bool = _lib.has_walk(tag)
		print("  %s立绘 %s走路  %s  <%s>" % [
			"[有]" if has_p else "[缺]", "[有]" if has_w else "[缺]",
			tag, str(p["name"]),
		])
		if _portrait and (_force or not has_p):
			p_jobs.append(p)
		if _walk and (_force or not has_w):
			w_jobs.append(p)

	print("  本次实际要画：立绘 %d 张 + 走路帧 %d 张" % [p_jobs.size(), w_jobs.size()])

	if _dry:
		print("[dry] 只检查不生成，退出")
		quit(0)
		return
	if p_jobs.is_empty() and w_jobs.is_empty():
		print("都已经有了，无需生成")
		quit(0)
		return

	for p in p_jobs:
		_pg.request(str(p["tag"]), str(p["name"]), str(p["role"]), str(p["cid"]), p["app"], str(p.get("tier", "")))
	for p in w_jobs:
		_wg.request(str(p["tag"]), str(p["name"]), str(p["role"]), str(p["cid"]), p["app"])

	# 等两个队列都排空（走路帧单张最多 240 秒，整体给足 4 小时）
	var last := -1
	var t0 := Time.get_ticks_msec()
	while true:
		var left: int = _pg.pending_count() + _wg.pending_count()
		if left == 0:
			break
		if Time.get_ticks_msec() - t0 > 14400000:
			push_warning("[gen_npcs] 超时退出，仍有 %d 张没画完" % left)
			break
		if left != last:
			last = left
			print("  ...剩余 立绘 %d + 走路 %d（已用 %d 秒）" % [
				_pg.pending_count(), _wg.pending_count(),
				int((Time.get_ticks_msec() - t0) / 1000.0),
			])
		await process_frame

	print("== 校验落盘 ==")
	for p in people:
		var tag := str(p["tag"])
		if _portrait:
			if _lib.has(tag):
				print("  [PASS] %s 立绘已入库" % tag)
			else:
				_fail += 1
				print("  [FAIL] %s 缺立绘" % tag)
		if _walk:
			if _lib.has_walk(tag):
				print("  [PASS] %s 走路帧已入库" % tag)
			else:
				_fail += 1
				print("  [FAIL] %s 缺走路帧" % tag)

	print("----------------------------------------")
	if _fail == 0:
		print("全部通过：%d 人的立绘 / 走路帧均已就绪" % people.size())
	else:
		print("失败 %d 项" % _fail)
	quit(0 if _fail == 0 else 1)


## 收集 9 个常规文化圈 + 通天福地的全部住客 + 主角，各一份 {tag, name, role, cid, app, tier}。
## 外观推导与 main.gd / start_menu.gd 完全一致，保证标签对得上、不会重复画。
func _all_people() -> Array:
	var people: Array = []
	var seen := {}

	# 主角：标签用固定文化键 "player"，与 culture 无关，各圈共用一张
	_add(people, seen, _lib.tag_for(
		_player_script.PORTRAIT_NAME, _player_script.PORTRAIT_CULTURE_KEY, _player_script.PLAYER_APPEARANCE
	), _player_script.PORTRAIT_NAME, "主角", str(_cd.current_id), _player_script.PLAYER_APPEARANCE, "")

	# 9 个常规文化圈的起始乡亲，每圈 4 人
	for cid in _cd.all_ids():
		_collect_culture(people, seen, str(cid), CharSprite.tier_for_kind("village"))
	# 通天福地是全世界独一份的秘境，不在 all_ids() 里，单独收它的 5 位住客
	_collect_culture(people, seen, "tianfu", CharSprite.tier_for_kind("tianfu"))
	return people


## 收某个文化圈的全部起始乡亲，逐个推导标签与外观后入列（自动去重）。
func _collect_culture(people: Array, seen: Dictionary, cid: String, tier: String) -> void:
	var c: Dictionary = _cd.get_culture(cid)
	var npcs = c.get("npcs", [])
	if typeof(npcs) != TYPE_ARRAY:
		return
	for raw in (npcs as Array):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var nm := str((raw as Dictionary).get("name", "")).strip_edges()
		if nm == "":
			continue
		var app = (raw as Dictionary).get("appearance", null)
		if typeof(app) != TYPE_DICTIONARY:
			app = CharSprite.derive_appearance(nm, cid, tier)
		_add(people, seen, _lib.tag_for(nm, cid, app), nm,
			str((raw as Dictionary).get("role", "")), cid, app, tier)


func _add(people: Array, seen: Dictionary, tag: String, nm: String, role: String, cid: String, app, tier: String) -> void:
	if tag == "" or seen.has(tag):
		return
	seen[tag] = true
	people.append({
		"tag": tag, "name": nm, "role": role,
		"cid": cid, "app": CharSprite.sanitize_appearance(app), "tier": tier,
	})

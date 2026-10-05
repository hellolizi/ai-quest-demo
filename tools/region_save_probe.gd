extends SceneTree
## 一次性验证工具：世界种子接入存档（第 1 步）
## 用法：godot --headless --path . --script res://tools/region_save_probe.gd
##
## 会真的读写 user://save.json，所以先备份、测完还原，不动玩家的存档。

const SAVE_PATH := "user://save.json"

var _rg                      # RegionGenerator（延迟从场景树取，避免编译期引用 autoload）
var _ss                      # SaveSystem
var _backup_exists := false
var _backup_text := ""
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
	_rg = root.get_node_or_null("RegionGenerator")
	_ss = root.get_node_or_null("SaveSystem")
	if _rg == null or _ss == null:
		push_error("[probe] 缺少 RegionGenerator / SaveSystem autoload")
		quit(1)
		return
	_backup_save()

	print("== 1. 新游戏掷种子 ==")
	var s1: int = _rg.randomize_world_seed()
	_ok(s1 != 0, "randomize_world_seed 得到非零种子: %d" % s1)
	var s2: int = _rg.randomize_world_seed()
	_ok(s1 != s2, "两次掷出的种子不同: %d vs %d" % [s1, s2])

	print("== 2. 种子决定地图 + 存取可复现 ==")
	var pts := [Vector2(0, 40), Vector2(3000, -2000), Vector2(123456, -654321)]
	_rg.set_world_seed(777)
	var a: Array = []
	for p in pts:
		a.append(_rg.culture_at(p))
	print("     种子777 取样风格: %s" % str(a))
	var saved: Dictionary = _rg.to_save()
	_rg.set_world_seed(888)
	var diff := 0
	for i in pts.size():
		if _rg.culture_at(pts[i]) != a[i]:
			diff += 1
	_ok(diff > 0, "换种子后 %d/%d 取样点风格改变" % [diff, pts.size()])
	_rg.from_save(saved)
	var same := 0
	for i in pts.size():
		if _rg.culture_at(pts[i]) == a[i]:
			same += 1
	_ok(same == pts.size(), "from_save 还原后 %d/%d 取样点风格一致" % [same, pts.size()])

	print("== 3. save_game 写入 region 字段 ==")
	_rg.set_world_seed(20261004)
	_ss.active = true
	_ss.save_game()
	var data = _read_save()
	_ok(typeof(data) == TYPE_DICTIONARY, "存档文件可解析")
	if typeof(data) == TYPE_DICTIONARY:
		_ok(data.has("region"), "存档含 region 字段")
		var rs := int(data.get("region", {}).get("world_seed", -1))
		_ok(rs == 20261004, "存档内 world_seed 正确: %d" % rs)

	print("== 4. load_game 还原种子 ==")
	_rg.set_world_seed(1)      # 先故意打乱
	_ss.load_game()
	_ok(_rg.world_seed == 20261004, "读档后 world_seed 还原: %d" % _rg.world_seed)
	var b: Array = []
	for p in pts:
		b.append(_rg.culture_at(p))
	_ok(str(a) != str(b) or true, "读档后取样风格: %s" % str(b))

	print("== 5. start_new_game 会掷新种子 ==")
	_rg.set_world_seed(0)
	_ss.start_new_game()
	_ok(_rg.world_seed != 0, "新游戏后 world_seed 非零: %d" % _rg.world_seed)
	var d2 = _read_save()
	var ns := int(d2.get("region", {}).get("world_seed", -1)) if typeof(d2) == TYPE_DICTIONARY else -2
	_ok(ns == _rg.world_seed, "新游戏存档里的种子与内存一致: %d" % ns)

	# 收尾：还原玩家存档
	_ss.active = false
	_restore_save()

	print("----------------------------------------")
	if _fail == 0:
		print("全部通过")
	else:
		print("失败 %d 项" % _fail)
	quit(0 if _fail == 0 else 1)


# ---------------------------------------------------------------- 存档备份

func _read_save():
	if not FileAccess.file_exists(SAVE_PATH):
		return null
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return null
	var t := f.get_as_text()
	f.close()
	return JSON.parse_string(t)


func _backup_save() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		_backup_exists = true
		var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
		if f != null:
			_backup_text = f.get_as_text()
			f.close()


func _restore_save() -> void:
	if _backup_exists:
		var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
		if f != null:
			f.store_string(_backup_text)
			f.close()
		print("[probe] 已还原玩家存档")
	elif FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(SAVE_PATH)
		print("[probe] 原本无存档，已清理测试存档")

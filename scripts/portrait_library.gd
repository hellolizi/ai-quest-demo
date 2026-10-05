extends Node
## 立绘库（Autoload 名字：PortraitLibrary）
##
## AI 生成的素材统一存到 res://generated/characters/，**一个角色一个小文件夹**，
## 文件夹名就是这个角色的「标签」(tag)：
##
##   res://generated/characters/阿花_12345678/
##   └─ portrait.png           正面立绘
##
## 标签由 NPC 名字 + 文化圈 + 外观参数稳定推导：同一个人永远是同一个标签，
## 于是「画过一次就永远复用」，不会再花钱重画。
## 以后加走路序列帧时，down/ up/ left/ right/ 这些子文件夹也建在同一个角色文件夹里。
##
## 放在 res://（即游戏目录）里而不是 user://，是为了跟项目一起走、方便备份，
## 也让「删除 user:// 里没用的东西」时不会误删好不容易画出来的素材。
##
## index.json 记着每个角色的元信息（谁、长什么样、什么模型画的、什么时候画的）
## 以及「启用 / 停用」状态——玩家在立绘库里淘汰掉的只是标记停用，文件原封不动留着，
## 以后想用随时能一键启用回来。

signal changed
## 走路帧入库 / 被清掉时发一次（tag 是角色标签）
signal walk_changed(tag: String)
## 攻击动作帧入库时发一次（tag 是角色标签）
signal attack_changed(tag: String)

## 素材根目录：一个角色一个子文件夹
const DIR := "res://generated/characters"
const INDEX_PATH := "res://generated/characters/index.json"
## 角色文件夹里的正面立绘文件名
const PORTRAIT_FILE := "portrait.png"

## 走路序列帧放在角色文件夹下的这个子目录里
const WALK_SUBDIR := "walk"
## 4 个朝向。落盘只存 down/up/left 三个（right 播放时由 left 内存翻转得到，省一半图）
const WALK_DIRS := ["down", "up", "left", "right"]
const WALK_STORED_DIRS := ["down", "up", "left"]
const WALK_MIRROR_FROM := "left"
const WALK_MIRROR_TO := "right"
## 每个朝向 4 帧
const WALK_FRAMES := 4

## 攻击动作序列帧放在角色文件夹下的这个子目录里（结构和 walk 一样）
const ATTACK_SUBDIR := "attack"
## 每个朝向 4 帧：蓄力 → 挥出 → 命中 → 收招
const ATTACK_FRAMES := 4

## 旧版把立绘平铺在这个目录里（一个角色一张 <tag>.png）。启动时自动搬进上面的新结构。
const LEGACY_DIR := "user://portraits"
const LEGACY_INDEX := "user://portraits/index.json"

## 文件名里不能出现的字符（Windows 限制）
const BAD_CHARS := "\\/:*?\"<>| \t\r\n"

## tag -> {file, name, role, culture, appearance, provider, model, created_at, enabled}
var _entries: Dictionary = {}
## tag -> ImageTexture（内存缓存，免得每次进游戏都重新读盘）
var _textures: Dictionary = {}
## tag -> {方向: Array[Texture2D]}（走路帧内存缓存，含内存翻转出来的 right）
var _walk_cache: Dictionary = {}
## tag -> {方向: Array[Texture2D]}（攻击帧内存缓存，含内存翻转出来的 right）
var _attack_cache: Dictionary = {}


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	_load_index()
	_migrate_legacy()


## 素材库在磁盘上的真实路径，方便在界面上告诉玩家去哪找
static func dir_path() -> String:
	return ProjectSettings.globalize_path(DIR)


# ---------------------------------------------------------------- 标签

## 由「名字 + 文化圈 + 外观」稳定推出标签，直接拿来做文件名。
## 同一个人（同样长相）算出来的标签永远一样，所以能命中缓存。
static func tag_for(npc_name: String, culture_id: String, appearance: Dictionary) -> String:
	var app := CharacterSprite.sanitize_appearance(appearance)
	var raw := "%s|%s|%s" % [npc_name, culture_id, _app_key(app)]
	return "%s_%08d" % [_slug(npc_name), absi(hash(raw)) % 100000000]


static func _app_key(app: Dictionary) -> String:
	return "%s,%s,%s,%s,%s,%s" % [
		app.get("skin", ""), app.get("hair", ""), app.get("hair_style", ""),
		app.get("clothes", ""), app.get("build", ""), app.get("accessory", ""),
	]


## 把名字整理成能用做文件名的样子：Windows 不允许的字符换成下划线，其余（含中文）保留
static func _slug(text: String) -> String:
	var out := ""
	for ch in text:
		out += "_" if BAD_CHARS.contains(ch) else ch
	out = out.strip_edges()
	if out == "" or out == "_":
		out = "npc"
	return out.substr(0, 24)


## 这个角色的专属小文件夹，他所有的素材都住在这里
static func char_dir(tag: String) -> String:
	return "%s/%s" % [DIR, tag]


static func path_for(tag: String) -> String:
	return "%s/%s" % [char_dir(tag), PORTRAIT_FILE]


## 走路帧所在目录：characters/<tag>/walk/
static func walk_dir_for(tag: String) -> String:
	return "%s/%s" % [char_dir(tag), WALK_SUBDIR]


## 某一朝向某一帧的文件路径：characters/<tag>/walk/<dir>_f<n>.png
static func walk_frame_path(tag: String, dir: String, frame: int) -> String:
	return "%s/%s_f%d.png" % [walk_dir_for(tag), dir, frame]


## 攻击帧所在目录：characters/<tag>/attack/
static func attack_dir_for(tag: String) -> String:
	return "%s/%s" % [char_dir(tag), ATTACK_SUBDIR]


## 某一朝向某一帧的攻击帧路径：characters/<tag>/attack/<dir>_f<n>.png
static func attack_frame_path(tag: String, dir: String, frame: int) -> String:
	return "%s/%s_f%d.png" % [attack_dir_for(tag), dir, frame]


# ---------------------------------------------------------------- 查询

## 这张立绘存在吗（索引里有 + 文件也还在）
func has(tag: String) -> bool:
	return _entries.has(tag) and FileAccess.file_exists(path_for(tag))


## 这张立绘现在是不是「采用」状态。不存在当然算没采用。
func is_enabled(tag: String) -> bool:
	if not has(tag):
		return false
	return bool(_entries[tag].get("enabled", true))


func get_entry(tag: String) -> Dictionary:
	return _entries.get(tag, {})


func all_tags() -> Array:
	return _entries.keys()


func total_count() -> int:
	return _entries.size()


func enabled_count() -> int:
	var n := 0
	for tag in _entries.keys():
		if is_enabled(tag):
			n += 1
	return n


func disabled_count() -> int:
	return total_count() - enabled_count()


## 读出立绘纹理（带内存缓存）。没有就返回 null。
func get_texture(tag: String) -> Texture2D:
	if _textures.has(tag):
		return _textures[tag]
	if not has(tag):
		return null
	var img := Image.load_from_file(path_for(tag))
	if img == null:
		push_warning("[PortraitLibrary] 立绘读不出来：%s" % path_for(tag))
		return null
	var tex := ImageTexture.create_from_image(img)
	_textures[tag] = tex
	return tex


## 这个角色有没有走路帧（索引里标了 + 至少第一帧文件还在）
func has_walk(tag: String) -> bool:
	if not _entries.has(tag):
		return false
	if not bool(_entries[tag].get("walk", false)):
		return false
	return FileAccess.file_exists(walk_frame_path(tag, WALK_STORED_DIRS[0], 0))


## 读出走路帧：{方向: Array[Texture2D]}，含内存翻转补出来的 right。
## 没有就返回空字典。带内存缓存。
func get_walk_frames(tag: String) -> Dictionary:
	if _walk_cache.has(tag):
		return _walk_cache[tag]
	if not has_walk(tag):
		return {}
	var out: Dictionary = {}
	for d in WALK_STORED_DIRS:
		var arr: Array = []
		for i in WALK_FRAMES:
			var img := Image.load_from_file(walk_frame_path(tag, d, i))
			if img == null:
				continue
			arr.append(ImageTexture.create_from_image(img))
		if not arr.is_empty():
			out[d] = arr
	# right 不落盘：把 left 的每一帧水平翻转，内存里补出 4 张
	if out.has(WALK_MIRROR_FROM):
		var mirrored: Array = []
		for i in WALK_FRAMES:
			var img := Image.load_from_file(walk_frame_path(tag, WALK_MIRROR_FROM, i))
			if img == null:
				continue
			img.flip_x()
			mirrored.append(ImageTexture.create_from_image(img))
		if not mirrored.is_empty():
			out[WALK_MIRROR_TO] = mirrored
	_walk_cache[tag] = out
	return out


## 这个角色有没有攻击动作帧（索引里标了 + 至少第一帧文件还在）
func has_attack(tag: String) -> bool:
	if not _entries.has(tag):
		return false
	if not bool(_entries[tag].get("attack", false)):
		return false
	return FileAccess.file_exists(attack_frame_path(tag, WALK_STORED_DIRS[0], 0))


## 读出攻击帧：{方向: Array[Texture2D]}，含内存翻转补出来的 right。
## 没有就返回空字典。带内存缓存。
func get_attack_frames(tag: String) -> Dictionary:
	if _attack_cache.has(tag):
		return _attack_cache[tag]
	if not has_attack(tag):
		return {}
	var out: Dictionary = {}
	for d in WALK_STORED_DIRS:
		var arr: Array = []
		for i in ATTACK_FRAMES:
			var img := Image.load_from_file(attack_frame_path(tag, d, i))
			if img == null:
				continue
			arr.append(ImageTexture.create_from_image(img))
		if not arr.is_empty():
			out[d] = arr
	# right 不落盘：把 left 的每一帧水平翻转，内存里补出
	if out.has(WALK_MIRROR_FROM):
		var mirrored: Array = []
		for i in ATTACK_FRAMES:
			var img := Image.load_from_file(attack_frame_path(tag, WALK_MIRROR_FROM, i))
			if img == null:
				continue
			img.flip_x()
			mirrored.append(ImageTexture.create_from_image(img))
		if not mirrored.is_empty():
			out[WALK_MIRROR_TO] = mirrored
	_attack_cache[tag] = out
	return out


# ---------------------------------------------------------------- 写入 / 状态

## 把一张刚生成好的图存进库里。同一个标签会覆盖旧图，并自动重新「采用」。
func register(tag: String, image: Image, meta: Dictionary) -> bool:
	if image == null:
		return false
	var dir := char_dir(tag)
	DirAccess.make_dir_recursive_absolute(dir)
	if not DirAccess.dir_exists_absolute(dir):
		push_warning("[PortraitLibrary] 建不了角色文件夹：%s" % dir)
		return false
	var err := image.save_png(path_for(tag))
	if err != OK:
		push_warning("[PortraitLibrary] 立绘保存失败：%s" % error_string(err))
		return false
	_textures.erase(tag)
	var entry: Dictionary = _entries.get(tag, {})
	entry["file"] = PORTRAIT_FILE
	entry["enabled"] = true
	entry["created_at"] = Time.get_datetime_string_from_system()
	for key in meta.keys():
		entry[key] = meta[key]
	_entries[tag] = entry
	_save_index()
	changed.emit()
	print("[PortraitLibrary] 已入库：%s" % tag)
	return true


## 把一组走路帧存进库：frames = {方向: Array[Image]}，只落盘 down/up/left。
## 同一个标签会覆盖旧帧。立绘本身不动，只补一个 walk 标记。
func register_walk(tag: String, frames: Dictionary, meta: Dictionary) -> bool:
	if frames.is_empty():
		return false
	var dir := walk_dir_for(tag)
	DirAccess.make_dir_recursive_absolute(dir)
	if not DirAccess.dir_exists_absolute(dir):
		push_warning("[PortraitLibrary] 建不了走路帧目录：%s" % dir)
		return false
	var saved := 0
	for d in WALK_STORED_DIRS:
		var arr = frames.get(d, null)
		if typeof(arr) != TYPE_ARRAY:
			continue
		for i in (arr as Array).size():
			var img = (arr as Array)[i]
			if img == null:
				continue
			if (img as Image).save_png(walk_frame_path(tag, d, i)) == OK:
				saved += 1
	if saved == 0:
		push_warning("[PortraitLibrary] 走路帧没存下任何一张：%s" % tag)
		return false
	_walk_cache.erase(tag)
	var entry: Dictionary = _entries.get(tag, {})
	entry["walk"] = true
	entry["walk_created_at"] = Time.get_datetime_string_from_system()
	for key in meta.keys():
		entry[key] = meta[key]
	_entries[tag] = entry
	_save_index()
	walk_changed.emit(tag)
	print("[PortraitLibrary] 走路帧已入库：%s（%d 张）" % [tag, saved])
	return true


## 把一组攻击动作帧存进库：frames = {方向: Array[Image]}，只落盘 down/up/left。
## 同一个标签会覆盖旧帧。立绘本身不动，只补一个 attack 标记。
func register_attack(tag: String, frames: Dictionary, meta: Dictionary) -> bool:
	if frames.is_empty():
		return false
	var dir := attack_dir_for(tag)
	DirAccess.make_dir_recursive_absolute(dir)
	if not DirAccess.dir_exists_absolute(dir):
		push_warning("[PortraitLibrary] 建不了攻击帧目录：%s" % dir)
		return false
	var saved := 0
	for d in WALK_STORED_DIRS:
		var arr = frames.get(d, null)
		if typeof(arr) != TYPE_ARRAY:
			continue
		for i in (arr as Array).size():
			var img = (arr as Array)[i]
			if img == null:
				continue
			if (img as Image).save_png(attack_frame_path(tag, d, i)) == OK:
				saved += 1
	if saved == 0:
		push_warning("[PortraitLibrary] 攻击帧没存下任何一张：%s" % tag)
		return false
	_attack_cache.erase(tag)
	var entry: Dictionary = _entries.get(tag, {})
	entry["attack"] = true
	entry["attack_created_at"] = Time.get_datetime_string_from_system()
	for key in meta.keys():
		entry[key] = meta[key]
	_entries[tag] = entry
	_save_index()
	attack_changed.emit(tag)
	print("[PortraitLibrary] 攻击帧已入库：%s（%d 张）" % [tag, saved])
	return true


## 采用 / 停用。停用只是标记，文件留着，随时能再启用。
func set_enabled(tag: String, on: bool) -> void:
	if not _entries.has(tag):
		return
	if bool(_entries[tag].get("enabled", true)) == on:
		return
	_entries[tag]["enabled"] = on
	_save_index()
	changed.emit()


func toggle_enabled(tag: String) -> bool:
	var now := not is_enabled(tag)
	set_enabled(tag, now)
	return now


## 删掉一个角色的整个文件夹（立绘 + 以后的走路帧一起清）。玩家真要清理时才用得上。
func remove(tag: String) -> void:
	if not _entries.has(tag):
		return
	_purge_dir(char_dir(tag))
	_entries.erase(tag)
	_textures.erase(tag)
	_walk_cache.erase(tag)
	_attack_cache.erase(tag)
	_save_index()
	changed.emit()


# ---------------------------------------------------------------- 索引读写

func _load_index() -> void:
	if not FileAccess.file_exists(INDEX_PATH):
		return
	var text := FileAccess.get_file_as_string(INDEX_PATH)
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[PortraitLibrary] index.json 解析失败，按空库处理")
		return
	_entries = parsed


func _save_index() -> void:
	var f := FileAccess.open(INDEX_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("[PortraitLibrary] 写不了索引：%s" % INDEX_PATH)
		return
	f.store_string(JSON.stringify(_entries, "\t"))
	f.close()


# ---------------------------------------------------------------- 迁移 / 清理

## 旧版把立绘平铺在 user://portraits/ 下（一个角色一张 <tag>.png）。
## 这里把它整体搬进新的「一个角色一个文件夹」结构，连旧索引一起并过来，最后清掉旧目录。
## 搬完旧目录就没了，所以只会真正执行一次；中途失败也会在下次启动接着搬。
func _migrate_legacy() -> void:
	if not DirAccess.dir_exists_absolute(LEGACY_DIR):
		return

	# 旧索引里的元信息并进来（同一个 tag 已有新记录就不覆盖）
	if FileAccess.file_exists(LEGACY_INDEX):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(LEGACY_INDEX))
		if typeof(parsed) == TYPE_DICTIONARY:
			for tag in (parsed as Dictionary).keys():
				if _entries.has(tag):
					continue
				var e: Dictionary = (parsed as Dictionary)[tag]
				e["file"] = PORTRAIT_FILE
				_entries[tag] = e

	var moved := 0
	var d := DirAccess.open(LEGACY_DIR)
	if d != null:
		var files: Array[String] = []
		d.list_dir_begin()
		var n := d.get_next()
		while n != "":
			if not d.current_is_dir() and n.to_lower().ends_with(".png"):
				files.append(n)
			n = d.get_next()
		d.list_dir_end()
		for f in files:
			var tag := f.get_basename()
			var dest := char_dir(tag)
			DirAccess.make_dir_recursive_absolute(dest)
			if not DirAccess.dir_exists_absolute(dest):
				continue
			if DirAccess.rename_absolute(LEGACY_DIR.path_join(f), dest.path_join(PORTRAIT_FILE)) == OK:
				moved += 1

	_save_index()
	_purge_dir(LEGACY_DIR)
	print("[PortraitLibrary] 旧立绘已搬进角色文件夹：%d 张" % moved)


## 递归删掉一个目录（连同里面的文件）
static func _purge_dir(rel: String) -> void:
	var d := DirAccess.open(rel)
	if d == null:
		return
	var subdirs: Array[String] = []
	var files: Array[String] = []
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if n != "." and n != "..":
			if d.current_is_dir():
				subdirs.append(n)
			else:
				files.append(n)
		n = d.get_next()
	d.list_dir_end()
	for f in files:
		d.remove(f)
	d = null
	for s in subdirs:
		_purge_dir(rel.path_join(s))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(rel))

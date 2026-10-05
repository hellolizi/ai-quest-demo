extends Node
## 奖励图标库（Autoload 名字：RewardLibrary）
##
## 任务奖励的图标统一存到 res://generated/rewards/，**一个标签一个小文件夹**：
##
##   res://generated/rewards/cat_gold/icon.png
##   res://generated/rewards/老张的月光石/icon.png
##
## 关键点：这个目录在 res://（游戏目录）下、且**不随存档走**（换新游戏只删 save.json）。
## 所以第一个存档画好的图标，第二个存档用到时能直接复用，不会重画、不花钱。
##
## 怎么判断「两个名字能不能共用一张图」？分三层（越靠前越便宜）：
##   1. 归类词典：金/金币/金子/金块… 全部归到 cat_gold，天然共用；
##   2. 别名记忆：每张图记下它被用过的所有名字，下次按名字也能命中；
##   3. 语义兜底：词典和别名都没命中时，交给 RewardIconGenerator 去问文字模型。
## 第 3 层不在本文件里，这里只负责前三层里「本地能判定的部分」。

signal changed

const DIR := "res://generated/rewards"
const INDEX_PATH := "res://generated/rewards/index.json"
## 每个标签文件夹里的图标文件名
const ICON_FILE := "icon.png"

## 文件名里不能出现的字符（Windows 限制），中文保留
const BAD_CHARS := "\\/:*?\"<>| \t\r\n"
## 归一化时要抹掉的标点 / 空白，抹掉后「金子！」和「金子」才算同一个词
const PUNCT := " \t\r\n，。、！？：；·.,!?:;'\"“”‘’()（）[]【】<>《》-_—…～~"

## 归类词典：类别 id -> {label: 给模型看的类别名, words: 关键词}
## 命中的词越长越优先，所以「宝石」不会被「石」抢到 ore 去。
const CATEGORIES := {
	"gold": {"label": "钱财 / 金子", "words": [
		"金币", "金子", "金块", "金条", "金锭", "黄金", "金钱", "铜钱", "银两", "银子",
		"钱币", "赏钱", "碎银", "gold", "coin",
	]},
	"gem": {"label": "宝石 / 珠宝", "words": [
		"宝石", "宝玉", "钻石", "水晶", "玉石", "玛瑙", "翡翠", "珍珠", "琉璃", "琥珀",
	]},
	"herb": {"label": "草药 / 丹药", "words": [
		"草药", "药材", "灵药", "药草", "药丸", "丹药", "药水", "伤药", "药膏",
	]},
	"food": {"label": "食物 / 干粮", "words": [
		"食物", "干粮", "口粮", "粮食", "面包", "馒头", "面饼", "烤肉", "鱼肉", "野果",
		"果酒", "米酒", "清茶", "米", "糖", "酒", "茶",
	]},
	"tool": {"label": "工具", "words": [
		"工具", "锄头", "锤子", "镰刀", "铲子", "斧头", "镐子", "绳索", "渔具", "水桶",
	]},
	"weapon": {"label": "兵器", "words": [
		"兵器", "长剑", "短刀", "匕首", "长矛", "弓箭", "刀", "剑", "弓", "箭", "枪",
	]},
	"cloth": {"label": "布匹 / 织物", "words": [
		"布匹", "绸缎", "丝绸", "织物", "毛线", "毡毯", "布料", "衣裳", "长袍", "围巾",
	]},
	"letter": {"label": "书信 / 卷轴", "words": [
		"书信", "信件", "信笺", "纸条", "便条", "字条", "卷轴", "地图", "文书", "信",
	]},
	"key": {"label": "钥匙 / 凭证", "words": [
		"钥匙", "令牌", "印章", "印记", "凭证", "符",
	]},
	"flower": {"label": "花草 / 种子", "words": [
		"鲜花", "花朵", "花种", "种子", "树苗", "盆栽", "花草", "花", "草",
	]},
	"ore": {"label": "矿石 / 石料", "words": [
		"矿石", "铁矿", "铜矿", "煤矿", "石料", "石头", "铁", "铜", "锡", "煤", "石",
	]},
	"wood": {"label": "木料 / 竹材", "words": [
		"木材", "木料", "木柴", "竹子", "竹竿", "木", "竹", "柴",
	]},
	"trinket": {"label": "饰物 / 玩物", "words": [
		"玩偶", "玩具", "铃铛", "风铃", "挂件", "项链", "手镯", "发簪", "饰物", "饰",
	]},
	"gift": {"label": "谢礼 / 礼物", "words": [
		"谢礼", "礼物", "赠礼", "回礼", "贺礼", "见面礼",
	]},
}

## tag -> {file, name, category, aliases, provider, model, created_at, enabled}
var _entries: Dictionary = {}
## tag -> ImageTexture（内存缓存，免得每次进游戏都重新读盘）
var _textures: Dictionary = {}


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	_load_index()


## 图标库在磁盘上的真实路径，方便在界面上告诉玩家去哪找
static func dir_path() -> String:
	return ProjectSettings.globalize_path(DIR)


static func icon_dir(tag: String) -> String:
	return "%s/%s" % [DIR, tag]


static func path_for(tag: String) -> String:
	return "%s/%s" % [icon_dir(tag), ICON_FILE]


# ---------------------------------------------------------------- 归类 / 标签

## 抹掉标点空白、转小写，得到用来比较的「净词」
static func _normalize(text: String) -> String:
	var out := ""
	for ch in text.strip_edges().to_lower():
		if PUNCT.contains(ch):
			continue
		out += ch
	return out


## 把名字整理成能当文件名的样子：Windows 不允许的字符换成下划线，其余（含中文）保留
static func _slug(text: String) -> String:
	var out := ""
	for ch in text:
		out += "_" if BAD_CHARS.contains(ch) else ch
	out = out.strip_edges()
	if out == "" or out == "_":
		out = "reward"
	return out.substr(0, 24)


## 这个奖励名属于哪个大类？没有就返回空串。命中越长的关键词越优先。
static func category_of(text: String) -> String:
	var norm := _normalize(text)
	if norm == "":
		return ""
	var best_cat := ""
	var best_len := 0
	for cat in CATEGORIES.keys():
		var words: Array = CATEGORIES[cat]["words"]
		for w in words:
			var word := str(w)
			if word != "" and norm.contains(word) and word.length() > best_len:
				best_len = word.length()
				best_cat = str(cat)
	return best_cat


## 类别的中文名，拼大小写提示词时用
static func category_label(cat: String) -> String:
	if cat == "" or not CATEGORIES.has(cat):
		return ""
	return str(CATEGORIES[cat]["label"])


## 一个奖励名最终落到哪个标签。有大类就按大类共用，没有就用字面名。
## 「金子」和「金块」都会得到 "cat_gold"，于是天然共用一张图。
static func canonical_tag(text: String) -> String:
	var cat := category_of(text)
	if cat != "":
		return "cat_%s" % cat
	return _slug(_normalize(text))


## 把任务的 rewards 拆成「要展示、要配图」的条目清单。
## 输出的每一项：{text: 显示名, amount: 数量, tag: 图标标签, category: 大类}
static func items_of_rewards(rewards: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if typeof(rewards) != TYPE_DICTIONARY:
		return out
	var r: Dictionary = rewards
	for key in r.keys():
		var k := str(key)
		var v: Variant = r[key]
		if k == "gold":
			var amount := 0
			if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
				amount = int(v)
			if amount > 0:
				out.append(_make_item("金币", amount, "gold"))
		elif k == "item":
			var nm := str(v).strip_edges()
			if nm != "":
				out.append(_make_item(nm, 1, ""))
		elif typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
			var n := int(v)
			if n != 0:
				out.append(_make_item(k, n, ""))
		elif typeof(v) == TYPE_STRING:
			var s := str(v).strip_edges()
			if s != "":
				out.append(_make_item(s, 1, ""))
	return out


static func _make_item(text: String, amount: int, cat_hint: String) -> Dictionary:
	var cat := cat_hint if cat_hint != "" else category_of(text)
	var tag := ("cat_%s" % cat) if cat != "" else _slug(_normalize(text))
	return {"text": text, "amount": amount, "tag": tag, "category": cat}


# ---------------------------------------------------------------- 查询

## 这张图标存在吗（索引里有 + 文件也还在）
func has(tag: String) -> bool:
	return _entries.has(tag) and FileAccess.file_exists(path_for(tag))


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


## 读出图标纹理（带内存缓存）。没有就返回 null。
func get_texture(tag: String) -> Texture2D:
	if _textures.has(tag):
		return _textures[tag]
	if not has(tag):
		return null
	var img := Image.load_from_file(path_for(tag))
	if img == null:
		push_warning("[RewardLibrary] 图标读不出来：%s" % path_for(tag))
		return null
	var tex := ImageTexture.create_from_image(img)
	_textures[tag] = tex
	return tex


## 给某个奖励名找一个「已经能用的」标签，找不到返回空串。
## 顺序：大类标签 → 名字/别名归一化全等 → 名字/别名宽松包含。
func resolve(text: String) -> String:
	var tag := canonical_tag(text)
	if tag != "" and has(tag):
		return tag
	var norm := _normalize(text)
	if norm == "":
		return ""
	for t in _entries.keys():
		if _entry_matches(_entries[t], norm, true):
			return str(t)
	for t in _entries.keys():
		if _entry_matches(_entries[t], norm, false):
			return str(t)
	return ""


func _entry_matches(entry: Dictionary, norm: String, exact: bool) -> bool:
	var names: Array = [str(entry.get("name", ""))]
	for a in entry.get("aliases", []):
		names.append(str(a))
	for n in names:
		var nn := _normalize(str(n))
		if nn == "":
			continue
		if exact:
			if nn == norm:
				return true
		elif nn.length() >= 2 and (nn.contains(norm) or norm.contains(nn)):
			return true
	return false


## 给模型看的「已有图标清单」，让它判断新奖励能不能复用其中一张
func catalog_for_llm(limit: int = 40) -> String:
	var lines: PackedStringArray = []
	var n := 0
	for t in _entries.keys():
		if n >= limit:
			break
		var e: Dictionary = _entries[t]
		var names: PackedStringArray = []
		var nm := str(e.get("name", ""))
		if nm != "":
			names.append(nm)
		for a in e.get("aliases", []):
			var s := str(a)
			if s != "" and not names.has(s):
				names.append(s)
		var label := str(e.get("category", ""))
		var suffix := "" if label == "" else "（%s）" % label
		lines.append("- %s%s：%s" % [t, suffix, "、".join(names)])
		n += 1
	return "\n".join(lines)


# ---------------------------------------------------------------- 写入 / 状态

## 把一张刚生成好的图存进库里。同一个标签会覆盖旧图，并把新名字并进别名。
func register(tag: String, image: Image, meta: Dictionary) -> bool:
	if image == null or tag == "":
		return false
	var dir := icon_dir(tag)
	DirAccess.make_dir_recursive_absolute(dir)
	if not DirAccess.dir_exists_absolute(dir):
		push_warning("[RewardLibrary] 建不了图标文件夹：%s" % dir)
		return false
	var err := image.save_png(path_for(tag))
	if err != OK:
		push_warning("[RewardLibrary] 图标保存失败：%s" % error_string(err))
		return false
	_textures.erase(tag)
	var entry: Dictionary = _entries.get(tag, {})
	entry["file"] = ICON_FILE
	entry["enabled"] = true
	entry["created_at"] = Time.get_datetime_string_from_system()
	# 别名要合并，不能覆盖：同一个标签可能被很多个名字用过
	var aliases: Array = entry.get("aliases", [])
	for extra in meta.get("aliases", []):
		var s := str(extra).strip_edges()
		if s != "" and not aliases.has(s):
			aliases.append(s)
	var new_name := str(meta.get("name", "")).strip_edges()
	if new_name != "" and not aliases.has(new_name):
		aliases.append(new_name)
	entry["aliases"] = aliases
	for key in meta.keys():
		if key == "aliases":
			continue
		entry[key] = meta[key]
	_entries[tag] = entry
	_save_index()
	changed.emit()
	print("[RewardLibrary] 已入库：%s" % tag)
	return true


## 记下「这张图也能代表这个名字」，下次靠别名就能复用，不用再问模型
func add_alias(tag: String, name: String) -> void:
	var n := name.strip_edges()
	if n == "" or not _entries.has(tag):
		return
	if str(_entries[tag].get("name", "")) == n:
		return
	var aliases: Array = _entries[tag].get("aliases", [])
	if aliases.has(n):
		return
	aliases.append(n)
	_entries[tag]["aliases"] = aliases
	_save_index()


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


func remove(tag: String) -> void:
	if not _entries.has(tag):
		return
	_purge_dir(icon_dir(tag))
	_entries.erase(tag)
	_textures.erase(tag)
	_save_index()
	changed.emit()


# ---------------------------------------------------------------- 索引读写

func _load_index() -> void:
	if not FileAccess.file_exists(INDEX_PATH):
		return
	var text := FileAccess.get_file_as_string(INDEX_PATH)
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[RewardLibrary] index.json 解析失败，按空库处理")
		return
	_entries = parsed


func _save_index() -> void:
	var f := FileAccess.open(INDEX_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("[RewardLibrary] 写不了索引：%s" % INDEX_PATH)
		return
	f.store_string(JSON.stringify(_entries, "\t"))
	f.close()


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

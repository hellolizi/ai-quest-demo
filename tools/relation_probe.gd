extends SceneTree
## 一次性验证工具：NPC ↔ NPC 关系网（NpcRelations）
## 用法：godot --headless --path . --script res://tools/relation_probe.gd
##
## 纯只读：只改内存里的关系网 / NPC 生成器状态，不写任何存档文件。

var _rel                      # NpcRelations
var _gen                      # NpcGenerator
var _wd                       # WorldData
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
	_rel = root.get_node_or_null("NpcRelations")
	_gen = root.get_node_or_null("NpcGenerator")
	_wd = root.get_node_or_null("WorldData")
	for n in [_rel, _gen, _wd]:
		if n == null:
			_log("[probe] 缺少 autoload 节点")
			quit(1)
			return

	# 纯离线验证：强制 mock，避免真去调大模型接口
	_gen.mode = "mock"

	_section_link()
	_section_ensure()
	_section_limit()
	_section_save()
	_section_generator()
	_section_ai_relations()

	if _fail == 0:
		_log("== 全部通过 ==")
		quit(0)
	else:
		_log("== 失败 %d 项 ==" % _fail)
		quit(1)


# ---------------------------------------------------------------- 1. 双向与对称

func _section_link() -> void:
	_log("== 1. link 双向写入且对称去重 ==")
	_rel.from_save({})
	var ok: bool = _rel.link("村民 甲", "村民 乙", "邻居", "住隔壁")
	_ok(ok, "第一次牵线成功")
	_ok(_rel.kind_of("村民 甲", "村民 乙") == "邻居", "甲→乙 是「邻居」")
	_ok(_rel.kind_of("村民 乙", "村民 甲") == "邻居", "乙→甲 也是「邻居」（对称）")
	_ok(not bool(_rel.link("村民 甲", "村民 乙", "同行", "重复")), "重复牵线被拒绝")
	_ok(_rel.total_links() == 1, "一对关系只算一条（实际 %d）" % _rel.total_links())

	var desc: String = _rel.describe("村民 甲")
	_ok(desc.contains("村民 乙") and desc.contains("邻居"), "describe 里能看到对方与关系种类")
	_ok(_rel.sanitize_kind("乱七八糟") == "旧识", "非法关系种类被收敛成「旧识」")


# ---------------------------------------------------------------- 2. 兜底补网

func _section_ensure() -> void:
	_log("== 2. ensure_links 让每个人至少有 1 个熟人，且可重复调用 ==")
	_rel.from_save({})
	_gen.from_save({})
	var names := ["村民 甲", "村民 乙", "村民 丙", "村民 丁", "村民 戊"]
	for n in names:
		_gen.note_name(n, "村民")
	var added: int = _rel.ensure_links(1)
	_ok(added > 0, "补网新增了 %d 条关系" % added)
	var all_ok := true
	for n in names:
		if _rel.relations_of(n).is_empty():
			all_ok = false
	_ok(all_ok, "每个登记过的人至少认得一个别人")
	var again: int = _rel.ensure_links(1)
	_ok(again == 0, "再调一次补网不新增（幂等，实际新增 %d）" % again)


# ---------------------------------------------------------------- 3. 关系上限

func _section_limit() -> void:
	_log("== 3. 每个 NPC 的关系数不超过 MAX_PER_NPC ==")
	_rel.from_save({})
	var hub := "村民 甲"
	for i in 6:
		_rel.link(hub, "路人 %d" % i, "旧识", "认识")
	var cap: int = int(_rel.MAX_PER_NPC)
	_ok(_rel.relations_of(hub).size() == cap,
		"甲的关系数被封顶在 %d（实际 %d）" % [cap, _rel.relations_of(hub).size()])


# ---------------------------------------------------------------- 4. 存档往返

func _section_save() -> void:
	_log("== 4. to_save / from_save 往返一致 ==")
	var before_links: int = _rel.total_links()
	var data: Dictionary = _rel.to_save()
	_rel.from_save({})
	_ok(_rel.total_links() == 0, "清空后关系归零")
	_rel.from_save(data)
	_ok(_rel.total_links() == before_links,
		"读回后关系条数一致（%d vs %d）" % [_rel.total_links(), before_links])
	_ok(_rel.has_relations("村民 甲"), "读回后甲仍有关系")
	_ok(_rel.relations_of("村民 甲").size() <= int(_rel.MAX_PER_NPC), "读回后仍不超上限")


# ---------------------------------------------------------------- 5. 生成新 NPC 自动牵线

func _section_generator() -> void:
	_log("== 5. mock 生成的新 NPC 会自动与已有的人牵上关系 ==")
	_rel.from_save({})
	_gen.from_save({})
	_gen.note_name("村民 甲", "农人")
	_gen.note_name("村民 乙", "铁匠")
	var home: Dictionary = _wd.by_id("village")
	_gen.request_npc(home)
	_ok(_gen.dynamic_npcs.size() == 1, "mock 模式同步生成了 1 个 NPC（实际 %d）" % _gen.dynamic_npcs.size())
	if _gen.dynamic_npcs.size() == 1:
		var new_name := str(_gen.dynamic_npcs[0]["name"])
		_ok(_rel.is_registered(new_name), "新 NPC「%s」已登记进关系网" % new_name)
		_ok(_rel.has_relations(new_name), "新 NPC 自动牵上了关系")


# ---------------------------------------------------------------- 6. AI 产出的关系落地

func _section_ai_relations() -> void:
	_log("== 6. AI 给出的 relations 会被采纳（含非法 target 过滤）==")
	_rel.from_save({})
	_gen.from_save({})
	_gen.note_name("村民 甲", "农人")
	_gen._apply_relations("过客 阿丁", [
		{"target": "村民 甲", "kind": "师徒", "note": "早年跟着学过一手"},
		{"target": "不存在的人", "kind": "亲属", "note": "查无此人"},
		{"target": "过客 阿丁", "kind": "旧识", "note": "不能认识自己"},
	])
	_ok(_rel.kind_of("过客 阿丁", "村民 甲") == "师徒", "AI 给的关系被正常采纳")
	_ok(_rel.total_links() == 1, "非法 target 被过滤，只落地 1 条（实际 %d）" % _rel.total_links())
	_ok(not bool(_rel.known_names().has("不存在的人")), "不存在的人没有被写进关系网")
	# AI 一条都没给时也要兜底牵线
	_gen._apply_relations("过客 阿戊", [])
	_ok(_rel.has_relations("过客 阿戊"), "AI 没给关系时兜底牵上一条")

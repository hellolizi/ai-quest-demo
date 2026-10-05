extends SceneTree
## 一次性验证工具：结婚系统（PlayerProfile 配偶状态 + 存档往返 + 对话界面「求婚」按钮门槛）
## 用法：godot --headless --path . --script res://tools/marriage_probe.gd
##
## 全程离线：只改内存，不写存档文件、不发网络请求。

var _pp                      # PlayerProfile
var _nm                      # NpcMemory
var _dg                      # DialogueGenerator
var _fail := 0


## 对话界面里用的假 NPC：只需能被 `_refresh_marry_btn` 读到 npc_name
class FakeNpc:
	extends Node
	var npc_name := "试婚者"
	var npc_role := "村民"
	var culture_id := ""
	var personality := ""
	var greetings := PackedStringArray(["你好"])


func _initialize() -> void:
	_run()


func _log(s: String) -> void:
	print(s)


func _ok(cond: bool, msg: String) -> void:
	if cond:
		_log("  [PASS] " + msg)
	else:
		_fail += 1
		_log("  [FAIL] " + msg)


func _run() -> void:
	await process_frame
	_pp = root.get_node_or_null("PlayerProfile")
	_nm = root.get_node_or_null("NpcMemory")
	_dg = root.get_node_or_null("DialogueGenerator")
	if _pp == null or _nm == null:
		_log("[probe] 缺少必要 autoload")
		quit(1)
		return
	# 全程离线：别让台词生成器去联网
	if _dg != null:
		_dg.mode = "mock"

	_section_profile()
	_section_save_roundtrip()
	await _section_dialogue_button()

	if _fail == 0:
		_log("== 全部通过 ==")
		quit(0)
	else:
		_log("== 失败 %d 项 ==" % _fail)
		quit(1)


## 1. 配偶状态：默认未婚、首次求婚成功、已有配偶时再求婚被拒
func _section_profile() -> void:
	_log("== 1. 配偶状态 ==")
	_pp.spouse = ""
	_ok(not _pp.is_married(), "初始未婚")
	_ok(_pp.marry("村民 甲"), "首次求婚成功")
	_ok(_pp.is_married(), "is_married() 为真")
	_ok(_pp.spouse == "村民 甲", "配偶记为「村民 甲」")
	_ok(not _pp.marry("村民 乙"), "已有配偶时再求婚被拒")
	_ok(_pp.spouse == "村民 甲", "配偶仍未被改写")
	_ok(not _pp.marry(""), "空名字求婚被拒")


## 2. 新游戏清空配偶 / 存档往返保留配偶
func _section_save_roundtrip() -> void:
	_log("== 2. 新游戏与存档往返 ==")
	_pp.new_game()
	_ok(_pp.spouse == "", "new_game() 清空配偶")

	_pp.marry("村民 甲")
	var snap: Dictionary = _pp.to_save()
	_ok(str(snap.get("spouse", "")) == "村民 甲", "存档里带着配偶字段")

	_pp.spouse = ""
	_ok(_pp.spouse == "", "清空后确认未婚")
	_pp.from_save(snap)
	_ok(_pp.spouse == "村民 甲", "读档恢复配偶")


## 3. 对话界面「求婚」按钮：好感到「信赖」才出现；已婚时给出只读提示
func _section_dialogue_button() -> void:
	_log("== 3. 对话界面求婚按钮 ==")
	var scene := load("res://scenes/ui/dialogue_ui.tscn") as PackedScene
	if scene == null:
		_ok(false, "能加载对话界面场景")
		return
	var dlg = scene.instantiate()
	root.add_child(dlg)
	await process_frame
	_ok(dlg._marry_btn != null, "对话界面里有「求婚」按钮")

	var npc := FakeNpc.new()
	root.add_child(npc)
	dlg._npc = npc
	dlg._understood = true
	var name := npc.npc_name

	# 好感不足：按钮不出现
	_pp.spouse = ""
	_nm.change_affinity(name, -999)
	dlg._refresh_marry_btn()
	_ok(not dlg._marry_btn.visible, "好感不足时求婚按钮不出现")

	# 好感到「信赖」：按钮出现且可点
	_nm.change_affinity(name, 999)
	_ok(_nm.affinity(name) >= int(_nm.LEVEL_TRUST), "好感已达信赖门槛（%d）" % _nm.affinity(name))
	dlg._refresh_marry_btn()
	_ok(dlg._marry_btn.visible, "好感达标后求婚按钮出现")
	_ok(not dlg._marry_btn.disabled, "未婚时按钮可点")
	_ok(dlg._marry_btn.text == "求婚", "未婚时按钮文案为「求婚」")

	# 点一下求婚：界面真的调用 PlayerProfile 结婚
	dlg._on_marry_pressed()
	_ok(_pp.spouse == name, "点「求婚」后成为伴侣")
	_ok(dlg._marry_btn.disabled and dlg._marry_btn.text == "已是你的伴侣", "按钮变为「已是你的伴侣」且不可再点")

	# 换一个人看：已有伴侣时给出只读提示
	var other := FakeNpc.new()
	other.npc_name = "试婚者 乙"
	root.add_child(other)
	dlg._npc = other
	_nm.change_affinity(other.npc_name, 999)
	dlg._refresh_marry_btn()
	_ok(dlg._marry_btn.visible and dlg._marry_btn.disabled, "已有伴侣时对他人只给只读提示")
	_ok(dlg._marry_btn.text == "你已有伴侣", "他人视角文案为「你已有伴侣」")
	_ok(_pp.spouse == name, "此时不会改掉原配偶")

	dlg.queue_free()
	npc.queue_free()
	other.queue_free()

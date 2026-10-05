extends SceneTree
## T13 离线探针：玩家详细状态栏 + NPC 简略状态栏。
## 不联网、不启动主场景——只把 HUD 脚本单独跑起来，喂假数据，检查：
##   1) HUD 建出玩家面板全部字段，且不报错；
##   2) set_npc_focus / clear_npc_focus / npc_focus 行为正确；
##   3) NPC 的 focus_changed 在「进入 / 离开 / 进屋」三种情况下都如实广播；
##   4) hud.gd / npc.gd / main.gd / dialogue_ui.gd 都能被编译器加载。

const HUD_PATH := "res://scripts/hud.gd"

var _pass := 0
var _fail := 0


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame

	var hud := root.get_node_or_null("PlayerProfile")   # 触发 autoload 就位
	if hud == null:
		_ok(false, "autoload PlayerProfile 已就位")
	else:
		_ok(true, "autoload PlayerProfile 已就位")

	# 生成器全走 mock，保证一个 HTTP 都不发
	_set_mock("PortraitGenerator")
	_set_mock("WalkSheetGenerator")
	_set_mock("PortraitLibrary")
	_set_mock("NpcMemory")

	await _section_compile()
	await _section_hud()
	await _section_focus_signal()
	await _section_theme()

	print("T13 探针：PASS %d / FAIL %d" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _set_mock(name: String) -> void:
	var n := root.get_node_or_null(name)
	if n != null and "mode" in n:
		n.mode = "mock"


## 4 个脚本都必须能编译（改坏了这里立刻报错）
func _section_compile() -> void:
	for path in [
		"res://scripts/hud.gd",
		"res://scripts/npc.gd",
		"res://scripts/main.gd",
		"res://scripts/dialogue_ui.gd",
	]:
		var s = load(path)
		_ok(s != null, "可加载 %s" % path)


## HUD 面板与 NPC 状态栏
func _section_hud() -> void:
	var hud_script = load(HUD_PATH)
	if hud_script == null:
		_ok(false, "可实例化 hud.gd")
		return
	var hud = hud_script.new()
	root.add_child(hud)
	await process_frame

	_ok(hud._hp_text != null, "玩家面板：血条文字已建")
	_ok(hud._gold_text != null, "玩家面板：金币行已建")
	_ok(hud._weapon_text != null, "玩家面板：武器行已建")
	_ok(hud._dist_text != null, "玩家面板：路程行已建")
	_ok(hud._quest_text != null, "玩家面板：任务行已建")
	_ok(hud._spouse_text != null, "玩家面板：伴侣行已建")
	_ok(hud._lang_text != null, "玩家面板：语言行已建")
	_ok(hud._npc_panel != null and not hud._npc_panel.visible, "NPC 面板初始隐藏")

	# 刷新一遍，确认原文/数值都填上了，不报错
	hud._refresh_profile()
	_ok(hud._dist_text.text.contains("米"), "路程行显示「米」：[%s]" % hud._dist_text.text)
	_ok(hud._quest_text.text.contains("进行中"), "任务行显示「进行中」：[%s]" % hud._quest_text.text)
	_ok(hud._spouse_text.text.contains("伴侣"), "伴侣行显示：[%s]" % hud._spouse_text.text)
	_ok(hud._lang_text.text.contains("语言"), "语言行显示：[%s]" % hud._lang_text.text)

	# 喂一个假 NPC
	var fake := FakeNpc.new()
	fake.npc_name = "测试美人"
	fake.npc_role = "福地住客"
	root.add_child(fake)
	hud.set_npc_focus(fake)
	await process_frame
	_ok(hud._npc_panel.visible, "set_npc_focus 后 NPC 面板可见")
	_ok(hud._npc_name_text.text == "测试美人", "NPC 名显示：[%s]" % hud._npc_name_text.text)
	_ok(hud._npc_role_text.text.contains("福地住客"), "NPC 身份显示：[%s]" % hud._npc_role_text.text)
	_ok(hud._npc_rel_text.text.contains("关系"), "NPC 关系显示：[%s]" % hud._npc_rel_text.text)
	_ok(hud.npc_focus() == fake, "npc_focus() 返回当前 NPC")

	hud.clear_npc_focus()
	await process_frame
	_ok(not hud._npc_panel.visible, "clear_npc_focus 后 NPC 面板隐藏")
	_ok(hud.npc_focus() == null, "clear 后 npc_focus() 为 null")

	hud.queue_free()
	fake.queue_free()


## NPC 的 focus_changed：进入 / 离开 / 进屋
func _section_focus_signal() -> void:
	var scene: PackedScene = load("res://scenes/npc.tscn")
	if scene == null:
		_ok(false, "可加载 npc.tscn")
		return
	_ok(true, "可加载 npc.tscn")

	var npc: Node2D = scene.instantiate()
	npc.npc_name = "探针甲"
	npc.npc_role = "村民"
	root.add_child(npc)
	await process_frame

	var events: Array = []
	npc.focus_changed.connect(func(who: Node, focused: bool) -> void:
		events.append([who, focused]))

	var player := Node2D.new()
	player.name = "Player"
	root.add_child(player)

	npc._on_body_entered(player)
	_ok(events.size() == 1 and events[0][1] == true, "进入范围：广播 focus=true")

	npc._on_body_exited(player)
	_ok(events.size() == 2 and events[1][1] == false, "离开范围：广播 focus=false")

	# 再进入一次，然后直接进屋：应当补一条 focus=false（人会从画面消失）
	npc._on_body_entered(player)
	events.clear()
	npc._enter_home()
	var got_false := false
	for e in events:
		if e[1] == false:
			got_false = true
	_ok(got_false, "进屋：广播 focus=false")
	_ok(not npc.visible, "进屋后 NPC 隐藏")

	npc.queue_free()
	player.queue_free()


## 假 NPC：只要名字和身份两样，够 HUD 面板用
class FakeNpc extends Node:
	var npc_name := ""
	var npc_role := ""


## T14：全局 UI 主题能建出来、能挂到 UI 层下、控件确实继承到样式
func _section_theme() -> void:
	var theme_script = load("res://scripts/ui_theme.gd")
	if theme_script == null:
		_ok(false, "可加载 ui_theme.gd")
		return
	_ok(true, "可加载 ui_theme.gd")

	var theme = theme_script.build()
	_ok(theme != null, "主题已构建")
	_ok(theme.default_font_size == 15, "默认字号 = 15")
	_ok(theme.get_stylebox("panel", "Panel") != null, "Panel 面板样式已设")
	_ok(theme.get_stylebox("normal", "Button") != null, "Button 常态样式已设")
	_ok(theme.get_stylebox("hover", "Button") != null, "Button 悬停样式已设")
	_ok(theme.get_stylebox("normal", "LineEdit") != null, "LineEdit 样式已设")

	# 挂到一棵小界面上，验证子控件确实继承
	var ui := Control.new()
	root.add_child(ui)
	var panel := Panel.new()
	ui.add_child(panel)
	var btn := Button.new()
	panel.add_child(btn)
	theme_script.apply(ui)
	await process_frame
	_ok(panel.theme != null, "apply 后面板拿到主题")
	_ok(btn.get_theme_stylebox("normal") != null, "按钮继承到常态样式")
	_ok(btn.get_theme_color("font_color") == Color(0.90, 0.91, 0.96), "按钮继承到字体颜色")

	ui.queue_free()


func _ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS  ", msg)
	else:
		_fail += 1
		print("  FAIL  ", msg)

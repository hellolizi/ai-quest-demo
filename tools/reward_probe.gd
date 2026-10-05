extends SceneTree
## 一次性验证工具：奖励图标（库 + 生成器 + 完成提示条）
## 用法：godot --headless --path . --script res://tools/reward_probe.gd
##
## 会往 res://generated/rewards/ 写一张测试图，测完删掉并还原索引，不污染玩家数据。

const TEST_TAG := "探针奖励"
const INDEX_PATH := "res://generated/rewards/index.json"

var _lib                      # RewardLibrary
var _gen                      # RewardIconGenerator
var _backup_index := ""
var _backup_exists := false
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
	_lib = root.get_node_or_null("RewardLibrary")
	_gen = root.get_node_or_null("RewardIconGenerator")
	if _lib == null:
		push_error("[probe] 缺少 RewardLibrary autoload")
		quit(1)
		return
	_ok(_gen != null, "RewardIconGenerator autoload 已注册")
	var lc: Node = root.get_node_or_null("LlmConfig")
	_ok(lc != null and str(_gen.mode) == str(lc.image_mode), "生成器收到了生图配置广播（mode）")
	_ok(lc != null and str(_gen.provider) == str(lc.image_provider), "provider 已同步")
	# 探针绝不能真去调生图接口（会花钱）：先把生成器强制关掉
	_gen.mode = "off"
	_backup()

	print("== 1. 归类词典：文字不同但能共用一张图 ==")
	_ok(_lib.category_of("金子") == "gold", "金子 → gold")
	_ok(_lib.category_of("金块") == "gold", "金块 → gold")
	_ok(_lib.category_of("金币") == "gold", "金币 → gold")
	_ok(_lib.category_of("黄金") == "gold", "黄金 → gold")
	_ok(_lib.canonical_tag("金子") == _lib.canonical_tag("金块"), "金子 / 金块 落同一个标签")
	_ok(_lib.canonical_tag("金子") == "cat_gold", "标签形如 cat_gold")
	_ok(_lib.category_of("红宝石") == "gem", "红宝石 → gem（宝石比石长，不被矿石抢）")
	_ok(_lib.category_of("老张的谢礼") == "gift", "老张的谢礼 → gift")
	_ok(_lib.category_of("探针奖励") == "", "词典没收录的名字归空")
	_ok(_lib.canonical_tag("金 子！") == "cat_gold", "归一化后仍落 gold")

	print("== 2. rewards 拆条 ==")
	var items: Array = _lib.items_of_rewards({"gold": 100, "item": "老张的谢礼"})
	_ok(items.size() == 2, "拆出 2 条（实际 %d）" % items.size())
	_ok(str(items[0].get("text", "")) == "金币" and int(items[0].get("amount", 0)) == 100, "金币 100")
	_ok(str(items[0].get("tag", "")) == "cat_gold", "金币用 cat_gold")
	_ok(str(items[1].get("tag", "")) == "cat_gift", "谢礼归 cat_gift（省生图）")
	_ok(_lib.items_of_rewards({}).is_empty(), "空 rewards 拆出空")

	print("== 3. 入库 / 读盘 / 别名复用 ==")
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.9, 0.8, 0.3, 1.0))
	var reg: bool = _lib.register(TEST_TAG, img, {"name": TEST_TAG, "category": ""})
	_ok(reg, "register 成功")
	_ok(FileAccess.file_exists(_lib.path_for(TEST_TAG)), "icon.png 已落盘")
	_ok(_lib.has(TEST_TAG), "has 认这张图")
	_ok(_lib.get_texture(TEST_TAG) != null, "get_texture 拿到贴图")
	_ok(_lib.resolve(TEST_TAG) == TEST_TAG, "resolve 命中自己")
	_lib.add_alias(TEST_TAG, "月之石")
	_ok(_lib.resolve("月之石") == TEST_TAG, "别名也能复用（月之石 → 探针奖励）")
	_ok(FileAccess.file_exists(INDEX_PATH), "index.json 已写")
	_lib._textures.clear()
	_ok(_lib.get_texture(TEST_TAG) != null, "清掉内存缓存后能重新读盘")
	_ok(_lib.catalog_for_llm().find(TEST_TAG) != -1, "给模型的清单里带上了这张图")
	_lib.toggle_enabled(TEST_TAG)
	_ok(not _lib.is_enabled(TEST_TAG), "toggle 能停用")
	_lib.set_enabled(TEST_TAG, true)
	_ok(_lib.is_enabled(TEST_TAG), "再启用回来")

	print("== 4. 生成器：提示词 / 尺寸 / 语义判定 ==")
	var prompt: String = _gen._build_prompt({"name": "金子", "category": "gold"})
	_ok(prompt.find("金子") != -1, "提示词带上奖励名")
	_ok(prompt.find("钱财") != -1, "提示词带上类别名")
	var old_provider: String = _gen.provider
	_gen.provider = "siliconflow"
	_ok(_gen._icon_size() == "1024x1024", "硅基流动图标用方形 1024x1024")
	_gen.provider = "ark_plan"
	_gen.size = ""
	_ok(_gen._icon_size() == "1K", "方舟图标用 1K")
	_gen.provider = old_provider
	_ok(_gen._parse_tag("我觉得 探针奖励 可以") == TEST_TAG, "从回复里认出既有标签")
	_ok(_gen._parse_tag("NEW") == "", "NEW 表示要新画")
	_ok(_gen._parse_tag("随便说点啥") == "", "说不清也当新画")

	print("== 5. 关掉生图时：只给标签、不排队 ==")
	_ok(not _gen.is_on(), "强制关掉后 is_on() 为 false")
	var t: String = _gen.request("金子")
	_ok(t == "cat_gold", "request 返回大类标签")
	_ok(not _gen.is_queued("cat_gold"), "没开生图就不排队")
	_ok(_gen.request("探针奖励") == TEST_TAG, "已有图的照样返回标签")

	print("== 6. 完成提示条 ==")
	var main_scene = load("res://scenes/main.tscn")
	_ok(main_scene != null and (main_scene as PackedScene).can_instantiate(), "main.tscn 能加载（引用没断）")
	var ps: PackedScene = load("res://scenes/ui/reward_popup.tscn")
	_ok(ps != null, "reward_popup.tscn 能加载")
	var popup: Control = ps.instantiate()
	root.add_child(popup)
	await process_frame
	popup._on_completed({"title": "测试任务", "rewards": {"gold": 100, "item": "老张的谢礼"}})
	_ok(popup._box.visible, "弹条显示出来了")
	_ok(popup._items.get_child_count() == 2, "两条奖励各一行（实际 %d）" % popup._items.get_child_count())
	_ok(popup._quest.text == "测试任务", "任务名写对了")
	var row: Node = popup._items.get_child(0)
	_ok(row.get_child_count() == 2, "一行 = 图标方块 + 文字列")
	popup.queue_free()

	_cleanup()
	print("----------------------------------------")
	if _fail == 0:
		print("全部通过")
	else:
		print("失败 %d 项" % _fail)
	quit(0 if _fail == 0 else 1)


# ---------------------------------------------------------------- 备份 / 还原

func _backup() -> void:
	if FileAccess.file_exists(INDEX_PATH):
		_backup_exists = true
		var f := FileAccess.open(INDEX_PATH, FileAccess.READ)
		if f != null:
			_backup_index = f.get_as_text()
			f.close()


func _cleanup() -> void:
	_lib.remove(TEST_TAG)
	if _backup_exists:
		var f := FileAccess.open(INDEX_PATH, FileAccess.WRITE)
		if f != null:
			f.store_string(_backup_index)
			f.close()
	elif FileAccess.file_exists(INDEX_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(INDEX_PATH))
	print("[probe] 已清理测试图与索引")

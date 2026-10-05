extends Node
## 全局大模型配置（Autoload 名字：LlmConfig）
##
## 配置读取顺序（后面的覆盖前面的）：
##   1. res://llm_config.cfg —— 随游戏分发的默认值（开发时填的那份）；
##   2. user://llm_config.cfg —— 玩家在「设置」界面里填的，写在这里，不污染游戏本体。
##
## 之所以要单独抽一个 autoload：以前 7 个生成器各自读 res://llm_config.cfg，
## 玩家想换 Key 就得手动改文件。现在改成：设置界面 → save_settings() → 写 user:// → broadcast()，
## 由这里把 mode/api_base/api_key/model 一键推送给所有生成器，立刻生效、无需重启。

const DEFAULT_PATH := "res://llm_config.cfg"
const USER_PATH := "user://llm_config.cfg"

## 需要接收配置的生成器 autoload（它们的字段名统一是 mode/api_base/api_key/model）
const TARGETS := [
	"QuestManager", "LocationGenerator", "SceneDecorator",
	"NpcMemory", "DialogueGenerator", "NpcGenerator", "StoryDirector",
]

## 生图生成器（字段名是 mode/provider/api_base/api_key/model/size/remove_bg）
## 立绘、房屋、奖励图标共用同一套生图配置。
const IMAGE_TARGETS := ["PortraitGenerator", "BuildingGenerator", "RewardIconGenerator", "WalkSheetGenerator"]

## 两家生图平台的默认参数：设置界面里选平台后自动带出这套默认值。
## 参数名两家不一样（硅基流动 image_size / 方舟 size），这里按各自习惯存。
const IMAGE_PRESETS := {
	"siliconflow": {
		"label": "硅基流动 SiliconFlow",
		"base": "https://api.siliconflow.cn/v1",
		"model": "Qwen/Qwen-Image",
		"size": "768x1024",
	},
	"ark_plan": {
		"label": "火山方舟 Agent Plan",
		"base": "https://ark.cn-beijing.volces.com/api/plan/v3",
		"model": "doubao-seedream-5-0-pro-260628",
		"size": "1K",
	},
	"dashscope": {
		"label": "阿里云百炼（通义万相/千问图像）",
		"base": "https://maas.qianwenaiapi.com/compatible-mode/v1",
		"model": "qwen-image-3.0",
		"size": "1024x1024",
	},
}

var mode := "mock"
var api_base := "https://api.openai.com/v1"
var api_key := ""
var model := "gpt-4o-mini"

# ---- AI 立绘（文本模型之外的独立一套配置，可以关掉只用程序化小人）----
## off = 关；api = 走生图接口
var image_mode := "off"
var image_provider := "siliconflow"
var image_api_base := "https://api.siliconflow.cn/v1"
var image_api_key := ""
var image_model := "Qwen/Qwen-Image"
var image_size := "768x1024"
var image_remove_bg := true


func _ready() -> void:
	_load()
	broadcast()


func _load() -> void:
	if FileAccess.file_exists(DEFAULT_PATH):
		_apply_file(DEFAULT_PATH)
	else:
		push_warning("[LlmConfig] 未找到 %s，使用离线 mock 模式" % DEFAULT_PATH)
	if FileAccess.file_exists(USER_PATH):
		_apply_file(USER_PATH)


func _apply_file(path: String) -> void:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		push_warning("[LlmConfig] 解析失败：%s" % path)
		return
	mode = str(cfg.get_value("llm", "mode", mode))
	api_base = str(cfg.get_value("llm", "api_base", api_base))
	api_key = str(cfg.get_value("llm", "api_key", api_key))
	model = str(cfg.get_value("llm", "model", model))
	image_mode = str(cfg.get_value("image", "mode", image_mode))
	image_provider = str(cfg.get_value("image", "provider", image_provider))
	image_api_base = str(cfg.get_value("image", "api_base", image_api_base))
	image_api_key = str(cfg.get_value("image", "api_key", image_api_key))
	image_model = str(cfg.get_value("image", "model", image_model))
	image_size = str(cfg.get_value("image", "size", image_size))
	image_remove_bg = bool(cfg.get_value("image", "remove_bg", image_remove_bg))


## 把当前配置刷进某个生成器
func apply_to(target: Node) -> void:
	if target == null:
		return
	target.mode = mode
	target.api_base = api_base
	target.api_key = api_key
	target.model = model


## 把立绘配置刷进立绘生成器
func apply_image_to(target: Node) -> void:
	if target == null:
		return
	target.mode = image_mode
	target.provider = image_provider
	target.api_base = image_api_base
	target.api_key = image_api_key
	target.model = image_model
	target.size = image_size
	target.remove_bg = image_remove_bg


## 把当前配置推给所有生成器
func broadcast() -> void:
	for key in TARGETS:
		apply_to(get_node_or_null("/root/%s" % key))
	for key in IMAGE_TARGETS:
		apply_image_to(get_node_or_null("/root/%s" % key))


## 设置界面点「保存」时调用：写进 user:// 并立刻热更新到所有生成器
func save_settings(p_mode: String, p_base: String, p_key: String, p_model: String) -> bool:
	mode = p_mode.strip_edges()
	api_base = p_base.strip_edges()
	api_key = p_key.strip_edges()
	model = p_model.strip_edges()
	return _persist()


## 同上，但保存的是立绘那一套配置
func save_image_settings(p_mode: String, p_provider: String, p_base: String, p_key: String,
		p_model: String, p_size: String, p_remove_bg: bool) -> bool:
	image_mode = p_mode.strip_edges()
	image_provider = p_provider.strip_edges()
	image_api_base = p_base.strip_edges()
	image_api_key = p_key.strip_edges()
	image_model = p_model.strip_edges()
	image_size = p_size.strip_edges()
	image_remove_bg = p_remove_bg
	return _persist()


## 两个段一起写，免得保存文本设置时把立绘设置冲掉
func _persist() -> bool:
	var cfg := ConfigFile.new()
	cfg.set_value("llm", "mode", mode)
	cfg.set_value("llm", "api_base", api_base)
	cfg.set_value("llm", "api_key", api_key)
	cfg.set_value("llm", "model", model)
	cfg.set_value("image", "mode", image_mode)
	cfg.set_value("image", "provider", image_provider)
	cfg.set_value("image", "api_base", image_api_base)
	cfg.set_value("image", "api_key", image_api_key)
	cfg.set_value("image", "model", image_model)
	cfg.set_value("image", "size", image_size)
	cfg.set_value("image", "remove_bg", image_remove_bg)
	var err := cfg.save(USER_PATH)
	if err != OK:
		push_warning("[LlmConfig] 保存设置失败：%s" % error_string(err))
		return false
	broadcast()
	print("[LlmConfig] 设置已保存到 %s（文本=%s，立绘=%s/%s）" % [USER_PATH, mode, image_mode, image_provider])
	return true

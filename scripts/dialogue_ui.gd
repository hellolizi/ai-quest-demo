extends Control
## 对话界面：跟 NPC 聊天、聊出他/她的难处、接任务，办完事再回来复命领奖励。
##
## 设计要点（对应「不要一看见 NPC 就是去领任务」）：
##   1. 聊天是主入口——「聊聊近况」「打听传闻」都只是聊天，不产生任务；
##   2. 只有主动问「有什么要帮忙的」，NPC 才会亲口说出自己的难处，并把它变成一件任务；
##   3. 事办完了不算完，要回到委托人这里点「复命交差」才发奖励；
##   4. 每次互动都会改好感，AI 会在关键节点重写「对玩家的印象」（见 NpcMemory）；
##   5. 玩家可以自由输入想说的话（输入框回车发送），NPC 会照着自己的性子回应，
##      他的情绪（友好 / 中立 / 不悦）会反过来影响好感。

signal closed

@onready var _speaker_label: Label = $Panel/Speaker
@onready var _relation_label: Label = $Panel/Relation
@onready var _body_label: RichTextLabel = $Panel/Body
@onready var _say_input: LineEdit = $Panel/InputRow/SayInput
@onready var _send_btn: Button = $Panel/InputRow/SendBtn
@onready var _topic_btn: Button = $Panel/Buttons/TopicBtn
@onready var _rumor_btn: Button = $Panel/Buttons/RumorBtn
@onready var _help_btn: Button = $Panel/Buttons/HelpBtn
@onready var _accept_btn: Button = $Panel/Buttons/AcceptBtn
@onready var _report_btn: Button = $Panel/Buttons/ReportBtn
@onready var _close_btn: Button = $Panel/Buttons/CloseBtn
@onready var _learn_btn: Button = $Panel/Buttons/LearnBtn
@onready var _gift_btn: Button = $Panel/Buttons/GiftBtn
@onready var _marry_btn: Button = $Panel/Buttons/MarryBtn
@onready var _input_row: HBoxContainer = $Panel/InputRow

## 交给 DialogueGenerator 的「话题」，决定 AI 这次该说什么
const TOPIC_SMALL_TALK := "玩家想跟你拉拉家常，问问你最近过得怎么样、村里有没有什么新鲜事。"
const TOPIC_NEED := "玩家问你是不是有什么需要帮忙的地方。请用自己的口吻说出眼下最让你发愁的一件麻烦（这将成为一件任务的起因），只说自己的难处，不要直接说「请你帮我做任务」。"
const TOPIC_THANKS := "玩家刚刚帮你把他答应的事情办成了，你向他道谢，并说一句你此刻的心情。"
const TOPIC_MARRY := "玩家刚刚向你求婚，你答应了。请用你自己的口吻说一句此刻的心情，可以亲密、暧昧一点，但不要露骨。"
## 福地住客被问「要帮忙吗」时的婉拒：他们富得流油、难得求人
const TOPIC_REFUSE := "玩家问你是不是有什么需要帮忙的地方。你如今日子过得极好、什么都不缺，想了想也没什么需要外人插手的事，于是客气地婉拒了。请用自己的口吻说一句婉拒的话，不要提出任何请求，也不要许任何好处。"
## 通天福地的住客出手极阔，却难得开口求人：只有这么小的概率会真的派发任务，
## 其余时候都只是客气地婉拒。
const TIANFU_QUEST_CHANCE := 0.25

## 离线（AI 不可用）时的兜底台词。每个入口配一套专属的，免得「问难处」却答了句问候语。
var LOCAL_SMALL_TALK := PackedStringArray([
	"还能咋样，日子一天天过，跟往常一样。",
	"最近啊……村里还算太平，就是琐事多。",
	"没啥大事。倒是你，看着像是走了不少路。",
	"老样子。你要是不嫌闷，就多坐会儿。",
])
var LOCAL_NEED := PackedStringArray([
	"唉，说起来还真有件事压在心口……你要是肯帮，我记你一辈子好。",
	"有件麻烦事，我一直没找到合适的人去办。你既然问了，我就厚着脸皮说了。",
	"心里头是有桩事放不下，只是话到嘴边，又怕给你添麻烦。",
	"要帮忙的地方……也不是没有，就看你有不有这个心了。",
])
var LOCAL_THANKS := PackedStringArray([
	"多谢你了，这份情我记下了。",
	"你可是帮了我大忙，往后有事尽管开口。",
	"有你这句话，我心里就踏实了。",
	"这事多亏了你，真不知道怎么谢才好。",
])
## 玩家自由说话、AI 不可用时的兜底回应
var LOCAL_FREE := PackedStringArray([
	"嗯，你说的这话，我记下了。",
	"你这个说法，倒是有意思。",
	"我听着呢，你接着说。",
	"哦？你倒是提醒我了。",
])
## 答应求婚、AI 不可用时的兜底台词
var LOCAL_MARRY := PackedStringArray([
	"你这人……真是的，我等这句话，等了好久了。",
	"往后的日子，你走到哪儿，我就跟到哪儿。",
	"好。从今往后，风雪也好、远路也好，我都陪你走。",
	"……这门亲事，我认了。你可别反悔。",
])
## 福地住客婉拒「要帮忙吗」、AI 不可用时的兜底台词
var LOCAL_REFUSE := PackedStringArray([
	"帮忙？我这日子过得好好的，哪有什么要劳烦你的。",
	"有心了。不过我这儿的难处，还不至于让外人插手。",
	"你的好意我心领了，眼下倒真没什么事能请你出手。",
	"唉，我这人挑剔，寻常小事也不愿假手于人。你且去逛你的吧。",
])

var _npc: Node = null
var _current_quest: Dictionary = {}
## 正在等 AI 说的那句是干什么用的："" / "greeting" / "topic" / "need" / "refuse" / "thanks" / "free"
var _pending_say := ""
## 复命后要显示的奖励文案
var _report_text := ""
## 当前这位 NPC 说的语言，以及玩家听不听得懂
var _lang := ""
var _understood := true


func _ready() -> void:
	visible = false
	_topic_btn.pressed.connect(_on_topic_pressed)
	_rumor_btn.pressed.connect(_on_rumor_pressed)
	_help_btn.pressed.connect(_on_help_pressed)
	_accept_btn.pressed.connect(_on_accept_pressed)
	_report_btn.pressed.connect(_on_report_pressed)
	_close_btn.pressed.connect(close)
	_learn_btn.pressed.connect(_on_learn_pressed)
	_gift_btn.pressed.connect(_on_gift_pressed)
	_marry_btn.pressed.connect(_on_marry_pressed)
	# 按钮的 pressed 不带参数，而 LineEdit 的 text_submitted 带一个字符串；
	# 所以处理函数给了默认值，两种来源都能用
	_send_btn.pressed.connect(_on_say_submitted)
	_say_input.text_submitted.connect(_on_say_submitted)
	QuestManager.quest_generated.connect(_on_quest_generated)
	QuestManager.quest_reached.connect(_on_quest_reached)
	LocationGenerator.location_created.connect(_on_location_created)
	LocationGenerator.location_failed.connect(_on_location_failed)
	DialogueGenerator.line_ready.connect(_on_line_ready)
	NpcMemory.impression_changed.connect(_on_impression_changed)
	_reset_buttons()


func open(npc: Node) -> void:
	_npc = npc
	_current_quest = {}
	_report_text = ""
	_say_input.text = ""
	# 这个人说的是不是你的母语？听不懂就得先学，或者用通译符
	_lang = CultureData.language_of_culture(npc.culture_id)
	_understood = PlayerProfile.understands(npc.culture_id, npc.npc_name)
	_reset_buttons()
	_apply_language_state()
	_speaker_label.text = "%s（%s）" % [npc.npc_name, npc.npc_role]
	if not _understood:
		_speaker_label.text += "　[%s]" % CultureData.language_name(_lang)
	_refresh_relation()
	# 先用 NPC 自带的台词顶上，AI 那句没准备好时不至于空着界面；
	# 正常情况下玩家靠近时就已经预取好了，这里会直接显示 AI 现编的那句
	var first_line := _local_line(npc)
	_body_label.text = _compose(first_line) if _understood else _unintelligible_block(first_line)
	PlayerProfile.ui_open = true
	visible = true
	_pending_say = "greeting"
	DialogueGenerator.request_line(npc.npc_name, npc.npc_role, npc.personality, npc.greetings)
	if _understood:
		_say_input.grab_focus()


func close() -> void:
	visible = false
	_pending_say = ""
	if _npc != null:
		# 还在路上的那句别浪费，留在缓存里，下次进来说不定就用上了
		DialogueGenerator.drop_waiter(_npc.npc_name)
	PlayerProfile.ui_open = false
	closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	# 对话开着时，Esc 直接结束（输入框正在打字时，Esc 会先被它用来取消焦点）
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		close()


func _reset_buttons() -> void:
	_topic_btn.disabled = false
	_rumor_btn.disabled = false
	_help_btn.disabled = false
	_accept_btn.disabled = true
	_report_btn.disabled = true
	_topic_btn.visible = true
	_rumor_btn.visible = true
	_help_btn.visible = true
	_accept_btn.visible = true
	_report_btn.visible = true


## 按「听不听得懂」调整界面：听不懂时收起所有要听懂才能用的入口，
## 只留「跟他学这儿的话」和「把通译符赠给他」两条路。
func _apply_language_state() -> void:
	if _understood:
		_learn_btn.visible = false
		_gift_btn.visible = false
		_input_row.visible = true
		_refresh_report_btn()
		return
	_topic_btn.visible = false
	_rumor_btn.visible = false
	_help_btn.visible = false
	_accept_btn.visible = false
	_report_btn.visible = false
	_input_row.visible = false
	_learn_btn.visible = true
	_gift_btn.visible = true
	_refresh_learn_btn()
	_refresh_gift_btn()


func _refresh_learn_btn() -> void:
	if _lang == "":
		_learn_btn.disabled = true
		_learn_btn.visible = false
		return
	var lang_name := CultureData.language_name(_lang)
	if PlayerProfile.knows_language(_lang):
		_learn_btn.disabled = true
		_learn_btn.text = "已经会说%s了" % lang_name
	else:
		_learn_btn.disabled = false
		_learn_btn.text = "跟他学%s（%d/%d）" % [
			lang_name, PlayerProfile.lesson_count(_lang), PlayerProfile.LESSONS_TO_LEARN,
		]


func _refresh_gift_btn() -> void:
	if _npc == null:
		_gift_btn.disabled = true
		return
	if PlayerProfile.npc_has_translator(_npc.npc_name):
		_gift_btn.disabled = true
		_gift_btn.text = "已把通译符赠给他"
	elif PlayerProfile.has_translator():
		_gift_btn.disabled = false
		_gift_btn.text = "把通译符赠给他"
	else:
		_gift_btn.disabled = true
		_gift_btn.text = "通译符（身上没有）"


## 「跟他学这儿的话」：学满 LESSONS_TO_LEARN 次就掌握了
func _on_learn_pressed() -> void:
	if _npc == null or _lang == "":
		return
	var count := PlayerProfile.add_lesson(_lang)
	var lang_name := CultureData.language_name(_lang)
	if PlayerProfile.knows_language(_lang):
		_understood = true
		_reset_buttons()
		_apply_language_state()
		_refresh_relation()
		_body_label.text = "[b]你跟着 %s 学了 %s，现在已经能听懂他说话了。[/b]" % [_npc.npc_name, lang_name]
		# 让 NPC 重新用你听得懂的话打个招呼
		_pending_say = "greeting"
		DialogueGenerator.request_line(_npc.npc_name, _npc.npc_role, _npc.personality, _npc.greetings)
	else:
		_refresh_learn_btn()
		_body_label.text = "[i]……[/i]\n\n[color=#8fd18f]你跟着 %s 学了一句%s，好像有点懂了。（%d/%d）[/color]" % [
			_npc.npc_name, lang_name, count, PlayerProfile.LESSONS_TO_LEARN,
		]


## 「把通译符赠给他」：他从此听懂你的话，你也就听懂他的回话
func _on_gift_pressed() -> void:
	if _npc == null:
		return
	if not PlayerProfile.gift_translator(_npc.npc_name):
		_refresh_gift_btn()
		return
	_understood = true
	_reset_buttons()
	_apply_language_state()
	_refresh_relation()
	_body_label.text = "[b]你把通译符赠给了 %s。他听懂你的话，你也听懂他了。[/b]" % _npc.npc_name
	_pending_say = "greeting"
	DialogueGenerator.request_line(_npc.npc_name, _npc.npc_role, _npc.personality, _npc.greetings)


## 「求婚」：好感到「信赖」才能开口。答应了就成了伴侣，往后这个人一直跟着你。
func _on_marry_pressed() -> void:
	if _npc == null:
		return
	if NpcMemory.affinity(_npc.npc_name) < NpcMemory.LEVEL_TRUST:
		return
	if PlayerProfile.is_married():
		_refresh_marry_btn()
		return
	if not PlayerProfile.marry(_npc.npc_name):
		_refresh_marry_btn()
		return
	NpcMemory.change_affinity(_npc.npc_name, 5, "答应了和你结为伴侣")
	_refresh_relation()
	_pending_say = "marry"
	_body_label.text = _compose_marry(_local_marry())
	DialogueGenerator.request_line(_npc.npc_name, _npc.npc_role, _npc.personality, LOCAL_MARRY, TOPIC_MARRY)


## 听不懂时显示的正文：外语原文 + 一句提示
func _unintelligible_block(text: String) -> String:
	var shown := CultureData.foreignize(text, _lang)
	return "[i]%s[/i]\n\n[color=#e0a0a0]（%s，你听不太懂。要么「跟他学这儿的话」，要么把通译符赠给他。）[/color]" % [
		_escape(shown), CultureData.language_name(_lang),
	]


func _refresh_relation() -> void:
	if _npc == null:
		return
	var text := NpcMemory.label_of(_npc.npc_name)
	var imp := NpcMemory.impression(_npc.npc_name)
	if imp != "":
		text += "　印象：%s" % imp
	if PlayerProfile.spouse == _npc.npc_name:
		text += "　[b]伴侣[/b]"
	_relation_label.text = text
	_refresh_marry_btn()


## 「求婚」按钮：听不懂、或好感还没到「信赖」，就不拿出来；
## 已经有伴侣时（本人 / 他人）只给出只读提示。
func _refresh_marry_btn() -> void:
	if _npc == null or not _understood:
		_marry_btn.visible = false
		return
	var name: String = _npc.npc_name
	if PlayerProfile.spouse == name:
		_marry_btn.visible = true
		_marry_btn.disabled = true
		_marry_btn.text = "已是你的伴侣"
		return
	if NpcMemory.affinity(name) < NpcMemory.LEVEL_TRUST:
		_marry_btn.visible = false
		return
	_marry_btn.visible = true
	if PlayerProfile.is_married():
		_marry_btn.disabled = true
		_marry_btn.text = "你已有伴侣"
	else:
		_marry_btn.disabled = false
		_marry_btn.text = "求婚"


## 只有「把事办完了、而且这个 NPC 就是委托人」时才让点复命
func _refresh_report_btn() -> void:
	if _npc == null:
		_report_btn.disabled = true
		return
	_report_btn.disabled = QuestManager.reportable_quest_for(_npc.npc_name).is_empty()


# ---------------------------------------------------------------- 话题按钮

## 「聊聊近况」：纯聊天，不产生任务
func _on_topic_pressed() -> void:
	if _npc == null:
		return
	_pending_say = "topic"
	_topic_btn.disabled = true
	_body_label.text = "[i]……[/i]"
	DialogueGenerator.request_line(_npc.npc_name, _npc.npc_role, _npc.personality, LOCAL_SMALL_TALK, TOPIC_SMALL_TALK)


## 「有什么要帮忙的」：先让 NPC 亲口说出难处，再把这件事整理成任务。
## 通天福地的住客出手极阔却难得开口：多数时候只是婉拒，小概率才真的派任务。
func _on_help_pressed() -> void:
	if _npc == null:
		return
	_help_btn.disabled = true
	_accept_btn.disabled = true
	_current_quest = {}
	_body_label.text = "[i]……[/i]"
	if _is_tianfu_source() and randf() > TIANFU_QUEST_CHANCE:
		_pending_say = "refuse"
		DialogueGenerator.request_line(_npc.npc_name, _npc.npc_role, _npc.personality, LOCAL_REFUSE, TOPIC_REFUSE)
		return
	_pending_say = "need"
	DialogueGenerator.request_line(_npc.npc_name, _npc.npc_role, _npc.personality, LOCAL_NEED, TOPIC_NEED)


## 「打听外面的传闻」：让 AI 造一个新地点，地图上会立刻多出这个地方
func _on_rumor_pressed() -> void:
	if _npc == null:
		return
	_pending_say = ""
	_rumor_btn.disabled = true
	_body_label.text = "[i]正在打听外面的传闻……[/i]"
	LocationGenerator.request_location(_npc.npc_name)


## 玩家在输入框里敲的话，回车（或点「说」）发送
func _on_say_submitted(text: String = "") -> void:
	if _npc == null:
		return
	var line := text.strip_edges()
	if line == "":
		line = _say_input.text.strip_edges()
	_say_input.text = ""
	if line == "":
		return
	_pending_say = "free"
	_body_label.text = "[i]你对%s说：「%s」[/i]\n\n[i]……[/i]" % [_npc.npc_name, _escape(line)]
	DialogueGenerator.request_line(_npc.npc_name, _npc.npc_role, _npc.personality, LOCAL_FREE, line, true)


## 「复命交差」：事办完了，回来领奖励、涨好感。多件任务时按委托人分别复命。
func _on_report_pressed() -> void:
	if _npc == null:
		return
	var quest := QuestManager.reportable_quest_for(_npc.npc_name)
	if quest.is_empty():
		return
	_report_text = _reward_summary(quest)
	QuestManager.report_quest(quest, _npc.npc_role, _npc.personality)
	_report_btn.disabled = true
	_refresh_relation()
	_pending_say = "thanks"
	_body_label.text = _compose_thanks(_local_thanks())
	DialogueGenerator.request_line(_npc.npc_name, _npc.npc_role, _npc.personality, LOCAL_THANKS, TOPIC_THANKS)


func _on_accept_pressed() -> void:
	if _current_quest.is_empty() or _npc == null:
		return
	QuestManager.accept_quest(_current_quest)
	_accept_btn.disabled = true
	_body_label.text = "[b]已接受任务：%s[/b]\n\n%s\n\n%s\n\n[color=#7f9dff]左上角会显示方位箭头；到了地方把事情办完，再回来找 %s，点「复命交差」领奖励。身上任务多的时候，按 T 可以切换导航目标。[/color]" % [
		_current_quest.get("title", "未命名"),
		QuestManager.tracked_label(),
		_current_quest.get("description", ""),
		_npc.npc_name,
	]


# ---------------------------------------------------------------- AI 回调

func _on_quest_generated(quest: Dictionary) -> void:
	# 这个任务必须是从当前这个 NPC 这儿问出来的，否则界面会被别人的任务顶掉
	if _npc == null or str(quest.get("source_npc", "")) != _npc.npc_name:
		return
	_current_quest = quest
	if not visible:
		return
	_pending_say = ""
	_reset_buttons()
	_accept_btn.disabled = false
	_body_label.text = _format_quest(quest)


func _on_quest_reached(_quest: Dictionary) -> void:
	_refresh_report_btn()


func _on_impression_changed(npc_name: String) -> void:
	if _npc != null and _npc.npc_name == npc_name:
		_refresh_relation()


func _on_location_created(loc: Dictionary) -> void:
	_pending_say = ""
	_more_btn_reset()
	PlayerProfile.record_event("听%s说起了「%s」这个地方" % [str(_npc.npc_name) if _npc != null else "村里人", str(loc.get("name", "？"))])
	_body_label.text = "[b]打听到了一个新地方：%s[/b]\n\n%s\n\n[color=#7f9dff]在村子%s方向、大约 %d 米处，已经画到地图上了；以后的任务也可能指向那里。[/color]" % [
		loc.get("name", "？"),
		loc.get("desc", ""),
		loc.get("direction", "？"),
		int(loc.get("distance_m", 0)),
	]


func _on_location_failed(reason: String) -> void:
	_pending_say = ""
	_more_btn_reset()
	_body_label.text = "[color=#e0a0a0]没能打听到新的地方：%s[/color]" % reason


## 世界上多了个新住客时，往对话里捎一句，让玩家知道「这世界在自己长人」。
## 对话没开着就什么也不做，免得把界面里的正文顶掉。
func note_new_npc(npc_name: String, npc_role: String, home_name: String) -> void:
	if not visible:
		return
	var where := home_name if home_name != "" else "附近"
	_body_label.text += "\n\n[color=#8fd18f]—— 听说%s那边，新来了一位%s，叫%s。[/color]" % [
		_escape(where), _escape(npc_role), _escape(npc_name),
	]


func _more_btn_reset() -> void:
	_topic_btn.disabled = false
	_rumor_btn.disabled = false
	_help_btn.disabled = false


## AI 现编的台词回来了
func _on_line_ready(npc_name: String, text: String, mood: String) -> void:
	if _npc == null or _npc.npc_name != npc_name:
		return
	# 界面关了、或者玩家已经点了别的按钮：这句先收回缓存，下次还能用
	if not visible or _pending_say == "":
		DialogueGenerator.stash(npc_name, text)
		return
	var kind := _pending_say
	_pending_say = ""
	_reset_buttons()
	_apply_language_state()
	# 听不懂：不管 AI 说的是什么，都只显示「外语原文 + 听不太懂」
	if not _understood:
		_body_label.text = _unintelligible_block(text)
		return
	match kind:
		"greeting":
			_body_label.text = _compose(text)
		"topic":
			_body_label.text = _compose_topic(text)
		"need":
			_body_label.text = _compose_need(text)
		"refuse":
			_body_label.text = _compose_refuse(text)
		"thanks":
			_body_label.text = _compose_thanks(text)
		"marry":
			_body_label.text = _compose_marry(text)
		"free":
			_apply_mood(mood)
			_body_label.text = _compose_free(text)
		_:
			_body_label.text = _compose_topic(text)


## 玩家自由说话后，NPC 的情绪反过来影响好感（友好 +2 / 不悦 -2 / 中立不变）
func _apply_mood(mood: String) -> void:
	if _npc == null:
		return
	match mood:
		"友好":
			NpcMemory.change_affinity(_npc.npc_name, 2, "和你聊天聊得挺投机")
		"不悦":
			NpcMemory.change_affinity(_npc.npc_name, -2, "你说的话让他不太高兴")
	_refresh_relation()


# ---------------------------------------------------------------- 文案

## NPC 亲口说完难处之后，马上把这件事整理成一件任务
func _compose_need(line: String) -> String:
	var lines := PackedStringArray()
	lines.append(_escape(line))
	lines.append("[color=#7f9dff]正在把你说的这件事整理成一件任务……[/color]")
	if _npc != null:
		QuestManager.request_quest(_npc.npc_name, _npc.npc_role, _npc.personality, _is_tianfu_source())
	return "\n\n".join(lines)


## 福地住客婉拒求助：他客气地推脱 + 灰字点出「福地的人难得开口」
func _compose_refuse(line: String) -> String:
	var lines := PackedStringArray()
	lines.append(_escape(line))
	lines.append("[color=gray]福地的人出手大方，却难得开口求人；改日再来问问，或许就肯说了。[/color]")
	return "\n\n".join(lines)


## 当前这位 NPC 是不是通天福地的住客
func _is_tianfu_source() -> bool:
	return _npc != null and str(_npc.culture_id) == "tianfu"


## 开场白：AI/本地那句 + 「他记得你最近在做什么」+ 灰字操作提示
func _compose(first_line: String) -> String:
	var lines := PackedStringArray()
	lines.append(_escape(first_line))
	lines.append_array(_trait_remark())
	lines.append("[color=gray]想随便聊聊，点「聊聊近况」；也可以直接在下面输入框里对他说点什么。[/color]")
	return "\n\n".join(lines)


## 聊某个话题：AI 那句 + 灰字提示
func _compose_topic(line: String) -> String:
	var lines := PackedStringArray()
	lines.append(_escape(line))
	lines.append("[color=gray]还想听？再点一次按钮；想帮他做事，点「有什么要帮忙的」。[/color]")
	return "\n\n".join(lines)


## 自由输入之后 NPC 的回话
func _compose_free(line: String) -> String:
	var lines := PackedStringArray()
	lines.append(_escape(line))
	lines.append("[color=gray]你可以接着对他说点什么，也可以用下面的按钮聊聊别的。[/color]")
	return "\n\n".join(lines)


## 复命：NPC 的道谢 + 奖励结算
func _compose_thanks(line: String) -> String:
	var lines := PackedStringArray()
	lines.append(_escape(line))
	if _report_text != "":
		lines.append("[color=#8fd18f]%s[/color]" % _report_text)
	return "\n\n".join(lines)


func _local_thanks() -> String:
	return str(LOCAL_THANKS[randi() % LOCAL_THANKS.size()])


## 求婚：NPC 的那句 + 「结为伴侣」的提示
func _compose_marry(line: String) -> String:
	var lines := PackedStringArray()
	lines.append(_escape(line))
	if _npc != null:
		lines.append("[color=#e0a0a0]你与%s就此结为伴侣。[/color]" % _escape(_npc.npc_name))
	return "\n\n".join(lines)


func _local_marry() -> String:
	return str(LOCAL_MARRY[randi() % LOCAL_MARRY.size()])


func _reward_summary(quest: Dictionary) -> String:
	var rewards = quest.get("rewards", {})
	var parts: PackedStringArray = []
	if typeof(rewards) == TYPE_DICTIONARY:
		for key in rewards:
			parts.append("%s: %s" % [key, str(rewards[key])])
	if parts.is_empty():
		return "奖励已发放。"
	return "奖励已发放 " + ", ".join(parts)


## 开场白先从 NPC 自己的台词池里随机抽一句顶上（AI 那句还没准备好时用的兜底）
func _local_line(npc: Node) -> String:
	if npc != null and npc.greetings.size() > 0:
		return str(npc.greetings[randi() % npc.greetings.size()])
	return "你好，旅行者。"


## 「他记得你最近在做什么」——按玩家最突出的行为倾向说一句
func _trait_remark() -> PackedStringArray:
	var profile := PlayerProfile.to_dict()
	match str(profile.get("dominant_trait", "exploration")):
		"social":
			return PackedStringArray(["你最近和村里人聊了不少，大家都念着你呢。"])
		"persistence":
			return PackedStringArray(["你在这附近待了很久了，是个沉得住气的人。"])
		_:
			# 只有累计移动真的达到「走过远路」的标准，才说他走了不少路
			if PlayerProfile.traveled_far():
				return PackedStringArray(["你最近走了不少路，这附近的每条小径怕是都被你踩遍了。"])
			return PackedStringArray(["你对这附近的路，看着还挺好奇的。"])


## 台词是 AI 写的，可能带 [ ]，直接塞进 RichTextLabel 会被当成标签
func _escape(text: String) -> String:
	return text.replace("[", "[lb]")


func _format_quest(quest: Dictionary) -> String:
	var lines: PackedStringArray = []
	lines.append("[b]%s[/b]  [color=gray](%s)[/color]" % [
		quest.get("title", "未命名"),
		quest.get("type", "side"),
	])
	lines.append("[b]目标地点[/b] %s" % WorldData.name_of(str(quest.get("target_location", ""))))
	lines.append(quest.get("description", ""))

	var stages: Array = quest.get("stages", [])
	if not stages.is_empty():
		lines.append("[b]目标[/b]")
		for i in stages.size():
			var stage = stages[i]
			if typeof(stage) == TYPE_DICTIONARY:
				lines.append("  %d. %s" % [i + 1, stage.get("goal", "???")])
			else:
				lines.append("  %d. %s" % [i + 1, str(stage)])

	var rewards = quest.get("rewards", {})
	if typeof(rewards) == TYPE_DICTIONARY and not rewards.is_empty():
		var parts: PackedStringArray = []
		for key in rewards:
			parts.append("%s: %s" % [key, str(rewards[key])])
		lines.append("[b]奖励[/b] " + ", ".join(parts))

	if quest.has("fits_profile_because"):
		lines.append("[color=#7f9dff]生成理由：%s[/color]" % quest["fits_profile_because"])

	return "\n".join(lines)

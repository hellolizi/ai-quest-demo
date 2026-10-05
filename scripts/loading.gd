extends Control
## 加载场景：只在「玩家自己写结局」时出现。
##
## 玩家亲手写下结局，等于给这一程许了个愿。进主场景前得先把这份心愿兑现成实的：
## 编一条贴着结局走的八幕主线、把终局的三个真实落点与人钉下来、写出第一章。
## 这期间由 StoryDirector 通过 prepare_progress 一步步报进度，这里只管把它画出来。
## 预设结局 / 没定结局用现成模板，秒进，不走这条路。

const MAIN_SCENE := "res://scenes/main.tscn"
## 预备完成后，多停留一会儿，让「准备好了，这就出发」这句被看清
const LINGER := 0.8

var _angle := 0.0
var _spinner: Control
var _step_text: Label
var _step_bar: ProgressBar
var _wish: Label
var _title: Label
var _done := false


func _ready() -> void:
	_spinner = $Box/Spinner
	_step_text = $Box/StepText
	_step_bar = $Box/StepBar
	_wish = $Box/Wish
	_title = $Box/Title
	_title.add_theme_font_size_override("font_size", 26)
	_step_text.add_theme_color_override("font_color", Color(0.8, 0.85, 0.95))
	_wish.add_theme_color_override("font_color", Color(0.95, 0.85, 0.6))
	_wish.text = "你的结局：%s" % StoryDirector.goal_summary()
	_spinner.draw.connect(_on_spinner_draw)
	# 先连好信号再开工：离线（mock）模式下整条预备会同步跑完，
	# 信号在 prepare_custom_ending() 内部就发出来了，没连上就全丢了。
	StoryDirector.prepare_progress.connect(_on_progress)
	StoryDirector.prepare_finished.connect(_on_finished)
	_step_bar.max_value = 3.0
	_step_bar.value = 0.0
	_step_text.text = "正在准备…"
	StoryDirector.prepare_custom_ending()


func _process(delta: float) -> void:
	_angle = fmod(_angle + delta * 4.0, TAU)
	if is_instance_valid(_spinner):
		_spinner.queue_redraw()


func _on_spinner_draw() -> void:
	var c := _spinner.size * 0.5
	var r := 22.0
	_spinner.draw_arc(c, r, 0.0, TAU, 48, Color(0.25, 0.28, 0.34), 5.0, true)
	_spinner.draw_arc(c, r, _angle, _angle + PI * 0.6, 32, Color(0.75, 0.85, 1.0), 5.0, true)


func _on_progress(step: int, text: String) -> void:
	_step_text.text = text
	_step_bar.value = clampi(step, 0, 3)


func _on_finished(ok: bool) -> void:
	if _done:
		return
	_done = true
	# ok=false 表示这次不该走预备（比如不是自定义结局）：直接进主场景
	if not ok:
		get_tree().change_scene_to_file(MAIN_SCENE)
		return
	_step_bar.value = 3.0
	_step_text.text = "准备好了，这就出发。"
	# 这一程已经预备好了，先落一次档，免得断在这里白编一场
	SaveSystem.save_game()
	await get_tree().create_timer(LINGER).timeout
	get_tree().change_scene_to_file(MAIN_SCENE)

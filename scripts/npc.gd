extends Area2D
## NPC：玩家靠近时显示提示，按 E 请求交谈。
## 平时过自己的日子——在住处附近溜达、沿着村口那条小路走一段、偶尔回屋待一会儿，
## 再出门接着晃。所有移动都只是视觉位移（Area2D 不参与物理碰撞），
## 玩家一靠近就停下来，免得你追着他说话。

signal talk_requested(npc: Node)
## 玩家进入 / 离开交互范围时广播，供 HUD 显示这个人的简略状态
signal focus_changed(npc: Node, focused: bool)

@export var npc_name: String = "村民"
@export var npc_role: String = "普通村民"
## 这个 NPC 属于哪个文化圈。它决定这个人说哪国话——
## 玩家听不懂外语时，台词会显示成外语原文（见 dialogue_ui / CultureData.foreignize）。
## 留空表示「跟玩家同一个文化圈」。
@export var culture_id: String = ""
## 这个 NPC 的性格：既决定开场白的语气，也会交给 AI 生成符合其性格的任务
@export_multiline var personality: String = "普通村民，说话客气但没什么特点。"
## 兜底台词池：AI 不可用（离线/超时/失败）时从这里随机抽一句；
## AI 可用时它同时作为「参考素材」喂给模型，让生成的台词更贴合这个 NPC。
@export var greetings: PackedStringArray = PackedStringArray()
## 聚落档次（"city" 表示城里人，穿着更讲究）。由 main.gd 在加入场景前塞进来。
var tier: String = ""

# ---------------------------------------------------------------- 走动的节奏与范围
## 在住处附近溜达的最大半径。够大，人才散得开，不会挤成一堆。
const WANDER_RADIUS := 130.0
const WANDER_SPEED := 34.0
## 沿小路散步时走得快一点，看着像「有正事要办」
const ROAD_SPEED := 52.0
## 回自家门口的速度
const HOME_SPEED := 42.0
const WANDER_MIN_WAIT := 1.2
const WANDER_MAX_WAIT := 4.0
## 进屋后待多久才出来
const INSIDE_MIN_WAIT := 6.0
const INSIDE_MAX_WAIT := 16.0
## 距离目标点这么近就算「到了」
const ARRIVE_DIST := 6.0
## 离住处这么近的小路点才值得专门去踩；太远的路口就不去了
const ROAD_REACH := 620.0

## 行为状态：站着歇脚、在路上走、进了屋
enum State { IDLE, WALK, INSIDE }
## 走到目的地之后做什么
enum Goal { WANDER, HOME, ROAD }

@onready var _prompt: Label = $Prompt
@onready var _sprite: CharacterSprite = $Sprite

var _player_in_range := false

## 外观参数（由 main.gd 在加入场景前塞进来）
var _appearance: Dictionary = {}
## 这个人在立绘库里的标签（由名字+文化圈+外观稳定推出）
var _portrait_tag := ""

## 住处（= 出生点，也是他家那扇门所在的位置）
var _home_pos := Vector2.ZERO
## 离住处最近的一条小路折线（世界坐标）；没有路就是空数组，那就只在附近溜达
var _road := PackedVector2Array()
## 当前朝哪儿走、走多快，以及到了之后干什么
var _target := Vector2.ZERO
var _walk_speed := WANDER_SPEED
var _goal: int = Goal.WANDER
var _state: int = State.IDLE
var _timer := 0.0


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	_prompt.visible = false
	_home_pos = position
	_target = _home_pos
	# 找一条离家最近的小路，好让这人能「上街」走一段
	var world := get_parent()
	if world != null and world.has_method("nearest_road_path"):
		_road = world.nearest_road_path(_home_pos)
	# 起步的等待时间随机一下，免得满村的人整齐划一地同时迈步
	_enter_idle(randf_range(0.0, WANDER_MAX_WAIT))
	_sprite.set_appearance(_appearance)
	_setup_portrait()


# ---------------------------------------------------------------- 立绘

## 报到：告诉立绘生成器「这个人需要一张立绘」，并监听立绘库变化。
## 有图就贴上，没图（或玩家把图停用了）就先显示程序化小人。
func _setup_portrait() -> void:
	var cid := culture_id if culture_id != "" else CultureData.current_id
	_portrait_tag = PortraitLibrary.tag_for(npc_name, cid, _appearance)
	PortraitLibrary.changed.connect(_refresh_portrait)
	PortraitLibrary.walk_changed.connect(_on_walk_changed)
	PortraitGenerator.request(_portrait_tag, npc_name, npc_role, cid, _appearance, tier)
	WalkSheetGenerator.request(_portrait_tag, npc_name, npc_role, cid, _appearance)
	_refresh_portrait()
	_refresh_walk()


func _refresh_portrait() -> void:
	if _portrait_tag == "":
		return
	if PortraitLibrary.is_enabled(_portrait_tag):
		_sprite.set_portrait(PortraitLibrary.get_texture(_portrait_tag))
	else:
		_sprite.clear_portrait()


## 走路帧入库通知：只认自己这套 tag，免得给别人刷新时白忙
func _on_walk_changed(tag: String) -> void:
	if tag == _portrait_tag:
		_refresh_walk()


func _refresh_walk() -> void:
	if _portrait_tag == "":
		return
	if PortraitLibrary.has_walk(_portrait_tag):
		_sprite.set_walk_frames(PortraitLibrary.get_walk_frames(_portrait_tag))
	else:
		_sprite.clear_walk_frames()


# ---------------------------------------------------------------- 外观

## 设置这个人的长相。加入场景前调用也可以（会先存起来，_ready 时再画）。
func set_appearance(data) -> void:
	_appearance = CharacterSprite.sanitize_appearance(data)
	if is_node_ready():
		_sprite.set_appearance(_appearance)


# ---------------------------------------------------------------- 走动

func _process(delta: float) -> void:
	# 在屋里：不出现在画面上，待够时间再出来
	if _state == State.INSIDE:
		_sprite.set_moving(false)
		_timer -= delta
		if _timer <= 0.0:
			_leave_home()
		return

	# 玩家在跟前，或界面（对话/任务日志）开着时，站定不动
	if _player_in_range or PlayerProfile.ui_open:
		_sprite.set_moving(false)
		return

	# 歇够了就挑下一件事做
	if _state == State.IDLE:
		_sprite.set_moving(false)
		_timer -= delta
		if _timer <= 0.0:
			_choose_action()
		return

	# 在路上：朝目标点走，走到了就处理「到站后要做什么」
	if _step_toward(_target, _walk_speed * delta):
		_on_arrived()


## 朝 target 迈这一步；到了（或已经很近）返回 true
func _step_toward(target: Vector2, step: float) -> bool:
	var to := target - position
	var d := to.length()
	if d <= ARRIVE_DIST:
		return true
	var dir := to / d
	position += dir * minf(step, d)
	_sprite.set_moving(true)
	_sprite.set_facing_vec(dir)
	return false


## 站着歇一会儿（wait < 0 时随机一个时长），时间到了会自动挑下一件事做
func _enter_idle(wait: float = -1.0) -> void:
	_state = State.IDLE
	_timer = wait if wait >= 0.0 else randf_range(WANDER_MIN_WAIT, WANDER_MAX_WAIT)
	_sprite.set_moving(false)


## 站定之后挑一件事：原地附近溜达 / 回屋 / 沿小路走一段
func _choose_action() -> void:
	# 已经走远了就先往家走，别越走越没影
	if position.distance_to(_home_pos) > WANDER_RADIUS * 1.5:
		_start_go_home()
		return
	var roll := randf()
	if roll < 0.40:
		_start_wander()
	elif roll < 0.62:
		_start_go_home()
	elif not _start_road_trip():
		_start_wander()


## 在住处附近挑个随机点溜达
func _start_wander() -> void:
	_goal = Goal.WANDER
	_walk_speed = WANDER_SPEED
	var angle := randf() * TAU
	var dist := randf_range(WANDER_RADIUS * 0.30, WANDER_RADIUS)
	_target = _home_pos + Vector2(cos(angle), sin(angle)) * dist
	_state = State.WALK


## 回自家门口（到了就会进屋待一阵子）
func _start_go_home() -> void:
	_goal = Goal.HOME
	_walk_speed = HOME_SPEED
	_target = _home_pos
	_state = State.WALK


## 挑一个离家不太远的小路点，走过去露个面。
## 没有合适的小路（比如荒野孤屋）就返回 false，让调用方改去溜达。
func _start_road_trip() -> bool:
	if _road.size() < 2:
		return false
	var candidates: Array = []
	for q in _road:
		var d: float = _home_pos.distance_to(q)
		if d > 40.0 and d < ROAD_REACH:
			candidates.append(q)
	if candidates.is_empty():
		return false
	_goal = Goal.ROAD
	_walk_speed = ROAD_SPEED
	_target = candidates[randi() % candidates.size()]
	_state = State.WALK
	return true


func _on_arrived() -> void:
	if _goal == Goal.HOME:
		_enter_home()
	else:
		_enter_idle()


## 走到自家门口 → 进屋待一阵子（人从画面上消失，玩家也不用隔着墙跟他搭话）
func _enter_home() -> void:
	_state = State.INSIDE
	_timer = randf_range(INSIDE_MIN_WAIT, INSIDE_MAX_WAIT)
	# 人进了屋就从画面上消失：若玩家正看着他，先把 HUD 上的状态栏撤掉
	if _player_in_range:
		focus_changed.emit(self, false)
	_player_in_range = false
	_prompt.visible = false
	_sprite.set_moving(false)
	visible = false
	# 藏起来的同时关掉探测，免得玩家隔着「空气」按 E 搭话
	set_deferred("monitoring", false)


## 待够了 → 从屋里出来
func _leave_home() -> void:
	visible = true
	set_deferred("monitoring", true)
	# 刚出门别贴着门站着，先随便走开一点再决定做什么
	_enter_idle(randf_range(0.6, 1.6))


# ---------------------------------------------------------------- 交互

func _on_body_entered(body: Node2D) -> void:
	if body.name == "Player":
		_player_in_range = true
		_prompt.visible = true
		# 让 HUD 亮出这个人的简略状态栏
		focus_changed.emit(self, true)
		# 玩家一靠近就让 AI 提前备一句：等按下 E 时往往已经生成好，可以秒回
		DialogueGenerator.prefetch(npc_name, npc_role, personality, greetings)


func _on_body_exited(body: Node2D) -> void:
	if body.name == "Player":
		_player_in_range = false
		_prompt.visible = false
		focus_changed.emit(self, false)


func _unhandled_input(event: InputEvent) -> void:
	if not _player_in_range or PlayerProfile.ui_open:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_E:
		get_viewport().set_input_as_handled()
		talk_requested.emit(self)

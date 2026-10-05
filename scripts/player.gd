extends CharacterBody2D
## 玩家：WASD / 方向键移动，并把移动距离记录到行为画像里。

const SPEED := 240.0

## 挥击：空手的基础攻击距离。武器的 range 效果在此基础上加成。
const ATTACK_REACH := 64.0
## 空手（或认不出的武器）时的攻击间隔（秒）。
## 有武器时按「武器类型」查表——见 WeaponData.KIND_COOLDOWN，
## 数值照现实中这类武器的使用节奏定（匕首最快、战锤/步枪最慢）。
const ATTACK_COOLDOWN := 0.55
## 无论攻速加成多高，两次挥击之间至少留这么久的间隔
const MIN_ATTACK_COOLDOWN := 0.15

## 身体半径的采样点：判断「能不能站到某个位置」时按这几处一起查，
## 免得半个人陷进水里或山体里。近似一个半径 9px 的圆。
const BODY_SAMPLES: Array[Vector2] = [
	Vector2.ZERO,
	Vector2(9, 0), Vector2(-9, 0), Vector2(0, 9), Vector2(0, -9),
]

## 玩家的固定外观：一身蓝衣配围巾，在任何文化圈里都认得出来。
## 这份定义同时被「开始菜单预生成主角立绘」引用，是主角长相的唯一来源。
const PLAYER_APPEARANCE := {
	"skin": "tan",
	"hair": "black",
	"hair_style": "short",
	"clothes": "blue",
	"build": "normal",
	"accessory": "scarf",
}

const PORTRAIT_CULTURE_KEY := "player"
const PORTRAIT_NAME := "玩家"

@onready var _sprite: CharacterSprite = $Sprite

var _prev_position: Vector2
## 玩家在立绘库里的标签。用固定字符串而不是当前文化圈，免得玩家换个地方长相就变了。
var _portrait_tag := ""
## 下一次能挥击的时刻（秒），用来控制攻击节奏
var _attack_cd := 0.0


func _ready() -> void:
	add_to_group("player")
	_prev_position = global_position
	_sprite.set_appearance(PLAYER_APPEARANCE)
	_setup_portrait()


## 玩家也有自己的专属立绘，同样可以进立绘库里挑
func _setup_portrait() -> void:
	_portrait_tag = PortraitLibrary.tag_for(PORTRAIT_NAME, PORTRAIT_CULTURE_KEY, PLAYER_APPEARANCE)
	PortraitLibrary.changed.connect(_refresh_portrait)
	PortraitLibrary.walk_changed.connect(_on_walk_changed)
	PortraitLibrary.attack_changed.connect(_on_attack_changed)
	PortraitGenerator.request(
		_portrait_tag, PORTRAIT_NAME, "主角", CultureData.current_id, PLAYER_APPEARANCE
	)
	WalkSheetGenerator.request(
		_portrait_tag, PORTRAIT_NAME, "主角", CultureData.current_id, PLAYER_APPEARANCE
	)
	AttackSheetGenerator.request(
		_portrait_tag, PORTRAIT_NAME, "主角", CultureData.current_id, PLAYER_APPEARANCE
	)
	_refresh_portrait()
	_refresh_walk()
	_refresh_attack()


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


## 攻击帧入库通知：只认自己这套 tag
func _on_attack_changed(tag: String) -> void:
	if tag == _portrait_tag:
		_refresh_attack()


func _refresh_attack() -> void:
	if _portrait_tag == "":
		return
	if PortraitLibrary.has_attack(_portrait_tag):
		_sprite.set_attack_frames(PortraitLibrary.get_attack_frames(_portrait_tag))
	else:
		_sprite.clear_attack_frames()


## 被瞬移（进屋 / 上楼 / 出门）后调用：镜头别从旧位置慢慢滑过来，
## 位置采样也一并重置，免得把这一大跳算进「行走距离」画像里。
func reset_camera() -> void:
	var cam := get_node_or_null("Camera2D")
	if cam is Camera2D:
		(cam as Camera2D).reset_smoothing()
	_prev_position = global_position
	velocity = Vector2.ZERO


func _physics_process(delta: float) -> void:
	_attack_cd = maxf(0.0, _attack_cd - delta)
	var indoors := InteriorManager.active
	# 室内不往世界上报：屋里没有任务点、也不该触发区块流式生成
	if not indoors:
		# 每帧把位置报给任务系统：走到目标地点附近会自动完成任务
		QuestManager.try_complete_at(global_position)
		# 每帧把位置报给世界生成器：它会提前在玩家前方把区块里的房屋和人造好（MC 式流式生成）
		LocationGenerator.report_player_position(global_position)

	# 对话打开时锁住移动
	if PlayerProfile.ui_open:
		velocity = Vector2.ZERO
		move_and_slide()
		_sprite.set_moving(false)
		_prev_position = global_position
		return

	# 空格 / 回车挥击：打范围内的敌人，武器的伤害/暴击/吸血都在这一下里体现
	if Input.is_action_just_pressed("ui_accept") and _attack_cd <= 0.0:
		_attack()

	var dir := Vector2(
		Input.get_axis("ui_left", "ui_right"),
		Input.get_axis("ui_up", "ui_down")
	)
	# 方向键之外，额外支持 WASD
	if Input.is_key_pressed(KEY_A):
		dir.x = -1.0
	if Input.is_key_pressed(KEY_D):
		dir.x = 1.0
	if Input.is_key_pressed(KEY_W):
		dir.y = -1.0
	if Input.is_key_pressed(KEY_S):
		dir.y = 1.0

	# 移动速度 = 基础 + 武器的 speed 效果
	var speed := SPEED + PlayerProfile.weapon_effect("speed", 0.0)
	velocity = dir.normalized() * speed
	# 地形阻挡：高山与深水（桥面除外）挡路。若径直走不过去，就贴着障碍滑动
	# （先试只走 x，再试只走 y），走斜线撞墙也不会被卡住。
	# 安全阀：万一已经站在被挡的格子里（例如卡进水里），不再限制，让它能走出来。
	# 地形阻挡只在地表有意义；屋里靠墙的碰撞体挡人，不必再查山高水深。
	if not indoors \
			and _terrain_blocked(global_position + velocity * delta) \
			and not _terrain_blocked(global_position):
		var step := velocity * delta
		if not _terrain_blocked(global_position + Vector2(step.x, 0.0)):
			velocity = Vector2(velocity.x, 0.0)
		elif not _terrain_blocked(global_position + Vector2(0.0, step.y)):
			velocity = Vector2(0.0, velocity.y)
		else:
			velocity = Vector2.ZERO
	move_and_slide()

	# 行走动画：真的挪动了才迈步，撞墙时不原地踏步；并按左右方向转身
	var moved := global_position.distance_to(_prev_position) > 0.5
	_sprite.set_moving(moved)
	_sprite.set_facing_vec(dir)

	# 用「实际位移」而不是「速度×时间」，被挡住时不计入
	PlayerProfile.add_distance(global_position.distance_to(_prev_position))
	_prev_position = global_position


## 挥击一次：命中范围内所有敌人，伤害按武器攻击力算；暴击翻倍、吸血回血。
func _attack() -> void:
	# 攻击间隔 = 当前武器类型的基准间隔（按现实武器查表）- 武器的 atk_speed 效果，至少留一点点间隔
	var base_cd := ATTACK_COOLDOWN
	if PlayerProfile.equipped_weapon != "":
		base_cd = WeaponData.base_cooldown(PlayerProfile.equipped_weapon)
	_attack_cd = maxf(MIN_ATTACK_COOLDOWN, base_cd - PlayerProfile.weapon_effect("atk_speed", 0.0))
	var reach := ATTACK_REACH + PlayerProfile.weapon_effect("range", 0.0)
	var power := PlayerProfile.attack_power()
	var crit := PlayerProfile.weapon_effect("crit", 0.0)
	var lifesteal := PlayerProfile.weapon_effect("lifesteal", 0.0)
	_sprite.play_attack()
	_flash_swing(reach)
	for node in get_tree().get_nodes_in_group("enemy"):
		var enemy := node as Node2D
		if enemy == null or not is_instance_valid(enemy):
			continue
		if global_position.distance_to(enemy.global_position) > reach:
			continue
		var dmg := power
		if crit > 0.0 and randf() < crit:
			dmg *= 2
		if enemy.has_method("take_hit"):
			enemy.take_hit(dmg)
		if lifesteal > 0.0:
			PlayerProfile.heal(maxi(1, int(round(float(dmg) * lifesteal))))


## 挥击的一道白光弧，让「打出去了」看得见
func _flash_swing(reach: float) -> void:
	var arc := Polygon2D.new()
	var pts := PackedVector2Array()
	var steps := 12
	for i in steps:
		var a := TAU * float(i) / float(steps)
		pts.append(Vector2(cos(a), sin(a)) * reach)
	arc.polygon = pts
	arc.color = Color(1.0, 0.96, 0.78, 0.28)
	arc.z_index = 4
	add_child(arc)
	var tw := create_tween()
	tw.tween_property(arc, "modulate:a", 0.0, 0.18)
	tw.tween_callback(arc.queue_free)


## 这个位置是否被地形挡住（按身体半径采样四周）
func _terrain_blocked(p: Vector2) -> bool:
	for off in BODY_SAMPLES:
		if RegionGenerator.is_blocking(p + off):
			return true
	return false

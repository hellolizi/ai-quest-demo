extends Area2D
## 敌人：两种来源共用这一个脚本。
## 1) 野生敌人：在废墟 / 矿口 / 林子里游荡，玩家靠近就扑上来咬人，掉一份锻造材料。
## 2) 坏人据点守兵：由 EnemyData 指定种族与武器，近战贴脸、远程放箭，掉材料 + 金币。
##
## 用 Area2D 而不是 CharacterBody2D：它不需要精细的碰撞滑动，只要够近就打。

## 野物：进入视野（这个距离内）就开始追玩家
const AGGRO := 340.0
## 野物：追击速度（像素/秒），比玩家慢，跑得掉
const SPEED := 92.0
## 野物：贴身撕咬的间隔与每次伤害
const BITE_COOLDOWN := 0.9
const BITE_DAMAGE := 9
## 守兵：仇恨半径比野物更大（据点周围都算他们的地盘）
const GUARD_AGGRO := 430.0

var hp := 30
var max_hp := 30
## 打死掉的材料：{id, count}
var drop: Dictionary = {}
## 打死掉的金币
var gold_drop := 0

## 守兵属性（野物时为空 / 0）
var race_id := ""
var race_name := ""
var species := ""
var weapon_kind := ""

var _player: Node2D = null
var _bite_cd := 0.0
var _body: Polygon2D
## 挨打时一起闪红的部件（躯干 + 武器）
var _tintables: Array[Polygon2D] = []
var _weapon_root: Node2D = null
## 程序化外观（体块 + 武器）整组挂在它下面：有 AI 图时整组隐藏
var _look_root: Node2D = null

## 守兵的 AI 美术：立绘 / 走路帧 / 攻击帧都按「族」共用一套
var _sprite_holder: Node2D = null
var _sprite: CharacterSprite = null
var _art_tag := ""

var _scale := 1.0
var _base_color := Color(0.42, 0.16, 0.18)
var _accent := Color(1.0, 0.85, 0.3)
var _move_speed := SPEED
var _aggro := AGGRO
var _attack_range := 30.0
var _attack_damage := BITE_DAMAGE
var _ranged := false
var _prefer_min := 0.0
var _prefer_max := 0.0


## 摆一只敌人。
## enemy_drop 形如 {"id": "ore_iron", "count": 1}；hp 越高越耐打。
## p_race 为空 → 野生敌人（原外观，贴身撕咬）；
## p_race 非空 → 坏人据点守兵，按 EnemyData 的种族 / 武器决定外观与打法。
func setup(enemy_hp: int, enemy_drop: Dictionary, p_race := "", p_weapon := "", p_gold := 0) -> void:
	max_hp = maxi(1, enemy_hp)
	hp = max_hp
	drop = enemy_drop.duplicate(true)
	gold_drop = maxi(0, p_gold)
	race_id = str(p_race)
	weapon_kind = str(p_weapon)
	if race_id != "":
		_apply_race()


func _apply_race() -> void:
	var r := EnemyData.race(race_id)
	race_name = str(r.get("name", "匪徒"))
	species = str(r.get("species", "人类"))
	_base_color = r.get("body", _base_color)
	_accent = r.get("accent", _accent)
	_scale = float(r.get("scale", 1.0))
	_move_speed = float(r.get("speed", SPEED))
	_aggro = GUARD_AGGRO
	_attack_damage = EnemyData.kind_damage(weapon_kind)
	_attack_range = EnemyData.kind_range(weapon_kind)
	_ranged = EnemyData.is_ranged_kind(weapon_kind)
	if _ranged:
		# 远程：靠近到射程内，但别贴到脸上
		_prefer_min = 120.0
		_prefer_max = 240.0
	else:
		_prefer_min = 0.0
		_prefer_max = 0.0
		_attack_range = maxf(_attack_range, 30.0)


func _ready() -> void:
	add_to_group("enemy")
	monitorable = false
	monitoring = false
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 17.0 * _scale
	shape.shape = circle
	add_child(shape)
	## 程序化外观统一挂到 _look_root 下，方便有 AI 图时整组隐掉
	_look_root = Node2D.new()
	add_child(_look_root)
	if race_id == "":
		_build_beast_look()
	else:
		_build_guard_look()
		_setup_ai_art()
	z_index = 3


## 野生敌人：一只暗红色的家伙，眼睛两点发亮——和村落里的 NPC 一眼分得开
func _build_beast_look() -> void:
	_body = Polygon2D.new()
	_body.polygon = PackedVector2Array([
		Vector2(-16, 14), Vector2(16, 14), Vector2(11, -12), Vector2(-11, -12),
	])
	_body.color = _base_color
	_look_root.add_child(_body)
	_tintables.append(_body)
	var eyes := Polygon2D.new()
	eyes.polygon = PackedVector2Array([
		Vector2(-7, -4), Vector2(-2, -4), Vector2(-2, 1), Vector2(-7, 1),
	])
	eyes.color = _accent
	eyes.position = Vector2(-3, -2)
	_look_root.add_child(eyes)
	var eyes2 := Polygon2D.new()
	eyes2.polygon = eyes.polygon
	eyes2.color = eyes.color
	eyes2.position = Vector2(8, -2)
	_look_root.add_child(eyes2)


## 守兵：躯干按种族配色，肩甲 / 头饰用 accent 点缀，手里握一件武器。
func _build_guard_look() -> void:
	_body = Polygon2D.new()
	_body.polygon = PackedVector2Array([
		Vector2(-15, 16), Vector2(15, 16), Vector2(12, -10), Vector2(-12, -10),
	])
	_body.color = _base_color
	_body.scale = Vector2(_scale, _scale)
	_look_root.add_child(_body)
	_tintables.append(_body)
	# 头
	var head := Polygon2D.new()
	head.polygon = PackedVector2Array([
		Vector2(-8, -9), Vector2(8, -9), Vector2(6, -22), Vector2(-6, -22),
	])
	head.color = _base_color.lightened(0.12)
	_look_root.add_child(head)
	# 腰带 / 种族标记
	var sash := Polygon2D.new()
	sash.polygon = PackedVector2Array([
		Vector2(-14, 6), Vector2(14, 6), Vector2(14, 10), Vector2(-14, 10),
	])
	sash.color = _accent
	_look_root.add_child(sash)
	# 两点眼睛
	var eyes := Polygon2D.new()
	eyes.polygon = PackedVector2Array([
		Vector2(-5, -18), Vector2(-1, -18), Vector2(-1, -14), Vector2(-5, -14),
	])
	eyes.color = _accent
	_look_root.add_child(eyes)
	var eyes2 := Polygon2D.new()
	eyes2.polygon = eyes.polygon
	eyes2.color = eyes.color
	eyes2.position = Vector2(5, 0)
	_look_root.add_child(eyes2)
	# 武器挂在会朝向玩家的转轴上
	_weapon_root = Node2D.new()
	_weapon_root.position = Vector2(6, 0)
	_look_root.add_child(_weapon_root)
	_draw_weapon()


## 按武器类型画一件简单的兵器（局部坐标朝右，整轴再朝玩家转）。
func _draw_weapon() -> void:
	if _weapon_root == null:
		return
	var shaft := Color(0.38, 0.26, 0.16)
	var steel := Color(0.80, 0.82, 0.86)
	match weapon_kind:
		"匕首":
			_add_part([Vector2(0, -2), Vector2(16, -2), Vector2(16, 2), Vector2(0, 2)], steel)
		"长剑":
			_add_part([Vector2(0, -2), Vector2(30, -2), Vector2(34, 0), Vector2(30, 2), Vector2(0, 2)], steel)
			_add_part([Vector2(-2, -6), Vector2(2, -6), Vector2(2, 6), Vector2(-2, 6)], shaft)
		"长矛":
			_add_part([Vector2(-10, -2), Vector2(38, -2), Vector2(38, 2), Vector2(-10, 2)], shaft)
			_add_part([Vector2(38, -4), Vector2(48, 0), Vector2(38, 4)], steel)
		"斧":
			_add_part([Vector2(-8, -2), Vector2(26, -2), Vector2(26, 2), Vector2(-8, 2)], shaft)
			_add_part([Vector2(22, -12), Vector2(34, -8), Vector2(34, 8), Vector2(22, 12)], steel)
		"战锤":
			_add_part([Vector2(-8, -2), Vector2(24, -2), Vector2(24, 2), Vector2(-8, 2)], shaft)
			_add_part([Vector2(24, -10), Vector2(36, -10), Vector2(36, 10), Vector2(24, 10)], steel)
		"长弓":
			# 一段弧当弓身，配一根细弦
			var arc := PackedVector2Array()
			for i in range(9):
				var t := float(i) / 8.0
				var a := lerpf(-1.1, 1.1, t)
				arc.append(Vector2(6.0 * (1.0 - cos(a)) + 4.0, sin(a) * 20.0))
			_add_part(arc, shaft)
		_:
			_add_part([Vector2(0, -2), Vector2(24, -2), Vector2(24, 2), Vector2(0, 2)], steel)


func _add_part(points: PackedVector2Array, color: Color) -> void:
	var p := Polygon2D.new()
	p.polygon = points
	p.color = color
	_weapon_root.add_child(p)
	_tintables.append(p)


# ---------------------------------------------------------------- AI 美术（立绘 / 走路 / 攻击）
#
# 守兵跟 NPC 一样走 AI 立绘管线：按「族」算一个稳定 tag，
# 立绘 + 走路帧 + 攻击帧三样都请求一遍；有图就用 AI 图（挂在 _sprite 上），
# 没图画好之前继续用上面那套程序化体块，画好了自动切换。

func _setup_ai_art() -> void:
	var r := EnemyData.race(race_id)
	var nm := EnemyData.display_name(race_id)
	var role := str(r.get("species", "守兵"))
	var look := EnemyData.look_cn(race_id)
	var app := EnemyData.appearance_for(race_id)
	## 按族共用一套图，所以 culture 留空、tag 只由「族名 + 族的外观 token」决定
	_art_tag = PortraitLibrary.tag_for(nm, "", app)

	_sprite_holder = Node2D.new()
	## 让 AI 图的「脚底」对上程序化体块的落地线（原点是脚底，往上生长）
	_sprite_holder.position = Vector2(0, 16)
	_sprite_holder.scale = Vector2(_scale, _scale)
	add_child(_sprite_holder)
	_sprite = CharacterSprite.new()
	_sprite.visible = false
	_sprite_holder.add_child(_sprite)

	PortraitLibrary.changed.connect(_on_art_changed)
	PortraitLibrary.walk_changed.connect(_on_walk_changed)
	PortraitLibrary.attack_changed.connect(_on_attack_changed)

	var wp := EnemyData.weapon_cn(weapon_kind)
	PortraitGenerator.request(_art_tag, nm, role, "", app, "", look)
	WalkSheetGenerator.request(_art_tag, nm, role, "", app, look)
	AttackSheetGenerator.request(_art_tag, nm, role, "", app, look, wp)
	_refresh_art()


## 立绘库变了：刷新这张图（只认自己那套 tag 的走路 / 攻击通知）
func _on_art_changed() -> void:
	_refresh_art()


func _on_walk_changed(tag: String) -> void:
	if tag == _art_tag:
		_refresh_art()


func _on_attack_changed(tag: String) -> void:
	if tag == _art_tag:
		_refresh_art()


## 有 AI 图就贴上去并隐藏程序化外观，一张都没有就继续用程序化外观
func _refresh_art() -> void:
	if _sprite == null or _art_tag == "":
		return
	if PortraitLibrary.is_enabled(_art_tag):
		_sprite.set_portrait(PortraitLibrary.get_texture(_art_tag))
	else:
		_sprite.clear_portrait()
	if PortraitLibrary.has_walk(_art_tag):
		_sprite.set_walk_frames(PortraitLibrary.get_walk_frames(_art_tag))
	else:
		_sprite.clear_walk_frames()
	if PortraitLibrary.has_attack(_art_tag):
		_sprite.set_attack_frames(PortraitLibrary.get_attack_frames(_art_tag))
	else:
		_sprite.clear_attack_frames()
	var any: bool = _sprite.has_portrait() or _sprite.has_walk() or _sprite.has_attack()
	_sprite.visible = any
	if _look_root != null:
		_look_root.visible = not any


func _physics_process(delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player") as Node2D
	if _player == null:
		return
	if PlayerProfile.ui_open:
		return
	if _bite_cd > 0.0:
		_bite_cd -= delta
	var to_player := _player.global_position - global_position
	var dist := to_player.length()
	if dist > 1.0 and _weapon_root != null:
		_weapon_root.rotation = to_player.angle()
	var moved := false
	if dist < _aggro and dist > 1.0:
		var dir := to_player.normalized()
		var step := 0.0
		if _ranged:
			# 远程：太近就后退，太远就逼近，落在舒服的射程里就站着放箭
			if dist < _prefer_min:
				step = -_move_speed * delta * 0.8
			elif dist > _prefer_max:
				step = _move_speed * delta
		else:
			step = _move_speed * delta
		if absf(step) > 0.0:
			var next := global_position + dir * step
			if not _blocked(next):
				global_position = next
				moved = true
	## AI 图：朝向玩家、走路时播走路帧
	if _sprite != null:
		if dist > 1.0:
			_sprite.set_facing_vec(to_player)
		_sprite.set_moving(moved)
	if dist < _attack_range and _bite_cd <= 0.0:
		_bite_cd = EnemyData.cooldown_for_kind(weapon_kind) if race_id != "" else BITE_COOLDOWN
		if _sprite != null:
			_sprite.play_attack()
		if _ranged:
			_fire(dir_from(to_player))
		else:
			_attack()
			_lunge()


func dir_from(v: Vector2) -> Vector2:
	return v.normalized() if v.length() > 1.0 else Vector2.RIGHT


## 近战一下：直接扣血
func _attack() -> void:
	PlayerProfile.take_damage(_attack_damage)


## 挥击时身体向前一挺，让「打出去」看得见
func _lunge() -> void:
	if _body == null:
		return
	var tw := create_tween()
	tw.tween_property(_body, "scale", Vector2(_scale * 1.12, _scale * 0.9), 0.06)
	tw.tween_property(_body, "scale", Vector2(_scale, _scale), 0.12)


## 远程：放出一支箭，挂到当前场景里，不随放箭者的死活消失
func _fire(dir: Vector2) -> void:
	if dir == Vector2.ZERO:
		return
	var bolt := Bolt.new()
	bolt.launch(dir, 340.0, _attack_damage)
	get_parent().add_child(bolt)
	bolt.global_position = global_position + dir * 14.0


## 被玩家打中
func take_hit(amount: int) -> void:
	hp -= maxi(1, amount)
	for part in _tintables:
		if part == null:
			continue
		var back := _orig_color(part)
		part.color = Color(1.0, 0.4, 0.4)
		var tw := part.create_tween()
		tw.tween_property(part, "color", back, 0.18)
	## 用 AI 图时程序化体块是隐的，改闪 AI 图本身
	if _sprite != null and _sprite.visible:
		_sprite.modulate = Color(1.0, 0.4, 0.4)
		var tw2 := _sprite.create_tween()
		tw2.tween_property(_sprite, "modulate", Color.WHITE, 0.18)
	if hp <= 0:
		_die()


## 记下部件本来的颜色，闪红之后好还原
func _orig_color(part: Polygon2D) -> Color:
	if not _orig_colors.has(part):
		_orig_colors[part] = part.color
	return _orig_colors[part]


func _die() -> void:
	if not drop.is_empty():
		var mid := str(drop.get("id", ""))
		var n := maxi(1, int(drop.get("count", 1)))
		if mid != "":
			PlayerProfile.add_item(mid, n)
	if gold_drop > 0:
		PlayerProfile.add_gold(gold_drop)
	var qm := get_node_or_null("/root/QuestManager")
	if qm != null and qm.has_method("notify_enemy_defeated"):
		qm.notify_enemy_defeated(global_position)
	queue_free()


## 闪红之后要还原的本色（部件 → 颜色）
var _orig_colors: Dictionary = {}


func _blocked(p: Vector2) -> bool:
	return RegionGenerator.is_blocking(p)


## 远程箭矢：飞向玩家，够近就扣血
class Bolt extends Node2D:
	var velocity := Vector2.RIGHT
	var damage := 8
	var life := 1.6
	var _player: Node2D = null

	func launch(dir: Vector2, speed: float, dmg: int) -> void:
		velocity = dir.normalized() * speed
		damage = maxi(1, dmg)

	func _physics_process(delta: float) -> void:
		if _player == null or not is_instance_valid(_player):
			_player = get_tree().get_first_node_in_group("player") as Node2D
		life -= delta
		global_position += velocity * delta
		if _player != null and not PlayerProfile.ui_open:
			if global_position.distance_to(_player.global_position) < 18.0:
				PlayerProfile.take_damage(damage)
				queue_free()
				return
		if life <= 0.0:
			queue_free()

	func _draw() -> void:
		draw_circle(Vector2.ZERO, 4.0, Color(1.0, 0.95, 0.6))
		draw_circle(Vector2.ZERO, 2.0, Color(1.0, 0.6, 0.2))

extends Node
## 记录「玩家此刻在不在屋里」以及进的是哪栋房。
##
## 世界上报（任务判定、区块流式生成）和地形阻挡都只在室外才有意义，
## 玩家、世界地图脚本每帧都来问这里一句，避免在室内误判、误生成。
## 真正搭屋子、搬玩家进出的活由 main.gd 干，这里只管状态与广播。

signal entered(info: Dictionary)
signal exited()

## 玩家此刻是否身处室内
var active := false
## 进屋时那栋房的档案：{bid, cid, spec, pos}
var info: Dictionary = {}
## 那栋房在世界里的位置——出门时把玩家放回门口
var house_pos := Vector2.ZERO


## 进屋：记下是哪栋房，然后广播出去让 main.gd 把屋子搭起来
func enter(house_info: Dictionary) -> void:
	info = house_info
	house_pos = house_info.get("pos", Vector2.ZERO)
	active = true
	entered.emit(info)


## 出门：清空状态，广播出去让 main.gd 把玩家送回世界
func exit() -> void:
	active = false
	info = {}
	exited.emit()

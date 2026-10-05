extends SceneTree
## 一次性工具：把某一颗世界种子下的 Voronoi 区域多边形导成 JSON，
## 供离线渲染预览图（不依赖任何显示设备）。
## 用法：godot --headless --path . --script res://tools/region_dump.gd

const COVER := Rect2(-3000, -3000, 6000, 6000)
const SEED := 424242
const OUT_PATH := "region_dump.json"

var _rg
var _cul


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	_rg = root.get_node_or_null("RegionGenerator")
	_cul = root.get_node_or_null("CultureData")
	if _rg == null or _cul == null:
		push_error("[dump] 缺少 RegionGenerator / CultureData")
		quit(1)
		return
	_rg.set_world_seed(SEED)

	var c0: Vector2i = _rg.grid_cell_of(COVER.position)
	var c1: Vector2i = _rg.grid_cell_of(COVER.position + COVER.size)
	var regions: Array = []
	for cy in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			var cell := Vector2i(cx, cy)
			var poly: PackedVector2Array = _rg.cell_polygon(cell, COVER)
			if poly.size() < 3:
				continue
			var region: Dictionary = _rg.region_of_cell(cell)
			var cid := str(region["culture"])
			var pal: Dictionary = _cul.palette_of(cid)
			var grass: Color = pal.get("grass", Color(0.2, 0.3, 0.2))
			var pts: Array = []
			for v in poly:
				pts.append([v.x, v.y])
			regions.append({
				"cell": [cell.x, cell.y],
				"culture": cid,
				"name": str(_cul.get_culture(cid).get("name", cid)),
				"color": [grass.r, grass.g, grass.b],
				"center": [region["center"].x, region["center"].y],
				"poly": pts,
			})

	var data := {
		"seed": SEED,
		"cover": [COVER.position.x, COVER.position.y, COVER.size.x, COVER.size.y],
		"count": regions.size(),
		"regions": regions,
	}
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()
	print("[dump] 导出 %d 个区域 -> %s" % [regions.size(), OUT_PATH])
	quit(0)

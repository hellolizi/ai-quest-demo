extends SceneTree
## 走路序列帧「最小验证」脚本（一次性工具，不参与游戏运行，不进 autoload）
##
## 目的：验证「一张大图里放 3 行 × 4 列 = 12 格（3 个朝向 × 4 个关键帧）」这条路，
## 出图后代码再把「朝左」水平翻转得到第 4 个朝向「朝右」。
##
## 为什么回到单张：多个方向放在同一次生成里，12 格天然就是同一个角色，
## 不需要参考图也不会出现"正面一个样、侧面另一个样"的漂移。
##
## 代价：格子越多模型越容易画歪 / 跨格。所以出图后必须靠 _align_cell 兜底——
## 逐格算角色包围盒，强行把它平移回格子正中、脚底压到同一条基线。
##
## 用法（在项目根目录执行）：
##   godot --headless --path . --script res://tools/walk_sheet_probe.gd
##
## 已经出过整张图会自动复用本地 sheet.png（可反复调对齐参数而不重复花钱）；
## 想强制重画，把 user://walk_probe_single/sheet.png 删掉再跑。
##
## 【模板底图实验】USE_TEMPLATE = true 时，先生成一张画好 3 行 4 列格线 + 每格中心十字的绿底模板，
## 把它当 image 参数喂给模型，看两件事：
##   1) 方舟 plan 版接口到底认不认 image 参数（之前一直没验证过）；
##   2) 模型会不会照着格子/中心标记去构图。
## 关掉就退回纯提示词。模板本身会存成 template.png，方便对着看。

const CFG_PATH := "res://llm_config.cfg"
const OUT_DIR := "user://walk_probe_single"
const SHEET_FILE := "sheet.png"

## 是否用「带格线 + 中心十字」的空白底图当参考图
const USE_TEMPLATE := true
## 底图边长（正方形即可，跟接口返回的 1K/2K 无关，模型会自行缩放跟随构图）
const TEMPLATE_SIZE := 1024

## 行 = 朝向，从上到下。列 = 每行 4 个关键帧，从左到右。
##
## 只让 AI 画 3 个朝向：正面 / 背面 / 左侧面。
## 第 4 个朝向（朝右）不画，出图后由代码把「朝左」水平翻转得到——
## 实测模型根本不会自己做左右镜像（写了也两行都朝左），而代码翻转是 100% 精确、绝对对称的。
const ROWS := [
	{"id": "down", "cn": "朝下（正面，脸朝镜头）", "side": false},
	{"id": "up", "cn": "朝上（背面，背对镜头）", "side": false},
	{"id": "left", "cn": "朝左（侧面，面朝画面左侧）", "side": true},
]

## 由 left 行翻转出来的朝向，跟着写进输出
const MIRROR_FROM := "left"
const MIRROR_TO := "right"

## 每行 4 帧
const FRAME_COLS := 4

const NEGATIVE_PROMPT := "多个不同角色，人物不一致，颜色不一致，身高不一致，格数错误，格子重叠，跨格，角色贴边，角色出格，角色大小不一，双腿向画面左右两侧张开，外八字，内八字，劈叉，侧踢，抬腿伸向身体侧面，横向迈步，大幅抬腿，腿超出身体轮廓，模糊，畸变，多余的手，多余的腿，文字，水印，签名，复杂背景，风景，写实照片，3D 渲染"

## 切格时每边内缩这么多像素再取用。
## 模型会把模板的格线一起画进成品，格线是深绿、跟亮绿幕色差较大，会被 _is_bg 当成"角色像素"，
## 而竖格线贯穿整格高度 → 包围盒被撑到格子底边，纵向对齐直接失效。内缩一圈把它切掉即可。
const CELL_INSET := 10

var _http: HTTPRequest


func _initialize() -> void:
	_run()


func _run() -> void:
	## _initialize() 阶段 root 还没真正进入场景树，此时 add_child 出来的 HTTPRequest
	## 调 request() 会报 ERR_UNCONFIGURED。等第一帧再动手。
	await process_frame

	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var sheet_path := "%s/%s" % [OUT_DIR, SHEET_FILE]
	var img: Image = null

	if FileAccess.file_exists(sheet_path):
		img = Image.load_from_file(sheet_path)
		if img == null:
			push_error("[probe] 已有的 sheet.png 读不了，先删掉它再重跑")
			quit(1)
			return
		print("[probe] 复用已有 sheet.png，跳过生图（想重画就删掉它）")
	else:
		var cfg := _read_image_cfg()
		if cfg.is_empty():
			push_error("[probe] 读不到可用的 [image] 配置（api_base / api_key / model 至少要填全）")
			quit(1)
			return
		_http = HTTPRequest.new()
		_http.timeout = 300.0
		root.add_child(_http)
		print("[probe] 服务商=%s 模型=%s 尺寸=%s" % [cfg["provider"], cfg["model"], cfg["size"]])
		if str(cfg["size"]).to_upper() == "1K":
			print("[probe] 提示：当前 1K，12 格每格只有约 340px，偏糊；嫌糊可在 llm_config.cfg 把 size 改成 2K 再重跑")

		## 带格线 + 中心十字的空白底图（可选）
		var ref := ""
		if USE_TEMPLATE:
			var tpl := _make_template(TEMPLATE_SIZE)
			tpl.save_png("%s/template.png" % OUT_DIR)
			ref = _image_to_data_url(tpl)
			print("[probe] 已生成模板底图并作为 image 参数发送：%s/template.png" % OUT_DIR)

		print("[probe] 正在生图（12 格一次出，可能要等半分钟）…")
		img = await _generate(cfg, _sheet_prompt(USE_TEMPLATE), ref)
		if img == null:
			push_error("[probe] 生图失败")
			quit(1)
			return

	_save_and_slice(img)

	print("")
	print("[probe] 完成，去这个文件夹看：%s" % ProjectSettings.globalize_path(OUT_DIR))
	print("[probe]   sheet.png          = 原图（AI 画的 12 格：朝下/朝上/朝左）")
	print("[probe]   sheet_aligned.png  = 逐格居中 + 脚底对齐 + 补上翻转出的朝右行（共 16 格）")
	print("[probe]   cells/             = 切好的 12 格原样")
	print("[probe]   cells_aligned/     = 切好的居中版（12 格 + 翻转出的 right 4 格），命名 <方向>_f<帧号>.png")
	quit(0)


# ---------------------------------------------------------------- 提示词

## 单张 3 行 × 4 列 = 12 格。每格只放一个角色，并要求居中留白。
## has_template 为 true 时，会额外告诉模型"跟着我给你的底图走"。
func _sheet_prompt(has_template: bool) -> String:
	## 行序描述直接从 ROWS 生成，避免两处写死对不上
	var parts: Array = []
	for i in ROWS.size():
		parts.append("第 %d 行：%s" % [i + 1, ROWS[i]["cn"]])
	var rows_desc := "；".join(parts) + "。"
	var front_rule := "正面 / 背面（镜头正对着人的正面或背面，看不到人的侧脸）：" \
		+ "迈步的方向是「前后」——也就是朝向镜头或背离镜头的方向，这个方向在画面里没有左右位移。" \
		+ "所以两条腿必须始终叠在身体正中央的那条竖直线上，左右几乎不分家：" \
		+ "站立和迈步时双脚的左右间距都小于一个脚掌的宽度，双脚只出现在身体正中间下方，绝不出现在身体轮廓的左侧或右侧之外。" \
		+ "绝对禁止两条腿向画面左边和右边分开，绝不允许双脚左右开立站在身体两侧，绝不劈叉、绝不外八字、绝不内八字、绝不横着跨步。" \
		+ "迈步只能这样表现：一格是左腿屈膝、膝盖明显朝镜头（向前）抬起、脚抬离地面、抬到另一条腿前面并挡住它；" \
		+ "下一格换成右腿屈膝、膝盖朝镜头抬起挡住左腿。没抬的那条腿在身体正下方蹬直承重。" \
		+ "抬脚高度只到脚踝附近、最多小腿一半，画面里绝不能看到横向张开或大幅跨开的两条腿。"
	var side_rule := "侧面：正常迈步，前后两条腿自然分开，步幅自然、要能明显读出迈步，不要夸张地大劈叉，" \
		+ "人的整体朝向必须是面朝画面左侧（能看到侧脸和鼻子的轮廓）。"
	var posture_rule := "所有格子的角色都必须站姿挺拔：脊背挺直，双肩自然向后打开、胸口打开，" \
		+ "抬头平视前方（正面和背面两行平视镜头），下巴微收，重心落在双脚正上方；" \
		+ "绝不驼背、不含胸、不弓背、不低头、不耸肩、不前倾。"

	var rows_n: int = ROWS.size()
	var total: int = rows_n * FRAME_COLS

	var tpl_note := ""
	if has_template:
		tpl_note = "\n【按我给的底图排布 - 必须严格照做】\n" \
			+ "我会同时给你一张已经画好 %d 行 %d 列格线、并且每格正中央有一个小十字标记的底图。\n" % [rows_n, FRAME_COLS] \
			+ "请严格保持这张底图的 %d 行 %d 列布局：每一格画一个角色，角色的身体中心要正好落在该格中心的十字标记上，\n" % [rows_n, FRAME_COLS] \
			+ "角色不要越过格线、不要跨到隔壁格。绿色背景保持纯绿，格线位置保持不变。" \
			+ "不要把小十字标记画进成品里。\n"

	return """一张 2D 游戏角色的行走动画序列帧图（Sprite Sheet）。
整张图均匀分成 %d 行 %d 列、共 %d 个大小完全相同的正方形格子。格子之间留有清晰的绿色间隔，互不重叠。
【最重要的一条】每一格里只画一个角色，角色必须落在该格的正中央：左右居中、上下居中，四周留出充足空白，
角色不贴边、不出格、不跨格、不被切掉。%d 个格子的角色大小必须一致。%s

%d 行 = %d 个朝向，从上到下：%s

每一行从左到右的 4 格，是同一个朝向走路循环的 4 个连续关键帧：
第 1 格 = 接触帧，左脚迈出刚落地；
第 2 格 = 经过帧，右腿抬起、从支撑腿旁荡过；
第 3 格 = 接触帧，右脚迈出刚落地，与第 1 格左右相反；
第 4 格 = 经过帧，左腿抬起、从支撑腿旁荡过，与第 2 格左右相反。

【腿部动作 - 必须严格照做】
正面 / 背面的行：%s
侧面的行：%s

【体态 - 必须严格照做】
%s

【角色一致性】
%d 个格子必须是同一个角色：一个年轻冒险者，黑色短发，蓝色短夹克，棕色长裤，深色短靴。
完全相同的脸、发型、发色、服装款式和颜色，五头身比例，身高大小完全一致，只是朝向和腿部姿势不同。
每一格角色头顶到脚底的总高度必须完全一样，头不要上下浮动。

2D 游戏美术风格，日式动漫半写实风格，约五头身，五官和四肢比例比 Q 版更接近真人，
保留赛璐璐平涂上色与清晰描边，画面干净利落，不要写实到照片级。
整张图绝对不要出现：驼背、含胸、弓背、低头、长短腿、两腿并齐站着不动、双腿向左右张开、
多余的手或腿、畸形的手、模糊、噪点、文字、水印、边框、地面阴影、多余的装饰。
纯色亮绿色背景（#00FF00），背景干净无杂物，无地面阴影，无文字，无水印，无边框，无网格线以外的装饰。""" \
		% [rows_n, FRAME_COLS, total, total, tpl_note, rows_n, rows_n, rows_desc, front_rule, side_rule, posture_rule, total]


# ---------------------------------------------------------------- 模板底图

## 一张 3 行 4 列的绿底图：画上格线 + 每格正中心一个小十字。
## 用途是喂给模型当构图参考，看它认不认这个"格子 + 中心点"。
func _make_template(size: int) -> Image:
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 1, 0))

	var rows := ROWS.size()
	var cw := int(size / FRAME_COLS)
	var ch := int(size / rows)
	var line := Color(0, 0.45, 0)      # 深绿格线，跟背景同色系，不喧宾夺主
	var mark := Color(1, 0, 1)         # 品红中心标记，够扎眼

	# 格线：内部 3 条竖线 + 3 条横线，各 2px 宽
	for i in range(1, FRAME_COLS):
		img.fill_rect(Rect2i(i * cw - 1, 0, 2, size), line)
	for i in range(1, rows):
		img.fill_rect(Rect2i(0, i * ch - 1, size, 2), line)

	# 每格中心一个十字（横杠 28px、竖杠 28px，各 4px 粗）
	var arm := 14
	var th := 4
	for r in rows:
		for c in FRAME_COLS:
			var cx := c * cw + cw / 2
			var cy := r * ch + ch / 2
			img.fill_rect(Rect2i(cx - arm, cy - th / 2, arm * 2, th), mark)
			img.fill_rect(Rect2i(cx - th / 2, cy - arm, th, arm * 2), mark)

	return img


## 把内存里的 Image 编成 data URL，供 image 参数使用
func _image_to_data_url(img: Image) -> String:
	return "data:image/png;base64,%s" % Marshalls.raw_to_base64(img.save_png_to_buffer())


# ---------------------------------------------------------------- 请求构造

func _read_image_cfg() -> Dictionary:
	var cf := ConfigFile.new()
	if cf.load(CFG_PATH) != OK:
		return {}
	var base := str(cf.get_value("image", "api_base", ""))
	var key := str(cf.get_value("image", "api_key", ""))
	var model := str(cf.get_value("image", "model", ""))
	if base.strip_edges() == "" or key.strip_edges() == "" or model.strip_edges() == "":
		return {}
	return {
		"provider": str(cf.get_value("image", "provider", "ark_plan")),
		"base": base,
		"key": key,
		"model": model,
		"size": str(cf.get_value("image", "size", "1K")),
	}


## 两家参数名不一样，跟 portrait_generator.gd 的 _build_body 保持一致
func _build_body(cfg: Dictionary, prompt: String, ref: String) -> Dictionary:
	if str(cfg["provider"]) == "ark_plan":
		var body := {
			"model": cfg["model"],
			"prompt": prompt,
			"size": cfg["size"],
			"response_format": "b64_json",
			"output_format": "png",
			"watermark": false,
		}
		## 参考图 / 模板底图：data:image/png;base64,... 形式
		if ref != "":
			body["image"] = ref
		return body
	var body_sf := {
		"model": cfg["model"],
		"prompt": prompt,
		"negative_prompt": NEGATIVE_PROMPT,
		"image_size": cfg["size"],
		"batch_size": 1,
		"output_format": "png",
	}
	if ref != "":
		body_sf["image"] = ref
	return body_sf


func _generate(cfg: Dictionary, prompt: String, ref: String = "") -> Image:
	var url := "%s/images/generations" % str(cfg["base"]).strip_edges().trim_suffix("/")
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer %s" % str(cfg["key"]).strip_edges(),
	])
	var err := _http.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(_build_body(cfg, prompt, ref)))
	if err != OK:
		push_error("[probe] 请求发不出去：%s" % error_string(err))
		return null
	var res: Array = await _http.request_completed
	return await _handle(res)


func _handle(res: Array) -> Image:
	var result: int = res[0]
	var code: int = res[1]
	var body: PackedByteArray = res[3]
	var text := body.get_string_from_utf8()

	if result != HTTPRequest.RESULT_SUCCESS:
		push_error("[probe] 请求失败（result=%d），检查网络 / 地址：%s" % [result, text.left(300)])
		return null
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("[probe] 返回不是 JSON（HTTP %d）：%s" % [code, text.left(300)])
		return null
	if code < 200 or code >= 300:
		push_error("[probe] HTTP %d：%s" % [code, _error_message(parsed)])
		return null

	var img: Image = await _extract_image(parsed)
	if img == null:
		push_error("[probe] 返回里没有图片：%s" % text.left(300))
	return img


## 方舟直接给 b64，硅基流动给 url 要再拉一次
func _extract_image(parsed: Dictionary) -> Image:
	var b64 := ""
	var url := ""
	for k in ["data", "images"]:
		var arr = parsed.get(k, null)
		if typeof(arr) != TYPE_ARRAY or (arr as Array).is_empty():
			continue
		var first = (arr as Array)[0]
		if typeof(first) == TYPE_DICTIONARY:
			if (first as Dictionary).has("b64_json"):
				b64 = str((first as Dictionary)["b64_json"])
			elif (first as Dictionary).has("url"):
				url = str((first as Dictionary)["url"])
		elif typeof(first) == TYPE_STRING:
			url = str(first)
	if b64 != "":
		return _decode(Marshalls.base64_to_raw(b64))
	if url != "":
		return await _fetch(url)
	return null


func _fetch(url: String) -> Image:
	var dl := HTTPRequest.new()
	dl.timeout = 180.0
	root.add_child(dl)
	if dl.request(url, PackedStringArray(), HTTPClient.METHOD_GET) != OK:
		dl.queue_free()
		return null
	var res: Array = await dl.request_completed
	dl.queue_free()
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS or int(res[1]) < 200 or int(res[1]) >= 300:
		return null
	return _decode(res[3])


## 按文件头魔数判 png / jpeg，跟 portrait_generator.gd 一致
func _decode(bytes: PackedByteArray) -> Image:
	var img := Image.new()
	if bytes.size() >= 8 and bytes[0] == 0x89 and bytes[1] == 0x50:
		if img.load_png_from_buffer(bytes) == OK:
			return img
	elif bytes.size() >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8:
		if img.load_jpg_from_buffer(bytes) == OK:
			return img
	img = Image.new()
	if img.load_jpg_from_buffer(bytes) == OK:
		return img
	img = Image.new()
	if img.load_png_from_buffer(bytes) == OK:
		return img
	return null


func _error_message(parsed: Dictionary) -> String:
	for key in ["message", "error", "msg", "detail"]:
		var v = parsed.get(key, null)
		if typeof(v) == TYPE_DICTIONARY:
			return str((v as Dictionary).get("message", str(v)))
		if v != null:
			return str(v)
	return JSON.stringify(parsed).left(200)


# ---------------------------------------------------------------- 存盘 / 切格

func _save_and_slice(img: Image) -> void:
	var cells_dir := "%s/cells" % OUT_DIR
	var aligned_dir := "%s/cells_aligned" % OUT_DIR
	DirAccess.make_dir_recursive_absolute(cells_dir)
	DirAccess.make_dir_recursive_absolute(aligned_dir)
	img.save_png("%s/%s" % [OUT_DIR, SHEET_FILE])

	var w := img.get_width()
	var h := img.get_height()
	var cw := int(w / FRAME_COLS)
	var ch := int(h / ROWS.size())
	## 每格实际取用的内缩框，避开模型画进成品的格线
	var iw := cw - CELL_INSET * 2
	var ih := ch - CELL_INSET * 2
	var key := _bg_key(img)
	## 脚底统一落在这条线上（留一点下边距）
	var baseline := int(ih * 0.92)

	## 在 AI 出的 3 行下面再补 1 行：由 MIRROR_FROM 行左右翻转得到 MIRROR_TO 行
	var aligned := Image.create_empty(w, ch * (ROWS.size() + 1), false, Image.FORMAT_RGBA8)
	aligned.fill(key)

	var worst := 0.0
	var worst_where := ""
	## 缓存每行已摆正的帧，供翻转复用
	var fixed_rows: Dictionary = {}
	for r in ROWS.size():
		var dir_id: String = ROWS[r]["id"]
		var row_frames: Array = []
		for c in FRAME_COLS:
			var cell := img.get_region(Rect2i(c * cw + CELL_INSET, r * ch + CELL_INSET, iw, ih))
			cell.save_png("%s/%s_f%d.png" % [cells_dir, dir_id, c])

			## 先量一下 AI 自己画得偏了多少，方便判断"提示词引导"到底有没有用
			var m := _measure_cell(cell, key)
			if m["found"]:
				var off: float = absf(float(m["anchor_x"]) - float(iw) * 0.5)
				if off > worst:
					worst = off
					worst_where = "%s f%d" % [dir_id, c]

			var fixed := _align_cell(cell, key, baseline, m)
			fixed.save_png("%s/%s_f%d.png" % [aligned_dir, dir_id, c])
			aligned.blit_rect(fixed, Rect2i(0, 0, iw, ih), Vector2i(c * cw + CELL_INSET, r * ch + CELL_INSET))
			row_frames.append(fixed)
		fixed_rows[dir_id] = row_frames

	## 翻转出第 4 行（朝右 = 朝左水平镜像）
	var src_row = fixed_rows.get(MIRROR_FROM, null)
	if src_row != null:
		var dst_r: int = ROWS.size()
		for c in FRAME_COLS:
			var mirrored: Image = (src_row[c] as Image).duplicate()
			mirrored.flip_x()
			mirrored.save_png("%s/%s_f%d.png" % [aligned_dir, MIRROR_TO, c])
			aligned.blit_rect(mirrored, Rect2i(0, 0, iw, ih), Vector2i(c * cw + CELL_INSET, dst_r * ch + CELL_INSET))
		print("[probe] 已由 %s 行水平翻转出 %s 行（第 %d 行）" % [MIRROR_FROM, MIRROR_TO, dst_r + 1])

	aligned.save_png("%s/sheet_aligned.png" % OUT_DIR)
	print("[probe] 原图 %d×%d，每格 %d×%d（去格线后取用 %d×%d）" % [w, h, cw, ch, iw, ih])
	if worst_where != "":
		print("[probe] AI 原始居中最大偏移 %.0fpx（占格宽 %.0f%%）→ %s；已全部拉回格子正中" \
			% [worst, worst / float(iw) * 100.0, worst_where])


# ---------------------------------------------------------------- 抠图 / 对齐

## 取四角均值当"绿幕"键色。四角互相差太多说明背景不纯，取均值也能凑合。
func _bg_key(img: Image) -> Color:
	var w := img.get_width()
	var h := img.get_height()
	var pts := [Vector2i(2, 2), Vector2i(w - 3, 2), Vector2i(2, h - 3), Vector2i(w - 3, h - 3)]
	var r := 0.0
	var g := 0.0
	var b := 0.0
	for p in pts:
		var c := img.get_pixel(p.x, p.y)
		r += c.r
		g += c.g
		b += c.b
	return Color(r / 4.0, g / 4.0, b / 4.0)


## 和键色足够接近就算背景。阈值放宽松些，绿幕边缘的半透明噪点也能吃掉。
func _is_bg(px: Color, key: Color) -> bool:
	var dr := px.r - key.r
	var dg := px.g - key.g
	var db := px.b - key.b
	return sqrt(dr * dr + dg * dg + db * db) <= 0.20


## 量一格里的角色：包围盒 + 上半身横向锚点。found 为 false 表示整格都是背景。
func _measure_cell(cell: Image, key: Color) -> Dictionary:
	var w := cell.get_width()
	var h := cell.get_height()
	## 逐行 / 逐列统计非背景像素个数，滤掉孤立噪点：
	## 一个像素的杂点不该把包围盒撑开、进而让整个角色被平移（这正是"走路时人物忽高忽低/像驼背"的元凶之一）。
	var min_run := maxi(2, int(w * 0.005))
	var row_cnt := PackedInt32Array()
	row_cnt.resize(h)
	var col_cnt := PackedInt32Array()
	col_cnt.resize(w)
	for y in h:
		for x in w:
			if _is_bg(cell.get_pixel(x, y), key):
				continue
			row_cnt[y] += 1
			col_cnt[x] += 1

	var min_x := w
	var max_x := -1
	var min_y := h
	var max_y := -1
	for y in h:
		if row_cnt[y] >= min_run:
			min_y = mini(min_y, y)
			max_y = maxi(max_y, y)
	for x in w:
		if col_cnt[x] >= min_run:
			min_x = mini(min_x, x)
			max_x = maxi(max_x, x)
	if max_x < 0 or max_y < 0:
		return {"found": false}

	## 横向锚点只看包围盒顶部往下 45% 那段（上半身），避开迈步时甩出去的腿
	var upper_y := int(min_y + (max_y - min_y) * 0.45)
	var u0 := w
	var u1 := -1
	for y in range(min_y, upper_y + 1):
		for x in range(min_x, max_x + 1):
			if _is_bg(cell.get_pixel(x, y), key):
				continue
			u0 = mini(u0, x)
			u1 = maxi(u1, x)
	var anchor_x := (min_x + max_x) * 0.5
	if u1 >= u0:
		anchor_x = (u0 + u1) * 0.5

	return {
		"found": true,
		"min_x": min_x, "max_x": max_x, "min_y": min_y, "max_y": max_y,
		"anchor_x": anchor_x,
	}


## 把一格里的角色重新摆正：横向按"上半身中心"对齐到格子中线，纵向把脚底压到基线。
func _align_cell(cell: Image, key: Color, baseline: int, m: Dictionary) -> Image:
	var w := cell.get_width()
	var h := cell.get_height()
	var out := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	out.fill(key)
	if not m["found"]:
		return cell  # 整格都是背景，原样返回，免得越界

	var min_x: int = m["min_x"]
	var max_x: int = m["max_x"]
	var min_y: int = m["min_y"]
	var max_y: int = m["max_y"]
	var anchor_x: float = m["anchor_x"]

	# 算平移量，并夹紧到不越界
	var dx := int(round(w * 0.5 - anchor_x))
	var dy := int(round(float(baseline) - float(max_y)))
	dx = clampi(dx, -min_x, w - 1 - max_x)
	dy = clampi(dy, -min_y, h - 1 - max_y)

	# 把非背景像素按平移量搬到新位置（保留绿幕，方便肉眼和原图比对）
	for y in range(min_y, max_y + 1):
		for x in range(min_x, max_x + 1):
			var px := cell.get_pixel(x, y)
			if _is_bg(px, key):
				continue
			out.set_pixel(x + dx, y + dy, px)
	return out

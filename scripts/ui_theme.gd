extends RefCounted
## 全局 UI 主题：给界面一套统一的「暗色 + 暖金」外观。
##
## 之前每个界面各写各的样式（有的用默认灰面板，有的自己画圆角），拼在一起显得碎。
## 这里集中建一个 Theme，在 main.gd 里挂到 UI 层下的每个 Control 上——
## 控件默认继承主题，此后新建的面板 / 按钮 / 输入框自动长成同一副样子。
##
## 已自带 StyleBox 的界面（HUD、锻造界面的行底板）会用覆盖样式盖过主题，不受影响。

const BG_PANEL := Color(0.09, 0.10, 0.14, 0.94)
const BORDER := Color(0.34, 0.32, 0.44, 0.90)
const ACCENT := Color(0.86, 0.72, 0.42)
const TEXT := Color(0.90, 0.91, 0.96)
const TEXT_DIM := Color(0.62, 0.64, 0.72)


## 把主题挂到 root 下每个顶层 Control（CanvasLayer 本身不能带 theme，只能逐个挂）。
## 控件继承后，其子树一并生效。
static func apply(root: Node) -> void:
	if root == null:
		return
	var t := build()
	for child in root.get_children():
		if child is Control:
			(child as Control).theme = t


static func build() -> Theme:
	var t := Theme.new()
	t.default_font_size = 15

	_panel(t, "Panel")
	_panel(t, "PanelContainer")
	_button(t)
	_line_edit(t)
	_rich_text(t)
	_label(t)
	_progress(t)
	_scroll(t)
	return t


static func _flat(bg: Color, radius: int, border: Color = Color(0, 0, 0, 0), border_w: int = 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	if border_w > 0:
		sb.border_color = border
		sb.set_border_width_all(border_w)
	return sb


static func _panel(t: Theme, type_name: String) -> void:
	var sb := _flat(BG_PANEL, 12, BORDER, 1)
	sb.content_margin_left = 12.0
	sb.content_margin_right = 12.0
	sb.content_margin_top = 10.0
	sb.content_margin_bottom = 10.0
	t.set_stylebox("panel", type_name, sb)


static func _button(t: Theme) -> void:
	var normal := _flat(Color(0.16, 0.17, 0.23, 0.98), 8, Color(0.30, 0.30, 0.40, 0.9), 1)
	normal.content_margin_left = 14.0
	normal.content_margin_right = 14.0
	normal.content_margin_top = 6.0
	normal.content_margin_bottom = 6.0

	var hover := _flat(Color(0.24, 0.24, 0.34, 1.0), 8, ACCENT, 1)
	hover.content_margin_left = 14.0
	hover.content_margin_right = 14.0
	hover.content_margin_top = 6.0
	hover.content_margin_bottom = 6.0

	var pressed := _flat(Color(0.32, 0.27, 0.18, 1.0), 8, ACCENT, 1)
	pressed.content_margin_left = 14.0
	pressed.content_margin_right = 14.0
	pressed.content_margin_top = 6.0
	pressed.content_margin_bottom = 6.0

	var disabled := _flat(Color(0.13, 0.13, 0.16, 0.60), 8, Color(0.24, 0.24, 0.30, 0.6), 1)
	disabled.content_margin_left = 14.0
	disabled.content_margin_right = 14.0
	disabled.content_margin_top = 6.0
	disabled.content_margin_bottom = 6.0

	var focus := _flat(Color(0, 0, 0, 0), 8, ACCENT, 1)

	t.set_stylebox("normal", "Button", normal)
	t.set_stylebox("hover", "Button", hover)
	t.set_stylebox("pressed", "Button", pressed)
	t.set_stylebox("disabled", "Button", disabled)
	t.set_stylebox("focus", "Button", focus)
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_hover_color", "Button", Color(1, 1, 1))
	t.set_color("font_pressed_color", "Button", Color(1.0, 0.92, 0.72))
	t.set_color("font_disabled_color", "Button", Color(0.52, 0.52, 0.58, 0.8))


static func _line_edit(t: Theme) -> void:
	var normal := _flat(Color(0.10, 0.11, 0.15, 0.98), 8, Color(0.28, 0.28, 0.36, 0.9), 1)
	normal.content_margin_left = 12.0
	normal.content_margin_right = 12.0
	normal.content_margin_top = 7.0
	normal.content_margin_bottom = 7.0

	var focus := _flat(Color(0.11, 0.12, 0.16, 1.0), 8, ACCENT, 1)
	focus.content_margin_left = 12.0
	focus.content_margin_right = 12.0
	focus.content_margin_top = 7.0
	focus.content_margin_bottom = 7.0

	t.set_stylebox("normal", "LineEdit", normal)
	t.set_stylebox("focus", "LineEdit", focus)
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_color("font_placeholder_color", "LineEdit", Color(0.55, 0.56, 0.64))
	t.set_color("caret_color", "LineEdit", ACCENT)
	t.set_color("selection_color", "LineEdit", Color(0.36, 0.32, 0.20, 0.7))


static func _rich_text(t: Theme) -> void:
	t.set_color("default_color", "RichTextLabel", TEXT)
	t.set_stylebox("normal", "RichTextLabel", _flat(Color(0, 0, 0, 0), 0))


static func _label(t: Theme) -> void:
	t.set_color("font_color", "Label", TEXT)


static func _progress(t: Theme) -> void:
	t.set_stylebox("background", "ProgressBar", _flat(Color(0.16, 0.16, 0.20, 1.0), 6))
	t.set_stylebox("fill", "ProgressBar", _flat(ACCENT, 6))


static func _scroll(t: Theme) -> void:
	# 滚动条细一点，抓握块暖色，别喧宾夺主
	t.set_stylebox("scroll", "VScrollBar", _flat(Color(0.10, 0.10, 0.14, 0.5), 6))
	var grabber := _flat(Color(0.34, 0.32, 0.42, 0.95), 6)
	grabber.content_margin_left = 2.0
	grabber.content_margin_right = 2.0
	t.set_stylebox("grabber", "VScrollBar", grabber)
	t.set_stylebox("grabber_highlight", "VScrollBar", _flat(ACCENT, 6))
	t.set_stylebox("grabber_pressed", "VScrollBar", _flat(ACCENT, 6))

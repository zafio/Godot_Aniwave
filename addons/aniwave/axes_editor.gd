@tool
extends EditorProperty
## Compact inspector editor for Aniwave.axes: one row of toggle buttons
## (X Y Z, or R G B A for colours) instead of one checkbox per line.

var _labels := PackedStringArray()
var _buttons: Array[Button] = []
var _updating := false


func _init(labels := PackedStringArray(["X", "Y", "Z", "W"])) -> void:
	_labels = labels
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 2)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in labels.size():
		var b := Button.new()
		b.text = labels[i]
		b.toggle_mode = true
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.tooltip_text = ("Add the effect to the %s channel" if labels[0] == "R" else "Add the effect to the %s component") % labels[i]
		b.toggled.connect(_on_toggled)
		row.add_child(b)
		_buttons.append(b)
		add_focusable(b)
	add_child(row)


func _ready() -> void:
	# Pressed buttons get a tint in the colour of their axis (like the 3D gizmo).
	var axis_colors := [&"axis_x_color", &"axis_y_color", &"axis_z_color"]
	var base := get_theme_stylebox(&"normal", &"Button")
	for i in _buttons.size():
		var c := get_theme_color(&"font_disabled_color", &"Editor")
		if i < 3 and has_theme_color(axis_colors[i], &"Editor"):
			c = get_theme_color(axis_colors[i], &"Editor")
		var on := StyleBoxFlat.new()
		on.bg_color = Color(c, 0.30)
		on.border_color = c
		on.set_border_width_all(1)
		on.set_corner_radius_all(3)
		for side in 4:
			on.set_content_margin(side, maxf(base.get_margin(side) - 1.0, 0.0))
		_buttons[i].add_theme_stylebox_override(&"pressed", on)
		_buttons[i].add_theme_stylebox_override(&"hover_pressed", on)


func _update_property() -> void:
	if _labels.size() > 0 and _labels[0] == "R":
		label = "Channels" # the inspector sets the label after creating us, so do it here
	var flags: int = get_edited_object().get(get_edited_property())
	_updating = true
	for i in _buttons.size():
		_buttons[i].set_pressed_no_signal(bool(flags & (1 << i)))
	_updating = false


func _on_toggled(_pressed: bool) -> void:
	if _updating:
		return
	var flags := 0
	for i in _buttons.size():
		if _buttons[i].button_pressed:
			flags |= 1 << i
	# Keep bits for components this property doesn't have (e.g. after switching
	# from a Color to a Vector2 and back).
	var old: int = get_edited_object().get(get_edited_property())
	flags |= old & ~((1 << _buttons.size()) - 1)
	emit_changed(get_edited_property(), flags)

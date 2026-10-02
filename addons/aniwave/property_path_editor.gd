@tool
extends EditorProperty
## Inspector editor for Aniwave.property: a text field plus a button
## that opens a searchable tree of the Target Node's properties, including
## properties inside its resources (materials, meshes, shader parameters...).

const Catalog := preload("res://addons/aniwave/property_catalog.gd")

var _line := LineEdit.new()
var _button := Button.new()
var _dialog: ConfirmationDialog
var _filter: LineEdit
var _tree: Tree
var _entries: Array = []
var _tracks: Array = []
var _target_name := ""
var _updating := false


func _init() -> void:
	var box := HBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_line.placeholder_text = "e.g. position or material_override:emission"
	_line.text_submitted.connect(func(_t: String) -> void: _commit_text())
	_line.focus_exited.connect(_commit_text)
	box.add_child(_line)
	_button.tooltip_text = "Browse the Target Node's properties, including materials and other resources."
	_button.pressed.connect(_open_dialog)
	box.add_child(_button)
	add_child(box)
	add_focusable(_line)
	add_focusable(_button)


func _ready() -> void:
	_button.icon = get_theme_icon(&"Search", &"EditorIcons")
	if _button.icon == null:
		_button.text = "Pick…"


func _update_property() -> void:
	_updating = true
	_line.text = str(get_edited_object().get(get_edited_property()))
	_updating = false


func _commit_text() -> void:
	if _updating:
		return
	var current := str(get_edited_object().get(get_edited_property()))
	if _line.text.strip_edges() != current:
		emit_changed(get_edited_property(), _line.text.strip_edges())


# --- browser dialog ----------------------------------------------------------

func _open_dialog() -> void:
	var obj := get_edited_object()
	var target: Node = obj.get("target_node")
	var mixer: AnimationMixer = obj.get("animation_mixer")
	_tracks = Catalog.animated_tracks(mixer)
	if target == null and _tracks.is_empty():
		var msg := "Set the Animation Mixer (to pick from its tracks) or the Target Node first."
		if EditorInterface.has_method(&"get_editor_toaster"):
			EditorInterface.call(&"get_editor_toaster").push_toast(msg, 1)
		else:
			push_warning("Aniwave: " + msg)
		return
	if _dialog == null:
		_build_dialog()
	_entries = Catalog.build(target) if target else []
	_target_name = String(target.name) if target else ""
	_dialog.title = "Pick a property" + (" of \"%s\"" % _target_name if target else "")
	_filter.text = ""
	_fill_tree()
	_dialog.popup_centered_clamped(Vector2i(560, 680), 0.8)
	_filter.grab_focus()


func _build_dialog() -> void:
	_dialog = ConfirmationDialog.new()
	_dialog.ok_button_text = "Select"
	var vb := VBoxContainer.new()
	_filter = LineEdit.new()
	_filter.placeholder_text = "Filter (e.g. emission, albedo, position)"
	_filter.clear_button_enabled = true
	_filter.right_icon = get_theme_icon(&"Search", &"EditorIcons")
	_filter.text_changed.connect(func(_t: String) -> void: _fill_tree())
	_filter.text_submitted.connect(func(_t: String) -> void: _select_first_and_confirm())
	vb.add_child(_filter)
	_tree = Tree.new()
	_tree.hide_root = true
	_tree.columns = 2
	_tree.set_column_expand(1, false)
	_tree.set_column_custom_minimum_width(1, 110)
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.item_activated.connect(_on_confirmed)
	vb.add_child(_tree)
	var note := Label.new()
	note.text = "Resource properties (materials, meshes) affect every node that shares that resource."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_color_override(&"font_color", get_theme_color(&"font_disabled_color", &"Editor"))
	vb.add_child(note)
	_dialog.add_child(vb)
	_dialog.confirmed.connect(_on_confirmed)
	add_child(_dialog)


func _fill_tree() -> void:
	_tree.clear()
	var root := _tree.create_item()
	var filter := _filter.text.strip_edges().to_lower()
	var obj := get_edited_object()
	var current := str(obj.get(get_edited_property()))
	var current_node: Node = obj.get("target_node")
	var dim := get_theme_color(&"font_disabled_color", &"Editor")

	# 1) Properties keyed in the Animation Mixer's animations.
	if not _tracks.is_empty():
		var group := _tree.create_item(root)
		group.set_text(0, "Animated tracks")
		group.set_text(1, str(_tracks.size()))
		group.set_custom_color(1, dim)
		group.set_selectable(0, false)
		group.set_selectable(1, false)
		if has_theme_icon(&"Animation", &"EditorIcons"):
			group.set_icon(0, get_theme_icon(&"Animation", &"EditorIcons"))
		var any := false
		for tr in _tracks:
			var label := "%s › %s" % [tr.node.name, tr.property]
			if filter != "" and not filter in label.to_lower():
				continue
			var item := _tree.create_item(group)
			item.set_text(0, label + ("   (whole value)" if tr.from_component else ""))
			item.set_tooltip_text(0, "%s:%s\nKeyed in: %s\nSets Target Node and Property." % [
					current_node.get_path_to(tr.node) if current_node and current_node.is_inside_tree() else tr.node.name,
					tr.property, ", ".join(tr.animations)])
			item.set_text(1, type_string(tr.type) if tr.type != TYPE_NIL else "shader param")
			item.set_custom_color(1, dim)
			item.set_metadata(0, {"node": tr.node, "property": tr.property})
			var node_icon := EditorInterface.get_editor_theme().get_icon(tr.node.get_class(), &"EditorIcons") \
					if EditorInterface.get_editor_theme().has_icon(tr.node.get_class(), &"EditorIcons") else null
			if node_icon:
				item.set_icon(0, node_icon)
			if tr.node == current_node and tr.property == current:
				item.select(0)
			any = true
		if not any:
			group.free()

	# 2) Everything on the Target Node, including resources.
	if not _entries.is_empty():
		var all := _tree.create_item(root)
		all.set_text(0, "All properties of \"%s\"" % _target_name)
		all.set_selectable(0, false)
		all.set_selectable(1, false)
		if not _add_entries(all, _entries, filter, current):
			all.free()


## Returns true if anything was added under parent.
func _add_entries(parent: TreeItem, entries: Array, filter: String, current: String) -> bool:
	var added := false
	for e in entries:
		if e.children.is_empty():
			if filter != "" and not filter in String(e.path).to_lower():
				continue
			var item := _tree.create_item(parent)
			item.set_text(0, _pretty(e.name))
			item.set_tooltip_text(0, e.path)
			item.set_text(1, type_string(e.type))
			item.set_custom_color(1, get_theme_color(&"font_disabled_color", &"Editor"))
			item.set_metadata(0, e.path)
			var icon := _type_icon(e.type)
			if icon:
				item.set_icon(0, icon)
			if e.path == current:
				item.select(0)
				_tree.scroll_to_item.call_deferred(item)
			added = true
		else:
			var branch := _tree.create_item(parent)
			branch.set_text(0, _pretty(e.name))
			branch.set_text(1, e["class"])
			branch.set_custom_color(1, get_theme_color(&"font_disabled_color", &"Editor"))
			branch.set_selectable(0, false)
			branch.set_selectable(1, false)
			if has_theme_icon(e["class"], &"EditorIcons"):
				branch.set_icon(0, get_theme_icon(e["class"], &"EditorIcons"))
			var inside := _add_entries(branch, e.children, filter, current)
			if not inside:
				branch.free()
				continue
			# Collapsed unless searching or it contains the current value.
			branch.collapsed = filter == "" and not current.begins_with(String(e.path) + ":")
			added = true
	return added


func _select_first_and_confirm() -> void:
	var item := _tree.get_root().get_next_in_tree() if _tree.get_root() else null
	while item and item.get_metadata(0) == null:
		item = item.get_next_in_tree()
	if item:
		item.select(0)
		_on_confirmed()


func _on_confirmed() -> void:
	var item := _tree.get_selected()
	if item == null or item.get_metadata(0) == null:
		return
	var meta: Variant = item.get_metadata(0)
	_dialog.hide()
	if meta is Dictionary:
		_pick_track(meta.node, meta.property)
	else:
		_line.text = String(meta)
		emit_changed(get_edited_property(), String(meta))


## Sets Target Node and Property together, as one undoable action.
func _pick_track(node: Node, prop: String) -> void:
	var obj := get_edited_object()
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Aniwave: pick animated track")
	ur.add_do_property(obj, &"target_node", node)
	ur.add_do_property(obj, &"property", prop)
	ur.add_undo_property(obj, &"target_node", obj.get("target_node"))
	ur.add_undo_property(obj, &"property", obj.get("property"))
	ur.commit_action()
	_line.text = prop


func _pretty(name: String) -> String:
	# "surface_0/material" -> "Surface 0 / Material", "shader_parameter/glow" -> "Shader Parameter / Glow"
	var parts := name.split("/")
	for i in parts.size():
		parts[i] = parts[i].capitalize()
	return " / ".join(parts)


func _type_icon(type: int) -> Texture2D:
	var icon_name := type_string(type)
	if has_theme_icon(icon_name, &"EditorIcons"):
		return get_theme_icon(icon_name, &"EditorIcons")
	return null

@tool
extends EditorInspectorPlugin
## Replaces Aniwave's Property field with a searchable property browser
## and its Axes field with a compact row of toggle buttons.

const PropertyPathEditor := preload("res://addons/aniwave/property_path_editor.gd")
const AxesEditor := preload("res://addons/aniwave/axes_editor.gd")


func _can_handle(object: Object) -> bool:
	return object is Aniwave


func _parse_property(object: Object, type: Variant.Type, name: String, hint_type: PropertyHint,
		hint_string: String, usage_flags: int, wide: bool) -> bool:
	if name == "property":
		add_property_editor(name, PropertyPathEditor.new())
		return true
	if name == "axes":
		# The hint lists this property type's components: "X,Y,Z" or "R,G,B,A".
		var labels := PackedStringArray()
		for part in hint_string.split(","):
			labels.append(part.get_slice(":", 0).strip_edges())
		if labels.is_empty() or labels[0] == "":
			return false
		add_property_editor(name, AxesEditor.new(labels))
		return true
	return false

@tool
extends RefCounted
## Lists every property an Aniwave can drive on a node, including
## properties inside its resources (materials, meshes, shader parameters...).
##
## Result: Array of entries, each a Dictionary:
##   { "name": String, "path": String, "type": int, "children": Array, "class": String }
## Leaves have "type" set to a supported Variant type and are pickable.
## Branches are resources (type TYPE_OBJECT) with "children".

const SUPPORTED := [TYPE_FLOAT, TYPE_INT, TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4, TYPE_COLOR]
const MAX_DEPTH := 4

const _SKIP := [
	"script", "process_priority", "process_physics_priority", "z_index",
	"resource_local_to_scene", "resource_path", "resource_name", "resource_scene_unique_id",
]
const _INT_HINTS_TO_SKIP := [
	PROPERTY_HINT_ENUM, PROPERTY_HINT_FLAGS,
	PROPERTY_HINT_LAYERS_2D_PHYSICS, PROPERTY_HINT_LAYERS_2D_RENDER,
	PROPERTY_HINT_LAYERS_3D_PHYSICS, PROPERTY_HINT_LAYERS_3D_RENDER,
	PROPERTY_HINT_LAYERS_AVOIDANCE,
]


static func build(object: Object) -> Array:
	if object == null:
		return []
	return _scan(object, "", 0, [])


static func _scan(object: Object, prefix: String, depth: int, visited: Array) -> Array:
	var out: Array = []
	for p in object.get_property_list():
		if not (p.usage & PROPERTY_USAGE_EDITOR) or p.name in _SKIP:
			continue
		var path: String = prefix + p.name
		if p.type == TYPE_OBJECT:
			if depth >= MAX_DEPTH:
				continue
			var value: Variant = object.get(p.name)
			if not (value is Resource) or visited.has(value.get_instance_id()):
				continue
			var children := _scan(value, path + ":", depth + 1, visited + [value.get_instance_id()])
			if children.is_empty():
				continue
			out.append({"name": p.name, "path": path, "type": TYPE_OBJECT,
					"class": value.get_class(), "children": children})
		elif p.type in SUPPORTED:
			if p.type == TYPE_INT and p.hint in _INT_HINTS_TO_SKIP:
				continue
			out.append({"name": p.name, "path": path, "type": p.type, "class": "", "children": []})
	return out


## Flat list of all pickable paths (used for tests and the fallback hint).
static func flatten(entries: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for e in entries:
		if e.children.is_empty():
			out.append(e.path)
		else:
			out.append_array(flatten(e.children))
	return out


## Every property animated by any animation of [param mixer], resolved to a
## node + property the modifier can drive. Component tracks (Bezier
## "position:x") also offer the whole parent value ("position").
## Returns Array of { "node": Node, "property": String, "type": int,
##   "animations": Array[String], "from_component": bool }
static func animated_tracks(mixer: AnimationMixer) -> Array:
	var out: Array = []
	if mixer == null or not mixer.is_inside_tree():
		return out
	var root := mixer.get_node_or_null(mixer.root_node)
	if root == null:
		return out
	var index := {} # "node_id|property" -> entry
	for anim_name in mixer.get_animation_list():
		var anim := mixer.get_animation(anim_name)
		if anim == null:
			continue
		for t in anim.get_track_count():
			var path := anim.track_get_path(t)
			var node := root.get_node_or_null(NodePath(path.get_concatenated_names()))
			if node == null or node is Aniwave:
				continue # skip tracks keying the modifiers themselves (amplitude...)
			var prop := String(path.get_concatenated_subnames())
			match anim.track_get_type(t):
				Animation.TYPE_VALUE, Animation.TYPE_BEZIER:
					pass
				Animation.TYPE_POSITION_3D:
					if prop != "": continue # skeleton bone
					prop = "position"
				Animation.TYPE_ROTATION_3D:
					if prop != "": continue
					prop = "rotation"
				Animation.TYPE_SCALE_3D:
					if prop != "": continue
					prop = "scale"
				_:
					continue
			if prop == "":
				continue
			_add_track(index, out, node, prop, anim_name, false)
			# "position:x" -> also offer "position"
			var cut := prop.rfind(":")
			if cut > 0 and prop.substr(cut + 1) in ["x", "y", "z", "w", "r", "g", "b", "a"]:
				_add_track(index, out, node, prop.substr(0, cut), anim_name, true)
	out.sort_custom(func(a, b): return (String(a.node.name) + "|" + a.property) < (String(b.node.name) + "|" + b.property))
	return out


static func _add_track(index: Dictionary, out: Array, node: Node, prop: String, anim_name: String, from_component: bool) -> void:
	var key := "%d|%s" % [node.get_instance_id(), prop]
	if index.has(key):
		var e: Dictionary = index[key]
		if not e.animations.has(anim_name):
			e.animations.append(anim_name)
		e.from_component = e.from_component and from_component
		return
	var value: Variant = node.get_indexed(prop)
	if value == null or not typeof(value) in SUPPORTED:
		# Shader parameters at their default read as null; still offer them.
		if not (value == null and "shader_parameter/" in prop):
			return
	var e := {"node": node, "property": prop, "type": typeof(value),
			"animations": [anim_name], "from_component": from_component}
	index[key] = e
	out.append(e)

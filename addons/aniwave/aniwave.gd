@tool
@icon("res://addons/aniwave/aniwave.svg")
class_name Aniwave
extends Node
## Adds a procedural Sine or Noise offset on top of whatever an AnimationPlayer
## or AnimationTree writes to a property (e.g. a Node3D's position).
##
## The offset is applied right after the mixer writes its values (via the
## mixer_applied signal), so it rides on top of your keyframes and Bezier
## curves instead of replacing them. Every parameter below is a normal
## property, so you can key it in the same AnimationPlayer: for example,
## key [member amplitude] from 0 to 1 between two position keys to fade the
## wobble in over that range.
##
## Several Aniwaves can target the same property; their offsets add up.
##
## One Aniwave can also modulate another: see [member amplitude_modulator]
## and [member frequency_modulator].

## Emitted when this wave's settings change, so Aniwaves that use it as a
## modulator can refresh.
signal wave_changed

enum Mode {
	SINE, ## Smooth periodic wave.
	NOISE, ## Smooth fractal noise (FastNoiseLite, simplex).
	TRIANGLE, ## Straight lines up and down with sharp turns.
	SQUARE, ## Jumps between high and low; Pulse Width sets the high part.
	SAWTOOTH, ## Steady ramp, then snaps back.
	RANDOM_STEPS, ## A new random value each step, held until the next.
	CURVE, ## One cycle drawn in a Curve.
}

enum Polarity {
	BOTH, ## Offset goes both ways around the keyed value.
	POSITIVE, ## Offset only goes up (e.g. a model resting on the floor that only lifts).
	NEGATIVE, ## Offset only goes down.
}

enum PolarityShape {
	REMAP, ## Squeezes the full wave into one side: smooth, never stops moving. Range 0..amplitude.
	CLAMP, ## Cuts off the other side: rests on the keyed value while the wave is below it.
	BOUNCE, ## Mirrors the other side (absolute value): sharp contact, like a bouncing ball.
}

enum TimeSource {
	ANIMATION, ## Uses the AnimationPlayer's playback position, so scrubbing and loops are deterministic.
	GLOBAL, ## Uses engine time. Use for AnimationTree or when there is no AnimationPlayer.
}

## Turn the modifier on or off. Turning it off removes its offset.
@export var enabled := true:
	set(value):
		if enabled == value:
			return
		enabled = value
		if enabled:
			_queue_refresh()
		else:
			_remove_offset()

@export_group("Target")
## The AnimationPlayer or AnimationTree whose output gets modified.
## If empty, the modifier runs every frame on its own (using global time).
@export var animation_mixer: AnimationMixer:
	set(value):
		if animation_mixer == value:
			return
		_disconnect_mixer()
		animation_mixer = value
		_freq_tables.clear()
		_connect_mixer()
		_update_process_mode()
		update_configuration_warnings()

## Use this Aniwave only as a modulator for other Aniwaves: it writes nothing
## to any property itself, so it needs no Target Node.
@export var modulator_only := false:
	set(value):
		if modulator_only == value:
			return
		if value:
			_remove_offset()
		modulator_only = value
		_invalidate_cache()
		_queue_refresh()
		update_configuration_warnings()
		notify_property_list_changed() # hide Target Node, Property and Axes

## The node whose property is modified.
@export var target_node: Node:
	set(value):
		if target_node == value:
			return
		_remove_offset()
		target_node = value
		_invalidate_cache()
		_queue_refresh()
		update_configuration_warnings()
		notify_property_list_changed() # refresh the Property dropdown

## Property to modify. Pick one from the list (it shows the Target Node's
## animatable properties) or type a sub-property like "position:x".
## Supported types: float, int, Vector2, Vector3, Vector4, Color.
@export var property: String = "position":
	set(value):
		value = str(value) # scenes saved with v1.0-1.2 stored a NodePath
		if property == value:
			return
		_remove_offset()
		property = value
		_invalidate_cache()
		_queue_refresh()
		update_configuration_warnings()
		notify_property_list_changed() # relabel Axes for the new type

## Which components receive the offset. The labels follow the property's type
## (X/Y, X/Y/Z, X/Y/Z/W or R/G/B/A); hidden for single-number properties.
@export_flags("X", "Y", "Z", "W") var axes := 1:
	set(value):
		axes = value
		_queue_refresh()

@export_group("Modifier")
@export var mode := Mode.SINE:
	set(value):
		mode = value
		if mode == Mode.CURVE and curve == null:
			curve = _default_curve()
		_queue_refresh()
		update_configuration_warnings()
		notify_property_list_changed() # show only this mode's settings

## Peak size of the offset, in the property's units. Key this to fade the effect.
@export var amplitude := 1.0:
	set(value):
		amplitude = value
		_queue_refresh()

## Waves per second (Sine) or how fast the noise changes (Noise).
@export_range(0.0, 20.0, 0.01, "or_greater", "suffix:Hz") var frequency := 1.0:
	set(value):
		frequency = value
		_queue_refresh()

## Shifts the modifier in time, in seconds.
@export var time_offset := 0.0:
	set(value):
		time_offset = value
		_queue_refresh()

@export var time_source := TimeSource.ANIMATION:
	set(value):
		time_source = value
		_queue_refresh()

@export_subgroup("Modulation")
## Another Aniwave whose wave controls this one's Amplitude, e.g. a slow sine
## that makes a noise swell and calm down. Only the other node's wave shape,
## Frequency, Phase and Polarity are used (not its Amplitude, Fade or target).
## Tick its "Modulator Only" if it shouldn't move anything itself.
@export var amplitude_modulator: Aniwave:
	set(value):
		if amplitude_modulator == value:
			return
		var old := amplitude_modulator
		amplitude_modulator = value if value != self else null
		_relisten(old)
		_modulation_changed()

## How much the modulator scales Amplitude. 1 = from nothing up to Amplitude
## (Amplitude stays the peak). 0.5 = between half and full.
@export_range(0.0, 1.0, 0.01) var amplitude_depth := 1.0:
	set(value):
		amplitude_depth = value
		_queue_refresh()

## Another Aniwave whose wave controls this one's speed, like vibrato: the
## wave speeds up and slows down while keeping its shape.
@export var frequency_modulator: Aniwave:
	set(value):
		if frequency_modulator == value:
			return
		var old := frequency_modulator
		frequency_modulator = value if value != self else null
		_relisten(old)
		_modulation_changed()

## How far the modulator pushes Frequency. 0.5 = between 50% and 150% of the
## current Frequency (with a modulator that goes both ways). The speed never
## goes below 0.
@export_range(0.0, 2.0, 0.01, "or_greater") var frequency_depth := 0.5:
	set(value):
		frequency_depth = value
		clear_frequency_cache()

@export_subgroup("Fade")
## Seconds over which the effect grows from nothing at the start of the
## animation, so the first frame is never modified. 0 = no fade.
## (Uses the AnimationPlayer's position; ignored with Time Source = Global.)
@export_range(0.0, 10.0, 0.01, "or_greater", "suffix:s") var fade_in := 0.1:
	set(value):
		fade_in = maxf(value, 0.0)
		_queue_refresh()

## Seconds over which the effect shrinks to nothing at the end of the
## animation, so looping animations join seamlessly. 0 = no fade.
@export_range(0.0, 10.0, 0.01, "or_greater", "suffix:s") var fade_out := 0.0:
	set(value):
		fade_out = maxf(value, 0.0)
		_queue_refresh()

## Limit the offset to one side of the keyed value. Applies to every selected axis;
## use a second Aniwave if another axis needs a different setting.
@export var polarity := Polarity.BOTH:
	set(value):
		polarity = value
		_queue_refresh()

## How the other half of the wave is folded into one side (only when Polarity isn't Both).
@export var polarity_shape := PolarityShape.REMAP:
	set(value):
		polarity_shape = value
		_queue_refresh()

@export_subgroup("Wave")
## Where in its cycle the wave starts (360° = one full cycle).
@export_range(-360.0, 360.0, 0.1, "suffix:°") var phase := 0.0:
	set(value):
		phase = value
		_queue_refresh()

## Extra phase per axis, so X, Y and Z don't move in lockstep (e.g. 90° gives circular motion on X+Y).
@export_range(0.0, 360.0, 0.1, "suffix:°") var axis_phase_spread := 0.0:
	set(value):
		axis_phase_spread = value
		_queue_refresh()

## Square: fraction of each cycle spent high (0.5 = even, 0.2 = short blips).
@export_range(0.01, 0.99, 0.01) var pulse_width := 0.5:
	set(value):
		pulse_width = clampf(value, 0.01, 0.99)
		_queue_refresh()

## Sawtooth: ramp down and snap up, instead of ramp up and snap down.
@export var saw_reverse := false:
	set(value):
		saw_reverse = value
		_queue_refresh()

## Rounds off the instant jumps of Square, Sawtooth and Random Steps.
## 0 = hard jumps, 1 = as smooth as the shape allows (Random Steps becomes a smooth random wander).
@export_range(0.0, 1.0, 0.01) var smoothing := 0.0:
	set(value):
		smoothing = clampf(value, 0.0, 1.0)
		_queue_refresh()

## Curve: one cycle, X from 0 to 1. Y is the offset in units of Amplitude
## (usually -1..1; values beyond that overshoot).
@export var curve: Curve:
	set(value):
		if curve and curve.changed.is_connected(_queue_refresh):
			curve.changed.disconnect(_queue_refresh)
		curve = value
		if curve:
			curve.changed.connect(_queue_refresh)
		_queue_refresh()
		update_configuration_warnings()

@export_subgroup("Noise")
## Also used by Random Steps.
@export var noise_seed := 0:
	set(value):
		noise_seed = value
		_rebuild_noise()

## More octaves add finer detail.
@export_range(1, 8) var noise_octaves := 3:
	set(value):
		noise_octaves = value
		_rebuild_noise()

## How strong the finer octaves are (0 = smooth, 1 = rough).
@export_range(0.0, 1.0, 0.01) var noise_roughness := 0.5:
	set(value):
		noise_roughness = value
		_rebuild_noise()

@export_group("Editor")
## Show the effect while scrubbing or playing in the editor.
@export var preview_in_editor := true:
	set(value):
		preview_in_editor = value
		if _should_run():
			_queue_refresh()
		else:
			_remove_offset()


# Shared bookkeeping so several modifiers can stack on one property and the
# offset never leaks into the property's real ("base") value.
# key -> {
#   "base": Variant,      # clean value, as the animation / user set it
#   "written": Variant,   # what we last wrote (base + all offsets)
#   "offsets": {},        # modifier instance id -> offset
#   "history": [],        # editor only, per component: recent written value -> its clean base
#   "history_old": [],    # editor only: previous generation of "history"
# }
static var _stacks := {}
const _HISTORY_SIZE := 256

## Internal: lets tests exercise editor-only behaviour from a script.
static var _force_editor_features := false

var _noise := FastNoiseLite.new()
var _refresh_queued := false
var _suspended := false # true while the editor is saving the scene
var _player_stopped := false # AnimationPlayer.stop() leaves no valid position until the next seek
var _watched := {} # Animation -> bound Callable (editor key fixing)
var _fix_queued := {}

# Runtime caches (rebuilt when Target Node or Property change).
var _cached_key := ""
var _cached_type := TYPE_NIL
var _cached_components := 1
var _idle_written := false # our offset is already 0 in the property: nothing to do while idle

# Modulation bookkeeping.
var _gain := 1.0 # Amplitude x amplitude modulation, for the frame being applied
var _evaluating := false # guards against modulators that depend on each other
var _building := false
var _sig_guard := false
var _emitting := false
var _version := 0 # bumped when keyed-Frequency tables are cleared
var _acc_t := -1.0e30 # live frequency integration (no animation table)
var _acc_c := 0.0


func _init() -> void:
	_rebuild_noise()
	renamed.connect(clear_frequency_cache) # the track path to our own Frequency changes


func _enter_tree() -> void:
	_freq_tables.clear() # we may have moved in the tree
	_connect_mixer()
	_update_process_mode()
	_queue_refresh()


func _ready() -> void:
	# Godot switches _process on at READY because the script defines it;
	# it's only meant to run when there is no Animation Mixer.
	_update_process_mode()


func _exit_tree() -> void:
	_remove_offset()
	_disconnect_mixer()


func _process(_delta: float) -> void:
	# Only used when there is no animation mixer.
	_apply()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_EDITOR_PRE_SAVE:
			# Keep the scene file free of the procedural offset.
			_remove_offset()
			_suspended = true
		NOTIFICATION_EDITOR_POST_SAVE:
			_suspended = false
			_queue_refresh()


const _COMMON_PROPERTIES := ["position", "rotation", "scale", "skew", "modulate", "self_modulate", "transparency"]
const _HIDDEN_PROPERTIES := ["process_priority", "process_physics_priority", "z_index"]


func _validate_property(prop: Dictionary) -> void:
	if (prop.name == "amplitude_depth" and amplitude_modulator == null) \
			or (prop.name == "frequency_depth" and frequency_modulator == null) \
			or (modulator_only and prop.name in ["target_node", "property", "axes", "amplitude", "fade_in", "fade_out"]):
		prop.usage = PROPERTY_USAGE_STORAGE
		return
	if prop.name == "axes":
		# Show only the components the chosen property actually has.
		match _target_type():
			TYPE_FLOAT, TYPE_INT:
				prop.usage = PROPERTY_USAGE_STORAGE # one value: nothing to choose
			TYPE_VECTOR2:
				prop.hint_string = "X,Y"
			TYPE_VECTOR3:
				prop.hint_string = "X,Y,Z"
			TYPE_VECTOR4:
				prop.hint_string = "X,Y,Z,W"
			TYPE_COLOR:
				prop.hint_string = "R,G,B,A"
		return
	# Only show the settings the chosen Mode uses.
	var used_by := {
		"phase": [Mode.SINE, Mode.TRIANGLE, Mode.SQUARE, Mode.SAWTOOTH, Mode.RANDOM_STEPS, Mode.CURVE],
		"axis_phase_spread": [Mode.SINE, Mode.TRIANGLE, Mode.SQUARE, Mode.SAWTOOTH, Mode.CURVE],
		"pulse_width": [Mode.SQUARE],
		"saw_reverse": [Mode.SAWTOOTH],
		"smoothing": [Mode.SQUARE, Mode.SAWTOOTH, Mode.RANDOM_STEPS],
		"curve": [Mode.CURVE],
		"noise_seed": [Mode.NOISE, Mode.RANDOM_STEPS],
		"noise_octaves": [Mode.NOISE],
		"noise_roughness": [Mode.NOISE],
	}
	if used_by.has(prop.name) and not mode in used_by[prop.name]:
		prop.usage = PROPERTY_USAGE_STORAGE
		return
	if prop.name == "axis_phase_spread" and _component_count_of_type(_target_type()) == 1 \
			and _target_type() != TYPE_NIL:
		prop.usage = PROPERTY_USAGE_STORAGE
		return
	if prop.name == "property":
		var names := get_property_choices()
		if not names.is_empty():
			# Dropdown of choices that still allows typing a custom value.
			prop.hint = PROPERTY_HINT_ENUM_SUGGESTION
			prop.hint_string = ",".join(names)


## The Target Node's properties this modifier can drive, in inspector order.
func get_property_choices() -> PackedStringArray:
	var names := PackedStringArray()
	if target_node == null or not is_instance_valid(target_node):
		return names
	for p in target_node.get_property_list():
		if not (p.usage & PROPERTY_USAGE_EDITOR):
			continue
		if not p.type in [TYPE_FLOAT, TYPE_INT, TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4, TYPE_COLOR]:
			continue
		# Skip enums/flags (ints shown as dropdowns): offsetting them makes no sense.
		if p.type == TYPE_INT and p.hint in [PROPERTY_HINT_ENUM, PROPERTY_HINT_FLAGS, PROPERTY_HINT_LAYERS_3D_PHYSICS, \
				PROPERTY_HINT_LAYERS_3D_RENDER, PROPERTY_HINT_LAYERS_2D_PHYSICS, PROPERTY_HINT_LAYERS_2D_RENDER]:
			continue
		if p.name in _HIDDEN_PROPERTIES or names.has(p.name):
			continue
		names.append(p.name)
	# Most-used properties first.
	var sorted := PackedStringArray()
	for common in _COMMON_PROPERTIES:
		if names.has(common):
			sorted.append(common)
	for n in names:
		if not sorted.has(n):
			sorted.append(n)
	return sorted


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if mode == Mode.CURVE and curve == null:
		warnings.append("Mode is Curve: assign a Curve (one cycle, X 0..1, Y about -1..1).")
	if modulator_only:
		pass # writes nothing, so no target needed
	elif target_node == null:
		warnings.append("Assign a Target Node.")
	elif property.is_empty():
		warnings.append("Set the Property to modify (e.g. position).")
	else:
		var value: Variant = _read_value()
		if value == null and "shader_parameter/" in property:
			warnings.append("Can't read shader parameter \"%s\". Set it once in the material's inspector so it has a value." % property)
		elif value == null:
			warnings.append("Target Node has no property \"%s\" (or a resource on the path is empty)." % property)
		elif not _is_supported(value):
			warnings.append("Property type %s isn't supported. Use float, int, Vector2/3/4 or Color." % type_string(typeof(value)))
	if animation_mixer == null:
		warnings.append("No Animation Mixer: the modifier will run every frame using global time.")
	return warnings


## Returns the offset this modifier would add at time [param t] for one component.
## If Frequency is keyed in the current animation, [param t] is animation time
## and the keyed speed is taken into account.
func sample(axis: int, t: float) -> float:
	return _unit_cycles(axis, _cycles_at(t)) * amplitude * _amp_factor(t - time_offset)


## The wave shape alone (after Polarity, before Amplitude), normally -1..1,
## at wave position [param base]: cycles (for Random Steps: steps) counted from
## the start, without Phase.
func _unit_cycles(axis: int, base: float) -> float:
	var s: float
	var cycles := base + (phase + axis_phase_spread * axis) / 360.0
	match mode:
		Mode.SINE:
			s = sin(TAU * cycles)
		Mode.NOISE:
			# Each axis reads a different row of the 2D noise so they move independently.
			s = _noise.get_noise_2d(base, axis * 137.0)
		Mode.TRIANGLE:
			# Same timing as Sine: 0 at the start, peak at 1/4, trough at 3/4.
			s = 1.0 - 4.0 * absf(fposmod(cycles + 0.25, 1.0) - 0.5)
		Mode.SQUARE:
			s = _square(fposmod(cycles, 1.0))
		Mode.SAWTOOTH:
			s = _sawtooth(fposmod(cycles, 1.0))
			if saw_reverse:
				s = -s
		Mode.RANDOM_STEPS:
			s = _random_steps(axis, base + phase / 360.0)
		Mode.CURVE:
			if curve == null:
				return 0.0
			# Not clamped: curves may overshoot on purpose.
			return _shape_polarity(curve.sample(fposmod(cycles, 1.0)))
	return _shape_polarity(clampf(s, -1.0, 1.0))


func _square(p: float) -> float:
	if smoothing <= 0.0:
		return 1.0 if p < pulse_width else -1.0
	# Soft edges, at most half of the shorter part of the cycle wide.
	var e := smoothing * minf(pulse_width, 1.0 - pulse_width) * 0.5
	var to_rise := fposmod(p + 0.5, 1.0) - 0.5 # signed distance to the rising edge at 0
	var to_fall := fposmod(p - pulse_width + 0.5, 1.0) - 0.5 # ...and to the falling edge
	var high := smoothstep(-e, e, to_rise) * (1.0 - smoothstep(-e, e, to_fall))
	return high * 2.0 - 1.0


func _sawtooth(p: float) -> float:
	var e := smoothing * 0.5 # part of the cycle used to ease the snap back
	if e <= 0.0 or p < 1.0 - e:
		return (p / (1.0 - e)) * 2.0 - 1.0 if e > 0.0 else p * 2.0 - 1.0
	return lerpf(1.0, -1.0, smoothstep(0.0, 1.0, (p - (1.0 - e)) / e))


func _random_steps(axis: int, steps: float) -> float:
	var k := floori(steps)
	var a := _step_value(axis, k)
	if smoothing <= 0.0:
		return a
	var into := steps - k
	var e := smoothing # last part of each step blends towards the next value
	if into < 1.0 - e:
		return a
	return lerpf(a, _step_value(axis, k + 1), smoothstep(0.0, 1.0, (into - (1.0 - e)) / e))


## Deterministic random value in -1..1 for a step (same every time you scrub).
func _step_value(axis: int, k: int) -> float:
	var h := k * 374761393 + axis * 668265263 + noise_seed * 1442695041
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(h & 0xFFFFFF) / float(0xFFFFFF) * 2.0 - 1.0


func _default_curve() -> Curve:
	# A starting shape to edit: quick rise, slower fall (like a heartbeat).
	var c := Curve.new()
	c.min_value = -1.0
	c.max_value = 1.0
	c.add_point(Vector2(0.0, 0.0))
	c.add_point(Vector2(0.15, 1.0))
	c.add_point(Vector2(0.4, -0.4))
	c.add_point(Vector2(1.0, 0.0))
	return c


## Folds a -1..1 value into 0..1 (or -1..0) according to the polarity settings.
func _shape_polarity(s: float) -> float:
	if polarity == Polarity.BOTH:
		return s
	var one_sided: float
	match polarity_shape:
		PolarityShape.REMAP:
			one_sided = (s + 1.0) * 0.5
		PolarityShape.CLAMP:
			one_sided = maxf(s, 0.0)
		_:
			one_sided = absf(s)
	return one_sided if polarity == Polarity.POSITIVE else -one_sided


## Re-applies the offset immediately (normally done automatically).
func refresh() -> void:
	_apply()


# --- internals -------------------------------------------------------------

func _on_mixer_applied() -> void:
	_player_stopped = false # the mixer just processed, so its position is valid
	_apply()


func _on_current_animation_changed(anim_name: String) -> void:
	_player_stopped = anim_name == ""
	if _player_stopped:
		_queue_refresh()


func _apply() -> void:
	_refresh_queued = false
	if modulator_only or not _should_run() or not _target_ok():
		return

	# Idle (amplitude 0, faded out, or no animation): once our offset is out of
	# the property there's nothing left to do, so skip all work.
	var fade := _fade_factor()
	var idle := absf(amplitude) < 1e-6 or fade <= 0.0
	if idle and _idle_written:
		return

	var current: Variant = _read_value()
	var type := typeof(current)
	if type != _cached_type:
		if not type in _SUPPORTED_TYPES:
			return
		_cached_type = type
		_cached_components = _component_count_of_type(type)

	var key := _key()
	var entry: Dictionary = _stacks.get(key, {})
	if entry.is_empty() or type != typeof(entry.base):
		entry = {"base": current, "written": current, "offsets": {}, "history": [], "history_old": []}
		_stacks[key] = entry
	else:
		_reconcile(entry, current)

	var offset: Variant
	if idle:
		offset = current * 0 # zero of the right type
	else:
		var wave_t := _get_time()
		_gain = amplitude if amplitude_modulator == null else amplitude * _amp_factor(wave_t - time_offset)
		offset = _make_offset(current, _cycles_at(wave_t))
		if fade < 1.0:
			offset = int(roundf(offset * fade)) if type == TYPE_INT else offset * fade
	entry.offsets[get_instance_id()] = offset
	_write(entry)
	_idle_written = idle


func _remove_offset() -> void:
	_idle_written = false
	if not _target_ok():
		return
	var key := _key()
	if not _stacks.has(key):
		return
	var entry: Dictionary = _stacks[key]
	if not entry.offsets.has(get_instance_id()):
		return
	var current: Variant = _read_value()
	if typeof(current) == typeof(entry.base):
		_reconcile(entry, current)
		entry.offsets.erase(get_instance_id())
		_write(entry)
	else:
		entry.offsets.erase(get_instance_id())
	if entry.offsets.is_empty():
		_stacks.erase(key)


## Works out the clean base value from what is in the property now.
## Only components that someone else changed since our last write become
## the new base; untouched components keep their known clean value, so the
## offset can't leak in (e.g. a Bezier track on position:x with a modifier on Y).
func _reconcile(entry: Dictionary, current: Variant) -> void:
	var written: Variant = entry.written
	var n := _component_count(current)
	if n == 1:
		if current != written:
			# The editor sometimes restores an older value we wrote (closing the
			# animation panel, Reset on Save, undo): map it back to its clean base.
			entry.base = _history_lookup(entry, 0, current)
		return
	var base: Variant = entry.base
	for i in n:
		if current[i] != written[i]:
			base[i] = _history_lookup(entry, i, current[i])
	entry.base = base


func _history_lookup(entry: Dictionary, i: int, v: Variant) -> Variant:
	var history: Array = entry.history
	if i < history.size() and history[i].has(v):
		return history[i][v]
	var old: Array = entry.history_old
	if i < old.size() and old[i].has(v):
		return old[i][v]
	return v


func _write(entry: Dictionary) -> void:
	var total: Variant = entry.base
	for offset: Variant in entry.offsets.values():
		total = total + offset
	target_node.set_indexed(property, total)
	# Read back: the property may store with less precision (e.g. 32-bit floats).
	entry.written = _read_value()
	# The history only exists to undo stale values the editor restores;
	# nothing does that in a running game, so skip it there.
	if _editor_features():
		_remember(entry)


## Per component: remembers "we wrote W, its clean value was B".
func _remember(entry: Dictionary) -> void:
	var n := _component_count(entry.written)
	var history: Array = entry.history
	while history.size() < n:
		history.append({})
	for i in n:
		var w: Variant = entry.written if n == 1 else entry.written[i]
		var b: Variant = entry.base if n == 1 else entry.base[i]
		var h: Dictionary = history[i]
		if w == b:
			h.erase(w) # no offset here: a later W really means W
			if i < entry.history_old.size():
				entry.history_old[i].erase(w)
		else:
			h[w] = b
	# Two generations instead of evicting one entry at a time (which needed
	# an allocation per write): when the current one is full, it becomes old.
	var full := false
	for h: Dictionary in history:
		if h.size() > _HISTORY_SIZE:
			full = true
			break
	if full:
		entry.history_old = history
		var fresh: Array = []
		for i in n:
			fresh.append({})
		entry.history = fresh


## Variant type of the chosen property, or TYPE_NIL if it can't be read yet.
func _target_type() -> int:
	if not _target_ok():
		return TYPE_NIL
	return typeof(_read_value())


func _component_count_of_type(type: int) -> int:
	match type:
		TYPE_VECTOR2:
			return 2
		TYPE_VECTOR3:
			return 3
		TYPE_VECTOR4, TYPE_COLOR:
			return 4
	return 1


## Reads the property. Shader parameters left at the shader's default read
## back as null, so fall back to the default value declared in the shader.
func _read_value() -> Variant:
	var value: Variant = target_node.get_indexed(property)
	if value != null:
		return value
	var marker := "shader_parameter/"
	var at := property.rfind(marker)
	if at < 0:
		return null
	var owner_path := property.substr(0, at).trim_suffix(":")
	var owner: Variant = target_node.get_indexed(owner_path) if owner_path != "" else target_node
	if owner is ShaderMaterial and owner.shader != null:
		return RenderingServer.shader_get_parameter_default(owner.shader.get_rid(), property.substr(at + marker.length()))
	return null


func _component_count(value: Variant) -> int:
	if typeof(value) == _cached_type:
		return _cached_components
	match typeof(value):
		TYPE_VECTOR2:
			return 2
		TYPE_VECTOR3:
			return 3
		TYPE_VECTOR4, TYPE_COLOR:
			return 4
	return 1


func _component_index(subname: String) -> int:
	match subname:
		"x", "r":
			return 0
		"y", "g":
			return 1
		"z", "b":
			return 2
		"w", "a":
			return 3
	return -1


func _make_offset(like: Variant, base: float) -> Variant:
	match typeof(like):
		TYPE_FLOAT:
			return _unit_cycles(0, base) * _gain # single value: Axes doesn't apply
		TYPE_INT:
			return int(roundf(_unit_cycles(0, base) * _gain))
		TYPE_VECTOR2:
			return Vector2(_axis(0, base), _axis(1, base))
		TYPE_VECTOR3:
			return Vector3(_axis(0, base), _axis(1, base), _axis(2, base))
		TYPE_VECTOR4:
			return Vector4(_axis(0, base), _axis(1, base), _axis(2, base), _axis(3, base))
		TYPE_COLOR:
			return Color(_axis(0, base), _axis(1, base), _axis(2, base), _axis(3, base))
	return null


func _axis(i: int, base: float) -> float:
	return _unit_cycles(i, base) * _gain if axes & (1 << i) else 0.0


# --- keyed Frequency --------------------------------------------------------
# The wave position is frequency x time only while Frequency is constant. If
# Frequency is keyed in the playing animation, that would make the wave rush
# or jump whenever it changes. Instead the position is the integral of the
# keyed frequency over time, so the speed is exactly what was keyed. It is
# still a pure function of the animation time, so scrubbing stays repeatable.
# The integral is tabulated once per animation (and again when it is edited).

const _NO_TABLE := {}
const _TABLE_STEPS_PER_SECOND := 240.0
const _TABLE_MAX_STEPS := 20000

var _freq_tables := {} # Animation -> { cum, dt, f0, f1 } (empty = Frequency not keyed)


## Wave position in cycles at animation time [param t] (shifted by Time Offset
## when called from the frame update).
func _cycles_at(t: float) -> float:
	var table := _frequency_table()
	if table.is_empty():
		if _fm_active():
			return _integrate_live(t)
		return frequency * t
	if t <= 0.0:
		return table.f0 * t
	var cum: PackedFloat64Array = table.cum
	var last := cum.size() - 1
	var dt: float = table.dt
	var x := t / dt
	var i := int(x)
	if i >= last:
		return cum[last] + table.f1 * (t - last * dt)
	return lerpf(cum[i], cum[i + 1], x - i)


func _frequency_table() -> Dictionary:
	if time_source != TimeSource.ANIMATION or not (animation_mixer is AnimationPlayer):
		return _NO_TABLE
	var player := animation_mixer as AnimationPlayer
	if player.assigned_animation == &"":
		return _NO_TABLE
	var anim := player.get_animation(player.assigned_animation)
	if anim == null:
		return _NO_TABLE
	var table: Variant = _freq_tables.get(anim)
	# A table that includes frequency modulation goes stale when the modulator changes.
	if table != null and not table.is_empty() and table.sig != _fm_signature():
		table = null
	if table == null:
		table = _build_frequency_table(player, anim)
		_freq_tables[anim] = table
	return table


func _build_frequency_table(player: AnimationPlayer, anim: Animation) -> Dictionary:
	if _building or not is_inside_tree() or anim.length <= 0.0:
		return _NO_TABLE
	var root := player.get_node_or_null(player.root_node)
	if root == null:
		return _NO_TABLE
	var path := NodePath(String(root.get_path_to(self)) + ":frequency")
	var bezier := false
	var track := anim.find_track(path, Animation.TYPE_VALUE)
	if track < 0:
		track = anim.find_track(path, Animation.TYPE_BEZIER)
		bezier = true
	var keyed := track >= 0 and anim.track_is_enabled(track) and anim.track_get_key_count(track) > 0
	var fm := _fm_active()
	if not keyed and not fm:
		return _NO_TABLE

	_building = true
	var steps := clampi(ceili(anim.length * _TABLE_STEPS_PER_SECOND), 2, _TABLE_MAX_STEPS)
	var dt := anim.length / steps
	var cum := PackedFloat64Array()
	cum.resize(steps + 1)
	var prev := _table_frequency(anim, track, bezier, keyed, fm, 0.0)
	var f0 := prev
	for i in range(1, steps + 1):
		var f := _table_frequency(anim, track, bezier, keyed, fm, i * dt)
		cum[i] = cum[i - 1] + 0.5 * (prev + f) * dt # trapezoid rule
		prev = f
	_building = false
	return {"cum": cum, "dt": dt, "f0": f0, "f1": prev, "sig": _fm_signature()}


## Speed at wave time [param t]: keyed (or constant) Frequency, times the
## frequency modulation.
func _table_frequency(anim: Animation, track: int, bezier: bool, keyed: bool, fm: bool, t: float) -> float:
	var f := _keyed_frequency(anim, track, bezier, t) if keyed else frequency
	return f * _freq_factor(t - time_offset) if fm else f


func _keyed_frequency(anim: Animation, track: int, bezier: bool, t: float) -> float:
	var v: Variant = anim.bezier_track_interpolate(track, t) if bezier else anim.value_track_interpolate(track, t)
	return float(v) if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT else frequency


## Forget the tabulated keyed-Frequency curves. This happens by itself when an
## animation is edited in the editor; call it if you change keys from code at runtime.
func clear_frequency_cache() -> void:
	_freq_tables.clear()
	_version += 1
	_queue_refresh()


# --- modulation ---------------------------------------------------------------
# Another Aniwave's wave can scale this one's Amplitude and drive its Frequency.
# Both are pure functions of the playhead, so scrubbing stays repeatable and
# there is no dependence on the order of the nodes in the tree.

func _fm_active() -> bool:
	return frequency_modulator != null and is_instance_valid(frequency_modulator) \
			and absf(frequency_depth) > 1e-6


## This node's wave shape (after Polarity, before Amplitude and Fade) at wave
## time [param t], for use by other Aniwaves. Uses the first axis.
func _unit_wave_at(t: float) -> float:
	if _evaluating:
		return 0.0 # two modulators that use each other: break the loop
	_evaluating = true
	var v := _unit_cycles(0, _cycles_at(t))
	_evaluating = false
	return v


## Same, at animation time [param anim_t] (this node's Time Offset applied).
func _modulation_at(anim_t: float) -> float:
	return _unit_wave_at(anim_t + time_offset)


## 0..1+ multiplier that the amplitude modulator applies at animation time [param anim_t].
func _amp_factor(anim_t: float) -> float:
	var m := amplitude_modulator
	if m == null or not is_instance_valid(m):
		return 1.0
	var s := m._modulation_at(anim_t)
	var u: float # 0..1 position of the modulator within its range
	match m.polarity:
		Polarity.BOTH:
			u = (s + 1.0) * 0.5
		Polarity.POSITIVE:
			u = s
		_:
			u = -s
	return maxf(0.0, 1.0 - clampf(amplitude_depth, 0.0, 1.0) * (1.0 - u))


## Multiplier on Frequency at animation time [param anim_t].
func _freq_factor(anim_t: float) -> float:
	var m := frequency_modulator
	if m == null or not is_instance_valid(m):
		return 1.0
	return maxf(0.0, 1.0 + frequency_depth * m._modulation_at(anim_t))


## Identifies everything that decides this node's frequency modulation, so a
## cached table can tell when it is out of date. 0 when there is none.
func _fm_signature() -> int:
	if not _fm_active():
		return 0
	return hash([frequency_modulator.get_instance_id(), frequency_depth, time_offset,
			frequency_modulator._wave_signature()])


## Everything that shapes this node's wave over time (but not Amplitude/Fade,
## and not Frequency while it's keyed, which changes every frame).
func _wave_signature() -> int:
	if _sig_guard:
		return 0
	_sig_guard = true
	var table := _frequency_table()
	var speed: Variant = frequency
	if not table.is_empty():
		speed = [table.cum.size(), table.f0, table.f1, table.sig]
	var curve_sig: Variant = 0
	if curve != null:
		var pts := []
		for i in curve.point_count:
			pts.append([curve.get_point_position(i), curve.get_point_left_tangent(i),
					curve.get_point_right_tangent(i)])
		curve_sig = [curve.get_instance_id(), curve.min_value, curve.max_value, pts]
	var sig := hash([mode, speed, phase, pulse_width, saw_reverse, smoothing, noise_seed,
			noise_octaves, noise_roughness, polarity, polarity_shape, time_offset,
			time_source, curve_sig, _version])
	_sig_guard = false
	return sig


const _LIVE_STEP := 1.0 / 120.0


## Wave position when the speed is modulated but there's no animation table
## (Global time or AnimationTree): the speed is added up frame to frame, so it
## is smooth but not repeatable when scrubbing.
func _integrate_live(t: float) -> float:
	if t < _acc_t or t - _acc_t > 2.0:
		_acc_t = 0.0 if t <= 30.0 else t
		_acc_c = 0.0
	while _acc_t < t:
		var step := minf(_LIVE_STEP, t - _acc_t)
		_acc_c += frequency * _freq_factor(_acc_t + step * 0.5 - time_offset) * step
		_acc_t += step
	return _acc_c


func _relisten(old: Aniwave) -> void:
	if old != null and is_instance_valid(old) and old != amplitude_modulator and old != frequency_modulator \
			and old.wave_changed.is_connected(_on_modulator_changed):
		old.wave_changed.disconnect(_on_modulator_changed)
	for m in [amplitude_modulator, frequency_modulator]:
		if m != null and not m.wave_changed.is_connected(_on_modulator_changed):
			m.wave_changed.connect(_on_modulator_changed)


func _on_modulator_changed() -> void:
	_queue_refresh()


func _modulation_changed() -> void:
	clear_frequency_cache()
	update_configuration_warnings()
	notify_property_list_changed() # show or hide the Depth settings


func _get_time() -> float:
	var pos := _animation_position()
	if pos >= 0.0:
		return pos + time_offset
	return Time.get_ticks_msec() / 1000.0 + time_offset


## Playhead of the AnimationPlayer in seconds, or -1 if not applicable.
func _animation_position() -> float:
	if time_source != TimeSource.ANIMATION or not (animation_mixer is AnimationPlayer):
		return -1.0
	var player := animation_mixer as AnimationPlayer
	if player.assigned_animation == &"":
		return -1.0
	if _player_stopped:
		return 0.0 # stop() rewinds to the start
	return player.current_animation_position


## 0..1 multiplier from Fade In / Fade Out (1 = full effect).
func _fade_factor() -> float:
	# Following an AnimationPlayer but it has no animation yet (before play(),
	# fresh editor session): there is no playhead, so leave the property alone
	# instead of freezing a random offset from engine time.
	if time_source == TimeSource.ANIMATION and animation_mixer is AnimationPlayer \
			and (animation_mixer as AnimationPlayer).assigned_animation == &"":
		return 0.0
	if fade_in <= 0.0 and fade_out <= 0.0:
		return 1.0
	var pos := _animation_position()
	if pos < 0.0:
		return 1.0
	var f := 1.0
	if fade_in > 0.0:
		f *= smoothstep(0.0, fade_in, pos)
	if fade_out > 0.0:
		var player := animation_mixer as AnimationPlayer
		var anim := player.get_animation(player.assigned_animation)
		if anim:
			f *= smoothstep(0.0, fade_out, anim.length - pos)
	return f


const _SUPPORTED_TYPES := [TYPE_FLOAT, TYPE_INT, TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4, TYPE_COLOR]


func _is_supported(value: Variant) -> bool:
	return typeof(value) in _SUPPORTED_TYPES


func _should_run() -> bool:
	if not enabled or _suspended or not is_inside_tree():
		return false
	if Engine.is_editor_hint() and not preview_in_editor:
		return false
	return true


func _target_ok() -> bool:
	return target_node != null and is_instance_valid(target_node) and not property.is_empty()


func _key() -> String:
	if _cached_key == "":
		_cached_key = "%d|%s" % [target_node.get_instance_id(), property]
	return _cached_key


func _invalidate_cache() -> void:
	_cached_key = ""
	_cached_type = TYPE_NIL
	_idle_written = false


func _queue_refresh() -> void:
	if not _emitting:
		_emitting = true
		wave_changed.emit()
		_emitting = false
	# Lets parameter changes show up in the editor without waiting for the
	# mixer. Deferred so it runs once even if many properties change.
	if _refresh_queued or not is_inside_tree():
		return
	_refresh_queued = true
	_apply.call_deferred()


func _connect_mixer() -> void:
	if animation_mixer == null:
		return
	if not animation_mixer.mixer_applied.is_connected(_on_mixer_applied):
		animation_mixer.mixer_applied.connect(_on_mixer_applied)
	if animation_mixer is AnimationPlayer \
			and not animation_mixer.current_animation_changed.is_connected(_on_current_animation_changed):
		animation_mixer.current_animation_changed.connect(_on_current_animation_changed)
	if _editor_features() and not animation_mixer.animation_list_changed.is_connected(_watch_animations):
		animation_mixer.animation_list_changed.connect(_watch_animations)
	_watch_animations()


func _disconnect_mixer() -> void:
	_unwatch_animations()
	if animation_mixer == null or not is_instance_valid(animation_mixer):
		return
	if animation_mixer.mixer_applied.is_connected(_on_mixer_applied):
		animation_mixer.mixer_applied.disconnect(_on_mixer_applied)
	if animation_mixer is AnimationPlayer \
			and animation_mixer.current_animation_changed.is_connected(_on_current_animation_changed):
		animation_mixer.current_animation_changed.disconnect(_on_current_animation_changed)
	if animation_mixer.animation_list_changed.is_connected(_watch_animations):
		animation_mixer.animation_list_changed.disconnect(_watch_animations)


func _editor_features() -> bool:
	return Engine.is_editor_hint() or _force_editor_features


# --- editor: keep inserted keys clean ---------------------------------------
# The inspector and the "insert key" buttons read the property as it is on
# screen, i.e. with the procedural offset included. Whenever an animation
# changes, any key that holds exactly the value we wrote is swapped for the
# clean base value, so the effect never gets baked into your keys.

func _watch_animations() -> void:
	_unwatch_animations()
	if not _editor_features() or animation_mixer == null:
		return
	for anim_name in animation_mixer.get_animation_list():
		var anim := animation_mixer.get_animation(anim_name)
		if anim == null or _watched.has(anim):
			continue
		var callable := _on_animation_changed.bind(anim)
		anim.changed.connect(callable)
		_watched[anim] = callable


func _unwatch_animations() -> void:
	for anim: Animation in _watched:
		if is_instance_valid(anim) and anim.changed.is_connected(_watched[anim]):
			anim.changed.disconnect(_watched[anim])
	_watched.clear()


func _on_animation_changed(anim: Animation) -> void:
	_freq_tables.erase(anim) # keys may have changed
	if _fix_queued.has(anim):
		return
	_fix_queued[anim] = true
	_fix_inserted_keys.call_deferred(anim)


func _fix_inserted_keys(anim: Animation) -> void:
	_fix_queued.erase(anim)
	if not is_instance_valid(anim) or not _target_ok() or animation_mixer == null:
		return
	var entry: Dictionary = _stacks.get(_key(), {})
	if entry.is_empty() or not entry.offsets.has(get_instance_id()):
		return
	# Only the first modifier on a property does the fixing (they share the entry).
	if entry.offsets.keys()[0] != get_instance_id():
		return
	var root := animation_mixer.get_node_or_null(animation_mixer.root_node)
	if root == null:
		return

	# Keys are inserted at the playhead, so when we know it, only look there.
	var at_time := -1.0
	if animation_mixer is AnimationPlayer:
		var player := animation_mixer as AnimationPlayer
		if player.assigned_animation != &"" and player.get_animation(player.assigned_animation) == anim:
			at_time = player.current_animation_position

	var ours := property
	var written: Variant = entry.written
	var base: Variant = entry.base
	var fixed_any := false

	for t in anim.get_track_count():
		var track_type := anim.track_get_type(t)
		if track_type != Animation.TYPE_VALUE and track_type != Animation.TYPE_BEZIER:
			continue
		var path := anim.track_get_path(t)
		if root.get_node_or_null(NodePath(path.get_concatenated_names())) != target_node:
			continue
		var track_prop := String(path.get_concatenated_subnames())

		# How the track's values relate to our property.
		var relation := ""
		var comp := -1
		if track_prop == ours:
			relation = "same"
		elif track_prop.begins_with(ours + ":"):
			relation = "track_is_component" # e.g. track position:x, modifier on position
			comp = _component_index(track_prop.substr(ours.length() + 1))
		elif ours.begins_with(track_prop + ":"):
			relation = "ours_is_component" # e.g. track position, modifier on position:x
			comp = _component_index(ours.substr(track_prop.length() + 1))
		else:
			continue
		if relation != "same" and comp < 0:
			continue

		for k in anim.track_get_key_count(t):
			if at_time >= 0.0 and absf(anim.track_get_key_time(t, k) - at_time) > 0.001:
				continue
			var is_bezier := track_type == Animation.TYPE_BEZIER
			var v: Variant = anim.bezier_track_get_key_value(t, k) if is_bezier else anim.track_get_key_value(t, k)
			var replacement: Variant = null
			var replace := false
			match relation:
				"same":
					if typeof(v) == typeof(written) and v == written and v != base:
						replacement = base
						replace = true
				"track_is_component":
					if _is_number(v) and comp < _component_count(written) \
							and is_equal_approx(v, written[comp]) and not is_equal_approx(v, base[comp]):
						replacement = base[comp]
						replace = true
				"ours_is_component":
					if _component_count(v) > 1 and comp < _component_count(v) and _is_number(written) \
							and is_equal_approx(v[comp], written) and not is_equal_approx(v[comp], base):
						replacement = v
						replacement[comp] = base
						replace = true
			if replace:
				if is_bezier:
					anim.bezier_track_set_key_value(t, k, replacement)
				else:
					anim.track_set_key_value(t, k, replacement)
				fixed_any = true

	if fixed_any:
		_queue_refresh()


func _is_number(v: Variant) -> bool:
	return typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT


func _update_process_mode() -> void:
	set_process(animation_mixer == null)


func _rebuild_noise() -> void:
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.seed = noise_seed
	_noise.frequency = 1.0
	_noise.fractal_type = FastNoiseLite.FRACTAL_FBM if noise_octaves > 1 else FastNoiseLite.FRACTAL_NONE
	_noise.fractal_octaves = noise_octaves
	_noise.fractal_gain = noise_roughness
	_queue_refresh()

@tool
extends EditorPlugin
# Aniwave itself registers through class_name. The plugin adds the
# searchable property browser to its inspector, so keep it enabled in
# Project Settings > Plugins.

var _inspector_plugin: EditorInspectorPlugin


func _enter_tree() -> void:
	_inspector_plugin = preload("res://addons/aniwave/inspector_plugin.gd").new()
	add_inspector_plugin(_inspector_plugin)


func _exit_tree() -> void:
	if _inspector_plugin:
		remove_inspector_plugin(_inspector_plugin)
		_inspector_plugin = null

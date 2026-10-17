@tool
class_name SettingsStore
extends RefCounted
## Reads and writes Settings as a ConfigFile ([display] (language, window mode, UI scale), [audio] (volumes, mute), [gameplay] (battle speed, auto end turn), [keys], [hints]). A missing or
## unreadable file gives defaults (with a warning), and unknown or invalid values fall back
## one by one, so a hand-edited file never crashes the game.

const DEFAULT_PATH := "user://settings.cfg"

var path := DEFAULT_PATH


func _init(settings_path := DEFAULT_PATH) -> void:
	path = settings_path


func load_or_default() -> Settings:
	var settings := Settings.new()
	if not FileAccess.file_exists(path):
		return settings
	var config := ConfigFile.new()
	var error := config.load(path)
	if error != OK:
		push_warning("SettingsStore: can't read %s (%s); using defaults" % [path, error_string(error)])
		return settings
	var language: Variant = config.get_value("display", "language", "")
	if language is String and Localization.LANGUAGES.has(language):
		settings.language = language
	for field: String in ["master_volume", "music_volume", "effects_volume"]:
		var volume: Variant = config.get_value("audio", field, settings.get(field))
		if _is_number(volume) and is_finite(float(volume)):
			settings.set(field, clampf(float(volume), 0.0, 1.0))
	for field: String in ["battle_speed", "net_battle_speed"]:
		var speed: Variant = config.get_value("gameplay", field, settings.get(field))
		if _is_number(speed) and int(speed) in Settings.BattleSpeed.values():
			settings.set(field, int(speed))
	# "auto_end" (was "auto_end_turn" while it was off by default): everyone starts with it on again.
	var auto_end: Variant = config.get_value("gameplay", "auto_end", settings.auto_end_turn)
	if auto_end is bool:
		settings.auto_end_turn = auto_end
	var qa: Variant = config.get_value("gameplay", "qa_tools", false)
	if qa is bool:
		settings.qa_tools = qa
	var muted: Variant = config.get_value("audio", "muted", false)
	if muted is bool:
		settings.muted = muted
	var mode: Variant = config.get_value("display", "window_mode", Settings.WindowMode.WINDOWED)
	if _is_number(mode) and int(mode) in Settings.WindowMode.values():
		settings.window_mode = int(mode) as Settings.WindowMode
	var scale_value: Variant = config.get_value("display", "ui_scale", 1.0)
	if _is_number(scale_value):
		settings.ui_scale = Settings.nearest_scale(float(scale_value))
	var taken: Dictionary[int, bool] = {}
	for action in Settings.REBINDABLE:
		var code: Variant = config.get_value("keys", action, 0)
		# A hand-edited file may hold anything: only real, free, unreserved keys are kept.
		if _is_number(code) and Settings.is_bindable_key(int(code)) and not taken.has(int(code)):
			settings.bindings[action] = int(code)
			taken[int(code)] = true
	var hints: Variant = config.get_value("hints", "dismissed", PackedStringArray())
	if hints is PackedStringArray or hints is Array:
		for id: Variant in hints:
			settings.dismissed_hints.append(str(id))
	return settings


static func _is_number(value: Variant) -> bool:
	return typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT


## Writes to a temporary file first, then swaps it in. False (with an error) on failure.
func save(settings: Settings) -> bool:
	var config := ConfigFile.new()
	config.set_value("gameplay", "battle_speed", settings.battle_speed)
	config.set_value("gameplay", "net_battle_speed", settings.net_battle_speed)
	config.set_value("gameplay", "auto_end", settings.auto_end_turn)
	config.set_value("gameplay", "qa_tools", settings.qa_tools)
	config.set_value("audio", "master_volume", settings.master_volume)
	config.set_value("audio", "music_volume", settings.music_volume)
	config.set_value("audio", "effects_volume", settings.effects_volume)
	config.set_value("audio", "muted", settings.muted)
	config.set_value("display", "language", settings.language)
	config.set_value("display", "window_mode", settings.window_mode)
	config.set_value("display", "ui_scale", settings.ui_scale)
	for action in settings.bindings:
		config.set_value("keys", action, settings.bindings[action])
	config.set_value("hints", "dismissed", PackedStringArray(settings.dismissed_hints))
	var temp_path := path + ".tmp"
	var error := config.save(temp_path)
	if error != OK:
		push_error("SettingsStore: can't write %s (%s)" % [temp_path, error_string(error)])
		return false
	error = DirAccess.rename_absolute(temp_path, path)
	if error != OK:
		push_error("SettingsStore: can't replace %s (%s)" % [path, error_string(error)])
		return false
	return true


func delete() -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

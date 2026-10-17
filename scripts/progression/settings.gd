@tool
class_name Settings
extends RefCounted
## Player preferences: language, volumes, battle speed, window mode, UI scale, rebound keys and the hints already seen.
## Plain data; SettingsStore saves it (user://settings.cfg, apart from the profile so
## resetting the save keeps it) and SettingsApplier puts it into effect.

enum WindowMode { WINDOWED, FULLSCREEN }
## How fast battles play: animations at normal speed, twice as fast, or skipped.
enum BattleSpeed { NORMAL, FAST, INSTANT }

const UI_SCALES: Array[float] = [0.75, 1.0, 1.25, 1.5]
## The actions the player can rebind, in display order. Right click and Esc (`cancel`)
## are fixed.
const REBINDABLE: Array[StringName] = [&"spell_1", &"spell_2", &"spell_3", &"spell_4", &"spell_5",
		&"end_turn", &"camera_rotate_left", &"camera_rotate_right", &"camera_toggle_view", &"camera_recenter", &"show_order", &"mark"]
const ACTION_LABELS: Dictionary[StringName, String] = {
	&"spell_1": "Spell 1", &"spell_2": "Spell 2", &"spell_3": "Spell 3", &"spell_4": "Spell 4", &"spell_5": "Spell 5",
	&"end_turn": "End turn", &"camera_rotate_left": "Turn camera left", &"camera_rotate_right": "Turn camera right",
	&"camera_toggle_view": "Toggle top view", &"camera_recenter": "Recenter camera", &"show_order": "Turn order",
	&"mark": "Point out (multiplayer)",
}

## Keys no action may take: they drive the menus (and the hint card's Enter).
const RESERVED_KEYS: Array[Key] = [KEY_ENTER, KEY_KP_ENTER, KEY_ESCAPE, KEY_TAB, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT]
const MODIFIER_KEYS: Array[Key] = [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META]
## Fixed actions on keys that a rebindable action must not share (spells past the fifth).
const FIXED_KEYED_ACTIONS: Array[StringName] = [&"spell_6", &"spell_7", &"spell_8", &"spell_9"]

## A key of Localization.LANGUAGES, or "" to follow the system's language.
var language := ""
## Loudness sliders, 0 to 1: everything, the music, the effects; and a mute for all.
var master_volume := 0.8
var music_volume := 0.5
var effects_volume := 0.8
var muted := false
var battle_speed := BattleSpeed.NORMAL
## The speed of multiplayer fights (each player's own: the playback is local), changed with the fight's speed button.
var net_battle_speed := BattleSpeed.FAST
## Ends the turn by itself once the acting hero can neither move nor afford a spell.
var auto_end_turn := true
## Developer tools: the title's QA screen, Auto in battle, cheats in QA battles.
var qa_tools := false
var window_mode := WindowMode.WINDOWED
var ui_scale := 1.0
## Action → physical keycode, only for actions the player changed.
var bindings: Dictionary[StringName, int] = {}
## Ids of the hints the player dismissed (see Hints).
var dismissed_hints: Array[String] = []


## Whether a physical keycode can be bound: a real key that isn't a modifier or reserved.
static func is_bindable_key(keycode: int) -> bool:
	return keycode > 0 and keycode not in RESERVED_KEYS and keycode not in MODIFIER_KEYS


## The allowed UI scale nearest to `value`.
static func nearest_scale(value: float) -> float:
	var best := UI_SCALES[0]
	for candidate in UI_SCALES:
		if absf(candidate - value) < absf(best - value):
			best = candidate
	return best


## The action's name in the current language (static: no `tr()`, so TranslationServer.translate).
static func action_label(action: StringName) -> String:
	if action in FIXED_KEYED_ACTIONS:
		return TranslationServer.translate("Spell %s") % str(action).trim_prefix("spell_")
	return TranslationServer.translate(ACTION_LABELS.get(action, str(action)))

@tool
class_name AudioSet
extends Resource
## The game's sounds: one stream per sound event and one per music track. Content is data: a
## new sound is a file in this set. A missing stream just plays nothing.

## What the game asks to hear (events of the battle, the screens and the result).
const SFX_EVENTS: Array[StringName] = [&"ui_click", &"cast", &"cast_fire", &"cast_fireball", &"cast_physical", &"cast_poison", &"hit",
		&"heal", &"step", &"death", &"turn_start", &"your_turn", &"turn_warning", &"victory", &"defeat"]
## Looping tracks, by the screens that play them.
const MUSIC_TRACKS: Array[StringName] = [&"hub", &"battle", &"boss"]

@export var sfx: Dictionary[StringName, AudioStream] = {}
@export var music: Dictionary[StringName, AudioStream] = {}
## How loud the music plays, in dB: below 0 so spell and hit sounds stand out over it.
@export_range(-30.0, 0.0) var music_gain_db := -6.0
## Per event gain in dB, to balance the files against each other (0 when absent).
@export var sfx_gain_db: Dictionary[StringName, float] = {}
## Per event random pitch change, 0.1 = up to 10 % either way (so a repeated sound, footsteps
## say, doesn't grate). 0 when absent.
@export var sfx_pitch_variation: Dictionary[StringName, float] = {}
## Per event minimum seconds between two plays of it (a crowd of identical sounds is noise).
@export var sfx_cooldown: Dictionary[StringName, float] = {}


func get_validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	for event: StringName in sfx:
		if event not in SFX_EVENTS:
			errors.append("audio set: unknown sound event %s" % event)
		elif sfx[event] == null:
			errors.append("audio set: empty stream for %s" % event)
	for track: StringName in music:
		if track not in MUSIC_TRACKS:
			errors.append("audio set: unknown music track %s" % track)
		elif music[track] == null:
			errors.append("audio set: empty stream for %s" % track)
	return errors

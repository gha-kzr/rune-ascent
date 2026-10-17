@tool
class_name PvpRoster
extends Resource
## The classes of a PvP match, in the order the lobby lists them (a seat keeps its position in this list).

@export var heroes: Array[PvpHero] = []
## What a fallen hero's spirit casts (when the lobby's Spirits rule is on): one of them a turn.
@export var spirit_spells: Array[SpellData] = []


func get_validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if heroes.is_empty():
		errors.append("PvP roster is empty")
	var names: Array[String] = []
	for hero in heroes:
		if hero == null:
			errors.append("PvP roster has an empty slot")
			continue
		for error in hero.get_validation_errors():
			errors.append(error)
		if hero.display_name() in names:
			errors.append("two PvP classes are named %s" % hero.display_name())
		names.append(hero.display_name())
	for spell in spirit_spells:
		if spell == null:
			errors.append("PvP roster has an empty spirit spell")
			continue
		for error in spell.get_validation_errors():
			errors.append("spirit spell %s: %s" % [spell.display_name, error])
		if spell.ap_cost != 1:
			errors.append("spirit spell %s must cost 1 AP (a spirit has one action)" % spell.display_name)
	return errors

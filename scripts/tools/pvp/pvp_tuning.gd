class_name PvpTuning
extends RefCounted
## Whole-roster multipliers for balance experiments (`tools/pvp_balance.gd`: hp=, dmg=, heal=, dot=, lifesteal=, ap=):
## applied to the PvP classes as loaded in memory, never saved, so an experiment is one command and leaves the data
## alone. `dmg` scales every damage, status ticks included; `dot` scales the ticks on top of it (dmg=1.3 dot=0: no
## damage over time); `heal` scales heals (status ticks included); `lifesteal` the share a damage heals back.

var hp := 1.0
var dmg := 1.0
var heal := 1.0
var dot := 1.0
var lifesteal := 1.0
var ap := 0
## The spirits' spells to keep, by name (spirit=curse,reveal); empty: all of them.
var spirit_spells: Array[String] = []


## Reads the options it knows from `name=value` pairs; the others are left to the caller.
static func from_options(options: Dictionary) -> PvpTuning:
	var tuning := PvpTuning.new()
	for field: String in ["hp", "dmg", "heal", "dot", "lifesteal"]:
		if options.has(field):
			tuning.set(field, maxf(0.0, float(options[field])))
	if options.has("ap"):
		tuning.ap = int(options["ap"])
	for word in str(options.get("spirit", "")).split(",", false):
		tuning.spirit_spells.append(word.strip_edges().to_lower())
	return tuning


func is_neutral() -> bool:
	return hp == 1.0 and dmg == 1.0 and heal == 1.0 and dot == 1.0 and lifesteal == 1.0 and ap == 0 and spirit_spells.is_empty()


## "hp ×0.8, dmg ×1.3" (only what differs from the game's numbers).
func describe() -> String:
	var parts: Array[String] = []
	for field: String in ["hp", "dmg", "heal", "dot", "lifesteal"]:
		if float(get(field)) != 1.0:
			parts.append("%s ×%s" % [field, str(get(field))])
	if ap != 0:
		parts.append("ap %+d" % ap)
	if not spirit_spells.is_empty():
		parts.append("spirits: %s" % ", ".join(spirit_spells))
	return ", ".join(parts) if not parts.is_empty() else "the game's numbers"


## Scales every PvP class, in memory (the loaded resources the matches use). Call once per process.
func apply() -> void:
	if is_neutral():
		return
	if not spirit_spells.is_empty():
		var kept: Array[SpellData] = []
		for spell in PvpHeroes.spirit_kit():
			if spell.display_name.to_lower() in spirit_spells:
				kept.append(spell)
		PvpHeroes.roster().spirit_spells = kept
	var seen: Dictionary[Object, bool] = {}
	for index in PvpHeroes.hero_count():
		var unit := PvpHeroes.hero(index).unit
		unit.max_hp = maxi(1, roundi(unit.max_hp * hp))
		unit.ap = maxi(1, unit.ap + ap)
		for spell in unit.spells:
			for effect in spell.effects:
				_scale(effect, false, seen)


func _scale(effect: EffectData, tick: bool, seen: Dictionary[Object, bool]) -> void:
	if effect == null or seen.has(effect):
		return
	seen[effect] = true
	if effect is DamageEffect:
		var damage := effect as DamageEffect
		var factor := dmg * (dot if tick else 1.0)
		damage.min_amount = roundi(damage.min_amount * factor)
		damage.max_amount = roundi(damage.max_amount * factor)
		damage.lifesteal_percent = roundi(damage.lifesteal_percent * lifesteal)
	elif effect is HealEffect:
		var healing := effect as HealEffect
		healing.min_amount = roundi(healing.min_amount * heal)
		healing.max_amount = roundi(healing.max_amount * heal)
	elif effect is ApplyStatusEffect and (effect as ApplyStatusEffect).status != null:
		for ticked in (effect as ApplyStatusEffect).status.tick_effects:
			_scale(ticked, true, seen)

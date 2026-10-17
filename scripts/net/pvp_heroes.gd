class_name PvpHeroes
extends RefCounted
## The classes of a PvP match (data/pvp/roster.tres): fixed units with no levels, no runes and no Power.
## What the lobby shows of a class, and what a match builds from it.

const ROSTER := "res://data/pvp/roster.tres"


static var _roster: PvpRoster


## Kept in a static: a plain load() frees the roster (and every class under it) as soon as the caller lets go of it,
## so every call read it again from disk (about 120 ms each, seconds for a screen of hero cards).
static func roster() -> PvpRoster:
	if _roster == null:
		_roster = load(ROSTER) as PvpRoster
	return _roster


static func hero_count() -> int:
	return roster().heroes.size()


static func hero(hero_index: int) -> PvpHero:
	var all := roster().heroes
	return all[clampi(hero_index, 0, all.size() - 1)]


## The class's name for the lobby.
static func hero_name(hero_index: int) -> String:
	return TranslationServer.translate(hero(hero_index).display_name())


## The class's unit and its permanent modifiers (none: classes are what they are).
static func build(hero_index: int) -> Dictionary:
	return {"unit": hero(hero_index).unit, "modifiers": []}


## What the lobby shows of a class: name, role, short description, stats and its spells.
static func summary(hero_index: int) -> Dictionary:
	var entry := hero(hero_index)
	var unit := entry.unit
	var state := UnitState.new(0, unit, UnitState.Team.PLAYER, Vector2i.ZERO)
	var icons: Array[Texture2D] = []
	var names: Array[String] = []
	for spell in unit.spells:
		icons.append(spell.display_icon())
		names.append(TranslationServer.translate(spell.display_name))
	return {"name": hero_name(hero_index), "role": TranslationServer.translate(entry.role_label),
			"description": TranslationServer.translate(entry.description), "gender": entry.gender,
			"hp": state.max_hp(), "ap": state.max_ap(), "mp": state.max_mp(),
			"spell_icons": icons, "spell_names": names}


## Everything the info popup shows: the summary, plus each spell in full.
static func details(hero_index: int) -> Dictionary:
	var info := summary(hero_index)
	var spells: Array[Dictionary] = []
	for spell in hero(hero_index).unit.spells:
		spells.append({"name": TranslationServer.translate(spell.display_name), "icon": spell.display_icon(), "ap": spell.ap_cost,
				"lines": SpellBar.detail_lines(spell)})
	info["spells"] = spells
	return info


static var _signature := 0


## A number that is the same for two games holding the same classes (stats, spells and what they do), whatever the
## language: the host's start entry carries it, so players on different versions find out at once.
static func signature() -> int:
	if _signature == 0:
		var parts: Array[String] = []
		for entry in roster().heroes:
			var unit := entry.unit
			var line := "%s|%d|%d|%d|%d" % [unit.display_name, unit.max_hp, unit.ap, unit.mp, unit.initiative]
			for modifier in unit.innate_modifiers:
				line += "|%s" % _modifier_text(modifier)
			for spell in unit.spells:
				line += _spell_text(spell)
			parts.append(line)
		var spirit := "spirit"
		for spell in roster().spirit_spells:
			spirit += _spell_text(spell)
		parts.append(spirit)
		parts.append("cards|%d|%d|%s" % [CardRules.HAND_SIZE, CardRules.PLAYS_PER_TURN, CardRules.COPIES_PER_SPELL])
		_signature = maxi(1, "\n".join(parts).hash())
	return _signature


## What a spirit casts when the lobby's Spirits rule is on.
static func spirit_kit() -> Array[SpellData]:
	return roster().spirit_spells


static func _spell_text(spell: SpellData) -> String:
	var text := "|%s,%d,%d,%d-%d,%s,%s,%d,%d" % [spell.display_name, spell.ap_cost, spell.cooldown, spell.min_range,
			spell.max_range, spell.needs_line_of_sight, spell.height_extends_range, spell.target_unit,
			spell.area.kind * 10 + spell.area.size]
	for effect in spell.effects:
		text += ",{%s}" % _effect_text(effect)
	return text


static func _modifier_text(modifier: StatModifier) -> String:
	return "%d:%d:%s" % [modifier.stat, modifier.amount, modifier.damage_type.display_name if modifier.damage_type != null else ""]


static func _effect_text(effect: EffectData) -> String:
	var text := "%s:%d" % [effect.get_script().get_global_name(), effect.target_filter]
	if effect is DamageEffect:
		var damage := effect as DamageEffect
		text += ":%d-%d:%s:%d:%d" % [damage.min_amount, damage.max_amount, damage.damage_type.display_name if damage.damage_type != null else "", damage.lifesteal_percent, damage.ambush_bonus_percent]
	elif effect is HealEffect:
		text += ":%d-%d" % [(effect as HealEffect).min_amount, (effect as HealEffect).max_amount]
	elif effect is MoveEffect:
		text += ":%d:%d" % [(effect as MoveEffect).kind, (effect as MoveEffect).distance]
	elif effect is CleanseEffect:
		text += ":%d" % (effect as CleanseEffect).remove
	elif effect is ApplyStatusEffect:
		var status := (effect as ApplyStatusEffect).status
		text += ":%s:%d:%s:%s:%s" % [status.display_name, status.duration, status.stealth, status.is_positive,
				(effect as ApplyStatusEffect).exclusive]
		for modifier in status.modifiers:
			text += ":" + _modifier_text(modifier)
		for tick in status.tick_effects:
			text += ":(%s)" % _effect_text(tick)
	return text

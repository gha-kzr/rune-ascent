@tool
class_name BattleActions
extends RefCounted
## Player and AI commands (command pattern). An action names its actor by id and holds
## only its intent; validate() and apply() resolve everything against the state they're
## given, so the same action can be tried on an AI clone and then on the real battle.
## Apply only through Battle.perform(), which validates first and handles turn flow.


@abstract class Action extends RefCounted:
	var actor_id: int

	## Empty string if the action is legal in `state`, otherwise the reason it isn't.
	func validate(state: BattleState) -> String:
		if state.is_over():
			return "the battle is over"
		if not state.started:
			return "the battle hasn't started"
		if actor_id < 0 or actor_id >= state.units.size():
			return "unknown unit %d" % actor_id
		if not state.units[actor_id].can_act():
			return "unit %d is dead" % actor_id
		if state.turn_order.current_unit_id() != actor_id:
			return "it is not unit %d's turn" % actor_id
		return _validate(state)

	@abstract func _validate(state: BattleState) -> String

	## Mutates `state` and returns what happened. Assumes validate() passed.
	@abstract func apply(state: BattleState) -> Array[BattleEvents.Event]


class Move extends Action:
	## What walking into a hidden enemy costs the walker, in percent of its max HP.
	const BUMP_DAMAGE_PERCENT := 10

	var destination: Vector2i

	func _init(actor: int, cell: Vector2i) -> void:
		actor_id = actor
		destination = cell

	func _validate(state: BattleState) -> String:
		if state.units[actor_id].spirit:
			return "a spirit doesn't walk"
		# As the player sees the board: a hidden enemy doesn't stop the move from being asked for (it is found by walking into it).
		if not Movement.reach(state, actor_id, true).can_reach(destination):
			return "can't reach %s" % destination
		return ""

	## Repositioning (see UnitState): the cost counts from where the move segment started,
	## so moving again re-spends from the segment's MP; the drawn path is the walk from
	## where the unit stands (a straight slide when no walk leads there).
	##
	## Bumping: the walk is the cheapest one *as the player sees the board* (see Movement.reach), so it may cross the cell
	## of an enemy hidden by stealth. Then the unit stops on the cell before it (or doesn't move, if it is the first step),
	## pays only for the steps it took, takes BUMP_DAMAGE_PERCENT of its max HP in damage, and the hidden unit is found: its
	## stealth ends. Walking into a hidden unit is how it is found, so its place is never given away for free.
	func apply(state: BattleState) -> Array[BattleEvents.Event]:
		var unit := state.units[actor_id]
		var reach := Movement.reach(state, actor_id, true)
		var route := reach.path_to(destination)
		var bumped: UnitState = null
		var stop := route.size()
		for index in route.size():
			var other := state.unit_at(route[index])
			if other != null and other.id != actor_id and other.team != unit.team:
				bumped = other
				stop = index
				break
		if bumped == null:
			return _walk(state, unit, reach, destination, route if not unit.moved else Movement.walk_path(state, actor_id, destination))
		while stop > 0 and state.unit_at(route[stop - 1]) != null:
			stop -= 1  # A unit can't stop on an ally's cell: it halts before the allies it was walking through.
		var halt := route[stop - 1] if stop > 0 else reach.origin
		var events: Array[BattleEvents.Event] = []
		if halt != unit.cell:
			events.append_array(_walk(state, unit, reach, halt, reach.path_to(halt) if not unit.moved else Movement.walk_path(state, actor_id, halt)))
		events.append_array(_bump(state, unit, bumped))
		return events

	## Moves the unit to `to` (its MP counted from the segment's origin) along `path`.
	func _walk(state: BattleState, unit: UnitState, reach: Movement.Reach, to: Vector2i, path: Array[Vector2i]) -> Array[BattleEvents.Event]:
		if path.is_empty():
			path = [to]
		var mp_before := unit.mp
		if not unit.moved:
			unit.moved = true
			unit.moved_from = unit.cell
		unit.moved_cost = reach.walk_cost(to)
		unit.mp = reach.origin_budget - unit.moved_cost
		unit.cell = to
		return [BattleEvents.UnitMoved.new(actor_id, path, mp_before - unit.mp)]

	func _bump(state: BattleState, unit: UnitState, hidden: UnitState) -> Array[BattleEvents.Event]:
		var amount := mini(maxi(1, roundi(unit.max_hp() * BUMP_DAMAGE_PERCENT / 100.0)), unit.hp)
		unit.hp -= amount
		var events: Array[BattleEvents.Event] = [BattleEvents.DamageDealt.new(unit.id, amount, unit.hp)]
		for ended in unit.break_stealth():  # Hurt: no longer hidden.
			events.append(BattleEvents.StatusExpired.new(unit.id, ended))
		for ended in hidden.break_stealth():  # Found.
			events.append(BattleEvents.StatusExpired.new(hidden.id, ended))
		return events


class CastSpell extends Action:
	var spell_index: int
	var target: Vector2i

	func _init(actor: int, spell_slot: int, target_cell: Vector2i) -> void:
		actor_id = actor
		spell_index = spell_slot
		target = target_cell

	## Whether the unit has that spell, enough AP for it and either a card of it (card mode) or no cooldown on it
	## (range aside). Shared with the UI.
	static func can_afford(unit: UnitState, slot: int) -> bool:
		return unit.can_cast(slot)

	func _validate(state: BattleState) -> String:
		var unit := state.units[actor_id]
		if spell_index < 0 or spell_index >= unit.data.spells.size():
			return "unit %d has no spell %d" % [actor_id, spell_index]
		var spell := unit.data.spells[spell_index]
		if unit.ap < unit.cast_cost(spell):
			return "%s needs %d AP, unit has %d" % [spell.display_name, unit.cast_cost(spell), unit.ap]
		if unit.card_mode and not unit.has_card(spell_index):
			return "%s is not in the hand" % spell.display_name
		if not unit.card_mode and unit.cooldown_left(spell) > 0:
			return "%s is on cooldown for %d turns" % [spell.display_name, unit.cooldown_left(spell)]
		if not Targeting.can_target(state, actor_id, spell, target):
			return "%s can't target %s" % [spell.display_name, target]
		return ""

	func apply(state: BattleState) -> Array[BattleEvents.Event]:
		var caster := state.units[actor_id]
		var spell := caster.data.spells[spell_index]
		var cost := caster.cast_cost(spell)
		caster.ap -= cost
		if caster.card_mode:
			caster.spend_card(spell_index)  # Cards replace cooldowns: the rarer spell simply comes up less often.
		elif spell.cooldown > 0:
			caster.cooldowns[spell] = spell.cooldown
		var area := Targeting.area_cells(state.grid, spell.area, caster.cell, target)
		var events: Array[BattleEvents.Event] = [BattleEvents.SpellCast.new(actor_id, spell, target, area, cost)]
		# Targets are fixed before any effect lands, in area order.
		var in_area: Array[int] = []
		for cell in area:
			var unit := state.unit_at(cell)
			if unit != null:
				in_area.append(unit.id)
		# Effect by effect: every hit lands, then every status, and so on.
		for effect in spell.effects:
			for target_id in _targets_of(spell, effect, state, in_area):
				if state.units[target_id].is_alive():  # Killed by an earlier effect: skipped.
					events.append_array(effect.apply_cast(state, actor_id, target_id, target))
		if spell.is_offensive():
			for ended in caster.break_stealth():  # An attack gives the caster away.
				events.append(BattleEvents.StatusExpired.new(actor_id, ended))
		caster.commit_position()  # A cast ends free repositioning: the next move counts from here.
		return events

	## The units an effect applies to, by its target filter. Without friendly fire a harmful effect spares the
	## caster's team (the caster included, unless the effect is aimed at the caster alone), except for a spell that
	## is aimed at an ally on purpose (the Ghoul's Feast).
	func _targets_of(spell: SpellData, effect: EffectData, state: BattleState, in_area: Array[int]) -> Array[int]:
		var caster_team := state.units[actor_id].team
		var spares_team := effect.is_harmful() and not state.friendly_fire and spell.target_unit != SpellData.TargetUnit.ALLY
		match effect.target_filter:
			EffectData.TargetFilter.CASTER:
				return [actor_id]
			EffectData.TargetFilter.ALLIES:
				if spares_team:
					return []
				return in_area.filter(func(id: int) -> bool: return state.units[id].team == caster_team)
			EffectData.TargetFilter.ENEMIES:
				return in_area.filter(func(id: int) -> bool: return state.units[id].team != caster_team)
		if spares_team:
			return in_area.filter(func(id: int) -> bool: return state.units[id].team != caster_team)
		return in_area


## Card mode: throws a card from the hand away (it goes to the discard pile). Free, so a turn can end with a cleaner hand.
class DiscardCard extends Action:
	var spell_index: int

	func _init(actor: int, spell_slot: int) -> void:
		actor_id = actor
		spell_index = spell_slot

	func _validate(state: BattleState) -> String:
		var unit := state.units[actor_id]
		if not unit.card_mode:
			return "there are no cards in this battle"
		if not unit.has_card(spell_index):
			return "unit %d holds no card %d" % [actor_id, spell_index]
		return ""

	func apply(state: BattleState) -> Array[BattleEvents.Event]:
		var unit := state.units[actor_id]
		unit.spend_card(spell_index)
		return [BattleEvents.CardDiscarded.new(actor_id, unit.data.spells[spell_index])]


## Before the battle starts: moves a hero to a cell of its start zone, swapping with a hero of its
## team standing there, if any. In a PvP battle the ENEMY team places in its own zone too.
class Place extends Action:
	var cell: Vector2i

	func _init(actor: int, zone_cell: Vector2i) -> void:
		actor_id = actor
		cell = zone_cell

	func validate(state: BattleState) -> String:
		if state.started:
			return "the battle has started"
		if actor_id < 0 or actor_id >= state.units.size():
			return "unknown unit %d" % actor_id
		if state.units[actor_id].team != UnitState.Team.PLAYER and not state.pvp:
			return "only heroes are placed"
		if not state.units[actor_id].is_alive():
			return "unit %d is dead" % actor_id
		return _validate(state)

	func _validate(state: BattleState) -> String:
		var zone := state.zone if state.units[actor_id].team == UnitState.Team.PLAYER else state.zone_enemy
		if cell not in zone:
			return "%s isn't in the start zone" % cell
		return ""

	func apply(state: BattleState) -> Array[BattleEvents.Event]:
		var unit := state.units[actor_id]
		if unit.cell == cell:
			return []
		var events: Array[BattleEvents.Event] = []
		var other := state.unit_at(cell)
		if other != null and other.team == unit.team:
			other.cell = unit.cell
			events.append(BattleEvents.UnitPlaced.new(other.id, other.cell))
		unit.cell = cell
		events.push_front(BattleEvents.UnitPlaced.new(actor_id, cell))
		return events


class EndTurn extends Action:
	func _init(actor: int) -> void:
		actor_id = actor

	func _validate(_state: BattleState) -> String:
		return ""

	func apply(_state: BattleState) -> Array[BattleEvents.Event]:
		return []  # Battle.perform() handles the turn change.

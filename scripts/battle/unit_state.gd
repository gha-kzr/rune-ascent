@tool
class_name UnitState
extends RefCounted
## Per-battle values of one unit. The UnitData template is shared and never mutated.
## Innate modifiers (UnitData), statuses (expiring) and permanent sources (levels, runes)
## change numbers through modifiers that are added up when asked (max_hp(), power(),
## resistance_percent(), …); nothing derived is stored, so expiry has nothing to undo.

## Resistance never goes past these: a hero is never immune, an enemy at 100 % is.
const MAX_HERO_RESISTANCE_PERCENT := 75
const MAX_ENEMY_RESISTANCE_PERCENT := 100

enum Team { PLAYER, ENEMY }

var id: int
var data: UnitData
var team: Team
var cell: Vector2i
var hp: int
var ap: int
var mp: int
## In application order, which is also tick order.
var statuses: Array[StatusInstance] = []
## For the whole battle: a hero's level rewards and runes, an enemy's level and preset.
## Shared resources, read-only.
var permanent_modifiers: Array[StatModifier] = []
## What killing it gives (enemies from an encounter); null for heroes.
var reward: UnitReward
## Overrides the encounter's AI profile (e.g. a boss preset); null: the encounter's.
var ai_profile: AIProfile
## Repositioning: since its last cast (or its turn start) the unit has moved from
## `moved_from`, spending `moved_cost` MP. Until it casts, it may move anywhere that cell
## could reach with that MP back (moving back refunds it); a cast commits the position.
var moved := false
var moved_from: Vector2i
var moved_cost := 0
## Spells waiting to be cast again: spell → turns left (counted down at turn start).
var cooldowns: Dictionary[SpellData, int] = {}
## Card mode (see CardRules): the spells are a deck of slot numbers. A play costs one AP, whatever the spell.
var card_mode := false
var hand: Array[int] = []
var draw_pile: Array[int] = []
var discard_pile: Array[int] = []
## Shuffles and draws: its own dice, so a hand never depends on the damage rolls.
var card_rng := RandomNumberGenerator.new()
## What it does in its team (enemies; NONE for heroes).
var role := EnemyData.Role.NONE
## Where the AI likes this unit to stand (null: straight at its opponents). Shared, read-only.
var positioning: Positioning
## Name shown in the HUD, e.g. "Brute Lv 5 · Elite".
var label := ""
var visual_scale := 1.0
## Multiplayer spirits (BattleState.spirit_kit): the unit fell and acts on as a spirit, on its own turn, with one action
## and the spirit's spells in place of its own (`data` is then a copy of its UnitData holding them).
var spirit := false

## A spirit's actions a turn.
const SPIRIT_ACTIONS := 1


func _init(unit_id: int, unit_data: UnitData, unit_team: Team, start_cell: Vector2i) -> void:
	id = unit_id
	data = unit_data
	team = unit_team
	cell = start_cell
	label = unit_data.display_name
	hp = max_hp()  # Innate modifiers count from the start.
	ap = max_ap()
	mp = max_mp()


func is_alive() -> bool:
	return hp > 0


## Whether it takes turns: alive, or a spirit.
func can_act() -> bool:
	return is_alive() or spirit


## The unit has fallen and goes on as a spirit: its spells become `kit`, one action a turn, no move, no status left.
## In card combat its hand is the whole kit, every turn (start_turn).
func become_spirit(kit: Array[SpellData]) -> void:
	spirit = true
	var spirit_data := data.duplicate() as UnitData
	spirit_data.spells = kit.duplicate()
	spirit_data.mp = 0
	data = spirit_data
	statuses.clear()
	cooldowns.clear()
	commit_position()
	ap = 0
	mp = 0
	if card_mode:
		hand.assign(range(kit.size()))
		draw_pile.clear()
		discard_pile.clear()


## Refills AP and MP, modifiers included. Called when the unit's turn starts.
func start_turn() -> void:
	ap = max_ap()
	mp = max_mp()
	commit_position()
	if spirit and card_mode:
		hand.assign(range(data.spells.size()))  # The whole kit again: what it didn't play last turn was thrown away.
	for spell: SpellData in cooldowns.keys():
		cooldowns[spell] -= 1
		if cooldowns[spell] <= 0:
			cooldowns.erase(spell)


## Switches to card mode: the spells become a shuffled deck and the first hand is drawn. `seed` makes the
## shuffles the same on every peer.
func enable_cards(seed: int) -> void:
	card_mode = true
	card_rng.seed = seed
	hand.clear()
	discard_pile.clear()
	draw_pile = CardRules.deck_for(data)
	_shuffle(draw_pile)
	ap = max_ap()
	draw_hand()


## Draws until the hand is full or there is nothing left to draw (the discard pile is shuffled back in when the
## draw pile runs out).
func draw_hand() -> void:
	while hand.size() < CardRules.HAND_SIZE:
		if draw_pile.is_empty():
			if discard_pile.is_empty():
				return
			draw_pile = discard_pile
			discard_pile = []
			_shuffle(draw_pile)
		hand.append(draw_pile.pop_back())


## Fisher-Yates with the unit's own dice (Array.shuffle() uses the global generator: not the same on every peer).
func _shuffle(cards: Array[int]) -> void:
	for index in range(cards.size() - 1, 0, -1):
		var other := card_rng.randi_range(0, index)
		var kept := cards[index]
		cards[index] = cards[other]
		cards[other] = kept


## Whether the hand holds a card of that spell.
func has_card(slot: int) -> bool:
	return hand.has(slot)


## The card leaves the hand for the discard pile (played or thrown away).
func spend_card(slot: int) -> void:
	hand.erase(slot)  # erase() removes only the first copy.
	discard_pile.append(slot)


## What casting `spell` costs in AP: a play in card mode, the spell's own cost otherwise.
func cast_cost(spell: SpellData) -> int:
	return 1 if card_mode else spell.ap_cost


## Whether the unit can cast that spell now (range aside): the AP, and either a card in hand or no cooldown.
func can_cast(slot: int) -> bool:
	if slot < 0 or slot >= data.spells.size():
		return false
	var spell := data.spells[slot]
	if ap < cast_cost(spell):
		return false
	return has_card(slot) if card_mode else cooldown_left(spell) == 0


## Turns before `spell` can be cast again (0: now).
func cooldown_left(spell: SpellData) -> int:
	return cooldowns.get(spell, 0)


## Where the current move segment started: the cell the unit's reach floods from.
func move_start() -> Vector2i:
	return moved_from if moved else cell


## The MP of the current move segment: what is left plus what repositioning would refund.
func move_budget() -> int:
	return mp + (moved_cost if moved else 0)


## Ends the move segment (a cast, a turn start): the next move counts from here.
func commit_position() -> void:
	moved = false
	moved_cost = 0


## Sum of the permanent and status modifiers for one stat (and damage type, for
## per-type stats).
func stat_bonus(stat: StatModifier.Stat, damage_type: DamageType = null) -> int:
	var total := 0
	for modifier in data.innate_modifiers:
		if modifier.applies_to(stat, damage_type):
			total += modifier.amount
	for modifier in permanent_modifiers:
		if modifier.applies_to(stat, damage_type):
			total += modifier.amount
	for status in statuses:
		for modifier in status.data.modifiers:
			if modifier.applies_to(stat, damage_type):
				total += modifier.amount
	return total


func max_hp() -> int:
	return maxi(1, data.max_hp + stat_bonus(StatModifier.Stat.MAX_HP))


func initiative() -> int:
	return data.initiative + stat_bonus(StatModifier.Stat.INITIATIVE)


## Percent added to the damage and heals the unit deals (0 = normal).
func power() -> int:
	return stat_bonus(StatModifier.Stat.POWER)


## Percent less damage of that type taken, at most max_resistance_percent() (may be
## negative: a weakness). Untyped damage (null) is never resisted.
func resistance_percent(damage_type: DamageType) -> int:
	if damage_type == null:
		return 0
	return mini(max_resistance_percent(), stat_bonus(StatModifier.Stat.RESISTANCE_PERCENT, damage_type))


func max_resistance_percent() -> int:
	return MAX_HERO_RESISTANCE_PERCENT if team == Team.PLAYER else MAX_ENEMY_RESISTANCE_PERCENT


func max_ap() -> int:
	if spirit:
		return SPIRIT_ACTIONS
	return maxi(0, (CardRules.PLAYS_PER_TURN if card_mode else data.ap) + stat_bonus(StatModifier.Stat.AP))


func max_mp() -> int:
	return maxi(0, data.mp + stat_bonus(StatModifier.Stat.MP))


## Percent of incoming damage the unit takes (100 = normal), never below 0.
func damage_taken_percent() -> int:
	return maxi(0, 100 + stat_bonus(StatModifier.Stat.DAMAGE_TAKEN_PERCENT))


## Damage types the unit has any resistance modifier for (permanent or status).
func resistance_types() -> Array[DamageType]:
	var types: Array[DamageType] = []
	var modifiers: Array[StatModifier] = data.innate_modifiers.duplicate()
	modifiers.append_array(permanent_modifiers)
	for status in statuses:
		modifiers.append_array(status.data.modifiers)
	for modifier in modifiers:
		if modifier.damage_type != null and modifier.damage_type not in types:
			types.append(modifier.damage_type)
	return types


func find_status(status: StatusData) -> StatusInstance:
	for instance in statuses:
		if instance.data == status:
			return instance
	return null


## Puts a status on the unit for its full duration. If the unit already has it, the new
## one replaces it (keeping its place in tick order). Current AP and MP shift at once by
## the change in their maxima, so a replaced status only shifts by the difference.
func add_status(status: StatusData, caster_id: int) -> StatusInstance:
	var ap_before := max_ap()
	var mp_before := max_mp()
	var instance := StatusInstance.new(status, caster_id, status.duration)
	var previous := find_status(status)
	if previous != null:
		statuses[statuses.find(previous)] = instance
	else:
		statuses.append(instance)
	ap = maxi(0, ap + max_ap() - ap_before)
	mp = maxi(0, mp + max_mp() - mp_before)
	return instance


## Whether the unit carries a stealth status.
func is_stealthed() -> bool:
	for status in statuses:
		if status.data.stealth:
			return true
	return false


## Ends every stealth status (the unit attacked or was hurt). Returns the ones that ended.
func break_stealth() -> Array[StatusData]:
	var ended: Array[StatusData] = []
	for status in statuses.duplicate():
		if status.data.stealth:
			statuses.erase(status)
			ended.append(status.data)
	return ended


func clone() -> UnitState:
	var copy := UnitState.new(id, data, team, cell)
	copy.hp = hp
	copy.ap = ap
	copy.mp = mp
	copy.moved = moved
	copy.moved_from = moved_from
	copy.moved_cost = moved_cost
	copy.cooldowns = cooldowns.duplicate()
	copy.card_mode = card_mode
	copy.hand = hand.duplicate()
	copy.draw_pile = draw_pile.duplicate()
	copy.discard_pile = discard_pile.duplicate()
	copy.card_rng.seed = card_rng.seed
	copy.card_rng.state = card_rng.state
	for status in statuses:
		copy.statuses.append(status.clone())
	copy.permanent_modifiers = permanent_modifiers.duplicate()
	copy.reward = reward
	copy.ai_profile = ai_profile
	copy.label = label
	copy.role = role
	copy.positioning = positioning
	copy.visual_scale = visual_scale
	copy.spirit = spirit
	return copy

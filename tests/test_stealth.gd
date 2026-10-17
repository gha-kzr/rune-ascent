extends TestCase
## Stealth (the Rogue's Vanish): a hidden unit can't be picked as a target by the other team, the AI doesn't aim at
## it, it shows again when someone walks into it, attacks, or is hurt (standing next to it shows nothing), and its first
## strike hits harder.
## Also the cleanse effect.

const STEALTH := "res://data/pvp/statuses/stealth.tres"


## A rogue (unit 0, side A) and a knight (unit 1, side B) on an open map, far apart; the rogue is hidden.
func _duel(hidden := true) -> BattleState:
	var map := PvpMap.generate(7, load("res://data/maps/typologies/open_field.tres") as MapTypology, 12)
	var side_a: Array[Dictionary] = [{"hero": 4, "name": "Rogue"}]
	var side_b: Array[Dictionary] = [{"hero": 0, "name": "Knight"}]
	var state := PvpBattle.create(map, side_a, side_b, 5)
	state.units[0].cell = Vector2i(2, 2)
	state.units[1].cell = Vector2i(8, 8)
	if hidden:
		state.units[0].add_status(load(STEALTH) as StatusData, 0)
	return state


func _knight_spell(name_text: String) -> int:
	var unit := PvpHeroes.build(0)["unit"] as UnitData
	for index in unit.spells.size():
		if unit.spells[index].display_name == name_text:
			return index
	return -1


func test_a_hidden_unit_is_hidden_from_the_other_team_only_even_when_someone_is_next_to_it() -> void:
	var state := _duel()
	assert_true(state.is_hidden_from(state.units[0], UnitState.Team.ENEMY))
	assert_false(state.is_hidden_from(state.units[0], UnitState.Team.PLAYER), "its own team sees it")
	state.units[1].cell = Vector2i(2, 3)
	assert_true(state.is_hidden_from(state.units[0], UnitState.Team.ENEMY), "an enemy standing next to it still doesn't see it")
	state.units[1].cell = Vector2i(2, 4)
	assert_true(state.is_hidden_from(state.units[0], UnitState.Team.ENEMY), "nor two cells away")


func _priestess_spell(name_text: String) -> int:
	var unit := PvpHeroes.build(5)["unit"] as UnitData
	for index in unit.spells.size():
		if unit.spells[index].display_name == name_text:
			return index
	return -1


func _knight_at(state: BattleState, knight_cell: Vector2i, rogue_cell: Vector2i) -> void:
	state.units[1].cell = knight_cell
	state.units[0].cell = rogue_cell


## Plays the knight's turn up to where it can move (the rogue is unit 0, the knight unit 1).
func _knights_turn(state: BattleState) -> Battle:
	var battle := Battle.new(state)
	battle.start()
	while state.current_unit().id != 1:
		battle.perform(BattleActions.EndTurn.new(state.current_unit().id))
	return battle


func test_the_cells_a_player_may_walk_to_do_not_give_a_hidden_enemy_away() -> void:
	var state := _duel()
	_knight_at(state, Vector2i(5, 5), Vector2i(5, 7))  # Two cells from the knight, hidden.
	assert_false(Vector2i(5, 7) in Movement.reach(state, 1).cells(), "really, nobody can stop on an occupied cell")
	var seen := Movement.reach(state, 1, true).cells()
	assert_true(Vector2i(5, 7) in seen, "but the drawing has no hole where the hidden enemy stands")
	assert_true(Vector2i(5, 8) in seen, "nor a shadow behind it")
	state.units[0].break_stealth()
	assert_false(Vector2i(5, 7) in Movement.reach(state, 1, true).cells(), "a revealed enemy blocks its cell as any other")
	assert_eq(Movement.reach(state, 1, true).cells().size(), Movement.reach(state, 1).cells().size(), "the same cells once nothing is hidden")


func test_walking_into_a_hidden_enemy_stops_before_it_hurts_the_walker_and_finds_the_hidden_one() -> void:
	var state := _duel()
	_knight_at(state, Vector2i(5, 5), Vector2i(5, 7))
	var battle := _knights_turn(state)
	var knight := state.units[1]
	var mp_before := knight.mp
	var hp_before := knight.hp
	var result := battle.perform(BattleActions.Move.new(1, Vector2i(5, 8)))  # Straight through the rogue's cell.
	assert_true(result.ok(), "the move can be asked for")
	assert_eq(knight.cell, Vector2i(5, 6), "it stopped on the cell before the rogue")
	assert_eq(mp_before - knight.mp, 1, "and paid for the one step it took")
	var damage := maxi(1, roundi(knight.max_hp() * BattleActions.Move.BUMP_DAMAGE_PERCENT / 100.0))
	assert_eq(hp_before - knight.hp, damage, "the walker is hurt")
	assert_eq(state.units[0].hp, state.units[0].max_hp(), "the hidden one is not")
	assert_false(state.units[0].is_stealthed(), "but it is found")
	assert_false(state.is_hidden_from(state.units[0], UnitState.Team.ENEMY))
	var kinds := result.events.map(func(e: BattleEvents.Event) -> String: return e.get_script().get_global_name() if e.get_script() != null else "?")
	assert_eq(result.events.size(), 3, "moved, hurt, found")
	assert_true(result.events[0] is BattleEvents.UnitMoved and result.events[1] is BattleEvents.DamageDealt and result.events[2] is BattleEvents.StatusExpired, str(kinds))
	assert_eq((result.events[1] as BattleEvents.DamageDealt).unit_id, 1)
	assert_eq((result.events[2] as BattleEvents.StatusExpired).unit_id, 0)


func test_walking_onto_the_hidden_enemys_own_cell_is_a_bump_too() -> void:
	var state := _duel()
	_knight_at(state, Vector2i(5, 5), Vector2i(5, 7))
	var battle := _knights_turn(state)
	var result := battle.perform(BattleActions.Move.new(1, Vector2i(5, 7)))
	assert_true(result.ok())
	assert_eq(state.units[1].cell, Vector2i(5, 6))
	assert_false(state.units[0].is_stealthed())


func test_a_hidden_enemy_on_the_first_step_means_no_move_but_still_a_bump() -> void:
	var state := _duel()
	_knight_at(state, Vector2i(5, 5), Vector2i(5, 6))  # Next to the knight, and the knight can't tell.
	var battle := _knights_turn(state)
	var knight := state.units[1]
	var mp_before := knight.mp
	var result := battle.perform(BattleActions.Move.new(1, Vector2i(5, 8)))
	assert_true(result.ok())
	assert_eq(knight.cell, Vector2i(5, 5), "it didn't move")
	assert_eq(knight.mp, mp_before, "and paid nothing")
	assert_false(knight.moved, "the move didn't count")
	assert_eq(result.events.size(), 2, "hurt, and found")
	assert_false(state.units[0].is_stealthed())


func test_a_walk_that_does_not_cross_the_hidden_enemy_is_a_plain_walk() -> void:
	var state := _duel()
	_knight_at(state, Vector2i(5, 5), Vector2i(5, 7))
	var battle := _knights_turn(state)
	var hp_before := state.units[1].hp
	var result := battle.perform(BattleActions.Move.new(1, Vector2i(3, 5)))
	assert_true(result.ok())
	assert_eq(state.units[1].cell, Vector2i(3, 5))
	assert_eq(state.units[1].hp, hp_before, "no harm")
	assert_true(state.units[0].is_stealthed(), "and nobody found")
	assert_eq(result.events.size(), 1)


func test_a_walker_can_die_of_the_bump() -> void:
	var state := _duel()
	_knight_at(state, Vector2i(5, 5), Vector2i(5, 7))
	var battle := _knights_turn(state)
	state.units[1].hp = 1
	var result := battle.perform(BattleActions.Move.new(1, Vector2i(5, 8)))
	assert_true(result.ok())
	assert_false(state.units[1].is_alive(), "hurt for the last of its HP")
	assert_true(result.events.any(func(e: BattleEvents.Event) -> bool: return e is BattleEvents.UnitDied))


func test_a_hidden_rogue_still_ambushes_from_next_to_an_enemy_that_cannot_see_her() -> void:
	var state := _duel()
	state.use_average_rolls = true
	_knight_at(state, Vector2i(5, 6), Vector2i(5, 5))
	var battle := Battle.new(state)
	battle.start()
	while state.current_unit().id != 0:
		battle.perform(BattleActions.EndTurn.new(state.current_unit().id))
	var hp_before := state.units[1].hp
	var result := battle.perform(BattleActions.CastSpell.new(0, 1, Vector2i(5, 6)))
	assert_true(result.ok(), result.error)
	var plain := (PvpHeroes.build(4)["unit"] as UnitData).spells[1].effects[0] as DamageEffect
	assert_true(hp_before - state.units[1].hp > roundi(plain.average_roll() * 1.5), "the ambush bonus applied")


func test_a_hidden_unit_does_not_block_line_of_sight() -> void:
	var state := _duel()
	_knight_at(state, Vector2i(2, 6), Vector2i(2, 4))  # The rogue between the knight and (2, 2).
	assert_true(Targeting.has_line_of_sight(state, Vector2i(2, 6), Vector2i(2, 2)), "its shadow would give it away")
	state.units[0].statuses.clear()
	assert_false(Targeting.has_line_of_sight(state, Vector2i(2, 6), Vector2i(2, 2)), "once it shows, it blocks like any unit")


func test_a_spell_that_needs_an_enemy_cannot_pick_a_hidden_one() -> void:
	var state := _duel()
	state.units[1].cell = Vector2i(2, 5)
	var picky := SpellData.new()
	picky.display_name = "Picky"
	picky.min_range = 1
	picky.max_range = 6
	picky.needs_line_of_sight = false
	picky.target_unit = SpellData.TargetUnit.ENEMY
	picky.area = AreaShape.new()
	var hit := DamageEffect.new()
	hit.min_amount = 1
	hit.max_amount = 1
	picky.effects.assign([hit])
	assert_false(Targeting.can_target(state, 1, picky, Vector2i(2, 2)), "hidden")
	state.units[0].break_stealth()
	assert_true(Targeting.can_target(state, 1, picky, Vector2i(2, 2)), "visible again")


func test_attacking_or_being_hurt_ends_stealth_but_vanishing_and_moving_do_not() -> void:
	var state := _duel()
	var battle := Battle.new(state)
	var rogue := state.units[0]
	var unit := PvpHeroes.build(4)["unit"] as UnitData
	var vanish := unit.spells[2]
	assert_false(vanish.is_offensive(), "vanishing is not an attack")
	assert_true(unit.spells[1].is_offensive(), "Ambush is")
	# Hurt by something: no longer hidden.
	var poke := DamageEffect.new()
	poke.min_amount = 5
	poke.max_amount = 5
	var events := poke.apply(state, 1, 0)
	assert_false(rogue.is_stealthed())
	assert_true(events.any(func(e: BattleEvents.Event) -> bool: return e is BattleEvents.StatusExpired), "the screen is told")
	# Attacks give the caster away.
	rogue.add_status(load(STEALTH) as StatusData, 0)
	state.units[1].cell = Vector2i(2, 3)
	battle.start()
	var current := state.current_unit()
	if current.id != 0:
		battle.perform(BattleActions.EndTurn.new(current.id))
	var result := battle.perform(BattleActions.CastSpell.new(0, 1, Vector2i(2, 3)))
	assert_true(result.ok(), result.error)
	assert_false(rogue.is_stealthed(), "the ambush revealed her")


func test_the_first_strike_from_stealth_hits_harder() -> void:
	var state := _duel()
	state.use_average_rolls = true
	var ambush := (PvpHeroes.build(4)["unit"] as UnitData).spells[1].effects[0] as DamageEffect
	var hidden_damage := ambush.scaled(state, 0, 1, ambush.average_roll())
	state.units[0].break_stealth()
	var plain_damage := ambush.scaled(state, 0, 1, ambush.average_roll())
	assert_true(hidden_damage > plain_damage * 1.7 and hidden_damage < plain_damage * 1.9, "+80%% (%f vs %f)" % [hidden_damage, plain_damage])


func test_the_ai_does_not_aim_at_a_hidden_unit_and_does_when_it_shows() -> void:
	var state := _duel()
	state.units[1].cell = Vector2i(2, 3)  # Next to it: nothing shows.
	var battle := Battle.new(state)
	battle.start()
	var knight_id := 1
	while state.current_unit().id != knight_id:
		battle.perform(BattleActions.EndTurn.new(state.current_unit().id))
	var action := EnemyAI.choose_next(state, knight_id)
	var attacking := action is BattleActions.CastSpell and state.units[knight_id].data.spells[(action as BattleActions.CastSpell).spell_index].is_offensive()
	assert_false(attacking, "no attack on a target it can't see, even next to it")
	state.units[0].break_stealth()
	assert_true(EnemyAI.choose_next(state, knight_id) is BattleActions.CastSpell, "once she shows, it hits her")


func test_a_cleanse_removes_harmful_statuses_and_keeps_the_helpful_ones() -> void:
	var state := _duel(false)
	var target := state.units[1]
	var harmful := StatusData.new()
	harmful.duration = 2
	var helpful := StatusData.new()
	helpful.duration = 2
	helpful.is_positive = true
	target.add_status(harmful, 0)
	target.add_status(helpful, 0)
	var cleanse := CleanseEffect.new()
	var events := cleanse.apply(state, 0, 1)
	assert_eq(target.statuses.size(), 1)
	assert_true(target.statuses[0].data.is_positive)
	assert_eq(events.size(), 1)
	var dispel := CleanseEffect.new()
	dispel.remove = CleanseEffect.Remove.HELPFUL
	dispel.apply(state, 0, 1)
	assert_eq(target.statuses.size(), 0)


func test_an_area_spell_still_hits_a_hidden_unit_it_covers() -> void:
	var state := _duel()
	state.units[1].cell = Vector2i(2, 6)
	var battle := Battle.new(state)
	battle.start()
	while state.current_unit().id != 1:
		battle.perform(BattleActions.EndTurn.new(state.current_unit().id))
	var whirl := -1
	for index in state.units[1].data.spells.size():
		if state.units[1].data.spells[index].display_name == "Whirlwind":
			whirl = index
	state.units[1].cell = Vector2i(2, 3)  # Next to the rogue: the whirlwind covers her.
	state.units[0].break_stealth()
	state.units[0].add_status(load(STEALTH) as StatusData, 0)
	var hp := state.units[0].hp
	var result := battle.perform(BattleActions.CastSpell.new(1, whirl, Vector2i(2, 3)))
	assert_true(result.ok(), result.error)
	assert_true(state.units[0].hp < hp, "the area hit her (she was next to him)")
	assert_false(state.units[0].is_stealthed(), "and revealed her")


func test_a_charge_cannot_be_aimed_at_a_hidden_unit() -> void:
	var state := _duel()
	state.units[1].cell = Vector2i(2, 8)  # In line with the rogue, hidden at (2, 2): 6 cells away.
	state.units[0].cell = Vector2i(2, 6)
	var charge := (PvpHeroes.build(0)["unit"] as UnitData).spells[_knight_spell("Charge")]
	assert_false(Targeting.can_target(state, 1, charge, Vector2i(2, 6)), "a hidden unit can't be charged")
	state.units[0].break_stealth()
	assert_true(Targeting.can_target(state, 1, charge, Vector2i(2, 6)), "a visible one can")


func test_the_ambush_bonus_applies_on_a_real_cast_and_only_to_enemies() -> void:
	var state := _duel()
	state.units[1].cell = Vector2i(2, 3)
	state.use_average_rolls = true
	var battle := Battle.new(state)
	battle.start()
	while state.current_unit().id != 0:
		battle.perform(BattleActions.EndTurn.new(state.current_unit().id))
	var hp := state.units[1].hp
	var result := battle.perform(BattleActions.CastSpell.new(0, 1, Vector2i(2, 3)))
	assert_true(result.ok(), result.error)
	var lost := hp - state.units[1].hp
	assert_true(lost >= 34 and lost <= 38, "20 x 1.8 = 36 from stealth (%d)" % lost)
	var spell := (PvpHeroes.build(4)["unit"] as UnitData).spells[1]
	assert_eq((spell.effects[0] as DamageEffect).target_filter, EffectData.TargetFilter.ENEMIES, "never her own team")


func test_no_class_resists_any_damage_in_multiplayer() -> void:
	var state := _duel(false)
	var wraith := PvpHeroes.build(7)["unit"] as UnitData
	state.units[0] = UnitState.new(0, wraith, UnitState.Team.PLAYER, Vector2i(2, 2))
	for type_name in ["physical", "holy", "fire", "frost", "poison"]:
		var damage := DamageEffect.new()
		damage.min_amount = 100
		damage.max_amount = 100
		damage.damage_type = load("res://data/damage_types/%s.tres" % type_name) as DamageType
		assert_eq(damage.scaled(state, 1, 0, 100.0), 100.0, "%s: the type is only a look" % type_name)


func test_healing_touch_cannot_be_aimed_at_the_priestess_herself() -> void:
	var map := PvpMap.generate(7, load("res://data/maps/typologies/open_field.tres") as MapTypology, 12)
	var side_a: Array[Dictionary] = [{"hero": 5, "name": "P"}, {"hero": 0, "name": "K"}]
	var side_b: Array[Dictionary] = [{"hero": 0, "name": "E"}]
	var state := PvpBattle.create(map, side_a, side_b, 5)
	state.units[0].cell = Vector2i(2, 2)
	state.units[1].cell = Vector2i(2, 4)
	var heal := (PvpHeroes.build(5)["unit"] as UnitData).spells[_priestess_spell("Healing Touch")]
	assert_false(Targeting.can_target(state, 0, heal, Vector2i(2, 2)), "not herself")
	assert_true(Targeting.can_target(state, 0, heal, Vector2i(2, 4)), "an ally")


func test_sudden_death_in_pvp_gets_heavier_and_reveals() -> void:
	var state := _duel()
	var battle := Battle.new(state)
	battle.sudden_death_round = 10
	battle.sudden_death_percent = 10
	state.turn_order.round_number = 10
	assert_eq(battle.sudden_death_percent_now(), 10)
	state.turn_order.round_number = 15
	assert_eq(battle.sudden_death_percent_now(), 10 + 3 * 5, "heavier every round")
	battle.start()
	var unit := state.current_unit()
	if not unit.is_stealthed():
		unit.add_status(load(STEALTH) as StatusData, unit.id)
	var events := battle._sudden_death(unit)
	assert_false(unit.is_stealthed(), "the damage revealed it")
	assert_true(events.any(func(e: BattleEvents.Event) -> bool: return e is BattleEvents.StatusExpired))


func test_two_healer_teams_cannot_stall_for_ever() -> void:
	var result := PvpSimulator.play([5, 5], [5, 5], 3, 12, "open_field", 900)
	assert_ne(result.winner, -1, "sudden death ends it (rounds %d)" % result.rounds)


func test_every_class_plays_a_stretch_against_the_next_without_errors() -> void:
	for hero in PvpHeroes.hero_count():
		var other := (hero + 1) % PvpHeroes.hero_count()
		var side_a: Array[int] = [hero]
		var side_b: Array[int] = [other]
		var result := PvpSimulator.play(side_a, side_b, 30 + hero, 12, "open_field", 60)
		assert_true(result.hp_left.size() == 2, "%d vs %d played" % [hero, other])


func test_a_start_with_another_class_signature_is_refused() -> void:
	var rig := NetRig.new()
	rig.host(1)
	rig.guest(2)
	rig.sessions[1].set_field("side", 0)
	rig.sessions[2].set_field("side", 1)
	rig.net.flush()
	rig.sessions[1].set_ready(true)
	rig.sessions[2].set_ready(true)
	rig.net.flush()
	var error := rig.sessions[2].state.apply({"k": "start", "n": rig.sessions[2].state.entry_count() + 1, "sig": PvpHeroes.signature() + 1})
	assert_ne(error, "", "another version of the classes")
	assert_eq(rig.sessions[2].state.phase, MatchState.Phase.LOBBY)

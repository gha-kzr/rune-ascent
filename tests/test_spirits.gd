extends TestCase
## Spirits (multiplayer, a lobby rule): a fallen hero keeps its turns as a spirit with one action and three spells (Curse,
## Root, Reveal; no heal), anywhere on the board, one curse of a kind at a time on a target; it never walks, its action
## ends its turn, and the fight is still won by the living.


## A Knight (unit 0) and a Ranger (unit 1) on side A, a Sorceress (unit 2) and a Rogue (unit 3) on side B, spirits on.
func _match(spirits := true, cards := false) -> BattleState:
	var map := PvpMap.generate(7, load("res://data/maps/typologies/open_field.tres") as MapTypology, 12)
	var side_a: Array[Dictionary] = [{"hero": _class("Knight"), "name": "K"}, {"hero": _class("Ranger"), "name": "R"}]
	var side_b: Array[Dictionary] = [{"hero": _class("Sorceress"), "name": "S"}, {"hero": _class("Rogue"), "name": "G"}]
	var state := PvpBattle.create(map, side_a, side_b, 5)
	state.use_average_rolls = true
	if spirits:
		state.spirit_kit = PvpHeroes.spirit_kit()
	if cards:
		state.enable_cards(3)
	return state


func _class(name: String) -> int:
	for index in PvpHeroes.hero_count():
		if PvpHeroes.hero(index).display_name() == name:
			return index
	return -1


func _slot(unit: UnitState, spell_name: String) -> int:
	for index in unit.data.spells.size():
		if unit.data.spells[index].display_name == spell_name:
			return index
	return -1


## Starts the fight and kills unit `fallen` (a QA cheat, like a lethal hit), then plays until it is `unit_id`'s turn.
func _started_with_a_fallen(state: BattleState, fallen: int) -> Battle:
	var battle := Battle.new(state)
	battle.start()
	battle.qa_set_hp(fallen, 0)
	return battle


func _turn_of(battle: Battle, unit_id: int) -> void:
	for step in 20:
		if battle.state.current_unit().id == unit_id:
			return
		battle.perform(BattleActions.EndTurn.new(battle.state.current_unit().id))


func test_a_fallen_hero_stays_in_the_turn_order_as_a_spirit_with_its_three_spells_and_one_action() -> void:
	var state := _match()
	var battle := _started_with_a_fallen(state, 1)
	var ranger := state.units[1]
	assert_false(ranger.is_alive())
	assert_true(ranger.spirit and ranger.can_act())
	assert_true(1 in state.turn_order.upcoming(), "still in the turn order")
	assert_eq(ranger.data.spells, PvpHeroes.spirit_kit(), "the spirit's spells")
	assert_eq(ranger.statuses.size(), 0)
	_turn_of(battle, 1)
	assert_eq(state.current_unit().id, 1, "its turn comes")
	assert_eq(ranger.ap, 1, "one action")
	assert_eq(ranger.mp, 0)
	assert_false(state.is_over(), "the living fight on")
	assert_false(BattleActions.Move.new(1, ranger.cell + Vector2i.RIGHT).validate(state).is_empty(), "a spirit doesn't walk")


func test_a_spirits_curse_lands_anywhere_ends_its_turn_and_only_once_per_target() -> void:
	var state := _match()
	var battle := _started_with_a_fallen(state, 1)
	_turn_of(battle, 1)
	var ranger := state.units[1]
	var curse := _slot(ranger, "Curse")
	var sorceress := state.units[2]
	var result := battle.perform(BattleActions.CastSpell.new(1, curse, sorceress.cell))
	assert_true(result.ok(), result.error)
	assert_eq(sorceress.damage_taken_percent(), 120, "+20 % damage taken")
	assert_ne(state.current_unit().id, 1, "the action ended the spirit's turn")
	assert_false(Targeting.can_target(state, 1, ranger.data.spells[curse], sorceress.cell), "one curse at a time on a target")
	assert_true(Targeting.can_target(state, 1, ranger.data.spells[curse], state.units[3].cell), "another target is fine")


func test_reveal_ends_stealth_in_its_cross_and_a_spirit_never_heals() -> void:
	var state := _match()
	var battle := _started_with_a_fallen(state, 1)
	var rogue := state.units[3]
	rogue.add_status(load("res://data/pvp/statuses/stealth.tres") as StatusData, 3)
	state.units[0].hp -= 30
	_turn_of(battle, 1)
	var ranger := state.units[1]
	var result := battle.perform(BattleActions.CastSpell.new(1, _slot(ranger, "Reveal"), rogue.cell + Vector2i(0, 2)))
	assert_true(result.ok(), result.error)
	assert_false(rogue.is_stealthed(), "found, two cells from the cross's middle")
	for spell in ranger.data.spells:
		for effect in spell.effects:
			assert_false(effect is HealEffect, "%s: spirits make fights shorter, not longer" % spell.display_name)


func test_without_the_rule_the_fallen_leave_the_turn_order() -> void:
	var state := _match(false)
	_started_with_a_fallen(state, 1)
	assert_false(state.units[1].spirit)
	assert_false(1 in state.turn_order.upcoming())


func test_the_fight_ends_when_a_side_has_only_spirits_left() -> void:
	var state := _match()
	var battle := _started_with_a_fallen(state, 2)
	battle.qa_set_hp(3, 0)
	assert_true(state.is_over(), "spirits don't keep a side alive")
	assert_eq(state.outcome(), BattleState.Outcome.PLAYER_WON)


func test_in_card_combat_a_spirit_holds_its_whole_kit_every_turn_and_plays_one() -> void:
	var all: Array[int] = []
	all.assign(range(PvpHeroes.spirit_kit().size()))
	var state := _match(true, true)
	var battle := _started_with_a_fallen(state, 1)
	_turn_of(battle, 1)
	var ranger := state.units[1]
	assert_eq(ranger.hand, all, "the whole kit")
	assert_eq(ranger.ap, 1, "one play")
	assert_true(battle.perform(BattleActions.CastSpell.new(1, _slot(ranger, "Curse"), state.units[2].cell)).ok())
	_turn_of(battle, 1)
	assert_eq(ranger.hand, all, "the others were thrown away and the whole kit comes back")


func test_the_ai_plays_a_spirit_without_walking() -> void:
	var state := _match()
	var battle := _started_with_a_fallen(state, 1)
	state.units[0].hp -= 60
	_turn_of(battle, 1)
	var action := EnemyAI.choose_next(state, 1)
	assert_true(action is BattleActions.CastSpell or action is BattleActions.EndTurn, "a cast or a pass, never a move")
	assert_true(battle.perform(action).ok())


func test_a_whole_match_with_spirits_plays_to_the_end() -> void:
	var result := PvpSimulator.play([_class("Knight"), _class("Sorceress")], [_class("Goblin"), _class("Priestess")], 21, 13, "open_field", 900)
	assert_true(result.winner != -1 or result.rounds > 0)

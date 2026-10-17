extends TestCase
## Card combat: spells become a deck (two copies of each), a hand of four is drawn each turn, at most two cards are played (a play is an
## AP), unplayed cards stay or are thrown away, and every peer deals and replays the same cards.


## A Knight (unit 0, side A) and a Ranger (unit 1, side B) next to each other, in card mode.
func _duel(card_seed := 3) -> BattleState:
	var map := PvpMap.generate(7, load("res://data/maps/typologies/open_field.tres") as MapTypology, 12)
	var side_a: Array[Dictionary] = [{"hero": 0, "name": "Knight"}]
	var side_b: Array[Dictionary] = [{"hero": 1, "name": "Ranger"}]
	var state := PvpBattle.create(map, side_a, side_b, 5)
	state.units[0].cell = Vector2i(5, 5)
	state.units[1].cell = Vector2i(5, 6)
	state.enable_cards(card_seed)
	return state


func _started(state: BattleState) -> Battle:
	var battle := Battle.new(state)
	battle.start()
	return battle


func _slot(unit: UnitState, spell_name: String) -> int:
	for index in unit.data.spells.size():
		if unit.data.spells[index].display_name == spell_name:
			return index
	return -1


func test_a_deck_holds_every_spell_twice() -> void:
	for hero in PvpHeroes.hero_count():
		var unit := PvpHeroes.build(hero)["unit"] as UnitData
		var deck := CardRules.deck_for(unit)
		for slot in unit.spells.size():
			assert_eq(deck.count(slot), CardRules.COPIES_PER_SPELL, "%s: %s" % [unit.display_name, unit.spells[slot].display_name])
		assert_true(deck.size() >= CardRules.HAND_SIZE + 2, "%s: a deck deeper than a hand" % unit.display_name)


func test_every_unit_starts_with_a_full_hand_and_two_plays() -> void:
	var state := _duel()
	for unit in state.units:
		assert_true(unit.card_mode)
		assert_eq(unit.hand.size(), CardRules.HAND_SIZE)
		assert_eq(unit.hand.size() + unit.draw_pile.size() + unit.discard_pile.size(), CardRules.deck_for(unit.data).size(), "no card lost")
		assert_eq(unit.max_ap(), CardRules.PLAYS_PER_TURN, "AP is the number of plays")
	var battle := _started(state)
	assert_eq(state.units[state.current_unit().id].ap, CardRules.PLAYS_PER_TURN)
	assert_true(battle.state.cards)


func test_the_same_seed_deals_the_same_cards_and_another_does_not() -> void:
	assert_eq(_duel(3).units[0].hand, _duel(3).units[0].hand)
	var differs := false
	for other_seed in [4, 5, 6, 7]:
		differs = differs or _duel(other_seed).units[0].hand != _duel(3).units[0].hand or _duel(other_seed).units[0].draw_pile != _duel(3).units[0].draw_pile
	assert_true(differs, "the seed shuffles the deck")


func test_a_cast_needs_a_card_in_hand_and_uses_one_play() -> void:
	var state := _duel()
	var battle := _started(state)
	var unit := state.current_unit()
	var enemy := state.units[1 - unit.id]
	enemy.cell = unit.cell + Vector2i(1, 0)
	var held := unit.hand[0]
	var missing := -1
	for slot in unit.data.spells.size():
		if not unit.hand.has(slot):
			missing = slot
	if missing >= 0:
		var refused := battle.perform(BattleActions.CastSpell.new(unit.id, missing, enemy.cell))
		assert_false(refused.ok(), "a spell that is not in the hand can't be cast")
		assert_true(refused.error.contains("hand"), refused.error)
	var spell := unit.data.spells[held]
	var cell := _target_for(state, unit, held)
	if cell == Vector2i(-1, -1):
		return  # Nothing reachable for this draw; the rules above are what this test is about.
	var hand_before := unit.hand.size()
	var result := battle.perform(BattleActions.CastSpell.new(unit.id, held, cell))
	assert_true(result.ok(), result.error)
	assert_eq(unit.ap, CardRules.PLAYS_PER_TURN - 1, "one play spent, whatever the spell costs (%d AP)" % spell.ap_cost)
	assert_eq(unit.hand.size(), hand_before - 1, "the card left the hand")
	assert_eq(unit.discard_pile.size(), 1, "and went to the discard pile")
	assert_true(unit.cooldowns.is_empty(), "cards replace cooldowns")


func _target_for(state: BattleState, unit: UnitState, slot: int) -> Vector2i:
	var spell := unit.data.spells[slot]
	for cell in Targeting.targetable_cells(state, unit.id, spell):
		if Targeting.can_target(state, unit.id, spell, cell):
			return cell
	return Vector2i(-1, -1)


func test_only_two_cards_can_be_played_in_a_turn() -> void:
	var state := _duel(11)
	var battle := _started(state)
	var unit := state.current_unit()
	var played := 0
	for attempt in 6:
		var slot := -1
		var cell := Vector2i(-1, -1)
		for candidate in unit.hand:
			cell = _target_for(state, unit, candidate)
			if cell != Vector2i(-1, -1):
				slot = candidate
				break
		if slot < 0:
			break
		var result := battle.perform(BattleActions.CastSpell.new(unit.id, slot, cell))
		if not result.ok():
			assert_true(result.error.contains("AP"), result.error)
			break
		played += 1
	assert_true(played <= CardRules.PLAYS_PER_TURN, "at most two plays (%d)" % played)
	assert_eq(unit.ap, CardRules.PLAYS_PER_TURN - played)


func test_discarding_is_free_and_only_cards_in_hand_can_be_thrown() -> void:
	var state := _duel()
	var battle := _started(state)
	var unit := state.current_unit()
	var thrown := unit.hand[0]
	var result := battle.perform(BattleActions.DiscardCard.new(unit.id, thrown))
	assert_true(result.ok(), result.error)
	assert_eq(unit.ap, CardRules.PLAYS_PER_TURN, "throwing a card costs nothing")
	assert_eq(unit.hand.size(), CardRules.HAND_SIZE - 1)
	assert_eq(unit.discard_pile, [thrown] as Array[int])
	assert_true(result.events[0] is BattleEvents.CardDiscarded)
	var absent := -1
	for slot in unit.data.spells.size():
		if not unit.hand.has(slot):
			absent = slot
	if absent >= 0:
		assert_false(battle.perform(BattleActions.DiscardCard.new(unit.id, absent)).ok(), "can't throw a card you do not hold")
	assert_false(battle.perform(BattleActions.DiscardCard.new(1 - unit.id, 0)).ok(), "not your turn")


func test_the_hand_is_refilled_at_the_end_of_the_turn_and_kept_cards_stay() -> void:
	var state := _duel()
	var battle := _started(state)
	var unit := state.current_unit()
	var kept: Array[int] = unit.hand.duplicate()
	var thrown: int = kept.pop_front()
	battle.perform(BattleActions.DiscardCard.new(unit.id, thrown))
	battle.perform(BattleActions.EndTurn.new(unit.id))
	assert_eq(unit.hand.size(), CardRules.HAND_SIZE, "refilled as the turn ends, to be read during the others' turns")
	battle.perform(BattleActions.EndTurn.new(state.current_unit().id))
	assert_eq(state.current_unit().id, unit.id, "back to the first unit")
	assert_eq(unit.hand.size(), CardRules.HAND_SIZE, "hand refilled")
	for card in kept:
		assert_true(unit.hand.has(card), "a card that was kept is still there")
	assert_eq(unit.ap, CardRules.PLAYS_PER_TURN)


func test_the_discard_pile_is_shuffled_back_when_the_deck_runs_out() -> void:
	var state := _duel()
	var unit := state.units[0]
	var total := CardRules.deck_for(unit.data).size()
	for turn in total * 2:
		unit.draw_hand()
		assert_eq(unit.hand.size(), CardRules.HAND_SIZE, "turn %d: always a full hand" % turn)
		assert_eq(unit.hand.size() + unit.draw_pile.size() + unit.discard_pile.size(), total, "no card is lost or made")
		unit.spend_card(unit.hand[0])
		unit.spend_card(unit.hand[0])


func test_a_clone_deals_the_same_next_cards_and_leaves_the_original_alone() -> void:
	var state := _duel()
	var copy := state.clone()
	assert_true(copy.cards)
	assert_eq(copy.units[0].hand, state.units[0].hand)
	assert_eq(copy.units[0].draw_pile, state.units[0].draw_pile)
	for unit: UnitState in [copy.units[0], state.units[0]]:
		unit.spend_card(unit.hand[0])
		unit.spend_card(unit.hand[0])
		unit.draw_hand()
	assert_eq(copy.units[0].hand, state.units[0].hand, "the same dice give the same draws")
	var other := state.clone()
	other.units[0].spend_card(other.units[0].hand[0])
	assert_eq(state.units[0].discard_pile.size(), 2, "a clone does not change the original")


func test_the_log_replays_to_the_same_cards_on_another_peer() -> void:
	var host := MatchState.new()
	var guest := MatchState.new()
	var entries: Array[Dictionary] = [
		{"k": "join", "id": 1, "name": "A", "token": MatchState.token_hash("a")},
		{"k": "join", "id": 2, "name": "B", "token": MatchState.token_hash("b")},
		{"k": "set", "id": 1, "f": "side", "v": 0}, {"k": "set", "id": 2, "f": "side", "v": 1},
		{"k": "cfg", "f": "cards", "v": true},
		{"k": "set", "id": 1, "f": "ready", "v": true}, {"k": "set", "id": 2, "f": "ready", "v": true},
		{"k": "start", "sig": PvpHeroes.signature()}, {"k": "go"},
	]
	for entry in entries:
		assert_eq(host.apply(entry.duplicate()), "", str(entry))
		assert_eq(guest.apply(entry.duplicate()), "", str(entry))
	assert_true(host.battle.state.cards, "the lobby setting turned the cards on")
	var first := host.battle.state.current_unit()
	var thrown := first.hand[0]
	var act := {"k": "act", "a": ActionCodec.encode(BattleActions.DiscardCard.new(first.id, thrown))}
	assert_eq(host.apply(act.duplicate()), "")
	assert_eq(guest.apply(act.duplicate()), "")
	var end := {"k": "act", "a": ActionCodec.encode(BattleActions.EndTurn.new(first.id))}
	assert_eq(host.apply(end.duplicate()), "")
	assert_eq(guest.apply(end.duplicate()), "")
	assert_eq(host.fingerprint(), guest.fingerprint(), "both peers hold the same cards")
	assert_eq(host.battle.state.units[first.id].hand, guest.battle.state.units[first.id].hand)


func test_the_cards_setting_is_a_flag_and_changes_the_hash() -> void:
	var state := MatchState.new()
	assert_eq(state.apply({"k": "cfg", "f": "cards", "v": "yes"}), "bad flag")
	assert_eq(state.apply({"k": "cfg", "f": "cards", "v": true}), "")
	assert_true(state.settings["cards"])
	var plain := _duel()
	var with_cards := PvpBattle.create(PvpMap.generate(7, load("res://data/maps/typologies/open_field.tres") as MapTypology, 12),
			[{"hero": 0, "name": "Knight"}] as Array[Dictionary], [{"hero": 1, "name": "Ranger"}] as Array[Dictionary], 5)
	assert_ne(StateHash.of(plain), StateHash.of(with_cards), "the hand is part of the fingerprint")


func test_the_action_codec_round_trips_a_discard_and_rejects_a_bad_one() -> void:
	var action := ActionCodec.decode(ActionCodec.encode(BattleActions.DiscardCard.new(2, 4)))
	assert_true(action is BattleActions.DiscardCard)
	assert_eq((action as BattleActions.DiscardCard).spell_index, 4)
	assert_true(ActionCodec.decode({"t": "discard", "a": 1}) == null, "no card named")
	assert_true(ActionCodec.decode({"t": "discard", "a": 1, "s": "x"}) == null)


func test_the_ai_plays_only_cards_it_holds() -> void:
	var state := _duel(5)
	state.units[0].cell = Vector2i(5, 5)
	state.units[1].cell = Vector2i(5, 7)
	var battle := _started(state)
	var casts := 0
	for step in 40:
		if battle.state.is_over():
			break
		var unit := battle.state.current_unit()
		var action := EnemyAI.choose_next(battle.state, unit.id)
		if action is BattleActions.CastSpell:
			casts += 1
			assert_true(unit.hand.has((action as BattleActions.CastSpell).spell_index), "the AI picked a card from its hand")
		var result := battle.perform(action)
		assert_true(result.ok(), result.error)
	assert_true(casts > 0, "the AI cast something")

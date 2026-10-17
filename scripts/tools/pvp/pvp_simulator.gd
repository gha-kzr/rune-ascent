class_name PvpSimulator
extends RefCounted
## Plays PvP matches between AIs (both sides use EnemyAI) on the real PvP rules and maps: the numbers behind
## `tools/pvp_balance.gd`. The AI plays worse than a player (it never plans two turns ahead and does not know a
## class's tricks), so read the results as a lower bound and as a way to spot a class that is far off.

const MAX_ACTIONS := 3000
const SUDDEN_DEATH_ROUND := 40
const SUDDEN_DEATH_PERCENT := 10


class Result:
	## 0: side A won, 1: side B won, -1: nobody (a draw or the action limit).
	var winner := -1
	var rounds := 0
	## Per unit id: damage dealt and healing done are not tracked; HP left at the end is.
	var hp_left: Array[int] = []


## One match: `side_a` and `side_b` are class indexes. `map_seed` also seeds the dice. `stats`, if given, records the
## match (PvpStats: damage, heals, deaths, spells). `spirits`: the lobby's Spirits rule (on by default, like the lobby).
static func play(side_a: Array[int], side_b: Array[int], map_seed: int, size := 12, typology := "open_field", max_actions := MAX_ACTIONS, cards := false, stats: PvpStats = null, spirits := true) -> Result:
	var typology_file := "res://data/maps/typologies/%s.tres" % typology
	if not ResourceLoader.exists(typology_file):
		push_error("PvpSimulator: no map typology %s" % typology)
		return Result.new()
	var map := PvpMap.generate(map_seed, load(typology_file) as MapTypology, size)
	var entries_a: Array[Dictionary] = []
	var entries_b: Array[Dictionary] = []
	for hero in side_a:
		entries_a.append({"hero": hero, "name": "A"})
	for hero in side_b:
		entries_b.append({"hero": hero, "name": "B"})
	var state := PvpBattle.create(map, entries_a, entries_b, map_seed)
	var result := Result.new()
	if state == null:
		push_error("PvpSimulator: can't build the match (map size %d too small for %d players?)" % [size, side_a.size() + side_b.size()])
		return result
	state.use_average_rolls = false
	if spirits:
		state.spirit_kit = PvpHeroes.spirit_kit()
	if cards:
		state.enable_cards(map_seed)
	var battle := Battle.new(state)
	battle.sudden_death_round = SUDDEN_DEATH_ROUND
	battle.sudden_death_percent = SUDDEN_DEATH_PERCENT
	if stats != null:
		var classes: Array[String] = []
		for hero in side_a + side_b:
			classes.append(PvpHeroes.hero(hero).display_name())
		stats.begin_match(classes)
	var started := battle.start()
	if stats != null:
		stats.record(state, started)
	var actions := 0
	while not state.is_over() and actions < max_actions:
		var unit := state.current_unit()
		var action := EnemyAI.choose_next(state, unit.id)
		var performed := battle.perform(action)
		if not performed.ok():
			performed = battle.perform(BattleActions.EndTurn.new(unit.id))
		if stats != null:
			stats.record(state, performed.events)
		actions += 1
	result.rounds = state.turn_order.round_number
	var outcome := state.outcome()
	if outcome == BattleState.Outcome.PLAYER_WON:
		result.winner = 0
	elif outcome == BattleState.Outcome.ENEMY_WON:
		result.winner = 1
	for unit in state.units:
		result.hp_left.append(maxi(0, unit.hp))
	if stats != null:
		stats.end_match(state, result.winner)
	return result

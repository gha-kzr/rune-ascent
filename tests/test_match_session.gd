extends TestCase
## The match session on a fake network: lobby, start, placement, turns, the host leaving (host
## swap), a player dropping out (the AI plays for them) and coming back, and drifted peers.


func _rig(total: int, a_count: int) -> NetRig:
	var rig := NetRig.new()
	rig.start_match(total, a_count)
	return rig


func _battle_started(rig: NetRig) -> bool:
	return rig.sessions[1].state.battle != null and rig.sessions[1].state.battle.state.started


## Everyone places nothing and says they're happy; the host then starts the first turn.
func _go(rig: NetRig) -> void:
	for id in rig.sessions:
		if not rig.net.transport(id).closed:
			rig.sessions[id].set_placed(true)
	rig.run(0.5)


func test_players_join_and_see_the_same_lobby() -> void:
	var rig := NetRig.new()
	rig.host(1, "Alice")
	rig.guest(2, "Bob")
	rig.guest(3, "Carol")
	rig.net.flush()
	for id in rig.sessions:
		var state := rig.sessions[id].state
		assert_eq(state.seat_ids(), [1, 2, 3] as Array[int], "seat list on %d" % id)
		assert_eq(state.seats[2].name, "Bob")
		assert_true(rig.sessions[id].is_synced)
	assert_true(rig.in_step())
	assert_eq(rig.sessions[2].host_id, 1)
	for id in [1, 2, 3]:
		assert_eq(rig.sessions[1].state.seats[id].side, -1, "nobody is put on a side for them")


func test_nobody_can_ready_up_without_a_side() -> void:
	var rig := NetRig.new()
	rig.host(1)
	var refusals := []
	rig.sessions[1].rejected.connect(func(why: String) -> void: refusals.append(why))
	rig.sessions[1].set_ready(true)
	rig.net.flush()
	assert_false(rig.sessions[1].state.seats[1].ready)
	assert_eq(refusals.size(), 1)
	rig.sessions[1].set_field("side", 0)
	rig.sessions[1].set_ready(true)
	rig.net.flush()
	assert_true(rig.sessions[1].state.seats[1].ready)


func test_the_host_removes_a_player_who_cannot_come_back() -> void:
	var rig := NetRig.new()
	rig.host(1)
	rig.guest(2)
	rig.guest(3)
	rig.sessions[2].kick(3)  # Not the host: refused.
	rig.net.flush()
	assert_true(rig.sessions[1].state.seats.has(3))
	rig.sessions[1].kick(3)
	rig.net.flush()
	assert_eq(rig.sessions[1].state.seat_ids(), [1, 2] as Array[int])
	assert_true(rig.sessions[3].halted_now(), "the removed player is told")
	assert_true(MatchState.token_hash(NetRig.token_of(3)) in rig.sessions[1].state.banned, "and cannot rejoin")
	assert_true(rig.in_step())


func test_emotes_reach_the_others_and_not_too_often() -> void:
	var rig := NetRig.new()
	rig.host(1)
	rig.guest(2)
	var seen := []
	rig.sessions[1].emote_received.connect(func(id: int, emote: int) -> void: seen.append([id, emote]))
	rig.sessions[2].send_emote(3)
	rig.sessions[2].send_emote(4)  # Too soon: dropped.
	rig.sessions[2].send_emote(99)  # Not an emote.
	rig.net.flush()
	assert_eq(seen, [[2, 3]])
	rig.run(2.0)
	rig.sessions[2].send_emote(4)
	rig.net.flush()
	assert_eq(seen, [[2, 3], [2, 4]])


func test_a_player_changes_hero_and_side_but_not_someone_elses() -> void:
	var rig := NetRig.new()
	rig.host(1)
	rig.guest(2)
	rig.sessions[2].set_field("hero", 2)
	rig.sessions[2].set_field("side", 1)
	rig.net.flush()
	assert_eq(rig.sessions[1].state.seats[2].hero, 2)
	assert_eq(rig.sessions[1].state.seats[2].side, 1)
	var refusals := []
	rig.sessions[2].rejected.connect(func(why: String) -> void: refusals.append(why))
	rig.sessions[2].propose({"k": "set", "id": 1, "f": "hero", "v": 1})
	rig.sessions[2].configure("size", 16)
	rig.sessions[2].set_field("hero", 99)
	rig.net.flush()
	assert_eq(refusals.size(), 3, "someone else's seat, a host setting, a hero that doesn't exist")
	assert_eq(rig.sessions[1].state.seats[1].hero, 0, "untouched")
	assert_eq(rig.sessions[1].state.settings["size"], 14)
	assert_true(rig.in_step())


func test_the_host_sets_the_map_and_everyone_gets_the_same_battle() -> void:
	var rig := NetRig.new()
	rig.host(1)
	rig.guest(2)
	rig.sessions[1].configure("typology", "ruins")
	rig.sessions[1].configure("size", 15)
	rig.sessions[1].configure("seed", 4242)
	rig.sessions[1].configure("turn", 60)
	rig.sessions[1].set_field("side", 0)
	rig.sessions[2].set_field("side", 1)
	rig.net.flush()
	assert_ne(rig.sessions[1].state.start_problem(), "", "nobody is ready")
	rig.sessions[1].set_ready(true)
	rig.sessions[2].set_ready(true)
	rig.net.flush()
	rig.sessions[1].start_match()
	rig.net.flush()
	var battle_a := rig.sessions[1].state.battle.state
	var battle_b := rig.sessions[2].state.battle.state
	assert_eq(battle_a.grid.size, Vector2i(15, 15))
	assert_eq(battle_b.grid.size, Vector2i(15, 15))
	assert_eq(StateHash.of(battle_a), StateHash.of(battle_b), "the same map and units")
	assert_eq(rig.sessions[2].state.settings["turn"], 60)
	assert_eq(rig.sessions[1].unit_of(1), 0)
	assert_eq(rig.sessions[1].unit_of(2), 1)


func test_changing_a_setting_leaves_the_players_ready() -> void:
	var rig := NetRig.new()
	rig.host(1)
	rig.guest(2)
	rig.sessions[2].set_field("side", 1)
	rig.sessions[2].set_ready(true)
	rig.net.flush()
	assert_true(rig.sessions[1].state.seats[2].ready)
	rig.sessions[1].configure("size", 12)
	rig.net.flush()
	assert_true(rig.sessions[1].state.seats[2].ready, "a player who is ready stays ready when the host edits the map or the rules")
	rig.sessions[2].set_field("hero", 1)
	rig.net.flush()
	assert_false(rig.sessions[1].state.seats[2].ready, "but a change of their own hero takes their Ready back")


func test_a_side_holds_six_players_at_most() -> void:
	var rig := NetRig.new()
	rig.host(1)
	for id in range(2, 9):
		rig.guest(id)
	for id in range(1, 9):
		rig.sessions[id].set_field("side", 0)
	rig.net.flush()
	assert_eq(rig.sessions[1].state.seats_on(0).size(), 6)
	assert_eq(rig.sessions[1].state.seats_on(1).size(), 0, "the others stay where they were")
	assert_eq(rig.sessions[1].state.seats[8].side, -1)
	assert_true(rig.in_step())


func test_six_against_six_starts_with_everyone_on_their_own_cell() -> void:
	var rig := NetRig.new()
	rig.start_match(12, 6)
	assert_eq(rig.sessions[1].state.phase, MatchState.Phase.BATTLE)
	var battle_state := rig.sessions[1].state.battle.state
	assert_eq(battle_state.units.size(), 12)
	var cells := {}
	for unit in battle_state.units:
		cells[unit.cell] = true
	assert_eq(cells.size(), 12, "a cell each in the two 3 x 3 start zones")
	rig.run(5.0)
	assert_true(rig.in_step())


func test_the_match_starts_placement_then_the_first_turn_when_all_are_placed() -> void:
	var rig := _rig(4, 2)
	assert_true(rig.sessions[3].state.battle != null, "the battle exists on every peer")
	assert_false(_battle_started(rig), "placement first")
	rig.sessions[2].act(BattleActions.Place.new(1, rig.sessions[2].state.battle.state.zone[0]))
	rig.net.flush()
	assert_eq(rig.sessions[1].state.battle.state.units[1].cell, rig.sessions[1].state.battle.state.zone[0], "the placement reached the host")
	rig.sessions[3].act(BattleActions.Place.new(0, rig.sessions[3].state.battle.state.zone[0]))
	rig.net.flush()
	assert_ne(rig.sessions[1].state.battle.state.units[0].cell, rig.sessions[1].state.battle.state.zone[0], "not their hero: refused")
	rig.sessions[3].act(BattleActions.Place.new(2, rig.sessions[3].state.battle.state.zone_enemy[0]))
	rig.net.flush()
	assert_eq(rig.sessions[4].state.battle.state.units[2].cell, rig.sessions[1].state.battle.state.zone_enemy[0], "side B places too")
	_go(rig)
	assert_true(_battle_started(rig), "everyone placed: the host starts the fight")
	assert_true(rig.in_step())


func test_only_the_owner_acts_on_their_turn() -> void:
	var rig := _rig(2, 1)
	_go(rig)
	var battle := rig.sessions[1].state.battle.state
	var current_seat := rig.sessions[1].state.current_seat()
	var other_seat := 2 if current_seat == 1 else 1
	var refusals := []
	rig.sessions[other_seat].rejected.connect(func(why: String) -> void: refusals.append(why))
	rig.sessions[other_seat].act(BattleActions.EndTurn.new(rig.sessions[1].unit_of(other_seat)))
	rig.net.flush()
	assert_eq(refusals.size(), 1, "not their turn")
	rig.sessions[other_seat].act(BattleActions.EndTurn.new(rig.sessions[1].unit_of(current_seat)))
	rig.net.flush()
	assert_eq(refusals.size(), 2, "not their hero")
	var before := rig.sessions[1].state.entry_count()
	rig.sessions[current_seat].act(BattleActions.EndTurn.new(rig.sessions[1].unit_of(current_seat)))
	rig.net.flush()
	assert_eq(rig.sessions[1].state.entry_count(), before + 1)
	assert_eq(rig.sessions[1].state.current_seat(), other_seat, "the turn passed")
	assert_true(rig.in_step())
	assert_true(battle != null)


func test_an_idle_player_loses_the_turn_when_the_timer_runs_out() -> void:
	var rig := _rig(2, 1)
	rig.sessions[1].configure("turn", 10)  # Too late: the match started. (Refused.)
	rig.net.flush()
	_go(rig)
	var first := rig.sessions[1].state.current_seat()
	rig.run(float(rig.sessions[1].state.settings["turn"]) - 1.0)
	assert_eq(rig.sessions[1].state.current_seat(), first, "still their turn")
	rig.run(2.0)
	assert_ne(rig.sessions[1].state.current_seat(), first, "the host ended it")
	assert_true(rig.in_step())


func test_the_next_player_takes_over_when_the_host_leaves() -> void:
	var rig := NetRig.new()
	rig.host(1)
	rig.guest(2)
	rig.guest(3)
	rig.net.flush()
	var changes := []
	rig.sessions[3].host_changed.connect(func(id: int) -> void: changes.append(id))
	rig.net.kill(1)
	rig.run(3.0)
	assert_eq(rig.sessions[2].host_id, 2)
	assert_eq(rig.sessions[3].host_id, 2)
	assert_eq(changes, [2], "peer 3 learned who the new host is")
	assert_false(rig.sessions[2].state.seats.has(1), "the lobby forgot the old host")
	rig.sessions[3].set_field("hero", 1)
	rig.net.flush()
	assert_eq(rig.sessions[2].state.seats[3].hero, 1, "the new host numbers entries")
	assert_true(rig.in_step())


func test_a_new_host_completes_its_log_from_the_peer_that_got_the_last_entry() -> void:
	var rig := _rig(3, 1)
	_go(rig)
	var current_seat := rig.sessions[1].state.current_seat()
	# The host's last entry reaches peer 3 only: the host dies before peer 2 gets it (it was on its way
	# to 2 through 3, one round later).
	rig.net.cut(1, 2)
	rig.sessions[1].propose({"k": "act", "sys": true, "a": ActionCodec.encode(BattleActions.EndTurn.new(rig.sessions[1].unit_of(current_seat)))})
	rig.net.deliver()
	rig.net.kill(1)
	assert_ne(rig.sessions[3].state.entry_count(), rig.sessions[2].state.entry_count(), "the two peers are out of step")
	rig.run(4.0)
	assert_eq(rig.sessions[2].host_id, 2)
	assert_eq(rig.sessions[2].state.entry_count(), rig.sessions[3].state.entry_count(), "caught up")
	assert_true(rig.in_step())
	assert_false(rig.sessions[2].halted_now() or rig.sessions[3].halted_now())


func test_a_resent_proposal_is_not_applied_twice_after_a_host_swap() -> void:
	var rig := _rig(3, 1)
	_go(rig)
	var seat := rig.sessions[1].state.current_seat()
	if seat == 1:
		rig.sessions[1].act(BattleActions.EndTurn.new(rig.sessions[1].unit_of(1)))
		rig.net.flush()
		seat = rig.sessions[1].state.current_seat()
	var session := rig.sessions[seat]
	var unit := rig.sessions[1].unit_of(seat)
	session.act(BattleActions.EndTurn.new(unit))
	rig.net.deliver()  # The host has it...
	rig.net.kill(1)  # ...and dies at once.
	rig.run(4.0)
	var ends := 0
	for entry in rig.sessions[2].state.log:
		if entry["k"] == "act" and entry["a"]["t"] == "end" and entry["a"]["a"] == unit:
			ends += 1
	assert_true(ends <= 1, "one end of turn for that unit, not two")
	assert_true(rig.in_step())


func test_a_player_who_drops_out_is_replaced_by_the_ai_after_the_grace_period() -> void:
	var rig := _rig(2, 1)
	_go(rig)
	rig.net.kill(2)
	rig.run(5.0)
	assert_false(rig.sessions[1].state.seats[2].connected, "marked as gone")
	assert_false(rig.sessions[1].state.seats[2].ai, "not yet: the grace period")
	rig.run(float(rig.sessions[1].state.settings["grace"]) + 1.0)
	assert_true(rig.sessions[1].state.seats[2].ai, "the AI plays their hero now")
	var entries_before := rig.sessions[1].state.entry_count()
	rig.run(float(rig.sessions[1].state.settings["turn"]) + 5.0)  # A whole turn timer: the idle player's turn ends by itself at the latest.
	assert_true(rig.sessions[1].state.entry_count() > entries_before, "the game goes on without them")


func test_the_ai_can_finish_the_fight_when_the_players_hand_it_their_heroes() -> void:
	var rig := _rig(2, 1)
	for id in rig.sessions:
		rig.sessions[id].ai_delay = 0.0
	_go(rig)
	rig.sessions[1].hand_to_ai(true)
	rig.sessions[2].hand_to_ai(true)
	rig.net.flush()
	assert_true(rig.sessions[1].state.seats[1].ai and rig.sessions[1].state.seats[2].ai)
	for round_index in 1500:
		rig.run(0.5)
		if rig.sessions[1].state.is_over():
			break
	assert_true(rig.sessions[1].state.is_over(), "AI against AI reaches an ending (sudden death at the latest)")
	assert_true(rig.in_step())
	assert_eq(rig.sessions[2].state.battle.state.outcome(), rig.sessions[1].state.battle.state.outcome())


func test_a_player_takes_their_hero_back_from_the_ai_between_turns() -> void:
	var rig := _rig(2, 1)
	for id in rig.sessions:
		rig.sessions[id].ai_delay = 0.0
	_go(rig)
	rig.sessions[2].hand_to_ai(true)
	rig.net.flush()
	assert_true(rig.sessions[1].state.seats[2].ai)
	var asked := false
	for step in 400:
		rig.run(0.2)
		if rig.sessions[1].state.current_seat() != 2 and not asked:
			rig.sessions[2].hand_to_ai(false)
			asked = true
			rig.net.flush()
		if asked and not rig.sessions[1].state.seats[2].ai:
			break
	assert_false(rig.sessions[1].state.seats[2].ai, "it is theirs again")
	assert_true(rig.in_step())


func test_a_returning_player_gets_their_hero_back_at_a_safe_moment() -> void:
	var rig := _rig(2, 1)
	_go(rig)
	rig.net.kill(2)
	rig.run(float(rig.sessions[1].state.settings["grace"]) + 3.0)
	assert_true(rig.sessions[1].state.seats[2].ai)
	# Seat 2 comes back: a new browser, the same token and seat.
	rig.net.transport(2).closed = false
	rig.net.connect_peers(2, 1)
	rig.sessions[2] = MatchSession.open_as_guest(rig.net.transport(2), "Bob", NetRig.token_of(2), 1)
	rig.net.flush()
	assert_true(rig.sessions[2].is_synced, "caught up with the whole log")
	assert_eq(rig.sessions[2].state.entry_count(), rig.sessions[1].state.entry_count())
	assert_true(rig.sessions[1].state.seats[2].connected)
	for step in 600:
		rig.run(0.5)
		if not rig.sessions[1].state.seats[2].ai:
			break
	assert_false(rig.sessions[1].state.seats[2].ai, "their hero is theirs again")
	assert_true(rig.in_step())


func test_a_stranger_cannot_join_a_match_that_has_started() -> void:
	var rig := _rig(2, 1)
	var halts := []
	rig.net.connect_peers(9, 1)
	rig.net.connect_peers(9, 2)
	var stranger := MatchSession.open_as_guest(rig.net.transport(9), "Eve", "a-stranger-token", 1)
	stranger.halted.connect(func(why: String) -> void: halts.append(why))
	rig.net.flush()
	assert_false(rig.sessions[1].state.seats.has(9))
	assert_true(stranger.halted_now(), "refused")
	assert_true(rig.sessions[1].state.entry_count() == rig.sessions[2].state.entry_count())


func test_a_peer_that_drifted_is_caught_by_the_state_fingerprint() -> void:
	var rig := _rig(2, 1)
	_go(rig)
	rig.sessions[2].state.battle.state.units[0].hp -= 3  # Something went wrong on this peer only.
	var halts := []
	rig.sessions[2].halted.connect(func(why: String) -> void: halts.append(why))
	var seat := rig.sessions[1].state.current_seat()
	rig.sessions[seat].act(BattleActions.EndTurn.new(rig.sessions[1].unit_of(seat)))
	rig.net.flush()
	assert_eq(halts.size(), 1, "the drifted peer stopped")
	assert_true(rig.sessions[2].halt_reason.contains("desync") or rig.sessions[2].halt_reason.contains("differs"))
	assert_false(rig.sessions[1].halted_now(), "the host carries on")


func test_a_peer_that_goes_silent_is_dropped_by_the_host() -> void:
	var rig := NetRig.new()
	rig.host(1)
	rig.guest(2)
	rig.net.flush()
	# Peer 2 stays linked but stops answering (its tick never runs): it times out.
	var silent := rig.sessions[2]
	for step in 120:
		rig.sessions[1].tick(0.1)
		rig.net.flush()
	assert_true(silent != null)
	assert_false(rig.sessions[1].state.seats.has(2), "removed from the lobby after the silence")


func test_after_the_fight_everyone_goes_back_to_the_lobby_to_play_again() -> void:
	var rig := _rig(2, 1)
	_go(rig)
	rig.sessions[1].back_to_lobby()
	rig.net.flush()
	assert_eq(rig.sessions[1].state.phase, MatchState.Phase.BATTLE, "refused: the fight isn't over")
	# End the fight on every peer the way the rules would (the replicas stay equal).
	for id in rig.sessions:
		rig.sessions[id].state.battle.state.units[1].hp = 0
	rig.sessions[1].back_to_lobby()
	rig.net.flush()
	for id in rig.sessions:
		assert_eq(rig.sessions[id].state.phase, MatchState.Phase.LOBBY, "peer %d" % id)
		assert_eq(rig.sessions[id].state.seat_ids(), [1, 2] as Array[int], "the same players")
		assert_false(rig.sessions[id].state.seats[2].ready, "they must ready up again")
	rig.sessions[1].set_ready(true)
	rig.sessions[2].set_ready(true)
	rig.net.flush()
	rig.sessions[1].start_match()
	rig.net.flush()
	assert_true(rig.sessions[2].state.battle != null, "a second match")
	assert_true(rig.in_step())


func test_a_peer_that_is_not_the_host_cannot_push_entries() -> void:
	var rig := _rig(3, 1)
	var victim := rig.sessions[2]
	var before := victim.state.entry_count()
	var forged := {"k": "set", "id": 3, "f": "hero", "v": 2, "n": before + 1, "c": "x-1"}
	victim._on_message(3, {"m": "entry", "e": forged})  # Player 3 isn't the host.
	victim._on_message(3, {"m": "entries", "list": [forged]})  # Nor was it asked for entries.
	assert_eq(victim.state.entry_count(), before, "nothing was applied")
	assert_false(victim.halted_now())
	assert_true(rig.in_step())


func test_the_log_keeps_a_hash_of_a_players_token_not_the_token() -> void:
	var rig := _rig(2, 1)
	for id in [1, 2]:
		var seat := rig.sessions[1].state.seats[id]
		assert_eq(seat.token.length(), 64, "a SHA-256 hash")
		assert_ne(seat.token, NetRig.token_of(id), "not the secret")
		assert_true(rig.sessions[2].state.seat_for_token(NetRig.token_of(id)) != null, "the secret still finds the seat")
		assert_true(rig.sessions[2].state.seat_for_token(seat.token) == null, "the hash in the log is no key")
	for entry in rig.sessions[2].state.log:
		assert_false(str(entry).contains(NetRig.token_of(1)), "no secret in what every player holds")


func test_a_peer_that_stalled_and_wakes_up_gets_its_seat_back() -> void:
	var rig := NetRig.new()
	rig.host(1)
	rig.guest(2, "Bob")
	rig.net.flush()
	for step in 120:  # Bob's tab was paused: the host heard nothing for 12 s.
		rig.sessions[1].tick(0.1)
		rig.net.flush()
	assert_false(rig.sessions[1].state.seats.has(2), "removed while silent")
	rig.run(3.0)  # Bob's tab wakes up: its pings reach the host, which asks it to say hello again.
	assert_true(rig.sessions[1].state.seats.has(2) and rig.sessions[1].state.seats[2].connected, "back")
	assert_eq(rig.sessions[1].state.seats[2].name, "Bob")
	assert_true(rig.in_step())


func test_only_the_host_I_joined_through_can_refuse_me_and_only_before_I_am_in() -> void:
	var rig := NetRig.new()
	rig.host(1)
	rig.guest(2)
	rig.guest(3)
	rig.net.flush()
	rig.net.transport(3).broadcast({"m": "refused", "why": "forged"})
	rig.net.flush()
	assert_false(rig.sessions[1].halted_now() or rig.sessions[2].halted_now(), "a player can't send everyone away")
	rig.net.transport(1).send(2, {"m": "refused", "why": "late"})
	rig.net.flush()
	assert_false(rig.sessions[2].halted_now(), "and not once I am in")


func test_a_peer_cannot_make_itself_host_while_the_host_is_there() -> void:
	var rig := NetRig.new()
	rig.host(1)
	rig.guest(2)
	rig.guest(3)
	rig.net.flush()
	rig.net.transport(3).broadcast({"m": "elected", "host": 3, "have": 0})
	rig.net.flush()
	assert_eq(rig.sessions[1].host_id, 1)
	assert_eq(rig.sessions[2].host_id, 1, "nobody follows a host that nobody lost")
	assert_true(rig.in_step())


func test_a_proposal_carries_only_the_fields_of_its_kind() -> void:
	var rig := NetRig.new()
	rig.host(1)
	rig.guest(2)
	rig.guest(3)
	rig.net.flush()
	var padding := "x".repeat(5000)
	rig.sessions[2].propose({"k": "set", "id": 2, "f": "hero", "v": 1, "h": 12345, "pad": padding, "sys": true})
	rig.net.flush()
	var entry: Dictionary = rig.sessions[1].state.log[-1]
	assert_eq(rig.sessions[1].state.seats[2].hero, 1)
	assert_false(entry.has("h") or entry.has("pad") or entry.has("sys"), "only k, id, f, v, c and n")
	assert_true(rig.in_step(), "no desync from a made-up hash")
	assert_false(rig.sessions[3].halted_now())
	rig.sessions[2].propose({"k": "set", "id": 2, "f": "name", "v": padding})
	rig.net.flush()
	assert_eq(rig.sessions[1].state.seats[2].name.length() <= MatchState.MAX_NAME, true, "a long text is cut or refused")
	assert_true(rig.in_step())


func test_a_nonce_must_be_the_senders_and_a_flood_is_slowed_down() -> void:
	var rig := NetRig.new()
	rig.host(1)
	rig.guest(2)
	rig.guest(3)
	rig.net.flush()
	var refusals := []
	rig.sessions[3].rejected.connect(func(why: String) -> void: refusals.append(why))
	rig.net.transport(3).send(1, {"m": "submit", "p": {"k": "set", "id": 3, "f": "hero", "v": 2, "c": "2-1"}})  # Bob's nonce.
	rig.net.flush()
	assert_eq(rig.sessions[1].state.seats[3].hero, 0, "refused: not 3's nonce")
	for i in 60:
		rig.sessions[3].set_field("hero", i % 2)
	rig.net.flush()
	assert_true(refusals.size() >= 20, "most of a flood is refused (%d)" % refusals.size())
	assert_true(rig.in_step())
	rig.run(5.0)
	rig.sessions[3].set_field("hero", 2)
	rig.net.flush()
	assert_eq(rig.sessions[1].state.seats[3].hero, 2, "and a calm player is fine again")


func test_the_clock_gives_back_the_playback_once_and_only_to_the_turns_player() -> void:
	var rig := _rig(2, 1)
	_go(rig)
	var turn := float(rig.sessions[1].state.settings["turn"])
	var seat := rig.sessions[1].state.current_seat()
	var other := 2 if seat == 1 else 1
	var unit := rig.sessions[1].unit_of(seat)
	rig.run(4.0)
	rig.sessions[other].turn_shown(unit)  # Not their hero: nothing.
	rig.net.flush()
	assert_true(rig.sessions[1].turn_seconds_left() < turn - 3.0, "no time given back")
	rig.sessions[seat].turn_shown(unit)
	rig.net.flush()
	for id in [1, 2]:
		assert_true(rig.sessions[id].turn_seconds_left() > turn - 0.5, "the playback is given back, on every screen (%d)" % id)
	rig.run(15.0)
	rig.sessions[seat].turn_shown(unit)
	rig.net.flush()
	assert_true(rig.sessions[1].turn_seconds_left() < turn - 14.0, "once per turn")


func test_the_clock_gives_back_at_most_the_playback_credit() -> void:
	var rig := _rig(2, 1)
	_go(rig)
	var seat := rig.sessions[1].state.current_seat()
	rig.run(15.0)
	rig.sessions[seat].turn_shown(rig.sessions[1].unit_of(seat))
	rig.net.flush()
	var expected := float(rig.sessions[1].state.settings["turn"]) - (15.0 - MatchSession.PLAYBACK_CREDIT)
	assert_true(absf(rig.sessions[1].turn_seconds_left() - expected) < 0.5, "%f, %f" % [rig.sessions[1].turn_seconds_left(), expected])


func test_guests_count_the_turn_down_too() -> void:
	var rig := _rig(2, 1)
	_go(rig)
	rig.run(5.0)
	var host_left := rig.sessions[1].turn_seconds_left()
	var guest_left := rig.sessions[2].turn_seconds_left()
	assert_true(absf(host_left - guest_left) < 1.5, "about the same clock (%f, %f)" % [host_left, guest_left])
	assert_true(guest_left < float(rig.sessions[2].state.settings["turn"]) - 3.0, "it moves on the guest's screen")


func test_a_player_left_alone_is_told_the_others_are_gone() -> void:
	var rig := NetRig.new()
	rig.host(1)
	rig.guest(2)
	rig.net.flush()
	rig.net.transport(1).close()
	rig.run(1.0)
	assert_true(rig.sessions[2].connection_lost, "nobody else is connected")
	rig = NetRig.new()
	rig.host(1)
	rig.guest(2)
	rig.net.flush()
	assert_false(rig.sessions[2].connection_lost)


func test_the_fight_starts_when_the_placement_time_is_up() -> void:
	var rig := _rig(2, 1)
	rig.sessions[1].set_placed(true)  # Player 2 never presses Ready.
	rig.run(10.0)
	assert_false(_battle_started(rig), "still placing")
	assert_true(rig.sessions[2].placement_seconds_left() > 15.0 and rig.sessions[2].placement_seconds_left() < 21.0, "the guest sees the clock too")
	rig.run(MatchSession.PLACEMENT_SECONDS)
	assert_true(_battle_started(rig), "the host started it")
	assert_true(rig.sessions[2].state.battle.state.started)
	assert_eq(rig.sessions[1].placement_seconds_left(), -1.0)
	assert_true(rig.in_step())


func test_friendly_fire_is_a_lobby_rule_on_by_default_that_reaches_every_battle() -> void:
	assert_true(MatchState.new().settings["friendly_fire"], "a new match keeps friendly fire, as it always was")
	var on := NetRig.new()
	on.start_match(2, 1)
	assert_true(on.sessions[1].state.battle.state.friendly_fire and on.sessions[2].state.battle.state.friendly_fire)
	var off := NetRig.new()
	off.start_match(2, 1, false, false)
	assert_false(off.sessions[1].state.battle.state.friendly_fire, "the host's choice reached the battle")
	assert_false(off.sessions[2].state.battle.state.friendly_fire, "on every peer")
	assert_true(off.in_step())


func test_only_the_host_changes_friendly_fire_and_only_to_a_flag() -> void:
	var rig := NetRig.new()
	rig.host(1)
	rig.guest(2)
	rig.sessions[2].configure("friendly_fire", false)
	rig.net.flush()
	assert_true(rig.sessions[1].state.settings["friendly_fire"], "a guest's change is refused")
	assert_eq(rig.sessions[1].state.apply({"k": "cfg", "f": "friendly_fire", "v": "no"}), "bad flag")


func test_marks_reach_everyone_at_a_calm_pace_and_bad_ones_are_dropped() -> void:
	var rig := _rig(2, 1)
	var got: Array = []
	rig.sessions[1].mark_received.connect(func(seat: int, cell: Vector2i) -> void: got.append([seat, cell]))
	rig.sessions[2].send_mark(Vector2i(3, 4))
	rig.sessions[2].send_mark(Vector2i(3, 5))  # Too soon.
	rig.net.flush()
	assert_eq(got, [[2, Vector2i(3, 4)]])
	rig.run(MatchSession.MARK_COOLDOWN + 0.1)
	rig.sessions[2].send_mark(Vector2i(-1, 4))
	rig.net.flush()
	assert_eq(got.size(), 1, "off the board: dropped")

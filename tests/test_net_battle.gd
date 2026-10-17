extends TestCase
## The multiplayer fight on screen: it follows the match's log (placement, first turn, moves), turns
## the local player's clicks into proposals, and can open late and catch up.

const SCENE := preload("res://scenes/net/net_battle.tscn")


func _frames(count := 3) -> void:
	for i in count:
		await (Engine.get_main_loop() as SceneTree).process_frame


func _controller(rig: NetRig, seat: int) -> NetBattleController:
	var controller := SCENE.instantiate() as NetBattleController
	controller.setup_net(rig.sessions[seat])
	controller.settings.net_battle_speed = Settings.BattleSpeed.INSTANT
	(Engine.get_main_loop() as SceneTree).root.add_child(controller)
	return controller


func _fight(total := 2, per_side := 1) -> NetRig:
	var rig := NetRig.new()
	rig.start_match(total, per_side)
	return rig


func test_the_screen_opens_on_the_matchs_battle_in_placement() -> void:
	var rig := _fight()
	var controller := _controller(rig, 1)
	await _frames()
	assert_eq(controller.battle.state.units.size(), 2)
	assert_eq(controller.input_state, BattleController.State.PLACING)
	assert_eq(StateHash.of(controller.battle.state), StateHash.of(rig.sessions[1].state.battle.state), "the same battle as the session's")
	assert_true(controller.battle.state.pvp)
	assert_eq(controller._placement_zone(), controller.battle.state.zone, "side A places in its zone")
	var other := _controller(rig, 2)
	await _frames()
	assert_eq(other._placement_zone(), other.battle.state.zone_enemy, "side B in its own")
	controller.free()
	other.free()


func test_clicking_a_zone_cell_places_my_hero_through_the_host() -> void:
	var rig := _fight()
	var guest := _controller(rig, 2)
	await _frames()
	var cell: Vector2i = guest.battle.state.zone_enemy[4]
	guest.click_cell(cell)
	assert_eq(guest.input_state, BattleController.State.ANIMATING, "waiting for the host's answer")
	assert_ne(guest.battle.state.units[1].cell, cell, "nothing moves before the host says so")
	rig.net.flush()
	await _frames()
	assert_eq(guest.battle.state.units[1].cell, cell, "the placement came back and was applied")
	assert_eq(guest.input_state, BattleController.State.PLACING)
	assert_eq(rig.sessions[1].state.battle.state.units[1].cell, cell, "and the host has it too")
	guest.free()


func test_a_click_outside_my_zone_or_on_someone_elses_hero_does_nothing() -> void:
	var rig := _fight()
	var host := _controller(rig, 1)
	await _frames()
	var before := rig.sessions[1].state.entry_count()
	host.click_cell(host.battle.state.zone_enemy[0])
	host.click_cell(Vector2i(0, 0))
	await _frames()
	assert_eq(rig.sessions[1].state.entry_count(), before, "no proposal was made")
	host.free()


func test_ready_waits_for_the_others_then_the_fight_starts() -> void:
	var rig := _fight()
	var host := _controller(rig, 1)
	var guest := _controller(rig, 2)
	await _frames()
	host.end_turn()
	rig.net.flush()
	await _frames()
	assert_true(host._prompt_text().contains("Waiting") or host._prompt_text().contains("Ready"), "waiting for the others")
	assert_false(host.battle.state.started)
	guest.end_turn()
	rig.run(1.0)
	await _frames(5)
	assert_true(host.battle.state.started and guest.battle.state.started, "both views started the fight")
	var turn_unit := host.battle.state.current_unit().id
	var host_has_it := turn_unit == 0
	assert_eq(host.input_state, BattleController.State.IDLE if host_has_it else BattleController.State.ENEMY_TURN)
	assert_eq(guest.input_state, BattleController.State.ENEMY_TURN if host_has_it else BattleController.State.IDLE)
	host.free()
	guest.free()


func _both_ready(rig: NetRig, host: NetBattleController, guest: NetBattleController) -> void:
	host.end_turn()
	guest.end_turn()
	rig.run(1.0)
	await _frames(5)


func test_my_turn_ends_through_the_host_and_everyone_sees_the_next_turn() -> void:
	var rig := _fight()
	var host := _controller(rig, 1)
	var guest := _controller(rig, 2)
	await _frames()
	await _both_ready(rig, host, guest)
	var mine := host if host.battle.state.current_unit().id == 0 else guest
	var theirs := guest if mine == host else host
	var first_unit := mine.battle.state.current_unit().id
	mine.end_turn()
	rig.net.flush()
	await _frames(5)
	assert_ne(mine.battle.state.current_unit().id, first_unit, "the turn passed on my screen")
	assert_ne(theirs.battle.state.current_unit().id, first_unit, "and on theirs")
	assert_eq(StateHash.of(host.battle.state), StateHash.of(guest.battle.state), "the two views agree")
	assert_eq(StateHash.of(host.battle.state), StateHash.of(rig.sessions[1].state.battle.state), "and with the match")
	host.free()
	guest.free()


func test_my_turn_is_announced_to_me_once_and_the_others_see_whose_it_is() -> void:
	var rig := _fight()
	var host := _controller(rig, 1)
	var guest := _controller(rig, 2)
	var sounds: Dictionary[int, Array] = {1: [], 2: []}
	host.sound.connect(func(event: StringName) -> void: sounds[1].append(event))
	guest.sound.connect(func(event: StringName) -> void: sounds[2].append(event))
	await _frames()
	await _both_ready(rig, host, guest)
	var mine := host if host.battle.state.current_unit().id == 0 else guest
	var seat := 1 if mine == host else 2
	assert_eq(sounds[seat].count(&"your_turn"), 1, "my turn's sound")
	assert_eq(sounds[3 - seat].count(&"your_turn"), 0, "not theirs")
	assert_eq(mine._turn_banner_text(mine.battle.state.current_unit()), tr("Your turn!"))
	var other := host if mine == guest else guest
	assert_true(other._turn_banner_text(other.battle.state.current_unit()).ends_with("'s turn"), "the others read whose turn it is")
	mine._begin_next()  # As after an action: the turn goes on.
	assert_eq(sounds[seat].count(&"your_turn"), 1, "once per turn")
	rig.run(float(rig.sessions[1].state.settings["turn"]) - NetBattleController.TURN_WARNING_SECONDS - 0.5)
	await _frames()
	assert_eq(sounds[seat].count(&"turn_warning"), 1, "the last seconds start ticking")
	await _frames()
	assert_eq(sounds[seat].count(&"turn_warning"), 1, "once for that second")
	rig.run(1.0)
	await _frames()
	assert_eq(sounds[seat].count(&"turn_warning"), 2, "and again the next second")
	host.free()
	guest.free()


func test_a_view_opened_late_replays_the_log_and_shows_where_things_stand() -> void:
	var rig := _fight()
	for id in rig.sessions:
		rig.sessions[id].ai_delay = 0.0
	for id in rig.sessions:
		rig.sessions[id].set_placed(true)
	rig.run(0.5)
	rig.sessions[1].hand_to_ai(true)
	rig.sessions[2].hand_to_ai(true)
	rig.run(12.0)  # The AI plays a while.
	assert_true(rig.sessions[1].state.entry_count() > 12)
	var late := _controller(rig, 2)
	await _frames(5)
	assert_eq(StateHash.of(late.battle.state), StateHash.of(rig.sessions[2].state.battle.state), "caught up with everything")
	assert_true(late.battle.state.started)
	late.free()


func test_the_turn_order_tags_the_ai_and_the_ones_who_left() -> void:
	var rig := _fight(3, 1)
	var host := _controller(rig, 1)
	await _frames()
	rig.net.kill(3)
	rig.run(3.0)
	var unit_of_three := rig.sessions[1].unit_of(3)
	assert_true(host.battle.state.units[unit_of_three].label.contains("(away)"), "the one who left")
	rig.run(float(rig.sessions[1].state.settings["grace"]) + 1.0)
	assert_true(host.battle.state.units[unit_of_three].label.contains("(AI)"), "then the AI plays for them")
	host.free()


func test_there_is_one_turn_order_and_the_countdown_is_next_to_the_round() -> void:
	var rig := _fight()
	var host := _controller(rig, 1)
	var guest := _controller(rig, 2)
	await _frames()
	assert_true(host.find_child("NetStatusPanel", true, false) == null, "no second list of players")
	var round_label := host.hud.get_node("%RoundLabel") as Label
	assert_true(round_label.text.contains(" s"), "the placement countdown shows after the round")
	await _both_ready(rig, host, guest)
	rig.run(5.0)
	await _frames()
	var left := ceili(rig.sessions[1].turn_seconds_left())
	assert_true(round_label.text.ends_with("%d s" % left) or round_label.text.ends_with("%d s" % (left + 1)), "the turn's seconds: %s" % round_label.text)
	rig.run(float(rig.sessions[1].state.settings["turn"]) - 8.0)
	await _frames()
	assert_true(round_label.has_theme_color_override("font_color"), "red for the last ten seconds")
	host.free()
	guest.free()


func test_the_spell_bar_always_shows_my_own_hero_not_the_one_whose_turn_it_is() -> void:
	var rig := _fight()
	var host := _controller(rig, 1)
	var guest := _controller(rig, 2)
	await _frames()
	await _both_ready(rig, host, guest)
	var mine := host if host.battle.state.current_unit().id == 0 else guest
	var theirs := guest if mine == host else host
	assert_eq(theirs._spells_unit_id(), theirs._my_unit(), "the bar's unit is my own, on someone else's turn too")
	assert_ne(theirs._spells_unit_id(), theirs.battle.state.current_unit().id, "although it isn't the acting unit")
	mine.end_turn()
	rig.net.flush()
	await _frames(5)
	assert_eq(theirs._spells_unit_id(), theirs._my_unit(), "and still after the turn passed to me")
	assert_eq(mine._spells_unit_id(), mine._my_unit())
	host.free()
	guest.free()


func test_the_fight_plays_at_the_players_multiplayer_speed_and_leaves_the_solo_one_alone() -> void:
	var rig := _fight()
	var controller := SCENE.instantiate() as NetBattleController
	controller.setup_net(rig.sessions[1])
	controller.settings.battle_speed = Settings.BattleSpeed.INSTANT  # This player's solo setting.
	(Engine.get_main_loop() as SceneTree).root.add_child(controller)
	await _frames()
	assert_eq(controller.settings.net_battle_speed, Settings.BattleSpeed.FAST, "x2 by default")
	assert_false(controller.event_player.instant, "not the solo setting")
	assert_eq(Engine.time_scale, BattleController.FAST_TIME_SCALE)
	assert_true((controller.hud.get_node("%SpeedButton") as Control).visible, "a speed button")
	controller.cycle_battle_speed()
	assert_eq(controller.settings.net_battle_speed, Settings.BattleSpeed.INSTANT)
	assert_true(controller.event_player.instant)
	assert_eq(controller.settings.battle_speed, Settings.BattleSpeed.INSTANT, "the solo setting is as the player left it")
	controller.free()
	assert_eq(Engine.time_scale, 1.0, "time given back")


func test_a_quick_message_is_a_comic_bubble_with_a_tail() -> void:
	var rig := _fight()
	var host := _controller(rig, 1)
	await _frames()
	var unit_view := host.units_view.find_view(rig.sessions[1].unit_of(1))
	unit_view.say("Hello!")
	await _frames(2)
	var bubble := unit_view.get_node("Speech") as SpeechBubble
	assert_eq(bubble.text, "Hello!")
	var sprite := bubble.find_children("*", "Sprite3D", true, false)[0] as Sprite3D
	assert_true(sprite.texture != null and sprite.texture.get_size().x > 60.0, "a picture sized to its text")
	assert_true(bubble.find_children("*", "PanelContainer", true, false).size() == 1 and bubble.find_children("*", "Control", true, false).any(func(c: Control) -> bool: return c is SpeechBubble.Tail), "a rounded panel and a tail")
	host.free()


func test_in_card_combat_the_hand_is_shown_a_card_is_played_or_thrown_through_the_host_and_both_views_agree() -> void:
	var rig := NetRig.new()
	rig.start_match(2, 1, true)
	var host := _controller(rig, 1)
	var guest := _controller(rig, 2)
	await _frames()
	await _both_ready(rig, host, guest)
	assert_true(host.battle.state.cards and guest.battle.state.cards, "the lobby's card setting reached the battle")
	var mine := host if host.battle.state.current_unit().id == 0 else guest
	var theirs := guest if mine == host else host
	var unit := mine.battle.state.current_unit()
	var bar := mine.hud.get_node("%SpellBar") as SpellBar
	assert_true(bar.is_card_mode(), "the bar shows cards")
	assert_eq(bar.slot_count(), CardRules.HAND_SIZE, "a hand of four")
	for position in unit.hand.size():
		assert_eq(bar.slot(position).get_node("CardName").text, mine.tr(unit.data.spells[unit.hand[position]].display_name), "card %d is the hand's" % position)
	# Throw the first card away: it goes through the host, and both views drop it.
	var thrown := unit.hand[0]
	mine.discard_card(0)
	rig.net.flush()
	await _frames(4)
	assert_eq(theirs.battle.state.units[unit.id].hand.size(), CardRules.HAND_SIZE - 1, "the other view saw the card go")
	assert_eq(theirs.battle.state.units[unit.id].discard_pile, [thrown] as Array[int])
	assert_eq(bar.slot_count(), CardRules.HAND_SIZE - 1, "my hand shows three cards now")
	# Pick a card: it is aimed with its spell slot, whatever its place in the hand.
	mine.select_spell(0)
	assert_eq(mine.selected_spell, unit.hand[0])
	assert_eq(mine.selected_card, 0)
	mine.select_spell(0)
	assert_eq(mine.selected_card, -1, "picking it again lets go")
	assert_eq(StateHash.of(host.battle.state), StateHash.of(guest.battle.state), "the two views hold the same cards")
	assert_eq(StateHash.of(host.battle.state), StateHash.of(rig.sessions[1].state.battle.state))
	host.free()
	guest.free()


func test_a_quick_message_floats_above_the_players_hero_and_is_replaced_by_the_next() -> void:
	var rig := _fight()
	var host := _controller(rig, 1)
	var guest := _controller(rig, 2)
	await _frames()
	var bob_unit := rig.sessions[1].unit_of(2)
	rig.sessions[2].send_emote(1)
	rig.net.flush()
	assert_eq(host.units_view.find_view(bob_unit).speech_text(), Emotes.text(1), "above Bob's hero on Alice's screen")
	assert_eq(guest.units_view.find_view(bob_unit).speech_text(), Emotes.text(1), "and on Bob's own")
	assert_eq(host.units_view.find_view(rig.sessions[1].unit_of(1)).speech_text(), "", "not above anyone else")
	rig.run(MatchSession.EMOTE_COOLDOWN + 0.1)
	rig.sessions[2].send_emote(3)
	rig.net.flush()
	assert_eq(host.units_view.find_view(bob_unit).speech_text(), Emotes.text(3), "a new message replaces the old one")
	host.free()
	guest.free()


func test_quick_messages_are_a_popup_in_the_middle_opened_by_a_button_above_end_turn() -> void:
	var rig := _fight()
	var host := _controller(rig, 1)
	var guest := _controller(rig, 2)
	await _frames()
	var say := host.find_child("SayButton", true, false) as Button
	var end_turn := host.find_child("EndTurnButton", true, false) as Button
	assert_eq(say.get_parent(), end_turn.get_parent(), "in the same column")
	assert_eq(say.get_index() + 1, end_turn.get_index(), "right above End turn")
	var popup := host.find_child("SayPopup", true, false) as Control
	assert_false(popup.visible)
	say.pressed.emit()
	assert_true(popup.visible)
	var panel := popup.get_node("SayPanel") as Control
	var middle := panel.position + panel.size / 2.0
	assert_true(absf(middle.x - popup.size.x / 2.0) <= 1.0 and absf(middle.y - popup.size.y / 2.0) <= 1.0, "the list opens in the middle of the screen")
	for index in Emotes.count():
		assert_true(popup.find_child("Emote%d" % index, true, false) != null)
	(popup.find_child("Emote2", true, false) as Button).pressed.emit()
	rig.net.flush()
	assert_false(popup.visible, "it closes once a message is picked")
	var mine := rig.sessions[1].unit_of(1)
	assert_eq(guest.units_view.find_view(mine).speech_text(), Emotes.text(2), "and the other screen shows it above the hero")
	say.pressed.emit()
	say.pressed.emit()
	assert_false(popup.visible, "the button closes it again")
	say.pressed.emit()
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	popup.gui_input.emit(click)
	assert_false(popup.visible, "so does a click around it")
	host.free()
	guest.free()


func test_the_menu_is_a_button_in_the_top_bar_not_in_the_actions_column() -> void:
	var rig := _fight()
	var host := _controller(rig, 1)
	await _frames()
	assert_true(host.find_child("MenuButton", true, false) == null, "no Menu button in the column: it is the Game root's hamburger")
	host.open_menu()
	assert_true(host.hud.is_modal_open(), "the leave question opens")
	host.hud.close_leave_panel()
	host.free()


func test_a_hero_in_stealth_is_see_through_to_its_own_team_and_gone_for_the_other() -> void:
	var rig := _fight()
	var host := _controller(rig, 1)  # Side A: its hero is unit 0
	var guest := _controller(rig, 2)
	await _frames()
	var stealth := load("res://data/pvp/statuses/stealth.tres") as StatusData
	for controller in [host, guest]:
		controller.battle.state.units[0].add_status(stealth, 0)
		controller.units_view.refresh_visibility(controller.battle.state)
	var own_view := host.units_view.find_view(0)
	var enemy_view := guest.units_view.find_view(0)
	assert_true(own_view.visible and own_view.is_ghost(), "its own team sees it, see-through")
	assert_false(enemy_view.visible, "the other team doesn't see it at all")
	assert_false(enemy_view.is_ghost())
	assert_false(host.units_view.find_view(1).is_ghost(), "other heroes stay solid")
	var model := own_view.model()
	if model != null:
		assert_true(model.is_ghost())
		var mesh := model.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
		var material := (mesh.material_override if mesh.material_override != null else mesh.get_active_material(0)) as BaseMaterial3D
		assert_true(material != null and material.albedo_color.a < 0.6 and material.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED, "its surfaces are drawn with transparency")
	# Found (or the status ends): solid again, and visible to everyone.
	for controller in [host, guest]:
		controller.battle.state.units[0].break_stealth()
		controller.units_view.refresh_visibility(controller.battle.state)
	assert_false(own_view.is_ghost())
	assert_true(enemy_view.visible, "found")
	if model != null:
		var restored_mesh := model.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
		var restored := (restored_mesh.material_override if restored_mesh.material_override != null else restored_mesh.get_active_material(0)) as BaseMaterial3D
		assert_true(restored != null and restored.albedo_color.a >= 0.99 and restored.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED, "and its own materials are back")
	host.free()
	guest.free()


func test_a_player_who_comes_back_to_the_ai_played_hero_can_act_on_their_turn() -> void:
	var rig := _fight()
	for id in rig.sessions:
		rig.sessions[id].ai_delay = 0.0
	var host := _controller(rig, 1)
	var guest := _controller(rig, 2)
	await _frames()
	await _both_ready(rig, host, guest)
	guest.free()
	rig.net.kill(2)
	rig.run(float(rig.sessions[1].state.settings["grace"]) + 3.0)
	assert_true(rig.sessions[1].state.seats[2].ai)
	rig.net.transport(2).closed = false
	rig.net.connect_peers(2, 1)
	rig.sessions[2] = MatchSession.open_as_guest(rig.net.transport(2), "Bob", NetRig.token_of(2), 1)
	rig.net.flush()
	var back := _controller(rig, 2)
	await _frames()
	var acted := false
	for step in 400:
		rig.run(0.2)
		await _frames(2)
		var mine := rig.sessions[1].unit_of(2)
		if not rig.sessions[1].state.seats[2].ai and back.battle.state.current_unit().id == mine:
			assert_eq(back.input_state, BattleController.State.IDLE, "my turn: I can play")
			back.end_turn()
			rig.net.flush()
			await _frames(3)
			assert_ne(back.battle.state.current_unit().id, mine, "and pass it")
			acted = true
			break
	assert_true(acted, "my turn came back")
	host.free()
	back.free()


func test_a_mark_is_shown_to_the_marking_players_team_only_and_replaces_their_last_one() -> void:
	var rig := _fight(3, 2)  # Seats 1 and 2 on side A, seat 3 on side B.
	var host := _controller(rig, 1)
	var mate := _controller(rig, 2)
	var foe := _controller(rig, 3)
	await _frames()
	rig.sessions[2].send_mark(Vector2i(1, 1))
	rig.net.flush()
	await _frames()
	var marks := host.find_children("*", "BoardMark", false, false)
	assert_eq(marks.size(), 1, "my teammate's mark is on my board")
	assert_eq((marks[0] as BoardMark).text(), host.tr("%s: Here!") % rig.sessions[1].state.seats[2].name)
	assert_eq(mate.find_children("*", "BoardMark", false, false).size(), 1, "and on theirs")
	assert_eq(foe.find_children("*", "BoardMark", false, false).size(), 0, "never on the other team's")
	assert_eq(host.feed_texts()[-1], (marks[0] as BoardMark).text(), "and in the feed")
	assert_true(foe.feed_texts().is_empty())
	rig.run(MatchSession.MARK_COOLDOWN + 0.1)
	rig.sessions[2].send_mark(Vector2i(2, 1))
	rig.net.flush()
	await _frames()
	var left := host.find_children("*", "BoardMark", false, false).filter(func(m: Node) -> bool: return not m.is_queued_for_deletion())
	assert_eq(left.size(), 1, "a new mark replaces the player's last one")
	for mark in host.find_children("*", "BoardMark", false, false):
		mark.free()  # Faded out on its own.
	rig.run(MatchSession.MARK_COOLDOWN + 0.1)
	rig.sessions[2].send_mark(Vector2i(3, 1))
	rig.net.flush()
	await _frames()
	assert_eq(host.find_children("*", "BoardMark", false, false).size(), 1, "the next mark shows after the last one faded out")
	host.free()
	mate.free()
	foe.free()


## Real input, as a player does it: the mouse over a cell, then the Point out key.
func _press_mark_key(controller: NetBattleController, cell: Vector2i) -> void:
	var at := controller.camera_rig.camera.unproject_position(controller.board_view.cell_to_world(cell))
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	controller.get_viewport().push_input(motion)
	controller.get_viewport().warp_mouse(at)
	for pressed in [true, false]:
		var key := InputEventKey.new()
		key.physical_keycode = KEY_G
		key.keycode = KEY_G
		key.pressed = pressed
		controller.get_viewport().push_input(key)
		await _frames(1)


func test_the_point_out_key_marks_the_cell_under_the_mouse_at_once_and_again() -> void:
	var rig := _fight(3, 2)
	var host := _controller(rig, 1)
	await _frames()
	var foe := host.battle.state.units[rig.sessions[1].unit_of(3)]
	var sent: Array = []
	rig.sessions[1].mark_received.connect(func(seat: int, cell: Vector2i) -> void: sent.append([seat, cell]))
	await _press_mark_key(host, foe.cell)
	rig.net.flush()
	assert_eq(sent, [[1, foe.cell]], "no menu: the mark goes where the mouse is")
	rig.run(MatchSession.MARK_COOLDOWN + 0.1)
	await _press_mark_key(host, foe.cell)
	rig.net.flush()
	assert_eq(sent.size(), 2, "and again")
	host.free()


func test_the_point_out_button_makes_the_next_click_a_mark() -> void:
	var rig := _fight(3, 2)
	var host := _controller(rig, 1)
	await _frames()
	var foe := host.battle.state.units[rig.sessions[1].unit_of(3)]
	var point := host.find_child("PointButton", true, false) as Button
	var say := host.find_child("SayButton", true, false) as Button
	assert_eq(point.get_index() + 1, say.get_index(), "a button of its own, above Say something")
	assert_true(point.text.contains(SettingsApplier.key_text(&"mark")), "it shows the key too")
	point.button_pressed = true
	assert_true(host._prompt_text().contains("point it out"))
	host.cancel()
	assert_false(host._marking or point.button_pressed, "Esc lets go")
	point.button_pressed = true
	host.click_cell(foe.cell)
	rig.net.flush()
	assert_eq(host.find_children("*", "BoardMark", false, false).size(), 1, "the click marked the cell")
	assert_false(host._marking, "one click only")
	assert_false(point.button_pressed, "the button lets go")
	host.free()


func test_while_someone_else_plays_the_prompt_says_how_to_point_things_out() -> void:
	var rig := _fight()
	var host := _controller(rig, 1)
	var guest := _controller(rig, 2)
	await _frames()
	await _both_ready(rig, host, guest)
	var waiting := guest if host.battle.state.current_unit().id == 0 else host
	assert_eq(waiting.input_state, BattleController.State.ENEMY_TURN)
	assert_true(waiting._prompt_text().contains(SettingsApplier.key_text(&"mark")), waiting._prompt_text())
	host.free()
	guest.free()


func test_a_fallen_players_quick_message_goes_in_the_feed() -> void:
	var rig := _fight()
	var host := _controller(rig, 1)
	await _frames()
	var bob_unit := rig.sessions[1].unit_of(2)
	host.battle.state.units[bob_unit].hp = 0  # Bob's hero has fallen (on this screen).
	rig.sessions[2].send_emote(7)
	rig.net.flush()
	assert_eq(host.units_view.find_view(bob_unit).speech_text(), "", "no bubble over a fallen hero")
	assert_true(host.feed_texts()[-1].ends_with(Emotes.text(7)), "the feed says it")
	host.free()


func test_a_spirits_turn_and_action_are_told_to_everyone() -> void:
	var rig := _fight()
	var host := _controller(rig, 1)
	var guest := _controller(rig, 2)
	await _frames()
	var mine := host.battle.state.units[host._my_unit()]
	var theirs := host.battle.state.units[guest._my_unit()]
	assert_true(rig.sessions[1].state.settings["spirits"], "the lobby rule is on by default")
	assert_false(host.battle.state.spirit_kit.is_empty(), "and the battle has the spirits' spells")
	mine.spirit = true
	assert_eq(host._turn_banner_text(mine), host.tr("Your spirit's turn!"))
	assert_eq(guest._turn_banner_text(guest.battle.state.units[mine.id]), "Host's turn", "not a spirit on the other screen yet")
	var curse := PvpHeroes.spirit_kit()[0]
	host._event_seen(BattleEvents.SpellCast.new(mine.id, curse, theirs.cell, [theirs.cell] as Array[Vector2i], 1))
	assert_eq(host.feed_texts()[-1], host.tr("%s's spirit: %s on %s") % [mine.label, host.tr(curse.display_name), theirs.label])
	host.free()
	guest.free()

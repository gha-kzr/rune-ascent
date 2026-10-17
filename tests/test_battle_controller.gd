extends TestCase
## The battle scene end to end: turn loop, player commands, enemy turns, result, restart.
## Time runs fast; waits are bounded by frames and the runner's per-test timeout.

const BATTLE_SCENE := preload("res://scenes/battle/battle.tscn")
const TIME_SCALE := 30.0
const MAX_WAIT_FRAMES := 3000
## Looking for a quarter-second flash: a miss should fail the test, not run into its time limit.
const FLASH_WAIT_MSEC := 4000
## The flash tests run slower than real time, so a hitch on a busy machine can't skip it.
const FLASH_TIME_SCALE := 0.25


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


## The slice battle (the enemy Skeleton Archer acts first), or a small custom one; placement is skipped
## (Ready) unless `ready` is false.
func _controller(layout := "", players: Array[UnitData] = [], enemies: Array[UnitData] = [], ready := true) -> SoloBattleController:
	Engine.time_scale = TIME_SCALE
	var controller := BATTLE_SCENE.instantiate() as SoloBattleController
	controller.rng_seed = 7
	if not layout.is_empty():
		controller.encounter = BattleFixtures.encounter(layout, enemies)
		controller.players = players
	_tree().root.add_child(controller)
	if ready:
		controller.end_turn()
	return controller


func _fighter(unit_name: String, initiative: int, max_hp := 20, damage := 5) -> UnitData:
	var data := BattleFixtures.unit(unit_name, initiative, 3, 6, max_hp)
	data.spells = [BattleFixtures.damage_spell(3, 1, 1, damage)] as Array[SpellData]
	return data


func _wait_for(controller: SoloBattleController, wanted: Array) -> bool:
	for i in MAX_WAIT_FRAMES:
		if controller.input_state in wanted:
			return true
		await _tree().process_frame
	return false


func _assert_views_in_sync(controller: SoloBattleController) -> void:
	for unit in controller.battle.state.units:
		var view := controller.units_view.view(unit.id)
		assert_eq(view.visible, unit.is_alive(), "unit %d visibility" % unit.id)
		assert_eq(view.hp_text(), "%d/%d" % [unit.hp, unit.max_hp()], "unit %d HP" % unit.id)
		if unit.is_alive():
			assert_true(view.position.is_equal_approx(controller.board_view.cell_to_world(unit.cell)), "unit %d position" % unit.id)


func test_enemies_act_until_the_players_turn() -> void:
	var controller := _controller()
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]), "reaches the player's turn")
	var current := controller.battle.state.current_unit()
	assert_eq(current.team, UnitState.Team.PLAYER)
	assert_true(controller.board_view.highlighted_count(BoardView.Highlight.REACH) > 0, "reachable cells shown")
	assert_false((controller.hud.get_node("%EndTurnButton") as Button).disabled, "player controls enabled")
	_assert_views_in_sync(controller)


func test_camera_opens_facing_the_player_spawns() -> void:
	var controller := _controller()
	var rig := controller.camera_rig
	var camera_side := rig.camera.global_position - rig.global_position
	var players_side := controller.board_view.cell_to_world(Vector2i(0, 8)) - controller.board_view.center()
	assert_true(Vector2(camera_side.x, camera_side.z).dot(Vector2(players_side.x, players_side.z)) > 0.0,
			"the camera looks from the players' side")


func test_clicking_a_reachable_cell_moves_the_unit() -> void:
	var controller := _controller("0p 0 0 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller.click_cell(Vector2i(2, 0))
	assert_eq(controller.input_state, BattleController.State.ANIMATING)
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	var unit := controller.battle.state.units[0]
	assert_eq(unit.cell, Vector2i(2, 0))
	assert_eq(unit.mp, 1)
	_assert_views_in_sync(controller)


func test_clicks_outside_the_reach_do_nothing() -> void:
	var controller := _controller("0p 0 0 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller.click_cell(Vector2i(4, 0))  # 4 away with 3 MP.
	controller.click_cell(Vector2i(5, 0))  # The enemy's cell.
	assert_eq(controller.input_state, BattleController.State.IDLE)
	assert_eq(controller.battle.state.units[0].cell, Vector2i(0, 0))


func test_selecting_a_spell_shows_its_range_and_cancel_goes_back() -> void:
	var controller := _controller("0p 0 0 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller.select_spell(0)
	assert_eq(controller.input_state, BattleController.State.TARGETING)
	assert_eq(controller.board_view.highlighted_count(BoardView.Highlight.RANGE), 1, "melee: one cell")
	assert_eq(controller.board_view.highlighted_count(BoardView.Highlight.REACH), 0, "reach hidden while aiming")
	assert_eq(controller.board_view.highlighted_count(BoardView.Highlight.RANGE_BLOCKED), 0, "melee needs no sight")
	controller.cancel()
	assert_eq(controller.input_state, BattleController.State.IDLE)
	controller.select_spell(0)
	controller.select_spell(0)
	assert_eq(controller.input_state, BattleController.State.IDLE, "selecting it again unselects it")


func test_spells_without_enough_ap_cannot_be_selected() -> void:
	var controller := _controller("0p 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller.battle.state.units[0].ap = 2
	controller.select_spell(0)
	assert_eq(controller.input_state, BattleController.State.IDLE)


func test_casting_on_the_last_enemy_wins() -> void:
	var controller := _controller("0p 0e", [_fighter("P0", 200)], [_fighter("E0", 100, 4)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller.select_spell(0)
	controller.click_cell(Vector2i(1, 0))
	assert_true(await _wait_for(controller, [BattleController.State.ENDED]), "the battle ends")
	assert_true((controller.hud.get_node("%ResultPanel") as Control).visible)
	assert_eq((controller.hud.get_node("%ResultLabel") as Label).text, "Victory!")
	assert_true((controller.hud.get_node("%EndTurnButton") as Button).disabled)
	_assert_views_in_sync(controller)


func test_ending_the_turn_lets_the_enemy_act_and_can_lose() -> void:
	var controller := _controller("0p 0 0e", [_fighter("P0", 200, 5)], [_fighter("E0", 100, 20, 5)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller.end_turn()
	assert_true(await _wait_for(controller, [BattleController.State.ENDED]), "the enemy walks up and kills P0")
	assert_eq((controller.hud.get_node("%ResultLabel") as Label).text, "Defeat")
	_assert_views_in_sync(controller)


func test_input_is_ignored_outside_the_players_turn() -> void:
	var controller := _controller()
	assert_eq(controller.battle.state.current_unit().data.display_name, "Skeleton Archer", "an enemy acts first")
	controller.end_turn()
	controller.select_spell(0)
	controller.click_cell(Vector2i(1, 8))
	assert_true(controller.input_state in [BattleController.State.ANIMATING, BattleController.State.ENEMY_TURN])
	assert_eq(controller.battle.state.current_unit().data.display_name, "Skeleton Archer", "still its turn")


func test_restart_mid_animation_starts_a_clean_battle() -> void:
	var controller := _controller("0p 0 0 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller.click_cell(Vector2i(3, 0))
	await _tree().process_frame  # Mid-walk.
	var old_battle := controller.battle
	controller.restart()
	assert_ne(controller.battle, old_battle)
	assert_eq(controller.input_state, BattleController.State.PLACING, "a new battle opens on placement")
	controller.end_turn()
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]), "the new battle reaches the player's turn")
	assert_eq(controller.battle.state.units[0].cell, Vector2i(0, 0), "fresh positions")
	assert_false((controller.hud.get_node("%ResultPanel") as Control).visible)
	await _tree().create_timer(0.5).timeout  # Let any leftover coroutine of the old battle run.
	assert_eq(controller.battle.state.units[0].cell, Vector2i(0, 0), "the old battle's move never lands")
	assert_eq(controller.input_state, BattleController.State.IDLE)
	_assert_views_in_sync(controller)


func test_a_real_mouse_click_moves_the_unit() -> void:
	var controller := _controller("0p 0 0 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	await _tree().physics_frame
	await _tree().physics_frame
	var target := controller.board_view.to_global(controller.board_view.cell_to_world(Vector2i(2, 0)))
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = controller.camera_rig.camera.unproject_position(target)
	controller.get_viewport().push_input(click)
	assert_eq(controller.input_state, BattleController.State.IDLE, "a press alone does nothing: the click acts on release")
	var release := click.duplicate() as InputEventMouseButton
	release.pressed = false
	controller.get_viewport().push_input(release)
	assert_true(await _wait_for(controller, [BattleController.State.ANIMATING]), "the click started a move")
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	assert_eq(controller.battle.state.units[0].cell, Vector2i(2, 0))


## Waits until a cast is playing with its spell area lit (from the cast's start through its flash),
## polled per frame (no timing guesses).
func _wait_for_area_flash(controller: SoloBattleController, _caster_id: int) -> bool:
	var deadline := Time.get_ticks_msec() + FLASH_WAIT_MSEC
	while Time.get_ticks_msec() < deadline:
		# The area is lit from the cast's start through its flash; polled per frame at a slowed
		# clock, so a stalled frame on a busy machine can't skip the whole window.
		if controller.event_player.is_playing and controller.board_view.highlighted_count(BoardView.Highlight.AREA) > 0:
			return true
		await _tree().process_frame
	return false


func test_restart_during_a_cast_does_not_replay_old_events_on_the_new_battle() -> void:
	var controller := _controller("0p 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	Engine.time_scale = FLASH_TIME_SCALE  # A flash lasts a few frames at most at high speed.
	controller.select_spell(0)
	controller.click_cell(Vector2i(1, 0))
	assert_true(await _wait_for_area_flash(controller, 0), "inside the area flash")
	controller.restart()
	controller.end_turn()
	Engine.time_scale = TIME_SCALE
	for i in 60:
		await _tree().process_frame  # Let the old playback's flash end and resume.
	assert_eq(controller.units_view.view(1).hp_text(), "20/20", "the old hit never lands on the new enemy")
	assert_eq(controller.input_state, BattleController.State.IDLE)
	_assert_views_in_sync(controller)


func test_moving_the_mouse_during_a_cast_keeps_its_area_flash() -> void:
	var controller := _controller("0p 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	Engine.time_scale = FLASH_TIME_SCALE
	controller.select_spell(0)
	controller.click_cell(Vector2i(1, 0))
	assert_true(await _wait_for_area_flash(controller, 0), "inside the area flash")
	controller._hovered_cell = Vector2i(0, 0)  # What _physics_process does when the mouse moves.
	controller._update_hover()
	assert_eq(controller.board_view.highlighted_count(BoardView.Highlight.AREA), 1, "the flash stays")


func test_hover_shows_the_path_while_moving_and_the_area_while_aiming() -> void:
	var controller := _controller("0p 0 0 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller._hovered_cell = Vector2i(3, 0)
	controller._update_hover()
	assert_eq(controller.board_view.highlighted_count(BoardView.Highlight.PATH), 3, "path of 3 steps")
	controller._hovered_cell = Vector2i(5, 0)  # Out of reach.
	controller._update_hover()
	assert_eq(controller.board_view.highlighted_count(BoardView.Highlight.PATH), 0)
	controller.select_spell(0)
	controller._hovered_cell = Vector2i(1, 0)
	controller._update_hover()
	assert_eq(controller.board_view.highlighted_count(BoardView.Highlight.AREA), 1, "single-cell area")
	assert_eq(controller.board_view.highlighted_count(BoardView.Highlight.PATH), 0, "no path while aiming")


func test_a_mutual_wipe_is_shown_as_a_defeat() -> void:
	# The caster's circle hits both itself and the last enemy: a DRAW in the rules.
	var nova := BattleFixtures.damage_spell(3, 0, 1, 10, AreaShape.Kind.CIRCLE, 1)
	var caster := BattleFixtures.unit("P0", 200, 3, 6, 5)
	caster.spells = [nova] as Array[SpellData]
	var controller := _controller("0p 0e", [caster], [_fighter("E0", 100, 5)])
	controller.battle.state.friendly_fire = true
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller.select_spell(0)
	controller.click_cell(Vector2i(0, 0))
	assert_true(await _wait_for(controller, [BattleController.State.ENDED]))
	assert_eq(controller.battle.state.outcome(), BattleState.Outcome.DRAW)
	assert_eq((controller.hud.get_node("%ResultLabel") as Label).text, "Defeat")


func test_play_again_starts_a_new_battle_and_the_seed_is_shown() -> void:
	var controller := _controller("0p 0e", [_fighter("P0", 200)], [_fighter("E0", 100, 4)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller.select_spell(0)
	controller.click_cell(Vector2i(1, 0))
	assert_true(await _wait_for(controller, [BattleController.State.ENDED]))
	assert_eq((controller.hud.get_node("%SeedLabel") as Label).text, "Battle seed 7")
	var old_battle := controller.battle
	(controller.hud.get_node("%RestartButton") as Button).pressed.emit()
	assert_ne(controller.battle, old_battle)
	assert_false((controller.hud.get_node("%ResultPanel") as Control).visible)
	controller.end_turn()
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))


func test_a_failed_restart_keeps_the_current_battle() -> void:
	var controller := _controller("0p 0 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	var old_battle := controller.battle
	Engine.time_scale = 1.0  # A slow walk, to restart in the middle of it.
	controller.click_cell(Vector2i(3, 0))
	await _tree().process_frame
	assert_eq(controller.input_state, BattleController.State.ANIMATING, "mid-walk")
	controller.encounter = null
	expect_error("no encounter or map set")
	controller.restart()
	assert_eq(controller.battle, old_battle)
	Engine.time_scale = TIME_SCALE
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]), "the walk finishes, still playable")
	assert_eq(controller.battle.state.units[0].cell, Vector2i(3, 0))


func test_escape_stops_aiming() -> void:
	var controller := _controller("0p 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller.select_spell(0)
	var escape := InputEventKey.new()
	escape.physical_keycode = KEY_ESCAPE
	escape.pressed = true
	controller.get_viewport().push_input(escape)
	assert_eq(controller.input_state, BattleController.State.IDLE)


func test_the_active_unit_is_marked() -> void:
	var controller := _controller("0p 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	assert_true(controller.units_view.view(0).is_active(), "P0's turn")
	assert_false(controller.units_view.view(1).is_active())
	controller.end_turn()
	assert_true(await _wait_for(controller, [BattleController.State.ENEMY_TURN]))
	assert_true(controller.units_view.view(1).is_active(), "E0's turn")
	assert_false(controller.units_view.view(0).is_active())


func test_the_spell_bar_is_empty_during_the_enemys_turn() -> void:
	var controller := _controller("0p 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	var bar := controller.hud.get_node("%SpellBar") as SpellBar
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	assert_true(bar.slot_count() > 0, "P0's spells on its own turn")
	controller.end_turn()
	assert_true(await _wait_for(controller, [BattleController.State.ENEMY_TURN]))
	assert_eq(bar.slot_count(), 0, "not E0's spells")
	assert_true(await _wait_for(controller, [BattleController.State.IDLE, BattleController.State.ENDED]))
	assert_true(bar.slot_count() > 0, "P0's again on its next turn")


func test_aiming_shows_cells_hidden_from_sight_faded() -> void:
	var bolt := BattleFixtures.damage_spell(3, 1, 4, 5, AreaShape.Kind.SINGLE, 0, true)
	var caster := BattleFixtures.unit("P0", 200)
	caster.spells = [bolt] as Array[SpellData]
	var controller := _controller("0p 0 # 0 0e", [caster], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller.select_spell(0)
	assert_eq(controller.board_view.highlighted_count(BoardView.Highlight.RANGE), 1)
	assert_eq(controller.board_view.highlighted_count(BoardView.Highlight.RANGE_BLOCKED), 2)
	controller.click_cell(Vector2i(4, 0))
	assert_eq(controller.input_state, BattleController.State.TARGETING, "a blocked cell can't be aimed at, and keeps the aim")


func test_a_click_out_of_the_aimed_spells_range_stops_aiming() -> void:
	var controller := _controller("0p 0 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller.select_spell(0)
	assert_eq(controller.input_state, BattleController.State.TARGETING)
	controller.click_cell(Vector2i(3, 0))
	assert_eq(controller.input_state, BattleController.State.IDLE, "out of range: like Esc")
	assert_eq(controller.selected_spell, -1)


func test_hovering_a_spell_shows_its_range_from_its_caster() -> void:
	var bolt := BattleFixtures.damage_spell(3, 1, 4, 5, AreaShape.Kind.SINGLE, 0, true)
	var caster := BattleFixtures.unit("P0", 200)
	caster.spells = [bolt] as Array[SpellData]
	var enemy := _fighter("E0", 100)
	var controller := _controller("0p 0 # 0 0e", [caster], [enemy])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	var board := controller.board_view
	var reach := board.highlighted_count(BoardView.Highlight.REACH)
	assert_true(reach > 0, "the move zone is up")
	controller.hud.spell_hovered.emit(bolt, true)
	assert_eq(board.highlighted_count(BoardView.Highlight.RANGE), 1, "in sight")
	assert_eq(board.highlighted_count(BoardView.Highlight.RANGE_BLOCKED), 2, "behind the rock")
	assert_eq(board.highlighted_count(BoardView.Highlight.REACH), 0, "the move zone steps aside")
	controller.hud.spell_hovered.emit(null, false)
	assert_eq(board.highlighted_count(BoardView.Highlight.RANGE), 0)
	assert_eq(board.highlighted_count(BoardView.Highlight.RANGE_BLOCKED), 0)
	assert_eq(board.highlighted_count(BoardView.Highlight.REACH), reach, "and comes back")
	# A spell on the inspected enemy's card: its range, from the enemy.
	controller._hovered_cell = Vector2i(4, 0)
	controller._update_hover()
	controller.hud.spell_hovered.emit(enemy.spells[0], false)
	assert_eq(board.highlighted_count(BoardView.Highlight.RANGE), 1, "the cell next to the enemy")


func test_hovering_another_unit_inspects_it() -> void:
	var controller := _controller("0p 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	var panel := controller.hud.get_node("%InspectCard") as Control
	controller._hovered_cell = Vector2i(3, 0)
	controller._update_hover()
	assert_true(panel.visible, "the enemy is shown")
	controller._hovered_cell = Vector2i(0, 0)
	controller._update_hover()
	assert_false(panel.visible, "not the unit that's acting")
	controller._hovered_cell = Vector2i(1, 0)
	controller._update_hover()
	assert_false(panel.visible, "empty cell")


func test_the_hud_never_runs_ahead_of_the_animations() -> void:
	# P0 ends its turn; E0 dies to its poison at its turn start; E1 plays next.
	var controller := _controller("0p 0 0e 0e", [_fighter("P0", 200)], [_fighter("E0", 100, 2), _fighter("E1", 90)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller.battle.state.units[1].add_status(BattleFixtures.status("Poison", 2, 3), 0)
	var panel_after_first_event := {}
	controller.event_player.event_played.connect(func(event: BattleEvents.Event) -> void:
		if panel_after_first_event.is_empty():
			panel_after_first_event["name"] = (controller.hud.get_node("%ActiveCard/Rows/Header/NameLabel") as Label).text)
	controller.end_turn()
	assert_true(await _wait_for(controller, [BattleController.State.ENEMY_TURN, BattleController.State.IDLE]))
	assert_eq(panel_after_first_event.get("name"), "P0", "still P0 while its turn end plays")
	assert_eq((controller.hud.get_node("%ActiveCard/Rows/Header/NameLabel") as Label).text, "E1 Lv 1", "E1 once the playback is over")
	var chips := controller.hud.get_node("%TurnTimeline/Chips").get_child_count()
	assert_eq(chips, 2, "E0 left the turn order")
	controller._hovered_cell = Vector2i(3, 0)
	controller._update_hover()
	assert_false((controller.hud.get_node("%InspectCard") as Control).visible, "E1 is acting, no inspect")


func test_the_inspect_panel_stays_while_the_mouse_is_on_it() -> void:
	var controller := _controller("0p 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller._hovered_cell = Vector2i(3, 0)
	controller._update_hover()
	var panel := controller.hud.get_node("%InspectCard") as Control
	var inside := controller.hud.get_node("%InspectCard/Rows/Header") as Control
	assert_eq(controller._hover_cell(inside, Vector2.ZERO), Vector2i(3, 0), "sticks over the panel")
	assert_eq(controller._hover_cell(controller.hud.get_node("%EndTurnButton"), Vector2.ZERO), BoardView.NO_CELL,
			"other HUD controls clear the hover")
	assert_true(panel.visible)


func test_a_battle_opens_on_placement_and_ready_starts_it() -> void:
	var controller := _controller("0p 0p 0p 0p\n0  0  0  0\n0  0  0  0\n0  0  0  0\n0  0  0e 0",
			[_fighter("A", 200), _fighter("B", 190)] as Array[UnitData], [_fighter("E", 100)] as Array[UnitData], false)
	assert_eq(controller.input_state, BattleController.State.PLACING)
	assert_false(controller.battle.state.started)
	assert_eq(controller.board_view.highlighted_count(BoardView.Highlight.ZONE), 4, "the zone is shown")
	var end_turn := controller.hud.get_node("%EndTurnButton") as Button
	assert_eq(end_turn.text, "Ready (Space)")
	assert_false(end_turn.disabled)
	var a := controller.battle.state.units[0]
	var b := controller.battle.state.units[1]
	assert_eq((controller.hud.get_node("%ActiveCard/Rows/Header/NameLabel") as Label).text, "A", "the first hero, not the first to act")
	controller.click_cell(b.cell)
	assert_eq((controller.hud.get_node("%ActiveCard/Rows/Header/NameLabel") as Label).text, "B", "the selected hero")
	controller.cancel()
	controller.click_cell(a.cell)  # Select A...
	controller.click_cell(Vector2i(3, 0))  # ...and place it.
	assert_true(await _wait_for(controller, [BattleController.State.PLACING]))
	assert_eq(a.cell, Vector2i(3, 0))
	await _tree().process_frame
	_assert_views_in_sync(controller)
	controller.click_cell(Vector2i(1, 2))  # Outside the zone, nothing selected: ignored.
	assert_eq(controller.input_state, BattleController.State.PLACING)
	end_turn.pressed.emit()
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]), "the fight starts")
	assert_true(controller.battle.state.started)
	assert_eq(end_turn.text, "End turn (Space)")
	assert_eq(controller.board_view.highlighted_count(BoardView.Highlight.ZONE), 0)


func test_placement_swaps_heroes_and_cancel_deselects() -> void:
	var controller := _controller("0p 0p 0p\n0  0  0\n0  0  0\n0  0  0\n0  0e 0",
			[_fighter("A", 200), _fighter("B", 190)] as Array[UnitData], [_fighter("E", 100)] as Array[UnitData], false)
	var a := controller.battle.state.units[0]
	var b := controller.battle.state.units[1]
	var a_cell := a.cell
	var b_cell := b.cell
	controller.click_cell(a_cell)
	controller.cancel()
	controller.click_cell(b_cell)  # Nothing selected any more: selects B, moves nothing.
	assert_eq([a.cell, b.cell], [a_cell, b_cell])
	controller.click_cell(b_cell)  # B again: deselects.
	controller.click_cell(a_cell)  # Selects A...
	controller.click_cell(b_cell)  # ...then B's cell: they swap.
	assert_true(await _wait_for(controller, [BattleController.State.PLACING]))
	assert_eq([a.cell, b.cell], [b_cell, a_cell], "swapped")


func _inspect_card(controller: SoloBattleController) -> Control:
	return controller.hud.get_node("%InspectCard") as Control


func test_clicking_a_unit_pins_its_card_until_the_close_button_or_esc() -> void:
	var controller := _controller("0p 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	var card := _inspect_card(controller)
	controller.click_cell(Vector2i(3, 0))
	assert_true(card.visible, "pinned")
	assert_true((card.get_node("Rows/Header/CloseButton") as Button).visible, "with its ✕")
	controller._hovered_cell = Vector2i(0, 0)  # The mouse leaves the unit (and rests on the active one).
	controller._update_hover()
	assert_true(card.visible, "it stays")
	controller.click_cell(Vector2i(3, 0))
	assert_true(card.visible, "clicking the pinned unit again does nothing")
	(card.get_node("Rows/Header/CloseButton") as Button).pressed.emit()
	assert_false(card.visible, "✕ unpins")
	controller.click_cell(Vector2i(3, 0))
	assert_true(card.visible)
	controller.cancel()
	assert_false(card.visible, "Esc unpins")


func test_esc_stops_aiming_before_it_unpins() -> void:
	var controller := _controller("0p 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller.click_cell(Vector2i(3, 0))
	controller.select_spell(0)
	controller.cancel()
	assert_eq(controller.input_state, BattleController.State.IDLE, "aim stopped")
	assert_true(_inspect_card(controller).visible, "still pinned")
	controller.cancel()
	assert_false(_inspect_card(controller).visible)


func test_a_click_that_casts_does_not_pin_but_one_that_does_nothing_else_does() -> void:
	var controller := _controller("0p 0e 0e 0", [_fighter("P0", 200)], [_fighter("E0", 100), _fighter("E1", 90)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	var name_path := "Rows/Header/NameLabel"
	controller.click_cell(Vector2i(2, 0))
	assert_eq((_inspect_card(controller).get_node(name_path) as Label).text, "E1 Lv 1")
	controller.select_spell(0)
	var hp_before := controller.battle.state.units[1].hp
	controller.click_cell(Vector2i(1, 0))
	assert_eq((_inspect_card(controller).get_node(name_path) as Label).text, "E1 Lv 1", "casting on E0 left the pin on E1")
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	assert_true(controller.battle.state.units[1].hp < hp_before, "the click cast the spell")
	controller.click_cell(Vector2i(1, 0))
	assert_eq((_inspect_card(controller).get_node(name_path) as Label).text, "E0 Lv 1", "with no spell aimed the click only looks: it pins")


func test_a_pinned_unit_that_dies_unpins() -> void:
	var controller := _controller("0p 0 0e", [_fighter("P0", 200)], [_fighter("E0", 1)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller.click_cell(Vector2i(2, 0))
	assert_true(_inspect_card(controller).visible)
	controller._hud_model.apply(BattleEvents.UnitDied.new(1))
	controller._update_inspected()
	assert_false(_inspect_card(controller).visible, "a fallen unit's card goes away")


func test_heroes_levels_show_in_the_cards() -> void:
	var controller := _controller("0p 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller.player_levels = [7]
	controller._refresh_hud()
	assert_eq((controller.hud.get_node("%ActiveCard/Rows/Header/NameLabel") as Label).text, "P0 · Lv 7")


func test_a_turn_order_chip_hovers_its_unit_and_a_click_focuses_the_camera() -> void:
	var controller := _controller("0p 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller.hud.chip_hovered.emit(1)
	assert_eq(controller._hover_cell(controller.hud.get_node("%TurnTimeline"), Vector2.ZERO), Vector2i(3, 0), "the unit's cell counts as hovered")
	controller.hud.chip_unhovered.emit()
	assert_eq(controller._hover_cell(controller.hud.get_node("%TurnTimeline"), Vector2.ZERO), BoardView.NO_CELL)
	controller.hud.chip_pressed.emit(1)
	var goal := controller.board_view.cell_to_world(Vector2i(3, 0))
	for i in MAX_WAIT_FRAMES:
		if controller.camera_rig.position.is_equal_approx(goal):
			break
		await _tree().process_frame
	assert_true(controller.camera_rig.position.is_equal_approx(goal), "the camera slid to the unit")


func test_esc_closes_the_order_overlay_first() -> void:
	var controller := _controller("0p 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller.click_cell(Vector2i(3, 0))
	(controller.hud.get_node("%TurnTimeline/OrderButton") as Button).pressed.emit()
	var overlay := controller.hud.get_node("%OrderOverlay") as Control
	assert_true(overlay.visible)
	controller.cancel()
	assert_false(overlay.visible)
	assert_true(_inspect_card(controller).visible, "the pin waits for the next Esc")


func test_aiming_at_a_unit_previews_its_damage_and_leaving_clears_it() -> void:
	var controller := _controller("0p 0e 0 0", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	var enemy_view := controller.units_view.view(1)
	controller._hovered_cell = Vector2i(1, 0)
	controller._update_hover()
	assert_false(enemy_view.has_preview(), "not aiming: no preview")
	controller.select_spell(0)
	controller._hovered_cell = Vector2i(1, 0)
	controller._update_hover()
	assert_true(enemy_view.has_preview(), "aiming at the enemy")
	assert_eq(enemy_view.preview_text(), "5", "the fighter's 5 damage")
	controller._hovered_cell = Vector2i(2, 0)
	controller._update_hover()
	assert_false(enemy_view.has_preview(), "the mouse moved off")
	controller._hovered_cell = Vector2i(1, 0)
	controller._update_hover()
	controller.cancel()
	assert_false(enemy_view.has_preview(), "aiming stopped")


func test_hovering_a_reachable_cell_labels_the_path_cost_with_its_climbs() -> void:
	var controller := _controller("0p 1 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller._hovered_cell = Vector2i(2, 0)
	controller._update_hover()
	assert_eq(controller.board_view.path_cost_texts(), ["3 MP", "+1"] as Array[String], "2 steps + 1 climb")
	controller._hovered_cell = Vector2i(3, 0)  # The enemy's cell: not reachable.
	controller._update_hover()
	assert_eq(controller.board_view.path_cost_texts().size(), 0)
	controller._hovered_cell = Vector2i(2, 0)
	controller._update_hover()
	controller.select_spell(0)
	assert_eq(controller.board_view.path_cost_texts().size(), 0, "aiming clears it")


func test_the_prompt_line_follows_the_step() -> void:
	var controller := _controller("0p 0p 0 0e", [_fighter("A", 200), _fighter("B", 190)] as Array[UnitData],
			[_fighter("E", 100)] as Array[UnitData], false)
	var prompt := controller.hud.get_node("%PromptLabel") as Label
	assert_true(prompt.visible)
	assert_true(prompt.text.begins_with("Place your heroes"), prompt.text)
	controller.click_cell(controller.battle.state.units[0].cell)
	assert_true(prompt.text.contains("place A"), prompt.text)
	controller.cancel()
	controller.end_turn()
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	assert_true(prompt.text.begins_with("Move to a blue cell"), prompt.text)
	controller.select_spell(0)
	assert_true(prompt.text.contains("Choose a target for Hit"), prompt.text)
	controller.cancel()
	controller.end_turn()
	assert_true(await _wait_for(controller, [BattleController.State.ENEMY_TURN, BattleController.State.IDLE]))
	if controller.input_state == BattleController.State.ENEMY_TURN:
		assert_true(prompt.text.ends_with("is acting..."), prompt.text)


func test_end_turn_pulses_only_when_nothing_is_left_to_do() -> void:
	var boxed := _fighter("P0", 200)
	boxed.mp = 0
	boxed.ap = 2  # The 3 AP spell is out of reach.
	var controller := _controller("0p 0 0 0e", [boxed], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	assert_true(controller.hud.is_end_turn_pulsing(), "no MP, no affordable spell")
	assert_true((controller.hud.get_node("%PromptLabel") as Label).text.begins_with("Nothing left"))
	var normal := _controller("0p 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(normal, [BattleController.State.IDLE]))
	assert_false(normal.hud.is_end_turn_pulsing(), "it can still move")


func test_right_click_over_the_hud_stops_aiming() -> void:
	var controller := _controller("0p 0e 0 0", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller.select_spell(0)
	assert_eq(controller.input_state, BattleController.State.TARGETING)
	var right := InputEventMouseButton.new()
	right.button_index = MOUSE_BUTTON_RIGHT
	right.pressed = true
	right.position = controller.hud.get_node("%EndTurnButton").get_global_rect().get_center()
	controller.get_viewport().push_input(right)
	assert_eq(controller.input_state, BattleController.State.IDLE, "the HUD didn't swallow the cancel")


func test_prompts_show_the_keys_the_player_bound() -> void:
	var settings := Settings.new()
	SettingsApplier.set_binding(settings, &"end_turn", KEY_J)
	SettingsApplier.set_binding(settings, &"spell_1", KEY_Z)
	var controller := _controller("0p 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)], false)
	assert_true(controller._prompt_text().contains("Ready (J)"), controller._prompt_text())
	controller.end_turn()
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	assert_true(controller._prompt_text().ends_with("(Z)"), "one spell: its key only: %s" % controller._prompt_text())
	assert_eq(controller._spell_keys_text(3), "Z-3")
	SettingsApplier.reset_bindings(Settings.new())


func test_the_menu_asks_to_leave_and_esc_closes_the_question_first() -> void:
	var controller := _controller("0p 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller.standalone = false
	var left := {"count": 0}
	controller.left_battle.connect(func() -> void: left.count += 1)
	controller.open_menu()
	controller.select_spell(0)
	controller.cancel()
	assert_false((controller.hud.get_node("%LeavePanel") as Control).visible, "Esc closes the question")
	assert_eq(left.count, 0, "and leaves nothing")
	controller.open_menu()
	(controller.hud.get_node("%LeaveButton") as Button).pressed.emit()
	assert_eq(left.count, 1)


func _mouse(controller: SoloBattleController, pressed: bool, at: Vector2) -> void:
	var button := InputEventMouseButton.new()
	button.button_index = MOUSE_BUTTON_LEFT
	button.pressed = pressed
	button.position = at
	button.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	controller.get_viewport().push_input(button)


func test_a_left_drag_pans_the_camera_and_does_not_click_the_board() -> void:
	var controller := _controller("0p 0 0 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	await _tree().physics_frame
	await _tree().physics_frame
	controller.camera_rig.bounds = Rect2()  # No limit for this test.
	var start := controller.camera_rig.camera.unproject_position(
			controller.board_view.to_global(controller.board_view.cell_to_world(Vector2i(2, 0))))
	var focus_before := controller.camera_rig.position
	_mouse(controller, true, start)
	var motion := InputEventMouseMotion.new()
	motion.position = start + Vector2(60, 0)
	motion.relative = Vector2(60, 0)
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	controller.get_viewport().push_input(motion)
	_mouse(controller, false, start + Vector2(60, 0))
	assert_true(controller.camera_rig.dragged)
	assert_ne(controller.camera_rig.position, focus_before, "the board was grabbed")
	assert_eq(controller.input_state, BattleController.State.IDLE, "the release of a drag clicks nothing")
	assert_eq(controller.battle.state.units[0].cell, Vector2i(0, 0))


func test_a_release_without_a_board_press_clicks_nothing() -> void:
	var controller := _controller("0p 0 0 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	await _tree().physics_frame
	await _tree().physics_frame
	var target := controller.camera_rig.camera.unproject_position(
			controller.board_view.to_global(controller.board_view.cell_to_world(Vector2i(2, 0))))
	_mouse(controller, false, target)  # E.g. a press that started on a HUD button.
	assert_eq(controller.input_state, BattleController.State.IDLE)
	assert_eq(controller.battle.state.units[0].cell, Vector2i(0, 0))


func _camera_settles_on(controller: SoloBattleController, point: Vector3) -> bool:
	for i in MAX_WAIT_FRAMES:
		if controller.camera_rig.position.is_equal_approx(point):
			return true
		await _tree().process_frame
	return false


func test_the_camera_follows_the_acting_unit_each_turn_and_recenter_goes_back() -> void:
	var controller := _controller("0p 0 0 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	var hero := controller.units_view.view(0).position
	assert_true(await _camera_settles_on(controller, controller.camera_rig.clamp_point(hero)), "on the hero whose turn it is")
	controller.camera_rig.focus(Vector3(5, 0, 0))  # The player looked elsewhere.
	var recenter := InputEventAction.new()
	recenter.action = &"camera_recenter"
	recenter.pressed = true
	controller._unhandled_input(recenter)
	assert_true(await _camera_settles_on(controller, controller.camera_rig.clamp_point(hero)), "the Recenter key returns to the acting unit")
	controller.camera_rig.focus(Vector3(5, 0, 0))
	controller.hud.recenter_pressed.emit()
	assert_true(await _camera_settles_on(controller, controller.camera_rig.clamp_point(hero)), "so does the HUD button")
	# An enemy turn: the camera goes to the enemy as its turn starts.
	controller.end_turn()
	assert_true(await _wait_for(controller, [BattleController.State.ENEMY_TURN, BattleController.State.IDLE]))
	assert_true(controller.camera_rig.bounds.has_area(), "the board's bounds were set")


func test_unit_focus_uses_where_the_unit_is_drawn_now() -> void:
	var controller := _controller("0p 0 0 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller.units_view.view(1).position = Vector3(2, 0, 0)  # Mid-move: drawn here, the state says (5, 0).
	controller.focus_unit(1)
	assert_true(await _camera_settles_on(controller, Vector3(2, 0, 0)), "the drawn position, not the state's final cell")


func test_a_row_of_the_full_order_moves_the_camera_to_that_unit() -> void:
	var controller := _controller("0p 0 0 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	(controller.hud.get_node("%TurnTimeline/OrderButton") as Button).pressed.emit()
	var rows := controller.hud.get_node("%OrderOverlay/%Rows").get_children()
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	(rows[1] as Control).gui_input.emit(click)  # The enemy, second in the order.
	assert_true(await _camera_settles_on(controller, controller.camera_rig.clamp_point(controller.units_view.view(1).position)))


func test_a_release_on_another_cell_or_over_the_hud_is_not_a_click() -> void:
	var controller := _controller("0p 0 0 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	await _tree().physics_frame
	await _tree().physics_frame
	var screen_of := func(cell: Vector2i) -> Vector2:
		return controller.camera_rig.camera.unproject_position(
				controller.board_view.to_global(controller.board_view.cell_to_world(cell)))
	_mouse(controller, true, screen_of.call(Vector2i(2, 0)))
	_mouse(controller, false, screen_of.call(Vector2i(3, 0)))  # Released on another cell, no drag in between.
	assert_eq(controller.input_state, BattleController.State.IDLE, "press and release on different cells: no click")
	assert_eq(controller.battle.state.units[0].cell, Vector2i(0, 0))


func test_the_arrows_are_left_to_the_menus_while_a_panel_is_open() -> void:
	var controller := _controller("0p 0 0 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller._physics_process(0.0)
	assert_true(controller.camera_rig.pan_enabled)
	(controller.hud.get_node("%TurnTimeline/OrderButton") as Button).pressed.emit()
	controller._physics_process(0.0)
	assert_false(controller.camera_rig.pan_enabled, "the order overlay is open")
	controller.cancel()
	controller._physics_process(0.0)
	assert_true(controller.camera_rig.pan_enabled)


func test_the_camera_follows_a_sudden_death_turn_too() -> void:
	var controller := _controller("0p 0 0 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller.battle.sudden_death_round = 1  # Every round counts as sudden death.
	controller.camera_rig.focus(Vector3(5, 0, 0))
	controller._on_event_played(BattleEvents.TurnStarted.new(0, 1, 6, 3))
	assert_true(await _camera_settles_on(controller, controller.camera_rig.clamp_point(controller.units_view.view(0).position)))


func test_recenter_goes_to_the_unit_on_screen_not_the_states_final_actor() -> void:
	var controller := _controller("0p 0 0 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller._hud_model.current_id = 1  # On screen it is the enemy's turn, whatever the final state says.
	controller.camera_rig.focus(Vector3(0, 0, 0))
	controller.recenter()
	assert_true(await _camera_settles_on(controller, controller.camera_rig.clamp_point(controller.units_view.view(1).position)))


func test_the_inspect_card_goes_to_the_side_away_from_the_unit_it_shows() -> void:
	var controller := _controller("0p 0 0 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller.camera_rig.focus(controller.board_view.center())
	controller.camera_rig.rotate_steps(0, false)
	controller.pin(1)  # The enemy: the hero is the active unit, whose card is elsewhere.
	await _tree().process_frame
	var on_screen := func() -> bool:  # An independent reading of which half the enemy is drawn in.
		var x := controller.camera_rig.camera.unproject_position(controller.units_view.to_global(controller.units_view.view(1).position)).x
		return x > controller.get_viewport().get_visible_rect().size.x / 2.0
	var enemy_on_right: bool = on_screen.call()
	assert_eq(controller.hud.is_inspect_on_left(), enemy_on_right, "the card is on the side away from the enemy")
	controller.camera_rig.rotate_steps(2, false)  # Half a turn: the enemy is now on the other side.
	await _tree().process_frame
	controller._update_inspected()
	assert_eq(on_screen.call(), not enemy_on_right, "the turn moved the enemy to the other half")
	assert_eq(controller.hud.is_inspect_on_left(), not enemy_on_right, "and the card followed")


func test_an_enemy_turn_moves_the_camera_only_when_the_enemy_is_off_screen() -> void:
	var controller := _controller("0p 0 0 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	var rig := controller.camera_rig
	rig.bounds = Rect2()
	var enemy := controller.units_view.view(1).position
	rig.camera.size = 40.0  # Zoomed far out: everything is comfortably on screen.
	rig.focus(Vector3(2.5, 0, 0))
	var before := rig.position
	controller._focus_turn_start(1)
	for i in 30:
		await _tree().process_frame
	assert_eq(rig.position, before, "an enemy already in view: the camera stays put")
	rig.camera.size = 3.0  # Zoomed in: the enemy is off screen.
	rig.focus(Vector3(-4, 0, 0))
	controller._focus_turn_start(1)
	assert_true(await _camera_settles_on(controller, enemy), "off screen: the camera goes to it")
	rig.focus(Vector3(-4, 0, 0))
	controller._focus_turn_start(0)  # An ally's turn always centers on it, in view or not.
	rig.camera.size = 40.0
	assert_true(await _camera_settles_on(controller, controller.units_view.view(0).position), "an ally's turn centers the camera")


func test_the_winners_cheer_on_the_result_screen() -> void:
	var hero := _fighter("P0", 200)
	hero.model_scene = load("res://assets/models/knight.tscn")
	hero.model_scale = 1.0
	var foe := _fighter("E0", 100)
	foe.model_scene = load("res://assets/models/orc_guard.tscn")
	foe.model_scale = 1.0
	var controller := _controller("0p 0 0e", [hero], [foe])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	for unit in controller.battle.state.units:
		if unit.team == UnitState.Team.ENEMY:
			unit.hp = 0
	controller._begin_next()
	var player := controller.units_view.view(0).model().find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer
	assert_true(player.current_animation == "Victory", "the surviving hero cheers: %s" % player.current_animation)
	var lost := _controller("0p 0 0e", [_fighter("P0", 200)], [foe])
	assert_true(await _wait_for(lost, [BattleController.State.IDLE]))
	for unit in lost.battle.state.units:
		if unit.team == UnitState.Team.PLAYER:
			unit.hp = 0
	lost._begin_next()
	var enemy_player := lost.units_view.view(1).model().find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer
	assert_true(enemy_player.current_animation == "Victory", "after a loss the enemies cheer: %s" % enemy_player.current_animation)


func test_aiming_a_backslash_marks_where_the_hero_lands() -> void:
	var hero := _fighter("P0", 200)
	hero.spells = [load("res://data/spells/backslash.tres")] as Array[SpellData]
	var controller := _controller("0 0e 0p 0 0 0", [hero], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller.select_spell(0)
	controller._hovered_cell = Vector2i(1, 0)
	controller._update_hover()
	assert_eq(controller.board_view.highlighted_count(BoardView.Highlight.LANDING), 1, "the landing cell")
	controller._hovered_cell = Vector2i(4, 0)  # Out of range.
	controller._update_hover()
	assert_eq(controller.board_view.highlighted_count(BoardView.Highlight.LANDING), 0)


func test_a_spell_with_no_target_says_so_and_shades_its_reach() -> void:
	var hero := _fighter("P0", 200)
	hero.spells = [load("res://data/spells/charge.tres")] as Array[SpellData]
	var controller := _controller("0p 0 0 0 0\n0 0 0 0 0e", [hero], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller.select_spell(0)
	assert_eq(controller.input_state, BattleController.State.TARGETING, "still aiming")
	assert_true(controller._prompt_text().contains("no target"), controller._prompt_text())
	assert_true(controller.board_view.highlighted_count(BoardView.Highlight.RANGE_BLOCKED) > 0, "its reach is shaded")


func test_auto_lets_the_ai_play_the_heroes_until_switched_off() -> void:
	var controller := _controller("0p 0 0 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100, 60, 1)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	assert_false((controller.hud.get_node("Root/Actions/AutoButton") as Button).visible, "no Auto without QA tools")
	controller.settings.qa_tools = true
	controller._set_state(BattleController.State.IDLE)
	assert_true((controller.hud.get_node("Root/Actions/AutoButton") as Button).visible, "Auto with QA tools")
	controller.set_auto_play(true)
	assert_eq(controller.input_state, BattleController.State.ENEMY_TURN, "the AI takes the hero's turn")
	var hero := controller.battle.state.units[0]
	for i in MAX_WAIT_FRAMES:
		if hero.cell != Vector2i(0, 0):
			break
		await _tree().process_frame
	assert_ne(hero.cell, Vector2i(0, 0), "the AI walked the hero")
	controller.set_auto_play(false)
	assert_true(await _wait_for(controller, [BattleController.State.IDLE, BattleController.State.ENDED]), "the player takes over")


func test_qa_cheats_heal_refill_and_win() -> void:
	var controller := _controller("0p 0 0 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100)])
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller.qa_cheat(&"win")
	assert_eq(controller.input_state, BattleController.State.IDLE, "no cheats outside QA battles")
	controller.qa_battle = true
	controller._set_state(BattleController.State.IDLE)
	assert_true((controller.hud.get_node("Root/QaBar") as Control).visible, "the cheat bar")
	var hero := controller.battle.state.units[0]
	controller.click_cell(Vector2i(3, 0))
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller.qa_cheat(&"refill")
	assert_eq(hero.mp, hero.max_mp(), "MP refilled")
	hero.hp = 3
	controller.qa_cheat(&"heal")
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	assert_eq(hero.hp, hero.max_hp(), "healed")
	controller.qa_cheat(&"win")
	assert_true(await _wait_for(controller, [BattleController.State.ENDED]))
	assert_eq((controller.hud.get_node("%ResultLabel") as Label).text, "Victory!")
	_assert_views_in_sync(controller)



func test_auto_switched_on_while_placing_or_aiming_waits_its_turn() -> void:
	var controller := _controller("0p 0 0 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100, 60, 1)], false)
	controller.settings.qa_tools = true
	controller.set_auto_play(true)
	assert_eq(controller.input_state, BattleController.State.PLACING, "placement stays the player's")
	controller.set_auto_play(false)
	controller.end_turn()  # Ready.
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller.select_spell(0)
	assert_eq(controller.input_state, BattleController.State.TARGETING)
	controller.set_auto_play(true)
	assert_eq(controller.input_state, BattleController.State.ENEMY_TURN, "the AI takes over from aiming")
	assert_eq(controller.selected_spell, -1)
	controller.set_auto_play(false)
	controller.set_auto_play(true)  # Off and on again mid-turn: still one AI at the wheel.
	assert_true(await _wait_for(controller, [BattleController.State.ENEMY_TURN, BattleController.State.ANIMATING]))
	controller.set_auto_play(false)
	assert_true(await _wait_for(controller, [BattleController.State.IDLE, BattleController.State.ENDED]))


func test_qa_cheats_kill_the_pinned_unit_and_lose() -> void:
	var controller := _controller("0p 0 0 0 0 0e\n0 0 0 0 0 0e", [_fighter("P0", 200)], [_fighter("E0", 100), _fighter("E1", 90)])
	controller.qa_battle = true
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	controller.qa_cheat(&"kill")
	assert_eq(controller.input_state, BattleController.State.IDLE, "nothing pinned: nothing killed")
	controller.pin(1)
	controller.qa_cheat(&"kill")
	assert_true(await _wait_for(controller, [BattleController.State.IDLE]))
	assert_false(controller.battle.state.units[1].is_alive(), "the pinned enemy fell")
	assert_true(controller.battle.state.units[2].is_alive())
	controller.qa_cheat(&"lose")
	assert_true(await _wait_for(controller, [BattleController.State.ENDED]))
	assert_eq((controller.hud.get_node("%ResultLabel") as Label).text, "Defeat")
	_assert_views_in_sync(controller)

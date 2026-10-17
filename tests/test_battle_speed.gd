extends TestCase
## Battle speed (normal, fast, instant), the HUD toggle and auto end turn.

const BATTLE_SCENE := preload("res://scenes/battle/battle.tscn")
const PATH := "user://test_battle_speed/settings.cfg"


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func after_each_clean() -> void:
	SettingsStore.new(PATH).delete()
	DirAccess.remove_absolute(PATH.get_base_dir())
	Engine.time_scale = 1.0


func _controller(settings: Settings, layout := "0p 0 0 0e") -> SoloBattleController:
	var hero := BattleFixtures.unit("P0", 200, 3, 6, 40)
	hero.spells = [BattleFixtures.damage_spell(2, 1, 5, 3)] as Array[SpellData]
	var enemy := BattleFixtures.unit("E0", 100, 3, 6, 400)
	enemy.spells = [BattleFixtures.damage_spell(2, 1, 5, 1)] as Array[SpellData]
	var controller := BATTLE_SCENE.instantiate() as SoloBattleController
	controller.rng_seed = 7
	controller.encounter = BattleFixtures.encounter(layout, [enemy])
	controller.players = [hero] as Array[UnitData]
	controller.settings = settings
	_tree().root.add_child(controller)
	return controller


func _wait_idle(controller: SoloBattleController) -> bool:
	for i in 1500:
		if controller.input_state == BattleController.State.IDLE:
			return true
		await _tree().process_frame
	return false


func test_the_settings_are_saved_and_a_bad_value_is_ignored() -> void:
	DirAccess.make_dir_recursive_absolute(PATH.get_base_dir())
	var store := SettingsStore.new(PATH)
	var settings := Settings.new()
	settings.battle_speed = Settings.BattleSpeed.INSTANT
	settings.net_battle_speed = Settings.BattleSpeed.NORMAL
	settings.auto_end_turn = false
	assert_true(store.save(settings))
	var loaded := store.load_or_default()
	assert_eq([loaded.battle_speed, loaded.net_battle_speed, loaded.auto_end_turn],
			[Settings.BattleSpeed.INSTANT, Settings.BattleSpeed.NORMAL, false])
	var file := FileAccess.open(PATH, FileAccess.WRITE)
	file.store_string("[gameplay]\nbattle_speed=9\nnet_battle_speed=-1\nauto_end=\"yes\"\nauto_end_turn=false\n")
	file.close()
	loaded = store.load_or_default()
	assert_eq([loaded.battle_speed, loaded.net_battle_speed, loaded.auto_end_turn],
			[Settings.BattleSpeed.NORMAL, Settings.BattleSpeed.FAST, true], "the defaults (the old auto end key is ignored)")


func test_the_hud_button_cycles_the_speed_and_fast_scales_time_and_gives_it_back() -> void:
	var settings := Settings.new()
	var controller := _controller(settings)
	var button := controller.hud.get_node("%SpeedButton") as Button
	assert_eq([button.text, Engine.time_scale], ["Speed x1", 1.0])
	var changes := [0]
	controller.speed_changed.connect(func() -> void: changes[0] += 1)
	button.pressed.emit()
	assert_eq([settings.battle_speed, button.text, Engine.time_scale, changes[0]], [Settings.BattleSpeed.FAST, "Speed x2", 2.0, 1])
	button.pressed.emit()
	assert_eq([settings.battle_speed, button.text, controller.event_player.instant], [Settings.BattleSpeed.INSTANT, "Speed: skip", true])
	assert_eq(Engine.time_scale, 1.0, "instant doesn't speed the clock: it skips the animations")
	button.pressed.emit()
	assert_eq([settings.battle_speed, controller.event_player.instant], [Settings.BattleSpeed.NORMAL, false])
	button.pressed.emit()  # Fast again, then leave the battle.
	assert_eq(Engine.time_scale, 2.0)
	controller.free()
	assert_eq(Engine.time_scale, 1.0, "the battle gives the clock back when it ends")


func test_a_battle_on_normal_speed_never_touches_the_clock() -> void:
	Engine.time_scale = 7.0  # Whatever the caller set (tests do).
	var controller := _controller(Settings.new())
	assert_eq(Engine.time_scale, 7.0)
	controller.free()
	assert_eq(Engine.time_scale, 7.0)


func test_instant_skips_the_animations_but_the_state_and_views_end_up_right() -> void:
	var settings := Settings.new()
	settings.battle_speed = Settings.BattleSpeed.INSTANT
	var controller := _controller(settings)
	controller.end_turn()  # Ready.
	assert_true(await _wait_idle(controller))
	var started := Time.get_ticks_msec()
	controller.select_spell(0)
	controller.click_cell(Vector2i(3, 0))
	assert_true(await _wait_idle(controller), "back to the player's turn")
	assert_true(Time.get_ticks_msec() - started < 400, "no animation waits (a normal cast alone takes over 0.5 s): %d ms" % (Time.get_ticks_msec() - started))
	var enemy := controller.battle.state.units[1]
	assert_true(enemy.hp < enemy.max_hp(), "the hit landed")
	assert_eq(controller.units_view.view(1).hp_text(), "%d/%d" % [enemy.hp, enemy.max_hp()], "and the view shows it")
	var floating := controller.units_view.view(1).find_children("FloatingNumber*", "Label3D", false, false)
	assert_true(floating.any(func(label: Node) -> bool: return (label as Label3D).text == "-%d" % (enemy.max_hp() - enemy.hp)),
			"the damage number still floats over the target")
	controller.free()


func test_floating_texts_of_one_action_are_stacked() -> void:
	var settings := Settings.new()
	settings.battle_speed = Settings.BattleSpeed.INSTANT
	var controller := _controller(settings)
	var view := controller.units_view.view(1)
	var events: Array[BattleEvents.Event] = [BattleEvents.DamageDealt.new(1, 3, 10), BattleEvents.DamageDealt.new(1, 4, 6)]
	await controller.event_player.play(events)
	var labels := view.find_children("FloatingNumber*", "Label3D", false, false)
	assert_eq(labels.size(), 2, "both numbers")
	assert_true(absf((labels[1] as Label3D).position.y - (labels[0] as Label3D).position.y) >= UnitView.FLOAT_STACK_STEP * 0.5, "one above the other")
	controller.free()


func _boxed_in_hero_controller(auto: bool) -> SoloBattleController:
	var hero := BattleFixtures.unit("P0", 200, 0, 2, 40)  # No MP, 2 AP: one cast and it is done.
	hero.spells = [BattleFixtures.damage_spell(2, 1, 5, 1)] as Array[SpellData]
	var enemy := BattleFixtures.unit("E0", 100, 0, 6, 400)
	enemy.spells = [BattleFixtures.damage_spell(2, 1, 5, 1)] as Array[SpellData]
	var settings := Settings.new()
	settings.auto_end_turn = auto
	var controller := BATTLE_SCENE.instantiate() as SoloBattleController
	controller.rng_seed = 7
	controller.encounter = BattleFixtures.encounter("0p 0 0e", [enemy])
	controller.players = [hero] as Array[UnitData]
	controller.settings = settings
	_tree().root.add_child(controller)
	return controller


func _hero_turn_ends(controller: SoloBattleController) -> Array:
	var count := [0]
	controller.event_player.event_played.connect(func(event: BattleEvents.Event) -> void:
		if event is BattleEvents.TurnEnded and event.unit_id == 0:
			count[0] += 1)
	return count


func test_auto_end_turn_ends_the_turn_when_nothing_is_left_to_do() -> void:
	Engine.time_scale = 10.0
	var controller := _boxed_in_hero_controller(true)
	var ended := _hero_turn_ends(controller)
	controller.end_turn()  # Ready.
	assert_true(await _wait_idle(controller))
	await _tree().create_timer(0.5).timeout
	assert_eq(ended[0], 0, "with 2 AP and a spell that costs 2 the hero can still act: the turn stays")
	controller.select_spell(0)
	controller.click_cell(Vector2i(1, 0))  # Nothing left afterwards: no MP, no AP.
	await _tree().create_timer(1.5).timeout
	assert_true(ended[0] >= 1, "the turn ended by itself")
	controller.free()


func test_without_auto_end_turn_the_player_ends_it() -> void:
	Engine.time_scale = 10.0
	var controller := _boxed_in_hero_controller(false)
	var ended := _hero_turn_ends(controller)
	controller.end_turn()
	assert_true(await _wait_idle(controller))
	controller.select_spell(0)
	controller.click_cell(Vector2i(1, 0))
	await _tree().create_timer(1.5).timeout
	assert_eq(ended[0], 0, "nothing ends the turn but the player")
	controller.free()


func test_auto_end_turn_waits_while_a_tutorial_step_is_showing() -> void:
	Engine.time_scale = 10.0
	var hero := BattleFixtures.unit("P0", 200, 0, 1, 40)  # 1 AP and a 2 AP spell: nothing to do from the start.
	hero.spells = [BattleFixtures.damage_spell(2, 1, 5, 1)] as Array[SpellData]
	var enemy := BattleFixtures.unit("E0", 100, 0, 6, 400)
	enemy.spells = [BattleFixtures.damage_spell(2, 1, 5, 1)] as Array[SpellData]
	var settings := Settings.new()
	settings.auto_end_turn = true
	var tutorial := Tutorial.new(Settings.new())
	for id in ["ready", "move", "spell", "cast"]:
		tutorial.complete(id)  # Only the End turn step is left.
	var controller := BATTLE_SCENE.instantiate() as SoloBattleController
	controller.rng_seed = 7
	controller.encounter = BattleFixtures.encounter("0p 0 0e", [enemy])
	controller.players = [hero] as Array[UnitData]
	controller.settings = settings
	controller.tutorial = tutorial
	_tree().root.add_child(controller)
	controller.end_turn()
	assert_true(await _wait_idle(controller))
	assert_eq(controller._step.get("id", ""), "end_turn", "the End turn step is up")
	var ended := _hero_turn_ends(controller)
	await _tree().create_timer(1.5).timeout
	assert_eq(ended[0], 0, "auto end turn leaves the player to read it and press End turn")
	controller.end_turn()
	assert_true(await _wait_idle(controller))
	assert_eq(controller._step.get("id", ""), "", "pressing it finishes the tutorial")
	controller.free()

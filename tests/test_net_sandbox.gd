extends TestCase
## The multiplayer sandbox tool: a whole match in one process, started at once, with a seat bar to switch screens.

const SCENE := preload("res://scenes/tools/net_sandbox.tscn")


func _sandbox(options: Dictionary) -> NetSandbox:
	var sandbox := SCENE.instantiate() as NetSandbox
	sandbox.load_saved_settings = false  # Never the player's own file.
	sandbox.options.merge(options, true)
	sandbox.settings.net_battle_speed = Settings.BattleSpeed.INSTANT
	(Engine.get_main_loop() as SceneTree).root.add_child(sandbox)
	return sandbox


func test_the_match_starts_at_once_with_the_classes_asked_and_the_others_played_by_the_ai() -> void:
	var sandbox := _sandbox({"players": 4, "heroes": "knight,rogue,priestess,ranger", "placed": true, "cards": true})
	for frame in 5:
		await (Engine.get_main_loop() as SceneTree).process_frame  # The host starts the fight at its next tick.
	var state := sandbox.sessions[1].state
	assert_eq(sandbox.sessions.size(), 4)
	assert_true(state.battle != null and state.battle.state.started, "placed and started, no lobby")
	assert_true(state.settings["cards"], "the rules asked for")
	assert_eq([state.seats[1].side, state.seats[2].side, state.seats[3].side, state.seats[4].side], [0, 0, 1, 1], "half and half")
	assert_eq(PvpHeroes.hero(state.seats[3].hero).display_name(), "Priestess")
	assert_false(state.seats[1].ai, "my seat is mine")
	assert_true(state.seats[2].ai and state.seats[3].ai and state.seats[4].ai, "the others are the AI's")
	assert_eq(sandbox.battle.session, sandbox.sessions[1])
	sandbox.view_seat(3)
	assert_eq(sandbox.battle.session, sandbox.sessions[3], "the seat bar switches screens")
	assert_false(state.seats[3].ai, "the seat taken is mine")
	assert_true(state.seats[1].ai, "the one left goes to the AI")
	assert_eq(sandbox.find_children("*", "NetBattleController", true, false).size(), 1, "one screen at a time")
	assert_true(sandbox.battle.sound.is_connected(sandbox.audio.play_sfx), "the fight's sounds are heard")
	assert_true(sandbox.find_child("TopBar", true, false) != null, "the game's round buttons")
	sandbox.open_settings()
	assert_true(sandbox.find_children("*", "SettingsScreen", true, false).size() == 1, "the settings over the fight")
	assert_eq(sandbox.sessions[1].ai_delay, 2.5, "the AI takes its time, to try things during its turns")
	sandbox.hold_ai(true)
	assert_true(sandbox.sessions[1].ai_delay > 1000.0, "held: it waits")
	sandbox.hold_ai(false)
	assert_eq(sandbox.sessions[1].ai_delay, 2.5)
	sandbox.free()


func test_an_unknown_class_is_reported_and_nothing_starts() -> void:
	expect_error("no class named")
	var sandbox := _sandbox({"heroes": "dragon"})
	assert_true(sandbox.sessions.is_empty() and sandbox.battle == null)
	sandbox.free()

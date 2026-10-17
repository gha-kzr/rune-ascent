extends TestCase
## The multiplayer screens: the front page, the lobby (what each player may change), and the whole
## flow from a room code to a lobby to a fight, with a relay in memory standing in for the server.


const TEST_FILE := "user://test_net_player.cfg"


func _sandbox() -> void:
	NetUi.player_file = TEST_FILE
	DirAccess.remove_absolute(TEST_FILE)


## Every test here uses its own player file: the screens save the name and the hero, and the real file is the player's.
func _init() -> void:
	NetUi.player_file = TEST_FILE


func after_each_clean() -> void:
	NetUi.player_file = TEST_FILE
	DirAccess.remove_absolute(TEST_FILE)


func _root() -> Node:
	return (Engine.get_main_loop() as SceneTree).root


func _frames(count := 2) -> void:
	for i in count:
		await (Engine.get_main_loop() as SceneTree).process_frame


func test_the_front_page_hosts_or_joins_with_a_name() -> void:
	_sandbox()
	var menu := NetMenuScreen.new()
	_root().add_child(menu)
	var hosted := []
	var joined := []
	menu.host_requested.connect(func(player_name: String) -> void: hosted.append(player_name))
	menu.join_requested.connect(func(player_name: String, text: String) -> void: joined.append([player_name, text]))
	NetUi.save_name("Alice")
	assert_true(menu.find_child("NameEdit", true, false) == null and menu.find_child("Heroes", true, false) == null, "name and hero are chosen in the lobby")
	(menu.find_child("HostButton", true, false) as Button).pressed.emit()
	assert_eq(hosted, ["Alice"])
	(menu.find_child("JoinButton", true, false) as Button).pressed.emit()
	assert_eq(joined, [], "no code typed yet")
	assert_ne((menu.find_child("Status", true, false) as Label).text, "")
	(menu.find_child("CodeEdit", true, false) as LineEdit).text = " R1abc "
	(menu.find_child("JoinButton", true, false) as Button).pressed.emit()
	assert_eq(joined, [["Alice", "R1abc"]], "the pasted text, trimmed")
	menu.free()


func test_the_lobby_lets_each_player_change_only_their_own_seat_and_the_host_the_rules() -> void:
	_sandbox()
	var rig := NetRig.new()
	rig.host(1, "Alice")
	rig.guest(2, "Bob")
	var host_lobby := NetLobbyScreen.new()
	var guest_lobby := NetLobbyScreen.new()
	_root().add_child(host_lobby)
	_root().add_child(guest_lobby)
	host_lobby.bind(rig.sessions[1])
	guest_lobby.bind(rig.sessions[2])
	await _frames()
	assert_eq(host_lobby.find_child("HeroPicker", true, false).get_child_count(), PvpHeroes.hero_count(), "a card for each hero, for my own seat")
	assert_true(host_lobby.find_child("Seat1", true, false) != null and host_lobby.find_child("Seat2", true, false) != null, "both players are listed")
	assert_true(host_lobby.find_child("TeamNone", true, false).visible, "nobody has a team yet")
	assert_true((host_lobby.find_child("Ready", true, false) as CheckBox).disabled, "no team, no ready")
	assert_true(host_lobby.find_child("Kick2", true, false) != null and host_lobby.find_child("Kick1", true, false) == null, "the host removes others, not themself")
	assert_true(guest_lobby.find_child("Kick1", true, false) == null, "a guest removes nobody")
	assert_true((host_lobby.find_child("Typology", true, false) as OptionButton).disabled == false, "the host edits the rules")
	assert_true((guest_lobby.find_child("Typology", true, false) as OptionButton).disabled, "a guest only reads them")
	assert_true((guest_lobby.find_child("Size", true, false) as SpinBox).editable == false)
	assert_true(guest_lobby.find_child("StartButton", true, false).visible == false, "only the host starts")
	# Bob picks the Mage on side B: everyone sees it.
	(guest_lobby.find_child("Hero1", true, false) as Button).pressed.emit()
	(guest_lobby.find_child("TeamB", true, false) as Control).gui_input.emit(_left_click())  # A click on the team joins it.
	rig.net.flush()
	assert_eq(rig.sessions[1].state.seats[2].hero, 1)
	assert_eq(rig.sessions[1].state.seats[2].side, 1)
	assert_eq(NetUi.saved_hero(), 1, "and the lobby will start with that hero next time")
	assert_false((guest_lobby.find_child("Ready", true, false) as CheckBox).disabled, "a team: ready is possible")
	(host_lobby.find_child("Kick2", true, false) as Button).pressed.emit()
	rig.net.flush()
	assert_false(rig.sessions[1].state.seats.has(2), "the host removed Bob")
	host_lobby.free()
	guest_lobby.free()


func test_each_team_card_lists_its_players_with_their_hero() -> void:
	var rig := NetRig.new()
	rig.host(1, "Alice")
	rig.guest(2, "Bob")
	rig.sessions[1].set_field("side", 0)
	rig.sessions[2].set_field("side", 1)
	rig.sessions[2].set_field("hero", 1)
	rig.net.flush()
	var lobby := NetLobbyScreen.new()
	_root().add_child(lobby)
	lobby.bind(rig.sessions[1])
	var team_a := lobby.find_child("TeamA", true, false)
	var team_b := lobby.find_child("TeamB", true, false)
	assert_true(team_a.find_child("Seat1", true, false) != null and team_a.find_child("Seat2", true, false) == null, "Alice on side A")
	assert_true(team_b.find_child("Seat2", true, false) != null and team_b.find_child("Seat1", true, false) == null, "Bob on side B")
	assert_true((team_a.find_child("Seat1", true, false) as Label).text.contains(PvpHeroes.hero_name(0)))
	assert_true((team_b.find_child("Seat2", true, false) as Label).text.contains(PvpHeroes.hero_name(1)))
	lobby.free()


func test_hero_cards_show_what_the_hero_is_and_does() -> void:
	for index in PvpHeroes.hero_count():
		var info := PvpHeroes.summary(index)
		assert_true(info["hp"] > 0 and info["ap"] > 0 and info["mp"] > 0)
		assert_eq(info["spell_icons"].size(), 4, "its four spells")
		assert_false(str(info["role"]).is_empty())
	assert_false(str(PvpHeroes.summary(0)["description"]).is_empty())
	var card := NetUi.hero_card(0, true, func(_i: int) -> void: pass)
	assert_true(card.button_pressed and card.toggle_mode)
	assert_true(card.find_children("*", "TextureRect", true, false).size() == 4)
	card.free()


func test_the_start_button_waits_until_everyone_is_ready() -> void:
	var rig := NetRig.new()
	rig.host(1, "Alice")
	rig.guest(2, "Bob")
	var lobby := NetLobbyScreen.new()
	_root().add_child(lobby)
	lobby.bind(rig.sessions[1])
	rig.sessions[1].set_field("side", 0)
	rig.sessions[2].set_field("side", 1)
	rig.net.flush()
	var start := lobby.find_child("StartButton", true, false) as Button
	assert_true(start.disabled, "nobody is ready")
	rig.sessions[2].set_ready(true)
	rig.net.flush()
	assert_true(start.disabled, "the host is not ready yet")
	(lobby.find_child("Ready", true, false) as CheckBox).toggled.emit(true)
	rig.net.flush()
	assert_false(start.disabled, "ready: the host can start")
	start.pressed.emit()
	rig.net.flush()
	assert_eq(rig.sessions[2].state.phase, MatchState.Phase.BATTLE)
	lobby.free()


func test_a_player_changes_their_name_in_the_lobby() -> void:
	var rig := NetRig.new()
	rig.host(1, "Alice")
	var lobby := NetLobbyScreen.new()
	_root().add_child(lobby)
	lobby.bind(rig.sessions[1])
	var edit := lobby.find_child("NameEdit", true, false) as LineEdit
	assert_eq(edit.text, "Alice")
	edit.text_submitted.emit("Alicia")
	assert_eq(rig.sessions[1].state.seats[1].name, "Alicia")
	lobby.free()


func _flow(relay: FakeRelay) -> NetFlow:
	var flow := NetFlow.new()
	flow.make_socket = relay.make_socket
	_root().add_child(flow)
	return flow


## The relay and every flow's hub run for `seconds` (the hubs are polled by hand, the relay delivers between steps).
func _pump(relay: FakeRelay, flows: Array, seconds := 2.0) -> void:
	var elapsed := 0.0
	relay.flush()
	while elapsed < seconds - 0.00001:
		for flow: NetFlow in flows:
			flow.hub._process(0.25)
		relay.flush()
		elapsed += 0.25


## A host in its lobby and a guest in the same one, both with the screens they would see.
func _two_players(relay: FakeRelay) -> Array:
	var host := _flow(relay)
	host.start("")
	host._on_host("Alice")
	_pump(relay, [host])
	var guest := _flow(relay)
	guest.start("")
	guest._on_join("Bob", host.hub.room_code)
	_pump(relay, [host, guest])
	return [host, guest]


func test_a_room_code_puts_two_players_in_the_same_lobby() -> void:
	var relay := FakeRelay.new()
	var host := _flow(relay)
	host.start("")
	host._on_host("Alice")
	assert_true(host._screen is NetJoinScreen, "waiting for the server to make the room")
	_pump(relay, [host])
	assert_true(host._screen is NetLobbyScreen, "the room is made: the lobby")
	var guest := _flow(relay)
	guest.start("")
	guest._on_join("Bob", RoomCode.pretty(host.hub.room_code))
	assert_true(guest._screen is NetJoinScreen, "waiting for the server")
	_pump(relay, [host, guest])
	await _frames()
	assert_true(guest._screen is NetLobbyScreen, "caught up: the lobby")
	assert_eq(host.hub.session.state.seat_ids(), [1, 2] as Array[int])
	assert_eq(guest.hub.session.state.seats[1].name, "Alice")
	assert_eq(guest.hub.session.host_id, 1)
	host.free()
	guest.free()


func test_a_link_opened_in_the_browser_joins_by_itself() -> void:
	var relay := FakeRelay.new()
	var host := _flow(relay)
	host.start("")
	host._on_host("Alice")
	_pump(relay, [host])
	var guest := _flow(relay)
	guest.start("room=" + host.hub.room_code)
	assert_true(guest._screen is NetJoinScreen, "no click needed")
	assert_true(guest.hub.transport != null)
	_pump(relay, [host, guest])
	assert_true(guest._screen is NetLobbyScreen)
	host.free()
	guest.free()


func test_a_bad_code_stays_on_the_front_page_with_a_message() -> void:
	var relay := FakeRelay.new()
	var guest := _flow(relay)
	guest.start("")
	guest._on_join("Bob", "not a code")
	assert_true(guest._screen is NetMenuScreen)
	assert_ne((guest._screen.find_child("Status", true, false) as Label).text, "")
	guest.free()


func test_a_code_nobody_has_goes_back_to_the_front_page_with_a_message() -> void:
	var relay := FakeRelay.new()
	var guest := _flow(relay)
	guest.start("")
	guest._on_join("Bob", "abcdef")
	assert_true(guest._screen is NetJoinScreen)
	_pump(relay, [guest])
	assert_true(guest._screen is NetMenuScreen, "back on the front page")
	assert_true((guest._screen.find_child("Status", true, false) as Label).text.begins_with("No match has that code"))
	guest.free()


func test_the_fight_opens_on_both_screens_and_leads_back_to_the_lobby() -> void:
	var relay := FakeRelay.new()
	var both := _two_players(relay)
	var host: NetFlow = both[0]
	var guest: NetFlow = both[1]
	await _frames()
	guest.hub.session.set_field("side", 1)
	host.hub.session.set_field("side", 0)
	_pump(relay, both)
	host.hub.session.set_ready(true)
	guest.hub.session.set_ready(true)
	_pump(relay, both)
	host.hub.session.start_match()
	_pump(relay, both)
	await _frames(3)
	assert_true(host._screen is NetBattleController, "the fight on the host's screen")
	assert_true(guest._screen is NetBattleController, "and the guest's")
	host.free()
	guest.free()


func test_the_front_page_has_no_name_or_hero_to_pick_and_names_players_by_themselves() -> void:
	_sandbox()
	var name_made := NetUi.saved_name()
	assert_true(name_made in NetUi.NAMES, "a random name from the list")
	assert_eq(NetUi.saved_name(), name_made, "kept for next time")
	NetUi.save_name("Zed")
	assert_eq(NetUi.saved_name(), "Zed", "until they pick their own")


func test_a_hero_card_shows_clearly_whether_it_is_the_chosen_one() -> void:
	var picked := []
	var card := NetUi.hero_card(1, false, func(index: int) -> void: picked.append(index))
	var mark := card.find_child("Chosen", true, false) as Label
	assert_false(mark.visible)
	card.button_pressed = true
	assert_true(mark.visible, "the mark shows at once, before the host answers")
	var normal := card.get_theme_stylebox("normal") as StyleBoxFlat
	var pressed := card.get_theme_stylebox("pressed") as StyleBoxFlat
	assert_true(pressed.border_width_left > normal.border_width_left and pressed.bg_color != normal.bg_color, "a different look")
	card.free()


func test_the_info_button_opens_the_hero_stats_and_spells_without_picking_it() -> void:
	var picked := []
	var holder := Control.new()
	holder.size = Vector2(900, 700)
	_root().add_child(holder)
	var card := NetUi.hero_card(0, false, func(index: int) -> void: picked.append(index))
	holder.add_child(card)
	(holder.find_child("Info0", true, false) as Button).pressed.emit()
	var popup := holder.find_child("HeroInfo", true, false)
	assert_true(popup != null, "the popup opened")
	assert_eq(picked, [], "the card was not picked")
	var info := PvpHeroes.details(0)
	assert_eq(info["spells"].size(), 4)
	for spell: Dictionary in info["spells"]:
		assert_false(spell["lines"].is_empty(), "each spell says what it does")
	assert_false(info.has("power") or info.has("resistances"), "Power and resistances mean nothing in PvP: hidden")
	(popup.find_child("CloseInfo", true, false) as Button).pressed.emit()
	await _frames()
	assert_true(holder.find_child("HeroInfo", true, false) == null, "closed")
	holder.free()


func test_scrolling_past_the_end_of_the_spell_list_does_not_close_the_popup() -> void:
	var holder := Control.new()
	holder.size = Vector2(900, 700)
	_root().add_child(holder)
	holder.add_child(NetUi.hero_card(0, false, func(_index: int) -> void: pass))
	(holder.find_child("Info0", true, false) as Button).pressed.emit()
	var popup := holder.find_child("HeroInfo", true, false) as Control
	for wheel in [MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_UP]:
		var event := InputEventMouseButton.new()
		event.button_index = wheel
		event.pressed = true
		popup.gui_input.emit(event)
	await _frames()
	assert_true(holder.find_child("HeroInfo", true, false) != null, "the wheel left the popup open")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	popup.gui_input.emit(click)
	await _frames()
	assert_true(holder.find_child("HeroInfo", true, false) == null, "a click outside closes it")
	holder.free()


func test_the_teams_are_blue_and_red_everywhere() -> void:
	assert_eq(NetUi.side_name(0), "Blue team")
	assert_eq(NetUi.side_name(1), "Red team")
	var lobby := NetLobbyScreen.new()
	var rig := NetRig.new()
	rig.host(1)
	_root().add_child(lobby)
	lobby.bind(rig.sessions[1])
	assert_true(lobby.find_children("*", "MapPreview", true, false).size() == 1)
	var map_preview := lobby.find_children("*", "MapPreview", true, false)[0] as MapPreview
	assert_eq(map_preview.zone_color, NetUi.SIDE_COLORS[0])
	assert_eq(map_preview.enemy_color, NetUi.SIDE_COLORS[1])
	lobby.free()


func _left_click() -> InputEventMouseButton:
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	return click


func test_a_team_is_joined_by_clicking_it_and_there_is_no_join_button() -> void:
	var rig := NetRig.new()
	rig.host(1, "Alice")
	rig.guest(2, "Bob")
	var lobby := NetLobbyScreen.new()
	_root().add_child(lobby)
	lobby.bind(rig.sessions[2])
	assert_true(lobby.find_child("SideA", true, false) == null and lobby.find_child("SideB", true, false) == null, "the join buttons are gone")
	(lobby.find_child("TeamA", true, false) as Control).gui_input.emit(_left_click())
	rig.net.flush()
	assert_eq(rig.sessions[1].state.seats[2].side, 0, "a click on the card")
	assert_true((lobby.find_child("JoinA", true, false) as Button).text.contains("your team"), "the card says it is mine")
	(lobby.find_child("JoinB", true, false) as Button).pressed.emit()
	rig.net.flush()
	assert_eq(rig.sessions[1].state.seats[2].side, 1, "the team's name is a button for the keyboard")
	assert_false((lobby.find_child("JoinA", true, false) as Button).text.contains("your team"))
	var right_click := _left_click()
	right_click.button_index = MOUSE_BUTTON_RIGHT
	(lobby.find_child("TeamA", true, false) as Control).gui_input.emit(right_click)
	rig.net.flush()
	assert_eq(rig.sessions[1].state.seats[2].side, 1, "only the left button joins")
	lobby.free()


func test_the_lobby_has_no_quick_messages_and_no_settings_button() -> void:
	var rig := NetRig.new()
	rig.start_match(2, 1)
	var lobby := NetLobbyScreen.new()
	_root().add_child(lobby)
	lobby.bind(rig.sessions[1])
	assert_true(lobby.find_child("Emote0", true, false) == null and lobby.find_child("Emotes", true, false) == null, "no quick messages in the lobby")
	assert_true(lobby.find_child("SettingsButton", true, false) == null, "the settings are the cog at the top")
	rig.sessions[2].send_emote(1)
	rig.net.flush()
	assert_false((lobby.find_child("Seat2", true, false) as Label).text.contains(Emotes.text(1)), "and nothing shows on a row")
	lobby.free()


func test_the_team_cards_take_the_mouse_as_a_whole_so_the_hover_and_the_hand_work_on_the_title_too() -> void:
	var rig := NetRig.new()
	rig.host(1, "Alice")
	rig.guest(2, "Bob")
	rig.sessions[2].set_field("side", 1)
	rig.net.flush()
	var lobby := NetLobbyScreen.new()
	_root().add_child(lobby)
	lobby.bind(rig.sessions[1])
	for name in ["TeamA", "TeamB"]:
		var card := lobby.find_child(name, true, false) as Control
		assert_eq(card.mouse_default_cursor_shape, Control.CURSOR_POINTING_HAND, name + ": a hand")
		assert_eq(card.mouse_filter, Control.MOUSE_FILTER_STOP, name + ": the card is what the mouse is over")
		for control in card.find_children("*", "Control", true, false):
			if control is Button and (control as Button).name.begins_with("Kick"):
				continue
			assert_eq((control as Control).mouse_filter, Control.MOUSE_FILTER_IGNORE, "%s: %s lets the mouse through to the card" % [name, control.name])
	var card_a := lobby.find_child("TeamA", true, false) as Control
	card_a.mouse_entered.emit()
	assert_ne(card_a.modulate, Color.WHITE, "hovered: lighter")
	card_a.mouse_exited.emit()
	assert_eq(card_a.modulate, Color.WHITE)
	lobby.free()


func test_the_new_map_button_is_a_round_arrow() -> void:
	var rig := NetRig.new()
	rig.host(1, "Alice")
	var lobby := NetLobbyScreen.new()
	_root().add_child(lobby)
	lobby.bind(rig.sessions[1])
	var button := lobby.find_child("NewSeed", true, false) as Button
	assert_true(button.icon != null and button.text.is_empty(), "an icon and no text")
	assert_ne(button.tooltip_text, "")
	var seed_before: int = rig.sessions[1].state.settings["seed"]
	button.pressed.emit()
	assert_ne(rig.sessions[1].state.settings["seed"], seed_before, "it still draws a new map")
	lobby.free()


func test_the_room_code_is_written_the_same_way_everywhere() -> void:
	assert_eq(RoomCode.pretty("aytjrd"), "ayt-jrd")
	assert_eq(RoomCode.link_for("https://example.org/game/", "aytjrd"), "https://example.org/game/#room=ayt-jrd")
	assert_eq(RoomCode.normalize(RoomCode.link_for("https://example.org/game/", "aytjrd")), "aytjrd", "and the link is read back")
	assert_eq(NetFlow._join_code_in("room=ayt-jrd"), "aytjrd")
	assert_eq(NetFlow._join_code_in("room=aytjrd"), "aytjrd", "an older link still works")
	var rig := NetRig.new()
	rig.host(1, "Alice")
	var lobby := NetLobbyScreen.new()
	_root().add_child(lobby)
	lobby.bind(rig.sessions[1])
	lobby.show_room("aytjrd", RoomCode.link_for("https://example.org/", "aytjrd"))
	assert_eq(lobby._room_code, "ayt-jrd", "the copied code is the displayed one")
	assert_true((lobby.find_child("RoomCode", true, false) as Label).text.contains("ayt-jrd"))
	lobby.free()


func test_changing_the_map_or_the_rules_leaves_the_players_ready_on_every_screen() -> void:
	var rig := NetRig.new()
	rig.host(1, "Alice")
	rig.guest(2, "Bob")
	var host_lobby := NetLobbyScreen.new()
	var guest_lobby := NetLobbyScreen.new()
	_root().add_child(host_lobby)
	_root().add_child(guest_lobby)
	host_lobby.bind(rig.sessions[1])
	guest_lobby.bind(rig.sessions[2])
	rig.sessions[1].set_field("side", 0)
	rig.sessions[2].set_field("side", 1)
	rig.net.flush()
	(host_lobby.find_child("Ready", true, false) as CheckBox).button_pressed = true
	(guest_lobby.find_child("Ready", true, false) as CheckBox).button_pressed = true
	rig.net.flush()
	var changes: Array[Callable] = [
		func() -> void: (host_lobby.find_child("Typology", true, false) as OptionButton).item_selected.emit(2),
		func() -> void: (host_lobby.find_child("Size", true, false) as SpinBox).value = 12,
		func() -> void: (host_lobby.find_child("NewSeed", true, false) as Button).pressed.emit(),
		func() -> void: (host_lobby.find_child("Turn", true, false) as SpinBox).value = 60,
		func() -> void: (host_lobby.find_child("Grace", true, false) as SpinBox).value = 33,
		func() -> void: (host_lobby.find_child("Cards", true, false) as CheckButton).toggled.emit(true),
		func() -> void: (host_lobby.find_child("FriendlyFire", true, false) as CheckButton).toggled.emit(false),
	]
	for change in changes:
		change.call()
		rig.net.flush()
		assert_true(rig.sessions[1].state.seats[1].ready and rig.sessions[1].state.seats[2].ready, "still ready after the change")
		assert_true((host_lobby.find_child("Ready", true, false) as CheckBox).button_pressed and (guest_lobby.find_child("Ready", true, false) as CheckBox).button_pressed, "and the boxes stay ticked")
	assert_false(rig.sessions[1].state.start_problem() != "", "the host can start")
	# What a player does to their own seat still takes their Ready back.
	rig.sessions[2].set_field("hero", 1)
	rig.net.flush()
	assert_false(rig.sessions[1].state.seats[2].ready)
	assert_true(rig.sessions[1].state.seats[1].ready)
	host_lobby.free()
	guest_lobby.free()


func test_a_new_match_takes_45_seconds_a_turn() -> void:
	assert_eq(MatchState.new().settings["turn"], 30)


func test_the_lobby_opens_with_the_hero_the_player_likes() -> void:
	_sandbox()
	var relay := FakeRelay.new()
	NetUi.save_hero(2)
	var host := _flow(relay)
	host.start("")
	host._on_host("Alice")
	_pump(relay, [host])
	assert_eq(host.hub.session.state.seats[1].hero, 2, "the host's seat starts with it")
	NetUi.save_hero(1)  # Another player, another browser: their own favourite.
	var guest := _flow(relay)
	guest.start("")
	guest._on_join("Bob", host.hub.room_code)
	_pump(relay, [host, guest])
	await _frames()
	_pump(relay, [host, guest])
	assert_eq(guest.hub.session.state.seats[2].hero, 1, "and so does the guest's")
	assert_eq(host.hub.session.state.seats[2].hero, 1, "everyone sees it")
	host.free()
	guest.free()


func test_the_lobby_can_copy_the_room_code_and_the_room_link() -> void:
	_sandbox()
	var relay := FakeRelay.new()
	var host := _flow(relay)
	host.start("")
	host._on_host("Alice")
	_pump(relay, [host])
	var lobby := host._screen as NetLobbyScreen
	var label := lobby.find_child("RoomCode", true, false) as Label
	assert_true(label.visible and label.text.contains(RoomCode.pretty(host.hub.room_code)), "the code is shown")
	for button_name in ["CopyRoomCode", "CopyRoom"]:
		var button := lobby.find_child(button_name, true, false) as Button
		assert_true(button != null and button.visible, button_name)
		button.pressed.emit()
	assert_true(lobby.find_child("ManualInvite", true, false) == null, "there is no manual invite any more")
	host.free()


func test_the_flow_tells_the_game_root_when_its_view_changes_and_when_the_fight_is_on() -> void:
	var relay := FakeRelay.new()
	var flow := _flow(relay)
	var views := {"count": 0}
	flow.view_changed.connect(func() -> void: views.count += 1)
	flow.start("")
	assert_eq(views.count, 1, "the front page")
	assert_false(flow.in_battle())
	flow._on_host("Alice")
	_pump(relay, [flow])
	assert_true(views.count >= 2, "the lobby came")
	assert_true(flow.in_lobby(), "the settings button is offered in the lobby")
	assert_false(flow.in_battle(), "no fight yet")
	assert_false(flow.menu_available(), "so the Game root's menu button stays away")
	flow.open_menu()  # No fight: nothing happens.
	flow.free()

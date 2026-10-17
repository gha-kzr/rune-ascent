class_name NetLobbyScreen
extends Screen
## Before the fight, in cards: your player (name, hero cards, team, ready), the two teams side by side (blue and red,
## with whoever has not chosen yet under them, and a Remove button for the host; a click on a team joins it), the invite card (the
## room code and link to copy or read out), and the map and rules (the
## host's choices, with the map drawn from above). Everything a player changes goes through the match session, so every
## screen shows the same lobby.

signal leave_requested

const RESET_ICON: Texture2D = preload("res://ui/icons/reset.svg")
var session: MatchSession

var _banner: Label
var _seat_card: Control
var _name_edit: LineEdit
var _hero_row: HFlowContainer
var _hero_shown := -1
var _unassigned_card: Control
var _unassigned_box: VBoxContainer
var _ready: CheckBox
var _team_boxes: Array[VBoxContainer] = []
var _team_titles: Array[Button] = []
var _team_cards: Array[Control] = []
var _room_label: Label
var _room_link := ""
var _room_code := ""
var _copy_room_code: Button
var _copy_room: Button
var _typology: OptionButton
var _size: SpinBox
var _seed: LineEdit
var _turn: SpinBox
var _grace: SpinBox
var _cards: CheckButton
var _friendly_fire: CheckButton
var _spirits: CheckButton
var _preview: MapPreview
var _preview_key := ""
var _start: Button
var _new_lobby: Button
var _refusal := ""
var _leave: Button
var _settings_fields: Array[Control] = []


func bind(match_session: MatchSession) -> void:
	session = match_session
	_build()
	session.changed.connect(refresh)
	session.rejected.connect(_on_rejected)
	refresh()


func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var background := ColorRect.new()
	background.color = Color(0.1, 0.11, 0.14)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	add_child(margin)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 10)
	margin.add_child(rows)
	var title := Label.new()
	title.theme_type_variation = &"HeaderLabel"
	title.text = "Match lobby"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rows.add_child(title)
	_banner = Label.new()
	_banner.name = "Banner"
	_banner.theme_type_variation = &"PromptLabel"
	_banner.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rows.add_child(_banner)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	rows.add_child(scroll)
	var main := HBoxContainer.new()
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main.add_theme_constant_override("separation", 14)
	scroll.add_child(main)
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 12)
	main.add_child(left)
	_build_seat_card(left)
	_build_teams(left)
	_build_invite(left)
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(350, 0)
	main.add_child(right)
	_build_settings(right)
	var bottom := HBoxContainer.new()
	rows.add_child(bottom)
	_leave = HubStyle.button("Leave", "LeaveButton")
	_leave.pressed.connect(leave_requested.emit)
	bottom.add_child(_leave)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(spacer)
	_new_lobby = HubStyle.button("Open a new lobby", "NewLobbyButton")
	_new_lobby.custom_minimum_size = Vector2(220, 48)
	_new_lobby.pressed.connect(func() -> void: session.back_to_lobby())
	_new_lobby.hide()
	bottom.add_child(_new_lobby)
	_start = HubStyle.button("Start the match", "StartButton")
	_start.custom_minimum_size = Vector2(220, 48)
	_start.pressed.connect(func() -> void: session.start_match())
	bottom.add_child(_start)


## Your player: name, hero, team, ready.
func _build_seat_card(parent: Control) -> void:
	var box := NetUi.card(parent, tr("Your player"))
	_seat_card = box.get_parent()
	_name_edit = LineEdit.new()
	_name_edit.name = "NameEdit"
	_name_edit.placeholder_text = NetUi.random_name()
	_name_edit.max_length = MatchState.MAX_NAME
	_name_edit.custom_minimum_size = Vector2(0, 40)
	_name_edit.text_submitted.connect(func(text: String) -> void: _rename(text))
	_name_edit.focus_exited.connect(func() -> void: _rename(_name_edit.text))
	box.add_child(_name_edit)
	_hero_row = HFlowContainer.new()
	_hero_row.name = "HeroPicker"
	_hero_row.add_theme_constant_override("h_separation", 10)
	_hero_row.add_theme_constant_override("v_separation", 10)
	box.add_child(_hero_row)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 8)
	box.add_child(line)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(spacer)
	_ready = CheckBox.new()
	_ready.name = "Ready"
	_ready.text = "Ready"
	_ready.tooltip_text = tr("Pick a team first")
	_ready.toggled.connect(func(on: bool) -> void: session.set_ready(on))
	line.add_child(_ready)


func _build_teams(parent: Control) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	parent.add_child(row)
	for side in 2:
		var box := NetUi.card(row, "", NetUi.SIDE_COLORS[side])
		var panel := box.get_parent() as Control
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		panel.name = "Team%s" % ("A" if side == 0 else "B")
		# The team's name is a button (so it works with the keyboard too), and the whole card answers a click: joining a
		# team is done by clicking it.
		var title := Button.new()
		title.name = "Join%s" % ("A" if side == 0 else "B")
		title.flat = true
		title.alignment = HORIZONTAL_ALIGNMENT_LEFT
		title.theme_type_variation = &"PromptLabel"
		title.add_theme_color_override("font_color", NetUi.SIDE_COLORS[side])
		title.add_theme_color_override("font_hover_color", NetUi.SIDE_COLORS[side].lightened(0.3))
		title.add_theme_color_override("font_focus_color", NetUi.SIDE_COLORS[side].lightened(0.3))
		title.pressed.connect(func() -> void: session.set_field("side", side))
		title.mouse_filter = Control.MOUSE_FILTER_IGNORE  # The card takes the mouse (hover, hand cursor, click); the button is for the keyboard.
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(title)
		box.move_child(title, 0)
		_team_titles.append(title)
		_team_cards.append(panel)
		panel.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		panel.mouse_entered.connect(func() -> void: panel.modulate = Color(1.12, 1.12, 1.12))
		panel.mouse_exited.connect(func() -> void: panel.modulate = Color.WHITE)
		panel.gui_input.connect(func(event: InputEvent) -> void:
			var click := event as InputEventMouseButton
			if click != null and click.pressed and click.button_index == MOUSE_BUTTON_LEFT:
				session.set_field("side", side))
		var list := VBoxContainer.new()
		list.add_theme_constant_override("separation", 4)
		list.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(list)
		_team_boxes.append(list)
	var waiting := NetUi.card(parent, tr("Not in a team yet"))
	waiting.get_parent().name = "TeamNone"
	_unassigned_card = waiting.get_parent()
	_unassigned_box = VBoxContainer.new()
	_unassigned_box.add_theme_constant_override("separation", 4)
	waiting.add_child(_unassigned_box)


func _build_settings(parent: Control) -> void:
	var box := NetUi.card(parent, tr("Map and rules"))
	_preview = MapPreview.new()
	_preview.custom_minimum_size = Vector2(300, 300)
	_preview.zone_color = NetUi.SIDE_COLORS[0]
	_preview.enemy_color = NetUi.SIDE_COLORS[1]
	_preview.enemy_as_square = true
	box.add_child(_preview)
	_typology = OptionButton.new()
	_typology.name = "Typology"
	for index in MatchState.TYPOLOGIES.size():
		_typology.add_item(_typology_name(MatchState.TYPOLOGIES[index]), index)
	_typology.item_selected.connect(func(index: int) -> void: session.configure("typology", MatchState.TYPOLOGIES[index]))
	_labelled(tr("Map shape"), _typology, box)
	_size = _spin(PvpMap.MIN_SIZE, PvpMap.MAX_SIZE, "Size")
	_size.value_changed.connect(func(value: float) -> void: session.configure("size", int(value)))
	_labelled(tr("Map size"), _size, box)
	_seed = LineEdit.new()
	_seed.name = "Seed"
	_seed.custom_minimum_size = Vector2(120, 0)
	_seed.text_submitted.connect(_on_seed_text)
	_seed.focus_exited.connect(func() -> void: _on_seed_text(_seed.text))
	var new_seed := HubStyle.button("", "NewSeed")
	new_seed.icon = RESET_ICON
	new_seed.expand_icon = true
	new_seed.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	new_seed.custom_minimum_size = Vector2(44, 40)
	new_seed.tooltip_text = tr("New map")
	new_seed.pressed.connect(func() -> void: session.configure("seed", randi_range(1, 999999)))
	var seed_row := HBoxContainer.new()
	seed_row.add_child(_seed)
	seed_row.add_child(new_seed)
	_labelled(tr("Map number"), seed_row, box)
	_turn = _spin(10, 120, "Turn")
	_turn.value_changed.connect(func(value: float) -> void: session.configure("turn", int(value)))
	_labelled(tr("Seconds per turn"), _turn, box)
	_grace = _spin(0, 120, "Grace")
	_grace.value_changed.connect(func(value: float) -> void: session.configure("grace", int(value)))
	_labelled(tr("Seconds before the AI replaces a player who left"), _grace, box)
	_cards = CheckButton.new()
	_cards.name = "Cards"
	_cards.text = tr("Card combat")
	_cards.tooltip_text = tr("Instead of action points, each turn draws a hand of four cards from the hero's spells and plays at most two of them. Rare spells come up less often.")
	_cards.toggled.connect(func(on: bool) -> void: session.configure("cards", on))
	box.add_child(_cards)
	_friendly_fire = CheckButton.new()
	_friendly_fire.name = "FriendlyFire"
	_friendly_fire.text = tr("Friendly fire")
	_friendly_fire.tooltip_text = tr("Spells that hurt (damage, harmful statuses) also hit your own team, and you can hit yourself with an area. Off: they only hit enemies.")
	_friendly_fire.toggled.connect(func(on: bool) -> void: session.configure("friendly_fire", on))
	box.add_child(_friendly_fire)
	_spirits = CheckButton.new()
	_spirits.name = "Spirits"
	_spirits.text = tr("Spirits")
	_spirits.tooltip_text = tr("A fallen hero keeps its turns as a spirit: once a turn, it curses or roots an enemy, or reveals hidden ones. Off: the fallen only watch.")
	_spirits.toggled.connect(func(on: bool) -> void: session.configure("spirits", on))
	box.add_child(_spirits)
	_settings_fields = [_typology, _size, _seed, new_seed, _turn, _grace, _cards, _friendly_fire, _spirits]


## Invite players: the room code and the link to it.
func _build_invite(parent: Control) -> void:
	var box := NetUi.card(parent, tr("Invite players"))
	_room_label = Label.new()
	_room_label.name = "RoomCode"
	_room_label.theme_type_variation = &"HeaderLabel"
	_room_label.hide()
	box.add_child(_room_label)
	var share := HBoxContainer.new()
	share.add_theme_constant_override("separation", 8)
	box.add_child(share)
	_copy_room = HubStyle.button("Copy the invite link", "CopyRoom")
	_copy_room.custom_minimum_size = Vector2(0, 44)
	_copy_room.pressed.connect(func() -> void: WebPage.copy(_room_link))
	_copy_room.hide()
	share.add_child(_copy_room)
	_copy_room_code = HubStyle.button("Copy the room code", "CopyRoomCode")
	_copy_room_code.custom_minimum_size = Vector2(0, 44)
	_copy_room_code.pressed.connect(func() -> void: WebPage.copy(_room_code))
	_copy_room_code.hide()
	share.add_child(_copy_room_code)


func _spin(low: int, high: int, node_name: String) -> SpinBox:
	var spin := SpinBox.new()
	spin.name = node_name
	spin.min_value = low
	spin.max_value = high
	spin.step = 1
	return spin


func _labelled(text: String, control: Control, parent: Control) -> void:
	var label := Label.new()
	label.theme_type_variation = &"SmallLabel"
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.text = text
	parent.add_child(label)
	parent.add_child(control)


static func _typology_name(file: String) -> String:
	return TranslationServer.translate(file.replace("_", " ").capitalize())


# --- Showing the lobby ----------------------------------------------------------------------

func refresh() -> void:
	if session == null:
		return
	var state := session.state
	var is_host := session.is_host()
	var in_lobby := state.phase == MatchState.Phase.LOBBY
	_refresh_seat(in_lobby)
	_refresh_teams(in_lobby)
	_refresh_settings(is_host and in_lobby)
	_start.visible = is_host and in_lobby
	_new_lobby.visible = is_host and not in_lobby and state.is_over()
	_start.disabled = not in_lobby or not state.start_problem().is_empty()
	_start.tooltip_text = state.start_problem()
	if session.connection_lost:
		_banner.text = tr("Nobody else is connected: the others left, or your own connection broke.")
	elif not _refusal.is_empty():
		_banner.text = _refusal
	elif not in_lobby:
		_banner.text = tr("The match is over: waiting for the host to open a new lobby.") if state.is_over() else tr("The match is going on.")
	elif not is_host:
		_banner.text = tr("Waiting for the host to start. Pick your hero and your team, then press Ready.")
	else:
		var problem := state.start_problem()
		_banner.text = tr("You are the host: start when everyone is ready.") if problem.is_empty() else tr("You are the host. Not ready to start yet: %s.") % problem


## A change the host refused (a full team, say): the screen goes back to what the match says and tells why.
func _on_rejected(reason: String) -> void:
	_refusal = reason.capitalize() if reason == reason.to_lower() else reason
	_hero_shown = -1
	refresh()
	get_tree().create_timer(4.0).timeout.connect(func() -> void:
		_refusal = ""
		refresh())


func _rename(text: String) -> void:
	var mine := session.state.seats.get(session.my_id) as MatchState.Seat
	var clean := text.strip_edges()
	if mine != null and not clean.is_empty() and clean != mine.name:
		NetUi.save_name(clean)
		session.set_field("name", clean)


func _refresh_seat(in_lobby: bool) -> void:
	var me := session.state.seats.get(session.my_id) as MatchState.Seat
	_seat_card.visible = in_lobby and me != null
	if me == null:
		return
	if not _name_edit.has_focus():
		_name_edit.text = me.name
	if _hero_shown != me.hero or _hero_row.get_child_count() == 0:
		_hero_shown = me.hero
		HubStyle.clear_children(_hero_row)
		var group := ButtonGroup.new()
		for index in PvpHeroes.hero_count():
			var card := NetUi.hero_card(index, index == me.hero, _on_hero_picked)
			card.button_group = group
			_hero_row.add_child(card)
	_ready.set_pressed_no_signal(me.ready)
	_ready.disabled = me.side < 0
	_ready.tooltip_text = tr("Pick a team first") if me.side < 0 else ""


func _on_hero_picked(index: int) -> void:
	NetUi.save_hero(index)
	session.set_field("hero", index)


## The two teams, side by side: who is on each, with their hero and what they are doing; the players who have not
## chosen a team yet are under them. The host can remove anyone but themself.
func _refresh_teams(in_lobby: bool) -> void:
	for side in 2:
		HubStyle.clear_children(_team_boxes[side])
		var seats := session.state.seats_on(side)
		var mine := session.state.seats.get(session.my_id) as MatchState.Seat
		var title := "%s  (%d/%d)" % [NetUi.side_name(side), seats.size(), MatchState.MAX_PER_SIDE]
		if mine != null and mine.side == side:
			title += "  ·  " + tr("your team")
		_team_titles[side].text = title
		_team_titles[side].tooltip_text = tr("Click to join this team") if in_lobby else ""
		_team_titles[side].disabled = not in_lobby
		_team_cards[side].mouse_filter = Control.MOUSE_FILTER_STOP if in_lobby else Control.MOUSE_FILTER_PASS
		if seats.is_empty():
			NetUi.note(_team_boxes[side], tr("Nobody yet."))
		for seat in seats:
			_add_seat_row(_team_boxes[side], seat, in_lobby, NetUi.SIDE_COLORS[side])
	HubStyle.clear_children(_unassigned_box)
	var waiting := session.state.seats_on(-1)
	_unassigned_card.visible = not waiting.is_empty()
	for seat in waiting:
		_add_seat_row(_unassigned_box, seat, in_lobby, Color(0.8, 0.8, 0.85))


func _add_seat_row(parent: Control, seat: MatchState.Seat, in_lobby: bool, color: Color) -> void:
	var line := HBoxContainer.new()
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE  # (a team card is hovered and clicked as a whole)
	parent.add_child(line)
	var row := Label.new()
	row.name = "Seat%d" % seat.id
	row.text = _seat_text(seat, in_lobby)
	row.add_theme_color_override("font_color", color)
	row.clip_text = true
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(row)
	if session.is_host() and in_lobby and seat.id != session.my_id:
		var kick := HubStyle.button("Remove", "Kick%d" % seat.id)
		kick.tooltip_text = tr("Remove this player from the match: they cannot come back.")
		kick.pressed.connect(func() -> void: session.kick(seat.id))
		line.add_child(kick)


func _seat_text(seat: MatchState.Seat, in_lobby: bool) -> String:
	var text := "%s: %s" % [seat.name, PvpHeroes.hero_name(seat.hero)]
	if seat.id == session.my_id:
		text += " " + tr("(you)")
	if seat.id == session.host_id:
		text += " " + tr("(host)")
	if not seat.connected:
		text += " " + tr("(away)")
	if seat.ready and in_lobby:
		text += " · " + tr("ready")
	return text


func _refresh_settings(editable: bool) -> void:
	var settings := session.state.settings
	_typology.select(MatchState.TYPOLOGIES.find(settings["typology"]))
	_size.set_value_no_signal(settings["size"])
	if not _seed.has_focus():
		_seed.text = str(settings["seed"])
	_turn.set_value_no_signal(settings["turn"])
	_grace.set_value_no_signal(settings["grace"])
	_cards.set_pressed_no_signal(bool(settings.get("cards", false)))
	_friendly_fire.set_pressed_no_signal(bool(settings.get("friendly_fire", true)))
	_spirits.set_pressed_no_signal(bool(settings.get("spirits", true)))
	for field in _settings_fields:
		if field is OptionButton:
			(field as OptionButton).disabled = not editable
		elif field is SpinBox:
			(field as SpinBox).editable = editable
		elif field is LineEdit:
			(field as LineEdit).editable = editable
		elif field is Button:
			(field as Button).disabled = not editable
	var key := "%s/%d/%d" % [settings["typology"], settings["size"], settings["seed"]]
	if key != _preview_key:
		_preview_key = key
		var typology := load("res://data/maps/typologies/%s.tres" % settings["typology"]) as MapTypology
		_preview.show_map(PvpMap.generate(int(settings["seed"]), typology, int(settings["size"])))


func _on_seed_text(text: String) -> void:
	if session.is_host() and text.is_valid_int() and int(text) != int(session.state.settings["seed"]):
		session.configure("seed", int(text))


## The room code, to read out or copy (anyone who has it can join).
func show_room(code: String, link: String) -> void:
	_room_code = RoomCode.pretty(code)
	_room_link = link
	_room_label.text = tr("Room code: %s") % RoomCode.pretty(code)
	_room_label.show()
	_copy_room_code.show()
	_copy_room.show()

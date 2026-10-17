class_name NetBattleController
extends BattleController
## The multiplayer fight, on the same screen as every other battle. The battle itself lives in the
## MatchSession (the replicated log); this view keeps its own copy of the battle and animates what the
## log brings, one entry at a time: placement moves, the first turn, moves and casts, whoever made
## them. What the local player does becomes a proposal to the host; nothing changes on screen until
## the host's entry comes back. A hero played by the AI, or by a player who left, is simply a turn
## that is not mine: the screen waits and watches.

var session: MatchSession

var _queue: Array[Dictionary] = []
## The log entry (its number) this view has applied up to.
var _applied := 0
## Whether the local player's action is on its way to the host and back.
var _awaiting := false
## Whether an entry is being played (the next waits for it).
var _busy := false
## The player pressed Ready for their placement.
var _placed_pressed := false
## My turn was announced (window, tab title), and the last second its clock ticked for (-1: none yet).
var _turn_cued := false
var _warned_second := -1
## The line about my own connection is shown once per loss.
var _lost_shown := false
## The button above End turn and the popup of quick messages it opens (a catcher for the clicks around, with the list).
var _say_button: Button
var _say_popup: Control
## The button above it that starts pointing something out (a toggle: on while the next click marks).
var _point_button: Button
## The next board click points something out (after the Point out button); the Point out key does it at once.
var _marking := false
## Where the mouse last was (every motion, HUD or board): where the Point out key marks.
var _mouse_at := Vector2.ZERO
## Each teammate's mark on the board (a seat id → its BoardMark, possibly freed once it faded out): a new one replaces
## the previous.
var _marks: Dictionary[int, Object] = {}
## The last quick messages and marks, as lines on the left (a fallen hero has no head to put a bubble over).
var _feed: VBoxContainer

const SAY_ICON: Texture2D = preload("res://ui/icons/speech.svg")
const POINT_ICON: Texture2D = preload("res://ui/icons/pin.svg")
## Seconds left on my turn when its clock starts ticking (a sound each second; the countdown turns red at 10 already).
const TURN_WARNING_SECONDS := 5
## How many lines the feed keeps, and how long each stays.
const FEED_LINES := 5
const FEED_SECONDS := 8.0
## The ring of a mark on the board, and its line in the feed.
const MARK_COLOR := Color(1.0, 0.85, 0.3)
## A spirit's action in the feed.
const SPIRIT_COLOR := Color(0.8, 0.6, 1.0)


## Call before the controller enters the tree.
func setup_net(match_session: MatchSession) -> void:
	session = match_session
	standalone = false
	sudden_death_round = MatchState.SUDDEN_DEATH_ROUND
	sudden_death_percent = MatchState.SUDDEN_DEATH_PERCENT
	battle_seed = int(session.state.settings["seed"])


func _ready() -> void:
	super._ready()
	hud.set_result_action_text("Back to the lobby")
	session.entry_applied.connect(_on_entry)
	session.rejected.connect(_on_rejected)
	session.emote_received.connect(_on_emote)
	session.mark_received.connect(_on_mark)
	session.changed.connect(_on_session_changed)
	_build_say_popup()
	_build_feed()
	_catch_up()


## Each player watches at their own speed (x2 by default): the playback is local, and the turn clock gives back what it
## took (MatchSession.turn_shown), so a slower screen costs its player nothing. The solo setting is left alone.
func _battle_speed() -> Settings.BattleSpeed:
	return settings.net_battle_speed


func cycle_battle_speed() -> void:
	settings.net_battle_speed = ((settings.net_battle_speed + 1) % Settings.BattleSpeed.size()) as Settings.BattleSpeed
	apply_battle_speed()
	speed_changed.emit()


## The spell bar (or the hand) shows my own hero, whoever's turn it is: other players' spells aren't mine to look at.
func _spells_unit_id() -> int:
	var mine := _my_unit()
	return mine if mine >= 0 and mine < battle.state.units.size() else super._spells_unit_id()


## The seconds left on the turn (or on the placement), after the round at the top.
func _process(delta: float) -> void:
	super._process(delta)
	var left := session.placement_seconds_left()
	if left < 0.0:
		left = session.turn_seconds_left()
	hud.set_countdown(ceili(left) if left >= 0.0 else -1)
	# The last seconds of my turn tick, one sound a second.
	if _turn_cued and left > 0.0 and left <= TURN_WARNING_SECONDS and ceili(left) != _warned_second:
		_warned_second = ceili(left)
		sound.emit(&"turn_warning")


func _on_session_changed() -> void:
	if session.connection_lost and not _lost_shown:
		_lost_shown = true
		hud.show_banner(tr("Nobody else is connected: the others left, or your own connection broke."))
	elif not session.connection_lost:
		_lost_shown = false


func _create_battle_state() -> BattleState:
	var made := session.state.make_battle()
	return made.state if made != null else null


## The start zone the local player's hero places in (its side's), highlighted while placing.
func _placement_zone() -> Array[Vector2i]:
	return _zone_of(_my_unit())


func _placement_zone_for_camera(battle_state: BattleState) -> Array[Vector2i]:
	var mine := session.unit_of(session.my_id)
	if mine >= 0 and mine < battle_state.units.size() and battle_state.units[mine].team == UnitState.Team.ENEMY:
		return battle_state.zone_enemy
	return battle_state.zone


func _zone_of(unit_id: int) -> Array[Vector2i]:
	if unit_id < 0 or battle == null:
		return battle.state.zone if battle != null else []
	return battle.state.zone if battle.state.units[unit_id].team == UnitState.Team.PLAYER else battle.state.zone_enemy


func _viewer_team() -> UnitState.Team:
	var mine := _my_unit()
	if mine >= 0 and battle != null and mine < battle.state.units.size():
		return battle.state.units[mine].team
	return UnitState.Team.PLAYER


func _my_unit() -> int:
	return session.unit_of(session.my_id)


# --- The log, one entry at a time -----------------------------------------------------------

## A view that opens late (a returning player, or a late start) replays what already happened, without
## animation, then shows where things stand.
func _catch_up() -> void:
	var log := session.state.log
	var start := -1
	for index in log.size():
		if log[index]["k"] == "start":
			start = index
	_applied = start + 1
	for index in range(start + 1, log.size()):
		_apply_silently(log[index])
		_applied = index + 1
	_sync_labels()
	units_view.sync(battle.state)
	_begin_next()
	if battle.state.started:
		units_view.set_active(battle.state.current_unit().id if not battle.state.is_over() else -1)


func _apply_silently(entry: Dictionary) -> void:
	match entry["k"]:
		"act":
			var action := ActionCodec.decode(entry["a"])
			if action != null:
				battle.perform(action)
		"go":
			battle.start()


func _on_entry(entry: Dictionary) -> void:
	if int(entry["n"]) <= _applied or battle == null:
		return
	_queue.append(entry)
	_pump()


func _pump() -> void:
	if _busy:
		return
	while not _queue.is_empty():
		var entry: Dictionary = _queue.pop_front()
		_applied = int(entry["n"])
		if _play_entry(entry):
			return
	_begin_next()


## Applies one entry to this view's battle. True when events started playing (the next entry waits).
func _play_entry(entry: Dictionary) -> bool:
	match entry["k"]:
		"act":
			if entry.get("by") == session.my_id and entry.get("sys") != true:
				_awaiting = false
			var action := ActionCodec.decode(entry["a"])
			if action == null:
				return false
			var result := battle.perform(action)
			if not result.ok():
				push_error("NetBattle: the host's action doesn't fit this view: %s" % result.error)
				return false
			_busy = true
			_play(result.events)
			return true
		"go":
			_busy = true
			_play(battle.start())
			return true
		"ai", "join", "drop":
			_sync_labels()
			_refresh_hud()
	return false


func _sync_labels() -> void:
	for seat_id in session.state.seat_ids():
		var unit_id := session.unit_of(seat_id)
		if unit_id < 0 or unit_id >= battle.state.units.size():
			continue
		var seat := session.state.seats[seat_id]
		var tag := ""
		if seat.ai:
			tag = " " + tr("(AI)")
		elif not seat.connected:
			tag = " " + tr("(away)")
		battle.state.units[unit_id].label = seat.name + tag


## A quick message from a player: it floats above their hero's head (while it stands), and goes in the feed.
func _on_emote(seat_id: int, emote_id: int) -> void:
	var unit_id := session.unit_of(seat_id)
	var unit_view := units_view.find_view(unit_id)
	if unit_view != null and battle != null and unit_id < battle.state.units.size() and battle.state.units[unit_id].is_alive():
		unit_view.say(Emotes.text(emote_id))
	_add_feed_line(tr("%s: %s") % [_seat_name(seat_id), Emotes.text(emote_id)], Color.WHITE)


func _seat_name(seat_id: int) -> String:
	var seat := session.state.seats.get(seat_id) as MatchState.Seat
	return seat.name if seat != null else "?"


## Whether that seat plays on my side (a mark is for its own team only).
func _same_side(seat_id: int) -> bool:
	var mine := session.state.seats.get(session.my_id) as MatchState.Seat
	var theirs := session.state.seats.get(seat_id) as MatchState.Seat
	return mine != null and theirs != null and mine.side == theirs.side


# --- Marks on the board ---------------------------------------------------------------------

## The Point out key (G by default) marks the cell under the mouse at once; after the Point out button, a click on the
## board does (instead of its action). Living or fallen, on my turn or not.
func _unhandled_input(event: InputEvent) -> void:
	if battle != null and event.is_action_pressed(&"mark") and not event.is_echo():
		if get_viewport().gui_get_hovered_control() == null:  # Over the HUD there is no cell to point at.
			var cell := board_view.pick_cell(camera_rig.camera, _mouse_at)
			if cell != BoardView.NO_CELL:
				mark_cell(cell)
		get_viewport().set_input_as_handled()
		return
	var button := event as InputEventMouseButton
	if _marking and button != null and button.button_index == MOUSE_BUTTON_LEFT and button.pressed and battle != null:
		var cell := board_view.pick_cell(camera_rig.camera, button.position)
		if cell != BoardView.NO_CELL:
			mark_cell(cell)
			get_viewport().set_input_as_handled()
			return
	super._unhandled_input(event)


func _input(event: InputEvent) -> void:
	if event is InputEventMouse:
		_mouse_at = (event as InputEventMouse).position
	super._input(event)


func click_cell(cell: Vector2i) -> void:
	if battle != null and _marking:
		mark_cell(cell)
		return
	super.click_cell(cell)


func cancel() -> void:
	if _marking:
		_set_marking(false)
	else:
		super.cancel()


func _set_marking(on: bool) -> void:
	_marking = on
	if _point_button != null:
		_point_button.set_pressed_no_signal(on)
	hud.set_prompt(_prompt_text())


## Sends my mark on `cell` ("Here!", for my team).
func mark_cell(cell: Vector2i) -> void:
	_set_marking(false)
	session.send_mark(cell)


## A player's mark: a ring and "Here!" on the cell, for their own team only (and in the feed).
func _on_mark(seat_id: int, cell: Vector2i) -> void:
	if battle == null or not _same_side(seat_id) or not battle.state.grid.in_bounds(cell):
		return
	var previous: Variant = _marks.get(seat_id)  # Untyped: a mark that faded out on its own is a freed object here.
	if is_instance_valid(previous):
		(previous as BoardMark).queue_free()
	var text := tr("%s: Here!") % _seat_name(seat_id)
	var height := 1.2
	var unit := battle.state.unit_at(cell)
	if unit != null and not battle.state.is_hidden_from(unit, units_view.viewer_team) and units_view.find_view(unit.id) != null:
		height = units_view.find_view(unit.id).world_height() + 0.6  # Above the head (and its status icons).
	var mark := BoardMark.new(text, MARK_COLOR, height)
	mark.position = board_view.cell_to_world(cell)
	add_child(mark)
	_marks[seat_id] = mark
	_add_feed_line(text, MARK_COLOR)


func _build_feed() -> void:
	_feed = VBoxContainer.new()
	_feed.name = "Feed"
	_feed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_feed.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_feed.position = Vector2(12.0, 120.0)
	hud.get_node("Root").add_child(_feed)


func _add_feed_line(text: String, color: Color) -> void:
	var line := Label.new()
	line.text = text
	line.theme_type_variation = &"SmallLabel"
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_theme_color_override("font_color", color)
	line.add_theme_color_override("font_outline_color", Color(0.05, 0.05, 0.08))
	line.add_theme_constant_override("outline_size", 6)
	_feed.add_child(line)
	while _feed.get_child_count() > FEED_LINES:
		_feed.get_child(0).free()
	var fade := line.create_tween()
	fade.tween_interval(FEED_SECONDS)
	fade.tween_property(line, "modulate:a", 0.0, 0.6)
	fade.tween_callback(line.queue_free)


## The lines in the feed, oldest first.
func feed_texts() -> Array[String]:
	var texts: Array[String] = []
	for line in _feed.get_children():
		texts.append((line as Label).text)
	return texts


## A button above End turn opens the list of quick messages, in the middle of the screen.
func _build_say_popup() -> void:
	var actions := hud.get_node("Root/Actions") as Control
	_say_button = Button.new()
	_say_button.name = "SayButton"
	_say_button.text = tr("Say something")
	_say_button.icon = SAY_ICON
	_say_button.add_theme_constant_override("icon_max_width", 22)
	_say_button.focus_mode = Control.FOCUS_NONE
	_say_button.pressed.connect(_toggle_say_popup)
	actions.add_child(_say_button)
	actions.move_child(_say_button, hud.get_node("%EndTurnButton").get_index())
	# Above it, the way to marks that a player who doesn't know the key finds (and the only one on a tablet).
	_point_button = Button.new()
	_point_button.name = "PointButton"
	_point_button.text = tr("Point out (%s)") % SettingsApplier.key_text(&"mark")
	_point_button.tooltip_text = tr("Then click a cell or a unit: your team sees a mark there. Faster: the key, with the mouse over it")
	_point_button.icon = POINT_ICON
	_point_button.add_theme_constant_override("icon_max_width", 22)  # A fixed size: the longest text sets the column's width.
	_point_button.toggle_mode = true
	_point_button.focus_mode = Control.FOCUS_NONE
	_point_button.toggled.connect(_set_marking)
	actions.add_child(_point_button)
	actions.move_child(_point_button, _say_button.get_index())
	_say_popup = Control.new()
	_say_popup.name = "SayPopup"
	_say_popup.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_say_popup.visible = false
	_say_popup.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed:
			_say_popup.hide())  # A click anywhere else closes it.
	var panel := PanelContainer.new()
	panel.name = "SayPanel"
	panel.theme_type_variation = &"Chip"
	_say_popup.add_child(panel)
	var list := VBoxContainer.new()
	panel.add_child(list)
	for index in Emotes.count():
		var emote := Button.new()
		emote.name = "Emote%d" % index
		emote.text = Emotes.text(index)
		emote.focus_mode = Control.FOCUS_NONE
		emote.pressed.connect(func() -> void:
			session.send_emote(index)
			_say_popup.hide())
		list.add_child(emote)
	hud.get_node("Root").add_child(_say_popup)


func _toggle_say_popup() -> void:
	if _say_popup.visible:
		_say_popup.hide()
		return
	_say_popup.show()
	var panel := _say_popup.get_node("SayPanel") as Control
	panel.size = panel.get_combined_minimum_size()
	panel.position = ((_say_popup.size - panel.size) / 2.0).floor()  # In the middle of the screen.


func _on_rejected(reason: String) -> void:
	_awaiting = false
	push_warning("NetBattle: refused: %s" % reason)
	hud.show_banner(tr("That isn't possible right now."))
	if not _busy:
		_begin_next()


# --- Turns ----------------------------------------------------------------------------------

func _begin_next() -> void:
	_busy = false
	_refresh_hud()
	if not _queue.is_empty():
		_pump()
		return
	var battle_state := battle.state
	if not battle_state.started:
		_set_state(State.PLACING)
		return
	units_view.set_active(battle_state.current_unit().id if not battle_state.is_over() else -1)
	if battle_state.is_over():
		_finish()
	elif _awaiting:
		_set_state(State.ANIMATING)  # My action is on its way: nothing to do until it comes back.
	elif session.controls_unit(battle_state.current_unit().id):
		_enter_idle()
		session.turn_shown(battle_state.current_unit().id)  # The clock gives back what the playback took.
		_cue_my_turn()
	else:
		_set_state(State.ENEMY_TURN)  # Someone else's turn (a player, or the AI): watch.
		_end_turn_cue()


## My turn has come and the screen is mine: a sound, and a player who looks elsewhere is called back (the window asks
## for attention, the browser tab's title says so). Once per turn.
func _cue_my_turn() -> void:
	if _turn_cued:
		return
	_turn_cued = true
	_warned_second = -1
	sound.emit(&"your_turn")
	if not DisplayServer.window_is_focused():
		DisplayServer.window_request_attention()
		WebPage.set_title_alert(tr("Your turn!"))


func _end_turn_cue() -> void:
	if _turn_cued:
		_turn_cued = false
		WebPage.set_title_alert("")


## Back on the game: the tab's title has said what it had to.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN or what == NOTIFICATION_EXIT_TREE:
		WebPage.set_title_alert("")


func _finish() -> void:
	_end_turn_cue()
	var mine := session.state.seats.get(session.my_id) as MatchState.Seat
	var my_team := UnitState.Team.PLAYER if mine == null or mine.side == 0 else UnitState.Team.ENEMY
	var outcome := battle.state.outcome()
	_finish_battle((outcome == BattleState.Outcome.PLAYER_WON and my_team == UnitState.Team.PLAYER) \
			or (outcome == BattleState.Outcome.ENEMY_WON and my_team == UnitState.Team.ENEMY))


func _set_state(new_state: State) -> void:
	if new_state == State.PLACING:
		_placing_hero = _my_unit()
	super._set_state(new_state)
	if new_state == State.PLACING and _placed_pressed:
		hud.set_player_controls_enabled(false)  # Ready was pressed: nothing more to do but wait.


func _turn_banner_text(unit: UnitState) -> String:
	if unit.spirit:
		return tr("Your spirit's turn!") if session.controls_unit(unit.id) else tr("%s's spirit") % unit.label
	if session.controls_unit(unit.id):
		return tr("Your turn!")
	return tr("%s's turn") % unit.label


## A spirit's action is told to everyone, at the top and in the feed: who did what to whom.
func _event_seen(event: BattleEvents.Event) -> void:
	var cast := event as BattleEvents.SpellCast
	if cast == null or battle == null or not battle.state.units[cast.caster_id].spirit:
		return
	var caster := battle.state.units[cast.caster_id]
	var target := battle.state.unit_at(cast.target)
	var text := tr("%s's spirit: %s") % [caster.label, tr(cast.spell.display_name)]
	if target != null and not battle.state.is_hidden_from(target, units_view.viewer_team):
		text = tr("%s's spirit: %s on %s") % [caster.label, tr(cast.spell.display_name), target.label]
	hud.show_banner(text)
	_add_feed_line(text, SPIRIT_COLOR)


func _prompt_text() -> String:
	if _marking:
		return tr("Click a cell or a unit to point it out to your team (Esc to cancel)")
	if input_state == State.IDLE and battle.state.started and battle.state.current_unit().spirit:
		return tr("Your spirit: one spell anywhere on the board (%s), or pass (%s)") % [
				_spell_keys_text(_spell_slot_count()), SettingsApplier.key_text(&"end_turn")]
	if input_state == State.PLACING:
		if _placed_pressed:
			return tr("Ready. Waiting for the other players...")
		return tr("Click a teal cell to place your hero, then press Ready (%s)") % SettingsApplier.key_text(&"end_turn")
	if input_state == State.ENEMY_TURN and battle.state.started and not battle.state.is_over():
		var seat_id := session.state.seat_of_unit(battle.state.current_unit().id)
		var seat := session.state.seats.get(seat_id) as MatchState.Seat
		if seat != null and not seat.connected and not seat.ai:
			return tr("%s is away: the AI takes over soon") % seat.name
		# Waiting is when a player has time to point things out: say how.
		return super._prompt_text() + "  ·  " + tr("%s: point out to your team what is under the mouse") % SettingsApplier.key_text(&"mark")
	return super._prompt_text()


# --- What the local player does -------------------------------------------------------------

func _perform(action: BattleActions.Action) -> void:
	_awaiting = true
	session.act(action)
	if _awaiting and not _busy:  # It hasn't come back yet (it never does at once for a guest).
		_set_state(State.ANIMATING)


## Ready: tell the host my hero is placed, then wait for the others.
func _press_ready() -> void:
	if _placed_pressed:
		return
	_placed_pressed = true
	session.set_placed(true)
	_set_state(State.PLACING)


## Placement is my own hero only: a click in my side's zone puts it there.
func _click_placing(cell: Vector2i) -> void:
	if not _placed_pressed and cell in _zone_of(_my_unit()):
		_perform(BattleActions.Place.new(_my_unit(), cell))


func _placing_click_action(cell: Vector2i, _clicked: UnitState) -> int:
	return Tutorial.Action.PLACE if not _placed_pressed and cell in _zone_of(_my_unit()) else -1

class_name NetSandbox
extends Node
## A multiplayer fight without the relay, the front page or the lobby: every seat is a MatchSession in this one
## process, on a MemoryNetwork (the tests' fake network), and the match starts at once with the classes and rules
## given on the command line. The screen is the real NetBattleController of one seat; the seat bar at the top left
## switches to another (in AI mode the seat you leave goes to the AI and the one you take is yours).
##
## `godot scenes/tools/net_sandbox.tscn -- players=4 blue=2 heroes=knight,rogue,priestess,ranger`
## Options: players (2-12), blue (players on the blue side, default half), heroes (names or numbers, in seat order,
## repeated), cards=1, ff=0 (no friendly fire), map (open_field, mountain, crater, islands, canyon, ruins), size, seed,
## turn (seconds), seat (the one you start on), others=ai|human, follow=1 (hot seat: the screen follows the turn; with
## others=human you play every seat), placed=1 (skip your placement too), spirits=0 (the lobby rule off), aidelay (seconds between the AI's actions,
## 2.5 by default: time to send marks and messages during its turns). P (or the seat bar's AI button) holds the AI: it
## waits until P again, so the others' turns can be looked at as long as needed.
## Like the game: the player's own settings (volumes, mute, keys, speeds; saved when changed), the sounds and the battle
## music, and the round buttons at the top right (sound, settings over the fight, the fight's menu).

const BATTLE_SCENE := preload("res://scenes/net/net_battle.tscn")
const SETTINGS_SCENE := preload("res://scenes/game/settings_screen.tscn")
const AUDIO_SET := preload("res://data/audio/audio_set.tres")

var options := {
	"players": 2, "blue": -1, "heroes": "", "cards": false, "ff": true, "map": "open_field", "size": 14, "seed": 1,
	"turn": 30, "seat": 1, "others": "ai", "follow": false, "placed": false, "aidelay": 2.5, "spirits": true,
}

## The AI's wait while it is held: it never comes.
const HELD_AI_DELAY := 1.0e9

var net := MemoryNetwork.new()
var sessions: Dictionary[int, MatchSession] = {}
var settings := Settings.new()
## Read the player's saved settings at start (tests keep their own).
var load_saved_settings := true
var audio: AudioService
## The seat whose screen is shown.
var viewing := 0
var battle: NetBattleController

var _seat_bar: HBoxContainer
var _top_bar: TopBar
var _settings_layer: CanvasLayer
var _settings_store := SettingsStore.new(SettingsStore.DEFAULT_PATH)
var _hold_button: Button
var _ai_held := false


func _ready() -> void:
	_read_arguments()
	if load_saved_settings:
		settings = _settings_store.load_or_default()
	SettingsApplier.apply(settings, get_window(), false)
	audio = AudioService.new()
	audio.audio_set = AUDIO_SET
	add_child(audio)
	audio.hook_buttons(get_tree())
	if not open_match():
		return
	audio.play_music(&"battle")
	_build_seat_bar()
	_build_top_bar()
	view_seat(clampi(int(options["seat"]), 1, sessions.size()))


func _read_arguments() -> void:
	for argument in OS.get_cmdline_user_args():
		var parts := argument.split("=", true, 1)
		if parts.size() < 2 or not options.has(parts[0]):
			continue
		var current: Variant = options[parts[0]]
		if current is bool:
			options[parts[0]] = parts[1] == "1" or parts[1] == "true"
		elif current is int:
			options[parts[0]] = int(parts[1])
		elif current is float:
			options[parts[0]] = float(parts[1])
		else:
			options[parts[0]] = parts[1]


## The match as the options say, started and placed (but for the viewed seat, unless `placed`). False (with an
## error) when the options don't make a match.
func open_match() -> bool:
	var total := clampi(int(options["players"]), 2, 12)
	var blue := int(options["blue"]) if int(options["blue"]) > 0 else (total + 1) / 2
	blue = clampi(blue, 1, total - 1)
	var heroes := _hero_indexes(str(options["heroes"]), total)
	if heroes.is_empty():
		return false
	for id in range(1, total + 1):
		if id == 1:
			sessions[id] = MatchSession.open_as_host(net.transport(id), "Seat 1", "sandbox-1")
		else:
			for other in sessions.keys():
				net.connect_peers(id, other)
			sessions[id] = MatchSession.open_as_guest(net.transport(id), "Seat %d" % id, "sandbox-%d" % id, 1)
		net.flush()
	for id in sessions:
		sessions[id].set_field("side", 0 if id <= blue else 1)
		sessions[id].set_field("hero", heroes[id - 1])
	var host := sessions[1]
	host.ai_delay = maxf(0.0, float(options["aidelay"]))
	host.configure("typology", str(options["map"]))
	host.configure("size", int(options["size"]))
	host.configure("seed", int(options["seed"]))
	host.configure("turn", int(options["turn"]))
	host.configure("cards", bool(options["cards"]))
	host.configure("friendly_fire", bool(options["ff"]))
	host.configure("spirits", bool(options["spirits"]))
	net.flush()
	for id in sessions:
		sessions[id].set_ready(true)
	net.flush()
	host.start_match()
	net.flush()
	if host.state.battle == null:
		push_error("NetSandbox: the match didn't start (check map=, size=, heroes=)")
		return false
	var mine := clampi(int(options["seat"]), 1, total)
	for id in sessions:
		if id != mine or bool(options["placed"]):
			sessions[id].set_placed(true)
		if id != mine and str(options["others"]) == "ai":
			sessions[id].hand_to_ai(true)
	net.flush()
	return true


## Hero numbers for `total` seats from "knight,3,rogue" (names or numbers, repeated); empty: every class in turn.
func _hero_indexes(text: String, total: int) -> Array[int]:
	var picked: Array[int] = []
	for word in text.split(",", false):
		var index := _hero_index(word.strip_edges())
		if index == -1:
			push_error("NetSandbox: no class named '%s' (%s)" % [word, ", ".join(_hero_names())])
			return []
		picked.append(index)
	var result: Array[int] = []
	for seat in total:
		result.append(picked[seat % picked.size()] if not picked.is_empty() else seat % PvpHeroes.hero_count())
	return result


func _hero_index(word: String) -> int:
	if word.is_valid_int():
		var number := int(word)
		return number if number >= 0 and number < PvpHeroes.hero_count() else -1
	return _hero_names().find(word.to_lower())


func _hero_names() -> Array[String]:
	var names: Array[String] = []
	for index in PvpHeroes.hero_count():
		names.append(PvpHeroes.hero(index).display_name().to_lower())  # English, whatever the language.
	return names


## Holds the AI (it waits before its next action until let go), or lets it play again.
func hold_ai(held: bool) -> void:
	_ai_held = held
	sessions[1].ai_delay = HELD_AI_DELAY if held else maxf(0.0, float(options["aidelay"]))
	if _hold_button != null:
		_hold_button.set_pressed_no_signal(held)
		_hold_button.text = "AI held (P)" if held else "AI plays (P)"


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_P:
		hold_ai(not _ai_held)
		get_viewport().set_input_as_handled()


## Real seconds for every session (the fight may play fast), then the messages between them.
func _process(delta: float) -> void:
	var real := delta / Engine.time_scale if Engine.time_scale > 0.0 else delta
	for id in sessions:
		sessions[id].tick(real)
	net.flush()
	if bool(options["follow"]) and battle != null and battle.input_state == BattleController.State.ENEMY_TURN:
		var turn := sessions[1].state.current_seat()
		if turn > 0 and turn != viewing and not sessions[1].state.seats[turn].ai:
			view_seat(turn)


## Shows that seat's screen. In AI mode the seat left goes to the AI and the seat taken comes back to its player.
func view_seat(seat_id: int) -> void:
	if not sessions.has(seat_id):
		return
	if str(options["others"]) == "ai" and viewing != 0 and viewing != seat_id:
		sessions[viewing].hand_to_ai(true)
		sessions[seat_id].hand_to_ai(false)
		net.flush()
	viewing = seat_id
	if battle != null:
		battle.free()
	battle = BATTLE_SCENE.instantiate() as NetBattleController
	battle.setup_net(sessions[seat_id])
	battle.settings = settings
	battle.sound.connect(audio.play_sfx)
	battle.speed_changed.connect(_save_settings)
	battle.battle_finished.connect(func(_state: BattleState) -> void: get_tree().reload_current_scene())
	battle.left_battle.connect(func() -> void: get_tree().reload_current_scene())
	add_child(battle)
	_refresh_seat_bar()


## The game's round buttons, at the top right: sound, the settings over the fight (a match never pauses), the menu.
func _build_top_bar() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 100
	add_child(layer)
	_top_bar = TopBar.new()
	layer.add_child(_top_bar)
	_top_bar.mute_button.show_muted(settings.muted)
	_top_bar.mute_button.toggled.connect(func(muted: bool) -> void:
		settings.muted = muted
		_save_settings())
	_top_bar.settings_requested.connect(open_settings)
	_top_bar.menu_requested.connect(func() -> void: battle.open_menu())
	_top_bar.show_settings(true)
	_top_bar.show_menu(true)


func open_settings() -> void:
	if _settings_layer != null:
		return
	_settings_layer = CanvasLayer.new()
	_settings_layer.layer = 50
	add_child(_settings_layer)
	var screen := SETTINGS_SCENE.instantiate() as SettingsScreen
	screen.in_match = true
	_settings_layer.add_child(screen)
	screen.show_settings(settings)
	screen.audio_live.connect(func() -> void: SettingsApplier.apply_audio(settings))
	screen.changed.connect(_save_settings)
	screen.back_pressed.connect(func() -> void:
		_settings_layer.queue_free()
		_settings_layer = null
		_top_bar.show_settings(true))
	_top_bar.show_settings(false)


func _save_settings() -> void:
	SettingsApplier.apply(settings, get_window())
	if _top_bar != null:
		_top_bar.mute_button.show_muted(settings.muted)
	if load_saved_settings:
		_settings_store.save(settings)


func _build_seat_bar() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)
	_seat_bar = HBoxContainer.new()
	_seat_bar.name = "SeatBar"
	_seat_bar.position = Vector2(12.0, 8.0)
	layer.add_child(_seat_bar)
	for id in sessions:
		var seat := sessions[1].state.seats[id]
		var button := Button.new()
		button.name = "Seat%d" % id
		button.toggle_mode = true
		button.focus_mode = Control.FOCUS_NONE
		button.text = "%d %s" % [id, PvpHeroes.hero_name(seat.hero)]
		button.add_theme_color_override("font_color", Color(0.55, 0.75, 1.0) if seat.side == 0 else Color(1.0, 0.55, 0.5))
		button.pressed.connect(view_seat.bind(id))
		_seat_bar.add_child(button)
	_hold_button = Button.new()
	_hold_button.name = "HoldAI"
	_hold_button.toggle_mode = true
	_hold_button.focus_mode = Control.FOCUS_NONE
	_hold_button.toggled.connect(hold_ai)
	_seat_bar.add_child(_hold_button)
	hold_ai(_ai_held)


func _refresh_seat_bar() -> void:
	if _seat_bar == null:
		return
	for button: Button in _seat_bar.get_children():
		if button != _hold_button:
			button.set_pressed_no_signal(button.name == "Seat%d" % viewing)

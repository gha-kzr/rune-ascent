class_name Hud
extends CanvasLayer
## Battle HUD, the controller's single entry point: it forwards to component scenes (turn
## timeline, full-order overlay, unit cards, spell bar) and owns the round label, actions,
## turn banner and result. The controller updates it with show_* calls (calls down) and
## listens to its signals (signals up); the HUD never reads or changes battle state itself.
##
## Buttons never take keyboard focus, so Space can't press a focused button; spells and
## End turn have keyboard shortcuts (1-9, the end_turn action) that respect disabled state.

signal spell_selected(index: int)
## Card combat: the player throws the card at this hand position away.
signal card_discarded(position: int)
## The spell under the mouse changed (null: none): one of the spell bar's (`on_bar`) or a row of the inspect card.
signal spell_hovered(spell: SpellData, on_bar: bool)
signal end_turn_pressed
signal view_toggle_pressed
## The speed button was pressed: the controller cycles the battle speed.
signal speed_pressed
## QA tools: Auto (the AI plays the heroes) was switched.
signal auto_toggled(on: bool)
## QA battles: a cheat was pressed (&"win", &"lose", &"kill", &"heal", &"refill").
signal qa_cheat(action: StringName)
## The tutorial's Skip link was pressed.
signal tutorial_skipped
signal restart_pressed
## A turn-order chip is hovered (unit id) or left, or clicked.
signal chip_hovered(unit_id: int)
signal chip_unhovered
signal chip_pressed(unit_id: int)
## The inspect card's ✕ was pressed.
signal card_closed
## The Recenter button (back to the acting unit).
signal recenter_pressed
## The player confirmed leaving the fight (Menu, then Leave).
signal leave_confirmed
## The hint card was dismissed (its button, or Enter).
signal hint_dismissed

const BANNER_FADE := 0.2
const BANNER_HOLD := 0.9
const END_TURN_PULSE_COLOR := Color(1.6, 1.5, 0.7)
const END_TURN_PULSE_TIME := 0.5

var _controls_enabled := true
var _placing := false
var _banner_tween: Tween
var _pulse_tween: Tween

@onready var _round_label: Label = %RoundLabel
var _round_text := ""
var _countdown := -1
@onready var _recenter_button: Button = %RecenterButton
@onready var _leave_panel: Control = %LeavePanel
@onready var _leave_button: Button = %LeaveButton
@onready var _stay_button: Button = %StayButton
@onready var _hint_card: HintCard = %HintCard
@onready var _prompt_label: Label = %PromptLabel
@onready var _timeline: TurnTimeline = %TurnTimeline
@onready var _order_overlay: OrderOverlay = %OrderOverlay
@onready var _active_card: UnitCard = %ActiveCard
@onready var _inspect_card: UnitCard = %InspectCard
@onready var _spell_bar: SpellBar = %SpellBar
@onready var _end_turn_button: Button = %EndTurnButton
@onready var _view_button: Button = %ViewButton
@onready var _speed_button: Button = %SpeedButton
var _auto_button: Button
var _qa_bar: VBoxContainer
var _tutorial: TutorialOverlay
@onready var _banner: Label = %Banner
@onready var _result_panel: Control = %ResultPanel
@onready var _result_label: Label = %ResultLabel
@onready var _restart_button: Button = %RestartButton
@onready var _seed_label: Label = %SeedLabel


func _ready() -> void:
	_end_turn_button.pressed.connect(end_turn_pressed.emit)
	_view_button.pressed.connect(view_toggle_pressed.emit)
	_speed_button.pressed.connect(speed_pressed.emit)
	_build_qa_controls()
	_tutorial = TutorialOverlay.new()
	_tutorial.skipped.connect(tutorial_skipped.emit)
	$Root.add_child(_tutorial)  # Last: above the rest of the HUD.
	_restart_button.pressed.connect(restart_pressed.emit)
	_spell_bar.spell_pressed.connect(spell_selected.emit)
	_spell_bar.discard_pressed.connect(card_discarded.emit)
	_spell_bar.spell_hovered.connect(spell_hovered.emit)
	_timeline.chip_hovered.connect(chip_hovered.emit)
	_timeline.chip_unhovered.connect(chip_unhovered.emit)
	_timeline.chip_pressed.connect(chip_pressed.emit)
	_timeline.order_button_pressed.connect(_order_overlay.toggle)
	# Shortcuts fire before GUI input, so the overlay's dim can't block them: lock the buttons.
	_order_overlay.opened.connect(_refresh_buttons)
	_order_overlay.closed.connect(_refresh_buttons)
	_order_overlay.unit_pressed.connect(chip_pressed.emit)  # Same as a timeline chip: look at it.
	_inspect_card.closed.connect(card_closed.emit)
	_hint_card.dismissed.connect(hint_dismissed.emit)
	_hint_card.visibility_changed.connect(_refresh_buttons)  # A shown hint is modal.
	_recenter_button.pressed.connect(recenter_pressed.emit)
	_recenter_button.text = tr("Recenter (%s)") % SettingsApplier.key_text(&"camera_recenter")
	_stay_button.pressed.connect(close_leave_panel)
	_leave_button.pressed.connect(func() -> void:
		close_leave_panel()
		leave_confirmed.emit())
	_leave_panel.hide()
	(_hint_card.get_node("%DismissButton") as Button).focus_mode = Control.FOCUS_NONE  # Space ends the turn here.
	# Spells listed on the inspect card show their details above the spell bar.
	_spell_bar.set_extra_targets(_inspect_card.spell_rows)
	var end_turn_shortcut := Shortcut.new()
	var end_turn_event := InputEventAction.new()
	end_turn_event.action = &"end_turn"
	end_turn_shortcut.events = [end_turn_event]
	_end_turn_button.shortcut = end_turn_shortcut
	_end_turn_button.text = _end_turn_text()
	set_overhead_view(false)
	_banner.modulate.a = 0.0
	_result_panel.hide()
	_inspect_card.hide()


func _unhandled_input(event: InputEvent) -> void:
	# Enter dismisses a shown hint (Space is End turn; the card's button can't take focus).
	if _hint_card.visible and event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode in [KEY_ENTER, KEY_KP_ENTER]:
		_hint_card.dismiss()
		get_viewport().set_input_as_handled()
		return
	if _hint_card.visible:
		return
	if event.is_action_pressed(&"show_order"):
		_order_overlay.toggle()
		get_viewport().set_input_as_handled()


## Units in the order they'll act, the current one first (every living unit: the timeline
## shows the next few, the overlay all of them); `title` (e.g. "Floor 3") goes before the
## round number.
func show_turn_order(units: Array[UnitInfo], round_number: int, title := "") -> void:
	_round_text = (tr("%s · Round %d") % [title, round_number]) if not title.is_empty() else tr("Round %d") % round_number
	_update_round_label()
	_timeline.show_order(units)
	_order_overlay.show_order(units)


## The seconds left on the turn (or the placement), shown after the round; -1 shows none. Red for the last ten.
func set_countdown(seconds: int) -> void:
	if seconds == _countdown:
		return
	_countdown = seconds
	_update_round_label()


func _update_round_label() -> void:
	_round_label.text = _round_text if _countdown < 0 else "%s  ·  %s" % [_round_text, tr("%d s") % _countdown]
	if _countdown >= 0 and _countdown <= 10:
		_round_label.add_theme_color_override("font_color", Color(1.0, 0.55, 0.5))
	else:
		_round_label.remove_theme_color_override("font_color")


## The active unit's card.
func show_unit(info: UnitInfo) -> void:
	_active_card.show_unit(info)


## The card for the unit under the mouse, or the pinned one (with its ✕).
func show_inspected(info: UnitInfo, pinned := false) -> void:
	_inspect_card.show_unit(info)
	_inspect_card.set_closable(pinned)
	_inspect_card.show()


## Puts the inspect card on the left or the right edge, so it never covers the unit it shows
## (the controller picks the side away from the unit).
func set_inspect_side(left: bool) -> void:
	_inspect_card.anchor_left = 0.0 if left else 1.0
	_inspect_card.anchor_right = 0.0 if left else 1.0
	_inspect_card.offset_left = 12.0 if left else -262.0
	_inspect_card.offset_right = 262.0 if left else -12.0
	_inspect_card.grow_horizontal = Control.GROW_DIRECTION_END if left else Control.GROW_DIRECTION_BEGIN


func is_inspect_on_left() -> bool:
	return _inspect_card.anchor_left == 0.0


func hide_inspected() -> void:
	_inspect_card.hide()
	_spell_bar.hide_details()


## Whether a control belongs to the (visible) inspect card.
func is_inspect_control(control: Control) -> bool:
	return _inspect_card.visible and (control == _inspect_card or _inspect_card.is_ancestor_of(control))


## The leave question, opened from the menu button in the Game root's top bar.
func open_leave_panel() -> void:
	_leave_panel.show()
	_refresh_buttons()


## Whether a full-screen panel (order, leave question, result) is over the board.
func is_modal_open() -> bool:
	return _order_overlay.is_open() or _leave_panel.visible or _result_panel.visible or _hint_card.visible


## Closes the leave confirmation if it's open; true if it was (Esc closes it first).
func close_leave_panel() -> bool:
	if not _leave_panel.visible:
		return false
	_leave_panel.hide()
	_refresh_buttons()
	return true


## Closes the full-order overlay if it's open; true if it was (Esc closes it first).
func close_order_overlay() -> bool:
	if not _order_overlay.is_open():
		return false
	_order_overlay.close()
	return true


## One slot per spell; spells costing more than `ap`, or waiting for their cooldown, are disabled.
func show_spells(spells: Array[SpellData], ap: int, cooldowns: Array[int] = []) -> void:
	_spell_bar.show_spells(spells, ap, cooldowns)


## Card combat: the hand as cards (one per card in hand, in hand order); a card needs a play (AP) to be cast.
func show_cards(info: UnitInfo) -> void:
	_spell_bar.show_cards(info.hand_spells, info.ap, info.deck_size, info.draw_count, info.discard_count)


## The active unit's AP changed (spells it can't afford are disabled).
func set_spell_ap(ap: int) -> void:
	_spell_bar.set_ap(ap)


## The active unit's cooldowns changed (per slot; waiting spells are disabled).
func set_spell_cooldowns(cooldowns: Array[int]) -> void:
	_spell_bar.set_cooldowns(cooldowns)


## Shows which spell is being aimed (-1 for none). Doesn't emit spell_selected.
func set_selected_spell(index: int) -> void:
	_spell_bar.set_selected(index)


## Spells and End turn only work on the player's turn, outside animations.
func set_player_controls_enabled(enabled: bool) -> void:
	_controls_enabled = enabled
	_refresh_buttons()


## While heroes are placed before the battle: no spells, and End turn becomes Ready.
func set_placing(placing: bool) -> void:
	_placing = placing
	_end_turn_button.text = _end_turn_text()
	_refresh_buttons()


## Shows a dismissable hint card (top right); `spotlight` returns the screen area it lights.
func show_hint(text: String, spotlight := Callable()) -> void:
	_hint_card.show_hint(text, spotlight)


## The persistent guidance line under the turn order ("" hides it).
func set_prompt(text: String) -> void:
	_prompt_label.text = text
	_prompt_label.visible = not text.is_empty()


## Lights `area` (screen coordinates) with `text`: the tutorial's spotlight.
func show_tutorial_step(text: String, area: Rect2) -> void:
	_hint_card.hide()  # A tip card would sit behind the dimming; it comes back at its next trigger.
	_tutorial.show_step(text, area)


func update_tutorial_area(area: Rect2) -> void:
	if _tutorial.is_active():
		_tutorial.set_hole(area)


func hide_tutorial() -> void:
	_tutorial.clear()


func is_tutorial_active() -> bool:
	return _tutorial.is_active()


## Screen rectangles of the HUD parts a tutorial step can light.
func end_turn_rect() -> Rect2:
	return _end_turn_button.get_global_rect()


func spell_slots_rect() -> Rect2:
	return _spell_bar.get_node("Slots").get_global_rect()


## The Auto toggle (QA tools) and, in QA battles, the cheat bar at the top left (its buttons
## only pressable when a cheat can act: the player's turn).
func show_qa_controls(auto_shown: bool, cheats_shown: bool, cheats_enabled := true) -> void:
	_auto_button.visible = auto_shown
	_qa_bar.visible = cheats_shown
	for button: Button in _qa_bar.get_children():
		button.disabled = not cheats_enabled


func set_auto(on: bool) -> void:
	_auto_button.set_pressed_no_signal(on)


func _build_qa_controls() -> void:
	_auto_button = Button.new()
	_auto_button.name = "AutoButton"
	_auto_button.text = tr("Auto")
	_auto_button.tooltip_text = tr("The AI plays your heroes until you turn it off.")
	_auto_button.toggle_mode = true
	_auto_button.focus_mode = Control.FOCUS_NONE
	_auto_button.visible = false
	_auto_button.toggled.connect(auto_toggled.emit)
	_speed_button.add_sibling(_auto_button)
	_qa_bar = VBoxContainer.new()
	_qa_bar.name = "QaBar"
	_qa_bar.visible = false
	_qa_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT, Control.PRESET_MODE_MINSIZE, 12)
	for entry: Array in [[&"win", tr("Win now")], [&"lose", tr("Lose now")], [&"kill", tr("Kill pinned unit")],
			[&"heal", tr("Heal the heroes")], [&"refill", tr("Refill AP and MP")]]:
		var button := Button.new()
		button.name = "Qa_" + entry[0]
		button.text = entry[1]
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(qa_cheat.emit.bind(entry[0]))
		_qa_bar.add_child(button)
	$Root.add_child(_qa_bar)


## Shows the current battle speed on its button.
func set_battle_speed(speed: Settings.BattleSpeed) -> void:
	match speed:
		Settings.BattleSpeed.NORMAL: _speed_button.text = tr("Speed x1")
		Settings.BattleSpeed.FAST: _speed_button.text = tr("Speed x2")
		Settings.BattleSpeed.INSTANT: _speed_button.text = tr("Speed: skip")


## Makes End turn pulse while the active hero has nothing left to do.
func set_end_turn_pulse(pulsing: bool) -> void:
	if pulsing == is_end_turn_pulsing():
		return
	if _pulse_tween != null:
		_pulse_tween.kill()
		_pulse_tween = null
	_end_turn_button.modulate = Color.WHITE
	if pulsing:
		_pulse_tween = create_tween().set_loops()
		_pulse_tween.tween_property(_end_turn_button, "modulate", END_TURN_PULSE_COLOR, END_TURN_PULSE_TIME)
		_pulse_tween.tween_property(_end_turn_button, "modulate", Color.WHITE, END_TURN_PULSE_TIME)


func is_end_turn_pulsing() -> bool:
	return _pulse_tween != null


func set_overhead_view(enabled: bool) -> void:
	var key := SettingsApplier.key_text(&"camera_toggle_view")
	_view_button.text = (tr("Side view (%s)") if enabled else tr("Top view (%s)")) % key


## "End turn (Space)" / "Ready (Space)", with whatever key End turn is bound to.
func _end_turn_text() -> String:
	return (tr("Ready (%s)") if _placing else tr("End turn (%s)")) % SettingsApplier.key_text(&"end_turn")


## Fades a short message in and out. Await it to wait until it's gone.
func show_banner(text: String) -> void:
	_banner.text = text
	if _banner_tween != null:
		_banner_tween.kill()
	_banner_tween = create_tween()
	_banner_tween.tween_property(_banner, "modulate:a", 1.0, BANNER_FADE)
	_banner_tween.tween_interval(BANNER_HOLD)
	_banner_tween.tween_property(_banner, "modulate:a", 0.0, BANNER_FADE)
	await _banner_tween.finished


## `battle_seed` is shown so a battle can be replayed (BattleController.rng_seed).
func show_result(won: bool, battle_seed := 0) -> void:
	_result_label.text = "Victory!" if won else "Defeat"
	_seed_label.text = tr("Battle seed %d") % battle_seed
	set_player_controls_enabled(false)
	_result_panel.show()


## The result screen's button: "Play again" standalone, "Continue" in the game flow.
func set_result_action_text(text: String) -> void:
	_restart_button.text = text


func hide_result() -> void:
	_result_panel.hide()


## A spell in one sentence, e.g. "Range 2-6, line of sight. Circle area 1. 5-7 damage."
static func spell_description(spell: SpellData) -> String:
	return ". ".join(SpellBar.detail_lines(spell)) + "."


func _refresh_buttons() -> void:
	var overlay_open := _order_overlay.is_open() or _leave_panel.visible or _hint_card.visible
	_spell_bar.set_locked(not _controls_enabled or _placing or overlay_open)
	_end_turn_button.disabled = not _controls_enabled or overlay_open

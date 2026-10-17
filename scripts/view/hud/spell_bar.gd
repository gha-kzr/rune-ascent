class_name SpellBar
extends VBoxContainer
## The active unit's spells as square icon slots (AP cost, key number), and a details panel
## that shows the spell under the mouse (name, AP, range, area, effects) just above it. Slots are toggle
## buttons; selecting is reported as a signal up.
##
## The hover is looked up from the mouse position every frame (hover_at), never from mouse_entered /
## mouse_exited: the slots are rebuilt after every action, Godot's tooltip popups steal the mouse, and a
## disabled button reports nothing useful. Other places that list spells (the inspect card) hand their rows
## over with set_extra_targets().
##
## Buttons never take keyboard focus, so Space can't press a focused button; the spell
## actions (keys 1-9 by default) are shortcuts that respect the disabled state.

signal spell_pressed(index: int)
## Card combat: the player threw the card at this position away (its ✕, or a right click on it).
signal discard_pressed(index: int)
## The spell under the mouse changed (null: none). `on_bar`: one of the bar's own slots or cards, not a row of
## another list (set_extra_targets).
signal spell_hovered(spell: SpellData, on_bar: bool)

## Spell slot i is pressed by the InputMap action "spell_<i+1>" (rebindable in the settings).
const MAX_KEYED_SLOTS := 9
const SLOT_SIZE := Vector2(64, 64)
const CARD_SIZE := Vector2(104, 150)
const HEAL_TINT := Color(0.55, 1.0, 0.6)

var _spells: Array[SpellData] = []
var _spell_costs: Array[int] = []
var _hovered: SpellData
## What spell_hovered last reported.
var _reported: SpellData
var _reported_on_bar := false
## Card combat: the slots are the cards of a hand (see CardRules).
var _card_mode := false
var _deck_total := 0
var _counts: Label
var _extra_targets: Callable
var _cooldowns: Array[int] = []
var _ap := 0
var _locked := false

@onready var _slots: HBoxContainer = %Slots
@onready var _details: PanelContainer = %Details
@onready var _details_name: Label = %DetailsName
@onready var _details_cost: Label = %DetailsCost
@onready var _details_body: Label = %DetailsBody


func _ready() -> void:
	# Floating: placed above whatever is hovered (hover_at), not by the bar's layout.
	_details.top_level = true
	_details.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_details.custom_minimum_size = Vector2(380, 0)
	_details.hide()
	_counts = Label.new()
	_counts.name = "CardCounts"
	_counts.theme_type_variation = &"SmallLabel"
	_counts.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_counts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_counts.visible = false
	add_child(_counts)


## Where else spells are listed: returns `[[control, spell], ...]` (the rows of the inspect card).
func set_extra_targets(source: Callable) -> void:
	_extra_targets = source


func _process(_delta: float) -> void:
	if is_visible_in_tree():
		hover_at(get_global_mouse_position())


## Shows the details of the spell under `point` (global coordinates), above it; hides them when there is none.
func hover_at(point: Vector2) -> void:
	var target := _target_at(point)
	if target.is_empty():
		_hovered = null
		_report_hover(null, false)
		if _details.visible:
			hide_details()
		return
	var spell := target[1] as SpellData
	_report_hover(spell, slot_at(point) >= 0)
	if spell != _hovered or not _details.visible:
		_hovered = spell
		show_details(spell)
	_place_details(target[0] as Control)


func _report_hover(spell: SpellData, on_bar: bool) -> void:
	if spell != _reported or on_bar != _reported_on_bar:
		_reported = spell
		_reported_on_bar = on_bar
		spell_hovered.emit(spell, on_bar)


## The slot under `point` (global coordinates), -1 for none.
func slot_at(point: Vector2) -> int:
	for i in _slots.get_child_count():
		if i < _spells.size() and (_slots.get_child(i) as Control).get_global_rect().has_point(point):
			return i
	return -1


## `[control, spell]` for the first listed spell under `point`, or `[]`.
func _target_at(point: Vector2) -> Array:
	var index := slot_at(point)
	if index >= 0:
		return [_slots.get_child(index), _spells[index]]
	if _extra_targets.is_valid():
		for pair: Array in _extra_targets.call():
			var control := pair[0] as Control
			if control.is_visible_in_tree() and control.get_global_rect().has_point(point):
				return pair
	return []


## The panel floats above `anchor` (below it when there is no room), inside the screen.
func _place_details(anchor: Control) -> void:
	var rect := anchor.get_global_rect()
	var size := _details.size
	var view := get_viewport_rect().size
	var x := rect.get_center().x - size.x * 0.5
	if view.x > size.x + 8.0:
		x = clampf(x, 4.0, view.x - size.x - 4.0)
	var y := rect.position.y - size.y - 8.0
	if y < 4.0 and rect.end.y + 8.0 + size.y < view.y:
		y = rect.end.y + 8.0
	_details.global_position = Vector2(x, y)


## One slot per spell; spells costing more than `ap`, or with turns of cooldown left
## (`cooldowns`, per slot; empty: none), are disabled.
func show_spells(spells: Array[SpellData], ap: int, cooldowns: Array[int] = []) -> void:
	_card_mode = false
	_counts.hide()
	_build(spells, ap, cooldowns)


## Card combat: one card per spell in the hand, each worth one play (AP). `deck_total` is the size of the whole deck,
## `draw_count` and `discard_count` the piles.
func show_cards(hand: Array[SpellData], ap: int, deck_total: int, draw_count: int, discard_count: int) -> void:
	_card_mode = true
	_deck_total = deck_total
	_counts.text = tr("Draw pile %d · Discard pile %d") % [draw_count, discard_count]
	_counts.show()
	_build(hand, ap, [])


func is_card_mode() -> bool:
	return _card_mode


func _build(spells: Array[SpellData], ap: int, cooldowns: Array[int]) -> void:
	hide_details()
	_hovered = null
	_spells.assign(spells)
	# Removed at once, freed at the end of the frame: a slot may be rebuilt from inside its own `pressed`.
	for child in _slots.get_children():
		_slots.remove_child(child)
		child.queue_free()
	_spell_costs.clear()
	_ap = ap
	for i in spells.size():
		_spell_costs.append(1 if _card_mode else spells[i].ap_cost)
		_slots.add_child(_make_slot(spells[i], i))
	set_cooldowns(cooldowns)


## Shows which spell is being aimed (-1 for none). Doesn't emit spell_pressed.
func set_selected(index: int) -> void:
	for i in _slots.get_child_count():
		var slot := _slots.get_child(i) as Button
		slot.set_pressed_no_signal(i == index)
		slot.theme_type_variation = &"SelectedSlotButton" if i == index else &"SlotButton"


func set_ap(ap: int) -> void:
	_ap = ap
	_refresh()


## Turns of cooldown left per slot (missing slots: ready); shown on the slot.
func set_cooldowns(cooldowns: Array[int]) -> void:
	_cooldowns.assign(cooldowns)
	_cooldowns.resize(_spell_costs.size())  # New entries are 0.
	_refresh()


## The number shown on a slot waiting for its cooldown ("" when ready).
func cooldown_text(index: int) -> String:
	return (slot(index).get_node("Cooldown") as Label).text


## Locked: no spell can be picked (not the player's turn, placement, animations).
func set_locked(locked: bool) -> void:
	_locked = locked
	_refresh()


func slot_count() -> int:
	return _slots.get_child_count()


func slot(index: int) -> Button:
	return _slots.get_child(index) as Button


func show_details(spell: SpellData) -> void:
	_details_name.text = spell.display_name
	var lines := detail_lines(spell)
	if _card_mode:
		_details_cost.text = tr("1 play")
		lines = lines.filter(func(line: String) -> bool: return not (line == tr("Once per turn") or line.begins_with(tr("Every %d turns").split("%")[0])))
		lines.append(tr("%d of the %d cards in the deck") % [CardRules.copies(spell), _deck_total])
	else:
		_details_cost.text = tr("%d AP") % spell.ap_cost
	_details_body.text = "\n".join(lines)
	# A wrapping label wraps (and reports its height) only when asked, at the width it has: never laid out, it was
	# a thousand pixels tall the first time a spell was shown. Giving it its width and asking for its lines first.
	_details_body.size.x = _details.custom_minimum_size.x
	_details_body.get_line_count()
	_details.reset_size()  # Shrinks back to the new text.
	_details.show()


func hide_details() -> void:
	_details.hide()


func is_details_visible() -> bool:
	return _details.visible


## One line each for range, area and every effect, e.g. "Range 2-6, line of sight". Static, so
## it translates through the TranslationServer (tr() is an instance method).
static func detail_lines(spell: SpellData) -> Array[String]:
	var lines: Array[String] = []
	var range_amount := EffectData.amount_text(spell.min_range, spell.max_range)
	var range_text: String
	if spell.needs_line_of_sight and spell.height_extends_range:
		range_text = TranslationServer.translate("Range %s, line of sight, +range from high ground")
	elif spell.needs_line_of_sight:
		range_text = TranslationServer.translate("Range %s, line of sight")
	elif spell.height_extends_range:
		range_text = TranslationServer.translate("Range %s, +range from high ground")
	else:
		range_text = TranslationServer.translate("Range %s")
	range_text = range_text % range_amount
	lines.append(range_text)
	if spell.target_unit == SpellData.TargetUnit.ENEMY:
		lines.append(TranslationServer.translate("Targets an enemy"))
	elif spell.target_unit == SpellData.TargetUnit.ALLY:
		lines.append(TranslationServer.translate("Targets an ally"))
	if spell.cooldown == 1:
		lines.append(TranslationServer.translate("Once per turn"))
	elif spell.cooldown > 1:
		lines.append(TranslationServer.translate("Every %d turns") % spell.cooldown)
	if spell.area != null and spell.area.kind != AreaShape.Kind.SINGLE:
		lines.append(TranslationServer.translate("%s area %d") % [TranslationServer.translate(AreaShape.Kind.keys()[spell.area.kind].capitalize()), spell.area.size])
	for effect in spell.effects:
		if effect != null:
			var text := effect.full_description()
			lines.append(text.left(1).to_upper() + text.substr(1))
	return lines


## The icon's tint: its damage type's color, green for a heal, else white.
static func spell_tint(spell: SpellData) -> Color:
	for effect in spell.effects:
		if effect is DamageEffect and (effect as DamageEffect).damage_type != null:
			return (effect as DamageEffect).damage_type.color
		if effect is HealEffect:
			return HEAL_TINT
	return Color.WHITE


func _make_slot(spell: SpellData, index: int) -> Button:
	var button := Button.new()
	button.name = "Spell%d" % (index + 1)
	button.theme_type_variation = &"SlotButton"
	button.toggle_mode = true
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = CARD_SIZE if _card_mode else SLOT_SIZE
	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.texture = spell.display_icon()
	icon.modulate = spell_tint(spell)
	icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 10)
	icon.offset_bottom = -58.0 if _card_mode else -18.0  # Room for the AP cost (a card: its name) under the icon.
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(icon)
	var cost := Label.new()
	cost.name = "Cost"
	cost.theme_type_variation = &"SmallLabel"
	cost.text = tr("%d AP") % spell.ap_cost
	cost.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 6)
	cost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _card_mode:
		_add_card_face(button, spell, index)
		cost.hide()  # A card costs one play, whatever the spell: the hand says it once.
	button.add_child(cost)
	var cooldown := Label.new()
	cooldown.name = "Cooldown"
	cooldown.theme_type_variation = &"HeaderLabel"
	cooldown.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cooldown.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cooldown.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cooldown.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(cooldown)
	if index < MAX_KEYED_SLOTS:
		var action := StringName("spell_%d" % (index + 1))
		var key := Label.new()
		key.name = "Key"
		key.theme_type_variation = &"SmallLabel"
		key.text = SettingsApplier.key_text(action)
		key.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT, Control.PRESET_MODE_MINSIZE, 6)
		key.mouse_filter = Control.MOUSE_FILTER_IGNORE
		button.add_child(key)
		button.shortcut = _action_shortcut(action)
		# Godot would add "(2 - Physical)" as a tooltip after a moment: its popup takes the mouse, the slot gets a
		# mouse_exited and the details panel (the real description) disappears.
		button.shortcut_in_tooltip = false
	button.pressed.connect(spell_pressed.emit.bind(index))
	return button


## A card's name and the ✕ that throws it away (a right click does too).
func _add_card_face(button: Button, spell: SpellData, index: int) -> void:
	var title := Label.new()
	title.name = "CardName"
	title.theme_type_variation = &"SmallLabel"
	title.text = tr(spell.display_name)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE, Control.PRESET_MODE_MINSIZE, 6)
	title.offset_top = -60.0
	title.offset_bottom = -12.0
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(title)
	var discard := Button.new()
	discard.name = "Discard"
	discard.text = "X"
	discard.theme_type_variation = &"CloseButton"
	discard.focus_mode = Control.FOCUS_NONE
	discard.tooltip_text = ""
	discard.custom_minimum_size = Vector2(26, 26)
	discard.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 2)
	discard.pressed.connect(discard_pressed.emit.bind(index))
	button.add_child(discard)
	button.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT and not _locked:
			discard_pressed.emit(index)
			button.accept_event())


func _refresh() -> void:
	for i in _slots.get_child_count():
		var slot_button := _slots.get_child(i) as Button
		var waiting := _cooldowns[i] if i < _cooldowns.size() else 0
		slot_button.disabled = _locked or _spell_costs[i] > _ap or waiting > 0
		(slot_button.get_node("Icon") as TextureRect).self_modulate.a = 0.4 if slot_button.disabled else 1.0
		(slot_button.get_node("Cooldown") as Label).text = str(waiting) if waiting > 0 else ""
		if _card_mode:
			(slot_button.get_node("Discard") as Button).disabled = _locked  # Throwing a card away is free: no play needed.


static func _action_shortcut(action: StringName) -> Shortcut:
	var event := InputEventAction.new()
	event.action = action
	var shortcut := Shortcut.new()
	shortcut.events = [event]
	return shortcut

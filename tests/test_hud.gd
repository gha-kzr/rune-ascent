extends TestCase
## The HUD shows what it's given and reports clicks as signals.

const HUD_SCENE := preload("res://scenes/battle/hud.tscn")


func _hud() -> Hud:
	var hud := HUD_SCENE.instantiate() as Hud
	(Engine.get_main_loop() as SceneTree).root.add_child(hud)
	return hud


func _info(unit_name: String, is_player := true, hp := 20) -> UnitInfo:
	var info := UnitInfo.new()
	info.display_name = unit_name
	info.is_player = is_player
	info.hp = hp
	info.max_hp = 30
	info.ap = 4
	info.max_ap = 6
	info.mp = 1
	info.max_mp = 3
	return info


func _spells() -> Array[SpellData]:
	return [BattleFixtures.damage_spell(3), BattleFixtures.damage_spell(5)] as Array[SpellData]


func _spell_button(hud: Hud, index: int) -> Button:
	return (hud.get_node("%SpellBar") as SpellBar).slot(index)


func _card_label(card: Node, path: String) -> Label:
	return card.get_node(path) as Label


func _active(hud: Hud, path: String) -> Label:
	return _card_label(hud.get_node("%ActiveCard"), path)


func _chips(hud: Hud) -> Array[Node]:
	return hud.get_node("%TurnTimeline/Chips").get_children()


func test_unit_panel_shows_the_unit() -> void:
	var hud := _hud()
	hud.show_unit(_info("Knight"))
	assert_eq(_active(hud, "Rows/Header/NameLabel").text, "Knight")
	assert_eq(_active(hud, "Rows/HpLabel").text, "20 / 30 HP")
	assert_eq(_active(hud, "Rows/PointsRow/ApLabel").text, "AP 4 / 6")
	assert_eq(_active(hud, "Rows/PointsRow/MpLabel").text, "MP 1 / 3")
	assert_eq((hud.get_node("%ActiveCard/Rows/HpBar") as ProgressBar).value, 20.0)
	hud.free()


func test_unit_info_copies_the_unit_state() -> void:
	var state := BattleFixtures.state("0p 0e")
	state.units[0].hp = 7
	var info := UnitInfo.from_unit(state.units[0])
	assert_eq([info.display_name, info.hp, info.max_hp, info.ap, info.mp, info.is_player], ["P0", 7, 20, 6, 3, true])


func test_timeline_shows_the_next_five_turns_with_name_and_hp_bar_only() -> void:
	var hud := _hud()
	var units: Array[UnitInfo] = []
	for i in 7:
		var info := _info("Unit%d" % i, i % 2 == 0, 10 + i)
		info.unit_id = i
		units.append(info)
	hud.show_turn_order(units, 3)
	var chips := _chips(hud)
	assert_eq(chips.size(), 5, "capped at the next 5 turns")
	assert_eq(chips[0].theme_type_variation, &"ChipActive", "only the acting unit is marked")
	assert_eq(chips[1].theme_type_variation, &"Chip")
	assert_eq(_card_label(chips[2], "Rows/NameLabel").text, "Unit2", "a name, no number or level")
	assert_eq((chips[2].get_node("Rows/HpBar") as ProgressBar).value, 12.0)
	assert_eq(chips[2].get_node("Rows").get_child_count(), 2, "name and bar, nothing else")
	assert_eq((hud.get_node("%RoundLabel") as Label).text, "Round 3")
	hud.show_turn_order([units[0]] as Array[UnitInfo], 3, "Floor 2")
	assert_eq(_chips(hud).size(), 1, "replaced, not added")
	assert_eq((hud.get_node("%RoundLabel") as Label).text, "Floor 2 · Round 3")
	hud.free()


func test_timeline_chips_report_hover_and_click() -> void:
	var hud := _hud()
	var info := _info("Knight")
	info.unit_id = 4
	hud.show_turn_order([info] as Array[UnitInfo], 1)
	var received: Array = []
	hud.chip_hovered.connect(func(id: int) -> void: received.append(["in", id]))
	hud.chip_unhovered.connect(func() -> void: received.append(["out"]))
	hud.chip_pressed.connect(func(id: int) -> void: received.append(["press", id]))
	var chip := _chips(hud)[0] as Control
	chip.mouse_entered.emit()
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	chip.gui_input.emit(click)
	chip.mouse_exited.emit()
	assert_eq(received, [["in", 4], ["press", 4], ["out"]])
	hud.free()


func test_order_overlay_lists_every_unit_and_toggles() -> void:
	var hud := _hud()
	var units: Array[UnitInfo] = []
	for i in 7:
		var info := _info("Unit%d" % i)
		info.level = 3 if i == 0 else 0
		units.append(info)
	units[1].statuses = [_status_info("Poison", 2, "")] as Array[StatusInfo]
	hud.show_turn_order(units, 1)
	var overlay := hud.get_node("%OrderOverlay") as OrderOverlay
	assert_false(overlay.visible, "closed at first")
	overlay.open()
	var rows := overlay.get_node("%Rows").get_children()
	assert_eq(rows.size(), 7, "not capped")
	assert_eq(_card_label(rows[0], "Line/NameLabel").text, "Unit0 · Lv 3")
	assert_eq(_card_label(rows[0], "Line/HpBox/HpLabel").text, "20 / 30 HP")
	assert_eq(rows[1].get_node("Line/Statuses").get_child_count(), 2, "an icon and its turns")
	overlay.close()
	var press := InputEventAction.new()
	press.action = &"show_order"
	press.pressed = true
	Input.parse_input_event(press)
	hud._unhandled_input(press)
	assert_true(overlay.visible, "Tab opens it")
	assert_true(hud.close_order_overlay(), "Esc closes it")
	assert_false(overlay.visible)
	assert_false(hud.close_order_overlay(), "nothing to close")
	(hud.get_node("%TurnTimeline/OrderButton") as Button).pressed.emit()
	assert_true(overlay.visible, "the button opens it")
	hud.free()


func test_spells_are_disabled_without_enough_ap() -> void:
	var hud := _hud()
	hud.show_spells(_spells(), 4)
	assert_false(_spell_button(hud, 0).disabled, "3 AP spell with 4 AP")
	assert_true(_spell_button(hud, 1).disabled, "5 AP spell with 4 AP")
	assert_eq(_spell_button(hud, 0).tooltip_text, "", "details show in a panel, not a tooltip")
	hud.free()


func test_player_controls_can_be_disabled() -> void:
	var hud := _hud()
	hud.show_spells(_spells(), 10)
	hud.set_player_controls_enabled(false)
	assert_true(_spell_button(hud, 0).disabled)
	assert_true((hud.get_node("%EndTurnButton") as Button).disabled)
	hud.set_player_controls_enabled(true)
	assert_false(_spell_button(hud, 0).disabled)
	assert_false((hud.get_node("%EndTurnButton") as Button).disabled)
	hud.free()


func test_buttons_emit_signals_up() -> void:
	var hud := _hud()
	hud.show_spells(_spells(), 10)
	var received: Array = []
	hud.spell_selected.connect(func(index: int) -> void: received.append(["spell", index]))
	hud.end_turn_pressed.connect(func() -> void: received.append(["end"]))
	hud.view_toggle_pressed.connect(func() -> void: received.append(["view"]))
	hud.restart_pressed.connect(func() -> void: received.append(["restart"]))
	_spell_button(hud, 1).pressed.emit()
	(hud.get_node("%EndTurnButton") as Button).pressed.emit()
	(hud.get_node("%ViewButton") as Button).pressed.emit()
	(hud.get_node("%RestartButton") as Button).pressed.emit()
	assert_eq(received, [["spell", 1], ["end"], ["view"], ["restart"]])
	hud.free()


func test_keyboard_shortcuts_press_enabled_buttons_only() -> void:
	var hud := _hud()
	hud.show_spells(_spells(), 4)
	var received: Array[int] = []
	hud.spell_selected.connect(func(index: int) -> void: received.append(index))
	var ends := {"count": 0}
	hud.end_turn_pressed.connect(func() -> void: ends.count += 1)
	for key: Key in [KEY_1, KEY_2, KEY_SPACE]:
		var press := InputEventKey.new()
		press.physical_keycode = key
		press.pressed = true
		hud.get_viewport().push_input(press)
		var release := press.duplicate() as InputEventKey
		release.pressed = false
		hud.get_viewport().push_input(release)
	assert_eq(received, [0] as Array[int], "key 2's spell costs too much AP")
	assert_eq(ends.count, 1, "Space ends the turn")
	hud.free()


func test_selected_spell_shows_pressed_without_emitting() -> void:
	var hud := _hud()
	hud.show_spells(_spells(), 10)
	var emitted := {"count": 0}
	hud.spell_selected.connect(func(_index: int) -> void: emitted.count += 1)
	hud.set_selected_spell(1)
	assert_false(_spell_button(hud, 0).button_pressed)
	assert_true(_spell_button(hud, 1).button_pressed)
	hud.set_selected_spell(-1)
	assert_false(_spell_button(hud, 1).button_pressed)
	assert_eq(emitted.count, 0)
	hud.free()


func test_result_panel() -> void:
	var hud := _hud()
	hud.show_spells(_spells(), 10)
	hud.show_result(false)
	assert_true((hud.get_node("%ResultPanel") as Control).visible)
	assert_eq((hud.get_node("%ResultLabel") as Label).text, "Defeat")
	assert_true(_spell_button(hud, 0).disabled, "no more actions once it's over")
	hud.hide_result()
	assert_false((hud.get_node("%ResultPanel") as Control).visible)
	hud.free()


func test_banner_fades_in_and_out() -> void:
	var hud := _hud()
	Engine.time_scale = 20.0
	var banner := hud.get_node("%Banner") as Label
	await hud.show_banner("Knight's turn")
	assert_eq(banner.text, "Knight's turn")
	assert_eq(banner.modulate.a, 0.0, "gone again")
	hud.free()


func test_hud_lets_clicks_through_to_the_board_and_never_takes_focus() -> void:
	var hud := _hud()
	hud.show_spells(_spells(), 10)
	hud.show_turn_order([_info("Knight")] as Array[UnitInfo], 1)
	hud.show_inspected(_info("Brute", false), true)
	var nodes: Array[Node] = [hud]
	while not nodes.is_empty():
		var node: Node = nodes.pop_back()
		nodes.append_array(node.get_children())
		if node is Button:
			assert_eq((node as Button).focus_mode, Control.FOCUS_NONE, "%s takes no focus" % node.name)
	for path in ["Root", "Root/TopBar", "%TurnTimeline", "%TurnTimeline/Chips", "%SpellBar", "Root/Actions", "%Banner"]:
		assert_eq((hud.get_node(path) as Control).mouse_filter, Control.MOUSE_FILTER_IGNORE, "%s ignores the mouse" % path)
	hud.free()


func test_spell_description_covers_range_area_and_effects() -> void:
	var fireball := load("res://data/spells/fireball.tres") as SpellData
	assert_eq(Hud.spell_description(fireball), "Range 3-5, line of sight. Circle area 1. 5-7 fire damage.")
	var mend := load("res://data/spells/mend.tres") as SpellData
	assert_eq(Hud.spell_description(mend), "Range 0-3. Heals 6-10.")
	var firebolt := load("res://data/spells/firebolt.tres") as SpellData
	assert_true(Hud.spell_description(firebolt).contains("+range from high ground"))


func test_spells_can_be_rebuilt_from_inside_a_button_press() -> void:
	# E.g. an instant spell whose playback refreshes the HUD synchronously.
	var hud := _hud()
	hud.show_spells(_spells(), 10)
	hud.spell_selected.connect(func(_index: int) -> void: hud.show_spells(_spells(), 2))
	_spell_button(hud, 0).pressed.emit()
	assert_eq((hud.get_node("%SpellBar") as SpellBar).slot_count(), 2, "rebuilt")
	assert_true(_spell_button(hud, 0).disabled, "with the new AP")
	hud.free()


func _status_info(status_name: String, turns: int, description: String) -> StatusInfo:
	var info := StatusInfo.new()
	info.display_name = status_name
	info.turns_left = turns
	info.description = description
	return info


func test_unit_panel_lists_statuses_with_tooltips() -> void:
	var hud := _hud()
	var info := _info("Knight")
	info.statuses = [_status_info("Poison", 2, "3-4 damage per turn"), _status_info("Guarded", 1, "-30% damage taken")] as Array[StatusInfo]
	hud.show_unit(info)
	var rows := hud.get_node("%ActiveCard/Rows/StatusList").get_children()
	assert_eq(rows.size(), 2)
	assert_eq(((rows[0] as Control).get_child(1) as Label).text, "Poison, 2 turns")
	assert_eq(((rows[1] as Control).get_child(1) as Label).text, "Guarded, 1 turn")
	assert_eq((rows[0] as Control).tooltip_text, "3-4 damage per turn")
	info.statuses = [] as Array[StatusInfo]
	hud.show_unit(info)
	assert_eq(hud.get_node("%ActiveCard/Rows/StatusList").get_child_count(), 0, "replaced")
	hud.free()


func test_modified_ap_and_mp_are_tinted() -> void:
	var hud := _hud()
	var info := _info("Knight")
	info.max_ap = 6
	info.base_ap = 6
	info.max_mp = 4
	info.base_mp = 3
	hud.show_unit(info)
	assert_eq(_active(hud, "Rows/PointsRow/ApLabel").modulate, Color.WHITE)
	assert_eq(_active(hud, "Rows/PointsRow/MpLabel").modulate, UnitCard.BUFFED_COLOR)
	info.max_mp = 1
	hud.show_unit(info)
	assert_eq(_active(hud, "Rows/PointsRow/MpLabel").modulate, UnitCard.DEBUFFED_COLOR)
	hud.free()


func test_inspect_card_shows_a_unit_lists_spells_and_hides() -> void:
	var hud := _hud()
	var card := hud.get_node("%InspectCard") as UnitCard
	assert_false(card.visible, "hidden at first")
	var info := _info("Brute", false)
	info.statuses = [_status_info("Crippled", 2, "-2 MP")] as Array[StatusInfo]
	info.spells = _spells()
	hud.show_inspected(info)
	assert_true(card.visible)
	assert_false(card.is_closable(), "hovering: no ✕")
	assert_eq(_card_label(card, "Rows/Header/NameLabel").text, "Brute")
	assert_eq(card.get_node("Rows/StatusList").get_child_count(), 1)
	var spells := card.get_node("Rows/SpellList").get_children()
	assert_eq(spells.size(), 2)
	assert_eq((spells[0].get_child(1) as Label).text, "Hit (3 AP)")
	hud.hide_inspected()
	assert_false(card.visible)
	hud.free()


func test_the_active_card_lists_no_spells_but_the_inspect_card_does() -> void:
	var hud := _hud()
	var info := _info("Mage")
	info.spells = _spells()
	hud.show_unit(info)
	assert_eq(hud.get_node("%ActiveCard/Rows/SpellList").get_child_count(), 0, "the spell bar has them")
	hud.free()


func test_pinned_card_shows_a_close_button_that_signals_up() -> void:
	var hud := _hud()
	var closes := {"count": 0}
	hud.card_closed.connect(func() -> void: closes.count += 1)
	hud.show_inspected(_info("Brute", false), true)
	var close := hud.get_node("%InspectCard/Rows/Header/CloseButton") as Button
	assert_true(close.visible, "pinned: ✕")
	assert_eq(close.theme_type_variation, &"CloseButton")
	close.pressed.emit()
	assert_eq(closes.count, 1)
	hud.show_inspected(_info("Brute", false))
	assert_false(close.visible, "just hovering: no ✕")
	hud.free()


func test_a_title_shows_the_heroes_level() -> void:
	var hud := _hud()
	var info := _info("Knight")
	info.level = 7
	hud.show_unit(info)
	assert_eq(_active(hud, "Rows/Header/NameLabel").text, "Knight · Lv 7")
	info.level = 0
	hud.show_unit(info)
	assert_eq(_active(hud, "Rows/Header/NameLabel").text, "Knight", "no level: just the name")
	hud.free()


func test_hovering_a_spell_shows_its_details_in_a_panel_above_the_bar() -> void:
	var hud := _hud()
	var bar := hud.get_node("%SpellBar") as SpellBar
	var fireball := load("res://data/spells/fireball.tres") as SpellData
	hud.show_spells([fireball, BattleFixtures.damage_spell(3)] as Array[SpellData], 10)
	var details := bar.get_node("%Details") as Control
	assert_false(details.visible, "hidden until hovered")
	bar.hover_at(bar.slot(0).get_global_rect().get_center())
	await (Engine.get_main_loop() as SceneTree).process_frame
	assert_true(details.visible)
	assert_eq((bar.get_node("%DetailsName") as Label).text, fireball.display_name)
	assert_eq((bar.get_node("%DetailsCost") as Label).text, "%d AP" % fireball.ap_cost)
	var body := (bar.get_node("%DetailsBody") as Label).text
	assert_true(body.contains("Range 3-5, line of sight") and body.contains("Circle area 1") and body.contains("fire damage"), body)
	assert_true(details.get_global_rect().end.y <= bar.slot(0).get_global_rect().position.y + 1.0, "above the slots")
	bar.hover_at(Vector2(-500, -500))
	assert_false(details.visible, "hidden again when the mouse leaves")
	bar.hover_at(bar.slot(0).get_global_rect().get_center())
	hud.show_spells([fireball] as Array[SpellData], 10)  # Rebuilt under a mouse that does not move: no event, still found.
	await (Engine.get_main_loop() as SceneTree).process_frame
	bar.hover_at(bar.slot(0).get_global_rect().get_center())
	assert_true(details.visible, "details follow a rebuilt slot")
	hud.free()


func test_the_first_spell_details_are_not_a_tall_panel() -> void:
	# A wrapping label that was never laid out used to size the panel at a thousand pixels the first time.
	var hud := _hud()
	var bar := hud.get_node("%SpellBar") as SpellBar
	hud.show_spells([load("res://data/spells/fireball.tres")] as Array[SpellData], 10)
	await (Engine.get_main_loop() as SceneTree).process_frame
	bar.hover_at(bar.slot(0).get_global_rect().get_center())
	await (Engine.get_main_loop() as SceneTree).process_frame
	assert_true((bar.get_node("%Details") as Control).size.y < 250.0, "%s" % [(bar.get_node("%Details") as Control).size])
	hud.free()


func test_hovering_a_spell_on_the_inspect_card_shows_its_details() -> void:
	var hud := _hud()
	var bar := hud.get_node("%SpellBar") as SpellBar
	var info := _info("Enemy", false)
	var fireball := load("res://data/spells/fireball.tres") as SpellData
	info.spells = [fireball] as Array[SpellData]
	hud.show_spells(_spells(), 10)
	hud.show_inspected(info, true)
	await (Engine.get_main_loop() as SceneTree).process_frame
	var card := hud.get_node("%InspectCard") as UnitCard
	card.show_spells = true
	card.show_unit(info)
	await (Engine.get_main_loop() as SceneTree).process_frame
	var rows := card.spell_rows()
	assert_eq(rows.size(), 1, "the card lists its spell")
	var row := rows[0][0] as Control
	bar.hover_at(row.get_global_rect().get_center())
	assert_true(bar.is_details_visible(), "the row's spell is described")
	assert_eq((bar.get_node("%DetailsName") as Label).text, fireball.display_name)
	bar.hover_at(Vector2(-500, -500))
	assert_false(bar.is_details_visible())
	hud.free()


func test_the_slot_under_the_mouse_is_found_even_when_disabled_and_after_a_rebuild() -> void:
	var hud := _hud()
	var bar := hud.get_node("%SpellBar") as SpellBar
	hud.show_spells(_spells(), 1)  # Both cost more than 1 AP: disabled.
	await (Engine.get_main_loop() as SceneTree).process_frame
	assert_true(bar.slot(0).disabled and bar.slot(1).disabled)
	assert_eq(bar.slot_at(bar.slot(1).get_global_rect().get_center()), 1, "a disabled slot is found")
	assert_eq(bar.slot_at(Vector2(-50, -50)), -1, "nothing there")
	hud.show_spells(_spells(), 10)  # Rebuilt (after an action): the lookup follows the new slots.
	await (Engine.get_main_loop() as SceneTree).process_frame
	assert_eq(bar.slot_at(bar.slot(0).get_global_rect().get_center()), 0)
	hud.free()


func test_a_spell_slot_has_no_automatic_shortcut_tooltip() -> void:
	var hud := _hud()
	hud.show_spells(_spells(), 10)
	var slot := _spell_button(hud, 0)
	assert_true(slot.shortcut != null, "the key still works")
	assert_false(slot.shortcut_in_tooltip, "no \"(1 - Physical)\" popup over the slot: it hides the details")
	assert_eq(slot.get_tooltip(Vector2.ZERO), "", "no tooltip text at all")
	hud.free()


func test_spell_slots_are_square_icons_with_cost_and_key() -> void:
	var hud := _hud()
	hud.show_spells(_spells(), 10)
	var slot := _spell_button(hud, 1)
	assert_eq(slot.theme_type_variation, &"SlotButton")
	assert_eq(slot.custom_minimum_size.x, slot.custom_minimum_size.y, "square")
	assert_eq((slot.get_node("Icon") as TextureRect).texture, _spells()[1].display_icon())
	assert_eq((slot.get_node("Cost") as Label).text, "5 AP")
	assert_eq((slot.get_node("Key") as Label).text, "2")
	hud.set_selected_spell(1)
	assert_eq(slot.theme_type_variation, &"SelectedSlotButton")
	assert_eq(_spell_button(hud, 0).theme_type_variation, &"SlotButton")
	hud.set_selected_spell(-1)
	assert_eq(slot.theme_type_variation, &"SlotButton")
	hud.free()


func test_unit_info_carries_statuses_modified_maxima_and_spells() -> void:
	var state := BattleFixtures.state("0p 0e")
	var unit := state.units[0]
	unit.data.spells = _spells()
	unit.add_status(BattleFixtures.status("Haste", 2, 0,
			[BattleFixtures.modifier(StatModifier.Stat.MP, 2)] as Array[StatModifier], true), 1)
	var info := UnitInfo.from_unit(unit)
	assert_eq([info.max_mp, info.base_mp, info.mp], [5, 3, 5])
	assert_eq(info.statuses.size(), 1)
	assert_eq([info.statuses[0].display_name, info.statuses[0].turns_left, info.statuses[0].description], ["Haste", 2, "+2 MP"])
	assert_eq(info.spells.size(), 2)


func test_power_and_resistances_always_show() -> void:
	var hud := _hud()
	var info := _info("Knight")
	hud.show_unit(info)
	assert_true(_active(hud, "Rows/CombatStats").visible, "always shown")
	assert_eq(_active(hud, "Rows/CombatStats").text, "Initiative 0, damage taken +0%\nPower: All +0%\nResist: none")
	info.power = 8
	info.initiative = 110
	info.damage_taken = -30
	info.resistances = {"Physical": 0, "Fire": 20, "Poison": -10}
	hud.show_unit(info)
	var expected := "Initiative 110, damage taken -30%\nPower: All +8%\nResist: Physical +0%, Fire +20%, Poison -10%"
	assert_eq(_active(hud, "Rows/CombatStats").text, expected)
	hud.show_inspected(info)
	assert_eq((hud.get_node("%InspectCard/Rows/CombatStats") as Label).text, expected)
	hud.free()


func test_unit_info_reads_power_and_resistances() -> void:
	var ice := DamageType.new()  # Not one of the game's types.
	ice.display_name = "Ice"
	var ward := BattleFixtures.modifier(StatModifier.Stat.RESISTANCE_PERCENT, 25)
	ward.damage_type = ice
	var map := MapData.new()
	map.layout = "0p 0e"
	var state := BattleState.create(map.parse(), [BattleFixtures.unit("P0")] as Array[UnitData],
			[BattleFixtures.unit("E0")] as Array[UnitData], 1, [[ward, BattleFixtures.modifier(StatModifier.Stat.POWER, 9)] as Array[StatModifier]])
	var info := UnitInfo.from_unit(state.units[0])
	assert_eq(info.power, 9)
	assert_eq(info.resistances.keys(), ["Physical", "Fire", "Poison", "Holy", "Frost", "Ice"], "every game type in order, then the unit's own")
	assert_eq(info.resistances["Physical"], 0, "zeros included")
	assert_eq(info.resistances["Ice"], 25)


func test_a_rebuilt_timeline_releases_a_hovered_chip() -> void:
	var hud := _hud()
	var info := _info("Knight")
	info.unit_id = 2
	hud.show_turn_order([info] as Array[UnitInfo], 1)
	var events: Array = []
	hud.chip_hovered.connect(func(id: int) -> void: events.append(["in", id]))
	hud.chip_unhovered.connect(func() -> void: events.append(["out"]))
	_chips(hud)[0].mouse_entered.emit()
	hud.show_turn_order([info] as Array[UnitInfo], 1)
	assert_eq(events, [["in", 2], ["out"]], "the old chip never reports leaving, so the rebuild does")
	hud.show_turn_order([info] as Array[UnitInfo], 1)
	assert_eq(events.size(), 2, "nothing hovered: nothing to release")
	hud.free()


func test_shortcut_buttons_are_locked_while_the_order_overlay_is_open() -> void:
	var hud := _hud()
	hud.show_spells(_spells(), 10)
	(hud.get_node("%OrderOverlay") as OrderOverlay).open()
	assert_true(_spell_button(hud, 0).disabled)
	assert_true((hud.get_node("%EndTurnButton") as Button).disabled)
	hud.close_order_overlay()
	assert_false(_spell_button(hud, 0).disabled)
	assert_false((hud.get_node("%EndTurnButton") as Button).disabled)
	hud.free()


func test_the_overlay_ignores_wheel_ticks_and_builds_its_rows_when_opened() -> void:
	var hud := _hud()
	var overlay := hud.get_node("%OrderOverlay") as OrderOverlay
	hud.show_turn_order([_info("Knight")] as Array[UnitInfo], 1)
	assert_eq(overlay.get_node("%Rows").get_child_count(), 0, "hidden: not built yet")
	overlay.open()
	assert_eq(overlay.get_node("%Rows").get_child_count(), 1)
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	overlay.get_node("%Dim").gui_input.emit(wheel)
	assert_true(overlay.visible, "zooming doesn't close it")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	overlay.get_node("%Dim").gui_input.emit(click)
	assert_false(overlay.visible)
	hud.free()


func test_enter_dismisses_a_shown_hint_and_space_does_not() -> void:
	var hud := _hud()
	var dismissals := {"count": 0}
	hud.hint_dismissed.connect(func() -> void: dismissals.count += 1)
	hud.show_hint("Place your heroes.")
	var space := InputEventKey.new()
	space.keycode = KEY_SPACE
	space.pressed = true
	hud._unhandled_input(space)
	assert_eq(dismissals.count, 0, "Space is End turn")
	var enter := InputEventKey.new()
	enter.keycode = KEY_ENTER
	enter.pressed = true
	hud._unhandled_input(enter)
	assert_eq(dismissals.count, 1)
	assert_false((hud.get_node("%HintCard") as Control).visible)
	assert_eq((hud.get_node("%HintCard/Rows/DismissButton") as Button).focus_mode, Control.FOCUS_NONE)
	hud.free()


func after_each_clean() -> void:
	SettingsApplier.reset_bindings(Settings.new())


func test_button_labels_show_the_keys_the_player_bound() -> void:
	var settings := Settings.new()
	SettingsApplier.set_binding(settings, &"end_turn", KEY_U)
	SettingsApplier.set_binding(settings, &"camera_toggle_view", KEY_J)
	SettingsApplier.set_binding(settings, &"show_order", KEY_K)
	var hud := _hud()
	assert_eq((hud.get_node("%EndTurnButton") as Button).text, "End turn (U)")
	assert_eq((hud.get_node("%ViewButton") as Button).text, "Top view (J)")
	assert_eq((hud.get_node("%TurnTimeline/OrderButton") as Button).text, "All (K)")
	assert_eq((hud.get_node("%OrderOverlay/%Hint") as Label).text, "K or Esc to close")
	hud.set_placing(true)
	assert_eq((hud.get_node("%EndTurnButton") as Button).text, "Ready (U)")
	hud.set_overhead_view(true)
	assert_eq((hud.get_node("%ViewButton") as Button).text, "Side view (J)")
	hud.free()


func test_default_labels_are_unchanged() -> void:
	var hud := _hud()
	assert_eq((hud.get_node("%EndTurnButton") as Button).text, "End turn (Space)")
	assert_eq((hud.get_node("%ViewButton") as Button).text, "Top view (T)")
	assert_eq((hud.get_node("%TurnTimeline/OrderButton") as Button).text, "All (Tab)")
	hud.free()


func test_the_menu_button_asks_before_leaving_the_fight() -> void:
	var hud := _hud()
	hud.show_spells(_spells(), 10)
	var leaves := {"count": 0}
	hud.leave_confirmed.connect(func() -> void: leaves.count += 1)
	var panel := hud.get_node("%LeavePanel") as Control
	assert_false(panel.visible, "closed at first")
	hud.open_leave_panel()
	assert_true(panel.visible)
	assert_eq(leaves.count, 0, "asking isn't leaving")
	assert_true(_spell_button(hud, 0).disabled and (hud.get_node("%EndTurnButton") as Button).disabled, "the shortcuts are locked meanwhile")
	(hud.get_node("%StayButton") as Button).pressed.emit()
	assert_false(panel.visible)
	assert_false((hud.get_node("%EndTurnButton") as Button).disabled, "unlocked again")
	assert_eq(leaves.count, 0)
	hud.open_leave_panel()
	(hud.get_node("%LeaveButton") as Button).pressed.emit()
	assert_eq(leaves.count, 1)
	assert_false(panel.visible)
	assert_false(hud.close_leave_panel(), "nothing left to close")
	hud.free()


func test_the_recenter_button_asks_the_controller_and_shows_its_key() -> void:
	var settings := Settings.new()
	var hud := _hud()
	var asks := {"count": 0}
	hud.recenter_pressed.connect(func() -> void: asks.count += 1)
	assert_eq((hud.get_node("%RecenterButton") as Button).text, "Recenter (C)")
	(hud.get_node("%RecenterButton") as Button).pressed.emit()
	assert_eq(asks.count, 1)
	hud.free()
	SettingsApplier.set_binding(settings, &"camera_recenter", KEY_V)
	var rebound := _hud()
	assert_eq((rebound.get_node("%RecenterButton") as Button).text, "Recenter (V)")
	rebound.free()


func test_clicking_a_row_of_the_full_order_looks_at_that_unit_and_closes_the_overlay() -> void:
	var hud := _hud()
	var units: Array[UnitInfo] = []
	for i in 7:
		var info := _info("Unit%d" % i)
		info.unit_id = i + 10
		units.append(info)
	hud.show_turn_order(units, 1)
	var overlay := hud.get_node("%OrderOverlay") as OrderOverlay
	overlay.open()
	var looked: Array[int] = []
	hud.chip_pressed.connect(func(id: int) -> void: looked.append(id))
	var rows := overlay.get_node("%Rows").get_children()
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	(rows[6] as Control).gui_input.emit(click)  # A unit beyond the timeline's 5.
	assert_eq(looked, [16] as Array[int])
	assert_false(overlay.visible, "closed to show the board")
	for control: Control in [rows[0], rows[0].get_node("Line"), rows[0].get_node("Line/HpBox")]:
		assert_true(control == rows[0] and control.mouse_filter == Control.MOUSE_FILTER_STOP or control != rows[0] and control.mouse_filter == Control.MOUSE_FILTER_IGNORE, "%s: only the row takes the click" % control.name)
	hud.free()


func test_the_inspect_card_can_sit_on_either_edge() -> void:
	var hud := _hud()
	var card := hud.get_node("%InspectCard") as Control
	hud.show_inspected(_info("Brute", false))
	assert_false(hud.is_inspect_on_left(), "right by default")
	hud.set_inspect_side(true)
	assert_true(hud.is_inspect_on_left())
	assert_eq([card.anchor_left, card.anchor_right, card.offset_left, card.offset_right], [0.0, 0.0, 12.0, 262.0])
	assert_eq(card.grow_horizontal, Control.GROW_DIRECTION_END)
	hud.set_inspect_side(false)
	assert_eq([card.anchor_left, card.anchor_right, card.offset_left, card.offset_right], [1.0, 1.0, -262.0, -12.0])
	assert_eq(card.grow_horizontal, Control.GROW_DIRECTION_BEGIN)
	hud.free()


func test_a_spell_waiting_for_its_cooldown_shows_its_turns_and_is_disabled() -> void:
	var hud := _hud()
	hud.show_spells(_spells(), 10, [2, 0] as Array[int])
	assert_true(_spell_button(hud, 0).disabled, "waiting")
	assert_eq(hud.get_node("%SpellBar").cooldown_text(0), "2")
	assert_false(_spell_button(hud, 1).disabled)
	assert_eq(hud.get_node("%SpellBar").cooldown_text(1), "")
	hud.set_spell_cooldowns([0, 0] as Array[int])
	assert_false(_spell_button(hud, 0).disabled, "ready again")
	hud.free()

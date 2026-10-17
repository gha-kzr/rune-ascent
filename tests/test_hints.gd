extends TestCase
## First-run hints: dismissals persist in the settings, and the cards report dismissing.


func test_a_known_hint_shows_until_dismissed() -> void:
	var settings := Settings.new()
	var hints := Hints.new(settings)
	assert_true(hints.should_show("hub_intro"))
	hints.dismiss("hub_intro")
	assert_false(hints.should_show("hub_intro"))
	assert_true(hints.should_show("first_status"), "others are unaffected")
	assert_eq(settings.dismissed_hints, ["hub_intro"] as Array[String], "kept in the settings")
	hints.dismiss("hub_intro")
	assert_eq(settings.dismissed_hints.size(), 1, "no duplicates")


func test_reset_shows_everything_again_and_unknown_ids_never_show() -> void:
	var hints := Hints.new(Settings.new())
	hints.dismiss("hub_intro")
	hints.dismiss("first_status")
	hints.reset()
	assert_true(hints.should_show("hub_intro") and hints.should_show("first_status"))
	assert_false(hints.should_show("no_such_hint"))
	assert_eq(hints.text("no_such_hint"), "")
	assert_true(hints.text("hub_intro").length() > 10)


func test_the_card_is_hidden_until_shown_and_reports_dismissal_once() -> void:
	var card := (load("res://scenes/game/hint_card.tscn") as PackedScene).instantiate() as HintCard
	(Engine.get_main_loop() as SceneTree).root.add_child(card)
	assert_false(card.visible)
	var dismissals := {"count": 0}
	card.dismissed.connect(func() -> void: dismissals.count += 1)
	card.show_hint("Do this.")
	assert_true(card.visible)
	assert_eq((card.get_node("%HintText") as Label).text, "Do this.")
	(card.get_node("%DismissButton") as Button).pressed.emit()
	assert_false(card.visible)
	card.dismiss()
	assert_eq(dismissals.count, 1, "a hidden card doesn't dismiss again")
	card.free()


func test_a_shown_card_blocks_the_screen_behind_it_until_dismissed() -> void:
	var host := Control.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(host)
	var card := (load("res://scenes/game/hint_card.tscn") as PackedScene).instantiate() as HintCard
	host.add_child(card)
	host.add_child(Control.new())  # Something added later would otherwise sit above the card.
	card.show_hint("Do this.")
	var blocker := host.get_node("HintBlocker") as Control
	assert_true(blocker.visible)
	assert_eq(blocker.mouse_filter, Control.MOUSE_FILTER_STOP)
	assert_eq(host.get_child(-1), card, "the card is on top")
	assert_eq(host.get_child(-2), blocker, "just over what it blocks")
	card.dismiss()
	assert_false(blocker.visible)
	host.free()


func test_a_card_can_light_an_area_and_sits_beside_it() -> void:
	var host := Control.new()
	host.size = Vector2(800, 600)
	(Engine.get_main_loop() as SceneTree).root.add_child(host)
	var card := (load("res://scenes/game/hint_card.tscn") as PackedScene).instantiate() as HintCard
	host.add_child(card)
	var lit := Rect2(300, 400, 200, 100)
	card.show_hint("Look here.", func() -> Rect2: return lit)
	var blocker := host.get_node("HintBlocker") as Control
	assert_true(card.is_processing(), "follows the area every frame")
	assert_false(Rect2(card.position, card.size).intersects(lit), "the card doesn't cover what it lights")
	card.dismiss()
	assert_false(card.is_processing())
	assert_false(blocker.visible)
	host.free()


func after_each_clean() -> void:
	SettingsApplier.reset_bindings(Settings.new())


func test_hint_texts_name_the_bound_key() -> void:
	var step := Tutorial.BATTLE_STEPS[0]
	assert_true(Tutorial.text_of(step).contains("Ready (Space)"), Tutorial.text_of(step))
	SettingsApplier.set_binding(Settings.new(), &"end_turn", KEY_J)
	assert_true(Tutorial.text_of(step).contains("Ready (J)"), Tutorial.text_of(step))
	assert_false(Tutorial.text_of(step).contains("{"), "no placeholder left")

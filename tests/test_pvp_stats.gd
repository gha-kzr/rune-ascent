extends TestCase
## The balance tool's numbers: a simulated match is read from its events (per class and per spell), runs add up (the
## parallel processes' results), and the whole-roster multipliers read their options.


func _class(name: String) -> int:
	for index in PvpHeroes.hero_count():
		if PvpHeroes.hero(index).display_name() == name:
			return index
	return -1


func test_a_match_is_counted_per_class_and_per_spell() -> void:
	var stats := PvpStats.new()
	PvpSimulator.play([_class("Knight")], [_class("Sorceress")], 11, 12, "open_field", 400, false, stats)
	assert_eq(stats.data["matches"], 1.0)
	assert_eq(stats.class_names(), ["Knight", "Sorceress"] as Array[String])
	var units := 0.0
	var dealt := 0.0
	var turns := 0.0
	for name in stats.class_names():
		units += float(stats.data["classes"][name]["units"])
		dealt += float(stats.data["classes"][name]["dealt"])
		turns += float(stats.data["classes"][name]["turns"])
	assert_eq(units, 2.0, "one hero each")
	assert_eq(turns, stats.data["unit_turns"], "every turn belongs to a class")
	assert_true(dealt > 0.0, "damage was dealt")
	var spell_damage := 0.0
	for key: String in stats.data["spells"]:
		spell_damage += float(stats.data["spells"][key]["dealt"])
	assert_eq(spell_damage, dealt, "and every point of it comes from a spell (or a status) in the spell table")
	assert_true(stats.report("test", 35.0).contains("Sorceress"))


func test_runs_add_up() -> void:
	var stats := PvpStats.new()
	PvpSimulator.play([_class("Knight")], [_class("Sorceress")], 11, 12, "open_field", 400, false, stats)
	var copy := JSON.parse_string(JSON.stringify(stats.data)) as Dictionary  # As a process sends it.
	var total := PvpStats.new()
	total.merge(copy)
	total.merge(copy)
	assert_eq(total.data["matches"], 2.0)
	assert_eq(total.data["classes"]["Knight"]["turns"], 2.0 * float(stats.data["classes"]["Knight"]["turns"]))
	assert_eq(total.turns_per_match(), stats.turns_per_match(), "the same matches twice: the same averages")


func test_tuning_reads_its_options_and_says_what_changes() -> void:
	var tuning := PvpTuning.from_options({"dmg": "1.3", "ap": "-1", "games": "10"})
	assert_eq(tuning.dmg, 1.3)
	assert_eq(tuning.ap, -1)
	assert_false(tuning.is_neutral())
	assert_eq(tuning.describe(), "dmg ×1.3, ap -1")
	assert_true(PvpTuning.from_options({}).is_neutral())

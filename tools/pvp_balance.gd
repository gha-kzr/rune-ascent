extends SceneTree
## Balance check for the PvP classes: AI-vs-AI matches on the real rules and maps (PvpSimulator), with the numbers per
## class and per spell (PvpStats). Runs on every core: the matches are shared out between Godot processes, and the
## result is the same whatever the number of processes (each match has its own seed).
##   godot --headless --script res://tools/pvp_balance.gd -- teams3 games=160
##   godot --headless --script res://tools/pvp_balance.gd -- teams5 games=60 dmg=1.3 out=runs/dmg13.json compare=runs/base.json
##   godot --headless --script res://tools/pvp_balance.gd -- duel games=6
## Modes: duel (every class against every class, 1v1: a win-rate matrix), teams2 ... teams6 (random teams of that size,
## duplicates allowed). Options:
##   games=      matches (per pair for duel, in total for teams; teams: 100 by default, duel: 6)
##   seed=       another set of matches (the same seed plays the same matches: compare runs on one seed)
##   map= size=  a typology file name (data/maps/typologies) and the board size (teams add one per extra hero)
##   cards=1     card combat
##   spirits=0   without the Spirits rule (on by default, like the lobby); spirit=curse,reveal keeps only those spells
##   without=    classes left out of the teams (without=priestess,necromancer)
##   with=       classes put in side A of every match (data on a class or a new spell sooner)
##   hp= dmg= heal= dot= lifesteal= ap=   whole-roster multipliers, in memory only (PvpTuning)
##   out=        also save the numbers as JSON (a path; res:// and user:// work too)
##   compare=    a JSON saved by out=: differences shown in brackets
##   turn_s=     seconds a human turn is taken to last, for the minutes (35)
##   jobs=       processes (all cores by default; 1: this one only)
## The AI plays worse than a player does and knows no class tricks, so read it as a lower bound and look for classes
## far from the others (win rate outside 40-60 % in teams) and for spells nobody casts.

const SCRIPT := "res://tools/pvp_balance.gd"

var _options := {}
var _mode := "teams3"
var _games := 0
var _seed := 1
var _map := "open_field"
var _size := 12
var _cards := false
var _pool: Array[int] = []
var _forced: Array[int] = []


func _init() -> void:
	for arg in OS.get_cmdline_user_args():
		if "=" in arg:
			var parts := arg.split("=", true, 1)
			_options[parts[0]] = parts[1]
		else:
			_mode = arg
	var error := _read_options()
	if not error.is_empty():
		print(error)
		quit(1)
		return
	PvpTuning.from_options(_options).apply()
	if _options.has("part"):
		_run_part()
	else:
		_run()


func _read_options() -> String:
	_games = int(_options.get("games", 6 if _mode == "duel" else 100))
	_seed = int(_options.get("seed", 1))
	_map = str(_options.get("map", "open_field"))
	_size = int(_options.get("size", 12))
	_cards = str(_options.get("cards", "0")) == "1"
	if _mode != "duel" and not (_mode.begins_with("teams") and _team_size() >= 1 and _team_size() <= 6):
		return "unknown mode %s (duel, teams2 ... teams6)" % _mode
	if _games < 1 or _size < PvpMap.MIN_SIZE or _size > PvpMap.MAX_SIZE:
		return "games= must be at least 1 and size= between %d and %d" % [PvpMap.MIN_SIZE, PvpMap.MAX_SIZE]
	if not ResourceLoader.exists("res://data/maps/typologies/%s.tres" % _map):
		return "no map typology named %s (see data/maps/typologies)" % _map
	var left_out := _classes(str(_options.get("without", "")))
	_forced = _classes(str(_options.get("with", "")))
	if left_out.has(-1) or _forced.has(-1):
		return "unknown class in without= or with= (%s)" % ", ".join(_names())
	for hero in PvpHeroes.hero_count():
		if hero not in left_out:
			_pool.append(hero)
	if _pool.is_empty():
		return "without= leaves no class"
	if _forced.size() > _team_size():
		return "with= names more classes than a team holds"
	return ""


func _team_size() -> int:
	return 1 if _mode == "duel" else int(_mode.trim_prefix("teams"))


func _names() -> Array[String]:
	var names: Array[String] = []
	for index in PvpHeroes.hero_count():
		names.append(PvpHeroes.hero(index).display_name())
	return names


## Class indexes from "priestess,Necromancer" (-1 for a name that isn't one).
func _classes(text: String) -> Array[int]:
	var lower := _names().map(func(name: String) -> String: return name.to_lower())
	var found: Array[int] = []
	for word in text.split(",", false):
		found.append(lower.find(word.strip_edges().to_lower()))
	return found


# --- The matches ------------------------------------------------------------------------------

## Every match of the run, in a fixed order: {a, b, seed, size} (and the pair for duels).
func _matches() -> Array[Dictionary]:
	var matches: Array[Dictionary] = []
	if _mode == "duel":
		for i in _pool:
			for j in _pool:
				if j <= i:
					continue
				for game in _games:
					var i_first := game % 2 == 0  # Sides swap, so neither class always gets the same start zone.
					matches.append({"a": [i if i_first else j], "b": [j if i_first else i], "size": _size,
							"seed": _seed * 100000 + i * 10000 + j * 1000 + game})
		return matches
	var size := _team_size()
	for game in _games:
		var rng := RandomNumberGenerator.new()
		rng.seed = hash([_seed, game])  # Each match draws its own teams: the same in any process.
		var side_a: Array[int] = _forced.duplicate()
		var side_b: Array[int] = []
		while side_a.size() < size:
			side_a.append(_pool[rng.randi_range(0, _pool.size() - 1)])
		while side_b.size() < size:
			side_b.append(_pool[rng.randi_range(0, _pool.size() - 1)])
		matches.append({"a": side_a, "b": side_b, "size": _size + (size - 1), "seed": _seed * 1000 + game})
	return matches


## Plays the matches whose index is `part` modulo `parts`.
func _play(part: int, parts: int) -> PvpStats:
	var stats := PvpStats.new()
	var names := _names()
	var matches := _matches()
	for index in matches.size():
		if index % parts != part:
			continue
		var match_spec := matches[index]
		var side_a: Array[int] = []
		side_a.assign(match_spec["a"])
		var side_b: Array[int] = []
		side_b.assign(match_spec["b"])
		var result := PvpSimulator.play(side_a, side_b, match_spec["seed"], match_spec["size"], _map, PvpSimulator.MAX_ACTIONS, _cards, stats,
				str(_options.get("spirits", "1")) != "0")
		if _mode == "duel":
			var score := 1.0 if result.winner == 0 else (0.5 if result.winner == -1 else 0.0)
			stats.record_duel(names[side_a[0]], names[side_b[0]], score)
			stats.record_duel(names[side_b[0]], names[side_a[0]], 1.0 - score)
	return stats


# --- One process, or many ---------------------------------------------------------------------

func _run() -> void:
	var started := Time.get_ticks_msec()
	var total := _matches().size()
	var jobs := clampi(int(_options.get("jobs", OS.get_processor_count())), 1, maxi(1, total))
	var stats := PvpStats.new()
	if jobs == 1:
		stats = _play(0, 1)
	else:
		var merged := _run_parallel(jobs)
		if merged == null:
			quit(1)
			return
		stats = merged
	var reference := {}
	if _options.has("compare"):
		reference = _read_json(str(_options["compare"])).get("data", {})
		if reference.is_empty():
			print("compare=: can't read %s" % _options["compare"])
	var title := "%s on %s %dx%d (%s)" % [_mode, _map, _size, _size, PvpTuning.from_options(_options).describe()]
	if not _options.get("without", "").is_empty():
		title += ", without %s" % _options["without"]
	if not _options.get("with", "").is_empty():
		title += ", with %s in side A" % _options["with"]
	print(stats.report(title, float(_options.get("turn_s", 35)), reference))
	if _options.has("out"):
		var saved := {"options": _options, "mode": _mode, "data": stats.data}
		if _write_json(str(_options["out"]), saved):
			print("saved to %s" % _options["out"])
	print("(%d matches, %d processes, %d s)" % [total, jobs, (Time.get_ticks_msec() - started) / 1000])
	quit()


## Starts `jobs` processes of this script on a share of the matches each, waits, and adds up what they saved. Null
## when one of them saved nothing (it failed: run with jobs=1 to see why).
func _run_parallel(jobs: int) -> PvpStats:
	var arguments: Array[String] = ["--headless", "--quiet", "--path", ProjectSettings.globalize_path("res://"), "--script", SCRIPT, "--", _mode]
	for key: String in _options:
		if key not in ["jobs", "out", "compare", "part"]:
			arguments.append("%s=%s" % [key, _options[key]])
	var pids: Array[int] = []
	var files: Array[String] = []
	for part in jobs:
		var file := "user://pvp_balance/part_%d_%d.json" % [OS.get_process_id(), part]
		files.append(file)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(file))
		var part_arguments := arguments.duplicate()
		part_arguments.append_array(["part=%d/%d" % [part, jobs], "out=%s" % file])
		pids.append(OS.create_process(OS.get_executable_path(), part_arguments))
	while pids.any(func(pid: int) -> bool: return pid > 0 and OS.is_process_running(pid)):
		OS.delay_msec(100)
	var stats := PvpStats.new()
	for file in files:
		var saved := _read_json(file)
		if saved.is_empty():
			print("a process saved nothing (%s): run with jobs=1 to see its errors" % file)
			return null
		stats.merge(saved["data"])
		DirAccess.remove_absolute(ProjectSettings.globalize_path(file))
	return stats


## A child process: plays its share and saves the numbers where the first process reads them.
func _run_part() -> void:
	var share := str(_options["part"]).split("/")
	var stats := _play(int(share[0]), maxi(1, int(share[1])))
	_write_json(str(_options["out"]), {"data": stats.data})
	quit()


func _write_json(path: String, value: Dictionary) -> bool:
	var absolute := ProjectSettings.globalize_path(path) if path.contains("://") else path
	DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	var file := FileAccess.open(absolute, FileAccess.WRITE)
	if file == null:
		print("can't write %s" % path)
		return false
	file.store_string(JSON.stringify(value, "\t"))
	return true


func _read_json(path: String) -> Dictionary:
	var absolute := ProjectSettings.globalize_path(path) if path.contains("://") else path
	if not FileAccess.file_exists(absolute):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(absolute))
	return parsed if parsed is Dictionary and (parsed as Dictionary).get("data") is Dictionary else {}

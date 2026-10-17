class_name PvpStats
extends RefCounted
## What AI-vs-AI matches tell about the PvP classes and their spells, read from the battle's own events (so it counts
## what really happened: damage after resistances, effective heals, kills): per class, damage dealt per turn, heals,
## damage taken per round alive, deaths and how many turns a hero plays before falling; per spell, casts, damage, heals
## and kills. Status ticks count for the status's caster (as "Class/Status (ticks)" in the spell table); sudden death and
## bumps count for nobody. A fallen hero's spirit (its turns and spells) shows in the spell table and the spirit counts,
## never in its class's numbers. Plain numbers in a Dictionary, so the processes of a parallel run send theirs as JSON and
## the first one adds them up (merge) and prints the report.

const CLASS_FIELDS: Array[String] = [
	"units", "wins", "turns", "dealt", "friendly", "healed", "taken", "deaths", "turns_before_death", "rounds_alive",
	"casts", "kills",
]
const SPELL_FIELDS: Array[String] = ["casts", "dealt", "friendly", "healed", "kills"]

var data := {
	"matches": 0.0, "rounds": 0.0, "unit_turns": 0.0, "spirit_turns": 0.0, "casts": 0.0, "moves": 0.0, "draws": 0.0, "a_wins": 0.0,
	"classes": {}, "spells": {}, "duels": {},
}

# The match being recorded.
var _class_of: Array[String] = []
var _turns: Array[int] = []
var _died: Array[bool] = []
## Who the damage and heals being read come from (a unit id, -1: nobody), and the spell table's row for them.
var _source := -1
var _source_key := ""
## Whether the source is a spirit: its doings go to the spell table only.
var _source_spirit := false
## Per unit: [source, spell key] of the last damage it took from a unit (the kill goes to them).
var _last_hit: Dictionary[int, Array] = {}


## A match starts: `classes` is each unit's class name, by unit id.
func begin_match(classes: Array[String]) -> void:
	_class_of = classes.duplicate()
	_turns.clear()
	_died.clear()
	for unit_class in _class_of:
		_class_row(unit_class)
		_turns.append(0)
		_died.append(false)
	_source = -1
	_source_key = ""
	_last_hit.clear()


func record(state: BattleState, events: Array[BattleEvents.Event]) -> void:
	for event in events:
		if event is BattleEvents.TurnStarted:
			_set_source(-1, "")  # Sudden death at the turn's start is nobody's.
			var starting := (event as BattleEvents.TurnStarted).unit_id
			if state.units[starting].spirit:
				data["spirit_turns"] = float(data.get("spirit_turns", 0.0)) + 1.0  # A fallen hero's: not its class's turns.
				continue
			data["unit_turns"] += 1.0
			_turns[starting] += 1
			_class_row(_class_of[starting])["turns"] += 1.0
		elif event is BattleEvents.UnitMoved:
			_set_source(-1, "")  # A bump into a hidden unit hurts the walker: nobody's damage.
			data["moves"] += 1.0
		elif event is BattleEvents.SpellCast:
			var cast := event as BattleEvents.SpellCast
			_set_source(cast.caster_id, "%s/%s" % [_class_of[cast.caster_id], cast.spell.display_name])
			_source_spirit = state.units[cast.caster_id].spirit
			_spell_row(_source_key)["casts"] += 1.0
			if _source_spirit:
				data["spirit_casts"] = float(data.get("spirit_casts", 0.0)) + 1.0
			else:
				data["casts"] += 1.0
				_class_row(_class_of[cast.caster_id])["casts"] += 1.0
		elif event is BattleEvents.StatusTicked:
			var ticked := event as BattleEvents.StatusTicked
			_set_source(-1, "")
			for instance in state.units[ticked.unit_id].statuses:
				if instance.data == ticked.status and instance.caster_id >= 0 and instance.caster_id < _class_of.size():
					_set_source(instance.caster_id, "%s/%s (ticks)" % [_class_of[instance.caster_id], ticked.status.display_name])
					break
		elif event is BattleEvents.DamageDealt:
			_damage(state, event as BattleEvents.DamageDealt)
		elif event is BattleEvents.Healed and _source >= 0:
			var amount := float((event as BattleEvents.Healed).amount)
			if not _source_spirit:
				_class_row(_class_of[_source])["healed"] += amount
			_spell_row(_source_key)["healed"] += amount
		elif event is BattleEvents.UnitDied:
			_death(state, (event as BattleEvents.UnitDied).unit_id)


func _set_source(unit_id: int, key: String) -> void:
	_source = unit_id
	_source_key = key
	_source_spirit = false


func _damage(state: BattleState, event: BattleEvents.DamageDealt) -> void:
	var amount := float(event.amount)
	_class_row(_class_of[event.unit_id])["taken"] += amount
	if _source < 0:
		return
	var field := "friendly" if state.units[_source].team == state.units[event.unit_id].team else "dealt"
	if not _source_spirit:
		_class_row(_class_of[_source])[field] += amount
	_spell_row(_source_key)[field] += amount
	if field == "dealt" and not _source_spirit:
		_last_hit[event.unit_id] = [_source, _source_key]


func _death(state: BattleState, unit_id: int) -> void:
	_died[unit_id] = true
	var row := _class_row(_class_of[unit_id])
	row["deaths"] += 1.0
	row["turns_before_death"] += float(_turns[unit_id])
	row["rounds_alive"] += float(state.turn_order.round_number)
	if _last_hit.has(unit_id):
		var killer: Array = _last_hit[unit_id]
		_class_row(_class_of[killer[0]])["kills"] += 1.0
		_spell_row(killer[1])["kills"] += 1.0


## The match is over: `winner` 0 (side A, the PLAYER team), 1 (side B) or -1 (a draw).
func end_match(state: BattleState, winner: int) -> void:
	var rounds := float(state.turn_order.round_number)
	data["matches"] += 1.0
	data["rounds"] += rounds
	if winner == -1:
		data["draws"] += 1.0
	elif winner == 0:
		data["a_wins"] += 1.0
	for unit in state.units:
		var row := _class_row(_class_of[unit.id])
		row["units"] += 1.0
		var side := 0 if unit.team == UnitState.Team.PLAYER else 1
		row["wins"] += 0.5 if winner == -1 else (1.0 if winner == side else 0.0)
		if not _died[unit.id]:
			row["rounds_alive"] += rounds


## A 1v1 result for the duel matrix: `score` is the row class's (1 win, 0.5 draw, 0 loss).
func record_duel(row_class: String, column_class: String, score: float) -> void:
	var key := "%s|%s" % [row_class, column_class]
	var cell: Array = data["duels"].get(key, [0.0, 0.0])
	data["duels"][key] = [float(cell[0]) + score, float(cell[1]) + 1.0]


func _class_row(unit_class: String) -> Dictionary:
	if not data["classes"].has(unit_class):
		var row := {}
		for field in CLASS_FIELDS:
			row[field] = 0.0
		data["classes"][unit_class] = row
	return data["classes"][unit_class]


func _spell_row(key: String) -> Dictionary:
	if not data["spells"].has(key):
		var row := {}
		for field in SPELL_FIELDS:
			row[field] = 0.0
		data["spells"][key] = row
	return data["spells"][key]


# --- Merging (parallel runs) ------------------------------------------------------------------

## Adds another run's numbers (its `data`, e.g. read back from JSON) to these.
func merge(other: Dictionary) -> void:
	_add(data, other)


static func _add(into: Dictionary, from: Dictionary) -> void:
	for key: Variant in from:
		var value: Variant = from[key]
		if value is Dictionary:
			if not into.has(key):
				into[key] = {}
			_add(into[key], value)
		elif value is Array:
			var sums: Array = into.get(key, [])
			sums.resize(maxi(sums.size(), (value as Array).size()))
			for index in (value as Array).size():
				sums[index] = float(sums[index] if sums[index] != null else 0.0) + float(value[index])
			into[key] = sums
		elif value is float or value is int:
			into[key] = float(into.get(key, 0.0)) + float(value)


# --- The report ---------------------------------------------------------------------------------

## Average unit turns per match (what the length of a match is made of).
func turns_per_match() -> float:
	return float(data["unit_turns"]) / maxf(1.0, float(data["matches"]))


func class_names() -> Array[String]:
	var names: Array[String] = []
	names.assign(data["classes"].keys())
	names.sort()
	return names


## The derived numbers of a class: win %, damage per turn, heal per turn, damage taken per round alive, death %,
## turns before death (of those who fell), rounds alive (everyone), casts per turn, kills per match.
func class_numbers(unit_class: String) -> Dictionary:
	var row: Dictionary = data["classes"].get(unit_class, {})
	if row.is_empty():
		return {}
	var units := maxf(1.0, float(row["units"]))
	var turns := maxf(1.0, float(row["turns"]))
	return {
		"units": float(row["units"]),
		"win": 100.0 * float(row["wins"]) / units,
		"dmg_turn": float(row["dealt"]) / turns,
		"friendly_share": 100.0 * float(row["friendly"]) / maxf(1.0, float(row["dealt"]) + float(row["friendly"])),
		"heal_turn": float(row["healed"]) / turns,
		"taken_round": float(row["taken"]) / maxf(1.0, float(row["rounds_alive"])),
		"death": 100.0 * float(row["deaths"]) / units,
		"turns_to_death": float(row["turns_before_death"]) / maxf(1.0, float(row["deaths"])),
		"rounds_alive": float(row["rounds_alive"]) / units,
		"casts_turn": float(row["casts"]) / turns,
		"kills": float(row["kills"]) / units,
	}


## The report as text. `turn_seconds`: what a human turn is taken to last, for the minutes. `reference`: another run's
## data (`compare=`), shown as differences in brackets.
func report(title: String, turn_seconds: float, reference: Dictionary = {}) -> String:
	var before := PvpStats.new()
	if not reference.is_empty():
		before.merge(reference)
	var has_before := not reference.is_empty()
	var lines: Array[String] = []
	var matches := maxf(1.0, float(data["matches"]))
	var turns := turns_per_match()
	var spirit_turns := float(data.get("spirit_turns", 0.0)) / matches
	var minutes := (turns * turn_seconds + spirit_turns * MatchSession.SPIRIT_TURN_SECONDS) / 60.0
	var summary := "%s: %d matches, %.1f rounds, %.1f unit turns and %.1f spirit turns a match (about %.0f min at %d s a turn, %d s a spirit's)" % [
			title, int(data["matches"]), float(data["rounds"]) / matches, turns, spirit_turns, minutes, int(turn_seconds),
			int(MatchSession.SPIRIT_TURN_SECONDS)]
	if has_before:
		summary += " [%+.0f %% turns]" % (100.0 * (turns / maxf(0.01, before.turns_per_match()) - 1.0))
	lines.append(summary)
	lines.append("%.2f casts and %.2f moves a turn; side A won %d %%, %d draws" % [
			float(data["casts"]) / maxf(1.0, float(data["unit_turns"])), float(data["moves"]) / maxf(1.0, float(data["unit_turns"])),
			roundi(100.0 * float(data["a_wins"]) / matches), int(data["draws"])])
	lines.append("")
	lines.append("%-12s %6s %9s %12s %5s %8s %7s %6s %10s %6s %6s %5s" % [
			"class", "units", "win%", "dmg/turn", "ff%", "heal/trn", "taken/r", "death%", "turns†", "rounds", "cast/t", "kills"])
	var rates: Array[float] = []
	var fewest := INF
	for unit_class in class_names():
		var now := class_numbers(unit_class)
		var then := before.class_numbers(unit_class) if has_before else {}
		rates.append(now["win"])
		fewest = minf(fewest, now["units"])
		lines.append("%-12s %6d %9s %12s %5.0f %8.1f %7.1f %6.0f %10s %6.1f %6.2f %5.2f" % [
				unit_class.left(12), int(now["units"]), _with_delta(now, then, "win", "%.0f"),
				_with_delta(now, then, "dmg_turn", "%.1f"), now["friendly_share"], now["heal_turn"], now["taken_round"], now["death"],
				_with_delta(now, then, "turns_to_death", "%.1f"), now["rounds_alive"], now["casts_turn"], now["kills"]])
	if not rates.is_empty():
		var mean := 0.0
		for rate in rates:
			mean += rate
		mean /= rates.size()
		var spread := 0.0
		for rate in rates:
			spread += (rate - mean) * (rate - mean)
		lines.append("win%% from %.0f to %.0f, spread (sd) %.1f; a class's win%% moves about ±%.0f points by chance (%d units)" % [
				rates.min(), rates.max(), sqrt(spread / rates.size()), 100.0 * sqrt(0.25 / maxf(1.0, fewest)), int(fewest)])
	lines.append("turns† = turns a hero played before falling (those who fell); rounds = rounds alive (everyone); taken/r = damage taken per round alive; ff% = share of its damage on its own team")
	lines.append("")
	lines.append("%-34s %8s %7s %9s %9s %7s" % ["spell (class/spell)", "casts/m", "share%", "dmg/cast", "heal/cast", "kills"])
	var keys: Array = data["spells"].keys()
	keys.sort()
	for key: String in keys:
		var row: Dictionary = data["spells"][key]
		var unit_class := key.get_slice("/", 0)
		var class_row: Dictionary = data["classes"].get(unit_class, {})
		var units := maxf(1.0, float(class_row.get("units", 1.0)))
		var casts := float(row["casts"])
		var per := maxf(1.0, casts)
		var ticks := key.ends_with("(ticks)")
		lines.append("%-34s %8s %7s %9.1f %9.1f %7d" % [key.left(34), "-" if ticks else "%.2f" % (casts / units),
				"-" if ticks else "%.0f" % (100.0 * casts / maxf(1.0, float(class_row.get("casts", 1.0)))),
				float(row["dealt"]) / (1.0 if ticks else per), float(row["healed"]) / (1.0 if ticks else per), int(row["kills"])])
	lines.append("casts/m = casts per hero of the class per match; ticks rows: total damage and heal over the run")
	if not data["duels"].is_empty():
		lines.append("")
		lines.append_array(_duel_matrix())
	return "\n".join(lines)


static func _with_delta(now: Dictionary, then: Dictionary, field: String, format: String) -> String:
	var text := format % float(now[field])
	if then.has(field):
		var difference := float(now[field]) - float(then[field])
		text += ("(%+.0f)" if format == "%.0f" else "(%+.1f)") % difference
	return text


func _duel_matrix() -> Array[String]:
	var lines: Array[String] = ["1v1: the row class's win rate against the column class (%):"]
	var names := class_names()
	var header := "%-12s" % ""
	for name in names:
		header += "%6s" % name.left(5)
	lines.append(header + "   avg")
	for row_class in names:
		var line := "%-12s" % row_class.left(12)
		var total := 0.0
		var counted := 0
		for column_class in names:
			var cell: Array = data["duels"].get("%s|%s" % [row_class, column_class], [])
			if cell.is_empty() or float(cell[1]) == 0.0:
				line += "%6s" % "-"
				continue
			var rate := 100.0 * float(cell[0]) / float(cell[1])
			total += rate
			counted += 1
			line += "%6d" % roundi(rate)
		lines.append(line + "%6d" % roundi(total / maxi(1, counted)))
	return lines

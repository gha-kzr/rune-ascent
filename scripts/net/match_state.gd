class_name MatchState
extends RefCounted
## The match every peer replicates: who is in it, the settings, and, once it starts, the battle.
## It only changes through apply(entry), one entry at a time in log order, and applying the same
## entries gives the same state on every peer (the battle's dice are seeded). An entry is a JSON-safe
## dictionary with a kind "k":
##   join {id, name, token}   a player arrives (or comes back: the same token)
##   drop {id}                a player left (lobby: gone; battle: disconnected)
##   kick {id}                the host removed a player from the lobby (they can't come back)
##   set {id, f, v}           a player's hero, side, ready flag or name (lobby)
##   cfg {f, v}               a setting: typology, size, seed, turn, grace, cards (lobby)
##   start {}                 builds the map and the battle (lobby, everyone ready)
##   ready {id, v}            a player is happy with their placement (battle, not started)
##   go {}                    placement is over, the first turn begins
##   act {a}                  a battle action (see ActionCodec), a: the encoded action
##   ai {id, v}               a seat is played by the AI (or goes back to its player)
##   lobby {}                 after the battle: back to the lobby for another one

enum Phase { LOBBY, BATTLE }

const MAX_PER_SIDE := 6
const MAX_NAME := 20
const TYPOLOGIES: Array[String] = ["open_field", "mountain", "crater", "islands", "canyon", "ruins"]
const SUDDEN_DEATH_ROUND := 40
const SUDDEN_DEATH_PERCENT := 10


class Seat extends RefCounted:
	var id := 0
	var name := ""
	## A hash of a secret only this player knows (the log is shared with every player, so never the secret itself):
	## the secret gets their seat back after a disconnect.
	var token := ""
	var hero := 0
	## 0 or 1; -1 until the player picks one (nobody is put on a side for them).
	var side := -1
	var ready := false
	var connected := true
	## Played by the AI (the player left); returning: they are back and will get the hero back at a safe moment.
	var ai := false
	var returning := false


var phase := Phase.LOBBY
var seats: Dictionary[int, Seat] = {}
var settings: Dictionary = {"typology": "open_field", "size": 14, "seed": 1, "turn": 30, "grace": 20, "cards": false, "friendly_fire": true, "spirits": true}
## Every entry applied so far; entry n is log[n - 1].
var log: Array[Dictionary] = []
var battle: Battle
## Seat id -> the id of its hero's unit, once the battle exists.
var unit_of_seat: Dictionary[int, int] = {}
var placed: Dictionary[int, bool] = {}
## Hashes of the tokens of the players the host removed: they can't join this match again.
var banned: Array[String] = []


func entry_count() -> int:
	return log.size()


func seat_ids() -> Array[int]:
	var ids: Array[int] = []
	ids.assign(seats.keys())
	ids.sort()
	return ids


func seats_on(side: int) -> Array[Seat]:
	var found: Array[Seat] = []
	for id in seat_ids():
		if seats[id].side == side:
			found.append(seats[id])
	return found


func seat_of_unit(unit_id: int) -> int:
	for seat_id in unit_of_seat:
		if unit_of_seat[seat_id] == unit_id:
			return seat_id
	return -1


## The seat whose hero's turn it is, or -1.
func current_seat() -> int:
	if battle == null or not battle.state.started or battle.state.is_over():
		return -1
	return seat_of_unit(battle.state.turn_order.current_unit_id())


## The seat of the player who holds this secret token, or null.
func seat_for_token(secret: String) -> Seat:
	var hashed := token_hash(secret)
	for id in seats:
		if seats[id].token == hashed:
			return seats[id]
	return null


## What the log keeps of a player's token.
static func token_hash(secret: String) -> String:
	return ("rune-ascent-multiplayer/token/" + secret).sha256_text()


func is_over() -> bool:
	return battle != null and battle.state.is_over()


## "" when the match could start now, else why not.
func start_problem() -> String:
	if phase != Phase.LOBBY:
		return TranslationServer.translate("the match has started")
	for id in seats:
		if seats[id].side < 0:
			return TranslationServer.translate("everyone must pick a team")
	if seats_on(0).is_empty() or seats_on(1).is_empty():
		return TranslationServer.translate("each team needs a player")
	for id in seats:
		if not seats[id].ready:
			return TranslationServer.translate("everyone must be ready")
	return ""


## Whether every seat that can still place its hero has said it is done (the AI's seats and the
## players who left count as done).
func everyone_placed() -> bool:
	for id in seats:
		var seat := seats[id]
		if not seat.ai and seat.connected and not placed.get(id, false):
			return false
	return true


## A fingerprint of the replicated state (the battle's, once there is one).
func fingerprint() -> int:
	if battle != null:
		return StateHash.of(battle.state)
	return str([phase, settings, seat_ids().map(func(id: int) -> String: return "%d:%s:%d:%d:%s" % [id, seats[id].name, seats[id].hero, seats[id].side, seats[id].ready])]).hash()


## Applies the next entry. Returns "" when it went in, else why it didn't (the state is unchanged).
func apply(entry: Dictionary) -> String:
	var error := _apply(entry)
	if error.is_empty():
		log.append(entry)
	return error


func _apply(entry: Dictionary) -> String:
	match entry.get("k"):
		"join": return _join(entry)
		"drop": return _drop(entry)
		"kick": return _kick(entry)
		"set": return _set_seat(entry)
		"cfg": return _cfg(entry)
		"start": return _start(entry)
		"ready": return _ready(entry)
		"go": return _go()
		"act": return _act(entry)
		"ai": return _ai(entry)
		"lobby": return _back_to_lobby()
	return "unknown entry"


func _join(entry: Dictionary) -> String:
	var id: Variant = entry.get("id")
	var token: Variant = entry.get("token")
	if id is not int or token is not String or (token as String).length() != 64:
		return "bad join"
	if token in banned:
		return TranslationServer.translate("you were removed from this match")
	var existing := _seat_with_hash(token)
	if existing != null:
		existing.connected = true
		if existing.ai:
			existing.returning = true
		return ""
	if phase != Phase.LOBBY:
		return TranslationServer.translate("the match has started")
	if seats.has(id):
		return TranslationServer.translate("that seat is taken")
	if seats.size() >= MAX_PER_SIDE * 2:
		return TranslationServer.translate("the match is full")
	var seat := Seat.new()
	seat.id = id
	seat.token = token
	seat.name = _clean_name(entry.get("name"), "Player %d" % id)
	seats[id] = seat
	return ""


func _seat_with_hash(hashed: String) -> Seat:
	for id in seats:
		if seats[id].token == hashed:
			return seats[id]
	return null


func _kick(entry: Dictionary) -> String:
	var id: Variant = entry.get("id")
	if phase != Phase.LOBBY or id is not int or not seats.has(id):
		return "can't remove that player now"
	banned.append(seats[id].token)
	seats.erase(id)
	return ""


func _drop(entry: Dictionary) -> String:
	var id: Variant = entry.get("id")
	if id is not int or not seats.has(id):
		return "no such seat"
	if phase == Phase.LOBBY:
		seats.erase(id)
	else:
		seats[id].connected = false
		seats[id].returning = false
	return ""


func _set_seat(entry: Dictionary) -> String:
	if phase != Phase.LOBBY:
		return "the match has started"
	var id: Variant = entry.get("id")
	if id is not int or not seats.has(id):
		return "no such seat"
	var seat := seats[id]
	var value: Variant = entry.get("v")
	match entry.get("f"):
		"hero":
			if value is not int or value < 0 or value >= PvpHeroes.hero_count():
				return "no such hero"
			seat.hero = value
			seat.ready = false
		"side":
			if value is not int or (value != 0 and value != 1):
				return "no such side"
			if value != seat.side and seats_on(value).size() >= MAX_PER_SIDE:
				return "that side is full"
			seat.side = value
			seat.ready = false
		"ready":
			if value is not bool:
				return "bad flag"
			if value and seat.side < 0:
				return TranslationServer.translate("pick a team first")
			seat.ready = value
		"name":
			seat.name = _clean_name(value, seat.name)
		_:
			return "unknown field"
	return ""


func _cfg(entry: Dictionary) -> String:
	if phase != Phase.LOBBY:
		return "the match has started"
	var value: Variant = entry.get("v")
	match entry.get("f"):
		"typology":
			if value is not String or value not in TYPOLOGIES:
				return "unknown map shape"
		"size":
			if value is not int or value < PvpMap.MIN_SIZE or value > PvpMap.MAX_SIZE:
				return "bad size"
		"seed":
			if value is not int or value < 0 or value > 999999999:
				return "bad seed"
		"turn":
			if value is not int or value < 10 or value > 120:
				return "bad turn time"
		"grace":
			if value is not int or value < 0 or value > 120:
				return "bad grace time"
		"cards", "friendly_fire", "spirits":
			if value is not bool:
				return "bad flag"
		_:
			return "unknown setting"
	settings[entry["f"]] = value  # Players who are ready stay ready: only a change of their own hero or team takes theirs back.
	return ""


## The host stamps the start with the signature of its classes: a player whose page holds other numbers (an old
## cached version, say) is told to reload instead of drifting into a desync.
func _start(entry: Dictionary) -> String:
	if entry.get("sig") != PvpHeroes.signature():
		return TranslationServer.translate("your game version differs from the host's: reload the page")
	var problem := start_problem()
	if not problem.is_empty():
		return problem
	var made := make_battle()
	if made == null:
		return "the battle couldn't be built"
	battle = made
	var order := _seat_order()
	unit_of_seat.clear()
	for index in order.size():
		unit_of_seat[order[index]] = index
	placed.clear()
	for id in seats:
		seats[id].ready = false
	phase = Phase.BATTLE
	return ""


## Seat ids in the order their units get ids: side A by seat id, then side B.
func _seat_order() -> Array[int]:
	var order: Array[int] = []
	for side in 2:
		for seat in seats_on(side):
			order.append(seat.id)
	return order


## A fresh battle for the seats and settings as they are (before anyone has acted). A view builds its
## own copy this way and replays the log on it.
func make_battle() -> Battle:
	var typology := load("res://data/maps/typologies/%s.tres" % settings["typology"]) as MapTypology
	var map := PvpMap.generate(int(settings["seed"]), typology, int(settings["size"]))
	var side_a: Array[Dictionary] = []
	var side_b: Array[Dictionary] = []
	for seat in seats_on(0):
		side_a.append({"hero": seat.hero, "name": seat.name})
	for seat in seats_on(1):
		side_b.append({"hero": seat.hero, "name": seat.name})
	var state := PvpBattle.create(map, side_a, side_b, hash([int(settings["seed"]), "battle"]))
	if state == null:
		return null
	state.friendly_fire = bool(settings.get("friendly_fire", true))
	if settings.get("spirits", true):
		state.spirit_kit = PvpHeroes.spirit_kit()
	if settings.get("cards", false):
		state.enable_cards(int(settings["seed"]))
	var fresh := Battle.new(state)
	fresh.sudden_death_round = SUDDEN_DEATH_ROUND
	fresh.sudden_death_percent = SUDDEN_DEATH_PERCENT
	return fresh


func _ready(entry: Dictionary) -> String:
	var id: Variant = entry.get("id")
	if phase != Phase.BATTLE or battle.state.started or id is not int or not seats.has(id) or entry.get("v") is not bool:
		return "can't change that now"
	placed[id] = entry["v"]
	return ""


func _go() -> String:
	if phase != Phase.BATTLE or battle.state.started:
		return "already started"
	battle.start()
	return ""


func _act(entry: Dictionary) -> String:
	if phase != Phase.BATTLE:
		return "no battle"
	var action := ActionCodec.decode(entry.get("a"))
	if action == null:
		return "malformed action"
	var result := battle.perform(action)
	return result.error


func _ai(entry: Dictionary) -> String:
	var id: Variant = entry.get("id")
	if id is not int or not seats.has(id) or entry.get("v") is not bool:
		return "bad ai entry"
	var seat := seats[id]
	seat.ai = entry["v"]
	seat.returning = false
	if seat.ai:
		placed[id] = true
	return ""


func _back_to_lobby() -> String:
	if not is_over():
		return "the battle isn't over"
	battle = null
	unit_of_seat.clear()
	placed.clear()
	phase = Phase.LOBBY
	for id in seats.keys():
		var seat := seats[id]
		seat.ready = false
		seat.ai = false
		seat.returning = false
		if not seat.connected:
			seats.erase(id)
	return ""


static func _clean_name(value: Variant, fallback: String) -> String:
	if value is not String:
		return fallback
	var text := (value as String).strip_edges().replace("\n", " ")
	if text.length() > MAX_NAME:
		text = text.left(MAX_NAME)
	return text if not text.is_empty() else fallback

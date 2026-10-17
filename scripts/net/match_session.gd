class_name MatchSession
extends RefCounted
## One player's side of a match, whatever the network: it keeps the replicated MatchState and keeps
## it equal to everyone else's.
##
## One peer, the host, numbers every change (an *entry*), checks it and sends it to the others; each
## peer applies the entries in order, so all of them hold the same state. The host is simply the
## lowest seat id still reachable: when it leaves, the next one takes over (host swap), asks the others
## how far they got, completes its log from whoever has most, and carries on numbering. A player
## who drops out is replaced by the AI after a grace period (the host plays its moves, as entries like
## any other); the same player can come back with their token and gets the hero back at a safe moment.
## Time only moves through tick(), so tests decide when time passes.
##
## Messages ("m"): hello, entry, entries, submit, reject, refused, redirect, pull, elected, have, ping, bye; and for
## show only: emote, mark, shown (my screen caught up with my turn), clock (the host's turn clock).

signal changed
## An entry went into the local state (the battle screen plays what it brings).
signal entry_applied(entry: Dictionary)
signal host_changed(new_host: int)
## One of my proposals was refused (the text says why).
signal rejected(reason: String)
## The match can't go on (a desync, the match was full or already started...).
signal halted(reason: String)
signal synced
## Another player sent an emote (a seat id and an emote number).
signal emote_received(seat_id: int, emote_id: int)
## A player put a mark on the board (a seat id and a cell); the screens show it to that player's team.
signal mark_received(seat_id: int, cell: Vector2i)

const PING_INTERVAL := 2.0
const PEER_TIMEOUT := 8.0
## How many emotes there are, and how often a player may send one.
const EMOTE_COUNT := 8
const EMOTE_COOLDOWN := 1.5
const MARK_COOLDOWN := 1.0
## No board is wider than this (a mark's cell outside it is dropped).
const MAX_MARK_CELL := 64
const DEFAULT_AI_DELAY := 0.6
const ELECTION_WAIT := 1.0
## Entries that carry the state's fingerprint, so a peer that drifted is noticed at once.
const HASHED: Array[String] = ["act", "go", "start", "lobby"]
## No honest log is longer than this (a message with more is dropped); the host stops numbering near it.
const MAX_ENTRIES := 20000
## What a peer may ask for per second (a short burst, then a steady rate): far above what a player does.
const PROPOSALS_BURST := 30.0
const PROPOSALS_PER_SECOND := 10.0
## The fields each kind of entry may carry (the host adds n, h and c itself): anything else a peer sends is dropped.
const ENTRY_FIELDS := {
	"join": ["id", "name", "token"], "set": ["id", "f", "v"], "ready": ["id", "v"], "ai": ["id", "v"], "cfg": ["f", "v"],
	"start": ["sig"], "go": [], "lobby": [], "drop": ["id"], "kick": ["id"], "act": ["a", "by", "sys"],
}
const MAX_FIELD_TEXT := 80
## Seconds each player has to place their hero before the fight starts (the host starts it when the time is up).
const PLACEMENT_SECONDS := 30.0
## The most a turn's clock gives back for the animations its player watched before getting control (see turn_shown).
const PLAYBACK_CREDIT := 10.0
## A spirit's turn (a fallen hero): one choice, so a short clock whatever the lobby's turn time.
const SPIRIT_TURN_SECONDS := 10.0

var transport: NetTransport
var my_id := 0
var my_name := ""
var my_token := ""
var host_id := 0
var state := MatchState.new()
var is_synced := false
var halt_reason := ""
## Seconds the AI waits before each move it plays (so the others can follow; tests use 0).
var ai_delay := DEFAULT_AI_DELAY

var _now := 0.0
var _ping_timer := 0.0
var _counter := 0
## Makes this session's request ids its own: a player who comes back (a new session, the counter at zero again) must not
## reuse the ids of its earlier requests, which the host would take for resends and drop.
var _salt := "%x" % (randi() % 0xFFFFF)
var _pending: Array[Dictionary] = []
var _seen: Dictionary[String, bool] = {}
var _last_heard: Dictionary[int, float] = {}
var _dead: Dictionary[int, bool] = {}
var _absent_since: Dictionary[int, float] = {}
var _turn_unit := -2
var _turn_elapsed := 0.0
## This turn's player said their screen caught up (sent once), and the host gave the time back (once).
var _shown_sent := false
var _turn_credited := false
var _placement_elapsed := 0.0
var _ai_wait := 0.0
var _electing := false
var _election_deadline := 0.0
var _election_have: Dictionary[int, int] = {}
var _election_pulling := false
var _held: Array = []
## Peers I asked for entries (a catch-up pull): their `entries` are accepted from them.
var _pulling: Dictionary[int, bool] = {}
var _last_emote: Dictionary[int, float] = {}
var _last_mark: Dictionary[int, float] = {}
var _budget: Dictionary[int, float] = {}
var _last_rehello: Dictionary[int, float] = {}
## Whether I am cut off from the others: my own connection is down, or every other player is gone.
var connection_lost := false
## My own connection was down at the last tick (and what to do when it is back: see _after_outage).
var _offline := false
## I am asking the player who is probably the host for the entries I missed while I was cut off.
var _resync_pending := false


## The player who opens the match: seat id = their transport id, host from the start.
static func open_as_host(net: NetTransport, player_name: String, token: String) -> MatchSession:
	var session := MatchSession.new()
	session._setup(net, player_name, token)
	session.host_id = session.my_id
	session.is_synced = true
	session._host_submit(session.my_id, {"k": "join", "id": session.my_id, "name": player_name, "token": MatchState.token_hash(token)}, true)
	return session


## A player joining through `host_hint`, the peer they are connected to (the host, or any player).
static func open_as_guest(net: NetTransport, player_name: String, token: String, host_hint: int) -> MatchSession:
	var session := MatchSession.new()
	session._setup(net, player_name, token)
	session.host_id = host_hint
	if host_hint in net.reachable_ids():
		session._send_hello()
	return session


func _setup(net: NetTransport, player_name: String, token: String) -> void:
	transport = net
	my_id = net.local_id()
	my_name = player_name
	my_token = token
	net.message_received.connect(_on_message)
	net.peer_connected.connect(_on_peer_connected)
	net.peer_disconnected.connect(_on_peer_lost)


func is_host() -> bool:
	return host_id == my_id


## Whether my hero is the one whose turn it is (and I play it, not the AI).
func is_my_turn() -> bool:
	return state.current_seat() == my_id and not state.seats[my_id].ai


## The hero's unit id for a seat, -1 before the battle.
func unit_of(seat_id: int) -> int:
	return state.unit_of_seat.get(seat_id, -1)


## Whether the local player controls that unit (their own hero while the AI isn't playing it).
func controls_unit(unit_id: int) -> bool:
	var seat_id := state.seat_of_unit(unit_id)
	return seat_id == my_id and state.seats.has(my_id) and not state.seats[my_id].ai


## Peers I can currently reach (not counting those that went quiet).
func peers() -> Array[int]:
	var found: Array[int] = []
	for id in transport.reachable_ids():
		if not _dead.has(id):
			found.append(id)
	return found


# --- My proposals ---------------------------------------------------------------------------

## Asks for a change (the host checks and numbers it). Lobby and battle helpers below build the entries.
func propose(entry: Dictionary) -> void:
	if halted_now():
		return
	if not transport.is_online():
		rejected.emit(TranslationServer.translate("not connected"))
		return
	_counter += 1
	entry["c"] = "%d-%s-%d" % [my_id, _salt, _counter]
	if is_host():
		_host_submit(my_id, entry)
	else:
		_pending.append(entry)
		transport.send(host_id, {"m": "submit", "p": entry})


func set_field(field: String, value: Variant) -> void:
	propose({"k": "set", "id": my_id, "f": field, "v": value})


func configure(setting: String, value: Variant) -> void:
	propose({"k": "cfg", "f": setting, "v": value})


func set_ready(on: bool) -> void:
	propose({"k": "set", "id": my_id, "f": "ready", "v": on})


func start_match() -> void:
	propose({"k": "start", "sig": PvpHeroes.signature()})


func set_placed(on: bool) -> void:
	propose({"k": "ready", "id": my_id, "v": on})


func act(action: BattleActions.Action) -> void:
	propose({"k": "act", "a": ActionCodec.encode(action), "by": my_id})


func back_to_lobby() -> void:
	propose({"k": "lobby"})


## The host removes a player from the lobby: they cannot join this match again.
func kick(seat_id: int) -> void:
	propose({"k": "kick", "id": seat_id})


## A quick message to the other players, shown over my hero (not part of the match log: it is only for show).
func send_emote(emote_id: int) -> void:
	if emote_id < 0 or emote_id >= EMOTE_COUNT:
		return
	var last: float = _last_emote.get(my_id, -100.0)
	if _now - last < EMOTE_COOLDOWN and last >= 0.0:
		return
	_last_emote[my_id] = _now
	transport.broadcast({"m": "emote", "e": emote_id})
	emote_received.emit(my_id, emote_id)


## A mark on the board for my team (not part of the match log: it is only for show). Everyone receives it, and each
## screen shows it only to the marking player's team.
func send_mark(cell: Vector2i) -> void:
	if not _mark_cell_ok(cell) or not _cooled_down(_last_mark, my_id, MARK_COOLDOWN):
		return
	transport.broadcast({"m": "mark", "x": cell.x, "y": cell.y})
	mark_received.emit(my_id, cell)


func _on_mark(from: int, message: Dictionary) -> void:
	var x: Variant = message.get("x")
	var y: Variant = message.get("y")
	if x is not int or y is not int or not state.seats.has(from):
		return
	var cell := Vector2i(x, y)
	if _mark_cell_ok(cell) and _cooled_down(_last_mark, from, MARK_COOLDOWN):
		mark_received.emit(from, cell)


func _mark_cell_ok(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < MAX_MARK_CELL and cell.y < MAX_MARK_CELL


## Whether `seat_id` may send again (its last message is at least `cooldown` old); if so, now is its last one.
func _cooled_down(last: Dictionary[int, float], seat_id: int, cooldown: float) -> bool:
	var previous: float = last.get(seat_id, -100.0)
	if _now - previous < cooldown and previous >= 0.0:
		return false
	last[seat_id] = _now
	return true


## Lets the AI play my hero (to finish the fight without me), or takes it back.
func hand_to_ai(on: bool) -> void:
	propose({"k": "ai", "id": my_id, "v": on})


func halted_now() -> bool:
	return not halt_reason.is_empty()


## Leaves the match: the others see me go.
func leave() -> void:
	transport.broadcast({"m": "bye"})
	transport.close()


# --- Time -----------------------------------------------------------------------------------

func tick(delta: float) -> void:
	_now += delta
	if halted_now():
		return
	if not transport.is_online():
		# My own connection is down: nothing is known about the others, so nothing is judged (no timeouts, no host
		# swap, no dropping seats) until it is back.
		if not _offline:
			_offline = true
			connection_lost = true
			changed.emit()
		return
	if _offline:
		_after_outage()
	for id in _budget.keys():
		_budget[id] = minf(PROPOSALS_BURST, _budget[id] + delta * PROPOSALS_PER_SECOND)
	if state.battle != null and state.battle.state.started and not state.battle.state.is_over():
		_turn_elapsed += delta  # Everyone counts the turn (the host's clock decides when it ends).
	elif state.battle != null and not state.battle.state.started:
		_placement_elapsed += delta
	_ping_timer += delta
	if _ping_timer >= PING_INTERVAL:
		_ping_timer = 0.0
		transport.broadcast({"m": "ping"})
	for id in peers():
		if _now - _last_heard.get(id, _now) > PEER_TIMEOUT:
			_on_peer_lost(id)
	if _electing:
		_election_tick()
	elif is_host():
		_host_tick(delta)


# --- Receiving ------------------------------------------------------------------------------

## My connection is back. Who is still here was told by the transport (peers gone are lost, the others heard again).
## A host that was cut off was replaced by the others meanwhile: it asks them for what it missed, like any guest.
func _after_outage() -> void:
	_offline = false
	connection_lost = peers().is_empty() and state.seat_ids().size() > 1
	if is_host() and not _electing and not peers().is_empty():
		host_id = peers().min()
		_resync_pending = true
		host_changed.emit(host_id)
		_send_hello()
	changed.emit()


func _on_peer_connected(id: int) -> void:
	_dead.erase(id)
	_last_heard[id] = _now
	if id == host_id and not is_host() and not is_synced:
		_send_hello()
	elif id == host_id and not is_host():
		for proposal in _pending:
			transport.send(host_id, {"m": "submit", "p": proposal})  # Sent while I was cut off: asked again (a nonce is applied once).
	elif is_host() and state.seats.has(id):
		_ask_to_come_back(id)  # A player whose connection blinked: its seat was dropped meanwhile, its token gets it back.


func _send_hello() -> void:
	transport.send(host_id, {"m": "hello", "name": my_name, "token": my_token, "have": state.entry_count()})


func _on_message(from: int, message: Dictionary) -> void:
	_last_heard[from] = _now
	var was_dead := _dead.has(from)
	_dead.erase(from)
	if was_dead and is_host() and message.get("m") not in ["hello", "bye"]:
		_ask_to_come_back(from)
	if connection_lost:
		connection_lost = false
		changed.emit()
	if halted_now():
		return
	match message.get("m"):
		"hello": _on_hello(from, message)
		"entry": _on_host_entry(from, message.get("e"))
		"entries": _on_entries(from, message)
		"submit": _on_submit(from, message.get("p"))
		"reject": _on_reject(message)
		"refused": _on_refused(from, message.get("why"))
		"redirect": _on_redirect(message)
		"rehello": if from == host_id and not is_host() and is_synced: _send_hello()  # (not yet synced: my hello is already on its way)
		"pull": _on_pull(from, message.get("from"))
		"elected": _on_elected(from, message.get("host"), message.get("have"))
		"have": _on_have(from, message.get("n"))
		"emote": _on_emote(from, message.get("e"))
		"mark": _on_mark(from, message)
		"shown": _on_shown(from, message.get("u"))
		"clock": _on_clock(from, message.get("u"), message.get("t"))
		"bye": _on_peer_lost(from)


## A peer I had given up on speaks again. If its seat went away (or is marked absent), it is asked to say hello again:
## its token gets it the seat back, and the entries it missed come with the answer.
func _ask_to_come_back(from: int) -> void:
	var seat := state.seats.get(from) as MatchState.Seat
	if seat != null and seat.connected:
		return
	if _now - _last_rehello.get(from, -100.0) < 2.0:
		return
	_last_rehello[from] = _now
	transport.send(from, {"m": "rehello"})


## Only the host I asked to join can refuse me, and only while I am not in yet.
func _on_refused(from: int, why: Variant) -> void:
	if from == host_id and not is_synced:
		_halt(str(why) if why is String and not (why as String).is_empty() else TranslationServer.translate("the match refused you"))


func _on_emote(from: int, emote_id: Variant) -> void:
	if emote_id is not int or emote_id < 0 or emote_id >= EMOTE_COUNT or not state.seats.has(from):
		return
	var last: float = _last_emote.get(from, -100.0)
	if _now - last < EMOTE_COOLDOWN and last >= 0.0:
		return  # Too often: ignored.
	_last_emote[from] = _now
	emote_received.emit(from, emote_id)


func _on_hello(from: int, message: Dictionary) -> void:
	if not is_host():
		transport.send(from, {"m": "redirect", "host": host_id})
		return
	var token: Variant = message.get("token")
	var have: Variant = message.get("have")
	if token is not String or have is not int:
		return
	var existing := state.seat_for_token(token)
	if existing != null and existing.id != from:
		transport.send(from, {"m": "refused", "why": TranslationServer.translate("that seat belongs to someone else")})
		return
	var error := _host_submit(from, {"k": "join", "id": from, "name": message.get("name", ""), "token": MatchState.token_hash(token)}, true)
	if not error.is_empty():
		transport.send(from, {"m": "refused", "why": error})
		return
	transport.send(from, {"m": "entries", "list": state.log.slice(clampi(have, 0, state.entry_count()))})


func _on_redirect(message: Dictionary) -> void:
	var new_host: Variant = message.get("host")
	if new_host is int and new_host != host_id and (not is_synced or _resync_pending):
		host_id = new_host
		_send_hello()


func _on_entries(from: int, message: Dictionary) -> void:
	var list: Variant = message.get("list")
	if list is not Array or (list as Array).size() > MAX_ENTRIES or not _trusts_entries_from(from):
		return
	for entry: Variant in list:
		_apply_entry(from, entry)
		if halted_now():
			return
	_pulling.erase(from)  # The answer to my pull came; later entries are taken from the host only.
	_election_pulling = false
	if from == host_id:
		_resync_pending = false
	if not is_synced:
		is_synced = true
		synced.emit()
		changed.emit()


## Entries come from the host, or from a peer I asked (catching up, or a new host collecting the longest log).
func _trusts_entries_from(from: int) -> bool:
	return from == host_id or _pulling.has(from)


func _on_host_entry(from: int, entry: Variant) -> void:
	if from == host_id:
		_apply_entry(from, entry)


func _apply_entry(from: int, entry: Variant) -> void:
	if entry is not Dictionary or entry.get("n") is not int:
		return
	var number: int = entry["n"]
	if number <= state.entry_count():
		return
	if number > state.entry_count() + 1:
		_pulling[from] = true
		transport.send(from, {"m": "pull", "from": state.entry_count()})
		return
	var error := state.apply(entry)
	if not error.is_empty():
		_halt(TranslationServer.translate("out of step with the host") + " (%s)" % error)
		return
	if entry.has("h") and entry["h"] != state.fingerprint():
		_halt(TranslationServer.translate("the game state differs from the host's (desync)") + " #%d" % number)
		return
	_after_applied(entry)


func _on_pull(from: int, since: Variant) -> void:
	if since is int:
		transport.send(from, {"m": "entries", "list": state.log.slice(clampi(since, 0, state.entry_count()))})


func _on_reject(message: Dictionary) -> void:
	var nonce := str(message.get("c", ""))
	_pending = _pending.filter(func(p: Dictionary) -> bool: return str(p.get("c")) != nonce)
	rejected.emit(str(message.get("why", "refused")))


func _on_submit(from: int, proposal: Variant) -> void:
	if proposal is not Dictionary:
		return
	if not is_host():
		transport.send(from, {"m": "redirect", "host": host_id})
		return
	_host_submit(from, proposal)


# --- The host: numbering and checking -------------------------------------------------------

## Checks a proposal, numbers it, applies it and sends it on. Returns "" when it went in, else why not.
## `internal`: built by the host itself (a join from a hello), which a proposal can never be.
func _host_submit(from: int, proposal: Dictionary, internal := false) -> String:
	if _electing:
		_held.append([from, proposal])
		return ""
	var nonce := str(proposal.get("c", ""))
	if not nonce.is_empty() and _seen.has(nonce):
		return ""  # Already in the log (a resend after a host swap).
	var error := _check_sender(proposal, from, internal)
	if error.is_empty():
		error = _authorize(proposal, from, internal)
	var entry := _clean(proposal, from == my_id or from == host_id)
	if error.is_empty():
		entry["n"] = state.entry_count() + 1
		error = state.apply(entry)
	if not error.is_empty():
		if from == my_id:
			rejected.emit(error)
		elif not nonce.is_empty():
			transport.send(from, {"m": "reject", "c": nonce, "why": error})
		return error
	if entry["k"] in HASHED:
		entry["h"] = state.fingerprint()
	for id in peers():
		transport.send(id, {"m": "entry", "e": entry})
	_after_applied(entry)
	return ""


## Limits on who may propose and how much: the nonce is the sender's own, there is room in the log, and a peer
## that floods the host is told to slow down.
func _check_sender(proposal: Dictionary, from: int, internal: bool) -> String:
	if internal or from == my_id:
		return ""
	var nonce: Variant = proposal.get("c")
	if nonce is not String or not (nonce as String).begins_with("%d-" % from) or (nonce as String).length() > 24:
		return "bad request"
	if state.entry_count() >= MAX_ENTRIES - 50:
		return TranslationServer.translate("the match log is full")
	var left: float = _budget.get(from, PROPOSALS_BURST)
	if left < 1.0:
		return TranslationServer.translate("too many requests")
	_budget[from] = left - 1.0
	return ""


## The entry the log keeps for a proposal: only the fields its kind has, scalars only, short texts. A peer's `h`, `n`
## and the like never get through; `sys` (an action played by the host for the AI or the timer) only from the host.
func _clean(proposal: Dictionary, from_host: bool) -> Dictionary:
	var kind: Variant = proposal.get("k")
	if kind is not String or not ENTRY_FIELDS.has(kind):
		return proposal.duplicate()  # _authorize refuses it ("unknown request").
	var entry := {"k": kind}
	for field: String in ENTRY_FIELDS[kind]:
		if not proposal.has(field) or (field == "sys" and not from_host):
			continue
		var value: Variant = proposal[field]
		if field == "a":
			if value is Dictionary and (value as Dictionary).size() <= 6:
				entry[field] = value
		elif value is bool or value is int or value is float or (value is String and (value as String).length() <= MAX_FIELD_TEXT):
			entry[field] = value
	var nonce: Variant = proposal.get("c")
	if nonce is String and (nonce as String).length() <= 24:
		entry["c"] = nonce
	return entry


## Who may ask for what. Joins come from a hello, never from a proposal.
func _authorize(entry: Dictionary, from: int, internal: bool) -> String:
	match entry.get("k"):
		"join":
			return "" if internal else "not allowed"
		"set", "ready":
			return "" if entry.get("id") == from else "not your seat"
		"ai":
			# The host decides, and a player may hand their own hero to the AI, or ask for it back
			# when it isn't their hero's turn.
			if from == host_id:
				return ""
			var asked: Variant = entry.get("id")
			if asked == from and (entry.get("v") == true or state.current_seat() != from):
				return ""
			return "only the host can"
		"cfg", "start", "go", "lobby", "drop", "kick":
			return "" if from == host_id else "only the host can"
		"act":
			if entry.get("sys") == true:
				return "" if from == host_id else "only the host can"
			var action := ActionCodec.decode(entry.get("a"))
			if action == null:
				return "malformed action"
			var seat_id := state.seat_of_unit(action.actor_id)
			if seat_id != from or not state.seats.has(from) or state.seats[from].ai:
				return "not your hero"
			return ""
	return "unknown request"


# --- After an entry is applied --------------------------------------------------------------

func _after_applied(entry: Dictionary) -> void:
	var nonce := str(entry.get("c", ""))
	if not nonce.is_empty():
		_seen[nonce] = true
		_pending = _pending.filter(func(p: Dictionary) -> bool: return str(p.get("c")) != nonce)
	var kind: String = entry["k"]
	if kind == "kick" and entry.get("id") == my_id:
		_halt(TranslationServer.translate("The host removed you from the match."))
		return
	if kind == "drop" and entry.get("id") == my_id and not is_host():
		_send_hello()  # The host thought I was gone while my link was fine: ask for my seat back with my token.
	if kind == "drop" and state.phase == MatchState.Phase.BATTLE:
		_absent_since[int(entry["id"])] = _now
	if kind == "join" or (kind == "ai" and entry.get("v") == false):
		_absent_since.erase(int(entry["id"]))
	if kind == "start" or kind == "lobby":
		_placement_elapsed = 0.0
	if kind == "act" or kind == "go" or kind == "start" or kind == "lobby":
		_ai_wait = 0.0
		_note_turn()
	changed.emit()
	entry_applied.emit(entry)


func _note_turn() -> void:
	var unit := state.battle.state.turn_order.current_unit_id() if state.battle != null and state.battle.state.started else -1
	if unit != _turn_unit:
		_turn_unit = unit
		_turn_elapsed = 0.0
		_shown_sent = false
		_turn_credited = false


## My screen has played everything up to my hero's turn and hands me the controls: the turn's clock gives back the
## seconds those animations took (up to PLAYBACK_CREDIT), so a slow playback or a far relay doesn't eat my turn. Sent
## once per turn; the host tells everyone the clock it settled on.
func turn_shown(unit_id: int) -> void:
	if unit_id != _turn_unit or _shown_sent or not controls_unit(unit_id):
		return
	_shown_sent = true
	if is_host():
		_credit_turn(my_id, unit_id)
	else:
		transport.send(host_id, {"m": "shown", "u": unit_id})


func _on_shown(from: int, unit_id: Variant) -> void:
	if is_host() and unit_id is int:
		_credit_turn(from, unit_id)


## The host gives the playback time back, once per turn and only to the player of the hero whose turn it is.
func _credit_turn(from: int, unit_id: int) -> void:
	if _turn_credited or unit_id != _turn_unit or state.seat_of_unit(unit_id) != from:
		return
	_turn_credited = true
	_turn_elapsed -= minf(_turn_elapsed, PLAYBACK_CREDIT)
	transport.broadcast({"m": "clock", "u": unit_id, "t": _turn_elapsed})


## The host's turn clock: the others set theirs to it (their countdowns show the same seconds).
func _on_clock(from: int, unit_id: Variant, elapsed: Variant) -> void:
	if from == host_id and unit_id is int and unit_id == _turn_unit and (elapsed is float or elapsed is int):
		_turn_elapsed = clampf(float(elapsed), 0.0, turn_limit())


## Seconds left to place heroes (-1 when the fight has begun or there is no battle).
func placement_seconds_left() -> float:
	if state.battle == null or state.battle.state.started:
		return -1.0
	return maxf(0.0, PLACEMENT_SECONDS - _placement_elapsed)


## Seconds left on the current turn (the host's clock; -1 when there is no timer).
func turn_seconds_left() -> float:
	if state.battle == null or not state.battle.state.started or state.battle.state.is_over():
		return -1.0
	return maxf(0.0, turn_limit() - _turn_elapsed)


## The seconds the current turn has: the lobby's turn time, or a spirit's short one.
func turn_limit() -> float:
	var unit := state.battle.state.turn_order.current_unit_id() if state.battle != null and state.battle.state.started else -1
	if unit >= 0 and state.battle.state.units[unit].spirit:
		return SPIRIT_TURN_SECONDS
	return float(state.settings["turn"])


# --- Losing peers and host swap -------------------------------------------------------------

func _on_peer_lost(id: int) -> void:
	_dead[id] = true
	if id == host_id and not is_host():
		_elect()


## The seat that should be host now: the lowest one I can reach (me included), counting `extra` as reachable.
func _expected_host(extra := -1) -> int:
	var candidates: Array[int] = [my_id]
	for id in peers():
		if state.seats.has(id) and state.seats[id].connected:
			candidates.append(id)
	if extra != -1 and state.seats.has(extra) and extra not in candidates:
		candidates.append(extra)
	candidates.sort()
	return candidates[0]


func _elect() -> void:
	if peers().is_empty() and state.seat_ids().size() > 1:
		# Nobody left to talk to: the others went, or my own connection broke (the screens say so).
		connection_lost = true
		changed.emit()
	var chosen := _expected_host()
	if chosen == host_id:
		return
	host_id = chosen
	host_changed.emit(chosen)
	if chosen == my_id:
		_electing = true
		_election_have.clear()
		_election_pulling = false
		_election_deadline = _now + ELECTION_WAIT
		for id in peers():
			transport.send(id, {"m": "elected", "host": my_id, "have": state.entry_count()})
	else:
		transport.send(host_id, {"m": "have", "n": state.entry_count()})
		for proposal in _pending:
			transport.send(host_id, {"m": "submit", "p": proposal})


## Someone says they are the host now. I believe it only if I would have chosen them too: they are the lowest seat I
## can reach, and the host I knew is gone (or it already is them).
func _on_elected(from: int, new_host: Variant, have: Variant) -> void:
	if new_host is not int or new_host != from or have is not int or not state.seats.has(from):
		return
	if from != host_id:
		if host_id not in _dead and host_id in peers():
			return  # My host is still there for me.
		if _expected_host(from) != from:
			return
		host_id = from
		host_changed.emit(from)
	transport.send(from, {"m": "have", "n": state.entry_count()})
	for proposal in _pending:
		transport.send(host_id, {"m": "submit", "p": proposal})


func _on_have(from: int, n: Variant) -> void:
	if _electing and n is int:
		_election_have[from] = n


func _election_tick() -> void:
	var waiting := false
	for id in peers():
		if not _election_have.has(id):
			waiting = true
	if not _election_pulling:
		var best := -1
		var best_count := state.entry_count()
		for id in _election_have:
			if _election_have[id] > best_count:
				best = id
				best_count = _election_have[id]
		if best != -1 and (not waiting or _now >= _election_deadline):
			_election_pulling = true
			_election_deadline = _now + ELECTION_WAIT
			_pulling[best] = true
			transport.send(best, {"m": "pull", "from": state.entry_count()})
			return
	if (not waiting and not _election_pulling) or _now >= _election_deadline:
		_finish_election()


## The new host has the longest log it could find: bring the others up to it and carry on.
func _finish_election() -> void:
	_electing = false
	_election_pulling = false
	for id in _election_have:
		if _election_have[id] < state.entry_count() and id in peers():
			transport.send(id, {"m": "entries", "list": state.log.slice(_election_have[id])})
	var held := _held
	_held = []
	for item: Array in held:
		_host_submit(item[0], item[1])
	changed.emit()


# --- The host's clock: absent players, the AI, the turn timer -------------------------------

func _host_tick(delta: float) -> void:
	var alive := peers()
	for id in state.seat_ids():
		var seat := state.seats[id]
		if seat.connected and id != my_id and id not in alive:
			_host_submit(my_id, {"k": "drop", "id": id})
	if state.phase != MatchState.Phase.BATTLE or state.battle == null or state.is_over():
		return
	for id in state.seat_ids():
		var seat := state.seats[id]
		if not seat.connected and not seat.ai and _now - _absent_since.get(id, _now) >= float(state.settings["grace"]):
			_host_submit(my_id, {"k": "ai", "id": id, "v": true})
		elif seat.ai and seat.returning and id != state.current_seat():
			_host_submit(my_id, {"k": "ai", "id": id, "v": false})  # Back at a moment that isn't their hero's turn.
	if not state.battle.state.started:
		if state.everyone_placed() or _placement_elapsed >= PLACEMENT_SECONDS:
			_host_submit(my_id, {"k": "go"})
		return
	var current := state.current_seat()
	if current == -1:
		return
	var seat := state.seats[current]
	if seat.ai:
		_ai_wait += delta
		if _ai_wait >= ai_delay:
			_ai_wait = 0.0
			_play_for_ai(current)
	elif _turn_elapsed >= turn_limit():
		var unit_id := state.unit_of_seat[current]
		_host_submit(my_id, {"k": "act", "sys": true, "a": ActionCodec.encode(BattleActions.EndTurn.new(unit_id))})


func _play_for_ai(seat_id: int) -> void:
	var unit_id: int = state.unit_of_seat[seat_id]
	var action := EnemyAI.choose_next(state.battle.state, unit_id)
	var error := _host_submit(my_id, {"k": "act", "sys": true, "a": ActionCodec.encode(action)})
	if not error.is_empty():
		_host_submit(my_id, {"k": "act", "sys": true, "a": ActionCodec.encode(BattleActions.EndTurn.new(unit_id))})


func _halt(reason: String) -> void:
	if halted_now():
		return
	halt_reason = reason
	halted.emit(reason)

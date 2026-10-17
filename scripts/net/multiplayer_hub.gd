class_name MultiplayerHub
extends Node
## Everything a player needs to be in a match, in one place: the connection to the relay server (RelayTransport)
## and the match session on top of it. A host asks the server for a room and gets its code; a joiner enters a room
## with that code. Either way the session starts once the server has let the player in (`session_started`), and the
## hub polls the network and ticks the session every frame. A returning player gets their seat back with the token
## the browser kept.

signal session_started
signal failed(reason: String)
signal status_changed

## Where the seat's token is kept (tests use another file: the real one is the player's way back into a match).
static var session_file := "user://net_session.cfg"

var transport: RelayTransport
var session: MatchSession
## The room's code ("" until the server has made it, or has let a joiner in).
var room_code := ""
var player_name := ""
var token := ""
## Makes the sockets to the server (tests give fakes).
var make_socket: Callable = func() -> RelaySocket: return RelaySocket.Real.new()
## The server's address ("" = the configured one, see RelayConfig).
var server_url := ""

var _hosting := false
var _token_retried := false


func _process(delta: float) -> void:
	# Real seconds: a fight played fast speeds the scene up (Engine.time_scale), never the turn clock or the timeouts.
	var real := delta / Engine.time_scale if Engine.time_scale > 0.0 else delta
	if transport != null:
		transport.poll(real)
	if session != null:
		session.tick(real)


# --- Opening or joining a match -------------------------------------------------------------

## Asks the server to wake up (a free service sleeps after a quiet quarter of an hour and takes about a minute to
## answer again), so it is ready when a player presses Host or Join. Does nothing outside a browser.
func warm_up() -> void:
	if not WebPage.is_web() or not server_url.is_empty():
		return
	var request := HTTPRequest.new()
	add_child(request)
	request.request_completed.connect(func(_result: int, _code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void: request.queue_free())
	request.request(RelayConfig.health_url())


## Opens a match as its host (seat 1). `session_started` comes when the server has made the room: its code is then
## `room_code`.
func host_room(name_: String) -> void:
	_reset()
	player_name = name_
	token = _random_text(24)
	_hosting = true
	_open()
	transport.open_host(token)


## Joins with a room code (typed, or in a link). Returns an error text, or "". The session starts when the server
## lets the player in (`session_started`); until then `status()` says what is going on.
func join(name_: String, text: String) -> String:
	var code := RoomCode.normalize(text)
	if code.is_empty():
		return TranslationServer.translate("That isn't a room code (6 letters and numbers).")
	_reset()
	player_name = name_
	room_code = code
	token = _stored_token(code)
	_open()
	transport.open_join(code, token)
	return ""


func leave() -> void:
	if session != null:
		session.leave()
	elif transport != null:
		transport.close()
	_reset()


func in_match() -> bool:
	return session != null


## What the connection is doing, for the screen that waits: "" when there is nothing to say.
func status() -> String:
	if transport == null:
		return ""
	match transport.state:
		RelayTransport.State.CONNECTING, RelayTransport.State.WAITING:
			if transport.waited > 6.0:
				return TranslationServer.translate("Waking the game server up... (it sleeps when nobody plays, so the first game of the day takes up to a minute)")
			return TranslationServer.translate("Connecting to the game server...")
		RelayTransport.State.RECONNECTING:
			return TranslationServer.translate("Connection lost: trying to come back...")
	return ""


# --- The server -----------------------------------------------------------------------------

func _open() -> void:
	_token_retried = false
	transport = RelayTransport.new(server_url if not server_url.is_empty() else RelayConfig.url(), make_socket)
	transport.welcomed.connect(_on_welcomed)
	transport.refused.connect(_on_refused)
	transport.connect_failed.connect(_on_connect_failed)
	status_changed.emit()


func _on_welcomed(id: int, code: String, peers: Array) -> void:
	room_code = code
	if _hosting:
		session = MatchSession.open_as_host(transport, player_name, token)
	else:
		# The lowest seat in the room is the host, unless the host swapped (the session is redirected then).
		session = MatchSession.open_as_guest(transport, player_name, token, int(peers.min()) if not peers.is_empty() else id)
	session.halted.connect(_on_halted)
	_store_token()
	session_started.emit()


func _on_refused(why: String) -> void:
	if why == "token_in_use" and not _token_retried:
		# Two tabs of one browser share what the browser remembers: this one is another player, with a token of its own.
		_token_retried = true
		token = _random_text(24)
		transport.retry_join(token)
		return
	var text := ""
	match why:
		"no_room":
			text = TranslationServer.translate("No match has that code. Check it: the host may have left.")
		"room_full":
			text = TranslationServer.translate("The match is full.")
		"slow_down":
			text = TranslationServer.translate("Too many wrong codes: wait a minute and try again.")
		"server_full":
			text = TranslationServer.translate("The game server is full: try again in a few minutes.")
		_:
			text = TranslationServer.translate("The game server refused the request.")
	_reset()
	failed.emit(text)


## The match can't go on (it refused the player, a desync...): the session's reason is a fragment ("the match is full").
func _on_halted(reason: String) -> void:
	failed.emit(reason.left(1).to_upper() + reason.substr(1))


func _on_connect_failed(reason: String) -> void:
	_reset()
	failed.emit(reason)


func _reset() -> void:
	if transport != null:
		transport.close()
	transport = null
	session = null
	room_code = ""
	_hosting = false


# --- The token ------------------------------------------------------------------------------

## The token this browser kept for this room, else a new one.
func _stored_token(room_name: String) -> String:
	var file := ConfigFile.new()
	if file.load(session_file) == OK and file.get_value("seat", "room", "") == room_name:
		var kept: Variant = file.get_value("seat", "token", "")
		if kept is String and (kept as String).length() >= 8:
			return kept
	return _random_text(24)


func _store_token() -> void:
	if session == null:
		return
	var file := ConfigFile.new()
	file.set_value("seat", "room", room_code)
	file.set_value("seat", "id", session.my_id)
	file.set_value("seat", "token", token)
	file.save(session_file)


static func _random_text(length: int) -> String:
	var alphabet := "abcdefghjkmnpqrstuvwxyz23456789"
	var bytes := Crypto.new().generate_random_bytes(length)
	var text := ""
	for value in bytes:
		text += alphabet[value % alphabet.length()]
	return text

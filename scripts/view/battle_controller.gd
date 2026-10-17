class_name BattleController
extends Node3D
## What every fight screen shares (solo and multiplayer): wires views, HUD and camera, takes the
## player's clicks and keys and shows the battle as it plays. Actions go through one path:
## Battle.perform() → EventPlayer.play() → views sync to the state → next turn. What differs is
## left to the subclasses through hooks: where the battle comes from (_create_battle_state), who
## decides the next turn (_next_turn, or _begin_next altogether) and how an action is sent
## (_perform). SoloBattleController runs the AI and adds the tutorial, tips and QA tools;
## NetBattleController follows the match's log.
##
## Input states (enum FSM): IDLE (player's turn, moving), TARGETING (a spell is aimed),
## ANIMATING (events playing), ENEMY_TURN (someone else is acting), ENDED (result shown).
## Signals up from the HUD and camera, calls down to them.

## The battle just ended (the result screen shows). The state is final: the caller applies
## and saves rewards now, so closing the game on the result screen loses nothing.
## A sound to hear (an AudioSet.SFX_EVENTS name), from the playback or the turn flow.
signal sound(event: StringName)

## The battle speed was changed with the HUD button (the Game root saves the settings).
signal speed_changed


signal battle_ended(state: BattleState)
## The player left the fight from the HUD's menu: nothing from it is kept.
signal left_battle
## The fight began or ended: the Game root's menu button is offered while it is on (see menu_available).
signal menu_changed
## A battle set up by setup() ended and the player chose to continue.
signal battle_finished(state: BattleState)

## PLACING: before the first turn, heroes are rearranged in the start zone until Ready.
enum State { PLACING, IDLE, TARGETING, ANIMATING, ENEMY_TURN, ENDED }

## The web build's Compatibility renderer lights the same scene brighter than Forward+
## (no filmic tonemapping), so its lights are scaled down.
const WEB_LIGHT_SCALE := 0.6

## Where the camera starts: this far from the board's centre toward the start zone (0 to 1).
const START_FOCUS_TOWARD_ZONE := 0.35
## Time scale of the "fast" battle speed.
const FAST_TIME_SCALE := 2.0
## Pause before the turn ends by itself (auto end turn), so the player sees what happened.
const AUTO_END_DELAY := 0.5
## The same in card combat: long enough to throw cards away after the last play (each throw starts it again).
const AUTO_END_CARDS_DELAY := 2.5
## How long the camera takes to reach an enemy that starts its turn off screen.
const ENEMY_FOCUS_DURATION := 0.45

## False once setup() was called: the Game root owns what happens after the battle.
var standalone := true
## Stalemate safety net (0: off); see Battle.sudden_death_round.
var sudden_death_round := 0
var sudden_death_percent := 10
## Shown before the round number in the HUD (e.g. "Floor 3").
var battle_title := ""
## The heroes' levels, parallel to `players` (shown in the HUD cards); empty: not shown.
var player_levels: Array = []
var _sudden_death_announced := false

var battle: Battle
## The seed of the current battle; set rng_seed to it to replay a battle.
var battle_seed := 0
var input_state := State.ENDED
var selected_spell := -1
## Card combat: the hand position of the card being aimed (selected_spell is its spell slot); -1 otherwise.
var selected_card := -1

var _hovered_cell := BoardView.NO_CELL
var _reach: Movement.Reach
var _targetable: Dictionary[Vector2i, bool] = {}
## While aiming: the cells in range that can't be aimed at (shaded); a click there keeps the aim.
var _blocked: Dictionary[Vector2i, bool] = {}
## The hero selected for placement (a unit id), or -1.
var _placing_hero := -1
## The unit whose card is pinned (a unit id), or -1; only the card's ✕ or Esc unpins.
var _pinned_unit := -1
## What the HUD displays, following the played events (see HudModel).
var _hud_model: HudModel
## The spell under the mouse in the HUD (null: none): its range shows on the board (see _update_spell_preview).
var _hovered_spell: SpellData
## Whether it is one of the spell bar's (cast by _spells_unit_id()), not a row of the inspect card (cast by its unit).
var _hovered_spell_on_bar := false
## The unit on the inspect card, or -1.
var _inspected_unit := -1
## The unit whose turn-order chip the mouse is over, or -1: its cell counts as hovered.
var _chip_unit := -1
## A left press started on the board (not on the HUD): its release may be a click.
var _board_press := false
## The cell under the press, to compare with the one under the release.
var _press_cell := BoardView.NO_CELL
## Bumped by each new battle; coroutines of an abandoned battle stop after their awaits.
var _battle_generation := 0

@onready var camera_rig: CameraRig = $CameraRig
@onready var board_view: BoardView = $BoardView
@onready var units_view: UnitsView = $UnitsView
@onready var event_player: EventPlayer = $EventPlayer
@onready var hud: Hud = $Hud


## The player's settings (battle speed, auto end turn); the Game root hands in its own, edited in
## place. A standalone battle uses the defaults.
var settings := Settings.new()
## Whether this controller set Engine.time_scale (so it gives it back).
var _set_time_scale := false
## Bumped each time the turn may end by itself: only the latest wait ends it.
var _auto_end_serial := 0


func _exit_tree() -> void:
	if _set_time_scale:
		Engine.time_scale = 1.0


## Puts the settings' battle speed into effect: fast speeds the whole scene up (the rules never
## look at the clock), instant makes the event player skip its animations.
func apply_battle_speed() -> void:
	var speed := _battle_speed()
	hud.set_battle_speed(speed)
	event_player.instant = speed == Settings.BattleSpeed.INSTANT
	if speed == Settings.BattleSpeed.FAST:
		Engine.time_scale = FAST_TIME_SCALE
		_set_time_scale = true
	elif _set_time_scale:
		Engine.time_scale = 1.0
		_set_time_scale = false


## The speed this fight plays at: the player's setting (a multiplayer match plays at one speed for everyone).
func _battle_speed() -> Settings.BattleSpeed:
	return settings.battle_speed


## The HUD button: normal, fast, instant, normal...
func cycle_battle_speed() -> void:
	settings.battle_speed = ((settings.battle_speed + 1) % Settings.BattleSpeed.size()) as Settings.BattleSpeed
	apply_battle_speed()
	speed_changed.emit()


func _ready() -> void:
	if OS.has_feature("web"):
		$DirectionalLight3D.light_energy *= WEB_LIGHT_SCALE
		$WorldEnvironment.environment.ambient_light_energy *= WEB_LIGHT_SCALE
	# The light turns with the camera, so the shadows fall the same way on screen from every
	# side (a fixed light made them look different, even broken, as the camera turned).
	$DirectionalLight3D.reparent(camera_rig)
	hud.spell_selected.connect(select_spell)
	hud.card_discarded.connect(discard_card)
	hud.spell_hovered.connect(_on_spell_hovered)
	hud.end_turn_pressed.connect(end_turn)
	hud.view_toggle_pressed.connect(func() -> void: camera_rig.set_overhead(not camera_rig.overhead))
	hud.restart_pressed.connect(_on_result_action)
	hud.card_closed.connect(unpin)
	hud.leave_confirmed.connect(left_battle.emit)
	hud.recenter_pressed.connect(recenter)
	hud.speed_pressed.connect(cycle_battle_speed)
	apply_battle_speed()
	hud.chip_hovered.connect(_on_chip_hovered)
	hud.chip_unhovered.connect(_on_chip_unhovered)
	hud.chip_pressed.connect(_on_chip_pressed)
	hud.set_result_action_text("Play again" if standalone else "Continue")
	camera_rig.overhead_changed.connect(hud.set_overhead_view)
	event_player.event_played.connect(_on_event_played)
	event_player.sound.connect(sound.emit)
	_connect_extras()
	start_battle()


## Builds a fresh battle (see _create_battle_state) and starts it.
## Returns false (and changes nothing) if the battle can't be made.
func start_battle() -> bool:
	var battle_state := _create_battle_state()
	if battle_state == null:
		return false  # Whoever made it reported why.
	event_player.stop()  # Abandon the previous battle's playback, if any.
	_battle_generation += 1
	battle = Battle.new(battle_state)
	battle.sudden_death_round = sudden_death_round
	battle.sudden_death_percent = sudden_death_percent
	_sudden_death_announced = false
	selected_spell = -1
	selected_card = -1
	board_view.build(battle_state.grid)
	units_view.build(battle_state, board_view)
	units_view.viewer_team = _viewer_team()
	units_view.refresh_visibility(battle_state)
	event_player.setup(units_view, board_view, camera_rig)
	camera_rig.set_bounds(Rect2(Vector2.ZERO, Vector2(battle_state.grid.size - Vector2i.ONE) * BoardView.CELL_SIZE))
	camera_rig.fit_board(battle_state.grid.size)
	# A third of the way to the start zone: on a big board the heroes stay clear of the HUD.
	var zone_center := _spawn_center(_placement_zone_for_camera(battle_state))
	camera_rig.focus(board_view.center().lerp(zone_center, START_FOCUS_TOWARD_ZONE))
	camera_rig.face_toward(zone_center - board_view.center())
	hud.hide_result()
	_placing_hero = -1
	_pinned_unit = -1
	_chip_unit = -1
	_refresh_hud()
	_set_state(State.PLACING)
	_battle_started()
	return true


## The team of the player looking at the board: what its enemies hide in stealth is not drawn. The multiplayer
## controller answers with the local player's side.
func _viewer_team() -> UnitState.Team:
	return UnitState.Team.PLAYER


## The state of the battle about to start; null (with an error) if it can't be made. Subclasses say where it comes from:
## the solo controller builds it from an encounter, the multiplayer one takes the match's.
func _create_battle_state() -> BattleState:
	push_error("BattleController: no source for the battle's state")
	return null


## The cells the camera starts toward (the heroes' start zone).
func _placement_zone_for_camera(battle_state: BattleState) -> Array[Vector2i]:
	return battle_state.zone


## The cells to show as the start zone while heroes are placed.
func _placement_zone() -> Array[Vector2i]:
	return battle.state.zone


## Abandons the current battle (even mid-animation) and starts a new one.
func restart() -> void:
	start_battle()


func _on_result_action() -> void:
	if standalone:
		restart()
	else:
		battle_finished.emit(battle.state)


# --- Hooks for the subclasses ---

## Wiring only a subclass needs, before the battle starts.
func _connect_extras() -> void:
	pass


## The battle was just built and its placement begins.
func _battle_started() -> void:
	pass


## Whether the player may do this now (the solo tutorial lets only the step's own action through).
func _allows(_action: Tutorial.Action) -> bool:
	return true


## The player did this (the solo tutorial marks its step done).
func _action_done(_action: Tutorial.Action) -> void:
	pass


## Whether something on screen asks the player to wait (a tutorial step is up): auto end turn holds back.
func _waiting_for_guide() -> bool:
	return false


## A playback event is being shown (the solo tips look for the first status).
func _event_seen(_event: BattleEvents.Event) -> void:
	pass


## The state just changed: refresh what depends on it that the core doesn't know (the solo tutorial and QA bar).
func _refresh_extras() -> void:
	pass


## A turn begins in a battle that is on and not over: who acts next? (The solo controller lets the player in, or the
## AI play.) The multiplayer controller doesn't come here: it follows the log (_begin_next).
func _next_turn() -> void:
	_set_state(State.ENEMY_TURN)


# --- Player commands (from the HUD and board clicks) ---

## Selects a spell to aim, or unselects it if it's already selected. In card combat `index` is a hand position.
func select_spell(index: int) -> void:
	if input_state != State.IDLE and input_state != State.TARGETING:
		return
	var unit := battle.state.current_unit()
	var slot := index
	if battle.state.cards:
		if index < 0 or index >= unit.hand.size():
			_enter_idle()
			return
		slot = unit.hand[index]
	var again := index == selected_card if battle.state.cards else index == selected_spell
	if again or not BattleActions.CastSpell.can_afford(unit, slot):
		_enter_idle()
		return
	if not _allows(Tutorial.Action.SELECT_SPELL):
		return
	selected_spell = slot
	selected_card = index if battle.state.cards else -1
	_action_done(Tutorial.Action.SELECT_SPELL)
	_set_state(State.TARGETING)


## Card combat: throws the card at that hand position away (free).
func discard_card(position: int) -> void:
	if input_state != State.IDLE and input_state != State.TARGETING:
		return
	var unit := battle.state.current_unit()
	if not battle.state.cards or position < 0 or position >= unit.hand.size():
		return
	selected_spell = -1
	selected_card = -1
	_perform(BattleActions.DiscardCard.new(unit.id, unit.hand[position]))


## Whether the menu button (the Game root's top bar) is offered: not once the result is showing.
func menu_available() -> bool:
	return input_state != State.ENDED


## The menu button: asks whether to leave the fight.
func open_menu() -> void:
	if menu_available():
		hud.open_leave_panel()


## Esc / right click: closes the leave confirmation or the order overlay, else stops aiming, else deselects the hero
## being placed, else unpins the card.
func cancel() -> void:
	if hud.close_leave_panel() or hud.close_order_overlay():
		return
	if input_state == State.TARGETING:
		_enter_idle()
	elif input_state == State.PLACING and _placing_hero != -1:
		_placing_hero = -1
		_set_state(State.PLACING)
	else:
		unpin()


## Pins a unit's card on the right; it stays until unpinned, even when the mouse leaves.
func pin(unit_id: int) -> void:
	if unit_id == _pinned_unit:
		return
	_pinned_unit = unit_id
	_update_inspected()


func unpin() -> void:
	if _pinned_unit != -1:
		_pinned_unit = -1
		_update_inspected()


## Ends the turn, or ends placement and starts the fight.
func end_turn() -> void:
	if input_state == State.PLACING:
		_press_ready()
	elif input_state == State.IDLE or input_state == State.TARGETING:
		if not _allows(Tutorial.Action.END_TURN):
			return
		_perform(BattleActions.EndTurn.new(battle.state.current_unit().id))


## Ready (during placement): the fight starts. The multiplayer controller tells the host instead.
func _press_ready() -> void:
	if not _allows(Tutorial.Action.READY):
		return
	_placing_hero = -1
	_action_done(Tutorial.Action.READY)
	_play(battle.start())


## A click on a board cell (or on a unit standing there).
func click_cell(cell: Vector2i) -> void:
	if battle == null:
		return
	var unit_id := battle.state.current_unit().id
	var clicked := battle.state.unit_at(cell)
	# A click that casts, moves or places is that action only; one that does nothing else pins the
	# unit under it (to look at it).
	var action := _click_action(cell, clicked)
	if clicked != null and clicked.id != _active_card_unit_id() and action == -1:
		pin(clicked.id)
	if action != -1 and not _allows(action as Tutorial.Action):
		return  # The tutorial lets only the step's own action through.
	match input_state:
		State.PLACING:
			_click_placing(cell)
		State.IDLE:
			if _reach != null and _reach.can_reach(cell):
				_perform(BattleActions.Move.new(unit_id, cell))
		State.TARGETING:
			if _targetable.has(cell):
				_perform(BattleActions.CastSpell.new(unit_id, selected_spell, cell))
			elif not _blocked.has(cell):
				_click_off_target()


## A click out of the aimed spell's range (or beside the board) stops aiming, like Esc; one on a shaded cell, in range
## but not aimable, keeps it (a near miss). Not while a tutorial step is up: a stray click would undo the step the
## player is following.
func _click_off_target() -> void:
	if input_state == State.TARGETING and not _waiting_for_guide():
		_enter_idle()


## A click during placement: select a hero, then a zone cell (a hero there swaps); the selected hero again
## deselects. The multiplayer controller places the player's only hero straight away.
func _click_placing(cell: Vector2i) -> void:
	var unit := battle.state.unit_at(cell)
	if _placing_hero == -1:
		if unit != null and unit.team == UnitState.Team.PLAYER:
			_placing_hero = unit.id
			_refresh_hud()
			_set_state(State.PLACING)
	elif unit != null and unit.id == _placing_hero:
		cancel()
	elif cell in battle.state.zone:
		var hero := _placing_hero
		_placing_hero = -1
		_perform(BattleActions.Place.new(hero, cell))


## What a click during placement does, as a Tutorial.Action (-1: nothing).
func _placing_click_action(cell: Vector2i, clicked: UnitState) -> int:
	if _placing_hero == -1:
		return Tutorial.Action.PLACE if clicked != null and clicked.team == UnitState.Team.PLAYER else -1
	return Tutorial.Action.PLACE if cell in battle.state.zone or (clicked != null and clicked.id == _placing_hero) else -1


## What a click on `cell` (with `clicked` on it) does in the current state, as a Tutorial.Action:
## picks or places a hero, moves, or casts; -1 when it does nothing.
func _click_action(cell: Vector2i, clicked: UnitState) -> int:
	match input_state:
		State.PLACING:
			return _placing_click_action(cell, clicked)
		State.IDLE:
			return Tutorial.Action.MOVE if _reach != null and _reach.can_reach(cell) else -1
		State.TARGETING:
			return Tutorial.Action.CAST if _targetable.has(cell) else -1
	return -1


# --- Input ---

## Right click over a HUD control stops aiming too: the control eats the click before
## _unhandled_input would see it.
func _input(event: InputEvent) -> void:
	if input_state == State.TARGETING and event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_RIGHT and get_viewport().gui_get_hovered_control() != null:
		cancel()
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"cancel"):
		cancel()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"camera_recenter"):
		recenter()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		# A click acts on release, unless the press turned into a camera drag; a press the HUD
		# ate never reaches here, so its release can't click the board.
		if event.pressed:
			_board_press = true
			_press_cell = board_view.pick_cell(camera_rig.camera, event.position)
		elif _board_press:
			_board_press = false
			# Only a release on the cell that was pressed, over the board, after no drag: a release
			# over the HUD, or after the camera slid under the cursor, is not a click.
			if not camera_rig.dragged and get_viewport().gui_get_hovered_control() == null:
				var cell := board_view.pick_cell(camera_rig.camera, event.position)
				if cell != BoardView.NO_CELL and cell == _press_cell:
					click_cell(cell)
					get_viewport().set_input_as_handled()
				elif cell == BoardView.NO_CELL and _press_cell == BoardView.NO_CELL:
					_click_off_target()  # A click beside the board.


## Per-frame work of a subclass (the solo tutorial keeps its spotlight on target); nothing here.
func _process(_delta: float) -> void:
	pass


## Hover is re-picked every physics frame from the mouse position, so it also follows
## camera turns and zooms; highlights only change when the hovered cell does.
func _physics_process(_delta: float) -> void:
	camera_rig.pan_enabled = not hud.is_modal_open()  # Arrow keys drive the menus over the board.
	if board_view.grid == null:
		return
	var cell := _hover_cell(get_viewport().gui_get_hovered_control(), get_viewport().get_mouse_position())
	if cell != _hovered_cell:
		_hovered_cell = cell
		_update_hover()
	_update_see_through()


## Obstacles that hide a living unit from the camera fade. (Not the hovered cell: the mouse only
## ever picks what is in front, so fading for it just made rocks vanish at random.)
func _update_see_through() -> void:
	if camera_rig.camera == null or battle == null:
		return
	var targets: Array[Vector3] = []
	for unit in battle.state.units:
		var view := units_view.find_view(unit.id)
		if unit.is_alive() and view != null:
			# The feet are what a rock hides first, the middle what a taller thing would.
			targets.append(view.global_position + Vector3.UP * 0.15)
			targets.append(view.global_position + Vector3.UP * view.world_height() * 0.5)
	board_view.look_through(camera_rig.camera.global_position, targets)


## The cell the mouse designates: none over the HUD, except over the inspect panel, where
## the hover sticks (so the panel stays up and its tooltips can be read).
func _hover_cell(hovered_control: Control, mouse_position: Vector2) -> Vector2i:
	if _chip_unit != -1 and battle != null:
		return battle.state.units[_chip_unit].cell
	if hovered_control != null:
		return _hovered_cell if hud.is_inspect_control(hovered_control) else BoardView.NO_CELL
	return board_view.pick_cell(camera_rig.camera, mouse_position)


func _on_chip_hovered(unit_id: int) -> void:
	_chip_unit = unit_id if battle != null and unit_id >= 0 and unit_id < battle.state.units.size() else -1


func _on_chip_unhovered() -> void:
	_chip_unit = -1


## Clicking a turn-order chip moves the camera to its unit.
func _on_chip_pressed(unit_id: int) -> void:
	focus_unit(unit_id)


## Slides the camera to a unit, where it is drawn right now (the state is already final while
## events play, so a unit's cell would be where it will end up).
func focus_unit(unit_id: int) -> void:
	if battle == null or unit_id < 0 or unit_id >= battle.state.units.size():
		return
	if battle.state.is_hidden_from(battle.state.units[unit_id], units_view.viewer_team):
		return  # Where a hidden unit is, is not the viewer's to know.
	var view := units_view.find_view(unit_id)
	var point := view.position if view != null else board_view.cell_to_world(battle.state.units[unit_id].cell)
	camera_rig.focus_on(point)


## The camera at a turn's start: an ally's turn (the viewer's team) always centers on it; an enemy's turn moves the
## camera only when the enemy isn't comfortably on screen already (and then slowly), so a run
## of enemy turns in view doesn't make the view dart between them.
func _focus_turn_start(unit_id: int) -> void:
	if battle == null or unit_id < 0 or unit_id >= battle.state.units.size():
		return
	if battle.state.units[unit_id].team == units_view.viewer_team:
		focus_unit(unit_id)
		return
	if battle.state.is_hidden_from(battle.state.units[unit_id], units_view.viewer_team):
		return
	var view := units_view.find_view(unit_id)
	var point := view.position if view != null else board_view.cell_to_world(battle.state.units[unit_id].cell)
	if not camera_rig.is_on_screen([point] as Array[Vector3]):
		camera_rig.focus_on(point, true, ENEMY_FOCUS_DURATION)


## Back to the acting unit (the Recenter key and button).
func recenter() -> void:
	if battle != null and battle.state.started and _hud_model.current_id != -1:
		focus_unit(_hud_model.current_id)  # The acting unit on screen: the state is already final while events play.
	elif battle != null:
		camera_rig.focus_on(board_view.center())


# --- Turn loop ---

func _perform(action: BattleActions.Action) -> void:
	var result := battle.perform(action)
	if not result.ok():
		push_warning("Battle: %s" % result.error)  # A UI bug; the state is unchanged.
		return
	if action is BattleActions.Move:
		_action_done(Tutorial.Action.MOVE)
	elif action is BattleActions.CastSpell:
		_action_done(Tutorial.Action.CAST)
	elif action is BattleActions.EndTurn and battle.state.units[action.actor_id].team == UnitState.Team.PLAYER:
		_action_done(Tutorial.Action.END_TURN)
	_play(result.events)


func _play(events: Array[BattleEvents.Event]) -> void:
	var generation := _battle_generation
	_set_state(State.ANIMATING)
	units_view.refresh_visibility(battle.state)  # Who went into or out of stealth shows from the start of the action.
	await event_player.play(events)
	if generation != _battle_generation:
		return  # This battle was abandoned while its events played.
	units_view.sync(battle.state)
	_begin_next()


## Decides what happens after a playback: result, player's input, or the AI's next action.
func _begin_next() -> void:
	var battle_state := battle.state
	_refresh_hud()
	if not battle_state.started:
		_set_state(State.PLACING)
		return
	units_view.set_active(battle_state.current_unit().id if not battle_state.is_over() else -1)
	if battle_state.is_over():
		# A mutual wipe (DRAW) is shown as a defeat (decision record).
		_finish_battle(battle_state.outcome() == BattleState.Outcome.PLAYER_WON)
		return
	_next_turn()


## The battle is over: the result screen, the fanfare and the winners' cheer. `won` is for the local player (the
## multiplayer controller works it out from their side).
func _finish_battle(won: bool) -> void:
	var state := battle.state
	_set_state(State.ENDED)
	sound.emit(&"victory" if won else &"defeat")
	_cheer(UnitState.Team.PLAYER if state.outcome() == BattleState.Outcome.PLAYER_WON else UnitState.Team.ENEMY, state)
	hud.show_result(won, battle_seed)
	battle_ended.emit(state)


## The survivors of the winning team play their victory animation (heroes after a win, the
## enemies after a loss), over the fanfare.
func _cheer(winners: UnitState.Team, state: BattleState) -> void:
	for unit in state.units:
		if unit.team == winners and unit.is_alive():
			var view := units_view.find_view(unit.id)
			if view != null:
				view.play_victory()


func _on_event_played(event: BattleEvents.Event) -> void:
	_event_seen(event)
	_hud_model.apply(event)
	_show_turn()
	if event is BattleEvents.TurnStarted:
		_focus_turn_start((event as BattleEvents.TurnStarted).unit_id)  # Every turn, ally or enemy: the camera follows the action.
	if event is BattleEvents.TurnStarted and battle.is_sudden_death() and not _sudden_death_announced:
		_sudden_death_announced = true
		if battle.state.pvp:
			hud.show_banner(tr("Sudden death: every hero loses %d%% HP every turn") % sudden_death_percent)
		else:
			hud.show_banner(tr("Sudden death: the party loses %d%% HP every turn") % sudden_death_percent)
		return
	if event is BattleEvents.TurnStarted:
		var unit := battle.state.units[(event as BattleEvents.TurnStarted).unit_id]
		if unit.team == units_view.viewer_team:
			sound.emit(&"turn_start")
		hud.show_banner(_turn_banner_text(unit))


## The banner at a turn's start: the unit's turn (multiplayer names the player, and says when it is the viewer's own).
func _turn_banner_text(unit: UnitState) -> String:
	return tr("%s's turn") % tr(unit.data.display_name)


# --- State and highlights ---

func _enter_idle() -> void:
	selected_spell = -1
	selected_card = -1
	_set_state(State.IDLE)


func _set_state(new_state: State) -> void:
	var menu_was_on := menu_available()
	input_state = new_state
	if menu_available() != menu_was_on:
		menu_changed.emit()
	var player_turn := new_state == State.IDLE or new_state == State.TARGETING or new_state == State.PLACING
	hud.set_player_controls_enabled(player_turn)
	hud.set_placing(new_state == State.PLACING)
	hud.set_selected_spell((selected_card if selected_card >= 0 else selected_spell) if new_state == State.TARGETING else -1)
	board_view.clear_highlights()
	units_view.clear_previews()
	_reach = null
	_targetable.clear()
	_blocked.clear()
	var unit_id := battle.state.current_unit().id if battle != null and not battle.state.is_over() else -1
	match new_state:
		State.PLACING:
			units_view.set_active(_placing_hero)
			board_view.show_highlight(BoardView.Highlight.ZONE, _placement_zone())
		State.IDLE:
			# As the player sees the board: a hidden enemy leaves no hole in the highlighted cells, and a move through
			# its cell is allowed (it is found by walking into it, see BattleActions.Move).
			_reach = Movement.reach(battle.state, unit_id, true)
			board_view.show_highlight(BoardView.Highlight.REACH, _reach.cells())
		State.TARGETING:
			var spell := battle.state.units[unit_id].data.spells[selected_spell]
			var cells := Targeting.targetable_cells(battle.state, unit_id, spell)
			for cell in cells:
				_targetable[cell] = true
			board_view.show_highlight(BoardView.Highlight.RANGE, cells)
			var blocked := Targeting.blocked_cells(battle.state, unit_id, spell)
			for cell in blocked:
				_blocked[cell] = true
			board_view.show_highlight(BoardView.Highlight.RANGE_BLOCKED, blocked)
	_update_spell_preview()
	hud.set_prompt(_prompt_text())
	hud.set_end_turn_pulse(new_state == State.IDLE and _nothing_left_to_do())
	if new_state == State.IDLE and settings.auto_end_turn and _nothing_left_to_do():
		_end_turn_soon()
	_refresh_extras()
	_update_hover()


## Auto end turn: ends the turn after a short pause, if the hero still has nothing to do then.
func _end_turn_soon() -> void:
	var generation := _battle_generation
	var turn := battle.state.current_unit().id
	_auto_end_serial += 1
	var serial := _auto_end_serial
	if battle.state.cards:
		await get_tree().create_timer(AUTO_END_CARDS_DELAY, true, false, true).timeout  # Real seconds, at any speed.
	elif event_player.instant:
		await get_tree().process_frame
	else:
		await create_tween().tween_interval(AUTO_END_DELAY).finished
	# While a tutorial step is up the player follows it: the step's own card must be readable.
	if generation == _battle_generation and serial == _auto_end_serial and input_state == State.IDLE \
			and battle.state.current_unit().id == turn \
			and not battle.state.is_over() and _nothing_left_to_do() and not _waiting_for_guide():
		end_turn()


## The guidance line for the current step.
func _prompt_text() -> String:
	match input_state:
		State.PLACING:
			if _placing_hero == -1:
				return tr("Place your heroes: click one, then a teal cell. Ready (%s) to fight") % SettingsApplier.key_text(&"end_turn")
			return tr("Click a teal cell to place %s (Esc to deselect)") % tr(battle.state.units[_placing_hero].label)
		State.IDLE:
			if _nothing_left_to_do():
				return tr("Nothing left to do: end your turn (%s)") % SettingsApplier.key_text(&"end_turn")
			return tr("Move to a blue cell or pick a spell (%s)") % _spell_keys_text(_spell_slot_count())
		State.TARGETING:
			var spell_name := tr(battle.state.current_unit().data.spells[selected_spell].display_name)
			if _targetable.is_empty():
				return tr("%s has no target from here (its reach is shaded). Esc to cancel") % spell_name
			return tr("Choose a target for %s (orange cells). Esc to cancel") % spell_name
		State.ENEMY_TURN:
			return tr("%s is acting...") % tr(battle.state.current_unit().label)
	return ""


## How many slots the spell bar has now: the spells, or the cards of the hand.
func _spell_slot_count() -> int:
	var unit := battle.state.current_unit()
	return unit.hand.size() if battle.state.cards else unit.data.spells.size()


## The keys of the spell slots, e.g. "1-3", or "1" for one spell.
func _spell_keys_text(spell_count: int) -> String:
	var count := clampi(spell_count, 1, SpellBar.MAX_KEYED_SLOTS)
	var first := SettingsApplier.key_text(&"spell_1")
	return first if count == 1 else "%s-%s" % [first, SettingsApplier.key_text(StringName("spell_%d" % count))]


## The acting hero can't afford any spell and has no MP left (repositioning back alone
## wouldn't help).
func _nothing_left_to_do() -> bool:
	var unit := battle.state.current_unit()
	if unit.mp > 0 and _reach != null and not _reach.cells().is_empty():
		return false
	for slot in unit.data.spells.size():
		if BattleActions.CastSpell.can_afford(unit, slot):
			return false
	return true


func _on_spell_hovered(spell: SpellData, on_bar: bool) -> void:
	_hovered_spell = spell
	_hovered_spell_on_bar = on_bar
	_update_spell_preview()


## The hovered spell's range on the board, from where its caster stands: orange where it sees, darker out of its
## line of sight. In every state but aiming (the aimed spell's own cells are up) and the result: on another player's
## turn too, to plan the next one. The move zone steps aside meanwhile, so the two don't mix.
func _update_spell_preview() -> void:
	if battle == null or input_state == State.TARGETING:
		return
	var caster := _spell_preview_caster()
	var in_sight: Array[Vector2i] = []
	var out_of_sight: Array[Vector2i] = []
	if caster != null:
		var cells := Targeting.range_preview(battle.state, caster.id, _hovered_spell)
		for cell in cells:
			if cells[cell]:
				in_sight.append(cell)
			else:
				out_of_sight.append(cell)
	board_view.show_highlight(BoardView.Highlight.RANGE, in_sight)
	board_view.show_highlight(BoardView.Highlight.RANGE_BLOCKED, out_of_sight)
	if input_state == State.IDLE and _reach != null:
		board_view.show_highlight(BoardView.Highlight.REACH, [] as Array[Vector2i] if caster != null else _reach.cells())


## Who casts the hovered spell: the spell bar's unit, or the inspected one for a row of its card; null when no spell
## is hovered, or its caster is down or hidden from the viewer.
func _spell_preview_caster() -> UnitState:
	if _hovered_spell == null or input_state == State.ENDED:
		return null
	var unit_id := _spells_unit_id() if _hovered_spell_on_bar else _inspected_unit
	if unit_id < 0 or unit_id >= battle.state.units.size():
		return null
	var unit := battle.state.units[unit_id]
	if not unit.is_alive() or battle.state.is_hidden_from(unit, units_view.viewer_team):
		return null
	return unit


## Path to the hovered cell while moving, or the spell's area while aiming; in any state,
## the hovered unit (other than the one acting) in the HUD's inspect panel.
func _update_hover() -> void:
	_update_inspected()
	var cells: Array[Vector2i] = []
	match input_state:
		State.PLACING:
			if _placing_hero != -1:
				cells.append(battle.state.units[_placing_hero].cell)
				if _hovered_cell in battle.state.zone:
					cells.append(_hovered_cell)
			board_view.show_highlight(BoardView.Highlight.PATH, cells)
		State.IDLE:
			board_view.clear_path_cost()
			if _reach != null and _reach.can_reach(_hovered_cell):
				# The walk from where the hero stands; the cost counts from where its move started.
				var unit_id := battle.state.current_unit().id
				cells = Movement.walk_path(battle.state, unit_id, _hovered_cell) \
						if _reach.origin != _reach.standing else _reach.path_to(_hovered_cell)
				board_view.show_path_cost(_hovered_cell, _reach.cost_to(_hovered_cell),
						Movement.climbing_steps(battle.state.grid, _reach.standing, cells))
			board_view.show_highlight(BoardView.Highlight.PATH, cells)
		State.TARGETING:
			if _targetable.has(_hovered_cell):
				var caster := battle.state.current_unit()
				var spell := caster.data.spells[selected_spell]
				cells = Targeting.area_cells(battle.state.grid, spell.area, caster.cell, _hovered_cell)
				units_view.show_previews(DamagePreview.for_cast(battle.state, caster.id, selected_spell, _hovered_cell))
				var landings: Array[Vector2i] = []
				landings.assign(DamagePreview.landings(battle.state, caster.id, selected_spell, _hovered_cell).values())
				board_view.show_highlight(BoardView.Highlight.LANDING, landings)
			else:
				units_view.clear_previews()
				board_view.clear_highlight(BoardView.Highlight.LANDING)
			board_view.show_highlight(BoardView.Highlight.AREA, cells)
		# Other states: _set_state already cleared the hover highlights, and the AREA layer
		# may be showing a cast's flash from the EventPlayer, which hover must not touch.
	if _chip_unit != -1 and input_state in [State.PLACING, State.IDLE, State.TARGETING]:
		board_view.show_highlight(BoardView.Highlight.PATH, [battle.state.units[_chip_unit].cell] as Array[Vector2i])


## The right-hand card: the hovered unit, else the pinned one (with its ✕). The unit on
## the active card is never repeated there.
func _update_inspected() -> void:
	var shown: UnitInfo = null
	var pinned := false
	if battle != null and _pinned_unit != -1 and _hud_model.infos[_pinned_unit].hp <= 0:
		_pinned_unit = -1  # A fallen unit's card goes away.
	if battle != null:
		var active_id := _active_card_unit_id()
		if _hovered_cell != BoardView.NO_CELL:
			var hovered := battle.state.unit_at(_hovered_cell)
			if hovered != null and hovered.id != active_id:
				shown = _hud_model.infos[hovered.id]
		if shown == null and _pinned_unit != -1 and _pinned_unit != active_id:
			shown = _hud_model.infos[_pinned_unit]
		pinned = shown != null and shown.unit_id == _pinned_unit
	_inspected_unit = shown.unit_id if shown != null else -1
	if shown == null:
		hud.hide_inspected()
	else:
		hud.set_inspect_side(_unit_is_right_of_center(shown.unit_id))
		hud.show_inspected(shown, pinned)


## Whether a unit is drawn in the right half of the screen, where the inspect card would
## sit on top of it: the card goes to the left edge then (and to the right otherwise).
func _unit_is_right_of_center(unit_id: int) -> bool:
	var view := units_view.find_view(unit_id)
	if view == null:
		return false
	var screen_x := camera_rig.camera.unproject_position(units_view.to_global(view.position)).x
	return screen_x > get_viewport().get_visible_rect().size.x * 0.5


## The unit shown on the active card: the acting one, or (placing) the selected hero, else the first.
func _active_card_unit_id() -> int:
	if battle.state.started:
		return _hud_model.current_id
	return _placing_hero if _placing_hero != -1 else battle.state.units[0].id


## The unit whose spells (or cards) the spell bar shows: the acting one, -1 for nobody. (A multiplayer fight shows the
## player's own; a solo one hides the bar during the enemy's turn.)
func _spells_unit_id() -> int:
	return _active_card_unit_id()


## Re-syncs the HUD from the battle state: the source of truth, after a playback (or a
## new battle, or a placement) while the events in between only updated the model.
func _refresh_hud() -> void:
	_hud_model = HudModel.from_state(battle.state, player_levels)
	_show_turn()
	var spells_unit := _hud_model.infos.get(_spells_unit_id()) as UnitInfo
	if spells_unit != null:
		if spells_unit.card_mode:
			hud.show_cards(spells_unit)
		else:
			hud.show_spells(spells_unit.spells, spells_unit.ap, spells_unit.cooldowns)
	else:
		hud.show_spells([] as Array[SpellData], 0)  # Nobody's spells to show: an empty bar.


## Shows the model's turn in the HUD: order, active card, AP for the spell bar, inspect
## card. The HUD gets plain UnitInfo values, never state.
func _show_turn() -> void:
	hud.show_turn_order(_hud_model.upcoming(), _hud_model.round_number, battle_title)
	var active := _hud_model.infos.get(_active_card_unit_id()) as UnitInfo
	if active != null:
		hud.show_unit(active)
	var spells_unit := _hud_model.infos.get(_spells_unit_id()) as UnitInfo
	if spells_unit != null:
		hud.set_spell_ap(spells_unit.ap)
		hud.set_spell_cooldowns(spells_unit.cooldowns)
	_update_inspected()


func _spawn_center(spawns: Array[Vector2i]) -> Vector3:
	var sum := Vector3.ZERO
	for cell in spawns:
		sum += board_view.cell_to_world(cell)
	return sum / maxi(spawns.size(), 1)

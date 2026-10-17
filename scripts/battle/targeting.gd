@tool
class_name Targeting
extends RefCounted
## Spell geometry: range, line of sight and area. Pure rules on a BattleState;
## AP and turn checks belong to actions.

## High ground: +1 max range per level the caster stands above the target, capped.
const RANGE_BONUS_PER_LEVEL := 1
const MAX_RANGE_BONUS := 2
## Line of sight runs from the caster's eyes to the target's body, above their cells,
## in terrain levels. Units are drawn almost 2 levels tall, so a one-level bump doesn't
## hide units standing on the same level from each other; a two-level wall does.
const EYE_HEIGHT := 1.5
const TARGET_HEIGHT := 1.0
const EPSILON := 1e-6


static func distance(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)


## Extra max range from high ground, for spells that allow it.
static func range_bonus(state: BattleState, spell: SpellData, from: Vector2i, to: Vector2i) -> int:
	if not spell.height_extends_range:
		return 0
	var levels_above := state.grid.height_at(from) - state.grid.height_at(to)
	return clampi(levels_above * RANGE_BONUS_PER_LEVEL, 0, MAX_RANGE_BONUS)


## Whether the caster could cast `spell` on `cell` from where it stands (geometry only).
static func can_target(state: BattleState, caster_id: int, spell: SpellData, cell: Vector2i) -> bool:
	var from := state.units[caster_id].cell
	if not _in_range(state, from, spell, cell):
		return false
	if spell.needs_line_of_sight and not has_line_of_sight(state, from, cell):
		return false
	if spell.target_unit != SpellData.TargetUnit.ANY:
		var unit := state.unit_at(cell)
		var caster := state.units[caster_id]
		if unit == null or unit.id == caster_id:
			return false
		if (unit.team == caster.team) != (spell.target_unit == SpellData.TargetUnit.ALLY):
			return false
		if state.is_hidden_from(unit, caster.team):
			return false  # Can't pick what it can't see.
	for effect in spell.effects:
		if effect != null and not effect.allows_target(state, caster_id, cell):
			return false
	return true


## Cells in the spell's range that it can't be aimed at: out of line of sight, or refused by
## one of its effects (a charge with no unit in a clear straight line, a teleport onto a unit).
## Shown faded, so players see the spell's reach and why they can't aim there.
static func blocked_cells(state: BattleState, caster_id: int, spell: SpellData) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var from := state.units[caster_id].cell
	for cell in _cells_in_reach(state, caster_id, spell):
		if _in_range(state, from, spell, cell) and not can_target(state, caster_id, spell, cell):
			result.append(cell)
	return result


## The spell's range from where the caster stands, geometry only (what a cell's unit is doesn't count, nor the
## effects' own conditions): cell → whether the caster sees it (always true when the spell doesn't need line of
## sight). Shown while a spell is hovered, before it is aimed.
static func range_preview(state: BattleState, caster_id: int, spell: SpellData) -> Dictionary[Vector2i, bool]:
	var result: Dictionary[Vector2i, bool] = {}
	var from := state.units[caster_id].cell
	for cell in _cells_in_reach(state, caster_id, spell):
		if _in_range(state, from, spell, cell):
			result[cell] = not spell.needs_line_of_sight or has_line_of_sight(state, from, cell)
	return result


static func targetable_cells(state: BattleState, caster_id: int, spell: SpellData) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for cell in _cells_in_reach(state, caster_id, spell):
		if can_target(state, caster_id, spell, cell):
			result.append(cell)
	return result


## The board cells within the spell's longest possible range of the caster (high ground
## included), row by row: only these can be in range, so big boards stay cheap to scan.
static func _cells_in_reach(state: BattleState, caster_id: int, spell: SpellData) -> Array[Vector2i]:
	var from := state.units[caster_id].cell
	var reach := spell.max_range + (MAX_RANGE_BONUS if spell.height_extends_range else 0)
	var cells: Array[Vector2i] = []
	for y in range(maxi(0, from.y - reach), mini(state.grid.size.y, from.y + reach + 1)):
		var span := reach - absi(y - from.y)
		for x in range(maxi(0, from.x - span), mini(state.grid.size.x, from.x + span + 1)):
			cells.append(Vector2i(x, y))
	return cells


## Traces the sight line cell by cell (Amanatides–Woo grid traversal) and checks each
## cell strictly between the two ends against the line's height where it crosses.
## Through an exact corner, sight is blocked only if both corner cells block.
static func has_line_of_sight(state: BattleState, from: Vector2i, to: Vector2i) -> bool:
	if from == to:
		return true
	var eye := state.grid.height_at(from) + EYE_HEIGHT
	var target := state.grid.height_at(to) + TARGET_HEIGHT
	var delta := Vector2(to - from)
	var step := Vector2i(signi(to.x - from.x), signi(to.y - from.y))
	# Line parameter t in [0, 1]; cells are 1 unit wide and the line joins cell centers,
	# so the first boundary on each axis is half a cell away.
	var t_delta := Vector2(_inverse(delta.x), _inverse(delta.y))
	var t_max := t_delta * 0.5
	var cell := from

	while true:
		var t_enter: float
		if absf(t_max.x - t_max.y) < EPSILON:
			t_enter = t_max.x
			var sight := lerpf(eye, target, t_enter)
			if _blocks(state, Vector2i(cell.x + step.x, cell.y), sight) \
					and _blocks(state, Vector2i(cell.x, cell.y + step.y), sight):
				return false
			cell += step
			t_max += t_delta
		elif t_max.x < t_max.y:
			t_enter = t_max.x
			cell.x += step.x
			t_max.x += t_delta.x
		else:
			t_enter = t_max.y
			cell.y += step.y
			t_max.y += t_delta.y

		if cell == to:
			return true
		var t_exit := minf(minf(t_max.x, t_max.y), 1.0)
		if _blocks(state, cell, lerpf(eye, target, (t_enter + t_exit) * 0.5)):
			return false
	return true  # Unreachable; keeps the parser happy.


## Cells affected by a spell aimed at `target` from `caster_cell`, clipped to the grid.
static func area_cells(grid: Grid, area: AreaShape, caster_cell: Vector2i, target: Vector2i) -> Array[Vector2i]:
	var cells: Array[Vector2i] = [target]
	match area.kind:
		AreaShape.Kind.CROSS:
			for direction in Grid.DIRECTIONS:
				for i in range(1, area.size + 1):
					cells.append(target + direction * i)
		AreaShape.Kind.CIRCLE:
			for dy in range(-area.size, area.size + 1):
				for dx in range(-area.size, area.size + 1):
					var offset := Vector2i(dx, dy)
					if offset != Vector2i.ZERO and absi(dx) + absi(dy) <= area.size:
						cells.append(target + offset)
		AreaShape.Kind.LINE:
			# Extends away from the caster along the dominant axis; `size` cells in total.
			var direction := dominant_direction(target - caster_cell)
			if direction != Vector2i.ZERO:
				for i in range(1, area.size):
					cells.append(target + direction * i)
	return cells.filter(func(cell: Vector2i) -> bool: return grid.in_bounds(cell))


## Range and target-cell checks, without line of sight.
static func _in_range(state: BattleState, from: Vector2i, spell: SpellData, cell: Vector2i) -> bool:
	if not state.grid.is_walkable(cell):
		return false  # Obstacles and holes can't be targeted; areas may still cover them.
	var d := distance(from, cell)
	return d >= spell.min_range and d <= spell.max_range + range_bonus(state, spell, from, cell)


static func _blocks(state: BattleState, cell: Vector2i, sight_height: float) -> bool:
	if not state.grid.in_bounds(cell):
		return true  # The edge of the world is opaque, whatever a block's height.
	match state.grid.type_at(cell):
		Grid.CellType.OBSTACLE:
			# Like terrain rising to the block's top: high ground sees over low blocks.
			return state.grid.height_at(cell) + state.grid.obstacle_levels(cell) > sight_height
		Grid.CellType.HOLE:
			return false
	var unit := state.unit_at(cell)
	# A hidden unit blocks nobody's sight: its shadow would give away where it stands.
	return (unit != null and not unit.is_stealthed()) or state.grid.height_at(cell) > sight_height


## The axis direction closest to `offset` (x wins a tie); zero for a zero offset.
static func dominant_direction(offset: Vector2i) -> Vector2i:
	if offset == Vector2i.ZERO:
		return Vector2i.ZERO
	if absi(offset.x) >= absi(offset.y):
		return Vector2i(signi(offset.x), 0)
	return Vector2i(0, signi(offset.y))


static func _inverse(value: float) -> float:
	return INF if is_zero_approx(value) else 1.0 / absf(value)

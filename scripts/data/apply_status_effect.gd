@tool
class_name ApplyStatusEffect
extends EffectData
## Puts a status on the target, or refreshes it (the new one replaces the old). Two
## statuses are "the same" when they are the same StatusData resource.

@export var status: StatusData
## Can't be aimed at a unit that already carries the status (a spirit's curse: one at a time on a target).
@export var exclusive := false


func is_harmful() -> bool:
	return status != null and not status.is_positive


func allows_target(state: BattleState, _caster_id: int, cell: Vector2i) -> bool:
	if not exclusive:
		return true
	var unit := state.unit_at(cell)
	return unit == null or unit.find_status(status) == null


func apply(state: BattleState, caster_id: int, target_id: int) -> Array[BattleEvents.Event]:
	var instance := state.units[target_id].add_status(status, caster_id)
	return [BattleEvents.StatusApplied.new(target_id, status, instance.turns_left)]


## e.g. "Poison for 3 turns (3-4 damage per turn)"; a status put on the caster counts the
## caster's own turns: "Guard for your next 2 turns (...)" (a self-buff doesn't count the turn it is cast in).
func describe() -> String:
	if status == null:
		return tr("no status")
	var turns := tr_n("%d turn", "%d turns", status.duration) % status.duration
	if target_filter == TargetFilter.CASTER:
		turns = tr("your next turn") if status.duration == 1 else tr("your next %d turns") % status.duration
	return tr("%s for %s (%s)") % [tr(status.display_name), turns, status.describe()]


func get_validation_errors() -> PackedStringArray:
	if status == null:
		return PackedStringArray(["apply status effect has no status"])
	return status.get_validation_errors()

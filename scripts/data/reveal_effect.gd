@tool
class_name RevealEffect
extends EffectData
## Ends the stealth of each unit it lands on, as if it had been found (a spirit's Reveal, over an area).


func apply(state: BattleState, _caster_id: int, target_id: int) -> Array[BattleEvents.Event]:
	var events: Array[BattleEvents.Event] = []
	for ended in state.units[target_id].break_stealth():
		events.append(BattleEvents.StatusExpired.new(target_id, ended))
	return events


func describe() -> String:
	return tr("reveals hidden units")

@tool
class_name CardRules
extends RefCounted
## The card combat mode: a unit's spells become a deck. It holds HAND_SIZE cards (drawn back up to that at the end of each
## of its turns, so the next hand can be read while the others play) and may play at most
## PLAYS_PER_TURN of them (a play is an action point: statuses that give or steal AP give or steal plays); the cards it
## does not play stay in its hand, or are thrown away. A card is one cast of one spell, so a played or thrown card goes
## to the discard pile, and the draw pile is the discard pile shuffled once it runs out.
## Every spell is in the deck twice (every spell costs the same: one action), so the hand's chance is the only
## difference with classic combat.

const HAND_SIZE := 4
const PLAYS_PER_TURN := 2
## Copies of each spell in a deck.
const COPIES_PER_SPELL := 2


static func copies(_spell: SpellData) -> int:
	return COPIES_PER_SPELL


## The unit's whole deck: each spell's slot number, once per copy, in slot order (the shuffle is the unit's).
static func deck_for(data: UnitData) -> Array[int]:
	var deck: Array[int] = []
	for slot in data.spells.size():
		for copy in copies(data.spells[slot]):
			deck.append(slot)
	return deck

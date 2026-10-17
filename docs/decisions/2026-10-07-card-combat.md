# Card combat (PvP)

Date: 2026-10-07. Status: first version, PvP only.

## What

An optional rule set for a PvP match, switched in the lobby by the host (`cfg cards`). Each hero's spells become a deck:

- a **card** is one cast of a spell; the deck holds 1 to 3 copies of each spell by **rarity** (`CardRules`): the weight of a spell is its AP cost plus 2 for a cooldown of 2 or more (1 for "once per turn"); weight up to 2 is common (3 copies), up to 4 uncommon (2), more rare (1). decks hold 8 to 11 cards (the Knight's: Guard x3, Slash, Shield Bash and Whirlwind x2, Charge x1), so a rare spell comes up about a third as often as a common one;
- each turn the hero **draws up to four cards** (since 2026-10-16 at the end of its turn, not the start: players asked to read their next hand while the others play) and may **play two**: a play is an action point (`max_ap()` is 2 plus the AP modifiers), so Blessing (+1 AP) is a third play and Pickpocket / Drain Will steal one;
- cards not played **stay** in the hand; any card can be **thrown away** for free, at any time in the turn (the X on the card or a right click); played and thrown cards go to the discard pile, which is shuffled back when the draw pile is empty;
- AP costs and cooldowns are not used any more; movement (MP) is unchanged;
- the hand is shown at the bottom of the screen in place of the spell bar, with the draw and discard pile sizes; hovering a card shows what the spell does, its rarity and how many of the deck's cards it is.

## Why this way

- **Replication**: the deck, piles and dice are part of the battle state, so the existing deterministic log needs no new data: a cast still names a spell slot, and one new action (`discard`) was added. The hand is hashed, so a drift shows up in the fingerprint.
- **Plays as AP** reuses every status that touches AP and the HUD's AP display ("Actions 2 / 2"), and the AI, which asks `UnitState.can_cast()`, plays only cards it holds.
- **Own dice per unit** keeps hands independent of the damage rolls: a hand does not change because an earlier hit rolled differently.

## Not done (ideas)

- Single-player (campaign, tower) in card mode: enemies would need decks and the heroes' progression would have to say what a card is.
- Deck-building from a shared pool, cards that are not spells (a movement card, a one-use buff), drawing extra cards as an effect, a limit on throws.
- The AI never throws cards away on purpose (it plays what it has).
- A card animation (the card flying from the hand when played) and a hand fan: the cards are plain buttons for now.
- Balance: one AI-vs-AI pass (60 games, 2v2) gave win rates from 28 % to 74 % between classes (noise is about 9 points at this size); the Sorceress did best and the Rogue worst. Read it as a lower bound, as for the classic mode; `pvp_balance.gd ... cards=1` reruns it.

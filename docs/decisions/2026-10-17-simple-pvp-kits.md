# Simpler PvP kits — decisions

Date: 2026-10-17. Status: decided, kits proposed (numbers to check with `tools/pvp_balance.gd`). Goal: fewer spells and far
fewer kinds of effect, so a player reads a fight at a glance and matches go faster. Multiplayer only; solo keeps its own
heroes (see `2026-10-10-shared-core.md`).

| Decision | Choice | Why | Revisit when |
|---|---|---|---|
| Classes | The **9 classes stay** (names, models, lobby), their kits are redone | The variety is in the classes, not in the number of effects | — |
| Spells per class | **4** | Readable; fits the bar and card combat | — |
| Action points | **Every spell costs 1 AP, every class has 2 AP**: two spells a turn, whatever the class | Close to card combat, without its chance | — |
| The same spell twice | **Allowed** | Simple; the strong ones have a limit (below) | a spell is spammed |
| Limits | A **cooldown only on the really big spells, 2 turns at most** (a hero lives 3 to 4 turns: a longer one is cast once a fight); movement spells and the one heal are **once per turn** (cooldown 1) | Two teleports or two heals a turn would break the map and the fights | — |
| Kinds of effect | **Damage** (one target or an area), **movement** (teleport, charge, leap back, jump, push, pull), **one heal** (the Priestess's), and **two statuses**: **Rooted** and **Hidden** (the Rogue's stealth, with its ambush bonus). Gone: AP theft and gifts, shields and defense, slows, marks, damage over time, lifesteal, cleanses | Each effect is one more thing to read in every fight | a class has nothing left to do |
| "+damage taken" | **Only the spirits** (their Curse) | It belongs to the fallen players | — |
| Damage types | **No resistances in multiplayer**; the type is only a look (color, sound, impact) | The Wraith was untouchable for four physical classes; one thing less to read | — |
| Movement points | **Per class**, as before, but the **Knight gets more** (5) and a Charge usable every turn | The tank must reach the melee on big maps, or it isn't one | — |
| Damage level | Built around the faster pace measured (damage ×1.3 gave matches about 20 % shorter) | Shorter matches | balance runs |
| Card combat | **2 copies of each spell** (a deck of 8), a hand of 4, 2 plays, no cooldowns (as before) | The only difference left with classic combat is the hand's chance | — |

## Open / deferred

- The numbers of each spell: a first set in `pvp_class_specs.gd`, then `pvp_balance.gd` against the current classes
  (`out=` / `compare=`).
- The Wraith's role is labelled "Spirit" in the lobby: renamed, so it isn't mistaken for the fallen players' spirits.
- The AI's positioning presets stay; check that it uses pushes and pulls sensibly.

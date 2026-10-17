class_name PvpClassSpecs
extends RefCounted
## The PvP classes, their spells and statuses, as plain data: the numbers live here, in one place, so balancing
## is "edit a number, rebuild" (`godot --headless --script res://tools/build_pvp_classes.gd`, then
## `tools/fill_uid_refs.gd`). The build writes data/pvp/**.tres; after that the .tres files are ordinary
## resources you can also tweak in the Inspector (a rebuild overwrites them).
##
## A damage or heal is [kind, min, max, ...]. Spell effects:
##   ["dmg", min, max, type, filter, {lifesteal, ambush}]   ["heal", min, max, filter]
##   ["status", id, filter, {exclusive}]   ["move", kind, distance, filter]   ["cleanse", "harmful"|"helpful", filter]
##   ["reveal", filter]
## filter: "all", "allies", "enemies" or "caster". Areas: "single", ["circle", n], ["cross", n], ["line", n].
## `from` borrows an existing spell's look and sound (icon, projectile, impact, animation); `icon` overrides the icon
## (ui/icons/<icon>.svg): the spells of one class must all have different icons (a test checks it).

## Class order is the lobby's order.
const ORDER: Array[String] = ["knight", "ranger", "sorceress", "necromancer", "rogue", "priestess", "goblin", "wraith", "monk"]


static func statuses() -> Dictionary:
	return {
		"stealth": {"name": "Hidden", "label": "H", "dur": 6, "positive": true, "color": [0.7, 0.7, 0.9], "stealth": true},
		"rooted": {"name": "Rooted", "label": "Ro", "dur": 1, "color": [0.6, 0.45, 0.25], "mods": [["mp", -9]], "aura": "crippled"},
		# The spirits' own: the only "+damage taken" of the game.
		"cursed": {"name": "Cursed", "label": "Cu", "dur": 1, "color": [0.75, 0.35, 0.9], "mods": [["dmg", 20]], "aura": "marked"},
	}


## A fallen hero's spirit (docs/decisions/2026-10-17-spirits.md): one of these a turn, anywhere on the board. A
## status lasts until the end of its target's next turn; Curse and Root can't be put on a target that already has it.
## No heal: it made matches longer (docs/decisions/2026-10-17-spirits.md).
const SPIRIT_SPELLS: Array[String] = ["spirit_curse", "spirit_root", "spirit_reveal"]


static func spirit_spells() -> Dictionary:
	return {
		"spirit_curse": {"name": "Curse", "from": "wail", "icon": "skull", "ap": 1, "range": [0, 99], "los": false, "target": "enemy",
				"fx": [["status", "cursed", "enemies", {"exclusive": true}]]},
		"spirit_root": {"name": "Root", "from": "chill_touch", "icon": "crippling_blow", "ap": 1, "range": [0, 99], "los": false, "target": "enemy",
				"fx": [["status", "rooted", "enemies", {"exclusive": true}]]},
		"spirit_reveal": {"name": "Reveal", "from": "wail", "icon": "hunters_mark", "ap": 1, "range": [0, 99], "los": false, "area": ["cross", 3],
				"fx": [["reveal", "enemies"]]},
	}


## Every spell costs 1 AP and every class has 2 (two casts a turn, the same spell twice if wanted); a cooldown only on
## the really big ones, 2 turns at most. Areas thrown at a cell hit everyone in them ("all": the lobby's friendly fire
## rule decides for allies); sweeps around the caster hit enemies only (or the caster would hit itself).
static func spells() -> Dictionary:
	return {
		# --- Knight: reaches the melee and holds it ---
		"knight_slash": {"name": "Slash", "from": "slash", "ap": 1, "range": [1, 1], "fx": [["dmg", 17, 21, "physical"]]},
		"knight_whirlwind": {"name": "Whirlwind", "from": "whirlwind", "ap": 1, "range": [0, 0], "los": false, "area": ["circle", 1],
				"fx": [["dmg", 14, 18, "physical", "enemies"]]},
		"knight_charge": {"name": "Charge", "from": "charge", "ap": 1, "range": [2, 5], "los": false, "target": "any",
				"fx": [["move", "charge", 1, "caster"], ["dmg", 12, 15, "physical", "enemies"]]},
		"knight_bash": {"name": "Shield Bash", "from": "shield_bash", "ap": 1, "range": [1, 1],
				"fx": [["dmg", 11, 14, "physical"], ["move", "push", 2, "enemies"]]},
		# --- Ranger: shoots from afar, leaps away ---
		"ranger_arrow": {"name": "Arrow", "from": "arrow", "ap": 1, "range": [2, 7], "height": true, "fx": [["dmg", 16, 20, "physical"]]},
		"ranger_volley": {"name": "Volley", "from": "volley", "ap": 1, "range": [3, 6], "area": ["circle", 1],
				"fx": [["dmg", 10, 13, "physical"]]},
		"ranger_backslash": {"name": "Backslash", "from": "backslash", "ap": 1, "range": [1, 1], "los": false,
				"fx": [["dmg", 9, 11, "physical", "enemies"], ["move", "retreat", 4, "caster"]]},
		"ranger_pin": {"name": "Pinning Shot", "from": "pinning_shot", "ap": 1, "range": [2, 6], "cd": 2,
				"fx": [["dmg", 9, 11, "physical"], ["status", "rooted", "enemies"]]},
		# --- Sorceress: the biggest damage, nothing else ---
		"sorc_firebolt": {"name": "Firebolt", "from": "firebolt", "ap": 1, "range": [2, 6], "height": true, "fx": [["dmg", 18, 22, "fire"]]},
		"sorc_fireball": {"name": "Fireball", "from": "fireball", "ap": 1, "range": [3, 6], "area": ["circle", 1],
				"fx": [["dmg", 13, 16, "fire"]]},
		"sorc_blink": {"name": "Blink", "from": "blink", "ap": 1, "range": [1, 4], "los": false, "fx": [["move", "teleport", 1, "caster"]]},
		"sorc_meteor": {"name": "Meteor", "from": "fireball", "icon": "meteor", "ap": 1, "range": [4, 7], "cd": 2, "area": ["circle", 2],
				"fx": [["dmg", 28, 34, "fire"]]},
		# --- Necromancer: areas and control ---
		"necro_plague_bolt": {"name": "Plague Bolt", "from": "spore_bolt", "ap": 1, "range": [2, 5], "fx": [["dmg", 16, 20, "poison"]]},
		"necro_miasma": {"name": "Miasma", "from": "spore_hex", "icon": "miasma", "ap": 1, "range": [3, 6], "area": ["circle", 1],
				"fx": [["dmg", 12, 15, "poison"]]},
		"necro_soul_pull": {"name": "Soul Pull", "from": "chill_touch", "icon": "icy_grasp", "ap": 1, "range": [2, 5],
				"fx": [["dmg", 8, 10, "poison", "enemies"], ["move", "pull", 3, "enemies"]]},
		"necro_grasp": {"name": "Grasping Dead", "from": "chill_touch", "ap": 1, "range": [2, 5], "cd": 2,
				"fx": [["dmg", 8, 10, "poison"], ["status", "rooted", "enemies"]]},
		# --- Rogue: appears and vanishes ---
		"rogue_dagger": {"name": "Dagger Strike", "from": "slash", "ap": 1, "range": [1, 1], "fx": [["dmg", 13, 17, "physical"]]},
		"rogue_ambush": {"name": "Ambush", "from": "piercing_thrust", "ap": 1, "range": [1, 1],
				"fx": [["dmg", 18, 22, "physical", "enemies", {"ambush": 80}]]},
		"rogue_shadow_step": {"name": "Shadow Step", "from": "blink", "ap": 1, "range": [2, 4], "los": false, "fx": [["move", "teleport", 1, "caster"]]},
		"rogue_vanish": {"name": "Vanish", "from": "guard", "ap": 1, "range": [0, 0], "los": false, "cd": 2, "fx": [["status", "stealth", "caster"]]},
		# --- Priestess: the one heal of the game ---
		"priest_smite": {"name": "Smite", "from": "smite", "ap": 1, "range": [1, 4], "fx": [["dmg", 14, 18, "holy"]]},
		"priest_radiance": {"name": "Radiance", "from": "wail", "icon": "repulse", "ap": 1, "range": [0, 0], "los": false, "area": ["circle", 1],
				"fx": [["dmg", 11, 14, "holy", "enemies"]]},
		"priest_rescue": {"name": "Rescue", "from": "chill_touch", "icon": "grapple_shot", "ap": 1, "range": [2, 5], "target": "ally",
				"fx": [["move", "pull", 3, "allies"]]},
		"priest_heal": {"name": "Healing Touch", "from": "mend", "ap": 1, "range": [1, 4], "target": "ally", "fx": [["heal", 22, 28, "allies"]]},
		# --- Goblin: bombs and a rocket ---
		"goblin_sling": {"name": "Slingshot", "from": "arrow", "ap": 1, "range": [2, 5], "fx": [["dmg", 11, 14, "physical"]]},
		"goblin_bomb": {"name": "Bomb", "from": "fireball", "ap": 1, "range": [2, 5], "area": ["circle", 1],
				"fx": [["dmg", 12, 15, "fire"]]},
		"goblin_rocket": {"name": "Rocket Jump", "from": "blink", "icon": "pounce", "ap": 1, "range": [2, 4], "los": false,
				"fx": [["move", "jump", 1, "caster"]]},
		"goblin_dynamite": {"name": "Dynamite", "from": "fireball", "icon": "dynamite", "ap": 1, "range": [3, 6], "cd": 2, "area": ["circle", 2],
				"fx": [["dmg", 22, 27, "fire"], ["move", "push", 1, "all"]]},
		# --- Wraith: haunts, wails and drags ---
		"wraith_touch": {"name": "Spectral Touch", "from": "chill_touch", "ap": 1, "range": [1, 3], "fx": [["dmg", 17, 21, "frost"]]},
		"wraith_wail": {"name": "Wail", "from": "wail", "ap": 1, "range": [0, 0], "los": false, "area": ["circle", 2],
				"fx": [["dmg", 11, 14, "frost", "enemies"]]},
		"wraith_phase": {"name": "Phase Walk", "from": "blink", "ap": 1, "range": [1, 4], "los": false, "fx": [["move", "teleport", 1, "caster"]]},
		"wraith_grasp": {"name": "Frozen Grasp", "from": "chill_touch", "icon": "grave_chill", "ap": 1, "range": [2, 5],
				"fx": [["dmg", 9, 12, "frost", "enemies"], ["move", "pull", 2, "enemies"]]},
		# --- Monk: pushes, pulls and quick feet ---
		"monk_palm": {"name": "Palm Strike", "from": "club", "ap": 1, "range": [1, 1], "fx": [["dmg", 15, 19, "physical"]]},
		"monk_staff": {"name": "Whirling Staff", "from": "whirlwind", "ap": 1, "range": [0, 0], "los": false, "area": ["circle", 1],
				"fx": [["dmg", 11, 14, "physical", "enemies"], ["move", "push", 2, "enemies"]]},
		"monk_dash": {"name": "Flying Kick", "from": "charge", "ap": 1, "range": [2, 4], "los": false, "target": "any",
				"fx": [["move", "charge", 1, "caster"], ["dmg", 11, 14, "physical", "enemies"]]},
		"monk_hook": {"name": "Iron Grip", "from": "grapple_shot", "ap": 1, "range": [2, 5],
				"fx": [["dmg", 8, 10, "physical", "enemies"], ["move", "pull", 3, "enemies"]]},
	}


## Per class: unit stats, its spells in key order, and what the lobby shows. `look` borrows a single-player model, `model` names an own recipe in scripts/tools/modeling/recipes (and `height` is its top in meters).
static func heroes() -> Dictionary:
	return {
		"knight": {"name": "Knight", "gender": "male", "hp": 200, "ap": 2, "mp": 5, "init": 100, "look": "knight", "color": [0.25, 0.45, 0.9],
				"role": "Frontline", "desc": "Charges in every turn, bashes enemies out of position and sweeps around him. Hard to remove.",
				"spells": ["knight_slash", "knight_whirlwind", "knight_charge", "knight_bash"]},
		"ranger": {"name": "Ranger", "gender": "neutral", "hp": 130, "ap": 2, "mp": 5, "init": 108, "look": "ranger", "color": [0.3, 0.75, 0.4],
				"ai": "ranged", "role": "Mobile sharpshooter", "desc": "Shoots from far away, pins a target to the ground and leaps back out of reach. Weak when caught.",
				"spells": ["ranger_arrow", "ranger_volley", "ranger_backslash", "ranger_pin"]},
		"sorceress": {"name": "Sorceress", "gender": "female", "hp": 85, "ap": 2, "mp": 4, "init": 105, "model": "sorceress", "height": 1.6, "color": [0.85, 0.4, 0.3],
				"ai": "ranged", "role": "Glass cannon", "desc": "The biggest damage in the game and nothing else. One careless step and she is gone: keep her behind your team.",
				"spells": ["sorc_firebolt", "sorc_fireball", "sorc_blink", "sorc_meteor"]},
		"necromancer": {"name": "Necromancer", "gender": "male", "hp": 150, "ap": 2, "mp": 4, "init": 100, "model": "necromancer", "height": 1.5, "color": [0.45, 0.25, 0.55],
				"ai": "ranged", "role": "Areas and control", "desc": "Hits groups, drags enemies out of their lines and pins them in place with the dead's hands.",
				"spells": ["necro_plague_bolt", "necro_miasma", "necro_soul_pull", "necro_grasp"]},
		"rogue": {"name": "Rogue", "gender": "female", "hp": 110, "ap": 2, "mp": 6, "init": 115, "model": "rogue", "height": 1.5, "color": [0.25, 0.3, 0.35],
				"role": "Assassin", "desc": "Vanishes until her next attack, then strikes for extra damage. Enemies can't see her, even next to her, until she attacks, is hurt, or one of them walks into her (which hurts them).",
				"spells": ["rogue_dagger", "rogue_ambush", "rogue_shadow_step", "rogue_vanish"]},
		"priestess": {"name": "Priestess", "gender": "female", "hp": 150, "ap": 2, "mp": 4, "init": 100, "model": "priestess", "height": 1.55, "color": [0.95, 0.9, 0.6],
				"ai": "support", "role": "Healer", "desc": "The only healer: mends her allies and pulls them out of danger. Her holy light burns whoever comes close. She cannot heal herself.",
				"spells": ["priest_smite", "priest_radiance", "priest_rescue", "priest_heal"]},
		"goblin": {"name": "Goblin", "gender": "male", "hp": 100, "ap": 2, "mp": 6, "init": 120, "model": "goblin", "height": 1.0, "color": [0.45, 0.7, 0.25],
				"ai": "ranged", "role": "Bomb thrower", "desc": "Fast and reckless: throws bombs and dynamite, and rockets himself across the board.",
				"spells": ["goblin_sling", "goblin_bomb", "goblin_rocket", "goblin_dynamite"]},
		"wraith": {"name": "Wraith", "gender": "neutral", "hp": 130, "ap": 2, "mp": 5, "init": 112, "look": "ghost", "color": [0.55, 0.4, 0.8],
				"role": "Haunter", "desc": "Drifts through walls, drags its victims close with an icy grasp and wails at everyone around.",
				"spells": ["wraith_touch", "wraith_wail", "wraith_phase", "wraith_grasp"]},
		"monk": {"name": "Monk", "gender": "male", "hp": 150, "ap": 2, "mp": 6, "init": 108, "model": "monk", "height": 1.5, "color": [0.9, 0.55, 0.2],
				"role": "Skirmisher", "desc": "Quick on its feet: kicks in, pulls enemies close and sweeps them away.",
				"spells": ["monk_palm", "monk_staff", "monk_dash", "monk_hook"]},
	}

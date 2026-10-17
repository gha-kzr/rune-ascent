extends SceneTree
## Builds the PvP classes (data/pvp/**) from scripts/tools/pvp/pvp_class_specs.gd: statuses, spells, units, classes
## and the roster. A rebuilt file keeps its UID. Then run tools/fill_uid_refs.gd.
##   godot --headless --script res://tools/build_pvp_classes.gd

const DIR := "res://data/pvp"
const FILTERS := {"all": 0, "allies": 1, "enemies": 2, "caster": 3}
const AREAS := {"single": 0, "cross": 1, "circle": 2, "line": 3}
const MOVES := {"teleport": 0, "jump": 1, "charge": 2, "push": 3, "pull": 4, "retreat": 5}
const TARGETS := {"any": 0, "enemy": 1, "ally": 2}
const GENDERS := {"neutral": 0, "female": 1, "male": 2}
const STATS := {"ap": 0, "mp": 1, "dmg": 2, "power": 3, "max_hp": 5, "init": 6}


func _init() -> void:
	var status_files := {}
	for id: String in PvpClassSpecs.statuses():
		status_files[id] = _build_status(id, PvpClassSpecs.statuses()[id])
	var spell_files := {}
	for id: String in PvpClassSpecs.spells():
		spell_files[id] = _build_spell(id, PvpClassSpecs.spells()[id], status_files)
	var roster := PvpRoster.new()
	for id: String in PvpClassSpecs.SPIRIT_SPELLS:
		roster.spirit_spells.append(_build_spell(id, PvpClassSpecs.spirit_spells()[id], status_files))
	var heroes := PvpClassSpecs.heroes()
	for id in PvpClassSpecs.ORDER:
		roster.heroes.append(_build_hero(id, heroes[id], spell_files))
	_save(roster, "%s/roster.tres" % DIR)
	print("Built %d statuses, %d spells, %d classes, %d spirit spells." % [status_files.size(), spell_files.size(), roster.heroes.size(),
			roster.spirit_spells.size()])
	var errors := roster.get_validation_errors()
	for error in errors:
		print("  problem: ", error)
	quit(1 if not errors.is_empty() else 0)


func _save(resource: Resource, path: String) -> Resource:
	var uid := ResourceLoader.get_resource_uid(path) if ResourceLoader.exists(path) else ResourceUID.INVALID_ID
	if uid == ResourceUID.INVALID_ID:
		uid = ResourceUID.create_id()
	resource.resource_path = ""
	var error := ResourceSaver.save(resource, path)
	if error != OK:
		push_error("can't save %s: %s" % [path, error_string(error)])
		return resource
	ResourceSaver.set_uid(path, uid)
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)


func _modifier(entry: Array) -> StatModifier:
	var modifier := StatModifier.new()
	modifier.stat = STATS[entry[0]]
	modifier.amount = int(entry[1])
	return modifier


func _build_status(id: String, spec: Dictionary) -> StatusData:
	var status := StatusData.new()
	status.display_name = spec["name"]
	status.short_label = spec["label"]
	status.duration = int(spec["dur"])
	status.is_positive = spec.get("positive", false)
	status.stealth = spec.get("stealth", false)
	var rgb: Array = spec["color"]
	status.color = Color(rgb[0], rgb[1], rgb[2])
	for entry: Array in spec.get("mods", []):
		status.modifiers.append(_modifier(entry))
	for entry: Array in spec.get("ticks", []):
		status.tick_effects.append(_effect(entry, {}))
	if spec.has("aura"):
		var aura := load("res://data/statuses/%s.tres" % spec["aura"]) as StatusData
		if aura != null:
			status.aura_effect = aura.aura_effect
			status.icon = aura.icon
	return _save(status, "%s/statuses/%s.tres" % [DIR, id]) as StatusData


func _effect(entry: Array, statuses: Dictionary) -> EffectData:
	match entry[0]:
		"dmg":
			var damage := DamageEffect.new()
			damage.min_amount = int(entry[1])
			damage.max_amount = int(entry[2])
			damage.damage_type = load("res://data/damage_types/%s.tres" % entry[3]) as DamageType
			damage.target_filter = FILTERS[entry[4] if entry.size() > 4 else "all"]
			var extras: Dictionary = entry[5] if entry.size() > 5 else {}
			damage.lifesteal_percent = int(extras.get("lifesteal", 0))
			damage.ambush_bonus_percent = int(extras.get("ambush", 0))
			return damage
		"heal":
			var heal := HealEffect.new()
			heal.min_amount = int(entry[1])
			heal.max_amount = int(entry[2])
			heal.target_filter = FILTERS[entry[3] if entry.size() > 3 else "all"]
			return heal
		"status":
			var apply := ApplyStatusEffect.new()
			apply.status = statuses[entry[1]]
			apply.target_filter = FILTERS[entry[2] if entry.size() > 2 else "all"]
			var options: Dictionary = entry[3] if entry.size() > 3 else {}
			apply.exclusive = options.get("exclusive", false)
			return apply
		"reveal":
			var reveal := RevealEffect.new()
			reveal.target_filter = FILTERS[entry[1] if entry.size() > 1 else "enemies"]
			return reveal
		"move":
			var move := MoveEffect.new()
			move.kind = MOVES[entry[1]]
			move.distance = int(entry[2])
			move.target_filter = FILTERS[entry[3] if entry.size() > 3 else "all"]
			return move
		"cleanse":
			var cleanse := CleanseEffect.new()
			cleanse.remove = CleanseEffect.Remove.HARMFUL if entry[1] == "harmful" else CleanseEffect.Remove.HELPFUL
			cleanse.target_filter = FILTERS[entry[2] if entry.size() > 2 else "all"]
			return cleanse
	push_error("unknown effect %s" % entry[0])
	return null


func _build_spell(id: String, spec: Dictionary, statuses: Dictionary) -> SpellData:
	var source := load("res://data/spells/%s.tres" % spec["from"]) as SpellData
	var spell := source.duplicate() as SpellData if source != null else SpellData.new()
	spell.display_name = spec["name"]
	if spec.has("icon"):  # Its own icon, when the borrowed one is already used by another spell of the class.
		spell.icon = load("res://ui/icons/%s.svg" % spec["icon"]) as Texture2D
	spell.ap_cost = int(spec["ap"])
	spell.cooldown = int(spec.get("cd", 0))
	spell.min_range = int(spec["range"][0])
	spell.max_range = int(spec["range"][1])
	spell.needs_line_of_sight = spec.get("los", true)
	spell.height_extends_range = spec.get("height", false)
	spell.target_unit = TARGETS[spec.get("target", "any")]
	var area := AreaShape.new()
	var area_spec: Variant = spec.get("area", "single")
	if area_spec is Array:
		area.kind = AREAS[area_spec[0]]
		area.size = int(area_spec[1])
	else:
		area.kind = AREAS[area_spec]
	spell.area = area
	spell.effects.clear()
	for entry: Array in spec["fx"]:
		spell.effects.append(_effect(entry, statuses))
	return _save(spell, "%s/spells/%s.tres" % [DIR, id]) as SpellData


func _build_hero(id: String, spec: Dictionary, spells: Dictionary) -> PvpHero:
	var unit := UnitData.new()
	unit.display_name = spec["name"]
	unit.max_hp = int(spec["hp"])
	unit.ap = int(spec["ap"])
	unit.mp = int(spec["mp"])
	unit.initiative = int(spec["init"])
	for spell_id: String in spec["spells"]:
		unit.spells.append(spells[spell_id])
	for entry: Array in spec.get("resist", []):
		var modifier := StatModifier.new()
		modifier.stat = StatModifier.Stat.RESISTANCE_PERCENT
		modifier.amount = int(entry[1])
		modifier.damage_type = load("res://data/damage_types/%s.tres" % entry[0]) as DamageType
		unit.innate_modifiers.append(modifier)
	var rgb: Array = spec["color"]
	unit.color = Color(rgb[0], rgb[1], rgb[2])
	unit.model_height = spec.get("height", 1.5)
	if spec.has("model"):
		unit.model_scene = load("res://assets/models/%s.tscn" % spec["model"]) as PackedScene
	elif spec.has("look"):
		var model := load("res://data/units/%s.tres" % spec["look"]) as UnitData
		unit.model_scene = model.model_scene
		unit.model_scale = model.model_scale
		unit.model_height = model.model_height
		unit.held_item = model.held_item
		unit.held_item_replaces = model.held_item_replaces
		unit.held_item_bone = model.held_item_bone
		unit.held_item_scale = model.held_item_scale
		unit.held_item_rotation = model.held_item_rotation
		unit.held_item_offset = model.held_item_offset
	var saved_unit := _save(unit, "%s/units/%s.tres" % [DIR, id]) as UnitData
	var hero := PvpHero.new()
	hero.unit = saved_unit
	hero.role_label = spec["role"]
	hero.description = spec["desc"]
	hero.gender = GENDERS[spec["gender"]]
	if spec.has("ai"):
		hero.ai_positioning = load("res://data/ai/positioning_%s.tres" % spec["ai"]) as Positioning
	return _save(hero, "%s/heroes/%s.tres" % [DIR, id]) as PvpHero

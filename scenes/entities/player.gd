extends Node
## Joueur — étape D.3.3 : récolte avec XP (A.2), pose de blocs avec fantôme
## de prévisualisation (4.1), inventaire (A.4.2), progression par l'usage
## (A.1). La récolte avance PAR TICKS (E.1) — jamais dans _process ; la visée
## et le fantôme sont purement visuels (frame).
## Provisoire : stats C.1 à la base 5 et kit d'outils de test — remplacés par
## la création de personnage (6.3/C.1/C.3) quand elle arrivera.

## Portée d'interaction en blocs (provisoire — la portée par Perception
## viendra avec les stats complètes, C.1).
const REACH := 5.0
## Kit de départ : outils FAIBLES (pin + cuivre, qualité 0.7 « Pauvre ») —
## dureté de base 14.4 × 0.7 → récolte jusqu'à dureté ~20 (A.2 : seuil ×0.5) :
## terre, sable, bois, grès, calcaire, pierre, ardoise passent ; granit,
## basalte et au-delà REBONDISSENT — le verrou de progression 3.2 est actif
## dès le spawn. Remplacé par le kit de classe C.3 à la création de personnage.
const STARTER_KIT := ["pioche", "hache", "pelle"]
const STARTER_MATERIALS := {"bois": "pin", "minerai": "cuivre"}
const STARTER_QUALITY := 0.7

## Module de démonstration (étape D.3.6) : 3 modules assemblés, touches J/K/L
## (les touches 1-9 pilotent déjà la hotbar). Coût en mana par A.6.
const MODULE_LOADOUT := ["trait_de_mana", "soin_mineur", "frappe_lourde"]
const MODULE_KEYS := [KEY_J, KEY_K, KEY_L]
## C.1 : 6 stats, base 5.
var stats := {"force": 5, "dexterite": 5, "endurance": 5, "volonte": 5, "perception": 5, "charisme": 5}
var skills: PlayerSkills
var inventory: Inventory
## Santé — formule validée par l'auteur (2026-07-20), par analogie avec le
## mana (A.5, Endurance ~ Volonté) : santé_max = 20 + Endurance * 8.
var health_max: float
var health: float
## Faim (2026-07-26) : décroît lentement avec le temps. Effets (dégâts de
## famine, nourriture) à câbler avec la boucle de survie — pour l'instant
## indicateur seulement.
var hunger_max := 100.0
var hunger := 100.0
const HUNGER_DECAY_PER_TICK := 0.003   # ~100 → 0 en ~1,4 jour in-game (24000 ticks/jour).
var mana: ManaPool
## Monnaie unique (or, 7.1) — aucun concept de portefeuille PNJ/taxes/
## entretien (A.8.1) n'est implémenté, seul le joueur en a un pour l'instant.
var gold: int = 0
var selected_slot := 0
## Banque de hotbar active (0-8, molette+Shift ou Shift+1-9) — 9 banques de
## 9 emplacements, fenêtres consécutives sur la liste stable outils+matériaux.
var active_hotbar := 0
const HOTBAR_COUNT := 9
const HOTBAR_SLOTS := 9
## Résolution de grille active (4.1) : 32 = bloc plein, 16/8/4 = sous-blocs.
var active_res := 32
const RES_SEQUENCE: Array[int] = [32, 16, 8, 4]
## Verrouillage des entrées pendant les benchs (mesures non contaminées).
var input_locked := false

var _camera: FlyCamera
var _ghost: MeshInstance3D
var _ghost_ok: StandardMaterial3D
var _ghost_bad: StandardMaterial3D
## Surbrillance du bloc en cours de récolte (s'assombrit avec la progression).
var _mining_overlay: MeshInstance3D
var _mining_overlay_mat: StandardMaterial3D

# État de récolte (piloté par ticks).
var _mining := false
var _target_valid := false
var _target := Vector3i.ZERO
var _target_normal := Vector3i.ZERO
var _hit_point := Vector3.ZERO
var _progress := 0.0
var _required := 0.0
var _bouncing := false
var _last_carve_region := Vector3i(-1, -1, -1)

# État de combat (E.3, piloté par ticks).
var _attack_cooldown_ticks := 0
var _module_cooldown_ticks := 0
var _target_creature: Node = null


## Race/classe choisies (6.1) — posées par apply_character, sauvegardées.
var race_id := ""
var class_id := ""


func _ready() -> void:
	# Setup des nœuds/systèmes uniquement. La CONFIGURATION du personnage
	# (stats, compétences, kit) vient de apply_character, appelée par
	# main._start_world APRÈS le choix de la création de personnage (6.3) —
	# ou du kit par défaut en mode direct (bench/probe/test).
	skills = PlayerSkills.new()
	skills.owner_entity = self
	inventory = Inventory.new()
	_recompute_derived()
	_camera = get_node("../FlyCamera") as FlyCamera
	TickManager.tick.connect(_on_tick)
	_build_ghost.call_deferred()


## Recalcule santé/mana depuis les stats + compétences courantes (A.5/A.5.1).
func _recompute_derived() -> void:
	health_max = 20.0 + int(stats["endurance"]) * 8.0
	health = health_max
	mana = ManaPool.new(int(stats["volonte"]), skills.level("meditation"))


## Kit de départ FAIBLE historique (pin+cuivre 0.7) — utilisé par le mode
## direct (benchs/sondes/tests) qui n'ont pas de création de personnage.
func apply_default_character() -> void:
	for tool_id in STARTER_KIT:
		inventory.add_object(ItemFactory.craft(tool_id, STARTER_MATERIALS, STARTER_QUALITY))
	inventory.add_object(ItemFactory.craft("epee", {"bois": "pin", "minerai": "cuivre"}, STARTER_QUALITY))
	inventory.add_material("etal_de_vente", 1)
	_recompute_derived()


## Applique une création de personnage (6.1/C.1-C.3) : stats réparties + bonus
## de race/classe, compétences de départ, kit, or, potentiels de base.
## `config` = { "race", "class", "stats": {6 stats réparties} }.
func apply_character(config: Dictionary) -> void:
	race_id = String(config.get("race", ""))
	class_id = String(config.get("class", ""))
	var race: Dictionary = GameData.races.get(race_id, {})
	var cls: Dictionary = GameData.classes.get(class_id, {})

	# Stats = valeurs réparties (C.1) + bonus de race + bonus de classe.
	var allocated: Dictionary = config.get("stats", {})
	for stat_id in stats:
		var value := int(allocated.get(stat_id, 5))
		value += int((race.get("stat_bonuses", {}) as Dictionary).get(stat_id, 0))
		value += int((cls.get("stat_bonuses", {}) as Dictionary).get(stat_id, 0))
		stats[stat_id] = value

	# Compétences de départ (C.3) + potentiels de base (6.4 : race PUIS classe).
	for skill_id in (cls.get("starting_skills", {}) as Dictionary):
		if skills.skills.has(skill_id):
			skills.skills[skill_id]["level"] = int(cls["starting_skills"][skill_id])
	for source: Dictionary in [race.get("base_potentials", {}), cls.get("base_potentials", {})]:
		for skill_id in source:
			if skills.skills.has(skill_id):
				skills.skills[skill_id]["potential"] = float(source[skill_id])
	skills.xp_modifier = float(race.get("xp_modifier", 1.0))

	# Kit de départ (C.3) : objets craftés + matériaux + or.
	for entry: Dictionary in cls.get("starting_items", []):
		var obj := ItemFactory.craft(String(entry["item_id"]), entry.get("materials", {}), float(entry.get("quality", 1.0)))
		if not obj.is_empty():
			inventory.add_object(obj)
	for mat_id in (cls.get("starting_materials", {}) as Dictionary):
		inventory.add_material(mat_id, int(cls["starting_materials"][mat_id]))
	gold = int(cls.get("gold", 0))

	_recompute_derived()


## Dernière position caméra valide — la sauvegarde de sortie (SaveManager)
## s'exécute alors que la scène est déjà détachée de l'arbre : interroger
## global_position à ce moment-là renvoie une erreur et (0,0,0), ce qui
## téléporterait le joueur à l'origine au chargement suivant.
var _last_known_position := Vector3.ZERO


## Position de référence pour l'IA des créatures (aggro, poursuite).
func get_position_for_ai() -> Vector3:
	if _camera != null and _camera.is_inside_tree():
		_last_known_position = _camera.global_position
	return _last_known_position


# --- Sauvegarde (E.10, via SaveManager — players/*.json : « inventaire,
# compétences+XP, position, or ») ---

func save_state() -> Dictionary:
	var pos := get_position_for_ai()
	return {
		"position": [pos.x, pos.y, pos.z],
		"race": race_id,
		"class": class_id,
		"stats": stats.duplicate(),
		"xp_modifier": skills.xp_modifier,
		"gold": gold,
		"health": health,
		"hunger": hunger,
		"selected_slot": selected_slot,
		"active_hotbar": active_hotbar,
		"active_res": active_res,
		"skills": skills.save_state(),
		"inventory": inventory.save_state(),
	}


func restore_state(data: Dictionary) -> void:
	race_id = String(data.get("race", ""))
	class_id = String(data.get("class", ""))
	var saved_stats: Dictionary = data.get("stats", {})
	for stat_id in stats:
		stats[stat_id] = int(saved_stats.get(stat_id, stats[stat_id]))
	gold = int(data.get("gold", 0))
	selected_slot = int(data.get("selected_slot", 0))
	active_hotbar = int(data.get("active_hotbar", 0))
	var res := int(data.get("active_res", 32))
	if res in RES_SEQUENCE:
		active_res = res
	skills.restore_state(data.get("skills", {}))
	skills.xp_modifier = float(data.get("xp_modifier", 1.0))
	inventory.restore_state(data.get("inventory", {}))
	# Santé/mana dérivent des stats/compétences restaurées (A.5). Le mana
	# repart plein (simplification), la santé est restaurée telle quelle,
	# bornée par le nouveau max (l'Endurance restaurée peut l'avoir changé).
	health_max = 20.0 + int(stats["endurance"]) * 8.0
	mana = ManaPool.new(int(stats["volonte"]), skills.level("meditation"))
	health = clampf(float(data.get("health", health_max)), 1.0, health_max)
	hunger = clampf(float(data.get("hunger", hunger_max)), 0.0, hunger_max)
	var pos: Variant = data.get("position")
	if pos is Array and (pos as Array).size() == 3:
		teleport_to(Vector3(float(pos[0]), float(pos[1]), float(pos[2])))


func skill_level(skill_id: String) -> int:
	return skills.level(skill_id)


func take_damage(amount: int) -> void:
	health = maxf(0.0, health - amount)


func _unhandled_input(event: InputEvent) -> void:
	if input_locked:
		return
	var button := event as InputEventMouseButton
	if button != null and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if button.button_index == MOUSE_BUTTON_LEFT:
			if button.pressed and _target_creature != null:
				_try_melee_attack()  # Créature visée : un coup par clic (cooldown E.1).
			else:
				_mining = button.pressed and _target_creature == null
				if not button.pressed:
					_progress = 0.0
		elif button.button_index == MOUSE_BUTTON_RIGHT and button.pressed:
			_try_place()
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_scroll_hotbar(-1, button.shift_pressed)
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_scroll_hotbar(1, button.shift_pressed)
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo:
		if key.physical_keycode >= KEY_1 and key.physical_keycode <= KEY_9:
			var slot := key.physical_keycode - KEY_1
			if key.shift_pressed:
				active_hotbar = slot  # Shift+1..9 : changer de banque de hotbar.
			else:
				selected_slot = slot
		elif key.physical_keycode == KEY_R:
			# Cycle de la résolution de grille (4.1) : 32 → 16 → 8 → 4.
			active_res = RES_SEQUENCE[(RES_SEQUENCE.find(active_res) + 1) % RES_SEQUENCE.size()]
			_progress = 0.0
		elif key.physical_keycode in MODULE_KEYS:
			_try_cast_module(MODULE_KEYS.find(key.physical_keycode))
		elif key.physical_keycode == KEY_V:
			_toggle_claim()
		elif key.physical_keycode == KEY_B:
			_cycle_claim_role()
		elif key.physical_keycode == KEY_T:
			_try_stock_stall()
		elif key.physical_keycode == KEY_G:
			_try_collect_stall()


## Cellule (3.2 : 128×128 blocs) où se trouve le joueur.
func current_cell() -> Vector2i:
	var pos := get_position_for_ai()
	return ClaimManager.cell_of_block(int(pos.x), int(pos.z))


func _toggle_claim() -> void:
	var cell := current_cell()
	if ClaimManager.is_claimed(cell):
		ClaimManager.unclaim(cell)
	else:
		ClaimManager.claim(cell)


func _cycle_claim_role() -> void:
	var role := ClaimManager.cycle_role(current_cell())
	if role != "":
		EventBus.ui_notification.emit("ui.role." + role)


## Voyage rapide (6.3) : point marchable au centre de la cellule choisie, en
## surface. Garde-fou de connexité (200 blocs, 6.3) différé — simplification
## assumée à cette étape (pas encore de flood fill de surface).
## Cellule DONJON (3.5, 2026-07-21) : le voyage rapide ne peut cibler que
## l'entrée — cibler la cellule fait entrer DIRECTEMENT dans le donjon
## (écran de chargement, sans le compte à rebours de l'approche à pied).
func fast_travel_to_cell(cell: Vector2i) -> void:
	if DungeonManager.is_dungeon_cell(cell):
		DungeonManager.enter_from_map(cell)
		return
	var cx := cell.x * ClaimManager.CELL_SIZE + ClaimManager.CELL_SIZE / 2
	var cz := cell.y * ClaimManager.CELL_SIZE + ClaimManager.CELL_SIZE / 2
	fast_travel_to_world(cx, cz)


## Voyage vers un point monde (carte) : PROGRESSIF désormais (2026-07-26) — le
## joueur marche automatiquement jusqu'à la cible, à mi-vitesse (2× plus lent
## qu'à pied). Plus de téléportation instantanée.
func fast_travel_to_world(wx: int, wz: int) -> void:
	_camera.travel_to(wx, wz)


## Téléportation générique (DungeonManager : entrée/sortie de donjon).
func teleport_to(pos: Vector3) -> void:
	_camera.teleport_to(pos)


## Molette : change l'emplacement sélectionné ; Shift+molette : change de
## banque de hotbar (jusqu'à 9).
func _scroll_hotbar(delta: int, shifted: bool) -> void:
	if shifted:
		active_hotbar = wrapi(active_hotbar + delta, 0, HOTBAR_COUNT)
	else:
		selected_slot = wrapi(selected_slot + delta, 0, HOTBAR_SLOTS)


func _process(_delta: float) -> void:
	# Visée + fantôme + overlays : visuel uniquement, la récolte avance en ticks (E.1).
	_update_target()
	_update_ghost()
	_update_mining_overlay()


## Progression de récolte normalisée (0..1) — pour la barre de l'UI.
func harvest_progress() -> float:
	if not _mining or not _target_valid or _bouncing or _required <= 0.0:
		return 0.0
	return clampf(_progress / _required, 0.0, 1.0)


func _update_mining_overlay() -> void:
	if _mining_overlay == null:
		return
	var progress := harvest_progress()
	var show := progress > 0.0
	_mining_overlay.visible = show
	if show:
		if active_res == 32:
			_mining_overlay.scale = Vector3.ONE
			_mining_overlay.position = Vector3(_target) + Vector3.ONE * 0.5
		else:
			# La sous-région en cours de sculpture, à la résolution active.
			var region := _carve_region()
			_mining_overlay.scale = Vector3.ONE * (active_res / 32.0)
			_mining_overlay.position = Vector3(_target) + (Vector3(region) + Vector3.ONE * (_cells_per_side() / 2.0)) * SubdivGrid.CELL_UNIT
		_mining_overlay_mat.albedo_color = Color(0, 0, 0, 0.15 + 0.45 * progress)


# --- Combat (E.3/A.5/A.6, par ticks) ---

## Fonctionnalité de l'arme équipée (hotbar) — mains nues si aucune arme
## n'est sélectionnée (4.2 : type d'arme déterminé par ce qui est en main).
func _equipped_weapon() -> Dictionary:
	var entry := _selected_entry()
	if entry.get("kind", "") == "object":
		var obj: Dictionary = entry["object"]
		var item: Dictionary = GameData.items.get(obj["item_id"], {})
		if item.get("type", "") == "arme":
			return obj
	return {}


func _try_melee_attack() -> void:
	if _attack_cooldown_ticks > 0 or _target_creature == null or not is_instance_valid(_target_creature):
		return
	var weapon := _equipped_weapon()
	var functionality: Dictionary
	var base_hardness: float
	var quality: float
	if weapon.is_empty():
		functionality = GameData.functionalities["mains_nues"]
		base_hardness = 1.0
		quality = 1.0
	else:
		functionality = GameData.functionalities[weapon["functionality"]]
		base_hardness = weapon["base_hardness"]
		quality = weapon["quality"]
	var skill_id := String(functionality["combat_skill"])
	# Vitesse d'attaque (A.4.1) : vitesse_base × (poids_référence/poids_réel)^0.75,
	# bornée à [0.4, 1.8] × base — « la densité pilote la vitesse » (4.2) :
	# une épée en granit noir frappe lentement, un manche en pin accélère.
	# (Audit 2026-07-21 : la formule existait au GDD mais n'était pas branchée.)
	var base_speed: float = functionality["vitesse_base"]
	var speed := base_speed
	if not weapon.is_empty():
		var real_weight := maxf(float(weapon.get("weight", 1.0)), 0.1)
		var ref_weight := maxf(float(functionality.get("poids_reference", real_weight)), 0.1)
		speed = clampf(base_speed * pow(ref_weight / real_weight, 0.75),
			0.4 * base_speed, 1.8 * base_speed)
	_attack_cooldown_ticks = maxi(1, ceili(10.0 / speed))

	var result := CombatResolver.resolve_attack(
		skills.level(skill_id), int(stats["dexterite"]), int(stats["force"]),
		0, 0, String(functionality["degats_des"]), base_hardness, quality, false, "")
	if result["hit"]:
		_target_creature.health = maxf(0.0, _target_creature.health - result["damage"])
		skills.gain_xp(skill_id, result["damage"])
		if _target_creature.is_dead():
			_creature_defeated(_target_creature)


## Notifie la mort d'une créature (E.12) — le HUD écoute ce signal pour le
## toast localisé ; le nettoyage effectif (despawn) est fait par CreatureManager.
func _creature_defeated(creature: Node) -> void:
	EventBus.creature_killed.emit(self, creature)


## Lance un des 3 modules du loadout (E.3/A.6) sur la créature visée (sinon
## droit devant). Le coût en mana insuffisant inflige la surchauffe (A.5/A.6).
func _try_cast_module(slot: int) -> void:
	if slot < 0 or slot >= MODULE_LOADOUT.size() or _module_cooldown_ticks > 0:
		return
	var module: Dictionary = GameData.modules[MODULE_LOADOUT[slot]]
	var module_level := 0  # Modules non progressés à ce stade (pas encore de livres, 5.1).
	var cost: float = float(module["mana_cost_base"]) / PlayerSkills.skill_factor(module_level)
	var overheat := mana.spend(cost, skills.level("controle_mana"))
	if overheat > 0.0:
		health = maxf(0.0, health - overheat)
	_module_cooldown_ticks = 5

	if _target_creature != null and is_instance_valid(_target_creature):
		var power: float = float(module["power_base"]) * PlayerSkills.skill_factor(module_level)
		var damage := CombatResolver.roll_dice(String(module.get("degats_des", "1d4"))) + int(power * 0.1)
		_target_creature.health = maxf(0.0, _target_creature.health - damage)
		if _target_creature.is_dead():
			_creature_defeated(_target_creature)


# --- Récolte (A.2, par ticks) ---

func _on_tick(_tick_index: int) -> void:
	mana.on_tick()
	hunger = maxf(0.0, hunger - HUNGER_DECAY_PER_TICK)
	if input_locked:
		# Carte du monde ouverte (ou bench) : pas de minage/attaque en arrière-plan.
		_mining = false
		return
	if _attack_cooldown_ticks > 0:
		_attack_cooldown_ticks -= 1
	if _module_cooldown_ticks > 0:
		_module_cooldown_ticks -= 1
	if not _mining or not _target_valid:
		_progress = 0.0
		_bouncing = false
		return
	var material_id := WorldManager.block_at_world(_target)
	if material_id == 0:
		return
	var mat_name: String = GameData.material_by_runtime[material_id]
	var mat: Dictionary = GameData.materials[mat_name]
	var hardness := float(mat["stats"]["durete"])
	var harvest: Dictionary = mat["harvest"]

	# L'outil utilisé est CELUI EN MAIN (hotbar) ; s'il ne correspond pas à
	# la catégorie d'outil du matériau (4.2 : outil dédié), on récolte à
	# mains nues (A.2 : équivalent à un outil de dureté 1, qualité 1).
	var tool := _held_tool_for(String(harvest["tool_category"]))
	var tool_hardness: float = tool.get("base_hardness", 1.0)
	var tool_quality: float = tool.get("quality", 1.0)

	# Irrécoltabilité (A.2) : outil trop faible = aucun progrès, ça rebondit
	# (mains nues comprises) — le verrou physique de la stratification 3.2.
	if tool_hardness * tool_quality < hardness * 0.5:
		_bouncing = true
		_progress = 0.0
		return
	_bouncing = false

	# temps_recolte = durete_materiau / (durete_outil * qualite_outil
	#                 * skill_factor(N_recolte))                        (A.2)
	# En grille fine (4.1), le temps est proportionnel au VOLUME retiré
	# (interprétation « volume conservé », signalée au GDD).
	var skill_id := String(harvest["skill"])
	var factor := PlayerSkills.skill_factor(skills.level(skill_id))
	var block_time := hardness / (tool_hardness * tool_quality * factor)

	if active_res == 32:
		# --- Arbre : casser la BASE abat l'arbre entier (tronc + branches +
		# feuilles), temps multiplié par le nombre de blocs de BOIS (demande
		# explicite) — couper une branche ou une feuille reste un bloc normal.
		var tree := WorldManager.generator.tree_at_base(_target.x, _target.y, _target.z) if WorldManager.generator != null else {}
		if not tree.is_empty():
			var wood_count: int = (tree["wood_positions"] as Array).size()
			_required = block_time * wood_count
			_progress += TickManager.TICK_DT
			if _progress < _required:
				return
			_progress = 0.0
			for pos: Vector3i in (tree["blocks"] as Dictionary):
				WorldManager.set_block(pos, 0)
			inventory.add_material(mat_name, wood_count * (1 + floori(skills.level(skill_id) / 10.0)))
			skills.gain_xp(skill_id, hardness * wood_count)
			# Cas spécial baobab (tronc creux) : l'eau qu'il contenait se
			# libère à l'emplacement de la base une fois l'arbre abattu.
			if "contient_liquide" in (tree["special_tags"] as Array):
				var water_id: int = GameData.material_runtime_ids.get("eau", 0)
				if water_id != 0:
					WorldManager.set_block(_target, water_id)
			return
		# --- Bloc entier (normal) ---
		_required = block_time
		_progress += TickManager.TICK_DT
		if _progress < _required:
			return
		_progress = 0.0
		# Un bloc subdivisé récolté en entier crédite son volume réel.
		var subdivided := not WorldManager.subdiv_grid_at(_target).is_empty()
		var credits := _region_credits(_target, Vector3i.ZERO, SubdivGrid.SIZE) if subdivided else {}
		if not WorldManager.set_block(_target, 0):
			return
		if subdivided:
			for id: String in credits:
				inventory.add_volume(id, credits[id])
		else:
			# quantite_recoltee = 1 + floor(N_recolte / 10)             (A.2)
			inventory.add_material(mat_name, 1 + floori(skills.level(skill_id) / 10.0))
		# XP gagnée par bloc récolté = durete_materiau                  (A.2)
		skills.gain_xp(skill_id, hardness)
	else:
		# --- Sculpture : retrait d'une sous-région à la résolution active ---
		var cells := _cells_per_side()
		var region := _carve_region()
		if region != _last_carve_region:
			_last_carve_region = region
			_progress = 0.0
		var credits := _region_credits(_target, region, cells)
		if credits.is_empty():
			return  # Région déjà vide.
		var volume := cells * cells * cells / float(SubdivGrid.CELLS)
		_required = maxf(block_time * volume, TickManager.TICK_DT)
		_progress += TickManager.TICK_DT
		if _progress < _required:
			return
		_progress = 0.0
		if WorldManager.set_sub_region(_target, region, cells, 0) != "ok":
			return
		for id: String in credits:
			inventory.add_volume(id, credits[id])
		skills.gain_xp(skill_id, hardness * volume)


## Cellules de 4 px par côté à la résolution active (32→8, 16→4, 8→2, 4→1).
func _cells_per_side() -> int:
	@warning_ignore("integer_division")
	return active_res / 4


## Sous-région visée POUR LA SCULPTURE : cellule juste à l'intérieur du bloc
## touché, sous le point d'impact, alignée sur la résolution active.
func _carve_region() -> Vector3i:
	var cells := _cells_per_side()
	var local := (_hit_point - Vector3(_target_normal) * 0.001) - Vector3(_target)
	var c := Vector3i(
		clampi(floori(local.x * SubdivGrid.SIZE), 0, SubdivGrid.SIZE - 1),
		clampi(floori(local.y * SubdivGrid.SIZE), 0, SubdivGrid.SIZE - 1),
		clampi(floori(local.z * SubdivGrid.SIZE), 0, SubdivGrid.SIZE - 1))
	return (c / cells) * cells


## Sous-région visée POUR LA POSE : dans la cellule adjacente à la face
## touchée, au plus près du point d'impact.
func _place_region(cell: Vector3i) -> Vector3i:
	var cells := _cells_per_side()
	var local := _hit_point - Vector3(cell)
	var c := Vector3i(
		clampi(floori(local.x * SubdivGrid.SIZE), 0, SubdivGrid.SIZE - 1),
		clampi(floori(local.y * SubdivGrid.SIZE), 0, SubdivGrid.SIZE - 1),
		clampi(floori(local.z * SubdivGrid.SIZE), 0, SubdivGrid.SIZE - 1))
	return (c / cells) * cells


## Cible FINE de pose d'un sous-bloc (2026-07-26) : détermine À LA FOIS le bloc
## ET la sous-cellule, au sous-voxel près, en décalant le point d'impact d'une
## demi sous-cellule du côté vide de la face. Corrige le bug « poser sur la face
## d'un sous-bloc INTÉRIEUR à un bloc sautait au bloc entier au-dessus ».
## Retourne { "block": Vector3i, "region": Vector3i }.
func _place_target_fine() -> Dictionary:
	var half := 0.5 / float(SubdivGrid.SIZE)
	var p := _hit_point + Vector3(_target_normal) * half
	var block := Vector3i(floori(p.x), floori(p.y), floori(p.z))
	var local := p - Vector3(block)
	var cells := _cells_per_side()
	var region := Vector3i(
		clampi(floori(local.x * SubdivGrid.SIZE), 0, SubdivGrid.SIZE - 1),
		clampi(floori(local.y * SubdivGrid.SIZE), 0, SubdivGrid.SIZE - 1),
		clampi(floori(local.z * SubdivGrid.SIZE), 0, SubdivGrid.SIZE - 1))
	return {"block": block, "region": (region / cells) * cells}


## Volumes solides (en blocs) par matériau dans une sous-région d'un bloc.
func _region_credits(block_pos: Vector3i, cell_min: Vector3i, cells: int) -> Dictionary:
	var credits := {}
	var grid := WorldManager.subdiv_grid_at(block_pos)
	if grid.is_empty():
		# Bloc plein : sculpter y taille directement (conversion en grille
		# faite par set_sub_region).
		var id := WorldManager.block_at_world(block_pos)
		if id != 0:
			credits[GameData.material_by_runtime[id]] = cells * cells * cells / float(SubdivGrid.CELLS)
		return credits
	for y in range(cell_min.y, cell_min.y + cells):
		for z in range(cell_min.z, cell_min.z + cells):
			var row := (z << 3) | (y << 6)
			for x in range(cell_min.x, cell_min.x + cells):
				var id := grid[row | x]
				if id != 0:
					var mat_name: String = GameData.material_by_runtime[id]
					credits[mat_name] = float(credits.get(mat_name, 0.0)) + 1.0 / SubdivGrid.CELLS
	return credits


# --- Hotbar unifiée : outils PUIS matériaux, répartis en 9 banques de 9 ---
# (molette : emplacement · Shift+molette ou Shift+1-9 : banque, jusqu'à 9)

## TOUTES les entrées possédées, ordre stable : objets (outils) d'abord, puis
## piles de matériaux triées par id. Chaque entrée : {"kind": "object",
## "object": {...}} ou {"kind": "material", "id": String, "count": int}.
func all_entries() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for obj in inventory.objects:
		entries.append({"kind": "object", "object": obj})
	for id: String in inventory.material_ids():
		var vol := inventory.total_volume(id)
		if vol <= 0.0001:
			continue
		# `count` = blocs entiers (compat) ; `volume` = total fractionnaire (13.27).
		entries.append({"kind": "material", "id": id,
			"count": int(inventory.material_stacks.get(id, 0)), "volume": vol})
	return entries


## Fenêtre de 9 entrées pour la banque `bank` (0-8) — vue affichée par la hotbar.
func hotbar_entries(bank: int = -1) -> Array[Dictionary]:
	var start := (active_hotbar if bank < 0 else bank) * HOTBAR_SLOTS
	var entries := all_entries()
	if start >= entries.size():
		return []
	return entries.slice(start, mini(start + HOTBAR_SLOTS, entries.size()))


## Clé de nom localisée de l'objet/du matériau en main ("" si rien).
func held_name_key() -> String:
	var entry := _selected_entry()
	match entry.get("kind", ""):
		"object":
			return entry["object"]["name_key"]
		"material":
			return GameData.materials[entry["id"]]["name_key"]
	return ""


## Entrée sélectionnée (API publique — vue première personne, UI).
func held_entry() -> Dictionary:
	return _selected_entry()


func _selected_entry() -> Dictionary:
	var entries := hotbar_entries()
	if selected_slot < entries.size():
		return entries[selected_slot]
	return {}


## L'outil EN MAIN s'il correspond à la catégorie demandée, sinon vide
## (= mains nues).
func _held_tool_for(tool_category: String) -> Dictionary:
	var entry := _selected_entry()
	if entry.get("kind", "") != "object":
		return {}
	var obj: Dictionary = entry["object"]
	if String(obj.get("tool_category", "")) != tool_category:
		return {}
	return obj


# --- Pose de blocs (4.1) ---

func _selected_material() -> String:
	var entry := _selected_entry()
	if entry.get("kind", "") == "material":
		return entry["id"]
	return ""


func _placement_cell() -> Vector3i:
	return _target + _target_normal


func _placement_valid() -> bool:
	if not (_target_valid and _target_normal != Vector3i.ZERO and _selected_material() != ""):
		return false
	if active_res == 32:
		var cell := _placement_cell()
		if cell.y < WorldManager.WORLD_Y_MIN or cell.y > WorldManager.WORLD_Y_MAX:
			return false
		return WorldManager.block_at_world(cell) == 0
	# Sous-bloc : ciblage FIN (bloc + sous-cellule). La région visée doit être
	# libre (cellule d'air, ou bloc subdivisé avec la région vide).
	var ft := _place_target_fine()
	var b: Vector3i = ft["block"]
	if b.y < WorldManager.WORLD_Y_MIN or b.y > WorldManager.WORLD_Y_MAX:
		return false
	var grid := WorldManager.subdiv_grid_at(b)
	if grid.is_empty():
		return WorldManager.block_at_world(b) == 0
	return SubdivGrid.region_empty(grid, ft["region"], _cells_per_side())


func _try_place() -> void:
	if not _placement_valid():
		return
	var mat_name := _selected_material()
	var runtime_id: int = GameData.material_runtime_ids.get(mat_name, 0)
	if runtime_id == 0:
		return
	if active_res == 32:
		if WorldManager.set_block(_placement_cell(), runtime_id):
			inventory.remove_material(mat_name, 1)
		return
	# Pose d'un sous-bloc (4.1) : ciblage FIN + consomme le volume correspondant.
	var cells := _cells_per_side()
	var volume := cells * cells * cells / float(SubdivGrid.CELLS)
	if not inventory.remove_volume(mat_name, volume):
		return
	var ft := _place_target_fine()
	var result := WorldManager.set_sub_region(ft["block"], ft["region"], cells, runtime_id)
	if result != "ok":
		inventory.add_volume(mat_name, volume)  # Remboursé.
		if result == "budget":
			EventBus.ui_notification.emit("ui.toast.budget_subdivision")


func _try_stock_stall() -> void:
	if not _target_valid:
		return
	var mat_name := _selected_material()
	if mat_name == "":
		return
	if ShopManager.stock_item(_target, mat_name, inventory):
		var price := ShopManager.suggested_price(mat_name)
		EventBus.ui_notification.emit(tr("ui.toast.etal_stock").format({
			"item": tr(GameData.materials[mat_name]["name_key"]), "prix": str(price)}))


func _try_collect_stall() -> void:
	if not _target_valid:
		return
	var amount := ShopManager.collect_gold(_target)
	if amount > 0:
		gold += amount
		EventBus.ui_notification.emit(tr("ui.toast.etal_collecte").format({"montant": str(amount)}))


# --- Visée (DDA voxel — pas de colliders physiques : le monde EST la grille) ---

func _update_target() -> void:
	if _camera == null:
		_target_valid = false
		_target_creature = null
		return
	var origin := _camera.global_position
	var dir := -_camera.global_basis.z

	# Créatures d'abord (E.3) : sphère la plus proche que le rayon traverse.
	_target_creature = _raycast_creature(origin, dir, REACH)
	if _target_creature != null:
		_target_valid = false
		_progress = 0.0
		return

	var hit := _raycast_voxel(origin, dir, REACH)
	var new_valid: bool = hit.has("pos")
	var new_target: Vector3i = hit.get("pos", Vector3i.ZERO)
	if new_valid != _target_valid or new_target != _target:
		_progress = 0.0  # Cible changée : la récolte repart de zéro.
	_target_valid = new_valid
	if new_valid:
		_target = new_target
		_target_normal = hit.get("normal", Vector3i.ZERO)
		_hit_point = hit.get("point", Vector3(_target))


## Créature la plus proche que le rayon de visée traverse (rayon 0.6, hauteur
## 1.2) — pas de colliders physiques, distance point-segment simple.
func _raycast_creature(origin: Vector3, dir: Vector3, max_dist: float) -> Node:
	var best: Node = null
	var best_t := max_dist
	for creature in CreatureManager.creatures:
		if not is_instance_valid(creature) or creature.is_dead():
			continue
		if creature.dimension != WorldManager.active_dimension:
			continue  # Jamais viser une créature gelée d'une autre dimension (3.5).
		var center: Vector3 = creature.position + Vector3.UP * 0.6
		var to_center := center - origin
		var t := to_center.dot(dir)
		if t < 0.0 or t > max_dist:
			continue
		var closest := origin + dir * t
		if closest.distance_to(center) <= 0.6 and t < best_t:
			best_t = t
			best = creature
	return best


## Parcours DDA de la grille voxel (Amanatides & Woo). Retourne
## { "pos": Vector3i, "normal": Vector3i, "point": Vector3 } ou {} si rien
## dans la portée. Un bloc SUBDIVISÉ (4.1) n'occupe pas forcément tout son
## volume — le point/normale de surface sont affinés par un second DDA dans
## sa sous-grille 8×8×8 (_raycast_subdiv) ; sans ça, viser/poser près d'un
## bloc déjà subdivisé calculait le point de contact sur la face de la
## BOÎTE ENGLOBANTE pleine, pas sur la vraie surface fine — ce qui décalait
## la pose d'un sous-bloc (8px/4px) sur la cellule voisine (bug constaté).
func _raycast_voxel(origin: Vector3, dir: Vector3, max_dist: float) -> Dictionary:
	var pos := Vector3i(floori(origin.x), floori(origin.y), floori(origin.z))
	if WorldManager.block_at_world(pos) != 0:
		var grid0 := WorldManager.subdiv_grid_at(pos)
		if grid0.is_empty():
			return {"pos": pos, "normal": Vector3i.ZERO, "point": origin}  # Caméra dans un bloc.
		var refined0 := _raycast_subdiv(pos, grid0, origin, dir, Vector3i.ZERO)
		if not refined0.is_empty():
			return refined0
	var step := Vector3i.ZERO
	var t_max := Vector3.INF
	var t_delta := Vector3.INF
	for axis in 3:
		if absf(dir[axis]) > 0.000001:
			step[axis] = 1 if dir[axis] > 0.0 else -1
			t_delta[axis] = absf(1.0 / dir[axis])
			var boundary := float(pos[axis] + (1 if step[axis] > 0 else 0))
			t_max[axis] = (boundary - origin[axis]) / dir[axis]
	var normal := Vector3i.ZERO
	var t := 0.0
	while t <= max_dist:
		# Avancer vers la frontière de cellule la plus proche.
		var axis := 0
		if t_max.y < t_max.x:
			axis = 1
		if t_max.z < t_max[axis]:
			axis = 2
		t = t_max[axis]
		if t > max_dist:
			break
		t_max[axis] += t_delta[axis]
		pos[axis] += step[axis]
		normal = Vector3i.ZERO
		normal[axis] = -step[axis]
		if WorldManager.block_at_world(pos) != 0:
			var grid := WorldManager.subdiv_grid_at(pos)
			if grid.is_empty():
				return {"pos": pos, "normal": normal, "point": origin + dir * t}
			var refined := _raycast_subdiv(pos, grid, origin + dir * t, dir, normal)
			if not refined.is_empty():
				return refined
			# La géométrie fine ne bloque pas ici (ex. coin creusé) : ce bloc
			# ne compte pas comme un obstacle, on continue le DDA principal.
	return {}


## Second DDA, à l'intérieur de la sous-grille 8×8×8 d'un bloc subdivisé
## (voir _raycast_voxel). `entry_point` est le point où le rayon entre dans
## ce bloc (monde), `entry_normal` la normale de cette face d'entrée (ZERO
## si la caméra est déjà dans le bloc). Retourne {} si le rayon traverse le
## bloc sans toucher de sous-cellule pleine (ex. coin creusé/vide).
func _raycast_subdiv(block_pos: Vector3i, grid: PackedInt32Array, entry_point: Vector3, dir: Vector3, entry_normal: Vector3i) -> Dictionary:
	const N := SubdivGrid.SIZE
	const UNIT := 1.0 / N
	var local_origin := entry_point - Vector3(block_pos)
	var cell := Vector3i(
		clampi(floori(local_origin.x / UNIT), 0, N - 1),
		clampi(floori(local_origin.y / UNIT), 0, N - 1),
		clampi(floori(local_origin.z / UNIT), 0, N - 1))
	if grid[SubdivGrid.cell_index(cell.x, cell.y, cell.z)] != 0:
		return {"pos": block_pos, "normal": entry_normal, "point": entry_point}
	var step := Vector3i.ZERO
	var t_max := Vector3.INF
	var t_delta := Vector3.INF
	for axis in 3:
		if absf(dir[axis]) > 0.000001:
			step[axis] = 1 if dir[axis] > 0.0 else -1
			t_delta[axis] = UNIT * absf(1.0 / dir[axis])
			var boundary := (float(cell[axis]) + (1.0 if step[axis] > 0 else 0.0)) * UNIT
			t_max[axis] = (boundary - local_origin[axis]) / dir[axis]
	var normal := entry_normal
	var t := 0.0
	while t <= 2.0:  # Jamais plus que la diagonale d'un bloc (√3 ≈ 1.73).
		var axis := 0
		if t_max.y < t_max.x:
			axis = 1
		if t_max.z < t_max[axis]:
			axis = 2
		t = t_max[axis]
		var next_cell := cell[axis] + step[axis]
		if next_cell < 0 or next_cell >= N:
			return {}  # Sort du bloc sans toucher de sous-cellule pleine.
		t_max[axis] += t_delta[axis]
		cell[axis] = next_cell
		normal = Vector3i.ZERO
		normal[axis] = -step[axis]
		if grid[SubdivGrid.cell_index(cell.x, cell.y, cell.z)] != 0:
			return {"pos": block_pos, "normal": normal, "point": entry_point + dir * t}
	return {}


# --- Fantôme de prévisualisation (4.1) ---

func _build_ghost() -> void:
	_ghost_ok = StandardMaterial3D.new()
	_ghost_ok.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_ok.albedo_color = Color(0.2, 1.0, 0.3, 0.35)
	_ghost_ok.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_bad = StandardMaterial3D.new()
	_ghost_bad.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_bad.albedo_color = Color(1.0, 0.2, 0.2, 0.4)
	_ghost_bad.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var box := BoxMesh.new()
	box.size = Vector3.ONE * 1.002
	_ghost = MeshInstance3D.new()
	_ghost.mesh = box
	_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ghost.visible = false
	get_parent().add_child(_ghost)
	# Overlay de minage : boîte sombre dont l'opacité suit la progression.
	_mining_overlay_mat = StandardMaterial3D.new()
	_mining_overlay_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mining_overlay_mat.albedo_color = Color(0, 0, 0, 0.0)
	_mining_overlay_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var overlay_box := BoxMesh.new()
	overlay_box.size = Vector3.ONE * 1.004
	_mining_overlay = MeshInstance3D.new()
	_mining_overlay.mesh = overlay_box
	_mining_overlay.material_override = _mining_overlay_mat
	_mining_overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mining_overlay.visible = false
	get_parent().add_child(_mining_overlay)


func _update_ghost() -> void:
	if _ghost == null:
		return
	# Le fantôme n'apparaît que si un matériau est sélectionné et une face visée
	# (4.1 : même position que le vrai placement, vert = valide, rouge = invalide).
	var show := _target_valid and _target_normal != Vector3i.ZERO and _selected_material() != ""
	_ghost.visible = show
	if show:
		# Le fantôme montre la sous-cellule exacte à la résolution active (4.1).
		var fraction := active_res / 32.0
		_ghost.scale = Vector3.ONE * fraction
		if active_res == 32:
			_ghost.position = Vector3(_placement_cell()) + Vector3.ONE * 0.5
		else:
			var ft := _place_target_fine()
			_ghost.position = Vector3(ft["block"] as Vector3i) + (Vector3(ft["region"] as Vector3i) + Vector3.ONE * (_cells_per_side() / 2.0)) * SubdivGrid.CELL_UNIT
		_ghost.material_override = _ghost_ok if _placement_valid() else _ghost_bad


## Informations de visée pour le HUD (clés tr() côté UI, 10.1).
## Créature visée (nom localisé + PV), pour le HUD — {} si aucune.
func creature_target_info() -> Dictionary:
	if _target_creature == null or not is_instance_valid(_target_creature):
		return {}
	return {
		"name_key": _target_creature.display_name_key,
		"health": int(_target_creature.health),
		"health_max": int(_target_creature.health_max),
	}


func target_info() -> Dictionary:
	if not _target_valid:
		return {}
	var material_id := WorldManager.block_at_world(_target)
	if material_id == 0:
		return {}
	var mat_name: String = GameData.material_by_runtime[material_id]
	var mat: Dictionary = GameData.materials[mat_name]
	# `str()` (pas `String()`) : le constructeur `String()` rejette la valeur
	# Nil telle quelle — bug réel trouvé en visant un matériau décoratif SANS
	# outil de récolte (`tool_category: null`, ex. étal de vente/brique/verre),
	# jamais déclenché avant faute d'avoir jamais visé un tel matériau.
	var tool := _held_tool_for(str(mat["harvest"].get("tool_category", "")))
	return {
		"name_key": mat["name_key"],
		"tool_name_key": tool.get("name_key", ""),  # vide = mains nues
		"progress_pct": int(100.0 * _progress / maxf(_required, 0.001)) if _mining else 0,
		"bouncing": _bouncing and _mining,
	}

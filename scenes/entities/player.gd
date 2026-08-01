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
## Potentiel PAR STAT (6.4) : 0-200, plancher au potentiel de base. Monté par
## les plats cuisinés (A.9.1). ATTENTION — il est stocké, sauvegardé et
## affiché, mais rien ne le CONSOMME encore : 6.4 prévoit que les stats
## gagnent de l'XP multipliée par leur potentiel, or la progression de stats
## n'existe pas (les stats sont figées à la création). Le crédit est donc
## fidèle au GDD, son effet attend la progression de stats.
const POTENTIAL_BASE := 80.0
const POTENTIAL_MAX := 200.0
var stat_potentials := {"force": POTENTIAL_BASE, "dexterite": POTENTIAL_BASE,
	"endurance": POTENTIAL_BASE, "volonte": POTENTIAL_BASE,
	"perception": POTENTIAL_BASE, "charisme": POTENTIAL_BASE}
var skills: PlayerSkills
var inventory: Inventory
## Emplacements d'équipement (6.2) — l'armure portée alimente la mitigation
## d'E.3, jusque-là toujours nulle faute d'équipement.
var equipment: Equipment
## Cabinet de curiosités (2026-08-01) : tout ce que le joueur a offert, et donc
## définitivement détruit. Porté par le PERSONNAGE et non par le monde : c'est
## un accomplissement, il suit celui qui l'a obtenu.
var collection: Collection
## Réputation et relations (7.2). Portée par le personnage : c'est SA
## réputation, elle le suit d'un monde à l'autre comme ses compétences.
var reputation: Reputation
## Santé — formule validée par l'auteur (2026-07-20), par analogie avec le
## mana (A.5, Endurance ~ Volonté) : santé_max = 20 + Endurance * 8.
var health_max: float
var health: float
## Faim (A.9) : décroît lentement avec le temps, se restaure en mangeant
## (touche F sur un matériau comestible en main — A.9.1). Effets de seuil
## appliqués par tick dans _hunger_tick_effects.
var hunger_max := 100.0
var hunger := 100.0
const HUNGER_DECAY_PER_TICK := 0.003   # ~100 → 0 en ~1,4 jour in-game (24000 ticks/jour).
## Seuils A.9 : < 50 → -10 % de régén de santé ; < 25 → -10 % à toutes les
## stats ET plus aucune régén ; = 0 → famine (1 % de santé max / 30 s).
const HUNGER_REGEN_PENALTY := 50.0
const HUNGER_STARVING := 25.0
const HUNGER_STAT_MALUS := 0.9
const STARVE_INTERVAL_TICKS := 300     # 30 s à 10 ticks/s (E.1).
const STARVE_HEALTH_FRACTION := 0.01
## Régénération de santé — le GDD ne donne PAS de formule (A.5.1 ne couvre
## que le maximum ; A.9 se contente de la moduler). Proposition par défaut,
## calquée sur la cadence du mana (A.5) : 1 PV toutes les 10 s, dont A.9
## retire 10 % sous 50 de faim et tout sous 25.
const HEALTH_REGEN_INTERVAL_TICKS := 100
const HEALTH_REGEN_AMOUNT := 1.0
## FATIGUE (amendement E.21 du 2026-07-27, demande de l'auteur — la spec
## d'origine excluait explicitement toute jauge de fatigue). Elle descend
## avec le temps éveillé et se restaure en dormant. Réglée pour rester une
## INCITATION, pas une corvée : ses effets sont progressifs, jamais létaux,
## et une nuit de sommeil la remplit entièrement.
##   < 50 : -10 % d'XP gagnée
##   < 25 : -10 % à toutes les stats, plus de régénération de santé
##   = 0  : effets cumulés, mais aucun dégât (contrairement à la famine A.9)
var fatigue_max := 100.0
var fatigue := 100.0
## ~2 jours in-game d'éveil avant l'épuisement total : dormir une nuit sur
## deux suffit, on ne court jamais après la jauge.
const FATIGUE_DECAY_PER_TICK := 0.002
const FATIGUE_TIRED := 50.0
const FATIGUE_EXHAUSTED := 25.0
const FATIGUE_XP_MALUS := 0.9
const FATIGUE_STAT_MALUS := 0.9
## Sommeil (E.21). Dormir demande un LIT visé (meuble F.6). Deux effets :
## saut de la nuit (21h → 5h) et buff « Reposé » (+5 % d'XP pendant 4 h
## in-game). Aucune jauge de fatigue : le GDD est explicite, dormir est un
## choix avantageux, jamais une corvée.
const RESTED_DURATION_TICKS := 4000     # 4 h in-game (24 000 ticks/jour).
const RESTED_XP_BONUS := 0.05
## Le saut de nuit fait AVANCER les ticks : la faim, le mana et l'IA
## consomment réellement le temps sauté (E.21 : « le saut n'est jamais
## gratuit ni exploitable »). Poussé par paquets pour ne pas geler la frame.
const SLEEP_TICK_BATCH := 500
var rested_until_tick := 0
## Mort (A.10) : -10 % de l'or transporté, 10 % de chance de perdre chaque objet.
const DEATH_GOLD_PENALTY := 0.10
const DEATH_DROP_CHANCE := 0.10
var _regen_tick_counter := 0
var _starve_tick_counter := 0
var mana: ManaPool
## Monnaie unique (or, 7.1) — aucun concept de portefeuille PNJ/taxes/
## entretien (A.8.1) n'est implémenté, seul le joueur en a un pour l'instant.
var gold: int = 0
var selected_slot := 0
## Banque de hotbar active (Ctrl+molette ou Ctrl+1-9).
var active_hotbar := 0
## LIAISONS de hotbar (2026-07-27) : indice absolu (banque * 9 + slot) ->
## { "kind": "material", "id": ... } ou { "kind": "object", "uid": ... }.
##
## Avant, la hotbar était une simple FENÊTRE sur la liste d'inventaire : son
## contenu changeait tout seul dès qu'on ramassait ou consommait quelque
## chose, et rien ne pouvait y être assigné. Les liaisons désignent les objets
## par `uid` (stable au tri, à la sauvegarde et au rechargement) et les
## matériaux par id. Une liaison dont la cible a disparu affiche un
## emplacement vide plutôt que de décaler tout le reste.
var hotbar_bindings := {}
## Banques de hotbar : PLANCHER, pas plafond (corrigé le 2026-07-27).
## Le nombre réel de banques suit la taille de l'inventaire — voir
## hotbar_bank_count(). L'ancienne constante était un plafond dur de
## 9 x 9 = 81 entrées : au-delà, un matériau détenu devenait IMPOSSIBLE
## à prendre en main, donc impossible à poser ou à manger. Avec 310
## matériaux au catalogue et un jeu conçu pour être très dense, la
## limite était déjà atteignable en jouant normalement.
const HOTBAR_MIN_BANKS := 9
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

# État de combat. REFONTE 2026-07-28 : le combat est directionnel et
# géométrique (voir MeleeAttack et CombatResolver). Le TIMING de la frappe
# avance à la frame ; ses CONSÉQUENCES restent appliquées au tick, comme tout
# le reste du jeu — _pending_hits est la frontière exacte entre les deux.
var _module_cooldown_ticks := 0
## Créature sous le réticule — sert UNIQUEMENT à désambiguïser « miner » de
## « frapper » à mains nues, et à l'affichage. Ce n'est plus un verrouillage :
## le coup touche ce que la lame traverse, pas ce que le réticule désigne.
var _target_creature: Node = null
var _attack := MeleeAttack.new()
## Stats dérivées de l'arme en main (WeaponStats.derive) — recalculées au
## CHANGEMENT d'arme seulement, jamais à la frappe ni à la frame.
var _weapon_stats: Dictionary = {}
var _weapon_stats_key := ""
## Stats de la frappe EN COURS, figées à son déclenchement (voir _begin_attack).
var _swing_stats: Dictionary = {}
var _swing_hardness := 1.0
var _swing_quality := 1.0
## BRIDAGE DE ROTATION pendant la frappe. Sans lui, tourner vite sur soi-
## meme pendant le swing ajoute cette rotation a la vitesse de la lame et
## le bonus de vitesse se farme en tournoyant : l'« helicoptere » que Mount
# & Blade interdit precisement. La CAMERA reste libre (on continue de
## viser) ; c'est l'ARC DE FRAPPE qui rattrape le regard a vitesse bornee.
const SWING_TURN_CAP := deg_to_rad(110.0)   # radians par seconde
var _swing_basis := Basis.IDENTITY
## Position de la pointe de l'arme à la frame précédente : le segment entre
## les deux est ce qu'on teste contre les zones de coup.
var _tip_previous := Vector3.ZERO
## Coups constatés par la géométrie, en attente d'application par le tick.
var _pending_hits: Array = []
## Garde levée (clic droit avec une arme en main).
var _guard_active := false
## Horodatage (ms) de la levée de garde — sert à la fenêtre de parade : une
## garde levée juste à temps vaut mieux qu'une garde tenue passivement.
var _guard_raised_msec := 0

## Endurance (combat directionnel) : consommée par les frappes et par les
## coups encaissés en garde. À zéro, la garde casse (stagger). Formule alignée
## sur celles de la santé et du mana (A.5) : dérivée de la stat Endurance.
var stamina_max := 100.0
var stamina := 100.0
const STAMINA_PER_ENDURANCE := 10.0
const STAMINA_BASE := 50.0
## Régénération par tick (10 ticks/s → ~8 points/s à pleine régén).
const STAMINA_REGEN_PER_TICK := 0.8
## Ticks d'attente après une dépense avant que la régénération reprenne :
## sans ça, enchaîner les coups ne coûterait rien.
const STAMINA_REGEN_DELAY_TICKS := 8
var _stamina_regen_block := 0


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
	equipment = Equipment.new()
	collection = Collection.new()
	reputation = Reputation.new()
	_recompute_derived()
	_camera = get_node("../FlyCamera") as FlyCamera
	TickManager.tick_entities.connect(_on_tick)
	_build_ghost.call_deferred()


## Recalcule santé/mana depuis les stats + compétences courantes (A.5/A.5.1).
func _recompute_derived() -> void:
	health_max = 20.0 + int(stats["endurance"]) * 8.0
	health = health_max
	stamina_max = STAMINA_BASE + int(stats["endurance"]) * STAMINA_PER_ENDURANCE
	stamina = stamina_max
	mana = ManaPool.new(int(stats["volonte"]), skills.level("meditation"))


## Kit de départ FAIBLE historique (pin+cuivre 0.7) — utilisé par le mode
## direct (benchs/sondes/tests) qui n'ont pas de création de personnage.
func apply_default_character() -> void:
	for tool_id in STARTER_KIT:
		inventory.add_object(ItemFactory.craft(tool_id, STARTER_MATERIALS, STARTER_QUALITY))
	inventory.add_object(ItemFactory.craft("epee", {"bois": "pin", "minerai": "cuivre"}, STARTER_QUALITY))
	inventory.add_material("etal_de_vente", 1)
	_recompute_derived()
	autofill_hotbar()


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
	autofill_hotbar()


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
		"fatigue": fatigue,
		"selected_slot": selected_slot,
		"active_hotbar": active_hotbar,
		"active_res": active_res,
		"skills": skills.save_state(),
		"inventory": inventory.save_state(),
		"equipment": equipment.save_state(),
		"collection": collection.save_state(),
		"reputation": reputation.save_state(),
		"hotbar": _hotbar_for_save(),
		"rested_until": rested_until_tick,
		"stat_potentials": stat_potentials.duplicate(),
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
	equipment.restore_state(data.get("equipment", {}))
	collection.restore_state(data.get("collection", {}))
	reputation.restore_state(data.get("reputation", {}))
	rested_until_tick = int(data.get("rested_until", 0))
	var saved_potentials: Dictionary = data.get("stat_potentials", {})
	for stat_id: String in stat_potentials:
		stat_potentials[stat_id] = float(saved_potentials.get(stat_id, POTENTIAL_BASE))
	hotbar_bindings.clear()
	for entry: Variant in data.get("hotbar", []):
		if entry is Dictionary and (entry as Dictionary).has("slot"):
			var saved: Dictionary = entry
			hotbar_bindings[int(saved["slot"])] = {
				"kind": String(saved.get("kind", "")),
				"id": String(saved.get("id", "")),
			} if String(saved.get("kind", "")) == "material" else {
				"kind": "object", "uid": int(saved.get("uid", -1))}
	# Santé/mana dérivent des stats/compétences restaurées (A.5). Le mana
	# repart plein (simplification), la santé est restaurée telle quelle,
	# bornée par le nouveau max (l'Endurance restaurée peut l'avoir changé).
	health_max = 20.0 + int(stats["endurance"]) * 8.0
	mana = ManaPool.new(int(stats["volonte"]), skills.level("meditation"))
	health = clampf(float(data.get("health", health_max)), 1.0, health_max)
	hunger = clampf(float(data.get("hunger", hunger_max)), 0.0, hunger_max)
	fatigue = clampf(float(data.get("fatigue", fatigue_max)), 0.0, fatigue_max)
	var pos: Variant = data.get("position")
	if pos is Array and (pos as Array).size() == 3:
		teleport_to(Vector3(float(pos[0]), float(pos[1]), float(pos[2])))


func skill_level(skill_id: String) -> int:
	return skills.level(skill_id)


func take_damage(amount: int) -> void:
	health = maxf(0.0, health - amount)
	if health <= 0.0:
		die()


## Mort et pénalité (A.10), copiée à la lettre :
##   respawn au dernier claim activé ; -10 % de l'or transporté ; chaque objet
##   de l'inventaire a 10 % de chance de tomber sur le lieu de mort
##   (récupérable 1 jour in-game) ; équipement PORTÉ conservé ; aucune perte
##   d'XP (la progression par l'usage rend la perte d'XP trop punitive — le
##   GDD pénalise l'économie à la place).
## Les MATÉRIAUX en vrac ne sont pas concernés : A.10 parle des « objets de
## l'inventaire », et lâcher des fractions de blocs n'aurait pas de sens.
func die() -> void:
	var death_position := get_position_for_ai()

	var lost_gold := int(floor(gold * DEATH_GOLD_PENALTY))
	gold -= lost_gold

	var dropped: Array[Dictionary] = []
	for instance in inventory.objects.duplicate():
		if randf() < DEATH_DROP_CHANCE:
			dropped.append(instance)
	for instance in dropped:
		inventory.objects.erase(instance)
	DropManager.drop(death_position, dropped, lost_gold)

	# Retour en jeu : santé pleine, faim conservée (A.10 ne la mentionne pas —
	# mourir de faim puis réapparaître affamé reste cohérent).
	health = health_max
	_mining = false
	_progress = 0.0
	_target_creature = null
	_clamp_selection()
	_respawn()

	EventBus.player_died.emit(death_position, dropped.size(), lost_gold)
	EventBus.ui_notification.emit(tr("ui.toast.mort").format({
		"or": str(lost_gold), "objets": str(dropped.size())}))


## Point de retour : dernier claim activé (A.10), sinon la position courante
## en surface — le GDD ne prévoit pas de joueur sans aucun point d'ancrage
## (il y a toujours un lit ou un claim à ce stade du jeu), donc rester sur
## place est le repli le moins surprenant.
## Réapparition IMMÉDIATE (teleport_to), surtout pas fast_travel_to_cell :
## le voyage rapide est une traversée ANIMÉE qui pousse des ticks (donc du
## temps de jeu, de la faim, de l'IA) — infliger ça à un joueur qui vient de
## mourir n'aurait aucun sens, et le ferait entrer dans un donjon si sa case
## de retour en abritait un.
func _respawn() -> void:
	var pos := get_position_for_ai()
	var wx := int(pos.x)
	var wz := int(pos.z)
	if ClaimManager.has_respawn:
		var center := POIGenerator.cell_center_world(ClaimManager.respawn_cell)
		wx = center.x
		wz = center.y
	var h := 24.0
	if WorldManager.generator != null:
		h = float(WorldManager.generator.height_at(wx, wz))
	# +2.9 : le joueur se tient SUR le sommet du bloc de sol, l'œil 1.9 plus
	# haut que ses pieds (même convention que le spawn de main._start_world).
	teleport_to(Vector3(float(wx) + 0.5, h + 2.9, float(wz) + 0.5))


func _unhandled_input(event: InputEvent) -> void:
	if input_locked:
		return
	# Geste de souris de l'attaque directionnelle : cumulé pendant la fenêtre
	# de lecture qui suit le clic (MeleeAttack l'ignore hors de cette fenêtre,
	# donc aucune condition à écrire ici).
	var motion := event as InputEventMouseMotion
	if motion != null:
		_attack.feed_gesture(motion.relative)
		# Le MÊME geste oriente la garde : on choisit sa parade à la souris,
		# exactement comme on choisit son attaque — et, comme elle, seulement
		# pendant la fenêtre de lecture qui suit la levée de garde.
		if _guard_active and not _guard_locked:
			_guard_gesture += motion.relative
	var button := event as InputEventMouseButton
	if button != null and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if button.button_index == MOUSE_BUTTON_LEFT:
			if _wants_combat():
				# MAINTENIR arme le coup et laisse choisir sa direction ;
				# RELÂCHER le porte. Le clic n'est plus un déclencheur, c'est
				# une gâchette qu'on tient (2026-07-28).
				if button.pressed:
					_begin_attack()
				else:
					_attack.release_input()
			else:
				_mining = button.pressed
				if not button.pressed:
					_progress = 0.0
		elif button.button_index == MOUSE_BUTTON_RIGHT:
			# Une arme en main garde ; tout le reste pose des blocs. Sans cette
			# règle, lever sa garde poserait un bloc en plein duel.
			if _equipped_weapon().is_empty():
				if button.pressed:
					_try_place()
			else:
				_set_guard(button.pressed)
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_scroll_hotbar(-1, button.ctrl_pressed)
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_scroll_hotbar(1, button.ctrl_pressed)
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo:
		if key.physical_keycode >= KEY_1 and key.physical_keycode <= KEY_9:
			var slot := key.physical_keycode - KEY_1
			if key.ctrl_pressed:
				# Ctrl+1..9 : changer de banque (2026-07-27, remplace Shift —
				# Shift reste libre pour les usages classiques de déplacement).
				active_hotbar = mini(slot, hotbar_bank_count() - 1)
			else:
				selected_slot = slot
		elif key.physical_keycode == KEY_R:
			# Cycle de la résolution de grille (4.1) : 32 → 16 → 8 → 4.
			active_res = RES_SEQUENCE[(RES_SEQUENCE.find(active_res) + 1) % RES_SEQUENCE.size()]
			_progress = 0.0
		elif key.physical_keycode in MODULE_KEYS:
			_try_cast_module(MODULE_KEYS.find(key.physical_keycode))
		elif key.physical_keycode == KEY_E:
			_try_talk()
		elif key.physical_keycode == KEY_V:
			_toggle_claim()
		elif key.physical_keycode == KEY_B:
			_cycle_claim_role()
		elif key.physical_keycode == KEY_T:
			_try_stock_stall()
		elif key.physical_keycode == KEY_G:
			_try_collect_stall()
		elif key.physical_keycode == KEY_F:
			_try_eat()
		elif key.physical_keycode == KEY_E:
			_try_equip()
		elif key.physical_keycode == KEY_C:
			_try_pickup()
		elif key.physical_keycode == KEY_N:
			_try_sleep()


## Liaisons de hotbar sérialisées (les clés JSON sont des chaînes : on écrit
## une liste d'entrées plutôt qu'un dictionnaire à clés entières).
func _hotbar_for_save() -> Array:
	var out: Array = []
	for index: int in hotbar_bindings:
		var binding: Dictionary = hotbar_bindings[index]
		var row := {"slot": index, "kind": String(binding.get("kind", ""))}
		if String(binding.get("kind", "")) == "material":
			row["id"] = String(binding.get("id", ""))
		else:
			row["uid"] = int(binding.get("uid", -1))
		out.append(row)
	return out


## Remplit les emplacements libres de la hotbar avec les entrées d'inventaire
## pas encore liées, dans l'ordre. Appelé après la constitution du kit de
## départ et après un ramassage : sans ça, la hotbar assignable démarrerait
## VIDE et le joueur ne pourrait rien tenir.
func autofill_hotbar() -> void:
	var used := {}
	for index: int in hotbar_bindings:
		used[hotbar_bindings[index]] = true
	var free_slots: Array[int] = []
	for index in HOTBAR_MIN_BANKS * HOTBAR_SLOTS:
		if not hotbar_bindings.has(index):
			free_slots.append(index)
	var cursor := 0
	for entry in all_entries():
		if cursor >= free_slots.size():
			return
		var binding := _binding_for(entry)
		if binding.is_empty() or used.has(binding):
			continue
		hotbar_bindings[free_slots[cursor]] = binding
		used[binding] = true
		cursor += 1


## Équipe une INSTANCE précise (API pour l'interface d'inventaire, 6.2).
## Renvoie false si l'objet ne s'équipe pas.
func equip_instance(instance: Dictionary) -> bool:
	var item: Dictionary = GameData.items.get(instance.get("item_id", ""), {})
	var slot := equipment.resolve_slot(String(item.get("equip_slot", "")))
	if slot == "":
		EventBus.ui_notification.emit("ui.toast.pas_equipable")
		return false
	inventory.objects.erase(instance)
	var replaced := equipment.equip(instance)
	if not replaced.is_empty():
		inventory.add_object(replaced)
	_clamp_selection()
	EventBus.ui_notification.emit(tr("ui.toast.equipe").format({
		"item": tr(String(instance.get("name_key", "")))}))
	return true


## Dépose une entrée d'inventaire au sol, à portée du joueur (A.10 : même
## mécanisme que les caches de mort — un objet lâché n'est jamais détruit).
## Un matériau est déposé par pile entière, un objet par instance.
func drop_entry(entry: Dictionary) -> void:
	var position := get_position_for_ai()
	match String(entry.get("kind", "")):
		"object":
			var instance: Dictionary = entry.get("object", {})
			if instance.is_empty() or not inventory.objects.has(instance):
				return
			inventory.objects.erase(instance)
			DropManager.drop(position, [instance], 0)
		"material":
			var id := String(entry.get("id", ""))
			var amount := int(inventory.material_stacks.get(id, 0))
			if amount <= 0:
				return
			inventory.remove_material(id, amount)
			DropManager.drop_materials(position, {id: amount})
		_:
			return
	_clamp_selection()
	EventBus.ui_notification.emit("ui.toast.depose")


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


## Voyage rapide (carte) : téléportation GRADUELLE le temps que le trajet
## s'écoule (2026-07-26). Coût de base 6 ticks/bloc (2× la marche à 3 ticks/bloc,
## GDD E.1), DIVISÉ par la vitesse de déplacement du joueur (`move_speed_mult`,
## modifiable par stats/effets). Le temps est réellement simulé (mana/faim).
const MAP_TRAVEL_TICKS_PER_BLOCK := 6.0
## Multiplicateur de vitesse de déplacement (1.0 = base ; bottes/stats l'augmentent).
var move_speed_mult := 1.0
## Le joueur est-il en voyage rapide (carte) ? — pour l'UI de la carte.
func is_traveling() -> bool:
	return _camera.has_method("is_traveling") and _camera.is_traveling()


func fast_travel_to_world(wx: int, wz: int) -> void:
	var from: Vector3 = _camera.global_position
	var dist := Vector2(float(wx) - from.x, float(wz) - from.z).length()
	var ticks := int(round(dist * MAP_TRAVEL_TICKS_PER_BLOCK / maxf(move_speed_mult, 0.1)))
	_camera.travel_to(wx, wz, ticks)


## Pose le joueur À LA SURFACE en (wx, wz), instantanément. Utilisé par la
## carte du monde, qui gère elle-même l'écoulement du temps du trajet : le
## voyage animé (fast_travel_to_world) pousserait ses propres ticks et
## compterait le temps DEUX FOIS.
func teleport_to_surface(wx: int, wz: int) -> void:
	var h := 24.0
	if WorldManager.generator != null:
		h = float(WorldManager.generator.height_at(wx, wz))
	teleport_to(Vector3(float(wx) + 0.5, h + 2.9, float(wz) + 0.5))


## Téléportation générique (DungeonManager : entrée/sortie de donjon).
func teleport_to(pos: Vector3, yaw_degrees: float = NAN) -> void:
	_camera.teleport_to(pos, yaw_degrees)


## Molette : change l'emplacement sélectionné ; Ctrl+molette : change de
## banque de hotbar (2026-07-27 : Ctrl remplace Shift).
func _scroll_hotbar(delta: int, bank_modifier: bool) -> void:
	if bank_modifier:
		active_hotbar = wrapi(active_hotbar + delta, 0, hotbar_bank_count())
	else:
		selected_slot = wrapi(selected_slot + delta, 0, HOTBAR_SLOTS)


func _process(delta: float) -> void:
	# Visée + fantôme + overlays : visuel uniquement, la récolte avance en ticks (E.1).
	_update_target()
	_update_ghost()
	_update_mining_overlay()
	# EXCEPTION ASSUMÉE À E.1 (2026-07-28) : le TIMING de la frappe et sa
	# géométrie avancent à la frame — une fenêtre de parade de 150 ms n'existe
	# pas à 10 Hz. _advance_attack ne modifie aucun état de jeu : il empile des
	# coups que _on_tick applique. Voir l'en-tête de MeleeAttack.
	if not input_locked:
		_measure_velocity(delta)
		_update_guard_direction(delta)
		_advance_attack(delta)


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


## Le clic gauche doit-il frapper plutôt que miner ? Une arme en main met le
## joueur en posture de combat ; à mains nues il continue de miner, sauf si une
## créature est effectivement devant lui — sinon on ne pourrait plus jamais
## boxer, ce qui condamnerait tout le début de partie sans équipement.
func _wants_combat() -> bool:
	if not _equipped_weapon().is_empty():
		return true
	return _target_creature != null and is_instance_valid(_target_creature)


## Fonctionnalité + stats dérivées de l'arme en main. Le cache est invalidé par
## une CLÉ d'arme (instance + fonctionnalité) : dériver à chaque frappe serait
## inutile, et à chaque frame franchement coûteux.
func _current_weapon_stats() -> Dictionary:
	var weapon := _equipped_weapon()
	var functionality_id := "mains_nues"
	if not weapon.is_empty():
		functionality_id = String(weapon["functionality"])
	var key := "%s:%d" % [functionality_id, int(weapon.get("uid", 0))]
	if key != _weapon_stats_key:
		_weapon_stats_key = key
		_weapon_stats = WeaponStats.derive(GameData.functionalities[functionality_id], weapon)
	return _weapon_stats


func _begin_attack() -> void:
	if _attack.is_busy() or _guard_active:
		return
	var weapon_stats := _current_weapon_stats()
	# Sans endurance, on ne lance pas de coup : c'est le frein qui empêche le
	# clic frénétique que tout ce système cherche à remplacer.
	if stamina < float(weapon_stats["stamina_cost"]):
		return
	_mining = false
	_progress = 0.0
	# Stats FIGÉES pour toute la durée de la frappe. Sans ça, changer d'arme
	# en plein swing rallongerait la portée du coup déjà parti (et truquerait
	# sa dureté à la résolution) : le joueur pourrait lancer une dague et
	# toucher à la portée d'une pique.
	var weapon := _equipped_weapon()
	_swing_basis = _camera.global_basis
	_swing_stats = weapon_stats.duplicate()
	_swing_hardness = float(weapon.get("base_hardness", 1.0)) if not weapon.is_empty() else 1.0
	_swing_quality = float(weapon.get("quality", 1.0)) if not weapon.is_empty() else 1.0
	_attack.begin(weapon_stats)


## Direction de la garde (blocage DIRECTIONNEL, 2026-07-28). Choisie au geste
## comme une attaque, et modifiable tant que la garde est tenue : le duel est un
## échange de lectures, pas un bouton de défense.
var _guard_direction: int = MeleeAttack.Direction.ESTOC
var _guard_gesture := Vector2.ZERO
## La direction de garde est-elle figée ? Elle l'est dès la fin de la fenêtre de
## lecture, et le reste jusqu'à ce qu'on baisse la garde.
##
## SYMÉTRIE VOULUE AVEC L'ATTAQUE (2026-08-01, demande de l'auteur). La garde
## suivait auparavant la souris en continu : elle se réorientait donc toute
## seule dès qu'on tournait la tête pour suivre un adversaire, et il était
## impossible de tenir une garde haute en regardant les pieds. Surtout, une
## défense qui se replace en permanence n'est plus un pari — or c'est le pari
## qui fait le duel. Pour changer de garde, on baisse et on relève : ça coûte
## le temps de la lecture, et c'est exactement le risque qu'on doit prendre.
var _guard_locked := false
## Temps écoulé (ms) depuis la levée de garde, CUMULÉ DEPUIS LE DELTA et non lu
## sur l'horloge murale.
##
## Distinct de `_guard_raised_msec`, qui sert à la fenêtre de PARADE parfaite :
## les deux durées n'ont ni la même valeur ni le même rôle, et les confondre
## ferait dépendre la qualité d'une parade de la lecture du geste.
##
## Pourquoi le delta plutôt que Time.get_ticks_msec() : tout le reste du combat
## avance au delta (MeleeAttack en entier), et mélanger les deux sources rend le
## système intestable — une sonde qui simule 300 ms en avançant le delta voyait
## l'horloge murale n'avancer que d'une milliseconde, donc la fenêtre de lecture
## ne se fermait jamais. Un système dont on ne peut pas simuler le temps ne peut
## pas être vérifié.
var _guard_read_ms := 0.0


func _set_guard(active: bool) -> void:
	if active and _attack.is_busy():
		# FEINTE : lever sa garde ANNULE une attaque en préparation. C'est le
		# geste central de Mount & Blade — armer un coup pour appâter une parade,
		# l'annuler, puis frapper ailleurs. Une frappe déjà PARTIE, elle, ne
		# s'annule pas : on assume son coup.
		if _attack.state == MeleeAttack.State.RELEASE:
			return
		_attack.interrupt()
		_swing_stats = {}
	if active and not _guard_active:
		_guard_raised_msec = Time.get_ticks_msec()
		_guard_read_ms = 0.0
		_guard_gesture = Vector2.ZERO
		_guard_locked = false
	if not active:
		_guard_locked = false
	_guard_active = active


## Lit le geste de garde pendant la fenêtre d'ouverture, puis VERROUILLE la
## direction. Même déroulé que l'attaque, mêmes constantes : le joueur n'a
## qu'un seul geste à apprendre pour attaquer et pour parer.
func _update_guard_direction(delta: float) -> void:
	if not _guard_active or _guard_locked:
		return
	_guard_gesture = _guard_gesture.move_toward(Vector2.ZERO,
		_guard_gesture.length() * minf(MeleeAttack.GESTURE_DECAY_PER_SEC * delta, 1.0))
	_guard_read_ms += delta * 1000.0
	if _guard_read_ms < MeleeAttack.GESTURE_MS:
		return
	# Fin de la lecture : on fige. Un geste trop faible laisse la garde au
	# CENTRE (estoc), comme un clic sans geste donne un estoc — la posture la
	# plus neutre est toujours celle qu'on obtient sans rien demander.
	_guard_direction = MeleeAttack.Direction.ESTOC
	if _guard_gesture.length() >= MeleeAttack.GESTURE_THRESHOLD:
		_guard_direction = MeleeAttack._resolve_direction(_guard_gesture)
	_guard_locked = true


## État de combat pour l'AFFICHAGE (indicateur directionnel du HUD).
##
## Le combat était mécaniquement complet mais ILLISIBLE : le joueur ne voyait
## ni la direction qu'il avait choisie, ni la phase où en était son coup, ni
## sa garde (retour utilisateur du 2026-07-28). Un combat directionnel dont on
## ne peut pas lire la direction n'est pas un combat directionnel.
func combat_hud_state() -> Dictionary:
	return {
		"phase": _attack.state,
		"attack_direction": _attack.direction,
		"phase_ratio": _attack.phase_ratio,
		"guarding": _guard_active,
		"guard_direction": _guard_direction,
		"guard_locked": _guard_locked,
		"stamina": stamina / maxf(stamina_max, 0.001),
	}


## Position de main d'une GARDE TENUE, dans la direction choisie.
##
## POURQUOI LA GARDE A UNE POSE. Elle n'en avait aucune : le bras restait au
## port d'arme, identique à l'inactivité. Le joueur ne voyait donc ni qu'il
## gardait, ni de quel côté — et l'adversaire non plus, ce qui vidait le
## blocage directionnel de son sens dans un duel joueur contre joueur.
##
## La main se place au DÉBUT de l'arc de la direction couverte, à mi-chemin du
## port d'arme : c'est la même géométrie que l'attaque, donc une garde haute
## ressemble à un coup haut armé — et c'est exactement ce qu'il faut, puisque
## dans les deux cas l'arme protège ce côté-là.
##
## `guard_for` traduit la direction de garde vers l'attaque qu'elle couvre : les
## tailles sont MIROIR (parer à gauche arrête un coup venu de la droite), l'estoc
## et le coup haut se couvrent eux-mêmes.
const GUARD_ARC_BLEND := 0.72


func _guard_hand_target(grip: Vector3, camera_basis: Basis, hand_radius: float) -> Vector3:
	var carry := grip + _carry_direction(camera_basis) * hand_radius
	var covered := MeleeAttack.guard_for(_guard_direction)
	var arc_start := MeleeAttack.tip_position(covered, 0.0, grip, camera_basis, hand_radius)
	# Une garde en cours de LECTURE reste au port : tant que la direction n'est
	# pas figée, montrer une posture serait annoncer un choix qui n'est pas fait.
	if not _guard_locked:
		return carry
	return carry.lerp(arc_start, GUARD_ARC_BLEND)


## Le bouclier ÉQUIPÉ (main gauche), ou {} si les mains sont libres.
##
## Le bouclier ne se tient pas dans la hotbar comme une arme : il est ÉQUIPÉ,
## donc porté en permanence dès qu'il est mis. C'est ce qui permet de garder au
## bouclier tout en tenant n'importe quelle arme à une main, sans manipulation.
func equipped_shield() -> Dictionary:
	var piece: Dictionary = equipment.equipped("arme_2")
	if piece.is_empty():
		return {}
	var item: Dictionary = GameData.items.get(piece.get("item_id", ""), {})
	if String(item.get("type", "")) != "bouclier":
		return {}
	return piece


## Caractéristiques défensives du bouclier porté : couverture et absorption.
## Retourne des valeurs NULLES sans bouclier, pour que l'appelant n'ait jamais à
## tester la présence d'un bouclier avant de lire ses chiffres.
func shield_profile() -> Dictionary:
	var shield := equipped_shield()
	# UNE ARME À DEUX MAINS INTERDIT LE BOUCLIER, et c'est le bouclier qui cède
	# — pas l'arme. Autrement il suffirait d'équiper un pavois pour ajouter de
	# la défense à un espadon sans rien sacrifier, ce qui supprimerait le choix
	# même que le GDD veut poser (5.6 : deux mains OU bouclier OU deux armes).
	# Le bouclier reste équipé, simplement inopérant : le retirer de force
	# surprendrait le joueur au changement d'arme.
	if int(_current_weapon_stats().get("hands", 1)) >= 2:
		return {"present": false, "couverture": 0, "absorption": 0.0, "quality": 1.0,
			"empeche_par_deux_mains": true}
	if shield.is_empty():
		return {"present": false, "couverture": 0, "absorption": 0.0, "quality": 1.0}
	var functionality: Dictionary = GameData.functionalities.get(
		shield.get("functionality", ""), {})
	# La qualité de fabrication porte l'absorption : un pavois bâclé protège
	# moins bien qu'un écu de maître, sinon seule la taille compterait et le
	# craft n'aurait aucun effet sur la défense.
	var quality := clampf(float(shield.get("quality", 1.0)), 0.2, 3.0)
	return {
		"present": true,
		"couverture": int(functionality.get("couverture", 0)),
		"absorption": clampf(float(functionality.get("absorption", 0.0))
			* (0.7 + 0.3 * quality), 0.0, 0.9),
		"quality": quality,
	}


## La garde couvre-t-elle une attaque venant de `attack_direction` ?
## Un BOUCLIER élargit la couverture aux directions VOISINES : avec un écu,
## garder en haut arrête aussi les tailles. C'est le sens même du bouclier —
## il protège une zone, là où une arme ne pare qu'une ligne. En contrepartie
## il occupe la main gauche, donc interdit les armes à deux mains.
func guard_covers(attack_direction: int) -> bool:
	if not _guard_active:
		return false
	var needed := MeleeAttack.guard_for(attack_direction)
	if _guard_direction == needed:
		return true
	var profile := shield_profile()
	if int(profile["couverture"]) <= 0:
		return false
	return needed in MeleeAttack.adjacent_guards(_guard_direction)


## CHAMBERING : le joueur pare-t-il en ATTAQUANT dans la même direction que le
## coup qui arrive ? Les deux armes s'entrechoquent, l'attaque adverse est
## annulée et la sienne continue — c'est le geste le plus exigeant de Mount &
## Blade, et le plus gratifiant.
##
## LA FENÊTRE EST LA PHASE DE WIND-UP, et c'est volontaire : elle n'est pas un
## nombre arbitraire mais la durée d'armement de l'arme tenue. Une dague donne
## donc une fenêtre serrée, un marteau une fenêtre large — le chambering hérite
## automatiquement du poids, sans constante à régler. Trop tôt et l'arme est
## déjà ARMÉE ; trop tard et elle n'est pas partie.
func is_chambering(incoming_direction: int) -> bool:
	return _attack.is_busy() \
		and _attack.state == MeleeAttack.State.WINDUP \
		and _attack.direction == incoming_direction


## Le joueur pare-t-il ce coup, et l'a-t-il levé DANS la fenêtre de parade ?
## Retourne { "guarding": bool, "parry": bool }. La parade « parfaite »
## (garde levée juste avant l'impact) est ce qui distingue une réaction d'une
## garde tenue passivement — c'est elle qui devra, plus tard, renvoyer le
## stagger à l'attaquant.
func guard_state() -> Dictionary:
	if not _guard_active:
		return {"guarding": false, "parry": false, "direction": _guard_direction}
	var window: float = float(_current_weapon_stats().get("parry_window_ms", 200.0))
	var held := float(Time.get_ticks_msec() - _guard_raised_msec)
	return {"guarding": true, "parry": held <= window,
		"direction": _guard_direction}


# --- Balayage de lame (frame) ---

## Hauteur de la PRISE de l'arme sous l'œil : la main n'est pas dans la tête,
## elle tient l'arme à hauteur de poitrine.
##
## CE N'EST PAS COSMÉTIQUE — deux défauts réels trouvés par --probe-combat le
## 2026-07-28, dans cet ordre :
##
## 1. Prise posée SUR la caméra : une frappe à l'horizontale contre un
##    humanoïde de même taille touchait sa TÊTE. Le ×2.5 devenait l'ordinaire
##    au lieu d'être la récompense d'une visée. D'où l'abaissement.
##
## 2. Prise décalée LATÉRALEMENT (vers la main droite) : l'estoc partait alors
##    parallèlement à l'axe de visée mais à 25 cm sur le côté, et manquait la
##    tête — dont la boîte ne fait que 24 cm de demi-largeur. Un joueur visant
##    parfaitement ratait, ce qui rompt la seule promesse d'un combat
##    directionnel : ce qu'on vise, on le touche.
##
## La pointe reste donc SUR L'AXE DE VISÉE, simplement abaissée. Le décalage
## latéral de la main est une affaire d'affichage (position du bras), pas de
## hitbox — il reviendra avec le corps visible, sur le rendu uniquement.
## 0,70 et non 0,45 (corrigé le 2026-07-28 sur captures) : à 45 cm sous l'œil,
## la prise plaçait bras et arme À 38 CM DE L'OBJECTIF. Ils remplissaient
## l'écran de grandes surfaces plates dès qu'on baissait le regard — ce qui se
## lisait comme un modèle cassé alors que la géométrie était juste. L'arme se
## tient à hauteur de taille, comme une garde basse.
## Vérifié après changement : une frappe à plat touche toujours le TORSE et il
## faut viser haut pour la tête (--probe-combat).
## 0,55 : compromis final apres captures. A 0,45 les bras bouchaient la vue ;
## a 0,70 l'arme assemblee (desormais un vrai modele de 1,4 a 2,2 blocs)
## sortait par le bas du cadre. VALEUR DE CADRAGE — a affiner a l'oeil,
## aucune sonde ne juge cela.
## 0,62 (2026-07-31) : le bras coupait encore le reticule en diagonale. Abaisser
## la prise le fait passer SOUS la ligne de visee, la ou un jeu a la premiere
## personne pose l'arme. Combine a HAND_ARC_RADIUS 0,72, le bras degage le
## centre de l'ecran.
const GRIP_DOWN := 0.62


## Décalage vertical pris sur l'axe du MONDE, pas sur celui de la caméra : la
## main est à hauteur de taille, et une taille ne monte pas quand on lève les
## yeux. Avec l'axe caméra, baisser le regard faisait basculer la prise vers
## l'avant en même temps que la tête (2026-07-28).
## Decalage LATERAL de la prise (demande du 2026-07-28 : « l'arme plus centree,
## visible a droite de l'ecran en etant debout »). Applique a la fois a la main
## ET a l'origine de l'arc, donc au balayage qui touche : l'arme reste ou on la
## voit. J'avais retire ce decalage plus tot parce qu'a 25 cm l'estoc manquait
## la tete (24 cm de demi-largeur) ; 0,16 le rend visible sans casser la visee,
## et --probe-combat le verifie (frappe a plat -> torse, visee haute -> tete).
const GRIP_RIGHT := 0.16


func _grip_position(camera_basis: Basis) -> Vector3:
	var right := camera_basis.x
	right.y = 0.0
	if right.length_squared() > 0.000001:
		right = right.normalized()
	return _camera.global_position - Vector3.UP * GRIP_DOWN + right * GRIP_RIGHT


## Direction de PORT de l'arme au repos : le lacet du regard, mais seulement
## une fraction de son tangage.
##
## 1.0 = les bras suivent INTÉGRALEMENT la vue (demande explicite du
## 2026-07-28). J'avais d'abord mis 0.35 pour dégager le champ quand on baisse
## le regard ; l'arbitrage de l'auteur est que l'arme doit rester en face de
## la visée en permanence, ce qui est aussi la convention des jeux à la
## première personne. Le champ est dégagé autrement : seuls les jambes et les
## bras réellement utilisés sont affichés (voir PlayerBody).
const CARRY_PITCH_RATIO := 1.0


func _carry_direction(camera_basis: Basis) -> Vector3:
	var forward := -camera_basis.z
	forward.y *= CARRY_PITCH_RATIO
	if forward.length_squared() < 0.000001:
		return -camera_basis.z
	return forward.normalized()


## Direction de l'ARME en espace monde : de la prise vers la cible de main.
##
## C'est LA MÊME géométrie que l'arc de frappe, donc l'arme pointe exactement
## le long du chemin que la lame va parcourir. Au repos elle vise devant ; en
## plein swing elle suit l'arc. Aucune chance qu'elle montre une direction et
## frappe dans une autre.
var _weapon_direction := Vector3.FORWARD


func weapon_direction() -> Vector3:
	return _weapon_direction


## Cibles des MAINS pour l'IK des bras, en espace monde :
##   { "droite": Vector3, "gauche": Vector3 (absent si arme à une main) }
##
## La main décrit LE MÊME ARC que la pointe de l'arme, simplement à un rayon
## beaucoup plus court — c'est la même fonction `MeleeAttack.tip_position` qui
## produit les deux. Conséquence voulue : le geste que le joueur VOIT et le
## balayage qui TOUCHE sont la même courbe, par construction. Un visuel qui
## mentirait sur la hitbox est la faute la plus grave d'un combat directionnel.
# --- Inertie de l'arme (ressort amorti) ----------------------------------

## DÉCALAGE lissé de la main PAR RAPPORT À LA CAMÉRA, et sa vitesse.
##
## RELATIF ET NON ABSOLU (corrigé le 2026-07-28 : « en marchant les bras
## traînent beaucoup trop, on marche en avant les bras sont en arrière »).
## Le ressort suivait une cible en espace MONDE : en translation, il accusait
## donc un retard PERMANENT de `v × amortissement / raideur` — pour une épée,
## 4,3 m/s × 10,7 / 75 ≈ 0,61 m. Le bras restait 60 cm derrière le corps tant
## qu'on avançait, et partait à gauche quand on se déplaçait à droite.
##
## En lissant le DÉCALAGE à la caméra plutôt que la position absolue :
##   - se DÉPLACER emporte la main avec le corps, sans aucun retard — un bras
##     ne reste pas en arrière parce qu'on marche ;
##   - TOURNER et FRAPPER produisent toujours le ballant voulu, puisque c'est
##     le décalage lui-même qui change.
## L'inertie mesure désormais le mouvement RELATIF du bras, qui est le seul
## qui doit peser.
var _hand_smoothed := Vector3.ZERO
var _hand_velocity := Vector3.ZERO
var _hand_initialised := false
## Décalage de retard de la frame courante, réutilisé pour faire traîner la
## POINTE davantage que la main : le bout d'une arme longue accuse plus le
## retard que le poing, c'est ce qui donne le fouetté d'un coup lourd.
var _lag_offset := Vector3.ZERO
## Vitesse du joueur, mesuree a la frame : alimente le BONUS DE VITESSE.
var _player_velocity := Vector3.ZERO
var _last_camera_position := Vector3.ZERO
var _velocity_initialised := false
const TIP_LAG_FACTOR := 2.2
## Borne du pas d'intégration : à 5 fps un ressort raide explose. On préfère un
## lissage temporairement mou à un bras qui part à l'infini.
const MAX_INERTIA_STEP := 1.0 / 30.0


## Tire la main vers `target` par un ressort amorti et retourne la position
## lissée. Intégration semi-implicite : stable et deux lignes.
func _integrate_hand_inertia(target: Vector3, delta: float, stats: Dictionary) -> Vector3:
	# Origine MOBILE : tout est exprimé relativement à la caméra, donc la
	# translation du corps n'entre jamais dans le ressort.
	var origin := _camera.global_position
	var target_offset := target - origin
	if not _hand_initialised:
		_hand_initialised = true
		_hand_smoothed = target_offset
		_hand_velocity = Vector3.ZERO
	var step := minf(delta, MAX_INERTIA_STEP)
	var stiffness := float(stats.get("inertia_stiffness", 200.0))
	var damping := float(stats.get("inertia_damping", 20.0))
	var acceleration := (target_offset - _hand_smoothed) * stiffness - _hand_velocity * damping
	_hand_velocity += acceleration * step
	_hand_smoothed += _hand_velocity * step
	_lag_offset = _hand_smoothed - target_offset
	return origin + _hand_smoothed


func hand_targets(hand_radius: float, offhand_offset: float, delta: float) -> Dictionary:
	if _camera == null:
		return {}
	var camera_basis := _camera.global_basis
	var grip := _grip_position(camera_basis)
	var carry := grip + _carry_direction(camera_basis) * hand_radius
	var target := carry

	if _attack.is_busy() and not _swing_stats.is_empty():
		var direction := _attack.direction
		var arc_start := MeleeAttack.tip_position(direction, 0.0, grip, camera_basis, hand_radius)
		var arc_end := MeleeAttack.tip_position(direction, 1.0, grip, camera_basis, hand_radius)
		match _attack.state:
			MeleeAttack.State.WINDUP:
				# Armer : la main recule vers le DÉBUT de l'arc. C'est ce
				# mouvement que l'adversaire doit pouvoir lire (télégraphie).
				target = carry.lerp(arc_start, _attack.phase_ratio)
			MeleeAttack.State.ARMEE:
				# Garde ARMÉE tenue : la main reste au point d'armement aussi
				# longtemps que le joueur maintient le bouton. La posture est
				# la menace — c'est ce que l'adversaire lit.
				target = arc_start
			MeleeAttack.State.RELEASE:
				target = MeleeAttack.tip_position(direction, _attack.phase_ratio, grip, camera_basis, hand_radius)
			MeleeAttack.State.RECOVERY:
				target = arc_end.lerp(carry, _attack.phase_ratio)
			_:
				target = carry
	elif _guard_active:
		target = _guard_hand_target(grip, camera_basis, hand_radius)

	var stats_for_inertia: Dictionary = _current_weapon_stats()
	if not _swing_stats.is_empty():
		stats_for_inertia = _swing_stats
	# INERTIE : la main est tiree vers sa cible, elle ne s'y colle pas.
	target = _integrate_hand_inertia(target, delta, stats_for_inertia)
	# L'arme pointe de la PRISE vers la main : le meme axe que l'arc.
	var axis_to_hand := target - grip
	if axis_to_hand.length_squared() > 0.000001:
		_weapon_direction = axis_to_hand.normalized()
	var targets := {"droite": target}
	# Arme à DEUX MAINS : la gauche se pose plus loin sur le manche. C'est la
	# « magie de la longueur du manche » du design — rien à animer, la position
	# de la seconde main se déduit de l'arme tenue.
	var stats: Dictionary = stats_for_inertia
	# ECART REEL entre les mains, deduit du MANCHE (WeaponStats) : c'est ce qui
	# donne des postures differentes selon l'arme sans rien animer. Une dague
	# n'ecarte pas les mains (0), une pique projette la gauche a plus d'un
	# metre devant le corps. `offhand_offset` ne sert plus que de repli pour
	# une arme sans pieces declarees.
	var separation := float(stats.get("hand_separation", 0.0))
	if separation <= 0.0 and int(stats.get("hands", 1)) >= 2:
		separation = offhand_offset
	if separation > 0.0:
		var axis := (target - grip)
		if axis.length_squared() > 0.000001:
			targets["gauche"] = grip + axis.normalized() * (hand_radius + separation)
	elif bool(shield_profile()["present"]):
		# BOUCLIER : la main gauche ne suit pas l'arme, elle porte la plaque
		# devant le buste. Elle se LÈVE en garde, ce qui rend le blocage visible
		# — sans quoi le joueur ne saurait pas si son bouclier est engagé, et
		# c'est pourtant lui qui décide s'il encaisse ou non.
		targets["gauche"] = _shield_hand_target(grip, camera_basis, hand_radius)
	return targets


## Décalage de la main au bouclier, en espace caméra : devant, à gauche, à
## hauteur de poitrine. Levé plus haut et plus au centre quand la garde est
## engagée.
## VALEURS DE CADRAGE, réglées sur captures. À 0,46 m devant l'œil, une plaque
## d'écu de 80 cm occupait la moitié de l'écran et masquait la cible : le
## bouclier protégeait littéralement le joueur de son propre jeu. On l'éloigne
## au bout du bras et on l'abaisse sous la ligne de visée, exactement comme la
## prise de l'arme (GRIP_DOWN).
const SHIELD_CARRY := Vector3(-0.40, -0.30, -0.80)
## En garde il REMONTE et se recentre — c'est ce mouvement, et lui seul, qui
## dit au joueur que son bouclier est engagé.
const SHIELD_GUARD := Vector3(-0.26, -0.05, -0.90)


func _shield_hand_target(grip: Vector3, camera_basis: Basis, hand_radius: float) -> Vector3:
	var offset := SHIELD_GUARD if (_guard_active and _guard_locked) else SHIELD_CARRY
	var forward := _carry_direction(camera_basis)
	var right := camera_basis.x
	right.y = 0.0
	if right.length_squared() > 0.000001:
		right = right.normalized()
	# `hand_radius` sert d'échelle : le bouclier reste à la même distance
	# relative que l'arme, sinon changer HAND_ARC_RADIUS décalerait l'un sans
	# l'autre et les deux mains cesseraient d'être cohérentes.
	var scaled := hand_radius / 0.72
	return grip + right * (offset.x * scaled) + Vector3.UP * (offset.y * scaled) 		+ forward * (-offset.z * scaled)

## Avance la frappe en cours et teste la géométrie. APPELÉ DEPUIS _process :
## c'est l'exception au tick documentée en tête de MeleeAttack. Cette fonction
## ne modifie AUCUN état de jeu — elle empile des coups constatés dans
## _pending_hits, que le tick appliquera.
## Vitesse du joueur, lissee. Brute elle serait bruitee par les micro-pas du
## controleur ; le bonus de vitesse sauterait alors d'une frame a l'autre.
func _measure_velocity(delta: float) -> void:
	if _camera == null or delta <= 0.0001:
		return
	if not _velocity_initialised:
		_velocity_initialised = true
		_last_camera_position = _camera.global_position
		return
	var instant := (_camera.global_position - _last_camera_position) / delta
	_last_camera_position = _camera.global_position
	_player_velocity = _player_velocity.lerp(instant, minf(delta * 12.0, 1.0))


func _advance_attack(delta: float) -> void:
	if not _attack.is_busy() or _camera == null or _swing_stats.is_empty():
		return
	var weapon_stats := _swing_stats
	var reach: float = float(weapon_stats["reach"])
	var event := _attack.advance(delta)
	# L'arc rattrape le regard a vitesse BORNEE (voir SWING_TURN_CAP).
	var aim := _camera.global_basis.get_rotation_quaternion()
	var current := _swing_basis.get_rotation_quaternion()
	var gap := current.angle_to(aim)
	if gap > 0.0001:
		var allowed := SWING_TURN_CAP * delta
		_swing_basis = Basis(current.slerp(aim, clampf(allowed / gap, 0.0, 1.0)))
	var camera_basis := _swing_basis
	var grip := _grip_position(camera_basis)

	if event == "locked":
		# Télégraphie (E.12) : la direction devient publique dès le
		# verrouillage, AVANT la frappe — c'est tout l'intérêt, l'adversaire
		# dispose du wind-up pour réagir. Émise UNE SEULE FOIS par attaque
		# depuis que la direction est verrouillée : elle ne peut plus changer,
		# donc l'annonce n'a plus à être corrigée.
		EventBus.attack_telegraphed.emit(self, MeleeAttack.direction_name(_attack.direction))
		return
	if event == "release":
		# Début de la phase dangereuse : origine du balayage, aucun test encore
		# (il n'y a pas de segment tant qu'on n'a pas une seconde position).
		_tip_previous = MeleeAttack.tip_position(_attack.direction, 0.0, grip, camera_basis, reach)
		# Le coup est PARTI : son coût en endurance est dû, qu'il touche ou
		# non. C'est la contrepartie qui rend le spacing intéressant — un coup
		# dans le vide se paie. La dépense elle-même est appliquée par le tick
		# (cette fonction ne modifie aucun état), d'où l'événement empilé.
		_pending_hits.append({"kind": "swing", "stats": weapon_stats})
		return
	if _attack.state != MeleeAttack.State.RELEASE or not _attack.can_still_hit:
		return

	# INERTIE appliquée à la POINTE, amplifiée : le bout d'une arme accuse le
	# retard plus que le poing, et c'est ce décalage qui fait « fouetter » un
	# coup lourd. Le décalage vient du ressort de la main (`_lag_offset`), donc
	# le VISUEL et la HITBOX traînent exactement pareil — l'invariant du système
	# tient aussi pour l'inertie.
	var tip := MeleeAttack.tip_position(_attack.direction, _attack.phase_ratio, grip, camera_basis, reach) \
		+ _lag_offset * TIP_LAG_FACTOR
	var segment_from := _tip_previous
	_tip_previous = tip

	var span := tip - segment_from
	var span_length := span.length()
	# Le décor arrête la lame. Sa distance est MESURÉE et comparée à celle de la
	# créature plus bas : couper d'office annulait un coup dont le mur était en
	# réalité DERRIÈRE la cible (corrigé le 2026-07-28).
	var wall_distance := INF
	if span_length > 0.0001:
		var wall := _raycast_voxel(segment_from, span / span_length, span_length)
		if wall.has("pos"):
			wall_distance = segment_from.distance_to(wall.get("point", tip))

	var best: Node = null
	var best_hit: Dictionary = {}
	for creature in CreatureManager.creatures:
		if not is_instance_valid(creature) or creature.is_dead():
			continue
		if creature.dimension != WorldManager.active_dimension:
			continue
		# Rejet grossier avant le test exact : la distance au point de prise
		# élimine presque tout le monde pour le prix d'une soustraction.
		if creature.logical_position.distance_squared_to(grip) > (reach + 2.0) * (reach + 2.0):
			continue
		var hit: Dictionary = creature.sweep_segment(segment_from, tip)
		if hit.is_empty():
			continue
		if best_hit.is_empty() or float(hit["t"]) < float(best_hit["t"]):
			best_hit = hit
			best = creature
	if best == null:
		# Rien touché, mais un mur a arrêté la lame : la frappe est consommée.
		if wall_distance < INF:
			_attack.can_still_hit = false
		return
	# Le mur est-il AVANT la cible ? Alors la lame s'y arrête et n'atteint
	# personne. Sinon il est derrière, et n'a rien à dire.
	var creature_distance := segment_from.distance_to(best_hit["point"])
	if wall_distance < creature_distance:
		_attack.can_still_hit = false
		return

	# SWEET SPOT : on ne blesse qu'avec la partie tranchante. Frapper au manche
	# GLISSE et ne fait rien — c'est ce qui punit d'être trop près avec une arme
	# longue, et ce qui donne aux armes courtes leur raison d'être.
	var impact_distance: float = grip.distance_to(best_hit["point"])
	var sweet := WeaponStats.sweet_spot_factor(impact_distance, reach)
	if sweet <= 0.001:
		# Coup GLISSANT : la frappe est consommée, aucun dégât. Il faut savoir
		# qu'on s'est trompé de distance, pas croire qu'on a raté sa visée.
		_attack.can_still_hit = false
		_pending_hits.append({"kind": "glisse", "stats": weapon_stats})
		return

	# BONUS DE VITESSE : la vitesse RELATIVE de l'arme et de la cible décide.
	# Avancer en frappant fait mal, frapper en reculant fait peu. C'est ce qui
	# rend le jeu de jambes MÉCANIQUE et pas seulement positionnel.
	var strike_direction := span.normalized() if span_length > 0.0001 else Vector3.ZERO
	var nominal := span_length / maxf(delta, 0.0001)
	# Seule la vitesse du JOUEUR est prise en compte : les creatures avancent
	# par tick a 10 Hz, leur vitesse instantanee serait un escalier plutot
	# qu'une mesure. A brancher quand elles bougeront a la frame.
	var closing := _player_velocity.dot(strike_direction)
	var speed := WeaponStats.speed_factor(nominal, closing)

	# Un coup par frappe (les armes « transperçantes » lèveront cette règle).
	_attack.can_still_hit = false
	_pending_hits.append({
		"kind": "hit",
		"creature": best, "zone": best_hit["id"], "mult": float(best_hit["mult"]),
		"point": best_hit["point"], "stats": weapon_stats,
		"hardness": _swing_hardness, "quality": _swing_quality,
		"sweet": sweet, "speed": speed,
	})


## Applique les coups constatés à la frame. APPELÉ DEPUIS LE TICK : c'est ici,
## et seulement ici, que l'état du jeu change (dégâts, endurance, XP, mort).
func _resolve_pending_hits() -> void:
	if _pending_hits.is_empty():
		return
	for hit: Dictionary in _pending_hits:
		var weapon_stats: Dictionary = hit["stats"]
		# Un coup PARTI coûte son endurance, touché ou non — l'événement
		# "swing" est émis au départ de la lame, indépendamment du résultat.
		if String(hit["kind"]) == "swing":
			_spend_stamina(float(weapon_stats["stamina_cost"]))
			continue
		if String(hit["kind"]) == "glisse":
			# Coup GLISSANT (frappé au manche) : aucun dégât, mais l'information
			# doit remonter — c'est une erreur de DISTANCE, pas de visée, et le
			# joueur ne peut pas corriger ce qu'il ne perçoit pas.
			EventBus.ui_notification.emit("ui.combat.coup_glissant")
			EventBus.damage_dealt.emit(hit.get("point", Vector3.ZERO), 0, false, true)
			continue
		var creature: Node = hit["creature"]
		if not is_instance_valid(creature) or creature.is_dead():
			continue
		# Le multiplicateur de ZONE est combiné au SWEET SPOT et au BONUS DE
		# VITESSE : viser juste, à la bonne distance, en avançant. Les trois
		# piliers offensifs de Mount & Blade se multiplient au même endroit.
		var combined: float = float(hit["mult"]) \
			* float(hit.get("sweet", 1.0)) * float(hit.get("speed", 1.0))
		var result := CombatResolver.resolve_hit(
			effective_stat("dexterite"), effective_stat("force"),
			String(weapon_stats["dice"]),
			float(hit["hardness"]), float(hit["quality"]), false, "",
			combined, float(weapon_stats["penetration"]))
		creature.health = maxf(0.0, creature.health - result["damage"])
		# AU POINT D'IMPACT, pas au-dessus de la cible : c'est ce qui apprend
		# le sweet spot et les zones — on voit OÙ on a touché.
		EventBus.damage_dealt.emit(hit["point"], int(result["damage"]),
			bool(result["critical"]), false)
		creature.provoke()  # Une bête sauvage riposte dès le 1er coup (F.3).
		note_offence_against(creature, RELATION_ON_HIT)
		if String(creature.ai_profile) in ["civil", "garde"]:
			_check_law("agression", creature)
		_gain_combat_xp(weapon_stats, float(result["damage"]))
		if creature.is_dead():
			_creature_defeated(creature)
	_pending_hits.clear()


## Répartit l'XP d'un coup porté entre les compétences qu'il entraîne.
##
## Un coup n'entraîne pas UNE compétence mais trois axes qui progressent
## ensemble, et c'est ce qui rend la spécialisation vivable :
##
##   1. L'ARME elle-même. Depuis le 2026-08-01, chaque type d'arme a la sienne
##      (l'espadon ne fait plus monter « épée »). Sans les deux axes suivants,
##      ce découpage punirait durement le simple fait de changer d'arme.
##   2. Le TYPE DE DÉGÂTS. Tranchant, perçant, contondant progressent avec
##      n'importe quelle arme qui les inflige : passer de la hache à l'espadon
##      conserve donc l'acquis de tranchant. C'est le contrepoids exact du
##      point 1.
##   3. LE STYLE. Une arme à deux mains entraîne « Deux mains » (GDD 5.6).
##      Dual Wielding et Bouclier attendent leurs systèmes respectifs.
##
## L'XP n'est pas divisée entre les trois : chacun reçoit une FRACTION des
## dégâts. Diviser ferait qu'un joueur progresse plus lentement à mesure qu'on
## ajoute des axes, ce qui punirait la profondeur du système.
const XP_MASTERY_SHARE := 0.5
const XP_STYLE_SHARE := 0.35


func _gain_combat_xp(weapon_stats: Dictionary, damage: float) -> void:
	if damage <= 0.0:
		return
	skills.gain_xp(String(weapon_stats.get("skill", "mains_nues")), damage)
	var damage_type := String(weapon_stats.get("damage_type", ""))
	if GameData.skills.has(damage_type):
		skills.gain_xp(damage_type, damage * XP_MASTERY_SHARE)
	if int(weapon_stats.get("hands", 1)) >= 2:
		skills.gain_xp("deux_mains", damage * XP_STYLE_SHARE)


## Offre un objet de l'inventaire à la collection. L'objet est DÉTRUIT : c'est
## le prix de l'entrée, et toute la valeur du système (voir Collection).
##
## Retourne "" en cas de refus (objet introuvable, ou déjà représenté par un
## exemplaire au moins aussi bon), sinon la clé enregistrée. L'appelant affiche
## le retour : un don silencieusement refusé laisserait croire à une perte.
func donate_to_collection(uid: int) -> String:
	var instance := inventory.object_by_uid(uid)
	if instance.is_empty():
		return ""
	var key := collection.donate(instance)
	if key == "":
		return ""
	# LA DESTRUCTION SE FAIT ICI, et seulement après l'enregistrement réussi :
	# dans l'autre ordre, un refus tardif aurait détruit l'objet pour rien.
	inventory.remove_object_units(instance, 1)
	# Une liaison de hotbar qui pointe vers un objet disparu doit partir avec
	# lui, sinon l'emplacement affiche un fantôme jusqu'au prochain nettoyage.
	for index: int in hotbar_bindings.keys():
		var binding: Dictionary = hotbar_bindings[index]
		if String(binding.get("kind", "")) == "object" and int(binding.get("uid", -1)) == uid:
			hotbar_bindings.erase(index)
	EventBus.ui_notification.emit("ui.toast.collection_don")
	return key


## Perte de relation quand le joueur FRAPPE un civil, et quand il le TUE.
##
## Frapper coûte peu, tuer coûte cher et durablement : c'est ce qui rend un
## village hostile au bout de quelques meurtres (seuil −50, GDD 7.2) plutôt
## qu'au premier geste maladroit. Les chiffres sont une interprétation — le GDD
## nomme les facteurs (« méfaits ») sans les chiffrer.
const RELATION_ON_HIT := -4.0
const RELATION_ON_KILL := -35.0


## Enregistre un méfait envers une créature. Sans effet sur une bête : agresser
## un loup n'est pas un crime, et compter un sanglier comme une victime ferait
## de la chasse un déshonneur.
func note_offence_against(creature: Node, amount: float) -> void:
	if creature == null or not is_instance_valid(creature):
		return
	if String(creature.ai_profile) not in ["civil", "garde"]:
		return
	reputation.record(String(creature.social_key), creature.village_cell,
		String(creature.race_id), amount, String(creature.kingdom_id))


## Confronte un acte aux LOIS du royaume où l'on se trouve (14.4/E.26).
##
## Trois conditions, dans cet ordre, et chacune peut tout arrêter :
##   1. être SUR un territoire — hors royaume, aucune loi ;
##   2. que ce royaume interdise cet acte — tous ne le font pas ;
##   3. qu'un TÉMOIN l'ait vu — c'est le principe central d'E.26, on ne
##      punit pas ce qui n'est pas vu.
##
## Un acte commis loin de tout regard ne laisse donc aucune trace, ce qui est
## voulu : c'est ce qui rend la Discrétion utile ailleurs que dans le vol, et
## ce qui permet de jouer un criminel plutôt que de subir un compteur de karma.
func _check_law(behaviour: String, subject: Node) -> void:
	if WorldManager.generator == null:
		return
	var kingdom: Dictionary = WorldManager.generator.kingdom_at_cell(current_cell())
	if kingdom.is_empty():
		return
	var law := KingdomLaws.law_for(kingdom, behaviour)
	if law.is_empty():
		return
	var place: Vector3 = subject.logical_position if subject != null 		else get_position_for_ai()
	# La VICTIME ne témoigne pas de sa propre mort : elle est retirée de la
	# liste. Sans ça, tout meurtre serait vu par le mort lui-même.
	var others: Array = []
	for creature: Variant in CreatureManager.creatures:
		if creature != subject:
			others.append(creature)
	if not KingdomLaws.is_witnessed(self, place, others):
		return
	var message := KingdomLaws.apply(String(law["consequence"]), self, kingdom)
	if message != "":
		EventBus.ui_notification.emit(message)


## Dépense d'endurance + blocage temporaire de la régénération.
func _spend_stamina(amount: float) -> void:
	stamina = maxf(0.0, stamina - amount)
	_stamina_regen_block = STAMINA_REGEN_DELAY_TICKS


## Régénération d'endurance, une passe par tick. Garde levée = régénération
## suspendue : tenir sa garde indéfiniment ne doit pas être gratuit, c'est ce
## qui force à choisir entre parer et reprendre son souffle.
func _stamina_tick() -> void:
	if _stamina_regen_block > 0:
		_stamina_regen_block -= 1
		return
	if _guard_active:
		return
	stamina = minf(stamina_max, stamina + STAMINA_REGEN_PER_TICK)


## Notifie la mort d'une créature (E.12) — le HUD écoute ce signal pour le
## toast localisé ; le nettoyage effectif (despawn) est fait par CreatureManager.
func _creature_defeated(creature: Node) -> void:
	# Tuer un civil est un MEURTRE : la sanction tombe avant le butin, pour
	# qu'elle s'applique même si la collecte échoue.
	note_offence_against(creature, RELATION_ON_KILL)
	_check_law("meurtre", creature)
	# La mort est aussi inscrite au REGISTRE DU VILLAGE : c'est ce qui empêche
	# l'habitant de réapparaître à la visite suivante. La réputation dit ce que
	# les gens pensent de vous, le registre dit qui n'est plus là.
	CreatureManager.call("_note_resident_death", creature)
	_collect_loot(creature)
	EventBus.creature_killed.emit(self, creature)


## Dépeçage (7.7 : « chaque créature droppe sa propre viande ») — viande et
## peau paramétriques de l'espèce (B.1/A.9.1), en quantité liée à sa
## corpulence. Va directement à l'inventaire : le joueur est sur place, une
## cache au sol serait une friction inutile. Les créatures amorphes (essaims,
## nuées) n'ont ni viande ni peau et ne donnent rien.
## Non implémenté : les parties d'alchimie (yeux, griffes, os — 7.7), les
## pools de loot F.7 et la statue 1:1 (F.3), qui attendent leurs systèmes.
func _collect_loot(creature: Node) -> void:
	var data: Dictionary = GameData.creatures.get(creature.creature_id, {})
	if data.is_empty() or "amorphe" in (data.get("tags", []) as Array):
		return
	var sante := float((data.get("base_stats", {}) as Dictionary).get("sante", 10))
	var portions := maxi(1, int(round(sante / 12.0)))
	var gained := {}
	for prefix: String in ["viande_de_", "peau_de_"]:
		var resource_id: String = prefix + String(creature.creature_id)
		if not GameData.resources.has(resource_id):
			continue
		var amount := portions if prefix == "viande_de_" else maxi(1, portions / 2)
		# Instances d'objet (comme les armes), pas des piles de matériau :
		# viandes et peaux ne sont pas des blocs (décision 2026-07-27).
		inventory.add_object(ItemFactory.resource_instance(resource_id, amount))
		gained[resource_id] = amount
	if gained.is_empty():
		return
	skills.gain_xp("collecte", float(portions) * 2.0)
	autofill_hotbar()
	EventBus.ui_notification.emit(tr("ui.toast.depecage").format({
		"creature": tr(String(data.get("name_key", ""))),
		"portions": str(portions)}))


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
		_target_creature.provoke()
		if _target_creature.is_dead():
			_creature_defeated(_target_creature)


# --- Récolte (A.2, par ticks) ---

func _on_tick(_tick_index: int) -> void:
	mana.on_tick()
	hunger = maxf(0.0, hunger - HUNGER_DECAY_PER_TICK)
	fatigue = maxf(0.0, fatigue - FATIGUE_DECAY_PER_TICK)
	_hunger_tick_effects()
	_stamina_tick()
	# Application des coups constatés par la géométrie depuis le tick
	# précédent. C'est la frontière frame → tick : le seul endroit où une
	# frappe change réellement l'état du jeu.
	_resolve_pending_hits()
	if input_locked:
		# Carte du monde ouverte (ou bench) : pas de minage/attaque en arrière-plan.
		_mining = false
		_attack.interrupt()
		_guard_active = false
		return
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
	# Blocs INCASSABLES (tour de donjon) : aucun outil n'en vient à bout.
	# Un simple `durete` très élevée ne suffirait pas — la progression sans
	# plafond (A.1) finirait par produire un outil capable de la percer.
	if "incassable" in (mat.get("tags", []) as Array):
		_bouncing = true
		_progress = 0.0
		return
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
# (molette : emplacement · Ctrl+molette ou Ctrl+1-9 : banque)

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


## Nombre de banques : au moins HOTBAR_MIN_BANKS, et assez pour couvrir la
## plus haute liaison posée.
func hotbar_bank_count() -> int:
	var highest := 0
	for index: int in hotbar_bindings:
		highest = maxi(highest, index / HOTBAR_SLOTS + 1)
	return maxi(HOTBAR_MIN_BANKS, highest)


## Assigne l'entrée `entry` (issue de all_entries) à l'emplacement absolu
## `index`. Une entrée déjà liée ailleurs est DÉPLACÉE — sans ça le même
## objet occuperait deux emplacements et l'un des deux mentirait.
func bind_hotbar(index: int, entry: Dictionary) -> void:
	var binding := _binding_for(entry)
	if binding.is_empty():
		return
	for existing: int in hotbar_bindings.keys():
		if hotbar_bindings[existing] == binding:
			hotbar_bindings.erase(existing)
	hotbar_bindings[index] = binding


func unbind_hotbar(index: int) -> void:
	hotbar_bindings.erase(index)


## Emplacement absolu occupé par `entry`, ou -1.
func hotbar_index_of(entry: Dictionary) -> int:
	var binding := _binding_for(entry)
	if binding.is_empty():
		return -1
	for index: int in hotbar_bindings:
		if hotbar_bindings[index] == binding:
			return index
	return -1


func _binding_for(entry: Dictionary) -> Dictionary:
	match entry.get("kind", ""):
		"material":
			return {"kind": "material", "id": String(entry.get("id", ""))}
		"object":
			var uid := int((entry.get("object", {}) as Dictionary).get("uid", -1))
			if uid >= 0:
				return {"kind": "object", "uid": uid}
	return {}


## Entrée d'inventaire visée par une liaison, ou {} si la cible n'existe plus
## (matériau épuisé, objet consommé ou déposé).
func _resolve_binding(binding: Dictionary) -> Dictionary:
	match String(binding.get("kind", "")):
		"material":
			var id := String(binding.get("id", ""))
			var volume := inventory.total_volume(id)
			if volume <= 0.0001:
				return {}
			return {"kind": "material", "id": id,
				"count": int(inventory.material_stacks.get(id, 0)), "volume": volume}
		"object":
			var obj := inventory.object_by_uid(int(binding.get("uid", -1)))
			if obj.is_empty():
				return {}
			return {"kind": "object", "object": obj}
	return {}


## Les 9 emplacements de la banque `bank`, dans l'ordre. Un emplacement non
## lié (ou dont la cible a disparu) rend un dictionnaire VIDE — la hotbar
## affiche un trou, elle ne décale pas les objets suivants.
func hotbar_entries(bank: int = -1) -> Array[Dictionary]:
	var start := (active_hotbar if bank < 0 else bank) * HOTBAR_SLOTS
	var result: Array[Dictionary] = []
	for slot in HOTBAR_SLOTS:
		var binding: Variant = hotbar_bindings.get(start + slot)
		result.append(_resolve_binding(binding) if binding != null else {})
	return result


## Clé de nom localisée de l'objet/du matériau en main ("" si rien).
func held_name_key() -> String:
	var entry := _selected_entry()
	match entry.get("kind", ""):
		"object":
			return entry["object"]["name_key"]
		"material":
			return String(GameData.stackable(entry["id"]).get("name_key", ""))
	return ""


## Entrée sélectionnée (API publique — vue première personne, UI).
func held_entry() -> Dictionary:
	return _selected_entry()


func _selected_entry() -> Dictionary:
	var binding: Variant = hotbar_bindings.get(active_hotbar * HOTBAR_SLOTS + selected_slot)
	return _resolve_binding(binding) if binding != null else {}


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
	# Une RESSOURCE (viande, peau — 7.7) n'est pas un bloc : elle n'a pas d'id
	# runtime et ne peut pas exister dans le monde. Garde-fou explicite en plus
	# de l'absence d'id, pour que l'aperçu de pose ne s'affiche même pas.
	if not GameData.is_placeable(_selected_material()):
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
			"item": tr(String(GameData.stackable(mat_name).get("name_key", ""))), "prix": str(price)}))


## Ramasse la cache d'objets au sol la plus proche (A.10).
func _try_pickup() -> void:
	var index := DropManager.nearest_cache(get_position_for_ai())
	if index < 0:
		return
	var count: int = (DropManager.caches[index]["objects"] as Array).size()
	var recovered := DropManager.collect(index, inventory)
	gold += recovered
	EventBus.ui_notification.emit(tr("ui.toast.ramasse").format({
		"objets": str(count), "or": str(recovered)}))


## Crédite les bonus de potentiel d'un plat (A.9.1) :
##   potentiel_gagné(stat) = bonus * (nutrition / 100)
## La qualité du plat (A.3) n'entre pas encore en jeu : la cuisine ne produit
## pas de qualité variable pour l'instant, ce serait un facteur toujours égal
## à 1 — à brancher quand la qualité d'artisanat s'appliquera aux plats.
func _credit_potential(bonuses: Dictionary, nutrition: float) -> void:
	if bonuses.is_empty():
		return
	var credited := {}
	for stat_id: String in bonuses:
		var gain := float(bonuses[stat_id]) * (nutrition / 100.0)
		if gain <= 0.0:
			continue
		stat_potentials[stat_id] = minf(POTENTIAL_MAX,
				float(stat_potentials.get(stat_id, POTENTIAL_BASE)) + gain)
		credited[stat_id] = gain
	if credited.is_empty():
		return
	var parts: Array[String] = []
	for stat_id: String in credited:
		parts.append("%s +%.1f" % [tr("stat." + stat_id + ".name"), credited[stat_id]])
	EventBus.ui_notification.emit(tr("ui.toast.potentiel").format({
		"details": ", ".join(parts)}))


# --- Sommeil (E.21) ---

## Dort dans le LIT visé. Refuse hors de la nuit (rien à sauter) et sans lit
## à portée. Le temps sauté est réellement simulé, par paquets de ticks.
func _try_sleep() -> void:
	if not _target_valid:
		EventBus.ui_notification.emit("ui.toast.pas_de_lit")
		return
	var block_id := WorldManager.block_at_world(_target)
	if block_id == 0 or GameData.material_by_runtime[block_id] != "lit":
		EventBus.ui_notification.emit("ui.toast.pas_de_lit")
		return
	if not DayNightManager.is_night():
		EventBus.ui_notification.emit("ui.toast.pas_la_nuit")
		return

	var ticks := DayNightManager.ticks_until(DayNightManager.HOUR_DAWN)
	# Le lit sert aussi d'ancre de résurrection (A.10 : « dernier lit ou
	# claim activé ») — c'est le lit qui prime, il est plus précis.
	ClaimManager.respawn_cell = current_cell()
	ClaimManager.has_respawn = true

	var pushed := 0
	while pushed < ticks:
		var batch := mini(SLEEP_TICK_BATCH, ticks - pushed)
		TickManager.push_ticks(batch)
		pushed += batch
	# Régénération x4 pendant le sommeil (E.21) : appliquée en bloc sur la
	# durée dormie plutôt que tick par tick (le résultat est le même, sans
	# payer 8 000 passes de régénération).
	var regen := float(ticks) / float(HEALTH_REGEN_INTERVAL_TICKS) * HEALTH_REGEN_AMOUNT * 4.0
	health = minf(health_max, health + regen)
	rested_until_tick = TickManager.tick_index + RESTED_DURATION_TICKS
	fatigue = fatigue_max
	EventBus.ui_notification.emit("ui.toast.reveil")


## true tant que le buff « Reposé » court (E.21).
func is_rested() -> bool:
	return TickManager.tick_index < rested_until_tick


## Multiplicateur d'XP dû à l'état du personnage : bonus « Reposé » (+5 %,
## E.21) et malus de fatigue (-10 % sous 50). Les deux se composent.
func xp_state_multiplier() -> float:
	var factor := 1.0
	if is_rested():
		factor *= 1.0 + RESTED_XP_BONUS
	if fatigue < FATIGUE_TIRED:
		factor *= FATIGUE_XP_MALUS
	return factor


# --- Équipement (6.2 / A.4.2) ---

## Équipe l'objet EN MAIN, ou le retire s'il est déjà porté. La pièce
## remplacée retourne à l'inventaire — jamais de perte, jamais de doublon
## (l'instance est DÉPLACÉE, pas copiée).
func _try_equip() -> void:
	var entry := _selected_entry()
	if entry.get("kind", "") != "object":
		return
	var instance: Dictionary = entry["object"]
	var item: Dictionary = GameData.items.get(instance.get("item_id", ""), {})
	var slot := equipment.resolve_slot(String(item.get("equip_slot", "")))
	if slot == "":
		EventBus.ui_notification.emit("ui.toast.pas_equipable")
		return
	inventory.objects.erase(instance)
	var replaced := equipment.equip(instance)
	if not replaced.is_empty():
		inventory.add_object(replaced)
	_clamp_selection()
	EventBus.ui_notification.emit(tr("ui.toast.equipe").format({
		"item": tr(String(instance.get("name_key", "")))}))


## Retire la pièce de `slot` et la remet à l'inventaire (API pour l'UI).
func unequip_slot(slot: String) -> void:
	var instance := equipment.unequip(slot)
	if instance.is_empty():
		return
	inventory.add_object(instance)
	EventBus.ui_notification.emit(tr("ui.toast.desequipe").format({
		"item": tr(String(instance.get("name_key", "")))}))


## Les emplacements de hotbar sont FIXES depuis qu'ils sont assignés
## explicitement : retirer un objet vide son emplacement, il ne décale plus
## rien. Ne reste qu'à purger les liaisons devenues orphelines.
func _clamp_selection() -> void:
	for index: int in hotbar_bindings.keys():
		if _resolve_binding(hotbar_bindings[index]).is_empty():
			hotbar_bindings.erase(index)


## Capacité de port (A.4.2) — la charge compte l'inventaire ET l'équipement.
func carry_capacity() -> float:
	return Inventory.capacity_for(effective_stat("force"))


func carried_weight() -> float:
	return inventory.total_weight() + equipment.total_weight()


## Dés de réduction totaux du joueur, au format E.3 ("" = aucune armure).
func armor_dice() -> String:
	return equipment.total_armor_dice()


## Malus de défense dû au poids de l'équipement (A.4.2).
##
## ORPHELIN DEPUIS LE 2026-07-28 — À RÉAFFECTER, PAS À SUPPRIMER. Cette valeur
## n'alimentait que la « défense » de la formule à 1d20, disparue avec le
## passage au toucher géométrique. La pénalité de poids, elle, reste un besoin
## de design entier (A.4.2 « charge maximale », et le jeu de jambes du combat
## directionnel n'a de sens que si l'armure lourde le ralentit) : elle doit
## être rebranchée sur la VITESSE DE DÉPLACEMENT et la régénération
## d'endurance. Laissée en place volontairement pour que ce report soit
## visible plutôt que perdu dans un diff.
func armor_malus() -> int:
	return equipment.defense_malus(carry_capacity())


## Catégorie de matériau dominante de l'armure portée — décide de l'efficacité
## de la protection face au type de dégât reçu (2026-07-28).
func armor_category() -> String:
	return equipment.dominant_armor_category()


## Encaisse un coup en garde : l'endurance absorbe le drain de l'arme adverse.
## Retourne true si la garde a TENU, false si elle a cédé (endurance
## insuffisante → stagger, le coup passe en entier).
## Une parade dans la fenêtre (garde levée juste à temps) divise le drain par
## deux : c'est la récompense du timing, seule différence entre parer et
## simplement tenir son bouclier levé.
## Un BOUCLIER absorbe une fraction du drain avant l'endurance : c'est du bois
## et du métal qui encaissent à la place des bras. C'est là tout son intérêt —
## il ne rend pas invincible, il permet de TENIR plus longtemps, ce qui est la
## vraie monnaie d'un duel.
func absorb_on_guard(drain: float, parried: bool) -> bool:
	var cost := drain * (0.5 if parried else 1.0)
	var shield := shield_profile()
	if bool(shield["present"]):
		cost *= 1.0 - float(shield["absorption"])
		# Le bouclier progresse par l'USAGE, comme tout le reste (A.1) : ce qui
		# le fait monter, c'est d'encaisser, pas de le porter.
		skills.gain_xp("bouclier", drain * SHIELD_XP_SHARE)
	if stamina < cost:
		_spend_stamina(stamina)
		_guard_active = false   # Garde brisée : il faut la relever.
		_guard_locked = false
		_attack.interrupt()
		return false
	_spend_stamina(cost)
	return true


## Fraction du drain encaissé convertie en XP de bouclier. Assise sur le drain
## BRUT et non sur le coût final : sinon un bon bouclier, qui absorbe beaucoup,
## progresserait moins vite qu'un mauvais.
const SHIELD_XP_SHARE := 0.6


# --- Faim et nourriture (A.9 / A.9.1) ---

## Effets de seuil de la faim, une passe par tick (E.1) : régénération de
## santé modulée, puis famine à 0. La famine « ne tue pas en dessous de
## 1 PV » (A.9) — le clamp bas est donc à 1, pas à 0.
func _hunger_tick_effects() -> void:
	_regen_tick_counter += 1
	if _regen_tick_counter >= HEALTH_REGEN_INTERVAL_TICKS:
		_regen_tick_counter = 0
		if hunger >= HUNGER_STARVING and fatigue >= FATIGUE_EXHAUSTED and health < health_max:
			var regen := HEALTH_REGEN_AMOUNT
			if hunger < HUNGER_REGEN_PENALTY:
				regen *= 0.9
			if fatigue < FATIGUE_TIRED:
				regen *= 0.9
			health = minf(health_max, health + regen)
	if hunger > 0.0:
		_starve_tick_counter = 0
		return
	_starve_tick_counter += 1
	if _starve_tick_counter >= STARVE_INTERVAL_TICKS:
		_starve_tick_counter = 0
		# AMENDÉ le 2026-07-27 (demande de l'auteur) : la famine PEUT tuer.
		# A.9 disait « ne tue pas en dessous de 1 PV » ; la mort est
		# désormais possible, notamment en traversant la carte du monde sans
		# surveiller ses jauges. take_damage déclenche die() (A.10 : perte
		# d'or, objets tombés, réapparition à l'ancre) — jamais un game over.
		take_damage(int(ceil(health_max * STARVE_HEALTH_FRACTION)))


## Stat EFFECTIVE (A.9) : -10 % à toutes les stats sous 25 de faim. Toute
## lecture de stat destinée à une formule de gameplay doit passer par ici —
## `stats` reste la valeur de base (fiche de personnage, sauvegarde).
func effective_stat(stat_id: String) -> int:
	var value := float(stats.get(stat_id, 0))
	if hunger < HUNGER_STARVING:
		value *= HUNGER_STAT_MALUS
	if fatigue < FATIGUE_EXHAUSTED:
		value *= FATIGUE_STAT_MALUS
	return int(floor(value))


## Mange le matériau comestible EN MAIN (1 unité). A.9.1 : un ingrédient cru
## ne rend que 50 % de sa nutrition et n'accorde aucun bonus de potentiel —
## le rendement plein passera par la cuisine (7.7), pas encore implémentée.
## Le risque d'infection du cru (F.5) attend le système de statuts (F.4).
func _try_eat() -> void:
	# Comestible EN MAIN : soit une instance (viande — modèle objet), soit un
	# matériau empilé (blé, tubercule — récolte de bloc).
	var entry := _selected_entry()
	var instance: Dictionary = entry.get("object", {}) if entry.get("kind", "") == "object" else {}
	var mat: Dictionary = instance
	var mat_name := ""
	if instance.is_empty():
		mat_name = _selected_material()
		if mat_name == "":
			return
		mat = GameData.stackable(mat_name)
	if not (mat.get("nutrition", {}) as Dictionary).has("faim"):
		EventBus.ui_notification.emit("ui.toast.pas_comestible")
		return
	if hunger >= hunger_max:
		EventBus.ui_notification.emit("ui.toast.rassasie")
		return
	if instance.is_empty():
		if not inventory.remove_material(mat_name, 1):
			return
	elif not inventory.remove_object_units(instance, 1):
		return
	var nutrition: Dictionary = mat["nutrition"]
	var gain := float(nutrition["faim"])
	if not bool(nutrition["cuit"]):
		gain *= 0.5
	hunger = minf(hunger_max, hunger + gain)
	# Bonus de POTENTIEL (A.9.1) : réservés aux plats CUISINÉS — manger cru
	# n'en donne aucun. C'est ce qui rend la cuisine rentable au-delà de la
	# simple survie (6.4 : le potentiel est le cœur de la progression).
	if bool(nutrition["cuit"]):
		_credit_potential(mat.get("potentiel", {}), float(nutrition["faim"]))
	EventBus.ui_notification.emit(tr("ui.toast.mange").format({
		"item": tr(String(mat["name_key"])), "faim": str(int(round(gain)))}))


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
## Ouvre le dialogue avec la créature visée, si elle a quelque chose à dire.
##
## On réutilise la CIBLE DE COMBAT, sans second système de visée : le joueur
## désigne un PNJ exactement comme il désignerait une proie. Avoir deux
## curseurs, l'un pour frapper l'autre pour parler, obligerait à deviner lequel
## est actif.
func _try_talk() -> void:
	if _target_creature == null or not is_instance_valid(_target_creature):
		return
	var panel := get_node_or_null("/root/Main/DialoguePanel")
	if panel == null:
		return
	panel.call("open_with", _target_creature)


## La créature visée accepte-t-elle de parler ? Sert au HUD, qui doit annoncer
## la touche AVANT qu'on l'essaie — une interaction qu'on découvre en tâtonnant
## n'existe pas pour la plupart des joueurs.
func can_talk_to_target() -> bool:
	if _target_creature == null or not is_instance_valid(_target_creature):
		return false
	return String(_target_creature.ai_profile) in ["civil", "garde"]


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

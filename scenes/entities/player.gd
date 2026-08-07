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
## Modules POSSÉDÉS et leur niveau : id -> niveau (0 = tout juste appris).
## Alimenté par la LECTURE DES LIVRES (5.1), seule source de modules du jeu :
## ils ne se craftent pas. Le loadout de démonstration ci-dessus reste jouable
## d'emblée — retirer au joueur ses trois touches tant qu'il n'a pas trouvé un
## grimoire aurait cassé la boucle de jeu existante pour un gain nul.
var known_modules := {}
## ASSEMBLAGES (GDD 5.1) : compétence d'arme → liste ordonnée de slots, chaque
## slot étant une liste ordonnée d'ids de module.
##   { "epee": [ ["double_lancer", "taillade_large"], [] ], "baton_magique": [...] }
##
## RATTACHÉS AU TYPE D'ARME et non à l'objet (lecture littérale du GDD : « chaque
## TYPE d'arme possède un nombre de slots de compétences », et ce nombre dérive
## du niveau dans cette compétence). Conséquence voulue : toutes tes épées
## partagent tes techniques d'épée, et changer d'épée ne te fait rien perdre.
var assemblies := {}
## Actions de lancement (touches par défaut J/K/L —
## les touches 1-9 pilotent déjà la hotbar). Voir InputManager.DEFAULTS.
const MODULE_ACTIONS := ["module_1", "module_2", "module_3"]

## Commandes ponctuelles : action de l'InputMap -> méthode appelée.
## L'ordre n'a pas d'importance (une action ne peut correspondre qu'à une
## seule entrée), mais l'UNICITÉ des clés, si : c'est elle qui rend
## impossible la collision « deux commandes sur la même touche ».
const ACTION_HANDLERS := {
	"cycle_grid": "_cycle_grid_resolution",
	"interact": "_try_interact",
	"equip": "_try_equip",


	"sleep": "_try_sleep",
	"toggle_claim": "_toggle_claim",
	"cycle_claim_role": "_cycle_claim_role",
	"stall_stock": "_try_stock_stall",
}
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
## Résolveur de modificateurs (E.4) — (base + Σ add) × Π mult. Toute lecture de
## stat de gameplay passe par `effective_stat`, qui passe par lui. Il ne porte
## pour l'instant que les malus de faim et de fatigue ; équipement (A.4.4),
## statuts (F.4) et auras de modules (5.1) s'y brancheront sans toucher au
## joueur. Non sauvegardé : entièrement dérivé d'un état qui l'est.
var modifiers := StatModifiers.new()
## Statuts temporaires (F.4). Posé APRÈS `modifiers` : il s'y enregistre.
var statuses := StatusTracker.new()
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
## CYCLE DE TIR (2026-08-02). Une arme de distance ne balaie rien : elle tend,
## vise et décoche. Elle a donc sa propre machine à états — voir RangedAttack
## pour pourquoi les deux ne sont pas fondues.
var _ranged := RangedAttack.new()
## Stats figées du tir en cours, même principe que pour une frappe : changer
## d'arme la corde tendue ne doit pas réécrire le projectile qui part.
var _shot_stats: Dictionary = {}
var _shot_hardness := 1.0
var _shot_quality := 1.0
## Tirage propre au tir : la dispersion doit être reproductible d'une machine à
## l'autre en réseau, elle ne peut pas dépendre de l'horloge globale.
var _shot_rng := RandomNumberGenerator.new()

var _swing_stats: Dictionary = {}
## Stats, dureté et qualité de la MAIN GAUCHE pour l'enchaînement en cours.
var _swing_stats_off: Dictionary = {}
var _swing_hardness_off := 1.0
var _swing_quality_off := 1.0
var _swing_hardness := 1.0
var _swing_quality := 1.0
## BRIDAGE DE ROTATION pendant la frappe. Sans lui, tourner vite sur soi-
## meme pendant le swing ajoute cette rotation a la vitesse de la lame et
## le bonus de vitesse se farme en tournoyant : l'« helicoptere » que Mount
# & Blade interdit precisement. La CAMERA reste libre (on continue de
## viser) ; c'est l'ARC DE FRAPPE qui rattrape le regard a vitesse bornee.
const SWING_TURN_CAP := deg_to_rad(110.0)   # radians par seconde
var _swing_basis := Basis.IDENTITY
## Distances à la main des points échantillonnés le long de la TÊTE de l'arme,
## et leurs positions à la frame précédente. Les segments entre les deux frames
## sont ce qu'on teste contre les zones de coup.
##
## LA TÊTE, PAS LA POINTE (2026-08-02, demande explicite : « ça touche quand la
## tête touche »). On ne suivait que l'extrémité : une hallebarde dont le fer
## traversait un torse ne touchait rien, parce que sa pointe passait au-dessus,
## et une épée ne coupait qu'avec son dernier centimètre. Un fer est un SEGMENT,
## il balaie une surface — c'est cette surface qu'on approche ici.
var _head_samples: PackedFloat32Array = PackedFloat32Array()
var _head_previous: PackedVector3Array = PackedVector3Array()

## Écart maximal entre deux points échantillonnés, en blocs. Choisi SOUS la plus
## petite zone de coup du jeu (0,14 pour une tête de poisson) : au-delà, une
## cible fine pourrait se glisser entre deux traces et le coup passerait au
## travers. En deçà, on paierait des tests pour rien.
const HEAD_SAMPLE_STEP := 0.11
## Borne dure du nombre de points. La hallebarde et l'espadon plafonnent ici ;
## sans borne, une arme démesurée ferait exploser le coût par créature.
const HEAD_SAMPLE_MAX := 6
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
	TickManager.ticks_skipped.connect(_on_ticks_skipped)
	_build_ghost.call_deferred()


## Recalcule santé/mana depuis les stats + compétences courantes (A.5/A.5.1).
func _recompute_derived() -> void:
	health_max = 20.0 + int(stats["endurance"]) * 8.0
	health = health_max
	stamina_max = STAMINA_BASE + int(stats["endurance"]) * STAMINA_PER_ENDURANCE
	stamina = stamina_max
	mana = ManaPool.new(int(stats["volonte"]), skills.level("meditation"))
	statuses.setup(self, modifiers)
	# Les modificateurs sont dérivés, jamais sauvegardés : ils se reposent ici,
	# ce qui couvre aussi bien la création que la restauration d'une partie.
	_refresh_state_modifiers()


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
	# Ces potentiels sont le PLANCHER PERMANENT de 6.4, pas une valeur de
	# départ : passer par set_base_potential, sans quoi le level up les
	# ramènerait à 80 et l'identité de la race s'évaporerait (corrigé 2026-08-02).
	for source: Dictionary in [race.get("base_potentials", {}), cls.get("base_potentials", {})]:
		for skill_id in source:
			skills.set_base_potential(skill_id, float(source[skill_id]))
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
		# MODULES APPRIS (5.1) : à persister impérativement. Les livres sont à
		# USAGE UNIQUE — un module oublié au rechargement est définitivement
		# perdu, puisque le grimoire qui l'enseignait a été consommé.
		"known_modules": known_modules.duplicate(),
		"assemblies": assemblies.duplicate(true),
		# STATUTS (F.4) : persistés en TICKS restants. Un poison contracté
		# avant une sauvegarde doit continuer à agir au rechargement, sinon
		# sauvegarder devient une purge gratuite.
		"statuses": statuses.save_state(),
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
	known_modules = (data.get("known_modules", {}) as Dictionary).duplicate()
	assemblies = (data.get("assemblies", {}) as Dictionary).duplicate(true)
	statuses.setup(self, modifiers)
	statuses.restore_state(data.get("statuses", {}))
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
	# Après les jauges, jamais avant : les modificateurs d'état en dérivent.
	# Une partie rechargée en état de famine doit rouvrir avec son malus.
	_refresh_state_modifiers()
	var pos: Variant = data.get("position")
	if pos is Array and (pos as Array).size() == 3:
		teleport_to(Vector3(float(pos[0]), float(pos[1]), float(pos[2])))


func skill_level(skill_id: String) -> int:
	return skills.level(skill_id)


func take_damage(amount: int) -> void:
	# RÉDUCTION PAR STATUT (F.4 : peau de pierre, garde de fer, bouclier
	# arcane). Passe par le résolveur E.4 : `reduction_degats` n'est pas une
	# stat de base, sa valeur nue est 0 et seuls les modificateurs la font
	# monter. Bornée à 80 % — une invulnérabilité complète casserait le combat.
	var reduction := clampf(modifiers.apply(0.0, "reduction_degats"), 0.0, 0.8)
	if reduction > 0.0:
		amount = int(round(float(amount) * (1.0 - reduction)))
	health = maxf(0.0, health - amount)
	# STAGGER (2026-08-02) : encaisser INTERROMPT son propre coup. Sans ça les
	# deux camps se traversaient — on pouvait échanger à l'aveugle en sachant
	# qu'on frapperait de toute façon, ce qui vide la parade de son intérêt et
	# transforme le duel en course aux dégâts. C'est la règle de Mount & Blade,
	# et elle vaut pour la créature comme pour le joueur.
	if amount > 0:
		_attack.interrupt()
		_swing_stats = {}
		# La corde se détend aussi : on ne garde pas un arc bandé en encaissant.
		_ranged.interrupt()
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
					_begin_combat_input()
				else:
					_release_combat_input()
			else:
				_mining = button.pressed
				if not button.pressed:
					_progress = 0.0
		elif button.button_index == MOUSE_BUTTON_RIGHT:
			# LE CLIC DROIT UTILISE CE QU'ON TIENT (2026-08-03, demande de
			# l'auteur). Trois cas, dans cet ordre, et l'ordre est la règle :
			#   arme     → garde (le combat prime : lever sa garde ne doit
			#              jamais poser un bloc ni manger en plein duel) ;
			#   comestible ou livre → consommé / lu ;
			#   reste    → pose de bloc, comportement historique.
			# `_equipped_weapon` lit l'emplacement SÉLECTIONNÉ, pas l'équipement :
			# le clic droit porte donc bien sur l'objet en main.
			# CTRL + CLIC DROIT : poser / reprendre un OBJET au sol, en tant que
			# bloc (2026-08-06). Testé AVANT tout le reste, et c'est délibéré :
			# le cas qu'on veut le plus souvent poser est justement une arme,
			# donc l'ordre habituel (arme → garde) rendrait la commande
			# inutilisable sur la moitié du catalogue.
			#
			# La condition porte sur `pressed` ET sur Ctrl, jamais sur Ctrl
			# seul : un RELÂCHEMENT fait avec Ctrl enfoncé doit continuer de
			# tomber dans la branche de garde, sinon une garde levée sans Ctrl
			# puis relâchée avec resterait levée pour toujours.
			if button.ctrl_pressed and button.pressed:
				_try_place_or_take_object()
			elif not _equipped_weapon().is_empty():
				_set_guard(button.pressed)
			elif button.pressed:
				if not _try_consume_held():
					_try_place()
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
			return
		# Table action -> méthode : une chaîne de `elif` avait laissé passer
		# KEY_E deux fois (« parler » puis « équiper », ce dernier jamais
		# atteint). Un dictionnaire ne peut pas contenir deux fois la même
		# clé — la collision devient une impossibilité d'écriture.
		for action: String in ACTION_HANDLERS:
			if event.is_action_pressed(action):
				Callable(self, ACTION_HANDLERS[action]).call()
				return
		for index in MODULE_ACTIONS.size():
			if event.is_action_pressed(MODULE_ACTIONS[index]):
				_cast_from_key(index)
				return


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


## VOYAGE RAPIDE INSTANTANÉ (2026-08-03, demande de l'auteur : « change le tp
## pour qu'il soit instantané »).
##
## Le trajet était une animation de six secondes qui déplaçait réellement le
## joueur d'un bout à l'autre du monde en simulant chaque tick au passage. Le
## temps de jeu était donc juste, mais le prix était lourd : streaming de tous
## les chunks de la trajectoire, IA de chaque créature survolée, et surtout
## peuplement puis relâche de chaque village traversé — d'où les pics de tick à
## 62 ms observés en jeu pendant un voyage.
##
## LE COÛT EN TEMPS DE JEU RESTE DÛ : on ne l'annule pas, on le PASSE
## (`skip_ticks`) au lieu de le jouer. Le voyage reste cher en heures de jeu,
## il ne coûte plus de secondes réelles.
func fast_travel_to_world(wx: int, wz: int) -> void:
	var from: Vector3 = _camera.global_position
	var dist := Vector2(float(wx) - from.x, float(wz) - from.z).length()
	var ticks := int(round(dist * MAP_TRAVEL_TICKS_PER_BLOCK / maxf(move_speed_mult, 0.1)))
	teleport_to_surface(wx, wz)
	TickManager.skip_ticks(ticks)


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
		_ranged.advance(delta)
	# POSTURE DE COMBAT poussée vers la caméra (2026-08-02) : elle y pondère le
	# jeu de jambes (recul et pas de côté ralentis, brève inertie). La caméra ne
	# doit connaître ni arme, ni endurance, ni garde — juste « ce corps est
	# engagé ou non », d'où un simple booléen plutôt qu'une référence au joueur.
	#
	# Bander un arc en fait partie : viser immobilise autant que tenir une garde,
	# et un archer qui recule à pleine vitesse en tirant serait intenable.
	if _camera != null:
		_camera.combat_stance = _guard_active or _attack.is_busy() or _ranged.is_busy()
		_camera.status_speed = movement_multiplier()


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
		# CHANGER D'ARME DÉTEND LA CORDE (2026-08-02). Le cycle de tir survivait
		# au changement : on bandait un arc, on passait à la pioche, et le tir
		# partait quand même — avec les stats figées de l'arc, depuis une main
		# qui tenait autre chose.
		if _ranged.is_busy():
			_ranged.interrupt()
		_weapon_stats_key = key
		_weapon_stats = WeaponStats.derive(GameData.functionalities[functionality_id], weapon)
	return _weapon_stats


## Le clic gauche BANDE ou ARME, selon ce qu'on tient. Un seul aiguillage, pour
## que le reste du fichier n'ait jamais à retester le type d'arme.
func _begin_combat_input() -> void:
	if WeaponStats.is_ranged(_current_weapon_stats()):
		_begin_draw()
		return
	_begin_attack()


func _release_combat_input() -> void:
	if WeaponStats.is_ranged(_current_weapon_stats()):
		_fire_shot()
		return
	_attack.release_input()


## Commence à bander. Le tir ne coûte l'endurance qu'au DÉCOCHAGE : tendre pour
## rien ne doit pas être puni, c'est même le geste qu'on veut encourager
## (préparer son tir avant que la cible n'arrive).
func _begin_draw() -> void:
	# Ni pendant une frappe de mêlée, ni en garde. Sans ce test, changer d'arme
	# en plein swing permettait de bander tout en frappant, et deux cycles
	# d'attaque tournaient en parallèle.
	if _ranged.is_busy() or _guard_active or _attack.is_busy():
		return
	var stats := _current_weapon_stats()
	var weapon := _equipped_weapon()
	_shot_stats = stats.duplicate()
	_shot_hardness = float(weapon.get("base_hardness", 1.0)) if not weapon.is_empty() else 1.0
	_shot_quality = float(weapon.get("quality", 1.0)) if not weapon.is_empty() else 1.0
	_ranged.begin(stats)


## Décoche, si l'arme est prête. Le projectile part de l'ŒIL et non de l'arme :
## c'est ce que le joueur vise, et faire partir la flèche de la main la ferait
## rater ce qu'il a sous le réticule — le mensonge exact que tout ce système
## s'interdit.
func _fire_shot() -> void:
	if not _ranged.can_fire() or _camera == null:
		return
	if stamina < float(_shot_stats.get("stamina_cost", 2.0)):
		_ranged.interrupt()
		return
	# LE CARQUOIS (2026-08-02). Le tir était GRATUIT : sans munition à dépenser,
	# une arme de distance dominait tout — aucune raison de s'approcher, aucune
	# gestion, aucun arbitrage. Une flèche se fabrique, se transporte et se
	# compte, exactement comme la nourriture.
	if not _consume_ammo(String(_shot_stats.get("munition", ""))):
		_ranged.interrupt()
		EventBus.ui_notification.emit("ui.combat.carquois_vide")
		return
	var skill_level: int = skills.level(String(_shot_stats.get("skill", "arc")))
	var spread := _ranged.fire(PlayerSkills.skill_factor(skill_level))
	var aim := -_camera.global_basis.z
	var direction := RangedAttack.scatter(aim, spread, _shot_rng)
	var origin := _camera.global_position + aim * 0.4
	ProjectileManager.launch(origin, direction, _shot_stats,
		_shot_hardness, _shot_quality, self)
	_pending_hits.append({"kind": "swing", "stats": _shot_stats})


## Combien de munitions de ce type le joueur transporte-t-il ?
func ammo_count(ammo_id: String) -> int:
	if ammo_id == "":
		return 0
	var total := 0
	for obj: Dictionary in inventory.objects:
		if String(obj.get("resource_id", "")) == ammo_id:
			total += int(obj.get("count", 1))
	return total


## Retire UNE munition. Retourne false si le carquois est vide — l'appelant
## annule alors le tir plutôt que de le laisser partir dans le vide.
func _consume_ammo(ammo_id: String) -> bool:
	if ammo_id == "":
		return true   # arme sans munition déclarée : rien à décompter
	for obj: Dictionary in inventory.objects:
		if String(obj.get("resource_id", "")) == ammo_id:
			return inventory.remove_object_units(obj, 1)
	return false


## Un projectile a touché : l'XP revient au tireur. Appelé par le tick du
## gestionnaire de projectiles, jamais à la frame.
func note_ranged_hit(stats: Dictionary, damage: float, victim: Node) -> void:
	_gain_combat_xp(stats, damage)
	note_offence_against(victim, RELATION_ON_HIT)
	if victim.is_dead():
		_creature_defeated(victim)


func _begin_attack() -> void:
	if _attack.is_busy() or _guard_active or _ranged.is_busy():
		return
	var weapon_stats := _current_weapon_stats()
	# Sans endurance, on ne lance pas de coup : c'est le frein qui empêche le
	# clic frénétique que tout ce système cherche à remplacer.
	#
	# EN DUAL WIELDING, LES DEUX COUPS SONT DUS D'AVANCE. L'enchaînement ne
	# s'interrompt pas : autoriser le premier coup sans pouvoir payer le second
	# laisserait le joueur à découvert au milieu d'un geste qu'il n'a pas choisi
	# de raccourcir. C'est aussi ce qui empêche le dual wielding d'être
	# gratuitement supérieur — il engage deux fois plus à chaque clic.
	var total_cost := float(weapon_stats["stamina_cost"])
	var offhand_preview := offhand_stats()
	if not offhand_preview.is_empty():
		total_cost += float(offhand_preview["stamina_cost"])
	if stamina < total_cost:
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
	# ENCHAÎNEMENT À DEUX ARMES : la main gauche fige les siennes en même temps.
	# Un enchaînement engagé va au bout avec les armes du moment où il est parti.
	_swing_stats_off = {}
	var offhand := offhand_weapon()
	if not offhand.is_empty():
		_swing_stats_off = offhand_stats().duplicate()
		_swing_hardness_off = float(offhand.get("base_hardness", 1.0))
		_swing_quality_off = float(offhand.get("quality", 1.0))
	_attack.begin(weapon_stats, 2 if not _swing_stats_off.is_empty() else 1)


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
	# ON NE PARE PAS AVEC UN ARC (2026-08-02). Le clic droit levait une garde
	# quelle que soit l'arme équipée : on bloquait donc une épée avec une corde
	# tendue. Une arme de tir n'a rien à opposer — dans Mount & Blade on lâche
	# son arc pour se défendre, on ne s'en sert pas comme d'un bouclier.
	if active and WeaponStats.is_ranged(_current_weapon_stats()):
		return
	# Lever sa garde DÉTEND la corde : on ne garde pas un arc bandé en levant
	# le bras, et sans ça le tir partait après coup, une fois la garde baissée.
	if active and _ranged.is_busy():
		_ranged.interrupt()
	if active and _attack.is_busy():
		# FEINTE : lever sa garde ANNULE une attaque en PRÉPARATION. C'est le
		# geste central de Mount & Blade — armer un coup pour appâter une parade,
		# l'annuler, puis frapper ailleurs.
		#
		# MAIS SEULEMENT EN PRÉPARATION (2026-08-02). Une frappe déjà partie ne
		# s'annule pas — on assume son coup — et surtout la RÉCUPÉRATION ne
		# s'annule pas non plus. C'était le trou : on balayait dans le vide et
		# l'on se retrouvait en garde à l'instant même, si bien que rater ne
		# coûtait RIEN. Or la récupération EST la punition du coup manqué : c'est
		# elle qui fait de l'attaque un engagement, et sans engagement la feinte
		# n'a personne à tromper.
		if _attack.state == MeleeAttack.State.RELEASE 				or _attack.state == MeleeAttack.State.RECOVERY:
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
	# Une garde en cours de LECTURE reste au port : tant que la direction n'est
	# pas figée, montrer une posture serait annoncer un choix qui n'est pas fait.
	if not _guard_locked:
		return carry
	# POSTURE PROPRE À LA GARDE (2026-08-02) et non plus le début de l'arc
	# d'attaque : parer et frapper ne sont pas le même geste, et emprunter la
	# géométrie de l'un pour l'autre mettait la lame dans l'axe du coup au lieu
	# d'en travers (voir MeleeAttack.guard_blade_axis).
	var offset := MeleeAttack.guard_hand_offset(_guard_direction)
	var right := camera_basis.x
	right.y = 0.0
	if right.length_squared() > 0.000001:
		right = right.normalized()
	var target := grip + right * (offset.x * hand_radius) + Vector3.UP * (offset.y * hand_radius) \
		+ _carry_direction(camera_basis) * (offset.z * hand_radius)
	return carry.lerp(target, GUARD_ARC_BLEND)


## Entame la structure du bouclier. Il se BRISE quand elle tombe à zéro : il
## reste porté mais cesse d'absorber, et le joueur en est averti — un bouclier
## qui cesserait silencieusement de protéger serait la pire des surprises.
func _wear_shield(drain: float) -> void:
	var shield := equipped_shield()
	if shield.is_empty():
		return
	var structure := shield_structure()
	if bool(structure["broken"]):
		return
	var left: float = maxf(float(structure["current"]) - drain * SHIELD_WEAR_PER_DRAIN, 0.0)
	shield["structure"] = left
	if left <= 0.0:
		EventBus.ui_notification.emit("ui.combat.bouclier_brise")


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


# --- POSTURES DE COMBAT (GDD 6.2, 2026-08-02) ----------------------------
#
# « L'usage des deux emplacements d'armes dépend du type d'arme équipée » : le
# joueur ne CHOISIT pas une posture, elle se DÉDUIT de ce qu'il porte. C'est ce
# qui évite un mode de combat à basculer — un état de plus à se rappeler, et un
# état de plus qui peut mentir sur ce que les mains font vraiment.
const STANCE_MAINS_NUES := "mains_nues"
const STANCE_UNE_MAIN := "une_main"
const STANCE_DEUX_MAINS := "deux_mains"
const STANCE_ARME_BOUCLIER := "arme_bouclier"
const STANCE_DEUX_ARMES := "deux_armes"

## Compétence de STYLE entraînée par chaque posture (GDD 6.2). Elle s'ajoute à
## celle du type d'arme, elle ne la remplace pas.
const STANCE_SKILL := {
	STANCE_DEUX_MAINS: "deux_mains",
	STANCE_ARME_BOUCLIER: "bouclier",
	STANCE_DEUX_ARMES: "dual_wielding",
}


## L'arme de MAIN GAUCHE, ou {} s'il n'y en a pas.
##
## Trois conditions, et chacune ferme un abus : ce doit être une arme (pas un
## bouclier — il a sa propre voie), à UNE main (une seconde arme à deux mains
## est physiquement absurde), et la main forte ne doit pas déjà être prise par
## une arme à deux mains.
func offhand_weapon() -> Dictionary:
	var piece: Dictionary = equipment.equipped("arme_2")
	if piece.is_empty():
		return {}
	var item: Dictionary = GameData.items.get(piece.get("item_id", ""), {})
	if String(item.get("type", "")) != "arme" or int(item.get("hands", 1)) >= 2:
		return {}
	if int(_current_weapon_stats().get("hands", 1)) >= 2:
		return {}
	return piece


## Posture courante, déduite des deux mains.
func combat_stance() -> String:
	var main_hand := _equipped_weapon()
	if main_hand.is_empty():
		return STANCE_MAINS_NUES
	if int(_current_weapon_stats().get("hands", 1)) >= 2:
		return STANCE_DEUX_MAINS
	if bool(shield_profile()["present"]):
		return STANCE_ARME_BOUCLIER
	if not offhand_weapon().is_empty():
		return STANCE_DEUX_ARMES
	return STANCE_UNE_MAIN


## Stats de combat de la main gauche ({} si elle ne porte pas d'arme).
## Mise en cache comme celles de la main forte : `derive()` est faite pour être
## appelée au changement d'arme, pas à la frame.
var _offhand_stats: Dictionary = {}
var _offhand_stats_key := ""


func offhand_stats() -> Dictionary:
	var weapon := offhand_weapon()
	if weapon.is_empty():
		_offhand_stats_key = ""
		_offhand_stats = {}
		return {}
	var key := "%s:%d" % [String(weapon["functionality"]), int(weapon.get("uid", 0))]
	if key != _offhand_stats_key:
		_offhand_stats_key = key
		_offhand_stats = WeaponStats.derive(
			GameData.functionalities[String(weapon["functionality"])], weapon)
	return _offhand_stats


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
	if shield_broken():
		# BRISÉ : encore au bras, mais il n'arrête plus rien. La couverture
		# élargie disparaît avec lui — c'est ce qui fait qu'on sent la perte.
		return {"present": false, "couverture": 0, "absorption": 0.0,
			"quality": 1.0, "brise": true}
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


## `offhand` : la prise de la main GAUCHE, symétrique de la droite. Le retour de
## main gauche d'un enchaînement part de là, donc son arc — et sa hitbox — aussi.
## Recentrage de la prise pour une arme à deux mains : fraction du décalage
## latéral conservée. 0 mettrait l'arme pile devant le nez ; on garde un léger
## décalage pour que la lame ne masque pas le réticule.
const TWO_HANDED_GRIP_CENTERING := 0.25


func _grip_position(camera_basis: Basis, offhand: bool = false) -> Vector3:
	var right := camera_basis.x
	right.y = 0.0
	if right.length_squared() > 0.000001:
		right = right.normalized()
	var lateral := -GRIP_RIGHT if offhand else GRIP_RIGHT
	# ARME À DEUX MAINS : LA PRISE SE CENTRE (2026-08-03).
	#
	# Tenue décalée à droite comme une arme à une main, une arme à deux mains
	# place son manche HORS D'ATTEINTE du bras gauche : l'épaule gauche est
	# à ~0,4 m sur le côté opposé, le manche à 0,7 m devant, et le bras ne fait
	# que 0,69 m. La seconde main glissait alors le long du manche pour rester à
	# portée, jusqu'à sortir de l'arme par le pommeau — d'où une main
	# visiblement à côté de l'arme, quoi qu'on corrige en aval.
	#
	# Aucune manipulation d'IK ne pouvait réparer ça : le problème n'était pas
	# où l'on posait la main, mais où l'on tenait l'arme. On ramène donc la
	# prise vers l'axe du corps, comme on tient réellement un espadon.
	if not offhand and int(_current_weapon_stats().get("hands", 1)) >= 2:
		lateral *= TWO_HANDED_GRIP_CENTERING
	return _camera.global_position - Vector3.UP * GRIP_DOWN + right * lateral


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


## Axe de la SECONDE arme, même invariant que la première : elle pointe le long
## de l'arc qu'elle parcourt, donc le geste vu est celui qui touche.
var _offhand_direction := Vector3.FORWARD


func offhand_direction() -> Vector3:
	return _offhand_direction


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
## UN RESSORT PAR MAIN (2026-08-02, demande de l'auteur : « le bras gauche
## devrait agir comme le bras droit »). Il n'y en avait qu'un, réservé à la
## droite : la main gauche se TÉLÉPORTAIT sur sa cible pendant que la droite
## avait du poids. Un bouclier claquait en position, une seconde arme n'avait
## aucun ballant, et les deux bras ne se lisaient pas comme appartenant au même
## corps.
##
## Le ressort est le MÊME (raideur et amortissement viennent de l'arme tenue) —
## seul son état est dédoublé.
var _hand_smoothed := {"droite": Vector3.ZERO, "gauche": Vector3.ZERO}
var _hand_velocity := {"droite": Vector3.ZERO, "gauche": Vector3.ZERO}
var _hand_initialised := {"droite": false, "gauche": false}
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
## `record_lag` : cette main porte-t-elle le coup en cours ? Seule celle-là doit
## publier son retard, car c'est lui qui fait traîner la POINTE de l'arme. La
## main d'appoint intègre son ressort sans y toucher — sinon elle écraserait le
## retard de la main qui frappe, et la hitbox cesserait de suivre le visuel.
func _integrate_hand_inertia(target: Vector3, delta: float, stats: Dictionary,
		hand: String = "droite", record_lag: bool = true) -> Vector3:
	# Origine MOBILE : tout est exprimé relativement à la caméra, donc la
	# translation du corps n'entre jamais dans le ressort.
	var origin := _camera.global_position
	var target_offset := target - origin
	if not bool(_hand_initialised[hand]):
		_hand_initialised[hand] = true
		_hand_smoothed[hand] = target_offset
		_hand_velocity[hand] = Vector3.ZERO
	var step := minf(delta, MAX_INERTIA_STEP)
	var stiffness := float(stats.get("inertia_stiffness", 200.0))
	var damping := float(stats.get("inertia_damping", 20.0))
	var smoothed: Vector3 = _hand_smoothed[hand]
	var velocity: Vector3 = _hand_velocity[hand]
	velocity += ((target_offset - smoothed) * stiffness - velocity * damping) * step
	smoothed += velocity * step
	_hand_velocity[hand] = velocity
	_hand_smoothed[hand] = smoothed
	if record_lag:
		_lag_offset = smoothed - target_offset
	return origin + smoothed


func hand_targets(hand_radius: float, offhand_offset: float, delta: float) -> Dictionary:
	if _camera == null:
		return {}
	var camera_basis := _camera.global_basis
	var grip := _grip_position(camera_basis)
	var carry := grip + _carry_direction(camera_basis) * hand_radius
	var target := carry

	# LE COUP COURANT PEUT PARTIR DE LA GAUCHE (enchaînement à deux armes) : la
	# main qui décrit l'arc est alors la gauche, et c'est la droite qui revient
	# au port. Sans ça le geste vu serait celui de la mauvaise main, alors même
	# que la hitbox, elle, partirait bien de la gauche.
	var offhand_strike: bool = _attack.is_busy() and _attack.is_offhand_strike()
	if offhand_strike:
		grip = _grip_position(camera_basis, true)
		carry = grip + _carry_direction(camera_basis) * hand_radius
		target = carry

	if _attack.is_busy() and not _swing_stats.is_empty():
		var direction := _attack.strike_direction()
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
	elif _ranged.is_busy():
		# POSE DE TIR (2026-08-02). La tension ne se voyait NULLE PART : le corps
		# restait au port pendant qu'on bandait, donc rien ne disait au joueur
		# où en était son arc — ni à un adversaire qu'on le tenait en joue. La
		# main d'arme RECULE vers la joue à mesure que la corde se tend, ce qui
		# est le geste, et ce qui rend la tension lisible de l'extérieur.
		var aim := _carry_direction(camera_basis)
		var full := grip + aim * (hand_radius * 0.30) + Vector3.UP * (hand_radius * 0.34)
		target = carry.lerp(full, _ranged.draw_ratio)
	elif _guard_active:
		target = _guard_hand_target(grip, camera_basis, hand_radius)

	var stats_for_inertia: Dictionary = _current_weapon_stats()
	if not _swing_stats.is_empty():
		stats_for_inertia = _active_swing_stats()
	# INERTIE : la main est tiree vers sa cible, elle ne s'y colle pas.
	target = _integrate_hand_inertia(target, delta, stats_for_inertia,
		"gauche" if offhand_strike else "droite")
	# L'arme pointe de la PRISE vers la main : le meme axe que l'arc, donc le
	# geste vu et le balayage qui touche restent la meme courbe.
	var axis_to_hand := target - grip
	if axis_to_hand.length_squared() > 0.000001:
		_weapon_direction = axis_to_hand.normalized()
	# SAUF EN GARDE : on pare EN TRAVERS de la ligne attaquee, pas dans son axe.
	# La main tient l'arme, la parade decide de son inclinaison — exactement
	# comme la visee decide de celle d'une frappe.
	if _guard_active and _guard_locked and not _attack.is_busy():
		_weapon_direction = MeleeAttack.guard_blade_axis(_guard_direction, camera_basis)
	# Le coup de main gauche renvoie sa cible sur la GAUCHE, et rend la droite
	# au port : les deux clés sont donc échangées, pas recalculées.
	var targets := {}
	if offhand_strike:
		targets["gauche"] = target
		targets["droite"] = _grip_position(camera_basis) 			+ _carry_direction(camera_basis) * hand_radius
		var swing_axis := target - grip
		if swing_axis.length_squared() > 0.000001:
			_offhand_direction = swing_axis.normalized()
		return targets
	targets["droite"] = target
	# DEUX ARMES : la gauche porte sa propre arme, au port ou croisée en garde.
	# Elle ne suit pas le manche de la droite — ce sont deux armes distinctes,
	# c'est tout l'intérêt de la posture.
	if _ranged.is_busy():
		# La gauche TIENT L'ARC, bras tendu vers la cible, pendant que la droite
		# tire la corde. Sans elle les deux mains se rejoindraient à la joue et
		# l'arc n'aurait plus de monture.
		targets["gauche"] = _integrate_hand_inertia(
			grip + _carry_direction(camera_basis) * (hand_radius * 1.15), delta,
			stats_for_inertia, "gauche", false)
		return targets
	if not offhand_weapon().is_empty():
		# MÊME TRAITEMENT QUE LA DROITE : le ressort de la main gauche est nourri
		# par les stats de SON arme, donc une dague y colle et un marteau y
		# traîne. Sans lui elle se téléportait sur sa cible.
		var left := _integrate_hand_inertia(
			_offhand_weapon_target(camera_basis, hand_radius), delta,
			offhand_stats(), "gauche", false)
		targets["gauche"] = left
		var left_axis := left - _grip_position(camera_basis, true)
		if left_axis.length_squared() > 0.000001:
			_offhand_direction = left_axis.normalized()
		if _guard_active and _guard_locked:
			# PARADE CROISÉE : la seconde lame barre la ligne OPPOSÉE à la
			# première, c'est ce croisement en X qui donne sa couverture large
			# à la posture (combat.md § « Deux Armes »).
			_offhand_direction = MeleeAttack.guard_blade_axis(
				MeleeAttack.guard_for(_guard_direction), camera_basis)
		return targets
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
	if is_zero_approx(separation) and int(stats.get("hands", 1)) >= 2:
		separation = offhand_offset
	# LE SIGNE COMPTE (2026-08-02). Un écart NÉGATIF pose la seconde main
	# DERRIÈRE la première, sur le pommeau : c'est la prise d'un espadon. Un
	# écart positif la projette devant, c'est celle d'une arme d'hast. On testait
	# `> 0.0`, donc toute arme à deux mains se tenait comme une pique et la main
	# gauche d'un espadon partait vers la lame.
	if not is_zero_approx(separation):
		# LA SECONDE MAIN EST SUR LE MANCHE, POINT.
		#
		# Sa définition est simple et n'a jamais varié : elle se tient à
		# `hand_separation` mètres de la première, LE LONG DE L'ARME. Tout le
		# reste (distance à la prise, position de la cible de la main droite,
		# axe prise→main) n'était que des approximations de cette phrase, et
		# chacune introduisait son propre écart. Mesuré : la main flottait à 10
		# cm du manche sur une épée, 27 cm sur un marteau.
		#
		# Deux ancrages, et ils doivent être COHÉRENTS ENTRE EUX — c'est l'erreur
		# qui a coûté le plus de temps ici :
		#   - l'ORIGINE est la main droite RÉELLE, car l'arme y est accrochée
		#     (l'IK rate sa cible de 9 cm, et l'arme suit l'os, pas la cible) ;
		#   - la DIRECTION est `_weapon_direction`, celle qui oriente réellement
		#     le modèle. Mélanger l'une avec l'axe de l'autre remet un décalage.
		var shaft_from := _right_hand_actual if _has_right_hand_actual else target
		if _weapon_direction.length_squared() > 0.000001:
			var wanted := shaft_from + _weapon_direction * separation
			targets["gauche"] = _integrate_hand_inertia(
				_slide_into_reach(shaft_from, _weapon_direction, wanted), delta,
				stats_for_inertia, "gauche", false)
	elif bool(shield_profile()["present"]):
		# BOUCLIER : la main gauche ne suit pas l'arme, elle porte la plaque
		# devant le buste. Elle se LÈVE en garde, ce qui rend le blocage visible
		# — sans quoi le joueur ne saurait pas si son bouclier est engagé, et
		# c'est pourtant lui qui décide s'il encaisse ou non.
		#
		# Elle passe par le ressort comme la droite : une plaque qui claque en
		# position se lit comme une interface, pas comme un bras.
		targets["gauche"] = _integrate_hand_inertia(
			_shield_hand_target(grip, camera_basis, hand_radius), delta,
			stats_for_inertia, "gauche", false)
	else:
		# MAIN LIBRE (2026-08-03, demande de l'auteur : « que le bras soit pas
		# collé au corps »). Aucune arme, aucune plaque : la gauche n'avait
		# AUCUNE cible et retombait sur la pose de port figée du squelette,
		# c'est-à-dire un bras plaqué contre le buste, immobile même en courant.
		#
		# Elle reçoit maintenant une pose de repos écartée du torse, BALANCÉE
		# PAR LA MARCHE et en opposition de phase avec la jambe du même côté —
		# c'est ce que fait un bras humain, et c'est ce qui fait la différence
		# entre un personnage et un mannequin.
		targets["gauche"] = _integrate_hand_inertia(
			_free_hand_target(grip, camera_basis, hand_radius), delta,
			stats_for_inertia, "gauche", false)
	return targets


## Épaule gauche et allonge du bras gauche, POUSSÉES par le corps à chaque
## frame. Le joueur calcule des cibles ; seul le corps sait ce que ses bras
## peuvent atteindre, et il n'y a aucune raison de lui faire deviner.
var _left_shoulder := Vector3.ZERO
var _left_reach := 0.0
## Position RÉELLE de la main droite à la frame précédente. L'arme y est
## accrochée : c'est de là que part son manche, et non de la cible qu'on avait
## demandée. L'écart entre les deux n'est pas anecdotique — mesuré à 9 cm, ce
## qui suffit à décoller la seconde main du manche.
##
## Une frame de retard est sans conséquence ici : la main parcourt quelques
## millimètres par frame, très en deçà de l'erreur qu'on corrige.
var _right_hand_actual := Vector3.ZERO
var _has_right_hand_actual := false


func set_left_arm_span(shoulder: Vector3, reach: float) -> void:
	_left_shoulder = shoulder
	_left_reach = reach


func set_right_hand_actual(position: Vector3) -> void:
	_right_hand_actual = position
	_has_right_hand_actual = true


## Ramène `wanted` sur le segment du manche jusqu'à ce qu'il soit à portée de
## l'épaule gauche. Retourne `wanted` inchangé s'il l'est déjà.
##
## Géométrie : on cherche l'intersection de la DROITE du manche avec la SPHÈRE
## d'allonge centrée sur l'épaule, et on garde la solution la plus proche de la
## prise voulue. Sans intersection (manche entièrement hors d'atteinte), on
## prend le point du manche le plus proche de l'épaule — le mieux disponible.
func _slide_into_reach(origin: Vector3, direction: Vector3, wanted: Vector3) -> Vector3:
	if _left_reach <= 0.0:
		return wanted
	# Marge : viser exactement l'allonge maximale tend le bras à la corde, ce
	# qui se lit comme une raideur. On garde un coude légèrement fléchi.
	var reach := _left_reach * 0.92
	if _left_shoulder.distance_to(wanted) <= reach:
		return wanted
	var to_origin := origin - _left_shoulder
	var b := 2.0 * to_origin.dot(direction)
	var c := to_origin.length_squared() - reach * reach
	var discriminant := b * b - 4.0 * c
	if discriminant < 0.0:
		# Le manche ne croise pas la sphère : point le plus proche de l'épaule.
		var closest := -to_origin.dot(direction)
		return origin + direction * closest
	var root := sqrt(discriminant)
	var t1 := (-b - root) * 0.5
	var t2 := (-b + root) * 0.5
	var wanted_t := (wanted - origin).dot(direction)
	# La solution la plus proche de la prise voulue : sur un espadon la main
	# recule vers le pommeau, sur une hampe elle avance — le signe se déduit,
	# il n'a pas à être codé.
	return origin + direction * (t1 if absf(t1 - wanted_t) < absf(t2 - wanted_t) else t2)


## Repos de la MAIN LIBRE, en espace caméra : en bas à gauche, légèrement en
## avant, avec un balancement de marche.
##
## L'amplitude est volontairement PETITE. Ce bras ne raconte rien de tactique —
## il ne pare pas, ne frappe pas, ne porte rien : s'il attirait l'œil il
## volerait l'attention que le combat directionnel demande de porter sur l'arme
## de l'adversaire. Il doit juste cesser d'être un morceau de bois.
const FREE_HAND_REST := Vector3(-0.34, -0.62, -0.18)
const FREE_HAND_SWING := 0.16


## La main gauche PORTE-T-ELLE quelque chose ? Distinct de « a une cible » :
## depuis 2026-08-03 elle en a toujours une, y compris au repos. C'est cette
## question-ci, et pas l'autre, qui décide de l'affichage du bras en première
## personne.
func left_hand_busy() -> bool:
	if _ranged.is_busy() or not offhand_weapon().is_empty():
		return true
	if bool(shield_profile()["present"]):
		return true
	var stats: Dictionary = _current_weapon_stats()
	return int(stats.get("hands", 1)) >= 2 or not is_zero_approx(float(stats.get("hand_separation", 0.0)))


func _free_hand_target(grip: Vector3, camera_basis: Basis, hand_radius: float) -> Vector3:
	var right := camera_basis.x
	var up := camera_basis.y
	var forward := -camera_basis.z
	# OPPOSITION DE PHASE : le bras gauche avance quand la jambe gauche recule.
	# La phase de marche vit sur le CORPS (PlayerBody), qui la calcule depuis la
	# distance réellement parcourue — la relire ici évite d'en tenir une seconde
	# qui dériverait.
	var swing := sin(_body_gait + PI) * FREE_HAND_SWING * _body_gait_amount
	return grip 			+ right * (FREE_HAND_REST.x * hand_radius) 			+ up * (FREE_HAND_REST.y * hand_radius) 			+ forward * ((FREE_HAND_REST.z + swing) * hand_radius)


## Phase et amplitude de marche, POUSSÉES par le corps à chaque frame (comme la
## posture l'est vers la caméra). Le joueur ne calcule pas la marche — il la
## reçoit de ce qui l'anime.
var _body_gait := 0.0
var _body_gait_amount := 0.0


func set_body_gait(phase: float, amount: float) -> void:
	_body_gait = phase
	_body_gait_amount = clampf(amount, 0.0, 1.0)


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


## PARADE CROISÉE (combat.md §2, « Deux Armes ») : « le clic droit déplace les
## deux armes devant le joueur en les croisant, les deux bras se croisent en X
## devant le visage ». Au repos, la gauche reste au port, en retrait et un peu
## plus bas que la droite — deux armes ne se tiennent pas côte à côte.
const OFFHAND_CARRY := Vector3(-0.55, -0.16, 0.80)
const OFFHAND_CROSS := Vector3(-0.30, 0.34, 0.66)


func _offhand_weapon_target(camera_basis: Basis, hand_radius: float) -> Vector3:
	var grip := _grip_position(camera_basis, true)
	var offset := OFFHAND_CROSS if (_guard_active and _guard_locked) else OFFHAND_CARRY
	var right := camera_basis.x
	right.y = 0.0
	if right.length_squared() > 0.000001:
		right = right.normalized()
	return grip + right * (offset.x * hand_radius) + Vector3.UP * (offset.y * hand_radius) 		+ _carry_direction(camera_basis) * (offset.z * hand_radius)


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


## Échelle d'affichage des armes à pièces. ELLE COMPTE MAINTENANT POUR LA
## GÉOMÉTRIE : depuis que la hitbox suit le modèle, agrandir l'arme à l'écran
## l'allonge aussi pour de vrai. Ce n'est plus un réglage de cadrage libre —
## c'est la longueur de l'arme.
const PART_DRAW_SCALE: float = preload("res://scenes/entities/held_item.gd").PART_SCALE


## Rayons, MESURÉS DEPUIS LA PRISE, des points à suivre le long de la tête —
## du talon du fer jusqu'à la pointe. Calculés UNE FOIS par frappe (au
## « release ») : la géométrie de l'arme ne change pas en plein swing.
##
## LE BRAS COMPTE (2026-08-02). L'arc partait de la prise (au corps) avec pour
## rayon la seule longueur de l'arme, alors que l'arme est DESSINÉE à partir de
## la MAIN, elle-même à `HAND_ARC_RADIUS` devant la prise : la hitbox était donc
## en retrait de 72 cm sur le modèle affiché, et le joueur voyait sa lame
## traverser une cible sans rien lui faire. On additionne désormais le bras et
## l'arme, exactement comme le rendu les additionne.
func _head_distances(stats: Dictionary) -> PackedFloat32Array:
	# La portée vulnérante est calculée par `WeaponStats.head_span`, PARTAGÉE
	# avec les créatures : c'est ce qui garantit que « seule la tête blesse »
	# veut dire la même chose des deux côtés du duel.
	var span := WeaponStats.head_span(stats, PlayerBody.HAND_ARC_RADIUS, PART_DRAW_SCALE)
	var first := span.x
	var last := span.y
	var count := clampi(int(ceil((last - first) / HEAD_SAMPLE_STEP)) + 1, 2, HEAD_SAMPLE_MAX)
	var out := PackedFloat32Array()
	for i in count:
		out.append(first + (last - first) * float(i) / float(count - 1))
	return out


## Positions des points de la tête pour la progression `u`, inertie comprise.
##
## Le retard du ressort est appliqué PROPORTIONNELLEMENT à la distance à la
## main : le bout d'une arme longue traîne, le talon du fer presque pas — c'est
## ce dégradé qui fait « fouetter » un coup lourd. Le décalage vient du même
## `_lag_offset` que le visuel, donc l'arme vue et l'arme qui touche traînent
## exactement pareil : l'invariant du système tient aussi pour l'inertie.
func _head_points(direction_id: int, u: float, grip: Vector3, camera_basis: Basis) -> PackedVector3Array:
	var out := PackedVector3Array()
	if _head_samples.is_empty():
		return out
	# Le recul de l'estoc est celui de la MAIN, en mètres : bras et arme forment
	# un bloc rigide qui avance d'un seul tenant. Une fraction du rayon de chaque
	# point ferait au contraire s'allonger l'arme pendant la poussée.
	var pull := (1.0 - MeleeAttack.THRUST_START) * PlayerBody.HAND_ARC_RADIUS
	var tip_radius: float = _head_samples[_head_samples.size() - 1]
	for distance: float in _head_samples:
		var lag := _lag_offset * TIP_LAG_FACTOR * (distance / maxf(tip_radius, 0.001))
		out.append(MeleeAttack.point_along(direction_id, u, grip, camera_basis, distance, pull) + lag)
	return out


## Stats du coup COURANT : celles de la main gauche pendant le retour d'un
## enchaînement, celles de la main forte le reste du temps. Un seul point de
## bascule, pour que la hitbox, les dégâts et le geste vu ne puissent pas se
## retrouver sur des armes différentes.
func _active_swing_stats() -> Dictionary:
	if _attack.is_offhand_strike() and not _swing_stats_off.is_empty():
		return _swing_stats_off
	return _swing_stats


func _advance_attack(delta: float) -> void:
	if not _attack.is_busy() or _camera == null or _swing_stats.is_empty():
		return
	# HIT-STOP (2026-08-02) : au contact, le geste se FIGE quelques dizaines de
	# millisecondes. C'est ce qui donne à la lame l'impression de mordre au lieu
	# de traverser, et c'est le plus gros contributeur au poids ressenti d'un
	# coup. On gèle ici, et ici seulement : la caméra, le déplacement et le tick
	# continuent — figer le joueur entier lui arracherait le contrôle en
	# récompense d'avoir touché, ce qui est exactement l'inverse du but.
	#
	# Conséquence recherchée : la fenêtre de récupération se décale d'autant.
	# Toucher coûte donc un peu de tempo, ce qui rend le coup dans le vide moins
	# ruineux par comparaison et resserre les échanges.
	#
	# Le figement est PRÉLEVÉ SUR CE DELTA, pas lu sur une horloge à part : le
	# geste reste seul maître de son propre temps (voir consume_freeze).
	delta = ImpactFeedback.consume_freeze(delta)
	if delta <= 0.0:
		return
	var weapon_stats := _active_swing_stats()
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
	var grip := _grip_position(camera_basis, _attack.is_offhand_strike())

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
		_head_samples = _head_distances(weapon_stats)
		_head_previous = _head_points(_attack.strike_direction(), 0.0, grip, camera_basis)
		# Le coup est PARTI : son coût en endurance est dû, qu'il touche ou
		# non. C'est la contrepartie qui rend le spacing intéressant — un coup
		# dans le vide se paie. La dépense elle-même est appliquée par le tick
		# (cette fonction ne modifie aucun état), d'où l'événement empilé.
		_pending_hits.append({"kind": "swing", "stats": weapon_stats})
		return
	if _attack.state != MeleeAttack.State.RELEASE or not _attack.can_still_hit:
		return

	# LA TÊTE ENTIÈRE BALAIE, pas seulement la pointe (2026-08-02) : voir
	# `_head_distances`. Chaque point échantillonné trace son propre segment
	# entre la frame précédente et celle-ci ; leur réunion approche la surface
	# réellement balayée par le fer.
	var head_now := _head_points(_attack.strike_direction(), _attack.phase_ratio, grip, camera_basis)
	var head_before := _head_previous
	_head_previous = head_now
	if head_now.is_empty() or head_before.size() != head_now.size():
		return

	# La POINTE sert de référence au décor et à la mesure du geste : c'est elle
	# qui va le plus loin, donc elle qui rencontre un mur la première.
	var tip: Vector3 = head_now[head_now.size() - 1]
	var segment_from: Vector3 = head_before[head_before.size() - 1]
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
		# élimine presque tout le monde pour le prix d'une soustraction. C'est
		# lui qui garde le coût du balayage multi-points négligeable — seules
		# les cibles à portée paient les quelques tests de boîtes.
		var cull: float = _head_samples[_head_samples.size() - 1] + 2.0
		if creature.logical_position.distance_squared_to(grip) > cull * cull:
			continue
		for i in head_now.size():
			var hit: Dictionary = creature.sweep_segment(head_before[i], head_now[i])
			if hit.is_empty():
				continue
			# Le PREMIER contact gagne, tous points confondus : c'est celui que
			# le joueur a vu toucher.
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

	# LA GARDE ADVERSE ARRÊTE LA LAME (2026-08-02). Les créatures parent
	# désormais, et une garde bien orientée annule le coup : c'est la moitié
	# défensive du duel, celle qui manquait. Le coup est CONSOMMÉ — on ne
	# retouche pas dans le même geste — et le joueur reçoit le même retour que
	# celui qu'il inflige quand il pare.
	# CHAMBRÉ PAR L'ADVERSAIRE (2026-08-02). Il est parti dans la MÊME direction
	# au bon moment : les deux armes s'entrechoquent, TON attaque est annulée et
	# la sienne poursuit sa course. C'est le pendant exact du chambering que tu
	# peux leur infliger — le geste le plus exigeant du jeu ne pouvait pas
	# rester à sens unique.
	if best.has_method("is_chambering") and best.is_chambering(_attack.strike_direction()):
		_attack.interrupt()
		_swing_stats = {}
		EventBus.ui_notification.emit("ui.combat.chambering")
		EventBus.damage_dealt.emit(best_hit["point"], 0, false, true)
		EventBus.combat_impact.emit(
			ImpactFeedback.IMPACT_CHAMBRE, best_hit["point"], 1.0)
		return

	# CRUSHTHROUGH : un marteau abattu de haut traverse la garde. C'est le seul
	# cas où une parade correcte ne suffit pas — et c'est ce qui empêche le
	# blocage systématique d'être une stratégie gagnante.
	var crushes := WeaponStats.crushes_through(weapon_stats, _attack.strike_direction())
	var target_guards: bool = best.has_method("guard_covers") \
		and best.guard_covers(_attack.strike_direction())
	if target_guards and not crushes:
		_attack.can_still_hit = false
		EventBus.ui_notification.emit("ui.combat.pare_par_adversaire")
		EventBus.damage_dealt.emit(best_hit["point"], 0, false, true)
		EventBus.combat_impact.emit(
			ImpactFeedback.IMPACT_PARE, best_hit["point"], 1.0)
		return

	# SWEET SPOT : on ne blesse qu'avec la partie tranchante. Frapper au manche
	# GLISSE et ne fait rien — c'est ce qui punit d'être trop près avec une arme
	# longue, et ce qui donne aux armes courtes leur raison d'être. La frontière
	# est désormais la JONCTION MANCHE/TÊTE du modèle, pas une fraction.
	var impact_distance: float = grip.distance_to(best_hit["point"])
	var sweet := WeaponStats.sweet_spot_factor(impact_distance,
		_head_samples[_head_samples.size() - 1],
		_head_samples[0] if _head_samples.size() > 1 else -1.0)
	# Traverser une garde n'est pas frapper à découvert : elle encaisse une part
	# du choc même quand elle cède. Sans cette réduction, le crushthrough rendrait
	# le blocage PIRE qu'inutile face à un marteau.
	if target_guards and crushes:
		sweet *= WeaponStats.CRUSHTHROUGH_DAMAGE
		EventBus.ui_notification.emit("ui.combat.garde_ecrasee")
	if sweet <= 0.001:
		# Coup GLISSANT : la frappe est consommée, aucun dégât. Il faut savoir
		# qu'on s'est trompé de distance, pas croire qu'on a raté sa visée.
		_attack.can_still_hit = false
		_pending_hits.append({"kind": "glisse", "stats": weapon_stats})
		EventBus.combat_impact.emit(
			ImpactFeedback.IMPACT_GLISSANT, best_hit["point"], 1.0)
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

	# RETOUR D'IMPACT, À LA FRAME (2026-08-02). Volontairement émis ICI et pas
	# dans `_resolve_pending_hits` : celui-ci tourne au tick, donc jusqu'à 100 ms
	# après le contact. Un hit-stop qui arrive un dixième de seconde après que la
	# lame est ressortie de la cible ne se lit plus comme un impact, mais comme
	# une saccade — c'est exactement le défaut qu'il vient corriger.
	#
	# C'est cohérent avec le partage déjà en place : la frame constate la
	# GÉOMÉTRIE (et ce retour n'est qu'une conséquence perceptive de la
	# géométrie), le tick applique l'ÉTAT. Aucun état de jeu n'est touché ici.
	#
	# La force est le même produit que celui envoyé au calcul des dégâts, moins
	# le jet de dés : le joueur sent donc la qualité de son placement — zone
	# visée, sweet spot, vitesse de rapprochement — et pas le hasard.
	var impact_force := float(best_hit["mult"]) * sweet * speed
	EventBus.combat_impact.emit(
		ImpactFeedback.IMPACT_ECRASE if (target_guards and crushes) else ImpactFeedback.IMPACT_CHAIR,
		best_hit["point"], impact_force)

	# Un coup par frappe (les armes « transperçantes » lèveront cette règle).
	_attack.can_still_hit = false
	_pending_hits.append({
		"kind": "hit",
		"creature": best, "zone": best_hit["id"], "mult": float(best_hit["mult"]),
		"point": best_hit["point"], "stats": weapon_stats,
		"hardness": _swing_hardness_off if _attack.is_offhand_strike() else _swing_hardness,
		"quality": _swing_quality_off if _attack.is_offhand_strike() else _swing_quality,
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
		creature.take_damage(float(result["damage"]))
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
	# La POSTURE entraîne sa propre compétence (GDD 6.2) : deux armes font
	# monter Dual Wielding, arme + bouclier font monter Bouclier, une arme à
	# deux mains fait monter Deux Mains. Elle s'ajoute à celle du type d'arme,
	# elle ne la remplace pas — c'est ce qui rend la spécialisation vivable.
	var style := String(STANCE_SKILL.get(combat_stance(), ""))
	if style != "" and GameData.skills.has(style):
		skills.gain_xp(style, damage * XP_STYLE_SHARE)


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


## FAMILLE DE SORTS : clé de `assemblies` pour le côté MAGIE (2026-08-03).
##
## Le menu combat sépare l'écran en deux zones INDÉPENDANTES — techniques d'arme
## à gauche, sorts à droite — sur demande de l'auteur. Chaque zone a ses propres
## slots, et un module ne peut aller que du bon côté (`book_type`).
##
## ÉCART ASSUMÉ AVEC LE GDD 5.1, qui dit que « n'importe quel module peut
## s'équiper dans n'importe quel type d'arme ». La séparation a été demandée
## explicitement après lecture de cette contrainte : elle échange la liberté de
## mélange contre deux panneaux lisibles. Le reste de la règle (slots croissants,
## coût A.6, ordre significatif) est inchangé.
const SPELL_FAMILY := "sorts"
## Compétence dont dérivent les slots de SORTS. `controle_mana` et non un
## domaine de magie : elle est universelle, là où « magie offensive » exclurait
## les grimoires de soin ou d'espace.
const SPELL_SLOT_SKILL := "controle_mana"


## Compétence d'arme correspondant à l'arme tenue en main forte, ou "" si le
## joueur n'a pas d'arme. C'est la clé de `assemblies` du côté ARMES.
func weapon_skill_id() -> String:
	if equipment == null:
		return ""
	var weapon: Dictionary = equipment.equipped("arme_1")
	if weapon.is_empty():
		return ""
	# `combat_skill` et non `skill` : c'est le nom du champ dans les
	# fonctionnalités (data/functionalities/*.json), et c'est lui qui désigne la
	# compétence d'arme dont dérive le nombre de slots.
	var functionality: Dictionary = GameData.functionalities.get(
			String(weapon.get("functionality", "")), {})
	return String(functionality.get("combat_skill", ""))


## Compétence dont dérivent les slots d'une FAMILLE. Côté armes c'est la
## compétence d'arme elle-même ; côté sorts, `controle_mana`.
func family_skill(family: String) -> String:
	return SPELL_SLOT_SKILL if family == SPELL_FAMILY else family


## Type de livre admis par une famille : un module d'arme ne va pas dans un
## sort, et réciproquement. C'est la règle que la séparation de l'écran rend
## nécessaire — sans elle, les deux zones ne seraient qu'un affichage.
func family_book_type(family: String) -> String:
	return "grimoire" if family == SPELL_FAMILY else "manuel"


## Slots de compétence disponibles pour une famille (GDD 5.1 : `2 + N/20`).
func assembly_slot_count(family: String) -> int:
	return SpellAssembly.skill_slots(skills.level(family_skill(family)))


## Slots de modules par compétence (GDD 5.1 : `2 + N/25`).
func assembly_module_count(family: String) -> int:
	return SpellAssembly.module_slots(skills.level(family_skill(family)))


## Assemblage rangé dans le slot `slot` du type d'arme `skill_id` (liste vide si
## rien). Toujours borné aux slots RÉELLEMENT disponibles : un assemblage rangé
## à un niveau élevé puis relu après une perte de niveau ne doit pas être
## lançable, mais il n'est pas effacé pour autant.
func assembly_at(skill_id: String, slot: int) -> Array:
	if slot < 0 or slot >= assembly_slot_count(skill_id):
		return []
	var slots: Array = assemblies.get(skill_id, [])
	return slots[slot] if slot < slots.size() else []


## Range un assemblage. Rejette les modules INCONNUS (on ne peut assembler que
## ce qu'on a appris dans un livre — 5.1) et tronque au nombre de slots de
## modules autorisé : c'est ici, et pas dans l'interface, que la règle tient.
func set_assembly(skill_id: String, slot: int, module_ids: Array) -> bool:
	if skill_id.is_empty() or slot < 0 or slot >= assembly_slot_count(skill_id):
		return false
	var clean: Array[String] = []
	var wanted := family_book_type(skill_id)
	for id: Variant in module_ids:
		var module_id := String(id)
		if not known_modules.has(module_id) or not GameData.modules.has(module_id):
			continue
		# CHAQUE ZONE SON TYPE (2026-08-03) : un manuel de combat ne s'assemble
		# que dans une technique d'arme, un grimoire que dans un sort. Le refus
		# vit ICI et non dans l'interface — sinon n'importe quel autre chemin
		# (sonde, triche, réseau) le contournerait.
		if String((GameData.modules[module_id] as Dictionary).get("book_type", "grimoire")) != wanted:
			continue
		clean.append(module_id)
		if clean.size() >= assembly_module_count(skill_id):
			break
	var slots: Array = assemblies.get(skill_id, [])
	while slots.size() < assembly_slot_count(skill_id):
		slots.append([] as Array[String])
	slots[slot] = clean
	assemblies[skill_id] = slots
	return true


## Coût en mana d'un assemblage, arme tenue comprise (A.6). Exposé pour que
## l'interface puisse l'AFFICHER pendant qu'on assemble : sans ce retour
## immédiat, on ne construit pas un sort, on tâtonne.
func assembly_cost(skill_id: String, slot: int) -> float:
	return SpellAssembly.mana_cost(assembly_at(skill_id, slot), known_modules,
			_held_mana_conductivity())


## Conductivité mana de l'arme en main forte (A.6 : réduit le coût des sorts).
## C'est ce qui rend la gemme d'un bâton structurante.
func _held_mana_conductivity() -> float:
	if equipment == null:
		return 0.0
	return float((equipment.equipped("arme_1") as Dictionary).get("mana_conductivity", 0.0))


## LIT un livre de l'inventaire (GDD 5.1/A.7) : jet de compétence Lecture, gain
## de modules en cas de réussite, effet d'échec sinon — et le livre est CONSOMMÉ
## dans les deux cas (« usage unique, réussite ou échec »).
##
## Retourne le résultat pour que l'interface puisse le DIRE. Une lecture qui
## échoue sans message laisserait le joueur devant un livre disparu sans rien
## comprendre — et l'échec est une mécanique voulue, pas un accident.
func read_book(obj: Dictionary) -> Dictionary:
	if not BookFactory.is_book(obj):
		return {}
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var result: Dictionary = BookFactory.resolve_reading(
			obj, skills.level("lecture"), int(stats.get("perception", 5)), rng)

	# Le livre part AVANT l'application des effets : un échec qui invoque un
	# ennemi ne doit pas pouvoir laisser le livre dans l'inventaire si l'effet
	# interrompt la suite.
	inventory.remove_object_units(obj, 1)

	# La Lecture progresse À L'USAGE (façon Elin/Elona, 5.1), y compris sur un
	# échec : on apprend en se cassant les dents. L'échec rapporte moins.
	skills.gain_xp("lecture", 12.0 if result.get("reussite", false) else 4.0)

	if result.get("reussite", false):
		for module_id: String in (result["modules"] as Array):
			# Un module DÉJÀ CONNU monte d'un niveau au lieu d'être ignoré
			# (5.1 : « les modules montent de niveau, sans plafond »). Sans
			# cela, tout livre en double serait du butin mort.
			known_modules[module_id] = int(known_modules.get(module_id, -1)) + 1
	else:
		_apply_reading_failure(result.get("echec", {}))
	# Signature IMPOSÉE par EventBus (book_id, success, reader) : le signal
	# préexistait au système de livres. On lui donne ce qu'il attend et on rend
	# le détail à l'appelant.
	EventBus.book_read.emit(String(obj.get("item_id", "")), bool(result.get("reussite", false)), self)
	return result


## Applique l'effet d'un échec de lecture (table en données, GDD A.7).
func _apply_reading_failure(failure: Dictionary) -> void:
	if failure.is_empty():
		return
	match String(failure.get("effet", "")):
		"mana":
			mana.spend(absf(float(failure.get("valeur", 0.0))), 0)
		"etourdi", "confusion":
			# VRAI STATUT depuis le 2026-08-03 (F.4). C'était un compteur privé,
			# stand-in assumé faute de système de statuts — il ne bloquait que
			# les modules, ne se sauvegardait pas et n'était visible nulle part.
			statuses.apply(String(failure.get("effet", "etourdi")),
					int(float(failure.get("duree_s", 5.0)) * 10.0), 1.0)
		"invocation_hostile":
			# `get_position_for_ai` et non `global_position` : Player est un Node
			# pur (la position vit sur la caméra), pas un Node3D.
			CreatureManager.spawn("bandit", get_position_for_ai() + Vector3(2.0, 0.0, 2.0))


## Ticks d'étourdissement restants (échec de lecture). Décompté dans _physics.
var _reading_stun_ticks := 0


## Les trois touches de lancement pointent sur les TROIS PREMIERS SLOTS DE
## COMPÉTENCE du type d'arme tenu (5.1). Elles remplacent le loadout figé de
## trois modules codés en dur, qui n'avait plus de sens dès lors qu'un sort est
## un assemblage rangé dans un slot d'arme.
##
## L'assemblage lié à la HOTBAR reste lançable autrement (voir
## `cast_selected_assembly`) : les deux chemins mènent au même code.
func _cast_from_key(index: int) -> void:
	var skill_id := weapon_skill_id()
	if skill_id.is_empty():
		return
	cast_assembly(skill_id, index)


## Lance l'ASSEMBLAGE actuellement en main (5.1/A.6). Remplace le lancement d'un
## module isolé : un sort est désormais une SUITE ORDONNÉE de modules, compilée
## par SpellAssembly, et c'est l'ordre qui décide de ce qui part.
##
## Le coût est payé UNE FOIS pour tout l'assemblage, modificateurs compris — un
## assemblage bâclé coûte donc réellement cher (A.6). Le déficit inflige la
## surchauffe (A.5), comme pour tout lancer.
func cast_selected_assembly() -> bool:
	var entry := _selected_entry()
	if String(entry.get("kind", "")) != "assemblage":
		return false
	return cast_assembly(String(entry.get("skill", "")), int(entry.get("slot", -1)))


func cast_assembly(skill_id: String, slot: int) -> bool:
	# ÉTOURDI / CONFUS : on ne lance pas (F.4). Le déplacement et la mêlée
	# restent possibles — c'est la fiche du statut qui décide du reste, par ses
	# modificateurs, et non ce point d'appel.
	if _module_cooldown_ticks > 0 or statuses.has("etourdi") or statuses.has("confusion"):
		return false
	var module_ids := assembly_at(skill_id, slot)
	if module_ids.is_empty():
		return false
	var compiled := SpellAssembly.compile(module_ids, known_modules)
	var casts: Array = compiled.get("casts", [])
	if casts.is_empty():
		return false

	var overheat := mana.spend(assembly_cost(skill_id, slot), skills.level("controle_mana"))
	if overheat > 0.0:
		health = maxf(0.0, health - overheat)
	_module_cooldown_ticks = 5

	_execute_casts(casts)

	# MONTÉE DE NIVEAU À L'USAGE (5.1, sans plafond). Chaque module qui a
	# réellement participé est crédité, y compris ceux enfouis derrière un
	# déclencheur — sinon les charges utiles ne progresseraient jamais et
	# construire un sort profond serait puni.
	for module_id: String in SpellAssembly.modules_fired(compiled):
		known_modules[module_id] = int(known_modules.get(module_id, 0)) + 1
	# L'XP VA À LA COMPÉTENCE, PAS À LA FAMILLE. Côté sorts, la famille s'appelle
	# « sorts » et n'est PAS une compétence : `data/skills/` n'en contient aucune
	# de ce nom (les vraies sont `controle_mana`, `magie_offensive`,
	# `magie_defensive`). `gain_xp` se contentait d'un avertissement et rendait
	# la main — lancer des sorts ne faisait donc monter STRICTEMENT RIEN, en
	# silence, depuis que les deux panneaux ont été séparés. `family_skill`
	# existait déjà et fait exactement cette traduction ; elle n'était simplement
	# pas appelée ici.
	skills.gain_xp(family_skill(skill_id), 6.0)
	return true


## Exécute un niveau de l'arbre compilé.
##
## PORTÉE ACTUELLE, ET C'EST UNE LIMITE RÉELLE : seuls les effets qui BLESSENT
## ou qui SOIGNENT sont simulés. Les projectiles ne volent pas encore (ils
## touchent la cible visée immédiatement), les zones ne persistent pas, et la
## mobilité (clignotement, charge) n'est pas appliquée. La compilation, le coût,
## l'ordre, le multi-cast et les déclencheurs sont eux complets et testés :
## c'est la couche de PRÉSENTATION qui manque, pas la grammaire.
## `origin` : d'où part cette salve. Vaut l'œil du joueur au premier niveau, et
## le POINT D'IMPACT du porteur pour une charge utile de déclencheur — c'est ce
## qui fait qu'une explosion déclenchée éclate là où le projectile est arrivé,
## et non dans la main du lanceur.
func _execute_casts(casts: Array, depth: int = 0, origin: Vector3 = Vector3.INF) -> void:
	if origin == Vector3.INF:
		origin = _camera.global_position if _camera != null else get_position_for_ai()
	for cast: Dictionary in casts:
		var trigger: Dictionary = cast.get("trigger", {})
		var volley: Array = cast.get("volley", [])
		for index in volley.size():
			var shot: Dictionary = volley[index]
			# LE DÉCLENCHEUR EST PORTÉ PAR LE PREMIER TIR DE LA VOLÉE, pas par
			# tous : sinon une volée de trois projectiles déclencherait sa charge
			# utile trois fois, et un multi-cast multiplierait silencieusement
			# les dégâts d'un déclencheur au lieu de multiplier ses porteurs.
			var carried: Dictionary = trigger if index == 0 else {}
			_apply_effect(String(shot["module"]), float(shot.get("power", 0.0)),
					shot.get("mods", {}), carried, depth, origin, index, volley.size())


## Teintes de projectile par domaine. Un sort doit se RECONNAÎTRE en vol :
## sans couleur, une boule de feu et un éclat de glace sont le même bâtonnet
## brun, et tout le travail d'assemblage devient invisible en jeu.
const SPELL_COLORS := {
	"feu": Color(1.0, 0.45, 0.12),
	"eau_glace": Color(0.45, 0.80, 1.0),
	"foudre": Color(0.95, 0.92, 0.35),
	"terre": Color(0.62, 0.50, 0.34),
	"vie": Color(0.40, 0.95, 0.50),
	"arcane": Color(0.65, 0.45, 1.0),
	"espace": Color(0.85, 0.85, 0.95),
	"corruption": Color(0.55, 0.12, 0.45),
}


func _apply_effect(module_id: String, power: float, mods: Dictionary = {},
		trigger: Dictionary = {}, depth: int = 0, origin: Vector3 = Vector3.ZERO,
		index: int = 0, volley_size: int = 1) -> void:
	var module: Dictionary = GameData.modules.get(module_id, {})
	if module.is_empty():
		return
	var tags: Array = module.get("tags", [])

	if "soin" in tags or "vie" in tags:
		health = minf(health_max, health + power * 0.5)
		_fire_payload(trigger, depth, origin)
		return

	# PROJECTILE : il VOLE désormais réellement (2026-08-03). C'est ce qui donne
	# un effet observable à `vitesse`, `portee`, `guidage` et `ricochet`, et ce
	# qui permet au déclencheur de partir à l'IMPACT plutôt qu'aussitôt après.
	if "projectile" in tags:
		_launch_spell_projectile(module_id, module, power, mods, trigger, depth,
				index, volley_size)
		return

	# PROTECTION / POSTURE / ENTRAVE / MOBILITÉ (2026-08-03) : ils passent
	# désormais par les STATUTS (F.4) et par un déplacement réel, au lieu de ne
	# rien produire. La table ci-dessous est la seule chose qui relie un module à
	# son statut — la mécanique, elle, est entièrement en données.
	if _apply_non_damaging(module_id, module, power, tags):
		_fire_payload(trigger, depth, origin)
		return
	if not module.has("degats_des"):
		# Reste ce qui n'a toujours pas de simulation (zones persistantes). Le
		# déclencheur part quand même, sinon un assemblage bâti sur un effet non
		# simulé perdrait silencieusement toute sa charge utile.
		_fire_payload(trigger, depth, origin)
		return
	if _target_creature == null or not is_instance_valid(_target_creature):
		_fire_payload(trigger, depth, origin)
		return
	var damage := CombatResolver.roll_dice(String(module["degats_des"])) + int(power * 0.1)
	# Même point d'entrée que la mêlée : un module qui blesse doit staggerer
	# comme une lame, sinon on pourrait couper un wind-up à l'épée mais pas
	# au sort — une exception que rien ne justifierait.
	_target_creature.take_damage(float(damage))
	_target_creature.provoke()
	if _target_creature.is_dead():
		_creature_defeated(_target_creature)
	_fire_payload(trigger, depth, _target_creature.logical_position)


## Facteur de vitesse de déplacement, statuts compris (F.4). Interrogé par la
## caméra à chaque frame : elle porte le mouvement mais ignore tout des statuts.
func movement_multiplier() -> float:
	return clampf(modifiers.apply(1.0, "vitesse_deplacement"), 0.0, 3.0)


## Quel STATUT un module pose-t-il sur son lanceur ? Table explicite plutôt
## qu'une convention de nommage : un module et un statut sont deux notions
## distinctes, et plusieurs modules peuvent poser le même statut (la carapace de
## roche et une potion de peau de pierre donnent le même effet).
const MODULE_STATUS := {
	"carapace_de_roche": "peau_de_pierre",
	"garde_de_fer": "peau_de_pierre",
	"bouclier_arcane": "peau_de_pierre",
	"posture_agile": "hate",
	"regeneration": "regeneration",
}


## Effets qui ne blessent pas : statuts posés sur soi, entraves posées autour,
## déplacements. Retourne true si le module a été traité ici.
func _apply_non_damaging(module_id: String, module: Dictionary, power: float,
		tags: Array) -> bool:
	var params: Dictionary = module.get("params", {})

	# 1. STATUT SUR SOI (protection, posture, régénération).
	if MODULE_STATUS.has(module_id):
		# La DURÉE vient de la fiche du module (`duree`, en secondes de jeu) et
		# la PUISSANCE de son niveau : monter un module allonge et renforce son
		# effet, comme pour tout le reste (A.6).
		var ticks := int(float(params.get("duree", 10.0)) * 10.0)
		statuses.apply(String(MODULE_STATUS[module_id]), ticks, 1.0 + power * 0.02)
		return true

	# 2. ZONE PERSISTANTE (nappe de flammes, emprise du gel). Elle DURE, ce qui
	# donne enfin un sens au paramètre `duree` de ces modules : jusqu'ici leur
	# effet s'appliquait à l'instant du lancer et disparaissait, autrement dit
	# une nappe n'était qu'une explosion.
	#
	# Posée AU SOL DEVANT le lanceur et non sur lui : une nappe de flammes
	# centrée sur soi est un suicide, pas un sort.
	if "zone" in tags and _camera != null:
		var aim := -_camera.global_basis.z
		aim.y = 0.0
		var here := get_position_for_ai()
		var centre: Vector3 = here + (aim.normalized() * 4.0 if aim.length_squared() > 0.001 else Vector3.ZERO)
		var status_id := "brulure" if "feu" in tags else ("ralentissement" if "entrave" in tags else "")
		ZoneManager.spawn(centre,
				float(params.get("rayon", 3.0)),
				int(float(params.get("duree", 6.0)) * 10.0),
				status_id,
				String(module.get("degats_des", "")),
				1.0 + power * 0.02,
				Color(1.0, 0.45, 0.12, 0.35) if "feu" in tags else Color(0.45, 0.8, 1.0, 0.3),
				self)
		return true

	# 3. ENTRAVE INSTANTANÉE AUTOUR DE SOI, pour les modules d'entrave qui ne
	# sont pas des zones : ralentit les créatures dans le rayon, sur-le-champ.
	if "entrave" in tags:
		var radius := float(params.get("rayon", 3.0))
		var here := get_position_for_ai()
		for creature in CreatureManager.creatures:
			if not is_instance_valid(creature) or creature.is_dead():
				continue
			if creature.dimension != WorldManager.active_dimension:
				continue
			if creature.logical_position.distance_to(here) > radius:
				continue
			if creature.has_method("apply_status"):
				creature.apply_status("ralentissement", 0, 1.0)
		return true

	# 4. MOBILITÉ (clignotement, charge d'épaule) : un déplacement réel, pas un
	# statut. On avance dans l'axe du REGARD, en s'arrêtant au premier obstacle —
	# se téléporter dans la roche est le seul résultat inacceptable.
	if "mobilite" in tags and _camera != null:
		var distance := float(params.get("distance", 6.0))
		var aim := -_camera.global_basis.z
		aim.y = 0.0
		if aim.length_squared() < 0.001:
			return true
		var from := _camera.global_position
		var to := from + aim.normalized() * distance
		if WorldManager.line_blocked(from, to):
			# Obstacle : on rabote jusqu'à trouver un point libre plutôt que
			# d'annuler le sort — un clignotement qui ne fait rien mais coûte sa
			# mana serait pire qu'un clignotement court.
			# `: Vector3` explicite : itérer un tableau littéral donne un
			# Variant, dont l'inférence est traitée comme une erreur ici.
			for fraction: float in [0.75, 0.5, 0.25]:
				var candidate: Vector3 = from + aim.normalized() * distance * fraction
				if not WorldManager.line_blocked(from, candidate):
					to = candidate
					break
		if _camera.has_method("teleport_to"):
			_camera.teleport_to(to)
		else:
			_camera.global_position = to
		return true
	return false


## Lance un projectile de sort. Les modificateurs accumulés par l'assemblage
## deviennent ici des paramètres de vol RÉELS — c'est le point où l'ordre des
## slots cesse d'être une abstraction.
func _launch_spell_projectile(module_id: String, module: Dictionary, power: float,
		mods: Dictionary, trigger: Dictionary, depth: int,
		index: int, volley_size: int) -> void:
	if _camera == null:
		return
	var params: Dictionary = module.get("params", {})
	var aim := -_camera.global_basis.z
	# UNE VOLÉE S'ÉVENTAILLE. Trois projectiles superposés se lisent comme un
	# seul et rendent le multi-cast invisible : c'est l'écart qui le montre.
	if volley_size > 1:
		var spread := deg_to_rad(7.0) * (float(index) - float(volley_size - 1) * 0.5)
		aim = aim.rotated(Vector3.UP, spread)
	var stats := {
		"vitesse_projectile": float(params.get("vitesse", 20.0)) + float(mods.get("vitesse", 0.0)),
		"dice": String(module.get("degats_des", "1d6")),
		"penetration": 0.0,
		"skill": weapon_skill_id(),
		"module": module_id,
	}
	var domain := ""
	for d: String in (module.get("grimoire_domains", []) as Array):
		if SPELL_COLORS.has(d):
			domain = d
			break
	var payload := trigger
	var carrier_depth := depth
	ProjectileManager.launch(
		_camera.global_position + aim * 0.6, aim, stats,
		1.0 + power * 0.05, 1.0, self,
		{
			"gravity": false,
			"range": float(params.get("portee", 25.0)) + float(mods.get("portee", 0.0)),
			"homing": float(mods.get("guidage", 0.0)),
			"bounces": int(mods.get("rebonds", 0.0)),
			"color": SPELL_COLORS.get(domain, Color(0.8, 0.8, 0.9)),
			# LE DÉCLENCHEUR PART D'ICI, au point où la course s'achève.
			"on_end": func(point: Vector3, _victim: Variant) -> void:
				_fire_payload(payload, carrier_depth, point),
		})


## Fait partir la charge utile d'un déclencheur, depuis `point`.
func _fire_payload(trigger: Dictionary, depth: int, point: Vector3) -> void:
	if trigger.is_empty() or depth >= SpellAssembly.MAX_DEPTH:
		return
	_execute_casts(trigger.get("casts", []), depth + 1, point)


# --- Récolte (A.2, par ticks) ---

## Temps de jeu écoulé SANS simulation (voyage rapide). On rattrape ce qui
## évolue linéairement, et rien d'autre.
##
## La FAMINE n'inflige délibérément pas ses dégâts ici : elle se contente de
## consommer les réserves. Appliquer des milliers de ticks de dégâts de faim
## ferait mourir en arrivant un joueur parti en bonne santé, ce qu'aucune
## interface ne lui aurait laissé prévoir — un voyage rapide doit coûter des
## vivres, pas la vie.
func _on_ticks_skipped(count: int) -> void:
	hunger = maxf(0.0, hunger - HUNGER_DECAY_PER_TICK * count)
	fatigue = maxf(0.0, fatigue - FATIGUE_DECAY_PER_TICK * count)
	mana.skip_ticks(count)


func _on_tick(_tick_index: int) -> void:
	mana.on_tick()
	# STATUTS (F.4) : le tracker rend les dégâts périodiques, le joueur les
	# applique par SON chemin de dégâts — un statut ne doit pas contourner le
	# stagger ni la mort.
	var periodic := statuses.tick()
	if periodic > 0.0:
		take_damage(int(ceil(periodic)))
	elif periodic < 0.0:
		health = minf(health_max, health - periodic)
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
	if _reading_stun_ticks > 0:
		_reading_stun_ticks -= 1
	if not _mining or not _target_valid:
		_progress = 0.0
		_bouncing = false
		return
	var material_id := WorldManager.block_at_world(_target)
	if material_id == 0:
		return
	var mat_name: String = GameData.material_by_runtime[material_id]
	var mat: Dictionary = GameData.materials[mat_name]
	# Blocs INCASSABLES : aucun outil n'en vient à bout. Un simple `durete` très
	# élevée ne suffirait pas — la progression sans plafond (A.1) finirait par
	# produire un outil capable de la percer.
	#
	# DEUX RÈGLES, et la distinction compte (2026-08-02). Le tag protège une
	# MATIÈRE (matériaux démoniaques) ; la seconde protège un LIEU. Depuis que
	# la tour de donjon est bâtie en pierre taillée — un matériau de
	# construction que le joueur fabrique et pose lui-même — l'incassabilité ne
	# pouvait plus être portée par le matériau : la rendre incassable aurait
	# rendu toute construction du joueur indestructible. C'est la STRUCTURE
	# qu'il faut sceller (GDD 3.5 : « structure d'entrée scellée »), pas le
	# granit taillé.
	if "incassable" in (mat.get("tags", []) as Array) or WorldManager.is_sealed_structure(_target):
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
		# --- Arbre : casser N'IMPORTE LEQUEL de ses blocs l'abat en entier
		# (2026-08-03, demande de l'auteur). C'était réservé à la BASE : couper
		# une branche ou une feuille ne faisait tomber qu'un cube, et l'arbre
		# restait suspendu en l'air, ce qui est le défaut classique du bûcheronnage
		# voxel.
		#
		# La requête est INVERSE (`tree_containing`) et ne coûte presque rien : les
		# arbres sont déterministes, on régénère les quelques candidats dont
		# l'empreinte peut couvrir ce bloc au lieu de tenir une liste d'entités.
		var tree := WorldManager.generator.tree_containing(_target.x, _target.y, _target.z) if WorldManager.generator != null else {}
		if not tree.is_empty():
			# LE VOLUME, PAS LE NOMBRE DE BLOCS. `wood_positions` liste les blocs
			# touchés par du bois, brindilles de 1/64 de bloc comprises : depuis
			# que les branches sont détaillées, un chêne en compte des centaines
			# et l'abattage aurait demandé vingt fois le temps prévu, pour un
			# butin vingt fois trop gros.
			var wood_count := maxi(1, roundi(float(tree.get("wood_volume",
					(tree["wood_positions"] as Array).size()))))
			# LE TEMPS ET LE BUTIN SUIVENT LE BOIS, PAS LE BLOC FRAPPÉ. Sans
			# cette bascule, abattre par une feuille — molle, et souvent le bloc
			# le plus accessible — coûtait une fraction du temps de la même
			# coupe au tronc, et créditait des feuilles au lieu de bûches. On
			# abat un arbre, pas un feuillage : c'est la dureté du bois qui
			# décide, où qu'on frappe.
			var species: Dictionary = GameData.trees.get(String(tree.get("species_id", "")), {})
			var wood_name := String(species.get("wood_material", mat_name))
			var wood_mat: Dictionary = GameData.materials.get(wood_name, mat)
			var wood_hardness := float((wood_mat.get("stats", {}) as Dictionary).get("durete", hardness))
			var wood_skill := String((wood_mat.get("harvest", {}) as Dictionary).get("skill", skill_id))
			var wood_factor := PlayerSkills.skill_factor(skills.level(wood_skill))
			var fell_time := wood_hardness / (tool_hardness * tool_quality * wood_factor)
			_required = fell_time * wood_count
			_progress += TickManager.TICK_DT
			if _progress < _required:
				return
			_progress = 0.0
			for pos: Vector3i in (tree["blocks"] as Dictionary):
				WorldManager.set_block(pos, 0)
			inventory.add_material(wood_name, wood_count * (1 + floori(skills.level(wood_skill) / 10.0)))
			skills.gain_xp(wood_skill, wood_hardness * wood_count)
			# POUSSES : abattre un arbre en rend une ou deux de son essence. C'est
			# la seule source non-triche, et sans elle la sylviculture serait un
			# système sans porte d'entrée — on pourrait replanter uniquement ce
			# qu'on n'a pas encore coupé.
			var sapling := SaplingManager.material_for(String(tree.get("species_id", "")))
			if GameData.materials.has(sapling):
				inventory.add_material(sapling, 1 + (1 if randf() < 0.5 else 0))
			# Cas spécial baobab (tronc creux) : l'eau qu'il contenait se
			# libère à l'emplacement de la base une fois l'arbre abattu.
			if "contient_liquide" in (tree["special_tags"] as Array):
				var water_id: int = GameData.material_runtime_ids.get("eau", 0)
				if water_id != 0:
					WorldManager.set_block(_target, water_id)
			return
		# --- Foreuse : un carré de blocs d'un seul coup ---
		var area := int(tool.get("mining_area", 1))
		if area > 1:
			_mine_area(area, tool_hardness, tool_quality)
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
	# ASSEMBLAGES (5.1) : un sort ou une attaque spéciale se lie à un slot de
	# hotbar comme n'importe quel objet (choix de l'auteur, 2026-08-03). Seuls
	# les assemblages NON VIDES sont proposés — lier un slot vide ne donnerait
	# qu'une case morte dans la barre.
	for skill_id: String in assemblies:
		var slots: Array = assemblies[skill_id]
		for slot in slots.size():
			if (slots[slot] as Array).is_empty():
				continue
			entries.append({"kind": "assemblage", "skill": skill_id, "slot": slot})
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
	# L'emplacement de COMBAT ne se lie pas : il suit l'arme équipée. Refuser
	# ici plutôt que dans l'UI garantit qu'aucun chemin (menu, sonde, réseau) ne
	# puisse y coller une pioche et faire mentir la posture.
	if index % HOTBAR_SLOTS == COMBAT_SLOT:
		return
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
		"assemblage":
			# Liée par (compétence, slot) et non par contenu : réordonner les
			# modules d'un assemblage ne doit pas le faire tomber de la barre.
			return {"kind": "assemblage", "skill": String(entry.get("skill", "")),
				"slot": int(entry.get("slot", -1))}
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
		"assemblage":
			var skill_id := String(binding.get("skill", ""))
			var slot := int(binding.get("slot", -1))
			# Un assemblage VIDÉ depuis le menu, ou devenu hors slots après une
			# perte de niveau, rend une entrée vide : la barre montre un trou
			# plutôt qu'un sort qui ne partirait pas.
			if assembly_at(skill_id, slot).is_empty():
				return {}
			return {"kind": "assemblage", "skill": skill_id, "slot": slot}
	return {}


## Les 9 emplacements de la banque `bank`, dans l'ordre. Un emplacement non
## lié (ou dont la cible a disparu) rend un dictionnaire VIDE — la hotbar
## affiche un trou, elle ne décale pas les objets suivants.
func hotbar_entries(bank: int = -1) -> Array[Dictionary]:
	var start := (active_hotbar if bank < 0 else bank) * HOTBAR_SLOTS
	var result: Array[Dictionary] = []
	for slot in HOTBAR_SLOTS:
		if slot == COMBAT_SLOT:
			# Réservé au combat : il suit l'ÉQUIPEMENT, pas une liaison.
			var main_hand: Dictionary = equipment.equipped("arme_1")
			result.append({} if main_hand.is_empty() else {"kind": "object", "object": main_hand})
			continue
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


## L'EMPLACEMENT 1 EST CELUI DU COMBAT (2026-08-02, demande de l'auteur). Il
## n'est lié à rien : il montre en permanence l'ARME ÉQUIPÉE en main forte, dans
## toutes les banques. C'est ce qui réconcilie deux systèmes qui coexistaient
## sans se parler — l'équipement (arme_1 / arme_2, avec sa posture et ses
## compétences de style) et la hotbar (ce qu'on tient). On ne peut plus se
## retrouver avec un bouclier équipé et une pioche en main en croyant se battre.
const COMBAT_SLOT := 0


func _selected_entry() -> Dictionary:
	if selected_slot == COMBAT_SLOT:
		var main_hand: Dictionary = equipment.equipped("arme_1")
		return {} if main_hand.is_empty() else {"kind": "object", "object": main_hand}
	var binding: Variant = hotbar_bindings.get(active_hotbar * HOTBAR_SLOTS + selected_slot)
	return _resolve_binding(binding) if binding != null else {}


## FOREUSE : mine un carré de `side` blocs de côté, d'un seul geste.
##
## L'ORIENTATION SUIT LA FACE VISÉE. Un carré toujours horizontal creuserait
## un puits quand on attaque un mur, et une tranchée quand on attaque le sol :
## la seule règle qui se comporte comme un outil, c'est que le carré soit
## PERPENDICULAIRE au regard, donc dans le plan de la face touchée.
##
## Pour un côté PAIR il n'existe pas de centre exact ; le carré est décalé de
## `-(side - 1) / 2`, ce qui met le bloc visé au coin bas-gauche en 2×2 et le
## garde au centre en 3×3 et 5×5. C'est prévisible, ce qui vaut mieux qu'exact.
func _mine_area(side: int, tool_hardness: float, tool_quality: float) -> void:
	# Base du plan : les deux axes qui ne sont pas celui de la normale.
	var normal := _target_normal
	var axis_u := Vector3i(0, 1, 0)
	var axis_v := Vector3i(0, 0, 1)
	if absi(normal.y) == 1:
		axis_u = Vector3i(1, 0, 0)
		axis_v = Vector3i(0, 0, 1)
	elif absi(normal.z) == 1:
		axis_u = Vector3i(1, 0, 0)
		axis_v = Vector3i(0, 1, 0)

	var offset := -(side - 1) / 2
	var targets: Array[Vector3i] = []
	var total_time := 0.0
	for du in side:
		for dv in side:
			var pos := _target + axis_u * (du + offset) + axis_v * (dv + offset)
			var id := WorldManager.block_at_world(pos)
			if id == 0:
				continue
			var name: String = GameData.material_by_runtime[id]
			var block: Dictionary = GameData.materials[name]
			# Les blocs qu'aucun outil ne perce sont SAUTÉS, pas bloquants : une
			# foreuse arrêtée net parce qu'un coin du carré touche la paroi d'un
			# donjon serait inutilisable là où elle sert le plus.
			if "incassable" in (block.get("tags", []) as Array) \
					or WorldManager.is_sealed_structure(pos):
				continue
			var block_hardness := float(block["stats"]["durete"])
			# Chaque bloc du carré doit être à la portée de l'outil, avec la même
			# règle d'irrécoltabilité qu'un coup normal (A.2) : une foreuse ne
			# doit pas servir à contourner la stratification 3.2.
			if tool_hardness * tool_quality < block_hardness * 0.5:
				continue
			var block_skill := String(block["harvest"]["skill"])
			var block_factor := PlayerSkills.skill_factor(skills.level(block_skill))
			total_time += block_hardness / (tool_hardness * tool_quality * block_factor)
			targets.append(pos)

	if targets.is_empty():
		_bouncing = true
		_progress = 0.0
		return

	# LE TEMPS EST CELUI DES BLOCS, REMISÉ. Offrir le carré gratuitement ferait
	# de la plus grosse foreuse un outil vingt-cinq fois plus rapide, ce qui
	# viderait la progression de récolte de son sens ; le faire payer plein tarif
	# n'apporterait que le confort de ne pas viser. La remise est le compromis :
	# une foreuse est franchement plus rapide, sans être gratuite.
	_required = total_time * DRILL_TIME_DISCOUNT
	_progress += TickManager.TICK_DT
	if _progress < _required:
		return
	_progress = 0.0

	for pos: Vector3i in targets:
		var id := WorldManager.block_at_world(pos)
		if id == 0:
			continue  # Disparu entre la mesure et le coup (fluide, autre joueur).
		var name: String = GameData.material_by_runtime[id]
		var block: Dictionary = GameData.materials[name]
		var subdivided := not WorldManager.subdiv_grid_at(pos).is_empty()
		var credits := _region_credits(pos, Vector3i.ZERO, SubdivGrid.SIZE) if subdivided else {}
		if not WorldManager.set_block(pos, 0):
			continue
		var block_skill := String(block["harvest"]["skill"])
		if subdivided:
			for material_id: String in credits:
				inventory.add_volume(material_id, credits[material_id])
		else:
			inventory.add_material(name, 1 + floori(skills.level(block_skill) / 10.0))
		skills.gain_xp(block_skill, float(block["stats"]["durete"]))


## Remise de temps d'une foreuse : le carré coûte 60 % du temps qu'auraient
## coûté ses blocs un par un.
const DRILL_TIME_DISCOUNT := 0.6


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
		# POSER UNE POUSSE, C'EST LA PLANTER. Le bloc seul ne saurait pas dire
		# quand il a été mis en terre, ni quelle essence il deviendra : c'est le
		# registre des pousses qui porte cet état, et il doit être prévenu au
		# moment de la pose, pas après coup par une inspection du monde.
		var species_id := SaplingManager.species_of(mat_name)
		if species_id != "":
			if SaplingManager.plant(_placement_cell(), species_id):
				inventory.remove_material(mat_name, 1)
			return
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


# --- Objets posés au sol (Ctrl + clic droit, 2026-08-06) ---
#
# UN OBJET N'EST PAS UN DROP. Une épée posée est un BLOC : elle occupe sa case,
# on marche autour, on la voit de loin, elle survit au rechargement comme le
# reste du monde. Le drop existe déjà et répond à un autre besoin (butin de
# mort, expiration au bout d'un jour).
#
# Le bloc porte le TYPE (`objet_<item_id>`, une entrée de palette par type) et
# `PlacedItemManager` porte l'EXEMPLAIRE. La reprise rend l'instance stockée
# telle quelle : poser puis reprendre ne doit jamais réparer ni améliorer quoi
# que ce soit.

## Ctrl + clic droit : reprendre ce qu'on vise, sinon poser ce qu'on tient.
##
## LA REPRISE PASSE EN PREMIER. Sans ça, poser un objet devant soi puis vouloir
## le reprendre reposerait le suivant par-dessus, et la seule façon de récupérer
## le premier serait de le miner.
func _try_place_or_take_object() -> void:
	if _try_take_object():
		return
	_try_place_object()


func _try_take_object() -> bool:
	if not _target_valid:
		return false
	var instance := PlacedItemManager.take(_target)
	if instance.is_empty():
		return false
	# ORDRE OBLIGATOIRE : `take` a déjà effacé l'entrée AVANT que le bloc ne
	# tombe. `PlacedItemManager` écoute `block_destroyed` pour rendre au sol
	# l'objet d'un bloc miné par accident ; effacer après aurait donc fait
	# tomber une COPIE au sol en plus de celle rendue à l'inventaire.
	WorldManager.set_block(_target, 0)
	inventory.add_object(instance)
	EventBus.ui_notification.emit("ui.toast.objet_repris")
	return true


func _try_place_object() -> bool:
	if not (_target_valid and _target_normal != Vector3i.ZERO):
		return false
	# UN OBJET ÉQUIPÉ NE SE POSE PAS. L'emplacement de combat montre l'arme
	# portée, pas une ligne d'inventaire : la retirer par ce chemin laisserait
	# l'équipement pointer sur un objet qui n'est plus nulle part.
	if selected_slot == COMBAT_SLOT:
		EventBus.ui_notification.emit("ui.toast.objet_equipe")
		return false
	var entry := _selected_entry()
	if entry.get("kind", "") != "object":
		return false
	var held: Dictionary = entry["object"]
	var cell := _placement_cell()
	if cell.y < WorldManager.WORLD_Y_MIN or cell.y > WorldManager.WORLD_Y_MAX:
		return false
	if WorldManager.block_at_world(cell) != 0:
		return false
	var material_id := PlacedItemManager.material_for(held)
	var runtime_id: int = GameData.material_runtime_ids.get(material_id, 0)
	if runtime_id == 0:
		return false
	# UNE SEULE UNITÉ. Une pile de dix quartiers de viande pose un quartier :
	# poser la pile entière dans un bloc rendrait dix objets pour une reprise,
	# ce qui est la même faille que la réparation gratuite, en plus gros.
	var placed_instance := held.duplicate(true)
	if placed_instance.has("count"):
		placed_instance["count"] = 1
	if not inventory.remove_object_units(held, 1):
		return false
	# Le registre AVANT le bloc : `set_block` remaille et émet ses signaux
	# immédiatement, et un abonné qui lirait le monde entre les deux verrait un
	# bloc d'objet dont personne ne sait quel objet il est.
	PlacedItemManager.remember(cell, placed_instance)
	if not WorldManager.set_block(cell, runtime_id):
		PlacedItemManager.forget(cell)
		inventory.add_object(placed_instance)  # Remboursé.
		return false
	return true


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
## Retourne true si un butin a été ramassé — c'est ce qui permet à
## `_try_interact` d'enchaîner sur le bloc puis sur le dialogue.
func _try_pickup() -> bool:
	var index := DropManager.nearest_cache(get_position_for_ai())
	if index < 0:
		return false
	var count: int = (DropManager.caches[index]["objects"] as Array).size()
	var recovered := DropManager.collect(index, inventory)
	gold += recovered
	EventBus.ui_notification.emit(tr("ui.toast.ramasse").format({
		"objets": str(count), "or": str(recovered)}))
	return true


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


## Équipe une instance dans un emplacement PRÉCIS (glisser-déposer sur la
## silhouette, 2026-08-02). `equip_instance` laisse le premier emplacement libre
## décider ; ici c'est le joueur qui a visé, et son choix prime.
##
## Retourne false si la pièce n'a rien à faire là. Les deux refus qui comptent :
## une arme à DEUX MAINS ne peut pas aller en main gauche (elle occupe déjà les
## deux), et une pièce ne peut pas atterrir dans un emplacement d'un autre
## groupe — un casque sur un doigt.
func equip_instance_in_slot(instance: Dictionary, slot: String) -> bool:
	var item: Dictionary = GameData.items.get(instance.get("item_id", ""), {})
	var wanted := String(item.get("equip_slot", ""))
	var group: Array = Equipment.SLOT_GROUPS.get(wanted, [])
	if slot != wanted and not (slot in group):
		EventBus.ui_notification.emit("ui.toast.pas_equipable")
		return false
	if slot == "arme_2" and int(item.get("hands", 1)) >= 2:
		EventBus.ui_notification.emit("ui.toast.deux_mains_occupe")
		return false
	inventory.objects.erase(instance)
	var replaced: Dictionary = equipment.slots.get(slot, {})
	equipment.slots[slot] = instance
	if not replaced.is_empty():
		inventory.add_object(replaced)
	_clamp_selection()
	EventBus.ui_notification.emit(tr("ui.toast.equipe").format({
		"item": tr(String(instance.get("name_key", "")))}))
	return true


# --- ZONES DE COUP DU JOUEUR (2026-08-02) --------------------------------
#
# Le joueur n'en avait aucune : un coup de PNJ se résolvait par un test de
# distance, puis les dés. La lame d'un bandit pouvait donc passer visiblement
# au-dessus de la tête et blesser quand même — le mensonge visuel exact qu'on a
# banni côté joueur (« ça touche quand la tête touche »).
#
# Le gabarit est celui de `data/hitbox_templates.json` : le joueur porte le
# MÊME modèle humanoïde que les PNJ, ses zones sont donc les leurs. Une seule
# table pour les deux camps — impossible qu'un coup soit jugé différemment
# selon qui le donne.
var _player_hitboxes: Array = []


func hitboxes() -> Array:
	if _player_hitboxes.is_empty():
		# DÉJÀ pré-converti par GameData au chargement (min/max en Vector3) : le
		# re-parser reviendrait à lire des Vector3 comme des tableaux JSON.
		# `MeleeAttack.parse_zones` ne sert qu'aux formes BRUTES — surcharge de
		# fiche et manifeste de modèle.
		_player_hitboxes = GameData.hitbox_templates.get("humanoide", [])
	return _player_hitboxes


## Position des PIEDS, origine des zones de coup. La caméra porte l'œil ; les
## boîtes, elles, sont mesurées depuis le sol comme celles des créatures.
func hitbox_origin() -> Vector3:
	# `player.gd` étend Node, pas Node3D : la position vient de la CAMÉRA,
	# qui est l'autorité de position et de collision. L'œil est à
	# EYE_HEIGHT au-dessus des pieds, origine des boîtes.
	return get_position_for_ai() - Vector3.UP * FlyCamera.EYE_HEIGHT


## Le segment monde [a, b] traverse-t-il une zone du joueur ? Même contrat et
## même algorithme que `Creature.sweep_segment` : la PLUS PROCHE le long du
## segment gagne, parce qu'une lame qui croise un bras avant le torse doit
## toucher le bras.
func sweep_segment(a: Vector3, b: Vector3) -> Dictionary:
	var zones := hitboxes()
	var direction := b - a
	if direction.length() < 0.0001 or zones.is_empty():
		return {}
	var local_a := a - hitbox_origin()
	var best := {}
	var best_t := 2.0
	for zone: Dictionary in zones:
		var hit: float = MeleeAttack.segment_aabb(local_a, direction, zone["min"], zone["max"])
		if hit >= 0.0 and hit < best_t:
			best_t = hit
			best = {
				"id": zone["id"], "mult": float(zone["mult"]),
				"t": hit, "point": a + direction * hit,
			}
	return best


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
## USURE DU BOUCLIER (2026-08-02). Un écu était éternel : le porter n'avait
## aucun coût, donc « bouclier » était strictement supérieur à « rien », pour
## toujours. Dans Mount & Blade un bouclier a des points de structure et FINIT
## PAR SE BRISER — c'est ce qui fait qu'on le baisse pour l'épargner, qu'on en
## garde un de rechange, et qu'un adversaire à la hache reste une menace même
## quand on pare juste.
##
## L'usure suit le choc encaissé, pas le nombre de coups : un marteau abîme un
## bouclier bien plus vite qu'une dague, ce qui redonne un rôle aux armes
## lourdes face à un défenseur.
## Structure par point de dureté. 30 et non 6 (recalibré le 2026-08-02 sur la
## sonde) : à 6, un écu de chêne et fer cédait en HUIT coups — ce n'est pas un
## bouclier, c'est une plaque de verre. À 30 il encaisse une quarantaine de
## coups d'épée, une vingtaine de masse : il tient un duel entier, pas une
## bataille, et le contondant le brise deux fois plus vite. C'est là que se joue
## l'arbitrage entre le porter et l'épargner.
const SHIELD_STRUCTURE_PER_HARDNESS := 30.0
const SHIELD_WEAR_PER_DRAIN := 1.0


## Structure restante du bouclier porté, et sa valeur maximale. {} sans bouclier.
func shield_structure() -> Dictionary:
	var shield := equipped_shield()
	if shield.is_empty():
		return {}
	var maximum := maxf(float(shield.get("base_hardness", 10.0))
		* float(shield.get("quality", 1.0)) * SHIELD_STRUCTURE_PER_HARDNESS, 1.0)
	return {
		"current": float(shield.get("structure", maximum)),
		"max": maximum,
		"broken": float(shield.get("structure", maximum)) <= 0.0,
	}


## Le bouclier a-t-il cédé ? Un bouclier brisé reste équipé — le retirer de
## force surprendrait le joueur — mais il ne protège plus.
func shield_broken() -> bool:
	var structure := shield_structure()
	return not structure.is_empty() and bool(structure["broken"])


func absorb_on_guard(drain: float, parried: bool) -> bool:
	var cost := drain * (0.5 if parried else 1.0)
	var shield := shield_profile()
	if bool(shield["present"]):
		cost *= 1.0 - float(shield["absorption"])
		_wear_shield(drain)
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
	# Les jauges viennent de bouger : reporter leur effet dans le résolveur
	# d'E.4 avant que quoi que ce soit ne lise une stat ce tick.
	_refresh_state_modifiers()
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


## Stat EFFECTIVE. Toute lecture de stat destinée à une formule de gameplay
## doit passer par ici — `stats` reste la valeur de base (fiche de personnage,
## sauvegarde).
##
## Depuis le 2026-08-02 le calcul est délégué au résolveur d'E.4
## (`StatModifiers`) : les malus de faim (A.9) et de fatigue (E.21) y sont
## posés comme des SOURCES nommées au lieu d'être testés en dur ici. Le
## résultat est identique à la virgule près ; ce qui change, c'est que les
## effets d'équipement (A.4.4), les statuts (F.4) et les auras de modules (5.1)
## ont désormais un endroit où s'ajouter, au lieu d'allonger cette fonction.
func effective_stat(stat_id: String) -> int:
	return int(floor(modifiers.apply(float(stats.get(stat_id, 0)), stat_id)))


## Reporte l'état du porteur (faim, fatigue) dans le résolveur. Appelé au tick
## et après toute restauration : c'est le seul endroit qui traduit une jauge en
## modificateur, et les modificateurs ne sont pas sauvegardés (ils se
## reposent ici — voir l'en-tête de StatModifiers).
func _refresh_state_modifiers() -> void:
	var starving := hunger < HUNGER_STARVING
	var exhausted := fatigue < FATIGUE_EXHAUSTED
	for stat_id: String in stats:
		# set_modifier avec les neutres retire la source : pas besoin de
		# distinguer « poser » de « retirer » ici.
		modifiers.set_modifier(stat_id, "faim", 0.0,
			HUNGER_STAT_MALUS if starving else 1.0)
		modifiers.set_modifier(stat_id, "fatigue", 0.0,
			FATIGUE_STAT_MALUS if exhausted else 1.0)


## Mange le matériau comestible EN MAIN (1 unité). A.9.1 : un ingrédient cru
## ne rend que 50 % de sa nutrition et n'accorde aucun bonus de potentiel —
## le rendement plein passera par la cuisine (7.7), pas encore implémentée.
## Le risque d'infection du cru (F.5) attend le système de statuts (F.4).
## Utilise l'objet en main : NOURRITURE ou LIVRE. Retourne true si quelque
## chose a été consommé — l'appelant retombe alors sur la pose de bloc.
##
## Le livre est ici et pas ailleurs parce que « consommer ce qu'on tient » le
## décrit exactement : il est à usage unique et disparaît à la lecture (5.1).
## Jusqu'ici rien n'appelait `read_book` — les grimoires se ramassaient et ne
## se lisaient nulle part.
func _try_consume_held() -> bool:
	var entry := _selected_entry()
	if String(entry.get("kind", "")) == "object":
		var obj: Dictionary = entry["object"]
		if BookFactory.is_book(obj):
			var result := read_book(obj)
			if bool(result.get("reussite", false)):
				EventBus.ui_notification.emit(tr("ui.toast.lecture_reussie").format({
					"modules": str((result.get("modules", []) as Array).size())}))
			else:
				EventBus.ui_notification.emit("ui.toast.lecture_echouee")
			return true
	return _try_eat()


## Mange le comestible en main. Retourne true si l'action a été TRAITÉE (y
## compris un refus expliqué : « pas comestible » est une réponse, et le clic
## ne doit pas retomber sur la pose de bloc après l'avoir affichée).
func _try_eat() -> bool:
	# Comestible EN MAIN : soit une instance (viande — modèle objet), soit un
	# matériau empilé (blé, tubercule — récolte de bloc).
	var entry := _selected_entry()
	var instance: Dictionary = entry.get("object", {}) if entry.get("kind", "") == "object" else {}
	var mat: Dictionary = instance
	var mat_name := ""
	if instance.is_empty():
		mat_name = _selected_material()
		if mat_name == "":
			# RIEN EN MAIN QUI SE MANGE : non traité. C'est le seul cas qui doit
			# rendre false, pour que le clic droit retombe sur la pose de bloc.
			return false
		mat = GameData.stackable(mat_name)
	if not (mat.get("nutrition", {}) as Dictionary).has("faim"):
		# Un MATÉRIAU non comestible est un matériau à POSER : on laisse la main
		# au clic droit plutôt que d'afficher un refus à chaque pose de bloc.
		if instance.is_empty():
			return false
		EventBus.ui_notification.emit("ui.toast.pas_comestible")
		return true
	if hunger >= hunger_max:
		EventBus.ui_notification.emit("ui.toast.rassasie")
		return true
	if instance.is_empty():
		if not inventory.remove_material(mat_name, 1):
			return false
	elif not inventory.remove_object_units(instance, 1):
		return false
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
	return true


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
## Cycle de la résolution de grille (4.1) : 32 -> 16 -> 8 -> 4. Le corps
## vivait en ligne dans la chaîne de `elif` du gestionnaire d'entrées ; il en
## est sorti pour que la table ACTION_HANDLERS soit uniforme.
func _cycle_grid_resolution() -> void:
	active_res = RES_SEQUENCE[(RES_SEQUENCE.find(active_res) + 1) % RES_SEQUENCE.size()]
	_progress = 0.0


## Ouvre le dialogue avec la créature visée, si elle a quelque chose à dire.
##
## On réutilise la CIBLE DE COMBAT, sans second système de visée : le joueur
## désigne un PNJ exactement comme il désignerait une proie. Avoir deux
## curseurs, l'un pour frapper l'autre pour parler, obligerait à deviner lequel
## est actif.
## INTERACTION CONTEXTUELLE (touche E, 2026-08-03). Une seule touche pour tout
## ce qui se trouve DANS LE MONDE, au lieu de trois (E parler, G ramasser,
## Y encaisser) qu'il fallait connaître et distinguer à l'avance.
##
## L'ORDRE EST LA RÈGLE, du plus proche au plus lointain :
##   1. un butin au sol à portée de ramassage — c'est ce qu'on vient chercher ;
##   2. le bloc visé, s'il est un étal (encaisser) ou un poste de travail
##      (ouvrir l'artisanat) ;
##   3. la créature visée, si elle accepte de parler.
##
## Le butin passe devant le dialogue à dessein : un PNJ debout sur un coffre est
## une situation banale, et ramasser est le geste qu'on répète le plus.
func _try_interact() -> void:
	if _try_pickup():
		return
	if _try_interact_block():
		return
	_try_talk()


## Poste de travail visé : ouvre l'artisanat. Renvoie true si quelque chose a
## été fait. Les huit stations (C.8) sont reconnues par leur CATÉGORIE, pas par
## une liste d'ids — en ajouter une neuvième en données suffira.
func _try_interact_block() -> bool:
	if not _target_valid:
		return false
	var block_id := WorldManager.block_at_world(_target)
	if block_id <= 0 or block_id >= GameData.material_by_runtime.size():
		return false
	var mat_name: String = GameData.material_by_runtime[block_id]
	var mat: Dictionary = GameData.materials.get(mat_name, {})

	# COFFRE (F.6) : OUVRE SON PANNEAU. Il raflait tout d'un coup — juste assez
	# pour vider le coffre d'un boss, inutilisable pour ce à quoi un coffre sert
	# vraiment : ranger, reprendre une partie, laisser le reste.
	if ContainerManager.is_chest(_target):
		var panel := get_node_or_null("/root/Main/ChestPanel")
		if panel != null and bool(panel.call("open_at", _target)):
			return true
		# Repli si le panneau manque (sonde headless, scène incomplète) : mieux
		# vaut vider le coffre que rendre son contenu inatteignable.
		gold += ContainerManager.take_all(_target, inventory)
		return true

	# ÉTAL : encaisser la recette (7.1). Il n'est pas de catégorie « station »,
	# c'est un meuble de commerce — d'où le test par id.
	if mat_name == "etal_de_vente":
		var amount := ShopManager.collect_gold(_target)
		if amount > 0:
			gold += amount
			EventBus.ui_notification.emit(tr("ui.toast.etal_collecte").format({
				"montant": str(amount)}))
		else:
			EventBus.ui_notification.emit("ui.toast.etal_vide")
		return true

	if String(mat.get("category", "")) != "station":
		return false
	var menu := get_node_or_null("/root/Main/GameMenu")
	if menu == null:
		return false
	menu.call("_open")
	menu.call("_select_tab", "craft")
	EventBus.ui_notification.emit(tr("ui.toast.station_ouverte").format({
		"station": tr(String(mat.get("name_key", mat_name)))}))
	return true


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

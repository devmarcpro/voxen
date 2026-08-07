extends Node
## GameData — charge et indexe tout data/ au démarrage (D.2, section 10).
## - Valide les schémas de l'Annexe B (champs manquants → erreur claire en console).
## - Valide l'unicité des couleurs matériaux + absence de collision avec les
##   couleurs réservées (B.1 : doublon = erreur bloquante de données).
## - Valide au boot que chaque clé de traduction référencée existe (10.1 :
##   clé manquante = warning console + affichage de la clé brute, jamais de crash).
## - Hot-reload F5 en debug (D.2) : recharge les données sans relancer.

const PATH_MATERIALS := "res://data/materials"
const PATH_CATEGORIES := "res://data/material_categories.json"
const PATH_RESERVED_COLORS := "res://data/reserved_colors.json"
const PATH_BIOMES := "res://data/biomes"
const PATH_NOISE_LAYERS := "res://data/noise_layers.json"
const PATH_STRATA := "res://data/strata.json"
const PATH_ORE_BANDS := "res://data/ore_bands.json"
const PATH_SKILLS := "res://data/skills"
const PATH_FUNCTIONALITIES := "res://data/functionalities"
const PATH_ITEMS := "res://data/items"
const PATH_MODULES := "res://data/modules"
## Statuts temporaires (GDD F.4) — brûlure, hâte, peau de pierre…
const PATH_STATUS_EFFECTS := "res://data/status_effects"
const PATH_DIMENSIONS := "res://data/dimensions"
## Table des effets d'échec de lecture (GDD A.7, extensible en données).
const PATH_READING_FAILURES := "res://data/reading_failures.json"
const PATH_CREATURES := "res://data/creatures"
const PATH_HITBOX_TEMPLATES := "res://data/hitbox_templates.json"
const PATH_ARMOR_TYPE_MODIFIERS := "res://data/armor_type_modifiers.json"
const PATH_WEAPON_PARTS := "res://data/weapon_parts.json"
const PATH_TREES := "res://data/trees"
const PATH_PLANTS := "res://data/plants"
const PATH_DUNGEON_ROOMS := "res://data/dungeon_rooms"
const PATH_DUNGEON_CONNECTORS := "res://data/dungeon_connectors"
const PATH_NAME_CULTURES := "res://data/name_cultures"
const PATH_RACES := "res://data/races"
const PATH_CLASSES := "res://data/classes"
const PATH_TRANSFORMATIONS := "res://data/transformations"
const PATH_PLATS := "res://data/plats"
const PATH_MUNITIONS := "res://data/munitions"

## Les 6 stats de personnage (C.1) — pour la validation des bonus race/classe.
const CHARACTER_STATS: Array[String] = [
	"force", "dexterite", "endurance", "volonte", "perception", "charisme",
]

## Locales de RÉFÉRENCE : toute clé manquante est un défaut, signalé une par
## une (10.1 — « aucune string affichable en dur, jamais »).
const VALIDATED_LOCALES: Array[String] = ["fr", "en"]
## Locales EN COURS de traduction (2026-07-27) : une clé manquante y retombe
## sur l'anglais (locale/fallback) et n'est PAS un défaut. On rapporte un
## TAUX DE COUVERTURE au lieu de noyer la console sous des centaines
## d'avertissements — sinon les vrais problèmes des locales de référence
## deviennent invisibles au milieu du bruit.
const PARTIAL_LOCALES: Array[String] = ["ja", "zh_Hans"]

## Les 13 stats obligatoires d'un matériau (B.1 / 4.2 / A.4.5).
## (Les noms de champs JSON sont ceux des schémas B — français, comme le GDD.)
const STAT_KEYS: Array[String] = [
	"durete", "densite", "valeur_base", "conductivite_mana", "flammabilite",
	"isolation", "conductivite_electrique", "flottabilite", "luminosite",
	"fertilite", "transparence", "elasticite", "friction",
]

## Les 8 couches de bruit obligatoires (B.8 / 3.0).
const NOISE_LAYER_KEYS: Array[String] = [
	"altitude", "temperature", "humidite", "mana", "danger",
	"vegetation", "sismique", "ressources",
]

## Tags dérivés automatiquement des stats par seuil >= 50 (B.1).
const DERIVED_TAG_THRESHOLD := 50
const DERIVED_TAGS := {
	"flammabilite": "inflammable",
	"conductivite_mana": "conducteur_mana",
	"flottabilite": "flottant",
	"isolation": "isolant",
	"luminosite": "luminescent",
	"transparence": "transparent",
	"conductivite_electrique": "conducteur",
}

## Mappage des catégories de matériaux à un style de texture procédurale par
## défaut (réécriture 2026-07-24). Un matériau peut surcharger ceci avec sa
## propre clé "texture_style" dans son .json (ex. sable→sand, brique→bricks).
const CATEGORY_TEXTURE_STYLES := {
	"bois":           "wood",
	"planches":       "planks",
	"roche":          "stone",
	"terre":          "soil",
	"fossile":        "stone",
	"minerai":        "ore",
	"mineral":        "ore",
	"lingot":         "metal",
	"cristal":        "gem",
	"vegetal":        "leaves",
	"liquide":        "water",
	"meteorologique": "snow",
	"synthetique":    "stone",
}

## Matériaux indexés par id texte → dictionnaire (schéma B.1 + tags dérivés).
var materials: Dictionary = {}
## Catégories de matériaux (B.2).
var material_categories: Dictionary = {}
## Couleurs réservées (stand-in matériaux + marqueurs d'attache, D.2/12.1).
var reserved_colors: Dictionary = {}
## Id texte → id runtime numérique (>= 1 ; 0 = air). Utilisé pour le stockage
## voxel compact (2 octets/bloc, G.2) et la palette shader.
var material_runtime_ids: Dictionary = {}
## Id runtime → id texte (indice 0 = air).
var material_by_runtime: Array[String] = ["air"]
## Masque des liquides par id runtime (1 = liquide) — le mesher abaisse leur
## face du dessus (2026-07-24). Thread-safe en lecture (rempli au boot).
var liquid_mask := PackedByteArray()
## MASQUE DES BLOCS « EN CROIX » par id runtime (2026-08-04) : herbes, céréales,
## fleurs, légumes — tout ce qui ne se lit PAS comme un cube.
##
## POURQUOI UN MASQUE ET PAS UNE CATÉGORIE. La catégorie dit ce QU'EST un
## matériau (végétal, roche, métal) ; celle-ci dit comment il SE DESSINE. Une
## bûche et un brin d'herbe sont tous deux « vegetal » et n'ont rien à voir à
## l'écran. C'est le champ `render` de la fiche qui tranche, et lui seul.
##
## Un bloc en croix N'OCCULTE RIEN : le mesher le traite comme de l'air pour le
## calcul des faces voisines, sinon un champ de blé creuserait un trou carré
## dans le sol qu'il recouvre.
var cross_mask := PackedByteArray()
## MASQUE DES BLOCS INVISIBLES par id runtime (2026-08-07) : les objets posés.
## Ils occupent leur case (visée, collision, sauvegarde) mais ne sont PAS
## maillés — leur apparence est leur vrai modèle d'objet, monté en scène par
## `PlacedItemManager`. Comme les blocs en croix, ils sont retirés du pad AVANT
## le balayage des faces : laissés dedans, une épée posée sur l'herbe volerait
## sa face du dessus au bloc de sol et creuserait un trou carré.
var hidden_mask := PackedByteArray()
## Id runtime → fiche du matériau, pour les seuls blocs en croix. Le mailleur y
## lit le PORT de la plante (touffe, épi, buisson, rampante, fleur) et ses
## dimensions. C'est la fiche de MATÉRIAU elle-même : une plante se pose, se
## casse et se ramasse comme un bloc, lui inventer un second registre parallèle
## rejouerait l'erreur qui a coûté deux pipelines de génération.
var plant_species_by_runtime: Dictionary = {}
## Id runtime → cellule de l'atlas de sprites (voir PlantAtlas). Rempli par
## WorldManager au moment de bâtir le matériau, quand la palette est prête.
var plant_atlas_index: Dictionary = {}
## Émission lumineuse (0-15) et transmission par id runtime (G.3). Lues sans
## verrou depuis les threads de meshing — comme tout GameData, figées au boot.
var emission_by_runtime := PackedByteArray()
var transmits_by_runtime := PackedByteArray()
## Biomes indexés par id (schéma B.6).
var biomes: Dictionary = {}
## Couches de bruit (schéma B.8).
var noise_layers: Dictionary = {}
## Strates par profondeur, ordonnées surface → fond (G.9).
var strata: Array = []
## Bandes de minerais par profondeur (G.9) — filons placés par NoiseGenerator.
var ore_bands: Array = []
## Compétences (C.4 ; champ category "combat"/"general", décision 6.0).
var skills: Dictionary = {}
## Fonctionnalités d'objets (B.3.1).
var functionalities: Dictionary = {}
## Objets / recettes (B.3).
var items: Dictionary = {}
## Modules de compétence (B.4).
var modules: Dictionary = {}
## Fiches de statut (F.4), indexées par id. Substrat partagé des sorts,
## des potions (F.9), de la nourriture avariée (F.5) et des échecs de
## lecture (A.7) — pas une annexe du système de sorts.
var status_effects: Dictionary = {}
## DIMENSIONS (3.5) : registre des mondes autres que l'overworld. Une dimension
## déclare son ambiance et, si elle en a un, le nœud qui sait la construire.
## Sans ce registre, « pas l'overworld » voulait dire « donjon ».
var dimensions: Dictionary = {}
## Effets d'échec de lecture, par gravité (« mineur » / « grave ») — GDD A.7.
## Chargée sans validation bloquante : un fichier absent dégrade la lecture
## ratée en simple perte du livre, ce qui reste jouable.
var reading_failures: Dictionary = {}
## Créatures / PNJ (B.5).
var creatures: Dictionary = {}
## Zones de coup par gabarit de squelette (combat directionnel, 2026-07-28) —
## data/hitbox_templates.json. Une fiche de créature peut surcharger la liste
## via son propre champ `hitboxes` ; sinon elle hérite de son
## `skeleton_template`. Voir Creature.hitboxes().
var hitbox_templates: Dictionary = {}
## Efficacité de l'armure par catégorie de matériau × type de dégât
## (2026-07-28) — data/armor_type_modifiers.json. Multiplie la MITIGATION.
## Voir WeaponStats.armor_type_modifier().
var armor_type_modifiers: Dictionary = {}
## Pieces d'arme (2026-07-28) — data/weapon_parts.json. Deux tables :
## `manches` (modele, longueur, points de prise) et `tetes` (modele, portee
## ajoutee). Une arme est un MANCHE + une TETE : son allonge et la position
## de ses mains se DEDUISENT des pieces, elles ne sont plus ecrites a la main.
var weapon_parts: Dictionary = {"manches": {}, "tetes": {}}
## Essences d'arbres (génération procédurale, TreeGenerator).
var trees: Dictionary = {}
## Plantes non-arborescentes en sous-voxels (2026-07-20, PlantGenerator) —
## data/plants/*.json.
var plants: Dictionary = {}
## Gabarits de répliques d'ambiance (E.23), à plat : le tirage les parcourt tous
## à chaque interaction, une liste est donc plus juste qu'un dictionnaire.
var dialogue_lines: Array[Dictionary] = []
## Salles/connecteurs de donjon (E.29, DungeonGenerator) — data/dungeon_rooms
## et data/dungeon_connectors/*.json (B.10, géométrie simplifiée en boîtes —
## pas de vox_model réel pour l'instant, voir DungeonGenerator).
var dungeon_rooms: Dictionary = {}
var dungeon_connectors: Dictionary = {}
## Cultures de nommage (12.5/B.11/C.9) — data/name_cultures/*.json. Pilotent
## les noms de PNJ, de villes et les titres de rôle, consommées par
## `NameGenerator`. Axe INDÉPENDANT de la race : une même race peut porter
## plusieurs cultures selon le royaume.
var name_cultures: Dictionary = {}
## Races (C.2) et classes (C.3) de création de personnage (6.1).
var races: Dictionary = {}
var classes: Dictionary = {}
## Transformations à station (4.2/C.8) : minerai→lingot, etc. (data/transformations).
var transformations: Dictionary = {}
## PLATS cuisinés (7.7) : consommables d'inventaire produits à la station
## Cuisine. Comme les ressources, ce sont des INSTANCES d'objet, jamais des
## blocs. `nutrition.cuit = true` → nutrition PLEINE (A.9.1) et bonus de
## potentiel crédités à la consommation (6.4).
var plats: Dictionary = {}
## Munitions (flèches, carreaux). Ce sont des RESSOURCES comme les plats — non
## posables, instanciées en inventaire, empilées — et elles vivent donc dans le
## même registre. Les distinguer par une classe à part aurait dupliqué le
## stockage, la consommation et l'affichage pour un seul champ de différence.
var munitions: Dictionary = {}
## RESSOURCES : objets empilables d'inventaire qui ne sont PAS des blocs
## (viandes, peaux — 7.7). Registre distinct de `materials` À DESSEIN : elles
## n'ont pas d'id runtime, pas d'entrée de palette, et ne peuvent donc pas
## être posées dans le monde. Poser un bloc de viande n'a aucun sens.
## Même stockage d'inventaire que les matériaux (empilage par id) — voir
## `stackable()` pour la résolution unifiée nom/couleur/valeur.
var resources: Dictionary = {}

var _blocking_errors: int = 0
## Couleur (hex majuscule) -> id du matériau qui la porte. Sert à garantir
## l'unicité des couleurs générées pour les matériaux paramétriques (B.1).
var _seen_colors: Dictionary = {}


func _ready() -> void:
	load_all()
	if _blocking_errors > 0:
		push_error("GameData : %d erreur(s) bloquante(s) de données au boot — arrêt." % _blocking_errors)
		get_tree().quit(1)


func _unhandled_key_input(event: InputEvent) -> void:
	# Hot-reload F5 (D.2) — debug uniquement.
	if not OS.is_debug_build():
		return
	if event.is_action_pressed("reload_data"):
		reload_data()


## Recharge toutes les données à chaud, puis prévient les systèmes dérivés.
func reload_data() -> void:
	print("GameData : rechargement des données (F5)...")
	# Les threads de meshing lisent `materials` / `material_by_runtime` /
	# `liquid_mask` SANS VERROU — c'est sûr uniquement parce que ces données
	# sont figées après le boot. load_all() les vide et les reconstruit : sans
	# cette attente, un thread pouvait parcourir un dictionnaire en cours de
	# réécriture (2026-07-27). Le drain rend la garantie « lecture seule » vraie
	# à nouveau avant qu'on y touche.
	if WorldManager != null:
		WorldManager.wait_for_in_flight()
	load_all()
	EventBus.data_reloaded.emit()


## Charge et valide tout data/. Peuple les index. Retourne false si une
## erreur bloquante a été rencontrée.
func load_all() -> bool:
	_blocking_errors = 0
	materials.clear()
	material_runtime_ids.clear()
	material_by_runtime = ["air"]

	reserved_colors = _load_json(PATH_RESERVED_COLORS)
	if reserved_colors == null:
		reserved_colors = {}

	var categories: Variant = _load_json(PATH_CATEGORIES)
	material_categories = categories if categories is Dictionary else {}

	_load_materials()
	_load_noise_layers()
	_load_biomes()
	_load_strata()
	_load_ore_bands()
	_load_skills()
	_load_functionalities()
	_load_items()
	_load_modules()
	_load_reading_failures()
	_load_status_effects()
	_load_dimensions()
	_load_hitbox_templates()   # avant les créatures : elles valident leur gabarit.
	_load_armor_type_modifiers()
	_load_weapon_parts()   # avant les objets : ils referencent des pieces.
	_load_creatures()
	_load_trees()
	_load_plants()
	_load_dialogue()
	_load_name_cultures()
	_load_dungeon_rooms()
	_load_dungeon_connectors()
	_load_races()
	_load_classes()
	_load_transformations()
	_load_plats()
	_load_munitions()
	_generate_parametric_resources()
	# APRÈS les essences et les matériaux, AVANT l'index : une pousse emprunte sa
	# couleur aux feuilles de son essence, et doit recevoir son id runtime avec
	# les autres matériaux.
	_generate_sapling_materials()
	# APRÈS le catalogue d'objets, AVANT l'index : un objet posé est un bloc, il
	# lui faut son id runtime comme aux autres.
	_generate_object_materials()
	_finalize_material_index()
	_validate_translation_keys()

	print("GameData : %d matériau(x), %d catégorie(s), %d biome(s), %d couche(s) de bruit, %d strate(s), %d compétence(s), %d objet(s), %d module(s), %d créature(s), %d essence(s) d'arbre, %d plante(s), %d salle(s)/%d connecteur(s) de donjon, %d race(s), %d classe(s), %d culture(s) de nommage." % [
		materials.size(), material_categories.size(), biomes.size(), noise_layers.size(), strata.size(), skills.size(), items.size(), modules.size(), creatures.size(), trees.size(), plants.size(), dungeon_rooms.size(), dungeon_connectors.size(), races.size(), classes.size(), name_cultures.size()])
	return _blocking_errors == 0


## Liste récursivement les .json d'un dossier (les matériaux sont rangés en
## sous-dossiers par catégorie — B.1 amendé, lisibilité à 200+ entrées).
func _list_json_recursive(path: String) -> Array[String]:
	var result: Array[String] = []
	for subdir in DirAccess.get_directories_at(path):
		result.append_array(_list_json_recursive(path + "/" + subdir))
	for file_name in DirAccess.get_files_at(path):
		if file_name.ends_with(".json"):
			result.append(path + "/" + file_name)
	return result


func _load_materials() -> void:
	var paths := _list_json_recursive(PATH_MATERIALS)
	if paths.is_empty():
		_blocking_error("aucun fichier dans %s" % PATH_MATERIALS)
		return

	# Couleur → id, pour la validation d'unicité (B.1).
	var seen_colors: Dictionary = {}
	var reserved := _all_reserved_colors()

	var sorted_ids: Array[String] = []
	for path in paths:
		var raw: Variant = _load_json(path)
		if not (raw is Dictionary):
			continue
		var mat: Dictionary = raw
		if not _validate_material(mat, path):
			continue
		# Rangement par dossier de catégorie : avertir si incohérent (B.1).
		var folder := path.get_base_dir().get_file()
		if folder != "materials" and folder != String(mat["category"]):
			push_warning("GameData : « %s » est dans le dossier « %s » mais sa catégorie est « %s »." % [mat["id"], folder, mat["category"]])
		# DIMENSION = DOSSIER, exactement comme pour les biomes (`data/materials/
		# <dimension>/<catégorie>/`). Elle n'était nulle part : rien ne pouvait
		# dire qu'un cristal de songe appartient à la faille et pas au monde, et
		# le monde vitrine les alignait donc dans la même rangée. Un matériau
		# posé directement sous data/materials est supposé overworld (compat).
		var dim_folder := path.get_base_dir().get_base_dir().get_file()
		mat["dimension"] = "overworld" if dim_folder == "materials" else dim_folder
		var id: String = mat["id"]
		if materials.has(id):
			_blocking_error("id de matériau dupliqué « %s » (%s)" % [id, path])
			continue

		# Couleurs (B.1, amendé le 2026-07-27 sur décision de l'auteur) :
		# l'unicité n'est PLUS obligatoire. Elle était une erreur bloquante,
		# ce qui plafonnait de fait le catalogue et imposait de chercher une
		# teinte libre à chaque ajout — friction inacceptable pour un jeu
		# volontairement très dense. Deux matériaux sans rapport peuvent
		# partager une couleur ; ce qui les distingue reste leur bruit de
		# texture (`noise`) et leur contexte. Seules les couleurs RÉSERVÉES
		# (marqueurs d'attache, stand-ins de craft) restent interdites : elles
		# ont une SIGNIFICATION technique, les confondre casserait le remapping.
		var color: String = String(mat["color"]).to_upper()
		if seen_colors.has(color):
			pass  # Doublon toléré (voir ci-dessus).
		elif reserved.has(color):
			_blocking_error("couleur %s du matériau « %s » entre en collision avec une couleur réservée (%s)" % [color, id, reserved[color]])
		seen_colors[color] = id

		# Applique un style de texture par défaut si non spécifié (2026-07-24).
		if not mat.has("texture_style"):
			mat["texture_style"] = CATEGORY_TEXTURE_STYLES.get(mat["category"], "basic")

		_derive_tags(mat)
		# CHEMIN D'ORIGINE. Les matériaux sont rangés par DIMENSION depuis le
		# 2026-08-04 (`data/materials/magique/`, `overworld/`) : sans retenir
		# d'où vient la fiche, rien ne peut vérifier qu'une dimension n'emploie
		# que ses propres blocs — et un rangement que rien ne vérifie se défait.
		mat["_source"] = path
		materials[id] = mat
		sorted_ids.append(id)

	_seen_colors = seen_colors


## Fige les ids runtime et les masques dérivés. APPELÉ EN DERNIER (2026-07-27) :
## les matériaux paramétriques (viandes, peaux) naissent des créatures, qui se
## chargent après les matériaux — indexer trop tôt les aurait laissés sans id.
func _finalize_material_index() -> void:
	# Ids runtime stables : ordre alphabétique des ids texte, 0 réservé à l'air.
	var sorted_ids: Array[String] = []
	for id: String in materials:
		sorted_ids.append(id)
	sorted_ids.sort()
	for id in sorted_ids:
		material_runtime_ids[id] = material_by_runtime.size()
		material_by_runtime.append(id)

	# Masque des LIQUIDES par id runtime (2026-07-24) : le mesher abaisse la
	# face du dessus des liquides (eau/lave « moins grands » que les blocs
	# pleins). Lu depuis les threads de meshing (GameData en lecture seule).
	# Émission lumineuse par id runtime (G.3) : table plate, lue depuis les
	# threads de meshing comme `liquid_mask`. Sans elle, le mesher devrait
	# faire deux consultations de dictionnaire par cellule du voisinage.
	emission_by_runtime = PackedByteArray()
	emission_by_runtime.resize(palette_size())
	transmits_by_runtime = PackedByteArray()
	transmits_by_runtime.resize(palette_size())
	transmits_by_runtime[0] = 1  # L'air transmet toujours.
	for id in sorted_ids:
		var rid: int = material_runtime_ids[id]
		var stats: Dictionary = materials[id]["stats"]
		emission_by_runtime[rid] = int(round(float(stats.get("luminosite", 0)) / 100.0 * 15.0))
		transmits_by_runtime[rid] = 1 if float(stats.get("transparence", 0)) >= 50.0 else 0

	liquid_mask = PackedByteArray()
	liquid_mask.resize(palette_size())
	cross_mask = PackedByteArray()
	cross_mask.resize(palette_size())
	hidden_mask = PackedByteArray()
	hidden_mask.resize(palette_size())
	plant_species_by_runtime.clear()
	for id in sorted_ids:
		if String(materials[id].get("category", "")) == "liquide":
			liquid_mask[material_runtime_ids[id]] = 1
		if String(materials[id].get("render", "cube")) == "croix":
			cross_mask[material_runtime_ids[id]] = 1
			plant_species_by_runtime[material_runtime_ids[id]] = materials[id]
		elif String(materials[id].get("render", "cube")) == "objet":
			hidden_mask[material_runtime_ids[id]] = 1


## Largeur des textures de palette indexées par id runtime (couleurs, bruit,
## style, masque des liquides). Le shader les lit en `texelFetch` par index
## exact — la largeur peut donc être quelconque, elle doit juste couvrir TOUS
## les ids.
##
## Corrigé le 2026-07-27 : ces tableaux étaient figés à 256 alors que le
## catalogue est à 242 matériaux. Au 257e, `set_pixel` serait sorti des bornes
## et le masque des liquides aurait silencieusement ignoré les ids au-delà —
## une corruption de rendu progressive et difficile à relier à sa cause. Un
## plancher de 256 est conservé pour ne rien changer tant qu'on est dessous.
func palette_size() -> int:
	return maxi(256, material_by_runtime.size())


## Plats cuisinés (7.7) — recettes à station Cuisine. Ils rejoignent
## `resources` : même modèle d'instance, même consommation.
## Charge les munitions. Même forme que les plats — un identifiant, une recette,
## une densité — moins la nutrition : on ne mange pas une flèche.
func _load_munitions() -> void:
	munitions.clear()
	for path in _list_json_recursive(PATH_MUNITIONS):
		var raw: Variant = _load_json(path)
		if not (raw is Dictionary):
			continue
		var ammo: Dictionary = raw
		var ok := true
		for field in ["id", "name_key", "recipe", "par_fabrication"]:
			if not ammo.has(field):
				_blocking_error("champ « %s » manquant dans %s" % [field, path])
				ok = false
		if not ok:
			continue
		var recipe: Dictionary = ammo["recipe"]
		if not skills.has(String(recipe.get("skill", ""))):
			_blocking_error("compétence inconnue « %s » (munition « %s »)" % [
					recipe.get("skill", "?"), ammo["id"]])
		munitions[ammo["id"]] = ammo
		resources[ammo["id"]] = {
			"id": ammo["id"],
			"name_key": ammo["name_key"],
			"category": "ressource",
			"item_kind": "munition",
			"color": String(ammo.get("color", "#8A6A3C")),
			"stats": {"densite": float(ammo.get("densite", 1)),
				"valeur_base": float(ammo.get("valeur_base", 2))},
			"nutrition": {},
			"potentiel": {},
			"tags": ["munition"],
		}


func _load_plats() -> void:
	plats.clear()
	for path in _list_json_recursive(PATH_PLATS):
		var raw: Variant = _load_json(path)
		if not (raw is Dictionary):
			continue
		var plat: Dictionary = raw
		var ok := true
		for field in ["id", "name_key", "nutrition", "recipe"]:
			if not plat.has(field):
				_blocking_error("champ « %s » manquant dans %s" % [field, path])
				ok = false
		if not ok:
			continue
		var recipe: Dictionary = plat["recipe"]
		if not skills.has(String(recipe.get("skill", ""))):
			_blocking_error("compétence inconnue « %s » (plat « %s »)" % [
					recipe.get("skill", "?"), plat["id"]])
		# Chaque entrée est un matériau précis OU un tag de ressource
		# (« viande » : n'importe quelle viande convient — c'est tout
		# l'intérêt des viandes paramétriques).
		for in_def: Dictionary in recipe.get("inputs", []):
			if in_def.has("material") and not materials.has(in_def["material"]):
				_blocking_error("ingrédient inconnu « %s » (plat « %s »)" % [
						in_def["material"], plat["id"]])
		# Un plat EST une ressource consommable : même registre, donc mêmes
		# règles (non posable, instancié en inventaire).
		plats[plat["id"]] = plat
		resources[plat["id"]] = {
			"id": plat["id"],
			"name_key": plat["name_key"],
			"category": "ressource",
			"item_kind": "plat",
			"color": String(plat.get("color", "#CCAA77")),
			"stats": {"densite": float(plat.get("densite", 2)),
				"valeur_base": float(plat.get("valeur_base", 8))},
			"nutrition": plat["nutrition"],
			"potentiel": plat.get("potentiel", {}),
			"tags": ["plat", "comestible"],
		}


## RESSOURCES paramétriques (B.1 : « gabarits instanciés depuis une source »).
## Chaque créature engendre sa viande et sa peau — « Viande de X », « Peau de
## X » — au lieu de 74 fichiers écrits à la main. Ce sont des objets
## d'inventaire, PAS des blocs : elles vont dans `resources` (2026-07-27).
##
## Bonus de potentiel de la viande (A.9.1, copié à la lettre) :
##   bonus_potentiel(stat) = stat_source_creature / 10, arrondi, max 8
## Nutrition (A.9) : proportionnelle à la corpulence de la bête, bornée. Le
## bloc est marqué `cuit: false` — manger cru ne rend que 50 % (A.9.1), le
## reste attend la station Cuisine (7.7).
##
## Couleur : décalage DÉTERMINISTE de la couleur du gabarit par le hash de
## l'id de la créature (B.1 : « la couleur d'une variante = couleur de la
## source décalée déterministiquement »), puis résolution de collision par
## petits pas — la validation d'unicité des couleurs reste vraie.
func _load_dimensions() -> void:
	dimensions.clear()
	for path in _list_json_recursive(PATH_DIMENSIONS):
		var raw: Variant = _load_json(path)
		if not (raw is Dictionary):
			continue
		var dimension: Dictionary = raw
		for field in ["id", "name_key"]:
			if not dimension.has(field):
				_blocking_error("champ « %s » manquant dans %s" % [field, path])
		if dimensions.has(dimension.get("id", "")):
			_blocking_error("id de dimension dupliqué « %s »" % dimension["id"])
			continue
		dimensions[String(dimension["id"])] = dimension


func _generate_parametric_resources() -> void:
	for creature_id: String in creatures:
		var creature: Dictionary = creatures[creature_id]
		# Les créatures sans corps à dépecer (essaims, nuées) ne donnent rien.
		if "amorphe" in (creature.get("tags", []) as Array):
			continue
		var stats: Dictionary = creature.get("base_stats", {})
		var potential := {}
		for stat_id: String in ["force", "dexterite", "endurance", "volonte"]:
			var bonus := mini(8, int(round(float(stats.get(stat_id, 0)) / 10.0)))
			if bonus > 0:
				potential[stat_id] = bonus
		var sante := float(stats.get("sante", 10))
		_add_parametric("viande_de_" + creature_id, "material.viande.name", creature,
				"#B5443C", {
					"nutrition": {"faim": clampf(round(sante * 0.6), 6.0, 45.0), "cuit": false},
					"potentiel": potential,
				})
		_add_parametric("peau_de_" + creature_id, "material.peau.name", creature,
				"#8A6A4F", {})


## POUSSES : un matériau POSABLE par essence (B.1, « Pousse de [essence] »).
##
## Des ressources n'auraient pas suffi : une ressource ne se pose pas, et une
## pousse qu'on ne peut pas planter ne sert à rien. Ce sont donc de vrais
## matériaux, avec un id runtime et une entrée de palette, générés depuis le
## catalogue d'essences — écrire trente-huit fichiers à la main aurait divergé
## dès la première essence ajoutée.
func _generate_sapling_materials() -> void:
	for species_id: String in trees:
		var species: Dictionary = trees[species_id]
		var id := "pousse_" + species_id
		if materials.has(id):
			continue  # Un fichier écrit à la main gagne toujours.
		var leaf: Dictionary = materials.get(String(species.get("leaf_material", "")), {})
		materials[id] = {
			"id": id,
			"name_key": "material.pousse.name",
			"category": "vegetal",
			"stats": {
				# TENDRE ET LÉGÈRE : une pousse s'arrache à la main, et la
				# transporter par centaines ne doit pas peser un arbre.
				"durete": 1, "densite": 1, "valeur_base": 4,
				"conductivite_mana": 3, "flammabilite": 70, "isolation": 10,
				"conductivite_electrique": 2, "flottabilite": 60, "luminosite": 0,
				"fertilite": 60, "transparence": 20, "elasticite": 40, "friction": 35,
			},
			"tags": ["organique", "vegetal", "pousse"],
			# COULEUR DÉCALÉE, pas recopiée. Reprendre telle quelle la couleur des
			# feuilles donnait deux blocs distincts pour une seule entrée de
			# palette — `--probe-butin` l'a signalé sur les 38 essences d'un
			# coup. `_variant_color` fait exactement ce décalage déterministe,
			# et c'est déjà lui qui distingue les viandes et les peaux.
			"color": _variant_color(String(leaf.get("color", "#4C8B3A")), id),
			"noise": {"type": "procedural", "seed_offset": 940, "amplitude": 0.05, "scale": 1},
			"harvest": {"tool_category": "mains_nues", "skill": "herboristerie"},
			"world_gen": {"mode": "aucun", "biome_tags": []},
			"parametric": {"source": "tree", "source_id": species_id},
			"source_name_key": String(species.get("name_key", "")),
			# La pousse appartient au monde de son essence : une pousse d'arbre
			# de songe n'est pas un végétal de l'overworld.
			"dimension": String(species.get("dimension", "overworld")),
		}
		_derive_tags(materials[id])


## OBJETS POSÉS : un matériau par TYPE d'objet du catalogue (2026-08-06).
##
## Ctrl + clic droit pose n'importe quel objet d'inventaire au sol EN TANT QUE
## BLOC. Or un objet n'a pas d'id runtime de palette, et il ne peut pas en
## recevoir un à l'exécution : les ids sont FIGÉS au démarrage par
## `_finalize_material_index`, ils dimensionnent les masques et les textures de
## palette, et ce sont eux qui sont écrits dans la sauvegarde. Un id créé au
## moment où le joueur pose une épée n'aurait aucune stabilité d'une partie à
## l'autre.
##
## POURQUOI PAR TYPE, ET PAS PAR INSTANCE. 21 armes × 41 bois × 21 minerais font
## 18 081 combinaisons pour les seules armes, avant qualité et usure : une entrée
## de palette par instance est hors de question. Ce qui distingue deux instances
## (qualité, matériaux, usure) va donc dans un REGISTRE POSITIONNEL,
## `PlacedItemManager` — le patron des pousses, qui résout déjà exactement ce
## cas : le bloc porte la forme, le registre porte ce que le bloc ne sait pas
## dire. La reprise rend l'instance TELLE QUELLE, ce qui interdit la machine à
## réparer qu'un objet reconstruit depuis sa fiche aurait été.
##
## POURQUOI PAS UNE SEULE ENTRÉE GÉNÉRIQUE non plus : les quarante objets du
## catalogue seraient alors le même cube, et la rangée d'objets du monde vitrine
## ne montrerait rien — or c'est précisément ce que la vitrine existe pour
## montrer.
##
## Parcours du CATALOGUE, jamais une liste écrite ici : un objet ajouté à
## `data/items/` reçoit son bloc sans qu'on y touche.
func _generate_object_materials() -> void:
	# COULEURS RÉPARTIES, PAS TIRÉES AU HASARD. `_variant_color` décale la teinte
	# par le hash de l'id : sur quarante et un blocs partant tous de la MÊME
	# couleur de base, deux hashs finissent dans le même seau et rendent le même
	# hex — `objet_hache` et `objet_masse` l'ont fait du premier coup, et
	# `--probe-butin` l'a signalé (une couleur en double, c'est deux blocs
	# indistinguables dans la palette du monde, donc dans la vitrine aussi).
	# Une teinte par rang sur le tour complet ne peut pas se cogner.
	var ids: Array[String] = []
	for item_id: String in items:
		ids.append(OBJECT_PREFIX + item_id)
	ids.sort()
	# REPLI pour les instances dont le `item_id` n'est PAS un objet du catalogue :
	# les ressources de créature (viande, peau) portent un genre (« viande ») et
	# non un id d'objet. Sans ce bloc, poser un quartier de viande n'aurait aucun
	# matériau et l'action échouerait en silence.
	ids.append(GENERIC_OBJECT_MATERIAL)
	var used := {}
	for id: String in materials:
		used[String((materials[id] as Dictionary).get("color", "")).to_upper()] = true
	for index in ids.size():
		var id: String = ids[index]
		var name_key := "material.objet.name"
		var source: Dictionary = items.get(id.substr(OBJECT_PREFIX.length()), {})
		if not source.is_empty():
			name_key = String(source.get("name_key", name_key))
		_add_object_material(id, name_key, _free_object_color(index, ids.size(), used))


## Teinte du n-ième bloc d'objet : le tour de roue divisé en parts égales, avec
## luminosité alternée pour que deux voisins de teinte ne se confondent pas non
## plus. Si la couleur est DÉJÀ PRISE par un matériau existant, on avance d'un
## cran plutôt que d'accepter un doublon — la palette du monde exige l'unicité.
func _free_object_color(index: int, total: int, used: Dictionary) -> String:
	for attempt in 64:
		var hue := fposmod(float(index) / float(maxi(total, 1)) + float(attempt) * 0.0037, 1.0)
		var value := 0.62 if index % 2 == 0 else 0.78
		var hex := ("#" + Color.from_hsv(hue, 0.55, value).to_html(false)).to_upper()
		if not used.has(hex):
			used[hex] = true
			return hex
	return "#B08A55"  # Repli : la sonde de palette dira si on en arrive là.


## Prefixe des matériaux d'objet posé, et matériau de repli.
const OBJECT_PREFIX := "objet_"
const GENERIC_OBJECT_MATERIAL := "objet_divers"


func _add_object_material(id: String, source_name_key: String, color: String) -> void:
	if materials.has(id):
		return  # Un fichier écrit à la main gagne toujours.
	materials[id] = {
		"id": id,
		# LE NOM DE L'OBJET, pas « Objet posé ». Les quarante et un blocs
		# portaient le même libellé générique : dans l'inventaire comme dans la
		# vitrine, une épée posée et une pioche posée s'appelaient pareil.
		"name_key": source_name_key if source_name_key != "" else "material.objet.name",
		"category": "objet",
		# NE SE MAILLE PAS EN CUBE. Un objet posé est rendu par son VRAI modèle
		# (voir PlacedItemManager) : le bloc n'est là que pour occuper la case,
		# être visé et traverser la sauvegarde. Sans ce champ on voyait un cube
		# coloré à la place de l'épée.
		"render": "objet",
		"stats": {
			# INERTE. Un objet posé n'est pas une matière première : il ne se
			# mine pas pour en tirer du minerai, il se REPREND. Les stats sont
			# donc neutres, et sa valeur est celle de l'instance, pas du bloc.
			"durete": 2, "densite": 4, "valeur_base": 1,
			"conductivite_mana": 0, "flammabilite": 20, "isolation": 10,
			"conductivite_electrique": 0, "flottabilite": 20, "luminosite": 0,
			"fertilite": 0, "transparence": 0, "elasticite": 20, "friction": 40,
		},
		"tags": ["objet"],
		"color": color,
		"noise": {"type": "procedural", "seed_offset": 950, "amplitude": 0.05, "scale": 1},
		"harvest": {"tool_category": "mains_nues", "skill": "collecte"},
		"world_gen": {"mode": "aucun", "biome_tags": []},
		"parametric": {"source": "item", "source_id": id.substr(OBJECT_PREFIX.length())},
		"source_name_key": source_name_key,
		# AUCUNE DIMENSION, et c'est exact : un objet posé n'appartient à aucun
		# monde, on l'emporte partout. Le monde vitrine lui fait donc son propre
		# groupe au lieu de le ranger arbitrairement dans l'overworld.
		"dimension": "",
	}
	_derive_tags(materials[id])


## Crée un matériau paramétrique dérivé de `source`, s'il n'existe pas déjà
## en dur dans data/materials (un fichier écrit à la main gagne toujours).
func _add_parametric(id: String, name_key: String, source: Dictionary,
		base_color: String, extra: Dictionary) -> void:
	if materials.has(id) or resources.has(id):
		return
	var mat := {
		"id": id,
		"name_key": name_key,
		"category": "ressource",  # Ni bois ni pierre : ça ne se pose pas.
		"stats": {
			"durete": 2, "densite": 5, "valeur_base": 3 + int(source.get("niveau_combat", 1)),
			"conductivite_mana": 2, "flammabilite": 30, "isolation": 25,
			"conductivite_electrique": 5, "flottabilite": 20, "luminosite": 0,
			"fertilite": 5, "transparence": 0, "elasticite": 20, "friction": 40,
		},
		"tags": ["organique", "animal"],
		"color": _variant_color(base_color, id),
		"noise": {"type": "procedural", "seed_offset": 900, "amplitude": 0.06, "scale": 1},
		"harvest": {"tool_category": "mains_nues", "skill": "collecte"},
		"world_gen": {"mode": "aucun", "biome_tags": []},
		"parametric": {"source": "creature", "source_id": source.get("id", "")},
		# Type d'objet porté par les instances (viande / peau) — sert au
		# libellé de catégorie et aux filtres d'interface.
		"item_kind": "viande" if name_key.ends_with("viande.name") else "peau",
		"source_name_key": source.get("name_key", ""),
	}
	for key: String in extra:
		mat[key] = extra[key]
	_derive_tags(mat)
	resources[id] = mat


## Couleur d'une variante paramétrique : décalage DÉTERMINISTE de la couleur
## du gabarit par le hash de l'id (B.1). Plus aucune recherche de teinte libre
## depuis que l'unicité n'est plus exigée (2026-07-27) — deux variantes ou une
## variante et un bloc peuvent coïncider, c'est sans conséquence : les
## ressources ne sont pas dans la palette du monde, et leur icône est un
## visuel d'objet, pas une face de bloc.
func _variant_color(base_color: String, variant_id: String) -> String:
	var base := Color.html(base_color)
	var offset: int = absi(hash(variant_id)) % 4096
	var color := Color.from_hsv(
		fposmod(base.h + float(offset % 64) / 512.0 - 0.0625, 1.0),
		clampf(base.s + float((offset / 64) % 8) * 0.02 - 0.06, 0.15, 0.95),
		clampf(base.v + float((offset / 512) % 8) * 0.02 - 0.06, 0.15, 0.95))
	return ("#" + color.to_html(false)).to_upper()


## Valide le schéma B.1 d'un matériau. Retourne false si invalide (bloquant).
func _validate_material(mat: Dictionary, path: String) -> bool:
	var ok := true
	for field in ["id", "name_key", "category", "stats", "color", "noise", "harvest", "world_gen"]:
		if not mat.has(field):
			_blocking_error("champ « %s » manquant dans %s" % [field, path])
			ok = false
	if not ok:
		return false

	# Les 13 stats, toutes obligatoires (B.1).
	var stats: Dictionary = mat["stats"] if mat["stats"] is Dictionary else {}
	for key in STAT_KEYS:
		if not stats.has(key):
			_blocking_error("stat « %s » manquante pour le matériau « %s » (%s)" % [key, mat.get("id", "?"), path])
			ok = false

	# Catégorie connue (B.2).
	if not material_categories.has(mat["category"]):
		_blocking_error("catégorie inconnue « %s » pour le matériau « %s » (absente de material_categories.json)" % [mat["category"], mat.get("id", "?")])
		ok = false

	# Couleur hexadécimale valide.
	if not Color.html_is_valid(String(mat["color"])):
		_blocking_error("couleur invalide « %s » pour le matériau « %s »" % [mat["color"], mat.get("id", "?")])
		ok = false

	# Paramètres de bruit (9.1/G.2 : bruit généré en shader).
	var noise: Dictionary = mat["noise"] if mat["noise"] is Dictionary else {}
	for key in ["type", "seed_offset", "amplitude", "scale"]:
		if not noise.has(key):
			_blocking_error("paramètre de bruit « %s » manquant pour le matériau « %s »" % [key, mat.get("id", "?")])
			ok = false

	# Nutrition (A.9/A.9.1) — bloc OPTIONNEL : seuls les matériaux comestibles
	# le portent. `faim` = valeur nutritive PLEINE (celle du plat cuisiné) ;
	# `cuit` = false pour un ingrédient cru, qui n'en rend que 50 % (A.9.1).
	if mat.has("nutrition"):
		var nutrition: Dictionary = mat["nutrition"] if mat["nutrition"] is Dictionary else {}
		if not nutrition.has("faim"):
			_blocking_error("bloc « nutrition » sans « faim » pour le matériau « %s »" % mat.get("id", "?"))
			ok = false
		elif float(nutrition["faim"]) <= 0.0:
			_blocking_error("nutrition.faim doit être > 0 pour le matériau « %s »" % mat.get("id", "?"))
			ok = false
		if not nutrition.has("cuit"):
			_blocking_error("bloc « nutrition » sans « cuit » pour le matériau « %s »" % mat.get("id", "?"))
			ok = false
	return ok


## Tags dérivés automatiquement des stats (B.1) — les systèmes à tags
## (section 10) réagissent aux tags, les formules fines aux valeurs graduées.
func _derive_tags(mat: Dictionary) -> void:
	var tags: Array = mat.get("tags", [])
	var stats: Dictionary = mat["stats"]
	for stat in DERIVED_TAGS:
		if int(stats.get(stat, 0)) >= DERIVED_TAG_THRESHOLD and not tags.has(DERIVED_TAGS[stat]):
			tags.append(DERIVED_TAGS[stat])
	mat["tags"] = tags


## Couches de bruit (B.8) : les 8 couches obligatoires, avec leurs champs.
func _load_noise_layers() -> void:
	var raw: Variant = _load_json(PATH_NOISE_LAYERS)
	noise_layers = raw if raw is Dictionary else {}
	for key in NOISE_LAYER_KEYS:
		if not noise_layers.has(key):
			_blocking_error("couche de bruit « %s » manquante dans %s" % [key, PATH_NOISE_LAYERS])
			continue
		var layer: Dictionary = noise_layers[key]
		for field in ["type", "octaves", "frequency", "seed_offset"]:
			if not layer.has(field):
				_blocking_error("champ « %s » manquant pour la couche de bruit « %s »" % [field, key])


## Biomes (B.6) : champs requis + références de matériaux existantes.
func _load_biomes() -> void:
	biomes.clear()
	for path in _list_json_recursive(PATH_BIOMES):
		var raw: Variant = _load_json(path)
		if not (raw is Dictionary):
			continue
		var biome: Dictionary = raw
		var ok := true
		for field in ["id", "name_key", "conditions", "priority", "surface_material", "subsurface_material"]:
			if not biome.has(field):
				_blocking_error("champ « %s » manquant dans %s" % [field, path])
				ok = false
		if not ok:
			continue
		for mat_field in ["surface_material", "subsurface_material"]:
			if not materials.has(biome[mat_field]):
				_blocking_error("matériau inconnu « %s » (%s) dans le biome « %s »" % [biome[mat_field], mat_field, biome["id"]])
		var conditions: Dictionary = biome["conditions"] if biome["conditions"] is Dictionary else {}
		for layer in conditions:
			if not NOISE_LAYER_KEYS.has(layer):
				_blocking_error("condition sur couche de bruit inconnue « %s » dans le biome « %s »" % [layer, biome["id"]])
			elif not (conditions[layer] is Array and (conditions[layer] as Array).size() == 2):
				_blocking_error("condition « %s » du biome « %s » : intervalle [min, max] attendu" % [layer, biome["id"]])
		if biomes.has(biome["id"]):
			_blocking_error("id de biome dupliqué « %s » (%s)" % [biome["id"], path])
			continue
		# Dimension = dossier parent sous data/biomes/ (overworld/magique/…).
		# Un biome directement sous data/biomes est supposé overworld (compat).
		var folder := path.get_base_dir().get_file()
		biome["dimension"] = "overworld" if folder == "biomes" else folder
		biomes[biome["id"]] = biome


## Strates par profondeur (G.9) : matériaux existants, y_max décroissants.
func _load_strata() -> void:
	var raw: Variant = _load_json(PATH_STRATA)
	strata = raw if raw is Array else []
	var previous_y_max := 1 << 30
	for stratum: Variant in strata:
		if not (stratum is Dictionary):
			_blocking_error("entrée de strate invalide dans %s" % PATH_STRATA)
			continue
		for field in ["material", "y_max", "transition"]:
			if not stratum.has(field):
				_blocking_error("champ « %s » manquant dans une strate de %s" % [field, PATH_STRATA])
		if stratum.has("material") and not materials.has(stratum["material"]):
			_blocking_error("matériau de strate inconnu « %s »" % stratum["material"])
		if stratum.has("y_max"):
			if int(stratum["y_max"]) > previous_y_max:
				_blocking_error("strates non ordonnées (y_max croissant) dans %s" % PATH_STRATA)
			previous_y_max = int(stratum["y_max"])


## Bandes de minerais (G.9) : matériaux existants, profondeurs cohérentes,
## hôtes (fossiles) référençant des matériaux existants.
func _load_ore_bands() -> void:
	var raw: Variant = _load_json(PATH_ORE_BANDS)
	ore_bands = raw if raw is Array else []
	for band: Variant in ore_bands:
		if not (band is Dictionary):
			_blocking_error("entrée de bande de minerai invalide dans %s" % PATH_ORE_BANDS)
			continue
		for field in ["material", "depth_min", "depth_max", "weight"]:
			if not band.has(field):
				_blocking_error("champ « %s » manquant dans une bande de %s" % [field, PATH_ORE_BANDS])
		if band.has("material") and not materials.has(band["material"]):
			_blocking_error("matériau de minerai inconnu « %s » (%s)" % [band["material"], PATH_ORE_BANDS])
		if int(band.get("depth_min", 0)) > int(band.get("depth_max", 0)):
			_blocking_error("bande « %s » : depth_min > depth_max" % band.get("material", "?"))
		for host in band.get("host", []):
			if not materials.has(host):
				_blocking_error("hôte de minerai inconnu « %s » (bande « %s »)" % [host, band.get("material", "?")])


## Compétences (C.4/6.0) : id, name_key, category combat|general.
func _load_skills() -> void:
	skills.clear()
	for path in _list_json_recursive(PATH_SKILLS):
		var raw: Variant = _load_json(path)
		if not (raw is Dictionary):
			continue
		var skill: Dictionary = raw
		var ok := true
		for field in ["id", "name_key", "category"]:
			if not skill.has(field):
				_blocking_error("champ « %s » manquant dans %s" % [field, path])
				ok = false
		if ok and not (skill["category"] in ["combat", "general"]):
			_blocking_error("category « %s » invalide (combat|general) dans %s" % [skill["category"], path])
			ok = false
		if ok:
			if skills.has(skill["id"]):
				_blocking_error("id de compétence dupliqué « %s »" % skill["id"])
			else:
				skills[skill["id"]] = skill


## Fonctionnalités (B.3.1) : profil mécanique porté par un objet.
func _load_functionalities() -> void:
	functionalities.clear()
	for path in _list_json_recursive(PATH_FUNCTIONALITIES):
		var raw: Variant = _load_json(path)
		if not (raw is Dictionary):
			continue
		var func_def: Dictionary = raw
		var ok := true
		for field in ["id", "name_key", "kind"]:
			if not func_def.has(field):
				_blocking_error("champ « %s » manquant dans %s" % [field, path])
				ok = false
		if ok:
			if functionalities.has(func_def["id"]):
				_blocking_error("id de fonctionnalité dupliqué « %s »" % func_def["id"])
			else:
				functionalities[func_def["id"]] = func_def


## Objets / recettes (B.3) : champs requis + références existantes.
func _load_items() -> void:
	items.clear()
	for path in _list_json_recursive(PATH_ITEMS):
		var raw: Variant = _load_json(path)
		if not (raw is Dictionary):
			continue
		var item: Dictionary = raw
		var ok := true
		# Une ARMURE (6.2) n'a pas de `functionality` — elle ne sert pas à
		# frapper ni à récolter : elle porte un `equip_slot` et contribue des
		# dés de réduction (A.4.2). Tout autre type exige sa fonctionnalité.
		var is_armor := String(item.get("type", "")) == "armure"
		# Un LIVRE (5.1, 2026-08-02) n'a ni fonctionnalité ni emplacement : il ne
		# frappe pas, ne se récolte pas et ne se porte pas. Il se LIT, et c'est
		# son seul usage. Il n'a pas non plus de recette réelle — le GDD est
		# explicite : « les modules ne se craftent pas », les livres se trouvent
		# en donjon ou s'achètent.
		var is_book := String(item.get("type", "")) == "livre"
		var required := ["id", "name_key", "type", "recipe", "stat_weights"]
		if is_armor:
			required.append("equip_slot")
		elif not is_book:
			required.append("functionality")
		for field in required:
			if not item.has(field):
				_blocking_error("champ « %s » manquant dans %s" % [field, path])
				ok = false
		if not ok:
			continue
		if is_book:
			pass  # Rien de plus à valider : ni emplacement ni fonctionnalité.
		elif is_armor:
			if not (String(item["equip_slot"]) in Equipment.SLOTS
					or Equipment.SLOT_GROUPS.has(String(item["equip_slot"]))):
				_blocking_error("emplacement d'équipement inconnu « %s » dans l'objet « %s » (6.2)" % [
						item["equip_slot"], item["id"]])
		elif not functionalities.has(item["functionality"]):
			_blocking_error("fonctionnalité inconnue « %s » dans l'objet « %s »" % [item["functionality"], item["id"]])
		var recipe: Dictionary = item["recipe"] if item["recipe"] is Dictionary else {}
		for input: Variant in recipe.get("inputs", []):
			if input is Dictionary and not material_categories.has(input.get("category", "")):
				_blocking_error("catégorie de recette inconnue « %s » dans l'objet « %s »" % [input.get("category", "?"), item["id"]])
		# Modèle .vox référencé (B.3) : absence = warning (remap 9.1 impossible).
		var vox_path := String(item.get("vox_model", ""))
		if vox_path != "" and not FileAccess.file_exists(vox_path if vox_path.begins_with("res://") else "res://" + vox_path):
			push_warning("GameData : modèle .vox introuvable « %s » (objet « %s »)." % [vox_path, item["id"]])
		# Sprites d'outil/arme (ToolSprite) : même règle que le .vox ci-dessus —
		# absence = warning. Ajouté après le rangement d'assets/ (2026-07-26) :
		# un déplacement de fichier cassait les icônes SANS aucun signal au boot.
		for part: String in (item.get("sprites", {}) as Dictionary):
			var sprite_path := String(item["sprites"][part])
			if sprite_path != "" and not FileAccess.file_exists(sprite_path):
				push_warning("GameData : sprite « %s » introuvable (%s de l'objet « %s »)." % [
						sprite_path, part, item["id"]])
		if items.has(item["id"]):
			_blocking_error("id d'objet dupliqué « %s »" % item["id"])
		else:
			items[item["id"]] = item


## Essences d'arbres (TreeGenerator) : bois/feuilles doivent exister, hauteur
## et rayons cohérents. `special_tags` piloté par les systèmes (10 : tags),
## ex. "contient_liquide" (baobab).
func _load_trees() -> void:
	trees.clear()
	for path in _list_json_recursive(PATH_TREES):
		var raw: Variant = _load_json(path)
		if not (raw is Dictionary):
			continue
		var tree: Dictionary = raw
		var ok := true
		for field in ["id", "name_key", "wood_material", "leaf_material", "height_range", "trunk_radius", "branch_parameters", "canopy_shape", "canopy_radius_range"]:
			if not tree.has(field):
				_blocking_error("champ « %s » manquant dans %s" % [field, path])
				ok = false
		if not ok:
			continue
		if not materials.has(tree["wood_material"]):
			_blocking_error("matériau de bois inconnu « %s » pour l'arbre « %s »" % [tree["wood_material"], tree["id"]])
		if not materials.has(tree["leaf_material"]):
			_blocking_error("matériau de feuilles inconnu « %s » pour l'arbre « %s »" % [tree["leaf_material"], tree["id"]])
		# LA LISTE FAIT FOI CÔTÉ GÉNÉRATEUR, pas ici : elle était recopiée à la
		# main dans ce fichier, si bien qu'ajouter une silhouette au générateur
		# faisait échouer 25 arbres au boot sans que le générateur soit en cause.
		if not (tree["canopy_shape"] in TreeGenerator.CANOPY_SHAPES):
			_blocking_error("canopy_shape invalide « %s » pour l'arbre « %s »" % [tree["canopy_shape"], tree["id"]])
		# Dimension = dossier parent sous data/trees/ (même règle que les
		# biomes et les matériaux).
		var tree_folder := path.get_base_dir().get_file()
		tree["dimension"] = "overworld" if tree_folder == "trees" else tree_folder
		if trees.has(tree["id"]):
			_blocking_error("id d'essence d'arbre dupliqué « %s »" % tree["id"])
		else:
			tree["_source"] = path
		trees[tree["id"]] = tree


## Plantes non-arborescentes en sous-voxels (2026-07-20, PlantGenerator) :
## data/plants/*.json — validation légère, la structure `morphology`/
## `materials` reste libre (interprétée par PlantGenerator, pas ici).
## Répliques d'ambiance. Un gabarit mal formé est SIGNALÉ et ignoré, pas
## bloquant : une réplique manquante appauvrit le dialogue, elle n'empêche pas
## de jouer — contrairement à un matériau inconnu, qui casse la génération.
func _load_dialogue() -> void:
	dialogue_lines.clear()
	for path in _list_json_recursive("res://data/dialogue"):
		var raw: Variant = _load_json(path)
		if not (raw is Dictionary):
			continue
		for entry: Variant in (raw as Dictionary).get("lignes", []):
			if not (entry is Dictionary):
				continue
			var line: Dictionary = entry
			if not line.has("id") or not line.has("text_key"):
				push_warning("GameData : réplique sans id/text_key dans %s" % path)
				continue
			dialogue_lines.append(line)


func _load_plants() -> void:
	plants.clear()
	for path in _list_json_recursive(PATH_PLANTS):
		var raw: Variant = _load_json(path)
		if not (raw is Dictionary):
			continue
		var plant: Dictionary = raw
		var ok := true
		for field in ["id", "name_key", "resolution", "materials", "morphology"]:
			if not plant.has(field):
				_blocking_error("champ « %s » manquant dans %s" % [field, path])
				ok = false
		if not ok:
			continue
		var mats: Dictionary = plant["materials"] if plant["materials"] is Dictionary else {}
		for key in mats:
			if not materials.has(mats[key]):
				_blocking_error("matériau inconnu « %s » (%s) pour la plante « %s »" % [mats[key], key, plant["id"]])
		if plants.has(plant["id"]):
			_blocking_error("id de plante dupliqué « %s »" % plant["id"])
		else:
			plants[plant["id"]] = plant


## Cultures de nommage (12.5, schéma B.11, catalogue C.9).
##
## La validation est PLUS STRICTE que pour les autres collections, pour une
## raison précise : un pool vide ne plante pas, il produit un nom TRONQUÉ.
## « Marc » sans suffixe, ou pire une chaîne vide, se serait glissé en jeu
## sans un message d'erreur — et le seul symptôme aurait été des PNJ à moitié
## anonymes, qu'on met longtemps à relier à un fichier de données.
## Exception unique : `famille_b` a le droit d'être `[""]`, c'est la
## convention de B.11 pour les cultures à noms de famille pleins (le sino).
func _load_name_cultures() -> void:
	name_cultures.clear()
	var pools := ["prenom_a", "prenom_b", "famille_a", "famille_b", "ville_a", "ville_b"]
	for path in _list_json_recursive(PATH_NAME_CULTURES):
		var raw: Variant = _load_json(path)
		if not (raw is Dictionary):
			continue
		var culture: Dictionary = raw
		var ok := true
		for field in ["id", "name_key", "name_order", "race_affinity", "titres"]:
			if not culture.has(field):
				_blocking_error("champ « %s » manquant dans %s" % [field, path])
				ok = false
		for pool_name: String in pools:
			var pool: Variant = culture.get(pool_name)
			if not (pool is Array) or (pool as Array).is_empty():
				_blocking_error("pool « %s » absent ou vide dans %s" % [pool_name, path])
				ok = false
				continue
			# Un pool ne doit pas contenir d'entrée vide, SAUF famille_b (B.11).
			if pool_name == "famille_b":
				continue
			for entry: Variant in (pool as Array):
				if String(entry).strip_edges() == "":
					_blocking_error("entrée vide dans le pool « %s » de %s" % [pool_name, path])
					ok = false
					break
		var order := String(culture.get("name_order", ""))
		if order != "prenom_nom" and order != "nom_prenom":
			_blocking_error("name_order « %s » inconnu dans %s (attendu prenom_nom ou nom_prenom)" % [order, path])
			ok = false
		if not ok:
			continue
		if name_cultures.has(culture["id"]):
			_blocking_error("id de culture dupliqué « %s »" % culture["id"])
		else:
			name_cultures[culture["id"]] = culture


## Salles de donjon (E.29, B.10 SIMPLIFIÉ) : data/dungeon_rooms/*.json —
## géométrie en boîte (`size`) + points d'attache (`doors`), pas de vrai
## `vox_model` pour l'instant (DungeonGenerator construit la salle en blocs
## pleins directement — voir sa doc pour la déviation assumée).
func _load_dungeon_rooms() -> void:
	dungeon_rooms.clear()
	for path in _list_json_recursive(PATH_DUNGEON_ROOMS):
		var raw: Variant = _load_json(path)
		if not (raw is Dictionary):
			continue
		var room: Dictionary = raw
		var ok := true
		for field in ["id", "size_category", "size", "doors"]:
			if not room.has(field):
				_blocking_error("champ « %s » manquant dans %s" % [field, path])
				ok = false
		if not ok:
			continue
		if dungeon_rooms.has(room["id"]):
			_blocking_error("id de salle de donjon dupliqué « %s »" % room["id"])
		else:
			dungeon_rooms[room["id"]] = room


## Connecteurs de donjon (E.29, B.10 SIMPLIFIÉ) : data/dungeon_connectors/*.json
## — corridor droit uniquement pour cette passe (pas d'escalier, un seul
## étage, voir DungeonGenerator).
func _load_dungeon_connectors() -> void:
	dungeon_connectors.clear()
	for path in _list_json_recursive(PATH_DUNGEON_CONNECTORS):
		var raw: Variant = _load_json(path)
		if not (raw is Dictionary):
			continue
		var conn: Dictionary = raw
		var ok := true
		for field in ["id", "type", "length", "doors"]:
			if not conn.has(field):
				_blocking_error("champ « %s » manquant dans %s" % [field, path])
				ok = false
		if not ok:
			continue
		if dungeon_connectors.has(conn["id"]):
			_blocking_error("id de connecteur de donjon dupliqué « %s »" % conn["id"])
		else:
			dungeon_connectors[conn["id"]] = conn


## Modules de compétence (B.4) : sorts/attaques assemblables (section 5).
func _load_status_effects() -> void:
	status_effects.clear()
	for path in _list_json_recursive(PATH_STATUS_EFFECTS):
		var raw: Variant = _load_json(path)
		if not (raw is Dictionary):
			continue
		var status: Dictionary = raw
		for field in ["id", "name_key", "duration_ticks"]:
			if not status.has(field):
				_blocking_error("champ « %s » manquant dans %s" % [field, path])
				return
		status_effects[status["id"]] = status


func _load_reading_failures() -> void:
	var raw: Variant = _load_json(PATH_READING_FAILURES)
	reading_failures = raw if raw is Dictionary else {}


func _load_modules() -> void:
	modules.clear()
	for path in _list_json_recursive(PATH_MODULES):
		var raw: Variant = _load_json(path)
		if not (raw is Dictionary):
			continue
		var module: Dictionary = raw
		var ok := true
		for field in ["id", "name_key", "module_type", "mana_cost_base", "power_base"]:
			if not module.has(field):
				_blocking_error("champ « %s » manquant dans %s" % [field, path])
				ok = false
		if ok and not (module["module_type"] in ["effet", "modificateur", "declencheur"]):
			_blocking_error("module_type « %s » invalide dans %s" % [module["module_type"], path])
			ok = false
		if ok:
			if modules.has(module["id"]):
				_blocking_error("id de module dupliqué « %s »" % module["id"])
			else:
				modules[module["id"]] = module


## Créatures / PNJ (B.5) : squelette modulaire (12), stats de base, IA,
## combat minimal (étape D.3.6 — arme + modules).
## Gabarits de zones de coup (combat directionnel). Chaque zone est validée
## ici, une fois au démarrage : le balayage de lame tourne à la frame et n'a
## pas à se défendre contre des données malformées.
func _load_hitbox_templates() -> void:
	hitbox_templates.clear()
	var raw: Variant = _load_json(PATH_HITBOX_TEMPLATES)
	if not (raw is Dictionary):
		_blocking_error("hitbox_templates.json illisible ou absent")
		return
	var templates: Variant = (raw as Dictionary).get("templates")
	if not (templates is Dictionary):
		_blocking_error("hitbox_templates.json : champ « templates » manquant")
		return
	for template_id: String in (templates as Dictionary):
		var zones: Variant = (templates as Dictionary)[template_id]
		if not (zones is Array) or (zones as Array).is_empty():
			_blocking_error("gabarit de hitbox « %s » vide ou mal formé" % template_id)
			continue
		var parsed: Array = []
		for zone: Variant in (zones as Array):
			if not (zone is Dictionary):
				_blocking_error("zone mal formée dans le gabarit « %s »" % template_id)
				continue
			var z: Dictionary = zone
			var ok := true
			for field in ["id", "min", "size", "mult"]:
				if not z.has(field):
					_blocking_error("zone du gabarit « %s » : champ « %s » manquant" % [template_id, field])
					ok = false
			if not ok:
				continue
			var mn: Array = z["min"]
			var sz: Array = z["size"]
			if mn.size() != 3 or sz.size() != 3:
				_blocking_error("zone « %s » du gabarit « %s » : min/size doivent avoir 3 composantes" % [z["id"], template_id])
				continue
			if sz[0] <= 0.0 or sz[1] <= 0.0 or sz[2] <= 0.0:
				_blocking_error("zone « %s » du gabarit « %s » : size doit être strictement positive" % [z["id"], template_id])
				continue
			# Pré-converti en Vector3 : le test d'intersection tourne par frame,
			# il ne doit pas repasser par des Array JSON à chaque coup.
			parsed.append({
				"id": String(z["id"]),
				"min": Vector3(mn[0], mn[1], mn[2]),
				"max": Vector3(mn[0] + sz[0], mn[1] + sz[1], mn[2] + sz[2]),
				"mult": float(z["mult"]),
			})
		if not parsed.is_empty():
			hitbox_templates[template_id] = parsed


## Efficacité de l'armure par type de dégât. La table DOIT contenir une ligne
## « _defaut » : une catégorie de matériau non listée ne doit jamais faire
## planter une résolution de coup, elle doit être neutre.
func _load_armor_type_modifiers() -> void:
	armor_type_modifiers.clear()
	var raw: Variant = _load_json(PATH_ARMOR_TYPE_MODIFIERS)
	if not (raw is Dictionary):
		_blocking_error("armor_type_modifiers.json illisible ou absent")
		return
	var table: Variant = (raw as Dictionary).get("modifiers")
	if not (table is Dictionary):
		_blocking_error("armor_type_modifiers.json : champ « modifiers » manquant")
		return
	armor_type_modifiers = table
	if not armor_type_modifiers.has("_defaut"):
		_blocking_error("armor_type_modifiers.json : ligne « _defaut » obligatoire")


## Pieces d'arme. Le modele de chaque piece est verifie ici, une fois : une
## arme dont la piece manque doit se signaler au demarrage, pas au moment ou
## un joueur la fabrique.
func _load_weapon_parts() -> void:
	var raw: Variant = _load_json(PATH_WEAPON_PARTS)
	if not (raw is Dictionary):
		_blocking_error("weapon_parts.json illisible ou absent")
		return
	for table_name in ["manches", "tetes"]:
		var table: Variant = (raw as Dictionary).get(table_name)
		if not (table is Dictionary):
			_blocking_error("weapon_parts.json : table « %s » manquante" % table_name)
			continue
		for part_id: String in (table as Dictionary):
			var part: Dictionary = (table as Dictionary)[part_id]
			var model := String(part.get("model", ""))
			if model == "" or not FileAccess.file_exists(model):
				_blocking_error("piece d'arme « %s » : modele introuvable « %s »" % [part_id, model])
			weapon_parts[table_name][part_id] = part


func _load_creatures() -> void:
	creatures.clear()
	for path in _list_json_recursive(PATH_CREATURES):
		var raw: Variant = _load_json(path)
		if not (raw is Dictionary):
			continue
		var creature: Dictionary = raw
		var ok := true
		for field in ["id", "name_key", "skeleton_template", "race", "base_stats", "ai_profile", "tags"]:
			if not creature.has(field):
				_blocking_error("champ « %s » manquant dans %s" % [field, path])
				ok = false
		if not ok:
			continue
		# Gabarit de zones de coup : sans lui, la créature serait intouchable en
		# combat directionnel — c'est une erreur bloquante, pas un warning.
		if not hitbox_templates.has(creature["skeleton_template"]):
			_blocking_error("gabarit de hitbox inconnu « %s » pour la créature « %s »" % [
					creature["skeleton_template"], creature["id"]])
		var combat: Dictionary = creature.get("combat", {})
		if combat.has("functionality") and not functionalities.has(combat["functionality"]):
			_blocking_error("fonctionnalité de combat inconnue « %s » pour la créature « %s »" % [combat["functionality"], creature["id"]])
		for module_id: String in combat.get("modules", []):
			if not modules.has(module_id):
				_blocking_error("module inconnu « %s » pour la créature « %s »" % [module_id, creature["id"]])
		# Modèle Blockbench (B.5/12.1) : absence = warning, comme les .vox
		# d'items — une créature sans modèle tombe sur la capsule provisoire.
		var model_path := String(creature.get("model", ""))
		if model_path != "" and not FileAccess.file_exists(model_path):
			push_warning("GameData : modèle de créature introuvable « %s » (« %s »)." % [
					model_path, creature["id"]])
		if creatures.has(creature["id"]):
			_blocking_error("id de créature dupliqué « %s »" % creature["id"])
		else:
			creatures[creature["id"]] = creature


## Races (C.2) : bonus de stats valides, potentiels de base référençant des
## compétences existantes (avertissement sinon).
func _load_races() -> void:
	races.clear()
	for path in _list_json_recursive(PATH_RACES):
		var raw: Variant = _load_json(path)
		if not (raw is Dictionary):
			continue
		var race: Dictionary = raw
		var ok := true
		for field in ["id", "name_key", "stat_bonuses"]:
			if not race.has(field):
				_blocking_error("champ « %s » manquant dans %s" % [field, path])
				ok = false
		if not ok:
			continue
		for stat in (race["stat_bonuses"] as Dictionary):
			if not CHARACTER_STATS.has(stat):
				_blocking_error("stat inconnue « %s » dans le bonus de la race « %s »" % [stat, race["id"]])
		for skill_id in (race.get("base_potentials", {}) as Dictionary):
			if not skills.has(skill_id):
				push_warning("GameData : potentiel de base pour compétence inconnue « %s » (race « %s »)." % [skill_id, race["id"]])
		if races.has(race["id"]):
			_blocking_error("id de race dupliqué « %s »" % race["id"])
		else:
			races[race["id"]] = race


## Classes (C.3) : bonus de stats, compétences/objets/matériaux de départ
## référençant du contenu existant.
func _load_classes() -> void:
	classes.clear()
	for path in _list_json_recursive(PATH_CLASSES):
		var raw: Variant = _load_json(path)
		if not (raw is Dictionary):
			continue
		var cls: Dictionary = raw
		var ok := true
		for field in ["id", "name_key", "stat_bonuses", "starting_skills", "starting_items"]:
			if not cls.has(field):
				_blocking_error("champ « %s » manquant dans %s" % [field, path])
				ok = false
		if not ok:
			continue
		for stat in (cls["stat_bonuses"] as Dictionary):
			if not CHARACTER_STATS.has(stat):
				_blocking_error("stat inconnue « %s » dans le bonus de la classe « %s »" % [stat, cls["id"]])
		for skill_id in (cls["starting_skills"] as Dictionary):
			if not skills.has(skill_id):
				_blocking_error("compétence de départ inconnue « %s » (classe « %s »)" % [skill_id, cls["id"]])
		for entry: Variant in cls["starting_items"]:
			if entry is Dictionary and not items.has(entry.get("item_id", "")):
				_blocking_error("objet de départ inconnu « %s » (classe « %s »)" % [entry.get("item_id", "?"), cls["id"]])
		for mat_id in (cls.get("starting_materials", {}) as Dictionary):
			if not materials.has(mat_id):
				_blocking_error("matériau de départ inconnu « %s » (classe « %s »)" % [mat_id, cls["id"]])
		if classes.has(cls["id"]):
			_blocking_error("id de classe dupliqué « %s »" % cls["id"])
		else:
			classes[cls["id"]] = cls


## Transformations à station (4.2/C.8) : minerai→lingot, etc. — input/output
## référençant des matériaux existants, skill existant.
func _load_transformations() -> void:
	transformations.clear()
	for path in _list_json_recursive(PATH_TRANSFORMATIONS):
		var raw: Variant = _load_json(path)
		if not (raw is Dictionary):
			continue
		var tr_def: Dictionary = raw
		var ok := true
		for field in ["id", "name_key", "station", "skill", "output"]:
			if not tr_def.has(field):
				_blocking_error("champ « %s » manquant dans %s" % [field, path])
				ok = false
		if not tr_def.has("input") and not tr_def.has("inputs"):
			_blocking_error("« input » ou « inputs » manquant dans %s" % path)
			ok = false
		if not ok:
			continue
		if not skills.has(tr_def["skill"]):
			_blocking_error("compétence inconnue « %s » (transformation « %s »)" % [tr_def["skill"], tr_def["id"]])
		# La SORTIE est toujours un matériau précis ; l'ENTRÉE peut être un
		# matériau précis (fonte minerai→lingot) OU une CATÉGORIE (2026-07-26 :
		# établi = « 4 bois », le joueur choisit l'essence).
		var out_mat: String = (tr_def["output"] as Dictionary).get("material", "")
		if not materials.has(out_mat):
			_blocking_error("matériau output inconnu « %s » (transformation « %s »)" % [out_mat, tr_def["id"]])
		# Entrée(s) : `input` unique OU `inputs` (liste, pour les alliages multi-
		# ingrédients acier=fer+charbon). Chaque entrée = matériau OU catégorie.
		var in_list: Array = tr_def["inputs"] if tr_def.has("inputs") else [tr_def.get("input", {})]
		for in_def: Dictionary in in_list:
			if in_def.has("category"):
				if not material_categories.has(in_def["category"]):
					_blocking_error("catégorie input inconnue « %s » (transformation « %s »)" % [in_def["category"], tr_def["id"]])
			elif not materials.has(in_def.get("material", "")):
				_blocking_error("matériau input inconnu « %s » (transformation « %s »)" % [in_def.get("material", ""), tr_def["id"]])
		if transformations.has(tr_def["id"]):
			_blocking_error("id de transformation dupliqué « %s »" % tr_def["id"])
		else:
			transformations[tr_def["id"]] = tr_def


## Validation au boot des clés de traduction (10.1) : chaque name_key doit
## exister dans chaque locale — clé manquante = warning, jamais de crash.
func _validate_translation_keys() -> void:
	var name_keys: Array[String] = []
	for collection: Dictionary in [materials, biomes, skills, functionalities, items, modules, creatures, trees, plants, races, classes, transformations]:
		for id in collection:
			name_keys.append(collection[id]["name_key"])
	for locale in VALIDATED_LOCALES:
		var translation := TranslationServer.get_translation_object(locale)
		if translation == null:
			push_warning("Localisation : aucune traduction chargée pour la locale « %s »." % locale)
			continue
		for key in name_keys:
			if translation.get_message(key) == &"":
				push_warning("Localisation : clé « %s » absente de la locale « %s »." % [key, locale])
	# Locales en cours : taux de couverture, pas d'avertissement par clé.
	# Mesuré sur TOUTES les clés de la locale de référence (anglais), pas
	# seulement les noms d'objets — c'est l'interface entière qu'il faut
	# traduire, et son volume ne se déduit pas des données.
	# La liste des clés vient du CSV de référence, PAS de l'objet Translation :
	# un .translation compilé (OptimizedTranslation) stocke ses messages dans
	# une table de hachage et get_message_list() y retourne toujours vide — la
	# couverture se calculait donc sur 0 clé et affichait « 0 / 0 ».
	var all_keys := _reference_keys()
	if all_keys.is_empty():
		all_keys = name_keys  # Repli : au moins les noms issus des données.
	for locale in PARTIAL_LOCALES:
		var translation := TranslationServer.get_translation_object(locale)
		if translation == null:
			# Silencieux = invisible : une locale déclarée mais non chargée
			# (fichier absent de project.godot, ou non réimporté après édition
			# du CSV) doit se voir, sinon on croit traduire dans le vide.
			push_warning("Localisation : locale « %s » déclarée mais AUCUNE traduction chargée (project.godot / réimport ?)." % locale)
			continue
		var traduites := 0
		for key: String in all_keys:
			var value := String(translation.get_message(key))
			if value != "" and value != key:
				traduites += 1
		var total := all_keys.size()
		var pourcent := 100.0 * float(traduites) / maxf(1.0, float(total))
		print("Localisation : « %s » traduite à %.0f %% (%d / %d clés) — le reste retombe sur l'anglais." % [
				locale, pourcent, traduites, total])


## Toutes les clés de traduction, lues dans le CSV de référence (anglais).
## Vide si le CSV n'est pas disponible (build exporté : seuls les
## .translation sont embarqués) — l'appelant retombe alors sur les noms de
## données, qu'il connaît toujours.
func _reference_keys() -> Array[String]:
	var keys: Array[String] = []
	var path := "res://locale/en.csv"
	if not FileAccess.file_exists(path):
		return keys
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return keys
	var first := true
	while not file.eof_reached():
		var row := file.get_csv_line()
		if first:
			first = false
			continue  # En-tête « keys,en ».
		if row.size() >= 1 and String(row[0]) != "":
			keys.append(String(row[0]))
	return keys


## Définition d'un EMPILABLE d'inventaire, matériau ou ressource. Tout code
## qui manipule le CONTENU d'un inventaire (nom, couleur, poids, valeur) doit
## passer par ici ; seul le code du MONDE (meshing, pose, palette) interroge
## `materials` directement — une ressource n'y figure pas, ce qui rend une
## viande non plaçable par construction plutôt que par une vérification qu'on
## pourrait oublier quelque part.
func stackable(id: String) -> Dictionary:
	var entry: Variant = materials.get(id)
	if entry != null:
		return entry
	return resources.get(id, {})


## true si `id` désigne un bloc posable dans le monde.
func is_placeable(id: String) -> bool:
	return materials.has(id)


## Aplatis toutes les couleurs réservées en { "#HEX": description }.
func _all_reserved_colors() -> Dictionary:
	var result: Dictionary = {}
	for group in reserved_colors:
		var entries: Variant = reserved_colors[group]
		if entries is Dictionary:
			for hex in entries:
				result[String(hex).to_upper()] = "%s:%s" % [group, entries[hex]]
	return result


func _load_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		_blocking_error("fichier introuvable : %s" % path)
		return null
	var text := FileAccess.get_file_as_string(path)
	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		_blocking_error("JSON invalide dans %s (ligne %d : %s)" % [path, json.get_error_line(), json.get_error_message()])
		return null
	return json.data


func _blocking_error(message: String) -> void:
	_blocking_errors += 1
	push_error("GameData : " + message)

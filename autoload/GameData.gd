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
const PATH_CREATURES := "res://data/creatures"
const PATH_TREES := "res://data/trees"
const PATH_PLANTS := "res://data/plants"
const PATH_DUNGEON_ROOMS := "res://data/dungeon_rooms"
const PATH_DUNGEON_CONNECTORS := "res://data/dungeon_connectors"
const PATH_RACES := "res://data/races"
const PATH_CLASSES := "res://data/classes"
const PATH_TRANSFORMATIONS := "res://data/transformations"

## Les 6 stats de personnage (C.1) — pour la validation des bonus race/classe.
const CHARACTER_STATS: Array[String] = [
	"force", "dexterite", "endurance", "volonte", "perception", "charisme",
]

## Locales dont les clés sont validées au boot (10.1 — ja/zh s'ajouteront ici).
const VALIDATED_LOCALES: Array[String] = ["fr", "en"]

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
## Créatures / PNJ (B.5).
var creatures: Dictionary = {}
## Essences d'arbres (génération procédurale, TreeGenerator).
var trees: Dictionary = {}
## Plantes non-arborescentes en sous-voxels (2026-07-20, PlantGenerator) —
## data/plants/*.json.
var plants: Dictionary = {}
## Salles/connecteurs de donjon (E.29, DungeonGenerator) — data/dungeon_rooms
## et data/dungeon_connectors/*.json (B.10, géométrie simplifiée en boîtes —
## pas de vox_model réel pour l'instant, voir DungeonGenerator).
var dungeon_rooms: Dictionary = {}
var dungeon_connectors: Dictionary = {}
## Races (C.2) et classes (C.3) de création de personnage (6.1).
var races: Dictionary = {}
var classes: Dictionary = {}
## Transformations à station (4.2/C.8) : minerai→lingot, etc. (data/transformations).
var transformations: Dictionary = {}

var _blocking_errors: int = 0


func _ready() -> void:
	load_all()
	if _blocking_errors > 0:
		push_error("GameData : %d erreur(s) bloquante(s) de données au boot — arrêt." % _blocking_errors)
		get_tree().quit(1)


func _unhandled_key_input(event: InputEvent) -> void:
	# Hot-reload F5 (D.2) — debug uniquement.
	if not OS.is_debug_build():
		return
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.physical_keycode == KEY_F5:
		reload_data()


## Recharge toutes les données à chaud, puis prévient les systèmes dérivés.
func reload_data() -> void:
	print("GameData : rechargement des données (F5)...")
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
	_load_creatures()
	_load_trees()
	_load_plants()
	_load_dungeon_rooms()
	_load_dungeon_connectors()
	_load_races()
	_load_classes()
	_load_transformations()
	_validate_translation_keys()

	print("GameData : %d matériau(x), %d catégorie(s), %d biome(s), %d couche(s) de bruit, %d strate(s), %d compétence(s), %d objet(s), %d module(s), %d créature(s), %d essence(s) d'arbre, %d plante(s), %d salle(s)/%d connecteur(s) de donjon, %d race(s), %d classe(s)." % [
		materials.size(), material_categories.size(), biomes.size(), noise_layers.size(), strata.size(), skills.size(), items.size(), modules.size(), creatures.size(), trees.size(), plants.size(), dungeon_rooms.size(), dungeon_connectors.size(), races.size(), classes.size()])
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
		var id: String = mat["id"]
		if materials.has(id):
			_blocking_error("id de matériau dupliqué « %s » (%s)" % [id, path])
			continue

		# Unicité des couleurs + collision avec les couleurs réservées (B.1).
		var color: String = String(mat["color"]).to_upper()
		if seen_colors.has(color):
			_blocking_error("couleur %s dupliquée entre « %s » et « %s »" % [color, seen_colors[color], id])
		elif reserved.has(color):
			_blocking_error("couleur %s du matériau « %s » entre en collision avec une couleur réservée (%s)" % [color, id, reserved[color]])
		seen_colors[color] = id

		# Applique un style de texture par défaut si non spécifié (2026-07-24).
		if not mat.has("texture_style"):
			mat["texture_style"] = CATEGORY_TEXTURE_STYLES.get(mat["category"], "basic")

		_derive_tags(mat)
		materials[id] = mat
		sorted_ids.append(id)

	# Ids runtime stables : ordre alphabétique des ids texte, 0 réservé à l'air.
	sorted_ids.sort()
	for id in sorted_ids:
		material_runtime_ids[id] = material_by_runtime.size()
		material_by_runtime.append(id)

	# Masque des LIQUIDES par id runtime (2026-07-24) : le mesher abaisse la
	# face du dessus des liquides (eau/lave « moins grands » que les blocs
	# pleins). Lu depuis les threads de meshing (GameData en lecture seule).
	liquid_mask = PackedByteArray()
	liquid_mask.resize(256)
	for id in sorted_ids:
		if String(materials[id].get("category", "")) == "liquide":
			var rid: int = material_runtime_ids[id]
			if rid < 256:
				liquid_mask[rid] = 1


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
		for field in ["id", "name_key", "type", "functionality", "recipe", "stat_weights"]:
			if not item.has(field):
				_blocking_error("champ « %s » manquant dans %s" % [field, path])
				ok = false
		if not ok:
			continue
		if not functionalities.has(item["functionality"]):
			_blocking_error("fonctionnalité inconnue « %s » dans l'objet « %s »" % [item["functionality"], item["id"]])
		var recipe: Dictionary = item["recipe"] if item["recipe"] is Dictionary else {}
		for input: Variant in recipe.get("inputs", []):
			if input is Dictionary and not material_categories.has(input.get("category", "")):
				_blocking_error("catégorie de recette inconnue « %s » dans l'objet « %s »" % [input.get("category", "?"), item["id"]])
		# Modèle .vox référencé (B.3) : absence = warning (remap 9.1 impossible).
		var vox_path := String(item.get("vox_model", ""))
		if vox_path != "" and not FileAccess.file_exists(vox_path if vox_path.begins_with("res://") else "res://" + vox_path):
			push_warning("GameData : modèle .vox introuvable « %s » (objet « %s »)." % [vox_path, item["id"]])
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
		if not (tree["canopy_shape"] in ["spherical", "conical", "flat", "weeping"]):
			_blocking_error("canopy_shape invalide « %s » pour l'arbre « %s »" % [tree["canopy_shape"], tree["id"]])
		if trees.has(tree["id"]):
			_blocking_error("id d'essence d'arbre dupliqué « %s »" % tree["id"])
		else:
			trees[tree["id"]] = tree


## Plantes non-arborescentes en sous-voxels (2026-07-20, PlantGenerator) :
## data/plants/*.json — validation légère, la structure `morphology`/
## `materials` reste libre (interprétée par PlantGenerator, pas ici).
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
		var combat: Dictionary = creature.get("combat", {})
		if combat.has("functionality") and not functionalities.has(combat["functionality"]):
			_blocking_error("fonctionnalité de combat inconnue « %s » pour la créature « %s »" % [combat["functionality"], creature["id"]])
		for module_id: String in combat.get("modules", []):
			if not modules.has(module_id):
				_blocking_error("module inconnu « %s » pour la créature « %s »" % [module_id, creature["id"]])
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

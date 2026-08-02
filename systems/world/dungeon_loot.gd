class_name DungeonLoot
extends RefCounted
## Butin de donjon (F.7 partiel) — classe statique pure, DÉTERMINISTE : mêmes
## cellule + profondeur + graine de monde → même butin, à chaque appel (G.1).
##
## Deux producteurs :
##   - `floor_caches()` : les caches dispersées au sol dans les salles, ce que
##     le joueur ramasse en explorant ;
##   - `boss_chest()`   : le coffre lâché par le boss du dernier étage.
##
## POURQUOI DÉTERMINISTE ET NON ALÉATOIRE À CHAQUE VISITE. Un donjon est
## reconstruit à chaque entrée (les étages ne sont pas persistés, seuls les
## blocs modifiés le sont). Un tirage au hasard à la construction rendrait le
## butin FARMABLE à l'infini : sortir, rentrer, re-ramasser. Le tirage est donc
## une fonction de (cellule, profondeur, graine), et DungeonManager retient
## quels étages ont déjà été pillés — voir `_looted_floors`.
##
## La qualité et la quantité montent avec la PROFONDEUR : descendre doit
## rapporter davantage, sinon rien n'incite à quitter le premier étage.

## Catégories exigées par les recettes d'objets (toutes les recettes de
## data/items/ n'utilisent que celles-ci).
const RECIPE_CATEGORIES := ["bois", "minerai", "textile"]

## Objets qu'un donjon peut contenir. Volontairement restreint aux ARMES,
## BOUCLIERS et ARMURES : un donjon récompense le combat, pas le jardinage —
## y trouver une faucille ou un seau ferait retomber la tension.
const LOOT_ITEMS := [
	"epee", "epee_courte", "dague", "rapiere", "espadon", "hache_arme",
	"hache_double", "masse", "masse_ailettes", "marteau_guerre", "lance",
	"hallebarde", "trident", "gourdin", "arc", "arbalete", "baton_magique",
	"ecu", "rondache", "pavois",
	"casque", "cuirasse", "jambieres", "bottes", "gants",
]

## Part des salles qui portent une cache. Toutes les salles en auraient une
## serait mécanique ; une sur trois laisse des pièces vides, donc de la
## variation, donc l'envie d'ouvrir la suivante.
const CACHE_ROOM_RATIO := 0.34
## Or d'une cache au sol : plancher + bonus par étage.
const CACHE_GOLD_BASE := 8
const CACHE_GOLD_PER_DEPTH := 6
## Or du coffre de boss — sans commune mesure avec une cache : c'est la
## récompense du donjon entier.
const CHEST_GOLD_BASE := 120
const CHEST_GOLD_PER_DEPTH := 45


## Qualité d'un objet trouvé (A.3, même échelle que l'artisanat). Monte avec la
## profondeur, plafonnée pour qu'un donjon ne surclasse jamais un artisan
## expert : le butin doit être une avance, pas une fin de progression.
static func _quality_for(depth: int, rng: RandomNumberGenerator) -> float:
	return clampf(0.55 + 0.09 * float(depth) + rng.randf_range(-0.08, 0.14), 0.4, 1.35)


## Matériaux disponibles par catégorie, résolus une fois. Un donjon ne doit
## jamais produire un objet dans un matériau qui n'existe pas au catalogue.
static var _by_category := {}


static func _materials_of(category: String) -> Array:
	if _by_category.is_empty():
		for cat: String in RECIPE_CATEGORIES:
			_by_category[cat] = []
		for mid: String in GameData.materials:
			var cat := String((GameData.materials[mid] as Dictionary).get("category", ""))
			if _by_category.has(cat):
				(_by_category[cat] as Array).append(mid)
		for cat: String in RECIPE_CATEGORIES:
			(_by_category[cat] as Array).sort()  # Ordre stable → déterminisme.
	return _by_category.get(category, [])


## Fabrique un objet de butin, ou {} si les données ne le permettent pas.
static func _make_item(rng: RandomNumberGenerator, depth: int) -> Dictionary:
	var item_id: String = LOOT_ITEMS[rng.randi() % LOOT_ITEMS.size()]
	var recipe: Dictionary = (GameData.items.get(item_id, {}) as Dictionary).get("recipe", {})
	if recipe.is_empty():
		return {}
	var choices := {}
	for input: Dictionary in (recipe.get("inputs", []) as Array):
		var category := String(input["category"])
		var pool := _materials_of(category)
		if pool.is_empty():
			return {}  # Catégorie vide : mieux vaut aucun objet qu'un objet bancal.
		choices[category] = pool[rng.randi() % pool.size()]
	return ItemFactory.craft(item_id, choices, _quality_for(depth, rng))


## Caches au sol de l'étage : [{ "position": Vector3, "objects": Array, "gold": int }].
## `rooms` vient de DungeonGenerator.generate_floor(). La salle 0 (l'entrée) est
## exclue : trouver le butin avant d'avoir marché ne récompense rien.
static func floor_caches(rooms: Array, depth: int, seed_value: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var out: Array = []
	for i in rooms.size():
		if i == 0:
			continue
		if rng.randf() > CACHE_ROOM_RATIO:
			continue
		var room: Dictionary = rooms[i]
		var origin: Vector3i = room["origin"]
		var size: Vector3i = room["size"]
		# Décentré : posé au milieu de chaque salle, le butin se verrait depuis
		# la porte et l'exploration se réduirait à traverser en diagonale.
		var px := origin.x + rng.randi_range(2, maxi(2, size.x - 3))
		var pz := origin.z + rng.randi_range(2, maxi(2, size.z - 3))
		var objects: Array = []
		var count := 1 if rng.randf() < 0.7 else 2
		for _n in count:
			var obj := _make_item(rng, depth)
			if not obj.is_empty():
				objects.append(obj)
		var gold := CACHE_GOLD_BASE + CACHE_GOLD_PER_DEPTH * depth + rng.randi_range(0, 12)
		out.append({
			"position": Vector3(px + 0.5, float(origin.y) + 1.2, pz + 0.5),
			"objects": objects,
			"gold": gold,
		})
	return out


## Contenu du coffre de boss : { "objects": Array, "gold": int }.
## Trois à cinq pièces, plus d'or que tout le reste de l'étage réuni.
static func boss_chest(depth: int, seed_value: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value ^ 0x5EED_C0DE
	var objects: Array = []
	for _n in rng.randi_range(3, 5):
		# Le coffre tire sa qualité un cran plus profond que l'étage : c'est
		# la seule source du jeu qui dépasse franchement l'artisanat courant.
		var obj := _make_item(rng, depth + 1)
		if not obj.is_empty():
			objects.append(obj)
	return {
		"objects": objects,
		"gold": CHEST_GOLD_BASE + CHEST_GOLD_PER_DEPTH * depth + rng.randi_range(0, 60),
	}

class_name POIGenerator
extends RefCounted
## Placement des points d'intérêt (E.2, 3.1/3.5) — un tirage INDÉPENDANT par
## type de POI et par cellule (128 blocs, même découpage que ClaimManager),
## selon `poi_weights` (pourcentage, 0-100) du biome résolu au CENTRE de la
## cellule. Déterministe (hash PCG partagé avec arbres/plantes/rivières —
## E.2 : « même technique que les POI », jamais de bruit corrélé qui
## grouperait des POI voisins). Plafonné à 2 POI par cellule (GDD E.2 :
## « chaque cellule a 0-2 POI ») : ordre canonique fixe des types, on
## retient les 2 premiers succès rencontrés dans cet ordre.
##
## SIMPLIFICATION ASSUMÉE ET SIGNALÉE : seul le PLACEMENT/EMPRISE est fait
## ici (quel type de POI existe dans quelle cellule, et quelle emprise il
## occupe — requêtable à la volée comme tout le reste du monde, jamais
## stocké). La génération du CONTENU réel (salles de donjon E.29, bâtiments
## de village et donjons) reste à faire — cette étape pose
## des icônes sur la carte + le MÉCANISME d'entrée/sortie de donjon
## (DungeonManager), pas encore de vraie structure en jeu.
##
## EMPRISE (2026-07-21, demande explicite) : un POI est contenu dans UNE
## SEULE cellule, sauf une « grande ville » (variante de taille du village,
## `village_size_at`) qui peut en occuper plusieurs (footprint carré
## GRANDE_VILLE_FOOTPRINT, ancré à son coin de coordonnées MINIMALES). Un
## donjon occupe l'INTÉGRALITÉ de sa cellule et est entouré d'un périmètre
## (voir DungeonManager) : y entrer téléporte à l'intérieur.

## Ordre canonique = ordre de priorité en cas de plafond à 2 (GDD E.2, ordre
## RÉDUIT À DEUX TYPES le 2026-08-01, sur décision de l'auteur.
##
## Le GDD en énumère cinq (village, donjon, camp, sanctuaire, filon majeur),
## mais seuls les villages et les donjons ont un CONTENU en jeu. Les trois
## autres ne posaient qu'une pastille sur la carte : le joueur s'y rendait et
## n'y trouvait rien. C'est exactement le défaut corrigé quelques jours plus tôt
## sur les villages fantômes — une carte ne doit pas promettre ce qui n'existe
## pas, et il vaut mieux retirer un marqueur que le laisser mentir.
##
## L'ORDRE DES DEUX RESTANTS EST PRÉSERVÉ, et ce n'est pas un détail : le tirage
## sale le hachage avec l'INDICE du type (`i * 97`). Village reste 0, donjon
## reste 1 — les mondes déjà générés gardent donc exactement les mêmes villages
## et les mêmes donjons aux mêmes endroits. Réordonner cette liste, ou y
## réinsérer un type en tête, déplacerait tout.
##
## Pour les réintroduire un jour : remettre le type en FIN de liste, rétablir
## ses `poi_weights` dans data/biomes/, sa couleur dans world_map_view et son
## bouton de téléportation dans le menu de triche.
const POI_TYPES: Array[String] = ["village", "donjon"]

## Compensation de l'ATTRITION DE SITE des villages.
##
## Le poids déclaré par biome (E.2 : « village 4 % par cellule ») exprime la
## densité de villages qu'on veut VOIR dans le monde. Or un village tiré n'est
## pas un village construit : il doit encore trouver, dans sa cellule, une
## emprise de 80 blocs assez plate et hors de l'eau. Le recensement
## (--probe-villages, 39 km²) donne un taux de survie mesuré d'environ 20 % :
## sans compensation, une densité annoncée à 4 % en produit 0,8 % sur le
## terrain, soit un village tous les 1 800 blocs au lieu de 640.
##
## C'est ce qui a fait dire à l'auteur que « les villages ne se génèrent pas ».
##
## Multiplier le tirage restaure l'intention du GDD sans toucher aux données de
## biome. Effet secondaire VOULU : la compensation profite surtout aux biomes
## plats, où presque tous les sites passent — les villages se concentrent donc
## dans les plaines et restent rares en montagne, ce qui est le comportement
## qu'on attendrait de toute façon.
##
## Si la géométrie du monde change (plus ou moins d'océan, relief plus doux),
## RELANCER --probe-villages et réajuster : ce nombre est calé sur une mesure,
## pas choisi au jugé.
const VILLAGE_SITE_ATTRITION := 4.0
const MAX_POI_PER_CELL := 2
const SEED_POI := 41213

## Taille des villages : la plupart tiennent dans 1 cellule, une minorité
## sont des « grandes villes » multi-cellules (footprint fixe, ancré au coin
## de coordonnées minimales — jamais de forme irrégulière, ça garderait la
## résolution d'emprise en O(footprint²) simple et déterministe).
const GRANDE_VILLE_CHANCE := 0.2
const GRANDE_VILLE_FOOTPRINT := 2
const SEED_VILLAGE_SIZE := 51817


## Types de POI présents dans la cellule `cell` (coordonnées de cellule, PAS
## coordonnées bloc — voir ClaimManager.cell_of_block). `biome` = dict biome
## déjà résolu au centre de la cellule (appelant : NoiseGenerator.biome_at).
static func pois_at_cell(cell: Vector2i, world_seed: int, biome: Dictionary) -> Array[String]:
	var weights: Dictionary = biome.get("poi_weights", {})
	if weights.is_empty():
		return []
	var found: Array[String] = []
	for i in POI_TYPES.size():
		if found.size() >= MAX_POI_PER_CELL:
			break
		var poi_type: String = POI_TYPES[i]
		var weight: float = weights.get(poi_type, 0.0)
		if weight <= 0.0:
			continue
		if poi_type == "village":
			weight *= VILLAGE_SITE_ATTRITION
		var roll := NoiseGenerator.pcg_hash(cell.x, cell.y, world_seed + SEED_POI + i * 97) % 10000
		if float(roll) < weight * 100.0:
			found.append(poi_type)
			# BUG RÉEL CORRIGÉ (2026-07-21, retour utilisateur : un village
			# pouvait aussi être un donjon dans la même cellule, téléportant
			# le joueur en pleine visite d'un village apparemment normal) —
			# un donjon occupe l'INTÉGRALITÉ de sa cellule (demande explicite
			# antérieure) : EXCLUSIF, aucun autre POI ne peut y coexister.
			if poi_type == "donjon":
				return ["donjon"]
	return found


## Centre monde (bloc) de la cellule — pratique pour placer/afficher un POI.
static func cell_center_world(cell: Vector2i) -> Vector2i:
	return Vector2i(cell.x * ClaimManager.CELL_SIZE + ClaimManager.CELL_SIZE / 2,
			cell.y * ClaimManager.CELL_SIZE + ClaimManager.CELL_SIZE / 2)


## Taille d'un village PRÉSENT en `cell` (n'a de sens que si "village" figure
## dans `pois_at_cell(cell, ...)` — appelant responsable de cette vérif).
## Tirage INDÉPENDANT du placement lui-même (seed dédiée).
static func village_size_at(cell: Vector2i, world_seed: int) -> String:
	var roll := NoiseGenerator.pcg_hash(cell.x, cell.y, world_seed + SEED_VILLAGE_SIZE) % 10000
	return "grande_ville" if float(roll) < GRANDE_VILLE_CHANCE * 10000.0 else "village"


## Résout le PROPRIÉTAIRE effectif d'une cellule pour l'affichage/gameplay
## village : si `cell` est engloutie par le footprint d'une grande ville
## ancrée ailleurs (coin minimal), retourne l'ancre de cette grande ville ;
## sinon retourne `cell` elle-même (résolution normale). `biome_lookup` =
## Callable(cell: Vector2i) -> Dictionary, fournie par l'appelant (biome au
## centre de la cellule candidate — NoiseGenerator.biome_at, instance donc
## pas directement accessible en statique ici).
static func village_owner_of(cell: Vector2i, world_seed: int, biome_lookup: Callable) -> Vector2i:
	for dz in range(GRANDE_VILLE_FOOTPRINT):
		for dx in range(GRANDE_VILLE_FOOTPRINT):
			var anchor := cell - Vector2i(dx, dz)
			if anchor == cell:
				continue
			var anchor_biome: Dictionary = biome_lookup.call(anchor)
			if anchor_biome.is_empty():
				continue
			if "village" not in pois_at_cell(anchor, world_seed, anchor_biome):
				continue
			if village_size_at(anchor, world_seed) == "grande_ville":
				return anchor
	return cell

class_name DungeonTower
extends RefCounted
## Structure de donjon (réécrite le 2026-07-27, demande de l'auteur) : une
## TERMITIÈRE MALÉFIQUE occupant toute la CELLULE (128 blocs, 3.2), pas un
## simple chunk. Masse organique sculptée au bruit : flancs irréguliers, pics
## démoniaques, cavités et tunnels « alien » qui la percent de part en part.
## Elle rend le donjon visible de très loin — jusqu'ici rien ne signalait une
## cellule de donjon, on y entrait en franchissant un périmètre invisible.
##
## Entrer dans une cavité de la termitière téléporte dans le donjon
## (DungeonManager).
##
## Classe statique pure, comme CityGenerator/POIGenerator : rien de persisté,
## tout est déterministe à partir de la cellule et de la graine. Les bruits
## sont créés une fois et mémorisés par graine (voir `_noises_for`) : les
## instancier par appel coûterait bien plus cher que de les évaluer.

## Emprise : toute la cellule (3.2).
const FOOTPRINT := ClaimManager.CELL_SIZE
## Rayon utile : on laisse une marge pour que la masse ne touche jamais la
## bordure de cellule (sinon deux donjons voisins se souderaient).
const RADIUS := 56.0
## Hauteur du dôme au centre, avant les pics.
const DOME_HEIGHT := 70.0
## Amplitude ajoutée par les pics (bruit crêté).
const SPIKE_HEIGHT := 58.0
## Seuil des cavités « alien » : au-dessus, le bloc est creusé.
const CAVITY_THRESHOLD := 0.42
## Épaisseur minimale de croûte : les cavités ne débouchent jamais en surface
## partout, sinon la structure ressemblerait à une éponge et non à un nid.
const CRUST := 2.0

## Palette DÉMONIAQUE, du cœur vers la surface. L'ordre compte : il sert de
## bandes de profondeur (voir `_material_for`).
const PALETTE: Array[String] = [
	"chair_noire",      # cœur, presque organique
	"os_calcine",       # veines claires dans la masse
	"basalte_maudit",   # masse principale
	"scorie_ardente",   # veines rouges luminescentes
	"croute_demoniaque",# surface, la plus sombre
]

static var _noise_cache := {}


## Jeu de bruits pour une graine donnée (créés une fois).
static func _noises_for(world_seed: int) -> Dictionary:
	if _noise_cache.has(world_seed):
		return _noise_cache[world_seed]
	# Silhouette : déforme le rayon du dôme, donne des flancs irréguliers.
	var shape := FastNoiseLite.new()
	shape.noise_type = FastNoiseLite.TYPE_SIMPLEX
	shape.seed = world_seed + 8801
	shape.frequency = 0.018
	shape.fractal_type = FastNoiseLite.FRACTAL_FBM
	shape.fractal_octaves = 3

	# Pics : bruit CRÊTÉ — c'est lui qui produit les aiguilles démoniaques.
	var spikes := FastNoiseLite.new()
	spikes.noise_type = FastNoiseLite.TYPE_SIMPLEX
	spikes.seed = world_seed + 8802
	spikes.frequency = 0.045
	spikes.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	spikes.fractal_octaves = 4

	# Cavités : bruit 3D, creuse tunnels et poches à l'intérieur.
	var cavity := FastNoiseLite.new()
	cavity.noise_type = FastNoiseLite.TYPE_SIMPLEX
	cavity.seed = world_seed + 8803
	cavity.frequency = 0.035
	cavity.fractal_type = FastNoiseLite.FRACTAL_FBM
	cavity.fractal_octaves = 3

	# Matière : mélange les blocs de la palette de façon organique, par
	# marbrures — pas par couches régulières, qui feraient « géologique »
	# au lieu de « vivant ».
	var matter := FastNoiseLite.new()
	matter.noise_type = FastNoiseLite.TYPE_SIMPLEX
	matter.seed = world_seed + 8804
	matter.frequency = 0.06
	matter.fractal_type = FastNoiseLite.FRACTAL_FBM
	matter.fractal_octaves = 2

	var set := {"shape": shape, "spikes": spikes, "cavity": cavity, "matter": matter}
	_noise_cache[world_seed] = set
	return set


## Centre (bloc) de la structure : le centre de sa cellule.
static func center_of(cell: Vector2i) -> Vector2i:
	return POIGenerator.cell_center_world(cell)


## true si (wx, wz) tombe dans l'emprise horizontale de la structure.
static func contains(cell: Vector2i, wx: int, wz: int) -> bool:
	var centre := center_of(cell)
	var dx := float(wx - centre.x)
	var dz := float(wz - centre.y)
	return dx * dx + dz * dz <= RADIUS * RADIUS


## Hauteur de la masse au-dessus du sol en (wx, wz), 0 hors de l'emprise.
## Dôme qui décroît vers les bords + pics crêtés : la silhouette de
## termitière vient de la combinaison des deux.
static func height_at(cell: Vector2i, wx: int, wz: int, world_seed: int) -> float:
	var centre := center_of(cell)
	var dx := float(wx - centre.x)
	var dz := float(wz - centre.y)
	var dist := sqrt(dx * dx + dz * dz)
	if dist > RADIUS:
		return 0.0
	var noises := _noises_for(world_seed)
	# Rayon déformé : la base n'est pas un cercle parfait.
	var wobble := (noises["shape"] as FastNoiseLite).get_noise_2d(float(wx), float(wz))
	var effective := RADIUS * (0.78 + 0.22 * wobble)
	if dist > effective:
		return 0.0
	var t := 1.0 - dist / effective          # 1 au centre, 0 au bord
	var dome := DOME_HEIGHT * pow(t, 1.6)
	# Bruit crêté ramené en 0..1 : les crêtes deviennent des aiguilles.
	var ridged: float = absf((noises["spikes"] as FastNoiseLite).get_noise_2d(float(wx), float(wz)))
	var spike := SPIKE_HEIGHT * pow(ridged, 2.2) * pow(t, 0.7)
	return dome + spike


## true si (wx, wy, wz) est creusé par une cavité « alien ». La croûte
## extérieure est préservée : une cavité ne perce la surface que là où le
## bruit est franchement au-dessus du seuil, ce qui donne des ouvertures
## nettes plutôt qu'une éponge.
static func is_cavity(wx: int, wy: int, wz: int, depth: float, world_seed: int) -> bool:
	var noises := _noises_for(world_seed)
	var value: float = absf((noises["cavity"] as FastNoiseLite).get_noise_3d(
			float(wx), float(wy) * 1.6, float(wz)))
	var threshold := CAVITY_THRESHOLD
	if depth < CRUST:
		threshold += 0.25  # Proche de la surface : bien plus dur à percer.
	return value > threshold


## Matériau (id runtime) d'un bloc plein, choisi par bruit + profondeur.
static func _material_for(wx: int, wy: int, wz: int, depth: float,
		world_seed: int, ids: PackedInt32Array) -> int:
	if ids.is_empty():
		return 0
	var noises := _noises_for(world_seed)
	var value: float = (noises["matter"] as FastNoiseLite).get_noise_3d(
			float(wx), float(wy), float(wz))
	# La croûte prend le matériau de surface, l'intérieur se marbre.
	if depth < CRUST:
		return ids[ids.size() - 1]
	var index := int((value * 0.5 + 0.5) * float(ids.size() - 1))
	return ids[clampi(index, 0, ids.size() - 2)]


## Matériau organique d'INTÉRIEUR (salles/couloirs de donjon, 2026-07-28) :
## mêmes marbrures que la masse de la termitière, mais SANS la logique de croûte
## — on est déjà au cœur du nid, pas sur sa peau. Permet aux salles générées
## procéduralement d'être bâties dans la même chair démoniaque que la structure
## visible depuis l'overworld, au lieu de la pierre grise d'origine.
static func interior_material(wx: int, wy: int, wz: int, world_seed: int, ids: PackedInt32Array) -> int:
	return _material_for(wx, wy, wz, CRUST + 1.0, world_seed, ids)


## Bloc de la structure en (wx, wy, wz), ou 0 pour du vide. `ground_y` = sol
## au centre de la cellule. `ids` = ids runtime de PALETTE, dans l'ordre.
static func block_at(cell: Vector2i, wx: int, wy: int, wz: int,
		ground_y: int, world_seed: int, ids: PackedInt32Array) -> int:
	if not contains(cell, wx, wz):
		return 0
	var local_y := float(wy - ground_y)
	if local_y < 0.0:
		return 0
	var top := height_at(cell, wx, wz, world_seed)
	if top <= 0.0 or local_y > top:
		return 0
	var depth := top - local_y
	if is_cavity(wx, wy, wz, depth, world_seed):
		return 0
	return _material_for(wx, wy, wz, depth, world_seed, ids)


## true si la position est dans une CAVITÉ de la structure — c'est le
## déclencheur d'entrée en donjon : le joueur s'est enfoncé dans le nid.
static func inside_interior(cell: Vector2i, wx: int, wy: int, wz: int,
		ground_y: int, world_seed: int) -> bool:
	if not contains(cell, wx, wz):
		return false
	var local_y := float(wy - ground_y)
	if local_y < 0.0:
		return false
	var top := height_at(cell, wx, wz, world_seed)
	if top <= 0.0 or local_y > top:
		return false
	# Sous la croûte ET dans du vide : on est bien À L'INTÉRIEUR du nid, pas
	# en train de longer sa paroi extérieure.
	var depth := top - local_y
	return depth > CRUST and is_cavity(wx, wy, wz, depth, world_seed)

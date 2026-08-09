class_name DungeonCavern
extends RefCounted
## Forme ORGANIQUE des salles de donjon — classe statique pure, déterministe.
##
## POURQUOI. Les salles étaient des BOÎTES : sol plat, quatre murs droits,
## plafond plat, à l'intérieur d'une termitière dont l'extérieur, lui, est
## sculpté au bruit avec des flancs irréguliers et des pics. Passer de la
## silhouette alien à un cube de 11×5×11 cassait net l'illusion — on entrait
## dans un nid et on se retrouvait dans un couloir de bureau.
##
## Chaque salle est maintenant une CAVITÉ : empreinte elliptique déformée au
## bruit, sol en relief, voûte en dôme, et quelques colonnes naturelles là où
## la matière n'a pas été creusée.
##
## TROIS CONTRAINTES QUI PILOTENT TOUS LES RÉGLAGES ICI :
##
## 1. La déformation ne fait que RÉTRÉCIR l'ellipse, jamais grandir. Le
##    générateur d'étage teste le chevauchement des salles sur leur boîte
##    englobante ; une cavité qui déborderait de sa boîte pourrait percer la
##    salle voisine et créer des raccourcis invisibles au graphe.
##
## 2. Le relief du sol varie de MOINS D'UN BLOC par pas horizontal. Le joueur
##    franchit automatiquement 1 bloc (`FlyCamera.STEP_HEIGHT`) : au-delà, une
##    salle deviendrait infranchissable sans saut, et un sol accidenté se
##    transformerait en piège plutôt qu'en décor.
##
## 3. Tout point de la cavité garde `MIN_CLEARANCE` blocs d'air au-dessus du
##    sol. Sans ce plancher, la voûte en dôme finissait par écraser les bords
##    de la salle sous le niveau de la tête.

## Amplitude du relief de sol, en blocs.
const FLOOR_RELIEF := 2.0
## Fréquence du bruit de relief. Choisie AVEC l'amplitude pour tenir la
## contrainte 2 : la pente maximale d'un simplex vaut environ 2·amplitude·
## fréquence par bloc, soit ici ~0,28 — largement sous la marche de 1 bloc.
const FLOOR_FREQ := 0.07
## Part du rayon que la déformation peut retirer (0,25 = l'ellipse respire
## entre 75 % et 100 % de son rayon nominal).
const SHAPE_BITE := 0.25
const SHAPE_FREQ := 0.10
## Hauteur d'air minimale garantie au-dessus du sol, partout dans la cavité.
const MIN_CLEARANCE := 3
## Seuil des colonnes : au-dessus, la matière reste en place et forme un pilier.
## Élevé À DESSEIN — des colonnes fréquentes transformeraient les salles en
## forêt de piliers et masqueraient le butin au sol.
const COLUMN_THRESHOLD := 0.62
const COLUMN_FREQ := 0.16
## Rayon (en blocs) autour d'une porte où l'on n'autorise aucune colonne : une
## colonne pile dans une entrée bloquerait le passage.
const DOOR_CLEARANCE := 3

static var _cache := {}
## MEME COURSE QUE LE FEUILLAGE (2026-08-09, voir TreeGenerator._leaf_shell_mutex) :
## cache statique atteint par les threads ouvriers ET par les requetes
## ponctuelles du thread principal.
static var _cache_mutex := Mutex.new()


static func _noises(seed_value: int) -> Dictionary:
	_cache_mutex.lock()
	if _cache.has(seed_value):
		var cached: Dictionary = _cache[seed_value]
		_cache_mutex.unlock()
		return cached
	_cache_mutex.unlock()
	var shape := FastNoiseLite.new()
	shape.noise_type = FastNoiseLite.TYPE_SIMPLEX
	shape.seed = seed_value + 4401
	shape.frequency = SHAPE_FREQ
	shape.fractal_type = FastNoiseLite.FRACTAL_FBM
	shape.fractal_octaves = 2

	var floor_n := FastNoiseLite.new()
	floor_n.noise_type = FastNoiseLite.TYPE_SIMPLEX
	floor_n.seed = seed_value + 4402
	floor_n.frequency = FLOOR_FREQ
	floor_n.fractal_type = FastNoiseLite.FRACTAL_FBM
	floor_n.fractal_octaves = 2

	var column := FastNoiseLite.new()
	column.noise_type = FastNoiseLite.TYPE_SIMPLEX
	column.seed = seed_value + 4403
	column.frequency = COLUMN_FREQ
	column.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	column.fractal_octaves = 2

	var set := {"shape": shape, "floor": floor_n, "column": column}
	_cache_mutex.lock()
	_cache[seed_value] = set
	_cache_mutex.unlock()
	return set


## Distance normalisée au centre de la salle, APRÈS déformation. < 1 = dans la
## cavité, >= 1 = dans la roche. `origin`/`size` sont ceux de la salle.
static func shaped_distance(wx: int, wz: int, origin: Vector3i, size: Vector3i,
		seed_value: int) -> float:
	var cx := float(origin.x) + float(size.x) * 0.5
	var cz := float(origin.z) + float(size.z) * 0.5
	# -1 sur le rayon : la salle garde toujours au moins un bloc de paroi
	# pleine sur sa boîte englobante (contrainte 1).
	var rx := maxf(1.0, float(size.x) * 0.5 - 1.0)
	var rz := maxf(1.0, float(size.z) * 0.5 - 1.0)
	var dx := (float(wx) + 0.5 - cx) / rx
	var dz := (float(wz) + 0.5 - cz) / rz
	var d := sqrt(dx * dx + dz * dz)
	var n: float = (_noises(seed_value)["shape"] as FastNoiseLite).get_noise_2d(float(wx), float(wz))
	# `n` dans [-1,1] -> mordant dans [0, SHAPE_BITE]. Toujours SOUSTRAIT du
	# rayon utile : la cavité ne peut que rentrer, jamais sortir.
	var bite := SHAPE_BITE * (n * 0.5 + 0.5)
	return d / maxf(0.05, 1.0 - bite)


## Hauteur du sol en (wx,wz), en blocs au-dessus de `origin.y`. 0 = niveau de
## référence de la salle ; le point le plus bas d'une salle vaut toujours 0,
## sinon les portes des couloirs déboucheraient dans le vide.
static func floor_offset(wx: int, wz: int, seed_value: int) -> int:
	var n: float = (_noises(seed_value)["floor"] as FastNoiseLite).get_noise_2d(float(wx), float(wz))
	return int(floor((n * 0.5 + 0.5) * FLOOR_RELIEF))


## Combien de son rayon la cavité conserve À CETTE HAUTEUR, entre 0 et 1.
##
## C'est ce qui fait la différence entre une salle et une CHAMBRE. Sans ce
## resserrement, l'empreinte déformée était identique du sol au plafond : les
## parois montaient droit, et malgré un contour irrégulier l'ensemble se
## lisait encore comme une boîte (constaté en capture au premier essai). Le
## rayon décroît maintenant avec la hauteur — pleine largeur au sol, resserré
## sous la voûte — ce qui donne l'alvéole bombée d'une termitière.
##
## Décroissance en carré et non linéaire : elle laisse la partie basse, celle
## où le joueur marche, presque à pleine largeur, et concentre le
## rétrécissement en haut, où il n'a aucune conséquence de circulation.
const TOP_PINCH := 0.55


static func radius_at(y_local: int, floor_y: int, box_height: int) -> float:
	var span := maxf(1.0, float(box_height - 1 - floor_y))
	var h := clampf((float(y_local) - float(floor_y)) / span, 0.0, 1.0)
	return 1.0 - TOP_PINCH * h * h


## Le point (wx, y_local, wz) est-il dans le vide de la salle ?
## `y_local` est relatif à `origin.y`.
static func is_open(wx: int, y_local: int, wz: int, origin: Vector3i,
		size: Vector3i, seed_value: int) -> bool:
	var floor_y := floor_offset(wx, wz, seed_value)
	if y_local <= floor_y or y_local >= size.y:
		return false
	return shaped_distance(wx, wz, origin, size, seed_value) \
			< radius_at(y_local, floor_y, size.y)


## Hauteur de la voûte au-dessus de `origin.y` : le premier niveau plein
## au-dessus du sol. Sert au placement (butin, créatures), pas au creusement.
## Toujours au moins MIN_CLEARANCE au-dessus du sol local (contrainte 3).
static func ceiling_offset(wx: int, wz: int, origin: Vector3i, size: Vector3i,
		seed_value: int) -> int:
	var floor_y := floor_offset(wx, wz, seed_value)
	for y in range(floor_y + 1, size.y):
		if not is_open(wx, y, wz, origin, size, seed_value):
			return y
	return size.y


## Une colonne de matière traverse-t-elle la cavité en (wx,wz) ?
## `door_cols` : ensemble "x_z" des colonnes de porte, tenues dégagées.
static func is_column(wx: int, wz: int, origin: Vector3i, size: Vector3i,
		seed_value: int, door_cols: Dictionary) -> bool:
	# Jamais de colonne près d'une porte, ni contre la paroi (elle s'y
	# confondrait avec le mur sans rien apporter).
	for key: String in door_cols:
		var parts := key.split("_")
		var dx: int = origin.x + int(parts[0]) - wx
		var dz: int = origin.z + int(parts[1]) - wz
		if absi(dx) <= DOOR_CLEARANCE and absi(dz) <= DOOR_CLEARANCE:
			return false
	if shaped_distance(wx, wz, origin, size, seed_value) > 0.7:
		return false
	var n: float = (_noises(seed_value)["column"] as FastNoiseLite).get_noise_2d(float(wx), float(wz))
	return n > COLUMN_THRESHOLD

class_name DungeonTower
extends RefCounted
## Structure de donjon visible depuis l'overworld : une TOUR GÉANTE EN PIERRE
## TAILLÉE occupant toute la cellule (128 blocs, 3.2). Réécrite le 2026-08-02
## sur demande de l'auteur — elle remplace la « termitière » démoniaque
## organique du 2026-07-27, dont la matière (chair, os, scorie) ne correspondait
## plus à la direction voulue.
##
## POURQUOI RONDE, ET PAS CARRÉE. « Toute la cellule » et « jamais chez la
## voisine » sont contradictoires pour un carré : un carré de demi-côté 60 a des
## coins à 85 blocs du centre, bien au-delà de la demi-cellule (64), et ils
## seraient tranchés net par `_tower_cell_at` qui ne teste que la cellule
## courante. Un disque de rayon 60 occupe 120 blocs sur 128 — c'est bien toute
## la cellule — tout en restant à l'intérieur. Les tourelles d'angle et les
## contreforts rendent la silhouette anguleuse malgré la base circulaire.
##
## MASSIVE, PAS CREUSE. La tour est un bloc de maçonnerie plein, CREUSÉ de
## quatre tunnels d'entrée cardinaux menant à une salle centrale, elle-même
## surmontée d'un puits de lumière qui perce jusqu'aux créneaux. C'est la
## « structure d'entrée scellée » du GDD 3.5 : on n'explore pas la tour, on la
## traverse pour atteindre la salle, et la salle téléporte dans les étages
## (dimension séparée — DungeonManager). Un intérieur réellement creux aurait
## produit un cylindre vide de 120 blocs de diamètre, coûteux et sans contenu.
##
## PIERRE PAR CELLULE. La palette est tirée du catalogue des pierres taillées
## (tag `pierre_taillee`, une par roche depuis le 2026-08-02) selon la cellule :
## tour de granit ici, d'ardoise là, de marbre ailleurs. Le pool est lu depuis
## GameData et non figé en dur — ajouter une roche au catalogue ajoute une
## variante de tour sans toucher à ce fichier (GDD 8 : le contenu est de la
## donnée).
##
## Classe statique pure, comme CityGenerator/POIGenerator : rien de persisté,
## tout est déterministe à partir de la cellule et de la graine.

## Emprise : toute la cellule (3.2).
const FOOTPRINT := ClaimManager.CELL_SIZE
## Rayon extérieur du fût. DOIT rester < demi-cellule (64) — voir l'en-tête et
## le test de `_tower_cell_at` dans NoiseGenerator, qui ne regarde qu'une cellule.
const RADIUS := 60.0
## Épaisseur de maçonnerie sous la peau où l'on grave les moulures/meurtrières.
const SKIN := 3.0
## Hauteur du fût principal, créneaux non compris.
const BODY_HEIGHT := 88
## Hauteur des créneaux au-dessus du fût.
const MERLON_HEIGHT := 5
## Tourelles d'angle : nombre, rayon, dépassement au-dessus du fût.
const TURRET_COUNT := 8
const TURRET_RADIUS := 11.0
const TURRET_RISE := 18
## Recul du FÛT par rapport au rayon d'emprise. Les tourelles, elles, vont
## jusqu'à RADIUS : elles saillent donc de `BODY_INSET` blocs hors du mur.
##
## Sans ce recul (première version, tourelles tangentes intérieurement au fût),
## la silhouette était un cylindre parfaitement lisse — les tourelles existaient
## dans le code et ne se voyaient nulle part sur la capture.
const BODY_INSET := 5.0
const BODY_RADIUS := RADIUS - BODY_INSET
## Rayon du CERCLE PORTEUR des tourelles. Posé pour que la tourelle affleure
## EXACTEMENT l'emprise sans jamais la dépasser : `orbite + rayon == RADIUS`.
##
## Une première version posait les centres SUR le cercle du fût, pour que les
## tourelles bombent vers l'extérieur. Elles atteignaient alors 71 blocs du
## centre, au-delà de la demi-cellule (64) : `contains()` les déclarait hors
## emprise, `_tower_cell_at` refusait de les générer, et elles auraient été
## tranchées net tout en mordant sur la cellule voisine — le défaut décrit dans
## l'en-tête de ce fichier, et pris en flagrant délit par --probe-dungeon.
const TURRET_ORBIT := RADIUS - TURRET_RADIUS
## Hauteur totale utile. Les appelants (NoiseGenerator) bornent la colonne de
## chunks à générer avec cette valeur : la sous-estimer TRONQUE la tour, d'où
## une constante unique plutôt que deux termes à additionner de mémoire.
const MAX_HEIGHT := BODY_HEIGHT + TURRET_RISE + MERLON_HEIGHT

## Salle centrale (le déclencheur d'entrée en donjon).
const HALL_RADIUS := 18.0
const HALL_FLOOR := 1
const HALL_HEIGHT := 20
## Tunnels d'entrée cardinaux, creusés du bord jusqu'à la salle.
const ENTRY_HALF_WIDTH := 3      # 7 blocs de large.
const ENTRY_HEIGHT := 11
## Puits de lumière : de la voûte de la salle jusqu'au sommet. Sans lui la salle
## est un cul-de-sac noir, et la tour n'a pas de sommet lisible depuis le sol.
const SHAFT_RADIUS := 6.0

## Assises décoratives : une moulure d'accent tous les N blocs de hauteur.
const COURSE_SPACING := 12

static var _noise_cache := {}
static var _pool_cache := PackedStringArray()
static var _palette_cache := {}
static var _palette_mutex := Mutex.new()


## Jeu de bruits pour une graine donnée (créés une fois).
static func _noises_for(world_seed: int) -> Dictionary:
	if _noise_cache.has(world_seed):
		return _noise_cache[world_seed]
	# Usure : altère légèrement le rayon et ronge les créneaux. Une tour
	# parfaitement régulière lit comme un objet posé ; quelques pierres
	# manquantes suffisent à la faire lire comme une ruine habitée.
	var wear := FastNoiseLite.new()
	wear.noise_type = FastNoiseLite.TYPE_SIMPLEX
	wear.seed = world_seed + 8801
	wear.frequency = 0.09
	wear.fractal_type = FastNoiseLite.FRACTAL_FBM
	wear.fractal_octaves = 2

	# Appareillage : mélange les pierres de la palette par blocs, pour que la
	# maçonnerie ne soit pas d'un seul ton plat.
	var bond := FastNoiseLite.new()
	bond.noise_type = FastNoiseLite.TYPE_SIMPLEX
	bond.seed = world_seed + 8804
	bond.frequency = 0.14
	bond.fractal_type = FastNoiseLite.FRACTAL_FBM
	bond.fractal_octaves = 2

	var set := {"wear": wear, "bond": bond}
	_noise_cache[world_seed] = set
	return set


# --- Palette de pierres taillées ---

## Toutes les pierres taillées du catalogue, triées (déterminisme : l'ordre
## d'itération d'un Dictionary Godot suit l'insertion, donc l'ordre de lecture
## des fichiers — trier garantit que la même graine donne la même tour d'une
## machine à l'autre).
static func stone_pool() -> PackedStringArray:
	if not _pool_cache.is_empty():
		return _pool_cache
	var ids: Array[String] = []
	for id: String in GameData.materials:
		var mat: Dictionary = GameData.materials[id]
		if "pierre_taillee" in (mat.get("tags", []) as Array):
			ids.append(id)
	ids.sort()
	_pool_cache = PackedStringArray(ids)
	return _pool_cache


## Palette d'une cellule : [maçonnerie principale, accent des moulures].
## Deux pierres suffisent — trois ou plus donnaient un patchwork qui ruinait la
## lecture monumentale de la masse.
static func palette_for(cell: Vector2i, world_seed: int) -> PackedInt32Array:
	var key := Vector3i(cell.x, cell.y, world_seed)
	_palette_mutex.lock()
	if _palette_cache.has(key):
		var hit: PackedInt32Array = _palette_cache[key]
		_palette_mutex.unlock()
		return hit
	_palette_mutex.unlock()

	var pool := stone_pool()
	var out := PackedInt32Array()
	if pool.is_empty():
		# Catalogue sans pierre taillée : repli sur la pierre générique plutôt
		# qu'une tour invisible (id 0 = air), qui serait indébogable.
		var fallback := int(GameData.material_runtime_ids.get("pierre", 0))
		out = PackedInt32Array([fallback, fallback])
	else:
		var h := NoiseGenerator.pcg_hash(cell.x, cell.y, world_seed + 8811)
		var main_index := h % pool.size()
		# L'accent est pris à un décalage PREMIER avec la taille du pool quand
		# c'est possible, pour qu'il ne retombe jamais sur la pierre principale.
		var accent_index := (main_index + 1 + (h >> 8) % maxi(pool.size() - 1, 1)) % pool.size()
		out = PackedInt32Array([
			int(GameData.material_runtime_ids.get(pool[main_index], 0)),
			int(GameData.material_runtime_ids.get(pool[accent_index], 0)),
		])
	_palette_mutex.lock()
	if _palette_cache.size() > 512:
		_palette_cache.clear()  # Borné, régénérable (G.1).
	_palette_cache[key] = out
	_palette_mutex.unlock()
	return out


## Vide les caches dérivés du catalogue. À appeler au hot-reload F5 : les ids
## runtime des matériaux peuvent avoir glissé, une palette gardée pointerait
## alors sur les mauvaises pierres.
static func reset_caches() -> void:
	_pool_cache = PackedStringArray()
	_palette_mutex.lock()
	_palette_cache.clear()
	_palette_mutex.unlock()


# --- Géométrie ---

## Centre (bloc) de la structure : le centre de sa cellule.
static func center_of(cell: Vector2i) -> Vector2i:
	return POIGenerator.cell_center_world(cell)


## true si (wx, wz) tombe dans l'emprise horizontale de la structure.
static func contains(cell: Vector2i, wx: int, wz: int) -> bool:
	var centre := center_of(cell)
	var dx := float(wx - centre.x)
	var dz := float(wz - centre.y)
	return dx * dx + dz * dz <= RADIUS * RADIUS


## Distance au centre d'une TOURELLE, ou une grande valeur si aucune n'est
## proche. Les tourelles sont réparties régulièrement sur le pourtour, leur
## centre posé sur le cercle du fût : elles en débordent donc à moitié, ce qui
## donne les redans verticaux qui cassent la silhouette ronde.
static func _turret_dist(dx: float, dz: float) -> float:
	var angle := atan2(dz, dx)
	var step := TAU / float(TURRET_COUNT)
	# `roundf` et non `round` : la fonction globale `round()` de GDScript rend un
	# Variant, ce qui casse l'inférence de type de la locale. Même remarque pour
	# le nom : `snapped` est une fonction native, une locale ainsi nommée la
	# masquerait.
	var slot_angle := roundf(angle / step) * step
	var tx := cos(slot_angle) * TURRET_ORBIT
	var tz := sin(slot_angle) * TURRET_ORBIT
	return sqrt((dx - tx) * (dx - tx) + (dz - tz) * (dz - tz))


## Hauteur de maçonnerie au-dessus du sol en (wx, wz) : 0 hors emprise.
## C'est le PROFIL EXTÉRIEUR (fût + tourelles + créneaux), avant creusement.
static func height_at(cell: Vector2i, wx: int, wz: int, world_seed: int) -> float:
	var centre := center_of(cell)
	var dx := float(wx - centre.x)
	var dz := float(wz - centre.y)
	var dist := sqrt(dx * dx + dz * dz)
	var turret := _turret_dist(dx, dz)
	# HORS DE L'EMPRISE = RIEN, sans exception : au-delà de RADIUS on est chez
	# la cellule voisine, qui ne générera jamais ces blocs.
	if dist > RADIUS:
		return 0.0
	var in_turret := turret <= TURRET_RADIUS
	var in_body := dist <= BODY_RADIUS
	# Entre BODY_RADIUS et RADIUS il n'y a QUE les tourelles : c'est ce vide qui
	# les détache du mur et donne le relief vertical de la silhouette.
	if not in_body and not in_turret:
		return 0.0

	var top := float(BODY_HEIGHT)
	if in_turret:
		top = float(BODY_HEIGHT + TURRET_RISE)

	# Créneaux : merlons et embrasures alternés sur le couronnement. Le motif
	# suit l'ANGLE et non les coordonnées monde — sinon les merlons seraient
	# alignés sur la grille du monde et non sur la tour, et l'ensemble aurait
	# l'air d'un bloc grignoté au hasard plutôt que d'un couronnement.
	var noises := _noises_for(world_seed)
	var angle := atan2(dz, dx)
	var ring := TURRET_RADIUS if in_turret else BODY_RADIUS
	var period := TAU / maxf(roundf(TAU * ring / 7.0), 8.0)
	var merlon := fmod(absf(angle), period * 2.0) < period
	var edge := dist > BODY_RADIUS - SKIN * 2.0 or (in_turret and turret > TURRET_RADIUS - SKIN)
	if merlon and edge:
		top += float(MERLON_HEIGHT)
	# Usure : quelques merlons manquants, quelques pierres descellées.
	var wear: float = (noises["wear"] as FastNoiseLite).get_noise_2d(float(wx), float(wz))
	top -= maxf(0.0, wear) * 4.0
	return maxf(top, 0.0)


## true si (local_x, local_y, local_z) — coordonnées RELATIVES au centre et au
## sol — est creusé : salle centrale, tunnels d'entrée, puits de lumière.
## Regroupé en une fonction pour que `block_at` et `inside_interior` ne puissent
## pas diverger : ils décrivaient la même cavité à deux endroits, et toute
## correction faite d'un seul côté déplaçait le déclencheur d'entrée hors de la
## salle réellement creusée.
static func _is_carved(dx: float, dy: int, dz: float) -> bool:
	if dy < HALL_FLOOR:
		return false
	var dist := sqrt(dx * dx + dz * dz)
	# Salle centrale.
	if dist <= HALL_RADIUS and dy < HALL_FLOOR + HALL_HEIGHT:
		return true
	# Puits de lumière, de la voûte de la salle jusqu'au sommet.
	if dist <= SHAFT_RADIUS and dy >= HALL_FLOOR + HALL_HEIGHT:
		return true
	# Tunnels cardinaux : un couloir plein axe X et un plein axe Z, bornés à
	# l'emprise. Ils traversent donc la salle de part en part — c'est voulu,
	# la salle est un carrefour à quatre portes.
	if dy < HALL_FLOOR + ENTRY_HEIGHT:
		if absf(dz) <= float(ENTRY_HALF_WIDTH) and absf(dx) <= RADIUS:
			return true
		if absf(dx) <= float(ENTRY_HALF_WIDTH) and absf(dz) <= RADIUS:
			return true
	return false


## Matériau (id runtime) d'un bloc plein. `ids` = [principale, accent].
static func _material_for(wx: int, wy: int, wz: int, local_y: int,
		world_seed: int, ids: PackedInt32Array) -> int:
	if ids.is_empty():
		return 0
	if ids.size() < 2:
		return ids[0]
	# Moulures : une assise d'accent à intervalle régulier, plus le socle et le
	# couronnement. C'est ce qui donne l'échelle à la tour — sans ces lignes
	# horizontales, 88 blocs de pierre uniforme n'ont pas de taille lisible.
	if local_y < 2 or local_y % COURSE_SPACING == 0:
		return ids[1]
	var noises := _noises_for(world_seed)
	var value: float = (noises["bond"] as FastNoiseLite).get_noise_3d(
			float(wx), float(wy) * 2.0, float(wz))
	# Appareillage : quelques pierres d'accent dispersées dans la masse.
	return ids[1] if value > 0.62 else ids[0]


## Matériau d'INTÉRIEUR (salles/couloirs des étages, DungeonManager) : même
## maçonnerie que la tour, sans la logique de moulures — un étage a son propre
## rythme architectural, imposer celui du fût n'aurait pas de sens.
static func interior_material(wx: int, wy: int, wz: int, world_seed: int, ids: PackedInt32Array) -> int:
	if ids.is_empty():
		return 0
	if ids.size() < 2:
		return ids[0]
	var noises := _noises_for(world_seed)
	var value: float = (noises["bond"] as FastNoiseLite).get_noise_3d(
			float(wx), float(wy) * 2.0, float(wz))
	return ids[1] if value > 0.62 else ids[0]


## Bloc de la structure en (wx, wy, wz), ou 0 pour du vide. `ground_y` = sol
## au centre de la cellule. `ids` = palette de la cellule (voir palette_for).
static func block_at(cell: Vector2i, wx: int, wy: int, wz: int,
		ground_y: int, world_seed: int, ids: PackedInt32Array) -> int:
	var centre := center_of(cell)
	var dx := float(wx - centre.x)
	var dz := float(wz - centre.y)
	var local_y := wy - ground_y
	if local_y < 0:
		return 0
	var top := height_at(cell, wx, wz, world_seed)
	if top <= 0.0 or float(local_y) > top:
		return 0
	if _is_carved(dx, local_y, dz):
		return 0
	return _material_for(wx, wy, wz, local_y, world_seed, ids)


## true si la position est DANS la salle centrale — c'est le déclencheur
## d'entrée en donjon. Volontairement plus strict que « dans une cavité » : un
## joueur qui longe un tunnel d'entrée ne doit pas être happé avant d'avoir
## atteint la salle, sinon l'entrée se déclenche au premier pas sous le linteau.
static func inside_interior(cell: Vector2i, wx: int, wy: int, wz: int,
		ground_y: int, _world_seed: int) -> bool:
	var centre := center_of(cell)
	var dx := float(wx - centre.x)
	var dz := float(wz - centre.y)
	var local_y := wy - ground_y
	if local_y < HALL_FLOOR or local_y >= HALL_FLOOR + HALL_HEIGHT:
		return false
	return dx * dx + dz * dz <= HALL_RADIUS * HALL_RADIUS

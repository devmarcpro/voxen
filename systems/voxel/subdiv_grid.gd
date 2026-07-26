class_name SubdivGrid
extends RefCounted
## Sous-grille de subdivision d'un bloc (4.1, chaîne 32→16→8→4 amendée).
## Représentation PLATE : PackedInt32Array de 8×8×8 = 512 cellules de 4 px
## (id matériau runtime, 0 = air), indice = x | z<<3 | y<<6.
## Choix délibéré vs l'octree esquissé en G.2 : avec 3 niveaux seulement, la
## grille plate est plus rapide (pas de pointeurs en GDScript) pour le même
## budget mémoire borné (2 Ko × 512 blocs subdivisés max par chunk).
## Fonctions STATIQUES sur le tableau — aucune instance par bloc.

const SIZE := 8            # Cellules de 4 px par côté de bloc.
const CELLS := 512
const CELL_UNIT := 0.125   # Taille d'une cellule en unités monde (1/8 bloc).


static func create_empty() -> PackedInt32Array:
	var grid := PackedInt32Array()
	grid.resize(CELLS)
	return grid


static func create_full(material_id: int) -> PackedInt32Array:
	var grid := create_empty()
	if material_id != 0:
		grid.fill(material_id)
	return grid


static func cell_index(x: int, y: int, z: int) -> int:
	return x | (z << 3) | (y << 6)


## Écrit une région cubique (cell_min dans 0..7, size 1/2/4/8 cellules).
static func set_region(grid: PackedInt32Array, cell_min: Vector3i, size: int, material_id: int) -> void:
	for y in range(cell_min.y, cell_min.y + size):
		for z in range(cell_min.z, cell_min.z + size):
			var row := (z << 3) | (y << 6)
			for x in range(cell_min.x, cell_min.x + size):
				grid[row | x] = material_id


## True si toute la région est d'air (placement possible).
static func region_empty(grid: PackedInt32Array, cell_min: Vector3i, size: int) -> bool:
	for y in range(cell_min.y, cell_min.y + size):
		for z in range(cell_min.z, cell_min.z + size):
			var row := (z << 3) | (y << 6)
			for x in range(cell_min.x, cell_min.x + size):
				if grid[row | x] != 0:
					return false
	return true


static func count_solid(grid: PackedInt32Array) -> int:
	var count := 0
	for i in CELLS:
		if grid[i] != 0:
			count += 1
	return count


## Id le plus représenté (0 si la grille est vide) — représentation LOD/ray
## du bloc subdivisé (approximation de la « couleur moyenne » de G.2 dans un
## pipeline à 1 id par face).
static func dominant_id(grid: PackedInt32Array) -> int:
	var counts := {}
	var best_id := 0
	var best_count := 0
	for i in CELLS:
		var id := grid[i]
		if id == 0:
			continue
		var c := int(counts.get(id, 0)) + 1
		counts[id] = c
		if c > best_count:
			best_count = c
			best_id = id
	return best_id


## Si toutes les cellules portent le même id (air compris), le retourne dans
## Vector2i(1, id) ; sinon Vector2i(0, 0). Sert à re-fusionner un bloc
## redevenu uniforme (plein ou vide) en bloc simple.
static func uniform_value(grid: PackedInt32Array) -> Vector2i:
	var first := grid[0]
	for i in range(1, CELLS):
		if grid[i] != first:
			return Vector2i(0, 0)
	return Vector2i(1, first)

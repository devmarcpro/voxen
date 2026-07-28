extends Node
## ExplorationManager — brouillard de guerre de la minimap (E.30). Persiste
## entre sessions via SaveManager (E.10, 2026-07-21).
## "Exploré" = simplifié en PROXIMITÉ du joueur (rayon fixe), en l'absence du
## cône de détection/vision réel (E.16, pas encore implémenté).
##
## STOCKAGE (réécrit le 2026-07-27) : une entrée par COLONNE (chunk_x, chunk_z)
## portant un masque de 64 bits, un bit par chunk_y. Le monde fait exactement
## 64 niveaux de chunks (WorldManager.CY_MIN_ABS..CY_MAX_ABS = -32..31), donc
## le masque est EXACT — aucune perte d'information.
##
## Pourquoi : le stockage précédent était une entrée de dictionnaire par chunk
## (x, z, y) VISITÉ, sérialisée en un triplet JSON à chaque autosave. Rien ne
## la bornait : elle grossissait indéfiniment avec l'exploration (jusqu'à 64
## entrées pour une seule colonne parcourue de haut en bas), et l'autosave
## sérialisait le tout sur le thread principal toutes les 5 minutes. Une longue
## partie finissait par payer des dizaines de Mo de JSON à chaque sauvegarde —
## une dégradation progressive, sans erreur, difficile à relier à sa cause.

const DETECTION_RADIUS_CHUNKS := 6
const MARK_INTERVAL_TICKS := 5  # Throttle (G.1) : pas de recalcul par frame.

## Bornes verticales en chunks (miroir de WorldManager) : 64 niveaux = 64 bits.
const CY_MIN := -32
const CY_COUNT := 64

## Vector2i(chunk_x, chunk_z) -> int (masque de bits, bit n = chunk_y CY_MIN+n).
var explored := {}

var _tick_counter := 0


func _ready() -> void:
	TickManager.tick_post.connect(_on_tick)


## Bit de `cy` dans un masque de colonne, ou 0 si hors des bornes du monde.
static func _bit_for(cy: int) -> int:
	var index := cy - CY_MIN
	if index < 0 or index >= CY_COUNT:
		return 0
	return 1 << index


func is_explored(cx: int, cz: int, cy: int) -> bool:
	var bit := _bit_for(cy)
	if bit == 0:
		return false
	return (int(explored.get(Vector2i(cx, cz), 0)) & bit) != 0


## true si la colonne a été explorée à N'IMPORTE quelle hauteur — ce que veut
## une carte vue de dessus (minimap, carte du monde).
func is_column_explored(cx: int, cz: int) -> bool:
	return int(explored.get(Vector2i(cx, cz), 0)) != 0


func _on_tick(_tick_index: int) -> void:
	_tick_counter += 1
	if _tick_counter < MARK_INTERVAL_TICKS:
		return
	_tick_counter = 0
	if WorldManager.generator == null:
		return  # Aucun monde actif (menu) : ne rien marquer.
	if WorldManager.active_dimension != &"overworld":
		return  # En donjon : les coordonnées locales pollueraient la minimap overworld.
	var player := get_node_or_null("/root/Main/Player")
	if player == null:
		return
	var pos: Vector3 = player.get_position_for_ai()
	var pcx := floori(pos.x / ChunkData.SIZE)
	var pcz := floori(pos.z / ChunkData.SIZE)
	var pcy := floori(pos.y / ChunkData.SIZE)
	var bit := _bit_for(pcy)
	if bit == 0:
		return  # Joueur hors des bornes verticales du monde : rien à marquer.
	for dx in range(-DETECTION_RADIUS_CHUNKS, DETECTION_RADIUS_CHUNKS + 1):
		for dz in range(-DETECTION_RADIUS_CHUNKS, DETECTION_RADIUS_CHUNKS + 1):
			if dx * dx + dz * dz > DETECTION_RADIUS_CHUNKS * DETECTION_RADIUS_CHUNKS:
				continue
			var column := Vector2i(pcx + dx, pcz + dz)
			var mask := int(explored.get(column, 0))
			if (mask & bit) != 0:
				continue
			explored[column] = mask | bit
			EventBus.chunk_explored.emit(Vector3i(column.x, column.y, pcy))


# --- Sauvegarde (E.10, via SaveManager) ---

## Format : [x, z, lo, hi] par colonne. Le masque est scindé en deux moitiés
## de 32 bits car state.json est du JSON : ses nombres sont relus en double,
## qui ne représente exactement que 53 bits — un masque 64 bits d'un seul
## tenant perdrait ses bits hauts en silence (chunks profonds « oubliés »).
func save_state() -> Array:
	var out := []
	for column: Vector2i in explored:
		var mask := int(explored[column])
		out.append([column.x, column.y, mask & 0xFFFFFFFF, (mask >> 32) & 0xFFFFFFFF])
	return out


func restore_state(data: Array) -> void:
	explored.clear()
	for entry: Variant in data:
		if not (entry is Array):
			continue
		var values: Array = entry
		if values.size() == 4:
			var mask: int = (int(values[2]) & 0xFFFFFFFF) | ((int(values[3]) & 0xFFFFFFFF) << 32)
			if mask != 0:
				explored[Vector2i(int(values[0]), int(values[1]))] = mask
		elif values.size() == 3:
			# Format HISTORIQUE (un triplet par chunk : x, z, y) — les
			# sauvegardes antérieures au 2026-07-27 restent lisibles.
			var bit := _bit_for(int(values[2]))
			if bit != 0:
				var column := Vector2i(int(values[0]), int(values[1]))
				explored[column] = int(explored.get(column, 0)) | bit

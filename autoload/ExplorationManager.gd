extends Node
## ExplorationManager — brouillard de guerre de la minimap (E.30). Stockage
## à résolution CHUNK par bande verticale (chunk_y), un bit par chunk visité,
## comme spécifié. Persiste entre sessions via SaveManager (E.10, 2026-07-21).
## "Exploré" = simplifié en PROXIMITÉ du joueur (rayon fixe), en l'absence du
## cône de détection/vision réel (E.16, pas encore implémenté).

const DETECTION_RADIUS_CHUNKS := 6
const MARK_INTERVAL_TICKS := 5  # Throttle (G.1) : pas de recalcul par frame.

## Vector3i(chunk_x, chunk_z, chunk_y) -> true (bitmask compact via Dictionary,
## suffisant tant que le nombre de chunks explorés reste modeste).
var explored := {}

var _tick_counter := 0


func _ready() -> void:
	TickManager.tick.connect(_on_tick)


func is_explored(cx: int, cz: int, cy: int) -> bool:
	return explored.has(Vector3i(cx, cz, cy))


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
	for dx in range(-DETECTION_RADIUS_CHUNKS, DETECTION_RADIUS_CHUNKS + 1):
		for dz in range(-DETECTION_RADIUS_CHUNKS, DETECTION_RADIUS_CHUNKS + 1):
			if dx * dx + dz * dz > DETECTION_RADIUS_CHUNKS * DETECTION_RADIUS_CHUNKS:
				continue
			var key := Vector3i(pcx + dx, pcz + dz, pcy)
			if not explored.has(key):
				explored[key] = true
				EventBus.chunk_explored.emit(key)


# --- Sauvegarde (E.10, via SaveManager) ---

func save_state() -> Array:
	var out := []
	for key: Vector3i in explored:
		out.append([key.x, key.y, key.z])
	return out


func restore_state(data: Array) -> void:
	explored.clear()
	for entry: Variant in data:
		if entry is Array and (entry as Array).size() == 3:
			explored[Vector3i(int(entry[0]), int(entry[1]), int(entry[2]))] = true

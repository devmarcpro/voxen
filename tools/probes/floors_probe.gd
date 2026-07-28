extends Probe
## Sonde `--probe-etages` (2026-07-28) : vérifie le donjon MULTI-ÉTAGE.
##
## Couvre les quatre points de la demande :
##  1. les salles sont bâties dans la matière démoniaque du nid, plus en pierre ;
##  2. il existe un orifice de DESCENTE à chaque étage sauf le dernier ;
##  3. le joueur arrive DOS à l'orifice de remontée ;
##  4. descente et remontée enchaînent les étages, et la remontée depuis le
##     premier fait bien sortir dans l'overworld.

func run() -> void:
	await wait_seconds(0.5)
	var dm := DungeonManager
	var g := WorldManager.generator

	# Trouver une cellule de donjon (même méthode que --probe-dungeon).
	var cell := Vector2i.ZERO
	var found := false
	for radius in range(0, 60):
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if maxi(absi(dx), absi(dz)) != radius:
					continue
				var c := Vector2i(dx, dz)
				var centre := POIGenerator.cell_center_world(c)
				var biome := g.biome_at(centre.x, centre.y)
				if biome.is_empty():
					continue
				if "donjon" in POIGenerator.pois_at_cell(c, WorldManager.world_seed, biome):
					cell = c
					found = true
					break
			if found:
				break
		if found:
			break
	if not found:
		print("[ETAGES] aucune cellule de donjon trouvée — test impossible.")
		finish(false, "ETAGES")
		return

	var centre := POIGenerator.cell_center_world(cell)
	var danger := g.danger_level(centre.x, centre.y)
	var total: int = dm._floor_count(cell)
	print("[ETAGES] cellule=%s danger=%d → %d étages (attendu %d)" % [
		cell, danger, total, DungeonManager.FLOORS_BY_DANGER[danger]])
	var ok := total == DungeonManager.FLOORS_BY_DANGER[danger]

	# --- Entrée par le premier étage ---
	dm._enter_dungeon(cell, Vector3(centre.x, 80.0, centre.y))
	await wait_frame()
	print("[ETAGES] entré : dimension=%s étage=%d" % [
		WorldManager.active_dimension, dm._current_depth])
	ok = ok and WorldManager.active_dimension == &"donjon" and dm._current_depth == 0

	# --- 1. Matière du nid ---
	var palette_names := DungeonTower.PALETTE
	var nest_ids := {}
	for name: String in palette_names:
		nest_ids[int(GameData.material_runtime_ids.get(name, -1))] = name
	var sol_id := WorldManager.block_at_world(Vector3i(3, 0, 3))
	var pierre_id: int = GameData.material_runtime_ids.get("pierre", -1)
	var sol_name: String = nest_ids.get(sol_id, "?")
	print("[ETAGES] sol de la salle d'entrée : id=%d (%s) — pierre=%s" % [
		sol_id, sol_name, sol_id == pierre_id])
	ok = ok and nest_ids.has(sol_id)

	# --- 3. Orientation à l'arrivée : dos à l'orifice de remontée ---
	var up := dm._ascent_orifice_position()
	var arrival := dm._entrance_center()
	var yaw: float = dm._arrival_yaw(up, arrival)
	# Le vecteur « regard » reconstruit depuis le yaw doit s'éloigner de l'orifice.
	var look := Vector3(-sin(deg_to_rad(yaw)), 0.0, -cos(deg_to_rad(yaw)))
	var away := (arrival - up).normalized()
	var alignment := look.dot(away)
	print("[ETAGES] arrivée : yaw=%.1f° alignement avec « dos à l'orifice »=%.2f (attendu ~1)" % [
		yaw, alignment])
	ok = ok and alignment > 0.9

	# --- 2 + 4. Descente jusqu'au fond ---
	var core_id: int = GameData.material_runtime_ids.get(DungeonManager.ORIFICE_CORE, -1)
	for expected_depth in range(1, total):
		var key := DungeonManager._floor_key(cell, dm._current_depth)
		var down := dm._descent_orifice_position(key)
		# L'orifice de descente doit EXISTER sur cet étage (le dernier n'en a pas).
		# floori() et non int() : int() tronque vers zéro, donc se trompe d'un bloc
		# en coordonnées négatives — _carve_orifice utilise bien floor(), et la
		# première version de cette sonde lisait donc le bloc VOISIN de l'orifice
		# (d'où un id incohérent d'un étage à l'autre).
		var core_found := WorldManager.block_at_world(
			Vector3i(floori(down.x), floori(down.y), floori(down.z)))
		var core_ok := core_found == core_id
		dm._descend()
		await wait_frame()
		print("[ETAGES]   descente → étage %d/%d (orifice en %s, cœur=%d attendu=%d %s)" % [
			dm._current_depth + 1, total, down, core_found, core_id,
			"OK" if core_ok else "MANQUANT"])
		ok = ok and dm._current_depth == expected_depth and core_ok

	# Au fond : plus d'orifice de descente.
	var at_bottom := dm._current_depth == total - 1
	print("[ETAGES] au fond : étage=%d/%d (attendu %d)" % [
		dm._current_depth + 1, total, total])
	ok = ok and at_bottom

	# --- 4. Remontée complète jusqu'à la sortie ---
	for expected_depth in range(total - 2, -1, -1):
		dm._ascend()
		await wait_frame()
		ok = ok and dm._current_depth == expected_depth
	print("[ETAGES] remonté au premier étage : étage=%d" % dm._current_depth)
	# Depuis le premier, la remontée fait SORTIR.
	dm._ascend()
	await wait_frame()
	print("[ETAGES] sortie : dimension=%s (attendu overworld)" % WorldManager.active_dimension)
	ok = ok and WorldManager.active_dimension == &"overworld"

	finish(ok, "ETAGES")

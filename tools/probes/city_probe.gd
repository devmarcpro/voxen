extends Probe
## Sonde `--probe-city` — extraite de main.gd le 2026-07-28 (audit architectural).
## Logique inchangée : seuls les accès à la scène ont été réécrits
## ($Player -> player, get_tree() -> main.get_tree(), etc.).


## Sonde headless de génération de villes (point 5, 2026-07-21) : trouve une
## cellule avec un village CONSTRUCTIBLE, vérifie le plan (routes croix + ≥2
## sorties, bâtiments = population), le terrassement (footprint aplati au
## plateau) et les blocs réels (route en gravier, murs de bâtiment posés).
func run() -> void:
	await main.get_tree().process_frame
	var g := WorldManager.generator
	var found_cell := Vector2i.ZERO
	var layout := {}
	for cx in range(-60, 61):
		if not layout.is_empty():
			break
		for cz in range(-60, 61):
			var l := g.city_at_cell(Vector2i(cx, cz))
			if not l.is_empty():
				found_cell = Vector2i(cx, cz)
				layout = l
				break
	print("[CITYPROBE] village constructible trouvé=%s cellule=%s" % [not layout.is_empty(), found_cell])
	if layout.is_empty():
		main.get_tree().quit(1)
		return
	var t: int = layout["T"]
	var types: PackedByteArray = layout["types"]
	var roads := 0
	var buildings := 0
	for v in types:
		if v == 1:
			roads += 1
		elif v == 2:
			buildings += 1
	# Sorties = tuiles route sur le bord du footprint (la croix en donne 4).
	var exits := 0
	for k in t:
		if types[0 * t + k] == 1 or types[(t - 1) * t + k] == 1:
			exits += 1
		if types[k * t + 0] == 1 or types[k * t + (t - 1)] == 1:
			exits += 1
	print("[CITYPROBE] T=%d routes=%d bâtiments=%d population=%d sorties=%d (attendu ≥2)" % [
		t, roads, buildings, layout["population"], exits])

	# Terrassement : une colonne du footprint doit être aplatie au plateau.
	var cell: Vector2i = layout["cell"]
	var offset: int = layout["offset"]
	var plateau: int = layout["plateau_y"]
	var footprint_wx := cell.x * 128 + offset * 16 + 8
	var footprint_wz := cell.y * 128 + offset * 16 + 8
	var surf := g.sample_surface(footprint_wx, footprint_wz)
	print("[CITYPROBE] terrassement : h=%d (attendu plateau=%d)" % [surf["h"], plateau])

	# Un bloc de route et un mur de bâtiment doivent exister au monde.
	var road_ok := false
	var wall_ok := false
	var gravier: int = GameData.material_runtime_ids.get("gravier", -1)
	for tz in t:
		for tx in t:
			var idx := tz * t + tx
			var wx := cell.x * 128 + (offset + tx) * 16 + 8
			var wz := cell.y * 128 + (offset + tz) * 16 + 8
			if types[idx] == 1 and g.block_at(wx, plateau, wz) == gravier:
				road_ok = true
			if types[idx] == 2:
				# Un coin de la boîte du bâtiment (mur `mur` de la palette) à plateau+1.
				var bwx := cell.x * 128 + (offset + tx) * 16 + CityGenerator.B_LO
				var bwz := cell.y * 128 + (offset + tz) * 16 + CityGenerator.B_LO
				if g.block_at(bwx, plateau + 1, bwz) == int((layout["palette"] as Dictionary)["mur"]):
					wall_ok = true
	print("[CITYPROBE] route posée=%s mur de bâtiment posé=%s" % [road_ok, wall_ok])

	var ok: bool = t >= 3 and roads > 0 and buildings > 0 and exits >= 2 \
		and surf["h"] == plateau and road_ok and wall_ok
	print("[CITYPROBE] RÉSULTAT : %s" % ("OK" if ok else "ÉCHEC"))
	main.get_tree().quit(0 if ok else 1)

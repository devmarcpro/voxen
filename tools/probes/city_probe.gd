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
	# DEUX décalages depuis la recherche de site du 2026-08-01 : le village n'est
	# plus centré dans sa cellule, il se pose là où le terrain le permet. Lire
	# `offset` pour les deux axes échantillonnait à côté du village et faisait
	# échouer la sonde sur un village pourtant correct.
	var offset: int = layout["offset"]
	var offset_z: int = layout.get("offset_z", offset)
	var plateau: int = layout["plateau_y"]
	var footprint_wx := cell.x * 128 + offset * 16 + 8
	var footprint_wz := cell.y * 128 + offset_z * 16 + 8
	var surf := g.sample_surface(footprint_wx, footprint_wz)
	print("[CITYPROBE] terrassement : h=%d (attendu plateau=%d)" % [surf["h"], plateau])

	# --- Ce qui fait qu'un bâtiment est un bâtiment -------------------------
	#
	# Le test précédent lisait UN coin, à une coordonnée en dur, et le comparait
	# au matériau de mur. Il ne prouvait presque rien et il est devenu faux à la
	# refonte du 2026-08-01 : les angles sont désormais en poutre, et la marge
	# varie d'un archétype à l'autre. On vérifie donc les PROPRIÉTÉS, pas des
	# coordonnées : un mur, un plancher, une ouverture, un toit en pente.
	var road_ok := false
	var wall_ok := false
	var floor_ok := false
	var door_ok := false
	var roof_ok := false
	var gravier: int = GameData.material_runtime_ids.get("gravier", -1)
	var palette: Dictionary = layout["palette"]
	var archetypes: Dictionary = layout.get("archetypes", {})

	for tz in t:
		for tx in t:
			var idx := tz * t + tx
			var wx := cell.x * 128 + (offset + tx) * 16 + 8
			var wz := cell.y * 128 + (offset_z + tz) * 16 + 8
			if types[idx] == CityGenerator.Tile.ROUTE and g.block_at(wx, plateau, wz) == gravier:
				road_ok = true
			if types[idx] != CityGenerator.Tile.BATIMENT:
				continue
			var spec: Dictionary = CityGenerator.ARCHETYPES.get(
				String(archetypes.get(idx, "maison")), CityGenerator.ARCHETYPES["maison"])
			var margin := int(spec["marge"])
			var wall_height := int(spec["murs"])
			var base_x := cell.x * 128 + (offset + tx) * 16
			var base_z := cell.y * 128 + (offset_z + tz) * 16
			var lo := margin
			var hi := 15 - margin
			@warning_ignore("integer_division")
			var mid := (lo + hi) / 2

			# MUR : le milieu d'une face, à hauteur d'homme. Un angle serait en
			# poutre, un point quelconque pourrait tomber sur une fenêtre.
			if g.block_at(base_x + mid, plateau + 1, base_z + lo) != 0:
				wall_ok = true
			# PLANCHER : l'intérieur repose sur le sol de la palette, pas sur la
			# terre du plateau. Il n'y en avait aucun avant la refonte.
			if g.block_at(base_x + mid, plateau, base_z + mid) == int(palette["sol"]):
				floor_ok = true
			# OUVERTURE : quelque part sur le périmètre, à hauteur de regard, il
			# doit y avoir de l'air — porte ou fenêtre. Un volume entièrement
			# clos serait inhabitable.
			for probe_x in range(lo, hi + 1):
				if g.block_at(base_x + probe_x, plateau + 2, base_z + lo) == 0 						or g.block_at(base_x + probe_x, plateau + 2, base_z + hi) == 0:
					door_ok = true
					break
			# TOIT EN PENTE. On cherche le point le plus HAUT de la toiture dans
			# la tuile et on exige qu'il dépasse le premier rang d'avant-toit :
			# un toit plat les met à la même hauteur, une pente les sépare.
			#
			# Tester « le centre est plein au-dessus du bord » serait FAUX : sous
			# deux pans, le centre est un comble vide. C'est exactement l'erreur
			# que ce commentaire existe pour empêcher de refaire.
			var eave_y := plateau + wall_height + 1
			var highest := 0
			for probe_y in range(eave_y, plateau + CityGenerator.MAX_BUILD_HEIGHT + 2):
				for probe_x in range(lo - 1, hi + 2):
					for probe_z in range(lo - 1, hi + 2):
						if g.block_at(base_x + probe_x, probe_y, base_z + probe_z) 								== int(palette["toit"]):
							highest = maxi(highest, probe_y)
			if highest > eave_y:
				roof_ok = true

	print("[CITYPROBE] mur=%s plancher=%s ouverture=%s toit en pente=%s" % [
		wall_ok, floor_ok, door_ok, roof_ok])
	print("[CITYPROBE] route posée=%s" % road_ok)

	# AUCUNE TUILE NUE. C'est le défaut qui donnait à un village son air de
	# chantier abandonné : les trois quarts du footprint restaient en terre.
	var bare := 0
	for value: int in types:
		if value == CityGenerator.Tile.VIDE:
			bare += 1
	print("[CITYPROBE] tuiles laissées vides : %d (attendu 0)" % bare)

	var ok: bool = t >= 3 and roads > 0 and buildings > 0 and exits >= 2 		and surf["h"] == plateau and road_ok and wall_ok and floor_ok 		and door_ok and roof_ok and bare == 0
	print("[CITYPROBE] RÉSULTAT : %s" % ("OK" if ok else "ÉCHEC"))
	main.get_tree().quit(0 if ok else 1)

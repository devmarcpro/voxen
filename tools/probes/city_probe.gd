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
	# ON GARDE LE PLUS GRAND, pas le premier venu. Le premier village rencontre
	# est un HAMEAU une fois sur deux, et photographier un hameau pour juger
	# d une refonte de villages revient a juger une ville sur son plus petit
	# faubourg (constate le 2026-08-09 : quatre maisons a l ecran, alors que la
	# categorie « ville » en pose trois fois plus).
	var best_t := 0
	for cx in range(-60, 61):
		for cz in range(-60, 61):
			var l := g.city_at_cell(Vector2i(cx, cz))
			if l.is_empty():
				continue
			if int(l["T"]) > best_t:
				best_t = int(l["T"])
				found_cell = Vector2i(cx, cz)
				layout = l
			if best_t >= CityGenerator.FOOTPRINT["ville"]:
				break
		if best_t >= CityGenerator.FOOTPRINT["ville"]:
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
	# SORTIES. Le village n est plus un carre plein (forme organique du
	# 2026-08-09) : compter les rues sur le bord de la BOITE ENGLOBANTE rend
	# desormais zero sur un village parfaitement desservi, puisque la forme
	# n atteint plus les bords de sa fenetre. Une sortie, c est une rue qui
	# DEBOUCHE SUR LE DEHORS — donc dont une voisine est hors du village.
	var exits := 0
	for idx in types.size():
		if types[idx] != CityGenerator.Tile.ROUTE:
			continue
		var tx := idx % t
		@warning_ignore("integer_division")
		var tz := idx / t
		for step: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nx := tx + step.x
			var nz := tz + step.y
			if nx < 0 or nx >= t or nz < 0 or nz >= t 					or types[nz * t + nx] == CityGenerator.Tile.HORS:
				exits += 1
				break
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
	# ON SONDE LA PLACE, pas le coin de la boite. Hors du village la colonne est
	# du terrain naturel — et depuis que les rues suivent le relief, une bonne
	# part du village ne l est plus non plus. La place, elle, est pavee et de
	# niveau par definition : c est le seul point dont le palier fasse foi.
	var square_idx := _square_index(types, t)
	@warning_ignore("integer_division")
	var footprint_wx := cell.x * 128 + (offset + square_idx % t) * 16 + 8
	@warning_ignore("integer_division")
	var footprint_wz := cell.y * 128 + (offset_z + square_idx / t) * 16 + 8
	var surf := g.sample_surface(footprint_wx, footprint_wz)
	# TERRASSEMENT EN PALIERS (2026-08-09). Le village n a plus UN plateau mais
	# un palier par tuile : comparer la surface au `plateau_y` global n a plus de
	# sens, et la sonde a echoue sur un village parfaitement correct (h=17 pour
	# un plateau median de 19). Ce qui doit rester vrai, c est que la colonne
	# soit posee sur SON palier — et que les paliers restent franchissables.
	var terraces: PackedInt32Array = layout.get("terraces", PackedInt32Array())
	@warning_ignore("integer_division")
	var terrace_ok := int(surf["h"]) == _terrace_at(layout, square_idx % t, square_idx / t)
	var step_ok := true
	var worst := 0
	for tz2 in t:
		for tx2 in t:
			if types[tz2 * t + tx2] == CityGenerator.Tile.HORS:
				continue
			for delta: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
				var nx := tx2 + delta.x
				var nz := tz2 + delta.y
				if nx >= t or nz >= t:
					continue
				# Deux tuiles du VILLAGE. Comparer un palier a celui d une tuile
				# hors du village n a aucun sens : dehors, le terrain est reste
				# naturel et son palier n a jamais ete applique.
				if types[nz * t + nx] == CityGenerator.Tile.HORS:
					continue
				var gap: int = absi(_terrace_at(layout, tx2, tz2) - _terrace_at(layout, nx, nz))
				worst = maxi(worst, gap)
				if gap > NoiseGenerator.CITY_TERRACE_STEP:
					step_ok = false
	@warning_ignore("integer_division")
	print("[CITYPROBE] terrassement de la place : h=%d (palier attendu=%d) paliers=%d" % [
		surf["h"], _terrace_at(layout, square_idx % t, square_idx / t), terraces.size()])
	# UN VILLAGE OU L ON NE PEUT PAS MARCHER N EST PAS UN VILLAGE. La marche d un
	# bloc se franchit sans sauter ; au-dela il faudrait des escaliers, que
	# personne ne genere. C est l assertion qui rend la refonte du relief sure.
	print("[CITYPROBE] paliers franchissables : %s (pire denivele entre voisines : %d)" % [
		step_ok, worst])


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
			var terrace := _terrace_at(layout, tx, tz)
			if types[idx] == CityGenerator.Tile.ROUTE and g.block_at(wx, terrace, wz) == gravier:
				road_ok = true
			if types[idx] != CityGenerator.Tile.BATIMENT:
				continue
			var spec: Dictionary = CityGenerator.ARCHETYPES.get(
				String(archetypes.get(idx, "maison")), CityGenerator.ARCHETYPES["maison"])
			var margin := int(spec["marge"])
			# La hauteur des murs VARIE par batiment depuis le 2026-08-09 : la
			# fiche d archetype ne donne plus qu une base. On mesure donc la
			# hauteur reelle au lieu de la supposer.
			var wall_height := _measured_wall_height(g, layout, tx, tz, margin)
			var base_x := cell.x * 128 + (offset + tx) * 16
			var base_z := cell.y * 128 + (offset_z + tz) * 16
			var lo := margin
			var hi := 15 - margin
			@warning_ignore("integer_division")
			var mid := (lo + hi) / 2

			# MUR : le milieu d'une face, à hauteur d'homme. Un angle serait en
			# poutre, un point quelconque pourrait tomber sur une fenêtre.
			if g.block_at(base_x + mid, terrace + 1, base_z + lo) != 0:
				wall_ok = true
			# PLANCHER : l'intérieur repose sur le sol de la palette, pas sur la
			# terre du plateau. Il n'y en avait aucun avant la refonte.
			if g.block_at(base_x + mid, terrace, base_z + mid) == int(palette["sol"]):
				floor_ok = true
			# OUVERTURE : quelque part sur le périmètre, à hauteur de regard, il
			# doit y avoir de l'air — porte ou fenêtre. Un volume entièrement
			# clos serait inhabitable.
			for probe_x in range(lo, hi + 1):
				if g.block_at(base_x + probe_x, terrace + 2, base_z + lo) == 0 						or g.block_at(base_x + probe_x, terrace + 2, base_z + hi) == 0:
					door_ok = true
					break
			# TOIT EN PENTE. On cherche le point le plus HAUT de la toiture dans
			# la tuile et on exige qu'il dépasse le premier rang d'avant-toit :
			# un toit plat les met à la même hauteur, une pente les sépare.
			#
			# Tester « le centre est plein au-dessus du bord » serait FAUX : sous
			# deux pans, le centre est un comble vide. C'est exactement l'erreur
			# que ce commentaire existe pour empêcher de refaire.
			var eave_y := terrace + wall_height + 1
			var highest := 0
			for probe_y in range(eave_y, terrace + CityGenerator.MAX_BUILD_HEIGHT + 2):
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

	await _capture_village(layout)

	var ok: bool = t >= 3 and roads > 0 and buildings > 0 and exits >= 2 		and terrace_ok and step_ok and road_ok and wall_ok and floor_ok 		and door_ok and roof_ok and bare == 0
	print("[CITYPROBE] RÉSULTAT : %s" % ("OK" if ok else "ÉCHEC"))
	main.get_tree().quit(0 if ok else 1)


## PHOTOGRAPHIER LE VILLAGE (2026-08-09).
##
## Toutes les assertions au-dessus decrivent une STRUCTURE : des murs existent,
## une route est posee, aucune tuile n est nue. Aucune ne dit si l endroit
## ressemble a un village. C est exactement ce que la refonte demandee visait —
## des rues ou l on navigue, des paliers qui suivent le relief, du decor — et
## rien de tout ca ne se lit dans un booleen.
##
## Trois points de vue, choisis pour montrer trois choses differentes : la
## silhouette d ensemble depuis le ciel, le relief depuis un angle rasant, et la
## rue depuis la hauteur des yeux — la seule qui dise si l on peut y circuler.
func _capture_village(layout: Dictionary) -> void:
	if not can_capture():
		return
	var cell: Vector2i = layout["cell"]
	var t: int = layout["T"]
	var offset := int(layout["offset"])
	var offset_z := int(layout.get("offset_z", offset))
	var span := t * 16
	# ON VISE LA PLACE, pas le centre de la boite englobante. Depuis que la forme
	# est organique, le village pousse ou il peut dans sa fenetre : viser le
	# milieu de la fenetre a photographie une foret de baobabs a cote du village.
	var types_shot: PackedByteArray = layout["types"]
	var square := _square_index(types_shot, t)
	@warning_ignore("integer_division")
	var mid_x := float(cell.x * 128 + (offset + square % t) * 16 + 8)
	@warning_ignore("integer_division")
	var mid_z := float(cell.y * 128 + (offset_z + square / t) * 16 + 8)
	@warning_ignore("integer_division")
	var plateau := float(_terrace_at(layout, square % t, square / t))
	# EN VOL, ENTREES VERROUILLEES. `FlyCamera` applique la GRAVITE : une
	# position posee de l exterieur est ecrasee des la frame suivante, et la
	# camera retombe au sol. La premiere version de cette capture a photographie
	# le nombril du joueur au niveau de la mer.
	camera.flying = true
	camera.input_locked = true
	# Le monde doit exister avant d etre photographie : on amene le joueur sur
	# place et on laisse le streaming faire son travail.
	camera.position = Vector3(mid_x, plateau + 40.0, mid_z)
	await _settle()

	camera.position = Vector3(mid_x, plateau + float(span), mid_z + 1.0)
	camera.look_at(Vector3(mid_x, plateau, mid_z), Vector3.UP)
	await _settle()
	await screenshot("village_plan.png")

	camera.position = Vector3(mid_x - float(span) * 0.8, plateau + 22.0,
			mid_z - float(span) * 0.8)
	camera.look_at(Vector3(mid_x, plateau + 4.0, mid_z), Vector3.UP)
	await _settle()
	await screenshot("village_silhouette.png")

	camera.position = Vector3(mid_x, plateau + 2.0, mid_z - float(span) * 0.45)
	camera.look_at(Vector3(mid_x, plateau + 2.0, mid_z), Vector3.UP)
	await _settle()
	await screenshot("village_rue.png")


func _settle() -> void:
	# Le streaming a besoin de temps : a 266 chunks en file, deux secondes ne
	# suffisent pas et l on photographie un village a moitie charge.
	await main.get_tree().create_timer(6.0).timeout
	for _i in 30:
		await main.get_tree().process_frame


## Palier de la tuile (tx, tz), ou le plateau global pour un layout d avant les
## terrasses.
func _terrace_at(layout: Dictionary, tx: int, tz: int) -> int:
	var terraces: PackedInt32Array = layout.get("terraces", PackedInt32Array())
	var idx := tz * int(layout["T"]) + tx
	if idx < 0 or idx >= terraces.size():
		return int(layout["plateau_y"])
	return terraces[idx]


## Hauteur REELLE des murs d un batiment : on monte le long d un angle tant que
## la poutre de chainage est la. La fiche d archetype ne donne plus qu une base
## depuis que les hauteurs varient, et supposer la hauteur ferait chercher le
## toit au mauvais endroit — donc conclure « pas de toit en pente » sur un
## batiment qui en a un.
func _measured_wall_height(g: Object, layout: Dictionary, tx: int, tz: int, margin: int) -> int:
	var cell: Vector2i = layout["cell"]
	var offset: int = layout["offset"]
	var offset_z: int = layout.get("offset_z", offset)
	var base_x := cell.x * 128 + (offset + tx) * 16
	var base_z := cell.y * 128 + (offset_z + tz) * 16
	var terrace := _terrace_at(layout, tx, tz)
	var height := 0
	for y in range(1, CityGenerator.MAX_BUILD_HEIGHT + 4):
		if g.block_at(base_x + margin, terrace + y, base_z + margin) == 0:
			break
		height = y
	return maxi(height - 1, 3)


## Index de la PLACE, ou du centre a defaut. Une sonde qui echantillonne en dur
## le coin de la boite englobante ne mesure plus rien depuis que le village a
## une forme.
func _square_index(types: PackedByteArray, t: int) -> int:
	for idx in types.size():
		if types[idx] == CityGenerator.Tile.PLACE:
			return idx
	@warning_ignore("integer_division")
	return (t / 2) * t + t / 2

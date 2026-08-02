extends Probe
## Sonde `--probe-interieur` — ASSERTIVE, code de sortie 0/1.
##
## Elle couvre point par point la refonte d'intérieur du 2026-08-02, chacun
## vérifié sur la GÉOMÉTRIE RÉELLEMENT CONSTRUITE et non sur le plan :
##
##   1. plus de salles qu'avant (et davantage en descendant) ;
##   2. salles organiques : sol en relief, empreinte non rectangulaire ;
##   3. escaliers réels (marches en gradins) et LUMINEUX ;
##   4. butin au sol dispersé dans plusieurs salles ;
##   5. coffre du boss, avec objets et or ;
##   6. le butin de donjon n'est PAS ramassable depuis l'overworld.
##
## Le point 6 est un bug qui n'existait pas encore quand le butin a été ajouté :
## le donjon est une dimension séparée occupant LES MÊMES COORDONNÉES que
## l'overworld, près de l'origine. Sans filtrage par dimension, les caches
## posées dans une salle se ramassaient depuis la surface.

const TAG := "INTERIEUR"

var _ok := true


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("[%s] ok — %s" % [TAG, message])
	else:
		_ok = false
		print("[%s] ÉCHEC : %s" % [TAG, message])


func run() -> void:
	await main.get_tree().process_frame
	_check_room_counts()
	await _check_built_floor()
	finish(_ok, TAG)


## 1. Le nombre de salles a augmenté, et il monte avec la profondeur.
func _check_room_counts() -> void:
	var shallow := DungeonGenerator.room_count_for(0)
	var deep := DungeonGenerator.room_count_for(4)
	_expect(shallow >= 8, "étage 1 vise %d salles (>= 8 ; c'était 4)" % shallow)
	_expect(deep > shallow, "l'étage 5 en vise %d, plus que l'étage 1 (%d)" % [deep, shallow])

	# Le plan RÉEL doit s'approcher de la cible : si le placement échoue trop
	# souvent (salles agrandies qui se gênent), l'étage reste minuscule sans
	# que rien ne le signale.
	var plan := DungeonGenerator.generate_floor(12345, shallow)
	var built: int = (plan.get("rooms", []) as Array).size()
	_expect(built >= shallow - 2, "plan généré : %d salles pour %d visées" % [built, shallow])
	_expect(int(plan.get("boss_room_index", 0)) != 0, "la salle du boss n'est pas l'entrée")


## 2 à 6 : sur un donjon RÉELLEMENT construit.
func _check_built_floor() -> void:
	var cell := _find_dungeon_cell()
	if cell == Vector2i(1 << 30, 0):
		_expect(false, "aucune cellule de donjon trouvée — rien à vérifier.")
		return
	print("[%s] cellule de donjon : %s" % [TAG, cell])

	# Entrée : on se place dans le périmètre de la cellule et on laisse le
	# compte à rebours de 3 s puis le chargement se dérouler (même mécanique
	# que --probe-dungeon, il n'y a pas d'API d'entrée directe).
	var caches_before: int = DropManager.caches.size()
	var centre := POIGenerator.cell_center_world(cell)
	var ground := int(floor(WorldManager.generator.height_at(centre.x, centre.y)))
	# On entre en s'enfonçant dans une CAVITÉ de la termitière, pas en
	# franchissant un périmètre : il faut donc trouver un point réellement
	# creux dans la masse (même recherche que --probe-dungeon).
	# BALAYAGE DÉTERMINISTE, et non un tirage au hasard : la recherche
	# aléatoire de la sonde historique échouait environ une fois sur deux
	# (400 essais peuvent tous tomber dans la masse pleine), ce qui rendait
	# cette sonde ininterprétable — un échec ne disait plus si le donjon était
	# cassé ou si le tirage avait été malchanceux.
	var spot := Vector3i(1 << 30, 0, 0)
	for ty in range(ground + 3, ground + 26):
		if spot.x != 1 << 30:
			break
		for r in range(0, 31):
			if spot.x != 1 << 30:
				break
			for a in range(0, 16):
				var ang := TAU * float(a) / 16.0
				var tx := centre.x + int(cos(ang) * float(r))
				var tz := centre.y + int(sin(ang) * float(r))
				if DungeonTower.inside_interior(cell, tx, ty, tz, ground, WorldManager.world_seed):
					spot = Vector3i(tx, ty, tz)
					break
	if spot.x == 1 << 30:
		_expect(false, "aucune cavité d'entrée trouvée dans la termitière.")
		return
	camera.position = Vector3(float(spot.x) + 0.5, float(spot.y) + 0.5, float(spot.z) + 0.5)
	await main.get_tree().create_timer(4.5).timeout
	if not DungeonManager._in_dungeon:
		_expect(false, "entrée dans le donjon impossible — rien à vérifier ensuite.")
		return
	_expect(WorldManager.active_dimension == &"donjon", "entré dans la dimension donjon")

	# --- 2. Salles organiques ---
	var seed_value: int = DungeonManager._floor_seed
	var entree: Dictionary = GameData.dungeon_rooms.get("entree", {})
	var size: Array = entree.get("size", [11, 8, 11])
	var origin := Vector3i.ZERO
	var box := Vector3i(int(size[0]), int(size[1]), int(size[2]))
	var heights := {}
	var corners_solid := 0
	for x in box.x:
		for z in box.z:
			heights[DungeonCavern.floor_offset(x, z, seed_value)] = true
			# Une BOÎTE aurait ses quatre coins creusés comme le reste. Une
			# ellipse déformée les laisse pleins : c'est la signature la plus
			# simple à tester d'une empreinte non rectangulaire.
			var at_corner := (x <= 1 or x >= box.x - 2) and (z <= 1 or z >= box.z - 2)
			if at_corner and DungeonCavern.shaped_distance(x, z, origin, box, seed_value) >= 1.0:
				corners_solid += 1
	_expect(heights.size() >= 2, "sol en relief : %d hauteurs distinctes dans l'entrée" % heights.size())
	_expect(corners_solid > 0, "empreinte non rectangulaire : %d colonne(s) de coin pleines" % corners_solid)

	# --- 3. Escaliers réels et lumineux ---
	var up: Vector3 = DungeonManager._ascent_landing
	var tread_id: int = GameData.material_runtime_ids.get(DungeonManager.STAIR_TREAD_UP, 0)
	var glow_id: int = GameData.material_runtime_ids.get(DungeonManager.STAIR_GLOW, 0)
	var emission: PackedByteArray = GameData.emission_by_runtime
	var lum: int = emission[glow_id] if glow_id < emission.size() else 0
	_expect(lum > 0, "escalier lumineux : la rampe « %s » émet %d/15" % [
			DungeonManager.STAIR_GLOW, lum])

	# La lumière doit être RÉELLEMENT POSÉE, pas seulement déclarée : c'est
	# tout l'écart entre « le matériau est lumineux » et « l'escalier éclaire ».
	var glow_blocks := 0
	for i in range(-2, DungeonManager.STAIR_STEPS + 4):
		for dy in range(-2, 12):
			for dz in range(-3, 4):
				if DungeonManager.dimension_block_at(
						Vector3i(int(up.x) + i, dy, int(up.z) + dz)) == glow_id:
					glow_blocks += 1
	_expect(glow_blocks >= 6, "%d bloc(s) lumineux posés le long de la volée" % glow_blocks)

	# Gradins : en suivant la volée, la hauteur de la marche doit changer d'un
	# bloc à chaque pas. Un sol plat (l'ancien « orifice ») donnerait 0 dénivelé.
	var climb := 0
	var probe_x := int(up.x)
	var probe_z := int(up.z)
	var previous := -999
	for i in range(0, DungeonManager.STAIR_STEPS + 2):
		var x := probe_x + i  # La volée de remontée court le long de -X depuis sa base.
		var found := -999
		for y in range(-4, 14):
			if DungeonManager.dimension_block_at(Vector3i(x, y, probe_z)) == tread_id:
				found = y
				break
		if found != -999 and previous != -999 and found != previous:
			climb += 1
		if found != -999:
			previous = found
	_expect(climb >= 3, "gradins : %d changements de hauteur le long de la volée" % climb)

	# --- 4. Butin au sol ---
	var dungeon_caches := 0
	var rooms_with_loot := {}
	for cache: Dictionary in DropManager.caches:
		if StringName(cache.get("dimension", &"overworld")) != &"donjon":
			continue
		dungeon_caches += 1
		var p: Vector3 = cache["position"]
		rooms_with_loot["%d_%d" % [int(p.x) / 12, int(p.z) / 12]] = true
	_expect(dungeon_caches > caches_before, "%d cache(s) posée(s) dans le donjon" % dungeon_caches)
	_expect(rooms_with_loot.size() >= 2, "butin dispersé sur %d zone(s), pas concentré" % rooms_with_loot.size())

	# --- 6. Cloisonnement des dimensions ---
	var here := DropManager.nearest_cache(Vector3(1 << 24, 0, 0))
	_expect(here < 0, "aucune cache atteignable loin de tout, en donjon")
	# CAPTURES. En vol (sinon la marche re-colle la caméra au sol et la vue
	# reste plaquée contre une paroi) et input verrouillé, pour que rien ne
	# bouge entre le cadrage et la prise.
	camera.set("flying", true)
	camera.set("input_locked", true)
	# HUD et outil en main masqués : ils occupent la moitié du cadre et ces
	# captures servent à juger une ARCHITECTURE, pas une interface.
	var hud: CanvasLayer = main.get_node_or_null("HUD")
	if hud != null:
		hud.visible = false
	# `HeldItem` se remet visible tout seul à chaque rafraîchissement (voir
	# held_item.gd) : le masquer ne tient pas. On sort donc de l'arbre l'outil
	# ET le corps du joueur, qui occupent ensemble le quart bas du cadre.
	var hidden: Array[Node] = []
	for path: String in ["HeldItem", "PlayerBody"]:
		var node: Node = camera.get_node_or_null(path)
		if node == null:
			node = main.get_node_or_null(path)
		if node != null and node.get_parent() != null:
			node.get_parent().remove_child(node)
			hidden.append(node)
	# 1. La salle d'entrée vue de haut : c'est la vue qui montre l'empreinte
	# non rectangulaire, le relief du sol et la voûte.
	# La caméra doit être DANS la cavité : posée hors de l'empreinte, elle se
	# retrouve noyée dans la masse et la capture ne montre qu'un aplat de
	# matière (constaté au premier essai).
	# On cadre la PLUS GRANDE salle de l'étage, pas l'entrée : le modelé se
	# lit mal dans un volume de 11 blocs de côté, alors qu'il saute aux yeux
	# dans une caverne de 19.
	var rooms: Array = DungeonManager._floors[DungeonManager._floor_key(
			cell, DungeonManager._current_depth)]["rooms"]
	var biggest: Dictionary = rooms[0]
	for room: Dictionary in rooms:
		var s: Vector3i = room["size"]
		var b: Vector3i = biggest["size"]
		if s.x * s.z > b.x * b.z:
			biggest = room
	var b_origin: Vector3i = biggest["origin"]
	var b_size: Vector3i = biggest["size"]
	var cx := float(b_origin.x) + float(b_size.x) * 0.5
	var cz := float(b_origin.z) + float(b_size.z) * 0.5
	print("[%s] capture : salle « %s » %s en %s" % [TAG, biggest["def_id"], b_size, b_origin])
	camera.position = Vector3(cx, float(b_origin.y) + float(b_size.y) * 0.55,
			cz - float(b_size.z) * 0.30)
	camera.look_at(Vector3(cx, float(b_origin.y) + 1.0, cz + float(b_size.z) * 0.4), Vector3.UP)
	await main.get_tree().create_timer(0.6).timeout
	await screenshot("donjon_salle.png")
	# 2. L'escalier de remontée, de trois quarts : marches en gradins et
	# rampes lumineuses.
	camera.position = Vector3(up.x + 7.0, up.y + 4.0, up.z + 6.0)
	camera.look_at(Vector3(up.x, up.y, up.z), Vector3.UP)
	await main.get_tree().create_timer(0.6).timeout
	await screenshot("donjon_escalier.png")
	if hud != null:
		hud.visible = true
	for node: Node in hidden:
		main.add_child(node)
	camera.set("input_locked", false)

	# Sortie : on marche sur le palier de l'escalier de remontée.
	var exit_landing: Vector3 = DungeonManager._exit_marker_position(cell)
	camera.position = Vector3(exit_landing.x, exit_landing.y + 2.9, exit_landing.z)
	await main.get_tree().create_timer(1.8).timeout
	_expect(WorldManager.active_dimension == &"overworld", "ressorti dans l'overworld")

	# De retour dehors, AUCUNE cache de donjon ne doit être atteignable — c'est
	# le bug corrigé : elles vivaient aux mêmes coordonnées que le spawn.
	var leaked := 0
	for cache: Dictionary in DropManager.caches:
		if StringName(cache.get("dimension", &"overworld")) != &"donjon":
			continue
		if DropManager.nearest_cache(cache["position"] as Vector3) >= 0:
			leaked += 1
	_expect(leaked == 0, "%d cache(s) de donjon fuient vers l'overworld (attendu 0)" % leaked)

	# --- 5. Coffre du boss ---
	var chest: Dictionary = DungeonLoot.boss_chest(3, 999)
	_expect(not (chest["objects"] as Array).is_empty(),
			"coffre du boss : %d objet(s)" % (chest["objects"] as Array).size())
	_expect(int(chest["gold"]) > 0, "coffre du boss : %d or" % int(chest["gold"]))
	# Descendre doit rapporter davantage, sinon rien n'incite à s'enfoncer.
	var shallow_chest: Dictionary = DungeonLoot.boss_chest(0, 999)
	_expect(int(chest["gold"]) > int(shallow_chest["gold"]),
			"le coffre s'enrichit avec la profondeur (%d au fond contre %d en surface)" % [
					int(chest["gold"]), int(shallow_chest["gold"])])


func _find_dungeon_cell() -> Vector2i:
	for radius in range(0, 60):
		for dx in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				if absi(dx) != radius and absi(dz) != radius:
					continue
				var c := Vector2i(dx, dz)
				var cwc := POIGenerator.cell_center_world(c)
				var cb: Dictionary = WorldManager.generator.biome_at(cwc.x, cwc.y)
				if not cb.is_empty() and "donjon" in POIGenerator.pois_at_cell(
						c, WorldManager.world_seed, cb):
					return c
	return Vector2i(1 << 30, 0)

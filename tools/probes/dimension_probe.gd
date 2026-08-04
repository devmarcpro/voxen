extends Probe
## Sonde `--probe-dimensions` (2026-08-03) — le système de dimensions.
##
## CE QU'ELLE DÉFEND. Avant cette passe, WorldManager disait « si la dimension
## active n'est pas l'overworld, appeler DungeonManager » : autrement dit,
## « pas l'overworld » signifiait « donjon ». Le système paraissait générique
## et ne l'était pas, et rien ne l'aurait signalé — tant qu'il n'existe qu'une
## seule dimension, une vraie abstraction et un renommage se comportent
## exactement pareil.
##
## La sonde vérifie donc les deux choses qu'une seule dimension ne peut pas
## prouver : que DEUX dimensions coexistent sans se mélanger, et qu'une
## dimension SANS code dédié fonctionne — c'est le seul test qui distingue une
## abstraction d'un cas particulier renommé.

const TAG := "DIMENSIONS"

var _ok := true


func _expect(condition: bool, message: String) -> void:
	print("[%s] %s — %s" % [TAG, "ok" if condition else "ÉCHEC", message])
	if not condition:
		_ok = false


func run() -> void:
	await wait_frame()
	_check_registry()
	await _check_generic_dimension()
	await _check_isolation()
	await _check_dungeon_is_local()
	finish(_ok, TAG)


## L'INTÉRIEUR DE DONJON VIT EN COORDONNÉES LOCALES, dans sa propre dimension.
##
## Le GDD a longtemps porté un « écart technique temporaire » : l'intérieur
## était placé dans une poche compacte éloignée, vers x/z ≈ 20 000, parce qu'un
## placement naïf à `cellule × N` faisait trembler la caméra — la précision
## d'un float32 s'effondre vers 4 000 000. Deux issues étaient envisagées, et
## c'est la seconde qui a été retenue : une vraie dimension séparée.
##
## On le VERROUILLE ici. Sans assertion, rien n'empêcherait un futur étage
## d'être posé aux coordonnées de sa cellule dans le monde — le jeu marcherait,
## et le tremblement reviendrait à des milliers de blocs de l'origine, là où
## personne ne le teste.
func _check_dungeon_is_local() -> void:
	var cell := Vector2i.ZERO
	var found := false
	for radius in range(0, 40):
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if maxi(absi(dx), absi(dz)) != radius:
					continue
				if DungeonManager.is_dungeon_cell(Vector2i(dx, dz)):
					cell = Vector2i(dx, dz)
					found = true
					break
			if found:
				break
		if found:
			break
	if not found:
		print("[%s] aucun donjon alentour pour l'essai." % TAG)
		return

	# L'ENTRÉE N'EST PAS IMMÉDIATE : elle passe par un écran de chargement et
	# une téléportation différée. Mesurer à la frame suivante donnait la
	# position OVERWORLD du joueur, et la sonde concluait à tort que la bascule
	# n'avait pas eu lieu.
	DungeonManager.enter_from_map(cell)
	for i in 120:
		await wait_frame()
		if WorldManager.active_dimension == &"donjon":
			break
	_expect(WorldManager.active_dimension == &"donjon",
			"on est bien dans la dimension donjon, pas dans l'overworld")
	if WorldManager.active_dimension != &"donjon":
		return

	var here: Vector3 = player.get_position_for_ai()
	print("[%s] cellule %s (soit %d blocs de l'origine) → intérieur en %s" % [
			TAG, cell, absi(cell.x) * ClaimManager.CELL_SIZE, str(here.round())])
	# LA CELLULE EST LOIN, L'INTÉRIEUR EST PRÈS : c'est toute la démonstration.
	# Si l'étage suivait les coordonnées de sa cellule, `here` serait à des
	# milliers de blocs, et une poche compacte le mettrait vers 20 000.
	_expect(absf(here.x) < 512.0 and absf(here.z) < 512.0,
			"l'étage est en coordonnées LOCALES (|x|,|z| < 512), pas à celles de sa cellule")
	DungeonManager.leave()
	await wait_frame()


## Le registre est peuplé, et le donjon y figure AVEC son backend : c'est ce
## qui l'a fait passer de cas du moteur à contenu.
func _check_registry() -> void:
	print("[%s] %d dimension(s) déclarée(s) : %s" % [
			TAG, GameData.dimensions.size(), GameData.dimensions.keys()])
	_expect(GameData.dimensions.size() >= 2,
			"le registre en contient au moins deux (une seule ne prouve rien)")
	_expect(GameData.dimensions.has("donjon"), "le donjon est déclaré en données")
	var dungeon: Dictionary = GameData.dimensions.get("donjon", {})
	_expect(String(dungeon.get("backend", "")) == "DungeonManager",
			"le donjon déclare son backend au lieu d'être câblé dans le moteur")


## UNE DIMENSION SANS BACKEND DOIT MARCHER. C'est l'assertion centrale : la
## faille de mana n'a pas une ligne de code dans WorldManager ni dans
## DimensionManager qui la nomme.
func _check_generic_dimension() -> void:
	var rift := &"faille_de_mana"
	var declaration: Dictionary = GameData.dimensions.get(String(rift), {})
	_expect(not declaration.is_empty(), "la faille de mana est déclarée")
	_expect(not declaration.has("backend"),
			"elle n'a AUCUN backend — c'est le stockage générique qui la tient")
	if declaration.is_empty():
		return

	var before: Vector3 = player.get_position_for_ai()
	var entered := DimensionManager.enter(rift, before, Vector3.ZERO)
	_expect(entered, "on entre dans la faille")
	if not entered:
		return
	await wait_frame()

	_expect(DimensionManager.active == rift, "la dimension active est bien la faille")
	_expect(WorldManager.active_dimension == rift,
			"WorldManager suit la bascule (sinon les blocs seraient lus dans l'overworld)")
	var chunks := DimensionManager.chunk_count(rift)
	print("[%s] la faille contient %d chunk(s)" % [TAG, chunks])
	_expect(chunks > 0, "la faille a été construite à l'entrée")

	# ON LIT UN BLOC PAR LE CHEMIN NORMAL. Si l'aiguillage était resté câblé sur
	# le donjon, cette lecture rendrait 0 : DungeonManager n'a rien à cet
	# endroit, et le défaut serait invisible autrement.
	# ON SONDE AUTOUR DU JOUEUR, pas autour de l'origine. Le terrain de la
	# faille est devenu CONTINU le 2026-08-04 et son sol vit vers y = 64 ; la
	# sonde cherchait encore des blocs à hauteur d'îlot flottant, près de zéro,
	# et concluait que la dimension était vide.
	var here: Vector3 = player.get_position_for_ai()
	var solid := 0
	for dy in range(-24, 13):
		for dx in range(-14, 15):
			if WorldManager.block_at_world(Vector3i(roundi(here.x) + dx,
					roundi(here.y) + dy, roundi(here.z))) != 0:
				solid += 1
	print("[%s] %d bloc(s) plein(s) lus au centre de la faille" % [TAG, solid])
	_expect(solid > 0, "les blocs de la faille se lisent par WorldManager.block_at_world")

	# UNE PHOTO, parce qu'une dimension sans ciel ni soleil est le genre
	# d'endroit qui peut être parfaitement correct côté blocs et parfaitement
	# noir à l'écran — aucune assertion ne le dirait.
	if can_capture():
		camera.input_locked = true
		player.input_locked = true
		camera.position = Vector3(26.0, 14.0, 26.0)
		camera.look_at(Vector3(0.0, 0.0, 0.0), Vector3.UP)
		await wait_seconds(1.2)
		await screenshot("faille_de_mana.png")
		print("[%s] capture : faille_de_mana.png" % TAG)

	# LA FAILLE EST-ELLE UN LIEU, ou seulement un décor ? Une dimension sans
	# rien à rencontrer ni rien à ramasser ne se visite qu'une fois, et tout le
	# travail d'architecture qui l'a rendue possible ne sert alors à rien.
	var residents := 0
	for creature in CreatureManager.creatures:
		if creature != null and is_instance_valid(creature) and creature.dimension == rift:
			residents += 1
	# ON COMPTE LES CACHES DU REGISTRE, pas celles à portée de main.
	# `nearest_cache` ne voit que dans le rayon de RAMASSAGE : balayer une ligne
	# avec elle ne prouvait rien, et faisait échouer la sonde alors que les
	# caches existaient bel et bien.
	var caches := 0
	for cache: Dictionary in DropManager.caches:
		if StringName(cache.get("dimension", &"overworld")) == rift:
			caches += 1
	print("[%s] la faille contient %d habitant(s) et %d cache(s) de butin" % [
			TAG, residents, caches])
	_expect(residents > 0, "on y rencontre quelqu'un")
	_expect(caches > 0, "on y trouve quelque chose à ramasser")

	# LE MONDE S'ÉTEND QUAND ON MARCHE.
	#
	# La dimension était PRÉ-BÂTIE en entier à l'entrée : elle était donc bornée
	# par ce qu'on acceptait d'attendre en y entrant — « une case dans le vide »
	# plutôt qu'un monde. Le terrain est maintenant interrogeable colonne par
	# colonne, et généré à la demande autour du joueur.
	#
	# On le VÉRIFIE en marchant : sans cette assertion, un streaming débranché
	# ne se verrait qu'en jouant, au moment de tomber du bord du monde.
	var chunks_before := DimensionManager.chunk_count(rift)
	var walk: Vector3 = player.get_position_for_ai() + Vector3(90.0, 0.0, 90.0)
	player.teleport_to(walk)
	for i in 40:
		await wait_frame()
	var chunks_after := DimensionManager.chunk_count(rift)
	print("[%s] après 90 blocs de marche : %d chunks → %d" % [
			TAG, chunks_before, chunks_after])
	_expect(chunks_after > chunks_before,
			"le monde se génère à la demande au lieu d'être borné")

	# CHAQUE DIMENSION N'EMPLOIE QUE SES PROPRES BLOCS (demande de l'auteur,
	# 2026-08-04 : « sinon on va pas s'en sortir »).
	#
	# Les données sont désormais rangées par dimension — `data/materials/magique/`
	# et `data/trees/magique/` — mais un rangement n'est qu'une intention tant
	# que rien ne le vérifie. Il suffirait qu'une zone de la faille cite
	# `pierre` ou qu'une essence de rêve pousse en forêt tempérée pour que la
	# séparation se défasse, sans que rien ne le signale : le jeu tournerait,
	# et les deux mondes se mélangeraient bloc par bloc.
	var magic_mats := {}
	for material_id: String in GameData.materials:
		var path := String((GameData.materials[material_id] as Dictionary).get("_source", ""))
		if "magique" in path:
			magic_mats[material_id] = true
	var declared: Array[String] = []
	for zone: Dictionary in (declaration.get("zones", []) as Array):
		for key: String in ["sol", "roche", "accent"]:
			var used := String(zone.get(key, ""))
			if used != "" and not magic_mats.has(used) and not magic_mats.is_empty():
				declared.append("%s.%s=%s" % [zone.get("id", "?"), key, used])
	print("[%s] %d matériau(x) propres à la dimension magique" % [TAG, magic_mats.size()])
	_expect(declared.is_empty(),
			"la faille n'emploie que des blocs de sa dimension%s" % [
					"" if declared.is_empty() else " — intrus : " + ", ".join(declared)])

	# MUTER AUSSI : une dimension où l'on ne peut rien casser n'est qu'un décor.
	var target := Vector3i.ZERO
	var found := false
	for dy in range(12, -30, -1):
		var probe_pos := Vector3i(roundi(here.x), roundi(here.y) + dy, roundi(here.z))
		if WorldManager.block_at_world(probe_pos) != 0:
			target = probe_pos
			found = true
			break
	if found:
		var removed := WorldManager.set_block(target, 0)
		_expect(removed and WorldManager.block_at_world(target) == 0,
				"un bloc de la faille se mine par le chemin normal")


## LES DIMENSIONS NE SE MÉLANGENT PAS. Le même Vector3i désigne un bloc
## différent de chaque côté : c'est la propriété que le partage des coordonnées
## rend fragile, et celle qui casserait en silence.
func _check_isolation() -> void:
	var rift := &"faille_de_mana"
	var probe_pos := Vector3i(3, 40, 3)
	var stone: int = GameData.material_runtime_ids.get("pierre", 1)

	# Un bloc témoin posé DANS la faille.
	DimensionManager.set_block_in(rift, probe_pos, stone, false)
	_expect(WorldManager.block_at_world(probe_pos) == stone,
			"le témoin est visible depuis la faille")

	# On sort, et il ne doit plus être là : l'overworld a ses propres blocs à
	# ces coordonnées.
	DimensionManager.leave()
	await wait_frame()
	_expect(DimensionManager.active == DimensionManager.OVERWORLD,
			"on revient bien dans l'overworld")
	_expect(WorldManager.block_at_world(probe_pos) != stone
			or WorldManager.generator == null,
			"le témoin de la faille n'existe PAS dans l'overworld")
	_expect(DimensionManager.chunk_count(rift) == 0,
			"la faille est libérée en sortant (elle se regénère à la prochaine visite)")

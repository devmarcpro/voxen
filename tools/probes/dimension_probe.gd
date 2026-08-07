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
	# LE TERRAIN ARRIVE PAR LE STREAMING, plus par une construction à l'entrée.
	# C'est tout l'objet de l'unification : on ne bâtit plus la dimension, on la
	# streame comme l'overworld. Il faut donc LAISSER PASSER DES FRAMES avant de
	# compter — mesurer à la frame suivante ne dirait que « l'asynchrone est
	# asynchrone », et l'assertion échouerait sur un système qui marche.
	var chunks := 0
	for i in 90:
		await wait_frame()
		chunks = DimensionManager.chunk_count(rift)
		if chunks > 0:
			break
	print("[%s] la faille contient %d chunk(s) après %d frame(s)" % [TAG, chunks, 90])
	_expect(chunks > 0, "la faille se streame autour du joueur dès l'arrivée")

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
		# CADRAGE RELATIF AU JOUEUR, jamais à l'origine. Le sol de la faille est
		# passé de y≈0 (îlots) à y≈64 (terrain continu) : une caméra posée en
		# dur à hauteur d'îlot photographiait le vide sous le monde, et donnait
		# à croire que la dimension était vide alors que la sonde venait d'y
		# compter des centaines de blocs.
		var eye: Vector3 = player.get_position_for_ai()
		camera.position = eye + Vector3(34.0, 26.0, 34.0)
		camera.look_at(eye + Vector3(0.0, -6.0, 0.0), Vector3.UP)
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

	# LE GÉNÉRATEUR DE LA DIMENSION EST CELUI DE L'OVERWORLD (2026-08-04).
	#
	# C'est l'assertion qui défend l'unification elle-même. Il a existé un SECOND
	# pipeline (`RiftBuilder` + `DimensionManager._build_column`) écrivant les
	# blocs un par un dans le fil principal ; il a été supprimé. Si un jour
	# quelqu'un en réintroduit un, cette ligne le dira : la dimension active doit
	# être servie par un `NoiseGenerator` — le même type que l'overworld — et il
	# doit savoir dans quelle dimension il est.
	var generator: NoiseGenerator = WorldManager.generator
	_expect(generator != null and generator.dimension == rift,
			"la faille est générée par un NoiseGenerator qui se sait dans la faille")
	if generator == null:
		return

	# LES ÎLES SUSPENDUES EXISTENT, et elles sont DÉTERMINISTES.
	#
	# Le semis est calculé depuis la colonne et la graine, jamais tiré : c'est
	# ce qui permet à une colonne évincée puis regénérée de retrouver la MÊME
	# île. Sans ça, revenir sur ses pas ferait pousser une seconde île à côté de
	# la première — un défaut qu'on ne voit qu'en marchant longtemps.
	var isles := 0
	var first := {}
	var first_col := Vector2i.ZERO
	for cx in range(-14, 15):
		for cz in range(-14, 15):
			var island := generator.sky_island_at(Vector2i(cx, cz))
			if not island.is_empty():
				isles += 1
				if first.is_empty():
					first = island
					first_col = Vector2i(cx, cz)
	print("[%s] %d île(s) suspendue(s) sur 841 colonnes" % [TAG, isles])
	_expect(isles > 20, "le ciel en porte assez pour qu'on en croise")

	# LES ARBRES SUSPENDUS AUX PLAFONDS DE CAVERNE (croquis de l'auteur).
	# Ils sont posés en MIROIR d'un arbre normal autour de leur point
	# d'accroche — pas par un second générateur, qui aurait doublé la
	# maintenance des 57 essences pour un résultat identique. On vérifie que le
	# semis existe et qu'il est déterministe : sans ça, une caverne évincée puis
	# regénérée verrait pousser un second arbre à côté du premier.
	var hung := 0
	for hx in range(-15, 16):
		for hz in range(-15, 16):
			if generator.hung_species_at(hx, hz) != "":
				hung += 1
	print("[%s] %d point(s) d'accroche d'arbre suspendu sur 961 cellules" % [TAG, hung])
	_expect(hung > 10, "les cavernes portent des arbres à l'envers")

	# LE COÛT D'UNE COLONNE, ET LE BUDGET DE FRAME. C'EST LE CRITÈRE.
	#
	# ---------------------------------------------------------------------
	# CE QUE CE CHRONOMÈTRE MESURE, ET POURQUOI IL A CHANGÉ DE POINT D'APPUI
	# ---------------------------------------------------------------------
	# Il chronométrait `DimensionManager._build_column`, qui écrivait les blocs
	# UN PAR UN DANS LE FIL PRINCIPAL, une colonne par frame : 738 ms mesurés,
	# et 50 ms était alors le bon seuil, puisque chaque milliseconde tombait
	# dans une frame.
	#
	# Cette fonction n'existe plus. La génération d'une dimension passe
	# désormais par le pipeline de l'overworld : WorkerThreadPool, six colonnes
	# en vol, deux meshes installés par frame. Le temps d'une colonne ne tombe
	# donc PLUS dans une frame, et un seuil de 50 ms appliqué à ce temps ne
	# mesurerait plus ce qu'il prétend — l'overworld lui-même ne l'a jamais
	# tenu : une colonne BOISÉE d'overworld coûte ~650 ms à froid.
	#
	# On garde donc deux assertions, et aucune n'est plus tendre que l'ancienne :
	#
	#   1. PARITÉ. Une colonne de dimension ne doit pas coûter sensiblement plus
	#      qu'une colonne d'overworld équivalente. C'est LA propriété que
	#      l'unification devait produire, et elle ne se contourne pas en
	#      bricolant un seuil : le témoin bouge avec la machine.
	#
	#   2. BUDGET DE FRAME, mesuré sur la frame. C'est ce que l'auteur a
	#      constaté en jouant — « le jeu rame franchement » — et c'est donc là
	#      qu'il faut regarder. Le seuil reste 50 ms, le nombre d'origine.
	#
	# DEUX PIÈGES DE MESURE se sont refermés avant d'obtenir ces chiffres, et
	# ils valent d'être écrits ici : (a) le premier témoin d'overworld tombait
	# en plein OCÉAN et ne générait aucun arbre — il comparait une forêt à de
	# l'eau ; (b) le repérage des colonnes boisées RÉCHAUFFAIT le cache d'arbres
	# du générateur qui servait ensuite à chronométrer, si bien que le témoin
	# mesurait un cache et la faille une génération. On repère donc avec un
	# générateur ÉCLAIREUR et on chronomètre avec un générateur NEUF, des deux
	# côtés.
	var scout := NoiseGenerator.new(WorldManager.world_seed, {}, &"overworld")
	var wooded: Array[Vector2i] = []
	for i in 400:
		var c := Vector2i(200 + i * 23, -60 + i * 41)
		# SEUIL BAISSÉ À DOUZE (2026-08-04). `_trees_in_window` écarte désormais
		# les essences trop étroites pour atteindre la colonne : le tableau rendu
		# est plus court à densité de forêt ÉGALE, et le seuil de vingt ne
		# trouvait plus que deux colonnes sur quatre cents — une médiane sur deux
		# échantillons ne vaut pas grand-chose.
		if (scout.prepare_context(c)["trees"] as Array).size() >= 12:
			wooded.append(c)
			if wooded.size() == 5:
				break
	var ow_fresh := NoiseGenerator.new(WorldManager.world_seed, {}, &"overworld")
	var ow_samples := _time_columns(ow_fresh, wooded)
	var ow_median := ow_samples[ow_samples.size() / 2] if not ow_samples.is_empty() else 0.0
	print("[%s] témoin : colonne d'overworld BOISÉE à froid, médiane %.1f ms (%d colonnes)" % [
			TAG, ow_median, ow_samples.size()])

	var cold: Array[Vector2i] = []
	for i in 5:
		cold.append(Vector2i(500 + i * 9, -500 - i * 7))
	var fresh := NoiseGenerator.new(WorldManager.world_seed, {}, rift)
	var samples := _time_columns(fresh, cold)
	var median := samples[samples.size() / 2]
	print("[%s] génération d'une colonne de faille : médiane %.1f ms (min %.1f, max %.1f)" % [
			TAG, median, samples[0], samples[samples.size() - 1]])
	if ow_median > 0.0:
		print("[%s]   soit %.2f fois le témoin d'overworld" % [TAG, median / ow_median])
		_expect(median <= ow_median * 1.6,
				"la faille se génère au prix de l'overworld (%.2f×, plafond 1,60×)"
						% (median / ow_median))
	_expect(generator.hung_species_at(3, -2) == generator.hung_species_at(3, -2),
			"le même point redonne la même essence suspendue")
	if not first.is_empty():
		_expect(str(generator.sky_island_at(first_col)) == str(first),
				"la même colonne redonne exactement la même île")

	# LE BUDGET DE FRAME, MESURÉ SUR LA FRAME.
	#
	# On marche en terrain neuf, et on regarde ce que coûte chaque frame pendant
	# que la dimension se streame derrière. C'est exactement la situation où
	# l'auteur a vu le jeu ramer, et c'est la seule mesure qu'on ne peut pas
	# satisfaire en déplaçant du travail ailleurs : si le fil principal bloque,
	# elle le dit.
	var walk_from: Vector3 = player.get_position_for_ai()
	player.teleport_to(walk_from + Vector3(3000.0, 0.0, 3000.0))
	var worst := 0.0
	var frames := 0
	var last := Time.get_ticks_usec()
	for i in 240:
		await wait_frame()
		var now := Time.get_ticks_usec()
		var ms := float(now - last) / 1000.0
		last = now
		# Les toutes premières frames après une téléportation portent la bascule
		# elle-même (files vidées, centre reconstruit) : on regarde le RÉGIME
		# de streaming, pas l'à-coup du voyage.
		if i >= 10:
			worst = maxf(worst, ms)
			frames += 1
	print("[%s] streaming de la faille : pire frame %.1f ms sur %d frames" % [TAG, worst, frames])
	_expect(worst < 50.0,
			"la génération tient dans un budget de frame (pire frame %.1f ms)" % worst)
	player.teleport_to(walk_from)
	for i in 20:
		await wait_frame()

	# CE QUE LE JOUEUR A BÂTI SURVIT À L'ÉVICTION.
	#
	# Dans une dimension, le terrain généré et les blocs posés vivent dans le
	# MÊME magasin — l'overworld, lui, garde ses éditions dans un diff séparé.
	# Évincer sans distinction effacerait le travail du joueur, et il ne s'en
	# apercevrait qu'en revenant sur ses pas. C'est le genre de perte qu'aucune
	# erreur ne signale.
	var mark := Vector3i(roundi(here.x), roundi(here.y) + 6, roundi(here.z))
	var stone: int = GameData.material_runtime_ids.get("verre_songe", 1)
	WorldManager.set_block(mark, stone)
	_expect(WorldManager.block_at_world(mark) == stone, "on peut bâtir dans la faille")
	# On s'éloigne largement au-delà du rayon de conservation, puis on revient.
	player.teleport_to(Vector3(here.x + 400.0, here.y, here.z + 400.0))
	for i in 60:
		await wait_frame()
	player.teleport_to(here)
	for i in 20:
		await wait_frame()
	_expect(WorldManager.block_at_world(mark) == stone,
			"le bloc posé est toujours là après un aller-retour lointain")

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


## Chronomètre la génération de colonnes complètes : le contexte (relief,
## biomes, matériaux, features) PUIS chacun de leurs chunks. C'est le travail
## exact qu'une tâche de streaming exécute pour une colonne.
##
## LE MAILLAGE N'Y EST PAS, volontairement : il a son propre budget et sa propre
## sonde (`--probe-mesh`). Le compter ici mesurerait deux choses sous une seule
## étiquette — c'est déjà arrivé dans ce projet, et le chiffre avait envoyé
## l'optimisation sur le mauvais code.
func _time_columns(gen: NoiseGenerator, columns: Array[Vector2i]) -> Array[float]:
	var samples: Array[float] = []
	for col: Vector2i in columns:
		var start := Time.get_ticks_usec()
		var ctx := gen.prepare_context(col)
		var span := gen.cy_range(col)
		for cy in range(span.x, span.y + 1):
			gen.generate_chunk(Vector3i(col.x, cy, col.y), ctx)
		samples.append(float(Time.get_ticks_usec() - start) / 1000.0)
	samples.sort()
	return samples

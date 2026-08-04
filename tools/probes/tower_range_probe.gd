extends Probe
## Sonde `--probe-tour` (2026-07-28) : vérifie que la PORTÉE VERTICALE DU
## STREAMING couvre toute la hauteur de la termitière de donjon.
##
## POURQUOI ELLE EXISTE : la structure était tranchée ~30 blocs au-dessus du sol
## sur les 128 qu'elle mesure, ce qui se voyait comme un couvercle plat. Aucune
## sonde ne pouvait le détecter — `--probe-dungeon` interroge le générateur
## directement (`block_at`), qui était CORRECT ; la troncature venait de
## `cy_range` / `prepare_context`, qui décident quels chunks sont demandés et
## maillés. Mesuré avant correctif : `cy_range=(-5,-1)` et `hmax=2` alors que le
## sommet occupe le chunk 6.
##
## C'est la seule sonde qui teste la PORTÉE du streaming plutôt que le contenu
## généré. Toute nouvelle structure dépassant nettement le relief (tour, arbre
## géant, bâtiment haut) doit être ajoutée ici ET à `tower_top_for_column`.

func run() -> void:
	await wait_seconds(0.5)
	var g := WorldManager.generator
	# Cellule de donjon CHERCHÉE, et non plus codée en dur (2026-08-02). La
	# valeur figée (-40, -30) désignait une cellule que le monde ne bâtit plus
	# depuis que le placement exige un sol émergé : elle est sous le niveau de
	# la mer. La sonde mesurait donc la portée d'une tour inexistante.
	var cell := Vector2i(0, 0)
	var trouve := false
	for radius in range(0, 60):
		for dx in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				if absi(dx) != radius and absi(dz) != radius:
					continue
				if g.has_dungeon(Vector2i(dx, dz)):
					cell = Vector2i(dx, dz)
					trouve = true
					break
			if trouve:
				break
		if trouve:
			break
	if not trouve:
		print("[TOUR] aucune cellule de donjon trouvée — sonde inexploitable.")
		main.get_tree().quit(1)
		return
	var centre := POIGenerator.cell_center_world(cell)
	var col := Vector2i(floori(float(centre.x) / 16.0), floori(float(centre.y) / 16.0))

	var ground := int(floor(g.height_at(centre.x, centre.y)))
	var tower_top := g.tower_top_for_column(col)
	var expected_top := ground + DungeonTower.MAX_HEIGHT

	# 1. Le sommet annoncé par le nouveau helper.
	print("[TOUR] cellule=%s colonne=%s sol=%d" % [cell, col, ground])
	print("[TOUR] tower_top_for_column=%d (attendu ~%d)" % [tower_top, expected_top])

	# 2. La plage de chunks du streaming doit englober ce sommet.
	var rng: Vector2i = g.cy_range(col)
	var cy_needed := floori(float(expected_top) / 16.0)
	print("[TOUR] cy_range=%s — chunk du sommet=%d couvert=%s" % [rng, cy_needed, rng.y >= cy_needed])

	# 3. `hmax` du contexte de colonne (pilote _column_task).
	var ctx: Dictionary = g.prepare_context(col)
	var hmax := int(ctx["hmax"])
	print("[TOUR] contexte hmax=%d — couvre le sommet=%s" % [hmax, hmax >= expected_top])

	# 4. Preuve par les blocs : la structure a-t-elle de la matière EN HAUT ?
	# On balaie la colonne centrale du sol au sommet théorique et on note le bloc
	# plein le plus haut. S'il s'arrête loin sous `expected_top`, c'est tronqué.
	var highest := -1
	for wy in range(ground, expected_top + 2):
		if g.block_at(centre.x, wy, centre.y) != 0:
			highest = wy
	print("[TOUR] bloc plein le plus haut au centre=%d (sol+%d)" % [highest, highest - ground])

	var ok := tower_top >= expected_top and rng.y >= cy_needed and hmax >= expected_top
	finish(ok, "TOUR")

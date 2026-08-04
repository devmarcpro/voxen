extends Probe
## Sonde `--probe-pousses` (2026-08-03) — pousses et sylviculture.
##
## Une pousse est le seul objet du jeu dont l'apparence est une RÉDUCTION d'un
## autre : elle contient l'arbre entier, ramené à un bloc. Deux choses peuvent
## silencieusement la vider de son sens, et aucune des deux ne fait planter le
## jeu.
##
##   1. Que la réduction rende la même bouillie pour toutes les essences. Une
##      pousse sert à reconnaître ce qu'on va planter ; si un peuplier et un
##      chêne donnent le même petit tas, elle ne dit plus rien.
##   2. Qu'elle ne pousse jamais. Le registre est le seul endroit qui sait
##      qu'un bloc est une pousse, et une pousse oubliée est un décor.

const TAG := "POUSSES"

var _ok := true


func _expect(condition: bool, message: String) -> void:
	print("[%s] %s — %s" % [TAG, "ok" if condition else "ÉCHEC", message])
	if not condition:
		_ok = false


func run() -> void:
	# ON NE SAUVEGARDE RIEN. Cette sonde plante des arbres dans le monde chargé
	# pour mesurer leur croissance ; sans ce verrou, la sauvegarde de sortie les
	# grave dans la partie de l'auteur — et l'exécution suivante hérite de
	# l'arbre de la précédente, ce qui rend la mesure fausse ET instable. C'est
	# exactement ce qui est arrivé : « après croissance » comptait 2 702 blocs,
	# puis 2 803, puis 2 822, d'un lancement à l'autre.
	SaveManager.world_active = false
	SaveManager.enabled = false
	await wait_frame()
	_check_catalogue()
	_check_miniatures_differ()
	_check_planting_and_growth()
	_check_persistence()
	finish(_ok, TAG)


## Chaque essence a sa pousse, POSABLE. Une pousse rangée dans les ressources
## au lieu des matériaux serait invisible à la pose : c'est la distinction qui
## a décidé de tout le reste.
func _check_catalogue() -> void:
	var missing: Array[String] = []
	for species_id: String in GameData.trees:
		var id := SaplingManager.material_for(species_id)
		if not GameData.materials.has(id) or not GameData.material_runtime_ids.has(id):
			missing.append(species_id)
	_expect(missing.is_empty(), "les %d essences ont une pousse posable%s" % [
			GameData.trees.size(),
			"" if missing.is_empty() else " — manquent : " + ", ".join(missing.slice(0, 6))])


## LA RÉDUCTION DOIT DISTINGUER LES ESSENCES, et contenir du bois ET des
## feuilles : un bloc uniquement vert n'est pas un arbre miniature, c'est un
## buisson, et un bloc uniquement brun est un piquet.
func _check_miniatures_differ() -> void:
	var signatures := {}
	var sampled := 0
	for species_id: String in ["peuplier", "chene", "sapin", "palmier", "saule", "acacia"]:
		var species: Dictionary = GameData.trees.get(species_id, {})
		if species.is_empty():
			continue
		var grid := TreeGenerator.sapling_grid(species, 4242)
		sampled += 1
		var solid := SubdivGrid.count_solid(grid)
		var wood_id: int = GameData.material_runtime_ids.get(String(species["wood_material"]), 0)
		var leaf_id: int = GameData.material_runtime_ids.get(String(species["leaf_material"]), 0)
		var wood_cells := 0
		var leaf_cells := 0
		for i in grid.size():
			if grid[i] == wood_id:
				wood_cells += 1
			elif grid[i] == leaf_id:
				leaf_cells += 1
		print("[%s] %s : %d cellule(s) pleines, dont %d de bois et %d de feuillage" % [
				TAG, species_id, solid, wood_cells, leaf_cells])
		_expect(solid > 0, "la pousse de %s n'est pas vide" % species_id)
		_expect(wood_cells > 0 and leaf_cells > 0,
				"la pousse de %s montre du bois ET du feuillage" % species_id)
		# LA SIGNATURE EST L'OCCUPATION, pas les matériaux : deux essences ont
		# des bois différents, donc compareraient différemment même à forme
		# identique. C'est la FORME qui doit distinguer.
		var shape := ""
		for i in grid.size():
			shape += "1" if grid[i] != 0 else "0"
		signatures[shape] = String(signatures.get(shape, "")) + species_id + " "

	_expect(signatures.size() == sampled,
			"les %d essences échantillonnées ont %d silhouette(s) distincte(s)" % [
					sampled, signatures.size()])
	if signatures.size() != sampled:
		for shape: String in signatures:
			if String(signatures[shape]).split(" ", false).size() > 1:
				print("[%s]   silhouettes confondues : %s" % [TAG, signatures[shape]])


## PLANTER, PUIS POUSSER. On plante, on vérifie l'inscription au registre et la
## présence de la miniature, puis on avance l'horloge et on vérifie qu'un vrai
## arbre a remplacé le bloc unique.
func _check_planting_and_growth() -> void:
	var spot := Vector3i(1500, 300, 1500)
	# TERRAIN VIERGE. La comparaison « avant / après » n'a de sens que si rien
	# d'autre n'occupe l'espace, et la sonde partage le monde avec ce qui a pu
	# s'y trouver.
	#
	# EN MUTATION BATCHÉE, et c'est indispensable : `set_block` remaille son
	# chunk À CHAQUE APPEL, et vider ce volume en fait près de sept mille. La
	# première version de ce nettoyage n'a jamais rendu la main.
	for dx in range(-8, 9):
		for dy in range(0, 24):
			for dz in range(-8, 9):
				WorldManager.set_block_batched(spot + Vector3i(dx, dy, dz), 0)
	WorldManager.flush_batched_edits()
	# Un socle, sinon la pousse flotte — et surtout la vérification « il reste
	# un bloc ici » ne distinguerait pas l'arbre du vide.
	WorldManager.set_block(spot + Vector3i(0, -1, 0),
			GameData.material_runtime_ids.get("terre", 1))

	var planted := SaplingManager.plant(spot, "chene")
	_expect(planted, "une pousse de chêne se plante")
	_expect(SaplingManager.saplings.has(spot), "la pousse est inscrite au registre")

	var grid := WorldManager.subdiv_grid_at(spot)
	_expect(not grid.is_empty(), "la pousse a bien une miniature en sous-voxels")
	_expect(SubdivGrid.count_solid(grid) < SubdivGrid.CELLS,
			"la miniature n'est pas un bloc plein (%d/%d cellules)" % [
					SubdivGrid.count_solid(grid), SubdivGrid.CELLS])

	# CE QUI OCCUPE LE VOISINAGE AVANT, pour prouver que l'arbre est bien neuf.
	var before := _solid_around(spot, 8)
	# On vieillit la pousse plutôt que de pousser 3 000 ticks : le résultat est
	# le même et la sonde ne passe pas trois mille tours de simulation à
	# l'obtenir.
	(SaplingManager.saplings[spot] as Dictionary)["planted"] = \
			TickManager.tick_index - SaplingManager.GROWTH_TICKS
	TickManager.push_ticks(1)

	var after := _solid_around(spot, 8)
	print("[%s] après croissance : %d bloc(s) autour contre %d avant" % [TAG, after, before])
	_expect(not SaplingManager.saplings.has(spot), "la pousse sort du registre en grandissant")
	_expect(after > before + 20, "un vrai arbre a remplacé la pousse")


## Le registre survit à un aller-retour de sauvegarde. Sans ça, quitter le jeu
## gèlerait toutes les pousses plantées : elles resteraient des décors.
func _check_persistence() -> void:
	var spot := Vector3i(1600, 300, 1600)
	WorldManager.set_block(spot + Vector3i(0, -1, 0),
			GameData.material_runtime_ids.get("terre", 1))
	SaplingManager.plant(spot, "bouleau")
	var saved := SaplingManager.save_state()
	SaplingManager.saplings.clear()
	SaplingManager.restore_state(saved)
	var restored: Dictionary = SaplingManager.saplings.get(spot, {})
	_expect(String(restored.get("species", "")) == "bouleau",
			"l'essence traverse la sauvegarde")
	_expect(restored.has("planted"), "l'instant de plantation traverse la sauvegarde")
	SaplingManager.forget(spot)


func _solid_around(center: Vector3i, radius: int) -> int:
	var n := 0
	for dx in range(-radius, radius + 1):
		for dy in range(0, radius * 3):
			for dz in range(-radius, radius + 1):
				if WorldManager.block_at_world(center + Vector3i(dx, dy, dz)) != 0:
					n += 1
	return n

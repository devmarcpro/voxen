extends Probe
## Sonde `--test-arbres` (2026-08-03) — CAPTURE des arbres.
##
## POURQUOI UNE CAPTURE ET PAS DES ASSERTIONS. Deux choses se jugent ici à
## l'oeil et à rien d'autre : les silhouettes par essence (un peuplier doit se
## reconnaître de loin) et les congés en sous-voxels qui lient les cubes aux
## coudes. `--probe-arbres` mesure les proportions, ce qui prouve que les
## essences DIFFÈRENT, pas qu'elles sont BELLES. D'où la photo.
##
## On plante une rangée d'essences choisies sur un terrain plat, à distance
## constante, pour les comparer côte à côte plutôt qu'au hasard du monde.

const TAG := "ARBRECAP"

## Une essence par ARCHITECTURE, pas une par silhouette : c'est le port qui se
## juge sur une photo. Huit et pas dix — au-delà, il faut reculer si loin que la
## brume les avale, et la planche cesse de prouver quoi que ce soit.
const SHOWCASE := [
	"peuplier",   # colonne, port excurrent serré
	"cedre",      # plateaux étagés
	"orme",       # gerbe en vase
	"acacia",     # parasol de savane
	"chene",      # houppier large et bas, port décurrent
	"sapin",      # cône, flèche unique
	"saule",      # rideaux retombants
	"palmier",    # stipe nue et palmes
]

## Nombre d'essences par photo.
const PER_PANEL := 4

## ESPACEMENT. Porté de 12 à 24 : les couronnes font jusqu'à 8 blocs de rayon,
## donc à 12 blocs d'écart deux voisins se touchaient et la planche montrait une
## haie continue au lieu de dix arbres.
const SPACING := 18


func run() -> void:
	# ON NE SAUVEGARDE RIEN. Cette sonde PLANTE des arbres dans le monde chargé
	# pour les photographier ; sans ce verrou, une autosave ou une sauvegarde de
	# sortie graverait une rangée d'arbres de démonstration dans la partie de
	# l'auteur, qui n'a rien demandé de tel.
	SaveManager.world_active = false
	SaveManager.enabled = false

	# Plein jour : de nuit on ne voit ni la silhouette ni les congés.
	TickManager.tick_index = int(DayNightManager.TICKS_PER_DAY / 2)
	await wait_frame()

	camera.input_locked = true
	player.input_locked = true

	# HUD ÉTEINT. La première capture était couverte aux deux tiers par la barre
	# de vie, l'aide clavier et l'arme en main : on photographiait l'interface,
	# pas les arbres.
	# Le corps du joueur aussi sort du cadre : son arme en main barrait le bas de
	# l'image. C'est `player_body` qu'on cache, pas `player` : ce dernier est un
	# Node (la logique), sans propriete `visible` — l'affecter leve une erreur.
	var body: Node = main.get("player_body")
	if body is Node3D:
		(body as Node3D).visible = false
	for node_name: String in ["HUD", "CombatHUD"]:
		var ui := main.get_node_or_null(node_name)
		if ui != null:
			ui.visible = false

	# ON PLANTE EN L'AIR, SUR FOND DE CIEL.
	#
	# Deux essais ratés avant celui-ci, et la même leçon : au sol, la rangée de
	# démonstration se noyait dans la forêt du biome, si bien que la photo ne
	# permettait pas de dire quel arbre était lequel. Une planche comparative
	# n'a pas à être une scène de jeu — il lui faut un fond neutre et rien
	# d'autre dans le cadre. (Le premier essai terrassait 177 000 blocs pour
	# obtenir ce fond neutre, avec remaillage synchrone à chaque bloc : le jeu
	# restait bloqué avant même d'ouvrir sa fenêtre.)
	#
	# La première version de cette sonde aplanissait une bande de terrain avec
	# 177 000 `set_block`, dont chacun REMAILLE SON CHUNK SYNCHRONEMENT : le jeu
	# restait bloqué avant même d'ouvrir sa fenêtre. Le terrassement n'apportait
	# qu'un fond régulier, ce qui ne vaut pas ce prix — on prend le relief tel
	# qu'il vient et on aligne seulement les arbres.
	var gen := WorldManager.generator
	var span := SHOWCASE.size() * SPACING
	# Assez haut pour survoler le relief et les arbres du biome.
	var ground := gen.height_at(0, 0) + 60
	var planted := 0
	for i in SHOWCASE.size():
		var species_id: String = SHOWCASE[i]
		var species: Dictionary = GameData.trees.get(species_id, {})
		if species.is_empty():
			print("[%s] essence « %s » absente du catalogue." % [TAG, species_id])
			continue
		var base := Vector3i(i * SPACING, ground, 0)
		var tree := TreeGenerator.generate(base, 20260803, species)
		var subdivs: Dictionary = tree["trunk_subdivs"]
		for pos: Vector3i in (tree["blocks"] as Dictionary):
			WorldManager.set_block(pos, tree["blocks"][pos])
		_paint_subdivs(subdivs)
		var low := 1 << 30
		var high := -(1 << 30)
		for pos: Vector3i in (tree["blocks"] as Dictionary):
			low = mini(low, pos.y)
			high = maxi(high, pos.y)
		_extent_of[i] = Vector2(low, high)
		_min_y = mini(_min_y, low)
		_max_y = maxi(_max_y, high)
		print("[%s] %s : %d bloc(s), dont %d congé(s) en sous-voxels" % [
				TAG, species_id, (tree["blocks"] as Dictionary).size(), subdivs.size()])
		planted += 1

	if planted == 0:
		print("[%s] rien à photographier." % TAG)
		main.get_tree().quit(1)
		return

	# Vue d'ensemble : les dix silhouettes alignées, de face. Le cadrage se
	# déduit de la HAUTEUR RÉELLE des arbres plantés, pas d'une constante : la
	# première version visait 14 m au-dessus d'un sol supposé plat et
	# photographiait des troncs coupés à mi-hauteur.
	# DEUX PANNEAUX DE CINQ, pas une rangée de dix.
	#
	# Une rangée de dix arbres espacés de 24 blocs fait 240 blocs de large : pour
	# la faire tenir dans le cadre il faut reculer de 150 m, et à cette distance
	# chaque arbre est une tache de trente pixels que la brume avale. On ne peut
	# pas à la fois tout montrer et montrer quelque chose — donc deux photos.
	var panels := int(ceil(float(SHOWCASE.size()) / PER_PANEL))
	for panel in panels:
		var first := panel * PER_PANEL
		await _frame(first, mini(PER_PANEL, SHOWCASE.size() - first))
		await screenshot("arbres_silhouettes_%d.png" % (panel + 1))
		print("[%s] capture : arbres_silhouettes_%d.png (%s)" % [
				TAG, panel + 1, SHOWCASE.slice(first, first + PER_PANEL)])

	# Gros plan : c'est à cette distance que se jugent le grain de 8 px des
	# branches et l'évasement des racines, que la vue d'ensemble ne peut pas
	# montrer.
	var close := SHOWCASE.find("acacia")
	if close >= 0:
		var x := close * SPACING
		var focus := Vector3(x, float(_min_y + _max_y) * 0.5, 0.0)
		camera.position = focus + Vector3(11.0, 3.0, 14.0)
		camera.look_at(focus, Vector3.UP)
		await _settle()
		await screenshot("arbres_gros_plan.png")
		print("[%s] capture : arbres_gros_plan.png" % TAG)

	# LES POUSSES, à hauteur d'œil. Une miniature de la taille d'un bloc ne se
	# juge pas de loin : soit elle rappelle l'essence qu'elle deviendra, soit
	# c'est un petit tas, et seule une photo rapprochée le dit.
	var row_y := _min_y
	for i in SHOWCASE.size():
		var seed_spot := Vector3i(i * 3, row_y, -40)
		WorldManager.set_block(seed_spot + Vector3i(0, -1, 0),
				GameData.material_runtime_ids.get("terre", 1))
		SaplingManager.plant(seed_spot, String(SHOWCASE[i]))
	var mid := float(SHOWCASE.size() - 1) * 3.0 * 0.5
	camera.position = Vector3(mid, float(row_y) + 1.4, -34.0)
	camera.look_at(Vector3(mid, float(row_y) + 0.4, -40.0), Vector3.UP)
	await _settle()
	await screenshot("arbres_pousses.png")
	print("[%s] capture : arbres_pousses.png (%d pousses)" % [TAG, SHOWCASE.size()])

	# VUE DE JEU, depuis le sol, dans une vraie forêt.
	#
	# Les planches ci-dessus sont des photos de laboratoire : fond de ciel, un
	# arbre par emplacement, rien autour. Elles disent si une essence a la bonne
	# silhouette, elles ne disent RIEN de ce que le joueur voit — une forêt trop
	# dense, des couronnes qui s'interpénètrent, un sous-bois bouché ne se
	# jugent qu'ici.
	var gen2 := WorldManager.generator
	var best := Vector2i.ZERO
	var best_count := -1
	for cx in range(-14, 15):
		for cz in range(-14, 15):
			var spot := Vector2i(cx * 24, cz * 24)
			var trees: Array = gen2.call("_trees_in_window", spot.x - 20, spot.x + 20,
					spot.y - 20, spot.y + 20)
			if trees.size() > best_count:
				best_count = trees.size()
				best = spot
	if best_count > 0:
		var ground2 := gen2.height_at(best.x, best.y)
		# EN LISIÈRE ET EN SURPLOMB, pas au milieu. La première version se plaçait
		# à 3 blocs du sol au centre du bosquet le plus dense : la caméra était
		# DANS une couronne, et la photo montrait l'intérieur d'un bloc de
		# feuilles. Une forêt se juge de sa lisière, d'où l'on voit à la fois les
		# fûts, le sous-bois et la ligne de cimes.
		camera.position = Vector3(best.x - 46.0, ground2 + 16.0, best.y - 46.0)
		camera.look_at(Vector3(best.x, ground2 + 6.0, best.y), Vector3.UP)
		await _settle()
		await screenshot("arbres_en_jeu.png")
		print("[%s] capture : arbres_en_jeu.png (%d arbres autour de %s)" % [TAG, best_count, best])

	main.get_tree().quit(0)


## Cadre `count` arbres à partir de `first`, au plus juste.
##
## Le recul se déduit de la LARGEUR du groupe et de la HAUTEUR des arbres, avec
## le champ de vision réel de la caméra : le coder en dur donnait soit des cimes
## coupées, soit dix taches perdues dans la brume, selon l'essence tirée.
func _frame(first: int, count: int) -> void:
	var left := float(first * SPACING)
	var right := float((first + count - 1) * SPACING)
	var mid := (left + right) * 0.5
	var width := right - left + float(SPACING)
	# La hauteur retenue est celle DU GROUPE photographié : cadrer quatre
	# pommiers sur la hauteur d'un séquoia planté ailleurs les réduirait à
	# quatre points.
	var tall := 1.0
	var floor_y := float(_max_y)
	for i in range(first, first + count):
		var extent: Vector2 = _extent_of.get(i, Vector2(_min_y, _max_y))
		tall = maxf(tall, extent.y - extent.x)
		floor_y = minf(floor_y, extent.x)
	var eye := floor_y + tall * 0.55
	var fov := deg_to_rad(camera_fov())
	# Le champ VERTICAL borne autant que l'horizontal : un cyprès est étroit et
	# haut, c'est sa hauteur qui décide du recul.
	var back := maxf(width * 0.62 / tan(fov * 0.5), tall * 0.62 / tan(fov * 0.5))
	camera.position = Vector3(mid, eye, back)
	camera.look_at(Vector3(mid, floor_y + tall * 0.45, 0.0), Vector3.UP)
	await _settle()


## Champ de vision de la caméra active, en degrés.
func camera_fov() -> float:
	var cam := main.get_viewport().get_camera_3d()
	return cam.fov if cam != null else 75.0


## Pose des sous-grilles telles quelles dans les chunks.
##
## On passe par le chemin interne, pas par `set_sub_region` : cette API-là
## sculpte CELLULE PAR CELLULE, ce qui ferait des centaines d'appels et autant
## de remaillages synchrones par arbre. Le générateur de monde écrit lui aussi
## les congés d'un bloc d'un coup (`extra_subdivs`) ; on fait la même chose,
## puisqu'on plante ici ce que le générateur planterait.
func _paint_subdivs(subdivs: Dictionary) -> void:
	for pos: Vector3i in subdivs:
		var ck := Vector3i(pos.x >> 4, pos.y >> 4, pos.z >> 4)
		var index := (pos.x & 15) | ((pos.z & 15) << 4) | ((pos.y & 15) << 8)
		var data: ChunkData = WorldManager.call("_get_chunk_sync", ck)
		if data == null:
			continue
		var grid: PackedInt32Array = subdivs[pos]
		data.set_subdiv(index, grid, SubdivGrid.dominant_id(grid))
		_dirty[ck] = true


var _dirty := {}

## Étendue verticale par essence (index → min/max y), pour cadrer chaque groupe
## sur SES arbres.
var _extent_of := {}

## Étendue verticale de ce qu'on a planté — sert au cadrage.
var _min_y := 1 << 30
var _max_y := -(1 << 30)


## Laisse le streaming ET le remaillage se vider avant la photo — sans ça on
## capture des chunks à moitié maillés et on croit à des trous.
func _settle() -> void:
	WorldManager.update_center(camera.position)
	# Les chunks touchés par `_paint_subdivs` ne sont pas marqués sales par
	# WorldManager (on a écrit sous lui) : on les remaille nous-mêmes, sinon la
	# photo montre les cubes sans leurs congés et on conclut à tort qu'ils
	# n'existent pas.
	for ck: Vector3i in _dirty:
		WorldManager.call("_remesh_chunk_now", ck, 0)
	_dirty.clear()
	await main.get_tree().create_timer(1.0).timeout
	var waited := 1.0
	while int(WorldManager.stats()["queue"]) > 0 and waited < 25.0:
		await main.get_tree().process_frame
		waited += main.get_process_delta_time()
	await main.get_tree().create_timer(0.6).timeout

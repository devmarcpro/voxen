extends Probe
## Sonde `--probe-plantes` (2026-08-04) — les plantes en 2D.
##
## CE QU'ELLE DÉFEND. Une plante en croix a trois façons d'être fausse sans que
## rien ne plante :
##
##   1. elle OCCULTE. Laissée dans le pad du mailleur, elle vole sa face du
##      dessus au sol qu'elle recouvre : un champ de blé pose un trou carré
##      dans le terrain, et on ne le voit qu'en marchant dessus ;
##   2. elle DÉBORDE de son bloc, et se fait trancher à la frontière de chunk —
##      exactement le défaut qui tronquait les couronnes d'arbres trop larges,
##      et qui a vécu des mois sans être remarqué ;
##   3. elle N'EXISTE PAS. Les fiches sont écrites, les biomes les citent, et
##      pas un brin ne pousse parce qu'un maillon du semis est débranché.
##
## Aucune de ces trois-là ne lève d'erreur. Elles se constatent à l'œil, tard.

const TAG := "PLANTES"

var _ok := true


func _expect(condition: bool, message: String) -> void:
	print("[%s] %s — %s" % [TAG, "ok" if condition else "ÉCHEC", message])
	if not condition:
		_ok = false


func run() -> void:
	await wait_frame()
	_check_catalogue()
	_check_geometry()
	_check_growth()
	await _check_meshing()
	_check_atlas()
	_check_hitbox_and_harvest()
	await _capture()
	finish(_ok, TAG)


## UNE PHOTO, parce qu'aucune assertion ne dit à quoi ça RESSEMBLE.
##
## Toutes les vérifications de cette sonde peuvent passer sur un champ de
## bâtonnets verticaux illisibles : elles comptent des quads, elles ne les
## regardent pas. Le générateur d'arbres a été refait deux fois pour cette
## raison exacte — les défauts de silhouette ne se voient qu'en image.
func _capture() -> void:
	if not can_capture():
		print("[%s] capture impossible (headless)." % TAG)
		return
	var generator: NoiseGenerator = WorldManager.generator
	if generator == null:
		return
	# ON CHERCHE UN ENDROIT RÉELLEMENT FLEURI. Photographier là où le joueur
	# s'est arrêté donnerait une image de son sous-sol une fois sur deux.
	# ON CHERCHE PRÈS DU JOUEUR, ET SUR LA TERRE FERME.
	#
	# La première version balayait des colonnes de chunks espacées de 29 et 43,
	# soit jusqu'à HUIT KILOMÈTRES de l'origine : elle a cadré un fond d'océan de
	# taïga à huit mille blocs, où le streaming n'avait aucune chance de rattraper
	# et où rien ne pousse. Le compte de plantes, lui, était juste — il portait
	# sur le semis, pas sur la question de savoir si le sol était émergé.
	var here_now: Vector3 = player.get_position_for_ai()
	var origin := Vector2i(floori(here_now.x / 16.0), floori(here_now.z / 16.0))
	var best := origin
	var best_count := 0
	var best_score := -1000
	for i in 220:
		var ring := 1 + i / 8
		var col := origin + Vector2i((i % 8) - 4, ring * (1 if i % 2 == 0 else -1))
		var probe_ground := generator.height_at(col.x * 16 + 8, col.y * 16 + 8)
		if probe_ground <= generator.water_level + 2:
			continue   # Sous l'eau ou sur l'estran : rien n'y pousse.
		var probe_ctx := generator.prepare_context(col)
		# ON PRÉFÈRE LES COLONNES DÉGAGÉES, sans les EXIGER. Deux cadrages de
		# suite ont fini DANS un houppier de chêne ; mais interdire tout arbre a
		# fait tomber le choix sur une colonne à ZÉRO plante, ce qui ne vaut pas
		# mieux. On note donc la colonne : beaucoup de plantes, peu d'arbres.
		var count := 0
		for plant: Dictionary in (probe_ctx["plants"] as Array):
			var rid := int(plant["material_id"])
			if GameData.cross_mask.size() > rid and GameData.cross_mask[rid] == 1:
				count += 1
		var score := count - (probe_ctx["trees"] as Array).size() * 3
		if count > 0 and score > best_score:
			best_score = score
			best_count = count
			best = col
	var wx := best.x * 16 + 8
	var wz := best.y * 16 + 8
	var ground := generator.height_at(wx, wz)
	print("[%s] cadrage : colonne %s, %d plante(s), sol y=%d" % [TAG, best, best_count, ground])
	# PLEIN JOUR, sinon on photographie une nuit noire et on ne conclut rien.
	# L'heure dérive du tick du monde : c'est lui qu'on avance, plutôt que de
	# forcer une lumière à côté de l'horloge — deux sources d'heure finiraient
	# par diverger, comme les deux champs `active` des dimensions.
	TickManager.tick_index += DayNightManager.ticks_until(12.0)
	camera.input_locked = true
	player.input_locked = true
	player.teleport_to(Vector3(float(wx), float(ground) + 2.9, float(wz)))
	# On laisse le streaming rattraper : photographier trop tôt rend du vide.
	for i in 150:
		await wait_frame()
	# Vue RASANTE et BASSE : une plante de 60 cm vue de haut n'est qu'un point.
	camera.position = Vector3(float(wx) - 4.5, float(ground) + 2.6, float(wz) - 4.5)
	camera.look_at(Vector3(float(wx) + 1.5, float(ground) + 0.4, float(wz) + 1.5), Vector3.UP)
	await wait_seconds(1.0)
	await screenshot("plantes_2d.png")
	print("[%s] capture : plantes_2d.png" % TAG)


## LE CATALOGUE : les fiches déclarent leur silhouette, et le masque du mailleur
## en dérive. Sans le masque, tout le reste est du décor mort.
func _check_catalogue() -> void:
	var crosses := 0
	var ports := {}
	for rid: int in GameData.plant_species_by_runtime:
		crosses += 1
		var species: Dictionary = GameData.plant_species_by_runtime[rid]
		ports[String(species.get("port", "touffe"))] = true
	print("[%s] %d matériau(x) en croix, ports employés : %s" % [
			TAG, crosses, str(ports.keys())])
	_expect(crosses >= 20, "le catalogue de plantes 2D est peuplé")
	_expect(ports.size() >= 4,
			"plusieurs ports sont réellement employés (une seule silhouette ne prouve rien)")

	# LE MASQUE ET LE REGISTRE DOIVENT S'ACCORDER. Deux tables qui doivent rester
	# égales finissent toujours par ne plus l'être — celle-ci est vérifiée.
	var masked := 0
	for rid in GameData.cross_mask.size():
		if GameData.cross_mask[rid] == 1:
			masked += 1
	_expect(masked == crosses,
			"le masque du mailleur et le registre d'espèces comptent pareil (%d/%d)" % [
					masked, crosses])

	# UN BLOC DE SOL NE DOIT JAMAIS ÊTRE UNE CROIX. `herbe_seche` est le matériau
	# de SURFACE de la steppe : le passer en croix rendrait le sol de tout un
	# biome non occultant. C'est arrivé — un id de plante avait été écrit
	# par-dessus le sien.
	for biome_id: String in GameData.biomes:
		var biome: Dictionary = GameData.biomes[biome_id]
		for key: String in ["surface_material", "subsurface_material"]:
			var mid := String(biome.get(key, ""))
			if mid == "":
				continue
			var rid: int = GameData.material_runtime_ids.get(mid, 0)
			if rid > 0 and rid < GameData.cross_mask.size() and GameData.cross_mask[rid] == 1:
				_expect(false, "le sol « %s » du biome « %s » est dessiné en croix" % [
						mid, biome_id])
				return
	_expect(true, "aucun matériau de SOL n'est dessiné en croix")


## LA GÉOMÉTRIE : elle tient dans son bloc, et elle est déterministe.
func _check_geometry() -> void:
	var overflow: Array[String] = []
	var empty: Array[String] = []
	for rid: int in GameData.plant_species_by_runtime:
		var species: Dictionary = GameData.plant_species_by_runtime[rid]
		var worst := 0.0
		var quad_count := 0
		# Plusieurs positions : la forme est tirée depuis les coordonnées, un
		# seul point ne dit rien du pire cas.
		for i in 24:
			var quads := PlantMesh.build(species, i * 13, 64, i * 7 - 40, 1337)
			quad_count += quads.size()
			for quad: PackedVector3Array in quads:
				for v: Vector3 in quad:
					worst = maxf(worst, maxf(absf(v.x), absf(v.z)))
		if quad_count == 0:
			empty.append(String(species["id"]))
		if worst > PlantMesh.MAX_HALF_WIDTH:
			overflow.append("%s (%.2f)" % [species["id"], worst])
	_expect(empty.is_empty(),
			"chaque espèce produit de la géométrie%s" % [
					"" if empty.is_empty() else " — vides : " + ", ".join(empty)])
	_expect(overflow.is_empty(),
			"aucune plante ne déborde de son bloc%s" % [
					"" if overflow.is_empty() else " — débordent : " + ", ".join(overflow)])

	# DÉTERMINISME : la même case redonne la même plante. Sans ça, un chunk
	# évincé puis regénéré verrait son champ changer de forme sous les yeux du
	# joueur — le même défaut que les îles suspendues, au même endroit.
	var sample: Dictionary = GameData.plant_species_by_runtime.values()[0]
	var a := PlantMesh.build(sample, 12, 64, -8, 1337)
	var b := PlantMesh.build(sample, 12, 64, -8, 1337)
	var c := PlantMesh.build(sample, 13, 64, -8, 1337)
	_expect(str(a) == str(b), "la même case redonne exactement la même plante")
	# LA GÉOMÉTRIE EST LA MÊME PARTOUT, ET C'EST VOULU DEPUIS LA CROIX.
	#
	# Cette assertion exigeait l'inverse : elle datait du temps où la silhouette
	# était bricolée par tirage, et où deux cases identiques auraient signalé un
	# semis figé. Depuis que la plante est une croix portant un SPRITE, la
	# variété vient du dessin, pas de la géométrie — deux touffes d'herbe ont le
	# même squelette, et c'est précisément ce qui les fait tenir dans la grille.
	_expect(str(a) == str(c),
			"la croix est la même dans chaque case (la variété est dans le sprite)")


## ELLES POUSSENT VRAIMENT. Le catalogue peut être parfait et le semis
## débranché : c'est le monde généré qui tranche, pas les fiches.
func _check_growth() -> void:
	var generator: NoiseGenerator = WorldManager.generator
	if generator == null:
		_expect(false, "aucun générateur")
		return
	var found := {}
	var columns := 0
	# On balaie plusieurs colonnes ÉLOIGNÉES pour croiser des biomes différents,
	# sinon on ne mesure que la végétation de l'endroit où le joueur dort.
	for i in 26:
		var col := Vector2i(i * 37 - 200, i * 53 - 300)
		var ctx := generator.prepare_context(col)
		columns += 1
		for plant: Dictionary in (ctx["plants"] as Array):
			var rid := int(plant["material_id"])
			if GameData.cross_mask.size() > rid and GameData.cross_mask[rid] == 1:
				found[rid] = int(found.get(rid, 0)) + 1
	var total := 0
	for rid: int in found:
		total += found[rid]
	print("[%s] %d plante(s) en croix semées sur %d colonnes, %d espèce(s) distincte(s)" % [
			TAG, total, columns, found.size()])
	_expect(total > 0, "les plantes 2D poussent réellement dans le monde")
	_expect(found.size() >= 3, "plusieurs espèces différentes apparaissent")


## LE MAILLAGE : la plante est DESSINÉE, et elle n'a rien volé au sol.
##
## C'est l'assertion la plus importante de cette sonde, et la seule qui puisse
## attraper l'occultation. On maille deux fois la même colonne — une fois telle
## quelle, une fois avec une plante posée — et on compare : la géométrie doit
## AUGMENTER. Si la plante occultait, elle prendrait la face du sol en échange
## de la sienne, et le compte n'augmenterait pas comme il faut.
func _check_meshing() -> void:
	# ON MAILLE UN CHUNK SYNTHÉTIQUE, PAS LE MONDE VIVANT.
	#
	# La première version posait une plante dans le monde et comparait le nombre
	# de sommets du chunk avant/après. En headless ça passait ; fenêtre ouverte,
	# le streaming remaillait le même chunk entre les deux mesures et le compte
	# bougeait pour des raisons qui n'avaient rien à voir avec la plante. Une
	# assertion qui dépend de ce que fait le streaming à cet instant ne mesure
	# pas ce qu'elle prétend — elle mesure la météo.
	#
	# Ici : une dalle de terre, maillée deux fois, avec et sans la plante. Aucun
	# thread, aucun voisin, aucune surprise.
	var stone: int = GameData.material_runtime_ids.get("terre", 1)
	var plant_id: int = GameData.material_runtime_ids.get("coquelicot", 0)
	_expect(plant_id > 0, "le coquelicot existe en catalogue")
	if plant_id == 0:
		return

	var bare := _slab(stone, 0, 0)
	var sown := _slab(stone, plant_id, 1)
	var bare_count := _count(bare)
	var sown_count := _count(sown)
	print("[%s] dalle d'essai : %d sommets nue → %d avec une plante" % [
			TAG, bare_count, sown_count])
	_expect(bare_count > 0, "la dalle nue produit bien de la géométrie")
	# LE SOL N'A RIEN PERDU, ET LA PLANTE S'EST AJOUTÉE. Si la plante occultait,
	# elle volerait la face du dessus du bloc sous elle : on gagnerait ses quads
	# et on en perdrait autant. Le gain doit donc être ENTIER.
	_expect(sown_count > bare_count,
			"poser une plante AJOUTE de la géométrie (+%d)" % [sown_count - bare_count])
	# UNE PLANTE = UN QUAD DOUBLE FACE = 8 SOMMETS, exactement. Le seuil valait
	# 16 du temps où la plante était un assemblage de quads ; le garder aurait
	# fait échouer la version plate pour la seule raison qu'elle est plus
	# économique. Un seuil doit suivre ce qu'il défend.
	# DEUX quads croisés, chacun double face : 16 sommets. Le seuil suit la
	# forme — il valait 16 pour l'assemblage multi-quads, 8 pour le plan unique,
	# 16 de nouveau pour la croix. Un seuil qui ne suit pas ce qu'il défend
	# finit par défendre autre chose.
	_expect(sown_count - bare_count == 16,
			"une plante coûte DEUX quads croisés double face (+%d)" % [
					sown_count - bare_count])


## AUCUNE HITBOX. C'est une demande explicite, et c'est la propriété la plus
## facile à casser sans s'en apercevoir : il suffit qu'un des trois endroits qui
## décident de la solidité oublie le masque pour qu'un champ redevienne un mur
## de cubes invisibles. Les trois sont vérifiés ici, pas seulement celui du
## joueur — une flèche arrêtée par un brin d'herbe ou un villageois qui marche
## sur les fleurs sont le même défaut, ailleurs.
func _check_hitbox_and_harvest() -> void:
	var generator: NoiseGenerator = WorldManager.generator
	if generator == null:
		return
	# LE SOL DE LA COLONNE OÙ L'ON POSE, pas de celle où le joueur se tient.
	# Première version : hauteur prise sous le joueur, plante posée trois blocs
	# plus loin — en terrain accidenté elle finissait DANS la roche, et le rayon
	# heurtait la pierre au-dessus d'elle. La sonde accusait le moteur de ne pas
	# savoir viser une plante ; c'était elle qui l'avait enterrée.
	var here: Vector3 = player.get_position_for_ai()
	var px := roundi(here.x) + 3
	var pz := roundi(here.z) + 3
	var pos := Vector3i(px, generator.height_at(px, pz) + 1, pz)
	var plant_id: int = GameData.material_runtime_ids.get("herbe_haute", 0)
	if plant_id == 0:
		return
	WorldManager.set_block(pos, plant_id)

	# 1. ELLE SE VISE — c'est la « hitbox » qui compte.
	#
	# L'auteur a demandé successivement « pas de hitbox » puis « une hitbox, donc
	# récupérable ». Les deux tiennent ensemble parce qu'il y a DEUX hitboxes
	# distinctes, et qu'on n'en voulait qu'une :
	#   — celle du DÉPLACEMENT, qu'on ne veut pas : sans quoi un champ de blé est
	#     un mur de cubes invisibles qu'il faut sauter un par un ;
	#   — celle de la VISÉE, qu'on veut : sans elle, on ne peut ni casser la
	#     plante ni la ramasser, et elle n'est qu'un décor.
	# LE RAYON PART JUSTE AU-DESSUS DE LA PLANTE. Tiré de trois blocs plus haut,
	# il heurtait le feuillage d'un arbre quand la case en portait un — et la
	# sonde concluait que les plantes ne se visent pas, alors qu'elle visait un
	# chêne. Un test de visée doit tirer sur la seule chose qu'il teste.
	var eye := Vector3(float(pos.x) + 0.5, float(pos.y) + 0.6, float(pos.z) + 0.5)
	var hit: Dictionary = player.call("_raycast_voxel", eye, Vector3.DOWN, 1.2)
	_expect(not hit.is_empty() and (hit["pos"] as Vector3i) == pos,
			"la plante se VISE (on peut la casser et la ramasser)")

	# 2. MAIS ON LA TRAVERSE EN MARCHANT.
	var blocking: bool = camera.call("_is_blocking", pos.x, pos.y, pos.z)
	_expect(not blocking, "on traverse la plante en marchant (pas un mur)")

	# 3. ET ELLE SE RAMASSE : la récolte crédite le matériau lui-même, par le
	# chemin commun à tous les blocs. On vérifie que la fiche porte bien ce
	# qu'il faut, sinon le bloc se casse et ne donne rien.
	var species: Dictionary = GameData.materials.get("herbe_haute", {})
	var harvest: Dictionary = species.get("harvest", {})
	_expect(String(harvest.get("skill", "")) != "" and String(harvest.get("tool_category", "")) != "",
			"la plante déclare outil et compétence de récolte (sinon elle ne donne rien)")

	# 2. UNE FLÈCHE LA TRAVERSE.
	#
	# LE SEGMENT NE DOIT COUVRIR QUE LA CASE DE LA PLANTE. Une première version
	# tirait sur quatre blocs et traversait le relief voisin : elle mesurait la
	# pente du terrain, pas la plante, et échouait pour une raison qui n'avait
	# rien à voir avec ce qu'elle prétendait défendre.
	var from := Vector3(float(pos.x) + 0.5, float(pos.y) + 0.5, float(pos.z) + 0.05)
	var to := Vector3(float(pos.x) + 0.5, float(pos.y) + 0.5, float(pos.z) + 0.95)
	_expect(not WorldManager.line_blocked(from, to),
			"une ligne de vue traverse la plante (ni flèche ni regard arrêtés)")

	# AUTO-VÉRIFICATION : le même segment DOIT être bloqué par un vrai bloc.
	# Sans elle, un `line_blocked` cassé qui rendrait toujours false ferait
	# passer l'assertion ci-dessus en beauté.
	var stone: int = GameData.material_runtime_ids.get("pierre", 0)
	if stone > 0:
		WorldManager.set_block(pos, stone)
		_expect(WorldManager.line_blocked(from, to),
				"le même segment EST bloqué par de la pierre (le test sait détecter)")
		WorldManager.set_block(pos, plant_id)

	# 3. ET LE BLOC EXISTE BIEN — sans quoi les deux tests ci-dessus seraient
	# vrais pour la mauvaise raison : il n'y aurait simplement rien à traverser.
	_expect(WorldManager.block_at_world(pos) == plant_id,
			"la plante est bien posée là (sinon on ne teste rien)")
	WorldManager.set_block(pos, 0)


## L'ATLAS : chaque espèce a sa cellule de pixels, à l'échelle des blocs.
func _check_atlas() -> void:
	var atlas := PlantAtlas.build(GameData.plant_species_by_runtime)
	var index: Dictionary = atlas["index"]
	_expect(index.size() == GameData.plant_species_by_runtime.size(),
			"chaque espèce a sa cellule dans l'atlas (%d/%d)" % [
					index.size(), GameData.plant_species_by_runtime.size()])
	var image: Image = (atlas["texture"] as ImageTexture).get_image()
	_expect(image.get_width() == PlantAtlas.COLUMNS * PlantAtlas.PIXELS_PER_BLOCK,
			"la cellule fait %d px de large — la grille des blocs (PIXELS = 16)"
					% PlantAtlas.PIXELS_PER_BLOCK)
	# CHAQUE SPRITE EST DESSINÉ, ET IL EST TROUÉ. Un sprite vide donne une plante
	# invisible ; un sprite PLEIN donne un rectangle opaque — les deux passent
	# toutes les autres assertions sans broncher.
	var blank: Array[String] = []
	var solid: Array[String] = []
	for rid: int in GameData.plant_species_by_runtime:
		var cell: int = index[rid]
		var ox := (cell % PlantAtlas.COLUMNS) * PlantAtlas.PIXELS_PER_BLOCK
		var oy := (cell / PlantAtlas.COLUMNS) * PlantAtlas.CELL_H
		var lit := 0
		for y in PlantAtlas.CELL_H:
			for x in PlantAtlas.PIXELS_PER_BLOCK:
				if image.get_pixel(ox + x, oy + y).a > 0.5:
					lit += 1
		var id := String((GameData.plant_species_by_runtime[rid] as Dictionary)["id"])
		if lit == 0:
			blank.append(id)
		elif lit > PlantAtlas.PIXELS_PER_BLOCK * PlantAtlas.CELL_H / 2:
			solid.append(id)
	_expect(blank.is_empty(), "aucun sprite n'est vide%s" % [
			"" if blank.is_empty() else " — vides : " + ", ".join(blank)])
	_expect(solid.is_empty(), "aucun sprite n'est un rectangle plein%s" % [
			"" if solid.is_empty() else " — pleins : " + ", ".join(solid)])


## Une dalle de 16×16 d'un matériau, à hauteur 0, avec éventuellement une plante
## posée dessus en (8, `plant_y`, 8).
func _slab(ground_id: int, plant_id: int, plant_y: int) -> ChunkData:
	var data := ChunkData.new()
	var blocks := PackedByteArray()
	blocks.resize(ChunkData.VOLUME * 2)
	for z in ChunkData.SIZE:
		for x in ChunkData.SIZE:
			blocks.encode_u16(ChunkData.index_of(x, 0, z) << 1, ground_id)
	if plant_id > 0:
		blocks.encode_u16(ChunkData.index_of(8, plant_y, 8) << 1, plant_id)
	data.blocks = blocks
	return data


func _count(data: ChunkData) -> int:
	var arrays := ChunkMesher.mesh_chunk(Vector3i.ZERO, data, null, {}, {}, true)
	if arrays.is_empty():
		return 0
	return (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()

extends Probe
## Sonde `--probe-dungeon` — extraite de main.gd le 2026-07-28 (audit architectural).
## Logique inchangée : seuls les accès à la scène ont été réécrits
## ($Player -> player, get_tree() -> main.get_tree(), etc.).


## Sonde donjon headless (2026-07-21, dimension séparée) : trouve une cellule
## donjon, s'approche (compte à rebours 3 s + écran de chargement), vérifie
## l'entrée en dimension, le sol réel, le boss, mine un bloc (diff persistant),
## sort par le marqueur, vérifie le retour overworld. Aucune capture d'écran :
## sûre en --headless (contrairement à --test-input).
func run() -> void:
	await main.get_tree().process_frame
	var gg := WorldManager.generator
	var donjon_cell := Vector2i.ZERO
	var found := false
	for dcx in range(-40, 41):
		if found:
			break
		for dcz in range(-40, 41):
			var c := Vector2i(dcx, dcz)
			# Règle AUTORITAIRE (2026-08-02) : `has_dungeon` et non un tirage
			# de POI refait ici. Ces sondes en portaient chacune leur copie
			# — biome puis `pois_at_cell` — et le jour où « sol émergé » s'y
			# est ajouté, elles ont continué à désigner une cellule que le
			# monde ne bâtit plus : tour absente, échantillons vides.
			if gg.has_dungeon(c):
				donjon_cell = c
				found = true
				break
	print("[DONJONPROBE] cellule trouvée=%s %s" % [found, donjon_cell])
	if not found:
		main.get_tree().quit(1)
		return
	# Entrée par la TOUR (2026-07-27) : on ne franchit plus un périmètre
	# invisible, on pénètre dans la tour qui matérialise le donjon. La sonde
	# se place donc au centre de son volume intérieur.
	var centre := POIGenerator.cell_center_world(donjon_cell)
	var ground := int(floor(gg.height_at(centre.x, centre.y)))
	# La tour doit exister EN BLOCS : un mur plein et un intérieur creux.
	# Termitière (2026-07-27) : masse organique occupant TOUTE la cellule.
	# On vérifie sa silhouette, ses cavités et sa palette.
	var seed_val: int = WorldManager.world_seed
	var hauteur_centre := DungeonTower.height_at(donjon_cell, centre.x, centre.y, seed_val)
	var hauteur_bord := DungeonTower.height_at(donjon_cell,
			centre.x + int(DungeonTower.RADIUS) - 2, centre.y, seed_val)
	var hors := DungeonTower.height_at(donjon_cell,
			centre.x + int(DungeonTower.RADIUS) + 8, centre.y, seed_val)
	print("[DONJONPROBE] silhouette : centre=%.1f bord=%.1f hors emprise=%.1f (fût plein, 0 dehors)" % [
			hauteur_centre, hauteur_bord, hors])
	# ATTENTION, ce test a changé de sens le 2026-08-02. Il exigeait
	# `centre > bord` — la signature d'un DÔME, qui décroît vers ses bords.
	# La structure est désormais une TOUR : hauteur constante sur tout le fût,
	# et le pourtour est même PLUS HAUT (tourelles et créneaux). Garder
	# l'ancienne assertion faisait échouer la sonde sur une tour parfaitement
	# correcte. Ce qui reste vrai, et qui compte vraiment :
	#   - la masse est haute (c'est un point de repère visible de loin) ;
	#   - elle s'arrête NET hors de l'emprise, sinon elle mord sur la cellule
	#     voisine (défaut réellement attrapé ici le 2026-08-02).
	if hauteur_centre <= 20.0 or hauteur_bord <= 20.0 or hors != 0.0:
		print("[DONJONPROBE] ÉCHEC : silhouette incorrecte.")
		main.get_tree().quit(1)
		return

	# Emprise : elle doit couvrir la CELLULE, pas un chunk (correction auteur).
	print("[DONJONPROBE] emprise : rayon=%.0f blocs (cellule=%d, chunk=%d)" % [
			DungeonTower.RADIUS, ClaimManager.CELL_SIZE, ChunkData.SIZE])
	if DungeonTower.RADIUS * 2.0 <= float(ChunkData.SIZE) * 2.0:
		main.get_tree().quit(1)
		return

	# Variété : la masse doit mélanger PLUSIEURS matériaux de la palette.
	var vus := {}
	var pleins := 0
	var creux := 0
	for i in 4000:
		var ox := randi_range(-40, 40)
		var oz := randi_range(-40, 40)
		var oy := randi_range(1, 45)
		var b := WorldManager.block_at_world(Vector3i(centre.x + ox, ground + oy, centre.y + oz))
		if b == 0:
			creux += 1
			continue
		var nom: String = GameData.material_by_runtime[b]
		# La palette n'est plus une constante depuis le 2026-08-02 : chaque
		# cellule tire ses pierres taillées. On vérifie donc l'APPARTENANCE À
		# LA FAMILLE (tag `pierre_taillee`) et non l'égalité à une liste figée.
		if "pierre_taillee" in (GameData.materials[nom].get("tags", []) as Array):
			vus[nom] = true
			pleins += 1
	print("[DONJONPROBE] échantillon : %d pleins, %d vides — %d matériaux de palette distincts %s" % [
			pleins, creux, vus.size(), vus.keys()])
	# Seuil abaissé de 3 à 2 : la tour en pierre taillée a une palette de DEUX
	# roches (maçonnerie + accent des moulures) là où la termitière en avait
	# cinq. Exiger 3 ferait échouer la sonde sur une tour parfaitement correcte.
	if vus.size() < 2 or pleins == 0 or creux == 0:
		print("[DONJONPROBE] ÉCHEC : pas assez de variété, ou aucune cavité (salle/tunnels).")
		main.get_tree().quit(1)
		return

	# Incassabilité conservée, mais elle a changé de NATURE le 2026-08-02 : elle
	# ne tient plus à un tag du matériau (la tour est en pierre taillée, un
	# matériau de construction que le joueur pose lui-même — le rendre
	# incassable aurait figé toutes ses propres bâtisses) mais à
	# l'EMPLACEMENT. On vérifie donc les deux faces de la règle : scellé dans
	# la tour, PAS scellé juste à côté.
	var dedans := WorldManager.is_sealed_structure(Vector3i(centre.x, ground + 5, centre.y))
	# Point témoin : le COIN de la cellule, et pas « le centre + rayon + 10 ».
	# Plein est à cette distance on est déjà dans la cellule VOISINE, à 58 blocs
	# de son centre — donc à l'intérieur de SA tour si elle en porte une, et le
	# témoin se déclenchait à juste titre. Le coin (62, 62) est à 87 blocs de son
	# propre centre et à plus de 90 de chacun des quatre voisins : c'est le seul
	# endroit d'une cellule garanti hors de toute tour.
	var demi := ClaimManager.CELL_SIZE / 2 - 2
	var dehors := WorldManager.is_sealed_structure(
			Vector3i(centre.x + demi, ground + 5, centre.y + demi))
	print("[DONJONPROBE] structure scellée : dans la tour=%s, hors emprise=%s (attendu true/false)" % [
			dedans, dehors])
	if not dedans or dehors:
		main.get_tree().quit(1)
		return

	# Point d'entrée : une cavité située SOUS la croûte.
	var entree := Vector3i(centre.x, ground + 6, centre.y)
	for essai in 200:
		var tx := centre.x + randi_range(-30, 30)
		var tz := centre.y + randi_range(-30, 30)
		var ty := ground + randi_range(3, 25)
		if DungeonTower.inside_interior(donjon_cell, tx, ty, tz, ground, seed_val):
			entree = Vector3i(tx, ty, tz)
			break
	print("[DONJONPROBE] cavité d'entrée trouvée en %s" % entree)
	camera.position = Vector3(float(entree.x) + 0.5, float(entree.y) + 0.5, float(entree.z) + 0.5)
	await main.get_tree().create_timer(4.5).timeout  # Compte à rebours 3 s + chargement.
	var entered: bool = DungeonManager._in_dungeon
	var dim_ok: bool = WorldManager.active_dimension == &"donjon"
	print("[DONJONPROBE] entré=%s (attendu true) dimension=%s (attendu donjon)" % [entered, WorldManager.active_dimension])
	if not entered:
		main.get_tree().quit(1)
		return
	var feet := camera.global_position - Vector3(0, 1.9, 0)  # EYE_HEIGHT — feet_y = sommet du bloc de sol.
	var floor_pos := Vector3i(floori(feet.x), floori(feet.y + 0.001) - 1, floori(feet.z))
	var floor_id := WorldManager.block_at_world(floor_pos)
	# COMPTE LES BOSS, pas les occupants (corrigé le 2026-08-02). Cette boucle
	# comptait toute créature de la dimension donjon et l'appelait « boss » —
	# exact tant que le boss était le seul habitant, faux dès que les étages ont
	# été peuplés d'ennemis. Le boss se reconnaît à sa méta, posée par
	# `_build_dimension` : c'est le seul marqueur qui le distingue vraiment.
	var boss_count := 0
	var occupants := 0
	for c in CreatureManager.creatures:
		if not (is_instance_valid(c) and c.dimension == &"donjon"):
			continue
		occupants += 1
		if c.has_meta("dungeon_boss_cell"):
			boss_count += 1
	print("[DONJONPROBE] occupants de l'étage : %d (tous types d'ennemis confondus)" % occupants)
	if occupants == 0:
		print("[DONJONPROBE] ÉCHEC : étage désert — le peuplement ne s'est pas fait.")
		main.get_tree().quit(1)
		return
	# Boss ATTENDU ABSENT au premier étage depuis le passage au multi-étage
	# (2026-07-28) : il n'existe plus qu'au dernier, et lui seul nettoie la
	# cellule. Le parcours complet des étages est couvert par --probe-etages.
	print("[DONJONPROBE] sol=%d (attendu != 0) boss=%d (attendu 0 : le boss est au dernier étage)" % [
		floor_id, boss_count])
	# Histogramme des ids matériau émis dans le mesh du chunk d'entrée (debug
	# rendu : un id inattendu ici = bug de meshing, pas de shader).
	var entry_mesh: MeshInstance3D = DungeonManager._dungeon_meshes.get(Vector3i.ZERO)
	if entry_mesh != null:
		var arrays: Array = entry_mesh.mesh.surface_get_arrays(0)
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var histo := {}
		for uv in uvs:
			var mid := int(round(uv.x))
			histo[mid] = int(histo.get(mid, 0)) + 1
		var named := {}
		for mid: int in histo:
			var mat_name: String = GameData.material_by_runtime[mid] if mid < GameData.material_by_runtime.size() else "?%d" % mid
			named[mat_name] = histo[mid]
		print("[DONJONPROBE] ids dans le mesh d'entrée : %s" % [named])
	var mined := WorldManager.set_block(floor_pos, 0)
	var mined_read := WorldManager.block_at_world(floor_pos)
	var edits: Dictionary = DungeonManager.save_state().get("edits", {})
	print("[DONJONPROBE] minage=%s relu=%d (attendu 0) diff_cellules=%d (attendu 1)" % [mined, mined_read, edits.size()])
	var exit_marker := DungeonManager._exit_marker_position(donjon_cell)
	camera.position = Vector3(exit_marker.x, exit_marker.y + 2.9, exit_marker.z)
	await main.get_tree().create_timer(1.8).timeout
	var back: bool = not DungeonManager._in_dungeon and WorldManager.active_dimension == &"overworld"
	print("[DONJONPROBE] retour overworld=%s (attendu true)" % back)
	var ok: bool = entered and dim_ok and floor_id != 0 and boss_count == 0 \
		and mined and mined_read == 0 and edits.size() == 1 and back
	print("[DONJONPROBE] RÉSULTAT : %s" % ("OK" if ok else "ÉCHEC"))
	main.get_tree().quit(0 if ok else 1)

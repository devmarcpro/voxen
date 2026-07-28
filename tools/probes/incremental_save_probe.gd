extends Probe
## Sonde `--probe-save-incr` — extraite de main.gd le 2026-07-28 (audit architectural).
## Logique inchangée : seuls les accès à la scène ont été réécrits
## ($Player -> player, get_tree() -> main.get_tree(), etc.).


## Sonde sauvegarde incrémentale (E.10/G.7) : vérifie qu'un autosave ne
## réécrit QUE les chunks retouchés, que les autres restent intacts sur
## disque, et qu'une relecture complète retrouve bien TOUS les blocs — la
## seule façon d'être sûr que « écrire moins » ne veut pas dire « perdre ».
func run() -> void:
	await main.get_tree().process_frame
	var ok := true
	var dir := ProjectSettings.globalize_path(SaveManager.save_dir) + "/chunks/"

	# Trois éditions dans trois chunks DISTINCTS (16 blocs de côté).
	var positions: Array[Vector3i] = []
	for i in 3:
		var x := i * 64
		var y := WorldManager.generator.height_at(x, 0) + 1
		positions.append(Vector3i(x, y, 0))
	var granit: int = GameData.material_runtime_ids.get("granit", 1)
	for pos in positions:
		WorldManager.set_block(pos, granit)
	SaveManager.save_now(true)

	var files: Array[String] = []
	for pos in positions:
		files.append("%d_%d_%d.bin" % [pos.x >> 4, pos.y >> 4, pos.z >> 4])
	var mtimes := {}
	for f in files:
		mtimes[f] = FileAccess.get_modified_time(dir + f)
	var tous_ecrits := true
	for f in files:
		if int(mtimes[f]) == 0:
			tous_ecrits = false
	print("[INCR] 3 chunks édités puis sauvés : tous présents sur disque=%s" % tous_ecrits)
	ok = ok and tous_ecrits

	# La résolution de date de modification est la seconde : attendre avant de
	# resauver, sinon on ne saurait pas distinguer « réécrit » de « intact ».
	await main.get_tree().create_timer(1.2).timeout

	# UNE seule édition supplémentaire, dans le premier chunk.
	WorldManager.set_block(positions[0] + Vector3i(1, 0, 0), granit)
	SaveManager.save_now(true)

	var reecrits: Array[String] = []
	for f in files:
		if FileAccess.get_modified_time(dir + f) != int(mtimes[f]):
			reecrits.append(f)
	print("[INCR] après 1 édition : %d fichier(s) réécrit(s) sur %d (attendu 1)" % [
			reecrits.size(), files.size()])
	ok = ok and reecrits.size() == 1 and reecrits[0] == files[0]

	# Les fichiers NON réécrits doivent rester lisibles et complets : on
	# recharge tout et on vérifie que les trois éditions sont là.
	SaveManager.load_world_at(SaveManager.save_dir)
	SaveManager.apply_pending_state()
	var relus := 0
	for pos in positions:
		if WorldManager.block_at_world(pos) == granit:
			relus += 1
	print("[INCR] relecture complète : %d/3 blocs retrouvés (attendu 3)" % relus)
	ok = ok and relus == 3

	print("[INCR] RÉSULTAT : %s" % ("OK" if ok else "ÉCHEC"))
	main.get_tree().quit(0 if ok else 1)

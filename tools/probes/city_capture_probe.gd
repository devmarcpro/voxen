extends Probe
## Sonde `--test-city` — extraite de main.gd le 2026-07-28 (audit architectural).
## Logique inchangée : seuls les accès à la scène ont été réécrits
## ($Player -> player, get_tree() -> main.get_tree(), etc.).


## Capture visuelle d'un village (fenêtré, --test-city) : survol en oblique,
## laisse les chunks se streamer, capture. Mesure aussi le fps statique
## au-dessus de la ville (perf de la génération de villes).
func run() -> void:
	await main.get_tree().process_frame
	var g := WorldManager.generator
	var found := Vector2i.ZERO
	var layout := {}
	# Cherche de préférence un village plus grand (T=5, plus lisible en photo).
	for cx in range(-60, 61):
		if int(layout.get("T", 0)) >= 5:
			break
		for cz in range(-60, 61):
			var l := g.city_at_cell(Vector2i(cx, cz))
			if not l.is_empty() and (layout.is_empty() or int(l["T"]) > int(layout["T"])):
				found = Vector2i(cx, cz)
				layout = l
				if int(l["T"]) >= 5:
					break
	if layout.is_empty():
		print("[CITYCAP] aucun village trouvé")
		main.get_tree().quit(1)
		return
	var wx := found.x * 128 + 64
	var wz := found.y * 128 + 64
	var plateau: int = layout["plateau_y"]
	print("[CITYCAP] village cellule=%s T=%d bâtiments=%d, survol pour capture" % [found, layout["T"], layout["buildings"]])
	camera.input_locked = true
	player.input_locked = true
	camera.position = Vector3(wx - 34, plateau + 26, wz - 34)
	camera.look_at(Vector3(wx, plateau + 2, wz), Vector3.UP)
	WorldManager.update_center(camera.position)
	# Laisser le streaming se déclencher PUIS se vider (attente minimale + file).
	await main.get_tree().create_timer(1.5).timeout
	var waited := 1.5
	while int(WorldManager.stats()["queue"]) > 0 and waited < 25.0:
		await main.get_tree().process_frame
		waited += main.get_process_delta_time()
	await main.get_tree().create_timer(1.0).timeout
	await screenshot("city_screenshot.png")
	print("[CITYCAP] capture : city_screenshot.png (streaming en %.1f s)" % waited)
	main.get_tree().quit(0)

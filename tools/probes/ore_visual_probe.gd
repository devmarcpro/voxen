extends Probe
## Sonde `--test-ore` — extraite de main.gd le 2026-07-28 (audit architectural).
## Logique inchangée : seuls les accès à la scène ont été réécrits
## ($Player -> player, get_tree() -> main.get_tree(), etc.).


## Capture souterraine (fenêtré, --test-ore) : trouve un filon, creuse une
## salle autour pour l'exposer, et capture — pour vérifier que le minerai se
## fond dans sa ROCHE hôte (masque de pépites, 2026-07-24).
func run() -> void:
	await main.get_tree().process_frame
	camera.input_locked = true
	player.input_locked = true
	var g := WorldManager.generator
	var ore_ids := {}
	for mid: String in GameData.materials:
		if GameData.materials[mid]["category"] in ["minerai", "mineral", "cristal", "fossile"]:
			ore_ids[int(GameData.material_runtime_ids[mid])] = true
	# Cherche un bloc de minerai à profondeur moyenne autour de l'origine.
	var found := Vector3i.ZERO
	var ok := false
	for cx in range(0, 60):
		if ok:
			break
		for cz in range(0, 60):
			var h := g.height_at(cx, cz)
			for d in range(40, 160):
				var wy := h - d
				if ore_ids.has(g.block_at(cx, wy, cz)):
					found = Vector3i(cx, wy, cz)
					ok = true
					break
			if ok:
				break
	print("[OREVIS] filon trouvé=%s à %s (%s)" % [ok, found, GameData.material_by_runtime[g.block_at(found.x, found.y, found.z)] if ok else "-"])
	if not ok:
		main.get_tree().quit(1)
		return
	# Creuse une salle autour du filon pour l'exposer.
	for dx in range(-4, 5):
		for dy in range(-3, 4):
			for dz in range(-4, 5):
				if dx * dx + dz * dz <= 20:
					WorldManager.set_block(found + Vector3i(dx, dy, dz), 0)
	camera.position = Vector3(found.x + 0.5, found.y + 1.0, found.z - 5.0)
	camera.look_at(Vector3(found.x + 0.5, found.y + 0.5, found.z + 4.0), Vector3.UP)
	WorldManager.update_center(camera.position)
	await main.get_tree().create_timer(3.5).timeout
	await screenshot("ore_visual.png")
	print("[OREVIS] capture : ore_visual.png")
	main.get_tree().quit(0)

extends Probe
## Sonde `--test-textures` — extraite de main.gd le 2026-07-28 (audit architectural).
## Logique inchangée : seuls les accès à la scène ont été réécrits
## ($Player -> player, get_tree() -> main.get_tree(), etc.).


## Vitrine des textures procédurales (fenêtré, --test-textures) : pose un mur
## d'échantillons (bois, minerai, lingot, gemme, roche, sable, eau) et capture,
## pour juger chaque matériau au 32px/face (réécriture 2026-07-24).
func run() -> void:
	await main.get_tree().process_frame
	camera.input_locked = true
	player.input_locked = true
	# Matériaux montrés, colonne par colonne (chacun 2 blocs de haut).
	var samples := ["chene", "acajou", "fer", "etain", "or", "lingot_fer", "lingot_or",
		"diamant", "emeraude", "pierre", "granit", "gres", "terre", "brique", "eau"]
	var g := WorldManager.generator
	var base_h := g.height_at(0, 0) + 30  # Bien au-dessus du sol, sur une plateforme neuve.
	# Plateforme de pierre + colonnes d'échantillons devant.
	for i in samples.size():
		var mid: int = GameData.material_runtime_ids.get(samples[i], 0)
		if mid == 0:
			continue
		var wx := i * 2
		for hy in 3:
			WorldManager.set_block(Vector3i(wx, base_h + hy, 0), mid)
			WorldManager.set_block(Vector3i(wx + 1, base_h + hy, 0), mid)
	# Caméra face au mur.
	var center_x := samples.size()  # ~milieu
	camera.position = Vector3(center_x, base_h + 2.0, 14.0)
	camera.look_at(Vector3(center_x, base_h + 1.5, 0.0), Vector3.UP)
	WorldManager.update_center(camera.position)
	await main.get_tree().create_timer(3.0).timeout
	await screenshot("textures_screenshot.png")
	print("[TEXCAP] vitrine capturée : textures_screenshot.png (%d échantillons)" % samples.size())
	# Zoom rapproché sur les 4 premiers (bois + minerais) pour le détail.
	camera.position = Vector3(2.0, base_h + 1.5, 5.0)
	camera.look_at(Vector3(2.0, base_h + 1.0, 0.0), Vector3.UP)
	await main.get_tree().create_timer(1.0).timeout
	await screenshot("textures_closeup.png")
	print("[TEXCAP] gros plan capturé : textures_closeup.png")
	main.get_tree().quit(0)

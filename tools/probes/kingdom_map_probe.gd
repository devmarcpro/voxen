extends Probe
## Sonde `--test-carte` — CAPTURE de la carte du monde avec les royaumes.
##
## Aucune assertion : une carte politique se regarde. Ce qu'on juge ici n'a pas
## d'expression numérique — est-ce que les territoires se distinguent du relief,
## est-ce que les frontières se lisent, est-ce que deux royaumes voisins se
## différencient. `--probe-royaumes` prouve que la géographie est correcte ;
## celle-ci montre si elle est lisible.

const TAG := "SHOTCARTE"


func run() -> void:
	if not can_capture():
		print("[%s] impossible en --headless : relancer AVEC fenêtre." % TAG)
		finish(true, TAG)
		return
	await wait_seconds(2.5)

	# On se place sur un royaume plutôt que sur le point de départ : une carte
	# centrée sur de la terre sauvage ne montrerait rien de ce qu'on veut voir.
	var generator := WorldManager.generator
	var found := Vector2i(0, 0)
	for radius in range(0, 60):
		var hit := false
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if maxi(absi(dx), absi(dz)) != radius:
					continue
				if not generator.kingdom_at_cell(Vector2i(dx, dz)).is_empty():
					found = Vector2i(dx, dz)
					hit = true
					break
			if hit:
				break
		if hit:
			break
	var kingdom := generator.kingdom_at_cell(found)
	print("[%s] centré sur %s : %s" % [TAG, found,
		String(kingdom.get("name", "terres sauvages"))])
	var center := POIGenerator.cell_center_world(found)
	# On NE se teleporte PAS : la carte s ouvre la ou le joueur est. Le saut
	# vers un royaume lointain testait autre chose que ce qu on croyait.
	if false:
		camera.position = Vector3(center.x, camera.position.y, center.y)
	await wait_seconds(0.6)

	var menu := main.get_node_or_null("GameMenu")
	if menu != null:
		var start := Time.get_ticks_msec()
		menu.call("_open_map")
		# La carte se construit en différé : on attend franchement, et on
		# MESURE — j'y ai ajouté une passe de royaumes qui interroge chaque
		# cellule visible et ses voisines, et le coût doit être connu.
		await wait_seconds(75.0)
		print("[%s] carte prête en %d ms" % [TAG, Time.get_ticks_msec() - start])
		await screenshot("carte_royaumes.png")
		print("[%s] %s" % [TAG, capture_path("carte_royaumes.png")])
	finish(true, TAG)

extends Probe
## Sonde `--test-corps` — CAPTURES du corps en jeu réel (fenêtré obligatoire).
##
## Aucune assertion : elle produit des images. Le cadrage, la posture des bras
## et l'échelle de l'arme ne se mesurent pas — ils se regardent. Les autres
## sondes prouvent que la mécanique est juste ; celle-ci montre à quoi ça
## ressemble, ce qui est la seule façon de trancher un « c'est à l'envers ».

const TAG := "SHOTCORPS"


func run() -> void:
	if not can_capture():
		print("[%s] impossible en --headless : relancer AVEC fenêtre." % TAG)
		finish(true, TAG)
		return
	# PLEIN JOUR : une lame de fer gris sur un sol nocturne est indiscernable,
	# et une capture d'inspection qui ne montre rien ne sert a rien. On force
	# midi plutot que de dependre de l'heure du monde charge.
	TickManager.tick_index = int(DayNightManager.TICKS_PER_DAY / 2)
	await wait_seconds(3.0)   # laisser les chunks se mesher

	# Sol propre sous les pieds : une capture sur un terrain accidenté ne dit
	# rien de la posture.
	var stone: int = GameData.material_runtime_ids.get("pierre", 1)
	var base := Vector3i(int(camera.position.x), floori(camera.position.y) - 6, int(camera.position.z))
	for dx in range(-4, 5):
		for dz in range(-4, 5):
			for dy in range(1, 7):
				WorldManager.set_block(Vector3i(base.x + dx, base.y + dy, base.z + dz), 0)
			WorldManager.set_block(Vector3i(base.x + dx, base.y, base.z + dz), stone)
	camera.position = Vector3(float(base.x) + 0.5, float(base.y + 1) + FlyCamera.EYE_HEIGHT, float(base.z) + 0.5)

	player.active_hotbar = 0
	player.selected_slot = 0

	# Plusieurs ARMES, pour juger l'assemblage manche+tête et surtout les
	# positions de main : une dague garde les poings serrés, une lance projette
	# la main avant loin devant. C'est précisément ce qu'aucune sonde logique ne
	# peut valider.
	# TOUT forger d'abord, LIER ensuite. `add_object` réattribue les emplacements
	# libres de la hotbar : lier puis ajouter faisait écraser notre liaison par le
	# kit de départ, et les captures montraient la PIOCHE en croyant montrer l'arme.
	var forged := {}
	for weapon_id: String in ["dague", "epee", "hache_arme", "lance", "espadon"]:
		var crafted := ItemFactory.craft(weapon_id, {"bois": "chene", "minerai": "fer"}, 1.0)
		player.inventory.add_object(crafted)
		forged[weapon_id] = int(crafted["uid"])
	# SERTIE : la gemme doit se voir au bout du bras. C'est le seul juge —
	# --probe-gemme prouve qu'elle existe dans la scène, pas qu'on la distingue.
	var gemmed := ItemFactory.craft("epee",
		{"bois": "chene", "minerai": "fer", "cristal": "emeraude"}, 1.0)
	player.inventory.add_object(gemmed)
	forged["epee_gemme"] = int(gemmed["uid"])
	# BOUCLIER équipé : la main gauche doit apparaître et présenter la PLAQUE,
	# pas sa tranche. Aucune assertion ne juge d'une orientation vue de face.
	player.equipment.equip(ItemFactory.craft("ecu",
		{"bois": "chene", "minerai": "fer"}, 1.0))
	await wait_seconds(0.5)

	for weapon_id: String in forged:
		player.hotbar_bindings[8] = {"kind": "object", "uid": int(forged[weapon_id])}
		player.active_hotbar = 0
		player.selected_slot = 8
		camera.rotation = Vector3(deg_to_rad(-18.0), 0.0, 0.0)
		# Laisser le cycle normal reconstruire l'objet en main.
		await wait_seconds(1.0)
		# TRACE : une capture qui montre un autre objet que celui visé est un
		# faux témoignage. On imprime ce que le joueur tient VRAIMENT.
		var entry: Dictionary = player.held_entry()
		print("[%s] visé=%s · en main=%s" % [TAG, weapon_id,
			entry.get("object", {}).get("item_id", "(rien)") if entry.has("object") else "(vide)"])
		await screenshot("arme_%s.png" % weapon_id)
		print("[%s] %s" % [TAG, capture_path("arme_%s.png" % weapon_id)])

	var angles := [
		["droit_devant", 0.0],
		["regard_bas_30", -30.0],
		["regard_pieds", -75.0],
	]
	for entry: Array in angles:
		camera.rotation = Vector3(deg_to_rad(float(entry[1])), 0.0, 0.0)
		await wait_seconds(0.6)
		await screenshot("corps_%s.png" % entry[0])
		print("[%s] %s" % [TAG, capture_path("corps_%s.png" % entry[0])])

	# CRÉATURE : corps animé + barre de vie. La barre ne s'affiche qu'une fois
	# blessée — on entame donc sa santé, sinon la capture ne montrerait rien.
	camera.rotation = Vector3.ZERO
	await wait_seconds(0.2)
	var forward := -camera.global_basis.z
	forward.y = 0.0
	var spot: Vector3 = camera.global_position + Vector3(0.0, -FlyCamera.EYE_HEIGHT, 0.0) \
		+ forward.normalized() * 3.5
	var mob := CreatureManager.spawn("bandit", spot)
	if mob != null:
		mob.logical_position = spot
		mob.position = spot
		mob.health = mob.health_max * 0.45
		await wait_seconds(0.8)
		await screenshot("mob_barre_de_vie.png")
		print("[%s] %s" % [TAG, capture_path("mob_barre_de_vie.png")])

	# LISIBILITÉ DU COMBAT : indicateur directionnel + chiffres de dégâts.
	# On arme une attaque vers la DROITE puis on la fait toucher, pour que la
	# capture montre à la fois le chevron actif et un chiffre au point d'impact.
	var sword := ItemFactory.craft("epee", {"bois": "chene", "minerai": "fer"}, 1.2)
	player.inventory.add_object(sword)
	player.hotbar_bindings[8] = {"kind": "object", "uid": int(sword["uid"])}
	player.selected_slot = 8
	camera.rotation = Vector3.ZERO
	await wait_seconds(0.4)
	var victim_spot: Vector3 = camera.global_position \
		+ Vector3(0.0, -FlyCamera.EYE_HEIGHT, 0.0) - camera.global_basis.z * 1.2
	var victim := CreatureManager.spawn("bandit", victim_spot)
	if victim != null:
		victim.logical_position = victim_spot
		victim.position = victim_spot
	player.call("_begin_attack")
	player.get("_attack").feed_gesture(Vector2(160.0, 0.0))
	# Laisser l'arme S'ARMER, puis capturer : c'est l'état « menace » que le
	# joueur doit pouvoir lire d'un coup d'œil.
	for i in 30:
		player.call("_advance_attack", 1.0 / 60.0)
	await wait_seconds(0.2)
	await screenshot("combat_arme.png")
	print("[%s] %s" % [TAG, capture_path("combat_arme.png")])
	# Relâcher : la lame part, touche, et le chiffre apparaît à l'impact.
	player.get("_attack").release_input()
	for i in 30:
		player.call("_advance_attack", 1.0 / 60.0)
	player.call("_resolve_pending_hits")
	await wait_seconds(0.15)
	await screenshot("combat_degats.png")
	print("[%s] %s" % [TAG, capture_path("combat_degats.png")])

	# Vue EXTERNE du même corps (avatar distant) : c'est ce que voient les
	# autres joueurs, et ça révèle une posture de bras qu'on ne voit pas de
	# l'intérieur.
	var remote: Node3D = preload("res://scenes/entities/player_body.gd").new()
	main.add_child(remote)
	if remote.setup(false):
		# Regard remis à l'horizontale AVANT de placer l'avatar : sinon on le
		# posait selon l'ancien axe de vue et il sortait du cadre.
		camera.rotation = Vector3.ZERO
		await wait_seconds(0.2)
		remote.apply_remote_pose(camera.global_position
			+ Vector3(0.0, -FlyCamera.EYE_HEIGHT + 0.6, 0.0) - camera.global_basis.z * 2.5, PI, 0.0)
		await wait_seconds(0.6)
		await screenshot("corps_vu_de_face.png")
		print("[%s] %s" % [TAG, capture_path("corps_vu_de_face.png")])
	finish(true, TAG)

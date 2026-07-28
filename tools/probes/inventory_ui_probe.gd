extends Probe
## Sonde `--probe-invui` — extraite de main.gd le 2026-07-28 (audit architectural).
## Logique inchangée : seuls les accès à la scène ont été réécrits
## ($Player -> player, get_tree() -> main.get_tree(), etc.).


## Sonde interface d'inventaire (2026-07-27) : vérifie la correspondance entre
## les lignes AFFICHÉES et les liaisons de hotbar. Un bug visuel a montré le
## badge « assigné » sur toutes les lignes de matériau parce que l'entrée
## d'affichage ne portait pas son id — invisible pour toute sonde qui ne
## regarde que le modèle, d'où celle-ci qui part de l'écran réel.
func run() -> void:
	await main.get_tree().process_frame
	var player: Node = player
	player.apply_default_character()
	# Inventaire LARGEMENT plus grand que la hotbar (comme après un passage au
	# menu de triche) : c'est la situation qui a révélé le bug — des centaines
	# de lignes pour une poignée d'emplacements liés. Un échantillon réduit
	# aurait tout lié d'office et n'aurait rien détecté.
	var ajoutes := 0
	for mid: String in GameData.materials:
		player.inventory.add_material(mid, 50)
		ajoutes += 1
		if ajoutes >= 200:
			break
	player.autofill_hotbar()

	var menu: CanvasLayer = preload("res://scenes/ui/game_menu.gd").new()
	menu.name = "GameMenuProbe"
	main.add_child(menu)
	await main.get_tree().process_frame

	var ok := true
	var entries: Array[Dictionary] = menu._build_inventory_entries()
	print("[INVUI] %d lignes d'inventaire construites" % entries.size())
	ok = ok and entries.size() > 0

	# 1. Toute ligne de matériau doit porter son id — sans lui, toutes les
	# lignes se ressemblent du point de vue des liaisons.
	var sans_id := 0
	for entry in entries:
		if entry.get("kind", "") == "material" and String(entry.get("id", "")) == "":
			sans_id += 1
	print("[INVUI] lignes de matériau sans id : %d (attendu 0)" % sans_id)
	ok = ok and sans_id == 0

	# 2. Le badge « assigné » ne doit apparaître QUE sur les lignes réellement
	# liées — leur nombre doit égaler celui des liaisons résolvables.
	var badges := 0
	for entry in entries:
		if int(player.hotbar_index_of(menu._entry_to_player(entry))) >= 0:
			badges += 1
	var liaisons := 0
	for index: int in player.hotbar_bindings:
		if not player._resolve_binding(player.hotbar_bindings[index]).is_empty():
			liaisons += 1
	print("[INVUI] lignes marquées assignées=%d, liaisons actives=%d (doivent coïncider), sur %d lignes" % [
			badges, liaisons, entries.size()])
	ok = ok and badges == liaisons
	# Le symptôme d'origine : TOUTES les lignes marquées. Avec bien plus de
	# lignes que d'emplacements, une majorité doit rester non assignée.
	print("[INVUI] lignes NON assignées : %d (doit être > 0 — sinon le badge ment)" % [
			entries.size() - badges])
	ok = ok and entries.size() - badges > 0

	# 3. Chaque ligne doit se résoudre vers une liaison DISTINCTE : deux lignes
	# différentes ne peuvent pas désigner le même emplacement.
	var vues := {}
	var collisions := 0
	for entry in entries:
		var binding: Dictionary = player._binding_for(menu._entry_to_player(entry))
		if binding.is_empty():
			continue
		var key := "%s|%s|%s" % [binding.get("kind", ""), binding.get("id", ""), binding.get("uid", "")]
		if vues.has(key):
			collisions += 1
		vues[key] = true
	print("[INVUI] lignes se résolvant vers la même liaison : %d (attendu 0)" % collisions)
	ok = ok and collisions == 0

	# 4. Assignation puis lecture : lier une ligne doit la marquer, elle seule.
	var cible: Dictionary = {}
	for entry in entries:
		if entry.get("kind", "") == "material":
			cible = entry
			break
	if not cible.is_empty():
		var slot := 40  # Banque 5, emplacement 5 — hors des liaisons de départ.
		player.bind_hotbar(slot, menu._entry_to_player(cible))
		var marquees := 0
		for entry in entries:
			if int(player.hotbar_index_of(menu._entry_to_player(entry))) == slot:
				marquees += 1
		print("[INVUI] après assignation de « %s » : %d ligne(s) marquée(s) (attendu 1)" % [
				String(cible.get("id", "?")), marquees])
		ok = ok and marquees == 1

	print("[INVUI] RÉSULTAT : %s" % ("OK" if ok else "ÉCHEC"))
	main.get_tree().quit(0 if ok else 1)

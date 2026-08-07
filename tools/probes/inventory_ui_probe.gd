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
	var ok_autofill := true
	var ajoutes := 0
	for mid: String in GameData.materials:
		player.inventory.add_material(mid, 50)
		ajoutes += 1
		if ajoutes >= 200:
			break
	player.autofill_hotbar()

	# --- L'AUTO-REMPLISSAGE (2026-08-07) ---
	#
	# CE QUI EST DÉFENDU : tout ce qu'on obtient doit atterrir dans un
	# emplacement libre, quel que soit le CHEMIN par lequel on l'obtient. Le
	# remplissage n'était appelé qu'à trois endroits (kit de départ, création de
	# personnage, dépeçage) : miner, ramasser, forger ou acheter versaient dans
	# un inventaire que la hotbar ne montrait pas. Il est désormais branché sur
	# le signal `gained` de l'inventaire, c'est-à-dire sur ses trois seules
	# portes d'entrée.
	# ON LIBÈRE UN EMPLACEMENT D'ABORD. La sonde a rempli l'inventaire de deux
	# cents matériaux : la hotbar est pleine, et un gain de plus n'a nulle part
	# où aller. Sans cette libération, le test mesurait « rien ne bouge » et
	# l'aurait appelé un échec — vrai constat, mauvaise conclusion.
	# ON LAISSE D'ABORD RETOMBER LA POUSSIÈRE. Les deux cents matériaux ajoutés
	# ci-dessus ont chacun émis `gained` ; leur liaison est différée d'une frame.
	# Sans cette attente, la file contient deux cents entrées ET la dague, la
	# seule place libérée revient au premier de la file, et le test conclut que
	# la dague n'a pas été liée alors que le mécanisme a parfaitement marché.
	await main.get_tree().process_frame
	var freed := -1
	for index: int in player.hotbar_bindings.keys():
		if index % int(player.HOTBAR_SLOTS) != int(player.COMBAT_SLOT):
			freed = index
			break
	player.unbind_hotbar(freed)
	var before: int = player.hotbar_bindings.size()
	var gagne: Dictionary = ItemFactory.craft("dague", {"bois": "chene", "minerai": "fer"}, 1.0)
	player.inventory.add_object(gagne)
	# Le remplissage est DIFFÉRÉ (une fois par frame, pas une fois par unité
	# gagnée) : mesurer tout de suite ne verrait rien et conclurait à tort.
	await main.get_tree().process_frame
	var place: int = player.hotbar_index_of({"kind": "object", "object": gagne})
	print("[INVUI] liaisons %d -> %d après un gain ; la dague est à l'emplacement %d (attendu >= 0)" % [
			before, player.hotbar_bindings.size(), place])
	ok_autofill = place >= 0

	# L'EMPLACEMENT DE COMBAT NE DOIT JAMAIS ÊTRE REMPLI : il suit l'arme
	# équipée. `bind_hotbar` le refuse, mais le remplissage écrit dans le
	# dictionnaire DIRECTEMENT — le garde-fou ne le couvrait pas, et un premier
	# bloc miné aurait chassé l'arme de la main.
	var combat_pris := false
	for index: int in player.hotbar_bindings:
		if index % player.HOTBAR_SLOTS == player.COMBAT_SLOT:
			combat_pris = true
	print("[INVUI] emplacement de combat rempli par l'auto-remplissage : %s (attendu non)" % (
			"OUI" if combat_pris else "non"))
	ok_autofill = ok_autofill and not combat_pris

	var menu: CanvasLayer = preload("res://scenes/ui/game_menu.gd").new()
	menu.name = "GameMenuProbe"
	main.add_child(menu)
	await main.get_tree().process_frame

	var ok := ok_autofill
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

	ok = await _check_weapon_icons() and ok

	print("[INVUI] RÉSULTAT : %s" % ("OK" if ok else "ÉCHEC"))
	main.get_tree().quit(0 if ok else 1)


## L'ICÔNE D'UNE ARME EST SON MODÈLE (2026-08-02, demande de l'auteur). Elle
## venait de PNG peints à la main : une épée en granit noir et une épée en
## cuivre partageaient la même image, et une pièce re-coupée gardait l'ancienne
## icône. Elle est désormais RENDUE depuis l'assemblage réellement porté.
##
## Ce qui se vérifie ici, et qu'aucun coup d'œil ne donne : le rendu aboutit
## (une image opaque, pas une case vide), deux MATÉRIAUX différents donnent deux
## icônes différentes — preuve que l'icône suit l'objet et non son type —, et
## l'arme remplit sa vignette.
func _check_weapon_icons() -> bool:
	var item: Dictionary = GameData.items["epee"]
	var iron: Dictionary = ItemFactory.craft("epee", {"bois": "chene", "minerai": "fer"}, 1.0)
	var copper: Dictionary = ItemFactory.craft("epee", {"bois": "ebene", "minerai": "cuivre"}, 1.0)
	# Premier appel : le rendu est ENFILÉ et l'on reçoit le repli. C'est le
	# contrat — aucun écran ne doit attendre un readback GPU.
	WeaponPreview.item_icon(item, iron["materials"], 48)
	WeaponPreview.item_icon(item, copper["materials"], 48)
	# Un rendu par frame : on laisse largement le temps aux deux.
	for i in 40:
		await main.get_tree().process_frame
	var tex_iron: Texture2D = WeaponPreview.item_icon(item, iron["materials"], 48)
	var tex_copper: Texture2D = WeaponPreview.item_icon(item, copper["materials"], 48)
	var rendered: bool = tex_iron != null and tex_copper != null
	print("[INVUI] icône rendue depuis le modèle : fer=%s cuivre=%s : %s" % [
		tex_iron != null, tex_copper != null, "OK" if rendered else "ÉCHEC"])
	if not rendered:
		return false
	# Deux matériaux, deux images. Comparer les PIXELS et non les références :
	# un cache mal calé rendrait la même texture pour les deux sans qu'on le voie.
	var a := tex_iron.get_image()
	var b := tex_copper.get_image()
	var differs: bool = a.get_size() == b.get_size() and a.get_data() != b.get_data()
	print("[INVUI] deux matériaux donnent deux icônes : %s" % [
		"OK" if differs else "ÉCHEC (image identique)"])
	# Et l'arme doit OCCUPER sa case : une image quasi vide passerait le test
	# d'opacité tout en étant illisible.
	var filled := 0
	var total := 0
	for y in range(0, a.get_height(), 2):
		for x in range(0, a.get_width(), 2):
			total += 1
			if a.get_pixel(x, y).a > 0.05:
				filled += 1
	var ratio := float(filled) / maxf(float(total), 1.0)
	var framed: bool = ratio > 0.05
	print("[INVUI] l'arme remplit sa vignette (%.0f %% de pixels) : %s" % [
		ratio * 100.0, "OK" if framed else "ÉCHEC"])
	return differs and framed

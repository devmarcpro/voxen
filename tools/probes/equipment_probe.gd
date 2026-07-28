extends Probe
## Sonde `--probe-equipement` — extraite de main.gd le 2026-07-28 (audit architectural).
## Logique inchangée : seuls les accès à la scène ont été réécrits
## ($Player -> player, get_tree() -> main.get_tree(), etc.).


## Sonde équipement headless (6.2/A.4.2) : vérifie les emplacements, le
## craft d'armure, les dés de réduction, l'aller-retour inventaire↔slots
## (aucune perte ni doublon), le poids porté et la sauvegarde/restauration.
func run() -> void:
	await main.get_tree().process_frame
	var player: Node = player
	player.apply_default_character()
	var ok := true

	# 1. Données : les 5 pièces d'armure existent et pointent un emplacement
	# qui contribue réellement à la protection (A.4.2).
	var armors: Array[String] = []
	for iid: String in GameData.items:
		if String((GameData.items[iid] as Dictionary).get("type", "")) == "armure":
			armors.append(iid)
	armors.sort()
	print("[EQUIP] armures en données : %d %s" % [armors.size(), armors])
	ok = ok and armors.size() >= 5

	# 2. Aucune armure portée → AUCUNE réduction (E.3 : pas de 1d2 gratuit).
	var naked_dice: String = player.armor_dice()
	print("[EQUIP] sans armure : dés=« %s » (attendu vide)" % naked_dice)
	ok = ok and naked_dice == ""

	# 3. Craft + équipement des 5 pièces. L'instance est DÉPLACÉE : le nombre
	# total d'objets (inventaire + équipement) doit rester constant.
	var mats := {"minerai": "fer", "textile": "lin"}
	var before_objects: int = player.inventory.objects.size()
	for iid in armors:
		player.inventory.add_object(ItemFactory.craft(iid, mats, 1.2))
	var with_armor: int = player.inventory.objects.size()
	for iid in armors:
		var idx := -1
		for i in player.inventory.objects.size():
			if String((player.inventory.objects[i] as Dictionary).get("item_id", "")) == iid:
				idx = i
				break
		if idx < 0:
			continue
		for entry: Dictionary in player.all_entries():
			if entry.get("kind", "") == "object" and entry["object"] == player.inventory.objects[idx]:
				player.bind_hotbar(player.active_hotbar * player.HOTBAR_SLOTS + player.selected_slot, entry)
				break
		player._try_equip()
	var total_after: int = player.inventory.objects.size() + player.equipment.slots.size()
	var conserved := total_after == with_armor
	print("[EQUIP] objets : départ=%d +5 armures=%d après équipement inv=%d + portés=%d = %d (attendu %d)" % [
			before_objects, with_armor, player.inventory.objects.size(),
			player.equipment.slots.size(), total_after, with_armor])
	ok = ok and conserved and player.equipment.slots.size() == 5

	# 4. Dés de réduction : notation valide, et une cuirasse de fer qualité 1.2
	# doit peser plus qu'une botte (facteur torse 1.0 vs pieds 0.3).
	var dice: String = player.armor_dice()
	var torse: String = Equipment.piece_dice(player.equipment.equipped("torse"), "torse")
	var pieds: String = Equipment.piece_dice(player.equipment.equipped("pieds"), "pieds")
	var faces_ok := int(torse.split("d")[1]) > int(pieds.split("d")[1])
	print("[EQUIP] dés totaux=%s | torse=%s pieds=%s (torse doit dominer : %s)" % [dice, torse, pieds, faces_ok])
	ok = ok and dice.begins_with("5d") and faces_ok

	# 5. La mitigation mord vraiment : sur 400 coups identiques, l'armure doit
	# réduire les dégâts moyens encaissés (E.3, réduction = jet des dés).
	var raw_total := 0
	var mitigated_total := 0
	for i in 400:
		raw_total += int(CombatResolver.resolve_attack(5, 5, 5, 0, 0, "2d6", 20.0, 1.0, false, "")["damage"])
		mitigated_total += int(CombatResolver.resolve_attack(5, 5, 5, 0, 0, "2d6", 20.0, 1.0, false, dice)["damage"])
	var mitigation_ok := mitigated_total < raw_total
	print("[EQUIP] dégâts cumulés sur 400 coups : sans armure=%d avec=%d (réduction=%s)" % [
			raw_total, mitigated_total, mitigation_ok])
	ok = ok and mitigation_ok

	# 6. Poids porté : A.4.2 compte l'équipement dans la charge.
	var carried: float = player.carried_weight()
	var inv_only: float = player.inventory.total_weight()
	print("[EQUIP] charge : inventaire=%.1f total avec équipement=%.1f (doit être supérieur)" % [inv_only, carried])
	ok = ok and carried > inv_only

	# 7. Sauvegarde/restauration : les pièces portées survivent au cycle.
	var state: Dictionary = player.save_state()
	player.equipment.slots.clear()
	player.restore_state(state)
	var restored: int = player.equipment.slots.size()
	print("[EQUIP] après sauvegarde/chargement : %d pièces portées (attendu 5)" % restored)
	ok = ok and restored == 5

	# 8. Retrait : la pièce revient à l'inventaire.
	var inv_before: int = player.inventory.objects.size()
	player.unequip_slot("torse")
	var unequip_ok: bool = player.inventory.objects.size() == inv_before + 1 \
			and player.equipment.equipped("torse").is_empty()
	print("[EQUIP] retrait du torse : rendu à l'inventaire=%s" % unequip_ok)
	ok = ok and unequip_ok

	print("[EQUIP] RÉSULTAT : %s" % ("OK" if ok else "ÉCHEC"))
	main.get_tree().quit(0 if ok else 1)

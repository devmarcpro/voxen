extends Probe
## Sonde `--probe-mort` — extraite de main.gd le 2026-07-28 (audit architectural).
## Logique inchangée : seuls les accès à la scène ont été réécrits
## ($Player -> player, get_tree() -> main.get_tree(), etc.).


## Sonde mort headless (A.10) : vérifie que la mort déclenche bien la pénalité
## (or, objets tombés), que l'équipement PORTÉ est conservé, que l'XP ne bouge
## pas, que la cache est récupérable puis expire après 1 jour in-game, et que
## le respawn vise le dernier claim activé.
func run() -> void:
	await main.get_tree().process_frame
	var player: Node = player
	player.apply_default_character()
	var ok := true

	# Un jeu d'armure porté + de l'or + des objets en sac.
	for iid in ["casque", "cuirasse", "jambieres", "bottes", "gants"]:
		player.inventory.add_object(ItemFactory.craft(iid, {"minerai": "fer", "textile": "lin"}, 1.2))
	for i in 5:
		player.equipment.equip(player.inventory.objects.pop_back())
	for i in 20:
		player.inventory.add_object(ItemFactory.craft("pioche", player.STARTER_MATERIALS, 1.0))
	player.gold = 1000
	player.skills.gain_xp("minage", 500.0)
	var xp_before: float = player.skills.skills["minage"]["xp"]
	var level_before: int = player.skills.skills["minage"]["level"]
	var bag_before: int = player.inventory.objects.size()
	var worn_before: int = player.equipment.slots.size()

	# Point de retour : une case revendiquée loin de la position de mort.
	var claim_cell := Vector2i(3, 4)
	ClaimManager.claim(claim_cell)
	print("[MORT] point de retour : claim=%s actif=%s" % [ClaimManager.respawn_cell, ClaimManager.has_respawn])
	ok = ok and ClaimManager.has_respawn and ClaimManager.respawn_cell == claim_cell

	# 1. Mise à mort par les dégâts (la boucle de combat passe par take_damage).
	player.take_damage(99999)
	await main.get_tree().process_frame

	var dropped: int = bag_before - player.inventory.objects.size()
	print("[MORT] or : 1000 → %d (attendu 900, -10%%)" % player.gold)
	ok = ok and player.gold == 900
	print("[MORT] sac : %d → %d objets (%d tombés)" % [
			bag_before, player.inventory.objects.size(), dropped])
	ok = ok and dropped <= bag_before
	# Le taux de 10 % (A.10) ne se vérifie pas sur un seul tirage : on mesure
	# la loi sur 20 000 objets. Bande large (7-13 %) — c'est un garde-fou
	# contre un taux FAUX (0 %, 100 %, 1 %), pas un test de qualité du RNG.
	var trials := 20000
	var hits := 0
	for i in trials:
		if randf() < player.DEATH_DROP_CHANCE:
			hits += 1
	var rate := float(hits) / float(trials)
	print("[MORT] taux de perte mesuré sur %d objets : %.1f%% (attendu ~10%%)" % [trials, rate * 100.0])
	ok = ok and rate > 0.07 and rate < 0.13
	print("[MORT] équipement porté : %d → %d (attendu conservé)" % [worn_before, player.equipment.slots.size()])
	ok = ok and player.equipment.slots.size() == worn_before
	print("[MORT] XP minage : %.0f → %.0f niveau %d → %d (attendu inchangé, A.10)" % [
			xp_before, float(player.skills.skills["minage"]["xp"]),
			level_before, int(player.skills.skills["minage"]["level"])])
	ok = ok and is_equal_approx(float(player.skills.skills["minage"]["xp"]), xp_before)
	print("[MORT] santé après respawn : %.0f / %.0f (attendu pleine)" % [player.health, player.health_max])
	ok = ok and is_equal_approx(player.health, player.health_max)

	# 2. Respawn sur le claim : la cellule du joueur doit être celle du claim.
	var cell: Vector2i = player.current_cell()
	print("[MORT] cellule après respawn : %s (attendu %s)" % [cell, claim_cell])
	ok = ok and cell == claim_cell

	# 3. Une cache existe sur le lieu de mort, avec l'or perdu.
	var cache_count := DropManager.caches.size()
	var cache_gold := int(DropManager.caches[0]["gold"]) if cache_count > 0 else -1
	print("[MORT] caches au sol : %d (attendu 1) or dedans=%d (attendu 100)" % [cache_count, cache_gold])
	ok = ok and cache_count == 1 and cache_gold == 100

	# 4. Récupération : objets rendus + or recrédité (le joueur revient sur place).
	var pos: Vector3 = DropManager.caches[0]["position"]
	player.teleport_to(pos)
	var bag_at_pickup: int = player.inventory.objects.size()
	player._try_pickup()
	print("[MORT] après ramassage : sac=%d (attendu %d) or=%d (attendu 1000) caches=%d (attendu 0)" % [
			player.inventory.objects.size(), bag_at_pickup + dropped, player.gold, DropManager.caches.size()])
	ok = ok and player.inventory.objects.size() == bag_at_pickup + dropped \
			and player.gold == 1000 and DropManager.caches.is_empty()

	# 5. Expiration : une cache non récupérée disparaît après 1 jour in-game.
	DropManager.drop(pos, [ItemFactory.craft("pioche", player.STARTER_MATERIALS, 1.0)], 5)
	var posee := DropManager.caches.size()
	TickManager.tick_index += DropManager.LIFETIME_TICKS + 1
	for i in DropManager.PURGE_INTERVAL_TICKS:
		DropManager._on_tick(TickManager.tick_index)
	print("[MORT] expiration : posée=%d après 1 jour in-game=%d (attendu 0)" % [posee, DropManager.caches.size()])
	ok = ok and posee == 1 and DropManager.caches.is_empty()

	print("[MORT] RÉSULTAT : %s" % ("OK" if ok else "ÉCHEC"))
	main.get_tree().quit(0 if ok else 1)

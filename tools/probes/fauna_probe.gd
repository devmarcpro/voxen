extends Probe
## Sonde `--probe-faune` — extraite de main.gd le 2026-07-28 (audit architectural).
## Logique inchangée : seuls les accès à la scène ont été réécrits
## ($Player -> player, get_tree() -> main.get_tree(), etc.).


## Sonde faune headless (F.3/B.5) : vérifie le catalogue chargé, la cohérence
## de la répartition par biome (aucun ours polaire dans le désert), le fait
## que les civils ne spawnent jamais en pleine nature, et les profils d'IA
## (fuite, riposte d'une bête sauvage).
func run() -> void:
	await main.get_tree().process_frame
	var ok := true

	# 1. Catalogue : F.3 énumère 37 fiches (l'en-tête annonce 34 — écart du GDD).
	var by_profile := {}
	for cid: String in GameData.creatures:
		var profile := String((GameData.creatures[cid] as Dictionary).get("ai_profile", "?"))
		by_profile[profile] = int(by_profile.get(profile, 0)) + 1
	print("[FAUNE] créatures chargées : %d — par profil : %s" % [GameData.creatures.size(), by_profile])
	ok = ok and GameData.creatures.size() >= 37

	# 2. Pool de spawn : uniquement des créatures à biome_tags (pas de civils).
	var pool: Array[String] = CreatureManager._spawn_pool
	var civils_in_pool: Array[String] = []
	for cid in pool:
		if String((GameData.creatures[cid] as Dictionary).get("ai_profile", "")) == "civil":
			civils_in_pool.append(cid)
	print("[FAUNE] pool de spawn : %d créatures, civils dedans=%s (attendu aucun)" % [
			pool.size(), civils_in_pool])
	ok = ok and pool.size() > 0 and civils_in_pool.is_empty()

	# 3. Cohérence par biome : on échantillonne le monde et on vérifie que
	# chaque créature tirée déclare bien un tag du biome de l'endroit.
	var gen := WorldManager.generator
	var sampled := 0
	var mismatches := 0
	var per_biome := {}
	for i in 400:
		var x := randi_range(-4000, 4000)
		var z := randi_range(-4000, 4000)
		var biome: Dictionary = gen.biome_at(x, z)
		if biome.is_empty():
			continue
		var cid: String = CreatureManager._pick_for_biome(x, z)
		if cid == "":
			continue
		sampled += 1
		var biome_id := String(biome.get("id", "?"))
		if not per_biome.has(biome_id):
			per_biome[biome_id] = {}
		per_biome[biome_id][cid] = true
		var tags: Array = (GameData.creatures[cid].get("world_gen", {}) as Dictionary).get("biome_tags", [])
		var matched := false
		for tag: String in tags:
			if tag in (biome.get("tags", []) as Array):
				matched = true
				break
		if not matched:
			mismatches += 1
			print("[FAUNE]   INCOHÉRENT : %s tiré en %s" % [cid, biome_id])
	print("[FAUNE] %d tirages sur %d biomes : %d incohérences (attendu 0)" % [
			sampled, per_biome.size(), mismatches])
	ok = ok and sampled > 0 and mismatches == 0
	var biome_ids: Array = per_biome.keys()
	biome_ids.sort()
	for bid: String in biome_ids:
		var names: Array = (per_biome[bid] as Dictionary).keys()
		names.sort()
		print("[FAUNE]   %-24s %s" % [bid, ", ".join(names)])

	# 4. Garde-fou explicite : les espèces polaires ne doivent JAMAIS être
	# candidates dans un biome chaud, et inversement.
	var polar_in_hot := 0
	var desert_in_polar := 0
	for i in 200:
		for probe: Array in [["desert_aride", ["ours_polaire", "loup_blanc", "morse", "renne"]],
				["calotte_glaciaire", ["scorpion", "chameau_sauvage", "crocodile"]]]:
			var biome_id: String = probe[0]
			var forbidden: Array = probe[1]
			var b: Dictionary = GameData.biomes.get(biome_id, {})
			if b.is_empty():
				continue
			for cid: String in CreatureManager._candidates_for_tags(b.get("tags", [])):
				if cid in forbidden:
					if biome_id == "desert_aride":
						polar_in_hot += 1
					else:
						desert_in_polar += 1
	print("[FAUNE] espèces polaires candidates en désert=%d, espèces chaudes en calotte=%d (attendu 0/0)" % [
			polar_in_hot, desert_in_polar])
	ok = ok and polar_in_hot == 0 and desert_in_polar == 0

	# 5. Profils d'IA : une bête craintive fuit et n'est jamais hostile ; une
	# bête sauvage est neutre AVANT d'être frappée, hostile APRÈS (F.3).
	CreatureManager.creature_root = Node3D.new()
	main.add_child(CreatureManager.creature_root)
	var cerf := CreatureManager.spawn("cerf", Vector3(0, 40, 0))
	var ours := CreatureManager.spawn("ours_brun", Vector3(10, 40, 0))
	var cerf_ok: bool = cerf != null and cerf.is_skittish() and not cerf.is_hostile()
	var ours_avant: bool = ours != null and not ours.is_hostile()
	if ours != null:
		ours.provoke()
	var ours_apres: bool = ours != null and ours.is_hostile()
	print("[FAUNE] cerf : fuit=%s hostile=%s (attendu true/false)" % [
			cerf != null and cerf.is_skittish(), cerf != null and cerf.is_hostile()])
	print("[FAUNE] ours brun : hostile avant provocation=%s après=%s (attendu false/true)" % [
			not ours_avant, ours_apres])
	ok = ok and cerf_ok and ours_avant and ours_apres

	# 6. Fuite effective : le cerf doit S'ÉLOIGNER du joueur sur quelques ticks.
	var player_pos := Vector3(3, 40, 0)
	var dist_avant: float = cerf.logical_position.distance_to(player_pos)
	for i in 30:
		cerf.tick_step(player_pos, player)
	var dist_apres: float = cerf.logical_position.distance_to(player_pos)
	print("[FAUNE] fuite du cerf : distance %.2f → %.2f (doit augmenter)" % [dist_avant, dist_apres])
	ok = ok and dist_apres > dist_avant

	print("[FAUNE] RÉSULTAT : %s" % ("OK" if ok else "ÉCHEC"))
	main.get_tree().quit(0 if ok else 1)

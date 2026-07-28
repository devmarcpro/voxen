extends Probe
## Sonde `--probe-params` — extraite de main.gd le 2026-07-28 (audit architectural).
## Logique inchangée : seuls les accès à la scène ont été réécrits
## ($Player -> player, get_tree() -> main.get_tree(), etc.).


func run() -> void:
	var flat := NoiseGenerator.new(4242, {"relief": 0.05, "biome_force": "desert_aride",
		"rivieres": false, "cavernes": false, "arbres": 0.0, "niveau_mer": -8})
	var normal := NoiseGenerator.new(4242, {})
	var flat_min := 1 << 30
	var flat_max := -(1 << 30)
	var normal_min := 1 << 30
	var normal_max := -(1 << 30)
	var desert_ok := true
	for gz in range(-40, 41, 8):
		for gx in range(-40, 41, 8):
			var wx := gx * 32
			var wz := gz * 32
			flat_min = mini(flat_min, flat.height_at(wx, wz))
			flat_max = maxi(flat_max, flat.height_at(wx, wz))
			normal_min = mini(normal_min, normal.height_at(wx, wz))
			normal_max = maxi(normal_max, normal.height_at(wx, wz))
			if flat.biome_at(wx, wz).get("id", "") != "desert_aride":
				desert_ok = false
	var flat_span := flat_max - flat_min
	var normal_span := normal_max - normal_min
	var rivers: Array = flat.rivers_near(-500, 500, -500, 500)
	print("[PARAMS] relief plat : h ∈ [%d, %d] (étendue %d) · normal : [%d, %d] (étendue %d)" % [
		flat_min, flat_max, flat_span, normal_min, normal_max, normal_span])
	print("[PARAMS] désert partout=%s (attendu true) · rivières=%d (attendu 0) · mer=%d (attendu -6)" % [
		desert_ok, rivers.size(), flat.water_level])
	var ok: bool = flat_span < maxi(int(normal_span * 0.15), 4) and normal_span > 30 \
		and desert_ok and rivers.is_empty() and flat.water_level == -6
	print("[PARAMS] RÉSULTAT : %s" % ("OK" if ok else "ÉCHEC"))
	main.get_tree().quit(0 if ok else 1)

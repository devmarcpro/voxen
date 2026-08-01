extends Probe
## Sonde `--probe-villages` — RECENSEMENT des villages sur une large zone.
##
## Pourquoi elle existe : « je crois que les villages ne se génèrent pas » est
## une observation de joueur, pas un diagnostic. Un village peut manquer pour
## quatre raisons complètement différentes — le tirage de POI ne le désigne pas,
## le biome n'a pas de palette, le site est sous l'eau, le site est trop pentu —
## et chacune se corrige autrement. Cette sonde compte les rejets PAR MOTIF,
## sur une zone assez large pour que les chiffres veuillent dire quelque chose.
##
## Elle ne juge pas : elle mesure. Le verdict d'échec ne porte que sur le cas
## indiscutable — zéro village sur toute la zone.

const TAG := "VILLAGES"

## Rayon du recensement, en cellules de 128 blocs. 24 → 49×49 = 2401 cellules,
## soit un carré de 6,1 km de côté. Assez pour que 4 % de densité annoncée
## produise une centaine de villages si tout va bien.
const RADIUS := 24


func run() -> void:
	await main.get_tree().process_frame
	var generator := WorldManager.generator
	if generator == null:
		print("[%s] pas de générateur." % TAG)
		finish(false, TAG)
		return

	var designated := 0        # le tirage de POI dit « village ici »
	var no_palette := 0        # biome sans village_palette
	var underwater := 0        # site trop bas
	var too_steep := 0         # site trop pentu
	var built := 0             # village réellement construit
	var by_category := {}
	var by_biome_rejected := {}
	var scanned := 0

	for cz in range(-RADIUS, RADIUS + 1):
		for cx in range(-RADIUS, RADIUS + 1):
			var cell := Vector2i(cx, cz)
			scanned += 1
			var center_x := cx * 128 + 64
			var center_z := cz * 128 + 64
			var biome: Dictionary = generator.biome_at(center_x, center_z)
			if biome.is_empty():
				continue
			if "village" not in POIGenerator.pois_at_cell(cell, generator.world_seed, biome):
				continue
			designated += 1

			if not biome.has("village_palette"):
				no_palette += 1
				by_biome_rejected[biome.get("id", "?")] = \
					int(by_biome_rejected.get(biome.get("id", "?"), 0)) + 1
				continue

			var layout: Dictionary = generator.city_at_cell(cell)
			if layout.is_empty():
				# Distinguer les deux rejets restants demande de refaire le
				# test : c'est le prix d'un diagnostic qui désigne la cause au
				# lieu de constater l'absence.
				var plateau := generator.height_at(center_x, center_z)
				if plateau < generator.water_level + 2:
					underwater += 1
				else:
					too_steep += 1
				continue

			built += 1
			var category := CityGenerator.size_category(cell, generator.world_seed)
			by_category[category] = int(by_category.get(category, 0)) + 1

	print("[%s] %d cellules balayées (%d km²)" % [TAG, scanned,
		int(scanned * 128 * 128 / 1000000)])
	print("[%s] désignées « village » par le tirage de POI : %d (%.1f %% des cellules)"
		% [TAG, designated, 100.0 * designated / maxf(float(scanned), 1.0)])
	print("[%s]   → construites : %d" % [TAG, built])
	print("[%s]   → rejet, biome sans palette de village : %d" % [TAG, no_palette])
	print("[%s]   → rejet, site sous l'eau ou trop bas : %d" % [TAG, underwater])
	print("[%s]   → rejet, terrain trop pentu : %d" % [TAG, too_steep])
	for category: String in by_category:
		print("[%s]   %s : %d" % [TAG, category, by_category[category]])
	if not by_biome_rejected.is_empty():
		print("[%s] biomes sans palette qui tiraient un village : %s"
			% [TAG, by_biome_rejected])

	var survival := 100.0 * built / maxf(float(designated), 1.0)
	print("[%s] taux de survie du tirage à la construction : %.1f %%" % [TAG, survival])
	# Distance moyenne entre deux villages, à densité uniforme : c'est le chiffre
	# que le joueur ressent réellement en marchant.
	if built > 0:
		var area_per_village := float(scanned) * 128.0 * 128.0 / float(built)
		print("[%s] un village tous les ~%d blocs en moyenne"
			% [TAG, int(sqrt(area_per_village))])

	# --- GARDE-FOUS -----------------------------------------------------------
	#
	# Des seuils larges, calés sur la mesure du 2026-08-01 (60 villages sur
	# 39 km², survie 27 %). Ils ne défendent pas une valeur exacte — le monde a
	# le droit d'évoluer — mais l'ORDRE DE GRANDEUR : si une refonte du relief
	# ramène la survie à 5 %, les villages redeviendront introuvables et il faut
	# que ça se voie ici plutôt qu'en jeu, six semaines plus tard.
	var ok := true
	for check: Array in [
		["des villages existent", built > 0, "%d" % built],
		["densité jouable (un village tous les 1500 blocs au plus)",
			built > 0 and sqrt(float(scanned) * 128.0 * 128.0 / float(built)) < 1500.0,
			"%d blocs" % int(sqrt(float(scanned) * 128.0 * 128.0 / maxf(float(built), 1.0)))],
		["l'attrition de site reste raisonnable", survival > 15.0,
			"%.0f %% des tirages aboutissent" % survival],
		["toutes les tailles apparaissent", by_category.size() >= 2,
			", ".join(PackedStringArray(by_category.keys()))],
	]:
		var passed: bool = check[1]
		ok = ok and passed
		print("[%s] %s (%s) : %s" % [TAG, check[0], check[2], "OK" if passed else "ÉCHEC"])
	finish(ok, TAG)

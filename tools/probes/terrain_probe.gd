extends Probe
## Sonde `--probe-terrain` — extraite de main.gd le 2026-07-28 (audit architectural).
## Logique inchangée : seuls les accès à la scène ont été réécrits
## ($Player -> player, get_tree() -> main.get_tree(), etc.).


## Sonde headless des paramètres de monde (2026-07-21, menu nouvelle partie) :
## un monde « plat + tout désert + sans rivières/cavernes » doit réellement
## l'être, comparé à un monde aux paramètres par défaut sur la même graine.
## Sonde du terrain fini/varié (--probe-terrain, headless) : échantillonne une
## grille sur toute l'étendue du monde et rapporte la distribution océan/plaines/
## collines/montagnes + vérifie que le bord du monde est bien de l'océan.
func run() -> void:
	var g := NoiseGenerator.new(4242, {})
	var wl := g.water_level
	var r := g.world_radius
	var ocean := 0
	var plaine := 0
	var colline := 0
	var montagne := 0
	var total := 0
	var hmin := 1 << 30
	var hmax := -(1 << 30)
	var step := 300
	for wz in range(-r, r + 1, step):
		for wx in range(-r, r + 1, step):
			var h := g.height_at(wx, wz)
			total += 1
			hmin = mini(hmin, h)
			hmax = maxi(hmax, h)
			if h < wl:
				ocean += 1
			elif h < wl + 30:
				plaine += 1
			elif h < wl + 90:
				colline += 1
			else:
				montagne += 1
	# Fertilité sur les terres émergées : doit VARIER (prospection).
	var fmin := 2.0
	var fmax := -1.0
	var fsum := 0.0
	var fn := 0
	for wz in range(-r, r + 1, step):
		for wx in range(-r, r + 1, step):
			if g.height_at(wx, wz) >= wl:
				var f := g.fertility_at(wx, wz)
				fmin = minf(fmin, f)
				fmax = maxf(fmax, f)
				fsum += f
				fn += 1
	var fmean := 0.0 if fn == 0 else fsum / float(fn)
	print("[TERRAIN] fertilité terre : min=%.2f moy=%.2f max=%.2f (doit varier)" % [fmin, fmean, fmax])
	# Couverture des biomes (item : tous les biomes présents dans chaque monde).
	var biome_tally := {}
	for wz in range(-r, r + 1, step):
		for wx in range(-r, r + 1, step):
			var bid: String = g.biome_at(wx, wz).get("id", "")
			if bid != "":
				biome_tally[bid] = int(biome_tally.get(bid, 0)) + 1
	var missing: Array[String] = []
	var overworld_count := 0
	for bid: String in GameData.biomes.keys():
		if String(GameData.biomes[bid].get("dimension", "overworld")) != "overworld":
			continue
		overworld_count += 1
		if not biome_tally.has(bid):
			missing.append(bid)
	print("[BIOMES] présents=%d/%d overworld manquants=%s" % [biome_tally.size(), overworld_count, missing])
	# Garantie « tous les biomes dans CHAQUE monde » : test multi-graines (grille
	# grossière) — chaque graine doit couvrir tous les biomes overworld.
	for test_seed in [1, 7, 42, 1337, 99999]:
		var gs := NoiseGenerator.new(test_seed, {})
		var seen := {}
		for wz in range(-gs.world_radius, gs.world_radius + 1, 600):
			for wx in range(-gs.world_radius, gs.world_radius + 1, 600):
				var bid: String = gs.biome_at(wx, wz).get("id", "")
				if bid != "":
					seen[bid] = true
		var miss: Array[String] = []
		for bid: String in GameData.biomes.keys():
			if String(GameData.biomes[bid].get("dimension", "overworld")) == "overworld" and not seen.has(bid):
				miss.append(bid)
		print("[BIOMES] graine %d : %d biomes, manquants=%s" % [test_seed, seen.size(), miss])
	var pct := func(n: int) -> float: return 100.0 * float(n) / float(total)
	# Bord extérieur : 24 points sur le cercle de rayon = world_radius + marge.
	var edge_ocean := 0
	for i in 24:
		var a := TAU * float(i) / 24.0
		var ex := int(cos(a) * (r + 400))
		var ez := int(sin(a) * (r + 400))
		if g.height_at(ex, ez) < wl:
			edge_ocean += 1
	# Noms générés (monde / continents / océans).
	print("[NOMS] monde=« %s »" % g.world_name())
	var regions := g.detect_regions(96)
	var conts: Array = regions["continents"]
	var ocs: Array = regions["oceans"]
	print("[NOMS] %d continents : %s" % [conts.size(), conts.map(func(c): return c["name"])])
	print("[NOMS] %d océans/mers : %s" % [ocs.size(), ocs.map(func(o): return o["name"])])
	var land_spawn := g.find_land_spawn(0, 0)
	var pc := g.preview_color(land_spawn.x, land_spawn.y)
	print("[TERRAIN] spawn terre=%s couleur_aperçu=(%.2f,%.2f,%.2f)" % [land_spawn, pc.r, pc.g, pc.b])
	# Rend l'aperçu du monde complet en PNG (vérification visuelle headless).
	var n := 192
	var img := Image.create(n, n, false, Image.FORMAT_RGB8)
	var pspan := 2.0 * float(r) / float(n)
	for py in n:
		for px in n:
			img.set_pixelv(Vector2i(px, py), g.preview_color(int(-r + px * pspan), int(-r + py * pspan)))
	img.save_png("user://terrain_preview.png")
	print("[TERRAIN] aperçu sauvé : user://terrain_preview.png")
	print("[TERRAIN] rayon=%d niveau_mer=%d échantillons=%d h∈[%d,%d]" % [r, wl, total, hmin, hmax])
	print("[TERRAIN] océan=%.1f%% plaine=%.1f%% colline=%.1f%% montagne=%.1f%%" % [
		pct.call(ocean), pct.call(plaine), pct.call(colline), pct.call(montagne)])
	print("[TERRAIN] bord océanique : %d/24 points sous le niveau de la mer (attendu 24)" % edge_ocean)
	# Critères : océan présent mais pas majoritaire absurde, plaines dominent la
	# terre (biais plaines), montagnes rares, bord entièrement noyé.
	var land := plaine + colline + montagne
	var plaine_share := 0.0 if land == 0 else float(plaine) / float(land)
	var mtn_share := 0.0 if land == 0 else float(montagne) / float(land)
	var ok: bool = edge_ocean == 24 and ocean > 0 and plaine_share > 0.4 and mtn_share < 0.22
	print("[TERRAIN] biais plaines=%.2f montagnes=%.2f RÉSULTAT : %s" % [
		plaine_share, mtn_share, "OK" if ok else "ÉCHEC"])
	# Bandes climatiques par latitude (style Terre) : biome dominant sur terre
	# à chaque latitude, de l'équateur (centre) au pôle (bord).
	for lat in [0.0, 0.15, 0.3, 0.45, 0.6, 0.75, 0.9]:
		var fz := int(lat * r)
		var tally := {}
		var found := 0
		for wx in range(-r, r + 1, step):
			if g.height_at(wx, fz) >= wl:
				var bid: String = g.biome_at(wx, fz).get("id", "?")
				tally[bid] = int(tally.get(bid, 0)) + 1
				found += 1
		var dom := "(océan)"
		var best := 0
		for k: String in tally:
			if tally[k] > best:
				best = tally[k]
				dom = k
		print("[CLIMAT] lat %.2f (fz=%d) : %s (%d/%d terres)" % [lat, fz, dom, best, found])
	main.get_tree().quit(0 if ok else 1)

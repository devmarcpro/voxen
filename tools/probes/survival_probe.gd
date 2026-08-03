extends Probe
## Sonde `--probe-survie` — extraite de main.gd le 2026-07-28 (audit architectural).
## Logique inchangée : seuls les accès à la scène ont été réécrits
## ($Player -> player, get_tree() -> main.get_tree(), etc.).


## Sonde ambiance & survie (E.21 / 7.7 / 6.4) : cycle jour/nuit, sommeil,
## fatigue, et boucle de cuisine qui crédite enfin le potentiel.
func run() -> void:
	await main.get_tree().process_frame
	var player: Node = player
	player.apply_default_character()
	var ok := true

	# 1. Cycle : les 4 phases d'E.21 doivent toutes exister sur 24 h.
	var phases := {}
	for h in 24:
		TickManager.tick_index = int(float(h) / 24.0 * DayNightManager.TICKS_PER_DAY)
		phases[DayNightManager.phase()] = true
	var attendues := ["nuit", "aube", "jour", "crepuscule"]
	var manquantes: Array[String] = []
	for phase: String in attendues:
		if not phases.has(phase):
			manquantes.append(phase)
	print("[SURVIE] phases sur 24 h : %s (manquantes : %s)" % [phases.keys(), manquantes])
	ok = ok and manquantes.is_empty()

	# 2. Bornes E.21 : minuit = nuit, midi = jour, 6h = aube, 20h = crépuscule.
	var controles := {0.0: "nuit", 6.0: "aube", 12.0: "jour", 20.0: "crepuscule", 22.0: "nuit"}
	var erreurs := 0
	for heure: float in controles:
		TickManager.tick_index = int(heure / 24.0 * DayNightManager.TICKS_PER_DAY)
		var got := DayNightManager.phase()
		if got != controles[heure]:
			erreurs += 1
			print("[SURVIE]   %.0fh → %s (attendu %s)" % [heure, got, controles[heure]])
	print("[SURVIE] bornes de phase : %d erreur(s) (attendu 0)" % erreurs)
	ok = ok and erreurs == 0

	# 3. Lumière : le plein jour doit être franchement plus lumineux que la nuit.
	TickManager.tick_index = int(12.0 / 24.0 * DayNightManager.TICKS_PER_DAY)
	var jour := DayNightManager.daylight()
	TickManager.tick_index = int(0.0 / 24.0 * DayNightManager.TICKS_PER_DAY)
	var nuit := DayNightManager.daylight()
	print("[SURVIE] facteur de lumière : midi=%.2f minuit=%.2f (attendu 1 / 0)" % [jour, nuit])
	ok = ok and is_equal_approx(jour, 1.0) and is_equal_approx(nuit, 0.0)

	# 4. Fatigue : décroît avec le temps, malus d'XP sous 50.
	player.fatigue = player.fatigue_max
	for i in 2000:
		player._on_tick(0)
	print("[SURVIE] fatigue après 2000 ticks : %.1f (attendu < %.0f)" % [
			player.fatigue, player.fatigue_max])
	ok = ok and player.fatigue < player.fatigue_max

	player.fatigue = 80.0
	var plein: float = player.xp_state_multiplier()
	player.fatigue = 30.0
	var fatigue_mult: float = player.xp_state_multiplier()
	print("[SURVIE] multiplicateur d'XP : reposé=%.2f fatigué=%.2f (doit baisser)" % [
			plein, fatigue_mult])
	ok = ok and fatigue_mult < plein

	# 5. Fatigue au plancher : malus de stats, mais AUCUN dégât (amendement).
	player.fatigue = 0.0
	player.hunger = 100.0
	player.health = player.health_max
	# LES TICKS D'ABORD, LA LECTURE ENSUITE (corrigé le 2026-08-03). La stat
	# était lue AVANT toute exécution de tick : or les jauges ne se traduisent en
	# modificateurs que dans `_hunger_tick_effects`, appelé au tick (E.4 — « les
	# jauges viennent de bouger : reporter leur effet avant que quoi que ce soit
	# ne lise une stat CE TICK »). La sonde lisait donc la valeur d'AVANT
	# l'épuisement et concluait à l'absence de malus. Le comportement du jeu est
	# correct ; c'était la mesure qui était prise trop tôt.
	for i in 1000:
		player._on_tick(0)
	var force_epuise: int = player.effective_stat("force")
	print("[SURVIE] épuisé : Force=%d (base %d, -10%%) santé=%.0f/%.0f (aucun dégât attendu)" % [
			force_epuise, int(player.stats["force"]), player.health, player.health_max])
	ok = ok and force_epuise < int(player.stats["force"]) and player.health >= player.health_max - 0.01

	# 5bis. Le TERRAIN doit vraiment s'assombrir. Le shader voxel est
	# `unshaded` : il ignore la lumière directionnelle, donc seul l'uniform
	# `daylight` le noircit. Sans cette vérif, un cycle purement décoratif
	# (ciel qui change, monde en plein jour) passerait inaperçu.
	var terrain: ShaderMaterial = WorldManager.base_material()
	if terrain != null:
		TickManager.tick_index = int(12.0 / 24.0 * DayNightManager.TICKS_PER_DAY)
		DayNightManager._apply_lighting()
		var midi: float = float(terrain.get_shader_parameter("daylight"))
		TickManager.tick_index = int(0.0 / 24.0 * DayNightManager.TICKS_PER_DAY)
		DayNightManager._apply_lighting()
		var minuit: float = float(terrain.get_shader_parameter("daylight"))
		print("[SURVIE] uniform terrain `daylight` : midi=%.2f minuit=%.2f (le monde doit noircir)" % [
				midi, minuit])
		ok = ok and midi > 0.9 and minuit < 0.1
	else:
		print("[SURVIE] pas de matériau terrain — vérification d'assombrissement sautée")

	# 5ter. Faune nocturne (E.21) : les tables de spawn doivent DIFFÉRER
	# entre le jour et la nuit, sinon la nuit n'a aucune identité.
	var biome_tags: Array = (GameData.biomes.get("foret_temperee", {}) as Dictionary).get("tags", [])
	TickManager.tick_index = int(12.0 / 24.0 * DayNightManager.TICKS_PER_DAY)
	var de_jour: Array[String] = CreatureManager._candidates_for_tags(biome_tags)
	TickManager.tick_index = int(0.0 / 24.0 * DayNightManager.TICKS_PER_DAY)
	var de_nuit: Array[String] = CreatureManager._candidates_for_tags(biome_tags)
	var seulement_nuit: Array[String] = []
	for cid in de_nuit:
		if cid not in de_jour:
			seulement_nuit.append(cid)
	print("[SURVIE] forêt tempérée — de jour : %s" % [de_jour])
	print("[SURVIE] forêt tempérée — de nuit : %s" % [de_nuit])
	print("[SURVIE] espèces exclusivement nocturnes : %d (attendu > 0)" % seulement_nuit.size())
	ok = ok and seulement_nuit.size() > 0 and de_jour != de_nuit

	# 5quater. Lumière de bloc (G.3) : une torche doit éclairer autour d'elle
	# avec une décroissance de 1 par bloc, et un mur doit l'arrêter.
	var torche_rid: int = GameData.material_runtime_ids.get("torche", 0)
	var emission: int = int(GameData.emission_by_runtime[torche_rid]) if torche_rid > 0 else 0
	print("[SURVIE] émission de la torche : %d/15 (luminosité 90 → attendu 14)" % emission)
	ok = ok and emission >= 13

	# Pad synthétique : de l'air partout, une torche au centre.
	var pad := PackedInt32Array()
	pad.resize(LightField.P * LightField.P * LightField.P)
	var centre := 9 * LightField.SX + 9 * LightField.SZ + 9 * LightField.SY
	pad[centre] = torche_rid
	var champ := LightField.compute_from_pad(pad)
	var au_centre: int = int(champ[centre])
	var a_trois: int = int(champ[centre + 3 * LightField.SX])
	# Décroissance de 1 par bloc, vérifiée sur toute la portée disponible.
	# (Le pad ne fait que 18 de côté : depuis le centre on ne peut aller que
	# jusqu'à 8 blocs — au-delà, l'index déborderait sur la rangée suivante,
	# ce qui a fait échouer une première version de ce test.)
	var decroissance_ok := true
	for distance in range(1, 9):
		var attendu: int = maxi(0, emission - distance)
		var lu: int = int(champ[centre + distance * LightField.SX])
		if lu != attendu:
			decroissance_ok = false
			print("[SURVIE]   à %d bloc(s) : %d (attendu %d)" % [distance, lu, attendu])
	print("[SURVIE] lumière : centre=%d à 3 blocs=%d — décroissance de 1/bloc : %s" % [
			au_centre, a_trois, decroissance_ok])
	ok = ok and au_centre == emission and a_trois == emission - 3 and decroissance_ok

	# Un mur opaque doit bloquer : on bouche la colonne +X à 1 bloc.
	# Le mur doit couvrir TOUT le plan YZ : une simple plaque 3×3 était
	# contournée par la lumière (elle se propage en 3D) — le premier test
	# concluait donc à tort que la pierre ne bloquait pas.
	var pad_mur := pad.duplicate()
	var pierre_rid: int = GameData.material_runtime_ids.get("pierre", 1)
	for y in LightField.P:
		for z in LightField.P:
			pad_mur[10 * LightField.SX + z * LightField.SZ + y * LightField.SY] = pierre_rid
	var champ_mur := LightField.compute_from_pad(pad_mur)
	var derriere: int = int(champ_mur[centre + 3 * LightField.SX])
	print("[SURVIE] derrière un mur de pierre : %d (attendu 0 — la pierre bloque)" % derriere)
	ok = ok and derriere == 0

	# Un chunk SANS source ne doit rien allouer (coût nul, cas majoritaire).
	var pad_vide := PackedInt32Array()
	pad_vide.resize(LightField.P * LightField.P * LightField.P)
	var vide := LightField.compute_from_pad(pad_vide)
	print("[SURVIE] chunk sans source : champ vide=%s (aucune allocation)" % vide.is_empty())
	ok = ok and vide.is_empty()

	# 6. Cuisine : les plats existent et sont CUITS (nutrition pleine).
	print("[SURVIE] plats chargés : %d %s" % [GameData.plats.size(), GameData.plats.keys()])
	ok = ok and GameData.plats.size() >= 4
	var crus := 0
	for pid: String in GameData.plats:
		if not bool((GameData.plats[pid]["nutrition"] as Dictionary).get("cuit", false)):
			crus += 1
	print("[SURVIE] plats marqués crus : %d (attendu 0)" % crus)
	ok = ok and crus == 0

	# 7. LA boucle de 6.4 : manger un plat cuisiné crédite le potentiel.
	#    C'est le point qui était mort — le potentiel n'augmentait jamais.
	var avant: float = float(player.stat_potentials["force"])
	player.hunger = 20.0
	player.inventory.add_object(ItemFactory.resource_instance("viande_grillee", 1))
	player.autofill_hotbar()
	_select_object(player, "viande_grillee")
	player._try_eat()
	var apres: float = float(player.stat_potentials["force"])
	print("[SURVIE] potentiel de Force : %.1f → %.1f après un plat cuisiné (doit monter)" % [
			avant, apres])
	ok = ok and apres > avant

	# 8. Manger CRU ne crédite rien (A.9.1) — sinon cuisiner ne servirait à rien.
	var avant_cru: float = float(player.stat_potentials["endurance"])
	player.hunger = 20.0
	player.inventory.add_object(ItemFactory.resource_instance("viande_de_cerf", 1))
	player.autofill_hotbar()
	_select_object(player, "viande_de_cerf")
	player._try_eat()
	print("[SURVIE] potentiel après viande CRUE : %.1f (doit être inchangé : %.1f)" % [
			float(player.stat_potentials["endurance"]), avant_cru])
	ok = ok and is_equal_approx(float(player.stat_potentials["endurance"]), avant_cru)

	print("[SURVIE] RÉSULTAT : %s" % ("OK" if ok else "ÉCHEC"))
	main.get_tree().quit(0 if ok else 1)

extends Probe
## Sonde `--probe-royaumes-perf` (2026-08-04) — coût de génération des royaumes.
##
## POURQUOI. Une partie réelle a craché des `[TICK] 62.3 ms` en boucle. Le
## coupable n'était pas celui qu'on croyait : ni l'IA, ni le spawn, mais
## `kingdom_at_cell`, qui coûte plus de 100 ms au premier appel d'un secteur
## neuf et que le peuplement de village déclenchait EN PLEIN TICK.
##
## Cette sonde mesure ce coût, le décompose, et vérifie qu'aucun tick ne le
## paie. Elle mesure AVANT d'optimiser — le même jour, une conclusion tirée
## d'une mesure unique s'est révélée fausse, cette machine ayant ±35 % de bruit.

const TAG := "ROYAUMESPERF"

## Budget d'un tick (E.14), en millisecondes.
const TICK_BUDGET_MS := 16.0

var _ok := true


func _expect(condition: bool, message: String) -> void:
	print("[%s] %s — %s" % [TAG, "ok" if condition else "ÉCHEC", message])
	if not condition:
		_ok = false


func run() -> void:
	await wait_frame()
	var generator := WorldManager.generator
	if generator == null:
		print("[%s] aucun générateur." % TAG)
		main.get_tree().quit(1)
		return
	_measure_neighbours(generator)
	_measure_cold_cost(generator)
	_measure_breakdown(generator)
	await _check_tick_never_pays(generator)
	_measure_spawn(generator)
	finish(_ok, TAG)


## LE DERNIER POSTE HORS BUDGET : faire apparaître UNE créature.
##
## On sépare l'INSTANCIATION de la scène de sa CONFIGURATION. La distinction
## décide du remède : si le coût est dans l'instanciation, on peut la faire
## d'avance, hors tick ; s'il est dans `setup`, il faudra le rendre moins cher,
## et un pool ne servirait à rien.
func _measure_spawn(_generator: NoiseGenerator) -> void:
	var scene: PackedScene = CreatureManager.CREATURE_SCENE
	var instantiate_ms: Array[float] = []
	var setup_ms: Array[float] = []
	var made: Array[Node] = []
	for i in 8:
		var start := Time.get_ticks_usec()
		var instance := scene.instantiate()
		instantiate_ms.append(float(Time.get_ticks_usec() - start) / 1000.0)
		CreatureManager.creature_root.add_child(instance)
		start = Time.get_ticks_usec()
		instance.setup("bandit", Vector3(0, 400, 0))
		setup_ms.append(float(Time.get_ticks_usec() - start) / 1000.0)
		made.append(instance)
	for instance in made:
		instance.queue_free()

	instantiate_ms.sort()
	setup_ms.sort()
	var i_med := instantiate_ms[instantiate_ms.size() / 2]
	var s_med := setup_ms[setup_ms.size() / 2]
	print("[%s] apparition d'une créature : instanciation %.1f ms | configuration %.1f ms" % [
			TAG, i_med, s_med])
	print("[%s]   → %s" % [TAG, "l'instanciation domine : elle peut se faire d'avance, hors tick"
			if i_med > s_med else "la configuration domine : un pool n'y changerait rien"])

	# ON DESCEND D'UN CRAN DANS LA CONFIGURATION. « setup coûte 12 ms » ne se
	# corrige pas ; savoir que ce sont les 18 maillages du .glb qui se
	# reconstruisent, si.
	var model_path := "res://models/creatures/humanoide.glb"
	if not ResourceLoader.exists(model_path):
		print("[%s] modèle humanoïde absent — analyse du corps impossible." % TAG)
		return
	var load_ms: Array[float] = []
	var inst_ms: Array[float] = []
	var skin_ms: Array[float] = []
	var bodies: Array[Node] = []
	for i in 8:
		var t := Time.get_ticks_usec()
		var glb: PackedScene = load(model_path)
		load_ms.append(float(Time.get_ticks_usec() - t) / 1000.0)
		t = Time.get_ticks_usec()
		var body := glb.instantiate()
		inst_ms.append(float(Time.get_ticks_usec() - t) / 1000.0)
		CreatureManager.creature_root.add_child(body)
		t = Time.get_ticks_usec()
		PlayerBody.apply_procedural_skin(body, PlayerBody.palette_for_species("humain"))
		skin_ms.append(float(Time.get_ticks_usec() - t) / 1000.0)
		bodies.append(body)
	for body in bodies:
		body.queue_free()
	load_ms.sort()
	inst_ms.sort()
	skin_ms.sort()
	print("[%s] corps riggé : chargement %.2f ms | instanciation du .glb %.2f ms | peau %.2f ms" % [
			TAG, load_ms[load_ms.size() / 2], inst_ms[inst_ms.size() / 2],
			skin_ms[skin_ms.size() / 2]])

	# Les briques du corps ne coûtent presque rien — donc le temps est ailleurs
	# dans `setup`. On chronomètre ses deux étapes lourdes séparément.
	var hitbox_ms: Array[float] = []
	var visual_ms: Array[float] = []
	var probes: Array[Node] = []
	var data: Dictionary = GameData.creatures["bandit"]
	for i in 6:
		var creature := scene.instantiate()
		CreatureManager.creature_root.add_child(creature)
		var t := Time.get_ticks_usec()
		creature.call("_resolve_hitboxes", data)
		hitbox_ms.append(float(Time.get_ticks_usec() - t) / 1000.0)
		creature.set("creature_id", "bandit")
		creature.set("race_id", String(data.get("race", "")))
		t = Time.get_ticks_usec()
		creature.call("_build_visual", data)
		visual_ms.append(float(Time.get_ticks_usec() - t) / 1000.0)
		probes.append(creature)
	for creature in probes:
		creature.queue_free()
	hitbox_ms.sort()
	visual_ms.sort()
	print("[%s] setup : boîtes de coups %.2f ms | construction visuelle %.2f ms" % [
			TAG, hitbox_ms[hitbox_ms.size() / 2], visual_ms[visual_ms.size() / 2]])

	# DERNIÈRE PIÈCE NON CHRONOMÉTRÉE. Les briques mesurées plus haut ne font
	# pas la somme : c'est donc `PlayerBody.setup` lui-même, et notamment le
	# moment où ses dix-huit maillages ENTRENT DANS L'ARBRE, qu'il faut isoler.
	var body_ms: Array[float] = []
	var built: Array[Node] = []
	var palette := PlayerBody.palette_for_species("humain")
	for i in 6:
		var human: Node3D = preload("res://scenes/entities/player_body.gd").new()
		CreatureManager.creature_root.add_child(human)
		var t := Time.get_ticks_usec()
		human.setup(false, palette)
		body_ms.append(float(Time.get_ticks_usec() - t) / 1000.0)
		built.append(human)
	for human in built:
		human.queue_free()
	body_ms.sort()
	print("[%s] PlayerBody.setup seul : %.2f ms (min %.2f, max %.2f)" % [
			TAG, body_ms[body_ms.size() / 2], body_ms[0], body_ms[body_ms.size() - 1]])


## CE QUI COMPTE VRAIMENT : qu'aucun tick ne paie le calcul.
##
## La mémoïsation a divisé le coût par quatre, mais dix millisecondes restent
## dix millisecondes dans un budget de seize. La garantie ne vient donc pas de
## l'optimisation, elle vient du fait que le peuplement de village REFUSE de
## déclencher le calcul : il attend que le préchauffage, qui tourne dans une
## frame et non dans un tick, ait préparé le secteur.
##
## C'est cette règle-là qu'on verrouille : sans elle, la moindre régression
## ramènerait les `[TICK] 62 ms` sans que rien ne le signale.
func _check_tick_never_pays(generator: NoiseGenerator) -> void:
	# On cherche un village, on s'y place, et on repart d'un cache VIDE : c'est
	# exactement la situation d'un joueur qui arrive dans une région neuve.
	var cell := Vector2i.ZERO
	var found := false
	for radius in range(0, 30):
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if maxi(absi(dx), absi(dz)) != radius:
					continue
				if not generator.city_at_cell(Vector2i(dx, dz)).is_empty():
					cell = Vector2i(dx, dz)
					found = true
					break
			if found:
				break
		if found:
			break
	if not found:
		print("[%s] aucun village pour l'essai." % TAG)
		return

	var center := POIGenerator.cell_center_world(cell)
	player.teleport_to(Vector3(center.x, 200.0, center.y))
	KingdomGenerator.clear_cache()
	CreatureManager._populated_villages.clear()

	var start := Time.get_ticks_usec()
	CreatureManager.call("_village_population_tick", Vector3(center.x, 200.0, center.y))
	var cold_tick := float(Time.get_ticks_usec() - start) / 1000.0
	print("[%s] tick de peuplement, royaume NON préchauffé : %.2f ms" % [TAG, cold_tick])
	_expect(cold_tick < TICK_BUDGET_MS,
			"le tick refuse de payer le calcul et rend la main (%.2f ms < %.0f)" % [
					cold_tick, TICK_BUDGET_MS])
	_expect(CreatureManager._populated_villages.is_empty(),
			"aucun village n'est peuplé tant que son royaume n'est pas prêt")

	# Puis on préchauffe comme le ferait WorldManager, hors tick, et le village
	# doit alors se peupler.
	KingdomGenerator.warm_sector(KingdomGenerator.sector_of(cell),
			WorldManager.world_seed, generator)
	CreatureManager.call("_village_population_tick", Vector3(center.x, 200.0, center.y))
	_expect(not CreatureManager._populated_villages.is_empty(),
			"une fois le secteur préchauffé, le village se peuple")

	# LE PRÉCHAUFFAGE TOURNE-T-IL VRAIMENT ? Les deux tests ci-dessus vérifient
	# les PIÈCES ; celui-ci vérifie que la mécanique s'enclenche toute seule.
	# Sans lui, un préchauffage jamais appelé passerait inaperçu — le jeu
	# marcherait, les villages ne se peupleraient simplement plus jamais.
	KingdomGenerator.clear_cache()
	var sector := KingdomGenerator.sector_of(cell)
	_expect(not KingdomGenerator.sector_ready(sector), "le secteur repart bien à froid")
	# Quelques frames suffisent : le préchauffage prépare un secteur par frame.
	for i in 6:
		await main.get_tree().process_frame
	_expect(KingdomGenerator.sector_ready(sector),
			"WorldManager préchauffe le secteur du joueur de lui-même, en quelques frames")


## CE QUE LE TICK DE PEUPLEMENT PAIE À CHAQUE PASSAGE, avant même d'envisager
## de peupler quoi que ce soit : il interroge `city_at_cell` sur les neuf
## cellules autour du joueur. Si cette requête est chère à froid, elle est
## chère À CHAQUE TICK où le joueur change de cellule.
func _measure_neighbours(generator: NoiseGenerator) -> void:
	var samples: Array[float] = []
	for i in 12:
		var cell := Vector2i(2000 + i * 41, -2000 - i * 29)
		var start := Time.get_ticks_usec()
		generator.city_at_cell(cell)
		samples.append(float(Time.get_ticks_usec() - start) / 1000.0)
	samples.sort()
	var median := samples[samples.size() / 2]
	print("[%s] `city_at_cell` sur cellule vierge : médiane %.2f ms (max %.2f)" % [
			TAG, median, samples[samples.size() - 1]])
	print("[%s]   → un tick de peuplement en interroge NEUF : %.1f ms" % [TAG, median * 9.0])

	var warm_start := Time.get_ticks_usec()
	generator.city_at_cell(Vector2i(2000, -2000))
	print("[%s] la même à chaud : %.3f ms" % [
			TAG, float(Time.get_ticks_usec() - warm_start) / 1000.0])


## COÛT À FROID D'UN SECTEUR, répété sur plusieurs secteurs vierges.
##
## On mesure plusieurs fois : sur cette machine, `--probe-mesh` rend 13,8 à
## 24,1 ms pour un code identique. Une mesure unique ne dit rien.
func _measure_cold_cost(generator: NoiseGenerator) -> void:
	var samples: Array[float] = []
	for i in 6:
		# Des secteurs très éloignés les uns des autres, jamais visités : le
		# cache doit être froid, sinon on chronomètre une lecture de dictionnaire.
		var sector := Vector2i(400 + i * 37, 400 - i * 53)
		var start := Time.get_ticks_usec()
		KingdomGenerator.capitals_in_sector(sector, WorldManager.world_seed, generator)
		samples.append(float(Time.get_ticks_usec() - start) / 1000.0)
	samples.sort()
	print("[%s] tirage des capitales seul : médiane %.1f ms (min %.1f, max %.1f)" % [
			TAG, samples[samples.size() / 2], samples[0], samples[samples.size() - 1]])

	# LE VRAI COÛT : capitales + territoires + identités, soit ce que fait
	# `kingdom_at_cell` sur un secteur neuf.
	var full: Array[float] = []
	for i in 6:
		var cell := Vector2i(9000 + i * 211, -9000 - i * 173)
		var start := Time.get_ticks_usec()
		generator.kingdom_at_cell(cell)
		full.append(float(Time.get_ticks_usec() - start) / 1000.0)
	full.sort()
	var median := full[full.size() / 2]
	print("[%s] `kingdom_at_cell` sur cellule vierge : médiane %.1f ms (min %.1f, max %.1f)" % [
			TAG, median, full[0], full[full.size() - 1]])
	print("[%s]   → soit %.0f budgets de tick pour UNE requête" % [TAG, median / TICK_BUDGET_MS])

	# Une fois chaude, la même requête doit être gratuite : si elle ne l'est
	# pas, le cache ne sert à rien et le problème est ailleurs.
	var warm_start := Time.get_ticks_usec()
	generator.kingdom_at_cell(Vector2i(9000, -9000))
	var warm := float(Time.get_ticks_usec() - warm_start) / 1000.0
	print("[%s] la même requête à chaud : %.3f ms" % [TAG, warm])
	_expect(warm < 1.0, "une cellule déjà calculée est gratuite (%.3f ms)" % warm)


## OÙ VA LE TEMPS. « C'est lent » ne se corrige pas ; « le coût d'entrée dans une
## cellule est recalculé N fois » se corrige.
func _measure_breakdown(generator: NoiseGenerator) -> void:
	# RECHERCHE EN ANNEAUX AUTOUR DE L'ORIGINE. Les capitales sont rares : la
	# première version tirait quarante secteurs sur une diagonale et n'en
	# trouvait aucun, si bien que l'analyse ne s'exécutait jamais et que la
	# sonde passait au vert sans rien avoir mesuré.
	var sector := Vector2i.ZERO
	var capitals: Array[Dictionary] = []
	for radius in range(0, 12):
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if maxi(absi(dx), absi(dz)) != radius:
					continue
				var candidate := Vector2i(dx, dz)
				var found := KingdomGenerator.capitals_in_sector(
						candidate, WorldManager.world_seed, generator)
				if not found.is_empty():
					sector = candidate
					capitals = found
					break
			if not capitals.is_empty():
				break
		if not capitals.is_empty():
			break
	if capitals.is_empty():
		print("[%s] aucune capitale trouvée pour l'analyse." % TAG)
		return

	print("[%s] secteur %s : %d capitale(s)" % [TAG, sector, capitals.size()])
	var territory_total := 0.0
	var identity_total := 0.0
	var cells_reached := 0
	for capital: Dictionary in capitals:
		var start := Time.get_ticks_usec()
		var territory := KingdomGenerator.territory_of(capital, generator)
		territory_total += float(Time.get_ticks_usec() - start) / 1000.0
		cells_reached += territory.size()
		start = Time.get_ticks_usec()
		KingdomGenerator.identity(capital, WorldManager.world_seed, generator)
		identity_total += float(Time.get_ticks_usec() - start) / 1000.0
	print("[%s] territoires : %.1f ms pour %d cellule(s) atteintes (%.3f ms/cellule)" % [
			TAG, territory_total, cells_reached,
			territory_total / maxf(1.0, float(cells_reached))])
	print("[%s] identités : %.1f ms" % [TAG, identity_total])

	# Le coût d'entrée dans une cellule est la brique élémentaire du calcul de
	# territoire : c'est lui qu'il faut mesurer pour savoir si le problème est
	# l'algorithme ou l'échantillonnage du monde.
	var entry_samples := 2000
	var start_entry := Time.get_ticks_usec()
	for i in entry_samples:
		KingdomGenerator.entry_cost(Vector2i(3000 + i, -3000 - i), generator)
	var per_entry := float(Time.get_ticks_usec() - start_entry) / 1000.0 / float(entry_samples)
	print("[%s] coût d'entrée dans une cellule, à froid : %.4f ms (%d échantillons)" % [
			TAG, per_entry, entry_samples])
	# NB : on ne compare plus ce coût au temps de territoire depuis que les
	# coûts d'entrée sont mémoïsés — le territoire n'en paie plus qu'un par
	# cellule au lieu de quatre, et le rapport n'aurait plus de sens.

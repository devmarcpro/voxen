extends Probe
## Sonde `--probe-village-vie` (2026-08-03) — CYCLE DE VIE d'un village peuplé.
##
## POURQUOI ELLE EXISTE. Une partie réelle a craché en boucle
## « Trying to assign invalid previously freed instance » depuis
## `CreatureManager._release_village`, à chaque tick, indéfiniment. Aucune sonde
## ne l'a vu : `--probe-villages` recense les villages CONSTRUITS et
## `--probe-pnj` vérifie le roster et la décimation, mais personne ne testait ce
## qui arrive à la LISTE D'HABITANTS quand un de ses membres disparaît.
##
## Trois choses se vérifient ici, et chacune correspond à un défaut constaté :
##   1. La liste d'habitants ne garde jamais une référence morte — c'était la
##      cause racine (`despawn` ne sortait pas l'habitant de son village).
##   2. Relâcher un village aux références abîmées n'interrompt pas la
##      fonction — la boucle typée levait l'erreur AVANT le garde de validité,
##      donc `erase(cell)` n'était jamais atteint et le tick suivant rejouait
##      exactement la même erreur. D'où la répétition sans fin.
##   3. Peupler un village ne fait pas exploser un tick — vingt corps riggés
##      instanciés d'un bloc donnaient les pics « [TICK] 62.3 ms » relevés en
##      jeu.

const TAG := "VILLAGEVIE"

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
		print("[%s] aucun générateur — sonde inexploitable." % TAG)
		main.get_tree().quit(1)
		return

	var cell := Vector2i.ZERO
	var plan := {}
	for radius in range(0, 40):
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if maxi(absi(dx), absi(dz)) != radius:
					continue
				var candidate: Dictionary = generator.city_at_cell(Vector2i(dx, dz))
				if not candidate.is_empty():
					cell = Vector2i(dx, dz)
					plan = candidate
					break
			if not plan.is_empty():
				break
		if not plan.is_empty():
			break
	if plan.is_empty():
		print("[%s] aucun village construit dans la zone de départ." % TAG)
		main.get_tree().quit(1)
		return

	VillageManager.casualties.clear()
	CreatureManager.call("_release_village", cell)
	_check_population_is_spread(cell, plan)
	_check_death_leaves_no_ghost(cell)
	_check_release_survives_a_dead_resident(cell)
	CreatureManager.call("_release_village", cell)
	VillageManager.casualties.clear()
	finish(_ok, TAG)


## LE PEUPLEMENT S'ÉTALE. Un village entier dans un seul tick, c'est le pic à
## 62 ms constaté en jeu : on vérifie que la mise en file existe VRAIMENT, en
## comptant les habitants sortis par vidange, et on chronomètre la vidange.
func _check_population_is_spread(cell: Vector2i, plan: Dictionary) -> void:
	# ON DÉCOMPOSE. « Peupler coûte 158 ms » ne désigne aucun coupable ; le
	# détail par étape, si — et ici il a désigné le bon, qui n'était pas celui
	# qu'on soupçonnait.
	var t0 := Time.get_ticks_usec()
	var kingdom: Dictionary = WorldManager.generator.kingdom_at_cell(cell)
	var kingdom_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	t0 = Time.get_ticks_usec()
	var kingdom_warm_ms := 0.0
	WorldManager.generator.kingdom_at_cell(cell)
	kingdom_warm_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	t0 = Time.get_ticks_usec()
	var roster := VillagePopulation.roster(cell, WorldManager.world_seed, plan,
			String(kingdom.get("culture", "")))
	var roster_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	print("[%s] détail : royaume %.1f ms à froid puis %.3f ms à chaud, roster %.1f ms (%d habitant(s))" % [
			TAG, kingdom_ms, kingdom_warm_ms, roster_ms, roster.size()])

	# LE VRAI COUPABLE DU PIC DE TICK, et ce n'était pas le spawn : générer les
	# royaumes d'un secteur neuf (capitales + territoires) coûte des centaines
	# de millisecondes, et `_populate_village` le déclenchait EN PLEIN TICK.
	# On n'assertit pas sur le coût à froid — c'est un calcul lourd préexistant,
	# hors du périmètre de cette sonde — mais on verrouille qu'il soit BIEN
	# UNIQUE : s'il redevenait payé à chaque appel, chaque tick le paierait.
	_expect(kingdom_warm_ms < 1.0,
			"le royaume d'une cellule n'est calculé qu'une fois (%.3f ms à chaud)" % kingdom_warm_ms)

	var start := Time.get_ticks_usec()
	CreatureManager.call("_populate_village", cell, plan)
	var enqueue_ms := float(Time.get_ticks_usec() - start) / 1000.0

	var immediate: int = (CreatureManager._populated_villages.get(cell, []) as Array).size()
	var queued: int = (CreatureManager._spawn_queue as Array).size()
	print("[%s] mise en file : %d habitant(s) en file, %d sortis, %.1f ms" % [
			TAG, queued, immediate, enqueue_ms])
	_expect(queued > 0, "les habitants passent par la file de spawn")
	_expect(enqueue_ms < TICK_BUDGET_MS,
			"la mise en file tient dans un tick (%.1f ms < %.0f)" % [enqueue_ms, TICK_BUDGET_MS])

	# LE VILLAGE EST MARQUÉ PEUPLÉ TOUT DE SUITE, même avec une liste vide :
	# sans ça le tick suivant remettrait le même village en file, encore et
	# encore, et la file grossirait sans fin.
	_expect(CreatureManager._populated_villages.has(cell),
			"le village est marqué peuplé dès la mise en file")

	var worst := 0.0
	var most_per_drain := 0
	for i in 200:
		if (CreatureManager._spawn_queue as Array).is_empty():
			break
		var had: int = (CreatureManager._populated_villages.get(cell, []) as Array).size()
		var t := Time.get_ticks_usec()
		CreatureManager.call("_drain_spawn_queue")
		worst = maxf(worst, float(Time.get_ticks_usec() - t) / 1000.0)
		most_per_drain = maxi(most_per_drain,
				(CreatureManager._populated_villages.get(cell, []) as Array).size() - had)
	var residents: int = (CreatureManager._populated_villages.get(cell, []) as Array).size()
	print("[%s] après vidange : %d habitant(s), au plus %d par vidange, pire vidange %.1f ms" % [
			TAG, residents, most_per_drain, worst])
	_expect(residents > 0, "les habitants finissent par arriver")

	# CE QU'ON CONTRÔLE : l'étalement. Le coût d'UN spawn (~20 ms pour un corps
	# riggé de 18 maillages) est une limite connue et préexistante du moteur,
	# supérieure au budget de tick à elle seule ; l'assertion porte donc sur le
	# nombre d'habitants par vidange, pas sur des millisecondes que cette sonde
	# ne peut pas faire baisser.
	_expect(most_per_drain <= CreatureManager.SPAWNS_PER_TICK,
			"au plus %d habitant(s) par tick" % CreatureManager.SPAWNS_PER_TICK)


## LA CAUSE RACINE. Retirer un habitant doit le sortir de la liste de son
## village ; sinon la liste garde un nœud libéré et le prochain parcours plante.
func _check_death_leaves_no_ghost(cell: Vector2i) -> void:
	var residents: Array = CreatureManager._populated_villages.get(cell, [])
	if residents.is_empty():
		_expect(false, "un habitant est disponible pour l'essai")
		return
	var before := residents.size()
	var victim: Node = residents[0]
	CreatureManager.despawn(victim)
	var after: int = (CreatureManager._populated_villages.get(cell, []) as Array).size()
	print("[%s] après retrait d'un habitant : %d → %d" % [TAG, before, after])
	_expect(after == before - 1, "l'habitant retiré sort de la liste de son village")

	# LE TÉMOIN QUI COMPTE : plus aucune référence morte dans la liste. C'est
	# exactement ce que la partie réelle avait, et que rien ne testait.
	var ghosts := 0
	for creature in CreatureManager._populated_villages.get(cell, []):
		if creature == null or not is_instance_valid(creature):
			ghosts += 1
	_expect(ghosts == 0, "aucune référence morte ne reste dans la liste (%d)" % ghosts)


## LA CONSÉQUENCE. Même si une référence morte se glissait dans la liste, la
## relâche doit aller jusqu'au bout : c'est elle qui retire le village du
## dictionnaire, et sans ça le tick suivant rejoue la même erreur pour toujours.
func _check_release_survives_a_dead_resident(cell: Vector2i) -> void:
	var residents: Array = CreatureManager._populated_villages.get(cell, [])
	if residents.is_empty():
		_expect(false, "un habitant reste pour l'essai de relâche")
		return
	# On fabrique EXPRÈS le cas pathologique : un nœud libéré laissé dans la
	# liste, comme le faisait `despawn` avant correction.
	var victim: Node = residents[0]
	CreatureManager.creatures.erase(victim)
	victim.free()
	print("[%s] liste sabotée avec 1 référence morte, on relâche le village" % TAG)

	CreatureManager.call("_release_village", cell)
	_expect(not CreatureManager._populated_villages.has(cell),
			"la relâche va jusqu'au bout malgré la référence morte")

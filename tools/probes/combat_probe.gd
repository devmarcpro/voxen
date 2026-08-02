extends Probe
## Sonde `--probe-combat` (2026-07-28) — combat DIRECTIONNEL de bout en bout.
##
## Ce qu'elle prouve, dans l'ordre où le joueur le vit : le geste de souris
## choisit un coup, le coup traverse ses phases en temps réel, la lame touche
## ce qu'elle croise et rien d'autre, la zone atteinte change les dégâts,
## l'endurance se paie même à vide, la garde absorbe puis casse, et l'ennemi
## télégraphie assez tôt pour qu'un pas en arrière suffise à l'éviter.
##
## POURQUOI ELLE SIMULE LES FRAMES À LA MAIN. Le timing de la frappe avance
## dans _process (exception assumée à E.1, voir MeleeAttack), pas au tick.
## Attendre de vraies frames rendrait la sonde dépendante du framerate de la
## machine : elle appelle donc `_advance_attack(dt)` avec un pas fixe, ce qui
## la rend déterministe et reproductible.

const TAG := "COMBAT"
## Pas de simulation : 60 Hz. Le combat doit se comporter pareil quel que soit
## le framerate — c'est justement ce que ce pas fixe vérifie.
const DT := 1.0 / 60.0


func run() -> void:
	await main.get_tree().process_frame
	player.apply_default_character()
	CreatureManager.natural_spawn_enabled = false  # Population maîtrisée.
	var ok := true

	ok = _check_gesture() and ok
	# TÔT, dans un monde encore intact : les tests suivants déplacent la
	# caméra et bâtissent des décors (auto-step), ce qui fausserait un test
	# de portée. Le cœur du système se vérifie sur un état propre.
	ok = await _check_all_directions_land() and ok
	ok = _check_weapon_stats() and ok
	ok = await _check_state_machine() and ok
	ok = await _check_geometric_hit() and ok
	ok = _check_zones_and_damage() and ok
	ok = await _check_stamina() and ok
	ok = _check_guard() and ok
	ok = await _check_creature_windup_and_dodge() and ok
	ok = _check_auto_step() and ok
	ok = _check_directional_guard() and ok
	ok = _check_sweet_spot() and ok
	ok = _check_speed_bonus() and ok
	ok = await _check_feint() and ok
	ok = _check_chambering() and ok
	ok = _check_turn_cap() and ok
	ok = _check_inertia_is_relative() and ok
	ok = _check_guard_is_locked() and ok
	ok = _check_shield() and ok

	finish(ok, TAG)


## LES QUATRE DIRECTIONS DOIVENT TOUCHER. Toutes les autres vérifications de
## frappe utilisaient l'estoc — la direction par défaut quand aucun geste n'est
## fourni. Trois des quatre arcs n'étaient donc JAMAIS exercés, et c'est ce trou
## qui a laissé passer « les attaques du haut vers le bas ne marchent pas »
## (2026-07-28). Un test qui n'exerce qu'un cas nominal ne teste qu'un quart du
## système.
func _check_all_directions_land() -> bool:
	_equip_sword()
	# DÉGAGER LA ZONE. Ce test tourne APRÈS celui de l'auto-step, qui laisse la
	# caméra sur une plateforme de pierre bâtie pour lui : les blocs alentour
	# arrêtaient la lame et trois directions sur quatre semblaient « ne pas
	# fonctionner » alors que le décor les bloquait. C'est la règle déjà apprise
	# ici même — un test qui frappe doit d'abord se ménager le vide autour.
	var origin := Vector3i(floori(camera.position.x), floori(camera.position.y),
		floori(camera.position.z))
	for dx in range(-4, 5):
		for dy in range(-4, 4):
			for dz in range(-4, 5):
				WorldManager.set_block(origin + Vector3i(dx, dy, dz), 0)
	await main.get_tree().process_frame
	var directions := [
		[MeleeAttack.Direction.ESTOC, Vector2(0.0, 60.0), "estoc"],
		[MeleeAttack.Direction.TAILLE_GAUCHE, Vector2(-90.0, 0.0), "taille gauche"],
		[MeleeAttack.Direction.TAILLE_DROITE, Vector2(90.0, 0.0), "taille droite"],
		[MeleeAttack.Direction.OVERHEAD, Vector2(0.0, -90.0), "overhead"],
	]
	var ok := true
	# Diagnostic de géométrie : sans lui, « coup porté=false » ne dit pas si la
	# cible est mal placée, l'arme absente, ou l'arc trop court.
	var probe_stats: Dictionary = player.call("_current_weapon_stats")
	var grip_probe: Vector3 = player.call("_grip_position", camera.global_basis)
	print("[%s]   caméra %s · prise %s · allonge %.2f" % [
		TAG, str(camera.global_position.round()), str(grip_probe.round()),
		float(probe_stats.get("reach", 0.0))])

	for entry: Array in directions:
		var target := _spawn_in_front(1.1)
		print("[%s]   cible à %s (écart prise→cible %.2f m)" % [
			TAG, str(target.logical_position.round()),
			grip_probe.distance_to(target.logical_position)])
		var hits := await _swing_in_direction(entry[1])
		var attack: MeleeAttack = player.get("_attack")
		var landed := hits.size() > 0
		var right_way: bool = attack.direction == entry[0]
		ok = ok and landed and right_way
		print("[%s] %-14s : direction retenue=%-14s coup porté=%s : %s" % [
			TAG, entry[2], MeleeAttack.direction_name(attack.direction), landed,
			"OK" if landed and right_way else "ÉCHEC"])
		_despawn(target)
	return ok


## Frappe complète avec un GESTE imposé, pour exercer une direction précise.
func _swing_in_direction(gesture: Vector2) -> Array:
	player.stamina = player.stamina_max
	var attack: MeleeAttack = player.get("_attack")
	attack.interrupt()
	player.call("_begin_attack")
	attack.feed_gesture(gesture)
	attack.release_input()
	var elapsed := 0.0
	while attack.is_busy() and elapsed < 5.0:
		player.call("_advance_attack", DT)
		elapsed += DT
	var pending: Array = (player.get("_pending_hits") as Array).duplicate()
	player.call("_resolve_pending_hits")
	var hits: Array = []
	for item: Dictionary in pending:
		if String(item.get("kind", "")) == "hit":
			hits.append(item)
	return hits


func _check_inertia_is_relative() -> bool:
	# SE DÉPLACER NE DOIT PAS FAIRE TRAÎNER LES BRAS. Le ressort d'inertie
	# suivait une cible en espace MONDE : en marchant, il accusait un retard
	# permanent de v × amortissement / raideur, soit ~60 cm pour une épée à
	# vitesse de marche. Les bras restaient derrière le corps (constaté en jeu
	# le 2026-07-28). Le ressort lisse désormais le DÉCALAGE à la caméra.
	_equip_sword()
	var attack: MeleeAttack = player.get("_attack")
	attack.interrupt()
	camera.rotation = Vector3.ZERO
	var start := camera.position

	# 1. TRANSLATION soutenue : le décalage doit converger vers ZÉRO.
	for i in 90:
		camera.position += Vector3(0.0, 0.0, -4.3 * DT)   # vitesse de marche
		player.call("hand_targets", 0.55, 0.28, DT)
	var walking_lag: float = (player.get("_lag_offset") as Vector3).length()
	var walk_ok := walking_lag < 0.05
	print("[%s] marche continue à 4,3 m/s : retard du bras = %.3f m (< 0.05) : %s" % [
		TAG, walking_lag, "OK" if walk_ok else "ÉCHEC"])

	# 2. Latéralement aussi — c'est le cas « à droite ils partent à gauche ».
	for i in 90:
		camera.position += Vector3(4.3 * DT, 0.0, 0.0)
		player.call("hand_targets", 0.55, 0.28, DT)
	var strafe_lag: float = (player.get("_lag_offset") as Vector3).length()
	var strafe_ok := strafe_lag < 0.05
	print("[%s] déplacement latéral : retard du bras = %.3f m (< 0.05) : %s" % [
		TAG, strafe_lag, "OK" if strafe_ok else "ÉCHEC"])

	# 3. Mais TOURNER doit toujours produire du ballant : c'est le poids de
	# l'arme, et le retirer viderait l'inertie de son sens.
	for i in 12:
		camera.rotation.y += deg_to_rad(9.0)
		player.call("hand_targets", 0.55, 0.28, DT)
	var turn_lag: float = (player.get("_lag_offset") as Vector3).length()
	var turn_ok := turn_lag > 0.03
	print("[%s] rotation vive : ballant conservé = %.3f m (> 0.03) : %s" % [
		TAG, turn_lag, "OK" if turn_ok else "ÉCHEC"])

	camera.position = start
	camera.rotation = Vector3.ZERO
	return walk_ok and strafe_ok and turn_ok


func _check_chambering() -> bool:
	# Attaquer DANS LA MÊME DIRECTION que le coup qui arrive, au bon moment.
	# La fenêtre est la phase de WIND-UP : ni trop tôt (l'arme serait déjà
	# armée), ni trop tard (elle ne serait pas partie).
	_equip_sword()
	player.stamina = player.stamina_max
	var attack: MeleeAttack = player.get("_attack")
	attack.interrupt()
	player.call("_begin_attack")
	# Traverser la lecture de geste pour entrer en WIND-UP.
	var elapsed := 0.0
	while attack.state != MeleeAttack.State.WINDUP and elapsed < 1.0:
		player.call("_advance_attack", DT)
		elapsed += DT
	var direction: int = attack.direction
	var chambers: bool = player.call("is_chambering", direction)
	var wrong_way: bool = player.call("is_chambering",
		MeleeAttack.Direction.OVERHEAD if direction != MeleeAttack.Direction.OVERHEAD
		else MeleeAttack.Direction.ESTOC)
	print("[%s] chambering en wind-up, même direction=%s · autre direction=%s : %s" % [
		TAG, chambers, wrong_way, "OK" if chambers and not wrong_way else "ÉCHEC"])

	# Une fois ARMÉE, il est TROP TARD : la fenêtre est passée.
	attack.release_input()
	var late := 0.0
	while attack.state == MeleeAttack.State.WINDUP and late < 2.0:
		player.call("_advance_attack", DT)
		late += DT
	var too_late: bool = not player.call("is_chambering", direction)
	print("[%s] fenêtre passée (état %d) : chambering refusé=%s : %s" % [
		TAG, attack.state, too_late, "OK" if too_late else "ÉCHEC"])
	attack.interrupt()
	return chambers and not wrong_way and too_late


func _check_turn_cap() -> bool:
	# Sans bridage, tourner vite pendant la frappe ajoute cette rotation à la
	# vitesse de la lame : le bonus de vitesse se farme en tournoyant. La caméra
	# reste libre, c'est l'ARC qui rattrape à vitesse bornée.
	_equip_sword()
	player.stamina = player.stamina_max
	camera.rotation = Vector3.ZERO
	var attack: MeleeAttack = player.get("_attack")
	attack.interrupt()
	# UNE ATTAQUE DOIT ÊTRE EN COURS : `_advance_attack` sort immédiatement
	# sinon, et le test passerait sans rien exercer (constaté : « arc tourné de
	# 0.00° » alors que le bridage n'avait jamais tourné).
	player.call("_begin_attack")
	var spin_up := 0.0
	while attack.state != MeleeAttack.State.WINDUP and spin_up < 1.0:
		player.call("_advance_attack", DT)
		spin_up += DT
	player.set("_swing_basis", camera.global_basis)
	# Demi-tour brutal de la caméra en UNE frame.
	camera.rotation = Vector3(0.0, PI, 0.0)
	player.call("_advance_attack", DT)
	var swing: Basis = player.get("_swing_basis")
	var turned := swing.get_rotation_quaternion().angle_to(Quaternion.IDENTITY)
	var allowed := deg_to_rad(110.0) * DT
	var ok := turned <= allowed * 1.5 + 0.001
	# Le bridage doit avoir REELLEMENT tourne un peu : a exactement 0 c'est
	# que le code n'a pas tourne du tout, et le test ne prouverait rien.
	var exercised := turned > 0.0001
	print("[%s] demi-tour caméra en 1 frame : arc tourné de %.2f° (plafond %.2f°, exercé=%s) : %s" % [
		TAG, rad_to_deg(turned), rad_to_deg(allowed), exercised,
		"OK" if ok and exercised else "ÉCHEC"])
	camera.rotation = Vector3.ZERO
	attack.interrupt()
	return ok and exercised


# --- Piliers Mount & Blade ------------------------------------------------

func _check_directional_guard() -> bool:
	# LA règle défensive de M&B : une taille venue de la droite adverse arrive
	# sur VOTRE gauche. Se tromper de direction = encaisser tout le coup.
	var pairs := [
		[MeleeAttack.Direction.TAILLE_DROITE, MeleeAttack.Direction.TAILLE_GAUCHE],
		[MeleeAttack.Direction.TAILLE_GAUCHE, MeleeAttack.Direction.TAILLE_DROITE],
		[MeleeAttack.Direction.OVERHEAD, MeleeAttack.Direction.OVERHEAD],
		[MeleeAttack.Direction.ESTOC, MeleeAttack.Direction.ESTOC],
	]
	var mapping_ok := true
	for pair: Array in pairs:
		var got: int = MeleeAttack.guard_for(pair[0])
		mapping_ok = mapping_ok and got == pair[1]
		print("[%s] attaque %-14s -> garde %-14s (attendu %s)" % [
			TAG, MeleeAttack.direction_name(pair[0]), MeleeAttack.direction_name(got),
			MeleeAttack.direction_name(pair[1])])
	print("[%s] correspondance attaque/garde : %s" % [TAG, "OK" if mapping_ok else "ÉCHEC"])

	# Et la garde du joueur doit RÉELLEMENT filtrer selon sa direction.
	_equip_sword()
	player.call("_set_guard", true)
	player.set("_guard_direction", MeleeAttack.Direction.TAILLE_GAUCHE)
	var covers_right: bool = player.call("guard_covers", MeleeAttack.Direction.TAILLE_DROITE)
	var covers_over: bool = player.call("guard_covers", MeleeAttack.Direction.OVERHEAD)
	player.call("_set_guard", false)
	var filter_ok := covers_right and not covers_over
	print("[%s] garde à gauche : pare une taille droite=%s, pare un overhead=%s : %s" % [
		TAG, covers_right, covers_over, "OK" if filter_ok else "ÉCHEC"])
	return mapping_ok and filter_ok


func _check_sweet_spot() -> bool:
	# Frapper au MANCHE ne doit rien faire : c'est ce qui punit d'être trop
	# près avec une arme longue, et ce qui donne un rôle aux armes courtes.
	var reach := 1.5
	var at_grip := WeaponStats.sweet_spot_factor(0.15, reach)
	var mid := WeaponStats.sweet_spot_factor(0.70, reach)
	var tip := WeaponStats.sweet_spot_factor(1.40, reach)
	var ok: bool = is_zero_approx(at_grip) and mid > 0.0 and mid < 1.0 and is_equal_approx(tip, 1.0)
	print("[%s] sweet spot sur 1,50 m : garde(0,15)=%.2f milieu(0,70)=%.2f pointe(1,40)=%.2f : %s" % [
		TAG, at_grip, mid, tip, "OK" if ok else "ÉCHEC"])
	return ok


func _check_speed_bonus() -> bool:
	# La mécanique signature : avancer en frappant fait mal, reculer fait peu.
	var nominal := 14.0
	var charging := WeaponStats.speed_factor(nominal, 5.0)
	var still := WeaponStats.speed_factor(nominal, 0.0)
	var retreating := WeaponStats.speed_factor(nominal, -5.0)
	var ok: bool = charging > still and still > retreating and is_equal_approx(still, 1.0)
	print("[%s] bonus de vitesse : en charge=%.2f immobile=%.2f en recul=%.2f : %s" % [
		TAG, charging, still, retreating, "OK" if ok else "ÉCHEC"])
	# Et il doit rester BORNÉ : M&B est un jeu de placement, pas une course.
	var absurd := WeaponStats.speed_factor(nominal, 500.0)
	var bounded: bool = absurd <= WeaponStats.SPEED_BONUS_MAX + 0.001
	print("[%s] borné même à vitesse absurde : %.2f (max %.2f) : %s" % [
		TAG, absurd, WeaponStats.SPEED_BONUS_MAX, "OK" if bounded else "ÉCHEC"])
	return ok and bounded


func _check_feint() -> bool:
	# FEINTE : lever sa garde ANNULE une attaque en préparation. C'est le geste
	# central de M&B — armer pour appâter une parade, annuler, frapper ailleurs.
	_equip_sword()
	player.stamina = player.stamina_max
	player.call("_begin_attack")
	var attack: MeleeAttack = player.get("_attack")
	for i in 20:
		player.call("_advance_attack", DT)
	var was_busy := attack.is_busy()
	player.call("_set_guard", true)
	var cancelled := not attack.is_busy()
	player.call("_set_guard", false)
	print("[%s] feinte : attaque armée=%s puis annulée par la garde=%s : %s" % [
		TAG, was_busy, cancelled, "OK" if was_busy and cancelled else "ÉCHEC"])

	# Mais une frappe DÉJÀ PARTIE ne s'annule pas : on assume son coup.
	player.call("_begin_attack")
	attack.release_input()
	var guarded_elapsed := 0.0
	while attack.state != MeleeAttack.State.RELEASE and guarded_elapsed < 3.0:
		player.call("_advance_attack", DT)
		guarded_elapsed += DT
	player.call("_set_guard", true)
	var still_swinging: bool = attack.state == MeleeAttack.State.RELEASE
	player.call("_set_guard", false)
	attack.interrupt()
	print("[%s] frappe déjà partie : non annulable=%s : %s" % [
		TAG, still_swinging, "OK" if still_swinging else "ÉCHEC"])
	await main.get_tree().process_frame
	return was_busy and cancelled and still_swinging


# --- 1. Le geste de souris choisit le coup -------------------------------

func _check_gesture() -> bool:
	# Repère écran : x positif = souris vers la droite, y positif = vers le bas.
	var cases := [
		[Vector2(60, 0), MeleeAttack.Direction.TAILLE_DROITE, "taille droite"],
		[Vector2(-60, 0), MeleeAttack.Direction.TAILLE_GAUCHE, "taille gauche"],
		# Convention Mount & Blade ET cohérence avec le HUD : on ARME vers le
		# HAUT pour frapper vers le bas. `y` est en coordonnées écran.
		[Vector2(0, -60), MeleeAttack.Direction.OVERHEAD, "overhead (souris vers le HAUT)"],
		[Vector2(0, 60), MeleeAttack.Direction.ESTOC, "estoc (souris vers le bas)"],
		[Vector2(3, 2), MeleeAttack.Direction.ESTOC, "estoc (geste trop faible)"],
	]
	var ok := true
	for case: Array in cases:
		var got: int = MeleeAttack._resolve_direction(case[0])
		var good: bool = got == case[1]
		ok = ok and good
		print("[%s] geste %-12s -> %-14s : %s" % [
			TAG, str(case[0]), MeleeAttack.direction_name(got), "OK" if good else "ATTENDU " + str(case[2])])
	return ok


# --- 2. Les stats découlent bien des matériaux ---------------------------

func _check_weapon_stats() -> bool:
	# Même arme, deux matériaux de densité opposée : la dérivation doit
	# produire un écart franc, sinon « la densité pilote la vitesse » (A.4.1)
	# n'est qu'un commentaire.
	var light := ItemFactory.craft("epee", {"bois": "balsa", "minerai": "cuivre"}, 1.0)
	var heavy := ItemFactory.craft("epee", {"bois": "gaiac", "minerai": "plomb"}, 1.0)
	var fn: Dictionary = GameData.functionalities["epee"]
	var s_light := WeaponStats.derive(fn, light)
	var s_heavy := WeaponStats.derive(fn, heavy)
	# Le poids est dans l'unité d'ItemFactory (densité × quantité), PAS en kg —
	# ne pas lui coller une unité qu'il n'a pas.
	print("[%s] épée légère (poids %.1f) : wind-up %.0f ms, parade %.0f ms, endurance %.1f" % [
		TAG, s_light["weight"], s_light["windup_ms"], s_light["parry_window_ms"], s_light["stamina_cost"]])
	print("[%s] épée lourde (poids %.1f) : wind-up %.0f ms, parade %.0f ms, endurance %.1f" % [
		TAG, s_heavy["weight"], s_heavy["windup_ms"], s_heavy["parry_window_ms"], s_heavy["stamina_cost"]])
	var ok: bool = s_heavy["weight"] > s_light["weight"] \
		and s_heavy["windup_ms"] > s_light["windup_ms"] \
		and s_heavy["parry_window_ms"] < s_light["parry_window_ms"] \
		and s_heavy["stamina_cost"] > s_light["stamina_cost"]
	print("[%s] lourde = plus lente, parade plus serrée, plus coûteuse : %s" % [TAG, "OK" if ok else "ÉCHEC"])

	# Le contondant draine plus la garde que le tranchant à poids comparable.
	var mace := ItemFactory.craft("masse", {"bois": "chene", "minerai": "fer"}, 1.0)
	var sword := ItemFactory.craft("epee", {"bois": "chene", "minerai": "fer"}, 1.0)
	var drain_mace: float = WeaponStats.derive(GameData.functionalities["masse"], mace)["stamina_drain"]
	var drain_sword: float = WeaponStats.derive(fn, sword)["stamina_drain"]
	var blunt_ok: bool = drain_mace > drain_sword
	print("[%s] drain de garde : masse=%.1f épée=%.1f (contondant doit dominer) : %s" % [
		TAG, drain_mace, drain_sword, "OK" if blunt_ok else "ÉCHEC"])
	# PIÈCES : allonge et écart des mains DÉDUITS du manche et de la tête.
	# C'est « la magie de la longueur du manche » — rien n'est animé ni écrit
	# à la main, la posture se déduit de l'arme tenue.
	print("[%s] --- pièces : allonge et prise déduites ---" % TAG)
	var rows := [["dague", "court"], ["epee", "moyen"], ["hache_arme", "long"],
		["lance", "tres_long"], ["espadon", "long"]]
	var reaches := {}
	for row: Array in rows:
		var wid: String = row[0]
		var stats := WeaponStats.derive(GameData.functionalities[wid], {})
		reaches[wid] = float(stats["reach"])
		print("[%s]   %-12s manche=%-10s allonge=%.2f  écart des mains=%.2f" % [
			TAG, wid, row[1], stats["reach"], stats["hand_separation"]])
	# Ce qui doit être vrai : la dague est la plus courte, la lance la plus
	# longue, et un espadon porte plus loin qu'une épée.
	#
	# CE QU'ON N'EXIGE PAS : que la hache d'armes dépasse l'épée. Sa tête est
	# compacte (0,34) là où une lame moyenne fait 0,75 : manche plus long,
	# allonge comparable. C'est physiquement juste, et la première version de
	# ce test l'avait exigé à tort — l'attente était fausse, pas la donnée.
	var reach_ok: bool = reaches["lance"] > reaches["espadon"] \
		and reaches["espadon"] > reaches["epee"] and reaches["epee"] > reaches["dague"]
	print("[%s] allonge : dague < épée < espadon < lance : %s" % [
		TAG, "OK" if reach_ok else "ÉCHEC"])

	# Une arme à UNE main ne doit écarter aucune seconde main ; une arme à deux
	# mains d'autant plus que son manche est long.
	var one_hand := float(WeaponStats.derive(GameData.functionalities["dague"], {})["hand_separation"])
	var polearm := float(WeaponStats.derive(GameData.functionalities["lance"], {})["hand_separation"])
	var two_hand := float(WeaponStats.derive(GameData.functionalities["hache_arme"], {})["hand_separation"])
	var grip_ok: bool = is_zero_approx(one_hand) and polearm > two_hand and two_hand > 0.0
	print("[%s] écart des mains : dague=%.2f hache=%.2f lance=%.2f (0 / croissant) : %s" % [
		TAG, one_hand, two_hand, polearm, "OK" if grip_ok else "ÉCHEC"])
	# INERTIE : la main est tirée par un ressort dont la MASSE de l'arme décide
	# de la mollesse. On simule 30 frames d'un déplacement brusque de cible et
	# on mesure le retard restant : une arme lourde doit traîner davantage.
	print("[%s] --- inertie : retard après un mouvement brusque ---" % TAG)
	var lags := {}
	for weapon_id: String in ["dague", "epee", "marteau_guerre"]:
		var stats := WeaponStats.derive(GameData.functionalities[weapon_id], {})
		var current := Vector3.ZERO
		var velocity := Vector3.ZERO
		var goal := Vector3(1.0, 0.0, 0.0)
		var stiffness := float(stats["inertia_stiffness"])
		var damping := float(stats["inertia_damping"])
		for i in 6:   # 0,1 s à 60 Hz : le temps d'un début de geste
			var acceleration := (goal - current) * stiffness - velocity * damping
			velocity += acceleration * DT
			current += velocity * DT
		lags[weapon_id] = goal.distance_to(current)
		print("[%s]   %-15s raideur=%.0f amortissement=%.1f · retard=%.3f" % [
			TAG, weapon_id, stiffness, damping, lags[weapon_id]])
	var inertia_ok: bool = lags["marteau_guerre"] > lags["epee"] and lags["epee"] > lags["dague"]
	print("[%s] plus l'arme est lourde, plus elle traîne : %s" % [
		TAG, "OK" if inertia_ok else "ÉCHEC"])

	# Et le ressort doit CONVERGER : un retard permanent décalerait l'arme de
	# sa cible pour toujours, et donc la hitbox avec elle.
	var settle := Vector3.ZERO
	var settle_velocity := Vector3.ZERO
	var settle_stats := WeaponStats.derive(GameData.functionalities["marteau_guerre"], {})
	for i in 240:
		var acceleration := (Vector3.RIGHT - settle) * float(settle_stats["inertia_stiffness"]) \
			- settle_velocity * float(settle_stats["inertia_damping"])
		settle_velocity += acceleration * DT
		settle += settle_velocity * DT
	var settled: bool = settle.distance_to(Vector3.RIGHT) < 0.01
	print("[%s] au repos le ressort converge (résidu %.4f < 0.01) : %s" % [
		TAG, settle.distance_to(Vector3.RIGHT), "OK" if settled else "ÉCHEC"])
	return ok and blunt_ok and reach_ok and grip_ok and inertia_ok and settled


# --- 3. La machine à états traverse ses phases ---------------------------

func _check_state_machine() -> bool:
	_equip_sword()
	var stats: Dictionary = player.call("_current_weapon_stats")
	var attack := MeleeAttack.new()
	attack.begin(stats)
	var seen: Array[String] = []
	var elapsed := 0.0

	# 1. BOUTON MAINTENU : l'arme s'arme puis ATTEND, indéfiniment. Rien ne
	# doit partir tout seul — c'est toute la demande du 2026-07-28.
	while elapsed < 3.0:
		var event := attack.advance(DT)
		if event != "":
			seen.append(event)
		elapsed += DT
	var held_ok: bool = attack.state == MeleeAttack.State.ARMEE and not seen.has("release")
	print("[%s] bouton maintenu 3 s : état=ARMEE=%s, aucune frappe partie=%s : %s" % [
		TAG, attack.state == MeleeAttack.State.ARMEE, not seen.has("release"),
		"OK" if held_ok else "ÉCHEC"])

	# 2. La direction est VERROUILLÉE : un geste franc pendant la garde armée ne
	# doit plus rien changer (2026-08-01). C'est ce verrou qui donne son prix à
	# la feinte — sans lui, annuler son coup pour en porter un autre serait
	# absurde puisqu'un mouvement de souris suffirait.
	var before: int = attack.direction
	attack.feed_gesture(Vector2(140.0, 0.0))   # geste franc vers la droite
	var redirected := false
	for i in 10:
		if attack.advance(DT) == "redirige":
			redirected = true
	var change_ok: bool = not redirected and attack.direction == before
	print("[%s] direction VERROUILLÉE pendant la garde armée (reste %s) : %s" % [
		TAG, MeleeAttack.direction_name(attack.direction), "OK" if change_ok else "ÉCHEC"])

	# 3. RELÂCHEMENT : la frappe part, puis le cycle se termine.
	attack.release_input()
	var after: Array[String] = []
	elapsed = 0.0
	while attack.is_busy() and elapsed < 5.0:
		var event := attack.advance(DT)
		if event != "":
			after.append(event)
		elapsed += DT
	var fire_ok: bool = after.has("release") and after.has("done") and not attack.is_busy()
	print("[%s] au relâchement : %s (attendu release puis done) : %s" % [
		TAG, str(after), "OK" if fire_ok else "ÉCHEC"])
	return held_ok and change_ok and fire_ok


# --- 4. La lame touche ce qu'elle croise, et rien d'autre ----------------

func _check_geometric_hit() -> bool:
	_equip_sword()
	var ok := true

	# a) Cible DEVANT, à portée : doit être touchée ET perdre des PV. Compter
	# les coups ne suffit pas — c'est la chaîne complète (géométrie → file
	# d'attente → tick → dégâts) qui doit aboutir.
	var target := _spawn_in_front(1.2)
	var hp_before: float = target.health
	var hit_front := await _swing_and_collect()
	var front_ok: bool = hit_front.size() > 0 and target.health < hp_before
	print("[%s] cible devant à 1,2 m : %d coup(s), PV %.0f → %.0f (attendu ≥1 et en baisse) : %s" % [
		TAG, hit_front.size(), hp_before, target.health, "OK" if front_ok else "ÉCHEC"])
	ok = ok and front_ok
	# La zone atteinte doit être nommée : c'est elle qui porte le multiplicateur.
	if hit_front.size() > 0:
		print("[%s]   zone touchée : %s (×%.1f)" % [
			TAG, hit_front[0]["zone"], float(hit_front[0]["mult"])])
	_despawn(target)

	# b) Cible DERRIÈRE : la lame ne doit jamais la trouver. C'est la promesse
	# du combat directionnel — plus de verrouillage qui frappe dans le dos.
	var behind := _spawn_in_front(-1.2)
	var hit_behind := await _swing_and_collect()
	var behind_ok: bool = hit_behind.is_empty()
	print("[%s] cible DERRIÈRE : %d coup(s) (attendu 0) : %s" % [
		TAG, hit_behind.size(), "OK" if behind_ok else "ÉCHEC"])
	ok = ok and behind_ok
	_despawn(behind)

	# c) Cible HORS D'ALLONGE : reculer suffit à être hors de danger.
	var far := _spawn_in_front(6.0)
	var hit_far := await _swing_and_collect()
	var far_ok: bool = hit_far.is_empty()
	print("[%s] cible à 6 m (hors allonge) : %d coup(s) (attendu 0) : %s" % [
		TAG, hit_far.size(), "OK" if far_ok else "ÉCHEC"])
	ok = ok and far_ok
	_despawn(far)

	# d) LA VISÉE DOIT COMPTER. Contre un humanoïde de même taille, une frappe
	# à l'horizontale doit atteindre le TORSE ; il faut lever le regard pour
	# toucher la tête. Sans ça, le multiplicateur ×2.5 serait acquis à chaque
	# coup et la visée n'aurait aucun sens (défaut réel trouvé ici même : la
	# prise de l'arme était posée à hauteur d'œil).
	var pitch_before := camera.rotation.x
	camera.rotation.x = 0.0
	var level_target := _spawn_in_front(1.2)
	var level_hits := await _swing_and_collect()
	var level_zone: String = String(level_hits[0]["zone"]) if level_hits.size() > 0 else "(aucune)"
	var level_ok: bool = level_zone == "torse"
	print("[%s] frappe à plat : zone=%s (attendu torse) : %s" % [
		TAG, level_zone, "OK" if level_ok else "ÉCHEC"])
	_despawn(level_target)

	camera.rotation.x = deg_to_rad(18.0)  # regard vers le HAUT
	var high_target := _spawn_in_front(1.2)
	var high_hits := await _swing_and_collect()
	var high_zone: String = String(high_hits[0]["zone"]) if high_hits.size() > 0 else "(aucune)"
	var high_ok: bool = high_zone == "tete"
	print("[%s] frappe en visant haut : zone=%s (attendu tete) : %s" % [
		TAG, high_zone, "OK" if high_ok else "ÉCHEC"])
	_despawn(high_target)
	camera.rotation.x = pitch_before
	return ok and level_ok and high_ok


# --- 5. La zone touchée change les dégâts --------------------------------

func _check_zones_and_damage() -> bool:
	var zones: Array = GameData.hitbox_templates.get("humanoide", [])
	var by_id := {}
	for zone: Dictionary in zones:
		by_id[zone["id"]] = float(zone["mult"])
	var ok: bool = by_id.get("tete", 0.0) > by_id.get("torse", 0.0) \
		and by_id.get("torse", 0.0) > by_id.get("bras_gauche", 0.0)
	print("[%s] multiplicateurs : tête=%.1f torse=%.1f bras=%.1f (tête > torse > bras) : %s" % [
		TAG, by_id.get("tete", 0.0), by_id.get("torse", 0.0), by_id.get("bras_gauche", 0.0),
		"OK" if ok else "ÉCHEC"])

	# Sur 300 coups identiques, viser la tête doit payer — et le critique ne
	# doit plus dépendre d'un dé (il n'y a plus de nat 20).
	var head_total := 0
	var body_total := 0
	var crits := 0
	for i in 300:
		var head := CombatResolver.resolve_hit(5, 5, "2d6", 20.0, 1.0, false, "", by_id["tete"], 0.0)
		var body := CombatResolver.resolve_hit(5, 5, "2d6", 20.0, 1.0, false, "", by_id["torse"], 0.0)
		head_total += int(head["damage"])
		body_total += int(body["damage"])
		crits += 1 if head["critical"] else 0
	var ratio := float(head_total) / maxf(float(body_total), 1.0)
	var damage_ok: bool = ratio > 2.0 and crits == 300
	print("[%s] 300 coups : tête=%d torse=%d (ratio %.2f) · critiques tête=%d/300 : %s" % [
		TAG, head_total, body_total, ratio, crits, "OK" if damage_ok else "ÉCHEC"])

	# La pénétration ronge la MITIGATION, pas les dégâts bruts.
	var mitigated := 0
	var pierced := 0
	for i in 300:
		mitigated += int(CombatResolver.resolve_hit(5, 5, "2d6", 20.0, 1.0, false, "4d6", 1.0, 0.0)["damage"])
		pierced += int(CombatResolver.resolve_hit(5, 5, "2d6", 20.0, 1.0, false, "4d6", 1.0, 0.8)["damage"])
	var pen_ok: bool = pierced > mitigated
	print("[%s] armure 4d6 : sans pénétration=%d avec 80%%=%d (doit augmenter) : %s" % [
		TAG, mitigated, pierced, "OK" if pen_ok else "ÉCHEC"])

	# Le triplet d'armure : la plaque arrête l'épée, elle subit la masse.
	var plate_slash := WeaponStats.armor_type_modifier("minerai", "tranchant")
	var plate_blunt := WeaponStats.armor_type_modifier("minerai", "contondant")
	var cloth_blunt := WeaponStats.armor_type_modifier("textile", "contondant")
	var type_ok: bool = plate_slash > 1.0 and plate_blunt < 1.0 and cloth_blunt > 1.0
	print("[%s] plaque vs tranchant=%.2f vs contondant=%.2f · rembourré vs contondant=%.2f : %s" % [
		TAG, plate_slash, plate_blunt, cloth_blunt, "OK" if type_ok else "ÉCHEC"])
	return ok and damage_ok and pen_ok and type_ok


# --- 6. L'endurance se paie, même dans le vide ---------------------------

func _check_stamina() -> bool:
	_equip_sword()
	player.stamina = player.stamina_max
	var before: float = player.stamina
	# Aucune cible : le coup part dans le vide et doit COÛTER quand même.
	await _swing_and_collect()
	var after: float = player.stamina
	var spent_ok: bool = after < before
	print("[%s] coup dans le vide : endurance %.1f → %.1f (doit baisser) : %s" % [
		TAG, before, after, "OK" if spent_ok else "ÉCHEC"])

	# Régénération bloquée juste après la dépense, puis reprise.
	var blocked: float = player.stamina
	player.call("_stamina_tick")
	var still_blocked: bool = is_equal_approx(float(player.stamina), blocked)
	for i in 20:
		player.call("_stamina_tick")
	var regen_ok: bool = player.stamina > blocked and still_blocked
	print("[%s] régén : bloquée juste après (%s), puis %.1f → %.1f : %s" % [
		TAG, "oui" if still_blocked else "NON", blocked, player.stamina, "OK" if regen_ok else "ÉCHEC"])

	# À sec, on ne lance plus de coup : c'est le frein anti-clic-frénétique.
	player.stamina = 0.0
	player.call("_begin_attack")
	var idle_attack: MeleeAttack = player.get("_attack")
	var empty_ok: bool = not idle_attack.is_busy()
	print("[%s] attaque sans endurance : refusée=%s : %s" % [
		TAG, "oui" if empty_ok else "NON", "OK" if empty_ok else "ÉCHEC"])
	player.stamina = player.stamina_max
	return spent_ok and regen_ok and empty_ok


# --- 7. La garde absorbe, puis casse -------------------------------------

func _check_guard() -> bool:
	_equip_sword()
	player.stamina = player.stamina_max
	var ok := true

	# Garde levée à l'instant : dans la fenêtre de parade.
	player.call("_set_guard", true)
	var state: Dictionary = player.call("guard_state")
	var parry_ok: bool = bool(state["guarding"]) and bool(state["parry"])
	print("[%s] garde levée à l'instant : garde=%s parade=%s : %s" % [
		TAG, state["guarding"], state["parry"], "OK" if parry_ok else "ÉCHEC"])
	ok = ok and parry_ok

	# La parade coûte MOINS que la garde passive : c'est la récompense du
	# timing, et la seule différence mécanique entre parer et subir.
	player.stamina = player.stamina_max
	player.call("absorb_on_guard", 20.0, true)
	var cost_parry: float = player.stamina_max - player.stamina
	player.stamina = player.stamina_max
	player.call("absorb_on_guard", 20.0, false)
	var cost_hold: float = player.stamina_max - player.stamina
	var reward_ok: bool = cost_parry < cost_hold
	print("[%s] coût du blocage : parade=%.1f garde tenue=%.1f (parade doit coûter moins) : %s" % [
		TAG, cost_parry, cost_hold, "OK" if reward_ok else "ÉCHEC"])
	ok = ok and reward_ok

	# Sans endurance, la garde CASSE et le coup passe en entier.
	player.stamina = 1.0
	player.call("_set_guard", true)
	var held: bool = player.call("absorb_on_guard", 50.0, false)
	var break_ok: bool = not held and not bool(player.get("_guard_active"))
	print("[%s] garde à 1 endurance contre un drain de 50 : tenue=%s (attendu non) : %s" % [
		TAG, held, "OK" if break_ok else "ÉCHEC"])
	player.stamina = player.stamina_max
	player.call("_set_guard", false)
	return ok and break_ok


# --- 8. L'ennemi télégraphie, et un pas en arrière suffit ----------------

func _check_creature_windup_and_dodge() -> bool:
	var creature := _spawn_in_front(1.0, "bandit")
	creature.set("ai_profile", "hostile")
	var declared := [false]
	var handler := func(attacker: Variant, _direction: String) -> void:
		if attacker == creature:
			declared[0] = true
	EventBus.attack_telegraphed.connect(handler)

	# Premier tick : la créature DÉCLARE, elle ne frappe pas encore.
	var first: Dictionary = creature.tick_step(player.get_position_for_ai(), player)
	var telegraph_ok: bool = declared[0] and first.is_empty()
	print("[%s] créature à portée : déclare=%s frappe immédiate=%s (attendu oui/non) : %s" % [
		TAG, declared[0], not first.is_empty(), "OK" if telegraph_ok else "ÉCHEC"])
	EventBus.attack_telegraphed.disconnect(handler)

	# Le coup finit par partir si on ne bouge pas.
	var landed := false
	for i in 30:
		if not creature.tick_step(player.get_position_for_ai(), player).is_empty():
			landed = true
			break
	print("[%s] wind-up écoulé sans bouger : le coup part=%s (attendu oui) : %s" % [
		TAG, landed, "OK" if landed else "ÉCHEC"])

	# ESQUIVE GÉOMÉTRIQUE : reculer hors d'allonge pendant le wind-up doit
	# annuler le coup et créditer l'Esquive — plus aucun jet de dé là-dedans.
	var hp_before: float = player.health
	creature.tick_step(player.get_position_for_ai(), player)      # déclaration
	creature.logical_position = player.get_position_for_ai() + Vector3(0.0, -0.9, 0.0) + Vector3(12.0, 0.0, 0.0)
	var dodged := true
	for i in 30:
		var event: Dictionary = creature.tick_step(player.get_position_for_ai(), player)
		if not event.is_empty():
			CreatureManager.call("_resolve_creature_attack", creature, player)
			break
	dodged = is_equal_approx(float(player.health), hp_before)
	print("[%s] sortie d'allonge pendant le wind-up : PV %.0f → %.0f (attendu inchangés) : %s" % [
		TAG, hp_before, player.health, "OK" if dodged else "ÉCHEC"])
	_despawn(creature)
	return telegraph_ok and landed and dodged


# --- 9. Le franchissement automatique ------------------------------------

func _check_auto_step() -> bool:
	# Plateforme SYNTHÉTIQUE plutôt que le terrain généré : en mode sonde le
	# joueur démarre en survol, et les chunks sous lui ne sont pas forcément
	# streamés — la première version de ce test se contentait alors de
	# s'ignorer lui-même, ce qui est le pire résultat possible (un test vert
	# qui n'a rien testé). Ici on POSE le décor, donc il existe toujours.
	var stone: int = GameData.material_runtime_ids.get("pierre", 1)
	var base := Vector3i(int(camera.position.x) + 6, floori(camera.position.y) - 10, int(camera.position.z))
	# DÉGAGER D'ABORD. La plateforme est bâtie DANS le terrain réel, dont le
	# contenu dépend du point de spawn — lui-même variable d'un lancement à
	# l'autre (monde sauvegardé rechargé). Un bloc de terrain à hauteur de tête
	# faisait refuser le franchissement, et le test échouait sans qu'aucun code
	# ne soit en cause. On vide la zone pour que SEUL le décor posé compte.
	for dx in range(-2, 5):
		for dz in range(-3, 4):
			for dy in range(0, 6):
				WorldManager.set_block(Vector3i(base.x + dx, base.y + dy, base.z + dz), 0)
	for dx in range(-1, 4):
		for dz in range(-2, 3):
			WorldManager.set_block(Vector3i(base.x + dx, base.y, base.z + dz), stone)
	for dz in range(-2, 3):
		WorldManager.set_block(Vector3i(base.x + 2, base.y + 1, base.z + dz), stone)

	# Relecture : si le décor n'a pas pris, le test doit ÉCHOUER, pas passer.
	var placed_ok: bool = WorldManager.block_at_world(Vector3i(base.x, base.y, base.z)) == stone \
		and WorldManager.block_at_world(Vector3i(base.x + 2, base.y + 1, base.z)) == stone
	print("[%s] décor de test posé (sol y=%d, marche y=%d) : %s" % [
		TAG, base.y, base.y + 1, "OK" if placed_ok else "ÉCHEC"])
	if not placed_ok:
		return false

	var ground := base.y
	var feet := float(ground + 1)
	camera.position = Vector3(float(base.x) + 0.5, feet + FlyCamera.EYE_HEIGHT, float(base.z) + 0.5)
	var blocked: bool = camera.call("_body_blocked_at", float(base.x) + 2.5, float(base.z) + 0.5, feet)
	var stepped: float = camera.call("_try_step_up", float(base.x) + 2.5, float(base.z) + 0.5, feet)
	var ok: bool = blocked and not is_nan(stepped) and is_equal_approx(stepped, feet + 1.0)
	print("[%s] marche d'1 bloc : bloquée=%s franchissable à y=%.1f (attendu %.1f) : %s" % [
		TAG, blocked, stepped, feet + 1.0, "OK" if ok else "ÉCHEC"])

	# Un mur de DEUX blocs ne se franchit pas : le relief garde son sens.
	for dz in range(-2, 3):
		WorldManager.set_block(Vector3i(base.x + 2, ground + 2, base.z + dz),
			GameData.material_runtime_ids.get("pierre", 1))
	var wall: float = camera.call("_try_step_up", float(base.x) + 2.5, float(base.z) + 0.5, feet)
	var wall_ok: bool = is_nan(wall)
	print("[%s] mur de 2 blocs : refusé=%s (attendu oui) : %s" % [
		TAG, wall_ok, "OK" if wall_ok else "ÉCHEC"])
	return ok and wall_ok


# --- Utilitaires ---------------------------------------------------------

## Équipe une épée en fer et la met EN MAIN (liaison de hotbar directe : la
## sonde n'a pas d'UI à traverser).
func _equip_sword() -> void:
	var sword := ItemFactory.craft("epee", {"bois": "chene", "minerai": "fer"}, 1.0)
	player.inventory.add_object(sword)
	player.hotbar_bindings[0] = {"kind": "object", "uid": int(sword["uid"])}
	player.active_hotbar = 0
	player.selected_slot = 0


## Déclenche une frappe complète en simulant les frames, et retourne les coups
## constatés (le tick ne les a pas encore appliqués).
func _swing_and_collect() -> Array:
	player.call("_begin_attack")
	var attack: MeleeAttack = player.get("_attack")
	# Le bouton est considéré MAINTENU dès `begin` : sans relâchement explicite
	# l'arme resterait armée pour toujours et cette boucle tournerait jusqu'à
	# sa borne de sécurité. On relâche donc immédiatement — un coup « au plus
	# vite », ce que mesure le reste de la sonde.
	attack.release_input()
	var elapsed := 0.0
	while attack.is_busy() and elapsed < 5.0:
		player.call("_advance_attack", DT)
		elapsed += DT
	var pending: Array = (player.get("_pending_hits") as Array).duplicate()
	# Le tick est la seule autorité : c'est lui qui applique (et vide la file).
	player.call("_resolve_pending_hits")
	var hits: Array = []
	for entry: Dictionary in pending:
		if String(entry.get("kind", "")) == "hit":
			hits.append(entry)
	return hits


## Fait apparaître une créature à `distance` mètres DEVANT la caméra
## (distance négative = derrière), à hauteur de corps.
func _spawn_in_front(distance: float, creature_id: String = "bandit") -> Node:
	var forward := -camera.global_basis.z
	forward.y = 0.0
	forward = forward.normalized()
	var origin: Vector3 = camera.global_position + Vector3(0.0, -FlyCamera.EYE_HEIGHT, 0.0)
	var spot := origin + forward * distance
	var creature := CreatureManager.spawn(creature_id, spot)
	# La position LOGIQUE est celle que lit le combat (voir sweep_segment) :
	# la position affichée est lissée et en retard d'une interpolation.
	creature.logical_position = spot
	creature.position = spot
	return creature


func _despawn(creature: Node) -> void:
	if is_instance_valid(creature):
		CreatureManager.creatures.erase(creature)
		creature.queue_free()


## Indice du premier bloc solide sous une position, ou -9999.
func _solid_ground_under(pos: Vector3) -> int:
	var bx := floori(pos.x)
	var bz := floori(pos.z)
	for wy in range(floori(pos.y), floori(pos.y) - 40, -1):
		if WorldManager.block_at_world(Vector3i(bx, wy, bz)) != 0:
			return wy
	return -9999


## LA GARDE SE VERROUILLE, ELLE AUSSI (2026-08-01).
##
## Ce que ce test défend : une garde qui suit la souris en continu n'est plus un
## pari, c'est un bouton. Elle se replaçait toute seule dès qu'on tournait la
## tête pour suivre un adversaire, et il devenait impossible de tenir une garde
## haute en regardant ailleurs. Changer de garde doit coûter une baisse et une
## relevée — c'est le risque qui fait le duel.
func _check_guard_is_locked() -> bool:
	var ok := true
	player.call("_set_guard", false)
	player.call("_set_guard", true)

	# Pendant la LECTURE, rien n'est figé et la posture reste au port : montrer
	# une garde serait annoncer un choix qui n'est pas encore fait.
	var reading_locked: bool = bool(player.get("_guard_locked"))
	ok = _report("garde non figée pendant la lecture", not reading_locked) and ok

	# Geste franc vers la gauche, puis on laisse la fenêtre de lecture expirer.
	player.set("_guard_gesture", Vector2(-140.0, 0.0))
	var waited := 0.0
	while waited < (MeleeAttack.GESTURE_MS / 1000.0) + 0.15:
		player.call("_update_guard_direction", DT)
		waited += DT
	var locked: bool = bool(player.get("_guard_locked"))
	var chosen: int = int(player.get("_guard_direction"))
	ok = _report("garde figée après la fenêtre de lecture", locked) and ok
	ok = _report("direction lue depuis le geste",
		chosen == MeleeAttack.Direction.TAILLE_GAUCHE,
		MeleeAttack.direction_name(chosen)) and ok

	# LE VERROU : un geste franc dans l'autre sens ne doit plus rien changer.
	player.set("_guard_gesture", Vector2(400.0, 0.0))
	for i in 40:
		player.call("_update_guard_direction", DT)
	ok = _report("garde INCHANGÉE par un geste ultérieur",
		int(player.get("_guard_direction")) == chosen,
		MeleeAttack.direction_name(int(player.get("_guard_direction")))) and ok

	# LA POSE DOIT SUIVRE. Une garde invisible n'existe pas pour le joueur, ni
	# pour son adversaire — la leçon la plus chère de tout ce chantier.
	var camera: Node3D = main.get_node("FlyCamera")
	var basis := camera.global_basis
	var grip: Vector3 = player.call("_grip_position", basis)
	var radius: float = preload("res://scenes/entities/player_body.gd").HAND_ARC_RADIUS
	var guard_pose: Vector3 = player.call("_guard_hand_target", grip, basis, radius)
	var carry_dir: Vector3 = player.call("_carry_direction", basis)
	var rest := grip + carry_dir * radius
	var moved := guard_pose.distance_to(rest)
	ok = _report("la main quitte le port d'arme en garde", moved > 0.15,
		"%.2f m" % moved) and ok

	# Et deux gardes différentes doivent donner deux poses différentes, sinon
	# l'adversaire ne peut pas lire de quel côté on se protège.
	player.set("_guard_direction", MeleeAttack.Direction.OVERHEAD)
	var high_pose: Vector3 = player.call("_guard_hand_target", grip, basis, radius)
	player.set("_guard_direction", MeleeAttack.Direction.TAILLE_DROITE)
	var side_pose: Vector3 = player.call("_guard_hand_target", grip, basis, radius)
	var spread := high_pose.distance_to(side_pose)
	ok = _report("deux gardes = deux poses distinctes", spread > 0.15,
		"%.2f m d'écart" % spread) and ok

	player.call("_set_guard", false)
	return ok


func _report(label: String, condition: bool, detail: String = "") -> bool:
	print("[%s] %s%s : %s" % [TAG, label,
		"" if detail == "" else " (" + detail + ")", "OK" if condition else "ÉCHEC"])
	return condition


## LE BOUCLIER (2026-08-01). Il manquait entièrement : la compétence « bouclier »
## existait dans la classification du GDD sans rien pour la faire monter, et
## l'emplacement de main gauche restait vide en toutes circonstances.
##
## Ce que ce test verrouille, c'est l'ARBITRAGE : un bouclier doit apporter
## quelque chose de net (couvrir plus large, encaisser à la place de
## l'endurance) ET coûter quelque chose de net (la main gauche, donc les armes à
## deux mains). Un bouclier qui ne coûte rien rendrait le choix du GDD 5.6
## (deux mains / bouclier / deux armes) purement décoratif.
func _check_shield() -> bool:
	var ok := true
	var equipment: Equipment = player.equipment
	equipment.slots.clear()

	# 1. Il va TOUJOURS en main gauche, jamais en main forte.
	var ecu := ItemFactory.craft("ecu", {"bois": "chene", "minerai": "fer"}, 1.0)
	equipment.equip(ecu)
	ok = _report("le bouclier s'équipe en main gauche",
		not equipment.equipped("arme_2").is_empty() and equipment.equipped("arme_1").is_empty()) and ok
	ok = _report("le joueur reconnaît son bouclier",
		int(player.call("equipped_shield").get("uid", -1)) == int(ecu["uid"])) and ok

	# 2. Une arme à UNE main : le bouclier opère.
	_give_weapon("epee")
	var profile: Dictionary = player.call("shield_profile")
	ok = _report("bouclier actif avec une arme à une main", bool(profile["present"])) and ok
	ok = _report("absorption non nulle", float(profile["absorption"]) > 0.1,
		"%.0f %%" % (float(profile["absorption"]) * 100.0)) and ok

	# 3. COUVERTURE ÉLARGIE : une garde haute arrête aussi les tailles.
	player.call("_set_guard", true)
	player.set("_guard_direction", MeleeAttack.Direction.OVERHEAD)
	player.set("_guard_locked", true)
	var covers_side: bool = player.call("guard_covers", MeleeAttack.Direction.TAILLE_DROITE)
	ok = _report("écu : garde haute couvre aussi une taille", covers_side) and ok

	# 4. Mais PAS tout : sans quoi la garde directionnelle n'aurait plus d'objet.
	player.set("_guard_direction", MeleeAttack.Direction.TAILLE_GAUCHE)
	var covers_opposite: bool = player.call("guard_covers", MeleeAttack.Direction.TAILLE_GAUCHE)
	ok = _report("écu : une taille ne couvre PAS la taille opposée",
		not covers_opposite) and ok
	player.call("_set_guard", false)

	# 5. L'ABSORPTION économise vraiment de l'endurance.
	player.set("stamina", player.get("stamina_max"))
	player.call("_set_guard", true)
	player.set("_guard_locked", true)
	var before: float = player.get("stamina")
	player.call("absorb_on_guard", 40.0, false)
	var with_shield: float = before - float(player.get("stamina"))
	equipment.slots.clear()
	player.set("stamina", player.get("stamina_max"))
	player.call("_set_guard", true)
	player.set("_guard_locked", true)
	before = player.get("stamina")
	player.call("absorb_on_guard", 40.0, false)
	var bare: float = before - float(player.get("stamina"))
	ok = _report("le bouclier réduit le drain d'endurance", with_shield < bare,
		"%.1f avec / %.1f sans" % [with_shield, bare]) and ok
	player.call("_set_guard", false)

	# 6. LE COÛT : une arme à deux mains rend le bouclier inopérant.
	equipment.equip(ItemFactory.craft("ecu", {"bois": "chene", "minerai": "fer"}, 1.0))
	_give_weapon("espadon")
	var two_handed: Dictionary = player.call("shield_profile")
	ok = _report("bouclier INOPÉRANT avec une arme à deux mains",
		not bool(two_handed["present"])) and ok

	# 7. Il PROGRESSE par l'usage, comme tout le reste (A.1).
	#
	# On VÉRIFIE l'arme réellement en main avant de mesurer. Ce test échouait une
	# fois sur cinq : la liaison de hotbar posée par `_give_weapon` se faisait
	# parfois reprendre, l'espadon du point 6 restait en main, et le bouclier
	# était donc légitimement inopérant. Le verdict accusait alors la
	# progression de compétence pour un problème d'installation du test.
	_give_weapon("epee")
	var in_hand: Dictionary = player.call("held_entry")
	var in_hand_id := String((in_hand.get("object", {}) as Dictionary).get("item_id", "(rien)"))
	ok = _report("l'épée est bien en main avant de mesurer l'XP",
		in_hand_id == "epee", in_hand_id) and ok
	var level_before: float = player.skills.skills["bouclier"]["xp"]
	player.set("stamina", player.get("stamina_max"))
	player.call("_set_guard", true)
	player.set("_guard_locked", true)
	player.call("absorb_on_guard", 30.0, false)
	ok = _report("encaisser fait monter la compétence bouclier",
		float(player.skills.skills["bouclier"]["xp"]) > level_before) and ok

	player.call("_set_guard", false)
	equipment.slots.clear()
	return ok


## Met une arme en main via un emplacement de hotbar LIBRE. Le kit de départ
## occupe les premiers : y écrire ferait tenir la pioche en croyant tenir
## l'épée, piège déjà rencontré sur les sondes de capture.
func _give_weapon(item_id: String) -> void:
	var weapon := ItemFactory.craft(item_id, {"bois": "chene", "minerai": "fer"}, 1.0)
	player.inventory.add_object(weapon)
	player.active_hotbar = 0
	player.selected_slot = 8
	# `bind_hotbar` et non une écriture directe dans le dictionnaire : l'API
	# publique purge les liaisons en double, ce que l'écriture brute ne fait pas
	# — et une liaison résiduelle sur le même objet ailleurs dans la barre
	# suffisait à rendre le résultat dépendant de l'ordre des tests.
	player.call("bind_hotbar", player.selected_slot,
		{"kind": "object", "object": weapon})

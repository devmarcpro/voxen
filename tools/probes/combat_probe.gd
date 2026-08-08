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
	# GARDE DES PNJ COUPÉE PAR DÉFAUT (2026-08-02). Les créatures parent
	# désormais, avec un jet : laisser ce hasard dans les tests de géométrie
	# rendrait « la lame atteint le torse » aléatoire. La parade a son propre
	# test, qui la rallume.
	CreatureManager.npc_guard_enabled = false
	# LE JOUEUR EST REMIS SUR LA TERRE FERME, ET EN VOL (2026-08-02).
	#
	# La sonde repart d'un monde SAUVEGARDÉ, et la position du joueur y est
	# celle qu'il avait à l'enregistrement — au fond du monde si une exécution
	# précédente l'y avait laissé tomber. Il chute ensuite pendant toutes les
	# frames que les tests laissent passer, et depuis que la géométrie des
	# créatures vit à la frame, ils en laissent passer beaucoup.
	#
	# `WORLD_Y_MIN` vaut −512 : arrivé là, `set_block` REFUSE toute écriture.
	# Des tests sans aucun rapport avec le combat — le décor du franchissement
	# de marche — échouaient donc sur leur propre montage. Ce n'était pas une
	# fragilité du test, c'était un joueur hors du monde.
	#
	# On le repose donc au sol, et on le met en VOL : il reste alors exactement
	# où chaque test le place, ce qui est la condition d'un montage reproductible.
	# LE VOL DE MESURE EST COUPÉ. `FlyCamera.bench` fait avancer la caméra en
	# ligne droite en permanence, altitude asservie au relief : c'était le mode
	# des benchs de performance, et il restait actif en sonde. Le joueur DÉRIVAIT
	# donc sur la carte pendant tout le test, et finissait au-dessus de colonnes
	# où `height_at` renvoie une valeur sous `WORLD_Y_MIN` (−512) — là où
	# `set_block` refuse d'écrire. Des tests sans rapport avec le combat
	# échouaient sur leur propre décor, et c'était bien ça la cause.
	camera.set("bench", false)
	camera.set("flying", true)
	await _replace_player_on_ground()
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
	ok = await _check_auto_step() and ok
	ok = _check_directional_guard() and ok
	ok = _check_sweet_spot() and ok
	ok = _check_weapon_geometry() and ok
	ok = _check_catalogue() and ok
	ok = await _check_dual_wielding() and ok
	ok = await _check_bare_hands() and ok
	ok = await _check_magic_and_combat_slot() and ok
	ok = await _check_npc_defence() and ok
	ok = _check_head_only_symmetry() and ok
	ok = await _check_cover_and_stagger() and ok
	ok = _check_crushthrough() and ok
	ok = _check_shield_wear() and ok
	ok = _check_left_arm() and ok
	ok = await _check_npc_feint_and_chamber() and ok
	ok = await _check_ranged() and ok
	# EN DERNIER, et c'est délibéré : ce test DESCEND le joueur au niveau de son
	# adversaire (seule situation où un duel a un sens), et la caméra ne revient
	# pas exactement à sa place — elle retombe pendant les frames d'attente. Le
	# placer en fin de course évite de casser les voisins pour une raison sans
	# rapport avec ce qu'ils mesurent.
	ok = await _check_creature_frame_sweep() and ok
	ok = _check_weapon_repertoire() and ok
	ok = _check_guard_blade() and ok
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
	var reaches := {}
	for wid: String in ["dague", "epee", "hache_arme", "lance", "espadon"]:
		var row_fn: Dictionary = GameData.functionalities[wid]
		var stats := WeaponStats.derive(row_fn, {})
		reaches[wid] = float(stats["reach"])
		# Le manche est LU dans la fiche, jamais recopié ici : une étiquette en
		# dur devient fausse au premier remaniement du catalogue de pièces.
		print("[%s]   %-12s manche=%-15s allonge=%.2f  écart des mains=%+.2f" % [
			TAG, wid, String((row_fn.get("parts", {}) as Dictionary).get("manche", "?")),
			stats["reach"], stats["hand_separation"]])
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
	# TICK EXCLUSIF (2026-08-02). `CreatureManager` tique TOUTES les créatures de
	# sa liste, et depuis que la sonde laisse passer des frames, ce tick-là
	# tourne aussi. Or le coup constaté est un ÉVÉNEMENT À USAGE UNIQUE : le
	# premier `tick_step` qui passe le consomme. Le manager volait donc
	# l'événement que la sonde attendait. On sort la créature de sa liste — elle
	# reste dans l'arbre, donc son `_process` continue de balayer — et la sonde
	# devient seule à la tiquer.
	CreatureManager.creatures.erase(creature)
	# LES DEUX AU MÊME NIVEAU. Le joueur survole le terrain en mode sonde ; la
	# créature se pose deux mètres plus bas. Tant que la portée d'engagement
	# était lue sur le champ `portee` (1,5 pour toutes les armes), l'écart
	# passait de justesse ; depuis qu'elle vaut l'allonge RÉELLE de la lame
	# (1,25 pour une épée courte), la créature ne peut plus atteindre le joueur
	# et n'attaque jamais. Ce n'est pas une régression : c'est la géométrie qui
	# est devenue juste, et le montage qui doit s'y conformer.
	for i in 4:
		creature.tick_step(player.get_position_for_ai(), player)
		await wait_frame()
	var duel_ground: float = creature.logical_position.y + creature.FEET_OFFSET
	var duel_spot: Vector3 = creature.logical_position
	duel_spot.y = duel_ground + FlyCamera.EYE_HEIGHT
	var step_back: Vector3 = camera.global_position - creature.logical_position
	step_back.y = 0.0
	if step_back.length_squared() < 0.01:
		step_back = Vector3.BACK
	camera.global_position = duel_spot + step_back.normalized() * 1.0
	await wait_frame()
	# On repart d'une créature AU REPOS : `_spawn_in_front` peut laisser passer
	# des frames, pendant lesquelles le tick du manager lui fait déjà déclarer
	# et porter un coup. Le témoin de télégraphie ne verrait alors rien.
	creature.set("_attack_declared", false)
	creature.set("_windup_left_ms", 0.0)
	creature.set("_hold_left_ms", 0.0)
	creature.set("_attack_cooldown_ticks", 0)
	creature.set("_pending_strike", {})
	creature.set("_strike_finished", false)
	creature.call("_start_pose", "", 0.05)
	var declared := [false]
	var handler := func(attacker: Variant, _direction: String) -> void:
		if attacker == creature:
			declared[0] = true
	EventBus.attack_telegraphed.connect(handler)

	# Elle DÉCLARE avant de frapper. Pas forcément au premier tick : selon le
	# relief, elle doit d'abord se rapprocher — ce qui compte est que la
	# déclaration précède le coup, jamais qu'elle tombe à une frame précise.
	# BUDGET LARGE : le jeu de jambes peut écarter la créature un instant, et
	# elle ne déclare qu'à portée. Ce test vérifie l'ORDRE — déclarer avant de
	# frapper —, pas la promptitude.
	var first: Dictionary = {}
	for i in 150:
		first = creature.tick_step(player.get_position_for_ai(), player)
		if declared[0] or not first.is_empty():
			break
		await wait_frame()
	var telegraph_ok: bool = declared[0] and first.is_empty()
	print("[%s] créature à portée : déclare=%s frappe immédiate=%s (attendu oui/non) : %s" % [
		TAG, declared[0], not first.is_empty(), "OK" if telegraph_ok else "ÉCHEC"])
	EventBus.attack_telegraphed.disconnect(handler)

	# Le coup finit par partir si on ne bouge pas.
	#
	# ON LAISSE PASSER DES FRAMES ENTRE LES TICKS (2026-08-02). La géométrie du
	# coup d'une créature vit désormais à la FRAME, comme celle du joueur : le
	# tick ne fait plus qu'appliquer ce que le balayage a constaté. Enchaîner des
	# `tick_step` sans frame intercalée, c'est demander le résultat d'un
	# balayage qui n'a jamais eu lieu — le montage doit refléter l'entrelacement
	# réel du jeu.
	# BUDGET LARGE, et c'est la feinte qui l'exige. Depuis qu'un PNJ peut annuler
	# sa menace, le cycle n'est plus déterministe : une série de feintes retarde
	# légitimement le coup. Ce test mesure que le cycle ABOUTIT, pas qu'il
	# aboutisse en un nombre de ticks fixé — l'exiger reviendrait à interdire la
	# feinte au nom de la reproductibilité.
	var landed := false
	for i in 300:
		if not creature.tick_step(player.get_position_for_ai(), player).is_empty():
			landed = true
			break
		await wait_frame()
	print("[%s] wind-up écoulé sans bouger : le coup part=%s (attendu oui) : %s" % [
		TAG, landed, "OK" if landed else "ÉCHEC"])

	# ESQUIVE GÉOMÉTRIQUE : reculer hors d'allonge pendant le wind-up doit
	# annuler le coup et créditer l'Esquive — plus aucun jet de dé là-dedans.
	var hp_before: float = player.health
	creature.tick_step(player.get_position_for_ai(), player)      # déclaration
	creature.logical_position = player.get_position_for_ai() + Vector3(0.0, -0.9, 0.0) + Vector3(12.0, 0.0, 0.0)
	# ESQUIVE : elle a changé de sens, et en mieux. Le coup était résolu au tick
	# par un test de portée ; il est désormais CONSTATÉ par le balayage, image
	# par image. Esquiver, c'est donc ne plus être dans l'arc au moment où la
	# lame passe — et non plus avoir reculé avant que le tick ne se prononce.
	#
	# La boucle reste COURTE volontairement : hors d'allonge, l'IA remarche vers
	# le joueur, et sur cent-vingt ticks elle a le temps de revenir le frapper.
	# Ce ne serait plus une esquive qu'on mesure, mais une poursuite.
	var dodged := true
	for i in 25:
		var event: Dictionary = creature.tick_step(player.get_position_for_ai(), player)
		if not event.is_empty():
			CreatureManager.call("_resolve_creature_attack", creature, player,
				event.get("hit", {}))
			break
		# On déplace la position LOGIQUE **et** la position visuelle : le
		# balayage suit le corps AFFICHÉ (c'est l'invariant « ce qu'on voit est
		# ce qui frappe »), et l'affichage rattrape le logique par
		# interpolation — en une demi-seconde. Ne bouger que le logique
		# laisserait la lame frapper là où la créature n'est plus.
		var far_away: Vector3 = player.get_position_for_ai() + Vector3(12.0, -0.9, 0.0)
		creature.logical_position = far_away
		creature.position = far_away
		await wait_frame()
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
	# BÂTI DANS LES BORNES DU MONDE. Le décor est posé sous le joueur, dont la
	# position dérive au fil de la sonde : il finissait sous `WORLD_Y_MIN`
	# (−512), altitude à laquelle `set_block` REFUSE toute écriture. Le test
	# échouait alors sur son propre montage, sans qu'aucun code de
	# franchissement ne soit en cause. Un test qui fabrique son décor doit le
	# fabriquer là où le monde existe.
	var floor_y := clampi(floori(camera.position.y) - 10,
		WorldManager.WORLD_Y_MIN + 2, WorldManager.WORLD_Y_MAX - 8)
	var base := Vector3i(int(camera.position.x) + 6, floor_y, int(camera.position.z))
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
	# ÉQUIPÉE, plus liée à la hotbar (2026-08-02). L'emplacement 1 est celui du
	# combat : il montre l'arme portée en main forte et refuse toute liaison.
	# Y coller une épée laissait la sonde se battre à MAINS NUES sans le dire.
	if not (player.equipment.equipped("arme_1") as Dictionary).is_empty():
		player.call("unequip_slot", "arme_1")
	var sword := ItemFactory.craft("epee", {"bois": "chene", "minerai": "fer"}, 1.0)
	player.inventory.add_object(sword)
	player.call("equip_instance", sword)
	player.active_hotbar = 0
	player.selected_slot = player.COMBAT_SLOT


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


## Repose le joueur sur le premier sol solide sous lui. S'il n'y en a aucun à
## portée — il est hors du monde, ou au-dessus d'une colonne non chargée —, on
## le remonte à une altitude franche et on laisse le terrain se générer.
func _replace_player_on_ground() -> void:
	for attempt in 3:
		for i in 20:
			await main.get_tree().process_frame
		var ground := _solid_ground_under(camera.position + Vector3.UP * 2.0)
		if ground > -9000:
			camera.position = Vector3(camera.position.x,
				float(ground + 1) + FlyCamera.EYE_HEIGHT, camera.position.z)
			await main.get_tree().process_frame
			return
		# Rien sous les pieds : on remonte au-dessus du relief connu et on
		# laisse le monde se charger avant de réessayer.
		if WorldManager.generator != null:
			var h := float(WorldManager.generator.height_at(
				int(camera.position.x), int(camera.position.z)))
			camera.position = Vector3(camera.position.x, h + 6.0, camera.position.z)


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


## LA HITBOX SUIT LE MODÈLE (2026-08-02, demande : « ça touche quand la tête
## touche »). Trois choses se vérifient ici, et aucune ne se voit à l'œil :
##
##   1. Ce qu'on promène est la TÊTE ENTIÈRE et non la pointe. Un fer est un
##      segment ; ne suivre que son extrémité laissait une hallebarde traverser
##      un torse sans rien lui faire.
##   2. Ce segment est placé LÀ OÙ L'ARME EST DESSINÉE : à partir de la main,
##      donc bras compris. La hitbox accusait 72 cm de retard sur le modèle.
##   3. Le sweet spot tombe sur la JONCTION MANCHE/TÊTE réelle. Une fraction
##      fixe de l'allonge ne pouvait coïncider avec la géométrie que par hasard.
func _check_weapon_geometry() -> bool:
	var ok := true
	var arm: float = preload("res://scenes/entities/player_body.gd").HAND_ARC_RADIUS
	var draw: float = preload("res://scenes/entities/held_item.gd").PART_SCALE
	print("[%s] --- géométrie d'arme : la hitbox suit le modèle ---" % TAG)
	for weapon_id: String in ["dague", "epee", "espadon", "hallebarde"]:
		var stats := WeaponStats.derive(GameData.functionalities[weapon_id], {})
		var samples: PackedFloat32Array = player.call("_head_distances", stats)
		var head_start := float(stats["head_start"])
		var reach := float(stats["reach"])
		# Le premier point est le talon du fer, le dernier la pointe — tous deux
		# mesurés depuis la prise, bras et échelle d'affichage compris.
		var start_ok := absf(samples[0] - (arm + head_start * draw)) < 0.01
		var tip_ok := absf(samples[samples.size() - 1] - (arm + reach * draw)) < 0.01
		var many_ok := samples.size() >= 2
		print("[%s]   %-11s tête %.2f→%.2f m de la prise · %d point(s) suivis : %s" % [
			TAG, weapon_id, samples[0], samples[samples.size() - 1], samples.size(),
			"OK" if (start_ok and tip_ok and many_ok) else "ÉCHEC"])
		ok = ok and start_ok and tip_ok and many_ok

	# LE CAS QUI MOTIVE TOUT : sur une hallebarde, le fer commence bien après le
	# milieu de l'allonge. L'ancienne règle (dégâts pleins à 62 % de l'allonge)
	# faisait tuer AVEC LE MANCHE ; la nouvelle exige d'avoir touché du fer.
	var halberd := WeaponStats.derive(GameData.functionalities["hallebarde"], {})
	var h_reach := float(halberd["reach"])
	var h_start := float(halberd["head_start"])
	var on_haft := WeaponStats.sweet_spot_factor(h_reach * 0.62, h_reach, h_start)
	var on_head := WeaponStats.sweet_spot_factor(h_reach * 0.99, h_reach, h_start)
	ok = _report("hallebarde : le manche ne blesse plus (62 % de l'allonge)",
		is_zero_approx(on_haft), "facteur %.2f, fer à %.0f %% de l'allonge" % [
			on_haft, h_start / h_reach * 100.0]) and ok
	ok = _report("hallebarde : le fer blesse à plein", on_head > 0.99,
		"facteur %.2f" % on_head) and ok

	# LES MAINS SUR LE MANCHE. Le signe de l'écart porte le sens : une arme
	# d'hast projette la main avant DEVANT, une arme blanche à deux mains pose
	# la seconde main sur le POMMEAU, donc derrière. Tout se tenait comme une
	# pique avant le 2026-08-02.
	var polearm := float(WeaponStats.derive(GameData.functionalities["lance"], {})["hand_separation"])
	var greatsword := float(WeaponStats.derive(GameData.functionalities["espadon"], {})["hand_separation"])
	ok = _report("prise : la lance avance la main gauche, l'espadon la recule",
		polearm > 0.0 and greatsword < 0.0,
		"lance %+.2f m · espadon %+.2f m" % [polearm, greatsword]) and ok
	# POIGNÉE vs FÛT (2026-08-02). Le catalogue confondait les deux : `moyen`
	# faisait 69 cm, une hampe de masse mais trois fois la poignée d'une épée, et
	# l'épée se tenait donc au tiers d'un manche avec 48 cm entre le poing et la
	# lame. Ce qui doit être vrai maintenant : une arme blanche a une POIGNÉE
	# courte qu'on tient haut, une arme à percussion ou d'hast un FÛT long qu'on
	# tient bas.
	var blade := WeaponStats.derive(GameData.functionalities["epee"], {})
	var mace := WeaponStats.derive(GameData.functionalities["masse"], {})
	var pike := WeaponStats.derive(GameData.functionalities["lance"], {})
	var lengths_ok: bool = float(blade["handle_length"]) < float(mace["handle_length"]) \
		and float(mace["handle_length"]) < float(pike["handle_length"])
	ok = _report("manches : poignée d'épée < fût de masse < hampe de lance",
		lengths_ok, "%.2f < %.2f < %.2f m" % [blade["handle_length"],
			mace["handle_length"], pike["handle_length"]]) and ok
	ok = _report("prise : la main est HAUTE sur une poignée, BASSE sur un fût",
		float(blade["grip_main"]) > float(mace["grip_main"])
			and float(mace["grip_main"]) > float(pike["grip_main"]),
		"épée %.2f · masse %.2f · lance %.2f" % [blade["grip_main"],
			mace["grip_main"], pike["grip_main"]]) and ok
	# Et ce qui motivait tout : entre le poing et la lame, il ne doit plus rester
	# un demi-mètre de manche. Une garde d'épée fait quelques centimètres.
	var stub := float(blade["head_start"])
	ok = _report("épée : le manche ne dépasse presque plus du poing",
		stub < 0.15, "%.02f m avant la lame" % stub) and ok

	# LES PIÈCES SONT DÉCLARÉES DEUX FOIS — dans l'objet (qui DESSINE l'arme) et
	# dans la fonctionnalité (qui la CHIFFRE). Les deux doivent coïncider, sinon
	# le modèle affiché et la hitbox repartent chacun de leur côté : c'est très
	# exactement le défaut qu'on vient de corriger, et rien n'empêchait de le
	# réintroduire au prochain ajout d'arme.
	var mismatched: Array[String] = []
	for item_id: String in GameData.items:
		var item: Dictionary = GameData.items[item_id]
		if not item.has("parts"):
			continue
		var fn: Dictionary = GameData.functionalities.get(String(item.get("functionality", "")), {})
		var fn_parts: Dictionary = fn.get("parts", {})
		if fn_parts.is_empty():
			continue
		if String(fn_parts.get("manche", "")) != String((item["parts"] as Dictionary).get("manche", "")) \
				or String(fn_parts.get("tete", "")) != String((item["parts"] as Dictionary).get("tete", "")):
			mismatched.append(item_id)
	ok = _report("objet et fonctionnalité déclarent les MÊMES pièces",
		mismatched.is_empty(),
		"toutes accordées" if mismatched.is_empty() else "désaccord : " + ", ".join(mismatched)) and ok
	return ok


## LONGUEURS RÉELLES (2026-08-02). Le catalogue a été re-coupé pièce par pièce ;
## cette table est ce qui empêche qu'il redérive. Chaque fourchette est celle de
## l'arme historique correspondante — une hallebarde fait 1,80 à 2,20 m, pas
## 2,81 comme avant le re-découpage, et une masse à une main 0,60 à 0,80 m et
## non 0,97.
##
## Les BOUCLIERS en sont absents : `portee_tete` ne mesure que ce qui dépasse
## au-dessus du point de greffe, or une plaque déborde aussi en dessous. Leur
## hauteur se vérifie ailleurs (verify_weapon_parts.gd).
const REAL_LENGTHS := {
	"dague": [0.25, 0.45], "epee_courte": [0.45, 0.75], "epee": [0.85, 1.05],
	"rapiere": [1.00, 1.30], "espadon": [1.40, 1.80],
	"hachette": [0.40, 0.70], "hache_arme": [1.10, 1.60],
	"hache_double": [1.10, 1.60], "marteau_guerre": [1.10, 1.60],
	"masse": [0.55, 0.85], "masse_ailettes": [0.55, 0.85],
	"pioche_combat": [0.55, 0.90], "gourdin": [0.45, 0.80],
	"baton_ferre": [1.60, 2.20], "baton_magique": [1.50, 2.20],
	"lance": [2.00, 2.60], "hallebarde": [1.80, 2.30],
	"trident": [1.70, 2.20], "faux_de_guerre": [1.60, 2.20],
	"arc": [1.20, 1.90], "arbalete": [0.60, 1.00],
}


## Le catalogue tient-il debout ? Trois invariants qui ne se voient pas en
## lisant les fiches, et qui redevenaient faux à chaque ajustement :
##   1. chaque arme mesure ce que mesure son équivalent réel ;
##   2. sa MASSE est celle de sa recette dans les matériaux de référence — donc
##      une arme forgée en chêne et fer tourne exactement à sa `vitesse_base` ;
##   3. le coût de craft suit la taille des pièces.
func _check_catalogue() -> bool:
	var ok := true
	print("[%s] --- catalogue : longueurs, masses, recettes ---" % TAG)
	var out_of_band: Array[String] = []
	for weapon_id: String in REAL_LENGTHS:
		var item: Dictionary = GameData.items.get(weapon_id, {})
		if item.is_empty() or not item.has("parts"):
			out_of_band.append(weapon_id + " (absent)")
			continue
		var parts: Dictionary = item["parts"]
		var handle: Dictionary = GameData.weapon_parts["manches"].get(String(parts["manche"]), {})
		var head: Dictionary = GameData.weapon_parts["tetes"].get(String(parts["tete"]), {})
		var total := float(handle.get("longueur", 0.0)) + float(head.get("portee_tete", 0.0))
		var band: Array = REAL_LENGTHS[weapon_id]
		if total < float(band[0]) - 0.001 or total > float(band[1]) + 0.001:
			out_of_band.append("%s %.2f m (attendu %.2f–%.2f)" % [
				weapon_id, total, band[0], band[1]])
	ok = _report("longueurs conformes aux armes réelles (%d armes)" % REAL_LENGTHS.size(),
		out_of_band.is_empty(),
		"toutes dans leur fourchette" if out_of_band.is_empty()
		else "hors fourchette : " + ", ".join(out_of_band)) and ok

	# La MASSE de référence doit être exactement celle de la recette bâtie en
	# chêne et fer. Sinon `vitesse_base` ne veut plus rien dire : une arme serait
	# ralentie ou accélérée dans ses propres matériaux de référence.
	var density := {"bois": 6.0, "minerai": 12.0}
	var drifted: Array[String] = []
	for weapon_id: String in GameData.items:
		var item: Dictionary = GameData.items[weapon_id]
		if not item.has("parts"):
			continue
		var fn: Dictionary = GameData.functionalities.get(String(item.get("functionality", "")), {})
		if not fn.has("poids_reference"):
			continue
		var computed := 0.0
		for input: Variant in (item["recipe"] as Dictionary).get("inputs", []):
			var row: Dictionary = input
			computed += float(density.get(String(row["category"]), 0.0)) * float(row["amount"])
		if absf(computed - float(fn["poids_reference"])) > 0.51:
			drifted.append("%s (%d vs %.0f)" % [weapon_id, int(fn["poids_reference"]), computed])
	ok = _report("masse de référence = recette en chêne et fer", drifted.is_empty(),
		"accordées" if drifted.is_empty() else "dérive : " + ", ".join(drifted)) and ok

	# Et le coût doit suivre la TAILLE. Une dague ne peut pas coûter autant de
	# métal qu'un espadon — c'était pourtant le cas (2 contre 5) avant que les
	# recettes ne soient dérivées du volume des pièces.
	var dagger := _metal_of("dague")
	var sword := _metal_of("epee")
	var greatsword := _metal_of("espadon")
	ok = _report("métal : dague < épée < espadon",
		dagger < sword and sword < greatsword,
		"%d < %d < %d lingot(s)" % [dagger, sword, greatsword]) and ok
	return ok


func _metal_of(weapon_id: String) -> int:
	for input: Variant in ((GameData.items[weapon_id]["recipe"] as Dictionary).get("inputs", [])):
		var row: Dictionary = input
		if String(row["category"]) == "minerai":
			return int(row["amount"])
	return 0


## ON PARE EN TRAVERS (2026-08-02). L'arme était orientée par la direction
## main → cible, la même qu'en attaque : en garde haute elle pointait donc vers
## le haut, DANS l'axe du coup qu'elle prétendait arrêter. Une lame parallèle à
## l'attaque ne l'intercepte pas, et le joueur ne comprend pas ce qu'il bloque.
func _check_guard_blade() -> bool:
	var ok := true
	var camera: Node3D = main.get_node("FlyCamera")
	var basis := camera.global_basis
	print("[%s] --- orientation de l'arme en parade ---" % TAG)
	var axes := {}
	for guard: int in [MeleeAttack.Direction.OVERHEAD, MeleeAttack.Direction.ESTOC,
			MeleeAttack.Direction.TAILLE_GAUCHE, MeleeAttack.Direction.TAILLE_DROITE]:
		var axis: Vector3 = MeleeAttack.guard_blade_axis(guard, basis)
		axes[guard] = axis
		# Trajectoire du coup couvert, prise au milieu de son arc : c'est ce que
		# la lame doit croiser.
		var attack := MeleeAttack.guard_for(guard)
		var before := MeleeAttack.tip_position(attack, 0.35, Vector3.ZERO, basis, 1.0)
		var after := MeleeAttack.tip_position(attack, 0.65, Vector3.ZERO, basis, 1.0)
		var travel := (after - before)
		var crossing := 1.0
		if travel.length_squared() > 0.000001:
			crossing = absf(axis.dot(travel.normalized()))
		# 0 = parfaitement perpendiculaire. On exige nettement mieux que 45°,
		# sinon la lame accompagne le coup au lieu de le barrer.
		var crossed := crossing < 0.5
		print("[%s]   garde %-14s : alignement avec le coup %.2f (doit être < 0,50) : %s" % [
			TAG, MeleeAttack.direction_name(guard), crossing, "OK" if crossed else "ÉCHEC"])
		ok = ok and crossed
	# Et deux gardes différentes doivent présenter la lame différemment, sinon
	# l'adversaire ne peut pas lire de quel côté on se protège.
	var distinct: bool = (axes[MeleeAttack.Direction.OVERHEAD] as Vector3).dot(
		axes[MeleeAttack.Direction.TAILLE_DROITE]) < 0.9
	ok = _report("deux gardes présentent la lame différemment", distinct) and ok
	return ok


## DUAL WIELDING (2026-08-02, GDD 6.2 + demande de l'auteur). Trois choses à
## prouver, et aucune ne se voit en lisant le code :
##   1. la POSTURE se déduit de l'équipement, elle ne se choisit pas ;
##   2. un clic produit DEUX frappes — main forte puis retour de main gauche —
##      avec les stats de CHAQUE arme, sinon la seconde arme ne serait qu'un
##      décor ;
##   3. l'emplacement 1 de la hotbar est celui du COMBAT : il suit l'arme
##      équipée et refuse toute liaison.
## COMBAT À MAINS NUES, STYLE BOXE (2026-08-07).
##
## CE QUI EST DÉFENDU, et aucun de ces trois points ne se voit en lisant le code.
##
## 1. QU'ON PUISSE FRAPPER SANS ARME, DÉLIBÉRÉMENT. C'était impossible : le
##    combat ne s'engageait qu'avec une arme en main ou une créature déjà sous
##    le réticule. On ne pouvait ni s'entraîner, ni lever les poings d'avance.
##
## 2. QUE LE COUP PORTE VRAIMENT. Une posture de boxe qui ne fait pas de dégâts
##    est un mime. Le chemin des stats passe par un repli (`mains_nues`) qui
##    n'était exercé par aucun test.
##
## 3. QUE LA MAIN SUIVE LA DIRECTION. C'est la seule chose qui distingue une
##    boxe d'un moulinet, et elle se décide en un endroit dont dépendent À LA
##    FOIS le geste vu et la hitbox. Si les deux divergeaient, on verrait un
##    crochet du gauche dont les dégâts partent de la droite — et absolument
##    rien ne le signalerait.
func _check_bare_hands() -> bool:
	var ok := true
	print("[%s] --- mains nues ---" % TAG)
	# DÉSARMÉ POUR DE BON : les deux mains, sinon la seconde arme resterait et
	# on testerait un dual wielding manchot en croyant tester des poings.
	for slot: String in ["arme_1", "arme_2"]:
		if not (player.equipment.equipped(slot) as Dictionary).is_empty():
			player.call("unequip_slot", slot)
	player.call("bind_hotbar", player.COMBAT_SLOT, {"kind": "combat"})
	player.active_hotbar = 0
	player.selected_slot = player.COMBAT_SLOT

	var stats: Dictionary = player.call("_current_weapon_stats")
	ok = _report("sans arme, l'entrée de combat met en posture de poing",
		bool(player.call("_wants_combat")) and String(stats.get("skill", "")) == "mains_nues",
		String(stats.get("skill", ""))) and ok
	# LA PORTÉE D'UN POING N'EST PAS CELLE D'UNE ÉPÉE. Elle valait 1,5 m —
	# la même qu'une épée longue — ce qui laissait frapper d'un mètre et demi.
	# L'ASSERTION PORTE SUR LA BANDE VULNÉRANTE, pas sur le champ `portee` de la
	# fiche : ce champ n'est qu'un terme d'une formule qui y ajoute la longueur
	# du bras. Vérifier la fiche aurait été vert avec une allonge réelle de
	# 1,62 m — un « poing » qui frappe d'un mètre et demi.

	# LE COUP PORTE.
	# LA CIBLE EST PLACÉE DANS LA BANDE VULNÉRANTE, CALCULÉE. Un poing n'a ni la
	# portée ni la bande d'une épée, et deux montages successifs ont conclu « le
	# poing ne fait rien » alors qu'il frappait dans le vide. On demande donc la
	# bande au même code que le jeu, et on vise son milieu — une distance écrite
	# à la main serait une devinette, et elle redeviendrait fausse au premier
	# réglage d'allonge.
	var span := WeaponStats.head_span(stats,
		preload("res://scenes/entities/player_body.gd").HAND_ARC_RADIUS,
		preload("res://scenes/entities/held_item.gd").PART_SCALE)
	var punch_range := (span.x + span.y) * 0.5
	print("[%s]   bande vulnérante du poing : %.2f→%.2f m, cible à %.2f" % [
		TAG, span.x, span.y, punch_range])
	# ET C'EST BIEN UNE ALLONGE DE POING. L'assertion porte sur la BANDE, pas sur
	# le champ `portee` de la fiche : ce champ n'est qu'un terme d'une formule
	# qui y ajoute la longueur du bras. Vérifier la fiche laissait passer une
	# allonge réelle de 1,62 m — un « poing » qui frappe d'un mètre et demi,
	# c'est-à-dire aussi loin qu'une épée (1,68).
	ok = _report("l'allonge est celle d'un bras, pas d'une lame",
		span.y < 1.40, "%.2f m contre 1,68 pour une épée" % span.y) and ok
	var target := _spawn_in_front(punch_range)
	var before := float(target.health)
	var hits := await _swing_and_collect()
	await main.get_tree().process_frame
	# DEUX COUPS PAR GESTE, un par poing : c'est la mécanique du dual wielding,
	# appliquée aux mains nues parce qu'on a bien deux armes. Un seul coup
	# voudrait dire qu'un bras reste au repos.
	ok = _report("le poing touche et blesse, DEUX fois (un par main)",
		hits.size() == 2 and float(target.health) < before,
		"%d coup(s), PV %.0f → %.0f" % [hits.size(), before, float(target.health)]) and ok
	_despawn(target)

	# LA MAIN SUIT LA DIRECTION, ET LES DEUX POINGS SERVENT. On interroge la
	# règle PURE, pas l'état de l'attaque : interrogée après le geste, la machine
	# à états a déjà joué ses deux frappes et l'on mesurerait la seconde en
	# croyant lire la première — c'est exactement l'erreur qu'a faite la première
	# version de ce test, qui rendait un résultat incohérent d'une direction à
	# l'autre.
	var PlayerScript := preload("res://scenes/entities/player.gd")
	var hands: Array[String] = []
	for direction: int in [MeleeAttack.Direction.TAILLE_GAUCHE, MeleeAttack.Direction.TAILLE_DROITE,
			MeleeAttack.Direction.ESTOC, MeleeAttack.Direction.OVERHEAD]:
		var first: bool = PlayerScript.punch_uses_left(direction, false)
		var second: bool = PlayerScript.punch_uses_left(direction, true)
		hands.append("%s puis %s" % ["G" if first else "D", "G" if second else "D"])
		ok = _report("  %s : les deux poings, jamais deux fois le même" % 
			MeleeAttack.direction_name(direction), first != second) and ok
	ok = _report("le crochet du gauche PART du poing gauche",
		PlayerScript.punch_uses_left(MeleeAttack.Direction.TAILLE_GAUCHE, false)
		and not PlayerScript.punch_uses_left(MeleeAttack.Direction.TAILLE_DROITE, false),
		str(hands)) and ok

	# ET AVEC UNE ARME, RIEN NE CHANGE : une épée se tient d'une main, la
	# direction ne doit pas décider pour elle. Sans ce contre-test, la règle de
	# boxe pourrait fuir dans le combat armé sans qu'on s'en aperçoive.
	_equip_sword()
	var armed_dummy := _spawn_in_front(1.1)
	await _swing_in_direction(Vector2(-90.0, 0.0))
	ok = _report("armé, un coup à gauche reste dans la main de l'arme",
		not bool(player.call("_strike_uses_offhand"))) and ok
	_despawn(armed_dummy)
	return ok


## ARME MAGIQUE ET GESTE MMO (2026-08-07).
##
## TROIS CHOSES À DÉFENDRE, dont aucune ne se voit en lisant le code.
##
## 1. LE SORT INNÉ EST GRAVÉ À LA FORGE, et il DÉPEND DE LA MATIÈRE. S'il était
##    constant, forger un second bâton n'aurait aucun intérêt ; s'il était tiré
##    au sort, le même bâton changerait de sort d'une partie à l'autre.
##
## 2. LA CHARGE EST EXIGÉE. Un relâchement immédiat ne doit RIEN lancer et ne
##    RIEN coûter — sinon un clic malheureux vide le mana.
##
## 3. LE GESTE MMO NE VAUT QU'EN COMBAT. Sur l'entrée de combat, un chiffre
##    déclenche l'emplacement SANS quitter la garde ; partout ailleurs il change
##    de main, comme toujours. Le même appui rend deux services opposés, et
##    c'est exactement le genre de règle qui se casse en silence.
func _check_magic_and_combat_slot() -> bool:
	var ok := true
	print("[%s] --- arme magique et geste de combat ---" % TAG)

	var staff_a := ItemFactory.craft("baton_magique", {"bois": "chene", "minerai": "fer"}, 1.0)
	var staff_b := ItemFactory.craft("baton_magique", {"bois": "ebene", "minerai": "or"}, 1.0)
	var staff_a2 := ItemFactory.craft("baton_magique", {"bois": "chene", "minerai": "fer"}, 1.0)
	var sword := ItemFactory.craft("epee", {"bois": "chene", "minerai": "fer"}, 1.0)
	ok = _report("un bâton magique sort de la forge avec un sort",
		String(staff_a.get("sort_inne", "")) != "", String(staff_a.get("sort_inne", ""))) and ok
	ok = _report("une épée n'en a pas",
		String(sword.get("sort_inne", "")) == "") and ok
	ok = _report("le sort DÉPEND DE LA MATIÈRE",
		String(staff_a.get("sort_inne", "")) != String(staff_b.get("sort_inne", "")),
		"%s vs %s" % [staff_a.get("sort_inne", ""), staff_b.get("sort_inne", "")]) and ok
	ok = _report("et il est REPRODUCTIBLE : même matière, même sort",
		String(staff_a.get("sort_inne", "")) == String(staff_a2.get("sort_inne", ""))) and ok

	# On équipe le bâton et on se met en combat.
	for slot: String in ["arme_1", "arme_2"]:
		if not (player.equipment.equipped(slot) as Dictionary).is_empty():
			player.call("unequip_slot", slot)
	player.inventory.add_object(staff_a)
	player.call("equip_instance", staff_a)
	player.call("bind_hotbar", player.COMBAT_SLOT, {"kind": "combat"})
	player.active_hotbar = 0
	player.selected_slot = player.COMBAT_SLOT
	player.mana.current = player.mana.max_mana()

	print("[%s]   équipé=%s · combat=%s · mana %.0f/%.0f · sort %s" % [
		TAG, String((player.equipment.equipped("arme_1") as Dictionary).get("item_id", "(rien)")),
		bool(player.call("_wants_combat")), float(player.mana.current), player.mana.max_mana(),
		String(player.call("innate_spell_of", player.equipment.equipped("arme_1")))])
	# LA CHARGE EST EXIGÉE : relâcher tout de suite ne lance rien et ne coûte rien.
	var mana_before := float(player.mana.current)
	player.call("_begin_combat_input")
	var fired_early: bool = bool(player.call("_release_innate_spell"))
	ok = _report("relâcher sans charger ne lance rien, et ne coûte pas de mana",
		not fired_early and is_equal_approx(float(player.mana.current), mana_before)) and ok

	# CHARGÉ, IL PART ET IL COÛTE.
	# ON ATTEND SUR L'HORLOGE DU CODE, PAS SUR UN MINUTEUR. `wait_seconds(0.4)`
	# n'a fait avancer la charge que de 156 ms — un `SceneTreeTimer` et
	# `Time.get_ticks_msec()` ne mesurent pas la même chose en headless. Le test
	# concluait « le sort ne part pas » alors qu'il n'avait simplement pas
	# chargé. On attend donc que la charge SOIT là, ce qui est la seule
	# condition qui compte.
	player.call("_begin_combat_input")
	for i in 240:
		if float(player.call("channel_ratio")) > 0.30:
			break
		await wait_frame()
	print("[%s]   charge atteinte : %.2f" % [TAG, float(player.call("channel_ratio"))])
	# LA CHARGE SE VOIT. Une mécanique invisible n'existe pas pour celui qui la
	# subit — c'est la leçon de la télégraphie du combat directionnel et de la
	# tension de l'arc. La main doit avoir QUITTÉ le port, et les deux bras
	# doivent être actifs : on canalise à deux mains.
	var rest: Vector3 = player.call("hand_targets", 0.55, 0.28, 1.0 / 60.0).get("droite", Vector3.ZERO)
	for i in 20:
		rest = player.call("hand_targets", 0.55, 0.28, 1.0 / 60.0).get("droite", Vector3.ZERO)
	var eye: Vector3 = camera.global_position
	ok = _report("la charge se VOIT : la main a quitté le port",
		rest.distance_to(eye) > 0.0 and bool(player.call("left_hand_busy")),
		"main à %.2f m de l'œil, deux bras actifs=%s" % [rest.distance_to(eye),
			bool(player.call("left_hand_busy"))]) and ok
	var fired: bool = bool(player.call("_release_innate_spell"))
	ok = _report("chargé puis relâché, le sort part et consomme du mana",
		fired and float(player.mana.current) < mana_before,
		"lancé=%s, mana %.1f → %.1f, cooldown=%d" % [fired, mana_before,
			float(player.mana.current), int(player.get("_module_cooldown_ticks"))]) and ok

	# LE LANCER SE VOIT AUSSI. Un sort qui part sans que rien ne bouge à l'écran
	# laisse le joueur incapable de distinguer « c'est parti » de « rien ne s'est
	# passé » — sur une action qui COÛTE du mana, c'est la pire ambiguïté
	# possible. Et ça vaut pour les sorts SANS projectile (soin, protection),
	# qui ne produisaient rigoureusement rien.
	var flashes: Node = main.get_node_or_null("SpellFlash")
	var flash_before: int = int(flashes.call("count")) if flashes != null else -1
	ok = _report("le geste de lancer est engagé après le tir",
		float(player.get("_cast_gesture")) >= 0.0) and ok
	ok = _report("un éclat est né au point de lancer",
		flashes != null and flash_before > 0, "%d éclat(s)" % flash_before) and ok

	# LE GESTE MMO. Un consommable dans un autre emplacement, et l'appui du
	# chiffre correspondant : il doit être MANGÉ sans que la main change.
	var food_id := ""
	for mat_id: String in GameData.materials:
		if (GameData.materials[mat_id] as Dictionary).has("nutrition"):
			food_id = mat_id
			break
	if food_id != "":
		player.inventory.add_material(food_id, 5)
		player.call("bind_hotbar", 6, {"kind": "material", "id": food_id})
		player.hunger = player.hunger_max * 0.4
		var hunger_before := float(player.hunger)
		var held_before: int = int(player.selected_slot)
		var used: bool = bool(player.call("_use_from_combat", 6))
		ok = _report("en combat, le chiffre CONSOMME l'emplacement visé",
			used and float(player.hunger) > hunger_before,
			"%s : consommé=%s, faim %.0f → %.0f" % [food_id, used, hunger_before, float(player.hunger)]) and ok
		ok = _report("et la main NE CHANGE PAS : on reste en garde",
			int(player.selected_slot) == held_before) and ok

		# HORS COMBAT, LE MÊME APPUI CHANGE DE MAIN. Sans ce contre-test, la
		# règle pourrait fuir partout et l'on ne pourrait plus prendre une pioche.
		player.call("bind_hotbar", 7, {"kind": "material", "id": food_id})
		player.selected_slot = 7
		ok = _report("hors combat, le chiffre ne consomme pas : il sélectionne",
			not bool(player.call("_use_from_combat", 6))) and ok
		player.selected_slot = player.COMBAT_SLOT

	# UN OUTIL NE SE MANGE PAS, ET NE DOIT PAS AVALER L'APPUI. Signalé en jeu :
	# une pioche dans un emplacement rendait ce chiffre inopérant en combat, donc
	# impossible de reprendre son outil sans sortir de la garde. `_try_eat` rend
	# TRUE sur un objet non comestible — « traité », pas « consommé » — et le
	# geste s'y fiait.
	var pick := ItemFactory.craft("pioche", {"bois": "chene", "minerai": "fer"}, 1.0)
	player.inventory.add_object(pick)
	player.call("bind_hotbar", 3, {"kind": "object", "object": pick})
	ok = _report("en combat, un chiffre pointant sur un OUTIL laisse changer de main",
		not bool(player.call("_use_from_combat", 3))) and ok

	# LES DEUX BRAS SONT AFFICHÉS quand on boxe. La mécanique envoyait bien deux
	# coups, mais le bras gauche n'était pas DESSINÉ : le second partait d'un
	# membre invisible, et le joueur ne voyait qu'une main.
	for slot: String in ["arme_1", "arme_2"]:
		if not (player.equipment.equipped(slot) as Dictionary).is_empty():
			player.call("unequip_slot", slot)
	player.selected_slot = player.COMBAT_SLOT
	ok = _report("à mains nues, le bras gauche est bien un membre actif",
		bool(player.call("left_hand_busy"))) and ok

	# UN EMPLACEMENT VIDE NE PIÈGE PAS LE JOUEUR : l'appui doit retomber sur la
	# sélection ordinaire, sinon on resterait coincé en combat sans en sortir.
	# L'EMPLACEMENT EST VIDÉ EXPLICITEMENT. L'auto-remplissage a garni la barre :
	# le supposer libre parce qu'on n'y a rien mis soi-même, c'est tester autre
	# chose que ce qu'on croit — ici, manger ce que le remplissage y avait posé.
	player.call("unbind_hotbar", 8)
	ok = _report("un emplacement vide laisse le chiffre changer de main",
		not bool(player.call("_use_from_combat", 8))) and ok
	return ok


func _check_dual_wielding() -> bool:
	var ok := true
	print("[%s] --- dual wielding ---" % TAG)
	_equip_sword()

	# LE COMBAT S'ASSIGNE, ET C'EST LE CONTRAIRE DE CE QU'ON VÉRIFIAIT ICI
	# (2026-08-07). L'emplacement 1 était RÉSERVÉ et refusait toute liaison ; le
	# combat est devenu une ENTRÉE comme une autre, qu'on pose où l'on veut. Ce
	# qu'il faut prouver a donc changé de sens : l'entrée suit son assignation,
	# et se DÉPLACE au lieu de se dédoubler.
	player.call("bind_hotbar", 5, {"kind": "combat"})
	player.selected_slot = 5
	var moved: bool = String((player.call("held_entry") as Dictionary).get("kind", "")) == "combat"
	ok = _report("le combat se joue depuis l'emplacement où on l'a mis", moved) and ok
	var count := 0
	for index: int in player.hotbar_bindings:
		if String((player.hotbar_bindings[index] as Dictionary).get("kind", "")) == "combat":
			count += 1
	ok = _report("l'assigner ailleurs le DÉPLACE, il ne se dédouble pas",
		count == 1, "%d occurrence(s)" % count) and ok
	# Remis à sa place pour la suite des tests.
	player.call("bind_hotbar", player.COMBAT_SLOT, {"kind": "combat"})
	player.selected_slot = player.COMBAT_SLOT

	# Une seule arme : une posture à une main, un seul coup par clic.
	var solo_stance := String(player.call("combat_stance"))
	var attack: MeleeAttack = player.get("_attack")
	await _swing_and_collect()
	ok = _report("une arme : posture « une_main », 1 frappe",
		solo_stance == "une_main" and attack.strikes == 1,
		"%s, %d frappe(s)" % [solo_stance, attack.strikes]) and ok

	# Seconde arme en main gauche : la posture bascule toute seule.
	var dagger := ItemFactory.craft("dague", {"bois": "chene", "minerai": "fer"}, 1.0)
	player.inventory.add_object(dagger)
	player.call("equip_instance_in_slot", dagger, "arme_2")
	var stance := String(player.call("combat_stance"))
	ok = _report("deux armes à une main : posture « deux_armes »",
		stance == "deux_armes", stance) and ok
	ok = _report("la main gauche porte bien la seconde arme",
		String((player.call("offhand_weapon") as Dictionary).get("item_id", "")) == "dague") and ok

	# UN CLIC, DEUX COUPS. Et chacun doit porter les stats de SON arme : c'est
	# ce qui fait que deux armes différentes ne se valent pas.
	var target := _spawn_in_front(1.2)
	var hits := await _swing_and_collect()
	var reaches: Array[float] = []
	for hit: Dictionary in hits:
		reaches.append(float((hit["stats"] as Dictionary).get("reach", 0.0)))
	var two_strikes: bool = attack.strikes == 2
	ok = _report("un clic engage deux frappes", two_strikes,
		"%d frappe(s) déclarée(s), %d coup(s) porté(s)" % [attack.strikes, hits.size()]) and ok
	# Les deux armes n'ont pas la même allonge : deux coups aux stats identiques
	# trahiraient une seconde frappe qui rejoue la première arme.
	if hits.size() >= 2:
		ok = _report("chaque frappe porte les stats de SON arme",
			not is_equal_approx(reaches[0], reaches[1]),
			"allonges %.2f puis %.2f" % [reaches[0], reaches[1]]) and ok
	_despawn(target)

	# Un bouclier CHASSE la seconde arme du même emplacement, et la posture suit.
	var shield := ItemFactory.craft("ecu", {"bois": "chene", "minerai": "fer"}, 1.0)
	player.inventory.add_object(shield)
	player.call("equip_instance_in_slot", shield, "arme_2")
	var shield_stance := String(player.call("combat_stance"))
	ok = _report("arme + bouclier : posture « arme_bouclier »",
		shield_stance == "arme_bouclier", shield_stance) and ok
	ok = _report("le bouclier a chassé la seconde arme",
		(player.call("offhand_weapon") as Dictionary).is_empty()) and ok

	# Une arme à DEUX MAINS occupe les deux : la main gauche se tait.
	player.call("unequip_slot", "arme_1")
	var greatsword := ItemFactory.craft("espadon", {"bois": "chene", "minerai": "fer"}, 1.0)
	player.inventory.add_object(greatsword)
	player.call("equip_instance_in_slot", greatsword, "arme_1")
	var two_handed := String(player.call("combat_stance"))
	ok = _report("arme à deux mains : posture « deux_mains », bouclier inopérant",
		two_handed == "deux_mains"
			and not bool((player.call("shield_profile") as Dictionary)["present"]),
		two_handed) and ok
	player.call("unequip_slot", "arme_2")
	return ok


## LES PNJ SE DÉFENDENT (2026-08-02). La lecture n'allait que dans un sens : on
## apprenait à lire leurs coups, ils n'opposaient rien aux nôtres. Trois choses
## à prouver, et aucune ne se voit à l'œil :
##   1. une garde bien orientée ARRÊTE la lame du joueur ;
##   2. une garde du MAUVAIS côté ne sert à rien — sinon parer serait un bouton
##      et non un pari ;
##   3. une créature ne peut pas parer deux coups d'affilée : c'est ce repos qui
##      crée l'ouverture, et sans lui le combat devient un mur.
func _check_npc_defence() -> bool:
	var ok := true
	print("[%s] --- défense des PNJ ---" % TAG)
	_equip_sword()
	var target := _spawn_in_front(1.2)

	# Garde FORCÉE du bon côté : on court-circuite le jet de lecture, qui n'est
	# pas ce qu'on teste ici.
	var attack: MeleeAttack = player.get("_attack")
	target.set("guard_direction", MeleeAttack.guard_for(MeleeAttack.Direction.ESTOC))
	target.set("_guard_ticks", 60)
	var hp_before: float = target.health
	var blocked := await _swing_and_collect()
	ok = _report("une garde bien orientée arrête la lame",
		blocked.is_empty() and is_equal_approx(target.health, hp_before),
		"%d coup(s), PV %.0f → %.0f" % [blocked.size(), hp_before, target.health]) and ok

	# Garde du MAUVAIS côté : le coup doit passer entier.
	target.set("guard_direction", MeleeAttack.Direction.TAILLE_GAUCHE)
	target.set("_guard_ticks", 60)
	var through := await _swing_and_collect()
	ok = _report("une garde du mauvais côté ne protège pas",
		not through.is_empty(), "%d coup(s)" % through.size()) and ok
	_despawn(target)

	# LE REPOS ENTRE DEUX GARDES. On rallume la réaction à la télégraphie et on
	# annonce deux coups coup sur coup : le second ne doit pas pouvoir être paré.
	CreatureManager.npc_guard_enabled = true
	var second := _spawn_in_front(1.2)
	second.set("_guard_cooldown_ticks", 0)
	second.set("_guard_ticks", 0)
	# `react_to_telegraph` porte le jet de lecture ; on l'appelle jusqu'à ce
	# qu'une garde monte, puis on vérifie que la SUIVANTE est refusée.
	var raised := false
	for i in 40:
		second.call("react_to_telegraph", MeleeAttack.Direction.ESTOC)
		if bool(second.call("is_guarding")):
			raised = true
			break
	var refused := false
	if raised:
		second.set("_guard_ticks", 0)   # la garde retombe, mais le repos court
		second.call("react_to_telegraph", MeleeAttack.Direction.ESTOC)
		refused = not bool(second.call("is_guarding"))
	ok = _report("pas deux parades d'affilée : la seconde est refusée",
		raised and refused, "garde levée=%s, seconde refusée=%s" % [raised, refused]) and ok
	_despawn(second)
	CreatureManager.npc_guard_enabled = false
	return ok


## SEULE LA TÊTE BLESSE, DES DEUX CÔTÉS (2026-08-02, demande de l'auteur).
##
## L'invariant existait côté joueur depuis le re-découpage des pièces, mais pas
## côté créature : leur portée vulnérante était calculée à part, sans l'échelle
## d'affichage des pièces — leur fer visible dépassait de 15 % la zone qui
## blesse — et le sweet spot ne s'appliquait qu'au joueur, si bien qu'un bandit
## touchant du talon de sa lame infligeait des dégâts pleins.
##
## Ce qui se vérifie : les deux camps lisent la MÊME fonction, la portée
## vulnérante commence bien à la jonction manche/tête, et le manche ne blesse
## jamais — quel que soit celui qui le tient.
func _check_head_only_symmetry() -> bool:
	var ok := true
	print("[%s] --- « seule la tête blesse », des deux côtés ---" % TAG)
	var arm: float = preload("res://scenes/entities/player_body.gd").HAND_ARC_RADIUS
	var draw: float = preload("res://scenes/entities/held_item.gd").PART_SCALE

	for weapon_id: String in ["dague", "epee", "hallebarde"]:
		var stats := WeaponStats.derive(GameData.functionalities[weapon_id], {})
		var span := WeaponStats.head_span(stats, arm, draw)
		# Le joueur suit exactement cette portée : ses points échantillonnés
		# doivent commencer et finir dessus.
		var samples: PackedFloat32Array = player.call("_head_distances", stats)
		var same: bool = absf(samples[0] - span.x) < 0.001 			and absf(samples[samples.size() - 1] - span.y) < 0.001
		print("[%s]   %-11s portée vulnérante %.2f→%.2f m — joueur et PNJ : %s" % [
			TAG, weapon_id, span.x, span.y, "MÊME" if same else "DIVERGENTE"])
		ok = ok and same
		# Et le MANCHE ne blesse pas : juste avant le talon du fer, le facteur
		# doit être nul.
		var on_haft := WeaponStats.sweet_spot_factor(span.x - 0.02, span.y, span.x)
		var on_head := WeaponStats.sweet_spot_factor(span.y, span.y, span.x)
		ok = _report("  %s : manche inoffensif, pointe à plein" % weapon_id,
			is_zero_approx(on_haft) and on_head > 0.99,
			"manche %.2f · pointe %.2f" % [on_haft, on_head]) and ok

	# ARME NATURELLE (croc, griffe, poing) : pas de manche, mais la base du
	# membre ne blesse pas non plus — l'épaule d'un loup n'est pas sa mâchoire.
	var natural := WeaponStats.derive(GameData.functionalities["mains_nues"], {})
	var natural_span := WeaponStats.head_span(natural, arm, draw)
	var base_harmless := is_zero_approx(WeaponStats.sweet_spot_factor(
		natural_span.x - 0.05, natural_span.y, natural_span.x))
	ok = _report("arme naturelle : la base du membre ne blesse pas",
		base_harmless and natural_span.x < natural_span.y,
		"vulnérante %.2f→%.2f m" % [natural_span.x, natural_span.y]) and ok
	return ok


## LE DÉCOR ET LE STAGGER (2026-08-02). Deux règles que le joueur subissait
## déjà et que les créatures ignoraient — donc deux asymétries qui rendaient le
## duel injuste sans qu'on puisse le voir :
##   1. la lame d'un PNJ traversait les MURS, celle du joueur non ;
##   2. encaisser n'interrompait le coup de personne, si bien qu'échanger à
##      l'aveugle était toujours payant et que parer devenait facultatif.
func _check_cover_and_stagger() -> bool:
	var ok := true
	print("[%s] --- couvert et stagger ---" % TAG)

	# 1. LIGNE DE VUE. On pose un mur entre deux points et on vérifie que le
	# test le voit — puis qu'il ne voit rien quand il n'y a rien.
	var camera: Node3D = main.get_node("FlyCamera")
	var origin: Vector3 = camera.global_position + Vector3(0.0, -1.0, 0.0)
	var far := origin + Vector3(0.0, 0.0, -3.0)
	# Dégager d'abord : le test doit partir d'un couloir vide.
	for dz in range(-4, 1):
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				WorldManager.set_block(Vector3i(
					floori(origin.x) + dx, floori(origin.y) + dy, floori(origin.z) + dz), 0)
	await main.get_tree().process_frame
	var clear_line: bool = not WorldManager.line_blocked(origin, far)
	# Puis on mure.
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			WorldManager.set_block(Vector3i(
				floori(origin.x) + dx, floori(origin.y) + dy, floori(origin.z) - 2), 1)
	await main.get_tree().process_frame
	var blocked: bool = WorldManager.line_blocked(origin, far)
	ok = _report("le décor coupe la ligne de vue (et pas quand il n'y a rien)",
		clear_line and blocked, "dégagé=%s muré=%s" % [clear_line, blocked]) and ok
	# On rouvre, les tests suivants ont besoin d'espace.
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			WorldManager.set_block(Vector3i(
				floori(origin.x) + dx, floori(origin.y) + dy, floori(origin.z) - 2), 0)
	await main.get_tree().process_frame

	# 2. STAGGER DE LA CRÉATURE : un coup reçu en plein wind-up annule son coup.
	var target := _spawn_in_front(1.2)
	target.call("react_to_telegraph", MeleeAttack.Direction.ESTOC)   # sort la garde du chemin
	target.set("_guard_ticks", 0)
	target.set("_attack_declared", true)
	target.set("_windup_left_ms", 500.0)
	target.call("_start_pose", "windup", 0.5)
	target.call("take_damage", 3.0)
	var creature_staggered: bool = not bool(target.get("_attack_declared"))
	ok = _report("créature frappée : son coup en préparation est annulé",
		creature_staggered, "wind-up restant %.0f ms" % float(target.get("_windup_left_ms"))) and ok
	_despawn(target)

	# 3. STAGGER DU JOUEUR : encaisser interrompt sa frappe.
	_equip_sword()
	var attack: MeleeAttack = player.get("_attack")
	attack.interrupt()
	player.call("_begin_attack")
	var was_busy: bool = attack.is_busy()
	player.call("take_damage", 4)
	ok = _report("joueur frappé : sa frappe en cours est interrompue",
		was_busy and not attack.is_busy(),
		"engagé=%s puis engagé=%s" % [was_busy, attack.is_busy()]) and ok
	return ok


## CRUSHTHROUGH (2026-08-02). Sans lui, un adversaire qui pare correctement est
## IMPRENABLE : le seul levier restant est l'endurance, et le duel se fige en
## attente. C'est la mécanique qui donne aux masses et aux marteaux leur raison
## d'être face aux lames.
##
## Trois conditions, et le test vérifie que chacune ferme bien son abus — sinon
## la règle deviendrait « les armes lourdes ignorent la défense », ce qui est
## l'inverse de l'intention.
func _check_crushthrough() -> bool:
	var ok := true
	print("[%s] --- crushthrough ---" % TAG)
	var hammer := WeaponStats.derive(GameData.functionalities["marteau_guerre"], {})
	var sword := WeaponStats.derive(GameData.functionalities["espadon"], {})
	var mace := WeaponStats.derive(GameData.functionalities["masse"], {})

	ok = _report("marteau à deux mains, coup haut : traverse la garde",
		WeaponStats.crushes_through(hammer, MeleeAttack.Direction.OVERHEAD),
		"poids %.0f" % float(hammer["weight"])) and ok
	ok = _report("le même marteau en taille : ne traverse PAS",
		not WeaponStats.crushes_through(hammer, MeleeAttack.Direction.TAILLE_DROITE)) and ok
	ok = _report("une lame lourde à deux mains : ne traverse pas (elle dévie)",
		not WeaponStats.crushes_through(sword, MeleeAttack.Direction.OVERHEAD),
		"espadon, %s" % String(sword["damage_type"])) and ok
	ok = _report("une masse à UNE main : ne traverse pas (pas l'inertie)",
		not WeaponStats.crushes_through(mace, MeleeAttack.Direction.OVERHEAD),
		"poids %.0f, %d main" % [float(mace["weight"]), int(mace["hands"])]) and ok
	# Et ce qui passe ne doit pas être un coup à découvert : la garde qui cède
	# encaisse quand même. Sans cette réduction, bloquer serait PIRE que ne rien
	# faire face à un marteau.
	ok = _report("traverser une garde coûte moins qu'un coup à découvert",
		WeaponStats.CRUSHTHROUGH_DAMAGE > 0.0 and WeaponStats.CRUSHTHROUGH_DAMAGE < 1.0,
		"%.0f %% des dégâts" % (WeaponStats.CRUSHTHROUGH_DAMAGE * 100.0)) and ok
	return ok


## LE BOUCLIER S'USE (2026-08-02). Il était éternel : le porter n'avait aucun
## coût, donc « bouclier » battait « rien » pour toujours et le seul arbitrage
## du GDD (deux mains / bouclier / deux armes) n'en était pas un.
func _check_shield_wear() -> bool:
	var ok := true
	print("[%s] --- usure du bouclier ---" % TAG)
	_equip_sword()
	var shield := ItemFactory.craft("ecu", {"bois": "chene", "minerai": "fer"}, 1.0)
	player.inventory.add_object(shield)
	player.call("equip_instance_in_slot", shield, "arme_2")
	var structure: Dictionary = player.call("shield_structure")
	var starts_whole: bool = not structure.is_empty() and float(structure["current"]) > 0.0 		and is_equal_approx(float(structure["current"]), float(structure["max"]))
	ok = _report("un bouclier neuf est intact", starts_whole,
		"%.0f / %.0f" % [structure.get("current", 0.0), structure.get("max", 0.0)]) and ok

	# Encaisser l'entame, et il finit par céder.
	player.stamina = player.stamina_max
	player.call("_set_guard", true)
	var blows := 0
	while not bool(player.call("shield_broken")) and blows < 400:
		player.stamina = player.stamina_max   # on teste la STRUCTURE, pas l'endurance
		player.call("absorb_on_guard", 12.0, false)
		blows += 1
	ok = _report("il finit par se briser sous les coups", bool(player.call("shield_broken")),
		"%d coup(s) encaissé(s)" % blows) and ok
	# Et une fois brisé, il ne protège PLUS : c'est ce qui doit se sentir.
	var profile: Dictionary = player.call("shield_profile")
	ok = _report("brisé, il n'absorbe plus rien",
		not bool(profile["present"]) and int(profile["couverture"]) == 0) and ok
	player.call("_set_guard", false)
	player.call("unequip_slot", "arme_2")
	return ok


## RÉPERTOIRE D'ATTAQUES (2026-08-02). Toutes les armes faisaient les quatre
## directions : une pique taillait comme une dague, une masse piquait de la
## pointe. Le choix d'une arme était donc purement chiffré, alors que dans
## Mount & Blade on choisit une arme pour son JEU.
##
## Ce qui doit être vrai : chaque arme a le répertoire qu'on lui a déclaré, et
## un geste hors répertoire est REPORTÉ sur le coup le plus proche — jamais
## refusé. Un clic qui ne produirait rien se lirait comme une arme cassée.
func _check_weapon_repertoire() -> bool:
	var ok := true
	print("[%s] --- répertoire d'attaques ---" % TAG)
	var expected := {
		"lance": [MeleeAttack.Direction.ESTOC, MeleeAttack.Direction.OVERHEAD],
		"masse": [MeleeAttack.Direction.TAILLE_GAUCHE, MeleeAttack.Direction.TAILLE_DROITE,
			MeleeAttack.Direction.OVERHEAD],
		"epee": [MeleeAttack.Direction.ESTOC, MeleeAttack.Direction.TAILLE_GAUCHE,
			MeleeAttack.Direction.TAILLE_DROITE, MeleeAttack.Direction.OVERHEAD],
	}
	for weapon_id: String in expected:
		var stats := WeaponStats.derive(GameData.functionalities[weapon_id], {})
		var dirs: Array = stats["directions"]
		var names: Array[String] = []
		for d: int in dirs:
			names.append(MeleeAttack.direction_name(d))
		var same: bool = dirs.size() == (expected[weapon_id] as Array).size()
		for d: int in (expected[weapon_id] as Array):
			same = same and (d in dirs)
		print("[%s]   %-8s : %s" % [TAG, weapon_id, ", ".join(names)])
		ok = ok and same

	# UNE MASSE NE PIQUE PAS : un estoc demandé devient un coup haut, le geste le
	# plus proche du poussé — et surtout il devient QUELQUE CHOSE.
	var mace: Array = WeaponStats.derive(GameData.functionalities["masse"], {})["directions"]
	var reported := MeleeAttack.nearest_allowed(MeleeAttack.Direction.ESTOC, mace)
	ok = _report("masse : un estoc demandé devient un coup haut",
		reported == MeleeAttack.Direction.OVERHEAD,
		MeleeAttack.direction_name(reported)) and ok
	# UNE LANCE NE FAUCHE PAS : une taille devient un estoc ou un coup haut.
	var spear: Array = WeaponStats.derive(GameData.functionalities["lance"], {})["directions"]
	var spear_cut := MeleeAttack.nearest_allowed(MeleeAttack.Direction.TAILLE_DROITE, spear)
	ok = _report("lance : une taille demandée est reportée",
		spear_cut in spear, MeleeAttack.direction_name(spear_cut)) and ok
	# ET JAMAIS DE REFUS : quelle que soit la demande, il sort une direction
	# jouable. Un clic sans effet se lirait comme un bug.
	var always := true
	for weapon_id: String in ["lance", "masse", "dague", "rapiere", "hache_arme"]:
		var dirs: Array = WeaponStats.derive(GameData.functionalities[weapon_id], {})["directions"]
		for wanted in 4:
			always = always and (MeleeAttack.nearest_allowed(wanted, dirs) in dirs)
	ok = _report("aucun geste n'est refusé : il sort toujours une attaque jouable",
		always) and ok
	return ok


## LA CRÉATURE BALAIE À LA FRAME (2026-08-02). Sa géométrie était échantillonnée
## AU TICK, à l'instant de la déclaration : on approchait l'arc entier avant même
## qu'il ne soit joué, si bien qu'on pouvait traverser l'arc d'un PNJ entre deux
## ticks sans être touché. C'était le dernier endroit où les deux camps
## n'étaient pas jugés de la même façon.
##
## Ce qui doit être vrai maintenant : le coup n'existe qu'APRÈS avoir été
## constaté par le balayage, il porte la zone touchée comme celui du joueur, et
## il porte un bonus de vitesse — la mécanique signature de Mount & Blade, qui
## ne fonctionnait que dans un sens.
func _check_creature_frame_sweep() -> bool:
	var ok := true
	print("[%s] --- balayage des créatures à la frame ---" % TAG)
	CreatureManager.npc_guard_enabled = false
	var creature := _spawn_in_front(1.0, "bandit")
	creature.set("ai_profile", "hostile")
	# LES DEUX COMBATTANTS AU MÊME NIVEAU. En mode sonde le joueur survole le
	# terrain : la créature apparue « devant lui » se pose sur le sol réel, deux
	# mètres et demi plus bas ou plus haut. Sa lame ne peut alors PAS l'atteindre
	# — et c'est géométriquement juste, ce n'est pas un défaut à masquer. On
	# descend donc le joueur au niveau de son adversaire, ce qui est la seule
	# situation où un duel a un sens.
	for i in 4:
		creature.tick_step(player.get_position_for_ai(), player)
		await wait_frame()
	var ground: float = creature.logical_position.y + creature.FEET_OFFSET
	var stand: Vector3 = creature.logical_position
	stand.y = ground + FlyCamera.EYE_HEIGHT
	var away: Vector3 = (camera.global_position - creature.logical_position)
	away.y = 0.0
	if away.length_squared() < 0.01:
		away = Vector3.BACK
	camera.global_position = stand + away.normalized() * 1.0
	await wait_frame()
	# TICK EXCLUSIF (2026-08-02). `CreatureManager` tique TOUTES les créatures de
	# sa liste, et depuis que la sonde laisse passer des frames, ce tick-là
	# tourne aussi. Or le coup constaté est un ÉVÉNEMENT À USAGE UNIQUE : le
	# premier `tick_step` qui passe le consomme. Le manager volait donc
	# l'événement que la sonde attendait. On sort la créature de sa liste — elle
	# reste dans l'arbre, donc son `_process` continue de balayer — et la sonde
	# devient seule à la tiquer.
	CreatureManager.creatures.erase(creature)
	# On déroule l'attaque en laissant vivre les frames, et on récupère
	# l'événement du tick.
	# ON ATTEND UN COUP QUI TOUCHE, pas le premier coup tout court. Depuis que
	# les créatures ont un jeu de jambes, elles contournent et reculent : une
	# frappe peut légitimement partir dans le vide. Ce test mesure CE QUE PORTE
	# un coup qui aboutit — exiger que le premier aboutisse reviendrait à
	# interdire le déplacement au nom de la reproductibilité.
	var event: Dictionary = {}
	var hit: Dictionary = {}
	for i in 400:
		event = creature.tick_step(player.get_position_for_ai(), player)
		if not event.is_empty():
			hit = event.get("hit", {})
			if not hit.is_empty():
				break
		await wait_frame()
	var landed: bool = not hit.is_empty()
	ok = _report("un coup qui aboutit remonte au tick", landed) and ok
	ok = _report("il porte la zone touchée, comme celui du joueur",
		not hit.is_empty() and hit.has("id"),
		String(hit.get("id", "(aucune)"))) and ok
	# BONUS DE VITESSE : présent, et borné comme celui du joueur.
	var speed := float(hit.get("speed", -1.0))
	ok = _report("il porte un bonus de vitesse borné",
		speed >= WeaponStats.SPEED_BONUS_MIN and speed <= WeaponStats.SPEED_BONUS_MAX,
		"%.2f (bornes %.2f–%.2f)" % [speed, WeaponStats.SPEED_BONUS_MIN,
			WeaponStats.SPEED_BONUS_MAX]) and ok
	# Et la portée vulnérante annoncée est bien celle de son arme.
	var stats := WeaponStats.derive(creature.call("combat_functionality"), {})
	var span := WeaponStats.head_span(stats,
		preload("res://scenes/entities/player_body.gd").HAND_ARC_RADIUS,
		preload("res://scenes/entities/held_item.gd").PART_SCALE)
	ok = _report("la zone touchée l'a été par la TÊTE de son arme",
		absf(float(hit.get("head_start", -1.0)) - span.x) < 0.001
			and absf(float(hit.get("reach", -1.0)) - span.y) < 0.001,
		"%.2f→%.2f m" % [hit.get("head_start", 0.0), hit.get("reach", 0.0)]) and ok
	_despawn(creature)
	return ok


## LE BRAS GAUCHE AGIT COMME LE DROIT (2026-08-02, demande de l'auteur).
##
## Il n'y avait qu'UN ressort d'inertie, réservé à la main forte : la gauche se
## TÉLÉPORTAIT sur sa cible. Un bouclier claquait en position, une seconde arme
## n'avait aucun ballant, et les deux bras ne se lisaient pas comme appartenant
## au même corps.
##
## Ce qui se vérifie : la gauche traîne comme la droite, elle a son PROPRE état
## (deux mains ne peuvent pas partager une vitesse), et le retard publié — celui
## qui fait traîner la POINTE de l'arme — reste celui de la main qui frappe.
func _check_left_arm() -> bool:
	var ok := true
	print("[%s] --- bras gauche ---" % TAG)
	var smoothed: Dictionary = player.get("_hand_smoothed")
	var velocity: Dictionary = player.get("_hand_velocity")
	ok = _report("chaque main a son propre ressort",
		smoothed.has("droite") and smoothed.has("gauche")
			and velocity.has("droite") and velocity.has("gauche")) and ok

	# On tire les deux mains vers des cibles ÉLOIGNÉES et on constate qu'aucune
	# n'y arrive d'un coup : c'est la définition du ballant.
	var stats: Dictionary = player.call("_current_weapon_stats")
	player.set("_hand_initialised", {"droite": false, "gauche": false})
	var near := camera.global_position
	var far := camera.global_position + Vector3(10.0, 0.0, 0.0)
	# AMORÇAGE. Au tout premier appel le ressort se POSE sur sa cible : il n'a
	# pas d'historique, et le contraire ferait démarrer le bras à l'origine du
	# monde. On l'amorce donc près du corps, PUIS on éloigne brutalement la
	# cible — c'est là que le ballant doit se voir.
	player.call("_integrate_hand_inertia", near, DT, stats, "gauche", false)
	var left_first: Vector3 = player.call("_integrate_hand_inertia", far, DT, stats, "gauche", false)
	var left_second: Vector3 = player.call("_integrate_hand_inertia", far, DT, stats, "gauche", false)
	var lags: bool = left_first.distance_to(far) > 0.5 		and left_second.distance_to(far) < left_first.distance_to(far)
	ok = _report("la main gauche TRAÎNE puis rattrape (elle ne se téléporte plus)",
		lags, "reste %.2f m puis %.2f m" % [left_first.distance_to(far), left_second.distance_to(far)]) and ok

	# Les deux états sont INDÉPENDANTS : bouger l'une ne doit pas déplacer l'autre.
	var right_before: Vector3 = (player.get("_hand_smoothed") as Dictionary)["droite"]
	player.call("_integrate_hand_inertia", far, DT, stats, "gauche", false)
	var right_after: Vector3 = (player.get("_hand_smoothed") as Dictionary)["droite"]
	ok = _report("les deux mains ne partagent pas leur état",
		right_before.is_equal_approx(right_after)) and ok

	# Et le RETARD publié n'est pas écrasé par la main d'appoint : c'est lui qui
	# fait traîner la pointe, il doit rester celui de la main qui frappe.
	player.call("_integrate_hand_inertia", far, DT, stats, "droite", true)
	var lag_right: Vector3 = player.get("_lag_offset")
	player.call("_integrate_hand_inertia", near - Vector3(10.0, 0.0, 0.0), DT, stats, "gauche", false)
	var lag_after: Vector3 = player.get("_lag_offset")
	ok = _report("la main d'appoint n'écrase pas le retard de la main qui frappe",
		lag_right.is_equal_approx(lag_after)) and ok
	return ok


## FEINTE ET CHAMBERING DES PNJ (2026-08-02). Les deux gestes les plus exigeants
## du jeu n'existaient QUE pour le joueur : il pouvait feinter et chambrer, eux
## non. Conséquence, attendre derrière sa garde ne coûtait jamais rien — il
## suffisait de patienter jusqu'au coup annoncé, qui arrivait toujours.
func _check_npc_feint_and_chamber() -> bool:
	var ok := true
	print("[%s] --- feinte et chambering des PNJ ---" % TAG)

	# La feinte MONTE avec le niveau : un villageois se lit comme un livre
	# ouvert, un chef de bande ment. Et elle reste BORNÉE — une créature qui
	# feinte une fois sur deux devient illisible, et le joueur cesse d'accorder
	# du crédit à ce qu'il voit.
	var novice := _spawn_in_front(1.0, "villageois")
	var veteran := _spawn_in_front(1.0, "chef_de_bande")
	var novice_chance: float = novice.call("_feint_chance")
	var veteran_chance: float = veteran.call("_feint_chance")
	ok = _report("la feinte monte avec le niveau, et reste bornée",
		veteran_chance > novice_chance and veteran_chance <= Creature_FEINT_MAX(),
		"villageois %.0f %% · chef de bande %.0f %%" % [
			novice_chance * 100.0, veteran_chance * 100.0]) and ok

	# CHAMBERING : la créature part dans la MÊME direction, en wind-up. C'est
	# exactement la condition que le joueur doit remplir pour chambrer.
	veteran.set("_attack_declared", true)
	veteran.set("_windup_left_ms", 300.0)
	veteran.set("attack_direction", MeleeAttack.Direction.TAILLE_DROITE)
	var chambers: bool = veteran.call("is_chambering", MeleeAttack.Direction.TAILLE_DROITE)
	var not_other: bool = not bool(veteran.call("is_chambering", MeleeAttack.Direction.ESTOC))
	ok = _report("chambrer exige la MÊME direction", chambers and not_other) and ok
	# Hors wind-up, il n'y a plus rien à chambrer.
	veteran.set("_attack_declared", false)
	veteran.set("_windup_left_ms", 0.0)
	ok = _report("hors préparation, plus de chambering",
		not bool(veteran.call("is_chambering", MeleeAttack.Direction.TAILLE_DROITE))) and ok
	_despawn(novice)
	_despawn(veteran)
	return ok


## Borne haute de la feinte, lue sur la créature (la constante vit là-bas).
func Creature_FEINT_MAX() -> float:
	return 0.30


## LE TIR (2026-08-02). L'arc et l'arbalète existaient en objets — dés, allonge,
## temps de recharge dérivés — mais il n'y avait AUCUN projectile dans le code.
## Ce qui se vérifie ici, et qu'aucun coup d'œil ne donne : une arme de tir est
## reconnue comme telle, la corde doit être tendue pour que le tir soit précis,
## la flèche CHUTE (donc il faut viser haut au loin), elle est arrêtée par le
## décor, et elle touche les MÊMES zones qu'une lame.
func _check_ranged() -> bool:
	var ok := true
	print("[%s] --- tir ---" % TAG)
	var bow := WeaponStats.derive(GameData.functionalities["arc"], {})
	var sword := WeaponStats.derive(GameData.functionalities["epee"], {})
	ok = _report("une arme de tir se reconnaît à sa donnée, pas à son nom",
		WeaponStats.is_ranged(bow) and not WeaponStats.is_ranged(sword),
		"arc %.0f m/s · épée %.0f" % [bow["vitesse_projectile"],
			sword["vitesse_projectile"]]) and ok

	# LA TENSION EST OBLIGATOIRE. Décocher à moitié tendu doit disperser
	# largement ; c'est ce qui interdit le clic frénétique.
	var ranged := RangedAttack.new()
	ranged.begin(bow)
	var loose := ranged.spread_degrees(1.0)
	for i in 120:
		ranged.advance(DT)
	var drawn := ranged.spread_degrees(1.0)
	ok = _report("tendre resserre le tir", drawn < loose * 0.5,
		"%.1f° à vide → %.1f° tendu" % [loose, drawn]) and ok
	# ET TENIR EN JOUE FATIGUE : la précision redescend.
	for i in 240:
		ranged.advance(DT)
	var tired := ranged.spread_degrees(1.0)
	ok = _report("tenir en joue trop longtemps dégrade la visée", tired > drawn,
		"%.1f° → %.1f°" % [drawn, tired]) and ok
	# La COMPÉTENCE resserre sans jamais annuler.
	var novice := ranged.spread_degrees(1.0)
	var master := ranged.spread_degrees(3.0)
	ok = _report("la compétence resserre le cône sans l'annuler",
		master < novice and master > 0.0, "%.2f° → %.2f°" % [novice, master]) and ok

	# LA FLÈCHE CHUTE. On tire à l'horizontale et on constate qu'elle est plus
	# bas qu'à son départ — sans cela, viser loin ne demanderait rien.
	var origin: Vector3 = camera.global_position + Vector3(0.0, 3.0, 0.0)
	var before: int = ProjectileManager.flying_count()
	ProjectileManager.launch(origin, Vector3(1.0, 0.0, 0.0), bow, 10.0, 1.0, player)
	ok = _report("le tir met un projectile en vol",
		ProjectileManager.flying_count() == before + 1) and ok
	var start_y := origin.y
	for i in 12:
		await main.get_tree().process_frame
	# Le projectile a disparu (planté ou épuisé) ou il est descendu : dans les
	# deux cas il n'a PAS volé droit.
	var dropped := true
	for shot: Dictionary in (ProjectileManager.get("_flying") as Array):
		if (shot["position"] as Vector3).y >= start_y:
			dropped = false
	ok = _report("la flèche chute (il faut viser haut au loin)", dropped) and ok

	# --- Ce que l'audit du 2026-08-02 a trouvé, et qui doit le rester ---
	_equip_ranged()
	# ON NE PARE PAS AVEC UN ARC : le clic droit levait une garde quelle que
	# soit l'arme, donc on bloquait une épée avec une corde tendue.
	player.call("_set_guard", true)
	var guarded_with_bow: bool = bool(player.get("_guard_active"))
	player.call("_set_guard", false)
	ok = _report("un arc ne pare pas", not guarded_with_bow) and ok

	# BANDER EXCLUT DE FRAPPER, et réciproquement : deux cycles d'attaque ne
	# doivent jamais tourner en parallèle.
	player.call("_begin_draw")
	var drawing: bool = (player.get("_ranged") as RangedAttack).is_busy()
	player.call("_begin_attack")
	var melee_blocked: bool = not (player.get("_attack") as MeleeAttack).is_busy()
	ok = _report("on ne frappe pas en bandant", drawing and melee_blocked) and ok

	# CHANGER D'ARME DÉTEND LA CORDE : le tir partait sinon avec les stats de
	# l'arc, depuis une main qui tenait autre chose.
	player.call("unequip_slot", "arme_1")
	player.call("_current_weapon_stats")
	ok = _report("changer d'arme détend la corde",
		not (player.get("_ranged") as RangedAttack).is_busy()) and ok

	# --- LE CARQUOIS ---------------------------------------------------------
	# Le tir était GRATUIT : sans munition à dépenser, une arme de distance
	# dominait tout — aucune raison de s'approcher, aucun arbitrage.
	_equip_ranged()
	var quiver: Dictionary = ItemFactory.resource_instance("fleche", 3)
	player.inventory.add_object(quiver)
	var before_count: int = player.call("ammo_count", "fleche")
	player.stamina = player.stamina_max
	player.call("_begin_draw")
	for i in 90:
		(player.get("_ranged") as RangedAttack).advance(DT)
	player.call("_fire_shot")
	var after_count: int = player.call("ammo_count", "fleche")
	ok = _report("tirer consomme une munition", after_count == before_count - 1,
		"%d → %d flèche(s)" % [before_count, after_count]) and ok

	# CARQUOIS VIDE : le tir est refusé, et la corde se détend plutôt que de
	# rester tendue indéfiniment.
	while player.call("ammo_count", "fleche") > 0:
		player.call("_consume_ammo", "fleche")
	player.call("_begin_draw")
	for i in 90:
		(player.get("_ranged") as RangedAttack).advance(DT)
	var flying_before: int = ProjectileManager.flying_count()
	player.call("_fire_shot")
	ok = _report("carquois vide : aucun tir ne part",
		ProjectileManager.flying_count() == flying_before
			and not (player.get("_ranged") as RangedAttack).is_busy()) and ok

	# --- LE TICK APPLIQUE BIEN LES IMPACTS ------------------------------------
	# Le tick des projectiles était branché avec la MAUVAISE SIGNATURE
	# (`_on_tick()` face à `tick_entities(tick_index)`) : Godot refusait l'appel
	# et le signal ne faisait RIEN. Les flèches volaient, touchaient, et
	# n'infligeaient AUCUN dégât — silencieusement, sans la moindre erreur en
	# console tant que personne ne tirait.
	#
	# On teste le CHEMIN DE DÉGÂTS lui-même, en lui soumettant un impact : c'est
	# exactement ce qui était mort. La trajectoire, elle, est couverte plus haut
	# (mise en vol, chute, arrêt par le décor).
	var target := _spawn_in_front(4.0)
	target.set("ai_profile", "civil")
	var hp_before: float = target.health
	var bow_stats := WeaponStats.derive(GameData.functionalities["arc"], {})
	(ProjectileManager.get("_pending") as Array).append({
		"victim": target, "zone": "torse", "mult": 1.0,
		"point": target.logical_position + Vector3(0.0, 1.0, 0.0),
		"stats": bow_stats, "hardness": 20.0, "quality": 1.0, "shooter": player,
	})
	for i in 20:
		await main.get_tree().process_frame
	ok = _report("le tick applique les impacts de projectile", target.health < hp_before,
		"PV %.0f → %.0f" % [hp_before, target.health]) and ok
	_despawn(target)
	return ok


## Met un ARC en main forte (emplacement de combat).
func _equip_ranged() -> void:
	if not (player.equipment.equipped("arme_1") as Dictionary).is_empty():
		player.call("unequip_slot", "arme_1")
	var bow := ItemFactory.craft("arc", {"bois": "chene", "minerai": "fer"}, 1.0)
	player.inventory.add_object(bow)
	player.call("equip_instance", bow)
	player.active_hotbar = 0
	player.selected_slot = player.COMBAT_SLOT


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

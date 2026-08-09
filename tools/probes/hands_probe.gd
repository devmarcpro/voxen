extends Probe
## Sonde `--probe-mains` (2026-08-03) — position des DEUX MAINS.
##
## POURQUOI. Deux défauts signalés par l'auteur : la main gauche ne tient pas
## l'arme quand celle-ci est à deux mains, et elle reste collée au corps quand
## seule la droite travaille. Ni l'un ni l'autre ne plante ni ne se voit dans un
## chiffre — c'est de la posture, donc exactement ce qu'une sonde doit mesurer
## en coordonnées avant qu'on juge une capture.
##
## Elle interroge `Player.hand_targets`, la seule source des cibles d'IK : ce
## que cette fonction rend est littéralement ce que les bras vont viser.

const TAG := "MAINS"
## Mêmes valeurs que celles passées par main.gd à chaque frame.
const HAND_RADIUS := 0.72
const OFFHAND_OFFSET := 0.28

var _ok := true


func _expect(condition: bool, message: String) -> void:
	print("[%s] %s — %s" % [TAG, "ok" if condition else "ÉCHEC", message])
	if not condition:
		_ok = false


func run() -> void:
	await wait_frame()
	_check_two_handed()
	_check_one_handed()
	_check_thrust()
	_check_two_handed_exclusivity()
	_check_combat_slot_shows_weapon()
	await _capture()
	finish(_ok, TAG)


## Équipe l'arme `item_id` en main forte, puis SIMULE DE VRAIES FRAMES.
##
## Le cycle de main.gd est un aller-retour : on calcule les cibles, on résout
## l'IK, et la position obtenue nourrit le calcul de la frame SUIVANTE (le
## manche part de la main droite réelle). Une version précédente de cette sonde
## appelait `hand_targets` quatre-vingt-dix fois d'affilée sans jamais résoudre
## l'IK entre-temps : les cibles convergeaient vers un ancrage périmé, et les
## chiffres obtenus ne décrivaient aucune frame réelle. Toute la mesure était à
## refaire.
func _targets_with(item_id: String) -> Dictionary:
	var weapon: Dictionary = ItemFactory.craft(item_id,
			{"bois": "chene", "minerai": "fer", "textile": "lin"}, 1.0)
	if weapon.is_empty():
		return {}
	player.inventory.add_object(weapon)
	player.equipment.equip(weapon)
	var body: Node = main.get("player_body")
	var targets := {}
	for i in 120:
		if body != null:
			body.call("follow_camera", camera, 1.9, 1.0 / 60.0)
			body.call("solve_legs")
			player.call("set_left_arm_span",
					body.call("shoulder_world_position", "gauche"),
					float(body.call("arm_reach", "gauche")))
			player.call("set_right_hand_actual", body.call("hand_world_position", "droite"))
		targets = player.hand_targets(HAND_RADIUS, OFFHAND_OFFSET, 1.0 / 60.0)
		if body != null:
			for side: String in targets:
				body.call("solve_arm", side, targets[side])
	return targets


## ARME À DEUX MAINS : la main gauche doit être COLLÉE AU MANCHE.
##
## ATTENTION — LA PREMIÈRE VERSION DE CE TEST ÉTAIT TAUTOLOGIQUE, et elle a
## conclu à tort que tout allait bien. Elle mesurait la distance de la CIBLE de
## la main gauche à l'axe prise→main droite ; or cette cible est calculée comme
## un point SUR cet axe (`grip + axis * along`). Le résultat était nul par
## construction, quelle que soit la réalité à l'écran. Une sonde qui mesure sa
## propre formule ne mesure rien.
##
## Ce qu'il faut regarder, et qu'on regarde maintenant :
##   1. l'os de la main gauche APRÈS IK, pas la cible — un IK à deux os
##      n'atteint sa cible que si elle est à portée du bras ;
##   2. la distance de cette main au SEGMENT DU MANCHE, reconstruit depuis la
##      main droite, la direction de l'arme et la géométrie des pièces.
func _check_two_handed() -> void:
	var body: Node = main.get("player_body")
	if body == null:
		_expect(false, "corps du joueur absent — posture non mesurable")
		return
	for item_id: String in ["espadon", "hallebarde", "marteau_guerre"]:
		var targets: Dictionary = _targets_with(item_id)
		if targets.is_empty() or not targets.has("gauche"):
			_expect(false, "%s (deux mains) : la main gauche n'a aucune cible" % item_id)
			continue
		# ON REJOUE LA BOUCLE DE main.gd EN ENTIER, `follow_camera` compris. Sans
		# lui le corps reste à l'origine du monde pendant que la caméra est à des
		# dizaines de mètres : la première mesure annonçait 95 m d'écart à la
		# cible, ce qui ne disait rien de la posture et tout de la sonde.
		body.call("follow_camera", camera, 1.9, 1.0 / 60.0)
		body.call("solve_legs")
		# Même envergure que celle poussée par main.gd à chaque frame : sans
		# elle le glissement sur le manche ne s'applique pas.
		player.call("set_left_arm_span",
				body.call("shoulder_world_position", "gauche"),
				float(body.call("arm_reach", "gauche")))
		for side: String in targets:
			body.call("solve_arm", side, targets[side])

		var stats: Dictionary = player.call("_current_weapon_stats")
		var handle := float(stats.get("handle_length", 0.0))
		var grip_main := float(stats.get("grip_main", 0.3))
		var hand_right: Vector3 = body.call("hand_world_position", "droite")
		var hand_left: Vector3 = body.call("hand_world_position", "gauche")
		var dir: Vector3 = player.call("weapon_direction")

		# LE MANCHE, en monde : de la main droite vers le pommeau d'un côté, vers
		# la tête de l'autre. C'est la pièce que la main gauche doit tenir.
		var pommel: Vector3 = hand_right - dir * (handle * grip_main)
		var fore: Vector3 = hand_right + dir * (handle * (1.0 - grip_main))
		var distance := _distance_to_segment(hand_left, pommel, fore)

		# L'IK A-T-IL SEULEMENT PU ATTEINDRE ? Une cible hors d'allonge laisse la
		# main court, et aucune correction de position ne rattrapera ça.
		var reach := float(body.call("arm_reach", "gauche"))
		var wanted: Vector3 = targets["gauche"]
		var miss := hand_left.distance_to(wanted)
		# ÉCART DE LA MAIN DROITE À SA PROPRE CIBLE : tout ce qui suit en hérite.
		# Le manche est reconstruit depuis elle, donc son erreur se propage
		# intégralement à la mesure de la main gauche.
		var miss_right := hand_right.distance_to(targets["droite"] as Vector3)
		print("[%s] %s : manche %.2f m — gauche à %.3f m du manche ; écarts aux cibles G %.3f / D %.3f (allonge %.2f m)" % [
				TAG, item_id, handle, distance, miss, miss_right, reach])
		_expect(miss < 0.08, "%s : la main gauche atteint sa cible (IK à portée)" % item_id)
		_expect(distance < 0.12, "%s : la main gauche est collée au manche" % item_id)


## ESTOC : le retrait à l'armement doit être AMPLE (demande de l'auteur), sans
## pour autant renvoyer la main derrière le corps ni raccourcir la portée du
## coup lui-même.
func _check_thrust() -> void:
	var basis := Basis.IDENTITY
	var origin := Vector3.ZERO
	var estoc: int = MeleeAttack.Direction.ESTOC
	var hand_start: Vector3 = MeleeAttack.tip_position(estoc, 0.0, origin, basis, HAND_RADIUS)
	var hand_end: Vector3 = MeleeAttack.tip_position(estoc, 1.0, origin, basis, HAND_RADIUS)
	var forward := -basis.z
	var start_depth: float = hand_start.dot(forward)
	var end_depth: float = hand_end.dot(forward)
	print("[%s] estoc : main à %.3f m devant la prise à l'armement, %.3f m au bout (recul %.3f m)" % [
			TAG, start_depth, end_depth, end_depth - start_depth])
	# AMPLE : le recul doit dépasser la moitié du rayon de main, sinon le geste
	# ne se lit pas — c'est tout l'objet du réglage.
	_expect(end_depth - start_depth > HAND_RADIUS * 0.5,
			"le retrait de l'estoc est ample")
	# MAIS DEVANT LE CORPS : sous zéro, le bras se retourne.
	_expect(start_depth > 0.05, "la main reste devant la prise à l'armement")
	# ET LA PORTÉE NE CHANGE PAS : seul le début du geste recule, la fin reste
	# à pleine extension — sinon on aurait modifié l'allonge des estocs.
	_expect(is_equal_approx(end_depth, HAND_RADIUS),
			"la pleine extension reste inchangée")


## Distance d'un point au segment [a, b].
func _distance_to_segment(point: Vector3, a: Vector3, b: Vector3) -> float:
	var span := b - a
	var length_squared := span.length_squared()
	if length_squared < 0.000001:
		return point.distance_to(a)
	var t := clampf((point - a).dot(span) / length_squared, 0.0, 1.0)
	return point.distance_to(a + span * t)


## ARME À UNE MAIN, sans bouclier ni seconde arme : la gauche ne doit pas
## rester plaquée au corps. C'est le second défaut signalé.
func _check_one_handed() -> void:
	# ON VIDE LES TROIS EMPLACEMENTS, arme_1 comprise. Ne libérer que la gauche
	# ne suffit pas : `equip` range dans le premier emplacement LIBRE, donc
	# l'épée partait en arme_2 derrière le marteau resté en main forte, et la
	# sonde mesurait du dual wielding en croyant tester une arme seule.
	player.equipment.unequip("arme_1")
	player.equipment.unequip("arme_2")
	player.equipment.unequip("bouclier")
	var targets: Dictionary = _targets_with("epee")
	var has_left: bool = targets.has("gauche")
	print("[%s] équipement : arme_1=%s arme_2=%s bouclier=%s ; bouclier présent=%s" % [
			TAG,
			String((player.equipment.equipped("arme_1") as Dictionary).get("item_id", "—")),
			String((player.equipment.equipped("arme_2") as Dictionary).get("item_id", "—")),
			String((player.equipment.equipped("bouclier") as Dictionary).get("item_id", "—")),
			bool((player.shield_profile() as Dictionary)["present"])])
	print("[%s] cibles rendues : %s" % [TAG, targets.keys()])
	print("[%s] épée à une main : cible de main gauche fournie = %s" % [TAG, has_left])
	_expect(has_left, "la main gauche a une cible même quand seule la droite sert")
	if not has_left:
		return
	var camera: Node3D = player.get("_camera")
	var grip: Vector3 = player.call("_grip_position", camera.global_basis)
	var left: Vector3 = targets["gauche"]
	# ÉCART AU CORPS : mesuré perpendiculairement à l'axe de visée. Un bras
	# collé donne une valeur proche de zéro ; un bras qui pend naturellement
	# s'en écarte de quelques dizaines de centimètres.
	var forward: Vector3 = -camera.global_basis.z
	var to_hand: Vector3 = left - grip
	var lateral: float = (to_hand - forward * to_hand.dot(forward)).length()
	print("[%s] écart latéral de la main gauche au corps : %.2f m" % [TAG, lateral])
	_expect(lateral > 0.12, "le bras gauche n'est pas collé au corps")

	# ET IL BOUGE. Deux mesures à des phases de marche différentes doivent
	# donner deux positions différentes — sans quoi le bras est simplement
	# décalé, ce qui n'est pas la même chose que vivant.
	# ON SIMULE LA MARCHE PAR L'API RÉELLE (`set_body_gait`), pas en écrivant
	# dans les champs du corps. À l'arrêt l'amplitude vaut zéro et le bras ne
	# balance pas — c'est le comportement voulu, et la première version de ce
	# test l'a pris pour un échec en oubliant de pousser l'amplitude.
	# PHASES AUX EXTRÊMES du balancement (±π/2 après le déphasage de π), et non
	# 0 et π : celles-ci sont les deux RACINES du sinus, donc deux positions
	# identiques. La première version du test comparait le bras à lui-même.
	player.call("set_body_gait", PI * 0.5, 1.0)
	for i in 60:
		player.hand_targets(HAND_RADIUS, OFFHAND_OFFSET, 1.0 / 60.0)
	var a: Vector3 = player.hand_targets(HAND_RADIUS, OFFHAND_OFFSET, 1.0 / 60.0).get("gauche", Vector3.ZERO)
	player.call("set_body_gait", PI * 1.5, 1.0)
	# Plusieurs frames : le ressort d'inertie amène la main à sa nouvelle cible,
	# il ne l'y téléporte pas.
	for i in 60:
		player.hand_targets(HAND_RADIUS, OFFHAND_OFFSET, 1.0 / 60.0)
	var b: Vector3 = player.hand_targets(HAND_RADIUS, OFFHAND_OFFSET, 1.0 / 60.0).get("gauche", Vector3.ZERO)
	print("[%s] balancement : %.3f m d'écart entre deux phases de marche" % [
			TAG, a.distance_to(b)])
	_expect(a.distance_to(b) > 0.02, "le bras gauche se balance avec la marche")


func _capture() -> void:
	if not can_capture():
		return
	camera.input_locked = true
	await wait_seconds(1.0)
	await screenshot("mains.png")
	print("[%s] capture : debug/mains.png" % TAG)


## UNE ARME À DEUX MAINS OCCUPE LES DEUX (2026-08-09, signalé en jeu : « on peut
## équiper 2 armes à 2 mains, ce qui est un problème évidemment »).
##
## `resolve_slot` ne regardait que les emplacements LIBRES : une arme à deux
## mains en arme_1 laissait arme_2 vide, donc disponible. On équipait ainsi deux
## espadons — quatre mains — sans que rien ne le signale.
##
## L'assertion porte sur ce qui compte VRAIMENT : non pas « le second équipement
## a été refusé », mais « il n'y a jamais deux armes portées quand l'une prend
## les deux mains », ET « celle qu'on déloge est revenue dans le sac ». Un refus
## qui ferait disparaître le bouclier passerait le premier test tout seul.
func _check_two_handed_exclusivity() -> void:
	var mats := {"bois": "chene", "minerai": "fer", "textile": "lin"}
	player.equipment.slots.clear()
	player.inventory.objects.clear()
	var two_handed_id := _two_handed_item_id()
	if two_handed_id == "":
		_expect(false, "aucune arme à deux mains dans le catalogue")
		return
	var first: Dictionary = ItemFactory.craft(two_handed_id, mats, 1.0)
	var second: Dictionary = ItemFactory.craft(two_handed_id, mats, 1.0)
	player.inventory.add_object(first)
	player.inventory.add_object(second)
	player.equip_instance(first)
	player.equip_instance(second)
	_expect(not player.equipment.equipped("arme_2").has("item_id"),
			"deux armes à deux mains : la main gauche reste libre (%s)"
			% [player.equipment.equipped("arme_2").get("item_id", "vide")])
	_expect(player.equipment.equipped("arme_1").has("item_id"),
			"la main forte tient bien une arme")
	# RIEN NE SE PERD : l'arme délogée est retournée au sac.
	_expect(player.inventory.objects.size() == 1,
			"l'arme délogée est revenue dans le sac (%d objet(s))"
			% player.inventory.objects.size())
	# ET RÉCIPROQUEMENT : un bouclier ne s'ajoute pas sur une main déjà prise.
	# ET RÉCIPROQUEMENT, un bouclier et une arme à deux mains ne COHABITENT pas.
	# L'assertion ne dit pas lequel des deux l'emporte — c'est un choix de
	# conception, et le figer ici interdirait de le changer sans casser la
	# sonde. Elle dit ce qui ne doit JAMAIS arriver : trois pièces pour deux
	# mains. (Le jeu fait céder l'arme : on garde le geste qu'on vient de faire.)
	var shield: Dictionary = ItemFactory.craft("ecu", mats, 1.0)
	if not shield.is_empty():
		player.inventory.add_object(shield)
		player.equip_instance(shield)
		var main_hand: Dictionary = player.equipment.equipped("arme_1")
		var off_hand: Dictionary = player.equipment.equipped("arme_2")
		_expect(not (Equipment.is_two_handed(main_hand) and not off_hand.is_empty()),
				"bouclier + arme à deux mains ne cohabitent pas (%s / %s)"
				% [main_hand.get("item_id", "vide"), off_hand.get("item_id", "vide")])


func _two_handed_item_id() -> String:
	for id: String in GameData.items:
		var item: Dictionary = GameData.items[id]
		if String(item.get("equip_slot", "")) == "arme" and int(item.get("hands", 1)) >= 2:
			return id
	return ""


## LE SLOT DE COMBAT MONTRE L'ARME ÉQUIPÉE (2026-08-09, signalé en jeu : « le
## slot combat est toujours à mains nues même quand on a des armes équipées »).
##
## L'assertion porte sur ce que l'AFFICHAGE reçoit — `HeldItem._source_entry` —
## et non sur `_equipped_weapon()`, qui était déjà correct : c'est précisément
## parce que la mécanique allait bien que le défaut a survécu. Vérifier la
## mécanique ici serait une assertion vraie pour la mauvaise raison.
func _check_combat_slot_shows_weapon() -> void:
	var held: Node = _find_held_item()
	if held == null:
		_expect(false, "HeldItem introuvable")
		return
	player.equipment.slots.clear()
	# Le slot de combat est sélectionné : c'est la posture qu'on teste.
	player.hotbar_bindings[player.COMBAT_SLOT] = {"kind": "combat"}
	player.active_hotbar = 0
	player.selected_slot = player.COMBAT_SLOT
	var bare: Dictionary = held.call("_source_entry")
	_expect(bare.is_empty(), "mains nues : rien en main (%s)" % [bare.get("kind", "vide")])
	var sword: Dictionary = ItemFactory.craft("epee_courte",
			{"bois": "chene", "minerai": "fer", "textile": "lin"}, 1.0)
	if sword.is_empty():
		_expect(false, "epee_courte introuvable")
		return
	player.equipment.slots["arme_1"] = sword
	var armed: Dictionary = held.call("_source_entry")
	_expect(String(armed.get("kind", "")) == "object"
			and String((armed.get("object", {}) as Dictionary).get("item_id", "")) == "epee_courte",
			"arme équipée : le modèle en main est l'épée (%s)"
			% [(armed.get("object", {}) as Dictionary).get("item_id", armed.get("kind", "vide"))])


func _find_held_item() -> Node:
	for node in main.find_children("HeldItem", "", true, false):
		if String(node.get("source")) == "hotbar":
			return node
	return null

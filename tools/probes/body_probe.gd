extends Probe
## Sonde `--probe-corps` (2026-07-28) — corps visible du joueur.
##
## Ce qu'elle prouve : le corps existe et porte le rig attendu, la tête est
## masquée pour SOI mais pas pour les autres, le corps suit la caméra sans
## jamais basculer avec le tangage, la colonne s'incline dans le bon sens et
## reste bridée, l'arme est portée par la MAIN, et un joueur distant reçoit
## bien position + regard.
##
## Elle vérifie aussi ce qui compte le plus : que rien de tout ça n'a touché
## la collision. `fly_camera.gd` reste l'autorité de position — si le corps
## avait été greffé dessus, c'est ici qu'on le verrait.

const TAG := "CORPS"


func run() -> void:
	await main.get_tree().process_frame
	await main.get_tree().process_frame
	var ok := true
	var body: Node3D = main.get("player_body")
	if body == null:
		print("[%s] AUCUN corps construit — modèle absent ou rig invalide" % TAG)
		finish(false, TAG)
		return

	ok = _check_rig(body) and ok
	ok = _check_local_head(body) and ok
	ok = _check_follow(body) and ok
	ok = _check_spine(body) and ok
	ok = await _check_weapon_in_hand(body) and ok
	ok = _check_remote_avatar() and ok
	ok = _check_arm_ik(body) and ok
	ok = await _check_leg_ik(body) and ok
	ok = _check_ik_culling(body) and ok
	ok = _check_skin(body) and ok
	ok = _check_gait(body) and ok
	ok = _check_creature_models() and ok
	ok = await _check_collision_untouched() and ok
	finish(ok, TAG)


func _check_skin(body: Node3D) -> bool:
	# Le .glb n'a AUCUNE texture et ses couleurs par sommet ne sont pas reprises
	# à l'import : sans peau procédurale le corps sort entièrement BLANC (c'est
	# ce que montraient les captures du 2026-07-28).
	var textured := 0
	var total := 0
	for mesh in _all_meshes(body):
		# Seuls les maillages DU CORPS (préfixe `mesh_`) : l'objet tenu est
		# aussi un MeshInstance3D sous ce nœud depuis qu'il pend à la main, et
		# il a légitimement son propre matériau.
		if not String(mesh.name).begins_with("mesh_"):
			continue
		total += 1
		var mat := mesh.material_override as StandardMaterial3D
		if mat != null and mat.albedo_texture != null:
			textured += 1
	var ok := total > 0 and textured == total
	print("[%s] peau procédurale : %d/%d maillages texturés : %s" % [
		TAG, textured, total, "OK" if ok else "ÉCHEC"])

	# Les calques doivent réellement DIFFÉRER, sinon la « palette » est un
	# décor : un pantalon de la couleur de la peau ne se verrait pas.
	var colors := {}
	for mesh in _all_meshes(body):
		var mat := mesh.material_override as StandardMaterial3D
		if mat != null and mat.albedo_texture != null:
			colors[mat.albedo_texture.get_image().get_pixel(0, 0)] = true
	var varied := colors.size() >= 3
	print("[%s] teintes distinctes (peau / haut / bas...) : %d : %s" % [
		TAG, colors.size(), "OK" if varied else "ÉCHEC"])
	return ok and varied


func _check_gait(body: Node3D) -> bool:
	# Cycle de marche piloté par la DISTANCE, pas par le temps : immobile, les
	# pieds ne doivent pas patiner.
	var skeleton: Skeleton3D = body.call("skeleton")
	var right := skeleton.find_bone("pied_droite")
	camera.rotation = Vector3.ZERO
	var start := camera.position

	# 1. À l'arrêt : la pose doit se stabiliser.
	for i in 40:
		body.call("follow_camera", camera, FlyCamera.EYE_HEIGHT)
		body.call("solve_legs")
	var still_a: Vector3 = skeleton.get_bone_global_pose(right).origin
	for i in 10:
		body.call("follow_camera", camera, FlyCamera.EYE_HEIGHT)
		body.call("solve_legs")
	var still_b: Vector3 = skeleton.get_bone_global_pose(right).origin
	var still_ok := still_a.distance_to(still_b) < 0.005
	print("[%s] immobile : pied stable (pas de patinage) déplacement=%.4f : %s" % [
		TAG, still_a.distance_to(still_b), "OK" if still_ok else "ÉCHEC"])

	# 2. En marchant : le pied doit bouger, et se LEVER à un moment du cycle.
	var lowest := 999.0
	var highest := -999.0
	for i in 60:
		camera.position += Vector3(0.06, 0.0, 0.0)   # ~ vitesse de marche
		body.call("follow_camera", camera, FlyCamera.EYE_HEIGHT)
		body.call("solve_legs")
		var foot: Vector3 = skeleton.get_bone_global_pose(right).origin
		lowest = minf(lowest, foot.y)
		highest = maxf(highest, foot.y)
	var lift := highest - lowest
	var walk_ok := lift > 0.05
	print("[%s] en marche : levée du pied sur le cycle = %.3f (> 0.05) : %s" % [
		TAG, lift, "OK" if walk_ok else "ÉCHEC"])
	camera.position = start
	return still_ok and walk_ok


func _check_creature_models() -> bool:
	# Toutes les créatures doivent porter un modèle (demande explicite : le
	# gabarit humanoïde sert de placeholder à TOUS les mobs pour l'instant).
	var missing: Array[String] = []
	for id: String in GameData.creatures:
		if String((GameData.creatures[id] as Dictionary).get("model", "")) == "":
			missing.append(id)
	var ok := missing.is_empty()
	print("[%s] créatures avec modèle : %d/%d%s : %s" % [
		TAG, GameData.creatures.size() - missing.size(), GameData.creatures.size(),
		"" if ok else " — sans modèle : " + str(missing.slice(0, 5)),
		"OK" if ok else "ÉCHEC"])

	# Et une créature réellement spawnée doit sortir texturée, pas blanche.
	var creature := CreatureManager.spawn("bandit", camera.position + Vector3(0.0, -3.0, 4.0))
	var painted := 0
	for mesh in _all_meshes(creature):
		if (mesh.material_override as StandardMaterial3D) != null:
			painted += 1
	var painted_ok := painted > 0
	print("[%s] créature spawnée : %d maillages peints (0 = blanche) : %s" % [
		TAG, painted, "OK" if painted_ok else "ÉCHEC"])

	# LES ZONES DE COUP DOIVENT COUVRIR LE CORPS AFFICHÉ. Un loup déclaré
	# `quadrupede` mais rendu avec le gabarit humanoïde avait ses zones au ras
	# du sol : la lame lui passait au travers. On vérifie donc que les zones
	# atteignent bien la hauteur du modèle, pas celle d'une fiche théorique.
	var zones: Array = creature.hitboxes()
	var zone_top := 0.0
	var has_head := false
	for zone: Dictionary in zones:
		zone_top = maxf(zone_top, float((zone["max"] as Vector3).y))
		if String(zone["id"]) == "tete":
			has_head = true
	var boxes_ok := zone_top > 1.5 and has_head
	print("[%s] zones du loup : %d, sommet à %.2f (modèle humanoïde = 2.0), tête présente=%s : %s" % [
		TAG, zones.size(), zone_top, has_head, "OK" if boxes_ok else "ÉCHEC"])

	# Corps ANIMÉ + barre de vie : la créature doit porter un vrai squelette
	# (donc pouvoir marcher), et sa barre n'apparaître qu'une fois blessée.
	var animated := false
	var bar_hidden_when_full := true
	for child in creature.get_children():
		if child.has_method("skeleton") and child.call("skeleton") != null:
			animated = true
	for node in _all_meshes(creature):
		if node.mesh is QuadMesh and node.get_parent().visible:
			bar_hidden_when_full = false
	print("[%s] créature : corps animé=%s · barre de vie cachée à pleine santé=%s : %s" % [
		TAG, animated, bar_hidden_when_full,
		"OK" if animated and bar_hidden_when_full else "ÉCHEC"])

	# Blessée, la barre doit apparaître.
	creature.health = creature.health_max * 0.4
	creature.call("_update_health_bar", creature.position)
	var bar_shown := false
	for node in _all_meshes(creature):
		if node.mesh is QuadMesh and node.get_parent().visible:
			bar_shown = true
	print("[%s] créature à 40 %% de PV : barre affichée=%s : %s" % [
		TAG, bar_shown, "OK" if bar_shown else "ÉCHEC"])
	# GESTE D'ATTAQUE VISIBLE. La télégraphie existait depuis le début, mais
	# rien ne la montrait : le joueur recevait un signal qu'il ne pouvait pas
	# percevoir. Le bras armé est ce qui rend la parade directionnelle jouable.
	var body: Node3D = null
	for child in creature.get_children():
		if child.has_method("set_combat_pose"):
			body = child
	var pose_ok := false
	if body != null:
		var skeleton: Skeleton3D = body.call("skeleton")
		var hand := skeleton.find_bone("main_droite")
		body.call("set_combat_pose", MeleeAttack.Direction.OVERHEAD, 0.0, "windup")
		var at_rest: Vector3 = skeleton.get_bone_global_pose(hand).origin
		body.call("set_combat_pose", MeleeAttack.Direction.OVERHEAD, 1.0, "windup")
		var armed: Vector3 = skeleton.get_bone_global_pose(hand).origin
		body.call("set_combat_pose", MeleeAttack.Direction.OVERHEAD, 1.0, "strike")
		var struck: Vector3 = skeleton.get_bone_global_pose(hand).origin
		# Trois positions DISTINCTES : sans ça le « geste » ne serait qu'une pose
		# figée, et l'adversaire n'aurait rien à lire.
		pose_ok = at_rest.distance_to(armed) > 0.15 and armed.distance_to(struck) > 0.15
		print("[%s] geste d'attaque : port→armé %.2f · armé→frappe %.2f (> 0.15) : %s" % [
			TAG, at_rest.distance_to(armed), armed.distance_to(struck),
			"OK" if pose_ok else "ÉCHEC"])
	else:
		print("[%s] geste d'attaque : aucun corps posable : ÉCHEC" % TAG)
	var creature_ok := boxes_ok and animated and bar_hidden_when_full and bar_shown and pose_ok
	CreatureManager.creatures.erase(creature)
	creature.queue_free()

	# COÛT DU SPAWN — la régression signalée en jeu le 2026-07-28 sur la
	# machine cible : « [TICK] 163.8 ms — entités 163.8 » puis 27,8 ms. Chaque
	# créature instanciait un modèle à 18 maillages ET fabriquait 4 textures
	# (donc 4 uploads GPU). Modèles préchargés + cache de matériaux partagé :
	# ce que cette mesure garde sous surveillance.
	# MESURE ROBUSTE : médiane de spawns INDIVIDUELS, après échauffement.
	# La première version prenait la moyenne d'une rafale de 10 : elle avalait
	# les coûts uniques (premier chargement, premières allocations) et se
	# faisait polluer par tout ce qui tournait à côté. Relevés successifs sans
	# le moindre changement de code : 8,3 · 11,3 · 7,2 · 45,0 · 12,2 ms — un
	# facteur 6. Une mesure aussi instable ne peut pas servir de garde-fou.
	# La médiane écarte les valeurs aberrantes ; l'échauffement écarte l'unique.
	var spawns: Array[Node] = []
	for i in 3:
		var warm := CreatureManager.spawn("bandit", camera.position + Vector3(float(i), -3.0, 6.0))
		if warm != null:
			spawns.append(warm)
	var samples: Array[float] = []
	for i in 12:
		var t0 := Time.get_ticks_usec()
		var c := CreatureManager.spawn("bandit", camera.position + Vector3(float(i), -3.0, 8.0))
		if c == null:
			break
		samples.append(float(Time.get_ticks_usec() - t0) / 1000.0)
		spawns.append(c)
	samples.sort()
	var per_spawn := samples[samples.size() / 2] if not samples.is_empty() else 0.0
	for c in spawns:
		CreatureManager.creatures.erase(c)
		c.queue_free()
	# Instancier un modèle riggé de 18 maillages coûte quelques millisecondes :
	# c'est irréductible sans mise en pool. Ce qui est garanti, c'est qu'un
	# tick n'en paie JAMAIS plus d'un (SPAWNS_PER_TICK) — le seuil vérifie donc
	# qu'un spawn tient confortablement dans le budget de 16 ms, pas qu'il est
	# gratuit. Les meutes sont étalées sur plusieurs ticks.
	# 12 ms et non 10 : meme en MEDIANE, la mesure va de 4,2 a 10,6 ms selon la
	# charge de la machine (relevés du 2026-07-28). Le seuil est calé sur la
	# PRECISION REELLE de la mesure — il attrape un doublement, pas du bruit.
	# Ce qui est garanti reste : un tick ne paie JAMAIS plus d'un spawn.
	var spawn_ok := per_spawn < 12.0
	print("[%s] coût d'un spawn (MÉDIANE de %d) : %.2f ms (< 12 ms ; 1/tick, budget 16) : %s" % [
		TAG, samples.size(), per_spawn, "OK" if spawn_ok else "ÉCHEC"])
	return ok and painted_ok and spawn_ok and creature_ok


func _check_arm_ik(body: Node3D) -> bool:
	# LE test qui compte pour l'IK : après résolution, la MAIN doit réellement
	# se trouver là où on l'a envoyée. C'est le seul juge des signes et des
	# conventions d'axes — une erreur de signe donne un solveur qui « marche »
	# mais place le bras à l'opposé.
	var skeleton: Skeleton3D = body.call("skeleton")
	var hand := skeleton.find_bone("main_droite")
	var shoulder := skeleton.find_bone("bras_droit")
	if hand < 0 or shoulder < 0:
		print("[%s] chaîne de bras absente" % TAG)
		return false

	var ok := true
	var worst := 0.0
	# Plusieurs cibles atteignables autour de l'épaule, pour ne pas valider un
	# cas particulier heureux.
	var shoulder_world: Vector3 = skeleton.global_transform * skeleton.get_bone_global_pose(shoulder).origin
	for offset: Vector3 in [
		Vector3(0.15, -0.30, -0.35), Vector3(0.35, -0.10, -0.20),
		Vector3(0.05, -0.45, -0.10), Vector3(0.25, 0.10, -0.30),
	]:
		var target := shoulder_world + offset
		body.call("solve_arm", "droite", target)
		var reached: Vector3 = skeleton.global_transform * skeleton.get_bone_global_pose(hand).origin
		var error := reached.distance_to(target)
		worst = maxf(worst, error)
		ok = ok and error < 0.02
	print("[%s] IK bras : erreur max de l'effecteur = %.1f mm sur 4 cibles (< 20 mm) : %s" % [
		TAG, worst * 1000.0, "OK" if ok else "ÉCHEC"])

	# PAS DE DÉFORMATION. Vérifier la position de la main ne suffit PAS : une
	# base non orthonormée place l'effecteur au bon endroit tout en ÉTIRANT la
	# géométrie — ce qui donne à l'écran de grandes plaques plates au lieu d'un
	# bras (constaté en jeu le 2026-07-28). On contrôle donc que chaque os de
	# la chaîne garde une échelle unitaire et une base directe.
	var scale_ok := true
	var worst_scale := 0.0
	for bone_name: String in ["bras_droit", "avantbras_droit", "main_droite",
			"cuisse_droite", "mollet_droite", "pied_droite"]:
		var index := skeleton.find_bone(bone_name)
		if index < 0:
			continue
		var pose_basis: Basis = skeleton.get_bone_global_pose(index).basis
		var scales := pose_basis.get_scale()
		for axis in 3:
			worst_scale = maxf(worst_scale, absf(scales[axis] - 1.0))
		if absf(scales.x - 1.0) > 0.02 or absf(scales.y - 1.0) > 0.02 \
				or absf(scales.z - 1.0) > 0.02 or pose_basis.determinant() < 0.0:
			scale_ok = false
	print("[%s] os non déformés : écart d'échelle max %.4f (< 0.02), bases directes : %s" % [
		TAG, worst_scale, "OK" if scale_ok else "ÉCHEC"])
	ok = ok and scale_ok

	# SENS DE FLEXION. Le test de précision de l'effecteur ne peut PAS l'attraper :
	# les deux signes du solveur placent la main exactement sur la cible, ils ne
	# diffèrent que par le côté où se plie l'articulation. D'où ce contrôle
	# direct — c'est le défaut « les bras se plient dans le mauvais sens »
	# signalé le 2026-07-28, invisible à toutes les assertions précédentes.
	var elbow_ok := true
	for pole: Vector3 in [Vector3(0.7, -0.2, 0.6), Vector3(-0.7, -0.2, 0.6), Vector3(0.0, 0.0, -1.0)]:
		var root := Vector3.ZERO
		var target := Vector3(0.0, -0.45, -0.30)
		var solved := TwoBoneIK.solve(root, target, 0.34, 0.34, pole)
		# Le coude doit être DU CÔTÉ du pôle par rapport à la corde racine→cible.
		var chord := (target - root).normalized()
		var elbow: Vector3 = solved["elbow"]
		var lateral := elbow - root - chord * (elbow - root).dot(chord)
		var aligned := lateral.normalized().dot(pole.normalized())
		elbow_ok = elbow_ok and aligned > 0.3
		print("[%s]   pôle %-18s -> coude aligné à %.2f (doit être > 0.30)" % [
			TAG, str(pole), aligned])
	print("[%s] articulations pliées DU CÔTÉ du pôle : %s" % [
		TAG, "OK" if elbow_ok else "ÉCHEC"])
	ok = ok and elbow_ok

	# Cible HORS D'ATTEINTE : le bras doit se tendre au maximum, pas produire
	# de NAN (un acos hors domaine contaminerait tout le squelette).
	var far := shoulder_world + Vector3(0.0, 0.0, -50.0)
	body.call("solve_arm", "droite", far)
	var stretched: Vector3 = skeleton.global_transform * skeleton.get_bone_global_pose(hand).origin
	var finite := is_finite(stretched.x) and is_finite(stretched.y) and is_finite(stretched.z)
	print("[%s] cible hors d'atteinte : pose finie (pas de NAN) = %s : %s" % [
		TAG, finite, "OK" if finite else "ÉCHEC"])
	return ok and finite


func _check_leg_ik(body: Node3D) -> bool:
	# Ground IK : sur une MARCHE d'un bloc, un pied doit se poser plus haut que
	# l'autre. C'est le défaut le plus visible d'un personnage dans un monde
	# voxel — un pied qui flotte pendant que l'autre s'enfonce.
	var stone: int = GameData.material_runtime_ids.get("pierre", 1)
	var base := Vector3i(int(camera.position.x) + 20, floori(camera.position.y) - 10, int(camera.position.z))
	# Zone dégagée d'abord : le décor est bâti dans le terrain RÉEL, dont le
	# contenu varie avec le point de spawn (monde sauvegardé rechargé). Sans ce
	# nettoyage, un bloc de terrain fausse la mesure de hauteur des pieds.
	for dx in range(-3, 4):
		for dz in range(-3, 4):
			for dy in range(0, 6):
				WorldManager.set_block(Vector3i(base.x + dx, base.y + dy, base.z + dz), 0)
	for dx in range(-2, 3):
		for dz in range(-2, 3):
			WorldManager.set_block(Vector3i(base.x + dx, base.y, base.z + dz), stone)
	# Marche d'un bloc sous la MOITIÉ du corps (côté +X).
	for dz in range(-2, 3):
		for dx in range(1, 3):
			WorldManager.set_block(Vector3i(base.x + dx, base.y + 1, base.z + dz), stone)
	await main.get_tree().process_frame
	# Le décor doit exister, sinon le test ne teste rien (leçon du 2026-07-28).
	var floor_ok: bool = WorldManager.block_at_world(Vector3i(base.x, base.y, base.z)) == stone
	var step_ok: bool = WorldManager.block_at_world(Vector3i(base.x + 1, base.y + 1, base.z)) == stone
	print("[%s] décor jambes : sol y=%d posé=%s · marche y=%d posée=%s" % [
		TAG, base.y, floor_ok, base.y + 1, step_ok])
	if not (floor_ok and step_ok):
		return false

	camera.rotation = Vector3.ZERO
	camera.position = Vector3(float(base.x) + 1.0, float(base.y + 2) + FlyCamera.EYE_HEIGHT, float(base.z) + 0.5)
	# L'abaissement du bassin converge en douceur (il ne doit pas sauter d'une
	# frame à l'autre) : on simule assez d'appels pour qu'il se stabilise.
	for i in 40:
		body.call("follow_camera", camera, FlyCamera.EYE_HEIGHT)
		body.call("solve_legs")

	var skeleton: Skeleton3D = body.call("skeleton")
	var right := skeleton.find_bone("pied_droite")
	var left := skeleton.find_bone("pied_gauche")
	var right_y: float = (skeleton.global_transform * skeleton.get_bone_global_pose(right).origin).y
	var left_y: float = (skeleton.global_transform * skeleton.get_bone_global_pose(left).origin).y
	# Diagnostic : ce que l'IK a VU sous chaque hanche. Sans ça, un écart nul
	# ne dit pas si le solveur est faux ou si la requête de sol n'a rien trouvé.
	for side: String in ["droite", "gauche"]:
		var hip := skeleton.find_bone("cuisse_" + side)
		var hip_world: Vector3 = skeleton.global_transform * skeleton.get_bone_global_pose(hip).origin
		var surface: float = body.call("_surface_under", hip_world)
		print("[%s]   hanche %s à (%.2f, %.2f, %.2f) → sol détecté : %s" % [
			TAG, side, hip_world.x, hip_world.y, hip_world.z,
			"aucun" if is_nan(surface) else "%.2f" % surface])
	var split := absf(right_y - left_y)
	var ok := split > 0.3

	# JAMBE AU-DESSUS DU VIDE : elle doit PENDRE, tendue vers le bas, et non
	# garder sa pose de repos comme si elle prenait appui sur un sol inexistant
	# (« flottement » signalé au bord d'un bloc, 2026-07-28). On retire le sol
	# sous le côté gauche et on vérifie que ce pied descend nettement.
	for dz in range(-3, 4):
		for dy in range(-1, 3):
			WorldManager.set_block(Vector3i(base.x - 2, base.y + dy, base.z + dz), 0)
			WorldManager.set_block(Vector3i(base.x - 3, base.y + dy, base.z + dz), 0)
	camera.position = Vector3(float(base.x) - 1.6, float(base.y + 2) + FlyCamera.EYE_HEIGHT, float(base.z) + 0.5)
	for i in 40:
		body.call("follow_camera", camera, FlyCamera.EYE_HEIGHT, 1.0 / 60.0)
		body.call("solve_legs")
	var void_left: float = (skeleton.global_transform * skeleton.get_bone_global_pose(left).origin).y
	var void_right: float = (skeleton.global_transform * skeleton.get_bone_global_pose(right).origin).y
	var hip: float = (skeleton.global_transform * skeleton.get_bone_global_pose(
		skeleton.find_bone("cuisse_gauche")).origin).y
	# Le pied au-dessus du vide doit être BAS sous la hanche : une jambe qui
	# pend est tendue, pas repliée.
	var dangle := hip - void_left
	var dangle_ok := dangle > 0.55
	print("[%s] jambe au-dessus du vide : pend de %.2f sous la hanche (> 0.55) · appui à %.2f : %s" % [
		TAG, dangle, void_right, "OK" if dangle_ok else "ÉCHEC"])
	ok = ok and dangle_ok
	print("[%s] IK jambes sur une marche : pieds à y=%.2f et %.2f (écart %.2f > 0.30) : %s" % [
		TAG, right_y, left_y, split, "OK" if ok else "ÉCHEC"])
	return ok


func _check_ik_culling(body: Node3D) -> bool:
	# Le culling est la condition de tenue sur la machine cible : l'IK est bon
	# marché à l'unité, ruineuse multipliée par une ville entière.
	var near: bool = body.call("update_ik_culling", body.global_position + Vector3(0.0, 0.0, 5.0))
	var far: bool = body.call("update_ik_culling", body.global_position + Vector3(0.0, 0.0, 40.0))
	var ok := near and not far
	print("[%s] culling IK : active à 5 m=%s, coupée à 40 m=%s : %s" % [
		TAG, near, far, "OK" if ok else "ÉCHEC"])
	body.call("update_ik_culling", body.global_position)  # réactivée pour la suite
	return ok


func _check_rig(body: Node3D) -> bool:
	var skeleton: Skeleton3D = body.call("skeleton")
	var meshes: Array = body.call("mesh_names")
	var bones := skeleton.get_bone_count() if skeleton != null else 0
	var ok: bool = skeleton != null and bones >= 20 and meshes.size() >= 15
	print("[%s] rig : %d os, %d maillages (attendu ≥20 / ≥15) : %s" % [
		TAG, bones, meshes.size(), "OK" if ok else "ÉCHEC"])
	# L'os de main est la condition pour porter une arme.
	var hand_bone: bool = skeleton != null and skeleton.find_bone("attach_arme") >= 0
	print("[%s] os « attach_arme » présent : %s" % [TAG, "OK" if hand_bone else "ÉCHEC"])
	return ok and hand_bone


func _check_local_head(body: Node3D) -> bool:
	# La caméra est DANS le crâne : sans masquage on voit l'intérieur de son
	# propre visage. C'est la raison d'être de la contrainte « tête = maillage
	# séparé » imposée au rig.
	# LISTE BLANCHE : uniquement les jambes et le(s) bras utilisé(s). Tout le
	# reste (tête, cou, torse, bassin) est masqué pour soi — à moins d'un mètre
	# de l'objectif ces pièces bouchent la vue au lieu de se lire comme un corps.
	body.call("set_local_limbs", false)   # arme à une main
	var must_see := ["mesh_cuisse_droite", "mesh_mollet_droite", "mesh_pied_droite",
		"mesh_cuisse_gauche", "mesh_pied_gauche",
		"mesh_bras_droit", "mesh_avantbras_droit", "mesh_main_droite"]
	var must_hide := ["mesh_tete", "mesh_cheveux", "mesh_cou",
		"mesh_torse_haut", "mesh_torse_bas", "mesh_bassin",
		"mesh_bras_gauche", "mesh_main_gauche"]
	var seen := 0
	var hidden := 0
	for child in _all_meshes(body):
		if child.name in must_see and child.visible:
			seen += 1
		if child.name in must_hide and not child.visible:
			hidden += 1
	var ok := seen == must_see.size() and hidden == must_hide.size()
	print("[%s] arme à UNE main : %d/%d visibles (jambes + bras droit), %d/%d masqués : %s" % [
		TAG, seen, must_see.size(), hidden, must_hide.size(), "OK" if ok else "ÉCHEC"])

	# Arme à DEUX mains : la gauche doit réapparaître, et elle seule.
	body.call("set_local_limbs", true)
	var left_shown := 0
	var torso_still_hidden := true
	for child in _all_meshes(body):
		if child.name in ["mesh_bras_gauche", "mesh_avantbras_gauche", "mesh_main_gauche"] and child.visible:
			left_shown += 1
		if child.name in ["mesh_torse_haut", "mesh_bassin"] and child.visible:
			torso_still_hidden = false
	var two_ok := left_shown == 3 and torso_still_hidden
	print("[%s] arme à DEUX mains : bras gauche rendu (%d/3), torse toujours masqué=%s : %s" % [
		TAG, left_shown, torso_still_hidden, "OK" if two_ok else "ÉCHEC"])
	body.call("set_local_limbs", false)
	return ok and two_ok


func _check_follow(body: Node3D) -> bool:
	# Le corps suit la caméra : PIEDS sous l'œil, LACET repris, TANGAGE jamais
	# appliqué au corps entier (sinon le personnage basculerait en bloc en
	# regardant ses pieds).
	camera.rotation = Vector3(deg_to_rad(-35.0), deg_to_rad(50.0), 0.0)
	camera.position = Vector3(120.0, 80.0, -60.0)
	body.call("follow_camera", camera, FlyCamera.EYE_HEIGHT)

	var expected_feet := camera.global_position - Vector3(0.0, FlyCamera.EYE_HEIGHT, 0.0)
	var feet_ok := body.global_position.distance_to(expected_feet) < 0.001
	print("[%s] pieds à %.2f sous l'œil (attendu %.2f) : %s" % [
		TAG, camera.global_position.y - body.global_position.y, FlyCamera.EYE_HEIGHT,
		"OK" if feet_ok else "ÉCHEC"])

	var yaw_ok := is_equal_approx(body.rotation.y, camera.rotation.y)
	var pitch_ok := is_zero_approx(body.rotation.x)
	print("[%s] lacet repris=%s · tangage NON appliqué au corps=%s : %s" % [
		TAG, yaw_ok, pitch_ok, "OK" if yaw_ok and pitch_ok else "ÉCHEC"])
	return feet_ok and yaw_ok and pitch_ok


func _check_spine(body: Node3D) -> bool:
	var skeleton: Skeleton3D = body.call("skeleton")
	var spine := skeleton.find_bone("colonne_1")
	if spine < 0:
		print("[%s] colonne introuvable" % TAG)
		return false

	# Regard vers le BAS : le buste doit s'incliner vers l'AVANT (-Z), donc
	# une rotation NÉGATIVE autour de X.
	camera.rotation = Vector3(deg_to_rad(-50.0), 0.0, 0.0)
	body.call("follow_camera", camera, FlyCamera.EYE_HEIGHT)
	var down_angle := skeleton.get_bone_pose_rotation(spine).get_euler().x

	camera.rotation = Vector3(deg_to_rad(50.0), 0.0, 0.0)
	body.call("follow_camera", camera, FlyCamera.EYE_HEIGHT)
	var up_angle := skeleton.get_bone_pose_rotation(spine).get_euler().x

	var sign_ok := down_angle < 0.0 and up_angle > 0.0
	print("[%s] colonne : regard bas=%.1f° regard haut=%.1f° (bas doit être négatif) : %s" % [
		TAG, rad_to_deg(down_angle), rad_to_deg(up_angle), "OK" if sign_ok else "ÉCHEC"])

	# Bridage : même en regardant à la verticale, le personnage ne doit pas se
	# casser le dos (le GDD demande explicitement de brider cet angle).
	camera.rotation = Vector3(deg_to_rad(-89.0), 0.0, 0.0)
	body.call("follow_camera", camera, FlyCamera.EYE_HEIGHT)
	var extreme := absf(skeleton.get_bone_pose_rotation(spine).get_euler().x)
	var clamped_ok := extreme <= deg_to_rad(31.0)
	print("[%s] regard à la verticale : colonne bridée à %.1f° par os (≤ 31°) : %s" % [
		TAG, rad_to_deg(extreme), "OK" if clamped_ok else "ÉCHEC"])
	camera.rotation = Vector3.ZERO
	return sign_ok and clamped_ok


func _check_weapon_in_hand(body: Node3D) -> bool:
	# L'objet tenu doit descendre de l'os de la MAIN, plus de la caméra : avec
	# de vrais bras, un viewmodel flottant devant l'objectif se verrait
	# immédiatement comme faux.
	var hand: Node3D = body.call("hand_attachment")
	if hand == null:
		print("[%s] aucun point d'accrochage de main" % TAG)
		return false
	var held: Node = null
	for child in hand.get_children():
		if child.name == "HeldItem":
			held = child
	var ok := held != null
	print("[%s] objet en main accroché à l'os « %s » : %s" % [
		TAG, hand.bone_name, "OK" if ok else "ÉCHEC"])
	var not_on_camera := camera.get_node_or_null("HeldItem") == null
	print("[%s] plus de viewmodel accroché à la caméra : %s" % [
		TAG, "OK" if not_on_camera else "ÉCHEC"])

	# L'ASSEMBLAGE EST-IL RÉELLEMENT CONSTRUIT ? On appelle la fonction
	# d'assemblage DIRECTEMENT plutôt que de passer par la hotbar : la version
	# précédente liait une épée à un emplacement, puis mesurait... la PIOCHE du
	# kit de départ (2026-07-28). Un test qui dépend de la plomberie d'inventaire
	# pour vérifier de la géométrie teste la mauvaise chose.
	var sword := ItemFactory.craft("epee", {"bois": "chene", "minerai": "fer"}, 1.0)
	var bench: MeshInstance3D = preload("res://scenes/entities/held_item.gd").new()
	main.add_child(bench)
	var assembled: bool = bench.call("_build_part_weapon",
		GameData.items["epee"], sword["materials"])
	var parts_built := 0
	for node in _all_meshes(bench):
		if node.mesh != null and node.visible:
			parts_built += 1
	var weapon_ok := assembled and parts_built >= 2
	print("[%s] épée assemblée depuis ses pièces : %s, %d maillage(s) (manche + tête) : %s" % [
		TAG, assembled, parts_built, "OK" if weapon_ok else "ÉCHEC"])

	# La TÊTE doit être posée au sommet du manche, pas à l'origine : c'est ce
	# décalage qui fait une arme et non deux morceaux superposés.
	var heights: Array[float] = []
	for node in _all_meshes(bench):
		if node.mesh != null:
			heights.append(node.global_position.y - bench.global_position.y)
	heights.sort()
	var stacked: bool = heights.size() >= 2 and (heights[-1] - heights[0]) > 0.2
	print("[%s] tête greffée au sommet du manche (écart %.2f > 0.20) : %s" % [
		TAG, (heights[-1] - heights[0]) if heights.size() >= 2 else 0.0,
		"OK" if stacked else "ÉCHEC"])
	bench.queue_free()
	weapon_ok = weapon_ok and stacked
	return ok and not_on_camera and weapon_ok


func _check_remote_avatar() -> bool:
	# Un joueur distant est LE MÊME corps, tête VISIBLE, piloté par la pose
	# réseau (position + regard). Instancié directement : monter une vraie
	# session ENet n'apporterait rien à ce qui est vérifié ici.
	var remote: Node3D = preload("res://scenes/entities/player_body.gd").new()
	main.add_child(remote)
	if not remote.setup(false):
		print("[%s] avatar distant : construction impossible" % TAG)
		remote.queue_free()
		return false
	var head_visible := false
	for child in _all_meshes(remote):
		if child.name == "mesh_tete":
			head_visible = child.visible
	print("[%s] avatar distant : tête VISIBLE (contrairement au local) : %s" % [
		TAG, "OK" if head_visible else "ÉCHEC"])

	remote.call("apply_remote_pose", Vector3(10.0, 20.0, 30.0), deg_to_rad(90.0), deg_to_rad(-30.0))
	var pose_ok := remote.global_position.distance_to(Vector3(10.0, 20.0, 30.0)) < 0.001 \
		and is_equal_approx(remote.rotation.y, deg_to_rad(90.0))
	var skeleton: Skeleton3D = remote.call("skeleton")
	var spine := skeleton.find_bone("colonne_1")
	var remote_pitch := skeleton.get_bone_pose_rotation(spine).get_euler().x if spine >= 0 else 0.0
	var pitch_ok := remote_pitch < 0.0   # regard vers le bas → buste en avant
	print("[%s] pose réseau : position+lacet=%s · tangage transmis au buste=%s : %s" % [
		TAG, pose_ok, pitch_ok, "OK" if pose_ok and pitch_ok else "ÉCHEC"])
	remote.queue_free()
	return head_visible and pose_ok and pitch_ok


func _check_collision_untouched() -> bool:
	# LE POINT LE PLUS IMPORTANT DE CETTE SONDE. Le corps ne doit avoir aucune
	# influence sur la position ni la collision : la caméra reste l'autorité.
	# Si le corps avait été greffé sur elle, ou s'il introduisait un décalage
	# visuel dans `position.y`, on rouvrirait la classe de bugs de dérive
	# flottante corrigée le 2026-07-21.
	var stone: int = GameData.material_runtime_ids.get("pierre", 1)
	var base := Vector3i(int(camera.position.x) + 12, floori(camera.position.y) - 10, int(camera.position.z))
	for dx in range(-2, 3):
		for dz in range(-2, 3):
			WorldManager.set_block(Vector3i(base.x + dx, base.y, base.z + dz), stone)
	var feet := float(base.y + 1)
	camera.position = Vector3(float(base.x) + 0.5, feet + FlyCamera.EYE_HEIGHT, float(base.z) + 0.5)
	var before := camera.position.y
	# Plusieurs frames de suivi du corps : si quoi que ce soit s'écrivait en
	# retour sur la caméra, la dérive apparaîtrait ici.
	for i in 30:
		await main.get_tree().process_frame
	var drift := absf(camera.position.y - before)
	var ok := drift < 0.001
	print("[%s] caméra après 30 frames avec corps : dérive=%.6f (attendu 0) : %s" % [
		TAG, drift, "OK" if ok else "ÉCHEC"])
	var still_blocked: bool = camera.call("_body_blocked_at",
		camera.position.x, camera.position.z, feet - 1.0)
	print("[%s] collision toujours opérante sous les pieds : %s" % [
		TAG, "OK" if still_blocked else "ÉCHEC"])
	return ok and still_blocked


func _all_meshes(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		out.append_array(_all_meshes(child))
	return out

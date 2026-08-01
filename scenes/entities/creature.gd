extends Node3D
## Scène GÉNÉRIQUE pour tout être vivant (D.2/12) : monstres, PNJ, animaux —
## une seule scène, configurée entièrement depuis un JSON de créature au
## spawn. AUCUNE logique de gameplay dans _process (E.1) : le mouvement et
## le combat avancent par tick ; _process ne fait qu'interpoler l'affichage.
## Visuel provisoire : capsule colorée par race (les parties .vox assemblées
## par points d'attache, 12.1, arrivent avec la bibliothèque de parties).

const AGGRO_RANGE := 14.0
## Malus de vision nocturne (E.21) : « le joueur voit moins loin, MAIS les
## ennemis aussi ». Le rayon d'agression est réduit la nuit — la nuit devient
## à la fois plus dangereuse (plus de spawns) et plus discrète (on peut
## passer à côté d'un prédateur sans le réveiller).
const AGGRO_NIGHT_FACTOR := 0.6
## Distance à laquelle une bête craintive (profil "fuit") s'écarte.
const FLEE_RANGE := 10.0
const WANDER_RADIUS := 4.0

var creature_id: String
var display_name_key: String
var stats: Dictionary       # base_stats (B.5) : sante, force, volonte, vitesse...
var ai_profile: String
var combat: Dictionary      # { functionality, modules } — vide si pacifique
## Dimension d'appartenance (3.5, 2026-07-21) : posée au spawn par
## CreatureManager. Une créature hors de la dimension ACTIVE est gelée
## (pas de tick) et invisible — un boss de donjon n'existe que dedans.
var dimension: StringName = &"overworld"

var health_max: float
var health: float
var weapon_level := 0       # Niveau de compétence de l'arme naturelle (0 = débutant).

var logical_position: Vector3
var _home: Vector3
var _attack_cooldown_ticks := 0
## Ticks restants avant que l'attaque DÉCLARÉE ne parte réellement (wind-up).
## 0 = aucune attaque en préparation.
var _windup_ticks := 0
## Direction de l'attaque en cours (MeleeAttack.Direction). Tiree a la
## DECLARATION et publiee par la telegraphie : le joueur doit pouvoir la
## lire pendant le wind-up pour orienter sa parade.
var attack_direction: int = 0
## PHASE VISUELLE de l'attaque ("" / "windup" / "strike" / "recover") et
## son avancement. L'IA avance au TICK (10 Hz) mais le geste doit se lire à
## la frame : la phase porte donc sa propre horloge en secondes, calée sur
## la durée du wind-up décidée au tick.
var _pose_phase := ""
var _pose_time := 0.0
var _pose_duration := 0.0
var _wander_target: Vector3
var _mesh: MeshInstance3D
## Bête sauvage ayant reçu un coup : passe hostile pour de bon (voir provoke).
var _provoked := false

# --- Vie sociale (3.4/8.4/14.2) ----------------------------------------------
#
# Ces champs sont portés par TOUTE créature, pas par une sous-classe « PNJ ».
# C'est le principe fondateur du GDD (12.1), rappelé par l'auteur : « un
# sanglier et un marchand sont faits de la même façon ». Un sanglier les laisse
# simplement vides — il n'a ni métier ni domicile, et le code qui les lit
# n'a donc aucun test d'espèce à faire.
#
# La tentation permanente sera de créer une classe NPC pour « ranger » ces
# quatre variables. Ce serait rouvrir la séparation monstre/PNJ que le GDD
# ferme explicitement, et il faudrait ensuite dupliquer le combat, le loot,
# l'inventaire et l'IA des deux côtés.

## Cellule du village d'appartenance, ou Vector2i.MAX si la créature est libre.
## Aucune relation n'est stockée ICI : elle vivrait sur une instance qui
## disparaît dès que le joueur s'éloigne. Elle appartient à `Player.reputation`,
## sous `social_key`.
var village_cell := Vector2i(1 << 30, 1 << 30)
## Poste de travail (VillagePopulation.JOBS), "" si aucun.
var job := ""
## Domicile et lieu de travail en coordonnées monde. Vector3.INF = aucun.
var home_building := Vector3.INF
var work_place := Vector3.INF
## Clé STABLE de cet habitant dans la réputation du joueur (Reputation).
## Vide pour une bête ou un civil hors village : ils n'ont pas d'avis personnel,
## seulement celui de leur race et du monde sur le joueur.
var social_key := ""
## Race, recopiée des données — la réputation raciale s'y adosse.
var race_id := ""
## Royaume dont dépend son village (14.4), "" en terre sauvage. Recopié au
## peuplement plutôt que recalculé : la requête est mise en cache mais reste
## bien plus chère qu'une lecture de champ, et un civil la ferait à chaque tick.
var kingdom_id := ""
## Rang dans le roster de son village, ou -1. C'est LUI qu'on inscrit au registre
## des morts : la position dans le roster est stable, l'instance ne l'est pas.
var roster_index := -1


## La créature a-t-elle une vie de village ? Un seul test, partout : sans lui,
## chaque appelant réinventerait « est-ce un PNJ » avec une règle légèrement
## différente.
func is_resident() -> bool:
	return job != "" and home_building != Vector3.INF


## Configure l'instance depuis les données GameData (D.2 : « se configure
## entièrement depuis un JSON de créature au spawn »).
func setup(id: String, spawn_position: Vector3) -> void:
	creature_id = id
	var data: Dictionary = GameData.creatures[id]
	display_name_key = data["name_key"]
	stats = data["base_stats"].duplicate()
	ai_profile = data["ai_profile"]
	race_id = String(data.get("race", ""))
	combat = data.get("combat", {})
	health_max = float(stats.get("sante", 10))
	health = health_max
	logical_position = spawn_position
	_home = spawn_position
	_wander_target = spawn_position
	position = spawn_position
	_resolve_hitboxes(data)
	_build_visual(data)


## Modèle Blockbench (12.1, amendé 2026-07-26) : une créature porte un `model`
## glTF/.glb complet et riggé. Tant qu'aucun modèle n'est fourni, on retombe
## sur la capsule colorée provisoire — le jour où un .glb est posé dans
## models/creatures/ et référencé en données, il s'affiche sans toucher au code.
## Décalage des PIEDS par rapport à `logical_position`. La convention héritée
## (`_ground_height`) place la position logique à `indice_de_bloc + 0,5`, alors
## que le sommet du bloc — donc le sol visible — est à `indice + 1`. Sans ce
## demi-bloc, toute créature apparaît enterrée jusqu'aux mollets.
const FEET_OFFSET := 0.5

## Corps ANIMÉ (2026-07-28) : une créature utilise le MÊME `PlayerBody` que le
## joueur, donc la même peau procédurale, la même IK de jambes et la même
## marche procédurale. Un seul système d'animation à maintenir.
var _body: Node3D


func _build_visual(data: Dictionary) -> void:
	var model_path := String(data.get("model", ""))
	if model_path != "" and ResourceLoader.exists(model_path):
		var body: Node3D = preload("res://scenes/entities/player_body.gd").new()
		add_child(body)
		# `false` : ce n'est pas le joueur local — corps ENTIER, tête comprise.
		if body.setup(false, PlayerBody.palette_for_species(
				String(data.get("race", creature_id)))):
			_body = body
			_build_health_bar()
			return
		body.queue_free()
	_build_placeholder_visual(data)


## Visuel PROVISOIRE : capsule teintée par race, en attendant les modèles.
func _build_placeholder_visual(data: Dictionary) -> void:
	_mesh = MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.35
	capsule.height = 1.2
	_mesh.mesh = capsule
	_mesh.position.y = 0.6
	var mat := StandardMaterial3D.new()
	# Couleur déterministe par race (placeholder — remplacé par les .vox
	# assemblés par points d'attache, 12.1, quand la bibliothèque existera).
	var h := hash(String(data.get("race", creature_id))) % 360 / 360.0
	mat.albedo_color = Color.from_hsv(h, 0.55, 0.8 if ai_profile == "hostile" else 0.65)
	_mesh.material_override = mat
	add_child(_mesh)


func is_dead() -> bool:
	return health <= 0.0


## Agressive à vue. Les profils F.3 se répartissent ainsi :
##   "hostile"       : attaque dès qu'elle voit le joueur ;
##   "bete_sauvage"  : neutre, mais riposte une fois blessée (ours, loups,
##                     ermite, braconnier — « acculée », « si dérangé ») ;
##   "fuit"          : ne se bat jamais, s'écarte du joueur (cerf, renne...) ;
##   "civil"/"garde" : pacifiques ici (la vie de village, 3.4/E.25, n'existe
##                     pas encore — ils ne spawnent pas naturellement).
func is_hostile() -> bool:
	if ai_profile == "hostile" or (ai_profile == "bete_sauvage" and _provoked):
		return true
	# HOSTILE À VUE sous −50 (GDD 7.2). C'est ce qui donne un poids réel aux
	# méfaits : un joueur qui massacre des villageois finit par ne plus pouvoir
	# entrer dans un village. La règle vaut pour les civils comme pour les
	# gardes — la seule différence est que les gardes savent se battre.
	return _standing() <= Reputation.HOSTILE


## Ce que cette créature pense du joueur, tous échelons de réputation confondus.
func _standing() -> float:
	var player := get_node_or_null("/root/Main/Player")
	if player == null or player.reputation == null:
		return 0.0
	return player.reputation.standing_with(social_key, village_cell, race_id, kingdom_id)


## Palier de relation, pour l'affichage et les règles (Reputation.tier).
func relation_tier() -> String:
	return Reputation.tier(_standing())


## Fuit le joueur au lieu de l'ignorer (profil "fuit", F.3).
func is_skittish() -> bool:
	return ai_profile == "fuit"


## Une bête sauvage devient hostile DÉFINITIVEMENT dès le premier coup reçu
## (F.3 : « acculée », « hostile si dérangé ») — appelé par qui inflige les
## dégâts, la créature ne surveille pas sa propre santé.
func provoke() -> void:
	if ai_profile == "bete_sauvage":
		_provoked = true


## Combat : niveau d'arme, dureté/qualité de l'« arme » (naturelle = fixe).
func combat_functionality() -> Dictionary:
	return GameData.functionalities.get(combat.get("functionality", ""), {})


# --- Zones de coup (combat directionnel, 2026-07-28) ---

## Zones de coup de CETTE créature, en espace local (y = 0 aux pieds).
## Surcharge par fiche si elle définit `hitboxes`, sinon gabarit hérité de son
## `skeleton_template`. Résolu une fois au spawn : le balayage de lame tourne
## à la frame et ne doit pas retraverser GameData à chaque coup.
var _hitboxes: Array = []


func hitboxes() -> Array:
	return _hitboxes


func _resolve_hitboxes(data: Dictionary) -> void:
	# La surcharge par fiche passe par le même pré-parsing que les gabarits
	# (Vector3 plutôt qu'Array JSON) — sinon deux formats cohabiteraient et le
	# test d'intersection devrait gérer les deux.
	if data.has("hitboxes"):
		for zone: Variant in data["hitboxes"]:
			var z: Dictionary = zone
			var mn: Array = z["min"]
			var sz: Array = z["size"]
			_hitboxes.append({
				"id": String(z["id"]),
				"min": Vector3(mn[0], mn[1], mn[2]),
				"max": Vector3(mn[0] + sz[0], mn[1] + sz[1], mn[2] + sz[2]),
				"mult": float(z["mult"]),
			})
		return
	# LES ZONES DOIVENT CORRESPONDRE AU MODÈLE RÉELLEMENT AFFICHÉ, pas au
	# gabarit théorique de la fiche. Toutes les créatures portent aujourd'hui
	# le gabarit HUMANOÏDE (placeholder assumé) : un loup déclaré `quadrupede`
	# aurait ses zones au ras du sol alors qu'il se dresse comme un humain, et
	# la lame lui passerait AU TRAVERS sans le toucher.
	# `hitbox_template` permet de le dire explicitement ; il disparaîtra quand
	# chaque espèce aura son vrai modèle et que `skeleton_template` redeviendra
	# la source de vérité.
	var template := String(data.get("hitbox_template", ""))
	if template == "":
		template = _template_for_model(
			String(data.get("model", "")), String(data["skeleton_template"]))
	_hitboxes = GameData.hitbox_templates.get(template, [])


## Gabarit de zones déduit du MODÈLE porté. Tant qu'un seul modèle existe la
## règle est simple, et elle se supprimera d'elle-même : dès qu'une espèce
## reçoit un `.glb` dédié, elle retombe sur son `skeleton_template`.
func _template_for_model(model_path: String, fallback: String) -> String:
	if model_path.ends_with("humanoide.glb"):
		return "humanoide"
	return fallback


## Le segment monde [a, b] (le balayage de la pointe d'arme entre deux frames)
## traverse-t-il une zone de coup ? Retourne { "id", "mult", "t", "point" } de
## la PREMIÈRE zone touchée dans l'ordre du gabarit, ou {} si aucune.
##
## Slab test analytique (ray-AABB), pas de PhysicsServer : le projet n'a aucun
## collider, ni sur le terrain ni sur les entités. Une poignée de comparaisons
## flottantes par zone et par créature candidate — négligeable, et surtout
## sans le coût caché qu'aurait la génération de formes de collision.
##
## `logical_position` et non `position` : `position` est la valeur LISSÉE pour
## l'affichage (voir _process), en retard d'une interpolation sur l'état réel.
## Le combat doit trancher sur l'état logique, sinon un coup toucherait ou
## raterait selon le framerate.
func sweep_segment(a: Vector3, b: Vector3) -> Dictionary:
	var origin := logical_position
	var direction := b - a
	var length := direction.length()
	if length < 0.0001 or _hitboxes.is_empty():
		return {}
	var local_a := a - origin
	# LA PLUS PROCHE LE LONG DU SEGMENT, pas la première de la liste (corrigé
	# le 2026-07-28). L'ordre du gabarit est un ordre de LECTURE, pas un ordre
	# spatial : une lame qui traverse le bras avant d'atteindre le torse doit
	# toucher le BRAS. La version précédente rendait la première boîte qui
	# intersectait, donc un coup arrêté par un avant-bras comptait comme un
	# coup au torse — exactement l'inverse de ce que le joueur voit.
	var best := {}
	var best_t := 2.0
	for zone: Dictionary in _hitboxes:
		var hit := _segment_aabb(local_a, direction, zone["min"], zone["max"])
		if hit >= 0.0 and hit < best_t:
			best_t = hit
			best = {
				"id": zone["id"], "mult": float(zone["mult"]),
				"t": hit, "point": a + direction * hit,
			}
	return best


## Slab test segment↔AABB. Retourne le paramètre t ∈ [0, 1] de la première
## intersection, ou -1.0 si le segment manque la boîte. `direction` n'est PAS
## normalisée : t est donc directement la fraction du segment parcourue.
static func _segment_aabb(from: Vector3, direction: Vector3, box_min: Vector3, box_max: Vector3) -> float:
	var t_near := 0.0
	var t_far := 1.0
	for axis in 3:
		var d: float = direction[axis]
		var origin: float = from[axis]
		var lo: float = box_min[axis]
		var hi: float = box_max[axis]
		if absf(d) < 0.000001:
			# Segment parallèle à cette paire de plans : il ne peut toucher que
			# s'il est DÉJÀ entre les deux.
			if origin < lo or origin > hi:
				return -1.0
			continue
		var t1 := (lo - origin) / d
		var t2 := (hi - origin) / d
		if t1 > t2:
			var swap := t1
			t1 = t2
			t2 = swap
		t_near = maxf(t_near, t1)
		t_far = minf(t_far, t2)
		if t_near > t_far:
			return -1.0
	return t_near


# --- Barre de vie (2026-07-28) -------------------------------------------

## Hauteur de la barre au-dessus des pieds. Au-dessus de la tête du gabarit
## (2,0) avec une marge lisible.
const HEALTH_BAR_HEIGHT := 2.35
const HEALTH_BAR_WIDTH := 0.9
const HEALTH_BAR_THICKNESS := 0.11
## Au-delà de cette distance la barre est cachée : à 40 m elle ne se lit plus
## et n'ajoute que du bruit à l'écran.
const HEALTH_BAR_MAX_DISTANCE := 28.0

var _health_bar: Node3D
var _health_fill: MeshInstance3D


## Deux quads en panneau publicitaire : fond sombre + remplissage coloré. Non
## ombrés et sans test de profondeur désactivé — une barre qui traverserait les
## murs révélerait la position des créatures cachées, ce qui est un avantage
## qu'on ne veut pas donner.
func _build_health_bar() -> void:
	_health_bar = Node3D.new()
	_health_bar.position.y = HEALTH_BAR_HEIGHT
	add_child(_health_bar)
	_health_bar.add_child(_health_quad(
		Vector2(HEALTH_BAR_WIDTH, HEALTH_BAR_THICKNESS), Color(0.05, 0.05, 0.07, 0.85), 0.0))
	_health_fill = _health_quad(
		Vector2(HEALTH_BAR_WIDTH, HEALTH_BAR_THICKNESS) * 0.86, Color(0.85, 0.25, 0.2), 0.01)
	_health_bar.add_child(_health_fill)
	_health_bar.visible = false


func _health_quad(size: Vector2, color: Color, depth: float) -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = size
	var node := MeshInstance3D.new()
	node.mesh = quad
	node.position.z = depth
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Panneau publicitaire Y : la barre pivote pour faire face à la caméra mais
	# reste HORIZONTALE — sans le verrouillage d'axe elle basculerait avec le
	# tangage du joueur et deviendrait illisible vue d'en haut.
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	mat.billboard_keep_scale = true
	node.material_override = mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node


func _update_health_bar(viewer_position: Vector3) -> void:
	if _health_bar == null:
		return
	var fraction := clampf(health / maxf(health_max, 0.001), 0.0, 1.0)
	# Visible seulement une fois BLESSÉE, et à portée de lecture : afficher une
	# barre pleine au-dessus de chaque animal du décor noierait l'écran.
	var show := fraction < 0.999 \
		and position.distance_to(viewer_position) <= HEALTH_BAR_MAX_DISTANCE
	_health_bar.visible = show
	if not show:
		return
	var width := HEALTH_BAR_WIDTH * 0.86
	_health_fill.scale.x = maxf(fraction, 0.001)
	# Le remplissage se vide vers la GAUCHE (ancré à gauche) au lieu de se
	# rétrécir par le centre : c'est ce que lit un joueur habitué aux jauges.
	_health_fill.position.x = -width * (1.0 - fraction) * 0.5
	var mat := _health_fill.material_override as StandardMaterial3D
	# Vert → orange → rouge : l'état se lit à la couleur avant même la longueur.
	mat.albedo_color = Color(0.85, 0.25, 0.2).lerp(Color(0.35, 0.8, 0.3), fraction)


func _process(delta: float) -> void:
	# Purement visuel : lissage vers la position logique mise à jour en tick.
	position = position.lerp(logical_position, minf(delta * 8.0, 1.0))
	var facing := rotation.y
	var to_target := logical_position - position
	to_target.y = 0.0
	if to_target.length_squared() > 0.0004:
		# Orientation par la DIRECTION DE MARCHE. `look_at` était réservé au
		# placeholder ; il est ici remplacé par un calcul d'angle, parce que le
		# corps ne doit prendre que le lacet (un `look_at` en terrain pentu
		# ferait basculer la créature en avant).
		facing = atan2(to_target.x, to_target.z)
	if _mesh != null:
		rotation.y = facing
	_advance_pose(delta)
	if _body != null:
		var viewer := CreatureManager.last_player_position
		# Le corps est piloté en MONDE (pose + marche + IK), pas en local :
		# c'est la distance réellement parcourue qui fait avancer les pas.
		_body.update_as_entity(position + Vector3(0.0, FEET_OFFSET, 0.0), facing, viewer, delta)
		# Pose de combat APRES la locomotion : les bras ecrasent la pose de
		# repos, exactement comme l'IK du joueur ecrase la sienne.
		if _pose_phase != "":
			var ratio := _pose_time / maxf(_pose_duration, 0.001)
			_body.set_combat_pose(attack_direction, ratio, _pose_phase)
		_update_health_bar(viewer)


## Une passe de tick (E.1) : IA + mouvement + cooldown d'attaque. Retourne
## un événement d'attaque à résoudre par CreatureManager, ou {} sinon.
func tick_step(player_position: Vector3, player_ref: Node) -> Dictionary:
	if _attack_cooldown_ticks > 0:
		_attack_cooldown_ticks -= 1
	# Wind-up déclaré au tick précédent : le coup part MAINTENANT. La portée
	# sera revérifiée à la résolution (CreatureManager) — si le joueur a
	# reculé entre-temps, le coup fend l'air et crédite son Esquive.
	if _windup_ticks > 0:
		_windup_ticks -= 1
		if _windup_ticks == 0:
			var derived := WeaponStats.derive(combat_functionality(), {})
			_start_pose("strike", float(derived["release_ms"]) / 1000.0)
			return {"attacker": self, "target": player_ref}
		return {}

	# Vise le CORPS du joueur (torse ≈ œil − 0.9), jamais l'œil de la caméra :
	# avec la convention feet_y/EYE_HEIGHT 1.9, l'œil est à ~2.4 au-dessus du
	# centre d'une créature au sol — mesurer la portée sur l'œil rendait la
	# morsure (portée 1.7) PHYSIQUEMENT impossible, même collé au joueur
	# (BUG RÉEL trouvé par le test de combat, corrigé le 2026-07-21).
	var body := player_position + Vector3(0.0, -0.9, 0.0)
	var to_player := body - logical_position
	# Distance RÉELLE (3D) pour l'agression/l'attaque — une créature au sol
	# ne remarque ni n'atteint un joueur bien au-dessus d'elle (ex. en vol).
	var dist3d := to_player.length()
	var to_player_flat := to_player
	to_player_flat.y = 0.0
	var dist_flat := to_player_flat.length()

	var aggro_range := AGGRO_RANGE
	if DayNightManager.is_night():
		aggro_range *= AGGRO_NIGHT_FACTOR
	if is_hostile() and dist3d <= aggro_range:
		var functionality := combat_functionality()
		var reach: float = functionality.get("portee", 1.5)
		if dist3d <= reach + 0.5:
			# À portée : DÉCLARER l'attaque, puis la porter après le wind-up
			# (2026-07-28). Frapper dans le même tick que la décision rendait
			# toute esquive impossible — le joueur n'avait littéralement pas
			# d'instant où reculer. La déclaration est publique (télégraphie
			# E.12) : c'est ce qui rend le combat lisible.
			if _attack_cooldown_ticks <= 0 and not combat.is_empty():
				var stats_derived := WeaponStats.derive(functionality, {})
				_windup_ticks = maxi(1, ceili(float(stats_derived["windup_ms"]) / 100.0))
				var speed: float = functionality.get("vitesse_base", 1.0)
				_attack_cooldown_ticks = maxi(1, ceili(10.0 / speed))
				# DIRECTION REELLE, tiree a la declaration : sans elle le blocage
				# directionnel du joueur n'aurait rien a parer. Elle est PUBLIEE
				# par la telegraphie, donc lisible et anticipable.
				attack_direction = randi() % 4
				# Le geste DOIT etre visible : sans lui la telegraphie est un
				# signal que le joueur ne peut pas percevoir.
				_start_pose("windup", float(_windup_ticks) * TickManager.TICK_DT)
				EventBus.attack_telegraphed.emit(self,
					MeleeAttack.direction_name(attack_direction))
		elif dist_flat > 0.01:
			# Poursuite HORIZONTALE (mouvement par tick, jamais en _process — E.1) ;
			# une créature terrestre ne peut pas voler vers une cible en hauteur.
			var step := to_player_flat.normalized() * (float(stats.get("vitesse", 5)) * 0.02)
			logical_position += step
			logical_position.y = _ground_height()
	elif is_skittish() and dist3d <= FLEE_RANGE:
		# Fuite : s'écarter du joueur, à plat (même contrainte que la
		# poursuite — une bête terrestre ne s'envole pas pour fuir).
		if dist_flat > 0.01:
			var away := -to_player_flat.normalized() * (float(stats.get("vitesse", 5)) * 0.03)
			logical_position += away
			logical_position.y = _ground_height()
			_wander_target = logical_position
	else:
		_wander(player_position)
	return {}


## Heure à laquelle un résident part travailler, et à laquelle il rentre.
## Bornes larges : un village où tout le monde bascule à la même minute donne un
## effet de marionnettes. Le point d'ancrage change, la déambulation reste.
const WORK_START_HOUR := 7.0
const WORK_END_HOUR := 19.0


## Point autour duquel la créature déambule à cet instant.
##
## Pour une bête, c'est son point d'apparition — inchangé. Pour un RÉSIDENT,
## c'est son lieu de travail le jour et son domicile la nuit : c'est tout ce
## qu'il faut pour qu'un village respire, sans machine à états ni chemin
## calculé. Les habitants convergent le matin et rentrent le soir, et ça se
## lit depuis une colline.
func _anchor() -> Vector3:
	if not is_resident():
		return _home
	var hour := fmod(float(TickManager.tick_index), DayNightManager.TICKS_PER_DAY) 		/ DayNightManager.TICKS_PER_DAY * DayNightManager.HOURS_PER_DAY
	var working := hour >= WORK_START_HOUR and hour < WORK_END_HOUR
	if working and work_place != Vector3.INF:
		return work_place
	return home_building


func _wander(_player_position: Vector3) -> void:
	# Déambulation légère autour de l'ancre (comportement civil/passif).
	if logical_position.distance_to(_wander_target) < 0.3:
		var angle := randf() * TAU
		_wander_target = _anchor() + Vector3(cos(angle), 0.0, sin(angle)) * randf() * WANDER_RADIUS
	var step := (_wander_target - logical_position)
	step.y = 0.0
	if step.length() > 0.05:
		logical_position += step.normalized() * (float(stats.get("vitesse", 5)) * 0.006)
	# RATTRAPAGE : si l'ancre a changé (bascule jour/nuit), la cible de
	# déambulation peut être restée près de l'ancienne. On la repose dès que
	# l'écart devient absurde, sinon un habitant mettrait la nuit entière à
	# comprendre qu'il doit rentrer.
	if _wander_target.distance_to(_anchor()) > WANDER_RADIUS * 2.0:
		_wander_target = _anchor()
	logical_position.y = _ground_height()


## Démarre une phase de geste. La durée vient du TICK (wind-up décidé par
## l'IA) mais s'écoule à la FRAME : c'est ce qui rend le geste lisible malgré
## une IA qui n'avance qu'à 10 Hz.
func _start_pose(phase: String, duration: float) -> void:
	_pose_phase = phase
	_pose_time = 0.0
	_pose_duration = maxf(duration, 0.05)


## Fait avancer le geste et enchaîne les phases. La récupération existe pour
## que le bras REVIENNE au port : sans elle il resterait figé en fin d'arc, et
## le joueur ne saurait pas que la menace est passée.
func _advance_pose(delta: float) -> void:
	if _pose_phase == "":
		return
	_pose_time += delta
	if _pose_time < _pose_duration:
		return
	match _pose_phase:
		"windup":
			# Le tick n'a pas encore libéré le coup : on TIENT la position
			# armée plutôt que d'enchaîner, sinon le geste partirait avant le
			# coup et mentirait sur le moment de l'impact.
			_pose_time = _pose_duration
		"strike":
			_start_pose("recover", 0.25)
		_:
			_pose_phase = ""


## Hauteur de sol RÉELLE sous la créature : premier bloc solide (eau exclue)
## en descendant depuis les pieds, via le monde réel routé par dimension —
## indispensable en donjon (aucun terrain généré : la hauteur procédurale
## overworld faisait tomber le boss À TRAVERS le sol de sa salle, bug latent
## corrigé le 2026-07-21) et plus juste en surface (grottes, blocs posés).
## Convention conservée : retourne l'INDICE du bloc de sol + 0.5 (comme
## l'ancien height_at()+0.5). Fenêtre bornée (~10 blocs) ; au-delà, retombe
## sur la hauteur procédurale (overworld) ou garde sa hauteur (donjon).
func _ground_height() -> float:
	var bx := floori(logical_position.x)
	var bz := floori(logical_position.z)
	var start := floori(logical_position.y)
	var water_id: int = GameData.material_runtime_ids.get("eau", -1)
	for wy in range(start + 1, start - 9, -1):
		var id := WorldManager.block_at_world(Vector3i(bx, wy, bz))
		if id != 0 and id != water_id:
			return float(wy) + 0.5
	if dimension == &"overworld" and WorldManager.generator != null:
		return WorldManager.generator.height_at(bx, bz) + 0.5
	return logical_position.y

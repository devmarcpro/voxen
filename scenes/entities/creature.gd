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
var _wander_target: Vector3
var _mesh: MeshInstance3D
## Bête sauvage ayant reçu un coup : passe hostile pour de bon (voir provoke).
var _provoked := false


## Configure l'instance depuis les données GameData (D.2 : « se configure
## entièrement depuis un JSON de créature au spawn »).
func setup(id: String, spawn_position: Vector3) -> void:
	creature_id = id
	var data: Dictionary = GameData.creatures[id]
	display_name_key = data["name_key"]
	stats = data["base_stats"].duplicate()
	ai_profile = data["ai_profile"]
	combat = data.get("combat", {})
	health_max = float(stats.get("sante", 10))
	health = health_max
	logical_position = spawn_position
	_home = spawn_position
	_wander_target = spawn_position
	position = spawn_position
	_build_visual(data)


## Modèle Blockbench (12.1, amendé 2026-07-26) : une créature porte un `model`
## glTF/.glb complet et riggé. Tant qu'aucun modèle n'est fourni, on retombe
## sur la capsule colorée provisoire — le jour où un .glb est posé dans
## models/creatures/ et référencé en données, il s'affiche sans toucher au code.
func _build_visual(data: Dictionary) -> void:
	var model_path := String(data.get("model", ""))
	if model_path != "" and ResourceLoader.exists(model_path):
		var scene: PackedScene = load(model_path)
		if scene != null:
			var instance := scene.instantiate()
			add_child(instance)
			return
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
	return ai_profile == "hostile" or (ai_profile == "bete_sauvage" and _provoked)


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


func _process(delta: float) -> void:
	# Purement visuel : lissage vers la position logique mise à jour en tick.
	position = position.lerp(logical_position, minf(delta * 8.0, 1.0))
	if _mesh != null and logical_position.distance_squared_to(position) > 0.0001:
		var to_target := logical_position - position
		to_target.y = 0.0
		if to_target.length_squared() > 0.01:
			look_at(position - to_target, Vector3.UP)


## Une passe de tick (E.1) : IA + mouvement + cooldown d'attaque. Retourne
## un événement d'attaque à résoudre par CreatureManager, ou {} sinon.
func tick_step(player_position: Vector3, player_ref: Node) -> Dictionary:
	if _attack_cooldown_ticks > 0:
		_attack_cooldown_ticks -= 1

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
			# À portée : attaquer si le cooldown est écoulé (E.1 : 10/vitesse).
			if _attack_cooldown_ticks <= 0 and not combat.is_empty():
				var speed: float = functionality.get("vitesse_base", 1.0)
				_attack_cooldown_ticks = maxi(1, ceili(10.0 / speed))
				return {"attacker": self, "target": player_ref}
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


func _wander(_player_position: Vector3) -> void:
	# Déambulation légère autour du point de spawn (comportement civil/passif).
	if logical_position.distance_to(_wander_target) < 0.3:
		var angle := randf() * TAU
		_wander_target = _home + Vector3(cos(angle), 0.0, sin(angle)) * randf() * WANDER_RADIUS
	var step := (_wander_target - logical_position)
	step.y = 0.0
	if step.length() > 0.05:
		logical_position += step.normalized() * (float(stats.get("vitesse", 5)) * 0.006)
	logical_position.y = _ground_height()


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

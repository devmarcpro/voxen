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
## IDENTIFIANT RÉSEAU (2026-08-08), attribué par l'AUTORITÉ à la naissance et
## stable jusqu'à la mort. 0 = créature purement locale (sondes, bancs). C'est
## la seule façon pour un client de savoir de quelle créature on lui parle : ni
## l'index dans le registre (il bouge à chaque mort) ni l'`instance_id` de Godot
## (il diffère d'une machine à l'autre) ne conviennent.
var net_id := 0

var health_max: float
var health: float
var weapon_level := 0       # Niveau de compétence de l'arme naturelle (0 = débutant).

var logical_position: Vector3
var _home: Vector3
var _attack_cooldown_ticks := 0
## L'armement et la menace tenue vivent désormais dans `_attack_declared`,
## `_windup_left_ms` et `_hold_left_ms` — voir leur déclaration plus bas et
## l'explication du passage à la frame qui l'accompagne.
## GARDE DU PNJ (2026-08-02). Direction tenue et ticks restants. Une créature
## qui ne pare jamais fait de la lecture un exercice à sens unique : on apprend
## à lire ses coups, elle n'oppose rien aux nôtres. C'est la moitié manquante du
## duel de Mount & Blade.
## BALAYAGE À LA FRAME (2026-08-02). La géométrie du coup était échantillonnée
## AU TICK, à l'instant de la déclaration : on approchait l'arc entier d'un
## coup, avant même qu'il ne soit joué. Le joueur, lui, balaie sa lame image par
## image. Conséquence, on pouvait traverser l'arc d'un PNJ entre deux ticks sans
## être touché — le dernier endroit où les deux camps n'étaient pas jugés
## pareil.
##
## Désormais : la géométrie avance à la FRAME comme celle du joueur (même
## exception documentée dans MeleeAttack), et le TICK reste la seule autorité
## qui applique les dégâts. Le coup constaté attend ici entre les deux.
var _pending_strike: Dictionary = {}
## Position des points de la tête d'arme à la frame précédente.
var _strike_previous := PackedVector3Array()
## Le coup courant a-t-il fini sa course sans rien toucher ? Le tick le lit pour
## créditer l'esquive du joueur.
var _strike_finished := false
## Vitesse VISUELLE, mesurée à la frame : elle alimente le bonus de vitesse,
## que les créatures n'avaient pas faute de bouger autrement qu'au tick.
var _velocity := Vector3.ZERO
var _last_visual_position := Vector3.INF
## Lacet réellement appliqué au corps affiché. Le balayage de l'arme s'en sert :
## ce qu'on voit doit être ce qui frappe, jusqu'à l'orientation.
var _visual_facing := 0.0

# --- JEU DE JAMBES (2026-08-02, demande de l'auteur) ---------------------
#
# Un ennemi marchait DROIT sur le joueur jusqu'au contact, puis restait collé.
# Deux conséquences : aucune tension — il n'y avait pas d'instant où il hésite,
# donc rien à lire dans son déplacement — et à plusieurs ils s'empilaient dans
# le même mètre carré, se recouvrant l'un l'autre.
#
# Le modèle est celui de Mount & Blade : on se FACE, on tient une distance
# d'engagement, et on la fait varier. S'approcher, tenir, reculer, contourner.
# C'est ce va-et-vient qui crée les ouvertures, et c'est lui qu'on apprend à
# lire — pas seulement le geste d'arme.
enum Footwork { APPROCHE, TIENT, RECULE, CONTOURNE }

## Distance d'engagement visée, en fraction de l'allonge RÉELLE de la créature.
## Juste EN DEÇÀ : à 1,15 elle tenait une distance d'où sa lame ne portait pas,
## et tous ses coups partaient dans le vide. À 0,85 elle est à portée dès
## qu'elle décide de frapper, et il lui reste de la marge pour reculer.
const ENGAGE_RATIO := 0.85
## Tolérance autour de cette distance : sans elle la créature oscillerait en
## permanence autour d'un point exact, ce qui se lit comme un tremblement.
const ENGAGE_SLACK := 0.35
## Durée d'une intention de pied, en ticks (0,8 à 2,2 s). Assez longue pour être
## lisible, assez courte pour ne pas devenir prévisible.
const FOOTWORK_MIN_TICKS := 8
const FOOTWORK_MAX_TICKS := 22
## Vitesse de déplacement latéral et arrière, en fraction de la vitesse de
## marche. On recule et on contourne moins vite qu'on avance — c'est vrai, et
## ça empêche de fuir indéfiniment une attaque engagée.
const STRAFE_FACTOR := 0.75
const BACKPEDAL_FACTOR := 0.6

## RAYON PERSONNEL. Deux créatures qui se recouvrent sont illisibles : on ne
## sait plus laquelle arme son coup. Chacune s'écarte des autres, ce qui produit
## naturellement une répartition en arc autour du joueur — sans avoir à
## attribuer des places, ce qui demanderait un chef d'orchestre.
const PERSONAL_SPACE := 1.15
const SEPARATION_WEIGHT := 1.6

var _footwork: int = Footwork.APPROCHE
var _footwork_ticks := 0
## Sens du contournement, tiré avec l'intention : +1 horaire, -1 antihoraire.
var _orbit_sign := 1.0

var guard_direction: int = 0
var _guard_ticks := 0
var _guard_cooldown_ticks := 0
## Au plus 0,4 s de menace tenue : au-delà, l'adversaire cesse de lire une
## intention et croit à un bug.
const MAX_HOLD_MS := 400.0

# --- LE GESTE DE L'IA COURT À LA FRAME (2026-08-02) --------------------------
#
# CE QUI N'ALLAIT PAS. L'attaque d'une créature était minutée EN TICKS :
#   _windup_ticks = maxi(1, ceili(windup_ms / 100.0))
# Trois conséquences, toutes perceptibles :
#
#   1. LES DURÉES ÉTAIENT FAUSSES. Un wind-up de dague (150 ms) durait 200 ms,
#      celui d'une épée (450) 500. Les armes lentes et rapides se ressemblaient,
#      et le calibrage patiemment posé dans les données ne survivait pas à
#      l'arrondi.
#   2. LA FRAPPE TOMBAIT SUR UNE GRILLE DE 100 ms. Impossible de lire finement
#      l'instant de l'impact : il était toujours sur un multiple de 100 ms, et
#      le joueur, lui, joue à la frame. Le duel opposait deux horloges
#      différentes — la sienne continue, celle d'en face crantée.
#   3. LA FEINTE ÉTAIT TIRÉE AU TICK, donc annulable seulement à 10 Hz.
#
# CE QUI CHANGE, ET CE QUI NE CHANGE PAS. Le partage reste celui de
# MeleeAttack, à la lettre : la FRAME ne calcule que du temps et de la
# géométrie, le TICK garde toute autorité sur l'état du jeu. Concrètement,
# le tick DÉCIDE encore (attaquer ou non, se déplacer, parer, se remettre) et
# applique tous les dégâts ; seule la MINUTERIE du geste déjà décidé passe à la
# frame. Une créature ne peut donc pas plus qu'avant faire diverger l'état du
# jeu : elle ne fait que porter son geste au bon moment.
#
# C'est la même exception, cadrée de la même façon, que celle qui a sorti
# l'attaque du joueur du tick — et pour exactement la même raison.

## Attaque DÉCLARÉE et pas encore partie. Couvre l'armement puis la menace
## tenue ; les deux durées courent à la frame, en millisecondes réelles.
var _attack_declared := false
var _windup_left_ms := 0.0
var _hold_left_ms := 0.0
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
## IDENTITÉ COMPLÈTE de l'habitant (2026-08-09) : prénom, nom, genre, race,
## classe, rôle, âge, origine, foyer, parenté, équipement, inventaire. Vide pour
## une créature sauvage, qui n'est le membre d'aucune communauté.
##
## PORTÉE ICI ET PAS SEULEMENT DANS LE ROSTER. Le roster la calculait déjà, mais
## rien ne la donnait à la créature : le PNJ qu'on croisait en jeu n'avait ni
## nom, ni âge, ni origine, et toute cette démographie n'existait que sur le
## papier. Le dialogue, la fiche et les rumeurs la lisent maintenant ici.
var identity: Dictionary = {}
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
		var body := _build_body(model_path, data)
		if body != null:
			_body = body
			_build_health_bar()
			_build_threat_indicator()
			return
	_build_placeholder_visual(data)


## Le corps dépend de la MORPHOLOGIE, pas de l'espèce : un humanoïde prend le
## corps du joueur (même peau, même IK, même marche), un animal prend
## `CreatureBody` (mêmes principes, mais quatre pattes, une ondulation ou des
## ailes). Les deux exposent `update_as_entity` et `set_combat_pose` — le reste
## du fichier n'a pas à savoir lequel il tient.
##
## Retourne null si le modèle n'a pas pu être monté ; l'appelant retombe alors
## sur la capsule provisoire plutôt que de laisser une créature invisible.
func _build_body(model_path: String, data: Dictionary) -> Node3D:
	if model_path.ends_with("humanoide.glb"):
		var human: Node3D = preload("res://scenes/entities/player_body.gd").new()
		add_child(human)
		# `false` : ce n'est pas le joueur local — corps ENTIER, tête comprise.
		if human.setup(false, PlayerBody.palette_for_species(
				String(data.get("race", creature_id)))):
			_attach_weapon(human, data)
			return human
		human.queue_free()
		return null
	var animal := CreatureBody.new()
	add_child(animal)
	# La teinte vient du manifeste du modèle (models/creatures/rigs.json), pas
	# d'une couleur dérivée de la race : un loup doit être gris, pas d'une
	# couleur tirée d'un hachage.
	if animal.setup(model_path):
		return animal
	animal.queue_free()
	return null


## Visuel PROVISOIRE : capsule teintée par race, en attendant les modèles.
## Met l'ARME DE LA FICHE dans la main du PNJ (2026-08-02, lisibilité du combat).
##
## POURQUOI ÇA COMPTE PLUS QUE TOUT LE RESTE. Un PNJ armait son bras dans le
## vide : rien ne disait au joueur s'il avait affaire à une dague ou à une
## hallebarde, donc rien ne lui permettait de juger la distance — la lecture la
## plus fondamentale de Mount & Blade, avant même la direction du coup.
##
## L'identifiant de fonctionnalité EST celui de l'objet pour toutes les armes :
## une seule valeur de fiche décide donc des CHIFFRES et du MODÈLE, et les deux
## ne peuvent pas diverger. Une créature à `mains_nues` n'a pas d'objet
## correspondant et se bat donc à mains nues, sans qu'il y ait rien à déclarer.
func _attach_weapon(body: Node3D, data: Dictionary) -> void:
	var functionality := String((data.get("combat", {}) as Dictionary).get("functionality", ""))
	var item: Dictionary = GameData.items.get(functionality, {})
	if item.is_empty() or not item.has("parts"):
		return
	var materials: Dictionary = (data.get("combat", {}) as Dictionary).get("arme_materiaux", {})
	var model := WeaponPreview.assemble(item, materials)
	if model == null:
		return
	# Les pièces sont modélisées vers +Y et les os pointent vers -Y : le demi-tour
	# est le même que pour l'arme du joueur (voir HeldItem.PART_ROTATION).
	model.rotation_degrees = Vector3(180.0, 0.0, 0.0)
	body.attach_weapon_model(model, WEAPON_SCALE)


## Même échelle que l'arme du joueur : ce qu'on voit dans la main d'un PNJ doit
## être l'arme qu'on ramassera sur son corps.
const WEAPON_SCALE: float = preload("res://scenes/entities/held_item.gd").PART_SCALE


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
## Fiche du profil d'IA de cette créature (E.16), ou {} si le profil manque.
## Lue à chaque appel plutôt que copiée : `F5` recharge les données à chaud, et
## un profil copié à la naissance résisterait au rechargement.
func profile() -> Dictionary:
	return GameData.ai_profiles.get(ai_profile, {})


## Portée de PERCEPTION, en blocs — ce qui était `AGGRO_RANGE` en dur.
##
## E.16 : « vision = cône de distance f(Perception) modulé par la lumière locale
## et la Discrétion de la cible ». On tient les deux modulations, en données :
## un profil déclare combien la lumière et la discrétion pèsent pour lui. Une
## bête sent plus qu'elle ne voit et s'en soucie peu ; un villageois ne
## remarquera personne dans le noir.
func perception_range(target_stealth: float = 0.0) -> float:
	var fiche := profile()
	var range_blocks := float(fiche.get("vision", AGGRO_RANGE))
	if DayNightManager.is_night():
		range_blocks *= float(fiche.get("vision_nuit", AGGRO_NIGHT_FACTOR))
	# LUMIÈRE LOCALE : `daylight()` vaut 1 en plein jour, 0 la nuit noire. Le
	# poids décide de ce qu'on perd dans l'ombre — à poids nul, on voit pareil.
	var light_weight := float(fiche.get("poids_lumiere", 0.0))
	if light_weight > 0.0:
		var light := clampf(DayNightManager.daylight(), 0.0, 1.0)
		range_blocks *= 1.0 - light_weight * (1.0 - light)
	# DISCRÉTION DE LA CIBLE : sans ce terme, la compétence n'avait AUCUN effet
	# sur les créatures — on pouvait monter Discrétion à 100 sans que rien ne
	# change, ce qui est pire qu'une compétence absente.
	var stealth_weight := float(fiche.get("poids_discretion", 0.0))
	if stealth_weight > 0.0 and target_stealth > 0.0:
		range_blocks *= maxf(0.2, 1.0 - stealth_weight * clampf(target_stealth / 100.0, 0.0, 1.0))
	return maxf(range_blocks, 1.0)


func is_hostile() -> bool:
	var fiche := profile()
	if bool(fiche.get("attaque_a_vue", false)):
		return true
	if bool(fiche.get("riposte", false)) and _provoked:
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


## Pose l'identité d'un habitant et lui donne son ÉQUIPEMENT VISIBLE.
##
## L'arme portée vient de l'équipement de sa classe, assemblée par la même
## fonction que celle du joueur et des avatars distants (`WeaponPreview`) : ce
## qu'on voit dans la main d'un forgeron est ce qu'on verrait dans la sienne.
## NOMMÉE `apply_identity` ET NON `set_identity` : `Node3D` porte déjà un
## `set_identity()` natif (identité de scène), et le redéfinir donne un
## avertissement traité en erreur — le moteur ne l aurait de toute façon
## jamais appelée comme on l entend ici.
func apply_identity(data: Dictionary) -> void:
	identity = data
	var carried: Array = data.get("equipement", [])
	if carried.is_empty() or _body == null or not _body.has_method("attach_weapon_model"):
		return
	var item: Dictionary = GameData.items.get(String(carried[0]), {})
	if item.is_empty():
		return
	# MATÉRIAUX MODESTES : un villageois ne porte pas d'acier de maître. Ils
	# décident de la teinte, donc de ce qu'on lit à distance.
	var model := WeaponPreview.assemble(item, {"bois": "pin", "minerai": "cuivre"})
	if model != null:
		_body.attach_weapon_model(model,
				preload("res://scenes/entities/held_item.gd").PART_SCALE)


## Nom affichable de cette créature : son nom complet si c'est quelqu'un, le nom
## d'espèce sinon. Un point d'entrée unique — le dialogue, la fiche et les
## journaux doivent tous dire la même chose.
func display_name() -> String:
	var shown := String(identity.get("affichage", ""))
	return shown if shown != "" else tr(display_name_key)


## Ligne de présentation : « 31 ans · garde · de Borgrad ». Vide pour une
## créature sans identité.
func identity_line() -> String:
	if identity.is_empty():
		return ""
	var parts: Array[String] = []
	if int(identity.get("age", 0)) > 0:
		parts.append(tr("ui.pnj.age").format({"age": str(int(identity["age"]))}))
	var role := String(identity.get("role", ""))
	if role != "":
		parts.append(tr("job.%s" % role))
	var origin := String(identity.get("origine", ""))
	if origin != "":
		parts.append(tr("ui.pnj.origine").format({"lieu": origin}))
	return " · ".join(parts)


## Palier de relation, pour l'affichage et les règles (Reputation.tier).
func relation_tier() -> String:
	return Reputation.tier(_standing())


## Fuit le joueur au lieu de l'ignorer (profil "fuit", F.3), OU sous TERREUR
## (F.4, 2026-08-03). Le statut se greffe ici plutôt que dans l'IA : « fuir »
## était déjà une notion du code, la terreur ne fait que l'activer
## temporairement au lieu d'inventer un second chemin de fuite.
func is_skittish() -> bool:
	# LE PROFIL LE DIT, plus une comparaison de chaîne : c'est la donnée qui
	# décide, comme pour l'agressivité et la perception.
	# UN CIVIL NE FUIT PAS À VUE (2026-08-09, signalé en jeu : « les PNJ fuient le
	# joueur »). Régression du passage des comportements en données : le profil
	# `civil` porte `fuit: true` — il DOIT fuir, mais quand on l'attaque, pas
	# quand on entre au village. La donnée disait « fuyard » là où elle voulait
	# dire « fuit s'il est menacé », et tout un village détalait à l'approche.
	if bool(profile().get("fuit", false)):
		return true
	if bool(profile().get("fuit_si_menace", false)) and _provoked:
		return true
	return has_status("terreur")


## Encaisse `amount` points de dégâts. UN SEUL POINT D'ENTRÉE, pour que le
## stagger ne puisse pas être oublié par un appelant.
##
## STAGGER (2026-08-02) : un coup reçu INTERROMPT l'attaque en préparation,
## exactement comme chez le joueur. Sans lui, frapper une créature en plein
## wind-up ne l'empêchait pas de porter son coup : la récompense du timing —
## toucher le premier — n'existait pas, et parer devenait facultatif.
## STATUTS (F.4, 2026-08-03) : une créature peut être ralentie, gelée, brûlée.
## Créés À LA DEMANDE : la grande majorité des créatures n'en porte jamais, et
## instancier un tracker par créature coûterait pour rien sur une population de
## soixante.
var _statuses: StatusTracker = null


## LE STATUT EST DIFFUSÉ TEL QUEL, jamais rejoué : il résulte d'un jet et de
## règles que le client n'a pas de raison d'avoir suivies. Sans ça, un ennemi
## ralenti chez l'hôte courrait normalement chez l'autre joueur.
func apply_status(status_id: String, duration_ticks: int = 0, power: float = 1.0) -> void:
	if net_id > 0 and NetworkManager.is_authority() and NetworkManager.has_peers():
		NetworkManager.rpc_creature_status.rpc(net_id, status_id, duration_ticks, power)
	if _statuses == null:
		_statuses = StatusTracker.new()
		_statuses.setup(self, StatModifiers.new())
	_statuses.apply(status_id, duration_ticks, power)


func has_status(status_id: String) -> bool:
	return _statuses != null and _statuses.has(status_id)


## Fait vieillir les statuts d'un tick et applique leurs dégâts périodiques.
## Appelé par le tick de la créature, jamais à la frame.
func tick_statuses() -> void:
	if _statuses == null:
		return
	var periodic := _statuses.tick()
	if periodic > 0.0:
		take_damage(periodic)


func take_damage(amount: float) -> void:
	health = maxf(0.0, health - amount)
	# LES PV SONT DIFFUSÉS, pas recalculés. Un client qui rejouerait le calcul de
	# dégâts obtiendrait un autre nombre — jets de dés, sweet spot, parade —, et
	# la barre de vie mentirait de plus en plus à chaque coup. L'autorité dit ce
	# qu'il reste ; c'est tout ce que le client a besoin de savoir.
	if net_id > 0 and NetworkManager.is_authority() and NetworkManager.has_peers():
		NetworkManager.rpc_creature_health.rpc(net_id, health)
	if amount <= 0.0:
		return
	_attack_declared = false
	_windup_left_ms = 0.0
	_hold_left_ms = 0.0
	if _pose_phase == "windup" or _pose_phase == "armee":
		_start_pose("recover", 0.2)


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
		_hitboxes = MeleeAttack.parse_zones(data["hitboxes"])
		return
	# LES ZONES DOIVENT CORRESPONDRE AU MODÈLE RÉELLEMENT AFFICHÉ, pas au
	# gabarit théorique de la fiche : un loup déclaré `quadrupede` mais rendu
	# avec le gabarit humanoïde aurait ses zones au ras du sol alors qu'il se
	# dresse comme un homme, et la lame lui passerait AU TRAVERS.
	#
	# Les modèles animaux embarquent donc leurs zones, CALCULÉES sur leur propre
	# géométrie par le générateur (`models/creatures/rigs.json`). C'est la seule
	# façon qu'elles restent vraies : une boîte saisie à la main cesserait de
	# l'être à la première retouche de proportion, et il y a vingt-sept modèles.
	var model_path := String(data.get("model", ""))
	if model_path != "":
		var zones: Array = CreatureBody.hitboxes_for(model_path)
		if not zones.is_empty():
			_hitboxes = MeleeAttack.parse_zones(zones)
			return
	# `hitbox_template` permet de forcer un gabarit ; sinon c'est celui du
	# squelette déclaré (cas de l'humanoïde et des espèces sans modèle dédié).
	var template := String(data.get("hitbox_template", ""))
	if template == "":
		template = String(data["skeleton_template"])
	_hitboxes = GameData.hitbox_templates.get(template, [])




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
		var hit := MeleeAttack.segment_aabb(local_a, direction, zone["min"], zone["max"])
		if hit >= 0.0 and hit < best_t:
			best_t = hit
			best = {
				"id": zone["id"], "mult": float(zone["mult"]),
				"t": hit, "point": a + direction * hit,
			}
	return best




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


## Maillages et matériaux des panneaux, PARTAGÉS entre toutes les créatures.
##
## Ils étaient créés à neuf pour chaque créature : trois `StandardMaterial3D`
## et trois `QuadMesh` par apparition. Mesuré, `_build_visual` coûtait 19,9 ms
## alors que ses briques connues — instancier le .glb, peindre la peau — n'en
## faisaient que 1,2 : tout le reste partait dans ces matériaux, chacun forçant
## la mise en place d'un pipeline de rendu.
##
## Or ils sont IDENTIQUES d'une créature à l'autre : mêmes tailles, mêmes
## couleurs, mêmes réglages. Le cache de peau du corps fait déjà exactement ça
## pour les dix-huit maillages du modèle — on applique la même règle ici.
##
## Le nœud, lui, reste propre à chaque créature : c'est lui qui porte la
## position et la visibilité.
static var _quad_mesh_cache := {}
static var _quad_material_cache := {}


func _health_quad(size: Vector2, color: Color, depth: float) -> MeshInstance3D:
	var mesh_key := "%.3f|%.3f" % [size.x, size.y]
	if not _quad_mesh_cache.has(mesh_key):
		var quad := QuadMesh.new()
		quad.size = size
		_quad_mesh_cache[mesh_key] = quad

	var material_key := color.to_html(true)
	if not _quad_material_cache.has(material_key):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		# Panneau publicitaire Y : la barre pivote pour faire face à la caméra
		# mais reste HORIZONTALE — sans le verrouillage d'axe elle basculerait
		# avec le tangage du joueur et deviendrait illisible vue d'en haut.
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
		mat.billboard_keep_scale = true
		_quad_material_cache[material_key] = mat

	var node := MeshInstance3D.new()
	node.mesh = _quad_mesh_cache[mesh_key]
	node.position.z = depth
	node.material_override = _quad_material_cache[material_key]
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node


# --- Télégraphie visible de l'attaque (2026-08-02) --------------------------
#
# POURQUOI CE N'EST PAS DANS LE HUD. Le combat directionnel était illisible du
# côté ADVERSE : le HUD affiche fidèlement ta propre attaque et ta propre garde,
# mais la menace, elle, n'avait qu'un seul canal — la pose 3D du corps. Dans
# Mount & Blade cette pose suffit, parce que les animations sont amples, tenues
# et jouées sur un squelette humain qu'on lit d'instinct. Ici, les poses sont
# procédurales sur des corps voxel : le bras part dans la bonne direction, mais
# de quelques degrés, et à trois mètres on ne voit rien.
#
# Le repère est donc posé DANS LE MONDE, au-dessus de la créature, et non au
# centre de l'écran. Ce choix est le cœur de l'affaire : un indicateur central
# apprendrait à regarder son réticule, alors que tout l'intérêt du système est
# d'apprendre à regarder SON ADVERSAIRE. Ancré sur elle, il désigne aussi
# laquelle menace quand il y en a trois — ce qu'un HUD central ne peut pas
# faire sans devenir un tableau de bord.
#
# La position du témoin encode la direction, comme les chevrons du HUD : en
# haut pour un coup qui descend, à gauche/droite pour une taille, en bas pour un
# estoc. Aucun glyphe, donc aucun risque de caractère manquant dans la police —
# le projet a déjà payé ce prix avec le chinois et le japonais.
const THREAT_HEIGHT := 2.75
const THREAT_SPREAD := 0.34
const THREAT_SIZE := 0.17
const THREAT_MAX_DISTANCE := 24.0
## Décalage de chaque direction autour du centre, dans l'ordre de
## MeleeAttack.Direction (ESTOC, TAILLE_GAUCHE, TAILLE_DROITE, OVERHEAD).
## L'estoc est EN BAS et le coup haut EN HAUT : même convention que le HUD du
## joueur, sans quoi on lirait sa propre attaque et celle d'en face à l'envers
## l'une de l'autre.
const THREAT_OFFSETS := [
	Vector2(0.0, -1.0), Vector2(-1.0, 0.0), Vector2(1.0, 0.0), Vector2(0.0, 1.0),
]
## Couleurs des deux temps. L'armement est ORANGE (il reste du temps pour
## répondre), la frappe est BLANC VIF (il est trop tard, mais on apprend le
## rythme en la voyant partir).
const THREAT_WINDUP := Color(1.0, 0.5, 0.12, 0.95)
const THREAT_STRIKE := Color(1.0, 1.0, 1.0, 1.0)

var _threat_root: Node3D
var _threat_mark: MeshInstance3D


## UN SEUL repère, qu'on DÉPLACE, et non quatre qu'on allume tour à tour.
##
## La première version en construisait quatre par créature — quatre maillages et
## quatre matériaux, payés au spawn. Or le spawn d'une créature est déjà le poste
## le plus lourd du jeu (la sonde `--probe-corps` le mesure et le trouve déjà
## au-dessus de son budget), et il n'y a jamais qu'UNE direction menaçante à la
## fois : les trois autres n'existaient que pour rester invisibles.
func _build_threat_indicator() -> void:
	_threat_root = Node3D.new()
	_threat_root.position.y = THREAT_HEIGHT
	add_child(_threat_root)
	_threat_mark = _health_quad(Vector2(THREAT_SIZE, THREAT_SIZE), THREAT_WINDUP, 0.0)
	_threat_root.add_child(_threat_mark)
	_threat_root.visible = false


## Montre la direction du coup EN COURS D'ARMEMENT, et son avancement.
##
## C'est la direction D'ARRIVÉE de la lame qui est montrée (`guard_for`), pas
## celle du geste de l'attaquant : une taille partie de SA droite arrive sur
## TA gauche. Montrer le geste obligerait le joueur à faire le miroir dans sa
## tête à chaque coup, ce qui n'est pas la difficulté qu'on cherche à créer —
## la difficulté, c'est de voir et de réagir à temps.
func _update_threat_indicator(viewer_position: Vector3) -> void:
	if _threat_root == null:
		return
	var arming := _pose_phase == "windup" or _pose_phase == "armee"
	var striking := _pose_phase == "strike"
	var show := (arming or striking) \
		and position.distance_to(viewer_position) <= THREAT_MAX_DISTANCE
	_threat_root.visible = show
	if not show:
		return
	# LE REPÈRE EST TOURNÉ VERS CELUI QUI LE LIT. Les quatre témoins sont placés
	# à des décalages en X/Y ; sans cette rotation ils resteraient dans l'espace
	# local de la CRÉATURE, et « à gauche » désignerait sa gauche à elle. Vue de
	# dos, l'indication serait donc inversée — pire que pas d'indication du tout,
	# puisqu'on parerait du mauvais côté en croyant bien lire.
	#
	# Le matériau met déjà les quads en panneau publicitaire, mais un panneau
	# publicitaire n'oriente que la FACE : il ne déplace pas les nœuds. C'est donc
	# ici, sur leur parent, que la question se règle.
	#
	# On oriente +Z vers le spectateur, ce qui aligne +X sur SA droite.
	var to_viewer := viewer_position - position
	to_viewer.y = 0.0
	if to_viewer.length_squared() > 0.0001:
		_threat_root.global_rotation.y = atan2(to_viewer.x, to_viewer.z)
	var offset: Vector2 = THREAT_OFFSETS[MeleeAttack.guard_for(attack_direction)]
	_threat_mark.position = Vector3(
		offset.x * THREAT_SPREAD, offset.y * THREAT_SPREAD, 0.0)
	var mat := _threat_mark.material_override as StandardMaterial3D
	if striking:
		mat.albedo_color = THREAT_STRIKE
		_threat_mark.scale = Vector3.ONE * 1.5
		return
	# Le témoin GROSSIT à mesure que le coup s'arme : l'imminence se lit à la
	# taille, en vision périphérique, sans avoir à fixer la créature.
	var ratio := clampf(_pose_time / maxf(_pose_duration, 0.001), 0.0, 1.0)
	mat.albedo_color = THREAT_WINDUP
	_threat_mark.scale = Vector3.ONE * lerpf(0.55, 1.25, ratio)


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
		facing = _yaw_towards(to_target)
	# ON SE TOURNE POUR FRAPPER (2026-08-02). Le lacet venait UNIQUEMENT de la
	# direction de marche : une créature immobile au contact du joueur gardait
	# son orientation précédente et l'attaquait en regardant ailleurs. C'était
	# visible à l'œil, et depuis que le balayage suit l'orientation affichée,
	# c'était aussi sa lame qui partait de travers.
	# LOCK-IN (2026-08-02, demande de l'auteur : « un mob ennemi devrait se lock
	# in au joueur de face »). Un adversaire engagé reste FACE à sa cible, qu'il
	# avance, recule ou contourne — sinon son jeu de jambes se lit comme une
	# errance, et surtout son arme part de travers. Ce n'est plus réservé au
	# moment de l'attaque : c'est l'état d'un ennemi qui vous a vu.
	if _pose_phase != "" or _engaged:
		var to_victim := CreatureManager.last_player_position - position
		to_victim.y = 0.0
		if to_victim.length_squared() > 0.0004:
			facing = _yaw_towards(to_victim)
	if _mesh != null:
		rotation.y = facing
	# ORIENTATION RÉELLEMENT AFFICHÉE (2026-08-02). `rotation.y` n'est posée que
	# sur la capsule provisoire : une créature MODÉLISÉE reçoit son lacet par
	# `update_as_entity`, et le nœud reste donc à zéro. Le balayage de son arme
	# lisait `rotation.y` et frappait vers le −Z du MONDE, quelle que soit la
	# direction où elle regardait. On mémorise ici le lacet réellement utilisé
	# pour dessiner le corps : la lame suit exactement ce qu'on voit.
	_visual_facing = facing
	# AVANT la pose : c'est lui qui décide des changements de phase, la pose ne
	# fait qu'avancer dans celle qui est en cours.
	_advance_declared_attack(delta)
	_advance_pose(delta)
	_measure_velocity(delta)
	# GÉOMÉTRIE À LA FRAME, comme celle du joueur. Elle ne modifie aucun état de
	# jeu : elle CONSTATE, et le tick appliquera (voir `_pending_strike`).
	if _pose_phase == "strike":
		_sweep_strike(delta)
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
		_update_threat_indicator(viewer)


## La créature tient-elle une garde, et couvre-t-elle `attack_direction` ?
##
## MÊME RÈGLE QUE POUR LE JOUEUR : les tailles sont MIROIR, l'estoc et le coup
## haut se couvrent eux-mêmes. Une garde tenue du mauvais côté ne sert à rien —
## sans quoi parer serait un bouton et non un pari.
func guard_covers(incoming: int) -> bool:
	return _guard_ticks > 0 and guard_direction == MeleeAttack.guard_for(incoming)


func is_guarding() -> bool:
	return _guard_ticks > 0


## Le joueur vient d'annoncer un coup : la créature tente de lever la bonne
## garde. Sa réussite dépend de son NIVEAU DE COMBAT — un villageois se trompe
## souvent, un chef de bande rarement. C'est ce qui donne au niveau un effet
## qu'on ressent en jouant, et non un simple chiffre de dégâts.
##
## Elle ne pare que si elle n'est pas déjà engagée dans son propre coup :
## attaquer et parer en même temps est précisément ce que le système interdit.
const GUARD_TICKS := 6
## Repos entre deux gardes. SANS LUI, une créature parait CHAQUE coup : le
## joueur n'avait plus aucune ouverture et le combat devenait un mur. Ce délai
## est ce qui crée la fenêtre — enchaîner paie, parce que la seconde attaque
## arrive pendant que la garde se rebaisse.
const GUARD_COOLDOWN_TICKS := 14
## Repos après une feinte : annuler son coup n'est pas gratuit non plus, sinon
## une créature feinterait en boucle et ne frapperait jamais.
const FEINT_RECOVERY_TICKS := 6
## Part des menaces tenues qui finissent en feinte, par tick de maintien. Bornée
## bas : une créature qui feinte une fois sur deux devient illisible, et le
## joueur cesse d'accorder du crédit à ce qu'il voit — ce qui détruit la
## télégraphie au lieu de l'enrichir.
const FEINT_BASE := 0.04
const FEINT_PER_LEVEL := 0.006
const FEINT_MAX := 0.30
## Chambrer se mérite : rien avant le niveau 10, et jamais plus d'une fois sur
## trois. Un adversaire qui chambre systématiquement rendrait toute attaque
## suicidaire.
const CHAMBER_MIN_LEVEL := 10.0
const CHAMBER_PER_LEVEL := 0.02
const CHAMBER_MAX := 0.33
## Diviseur de niveau. Volontairement HAUT : un bandit de niveau 10 lit une
## attaque sur quatre, un souverain de niveau 25 une sur deux. Parer devait
## rester un événement remarquable, pas la réponse par défaut — un adversaire
## qui bloque plus d'une fois sur deux ne se lit plus, il use.
const GUARD_SKILL_DIVISOR := 60.0


## Chance de feinter, et de chambrer : toutes deux montent avec le niveau de
## combat. C'est ce qui fait qu'un villageois se lit comme un livre ouvert et
## qu'un chef de bande ment.
func _feint_chance() -> float:
	var level := float(GameData.creatures[creature_id].get("niveau_combat", 5))
	return clampf(FEINT_BASE + level * FEINT_PER_LEVEL, 0.0, FEINT_MAX)


## La créature attaque-t-elle DANS le coup qui arrive ? C'est le pendant exact
## de `Player.is_chambering` : même condition, même fenêtre. Le geste le plus
## exigeant du jeu ne pouvait pas rester réservé au joueur.
## Cette créature dévie-t-elle les projectiles ? Il lui faut une GARDE LEVÉE et
## une plaque : on ne pare pas une flèche à l'épée. Les créatures n'ont pas
## encore de bouclier en données — la règle est en place, elle s'appliquera dès
## qu'une en portera un, et elle vaut déjà pour le joueur.
func blocks_projectiles() -> bool:
	return _guard_ticks > 0 and bool(combat.get("bouclier", false))


## Un projectile dévié entame la plaque, comme un coup encaissé.
func wear_from_projectile() -> void:
	pass


func is_chambering(incoming: int) -> bool:
	return _attack_declared and attack_direction == incoming


## Wind-up d'un chambering, en ms. Volontairement bref et FIXE : c'est un
## départ simultané, pas une attaque ordinaire. Valait un tick (100 ms) quand
## tout était cranté ; on garde cette valeur, désormais exacte.
const CHAMBER_WINDUP_MS := 100.0


func react_to_telegraph(incoming: int) -> void:
	if _attack_declared or _pose_phase == "strike" or combat.is_empty():
		return
	if _guard_cooldown_ticks > 0 or _guard_ticks > 0:
		return
	var level := float(GameData.creatures[creature_id].get("niveau_combat", 5))
	# CHAMBRER PLUTÔT QUE PARER (2026-08-02). Un adversaire aguerri ne se
	# contente pas de bloquer : il part dans la MÊME direction pour entrechoquer
	# les lames. Réservé aux hauts niveaux — c'est le geste qui doit se mériter,
	# et croiser un adversaire qui chambre doit se remarquer.
	if _attack_cooldown_ticks <= 0 and randf() < clampf(
			(level - CHAMBER_MIN_LEVEL) * CHAMBER_PER_LEVEL, 0.0, CHAMBER_MAX):
		var chambered := WeaponStats.derive(combat_functionality(), {})
		attack_direction = MeleeAttack.nearest_allowed(
			incoming, chambered.get("directions", []))
		# Wind-up ÉCOURTÉ : chambrer, c'est partir en même temps que l'autre.
		# Aucune menace tenue — un chambering qui attendrait ne chambrerait plus.
		_attack_declared = true
		_windup_left_ms = CHAMBER_WINDUP_MS
		_hold_left_ms = 0.0
		_attack_cooldown_ticks = maxi(1, ceili(
			10.0 / float(combat_functionality().get("vitesse_base", 1.0))))
		_start_pose("windup", CHAMBER_WINDUP_MS / 1000.0)
		EventBus.attack_telegraphed.emit(self,
			MeleeAttack.direction_name(attack_direction))
		return
	var reads_it := randf() < clampf(0.10 + level / GUARD_SKILL_DIVISOR, 0.0, 0.6)
	# Se tromper de garde est un VRAI choix, pas une absence de garde : la bête
	# se protège du mauvais côté, et le joueur voit qu'elle s'est trompée.
	guard_direction = MeleeAttack.guard_for(incoming) if reads_it else randi() % 4
	_guard_ticks = GUARD_TICKS
	_guard_cooldown_ticks = GUARD_COOLDOWN_TICKS
	_start_pose("garde", float(GUARD_TICKS) * TickManager.TICK_DT)


## Une passe de tick (E.1) : IA + mouvement + cooldown d'attaque. Retourne
## un événement d'attaque à résoudre par CreatureManager, ou {} sinon.
func tick_step(player_position: Vector3, player_ref: Node) -> Dictionary:
	# ÉTOURDI (F.4) : « perd son prochain tour de décision ». Le retour anticipé
	# est exactement ça — la créature ne décide rien ce tick-ci. Placé AVANT les
	# décomptes de recharge à dessein : être étourdi ne doit pas faire avancer
	# ses temps de recharge, sinon le statut offrirait un répit gratuit.
	if has_status("etourdi"):
		return {}
	if _attack_cooldown_ticks > 0:
		_attack_cooldown_ticks -= 1
	if _guard_cooldown_ticks > 0:
		_guard_cooldown_ticks -= 1
	if _guard_ticks > 0:
		_guard_ticks -= 1
		if _guard_ticks == 0 and _pose_phase == "garde":
			_pose_phase = ""
	# LE GESTE DÉCLARÉ COURT À LA FRAME (2026-08-02) : son armement, sa menace
	# tenue, sa feinte et son départ sont minutés par `_advance_declared_attack`.
	# Le tick n'a plus qu'à s'effacer tant qu'il dure — il ne redécide rien et ne
	# déplace pas la créature, exactement comme avant : on ne se repositionne pas
	# une arme à moitié armée.
	if _attack_declared:
		return {}
	# COUP CONSTATÉ par la géométrie : le tick l'applique maintenant. C'est le
	# même contrat que pour le joueur — la frame observe, le tick décide.
	if not _pending_strike.is_empty():
		var hit := _pending_strike
		_pending_strike = {}
		_strike_finished = false
		return {"attacker": self, "target": player_ref, "hit": hit}
	if _strike_finished:
		_strike_finished = false
		return {"attacker": self, "target": player_ref, "hit": {}}

	# Vise le CORPS du joueur (torse ≈ œil − 0.9), jamais l'œil de la caméra :
	# avec la convention feet_y/EYE_HEIGHT 1.9, l'œil est à ~2.4 au-dessus du
	# centre d'une créature au sol — mesurer la portée sur l'œil rendait la
	# morsure (portée 1.7) PHYSIQUEMENT impossible, même collé au joueur
	# (BUG RÉEL trouvé par le test de combat, corrigé le 2026-07-21).
	# CONFUSION (F.4) : « 30 % d'agir au hasard ». Concrètement, la créature perd
	# de vue sa cible et erre — on la traite comme non engagée pour ce tick, ce
	# qui la fait retomber sur son errance normale au lieu d'inventer un
	# comportement « aléatoire » qui n'existerait nulle part ailleurs.
	if has_status("confusion") and randf() < 0.3:
		_wander(player_position)
		return {}
	var body := player_position + Vector3(0.0, -0.9, 0.0)
	var to_player := body - logical_position
	# Distance RÉELLE (3D) pour l'agression/l'attaque — une créature au sol
	# ne remarque ni n'atteint un joueur bien au-dessus d'elle (ex. en vol).
	var dist3d := to_player.length()
	var to_player_flat := to_player
	to_player_flat.y = 0.0
	var dist_flat := to_player_flat.length()

	# PORTÉE LUE DANS LE PROFIL, et modulée par la lumière et la DISCRÉTION du
	# joueur. Elle était une constante en dur, si bien que monter Discrétion ne
	# changeait rigoureusement rien : la compétence existait, aucun ennemi ne
	# s'en apercevait.
	var stealth := 0.0
	if player_ref != null and player_ref.has_method("skill_level"):
		stealth = float(player_ref.call("skill_level", "discretion"))
	_engaged = is_hostile() and dist3d <= perception_range(stealth)
	if _engaged:
		var functionality := combat_functionality()
		# ALLONGE RÉELLE, celle de la lame (2026-08-02). Le code lisait le champ
		# `portee` de la fiche — resté à 1,5 pour TOUTES les armes depuis que
		# l'allonge se déduit des pièces. Une créature tenait donc sa distance,
		# et déclarait ses coups, à un mètre cinquante alors que son fer
		# n'atteint que 1,25 m : elle frappait systématiquement dans le vide et
		# aucun de ses coups ne pouvait aboutir. Le défaut est resté caché tant
		# que la résolution était un test de rayon sur ce même champ — les deux
		# erreurs se compensaient.
		var reach := _strike_reach(functionality)
		if dist3d <= reach + 0.5:
			# À portée : DÉCLARER l'attaque, puis la porter après le wind-up
			# (2026-07-28). Frapper dans le même tick que la décision rendait
			# toute esquive impossible — le joueur n'avait littéralement pas
			# d'instant où reculer. La déclaration est publique (télégraphie
			# E.12) : c'est ce qui rend le combat lisible.
			# PAS DE NOUVELLE ATTAQUE TANT QUE LA LAME EST EN L'AIR (2026-08-02).
			# Une créature pouvait redéclarer pendant sa propre frappe : la
			# nouvelle pose écrasait la précédente, le balayage n'atteignait
			# jamais sa fin, et le coup en cours était PERDU sans jamais être
			# résolu. Constaté en instrumentant la sonde ; en jeu, le cas se
			# produit dès qu'une arme lente sort une frappe plus longue que le
			# temps de recharge de la créature.
			if _attack_cooldown_ticks <= 0 and not combat.is_empty() 					and _pose_phase != "strike":
				var stats_derived := WeaponStats.derive(functionality, {})
				# DURÉE RÉELLE de l'arme, à la milliseconde, et non plus arrondie
				# au tick supérieur : une dague à 150 ms est enfin deux fois plus
				# vive qu'une masse à 300, ce que l'arrondi à 200/300 effaçait.
				_attack_declared = true
				_windup_left_ms = float(stats_derived["windup_ms"])
				# MENACE TENUE, tirée en continu et non plus par pas de 100 ms :
				# on ne peut littéralement plus compter les temps de l'adversaire.
				_hold_left_ms = randf_range(0.0, MAX_HOLD_MS)
				var speed: float = functionality.get("vitesse_base", 1.0)
				_attack_cooldown_ticks = maxi(1, ceili(10.0 / speed))
				# DIRECTION REELLE, tiree a la declaration : sans elle le blocage
				# directionnel du joueur n'aurait rien a parer. Elle est PUBLIEE
				# par la telegraphie, donc lisible et anticipable.
				# Tirée DANS le répertoire de son arme : un garde à la lance ne
				# peut pas fauter latéralement, et le joueur peut donc apprendre
				# à lire ce qu'une arme donnée sait faire.
				var repertoire: Array = stats_derived.get("directions", [])
				attack_direction = MeleeAttack.nearest_allowed(randi() % 4, repertoire)
				# Le geste DOIT etre visible : sans lui la telegraphie est un
				# signal que le joueur ne peut pas percevoir.
				_start_pose("windup", _windup_left_ms / 1000.0)
				EventBus.attack_telegraphed.emit(self,
					MeleeAttack.direction_name(attack_direction))
		if dist_flat > 0.01:
			# JEU DE JAMBES plutôt que marche droit devant. Le mouvement reste
			# au TICK (E.1) ; une créature terrestre ne vole pas vers une cible
			# en hauteur, d'où un déplacement à plat.
			_step_footwork(to_player_flat, dist_flat, reach)
	elif is_skittish() and dist3d <= FLEE_RANGE:
		# Fuite : s'écarter du joueur, à plat (même contrainte que la
		# poursuite — une bête terrestre ne s'envole pas pour fuir).
		if dist_flat > 0.01:
			var away := -to_player_flat.normalized() * (float(stats.get("vitesse", 5)) * 0.03)
			_move_by(away)
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
		_move_by(step.normalized() * (float(stats.get("vitesse", 5)) * 0.006))
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
## Fait courir le temps de l'attaque DÉCLARÉE : armement, puis menace tenue,
## puis frappe. Appelé à la FRAME. Ne touche à aucun état de jeu — il ne fait
## que décider QUAND la lame part, exactement comme la machine à états du joueur.
func _advance_declared_attack(delta: float) -> void:
	if not _attack_declared:
		return
	var remaining_ms := delta * 1000.0
	if _windup_left_ms > 0.0:
		_windup_left_ms -= remaining_ms
		if _windup_left_ms > 0.0:
			return
		# Le RELIQUAT alimente la phase suivante : sans lui, chaque transition
		# perdrait une fraction de frame et le geste dériverait d'autant à
		# chaque coup — le défaut d'arrondi qu'on vient précisément de retirer.
		remaining_ms = -_windup_left_ms
		_windup_left_ms = 0.0
		if _hold_left_ms > 0.0:
			_start_pose("armee", _hold_left_ms / 1000.0)
	if _hold_left_ms > 0.0:
		# FEINTE, tirée à la FRAME. `_feint_chance()` était calibrée pour un
		# tirage par TICK : on la convertit en taux par seconde (×10) puis on
		# l'applique au delta. La probabilité de feinter sur une menace d'une
		# durée donnée reste donc celle d'avant — c'est la GRANULARITÉ qui
		# change, pas la fréquence. Une feinte peut désormais tomber à
		# n'importe quel instant, et non plus tous les dixièmes de seconde.
		if randf() < _feint_chance() * TickManager.TICKS_PER_SECOND * delta:
			_cancel_declared_attack()
			return
		_hold_left_ms -= remaining_ms
		if _hold_left_ms > 0.0:
			return
		_hold_left_ms = 0.0
	_release_declared_attack()


## La menace est trahie : le coup annoncé n'arrive pas. Le temps de remise est
## payé en TICKS — c'est un rythme de décision, pas une durée perçue.
func _cancel_declared_attack() -> void:
	_attack_declared = false
	_windup_left_ms = 0.0
	_hold_left_ms = 0.0
	_attack_cooldown_ticks = FEINT_RECOVERY_TICKS
	_start_pose("recover", 0.2)


## La lame PART : c'est le balayage à la frame qui dira ce qu'elle touche, et le
## tick qui appliquera. Aucun dégât n'est décidé ici.
func _release_declared_attack() -> void:
	_attack_declared = false
	_pending_strike = {}
	_strike_previous = PackedVector3Array()
	_strike_finished = false
	var derived := WeaponStats.derive(combat_functionality(), {})
	_start_pose("strike", float(derived["release_ms"]) / 1000.0)


func _advance_pose(delta: float) -> void:
	if _pose_phase == "":
		return
	_pose_time += delta
	if _pose_time < _pose_duration:
		return
	match _pose_phase:
		"garde":
			# La garde se TIENT : c'est le tick qui la baisse, pas l'horloge de
			# la pose. Une garde qui retombe seule ne se lirait pas.
			_pose_time = _pose_duration
		"armee":
			# Menace TENUE : la pose reste à son point d'armement. Elle ne
			# retombe pas d'elle-même — c'est le tick qui décide de frapper.
			_pose_time = _pose_duration
		"windup":
			# Le tick n'a pas encore libéré le coup : on TIENT la position
			# armée plutôt que d'enchaîner, sinon le geste partirait avant le
			# coup et mentirait sur le moment de l'impact.
			_pose_time = _pose_duration
		"strike":
			# La lame a fini sa course. Si elle n'a rien constaté, le tick
			# créditera l'esquive du joueur — il a bougé au bon moment.
			if _pending_strike.is_empty():
				_strike_finished = true
			_start_pose("recover", 0.25)
		_:
			_pose_phase = ""


## Vitesse VISUELLE lissée. Brute, elle serait un escalier : la position logique
## n'avance qu'au tick et `position` la rattrape par interpolation.
func _measure_velocity(delta: float) -> void:
	if delta <= 0.0001:
		return
	if _last_visual_position == Vector3.INF:
		_last_visual_position = position
		return
	var instant := (position - _last_visual_position) / delta
	_last_visual_position = position
	_velocity = _velocity.lerp(instant, minf(delta * 12.0, 1.0))


## Combien de points suivre le long de la tête d'arme, et la finesse. Mêmes
## valeurs que côté joueur : un fer est un segment, pas un point.
const STRIKE_HEAD_SAMPLES := 3
## Distance maximale qu'un point du fer peut franchir en UNE frame sans que ce
## soit une téléportation, en mètres. Généreuse à dessein : une frappe rapide
## sur une frame longue (30 im/s, soit 33 ms) déplace déjà la pointe d'un bon
## demi-mètre, et une créature qui charge y ajoute sa propre vitesse. Il ne
## s'agit pas de brider le geste, seulement d'écarter l'invraisemblable — un
## saut de plusieurs mètres, qui ne peut venir que d'un repositionnement.
const MAX_STRIKE_TRAVEL_PER_FRAME := 2.5


## Promène la TÊTE de l'arme entre la frame précédente et celle-ci, et retient
## le premier contact. Ne touche à AUCUN état de jeu — elle remplit
## `_pending_strike`, que le tick videra.
func _sweep_strike(delta: float) -> void:
	if not _pending_strike.is_empty():
		return   # un coup ne touche qu'une fois
	var player := get_node_or_null("/root/Main/Player")
	if player == null or not player.has_method("sweep_segment"):
		return
	var functionality := combat_functionality()
	if functionality.is_empty():
		return
	var stats := WeaponStats.derive(functionality, {})
	var arm: float = PlayerBody.HAND_ARC_RADIUS
	var draw: float = preload("res://scenes/entities/held_item.gd").PART_SCALE
	# MÊME portée vulnérante que le joueur, lue au même endroit.
	var span := WeaponStats.head_span(stats, arm, draw)
	var grip := position + Vector3.UP * PlayerBody.COMBAT_GRIP_HEIGHT
	# REPÈRE PRIS SUR LE LACET RÉELLEMENT AFFICHÉ. Depuis que la convention est
	# corrigée (`_yaw_towards`), le corps regarde bien sa cible : la lame peut
	# donc suivre le corps, ce qui est l'invariant qu'on veut — ce qu'on voit
	# EST ce qui frappe, orientation comprise.
	var facing := Basis.from_euler(Vector3(0.0, _visual_facing, 0.0))
	var ratio := clampf(_pose_time / maxf(_pose_duration, 0.001), 0.0, 1.0)
	var pull := (1.0 - MeleeAttack.THRUST_START) * arm

	var current := PackedVector3Array()
	for i in STRIKE_HEAD_SAMPLES:
		var distance: float = lerpf(span.x, span.y, float(i) / float(STRIKE_HEAD_SAMPLES - 1))
		current.append(MeleeAttack.point_along(
			attack_direction, ratio, grip, facing, distance, pull))
	# LE FER NE SE TÉLÉPORTE PAS (2026-08-02). Le balayage relie la position du
	# fer à la frame précédente à celle de cette frame et traite le segment comme
	# une trajectoire. C'est juste tant que la créature se DÉPLACE ; ça devient
	# faux dès qu'elle est REPOSITIONNÉE en plein coup — changement de dimension,
	# voyage rapide, réapparition, ou simplement une IA qu'on replace. Le segment
	# fait alors plusieurs mètres et transperce tout ce qui se trouve sur le
	# trajet, y compris un joueur qui n'a jamais été à portée.
	#
	# Trouvé en instrumentant la sonde d'esquive : une créature téléportée à 12 m
	# pendant sa frappe touchait encore, parce que sa lame « balayait » les douze
	# mètres en une frame. Le défaut était latent depuis le passage du balayage à
	# la frame ; le passage du geste de l'IA à la frame l'a simplement rendu
	# fréquent, en laissant plus souvent une frappe en vol entre deux ticks.
	#
	# Un saut plus grand que ce qu'un bras peut parcourir en une frame n'est donc
	# PAS une trajectoire : on repart de la nouvelle position sans rien tester.
	# Le coup n'est pas annulé — il continue depuis là où le corps se trouve
	# vraiment, ce qui est exactement ce qu'on voit à l'écran.
	var teleported := false
	if _strike_previous.size() == current.size() and current.size() > 0:
		var jump := (current[0] - _strike_previous[0]).length()
		teleported = jump > MAX_STRIKE_TRAVEL_PER_FRAME
	if _strike_previous.size() == current.size() and not teleported:
		for i in current.size():
			var hit: Dictionary = player.sweep_segment(_strike_previous[i], current[i])
			if hit.is_empty():
				continue
			# LE DÉCOR ARRÊTE LA LAME, ici aussi.
			if WorldManager.line_blocked(grip, hit["point"]):
				continue
			hit["grip_distance"] = grip.distance_to(hit["point"])
			hit["head_start"] = span.x
			hit["reach"] = span.y
			# BONUS DE VITESSE (2026-08-02) : la vitesse RELATIVE de l'arme et de
			# la cible décide, exactement comme pour le joueur. Une créature qui
			# CHARGE frappe plus fort, une créature qu'on fuit frappe moins.
			# C'était la mécanique signature de Mount & Blade qui ne marchait que
			# dans un sens, faute d'une vitesse mesurable côté créature.
			var travel: Vector3 = current[i] - _strike_previous[i]
			var nominal := travel.length() / maxf(delta, 0.0001)
			var closing := 0.0
			if travel.length_squared() > 0.000001:
				closing = _velocity.dot(travel.normalized())
			hit["speed"] = WeaponStats.speed_factor(nominal, closing)
			_pending_strike = hit
			break
	_strike_previous = current


## Distance à laquelle la POINTE de son arme arrive, mesurée depuis son corps.
## C'est la même géométrie que celle du balayage (`WeaponStats.head_span`), donc
## la distance à laquelle elle décide d'attaquer est exactement celle à laquelle
## elle touche.
func _strike_reach(functionality: Dictionary) -> float:
	if functionality.is_empty():
		return 1.5
	var stats := WeaponStats.derive(functionality, {})
	return WeaponStats.head_span(stats, PlayerBody.HAND_ARC_RADIUS,
		preload("res://scenes/entities/held_item.gd").PART_SCALE).y


## Avance d'un tick le jeu de jambes, et déplace la créature.
##
## Le pas est la somme de trois intentions, et aucune ne suffit seule :
##   RADIALE      — tenir la distance d'engagement (s'approcher ou reculer) ;
##   TANGENTIELLE — contourner, ce qui oblige le joueur à se réorienter ;
##   SÉPARATION   — s'écarter des autres, pour que chacun garde son espace.
func _step_footwork(to_player_flat: Vector3, dist_flat: float, reach: float) -> void:
	_footwork_ticks -= 1
	if _footwork_ticks <= 0:
		_choose_footwork(dist_flat, reach)
	var forward := to_player_flat / maxf(dist_flat, 0.0001)
	var side := Vector3(-forward.z, 0.0, forward.x)
	var target := reach * ENGAGE_RATIO
	var intent := Vector3.ZERO
	match _footwork:
		Footwork.APPROCHE:
			intent = forward
		Footwork.RECULE:
			intent = -forward * BACKPEDAL_FACTOR
		Footwork.CONTOURNE:
			intent = side * (_orbit_sign * STRAFE_FACTOR)
		Footwork.TIENT:
			# TENIR n'est pas rester immobile : c'est corriger la distance. Une
			# créature parfaitement figée se lit comme un décor, et surtout elle
			# cesse d'être une menace qu'on doit surveiller.
			intent = forward * clampf((dist_flat - target) / maxf(ENGAGE_SLACK, 0.01), -1.0, 1.0)
	# La distance d'engagement PRIME sur l'intention : trop loin on se rapproche
	# quoi qu'on ait décidé, trop près on se dégage. Sans cette correction, une
	# créature qui a tiré « recule » reculerait jusqu'à sortir du combat.
	if dist_flat > target + ENGAGE_SLACK:
		intent += forward
	elif dist_flat < target - ENGAGE_SLACK:
		intent -= forward
	intent += _separation() * SEPARATION_WEIGHT
	if intent.length_squared() < 0.000001:
		return
	var speed := float(stats.get("vitesse", 5)) * 0.02
	_move_by(intent.normalized() * speed)


## Tire une nouvelle intention, biaisée par la distance courante. On ne recule
## pas quand on est déjà loin, on ne s'approche pas quand on est déjà collé :
## le hasard porte sur le STYLE, jamais sur la cohérence.
func _choose_footwork(dist_flat: float, reach: float) -> void:
	_footwork_ticks = randi_range(FOOTWORK_MIN_TICKS, FOOTWORK_MAX_TICKS)
	_orbit_sign = 1.0 if randf() < 0.5 else -1.0
	var target := reach * ENGAGE_RATIO
	if dist_flat > target + ENGAGE_SLACK:
		_footwork = Footwork.APPROCHE
		return
	if dist_flat < target - ENGAGE_SLACK:
		_footwork = Footwork.RECULE
		return
	# À bonne distance : c'est là que le choix est intéressant. Contourner
	# domine — c'est ce qui donne au combat son mouvement de rotation
	# caractéristique et force le joueur à se replacer en permanence.
	var roll := randf()
	if roll < 0.45:
		_footwork = Footwork.CONTOURNE
	elif roll < 0.70:
		_footwork = Footwork.TIENT
	elif roll < 0.88:
		_footwork = Footwork.APPROCHE
	else:
		_footwork = Footwork.RECULE


## Vecteur d'écartement des autres créatures proches. Purement local : chacune
## regarde ses voisines, personne n'orchestre. C'est ce qui fait que la
## formation se défait et se refait toute seule quand le joueur se déplace.
## RAYON D'ENCOMBREMENT d'un corps, en blocs. Plus petit que `PERSONAL_SPACE`
## (1.15) exprès : la séparation douce garde les gens à distance de courtoisie,
## celui-ci n'intervient qu'au CONTACT, quand la première a échoué.
const BODY_RADIUS := 0.38


## DÉPLACEMENT D'UNE CRÉATURE — POINT DE PASSAGE UNIQUE (2026-08-09).
##
## Les trois sites qui écrivaient `logical_position +=` — poursuite, fuite,
## déambulation — passent par ici. Sans ce goulot, la règle « on ne se traverse
## pas » aurait été à recopier trois fois, et la quatrième façon de bouger
## qu'on ajoutera l'aurait oubliée. C'est le pendant exact de
## `_body_blocked_at` côté joueur.
##
## On POUSSE DEHORS plutôt qu'on ne BLOQUE, à l'inverse du joueur. Un joueur
## bloqué comprend qu'il bute sur quelqu'un et contourne ; une créature bloquée
## resterait collée à l'obstacle sans jamais le contourner, puisque son
## intention est recalculée à 10 Hz seulement. La poussée, elle, fait glisser
## les corps l'un contre l'autre — c'est ce qui donne une foule qui s'écarte au
## lieu d'une file qui se fige.
func _move_by(step: Vector3) -> void:
	logical_position = _slide(logical_position, step)
	_push_out_of_bodies()
	logical_position.y = _ground_height()


## Demi-largeur du corps pour la collision avec le DÉCOR. Volontairement plus
## petite que `BODY_RADIUS` : un villageois qui frotte les chambranles resterait
## coincé dans sa propre porte, et il n'a pas le recul du joueur pour manœuvrer.
const WALL_RADIUS := 0.30


## Applique `step` en GLISSANT le long des murs, axe par axe — la même
## résolution que le joueur, pour que « traverser un mur » veuille dire la même
## chose des deux côtés.
##
## LES CRÉATURES TRAVERSAIENT LES MURS (2026-08-09, signalé en jeu). Leur
## déplacement n'a JAMAIS consulté le terrain : il ajoutait un pas et replaquait
## `y` au sol. Le défaut est aussi vieux que la déambulation ; il ne s'est vu que
## le jour où les villageois se sont mis à fuir et à traverser leurs maisons.
##
## Une créature DÉJÀ DANS un mur n'est pas retenue — le monde est modifiable et
## l'on peut murer quelqu'un. Ne pas prévoir ce cas fige un habitant pour
## toujours, sans que rien ne le signale.
func _slide(from: Vector3, step: Vector3) -> Vector3:
	if _wall_at(from.x, from.z, from.y):
		return from + step
	var out := from
	if not _wall_at(out.x + step.x, out.z, out.y):
		out.x += step.x
	if not _wall_at(out.x, out.z + step.z, out.y):
		out.z += step.z
	return out


## Un mur occupe-t-il l'emprise du corps à cette position ? Deux niveaux : les
## pieds et la tête. La règle de solidité elle-même vit dans `WorldManager` —
## partagée avec le joueur, sans quoi le blé serait franchissable pour l'un et
## infranchissable pour l'autre.
func _wall_at(x: float, z: float, logical_y: float) -> bool:
	# `logical_position.y` EST LE CENTRE DU BLOC DE SOL (`_ground_height` rend
	# `indice + 0.5`), pas son sommet — contrairement au `feet_y` du joueur, qui
	# est la surface. Prendre l'un pour l'autre faisait lire LE SOL comme un mur :
	# la règle d'évasion s'activait alors à chaque pas et plus rien ne bloquait.
	# La sonde annonçait « un mur arrête une créature » et mesurait 4 m parcourus.
	var foot_by := floori(logical_y + 0.5 + 0.001)
	for level in [foot_by, foot_by + 1]:
		for corner_x in [-WALL_RADIUS, WALL_RADIUS]:
			for corner_z in [-WALL_RADIUS, WALL_RADIUS]:
				if WorldManager.is_body_blocking(
						Vector3i(floori(x + corner_x), level, floori(z + corner_z))):
					return true
	return false


## Écarte des corps qui se chevauchent : les autres créatures, et LE JOUEUR.
##
## Le joueur, lui, est bloqué net par `_body_blocked_at` et ne bouge donc pas
## d'ici ; c'est la créature qui cède. C'est le bon sens de la correction : le
## joueur ne doit jamais être déplacé par une décision qu'il n'a pas prise.
func _push_out_of_bodies() -> void:
	var here := logical_position
	for other in CreatureManager.creatures:
		if other == self or not is_instance_valid(other) or other.is_dead():
			continue
		if other.dimension != dimension:
			continue
		here = _pushed_out(here, other.logical_position, BODY_RADIUS * 2.0)
	# LES JOUEURS OCCUPENT DE LA PLACE EUX AUSSI. Sans ça, une créature
	# traverserait le joueur alors qu'il ne la traverse plus — et pouvait venir
	# s'arrêter DANS son corps, ce qui l'aurait emmuré si `_body_blocked_at`
	# n'avait pas sa règle d'évasion.
	#
	# Le joueur local n'est présent que dans la dimension active ; ailleurs, il
	# n'occupe rien. Les joueurs DISTANTS comptent au même titre : une partie
	# solo est une partie multijoueur à un joueur, et une règle qui ne vaudrait
	# que pour l'hôte serait à réécrire au premier invité.
	if dimension == WorldManager.active_dimension:
		here = _pushed_out(here, CreatureManager.last_player_position, BODY_RADIUS * 2.0)
	for peer_body: Node3D in NetworkManager.remote_bodies().values():
		if is_instance_valid(peer_body):
			here = _pushed_out(here, peer_body.global_position, BODY_RADIUS * 2.0)
	logical_position = here


## `point` écarté de `body` jusqu'à `min_gap`, à plat. Rien à faire s'ils ne se
## chevauchent pas — et le cas EXACTEMENT SUPERPOSÉ (gap nul) reçoit une
## direction arbitraire mais stable, faute de quoi la normalisation rendrait NAN
## et la créature disparaîtrait du monde.
func _pushed_out(point: Vector3, body: Vector3, min_gap: float) -> Vector3:
	var away := point - body
	away.y = 0.0
	var gap := away.length()
	if gap >= min_gap:
		return point
	if gap < 0.0001:
		# EXACTEMENT SUPERPOSÉS : aucune direction ne se déduit de la géométrie,
		# on en invente une — stable, dérivée de l'identité réseau, pour que
		# deux machines écartent le même corps du même côté.
		#
		# On sort ICI plutôt que de retomber dans la formule commune. Une
		# première version posait `gap = 1.0` puis appliquait `min_gap - gap` :
		# la poussée valait -0.24 m et RAPPROCHAIT les corps. Le chiffre était
		# reproductible, ce qui l'a fait passer pour un effet du décor.
		return point + Vector3(cos(float(net_id)), 0.0, sin(float(net_id))) * min_gap
	return point + (away / gap) * (min_gap - gap)


func _separation() -> Vector3:
	var push := Vector3.ZERO
	# Ne parcourt QUE les créatures de la dimension active : les autres sont
	# gelées et n'occupent aucun espace ici.
	for other in CreatureManager.creatures:
		if other == self or not is_instance_valid(other) or other.is_dead():
			continue
		if other.dimension != dimension:
			continue
		var away: Vector3 = logical_position - other.logical_position
		away.y = 0.0
		var gap := away.length()
		if gap > PERSONAL_SPACE or gap < 0.0001:
			continue
		# Plus on est proche, plus on pousse fort : deux créatures qui se
		# touchent se repoussent franchement, deux qui se frôlent s'ignorent.
		push += (away / gap) * (1.0 - gap / PERSONAL_SPACE)
	return push


## Lacet pour REGARDER dans la direction `d`.
##
## LA CONVENTION ÉTAIT INVERSÉE (corrigé le 2026-08-02). Le code posait
## `atan2(d.x, d.z)` — or une rotation de lacet θ envoie le −Z du corps sur
## `(−sin θ, 0, −cos θ)`, et l'avant du projet EST le −Z (voir le LISEZMOI des
## rigs). Avec l'ancienne formule, une créature se déplaçait donc DOS À SA
## DIRECTION DE MARCHE, et attaquait en tournant le dos à sa victime. Le défaut
## est resté invisible tant qu'aucune arme n'était portée : un corps symétrique
## marchant à reculons ne saute pas aux yeux, une lame qui part à l'opposé si.
func _yaw_towards(d: Vector3) -> float:
	return atan2(-d.x, -d.z)


## Cette créature est-elle ENGAGÉE contre le joueur ? Posé au tick par l'IA :
## `_process` tourne à la frame et n'a pas à refaire le test d'agression.
var _engaged := false


## Hauteur de sol RÉELLE sous la créature : premier bloc solide (eau exclue)
## en descendant depuis les pieds, via le monde réel routé par dimension —
## indispensable en donjon (aucun terrain généré : la hauteur procédurale
## overworld faisait tomber le boss À TRAVERS le sol de sa salle, bug latent
## corrigé le 2026-07-21) et plus juste en surface (grottes, blocs posés).
## Convention conservée : retourne l'INDICE du bloc de sol + 0.5 (comme
## l'ancien height_at()+0.5). Fenêtre bornée (~10 blocs) ; au-delà, retombe
## sur la hauteur procédurale (overworld) ou garde sa hauteur (donjon).
## Dernière hauteur de sol calculée, et la colonne où elle l'a été. Une
## créature qui déambule avance de quelques centièmes de bloc par tick : elle
## reste des dizaines de ticks dans la même colonne, et y recalculer sa hauteur
## à chaque fois est du travail refait à l'identique.
var _ground_column := Vector2i(1 << 30, 0)
var _ground_cached := 0.0


## Hauteur du sol sous la créature.
##
## DEUX CHEMINS, ET C'EST LA RAISON D'ÊTRE DE CETTE FONCTION. Quand le monde
## est chargé sous les pieds, on sonde les blocs : c'est exact, ça tient compte
## de ce que le joueur a creusé ou bâti, et ça ne coûte que des lectures de
## tableau. Quand il ne l'est PAS, chaque sondage devient une requête au
## générateur qui reconstruit la colonne entière — et il y en avait DIX par
## créature et par tick.
##
## Mesuré : 83,6 ms d'IA pour dix-huit villageois, soit 4,6 ms chacun, contre
## 1,0 ms pour cinquante bêtes sauvages. La différence n'était pas leur
## comportement, c'était que les villageois se tiennent là où le joueur vient
## d'arriver, donc dans des chunks pas encore streamés.
func _ground_height() -> float:
	var bx := floori(logical_position.x)
	var bz := floori(logical_position.z)
	var column := Vector2i(bx, bz)
	if column == _ground_column:
		return _ground_cached

	_ground_column = column
	var start := floori(logical_position.y)
	if not WorldManager.is_block_loaded(Vector3i(bx, start, bz)):
		# UNE seule requête au lieu de dix : la hauteur procédurale suffit là où
		# personne n'a encore rien pu creuser, puisque le chunk n'existe pas.
		if dimension == &"overworld" and WorldManager.generator != null:
			_ground_cached = WorldManager.generator.height_at(bx, bz) + 0.5
		else:
			_ground_cached = logical_position.y
		return _ground_cached

	var water_id: int = GameData.material_runtime_ids.get("eau", -1)
	var crosses := GameData.cross_mask
	for wy in range(start + 1, start - 9, -1):
		var id := WorldManager.block_at_world(Vector3i(bx, wy, bz))
		# LES PLANTES NE SONT PAS DU SOL. Sans ce test, un villageois qui traverse
		# une prairie marche SUR les fleurs, un demi-bloc trop haut, et flotte.
		if id != 0 and id < crosses.size() and crosses[id] == 1:
			continue
		if id != 0 and id != water_id:
			_ground_cached = float(wy) + 0.5
			return _ground_cached
	if dimension == &"overworld" and WorldManager.generator != null:
		_ground_cached = WorldManager.generator.height_at(bx, bz) + 0.5
		return _ground_cached
	_ground_cached = logical_position.y
	return _ground_cached

class_name CreatureBody
extends Node3D
## Corps ANIMÉ des créatures non humanoïdes (2026-08-02) — quadrupèdes, bipèdes,
## serpents, poissons, oiseaux, arthropodes, tentaculaires, flottants, dragons.
##
## CE FICHIER NE CONNAÎT AUCUNE ESPÈCE. Il découvre ce qu'un squelette sait
## faire en lisant le NOM de ses os, et compose les comportements qu'il y
## trouve. Ajouter un mob — six pattes, trois paires d'ailes, huit tentacules —
## ne demande donc pas une ligne ici : il suffit de nommer les os.
##
##   PATTE  : `cuisse_<sfx>` → `mollet_<sfx>` → `pied_<sfx>` (ou `serre_`,
##            `tarse_`). Chaîne de 2 os EXACTEMENT, résolue par `TwoBoneIK` et
##            ancrée sur les blocs. Le NOMBRE est libre ; le côté et l'ordre de
##            l'allure sont déduits de la POSITION des hanches au repos, jamais
##            du nom — c'est ce qui fait qu'une araignée marche sans qu'on ait
##            eu à décrire une allure d'araignée.
##   AILE   : `aile_<sfx>` → `avantaile_<sfx>` → `plume_<sfx>`, les deux
##            derniers facultatifs. Autant de paires qu'on veut.
##   SOUPLE : toute suite `<base>_1`, `<base>_2`… dont chaque os est parent du
##            suivant. Animée en ONDE propagée, l'axe étant déduit de son
##            orientation au repos : lacet pour une colonne horizontale,
##            balancement radial pour un tentacule qui pend.
##   BALLANT: un os isolé `nageoire_*`, `pince_*`, `oreille_*` oscille doucement.
##
## Un squelette sans patte **flotte** au lieu de marcher. C'est la seule
## décision prise à partir d'une absence, et elle tombe juste pour une méduse
## comme pour un spectre.
##
## POURQUOI PAS `PlayerBody`. Celui-là est le corps du JOUEUR : première
## personne, visée, armes tenues, réplication réseau. Rien de tout cela n'a de
## sens pour un poisson, et le mélanger aurait fait payer un test d'espèce par
## méthode au corps qui tourne toutes les frames. Ce qui est partagé l'est
## vraiment : le solveur `TwoBoneIK`, le cache de matériaux, et le principe du
## cycle piloté par la DISTANCE PARCOURUE — une créature qui ralentit ralentit
## ses pas, une créature à l'arrêt a les pattes au sol.
##
## AUCUNE ANIMATION N'EST LUE DEPUIS LE `.glb` : les modèles générés par
## `tools/generate_creature_rigs.py` n'en contiennent aucune, volontairement.
## Tout ce qui bouge ici est calculé — 27 espèces, zéro fichier d'animation.

## Manifeste écrit par le générateur : famille, calques de couleur et zones de
## coup de chaque modèle. Lu ICI plutôt que retapé en dur, sinon la teinte du
## modèle ouvert dans Blockbench et celle du modèle affiché en jeu divergeraient
## à la première retouche.
const MANIFEST_PATH := "res://models/creatures/rigs.json"

## Extrémités reconnues d'une chaîne de patte, dans l'ordre d'essai.
const LEG_TIPS := ["pied", "serre", "tarse"]
## Os isolés qui ballottent. Ils ne visent rien : les rigger en chaîne IK
## n'aurait rien apporté.
const FLOPPY_PREFIX := ["nageoire", "pince", "oreille"]

# --- Locomotion (mêmes principes que PlayerBody) -------------------------

## Distance parcourue pour un cycle de pas complet, mise à l'échelle de la
## créature au `setup` : une petite bête fait des pas courts. Sans ça un rat
## patinerait au ralenti et un cheval trottinerait.
const STRIDE_REACH := 0.20        # amplitude avant/arrière de la patte
const STEP_LIFT := 0.12           # hauteur à laquelle la patte se lève
const GAIT_SETTLE_SPEED := 0.12   # retour à la station debout à l'arrêt

## Profondeur de recherche du sol sous une hanche, en blocs. Au-delà, la patte
## est en l'air (saut, chute, vol) et l'IK se désactive d'elle-même.
const GROUND_SEARCH := 3

## Coude vers l'ARRIÈRE aux pattes avant, genou vers l'AVANT aux pattes
## arrière : c'est la géométrie d'un quadrupède. Sans ces pôles le triangle se
## replierait dans un plan quelconque et les pattes partiraient de côté.
const POLE_FRONT := Vector3(0.0, 0.0, 1.0)
const POLE_REAR := Vector3(0.0, 0.0, -1.0)
## Décalage de phase d'une paire de pattes à la suivante. PI donne exactement le
## trot diagonal d'un quadrupède (avant-droit avec arrière-gauche) ; au-delà de
## deux paires, le petit supplément transforme l'alternance en onde qui court le
## long du corps — c'est la démarche d'un mille-pattes.
const PAIR_PHASE := PI
const PAIR_WAVE := 0.35

## Ondulation des chaînes souples.
const WAVE_AMPLITUDE := deg_to_rad(16.0)   # lacet par segment, en mouvement
const WAVE_IDLE := 0.28                    # part conservée à l'arrêt : un
                                           # serpent immobile respire encore
const WAVE_LAG := 0.85                     # retard d'un segment au suivant —
                                           # c'est lui qui fait une ONDE et non
                                           # un balancier rigide
const WAVE_SPEED := 5.0                    # rad/s de l'ondulation de repos
## Une colonne porte l'onde principale ; un cou ou une queue ne doit que la
## prolonger, sinon la créature se tortille de partout.
const WAVE_SECONDARY := 0.55

## Battement d'aile. L'amplitude est large parce qu'une aile qui bat peu se lit
## comme une aile cassée ; le retard vers l'extrémité donne la souplesse.
const FLAP_AMPLITUDE := deg_to_rad(48.0)
const FLAP_SPEED := 7.0
const FLAP_LAG := 0.55
## Battement RÉSIDUEL au sol : à zéro l'oiseau se fige en croix.
const GLIDE_AMPLITUDE := deg_to_rad(7.0)

## Ballant des appendices libres. Décoratif, mais c'est ce qui sépare une
## créature d'une statue.
const FLOPPY_AMPLITUDE := deg_to_rad(11.0)
const FLOPPY_SPEED := 2.2

## Sustentation d'un corps sans patte (méduse, spectre) : il respire et dérive
## au lieu de rester planté.
const HOVER_HEIGHT := 0.07
const HOVER_SPEED := 1.3
const HOVER_ROLL := deg_to_rad(5.0)

## CULLING (budget Intel UHD 620), même politique que `PlayerBody` : l'IK est
## bon marché à l'unité, ruineuse par le nombre. Au-delà, la créature garde sa
## pose de repos — personne ne le verra.
const IK_MAX_DISTANCE := 15.0

var family := ""
var ik_enabled := true

var _skeleton: Skeleton3D
var _meshes := {}                 # nom -> MeshInstance3D
## Pattes : { "indices", "l1", "l2", "sole", "pole", "phase" }.
var _legs: Array[Dictionary] = []
## Chaînes souples : { "indices", "axis": Vector3, "gain": float }.
var _chains: Array[Dictionary] = []
## Ailes : { "indices", "mirror": float }.
var _wings: Array[Dictionary] = []
var _floppy: Array[int] = []
var _lunge_bones: Array[int] = []
var _stride := 1.1
var _walks := false

var _gait_phase := 0.0
var _gait_amount := 0.0
var _move_direction := Vector3.FORWARD
var _last_ground_position := Vector3.ZERO
var _has_last_position := false
var _time := 0.0
var _frame_delta := 1.0 / 60.0
var _airborne := false

## Manifeste chargé une seule fois pour tout le jeu : vingt créatures qui
## apparaissent ne doivent pas relire et reparser le même JSON vingt fois.
static var _manifest := {}


## Construit le corps depuis un `.glb`. Retourne false si le modèle est absent
## ou sans squelette — l'appelant retombe alors sur sa capsule, même politique
## que `PlayerBody.setup`.
func setup(model_path: String) -> bool:
	if not ResourceLoader.exists(model_path):
		push_warning("CreatureBody : modèle introuvable « %s »." % model_path)
		return false
	var scene: PackedScene = load(model_path)
	if scene == null:
		return false
	var instance := scene.instantiate()
	add_child(instance)
	_skeleton = _find_skeleton(instance)
	if _skeleton == null:
		push_warning("CreatureBody : « %s » n'a pas de Skeleton3D — rig invalide." % model_path)
		return false
	_collect_meshes(instance)
	var entry := species_entry(model_path)
	family = String(entry.get("famille", ""))
	_apply_skin(entry)
	_map_bones()
	# Un rig sans AUCUNE capacité reconnue ne s'animerait jamais : mieux vaut le
	# dire au chargement que laisser une statue en jeu.
	if _legs.is_empty() and _chains.is_empty() and _wings.is_empty() and _floppy.is_empty():
		push_warning("CreatureBody : « %s » n'expose aucune capacité animable — vérifier le nommage des os." % model_path)
	return true


## Entrée de manifeste d'un modèle, ou {} s'il n'y figure pas. Statique : les
## zones de coup sont lues par `creature.gd` avant même qu'un corps existe.
static func species_entry(model_path: String) -> Dictionary:
	if _manifest.is_empty():
		_manifest = {"especes": {}}
		if ResourceLoader.exists(MANIFEST_PATH):
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
			if parsed is Dictionary:
				_manifest = parsed
	var all: Dictionary = _manifest.get("especes", {})
	return all.get(model_path.get_file().get_basename(), {})


## Zones de coup du modèle, telles que CALCULÉES sur sa géométrie par le
## générateur. Elles ne peuvent pas vivre ailleurs sans se désynchroniser : une
## boîte saisie à la main cesserait d'être vraie à la première retouche de
## proportion.
static func hitboxes_for(model_path: String) -> Array:
	return species_entry(model_path).get("hitboxes", [])


## Peau procédurale par CALQUE (dos / ventre / pattes / détail). Le `.glb` n'a
## aucune texture et Godot ne reprend pas ses couleurs par sommet — sans ça la
## créature sort entièrement BLANCHE. Les matériaux passent par le cache partagé
## de `PlayerBody` : deux loups partagent leurs matériaux, et aucun upload GPU
## n'est payé au moment où une créature apparaît.
func _apply_skin(entry: Dictionary) -> void:
	var palette: Dictionary = entry.get("palette", {})
	var layers: Dictionary = entry.get("calques", {})
	for mesh_name: String in _meshes:
		var rgb: Variant = palette.get(String(layers.get(mesh_name, "dos")))
		var color := Color(0.55, 0.5, 0.45)
		if rgb is Array and (rgb as Array).size() >= 3:
			color = Color(rgb[0], rgb[1], rgb[2])
		(_meshes[mesh_name] as MeshInstance3D).material_override = \
			PlayerBody.tinted_material(color)


# --- Découverte des capacités -------------------------------------------

func _map_bones() -> void:
	var names: Array[String] = []
	for i in _skeleton.get_bone_count():
		names.append(_skeleton.get_bone_name(i))
	_map_legs(names)
	_map_wings(names)
	_map_chains(names)
	_map_floppy(names)
	_map_lunge(names)
	_walks = not _legs.is_empty()


func _map_legs(names: Array[String]) -> void:
	for root: String in names:
		if not root.begins_with("cuisse"):
			continue
		var suffix := root.substr("cuisse".length())
		var mid := "mollet" + suffix
		var tip := ""
		for candidate: String in LEG_TIPS:
			if (candidate + suffix) in names:
				tip = candidate + suffix
				break
		if tip == "" or not (mid in names):
			continue
		var indices: Array[int] = [_skeleton.find_bone(root), _skeleton.find_bone(mid),
			_skeleton.find_bone(tip)]
		# La chaîne DOIT faire deux os : c'est ce qui autorise le solveur
		# analytique. Une chaîne rompue est ignorée plutôt que résolue de
		# travers — une patte figée se voit moins qu'une patte disloquée.
		if _skeleton.get_bone_parent(indices[1]) != indices[0] \
				or _skeleton.get_bone_parent(indices[2]) != indices[1]:
			push_warning("CreatureBody : chaîne « %s » rompue — patte ignorée." % root)
			continue
		var hip := _skeleton.get_bone_global_rest(indices[0]).origin
		var mid_rest := _skeleton.get_bone_global_rest(indices[1]).origin
		var tip_rest := _skeleton.get_bone_global_rest(indices[2]).origin
		_legs.append({
			"indices": indices,
			"l1": hip.distance_to(mid_rest),
			"l2": mid_rest.distance_to(tip_rest),
			# La SEMELLE touche le bloc, pas l'origine de l'os : au repos le
			# modèle est posé au sol, donc la hauteur de l'extrémité EST cet écart.
			"sole": tip_rest.y,
			"x": hip.x, "z": hip.z,
			"pole": POLE_REAR, "phase": 0.0,
		})
	_assign_gait()


## Répartit l'allure D'APRÈS LA GÉOMÉTRIE : côté par le signe de X, rang par la
## profondeur Z. Aucun nom n'est interprété, donc six ou huit pattes marchent
## sans que rien n'ait été écrit pour elles.
func _assign_gait() -> void:
	if _legs.is_empty():
		return
	_legs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["z"]) < float(b["z"]))
	var pair := 0
	var previous_z: float = float(_legs[0]["z"])
	var pairs := 1
	for leg: Dictionary in _legs:
		if absf(float(leg["z"]) - previous_z) > 0.01:
			pair += 1
			previous_z = float(leg["z"])
			pairs += 1
		leg["pair"] = pair
	var extra := 0.0 if pairs <= 2 else PAIR_WAVE
	for leg: Dictionary in _legs:
		# Gauche et droite en opposition, puis chaque paire décalée : à deux
		# paires c'est le trot diagonal, à quatre l'alternance en tétrapode
		# d'une araignée, à huit l'onde d'un mille-pattes.
		var left := 1.0 if float(leg["x"]) < 0.0 else 0.0
		leg["phase"] = left * PI + float(leg["pair"]) * (PAIR_PHASE + extra)
		# Le coude d'une patte AVANT pointe en arrière, le genou d'une patte
		# arrière vers l'avant. Sur un bipède il n'y a qu'un rang : genou avant.
		leg["pole"] = POLE_FRONT if (pairs > 1 and int(leg["pair"]) < pairs - 1) else POLE_REAR
	# Le cycle est mis à l'échelle de la PLUS LONGUE patte : sans ça un rat
	# patinerait au ralenti et un cheval trottinerait. Le plancher évite qu'une
	# patte minuscule ne fasse tourner le cycle à une vitesse absurde.
	var longest := 0.0
	for leg: Dictionary in _legs:
		longest = maxf(longest, float(leg["l1"]) + float(leg["l2"]))
	_stride = maxf(0.35, longest * 1.5)


func _map_wings(names: Array[String]) -> void:
	for root: String in names:
		if not root.begins_with("aile_"):
			continue
		var suffix := root.substr("aile".length())
		var indices: Array[int] = [_skeleton.find_bone(root)]
		for part: String in ["avantaile" + suffix, "plume" + suffix]:
			var index := _skeleton.find_bone(part)
			if index >= 0:
				indices.append(index)
		# Le côté gauche bat en MIROIR : même angle, sens opposé, sinon les deux
		# ailes partiraient du même côté et l'oiseau ramerait de travers. Il est
		# déduit de la position au repos, pas du nom.
		var mirror := -1.0 if _skeleton.get_bone_global_rest(indices[0]).origin.x < 0.0 else 1.0
		_wings.append({"indices": indices, "mirror": mirror})


## Repère les chaînes `<base>_1..N` et déduit l'axe de leur onde de leur
## ORIENTATION AU REPOS. C'est ce qui permet à une même fonction de faire onduler
## une colonne de serpent en lacet et un tentacule de méduse en balancement
## radial : la géométrie dit ce que le mouvement doit être.
func _map_chains(names: Array[String]) -> void:
	var groups := {}
	for bone_name: String in names:
		var cut := bone_name.rfind("_")
		if cut <= 0:
			continue
		var index := bone_name.substr(cut + 1)
		if not index.is_valid_int():
			continue
		var base := bone_name.substr(0, cut)
		if not groups.has(base):
			groups[base] = []
		(groups[base] as Array).append(index.to_int())
	for base: String in groups:
		var numbers: Array = groups[base]
		numbers.sort()
		if numbers.size() < 2 or numbers[0] != 1:
			continue
		var indices: Array[int] = []
		var broken := false
		for n: int in numbers:
			var index := _skeleton.find_bone("%s_%d" % [base, n])
			if index < 0 or (not indices.is_empty() and _skeleton.get_bone_parent(index) != indices[-1]):
				broken = true
				break
			indices.append(index)
		if broken or indices.size() < 2:
			continue
		var first := _skeleton.get_bone_global_rest(indices[0]).origin
		var last := _skeleton.get_bone_global_rest(indices[-1]).origin
		var direction := last - first
		if direction.length_squared() < 0.000001:
			continue
		direction = direction.normalized()
		var axis := Vector3.UP
		if absf(direction.y) > 0.7:
			# Chaîne qui PEND (ou monte) : elle doit balancer dans le plan
			# radial, vers l'extérieur et vers l'intérieur. L'axe est donc
			# perpendiculaire à son écart au centre du corps.
			var radial := Vector3(first.x, 0.0, first.z)
			axis = Vector3(-radial.z, 0.0, radial.x)
			axis = axis.normalized() if axis.length_squared() > 0.0001 else Vector3.RIGHT
		_chains.append({
			"indices": indices, "axis": axis,
			# La colonne porte l'onde principale ; un cou ou une queue ne fait
			# que la prolonger, sinon la créature se tortille de partout.
			"gain": 1.0 if base == "corps" else WAVE_SECONDARY,
		})


func _map_floppy(names: Array[String]) -> void:
	for bone_name: String in names:
		# Un membre d'une chaîne finit par `_<n>` : il est déjà animé en onde.
		var cut := bone_name.rfind("_")
		if cut > 0 and bone_name.substr(cut + 1).is_valid_int():
			continue
		for prefix: String in FLOPPY_PREFIX:
			if bone_name.begins_with(prefix):
				_floppy.append(_skeleton.find_bone(bone_name))
				break


## Os qui portent le geste d'attaque : le cou s'il existe, sinon le premier
## segment de colonne, puis la tête.
func _map_lunge(names: Array[String]) -> void:
	for candidate: String in ["cou", "cou_1", "corps_1"]:
		if candidate in names:
			_lunge_bones.append(_skeleton.find_bone(candidate))
			break
	var head := _skeleton.find_bone("tete")
	if head >= 0:
		_lunge_bones.append(head)


# --- Pilotage ------------------------------------------------------------

## Une frame de vie : pose, avancement du cycle et animation. MÊME SIGNATURE que
## `PlayerBody.update_as_entity` — `creature.gd` appelle l'un ou l'autre sans
## savoir lequel il tient.
func update_as_entity(feet_position: Vector3, yaw: float, viewer_position: Vector3,
		delta: float = 1.0 / 60.0) -> void:
	_frame_delta = delta
	_time += delta
	global_position = feet_position
	rotation.y = yaw
	rotation.z = 0.0
	_advance_gait(feet_position)
	update_ik_culling(viewer_position)
	# Le fondu de la pose de combat court MÊME hors IK : elle est repoussée à
	# zéro quand plus personne n'attaque, sinon une créature cullée en pleine
	# morsure reviendrait figée le nez en avant.
	_pose_amount = move_toward(_pose_amount, 0.0, delta * POSE_FADE)
	if not ik_enabled:
		return
	# Les capacités se COMPOSENT : un dragon marche, ondule et bat des ailes
	# parce qu'il a les trois, sans qu'aucune ne sache que les autres existent.
	#
	# L'ORDRE COMPTE. L'ondulation bouge la colonne, donc les HANCHES ; l'IK des
	# pattes doit donc passer APRÈS, sinon elle ancrerait les pieds sous des
	# hanches qui se déplacent ensuite et les pattes glisseraient sur le sol.
	if not _chains.is_empty():
		_undulate()
	if not _wings.is_empty():
		_flap()
	if not _floppy.is_empty():
		_sway_floppy()
	if _walks:
		_airborne = not _wings.is_empty() and is_nan(_surface_under(feet_position + Vector3.UP * 0.2))
		if _airborne:
			_tuck_legs()
		else:
			_animate_legs()
	else:
		_hover()
	_apply_attack_pose()


## Avance le cycle en fonction de la DISTANCE réellement parcourue, jamais du
## temps : c'est ce qui fait qu'une créature immobile a les pattes au sol et
## qu'une créature qui ralentit ralentit ses pas.
func _advance_gait(feet_position: Vector3) -> void:
	if not _has_last_position:
		_last_ground_position = feet_position
		_has_last_position = true
		return
	var step := feet_position - _last_ground_position
	step.y = 0.0
	_last_ground_position = feet_position
	var distance := step.length()
	# Sous quelques millimètres par frame c'est du bruit numérique, pas de la
	# marche : le seuil évite qu'une créature à l'arrêt frémisse indéfiniment.
	if distance > 0.0015:
		# Une téléportation (voyage rapide, apparition) ne doit pas compter
		# comme des milliers de pas parcourus en une frame.
		if distance < 1.0:
			_move_direction = step / distance
			_gait_phase = fmod(_gait_phase + distance / _stride * TAU, TAU)
		_gait_amount = minf(_gait_amount + GAIT_SETTLE_SPEED, 1.0)
	else:
		_gait_amount = maxf(_gait_amount - GAIT_SETTLE_SPEED, 0.0)
		if _gait_amount <= 0.0:
			_gait_phase = 0.0


## Coupe l'IK au-delà d'une certaine distance du joueur. Retourne l'état.
func update_ik_culling(viewer_position: Vector3) -> bool:
	ik_enabled = global_position.distance_to(viewer_position) <= IK_MAX_DISTANCE
	return ik_enabled


# --- Pattes --------------------------------------------------------------

## Ancre chaque patte sur le BLOC qu'elle touche et y superpose le cycle de pas.
## Sur un terrain en escalier, sans ça une patte flotte pendant qu'une autre
## s'enfonce — le défaut le plus visible d'une créature dans un monde voxel.
##
## La hauteur du sol vient d'une descente de blocs, PAS d'un RayCast3D : le
## projet n'a aucun collider, et c'est aussi ce qui rend la requête bon marché.
func _animate_legs() -> void:
	var world_inverse := _skeleton.global_transform.affine_inverse()
	for leg: Dictionary in _legs:
		var indices: Array = leg["indices"]
		var hip_local: Vector3 = _skeleton.get_bone_global_pose(indices[0]).origin
		var hip_world: Vector3 = _skeleton.global_transform * hip_local
		var reach: float = float(leg["l1"]) + float(leg["l2"])
		var surface := _surface_under(hip_world)
		if is_nan(surface):
			# SANS APPUI (bord de bloc, saut, chute) : la patte PEND, tendue vers
			# le bas. Lui laisser sa pose de repos la ferait rester pliée comme
			# si elle prenait appui sur un sol inexistant.
			_solve_leg(leg, hip_local, hip_local + Vector3.DOWN * reach)
			continue
		var foot := Vector3(hip_world.x, surface + float(leg["sole"]), hip_world.z)
		if _gait_amount > 0.0:
			var phase: float = _gait_phase + float(leg["phase"])
			foot += _move_direction * (cos(phase) * STRIDE_REACH * _gait_amount)
			# La patte ne se lève que sur la moitié « en vol » du cycle ; sur
			# l'autre moitié elle reste PLAQUÉE au bloc, ce que l'IK de sol
			# garantit justement.
			foot.y += maxf(sin(phase), 0.0) * STEP_LIFT * _gait_amount
		_solve_leg(leg, hip_local, world_inverse * foot)


func _solve_leg(leg: Dictionary, hip_local: Vector3, foot_local: Vector3) -> void:
	var indices: Array = leg["indices"]
	var result := TwoBoneIK.solve(hip_local, foot_local, leg["l1"], leg["l2"], leg["pole"])
	TwoBoneIK.apply_global_basis(_skeleton, indices[0], result["upper"])
	TwoBoneIK.apply_global_basis(_skeleton, indices[1], result["lower"])


## Pattes REPLIÉES en vol. Un rapace en vol ne laisse pas ses serres pendre : il
## les ramène sous la queue, et c'est ce qui distingue au premier coup d'œil un
## animal qui vole d'un animal qui se pose.
func _tuck_legs() -> void:
	for leg: Dictionary in _legs:
		var indices: Array = leg["indices"]
		_skeleton.set_bone_pose_rotation(indices[0], Quaternion(Vector3.RIGHT, deg_to_rad(70.0)))
		_skeleton.set_bone_pose_rotation(indices[1], Quaternion(Vector3.RIGHT, deg_to_rad(-110.0)))


## Sustentation d'un corps sans patte. Il respire et roule doucement au lieu de
## rester planté au sol comme un décor.
func _hover() -> void:
	position.y += (sin(_time * HOVER_SPEED) * 0.5 + 0.5) * HOVER_HEIGHT
	rotation.z = sin(_time * HOVER_SPEED * 0.7) * HOVER_ROLL


## Sommet du premier bloc plein sous `position`, ou NAN si rien à portée.
func _surface_under(position: Vector3) -> float:
	var bx := floori(position.x)
	var bz := floori(position.z)
	var start := floori(position.y)
	# Ligne NON CHARGÉE = air, SANS interroger le générateur. Cette fonction
	# court PAR PATTE ET PAR FRAME ; sur un chunk pas encore streamé, chaque
	# lecture reconstruirait la colonne entière (le coût qui a porté l'IA à
	# 300-600 ms par tick au bench du 2026-08-09, ici en pire : à la frame).
	# Le test est PAR LIGNE et non en tête de fonction : la hanche vit souvent
	# dans le chunk d'air au-dessus de la bande stockée (jamais en mémoire),
	# alors que le sol en dessous, lui, est bien chargé.
	for wy in range(start, start - GROUND_SEARCH - 1, -1):
		var pos := Vector3i(bx, wy, bz)
		if not WorldManager.is_block_loaded(pos):
			continue
		if WorldManager.block_at_world(pos) != 0:
			return float(wy + 1)   # sommet du bloc, comme la collision
	return NAN


# --- Chaînes souples -----------------------------------------------------

## Onde propagée le long de chaque chaîne. Le retard de phase d'un maillon au
## suivant est ce qui en fait une onde plutôt qu'un balancier rigide : sans lui,
## tout le corps partirait du même côté au même instant.
##
## L'amplitude suit la vitesse mais ne tombe jamais à zéro : une créature
## parfaitement immobile se lit comme un décor, pas comme un être vivant.
func _undulate() -> void:
	var amount: float = lerpf(WAVE_IDLE, 1.0, _gait_amount)
	# La phase avance avec la DISTANCE quand la créature avance, et avec le
	# TEMPS quand elle stationne — sinon le mouvement de repos se figerait.
	var phase := _gait_phase + _time * WAVE_SPEED * (1.0 - _gait_amount)
	for chain: Dictionary in _chains:
		var indices: Array = chain["indices"]
		var axis: Vector3 = chain["axis"]
		var gain: float = chain["gain"]
		for i in indices.size():
			var angle := sin(phase - float(i) * WAVE_LAG) * WAVE_AMPLITUDE * amount * gain
			_skeleton.set_bone_pose_rotation(indices[i], Quaternion(axis, angle))


func _sway_floppy() -> void:
	var speed := FLOPPY_SPEED * (1.0 + _gait_amount)
	for i in _floppy.size():
		var angle := sin(_time * speed - float(i) * 0.7) * FLOPPY_AMPLITUDE
		_skeleton.set_bone_pose_rotation(_floppy[i], Quaternion(Vector3.UP, angle))


# --- Ailes ---------------------------------------------------------------

## Battement, ou repos si l'animal est posé. La rotation est prise autour de Z
## parce que les ailes sont étalées le long de X au repos (voir le générateur) :
## c'est l'axe qui les fait monter et descendre. Le retard croissant vers
## l'extrémité donne la souplesse — une aile qui pivote d'un bloc se lit comme
## une planche.
func _flap() -> void:
	var amplitude := GLIDE_AMPLITUDE
	if _airborne or not _walks:
		amplitude = lerpf(GLIDE_AMPLITUDE, FLAP_AMPLITUDE, maxf(_gait_amount, 0.35))
	var phase := _time * FLAP_SPEED
	for wing: Dictionary in _wings:
		var indices: Array = wing["indices"]
		var mirror: float = wing["mirror"]
		for i in indices.size():
			var angle := sin(phase - float(i) * FLAP_LAG) * amplitude * mirror
			_skeleton.set_bone_pose_rotation(indices[i], Quaternion(Vector3.BACK, angle))


# --- Pose de combat ------------------------------------------------------

## QUATRE GESTES DISTINCTS, un par direction (2026-08-02, demande de l'auteur :
## « les animaux attaquent avec les directions également »).
##
## POURQUOI ÇA NE POUVAIT PAS RESTER UN RAMASSÉ UNIQUE. Le combat demande au
## joueur de parer la DIRECTION du coup qui arrive, et le blocage consultait
## bien celle de la bête — mais son corps n'en montrait rien. On exigeait donc
## du joueur qu'il lise une information invisible : un pile ou face déguisé en
## duel. Quatre attaques réclament quatre gestes.
##
## Chaque direction est un AXE et deux angles : où le corps se ramasse pendant
## le wind-up, où il se détend à la frappe. Le vocabulaire est celui de l'animal
## et non de l'escrime — une bête ne taille pas, elle fauche ; elle n'estoque
## pas, elle mord droit devant.
##   estoc    : la tête recule puis se PROJETTE droit devant (morsure)
##   overhead : l'animal se CABRE puis s'abat de tout son poids (bond)
##   tailles  : la tête part d'un côté et FAUCHE en travers (coup de patte,
##              coup de queue, morsure latérale)
##
## Les clés sont les valeurs de `MeleeAttack.Direction` :
## 0 = estoc, 1 = taille gauche, 2 = taille droite, 3 = overhead.
const ATTACK_POSES := {
	0: {"axe": Vector3.RIGHT, "arme": -32.0, "frappe": 46.0, "avance": 0.26, "monte": 0.0},
	1: {"axe": Vector3.UP, "arme": -50.0, "frappe": 58.0, "avance": 0.12, "monte": 0.0},
	2: {"axe": Vector3.UP, "arme": 50.0, "frappe": -58.0, "avance": 0.12, "monte": 0.0},
	3: {"axe": Vector3.RIGHT, "arme": -58.0, "frappe": 62.0, "avance": 0.10, "monte": 0.22},
}

## Abaissement du corps pendant le ramassé. C'est lui qui se lit en premier et
## de loin, avant même l'angle de la tête : une bête qui se tasse va bondir.
const LUNGE_CROUCH := 0.12
## Résorption de la pose quand plus personne ne l'entretient, par seconde.
const POSE_FADE := 4.0

## Pose courante : intensité (0 = repos), axe et angle retenus de la dernière
## direction jouée. Conservés parce que la pose continue de se résorber pendant
## des frames où l'appelant ne dit plus rien.
var _pose_amount := 0.0
var _pose_axis := Vector3.RIGHT
var _pose_angle := 0.0
var _pose_advance := 0.0
var _pose_rise := 0.0
var _pose_crouch := 0.0


## Télégraphie l'attaque. Même rôle et même signature que
## `PlayerBody.set_combat_pose` : `creature.gd` appelle sans savoir quel corps
## il tient.
##
## POURQUOI ÇA COMPTE. Les créatures déclarent leur direction et attendent un
## wind-up entier avant de frapper, mais rien ne le MONTRAIT : le joueur
## recevait un signal qu'il ne pouvait pas percevoir. Ce geste est ce qui rend
## la parade jouable contre un loup.
func set_combat_pose(direction: int, ratio: float, phase: String) -> void:
	if _skeleton == null or not ik_enabled:
		return
	var pose: Dictionary = ATTACK_POSES.get(direction, ATTACK_POSES[0])
	var clamped := clampf(ratio, 0.0, 1.0)
	var armed := float(pose["arme"])
	var struck := float(pose["frappe"])
	_pose_axis = pose["axe"]
	_pose_amount = 1.0
	match phase:
		"windup":
			# SE RAMASSE : c'est le signal, et il dure tout le wind-up.
			_pose_angle = lerpf(0.0, armed, clamped)
			_pose_crouch = clamped
			_pose_advance = 0.0
			_pose_rise = float(pose["monte"]) * clamped
		"garde":
			# Une bête ne pare pas avec une lame : elle se DÉTOURNE et présente
			# son flanc ou son épaule du côté couvert. L'angle est celui de la
			# direction gardée, à mi-amplitude — assez pour se lire, pas assez
			# pour ressembler à une attaque.
			_pose_angle = armed * 0.55
			_pose_crouch = 0.7
			_pose_advance = 0.0
			_pose_rise = 0.0
		"armee":
			# MENACE TENUE : la bête reste tassée, prête à bondir. C'est le
			# moment où le joueur choisit sa garde.
			_pose_angle = armed
			_pose_crouch = 1.0
			_pose_advance = 0.0
			_pose_rise = float(pose["monte"])
		"strike":
			_pose_angle = lerpf(armed, struck, clamped)
			_pose_crouch = 1.0 - clamped
			# L'avance culmine au MILIEU de la frappe puis se résorbe : la bête
			# se jette en avant et se replace, elle ne téléporte pas son corps.
			_pose_advance = float(pose["avance"]) * sin(clamped * PI)
			_pose_rise = float(pose["monte"]) * (1.0 - clamped)
		"recover":
			_pose_angle = lerpf(struck, 0.0, clamped)
			_pose_crouch = 0.0
			_pose_advance = float(pose["avance"]) * (1.0 - clamped) * 0.3
			_pose_rise = 0.0
	_apply_attack_pose()


## Applique la pose courante. Extrait parce qu'elle doit continuer de se
## résorber les frames où plus personne n'appelle `set_combat_pose` — sinon une
## bête cullée en pleine morsure reviendrait figée le nez en avant.
func _apply_attack_pose() -> void:
	if is_zero_approx(_pose_amount) or _lunge_bones.is_empty():
		return
	position.y -= LUNGE_CROUCH * _pose_crouch * _pose_amount
	position.y += _pose_rise * _pose_amount
	# L'avance est prise dans le repère du CORPS : une morsure part vers l'avant
	# de la bête, pas vers l'avant du monde.
	position += global_transform.basis.z * (-_pose_advance * _pose_amount)
	var angle := deg_to_rad(_pose_angle) * _pose_amount / float(_lunge_bones.size())
	for index: int in _lunge_bones:
		# COMPOSÉ avec la pose courante et non écrasé : sur un serpent, le
		# premier segment porte DÉJÀ l'ondulation, et la remplacer casserait
		# l'onde en pleine attaque.
		_skeleton.set_bone_pose_rotation(index,
			_skeleton.get_bone_pose_rotation(index) * Quaternion(_pose_axis, angle))


# --- Divers --------------------------------------------------------------

## Point d'accrochage nommé (`attach_tete`, `attach_dos`) : selle, sacoche,
## trophée. Les os existent sur tous les rigs.
func attachment(bone: String) -> BoneAttachment3D:
	if _skeleton == null or _skeleton.find_bone(bone) < 0:
		return null
	var node := BoneAttachment3D.new()
	_skeleton.add_child(node)
	node.bone_name = bone
	return node


func skeleton() -> Skeleton3D:
	return _skeleton


## Capacités découvertes, pour la sonde de vérification.
func capabilities() -> Dictionary:
	return {"pattes": _legs.size(), "ailes": _wings.size(),
		"chaines": _chains.size(), "ballants": _floppy.size(), "marche": _walks}


func mesh_names() -> Array:
	return _meshes.keys()


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null


func _collect_meshes(node: Node) -> void:
	if node is MeshInstance3D:
		_meshes[String(node.name)] = node
	for child in node.get_children():
		_collect_meshes(child)

class_name PlayerBody
extends Node3D
## Corps visible du joueur (2026-07-28) — première personne AVEC corps réel
## (pieds et bras), et avatar des autres joueurs en multijoueur. Le même nœud
## sert aux deux : un joueur distant est le même corps, piloté par le réseau
## au lieu de la caméra locale.
##
## POURQUOI CE N'EST PAS LA CAMÉRA QUI PORTE LE CORPS. `FlyCamera` est
## l'autorité de position ET de collision : sa `position.y` est lue par
## `_body_blocked_at`, `_try_step_up` et le balayage de chute. Y greffer un
## corps, ou pire y introduire un décalage visuel, rouvrirait exactement la
## classe de bugs de dérive flottante corrigée le 2026-07-21 (« le joueur se
## bloque, il faut constamment sauter »). Le corps est donc un nœud SÉPARÉ qui
## se contente de SUIVRE la caméra : `fly_camera.gd` n'est pas modifié d'une
## ligne, et aucun bug de rendu ne peut devenir un bug de collision.
##
## Le modèle et le nommage des os viennent de models/creatures/LISEZMOI.md.

const MODEL_PATH := "res://models/creatures/humanoide.glb"

## Maillages masqués pour le joueur LOCAL. La tête, évidemment (la caméra est
## dans le crâne). Mais AUSSI le haut du torse, le cou et les épaules : à
## hauteur d'œil ils se trouvent à 40 cm sous l'objectif et OCCULTENT la moitié
## de l'écran dès qu'on baisse le regard (constaté en jeu le 2026-07-28 —
## captures utilisateur : une masse claire remplissait la vue).
## Ce qu'on doit voir de soi-même, c'est le BASSIN, les JAMBES et les BRAS.
## Tout reste visible pour les autres joueurs — d'où la nécessité que ce soient
## des objets distincts (contrainte de rig, LISEZMOI section 4).
## VISIBILITÉ LOCALE PAR LISTE BLANCHE (2026-07-28, demande explicite : « affiche
## uniquement les jambes et le (ou les) bras utilisés »). Une liste NOIRE ne
## suffisait plus : le bras inutilisé doit disparaître quand l'arme est à une
## main, ce qui dépend de l'équipement et change en cours de partie.
##
## Tout le reste du corps (tête, cou, torse, bassin, bras inutilisé) est masqué
## POUR SOI seulement : à moins d'un mètre de l'objectif, ces pièces ne se
## lisent plus comme un corps mais comme des plaques de couleur qui bouchent la
## vue. Les autres joueurs, eux, voient le corps entier.
const LOCAL_LEG_MESHES := [
	"mesh_cuisse_droite", "mesh_mollet_droite", "mesh_pied_droite",
	"mesh_cuisse_gauche", "mesh_mollet_gauche", "mesh_pied_gauche",
]
const LOCAL_ARM_MESHES := {
	"droite": ["mesh_bras_droit", "mesh_avantbras_droit", "mesh_main_droite"],
	"gauche": ["mesh_bras_gauche", "mesh_avantbras_gauche", "mesh_main_gauche"],
}

## Palette par défaut (peau / cheveux / haut / bas), reprise de
## `player_model.gd` pour que le placeholder de carte et le corps 3D
## s'accordent. Surchargeable à la création de personnage (12).
const DEFAULT_PALETTE := {
	"peau": Color(0.85, 0.68, 0.52), "cheveux": Color(0.35, 0.22, 0.12),
	"haut": Color(0.30, 0.45, 0.75), "bas": Color(0.35, 0.28, 0.22),
}

## Quel calque de la palette teinte quel maillage.
const MESH_LAYER := {
	"mesh_tete": "peau", "mesh_cou": "peau",
	"mesh_main_droite": "peau", "mesh_main_gauche": "peau",
	"mesh_avantbras_droit": "peau", "mesh_avantbras_gauche": "peau",
	"mesh_cheveux": "cheveux",
	"mesh_torse_haut": "haut", "mesh_torse_bas": "haut",
	"mesh_bras_droit": "haut", "mesh_bras_gauche": "haut",
	"mesh_bassin": "bas",
	"mesh_cuisse_droite": "bas", "mesh_cuisse_gauche": "bas",
	"mesh_mollet_droite": "bas", "mesh_mollet_gauche": "bas",
	"mesh_pied_droite": "bas", "mesh_pied_gauche": "bas",
}

## Part du tangage de la caméra reportée sur la colonne. Volontairement
## PARTIELLE : à 1.0 le buste suivrait le regard au degré près et le joueur
## verrait son propre torse se plier à la verticale. Une fraction donne
## l'inclinaison sans absurdité, et c'est aussi ce qui permettra plus tard de
## viser les jambes ou la tête en penchant le buste (design du combat).
const SPINE_PITCH_RATIO := 0.4
## Bornes du tangage repris par le buste — au-delà, le personnage se casserait
## le dos (le GDD demande explicitement de brider cet angle).
const SPINE_PITCH_LIMIT := deg_to_rad(60.0)
## Os de la colonne, du bas vers le haut. Le tangage est RÉPARTI entre eux
## pour que la courbure soit continue plutôt que cassée sur une seule
## articulation.
const SPINE_BONES := ["colonne_1", "colonne_2"]

## Pose de PORT de l'arme, appliquée au bras droit. En attendant l'IK (qui
## aimantera les mains sur les points de prise de l'arme), cette pose fixe
## suffit à ce que le joueur VOIE son bras et son arme devant lui — c'est la
## demande, et elle ne dépend pas d'un solveur qui n'existe pas encore.
const CARRY_POSE := {
	"bras_droit": Vector3(-55.0, 0.0, -12.0),
	"avantbras_droit": Vector3(-35.0, 0.0, 0.0),
	"bras_gauche": Vector3(-12.0, 0.0, 12.0),
	"avantbras_gauche": Vector3(-20.0, 0.0, 0.0),
}

## Chaînes IK : (racine, milieu, extrémité). Deux os EXACTEMENT — c'est ce qui
## autorise le solveur analytique (voir TwoBoneIK).
const ARM_CHAINS := {
	"droite": ["bras_droit", "avantbras_droit", "main_droite"],
	"gauche": ["bras_gauche", "avantbras_gauche", "main_gauche"],
}
const LEG_CHAINS := {
	"droite": ["cuisse_droite", "mollet_droite", "pied_droite"],
	"gauche": ["cuisse_gauche", "mollet_gauche", "pied_gauche"],
}

## Rayon de l'arc décrit par la MAIN pendant une frappe. La main est sur le
## même arc que la pointe de l'arme, simplement beaucoup plus près du centre
## de rotation — d'où un rayon court. Réutiliser `MeleeAttack.tip_position`
## pour la main garantit que le geste vu et le balayage qui touche sont la
## MÊME courbe : le visuel ne peut pas mentir sur la hitbox.
## 0,55 et non 0,38 (corrige le 2026-07-28 sur captures) : la main tenue trop
## pres de l'oeil, le bras occupait la moitie de l'ecran. Bras tendu vers
## l'avant, l'arme s'eloigne et redevient lisible.
## 0,72 (2026-07-31) : a 0,55 l'avant-bras restait une grande surface plate en
## bas de l'ecran, parce qu'un membre proche de l'objectif occupe un angle
## enorme. L'eloigner le raccourcit en perspective sans rien changer a la
## geometrie de frappe (la pointe reste sur le meme arc). VALEUR DE CADRAGE.
const HAND_ARC_RADIUS := 0.72
## Écart de la main gauche le long de l'arme pour une arme à deux mains.
const OFFHAND_ALONG_WEAPON := 0.28

## Le coude pointe vers l'extérieur et l'arrière, le genou vers l'avant : ce
## sont les pôles qui lèvent l'ambiguïté du triangle (sans eux, le membre
## pivoterait au hasard autour de l'axe racine→cible).
const ELBOW_POLE_OUT := 0.7
const KNEE_POLE_FORWARD := 1.0

## Profondeur de recherche du sol sous une hanche, en blocs. Au-delà, le pied
## est en l'air (saut, chute) et l'IK de jambe se désactive d'elle-même.
const GROUND_SEARCH := 3
## Abaissement maximal du bassin quand un pied ne peut pas atteindre son sol
## (bord de bloc). Borné : au bord d'un gouffre, un personnage non bridé
## s'accroupirait jusqu'au ridicule.
const MAX_PELVIS_DROP := 0.45
## Vitesse de convergence de cet abaissement, en unités par appel. Lissé : un
## saut de bassin d'une frame à l'autre en franchissant une marche se verrait.
const PELVIS_DROP_SPEED := 0.06

## --- Marche PROCÉDURALE ---
## Le `.glb` généré ne contient AUCUNE animation. Plutôt que d'attendre un
## travail d'animation, le cycle de marche est calculé : les cibles de pieds
## de l'IK sont décalées par une phase qui avance avec la DISTANCE PARCOURUE,
## et non avec le temps. C'est ce qui fait qu'un joueur qui ralentit voit ses
## pas ralentir naturellement, et qu'un joueur immobile a les pieds au sol —
## un cycle piloté par le temps patinerait sur place.
const STRIDE_LENGTH := 1.1      # distance parcourue pour un cycle complet
const STRIDE_REACH := 0.22      # amplitude avant/arrière du pied
const STEP_LIFT := 0.16         # hauteur à laquelle le pied se lève
## Retour à la station debout quand on s'arrête (par appel).
const GAIT_SETTLE_SPEED := 0.12

var _gait_phase := 0.0
var _gait_amount := 0.0         # 0 = immobile, 1 = marche pleine
var _last_ground_position := Vector3.ZERO
var _has_last_position := false
var _move_direction := Vector3.FORWARD

var _pelvis_drop := 0.0
## Hauteur de l'os du pied AU-DESSUS de sa semelle, mesurée sur le repos : la
## semelle doit toucher le bloc, pas l'origine de l'os.
var _foot_sole_offset := 0.0

## CULLING (budget Intel UHD 620). L'IK est bon marché à l'unité — deux acos —
## mais la faire tourner pour chaque PNJ d'une ville la rendrait ruineuse par
## le nombre. Au-delà de cette distance du joueur, un corps garde sa pose de
## repos : personne ne verra que ses pieds ne suivent pas exactement une marche.
const IK_MAX_DISTANCE := 15.0

## Vrai pour le corps du joueur de CETTE machine (tête masquée).
var is_local := true
## IK active ? Coupée par le culling de distance pour les corps distants.
var ik_enabled := true

var _visible_left := false
var _limbs_configured := false

var _skeleton: Skeleton3D
var _meshes := {}          # nom -> MeshInstance3D
var _spine_indices: Array[int] = []
var _hand_attachment: BoneAttachment3D
var _offhand_attachment: BoneAttachment3D
## Tangage courant, en radians (posé par follow_camera ou par le réseau).
var _pitch := 0.0


## Construit le corps. Retourne false si le modèle est absent — l'appelant
## reste alors sans corps visible plutôt que de planter (même politique que
## `creature.gd`, qui retombe sur sa capsule).
func setup(local: bool, palette: Dictionary = DEFAULT_PALETTE) -> bool:
	is_local = local
	if not ResourceLoader.exists(MODEL_PATH):
		push_warning("PlayerBody : modèle introuvable « %s » — aucun corps affiché." % MODEL_PATH)
		return false
	var scene: PackedScene = load(MODEL_PATH)
	if scene == null:
		return false
	var instance := scene.instantiate()
	add_child(instance)
	_skeleton = _find_skeleton(instance)
	if _skeleton == null:
		push_warning("PlayerBody : le modèle n'a pas de Skeleton3D — rig invalide.")
		return false
	_collect_meshes(instance)
	# Peau procédurale : sans elle le modèle sort BLANC (le .glb n'a pas de
	# texture et ses couleurs par sommet ne sont pas reprises à l'import).
	# La palette est un PARAMÈTRE : l'appliquer ici puis une seconde fois
	# depuis l'appelant repeignait les 18 maillages deux fois par créature,
	# soit ~3 ms perdues a chaque apparition (mesure du 2026-07-28).
	apply_procedural_skin(instance, palette)

	# Corps réduit aux jambes et au bras droit pour soi-même ; l'appelant
	# affinera selon l'arme tenue (une arme à deux mains rend la gauche).
	if is_local:
		set_local_limbs(false)

	for bone_name: String in SPINE_BONES:
		var index := _skeleton.find_bone(bone_name)
		if index >= 0:
			_spine_indices.append(index)
	_measure_chains()
	_apply_carry_pose()
	_build_hand_attachment()
	return true


## N'affiche, pour le joueur LOCAL, que les jambes et le(s) bras utilisé(s).
## `use_left` : vrai pour une arme à deux mains, un bouclier ou les poings —
## bref dès que la main gauche sert à quelque chose.
##
## Sans effet sur un corps distant : les autres joueurs doivent voir un
## personnage entier, pas une paire de jambes.
func set_local_limbs(use_left: bool) -> void:
	if not is_local:
		return
	if _visible_left == use_left and _limbs_configured:
		return   # Rien n'a changé : ne pas retoucher 18 nœuds par frame.
	_visible_left = use_left
	_limbs_configured = true
	var shown := {}
	for mesh_name: String in LOCAL_LEG_MESHES:
		shown[mesh_name] = true
	for mesh_name: String in LOCAL_ARM_MESHES["droite"]:
		shown[mesh_name] = true
	if use_left:
		for mesh_name: String in LOCAL_ARM_MESHES["gauche"]:
			shown[mesh_name] = true
	for mesh_name: String in _meshes:
		(_meshes[mesh_name] as MeshInstance3D).visible = shown.has(mesh_name)


# --- Pose de combat (créatures et joueurs distants) ----------------------

## Hauteur de la prise au-dessus des pieds, pour un corps vu de l'EXTÉRIEUR.
## Le joueur local, lui, dérive sa prise de la caméra (`Player.GRIP_DOWN`) —
## ici il n'y a pas de caméra, seulement un corps.
const COMBAT_GRIP_HEIGHT := 1.30


## Pose le bras armé d'une entité selon la phase de SON attaque.
##
## POURQUOI ÇA COMPTE. La télégraphie existait depuis le début — les créatures
## déclarent leur direction et attendent un wind-up entier avant de frapper —
## mais RIEN ne le montrait : le joueur recevait un signal qu'il ne pouvait pas
## percevoir. Or dans Mount & Blade on lit le CORPS de l'adversaire, pas une
## icône. Ce bras qui s'arme est ce qui rend la parade directionnelle jouable.
##
## Réutilise `MeleeAttack.tip_position` — la même courbe que le joueur, donc un
## ennemi bouge comme on bouge soi-même, et ce qu'on apprend sur soi se lit
## chez lui.
func set_combat_pose(direction: int, ratio: float, phase: String) -> void:
	if _skeleton == null or not ik_enabled:
		return
	var facing := global_transform.basis
	var grip := global_position + Vector3.UP * COMBAT_GRIP_HEIGHT
	var carry := grip + (-facing.z) * HAND_ARC_RADIUS
	var target := carry
	match phase:
		"windup":
			# Le bras RECULE vers le début de l'arc : c'est le geste que le
			# joueur doit apprendre à lire pour parer du bon côté.
			target = carry.lerp(
				MeleeAttack.tip_position(direction, 0.0, grip, facing, HAND_ARC_RADIUS),
				clampf(ratio, 0.0, 1.0))
		"garde":
			# GARDE VISIBLE : même posture que celle du joueur — la main du côté
			# couvert, la lame EN TRAVERS de la ligne parée. C'est ce qui permet
			# de voir qu'un PNJ s'est protégé du mauvais côté, donc de le punir.
			var offset := MeleeAttack.guard_hand_offset(direction)
			var right := facing.x
			right.y = 0.0
			if right.length_squared() > 0.000001:
				right = right.normalized()
			target = grip + right * (offset.x * HAND_ARC_RADIUS) 				+ Vector3.UP * (offset.y * HAND_ARC_RADIUS) 				+ (-facing.z) * (offset.z * HAND_ARC_RADIUS)
			solve_arm("droite", target)
			point_weapon(MeleeAttack.guard_blade_axis(direction, facing), _weapon_scale)
			return
		"armee":
			# MENACE TENUE : le bras reste au point d'armement, exactement comme
			# la garde armée du joueur. Sans ce cas, la pose retombait au port
			# et le PNJ semblait renoncer juste avant de frapper.
			target = MeleeAttack.tip_position(direction, 0.0, grip, facing, HAND_ARC_RADIUS)
		"strike":
			target = MeleeAttack.tip_position(direction, clampf(ratio, 0.0, 1.0),
				grip, facing, HAND_ARC_RADIUS)
		"recover":
			target = MeleeAttack.tip_position(direction, 1.0, grip, facing, HAND_ARC_RADIUS) \
				.lerp(carry, clampf(ratio, 0.0, 1.0))
	solve_arm("droite", target)
	# L'ARME SUIT L'ARC, comme celle du joueur (2026-08-02). Sans ça un PNJ
	# armait son bras dans le vide : l'arme, simple enfant de l'os, héritait de
	# la rotation de la main et pointait n'importe où. Or dans Mount & Blade on
	# juge la distance et le danger SUR L'ARME de l'adversaire — c'est le
	# premier élément à lire, avant même la direction du coup.
	var axis := target - grip
	if axis.length_squared() > 0.000001:
		point_weapon(axis.normalized(), _weapon_scale)


## Échelle d'affichage de l'arme portée, posée à l'accrochage.
var _weapon_scale := 1.0


## Accroche un MODÈLE D'ARME dans la main droite (créatures, 2026-08-02). Le
## joueur y reparente son `HeldItem` — même os, même orientation — mais le sien
## suit la hotbar, alors que celui d'un PNJ est figé par sa fiche.
func attach_weapon_model(model: Node3D, scale_factor: float) -> bool:
	if _hand_attachment == null or model == null:
		return false
	model.name = "HeldItem"
	# `point_weapon` ne redresse que les ARMES À PIÈCES : sans ce marqueur elle
	# laisserait le modèle hériter de la rotation de l'avant-bras.
	model.set_meta("part_weapon", true)
	model.scale = Vector3.ONE * scale_factor
	_weapon_scale = scale_factor
	_hand_attachment.add_child(model)
	return true


## Oriente l'arme tenue vers `forward` (espace MONDE), sans toucher à sa
## position — elle reste attachée à la main.
##
## POURQUOI CE N'EST PAS L'OS QUI DÉCIDE. L'arme était simple enfant de l'os
## `attach_arme` : elle héritait donc de la rotation de la MAIN, elle-même
## dictée par l'avant-bras que l'IK oriente vers sa cible. Résultat, l'arme
## pointait là où pointait le bras — en travers de l'écran — et non là où le
## joueur vise (constaté en jeu le 2026-07-28 : « le placement des mains, là
## c'est pas possible »).
##
## La main PORTE l'arme (position), l'axe de VISÉE l'oriente (rotation). C'est
## aussi ce qui rétablit l'invariant du système : l'arme pointe exactement le
## long de l'arc que la lame va parcourir.
func point_weapon(forward: Vector3, scale_factor: float) -> void:
	if _hand_attachment == null:
		return
	var held := _hand_attachment.get_node_or_null("HeldItem") as Node3D
	if held == null or forward.length_squared() < 0.000001:
		return
	# Outil à SPRITE : bâti sur un autre axe, on n'y touche pas. Le joueur
	# porte un `HeldItem` qui l'annonce par une propriété, une créature un
	# assemblage nu qui l'annonce par un marqueur — les deux disent la même
	# chose, et `point_weapon` doit servir les deux.
	if not (held.get("is_part_weapon") == true or held.has_meta("part_weapon")):
		return
	# Le modèle d'arme est construit vers +Y (LISEZMOI des pièces) : on bâtit
	# donc une base dont l'axe Y EST la direction voulue.
	var y := forward.normalized()
	var reference := Vector3.UP if absf(y.dot(Vector3.UP)) < 0.95 else Vector3.FORWARD
	var x := reference.cross(y).normalized()
	var z := x.cross(y).normalized()
	held.global_transform = Transform3D(
		Basis(x * scale_factor, y * scale_factor, z * scale_factor),
		_hand_attachment.global_position)


## Oriente le BOUCLIER : sa plaque fait face à `forward`.
##
## Même raison que `point_weapon` — accroché à l'os de la main, le bouclier
## héritait de la rotation de l'avant-bras et présentait sa TRANCHE à
## l'adversaire. Un bouclier de profil ne protège visiblement rien, et le joueur
## ne peut pas comprendre ce qu'il bloque.
##
## Les plaques sont modelisées dans le plan XY, face vers +Z (voir HEADS dans
## tools/generate_weapon_parts.py). On construit donc une base dont le Z local
## est la direction de visée.
func point_shield(forward: Vector3, scale_factor: float) -> void:
	if _offhand_attachment == null:
		return
	var shield := _offhand_attachment.get_node_or_null("ShieldItem") as Node3D
	if shield == null or not shield.visible:
		return
	var z := forward.normalized()
	if z.length_squared() < 0.0001:
		return
	var reference := Vector3.UP if absf(z.dot(Vector3.UP)) < 0.95 else Vector3.FORWARD
	var x := reference.cross(z).normalized()
	var y := z.cross(x).normalized()
	shield.global_transform = Transform3D(
		Basis(x * scale_factor, y * scale_factor, z * scale_factor),
		_offhand_attachment.global_position)


## Oriente l'ARME de main gauche (dual wielding, 2026-08-02). Même géométrie
## que `point_weapon` — une pièce d'arme est bâtie vers +Y — mais sur l'autre
## main. Sans elle, la seconde arme héritait de la rotation de l'avant-bras
## gauche et pointait en travers, exactement le défaut corrigé sur la main forte
## le 2026-07-28.
func point_offhand_weapon(forward: Vector3, scale_factor: float) -> void:
	if _offhand_attachment == null:
		return
	var held := _offhand_attachment.get_node_or_null("ShieldItem") as Node3D
	if held == null or not held.visible or forward.length_squared() < 0.000001:
		return
	if not bool(held.get("is_part_weapon")):
		return
	var y := forward.normalized()
	var reference := Vector3.UP if absf(y.dot(Vector3.UP)) < 0.95 else Vector3.FORWARD
	var x := reference.cross(y).normalized()
	var z := x.cross(y).normalized()
	held.global_transform = Transform3D(
		Basis(x * scale_factor, y * scale_factor, z * scale_factor),
		_offhand_attachment.global_position)


## Point d'accrochage de l'arme (os `attach_arme`, main droite). Les objets
## tenus y sont reparentés : l'arme est PORTÉE par la main, elle ne flotte plus
## devant la caméra comme le faisait le viewmodel.
func hand_attachment() -> BoneAttachment3D:
	return _hand_attachment


## Suit la caméra locale : les PIEDS se posent sous l'œil, le corps ne prend
## que le LACET (yaw). Le tangage part dans la colonne, pas dans le corps
## entier — sinon le personnage basculerait en bloc en regardant ses pieds.
func follow_camera(camera: Node3D, eye_height: float, delta: float = 1.0 / 60.0) -> void:
	_frame_delta = delta
	global_position = camera.global_position - Vector3(0.0, eye_height, 0.0)
	rotation.y = camera.rotation.y
	_pitch = camera.rotation.x
	_advance_gait(global_position)
	_apply_spine_pitch()


## Avance le cycle de marche en fonction de la DISTANCE réellement parcourue.
func _advance_gait(feet_position: Vector3) -> void:
	if not _has_last_position:
		_last_ground_position = feet_position
		_has_last_position = true
		return
	var delta := feet_position - _last_ground_position
	delta.y = 0.0
	_last_ground_position = feet_position
	var distance := delta.length()
	# Seuil : sous quelques millimètres par frame, c'est du bruit (dérive
	# numérique, micro-ajustements), pas de la marche.
	if distance > 0.0015:
		_move_direction = delta / distance
		_gait_phase = fmod(_gait_phase + distance / STRIDE_LENGTH * TAU, TAU)
		_gait_amount = minf(_gait_amount + GAIT_SETTLE_SPEED, 1.0)
	else:
		# À l'arrêt : on rend l'amplitude à zéro ET on ramène la phase vers un
		# pied à plat, sinon le personnage se fige en plein pas.
		_gait_amount = maxf(_gait_amount - GAIT_SETTLE_SPEED, 0.0)
		if _gait_amount <= 0.0:
			_gait_phase = 0.0


## Pilotage d'une ENTITÉ non-joueur (créature, PNJ) : pose, marche et IK en un
## appel. Le corps d'une créature est le MÊME nœud que celui du joueur — un
## seul système d'animation à maintenir, et ce qu'on voit d'un mob est ce qu'on
## verrait de soi.
##
## `viewer_position` sert au culling : au-delà de IK_MAX_DISTANCE, l'IK est
## coupée et la créature garde sa pose de repos. Personne ne remarque à 20 m
## que des pieds ne suivent pas exactement une marche.
func update_as_entity(feet_position: Vector3, yaw: float, viewer_position: Vector3, delta: float = 1.0 / 60.0) -> void:
	_frame_delta = delta
	global_position = feet_position
	rotation.y = yaw
	_advance_gait(feet_position)
	update_ik_culling(viewer_position)
	solve_legs()


## Pose imposée par le réseau (joueur distant) : position des pieds, plus
## l'orientation du regard. Le tangage est répliqué parce que sans lui on ne
## voit pas où l'autre vise — information vitale dans un combat directionnel.
func apply_remote_pose(feet_position: Vector3, yaw: float, pitch: float) -> void:
	global_position = feet_position
	rotation.y = yaw
	_pitch = pitch
	_apply_spine_pitch()


# --- Cinématique inverse -------------------------------------------------

## Longueurs d'os au REPOS, mesurées une fois : elles ne changent jamais et
## les recalculer par frame serait du gaspillage pur.
var _chain_lengths := {}


func _measure_chains() -> void:
	for table: Dictionary in [ARM_CHAINS, LEG_CHAINS]:
		for side: String in table:
			var names: Array = table[side]
			var indices: Array[int] = []
			for bone_name: String in names:
				indices.append(_skeleton.find_bone(bone_name))
			if indices.has(-1):
				continue
			var root := _skeleton.get_bone_global_rest(indices[0]).origin
			var mid := _skeleton.get_bone_global_rest(indices[1]).origin
			var tip := _skeleton.get_bone_global_rest(indices[2]).origin
			_chain_lengths[names[0]] = {
				"indices": indices,
				"l1": root.distance_to(mid),
				"l2": mid.distance_to(tip),
			}
	# Décalage semelle → os du pied : au repos le corps est posé au sol
	# (y = 0), donc la hauteur de l'os du pied EST cet écart.
	var foot := _skeleton.find_bone("pied_droite")
	if foot >= 0:
		_foot_sole_offset = _skeleton.get_bone_global_rest(foot).origin.y


## Place la main sur la prise de l'arme. `phase_target` est la cible EN ESPACE
## MONDE ; elle vient du joueur, qui la calcule avec la même fonction d'arc que
## le balayage de lame.
func solve_arm(side: String, world_target: Vector3) -> void:
	if not ik_enabled:
		return
	var names: Array = ARM_CHAINS.get(side, [])
	if names.is_empty() or not _chain_lengths.has(names[0]):
		return
	var chain: Dictionary = _chain_lengths[names[0]]
	var indices: Array = chain["indices"]
	var root: Vector3 = _skeleton.get_bone_global_pose(indices[0]).origin
	# Tout se résout dans l'espace du SQUELETTE : la cible monde doit y entrer.
	var local_target: Vector3 = _skeleton.global_transform.affine_inverse() * world_target
	# Coude vers l'extérieur et l'arrière — posture humaine, pas un bras cassé.
	var outward := ELBOW_POLE_OUT if side == "droite" else -ELBOW_POLE_OUT
	var pole := Vector3(outward, -0.2, 0.6)
	var result := TwoBoneIK.solve(root, local_target, chain["l1"], chain["l2"], pole)
	TwoBoneIK.apply_global_basis(_skeleton, indices[0], result["upper"])
	TwoBoneIK.apply_global_basis(_skeleton, indices[1], result["lower"])


## Ancre les pieds sur les BLOCS (Ground IK). Sur un terrain en escalier, sans
## ça un pied flotte pendant que l'autre s'enfonce — le défaut le plus visible
## d'un personnage dans un monde voxel.
##
## La hauteur du sol vient d'une descente de blocs, PAS d'un RayCast3D : le
## projet n'a aucun collider, ni sur le terrain ni sur les entités (c'est aussi
## ce qui rend cette requête bon marché — quelques lectures de tableau).
## Position MONDE de la main d'un côté, APRÈS résolution de l'IK. À ne pas
## confondre avec la cible qu'on lui a donnée : un IK à deux os ne l'atteint que
## si elle est à portée du bras. Mesurer la cible revient à mesurer son propre
## calcul — l'écart entre les deux est précisément ce qu'il faut regarder.
func hand_world_position(side: String) -> Vector3:
	if _skeleton == null:
		return Vector3.ZERO
	var names: Array = ARM_CHAINS.get(side, [])
	if names.size() < 3:
		return Vector3.ZERO
	var index := _skeleton.find_bone(String(names[2]))
	if index < 0:
		return Vector3.ZERO
	return _skeleton.global_transform * _skeleton.get_bone_global_pose(index).origin


## Position MONDE de l'ÉPAULE d'un côté — la racine de la chaîne d'IK. C'est
## depuis ce point, et non depuis la prise de l'arme, que se mesure ce que le
## bras peut atteindre.
func shoulder_world_position(side: String) -> Vector3:
	if _skeleton == null:
		return Vector3.ZERO
	var names: Array = ARM_CHAINS.get(side, [])
	if names.is_empty():
		return Vector3.ZERO
	var index := _skeleton.find_bone(String(names[0]))
	if index < 0:
		return Vector3.ZERO
	return _skeleton.global_transform * _skeleton.get_bone_global_pose(index).origin


## Allonge maximale d'un bras (somme des deux segments). Au-delà, la main ne
## peut PAS atteindre sa cible, quoi qu'on lui demande.
func arm_reach(side: String) -> float:
	var names: Array = ARM_CHAINS.get(side, [])
	if names.is_empty() or not _chain_lengths.has(names[0]):
		return 0.0
	var chain: Dictionary = _chain_lengths[names[0]]
	return float(chain["l1"]) + float(chain["l2"])


func solve_legs() -> void:
	if not ik_enabled:
		return
	# ABAISSEMENT DU BASSIN, sans quoi le reste ne sert à rien au bord d'un
	# bloc. Une jambe de ce gabarit mesure 0,75 et la hanche est à 0,875 du
	# sol : descendre d'un bloc ENTIER en gardant le bassin en haut est
	# géométriquement impossible — pour ce rig comme pour une vraie jambe.
	# Sans cet abaissement, le pied bas reste tendu dans le vide et l'effet
	# recherché (« une jambe tendue, l'autre pliée ») ne se produit jamais.
	#
	# C'est un décalage PUREMENT VISUEL sur ce nœud : la caméra, qui porte la
	# position et la collision, n'est pas touchée. C'est très exactement ce que
	# la séparation caméra/corps rend possible sans risque.
	_apply_pelvis_drop()
	for side: String in LEG_CHAINS:
		var names: Array = LEG_CHAINS[side]
		if not _chain_lengths.has(names[0]):
			continue
		var chain: Dictionary = _chain_lengths[names[0]]
		var indices: Array = chain["indices"]
		var hip_local: Vector3 = _skeleton.get_bone_global_pose(indices[0]).origin
		var hip_world: Vector3 = _skeleton.global_transform * hip_local
		var surface := _surface_under(hip_world)
		if is_nan(surface):
			# AU-DESSUS DU VIDE : la jambe PEND, tendue vers le bas. Elle gardait
			# sa pose de repos, donc restait pliée comme si elle prenait appui
			# sur un sol inexistant — c'est le « flottement » signalé au bord
			# d'un bloc. Une jambe sans appui tombe, l'autre encaisse en se
			# fléchissant (voir _apply_pelvis_drop).
			var reach: float = float(chain["l1"]) + float(chain["l2"])
			_solve_leg_to(chain, hip_local, hip_local + Vector3.DOWN * reach)
			continue
		# La SEMELLE se pose sur le bloc ; l'os du pied est au-dessus d'elle.
		var foot_world := Vector3(hip_world.x, surface + _foot_sole_offset, hip_world.z)
		# Cycle de marche : une jambe est en avance d'un demi-cycle sur l'autre.
		if _gait_amount > 0.0:
			var phase: float = _gait_phase + (0.0 if side == "droite" else PI)
			foot_world += _move_direction * (cos(phase) * STRIDE_REACH * _gait_amount)
			# Le pied ne se lève que sur la moitié « en vol » du cycle ; sur
			# l'autre moitié il reste PLAQUÉ au bloc, ce qui est justement ce
			# que l'IK de sol garantit.
			foot_world.y += maxf(sin(phase), 0.0) * STEP_LIFT * _gait_amount
		# BALLANT : le pied est tiré vers sa cible par un ressort, comme la main.
		# Sans lui les jambes se téléportent d'une pose à l'autre en franchissant
		# une marche — c'est net, et c'est mort.
		foot_world = _spring_foot(side, foot_world)
		var foot_local: Vector3 = _skeleton.global_transform.affine_inverse() * foot_world
		_solve_leg_to(chain, hip_local, foot_local)


## Abaisse le corps juste assez pour que le pied le plus bas reste atteignable,
## borné et lissé. Borné, parce qu'un joueur au bord d'un gouffre s'accroupirait
## sinon jusqu'au ridicule ; lissé, parce qu'un saut de bassin d'une frame à
## l'autre en franchissant une marche se verrait immédiatement.
func _apply_pelvis_drop() -> void:
	var needed := 0.0
	for side: String in LEG_CHAINS:
		var names: Array = LEG_CHAINS[side]
		if not _chain_lengths.has(names[0]):
			continue
		var chain: Dictionary = _chain_lengths[names[0]]
		var indices: Array = chain["indices"]
		var hip_world: Vector3 = _skeleton.global_transform * _skeleton.get_bone_global_pose(indices[0]).origin
		var surface := _surface_under(hip_world)
		if is_nan(surface):
			continue
		var reach: float = float(chain["l1"]) + float(chain["l2"])
		var required: float = hip_world.y - (surface + _foot_sole_offset)
		needed = maxf(needed, required - reach)
	_pelvis_drop = move_toward(_pelvis_drop, clampf(needed, 0.0, MAX_PELVIS_DROP), PELVIS_DROP_SPEED)
	position.y -= _pelvis_drop


## Résout UNE jambe vers une cible en espace squelette. Extrait pour être
## partagé par le cas « pied posé » et le cas « jambe qui pend ».
func _solve_leg_to(chain: Dictionary, hip_local: Vector3, foot_local: Vector3) -> void:
	var indices: Array = chain["indices"]
	# Genou vers l'AVANT : une jambe ne se plie pas en arrière.
	var pole := Vector3(0.0, 0.0, -KNEE_POLE_FORWARD)
	var result := TwoBoneIK.solve(hip_local, foot_local, chain["l1"], chain["l2"], pole)
	TwoBoneIK.apply_global_basis(_skeleton, indices[0], result["upper"])
	TwoBoneIK.apply_global_basis(_skeleton, indices[1], result["lower"])


## --- Ballant des jambes (ressort amorti, même principe que l'arme) ---
## Sous-amorti VOLONTAIREMENT : c'est ce léger dépassement qui donne du poids
## au pas. Plus raide que le ressort de l'arme — un pied doit se poser
## franchement, pas gigoter sous le personnage.
const FOOT_STIFFNESS := 320.0
const FOOT_DAMPING := 26.0
const MAX_FOOT_STEP := 1.0 / 30.0

var _foot_smoothed := {}
var _foot_velocity := {}
## Pas de temps de la frame courante, posé par follow_camera/update_as_entity :
## solve_legs est appelée sans delta par plusieurs chemins.
var _frame_delta := 1.0 / 60.0


func _spring_foot(side: String, target: Vector3) -> Vector3:
	if not _foot_smoothed.has(side):
		_foot_smoothed[side] = target
		_foot_velocity[side] = Vector3.ZERO
		return target
	# Téléportation (voyage rapide, changement de dimension) : au-delà d'un
	# mètre le ressort n'a rien à lisser, il rattraperait en traînant le pied
	# à travers la carte.
	if (_foot_smoothed[side] as Vector3).distance_to(target) > 1.0:
		_foot_smoothed[side] = target
		_foot_velocity[side] = Vector3.ZERO
		return target
	var step := minf(_frame_delta, MAX_FOOT_STEP)
	var acceleration: Vector3 = (target - _foot_smoothed[side]) * FOOT_STIFFNESS 		- _foot_velocity[side] * FOOT_DAMPING
	_foot_velocity[side] += acceleration * step
	_foot_smoothed[side] += _foot_velocity[side] * step
	return _foot_smoothed[side]


## Sommet du premier bloc plein sous `position`, ou NAN si rien à portée.
func _surface_under(position: Vector3) -> float:
	var bx := floori(position.x)
	var bz := floori(position.z)
	var start := floori(position.y)
	for wy in range(start, start - GROUND_SEARCH - 1, -1):
		if WorldManager.block_at_world(Vector3i(bx, wy, bz)) != 0:
			return float(wy + 1)   # sommet du bloc, comme la convention de collision
	return NAN


## Coupe l'IK au-delà d'une certaine distance du joueur (culling annoncé au
## design). Retourne l'état appliqué.
func update_ik_culling(viewer_position: Vector3) -> bool:
	ik_enabled = global_position.distance_to(viewer_position) <= IK_MAX_DISTANCE
	return ik_enabled


func _apply_spine_pitch() -> void:
	if _spine_indices.is_empty():
		return
	var total := clampf(_pitch, -SPINE_PITCH_LIMIT, SPINE_PITCH_LIMIT) * SPINE_PITCH_RATIO
	var per_bone := total / float(_spine_indices.size())
	for index: int in _spine_indices:
		# Rotation autour de X : un tangage NÉGATIF (regard vers le bas)
		# incline le buste vers l'avant (-Z), ce qui est le sens voulu.
		_skeleton.set_bone_pose_rotation(index, Quaternion(Vector3.RIGHT, per_bone))


func _apply_carry_pose() -> void:
	for bone_name: String in CARRY_POSE:
		var index := _skeleton.find_bone(bone_name)
		if index < 0:
			continue
		var angles: Vector3 = CARRY_POSE[bone_name]
		_skeleton.set_bone_pose_rotation(index, Quaternion(Basis.from_euler(Vector3(
			deg_to_rad(angles.x), deg_to_rad(angles.y), deg_to_rad(angles.z)))))


func _build_hand_attachment() -> void:
	_hand_attachment = _attach_to("attach_arme", "MainDroite")
	# Main GAUCHE : elle ne portait rien tant qu'aucun objet ne s'y tenait. Le
	# bouclier lui donne enfin un usage — et le rig prévoyait l'os depuis le
	# début (voir models/creatures/LISEZMOI.md).
	_offhand_attachment = _attach_to("attach_arme_gauche", "MainGauche")


func _attach_to(bone: String, node_name: String) -> BoneAttachment3D:
	if _skeleton.find_bone(bone) < 0:
		push_warning("PlayerBody : os « %s » absent — rien à quoi accrocher." % bone)
		return null
	var attachment := BoneAttachment3D.new()
	attachment.name = node_name
	_skeleton.add_child(attachment)
	attachment.bone_name = bone
	return attachment


## Point d'accrochage de la main GAUCHE (bouclier, torche, seconde arme).
func offhand_attachment() -> BoneAttachment3D:
	return _offhand_attachment


# --- Peau procédurale ----------------------------------------------------

## Côté de la tuile de grain, en pixels. Petite et filtrée en NEAREST : on
## cherche le même grain pixel-art que les blocs du monde, pas un dégradé lisse.
const SKIN_TILE := 8
## Amplitude du grain autour de la couleur de base.
const SKIN_NOISE := 0.06


## Applique une peau PROCÉDURALE aux maillages d'un modèle humanoïde.
##
## Pourquoi procédural plutôt qu'un atlas peint : le `.glb` généré n'a AUCUNE
## texture, et ses couleurs par sommet ne sont pas reprises par le matériau
## importé — d'où le corps entièrement BLANC constaté en jeu. Générer la
## teinte ici a en plus l'avantage d'être data-driven : la création de
## personnage (12) n'aura qu'à passer une autre palette, et les variantes
## rares (12.4) qu'à décaler la graine.
##
## STATIQUE : les créatures utilisent le même gabarit et passent par ici aussi
## (creature.gd), sinon elles resteraient blanches de leur côté.
## CACHE GLOBAL, indispensable sur la machine cible. Sans lui, chaque créature
## qui apparaît fabriquait 4 images + 4 ImageTexture, donc 4 uploads GPU : le
## tick de spawn passait à 27,8 ms (163,8 ms au tout premier, chargement du
## modèle compris) sur un budget de 16 — mesuré en jeu sur Intel UHD 620 le
## 2026-07-28. La clé est (calque, couleur) : deux créatures de la même espèce
## partagent donc leurs matériaux, et le grain n'a plus à varier par individu
## (invisible à 8×8 de toute façon).
static var _skin_cache := {}


static func apply_procedural_skin(root: Node, palette: Dictionary, _seed_offset: int = 0) -> void:
	for mesh: MeshInstance3D in _find_meshes(root):
		var layer := String(MESH_LAYER.get(String(mesh.name), "haut"))
		var base: Color = palette.get(layer, DEFAULT_PALETTE.get(layer, Color.GRAY))
		var key := "%s|%s" % [layer, base.to_html(false)]
		if not _skin_cache.has(key):
			_skin_cache[key] = _grain_material(base, hash(key))
		mesh.material_override = _skin_cache[key]


## Palette d'une ESPÈCE : teinte dérivée de la race, donc deux loups se
## ressemblent et un loup ne ressemble pas à un cerf. Ici et pas dans
## `creature.gd` parce que ce fichier n'a pas de `class_name` — et parce que
## CreatureManager doit pouvoir préchauffer le cache de matériaux au démarrage.
static func palette_for_species(race: String) -> Dictionary:
	var palette: Dictionary = DEFAULT_PALETTE.duplicate()
	var hue := float(hash(race) % 360) / 360.0
	palette["haut"] = Color.from_hsv(hue, 0.5, 0.75)
	palette["bas"] = Color.from_hsv(hue, 0.35, 0.45)
	return palette


## Construit d'avance les matériaux d'une palette, hors tick. Appelé au
## démarrage pour chaque race : c'est ce qui évite qu'une créature paie ses
## uploads de texture au moment où elle apparaît.
static func warm_skin_cache(palette: Dictionary) -> void:
	for layer: String in DEFAULT_PALETTE:
		var base: Color = palette.get(layer, DEFAULT_PALETTE[layer])
		var key := "%s|%s" % [layer, base.to_html(false)]
		if not _skin_cache.has(key):
			_skin_cache[key] = _grain_material(base, hash(key))


## Matériau à grain pour une couleur quelconque, mis en cache. Public parce que
## les PIÈCES D'ARME l'utilisent aussi : manche et tête sont teintés par les
## matériaux du craft exactement comme la peau, et deux épées en fer doivent
## partager leur matériau plutôt que d'en fabriquer un chacune.
static func tinted_material(base: Color) -> StandardMaterial3D:
	var key := "piece|" + base.to_html(false)
	if not _skin_cache.has(key):
		_skin_cache[key] = _grain_material(base, hash(key))
	return _skin_cache[key]


static func _grain_material(base: Color, grain_seed: int) -> StandardMaterial3D:
	var image := Image.create_empty(SKIN_TILE, SKIN_TILE, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = grain_seed
	for y in SKIN_TILE:
		for x in SKIN_TILE:
			var d := rng.randf_range(-SKIN_NOISE, SKIN_NOISE)
			image.set_pixel(x, y, Color(
				clampf(base.r + d, 0.0, 1.0),
				clampf(base.g + d, 0.0, 1.0),
				clampf(base.b + d, 0.0, 1.0)))
	var texture := ImageTexture.create_from_image(image)
	var material := StandardMaterial3D.new()
	material.albedo_texture = texture
	# NEAREST + répétition : grain net par pixel, jamais interpolé — cohérent
	# avec le rendu voxel du reste du jeu.
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	material.uv1_scale = Vector3(4.0, 4.0, 4.0)
	material.roughness = 1.0
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return material


static func _find_meshes(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		out.append_array(_find_meshes(child))
	return out


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


## Noms des maillages trouvés — utilisé par la sonde pour vérifier que le rig
## livré correspond bien à celui que le code attend.
func mesh_names() -> Array:
	return _meshes.keys()


func skeleton() -> Skeleton3D:
	return _skeleton

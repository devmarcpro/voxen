class_name TwoBoneIK
extends RefCounted
## Cinématique inverse ANALYTIQUE à deux os (2026-07-28).
##
## POURQUOI ANALYTIQUE ET PAS FABRIK/CCDIK. Un solveur itératif converge par
## approximations successives sur une chaîne quelconque : c'est puissant, et
## c'est exactement ce dont on n'a pas besoin. Une jambe (cuisse → mollet) et
## un bras (bras → avant-bras) sont des chaînes de DEUX os, et deux os forment
## un triangle : la loi des cosinus donne l'angle EXACT en une seule opération,
## sans boucle ni tolérance. C'est la raison pour laquelle le rig impose des
## chaînes de deux os (models/creatures/LISEZMOI.md) — la contrainte de
## modélisation existe précisément pour rendre ce calcul possible.
##
## Coût : deux acos, un produit vectoriel, deux constructions de base. Sur la
## machine cible (Intel UHD 620), le poste de dépense n'est pas là — c'est le
## nombre d'entités animées, d'où le culling appliqué par l'appelant.
##
## CONVENTION D'OS : les os du gabarit humanoïde pointent vers -Y au repos
## (chaque enfant est posé sous son parent). Un os « dirigé vers d » a donc
## pour base une rotation qui envoie -Y sur d.

## Marge sous la longueur totale : atteindre exactement l1+l2 tend le membre
## parfaitement droit, et la moindre erreur numérique fait alors basculer le
## coude d'un côté ou de l'autre d'une frame à l'autre (claquement visible).
const REACH_MARGIN := 0.001


## Résout la chaîne et retourne { "upper": Basis, "lower": Basis } — les bases
## GLOBALES (espace du squelette) des deux os.
##
## `root`   : origine de l'os supérieur (épaule / hanche).
## `target` : où l'extrémité (main / pied) doit se poser.
## `pole`   : direction vers laquelle le coude/genou doit pointer. C'est elle
##            qui lève l'ambiguïté : à distance donnée, le triangle peut se
##            replier dans une infinité de plans, et sans pôle le membre
##            pivoterait au hasard.
static func solve(root: Vector3, target: Vector3, l1: float, l2: float, pole: Vector3) -> Dictionary:
	var to_target := target - root
	var distance := to_target.length()
	if distance < 0.0001:
		# Cible confondue avec la racine : aucune direction exploitable.
		to_target = Vector3.DOWN * 0.001
		distance = 0.001
	# Hors d'atteinte (trop loin ou trop près) : on borne au lieu de renvoyer
	# une valeur invalide — un membre tendu au maximum est correct, un acos
	# hors domaine produirait un NAN qui se propagerait dans tout le squelette.
	var reach := l1 + l2 - REACH_MARGIN
	var minimum := absf(l1 - l2) + REACH_MARGIN
	distance = clampf(distance, minimum, reach)
	var direction := to_target.normalized()

	# Angle au niveau de la racine entre la ligne racine→cible et l'os
	# supérieur (loi des cosinus).
	var cos_root := clampf((l1 * l1 + distance * distance - l2 * l2) / (2.0 * l1 * distance), -1.0, 1.0)
	var root_angle := acos(cos_root)

	# Axe de flexion : perpendiculaire au plan (direction, pôle). Si le pôle
	# est colinéaire à la direction, le plan est indéterminé — on prend alors
	# un axe de secours plutôt que de produire un vecteur nul.
	var axis := direction.cross(pole)
	if axis.length_squared() < 0.000001:
		axis = direction.cross(Vector3.RIGHT if absf(direction.x) < 0.9 else Vector3.UP)
	axis = axis.normalized()

	# Direction de l'os supérieur : la ligne vers la cible, écartée de
	# `root_angle` DANS le plan de flexion, DU CÔTÉ DU PÔLE.
	#
	# SIGNE POSITIF, corrigé le 2026-07-28 (« les bras se plient dans le mauvais
	# sens »). Autour de `axis = direction × pole`, la règle de la main droite
	# fait qu'un angle POSITIF rapproche du pôle : avec d = X et p = Z,
	# axis = -Y et la rotation de +θ donne X·cosθ + Z·sinθ, soit un déport vers
	# Z, donc vers le pôle. Le `-root_angle` d'origine envoyait donc le coude à
	# l'OPPOSÉ du pôle demandé — coudes en avant, genoux en arrière.
	#
	# Le test de précision de l'effecteur ne pouvait PAS attraper ça : les deux
	# signes placent la main exactement sur la cible, ils ne diffèrent que par
	# le côté où se plie l'articulation. D'où l'assertion de coude ajoutée à
	# --probe-corps en même temps que ce correctif.
	var upper_dir := direction.rotated(axis, root_angle).normalized()
	var elbow := root + upper_dir * l1
	var lower_dir := (target - elbow)
	if lower_dir.length_squared() < 0.000001:
		lower_dir = upper_dir
	lower_dir = lower_dir.normalized()

	return {
		"upper": _basis_pointing(upper_dir, axis),
		"lower": _basis_pointing(lower_dir, axis),
		"elbow": elbow,
	}


## Base dont l'axe -Y pointe vers `direction` (convention d'os du gabarit).
## `axis` sert de référence de roulis pour que l'os ne vrille pas d'une frame
## à l'autre — sans lui, deux directions voisines pourraient produire deux
## orientations très différentes autour de l'axe de l'os.
static func _basis_pointing(direction: Vector3, axis: Vector3) -> Basis:
	var y := -direction
	var x := axis - y * axis.dot(y)
	if x.length_squared() < 0.000001:
		x = Vector3.RIGHT if absf(y.x) < 0.9 else Vector3.FORWARD
		x = x - y * x.dot(y)
	x = x.normalized()
	var z := x.cross(y).normalized()
	return Basis(x, y, z)


## Applique une base GLOBALE à un os, en la convertissant en pose locale.
## `set_bone_pose_rotation` attend une rotation RELATIVE AU REPOS : on retire
## donc la base du parent puis celle du repos. (Sur le gabarit généré les
## repos sont sans rotation, mais on ne le suppose pas — un modèle refait dans
## Blockbench pourrait en porter.)
static func apply_global_basis(skeleton: Skeleton3D, bone: int, global_basis_target: Basis) -> void:
	var parent := skeleton.get_bone_parent(bone)
	var parent_basis := skeleton.get_bone_global_pose(parent).basis if parent >= 0 else Basis.IDENTITY
	var local_basis := parent_basis.inverse() * global_basis_target
	var rest_basis := skeleton.get_bone_rest(bone).basis
	skeleton.set_bone_pose_rotation(bone, Quaternion(rest_basis.inverse() * local_basis).normalized())

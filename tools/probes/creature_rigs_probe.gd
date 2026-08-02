extends Probe
## Sonde `--probe-rigs-animaux` (2026-08-02) — les gabarits de corps non
## humanoides, toutes especes.
##
## Ce qu'elle prouve, espece par espece : le `.glb` se monte en corps jouable,
## le pilote DECOUVRE les bonnes capacites a partir du seul nommage des os
## (pattes, ailes, chaines souples), les chaines de pattes font DEUX os
## (condition du solveur analytique), le modele est pose au sol et sous le
## plafond du joueur, sa peau procedurale est appliquee, ses zones de coup
## existent et tiennent dans sa silhouette — et surtout : il BOUGE.
##
## POURQUOI LES CAPACITES ATTENDUES SONT ECRITES ICI. Le pilote les deduit du
## squelette ; les relire depuis le meme manifeste que lui ne testerait rien.
## Cette table est la SPECIFICATION, et c'est elle qui casse si un nommage
## derape dans le generateur.
##
## POURQUOI UNE SONDE ET PAS UN SCRIPT HORS-JEU. `CreatureBody` lit les blocs
## (`WorldManager`) pour ancrer les pattes : sans autoload il ne compile meme
## pas, et un test qui n'instancierait pas le corps ne prouverait rien de
## l'animation. Ici les corps sont montes dans le monde reel et animes sur
## plusieurs frames.

const TAG := "RIGS-ANIMAUX"

## espece : [famille, pattes, ailes, chaines souples]
##
## `colonne_1`/`colonne_2` compte comme une chaine souple, et c'est VOULU : la
## colonne d'un marcheur ondule legerement, ce qui donne le roulis du corps
## pendant la marche sans une ligne de code de plus. Une queue d'un seul os
## n'en est pas une (il faut deux maillons pour propager une onde).
const EXPECTED := {
	"chat":          ["quadrupede", 4, 0, 2],
	"loup":          ["quadrupede", 4, 0, 2],
	"ours":          ["quadrupede", 4, 0, 1],
	"cerf":          ["quadrupede", 4, 0, 1],
	"sanglier":      ["quadrupede", 4, 0, 1],
	"cheval":        ["quadrupede", 4, 0, 2],
	"rat":           ["quadrupede", 4, 0, 2],
	"lezard":        ["quadrupede", 4, 0, 2],
	"crocodile":     ["quadrupede", 4, 0, 2],
	"serpent":       ["serpentin", 0, 0, 1],
	"ver":           ["serpentin", 0, 0, 1],
	"poisson":       ["nageur", 0, 0, 1],
	"requin":        ["nageur", 0, 0, 1],
	"raie":          ["nageur", 0, 0, 3],
	"aigle":         ["volant", 2, 2, 1],
	"chauve_souris": ["volant", 2, 2, 1],
	"raptor":        ["bipede", 2, 0, 3],
	"autruche":      ["bipede", 2, 0, 2],
	"araignee":      ["arthropode", 8, 0, 0],
	"scarabee":      ["arthropode", 6, 0, 2],
	"crabe":         ["arthropode", 8, 0, 0],
	"abeille":       ["insecte_volant", 6, 4, 2],
	"mille_pattes":  ["segmente", 16, 0, 3],
	"pieuvre":       ["tentaculaire", 0, 0, 8],
	"meduse":        ["flottant", 0, 0, 6],
	"spectre":       ["flottant", 0, 0, 3],
	"dragon":        ["draconique", 4, 2, 3],
}
## Hauteur maximale toleree : PLAYER_HEIGHT vaut 2,0 et une creature plus haute
## traverserait les plafonds exactement comme le joueur le ferait.
const MAX_HEIGHT := 2.0


func run() -> void:
	await wait_frame()
	await wait_frame()
	var ok := true
	var failures: Array[String] = []
	for species: String in EXPECTED:
		if not await _check(species):
			ok = false
			failures.append(species)
	print("[%s] %d espece(s) verifiee(s)%s" % [TAG, EXPECTED.size(),
		"" if failures.is_empty() else " — EN ECHEC : " + ", ".join(failures)])
	finish(ok, TAG)


func _check(species: String) -> bool:
	var path := "res://models/creatures/%s.glb" % species
	var expected: Array = EXPECTED[species]
	if not ResourceLoader.exists(path):
		print("[%s] %-13s : modele INTROUVABLE" % [TAG, species])
		return false
	var body := CreatureBody.new()
	main.add_child(body)
	if not body.setup(path):
		print("[%s] %-13s : montage ECHOUE (pas de squelette ?)" % [TAG, species])
		body.queue_free()
		return false

	var skeleton: Skeleton3D = body.skeleton()
	var caps: Dictionary = body.capabilities()
	var family_ok: bool = body.family == expected[0]
	# Les capacites DECOUVERTES doivent etre celles que la geometrie annonce :
	# c'est le test qui garantit qu'un nouveau rig s'animera sans code.
	var caps_ok: bool = int(caps["pattes"]) == int(expected[1]) \
		and int(caps["ailes"]) == int(expected[2]) \
		and int(caps["chaines"]) == int(expected[3])

	# Chaines de pattes : DEUX os exactement, sinon le solveur analytique ne
	# s'applique pas et la patte se disloque a la premiere resolution.
	var chains_ok := _chains_ok(skeleton)
	var attach_ok := skeleton.find_bone("attach_tete") >= 0

	# Peau procedurale. Le `.glb` n'a AUCUNE texture et Godot ne reprend pas ses
	# couleurs par sommet : sans elle la creature sort entierement BLANCHE.
	var painted := 0
	var meshes := _meshes_of(body)
	for mesh: MeshInstance3D in meshes:
		var material := mesh.material_override as StandardMaterial3D
		if material != null and material.albedo_texture != null:
			painted += 1
	var skin_ok := not meshes.is_empty() and painted == meshes.size()

	# Assise : bas du modele a y = 0 et sous le plafond du joueur.
	var aabb := _aabb_of(meshes)
	var height := aabb.position.y + aabb.size.y
	var stance_ok := absf(aabb.position.y) < 0.02 and height <= MAX_HEIGHT + 0.001

	# Zones de coup : presentes, et CONTENUES dans la silhouette. Une boite plus
	# large que le modele ferait toucher a cote de la creature.
	var zones: Array = CreatureBody.hitboxes_for(path)
	var zones_ok := not zones.is_empty()
	for zone: Variant in zones:
		var z: Dictionary = zone
		var mn: Array = z["min"]
		var sz: Array = z["size"]
		var box := AABB(Vector3(mn[0], mn[1], mn[2]), Vector3(sz[0], sz[1], sz[2]))
		if not aabb.grow(0.02).encloses(box):
			zones_ok = false

	# LE POINT CENTRAL : l'animation procedurale bouge vraiment le squelette.
	var moved := await _poses_change(body, skeleton)

	var ok: bool = family_ok and caps_ok and chains_ok and attach_ok and skin_ok \
		and stance_ok and zones_ok and moved
	print("[%s] %-13s %-15s %s | %d pattes %d ailes %d chaines %s | chaines %s | attache %s | peau %d/%d | H %.2f y=%.3f %s | %d zone(s) %s | animee %s" % [
		TAG, species, body.family, "OK" if family_ok else "ATTENDU " + String(expected[0]),
		int(caps["pattes"]), int(caps["ailes"]), int(caps["chaines"]),
		"OK" if caps_ok else "INATTENDU",
		"OK" if chains_ok else "CASSEES", "OK" if attach_ok else "ABSENTE",
		painted, meshes.size(), height, aabb.position.y, "OK" if stance_ok else "KO",
		zones.size(), "OK" if zones_ok else "HORS SILHOUETTE",
		"OK" if moved else "FIGEE"])
	body.queue_free()
	return ok


## Toutes les chaines de pattes presentes font-elles racine -> milieu -> bout,
## chacune parent de la suivante ? Le balayage se fait sur les OS reels : le
## nombre de pattes est libre, seule la structure compte.
func _chains_ok(skeleton: Skeleton3D) -> bool:
	var names: Array[String] = []
	for i in skeleton.get_bone_count():
		names.append(skeleton.get_bone_name(i))
	for root: String in names:
		if not root.begins_with("cuisse"):
			continue
		var suffix := root.substr("cuisse".length())
		var mid := "mollet" + suffix
		var tip := ""
		for candidate: String in ["pied", "serre", "tarse"]:
			if (candidate + suffix) in names:
				tip = candidate + suffix
				break
		if tip == "" or not (mid in names):
			return false
		var a := skeleton.find_bone(root)
		var b := skeleton.find_bone(mid)
		var c := skeleton.find_bone(tip)
		if skeleton.get_bone_parent(b) != a or skeleton.get_bone_parent(c) != b:
			return false
	return true


## Anime le corps en le DEPLACANT, et constate qu'au moins un os change de pose.
## Le deplacement est indispensable : le cycle est pilote par la distance
## parcourue, pas par le temps — un corps pose sur place doit justement rester
## immobile, et le tester a l'arret validerait le contraire de ce qu'on veut.
func _poses_change(body: Node3D, skeleton: Skeleton3D) -> bool:
	var origin: Vector3 = camera.global_position + Vector3(0.0, -1.0, -2.0)
	body.update_as_entity(origin, 0.0, camera.global_position, 1.0 / 60.0)
	await wait_frame()
	var before: Array[Quaternion] = []
	for i in skeleton.get_bone_count():
		before.append(skeleton.get_bone_pose_rotation(i))
	for step in 12:
		# Avance de 8 cm par frame : au-dela d'un metre le code traite le saut
		# comme une teleportation et n'avancerait PAS le cycle (protection
		# voulue contre le voyage rapide).
		body.update_as_entity(origin + Vector3(0.0, 0.0, 0.08 * (step + 1)),
			0.0, camera.global_position, 1.0 / 60.0)
		await wait_frame()
	for i in skeleton.get_bone_count():
		if not before[i].is_equal_approx(skeleton.get_bone_pose_rotation(i)):
			return true
	return false


func _meshes_of(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		out.append_array(_meshes_of(child))
	return out


func _aabb_of(meshes: Array[MeshInstance3D]) -> AABB:
	var total := AABB()
	var first := true
	for mesh: MeshInstance3D in meshes:
		total = mesh.get_aabb() if first else total.merge(mesh.get_aabb())
		first = false
	return total

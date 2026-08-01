extends SceneTree
## Verification d'un rig humanoide contre la spec de models/creatures/LISEZMOI.md.
##
##   godot --headless --path . --script tools/verify_rig.gd
##
## A LANCER SUR TOUT MODELE EXPORTE DEPUIS BLOCKBENCH, avant de s'en servir :
## les contraintes du rig (chaines de 2 os, un maillage par os, tete separee,
## hauteur 2.0) ne se voient pas a l'oeil, elles se constatent au moment ou
## l'IK disloque un bras. Ce script les verifie en 2 secondes.
##
## N'utilise aucun autoload et ne genere aucun monde : il tourne meme quand les
## sondes de tools/probes/ sont bloquees.

const REQUIRED_ATTACH := ["attach_arme", "attach_arme_gauche", "attach_dos", "attach_tete"]
const CHAINS := [
	["bras_droit", "avantbras_droit", "main_droite"],
	["bras_gauche", "avantbras_gauche", "main_gauche"],
	["cuisse_droite", "mollet_droite", "pied_droite"],
	["cuisse_gauche", "mollet_gauche", "pied_gauche"],
]


func _init() -> void:
	var scene: PackedScene = load("res://models/creatures/humanoide.glb")
	if scene == null:
		print("ECHEC : modele introuvable ou illisible")
		quit(1)
		return
	var root := scene.instantiate()
	var skel: Skeleton3D = _find_skeleton(root)
	if skel == null:
		print("ECHEC : aucun Skeleton3D — le .glb n'a pas de squelette")
		quit(1)
		return

	var ok := true
	print("=== SQUELETTE : %d os ===" % skel.get_bone_count())
	var names: Array[String] = []
	for i in skel.get_bone_count():
		names.append(skel.get_bone_name(i))

	# 1. Os d'attache presents.
	for attach: String in REQUIRED_ATTACH:
		var found := attach in names
		print("  attache %-20s : %s" % [attach, "OK" if found else "MANQUANT"])
		ok = ok and found

	# 2. Chaines de 2 os EXACTEMENT (racine -> milieu -> extremite).
	print("=== CHAINES IK (2 os exactement) ===")
	for chain: Array in CHAINS:
		var a := skel.find_bone(chain[0])
		var b := skel.find_bone(chain[1])
		var c := skel.find_bone(chain[2])
		var chain_ok := a >= 0 and b >= 0 and c >= 0 \
			and skel.get_bone_parent(b) == a and skel.get_bone_parent(c) == b
		print("  %-16s -> %-20s -> %-16s : %s" % [chain[0], chain[1], chain[2],
			"OK" if chain_ok else "CASSEE"])
		ok = ok and chain_ok

	# 3. Colonne en 2 os.
	var s1 := skel.find_bone("colonne_1")
	var s2 := skel.find_bone("colonne_2")
	var spine_ok := s1 >= 0 and s2 >= 0 and skel.get_bone_parent(s2) == s1
	print("=== COLONNE : %s ===" % ("OK (2 os)" if spine_ok else "CASSEE"))
	ok = ok and spine_ok

	# 4. Un maillage par os, et tete/cheveux separes (premiere personne).
	var meshes: Array[String] = []
	_collect_meshes(root, meshes)
	print("=== MAILLAGES : %d ===" % meshes.size())
	meshes.sort()
	print("  " + ", ".join(meshes))
	var head_split := "mesh_tete" in meshes and "mesh_cheveux" in meshes
	print("  tete et cheveux separables : %s" % ("OK" if head_split else "NON"))
	ok = ok and head_split

	# 5. Hauteur totale : PLAYER_HEIGHT = 2.0 (fly_camera.gd).
	var aabb := _merged_aabb(root)
	var height := aabb.position.y + aabb.size.y
	print("=== HAUTEUR : %.3f unite(s) (attendu 2.000) ===" % height)
	var height_ok := absf(height - 2.0) < 0.01 and absf(aabb.position.y) < 0.01
	ok = ok and height_ok
	print("  pieds a y=%.3f (attendu 0.000)" % aabb.position.y)

	print("\n=== RESULTAT : %s ===" % ("CONFORME" if ok else "NON CONFORME"))
	quit(0 if ok else 1)


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null


func _collect_meshes(node: Node, out: Array[String]) -> void:
	if node is MeshInstance3D:
		out.append(node.name)
	for child in node.get_children():
		_collect_meshes(child, out)


func _merged_aabb(node: Node) -> AABB:
	var total := AABB()
	var first := true
	for child in node.get_children():
		if child is MeshInstance3D:
			var box: AABB = (child as MeshInstance3D).get_aabb()
			total = box if first else total.merge(box)
			first = false
		var sub := _merged_aabb(child)
		if sub.size != Vector3.ZERO:
			total = sub if first else total.merge(sub)
			first = false
	return total

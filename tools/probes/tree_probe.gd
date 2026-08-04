extends Probe
## Sonde `--probe-arbres` (2026-08-03) — abattage et intégrité des arbres.
##
## POURQUOI. Casser un bloc d'arbre laissait le reste SUSPENDU EN L'AIR dès
## qu'on ne visait pas le pied — le défaut classique du bûcheronnage voxel. Rien
## ne plante, rien ne se voit dans un chiffre : c'est de la structure de monde,
## donc exactement ce qu'une sonde doit vérifier bloc par bloc.

const TAG := "ARBRES"

var _ok := true


func _expect(condition: bool, message: String) -> void:
	print("[%s] %s — %s" % [TAG, "ok" if condition else "ÉCHEC", message])
	if not condition:
		_ok = false


func run() -> void:
	await wait_frame()
	var gen := WorldManager.generator
	if gen == null:
		print("[%s] aucun générateur — sonde inexploitable." % TAG)
		main.get_tree().quit(1)
		return

	var tree := _find_tree(gen)
	if tree.is_empty():
		print("[%s] aucun arbre trouvé dans la fenêtre de recherche." % TAG)
		main.get_tree().quit(1)
		return
	_check_silhouettes()
	_check_lookup(gen, tree)
	_check_felling(gen, tree)
	finish(_ok, TAG)


## SILHOUETTES RÉELLES (2026-08-03). Le catalogue comptait 38 essences pour 4
## formes, dont la sphère pour 25 d'entre elles : chêne, bouleau, érable et
## vingt autres étaient le même ballon sur un bâton, donc indistinguables.
##
## On mesure le PROFIL de chaque essence — élancement (hauteur/largeur) et
## position du houppier le plus large — parce que c'est ce qui identifie un arbre
## de loin. Deux essences de familles différentes doivent donner deux profils
## différents ; sinon la forme n'est qu'une étiquette dans un fichier.
func _check_silhouettes() -> void:
	var formes := {}
	var profils := {}
	for species_id: String in GameData.trees:
		var species: Dictionary = GameData.trees[species_id]
		formes[String(species.get("canopy_shape", "?"))] = true
		var tree := TreeGenerator.generate(Vector3i(0, 0, 0), 1337, species)
		var blocks: Dictionary = tree["blocks"]
		if blocks.is_empty():
			continue
		var min_y := 1 << 30
		var max_y := -(1 << 30)
		var max_r := 0.0
		var widest_y := 0
		var per_level := {}
		# ON IGNORE L'ÉVASEMENT DES RACINES (2026-08-03). Depuis que le pied
		# s'évase en contreforts, TOUTES les essences sont larges au ras du sol :
		# un cyprès mesurait 2,5 blocs de rayon à sa base pour 2 à sa cime, et
		# passait donc pour aussi trapu qu'un platane. L'élancement se lit sur le
		# HOUPPIER, pas sur les racines.
		var crown_floor := 3
		for pos: Vector3i in blocks:
			min_y = mini(min_y, pos.y)
			max_y = maxi(max_y, pos.y)
			if pos.y < crown_floor:
				continue
			var r := sqrt(float(pos.x * pos.x + pos.z * pos.z))
			per_level[pos.y] = maxf(float(per_level.get(pos.y, 0.0)), r)
			if r > max_r:
				max_r = r
				widest_y = pos.y
		var height := float(max_y - min_y + 1)
		var elancement := height / maxf(max_r * 2.0, 1.0)
		# Hauteur RELATIVE du houppier le plus large : bas pour un chêne, haut
		# pour un vase, au milieu pour un ovale.
		var hauteur_relative := float(widest_y - min_y) / maxf(height, 1.0)
		profils[species_id] = Vector2(elancement, hauteur_relative)

	print("[%s] formes de canopée employées : %d %s" % [TAG, formes.size(), formes.keys()])
	_expect(formes.size() >= 8, "le catalogue emploie au moins 8 silhouettes distinctes")

	# Comparaisons qui doivent tenir si les formes sont réelles.
	var paires := [
		["peuplier", "chene", "un peuplier est nettement plus élancé qu'un chêne"],
		["cypres", "platane", "un cyprès est nettement plus élancé qu'un platane"],
		["bouleau", "hetre", "un bouleau est plus élancé qu'un hêtre"],
	]
	for paire: Array in paires:
		var a: String = paire[0]
		var b: String = paire[1]
		if not (profils.has(a) and profils.has(b)):
			continue
		var ea: float = (profils[a] as Vector2).x
		var eb: float = (profils[b] as Vector2).x
		print("[%s] élancement %s=%.2f  %s=%.2f" % [TAG, a, ea, b, eb])
		_expect(ea > eb * 1.4, String(paire[2]))

	# L'ORME EST UN VASE : son houppier le plus large est HAUT ; le chêne, bas.
	if profils.has("orme") and profils.has("chene"):
		var ho: float = (profils["orme"] as Vector2).y
		var hc: float = (profils["chene"] as Vector2).y
		print("[%s] houppier le plus large — orme à %.0f %% de la hauteur, chêne à %.0f %%" % [
				TAG, ho * 100.0, hc * 100.0])
		_expect(ho > hc, "l'orme s'évase vers le haut, le chêne s'étale bas")


## Premier arbre trouvé autour du spawn.
func _find_tree(gen: NoiseGenerator) -> Dictionary:
	for radius in range(0, 40):
		for dx in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				if absi(dx) != radius and absi(dz) != radius:
					continue
				var trees: Array = gen.call("_trees_in_window", dx * 8, dx * 8, dz * 8, dz * 8)
				for tree: Dictionary in trees:
					if not (tree.get("blocks", {}) as Dictionary).is_empty():
						return tree
	return {}


## LA REQUÊTE INVERSE doit reconnaître N'IMPORTE QUEL bloc de l'arbre — pas
## seulement son pied. C'est elle qui rend l'abattage possible depuis une
## branche ou une feuille.
func _check_lookup(gen: NoiseGenerator, tree: Dictionary) -> void:
	var blocks: Dictionary = tree["blocks"]
	var base: Vector3i = tree["base"]
	var wood: Array = tree["wood_positions"]
	print("[%s] arbre « %s » en %s : %d bloc(s), dont %d de bois" % [
			TAG, String(tree.get("species_id", "?")), base, blocks.size(), wood.size()])

	# Le pied, un bloc de bois haut, et un bloc de feuillage.
	var sommet: Vector3i = base
	for pos: Vector3i in wood:
		if pos.y > sommet.y:
			sommet = pos
	var feuille := Vector3i(1 << 30, 0, 0)
	for pos: Vector3i in blocks:
		if not (pos in wood):
			feuille = pos
			break

	# VOLUME DE BOIS. Il pilote le temps d'abattage et le butin, et il ne doit
	# pas être le nombre de BLOCS touchés : depuis que les branches se tracent
	# au pas de 8 px, un chêne touche des centaines de blocs dont la plupart ne
	# contiennent qu'une brindille. Sans ce garde-fou, la régression serait
	# invisible en jeu jusqu'à ce qu'un joueur passe dix minutes sur un arbre.
	var volume := float(tree.get("wood_volume", -1.0))
	print("[%s] volume de bois : %.1f bloc(s) pleins pour %d bloc(s) touchés" % [
			TAG, volume, wood.size()])
	_expect(volume >= 1.0, "le volume de bois est renseigné et non nul")
	_expect(volume < float(wood.size()), "le volume est inférieur au nombre de blocs touchés")

	_expect(not gen.tree_containing(base.x, base.y, base.z).is_empty(),
			"le pied est reconnu comme appartenant à l'arbre")
	_expect(not gen.tree_containing(sommet.x, sommet.y, sommet.z).is_empty(),
			"un bloc de tronc haut est reconnu")
	if feuille.x != 1 << 30:
		_expect(not gen.tree_containing(feuille.x, feuille.y, feuille.z).is_empty(),
				"un bloc de feuillage est reconnu")
	# ET UN BLOC HORS ARBRE NE L'EST PAS : sans ce témoin, une requête qui
	# répondrait « oui » à tout passerait les trois tests ci-dessus.
	_expect(gen.tree_containing(base.x + 40, base.y, base.z + 40).is_empty(),
			"un bloc éloigné n'appartient à aucun arbre")


## ABATTAGE : après avoir cassé un bloc QUELCONQUE, plus aucun bloc de l'arbre
## ne doit subsister. Un tronc restant en l'air est le défaut qu'on corrige.
func _check_felling(gen: NoiseGenerator, tree: Dictionary) -> void:
	var blocks: Dictionary = tree["blocks"]
	var wood: Array = tree["wood_positions"]
	# On vise un bloc de feuillage s'il y en a un, sinon le sommet du tronc :
	# c'est le cas que l'ancienne règle (« seul le pied abat ») ratait.
	var cible: Vector3i = tree["base"]
	for pos: Vector3i in blocks:
		if not (pos in wood):
			cible = pos
			break
	print("[%s] on casse %s (feuillage ou cime), pas le pied %s" % [TAG, cible, tree["base"]])

	# On rejoue ce que fait le joueur quand l'abattage aboutit.
	var abattu: Dictionary = gen.tree_containing(cible.x, cible.y, cible.z)
	_expect(not abattu.is_empty(), "le bloc visé désigne bien son arbre")
	if abattu.is_empty():
		return
	for pos: Vector3i in (abattu["blocks"] as Dictionary):
		WorldManager.set_block(pos, 0)

	var restants := 0
	for pos: Vector3i in blocks:
		if WorldManager.block_at_world(pos) != 0:
			restants += 1
	print("[%s] après abattage : %d bloc(s) restant(s) sur %d" % [TAG, restants, blocks.size()])
	_expect(restants == 0, "aucun morceau d'arbre ne reste suspendu en l'air")

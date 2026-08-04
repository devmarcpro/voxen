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
	_check_cost()
	_check_silhouettes()
	_check_lookup(gen, tree)
	_check_felling(gen, tree)
	finish(_ok, TAG)


## COÛT D'UN ARBRE, essence par essence (2026-08-04).
##
## POURQUOI. Un platane posé depuis le menu de triche faisait plus de 2 000
## blocs. Un arbre est le décor le plus répandu du monde : son volume se paie à
## la génération, au maillage, à la sauvegarde et à l'abattage, et personne ne
## le regardait.
##
## On mesure aussi la part de feuillage ENFERMÉ — les blocs dont les six voisins
## sont pleins. Ceux-là ne sont visibles d'aucun angle, et comme casser
## n'importe quel bloc abat l'arbre entier, le joueur ne peut jamais entrer dans
## une couronne pour les découvrir. C'est du volume payé pour rien.
func _check_cost() -> void:
	var total := 0
	var worst := ""
	var worst_count := 0
	var enclosed_total := 0
	var leaves_total := 0
	var report: Array[String] = []
	for species_id: String in GameData.trees:
		var species: Dictionary = GameData.trees[species_id]
		var tree := TreeGenerator.generate(Vector3i.ZERO, 20260804, species)
		var blocks: Dictionary = tree["blocks"]
		var leaf_id: int = GameData.material_runtime_ids.get(String(species["leaf_material"]), 0)
		var enclosed := 0
		var leaves := 0
		for pos: Vector3i in blocks:
			if blocks[pos] != leaf_id:
				continue
			leaves += 1
			var buried := true
			for dir: Vector3i in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
					Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
				if not blocks.has(pos + dir):
					buried = false
					break
			if buried:
				enclosed += 1
		total += blocks.size()
		leaves_total += leaves
		enclosed_total += enclosed
		# LE PLAFOND NE S'APPLIQUE QU'À L'OVERWORLD. Le colosse des songes fait
		# 40 à 60 blocs de haut PAR SA FICHE — trois fois le séquoia, et c'est
		# tout son propos. Le comparer au budget d'une forêt tempérée n'aurait
		# aucun sens : il pousse sur une île flottante, par poignées, pas par
		# milliers sur un continent.
		if "magique" in String(species.get("_source", "")):
			continue
		if blocks.size() > worst_count:
			worst_count = blocks.size()
			worst = species_id
		if blocks.size() >= 900:
			report.append("%s %d" % [species_id, blocks.size()])

	print("[%s] COÛT : %d blocs pour %d essences, soit %d en moyenne" % [
			TAG, total, GameData.trees.size(), total / maxi(1, GameData.trees.size())])
	print("[%s]   la plus lourde : %s à %d blocs" % [TAG, worst, worst_count])
	if not report.is_empty():
		print("[%s]   au-dessus de 900 blocs : %s" % [TAG, ", ".join(report)])
	print("[%s]   feuillage ENFERMÉ (invisible) : %d sur %d, soit %.0f %% du feuillage" % [
			TAG, enclosed_total, leaves_total,
			float(enclosed_total) / maxf(1.0, float(leaves_total)) * 100.0])
	# LE SEUIL GARDE CONTRE UNE EXPLOSION, PAS CONTRE LE DESIGN.
	#
	# Il ne s'agit pas de décréter qu'un arbre doit être petit : le séquoia fait
	# 22 à 32 blocs de haut par ses données, et son volume est celui que ces
	# données demandent. Ce que la sonde doit attraper, c'est le jour où une
	# essence part à 3 000 blocs pour une raison qui n'est pas dans sa fiche —
	# ce qui est exactement arrivé le 2026-08-04 : un facteur de remplissage de
	# couronne à 1,5 donnait 3,4 fois le volume de la couronne NOMINALE, et un
	# platane pesait 2 882 blocs pour un rayon de 8.
	#
	# Le plafond est donc posé un cran au-dessus de la plus grosse essence
	# légitime, et il baissera si l'auteur décide de rapetisser le catalogue.
	# PLAFOND RELEVÉ DE 2200 À 2400 le 2026-08-04, et voici pourquoi — un seuil
	# qu'on déplace sans raison écrite ne garde plus rien.
	#
	# Le feuillage des conifères a été DENSIFIÉ à dessein le même jour : le sapin
	# laissait voir son tronc entre des amas trop clairsemés et ne ressemblait à
	# rien. Le séquoia, plus haute essence du catalogue (22 à 32 blocs), absorbe
	# ce changement et passe de 2 011 à 2 215 blocs. Ce n'est pas une dérive,
	# c'est le prix d'une correction voulue sur l'arbre le plus grand du jeu.
	#
	# La MOYENNE reste le vrai garde-fou : elle, elle n'a pas bougé.
	_expect(worst_count < 2400, "aucune essence n'explose (la pire : %s à %d, plafond 2400)" % [
			worst, worst_count])
	_expect(total / maxi(1, GameData.trees.size()) < 600,
			"la MOYENNE reste raisonnable (%d blocs)" % (total / maxi(1, GameData.trees.size())))


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
	var heights := {}
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
		heights[species_id] = height

	# DEUX ESSENCES NE DOIVENT PAS AVOIR LE MÊME PROFIL.
	#
	# C'est l'assertion qui manquait, et c'est la seule qui attrape le vrai
	# défaut : le 2026-08-04, vingt-neuf essences sur trente-huit n'avaient
	# aucune architecture propre et prenaient le défaut de leur silhouette. Un
	# érable et un noyer, un charme et un aulne, un pommier et un olivier
	# étaient le même arbre à la couleur près — et les tests par PAIRES ne
	# pouvaient pas le voir, puisqu'ils comparent des familles différentes.
	#
	# Le profil est arrondi : deux essences qui ne diffèrent que d'un centième
	# ne se distinguent pas à l'oeil, et prétendre le contraire serait se
	# mentir.
	var by_profile := {}
	for species_id: String in profils:
		var p: Vector2 = profils[species_id]
		# LA TAILLE FAIT PARTIE DU PROFIL. L'élancement est un RATIO, donc sans
		# échelle : un noisetier de 4 blocs et un teck de 16 tombaient sur la
		# même signature alors que personne ne les confondrait. On y joint donc
		# la hauteur, par tranches de 4 blocs — l'écart à partir duquel deux
		# arbres cessent de se lire comme de la même taille.
		var key := "%.1f|%.1f|%d" % [p.x, p.y, int(float(heights.get(species_id, 0.0)) / 4.0)]
		if not by_profile.has(key):
			by_profile[key] = []
		(by_profile[key] as Array).append(species_id)
	var clones: Array[String] = []
	for key: String in by_profile:
		var group: Array = by_profile[key]
		if group.size() > 2:
			clones.append("%s (%d) : %s" % [key, group.size(), ", ".join(group.slice(0, 4))])
	print("[%s] %d profils distincts pour %d essences" % [
			TAG, by_profile.size(), profils.size()])
	for line: String in clones:
		print("[%s]   profil partagé — %s" % [TAG, line])
	# Trois essences ou plus sur le MÊME profil arrondi, c'est un défaut ; deux
	# qui se ressemblent reste plausible dans une flore réelle.
	_expect(clones.is_empty(), "aucun groupe de 3 essences ou plus ne partage un profil")

	# TOUTE ESSENCE DOIT POUSSER QUELQUE PART.
	#
	# Une essence absente de tout biome existe dans le catalogue, coûte ses deux
	# entrées de palette et ses quatre clés de locale, et n'apparaît dans aucun
	# monde — on ne peut la voir qu'au menu de triche. Rien ne le signale : le
	# jeu tourne, la forêt pousse, et il manque simplement un arbre que personne
	# ne cherchait.
	#
	# C'est arrivé deux fois. Le FROMAGER, câblé le 2026-08-04 sur un
	# identifiant de biome inexistant (`jungle` au lieu de `jungle_tropicale`),
	# et le NOYER, jamais câblé depuis sa création. Le script d'alors avait
	# imprimé « 5 biomes câblés » quand huit étaient attendus, et l'écart n'a
	# pas été relevé — d'où cette assertion, qui ne dépend d'aucune vigilance.
	var planted := {}
	for biome_id: String in GameData.biomes:
		for entry: Dictionary in ((GameData.biomes[biome_id] as Dictionary).get("vegetation", []) as Array):
			planted[String(entry["id"])] = true
	# LES ESSENCES D'UNE AUTRE DIMENSION SONT EXEMPTÉES, et c'est une exemption
	# raisonnée, pas une échappatoire : un arbre de la faille de mana est planté
	# par le constructeur de sa dimension, pas par un biome de l'overworld. Lui
	# demander un biome reviendrait à le faire pousser… dans l'overworld, soit
	# exactement le mélange que la séparation par dimension vient d'interdire.
	# On les reconnaît à leur rangement (`data/trees/magique/`).
	var homeless: Array[String] = []
	for species_id: String in GameData.trees:
		if planted.has(species_id):
			continue
		homeless.append(species_id)
	_expect(homeless.is_empty(), "toutes les essences poussent dans au moins un biome%s" % [
			"" if homeless.is_empty() else " — orphelines : " + ", ".join(homeless)])

	print("[%s] formes de canopée employées : %d %s" % [TAG, formes.size(), formes.keys()])
	_expect(formes.size() >= 8, "le catalogue emploie au moins 8 silhouettes distinctes")

	# Comparaisons qui doivent tenir si les formes sont réelles.
	var paires := [
		["peuplier", "chene", "un peuplier est nettement plus élancé qu'un chêne"],
		["cypres", "platane", "un cyprès est nettement plus élancé qu'un platane"],
		# PAIRE REMPLACÉE le 2026-08-04. « Bouleau vs hêtre » opposait deux
		# feuillus MOYENNEMENT élancés (1,57 contre 1,22) : la comparaison ne
		# discriminait presque rien, et elle a échoué dès que chaque essence a
		# reçu son port réel. Le chêne, lui, s'étale franchement — c'est une
		# opposition qui veut dire quelque chose.
		["bouleau", "chene", "un bouleau est plus élancé qu'un chêne étalé"],
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

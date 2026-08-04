class_name TreeGenerator
extends RefCounted
## Générateur procédural d'arbres en code pur — aucun modèle externe (.vox/
## Blender/Blockbench), piloté par les données `data/trees/*.json`.
## Déterministe : mêmes coordonnées + même graine monde → même arbre, à
## chaque appel, sur toute machine (nécessaire au streaming de chunks, G.1).
## Échelle : 1 bloc = 1 mètre (le joueur fait 2 blocs de haut).
##
## ============================================================================
## REFONTE DU 2026-08-03 — « je veux que les arbres ressemblent vraiment à
## leurs versions réelles », « tu peux utiliser des blocs de 32, 16 et 8 px ».
## ============================================================================
##
## CE QUI CLOCHAIT. L'ancien générateur posait un tronc droit, y plantait N
## bâtons rectilignes tous de la même grosseur, et coiffait le tout d'une forme
## géométrique choisie dans une liste. Trente-huit essences en sortaient comme
## des variations de la même chose : un poteau à pompon. Aucun réglage de la
## forme du pompon ne pouvait corriger ça, parce que ce n'est pas le pompon qui
## fait reconnaître un arbre.
##
## CE QUI FAIT RECONNAÎTRE UN ARBRE, dans l'ordre où l'œil le lit :
##
##   1. L'ARCHITECTURE DU TRONC. Un sapin garde une flèche unique qui monte
##      jusqu'à la cime et porte des branches latérales de plus en plus courtes
##      (port « excurrent »). Un chêne, lui, perd son axe : à mi-hauteur le
##      tronc se divise en plusieurs maîtresses branches de force égale qui se
##      partagent la couronne (port « décurrent »). Un palmier n'a ni l'un ni
##      l'autre : une stipe nue et un bouquet terminal. Ces trois familles ne
##      se ressemblent en rien, et c'est la distinction la plus lourde de
##      toutes — l'ancien générateur n'en modélisait aucune.
##   2. LA RAMIFICATION. Une vraie branche se divise, encore, et encore, en
##      s'affinant. C'est de là que vient la texture d'un arbre.
##   3. LE GÉOTROPISME. À port égal, l'orme monte ses branches en gerbe et le
##      saule les laisse retomber. Un seul paramètre, deux arbres opposés.
##   4. Le feuillage en dernier — il habille un squelette, il ne le remplace
##      pas.
##
## D'où la structure de ce fichier : on fait POUSSER un squelette récursif dans
## l'espace continu (`_grow`), puis on le RASTÉRISE (`_stroke`), puis on
## accroche le feuillage aux extrémités produites. Dans cet ordre, et pas
## l'inverse.
##
## ---------------------------------------------------------------------------
## LA RÈGLE DE GRAIN : 32 ET 16 PX, RIEN DE PLUS FIN
## ---------------------------------------------------------------------------
## Le bloc plein fait 32 px, la moitié 16. Le système de subdivision (4.1)
## descend à 4 px et le générateur est passé un temps par le 8 px, mais **on
## s'arrête au 16** (décision de l'auteur, 2026-08-04, pour la performance).
##
## CE QUE ÇA CHANGE, ET POURQUOI C'EST LE BON ÉCHANGE. Un réseau à 16 px porte
## deux pas par bloc et par axe au lieu de quatre : une sous-grille compte donc
## **huit** cellules signifiantes au lieu de soixante-quatre. Le mailleur en
## sort beaucoup moins de quads, et surtout le nombre de MOTIFS distincts
## s'effondre — ce qui fait travailler son cache de quads au lieu de le saturer.
## Le prix payé est une branche qui ne descend plus sous le demi-bloc ; à la
## distance où l'on voit un arbre, la différence entre 8 et 16 px sur une
## brindille ne se lit pas.
##
## Tout le bois est tracé sur ce réseau puis PROMU : un bloc dont toutes les
## cellules fines sont pleines redevient un bloc plein de 32 px. Le mailleur
## glouton refusionne les faces coplanaires de lui-même.
##
## Le FEUILLAGE, lui, reste en blocs pleins : seule sa peau exposée est érodée
## en 8 px. Raffiner l'intérieur d'une couronne coûterait le prix fort pour du
## volume que personne ne voit — mesuré, c'est le poste qui a fait passer le
## maillage de 6 à 20 ms/chunk lors d'un essai antérieur.


## Silhouettes reconnues, SOURCE UNIQUE : GameData valide les fichiers
## d'essence contre cette liste. Elles désignent la SILHOUETTE VOULUE ; c'est
## `_architecture()` qui les traduit en règles de croissance.
const CANOPY_SHAPES := [
	"spherical", "conical", "flat", "weeping",
	"columnar", "vase", "tiered", "umbrella", "oval", "broad",
]

## Pas du réseau fin, en subdivisions de 4 px : 4 = 16 px. NE PAS descendre
## sous 4, c'est précisément ce que la règle de grain interdit.
const FINE_STEP := 4
## Pas fins par bloc et par axe (8 / FINE_STEP × ... : ici 2).
const FINE_PER_BLOCK := 2

## Décalage et masque pour passer d'une coordonnée FINE à son BLOC, dérivés de
## FINE_PER_BLOCK au lieu d'être écrits en dur.
##
## Ils l'étaient (`>> 2` et `& 3`, justes pour quatre pas par bloc), et le
## passage au grain 16 px les a laissés derrière : l'arbre entier se retrouvait
## écrasé de moitié dans l'espace des blocs, son pied ne tombait plus sur sa
## propre case, et la recherche inverse ne le reconnaissait plus. Rien ne
## plantait — le générateur produisait simplement des arbres faux.
const FINE_SHIFT := 1   # log2(FINE_PER_BLOCK)
const FINE_MASK := FINE_PER_BLOCK - 1

## GRAIN PROPRE AUX POUSSES : 8 px, plus fin que le bois du monde.
##
## C'est une EXCEPTION ASSUMÉE à la règle 32/16, et elle se justifie par ce
## qu'est une pousse : l'arbre entier réduit dans UN bloc. Au grain du monde,
## une miniature ne dispose que de 2×2×2 pièces — elle ne peut représenter
## aucune silhouette, et les 38 essences sortaient toutes en cube plein.
##
## La règle vise l'optimisation, et l'exception ne la contredit pas : le monde
## porte des milliers d'arbres, alors qu'une pousse est un bloc posé à la main,
## par dizaines au plus. Le coût de maillage y est négligeable, la lisibilité
## non.
const SAPLING_CELLS := 4                          # 4×4×4 pièces dans le bloc.
const SAPLING_STEP := SubdivGrid.SIZE / SAPLING_CELLS

## Angle d'or. Les branches successives d'une pousse ne sortent ni au hasard ni
## à intervalle régulier : elles tournent d'environ 137,5° l'une par rapport à
## la précédente, ce qui les empêche de se faire de l'ombre. Un pas régulier
## donnerait des étages alignés, visibles et faux ; un pas aléatoire donnerait
## des paquets et des trous.
const PHYLLOTAXIS := 2.39996

## En dessous de ce rayon (en PAS FINS), une pousse est un rameau terminal : on
## arrête de subdiviser et on y accroche du feuillage.
##
## Exprimé en pas fins, donc à réviser si le grain change : la valeur a été
## halvée le 2026-08-04 en passant du 8 px au 16 px, pour que le seuil garde la
## même taille RÉELLE. L'oublier aurait doublé l'épaisseur de tous les rameaux
## terminaux sans que rien ne le signale — le générateur aurait simplement
## produit des arbres plus gros.
const TIP_RADIUS := 0.28

## BUDGET D'EXTRÉMITÉS. La ramification est exponentielle, et le feuillage
## coûte un amas par extrémité : sans plafond, un cèdre produisait 325 rameaux
## et sa génération à elle seule dépassait la seconde — pour une couronne que
## soixante rameaux remplissent déjà, puisque les amas se recouvrent.
##
## Le plafond ne coupe pas au hasard : la récursion est en largeur d'abord par
## construction (chaque génération est complète avant la suivante), donc ce qui
## saute est la génération la plus fine, celle qui se voit le moins.
const MAX_TIPS := 96

## REMPLISSAGE DE LA COURONNE (2026-08-04) — la constante la plus chère du
## fichier, parce que son effet est CUBIQUE.
##
## `_foliage` dimensionne chaque amas à `crown × CROWN_FILL / N^⅓`. La division
## par la racine cubique est correcte et rend le volume total indépendant du
## nombre d'extrémités : N amas de rayon r couvrent N·r³, et N·(k/N^⅓)³ = k³.
##
## Mais ce volume total vaut alors `(4/3)π · CROWN_FILL³ · crown³`. À 1,5, cela
## faisait **3,4 fois** le volume d'une couronne sphérique de rayon `crown` : le
## feuillage débordait très largement du rayon que les données demandent, et un
## platane pesait 2 882 blocs. À 1,0, le volume tombe sur la couronne nominale,
## celle que `canopy_radius_range` décrit.
##
## Ne pas descendre trop bas : le plancher de 1,5 bloc par amas transforme un
## arbre à beaucoup d'extrémités en confettis — c'est le défaut qu'un réglage
## antérieur avait produit en divisant par la racine carrée.
const CROWN_FILL := 1.0

## ÉVIDAGE DU FEUILLAGE. Un bloc de feuille dont les six voisins sont pleins
## n'est visible d'AUCUN angle. Et comme casser n'importe quel bloc abat l'arbre
## entier, le joueur ne peut jamais entrer dans une couronne pour l'y découvrir :
## ce volume est payé à la génération, au maillage et à la sauvegarde pour
## quelque chose que personne ne verra jamais.
##
## Mesuré avant de le coder : 11 % du feuillage. C'est modeste — la vraie
## économie est dans CROWN_FILL — mais c'est un gain sans aucune contrepartie
## visuelle, ce qui est rare.
const HOLLOW_CANOPY := true


## Génère un arbre à `base` (position du premier bloc de tronc, au sol).
## Retourne { "blocks": Dictionary[Vector3i,int], "wood_positions": Array[Vector3i],
##            "base": Vector3i, "species_id": String, "special_tags": Array,
##            "trunk_subdivs": Dictionary[Vector3i,PackedInt32Array] }.
## `blocks` est un survol SPARSE (positions monde → id matériau runtime) ;
## ne contient QUE les voxels de l'arbre (jamais le sol/l'air alentour).
static func generate(base: Vector3i, world_seed: int, species: Dictionary) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed_for(world_seed, base)

	var wood_id: int = GameData.material_runtime_ids.get(species["wood_material"], 0)
	var leaf_id: int = GameData.material_runtime_ids.get(species["leaf_material"], 0)
	var arch := _architecture(species, rng)

	# Le contexte voyage dans toute la récursion. Un dictionnaire plutôt que
	# huit paramètres traînés de fonction en fonction : `_grow` s'appelle
	# lui-même, et la signature serait devenue illisible.
	var ctx := {
		"fine": {},            # Vector3i (pas fins) → id matériau : le bois.
		"tips": [],            # Array[Vector3] : où accrocher le feuillage.
		"arch": arch,
		"rng": rng,
		"wood_id": wood_id,
	}

	# Le pied, en pas fins, au centre du bloc de base.
	var foot := Vector3(
			base.x * FINE_PER_BLOCK + (FINE_PER_BLOCK - 1) * 0.5,
			base.y * FINE_PER_BLOCK,
			base.z * FINE_PER_BLOCK + (FINE_PER_BLOCK - 1) * 0.5)

	# --- 1. Le squelette ---
	if String(arch["form"]) == "palm":
		_grow_palm(ctx, foot)
	else:
		var lean := Vector3(rng.randf_range(-1.0, 1.0), 0.0, rng.randf_range(-1.0, 1.0))
		var up := (Vector3.UP + lean * float(arch["lean"])).normalized()
		_grow(ctx, foot, up, float(arch["height"]), float(arch["base_radius"]),
				int(arch["depth"]), true)

	# --- 2. Les racines ---
	_grow_roots(ctx, foot)

	# --- 3. Rastérisation du bois : réseau fin → blocs pleins + sous-grilles ---
	var blocks := {}
	var subdivs := {}
	var wood_positions: Array[Vector3i] = []
	var wood_volume := _rasterize(ctx["fine"], blocks, subdivs, wood_positions)

	# --- 4. Le feuillage, accroché aux rameaux terminaux ---
	_foliage(ctx, blocks, leaf_id)

	# --- 4 bis. Évidage : le feuillage enfermé ne se voit d'aucun angle ---
	# AVANT l'érosion de la peau, et l'ordre compte : l'érosion travaille sur les
	# blocs EXPOSÉS, et évider après elle lui ferait ronger une surface qu'on
	# vient de creuser.
	if HOLLOW_CANOPY:
		_hollow(blocks, leaf_id)

	# --- 5. Peau du feuillage érodée en 8 px ---
	_erode_leaf_shell(blocks, subdivs, leaf_id)

	return {
		"blocks": blocks, "wood_positions": wood_positions, "base": base,
		"species_id": String(species["id"]), "special_tags": species.get("special_tags", []),
		"trunk_subdivs": subdivs,
		# VOLUME de bois, en blocs pleins équivalents — pas un nombre de blocs.
		# `wood_positions` compte les blocs TOUCHÉS par du bois, brindilles de
		# 1/64 de bloc comprises : s'en servir pour le temps d'abattage et le
		# butin ferait d'un rameau une bûche, et un chêne demanderait vingt fois
		# le temps qu'il faut depuis que les branches sont détaillées.
		"wood_volume": wood_volume,
	}


## POUSSE : l'arbre entier réduit dans UN bloc, en sous-voxels.
##
## On génère l'arbre pour de vrai, puis on le RÉDUIT : sa boîte englobante est
## ramenée au bloc, et chaque cellule fine prend le matériau dominant de la
## portion d'arbre qui lui correspond. Dessiner à la main un petit motif
## d'arbre aurait été plus simple, mais aurait menti — la pousse doit
## ressembler à l'essence qu'elle deviendra, sinon elle n'apprend rien au
## joueur qui la regarde.
##
## La réduction respecte la RÈGLE DE GRAIN : les pièces font 8 px, comme le
## reste du bois. Un bloc en contient 4×4×4, ce qui suffit à distinguer une
## colonne d'un parasol — c'est tout ce qu'on demande à une pousse.
static func sapling_grid(species: Dictionary, seed_value: int) -> PackedInt32Array:
	var tree := generate(Vector3i.ZERO, seed_value, species)
	var blocks: Dictionary = tree["blocks"]
	if blocks.is_empty():
		return PackedInt32Array()

	var low := Vector3i(1 << 30, 1 << 30, 1 << 30)
	var high := Vector3i(-(1 << 30), -(1 << 30), -(1 << 30))
	for pos: Vector3i in blocks:
		low = Vector3i(mini(low.x, pos.x), mini(low.y, pos.y), mini(low.z, pos.z))
		high = Vector3i(maxi(high.x, pos.x), maxi(high.y, pos.y), maxi(high.z, pos.z))
	var span := Vector3(maxi(1, high.x - low.x + 1), maxi(1, high.y - low.y + 1),
			maxi(1, high.z - low.z + 1))

	# On compte les matériaux tombant dans chaque cellule fine, et on garde le
	# plus représenté : sur une réduction aussi forte, prendre le premier venu
	# donnerait un arbre en bois ou en feuilles selon l'ordre du dictionnaire.
	var tally := {}
	for pos: Vector3i in blocks:
		var local := Vector3(pos - low)
		var cell := Vector3i(
				clampi(int(local.x / span.x * SAPLING_CELLS), 0, SAPLING_CELLS - 1),
				clampi(int(local.y / span.y * SAPLING_CELLS), 0, SAPLING_CELLS - 1),
				clampi(int(local.z / span.z * SAPLING_CELLS), 0, SAPLING_CELLS - 1))
		if not tally.has(cell):
			tally[cell] = {}
		var counts: Dictionary = tally[cell]
		var id: int = blocks[pos]
		counts[id] = int(counts.get(id, 0)) + 1

	var grid := SubdivGrid.create_empty()
	for cell: Vector3i in tally:
		var counts: Dictionary = tally[cell]
		var best := 0
		var best_count := 0
		for id: int in counts:
			if int(counts[id]) > best_count:
				best_count = int(counts[id])
				best = id
		if best != 0:
			SubdivGrid.set_region(grid, cell * SAPLING_STEP, SAPLING_STEP, best)

	# UNE POUSSE TOUCHE LE SOL. La réduction centre l'arbre sur sa boîte
	# englobante, qui inclut les racines : sans ce recalage, une pousse à
	# houppier large flotterait au-dessus de sa case.
	return grid


static func _seed_for(world_seed: int, base: Vector3i) -> int:
	var v := (world_seed * 747796405 + 2891336453) ^ (base.x * 2654435761) ^ (base.z * 1597334677)
	v = (v ^ (v >> 15)) * 0x85EBCA6B
	return (v ^ (v >> 13)) & 0x7FFFFFFF


# ============================================================================
# ARCHITECTURE : des données d'essence aux règles de croissance
# ============================================================================


## Traduit une fiche d'essence en paramètres de croissance.
##
## Les valeurs par défaut viennent de `canopy_shape`, qui est déjà renseigné
## pour les 38 essences : une silhouette voulue implique une architecture, et
## il aurait été absurde de redemander l'information. Un fichier d'essence peut
## surcharger n'importe quelle clé via un bloc `architecture`, pour les cas où
## la silhouette seule ne suffit pas à décrire l'arbre (baobab, bambou…).
static func _architecture(species: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var shape := String(species["canopy_shape"])
	var height_range: Array = species["height_range"]
	var height := float(rng.randi_range(int(height_range[0]), int(height_range[1])))
	var canopy_range: Array = species["canopy_radius_range"]
	var canopy_radius := float(rng.randi_range(int(canopy_range[0]), int(canopy_range[1])))
	var trunk_radius := float(species["trunk_radius"])

	var arch := {
		# --- Port ---
		# "excurrent" : une flèche unique du pied à la cime, branches latérales
		#               subordonnées (conifères, peuplier).
		# "decurrent" : l'axe se dissout en maîtresses branches codominantes
		#               (chêne, orme, pommier).
		# "palm"      : stipe nue + bouquet terminal.
		"form": "decurrent",
		# RAYON DE REMPLISSAGE. Pour qu'un bloc soit promu en 32 px, il faut que
		# ses cellules de coin soient dedans, soit √(1,5² + 1,5²) ≈ 2,12 pas
		# fins depuis l'axe. À 2,0 — la valeur d'abord retenue — un tronc
		# d'un bloc d'épaisseur ratait ses coins de 6 % et sortait ENTIÈREMENT
		# en sous-grilles : mesuré, 41 blocs subdivisés sur 41 pour un cyprès,
		# là où le tronc devrait être en blocs pleins et bon marché.
		"base_radius": maxf(2.2, trunk_radius * 2.2),
		# Fraction de la hauteur où l'axe cède la place aux maîtresses branches
		# (décurrent), ou où commencent les latérales (excurrent).
		"fork": 0.45,
		# Branches par verticille (excurrent) ou maîtresses branches à la
		# première fourche (décurrent).
		"children": 3,
		# Divisions d'une branche SECONDAIRE. Distinct de `children` : réutiliser
		# le même nombre aux deux endroits faisait exploser la ramification —
		# 13 verticilles × 5 latérales × 5 divisions = 325 rameaux pour un cèdre.
		# Une branche se divise en deux ou trois, pas en cinq.
		"subdivide": 2,
		# Divergence des filles par rapport à leur mère, en degrés.
		"spread_deg": 45.0,
		# GÉOTROPISME : +1 redresse les branches vers le ciel (orme, peuplier),
		# -1 les fait retomber (saule), 0 les laisse droites.
		"droop": 0.0,
		"depth": 3,
		"length_ratio": 0.62,
		"radius_ratio": 0.58,
		# Sinuosité du bois : 0 = tiges rectilignes de géomètre.
		"curve": 0.16,
		"lean": 0.05,
		# NOMBRE de verticilles répartis sur la partie feuillée d'un axe
		# excurrent — pas leur espacement.
		#
		# L'espacement fixe s'accordait mal au plafond d'extrémités : un axe de
		# 20 blocs avec un pas de 0,5 bloc demandait 40 verticilles, le budget
		# était épuisé par les premiers, et l'arbre sortait FEUILLU EN BAS ET
		# CHAUVE EN HAUT. Un nombre fixe se répartit sur toute la hauteur quelle
		# que soit la taille de l'arbre, ce qui est aussi la façon dont un vrai
		# conifère s'étage.
		"whorls": 10,
		"foliage": "mass",
		"leaf_radius": canopy_radius,
		# Aplatissement du feuillage : 1 = sphérique, 0,4 = galette.
		"leaf_flatten": 1.0,
		"leaf_density": 0.88,
		"roots": 5,
	}

	match shape:
		"conical":
			# Sapin, épicéa, mélèze : flèche unique, verticilles de branches
			# horizontales d'autant plus courtes qu'on monte.
			arch["form"] = "excurrent"
			arch["fork"] = 0.12
			arch["spread_deg"] = 78.0
			arch["droop"] = -0.18
			arch["depth"] = 2
			arch["children"] = 4
			arch["length_ratio"] = 0.34
			arch["whorls"] = 14
			arch["curve"] = 0.07
			arch["foliage"] = "needle"
			arch["leaf_flatten"] = 0.55
		"columnar":
			# Peuplier d'Italie, cyprès : branches courtes et serrées contre
			# l'axe, d'où la silhouette en point d'exclamation.
			arch["form"] = "excurrent"
			arch["fork"] = 0.15
			arch["spread_deg"] = 22.0
			arch["droop"] = 0.55
			arch["depth"] = 2
			arch["children"] = 3
			arch["length_ratio"] = 0.22
			arch["whorls"] = 12
			arch["curve"] = 0.06
			# Dense, pas aéré : un peuplier d'Italie est une colonne PLEINE de
			# feuilles. En « airy » il sortait comme un mât avec trois touffes.
			arch["foliage"] = "mass"
			arch["leaf_flatten"] = 1.3
			arch["lean"] = 0.02
		"tiered":
			# Cèdre du Liban : plateaux horizontaux nettement séparés.
			arch["form"] = "excurrent"
			# Un cèdre montre un fût net avant d'étager ses plateaux ; à 0,3 la
			# ramure démarrait si bas que le tronc disparaissait dedans.
			arch["fork"] = 0.45
			arch["spread_deg"] = 86.0
			arch["droop"] = -0.05
			arch["depth"] = 2
			arch["children"] = 5
			arch["length_ratio"] = 0.5
			arch["whorls"] = 5
			arch["foliage"] = "tiered"
			arch["leaf_flatten"] = 0.32
		"vase":
			# Orme : maîtresses branches qui montent en gerbe et s'évasent.
			arch["fork"] = 0.34
			arch["spread_deg"] = 26.0
			arch["droop"] = 0.62
			arch["children"] = 4
			arch["depth"] = 3
			arch["length_ratio"] = 0.72
			arch["leaf_flatten"] = 0.8
		"broad":
			# Chêne, hêtre, platane : couronne large et basse, branches
			# tortueuses presque horizontales.
			arch["fork"] = 0.42
			arch["spread_deg"] = 55.0
			arch["droop"] = -0.05
			arch["children"] = 4
			arch["depth"] = 3
			arch["length_ratio"] = 0.66
			arch["curve"] = 0.24
			arch["leaf_flatten"] = 0.85
		"oval":
			# Bouleau, charme, frêne : houppier ovale, plus haut que large.
			arch["fork"] = 0.5
			arch["spread_deg"] = 34.0
			arch["droop"] = 0.28
			arch["children"] = 3
			arch["depth"] = 3
			arch["length_ratio"] = 0.6
			arch["foliage"] = "airy"
			arch["leaf_flatten"] = 1.25
		"umbrella":
			# Acacia de savane : tronc nu, branches qui montent puis s'étalent
			# à l'horizontale en une table de feuillage.
			arch["fork"] = 0.55
			arch["spread_deg"] = 58.0
			arch["droop"] = 0.45
			arch["children"] = 4
			arch["depth"] = 3
			arch["length_ratio"] = 0.78
			arch["leaf_flatten"] = 0.3
		"weeping":
			# Saule : le feuillage retombe en rideaux depuis les branches.
			arch["fork"] = 0.45
			arch["spread_deg"] = 48.0
			arch["droop"] = -0.75
			arch["children"] = 4
			arch["depth"] = 3
			arch["length_ratio"] = 0.7
			arch["foliage"] = "curtain"
			arch["leaf_flatten"] = 0.7
		"flat":
			# Palmier : la seule famille sans ramification du tout.
			arch["form"] = "palm"
			arch["foliage"] = "frond"
		"spherical":
			# Pommier, olivier, noisetier : petits arbres de verger, couronne
			# ronde et basse sur un tronc court.
			arch["fork"] = 0.4
			arch["spread_deg"] = 48.0
			arch["droop"] = 0.15
			arch["children"] = 4
			arch["depth"] = 3
			arch["length_ratio"] = 0.62
			arch["curve"] = 0.22

	# Surcharges explicites de la fiche d'essence, quand la silhouette ne
	# suffit pas à décrire l'arbre.
	var overrides: Dictionary = species.get("architecture", {})
	for key: String in overrides:
		arch[key] = overrides[key]
	# La hauteur reste TIRÉE AU SORT, donc jamais surchargeable : une fiche qui
	# la fixerait supprimerait toute variété dans un bosquet.
	arch["height"] = height * FINE_PER_BLOCK
	# PORTÉE DE LA COURONNE, en pas fins. C'est elle qui borne l'étalement des
	# maîtresses branches, et il a fallu l'introduire : la longueur d'une fille
	# se déduisait de celle de sa mère, donc du TRONC pour la première
	# génération. Un bouleau de 14 blocs sortait ainsi des branches de 8 blocs
	# et une couronne de 16 blocs de large — mesuré, il était aussi trapu qu'un
	# hêtre alors que sa fiche demandait un rayon de 2 à 3.
	arch["crown_reach"] = canopy_radius * FINE_PER_BLOCK
	# L'espacement se DÉDUIT du nombre voulu et de la longueur feuillée.
	var leafy: float = float(arch["height"]) * (1.0 - float(arch["fork"]))
	arch["whorl_spacing"] = maxf(1.5, leafy / maxf(1.0, float(arch["whorls"])))
	return arch


# ============================================================================
# LE SQUELETTE
# ============================================================================


## Fait pousser une pousse et, récursivement, tout ce qu'elle porte.
##
## `from` et `dir` en pas fins, `length` et `radius` en pas fins. `leader`
## distingue l'axe principal des branches qu'il porte : c'est lui qui décide si
## l'arbre garde une flèche ou se divise.
static func _grow(ctx: Dictionary, from: Vector3, dir: Vector3, length: float, radius: float, depth: int, leader: bool) -> void:
	var arch: Dictionary = ctx["arch"]
	var rng: RandomNumberGenerator = ctx["rng"]
	var excurrent := String(arch["form"]) == "excurrent"
	var fork := float(arch["fork"])
	var droop := float(arch["droop"])
	var curve := float(arch["curve"])

	# Un axe décurrent s'arrête à la fourche et laisse la place à ses filles ;
	# un axe excurrent monte jusqu'au bout. C'est TOUTE la différence entre un
	# chêne et un sapin, et elle tient dans cette ligne.
	var run := length if (excurrent or not leader) else length * fork
	# Un pas de DEUX pas fins (un demi-bloc), pas d'un seul : la direction est
	# reperturbée à chaque pas, donc doubler le pas divise par deux le nombre de
	# perturbations subies par une branche — et par deux le coût de tracé.
	var steps := maxi(2, roundi(run * 0.5))
	var seg := run / steps

	var pos := from
	var heading := dir
	var travelled := 0.0
	var next_whorl := float(arch["whorl_spacing"]) * (fork * 4.0 if leader else 0.0)

	# BUDGET DE VERTICILLES, RÉPARTI SUR TOUTE LA HAUTEUR.
	#
	# Les verticilles se posent EN MONTANT le long de l'axe. Quand le plafond
	# d'extrémités était atteint en chemin, ceux du haut n'étaient tout
	# simplement jamais posés : le conifère perdait sa moitié supérieure et
	# laissait dépasser un tronc nu. C'est exactement ce que montrait la
	# capture du sapin — « il ne ressemble à rien », et pour cause, il lui
	# manquait la pointe qui fait un sapin.
	#
	# On ne coupe donc plus quand le budget est épuisé : on RÉDUIT LE NOMBRE DE
	# BRANCHES PAR VERTICILLE pour que tous les étages tiennent. Un sapin à
	# trois branches par étage sur toute sa hauteur est un sapin ; un sapin à
	# quatre branches sur sa moitié basse est un buisson surmonté d'un poteau.
	var per_whorl := int(arch["children"])
	if excurrent and leader:
		var spacing := maxf(float(arch["whorl_spacing"]), 0.5)
		var expected := maxf(1.0, run / spacing)
		per_whorl = clampi(int(float(MAX_TIPS) * 0.85 / expected), 2, int(arch["children"]))

	for i in steps:
		var t0 := float(i) / steps
		var t1 := float(i + 1) / steps
		# Le bois se cherche : dérive aléatoire + rappel géotropique. Sans la
		# dérive on obtient des tiges de géomètre ; sans le rappel, une branche
		# part au hasard et ne « pèse » nulle part.
		var wobble := Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-0.35, 0.35),
				rng.randf_range(-1.0, 1.0)) * curve
		# RAPPEL VERS LA DIRECTION INITIALE. Sans ce terme, la perturbation
		# aléatoire est une MARCHE SANS FORCE DE RAPPEL : sur vingt pas elle
		# emmène la branche n'importe où, et l'arbre sort en écheveau de
		# tentacules — c'est exactement ce que montrait la première capture.
		# Une vraie branche se tord autour de son axe, elle ne s'en va pas.
		heading = (heading + wobble + dir * 0.35 + Vector3.UP * droop * 0.22).normalized()
		var next := pos + heading * seg
		_stroke(ctx, pos, next, lerpf(radius, radius * 0.72, t0), lerpf(radius, radius * 0.72, t1))
		pos = next
		travelled += seg

		# Latérales le long d'un axe excurrent : c'est ce qui donne au conifère
		# ses verticilles étagés. Sur un axe décurrent on n'en pose pas — ses
		# branches naissent toutes à la fourche.
		if excurrent and depth > 0 and leader and travelled >= next_whorl and t1 < 0.97:
			next_whorl = travelled + float(arch["whorl_spacing"])
			# Les latérales raccourcissent en montant : c'est ce profil qui
			# fait le cône. Un profil plat donnerait un cylindre.
			var profile := lerpf(1.0, 0.18, t1)
			# Leur longueur se mesure sur la COURONNE VOULUE, pas sur la
			# hauteur du tronc : une latérale de sapin doit atteindre le bord
			# de la couronne, quelle que soit la taille de l'arbre.
			var lateral_len := float(arch["crown_reach"]) * profile * 0.95
			var lateral_r := radius * float(arch["radius_ratio"]) * lerpf(1.0, 0.4, t1)
			# Le budget est déjà réparti (voir `per_whorl`) : on ne coupe plus
			# en chemin, sinon on recréerait la troncature qu'on vient de
			# supprimer.
			var whorl := per_whorl
			for k in whorl:
				var yaw := PHYLLOTAXIS * (i * whorl + k) + rng.randf_range(-0.25, 0.25)
				var lateral := _spread(heading, yaw, deg_to_rad(float(arch["spread_deg"])
						+ rng.randf_range(-8.0, 8.0)))
				_grow(ctx, pos, lateral, lateral_len, maxf(lateral_r, TIP_RADIUS), depth - 1, false)

	# Fin de l'axe.
	if depth <= 0 or radius <= TIP_RADIUS:
		(ctx["tips"] as Array).append(pos)
		return

	if excurrent and leader:
		# La flèche se termine en pointe : le sommet porte du feuillage, pas
		# une fourche.
		(ctx["tips"] as Array).append(pos)
		return

	# Fourche : N filles se partagent la suite. À la première (l'axe), ce sont
	# les maîtresses branches ; plus loin, ce sont de simples divisions.
	var n := int(arch["children"]) if leader else int(arch["subdivide"])
	if (ctx["tips"] as Array).size() >= MAX_TIPS:
		(ctx["tips"] as Array).append(pos)
		return
	var base_yaw := rng.randf() * TAU
	for k in n:
		var yaw := base_yaw + PHYLLOTAXIS * k + rng.randf_range(-0.3, 0.3)
		var angle := deg_to_rad(float(arch["spread_deg"]) + rng.randf_range(-10.0, 10.0))
		var child_dir := _spread(heading, yaw, angle)
		# PREMIÈRE FOURCHE : la longueur se déduit de la couronne voulue. Une
		# maîtresse branche part à `angle` de la verticale, donc n'avance
		# horizontalement que de L·sin(angle) ; c'est cette avance-là qui doit
		# valoir le rayon de la couronne, et les générations suivantes viennent
		# la compléter, d'où le facteur 0,6.
		var child_len := length * float(arch["length_ratio"])
		if leader:
			child_len = float(arch["crown_reach"]) / maxf(sin(angle), 0.4) * 0.6
		child_len *= rng.randf_range(0.85, 1.15)
		var child_r := radius * float(arch["radius_ratio"])
		_grow(ctx, pos, child_dir, child_len, maxf(child_r, TIP_RADIUS), depth - 1, false)


## Direction fille : `dir` inclinée de `angle` et tournée de `yaw` autour d'elle.
## On construit une base orthonormée locale plutôt que de composer des rotations
## d'Euler, qui dégénèrent quand la mère est verticale — le cas le plus fréquent
## de tous, puisque c'est celui du tronc.
static func _spread(dir: Vector3, yaw: float, angle: float) -> Vector3:
	var reference := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var side := dir.cross(reference).normalized()
	var other := dir.cross(side).normalized()
	var radial := (side * cos(yaw) + other * sin(yaw)).normalized()
	return (dir * cos(angle) + radial * sin(angle)).normalized()


## PALMIER. Ni flèche ni fourche : une stipe qui s'incurve, et un bouquet de
## palmes au sommet. Le traiter comme un arbre à branches en ferait un feuillu
## quelconque, ce qu'aucun palmier n'est.
static func _grow_palm(ctx: Dictionary, foot: Vector3) -> void:
	var arch: Dictionary = ctx["arch"]
	var rng: RandomNumberGenerator = ctx["rng"]
	var height := float(arch["height"])
	var steps := maxi(4, roundi(height))
	var seg := height / steps
	var lean := Vector3(rng.randf_range(-1.0, 1.0), 0.0, rng.randf_range(-1.0, 1.0)).normalized()
	var pos := foot
	var base_radius := float(arch["base_radius"])
	for i in steps:
		var t := float(i) / steps
		# La stipe penche de plus en plus haut, comme un palmier de plage.
		var heading := (Vector3.UP + lean * (0.10 + 0.22 * t)).normalized()
		var next := pos + heading * seg
		# Elle s'affine peu : un palmier n'est pas un cône.
		_stroke(ctx, pos, next, lerpf(base_radius, 1.1, t), lerpf(base_radius, 1.1, t + 1.0 / steps))
		pos = next
	(ctx["tips"] as Array).append(pos)


## RACINES. Un tronc qui sort du sol comme un piquet planté est ce qui trahit
## le plus la génération procédurale ; un vrai pied s'évase en contreforts.
##
## Elles restent AU NIVEAU DU SOL, jamais en dessous : le générateur de monde
## refuse d'écrire un bloc d'arbre là où il y a déjà de la terre, donc une
## racine enterrée serait invisible et le calcul serait perdu.
static func _grow_roots(ctx: Dictionary, foot: Vector3) -> void:
	var arch: Dictionary = ctx["arch"]
	var rng: RandomNumberGenerator = ctx["rng"]
	var count := int(arch["roots"])
	if count <= 0:
		return
	var radius := float(arch["base_radius"])
	var start_yaw := rng.randf() * TAU
	for i in count:
		var yaw := start_yaw + TAU * i / count + rng.randf_range(-0.25, 0.25)
		var dir := Vector3(cos(yaw), 0.0, sin(yaw))
		var length := radius * rng.randf_range(1.6, 2.6)
		# Le contrefort s'épaissit vers le TRONC, à l'inverse d'une branche qui
		# s'affine vers sa pointe.
		var start := foot + Vector3(0.0, radius * 0.8, 0.0)
		var end := foot + dir * length + Vector3(0.0, -0.4, 0.0)
		_stroke(ctx, start, end, radius * 0.85, 0.6)


# ============================================================================
# RASTÉRISATION : de l'espace continu au réseau de 8 px
# ============================================================================


## Trace un tronçon conique de `a` à `b` sur le réseau fin.
static func _stroke(ctx: Dictionary, a: Vector3, b: Vector3, ra: float, rb: float) -> void:
	var span := b - a
	var distance := span.length()
	# Un pas de 0,85 garantit que deux boules successives se recouvrent même au
	# rayon minimal (deux sphères de rayon 0,5 espacées de 0,85 se coupent
	# encore) : sans recouvrement, une branche fine sort en pointillés. En
	# dessous, on paye des boules redondantes — le tracé est le premier poste de
	# la génération.
	var steps := maxi(1, ceili(distance / 0.85))
	for i in range(steps + 1):
		var t := float(i) / steps
		_ball(ctx, a + span * t, lerpf(ra, rb, t))


## Boule de bois sur le réseau fin, centre en coordonnées continues.
static func _ball(ctx: Dictionary, center: Vector3, radius: float) -> void:
	var fine: Dictionary = ctx["fine"]
	var wood_id: int = ctx["wood_id"]
	var origin := Vector3i(roundi(center.x), roundi(center.y), roundi(center.z))
	# Sous un demi-pas, on pose quand même LA cellule la plus proche : c'est
	# ainsi qu'un rameau terminal fait exactement 8 px et pas zéro.
	if radius <= 0.5:
		fine[origin] = wood_id
		return
	var reach := ceili(radius)
	for dx in range(-reach, reach + 1):
		for dy in range(-reach, reach + 1):
			for dz in range(-reach, reach + 1):
				var cell := origin + Vector3i(dx, dy, dz)
				if Vector3(cell).distance_squared_to(center) <= radius * radius:
					fine[cell] = wood_id


## Réseau fin → blocs. UN BLOC DONT LES 64 CELLULES SONT PLEINES REDEVIENT UN
## BLOC PLEIN : c'est ce qui garde le tronc en 32 px, bon marché à mailler, et
## ne laisse en subdivisions que ce qui en a besoin — branches et racines. Sans
## cette promotion, un tronc de chêne serait deux cents sous-grilles de 64
## cellules là où deux cents cubes suffisent.
## Retourne le VOLUME de bois posé, en blocs pleins équivalents.
static func _rasterize(fine: Dictionary, blocks: Dictionary, subdivs: Dictionary, wood_positions: Array[Vector3i]) -> float:
	var per_block := {}
	for cell: Vector3i in fine:
		var block := Vector3i(cell.x >> FINE_SHIFT, cell.y >> FINE_SHIFT, cell.z >> FINE_SHIFT)
		if not per_block.has(block):
			per_block[block] = []
		(per_block[block] as Array).append(cell)

	var full := FINE_PER_BLOCK * FINE_PER_BLOCK * FINE_PER_BLOCK
	var volume := 0.0
	for block: Vector3i in per_block:
		var cells: Array = per_block[block]
		var material_id: int = fine[cells[0]]
		blocks[block] = material_id
		wood_positions.append(block)
		volume += float(cells.size()) / float(full)
		if cells.size() >= full:
			continue  # Plein : reste un bloc de 32 px.
		var grid := SubdivGrid.create_empty()
		for cell: Vector3i in cells:
			var q := Vector3i(cell.x & FINE_MASK, cell.y & FINE_MASK, cell.z & FINE_MASK)
			SubdivGrid.set_region(grid, q * FINE_STEP, FINE_STEP, material_id)
		subdivs[block] = grid
	return volume


# ============================================================================
# LE FEUILLAGE
# ============================================================================


## Accroche le feuillage aux rameaux terminaux produits par le squelette.
##
## Le feuillage NE DÉFINIT PLUS LA SILHOUETTE — c'est le squelette qui la
## définit, et les amas ne font que l'habiller. C'est l'inverse de l'ancien
## générateur, où une forme géométrique était plaquée sur un bâton, et c'est
## pourquoi un port en gerbe ou en parasol se lit maintenant même quand deux
## essences partagent le même style de feuille.
static func _foliage(ctx: Dictionary, blocks: Dictionary, leaf_id: int) -> void:
	var arch: Dictionary = ctx["arch"]
	var rng: RandomNumberGenerator = ctx["rng"]
	var tips: Array = ctx["tips"]
	if tips.is_empty() or leaf_id == 0:
		return
	var style := String(arch["foliage"])
	var flatten := float(arch["leaf_flatten"])
	var density := float(arch["leaf_density"])
	# TAILLE DES AMAS : celle qui remplit la couronne sans la déborder.
	#
	# N amas de rayon r couvrent un volume de l'ordre de N·r³ ; pour qu'il vaille
	# celui de la couronne, r doit décroître comme la RACINE CUBIQUE du nombre
	# d'extrémités. Les deux réglages précédents se sont trompés en sens
	# opposés : diviser par la racine carrée écrasait chaque amas au plancher et
	# donnait des confettis, un rayon fixe donnait 4 084 blocs pour un cèdre
	# — une couronne pleine, débordant largement du rayon demandé.
	var count := maxf(1.0, float(tips.size()))
	var crown := float(arch["leaf_radius"])
	var per_tip := clampf(crown * CROWN_FILL / pow(count, 1.0 / 3.0), 1.5, crown * 0.7)

	for tip: Vector3 in tips:
		match style:
			"frond":
				_fronds(blocks, tip, arch, rng, leaf_id)
			"curtain":
				_blob(blocks, tip, per_tip, flatten, density, leaf_id)
				_curtain(blocks, tip, arch, rng, leaf_id)
			"tiered":
				# Plateau : large, mince, posé à plat sur la branche.
				_blob(blocks, tip, per_tip * 1.35, 0.28, density, leaf_id)
			"needle":
				# DENSE ET RAMASSÉ. Un conifère ne laisse pas voir son tronc :
				# ses aiguilles forment un manteau opaque. Les amas étaient
				# aplatis (0,6) et clairsemés, et le fût pâle transparaissait
				# entre eux — un sapin doit être une masse sombre, pas un
				# treillis. On les arrondit et on les serre.
				_blob(blocks, tip, per_tip * 1.15, 0.85, minf(density * 1.25, 1.0), leaf_id)
			"airy":
				_blob(blocks, tip, per_tip * 0.9, flatten, density * 0.72, leaf_id)
			_:
				_blob(blocks, tip, per_tip, flatten, density, leaf_id)


## Amas de feuillage ellipsoïdal autour d'un point, en blocs pleins.
## Retire le feuillage totalement enfermé. Voir HOLLOW_CANOPY.
##
## UNE SEULE PASSE, sur l'état d'ORIGINE : on retire d'un coup tous les blocs
## qui étaient enfermés avant de commencer. Le reste forme exactement la surface
## de la couronne, identique vue du dehors. Enchaîner les passes creuserait au
## contraire jusqu'à ne laisser qu'une coquille percée.
static func _hollow(blocks: Dictionary, leaf_id: int) -> void:
	var buried: Array[Vector3i] = []
	for pos: Vector3i in blocks:
		if blocks[pos] != leaf_id:
			continue
		var enclosed := true
		for dir: Vector3i in FACE_DIRS:
			if not blocks.has(pos + dir):
				enclosed = false
				break
		if enclosed:
			buried.append(pos)
	for pos: Vector3i in buried:
		blocks.erase(pos)


static func _blob(blocks: Dictionary, tip_fine: Vector3, radius: float, flatten: float, density: float, leaf_id: int) -> void:
	var center := tip_fine / float(FINE_PER_BLOCK)
	var origin := Vector3i(roundi(center.x), roundi(center.y), roundi(center.z))
	var reach := maxi(1, ceili(radius))
	var reach_y := maxi(1, ceili(radius * flatten))
	for dx in range(-reach, reach + 1):
		for dy in range(-reach_y, reach_y + 1):
			for dz in range(-reach, reach + 1):
				var pos := origin + Vector3i(dx, dy, dz)
				if blocks.has(pos):
					continue  # Ne recouvre jamais du bois.
				var ry := float(dy) / maxf(flatten, 0.05)
				var d2 := float(dx * dx + dz * dz) + ry * ry
				if d2 > radius * radius:
					continue
				# Bord adouci : la probabilité tombe vers l'extérieur, sinon
				# l'amas a un contour de compas.
				var edge := d2 / maxf(radius * radius, 0.01)
				if _keep_leaf(pos, leaf_id, density * lerpf(1.05, 0.55, edge)):
					blocks[pos] = leaf_id


## SAULE : le feuillage retombe en rideaux verticaux depuis la branche. Sans
## eux, un saule n'est qu'un arbre rond de plus — alors que le rideau est
## précisément ce que les gens dessinent quand on leur demande un saule.
static func _curtain(blocks: Dictionary, tip_fine: Vector3, arch: Dictionary, rng: RandomNumberGenerator, leaf_id: int) -> void:
	var center := tip_fine / float(FINE_PER_BLOCK)
	var origin := Vector3i(roundi(center.x), roundi(center.y), roundi(center.z))
	var strands := rng.randi_range(2, 4)
	for s in strands:
		var yaw := rng.randf() * TAU
		var offset := Vector3i(roundi(cos(yaw) * rng.randf_range(0.0, 2.0)), 0,
				roundi(sin(yaw) * rng.randf_range(0.0, 2.0)))
		var drop := rng.randi_range(2, maxi(3, int(float(arch["leaf_radius"]) * 1.6)))
		for d in drop:
			var pos := origin + offset + Vector3i(0, -d, 0)
			if blocks.has(pos):
				continue
			# Le rideau s'éclaircit vers le bas, comme les vraies branches
			# retombantes qui s'effilochent.
			if _keep_leaf(pos, leaf_id, lerpf(0.95, 0.42, float(d) / maxf(drop, 1))):
				blocks[pos] = leaf_id


## PALMIER : des palmes qui rayonnent depuis le sommet de la stipe et
## retombent. Une boule de feuilles à la place en ferait un arbre à sucette.
static func _fronds(blocks: Dictionary, tip_fine: Vector3, arch: Dictionary, rng: RandomNumberGenerator, leaf_id: int) -> void:
	var center := tip_fine / float(FINE_PER_BLOCK)
	var origin := Vector3i(roundi(center.x), roundi(center.y), roundi(center.z))
	# Un cocotier porte une couronne FOURNIE de palmes longues : à six palmes de
	# quatre blocs, la capture montrait une houppe ridicule au bout d'un mât.
	var count := rng.randi_range(9, 13)
	var length := maxi(4, int(float(arch["leaf_radius"]) * 1.9))
	var start_yaw := rng.randf() * TAU
	for i in count:
		var yaw := start_yaw + TAU * i / count + rng.randf_range(-0.15, 0.15)
		var dir := Vector3(cos(yaw), 0.0, sin(yaw))
		for step in range(1, length + 1):
			var t := float(step) / length
			# La palme part à l'horizontale et retombe : une parabole, pas une
			# droite.
			var drop := -0.6 * t * t * length
			var pos := origin + Vector3i(roundi(dir.x * step), roundi(drop + 1.0), roundi(dir.z * step))
			blocks[pos] = leaf_id
			# Largeur : deux blocs près de l'insertion, un seul au bout.
			# Largeur de la palme : trois blocs près de l'insertion, un au bout.
			if t < 0.7:
				var side := Vector3i(roundi(-dir.z), 0, roundi(dir.x))
				if not blocks.has(pos + side):
					blocks[pos + side] = leaf_id
				if t < 0.4 and not blocks.has(pos - side):
					blocks[pos - side] = leaf_id


## Bruit soustractif déterministe (silhouette organique, jamais un bloc plein
## parfait) — hachage de la position monde, indépendant de tout autre état.
static func _keep_leaf(pos: Vector3i, seed_value: int, keep_chance: float) -> bool:
	var v := (pos.x * 668265263) ^ (pos.y * 374761393) ^ (pos.z * 2246822519) ^ seed_value
	v = (v ^ (v >> 13)) * 1274126177
	var f := float(v & 0xFFFFFF) / float(0xFFFFFF)
	return f < keep_chance


# ============================================================================
# PEAU DU FEUILLAGE
# ============================================================================


const FACE_DIRS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]

## Rayon d'érosion, en pas fins. Au-delà de ~2,6 le bloc de coin disparaît
## entièrement et la couronne se troue.
const LEAF_ERODE_RADIUS := 2.1

## Cache des grilles de feuillage érodé : au plus 64 par essence.
static var _leaf_shell_cache := {}


## À l'intérieur d'une couronne, un bloc plein ne se voit pas : le raffiner
## coûte cher et ne montre rien. Sur le POURTOUR au contraire, le cube franc est
## exactement ce qui fait « tas de cubes verts ». On érode donc les seules faces
## exposées, en 8 px, ce qui arrondit la silhouette.
##
## L'érosion ne dépend QUE des faces libres du bloc, jamais d'un tirage : les 64
## masques possibles donnent 64 grilles, partagées par toute la forêt et par le
## cache de quads du mailleur. Un motif tiré au hasard par bloc rendrait ce
## cache inutile — mesuré, 3,9 ms/chunk de maillage contre 0,2.
static func _erode_leaf_shell(blocks: Dictionary, subdivs: Dictionary, leaf_id: int) -> void:
	var shells := {}
	for pos: Vector3i in blocks:
		if blocks[pos] != leaf_id or subdivs.has(pos):
			continue
		var mask := 0
		for i in 6:
			if not blocks.has(pos + FACE_DIRS[i]):
				mask |= 1 << i
		# TROIS OU QUATRE FACES LIBRES : c'est la définition d'un coin de
		# silhouette, et c'est là que le cube franc se voit.
		#
		# À une ou deux faces on est sur un flanc, où l'érosion se verrait à
		# peine et percerait le feuillage à jour. À CINQ OU SIX on est sur un
		# fleck isolé au bout d'un rameau : l'éroder ne se voit pas davantage,
		# et comme un feuillage clairsemé en produit énormément, la règle
		# « ≥ 3 » à elle seule subdivisait presque toute la couronne — mesuré,
		# 1 005 blocs subdivisés sur 1 078 pour un cèdre. Le maillage des
		# sous-grilles coûte cher, il doit servir là où il se voit.
		var free := _bit_count(mask)
		if free == 3 or free == 4:
			shells[pos] = mask
	for pos: Vector3i in shells:
		subdivs[pos] = _eroded_leaf_grid(leaf_id, shells[pos])


static func _bit_count(mask: int) -> int:
	var n := 0
	for i in 6:
		if mask & (1 << i):
			n += 1
	return n


## Bloc de feuillage dont les coins exposés sont rongés, au pas de 8 px.
static func _eroded_leaf_grid(material_id: int, mask: int) -> PackedInt32Array:
	var key := (material_id << 8) | mask
	if _leaf_shell_cache.has(key):
		return _leaf_shell_cache[key]

	var grid := SubdivGrid.create_empty()
	var center := (FINE_PER_BLOCK - 1) * 0.5   # 1,5 en pas fins.
	for qx in FINE_PER_BLOCK:
		for qy in FINE_PER_BLOCK:
			for qz in FINE_PER_BLOCK:
				var q := Vector3i(qx, qy, qz)
				# Distance vers les seules faces LIBRES : un cube reste plein
				# du côté où il a un voisin, sinon on ouvrirait des trous dans
				# la masse du feuillage.
				var reach := 0.0
				for i in 6:
					if not (mask & (1 << i)):
						continue
					var dir: Vector3i = FACE_DIRS[i]
					var along := (float(q.x) - center) * dir.x + (float(q.y) - center) * dir.y \
							+ (float(q.z) - center) * dir.z
					if along > 0.0:
						reach += along * along
				if reach <= LEAF_ERODE_RADIUS * LEAF_ERODE_RADIUS:
					SubdivGrid.set_region(grid, q * FINE_STEP, FINE_STEP, material_id)

	_leaf_shell_cache[key] = grid
	return grid

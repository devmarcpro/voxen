class_name ShowcaseBuilder
extends RefCounted
## LE MONDE VITRINE (2026-08-06) — tout le contenu du jeu posé en rangées sur
## une dalle plate, une rangée par catégorie.
##
## ---------------------------------------------------------------------------
## POURQUOI
## ---------------------------------------------------------------------------
## Trois défauts visuels de la seule journée du 2026-08-04 ont coûté un
## aller-retour de capture chacun, et se seraient vus en dix secondes ici : des
## plantes en cure-dents, des fleurs en guéridons, et un monde ENTIÈREMENT BLANC
## parce qu'un shader était cassé — celui-là sans qu'aucune sonde ne bronche.
## Ce qui se regarde doit pouvoir se regarder d'un coup d'œil.
##
## ---------------------------------------------------------------------------
## L'INVARIANT, ET C'EST LA SEULE RÈGLE QUI COMPTE ICI
## ---------------------------------------------------------------------------
## « Même si je rajoute 300 blocs, je veux que les 300 blocs soient dans le
## monde automatiquement. » Tout ce qui est posé vient donc d'un PARCOURS DU
## CATALOGUE (`GameData.materials` groupés par catégorie, `GameData.trees`, les
## matériaux en croix, les archétypes de bâtiment). Il n'y a pas une seule liste
## d'ids écrite dans ce fichier, et il ne doit jamais y en avoir : une liste
## figée serait périmée au 301ᵉ bloc. C'est exactement le doublon de vérité qui
## a coûté deux pipelines de génération.
##
## `build()` rend la POSITION de chaque entrée de catalogue posée. La sonde
## `--probe-vitrine` relit le monde à ces positions et échoue s'il en manque
## une : sans cette vérification, la vitrine dériverait en silence, ce qui est
## précisément le défaut qu'elle existe pour révéler ailleurs.
##
## ---------------------------------------------------------------------------
## ÉCRITURE EN LOT, OBLIGATOIREMENT
## ---------------------------------------------------------------------------
## `set_block_batched`, jamais `set_block` : celui-ci remaille SYNCHRONEMENT
## jusqu'à sept chunks par bloc posé, et la vitrine en pose des dizaines de
## milliers. Le flux est vidé par rangée, pas à la fin — un flush unique ferait
## tomber tous les remesh dans la même frame.
##
## Le coût réel est ailleurs et vaut d'être dit : `_write_block_data` appelle
## `_get_chunk_sync`, qui GÉNÈRE le chunk s'il n'est pas chargé. Poser la
## vitrine génère donc tous les chunks qu'elle touche, sur le fil principal.
## C'est abordable ICI et seulement ici, parce que le monde est plat : ni
## cavernes, ni rivières, ni villes, ni arbres, ni plantes à semer.

## Hauteur du sol de la dalle (voir NoiseGenerator.FLAT_HEIGHT) : le sommet du
## bloc de sol. Ce qui est posé l'est un bloc au-dessus.
const GROUND_Y := 72
const PLACE_Y := GROUND_Y + 1

## Écartement des rangées sur Z, et pas entre deux entrées d'une rangée sur X.
## Deux blocs voisins ne se lisent pas : sans l'intervalle, une rangée est une
## bande de couleur, pas une collection d'échantillons.
const ROW_GAP := 10
const STEP := 2
## Les arbres se recouvrent : `TREE_MAX_REACH` monte à 18, et une couronne
## comme celle du colosse va bien au-delà. Une rangée d'arbres serrés serait un
## bloc de forêt où l'on ne distinguerait aucune essence.
const TREE_STEP := 44
const TREE_ROW_GAP := 80
## Une maison fait 16 blocs de côté plus sa toiture. L'écart est celui qui laisse
## voir un pignon entier depuis le sol.
## Intervalle entre deux MONDES. Bien plus large qu'entre deux rangées : c'est
## ce vide qui fait lire la vitrine comme plusieurs collections et non comme une
## seule liste interminable.
const SET_GAP := 60

const STRUCTURE_STEP := 32
const STRUCTURE_ROW_GAP := 40

## Origine des rangées. Décalée du point de spawn pour qu'on n'atterrisse pas
## AU MILIEU de la première rangée, ce qui est arrivé aux captures de plantes.
const ORIGIN := Vector3i(-8, PLACE_Y, 8)

## Blocs posés depuis le dernier vidage — le flux est vidé par paquets et non en
## fin de construction, faute de quoi les remesh tombent tous dans la même frame.
const FLUSH_EVERY := 4000

## Rapport de construction. `positions` est la preuve : une entrée de catalogue →
## le bloc du monde où on doit la retrouver.
## LES CLÉS SONT PRÉFIXÉES PAR LEUR CATALOGUE (`materiau:`, `arbre:`,
## `structure:`), et ce n'est pas cosmétique : la moitié des essences PORTENT LE
## NOM de leur bois (`chene` est une essence ET un matériau). Sans préfixe,
## l'arbre écrasait le matériau, le rapport annonçait 534 entrées pour 570, et
## la relecture passait quand même — le bloc au pied d'un chêne étant du chêne,
## l'assertion était vraie pour la mauvaise raison.
##   { "positions": { "<catalogue>:<id>": Vector3i },
##     "rows":      [ { "label": String, "z": int, "scale": String } ],
##     "blocks":    int (blocs réellement écrits) }
var positions := {}
var rows: Array[Dictionary] = []
var blocks_written := 0

## Construction TERMINÉE. Sans ce drapeau, « la vitrine est-elle prête ? » se
## répondait par « `rows` est-il non vide ? » — or `rows` se remplit AU FUR ET À
## MESURE. La sonde relevait donc son compte après la PREMIÈRE rangée : 96
## entrées au lieu de 570, et l'échec accusait le constructeur alors que c'était
## la question qui était fausse.
var done := false

## Temps passé à VIDER LE FLUX, isolé du reste. La construction a mesuré
## 409 secondes à sa première exécution : sans cette séparation, on ne pouvait
## pas savoir si le coût était dans l'écriture des blocs (donc dans la
## génération des chunks) ou dans le remaillage — et on l'aurait deviné.
var flush_ms := 0
## Temps passé À ATTENDRE LE MOTEUR (`await process_frame`), par opposition au
## travail fait par ce constructeur. Sans ce second chronomètre on attribuerait
## au constructeur des frames que le streaming du monde occupe.
var idle_ms := 0

var _pending := 0
var _next_z := 0


## Construit la vitrine entière. COROUTINE : elle rend la main entre les
## rangées, sinon les arbres à eux seuls figeraient plusieurs secondes.
func build(tree_root: Node3D = null) -> void:
	positions.clear()
	rows.clear()
	blocks_written = 0
	done = false
	_next_z = ORIGIN.z
	var started := Time.get_ticks_msec()
	for content_set: String in _content_sets():
		# UN BLOC DE RANGÉES PAR MONDE, séparés par un large intervalle. Tout
		# était mélangé : les cristaux de la faille voisinaient avec la roche de
		# l'overworld dans la rangée « Cristal », et rien ne disait d'où venait
		# quoi. Un catalogue mélangé ne montre pas le jeu, il montre un tas.
		_next_z += SET_GAP
		await _build_material_rows(content_set)
		await _build_plant_row(content_set)
		await _build_tree_row(content_set)
		# LES STRUCTURES SONT UN SYSTÈME DE L'OVERWORLD (E.2/3.4) : les villages
		# n'existent pas ailleurs. La rangée suit donc le monde auquel elle
		# appartient au lieu d'être posée en bout de vitrine.
		if content_set == "overworld":
			await _build_structure_row(content_set)
		await _build_object_row(content_set)
	print("[VITRINE] %d monde(s) en %d ms" % [_content_sets().size(), Time.get_ticks_msec() - started])
	_flush()
	if tree_root != null:
		_build_labels(tree_root)
	done = true


## Jeux de contenu présents au catalogue, dans l'ordre d'affichage : l'overworld
## d'abord (c'est le monde de référence), les autres ensuite, et « aucun » en
## dernier — les objets posés n'appartiennent à aucun monde.
##
## DÉRIVÉS DU CATALOGUE, comme tout le reste ici : ajouter `data/materials/
## <nouveau_monde>/` lui donne son bloc de rangées sans qu'on touche à ce
## fichier.
func _content_sets() -> Array[String]:
	var seen := {}
	for id: String in GameData.materials:
		seen[String((GameData.materials[id] as Dictionary).get("dimension", "overworld"))] = true
	for id: String in GameData.trees:
		seen[String((GameData.trees[id] as Dictionary).get("dimension", "overworld"))] = true
	var others: Array[String] = []
	for key: String in seen:
		if key != "overworld" and key != "":
			others.append(key)
	others.sort()
	var out: Array[String] = []
	if seen.has("overworld"):
		out.append("overworld")
	out.append_array(others)
	if seen.has(""):
		out.append("")
	return out


func _set_of(entry: Dictionary) -> String:
	return String(entry.get("dimension", "overworld"))


# --- Rangées ---

## UNE RANGÉE PAR CATÉGORIE DE MATÉRIAU, catégories ET contenu tirés du
## catalogue. Les blocs EN CROIX sont écartés d'ici : ils ont leur propre
## rangée, où on les regarde pour ce qu'ils sont (des plantes) et non pour la
## catégorie de leur fiche.
func _build_material_rows(content_set: String) -> void:
	var by_category := {}
	for id: String in GameData.materials:
		var mat: Dictionary = GameData.materials[id]
		if String(mat.get("render", "cube")) == "croix":
			continue
		if _set_of(mat) != content_set:
			continue
		var category := String(mat.get("category", "?"))
		if category == "objet":
			continue  # Rangée à part : un objet posé se montre en OBJET, pas en bloc.
		if not by_category.has(category):
			by_category[category] = [] as Array[String]
		(by_category[category] as Array[String]).append(id)
	var categories := by_category.keys()
	categories.sort()
	for category: String in categories:
		var ids: Array[String] = by_category[category]
		ids.sort()  # Ordre STABLE : une capture doit être comparable à la précédente.
		_row(content_set, "category.%s.name" % category, ids, STEP, ROW_GAP)
		await _breathe()


## LES PLANTES EN CROIX, toutes catégories confondues. Elles se posent comme
## n'importe quel bloc — c'est tout l'intérêt du choix de rendu du 2026-08-04 :
## une plante n'est pas un second registre, c'est un matériau avec un `render`.
func _build_plant_row(content_set: String) -> void:
	var ids: Array[String] = []
	for id: String in GameData.materials:
		var mat: Dictionary = GameData.materials[id]
		if String(mat.get("render", "cube")) == "croix" and _set_of(mat) == content_set:
			ids.append(id)
	ids.sort()
	_row(content_set, "vitrine.plantes", ids, STEP, ROW_GAP)
	await _breathe()


## Pose une rangée de blocs pleins et enregistre où chaque id a atterri.
func _row(content_set: String, label: String, ids: Array[String], step: int, gap: int) -> void:
	if ids.is_empty():
		return
	var z := _next_z
	_next_z += gap
	# `scale` dit la TAILLE de ce qu'on y trouve, et sert à cadrer les captures.
	# Une donnée sur la rangée plutôt qu'un `if` sur son nom dans la sonde : le
	# jour où une rangée d'un nouveau genre apparaît, elle porte son cadrage.
	rows.append({"label": label, "z": z, "scale": "bloc", "set": content_set})
	var x := ORIGIN.x
	for id: String in ids:
		var runtime_id: int = GameData.material_runtime_ids.get(id, 0)
		if runtime_id == 0:
			continue  # Sans id runtime, le bloc n'existe pas — la sonde le dira.
		var pos := Vector3i(x, PLACE_Y, z)
		if WorldManager.set_block_batched(pos, runtime_id):
			blocks_written += 1
		positions["materiau:" + id] = pos
		x += step
		_maybe_flush()


## LES ESSENCES D'ARBRE, générées pour de vrai. Poser leur bois et leurs
## feuilles en cubes ne montrerait rien : ce qu'on veut voir d'une essence, c'est
## sa SILHOUETTE — l'architecture du tronc, la forme de la couronne. C'est
## justement ce que le générateur a été réécrit deux fois pour produire.
func _build_tree_row(content_set: String) -> void:
	var ids: Array[String] = []
	for id: String in GameData.trees:
		if _set_of(GameData.trees[id]) == content_set:
			ids.append(id)
	if ids.is_empty():
		return
	ids.sort()
	var z := _next_z
	_next_z += TREE_ROW_GAP
	rows.append({"label": "vitrine.arbres", "z": z, "scale": "arbre", "set": content_set})
	var x := ORIGIN.x
	for species_id: String in ids:
		var species: Dictionary = GameData.trees[species_id]
		var base := Vector3i(x, PLACE_Y, z)
		# GRAINE FIXE PAR ESSENCE, et non la graine du monde : deux captures de
		# la vitrine doivent montrer le MÊME arbre, sinon on ne peut pas
		# comparer un avant et un après.
		var tree: Dictionary = TreeGenerator.generate(base, hash(species_id), species)
		var tree_blocks: Dictionary = tree.get("blocks", {})
		var anchor := base
		var has_anchor := false
		for block_pos: Vector3i in tree_blocks:
			if WorldManager.set_block_batched(block_pos, int(tree_blocks[block_pos])):
				blocks_written += 1
			if not has_anchor:
				anchor = block_pos
				has_anchor = true
			_maybe_flush()
		# `set_subdiv_grid_BATCHED`, et le B majuscule vaut 411 secondes. La
		# variante instantanée remaille jusqu'à sept chunks par bloc subdivisé,
		# et un arbre rastérisé sur un réseau de 8 px en compte des milliers :
		# la rangée d'arbres coûtait à elle seule 411 s sur les 413 de la
		# construction entière, mesure à l'appui.
		var subdivs: Dictionary = tree.get("trunk_subdivs", {})
		for block_pos: Vector3i in subdivs:
			WorldManager.set_subdiv_grid_batched(block_pos, subdivs[block_pos])
			_maybe_flush()
		# ANCRE = LE PREMIER BLOC RÉELLEMENT ÉMIS. Le PIED de l'arbre paraissait
		# le repère évident, et il est faux : `arbre_mort` a un tronc d'un rayon
		# d'un bloc, rastérisé en sous-voxels, et sa cellule de base n'est pas
		# forcément pleine. La sonde a vérifié de l'air et l'a dit.
		if has_anchor:
			positions["arbre:" + species_id] = anchor
		x += TREE_STEP
		await _breathe()


## LES STRUCTURES. Le catalogue est celui des ARCHÉTYPES de bâtiment
## (`CityGenerator.ARCHETYPES`) : ajouter un archétype ajoute sa maquette ici
## sans qu'on y touche.
##
## LA TOUR DE DONJON N'Y EST PAS, et c'est un manque assumé plutôt qu'un oubli :
## elle n'est pas un jeu de blocs qu'on estampe, mais une fonction échantillonnée
## bloc à bloc sur une emprise de 112 × 112 × ~60 — près de huit cent mille
## appels sur le fil principal. Elle a déjà sa sonde (`--probe-tour`).
func _build_structure_row(content_set: String) -> void:
	var names := CityGenerator.ARCHETYPES.keys()
	names.sort()
	var z := _next_z
	_next_z += STRUCTURE_ROW_GAP
	rows.append({"label": "vitrine.structures", "z": z, "scale": "structure", "set": content_set})
	var palette := _structure_palette()
	if palette.is_empty():
		return
	var x := ORIGIN.x
	for archetype: String in names:
		var local: Dictionary = CityGenerator.building_blocks(Vector3i(0, 0, 1), palette, archetype)
		var origin := Vector3i(x, GROUND_Y, z)
		var anchor := origin
		var has_anchor := false
		for local_pos: Vector3i in local:
			var pos := origin + local_pos
			if WorldManager.set_block_batched(pos, int(local[local_pos])):
				blocks_written += 1
			if not has_anchor:
				# ANCRE = LE PREMIER BLOC RÉELLEMENT ÉMIS, et non un coin calculé
				# de tête. `building_blocks` commence par le plancher, mais son
				# emprise dépend de la marge de l'archétype : un `origin` nu ne
				# tombe sur aucun bloc, et la sonde aurait vérifié de l'air.
				anchor = pos
				has_anchor = true
			_maybe_flush()
		if has_anchor:
			positions["structure:" + archetype] = anchor
		x += STRUCTURE_STEP
		await _breathe()


## LA RANGÉE D'OBJETS POSÉS, et elle ne peut PAS être une rangée de blocs.
##
## Un bloc `objet_<id>` est marqué `render: "objet"` : le mailleur ne l'émet
## pas, c'est `PlacedItemManager` qui monte le vrai modèle depuis l'INSTANCE.
## La première version écrivait les blocs comme n'importe quel matériau, sans
## instance : la rangée était donc rigoureusement vide, et aucune assertion ne
## pouvait le dire — le bloc était bien là, il n'avait simplement rien à
## montrer. Il a fallu la capture.
##
## Un exemplaire est donc FORGÉ par objet, avec le premier matériau de chaque
## catégorie de sa recette : c'est ce que la vitrine doit montrer, une épée
## faite de bois et de métal réels.
func _build_object_row(content_set: String) -> void:
	var by_group := {}
	for id: String in GameData.materials:
		var mat: Dictionary = GameData.materials[id]
		if String(mat.get("category", "")) != "objet" or _set_of(mat) != content_set:
			continue
		var key := _object_group_of(String(mat.get("parametric", {}).get("source_id", "")))
		if not by_group.has(key):
			by_group[key] = [] as Array[String]
		(by_group[key] as Array[String]).append(id)
	if by_group.is_empty():
		return
	# ORDRE FIXE, du plus courant au plus rare, et non alphabétique : on cherche
	# une masse dans « contondant », pas à la lettre C. Une clé absente de la
	# liste passe en queue plutôt que de disparaître — ajouter un type de dégâts
	# ne doit pas escamoter ses armes sans le moindre signe.
	var keys: Array[String] = []
	for key: String in GROUP_ORDER:
		if by_group.has(key):
			keys.append(key)
	var rest := by_group.keys()
	rest.sort()
	for key: String in rest:
		if not (key in keys):
			keys.append(key)
	for key: String in keys:
		var ids: Array[String] = by_group[key]
		ids.sort()
		_row(content_set, GROUP_LABELS.get(key, "material.objet.name"), ids, STEP, ROW_GAP)
		# UN EXEMPLAIRE PAR BLOC, sans quoi la rangée est INVISIBLE : le bloc
		# `objet_*` n'est pas maillé, c'est `PlacedItemManager` qui monte le
		# modèle depuis l'instance. Le regroupement par classe a fait passer
		# cette rangée par `_row`, qui pose des blocs et rien d'autre — et les
		# quarante et un objets ont disparu d'un coup. C'est l'assertion
		# « chaque bloc d'objet porte un exemplaire » qui l'a dit, écrite
		# précisément parce que ce défaut-là ne se voit qu'en capture.
		for id: String in ids:
			var instance := _sample_instance(String((GameData.materials[id] as Dictionary)
					.get("parametric", {}).get("source_id", "")))
			if not instance.is_empty() and positions.has("materiau:" + id):
				PlacedItemManager.remember(positions["materiau:" + id], instance)
		await _breathe()


## Groupe d'un objet du catalogue : sa CLASSE DE DÉGÂTS pour une arme, son TYPE
## sinon. C'est le rangement des fiches sur disque (`data/items/<type>/` et
## `data/items/arme/<classe>/`), relu depuis les champs plutôt que depuis le
## chemin — GameData a déjà vérifié que les deux s'accordent.
func _object_group_of(item_id: String) -> String:
	var item: Dictionary = GameData.items.get(item_id, {})
	if item.is_empty():
		return "divers"
	var type_id := String(item.get("type", ""))
	if type_id == "arme":
		var weapon_class := String(item.get("weapon_class", ""))
		return weapon_class if weapon_class != "" else "arme"
	return type_id


const GROUP_ORDER: Array[String] = [
	"tranchant", "percant", "contondant", "distance", "magique",
	"arme", "bouclier", "armure", "outil", "livre", "divers",
]
## Clé de traduction par groupe. Les trois classes de dégâts empruntent celle de
## la COMPÉTENCE du même nom : le jeu nomme déjà ces familles, il serait absurde
## de les renommer ici et de laisser les deux libellés diverger.
const GROUP_LABELS := {
	"tranchant": "skill.tranchant.name",
	"percant": "skill.percant.name",
	"contondant": "skill.contondant.name",
	# Ces deux-là n'ont pas de compétence homonyme : le tir a `arc`/`arbalete`,
	# la magie a `baton_magique`. Elles ont donc leur propre libellé.
	"distance": "weapon_class.distance.name",
	"magique": "weapon_class.magique.name",
	"arme": "item_type.arme.name",
	"bouclier": "item_type.bouclier.name",
	"armure": "item_type.armure.name",
	"outil": "item_type.outil.name",
	"livre": "item_type.livre.name",
	"divers": "material.objet.name",
}


## Exemplaire représentatif d'un objet du catalogue. Le repli générique
## (`objet_divers`) n'a pas d'objet derrière lui : il reçoit une RESSOURCE, ce
## qui est exactement le cas qu'il existe pour couvrir.
func _sample_instance(item_id: String) -> Dictionary:
	if GameData.items.has(item_id):
		var recipe: Dictionary = (GameData.items[item_id] as Dictionary).get("recipe", {})
		var choices := {}
		for input: Dictionary in recipe.get("inputs", []):
			var category := String(input.get("category", ""))
			var pick := _first_id_of_category(category)
			if pick != "":
				choices[category] = pick
		return ItemFactory.craft(item_id, choices, 1.0)
	var resource_ids := GameData.resources.keys()
	if resource_ids.is_empty():
		return {}
	resource_ids.sort()
	return ItemFactory.resource_instance(String(resource_ids[0]))


func _first_id_of_category(category: String) -> String:
	var ids: Array[String] = []
	for id: String in GameData.materials:
		if String((GameData.materials[id] as Dictionary).get("category", "")) == category:
			ids.append(id)
	if ids.is_empty():
		return ""
	ids.sort()
	return ids[0]


## Palette de construction, prise dans le CATALOGUE et non écrite ici : le
## premier matériau de chaque catégorie utile, en ordre stable.
func _structure_palette() -> Dictionary:
	var wall := _first_of_category("roche")
	var roof := _first_of_category("planches")
	var floor_mat := _first_of_category("construction")
	var beam := _first_of_category("bois")
	if wall == 0 or roof == 0 or floor_mat == 0 or beam == 0:
		push_warning("ShowcaseBuilder : palette de structure incomplète — rangée sautée.")
		return {}
	return {"mur": wall, "toit": roof, "sol": floor_mat, "poutre": beam}


func _first_of_category(category: String) -> int:
	var ids: Array[String] = []
	for id: String in GameData.materials:
		if String((GameData.materials[id] as Dictionary).get("category", "")) == category:
			ids.append(id)
	if ids.is_empty():
		return 0
	ids.sort()
	return GameData.material_runtime_ids.get(ids[0], 0)


# --- Étiquettes ---

## ÉTIQUETTES AU SOL devant chaque rangée. Des `Label3D` et non des lettres en
## blocs : une police en voxels demanderait un atlas de glyphes, ne serait pas
## traduisible, et coûterait plus de blocs que le contenu qu'elle annonce.
##
## Elles sont reconstruites à chaque démarrage du monde, comme les rangées
## elles-mêmes : rien à persister, donc rien qui puisse diverger du monde.
func _build_labels(root: Node3D) -> void:
	var holder := root.get_node_or_null("ShowcaseLabels")
	if holder != null:
		holder.free()
	holder = Node3D.new()
	holder.name = "ShowcaseLabels"
	root.add_child(holder)
	for row: Dictionary in rows:
		var label := Label3D.new()
		# « Faille de mana — Cristal », et pas « Cristal » seul : sur une vitrine
		# à plusieurs mondes, la catégorie ne suffit plus à dire ce qu'on regarde.
		label.text = "%s — %s" % [_set_name(String(row.get("set", "overworld"))), tr(String(row["label"]))]
		label.font_size = 96
		# PETITE ET SUR LE CÔTÉ. La première version faisait deux mètres de haut
		# et se dressait DANS l'axe de la rangée : sur la capture, le mot
		# « Minerai » couvrait les minerais. Une étiquette qui masque ce qu'elle
		# annonce est pire qu'une rangée sans étiquette.
		label.pixel_size = 0.011
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.position = Vector3(float(ORIGIN.x) - 3.0, float(PLACE_Y) + 0.8, float(row["z"]) - 3.0)
		holder.add_child(label)


## Nom lisible d'un jeu de contenu. Les dossiers portent le nom du JEU DE BIOMES
## (`magique`), pas celui de la dimension (`faille_de_mana`) : on remonte donc
## par `biome_set` jusqu'à la fiche de dimension qui l'emploie. Sans ça, la
## vitrine annoncerait « magique » là où le jeu dit « Faille de mana ».
func _set_name(content_set: String) -> String:
	if content_set == "":
		return tr("vitrine.hors_monde")
	if content_set == "overworld":
		return tr("vitrine.overworld")
	for id: String in GameData.dimensions:
		var fiche: Dictionary = GameData.dimensions[id]
		if String(fiche.get("biome_set", id)) == content_set:
			return tr(String(fiche.get("name_key", id)))
	return content_set


# --- Écriture ---

func _maybe_flush() -> void:
	_pending += 1
	if _pending >= FLUSH_EVERY:
		_flush()


func _flush() -> void:
	_pending = 0
	var started := Time.get_ticks_msec()
	# `false` : ON NE REMAILLE PAS SOI-MÊME. La vitrine touche des centaines de
	# chunks dont le joueur n'en voit qu'une poignée ; les remailler tous, à la
	# main et de façon synchrone, coûtait 32 s sur 59. Le drapeau sale suffit —
	# la file de streaming s'en occupe, et elle sait dans quel ordre.
	WorldManager.flush_batched_edits(false)
	flush_ms += Time.get_ticks_msec() - started


## Rend la main au moteur ET vide le flux. Une rangée d'arbres écrit des
## dizaines de milliers de blocs : sans ça, la construction serait une seule
## frame de plusieurs secondes.
func _breathe() -> void:
	_flush()
	var started := Time.get_ticks_msec()
	await Engine.get_main_loop().process_frame
	idle_ms += Time.get_ticks_msec() - started

extends Node
## OBJETS POSÉS AU SOL EN TANT QUE BLOCS (2026-08-06, Ctrl + clic droit).
##
## ---------------------------------------------------------------------------
## POURQUOI UN REGISTRE, ET PAS UNE ENTRÉE DE PALETTE PAR OBJET
## ---------------------------------------------------------------------------
## Le monde voxel ne stocke qu'un id de matériau par bloc. `GameData` génère un
## matériau par TYPE d'objet (`objet_<item_id>`), ce qui donne à chaque type sa
## propre apparence et son id runtime stable — mais un TYPE ne dit rien de
## l'exemplaire : deux épées peuvent différer par leur qualité, leur bois, leur
## minerai, leur gemme. Une entrée de palette par exemplaire est exclue (18 081
## combinaisons pour les seules armes, et les ids runtime sont figés au
## démarrage). Ce registre porte donc le seul état que le bloc ne sait pas
## dire : L'INSTANCE ELLE-MÊME.
##
## ---------------------------------------------------------------------------
## L'INSTANCE EST RENDUE TELLE QUELLE, ET C'EST LE POINT CRITIQUE
## ---------------------------------------------------------------------------
## `take()` rend le dictionnaire STOCKÉ, jamais un objet reconstruit depuis sa
## fiche. Reconstruire ferait de « poser puis reprendre » une machine à réparer
## gratuite — qualité et usure repartiraient à neuf — et ça ne se verrait qu'une
## fois le joueur en train de l'exploiter. Le seul champ recalculé serait un
## champ qu'on aurait tort de recalculer.
##
## Registre POSITIONNEL comme celui des pousses et des coffres : la clé est le
## bloc, ce qui rend la vérification de cohérence triviale et la sauvegarde
## différentielle (E.10) directe.

## Objets posés : Vector3i → { "item": Dictionary, "dimension": StringName,
##                              "yaw": int (quarts de tour, 0-3) }.
var placed := {}

## Script de rendu d'objet, le MÊME que la main du joueur et que le butin au
## sol. `preload` et non `class_name` : le script n'en déclare pas.
##
## UN OBJET POSÉ S'AFFICHE AVEC SON VRAI MODÈLE. La première version laissait le
## bloc se mailler en cube : les quarante et un objets du catalogue étaient
## quarante et un cubes colorés, et une épée posée ne ressemblait pas à une épée.
## Le bloc reste là — il occupe la case, se vise et traverse la sauvegarde — mais
## il est marqué `render: "objet"` et le mailleur ne l'émet pas ; c'est ce nœud
## qui le montre. Refaire un rendu ici aurait divergé au premier type d'objet
## ajouté : celui-ci sait déjà assembler une arme en pièces, extruder un sprite
## d'outil et remapper un .vox par matériaux.
const HELD_ITEM_SCRIPT := preload("res://scenes/entities/held_item.gd")

var _marker_root: Node3D
var _markers: Array[Node3D] = []


func _ready() -> void:
	# UN BLOC PEUT DISPARAÎTRE SANS PASSER PAR `take` : il est miné, une
	# explosion l'emporte, un chunk est réécrit. Sans ce branchement, l'objet
	# resterait dans le registre pour toujours — et le joueur, lui, aurait perdu
	# son épée. On le lui rend au sol, à l'endroit exact.
	EventBus.block_destroyed.connect(_on_block_destroyed)
	# La bascule de dimension est notifiée par WorldManager, qui appelle
	# `on_dimension_changed` — il n'y a pas de signal pour ça, et DropManager est
	# prévenu exactement de la même façon.


## Id de matériau qui porte une instance donnée.
##
## `item_id` est l'id de l'objet pour tout ce qui est crafté. Les ressources de
## créature (viande, peau) y mettent leur GENRE, qui n'est pas un objet du
## catalogue : elles retombent sur le matériau générique.
static func material_for(instance: Dictionary) -> String:
	var candidate := GameData.OBJECT_PREFIX + String(instance.get("item_id", ""))
	if GameData.materials.has(candidate):
		return candidate
	return GameData.GENERIC_OBJECT_MATERIAL


## Enregistre une instance posée en `pos`. N'ÉCRIT PAS LE BLOC : l'appelant le
## fait, parce que lui seul sait s'il passe par `set_block` (pose du joueur,
## remaillage immédiat) ou `set_block_batched` (construction en masse).
func remember(pos: Vector3i, instance: Dictionary, yaw: int = 0) -> void:
	placed[pos] = {
		# DUPLICATION PROFONDE : l'instance contient `materials`, un
		# sous-dictionnaire. Sans copie profonde, l'objet posé et celui resté en
		# main partageraient leurs matériaux — modifier l'un modifierait l'autre.
		"item": instance.duplicate(true),
		"dimension": WorldManager.active_dimension,
		# TOUS POSÉS PAREIL, à plat et droit. La première version dérivait
		# l'orientation de la position : deux épées côte à côte partaient chacune
		# dans son sens et une rangée d'objets ressemblait à un tas renversé. Un
		# objet qu'on dépose se pose droit ; c'est au joueur de le tourner.
		"yaw": posmod(yaw, QUARTER_TURNS),
	}
	refresh_markers()
	_broadcast(pos)


## Instance posée en `pos` dans la dimension COURANTE, ou {} — sans la retirer.
func peek(pos: Vector3i) -> Dictionary:
	var entry: Dictionary = placed.get(pos, {})
	if entry.is_empty():
		return {}
	# La dimension compte : donjons et failles occupent les MÊMES coordonnées
	# que l'overworld près de l'origine. C'est le bug qu'avait DropManager, et
	# il rendait un butin de donjon ramassable depuis la surface.
	if String(entry.get("dimension", "overworld")) != String(WorldManager.active_dimension):
		return {}
	return entry["item"]


## Reprend l'instance posée en `pos` et l'efface du registre. N'EFFACE PAS LE
## BLOC, pour la même raison que `remember` ne l'écrit pas.
func take(pos: Vector3i) -> Dictionary:
	var instance := peek(pos)
	if instance.is_empty():
		return {}
	placed.erase(pos)
	refresh_markers()
	_broadcast_removed(pos)
	return instance


func forget(pos: Vector3i) -> void:
	placed.erase(pos)
	refresh_markers()
	_broadcast_removed(pos)


func count() -> int:
	return placed.size()


## Quarts de tour possibles. Quatre et non huit : le monde est aligné sur grille
## à toutes les résolutions (4.1), et un objet posé de biais entre deux blocs
## trahirait cet alignement partout où il se pose contre un mur.
const QUARTER_TURNS := 4


## Fait pivoter d'un quart de tour l'objet posé en `pos`. Retourne false s'il n'y
## a pas d'objet là — c'est ce qui permet à l'appelant d'enchaîner sur autre
## chose sans avoir à interroger le registre d'abord.
func rotate(pos: Vector3i) -> bool:
	if peek(pos).is_empty():
		return false
	var entry: Dictionary = placed[pos]
	entry["yaw"] = posmod(int(entry.get("yaw", 0)) + 1, QUARTER_TURNS)
	refresh_markers()
	# ON DIFFUSE L'ORIENTATION, PAS LE GESTE. « Il a tourné » obligerait le
	# client à connaître l'état d'avant, donc à n'avoir manqué aucun message.
	_broadcast(pos)
	return true


## Le bloc a disparu autrement que par une reprise : l'objet tombe au sol.
##
## On ne le détruit pas. Un joueur qui donne un coup de pioche sur son épée
## posée a fait une maladresse, pas un choix — et rien dans le jeu ne l'aurait
## averti que ce bloc-là était son épée.
func _on_block_destroyed(pos: Vector3i, _material_id: int) -> void:
	if not placed.has(pos):
		return
	var entry: Dictionary = placed[pos]
	placed.erase(pos)
	refresh_markers()
	if String(entry.get("dimension", "overworld")) != String(WorldManager.active_dimension):
		return
	DropManager.drop(Vector3(pos) + Vector3(0.5, 0.5, 0.5), [entry["item"]])


## Appelé par WorldManager à chaque bascule de dimension : ce qui est visible
## change entièrement. Sans ça, les objets posés dans une faille apparaîtraient
## en surface — donjons et failles partagent les coordonnées de l'overworld,
## c'est le bug qu'avait DropManager avant le 2026-08-02.
func on_dimension_changed() -> void:
	refresh_markers()


# --- Rendu ---

## Reconstruit les objets visibles. Brutal et assumé : on repart de zéro à
## chaque changement, comme `DropManager._refresh_markers`. Un objet posé est un
## geste rare — quelques dizaines par partie — et un cache incrémental coûterait
## plus en complexité qu'il ne rapporterait, avec le risque bien réel d'un
## marqueur oublié sur un bloc disparu.
func refresh_markers() -> void:
	for marker in _markers:
		if is_instance_valid(marker):
			marker.queue_free()
	_markers.clear()
	if placed.is_empty():
		return
	if _marker_root == null or not is_instance_valid(_marker_root):
		var main := get_node_or_null("/root/Main")
		if main == null:
			return
		_marker_root = Node3D.new()
		_marker_root.name = "PlacedItems"
		main.add_child(_marker_root)
	for pos: Vector3i in placed:
		var entry: Dictionary = placed[pos]
		if String(entry.get("dimension", "overworld")) != String(WorldManager.active_dimension):
			continue
		var pivot := Node3D.new()
		# CENTRÉ DANS SA CASE et posé au tiers de sa hauteur : l'objet doit se
		# lire comme DÉPOSÉ sur la case, pas comme flottant au milieu d'un cube
		# d'air. L'orientation dérive de la position — deux épées côte à côte ne
		# doivent pas être la même image dupliquée.
		pivot.position = Vector3(pos) + Vector3(0.5, 0.12, 0.5)
		# COUCHÉ, pas debout. Le modèle d'objet est bâti dans l'orientation de la
		# MAIN — une épée verticale, longue de plus d'un bloc : posée telle
		# quelle, elle sortait de sa case par le haut et se plantait dans le sol
		# comme un piquet. Un objet déposé se lit à plat.
		# Ordre de rotation YXZ (défaut de Node3D) : le lacet s'applique APRÈS le
		# basculement, donc autour de la verticale du monde. L'objet couché
		# pivote bien à plat sur le sol, et non autour de son propre axe.
		pivot.rotation_degrees = Vector3(90.0, 90.0 * float(int(entry.get("yaw", 0))), 0.0)
		_marker_root.add_child(pivot)
		var visual := MeshInstance3D.new()
		visual.set_script(HELD_ITEM_SCRIPT)
		# Propriétés AVANT `add_child` : c'est lui qui déclenche `_ready`.
		visual.source = "explicite"
		visual.explicit_entry = {"kind": "object", "object": entry["item"]}
		visual.in_hand = false
		pivot.add_child(visual)
		_markers.append(pivot)


# --- Réplication (2026-08-08) ---
#
# L'autorité applique puis annonce ; le client se contente d'appliquer ce qu'on
# lui annonce. Les fonctions `apply_remote_*` écrivent dans le MÊME registre et
# rafraîchissent le MÊME rendu que le chemin local : il n'y a pas de « version
# client » de l'objet posé.

func _broadcast(pos: Vector3i) -> void:
	if not (NetworkManager.is_authority() and NetworkManager.has_peers()):
		return
	var entry: Dictionary = placed.get(pos, {})
	if entry.is_empty():
		return
	NetworkManager.rpc_placed_item.rpc(pos, entry["item"], int(entry.get("yaw", 0)),
			String(entry.get("dimension", "overworld")))


func _broadcast_removed(pos: Vector3i) -> void:
	if NetworkManager.is_authority() and NetworkManager.has_peers():
		NetworkManager.rpc_placed_item_removed.rpc(pos)


func apply_remote_placed(pos: Vector3i, instance: Dictionary, yaw: int,
		dimension: StringName) -> void:
	placed[pos] = {"item": instance.duplicate(true), "dimension": dimension,
		"yaw": posmod(yaw, QUARTER_TURNS)}
	refresh_markers()


func apply_remote_removed(pos: Vector3i) -> void:
	placed.erase(pos)
	refresh_markers()


# --- Sauvegarde (E.10, via SaveManager) ---

func save_state() -> Dictionary:
	var out := {}
	for pos: Vector3i in placed:
		var entry: Dictionary = placed[pos]
		out["%d,%d,%d" % [pos.x, pos.y, pos.z]] = {
			"item": entry["item"],
			"dimension": String(entry.get("dimension", "overworld")),
			"yaw": int(entry.get("yaw", 0)),
		}
	return out


func restore_state(data: Dictionary) -> void:
	placed.clear()
	for key: String in data:
		var parts := key.split(",")
		if parts.size() != 3 or not (data[key] is Dictionary):
			continue
		var entry: Dictionary = data[key]
		var instance: Dictionary = entry.get("item", {})
		if instance.is_empty():
			continue
		# LES UIDS REVIENNENT DE LA SAUVEGARDE ET DOIVENT ÊTRE RÉSERVÉS. Le
		# compteur d'ItemFactory est statique et repart à 1 à chaque lancement :
		# sans ça, le premier objet crafté après un chargement reçoit un uid déjà
		# porté par une épée posée dans le monde, et toute recherche par uid
		# tombe sur l'autre. Le bug est silencieux — il a déjà été payé une fois
		# sur les objets d'inventaire.
		ItemFactory.note_uid(int(instance.get("uid", 0)))
		placed[Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))] = {
			"item": instance,
			"dimension": StringName(entry.get("dimension", "overworld")),
			"yaw": int(entry.get("yaw", 0)),
		}
	refresh_markers()

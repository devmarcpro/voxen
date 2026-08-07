extends Node
## POUSSES (2026-08-03, demande de l'auteur : « on rajoutera les pousses qui
## sont une version miniature de la taille d'un bloc d'un arbre en entier »).
##
## Une pousse est UN BLOC qui contient l'arbre entier en réduction, sculpté en
## sous-voxels. Ce n'est pas un décor : posée, elle grandit et devient le vrai
## arbre de son essence.
##
## ---------------------------------------------------------------------------
## POURQUOI UN REGISTRE, ET PAS UN MATÉRIAU QUI SAIT TOUT
## ---------------------------------------------------------------------------
## Le monde voxel ne stocke qu'un id de matériau par bloc : il ne peut pas
## retenir QUAND une pousse a été plantée. Ce registre-ci porte donc le seul
## état que le bloc ne sait pas dire — l'essence et l'instant de plantation —
## et rien d'autre. La géométrie reste dans le monde, où elle a sa place.
##
## Le registre est POSITIONNEL comme celui des coffres : la clé est le bloc, ce
## qui rend la vérification de cohérence triviale (le bloc a-t-il disparu ?) et
## la sauvegarde différentielle (E.10) directe.

## Ticks avant qu'une pousse devienne un arbre. 3 000 ticks ≈ un jour de jeu
## et demi : assez long pour que planter une forêt soit un projet, assez court
## pour qu'on voie le résultat dans une même session.
const GROWTH_TICKS := 3000

## Préfixe des matériaux de pousse, généré par GameData pour chaque essence.
const PREFIX := "pousse_"

## Pousses vivantes : Vector3i → { "species": String, "planted": int,
##                                 "dimension": StringName }.
var saplings := {}


func _ready() -> void:
	TickManager.tick_world.connect(_on_tick)


## Id de matériau de pousse pour une essence, et l'inverse.
static func material_for(species_id: String) -> String:
	return PREFIX + species_id


static func species_of(material_id: String) -> String:
	return material_id.substr(PREFIX.length()) if material_id.begins_with(PREFIX) else ""


## Enregistre une pousse fraîchement posée et lui donne sa forme.
##
## La MINIATURE est écrite ici et pas à la pose : c'est la seule façon que la
## pousse ait la même allure d'où qu'elle vienne — main du joueur, butin
## d'abattage, menu de triche ou repeuplement futur.
func plant(pos: Vector3i, species_id: String) -> bool:
	var species: Dictionary = GameData.trees.get(species_id, {})
	if species.is_empty():
		return false
	var grid := TreeGenerator.sapling_grid(species, _seed_at(pos))
	if grid.is_empty():
		return false
	WorldManager.set_subdiv_grid(pos, grid, SubdivGrid.dominant_id(grid))
	saplings[pos] = {
		"species": species_id,
		"planted": TickManager.tick_index,
		"dimension": WorldManager.active_dimension,
	}
	return true


## Retire une pousse du registre (arrachée, minée, ou devenue arbre).
func forget(pos: Vector3i) -> void:
	saplings.erase(pos)


func count() -> int:
	return saplings.size()


## Une pousse arrivée à terme devient son arbre.
##
## UNE SEULE PAR TICK, comme les créatures de village : faire pousser une forêt
## entière dans le même tick reproduirait exactement le pic que le peuplement de
## village a coûté (mesuré à 62 ms en jeu), et pour la même raison — un arbre
## est aujourd'hui plusieurs centaines de blocs.
func _on_tick(_tick_index: int) -> void:
	if saplings.is_empty():
		return
	var mature := Vector3i.ZERO
	var found := false
	for pos: Vector3i in saplings:
		var entry: Dictionary = saplings[pos]
		if String(entry.get("dimension", "overworld")) != String(WorldManager.active_dimension):
			continue  # Gelée hors de sa dimension, comme les créatures (3.5).
		if TickManager.tick_index - int(entry["planted"]) < GROWTH_TICKS:
			continue
		mature = pos
		found = true
		break
	if found:
		_grow(mature)


## Fait pousser l'arbre à la place de la pousse.
func _grow(pos: Vector3i) -> void:
	var entry: Dictionary = saplings[pos]
	saplings.erase(pos)
	# LA POUSSE A PU ÊTRE ARRACHÉE entre-temps sans passer par `forget` (bloc
	# miné, terrain remplacé, chunk réécrit) : sans ce contrôle, un arbre
	# surgirait d'un trou où plus rien ne poussait.
	var here := WorldManager.block_at_world(pos)
	if here == 0:
		return
	var species: Dictionary = GameData.trees.get(String(entry["species"]), {})
	if species.is_empty():
		return
	var tree := TreeGenerator.generate(pos, WorldManager.world_seed + int(entry["planted"]), species)
	# ÉCRITURE EN LOT, ET C'EST UN CORRECTIF DE PERFORMANCE, pas un nettoyage.
	# Ces deux boucles passaient par les variantes INSTANTANÉES, qui remaillent
	# jusqu'à sept chunks PAR BLOC. Un arbre compte des centaines de blocs pleins
	# et des milliers de blocs subdivisés : une pousse arrivée à terme figeait
	# donc la frame. Mesuré sur le monde vitrine, qui pose les 57 essences par ce
	# même chemin : 411 secondes en instantané contre 12,8 en lot.
	#
	# Le vidage est explicite ici et non laissé au tick : la croissance doit se
	# voir dans la frame où elle a lieu, pas à la suivante.
	#
	# CONSÉQUENCE RÉSEAU, à dire plutôt qu'à taire : `set_block` routait en RPC,
	# le chemin batché non. La croissance devient donc locale — ce qui est déjà
	# le cas de tout ce qui a été écrit depuis le 2026-07-20 (les pousses ne sont
	# répliquées nulle part ailleurs : ni le registre, ni la plantation) et ce
	# qui reste juste tant que les deux camps partagent tick et graine. À
	# reprendre avec le reste de la réplication, pas avant.
	var blocks: Dictionary = tree["blocks"]
	for block_pos: Vector3i in blocks:
		WorldManager.set_block_batched(block_pos, blocks[block_pos])
	var subdivs: Dictionary = tree["trunk_subdivs"]
	for block_pos: Vector3i in subdivs:
		WorldManager.set_subdiv_grid_batched(block_pos, subdivs[block_pos])
	WorldManager.flush_batched_edits()
	EventBus.ui_notification.emit("ui.toast.pousse_grandie")


## Graine de la miniature. Deux pousses de la même essence côte à côte ne
## doivent pas être le même modèle réduit au voxel près.
func _seed_at(pos: Vector3i) -> int:
	return absi((pos.x * 73856093) ^ (pos.y * 19349663) ^ (pos.z * 83492791))


# --- Sauvegarde (E.10, via SaveManager) ---

func save_state() -> Dictionary:
	var out := {}
	for pos: Vector3i in saplings:
		var entry: Dictionary = saplings[pos]
		out["%d,%d,%d" % [pos.x, pos.y, pos.z]] = {
			"species": String(entry["species"]),
			"planted": int(entry["planted"]),
			"dimension": String(entry.get("dimension", "overworld")),
		}
	return out


func restore_state(data: Dictionary) -> void:
	saplings.clear()
	for key: String in data:
		var parts := key.split(",")
		if parts.size() != 3 or not (data[key] is Dictionary):
			continue
		var entry: Dictionary = data[key]
		saplings[Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))] = {
			"species": String(entry.get("species", "")),
			"planted": int(entry.get("planted", 0)),
			"dimension": StringName(entry.get("dimension", "overworld")),
		}

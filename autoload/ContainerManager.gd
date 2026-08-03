extends Node
## Coffres — conteneurs posés dans le monde (GDD F.6 : « Coffre, stockage 30
## slots · Grand coffre, 60 ») — 2026-08-03.
##
## MODÈLE, calqué sur ShopManager qui résout déjà le même problème : un état
## attaché à une POSITION DE BLOC, né à la pose et détruit à la casse, persisté
## à part du monde voxel. Le bloc lui-même reste un matériau ordinaire ; c'est
## ce dictionnaire qui lui donne un contenu.
##
## DIMENSION. Un donjon partage les coordonnées de l'overworld : sans ce champ,
## le coffre d'une salle de donjon serait ouvrable depuis la surface, à quelques
## blocs du spawn. Même piège que les caches au sol (DropManager) et les zones
## d'effet — il se paie deux fois avant qu'on l'apprenne.
##
## CASSER UN COFFRE REND SON CONTENU. C'est une rupture assumée avec l'étal, qui
## perd le sien : un étal est un commerce qu'on démonte, un coffre est un
## rangement. Perdre trente objets sur un coup de pioche mal placé serait une
## punition qu'aucune règle n'annonce.

## Capacité par matériau de coffre (F.6). Le nombre de LIGNES, pas d'unités :
## une pile de 64 pierres occupe un slot.
const CAPACITY := {"coffre": 30, "grand_coffre": 60}

## Coffres actifs : Vector3i → { "objects": Array[Dictionary],
##                               "materials": Dictionary, "gold": int,
##                               "dimension": StringName }
var chests := {}


func _ready() -> void:
	EventBus.block_placed.connect(_on_block_placed)
	EventBus.block_destroyed.connect(_on_block_destroyed)


## Un matériau est-il un coffre ? Par le TAG et non par une liste d'ids : ajouter
## un « coffre de voyage » en données suffira, sans toucher à ce fichier.
static func is_chest_material(material_id: String) -> bool:
	var mat: Dictionary = GameData.materials.get(material_id, {})
	return "conteneur" in (mat.get("tags", []) as Array)


func _on_block_placed(pos: Vector3i, material_id: int) -> void:
	if material_id <= 0 or material_id >= GameData.material_by_runtime.size():
		return
	var name: String = GameData.material_by_runtime[material_id]
	if not is_chest_material(name) or chests.has(pos):
		return
	chests[pos] = {
		"objects": [] as Array[Dictionary],
		"materials": {},
		"gold": 0,
		"dimension": WorldManager.active_dimension,
		"material": name,
	}


## Casser un coffre RECRACHE son contenu au sol plutôt que de le détruire.
## Passe par DropManager : le butin au sol existe déjà, en refaire une variante
## ici garantirait qu'elle diverge.
func _on_block_destroyed(pos: Vector3i, _material_id: int) -> void:
	if not chests.has(pos):
		return
	var chest: Dictionary = chests[pos]
	chests.erase(pos)
	var objects: Array = chest["objects"]
	var materials: Dictionary = chest["materials"]
	var gold := int(chest["gold"])
	if objects.is_empty() and materials.is_empty() and gold <= 0:
		return
	var centre := Vector3(pos) + Vector3(0.5, 0.5, 0.5)
	if not objects.is_empty() or gold > 0:
		DropManager.drop(centre, objects, gold)
	if not materials.is_empty():
		DropManager.drop_materials(centre, materials)


func is_chest(pos: Vector3i) -> bool:
	return chests.has(pos) \
			and StringName((chests[pos] as Dictionary).get("dimension", &"overworld")) == WorldManager.active_dimension


## Contenu d'un coffre ({} si absent ou d'une autre dimension).
func contents(pos: Vector3i) -> Dictionary:
	return chests[pos] if is_chest(pos) else {}


## Lignes occupées / capacité. Sert à l'interface ET au refus de dépôt : un
## coffre plein doit se voir avant qu'on essaie d'y ranger quelque chose.
func usage(pos: Vector3i) -> Vector2i:
	var chest := contents(pos)
	if chest.is_empty():
		return Vector2i.ZERO
	var used: int = (chest["objects"] as Array).size() + (chest["materials"] as Dictionary).size()
	return Vector2i(used, int(CAPACITY.get(String(chest.get("material", "coffre")), 30)))


## Pose un contenu D'AUTORITÉ, sans passer par la pose de bloc — c'est ainsi
## que le coffre de boss d'un donjon est garni (DungeonManager). Crée l'entrée
## si le bloc vient d'être écrit sans passer par `EventBus.block_placed`.
func fill(pos: Vector3i, material_name: String, objects: Array, gold: int = 0) -> void:
	var typed: Array[Dictionary] = []
	for obj: Variant in objects:
		if obj is Dictionary:
			typed.append(obj)
	chests[pos] = {
		"objects": typed,
		"materials": {},
		"gold": gold,
		"dimension": WorldManager.active_dimension,
		"material": material_name,
	}


## Vide tout le coffre dans l'inventaire fourni et retourne l'or récupéré.
## L'appelant crédite l'or (le porte-monnaie vit sur le joueur, pas ici).
func take_all(pos: Vector3i, inventory: Inventory) -> int:
	var chest := contents(pos)
	if chest.is_empty():
		return 0
	for obj: Dictionary in (chest["objects"] as Array):
		inventory.add_object(obj)
	for material_id: String in (chest["materials"] as Dictionary):
		inventory.add_material(material_id, int(chest["materials"][material_id]))
	var gold := int(chest["gold"])
	chest["objects"] = [] as Array[Dictionary]
	chest["materials"] = {}
	chest["gold"] = 0
	return gold


## Dépose UN objet dans le coffre. Retourne false si le coffre est plein — le
## refus est explicite plutôt que silencieux, l'objet ne doit jamais disparaître
## entre deux inventaires.
func store_object(pos: Vector3i, obj: Dictionary) -> bool:
	var chest := contents(pos)
	if chest.is_empty():
		return false
	var use := usage(pos)
	if use.x >= use.y:
		return false
	(chest["objects"] as Array).append(obj)
	return true


## Dépose des unités d'un matériau. Une pile existante ne consomme pas de ligne
## supplémentaire — c'est la règle qui rend les 30 slots utilisables.
func store_material(pos: Vector3i, material_id: String, count: int) -> bool:
	var chest := contents(pos)
	if chest.is_empty() or count <= 0:
		return false
	var materials: Dictionary = chest["materials"]
	if not materials.has(material_id):
		var use := usage(pos)
		if use.x >= use.y:
			return false
	materials[material_id] = int(materials.get(material_id, 0)) + count
	return true


# --- Sauvegarde (E.10, via SaveManager) ---

func save_state() -> Dictionary:
	var out := {}
	for pos: Vector3i in chests:
		var chest: Dictionary = chests[pos]
		out["%d,%d,%d" % [pos.x, pos.y, pos.z]] = {
			"objects": (chest["objects"] as Array).duplicate(true),
			"materials": (chest["materials"] as Dictionary).duplicate(),
			"gold": int(chest["gold"]),
			"dimension": String(chest.get("dimension", "overworld")),
			"material": String(chest.get("material", "coffre")),
		}
	return out


func restore_state(data: Dictionary) -> void:
	chests.clear()
	for key: String in data:
		var parts := key.split(",")
		if parts.size() != 3 or not (data[key] is Dictionary):
			continue
		var chest: Dictionary = data[key]
		var typed: Array[Dictionary] = []
		for obj: Variant in (chest.get("objects", []) as Array):
			if obj is Dictionary:
				typed.append(obj)
		chests[Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))] = {
			"objects": typed,
			"materials": (chest.get("materials", {}) as Dictionary).duplicate(),
			"gold": int(chest.get("gold", 0)),
			"dimension": StringName(chest.get("dimension", "overworld")),
			"material": String(chest.get("material", "coffre")),
		}

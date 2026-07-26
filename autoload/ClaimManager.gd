extends Node
## ClaimManager — cases revendiquées par le joueur (3.3). Persistant via
## SaveManager (E.10, state.json) depuis le 2026-07-21.
## Cellule = case de la carte du monde, 128×128 blocs (3.2) : Vector2i en
## coordonnées CELLULE, pas bloc ni chunk (cell = floor(bloc / CELL_SIZE)).

const CELL_SIZE := 128
const ROLES: Array[String] = ["base", "habitation", "champs", "ressources_naturelles"]

## Vector2i (cellule) -> String (rôle, un des ROLES).
var claims := {}


static func cell_of_block(wx: int, wz: int) -> Vector2i:
	return Vector2i(floori(float(wx) / CELL_SIZE), floori(float(wz) / CELL_SIZE))


func is_claimed(cell: Vector2i) -> bool:
	return claims.has(cell)


func role_of(cell: Vector2i) -> String:
	return String(claims.get(cell, ""))


## Revendique une cellule (rôle "base" par défaut). Retourne false si déjà
## revendiquée, ou si la cellule est occupée par un donjon actif (3.3 :
## « tant qu'un donjon occupe une cellule, celle-ci n'est ni claimable ni
## zonable » — elle le redevient après le nettoyage + délai, DungeonManager).
func claim(cell: Vector2i) -> bool:
	if claims.has(cell):
		return false
	if DungeonManager.is_dungeon_cell(cell):
		EventBus.ui_notification.emit("ui.toast.cellule_donjon")
		return false
	claims[cell] = "base"
	EventBus.cell_role_changed.emit(cell, "base")
	return true


func unclaim(cell: Vector2i) -> bool:
	if not claims.has(cell):
		return false
	claims.erase(cell)
	EventBus.cell_role_changed.emit(cell, "")
	return true


## Cycle vers le rôle suivant (3.3 : le joueur peut changer de rôle librement).
## Retourne le nouveau rôle, ou "" si la cellule n'est pas revendiquée.
func cycle_role(cell: Vector2i) -> String:
	if not claims.has(cell):
		return ""
	var next := ROLES[(ROLES.find(claims[cell]) + 1) % ROLES.size()]
	claims[cell] = next
	EventBus.cell_role_changed.emit(cell, next)
	return next


# --- Sauvegarde (E.10, via SaveManager) ---

## Clés JSON = "x,z" (un Vector2i ne survit pas à JSON.stringify).
func save_state() -> Dictionary:
	var out := {}
	for cell: Vector2i in claims:
		out["%d,%d" % [cell.x, cell.y]] = claims[cell]
	return out


func restore_state(data: Dictionary) -> void:
	claims.clear()
	for key: String in data:
		var parts := key.split(",")
		if parts.size() == 2:
			claims[Vector2i(int(parts[0]), int(parts[1]))] = String(data[key])

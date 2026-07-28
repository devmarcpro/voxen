extends Node
## Boutique passive (7.1/A.8/E.8, GDD étape 9 : « le reste par itérations »
## après le MVP D.3.1-8). Un étal de vente (matériau `etal_de_vente`, posé
## comme un bloc via le hotbar) devient une boutique dès qu'il est placé.
##
## SIMPLIFICATION ASSUMÉE ET SIGNALÉE : E.8 prévoit un trafic client dérivé
## d'une VRAIE population de PNJ locale + réputation + accessibilité par
## route — RIEN de tout ça n'existe encore dans le jeu (aucun PNJ marchand/
## villageois, aucun système de réputation 7.2, aucune génération de route).
## Le trafic est donc simulé de façon ABSTRAITE (constante fixe), cohérent
## avec E.10 qui range déjà les boutiques parmi les « états abstraits hors-
## site ». Pas de portefeuille PNJ fini (A.8.1) : l'or est traité comme
## infini côté acheteurs. Pas de troc, pas de prix ajustable par le joueur
## (toujours au prix suggéré A.8, calculé à la pose) — juste des matériaux
## bruts (pas d'objets craftés/qualité variable dans l'étal pour l'instant).

const SALE_INTERVAL_TICKS := 1000   # 1 heure in-game (24 000 ticks/jour ÷ 24, E.1).
const CLIENTS_PER_INTERVAL := 2     # Trafic ABSTRAIT — pas de vraie population de PNJ (E.8, hors scope).
const MAX_SLOTS := 12               # F.6 : étal de vente, 12 slots.
const PRICE_MARGIN := 1.5           # A.8 : marge d'artisanat.
const REPUTATION_FACTOR := 1.0      # Pas de réputation locale (7.2 hors scope) — neutre.

## Vector3i (position du bloc étal) -> { "slots": Array[{material_id, price}], "gold": int }.
var _stalls := {}
var _tick_accum := 0


func _ready() -> void:
	EventBus.block_placed.connect(_on_block_placed)
	EventBus.block_destroyed.connect(_on_block_destroyed)
	TickManager.tick_world.connect(_on_tick)


func _on_block_placed(pos: Vector3i, material_id: int) -> void:
	var etal_id: int = GameData.material_runtime_ids.get("etal_de_vente", -1)
	if etal_id != -1 and material_id == etal_id and not _stalls.has(pos):
		_stalls[pos] = {"slots": [], "gold": 0}


## Casser l'étal perd le stock/or restant — simplification assumée (pas de
## récupération de secours à la casse, cohérent avec la règle générale de
## minage : casser un contenant ne préserve pas son contenu ailleurs dans ce projet).
func _on_block_destroyed(pos: Vector3i, _material_id: int) -> void:
	_stalls.erase(pos)


func is_stall(pos: Vector3i) -> bool:
	return _stalls.has(pos)


## Prix suggéré (A.8) pour un matériau BRUT (qualité 1.0 implicite — pas
## d'objet crafté dans l'étal pour cette passe).
static func suggested_price(material_id: String) -> int:
	var mat: Dictionary = GameData.stackable(material_id)
	var valeur_base: float = float((mat.get("stats", {}) as Dictionary).get("valeur_base", 1.0))
	var facteur_reputation := clampf(1.0 + (0.0 / 200.0), 0.5, 2.0) * REPUTATION_FACTOR
	return maxi(1, int(round(valeur_base * PRICE_MARGIN * facteur_reputation)))


## Dépose 1 unité de `material_id` (retirée de `inventory`) dans l'étal
## `stall_pos`, au prix suggéré. false si étal introuvable/plein/inventaire
## insuffisant (rien n'est retiré dans ce cas).
func stock_item(stall_pos: Vector3i, material_id: String, inventory: Inventory) -> bool:
	if not _stalls.has(stall_pos):
		return false
	var stall: Dictionary = _stalls[stall_pos]
	var slots: Array = stall["slots"]
	if slots.size() >= MAX_SLOTS:
		return false
	if not inventory.remove_material(material_id, 1):
		return false
	slots.append({"material_id": material_id, "price": suggested_price(material_id)})
	return true


## Récolte l'or accumulé dans l'étal visé (remis à zéro). 0 si étal introuvable.
func collect_gold(stall_pos: Vector3i) -> int:
	if not _stalls.has(stall_pos):
		return 0
	var stall: Dictionary = _stalls[stall_pos]
	var amount: int = stall["gold"]
	stall["gold"] = 0
	return amount


func _on_tick(_tick_index: int) -> void:
	_tick_accum += 1
	if _tick_accum < SALE_INTERVAL_TICKS:
		return
	_tick_accum = 0
	for pos: Vector3i in _stalls:
		_simulate_sales(pos)


# --- Sauvegarde (E.10, via SaveManager) ---

## Clés JSON = "x,y,z" (position du bloc étal).
func save_state() -> Dictionary:
	var out := {}
	for pos: Vector3i in _stalls:
		var stall: Dictionary = _stalls[pos]
		out["%d,%d,%d" % [pos.x, pos.y, pos.z]] = {
			"slots": (stall["slots"] as Array).duplicate(true),
			"gold": int(stall["gold"]),
		}
	return out


func restore_state(data: Dictionary) -> void:
	_stalls.clear()
	for key: String in data:
		var parts := key.split(",")
		if parts.size() != 3 or not (data[key] is Dictionary):
			continue
		var stall: Dictionary = data[key]
		_stalls[Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))] = {
			"slots": stall.get("slots", []),
			"gold": int(stall.get("gold", 0)),
		}


## Un client potentiel tire un slot occupé au hasard et l'achète si le prix
## affiché passe le test d'acceptation (A.8 : prix_affiché <= prix_suggéré *
## random(0.9, 1.3) — vendre trop cher ralentit les ventes sans les bloquer).
func _simulate_sales(pos: Vector3i) -> void:
	var stall: Dictionary = _stalls[pos]
	var slots: Array = stall["slots"]
	for i in CLIENTS_PER_INTERVAL:
		if slots.is_empty():
			break
		var idx := randi() % slots.size()
		var slot: Dictionary = slots[idx]
		var threshold := float(suggested_price(slot["material_id"])) * randf_range(0.9, 1.3)
		if float(slot["price"]) <= threshold:
			slots.remove_at(idx)
			stall["gold"] = int(stall["gold"]) + int(slot["price"])
			EventBus.item_sold.emit(slot["material_id"], slot["price"], pos, null)

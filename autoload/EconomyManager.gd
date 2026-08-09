extends Node
## EconomyManager — l'économie des PNJ (GDD A.8 / A.8.1, 2026-08-09).
##
## ---------------------------------------------------------------------------
## CE QUE CE FICHIER TIENT, ET POURQUOI MAINTENANT
## ---------------------------------------------------------------------------
## Les villages ont désormais des bâtiments de service HABITÉS (marchand,
## taverne, forge, temple, casino, guilde). Sans économie, ce sont des façades :
## un marchand qui ne vend rien est un villageois avec un titre. Ce manager
## porte les trois briques que le GDD spécifie :
##
##   1. LES PORTEFEUILLES PNJ (A.8.1) — « tout PNJ a un stock d'or maximal
##      selon son métier, qui se recharge lentement (cadence hebdomadaire) ».
##      Un marchand à sec REFUSE d'acheter en or et propose un TROC.
##   2. LES PRIX (A.8) — valeur matériaux × 1.5 × qualité × réputation. La
##      formule vit déjà dans ShopManager.suggested_price ; on la RÉUTILISE,
##      on ne la recopie pas.
##   3. LE STOCK DES MARCHANDS — dérivé du monde (graine + cellule + semaine),
##      jamais stocké : le restock hebdomadaire est GRATUIT par construction,
##      puisque la graine change avec la semaine.
##
## CE QUI EST PERSISTÉ : l'or des portefeuilles entamés et les achats de la
## semaine en cours — c'est-à-dire uniquement les ÉCARTS au monde dérivé.
## Un portefeuille jamais touché n'existe pas en mémoire.
##
## MULTIJOUEUR : l'or d'un PNJ est un état PARTAGÉ (deux joueurs peuvent vider
## le même marchand) — mutations chez l'hôte, diffusées, comme les coffres.
## L'or du JOUEUR est local à chaque pair : chacun est l'autorité de sa bourse.

## Bases de portefeuille par métier (A.8.1). Le GDD en fixe quatre : villageois
## 30, marchand 300, maître de guilde 2000, roi 15000. Les autres sont
## INTERPOLÉS en attendant un barème officiel — déclarés ici, pas éparpillés.
const WALLET_BASE := {
	"marchand": 300,
	"forgeron": 200,
	"tavernier": 120,
	"pretre": 80,
	"maitre_guilde": 2000,
	# LA MAISON DE JEU. Le croupier ne joue pas son argent de poche : son
	# portefeuille EST la caisse du casino, et c'est elle que le joueur peut
	# faire sauter. Dimensionnée pour survivre à une bonne soirée, pas à un
	# joueur chanceux qui s'acharne.
	"croupier": 1000,
	"souverain": 15000,
}
const WALLET_DEFAULT := 30  # villageois/client (A.8.1)

## Recharge hebdomadaire : +15 % du plafond (A.8.1, même horloge que la
## corruption E.20 — la semaine de VillageManager).
const WEEKLY_RECHARGE := 0.15

## Marge de rachat : un marchand achète sous la valeur A.8, sinon acheter puis
## revendre au même prix serait une machine à or gratuite. Réglage assumé, le
## GDD ne fixe pas ce taux.
const BUYBACK_RATIO := 0.6

## Tolérance du troc (A.8.1 : « objets ≈ valeur équivalente (±15 %) »).
const BARTER_TOLERANCE := 0.15

## Taille du stock d'un marchand, par semaine.
const STOCK_LINES := 8
const SEED_STOCK := 77003

## key ("cx:cz:idx") -> {"gold": int, "week": int}. N'existe que pour les
## portefeuilles ENTAMÉS : le reste du monde se dérive.
var _wallets := {}
## key_semaine ("cx:cz:idx:w") -> {ligne: quantité achetée}. Vidé de fait par
## le changement de semaine (la clé change).
var _stock_taken := {}


func _wallet_key(cell: Vector2i, roster_index: int) -> String:
	return "%d:%d:%d" % [cell.x, cell.y, roster_index]


func _current_week() -> int:
	return TickManager.tick_index / VillageManager.WEEK_TICKS


## Plafond d'or d'un PNJ, selon son métier (A.8.1).
func wallet_max(role: String) -> int:
	return int(WALLET_BASE.get(role, WALLET_DEFAULT))


## Or DISPONIBLE d'un PNJ, recharge hebdomadaire comprise. La recharge est
## calculée PARESSEUSEMENT à la lecture : aucun coût par tick, et un
## portefeuille jamais consulté ne coûte rien du tout.
func wallet_gold(creature: Node) -> int:
	var key := _creature_key(creature)
	var cap := wallet_max(String((creature.identity as Dictionary).get("role", "")))
	if key == "" or not _wallets.has(key):
		return cap
	var entry: Dictionary = _wallets[key]
	var weeks := _current_week() - int(entry["week"])
	if weeks > 0:
		entry["gold"] = mini(cap, int(entry["gold"]) + int(ceil(cap * WEEKLY_RECHARGE)) * weeks)
		entry["week"] = _current_week()
	return int(entry["gold"])


## Débite (delta négatif) ou crédite le portefeuille d'un PNJ. AUTORITÉ SEULE :
## un client passe par NetworkManager.request_npc_wallet, l'hôte applique et
## diffuse — exactement le chemin des coffres.
func adjust_wallet(creature: Node, delta: int) -> void:
	var key := _creature_key(creature)
	if key == "":
		return
	var cap := wallet_max(String((creature.identity as Dictionary).get("role", "")))
	if NetworkManager.is_authority():
		var current := wallet_gold(creature)
		_wallets[key] = {"gold": clampi(current + delta, 0, cap), "week": _current_week()}
		if NetworkManager.has_peers():
			NetworkManager.rpc_npc_wallet.rpc(key, int(_wallets[key]["gold"]),
					int(_wallets[key]["week"]))
	else:
		NetworkManager.request_npc_wallet.rpc_id(1, key, delta, cap)


## Application distante (hôte -> clients), et requête entrante (client -> hôte).
func apply_remote_wallet(key: String, gold: int, week: int) -> void:
	_wallets[key] = {"gold": gold, "week": week}


func apply_wallet_request(key: String, delta: int, cap: int) -> void:
	var current := cap
	if _wallets.has(key):
		var entry: Dictionary = _wallets[key]
		var weeks := _current_week() - int(entry["week"])
		current = mini(cap, int(entry["gold"]) + int(ceil(cap * WEEKLY_RECHARGE)) * maxi(weeks, 0))
	_wallets[key] = {"gold": clampi(current + delta, 0, cap), "week": _current_week()}
	if NetworkManager.has_peers():
		NetworkManager.rpc_npc_wallet.rpc(key, int(_wallets[key]["gold"]),
				int(_wallets[key]["week"]))


func _creature_key(creature: Node) -> String:
	if int(creature.roster_index) < 0:
		return ""
	return _wallet_key(Vector2i(creature.village_cell), int(creature.roster_index))


# --- STOCK DES MARCHANDS ----------------------------------------------------

## Étal de la semaine d'un PNJ marchand : lignes {material_id, price, count}.
##
## DÉRIVÉ, JAMAIS STOCKÉ. La graine mélange la cellule, le rang au roster et la
## SEMAINE : le stock se renouvelle donc tout seul à la semaine (A.8.1, même
## horloge que la recharge des portefeuilles), sans aucun état à entretenir.
## Seuls les ACHATS de la semaine en cours sont retenus (_stock_taken), pour
## qu'un objet acheté ne se rachète pas à l'infini.
##
## LE STOCK VIENT DU LIEU. Un marchand vend ce que son biome produit (les
## matériaux de la palette du village, le bois local, la récolte des champs) ;
## le forgeron vend le métal et les outils. Un marchand générique qui vendrait
## la même liste partout casserait la seule raison de voyager entre villages.
func merchant_stock(creature: Node) -> Array:
	var key := _creature_key(creature)
	if key == "":
		return []
	var cell := Vector2i(creature.village_cell)
	var role := String((creature.identity as Dictionary).get("role", ""))
	var week := _current_week()
	var rng := RandomNumberGenerator.new()
	rng.seed = NoiseGenerator.pcg_hash(cell.x * 31 + int(creature.roster_index),
			cell.y, WorldManager.world_seed + SEED_STOCK + week)
	var pool := _stock_pool(cell, role)
	if pool.is_empty():
		return []
	var taken: Dictionary = _stock_taken.get("%s:%d" % [key, week], {})
	var out: Array = []
	for line in STOCK_LINES:
		var material_id := String(pool[rng.randi_range(0, pool.size() - 1)])
		var count := rng.randi_range(2, 8)
		var price := ShopManager.suggested_price(material_id)
		out.append({
			"material_id": material_id,
			"price": maxi(1, price),
			"count": maxi(0, count - int(taken.get(line, 0))),
			"line": line,
		})
	return out


## Matériaux qu'un métier vend ici. Tout vient des DONNÉES : la palette du
## village pour le marchand, les catégories minerai/lingot pour le forgeron.
func _stock_pool(cell: Vector2i, role: String) -> Array:
	var out: Array = []
	if role == "forgeron":
		for id: String in GameData.materials:
			var cat := String((GameData.materials[id] as Dictionary).get("category", ""))
			if cat == "minerai" or cat == "lingot":
				out.append(id)
		return out
	# Marchand généraliste : ce que le biome du village produit, plus les
	# denrées de base. `village_palette` désigne des matériaux réels — c'est la
	# même source que les murs du village, donc toujours cohérente avec le lieu.
	var layout: Dictionary = WorldManager.generator.city_at_cell(cell)
	for id: String in ["ble", "tubercule", "torche", "corde", "silex"]:
		if GameData.materials.has(id):
			out.append(id)
	if not layout.is_empty():
		var biome: Dictionary = WorldManager.generator.biome_at(
			cell.x * 128 + 64, cell.y * 128 + 64)
		for field: String in ["mur", "toit", "poutre", "culture", "tronc"]:
			var id := String((biome.get("village_palette", {}) as Dictionary).get(field, ""))
			if id != "" and GameData.materials.has(id):
				out.append(id)
	return out


## ACHAT d'une ligne de stock par le joueur local. Retourne true si la vente
## s'est faite : l'or du joueur bouge ici (il est local), l'or du PNJ part par
## le chemin d'autorité.
func buy_from_merchant(creature: Node, line: Dictionary, player: Node) -> bool:
	var price := int(line["price"])
	if int(line["count"]) <= 0 or player.gold < price:
		return false
	var key := _creature_key(creature)
	var week_key := "%s:%d" % [key, _current_week()]
	var taken: Dictionary = _stock_taken.get(week_key, {})
	taken[int(line["line"])] = int(taken.get(int(line["line"]), 0)) + 1
	_stock_taken[week_key] = taken
	if NetworkManager.is_authority() and NetworkManager.has_peers():
		NetworkManager.rpc_npc_stock.rpc(week_key, taken)
	elif not NetworkManager.is_authority():
		NetworkManager.request_npc_stock.rpc_id(1, week_key, int(line["line"]))
	player.gold -= price
	player.inventory.add_material(String(line["material_id"]), 1)
	adjust_wallet(creature, price)
	EventBus.item_sold.emit(String(line["material_id"]), price, creature, player)
	return true


## VENTE d'un matériau du joueur au PNJ. Trois issues, et l'appelant doit les
## distinguer : "vendu", "troc" (portefeuille à sec — A.8.1 exige la
## proposition, pas le refus sec), "refus" (rien à vendre).
func sell_to_merchant(creature: Node, material_id: String, player: Node) -> Dictionary:
	if player.inventory.material_stacks.get(material_id, 0) < 1:
		return {"issue": "refus"}
	var price := maxi(1, int(round(ShopManager.suggested_price(material_id) * BUYBACK_RATIO)))
	if wallet_gold(creature) < price:
		# TROC (A.8.1) : le marchand n'a plus d'or mais son étal a de la valeur.
		# On cherche une ligne de stock à ±15 % du prix demandé.
		for line: Dictionary in merchant_stock(creature):
			if int(line["count"]) <= 0:
				continue
			var value := int(line["price"])
			if absf(value - price) <= price * BARTER_TOLERANCE:
				return {"issue": "troc", "contre": line, "prix": price}
		return {"issue": "refus_sec"}
	player.inventory.remove_material(material_id, 1)
	player.gold += price
	adjust_wallet(creature, -price)
	EventBus.item_sold.emit(material_id, price, player, creature)
	return {"issue": "vendu", "prix": price}


## Le troc accepté : l'objet du joueur contre la ligne du marchand, sans or.
func barter_with_merchant(creature: Node, material_id: String, line: Dictionary,
		player: Node) -> bool:
	if player.inventory.material_stacks.get(material_id, 0) < 1 or int(line["count"]) <= 0:
		return false
	player.inventory.remove_material(material_id, 1)
	player.inventory.add_material(String(line["material_id"]), 1)
	var key := _creature_key(creature)
	var week_key := "%s:%d" % [key, _current_week()]
	var taken: Dictionary = _stock_taken.get(week_key, {})
	taken[int(line["line"])] = int(taken.get(int(line["line"]), 0)) + 1
	_stock_taken[week_key] = taken
	if NetworkManager.is_authority() and NetworkManager.has_peers():
		NetworkManager.rpc_npc_stock.rpc(week_key, taken)
	elif not NetworkManager.is_authority():
		NetworkManager.request_npc_stock.rpc_id(1, week_key, int(line["line"]))
	return true


func apply_remote_stock(week_key: String, taken: Dictionary) -> void:
	_stock_taken[week_key] = taken


func apply_stock_request(week_key: String, line: int) -> void:
	var taken: Dictionary = _stock_taken.get(week_key, {})
	taken[line] = int(taken.get(line, 0)) + 1
	_stock_taken[week_key] = taken
	if NetworkManager.has_peers():
		NetworkManager.rpc_npc_stock.rpc(week_key, taken)


# --- PERSISTANCE ------------------------------------------------------------

## Seuls les ÉCARTS au monde dérivé sont sauvés : portefeuilles entamés et
## achats de la semaine courante. Un monde jamais commercé sauve deux
## dictionnaires vides.
func save_state() -> Dictionary:
	return {"wallets": _wallets.duplicate(true), "stock_taken": _stock_taken.duplicate(true)}


func restore_state(state: Dictionary) -> void:
	_wallets = (state.get("wallets", {}) as Dictionary).duplicate(true)
	_stock_taken = (state.get("stock_taken", {}) as Dictionary).duplicate(true)


func reset() -> void:
	_wallets.clear()
	_stock_taken.clear()

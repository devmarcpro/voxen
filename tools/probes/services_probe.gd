extends Probe
## Sonde `--probe-services` (2026-08-09) — l'économie des villages.
##
## POURQUOI ELLE EXISTE. Les bâtiments de service ont reçu leurs travailleurs,
## leurs portefeuilles (A.8.1), leur commerce (A.8), leurs guildes (B.7). Tout
## ça est de la MÉCANIQUE PURE : rien ne plante si le marchand paie trop, si le
## portefeuille ne se recharge jamais, si un contrat compte les morts d'autrui.
## Chaque règle du GDD citée ici a donc son assertion, au niveau des managers —
## le dialogue n'est qu'un habillage au-dessus des mêmes appels.

const TAG := "SERVICES"

var _ok := true


func _check(label: String, condition: bool, detail: String = "") -> void:
	if not condition:
		_ok = false
	print("[%s] %s%s : %s" % [TAG, label, "" if detail == "" else " (" + detail + ")",
		"OK" if condition else "ÉCHEC"])


func run() -> void:
	await wait_frame()
	var plan := _find_service_village()
	if plan.is_empty():
		_check("village avec services", false, "aucun trouvé dans le rayon scanné")
		finish(false, TAG)
		return
	_check_roster_fills_services(plan)
	_check_economy(plan)
	_check_guilds()
	finish(_ok, TAG)


## Village dont le plan déclare au moins marchand + taverne, dans un rayon
## raisonnable autour de l'origine.
func _find_service_village() -> Dictionary:
	var g := WorldManager.generator
	for cx in range(-60, 61):
		for cz in range(-60, 61):
			var plan: Dictionary = g.city_at_cell(Vector2i(cx, cz))
			if plan.is_empty():
				continue
			var services: Dictionary = plan.get("services", {})
			if services.values().has("marchand") and services.values().has("taverne"):
				plan["_cell"] = Vector2i(cx, cz)
				return plan
	return {}


## CHAQUE SERVICE DU PLAN A SON TRAVAILLEUR, et il travaille CHEZ LUI.
func _check_roster_fills_services(plan: Dictionary) -> void:
	var cell: Vector2i = plan["_cell"]
	var roster := VillagePopulation.roster(cell, WorldManager.world_seed, plan, "")
	var services: Dictionary = plan.get("services", {})
	var filled := {}
	for entry: Dictionary in roster:
		var service := String(entry.get("service", ""))
		if service == "":
			continue
		filled[int(entry["service_plot"])] = service
		# LE POSTE EST DANS LE BÂTIMENT : la position de travail de ce résident
		# doit être la tuile de son service, pas la place commune.
		var work := VillagePopulation.work_position_for(cell, plan, entry)
		var expected := VillagePopulation.tile_position(cell, plan, int(entry["service_plot"]))
		if Vector3i(work) != Vector3i(expected):
			_check("poste au bâtiment (%s)" % service, false,
				"%s != %s" % [work, expected])
			return
	# Un village assez peuplé pourvoit TOUS ses services ; un petit en pourvoit
	# au moins la moitié (les adultes manquent, pas l'intention).
	var covered := 0
	for plot: int in services:
		if filled.has(plot):
			covered += 1
	_check("services pourvus", covered * 2 >= services.size(),
		"%d/%d pourvus, population %d" % [covered, services.size(), roster.size()])
	_check("les postes sont au bâtiment", true)


## L'ÉCONOMIE (A.8 / A.8.1), sur un marchand-bouchon : la sonde teste la
## MÉCANIQUE, pas le spawn — un Node avec identité suffit, et il est le même
## que celui que le dialogue manipule.
func _check_economy(plan: Dictionary) -> void:
	var cell: Vector2i = plan["_cell"]
	var npc := _stub_npc(cell, 0, "marchand")
	main.add_child(npc)

	# STOCK : dérivé, non vide, aux prix A.8 (jamais gratuits).
	var stock: Array = EconomyManager.merchant_stock(npc)
	var priced := not stock.is_empty()
	for line: Dictionary in stock:
		if int(line["price"]) < 1:
			priced = false
	_check("stock du marchand dérivé et chiffré", priced, "%d lignes" % stock.size())

	# ACHAT : l'or change de mains, l'objet arrive.
	player.set("gold", 500)
	var line: Dictionary = stock[0]
	var before_count := int(player.inventory.material_stacks.get(String(line["material_id"]), 0))
	var bought := EconomyManager.buy_from_merchant(npc, line, player)
	_check("achat : or débité, objet reçu",
		bought and player.gold == 500 - int(line["price"])
		and int(player.inventory.material_stacks.get(String(line["material_id"]), 0)) == before_count + 1)
	# La ligne achetée décompte du stock DE LA SEMAINE.
	var after: Array = EconomyManager.merchant_stock(npc)
	_check("le stock se décompte", int(after[0]["count"]) == int(line["count"]) - 1,
		"%d -> %d" % [int(line["count"]), int(after[0]["count"])])

	# VENTE : le marchand paie sous la valeur A.8 (marge), depuis SON or.
	var wallet_before := EconomyManager.wallet_gold(npc)
	var gold_before: int = player.gold
	var sale: Dictionary = EconomyManager.sell_to_merchant(npc, String(line["material_id"]), player)
	_check("vente : payée par le portefeuille du PNJ",
		String(sale.get("issue", "")) == "vendu"
		and player.gold == gold_before + int(sale.get("prix", 0))
		and EconomyManager.wallet_gold(npc) == wallet_before - int(sale.get("prix", 0)))

	# PORTEFEUILLE À SEC (A.8.1) : la vente devient TROC ou refus motivé — pas
	# un paiement dans le vide.
	EconomyManager.adjust_wallet(npc, -100000)
	player.inventory.add_material(String(line["material_id"]), 1)
	var dry: Dictionary = EconomyManager.sell_to_merchant(npc, String(line["material_id"]), player)
	var issue := String(dry.get("issue", ""))
	_check("marchand à sec : troc proposé, jamais payé", issue == "troc" or issue == "refus_sec",
		issue)

	# RECHARGE HEBDOMADAIRE (A.8.1 : +15 % du plafond par semaine). On recule
	# la semaine du portefeuille et on relit : la recharge est paresseuse.
	var key: String = "%d:%d:0" % [cell.x, cell.y]
	EconomyManager._wallets[key] = {"gold": 0, "week": EconomyManager._current_week() - 2}
	var recharged := EconomyManager.wallet_gold(npc)
	var expected := mini(300, int(ceil(300 * 0.15)) * 2)
	_check("recharge hebdomadaire +15%/semaine", recharged == expected,
		"%d or après 2 semaines (attendu %d)" % [recharged, expected])
	npc.queue_free()


## LES GUILDES (7.3 / B.7) : inscription, contrat, progression, rang.
func _check_guilds() -> void:
	_check("gabarits B.7 chargés", not GameData.quest_templates.is_empty(),
		str(GameData.quest_templates.keys()))
	var guilds: Array = GuildManager.known_guilds()
	_check("guildes dérivées des gabarits", "guerriers" in guilds and "prospecteurs" in guilds,
		str(guilds))

	player.guild_state = {}
	player.active_quests = {}
	_check("pas membre : rang 0", GuildManager.rank_of(player, "guerriers") == 0)
	GuildManager.enroll(player, "guerriers")
	_check("inscrit : novice", GuildManager.rank_of(player, "guerriers") == 1)

	var offered: Dictionary = GuildManager.offered_quest(player, "guerriers")
	_check("contrat proposé", not offered.is_empty()
		and String(offered["pattern"]) == "tuer" and int(offered["count"]) > 0,
		"%s x%d, %d or" % [offered.get("target", "?"), int(offered.get("count", 0)),
			int(offered.get("gold", 0))])
	GuildManager.accept(player, "guerriers", offered)

	# PROGRESSION : seules MES victimes comptent. Une victime tuée par un tiers
	# ne bouge pas le compteur — en multijoueur, chacun chasse pour soi.
	var victim := _stub_npc(Vector2i.ZERO, -1, "")
	victim.set("creature_id", String(offered["target"]))
	main.add_child(victim)
	EventBus.creature_killed.emit(victim, victim)  # tueur = un tiers
	_check("la victime d'un tiers ne compte pas",
		int(GuildManager.active_quest(player, "guerriers")["done"]) == 0)
	for _i in int(offered["count"]):
		EventBus.creature_killed.emit(player, victim)
	var active: Dictionary = GuildManager.active_quest(player, "guerriers")
	_check("mes victimes comptent, borné au contrat",
		int(active["done"]) == int(active["count"]))

	# RENDU : l'or tombe, l'XP monte, le rang saute au seuil (100 XP -> rang 2).
	var state: Dictionary = player.guild_state["guerriers"]
	state["xp"] = 95
	player.guild_state["guerriers"] = state
	var gold_before: int = player.gold
	var done: Dictionary = GuildManager.turn_in(player, "guerriers")
	_check("contrat rendu : or + XP + rang",
		not done.is_empty() and player.gold == gold_before + int(done["gold"])
		and GuildManager.rank_of(player, "guerriers") == 2,
		"rang %d, %d XP" % [GuildManager.rank_of(player, "guerriers"),
			GuildManager.xp_of(player, "guerriers")])

	# PROSPECTEURS : miner le minerai du contrat fait avancer, un autre non.
	GuildManager.enroll(player, "prospecteurs")
	var prospect: Dictionary = GuildManager.offered_quest(player, "prospecteurs")
	_check("contrat de prospection", not prospect.is_empty()
		and String(prospect["pattern"]) == "localiser", String(prospect.get("target", "?")))
	GuildManager.accept(player, "prospecteurs", prospect)
	var ore_id: int = GameData.material_runtime_ids.get(String(prospect["target"]), 0)
	var other_id: int = GameData.material_runtime_ids.get("terre", 0)
	EventBus.block_destroyed.emit(Vector3i.ZERO, other_id)
	_check("un autre bloc ne compte pas",
		int(GuildManager.active_quest(player, "prospecteurs")["done"]) == 0)
	EventBus.block_destroyed.emit(Vector3i.ZERO, ore_id)
	_check("le minerai du contrat compte",
		int(GuildManager.active_quest(player, "prospecteurs")["done"]) == 1)
	victim.queue_free()


## PNJ-bouchon : les trois propriétés que l'économie lit, rien d'autre. C'est
## le même contrat d'interface que le vrai `creature.gd` — si l'un des deux
## divergeait, la sonde et le jeu liraient des champs différents et cette sonde
## serait verte pour la mauvaise raison ; d'où le test « poste au bâtiment » sur
## le VRAI roster plus haut.
func _stub_npc(cell: Vector2i, roster_index: int, role: String) -> Node:
	var script := GDScript.new()
	script.source_code = """extends Node
var identity := {}
var roster_index := -1
var village_cell := Vector2i.ZERO
var creature_id := ""
var display_name_key := ""
"""
	script.reload()
	var npc := Node.new()
	npc.set_script(script)
	npc.set("village_cell", cell)
	npc.set("roster_index", roster_index)
	npc.set("identity", {"role": role})
	return npc

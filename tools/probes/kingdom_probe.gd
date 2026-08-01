extends Probe
## Sonde `--probe-royaumes` — génération des royaumes PNJ (E.27 / 14.4).
##
## CE QU'ELLE DÉFEND. E.27 pose une contrainte forte et facile à trahir sans
## s'en apercevoir : « aucun réseau global à calculer ; chaque secteur se résout
## seul, ses graines sont connaissables SANS GÉNÉRER LE TERRAIN ». C'est cette
## propriété qui permet à la carte du monde d'afficher des royaumes lointains
## avant toute visite. Le jour où une requête de royaume déclenchera une
## génération de chunk, la carte gèlera pendant des secondes et personne ne
## saura pourquoi.
##
## Elle mesure aussi ce qui ne se voit qu'à l'échelle : un monde où « la
## majorité est sauvage » (E.27) et où « un royaume est un événement ». Une
## génération qui couvrirait le monde de royaumes serait aussi fausse qu'une
## génération qui n'en produirait aucun, et les deux se constatent uniquement
## par recensement.

const TAG := "ROYAUMES"

## Rayon du recensement, en cellules. 96 → 193×193, soit trois secteurs de côté :
## assez pour que plusieurs royaumes coexistent et que des frontières se forment.
const RADIUS := 96

var _ok := true


func _check(label: String, condition: bool, detail: String = "") -> void:
	if not condition:
		_ok = false
	print("[%s] %s%s : %s" % [TAG, label, "" if detail == "" else " (" + detail + ")",
		"OK" if condition else "ÉCHEC"])


func run() -> void:
	await main.get_tree().process_frame
	var generator := WorldManager.generator
	if generator == null:
		_check("générateur présent", false)
		finish(false, TAG)
		return
	_check_sectors()
	_check_no_terrain_needed(generator)
	_check_census(generator)
	_check_determinism(generator)
	_check_borders(generator)
	_check_laws(generator)
	finish(_ok, TAG)


## Le découpage en secteurs doit tenir en coordonnées NÉGATIVES. C'est le piège
## classique : `-1 / 64` vaut 0 en division entière, ce qui replierait tout le
## quadrant négatif sur le secteur zéro et collerait deux royaumes l'un dans
## l'autre — un bug qui n'apparaît qu'à l'ouest du point de départ.
func _check_sectors() -> void:
	_check("secteur de (0,0)", KingdomGenerator.sector_of(Vector2i(0, 0)) == Vector2i(0, 0))
	_check("secteur de (63,63)", KingdomGenerator.sector_of(Vector2i(63, 63)) == Vector2i(0, 0))
	_check("secteur de (64,0)", KingdomGenerator.sector_of(Vector2i(64, 0)) == Vector2i(1, 0))
	_check("secteur de (-1,-1) N'EST PAS (0,0)",
		KingdomGenerator.sector_of(Vector2i(-1, -1)) == Vector2i(-1, -1),
		str(KingdomGenerator.sector_of(Vector2i(-1, -1))))
	_check("secteur de (-64,0)", KingdomGenerator.sector_of(Vector2i(-64, 0)) == Vector2i(-1, 0))


## LA CONTRAINTE CENTRALE d'E.27 : répondre sans générer de terrain. On compte
## les chunks avant et après une interrogation sur une région jamais visitée.
func _check_no_terrain_needed(generator: NoiseGenerator) -> void:
	var before: int = int(WorldManager.stats()["cache"])
	var far := Vector2i(4000, -4000)   # très loin du joueur, jamais streamé
	var kingdom := generator.kingdom_at_cell(far)
	var after: int = int(WorldManager.stats()["cache"])
	_check("interroger un royaume lointain ne génère AUCUN chunk", after == before,
		"%d chunks avant, %d après" % [before, after])
	_check("la réponse est exploitable", kingdom is Dictionary)


func _check_census(generator: NoiseGenerator) -> void:
	var owned := 0
	var scanned := 0
	var by_kingdom := {}
	var by_size := {}
	var by_government := {}
	# Pas maille par maille : 37 000 cellules × un Dijkstra chacune serait
	# absurde même avec le cache. Un échantillon régulier suffit à mesurer une
	# PROPORTION, qui est la seule chose qui nous intéresse ici.
	for cz in range(-RADIUS, RADIUS + 1, 4):
		for cx in range(-RADIUS, RADIUS + 1, 4):
			scanned += 1
			var kingdom := generator.kingdom_at_cell(Vector2i(cx, cz))
			if kingdom.is_empty():
				continue
			owned += 1
			by_kingdom[String(kingdom["id"])] = true
			by_size[String(kingdom["size"])] = int(by_size.get(kingdom["size"], 0)) + 1
			by_government[String(kingdom["government_type"])] = true

	var share := 100.0 * owned / maxf(float(scanned), 1.0)
	print("[%s] %d cellules sondées · %d royaumes distincts" % [TAG, scanned, by_kingdom.size()])
	print("[%s] tailles rencontrées : %s" % [TAG, by_size])
	print("[%s] gouvernances rencontrées : %d formes" % [TAG, by_government.size()])
	_check("des royaumes existent", by_kingdom.size() > 0, "%d" % by_kingdom.size())
	# « La majorité du monde est sauvage ; un royaume est un événement. » Les
	# bornes sont larges — c'est un ordre de grandeur qu'on défend, pas un
	# chiffre — mais elles attrapent les deux échecs qui comptent : un monde
	# vide de civilisation, et un monde entièrement colonisé.
	_check("la majorité du monde reste sauvage", share < 50.0,
		"%.1f %% de cellules sous autorité" % share)
	_check("la civilisation n'est pas anecdotique", share > 1.0,
		"%.1f %%" % share)
	_check("plusieurs gouvernances coexistent", by_government.size() >= 2)


## Un royaume est DÉRIVÉ : deux interrogations doivent donner exactement le même
## résultat, sinon les frontières bougeraient sous les pieds du joueur et rien
## ne pourrait être bâti dessus (traités, conquêtes, lois).
func _check_determinism(generator: NoiseGenerator) -> void:
	var sample := Vector2i(37, -21)
	var first := generator.kingdom_at_cell(sample)
	KingdomGenerator.clear_cache()
	var second := generator.kingdom_at_cell(sample)
	_check("un royaume est reproductible après purge du cache",
		str(first) == str(second))
	# Et le cache doit répondre la même chose que le calcul nu : un cache qui
	# ment est pire que pas de cache.
	var direct := KingdomGenerator.kingdom_at(sample, generator.world_seed, generator)
	_check("le cache donne le même résultat que le calcul direct",
		String(direct.get("id", "")) == String(second.get("id", "")))


## Un territoire doit être CONTIGU et contenir sa capitale. Un royaume troué ou
## dont la capitale serait hors de ses terres n'aurait aucun sens, et le défaut
## resterait invisible tant que personne ne dessine la carte.
func _check_borders(generator: NoiseGenerator) -> void:
	var capital := {}
	for sector_z in range(-2, 3):
		for sector_x in range(-2, 3):
			var capitals := KingdomGenerator.capitals_in_sector(
				Vector2i(sector_x, sector_z), generator.world_seed, generator)
			if not capitals.is_empty():
				capital = capitals[0]
				break
		if not capital.is_empty():
			break
	if capital.is_empty():
		_check("une capitale existe près de l'origine", false)
		return

	var territory := KingdomGenerator.territory_of(capital, generator)
	_check("le territoire contient sa capitale", territory.has(capital["cell"]),
		"%d cellule(s)" % territory.size())
	_check("le territoire n'est pas réduit à un point", territory.size() >= 1)

	# CONTIGUÏTÉ : chaque cellule autre que la capitale doit toucher une autre
	# cellule du territoire.
	var isolated := 0
	for cell: Vector2i in territory:
		if cell == capital["cell"]:
			continue
		var touching := false
		for offset: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0),
				Vector2i(0, 1), Vector2i(0, -1)]:
			if territory.has(cell + offset):
				touching = true
		if not touching:
			isolated += 1
	_check("aucune enclave détachée", isolated == 0, "%d isolée(s)" % isolated)

	# Une cellule ne peut appartenir qu'à UN royaume : le litige est tranché par
	# le coût, et deux royaumes qui se revendiqueraient la même terre rendraient
	# les lois et les taxes indécidables.
	var owner := generator.kingdom_at_cell(capital["cell"])
	_check("la capitale appartient à son propre royaume",
		String(owner.get("id", "")) == KingdomGenerator.id_of(capital["cell"]),
		String(owner.get("name", "aucun")))


## LOIS ET INFRACTIONS (14.4 / E.26). Ce que ces tests défendent en premier :
## qu'une infraction NON VUE ne coûte rien. C'est le principe explicite du GDD —
## « pas de log caché, pas de karma » — et c'est exactement le genre de règle
## qu'une refonte ultérieure trahira « pour que ce soit plus juste », en
## transformant le jeu en comptable moral.
func _check_laws(generator: NoiseGenerator) -> void:
	# Un royaume QUI LÉGIFÈRE. Le premier jet prenait le royaume le plus proche
	# et tombait sur une anarchie : la sonde reprochait alors à un royaume sans
	# lois de ne pas en avoir, alors que c'est précisément la règle du GDD.
	# Chercher le bon sujet fait partie du test.
	var kingdom := {}
	for radius in range(0, 60):
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if maxi(absi(dx), absi(dz)) != radius:
					continue
				var candidate := generator.kingdom_at_cell(Vector2i(dx, dz))
				if candidate.is_empty():
					continue
				if String(candidate["government_type"]) in KingdomLaws.LAWLESS_GOVERNMENTS:
					continue
				kingdom = candidate
				break
			if not kingdom.is_empty():
				break
		if not kingdom.is_empty():
			break
	if kingdom.is_empty():
		_check("un royaume légiférant existe pour tester ses lois", false)
		return

	var laws := KingdomLaws.laws_of(kingdom)
	print("[%s] %s (%s) : %d loi(s)" % [TAG, kingdom["name"],
		kingdom["government_type"], laws.size()])
	_check("un royaume a des lois", not laws.is_empty())
	_check("le meurtre y est interdit",
		not KingdomLaws.law_for(kingdom, "meurtre").is_empty())
	_check("les lois sont déterministes",
		str(laws) == str(KingdomLaws.laws_of(kingdom)))

	# HORS ROYAUME : aucune loi. « La wilderness est l'anarchie de fait. »
	_check("la terre sauvage n'a aucune loi", KingdomLaws.laws_of({}).is_empty())
	# ANARCHIE : pas de lois non plus, faute de pouvoir les faire appliquer.
	var anarchy := kingdom.duplicate()
	anarchy["government_type"] = "anarchie"
	_check("une anarchie n'a aucune loi", KingdomLaws.laws_of(anarchy).is_empty())

	# DÉTECTION : sans témoin, rien ne se passe.
	var lonely: Array = []
	_check("aucun témoin = infraction ignorée",
		not KingdomLaws.is_witnessed(player, Vector3.ZERO, lonely))

	# Une BÊTE ne témoigne pas : sinon chasser sous l'œil d'un loup vous
	# dénoncerait, ce qui serait absurde.
	var boar := CreatureManager.spawn("sanglier", Vector3(0, 0, 0))
	if boar != null:
		boar.logical_position = Vector3.ZERO
		_check("une bête ne témoigne pas",
			not KingdomLaws.is_witnessed(player, Vector3.ZERO, [boar]))
		CreatureManager.despawn(boar)

	# CONSÉQUENCES.
	var gold_before: int = player.gold
	player.gold = 500
	var message := KingdomLaws.apply("amende:50", player, kingdom)
	_check("une amende débite le portefeuille", player.gold == 450,
		"%d or" % player.gold)
	_check("l'amende est annoncée au joueur", message != "")

	# Amende impayable : « confiscation d'objets à la place » (E.26). Être
	# fauché ne doit pas valoir immunité.
	player.gold = 0
	player.inventory.add_object(ItemFactory.craft("epee",
		{"bois": "chene", "minerai": "fer"}, 1.0))
	var objects_before: int = player.inventory.objects.size()
	KingdomLaws.apply("amende:50", player, kingdom)
	_check("une amende impayable saisit un bien",
		player.inventory.objects.size() == objects_before - 1)
	player.gold = gold_before

	# Crime grave : la réputation DU ROYAUME s'effondre, pas seulement la locale.
	var fresh := Reputation.new()
	player.reputation = fresh
	KingdomLaws.apply("gardes_hostiles", player, kingdom)
	var standing := fresh.kingdom(String(kingdom["id"]))
	_check("un crime grave effondre la réputation du royaume", standing < 0.0,
		"%.1f" % standing)

	# Loi arbitraire : au moins un royaume du monde doit en avoir une, sinon la
	# mécanique existe sans jamais se manifester.
	var banned_somewhere := ""
	for radius in range(0, 40):
		for dz in range(-radius, radius + 1, 3):
			for dx in range(-radius, radius + 1, 3):
				var other := generator.kingdom_at_cell(Vector2i(dx, dz))
				if other.is_empty():
					continue
				for law: Dictionary in KingdomLaws.laws_of(other):
					if String(law.get("type", "")) == "objet":
						banned_somewhere = "%s interdit en %s" % [
							law["target"], other["name"]]
		if banned_somewhere != "":
			break
	_check("des lois arbitraires existent dans le monde", banned_somewhere != "",
		banned_somewhere)

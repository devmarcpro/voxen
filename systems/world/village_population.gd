class_name VillagePopulation
extends RefCounted
## Qui habite un village, et où (3.4/8.4/14.2).
##
## PRINCIPE FONDATEUR, rappelé par l'auteur le 2026-08-01 et posé par le GDD
## (12.1) : « les PNJ (villageois, marchands, monstres...) sont tous construits
## de la même manière ». Un sanglier et un marchand sont la même chose.
##
## Ce fichier ne crée donc AUCUNE classe de PNJ. Il ne fabrique rien du tout :
## il DÉCIDE, à partir de la cellule et de la graine du monde, quels
## identifiants de créature peuplent un village et à quel bâtiment chacun est
## rattaché. Le spawn passe par `CreatureManager.spawn`, exactement comme un
## loup — la seule différence est que le résultat porte ensuite un métier et un
## domicile, deux champs que `Creature` expose pour tout le monde et qu'un
## sanglier laisse simplement vides.
##
## POURQUOI DÉRIVÉ ET NON PERSISTÉ. Le roster est reproductible depuis (cellule,
## graine) : on peut donc entrer et sortir d'un village cent fois sans que rien
## ne soit écrit sur disque, et sans que la population change. Ce qui DOIT être
## persisté, c'est ce qui dévie de cette dérivation — un habitant tué, une
## relation qui a évolué. La décimation (3.4) enregistre des ABSENCES, pas des
## présences : c'est infiniment plus économique, puisque le cas courant est un
## village intact.

const SEED_POPULATION := 77213

## Postes de travail du GDD 8.4. Chacun mappe une compétence de rendement (E.6).
## L'ordre compte : c'est l'ordre d'attribution, donc les premiers postes sont
## pourvus en priorité dans un petit hameau.
const JOBS: Array[String] = [
	"garde", "fermier", "forgeron", "vendeur", "cuisinier",
	"mineur", "bucheron", "eleveur", "couturier", "herboriste", "transporteur",
]

## Métier de repli quand aucune créature civile ne déclare de poste compatible.
const JOB_NONE := ""


## Roster d'un village : une liste d'habitants, groupés en FOYERS.
##
## ---------------------------------------------------------------------------
## POURQUOI DES FOYERS ET PLUS DES INDIVIDUS ISOLÉS (2026-08-09)
## ---------------------------------------------------------------------------
## Chaque habitant était tiré séparément et déclaré FONDATEUR : deux personnes
## vivant sous le même toit portaient donc deux noms de famille différents. Un
## village n'était pas une communauté, c'était une liste de gens qui se
## trouvaient là. `NameGenerator.inherited_family_name` existait pour ça depuis
## le 2026-08-02 et n'était appelé nulle part.
##
## Un foyer partage désormais son NOM, sa RACE et son LOGEMENT, et ses membres
## sont liés : conjoints, ou parent et enfant. C'est ce qui rend lisibles la
## décimation (tuer une maison, c'est éteindre une famille), l'héritage (E.31)
## et la conquête (3.4).
##
## ---------------------------------------------------------------------------
## DÉRIVÉ, JAMAIS PERSISTÉ
## ---------------------------------------------------------------------------
## Tout ci-dessous se recalcule depuis (cellule, graine) : âges, liens, origines,
## équipement. Rien n'est stocké — c'est le principe qui tenait déjà pour les
## noms, et il vaut d'autant plus ici que la matière a décuplé. Seule la MORT est
## persistée (VillageManager), parce qu'elle seule ne se déduit pas.
##
## Chaque entrée porte : creature_id, job, plot, foyer, culture, prenom,
## nom_famille, genre, affichage, race, classe, role, age, origine, conjoint,
## parents, equipement, inventaire.
static func roster(cell: Vector2i, world_seed: int, plan: Dictionary,
		culture_id: String = "") -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var buildings: Array[int] = _habitable_plots(plan)
	if buildings.is_empty():
		return out

	var rng := RandomNumberGenerator.new()
	rng.seed = NoiseGenerator.pcg_hash(cell.x, cell.y, world_seed + SEED_POPULATION)
	var population := int(plan.get("population", 0))

	# On ne peuple JAMAIS au-delà des logements disponibles : la capacité d'un
	# village est dérivée de son bâti (3.4), pas d'un chiffre indépendant. Un
	# village dont la population dépasserait ses maisons aurait des habitants
	# sans domicile, donc sans routine et sans point de chute la nuit.
	population = mini(population, buildings.size() * RESIDENTS_PER_HOUSE)

	# Culture par défaut si l'appelant n'en fournit pas : celle de la race la
	# plus courante. Un village hors de tout royaume doit quand même avoir des
	# noms cohérents entre eux.
	var culture := culture_id
	if culture == "":
		culture = NameGenerator.culture_for_race("humain",
				NoiseGenerator.pcg_hash(cell.x, cell.y, world_seed + SEED_POPULATION))
	var village_name := NameGenerator.town_name(culture,
			NoiseGenerator.pcg_hash(cell.x, cell.y, world_seed))

	var jobs := _jobs_for(population, rng)
	for index in population:
		var job: String = jobs[index]
		var creature_id := _creature_for_job(job, rng)
		if creature_id == "":
			continue
		@warning_ignore("integer_division")
		var household: int = index / RESIDENTS_PER_HOUSE
		var plot: int = buildings[household]
		# LE FOYER porte la graine du nom et de la race : tous ses membres la
		# partagent. Le RANG DANS LE FOYER porte celle de la personne — sans
		# lui, deux conjoints seraient la même personne écrite deux fois.
		var house_seed := NoiseGenerator.pcg_hash(cell.x, cell.y,
				world_seed + SEED_POPULATION + household * 104729)
		var npc_seed := NoiseGenerator.pcg_hash(cell.x, cell.y,
				world_seed + SEED_POPULATION + index * 7717)
		var rank: int = index % RESIDENTS_PER_HOUSE
		var family := NameGenerator.family_name(culture, house_seed)
		var race := _race_for_culture(culture, house_seed)
		var gender := "f" if (npc_seed >> 3) % 2 == 0 else "m"
		# COMPOSITION DU FOYER : couple, ou parent et enfant. C'est ce tirage qui
		# fait qu'un village a des familles et pas seulement des colocataires.
		var with_child: bool = (house_seed >> 5) % 100 < 35
		var is_child: bool = rank == 1 and with_child
		var identity := NameGenerator.identity(culture, npc_seed, gender, "", family)
		var spouse := -1
		if not with_child:
			spouse = index - 1 if rank == 1 else index + 1
			if spouse >= population:
				spouse = -1  # Un veuf : le foyer n'a qu'un occupant.
		out.append({
			"creature_id": creature_id,
			# UN ENFANT N'A PAS DE MÉTIER. Lui en donner un ferait tenir la forge
			# par un gamin de neuf ans, et fausserait le compte des postes.
			"job": "" if is_child else job,
			"plot": plot,
			"foyer": household,
			"culture": culture,
			"prenom": identity["prenom"],
			"nom_famille": family,
			"genre": gender,
			"affichage": identity["affichage"],
			"race": race,
			"classe": _class_of(creature_id),
			"role": _role_of(creature_id, "" if is_child else job),
			"age": _age_for(npc_seed, is_child),
			# ORIGINE : natif la plupart du temps, venu d'ailleurs parfois. Un
			# village où personne n'a jamais bougé est un village mort ; une
			# origine étrangère donne prise au dialogue et aux rumeurs.
			"origine": village_name if (npc_seed >> 11) % 100 >= 25 else NameGenerator.town_name(
					culture, npc_seed + 991),
			"conjoint": spouse,
			"parents": [index - 1] if is_child else [],
			"equipement": _equipment_for(creature_id, is_child),
			"inventaire": _inventory_for(creature_id, is_child),
		})
	return out


## Race d'un foyer, tirée dans les AFFINITÉS de la culture (`race_affinity`).
## Une culture celte fait surtout des elfes et parfois des humains : c'est la
## donnée qui le dit, et la lire ici évite une seconde table qui divergerait.
static func _race_for_culture(culture_id: String, seed_value: int) -> String:
	var affinities: Dictionary = (GameData.name_cultures.get(culture_id, {}) as Dictionary).get(
			"race_affinity", {})
	if affinities.is_empty():
		return "humain"
	var ids := affinities.keys()
	ids.sort()  # Ordre STABLE : sinon le tirage dépendrait de l'ordre du JSON.
	var total := 0.0
	for id: String in ids:
		total += float(affinities[id])
	var roll := float(seed_value % 10000) / 10000.0 * total
	for id: String in ids:
		roll -= float(affinities[id])
		if roll <= 0.0:
			return id
	return str(ids[0])


## Classe d'un habitant, DÉCLARÉE dans sa fiche. En donnée et non déduite du
## métier : un forgeron est un artisan, mais rien n'oblige la correspondance à
## rester vraie pour une espèce qu'on ajouterait demain.
static func _class_of(creature_id: String) -> String:
	return String((GameData.creatures.get(creature_id, {}) as Dictionary).get("classe", "vagabond"))


## Rôle social : le rôle de commandement de la fiche s'il en a un (souverain,
## maître de guilde), sinon le métier. C'est ce qui s'affiche sous le nom.
static func _role_of(creature_id: String, job: String) -> String:
	# `leadership_role` vaut NULL dans la plupart des fiches, et `String(null)`
	# n'existe pas en GDScript — un cas que la lecture ne signale pas et que
	# l'exécution refuse. On teste le type avant de convertir.
	var raw: Variant = (GameData.creatures.get(creature_id, {}) as Dictionary).get("leadership_role")
	var leadership := String(raw) if raw is String else ""
	return leadership if leadership != "" else job


## Âge. Les bornes sont larges à dessein : un village où tout le monde a trente
## ans n'a ni passé ni avenir, et l'âge sert au dialogue comme à la succession.
static func _age_for(seed_value: int, is_child: bool) -> int:
	if is_child:
		return 7 + int((seed_value >> 7) % 11)
	var adult := 20 + int((seed_value >> 13) % 45)
	# Un ancien sur huit : assez pour qu'un village ait ses vieux.
	return adult + 20 if (seed_value >> 17) % 8 == 0 else adult


## ÉQUIPEMENT, dérivé de la CLASSE — la même donnée que celle qui équipe le
## joueur à la création (`starting_items` de data/classes). Un forgeron PNJ porte
## donc les outils d'un artisan, sans qu'on ait écrit une seconde table qui
## aurait divergé de la première au premier objet ajouté.
static func _equipment_for(creature_id: String, is_child: bool) -> Array:
	if is_child:
		return []  # Un enfant ne porte pas les outils du métier familial.
	var class_id := _class_of(creature_id)
	var items: Array = (GameData.classes.get(class_id, {}) as Dictionary).get("starting_items", [])
	var out: Array = []
	for entry: Variant in items:
		if entry is Dictionary:
			out.append(String((entry as Dictionary).get("item_id", "")))
	return out


## INVENTAIRE, même source : les matériaux de départ de la classe.
static func _inventory_for(creature_id: String, is_child: bool) -> Dictionary:
	if is_child:
		return {}
	var class_id := _class_of(creature_id)
	return ((GameData.classes.get(class_id, {}) as Dictionary).get(
			"starting_materials", {}) as Dictionary).duplicate()


## Résidents par maison. Deux : le même chiffre que celui qui dimensionne le
## nombre de bâtiments dans CityGenerator. Les deux DOIVENT rester d'accord,
## sinon un village bâtit dix maisons pour huit habitants ou l'inverse.
const RESIDENTS_PER_HOUSE := CityGenerator.RESIDENTS_PER_BUILDING


## Tuiles de bâtiment, triées : l'ordre doit être stable d'un appel à l'autre,
## sinon deux appels successifs logeraient les mêmes habitants ailleurs.
static func _habitable_plots(plan: Dictionary) -> Array[int]:
	var out: Array[int] = []
	var types: PackedByteArray = plan.get("types", PackedByteArray())
	for idx in types.size():
		if types[idx] == CityGenerator.Tile.BATIMENT:
			out.append(idx)
	out.sort()
	return out


## Répartition des postes. Les premiers de `JOBS` sont pourvus d'abord — un
## hameau de quatre âmes a donc un garde, un fermier, un forgeron et un
## vendeur, ce qui en fait un lieu utile plutôt qu'un décor. Au-delà de la
## liste, on tire au sort : un gros village a plusieurs fermiers.
static func _jobs_for(population: int, rng: RandomNumberGenerator) -> Array[String]:
	var out: Array[String] = []
	for index in population:
		if index < JOBS.size():
			out.append(JOBS[index])
		else:
			out.append(JOBS[rng.randi_range(0, JOBS.size() - 1)])
	return out


## Créature civile capable d'exercer ce poste, tirée parmi celles dont les
## DONNÉES le déclarent (`jobs_compatible`). Rien n'est codé en dur ici : on
## ajoute un métier ou une espèce d'habitant en éditant du JSON, ce qui est la
## règle du projet (11.1).
static func _creature_for_job(job: String, rng: RandomNumberGenerator) -> String:
	var candidates := candidates_for_job(job)
	if candidates.is_empty():
		return ""
	return candidates[rng.randi_range(0, candidates.size() - 1)]


static func candidates_for_job(job: String) -> Array[String]:
	var out: Array[String] = []
	for creature_id: String in GameData.creatures:
		var data: Dictionary = GameData.creatures[creature_id]
		# Un habitant est une créature CIVILE : le profil d'IA fait foi, pas les
		# étiquettes. Un loup qui déclarerait « fermier » par accident de donnée
		# ne doit pas se retrouver à tenir une ferme.
		if String(data.get("ai_profile", "")) not in ["civil", "garde"]:
			continue
		if job in (data.get("jobs_compatible", []) as Array):
			out.append(creature_id)
	out.sort()
	return out


## Position monde du DOMICILE d'un habitant : le centre de sa tuile de bâtiment.
static func home_position(cell: Vector2i, plan: Dictionary, plot: int) -> Vector3i:
	var t: int = plan["T"]
	var tx := plot % t
	@warning_ignore("integer_division")
	var tz := plot / t
	var wx := cell.x * CityGenerator.TILES_PER_CELL * 16 \
		+ (int(plan["offset"]) + tx) * 16 + 8
	var wz := cell.y * CityGenerator.TILES_PER_CELL * 16 \
		+ (int(plan.get("offset_z", plan["offset"])) + tz) * 16 + 8
	return Vector3i(wx, int(plan.get("plateau_y", 0)) + 1, wz)


## Position monde du POSTE DE TRAVAIL : la place centrale du village.
##
## Provisoire et assumé comme tel. Le GDD (8.4) veut que chaque poste ait son
## lieu — la forge pour le forgeron, les champs pour le fermier. Tant que les
## bâtiments n'ont pas de fonction déclarée, envoyer tout le monde sur la place
## produit au moins une vie de village LISIBLE : des habitants qui convergent
## le matin et rentrent le soir. Un habitant planté devant sa porte toute la
## journée ne raconterait rien.
static func work_position(cell: Vector2i, plan: Dictionary) -> Vector3i:
	var t: int = plan["T"]
	@warning_ignore("integer_division")
	var center := t / 2
	var wx := cell.x * CityGenerator.TILES_PER_CELL * 16 \
		+ (int(plan["offset"]) + center) * 16 + 8
	var wz := cell.y * CityGenerator.TILES_PER_CELL * 16 \
		+ (int(plan.get("offset_z", plan["offset"])) + center) * 16 + 8
	return Vector3i(wx, int(plan.get("plateau_y", 0)) + 1, wz)

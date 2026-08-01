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


## Roster d'un village : liste de { "creature_id", "job", "plot" }.
##
## `plot` est l'INDEX DE TUILE du bâtiment attribué, tel que le produit
## `CityGenerator.tile_plan` — le lien entre un habitant et une maison précise,
## qui rendra possible la décimation (3.4), la réoccupation par le joueur et
## l'assignation de postes (14.2) sans rien recalculer.
static func roster(cell: Vector2i, world_seed: int, plan: Dictionary) -> Array[Dictionary]:
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

	var jobs := _jobs_for(population, rng)
	for index in population:
		var job: String = jobs[index]
		var creature_id := _creature_for_job(job, rng)
		if creature_id == "":
			continue
		@warning_ignore("integer_division")
		var plot: int = buildings[index / RESIDENTS_PER_HOUSE]
		out.append({"creature_id": creature_id, "job": job, "plot": plot})
	return out


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

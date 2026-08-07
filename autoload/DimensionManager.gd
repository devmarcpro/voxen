extends Node
## DIMENSIONS (2026-08-03, refondu le 2026-08-04) — registre, ambiance,
## backends spécialisés.
##
## ---------------------------------------------------------------------------
## CE QUE CE FICHIER A CESSÉ D'ÊTRE
## ---------------------------------------------------------------------------
## Il a porté, jusqu'au 2026-08-04, un SECOND PIPELINE DE GÉNÉRATION : un
## stockage voxel à lui, son maillage, son streaming, et un `_build_column` qui
## écrivait les blocs un par un dans le fil principal. C'était un doublon
## inférieur de `NoiseGenerator` + `WorldManager`, lesquels faisaient déjà le
## même travail pour l'overworld — mais multithreadés, chunkés, maillés en
## asynchrone, LODés et bornés en budget. Mesuré : 738 ms pour UNE colonne de
## chunks, contre un budget de frame de 16.
##
## La correction n'a pas été d'optimiser ce doublon mais de le supprimer :
## L'OVERWORLD EST UNE DIMENSION PARMI LES AUTRES. `NoiseGenerator` prend une
## dimension en paramètre, `WorldManager` streame celle qui est active, et tout
## ce que `RiftBuilder` savait faire — reliefs, cavernes, spirales, îles
## suspendues, arbres à l'envers — est redevenu des DONNÉES lues par le
## générateur unique.
##
## LEÇON GÉNÉRALE, notée parce qu'elle s'est déjà présentée deux fois : quand un
## second mécanisme apparaît à côté d'un premier qui fait déjà le travail, le
## geste juste est de GÉNÉRALISER LE PREMIER, jamais d'écrire le second.
##
## ---------------------------------------------------------------------------
## CE QUI RESTE ICI, ET POURQUOI ÇA NE PEUT PAS ÊTRE AILLEURS
## ---------------------------------------------------------------------------
## Le REGISTRE (quelles dimensions existent), l'ENTRÉE et la SORTIE (avec la
## pile de retour), l'AMBIANCE déclarée en données (ciel, soleil, brouillard),
## le PEUPLEMENT d'arrivée, et l'aiguillage vers les BACKENDS spécialisés.
##
## Un backend, c'est une dimension dont le contenu n'est pas du terrain : le
## donjon a des étages, des salles, des escaliers et un boss, produits par son
## propre constructeur. Il n'y a rien à généraliser là — ce n'est pas un monde
## qu'on streame, c'est une structure qu'on bâtit.

## Dimension de départ.
const OVERWORLD: StringName = &"overworld"

## Dimension active — LECTURE SEULE, DÉRIVÉE DE WorldManager.
##
## Ce champ a d'abord été une variable propre, et c'était un doublon de vérité
## qui a cassé le donjon dans l'heure : `DungeonManager` bascule la dimension en
## appelant `WorldManager.set_active_dimension` directement, si bien que ce
## champ restait à « overworld » pendant que le monde était en donjon.
## L'aiguillage cherchait alors un backend pour l'overworld, n'en trouvait pas,
## et lisait un stockage vide : tous les blocs du donjon rendaient zéro.
##
## Deux champs qui doivent rester égaux finissent toujours par ne plus l'être.
## Il n'y en a plus qu'un.
var active: StringName:
	get:
		return WorldManager.active_dimension

## Backends spécialisés : dimension → nœud sachant lire et muter ses blocs.
var _backends := {}

## Position de retour, empilée à l'entrée. Une PILE et non une variable : rien
## n'interdit à une dimension d'en ouvrir une autre, et un simple champ ferait
## ressortir le joueur au mauvais endroit.
var _return_stack: Array[Vector3] = []

## Environnements d'ambiance, construits une fois par dimension.
var _environments := {}


## Déclare qu'une dimension est servie par un backend spécialisé.
func register_backend(dimension: StringName, backend: Node) -> void:
	_backends[dimension] = backend


## LA question que pose WorldManager pour savoir s'il doit streamer lui-même ou
## déléguer. C'est le seul aiguillage qui subsiste.
func has_backend(dimension: StringName) -> bool:
	return _backends.has(dimension)


func is_overworld() -> bool:
	return active == OVERWORLD


## La dimension existe-t-elle ? Une dimension inconnue n'est pas une erreur de
## programmation mais une erreur de DONNÉES : on la signale sans planter.
func exists(dimension: StringName) -> bool:
	return dimension == OVERWORLD or GameData.dimensions.has(String(dimension))


# --- Entrée et sortie -------------------------------------------------------

## Entre dans une dimension et retient d'où l'on vient.
##
## PLUS RIEN N'EST « CONSTRUIT » ICI. Une dimension streamée se génère autour du
## joueur comme l'overworld : il suffit de basculer et de poser le joueur. Ce
## qui reste à faire à l'arrivée, c'est le PEUPLEMENT — les habitants et les
## caches de butin, qui ne sont pas du terrain.
func enter(dimension: StringName, from_position: Vector3, arrival: Vector3) -> bool:
	if not exists(dimension):
		push_warning("DimensionManager : dimension inconnue « %s »." % dimension)
		return false
	_return_stack.append(from_position)
	# ON ACTIVE AVANT DE PEUPLER, et l'ordre compte. Le contenu d'une dimension
	# — créatures, caches de butin — s'enregistre auprès de systèmes qui rangent
	# leurs entrées PAR DIMENSION ACTIVE. Peupler d'abord faisait naître les
	# caches sous l'étiquette « overworld » : elles existaient, mais restaient
	# invisibles une fois dans la faille.
	_activate(dimension)
	var landing := _landing(dimension, arrival)
	var player := get_node_or_null("/root/Main/Player")
	if player != null:
		player.teleport_to(landing)
	if not _backends.has(dimension):
		# LE TERRAIN DOIT EXISTER AVANT QU'ON Y POSE QUOI QUE CE SOIT. Le
		# streaming est asynchrone : on demande la colonne d'arrivée tout de
		# suite, par le chemin synchrone, sinon les habitants naîtraient dans le
		# vide et tomberaient.
		WorldManager.update_center(landing)
		_populate(dimension, landing)
	return true


## Le point d'arrivée : au-dessus du sol réel de la dimension, jamais à une
## altitude devinée. La hauteur vient du générateur de la dimension, donc de la
## même fonction que le terrain qu'on va fouler.
func _landing(dimension: StringName, fallback: Vector3) -> Vector3:
	if _backends.has(dimension):
		return fallback
	var generator: NoiseGenerator = WorldManager.generator
	if generator == null:
		return fallback
	var ground := generator.height_at(roundi(fallback.x), roundi(fallback.z))
	return Vector3(fallback.x + 0.5, float(ground) + 2.9, fallback.z + 0.5)


## CE QU'ON RENCONTRE ET CE QU'ON RAMASSE.
##
## Le bestiaire ayant été réduit aux humains, il n'y a pas de démons à mettre
## dans une faille. On y pose donc ce qui reste cohérent : des gens entrés qui
## n'en sont pas ressortis. Ce n'est pas un pis-aller, c'est une lecture du lieu.
func _populate(dimension: StringName, arrival: Vector3) -> void:
	var declaration: Dictionary = GameData.dimensions.get(String(dimension), {})
	var rng := RandomNumberGenerator.new()
	rng.seed = WorldManager.world_seed ^ hash(String(dimension))
	var generator: NoiseGenerator = WorldManager.generator
	if generator == null:
		return

	for entry: String in (declaration.get("habitants", []) as Array):
		if not GameData.creatures.has(entry):
			continue
		var spot := _ground_spot(generator, arrival, rng, 6.0, 16.0)
		var creature := CreatureManager.spawn(entry, spot)
		if creature != null:
			creature.dimension = dimension

	# Butin : les cristaux du lieu, qui ne poussent nulle part ailleurs. Ils
	# sortent des `accent_material` de ses biomes — la donnée dit déjà quel
	# cristal appartient à quel pays, il n'y a pas à le redire ici.
	var biome_ids: Array = declaration.get("biomes", [])
	for i in rng.randi_range(4, 7):
		if biome_ids.is_empty():
			break
		var zone: Dictionary = GameData.biomes.get(
				String(biome_ids[rng.randi() % biome_ids.size()]), {})
		var prize := String(zone.get("accent_material", ""))
		if prize == "":
			continue
		var spot := _ground_spot(generator, arrival, rng, 8.0, 40.0)
		DropManager.drop_materials(spot, {prize: rng.randi_range(4, 12)})


## Un point posé SUR LE SOL, à distance de l'arrivée. La hauteur est demandée au
## générateur, pas cherchée en sondant des blocs : les chunks alentour ne sont
## pas encore streamés au moment où l'on peuple, et une recherche par blocs
## répondrait « vide » partout.
func _ground_spot(generator: NoiseGenerator, arrival: Vector3,
		rng: RandomNumberGenerator, near: float, far: float) -> Vector3:
	var angle := rng.randf() * TAU
	var distance := rng.randf_range(near, far)
	var x := arrival.x + cos(angle) * distance
	var z := arrival.z + sin(angle) * distance
	return Vector3(x, float(generator.height_at(roundi(x), roundi(z))) + 1.5, z)


## Revient d'où l'on venait. Sans pile, on retombe au centre de l'overworld, ce
## qui vaut mieux que de rester coincé dans une dimension.
func leave() -> void:
	if active == OVERWORLD:
		return
	# `: Vector3` explicite : `Array.pop_back` rend un Variant, dont l'inférence
	# est traitée comme une erreur dans ce projet.
	var back: Vector3 = _return_stack.pop_back() if not _return_stack.is_empty() else Vector3.ZERO
	var left := active
	CreatureManager.despawn_dimension(left)
	_activate(OVERWORLD)
	if not _backends.has(left):
		# Une dimension générée ne survit pas à la sortie : la regénérer est
		# déterministe et coûte moins que d'en tenir les chunks en mémoire pour
		# un endroit où le joueur n'est pas. C'est déjà la règle de l'overworld
		# (G.1 : jamais stocker ce qui est régénérable).
		WorldManager.free_dimension(left)
	var player := get_node_or_null("/root/Main/Player")
	if player != null:
		player.teleport_to(back)


## Bascule effective : c'est WorldManager qui échange le monde et gèle le
## streaming, et CreatureManager qui gèle les créatures — on ne duplique ni l'un
## ni l'autre, on les prévient.
func _activate(dimension: StringName) -> void:
	WorldManager.set_active_dimension(dimension)
	_apply_ambience(dimension)


# --- Ambiance ---------------------------------------------------------------

## Ciel, soleil et brouillard d'une dimension, tels que ses données les
## déclarent. L'ambiance était un environnement construit à la main dans
## DungeonManager, donc invisible à toute autre dimension.
func _apply_ambience(dimension: StringName) -> void:
	var camera := get_viewport().get_camera_3d()
	var sun := get_node_or_null("/root/Main/Sun") as DirectionalLight3D
	var declaration: Dictionary = GameData.dimensions.get(String(dimension), {})
	var ambience: Dictionary = declaration.get("ambience", {})

	if sun != null:
		sun.visible = bool(ambience.get("sunlight", dimension == OVERWORLD))
	if camera == null:
		return
	if dimension == OVERWORLD or ambience.is_empty():
		camera.environment = null
		return
	if not _environments.has(dimension):
		_environments[dimension] = _build_environment(ambience)
	camera.environment = _environments[dimension]


func _build_environment(ambience: Dictionary) -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.html(String(ambience.get("background", "#050508")))
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.html(String(ambience.get("ambient", "#39304C")))
	env.ambient_light_energy = float(ambience.get("ambient_energy", 0.6))
	if bool(ambience.get("fog", false)):
		env.fog_enabled = true
		env.fog_light_color = Color.html(String(ambience.get("fog_color", "#1A1428")))
		env.fog_density = float(ambience.get("fog_density", 0.02))
	return env


# --- Blocs (aiguillés depuis WorldManager, backends seulement) ---------------

## Lecture d'un bloc servi par un backend.
func block_at(pos: Vector3i) -> int:
	if not _backends.has(active):
		return 0
	return int((_backends[active] as Node).call("dimension_block_at", pos))


## Mutation d'un bloc servi par un backend.
func apply_block(pos: Vector3i, material_id: int) -> bool:
	if not _backends.has(active):
		return false
	return bool((_backends[active] as Node).call("dimension_apply_block", pos, material_id))


## Écrit un bloc dans une dimension donnée, active ou non.
##
## Reste ici pour les APPELANTS QUI BÂTISSENT (le donjon pose ses étages, les
## sondes posent leurs témoins) : c'est le seul chemin qui ne passe pas par la
## dimension active. Le terrain, lui, ne s'écrit plus bloc par bloc — il se
## génère.
func set_block_in(dimension: StringName, pos: Vector3i, material_id: int,
		_remesh: bool = true) -> bool:
	if _backends.has(dimension):
		if dimension != active:
			return false
		return apply_block(pos, material_id)
	return WorldManager.set_block_in(dimension, pos, material_id)


## Lit un bloc dans une dimension DONNÉE, active ou non.
func block_at_in(dimension: StringName, pos: Vector3i) -> int:
	if _backends.has(dimension):
		return block_at(pos) if dimension == active else 0
	return WorldManager.block_at_in(dimension, pos)


func chunk_count(dimension: StringName) -> int:
	return WorldManager.chunk_count_in(dimension)

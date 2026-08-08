extends Node3D
## ÉCLAT DE SORT (2026-08-08, demande de l'auteur : « faudra aussi rajouter des
## animations pour les sorts »).
##
## POURQUOI CE FICHIER. Lancer un sort ne se voyait NULLE PART. Le mana baissait,
## un projectile partait parfois — et parfois non, un sort de soin ou de
## protection ne produisant aucun objet visible. Un joueur ne pouvait donc pas
## distinguer « mon sort est parti » de « rien ne s'est passé », ce qui est la
## pire ambiguïté possible sur une action qui COÛTE.
##
## C'est la même leçon que le retour d'impact du combat : une mécanique dont
## l'instant décisif est invisible n'existe pas pour celui qui la joue.
##
## LA COULEUR VIENT DES TAGS DU MODULE, pas d'une table d'ids. Un module de feu
## est orange parce que sa fiche dit « feu » ; en ajouter un nouveau lui donne sa
## couleur sans qu'on touche à ce fichier — et un module sans tag connu reste
## bleu de mana, ce qui est la bonne réponse par défaut plutôt qu'une absence
## d'effet.
const TEINTES := {
	"feu": Color(1.0, 0.55, 0.15),
	"glace": Color(0.55, 0.85, 1.0),
	"foudre": Color(0.95, 0.90, 0.35),
	"terre": Color(0.65, 0.50, 0.30),
	"corruption": Color(0.55, 0.25, 0.60),
	"soin": Color(0.45, 1.0, 0.55),
	"vie": Color(0.45, 1.0, 0.55),
	"protection": Color(0.70, 0.80, 1.0),
	"arcane": Color(0.70, 0.55, 1.0),
}
const DEFAUT := Color(0.55, 0.75, 1.0)

## Durée de l'éclat. Court : c'est une PONCTUATION, pas un effet à contempler.
## Trop long, il masquerait le projectile qu'il annonce.
const DUREE := 0.28
## Rayon final. L'éclat GRANDIT en s'effaçant — un point qui s'éteint sur place
## se lit comme une erreur d'affichage, un point qui s'ouvre se lit comme un
## départ.
const RAYON_DEBUT := 0.06
const RAYON_FIN := 0.34

var _vivants: Array[Dictionary] = []


func _ready() -> void:
	EventBus.spell_cast.connect(_on_spell_cast)


func _on_spell_cast(world_position: Vector3, module_id: String) -> void:
	var mesh := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radial_segments = 8
	sphere.rings = 4
	sphere.radius = RAYON_DEBUT
	sphere.height = RAYON_DEBUT * 2.0
	mesh.mesh = sphere
	var material := StandardMaterial3D.new()
	# NON ÉCLAIRÉ ET ADDITIF : un éclat de magie est une SOURCE, il ne reçoit pas
	# la lumière du soleil. Le rendu du jeu est déjà unshaded, l'éclat doit s'y
	# tenir sinon il paraîtrait posé par-dessus.
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.albedo_color = _teinte(module_id)
	mesh.material_override = material
	mesh.position = world_position
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mesh)
	_vivants.append({"noeud": mesh, "materiau": material, "mesh": sphere, "age": 0.0})


func _process(delta: float) -> void:
	if _vivants.is_empty():
		return
	var restants: Array[Dictionary] = []
	for eclat: Dictionary in _vivants:
		var noeud: MeshInstance3D = eclat["noeud"]
		if not is_instance_valid(noeud):
			continue
		var age := float(eclat["age"]) + delta
		if age >= DUREE:
			noeud.queue_free()
			continue
		eclat["age"] = age
		var ratio := age / DUREE
		var rayon: float = lerpf(RAYON_DEBUT, RAYON_FIN, ratio)
		var sphere: SphereMesh = eclat["mesh"]
		sphere.radius = rayon
		sphere.height = rayon * 2.0
		var materiau: StandardMaterial3D = eclat["materiau"]
		var couleur := materiau.albedo_color
		couleur.a = 1.0 - ratio
		materiau.albedo_color = couleur
		restants.append(eclat)
	_vivants = restants


func _teinte(module_id: String) -> Color:
	var module: Dictionary = GameData.modules.get(module_id, {})
	for tag: String in module.get("tags", []):
		if TEINTES.has(tag):
			return TEINTES[tag]
	return DEFAUT


## Nombre d'éclats en vie (sondes).
func count() -> int:
	return _vivants.size()

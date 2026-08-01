class_name Collection
extends RefCounted
## Collection du joueur : le catalogue de tout ce qu'il a offert, définitivement.
##
## OBJECTIF DE JEU (demande de l'auteur du 2026-08-01) : « un des objectifs du
## joueur est de collectionner tous les items du jeu ». Ce n'est pas un journal
## de ce qu'on a croisé — c'est un cabinet de curiosités, et déposer une pièce
## la DÉTRUIT.
##
## POURQUOI LA DESTRUCTION EST LE CŒUR DU SYSTÈME, et non une contrainte
## regrettable. Sans elle, remplir la collection serait une formalité : on
## dépose, on reprend, l'objet continue de servir. Le sacrifice est ce qui donne
## un prix à chaque entrée — donner sa première épée en fer coûte une épée en
## fer. C'est aussi ce qui rend la complétion lente sans être artificielle : le
## joueur ne renonce à un objet que lorsqu'il en a un meilleur.
##
## GRANULARITÉ : UNE ENTRÉE PAR TYPE D'OBJET, pas par exemplaire.
##
## Le choix mérite d'être écrit, parce que l'autre option paraît séduisante.
## Indexer par (type × matériaux × qualité) donnerait des millions d'entrées :
## une épée existe en 18 081 variantes. Une collection qu'on ne peut pas finir,
## et dont une page ne montre rien d'intelligible, n'est pas un objectif — c'est
## un compteur. On indexe donc par type.
##
## La PROFONDEUR passe par la QUALITÉ : redonner un meilleur exemplaire du même
## type améliore l'entrée. Le collectionneur a donc deux horizons — tout avoir,
## puis tout avoir en beau — sans que le second empêche jamais d'atteindre le
## premier.

## Une entrée : { "quality": float, "materials": Dictionary, "tick": int }.
## `materials` et `tick` sont conservés pour l'affichage (« offert le… », de
## quoi était fait l'exemplaire) : une collection sans souvenir n'en est pas une.
var entries := {}


## Tous les identifiants collectionnables, dans l'ordre d'affichage.
##
## Les OBJETS craftables et les RESSOURCES de créature (viande, peau) : tout ce
## qui peut exister comme instance dans un inventaire. Les matériaux bruts en
## sont exclus — ce sont des piles de blocs, pas des pièces de collection, et
## les inclure noierait les 31 objets sous 249 minerais.
static func catalogue() -> Array[String]:
	var ids: Array[String] = []
	for item_id: String in GameData.items:
		ids.append(item_id)
	for resource_id: String in GameData.resources:
		ids.append(resource_id)
	ids.sort()
	return ids


## Clé de collection d'une INSTANCE. Une ressource s'identifie par son
## `resource_id` (« viande_de_loup »), un objet crafté par son `item_id`.
static func key_of(instance: Dictionary) -> String:
	var resource_id := String(instance.get("resource_id", ""))
	if resource_id != "":
		return resource_id
	return String(instance.get("item_id", ""))


## Nom affichable d'une entrée du catalogue.
static func name_key_of(key: String) -> String:
	if GameData.items.has(key):
		return String((GameData.items[key] as Dictionary).get("name_key", key))
	if GameData.resources.has(key):
		return String((GameData.resources[key] as Dictionary).get("name_key", key))
	return key


## Catégorie affichable, pour le tri et le regroupement.
static func kind_of(key: String) -> String:
	if GameData.resources.has(key):
		return "ressource"
	var item: Dictionary = GameData.items.get(key, {})
	return String(item.get("type", "divers"))


func has(key: String) -> bool:
	return entries.has(key)


func quality_of(key: String) -> float:
	return float((entries.get(key, {}) as Dictionary).get("quality", 0.0))


## Peut-on offrir cette instance ? Faux si le type est déjà représenté par un
## exemplaire AU MOINS AUSSI BON : détruire un objet sans rien gagner serait une
## perte sèche, et l'interface doit pouvoir l'empêcher plutôt que de compter sur
## l'attention du joueur.
func would_improve(instance: Dictionary) -> bool:
	var key := key_of(instance)
	if key == "":
		return false
	if not entries.has(key):
		return true
	return float(instance.get("quality", 1.0)) > quality_of(key) + 0.0001


## Enregistre l'instance dans la collection. L'appelant est responsable de la
## RETIRER de l'inventaire — cette classe ne connaît pas l'inventaire, et c'est
## volontaire : elle reste testable seule.
##
## Retourne "" si le don est refusé, sinon la clé enregistrée.
func donate(instance: Dictionary) -> String:
	if not would_improve(instance):
		return ""
	var key := key_of(instance)
	entries[key] = {
		"quality": float(instance.get("quality", 1.0)),
		"materials": (instance.get("materials", {}) as Dictionary).duplicate(),
		"tick": TickManager.tick_index,
	}
	return key


## Avancement : { "offerts": int, "total": int, "ratio": float }.
func progress() -> Dictionary:
	var total := catalogue().size()
	var owned := 0
	# On compte les entrées PRÉSENTES AU CATALOGUE : une sauvegarde d'avant le
	# retrait d'un objet ne doit pas afficher 32/31.
	for key: String in entries:
		if GameData.items.has(key) or GameData.resources.has(key):
			owned += 1
	return {"offerts": owned, "total": total,
		"ratio": float(owned) / maxf(float(total), 1.0)}


func save_state() -> Dictionary:
	return {"entries": entries.duplicate(true)}


func restore_state(data: Dictionary) -> void:
	entries.clear()
	var saved: Dictionary = data.get("entries", {})
	for key: Variant in saved:
		if saved[key] is Dictionary:
			entries[String(key)] = saved[key]

class_name Equipment
extends RefCounted
## Emplacements d'équipement (6.2) — 13 pour un humanoïde. Une pièce équipée
## est une INSTANCE d'objet (le dictionnaire produit par ItemFactory), la même
## que celles stockées dans Inventory.objects : équiper = déplacer la
## référence de l'inventaire vers un emplacement, jamais dupliquer.
##
## Ce que cette classe fait : les emplacements, la mitigation d'armure (A.4.2)
## et le poids porté. Ce qu'elle ne fait PAS encore :
## - les effets passifs d'équipement (A.4.4) et les pools de loot (F.7) — ils
##   attendent le résolveur de modificateurs d'E.4, qui n'existe pas encore ;
## - les morphologies non-humanoïdes (`equip_slots` de B.5, 6.2) — la liste
##   ci-dessous est celle de l'humanoïde, les gabarits quadrupède/volant/
##   amorphe restent à câbler quand les créatures porteront de l'équipement.
##
## (Cet en-tête affirmait jusqu'au 2026-08-02 que Dual Wielding / Bouclier /
## Deux Mains « n'existent pas en données » — c'était faux depuis le
## 2026-08-01. Ce projet documente sa dette en prose plutôt qu'en TODO, ce qui
## est un bon choix, mais la prose périme en silence : à relire quand on
## touche au fichier.)

## Les 13 emplacements humanoïdes (6.2), dans l'ordre du GDD.
const SLOTS: Array[String] = [
	"tete", "torse", "jambes", "pieds", "mains",
	"anneau_1", "anneau_2", "amulette",
	"arme_1", "arme_2",
	"accessoire_1", "accessoire_2",
	"dos",
]

## Emplacements interchangeables : équiper dans « anneau » prend le premier
## des deux libres. Évite d'imposer au joueur le choix d'un numéro.
const SLOT_GROUPS := {
	"anneau": ["anneau_1", "anneau_2"],
	"arme": ["arme_1", "arme_2"],
	"accessoire": ["accessoire_1", "accessoire_2"],
	# Un BOUCLIER va toujours en main gauche (arme_2), jamais en main forte.
	# Il n'est pas dans le groupe « arme » exprès : sans ça, un bouclier posé
	# dans le premier emplacement libre pouvait atterrir en arme_1 et l'on se
	# retrouvait à frapper avec — un cas absurde qu'aucune règle ne rattrapait
	# plus ensuite.
	"bouclier": ["arme_2"],
}

## Facteur de protection par emplacement (A.4.2, copié à la lettre). Les
## emplacements absents ne contribuent AUCUN dé de réduction (un anneau ne
## protège pas — ses effets passent par A.4.4, pas encore implémenté).
const SLOT_ARMOR_FACTOR := {
	"torse": 1.0,
	"tete": 0.6,
	"jambes": 0.7,
	"pieds": 0.3,
	"mains": 0.3,
}

## slot -> instance d'objet (dictionnaire ItemFactory). Emplacement vide = absent.
var slots := {}

## Pièces SORTIES EN PLUS lors du dernier `equip` — aujourd'hui la main gauche
## libérée par une arme à deux mains. `equip` ne peut en rendre qu'une, et
## l'oublier ici la ferait DISPARAÎTRE : elle n'est plus équipée, et personne ne
## l'a remise dans l'inventaire.
var displaced: Array = []


## Emplacement CONCRET libre pour un `equip_slot` de données (B.3), ou "" si
## l'emplacement est inconnu. Un groupe plein retourne son PREMIER emplacement
## (l'appelant y remplace la pièce déjà portée).
## Une arme à DEUX MAINS occupe-t-elle déjà les deux ? (2026-08-09, signalé en
## jeu : « on peut équiper 2 armes à 2 mains, ce qui est un problème »).
##
## `resolve_slot` ne raisonnait que sur les emplacements LIBRES : une espadon en
## arme_1 laissait arme_2 vide, donc disponible, et l'on se retrouvait avec deux
## armes à deux mains — quatre mains au total. Le refus existait déjà pour le
## glisser-déposer précis (`equip_instance_in_slot`), mais pas pour l'équipement
## automatique, qui est le chemin ordinaire.
static func is_two_handed(instance: Dictionary) -> bool:
	if instance.is_empty():
		return false
	var item: Dictionary = GameData.items.get(instance.get("item_id", ""), {})
	return int(item.get("hands", 1)) >= 2


## Emplacements d'arme RÉELLEMENT libres, une fois la règle des deux mains
## appliquée. Retourne [] si la pièce ne peut aller nulle part.
func free_weapon_slots(two_handed: bool) -> Array:
	# Une arme à deux mains DÉJÀ portée mobilise les deux emplacements : plus
	# rien ne peut s'y ajouter, ni seconde arme ni bouclier.
	if is_two_handed(slots.get("arme_1", {})):
		return []
	if two_handed:
		# La nouvelle arme réclame les deux mains : elle ne peut prendre que la
		# main forte, et seulement si la gauche est libre.
		return [] if slots.has("arme_2") else ["arme_1"]
	var free: Array = []
	for slot: String in ["arme_1", "arme_2"]:
		if not slots.has(slot):
			free.append(slot)
	return free


func resolve_slot(equip_slot: String) -> String:
	if SLOT_GROUPS.has(equip_slot):
		var group: Array = SLOT_GROUPS[equip_slot]
		for slot: String in group:
			if not slots.has(slot):
				return slot
		return group[0]
	return equip_slot if equip_slot in SLOTS else ""


## Équipe `instance` et retourne la pièce DÉPLACÉE (celle qui occupait
## l'emplacement), ou {} si l'emplacement était libre. L'appelant est
## responsable de sortir l'instance de l'inventaire et d'y remettre le retour.
func equip(instance: Dictionary) -> Dictionary:
	var item: Dictionary = GameData.items.get(instance.get("item_id", ""), {})
	var equip_slot := String(item.get("equip_slot", ""))
	var slot := resolve_slot(equip_slot)
	# RÈGLE DES DEUX MAINS (voir `free_weapon_slots`). Elle s'applique aux armes
	# ET aux boucliers : les deux visent la main gauche, qu'une arme à deux
	# mains a déjà prise.
	displaced.clear()
	# UNE ARME À DEUX MAINS OCCUPE LES DEUX. `resolve_slot` ne raisonne que sur
	# les emplacements LIBRES : une espadon en arme_1 laissait arme_2 vide, donc
	# disponible, et l'on portait deux armes à deux mains — quatre mains.
	#
	# On corrige ICI et pas dans `resolve_slot`, qui rend le premier emplacement
	# libre d'un GROUPE et ne connaît rien des règles de prise. Surtout, on n'y
	# touche pas au cas du bouclier : son groupe vaut ["arme_2"] exprès — sans
	# quoi un écu pouvait atterrir en main forte et l'on frappait avec.
	if equip_slot == "arme":
		if is_two_handed(instance):
			# Elle réclame les deux mains : main forte, et la gauche se vide.
			slot = "arme_1"
			if slots.has("arme_2"):
				displaced.append(unequip("arme_2"))
		elif is_two_handed(slots.get("arme_1", {})):
			# La main forte tient déjà un espadon : les deux mains sont prises,
			# la nouvelle arme la REMPLACE plutôt que de se poser à côté.
			slot = "arme_1"
	elif equip_slot == "bouclier" and is_two_handed(slots.get("arme_1", {})):
		# Un bouclier ne se glisse pas sous une arme à deux mains : c'est l'arme
		# qui cède, sinon on porterait trois pièces pour deux mains.
		displaced.append(unequip("arme_1"))
	if slot == "":
		return {}
	var previous: Dictionary = slots.get(slot, {})
	slots[slot] = instance
	return previous


## Retire la pièce de `slot` et la retourne ({} si l'emplacement était vide).
func unequip(slot: String) -> Dictionary:
	if not slots.has(slot):
		return {}
	var instance: Dictionary = slots[slot]
	slots.erase(slot)
	return instance


func equipped(slot: String) -> Dictionary:
	return slots.get(slot, {})


## Dés de réduction d'UNE pièce (A.4.2) :
##   des_piece = 1dX, X = round(durete_BASE * qualite * facteur_slot / 4),
##   minimum 1d2. `base_hardness` est la dureté AVANT qualité (A.4.1) — la
##   qualité est appliquée ici, une seule fois.
static func piece_dice(instance: Dictionary, slot: String) -> String:
	var factor := float(SLOT_ARMOR_FACTOR.get(slot, 0.0))
	if factor <= 0.0 or instance.is_empty():
		return ""
	var faces := int(round(float(instance.get("base_hardness", 0.0))
			* float(instance.get("quality", 1.0)) * factor / 4.0))
	return "1d%d" % maxi(2, faces)


## Dés de protection TOTALE, au format attendu par CombatResolver ("XdY").
## Les pièces ne partagent pas le même nombre de faces : on somme les dés en
## conservant la MOYENNE totale, ramenée à une notation unique — la moyenne
## d'un 1dY vaut (Y+1)/2, donc N dés de moyenne cumulée M équivalent à
## NdY avec Y = 2*M/N - 1. Retourne "" si aucune pièce d'armure n'est portée
## (E.3 : pas d'armure = réduction nulle, surtout pas 1d2 gratuit).
func total_armor_dice() -> String:
	var count := 0
	var mean_sum := 0.0
	for slot: String in SLOT_ARMOR_FACTOR:
		var dice := piece_dice(slots.get(slot, {}), slot)
		if dice == "":
			continue
		count += 1
		mean_sum += (float(dice.split("d")[1]) + 1.0) * 0.5
	if count == 0:
		return ""
	var faces := int(round(2.0 * mean_sum / float(count) - 1.0))
	return "%dd%d" % [count, maxi(2, faces)]


## Catégorie de matériau DOMINANTE de l'armure portée (combat directionnel,
## 2026-07-28) — celle qui décide si la protection est de type « plaque » ou
## « rembourré » face au tranchant/perçant/contondant (WeaponStats.
## armor_type_modifier). On prend la pièce de TORSE : c'est le facteur de
## protection le plus élevé (1.0 ci-dessus) et ce qui définit une panoplie.
## Retourne "" si le torse est nu — l'appelant tombe alors sur la ligne
## « _defaut », neutre.
func dominant_armor_category() -> String:
	var torso: Dictionary = slots.get("torse", {})
	if torso.is_empty():
		return ""
	var materials: Dictionary = torso.get("materials", {})
	var best_category := ""
	var best_amount := 0
	# La recette liste ses entrées par catégorie ; la catégorie la plus
	# fournie est celle qui donne son caractère à la pièce.
	var item: Dictionary = GameData.items.get(torso.get("item_id", ""), {})
	for input: Variant in item.get("recipe", {}).get("inputs", []):
		var category := String((input as Dictionary).get("category", ""))
		var amount := int((input as Dictionary).get("amount", 0))
		if materials.has(category) and amount > best_amount:
			best_amount = amount
			best_category = category
	return best_category


## Élément Wu Xing du PORTEUR (5.2/A.4.6, amendement 2026-08-09) : dérivé de la
## catégorie de matériau dominante de l'armure (la pièce de torse, même règle
## que `dominant_armor_category`) — métal→Métal, bois/fibre/cuir→Bois,
## roche/terre→Terre, glace/liquide→Eau, flammabilité ≥ 60→Feu. Torse nu :
## neutre. L'armure de plates face à un mage de Feu est un vrai handicap.
func wu_element() -> String:
	var category := dominant_armor_category()
	if category == "":
		return ""
	var torso: Dictionary = slots.get("torse", {})
	var mat_id := String((torso.get("materials", {}) as Dictionary).get(category, ""))
	var material: Dictionary = GameData.materials.get(mat_id, {})
	if not material.is_empty():
		var el := WuXing.element_of_material(material)
		if el != "":
			return el
	return WuXing.CATEGORY_ELEMENT.get(category, "")


## Poids total de l'équipement porté — compte dans la capacité (A.4.2 :
## « inclut inventaire ET équipement »).
func total_weight() -> float:
	var total := 0.0
	for slot: String in slots:
		total += float((slots[slot] as Dictionary).get("weight", 0.0))
	return total


## Malus de défense lié au poids porté (E.3 : `armor_malus` de la formule de
## défense). Le GDD chiffre le malus de VITESSE en fonction de
## poids_total/capacite (A.4.2) mais laisse le malus de DÉFENSE sans formule :
## proposition par défaut, même rapport, 1 point de défense par tranche de
## 25 % de capacité utilisée par l'équipement seul.
func defense_malus(capacity: float) -> int:
	if capacity <= 0.0:
		return 0
	return int(floor(total_weight() / capacity * 4.0))


func save_state() -> Dictionary:
	var data := {}
	for slot: String in slots:
		data[slot] = slots[slot]
	return data


func restore_state(data: Dictionary) -> void:
	slots.clear()
	for slot: Variant in data:
		if String(slot) in SLOTS and data[slot] is Dictionary:
			# Une pièce équipée porte un uid de la session précédente : sans le
			# déclarer, un craft ultérieur pourrait le réattribuer et deux objets
			# distincts deviendraient indiscernables.
			ItemFactory.note_uid(int((data[slot] as Dictionary).get("uid", 0)))
			slots[String(slot)] = data[slot]

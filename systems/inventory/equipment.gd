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


## Emplacement CONCRET libre pour un `equip_slot` de données (B.3), ou "" si
## l'emplacement est inconnu. Un groupe plein retourne son PREMIER emplacement
## (l'appelant y remplace la pièce déjà portée).
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
	var slot := resolve_slot(String(item.get("equip_slot", "")))
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

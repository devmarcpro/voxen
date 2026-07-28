class_name Inventory
extends RefCounted
## Inventaire à piles (étape D.3.3) — poids et capacité selon A.4.2 :
##   capacite = 30 + Force * 5 (inclut inventaire ET équipement)
## Le poids d'un bloc de matériau = sa `densite` (la densité pilote le poids,
## 4.2/A.4.1). Le dépassement de capacité n'est PAS bloqué : il applique un
## malus de vitesse (A.4.2) — géré par le porteur, pas par l'inventaire.

## Piles de matériaux : id matériau -> quantité (blocs entiers).
var material_stacks := {}
## Fractions de bloc par matériau (0..1) — la monnaie de la subdivision 4.1 :
## poser/récolter des sous-blocs déplace des fractions de volume ; une
## fraction qui atteint 1 redevient un bloc entier. (Règle non couverte par
## l'Annexe A — interprétation « volume conservé », signalée au GDD.)
var material_fractions := {}
## Objets individuels (outils...) : liste d'instances (voir ItemFactory).
var objects: Array[Dictionary] = []


## Capacité de poids (A.4.2, amendée le 2026-07-19 : ×100).
static func capacity_for(force: int) -> float:
	return (30.0 + force * 5.0) * 100.0


func add_material(material_id: String, amount: int) -> void:
	material_stacks[material_id] = int(material_stacks.get(material_id, 0)) + amount


## Retire `amount` unités ; retourne false (sans rien retirer) si insuffisant.
func remove_material(material_id: String, amount: int) -> bool:
	var held := int(material_stacks.get(material_id, 0))
	if held < amount:
		return false
	if held == amount:
		material_stacks.erase(material_id)
	else:
		material_stacks[material_id] = held - amount
	return true


func add_object(object_instance: Dictionary) -> void:
	# Regroupement des ressources IDENTIQUES (même espèce, même type) : sans
	# lui, chaque chasse ajoute une ligne et l'inventaire devient illisible.
	# Les objets craftés ne sont jamais regroupés — deux épées de même recette
	# diffèrent par leur qualité et doivent rester distinctes.
	var resource_id := String(object_instance.get("resource_id", ""))
	if resource_id != "":
		for existing in objects:
			if String(existing.get("resource_id", "")) == resource_id:
				existing["count"] = int(existing.get("count", 1)) + int(object_instance.get("count", 1))
				return
	objects.append(object_instance)


## Retire `count` unités d'une instance (l'entrée disparaît à zéro).
## Retourne false si l'instance est absente ou la quantité insuffisante.
func remove_object_units(instance: Dictionary, count: int = 1) -> bool:
	var index := objects.find(instance)
	if index < 0:
		return false
	var held := int(instance.get("count", 1))
	if held < count:
		return false
	if held == count:
		objects.remove_at(index)
	else:
		instance["count"] = held - count
	return true


## Instance portant l'uid demandé, ou {} — les liaisons de hotbar désignent
## les objets par uid (stable au tri, à la sauvegarde et au rechargement).
func object_by_uid(uid: int) -> Dictionary:
	for obj in objects:
		if int(obj.get("uid", -1)) == uid:
			return obj
	return {}


## Volume total détenu d'un matériau, en blocs (entiers + fraction).
func total_volume(material_id: String) -> float:
	return int(material_stacks.get(material_id, 0)) + float(material_fractions.get(material_id, 0.0))


## Union des ids de matériaux détenus (blocs entiers OU fraction seule), triés.
func material_ids() -> Array:
	var seen := {}
	for id in material_stacks:
		seen[id] = true
	for id in material_fractions:
		seen[id] = true
	var ids: Array = seen.keys()
	ids.sort()
	return ids


## Format d'affichage d'un volume en blocs : « 13 » si entier, « 13.27 » sinon
## (2026-07-26 : on mine/construit en sous-voxels → quantités fractionnaires).
static func format_volume(v: float) -> String:
	if absf(v - round(v)) < 0.005:
		return str(int(round(v)))
	return "%.2f" % v


## Crédite un volume (récolte de sous-blocs) ; consolide en blocs entiers.
func add_volume(material_id: String, volume: float) -> void:
	var fraction := float(material_fractions.get(material_id, 0.0)) + volume
	var whole := floori(fraction)
	if whole > 0:
		add_material(material_id, whole)
		fraction -= whole
	if fraction > 0.0001:
		material_fractions[material_id] = fraction
	else:
		material_fractions.erase(material_id)


## Débite un volume (pose de sous-blocs) ; casse un bloc entier en fraction
## si nécessaire. Retourne false (sans rien débiter) si insuffisant.
func remove_volume(material_id: String, volume: float) -> bool:
	if total_volume(material_id) < volume - 0.0001:
		return false
	var fraction := float(material_fractions.get(material_id, 0.0))
	while fraction < volume - 0.0001:
		if not remove_material(material_id, 1):
			return false
		fraction += 1.0
	fraction -= volume
	if fraction > 0.0001:
		material_fractions[material_id] = fraction
	else:
		material_fractions.erase(material_id)
	return true


# --- Sauvegarde (E.10, via SaveManager) ---
## Tout est déjà JSON-compatible (ids texte, dictionnaires plats) : les
## instances d'objets (ItemFactory) portent leurs stats calculées — pas
## besoin de recrafter au chargement.

func save_state() -> Dictionary:
	return {
		"stacks": material_stacks.duplicate(),
		"fractions": material_fractions.duplicate(),
		"objects": objects.duplicate(true),
	}


func restore_state(data: Dictionary) -> void:
	material_stacks.clear()
	material_fractions.clear()
	objects.clear()
	var stacks: Dictionary = data.get("stacks", {})
	for id: String in stacks:
		material_stacks[id] = int(stacks[id])  # JSON relit les nombres en float.
	var fractions: Dictionary = data.get("fractions", {})
	for id: String in fractions:
		material_fractions[id] = float(fractions[id])
	for obj: Variant in (data.get("objects", []) as Array):
		if obj is Dictionary:
			objects.append(obj)


## Poids total porté : blocs et fractions (densité × volume) + objets.
func total_weight() -> float:
	var weight := 0.0
	for id in material_stacks:
		var mat: Variant = GameData.stackable(id)
		if mat != null:
			weight += float(mat["stats"]["densite"]) * int(material_stacks[id])
	for id in material_fractions:
		var mat: Variant = GameData.stackable(id)
		if mat != null:
			weight += float(mat["stats"]["densite"]) * float(material_fractions[id])
	for obj in objects:
		# `count` : les ressources regroupent plusieurs unités sur une instance.
		weight += float(obj.get("weight", 0.0)) * float(obj.get("count", 1))
	return weight

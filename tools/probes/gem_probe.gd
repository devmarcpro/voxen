extends Probe
## Sonde `--probe-gemme` — sertissage de gemme sur les armes.
##
## Ce que cette sonde défend, et pourquoi : la gemme est le support du futur
## enchantement, pas un bonus de stat. La tentation permanente sera de lui faire
## « ajouter un peu de dégâts » ; le jour où ça arrivera, l'enchantement n'aura
## plus rien à apporter et le sertissage deviendra un simple upgrade linéaire.
## Les assertions ci-dessous verrouillent donc autant ce que la gemme NE FAIT
## PAS que ce qu'elle fait.

const TAG := "GEMME"

var _ok := true


func _check(label: String, condition: bool, detail: String = "") -> void:
	if not condition:
		_ok = false
	print("[%s] %s%s : %s" % [TAG, label, "" if detail == "" else " (" + detail + ")",
		"OK" if condition else "ÉCHEC"])


func run() -> void:
	_check_catalogue()
	_check_craft_sans_gemme()
	_check_craft_avec_gemme()
	_check_gemme_neutre_sur_le_combat()
	_check_eligibilite()
	_check_rendu()
	finish(_ok, TAG)


## Le catalogue de pierres sertissables doit être non vide et TRIÉ par
## conductivité décroissante : c'est l'ordre dans lequel l'UI les propose, donc
## celui dans lequel le joueur les compare.
func _check_catalogue() -> void:
	var gems := ItemFactory.gem_materials()
	_check("catalogue non vide", gems.size() >= 5, "%d pierre(s)" % gems.size())
	var sorted := true
	for i in range(1, gems.size()):
		var previous := float(GameData.materials[gems[i - 1]]["stats"]["conductivite_mana"])
		var current := float(GameData.materials[gems[i]]["stats"]["conductivite_mana"])
		if current > previous:
			sorted = false
	_check("trié par conductivité décroissante", sorted,
		"" if gems.is_empty() else "%s en tête" % gems[0])
	var all_crystal := true
	for gem_id: String in gems:
		if String(GameData.materials[gem_id].get("category", "")) != ItemFactory.GEM_CATEGORY:
			all_crystal = false
	_check("toutes de catégorie cristal", all_crystal)


func _check_craft_sans_gemme() -> void:
	var plain := ItemFactory.craft("epee", {"bois": "chene", "minerai": "fer"}, 1.0)
	_check("arme non sertie : pas de champ gem", not plain.has("gem"))
	_check("arme non sertie : conductivité de mana nulle",
		is_equal_approx(float(plain.get("mana_conductivity", -1.0)), ItemFactory.NO_GEM_MANA))


func _check_craft_avec_gemme() -> void:
	var plain := ItemFactory.craft("epee", {"bois": "chene", "minerai": "fer"}, 1.0)
	var set_gem := ItemFactory.craft("epee",
		{"bois": "chene", "minerai": "fer", "cristal": "rubis"}, 1.0)
	_check("arme sertie : gem = rubis", String(set_gem.get("gem", "")) == "rubis")
	_check("arme sertie : couleur transmise pour le rendu",
		String(set_gem.get("gem_color", "")) == String(GameData.materials["rubis"]["color"]))

	var mana := float(set_gem.get("mana_conductivity", 0.0))
	_check("arme sertie : conductivité de mana = celle de la pierre",
		is_equal_approx(mana, float(GameData.materials["rubis"]["stats"]["conductivite_mana"])),
		"%.0f" % mana)

	# La pierre est PHYSIQUEMENT là : elle pèse. Et parce qu'elle pèse, elle
	# ralentit l'arme (WeaponStats dérive la vitesse du poids). C'est le seul
	# effet mécanique du sertissage, et il est volontairement défavorable.
	var gain := float(set_gem["weight"]) - float(plain["weight"])
	var expected := float(GameData.materials["rubis"]["stats"]["densite"]) * ItemFactory.GEM_WEIGHT_SHARE
	_check("arme sertie : surpoids = densité × part taillée",
		is_equal_approx(gain, expected), "+%.3f" % gain)
	# Garde-fou de dosage : une pierre taillée ne doit jamais peser comme un
	# composant. Sans ce plafond, un diamant doublait le poids d'une dague.
	var dagger := ItemFactory.craft("dague", {"bois": "chene", "minerai": "fer"}, 1.0)
	var dagger_gem := ItemFactory.craft("dague",
		{"bois": "chene", "minerai": "fer", "cristal": "diamant"}, 1.0)
	var ratio := float(dagger_gem["weight"]) / maxf(0.001, float(dagger["weight"]))
	_check("surpoids marginal sur l'arme la plus légère", ratio < 1.35,
		"×%.2f" % ratio)


## LE VERROU CENTRAL : sertir ne doit rien changer au combat. Dureté, dégâts,
## allonge, fenêtre de parade — tout doit être identique à l'arme nue, à la
## seule exception de ce que le POIDS entraîne mécaniquement.
func _check_gemme_neutre_sur_le_combat() -> void:
	var plain := ItemFactory.craft("epee", {"bois": "chene", "minerai": "fer"}, 1.0)
	var set_gem := ItemFactory.craft("epee",
		{"bois": "chene", "minerai": "fer", "cristal": "rubis"}, 1.0)
	_check("dureté inchangée par la gemme",
		is_equal_approx(float(plain["base_hardness"]), float(set_gem["base_hardness"])),
		"%.2f" % float(set_gem["base_hardness"]))

	var functionality: Dictionary = GameData.functionalities.get(plain["functionality"], {})
	var a := WeaponStats.derive(functionality, plain)
	var b := WeaponStats.derive(functionality, set_gem)
	_check("allonge inchangée par la gemme",
		is_equal_approx(float(a["reach"]), float(b["reach"])), "%.3f" % float(b["reach"]))
	_check("dés de dégâts inchangés par la gemme",
		String(a.get("dice", "")) == String(b.get("dice", "")))
	# La vitesse, elle, DOIT bouger : c'est la contrepartie assumée du poids.
	_check("l'arme sertie est plus lente (contrepartie du poids)",
		float(b["windup_ms"]) > float(a["windup_ms"]),
		"%.0f ms → %.0f ms" % [float(a["windup_ms"]), float(b["windup_ms"])])


## Seules les armes ASSEMBLÉES ont un logement : une armure ou un outil à sprite
## n'a aucun point de géométrie où sertir, et proposer le choix mentirait.
func _check_eligibilite() -> void:
	_check("épée sertissable", ItemFactory.accepts_gem("epee"))
	_check("lance sertissable", ItemFactory.accepts_gem("lance"))
	_check("cuirasse NON sertissable", not ItemFactory.accepts_gem("cuirasse"))
	_check("objet inconnu NON sertissable", not ItemFactory.accepts_gem("nexistepas"))

	# Desserti après coup : le futur enchantement doit pouvoir changer de pierre
	# sans refondre l'arme.
	var weapon := ItemFactory.craft("epee",
		{"bois": "chene", "minerai": "fer", "cristal": "saphir"}, 1.0)
	ItemFactory.set_gem(weapon, "")
	_check("dessertissage : champ gem retiré", not weapon.has("gem"))
	_check("dessertissage : conductivité revenue à zéro",
		is_equal_approx(float(weapon["mana_conductivity"]), ItemFactory.NO_GEM_MANA))


## LA GEMME DOIT SE VOIR. Une pierre sertie invisible n'existe pas pour le
## joueur — la leçon la plus chère de tout ce lot de combat.
func _check_rendu() -> void:
	var held_script: GDScript = preload("res://scenes/entities/held_item.gd")
	var plain_node: MeshInstance3D = held_script.new()
	var gem_node: MeshInstance3D = held_script.new()
	main.add_child(plain_node)
	main.add_child(gem_node)

	var plain := ItemFactory.craft("epee", {"bois": "chene", "minerai": "fer"}, 1.0)
	var set_gem := ItemFactory.craft("epee",
		{"bois": "chene", "minerai": "fer", "cristal": "emeraude"}, 1.0)
	var item: Dictionary = GameData.items["epee"]
	plain_node.call("_build_part_weapon", item, plain["materials"], plain)
	gem_node.call("_build_part_weapon", item, set_gem["materials"], set_gem)

	var plain_meshes := _count_meshes(plain_node)
	var gem_meshes := _count_meshes(gem_node)
	_check("la gemme ajoute exactement un maillage", gem_meshes == plain_meshes + 1,
		"%d → %d" % [plain_meshes, gem_meshes])

	# Émissive : le rendu du jeu est non éclairé, une pierre mate serait
	# indiscernable du métal, de jour comme de nuit.
	var emissive := false
	var tinted := false
	for mesh: MeshInstance3D in _meshes(gem_node):
		var mat := mesh.material_override
		if mat is StandardMaterial3D and (mat as StandardMaterial3D).emission_enabled:
			emissive = true
			tinted = (mat as StandardMaterial3D).albedo_color.is_equal_approx(
				Color.html(String(GameData.materials["emeraude"]["color"])))
	_check("gemme émissive (visible de nuit)", emissive)
	_check("gemme à la couleur de la pierre", tinted)

	plain_node.queue_free()
	gem_node.queue_free()


func _count_meshes(node: Node) -> int:
	return _meshes(node).size()


func _meshes(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out.append(node)
	for child in node.get_children():
		out.append_array(_meshes(child))
	return out

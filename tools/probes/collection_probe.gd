extends Probe
## Sonde `--probe-collection` — le cabinet de curiosités.
##
## Ce que cette sonde défend : **offrir DÉTRUIT**. C'est la règle qui donne sa
## valeur à toute la collection, et c'est aussi celle qu'une refonte ultérieure
## sera tentée d'assouplir « pour être moins punitif ». Si l'objet survit au
## don, remplir la collection ne coûte plus rien et cesse d'être un objectif.
##
## Elle vérifie aussi le cas inverse, moins évident : un don REFUSÉ ne doit
## RIEN détruire. Une pièce déjà en collection dans une meilleure qualité ne
## s'améliore pas ; consommer quand même l'objet serait une perte sèche que le
## joueur ne comprendrait pas.

const TAG := "COLLECTION"

var _ok := true


func _check(label: String, condition: bool, detail: String = "") -> void:
	if not condition:
		_ok = false
	print("[%s] %s%s : %s" % [TAG, label, "" if detail == "" else " (" + detail + ")",
		"OK" if condition else "ÉCHEC"])


func run() -> void:
	await main.get_tree().process_frame
	_check_catalogue()
	_check_donation_destroys()
	_check_refusal_preserves()
	_check_quality_upgrade()
	_check_persistence()
	finish(_ok, TAG)


func _check_catalogue() -> void:
	var catalogue := Collection.catalogue()
	_check("catalogue non vide", catalogue.size() > 20, "%d pièces" % catalogue.size())
	# Objets ET ressources : une collection qui ignorerait les butins de chasse
	# serait à moitié vide sans que rien ne l'explique.
	var has_item := catalogue.has("epee")
	var has_resource := false
	for key: String in catalogue:
		if GameData.resources.has(key):
			has_resource = true
			break
	_check("objets craftables présents", has_item)
	_check("ressources de créature présentes", has_resource)
	_check("aucun doublon", catalogue.size() == _unique(catalogue).size())


func _check_donation_destroys() -> void:
	var collection: Collection = player.collection
	collection.entries.clear()
	var sword := ItemFactory.craft("epee", {"bois": "chene", "minerai": "fer"}, 1.0)
	player.inventory.add_object(sword)
	var uid := int(sword["uid"])
	var before: int = player.inventory.objects.size()

	var key: String = player.call("donate_to_collection", uid)
	_check("le don est accepté", key == "epee", key)
	_check("la pièce entre en collection", collection.has("epee"))
	# LE POINT CENTRAL.
	_check("L'OBJET EST DÉTRUIT", player.inventory.object_by_uid(uid).is_empty())
	_check("l'inventaire a bien perdu une entrée",
		player.inventory.objects.size() == before - 1,
		"%d -> %d" % [before, player.inventory.objects.size()])


func _check_refusal_preserves() -> void:
	var collection: Collection = player.collection
	collection.entries.clear()
	var good := ItemFactory.craft("dague", {"bois": "chene", "minerai": "fer"}, 2.0)
	player.inventory.add_object(good)
	player.call("donate_to_collection", int(good["uid"]))

	# Exemplaire MOINS bon du même type : le don doit être refusé.
	var poor := ItemFactory.craft("dague", {"bois": "chene", "minerai": "fer"}, 0.5)
	player.inventory.add_object(poor)
	var uid := int(poor["uid"])
	var key: String = player.call("donate_to_collection", uid)
	_check("un exemplaire moins bon est refusé", key == "")
	# ET SURTOUT : le refus ne doit rien détruire.
	_check("un don refusé ne détruit RIEN",
		not player.inventory.object_by_uid(uid).is_empty())
	_check("la qualité en collection n'a pas régressé",
		is_equal_approx(collection.quality_of("dague"), 2.0),
		"%.2f" % collection.quality_of("dague"))


func _check_quality_upgrade() -> void:
	var collection: Collection = player.collection
	collection.entries.clear()
	var plain := ItemFactory.craft("masse", {"bois": "chene", "minerai": "fer"}, 1.0)
	player.inventory.add_object(plain)
	player.call("donate_to_collection", int(plain["uid"]))
	var progress_before: int = int(collection.progress()["offerts"])

	var better := ItemFactory.craft("masse", {"bois": "chene", "minerai": "fer"}, 3.0)
	player.inventory.add_object(better)
	var uid := int(better["uid"])
	var key: String = player.call("donate_to_collection", uid)
	_check("un meilleur exemplaire est accepté", key == "masse")
	_check("la qualité en collection progresse",
		is_equal_approx(collection.quality_of("masse"), 3.0),
		"%.2f" % collection.quality_of("masse"))
	_check("le meilleur exemplaire est détruit lui aussi",
		player.inventory.object_by_uid(uid).is_empty())
	# Améliorer ne doit PAS compter comme une pièce de plus : sinon la
	# progression dépasserait le total du catalogue.
	_check("l'avancement ne double pas sur une amélioration",
		int(collection.progress()["offerts"]) == progress_before,
		"%d pièce(s)" % int(collection.progress()["offerts"]))


## Une collection qui ne survit pas au rechargement n'est pas un objectif de
## jeu, c'est une session de jeu.
func _check_persistence() -> void:
	var collection: Collection = player.collection
	collection.entries.clear()
	var axe := ItemFactory.craft("hache_arme", {"bois": "chene", "minerai": "fer"}, 1.6)
	player.inventory.add_object(axe)
	player.call("donate_to_collection", int(axe["uid"]))

	var saved := collection.save_state()
	var restored := Collection.new()
	restored.restore_state(saved)
	_check("la collection survit à une sauvegarde/relecture",
		restored.has("hache_arme"))
	_check("la qualité est conservée",
		is_equal_approx(restored.quality_of("hache_arme"), 1.6),
		"%.2f" % restored.quality_of("hache_arme"))
	# Le joueur sérialise-t-il bien sa collection ? Le test ci-dessus ne prouve
	# que la classe ; c'est le branchement qui casse en silence.
	var player_state: Dictionary = player.call("save_state")
	_check("save_state du joueur porte la collection",
		(player_state.get("collection", {}) as Dictionary).has("entries"))


func _unique(values: Array[String]) -> Array[String]:
	var seen := {}
	var out: Array[String] = []
	for value: String in values:
		if not seen.has(value):
			seen[value] = true
			out.append(value)
	return out

extends Probe
## Sonde `--probe-reseau` (2026-08-08) — LE MODÈLE D'AUTORITÉ.
##
## ---------------------------------------------------------------------------
## POURQUOI ELLE EXISTE
## ---------------------------------------------------------------------------
## Le jeu tient désormais toute partie pour une partie multijoueur : l'autorité
## décide, applique, et ne diffuse que s'il y a quelqu'un. Cette règle n'a de
## valeur que si elle est VÉRIFIÉE — sinon elle redevient ce qu'elle remplace,
## une intention écrite en commentaire pendant que le code garde deux chemins.
##
## Elle se vérifie SANS deux machines, et c'est tout l'intérêt de la forme
## retenue : ce qu'on défend, ce sont des invariants de code, pas des paquets.
##   1. En solo, on EST l'autorité. Si ce n'était pas vrai, le jeu solo passerait
##      son temps à envoyer des demandes à un hôte qui n'existe pas.
##   2. Un CLIENT ne décide de rien : il ne fait naître aucune créature et ne
##      fait tourner aucune IA. Deux simulations indépendantes divergeraient dès
##      la première seconde.
##   3. Ce qu'un client CONSTRUIT en obéissant est identique à ce que l'autorité
##      construit en décidant. C'est la promesse « un seul chemin » ; si les deux
##      divergeaient, le multijoueur montrerait deux mondes différents et le
##      solo ne s'en apercevrait jamais.
##   4. Un message REJOUÉ ne dédouble rien. Un paquet fiable peut arriver deux
##      fois après une reconnexion, et une créature dédoublée est un ennemi
##      fantôme que personne ne peut tuer.

const TAG := "RESEAU"

var _ok := true


func _expect(condition: bool, message: String) -> void:
	print("[%s] %s — %s" % [TAG, "ok" if condition else "ÉCHEC", message])
	if not condition:
		_ok = false


func run() -> void:
	await wait_frame()
	CreatureManager.natural_spawn_enabled = false
	_check_authority_in_solo()
	_check_client_decides_nothing()
	_check_same_construction()
	_check_replay()
	finish(_ok, TAG)


## 1. EN SOLO, ON EST L'AUTORITÉ.
func _check_authority_in_solo() -> void:
	_expect(NetworkManager.is_authority(),
		"une partie solo est autoritaire (sinon elle demanderait à un hôte absent)")
	_expect(not NetworkManager.has_peers(),
		"et elle n'a personne à qui diffuser (aucun paquet émis pour rien)")
	# Le monde doit accepter une mutation par le chemin normal, celui-là même
	# qui sert en réseau.
	var pos := Vector3i(900, 200, 900)
	var dirt: int = GameData.material_runtime_ids.get("terre", 1)
	WorldManager.set_block(pos, dirt)
	_expect(WorldManager.block_at_world(pos) == dirt,
		"une mutation passe par le chemin d'autorité et atterrit")
	WorldManager.set_block(pos, 0)


## 2. UN CLIENT NE DÉCIDE DE RIEN.
func _check_client_decides_nothing() -> void:
	var before := CreatureManager.creatures.size()
	# On se déclare client le temps du test. C'est la seule façon d'exercer la
	# branche « je ne décide pas » sans monter une vraie session.
	NetworkManager.is_client = true
	var refused: Node = CreatureManager.spawn("bandit", player.get_position_for_ai() + Vector3(3, 0, 0))
	_expect(refused == null and CreatureManager.creatures.size() == before,
		"un client ne fait naître AUCUNE créature de sa propre initiative")
	# Et son tick ne fait pas tourner l'IA : on le déclenche à la main et on
	# vérifie qu'il rend la main sans rien décider.
	var positions: Array[Vector3] = []
	for creature in CreatureManager.creatures:
		positions.append(creature.logical_position)
	CreatureManager._on_tick(0)
	var moved := false
	for index in CreatureManager.creatures.size():
		if index < positions.size() 				and CreatureManager.creatures[index].logical_position != positions[index]:
			moved = true
	_expect(not moved, "et son tick ne fait bouger personne (aucune IA côté client)")
	NetworkManager.is_client = false


## 3. LES DEUX CONSTRUCTIONS SONT IDENTIQUES.
func _check_same_construction() -> void:
	var spot: Vector3 = player.get_position_for_ai() + Vector3(5, 0, 0)
	var decided: Node = CreatureManager.spawn("bandit", spot)
	if decided == null:
		_expect(false, "l'autorité peut faire naître une créature")
		return
	_expect(int(decided.net_id) > 0,
		"une créature née par décision reçoit un identifiant réseau (%d)" % int(decided.net_id))
	_expect(CreatureManager.by_net_id(int(decided.net_id)) == decided,
		"et on la retrouve par cet identifiant")

	# Le MÊME appel que celui d'un client qui obéit.
	CreatureManager.apply_remote_spawn(9001, "bandit", spot + Vector3(0, 0, 2), &"overworld")
	var obeyed := CreatureManager.by_net_id(9001)
	_expect(obeyed != null, "un client construit bien la créature qu'on lui annonce")
	if obeyed == null:
		return
	# CE QU'ON COMPARE : les champs qui font la créature. Deux constructions qui
	# divergeraient donneraient deux mondes différents sans que le solo le voie.
	var same: bool = String(obeyed.creature_id) == String(decided.creature_id) 		and String(obeyed.dimension) == String(decided.dimension) 		and is_equal_approx(float(obeyed.health), float(decided.health)) 		and obeyed.get_script() == decided.get_script()
	_expect(same, "décider et obéir construisent la MÊME créature (espèce, dimension, PV, script)")

	# La mort la retire des deux registres — sans quoi un identifiant recyclé
	# désignerait un cadavre.
	var net_id := int(decided.net_id)
	CreatureManager.despawn(decided)
	_expect(CreatureManager.by_net_id(net_id) == null,
		"une créature retirée ne répond plus à son identifiant")
	CreatureManager.despawn(obeyed)


## 4. UN MESSAGE REJOUÉ NE DÉDOUBLE RIEN.
func _check_replay() -> void:
	var spot: Vector3 = player.get_position_for_ai() + Vector3(7, 0, 0)
	CreatureManager.apply_remote_spawn(9100, "bandit", spot, &"overworld")
	var count := CreatureManager.creatures.size()
	CreatureManager.apply_remote_spawn(9100, "bandit", spot, &"overworld")
	_expect(CreatureManager.creatures.size() == count,
		"annoncer deux fois la même créature n'en crée qu'une")
	var ghost := CreatureManager.by_net_id(9100)
	if ghost != null:
		CreatureManager.despawn(ghost)

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
	_check_registries()
	_check_remote_player()
	_check_duels()
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


## 5. LES REGISTRES POSITIONNELS. Objets posés, pousses, coffres : quatre
## registres de même forme, donc une même façon de se répliquer — et une même
## façon de se tromper si l'un s'en écarte.
##
## CE QU'ON DÉFEND : qu'appliquer un message distant produise EXACTEMENT l'état
## qu'aurait produit le geste local. Si les deux divergeaient, deux joueurs
## verraient deux mondes et le solo ne le saurait jamais.
func _check_registries() -> void:
	var pos := Vector3i(950, 210, 950)

	# OBJET POSÉ : l'instance doit revenir INTACTE (qualité, matériaux, usure).
	# C'est la même promesse que la reprise en main : un objet reconstruit
	# depuis sa fiche serait un objet neuf.
	var sword := ItemFactory.craft("epee", {"bois": "chene", "minerai": "fer"}, 0.42)
	sword["usure"] = 0.71
	PlacedItemManager.apply_remote_placed(pos, sword, 2, &"overworld")
	var back := PlacedItemManager.peek(pos)
	_expect(not back.is_empty()
			and is_equal_approx(float(back.get("quality", -1.0)), 0.42)
			and is_equal_approx(float(back.get("usure", -1.0)), 0.71),
		"un objet posé annoncé à distance garde son exemplaire exact")
	_expect(int((PlacedItemManager.placed[pos] as Dictionary).get("yaw", -1)) == 2,
		"et son orientation, qui est diffusée en ÉTAT et non en geste")
	PlacedItemManager.apply_remote_removed(pos)
	_expect(PlacedItemManager.peek(pos).is_empty(), "et son retrait annoncé l'efface")

	# POUSSE : la miniature est RECONSTRUITE, pas transmise — elle est
	# déterministe par position. On vérifie que le registre la retient avec son
	# instant de plantation, qui décide de sa croissance.
	var species := ""
	for id: String in GameData.trees:
		species = id
		break
	SaplingManager.apply_remote_sapling(pos, species, 1234, &"overworld")
	var sapling: Dictionary = SaplingManager.saplings.get(pos, {})
	_expect(String(sapling.get("species", "")) == species
			and int(sapling.get("planted", -1)) == 1234,
		"une pousse annoncée garde son essence ET son instant de plantation")
	SaplingManager.apply_remote_removed(pos)
	_expect(not SaplingManager.saplings.has(pos), "et son retrait l'efface")

	# COFFRE : c'est le CONTENU ENTIER qui voyage, pas le mouvement d'objet.
	# Deux joueurs puisant dans le même coffre à la même seconde sont le cas où
	# une grammaire incrémentale se désynchronise.
	ContainerManager.apply_remote_contents(pos, {"or": 7})
	_expect(int((ContainerManager.contents(pos) as Dictionary).get("or", 0)) == 7,
		"le contenu d'un coffre s'applique tel qu'annoncé")


## 6. CE QU'ON VOIT D'UN AUTRE JOUEUR.
##
## Un joueur distant était un mannequin DÉSARMÉ et sans geste : on ne voyait ni
## ce qu'il tenait, ni qu'il armait un coup, ni de quel côté. Dans un jeu où
## l'on pare EN LISANT LE CORPS de l'adversaire, ça ne rend pas le duel
## imparfait, ça le rend impossible.
##
## CE QU'ON DÉFEND : que le geste diffusé décrive VRAIMENT ce que le joueur
## fait, dans le vocabulaire que le corps sait rejouer. Un dictionnaire vide ou
## figé passerait toutes les autres assertions du réseau sans que rien ne
## bouge à l'écran.
func _check_remote_player() -> void:
	var vocabulaire := ["port", "windup", "armee", "strike", "recover", "garde"]

	var at_rest: Dictionary = player.combat_gesture()
	_expect(String(at_rest.get("phase", "")) == "port",
		"au repos, le geste annoncé est le port d'arme")

	# GARDE LEVÉE : la phase doit le dire. C'est ce qui permet à l'adversaire de
	# voir de quel côté on s'est protégé, donc de choisir l'autre.
	player.call("_set_guard", true)
	var guarding: Dictionary = player.combat_gesture()
	_expect(String(guarding.get("phase", "")) == "garde",
		"une garde levée s'annonce comme une garde, avec son côté")
	player.call("_set_guard", false)

	# ATTAQUE ENGAGÉE : la phase doit suivre la machine à états, et la direction
	# être celle du coup qui part.
	player.call("_begin_attack")
	var swinging: Dictionary = player.combat_gesture()
	_expect(String(swinging.get("phase", "")) in vocabulaire
			and String(swinging.get("phase", "")) != "port",
		"un coup engagé s'annonce dans une phase de combat (%s)" % swinging.get("phase", ""))
	_expect(int(swinging.get("direction", -1)) >= 0,
		"et il annonce SA direction, celle que l'adversaire doit lire")

	# LE VOCABULAIRE EST CELUI DU CORPS. S'il en dérivait, le message
	# arriverait et ne produirait aucune pose — un avatar figé pendant qu'on se
	# fait frapper, sans qu'aucune assertion ne bronche.
	var body: Node = main.get_node_or_null("PlayerBody")
	_expect(body != null and body.has_method("set_combat_pose"),
		"le corps sait rejouer ce vocabulaire (set_combat_pose)")


## 7. LE PVP PASSE PAR UNE DEMANDE DE DUEL (2026-08-08).
##
## CE QU'ON DÉFEND. Sans porte d'entrée, deux joueurs qui se croisent peuvent se
## frapper, et l'on ne peut plus construire à côté de quelqu'un sans risquer
## d'être tué par un coup mal placé. Le duel rend l'affrontement CONSENTI.
##
## L'arbitrage est le vrai sujet. Un duel n'est pas une case cochée chez chacun :
## c'est un fait tenu par l'hôte. Si chaque camp gardait sa propre idée de « je
## suis en duel avec untel », un message perdu suffirait à ce qu'un joueur se
## croie en duel quand l'autre non — et le second se ferait frapper sans pouvoir
## répondre. On vérifie donc les REFUS autant que les acceptations : c'est ce
## qu'un système d'autorisation doit prouver, et c'est ce qu'on oublie de tester.
func _check_duels() -> void:
	DuelManager.pending.clear()
	DuelManager.active.clear()

	# LA PAIRE EST ORDONNÉE. Sans ça « 3 contre 7 » et « 7 contre 3 » seraient
	# deux duels distincts, et l'un des deux joueurs pourrait frapper sans être
	# frappé — l'asymétrie la plus injuste possible.
	_expect(DuelManager.pair_key(3, 7) == DuelManager.pair_key(7, 3),
		"une paire de duel se lit dans les deux sens")

	# ON N'ACCEPTE PAS UN DUEL QUE PERSONNE N'A PROPOSÉ.
	_expect(not DuelManager.open_duel(3, 7),
		"sans demande, aucun duel ne s'ouvre (on ne se provoque pas soi-même par surprise)")
	DuelManager.pending[3] = 7
	_expect(DuelManager.open_duel(3, 7), "une demande acceptée ouvre le duel")
	_expect(DuelManager.is_dueling(3, 7) and DuelManager.is_dueling(7, 3),
		"et il vaut pour LES DEUX, dans les deux sens")
	_expect(not DuelManager.is_dueling(3, 9),
		"il ne vaut pas pour un tiers qui n'a rien demandé")
	_expect(not DuelManager.is_dueling(5, 5),
		"et personne n'est en duel avec soi-même")

	# LA DEMANDE EST CONSOMMÉE : l'accepter deux fois ne rouvre rien, sinon un
	# message rejoué ferait réapparaître un duel qu'on vient de clore.
	_expect(not DuelManager.open_duel(3, 7),
		"une demande déjà acceptée ne se rejoue pas")

	# UN JOUEUR QUI PART EMPORTE SES DUELS. Sans ça sa paire resterait ouverte,
	# et le prochain joueur héritant de son identifiant se retrouverait en duel
	# sans l'avoir demandé.
	DuelManager.forget_peer(7)
	_expect(not DuelManager.is_dueling(3, 7),
		"un joueur qui se déconnecte emporte ses duels avec lui")
	DuelManager.active.clear()

	# LE DUEL AUTORISE, MAIS IL FAUT AUSSI QUE LE COUP TOUCHE. C'est le manque
	# que j'ai signalé en livrant l'arbitrage : les dégâts étaient permis, et
	# rien ne les produisait — la lame traversait l'adversaire sans rien lui
	# retirer, parce que le balayage ne testait que les créatures.
	var body: Node3D = preload("res://scenes/entities/player_body.gd").new()
	main.add_child(body)
	body.setup(false)
	body.set("duel_peer_id", 42)
	body.set("logical_position", Vector3(100, 60, 100))
	# Un segment qui traverse le TORSE, à hauteur d'homme.
	var through: Dictionary = body.call("sweep_segment",
		Vector3(99.0, 61.0, 100.0), Vector3(101.0, 61.0, 100.0))
	_expect(not through.is_empty(),
		"un corps de joueur se fait toucher par le balayage d'arme%s" % (
			"" if through.is_empty() else " (zone %s)" % through.get("id", "?")))
	# ET IL A DES ZONES, comme une créature : sans elles, une tête et un pied
	# vaudraient le même coup, et tout le travail de visée serait perdu.
	_expect(float(through.get("mult", 0.0)) > 0.0,
		"et la zone touchée porte son multiplicateur (%.2f)" % float(through.get("mult", 0.0)))

	# UN JOUEUR QUI N'EST PAS UNE CIBLE NE BLOQUE RIEN. `duel_peer_id` à zéro,
	# c'est le corps du joueur LOCAL : la lame doit passer au travers, sinon on
	# arrêterait un coup destiné à la créature derrière.
	body.set("duel_peer_id", 0)
	var ignored: Dictionary = body.call("sweep_segment",
		Vector3(99.0, 61.0, 100.0), Vector3(101.0, 61.0, 100.0))
	_expect(ignored.is_empty(),
		"et un corps qui n'est pas une cible laisse la lame passer")
	body.queue_free()

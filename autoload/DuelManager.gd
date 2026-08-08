extends Node
## DUELS (2026-08-08, décision de l'auteur : « le pvp marche par demande de
## duel »).
##
## ---------------------------------------------------------------------------
## POURQUOI LE PVP PASSE PAR UNE DEMANDE
## ---------------------------------------------------------------------------
## Sans porte d'entrée explicite, deux joueurs qui se croisent peuvent se frapper
## — et dans un jeu de construction, ça veut dire qu'on ne peut pas jouer à côté
## de quelqu'un sans risquer d'être tué par un coup mal placé. La demande de duel
## rend l'affrontement CONSENTI par les deux camps : c'est le seul état dans
## lequel un joueur peut en blesser un autre.
##
## ---------------------------------------------------------------------------
## L'AUTORITÉ ARBITRE, ET C'EST TOUT LE POINT
## ---------------------------------------------------------------------------
## Un duel n'est PAS une case cochée chez chacun : c'est un fait tenu par
## l'hôte. Si chaque camp gardait sa propre idée de « je suis en duel avec
## untel », il suffirait d'un message perdu pour qu'un joueur se croie en duel
## quand l'autre non — et le second se ferait frapper sans pouvoir répondre.
## L'hôte tient la liste, l'hôte valide les dégâts, l'hôte annonce.
##
## En solo, tout ceci ne fait rien : `has_peers()` est faux, aucun message n'est
## émis, et il n'y a personne à provoquer. Le code n'en est pas moins exercé —
## c'est la règle posée le 2026-08-08.

## Demandes en attente : id du demandeur → id du destinataire.
var pending := {}
## Duels en cours, chez l'AUTORITÉ : paires ordonnées { "a|b": true }.
var active := {}


## Clé canonique d'une paire. ORDONNÉE (le plus petit d'abord) : sans ça
## « 3 contre 7 » et « 7 contre 3 » seraient deux duels différents, et l'un des
## deux joueurs pourrait frapper sans être frappé.
static func pair_key(a: int, b: int) -> String:
	return "%d|%d" % [mini(a, b), maxi(a, b)]


## Ces deux joueurs sont-ils en duel ? SEULE QUESTION que le combat pose.
func is_dueling(a: int, b: int) -> bool:
	return a != b and active.has(pair_key(a, b))


## Demande un duel à `target_peer`. Rien ne se passe en solo : il n'y a
## personne à provoquer, et c'est un état parfaitement normal.
func request(target_peer: int) -> bool:
	if target_peer <= 0 or not NetworkManager.is_multiplayer_active():
		return false
	NetworkManager.rpc_duel_request.rpc_id(target_peer)
	return true


## Le destinataire répond. Seule l'AUTORITÉ ouvre réellement le duel : la
## réponse lui est adressée, et c'est elle qui annonce aux deux camps.
func respond(requester_peer: int, accepted: bool) -> void:
	NetworkManager.rpc_duel_response.rpc_id(1, requester_peer, accepted)


## Ouverture, côté autorité. Retourne false si la demande n'existe pas — on ne
## peut pas accepter un duel que personne n'a proposé.
func open_duel(requester: int, accepter: int) -> bool:
	if requester == accepter or requester <= 0 or accepter <= 0:
		return false
	if int(pending.get(requester, -1)) != accepter:
		return false
	pending.erase(requester)
	active[pair_key(requester, accepter)] = true
	return true


func close_duel(a: int, b: int) -> void:
	active.erase(pair_key(a, b))


## Un joueur part : tous ses duels s'arrêtent. Sans ça, sa paire resterait
## ouverte et le prochain joueur qui hériterait de son identifiant se
## retrouverait en duel sans l'avoir demandé.
func forget_peer(peer_id: int) -> void:
	pending.erase(peer_id)
	for requester: int in pending.keys():
		if int(pending[requester]) == peer_id:
			pending.erase(requester)
	for key: String in active.keys():
		for part in key.split("|"):
			if int(part) == peer_id:
				active.erase(key)
				break


func count() -> int:
	return active.size()

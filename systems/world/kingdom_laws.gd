class_name KingdomLaws
extends RefCounted
## Lois des royaumes, infractions et conséquences (GDD 14.4 / B.9 / E.26).
##
## CE QUI REND UN ROYAUME RÉEL. Sans lois, un royaume n'est qu'une teinte sur
## une carte : on le traverse sans que rien ne change. Ce sont ses lois qui font
## qu'entrer sur son territoire est une décision — et qu'en sortir en est une
## autre, puisque « hors royaume = aucune loi » (14.4).
##
## LE PRINCIPE QUI STRUCTURE TOUT : une infraction n'a de conséquence QUE SI
## ELLE EST REPÉRÉE (E.26). Pas de karma caché, pas de journal secret. Tuer un
## homme seul au fond d'un bois ne coûte rien, et c'est cohérent avec le reste
## du jeu — ce qui n'est pas vu n'existe pas. C'est aussi ce qui rend la
## Discrétion utile en dehors du vol.
##
## LES LOIS SONT GÉNÉRÉES, PAS ÉCRITES. Le monde est infini : on ne peut pas
## rédiger `data/kingdoms/*.json` pour chaque royaume. Elles sont donc dérivées
## de la capitale, comme le reste de l'identité du royaume. Le GDD y invite
## explicitement en réclamant des lois arbitraires — « la pomme est totalement
## illégale » — dont il note qu'elles sont « simples à générer, de grande valeur
## comique, pour un coût de contenu quasi nul ».

## Lois de comportement communes, avec leur conséquence. Toutes les
## gouvernances ne les portent pas : c'est ce qui différencie un royaume d'un
## autre autrement que par sa couleur.
const BEHAVIOUR_LAWS := [
	{"id": "loi_meurtre", "target": "meurtre", "consequence": "gardes_hostiles"},
	{"id": "loi_vol", "target": "vol", "consequence": "amende:50"},
	{"id": "loi_agression", "target": "agression", "consequence": "amende:20"},
]

## Une anarchie n'a pas de lois : « un royaume sans gardes ne peut mécaniquement
## pas faire appliquer ses lois — la loi y est décorative par construction »
## (14.4). Plutôt que de lui en donner d'inapplicables, on n'en donne aucune.
const LAWLESS_GOVERNMENTS := ["anarchie"]

const SEED_LAWS := 51137


## Lois d'un royaume. Retourne [] pour une anarchie ou hors royaume.
static func laws_of(kingdom: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if kingdom.is_empty():
		return out
	var government := String(kingdom.get("government_type", ""))
	if government in LAWLESS_GOVERNMENTS:
		return out

	var capital: Vector2i = kingdom.get("capital", Vector2i.ZERO)
	var hash_value := NoiseGenerator.pcg_hash(capital.x, capital.y, SEED_LAWS)

	# Le meurtre est illégal PARTOUT sauf en anarchie : un royaume qui tolère
	# qu'on tue ses sujets n'a pas de sujets très longtemps. Les deux autres
	# lois de comportement varient.
	out.append(BEHAVIOUR_LAWS[0].duplicate())
	for index in range(1, BEHAVIOUR_LAWS.size()):
		if (hash_value >> (index * 3)) % 4 != 0:
			out.append(BEHAVIOUR_LAWS[index].duplicate())

	# LOI ARBITRAIRE : un objet courant, interdit sans raison. Un royaume sur
	# deux en a une. C'est du flavor assumé (esprit Elona/Elin), et c'est ce
	# qu'un joueur racontera à quelqu'un d'autre.
	if hash_value % 2 == 0:
		var candidates := _bannable_items()
		if not candidates.is_empty():
			out.append({"id": "loi_objet", "type": "objet",
				"target": candidates[hash_value % candidates.size()],
				"consequence": "confiscation"})
	return out


## Objets susceptibles d'être interdits : ceux qu'on porte couramment. Interdire
## une pièce d'armure de haut niveau ne ferait rire personne, parce que personne
## ne l'aurait sur soi en traversant la frontière.
static func _bannable_items() -> Array[String]:
	var out: Array[String] = []
	for item_id: String in GameData.items:
		var item: Dictionary = GameData.items[item_id]
		if String(item.get("type", "")) in ["outil", "arme", "ressource"]:
			out.append(item_id)
	out.sort()
	return out


## L'objet `item_id` est-il illégal dans ce royaume ?
static func item_is_banned(kingdom: Dictionary, item_id: String) -> bool:
	for law: Dictionary in laws_of(kingdom):
		if String(law.get("type", "")) == "objet" and String(law["target"]) == item_id:
			return true
	return false


## Loi correspondant à un comportement, ou {} si le royaume ne l'interdit pas.
static func law_for(kingdom: Dictionary, behaviour: String) -> Dictionary:
	for law: Dictionary in laws_of(kingdom):
		if String(law.get("type", "comportement")) == "comportement" \
				and String(law["target"]) == behaviour:
			return law
	return {}


# --- Détection ----------------------------------------------------------------

## Rayon dans lequel un PNJ peut témoigner. Généreux : un crime commis sur la
## place d'un village doit être vu, sinon la loi ne s'appliquerait jamais là où
## elle compte le plus.
const WITNESS_RANGE := 24.0


## Y a-t-il un témoin, et l'infraction est-elle repérée ?
##
## Jet opposé Discrétion du joueur contre Perception du témoin le plus proche
## (E.3/E.26). AUCUN témoin dans le rayon → l'infraction est ignorée, purement
## et simplement. C'est le cœur du système : on ne punit pas ce qui n'est pas vu.
static func is_witnessed(player: Node, position: Vector3, creatures: Array) -> bool:
	var witness: Node = null
	var best := WITNESS_RANGE
	for creature: Variant in creatures:
		if creature == null or not is_instance_valid(creature):
			continue
		if creature.is_dead():
			continue        # un mort ne témoigne pas
		if String(creature.ai_profile) not in ["civil", "garde"]:
			continue        # une bête ne porte pas plainte
		var distance: float = creature.logical_position.distance_to(position)
		if distance < best:
			best = distance
			witness = creature
	if witness == null:
		return false

	# Jet de compétence universel (E.3) : 1d20 + compétence/2 + stat/4.
	var stealth := float(player.skills.level("discretion")) * 0.5 \
		+ float(player.stats.get("dexterite", 5)) * 0.25
	var perception := float(witness.stats.get("dexterite", 5)) * 0.25 \
		+ float(witness.weapon_level) * 0.5
	# Un garde voit mieux : c'est son métier, et c'est ce qui rend le fait de
	# les éliminer d'abord une vraie tactique de criminel.
	if String(witness.job) == "garde":
		perception += 4.0
	return randi_range(1, 20) + perception >= randi_range(1, 20) + stealth


# --- Conséquences --------------------------------------------------------------

## Applique la conséquence d'une loi enfreinte. Retourne une clé de langue
## décrivant ce qui vient de se passer, ou "" si rien ne s'est appliqué.
##
## LE JOUEUR DOIT SAVOIR. Une amende prélevée en silence se lit comme un bug de
## comptabilité ; une confiscation muette se lit comme un objet perdu. Chaque
## conséquence renvoie donc de quoi l'annoncer — c'est le minimum pour qu'une
## règle soit apprenable.
static func apply(consequence: String, player: Node, kingdom: Dictionary,
		item_id: String = "") -> String:
	if consequence.begins_with("amende:"):
		var amount := int(consequence.split(":")[1])
		if player.gold >= amount:
			player.gold -= amount
			return "ui.loi.amende"
		# « Si insuffisant : confiscation d'objets à la place » (E.26). On prend
		# le plus précieux : une amende qu'on ne peut pas payer doit coûter
		# quelque chose, sinon être fauché devient une immunité.
		return _confiscate_best(player)
	if consequence == "confiscation":
		return _confiscate_item(player, item_id)
	if consequence == "gardes_hostiles":
		# La réputation par ROYAUME s'effondre : ce sont ses gardes qui
		# deviennent hostiles, partout sur son territoire, pas seulement ici.
		player.reputation.record("", Vector2i(1 << 30, 1 << 30), "",
			HOSTILITY_PENALTY, String(kingdom.get("id", "")))
		return "ui.loi.gardes_hostiles"
	return ""


## Chute de réputation infligée par un crime grave. Assez forte pour franchir le
## seuil d'hostilité (−50) en deux ou trois meurtres témoignés, pas en un seul :
## une erreur ne doit pas fermer un royaume définitivement.
const HOSTILITY_PENALTY := -70.0


static func _confiscate_item(player: Node, item_id: String) -> String:
	for instance: Dictionary in player.inventory.objects:
		if String(instance.get("item_id", "")) == item_id:
			player.inventory.remove_object_units(instance, 1)
			return "ui.loi.confiscation"
	return ""


static func _confiscate_best(player: Node) -> String:
	var best := {}
	for instance: Dictionary in player.inventory.objects:
		if best.is_empty() or float(instance.get("weight", 0.0)) \
				> float(best.get("weight", 0.0)):
			best = instance
	if best.is_empty():
		return ""
	player.inventory.remove_object_units(best, 1)
	return "ui.loi.saisie"

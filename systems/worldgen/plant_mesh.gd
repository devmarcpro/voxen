class_name PlantMesh
extends RefCounted
## PLANTES EN 2D : UNE IMAGE PLATE, DROITE, TRAVERSABLE (2026-08-04).
##
## ---------------------------------------------------------------------------
## CE QUE C'EST, ET CE QUE ÇA A CESSÉ D'ÊTRE
## ---------------------------------------------------------------------------
## Une plante est UNE CROIX : deux quads verticaux sur les diagonales du bloc,
## dessinés des deux côtés, portant le même sprite. Centrée sur sa case, haute
## d'un bloc — ou de deux pour ce qui dépasse.
##
## La première version construisait des silhouettes en plusieurs quads — lames
## effilées et courbées, épis en fuseau, corolles croisées, pétales inclinés —
## pour imiter un volume. L'auteur a tranché après l'avoir vu à l'écran : « je
## veux que les plantes soient une image plate toute droite ». Il a raison, et
## pas seulement par goût :
##
##   — une silhouette bricolée en quads penchés ne ressemble jamais à la plante,
##     elle ressemble à des quads penchés. Trois tours de retouche l'ont montré :
##     cure-dents, puis guéridons, puis petites tables ;
##   — un plan vertical est le support d'une IMAGE. C'est la voie qui
##     mène à de vraies textures de plantes, où la lisibilité vient du dessin et
##     non de la géométrie — et une image de blé sera toujours plus lisible que
##     n'importe quel assemblage de rectangles ;
##   — et ça coûte seize sommets au lieu de cent.
##
## Un plan UNIQUE a été essayé entre les deux, et il avait un défaut rédhibitoire :
## vu dans son axe, il disparaît par la tranche, et le champ s'évanouit. D'où la
## croix — deux plans perpendiculaires se voient d'où qu'on les regarde.
##
## ---------------------------------------------------------------------------
## DEUX HITBOXES, ET UNE SEULE EST VOULUE
## ---------------------------------------------------------------------------
## On TRAVERSE les plantes en marchant, mais on peut les VISER pour les casser
## et les ramasser. Ce sont deux choses distinctes, et la confusion entre elles
## a coûté un aller-retour : « pas de hitbox » voulait dire le déplacement,
## « une hitbox donc récupérable » voulait dire la visée.
##
## On traverse les plantes. Ce n'est pas un détail de confort : sans ça, un
## champ de blé devient un mur de cubes invisibles qu'il faut sauter un par un.
## La règle est portée par `GameData.cross_mask`, et appliquée aux TROIS endroits
## qui décident de ce qui est solide — la collision du joueur, la ligne de vue
## (une flèche traverse l'herbe) et la recherche de sol des créatures (un
## villageois ne marche pas sur les fleurs).
##
## Ce fichier ne connaît que la géométrie ; c'est le masque qui porte la règle.

## Demi-largeur maximale : une plante ne déborde JAMAIS de son bloc. Un quad qui
## dépasse serait tranché à la frontière de chunk, parce que le mailleur n'émet
## que la géométrie des blocs qu'il possède — le défaut qui a tronqué les
## couronnes d'arbres trop larges pendant des mois.
const MAX_HALF_WIDTH := 0.5


## Le quad d'une plante, en coordonnées LOCALES au bloc porteur : origine au
## centre de la case, y = 0 au sol.
##
## Retourne un Array d'UN quad (PackedVector3Array de 4 sommets). Le contrat
## reste une LISTE parce que le mailleur ne doit pas avoir à changer si une
## plante en réclame deux un jour — une pousse à deux plans, par exemple.
static func build(species: Dictionary, wx: int, wy: int, wz: int, world_seed: int) -> Array:
	# MÊME CASE, MÊME PLANTE. Le hachage porte sur les coordonnées MONDE : un
	# chunk évincé puis regénéré doit rendre exactement le même champ.
	# HAUTEUR EN BLOCS ENTIERS : un bloc, ou deux pour ce qui dépasse (maïs,
	# tournesol, chanvre). Pas de valeur intermédiaire, et c'est délibéré — un
	# sprite de 16 px par bloc ne reste carré que si le quad qui le porte fait
	# exactement un bloc de haut. Une plante de 0,7 bloc écraserait ses pixels
	# verticalement, et le grain cesserait d'être celui du monde.
	var tall := float(species.get("hauteur_image", 0.9)) > 1.0
	var height := 2.0 if tall else 1.0

	# LES DEUX DIAGONALES DU BLOC. C'est la croix : chaque quad va d'un coin au
	# coin opposé, donc la plante remplit sa case exactement et reste CENTRÉE
	# sur elle. Un seul plan disparaissait par la tranche dès qu'on se plaçait
	# dans son axe — deux plans perpendiculaires se voient de partout, et c'est
	# tout l'intérêt du croisement.
	var quads: Array = []
	for turn in 2:
		var a := PI * 0.25 + float(turn) * PI * 0.5
		var half := Vector3(cos(a), 0.0, sin(a)) * (MAX_HALF_WIDTH * 1.41421356)
		var quad := PackedVector3Array()
		quad.resize(4)
		quad[0] = _inside(-half)
		quad[1] = _inside(half)
		quad[2] = _inside(half + Vector3(0.0, height, 0.0))
		quad[3] = _inside(-half + Vector3(0.0, height, 0.0))
		quads.append(quad)
	return quads


## Ramène un point dans l'emprise du bloc porteur (horizontalement seulement :
## une plante a le droit de monter, c'est ce qui distingue un maïs d'une salade).
static func _inside(p: Vector3) -> Vector3:
	return Vector3(
		clampf(p.x, -MAX_HALF_WIDTH, MAX_HALF_WIDTH),
		maxf(p.y, 0.0),
		clampf(p.z, -MAX_HALF_WIDTH, MAX_HALF_WIDTH))


## Hachage déterministe — la même famille que celle des arbres et des POI, pour
## qu'aucun second mécanisme de semis n'apparaisse à côté du premier.
static func _hash(x: int, y: int, z: int, world_seed: int) -> int:
	var v := (x * 747796405 + 2891336453) ^ (y * 1597334677) ^ (z * 2654435761) ^ world_seed
	v = (v ^ (v >> 15)) * 0x85EBCA6B
	v = (v ^ (v >> 13)) * 0xC2B2AE35
	return absi(v ^ (v >> 16))

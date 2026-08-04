# Pièces d'arme (Blockbench)

Une arme du jeu n'est jamais un modèle unique : c'est un **manche** + une
**tête**, assemblés au craft et teintés par les matériaux choisis. Une même
tête de hache montée sur quatre manches donne quatre armes différentes, en
allonge comme en prise en main.

Chaque pièce existe en deux fichiers, générés depuis la même table :

| Fichier | Rôle |
|---|---|
| `manche_<id>.bbmodel` | **projet Blockbench, à ouvrir pour éditer** |
| `manche_<id>.glb` | consommé par le jeu |

Régénérer les deux : `python tools/generate_weapon_parts.py`
Vérifier la cohérence : `godot --headless --path . --script tools/verify_weapon_parts.gd`

---

## Conventions — les cinq règles

**1. L'arme pointe vers +Y.** La base du manche est à `y = 0`, la pointe vers
le haut. Toute la chaîne en dépend : le code greffe la tête au sommet du
manche, puis fait pivoter l'ensemble pour le mettre dans la main.

**2. Échelle : 32 px = 1 bloc**, comme le gabarit humanoïde. Un manche de
22 px fait donc 0,69 bloc.

**3. Le manche occupe `y = 0` → `longueur`, et rien d'autre.** Pas de pommeau
qui descend sous zéro, pas de garde qui dépasse au sommet : c'est exactement à
`y = longueur` que la tête se greffe. Un débordement se traduirait par une tête
enfoncée dans le manche ou flottant au-dessus.

**4. AUCUNE COULEUR.** Les pièces ne portent ni texture ni couleur : la teinte
vient du matériau choisi au craft (chêne, ébène, fer, plomb...). Une pièce
colorée casserait tout le système de matériaux — un manche en plomb et un
manche en balsa doivent se distinguer par leur teinte, pas se ressembler.

**5. Reste centré sur X et Z.** Le manche est tenu sur son axe ; un décalage
latéral déporterait l'arme dans la main.

---

## Les 12 manches : POIGNÉES d'un côté, FÛTS de l'autre

Le catalogue confondait les deux jusqu'au 2026-08-02 : `moyen` faisait 69 cm,
ce qui est une hampe de masse mais **trois fois la poignée d'une épée**.
L'épée se tenait donc au tiers d'un manche, avec 48 cm de bois nu entre le
poing et la lame — et comme la prise décide de l'allonge, cette géométrie
fausse contaminait le gameplay.

**Poignées** — la main les couvre, un pommeau les termine, la lame commence
juste au-dessus du poing.

| id | longueur | armes |
|---|---|---|
| `poignee_dague` | 4 px · 0,125 | dague |
| `poignee_epee` | 6 px · 0,188 | épée, épée courte, rapière |
| `poignee_longue` | 13 px · 0,406 | espadon (main gauche au pommeau) |

**Fûts** — on les tient bas, et la longueur restante fait l'allonge et
l'inertie.

| id | longueur | armes |
|---|---|---|
| `court` | 8 px · 0,250 | hachette, gourdin |
| `moyen` | 13 px · 0,406 | masse, masse à ailettes, pioche de combat |
| `long` | 34 px · 1,062 | hache d'armes, hache double, marteau de guerre |
| `hampe` | 48 px · 1,500 | hallebarde, trident, faux de guerre |
| `hampe_longue` | 64 px · 2,000 | lance |
| `baton` | 46 px · 1,438 | bâton ferré, bâton de canalisation |
| `arc` | 30 px · 0,938 | arc |
| `arbalete` | 18 px · 0,562 | arbalète |
| `poignee` | 4 px · 0,125 | écu, rondache, pavois |

**Hampe et pique sont deux pièces** : une hallebarde fait 1,80 à 2,20 m, une
lance 2,50. Elles n'en faisaient qu'une, poussée à 2,19 m pour qu'un espadon ne
porte pas plus loin qu'une pique ; l'espadon étant repassé de 2,02 à 1,59 m
avec sa vraie poignée, la contrainte s'est desserrée d'elle-même.

Épaisseurs : 3 à 5 px, plus un pommeau optionnel (3ᵉ valeur de `HANDLES`).
Rien n'oblige à un simple cylindre — renflements, garde, enroulement de cuir
sont les bienvenus, tant que la pièce reste dans `y = 0 → longueur`.

---

## Recette et masse : DÉRIVÉES du volume des pièces

Elles étaient tapées à la main et ne suivaient plus rien : le métal consommé
allait de 28 à 424 px³ par unité selon l'arme — un facteur 15 sans
justification —, une masse à une main pesait 2 kg quand un espadon en pesait
2,1, et une hallebarde de 2,80 m était plus légère qu'une masse.

`tools/generate_weapon_parts.py` les recalcule désormais depuis le volume réel
des boîtes :

- **recette** : une unité de matière = `UNIT_VOLUME_PX3` (140 px³) ;
- **`poids_reference`** = masse de cette recette **en chêne et fer**.

Conséquence à connaître : une arme forgée dans ses matériaux de référence
tourne **exactement à sa `vitesse_base`**, et seul un écart à cette référence
la ralentit ou l'accélère. `poids_reference` n'est plus un chiffre à l'estime.

`HEAD_WOOD_SHARE` déclare les têtes qui ne sont pas métalliques : un plateau de
bouclier est une planche cerclée de fer, un gourdin un rondin, des branches
d'arc du bois. Sans ce chiffre, la dérivation ferait forger un écu dans six
lingots.

**Ne modifie donc plus les `inputs` d'une recette ni `poids_reference` à la
main** : le générateur les réécrit. Change la géométrie, ou `UNIT_VOLUME_PX3`.

---

## Longueurs de référence

`--probe-combat` vérifie que chaque arme tombe dans la fourchette de son
équivalent historique (table `REAL_LENGTHS` de la sonde). Au 2026-08-02, les 21
armes y sont : dague 0,38 · épée 0,94 · rapière 1,12 · espadon 1,59 ·
hachette 0,59 · masse 0,69 · hache d'armes 1,41 · bâton 1,72 · trident 1,94 ·
hallebarde 2,12 · lance 2,31 m.

---

## ⚠ LE PIÈGE : la longueur est aussi une donnée de GAMEPLAY

`data/weapon_parts.json` porte pour chaque manche :

```json
"moyen": { "longueur": 0.688, "grip_main": 0.30, "grip_offhand": 0.62 }
```

- **`longueur`** doit correspondre EXACTEMENT à la hauteur du modèle. Elle sert
  à calculer l'**allonge** de l'arme et la position où la tête se greffe.
- **`grip_main` / `grip_offhand`** sont des FRACTIONS de cette longueur : où
  se posent la main forte et la main avant. Ce sont des choix de gameplay,
  pas des mesures — c'est à toi de les régler si tu déplaces la prise.

**Si tu rallonges un manche dans Blockbench sans mettre `longueur` à jour,
l'arme sera visuellement plus longue que sa portée réelle** : elle toucherait
« dans le vide » sur les derniers centimètres, ce qui est exactement le
mensonge visuel que tout le système de combat s'interdit.

Deux façons de rester cohérent, au choix :

1. **Modifier la table du générateur** (`HANDLES` dans
   `tools/generate_weapon_parts.py`) et relancer : il réécrit `longueur` dans
   le JSON tout seul. C'est la voie sûre pour un simple changement de taille.
2. **Éditer dans Blockbench**, exporter, puis **mettre `longueur` à jour à la
   main** dans `data/weapon_parts.json`.

Dans les deux cas, lance ensuite :

```
godot --headless --path . --script tools/verify_weapon_parts.gd
```

Il compare la géométrie réelle de chaque `.glb` aux données et signale tout
écart. C'est le garde-fou de la règle « ce qu'on voit est ce qui touche ».

---

## Boucle de travail

1. Ouvrir `manche_<id>.bbmodel` dans Blockbench (`File > Open Model`).
2. Sculpter. Rester dans `y = 0 → longueur`, centré sur X/Z, sans couleur.
3. `File > Export > Export glTF Model` → écraser `manche_<id>.glb`.
4. Mettre `longueur` à jour si la hauteur a changé.
5. `godot --headless --path . --import`
6. `godot --headless --path . --script tools/verify_weapon_parts.gd`
7. Voir le résultat en jeu : F1 → onglet **Armes** → choisir bois, minerai,
   puis cliquer l'arme. La ligne de statut affiche poids, allonge, wind-up et
   fenêtre de parade de l'exemplaire forgé.

---

## La gemme sertie

Une arme assemblée (donc dotée de `parts`) accepte une **gemme facultative** :
n'importe quel matériau de catégorie `cristal` (10 pierres). Elle se choisit au
craft, à côté des matériaux, et vaut aussi pour le menu de triche (onglet
**Armes**).

**Aucun modèle à faire.** La pierre est un petit cube pivoté, généré par le
code et posé à la jonction manche/tête — le seul point commun à toutes les
armes, quelle que soit la pièce montée. Elle prend la couleur du matériau et
elle est le **seul élément émissif** de l'arme : le rendu du jeu est non
éclairé, une pierre mate serait indiscernable du métal, de jour comme de nuit.

### Ce que la gemme fait — et surtout ce qu'elle ne fait pas

| Effet | Valeur |
|---|---|
| `mana_conductivity` de l'instance | celle de la pierre (support du futur enchantement) |
| Poids | `+ densité × 0,15` (une pierre est **taillée**, pas un bloc) |
| Vitesse de l'arme | légèrement **réduite**, conséquence mécanique du poids |
| Dégâts, dureté, allonge, dés | **strictement inchangés** |

Cette dernière ligne est un choix de conception, pas un oubli. La tentation
permanente sera de faire « ajouter un peu de dégâts » à la gemme ; le jour où
ça arrivera, l'enchantement n'aura plus rien à apporter et le sertissage
deviendra un simple palier de puissance. `--probe-gemme` verrouille donc autant
ce que la gemme NE FAIT PAS que ce qu'elle fait.

    godot --headless --path . -- --probe-gemme

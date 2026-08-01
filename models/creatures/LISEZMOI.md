# Modèles de créatures (Blockbench)

Pipeline figé le 2026-07-26 (GDD 9.1 / 12.1) : **les créatures sont modélisées
et riggées dans Blockbench**, exportées en **glTF / `.glb`**, et importées
nativement par Godot (maillage + squelette + animations).

Les blocs spéciaux, meubles, items et structures restent sur **MagicaVoxel**
(`.vox`, dans `models/`).

## Poser un modèle

1. Exporter depuis Blockbench en `.glb` dans ce dossier, ex. `loup.glb`.
2. Ajouter le chemin dans la fiche de la créature (`data/creatures/loup.json`) :

   ```json
   "model": "res://models/creatures/loup.glb"
   ```

Aucune modification de code n'est nécessaire : `creature.gd` charge le modèle
s'il existe, et retombe sinon sur la **capsule colorée provisoire**. Un chemin
renseigné mais introuvable produit un avertissement clair au démarrage.

## Conventions à respecter

- **Os d'attache d'équipement** (6.2/12.1) : nommer les os `attach_arme`,
  `attach_dos`, `attach_tete`... — ils remplacent les voxels-marqueurs de
  l'ancien pipeline `.vox`.
- **Texture atlas en pixel-art à palette réduite** : la recoloration (variantes
  rares 12.4, statue 1:1 de F.3) se fait par échange de couleurs en shader, ce
  qui suppose des couleurs-clés franches et peu nombreuses.
- **Échelle** : 1 unité Godot = 1 bloc de 32 px.

---

# Gabarit HUMANOÏDE — spécification complète

> **Le gabarit existe déjà** (généré le 2026-07-28), en **deux fichiers issus
> des mêmes tables** — ils ne peuvent pas diverger :
>
> | Fichier | Rôle |
> |---|---|
> | `humanoide.bbmodel` | **projet Blockbench, à ouvrir pour éditer** |
> | `humanoide.glb` | consommé par Godot (devient un `Skeleton3D`) |
>
> C'est un **mannequin cubique sans texture** : le rig est correct et complet,
> l'art reste à faire.
>
> **Pourquoi deux fichiers** : Blockbench **n'importe pas le glTF** (c'est un
> format d'export seulement chez eux). Un `.glb` seul serait un cul-de-sac —
> impossible de retoucher une proportion sans tout re-rigger. Le `.bbmodel`
> est le format de projet natif, donc le seul qui permette de reprendre le
> travail.
>
> - Régénérer les deux : `python tools/generate_humanoid_rig.py`
>   (la géométrie est un tableau lisible en tête du script, pas un binaire
>   opaque — ajuster une proportion = éditer `BONES`/`BODY`).
> - Valider n'importe quel modèle : `godot --headless --path . --script tools/verify_rig.gd`

Figée le 2026-07-28. Ce gabarit sert **à la fois aux PNJ/monstres humanoïdes
et au JOUEUR** (décision utilisateur : corps visible en première personne,
pieds et bras compris, et avatar visible des autres joueurs en multijoueur).

Trois systèmes lisent ce rig, et chacun impose ses contraintes ; elles sont
toutes justifiées ci-dessous plutôt qu'assénées, pour qu'on sache lesquelles
sont négociables :

| Système | Ce qu'il exige |
|---|---|
| IK (cinématique inverse) | chaînes de **2 os exactement** |
| Démembrement | **un maillage par os**, jamais à cheval |
| Première personne | **tête masquable seule** |
| Combat directionnel | os d'attache d'arme aux **deux** mains |

## 1. Type de projet Blockbench

**« Generic Model »** (ou « Modded Entity »). Un projet **« Java Block/Item »
n'exporte PAS de squelette** — l'export glTF sortirait un maillage sans os et
tout l'IK tomberait à l'eau. Si le modèle a été commencé en Java Block/Item :
`File > Convert Project > Generic Model`.

Dans Blockbench, **chaque groupe (dossier) devient un os**. La hiérarchie de
groupes EST le squelette.

## 2. Échelle et origine

- **Hauteur totale : 2,0 unités** = 2 blocs = **64 px** à 32 px/bloc.
  C'est `PLAYER_HEIGHT` dans `scenes/entities/fly_camera.gd`, la source de
  vérité de la collision — un modèle plus grand traverserait les plafonds.
- **Pieds à y = 0**, personnage centré sur x = 0 et z = 0.
- **Face tournée vers −Z** (convention Godot : `-basis.z` est l'avant).
- Les yeux tombent à **1,9 unité** (`EYE_HEIGHT` = 60,8 px) : la tête doit
  englober cette hauteur, sinon la caméra première personne sort du crâne.

Les proportions internes sont libres. Les zones de coup
(`data/hitbox_templates.json`) seront **recalées sur le modèle réel** — inutile
de viser des dimensions précises, seule la hauteur totale est contraignante.

## 3. Nommage des os

Français, `snake_case`. **Déviation assumée** de la convention « identifiants
en anglais » du projet : ces noms sont de la donnée d'asset, ils prolongent les
`attach_*` déjà figés plus haut, et surtout ils doivent correspondre **mot pour
mot** aux identifiants de zones de `data/hitbox_templates.json` — un seul
vocabulaire entre le rig, les hitboxes et le démembrement.

```
racine                          (y = 0, aux pieds)
└── bassin
    ├── colonne_1               \ 2 os obligatoires : le pitch caméra est
    │   └── colonne_2           / réparti dessus (buste qui se penche)
    │       ├── cou
    │       │   └── tete
    │       │       └── attach_tete
    │       ├── attach_dos
    │       ├── epaule_gauche
    │       │   └── bras_gauche          \
    │       │       └── avantbras_gauche  > chaîne de 2 os
    │       │           └── main_gauche  /
    │       │               └── attach_arme_gauche
    │       └── epaule_droite
    │           └── bras_droit           \
    │               └── avantbras_droit   > chaîne de 2 os
    │                   └── main_droite  /
    │                       └── attach_arme
    ├── cuisse_gauche                    \
    │   └── mollet_gauche                 > chaîne de 2 os
    │       └── pied_gauche              /
    └── cuisse_droite                    \
        └── mollet_droite                 > chaîne de 2 os
            └── pied_droite              /
```

**Pourquoi 2 os et pas plus** : un solveur analytique à deux os (loi des
cosinus) résout l'angle en une opération. Un os de plus dans la chaîne force un
solveur itératif (FABRIK/CCDIK) — coût sans commune mesure sur la machine
cible (Intel UHD 620, `gl_compatibility`). Les `epaule_*` sont HORS chaîne
(elles ne sont pas résolues par l'IK, elles la portent) : elles sont donc
facultatives, mais recommandées pour un haussement d'épaules crédible.

`attach_arme` est sur la main **droite** — c'est le nom déjà figé pour toutes
les créatures, on ne le renomme pas. La gauche prend le nom explicite.

## 4. Maillages : un objet par os

Chaque segment de chair est un **objet de maillage distinct**, pesé à **1.0 sur
un seul os**. Aucun cube ne chevauche deux os ; les segments se recouvrent
légèrement aux articulations (coude, genou) pour ne pas laisser de trou.

```
mesh_tete           mesh_torse            mesh_bras_gauche
mesh_cheveux        mesh_bassin           mesh_avantbras_gauche
                                          mesh_main_gauche
mesh_cuisse_gauche  mesh_mollet_gauche    mesh_pied_gauche
mesh_cuisse_droite  mesh_mollet_droite    mesh_pied_droite
                                          mesh_bras_droit ... (idem à droite)
```

**Deux raisons, et elles ne sont pas cosmétiques :**

1. **Démembrement** : trancher se fait en passant l'échelle d'un os à
   `Vector3.ZERO` (coût ≈ 0 ms). Un cube à cheval sur deux os s'étirerait au
   lieu de disparaître, et il n'y aurait pas de coupe nette.
2. **Première personne** : `mesh_tete` et `mesh_cheveux` sont **masqués pour le
   joueur local uniquement** (la caméra est dans le crâne — sans ça, on voit
   l'intérieur de son propre visage). Ils restent visibles pour les autres
   joueurs. C'est impossible si la tête partage son maillage avec le torse.

## 4 bis. Découpage concret : les 18 cubes

Dimensions en **pixels à 32 px/bloc**, personnage de **64 px** (2 blocs). Y = 0
aux pieds. `droite` = **+X**, `gauche` = **−X** (le personnage regarde vers −Z,
donc vu de dos sa main droite est bien à droite de l'écran).

Ces valeurs sont un point de départ cohérent, pas un dogme : ajuste les
proportions à ton goût, seule la **hauteur totale de 64 px** est contraignante.
Les zones de coup seront recalées sur le modèle final.

### Jambes (× 2 : suffixe `_gauche` / `_droite`)

| Groupe (os) | Cube (maillage) | Taille L×H×P | Y de … à | Pivot |
|---|---|---|---|---|
| `cuisse_gauche` | `mesh_cuisse_gauche` | 8 × 13 × 9 | 15 → 28 | **28** (hanche) |
| `mollet_gauche` | `mesh_mollet_gauche` | 7 × 13 × 8 | 3 → 16 | **16** (genou) |
| `pied_gauche` | `mesh_pied_gauche` | 7 × 4 × 10 | 0 → 4 | **4** (cheville) |

Le pied déborde vers l'**avant** (−Z) : profondeur 10 contre 8 pour le mollet.

### Tronc

| Groupe (os) | Cube (maillage) | Taille L×H×P | Y de … à | Pivot |
|---|---|---|---|---|
| `bassin` | `mesh_bassin` | 17 × 6 × 9 | 28 → 34 | **28** |
| `colonne_1` | `mesh_torse_bas` | 17 × 8 × 9 | 34 → 42 | **34** |
| `colonne_2` | `mesh_torse_haut` | 18 × 9 × 9 | 41 → 50 | **41** |
| `cou` | `mesh_cou` | 6 × 2 × 6 | 50 → 52 | **50** |
| `tete` | `mesh_tete` | 12 × 12 × 12 | 52 → 64 | **52** (base du crâne) |
| `tete` | `mesh_cheveux` | 13 × 5 × 13 | 60 → 65 | — (même os) |

`mesh_cheveux` est un **objet distinct** porté par le même os que la tête : il
doit pouvoir être masqué avec elle en première personne, et recoloré à part.

Les yeux tombent à **60,8 px** — bien à l'intérieur du cube de tête (52 → 64).
C'est ce qui garantit que la caméra première personne ne sort pas du crâne.

### Bras (× 2 : suffixe `_gauche` / `_droite`)

| Groupe (os) | Cube (maillage) | Taille L×H×P | Y de … à | Pivot |
|---|---|---|---|---|
| `epaule_gauche` | *(aucun cube)* | — | — | **48** |
| `bras_gauche` | `mesh_bras_gauche` | 5 × 11 × 7 | 37 → 48 | **48** (épaule) |
| `avantbras_gauche` | `mesh_avantbras_gauche` | 5 × 11 × 6 | 26 → 37 | **37** (coude) |
| `main_gauche` | `mesh_main_gauche` | 5 × 6 × 6 | 20 → 26 | **26** (poignet) |

En X, les bras se placent **contre** le torse (demi-largeur 9) : le bras droit
occupe x 9 → 14, le gauche x −14 → −9.

`epaule_*` ne porte **aucun cube** : c'est un os de portage, hors chaîne IK.
Tu peux l'omettre entièrement si tu ne veux pas de haussement d'épaules.

### Récapitulatif

18 cubes : 2 pieds, 2 mollets, 2 cuisses, 1 bassin, 2 torse, 1 cou, 1 tête,
1 cheveux, 2 bras, 2 avant-bras, 2 mains.

## 4 ter. Placement des pivots — le point qui casse tout si on le rate

Dans Blockbench, chaque groupe a un **pivot point**. Par défaut il se pose au
centre du cube : **c'est faux pour un membre**.

Le pivot doit être **à l'ARTICULATION**, c'est-à-dire à l'extrémité par
laquelle le membre est rattaché au parent — donc en **haut** du cube pour tout
ce qui pend (cuisse, mollet, bras, avant-bras, main), et en **bas** pour ce qui
monte (colonne, cou, tête).

C'est la colonne « Pivot » des tableaux ci-dessus.

Un pivot au centre du cube fait tourner l'avant-bras **autour de son milieu**
au lieu du coude : le bras se disloque dès la première résolution d'IK, et
aucun réglage côté code ne peut le rattraper. C'est l'erreur la plus fréquente
et la plus coûteuse à corriger après coup (il faut re-rigger).

## 5. Animations

- **Aucune piste de `scale`**, sur aucun os. Le démembrement pilote l'échelle
  des os ; une piste d'animation la réécrirait à chaque frame et le membre
  tranché réapparaîtrait.
- Animations attendues, jambes et corps seulement (`idle`, `marche`, `course`,
  `saut`, `accroupi`). **Les bras n'ont pas besoin d'être animés** : ils sont
  pilotés par l'IK, qui aimante les mains sur les points de prise de l'arme.
  C'est tout l'intérêt du système — un seul jeu d'animations couvre les ~70
  armes du catalogue, quelle que soit la longueur du manche.

## 6. Texture

- Atlas **pixel-art à palette réduite**, couleurs franches et peu nombreuses :
  la recoloration (variantes rares 12.4, statue 1:1 de F.3) se fait par échange
  de couleurs en shader.
- Prévoir des **zones de couleur distinctes** pour peau / cheveux / haut / bas :
  ce sont les quatre calques que la création de personnage fera varier (voir
  la palette de `scenes/entities/player_model.gd`, le placeholder actuel).

## 7. Boucle de travail Blockbench → jeu

1. Ouvrir `humanoide.bbmodel` dans Blockbench (`File > Open Model`).
2. Éditer les formes. **Ne pas renommer les groupes** : leurs noms sont lus par
   le code (os d'attache, zones de coup, démembrement).
3. `File > Export > Export glTF Model` → écraser `humanoide.glb`.
4. `godot --headless --path . --import` puis
   `godot --headless --path . --script tools/verify_rig.gd`.

Côté données, le modèle se branche par une ligne dans une fiche de créature :

```json
"model": "res://models/creatures/humanoide.glb"
```

### ⚠ Échelle à l'export — point NON VÉRIFIÉ

Le `.bbmodel` fait **64 unités** de haut ; le `.glb` généré par le script fait
**2,0 unités Godot**, la valeur exigée par `PLAYER_HEIGHT`.

Blockbench applique sa propre échelle à l'export glTF (héritage Minecraft :
16 unités = 1 bloc), qui n'a **pas pu être vérifiée** ici — Blockbench ne
tourne pas en ligne de commande. Un export depuis Blockbench sortira donc
peut-être un modèle 2× ou 4× trop grand.

Ce n'est pas un problème et **surtout pas une raison de re-modéliser** :
`verify_rig.gd` imprime la hauteur réelle, et la correction se fait en une
ligne dans `humanoide.glb.import` (paramètre d'échelle de l'importeur glTF),
jamais en déformant le modèle.

## 8. Checklist avant de livrer

- [ ] Projet en **Generic Model** (le squelette s'exporte)
- [ ] Hauteur totale **2,0 unités**, pieds à y = 0, face vers −Z
- [ ] Chaînes bras et jambes à **2 os exactement**
- [ ] Colonne en **2 os** (`colonne_1`, `colonne_2`)
- [ ] `attach_arme`, `attach_arme_gauche`, `attach_dos`, `attach_tete` présents
- [ ] **Un maillage par os**, `mesh_tete` et `mesh_cheveux` **séparés**
- [ ] Poids de vertex à **1.0**, aucun maillage à cheval sur deux os
- [ ] **Aucune piste de scale** dans les animations
- [ ] Exporté en `.glb` dans ce dossier

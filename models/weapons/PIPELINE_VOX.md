# Pièces d'arme en `.vox` — spécification (EN ATTENTE)

> **Mis de côté le 2026-08-02.** Le combat passe d'abord. Ce document existe
> pour que la spécification ne se reperde pas, et pour qu'une pièce modélisée
> entre-temps soit directement utilisable le jour où le branchement se fera.

Aujourd'hui les pièces d'arme sont générées en `.glb` par
`tools/generate_weapon_parts.py` à partir de tables de boîtes. L'objectif de ce
document est de permettre de les **modéliser à la main dans MagicaVoxel** à la
place.

---

## 1. Échelle — la seule chose vraiment contraignante

**1 voxel = 1 pixel de bloc = 1/32ᵉ de bloc ≈ 3 cm.** Un bloc fait 32 voxels de
côté.

Toutes les longueurs du catalogue en découlent. Elles sont calées sur les
dimensions des armes historiques (voir `LISEZMOI.md`, section « Longueurs de
référence ») et vérifiées par `--probe-combat`.

### Manches

| pièce | voxels | épaisseur | armes |
|---|---|---|---|
| `poignee_dague` | 4 | 3 | dague |
| `poignee_epee` | 6 | 3 | épée, rapière, épée courte |
| `poignee_longue` | 13 | 3 | espadon |
| `court` | 8 | 3 | hachette, gourdin |
| `moyen` | 13 | 3 | masse, masse à ailettes, pioche de combat |
| `long` | 34 | 4 | hache d'armes, hache double, marteau de guerre |
| `hampe` | 48 | 4 | hallebarde, trident, faux de guerre |
| `hampe_longue` | 64 | 4 | lance |
| `baton` | 46 | 4 | bâton ferré, bâton de canalisation |
| `arc` | 30 | 3 | arc |
| `arbalete` | 18 | 5 | arbalète |
| `poignee` | 4 | 4 | écu, rondache, pavois |

### Têtes

Hauteur **au-dessus du point de greffe**, et débord sous celui-ci quand la pièce
en a un (contrepoids, croc arrière, plaque de bouclier).

| tête | haut | sous la greffe | demi-largeur |
|---|---|---|---|
| `lame_dague` | 8 | 0 | 2,5 |
| `lame_courte` | 12 | 0 | 3 |
| `lame_moyenne` | 24 | 0 | 4 |
| `lame_longue` | 38 | 0 | 5 |
| `rapiere` | 30 | 0 | 3,5 |
| `pointe` | 10 | 0 | 2,5 |
| `trident` | 14 | 0 | 5 |
| `hache` | 11 | −1 | 10 |
| `hache_double` | 11 | −1 | 9 |
| **`hallebarde`** | **20** | **0** | **9** |
| `faux` | 8 | 0 | 16 |
| `masse` | 9 | 0 | 3,5 |
| `masse_ailettes` | 9 | 0 | 5 |
| `marteau` | 11 | 0 | 6 |
| `gourdin` | 10 | −4 | 3 |
| `bec` | 8 | 0 | 11 |
| `branches_arc` | 18 | −34 | 1 |
| `arc_arbalete` | 8 | −2 | 16 |
| `cristal` | 10 | 0 | 3 |
| `orbe` | 9 | 1 | 4 |
| `rondache` | 7 | −7 | 7 |
| `ecu` | 11 | −17 | 9 |
| `pavois` | 17 | −15 | 11 |

---

## 2. Point d'attache : ne pas en mettre

La convention est **géométrique**, pas marquée par un voxel :

> Une arme pointe vers **+Y**. Un manche occupe `y = 0 → longueur`. Une tête est
> modélisée **à partir de `y = 0`**, et c'est l'assemblage qui la remonte au
> sommet du manche.

Le bas de la tête, à `y = 0`, **est** le point d'attache. Elle a le droit de
déborder latéralement et de descendre sous zéro.

Un voxel-marqueur (rouge ou autre) apparaîtrait comme un cube coloré sur l'arme.
Les marqueurs de `data/reserved_colors.json` (`marqueurs_attache`) appartiennent
à l'**ancien** pipeline des créatures : les os `attach_*` des rigs les ont
remplacés.

---

## 3. Couleurs : peindre en couleurs RÉSERVÉES

Les pièces sont **teintées au craft** — une hallebarde en fer, en cuivre ou en
granit noir, c'est le même modèle recoloré. Une couleur littérale resterait
telle quelle en jeu et le système de matériaux s'effondrerait.

Peindre en **valeur exacte**, sans dégradé ni ombrage (l'ombrage est ajouté par
le rendu) :

| couleur | code | rôle |
|---|---|---|
| vert pur | `#00FF00` | slot de matériau 1 |
| magenta pur | `#FF00FF` | slot 2 |
| cyan pur | `#00FFFF` | slot 3 |
| jaune pur | `#FFFF00` | slot 4 |

Pour une arme, la convention actuelle est : **manche → bois**, **tête →
minerai**. Une pièce d'un seul matériau se peint donc entièrement dans **une
seule** couleur réservée.

---

## 4. Où déposer les fichiers

```
models/weapons/manche_<id>.vox
models/weapons/tete_<id>.vox
```

---

## 5. Ce qui reste à brancher côté code

Trois points, et le troisième est le plus important :

1. **`WeaponPreview.assemble` ne charge que du `.glb`** (`load()` d'une
   `PackedScene`). Le lecteur `.vox` existe et fonctionne déjà — `VoxLoader`
   lit la palette, détecte les couleurs réservées et sait construire un
   maillage — mais les deux ne sont pas reliés.

2. **Le matériau.** Les pièces `.glb` sont teintées à plat par
   `PlayerBody.tinted_material`. Une pièce `.vox` doit passer par le matériau à
   palette remappée (`held_item._build_remapped_material`), qui devra devenir
   partagé — sinon l'arme tenue et l'icône d'inventaire divergeront, comme
   c'était le cas avant le 2026-08-02.

3. **La longueur doit rester DÉRIVÉE du modèle.** `data/weapon_parts.json`
   contient `longueur` et `portee_tete`, aujourd'hui réécrits par le générateur
   depuis les boîtes. Pour une pièce `.vox`, ils devront être mesurés sur le
   `.vox` lui-même. Sans ça on rouvre l'écart modèle/hitbox fermé le
   2026-08-02 : l'arme paraîtrait plus longue que sa portée réelle, et
   toucherait « dans le vide » sur ses derniers centimètres.

   `godot --headless --path . --script tools/verify_weapon_parts.gd` est le
   garde-fou : il compare la géométrie réelle de chaque pièce à sa donnée.

4. Conséquence des recettes dérivées : le **volume** de la pièce décide du coût
   de craft et de la masse (`_derive_recipes`). Une pièce `.vox` devra donc
   aussi voir son volume mesuré, sinon son arme n'aura ni poids ni prix.

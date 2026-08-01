# Interface : police et thème

Tout ce qui s'affiche dans une interface de Voxen passe par **une** source de
vérité : `autoload/UITheme.gd`. Palette, échelle de tailles, grille
d'espacement et fabriques partagées (`heading`, `field`, `rule`, `dim`) y sont
définies **en code, avec leur justification**.

## Les deux fichiers générés

| Fichier | Généré par | Rôle |
|---|---|---|
| `voxen_pixel.png` + `.fnt` | `python tools/generate_pixel_font.py` | police pixel matricielle (BMFont) |
| `voxen_theme.tres` | `godot --headless --path . --script tools/generate_ui_theme.gd` | sérialisation de `UITheme.build()` |

Ni l'un ni l'autre ne s'édite à la main. Le `.tres` est **déclaré dans
`project.godot`** (`gui/theme/custom`) : c'est le seul mécanisme qui atteigne
tous les Control du projet. Le poser au runtime sur la fenêtre racine ne suffit
pas — les interfaces de Voxen pendent sous des nœuds 3D et des CanvasLayer, et
l'héritage de thème ne les atteint pas de façon fiable. Le symptôme est
traître : tout compile, la fenêtre porte bien un thème, et l'écran ne change
pas.

## Les tailles disponibles sont 11, 22 et 33. Pas autre chose.

La police est importée en **mise à l'échelle entière uniquement**. Un glyphe
pixel n'a de sens qu'à ×1, ×2, ×3 ; à une échelle fractionnaire, une colonne de
pixels sur deux disparaît. Toute taille demandée en dehors de ces multiples est
ramenée au palier inférieur — écrire `font_size = 15` ne produit pas du 15, il
produit du 11 silencieusement. D'où `UITheme.FONT_SMALL` / `FONT_BODY` /
`FONT_HEADING` / `FONT_TITLE`, qui rendent l'intention explicite.

## Ajouter un glyphe

Les glyphes sont des **données lisibles** dans `tools/generate_pixel_font.py` :
sept lignes de cinq caractères (`#` et `.`), neuf pour une lettre à jambage.
Les accentuées ne se dessinent pas — elles se **composent** (corps + marque),
sinon `é` et `e` finiraient par diverger.

Attention aux symboles (`✗`, `⚔`, `±`, `≥`) : le moteur ne les a **pas** dans sa
police de secours, contrairement aux idéogrammes. Un symbole oublié s'affiche
en carré vide. `--test-ui` vérifie la présence de la liste courante.

## Voir le résultat

    godot --path . -- --test-ui

Produit une capture de chaque écran dans `debug/`, et vérifie que la police
pixel est **réellement résolue sur un Label de l'arbre** — pas seulement
présente dans le thème, ce qui est une nuance qui a déjà coûté une session.

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

# Architecture du dépôt — qui fait quoi, où

*Créé le 2026-08-09 (demande de l'auteur). Carte technique du dépôt : chaque
dossier, les fichiers qui portent les systèmes, et les frontières entre eux.
Le GDD ([GDD.md](GDD.md)) dit ce que le jeu DOIT faire ; ce fichier dit OÙ
c'est fait. Règle de tenue : toucher un système = vérifier sa ligne ici.*

## Vue d'ensemble

```
project.godot          Config Godot 4.7 (gl_compatibility obligatoire — UHD 620)
GDD.md                 Design de référence (amendé par dates, fait foi)
README.md              État d'avancement, perf mesurée, reste à faire
combat.md              Notes de conception du combat directionnel
ARCHITECTURE.md        Ce fichier
autoload/              30 singletons : état global et systèmes transverses
scenes/                Scènes et leurs scripts (main, entités, UI, monde)
systems/               Logique pure sans nœud : voxel, worldgen, combat, etc.
native/                Extension GDExtension C++ (cœur voxel/génération)
data/                  TOUT le contenu en JSON (data-driven intégral)
tools/                 Sondes de validation + générateurs Python d'assets
assets/, models/       Textures UI, police pixel, modèles .glb (versionnés)
locale/                Traductions fr/en/ja/zh_Hans (.csv → .translation)
debug/                 Artefacts régénérables (captures, logs) — gdignoré
```

## Le cœur voxel (chaîne chunk → écran)

| Fichier | Rôle |
|---|---|
| [autoload/WorldManager.gd](autoload/WorldManager.gd) | Streaming par colonne (rayon 8), file de workers, upload des meshes (budget/frame), mutations `set_block`/`set_block_batched` (D.2), diff d'édition `_edits` (base de la sauvegarde), LOD fine/coarse, éviction. LE point de passage de toute lecture/écriture de bloc. |
| [systems/voxel/chunk_mesher.gd](systems/voxel/chunk_mesher.gd) | Greedy meshing (référence GDScript + pont vers le natif), plantes en croix, assemblage des surfaces. `use_native` = bascule de diagnostic. |
| [systems/voxel/chunk_data.gd](systems/voxel/chunk_data.gd) | Données d'un chunk 16³ : blocs u16, sous-grilles, hôtes de filons. |
| [systems/voxel/subdiv_grid.gd](systems/voxel/subdiv_grid.gd) | Sous-grilles 8³ (sculpture 32→16→8→4 px). |
| [systems/voxel/light_field.gd](systems/voxel/light_field.gd) | Lumière de bloc 0-15 (référence GDScript ; portée en natif). |
| [scenes/world/voxel_material.gdshader](scenes/world/voxel_material.gdshader) | LE shader du terrain : textures procédurales par style, teinte d'herbe PAR SOMMET (COLOR.gba), lumière cuite (COLOR.r), plantes (UV.x négatif), jour/nuit par uniform. **Matériau PARTAGÉ par tous les chunks** — toute donnée par chunk passe par les sommets ou MODEL_MATRIX, jamais par un duplicata. |

## L'extension native (`native/`) — C++ via GDExtension

Toolchain sans admin (MinGW portable + SCons + godot-cpp 4.5), commandes dans
l'en-tête de [native/SConstruct](native/SConstruct). **Chaque fonction C++ est
le MIROIR d'une fonction GDScript conservée** ; la parité est verrouillée par
`--probe-mesh-parite` (294 chunks + 49 contextes, au bit près).

| Fichier | Rôle |
|---|---|
| [native/src/voxen_mesher.cpp](native/src/voxen_mesher.cpp) | `mesh_core` (intérieur/croix/lumière/greedy/subdiv + teinte par sommet), `fill_shell_terrain` (coquille : strates/cavernes/dimensions), `configure_shell`. |
| [native/src/voxen_columns.cpp](native/src/voxen_columns.cpp) | `sample_columns` : les 324 colonnes d'un contexte (terrain continental, climat, biomes+dither, littoraux). Overworld/plat seulement. |
| [native/src/register_types.cpp](native/src/register_types.cpp) | Enregistrement de la classe `VoxenNative`. |

Périmètre natif au 2026-08-09 : maillage 17,1 → 1,61 ms/chunk, colonnes ×20.
Reste GDScript : surcouches de coquille, plantes, villes, dimensions, et les
ARBRES (75 % du coût de contexte restant — prochain chantier).

## Génération du monde (`systems/worldgen/`)

| Fichier | Rôle |
|---|---|
| [noise_generator.gd](systems/worldgen/noise_generator.gd) | LE générateur (5 000 lignes) : terrain, climat, biomes, strates, filons, cavernes, rivières, fenêtres d'arbres/plantes/cultures, villes (routage), dimensions, contexte de colonne (`prepare_context`), coquille du mesher (`fill_shell`), instrumentation `profiling`. Immuable après `_init` → lisible des threads sans verrou. Configure les instances natives. |
| [tree_generator.gd](systems/worldgen/tree_generator.gd) | Formes d'arbres (10 silhouettes, racines, détail 8 px) — déterministe par graine. |
| [plant_generator.gd](systems/worldgen/plant_generator.gd) | Cultures en sous-voxels (stades de croissance). |
| [city_generator.gd](systems/worldgen/city_generator.gd) | Plans de villages/capitales : tuiles, terrasses, bâtiments, rues. |
| [kingdom_generator.gd](systems/worldgen/kingdom_generator.gd) | Royaumes par secteurs 64×64 cellules, territoire à coût, lois. |
| [dungeon_generator.gd](systems/worldgen/dungeon_generator.gd), [dungeon_tower.gd](systems/worldgen/dungeon_tower.gd), [dungeon_cavern.gd](systems/worldgen/dungeon_cavern.gd) | Termitière extérieure + intérieurs organiques multi-étages. |
| [poi_generator.gd](systems/worldgen/poi_generator.gd) | Placement des POI (village, donjon) par cellule. |
| [showcase_builder.gd](systems/worldgen/showcase_builder.gd) | Monde vitrine plat (rangées de démonstration). |

## Entités (`scenes/entities/`)

| Fichier | Rôle |
|---|---|
| [player.gd](scenes/entities/player.gd) | God object assumé (3 300 lignes, découpage proposé au README) : déplacement, raycast bloc/sous-bloc, casser/poser/sculpter, combat joueur, inventaire/hotbar, faim/fatigue/sommeil/mort, claims, lois, dialogue. |
| [player_body.gd](scenes/entities/player_body.gd) | Corps visuel du joueur : rig, IK, pose d'arme, cache de matériaux de peau. |
| [fly_camera.gd](scenes/entities/fly_camera.gd) | Caméra première personne, vol/marche, bench de vol. |
| [creature.gd](scenes/entities/creature.gd) | LA créature générique data-driven : IA au tick (10 Hz), combat directionnel, collision monde (`_wall_at` — règle `loaded_only`), statuts. |
| [creature_body.gd](scenes/entities/creature_body.gd) | Corps riggé : IK des pattes, ondulation, ailes, culling de distance. |
| [held_item.gd](scenes/entities/held_item.gd) | Objet en main (pièces d'armes assemblées, blocs). |

## Autoloads notables (au-delà de WorldManager)

| Autoload | Rôle |
|---|---|
| GameData | Chargement de TOUT `data/` au boot, ids runtime, masques (liquides, croix…) — figé après boot, lu sans verrou par les threads. |
| EventBus | Signaux inter-systèmes (E.12) — SEUL couplage autorisé entre systèmes. |
| TickManager | Horloge de simulation 10 Hz, phases entités/monde/flush/post, budget 16 ms instrumenté. |
| CreatureManager | Spawn (file étalée), tick des créatures, grille spatiale des voisins, population de villages (via [systems/world/village_population.gd](systems/world/village_population.gd)). |
| SaveManager | Sauvegarde incrémentale atomique, versionnement/migrations. |
| DimensionManager / DungeonManager | Registre des dimensions (3.5) / backend donjon (constructeur + boss + coffres). |
| NetworkManager | Squelette multijoueur : 5 RPC (blocs, pose), poignée de main de graine, horloge host-autoritaire. |
| SettingsManager / InputManager | settings.cfg (langue, distance, touches) / 29 actions remappables. |
| EconomyManager, ShopManager, GuildManager, VillageManager | Commerce A.8, étals, guildes B.7, registres de villages. |
| DayNightManager | Cycle jour/nuit — pousse `daylight` sur LE matériau partagé. |
| ZoneManager, ContainerManager, SaplingManager, PlacedItemManager, DropManager, ProjectileManager | Zones d'effet, coffres, pousses, objets posés, butin au sol, projectiles. |

## Combat (`systems/combat/`)

`melee_attack.gd` (balayage directionnel, zones), `combat_resolver.gd`
(pipeline dégâts/mitigation — l'en-tête porte le raisonnement E.3.1),
`weapon_stats.gd` (stats dérivées des pièces et matériaux),
`wu_xing.gd` (les cinq éléments 5.2/A.4.6 — LA table unique des cycles et
des dérivations d'alignement ; le multiplicateur s'applique dans
`resolve_hit`, les combos dans `player.cast_assembly`),
`spell_assembly.gd` (compilation des assemblages de modules, coût A.6).

## Données (`data/`) et outillage (`tools/`)

- `data/` : matériaux (507), biomes, strates, créatures, objets, modules,
  statuts, dimensions, cultures de nommage, plats… Schémas en annexe B du GDD.
  **Ajouter du contenu = ajouter un JSON**, le menu de triche l'expose seul.
- `tools/probes/` : ~50 sondes (`--probe-*`, table dans
  [probe_registry.gd](tools/probes/probe_registry.gd)) — lancement :
  `godot --headless --path . -- --probe-x` (le `--` est OBLIGATOIRE).
  Les sondes de MESURE : `--probe-mesh` (maillage par phase), `--probe-gen`
  (génération par phase), `--probe-mesh-parite` (parité GDScript↔natif).
  Suite complète : `tools/run_probes.sh`.
- `tools/*.py` : générateurs d'assets (police pixel CJK, rigs de créatures,
  pièces d'armes). Après régénération d'un asset : `godot --headless --path .
  --editor --quit` (les caches d'import MENTENT sinon).

## Les invariants qui ne se voient pas dans l'arborescence

1. **Le tick est un budget de simulation, pas de construction** — tout ce qui
   bâtit (corps, plan de ville, royaume, chunk) se fait à la frame ou en
   worker, jamais dans le tick.
2. **Toute lecture de bloc cadencée doit traiter « chunk non chargé »**
   (`is_block_loaded`, `loaded_only`) : hors chunk chargé, `block_at_world`
   régénère une colonne entière.
3. **GDScript et C++ sont des miroirs** : on ne modifie jamais l'un sans
   l'autre, et `--probe-mesh-parite` tranche.
4. **GameData est figé après le boot** — c'est ce qui autorise les threads à
   lire sans verrou ; le hot-reload F5 attend les tâches en vol.
5. **Mesurer avant d'optimiser** — les sondes de mesure existent pour ça, et
   cette machine a ±35 % de bruit : une mesure unique ne prouve rien.

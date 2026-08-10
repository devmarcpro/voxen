# Voxen

Jeu de construction voxel / roguelite de vie simulée (Godot 4, GDScript, `gl_compatibility`).
Le design de référence fait autorité : voir [GDD.md](GDD.md) — **sauf sur le combat**,
où le code a délibérément quitté E.3 (voir §5.1 et l'annexe E.3.1 du GDD, amendées
le 2026-08-02 : la géométrie décide du toucher, plus aucun jet de 1d20).

---

## Essayer le projet

### Ce qu'il faut

- **Godot 4.7** (`gl_compatibility` — le projet cible une Intel UHD 620, il n'y
  a aucun rendu Forward+). Deux binaires traînent parfois sur une machine de
  dev : **c'est le 4.7 qui fait foi**, un 4.5 ouvrira le projet avec des erreurs
  de parse trompeuses.
- **Python 3** uniquement pour les générateurs de contenu (`tools/*.py`), jamais
  pour jouer.
- **Optionnel mais fortement recommandé : l'extension native** (`native/`),
  le cœur du mesher en C++ (voir « Le mesher natif » plus bas). Sans elle le
  jeu fonctionne à l'identique sur le chemin GDScript de référence — juste
  6 à 7× plus lentement au maillage.

### Lancer

```bash
# Depuis la racine du dépôt
godot --path .                       # le jeu, menu de démarrage
godot --path . -- --statique         # monde de test direct, sans passer par le menu
```

**Le `--` est obligatoire** dès qu'on passe un argument au jeu : sans lui, Godot
mange le drapeau et le jeu attend sagement au menu. C'est un faux diagnostic
classique — « la sonde est gelée » alors qu'elle n'a jamais démarré.

### Les commandes en jeu

`F3` affiche l'aide complète, **générée depuis les liaisons réelles** (elles sont
remappables dans les paramètres, donc l'aide ne peut pas mentir). L'essentiel :

| Touche | Action |
|---|---|
| ZQSD / WASD | marcher (touches **physiques** : la disposition du clavier est suivie sans réglage) |
| Espace / F | sauter · basculer vol/marche |
| Clic gauche maintenu | récolter, sculpter, attaquer |
| Clic droit | poser un bloc · consommer l'objet en main |
| E | interagir (coffre, établi, butin au sol, objet posé) |
| R | changer la finesse de grille (32 / 16 / 8 / 4 px) |
| 1-9, molette | emplacement de barre · `Ctrl` + molette pour changer de banque |
| Tab / M / B | inventaire · carte du monde · rôle de la cellule |
| J K L | modules assemblés |
| H / N / V | équiper · dormir · revendiquer la cellule |
| **F1** | **menu de triche** — tout le contenu du jeu y est atteignable |
| F9 / F5 | sauvegarder · recharger les données à chaud |

### Vérifier que rien n'est cassé

```bash
tools/run_probes.sh          # 28 sondes assertives, headless, code de sortie 0/1
tools/run_probes.sh --list   # ce qu'elle contient
```

Compter environ **quinze minutes** : chaque sonde est un processus Godot complet
qui charge un monde. Deux échecs sont attendus au 2026-08-04 (`--probe-police`,
`--probe-corps`), documentés plus bas.

Une sonde seule, quand on travaille sur un système précis :

```bash
godot --headless --path . -- --probe-arbres
```

Les sondes de **capture** (`--test-*`) doivent tourner **sans** `--headless` :
en mode headless le serveur de rendu est un mannequin, `frame_post_draw` ne se
déclenche jamais, et les images ne sont pas écrites. Elles atterrissent dans
`debug/`, qui est ignoré par git.

### Le mesher natif (GDExtension `native/`)

Le cœur du meshing (intérieur, greedy, subdivision, lumière) existe en **deux
exemplaires miroirs** : [chunk_mesher.gd](systems/voxel/chunk_mesher.gd) (la
référence, toujours fonctionnelle) et
[native/src/voxen_mesher.cpp](native/src/voxen_mesher.cpp) (port C++ fidèle).
Si la DLL est présente, elle est utilisée ; sinon le GDScript prend le relais
sans rien casser. Depuis le port de la **coquille** (`fill_shell_terrain`,
strates + cavernes + dimensions — les surcouches arbres/villes restent en
GDScript partagé), le périmètre natif couvre tout le maillage : mesuré sur la
machine cible, **17,1 → 1,61 ms/chunk (×10,6)** — le gain vient autant du C++
que de la disparition des verrous de VM GDScript côté threads workers. Le
hachage de cellules y est reproduit en entier 64 bits signé au bit près, et
TOUTES les constantes viennent du GDScript (`configure_shell`) : le C++ n'en
recopie aucune.

```bash
# Toolchain SANS Visual Studio ni droits admin (détail : native/SConstruct) :
#   MinGW-w64 portable (winlibs) + `pip install --user scons` + godot-cpp 4.5
cd native
python -m SCons platform=windows use_mingw=yes target=template_debug -j8
# puis enregistrer l'extension :
godot --headless --path .. --editor --quit
```

**Toute modification d'un des deux mesher doit passer `--probe-mesh-parite`** :
la sonde maille les mêmes chunks réels par les deux chemins et compare les
tableaux élément par élément. C'est elle qui garde les miroirs honnêtes.

### Pièges connus de l'environnement

- **`debug/` est `.gdignore`** : Godot n'y voit aucun script. Un outil rangé là
  ne sera jamais chargé — les scripts vont dans `tools/`.
- **Après avoir modifié une locale (`locale/*.csv`)**, il faut lancer l'éditeur
  une fois (`godot --headless --path . --editor --quit`) pour régénérer les
  `.translation` compilés. Sans ça le jeu affiche les clés brutes.
- **Essais réseau** : un hôte d'une exécution précédente peut rester sur le port
  et servir l'**ancien** code, avec pour seul symptôme
  `The rpc node checksum failed`. Tuer les processus Godot avant chaque essai.

---

## État actuel (au 2026-08-04)

Le projet a exécuté l'ordre de construction **D.3 étapes 1 à 8** ainsi que quelques
extras (boutique passive, menu de triche). **49 200 lignes de GDScript** sur 154 fichiers.

**Ce qui a changé depuis le 2026-08-02**, en un paragraphe : les modules et sorts
sont passés de 4 fiches à un système d'assemblage complet (36 modules, livres, jet
de lecture, 14 statuts, zones persistantes) ; les arbres ont été refaits deux fois
et portent maintenant dix silhouettes réelles, des racines et un détail au 8 px ;
les pousses existent ; les dimensions sont devenues un système générique au lieu
d'un cas particulier nommé « donjon » ; le menu de triche expose la totalité du
contenu ; et le budget de tick a été assaini — les pics à 105 ms relevés en jeu ont
disparu.

**Socle en place :**

| Domaine | État |
|---|---|
| Data-driven (`GameData`) | **316 matériaux** (blocs) + ressources paramétriques (viandes/peaux/pousses, hors palette), 24 biomes, 53 compétences, 35 fonctionnalités, **40 objets**, **72 transformations**, 38 arbres, 6 plantes, 6 races, 6 classes, 10 cultures de nommage, 7 salles / 3 connecteurs de donjon, 4 plats, **36 modules**, **14 statuts**, **2 dimensions**, 18 créatures (humaines seulement depuis le 2026-08-02). *`GameData.load_all()` imprime ces comptes au boot — c'est lui qui fait foi, pas cette ligne.* |
| Noms culturels (12.5, E.31, B.11, C.9) | **Fait le 2026-08-02** — le GDD le listait comme « à écrire » (§16). 10 cultures de nommage en données (`data/name_cultures/`), chacune avec ses pools préfixe/suffixe pour prénoms, noms de famille et villes, plus ses titres pour les 6 gouvernances. `NameGenerator` : tirage déterministe, héritage du nom de famille, `name_order` par culture (le sino nomme famille avant prénom), titres genrés. **Culture ≠ race** : un royaume humain peut sonner latin, sino, slave ou nordique ; les trois races originales ont chacune une culture exclusive. Les royaumes reçoivent une culture, leurs villages et habitants en héritent — sonde `--probe-noms` |
| Localisation (10.1) | **Les quatre locales portent les 981 clés** (mesuré le 2026-08-02) : `fr` / `en` font référence et sont validées clé par clé ; `ja` et `zh_Hans` sont à **978 / 981**, le boot les rapporte à 100 % arrondi. Elles restent déclarées dans `PARTIAL_LOCALES` — le repli sur l'anglais reste donc actif, à retirer une fois les dernières clés traduites. **Police CJK (2026-08-01)** : aucun caractère chinois ou japonais ne s'affichait — le repli de police pointait sur la police intégrée de Godot, latine elle aussi. Les 1327 idéogrammes des traductions sont désormais rastérisés en cellules 12×12 depuis Noto Sans SC (SIL OFL) par `tools/generate_pixel_font.py`, sans embarquer de `.ttf` (+45 Ko). Jeu de glyphes figé sur les traductions du jour, gardé par `--probe-police` |
| Génération du monde (E.2) | continents/océans, rivières & littoraux, strates, filons, grottes, biomes, arbres, plantes, POI, villes (coques de bâtiments), noms de monde |
| Voxel (4, G.2) | chunks multithreadés, meshing greedy, subdivision 32→16→8→4, LOD, ombrage voxel maison, édition instantanée. **Cœur du mesher en GDExtension C++ depuis le 2026-08-09** (`native/`, 2,55 ms/chunk, budget E.14 tenu), chemin GDScript conservé en référence/repli, parité verrouillée par `--probe-mesh-parite` |
| Joueur | déplacement, raycast bloc + sous-bloc, casser/poser/sculpter, récolte + XP, inventaire volumétrique, hotbar multi-banques, PV, mana |
| Équipement (6.2, A.4.2) | 13 emplacements, 5 pièces d'armure, dés de réduction réels en combat, poids porté, persistance — sonde `--probe-equipement` |
| Éclairage (G.3) | lumière de bloc 0-15 propagée depuis la `luminosite` des matériaux (torche 14, lave 14, gemmes), cuite dans la couleur de sommet, lue par le shader — s'ajoute au jour au lieu de le remplacer |
| Carte du monde | **une seule carte** (l'onglet du menu ouvre celle de la touche M) ; déplacement **case par case en ZQSD** qui fait réellement s'écouler le temps (2× le coût de la marche), avatar du joueur comme marqueur, horloge et jauges affichées — on peut s'épuiser, voire mourir, en traversant le monde |
| Termitière de donjon (3.5) | masse organique **à l'échelle de la cellule** (rayon 56), sculptée au bruit : flancs irréguliers, **pics démoniaques** (bruit crêté), **cavités et tunnels « alien »** (bruit 3D), palette de 5 matériaux sombres marbrés, tous **incassables** ; on entre en s'enfonçant dans une cavité |
| Cycle jour/nuit (E.21) | `DayNightManager` : 4 phases, course du soleil, **assombrissement réel du terrain par uniform de shader** (G.3), faune nocturne distincte, densité de spawn ×2 et portée d'agression réduite la nuit — sonde `--probe-survie`. **Bug réparé le 2026-08-09** : l'uniform `daylight` n'atteignait que le matériau source alors que chaque chunk portait un duplicata figé à l'installation — les chunks anciens gardaient la lumière de leur pose. Le matériau est désormais PARTAGÉ par tous les chunks (la teinte d'herbe est cuite par sommet, l'origine lue dans MODEL_MATRIX) : l'heure touche tout le monde, et ~3 ms/frame de rebinds driver ont disparu |
| Sommeil & fatigue (E.21) | lit craftable (1er meuble F.6), saut de nuit avec temps réellement simulé, buff « Reposé » (+5 % XP), jauge de **fatigue** (amendement auteur) à effets progressifs jamais létaux |
| Cuisine (7.7, A.9.1, 6.4) | fourneau + compétence Cuisine + 4 plats ; un plat **cuisiné** rend la nutrition pleine et **crédite le potentiel de stat** — manger cru n'en donne aucun |
| Mort et pénalité (A.10) | **la famine peut tuer** (A.9 amendé sur décision auteur — plus de plancher à 1 PV) ; respawn au dernier lit ou claim, -10 % d'or, 10 % de perte par objet, équipement conservé, aucune perte d'XP ; caches au sol récupérables 1 jour in-game (`DropManager`) — sonde `--probe-mort` |
| Faim (A.9, A.9.1) | jauge + décroissance, **manger** (touche F, matériaux à bloc `nutrition`, cru = 50 %), seuils de régén, malus de stats < 25, famine à 0 — sonde `--probe-faim` |
| Artisanat (4.2) | recettes, transformations, stations, qualité |
| Combat (5, E.3.1) | **Directionnel façon Mount & Blade**, pas le E.3 d'origine : la géométrie décide du toucher (balayage de lame contre les zones de coup), les données décident des dégâts (A.4.1/A.4.2 intacts), le critique est la **zone visée** (`zone_mult` 2.5 à la tête) et non un nat 20. Gardes, boucliers, endurance. Pool de mana (A.5), créature générique data-driven. Le raisonnement complet est en tête de [combat_resolver.gd](systems/combat/combat_resolver.gd) et résumé en E.3.1 du GDD |
| Butin (7.7, A.9.1) | viande et peau **paramétriques** par espèce (B.1), en **instances d'objet** comme les armes (icône colorée, jamais un bloc) : registre `GameData.resources` séparé, sans id runtime ni entrée de palette. Unités identiques regroupées sur une instance. Bonus de potentiel dérivés de la source, dépeçage, consommation — sonde `--probe-butin` |
| Inventaire & hotbar | hotbar **assignable** (liaisons slot → objet par `uid`, stables au tri et à la sauvegarde), bande intégrée à l'inventaire avec **glisser-déposer**, menu d'actions au clic (infos, équiper, assigner banque/emplacement, déposer au sol) |
| Faune (F.3) | **18 fiches, toutes humaines** — spawn filtré par biome, meutes, profils d'IA (hostile / bête sauvage qui riposte / civil). **Périmètre réduit aux humains le 2026-08-02** (décision auteur, *pour l'instant*) : les 19 espèces animales ont été supprimées le temps que les modèles existent, le gabarit `humanoide.glb` étant le seul rig disponible. ⚠️ **La condition posée est désormais remplie** : `models/creatures/` contient 28 `.glb` (loup, ours, sanglier, cerf, crocodile, requin, araignée, chauve-souris, serpent, rat, aigle… plus dragon, spectre et raptor, qui ne correspondent à aucune fiche F.3). Restaurer les 19 fiches est redevenu un travail de données — à faire une fois le lot d'armement des créatures en cours terminé, pour que les animaux naissent directement au nouveau format `combat.arme_materiaux`. Spawn hostile = **bandit seul** (il a hérité des biomes des trois autres hostiles) ; spawn neutre = humains errants (villageois, chasseur, nomade, marchand ambulant, braconnier, ermite). Les métiers sédentaires restent réservés aux villages. Les fiches supprimées sont récupérables en `git show 8788dbd:data/creatures/<id>.json` — sonde `--probe-faune` |
| Carte & exploration (3.1, E.30) | carte du monde, voyage rapide, claims + rôles, minimap, brouillard de guerre |
| Donjons (3.5, E.29) | entrée/sortie par dimension, 2/4/6 étages selon le danger. **Intérieur refait le 2026-08-02** : salles **organiques** (empreinte elliptique déformée au bruit, sol en relief, voûte qui se resserre en hauteur, colonnes naturelles — `DungeonCavern`) au lieu de boîtes ; **8 à 18 salles** par étage selon la profondeur, sur 7 gabarits et 3 connecteurs ; **vrais escaliers** en gradins à rampes **lumineuses** (scorie ardente, 6/15) remplaçant les anciens disques plats ; **butin au sol** dispersé dans les salles et **coffre lâché par le boss** du dernier étage — sonde `--probe-interieur` |
| Boutique (7.1, E.8) | étal de vente passif, clients abstraits |
| Sauvegarde (E.10) | `SaveManager`, autosave **incrémentale**, écriture atomique ; **nombre de mondes illimité**, liste défilante complète, **suppression** avec confirmation et garde-fous (jamais hors du dossier de sauvegardes, jamais le monde en cours) — sonde `--probe-saves`. **Versionnement (2026-08-01)** : chaîne de migrations, copie de sûreté `world.v<N>.bak` avant migration, et **refus explicite motivé** au lieu de l'ancien « monde neuf » silencieux qui aurait effacé les parties au premier incrément du format ; chunks illisibles comptés et signalés au joueur |
| Modules et sorts (5.1, A.5-A.7, C.6) | **Système d'assemblage complet (2026-08-03)**, là où le GDD n'avait que 4 fiches d'exemple. 36 modules en trois rôles (`effet` / `modificateur` / `declencheur`), assemblés à la Noita : un multicast consomme les N effets qui le suivent, un déclencheur porte une charge utile récursive. Coût de mana par A.6, atténué par la conductivité des matériaux ; nombre d'emplacements dérivé des compétences. Les modules ne s'obtiennent **que** par la lecture d'un livre (jet A.7 avec échecs gradués), et les livres qu'en donjon — sondes `--probe-assemblage`, `--probe-modules` |
| Statuts (F.4) | 14 effets en données, appliqués par un `StatusTracker` qui enregistre ses modificateurs auprès du résolveur E.4 et rend les dégâts périodiques **sans jamais toucher à la santé lui-même** — un statut ne doit pas contourner le stagger ni la mort |
| Zones et coffres (F.6) | `ZoneManager` : zones d'effet persistantes qui pulsent au tick, bornées et filtrées par dimension. `ContainerManager` : coffres (30) et grands coffres (60), le coffre de boss étant **le même objet** que celui qui se craft ; casser un coffre en répand le contenu au sol |
| Dimensions (3.5) | **Généralisé le 2026-08-03.** `WorldManager` disait « si ce n'est pas l'overworld, appeler `DungeonManager` » : « pas l'overworld » signifiait donc « donjon », et toute troisième dimension aurait été un cas particulier de plus. Une dimension est maintenant une entrée de registre en données (`data/dimensions/`) plus un stockage voxel générique ; le donjon garde son constructeur mais s'y déclare comme **backend**. Une seconde dimension — la **faille de mana**, îlots d'améthyste dans le vide, habitants et butin — existe **sans une ligne de code qui la nomme**, ce qui est le seul test distinguant une abstraction d'un renommage. L'intérieur des donjons vit en coordonnées **locales**, ce qui referme l'« écart technique temporaire » que le GDD portait depuis le 2026-07-21 — sonde `--probe-dimensions` |
| Arbres (B.6) | **Refaits deux fois le 2026-08-03.** Dix silhouettes réelles au lieu de quatre (25 essences partageaient la même sphère : chêne, bouleau et érable étaient le même ballon sur un bâton), assignées essence par essence — colonne pour le peuplier, vase pour l'orme, étages pour le cèdre, parasol pour l'acacia. Le détail fin est en **8 px et jamais moins** (règle de grain de l'auteur) : branches effilées avec ramifications, **racines** en contreforts, peau du feuillage érodée sur ses coins exposés. Casser **n'importe quel** bloc abat l'arbre entier, au temps et au butin du **bois** et non du bloc frappé — sondes `--probe-arbres`, `--test-arbres` |
| Pousses | Un **matériau posable par essence** (38, générés depuis le catalogue). La miniature n'est pas dessinée : l'arbre est généré pour de vrai puis **réduit** dans un bloc, si bien qu'une pousse ressemble à ce qu'elle deviendra. `SaplingManager` porte le seul état que le bloc ne sait pas dire — essence et instant de plantation — et fait grandir une pousse par tick. Abattre un arbre en rend une ou deux — sonde `--probe-pousses` |
| Foreuses | Quatre outils de minage à large emprise (2×2 à 5×5), de catégorie pioche. Le carré suit le **plan de la face visée** — viser un mur ne creuse pas un puits — et la règle d'irrécoltabilité (A.2) comme le scellement des donjons (3.5) s'appliquent **bloc par bloc** : un bloc hors de portée est sauté, pas emporté — sonde `--probe-foreuse` |
| Réseau (8, E.11) | **Squelette, et il faut le lire comme tel.** Le projet compte **cinq RPC au total** : quatre pour les mutations de blocs et de sous-grilles, un pour la pose des joueurs. Tout ce qui a été bâti depuis le 2026-07-20 est **solo** — créatures, combat, villages, donjons, dimensions, coffres, butin, sorts, statuts, artisanat. Un client voit le terrain de l'hôte et un repère qui bouge, rien d'autre. **Fondation posée le 2026-08-04** : poignée de main de monde (la graine n'était **jamais** transmise — les deux camps s'en tiraient parce qu'ils valaient 1337 par défaut, une coïncidence et non un protocole) et horloge host-autoritaire (chacun faisait avancer son propre `TickManager` : il pouvait faire nuit chez l'un et jour chez l'autre). Le critère G.8 de latence est mesuré à 112-168 ms contre 100 attendus, mais **ce n'est pas le réseau** : le client tourne à 29 fps en streamant, donc ~69 ms sont de la pure quantification de frame — banc `--bench-network-client` |
| Commandes (2026-08-01) | `InputManager` : 29 actions déclarées en une table unique, **remappables** depuis les paramètres et persistées ; touches PHYSIQUES (ZQSD/WASD selon la disposition, sans réglage) ; l'aide du HUD est **générée** depuis les liaisons réelles au lieu d'être écrite en dur dans les fichiers de langue — sonde `--probe-touches` |
| Réglages | `SettingsManager` : un seul `user://settings.cfg` pour langue, distance d'affichage et touches, hors de toute sauvegarde. La **langue est enfin persistée** (elle ne l'était pas — le choix était perdu à chaque lancement) |
| Interface (E.13) | menu de démarrage, menu de jeu (perso/royaume/carte/monde/inventaire/craft), HUD, écran de remappe des touches. **Menu de combat refait (2026-08-03)** : les modules sont des cases qu'on assemble au **glisser-déposer**, l'écran séparé en armes / sorts. **Interface de coffre** en deux colonnes |
| Menu de triche | **Tout le contenu du jeu y est atteignable (2026-08-03)**, sur 6 onglets et **606 boutons** : les 316 matériaux un par un rangés par catégorie, tous les objets forgés aux réglages de l'atelier, les 42 ressources, les 38 essences et 6 plantes à planter devant soi, les 72 transformations, les dimensions, races, classes, 14 statuts et 53 compétences. **Aucune liste n'est écrite à la main** — chaque grille parcourt son registre `GameData`, donc un contenu ajouté au jeu y devient trichable sans toucher au fichier. Verrouillé par `--probe-triche`, qui échoue le jour où quelqu'un ajoute du contenu sans l'exposer |


---

## Performance — état mesuré au 2026-08-09

Les chiffres ci-dessous sont **mesurés**, pas estimés, sur la machine cible
(Intel UHD 620, `gl_compatibility`). Ils bougent de ±35 % d'une exécution à
l'autre : toute conclusion tirée d'une mesure unique est suspecte, et ça s'est
vérifié plusieurs fois.

| Critère (G.8 / E.14) | Cible | Mesuré | Verdict |
|---|---|---|---|
| Tick de simulation (E.1) | < 16 ms | ≤ 2,9 ms au bench statique | ✅ |
| 50 créatures actives (D.3 étape 6) | < 8 ms | **16,9 ms** de moyenne | ❌ — voir ci-dessous |
| Maillage d'un chunk (D.3 étape 4) | < 4 ms | **1,61 ms** (mesher + coquille natifs) | ✅ **tenu, marge ×2,5** |
| Mutation visible chez l'autre joueur (étape 8) | < 100 ms | **112-168 ms** | ❌, mais voir ci-dessous |
| Bench statique (rayon 8) | 60 fps | **64,3 fps** (34 % de frames > 16,7 ms) | ~ |
| Bench de vol (rayon 8) | 60 fps | **34,0 fps** (37 % de frames lentes) | ❌, était à 8,0 |

### Le maillage, critère enfin vert — mesher ET coquille en C++ (2026-08-09)

Ce que l'annexe E.14 prescrivait (*« si le meshing GDScript est trop lent,
passer cette partie — et elle seule — en GDExtension »*) est fait, en deux
temps : le cœur du mesher (17,1 → 2,55 ms/chunk), puis la **coquille**
(`fill_shell_terrain` : strates, cavernes, branche dimension — la partie dont
une divergence se paie en parois fantômes aux frontières) → **1,61 ms/chunk**
au total. Parité 294/294 chunks vérifiée par `--probe-mesh-parite`, qui
bascule les DEUX ports d'un seul A/B (contextes de colonne compris — les
hauteurs sont entières, la moindre dérive du terrain C++ s'y verrait au bloc
près). Troisième temps le même jour : les **colonnes** (`sample_columns`, les
324 `_sample_column` d'un contexte — terrain continental, climat, biomes,
littoraux) mesurées à 41,4 % de la génération par la nouvelle sonde
`--probe-gen` → **14,5 → 0,72 ms/colonne (×20)**, contexte 33,0 → 20,1
ms/colonne. Hors ville et hors dimensions (le terrassement et les reliefs de
dimension restent en GDScript de référence). Quatrième temps (2026-08-10) :
**les arbres** — `TreeGenerator.generate` porté en entier
([voxen_trees.cpp](native/src/voxen_trees.cpp)) : squelette récursif, RNG
Godot au même ordre d'appels (piège payé : l'ordre d'évaluation des arguments
C++ n'est pas spécifié — chaque tirage est hissé en variable nommée), tables
ordonnées maison pour préserver l'ordre d'insertion des dictionnaires dont
dépend l'ordre des sommets. Formes 13,7 → **2,75 ms/colonne**, contexte
complet 33,0 → **9,0 ms/colonne (×3,7)**. Les postes restants sont émiettés
(candidats 2,4 / plantes 1,9 / stamp 1,3 ms) — rendements décroissants, le
chantier génération est considéré clos à ce niveau.

### Les 50 créatures, critère repassé au rouge — et pourquoi c'est assumé

Le 0,67 ms d'antan mesurait des créatures qui **traversaient les murs**. La
collision murale du 2026-08-09 rend chaque déplacement 5 à 8× plus cher, et
trois optimisations du même jour (colonnes dédoublonnées, grille spatiale
remplaçant les paires O(n²) de séparation, cache d'allonge d'arme) ont ramené
le tick de 29,4 à **16,9 ms** — encore 2× le budget. Le reliquat est étalé
(~0,34 ms/créature de frais généraux GDScript par créature engagée) : les
prochains gains passeront par une IA à niveaux de détail (E.18) ou un portage
natif, pas par du micro-GDScript.

### Le budget de tick, assaini

Une partie réelle crachait des `[TICK] 62 à 105 ms` en boucle en approchant d'un
village. **Quatre postes distincts**, tous trouvés en instrumentant
`CreatureManager._on_tick` par sous-étape (IA / morts / villages / spawn) — pas
en raisonnant, et c'est le point : trois hypothèses plausibles ont été émises
avant, toutes fausses ou partielles.

- **`Creature._ground_height`** faisait dix `block_at_world` par créature et par
  tick ; cette lecture retombe sur une requête au générateur quand le chunk
  n'est pas chargé. **4,6 ms par villageois** — contre 1 ms pour cinquante bêtes
  sauvages, parce qu'elles, elles sont dans des chunks chargés. Le même code est
  gratuit ou ruineux selon l'état du streaming. → **83,6 ms d'IA ramenés à 2,6**.
- **`KingdomGenerator._entry_cost`**, fonction pure appelée quatre fois par
  cellule par le Dijkstra de territoire : 86 % du coût. Mémoïsée →
  **42,8 ms ramenés à 10,0**, résultats identiques au bloc près.
- **Préchauffage hors tick** des plans de ville et des secteurs de royaume, un
  élément par frame. Le peuplement de village **refuse** désormais de calculer
  l'un ou l'autre : il repasse au tick suivant. → **56,4 ms ramenés à 2,1**.
- **La file de spawn est passée du tick à la frame.** Monter un corps riggé coûte
  12 à 25 ms et **ne se laisse pas réduire** — chaque brique a été chronométrée,
  aucune ne domine. On ne l'a donc pas réduit, on l'a déplacé.

**La règle qui s'en dégage, et qui vaut pour tout système futur :**

> Le tick est un budget de **simulation**, pas de **construction**.
> Tout ce qui bâtit — royaume, plan de ville, corps de créature, chunk — se fait
> dans une frame et se réclame préchauffé.

### Le maillage, seul critère encore rouge

8,1 ms contre 4 attendus, réparti en `greedy` 3,7 ms (45 %), `subdiv` 2,1 ms,
coquille + intérieur 2,4 ms.

**Ce n'est pas le contenu.** Couper *tout* le détail en sous-voxels des arbres
fait passer le maillage de 8,28 à 8,15 ms — rien. L'érosion du feuillage coûte
0,44 ms à elle seule, et le poste `subdiv` vient des blocs **sculptés** de la
sauvegarde, pas des arbres. Il n'y a donc aucun arbitrage « détail contre
performance » à faire : le plafond est **l'émission de quads en GDScript**, ce
que l'annexe E.14 anticipe en prévoyant un passage en GDExtension. C'est une
décision de projet — écrire le mailleur en natif, ou amender le critère pour ce
qu'une UHD 620 peut tenir.

### La latence réseau n'est pas un problème réseau

112 à 168 ms mesurés contre 100 attendus, mais le client tourne à **29 fps**
pendant qu'il streame : un aller-retour ne peut pas descendre sous ~69 ms de
pure quantification de frame. La latence perçue est bornée par le temps de
frame, pas par ENet — elle se corrigera en réglant le maillage, pas le code
réseau.

---

## Reste à faire

Liste des éléments du GDD non développés, partiellement implémentés, ou non
fonctionnels dans le code actuel. Références de section entre parenthèses.

> **Règle de tenue de ce fichier** (posée le 2026-08-02, après un audit qui a
> trouvé **six contradictions** entre le tableau « Socle en place » et cette
> liste : noms culturels, lits/meubles, cuisine, royaumes PNJ, locales CJK,
> nombre de lignes). Le tableau et cette liste étaient mis à jour
> indépendamment, et personne ne relisait les deux. **Livrer une brique, c'est
> toucher les deux endroits dans le même geste** : ajouter la ligne au tableau
> *et* rayer ou amender le bullet correspondant ici. Un item barré qui explique
> où est passé le travail vaut mieux qu'un item supprimé.

### Priorité 1 — Trous dans la tranche verticale du MVP

Ces points sont dans le périmètre MVP (section 15) mais absents ou à l'état de stub.

- ~~**Créatures : les modèles (12.1)**~~ — **résolu** : les 18 fiches humaines pointent toutes sur `humanoide.glb`, et 28 modèles au total sont présents dans [models/creatures/](models/creatures/). Plus de capsules colorées. Pipeline figé le 2026-07-26 : **Blockbench → glTF/`.glb`**. ~~Il reste que ces modèles ne sont pas versionnés~~ — **périmé, vérifié le 2026-08-09** : les 200 fichiers de `models/` sont suivis par git (`git ls-files models`), plus rien à perdre à un `git clean`.
- **PNJ dans la boucle** — *fait le 2026-08-01* : les villages se peuplent d'habitants dérivés de (cellule, graine), chacun rattaché à un bâtiment, avec un métier parmi les 11 de 8.4 et une routine jour/nuit. Ce sont des `Creature` ordinaires — aucune classe PNJ, conformément à 12.1. Restent le dialogue, la relation qui évolue, le commerce et la persistance des morts (décimation).
- ~~**Compétences assemblées (5.1, F.2, B.4) — LE trou du MVP**~~ — **comblé le 2026-08-03.** Le GDD décrivait un système Noita/Elin à trois étages ; il existe. **36 modules** en trois rôles (`effet` / `modificateur` / `declencheur`), assemblés dans le menu de combat au **glisser-déposer** ; un multicast consomme les N effets qui le suivent, un déclencheur porte une charge utile récursive. Emplacements dérivés des compétences (`2 + N/20` plafonné à 6 pour les compétences, `2 + N/25` plafonné à 5 pour les modules), coût de mana composé par A.6 atténué par la conductivité des matériaux. Les modules s'obtiennent **uniquement** par lecture d'un livre, avec le jet A.7 et ses échecs gradués ; les livres ne se trouvent qu'en donjon. Le loadout codé en dur a disparu — sondes `--probe-assemblage`, `--probe-modules`. *Restent ouverts :* les **12 modules manquants** sur les 48 de F.2, et le **contenu éditorial** des 8 domaines de grimoire et 4 manuels (C.6), qui n'est pas du code.
- **Résolveur de modificateurs (E.4)** — *socle posé le 2026-08-02*. [`StatModifiers`](systems/progression/stat_modifiers.gd) applique `(base + Σ add) × Π mult` avec des sources nommées, posables et **retirables** — c'est le retrait qu'aucun code en dur ne savait faire, et la raison d'être d'E.4. Le joueur y fait passer ses malus de faim (A.9) et de fatigue (E.21), qui étaient testés en dur dans `effective_stat` ; la sonde `--probe-modificateurs` vérifie l'algèbre, le retrait, l'idempotence, l'absence de fuite, et surtout la **non-régression** sur les quatre combinaisons faim/fatigue. Restent à brancher, et c'est désormais un travail d'ajout et non de conception : **équipement (A.4.4)**, **statuts (F.4)**, **auras de modules (5.1)**, **humeur des PNJ**. Le résolveur n'est **pas sérialisé**, volontairement : tout ce qu'il porte dérive d'un état qui l'est déjà (voir l'en-tête du fichier).
- ~~**Statuts (F.4)**~~ — **faits le 2026-08-03.** Les 14 statuts sont en données (`data/status_effects/`), portés par un `StatusTracker` qui enregistre ses modificateurs auprès du résolveur E.4 sous la source `statut:<id>` et rend les dégâts périodiques **sans jamais toucher à la santé lui-même** — un statut ne doit contourner ni le stagger ni la mort. Appliqués par les modules et par les zones persistantes (`ZoneManager`). *Reste ouvert :* le **risque d'infection du cru** (F.5), que A.9.1 suppose et que rien ne déclenche encore.
- **Emplacements d'équipement (6.2)** — *partiel* : les 13 emplacements, l'armure et la mitigation A.4.2 fonctionnent. Les **boucliers** (3 modèles, blocage élargi, absorption d'endurance) et les **53 compétences** (une par arme, maîtrises de type de dégâts, Dual Wielding / Bouclier / Deux Mains) existent depuis le 2026-08-01 ; Deux Mains et Bouclier progressent, Dual Wielding attend son système. Restent les **morphologies non-humanoïdes** (`equip_slots` de B.5) et l'usage des slots `arme_1`/`arme_2` par le combat, qui lit encore l'objet en main.
- **Effets d'équipement passifs (A.4.4)**, **pools de loot (F.7)** et **stats étendues des matériaux (A.4.5)** — non appliqués : anneaux, amulettes, accessoires et dos s'équipent mais ne font encore rien. Le butin de créature se limite à viande + peau ; pas d'objets, d'or, ni la **statue 1:1** de F.3.
- **Contenu des POI** — camps, sanctuaires et filons majeurs ont été **RETIRÉS** le 2026-08-01 (décision de l'auteur) : ils n'avaient aucun contenu et leurs pastilles menaient à du vide. Il ne reste que **village** et **donjon**. Pour les réintroduire, voir le commentaire de `POIGenerator.POI_TYPES` — l'ordre de la liste est signifiant. Les **villages**, eux, ont été refaits le 2026-08-01 : six archétypes de bâtiment, toitures en pente, fenêtres, planchers, place pavée, champs, et des habitants. Restent l'**intérieur** (aucun mobilier) et la fonction des bâtiments (voir « Différé »).
- **Donjons (E.29)** — *largement traité le 2026-08-02* : 7 gabarits de salle / 3 connecteurs, 8 à 18 salles par étage, plusieurs étages, boss de fin (chef de bande) qui lâche un coffre, butin au sol. Restent les **salles à thème** (aucune n'a de rôle déclaré : ni salle de garde, ni réserve, ni piège), le **peuplement en créatures** hors boss, et la **réapparition** de nouveaux donjons ailleurs après nettoyage.
- **Progression par le potentiel (6.4)** — *à moitié*, et la boucle est coupée en **trois** points, pas un :
  1. Les plats cuisinés créditent bien le potentiel **de stat** ([`_credit_potential()`](scenes/entities/player.gd#L2617)), mais **rien ne le consomme** : les 6 stats de C.1 sont figées à la création. Le GDD ne chiffre aucune source d'XP de stat — c'est une décision de design à prendre, pas un bug.
  2. ~~Le **plancher de potentiel par race/classe** n'est pas appliqué.~~ **Corrigé le 2026-08-02.** Les données étaient bonnes (4 races et 5 classes sur 6 portent leurs `base_potentials` ; Humain, Échomorphe et Vagabond sont vides *par design* — leur identité passe par le `xp_modifier` ou les points de création) et [player.gd](scenes/entities/player.gd#L324) les appliquait bien à la création. Le défaut était **un cran plus loin** : `PlayerSkills` ne stockait aucun plancher par compétence, et le level up ramenait tout le monde à la constante 80. Le potentiel de Forge 120 d'un nain n'était donc qu'une avance de départ qui s'évaporait aux premiers niveaux, alors que 6.4 le veut permanent (*« un nain garde toujours un bon potentiel de Forge, même sans l'entretenir »*). Chaque compétence porte maintenant son `base_potential`, posé par race puis classe, respecté au level up et persisté.
     *Reste ouvert :* C.3 prévoit aussi des planchers **bas** (« Mage : armes lourdes 60 ») pour marquer les faiblesses. Aucune donnée n'en porte — toutes les valeurs sont ≥ 110. C'est un choix d'équilibrage à faire, pas un bug.
  3. Les **entraîneurs PNJ** (20 or × niveau → +10 de potentiel), troisième source prévue par A.1 et puits d'or de 7.6, n'existent pas.

  Le potentiel de **compétence**, lui, est bien consommé aux montées de niveau.

### Différé volontairement (décision de l'auteur, 2026-08-01)

- **Fonction des bâtiments de village** — un bâtiment est aujourd'hui un volume
  clos sans rôle déclaré : ni forge, ni taverne, ni étal, ni ferme. Tant que
  cette fonction n'existe pas, `VillagePopulation.work_position` envoie TOUS les
  habitants sur la place centrale, quel que soit leur métier. C'est provisoire
  et assumé : un village où les gens convergent le matin et rentrent le soir est
  déjà lisible, alors qu'un habitant planté devant sa porte ne raconterait rien.
  Cette brique débloquera d'un coup le vrai lieu de travail (8.4), le commerce
  sur place et la halle comme point de revendication (3.4).

- **Royaumes PNJ (14.4 / E.27 / B.9)** — *fait le 2026-08-01* : génération déterministe par secteurs de 64×64 cellules, 0-2 capitales par secteur placées sur les sites favorables, quatre tailles, six gouvernances, race dominante issue du biome, territoire par croissance à coût (il contourne les massifs et s'arrête devant l'eau). Aucune génération de terrain n'est nécessaire — la carte affiche les royaumes lointains avant toute visite, et `--probe-royaumes` le vérifie. Mesuré : ~1,3 % du monde sous autorité, 9 royaumes sur 39 km². Les **lois** (E.26) sont générées par royaume — meurtre, vol, agression, plus une interdiction arbitraire d'objet dans un royaume sur deux — avec détection par témoin (jet Discrétion contre Perception : sans témoin, l'infraction est ignorée) et conséquences réelles (amende, saisie, gardes hostiles). Une anarchie n'a aucune loi, faute de pouvoir les faire appliquer. Restent les **douanes** (tarifs par catégorie), la **diplomatie** (14.4), la **succession** (12.3) et le **royaume du joueur** (14.1/14.5).

### Priorité 2 — Systèmes de vie simulée (sections 7, 12, 14)

- **PNJ vivants** — *population faite* (voir Priorité 1). Restent le LOD de simulation à 3 niveaux (E.18) et l'abstraction hors-site (E.6) : hors de portée du joueur, un village cesse purement et simplement d'exister.
- **Dialogue PNJ (E.23)** — *fait le 2026-08-01* : menu contextuel (pas d'arbre), 29 gabarits de répliques d'ambiance data-driven à conditions (métier, relation, heure), tirage pondéré et anti-répétition. Options **Parler** et **Offrir un cadeau** actives ; Commercer, Quêtes et Recruter affichées désactivées avec leur raison — leurs systèmes n'existent pas. Restent les **préférences de cadeau par tags** et les conditions sur **événements récents**.
- **Réputation et relations (7.2)** — *fait le 2026-08-01* : les cinq niveaux (individuel, race, village, **royaume**, global), les paliers du GDD, la propagation d'une action sur les échelons collectifs, l'hostilité à vue sous −50 et le prix marchand. Reste le contrecoup chez les **races rivales**, implémenté mais sans données (`rivals` est `null` partout).
- **Quêtes et guildes (7.3, B.7)** — aucun `data/quest_templates/`, aucune des 12 guildes.
- **Agriculture et élevage (7.4)** — absents (les 6 plantes ne sont que récoltables).
- **Habitat / détection de pièces (7.5, E.5)** — absents.
- **Meubles (F.6, 16)** — **1 sur 16** : le **lit** est craftable et sert de point de résurrection (A.10) et de sommeil (E.21). Manquent les 15 autres : coffres, garde-manger, bibliothèques, etc.
- **Cuisine, alchimie et nourriture (7.7)** — la **cuisine est faite** : fourneau, compétence Cuisine, 4 plats (`data/plats/`), et un plat cuisiné rend la nutrition pleine **et crédite le potentiel de stat** (A.9.1) — le cru reste à 50 % sans bonus. Manquent les **parties d'alchimie** (yeux, griffes, os) et l'**alambic**, et il n'y a de données ni pour les **18 consommables (F.5)**, ni pour les **12 potions (F.9)**, ni pour les **15 meubles restants (F.6)**, ni pour les **14 statuts (F.4)**.
- **Économie et flux d'or (7.6, A.8.1)** — pas de portefeuilles PNJ, ni taxes, ni entretien.
- **Villages : conquête et succession (3.4, 12.3)** — la **population** et la **décimation** existent depuis le 2026-08-01 : les morts sont persistés (on n'enregistre que les absences, un village intact ne coûte rien), un village entièrement vidé devient un POI abandonné, et le repeuplement hebdomadaire d'E.25 tourne. Restent la **conquête** (halle comme point de revendication, jet de Leadership) et la **succession**. La **capacité** est dérivée du nombre de bâtiments, pas encore de la détection de pièces d'E.5.
- **Âge des PNJ (12.2)**, **familles/statuts (12.3)**, **monstres rares (12.4)** — absents.
- ~~**Génération de noms culturels (12.5, E.31, B.11)**~~ — **fait le 2026-08-02**, voir la ligne « Noms culturels » du tableau ci-dessus : 10 cultures en données, `NameGenerator`, sonde `--probe-noms`.
- **Compagnons (E.17)** et recrutement — le signal `creature_recruited` n'est émis nulle part.
- **Raids et menaces (E.7)** — le signal `raid_resolved` n'est émis nulle part.
- **IA de créature (E.16)** — les 4 profils de base marchent (errance, poursuite, fuite, riposte) ; restent les **besoins**, les **routines quotidiennes**, le **pathfinding** (les créatures vont en ligne droite) et les caravanes inter-villages.

### Priorité 3 — Systèmes de monde et d'ambiance

- **Éclairage local — partiel** : la propagation 0-15 fonctionne (torches, lave, gemmes ; décroissance de 1/bloc, blocage par les opaques, cuisson dans la couleur de sommet). Restent trois écarts avec G.3, tous documentés dans [light_field.gd](systems/voxel/light_field.gd) :
  - la propagation est **recalculée par chunk maillé**, pas incrémentale (G.3 : deltas locaux, file dédiée, budget par tick) ;
  - une source à plus d'**un bloc hors du chunk** n'éclaire pas dedans (visible seulement pour une torche collée à une bordure de chunk) ;
  - **pas de skylight** : le jour est un uniform global, pas une propagation par colonne.
- **Météo (E.28)** — totalement absente. Saisons volontairement reportées (section 16).
- **Eau et liquides (E.22)** — les liquides sont des blocs **statiques** meshés (avec abaissement de surface) ; aucun écoulement, aucune propagation, aucune nage.
- **Dérive de la corruption (3.1, E.20)** — absente.
- **Explosions (A.11)** — absentes.
- **Dimension magique / démons** — prévue, non commencée.
- **Fertilité des sols** — *partielle* : le champ de fertilité existe et **module déjà la densité de végétation dans un biome** ([noise_generator.gd](systems/worldgen/noise_generator.gd#L928), 2026-07-26). Ce qui manque, c'est son **usage agricole** (7.4) : rendement des cultures, épuisement, fumure.

### Priorité 4 — Royaume du joueur (section 14, endgame)

- Expansion territoriale au-delà du claim simple (14.1) : les claims existent (`ClaimManager`, 4 rôles) mais ne produisent ni n'exploitent rien.
- Population et exploitation (14.2), halls de guilde (14.3).
- Défense (14.5), entretien et taxes (14.6).
- **Royaumes PNJ (E.27) et lois (E.26) : faits le 2026-08-01** — voir le bloc « Différé » ci-dessus, qui fait foi. Ce qui reste vraiment ouvert ici, c'est le **royaume du joueur** : statut, gouvernance choisie, diplomatie (14.4), douanes, succession (12.3). Il n'y a pas de `data/kingdoms/` parce que les royaumes PNJ sont **générés** par secteur, pas écrits en données — B.9 décrit le schéma d'une entrée créée à la volée.

### Priorité 5 — Outils, contenu et finition

- **Tables de sculpture / éditeur (13, E.9)** — la sculpture libre en sous-blocs fonctionne, mais l'éditeur d'objets custom n'existe pas.
- **Mode tactique (5.0)** — `TickManager.tactical_mode` est correctement implémenté (les ticks cessent de suivre l'horloge, `push_ticks()` les avance à la demande) mais n'est basculé que par le **menu de triche** ([cheat_menu.gd](scenes/ui/cheat_menu.gd#L153)). Un pilier du GDD — *« jouer façon roguelike au tour par tour »* — réduit à un outil de debug : pas de déclencheur de jeu, pas d'UI d'action time, pas d'affichage de fourchette de dégâts au survol (E.3). À noter que le combat directionnel (E.3.1) rend ce mode **plus difficile à concevoir** qu'à l'époque du jet de toucher : une attaque visée à la souris ne se découpe pas naturellement en tours. À retrancher.
- **Grimoires et manuels (C.6, A.7)** — le **système** existe depuis le 2026-08-03 (fabrication de livre, jet de lecture A.7, échecs gradués, apprentissage de module) ; c'est le **contenu éditorial** des 8 domaines et 4 manuels qui n'est pas écrit. `BookFactory` tire dans les modules par domaine, donc un livre est fonctionnel mais anonyme.
- **Tooltips contextuels d'onboarding (E.19)** — absents.
- **Véhicules (E.24)** — absents (extension future assumée).
- **Multijoueur (8, E.11) — le plus gros morceau qui reste au projet.** Inventaire fait le 2026-08-04 : **cinq RPC en tout**, quatre pour les blocs et un pour la pose des joueurs. Tout ce qui a été bâti depuis le 2026-07-20 est solo. **Fondation posée** : poignée de main de monde (la graine n'était jamais transmise) et horloge host-autoritaire. **Ordre de bataille pour la suite**, du plus structurant au moins :
  1. **Créatures** — un client ne voit personne. C'est le gap le plus visible, et il commande le reste : sans entités répliquées, le combat n'a rien à synchroniser.
  2. **Combat** — dégâts et morts sont résolus localement chez chacun. L'hôte doit trancher.
  3. **État du monde partagé** — coffres, butin au sol, villages, pousses.
  4. **Dimensions** — le routage RPC est overworld-only ; un client qui entre en donjon ne verrait rien de ce que fait l'hôte.
  5. **Anti-triche** (portée, possession) et **prédiction client**, qui n'ont de sens qu'une fois le reste en place.
- **Structures et routes (9.2)** — routes en croix générées dans les villes, mais aucun réseau routier inter-cellules.
- **Audio / musique** — hors périmètre du GDD, rien en place. Voir « Ce qu'il faut créer ».
- **Nom du projet et lore (16)** — à écrire.

### Dette technique / hygiène

- **Mesures de perf : distance d'affichage** — les benchs forcent désormais le rayon par défaut (8) et ignorent `display.cfg`. Un réglage joueur à 14 triplait le nombre de chunks et faisait lire *245 → 66 fps* comme une régression, alors qu'aucun code de rendu n'avait changé.
- **Équilibrage de l'armure** : un jeu complet de fer qualité 1.2 donne 5d4 de réduction (moyenne 12,5) contre ~8 de dégâts bruts pour une arme de départ — mesuré par la sonde, les dégâts encaissés chutent de 2594 à 192 sur 400 coups. Les formules A.4.1/A.4.2 sont appliquées à la lettre : c'est le **chiffrage par défaut du GDD qui est à équilibrer en playtest**, pas l'implémentation.
- **[player.gd](scenes/entities/player.gd) est un god object** (relevé le 2026-08-02) : **3 284 lignes, 133 fonctions**. Il porte le déplacement, le raycast bloc *et* sous-bloc, la pose et la sculpture, la physique de balayage d'arme, les gardes et boucliers, l'inertie des mains, la hotbar et ses liaisons, l'équipement, la faim, la fatigue, le sommeil, la mort, le respawn, les claims, le voyage rapide, les lois, le dialogue et le loot. Trois découpages se lisent tout seuls dans la liste des fonctions, aucun ne demande de changement de comportement : `PlayerCombat` (~800 l. — gardes, balayage, hitboxes, cibles), `PlayerHotbar` (~250 l. — liaisons, banques, résolution d'entrée), `PlayerSurvival` (faim, fatigue, sommeil, mort, respawn).
- **Signaux EventBus morts** : `creature_recruited`, `book_read` et `raid_resolved` sont déclarés dans [EventBus.gd](autoload/EventBus.gd) et **émis nulle part** — ce sont les trois systèmes absents (compagnons E.17, livres 5.1, raids E.7) qui se signalent d'eux-mêmes. Les garder déclarés est utile ; savoir qu'ils sont muets l'est aussi.
- **Compétences défensives jamais entraînées** : `esquive` et `encaissement` existent en données, et E.3 étape 6 prévoit que le défenseur y gagne de l'XP à chaque coup reçu. Comme le jet de défense a disparu avec E.3.1, **aucun `gain_xp` ne les cible** : deux compétences mortes. À raccrocher au combat directionnel (esquive sur un coup évité de justesse, encaissement sur un coup absorbé par l'armure).
- **⚠️ LE RUNNER N'EST PAS DÉTERMINISTE — au moins trois sondes échouent par intermittence** (mesuré le 2026-08-02 sur quatre exécutions complètes). Chaque exécution rend un ensemble d'échecs *différent* : une fois `--probe-corps`, une fois `--probe-combat`, une fois `--probe-dungeon` — et toutes les trois **passent lancées isolément**. C'est le défaut le plus grave de l'outillage, plus grave que n'importe quelle sonde manquante : un runner qui ment une fois sur trois n'est plus un filet, et on prend l'habitude de relancer jusqu'au vert, ce qui revient à ne plus tester du tout. À traiter **avant** de convertir la moindre sonde supplémentaire en assertive. Deux causes identifiées, une non élucidée :
  - **`--probe-corps` — assertion de perf sensible à la charge.** Le coût d'un spawn (médiane sur 12, seuil 12 ms) rend **8,6-8,7 ms lancée seule** mais **17,9 ms en fin de `run_probes.sh`**. Ce n'est pas une régression, c'est la charge accumulée par les sondes précédentes. À trancher : sortir l'assertion de perf du runner en gardant la sonde fonctionnelle dedans, ou lui donner une marge de charge explicite.
  - **`--probe-combat` — sonde non idempotente.** Elle échoue environ **une fois sur trois**, toujours sur la même assertion (« sortie d'allonge pendant le wind-up »), avec un résultat différent à chaque fois (60→51, 60→56, 60→60). La cause se lit dans son propre journal : le joueur **dérive d'un run à l'autre** (caméra en 156, puis 163, puis 169) parce que la sonde réutilise le monde persisté au lieu de repartir d'un état fixe. C'est exactement le défaut déjà corrigé pour les sondes de sauvegarde — même remède : un point de départ imposé, indépendant de l'état laissé par le run précédent. Une assertion de portée géométrique ne peut pas être fiable si la position de départ change.
  - **`--probe-dungeon` — cause non élucidée.** Observée en échec une fois en suite, verte deux fois de suite lancée seule. À instrumenter avant de conclure ; ne pas la « corriger » au jugé.

  Piste transversale pour les trois : les sondes **partagent le monde persisté par défaut** et se le passent dans l'état où la précédente l'a laissé. Le remède générique est celui déjà appliqué aux sondes de sauvegarde — un monde de sonde dédié, remis à zéro — plutôt que trois correctifs séparés.
- **⚠️ `--probe-police` ÉCHOUE actuellement** (suite lancée le 2026-08-02 : **16/17**). Les traductions `ja` et `zh_Hans` ont reçu de nouvelles clés sans que la police pixel soit régénérée : **21 caractères japonais et 38 chinois n'ont aucun glyphe** et s'afficheront en tofu. C'est exactement le mode de panne que la sonde a été écrite pour attraper, et il fonctionne. Correctif : relancer `tools/generate_pixel_font.py`, puis réimporter. *Non fait ici : les CSV concernés appartiennent à un lot encore en cours dans l'arbre de travail, et régénérer la police maintenant figerait un état partiel.*
- **Traductions compilées périmées** : les `.csv` sont plus récents que les `.translation` (mesuré le 2026-08-02, 17:15 contre 16:52). Godot lit les `.translation` — sans réimport, les clés récentes s'affichent en brut. Voir la note en bas de ce fichier.
- **Commentaires d'en-tête périmés** : [equipment.gd](systems/inventory/equipment.gd#L10) affirme encore que Dual Wielding / Bouclier / Deux Mains *« n'existent pas en données (data/skills/) »* — les trois fichiers sont là depuis le 2026-08-01. Ce projet documente sa dette en prose plutôt qu'en `TODO` (il n'y en a **aucun** dans les 30 000 lignes, et c'est un bon choix) — mais la prose périme en silence, sans que rien ne la signale.

### Corrigé — dégradations qui ne se voyaient qu'à la longue

Quatre problèmes sans symptôme immédiat, qui empiraient avec le temps de jeu.
Tous corrigés le 2026-07-27, tous couverts par une sonde.

- **Plafond de palette (256)** : les textures indexées par id runtime (couleurs, bruit, style, masque des liquides) étaient figées à 256 alors que le catalogue en comptait 242 — 14 de marge. Au 257e matériau, `set_pixel` serait sorti des bornes et le masque des liquides aurait **silencieusement** ignoré les ids suivants. Dimensionnées sur le catalogue (`GameData.palette_size()`). Le catalogue de blocs est repassé à 243 ids une fois viandes et peaux sorties de la palette, mais le plafond était bien réel et le restera : c'est un jeu à très forte densité de contenu.
- **Autosave à coût croissant** : chaque sauvegarde réécrivait **tous** les chunks modifiés depuis le début de la partie, toutes les 5 minutes, et les gardait tous en mémoire le temps de l'écriture. Après une longue session de construction, des milliers de fichiers repassaient alors que deux ou trois avaient bougé. Seuls les chunks **retouchés depuis la dernière écriture** sont réécrits (sonde `--probe-save-incr` : 1 fichier au lieu de 3, relecture complète intacte).
- **Brouillard de guerre non borné** : `ExplorationManager` gardait une entrée par chunk `(x, z, y)` visité — jusqu'à 64 pour une seule colonne parcourue de haut en bas — et sérialisait le tout en JSON à chaque autosave. Rien ne le bornait. Stockage réécrit en **un masque de 64 bits par colonne** : exact (le monde fait exactement 64 niveaux de chunks), et jusqu'à 64× plus compact. Les sauvegardes existantes restent lisibles.
- **Course de données au hot-reload (F5)** : `load_all()` vidait et reconstruisait `materials` / `material_by_runtime` / `liquid_mask` pendant que les threads de meshing les parcouraient sans verrou. La lecture sans verrou n'est sûre que parce que ces données sont figées après le boot — F5 rompait cette garantie. Le rechargement attend maintenant la fin des tâches en vol.

### Corrigé au passage

- **Carte du monde** : le brouillard de guerre testait `chunk_y = 0` en dur — explorer en altitude ou sous terre ne révélait donc **rien** sur la carte. Une vue de dessus interroge maintenant la colonne entière.
- **Sondes de sauvegarde non idempotentes** : elles réutilisaient le monde par défaut et accumulaient l'état d'un run à l'autre, faisant échouer `--probe-save-verify` au deuxième passage — un échec de test sans bug dans le code testé. Elles écrivent dans `user://saves/_sondes`, remis à zéro à chaque `--probe-save`.
- **Répartition de la faune par tags de biome** : le filtrage empêche bien l'ours polaire dans le désert, mais les tags larges (`foret`, `froid`) restent grossiers — un ours brun peut apparaître en forêt tropicale sèche parce que les deux portent `foret`. À affiner (tags plus fins, ou pondération par biome) quand la faune sera jouée.
- **Barème de stats des créatures** : F.3 ne donne qu'un « niveau de combat approximatif », aucun barème. Formule linéaire par défaut calée sur le sanglier existant — à équilibrer en playtest.
- **Régénération de santé** : le GDD ne la chiffre nulle part (A.5.1 ne donne que le maximum, A.9 se contente de la moduler). Valeur par défaut posée dans [player.gd](scenes/entities/player.gd) — 1 PV / 10 s, calquée sur la cadence du mana (A.5) : **à trancher et équilibrer**.
- ~~Logs de bench et screenshots de debug à la racine~~ — **fait (2026-07-26)** : tout est dans `debug/`, hors du versionné (`.gitignore`) et hors de l'import Godot (`.gdignore`) ; les captures y sont écrites via `_capture_path()` dans [main.gd](scenes/main.gd).
- **Rendu de la génération de monde** : les briques techniques sont validées, mais le rendu et la distribution visuelle sont à retravailler.
- ~~**Meshing au-dessus du budget E.14**~~ — **résolu le 2026-08-09** par ce que le GDD prescrivait lui-même en E.14 : le cœur du mesher est passé en GDExtension C++ (`native/`), 17,1 → **2,55 ms/chunk**, budget < 4 ms tenu. Voir « Le mesher natif » et la section Performance.
- Budgets de perf G.8 à re-vérifier après chaque ajout de système simulé.

### Limites arbitraires levées

Le jeu vise une très forte densité de contenu : ces plafonds auraient bloqué
l'ajout de contenu sans erreur explicite, en demandant une refonte tardive.

- **Palette de matériaux (256)** → dimensionnée sur le catalogue. À 311 ids, la limite était déjà franchie.
- **Hotbar (9 banques × 9 = 81 entrées)** → remplacée par des **liaisons explicites** : la hotbar n'est plus une fenêtre glissante sur l'inventaire (dont le contenu changeait tout seul au moindre ramassage), mais une table d'assignations. Le nombre de banques suit les liaisons posées.
- **Unicité obligatoire des couleurs de matériaux** → levée (décision auteur). C'était une **erreur bloquante** : chaque ajout imposait de trouver une teinte libre, ce qui plafonnait de fait le catalogue. Seules les couleurs *réservées* (marqueurs techniques) restent interdites.
- **Sélecteur de langue câblé sur deux entrées** (« 0 si fr sinon en ») → table de données ; une langue de plus est une ligne. Toute 3e langue était invisible dans l'interface **même une fois traduite**.
- **Brouillard de guerre testé à `chunk_y = 0`** → interrogation par colonne (voir plus haut).

Restent **volontairement** bornés, comme budgets de design documentés et non
comme limites techniques : 64 créatures actives par zone (E.14), 512 blocs
subdivisés par chunk (G.2), 64 niveaux de chunks en hauteur (3.2). Le stockage
voxel est en `u16` : **65 535 matériaux** possibles, sans réécriture.

### Points de fragilité connus, non corrigés

- **Migration de sauvegarde : le socle existe, aucune migration n'est écrite** — *corrigé partiellement le 2026-08-01*. `SAVE_VERSION` vaut toujours 1, mais l'écart de version ne fait plus repartir sur un monde neuf : la chaîne `MIGRATIONS` + `MIN_SUPPORTED_VERSION` est en place, une copie de sûreté est prise avant toute migration, et l'échec est un **refus motivé affiché au joueur**. Reste à écrire la première migration réelle au prochain incrément du format.
- **`_edits` ne se nettoie jamais** : c'est voulu (il est la vérité des modifications, base du diff E.10), mais il croît avec tout ce que le joueur pose. Poser puis casser un bloc laisse une entrée. Un compactage (oublier les modifications redevenues identiques à la génération) sera nécessaire pour les très longues parties.
- **Créatures non sauvegardées** : le spawn naturel les régénère, les boss de donjon renaissent tant que le donjon n'est pas nettoyé. Assumé et documenté, mais ça se verra dès que les PNJ auront une identité (12.3).

## Ce qu'il faut créer — contenu artistique et données

Le code lit tout en données : ces manques sont du **contenu**, pas du
développement. Chacun est cerné et chiffré au 2026-08-04.

### Sprites d'objets — 23 sur 40 manquants

17 objets ont leurs deux sprites (`manche` + `tete`, teintés par matériau au
runtime via `sprite_tint`). **23 n'en ont aucun** et s'affichent en repli :

> `baton_ferre`, `bottes`, `casque`, `cuirasse`, `ecu`, `epee_courte`,
> `espadon`, `faux_de_guerre`, `gants`, `gourdin`, `grimoire`, `hache_double`,
> `hachette`, `hallebarde`, `jambieres`, `manuel_de_combat`, `marteau_guerre`,
> `masse_ailettes`, `pavois`, `pioche_combat`, `rapiere`, `rondache`, `trident`

Format : PNG dans `assets/weapons/` ou `assets/tools/`, **teinte neutre** (le
jeu la colore selon le matériau forgé — un sprite déjà coloré donnera un fer
qui a l'air en bois). Voir `data/items/hache.json` pour le gabarit.

### Modèles .vox — 4 sur 40

Seuls quatre objets portent un `vox_model`. Les foreuses ont été livrées
**volontairement sans** : un chemin vers un fichier absent fait échouer
`VoxLoader` au chargement, ce qui s'est déjà produit avec les livres. Le repli
procédural fonctionne, mais un vrai modèle vaut mieux.

### Créatures — 28 modèles pour 18 fiches

`models/creatures/` contient **28 `.glb`** (loup, ours, sanglier, cerf,
crocodile, requin, araignée, chauve-souris, serpent, rat, aigle, plus dragon,
spectre et raptor sans fiche correspondante). Le catalogue, lui, ne compte que
**18 fiches, toutes humaines** — les 19 espèces animales ont été retirées le
2026-08-02 faute de rigs. **La condition posée est remplie** : les restaurer
est redevenu un travail de données (`git show 8788dbd:data/creatures/<id>.json`).

### Audio — rien

Aucun son, aucune musique, aucun bruitage. Hors périmètre du GDD à ce jour :
c'est un chantier entier à ouvrir, pas un trou à combler.

### Textes de contenu

- **8 domaines de grimoire et 4 manuels de combat (C.6)** — les fiches
  n'existent pas ; `BookFactory` tire dans les modules par domaine, donc le
  système marche mais le contenu éditorial est vide.
- **Nom du projet et lore (§16 du GDD)** — à écrire.
- **Dialogues** — un seul fichier dans `data/dialogue/`.

---

## Ce qu'il faut équilibrer

Ces valeurs sont des **défauts du GDD appliqués à la lettre**. Le code les
respecte ; ce sont les chiffres qui demandent du playtest. Distinguer les deux
est important : ce ne sont pas des bugs.

- **L'armure écrase les dégâts.** Un jeu complet de fer qualité 1.2 donne 5d4 de
  réduction (moyenne 12,5) contre ~8 de dégâts bruts pour une arme de départ.
  Mesuré : les dégâts encaissés chutent de **2594 à 192 sur 400 coups**. Les
  formules A.4.1/A.4.2 sont correctes — c'est leur chiffrage par défaut qui rend
  un joueur équipé quasi invulnérable.
- **Coût en mana des assemblages (A.6)** — la conductivité des matériaux peut
  retrancher jusqu'à 65 % du coût. Jamais joué en conditions réelles : un sort
  à multicast peut être soit inutilisable, soit gratuit, personne ne le sait.
- **Jet de lecture des livres (A.7)** — la difficulté des trois crans (facile /
  moyen / redoutable) n'a été éprouvée qu'au menu de triche.
- **Temps d'abattage d'un arbre** — proportionnel au **volume de bois**, qui a
  beaucoup grossi avec les arbres détaillés du 2026-08-03. Un chêne fait
  maintenant plusieurs centaines de blocs : à vérifier qu'abattre ne prend pas
  une éternité.
- **Remise de temps des foreuses** (`DRILL_TIME_DISCOUNT = 0.6`) — un carré coûte
  60 % du temps de ses blocs pris un par un. Valeur choisie pour que l'outil soit
  franchement utile sans rendre la progression de récolte inutile ; à confronter
  au jeu.
- **Croissance des pousses** (`GROWTH_TICKS = 3000`, ≈ un jour et demi de jeu) —
  assez long pour que planter une forêt soit un projet, assez court pour en voir
  le résultat. Jamais joué sur la durée.
- **Densité des donjons et de leur butin** — 2/4/6 étages selon le danger, avec
  un coffre de boss au fond. La courbe de récompense n'a jamais été confrontée à
  la difficulté réelle.
- **Compétences défensives mortes** : `esquive` et `encaissement` existent mais
  **aucun `gain_xp` ne les cible** depuis que le jet de défense a disparu avec
  E.3.1. Ce n'est pas qu'un équilibrage : deux compétences ne progressent
  jamais, quoi que fasse le joueur.

---

## Sondes de validation

**Suite agrégée (2026-08-01)** — une seule commande répond à « est-ce que
quelque chose est cassé ? » :

```
tools/run_probes.sh              # sondes assertives, headless, code de sortie 0/1
tools/run_probes.sh --list       # ce qu'elle contient
```

Elle n'enchaîne que les sondes qui rendent un **verdict** (`finish(ok, tag)`).
Compté le 2026-08-04 : **58 drapeaux au registre** (douze de plus qu'au
2026-08-02, un par lot livré depuis) ; le runner en enchaîne **29**. Les
assertives qui restent dehors sont les sondes de **capture** (`--test-ui`,
`--test-corps`, `--test-triche`, `--test-carte`, `--test-arbres`), exclues
volontairement : en headless leurs captures sont sautées, donc leur verdict ne
vaudrait plus grand-chose.

**La couverture s'était perdue en route, et c'est instructif.** Le 2026-08-02
elle était annoncée complète ; au 2026-08-04, **neuf sondes assertives livrées
depuis n'y étaient pas** — arbres, pousses, foreuses, dimensions, triche,
cycle de vie des villages, perf des royaumes, assemblage, mains. Chacune avait
été écrite, exécutée une fois, et jamais rebranchée. Une sonde qui ne tourne pas
ne protège rien : **ajouter la ligne au runner fait partie de la livraison**,
pas d'un rangement ultérieur. Elles y sont désormais.

Le chantier restant est ailleurs et il est plus lourd : **~25 sondes n'impriment
qu'un rapport** qu'un humain doit lire et ne peuvent rien signaler à une CI. Les
convertir en verdicts reste l'hygiène la plus rentable du projet.

**Verdict du runner au 2026-08-04 : 26/28.** Les deux rouges, nommés parce qu'un
échec tu ne se corrige pas :

- **`--probe-police`** — rouge de longue date, glyphes CJK.
- **`--probe-corps`** — *« coût d'un spawn : 18,6 ms »* contre 12 attendus.
  C'est le montage d'un corps riggé, le dernier poste lourd du jeu, et il **ne
  se laisse pas réduire** : chaque brique a été chronométrée le 2026-08-04
  (instanciation du `.glb` 0,8 ms, peau 0,4 ms, boîtes de coups 0,03 ms,
  `PlayerBody.setup` 6 ms) et aucune ne domine. Le tick, lui, ne le paie plus —
  la file de spawn est passée en frame. **Le seuil de la sonde n'a délibérément
  pas été relâché** pour la faire passer : il mesure un coût réel, et le faire
  disparaître du tableau de bord ne le ferait pas disparaître de la machine.
  Le vrai remède est de partager les maillages du rig entre instances.
Convertir les autres en sondes assertives est le chantier d'hygiène le plus
rentable du projet — le coût de leur absence s'est vu le 2026-08-01, où
`--test-input` plantait depuis la refonte du craft (2026-07-26) sur un champ
`_craft_list` supprimé, sans que rien ne le signale : la sonde n'a pas de code
de sortie, donc son crash passait pour du bruit de journal.

Chaque lot livré porte sa sonde headless, exécutable sans interface :

```
godot --headless --path . -- --probe-dimensions   # deux dimensions coexistent ; une SANS code dédié fonctionne
godot --headless --path . -- --probe-arbres       # dix silhouettes distinctes ; abattre par n'importe quel bloc
godot --headless --path . -- --probe-pousses      # la miniature ressemble à son essence, et elle pousse
godot --headless --path . -- --probe-foreuse      # emprise réelle, plan de la face, irrécoltabilité bloc par bloc
godot --headless --path . -- --probe-triche       # CHAQUE entrée de CHAQUE registre a un bouton
godot --headless --path . -- --probe-village-vie  # une référence morte ne bloque plus la relâche d'un village
godot --headless --path . -- --probe-royaumes-perf # aucun tick ne paie la génération d'un royaume
godot --headless --path . -- --probe-assemblage   # multicast, déclencheurs récursifs, coût de mana A.6
godot --headless --path . -- --probe-potentiel    # 6.4 : le plancher de race/classe tient au level up
godot --headless --path . -- --probe-modificateurs # E.4 : algèbre, retrait, non-régression faim/fatigue
godot --headless --path . -- --probe-touches      # commandes : aucune collision, remappe, persistance
godot --headless --path . -- --probe-police       # tout caractère traduit a bien un glyphe
godot --headless --path . -- --probe-interieur     # donjon : salles organiques, escaliers, butin, cloisonnement des dimensions
godot --headless --path . -- --probe-noms          # noms culturels : 10 cultures, determinisme, variete, heritage, ordre
godot --headless --path . -- --probe-butin        # paramétriques, couleurs uniques, palette, dépeçage
godot --headless --path . -- --probe-faune        # catalogue + cohérence des biomes + profils d'IA
godot --headless --path . -- --probe-faim         # A.9/A.9.1 : manger, seuils, famine
godot --headless --path . -- --probe-equipement   # 6.2/A.4.2 : emplacements, armure, poids
godot --headless --path . -- --probe-mort         # A.10 : pénalité, caches au sol, respawn
godot --headless --path . -- --probe-save         # écrit une sauvegarde de test...
godot --headless --path . -- --probe-save-verify  # ...et vérifie sa relecture
godot --headless --path . -- --probe-save-incr    # n'écrit que le delta, sans rien perdre
godot --headless --path . -- --probe-saves        # mondes illimités, suppression et ses garde-fous
godot --headless --path . -- --probe-mesh         # profil du meshing par phase (E.14)
godot --headless --path . -- --probe-survie       # cycle, sommeil, fatigue, cuisine, faune nocturne
godot --headless --path . -- --probe-invui        # lignes d'inventaire vs liaisons de hotbar
```

Les sondes de sauvegarde écrivent dans `user://saves/_sondes`, **jamais** dans
un monde du joueur, et `--probe-save` repart d'un dossier vide (la paire est
idempotente).

**Traductions** : `fr` et `en` font référence (toute clé manquante est signalée
une par une). `ja` et `zh_Hans` sont en cours — une clé absente retombe sur
l'anglais et le boot affiche leur taux de couverture. Ajouter une langue =
une ligne dans `LOCALES` ([start_menu.gd](scenes/ui/start_menu.gd)), une dans
`PARTIAL_LOCALES` et une dans `project.godot`.

**Après toute modification de `locale/*.csv`**, relancer un import
(`godot --headless --path . --editor --quit`) : Godot lit les `.translation`
compilés, pas les CSV — sans ça les nouvelles clés s'affichent en brut.

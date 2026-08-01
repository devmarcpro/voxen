# Voxen

Jeu de construction voxel / roguelite de vie simulée (Godot 4, GDScript, `gl_compatibility`).
Le design de référence fait autorité : voir [GDD.md](GDD.md).

---

## État actuel (au 2026-07-26)

Le projet a exécuté l'ordre de construction **D.3 étapes 1 à 8** ainsi que quelques
extras (boutique passive, menu de triche). ~15 000 lignes de GDScript.

**Socle en place :**

| Domaine | État |
|---|---|
| Data-driven (`GameData`) | 242 matériaux (blocs) + 68 **ressources** paramétriques (viandes/peaux, hors palette), 24 biomes, 20 compétences, 15 fonctionnalités, 18 objets (dont 5 armures), 41 transformations, 38 arbres, 6 plantes, 6 races, 6 classes, 4 modules, 37 créatures |
| Localisation (10.1) | `fr` / `en` complets et validés clé par clé ; `ja` / `zh_Hans` en cours (23 %), repli automatique sur l'anglais + rapport de couverture au boot |
| Génération du monde (E.2) | continents/océans, rivières & littoraux, strates, filons, grottes, biomes, arbres, plantes, POI, villes (coques de bâtiments), noms de monde |
| Voxel (4, G.2) | chunks multithreadés, meshing greedy, subdivision 32→16→8→4, LOD, ombrage voxel maison, édition instantanée |
| Joueur | déplacement, raycast bloc + sous-bloc, casser/poser/sculpter, récolte + XP, inventaire volumétrique, hotbar multi-banques, PV, mana |
| Équipement (6.2, A.4.2) | 13 emplacements, 5 pièces d'armure, dés de réduction réels en combat, poids porté, persistance — sonde `--probe-equipement` |
| Éclairage (G.3) | lumière de bloc 0-15 propagée depuis la `luminosite` des matériaux (torche 14, lave 14, gemmes), cuite dans la couleur de sommet, lue par le shader — s'ajoute au jour au lieu de le remplacer |
| Carte du monde | **une seule carte** (l'onglet du menu ouvre celle de la touche M) ; déplacement **case par case en ZQSD** qui fait réellement s'écouler le temps (2× le coût de la marche), avatar du joueur comme marqueur, horloge et jauges affichées — on peut s'épuiser, voire mourir, en traversant le monde |
| Termitière de donjon (3.5) | masse organique **à l'échelle de la cellule** (rayon 56), sculptée au bruit : flancs irréguliers, **pics démoniaques** (bruit crêté), **cavités et tunnels « alien »** (bruit 3D), palette de 5 matériaux sombres marbrés, tous **incassables** ; on entre en s'enfonçant dans une cavité |
| Cycle jour/nuit (E.21) | `DayNightManager` : 4 phases, course du soleil, **assombrissement réel du terrain par uniform de shader** (G.3), faune nocturne distincte, densité de spawn ×2 et portée d'agression réduite la nuit — sonde `--probe-survie` |
| Sommeil & fatigue (E.21) | lit craftable (1er meuble F.6), saut de nuit avec temps réellement simulé, buff « Reposé » (+5 % XP), jauge de **fatigue** (amendement auteur) à effets progressifs jamais létaux |
| Cuisine (7.7, A.9.1, 6.4) | fourneau + compétence Cuisine + 4 plats ; un plat **cuisiné** rend la nutrition pleine et **crédite le potentiel de stat** — manger cru n'en donne aucun |
| Mort et pénalité (A.10) | **la famine peut tuer** (A.9 amendé sur décision auteur — plus de plancher à 1 PV) ; respawn au dernier lit ou claim, -10 % d'or, 10 % de perte par objet, équipement conservé, aucune perte d'XP ; caches au sol récupérables 1 jour in-game (`DropManager`) — sonde `--probe-mort` |
| Faim (A.9, A.9.1) | jauge + décroissance, **manger** (touche F, matériaux à bloc `nutrition`, cru = 50 %), seuils de régén, malus de stats < 25, famine à 0 — sonde `--probe-faim` |
| Artisanat (4.2) | recettes, transformations, stations, qualité |
| Combat (5, E.3) | pipeline de jets complet, pool de mana (A.5), créature générique data-driven, 4 modules |
| Butin (7.7, A.9.1) | viande et peau **paramétriques** par espèce (B.1), en **instances d'objet** comme les armes (icône colorée, jamais un bloc) : registre `GameData.resources` séparé, sans id runtime ni entrée de palette. Unités identiques regroupées sur une instance. Bonus de potentiel dérivés de la source, dépeçage, consommation — sonde `--probe-butin` |
| Inventaire & hotbar | hotbar **assignable** (liaisons slot → objet par `uid`, stables au tri et à la sauvegarde), bande intégrée à l'inventaire avec **glisser-déposer**, menu d'actions au clic (infos, équiper, assigner banque/emplacement, déposer au sol) |
| Faune (F.3) | **37 fiches de créatures**, spawn filtré par biome, meutes, profils d'IA (hostile / bête sauvage qui riposte / craintive qui fuit / civil) — sonde `--probe-faune` |
| Carte & exploration (3.1, E.30) | carte du monde, voyage rapide, claims + rôles, minimap, brouillard de guerre |
| Donjons (3.5) | entrée/sortie par dimension, salles/couloirs creusés proc. |
| Boutique (7.1, E.8) | étal de vente passif, clients abstraits |
| Sauvegarde (E.10) | `SaveManager`, autosave **incrémentale**, écriture atomique ; **nombre de mondes illimité**, liste défilante complète, **suppression** avec confirmation et garde-fous (jamais hors du dossier de sauvegardes, jamais le monde en cours) — sonde `--probe-saves` |
| Réseau (8, E.11) | squelette host/join + RPC d'édition de blocs |
| Interface (E.13) | menu de démarrage, menu de jeu (perso/royaume/carte/monde/inventaire/craft), HUD, menu de triche |

---

## Reste à faire

Liste des éléments du GDD non développés, partiellement implémentés, ou non
fonctionnels dans le code actuel. Références de section entre parenthèses.

### Priorité 1 — Trous dans la tranche verticale du MVP

Ces points sont dans le périmètre MVP (section 15) mais absents ou à l'état de stub.

- **Créatures : les modèles (12.1)** — les 37 fiches de F.3 existent (stats, IA, biomes, recrutement), mais le rendu reste des **capsules colorées**. Pipeline figé le 2026-07-26 : **Blockbench → glTF/`.glb`** (voir [models/creatures/](models/creatures/)) ; `creature.gd` charge déjà le champ `model` s'il est renseigné, il ne manque que les modèles.
- **PNJ dans la boucle** — *fait le 2026-08-01* : les villages se peuplent d'habitants dérivés de (cellule, graine), chacun rattaché à un bâtiment, avec un métier parmi les 11 de 8.4 et une routine jour/nuit. Ce sont des `Creature` ordinaires — aucune classe PNJ, conformément à 12.1. Restent le dialogue, la relation qui évolue, le commerce et la persistance des morts (décimation).
- **Modules de compétences (F.2, B.4)** — 4 modules sur **48**. Pas de système d'assemblage de compétences (5.1), pas de coût en mana assemblé (A.6).
- **Emplacements d'équipement (6.2)** — *partiel* : les 13 emplacements, l'armure et la mitigation A.4.2 fonctionnent. Les **boucliers** (3 modèles, blocage élargi, absorption d'endurance) et les **53 compétences** (une par arme, maîtrises de type de dégâts, Dual Wielding / Bouclier / Deux Mains) existent depuis le 2026-08-01 ; Deux Mains et Bouclier progressent, Dual Wielding attend son système. Restent les **morphologies non-humanoïdes** (`equip_slots` de B.5) et l'usage des slots `arme_1`/`arme_2` par le combat, qui lit encore l'objet en main.
- **Effets d'équipement passifs (A.4.4)**, **pools de loot (F.7)** et **stats étendues des matériaux (A.4.5)** — non appliqués : anneaux, amulettes, accessoires et dos s'équipent mais ne font encore rien. Le butin de créature se limite à viande + peau ; pas d'objets, d'or, ni la **statue 1:1** de F.3.
- **Contenu des POI** — camps, sanctuaires et filons majeurs ont été **RETIRÉS** le 2026-08-01 (décision de l'auteur) : ils n'avaient aucun contenu et leurs pastilles menaient à du vide. Il ne reste que **village** et **donjon**. Pour les réintroduire, voir le commentaire de `POIGenerator.POI_TYPES` — l'ordre de la liste est signifiant. Les **villages**, eux, ont été refaits le 2026-08-01 : six archétypes de bâtiment, toitures en pente, fenêtres, planchers, place pavée, champs, et des habitants. Restent l'**intérieur** (aucun mobilier) et la fonction des bâtiments (voir « Différé »).
- **Donjons (E.29)** — bibliothèque réduite (3 salles / 1 connecteur), un seul étage, pas de boss ni de cycle complet « clear → disparition → réapparition ».
- **Progression par le potentiel (6.4)** — *à moitié* : les plats cuisinés créditent maintenant le potentiel **de stat**, mais **rien ne le consomme** — 6.4 prévoit que les stats gagnent de l'XP multipliée par leur potentiel, or les stats sont figées à la création. La progression de stats est la moitié manquante, et le GDD ne chiffre aucune source d'XP de stat : c'est une décision de design à prendre. Le potentiel de **compétence**, lui, est bien consommé aux montées de niveau.

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
- **Meubles (F.6, 16)** — aucun : d'où l'absence de **lits**, que A.10 désigne pourtant comme point de résurrection principal (seul le claim sert de point de retour), et de coffres, garde-manger, bibliothèques, etc.
- **Cuisine, alchimie et nourriture (7.7)** — les **viandes paramétriques** existent et portent leurs bonus de potentiel, mais rien ne les consomme encore : il manque la **station Cuisine et les recettes de plats** (tout se mange cru à 50 %, et les bonus de potentiel A.9.1 ne sont donc **jamais crédités** — c'est l'étape qui débloque la boucle 6.4), les **parties d'alchimie** (yeux, griffes, os) et l'**alambic**. Aucune donnée pour les **18 consommables (F.5)**, **12 potions (F.9)**, **16 meubles (F.6)**, **14 statuts (F.4)** — d'où l'absence du risque d'infection du cru.
- **Économie et flux d'or (7.6, A.8.1)** — pas de portefeuilles PNJ, ni taxes, ni entretien.
- **Villages : conquête et succession (3.4, 12.3)** — la **population** et la **décimation** existent depuis le 2026-08-01 : les morts sont persistés (on n'enregistre que les absences, un village intact ne coûte rien), un village entièrement vidé devient un POI abandonné, et le repeuplement hebdomadaire d'E.25 tourne. Restent la **conquête** (halle comme point de revendication, jet de Leadership) et la **succession**. La **capacité** est dérivée du nombre de bâtiments, pas encore de la détection de pièces d'E.5.
- **Âge des PNJ (12.2)**, **familles/statuts (12.3)**, **monstres rares (12.4)** — absents.
- **Génération de noms culturels (12.5, E.31, B.11)** — `world_namer.gd` nomme le monde uniquement ; aucun `data/name_cultures/` (les 10 cultures de C.9 restent à écrire).
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
- **Fertilité des sols** — prévue, non commencée.

### Priorité 4 — Royaume du joueur (section 14, endgame)

- Expansion territoriale au-delà du claim simple (14.1) : les claims existent (`ClaimManager`, 4 rôles) mais ne produisent ni n'exploitent rien.
- Population et exploitation (14.2), halls de guilde (14.3).
- Statut de royaume, gouvernance, **lois et infractions (14.4, E.26, B.9)**, diplomatie — aucun `data/kingdoms/`.
- Défense (14.5), entretien et taxes (14.6).
- **Génération des royaumes PNJ (E.27)** — absente.

### Priorité 5 — Outils, contenu et finition

- **Tables de sculpture / éditeur (13, E.9)** — la sculpture libre en sous-blocs fonctionne, mais l'éditeur d'objets custom n'existe pas.
- **Mode tactique (5.0)** — `TickManager.tactical_mode` existe mais **n'est déclenché par rien** ; pas d'UI d'action time.
- **Grimoires et manuels (C.6, A.7)** — les 8 domaines et 4 manuels ne sont pas écrits ; `book_read` n'est émis nulle part.
- **Tooltips contextuels d'onboarding (E.19)** — absents.
- **Véhicules (E.24)** — absents (extension future assumée).
- **Multijoueur (8, E.11)** — le squelette réseau ne synchronise que des positions et des éditions de blocs : pas d'autorité sur les jets de dés, pas de synchronisation d'entités, d'inventaire ni de sauvegarde partagée.
- **Structures et routes (9.2)** — routes en croix générées dans les villes, mais aucun réseau routier inter-cellules.
- **Audio / musique** — hors périmètre du GDD, rien en place.
- **Nom du projet et lore (16)** — à écrire.

### Dette technique / hygiène

- **Mesures de perf : distance d'affichage** — les benchs forcent désormais le rayon par défaut (8) et ignorent `display.cfg`. Un réglage joueur à 14 triplait le nombre de chunks et faisait lire *245 → 66 fps* comme une régression, alors qu'aucun code de rendu n'avait changé.
- **Équilibrage de l'armure** : un jeu complet de fer qualité 1.2 donne 5d4 de réduction (moyenne 12,5) contre ~8 de dégâts bruts pour une arme de départ — mesuré par la sonde, les dégâts encaissés chutent de 2594 à 192 sur 400 coups. Les formules A.4.1/A.4.2 sont appliquées à la lettre : c'est le **chiffrage par défaut du GDD qui est à équilibrer en playtest**, pas l'implémentation.
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
- **Meshing au-dessus du budget E.14** : mesuré à **13,9 ms/chunk** pour une cible de **< 4 ms**. La sonde `--probe-mesh` donne la répartition — **greedy 72 %**, coquille 20 %, subdivision ~0 %. Un saut rapide supplémentaire (deux niveaux pleins adjacents ne portent aucune face) a rendu **11,6 %** sur le greedy ; le reste demande soit une réécriture en meshing binaire (masques de bits par colonne), soit ce que le GDD prescrit lui-même en E.14 : *« si le meshing GDScript est trop lent, passer cette partie — et elle seule — en GDExtension/Rust, décision au profilage »*. Le profilage est maintenant fait.
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

- **Pas de migration de sauvegarde** : `SAVE_VERSION` vaut 1 et tout écart fait repartir sur un **monde neuf** (avec un simple avertissement). Tant que le format bouge, il faudra soit une conversion, soit assumer la casse — à trancher avant toute distribution.
- **`_edits` ne se nettoie jamais** : c'est voulu (il est la vérité des modifications, base du diff E.10), mais il croît avec tout ce que le joueur pose. Poser puis casser un bloc laisse une entrée. Un compactage (oublier les modifications redevenues identiques à la génération) sera nécessaire pour les très longues parties.
- **Créatures non sauvegardées** : le spawn naturel les régénère, les boss de donjon renaissent tant que le donjon n'est pas nettoyé. Assumé et documenté, mais ça se verra dès que les PNJ auront une identité (12.3).

## Sondes de validation

Chaque lot livré porte sa sonde headless, exécutable sans interface :

```
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

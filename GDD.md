# Game Design Document — Projet [Nom à définir]

*Document de travail — v0.1*

---

## 1. Concept général

**Pitch :** Un RPG voxel en monde infini généré procéduralement et totalement continu, où une carte du monde façon roguelite (case par case) sert de couche stratégique et de voyage rapide au-dessus d'un monde voxel 3D façon Minecraft — avec construction à résolution variable, combat en temps réel basculable à la volée en mode tactique (action time), une progression par l'usage à la Elona/Elin, et un endgame de construction de royaume.

**Piliers d'inspiration :**
| Jeu | Ce qu'on en garde |
|---|---|
| Minecraft | Construction voxel, blocs, exploration 3D |
| Elin / Elona | Progression par l'usage infinie, vie simulée (commerce, agriculture, apprivoisement, réputation) |
| Tales of Maj'Eyal | Structure de combat tactique, profondeur des builds |
| Noita | Système de sorts/compétences modulaire |

**Public visé :** joueurs de RPG bac-à-sable profonds et de roguelikes (fans de Minecraft moddé, Elin/Elona, ToME, RimWorld/Dwarf Fortress) — un public de niche exigeant, tolérant à la complexité, sensible à l'émergence. PC (Steam), solo et coop entre amis.

---

## 2. Boucle de jeu (Game Loop)

**Boucle macro :**
Exploration du monde voxel continu (à pied ou via voyage rapide par la carte du monde) → points d'intérêt (donjons, villages, ressources) → exploration/combat/construction/récolte → retour à la base/claims.

**Boucle micro (dans le monde) :**
Combat / récolte / construction → gain d'XP par l'usage (armes, modules, compétences) → équipement et compétences plus puissants → accès à des zones plus dangereuses (couche de corruption plus dense).

**Boucle endgame (section 14) :**
Claim de territoire → recrutement/assignation de PNJ → exploitation automatisée → richesse et rangs de guilde → expansion, halls de guilde, diplomatie, défense contre les raids.

---

## 3. Le monde

### 3.0 Génération procédurale (couches de bruit)

Le monde est généré par superposition de multiples couches de bruit (type Perlin/Simplex), qui se combinent pour définir à la fois les biomes et le contenu matériel du monde.

**Couches de bruit :**
- Altitude
- Température
- Humidité
- Densité de mana/magie
- Densité de ressources/minerais
- Densité de végétation
- Activité sismique/volcanique
- Niveau de danger/corruption

**Application à deux échelles :**
- **Carte du monde** : la combinaison des couches détermine le biome global de chaque case (ex : désert volcanique à forte magie, toundra pauvre en mana).
- **Intérieur d'une cellule (génération 3D voxel)** : les mêmes familles de couches (affinées/dérivées) génèrent le terrain, les cavités et la distribution des matériaux à l'intérieur de la zone jouable, en cohérence avec le biome déterminé à l'échelle macro.

**Placement des matériaux : approche mixte**
- Certains matériaux/minerais ont leur propre couche de bruit dédiée (poches rares/riches indépendantes du biome).
- D'autres matériaux découlent directement du biome déterminé par les couches principales (ex : sable en désert, glace en toundra).

**Décisions :**
- Cohérence macro/micro et transitions : **résolu (E.2)** — une seule génération continue, la cellule et la carte ne sont que des fenêtres/résumés sur le même champ de bruit.
- **Visibilité des couches :** la carte du monde affiche le biome et la heat-map de danger (6.3) ; les autres couches (mana, ressources...) sont **cachées par défaut** et se révèlent par le jeu — effets `detection_filons`/`detection_tresors` (F.7), informations vendues par la guilde des Prospecteurs (G.9), rumeurs de PNJ (E.23).

**Réalisme géologique/climatique (2026-07-20, implémenté — voir E.2/E.2.4/E.2.5 pour le détail technique) :**
- **Climat par latitude** : la température n'est plus un simple bruit — elle suit une **bande de latitude** (fonction de la coordonnée Nord/Sud du monde, cycle pôle→équateur→pôle), perturbée localement par du bruit, et réduite par l'altitude (plus il fait froid en montagne). Les 8 couches de bruit (B.8) restent inchangées : la couche "température" devient la variation locale plutôt que le signal principal.
- **Humidité et ombre pluviométrique** : un grand relief au vent dominant assèche les terres qu'il abrite (effet d'ombre pluviométrique) — les déserts se forment naturellement derrière les chaînes de montagnes, pas seulement par un tirage de bruit indépendant.
- **Orogenèse** : les chaînes de montagnes se forment aussi bien à l'intérieur des masses continentales (pics classiques) qu'à leurs **bordures** (chaînes côtières façon Andes/Rocheuses), en suivant le gradient de continentalité — un rendu plus proche d'une tectonique des plaques que d'un bruit isolé.
- **Rivières** : réseau hydrographique généré par sources en altitude puis traçage par **descente de gradient** jusqu'à la mer ou un bassin endoréique (petit lac sans exutoire). **Simplification assumée** (monde infini streamé, voir E.2.2) : la recherche de sources est bornée à une fenêtre régionale autour de la zone explorée — pas de bassin versant global précalculé.
- **Littoraux** : le matériau de rivage (plage de sable, estran de galets, falaise, marécage côtier) est choisi par la **pente locale du terrain**, pas par le biome seul.
- **Spéléologie** : les cavernes ne sont plus un bruit 3D creusé nu mais un réseau de **tunnels karstiques sinueux + grandes salles**, avec spéléothèmes (stalactites/stalagmites/colonnes en calcite) et dépôts organiques (guano) aux transitions plafond/sol (E.2.4).
- **Gaz souterrains** : grisou (méthane, plafond des poches profondes), monoxyde de carbone (diffus, poches mal ventilées), dioxyde de soufre (zones volcaniques profondes), gaz toxique lourd (fond des gouffres non ventilés) — placement **règle-basé déterministe**, pas une simulation fluide temps réel (E.2.5). **Retiré du prototype le 2026-07-20** (demande explicite) — la spec E.2.5 reste la référence si le système revient.
- **Limite assumée et disclosed** : tout ce qui précède vise un réalisme **perçu/procédural crédible**, jamais une simulation physique exacte à l'échelle de la Terre réelle — un monde infini streamé par chunks, en temps réel, sur le matériel cible (Annexe G), ne peut pas faire tourner une hydraulique/atmosphère globale. Les échelles (ex : distance pôle-à-pôle) sont **compressées pour rester jouables**.

### 3.1 Carte du monde (couche roguelite)
- Monde infini, généré procéduralement.
- Déplacement case par case sur la carte du monde (façon roguelike).
- **Biomes :** nombreux et nuancés (**20+**), émergeant des combinaisons variées des couches de bruit (section 3.0) plutôt qu'un petit nombre de catégories larges façon Minecraft.
- **Points d'intérêt :** donjons/ruines à explorer, camps de monstres/repaires, ressources rares à récolter, sanctuaires/autels magiques, villages/villes PNJ (voir 3.3).
- **Trésors et artefacts :** catégorie d'objets à part — très rares, non craftables/non sculptables, trouvables uniquement en donjon. Générés aléatoirement (pas d'exemplaire unique par objet), mais avec un taux d'apparition très faible. Lien naturel avec la guilde Chasseurs de trésor (section 7.3).
- **Niveau de danger :** déterminé par la couche "danger/corruption" (voir 3.0), indépendamment de la distance au point d'origine — pas de progression de difficulté façon "plus loin du spawn = plus dur" à la Diablo, et **jamais de scaling sur le niveau du joueur**.
- **Dérive de la corruption (monde vivant)** : la couche de danger n'est pas figée — elle **dérive lentement selon les actes** (mise à jour hebdomadaire in-game, détail en E.20) : les foyers hostiles non nettoyés (donjons, camps) **infectent** progressivement leurs cases voisines ; **nettoyer** un foyer fait durablement baisser le danger local. Conséquence de design voulue : la région autour de la base du joueur se pacifie naturellement (il nettoie ce qui est proche), le défi et le meilleur loot s'éloignent — l'exploration est encouragée par la structure du monde, pas par une règle artificielle. La richesse suit toujours le danger (loot ∝ corruption locale), jamais l'inverse.
- **Articulation avec le monde voxel continu :** la carte du monde est une vue abstraite du même monde voxel, utilisée comme **raccourci de voyage rapide** (se déplacer sur la carte = se téléporter/voyager vite vers les coordonnées correspondantes). Le joueur peut aussi **tout traverser à pied en continu**, sans jamais passer par la carte, puisque le monde voxel est sans coupure.

**Décisions :**
- **Biomes :** la liste de référence est **C.7** (12 au lancement, extensible vers 20+ par simple ajout de données B.6 — les conditions de couches y sont définies par biome).
- **Points d'intérêt : hybride résolu (E.2)** — assemblés procéduralement à partir de **salles/bâtiments préfabriqués .vox faits main** (palettes remapables 9.2) ; densités chiffrées en E.2 (village 4 %, donjon 6 %, camp 8 %, sanctuaire 3 %, filon majeur 6 % par cellule).
- **Trésors/artefacts :** mécaniquement = objets à **effets d'équipement (A.4.4) tirés des pools F.7 avec un budget supérieur** (2-3 effets, valeurs au-dessus des fourchettes normales) + stats de base hors normes fixées à la génération ; jamais craftables ni sculptables.

### 3.2 Entrer dans une cellule (mode voxel)
- Chaque case de la carte du monde correspond à une zone jouable en voxels 3D complets (façon Minecraft).
- **Taille d'une cellule :** **128×128 blocs**, **hauteur : 512 blocs** — la hauteur est une **limite de design par défaut**, pas une limite d'architecture (voir ci-dessous).
- **Décision (2026-07-19) — axe vertical :** le monde va de **-512 (fond) à +512 (plafond)**. Le plafond de +512 est une limite **pour les joueurs** (construction), pas une contrainte de génération — le relief généré culmine naturellement en dessous (~400). La profondeur maximale de génération est **-512**.
- **Continuité totale** : aucune coupure entre deux cellules voisines — l'ensemble des cellules forme un seul monde voxel continu et sans écran de chargement, comme si on marchait d'une case à l'autre sans transition.
- **Verticalité extensible (chunks cubiques)** : le monde est stocké en chunks cubiques indexés en 3D `(x, y, z)` dès le départ (voir Annexe D). Un **mode/extension à profondeur infinie** reste donc théoriquement possible sans refonte : il suffirait de streamer des chunks au-delà de la limite de 512. À prévoir si activé un jour : couches de bruit 3D ou règles dérivées de la profondeur (ex : corruption/mana croissant avec la profondeur, biomes souterrains par strates), représentation des profondeurs sur la carte du monde, convention Y=0 à la surface.
- **Stratification par dureté (verrou de progression) :** la roche durcit avec la profondeur — impossible de creuser jusqu'au fond dès le début. Grâce à la règle d'irrécoltabilité (A.2), un outil trop faible **rebondit** sur la strate suivante : le mur est physique et lisible, pas artificiel. Trois voies pour descendre : monter son Minage et forger de meilleurs outils avec les matériaux de la strate courante (boucle : chaque strate équipe pour la suivante), trouver du meilleur matériel en donjon, ou **recruter des PNJ mineurs de haut niveau** et les assigner à l'extraction (14.2) — un vétéran du minage devient un recrutement stratégique de grande valeur. Strates par défaut (surface → fond, dureté croissante, cf. F.1 — profondeurs alignées sur **G.9, qui fait autorité** ; corrigé le 2026-07-21, cette section donnait d'anciennes valeurs) : terre/grès (surface), calcaire (~-12), ardoise (~-55), pierre (~-80), basalte (~-160), granit (~-260), granit noir (~-380), avec transitions bruitées (pas de lignes plates) et poches locales plus tendres/dures. Les filons les plus riches vivent dans les strates profondes.

### 3.3 Persistance et claims
- **Cases "claim"** (revendiquées par le joueur) : constructions persistantes indéfiniment.
- **Cases sauvages** (non revendiquées) : régénérées après 1 semaine de temps in-game.
- **Villages et villes** (PNJ) : permanents, non affectés par la régénération.

**Cellules donjon exclues du zonage :** tant qu'un donjon occupe une cellule (3.5), celle-ci n'est ni claimable ni zonable — elle le redevient après le délai de disparition post-nettoyage (3.5/E.29).

**Rôles des cases claim (zonage) :** le joueur peut assigner un **rôle** à chaque case revendiquée, et en **changer librement à tout moment**. Le rôle est **mécanique et porte des restrictions** — il change le comportement de la case, pas juste son étiquette :

| Rôle | Comportement |
|---|---|
| **Base** | Cœur du territoire — constructions persistantes, toutes activités autorisées |
| **Habitation** | Logements des PNJ résidents (voir 7.5) |
| **Champs** | Agriculture/élevage (voir 7.4), assignation de PNJ fermiers |
| **Ressources naturelles** | La case **garde la régénération hebdomadaire des cases sauvages** malgré le claim — réserve d'exploitation renouvelable (récoltable en boucle, notamment par les PNJ assignés, section 14.2). Restriction : pas de construction lourde (elle serait effacée par la régénération). |

**Décisions :**
- **Restrictions par rôle :** Base = tout autorisé · Habitation = tout autorisé, seules les pièces de ce rôle comptent pour la capacité de logement (7.5) · Champs = constructions légères uniquement (pas de station lourde), parcelles agricoles actives · Ressources naturelles = **aucune construction** (tout bâti y est effacé à la régénération), récolte et assignation de PNJ uniquement.
- **Changement de rôle vers "ressources naturelles" sur case construite :** dialogue de confirmation explicite listant ce qui sera effacé — obligatoire, pas contournable.
- **Autres rôles :** non au lancement — les quatre couvrent les usages (la défense et le commerce vivent sur les cases Base/Habitation) ; le champ `role` en données reste extensible.

### 3.4 Villages PNJ : population, décimation et conquête

**Repeuplement (cadence hebdomadaire, même horloge que 3.3/7.6/E.20) :**
- Chaque village a une **capacité** dérivée du nombre de pièces habitables détectées (même algorithme que l'habitat du joueur, 7.5/E.5, appliqué aux bâtiments du village).
- Chaque semaine, un village sous sa capacité a une chance de gagner un nouveau résident (immigration/nouvelle génération abstraite — pas de simulation de naissance individuelle), qui reprend un poste vacant (jobs_compatible, 14.2).
- La vitesse de repeuplement est **modulée par la corruption locale** (E.20) : un village dans une zone pacifiée par le joueur repeuple vite ; un village menacé stagne ou décline — la même pression civilisatrice qui éloigne le danger nourrit aussi la vie.

**Décimation totale (conséquence assumée) :** un village peut être **entièrement vidé** si le joueur (ou un raid, un monstre) tue ses habitants plus vite qu'ils ne repeuplent. Un village à 0 population devient un **POI abandonné** : bâtiments et meubles intacts et persistants (aucune régénération ne les efface — c'est un site claim-like), mais sans résidents ni services. Un village vidé peut être **réoccupé** par le joueur lui-même (assigner ses propres PNJ recrutés dans les logements déjà debout — réutilisation directe du bâti existant, sans reconstruire) ou repeupler naturellement à très long terme si la zone se pacifie.

**Conquête (distincte de la décimation — pas besoin de tuer pour conquérir) :** le joueur peut annexer un village à son royaume (14.1) sans exterminer sa population :
- **Condition :** réduire les défenses du village (gardes vivants × leur niveau de combat) sous 25 % de leur valeur nominale.
- **Action :** revendiquer le village au bâtiment central (mairie/hall) — jet de compétence universel (E.3) : `1d20 + Leadership/2 + Charisme/4 vs DD = population du village * 2`.
- **Succès :** le village rejoint le royaume du joueur ; sa population existante devient gérable comme des PNJ recrutés (jobs 14.2, logements déjà en place). Impact de réputation fort et variable (positif si le village appartenait à un royaume hostile au joueur — perçu comme libération ; négatif si le royaume d'origine était neutre ou allié — perçu comme agression).
- **Échec :** réputation locale négative, les défenses se régénèrent partiellement.

**Décisions :**
- **Capacités par taille (pièces habitables générées) :** hameau 4-8, village 8-20, ville 20-60, capitale 60+. Vitesse de repeuplement : formule E.25 (`0.15 × sous-capacité × pacification`).
- **Reprise d'un village conquis : oui** — le royaume d'origine, s'il reste hostile et puissant, peut lancer un **raid de reconquête** (pipeline E.7 standard, cible = le village annexé) ; en cas de victoire du raid non défendu, le village retourne à son royaume d'origine. La diplomatie (14.4) permet d'acheter la paix à la place.

### 3.5 Donjons : structure, génération et intégration

**Rôle central :** les donjons sont une des sources principales de contenu du jeu — loot de tout type, **grimoires/manuels** (source première des modules de compétences, section 5), objectifs de quêtes de guilde (7.3), trésors/artefacts (3.1), et terrain de combat pur. À développer en priorité.

**Génération à la Daggerfall — modulaire, en salles et connecteurs .vox :**
- Un donjon est assemblé depuis une bibliothèque de **salles** (room prefabs .vox — tailles petite/moyenne/grande/immense, formes variées, **jamais forcément planes** : un sol peut avoir marches internes, fosses, plateformes — c'est un modèle voxel comme un autre) et de **connecteurs** (corridors droits/coudés/en T, escaliers montants/descendants, portes, rampes).
- **Points d'attache** : même technique que l'assemblage de créatures (12.1) — des voxels-marqueurs de couleurs réservées dans les .vox de salles/connecteurs indiquent où les pièces se branchent, typés (porte nord/sud/est/ouest, cage d'escalier). Réutilisation directe d'un système déjà construit pour un usage différent.
- **Étages, verticalité réelle ("à étage")** : un donjon empile plusieurs niveaux reliés par des connecteurs escaliers — extension naturelle des chunks cubiques indexés `(x,y,z)` (3.2/D.2). Chaque étage a son propre graphe de salles, généré indépendamment.
- **Palette remapable** : les mêmes salles/connecteurs génériques servent tous les thèmes (ruine, crypte, mine effondrée, repaire...) via le remapping de couleurs stand-in déjà en place (9.1/9.2) — un petit nombre de prefabs, une grande variété visuelle.

**Génération (algorithme, détail technique en E.29) :** placement de l'entrée → extension par graphe (attacher connecteur + salle compatible à un point d'attache libre, répéter jusqu'au nombre de salles cible) → garantie de connexité → cage d'escalier vers l'étage suivant si applicable → salle spéciale (trésor/boss) au point le plus reculé de l'étage le plus profond.

**Taille et profondeur (alignées sur les foyers d'E.20) :**
- **Donjon mineur :** 2-3 étages, 8-15 salles/étage.
- **Donjon majeur :** 5-8 étages, 15-25 salles/étage, salle boss unique au dernier étage.
- **Difficulté et loot croissent avec la profondeur** de l'étage (indépendamment de la corruption de surface de la cellule, formule E.29) : descendre est toujours un choix qui paie, quel que soit le danger ambiant de la région.

**Occupation de la cellule sur la carte du monde :**
- Le **terrain de surface** de la cellule où apparaît un donjon est remplacé par une structure d'entrée scellée (ruine effondrée, faille, gouffre, portail muré...) — non claimable (3.3), non cultivable ; le reste de la cellule est naturellement impraticable autour du point d'entrée unique.
- **Voyage rapide restreint au point d'entrée** : la carte du monde ne peut cibler que l'entrée — jamais un point arbitraire à l'intérieur (les étages empilés n'ont pas de représentation 2D unique). Une fois entré, exploration entièrement à pied, façon roguelike classique.
- Techniquement, l'intérieur occupe le volume de chunks sous/autour de la cellule — toujours le même monde continu, juste une structure très dense et fermée (aucune exception d'architecture, D.2/G.2 s'appliquent tels quels).
- **Écart technique temporaire (prototype, 2026-07-21)** : l'implémentation actuelle place l'intérieur dans une **poche compacte éloignée** (grille de slots vers x/z ≈ 20 000) et téléporte le joueur — un placement aux coordonnées naïves `cellule × N` explosait la précision float32 de Godot (jitter caméra constaté à ~4 000 000). **La décision ci-dessus reste la cible** : générer l'étage *sous* la cellule (les chunks cubiques -512→+512 le permettent) ou passer à une vraie dimension séparée — à trancher avant le multijoueur.

**Persistance et nettoyage (fixe, pas de repop avant nettoyage complet) :**
- Mobs et loot générés sont **fixes** : explorer un donjon, c'est le vider progressivement — aucune régénération interne tant qu'il n'est pas entièrement nettoyé (contrairement à la surface, 3.3). Les changements (morts, butin pris, blocs détruits) suivent exactement la sauvegarde différentielle standard (E.10) : rien de nouveau à construire.
- **Nettoyage complet (boss vaincu) :** le donjon **disparaît et redevient une cellule normale**, mais reste dans son état exploré (loot restant accessible, structure intacte) pendant **1,5 jour in-game** — le temps que le joueur termine ce qu'il a à faire. Passé ce délai, la cellule régénère en terrain normal du biome environnant et devient claimable (3.3) comme n'importe quelle case sauvage.

**Intégration aux systèmes existants :**
- **Quêtes de guilde (7.3/B.7) :** nouveau pattern `donjon` — nettoyer ou atteindre le fond d'un donjon désigné (cohérent avec les gabarits par guilde déjà posés).
- **Grimoires/manuels (5.1) :** les donjons sont leur **source principale** (piédestaux, coffres, salles de bibliothèque thématiques).
- **Artefacts (3.1) :** réservés à la salle boss/trésor des donjons majeurs.
- **Créatures (F.3) :** humains hostiles (bandits, pillards, ermites) et bêtes tanières peuplent les salles selon le profil du donjon — un ermite en salle isolée profonde, une bande organisée dans les grandes salles d'un étage supérieur.

**Décisions :**
- **Après nettoyage complet : la cellule redevient normale et claimable après le délai de grâce de 1,5 jour** (ci-dessus) — pas de farm infini du même donjon, pas de disparition brutale non plus.
- **Pas de repop avant nettoyage complet** — explorer vide réellement le donjon, cohérent avec un vrai dungeon crawl plutôt qu'un spawn infini.

**Questions ouvertes :**
- Taille exacte des salles/connecteurs en blocs et taille de la bibliothèque de prefabs au lancement.
- Un nouveau donjon peut-il apparaître ailleurs dans le monde pour remplacer celui disparu (fréquence de génération de nouveaux foyers de donjon) ?

---

## 4. Construction voxel

### 4.1 Blocs et subdivision

- Bloc de base : **32 pixels par face** (amendé le 2026-07-19).
- Subdivision possible : **32 → 16 → 8 → 4 pixels** (facteur 2, 3 niveaux, façon octree) — le sous-bloc le plus fin fait 4 px, soit au plus **8×8×8 = 512 sous-voxels par bloc** (deux fois moins coûteux que l'ancienne chaîne 16→1).
- **Alignement sur grille strict, à toutes les résolutions :** les blocs 16px sont toujours snappés sur la grille principale du monde ; les blocs subdivisés (8/4/2/1px) se placent dans les sous-cellules de leur bloc parent. Aucun placement en position arbitraire/décalée — tout est toujours sur grille, seule la finesse de la grille change.
- **Garde-fou de performance :** budget de blocs subdivisés par chunk (512 par défaut, message clair au joueur si atteint — voir G.2). Vu au loin, un détail fin est affiché à la résolution du bloc (couleur moyenne) : la finesse est un plaisir de proximité, par conception.
- Fonction de la subdivision : **esthétique uniquement** — détails fins de construction, sculpture, décoration.
- ~~Physique/destruction fine façon Noita~~ **Abandonné** (trop coûteux et trop difficile à synchroniser en multijoueur — voir section 8).

**Destruction (explosions, etc.) :** approche discrète façon Minecraft/Terraria — une bombe détruit des **blocs pleins** (chaque bloc individuel, à sa résolution de subdivision, est soit détruit soit intact) dans un rayon donné, sans simulation de fragments/particules physiques.

**Prévisualisation de placement (ghost preview) :**
- Tout objet posable en main (bloc, meuble, structure/modèle sculpté, station) affiche en permanence un **fantôme semi-transparent** à la position de placement visée, aligné sur la grille à la résolution active.
- **Code couleur :** teinte normale/verte si le placement est valide, **rouge** si invalide (collision, hors de portée, sur une entité...).
- **Blocs subdivisés :** le fantôme montre la **sous-cellule exacte** visée dans le bloc parent (indispensable pour placer un bloc de 8px ou 4px avec précision).
- **Structures et modèles sculptés :** le fantôme affiche le modèle entier ; **rotation via les touches directionnelles** avant validation. Placement **aligné sur la grille 16px, centré, par défaut** ; en maintenant **Shift**, le placement bascule sur la **grille fine** (jusqu'à 4px) pour un positionnement précis (ex : coller un meuble exactement contre un mur).
- Implémentation : même mesh que l'objet réel, rendu avec un shader transparent, positionné par le même code de placement — un mode de rendu, pas un système à part.

**Décisions (résolu, A.11) :**
- Rayon/résistance : formule A.11 — un bloc est détruit si `durete_bloc < P × (1 − distance/R)` : la **dureté du matériau EST la résistance à l'explosion** (le granit noir tient là où le grès saute), aucune stat supplémentaire.
- **La subdivision est respectée** (A.11) : chaque sous-bloc est testé individuellement à sa propre échelle.

### 4.2 Matériaux et artisanat

**Catégories de matériaux :** chaque matériau appartient à une catégorie (bois, minerai, roche, liquide, synthétique, etc. — *liste complète à établir*).

**Stats par matériau :** chaque matériau possède ses propres statistiques individuelles fixes, indépendamment de sa catégorie. **13 stats** (effets détaillés en Annexe A.4.5, schéma en B.1) :
- `durete` — dégâts, protection, récolte
- `densite` — poids, vitesse d'arme
- `valeur_base` — économie
- `conductivite_mana` — efficacité magique (réduction des coûts en mana)
- `flammabilite` — prend feu, vitesse de combustion
- `isolation` — protection chaleur/froid
- `conductivite_electrique` — sensibilité/propagation de la foudre
- `flottabilite` — flotte ou coule (crucial pour les véhicules navals)
- `luminosite` — émet de la lumière (éclairage, visibilité/discrétion)
- `fertilite` — rendement agricole du sol (7.4)
- `transparence` — laisse passer la lumière/le regard (fenêtres, serres)
- `elasticite` — amortit les chutes, puissance des arcs
- `friction` — surfaces glissantes (glace) ou routes rapides (pavés)

Le choix du matériau dans un craft est donc un **arbitrage multidimensionnel**, pas seulement dureté/poids.

**Récolte :**
- Chaque catégorie de matériau est associée à un outil dédié (hache → bois, pioche → minerai/roche, etc.).
- La **vitesse** et la **quantité** récoltées dépendent de trois facteurs combinés :
  1. Le niveau du joueur dans la compétence de récolte associée au matériau visé (ex : Minage pour minerai/roche).
  2. La dureté du matériau récolté.
  3. La dureté des matériaux composant l'outil utilisé.
- **Important :** les matériaux bruts n'ont pas de "qualité" — seulement leurs stats fixes. La récolte n'améliore jamais la qualité d'un matériau, seulement la vitesse/quantité obtenue.

**La qualité (objets uniquement) :**
- La qualité ne s'applique qu'aux **objets** : armes, armures, accessoires, outils, meubles, etc. — qu'ils soient craftés par le joueur, obtenus en loot (drop), ou détenus par des PNJ (marchands).
- La qualité est un **multiplicateur** allant de 0 à théoriquement l'infini, avec une difficulté croissante pour monter chaque palier supplémentaire (rendements décroissants).
- Chaque palier de qualité porte un **nom** (ex : pauvre, médiocre, correct... jusqu'à des qualités exceptionnelles) — *nomenclature exacte à établir*.
- Pour un objet crafté, la qualité dépend du niveau de la compétence d'artisanat associée du joueur.
- *(Interprétation à confirmer : la dureté de base d'un outil crafté vient des stats fixes des matériaux utilisés ; la qualité vient ensuite multiplier ces stats de base pour obtenir les stats finales de l'objet.)*

**Fabrication d'outils :**
- Un outil peut être fabriqué avec n'importe quel matériau, tant que les matériaux utilisés correspondent aux catégories requises par la recette (ex : une pioche demande "du bois" — n'importe lequel — et "du minerai" — n'importe lequel).
- Ce craft simple par recette est la **voie de base**, disponible pour tous types d'objets (outils compris) sans passer par une table de sculpture.

**Transformation et stations :**
- Par défaut, un matériau récolté correspond à un bloc ; il peut être transformé (raffiné/travaillé) en d'autres formes (ex : minerai → lingot).
- Toute transformation nécessite une **station dédiée** (forge, scierie, etc.).
- Une station peut être :
  - **Portative** : portée dans l'inventaire du joueur si son poids le permet — les recettes des stations transportées apparaissent alors dans la fenêtre de craft.
  - **Fixe sur une case claim** : les recettes des stations posées sur la case revendiquée par le joueur sont disponibles tant que le joueur se trouve sur cette case.

**Décisions :**
- **Catégories figées (11, alignées sur F.1) :** bois, métal (minerai), roche, terre, végétal/fibre, liquide, minéral, fossile, gemme/cristal, météorologique, synthétique. Table outils/compétences par catégorie : B.2.
- **Stats par matériau : résolu** — 13 stats (4.2/A.4.5), chiffrées pour les 153 matériaux en F.1.
- **Paliers de qualité : résolu (A.3)** — 8 paliers nommés, Misérable → Mythique.
- **Formule dureté/qualité : résolu (A.4/A.4.1)** — dureté de base = moyenne pondérée des matériaux, qualité appliquée une seule fois.
- **Transformations principales (station → recettes) :** Forge : minerai→lingot, sable→verre, argile→brique · Scierie : tronc→planches, bois→papier · Tailleur de pierre : roche brute→pierre taillée/pavés · Atelier de tissage : fibres→tissu, paille→chaume · Alambic : liquides→extraits/potions · Cuisine : ingrédients→plats (F.5) · Table d'enchantement : gemmes→gemmes taillées (+ enchantement futur, A.4.4). Le détail vit en données (`data/recipes/`), extensible sans code.
- **Stations portatives :** chaque station a un poids élevé (établi 35, forge 80, scierie 60, autres 40-60) intégré au système de capacité existant (A.4.2 : `30 + Force×5`) — transporter une forge est possible mais engage l'essentiel de la capacité d'un personnage non spécialisé.

---

## 5. Combat et système de compétences

### 5.0 Système de temps : temps réel ↔ mode tactique (action time)

- **Architecture à ticks dès le départ** : toute la logique de jeu (combat, mana, faim, régénération, IA...) est pilotée par des ticks de simulation, jamais par le delta de frame. Contrainte d'architecture fondamentale (voir Annexe D) — impossible à retrofit proprement plus tard.
- **Par défaut : temps réel** — les ticks avancent avec l'horloge.
- **Mode tactique (action time, façon Elona/ToME) : bascule à la volée par une touche** — les ticks n'avancent que lorsqu'un joueur consomme du temps (se déplacer, attaquer, utiliser un objet/compétence). Réfléchir est gratuit.
- **En multijoueur :**
  - Passer en mode tactique déclenche un **vote** ; s'il est accepté, tout le groupe bascule.
  - En mode tactique multi, **le temps avance dès que n'importe quel joueur agit** (pas d'attente que tous aient joué leur "tour" — le tick le plus rapide gagne).

**Décisions :**
- **Vote (tactique ET sommeil E.21, même mécanique) :** majorité simple, fenêtre de vote de 15 s, re-vote possible après 30 s (harmonisé avec E.11).
- **Granularité des ticks : résolu (E.1)** — coûts par action définis (déplacement 3 ticks/bloc, attaque 10/vitesse_arme, objet 5, bloc 2) ; oui, les actions rapides/lentes coûtent différemment, c'est le cœur du système.

### 5.1 Combat

> ⚠️ **AMENDÉ LE 2026-08-02 — le combat est DIRECTIONNEL, plus à jet de toucher.**
> Le paragraphe « Résolution à jets de dés » ci-dessous décrivait le système
> d'origine (E.3). Il a été **abandonné en implémentation le 2026-07-28** au
> profit d'un combat directionnel façon Mount & Blade. La spécification qui
> fait désormais autorité est **E.3.1** ; E.3 est conservée comme référence
> historique et reste valable pour tout ce qui n'est pas le toucher (dégâts,
> mitigation, jet de compétence universel).

- **Type de combat :** temps réel **directionnel** (E.3.1) — la direction du coup est lue au mouvement de souris qui suit le clic, l'arme balaie réellement l'espace, et ce qui touche géométriquement touche. La bascule en mode tactique (5.0) reste au design, mais **elle n'a pas encore de forme retenue** : une attaque visée à la souris ne se découpe pas naturellement en tours, et c'est une question ouverte que l'amendement de ce jour crée. Voir la note « Question ouverte » en fin de E.3.1.
- **Résolution :** la **géométrie** décide *si* et *où* le coup porte ; les **dés** décident *combien*. Dés de dégâts par type d'arme (dague 1d6, masse 3d8…), mitigation d'armure à jet, et **critique par zone touchée** (la tête vaut ×2.5) au lieu du 20 naturel — un critique est une intention de visée, pas une loterie. Détail complet en E.3.1.
- Reste **inchangé et pleinement en vigueur** : le **jet de compétence universel** (1d20 + compétence/2 + stat/4 vs difficulté), qui unifie toutes les actions risquées hors combat — lecture, dressage, capture, négociation, discrétion. C'est la grammaire de tout le reste du jeu ; seul le combat au corps-à-corps y échappe.
- **Structure des compétences (façon Noita + Elin) :**
  - Chaque **type d'arme** possède un nombre de **slots de compétences**.
  - Chaque **compétence** possède un nombre de **slots de modules**.
  - Les **modules** s'assemblent façon Noita (modificateurs de sort/attaque) et sont **communs à toutes les armes** : n'importe quel module peut s'équiper dans n'importe quel type d'arme (pas de restriction par arme).
  - Chaque module a un **coût en mana** : plus un module/sort est complexe, plus il coûte de mana à utiliser.
  - Le **mana se régénère façon Elin** : récupération passive dans le temps (chance de récupération par tour, influencée par une compétence dédiée), accélérée par le repos.
- **Progression infinie par l'usage (façon Elin) :**
  - Les modules montent de niveau en étant utilisés, sans plafond.
  - Les types d'armes montent de niveau en étant utilisés, sans plafond.

**Acquisition des modules — Grimoires et Manuels :**
- Les modules ne se craftent pas : ils s'obtiennent en lisant des **livres** trouvables en donjon, achetables chez les marchands, etc.
- Deux types de livres :
  - **Grimoire** : contient des modules pour les sorts (magie).
  - **Manuel de combat** : contient des modules pour les armes.
- Lire un livre octroie un certain nombre de modules associés.
- Les livres sont **générés aléatoirement**.
- Plus un livre est puissant, plus il est difficile à lire, ce qui peut provoquer un **échec de lecture**.
- **Lecture** est une compétence qui progresse à l'usage (façon Elin/Elona) ; plus elle est élevée, plus le joueur obtient de modules d'un même livre et plus les chances de succès sont hautes.

**Échec de lecture et consommation :**
- Un livre est à **usage unique** : il est consommé/détruit à la lecture, réussite ou échec.
- En cas d'échec, un **effet aléatoire** se déclenche, mineur ou fort selon les cas (ex : léger étourdissement à confusion/téléportation/invocation d'ennemi — *liste précise des effets à établir*).

**Décisions :**
- **Effets d'échec de lecture : résolu (A.7)** — mineur (étourdissement 5 s, perte de mana), grave (confusion, téléportation, invocation hostile ≈ difficulté du livre) ; la table détaillée vit en données (`data/reading_failures.json`), extensible.
- **Domaines de grimoires : oui, résolu (C.6/B.4)** — 8 domaines de grimoires + 4 de manuels ; chaque livre généré tire son domaine, qui filtre les modules qu'il contient.
- **Slots : croissants avec le niveau d'arme** — slots de compétences par arme = `2 + floor(N_arme/20)` (max 6) ; slots de modules par compétence = `2 + floor(N_arme/25)` (max 5). La progression d'arme débloque de la complexité de build, pas seulement des chiffres.
- **Pool de mana : résolu (A.5)** — `20 + Volonté×3 + Méditation×2` (+ effets d'équipement, règle de retrait A.4.4). Ni la race (sauf via ses bonus de stats) ni l'arme n'y entrent directement.

---

## 6. Progression du personnage

- Au départ, le joueur choisit une **Race** et une **Classe**, qui déterminent un kit de base (stats, compétences de départ).
- Au-delà de ce kit initial, tout se débloque et progresse par l'usage (façon Elona), sans plafond.
- **Mort :** pas de permadeath — mort avec pénalité (perte d'objets/XP), puis respawn.

### 6.0 Double niveau : combat et général

Le "niveau" d'un personnage (joueur comme PNJ — même système, section 12) est **divisé en deux valeurs dérivées** :

- **Niveau de combat** : moyenne de toutes les compétences liées au **combat et à la survie** (armes, dual wielding/bouclier/deux mains, magie offensive/défensive, discrétion, athlétisme...).
- **Niveau général** : moyenne de toutes les autres compétences (artisanat, récolte, lecture, négociation, agriculture...).

Aucun des deux n'est une jauge qu'on remplit directement : ce sont des **agrégats calculés** depuis les compétences, qui elles seules progressent (à l'usage). Usages :
- Le **niveau de combat** sert au scaling des menaces : sélection de cibles des gabarits de quête (Annexe B.7), difficulté des raids (14.5), évaluation d'une créature avant de l'engager.
- Le **niveau général** sert au contenu civil : exigences de rang de guilde non-combat, évaluation d'un PNJ pour un poste de travail (14.2), etc.

**Décisions :**
- **Classification figée** (champ `category` de chaque compétence en données) : *combat/survie* = toutes les compétences d'armes, Dual Wielding, Bouclier, Deux Mains, tous les domaines de magie, Méditation, Contrôle du Mana, Esquive, Encaissement, Discrétion, Athlétisme. *Général* = tout le reste (récolte, artisanat, Lecture, Négociation, Dressage, Leadership, Agriculture, Élevage, Navigation).
- **Agrégat : résolu (A.1)** — moyenne des **5 meilleures** compétences de chaque catégorie (anti-dilution).

### 6.1 Races et classes

- **Races :** un mélange de races fantasy classiques (humain, elfe, nain...) et de races originales, propres au monde du jeu.
- **Classe :** détermine **uniquement des bonus de stats/équipement de départ** — aucune restriction durable ensuite (pas de plafond ni de pénalité liés à la classe une fois en jeu, cohérent avec la progression 100% par l'usage).
- **Création de personnage détaillée :** répartition de points, choix multiples — pas un simple menu déroulant simplifié.

**Décisions (résolu, Annexe C) :**
- **Races : C.2** est la liste de lancement (6 races avec bonus). **Classes : C.3** (6 kits complets). **Création : C.1** — 6 stats, 30 points à répartir (base 5, max 15 à la création), + race, classe, apparence (choix des parties du corps, 12).

### 6.2 Emplacements d'équipement

Pour un personnage humanoïde, **13 emplacements** :
- Tête
- Torse
- Jambes
- Pieds
- Mains
- 2 anneaux
- 1 amulette
- 2 emplacements d'armes
- 2 accessoires
- Dos (cape ou sac)

**Emplacements d'armes :** leur usage dépend du type d'arme équipée :
- **2 armes à une main** → entraîne la compétence **Dual Wielding**, en plus des compétences propres à chaque type d'arme.
- **1 arme à une main + 1 bouclier** → entraîne la compétence **Bouclier**.
- **1 arme à deux mains** → entraîne la compétence **Deux Mains**, en plus de la compétence du type d'arme.

**Équipement non-humanoïde :** les créatures utilisant d'autres templates de squelette (section 12) ont aussi des emplacements d'équipement, **adaptés à leur morphologie** (ex : un quadrupède n'a pas d'emplacement "mains" mais peut avoir des emplacements différents).

**Décisions :**
- **Accessoires (2 slots) :** ceintures, broches, bracelets, lunettes, trophées portés — objets à effets (A.4.4) qui ne sont ni anneaux ni amulettes ; pools de loot en F.7.
- **Armure : oui**, même double voie que tout objet — craft simple par recette (4.2) ET table de sculpture optionnelle (13, table items ou armes selon la pièce).
- **Emplacements par morphologie :** *quadrupède* = tête, torse, selle (dos), amulette, 2 accessoires · *volant* = tête, torse, amulette, 2 accessoires · *amorphe* = amulette, 2 accessoires uniquement. Défini par template dans les données (`equip_slots` de B.5).

### 6.3 Début de partie

**Séquence de démarrage :**
1. Création du monde (seed) puis **création de personnage détaillée** (6.1).
2. **Choix de la zone de départ sur la carte du monde** : le joueur voit la carte générée (biomes + indication du niveau de danger/corruption par case, façon heat-map simplifiée) et **clique sa case de départ**. C'est cohérent avec le danger piloté par le bruit (3.1) : le joueur choisit lui-même son niveau de risque initial — zone paisible pour apprendre, ou zone corrompue pour un départ brutal assumé.
3. **Spawn en pleine nature, seul** (façon Minecraft) : pas de scène d'ouverture, pas de village de départ imposé — le monde commence immédiatement. Position exacte : point marchable le plus proche du centre de la case choisie, en surface.
4. Équipement initial = kit de la classe (C.3), rien d'autre.

**Apprentissage par le jeu (zéro script)** : aucun tutoriel guidé ni quête d'apprentissage imposée. Un système de **tooltips contextuels** déclenchés par les événements EventBus enseigne au fil des premières fois (voir E.19). Tout est désactivable dans les réglages ("mode vétéran") et n'apparaît qu'une fois par savoir.

**En multijoueur :** les invités qui rejoignent spawnent près du joueur host (ou à un point de ralliement défini par le host), avec leur propre personnage importé (E.10).

**Décisions :**
- **Heat-map : vague par défaut** — 3 niveaux lisibles (paisible / dangereuse / mortelle) ; la **valeur précise** de corruption se débloque par rang dans la guilde Exploration (récompense d'information, cohérent avec 7.3).
- **Garde-fou de spawn :** re-tirage automatique du point exact si la surface marchable connexe < 200 blocs (falaise, îlot) — jusqu'à trouver une zone viable dans la case choisie, sinon case adjacente la plus proche.

### 6.4 Potentiel de progression (façon Elin)

Chaque **stat** (les 6 de C.1) et chaque **compétence** possède une sous-stat de **Potentiel**, de 0 à 200 :

- **Plus le potentiel est haut, plus la stat/compétence monte vite** : l'XP gagnée est multipliée par `potentiel/100` (potentiel 200 = progression ×2, potentiel 50 = ×0.5).
- **Monter de niveau consomme du potentiel** : chaque level up de la stat/compétence fait baisser son potentiel (formule A.1.1) — la progression s'essouffle d'elle-même si on ne l'entretient pas.
- **Potentiel de base permanent** : chaque personnage a un plancher de potentiel par stat/compétence, déterminé par sa **race et sa classe** (C.2/C.3) — le potentiel ne descend jamais sous ce plancher. C'est ce qui donne son identité mécanique durable à chaque combinaison race/classe (un nain garde toujours un bon potentiel de Forge, même sans l'entretenir).
- **Restaurer/dépasser le potentiel :** principalement en **mangeant des plats cuisinés** (7.7 — chaque aliment porte des bonus de potentiel vers les stats concernées), en dormant (buff Reposé, E.21), et via des **entraîneurs PNJ** (service payant en ville ou PNJ entraîneur recruté sur sa base — un puits d'or supplémentaire, 7.6).
- La gestion du potentiel devient une **boucle de jeu à part entière** (le cœur d'Elin) : bien manger n'est pas de la survie, c'est de l'optimisation de croissance — et ça raccorde l'agriculture, la chasse, la cuisine et l'élevage à la progression du personnage.
- S'applique aux **PNJ et compagnons** aussi (même système, section 12) : nourrir ses compagnons avec de bons plats accélère leur croissance.

---

## 7. Systèmes de vie simulée (inspiration Elona/Elin)

- Quêtes de guilde
- Réputation et relations PNJ
- Commerce et boutiques (achat/vente, tenir sa propre boutique)
- Agriculture et élevage
- Apprivoisement de créatures/montures

### 7.1 Commerce et boutiques

- **Vendre à des marchands PNJ existants** : possible directement, comme dans un RPG classique.
- **Tenir sa propre boutique** : possible aussi, en boutique **passive sur sa case claim** — les PNJ viennent acheter tout seuls, façon Elona (le joueur n'a pas besoin d'être présent pour vendre).
- **Prix :** un **prix suggéré est calculé automatiquement** (probablement à partir de la rareté/qualité/matériaux de l'objet — à relier au système de qualité, section 4.2), mais le joueur peut **ajuster ce prix librement**.
- **Monnaie :** une **monnaie unique** (or), pas de multi-devises ni de troc.

**Décisions (résolu, A.8/E.8/F.6) :**
- **Prix : formule A.8** (valeur matériaux × 1.5 × qualité × rareté × réputation).
- **Limite : l'étal est un meuble physique** (F.6, 12 slots) — plus d'étals = plus de slots de vente.
- **Consultation à distance : non au lancement** — l'or s'accumule dans le coffre de la boutique, relevé sur place (E.8) ; consultation à distance = extension future.

### 7.2 Réputation et relations PNJ

- **Pas de mariage prévu pour l'instant** (peut-être reconsidéré plus tard).
- **Système à quatre niveaux, en parallèle :**
  - **Réputation globale** : perception générale du joueur, toutes factions confondues.
  - **Réputation par royaume** : chaque royaume/faction a sa propre opinion du joueur.
  - **Relation par PNJ individuel** : chaque PNJ a sa propre relation avec le joueur.
  - **Réputation par race** : chaque race a sa propre perception du joueur.
- **Facteurs d'évolution (mélange de tous) :** actions positives/négatives envers les PNJ (aide, cadeaux, méfaits), quêtes accomplies, combat/protection (défendre un PNJ ou un village).

**Décisions :**
- **Interactions entre niveaux : oui, légères** — les rivalités entre races/royaumes sont déclarées en données (`rivals` dans races/B.9) : un gain de réputation envers X applique **−25 % de ce gain** envers ses rivaux déclarés. Pas de cascade au-delà d'un degré.
- **Conséquences par palier (échelle −100..+100) :** ≤ −50 : hostile à vue (gardes/civils fuient ou attaquent) · −49..−20 : prix +25 %, quêtes refusées · −19..+19 : neutre · +20..+49 : prix −10 % · ≥ +50 : quêtes spéciales, confidences/rumeurs (E.23), facilités de recrutement.
- **Recrutement : la relation individuelle est le critère** (B.5) ; les réputations race/royaume agissent en **modificateur de vitesse** du gain de relation (×0.5 à ×1.5 selon le palier), jamais en seuil direct.

### 7.3 Quêtes et guildes

**Génération des quêtes :** entièrement **procédurales**, générées à partir de gabarits (façon tableau de quêtes/bounty board) — cohérent avec l'infinité du monde et l'approche data-driven (section 10). Pas de questlines écrites à la main pour l'instant.

**Types de guildes envisagés :**
- Guerriers/combat
- Magie
- Artisanat/commerce
- Exploration/aventuriers
- Assassins/voleurs
- Transporteurs (logistique)
- Développement de ville/royaume
- Gladiateurs (tournois, arène — lié au PvP en duel, section 8)
- Navigateurs (exploration maritime, commerce à distance)
- Bâtisseurs (contrats de construction — lié aux tables de sculpture, section 13)
- Prospecteurs (repérage de gisements rares — lié aux couches de bruit de ressources, section 3.0)
- Chasseurs de trésor

**Progression de rang :** monter en rang dans une guilde donne accès à un **mélange** de :
- Meilleures récompenses (or, objets)
- Compétences/modules exclusifs à la guilde
- Accès à des zones/PNJ/services réservés
- **Tables de sculpture** (voir section 13) : accès aux tables des locaux de guilde à un rang intermédiaire, puis station personnelle à un rang supérieur — chaque table est liée à une guilde spécifique.

**Décisions :**
- **Gabarits par guilde : oui, résolu (B.7)** — chaque gabarit porte un champ `guild` ; chaque guilde a ses patterns propres (combat = éliminer, transport = livrer, bâtisseurs = construire, prospecteurs = localiser...).
- **Réputation de guilde : ce n'est PAS une réputation (7.2)** — c'est le système **rang + XP de guilde**, une progression, pas une opinion. Structure de rangs figée : **5 rangs** (Novice, Compagnon, Adepte, Expert, Maître), montée par XP de quêtes de guilde.
- **Multi-guildes : toutes cumulables** au lancement (les taxes hebdomadaires par guilde, A.8.1, sont le coût naturel du cumul).
- **Guilde développement de ville/royaume :** ses quêtes sont des **contrats de construction réels** (bâtir/réparer des structures sur des sites concrets, validées par la détection de pièces E.5) et des financements (apporter N matériaux à un projet communal contre or + XP de guilde).

*(Détail de l'apprivoisement — au-delà de ce qui est déjà couvert en section 12 — à développer ultérieurement.)*

### 7.4 Agriculture et élevage

- **Cultures :** cultivables **partout**, avec un **rendement variable selon le biome** (le biome influence l'efficacité, pas la possibilité de cultiver).
- **Faim/nutrition :** un système de faim **oblige le joueur à manger régulièrement** — mécanique de survie active, pas un simple bonus optionnel.
- **Élevage :** les animaux de ferme utilisent le **même système modulaire de créatures** que les monstres/PNJ (section 12) — pas de système séparé.

**Principe transversal : abstraction hors-site**

Toute gestion de ville/village/base (cultures, élevage, boutique passive — section 7.1, etc.) doit être **abstraite** quand le joueur n'est pas physiquement présent sur place, plutôt que simulée en temps réel dans le détail. Ce système d'abstraction est noté comme un **chantier à développer plus tard en profondeur**, mais il concerne déjà plusieurs mécaniques déjà posées : agriculture/élevage, boutiques passives (7.1), régénération des cases sauvages (3.3).

**Décisions (résolu) :**
- **Faim : A.9** (jauge 0-100, −1/90 s, paliers de malus, plancher 1 PV). **PNJ : E.15** (auto-nourris au garde-manger, proposition validée par défaut).
- **Abstraction hors-site : E.6** — résolution par **formules** (jamais de simulation accélérée), rapport au retour.

### 7.5 Habitat des PNJ (base du joueur)

Les PNJ résidant sur la base/claim du joueur (compagnons recrutés, animaux — section 12) ont des **besoins de logement**, selon leur statut :

- **PNJ normal** — a besoin d'une **pièce** remplissant toutes ces conditions :
  - Fermée, avec une **porte**
  - Au moins **un meuble** (n'importe lequel)
  - Un **toit**
  - Taille minimale : **2×2×2 blocs** (intérieur)
- **Statut "bétail"** — a juste besoin d'un **toit** (abri simple, pas de pièce fermée requise).

**Implications techniques :** nécessite un algorithme de **détection de pièce** (espace clos + porte + toit) — à ranger dans `systems/` (Annexe D). Le statut bétail/normal est un champ modifiable de l'entité créature (Annexe B.5).

**Règles :**
- **Besoin non satisfait :** le PNJ **reste** mais subit un **malus** (humeur/productivité) — pas de départ.
- **Partage de pièce :** possible, mais avec malus (−5 humeur par co-occupant au-delà du premier — chiffré dans les Décisions ci-dessous).
- **Statut bétail vs normal :** **assigné par le joueur lui-même** (il choisit de traiter une créature comme résident ou comme bétail).

**Décisions :**
- **Malus chiffrés :** sans logement valide : humeur −15 · pièce partagée : −5 par co-occupant au-delà du premier. **Effet de l'humeur :** la productivité des jobs (E.6/14.2) est multipliée par `humeur/100` × 1.5 borné [0.4, 1.2] — l'humeur est LE levier de rendement.
- **Meilleure chambre : oui** — +1 humeur par type de meuble distinct dans la pièce (max +10), +5 si volume ≥ 27 blocs. Les meubles à bonus propres (tapis, trophée, F.6) s'ajoutent.
- **Rétrogradation en bétail : oui, le PNJ réagit** — relation −30, humeur −20 (durables tant que le statut persiste). Traiter un roi en bétail a un prix relationnel, en plus du prix diplomatique (14.2).

### 7.7 Cuisine, alchimie et nourriture (voir aussi 6.4)

**Cuisine (station Cuisine, compétence Cuisine) :**
- Les recettes combinent des ingrédients (viandes, légumes, plantes, œufs...) en **plats**. Un plat porte : une valeur de **nutrition** (remplit la faim, A.9) et des **bonus de potentiel** (6.4) vers les stats liées à ses ingrédients.
- **La nutrition est le multiplicateur** (façon Elin) : `potentiel_gagné = Σ bonus des ingrédients × nutrition/100 × qualité du plat` — un plat raffiné vaut mieux que ses ingrédients crus, cuisiner a un vrai rendement.
- La qualité du plat suit la formule de qualité standard (A.3) sur la compétence Cuisine.

**Viandes (paramétriques par créature) :** chaque créature droppe **sa propre viande**, dont les bonus de potentiel dérivent des **stats de la créature source** (une viande d'ours brun donne du potentiel de Force/Endurance, une viande d'aigle de la Perception — formule A.9.1). Pas de contenu à la main : la viande est générée depuis la fiche de la créature (B.5).

**Alchimie (station Alambic, compétence Alchimie) :**
- Les **potions** donnent des **bonus temporaires** (buffs à durée : stats, résistances, régénérations, effets spéciaux — via le système de statuts F.4 et de modificateurs E.4).
- Ingrédients : **parties de créatures** (yeux, peaux, griffes, dents, os... — droppées par les mobs, matériaux paramétriques F.1) et **plantes** (F.8) ; les propriétés de la partie/plante orientent l'effet de la potion (un œil → potions de Perception/vision, une griffe → potions de Force...).
- Qualité de la potion (A.3, compétence Alchimie) = durée et intensité du buff.

**Boucle complète :** chasser (parties + viandes spécifiques) + cultiver (plantes, 7.4) → cuisiner (croissance long terme via potentiel) + distiller (puissance court terme via buffs) → progresser → chasser plus grand. La chasse d'une créature précise pour sa viande/ses parties devient un objectif en soi.

### 7.6 Économie et flux d'or (sources et puits)

**Principe :** avec récolte infinie (2) et progression sans plafond, l'inflation est structurellement garantie sans **puits** explicites — l'or doit pouvoir disparaître du jeu, pas seulement circuler.

**Règle unifiée — portefeuille de PNJ fini :** tout PNJ (marchand existant, client de la boutique passive 7.1, prêtre, maître de guilde...) a un **stock d'or maximal** selon son métier/rang, qui **se recharge lentement** (cadence hebdomadaire, même horloge que la corruption E.20 et la régénération 3.3). Un marchand à sec **refuse d'acheter en or** au-delà de son stock — il propose un **troc en objets** de valeur équivalente plutôt qu'un refus sec (débouché préservé, formule A.8.1). Cette règle unique couvre à la fois la vente aux marchands (7.1) et les ventes de la boutique passive (E.8) : même mécanique, deux contextes.

**Puits d'or récurrents — entretien du royaume (14) :**
- **Taxes de guilde** : prélèvement hebdomadaire automatique (% des gains de quêtes de la semaine, ou montant fixe croissant par rang) — cet or **sort du jeu**, il n'est reversé à aucun PNJ dépensable.
- **Entretien du territoire** : coût hebdomadaire proportionnel à la population de PNJ assignés et au nombre de structures spéciales (stations, tourelles, halls de guilde) — payé automatiquement depuis le trésor du royaume (alimenté par les boutiques passives, E.8). Non-paiement → malus (détail 14.6), pas de spirale automatique.
- **Résurrection de compagnons** (déjà acté, E.17) : coût ∝ niveau, payé à un prêtre — lui-même limité par son propre portefeuille (règle ci-dessus).
- **Mort du joueur** (déjà acté, A.10) : −10 % de l'or transporté, détruit — un puits ponctuel déjà en place.

**Boucle complète :** récolte → vente (limitée par les portefeuilles PNJ) → richesse → entretien du royaume (sort du jeu) + taxes de guilde (sort du jeu) — l'or circule et fuit, il ne s'accumule pas indéfiniment côté monde.

**Décisions :**
- **Barèmes : résolu (A.8.1)** — portefeuilles par métier/rang, taxe 5 % pondérée par rang, entretien 10 or/PNJ + 25 or/structure.
- **Trésor : visible et gérable** — écran de gestion de claim (E.13) : solde, prévisionnel hebdomadaire (revenus boutiques vs entretien), dépôts/retraits libres du joueur (constituer une réserve est permis et encouragé, cf. 14.6).

---

## 8. Multijoueur

- **Mode :** coopératif, groupes de **4 à 8 joueurs**.
- **Modèle réseau : host-and-join façon Terraria** — un joueur héberge la partie, les autres le rejoignent. Pas de serveur dédié requis, réaliste pour un développement solo.
- **Simplifié par l'abandon de la physique de destruction fine (voir section 4.1)** : la destruction par blocs pleins se synchronise comme un événement discret ("ce bloc a été détruit"), exactement comme Terraria/Minecraft — beaucoup plus simple qu'une simulation physique continue à synchroniser.
- Recommandation technique : s'appuyer sur l'**API multijoueur haut niveau de Godot** (moteur confirmé — voir section 10) plutôt que développer le réseau from scratch.
- **PvP : restreint** — uniquement via duel accepté entre joueurs, pas de PvP ouvert/non consenti.

---

## 9. Direction artistique

- **Voxel stylisé et coloré**, façon Minecraft (plutôt que pixel art ou ambiance sombre façon Noita).
- **Références de direction artistique :** voxel lisible et chaleureux — inspirations : la lisibilité matérielle de Minecraft, la générosité colorée de Dragon Quest Builders 2, le charme cubique de Cube World. La palette de matériaux (F.1.1) EST la palette du jeu : couleurs naturelles désaturées pour le monde, saturées réservées aux gemmes/magie/UI. Lumière douce, ombres colorées, brouillard de distance teinté par le biome.

### 9.1 Pipeline technique : modélisation et couleurs indexées

**Amendé le 2026-07-26 — deux outils, deux familles d'assets (décision de l'auteur) :**

| Famille | Outil | Format | Technique de couleur |
|---|---|---|---|
| **Blocs spéciaux, meubles (F.6), items/armes, structures et bâtiments (9.2)** | **MagicaVoxel** | `.vox` | index de palette + couleurs stand-in remappées (ci-dessous) |
| **Créatures, PNJ et montures (12, F.3)** | **Blockbench** | glTF/`.glb` (export), maillé et *riggé* dans l'outil | texture atlas pixel-art ; recoloration par échange de palette en shader (voir 12.1) |

*Tout ce qui suit dans cette section décrit le pipeline **MagicaVoxel**. Le pipeline créatures est décrit en 12.1.*

- Les modèles 3D de blocs, meubles, items et structures sont créés dans **MagicaVoxel**.
- Le format `.vox` stocke chaque voxel avec un **index de couleur** (pas une couleur RGB figée), relié à une palette de 256 couleurs. Changer une couleur dans la palette met à jour tous les voxels liés à cet index.
- **Technique de matérialisation dynamique :** pour les objets composés de plusieurs matériaux (ex : une épée = manche en bois + lame en minerai), on modélise avec des **couleurs "stand-in" dédiées** et non-naturelles (ex : vert fluo = emplacement bois, rose fluo = emplacement minerai). En jeu, ces index sont **remappés dynamiquement** vers la couleur réelle du matériau utilisé dans le craft (bois ou minerai spécifique).
- **Contrainte pipeline :** l'import doit préserver l'index de couleur par voxel (lecture directe du format `.vox`, pas d'export intermédiaire type OBJ qui fige la couleur en RGB par sommet).
- **Couleurs réservées structurelles :** en plus des couleurs stand-in de matériaux, d'autres couleurs réservées encodent les **points d'attache** des parties de créatures (voir 12.1) — même famille de technique, détectées et retirées à l'import.
- Cette approche s'articule naturellement avec l'architecture data-driven (section 10) : chaque matériau défini en données porte une couleur associée, utilisée pour le remapping à l'affichage/à la construction de l'objet.

**Texture/bruit des matériaux :**
- Chaque matériau a, en plus de sa couleur, sa propre **texture/bruit** (pour l'instant : uniquement du bruit par voxel — pas de texture continue étirée sur la surface).
- **Blocs de construction** (taille normale, 32px) : texture de bruit en **32×32 pixels par face** (amendé le 2026-07-19 — 1 pixel de bruit par pixel de face ; le sous-bloc de subdivision le plus fin, 4 px, porte 4×4 pixels de bruit — cohérent avec la chaîne 32→16→8→4 de la section 4.1).
- **Items et créatures/PNJ** : résolution différente, **2×2 pixels par voxel** (grain plus visible/chunky que les blocs).
- Le bruit est majoritairement **procédural**, avec un mélange de quelques textures dessinées à la main pour des matériaux spéciaux.

### 9.2 Structures et villes : extension aux bâtiments et routes

- Le même principe de couleurs "stand-in" remappées (voir 9.1) s'applique à l'échelle des **bâtiments, structures et routes**, pas seulement aux items/armes.
- Un petit nombre de **modèles génériques** (maison, puits, portion de route, mur d'enceinte...) suffit : chaque modèle porte des couleurs-index réservées par **catégorie de matériau** (peu de slots : **mur, toit, sol** — 3 catégories).
- Au moment de la génération d'un village, ces index sont remappés vers la **palette de matériaux propre au biome/type de village** (ex : pierre claire + bois sombre en zone nordique, grès + bois séché en désert).
- **Cohérence à deux niveaux :**
  - **Palette de base par village** : tous les bâtiments d'un même village partagent une palette de matériaux cohérente.
  - **Variantes ponctuelles** : certains bâtiments individuels peuvent s'écarter de la palette de base (ex : maison plus riche/plus pauvre avec des matériaux différents).
- **Bénéfice production :** un même prefab de bâtiment peut donner de nombreuses variantes visuelles selon le biome/village sans modélisation dédiée à chaque fois — gain de temps important pour un développement solo.
- S'articule avec la génération procédurale du monde (section 3.0) : le choix de palette par village peut découler des couches de bruit du biome environnant.

---

## 10. Architecture technique : Data-Driven Design

**Moteur cible : Godot.**

**Principe fondamental :** l'intégralité du jeu doit être pilotée par des données (data-driven), pas par du code en dur. Objectifs :
- Ajouter du contenu (matériaux, objets, monstres, biomes, modules de compétences, recettes, etc.) doit être aussi simple que créer/éditer une entrée de données, sans toucher au code.
- Les systèmes doivent interagir entre eux nativement, plutôt que via des cas particuliers codés en dur.

**Piste d'implémentation (à discuter) :** une architecture à base de **tags/composants** (façon ECS — Entity Component System), où :
- Un matériau, un objet, un monstre, etc. est une combinaison de composants de données (ex : `Dureté`, `Densité`, `Inflammable`, `Catégorie:Bois`, `Conducteur`, `Densité de mana`...).
- Les systèmes de jeu (feu, physique, craft, récolte, IA...) réagissent aux **tags/composants présents**, pas à des identifiants spécifiques codés en dur — ce qui permet aux systèmes d'interagir automatiquement entre eux (ex : le système de feu affecte tout objet possédant le tag `Inflammable`, qu'il s'agisse de bois, de tissu ou d'huile, sans code dédié à chaque cas).
- Le contenu (nouveaux matériaux, monstres, recettes, biomes...) se définit dans des fichiers de données (JSON ou équivalent) en assemblant ces composants.

**Portée :** le data-driven vise avant tout à accélérer le développement interne (ajout rapide de contenu par l'équipe) — pas une priorité de support au moddage communautaire pour l'instant.

### 10.1 Localisation (contrainte du jour 1)

Le jeu doit permettre de **changer de langue d'affichage** dans les réglages, à chaud (sans redémarrage). C'est une contrainte d'architecture posée dès le départ — trivial au jour 1, cauchemar à retrofit.

**Règle absolue :** aucun texte affiché ne vit dans le code ni dans les champs de données de gameplay — tout texte visible passe par une **clé de traduction**.

- **Système :** la localisation intégrée de Godot (`tr()`, fichiers CSV ou gettext .po, changement de locale à chaud).
- **Données de contenu :** les champs texte deviennent des clés — `"name_key": "material.chene.name"` au lieu de `"name": "Chêne"` — et les textes vivent dans `locale/fr.csv`, `locale/en.csv`, etc. GameData valide au boot que chaque clé référencée existe (clé manquante = warning console + affichage de la clé brute, jamais de crash).
- **Textes générés** (gabarits de quêtes B.7, rapports d'abstraction E.6, noms de paliers de qualité A.3, effets d'objets) : une clé de gabarit **par langue avec placeholders** (`quest.chasse_prime.text = "Éliminez {count} {target} près de {location}."`) — jamais de concaténation de morceaux de phrases (l'ordre des mots varie selon les langues).
- **Hors localisation :** les noms propres saisis par le joueur (modèles sculptés, PNJ renommés) et les ids internes.
- **Changement à chaud :** signal EventBus `locale_changed` → toute l'UI se rafraîchit.
- **Langues de lancement : français, anglais, japonais, chinois.** Implication CJK à prévoir dès le choix des polices : la police d'UI doit couvrir les glyphes japonais et chinois (police à large couverture type Noto Sans CJK en fallback), tailles/retours à la ligne testés dans les 4 langues (le CJK est plus compact, l'allemand-like plus long — l'UI doit tolérer les deux). L'interdiction de concaténation (ci-dessus) est doublement critique en CJK où l'ordre grammatical diffère fortement.

**Décisions :**
- **Format : JSON confirmé** (tous les schémas de l'Annexe B font foi).
- **Éditeur de contenu interne : non au lancement** — JSON édité à la main, avec la validation de schéma au boot + hot-reload F5 (D.2) comme filet ; un éditeur visuel n'est envisagé que si le volume de contenu le justifie plus tard.

---

## 11. Contraintes techniques & risques majeurs

- ~~Physique voxel fine en 3D~~ **Risque levé** : abandon de la simulation de destruction fine façon Noita au profit d'une destruction discrète par blocs pleins (voir 4.1), beaucoup moins coûteuse et bien plus simple à synchroniser en réseau.
- **Monde infini + persistance des claims** : besoin d'un système robuste de streaming de chunks et de sauvegarde différentielle (ne sauvegarder que ce qui a changé).
- **Netcode coopératif (host-and-join, façon Terraria)** : bien plus simple maintenant que la destruction se fait par blocs pleins (événements discrets), mais reste un développement à part entière.
- **Scope très large** (4 inspirations combinées) : risque de dilution du développement → prioriser un MVP centré sur 1-2 piliers avant d'étendre.
- **Architecture data-driven à grande échelle** : bien conçue dès le départ, sinon coûteuse à retrofit plus tard.
- **Abstraction hors-site** (voir 7.4) : la gestion de ville/village/base doit se simuler de façon abstraite quand le joueur n'est pas sur place (cultures, élevage, boutiques passives, régénération des cases sauvages) — chantier transversal à concevoir en profondeur, impacte plusieurs systèmes déjà posés.
- **Localisation dès le jour 1** (voir 10.1) : discipline permanente — toute string affichable passe par une clé de traduction dès la première ligne de code. Coût quasi nul si respecté d'emblée, refonte massive sinon.
- **Éclairage et transparence voxel** (impliqués par les stats `luminosite`/`transparence`, A.4.5) : nécessitent un système de propagation de lumière par bloc (échelle 0-15, façon Minecraft) et une passe de rendu séparée pour les blocs transparents — deux chantiers de moteur classiques mais non triviaux, à intégrer au pipeline de meshing dès sa conception.

---

## 12. Créatures et PNJ : système modulaire

**Principe :** les PNJ (villageois, marchands, monstres...) sont tous construits de la **même manière**, à partir de blocs de construction `.vox` assemblés de façon modulaire — il n'y a pas de distinction technique entre un "monstre" et un "PNJ humain".

**Squelette modulaire :** une créature humanoïde est composée de parties interchangeables :
- 1 tête (parmi une bibliothèque de variantes, ex : têtes n°1, 4, 18, 32...)
- 1 torse (ex : torse n°1, 42...)
- 2 bras (ex : bras n°1)
- 2 jambes (ex : jambe n°6)

Chaque créature du jeu est un assemblage choisi dans ces bibliothèques de parties.

**Unification monstre/PNJ :** tous les êtres vivants (monstres sauvages, villageois, marchands...) partagent la même structure de données : stats, inventaire, relations, etc. Un monstre est donc, techniquement, un PNJ comme un autre.

**Implication gameplay majeure :** grâce à cette unification, **n'importe quelle créature — un monstre sauvage aussi bien qu'un marchand — peut potentiellement devenir un compagnon**, via le même système sous-jacent de relations/réputation (voir section 7). Le fonctionnement complet des compagnons (capacité d'escorte par Charisme+Leadership, statuts permanent/suiveur territorial, ordres, mort et résurrection façon Elona) est spécifié en **E.17** ; l'IA de toutes les créatures en **E.16**.

**Templates de morphologie :** les créatures non-humanoïdes utilisent des **templates de squelette différents** selon leur morphologie (quadrupède, volant, amorphe, etc.), plutôt que d'être forcées dans le squelette humanoïde tête/torse/2bras/2jambes.

**Parties du corps = cosmétiques :** les parties assemblées (tête, torse, bras, jambes, ou équivalents selon template) sont **purement visuelles**. Les stats de la créature viennent d'ailleurs (race, classe, niveau).

**Conditions de recrutement :** variables selon le type de créature — un **mélange** de seuil de réputation/relation, d'action spécifique (objet, compétence de dressage), et/ou de quête dédiée selon les cas.

**Mécanique d'apprivoisement :** en deux temps — une **action dédiée** est nécessaire pour la première rencontre/le premier apprivoisement (jet de compétence universel, E.3 : 1d20 + Dressage/2 + Charisme/4 vs DD = 10 + niveau_combat_cible/2, cible affaiblie = bonus), puis la **relation évolue ensuite** dans le temps comme pour tout autre PNJ (via le système de réputation/relations, section 7).

### 12.1 Modèles de créatures (Blockbench)

**Amendé le 2026-07-26 (décision de l'auteur) : les créatures sont modélisées et riggées dans Blockbench, pas assemblées à partir de parties `.vox`.** Une créature = **un modèle complet**, exporté en glTF/`.glb` avec son squelette et ses animations, référencé par `model` dans sa fiche B.5.

**Ce que ce choix remplace :** la bibliothèque de parties interchangeables et l'assemblage par points d'attache (spécification d'origine conservée plus bas comme référence). Conséquences assumées :

- `parts_pool` (B.5) devient **facultatif et inutilisé** pour les créatures Blockbench — la variété vient de modèles distincts et de la recoloration, plus du tirage de parties. Le champ reste au schéma pour ne pas casser les fiches existantes.
- Les **templates de squelette** (humanoïde / quadrupède / volant / amorphe) restent pertinents : ils ne pilotent plus l'assemblage mais restent la clé des `equip_slots` par morphologie (6.2) et des profils d'IA (E.16).
- Les **points d'équipement visibles** (arme en main, cape au dos) deviennent des **os nommés** du rig Blockbench (`attach_arme`, `attach_dos`...) plutôt que des voxels-marqueurs — même rôle, convention de nommage à figer dans les données.
- La **recoloration** (variantes rares 12.4, statue 1:1 de F.3, teintes de biome) reste possible : la texture atlas est en pixel-art à palette réduite, l'échange de couleurs se fait **en shader** exactement comme le remapping `.vox`, en travaillant sur des couleurs-clés de la texture au lieu d'index de palette.
- Les **couleurs réservées d'attache** de `data/reserved_colors.json` (#FF8000 bras, #8000FF patte, #0080FF tête...) ne servent plus aux créatures. Elles restent réservées pour les blocs/meubles MagicaVoxel qui en auraient besoin — aucune n'entre en collision avec la palette de matériaux (F.1.1).

**Statut d'implémentation (2026-07-26) :** les créatures en jeu sont des **capsules colorées provisoires**. Les 37 fiches de F.3 existent en données avec leurs stats, profils d'IA et biomes ; il manque les modèles Blockbench et l'importeur glTF associé.

---

*Spécification d'origine, conservée comme référence (assemblage `.vox` par points d'attache — remplacée pour les créatures, la technique reste valable pour tout assemblage voxel futur) :*

**Principe :** l'assemblage des parties du corps est piloté par des **voxels-marqueurs de couleurs réservées** placés directement dans les modèles .vox (extension de la technique des couleurs stand-in, section 9.1) :

- Sur chaque partie (torse, membre, tête...), le modeleur place des voxels d'une **couleur fluo réservée** aux emplacements de connexion.
- **Une couleur réservée par type d'attache** : ex. vert fluo = bras, cyan fluo = jambe, jaune fluo = tête/cou, magenta structurel = main/arme... (nomenclature exacte des couleurs réservées à figer dans les données).
- À l'import, le script détecte ces marqueurs, **les retire du modèle visible**, et enregistre leur position comme **point d'attache** dans la ressource.
- À l'assemblage d'une créature, le jeu aligne le point d'attache de chaque membre sur le point correspondant du torse — n'importe quelle partie de la bibliothèque se branche sur n'importe quelle autre, tant que les couleurs d'attache correspondent.
- **Orientation :** chaque attache est encodée par **deux voxels marqueurs adjacents** (position + direction), pour que le membre sache dans quel sens pointer.

**Bénéfices dérivés :**
- Les templates de morphologie (section 12) deviennent triviaux : un quadrupède est simplement un torse portant 4 attaches "patte" au lieu de 2 attaches bras + 2 attaches jambes.
- Les points d'attache servent aussi de **pivots d'animation** (rotation de l'épaule = rotation autour de l'attache du bras).
- Extensible aux **points d'équipement visibles** (l'arme équipée s'attache au marqueur main, la cape au marqueur dos...).

**Décisions :**
- **Templates de squelette au lancement : 4** — bipède/humanoïde, quadrupède, volant, amorphe (cohérent avec E.16/F.3). Extensible par données.
- **Bibliothèques de parties au lancement :** humanoïde 12 têtes / 8 torses / 8 bras / 8 jambes · quadrupède 6 têtes / 4 torses / 6 pattes · volant 4 têtes / 4 torses / 4 ailes · amorphe 6 corps entiers.
- **Règle de recrutement par type (défauts, surchargés par créature en B.5) :** humanoïdes intelligents → `relation` · bêtes/animaux → `dressage` · PNJ uniques (rois, maîtres) → `dressage` à DD très élevé ou `quete` · certains → `jamais`.
- **Couleurs réservées figées (`data/reserved_colors.json`) :** stand-in matériaux : #00FF00 (catégorie 1 de la recette), #FF00FF (cat. 2), #00FFFF (cat. 3), #FFFF00 (cat. 4) · attaches : #FF8000 bras, #8000FF jambe/patte, #0080FF tête/cou, #FF0080 main/arme, #80FF00 dos, #008080 selle/monture · #FFFFFF = second voxel d'orientation de toute attache. Aucune de ces valeurs n'existe dans la palette F.1.1 (vérifié).

### 12.2 Âge des PNJ

- Chaque PNJ a un **âge** (champ d'instance, en années in-game), qui avance avec le calendrier (1 an in-game = valeur à calibrer, défaut 120 jours in-game).
- **Catégories d'âge** (modulent l'apparence via les parties .vox et les stats) : jeune → adulte → âgé. Les PNJ âgés perdent progressivement en stats physiques (−10 % par tranche au-delà du seuil) mais leurs compétences acquises restent — un vieux forgeron reste un maître.
- **Mort de vieillesse :** au-delà de l'espérance de vie de sa race (donnée `lifespan` par race, avec variance ±15 %), un PNJ a une chance croissante par semaine de mourir naturellement (hors écran : résolu à l'échéance, timer wheel G.6). Sa mort déclenche la **succession** (12.3) s'il portait un rôle, et l'héritage familial de ses biens.
- **Naissances :** les couples de PNJ (champ `spouse`) peuvent avoir des enfants (nouvelle instance liée par `family`, catégorie jeune), qui grandissent et prennent des jobs à l'âge adulte — c'est le moteur démographique interne des villages, complémentaire de l'immigration (E.25). Les jeunes PNJ ne sont ni recrutables ni assignables.
- **Conséquence design :** la population du monde est un flux, pas un stock — les rois meurent aussi de vieillesse (la succession n'est pas qu'une affaire d'assassinat), les lignées existent réellement, et un compagnon mortel vieillit (son espérance de vie raciale s'applique — attachement et renouvellement).

### 12.3 Familles, statuts et succession

**Liens familiaux :** au-delà des relations générales (7.2), un PNJ peut porter des liens de **famille** (parent/enfant/conjoint — champ `family` du schéma B.5). Ces liens ne sont pas décoratifs : ils pilotent la succession — et la démographie (12.2).

**Gouvernance et succession des PNJ uniques (rois, maîtres de guilde, prêtres...) :** leur mort est **définitive pour l'individu** (pas de résurrection façon compagnon, E.17) — mais le **rôle** qu'ils occupaient est repris selon la règle de succession propre à sa structure :
- **Monarchie héréditaire** (royaumes, 14.4) : l'héritier désigné (aîné des enfants, ou héritier explicitement nommé) monte sur le trône après un **délai de transition** (quelques semaines).
- **Conseil/démocratie** (autre type de gouvernance possible pour un royaume PNJ) : le second dans la hiérarchie (ex. premier ministre) prend la relève — même délai.
- **Guilde :** l'officier de plus haut rang après le maître devient le nouveau maître de guilde.
- **Règle générale :** tout PNJ avec un rôle de leadership porte un champ `succession_rule` (`heir` → PNJ désigné par lien familial, ou `next_in_rank` → PNJ de plus haut rang restant dans la même faction/lieu).
- **Vacance :** pendant le délai de transition, le poste est vide (conséquences visibles : pas de nouvelles quêtes de guilde, instabilité du royaume — fenêtre d'opportunité pour la diplomatie ou la conquête, 14.4/3.4).
- **Absence d'héritier ou de second** (lignée éteinte, guilde sans officier) : vacance prolongée, potentiel déclencheur narratif (crise de succession) — traité au cas par cas, pas de repeuplement magique automatique.
- **Tous les royaumes n'ont pas de roi** : le type de gouvernance (monarchie, conseil...) est une propriété du royaume (champ `government_type`, schéma B.9), pas une constante du jeu.

**Décisions :**
- **Délais de transition : résolu (E.25)** — guilde 2 semaines, royaume 4 semaines.
- **Données de royaume : résolu (B.9)** — schéma complet (gouvernance, territoire, taxes, lois, diplomatie).
- **Crise de succession exploitable : oui** — pendant une vacance (héritier absent ou délai de transition en cours), une **conquête (3.4) bénéficie d'un DD réduit de 25 %** sur le territoire concerné ; revendiquer un trône vacant soi-même passe par ce même pipeline. Soutenir un prétendant = extension future (contenu, pas système).

### 12.4 Monstres rares (inspiration Phantasy Star Online)

**Variantes rares :** à la résolution d'un spawn (E.16), une créature a une faible chance d'apparaître en **variante rare** — exclue pour les civils, PNJ uniques et le bétail (champ `rare_chance` de B.5, défaut 2 %, 0 pour les exclusions).

- **Stats :** multipliées ×2 à ×3 (tirage par tier) par rapport à la créature de base.
- **Apparence :** teinte distincte (or/argent/prismatique selon tier) via le **paramètre de recolorisation par instance déjà en place pour toutes les créatures** (G.5) — zéro nouveau système de rendu — plus un effet émissif (glow), repérable de loin, cohérent avec la mécanique `luminosite` (A.4.5).
- **Nom affiché :** `[Épithète] [Nom de créature]` (ex. "Loup Blanc Ancestral") — épithètes tirées d'un pool par tier (`data/rare_epithets.json`, localisé, 10.1).
- **Drop garanti :** un objet à effets (A.4.4) au budget renforcé (3-4 effets au lieu de 0-2) systématiquement à la mort.

**Décisions :**
- Réutilise entièrement les systèmes existants (recolorisation par instance G.5, effets d'équipement A.4.4) — aucune nouvelle brique technique.

**Questions ouvertes :**
- Les tiers de rareté (or/argent/prismatique) ont-ils des taux de spawn différenciés, ou un seul tier "rare" au lancement avec l'extension vers plusieurs tiers plus tard ?

### 12.5 Noms de PNJ et de villes (génération culturelle)

**Principe : générateur par préfixe + suffixe, piloté par culture.** Chaque nom (prénom, nom de famille, nom de ville) est formé en tirant une **partie A** et une **partie B** dans les pools d'une **culture** (schéma B.11) et en les concaténant — aucun nom écrit à la main, une variété énorme depuis quelques dizaines d'entrées par pool.

- **Chaque PNJ a un prénom ET un nom de famille**, générés à l'instanciation (B.5). Le nom de famille est **hérité** : un PNJ fondateur (sans parent) tire un nom de famille dans le pool de sa culture, ses enfants (12.2, liens `family`) le portent automatiquement.
- **Titre pour les PNJ importants** : tout PNJ à `leadership_role` (12.3) reçoit en plus un **titre** tiré du pool de sa culture, adapté à son type de rôle (Roi/Reine pour une monarchie, Premier Ministre pour une république, Grand Maître pour une guilde...) — affiché avant son nom (ex. "Roi Aldric Sombreval").
- **Culture ≠ race — deux axes indépendants** : une race peut porter plusieurs cultures possibles selon le royaume où elle est née (un royaume **humain** peut avoir une culture à sonorité chinoise, nordique, latine... — cf. exemple B.11). Chaque culture déclare des **affinités de tirage par race** (`race_affinity`) : les races "originales" (Sylvide, Cendreux, Échomorphe) ont chacune une culture qui leur est propre (peu ou pas partagée), tandis qu'Humain/Elfe/Nain piochent parmi un plus large éventail de cultures inspirées du monde réel.
- **Villes et villages** héritent de la culture de leur royaume (E.27) — noms cohérents à l'échelle d'un même royaume.
- **Ordre des noms** configurable par culture (`name_order`: `prenom_nom` ou `nom_prenom`) — certaines cultures nomment famille avant prénom.

**Décisions :**
- **Cultures de lancement : 10** (liste C.9) — assez pour une vraie variété sans exploser le volume de contenu à la main.
- Détail technique complet (algorithme, formats) : **E.31**.

---

## 13. Tables de sculpture : création d'objets custom

**Principe :** des stations de craft spéciales — les **tables de sculpture** — permettent au joueur de designer lui-même la forme de ses objets, plutôt que de simplement combiner des matériaux via une recette fixe. **La sculpture n'est jamais obligatoire** : c'est une option pour plus de personnalisation, en plus du craft simple par recette (voir 4.2) qui reste toujours disponible pour tous types d'objets.

**Catégories de tables :** une table dédiée par type d'objet — **items, armes, blocs, meubles, véhicules**.

**Déroulé :**
1. Le joueur utilise la table correspondant à ce qu'il veut créer.
2. Il choisit la **fonctionnalité** de l'objet (ex : épée, lit, décoratif, etc.) — la fonctionnalité détermine le rôle mécanique de l'objet.
3. Un **éditeur de sculpture** s'ouvre, avec un **périmètre délimité** dans lequel construire.
4. Le joueur construit la forme avec les **blocs de son inventaire** (les matériaux qu'il possède réellement).
5. Une fois la sculpture **validée**, les **stats de l'objet sont calculées automatiquement**.
6. Le modèle obtenu est **sauvegardé** et **nommé** par le joueur.
7. Le joueur peut ensuite **refabriquer le même modèle à volonté**, tant qu'il dispose des matériaux nécessaires — le design sauvegardé devient une recette réutilisable.

**Lien avec les autres systèmes :**
- Se distingue des objets pré-modélisés par l'équipe (loot, PNJ marchands — voir 9.1) qui utilisent la technique de couleurs "stand-in" remappées : ici, le joueur place directement les vrais matériaux voxel par voxel, donc pas besoin de remapping de couleur — la couleur/texture réelle du matériau s'affiche nativement pendant la sculpture.
- S'articule avec le système de matériaux et de compétence d'artisanat (section 4.2).

**Taille du périmètre :** dépend de la table/fonctionnalité choisie (ex : la table à véhicules offre un périmètre bien plus grand qu'une table à items).

**Calcul des stats :** dépend **uniquement des matériaux utilisés** (même logique que pour les outils, section 4.2) — la forme/géométrie n'affecte pas les stats.

**Partage :** un modèle sauvegardé est **partageable avec les coéquipiers en coopératif**.

**Obtention : récompenses de guilde (progression en deux temps)**

Les tables de sculpture ne s'achètent pas et ne se craftent pas librement : elles se **débloquent en montant en rang dans les guildes** (section 7.3), en deux étapes par table :
1. **Rang intermédiaire** : droit d'utiliser les tables publiques présentes dans les locaux de la guilde.
2. **Rang supérieur** : obtention de la **station personnelle** (à poser sur son claim ou transporter, comme toute station — section 4.2).

| Table de sculpture | Guilde |
|---|---|
| Blocs / structures | Bâtisseurs |
| Meubles | Bâtisseurs (rang inférieur à celui des structures) |
| Armes | Guerriers / Gladiateurs |
| Items | Artisanat/commerce |
| Véhicules | Navigateurs / Transporteurs |

Ça renforce l'identité mécanique de chaque guilde (récompense désirable au-delà de l'or) et fait de la sculpture un privilège mérité, cohérent avec son statut optionnel.

**Décisions :**
- **Qualité sur les objets sculptés : oui** — même formule A.3, sur la compétence d'artisanat associée à la table utilisée. Un objet sculpté = stats des matériaux (pondération voxel) × qualité, exactement comme un craft simple.
- **Contrainte de forme : aucune** — forme totalement libre, la fonctionnalité choisie fait foi. **Unique exception : les véhicules** (E.24, blocs fonctionnels requis).
- **Partage : échange manuel explicite** — le créateur pousse un design vers le **catalogue de groupe** sur action volontaire (E.9) ; jamais de partage automatique.
- **Rangs de déblocage (structure 5 rangs, 7.3) :** accès aux tables des locaux de guilde au rang **3 (Adepte)** ; station personnelle au rang **4 (Expert)**.
- **Tables partagées entre deux guildes : chemins indépendants, conditions identiques** — rang 3/4 dans l'une OU l'autre suffit.

---

## 14. Le royaume du joueur (endgame)

**Vision :** la destination naturelle d'une partie est de passer d'**aventurier** à **bâtisseur de royaume**. Le joueur étend progressivement son territoire, le peuple, l'exploite, le défend, et finit par interagir d'égal à égal avec les royaumes PNJ. La plupart des systèmes du jeu convergent vers cette boucle.

### 14.1 Expansion territoriale

- Le joueur **claim de plus en plus de cases** autour de sa base (extension du système de claims, section 3.3), OU **conquiert des villages PNJ existants** sans les détruire (voir 3.4) — deux voies d'expansion, colonisation du vide et annexion du peuplé.
- Chaque case revendiquée reçoit un **rôle configurable à tout moment** (zonage — voir 3.3) : base, habitation, champs, ressources naturelles — l'aménagement du territoire est une couche de gestion à part entière.
- Il y **construit des bâtiments** (construction libre + modèles de structures sculptés, sections 4 et 13).

### 14.2 Population et exploitation

- Le joueur **recrute des PNJ** (via les mécaniques de la section 12 : relation, dressage, quête) qui viennent résider sur son territoire (besoins de logement, section 7.5).
- **Exploitation des ressources :** le joueur **assigne** les PNJ à des tâches précises (poste de travail, zone à exploiter), puis les PNJ les **exécutent en autonomie**. Hors présence du joueur, l'exécution passe par le système d'abstraction hors-site (section 7.4).
- **Capture :** aucune créature n'est exclue des systèmes de capture/statut — **même les PNJ uniques ou importants (rois, chefs...) peuvent être capturés** et assignés en bétail (section 7.5). Conséquences de réputation proportionnelles à l'importance de la cible (capturer un roi = réputation du royaume concerné effondrée, hostilité, primes...).

### 14.3 Halls de guilde

- Le joueur peut **construire les halls des guildes dans lesquelles il a un rang élevé** sur son propre territoire.
- Bénéfice : prendre les quêtes de ces guildes **sans se déplacer** — le contenu de guilde vient au joueur.

### 14.4 Statut de royaume, gouvernance, lois et diplomatie

- **Le territoire du joueur devient mécaniquement un royaume à part entière**, au même titre que les royaumes PNJ : il entre dans le système de réputation par royaume (section 7.2) et peut être perçu/traité comme tel par les autres.

**Répartition dans le monde :** les royaumes sont des **îlots de civilisation** séparés par de vastes terres sauvages **sans lois ni douanes** (la wilderness est l'anarchie de fait). Toutes les tailles existent, du hameau-État à la grande puissance dont la capitale s'étale sur plusieurs cellules ; chaque royaume a une **race dominante** (selon le biome de sa capitale — ~90 % de la population, et l'exclusivité des rôles de gouvernance), les autres races y étant présentes mais rares et jamais au pouvoir. Génération complète en E.27.

**Types de gouvernance (par royaume, y compris celui du joueur) :** chaque royaume a un **type de gouvernance** qui détermine sa règle de succession (déjà posée en 12.3), son niveau de taxes, ses politiques commerciales, et surtout **ses propres lois**. Types de départ :
- **Monarchie héréditaire** — succession par héritier.
- **République/démocratie élue** — succession par le second en rang ; taxes modérées, lois généralement stables.
- **Théocratie** — gouvernée par une figure religieuse ; lois souvent strictes, liées à un culte (interdits alimentaires, jours sacrés).
- **Ploutocratie / guilde marchande dirigeante** — le plus riche/la guilde de commerce gouverne ; taxes élevées mais commerce très favorisé, peu de lois hors affaires.
- **Dictature militaire** — taxes élevées (effort de guerre), lois strictes, défenses (14.5) renforcées par défaut.
- **Anarchie** — **pas de gouvernement central, pas de leadership_role, pas de succession** (12.3 ne s'applique pas) : peu ou pas de lois, notamment **le meurtre y est légal** (aucune conséquence légale — voir plus bas). En contrepartie : pas de garde organisée, défenses de zone faibles par défaut (14.5), corruption locale (E.20) généralement plus haute.

**Lois propres à chaque royaume (`data/kingdoms/*.json`, section B.9) :** chaque royaume définit sa propre liste de lois — comportements et objets légaux ou illégaux, **totalement indépendante des autres royaumes**. Deux catégories :
- **Lois cohérentes avec la gouvernance** : ex. vol illégal partout sauf en anarchie, port d'armes réglementé en théocratie.
- **Lois arbitraires/absurdes** (flavor assumé, dans l'esprit Elona/Elin) : un royaume peut interdire un objet sans raison apparente — ex. **la pomme est totalement illégale** dans tel royaume. Simple à générer (piocher un item courant + statut illégal), grande valeur comique et mémorable pour un coût de contenu quasi nul.

**Détection et conséquences :** une infraction n'a de conséquence que si elle est **repérée** (jet de Discrétion / cône de détection des PNJ à proximité, E.16 — cohérent avec le vol/la contrebande). Conséquences possibles par loi (`consequence` dans les données) : amende automatique, confiscation de l'objet, hostilité immédiate des gardes locaux, ou simple impact sur la réputation par royaume (7.2). Un royaume sans gardes (anarchie) ne peut mécaniquement pas faire appliquer ses lois — la loi y est décorative par construction.

**Politiques commerciales (import/export) :** chaque royaume applique des **taxes douanières** par catégorie de matériau (au-delà des taxes de guilde/entretien déjà posées en 7.6), pouvant aller jusqu'à l'**interdiction totale** d'un bien. Conséquences gameplay :
- Raccord avec la guilde **Transporteurs/Navigateurs** (7.3) : les routes commerciales inter-royaumes deviennent un vrai calcul économique (où vendre, où passer).
- **Contrebande** émergente : transporter un bien interdit à travers une frontière est risqué (détection = confiscation/hostilité) mais lucratif — sans système dédié, juste la combinaison des lois + Discrétion + commerce déjà posés.

- **Diplomatie :** le joueur peut passer des **accords avec les autres royaumes** (commerce, non-agression, alliance...) — la gouvernance du royaume visé influence ce qui est proposable (une dictature militaire négocie différemment d'une république).

**Décisions :**
- **Conséquences légales : résolu (E.26)** — 3 types (`amende:N`, `confiscation`, `gardes_hostiles`) + impact de réputation systématique proportionnel à la sévérité. Sévérités par défaut : objet interdit → confiscation · vol → amende · violence/meurtre → gardes hostiles.
- **Accords diplomatiques (4 types, disponibilité selon gouvernance) :** *Accord commercial* (tarifs douaniers −50 % réciproques — favorisé par ploutocratie/république) · *Non-agression* (aucun raid entre les deux — accessible à tous sauf anarchie, qui ne peut rien garantir) · *Alliance défensive* (renforts PNJ lors des raids subis, E.7 — république/monarchie) · *Tribut* (paiement hebdomadaire contre paix — exigé typiquement par dictature militaire ; le joueur peut aussi l'exiger d'un royaume faible).
- **Gouvernance du royaume du joueur : choisie par le joueur** à la fondation (seuil 14.5), **changeable** ensuite (délai de transition 4 semaines avec malus d'humeur temporaire −10 sur la population — les régimes ne changent pas sans friction).

### 14.5 Défense

- Le joueur défend son territoire avec des **gardes** (PNJ assignés), des **tourelles** et des **murs**.
- **Attaques réelles** : le territoire peut subir des raids (monstres, royaumes hostiles).
  - **Joueur présent sur place** : l'attaque se joue en temps réel/tactique, dans le monde voxel.
  - **Joueur absent** : l'attaque est **simulée** via le système d'abstraction hors-site (section 7.4) — le résultat (dégâts, pertes, victoire des défenses) est calculé et rapporté au joueur.

**Décisions :**
- **Seuil de royaume reconnu : 8+ cellules claim ET 5+ PNJ résidents** — à ce moment, une entrée B.9 est créée pour le joueur (gouvernance à choisir, 14.4), la diplomatie et les raids de royaumes deviennent possibles. Avant ce seuil : simple "campement" aux yeux du monde (raids de monstres/bandits seulement).
- **Accords diplomatiques : résolu (14.4)** — 4 types selon gouvernance.
- **Déclencheurs et échelle des raids : résolu (E.7/E.20)** — jet hebdomadaire, probabilité f(corruption effective, valeur du territoire, réputations négatives — roi capturé compris), force ∝ valeur du territoire, jamais scalée sur le joueur.
- **Résolution en absence : résolu (E.6)** — `defense_totale = Σ gardes(niveau_combat × équipement) + tourelles + bonus murs` vs `force_raid`, en un jet ; défaite = pertes proportionnelles, jamais de wipe.
- **Postes de travail figés (11) :** mineur, bûcheron, fermier, éleveur, garde, vendeur, forgeron, couturier, cuisinier, herboriste, transporteur. Chaque poste mappe une compétence (rendement E.6) — extensible en données.

### 14.6 Entretien et taxes (voir 7.6)

- Le royaume coûte un **entretien hebdomadaire** (population assignée + structures spéciales) et des **taxes de guilde**, prélevés automatiquement sur le trésor du royaume (alimenté par les boutiques passives, E.8) — ce sont les puits d'or qui contrebalancent la richesse générée par l'exploitation territoriale (14.2).
- **Non-paiement (trésor insuffisant)** : malus progressifs, jamais de spirale de destruction automatique — humeur des PNJ en baisse, gardes moins efficaces, tourelles hors service jusqu'à régularisation. Un rapport hebdomadaire (même mécanisme que le journal E.6) informe le joueur avant que ça devienne critique.

**Décisions :**
- **Paliers de dette :** 1 semaine impayée : humeur générale −5 · 2 semaines : productivité −25 %, tourelles hors service · 4+ semaines : les gardes cessent de patrouiller, 1 PNJ peut quitter le territoire par semaine (le moins fidèle en relation). Tout se rétablit dès régularisation.
- **Réserve : oui** — dépôts libres et illimités dans le trésor (7.6), qui absorbe automatiquement les mauvaises semaines.

---

## 15. MVP : premier jalon jouable

**Objectif :** une **tranche verticale mince** qui touche à tous les piliers, avec un **focus fort sur le monde et la construction** — le pilier prioritaire à prouver en premier.

**Inclus dans le MVP :**

*Monde et construction (priorité) :*
- Génération procédurale avec un jeu de couches de bruit réduit (altitude, température, humidité — les couches secondaires comme mana/danger/ressources peuvent être simplifiées ou reportées).
- Monde voxel continu, carte du monde avec voyage rapide.
- Une poignée de biomes de base.
- Construction avec subdivision (au moins 2-3 niveaux pour valider la technique, sans forcément les 5 niveaux complets dès le départ).
- Quelques catégories de matériaux et récolte de base.

*Combat et magie (minimal) :*
- Un ou deux types d'armes avec quelques slots de compétences.
- Un petit nombre de modules pré-définis pour valider la boucle (le système complet de grimoires/manuels peut arriver après).
- Système de mana basique.

*Vie simulée (minimal) :*
- PNJ de base utilisant le système modulaire (section 12), sans forcément tout l'éventail de guildes/commerce dès le départ.

**Reporté après le MVP :**
- Les 12 guildes et leur système de quêtes complet.
- Le système complet de réputation à 4 niveaux.
- L'agriculture/élevage et l'abstraction hors-site.
- Les tables de sculpture (peuvent venir juste après, comme feature de personnalisation).
- Le multijoueur complet (même si l'architecture doit être pensée dès le départ pour ne pas bloquer son ajout plus tard).
- Direction artistique poussée (une palette de base suffit pour le MVP).

*(Répartition validée — l'ordre de construction exécutable est en D.3, avec critères de perf par étape en G.8.)*

---

## 16. État du document

**Toutes les questions de design et d'implémentation sont tranchées** : chaque section porte ses Décisions, les formules vivent en Annexe A, les schémas de données en B, le contenu de lancement en C et F, l'architecture Godot en D, les intégrations système en E, la stratégie de performance en G. Une IA ou un développeur peut suivre ce document et l'ordre de construction D.3 (avec les critères de validation G.8) sans avoir à inventer de règle manquante — les valeurs chiffrées restent des défauts à équilibrer en playtest, jamais des trous.

**Amendements postérieurs à la rédaction** (le document n'est plus figé — chaque écart entre le design et le code doit atterrir ici, sinon le GDD cesse de faire autorité sans que personne ne le sache) :
- **2026-08-02 — résolveur de modificateurs (E.4)** : implémenté, avec deux écarts assumés documentés sous E.4 (instance portée par l'entité plutôt que singleton ; bonus de race fondus dans la base). Sans impact de design.
- **2026-08-02 — plancher de potentiel (6.4)** : le plancher de race/classe était appliqué à la création mais pas respecté au level up, ce qui rendait l'identité de race temporaire au lieu de permanente. Corrigé, sonde `--probe-potentiel`. Le texte de 6.4 était juste ; c'est le code qui ne le suivait pas.
- **2026-07-28 / écrit le 2026-08-02 — combat directionnel (E.3.1)** : le jet de toucher d'E.3 est abandonné, la géométrie décide du toucher. §5.1 et E.3 portent l'avertissement, E.3.1 fait autorité. **Ceci a rouvert une question d'architecture** : le mode tactique (5.0) n'a plus de forme évidente — trois pistes en fin d'E.3.1, aucune tranchée. C'est le premier trou de design réel du document depuis sa rédaction.

**Seuls restent ouverts, par nature (choix créatifs personnels, sans impact d'architecture) :**
- Le **nom du projet**.
- Donjons (3.5) : taille exacte des salles/connecteurs en blocs, taille de la bibliothèque de prefabs au lancement, fréquence de réapparition de nouveaux donjons dans le monde.
- Monstres rares (12.4) : nombre de tiers de rareté.
- ~~Noms/cultures (12.5) : contenu exact des pools de noms pour les 10 cultures (C.9)~~ — **écrit le 2026-08-02** (`data/name_cultures/`, dix cultures au schéma B.11).
- Le **lore** : noms propres des royaumes générés (les gabarits existent, 10.1/E.27), textes d'ambiance, mythologie du monde — à écrire au fil du contenu.
- L'ajout des **saisons** (E.28 : l'architecture les accueille, gros impact agricole — à décider après playtest de la boucle agricole).
- La réintroduction éventuelle de **créatures fantastiques** dans les zones à haute corruption (F.3 : prévu sans changement de système).
- **Audio/musique** : direction sonore à définir avec un compositeur — hors périmètre de ce document.

**Extensions futures explicitement préparées par l'architecture (non bloquantes) :** enchantement (A.4.4), véhicules aériens (E.24), profondeur infinie (3.2/G.2), moddage public (10), consultation à distance des boutiques (E.8), éditeur de contenu visuel (10.1), soutien de prétendants en crise de succession (12.3).

---

# ANNEXES TECHNIQUES

*Les annexes A à D sont des **propositions par défaut** destinées à rendre le GDD directement implémentable. Chaque formule, valeur ou structure est modifiable — elles servent de point de départ concret plutôt que de laisser des trous.*

---

## Annexe A — Formules et valeurs par défaut

### A.1 Progression des compétences (usage, sans plafond)

Toutes les compétences (armes, modules, récolte, artisanat, lecture, dual wielding, bouclier, deux mains, etc.) suivent la même courbe :

```
XP requise pour passer du niveau N au niveau N+1 :
xp_next(N) = base_xp * (N + 1)^1.6
avec base_xp = 100
```

- Niveau 1→2 : ~300 XP ; niveau 10→11 : ~4 600 XP ; niveau 50→51 : ~53 000 XP.
- Chaque usage donne une XP fixe selon l'action (voir A.2 à A.6). Croissance polynomiale (pas exponentielle) : la progression ralentit mais ne devient jamais absurde, cohérent avec "infini à la Elin".
- **Bonus de compétence :** la plupart des formules utilisent `skill_factor(N) = 1 + N * 0.02` (+2 % d'efficacité par niveau, sans plafond).

**Potentiel (voir 6.4) :**
```
xp_effective = xp_gagnée * (potentiel / 100)
À chaque level up de la stat/compétence :
  potentiel = max(potentiel_base, potentiel - (10 + niveau/10))
potentiel_base : par race+classe (C.2/C.3), défaut 80, fourchette 50-130
Sources de potentiel : plats (A.9.1, principal), sommeil (Reposé : +2
  à toutes les stats consommées récemment), entraîneur PNJ (20 or *
  niveau actuel → +10 de potentiel dans une compétence choisie)
Cap : 200. Le potentiel est par-personnage (joueur, PNJ, compagnons).
```

**Niveaux dérivés (voir 6.0) :**
```
niveau_combat  = moyenne des 5 meilleures compétences taguées "combat/survie"
niveau_general = moyenne des 5 meilleures compétences taguées "general"
```
Le tag combat/general est un champ de la définition de chaque compétence (data-driven). "5 meilleures" évite la dilution quand un personnage touche à tout.

### A.2 Récolte

```
temps_recolte (secondes) =
  durete_materiau / (durete_outil * qualite_outil * skill_factor(N_recolte))

quantite_recoltee = 1 + floor(N_recolte / 10)    (chance de +1 par palier de 10 niveaux)
XP gagnée par bloc récolté = durete_materiau
```

- Un matériau est **irrécoltable** si `durete_outil * qualite_outil < durete_materiau * 0.5` (outil trop faible : aucun progrès, feedback visuel "l'outil rebondit") — s'applique aussi aux mains nues (confirmé le 2026-07-19).
- Récolte à mains nues : **équivalente à un outil de dureté 1**, qualité = 1 (confirmé le 2026-07-19 : seuls sable, paille et autres matériaux de dureté ≤ 2 se récoltent sans outil).

### A.3 Qualité d'artisanat

```
qualite_produite = clamp_min(0.1,
    (N_artisanat / (N_artisanat + 25)) * 2 * random(0.85, 1.15))
```

- Asymptote : tend vers ×2.0 pour un artisan très expérimenté, mais `random` permet des pics au-dessus.
- Niveau 25 ≈ qualité ×1.0 en moyenne. Niveau 100 ≈ ×1.6.
- **Dépassement de l'asymptote** : des bonus additifs (station de meilleure qualité, outils spéciaux, buffs, matériaux exotiques) s'ajoutent après la formule — c'est comme ça que "0 → ∞ mais de plus en plus dur" se concrétise : la compétence seule plafonne doucement, les bonus externes repoussent la limite.

**Paliers nommés (par tranches de multiplicateur) :**

| Multiplicateur | Nom |
|---|---|
| 0.1 – 0.49 | Misérable |
| 0.5 – 0.79 | Pauvre |
| 0.8 – 1.19 | Correct |
| 1.2 – 1.59 | Bon |
| 1.6 – 1.99 | Excellent |
| 2.0 – 2.99 | Chef-d'œuvre |
| 3.0 – 4.99 | Légendaire |
| 5.0+ | Mythique |

### A.4 Stats d'un objet crafté/sculpté

```
stat_finale = stat_base_materiaux * qualite_produite

stat_base_materiaux (craft simple) = moyenne pondérée des stats des matériaux
    selon les quantités de la recette
stat_base_materiaux (sculpture)   = moyenne pondérée des stats des matériaux
    selon le nombre de voxels de chaque matériau dans le modèle
```

- La sculpture n'ajoute **aucun bonus de stats** (déjà décidé : la forme est cosmétique) ; elle donne juste un contrôle exact de la pondération via la composition voxel.

### A.4.1 Stats de combat des armes (dégâts, vitesse, portée)

**Principe :** la **fonctionnalité** (choisie au craft/à la sculpture) porte le profil de base ; les **matériaux** modulent via leurs stats existantes (aucune nouvelle stat de matériau nécessaire) ; la **qualité** multiplie.

```
degats  = jet(degats_des(fonctionnalité)) * (durete_BASE_arme / 20) * qualite
          (système à jets de dés : voir E.3 pour la résolution complète.
          durete_BASE = moyenne pondérée des matériaux AVANT qualité, cf. A.4 —
          la qualité n'est appliquée qu'UNE fois, ici ; ne jamais utiliser la
          dureté finale déjà multipliée, ce serait un double comptage)
          (20 = dureté de référence, étalon fer)
vitesse = vitesse_base(fonctionnalité) * (poids_reference / poids_reel)^0.75
          bornée à [0.4, 1.8] * vitesse_base
          (exposant 0.75 au lieu de sqrt : le choix du matériau du
          manche se SENT — pin vs ébène ≈ 25 % d'écart de cadence)
portee  = fixe par fonctionnalité (non modulée par les matériaux)
type_degats = fixe par fonctionnalité (tranchant / perçant / contondant)
```

**Profils de fonctionnalité par défaut** (`data/functionalities/*.json`) :

| Fonctionnalité | Dés de dégâts | Crit | Vitesse (att./10 ticks) | Portée (blocs) | Type |
|---|---|---|---|---|---|
| Dague | 1d6 | 19-20 | 3.0 | 1 | perçant |
| Épée | 2d6 | 20 | 2.0 | 1.5 | tranchant |
| Masse | 3d8 | 20 | 1.2 | 1.5 | contondant |
| Lance | 2d8 | 20 | 1.5 | 2.5 | perçant |
| Hache d'armes | 2d10 | 20 | 1.4 | 1.5 | tranchant |
| Arc | 2d6 | 20 | 1.5 | 25 | perçant |
| Arbalète | 3d6 | 20 | 0.8 | 30 | perçant |
| Bâton magique | 1d4 | 20 | 1.8 | 1 | contondant |

Le résultat du jet est ensuite modulé par matériaux/qualité (formule E.3.3) — les dés remplacent le `degats_base` fixe ; `crit_range` : valeurs naturelles du d20 déclenchant un critique.

- La dureté pilote les dégâts, la densité (poids) pilote la vitesse : granit noir = lent et dévastateur, bois-fer léger = rapide mais mordant modérément.
- Les **dégâts élémentaires viennent des modules** (section 5), jamais de l'arme elle-même.

### A.4.2 Armures et poids porté

```
protection : chaque pièce contribue des DÉS de réduction (mitigation à jet, E.3.4)
  des_piece = 1dX  avec  X = round(durete_BASE * qualite * facteur_slot / 4)
             (min 1d2 ; durete_BASE avant qualité, même règle qu'en A.4.1)
  Exemple : cuirasse fer (durete 25) qualité 1.2, facteur 1.0 → 1d8
facteur_slot : torse 1.0, tête 0.6, jambes 0.7, pieds 0.3, mains 0.3
malus_vitesse_deplacement = f(poids_total_porté / capacite)
    capacite = (30 + Force * 5) * 100 (inclut inventaire ET équipement)
    (amendé le 2026-07-19 : ×100 — l'échelle de poids « densité = poids d'un
    bloc » rendait la capacité initiale inférieure au poids du kit de départ)
```

- Optionnel (à activer si le combat en a besoin) : matrice type de dégâts × matériau d'armure via les tags (contondant efficace contre matériaux rigides, perçant contre souples).

### A.4.3 Durabilité

**Pas de durabilité.** Décision ferme : les objets ne s'usent pas et ne se cassent pas à l'usage — la maintenance d'équipement serait une friction sans intérêt dans un jeu déjà dense. (Les objets restent destructibles par des causes externes : explosions, etc.)

### A.4.4 Effets d'équipement passifs

Un objet porté peut avoir une liste d'**effets passifs** (champ `effects`, schéma B.3), appliqués tant qu'il est équipé. Chaque effet est un modificateur data-driven ciblant :

1. **Stat** : `{"target": "stat", "id": "perception", "add": 2}` (ou `"mult"`)
2. **Compétence** : `{"target": "skill", "id": "meditation", "add": 5}` — niveaux **effectifs** : comptent dans `skill_factor()` et dans toutes les formules (y compris les capacités maximales : mana_max, santé max, capacité de poids), mais ne génèrent pas d'XP et n'entrent PAS dans les niveaux dérivés (6.0).

**Règle de retrait (jauges maximales) :** quand retirer un objet fait baisser un maximum (santé max, mana max...), la valeur **courante** est clampée au nouveau max, avec un **plancher de 1** pour la santé (retirer un anneau de +PV alors qu'on a moins de PV que le bonus laisse à 1 PV, jamais 0 — on ne meurt pas en se déshabillant). Pour la capacité de poids : dépasser la capacité après retrait applique simplement le malus de surcharge (A.4.2), rien n'est jeté.
3. **Mécanique** : `{"target": "mechanic", "id": "faim_vitesse", "mult": 0.8}` — ids de mécaniques exposés par les systèmes (`capacite_poids`, `surchauffe_mult`, `vitesse_deplacement`...)
4. **Tag comportemental** : `{"target": "grant_tag", "id": "detection_filons"}` — le porteur gagne un tag auquel les autres systèmes réagissent (mécanisme le plus puissant, zéro code par objet)

**Règles :** les `add` s'additionnent, les `mult` se multiplient entre tous les objets portés ; la **qualité** de l'objet multiplie les valeurs numériques (`add × qualité`, arrondi). Les objets craftés simples n'ont **pas** d'effets par défaut — les effets apparaissent sur le loot généré (donjons, marchands).

**Extension future — Enchantement :** la Table d'enchantement (C.8) permettra d'ajouter des effets à un objet existant. Non spécifié pour l'instant ; le champ `effects` est conçu pour l'accueillir sans refonte (l'enchantement = ajouter des entrées à la liste, avec coût en matériaux `conducteur_mana` et compétence Enchantement).

### A.4.5 Stats étendues des matériaux : application

Les 13 stats de matériau (4.2) se transmettent aux objets craftés/sculptés par **moyenne pondérée** (quantités de recette ou comptage de voxels — même mécanisme que la dureté, A.4). La **qualité ne les multiplie PAS** : ce sont des propriétés physiques, pas des performances (seule la dureté → dégâts/protection passe par la qualité, via A.4.1/A.4.2).

**Principe d'équilibrage (avec 120+ matériaux) :** la différenciation vient de **profils** (chaque matériau excelle quelque part et paie ailleurs — l'opale règne sur le mana mais casse, le jade tient par son élasticité, le basalte résiste mais conduit), pas d'une inflation générale des échelles ; et les **formules sont calibrées pour que ~30 points d'écart se ressentent en jeu** (~20-25 % d'effet). Les paliers serrés de dureté des roches sont VOULUS (stratification G.9) — ne pas les écarter.

Effets par défaut dans les formules :
```
Coût en mana d'un module (via l'arme tenue) :
  cout_effectif *= (1 - conductivite_mana_arme / 140)   (max ~-65 %)
  (dénominateur réduit : 30 points d'écart entre deux gemmes ≈ 21 %
  de coût — le choix de la gemme du bâton devient structurant)
Dégâts de foudre reçus :
  *= (0.35 + conductivite_electrique_armure / 77)       (0.35x à 1.65x)
  (courbe élargie : l'armure de cuir vs de fer face à un mage foudre
  n'est plus un détail mais un x3 d'écart)
Résistance chaleur/froid (biomes extrêmes, dégâts élémentaires) :
  degats_subis *= (1 - isolation_armure / 125)   (max -80 %)
  (la laine/fourrure en toundra, le saphir contre le feu : décisifs)
Feu : chance d'ignition d'un bloc/objet exposé = flammabilite / 100
  par exposition ; vitesse de combustion proportionnelle
Chute : degats_chute *= (1 - elasticite_bloc_reception / 150)
Arc/arbalète : degats *= (0.8 + elasticite_bois / 250)  (bois élastique = arc puissant)
Véhicule naval : flotte si moyenne pondérée de flottabilite >= 50
Vitesse de déplacement au sol : *= (0.85 + friction_sol * 0.003)
  bornée [0.85, 1.15] (glace 0 = glissade, pavés 100 = +15 %)
Agriculture : rendement_final = rendement_biome (B.6) * (0.5 + fertilite_sol / 100)
Lumière émise par un bloc/objet : niveau = luminosite / 100 * 15
  (échelle de lumière 0-15 ; un objet lumineux porté éclaire mais
  augmente la détection par les ennemis — malus de Discrétion)
Transparence : transparence >= 50 → le bloc laisse passer lumière et
  regard (fenêtres, serres) — impact meshing : passe de rendu séparée
```

### A.5 Mana (calqué Elin)

```
mana_max = 20 + (Volonté * 3) + (N_meditation * 2)
    N_meditation inclut les niveaux effectifs d'équipement (A.4.4) ;
    au retrait d'un objet, le mana courant est clampé au nouveau max
    (règle de retrait A.4.4).
Régénération passive : tous les 10 ticks (≈1 s en temps réel — voir 5.0 et D.2),
    chance de 1/8 de régénérer
    regen = 1 + N_meditation * 0.2 (niveaux effectifs inclus ; l'XP de
    Méditation gagnée à chaque proc est calculée sur le niveau réel)
Repos actif (s'asseoir/camper) : la chance passe à 1/2 par seconde.
Surchauffe : lancer sans mana suffisant est permis ; le déficit est infligé
    en dégâts de santé * 2. La compétence Contrôle du Mana réduit ce
    multiplicateur : 2 / skill_factor(N_controle).
```

### A.5.1 Santé du joueur (ajouté 2026-07-20, validé par l'auteur)

Par analogie avec le mana (A.5, Endurance ~ Volonté) :

```
santé_max = 20 + (Endurance * 8)
```

### A.6 Coût en mana d'une compétence assemblée

```
cout_total = somme des couts des modules équipés dans la compétence
cout_module_effectif = cout_base_module / skill_factor(N_module)
```

Monter un module en niveau le rend plus puissant ET moins coûteux (puissance : `effet_base * skill_factor(N_module)`).

### A.7 Lecture des livres (jet de compétence, cf. E.3)

```
Jet : 1d20 + N_lecture/2 + Perception/4  vs  DD = 10 + difficulte_livre/2
Réussite        → modules_obtenus = max(1, floor(nb_modules_du_livre
                    * min(1, N_lecture / difficulte_livre)))
Réussite de 10+ → tous les modules du livre + bonus d'XP
Échec           → effet mineur (étourdissement 5 s, perte de mana)
Échec de 10+ ou 1 naturel → effet grave (confusion, téléportation,
                    invocation hostile de niveau ≈ difficulté)
XP de lecture = difficulte_livre * 5 (succès) ou * 2 (échec)
Le livre est consommé dans tous les cas (section 5).
```

### A.8 Prix suggéré (commerce)

```
prix_suggere = valeur_base_objet * qualite * facteur_rarete * facteur_reputation
valeur_base_objet = somme(valeur_base des matériaux * quantités) * 1.5 (marge d'artisanat)
facteur_reputation = 1 + (reputation_locale / 200)     (borné à [0.5, 2.0])
```

Les PNJ acceptent d'acheter en boutique passive si `prix_affiché <= prix_suggere * random(0.9, 1.3)` — vendre trop cher ralentit les ventes sans les bloquer totalement.

### A.8.1 Économie : portefeuilles PNJ, taxes, entretien (7.6/14.6)

```
PORTEFEUILLE PNJ (marchands ET clients, règle unifiée) :
  or_max = base(métier) * (1 + rang*0.5)
    base : villageois/client 30, marchand 300, maître de guilde 2000,
    roi 15000 (cohérent avec les niveaux de F.3)
  recharge hebdomadaire : +15 % de or_max (plafonné à or_max)
  Vente du joueur refusée en or au-delà du stock du PNJ → PROPOSITION
    DE TROC automatique : objets de son inventaire ≈ valeur équivalente
    (±15 %), le joueur accepte ou refuse.

TAXES DE GUILDE (hebdomadaire, prélevée automatiquement, DÉTRUITE) :
  taxe = 0.05 * gains_de_quetes_de_la_semaine * rang_guilde_du_joueur
  (rang 1 = x1, rang 5 = x1.4 — les hauts rangs coûtent plus cher
  mais rapportent plus, cf. 7.3)

ENTRETIEN DU ROYAUME (hebdomadaire, prélevé sur le trésor du royaume,
  taux `base_rate` défini par royaume — B.9 — module selon la
  gouvernance : dictature/ploutocratie plus haut, anarchie proche 0
  car pas d'administration à financer) :
  entretien = Σ(10 or / PNJ assigné) + Σ(25 or / structure spéciale
              : station, tourelle, hall de guilde)
  Payé automatiquement si trésor suffisant. Sinon : dette d'entretien
    += manquant ; malus progressifs par palier de dette (14.6) —
    jamais de destruction automatique de structures.
  Trésor du royaume alimenté par les boutiques passives (E.8) du
    territoire, consultable dans l'écran de gestion de claim (E.13).
```

### A.9 Faim

```
Jauge 0–100, départ 100. Baisse de 1 point / 90 s de jeu actif
(pauses et menus exclus). Effets :
  < 50 : -10 % régénération de santé
  < 25 : -10 % à toutes les stats, plus de régén de santé
  = 0  : perte de 1 % de santé max / 30 s
        AMENDÉ 2026-07-27 (décision de l'auteur) : la famine PEUT tuer.
        Le plancher de 1 PV est retiré — mourir de faim déclenche la
        pénalité de mort normale (A.10), jamais un game over.
Manger restaure selon l'aliment (valeur nutritive en données).
```

### A.9.1 Nourriture, potentiel et potions (7.7)

```
PLAT : potentiel_gagné(stat) = Σ bonus_ingredients(stat)
         * (nutrition_totale / 100) * qualite_plat (A.3)
  répartis à la consommation ; nutrition remplit la faim (A.9).
VIANDE (paramétrique) : bonus_potentiel(stat) =
         stat_source_creature / 10  (arrondi, max 8 par stat)
  ex. ours brun For 14 → viande : +1.4 → +1 potentiel Force par unité
  cuisinée dans un plat (multiplié par nutrition/qualité).
CRU : manger cru = 50 % de la nutrition, aucun bonus de potentiel,
  risque d'infection (F.5) — cuisiner est toujours mieux.
POTION : intensité = effet_base * qualite_potion (A.3, Alchimie)
         durée = durée_base * (0.5 + qualite_potion / 2)
  1 potion active max par famille d'effet (pas d'empilement de
  potions de Force) ; les potions passent par les statuts (F.4)
  et le résolveur de modificateurs (E.4) — zéro système nouveau.
```

### A.10 Mort et pénalité

```
À la mort : respawn au dernier lit/claim activé.
Pénalité : -10 % de l'or transporté, chaque objet de l'inventaire a 10 % de
chance de tomber au sol sur le lieu de mort (récupérable pendant 1 jour in-game).
Équipement porté : conservé. XP de compétences : aucune perte (la progression
usage-based rend la perte d'XP très punitive, on pénalise l'économie à la place).
```

*(Alternative plus dure à tester en playtest : perte de 5 % de l'XP du niveau en cours sur les 3 compétences les plus hautes.)*

### A.11 Explosions

```
Une explosion a : puissance P, rayon R (en blocs).
Pour chaque bloc dans R : détruit si durete_bloc < P * (1 - distance/R).
La subdivision est respectée : chaque sous-bloc est testé individuellement
(un bloc 16px non subdivisé est testé une fois ; des sous-blocs 4px sont
testés chacun). Les blocs détruits droppent leur matériau avec 50 % de perte.
```

---

## Annexe B — Schémas de données (JSON)

Convention : fichiers dans `data/`, un fichier par type de contenu, encodage UTF-8. IDs en `snake_case`, uniques par type. Les tags pilotent les interactions inter-systèmes (voir section 10).

### B.1 Matériau — `data/materials/<categorie>/*.json`

*Amendé le 2026-07-19 : les fichiers matériaux sont rangés dans des sous-dossiers par catégorie (`data/materials/bois/chene.json`, `data/materials/roche/granit.json`...) — lisibilité à 200+ matériaux. GameData charge récursivement et avertit si le dossier ne correspond pas au champ `category`.*

```json
{
  "id": "chene",
  "name_key": "material.chene.name",
  "category": "bois",
  "stats": {
    "durete": 12, "densite": 6, "valeur_base": 4,
    "conductivite_mana": 10, "flammabilite": 60, "isolation": 35,
    "conductivite_electrique": 5, "flottabilite": 80, "luminosite": 0,
    "fertilite": 0, "transparence": 0, "elasticite": 25, "friction": 45
  },
  "tags": ["organique"],
  "color": "#8B5A2B",
  "noise": {
    "type": "procedural",
    "seed_offset": 101,
    "amplitude": 0.08,
    "scale": 4
  },
  "harvest": {
    "tool_category": "hache",
    "skill": "bucheronnage"
  },
  "world_gen": {
    "mode": "biome",
    "biome_tags": ["foret", "tempere"]
  }
}
```

- `world_gen.mode` : `"biome"` (découle du biome) ou `"noise_layer"` (couche de bruit dédiée, avec `noise_layer_id` et seuils).
- `noise.type` : `"procedural"` ou `"texture"` (matériaux spéciaux, avec `texture_path`).
- **Matériaux paramétriques** : certains matériaux sont des **gabarits instanciés depuis une source** plutôt que des entrées fixes — `"parametric": {"source": "creature"|"tree"}`. Ex. : *Viande de X*, *Peau de X*, *Os de X* (stats/bonus dérivés de la créature source, B.5), *Feuilles de X*, *Pousse de X* (couleur/stats dérivées de l'essence, F.1). Une seule définition couvre toutes les variantes — les 40 essences ont leurs feuilles sans 40 entrées ; la couleur d'une variante = couleur de la source décalée déterministiquement (pas de collision avec la palette F.1.1, vérifiée au boot).
- **`color` : couleur UNIQUE par matériau** (obligatoire). GameData valide au boot qu'aucune couleur n'est dupliquée dans tout le catalogue ET qu'aucune n'entre en collision avec les couleurs réservées (stand-in matériaux + marqueurs d'attache, `data/reserved_colors.json`, 12.1) — un doublon = erreur bloquante de données. Deux matériaux visuellement proches (ex : pin/sapin) se distinguent par un écart minimal de teinte/valeur + leurs paramètres de bruit (`noise`) : la texture différencie ce que la couleur seule ne suffit pas à séparer. La palette complète de départ est en F.1.1.
- **Tags dérivés automatiquement** des stats par seuils (>= 50) : `flammabilite` → `inflammable`, `conductivite_mana` → `conducteur_mana`, `flottabilite` → `flottant`, `isolation` → `isolant`, `luminosite` → `luminescent`, `transparence` → `transparent`, `conductivite_electrique` → `conducteur`. Les systèmes à tags (section 10) réagissent aux tags ; les formules fines utilisent la valeur graduée. Seuls les tags non dérivables (ex : `organique`, `corrompu`) sont déclarés à la main.

### B.2 Catégorie de matériau — `data/material_categories.json`

*11 catégories, alignées sur la décision 4.2 et les familles de F.1 (amendé le 2026-07-19 : ajout de `mineral`, `fossile`, `meteorologique` ; l'id `cristal` couvre la catégorie « gemme/cristal »).*

```json
{
  "bois":           { "tool": "hache",   "harvest_skill": "bucheronnage", "station_transform": "scierie" },
  "minerai":        { "tool": "pioche",  "harvest_skill": "minage",       "station_transform": "forge" },
  "roche":          { "tool": "pioche",  "harvest_skill": "minage",       "station_transform": "tailleur_pierre" },
  "terre":          { "tool": "pelle",   "harvest_skill": "terrassement", "station_transform": null },
  "vegetal":        { "tool": "faucille","harvest_skill": "herboristerie","station_transform": "atelier_tissage" },
  "liquide":        { "tool": "seau",    "harvest_skill": "collecte",     "station_transform": "alambic" },
  "mineral":        { "tool": "pioche",  "harvest_skill": "minage",       "station_transform": "alambic" },
  "fossile":        { "tool": "pioche",  "harvest_skill": "minage",       "station_transform": "tailleur_pierre" },
  "cristal":        { "tool": "pioche",  "harvest_skill": "minage",       "station_transform": "table_enchantement" },
  "meteorologique": { "tool": "pelle",   "harvest_skill": "terrassement", "station_transform": null },
  "synthetique":    { "tool": null,      "harvest_skill": null,           "station_transform": "atelier" }
}
```

### B.3 Objet / recette — `data/items/*.json`

```json
{
  "id": "pioche",
  "name_key": "item.pioche.name",
  "type": "outil",
  "equip_slot": "arme",
  "hands": 1,
  "functionality": "recolte_minage",
  "recipe": {
    "station": "etabli",
    "craft_skill": "menuiserie",
    "inputs": [
      { "category": "bois",    "amount": 2 },
      { "category": "minerai", "amount": 3 }
    ]
  },
  "stat_weights": { "durete": { "minerai": 0.8, "bois": 0.2 } },
  "vox_model": "models/tools/pioche.vox",
  "vox_slots": { "#00FF00": "bois", "#FF00FF": "minerai" },
  "effects": [],
  "tags": ["outil", "recolte"]
}
```

- `vox_slots` : mapping couleur stand-in → catégorie de matériau (technique 9.1).
- `effects` : liste d'effets passifs (voir A.4.4) — vide pour les objets craftés, remplie sur le loot généré.
- Un objet sculpté par le joueur génère une entrée du même format, stockée dans la sauvegarde, avec `vox_model` pointant vers le modèle sauvegardé et `stat_weights` calculé depuis la composition voxel.

### B.3.1 Fonctionnalité — `data/functionalities/*.json`

Profil mécanique porté par la fonctionnalité d'un objet (référencée par le champ `functionality` de B.3, et choisie à la table de sculpture — section 13). Utilisé par les formules A.4.1/A.4.2.

```json
{
  "id": "epee",
  "name_key": "functionality.epee.name",
  "kind": "arme",
  "hands": 1,
  "combat_skill": "epee",
  "degats_des": "2d6",
  "crit_range": 20,
  "vitesse_base": 2.0,
  "portee": 1.5,
  "type_degats": "tranchant",
  "poids_reference": 40
}
```

Pour une armure : `"kind": "armure"`, avec `"equip_slot"` et `"facteur_slot"` à la place des champs d'attaque. Pour un meuble/objet non combattant : `"kind": "mobilier"` etc., sans champs de combat.

### B.4 Module de compétence — `data/modules/*.json`

```json
{
  "id": "projectile_feu",
  "name_key": "module.projectile_feu.name",
  "module_type": "effet",
  "mana_cost_base": 8,
  "power_base": 12,
  "tags": ["feu", "projectile"],
  "params": { "vitesse": 20, "portee": 30 },
  "grimoire_domains": ["feu", "destruction"],
  "book_type": "grimoire"
}
```

- `module_type` : `"effet"` (produit quelque chose), `"modificateur"` (altère le module suivant, façon Noita : multi-cast, rebond, homing...), `"declencheur"` (trigger sur impact/timer).
- `book_type` : `"grimoire"` (sorts) ou `"manuel"` (armes).

### B.5 Créature / PNJ — `data/creatures/*.json`

```json
{
  "id": "villageois_humain",
  "name_key": "creature.villageois_humain.name",
  "skeleton_template": "humanoide",
  "parts_pool": {
    "tete":  [1, 4, 18, 32],
    "torse": [1, 42],
    "bras":  [1, 3],
    "jambes": [6, 7]
  },
  "race": "humain",
  "base_stats": { "sante": 40, "force": 8, "volonte": 6, "vitesse": 10 },
  "equip_slots": "humanoide_standard",
  "inventory_table": "loot_villageois",
  "ai_profile": "civil",
  "jobs_compatible": ["fermier", "vendeur", "garde"],
  "housing_default": "normal",
  "recruitable": { "method": "relation", "threshold": 60 },
  "leadership_role": null,
  "succession_rule": null,
  "rare_chance": 0.02,
  "tags": ["humanoide", "civil", "commerce_possible"]
}
```

- `model` (ajouté 2026-07-26) : chemin du modèle **Blockbench** exporté (glTF/`.glb`) de la créature — voir 12.1. `parts_pool` devient facultatif et n'est plus utilisé pour l'assemblage.
- `recruitable.method` : `"relation"` (seuil), `"dressage"` (jet de compétence), `"quete"` (id de gabarit), ou `"jamais"`.
- `jobs_compatible` : postes de travail assignables (section 14.2) ; `housing_default` : statut de logement initial (7.5), modifiable par le joueur (y compris → `"betail"`).
- `leadership_role` (instance uniquement, ex. `"roi_royaume_x"`, `"maitre_guilde_guerriers"`) et `succession_rule` (`"heir"` ou `"next_in_rank"`, section 12.3) : définis sur les PNJ uniques, `null` pour la population générique.
- Liens familiaux (instance) : `"family": {"parent_of": [...], "child_of": "...", "spouse": "..."}` — pilote la succession (12.3) et la démographie (12.2).
- `rare_chance` (0 pour civils/uniques/bétail) : système de variantes rares (12.4).
- **Identité (instance, humanoïdes civils/uniques uniquement) :** `"prenom"`, `"nom_famille"`, `"titre"` (optionnel, PNJ à `leadership_role`) — générés à l'instanciation par le système de noms culturels (12.5/E.31), jamais pour les bêtes/monstres (une variante rare garde son épithète, 12.4, pas un nom propre).
- Un monstre utilise exactement le même schéma (`ai_profile: "hostile"`, `recruitable.method: "dressage"`...). Son bloc `combat` porte `durete_naturelle` (dureté de l'« arme » naturelle, défaut 10 = étalon demi-fer A.4.1) — entre dans la formule de dégâts E.3 comme la dureté de base d'une arme craftée (ajouté 2026-07-21, remplace une valeur en dur).
- Les PNJ ont leurs propres compétences qui **progressent à l'usage comme le joueur** (instance ≠ définition : l'état courant des skills vit dans la sauvegarde).

### B.6 Biome — `data/biomes/*.json`

```json
{
  "id": "foret_de_mana",
  "name_key": "biome.foret_de_mana.name",
  "conditions": {
    "altitude":    [0.3, 0.6],
    "temperature": [0.4, 0.7],
    "humidite":    [0.5, 1.0],
    "mana":        [0.7, 1.0]
  },
  "priority": 5,
  "surface_material": "terre_fertile",
  "subsurface_material": "terre",
  "vegetation": [
    { "id": "if", "density": 0.05 },
    { "id": "champignon", "density": 0.02 }
  ],
  "village_palette": { "mur": "chene", "toit": "chaume_tresse", "sol": "calcaire" },
  "poi_weights": { "sanctuaire": 3, "donjon": 1, "camp": 1 },
  "farming_yield": 1.2,
  "tags": ["magique", "foret"]
}
```

- Résolution : pour chaque colonne du monde, le biome retenu est celui dont toutes les `conditions` matchent les valeurs de bruit, à la `priority` la plus haute (les biomes rares/spécifiques ont une priorité haute, les génériques une basse).
- **`temperature` (2026-07-20) :** n'est plus un bruit indépendant — c'est désormais la **bande de latitude** du monde (0 = pôle, 1 = équateur), perturbée localement par du bruit et réduite par l'altitude (E.2). Les plages `conditions.temperature` des biomes existants restent valides sans changement (même échelle 0..1), seule la MANIÈRE dont la valeur est calculée a changé.
- **`plantes_sol` (optionnel, ajouté en cours de projet) :** même forme que `vegetation` (`[{"material_id", "density"}]`) mais pour du décor bas niveau (herbe, fleurs, buissons, fougères) posé en un seul bloc plutôt qu'une structure 3D complète (TreeGenerator) — densité en probabilité par bloc, comme `vegetation`.

### B.7 Gabarit de quête — `data/quest_templates/*.json`

```json
{
  "id": "chasse_prime",
  "guild": "guerriers",
  "rank_min": 1,
  "pattern": "tuer",
  "target_selector": { "tags_any": ["hostile"], "combat_level_range_around_player": [0.8, 1.2] },
  "count_range": [3, 8],
  "reward": { "gold_per_target_level": 15, "guild_xp": 10 },
  "text_key": "quest.chasse_prime.text"
}
```

- `text_key` pointe vers un gabarit localisé avec placeholders (ex : fr = "Éliminez {count} {target} près de {location}.") — une version par langue dans `locale/` (voir 10.1). Les valeurs `{target}`/`{location}` sont elles-mêmes résolues via les `name_key` des entités concernées.
- **Pattern `"donjon"`** (7.3/3.5) : `target_selector` référence un donjon POI généré à proximité plutôt qu'un type de créature — objectif "atteindre l'étage le plus profond" ou "vaincre le boss" (`dungeon_cleared` sur l'EventBus valide la quête automatiquement).

### B.8 Couches de bruit — `data/noise_layers.json`

```json
{
  "altitude":    { "type": "fbm",     "octaves": 5, "frequency": 0.0008, "seed_offset": 1 },
  "temperature": { "type": "simplex", "octaves": 3, "frequency": 0.0005, "seed_offset": 2 },
  "humidite":    { "type": "simplex", "octaves": 3, "frequency": 0.0005, "seed_offset": 3 },
  "mana":        { "type": "simplex", "octaves": 4, "frequency": 0.0012, "seed_offset": 4 },
  "danger":      { "type": "simplex", "octaves": 2, "frequency": 0.0004, "seed_offset": 5 },
  "vegetation":  { "type": "simplex", "octaves": 3, "frequency": 0.002,  "seed_offset": 6 },
  "sismique":    { "type": "simplex", "octaves": 2, "frequency": 0.0006, "seed_offset": 7 },
  "ressources":  { "type": "fbm",     "octaves": 4, "frequency": 0.003,  "seed_offset": 8 }
}
```

**Note (2026-07-20) :** la couche "température" n'est plus le signal primaire du climat — voir 3.0/B.6, elle sert désormais de perturbation locale à une bande de latitude calculée par fonction pure (pas de bruit). La couche "ressources" sert maintenant à deux usages : la distribution des minerais (prévu, non encore implémenté) ET, en profondeur, un proxy de "veine de charbon" pour le placement du grisou (E.2.5) — aucune nouvelle couche de bruit n'a été ajoutée (les 8 couches B.8 restent fixes), les composantes supplémentaires (orogenèse, karst, rivières) sont des champs de bruit INTERNES au générateur, hors du schéma de données B.8, au même titre que le domain warping et le bruit ridged déjà en place.

Toutes dérivées d'une seed monde unique + `seed_offset` (reproductibilité totale).

### B.9 Royaume — `data/kingdoms/*.json`

```json
{
  "id": "royaume_x",
  "name_key": "kingdom.royaume_x.name",
  "government_type": "monarchie_hereditaire",
  "culture": "culture_nordique",
  "capital_poi": "ville_x_capitale",
  "territory_cells": [[14,-3], [14,-4], [15,-3]],
  "taxes": { "base_rate": 0.08, "tariff_default": 0.10 },
  "tariffs": { "gemmes": 0.35, "houille": 0.02, "artefacts": 0.50 },
  "laws": [
    { "id": "loi_meurtre", "type": "comportement", "target": "meurtre",
      "status": "illegal", "consequence": "gardes_hostiles" },
    { "id": "loi_vol", "type": "comportement", "target": "vol",
      "status": "illegal", "consequence": "amende:50" },
    { "id": "loi_pomme", "type": "objet", "target": "pomme",
      "status": "illegal", "consequence": "confiscation" }
  ],
  "diplomacy": { "royaume_y": "hostile", "royaume_z": "allie" },
  "tags": ["cotier", "commercant"]
}
```

- `government_type` (12.3/14.4) : `monarchie_hereditaire`, `republique_elue`, `theocratie`, `ploutocratie`, `dictature_militaire`, `anarchie` (ce dernier : pas de `capital_poi`/leadership requis, `laws` typiquement vide ou réduite).
- `culture` (schéma B.11, 12.5/E.31) : pilote la génération des noms de PNJ, de villes, et les titres des rôles de leadership — axe **indépendant** de la race dominante (une race peut porter plusieurs cultures possibles, avec des affinités de tirage).
- `laws[].consequence` : `"gardes_hostiles"`, `"amende:N"`, `"confiscation"`, ou combinaison — résolu par le système de détection d'infraction (E.26).
- `tariffs` : surcharge par catégorie de matériau (B.1) au-delà de `tariff_default` ; une valeur de `1.0`+ équivaut à une interdiction totale d'import/export (invendable/impossible de faire entrer le bien).
- `territory_cells` : dérivé dynamiquement des claims/conquêtes (3.3/3.4), pas saisi à la main pour les royaumes générés.

### B.10 Salle/connecteur de donjon — `data/dungeon_rooms/*.json`, `data/dungeon_connectors/*.json`

```json
{
  "id": "salle_ronde_moyenne",
  "kind": "salle",
  "size_category": "moyenne",
  "floor_theme": ["ruine", "crypte"],
  "vox_model": "models/dungeon/rooms/salle_ronde_moyenne.vox",
  "flat_floor": false,
  "connectors": [
    { "type": "porte", "position": [0, 0, 8], "direction": "nord" },
    { "type": "porte", "position": [8, 0, 0], "direction": "est" }
  ],
  "special_tags": ["boss_room_eligible", "treasure_eligible"],
  "vox_slots": { "#00FF00": "roche", "#FF00FF": "minerai" }
}
```

```json
{
  "id": "escalier_descendant",
  "kind": "connecteur",
  "type": "escalier",
  "vertical_offset": -16,
  "vox_model": "models/dungeon/connectors/escalier_descendant.vox",
  "connectors": [
    { "type": "cage_escalier_haut", "position": [0, 0, 0] },
    { "type": "cage_escalier_bas", "position": [0, -16, 0] }
  ]
}
```

- `connectors[].type` doit correspondre entre une salle et le connecteur qui s'y attache (ex. `porte` ↔ `porte`, `cage_escalier_haut` ↔ `cage_escalier_bas`) — résolution par l'algorithme E.29.
- `special_tags` piloté la sélection lors du peuplement (`boss_room_eligible`, `treasure_eligible`, `entree` réservé à la salle de départ).
- Réutilise exactement le pipeline `.vox` existant : couleurs stand-in de matériaux (9.1) + marqueurs d'attache (12.1), aucune nouvelle technique d'import.

### B.11 Culture de nommage — `data/name_cultures/*.json`

```json
{
  "id": "culture_sino",
  "name_key": "culture.sino.name",
  "name_order": "nom_prenom",
  "race_affinity": { "humain": 1.0 },
  "prenom_a": ["Li", "Wang", "Zh", "Xi", "Mei", "Jian", "Hu", "Chen"],
  "prenom_b": ["ang", "ei", "ong", "an", "ing", "ao", "un"],
  "famille_a": ["Li", "Wang", "Zhang", "Chen", "Liu", "Yang", "Huang"],
  "famille_b": [""],
  "ville_a": ["Bei", "Nan", "Shang", "Hang", "Chang", "Guang"],
  "ville_b": ["jing", "hai", "zhou", "yang", "an", "sha"],
  "titres": {
    "monarchie_hereditaire": { "m": "Empereur", "f": "Impératrice" },
    "republique_elue": { "m": "Premier Ministre", "f": "Première Ministre" },
    "theocratie": { "m": "Grand Prêtre", "f": "Grande Prêtresse" },
    "ploutocratie": { "m": "Négociant en Chef", "f": "Négociante en Chef" },
    "dictature_militaire": { "m": "Généralissime", "f": "Généralissime" },
    "guilde_maitre": { "m": "Grand Maître", "f": "Grande Maîtresse" }
  }
}
```

- `prenom_a/b`, `famille_a/b`, `ville_a/b` : pools de la partie A et B, concaténées (E.31). `famille_b: [""]` (chaîne vide) = culture à noms de famille "pleins" plutôt que composés (comme le sino ci-dessus) ; la plupart des autres cultures ont un vrai suffixe.
- `race_affinity` : poids de tirage par race à la génération d'un royaume (E.27) ; les races absentes ont un poids 0 (jamais tirées pour elles). Les cultures dédiées aux races originales (Sylvide, Cendreux, Échomorphe) n'ont qu'une seule entrée à 1.0 et rien d'autre.
- `titres` : une entrée par type de gouvernance (B.9) + `guilde_maitre` (utilisé indépendamment du royaume, pour tout maître de guilde, 7.3) ; genré `m`/`f` selon le PNJ.

---

## Annexe C — Listes de contenu de départ

*Volumes volontairement réduits pour un dev solo : mieux vaut 6 races finies que 15 prévues.*

### C.1 Stats de personnage (création + progression)

| Stat | Effet principal |
|---|---|
| Force | Dégâts mêlée, poids transportable |
| Dextérité | Vitesse d'attaque, précision |
| Endurance | Santé max, résistance |
| Volonté | Mana max, résistance mentale |
| Perception | Détection (POI, minerais), portée |
| Charisme | Prix, relations PNJ |

Création : 30 points à répartir (base 5 par stat, max 15 à la création), + choix de race, classe, apparence (parties du corps, section 12).

### C.2 Races de départ (6)

| Race | Type | Bonus |
|---|---|---|
| Humain | Classique | +10 % XP de compétences (polyvalent) |
| Elfe | Classique | +2 Volonté, +1 Perception, régén mana +20 % |
| Nain | Classique | +2 Endurance, +1 Force, minage/forge +15 % |
| Sylvide | Original — peuple des forêts de mana | Photosynthèse (faim ralentie de moitié le jour), affinité végétale |
| Cendreux | Original — né des zones volcaniques | Immunisé aux dégâts de chaleur mineurs, +15 % forge |
| Échomorphe | Original — créature du bruit, mimétique | Peut changer ses parties de corps (section 12) à volonté, -10 % XP |

### C.3 Classes de départ (6)

| Classe | Kit (stats + équipement + compétences de départ) |
|---|---|
| Guerrier | +2 For/+1 End ; épée fer, bouclier bois ; niv. 5 en Épée, Bouclier |
| Mage | +2 Vol/+1 Per ; bâton, 1 grimoire simple ; niv. 5 en Magie, Méditation, 3 modules de base |
| Artisan | +2 Dex/+1 For ; outils complets qualité Correct ; niv. 5 en 2 métiers au choix |
| Chasseur | +2 Dex/+1 Per ; arc, 20 flèches ; niv. 5 en Arc, Dressage |
| Marchand | +2 Cha/+1 Per ; 500 or, étal portatif ; niv. 5 en Négociation, Lecture |
| Vagabond | +1 partout ; rien ; +15 points de création en plus |

**Potentiels de base (6.4/A.1.1) :** chaque race ET chaque classe définit ses potentiels de base par stat et par familles de compétences (champ `base_potentials` en données) — ex. Nain : Forge/Minage 120, Magie 60 ; Mage : domaines de magie 120, armes lourdes 60. Les valeurs complètes vivent dans `data/races/` et `data/classes/` (défaut 80 partout où non spécifié).

### C.4 Compétences (liste de départ, ~30)

- **Armes :** Épée, Hache d'armes, Masse, Lance, Dague, Arc, Arbalète, Bâton magique, Mains nues, Bouclier, Dual Wielding, Deux Mains
- **Magie :** Méditation (régén mana), Contrôle du Mana (surchauffe), + 1 compétence par domaine de grimoire (voir C.6)
- **Récolte :** Minage, Bûcheronnage, Terrassement, Herboristerie, Collecte
- **Artisanat :** Forge, Menuiserie, Taille de pierre, Tissage, Alchimie, Cuisine, Enchantement
- **Vie :** Lecture, Négociation, Dressage, **Leadership** (capacité d'escorte, E.17), Agriculture, Élevage, Discrétion, Athlétisme (course/saut/nage)

### C.5 Stats des matériaux

Les 13 stats (voir 4.2 et A.4.5) : `durete`, `densite`, `valeur_base`, `conductivite_mana`, `flammabilite`, `isolation`, `conductivite_electrique`, `flottabilite`, `luminosite`, `fertilite`, `transparence`, `elasticite`, `friction`. Tags dérivés par seuils (B.1) + tags manuels : `organique`, `corrompu`.

### C.6 Domaines de grimoires (8) et manuels (4)

- **Grimoires :** Feu, Eau/Glace, Foudre, Terre, Vie (soin/nature), Arcane (pur mana, projectiles/boucliers), Espace (téléport, portée), Corruption (dégâts sur soi pour puissance — lié à la couche danger)
- **Manuels :** Frappes (effets d'attaque), Postures (buffs de maniement), Techniques (mobilité, contres), Maîtrise (modificateurs : multi-coups, portée...)

### C.7 Biomes de départ (17 implémentés au 2026-07-20, extensibles vers 20+)

Plaine tempérée, Forêt tempérée, Forêt mixte, Forêt de mana*, Désert aride, Désert rocheux, Désert de cendres* (volcanique, à faire), Toundra, Taïga, Steppe, Marécage, Marécage corrompu* (à faire), Montagne, Montagne cristalline* (mana+ressources), Calotte glaciaire, Côte/plage, Méditerranéen, Savane, Jungle tropicale. (* = biomes "spéciaux" à conditions multi-couches et priorité haute.)

Réalisme climatique (2026-07-20, 3.0/E.2) : chaque biome réel de la Terre a désormais son créneau logique dans la matrice latitude/altitude/humidité — calotte glaciaire aux latitudes extrêmes (toute altitude/humidité), toundra/taïga aux latitudes froides, steppe (froide et sèche) et forêt mixte (froide-tempérée, humide) en transition vers les biomes tempérés, désert aride (sable, plat) et désert rocheux (mesas/collines, priorité plus haute pour trancher le chevauchement d'altitude) aux latitudes chaudes et sèches, savane/jungle tropicale/méditerranéen aux latitudes chaudes selon l'humidité.

### C.8 Stations de transformation (8)

Établi (générique), Forge, Scierie, Tailleur de pierre, Atelier de tissage, Alambic, Cuisine, Table d'enchantement — plus les 5 tables de sculpture (items, armes, blocs, meubles, véhicules), qui se débloquent uniquement via les rangs de guilde (voir section 13).

### C.9 Cultures de nommage (10, schéma B.11)

*Purement phonétique/toponymique — aucune donnée de gameplay différenciée par culture au-delà des pools de noms et titres. Affinité de race entre parenthèses.*

Latine/romane (Humain) · Nordique/germanique (Nain, Humain) · Sino (Humain) · Nipponne (Humain) · Slave (Humain) · Arabo-berbère (Humain) · Celte (Elfe, Humain) · Sylvestre — sonorités végétales/fluides dédiées (Sylvide exclusivement) · Ignée — consonnes dures, sonorités volcaniques dédiées (Cendreux exclusivement) · Résonance — syllabes fragmentées/répétées, sonorité artificielle dédiée (Échomorphe exclusivement, cohérent avec sa nature mimétique du bruit, 12/section race).

---

## Annexe D — Architecture Godot proposée

*Godot 4.x, langage principal GDScript (itération rapide), C# ou GDExtension/Rust en option ciblée pour le meshing voxel si les performances l'exigent (à profiler d'abord).*

### D.1 Arborescence du projet

```
res://
├── autoload/            # Singletons globaux
│   ├── GameData.gd      # Charge et indexe tout data/ au démarrage
│   ├── WorldManager.gd  # Seed, couches de bruit, streaming de chunks
│   ├── SaveManager.gd   # Sauvegarde différentielle
│   ├── NetworkManager.gd# Host/join, RPC haut niveau
│   └── EventBus.gd      # Signaux globaux inter-systèmes
├── data/                # TOUT le contenu (JSON) — voir Annexe B
│   ├── materials/  ├── items/  ├── modules/  ├── creatures/
│   ├── biomes/     ├── quest_templates/  └── ...
├── systems/             # Logique pure, sans scène
│   ├── voxel/           # Chunks, meshing, subdivision (octree par bloc)
│   ├── worldgen/        # Évaluation des couches de bruit, biomes, POI
│   ├── crafting/        # Recettes, qualité, stations
│   ├── combat/          # Résolution des modules, mana, dégâts
│   ├── skills/          # XP par usage, skill_factor
│   ├── economy/         # Prix, boutiques passives, abstraction hors-site
│   └── reputation/
├── scenes/
│   ├── world/           # Monde voxel, chunk.tscn
│   ├── entities/        # creature.tscn (générique !), player.tscn
│   ├── ui/              # Inventaire, craft, carte du monde, sculpture
│   └── main.tscn
├── locale/              # Traductions : fr.csv, en.csv... (voir 10.1)
├── models/              # .vox sources : blocs, meubles, items, structures
│                        # (importés par script custom)
├── models/creatures/    # .glb Blockbench : créatures et PNJ (import natif)
└── addons/
```

### D.2 Décisions d'architecture clés

- **Simulation à ticks (décision fondamentale, voir 5.0)** : un `TickManager` (dans WorldManager ou autoload dédié) est la seule source d'avancement du temps de jeu. En temps réel, il émet des ticks à fréquence fixe (ex : 10 ticks/s) ; en mode tactique, il n'émet que lorsqu'une action de joueur consomme du temps. Tous les systèmes (combat, mana A.5, faim A.9, IA, croissance des cultures, timers de régénération 3.3) s'abonnent aux ticks et n'utilisent JAMAIS `_process(delta)` pour la logique de jeu — delta reste réservé au purement visuel (animations, interpolation, particules). En multi, le host est l'autorité des ticks et les diffuse.
- **Une seule scène `creature.tscn`** pour tout être vivant (section 12) : elle se configure entièrement depuis un JSON de créature au spawn (parties .vox, stats, IA). Ne jamais créer une scène par type de monstre.
- **GameData** charge tous les JSON au boot, valide les schémas (champs manquants → erreur claire en console), et expose des dictionnaires indexés par id. Hot-reload en debug (touche F5 recharge les données sans relancer) — crucial pour itérer sur le contenu.
- **EventBus** : les systèmes communiquent par signaux (`block_destroyed`, `item_crafted`, `creature_killed`, `skill_xp_gained`...). Le système de quêtes écoute `creature_killed` sans que le combat connaisse les quêtes — c'est l'interaction inter-systèmes voulue en section 10.
- **Voxels : chunks cubiques de 16×16×16 blocs, indexés en 3D `(x, y, z)` dès le premier jour** (jamais en `(x, z)` + pile fixe — coût quasi nul maintenant, retrofit pénible plus tard). La cellule-monde de 128×128 = 8×8 chunks horizontaux × 32 en hauteur par défaut. Le streaming charge une bulle de chunks autour du joueur ; la hauteur 512 est une borne de design que le streaming peut ignorer si un mode profondeur infinie est activé (voir 3.2). Chaque bloc est soit plein (1 id matériau, 2 octets), soit accompagné d'une structure de subdivision séparée (amendé 2026-07-21 : **grille plate 8×8×8**, pas un octree — voir G.2 ; seule une minorité de blocs sont subdivisés — **budget de 512 blocs subdivisés par chunk**, voir G.2). Meshing par greedy meshing, uniquement les faces visibles, avec **LOD de distance** : la subdivision fine n'est jamais meshée au loin (G.2).
- **Import des créatures (amendé 2026-07-26) :** modèles **Blockbench** exportés en glTF/`.glb`, importés nativement par Godot (maillage + squelette + animations). Aucun importeur custom n'est nécessaire ; la recoloration (12.4/F.3) se fait en shader sur la texture atlas. Le point d'attache d'un équipement visible est un **os nommé** du rig.
- **Import .vox (blocs, meubles, items, structures) :** script d'import custom (EditorImportPlugin) qui lit le format .vox directement et produit une ressource `VoxModel` conservant `positions + index de couleur`, et détectant les **voxels-marqueurs de couleurs réservées** (section 12.1) : ils sont retirés du mesh visible et exportés comme liste de points d'attache typés `{type, position, direction}`. Le remapping des couleurs stand-in matériaux se fait dans un shader (palette 256 entrées passée en uniform/texture 256×1). Les couleurs réservées (attaches + stand-in matériaux) sont centralisées dans `data/reserved_colors.json`.
- **Sauvegarde différentielle :** le monde n'est jamais sauvegardé entièrement ; seuls les chunks modifiés par rapport à la génération (diff) + les entités + l'état abstrait des claims sont écrits. Un chunk sauvegardé stocke `seed + liste des modifications`.
- **Réseau :** API haut niveau Godot (`MultiplayerAPI`, RPC). Le host est autoritaire. Les modifications voxel sont des RPC fiables (`place_block`, `destroy_block`) ; positions des entités en unreliable à 10-20 Hz. Prévoir dès le début que toute mutation du monde passe par une fonction unique (facile à router en réseau plus tard, même si le multi arrive après le MVP).
- **Temps :** horloge de jeu centrale dans WorldManager (jour/nuit, semaine in-game pour la régénération des cases sauvages, timers d'abstraction hors-site).

### D.3 Ordre de construction conseillé (aligné MVP, section 15)

1. GameData + 3 JSON de matériaux → afficher un chunk plat texturé par bruit. **Dès cette étape : pipeline de localisation en place (clés `name_key`, `locale/fr.csv` + `locale/en.csv`, validation des clés au boot) — aucune string affichable en dur, jamais.**
2. Génération par couches (altitude/temp/humidité) + 4 biomes → monde continu streamé.
3. Casser/poser des blocs, récolte avec XP, inventaire.
4. Subdivision (2 niveaux d'abord : 16 et 8 px — chaîne 32→16→8→4, amendée 2026-07-19).
5. Import .vox + remapping palette → premier outil crafté visible en main.
6. Une créature générique data-driven + combat minimal (1 arme, 3 modules, mana).
7. Carte du monde + voyage rapide + claim d'une case + minimap (E.30).
8. Premier donjon (E.29) : 2-3 salles/connecteurs prefabs, un étage,
   validation du pipeline complet (génération → boss → disparition).
9. Le reste (sculpture, guildes, boutiques, réseau) par itérations.


---

## Annexe E — Spécifications d'intégration technique

*Cette annexe précise le fonctionnement interne et l'articulation des systèmes, résolvant les questions techniques laissées ouvertes. Comme A-D : propositions par défaut, amendables.*

### E.1 Boucle de tick (cœur du jeu)

```
Fréquence : 10 ticks/seconde en temps réel. TICK_DT = 0.1 s de temps de jeu.
En mode tactique : 0 tick tant qu'aucune action ; une action de joueur pousse
N ticks (coût de l'action) dans la file, exécutés immédiatement.

Coûts d'action par défaut (mode tactique) :
  se déplacer d'un bloc : 3 ticks (modulé par vitesse/poids porté)
  attaque : 10 / vitesse_arme ticks
  utiliser un objet : 5 ticks ; poser/casser un bloc : 2 ticks
  (en temps réel, ces mêmes coûts deviennent des cooldowns)

Ordre d'un tick (déterministe, host-autoritaire) :
  1. Entités : IA décide → actions résolues (combat E.3, déplacement)
  2. Systèmes du monde : croissance cultures, régén mana/santé, faim,
     timers (régénération cases sauvages, boutiques)
  3. EventBus : dispatch des événements émis pendant 1-2
  4. Réseau : diff d'état → clients
Le temps calendaire (jour/nuit, semaine in-game) est un compteur de ticks :
  1 jour in-game = 24 000 ticks (40 min temps réel). 1 semaine = 7 jours.
```

### E.2 Génération du monde : unification macro/micro

Résout la question ouverte de 3.0 (cohérence carte ↔ cellules ↔ transitions) :

```
Il n'existe qu'UNE génération : les couches de bruit sont des fonctions
continues f(x, z) sur les coordonnées MONDE (en blocs).
- Le biome en un point = résolution des conditions (B.6) sur les valeurs
  de bruit À CE POINT. Les transitions entre biomes sont donc naturellement
  continues (aucun raccord à gérer entre cellules : la cellule n'est qu'une
  fenêtre administrative de 128×128 sur ce champ continu).
- La "case" de la carte du monde affiche le biome échantillonné AU CENTRE
  de la cellule + icônes des POI qu'elle contient. La carte est un
  résumé, jamais une source de vérité.
- Terrain 3D SPECTACULAIRE — l'altitude n'est pas un simple bruit
  lissé ("plat avec un peu de relief" est explicitement un anti-but) :
    altitude(x,z) = continentalité (bruit très basse fréquence :
      grandes masses émergées / mers)
      + relief modulé par une couche d'ÉROSION/PIC :
        * ridged noise (crêtes) → CHAÎNES DE MONTAGNES massives,
          arêtes vives, pics à 200-400 blocs au-dessus des plaines
        * domain warping (le bruit déforme ses propres coordonnées)
          → côtes découpées, vallées sinueuses, formes organiques
        * terrasses conditionnelles (quantification locale de
          l'altitude là où la couche sismique est forte) → FALAISES
          verticales de 30-80 blocs, mesas, canyons
      + bassins : les minima locaux larges sous le niveau d'eau
        régional → GRANDS LACS (remplis à la génération, sources
        E.22) ; les fleuves suivent le gradient entre lacs et mer.
    Formations rares (hash déterministe, façon POI) : arches
    naturelles, pitons isolés, cratères, gorges — assemblées par
    modificateurs de terrain paramétriques, pas de prefabs.
  Un bruit 3D de cavernes (densité) creuse en dessous ; les strates
  de matériaux suivent la profondeur + le biome de surface + les
  couches dédiées (ressources) pour les filons.
- STRATIFICATION PAR DURETÉ (verrou de progression naturel) : plus on
  descend, plus la roche est dure — voir la table des strates en G.9/
  section 3.2. Combiné à la règle d'irrécoltabilité (A.2 : outil trop
  faible = rebond), creuser profond exige de meilleurs outils, de
  meilleurs matériaux (trouvés... en profondeur : boucle de progression)
  ou des PNJ mineurs de haut niveau. Les filons riches et les meilleurs
  minerais sont placés dans les strates profondes.
- POI : placement déterministe par hash(seed, cell_x, cell_z) → chaque
  cellule a 0-2 POI tirés selon poi_weights du biome (B.6). Densités par
  défaut : village 4 %, donjon 6 %, camp 8 %, sanctuaire 3 %, filon
  majeur 6 % par cellule. Les donjons sont assemblés procéduralement à
  partir de salles préfabriquées .vox (mêmes palettes remapables que 9.2).
- Villes : un village démarre par un centre + N bâtiments préfab posés le
  long de routes générées (bruit + A* sur la carte des pentes), palette
  par biome (9.2).
```

### E.2.2 Rivières et littoraux (hydrographie, implémenté 2026-07-20)

```
Réseau hydrographique (E.2, complète la mention des lacs/fleuves ci-dessus) :
- SOURCES : nées en altitude, tirées par cellule (même technique que les
  POI/arbres — hash déterministe + rejet bon marché avant tout calcul de
  bruit), exigent une altitude suffisante (naissent en montagne).
- TRAÇAGE : descente de gradient (steepest descent) pas à pas depuis la
  source ; s'arrête à la mer/un lac (jonction), ou sur un minimum local
  sans exutoire (BASSIN ENDORÉIQUE, un petit lac isolé) — jamais de rivière
  qui remonte ou traverse une crête.
- CREUSEMENT : le lit est creusé LOCALEMENT (pas via le niveau de mer
  global) — l'eau remplit le lit jusqu'au niveau du terrain d'origine à cet
  endroit précis, ce qui permet des rivières de MONTAGNE (pas seulement au
  niveau de la mer). Largeur croissante avec la distance parcourue depuis
  la source (approxime grossièrement la confluence affluent → rivière →
  fleuve, sans vrai calcul de débit/bassin versant).
  Matériau du lit : gravier/estran, pas le matériau du biome de surface.
- SIMPLIFICATION ASSUMÉE (monde infini streamé par chunks, G.1/G.2) : la
  recherche de sources candidates est bornée à une fenêtre RÉGIONALE autour
  de la zone en cours de génération — pas de bassin versant global
  précalculé (incompatible avec un monde infini sans limite connue à
  l'avance). Un fleuve dont la source est plus lointaine que cette fenêtre
  n'est pas retrouvé depuis une zone éloignée de sa source — limite
  mineure et disclosed, pas un bug.

Littoraux (bande autour du niveau de la mer) :
- Le matériau de rivage est choisi par la PENTE LOCALE du terrain (déjà
  calculée pour l'orogenèse — E.2, aucun coût de calcul supplémentaire) :
  pente douce = plage de sable ; pente moyenne = estran de galets ; pente
  forte = falaise ; pente très douce + humidité haute = marécage côtier.
```

### E.2.4 Spéléologie et géologie souterraine (implémenté 2026-07-20)

```
Remplace le bruit 3D creusé nu par un réseau karstique :
- TUNNELS : deux champs de bruit 3D indépendants ("vers") — un point est
  creusé si les DEUX sont proches de zéro (intersection des deux champs),
  ce qui forme des tunnels sinueux qui se ramifient et se croisent, plutôt
  qu'un bruit 3D à seuil unique (gruyère non-structuré).
- GRANDES SALLES : un troisième bruit 3D basse fréquence, seuillé haut,
  forme de rares cavernes spacieuses indépendamment des tunnels.
- BORNES : jamais à moins de 10 blocs de la surface (pas de trou béant
  visible depuis le ciel), jamais à moins de 24 blocs du plancher du monde,
  et plafonné en profondeur (le karst réel ne s'étend pas à l'infini — et
  le coût de calcul non plus, voir note de performance ci-dessous).
- SPÉLÉOTHÈMES : aux transitions plafond/air (stalactite, calcite) et
  air/sol (stalagmite, calcite, ou dépôt de guano) des poches creusées,
  densité faible, déterministe. Simplification assumée : détection bornée
  au chunk courant, une poche à cheval sur 2 chunks peut avoir des
  spéléothèmes visuellement coupés à la frontière.
- STRATIFICATION : inchangée (voir 3.2/G.9) — les cavernes creusent DANS
  les strates déjà stratifiées par profondeur/dureté, elles ne remplacent
  pas ce système.

Note de performance (à valider au bench, Annexe G) : chaque bloc solide
testé dans la bande de profondeur des cavernes paie jusqu'à 3
échantillons de bruit 3D — le poste le plus coûteux de cette refonte.
Mesuré au premier bench post-intégration : meshing moyen ~17 ms (contre
~6-9 ms avant), toujours sous les 60 fps mais avec moins de marge. Pistes
si recalibrage nécessaire : réduire CAVE_MAX_DEPTH, ou n'évaluer le bruit
karstique qu'à une fréquence spatiale plus grossière.
```

### E.2.5 Gaz souterrains (implémenté 2026-07-20, **retiré le jour même** sur demande — spec conservée comme référence)

```
Placement RÈGLE-BASÉ déterministe dans les poches d'air déjà creusées
(E.2.4) — PAS une simulation fluide/physique temps réel (hors de portée
pour un monde infini streamé en temps réel, GDScript pur, iGPU cible) :
- GRISOU (méthane, plus léger que l'air) : uniquement au PLAFOND d'une
  poche (le bloc du dessus est solide), dans une bande de profondeur
  plausible pour une veine de charbon — approximée par la couche de bruit
  "ressources" (B.8, déjà existante, aucune nouvelle couche).
- MONOXYDE DE CARBONE : diffus, chance faible et uniforme sous terre —
  cohérent avec son danger réel (inodore, indétectable sans équipement).
- DIOXYDE DE SOUFRE : zones sismiques fortes en profondeur (proximité
  volcanique, couche "sismique" existante).
- GAZ TOXIQUE LOURD : fond d'un gouffre profond (le dessous est un vrai
  plancher solide, pas une poche qui continue), sans poche voisine —
  approxime "non ventilé".
Matériaux : `data/materials/gaz/*.json` (nouvelle catégorie B.1/B.2 "gaz"),
tags `toxique`/`explosif`/`inodore` selon le gaz — les effets sur le
joueur (dégâts, explosion au contact d'une flamme) restent À IMPLÉMENTER
(hors scope de cette passe génération : ceci pose les blocs, pas encore
leurs interactions gameplay).
```

### E.3 Pipeline de résolution du combat (système à jets de dés) — *superseded par E.3.1 sur le toucher*

> ⚠️ **L'étape 2 (JET DE TOUCHER) de ce pipeline n'est plus en vigueur** depuis
> le 2026-07-28 : voir **E.3.1**. Les étapes 1, 3, 4, 5 et 6 restent exactes,
> ainsi que le **jet de compétence universel** en fin de section, qui n'a jamais
> été remis en cause. Section conservée entière : elle documente l'intention
> d'origine, et les formules de dégâts y sont toujours la référence.

Combat et actions risquées reposent sur des **jets de dés explicites**, façon roguelike (ToME/Elona) — lisibles en mode tactique, générateurs de variance et de récit. Notation XdY dans les données.

```
Une attaque (arme ou compétence-module) :
1. Coût : mana (A.6) déduit — ou surchauffe (A.5).
2. JET DE TOUCHER :
     attaque = 1d20 + N_arme/2 + Dex/4
     défense = 10 + N_esquive/2 - malus_poids_armure
     attaque >= défense → touché.
     1d20 naturel 20 → CRITIQUE (dégâts max +50 %) ; naturel 1 → échec
     critique (raté + le défenseur gagne une riposte gratuite).
     DEGRÉS DE RÉUSSITE : battre la défense de 10+ = coup solide
     (dégâts +25 %) — garde la marge signifiante à haut niveau,
     quand les bonus N/2 dépassent l'amplitude du d20.
3. JET DE DÉGÂTS :
     bruts = jet(des_fonctionnalité, cf. B.3.1)
             * (durete_BASE/20) * qualite    (règle A.4.1)
             + For/4 (mêlée) ou Dex/4 (distance)
             + effets des modules actifs (leurs propres dés)
4. MITIGATION À JET : l'armure ENCAISSE un jet
     reduction = jet(des_protection_totale)  — chaque pièce contribue
     ses dés selon dureté/qualité/facteur_slot (A.4.2) ;
     degats_finaux = max(0, bruts - reduction)
5. Application santé + événements EventBus : `damage_dealt`,
   `creature_killed` si mort (écoutés par quêtes, XP, réputation).
6. XP : attaquant gagne XP d'arme et de modules utilisés ; défenseur
   gagne XP d'Esquive et d'Encaissement.
UI mode tactique : au survol d'une cible, afficher chance de toucher,
fourchette de dégâts, chance de critique — la lisibilité est le but.
Statuts (brûlure, gel, poison...) : appliqués par tags des modules,
tickés en phase 2 de E.1, données dans data/status_effects/.
Le host tire tous les dés (autorité, E.11) — RNG seedé par tick pour
la reproductibilité en debug.
```

**Jet de compétence universel (hors combat)** — remplace les formules ad hoc :
```
1d20 + N_competence/2 + stat_associée/4  vs  DD (difficulté fixe)
Degrés : réussite de 10+ = succès supérieur ; échec de 10+ (ou 1 naturel)
= échec grave (table d'effets aggravés).
S'applique à : lecture (A.7 révisé), dressage/capture, négociation,
vol/discrétion, désamorçage, etc. UNE grammaire pour tout le jeu.
```

### E.3.1 Combat directionnel (amendement du 2026-07-28, spec écrite le 2026-08-02)

*Cette section **remplace l'étape 2 d'E.3** et fait autorité sur le toucher. Elle a été écrite après coup, à partir du code déjà en place ([combat_resolver.gd](systems/combat/combat_resolver.gd), [melee_attack.gd](systems/combat/melee_attack.gd), [player.gd](scenes/entities/player.gd)) et de la discussion de faisabilité archivée dans `combat.md` — lequel est un **transcript de conversation, pas une spécification** : ne pas l'utiliser comme référence.*

**Pourquoi le changement.** E.3 faisait décider le toucher par un 1d20. Combiné à une arme qui balaie réellement l'espace, cela met **deux systèmes en concurrence sur la même question** — le dé pouvait annuler un coup que le joueur avait visé, placé et distancé correctement. C'est la faute cardinale d'un combat de type Mount & Blade, dont la seule promesse au joueur est : *ce que vous voyez toucher, touche*.

**Le partage retenu :**

```
LA GÉOMÉTRIE décide SI et OÙ ça touche :
  - la direction du coup est lue au mouvement de souris qui suit le clic
    (haut / bas / gauche / droite / estoc) ;
  - l'arme balaie l'espace pendant l'animation ; le balayage est testé
    contre les ZONES DE COUP de la cible (Creature.sweep_segment,
    gabarits de hitbox en données, B.5) ;
  - aucun 1d20 de toucher, aucun verrouillage de cible.

LES DONNÉES décident COMBIEN — pipeline A.4.1/A.4.2 conservé INTACT :
  bruts     = jet(dés_fonctionnalité) * (durete_BASE/20) * qualité
              + For/4 (mêlée) ou Dex/4 (distance)
              + effets des modules
  bruts    *= zone_mult          <-- remplace le critique au nat 20
  mitigation = jet(dés_protection_totale) * (1 - pénétration)
  finaux    = max(0, bruts - mitigation)
```

**Le critique change de nature.** Ce n'est plus un 20 naturel, c'est le `zone_mult` du gabarit atteint (tête 2.5, torse 1.0, bras 0.7). Un critique cesse d'être une loterie pour devenir une **intention de visée**. Le seuil d'affichage « CRITIQUE » (retour visuel, sonore, XP) est `zone_mult >= 2.0` : les points faibles seuls, jamais un torse.

**Défense.** Elle passe par la **garde directionnelle**, plus par un jet d'esquive : une garde couvre sa direction, un bouclier couvre en plus les directions **voisines** (jamais toutes — deux tailles ne se jouxtent pas, sans quoi un bouclier couvrirait l'intégralité de la rose), et absorbe de l'endurance. La boucle du GDD se referme comme prévu en 6.2 : *deux mains bat l'arme seule, le bouclier bat le dual wielding*.

**Conséquences à traiter (dette ouverte par cet amendement) :**
- **Esquive et Encaissement** (E.3 étape 6 : XP au défenseur) n'ont plus de jet auquel s'accrocher et ne gagnent aujourd'hui **aucune XP**. À raccrocher : Esquive sur un coup évité de justesse (le balayage passe à moins de X du gabarit), Encaissement sur un coup absorbé par l'armure.
- **Le réseau y gagne** (E.11) : le toucher est reproductible à partir de la géométrie, donc validable côté host sans rejouer un RNG. Seuls les dés de dégâts restent à l'autorité du host.
- **Le terrain voxel impose l'auto-step** : sans franchissement automatique des blocs de hauteur 1, le jeu de jambes — la moitié de ce combat — est mort dès que le sol n'est pas plat. C'est une **dépendance dure** du contrôleur de personnage, pas une finition.

**Question ouverte créée par cet amendement — le mode tactique (5.0).** Le tour par tour reposait implicitement sur le jet de toucher : une attaque se résolvait en un jet, donc en un tour. Une attaque *visée à la souris* ne se découpe pas ainsi. Trois pistes, aucune tranchée : (a) le mode tactique ne s'applique **qu'à distance et à la magie**, le corps-à-corps restant temps réel ; (b) en tactique, le corps-à-corps retombe sur E.3 d'origine (un jet), en assumant que ce sont deux jeux différents ; (c) le tour fixe la **direction et la garde**, la résolution restant géométrique mais figée. À trancher avant d'écrire la moindre UI d'action time.

### E.4 Modificateurs : résolution unifiée

Toute valeur de jeu interrogeable passe par un résolveur unique :
`Stats.get(entity, "id")` = `(base + Σ add) × Π mult`, où les sources de
modificateurs sont : équipement (A.4.4), statuts actifs, bonus de race,
auras/buffs de modules, humeur (PNJ). Chaque source est enregistrée/retirée
dynamiquement — aucun système ne modifie jamais une valeur en dur.

> **Implémenté le 2026-08-02** — `systems/progression/stat_modifiers.gd`, sonde
> `--probe-modificateurs`. Deux écarts assumés avec le texte ci-dessus, tous
> deux dans le sens de l'architecture existante :
> - **Ce n'est pas un singleton `Stats.get(entity, …)`** mais une instance
>   portée par l'entité, comme `skills`, `inventory` et `equipment` — le projet
>   n'a pas de registre global d'entités, et en créer un pour ce seul usage
>   coûterait plus qu'il ne rapporte. La lecture publique reste
>   `entity.effective_stat(id)` : point d'entrée unique, conforme à l'esprit
>   d'E.4 (« aucun système ne modifie jamais une valeur en dur »).
> - **Les bonus de race** restent fondus dans la stat de base à la création
>   plutôt que posés comme source : ils ne changent jamais de la partie, et en
>   faire une source coûterait une itération à chaque lecture, dans un chemin
>   chaud, pour une valeur constante.
>
> Sources effectivement branchées à ce jour : **faim (A.9) et fatigue (E.21)**.
> Équipement (A.4.4), statuts (F.4), auras de modules (5.1) et humeur des PNJ
> restent à ajouter — le résolveur existe pour qu'elles n'aient plus qu'à
> s'enregistrer, ce qui fait d'elles un travail d'ajout et non de conception.

### E.5 Détection de pièces (habitat, 7.5)

```
Déclenchée à la pose/destruction d'un bloc ou d'une porte sur un claim
(événement EventBus, throttlé). Flood fill 3D depuis chaque porte du claim :
- volume clos si le fill ne s'échappe pas (limite 4 096 blocs sinon "trop
  grand/ouvert") ; plafond couvert = toit ; volume intérieur >= 2×2×2 ;
  >= 1 entité meuble dans le volume.
Résultat : liste de pièces {volume, meubles, porte(s)} stockée par claim ;
l'assignation PNJ↔pièce se fait dans l'UI de gestion du claim.
Bétail : flood fill vertical simple (un toit au-dessus de la position).
```

### E.6 Abstraction hors-site (7.4/14.5) — niveau 3 du LOD de simulation (voir E.18)

```
Quand aucun joueur n'est dans une zone chargée contenant un claim actif :
les entités du claim sont désinstanciées vers un état abstrait
{pnj: [...], jobs, stocks, defense_totale}.
Au retour du joueur (ou toutes les heures in-game en tâche de fond) :
  résolution par formules, PAS de simulation :
  production = Σ (rendement_job(pnj) * heures * facteur_humeur)
     rendement_job = f(compétence du PNJ, richesse de la zone assignée)
  ventes boutique = débit_client(trafic local) * attractivité_prix (A.8)
  raid éventuel (E.7) résolu en un jet : force_raid vs defense_totale
     defense_totale = Σ gardes (niveau_combat * équipement) + tourelles
     + bonus murs. Victoire → dégâts mineurs listés ; défaite → pertes
     de stocks/structures proportionnelles, jamais de wipe total.
Un rapport (journal) est présenté au joueur à son retour.
```

### E.7 Raids et menaces

```
Fréquence des raids sur un royaume de joueur : jet hebdomadaire in-game,
probabilité = f(corruption locale EFFECTIVE (E.20), valeur du territoire, réputations
négatives — un roi capturé (14.2) augmente drastiquement la proba côté
royaume lésé). Force du raid ~ valeur du territoire * (0.8-1.2), jamais
scalée sur le niveau du joueur (cohérent avec 3.1 : le monde ne scale pas).
Joueur présent : spawn réel d'une escouade à la bordure de cellule, IA
d'assaut vers le cœur du claim. Absent : résolution E.6.
```

### E.8 Boutique passive (7.1) — clients à portefeuille fini (voir A.8.1/7.6)

```
Trafic client = f(population PNJ dans un rayon de 3 cellules, réputation
locale, accessibilité (route générée à proximité)). Chaque heure in-game :
N clients potentiels ; chacun tire un objet de l'étal selon
attrait = demande(type d'objet localement) / prix_relatif.
Stock : l'étal est un conteneur physique (limite = taille du meuble étal).
L'or s'accumule dans le coffre de la boutique (à relever sur place ;
consultation à distance = extension future, pas MVP).
```

### E.9 Éditeur de sculpture (13) — technique

```
L'éditeur EST le moteur voxel du jeu : un mini-espace voxel isolé
(périmètre selon la table : items 16³, armes 16×16×48, meubles 32³,
blocs 16³ par définition, structures 64³, véhicules 64×64×96 — en voxels
de 1px), avec la même pose/subdivision/ghost preview que le monde.
Les matériaux sont débités de l'inventaire en temps réel (rendus si
effacés). Validation → génère : VoxModel (mesh + composition par matériau),
stat_weights (comptage de voxels), entrée d'objet (B.3) sauvegardée dans
le profil du joueur, partageable en coop (copie du modèle vers le
catalogue du groupe, sur action explicite du créateur).
```

### E.10 Sauvegarde (**implémenté 2026-07-21** — SaveManager.gd ; état réel ci-dessous)

```
Format : un dossier par monde (user://saves/monde).
  world.json      : version, seed, temps (ticks) + TABLE DES MATÉRIAUX
                    (id runtime → id texte au moment de la sauvegarde :
                    les ids runtime glissent quand un matériau est
                    ajouté/retiré, la table rend la sauvegarde immune)
  chunks/x_y_z.bin : uniquement chunks modifiés — liste (index_bloc,
                     nouvel_état) ; état = id matériau OU sous-grille
                     de subdivision sérialisée (grille plate G.2 amendée)
  state.json      : claims (rôles), exploration/minimap, étals de
                    boutique, donjons nettoyés, état du joueur
                    (position, or, santé, compétences+XP, inventaire)
                    — fusionne players/*.json + abstract.json tant que
                    le jeu est solo ; ils se sépareront avec le multi
  entities.json   : instances de créatures — PAS ENCORE (le spawn
                    naturel régénère la faune ; le boss d'un donjon non
                    nettoyé renaît à la session suivante, simplification
                    assumée)
Écriture : autosave toutes les 5 min réelles + F9 (manuel) + à la
sortie du jeu ; écriture atomique (tmp + remplacement, récupération du
.tmp au chargement si l'écriture a été interrompue) ; instantané en
octets sur le thread principal, I/O en thread (G.7 : l'autosave ne
bloque jamais le jeu). Persistance COUPÉE en modes bench/probe/test et
côté client --join (le host possède la sauvegarde). Le multi : seul le
host possède la sauvegarde ; les invités gardent localement leur
personnage (import à la connexion, exporté à la déconnexion — à faire).
```

### E.11 Réseau : autorité et flux

```
Host autoritaire sur : ticks, monde voxel, entités, loot, économie.
Client envoie : intentions (inputs, "je pose bloc X ici") ; le host valide
(anti-triche minimal : portée, possession) et diffuse le résultat.
Fiable (RPC) : mutations du monde, inventaire, craft, quêtes, votes.
Non-fiable 10-20 Hz : positions/animations des entités proches.
Intérêt : un client ne reçoit que les chunks/entités dans son rayon.
Vote tactique (5.0) : RPC fiable, majorité simple, re-vote possible
après 30 s ; le passage en tactique fige les ticks pour tous.
```

### E.12 EventBus : signaux standards

| Signal | Émis par | Écouté par (exemples) |
|---|---|---|
| `block_placed/destroyed` | monde | pièces (E.5), quêtes bâtisseur, réseau |
| `creature_killed` | combat | quêtes, XP, réputation, loot |
| `item_crafted` | craft | quêtes artisan, XP artisanat |
| `item_sold` | économie | or, réputation marchande |
| `skill_level_up` | skills | UI, niveaux dérivés (6.0), guildes |
| `creature_recruited` | relations | royaume (population), habitat |
| `book_read` | lecture | modules, effets d'échec |
| `raid_resolved` | E.6/E.7 | journal, réputation |
| `cell_role_changed` | claims | régénération, restrictions |
| `locale_changed` | réglages | toute l'UI (rafraîchissement des textes) |
| `chunk_explored` | E.16 (détection) | minimap (E.30) |
| `dungeon_cleared` | E.29 (mort du boss) | timer de disparition, quêtes de guilde (7.3) |

Règle : aucun système n'appelle directement un autre système de gameplay ;
tout couplage passe par les données (tags) ou l'EventBus.

### E.13 Écrans d'interface (liste de référence)

Inventaire+équipement (avec poids), Craft (recettes des stations à portée,
4.2), Fenêtre de sculpture (E.9), Feuille de personnage (stats, compétences,
niveaux dérivés), Assemblage de compétences (slots armes/modules, coûts mana),
Carte du monde (biomes, POI, claims, voyage rapide), Gestion de claim
(rôles de cases, pièces/logements, assignations de jobs, journal des rapports
E.6), Guildes (rangs, quêtes), Commerce (achat/vente, gestion d'étal),
Relations (PNJ connus, réputations), Dialogue PNJ.

### E.14 Budgets de performance (cibles)

Chunks visibles : rayon de 8 chunks (~128 blocs) par défaut. Meshing :
< 4 ms par chunk (thread séparé, jamais sur le thread principal). Entités
actives simultanées par zone : ~64. Tick complet : < 8 ms (marge sur les
100 ms du tick). Mémoire d'un chunk plein non subdivisé : 8 Ko (16³ × 2 o).
Si le meshing GDScript est trop lent : passer cette partie (et elle seule)
en GDExtension/Rust — décision au profilage, pas avant.
La stratégie d'optimisation complète, système par système, est
consolidée en **Annexe G** (qui fait autorité en cas de divergence).

### E.15 Faim des PNJ (proposition, à valider)

Les PNJ résidents ont la même jauge de faim que le joueur (même système,
section 12 oblige), mais se nourrissent SEULS depuis les stocks de
nourriture du claim (conteneurs marqués "garde-manger"). Stock vide →
malus d'humeur et de productivité (pas de mort de faim des PNJ : pénalité,
pas de gestion punitive). Cela raccorde l'agriculture (7.4) à la boucle
royaume : les champs nourrissent la population qui exploite le territoire.

### E.16 Intelligence artificielle des créatures

**Architecture : Utility AI data-driven** (`data/ai_profiles/*.json`). Ne
s'applique qu'aux PNJ en simulation PLEINE — niveau 1 du LOD (E.18) ; les
PNJ hors chargement tournent en mode logique (graphe de POI, E.18.2) ou
abstrait (E.6). À chaque tick de décision (1 tous les 10 ticks par entité,
échelonnés entre entités),
l'entité NOTE ses actions candidates et exécute la mieux notée :

```
score(action) = Σ considération_i * poids_i
Considérations : lisent les mêmes données que tout le reste (stats, tags,
faim, santé, distance de cible, job assigné, horaire, ordres reçus...).
Exemples de profils :
  hostile      : attaquer(portée, agressivité), poursuivre, fuir(santé<25%)
  bete_sauvage : fuir(joueur proche), attaquer(acculée), errer, manger
  civil        : routine horaire (voir ci-dessous), fuir(danger), alerter gardes
  garde        : patrouiller, intercepter(hostile détecté), retour au poste
  assaillant   : progresser vers cœur du claim, détruire obstacles(murs),
                 attaquer défenseurs — utilisé par les raids (E.7)
  compagnon    : voir E.17
Créer/modifier un comportement = éditer un JSON, zéro code.
```

**Routines civiles :** champ `horaires` du profil, piloté par l'horloge de
ticks (E.1) : ex. 6h-20h → job (étal, champ, forge), 20h-22h → social
(taverne/place), nuit → lit assigné (7.5). C'est ce qui fait vivre les
villages, et ça réutilise l'assignation de jobs (14.2).

**Détection :** vision = cône de distance f(Perception) modulé par la
lumière locale (A.4.5 : luminosite) et la Discrétion de la cible (jet
opposé E.3 quand ça compte). L'alerte se propage aux alliés proches
(événement local, pas EventBus global).

**Pathfinding voxel 3D (deux étages) :**
```
LOCAL : A* sur grille de navigation dérivée des blocs — marchable =
  bloc solide + 2 blocs d'air au-dessus ; liens de saut (1 bloc),
  de chute (<= 3 blocs), échelles/portes. La nav-grille d'un chunk est
  invalidée par `block_placed/destroyed` et reconstruite paresseusement :
  le monde destructible est géré nativement.
  Budget : file de requêtes globale, N chemins résolus/tick ; entités
  lointaines ou non-critiques : déplacement en ligne droite + esquive
  d'obstacle locale (pas de vrai A*).
GLOBAL : graphe grossier au niveau cellules/routes (E.2) pour les trajets
  longue distance (caravanes, raids inter-cellules) ; affiné en local à
  l'arrivée. Hors zone chargée : pas de pathfinding du tout — les entités
  sont dans l'abstraction (E.6), position téléportée logiquement.
Morphologies (12) : volants ignorent la contrainte de sol (A* 3D volumique
  simplifié) ; amorphes passent les ouvertures 1 bloc. Paramètres de
  navigation dans le template de squelette.
```

### E.17 Compagnons

**Capacité d'escorte** — le nombre de compagnons actifs qui suivent le
joueur dépend du Charisme et d'une compétence dédiée **Leadership**
(progresse à l'usage : gagner des combats avec des compagnons actifs,
donner des ordres) :
```
places_escorte = 1 + floor(Charisme / 5) + floor(N_leadership / 10)
  (départ typique : 2 ; bâti Charisme/Leadership élevés : 6+)
```
**Deux statuts distincts :**
- **Compagnon permanent** : recruté (12), voyage partout avec le joueur,
  compte dans places_escorte quand actif ; les inactifs attendent à la
  base (et peuvent y être assignés à des jobs, 14.2).
- **Suiveur territorial** : PNJ résident mis en état "suivre" UNIQUEMENT
  sur le territoire du joueur (aider à un chantier, escorte locale) —
  ne compte pas dans places_escorte, refuse de quitter le territoire.

**Ordres** (via dialogue ou raccourci, façon Elona) : suis-moi / attends
ici / posture agressive / défensive / évite les combats / retourne à la
base. En mode tactique (5.0), les ordres sont donnés sans coût de ticks.

**Équipement :** géré par le joueur via un écran d'échange ; les compagnons
utilisent leurs compétences (qui progressent à l'usage, comme acté en B.5).

**Mort d'un compagnon (façon Elona) :** un compagnon tué est MORT, pas
inconscient — mais **ressuscitable** :
- Son corps/dépouille est récupérable (objet-âme dans l'inventaire, poids
  symbolique) ; son équipement reste sur lui.
- Résurrection = action dédiée coûteuse : soit un PNJ prêtre/autel de
  sanctuaire (POI, 3.1) contre de l'or (coût ∝ niveau du compagnon),
  soit plus tard un sort du domaine Vie (C.6) de haut niveau.
- Un compagnon mort non ressuscité reste mort indéfiniment (pas de
  disparition du corps) — la perte n'est jamais irréversible, mais elle
  coûte et interrompt (retour au sanctuaire).
- À la résurrection : malus temporaire ("affaibli", -20 % stats pendant
  1 jour in-game). Relation inchangée — mourir pour vous n'est pas un
  motif de rancune, être laissé mort longtemps pourrait le devenir
  (extension future).

### E.18 LOD de simulation des PNJ (trois niveaux)

Pattern Dwarf Fortress/RimWorld : le niveau de simulation d'un PNJ dépend
de sa distance au joueur, avec des transitions invisibles.

```
NIVEAU 1 — PLEIN (chunks chargés autour du joueur) :
  IA utility complète (E.16), pathfinding réel, physique, rendu.

NIVEAU 2 — LOGIQUE (zone claim/ville CONNEXE à celle du joueur, mais
  hors chargement — ex. l'autre bout de sa base ou du village visité) :
  Le PNJ vit sur le GRAPHE DES POINTS D'INTÉRÊT de la zone :
    nœuds = lits (pièces E.5), postes de travail (jobs 14.2), étals,
    tavernes, portes... ; arêtes = distances précalculées sur la
    nav-grille (E.16), invalidées par modifications de blocs.
  État du PNJ = {POI courant OU transit(POI_a → POI_b, progression),
    agenda} — tout avance par COÛTS DE TICKS identiques au niveau 1 :
    durée de trajet = distance_graphe * coût_tick/bloc, les actions de
    routine (travailler, manger, dormir) durent leur temps réel.
  Les actions se résolvent par formules (le fermier produit, le client
  achète — mêmes formules que E.6/E.8) : timings honnêtes, coût quasi
  nul (une entrée d'agenda + un timer par PNJ ; ~100 PNJ logiques ≈
  le coût de 3 PNJ pleins).

NIVEAU 3 — ABSTRAIT (aucun joueur dans la zone) : E.6, résolution à
  gros grain par période, pas de PNJ individuels actifs.

TRANSITIONS :
  2 → 1 (le joueur approche) : matérialisation par interpolation — un
    PNJ "en transit à 60 %" est spawné à 60 % du chemin sur le graphe.
    Jamais de téléportation visible : la ville semble avoir vécu.
  1 → 2 (le joueur s'éloigne) : l'état plein est projeté sur le graphe
    (POI le plus proche, action en cours convertie en agenda).
  2 ↔ 3 : sérialisation/désérialisation vers l'état abstrait (E.6).
ÉVÉNEMENTS EN ZONE LOGIQUE (ex. raid sur un quartier hors écran) :
  joueur assez proche → chargement forcé + matérialisation du combat ;
  sinon → résolution par formule (E.6/E.7) pour ce sous-événement.

Le niveau 2 sert AUSSI les villages PNJ traversés par le joueur : même
mécanisme, zéro système supplémentaire — les villages paraissent vivants.
```

### E.19 Tooltips contextuels (onboarding, 6.3)

```
data/tutorials/*.json : { "id", "trigger": {signal EventBus + conditions},
  "text_key", "once": true, "delay_ticks", "category" }
Exemples :
  premier arbre visé → tooltip récolte/outils
  premier bloc en main → placement + ghost preview + Shift grille fine (4.1)
  première subdivision → explication des résolutions
  premier livre ramassé → lecture, risque d'échec
  première créature hostile détectée → bascule mode tactique (5.0)
  faim < 60 la première fois → manger
  premier module obtenu → écran d'assemblage (slots)
  premier claim → rôles de cases (3.3)
  premier PNJ recrutable (relation proche du seuil) → recrutement
Moteur : un système léger abonné à l'EventBus ; état "vu" par profil
joueur (E.10). Catégories désactivables ; "mode vétéran" = tout off.
Aucun contenu de jeu verrouillé derrière un tutoriel — information
pure, jamais de progression conditionnée.
```

### E.20 Dérive de la corruption (3.1)

```
La couche danger/corruption = bruit de base (3.0) + DELTA persistant par
cellule (sauvegardé, E.10), borné [-40, +40] autour de la base.
Mise à jour HEBDOMADAIRE in-game (même horloge que la régénération 3.3) :

INFECTION — chaque foyer hostile ACTIF (donjon non nettoyé, camp, repaire)
  ajoute +2 de delta à sa cellule et +1 aux 8 voisines, par semaine,
  jusqu'à son plafond d'influence (foyer mineur +10, majeur +25).
NETTOYAGE — vider un foyer (boss/chef tué, occupants éliminés) :
  - le foyer devient INACTIF (plus d'infection) pendant sa période de
    répit : 4 semaines (mineur) à 12 semaines (majeur), puis il peut
    se repeupler (jet hebdomadaire, proba ∝ corruption locale restante)
  - delta local : -8 immédiat sur la cellule, -3 sur les voisines
DÉCROISSANCE NATURELLE — sans foyer actif à proximité, le delta tend
  vers 0 à raison de -1/semaine (le monde revient à son état de bruit).
ZONES CIVILISÉES — les cellules claim du joueur et les villages PNJ
  exercent une pression -1/semaine sur leurs voisines (la civilisation
  repousse la corruption — les gardes patrouillent).

EFFETS de la corruption effective (bruit + delta) : niveau des créatures
  qui spawnent, densité des foyers, qualité/rareté du loot (richesse ∝
  danger), proba de raids (E.7), teinte visuelle du biome (feedback).
UI : la heat-map de la carte du monde (6.3) affiche la valeur effective —
  le joueur VOIT sa région se pacifier et les frontières sombres au loin.
Coût : un passage hebdomadaire sur les cellules à delta non nul ou à
  foyer — négligeable (pas de simulation continue).
```

### E.21 Cycle jour/nuit et sommeil

```
CYCLE — 1 jour in-game = 24 000 ticks (E.1) : aube 5h-7h, jour 7h-19h,
crépuscule 19h-21h, nuit 21h-5h (heures in-game). Lumière ambiante
interpolée ; la nuit, seules les sources locales comptent (luminosite
A.4.5 : torches, lanternes, blocs lumineux — l'éclairage de la base
devient un vrai enjeu de construction).

LA NUIT EST DANGEREUSE :
- Spawns nocturnes : les tables de spawn par biome ont un volet "nuit"
  (créatures nocturnes : loups en chasse, prédateurs embusqués,
  humains hostiles en maraude) ; densité de spawn hostile x2, et
  niveau effectif +10 % de corruption locale (E.20) la nuit.
- Malus de vision : cône de détection réduit pour tous (E.16) — le
  joueur voit moins loin, MAIS les ennemis aussi : la nuit favorise
  la Discrétion (jets +4) autant qu'elle menace. Vision nocturne
  (grant_tag F.7) annule le malus du porteur.
- Les PNJ civils rentrent dormir (routines E.16), villages fermés —
  commerce indisponible la nuit sauf tavernes.

SOMMEIL (lit requis, meuble F.6) :
- Dormir SANS sauter le temps ("se reposer jusqu'à l'aube" désactivé) :
  régén santé/mana x4 pendant le sommeil, buff "Reposé" au réveil
  (+5 % XP pendant 4 h in-game, humeur PNJ +5). Vulnérable pendant
  le sommeil (réveillé par toute attaque).
- SAUTER LA NUIT : dormir 21h-5h avance le temps au matin. Le monde
  est résolu par l'abstraction (E.6) pour la durée sautée : cultures
  poussent, boutiques hors-site vendent, timers avancent — le saut
  n'est jamais gratuit ni exploitable (les raids peuvent frapper
  pendant la nuit sautée et réveillent le dormeur, résolution réelle).
- Pas de privation de sommeil punitive pour le joueur (pas de jauge
  fatigue) — dormir est un choix avantageux, pas une corvée.
  **AMENDÉ le 2026-07-27 (décision de l'auteur) : une jauge de fatigue
  EST ajoutée.** Elle descend avec le temps éveillé (~2 jours in-game)
  et se remplit entièrement en dormant une nuit. Ses effets restent
  volontairement doux, dans l'esprit de la règle d'origine — une
  incitation, jamais une corvée, et jamais létale :
    < 50 : -10 % d'XP gagnée
    < 25 : -10 % à toutes les stats, plus de régénération de santé
    = 0  : effets cumulés, AUCUN dégât (contrairement à la famine A.9)
MULTIJOUEUR — sauter la nuit déclenche un VOTE (même mécanique que le
mode tactique, E.11) : majorité simple, tous doivent être dans un lit
ou hors combat ; le temps saute pour tout le monde.
```

### E.22 Eau et liquides (physique façon Minecraft)

```
MODÈLE — automate cellulaire par blocs, PAS de simulation de fluide :
- Un bloc de liquide est SOURCE (niveau 8/8) ou ÉCOULEMENT (niveau 7→1).
- Propagation : un liquide s'écoule vers le bas en priorité (devient
  source de chute), sinon s'étale horizontalement en perdant 1 niveau
  par bloc (portée 7 blocs pour l'eau, 3 pour les liquides visqueux —
  lave, boue, goudron, huile : champ `viscosite` dérivé de la friction).
- Vitesse : mise à jour des blocs liquides actifs tous les 5 ticks
  (eau) / 15 ticks (visqueux) — file de blocs "à recalculer", seuls
  les liquides en mouvement coûtent quelque chose.
- Les sources sont INFINIES en récolte au seau (un lac ne se vide pas
  en le puisant) mais un bloc source détruit/déplacé disparaît.
  Pas de "bassin infini 2x2" : une source ne se duplique jamais
  (différence assumée avec Minecraft, évite les exploits d'eau).
- SUBDIVISION (4.1) : les liquides vivent à la résolution du bloc de base (32px)
  UNIQUEMENT — un bloc partiellement subdivisé compte comme solide
  si >= 50 % de son volume est plein, sinon le liquide le traverse.
  (Garde la physique simple ; l'étanchéité fine n'est pas simulée.)

INTERACTIONS (par tags/stats, section 10 + A.4.5) :
- Lave + eau adjacentes → obsidienne (contact source) ou pierre
  (contact écoulement). Lave enflamme les blocs flammabilite > 0
  adjacents ; dégâts de contact 3d6 feu/tour.
- L'eau éteint le statut Brûlure ; nettoie certains statuts de surface.
- Conductivité : la foudre (modules F.2) frappant l'eau se propage à
  toutes les entités dans le volume d'eau connexe (rayon 5) — l'eau
  salée (CÉl 90) étend le rayon à 8.
- Le courant pousse les entités et objets au sol (direction de
  l'écoulement, force faible).

NAGE ET IMMERSION :
- Nager = Athlétisme ; vitesse = f(compétence), le poids porté tire
  vers le fond (surcharge = on coule, largage d'objets possible).
- Souffle : jauge 30 s + Endurance*2 ; à 0 → 1d6 dégâts/tour.
  respiration_aquatique (tag F.7) = immunité.
- Sous l'eau : vision réduite, pas de combat à distance sauf arbalète
  (malus -4), mêlée à -2, feu impossible, foudre déconseillée (cf. plus
  haut — y compris pour le lanceur).
- La pluie (météo par biome, extension future) remplit les cavités
  ouvertes d'1 niveau max — pas d'inondation générale.

BATEAUX (pont vers les véhicules, 13) : un véhicule sculpté flotte si
flottabilite moyenne >= 50 (A.4.5) ; il repose sur la surface des blocs
d'eau et suit le courant s'il n'est pas dirigé. Détail du pilotage :
avec le système véhicules (à spécifier).
Réseau : le host simule, les écoulements sont des mutations de blocs
standard (E.11) — rien de nouveau à synchroniser.
```

### E.23 Dialogue PNJ (menu contextuel façon Elona)

```
STRUCTURE — interagir avec un PNJ ouvre un MENU CONTEXTUEL, pas un arbre :
  la réplique d'ambiance du PNJ s'affiche en haut, les options en dessous.
  Options AFFICHÉES SELON LE CONTEXTE (data-driven, conditions sur tags/
  état — section 10) :
    Parler        (toujours — retire une réplique d'ambiance, +micro-
                   relation 1x/jour/PNJ, jet de Charisme pour bonus)
    Commercer     (tag commerce_possible + PNJ marchand/étal)
    Quêtes        (PNJ donneur de quêtes / maître de guilde)
    Recruter      (conditions de recrutable B.5 approchées/remplies)
    Offrir un cadeau (objet de l'inventaire → relation selon valeur
                   et préférences du PNJ ; préférences par tags dans
                   la définition, ex. un érudit aime les livres)
    Donner un ordre (compagnons/suiveurs — E.17)
    Échanger équipement (compagnons)
    Assigner      (PNJ du territoire : job/logement/statut — 14.2, 7.5)
    Négocier      (contexte diplomatique 14.4 / marchandage de prix)
    Demander à suivre (suiveur territorial, E.17)
    Ressusciter un compagnon (prêtres uniquement, E.17)
    [Duel]        (autre joueur — PvP consenti, section 8)

RÉPLIQUES D'AMBIANCE — gabarits data-driven (data/dialogue/*.json) :
  { "id", "text_key", "conditions": {métier, humeur min/max, relation
    min/max, heure, biome/météo, événements récents (raid subi, roi
    capturé…), réputation du joueur (globale/royaume/race 7.2)} }
  Sélection : pool des gabarits dont les conditions matchent, tirage
  pondéré, anti-répétition (mémoire des N dernières répliques par PNJ).
  Exemples : un forgeron heureux le matin parle de sa forge ; un
  villageois d'un royaume dont vous avez capturé le roi vous insulte
  ou tremble (selon son courage) ; relation haute → confidences,
  rumeurs utiles (position de POI non découverts — récompense douce
  du social).
  LOCALISATION : chaque gabarit = une text_key par langue (10.1) ;
  les placeholders sont résolus via name_keys.
VOLUME DE DÉPART : ~15-20 gabarits génériques + 3-5 par métier ;
  le système est conçu pour en absorber des centaines sans code.
Pas d'arbres ramifiés ni de dialogue génératif : la profondeur vient
des conditions contextuelles, pas de la ramification — fidèle à Elona,
et un ordre de grandeur moins cher à produire et à localiser en 4
langues.
```

### E.24 Véhicules

```
NATURE — un véhicule est une ENTITÉ RIGIDE : le modèle sculpté (table
véhicules, 13) devient un objet mobile unique, façon grosse monture.
Le monde voxel n'est PAS emporté : collision par boîte englobante +
échantillonnage de la coque contre le terrain. Beaucoup plus simple
et robuste (réseau compris) que des "blocs qui bougent".

TYPES AU LANCEMENT — terrestres et navals ; aériens = extension future
(l'architecture entité-rigide les permettra sans refonte).
Fonctionnalités (B.3.1, kind "vehicule") :
  Charrette (terrestre, cargo)         Char à voile (terrestre, rapide)
  Draisine mécanique (terrestre)       Barque (naval, petit)
  Voilier (naval, cargo + passagers)
PROPULSION : mécanique/voiles — autonome, pas de traction animale.
  Le vent (direction globale par cellule, dérivée du bruit météo)
  module la vitesse des véhicules à voiles (naviguer contre le vent
  = lent ; compétence Navigation réduit le malus).

BLOCS FONCTIONNELS À LA SCULPTURE — pendant la sculpture, le joueur
place des blocs spéciaux (extension des marqueurs 12.1, ici visibles) :
  Siège de pilote (obligatoire, 1)   Sièges passagers (0-N)
  Gouvernail/timon (obligatoire)     Coffres intégrés (cargo)
  Mât+voile (véhicules à voiles — surface de voile ∝ vitesse)
  Roues (terrestres : >= 2 requis, matériau des roues → friction)
La VALIDATION vérifie les requis de la fonctionnalité choisie —
c'est la seule "contrainte de forme" du jeu (exception assumée à la
règle forme-libre de la section 13, car fonctionnelle et lisible).

STATS DÉRIVÉES (A.4/A.4.5, aucune stat nouvelle de matériau) :
  PV_vehicule = Σ durete des voxels * qualité
  vitesse = base(fonctionnalité) * f(poids total, surface de voile
            ou taille des roues) — matériaux légers = véhicule vif
  capacité de cargo = Σ volume des coffres intégrés
  flottaison (navals) : moyenne pondérée flottabilite >= 50 (A.4.5),
  tirant d'eau ∝ densité — un voilier blindé de fer coule, doser.
PILOTAGE — monter au siège (interaction) ; contrôles directs façon
monture ; les compagnons/joueurs s'assoient aux sièges passagers.
En mode tactique (5.0) : déplacer le véhicule coûte des ticks comme
une entité (1 case de mouvement = coût f(vitesse)).
TERRAIN — les terrestres franchissent 1 bloc de dénivelé, la pente
raide les arrête (les routes 9.2/friction des pavés prennent leur
sens) ; les navals demandent >= 1 bloc d'eau de profondeur + tirant.
DÉGÂTS — les véhicules encaissent (PV) ; à 0 : épave récupérable
(50 % des matériaux, façon A.11). Pas de dégâts de collision infligés
aux entités percutées au lancement (simplicité), juste poussée.
CARTE DU MONDE — voyager avec un véhicule accélère le voyage rapide
(coût de temps in-game réduit : x0.6 terrestre sur route, x0.5 naval
sur mer) et augmente le cargo transportable en voyage.
SAUVEGARDE/RÉSEAU — une entité standard (E.10/E.11) : position,
modèle référencé, PV, contenu des coffres ; le host est autoritaire.
```

### E.25 Population de village, décimation, conquête et succession (3.4/12.3)

```
CAPACITÉ DE VILLAGE — même détection de pièces que l'habitat (E.5),
  appliquée à tous les bâtiments du village au chargement/à la
  construction ; capacité = Σ pièces habitables valides.

REPEUPLEMENT — passage hebdomadaire (même liste que E.20/3.3/7.6) sur
  les villages sous capacité :
    chance_repop = 0.15 * (1 - population/capacite)
                   * (1 - corruption_locale_effective/100)   (E.20)
  Succès : instancie un PNJ générique depuis le pool du village
  (F.3-like), assigné à un job vacant (14.2) ou "villageois" par défaut.

DÉCIMATION — population atteint 0 : le village passe en état ABANDONNÉ
  (flag sur le POI) — bâtiments/meubles conservés (persistants, comme
  un claim), plus aucun PNJ, plus de génération de repop tant qu'un
  résident (joueur-assigné ou repop naturelle très lente) ne s'y
  réinstalle. Réutilisable directement par le joueur (7.5 : logements
  déjà valides).

CONQUÊTE — condition : Σ(niveau_combat des gardes vivants) < 25 % de
  la valeur nominale du village. Action au bâtiment central : jet
  universel (E.3) 1d20 + Leadership/2 + Charisme/4 vs DD = population*2.
  Succès : le village change d'allégeance (champ `royaume_id` du POI
  → royaume du joueur, 14.4) ; sa population reste en place, devient
  gérable (jobs 14.2). Réputation : delta fort sur la réputation par
  royaume ET par race concernées (7.2), signe dépendant de la relation
  préalable joueur/royaume d'origine (libération vs agression).
  Échec : réputation locale -X, défenses régénèrent +50 % sur 2 semaines.

SUCCESSION (PNJ à `leadership_role` non nul, mort) :
  Déclenché par l'événement `creature_killed` (E.12) sur une entité à
  leadership_role != null → programme un événement à délai (timer wheel,
  G.6) de durée `transition_semaines` (donnée du rôle : 2 pour une
  guilde, 4 pour un royaume) :
    succession_rule = "heir"      → cherche family.parent_of trié par
       âge/ancienneté, sinon fallback "next_in_rank"
    succession_rule = "next_in_rank" → PNJ de plus haut niveau général
       (6.0) parmi ceux partageant le même royaume_id/guild_id
    Aucun candidat → vacance prolongée (flag narratif, pas de reroll
       automatique — laissé à disposition du joueur/futur contenu)
  À la résolution : le nouveau titulaire hérite de `leadership_role`,
  `EventBus.leadership_changed` émis (quêtes de guilde débloquées à
  nouveau, diplomatie 14.4 mise à jour).
Coût : ces trois systèmes ne tournent que sur des POI/entités
  concernés, cadence hebdomadaire — négligeable (cohérent avec G.6).
```

### E.26 Lois, infractions et politiques commerciales (14.4/B.9)

```
VÉRIFICATION D'INFRACTION — déclenchée par événement (EventBus, E.12) :
  creature_killed, item_possessed (ramassage/craft), item_sold,
  border_crossed (E.24/déplacement inter-royaume avec cargo) →
  lookup dans data/kingdoms/{royaume_local}.json → laws[] filtré par
  type+target correspondant à l'événement.
  Coût : une lookup dictionnaire par événement concerné, négligeable.

DÉTECTION (l'infraction n'a de conséquence QUE si repérée) :
  Réutilise le cône de détection des PNJ à proximité (E.16) : jet
  opposé Discrétion du joueur vs Perception du PNJ témoin le plus
  proche (E.3). Aucun témoin dans le rayon → l'infraction est
  IGNORÉE mécaniquement (pas de log caché, pas de "karma" — cohérent
  avec le principe general de ne pas punir ce qui n'est pas vu).

RÉSOLUTION DE LA CONSÉQUENCE (`laws[].consequence`) :
  "amende:N"        → débit automatique du portefeuille joueur (si
                       insuffisant : confiscation d'objets à la place)
  "confiscation"     → l'objet concerné est retiré de l'inventaire
  "gardes_hostiles"  → les gardes locaux (profil E.16 "garde") gagnent
                       une considération d'urgence "intercepter le
                       contrevenant" — combat ou fuite (E.7-like)
  Royaume sans gardes (anarchie, 14.4) → AUCUNE conséquence structurelle
    possible : la loi ne peut mécaniquement pas s'appliquer.
  Impact secondaire systématique : réputation par royaume (7.2) baisse
    proportionnellement à la sévérité de la loi enfreinte.

DOUANES/TARIFS (import-export) — vérifiées au franchissement de
  frontière avec du cargo (inventaire du joueur ou d'un véhicule,
  E.24) OU à la vente en boutique d'un royaume différent de l'origine
  du bien :
    prix_final = prix_suggere (A.8) * (1 - tariffs[categorie])
    tariff >= 1.0 → vente/import refusés (bien interdit)
  La CONTREBANDE (faire passer un bien taxé/interdit sans déclaration)
  suit exactement le pipeline détection ci-dessus — aucun système
  séparé nécessaire : c'est une infraction "objet" comme une autre.

Génération des lois arbitraires (flavor, 14.4) : au moment de générer
  un royaume, tirage aléatoire pondéré (ex. 15 % de chance) d'ajouter
  0-2 lois absurdes depuis un pool `data/absurd_laws_pool.json` (un
  objet courant + statut illégal + conséquence mineure) — gratuit en
  contenu, mémorable en jeu.
```

### E.27 Génération des royaumes PNJ (monde infini)

```
STRUCTURE DU MONDE — les royaumes sont des ÎLOTS DE CIVILISATION
séparés par de vastes terres sauvages sans lois (14.4 : hors royaume =
aucune loi, aucune douane — la "wilderness" est l'anarchie de fait).
La majorité du monde est sauvage ; un royaume est un événement.

GÉNÉRATION DÉTERMINISTE PAR GRAINES DE CAPITALE (compatible infini) :
  Le monde est découpé en SECTEURS de 64x64 cellules. Par secteur :
  hash(seed, secteur) → 0 à 2 "graines de capitale", placées sur les
  cellules du secteur les plus favorables : basse corruption (bruit
  danger), eau/côte à proximité, terrain praticable (altitude modérée),
  biome hospitalier. Aucun réseau global à calculer : chaque secteur
  se résout seul, ses graines sont connaissables sans générer le
  terrain (lecture pure des couches de bruit) — la carte du monde
  peut donc afficher les royaumes lointains avant toute visite.

TAILLE (tirée à la graine, toute la gamme voulue) :
  hameau-État    : capitale-village seule                (40 %)
  cité-État      : capitale 1 cellule + 1-3 villages     (30 %)
  petit royaume  : capitale 1-2 cellules, 1-2 villes,
                   3-6 villages                          (20 %)
  grand royaume  : capitale 2-4 CELLULES (ville traversant
                   les frontières de cellules — le monde continu
                   3.2 le permet nativement), 2-4 villes,
                   6-12 villages                         (10 %)
  Territoire : cellules contiguës autour de la capitale (croissance
  par coût : le territoire s'étend en évitant hautes corruptions et
  montagnes) ; villes/villages placés dans le territoire le long des
  routes générées (E.2). Deux royaumes proches bornent leurs
  territoires l'un contre l'autre (frontière) ; sinon le territoire
  s'arrête et la wilderness commence.

IDENTITÉ (déterministe à la graine) :
  - Race dominante : choisie selon le biome de la capitale (affinités
    déclarées dans les données de race — ex. nains → montagnes) ;
    ~90 % de la population générée est de la race dominante, ~10 %
    d'autres races, et TOUT rôle de gouvernance/leadership_role est
    exclusivement de la race dominante (12.2/B.9).
  - **Culture (12.5/B.11) :** tirage pondéré par `race_affinity` parmi
    les 10 cultures (C.9) selon la race dominante du royaume — un
    royaume humain peut tirer n'importe quelle culture à large spectre
    (sino, nordique, latine...), un royaume sylvide tire toujours sa
    culture dédiée. Détermine ensuite noms de PNJ, noms de villes et
    titres des rôles de leadership (E.31).
  - Gouvernance : tirage pondéré par la race/culture (données),
    puis taxes, tarifs, lois (dont absurdes, E.26), palette
    architecturale (9.2) et nom du royaume généré (gabarits par
    langue, 10.1 — distinct du nom des villes, qui suit E.31).
  - COMMERCES ET HALLS DE GUILDE : chaque ville tire ALÉATOIREMENT
    ses types de boutiques (forgeron, alchimiste, libraire, tailleur,
    épicier...) et ses halls de guilde parmi les 12 (7.3) — avec la
    règle : MAXIMUM UN EXEMPLAIRE DE CHAQUE TYPE PAR VILLE. Nombre
    tiré selon la taille (hameau 0-1 boutique, capitale 5-8 boutiques
    + 2-4 halls). Conséquence voulue : aucune ville n'a tout —
    trouver "la ville qui a un hall des Enchanteurs" est une vraie
    information (rumeurs E.23, guilde Exploration), et le voyage
    inter-villes reste utile à haut niveau.
  - Relations initiales entre royaumes voisins : tirage pondéré par
    compatibilité de gouvernance et de race (deux dictatures
    frontalières = tension probable) → champ diplomacy (B.9).

MATÉRIALISATION PARESSEUSE — un royaume "existe" en données dès que
  son secteur est interrogé (carte du monde), mais ses villes/PNJ ne
  sont INSTANCIÉS qu'à l'approche du joueur (E.2 première visite,
  puis LOD E.18). Un royaume jamais visité ne coûte rien.
LE ROYAUME DU JOUEUR naît différemment (14.4) : par ses claims —
  même schéma B.9, gouvernance choisie par le joueur à la fondation (14.4).
```

### E.28 Météo (mécanique profonde)

```
GÉNÉRATION — la météo est une FONCTION PURE, jamais une simulation :
  meteo(cellule, temps) = f(bruit spatial lent + bruit temporel,
  filtrés par température/humidité locales (3.0))
  → un état parmi : clair, nuageux, brouillard, pluie, orage, neige,
  vent fort, + extrêmes rares : TEMPÊTE, BLIZZARD, CANICULE.
  Évaluée à la demande (zones chargées, carte du monde, E.6/E.18) —
  coût nul pour le reste du monde, déterministe et reproductible.
  Cohérence spatiale : le bruit spatial est lent → un front de pluie
  couvre plusieurs cellules et "se déplace" avec le temps.
  Les EXTRÊMES sont ANNONCÉS 1 jour in-game à l'avance : ciel visible
  + les PNJ en parlent (gabarits météo, E.23 — raccord existant).

TEMPÉRATURE RESSENTIE (joueur ET PNJ) :
  T = temp_biome (3.0) + mod_météo (neige -15, canicule +18...)
      + mod_nuit (-8, E.21) + mod_altitude (-1/20 blocs au-dessus
      de la surface de référence) + mod_profondeur (+stable sous
      terre : les cavernes lissent vers une T moyenne)
  Zone de confort : [5, 30]. Hors zone : malus progressifs
  (vitesse, régén) puis dégâts froid/chaleur par palier — contrés par
  l'ISOLATION de l'équipement (A.4.5, formule déjà calibrée), les
  sources de chaleur locales (cheminée F.6 : déjà "annule le malus de
  froid dans la pièce" ; lave, torches à petit rayon), l'ombre et
  l'eau en canicule. Le biome extrême devient un vrai contenu :
  la toundra exige la fourrure, le désert tue à midi en canicule.

EFFETS PAR ÉTAT :
  Pluie    : cultures arrosées (+15 % vitesse de pousse, 7.4),
             feux éteints, +1 niveau d'eau dans cavités (E.22),
             visibilité -20 % (détection E.16)
  Orage    : pluie + FOUDRE RÉELLE : impacts aléatoires, ciblage
             pondéré par hauteur ET conductivité électrique du bloc
             sommital (A.4.5) → un PARATONNERRE émergent : un mât de
             fer/cuivre au point haut capte la foudre et protège
             (aucun système dédié — les stats des matériaux suffisent).
             Impact : dégâts zone 3d8, ignition (flammabilite), les
             entités dans l'eau connexe prennent la propagation (E.22).
  Neige    : couche de NEIGE au sol (bloc fin 4px auto-posé sur les
             surfaces exposées, paresseusement au chargement — comme
             la régénération 3.3), fond au redoux/sources de chaleur.
  GEL      : température < -5 prolongée → la SURFACE des blocs d'eau
             calmes devient GLACE (bloc réel, marchable, friction 5,
             cassable → re-eau) ; appliqué paresseusement au
             chargement de la zone selon la météo courante. Les lacs
             gelés ouvrent des raccourcis saisonniers ; la pêche/
             navigation s'arrêtent.
  Blizzard : neige + froid extrême (-25) + visibilité 3 blocs +
             vent fort — voyager devient dangereux, s'abriter devient
             le gameplay.
  Canicule : +18, cultures flétrissent SANS arrosage manuel (7.4),
             l'eau peu profonde s'évapore (niveaux d'écoulement
             uniquement, jamais les sources, E.22), risque d'ignition
             spontanée des blocs flammabilite >= 80 exposés.
  Tempête  : vent violent (véhicules à voiles ingouvernables, E.24),
             projectiles déviés, arrachage des blocs très fragiles
             exposés (durete <= 3 ET non-abrités : paille, chaume —
             budget : quelques blocs/cellule max, jamais destructeur
             de bases en dur).
  Vent     : direction/force par cellule — DÉJÀ consommé par les
             voiles (E.24) ; la tempête/le calme plat en sont les
             extrêmes.

MATÉRIAUX : Glace et Neige ajoutés au catalogue (F.1) — matériaux
  réels à part entière (constructibles : la glace est un vrai bloc,
  transparent, glissant ; fond près des sources de chaleur).
DONNÉES : data/weather_states.json (états, modificateurs, effets) —
  ajouter un état météo = une entrée, zéro code (section 10).
SAISONS : non incluses pour l'instant ; la génération temporelle est
  conçue pour accueillir une modulation saisonnière plus tard
  (multiplier le bruit temporel par une courbe annuelle) — question
  ouverte, gros impact agriculture si activé.
```

### E.29 Génération procédurale des donjons (3.5)

```
BIBLIOTHÈQUE — deux familles de prefabs .vox (schéma B.10) :
  SALLES : catégories de taille (petite 8³, moyenne 16³, grande 24³,
    immense 32×32×16), forme libre, sol NON obligatoirement plat
    (fosses, marches, plateformes encodées dans le modèle voxel lui-
    même). Points d'attache = voxels-marqueurs typés (même technique
    que 12.1) : porte_nord/sud/est/ouest, cage_escalier_haut/bas.
  CONNECTEURS : corridor_droit, corridor_coude, corridor_T,
    escalier_montant, escalier_descendant (offset vertical -16/+16,
    aligné chunk), porte_simple, rampe.

GÉNÉRATION PAR ÉTAGE (graphe, façon Daggerfall) :
  1. Placer la salle d'entrée à la position fixe (sous le point
     d'entrée de surface, 3.5).
  2. Boucle : choisir un point d'attache libre au hasard parmi les
     salles déjà placées → tirer un connecteur compatible avec son
     type → tirer une salle compatible avec l'autre bout du
     connecteur → tester la collision AABB contre tout le déjà-placé
     → si collision, retirer (max 8 essais) sinon placer.
     Répéter jusqu'au nombre cible de salles de l'étage (3.5) ou
     échec de placement répété (accepter l'étage tel quel — pas de
     boucle infinie).
  3. Connexité garantie par construction (chaque salle n'est ajoutée
     que reliée à l'existant) — pas de vérification a posteriori.
  4. Si un étage suivant existe : convertir 1 point d'attache libre
     d'une salle profonde (distance de graphe maximale à l'entrée)
     en cage d'escalier vers le bas.
  5. Étage le plus profond : la salle la plus distante de l'entrée
     (BFS sur le graphe) est taguée `boss_room` (tirage de la
     créature la plus dangereuse du profil du donjon + artefact
     garanti si donjon majeur, 3.1).
  6. Peuplement : chaque salle reçoit 0-N créatures (poids par
     `special_tags`, profil du donjon) et 0-N contenants de loot,
     depuis les tables standards (F.3/F.7) modulées par la formule
     de profondeur ci-dessous.
  Coût : génération en thread au premier accès à l'étage (paresseuse,
  comme le reste du monde, E.2) — un étage jamais atteint ne coûte
  rien. Déterministe par seed(monde, id_donjon, étage).

DIFFICULTÉ/LOOT PAR PROFONDEUR :
  corruption_effective_etage = corruption_locale (E.20) + etage * 8
    (plafonnée à 100) — utilisée pour le niveau des spawns (F.3) et
    la qualité/rareté du loot (A.3/A.8), indépendamment de la
    corruption de surface.

THÈME ET PALETTE — un donjon tire un thème à sa génération (ruine,
  crypte, mine effondrée, repaire) qui sélectionne : la palette de
  remapping (9.1/9.2), le pool de créatures (F.3), et les tags
  `floor_theme` filtrant les salles/connecteurs éligibles.

TERRAIN DE SURFACE (3.5) — au moment de la génération du POI (E.2),
  la colonne de terrain normale de la cellule est remplacée par une
  structure d'entrée scellée (petite bibliothèque de prefabs de
  surface dédiée, même système de palette) + terrain environnant
  rendu impraticable (falaises/éboulis générés, pas de mur infini
  artificiel — cohérent avec un monde entièrement destructible).

NETTOYAGE ET DISPARITION (3.5) : à la mort du boss (`creature_killed`
  sur l'entité `boss_room`), le donjon passe en état "nettoyé" —
  timer de 1,5 jour in-game (timer wheel, G.6) puis : le volume de
  chunks du donjon est marqué à régénérer, la cellule redevient
  éligible à la génération de terrain normale + au claim (3.3).
```

### E.30 Minimap et brouillard de guerre

```
AFFICHAGE — toujours visible à l'écran (coin, façon roguelike). Coupe
  AU NIVEAU Y DU JOUEUR : le monde étant réellement 3D (grottes,
  donjons multi-étages 3.5/E.29, tours), la minimap montre le plan de
  la bande verticale où se trouve le joueur (± 1 chunk, ex. pour voir
  un escalier proche), jamais une projection aplatie de toute la
  colonne. Changer d'étage change ce qui s'affiche.

BROUILLARD DE GUERRE — seules les zones explorées sont visibles, le
  reste est noir. "Exploré" = traversé par le cône de détection/
  vision du joueur (E.16) au passage.

STOCKAGE (perf, cohérent avec G) — résolution CHUNK (16×16), par
  bande verticale (chunk_y, 16 blocs), PAS par bloc individuel :
    explored[chunk_x, chunk_z, chunk_y] : 1 bit
  Bitmask compact, un set par joueur, sauvegardé dans le profil
  (E.10) — persiste entre sessions. Un donjon (E.29) a ses propres
  coordonnées chunk (même monde, volume dense) : chaque étage a donc
  naturellement son propre bitmask d'exploration, sans système
  séparé.

RENDU — échantillonnage des chunks explorés dans un rayon autour du
  joueur à la bande Y courante ; teinte simplifiée par matériau
  dominant de surface du chunk (pas de rendu plein, juste une
  couleur) ; PNJ/monstres détectés affichés en surcouche (icônes),
  pas de mémoire dédiée (état live, pas de fog par entité).
  Coût : mise à jour incrémentale sur `chunk_explored` (nouvel
  événement EventBus, E.12) — jamais de recalcul de zone.
```

### E.31 Génération de noms (PNJ, villes, titres — 12.5)

```
ALGORITHME (identique pour prénom/nom de famille/ville) :
  nom = pick_random(culture.X_a) + pick_random(culture.X_b)
  (concaténation directe ; pas de règle de jonction — les pools sont
  écrits pour s'enchaîner proprement à l'écriture des données)

PRÉNOM (instanciation d'un PNJ humanoïde civil/unique, B.5) :
  culture = royaume_local.culture (B.9) — ou culture par défaut de la
    race si le PNJ n'est pas rattaché à un royaume (ex. ermite)
  prenom = pick(culture.prenom_a) + pick(culture.prenom_b)

NOM DE FAMILLE (hérité, cohérent avec la démographie 12.2) :
  Si le PNJ a un parent (family.child_of) → hérite du nom de famille
    du parent (celui à l'index 0 si parents multiples/lignée
    paternelle/maternelle non distinguée — simplification assumée).
  Sinon (PNJ fondateur, généré directement par E.25/immigration) :
    nom_famille = pick(culture.famille_a) + pick(culture.famille_b)

TITRE (uniquement si `leadership_role` non nul, à l'obtention du
  rôle — génération initiale OU succession, E.25) :
    Monarchie/théocratie/dictature/ploutocratie/république → titre =
      culture.titres[government_type_du_royaume][genre_du_pnj]
    Maître de guilde (indépendant du royaume, 7.3) → titre =
      culture.titres["guilde_maitre"][genre_du_pnj]
  Affichage : `"{titre} {prenom} {nom_famille}"` (ou `"{titre}
  {nom_famille} {prenom}"` si `name_order: "nom_prenom"`) — résolu
  en une fonction d'affichage unique réutilisée partout (fiches PNJ,
  dialogue E.23, journal de raid E.6, quêtes B.7).

VILLE (à la génération d'un royaume, E.27, pour la capitale et
  chaque village/ville placé) :
    nom_ville = pick(royaume.culture.ville_a)
              + pick(royaume.culture.ville_b)
  Toutes les localités d'un même royaume tirent dans la même culture
  → cohérence sonore à l'échelle du royaume (E.27 s'y raccorde
  directement, aucune étape supplémentaire).

COÛT — génération one-shot à l'instanciation (PNJ) ou à la création
  du royaume (villes), jamais recalculée ; stockée comme toute donnée
  d'instance (E.10). Zéro coût récurrent.
UNICITÉ — non garantie (deux "Li Wei" peuvent exister dans des
  royaumes différents, comme dans la réalité) ; au sein d'un même
  royaume, un nouveau tirage identique à un PNJ vivant est re-tiré
  une fois (évite les doublons directs sans complexifier l'algorithme).
```



## Annexe F — Catalogue de contenu de départ

*Contenu prêt à transcrire en JSON (schémas Annexe B). Valeurs = premières propositions d'équilibrage, à ajuster en playtest. Colonnes matériaux : Dur(eté), Den(sité), Val(eur), CMa (conductivité mana), Fla(mmabilité), Iso(lation), CÉl (conduct. électrique), Flo(ttabilité), Lum(inosité), Fer(tilité), Tra(nsparence), Éla(sticité), Fri(ction). Rappel B.1 : stat ≥ 50 → tag dérivé.*

### F.1 Matériaux (153 à la rédaction — **207 en données au 2026-07-21**, monde réel uniquement ; `data/materials/` fait foi, la liste s'est étendue en cours de route : plantes récoltables, calcite/guano des cavernes, étal de vente...)

**Bois (40) — outil : hache, compétence Bûcheronnage**

*Profils : chaque essence a un rôle (arc, manche, coque, meuble, charpente...) — l'essence se choisit comme la gemme.*

| Matériau | Dur | Den | Val | CMa | Fla | Iso | CÉl | Flo | Lum | Fer | Tra | Éla | Fri | Rôle |
|---|--|--|--|--|--|--|--|--|--|--|--|--|--|---|
| Pin | 8 | 4 | 2 | 5 | 70 | 40 | 5 | 85 | 0 | 0 | 0 | 30 | 45 | générique abondant |
| Sapin | 7 | 3 | 2 | 5 | 72 | 45 | 5 | 88 | 0 | 0 | 0 | 32 | 45 | charpente légère |
| Épicéa | 8 | 3 | 4 | 18 | 70 | 42 | 5 | 88 | 0 | 0 | 0 | 45 | 45 | bois de résonance (instruments) |
| Mélèze | 10 | 5 | 5 | 8 | 55 | 40 | 5 | 80 | 0 | 0 | 0 | 35 | 45 | résiste à l'eau (pontons) |
| Cèdre | 9 | 4 | 7 | 14 | 50 | 55 | 5 | 84 | 0 | 0 | 0 | 30 | 45 | imputrescible, parfumé (coffres) |
| Chêne | 12 | 6 | 4 | 10 | 60 | 35 | 5 | 80 | 0 | 0 | 0 | 25 | 45 | polyvalent robuste |
| Hêtre | 12 | 6 | 4 | 8 | 62 | 34 | 5 | 79 | 0 | 0 | 0 | 28 | 48 | manches d'outils |
| Bouleau | 9 | 4 | 3 | 15 | 65 | 35 | 5 | 85 | 0 | 0 | 0 | 35 | 45 | léger, écorce utile |
| Érable | 11 | 5 | 5 | 12 | 60 | 35 | 5 | 82 | 0 | 0 | 0 | 40 | 45 | meubles fins |
| Frêne | 11 | 4 | 5 | 12 | 60 | 35 | 5 | 84 | 0 | 0 | 0 | 62 | 45 | LE manche d'arme (élasticité+léger) |
| Orme | 12 | 6 | 6 | 10 | 58 | 36 | 5 | 79 | 0 | 0 | 0 | 48 | 45 | moyeux de roues (E.24) |
| If | 13 | 6 | 9 | 20 | 55 | 30 | 5 | 78 | 0 | 0 | 0 | 78 | 45 | LE bois d'arc (élasticité 78) |
| Noyer | 13 | 6 | 8 | 12 | 55 | 35 | 5 | 78 | 0 | 0 | 0 | 30 | 45 | crosses, meubles nobles |
| Cerisier | 11 | 6 | 9 | 14 | 58 | 34 | 5 | 79 | 0 | 0 | 0 | 30 | 44 | ébénisterie chaleureuse |
| Olivier | 15 | 8 | 12 | 16 | 45 | 32 | 6 | 62 | 0 | 0 | 0 | 22 | 38 | dense, veiné (déco/manches durs) |
| Ébène | 18 | 10 | 22 | 15 | 38 | 30 | 8 | 45 | 0 | 0 | 0 | 15 | 36 | le + dur, COULE (den 10) |
| Gaïac | 20 | 11 | 26 | 12 | 35 | 30 | 8 | 38 | 0 | 0 | 0 | 12 | 12 | bois-fer réel : autolubrifiant (fri 12), engrenages |
| Acajou | 12 | 6 | 12 | 12 | 55 | 35 | 5 | 78 | 0 | 0 | 0 | 28 | 45 | coques nobles |
| Teck | 13 | 7 | 16 | 10 | 42 | 38 | 5 | 74 | 0 | 0 | 0 | 26 | 40 | LE bois de coque (huileux, imputrescible) |
| Balsa | 3 | 1 | 6 | 8 | 80 | 50 | 4 | 97 | 0 | 0 | 0 | 40 | 45 | ultra-léger, flotte comme rien |
| Bambou | 7 | 3 | 4 | 15 | 75 | 30 | 5 | 90 | 0 | 0 | 0 | 75 | 40 | échafaudages, élastique |
| Saule | 8 | 5 | 4 | 15 | 50 | 35 | 8 | 80 | 0 | 0 | 0 | 55 | 45 | vannerie, souple |
| Liège (chêne-liège) | 4 | 2 | 8 | 6 | 55 | 88 | 3 | 96 | 0 | 0 | 0 | 65 | 70 | isolation + flottaison extrêmes |
| Peuplier | 7 | 4 | 2 | 8 | 68 | 38 | 5 | 87 | 0 | 0 | 0 | 33 | 46 | croissance rapide (sylviculture) |
| Tilleul | 8 | 4 | 5 | 12 | 64 | 40 | 4 | 85 | 0 | 0 | 0 | 30 | 42 | LE bois de sculpture (tendre, fin) |
| Charme | 14 | 7 | 5 | 8 | 58 | 33 | 5 | 74 | 0 | 0 | 0 | 26 | 50 | très dur, engrenages/maillets |
| Robinier (faux acacia) | 15 | 7 | 7 | 9 | 50 | 34 | 5 | 72 | 0 | 0 | 0 | 38 | 45 | piquets/extérieur, imputrescible |
| Châtaignier | 11 | 5 | 5 | 10 | 58 | 36 | 5 | 81 | 0 | 0 | 0 | 34 | 45 | charpente, riche en tanin (cuir !) |
| Platane | 11 | 6 | 4 | 9 | 60 | 35 | 5 | 80 | 0 | 0 | 0 | 30 | 46 | ville/ombrage, bois madré |
| Aulne | 8 | 4 | 4 | 11 | 62 | 37 | 6 | 84 | 0 | 0 | 0 | 32 | 45 | résiste immergé (pilotis de Venise) |
| Buis | 19 | 9 | 18 | 14 | 42 | 30 | 6 | 48 | 0 | 0 | 0 | 20 | 34 | grain le + fin : gravure, poulies |
| Cyprès | 10 | 4 | 8 | 13 | 52 | 42 | 5 | 83 | 0 | 0 | 0 | 28 | 43 | imputrescible, parfumé |
| Séquoia | 9 | 4 | 14 | 12 | 48 | 52 | 5 | 86 | 0 | 0 | 0 | 26 | 45 | troncs GÉANTS (gros volumes d'un arbre) |
| Palmier (stipe) | 6 | 5 | 3 | 8 | 66 | 36 | 5 | 82 | 0 | 0 | 0 | 42 | 48 | biomes chauds/côtes |
| Acacia | 13 | 6 | 7 | 10 | 52 | 34 | 5 | 76 | 0 | 0 | 0 | 30 | 44 | savanes, gomme arabique |
| Eucalyptus | 12 | 6 | 6 | 11 | 56 | 33 | 5 | 78 | 0 | 0 | 0 | 36 | 44 | croissance très rapide, huileux |
| Pommier | 12 | 6 | 7 | 11 | 58 | 34 | 5 | 79 | 0 | 0 | 0 | 28 | 44 | vergers (7.4), bois de fumage |
| Noisetier | 9 | 4 | 4 | 16 | 62 | 36 | 5 | 84 | 0 | 0 | 0 | 58 | 45 | baguettes souples, haies |
| Bois flotté | 7 | 4 | 4 | 6 | 58 | 38 | 6 | 82 | 0 | 0 | 0 | 22 | 48 | plages, patiné (déco côtière) |
| Bois calciné | 6 | 4 | 3 | 5 | 5 | 45 | 5 | 70 | 0 | 0 | 0 | 5 | 50 | quasi ininflammable |

**Métaux (12) — minerai → lingot (Forge), outil : pioche, compétence Minage**

| Matériau | Dur | Den | Val | CMa | Fla | Iso | CÉl | Flo | Lum | Fer | Tra | Éla | Fri |
|---|--|--|--|--|--|--|--|--|--|--|--|--|--|
| Cuivre | 16 | 10 | 5 | 30 | 0 | 5 | 85 | 5 | 0 | 0 | 0 | 15 | 25 |
| Étain | 12 | 9 | 4 | 15 | 0 | 5 | 60 | 5 | 0 | 0 | 0 | 10 | 25 |
| Zinc | 13 | 9 | 4 | 12 | 0 | 5 | 55 | 5 | 0 | 0 | 0 | 10 | 25 |
| Bronze | 20 | 11 | 6 | 20 | 0 | 5 | 70 | 4 | 0 | 0 | 0 | 12 | 25 |
| Laiton | 18 | 11 | 7 | 22 | 0 | 5 | 68 | 4 | 3 | 0 | 0 | 12 | 22 |
| Fer | 25 | 12 | 8 | 10 | 0 | 5 | 75 | 3 | 0 | 0 | 0 | 10 | 25 |
| Acier | 30 | 13 | 12 | 12 | 0 | 5 | 72 | 3 | 0 | 0 | 0 | 15 | 25 |
| Acier trempé | 34 | 13 | 20 | 12 | 0 | 5 | 70 | 3 | 0 | 0 | 0 | 12 | 25 |
| Argent | 15 | 10 | 20 | 55 | 0 | 5 | 90 | 4 | 5 | 0 | 0 | 12 | 22 |
| Or | 10 | 19 | 35 | 65 | 0 | 5 | 95 | 2 | 8 | 0 | 0 | 20 | 20 |
| Platine | 14 | 21 | 50 | 60 | 0 | 5 | 80 | 2 | 6 | 0 | 0 | 15 | 20 |
| Plomb | 9 | 18 | 5 | 2 | 0 | 15 | 40 | 2 | 0 | 0 | 0 | 25 | 30 |
| Nickel | 22 | 12 | 10 | 15 | 0 | 5 | 60 | 3 | 0 | 0 | 0 | 14 | 25 |
| Cobalt | 23 | 12 | 14 | 25 | 0 | 5 | 58 | 3 | 2 | 0 | 0 | 13 | 25 |
| Titane | 32 | 8 | 40 | 18 | 0 | 8 | 45 | 8 | 0 | 0 | 0 | 22 | 25 |
| Tungstène | 42 | 24 | 55 | 8 | 0 | 5 | 55 | 1 | 0 | 0 | 0 | 6 | 28 |
| Aluminium (bauxite) | 14 | 5 | 9 | 15 | 0 | 6 | 78 | 25 | 0 | 0 | 0 | 18 | 22 |
| Chrome (chromite) | 28 | 13 | 22 | 12 | 0 | 5 | 52 | 3 | 4 | 0 | 0 | 8 | 18 |
| Manganèse | 20 | 13 | 12 | 10 | 0 | 6 | 48 | 3 | 0 | 0 | 0 | 9 | 26 |
| Bismuth | 8 | 17 | 16 | 35 | 0 | 12 | 30 | 2 | 12 | 0 | 0 | 6 | 28 |
| Antimoine | 10 | 12 | 10 | 20 | 5 | 10 | 35 | 3 | 0 | 0 | 0 | 5 | 28 |

**Roches (20) — outil : pioche, compétence Minage**

| Matériau | Dur | Den | Val | CMa | Fla | Iso | CÉl | Flo | Lum | Fer | Tra | Éla | Fri |
|---|--|--|--|--|--|--|--|--|--|--|--|--|--|
| Pierre | 15 | 14 | 1 | 5 | 0 | 25 | 10 | 2 | 0 | 0 | 0 | 3 | 55 |
| Granit | 28 | 16 | 4 | 5 | 0 | 25 | 8 | 1 | 0 | 0 | 0 | 2 | 55 |
| Granit noir (gabbro) | 35 | 18 | 10 | 10 | 0 | 25 | 8 | 1 | 0 | 0 | 0 | 2 | 55 |
| Diorite | 26 | 14 | 4 | 6 | 0 | 40 | 8 | 1 | 0 | 0 | 0 | 2 | 55 |
| Andésite | 24 | 15 | 3 | 6 | 0 | 20 | 9 | 1 | 0 | 0 | 0 | 8 | 65 |
| Calcaire | 12 | 13 | 2 | 5 | 0 | 30 | 10 | 2 | 0 | 0 | 0 | 3 | 55 |
| Dolomie | 14 | 13 | 3 | 5 | 0 | 30 | 10 | 2 | 0 | 0 | 0 | 3 | 55 |
| Craie | 6 | 11 | 1 | 5 | 0 | 30 | 8 | 3 | 0 | 0 | 0 | 3 | 60 |
| Marbre | 18 | 15 | 12 | 15 | 0 | 25 | 10 | 1 | 3 | 0 | 5 | 2 | 40 |
| Quartzite | 30 | 16 | 8 | 20 | 0 | 22 | 12 | 1 | 2 | 0 | 8 | 2 | 45 |
| Schiste | 13 | 13 | 2 | 6 | 5 | 28 | 12 | 2 | 0 | 0 | 0 | 4 | 45 |
| Gneiss | 27 | 19 | 5 | 8 | 0 | 24 | 9 | 1 | 0 | 0 | 0 | 2 | 40 |
| Basalte | 25 | 17 | 5 | 8 | 0 | 8 | 25 | 1 | 0 | 0 | 0 | 2 | 55 |
| Tuf volcanique | 8 | 10 | 2 | 10 | 0 | 45 | 8 | 6 | 0 | 0 | 0 | 6 | 58 |
| Pierre ponce | 4 | 4 | 4 | 8 | 0 | 55 | 5 | 65 | 0 | 0 | 0 | 8 | 62 |
| Obsidienne | 30 | 15 | 15 | 35 | 0 | 15 | 15 | 1 | 5 | 0 | 25 | 1 | 30 |
| Silex | 22 | 14 | 3 | 8 | 0 | 20 | 8 | 2 | 0 | 0 | 0 | 1 | 40 |
| Grès | 10 | 12 | 2 | 5 | 0 | 30 | 8 | 3 | 0 | 0 | 0 | 4 | 60 |
| Ardoise | 14 | 14 | 4 | 8 | 0 | 30 | 10 | 2 | 0 | 0 | 0 | 3 | 45 |
| Gypse | 5 | 10 | 3 | 8 | 0 | 40 | 6 | 4 | 0 | 0 | 12 | 4 | 50 |
| Rhyolite | 23 | 12 | 3 | 7 | 0 | 45 | 9 | 2 | 0 | 0 | 0 | 2 | 60 |
| Péridotite | 33 | 21 | 8 | 25 | 0 | 12 | 18 | 1 | 0 | 0 | 0 | 2 | 55 |
| Serpentinite | 17 | 14 | 9 | 22 | 0 | 35 | 8 | 2 | 2 | 0 | 8 | 5 | 30 |
| Travertin | 11 | 12 | 8 | 8 | 0 | 30 | 10 | 3 | 2 | 0 | 5 | 3 | 50 |
| Conglomérat | 12 | 13 | 2 | 5 | 0 | 26 | 9 | 2 | 0 | 0 | 0 | 4 | 58 |
| Brèche volcanique | 16 | 14 | 3 | 9 | 0 | 24 | 10 | 2 | 0 | 0 | 0 | 3 | 58 |
| Kimberlite | 21 | 15 | 18 | 15 | 0 | 22 | 10 | 1 | 0 | 0 | 0 | 2 | 52 |
| Calcite (spath) | 8 | 10 | 7 | 30 | 0 | 20 | 8 | 4 | 6 | 0 | 60 | 2 | 35 |

**Terres & sols (6) — outil : pelle, compétence Terrassement**

| Matériau | Dur | Den | Val | CMa | Fla | Iso | CÉl | Flo | Lum | Fer | Tra | Éla | Fri |
|---|--|--|--|--|--|--|--|--|--|--|--|--|--|
| Terre | 3 | 8 | 1 | 5 | 5 | 35 | 20 | 10 | 0 | 45 | 0 | 15 | 60 |
| Terre fertile | 3 | 8 | 3 | 10 | 5 | 35 | 22 | 10 | 0 | 75 | 0 | 15 | 60 |
| Tourbe | 4 | 7 | 2 | 8 | 55 | 45 | 18 | 25 | 0 | 60 | 0 | 20 | 55 |
| Sable | 2 | 9 | 1 | 3 | 0 | 25 | 5 | 8 | 0 | 5 | 0 | 5 | 70 |
| Argile | 4 | 10 | 2 | 8 | 0 | 40 | 30 | 5 | 0 | 20 | 0 | 35 | 50 |
| Gravier | 4 | 11 | 1 | 3 | 0 | 20 | 8 | 4 | 0 | 5 | 0 | 5 | 75 |

**Végétaux & fibres (8) — outil : faucille, compétence Herboristerie**

| Matériau | Dur | Den | Val | CMa | Fla | Iso | CÉl | Flo | Lum | Fer | Tra | Éla | Fri |
|---|--|--|--|--|--|--|--|--|--|--|--|--|--|
| Lin | 2 | 1 | 3 | 8 | 80 | 45 | 3 | 88 | 0 | 0 | 0 | 55 | 55 |
| Coton | 2 | 1 | 4 | 5 | 85 | 55 | 2 | 90 | 0 | 0 | 0 | 60 | 55 |
| Paille | 1 | 1 | 1 | 3 | 95 | 50 | 2 | 92 | 0 | 0 | 0 | 70 | 60 |
| Chanvre | 3 | 2 | 3 | 10 | 75 | 40 | 3 | 86 | 0 | 0 | 0 | 65 | 55 |
| Laine | 2 | 2 | 6 | 8 | 70 | 75 | 2 | 85 | 0 | 0 | 0 | 70 | 60 |
| Soie | 4 | 1 | 18 | 30 | 55 | 45 | 5 | 90 | 0 | 0 | 10 | 90 | 35 |
| Cuir | 8 | 4 | 5 | 5 | 40 | 50 | 15 | 60 | 0 | 0 | 0 | 55 | 55 |
| Fourrure | 3 | 2 | 7 | 5 | 60 | 85 | 5 | 80 | 0 | 0 | 0 | 65 | 65 |

**Liquides (7) — outil : seau, compétence Collecte**

| Matériau | Dur | Den | Val | CMa | Fla | Iso | CÉl | Flo | Lum | Fer | Tra | Éla | Fri |
|---|--|--|--|--|--|--|--|--|--|--|--|--|--|
| Eau | 0 | 10 | 1 | 15 | 0 | 20 | 80 | — | 0 | 30 | 85 | 0 | 10 |
| Eau salée | 0 | 10 | 1 | 12 | 0 | 20 | 90 | — | 0 | 0 | 80 | 0 | 10 |
| Lave | 0 | 25 | 8 | 20 | 0 | 0 | 30 | — | 90 | 0 | 15 | 0 | 20 |
| Huile | 0 | 8 | 6 | 5 | 95 | 30 | 5 | — | 0 | 0 | 55 | 0 | 5 |
| Goudron | 1 | 11 | 5 | 3 | 90 | 35 | 5 | — | 0 | 0 | 0 | 10 | 5 |
| Boue | 1 | 12 | 1 | 8 | 0 | 30 | 40 | — | 0 | 40 | 5 | 10 | 15 |
| Sève | 1 | 9 | 5 | 20 | 65 | 30 | 10 | — | 0 | 10 | 40 | 20 | 3 |

**Minéraux & ressources souterraines (12) — outil : pioche (ou pelle pour les meubles), compétence Minage**

| Matériau | Dur | Den | Val | CMa | Fla | Iso | CÉl | Flo | Lum | Fer | Tra | Éla | Fri | Usage principal |
|---|--|--|--|--|--|--|--|--|--|--|--|--|--|---|
| Houille | 6 | 8 | 3 | 2 | 85 | 30 | 15 | 15 | 0 | 0 | 0 | 5 | 45 | Carburant de forge |
| Lignite | 4 | 7 | 2 | 2 | 75 | 32 | 12 | 20 | 0 | 0 | 0 | 6 | 45 | Carburant médiocre |
| Anthracite | 9 | 9 | 6 | 2 | 90 | 28 | 18 | 10 | 0 | 0 | 0 | 4 | 45 | Meilleur carburant |
| Soufre | 3 | 7 | 8 | 5 | 95 | 20 | 5 | 20 | 3 | 0 | 0 | 3 | 45 | Alchimie, explosifs |
| Salpêtre | 3 | 7 | 7 | 5 | 80 | 22 | 8 | 18 | 0 | 15 | 0 | 3 | 48 | Explosifs, conservation |
| Sel gemme | 4 | 8 | 5 | 5 | 0 | 25 | 35 | 12 | 0 | 0 | 20 | 3 | 50 | Cuisine, conservation |
| Graphite | 3 | 8 | 6 | 12 | 20 | 20 | 70 | 10 | 0 | 0 | 0 | 3 | 15 | Lubrifiant, écriture |
| Mica | 4 | 9 | 5 | 18 | 0 | 50 | 4 | 8 | 3 | 0 | 45 | 15 | 40 | Isolant, fenêtres rustiques |
| Pyrite | 16 | 13 | 4 | 8 | 15 | 10 | 40 | 3 | 8 | 0 | 0 | 3 | 30 | "Or des fous", étincelles |
| Malachite | 12 | 11 | 12 | 20 | 0 | 12 | 30 | 4 | 4 | 0 | 5 | 3 | 35 | Pigment, déco, source de cuivre |
| Argile réfractaire | 5 | 10 | 6 | 8 | 0 | 60 | 12 | 5 | 0 | 10 | 0 | 30 | 50 | Fours, creusets |
| Guano/salpêtre de grotte | 2 | 5 | 6 | 3 | 40 | 25 | 10 | 30 | 0 | 95 | 0 | 10 | 50 | Engrais puissant (7.4) |
| Tourbe compactée | 5 | 8 | 3 | 6 | 65 | 42 | 15 | 22 | 0 | 55 | 0 | 12 | 50 | Carburant + amendement |
| Bitume | 4 | 10 | 7 | 4 | 92 | 30 | 6 | 8 | 0 | 0 | 0 | 15 | 4 | Étanchéité (navals), torches |
| Cinabre | 9 | 15 | 20 | 28 | 8 | 12 | 22 | 3 | 6 | 0 | 0 | 3 | 32 | Pigment rouge, alchimie (toxique) |
| Ocre | 3 | 8 | 4 | 6 | 0 | 24 | 10 | 12 | 0 | 20 | 0 | 8 | 52 | Pigment jaune/rouge |
| Lapis-lazuli | 15 | 10 | 30 | 55 | 0 | 15 | 18 | 3 | 8 | 0 | 10 | 3 | 34 | Pigment bleu précieux, déco |
| Turquoise | 14 | 9 | 26 | 48 | 0 | 16 | 16 | 4 | 6 | 0 | 8 | 4 | 34 | Bijoux, déco |
| Ambre | 6 | 4 | 24 | 42 | 45 | 30 | 4 | 55 | 10 | 0 | 55 | 20 | 36 | Bijoux, inclusions (curiosités) |
| Fluorine | 12 | 10 | 14 | 50 | 0 | 16 | 14 | 4 | 35 | 0 | 55 | 2 | 32 | Fondant de forge, luminescence |
| Amiante | 4 | 7 | 8 | 8 | 0 | 90 | 5 | 15 | 0 | 0 | 0 | 40 | 45 | Isolant extrême (toxique) |
| Phosphorite | 6 | 10 | 9 | 10 | 25 | 22 | 12 | 8 | 8 | 80 | 0 | 4 | 48 | Engrais minéral |

**Fossiles & curiosités souterraines (6) — outil : pioche, compétence Minage — objets de collection, vente aux érudits, déco**

| Matériau | Dur | Den | Val | CMa | Fla | Iso | CÉl | Flo | Lum | Fer | Tra | Éla | Fri | Notes |
|---|--|--|--|--|--|--|--|--|--|--|--|--|--|---|
| Os fossile | 10 | 9 | 15 | 12 | 3 | 20 | 6 | 15 | 0 | 5 | 0 | 6 | 45 | Squelettes géants dans les strates profondes |
| Ammonite | 9 | 9 | 18 | 15 | 0 | 20 | 6 | 12 | 0 | 0 | 0 | 4 | 42 | Spirales fossiles, prisées des érudits |
| Bois pétrifié | 16 | 13 | 14 | 18 | 0 | 22 | 8 | 4 | 0 | 0 | 0 | 3 | 48 | Bois devenu pierre — constructible, esthétique unique |
| Coquillage fossile | 7 | 8 | 8 | 10 | 0 | 22 | 6 | 18 | 0 | 3 | 0 | 4 | 44 | Anciennes mers, trouvé en calcaire |
| Géode | 13 | 11 | 22 | 45 | 0 | 18 | 12 | 4 | 15 | 0 | 20 | 2 | 36 | À briser : contient des cristaux aléatoires |
| Météorite ferreuse | 38 | 20 | 60 | 40 | 0 | 8 | 65 | 1 | 0 | 0 | 0 | 7 | 26 | Fer météorique — rare, forge d'exception |

**Végétaux paramétriques (2 gabarits × 40 essences) — dérivés automatiquement de chaque arbre (B.1)**

| Gabarit | Dur | Den | Val | Fla | Iso | Flo | Éla | Notes |
|---|--|--|--|--|--|--|--|---|
| Feuilles de [essence] | 1 | 1 | 1 | 80 | 40 | 90 | 40 | couleur dérivée de l'essence ; compost/fourrage ; bloc décoratif |
| Pousse de [essence] | 1 | 1 | 3 | 60 | 30 | 85 | 30 | replantable → **sylviculture** : l'arbre repousse (vitesse selon essence, ×2 pour peuplier/eucalyptus) |

**Parties de créatures (6 gabarits × créatures F.3) — drops de mobs, paramétriques (B.1) ; ingrédients d'alchimie (7.7) et de craft**

| Gabarit | Usage principal | Dérivation |
|---|---|---|
| Viande de [créature] | cuisine (7.7) | bonus de potentiel ∝ stats de la source (A.9.1) |
| Peau de [créature] | cuir (tannage, catégorie fibre), alchimie | dureté/isolation ∝ Endurance de la source |
| Os de [créature] | outils/armes primitifs, alchimie, engrais | dureté ∝ Force de la source |
| Dent/croc de [créature] | pointes de flèches, alchimie, bijoux | dureté ∝ niveau de combat |
| Griffe de [créature] | alchimie (Force/Dextérité), outils | dureté ∝ Dextérité |
| Œil de [créature] | alchimie (Perception/vision) | valeur ∝ Perception |

**Météorologiques (2) — apparaissent/disparaissent selon la météo (E.28) ; récoltables**

| Matériau | Dur | Den | Val | CMa | Fla | Iso | CÉl | Flo | Lum | Fer | Tra | Éla | Fri | Notes |
|---|--|--|--|--|--|--|--|--|--|--|--|--|--|---|
| Glace | 6 | 9 | 2 | 20 | 0 | 30 | 25 | 40 | 0 | 0 | 70 | 2 | 5 | transparente, très glissante, fond à la chaleur |
| Neige | 1 | 3 | 1 | 10 | 0 | 60 | 5 | 50 | 0 | 5 | 5 | 30 | 30 | isolante (igloo viable !), fond vite |

**Gemmes & cristaux (10) — outil : pioche, compétence Minage, transformation : Table d'enchantement**

| Matériau | Dur | Den | Val | CMa | Fla | Iso | CÉl | Flo | Lum | Fer | Tra | Éla | Fri |
|---|--|--|--|--|--|--|--|--|--|--|--|--|--|
| Quartz | 20 | 9 | 8 | 45 | 0 | 15 | 25 | 3 | 10 | 0 | 70 | 2 | 30 | générique abordable |
| Améthyste | 22 | 9 | 25 | 75 | 0 | 15 | 45 | 3 | 25 | 0 | 68 | 2 | 30 | équilibre mana/foudre |
| Topaze | 28 | 9 | 30 | 60 | 0 | 10 | 70 | 3 | 14 | 0 | 66 | 2 | 30 | LA gemme de foudre |
| Grenat | 24 | 10 | 18 | 55 | 0 | 12 | 24 | 3 | 10 | 0 | 58 | 2 | 30 | le "budget" du mage |
| Opale | 12 | 7 | 45 | 92 | 0 | 18 | 22 | 4 | 45 | 0 | 55 | 5 | 32 | reine du mana, FRAGILE |
| Jade | 26 | 10 | 38 | 50 | 0 | 35 | 15 | 3 | 8 | 0 | 40 | 25 | 34 | la plus tenace (élastique) |
| Rubis | 27 | 9 | 40 | 78 | 0 | 0 | 25 | 3 | 22 | 0 | 62 | 2 | 30 | affinité feu (iso 0) |
| Saphir | 27 | 9 | 40 | 78 | 0 | 80 | 28 | 3 | 12 | 0 | 66 | 2 | 30 | affinité froid (iso 80) |
| Émeraude | 24 | 9 | 50 | 82 | 0 | 15 | 26 | 3 | 12 | 0 | 64 | 2 | 30 | mana haut, la + précieuse hors diamant |
| Diamant | 40 | 9 | 80 | 55 | 0 | 15 | 12 | 3 | 20 | 0 | 85 | 1 | 28 | dureté inégalée, mana moyen |

*(Colonne "Notes" ajoutée : chaque gemme a désormais un rôle — le choix n'est plus esthétique mais tactique.)*

*(La conductivité de mana des gemmes/métaux nobles est l'interprétation magique du monde — les matériaux restent réels, c'est leur usage qui est fantastique.)*

**Synthétiques (4) — fabriqués en station (pas de récolte)**

| Matériau | Dur | Den | Val | CMa | Fla | Iso | CÉl | Flo | Lum | Fer | Tra | Éla | Fri | Station |
|---|--|--|--|--|--|--|--|--|--|--|--|--|--|---|
| Verre | 8 | 8 | 6 | 20 | 0 | 10 | 15 | 4 | 0 | 0 | 95 | 1 | 25 | Forge (sable) |
| Brique | 18 | 12 | 4 | 5 | 0 | 35 | 10 | 2 | 0 | 0 | 0 | 3 | 50 | Forge (argile) |
| Chaume tressé | 3 | 2 | 2 | 5 | 90 | 65 | 3 | 88 | 0 | 0 | 0 | 55 | 60 | Atelier tissage (paille) |
| Papier | 1 | 1 | 3 | 25 | 95 | 25 | 3 | 90 | 0 | 0 | 15 | 20 | 45 | Scierie (bois) |

### F.1.1 Palette de couleurs des matériaux (hex uniques)

*Chaque hex est unique dans le catalogue. Familles de teintes par catégorie pour la lisibilité (bois = bruns, métaux = gris/métalliques, cristaux = saturés...) ; les nuances proches se départagent en jeu par leur bruit.*

**Bois :** Pin #C8A96E · Sapin #CBB183 · Épicéa #D6BC8A · Mélèze #B98D5C · Cèdre #B57452 · Chêne #8B5A2B · Hêtre #C69C6D · Bouleau #E3CDA4 · Érable #D2A46B · Frêne #CFB489 · Orme #9C7248 · If #A66A3A · Noyer #6B4426 · Cerisier #9E4F32 · Olivier #8A7B4A · Ébène #2B211C · Gaïac #4A3B23 · Acajou #7C3B24 · Teck #8F6236 · Balsa #EFDFBC · Bambou #B9BA6D · Saule #A89A6B · Liège #B08D62 · Peuplier #DCC79B · Tilleul #E8D9B0 · Charme #C2AD85 · Robinier #A98A3F · Châtaignier #93683B · Platane #C79B72 · Aulne #B57B54 · Buis #D9C27E · Cyprès #A28A55 · Séquoia #A0522D · Palmier #C4A05A · Acacia #B4763B · Eucalyptus #A9997A · Pommier #A5643C · Noisetier #C09468 · Bois flotté #B7AC97 · Bois calciné #3A322C

**Métaux :** Cuivre #C26E43 · Étain #B8BCC0 · Zinc #AEB4B8 · Bronze #B08D57 · Laiton #C9A34C · Fer #8E8E93 · Acier #A9ADB3 · Acier trempé #7E848D · Argent #D9DCE1 · Or #E8C34A · Platine #E4E6E9 · Plomb #5F6470 · Nickel #B9B6A8 · Cobalt #4A5E8F · Titane #9FA8B5 · Tungstène #55585F · Aluminium #CED3D6 · Chrome #C4CBD4 · Manganèse #8A8290 · Bismuth #B78CA8 · Antimoine #9A9AA6

**Roches :** Pierre #9B9B93 · Granit #A79E96 · Granit noir #45434A · Diorite #C5C2BB · Andésite #8A8A82 · Calcaire #D6CDB4 · Dolomie #CFC4A6 · Craie #EFEBDD · Marbre #E7E3DC · Quartzite #D8CFC7 · Schiste #6E7276 · Gneiss #918878 · Basalte #4F4F52 · Tuf volcanique #B5A48C · Pierre ponce #C9C3B6 · Obsidienne #1E1B24 · Silex #6B655C · Grès #D2B285 · Ardoise #5A616B · Gypse #E9E2D2 · Rhyolite #C79C8A · Péridotite #5E6B4E · Serpentinite #5E7D62 · Travertin #DDC9A6 · Conglomérat #AF9C82 · Brèche volcanique #8D6E5C · Kimberlite #566068 · Calcite #EFE8DA

**Terres :** Terre #6E4F31 · Terre fertile #4E3A22 · Tourbe #3F3428 · Sable #E4D3A1 · Argile #B0764F · Gravier #A29A8D

**Végétaux/fibres :** Lin #E9E2C8 · Coton #F5F1E6 · Paille #E5CE7E · Chanvre #C9BE93 · Laine #EDE6D6 · Soie #F2EBDD · Cuir #8A5A33 · Fourrure #A9885E

**Liquides :** Eau #3F76B8 · Eau salée #2E6494 · Lave #E2531F · Huile #6E5B23 · Goudron #26221E · Boue #5C4A35 · Sève #C79038

**Minéraux :** Houille #26262A · Lignite #423A32 · Anthracite #17171C · Soufre #E8D33F · Salpêtre #E5E0CB · Sel gemme #F0E8E0 · Graphite #4B4E55 · Mica #C7B98F · Pyrite #C9A83C · Malachite #2E8B57 · Argile réfractaire #C8A182 · Guano #8F8358 · Tourbe compactée #4A3E2E · Bitume #1C1A18 · Cinabre #B02A1E · Ocre #C9862B · Lapis-lazuli #26529C · Turquoise #40B5AD · Ambre #E0A030 · Fluorine #7FD48A · Amiante #C4C8BE · Phosphorite #97917B

**Météorologiques :** Glace #B8E0EE · Neige #FAFBFD

**Fossiles :** Os fossile #D8CCAE · Ammonite #B79C74 · Bois pétrifié #7A6A58 · Coquillage fossile #D9CDBD · Géode #93A0B6 · Météorite ferreuse #443F45

**Gemmes :** Quartz #E8E4EC · Améthyste #8A4FBF · Topaze #E8B33C · Grenat #8E1F2F · Opale #DCE8E4 · Jade #3D9B6B · Rubis #C81E3C · Saphir #1E4FA8 · Émeraude #1F9E5A · Diamant #EDF5F7

**Synthétiques :** Verre #C6DEE4 · Brique #A9502F · Chaume tressé #D3B76A · Papier #F3EEDF

### F.2 Modules de compétences (48)

*Format : nom — type (effet/modificateur/déclencheur) — coût mana base — effet. Dés : notation E.3.*

**Grimoires — Feu :** Projectile de feu (effet, 8, 2d6 feu à distance) · Nova ardente (effet, 18, 3d6 feu en cercle 3 blocs) · Trait incendiaire (effet, 12, 1d4 + statut brûlure 3 tours) · Mains brûlantes (effet, 6, cône court 2d4) · Cœur de braise (modificateur, +4, le module suivant enflamme le sol 5 s)
**Eau/Glace :** Trait de givre (effet, 8, 2d4 + ralentissement) · Prison de glace (effet, 16, immobilise 1d4+1 tours, jet de Force pour briser) · Mur de glace (effet, 14, blocs de glace temporaires — matériau réel, friction 5) · Soin des eaux (effet, 12, rend 2d6 PV) · Brume (effet, 10, réduit la détection dans une zone)
**Foudre :** Éclair (effet, 10, 2d8, ×conductivité armure cible A.4.5) · Chaîne (modificateur, +6, l'effet saute à 1d3 cibles proches) · Choc statique (effet, 5, 1d4 + interrompt l'action en cours) · Orage local (effet, 25, 1d8/tour zone 5 blocs, 3 tours)
**Terre :** Projectile rocheux (effet, 8, 2d6 contondant) · Pique de pierre (effet, 12, 3d4 depuis le sol, ignore bouclier) · Peau de pierre (effet, 14, +2d4 dés d'armure 5 tours) · Séisme mineur (effet, 22, 2d6 zone + jet ou chute) · Façonnage (effet, 10, déplace 1 bloc de terre/sable — outil de terrassement magique)
**Vie :** Soin mineur (effet, 8, 3d4 PV) · Régénération (effet, 14, 1d4 PV/tour, 5 tours) · Croissance (effet, 12, accélère une culture d'1 stade) · Purge (effet, 10, retire 1 statut négatif) · Lien vital (effet, 16, transfère ses PV à un allié 1:1)
**Arcane :** Trait de mana (effet, 5, 1d8 brut) · Bouclier arcanique (effet, 12, absorbe 2d8 dégâts) · Marque (déclencheur, 6, le prochain module se déclenche sur la cible marquée à l'impact suivant) · Double incantation (modificateur, +8, répète le module suivant) · Concentration (modificateur, +4, le module suivant +1 dé)
**Espace :** Pas éclipsé (effet, 10, téléporte 5 blocs en vue) · Échange (effet, 14, échange sa position avec la cible) · Portée étendue (modificateur, +5, portée ×2 du module suivant) · Rappel (effet, 30, téléporte au lit/claim — cooldown 1 jour) · Poche dimensionnelle (effet, 20, +30 capacité de poids 10 min)
**Corruption :** Sang pour puissance (modificateur, +0, le module suivant coûte des PV au lieu du mana, 2:1) · Drain (effet, 12, 2d4 + soigne la moitié infligée) · Terreur (effet, 14, jet de Volonté ou la cible fuit 1d4 tours) · Contagion (modificateur, +8, les statuts du module suivant se propagent aux ennemis adjacents) · Appel corrompu (effet, 28, invoque 1 créature corrompue temporaire alliée)

**Manuels — Frappes :** Frappe lourde (effet, 6, +1d6 au prochain coup) · Fente (effet, 8, attaque + avance d'1 bloc) · Balayage (effet, 12, touche toutes les cibles adjacentes) · Brise-garde (effet, 10, la cible perd ses dés d'armure 2 tours) · Exécution (effet, 15, +2d6 si cible < 30 % PV)
**Postures :** Garde de fer (effet, 8, +1d6 armure tant que la posture tient) · Posture du vent (effet, 8, +0.5 att/10 ticks, -1d4 armure) · Ancrage (effet, 6, immunité aux projections/recul) · Duelliste (effet, 10, +2 toucher contre une cible unique désignée)
**Techniques :** Pas de côté (effet, 6, esquive-déplacement 2 blocs) · Contre (déclencheur, 10, riposte automatique au prochain coup esquivé) · Charge (effet, 12, rue de 4 blocs + 1d6 et projection) · Désarmement (effet, 14, jet opposé, l'arme de la cible tombe)
**Maîtrise :** Coups jumeaux (modificateur, +8, la frappe suivante frappe 2 fois à -2 toucher) · Allonge (modificateur, +5, portée +1 bloc sur la frappe suivante) · Économie de geste (modificateur, +4, la frappe suivante coûte 2 ticks de moins) · Impact (modificateur, +6, la frappe suivante projette d'1d3 blocs)

### F.3 Créatures et PNJ (34 — animaux réels et humains uniquement)

*Format : nom — squelette — niv. combat approx — profil IA — recrutable — notes. Tous suivent le schéma B.5 ; les civils ont des jobs_compatible. Pas de créatures fantastiques pour l'instant : la menace vient des bêtes, des humains hostiles et de l'environnement.*

**Civils (humains, villages) :** Villageois (nv 3, civil, relation 60, jobs fermier/vendeur) · Fermier (nv 3, civil, relation 55, agriculture 15) · Forgeron (nv 6, civil, relation 65, forge 25) · Marchand ambulant (nv 5, civil, relation 70, négociation 20, caravanes inter-villages — pathfinding global E.16) · Garde de village (nv 12, garde, relation 75) · Prêtre de sanctuaire (nv 8, civil, relation 80, ressuscite les compagnons E.17) · Maître de guilde (nv 20, civil, jamais) · Érudit (nv 4, civil, relation 60, lecture 30) · Tavernier (nv 5, civil, relation 65) · Chasseur (nv 9, civil, relation 60, arc 18, dressage 12) · Roi/Reine (nv 25, civil+escorte, dressage DD élevé — capturable, 14.2)
**Humains hostiles :** Bandit (nv 10, hostile, relation — se rend si dominé) · Chef de bande (nv 16, hostile, relation, camps 3.1) · Braconnier (nv 8, hostile si surpris, relation) · Pillard (nv 12, assaillant, relation, raids E.7) · Déserteur (nv 11, hostile, relation) · Ermite (nv 14, neutre→hostile si dérangé, relation 85, donjons/ruines — gardien humain des trésors)
**Plaines/forêts tempérées :** Loup (quadrupède, nv 6, bete_sauvage, meutes 1d4+1, dressage) · Sanglier (quadrupède, nv 8, bete_sauvage acculée, dressage) · Cerf (quadrupède, nv 3, fuit, dressage) · Renard (quadrupède, nv 3, fuit, dressage) · Essaim d'abeilles (amorphe, nv 4, hostile près de la ruche, jamais — miel récoltable)
**Désert :** Scorpion (quadrupède bas, nv 7, hostile, dressage, statut poison) · Vautour (volant, nv 5, hostile si blessé détecté, dressage) · Chameau sauvage (quadrupède, nv 6, fuit, dressage — monture endurante) · Nomade (humain, nv 9, civil, relation, marchand itinérant)
**Toundra/taïga :** Ours polaire (quadrupède, nv 18, bete_sauvage, dressage, fourrure isolante) · Loup blanc (quadrupède, nv 8, meutes, dressage) · Renne (quadrupède, nv 4, fuit, dressage/élevage) · Morse (quadrupède, nv 12, bete_sauvage sur la côte, dressage)
**Marécage :** Crocodile (quadrupède bas, nv 14, embuscade aquatique, dressage) · Nuée de moustiques (amorphe, nv 4, hostile, jamais, dégâts continus faibles + risque infection) · Serpent venimeux (amorphe, nv 8, hostile si approché, dressage, poison)
**Montagne :** Aigle (volant, nv 7, bete_sauvage, dressage) · Ours brun (quadrupède, nv 16, bete_sauvage, dressage) · Bouquetin (quadrupède, nv 4, fuit, dressage/élevage) · Lynx (quadrupède, nv 9, embuscade, dressage)

*Note : les niches "créatures de donjon" sont occupées par les humains hostiles (bandits, pillards, ermites) et les bêtes tanières (ours, loups) — un donjon est une ruine investie, pas une crypte magique. Les créatures fantastiques pourront être réintroduites plus tard comme contenu des zones à haute corruption sans toucher aux systèmes.*

**Drop rare universel — la statue 1:1 :** toute créature a une faible chance (défaut 0.5 %, pondérable par créature) de dropper une **statue d'elle-même à l'échelle 1:1** — un meuble décoratif (posable, F.6-like) généré automatiquement : le modèle assemblé exact de la créature (ses parties tirées, 12/12.1), **recolorisé en pierre** via le remapping de palette existant (9.1/G.5 — zéro asset à produire). Trophée de chasse ultime, objet de collection et de prestige (humeur/déco), valeur de vente ∝ niveau de la créature.

### F.4 Statuts (`data/status_effects/`, 14)

Brûlure (1d4 feu/tour, 3 tours, retiré par eau) · Ralentissement (-30 % vitesse/coûts ticks +30 %) · Gel (immobilisé, jet de Force/tour) · Poison (1d3/tour jusqu'à purge, cumule) · Saignement (1d4/tour, stoppé par soin ou bandage) · Étourdi (perd son prochain tour de décision) · Confusion (30 % d'agir au hasard) · Terreur (fuit la source) · Infection (Endurance -2/jour jusqu'à soin — maladie longue) · Affaibli (-20 % stats, post-résurrection E.17) · Régénération (+1d4 PV/tour) · Peau de pierre (+2d4 armure) · Hâte (coûts ticks -20 %) · Béni (+1 à tous les jets, sanctuaires)

### F.5 Nourriture et consommables (18)

Pain (+20 faim) · Ragoût (+35 faim, +5 PV) · Viande grillée (+30 faim) · Viande crue (+15 faim, 20 % infection) · Poisson grillé (+25 faim) · Baies (+8 faim) · Champignon bleu (+5 faim, +10 mana) · Fruit de mana (+10 faim, +25 mana) · Ration de voyage (+25 faim, ne périme pas) · Ration moisie (+15 faim, 30 % poison) · Fiole de soin (2d6 PV) · Grande fiole de soin (4d6 PV) · Essence de mana (+30 mana instantané) · Antidote (purge poison) · Bandage (stoppe saignement, +1d4 PV) · Élixir de hâte (statut Hâte 10 tours) · Huile d'arme (prochain combat : +1d4 feu par coup) · Torche (item main : luminosité 70, consommée en 10 min)

### F.6 Meubles (16)

*Tous sculptables (table meubles) ou craftables via recettes simples ; requis pour l'habitat (7.5) et les POI du graphe E.18.*

Lit (dormir, assignation PNJ) · Lit de paille (idem, malus humeur -3) · Table · Chaise · Coffre (stockage 30 slots) · Grand coffre (60) · Garde-manger (stock nourriture PNJ, E.15) · Étal de vente (boutique passive 7.1, 12 slots) · Torchère (luminosité 80, fixe) · Lanterne de cristal (luminosité 95) · Cheminée (chaleur : annule malus de froid dans la pièce) · Bibliothèque (stocke les livres, +5 % réussite de lecture à proximité) · Râtelier d'armes (stockage + déco) · Tapis (humeur +2 dans la pièce) · Trophée (tête de créature vaincue, humeur/prestige) · Autel domestique (résurrection E.17 à domicile, coût ×1.5)

### F.7 Effets d'équipement types (pour la génération de loot, A.4.4)

*Pools par slot pour le générateur : anneaux/amulettes tirent 1-2 effets, armes/armures 0-1.*

skill +2..+6 : Méditation, Esquive, Discrétion, Négociation, Minage, Forge, Leadership, Dressage, Lecture, Athlétisme · stat +1..+3 : les 6 stats · mechanic : capacite_poids +10..+40, faim_vitesse ×0.7..0.9, surchauffe_mult ×0.6..0.9, vitesse_deplacement ×1.05..1.15, regen_sante +50..100 % · grant_tag : detection_filons, detection_tresors (chasseurs de trésor !), vision_nocturne, respiration_aquatique, pas_silencieux, immunite_poison

### F.8 Plantes non-arbres (22 — réelles, récolte Herboristerie/Agriculture)

**Cultures (8, cultivables en champs 7.4) :** Blé (pain), Orge (bière/soupe), Carotte, Pomme de terre, Chou, Oignon, Citrouille, Tomate — chaque culture a nutrition + bonus de potentiel propres (données `data/plants/`).
**Buissons & vignes (4) :** Framboisier, Myrtillier, Vigne (raisin/vin via alambic), Houblon (bière).
**Herbes médicinales/alchimiques (6) :** Camomille (potions de calme/sommeil), Menthe (fraîcheur — résistance chaleur), Sauge (mana), Achillée (soin/saignement), Ortie (fibres + potions de résistance), Belladone (poisons — illégale dans certains royaumes, E.26 !).
**Champignons (2) :** Champignon des prés (comestible), Amanite (toxique — poison d'alchimie).
**Décoratives (2) :** Fleurs sauvages (teintures + humeur des pièces), Roseau (vannerie, chaume, papier).

### F.9 Potions de départ (12 — alchimie, 7.7)

Potion de soin (2d6 PV, instantané) · de Force/Dextérité/Endurance/Volonté/Perception/Charisme (+3 stat, 10 min) · de résistance au feu / au froid (isolation +40, 10 min) · de vision nocturne (tag, 10 min) · de respiration aquatique (tag, 5 min) · Antipoison (purge + immunité 5 min) · Poison de lame (applique le statut Poison aux attaques, 5 min — illégal dans la plupart des royaumes).


---

## Annexe G — Stratégie d'optimisation (fait autorité sur les questions de performance)

*Consolidation des décisions de performance. Règle d'or : mesurer avant d'optimiser (profiler Godot), mais ARCHITECTURER pour l'optimisation dès le jour 1 — les points ci-dessous sont ceux qu'on ne peut pas rattraper après coup. E.14 (budgets) reste valide ; G détaille le "comment".*

### G.1 Principes transversaux

```
- GDScript TYPÉ partout (annotations de types : gain réel d'interpréteur,
  gratuit). Chemins chauds identifiés au profilage → GDExtension/Rust,
  jamais préventivement. Candidats probables : meshing, éclairage,
  bruit de génération, A*.
- AUCUNE allocation dans les boucles par tick : pools d'objets
  (entités, projectiles, particules), tableaux préalloués réutilisés,
  PackedByteArray/PackedInt32Array pour les données voxel (jamais des
  Array de Variant).
- TIME-SLICING : chaque système lourd a un budget par tick et une file
  de travail reportable (meshing, éclairage, nav-grille, pathfinding,
  liquides, détection de pièces). Rien ne "finit coûte que coûte" dans
  la même frame.
- Threads : génération, meshing, éclairage et sauvegarde HORS thread
  principal (WorkerThreadPool Godot). Le thread principal ne fait que :
  tick de gameplay, upload de meshes prêts, rendu, UI.
- Tout est SEEDÉ et déterministe → jamais besoin de stocker ce qui est
  regénérable (principe déjà acté E.10, il vaut pour tout).
```

### G.2 Voxels : mémoire et meshing

```
STOCKAGE — chunk 16³ : PackedByteArray de 2 octets/bloc (id matériau,
  0 = air) = 8 Ko. Chunks 100 % air ou 100 % même matériau : stockés
  comme constante (1 entrée), pas de tableau — la majorité du monde
  (ciel, sous-sol profond) ne coûte presque rien.
SUBDIVISION — amendé 2026-07-21 (implémentation validée) : GRILLE PLATE
  8×8×8 par bloc subdivisé (PackedInt32Array de 512 cellules de 4 px),
  structure séparée (dictionnaire chunk-local index_bloc → grille), PAS
  l'octree initialement esquissé — avec 3 niveaux seulement, la grille
  plate est plus rapide en GDScript (pas de pointeurs) pour le même
  budget mémoire borné (2 Ko × 512 blocs max). GARDE-FOU : budget de subdivision
  par chunk (défaut : 512 blocs subdivisés/chunk, message clair au
  joueur si atteint) — évite qu'une méga-sculpture fine fasse exploser
  mémoire et meshing. À 4px (amendé 2026-07-19 : chaîne 32→16→8→4),
  un bloc = jusqu'à 512 sous-voxels : le greedy meshing fusionne les
  sous-voxels de même matériau, et les faces coplanaires SONT fusionnées
  à travers les résolutions (un mur mixte 32px/8px ne génère pas de couture).
MESHING — greedy meshing par chunk, en thread, budget 2 chunks
  uploadés/frame max. Un seul matériau de surface Godot par chunk
  (atlas/array de "textures" générées) → 1 draw call/chunk opaque
  + 1 transparent (A.4.5).
TEXTURES DE BRUIT — jamais stockées par bloc : le bruit par voxel
  (9.x) est généré EN SHADER depuis (world_pos, id_matériau, seed) —
  zéro mémoire texture par bloc, variation infinie gratuite.
LOD DE DISTANCE (rendu) — au-delà de N chunks (défaut 4) : les blocs
  subdivisés sont rendus à la résolution du bloc de base (32px) (couleur moyenne de
  l'octree, précalculée à la modification) ; au-delà de 8 chunks :
  chunks fusionnés 2x2x2 en meshes simplifiés. La subdivision fine
  n'est jamais meshée au loin — c'est LA parade au coût du 4px.
ÉVICTION — chunks hors rayon : mesh libéré immédiatement, données
  gardées en cache LRU (256 chunks), puis sérialisées si modifiées /
  jetées si vierges (regénérables par seed).
```

### G.3 Éclairage et transparence

```
Propagation 0-15 par flood fill INCRÉMENTAL : les mises à jour de
lumière sont des deltas locaux (pose/destruction de bloc ou de source),
jamais un recalcul de chunk complet ; file dédiée, budget par tick,
en thread avec le meshing (la lumière est cuite dans les vertex).
Lumière du jour : colonne skylight précalculée à la génération,
propagée pareil. Le cycle jour/nuit (E.21) module en SHADER (uniform
global), pas en re-propagation — changer l'heure ne coûte rien.
Transparence : passe séparée, triée par chunk seulement (pas par face).
```

### G.4 Génération procédurale

```
FastNoiseLite (natif Godot, C++) pour toutes les couches — jamais de
bruit en GDScript. Le terrain spectaculaire (E.2 : ridged, domain
warping, terrasses) reste du bruit par colonne — même coût que du
terrain plat, seule la composition des couches change. Le domain
warping double les évaluations de bruit sur x/z : rester à 1 niveau
de warp (pas de warp imbriqué). Les 8 couches sont échantillonnées PAR COLONNE
(x,z) une fois, mises en cache par chunk-colonne ; le remplissage 3D
ne réévalue pas le bruit 2D. Le bruit 3D de cavernes est évalué par
pas de 4 blocs et interpolé (trilinéaire) — ×64 moins d'appels,
différence invisible. Génération complète en thread, par anneaux de
priorité autour du joueur. Les POI/villages (E.2) se génèrent à la
première visite de la cellule uniquement (hash déterministe).
```

### G.5 Entités, IA, pathfinding

```
Budgets (E.14) : ~64 entités niveau 1 (plein). Au-delà du budget dans
une zone : les spawns s'arrêtent (pas de despawn brutal).
IA : décisions échelonnées (E.16) — jamais plus de ~6 décisions
utility/tick. Perception : requêtes spatiales via grille de hachage
(cellules 8 blocs), pas de distance N² entre entités.
Pathfinding : file globale, 2 requêtes A* résolues/tick max, résultats
cachés et partagés (deux gardes vers le même point réutilisent le
chemin). Nav-grille par chunk reconstruite PARESSEUSEMENT (au premier
besoin après invalidation), en thread.
Rendu des créatures : les parties .vox (12) sont des meshes PARTAGÉS
(bibliothèque = ressources uniques) ; recolorisation par palette en
shader (paramètre d'instance), pas de duplication de mesh —
100 villageois = ~6 meshes distincts en mémoire. Animations simples
par transform de parties (pivots 12.1), pas de skinning.
```

### G.6 Simulation du monde

```
Liquides : file active uniquement (E.22) — un lac stable coûte 0.
Cultures/faim PNJ/timers : PAS de per-tick — chaque instance stocke
  son échéance en ticks et s'enregistre dans une TIMER WHEEL globale
  (le tick ne visite que ce qui échoit ce tick). 10 000 cultures
  plantées = coût nul entre deux échéances.
Corruption (E.20), régénération (3.3), raids (E.7) : passages
  hebdomadaires sur listes filtrées (cellules à delta/foyer) — déjà
  bon marché par conception.
Boutiques/abstraction (E.6/E.8) : résolution par formules à
  l'échéance ou au retour du joueur — jamais de simulation de fond.
Détection de pièces (E.5) : throttlée (1 revalidation/s max par claim),
  flood fill borné, en thread.
```

### G.7 Réseau et sauvegarde

```
Chunks vers les clients : envoyés compressés (zstd sur le
PackedByteArray + octrees), puis uniquement des DELTAS (liste de
mutations) — jamais de renvoi complet. Mutations groupées par tick
(batching) en un seul paquet fiable.
Positions d'entités : quantifiées (10 cm), envoyées seulement si
changées, interpolées côté client.
Sauvegarde : sérialisation en thread, écriture atomique (E.10) ;
l'autosave ne bloque jamais le jeu (copie-sur-écriture des
structures modifiées pendant la sérialisation).
```

### G.8 Ordre de vérification au développement

```
Chaque étape de D.3 a son critère de perf AVANT de passer à la
suivante (sur machine moyenne cible) :
  1-2. Génération+rendu : 60 fps en vol rapide, rayon 8 chunks.
  3.   Casser/poser : aucune frame > 16 ms sur mutation.
  4.   Subdivision : une façade de 64 blocs 4px meshée < 4 ms.
  6.   50 créatures actives : tick < 8 ms.
  8.   2 joueurs LAN : mutation visible < 100 ms chez l'autre.
Un critère raté = on optimise AVANT d'empiler le système suivant.
```

### G.9 Stratification verticale (données)

```
data/strata.json : liste ordonnée { "material", "y_max", "transition" }
  — évaluée par colonne pendant la génération (G.4), bruit de
  transition (±12 blocs) pour des frontières organiques, surchargée
  par les biomes (un volcan fait remonter le basalte) et percée par
  les cavernes/filons. Coût : nul (une lookup par bloc généré).
Défaut : terre/grès 0→-12, calcaire -12→-55, ardoise -55→-80,
  pierre -80→-160, basalte -160→-260, granit -260→-380,
  granit noir -380→fond. Poches locales (bruit dédié) : ±1 strate.

MINERAIS PAR PROFONDEUR — les filons (couche ressources, B.8) sont
filtrés par bande de profondeur : plus c'est profond, meilleur c'est
(data/ore_bands.json, cf. valeurs F.1) :
  0 → -55    : cuivre, étain, zinc, lignite, sel gemme, argile réfract.,
               ocre, tourbe compactée, turquoise, ambre (côtes/forêts)
  -30 → -120 : fer, nickel, manganèse, houille, pyrite, malachite,
               soufre, mica, salpêtre, quartz, bitume, fluorine,
               phosphorite, calcite    (l'ère du fer)
  -80 → -220 : or, argent, cobalt, antimoine, anthracite, graphite,
               cinabre, améthyste, topaze, grenat, lapis-lazuli,
               géodes                  (richesse + acier)
  -160 → -320: platine, titane, chrome, bismuth, opale, jade, rubis,
               saphir, émeraude, kimberlite (roche-hôte du diamant)
  -280 → fond: tungstène, diamant (dans la kimberlite) + filons GÉANTS
FOSSILES : os/ammonites/coquillages dans les roches sédimentaires
  (calcaire, schiste, grès) toutes profondeurs ; bois pétrifié dans
  le tuf ; météorite ferreuse : poches ultra-rares à toute profondeur
  + sites d'impact de surface (POI rare).
Le guano se trouve dans les cavernes peu profondes (engrais, 7.4).
La kimberlite est le SIGNAL du diamant (le prospecteur avisé la
reconnaît — et la guilde des Prospecteurs vend cette information).
Les bandes se CHEVAUCHENT (transitions douces) ; densité et taille des
filons augmentent avec la profondeur DANS chaque bande (un filon de
fer à -100 est plus gros qu'à -40). La couche danger/corruption (3.0)
s'intensifie aussi avec la profondeur (spawns souterrains plus durs) :
le risque, la dureté de la roche et la valeur du minerai montent
ensemble — trois pressions alignées sur la même verticale.
Les ROCHES suivent aussi des variantes latérales (diorite/andésite/
gneiss remplacent localement granit/basalte par bruit ; quartzite près
des filons de quartz ; tuf/ponce près des zones volcaniques 3.0) —
la géologie varie horizontalement ET verticalement.
```

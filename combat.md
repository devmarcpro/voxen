 Faisabilité d'un système de combat à la mount and blade dans mon jeu ? Donc arme qui tape selon la direction

Techniquement et en termes de game design, c'est totalement faisable et c'est même une excellente idée. Le système de combat à la Mount & Blade (ou Mordhau / Chivalry) s'intègre parfaitement avec ta nouvelle orientation RPG / Aventurier nomade. Cela remplace le clic frénétique des jeux voxel classiques par un gameplay basé sur le timing, la distance (spacing) et la gestion de l'endurance.

Puisque ton jeu tourne sur Godot 4, voici l'analyse de faisabilité technique, les frictions liées au monde voxel, et la méthode d'implémentation.
1. Faisabilité Technique (Godot 4) : Très Haute

L'architecture d'un tel système est en réalité assez légère et ne viendra pas surcharger ton TickManager ou ton streaming de chunks.

    Lecture des Inputs (La Rose des Vents) : Au clic de la souris, le jeu ne lance pas l'attaque tout de suite. Il lit le event.relative (le mouvement de la souris) dans les millisecondes qui suivent le clic. Si le delta X est fortement positif, le jeu verrouille une "Attaque Droite". Si c'est Y négatif, une "Attaque Haute", etc.

    Détection des Coups (Hitboxes) : Dans un jeu voxel, les collisions du terrain sont une grille, mais tes entités (joueur, monstres) utiliseront des CharacterBody3D avec des capsules de collision classiques. Pour l'arme, tu n'utilises pas le moteur physique lourd, mais un Raycast balayé (ShapeCast3D ou tir de multiples Raycasts le long de la lame à chaque frame de l'animation) pour détecter exactement quelle partie de l'ennemi a été touchée.

    Les Outils Extrudés : Puisque tes armes sont des sprites 2D extrudés en 3D (Manche + Tête), tu peux facilement placer des "Points d'attache" (Marker3D) sur la pointe et la base de la tête de l'arme pour générer ces raycasts dynamiquement, peu importe la forme de l'outil généré.

2. Le Grand Piège : Le Terrain Voxel vs Le Jeu de Jambes

C'est ici que se trouve le vrai défi de conception. Le combat de Mount & Blade repose à 50% sur les coups de souris, et à 50% sur le jeu de jambes (reculer pour esquiver, avancer pour punir).

    Le problème du "Staircase" : Dans un monde voxel, le sol n'est pas lisse, il est fait de blocs d'un mètre de haut. Si ton joueur doit sauter (barre espace) pour reculer sur un bloc surélevé, le combat fluide est mort.

    La Solution Obligatoire (Auto-Step) : Ton contrôleur de personnage (KinematicBody) doit impérativement inclure une mécanique de franchissement automatique (Step-up). Le joueur doit pouvoir glisser sur les blocs d'une hauteur de 1 sans avoir à sauter, lissant ainsi ses déplacements en combat pour qu'il puisse se concentrer sur son arme, même sur un terrain accidenté.

3. Synergies avec tes Systèmes Actuels

Ce système de combat valorise énormément les mécaniques que tu as déjà posées dans ton GDD :

    Poids et Inertie : Tu as prévu des matériaux denses (Plomb, Obsidienne). Si le joueur forge une tête de marteau en plomb, le système directionnel lira cette donnée : l'attaque de haut en bas infligera des dégâts colossaux, mais la vitesse de l'animation (Wind-up) sera extrêmement lente, laissant le joueur vulnérable.

    Allonge (Reach) : Le sprite du manche en bois détermine la longueur du modèle 3D. Un long manche en frêne permet des attaques d'estoc (vers l'avant) qui touchent loin, idéales pour garder les monstres de la "Dimension Malfaisante" à distance.

    Dégâts de Zone vs Précision : Une attaque horizontale (gauche à droite) balaiera une large zone devant le joueur (utile contre les meutes), tandis qu'une attaque verticale (haut en bas) ou d'estoc sera parfaite pour éviter de frapper un mur dans un donjon étroit.

Bilan : Ce système demande de la rigueur sur les animations (AnimationTree avec Blend Spaces dans Godot) et sur le contrôleur de mouvement, mais son impact sur les performances est négligeable et il donne une identité immédiate ("Hardcore RPG") à ton jeu.

Veux-tu que je te fournisse la logique mathématique en GDScript pour capturer la direction de la souris et déclencher les bonnes attaques, ou préfères-tu qu'on aborde la structure de l'AnimationTree nécessaire pour ce système ?

Et si pour la génération du terrain on rajouter des blocs subdivisé pour permettre au joueur de se déplacer sans devoir constamment sauter, quel impact sur les performances

C'est une excellente question de design, mais c'est aussi un piège technique redoutable.

D'après l'audit de Claude, ton moteur possède déjà la technologie pour le faire : tes fichiers chunk_data.gd et subdiv_grid.gd gèrent des sous-grilles 8³. Actuellement, tu les utilises de manière "éparse" (probablement pour que le joueur crafte des meubles ou des micro-blocs).

Cependant, utiliser ces sous-grilles pour lisser généralement le terrain lors de la génération procédurale aura un impact dévastateur sur tes performances, en particulier sur ta cible matérielle (Intel UHD 620). Voici pourquoi, et voici la solution utilisée par l'industrie pour contourner ce problème.
1. L'Impact Mémoire (La fin de l'éparsité)

Actuellement, ton architecture est ultra-optimisée car un bloc d'air ou un bloc de pierre plein ne pèse que 2 octets. La sous-grille (qui pèse beaucoup plus lourd en mémoire) n'est instanciée que si le joueur sculpte un bloc spécifique.

    Si tu lisses le terrain : Absolument tous les blocs situés à la surface de ton monde deviendront des blocs subdivisés. Tu vas passer d'une architecture "éparse" (quelques blocs par chunk) à une architecture "dense" (des centaines de blocs subdivisés par chunk). La consommation de RAM va exploser, potentiellement au-delà de ce qu'une machine modeste peut supporter.

2. L'Impact GPU (La mort du Greedy Meshing)

Ton chunk_mesher.gd utilise le "Greedy Meshing". C'est un algorithme magique qui fusionne les faces planes adjacentes. Une plaine plate de 16x16 blocs n'est pas dessinée avec 256 petits carrés, mais avec 2 gros triangles. C'est ce qui sauve ton GPU.

    Si tu lisses le terrain : Le Greedy Meshing est brisé. La surface ne sera plus une plaine parfaite, mais une multitude de micro-pentes et d'escaliers en sous-voxels. Ton maillage va cracher des milliers de minuscules triangles par chunk. Ton Intel UHD 620 va s'effondrer.

3. L'Impact CPU (Temps de génération)

Ton generate_chunk() prend déjà environ 5 ms par chunk. Pour générer un terrain lissé en sous-voxels, l'algorithme de bruit (Perlin/Simplex) devra échantillonner la surface avec une précision 8 fois supérieure pour décider quels micro-blocs placer ou retirer. Le temps de génération du monde va s'allonger drastiquement, causant du lag lors de l'exploration (stuttering).
La Vraie Solution : L'Auto-Step (Le code, pas les polygones)

Pour que le joueur puisse se déplacer de manière fluide sans sauter, la solution n'est pas de modifier la géométrie du monde. La solution est de modifier le code physique du joueur. C'est la méthode utilisée par Minecraft (via les chevaux ou certains mods) et tous les FPS rétro.

Au lieu de faire des pentes en sous-voxels, tu implémentes un système d'Auto-Step (franchissement automatique) sur ton CharacterBody3D.

Comment ça fonctionne mécaniquement :

    Détection : Quand le joueur avance et heurte un mur d'un bloc de haut, le code tire un Raycast (rayon) depuis ses "genoux" vers l'avant, puis un autre vers le bas.

    Téléportation fluide : Si le code détecte que l'obstacle ne fait qu'un seul bloc de haut et que le bloc du dessus est vide (de l'air), il n'arrête pas le joueur. Il ajoute instantanément +1 en Y à la position du joueur (ou utilise un lissage très rapide, un Lerp).

    Résultat : Le terrain reste fait de gros cubes (0 impact mémoire, 0 impact GPU, Greedy Meshing conservé), mais le joueur "glisse" sur les collines d'un mètre de haut de manière totalement fluide, permettant le combat tactique à la Mount & Blade que tu souhaites.

Veux-tu que nous rédigions le code GDScript de cet Auto-Step ?

Donne moi une liste d'armes pour notre système de combat à la mount and blade

Voici une liste d'armes conçues spécifiquement pour exploiter ton système de combat directionnel à la Mount & Blade, tout en s'intégrant parfaitement à ton architecture voxel modulaire (Manche + Tête) et à tes matériaux systémiques.

Pour chaque arme, j'ai précisé son Gameplay Directionnel (quelles attaques sont favorisées) et ses Synergies Systémiques (comment elle réagit avec la physique, la chimie ou la magie).
Catégorie 1 : Les Épées (Polyvalence et Maîtrise)

Les épées utilisent le sprite "Tête" le plus long, extrudé pour donner de l'allonge. Elles sont équilibrées.
1. L’Épée Longue (Une ou deux mains)

    Gameplay : L'arme polyvalente par excellence.

        Estoc (Haut/Milieu) : Très rapide, perce les armures légères, allonge maximale.

        Taille (Gauche/Droite) : Dégâts modérés, bon balayage contre les meutes.

    Synergie Matériaux : Forgée en Acier, elle est durable. Forgée en Obsidienne, elle est ultra-tranchante mais se brise (Durabilité 0 instantanée) si elle bloque une attaque lourde ou frappe de la roche.

2. La Rapière / Estoc (Une main)

    Gameplay : Vitesse pure.

        Estoc (Toutes directions) : Inflige 90% des dégâts via la pointe. Le "Wind-up" (temps de préparation) est quasi nul. Idéal pour interrompre l'adversaire.

        Taille : Inflige des dégâts négligeables (coup de fouet).

    Synergie Systémique : Parfaite pour le style "Nomade". Très légère (faible poids en inventaire, faible consommation d'endurance).

3. La Zweihänder / Espadon (Deux mains lourdes)

    Gameplay : Le contrôle de zone.

        Taille (Gauche/Droite) : L'animation est lente mais le balayage est immense. Possède une propriété "Transpercer" : le rayon de détection ne s'arrête pas au premier ennemi touché, permettant de faucher 3 monstres d'un coup.

        Garde (Directionnelle) : Son poids lui permet de bloquer sans subir de "Stagger" (étourdissement) même face à des armes de siège.

    Synergie Thermique : Si le manche est en Bois de Fer (très dur), la lame peut être chauffée par un fluide magique sans consumer l'arme, ajoutant des dégâts de feu à chaque balayage.

Catégorie 2 : Haches et Armes d'Hast (Allonge et Impact)

Utilisent des manches longs, la tête est concentrée à l'extrémité, créant beaucoup d'inertie (Moment-Force).
4. La Hache d’Armes (Deux mains)

    Gameplay : Anti-bouclier.

        Overhead (Haut-bas) : Dégâts massifs concentrés. Possède un bonus caché de "Destruction d'Intégrité" contre les blocs de bois et les boucliers.

        Gauche/Droite : Difficile à manier, le "Sweet Spot" (zone de dégâts maximum) est uniquement sur la lame. Frapper avec le manche inflige 10% des dégâts.

    Synergie Matériaux : Une tête de hache en Cuivre s'oxyde vite mais peut être chargée électriquement (via la chimie) pour paralyser l'ennemi sur un coup Overhead.

5. La Lance / Pique (Une main + Bouclier, ou Deux mains)

    Gameplay : La distance de sécurité.

        Estoc (Milieu) : Seul coup possible. Allonge extrême. Idéal en formation de tortue (derrière un bouclier) ou pour charger à cheval.

        Action Spéciale : "Coucher la pique" (Brace) : le joueur se fige, la pique pointée vers l'avant. Tout ennemi (ou joueur) courant vers la pique s'embroche, subissant des dégâts basés sur sa propre vitesse.

    Synergie Magique : Avec une pointe en Cristal Magique, l'estoc peut projeter un cône d'énergie (Bruit de Magie) à l'impact.

Catégorie 3 : Armes Contondantes (Anti-Armure et Systémique)

N'utilisent pas le tranchant, mais la Densité et la Dureté.
6. La Masse à Ailettes (Une main)

    Gameplay : Le brise-armure.

        Toutes directions : Les dégâts ignorent 50% de la valeur d'Armure de la cible. Le "Stagger" (étourdissement au blocage) est élevé.

    Synergie Chimique : La tête à ailettes peut être trempée dans de l'Acide. Le design de l'arme retient le fluide, infligeant des dégâts corrosifs passifs sur plusieurs ticks après l'impact.

7. Le Marteau de Guerre (Deux mains lourdes)

    Gameplay : La force brute.

        Overhead (Haut-bas) : Le coup le plus lent du jeu, mais le plus dévastateur. Si l'ennemi bloque, il est projeté au sol (Ragdoll) et son bouclier est brisé.

        Gauche/Droite : Agit comme une batte de baseball, projetant les ennemis légers sur le côté.

    Synergie Thermique et Poids : Si la tête est forgée en Plomb (très dense), l'allonge est réduite mais le poids explose. Utiliser cette arme consomme 50% de l'endurance par coup. Si chauffée, elle conserve sa température très longtemps (inertie thermique de la masse).

Catégorie 4 : Armes Magiques et Exotiques (Dimensionnelles)

Ces armes utilisent des matériaux issus de l'Infiltration Dimensionnelle.
8. Le Bâton de Canalisation (Deux mains)

    Gameplay : Le combat à distance "Voxel".

        Estoc (Milieu) : Ne frappe pas physiques, mais agit comme un "Pointer" (Raycast) qui consume des cristaux magiques dans l'inventaire.

        Overhead : Si le joueur frappe le sol avec, cela déclenche une onde de choc (Bruit Acoustique) qui alerte toutes les créatures dans un rayon de 50 blocs.

    Synergie Dimensionnelle : Si le bâton est forgé dans un biome sous l'influence du Bruit de Magie, il permet de "sculpter" les fluides (comme l'eau ou l'acide) à distance, pour les projeter sur l'ennemi.

9. La Dague de Verre Abyssal (Une main, furtivité)

    Gameplay : La traîtrise rapide.

        Estoc/Taille (Très rapide) : Allonge quasi nulle. Dégâts faibles de face.

        Backstab : Dégâts multipliés par 10 si l'estoc est porté parfaitement dans le dos de l'ennemi (non-alerté).

    Synergie Matériaux : Le Verre Abyssal est invisible dans les zones d'ombre perpétuelle (comme le fond des Piliers Karstiques). Le joueur nomade tenant cette dague est plus difficile à repérer par l'IA.

10. Le Fléau de chair (Hache/Masse exotique)

    Gameplay : L'imprévisibilité.

        Taille (Circulaire) : La tête est reliée au manche par une chaîne voxel (sous-voxels de chaîne). La trajectoire est chaotique. Elle peut contourner un bouclier pour frapper le dos ou la tête de l'ennemi. Très difficile à bloquer directionnellement.

    Synergie Dimensionnelle : Forgé avec des matériaux de la Dimension Démoniaque, le fléau gagne en longueur et en dégâts en fonction du Bruit Malfaisant local. Il corrompt lentement le porteur s'il n'est pas "Aventurier" ou purifié par l'Astrologie.

Donne moi une liste d'armes mais ne rentre pas trop en détail, dis moi juste la rangé, le type de dégât, etc

Voici une liste simplifiée des types d'armes pour ton système de combat directionnel, classés par le type de tête (qui définit le dégât) et influencés par la longueur du manche (qui définit l'allonge).
1. Lames (Tranchant & Perçant)
Type de Tête	Allonge (Manche)	Type de Dégât Principal	Vitesse	Spécificité Directionnelle
Dague	Très Courte	Perçant (Estoc)	Très Rapide	Bonus dégâts dans le dos.
Épée courte	Courte / Moyenne	Tranchant (Taille)	Rapide	Équilibrée, bonne en parade.
Épée longue	Moyenne / Longue	Tranchant (Taille)	Moyenne	Polyvalente (1H ou 2H).
Espadon	Longue	Tranchant (Taille)	Lente	Dégâts de zone (traverse les ennemis).
Rapière	Moyenne	Perçant (Estoc)	Très Rapide	Wind-up presque nul sur l'estoc.
2. Haches & Armes d'Hast (Tranchant & Contondant)
Type de Tête	Allonge (Manche)	Type de Dégât Principal	Vitesse	Spécificité Directionnelle
Hachette	Courte	Tranchant (Inertie)	Moyenne	Bonus contre les boucliers/blocs bois.
Hache d'armes	Longue	Tranchant (Inertie)	Lente	"Sweet spot" (lame) vs manche.
Lance	Longue / Très Longue	Perçant (Estoc)	Rapide	Allonge maximale, arrêt de charge.
Hallebarde	Longue	Tranchant / Perçant	Lente	Mixte selon la direction (coup/estoc).
3. Masses & Marteaux (Contondant)
Type de Tête	Allonge (Manche)	Type de Dégât Principal	Vitesse	Spécificité Directionnelle
Masse	Courte / Moyenne	Contondant	Moyenne	Ignore une partie de l'armure.
Marteau de guerre	Moyenne / Longue	Contondant	Lente	Fort impact (choc), projection.
Fléau	Moyenne (Chaîne)	Contondant	Moyenne	Trajectoire chaotique, contourne la garde.
4. Spéciales / Magiques (Voxel & Énergie)
Type de Tête	Allonge (Manche)	Type de Dégât Principal	Vitesse	Spécificité Systémique
Bâton	Longue	Contondant	Rapide	Canalisation magique / Onde de choc.
Dague de Verre	Très Courte	Perçant	Très Rapide	Invisible dans l'ombre.

Encore plus

Voici des catégories supplémentaires pour enrichir ton arsenal, en intégrant des armes improvisées (crafting voxel), des armes d'hast techniques et des armes corrompues.
5. Outils Détournés (Survie, Mine & Ingénierie)
Type de Tête	Allonge (Manche)	Type de Dégât Principal	Vitesse	Spécificité Directionnelle
Pioche	Courte / Moyenne	Perçant (Lourd)	Lente	Dégâts extrêmes sur armures lourdes et golems de pierre.
Faux de récolte	Moyenne	Tranchant (Taille)	Lente	Coups horizontaux massifs, fauche la végétation au passage.
Pelle de combat	Courte	Contondant / Tranchant	Moyenne	Très polyvalente. Frappe verticale étourdissante.
Marteau de forge	Moyenne	Contondant	Très Lente	Inflige d'énormes dégâts structurels aux blocs de construction.
Coutelas / Machette	Courte	Tranchant (Taille)	Rapide	Bonus de dégâts contre la biomasse et les lianes.
6. Armes d'Hast Exotiques (Contrôle & Distance)
Type de Tête	Allonge (Manche)	Type de Dégât Principal	Vitesse	Spécificité Directionnelle
Fauchard (Glaive)	Longue	Tranchant (Taille)	Moyenne	Attaques latérales excellentes pour faucher les jambes.
Trident	Longue	Perçant (Estoc)	Rapide	Synergie aquatique (élément Eau).
Bâton ferré	Longue	Contondant	Rapide	Parade très efficace, consomme très peu d'endurance.
Pique à crochet	Longue	Perçant / Tirant	Lente	Le coup directionnel "Bas/Arrière" permet d'agripper un bouclier pour le baisser.
Faux de guerre	Longue	Perçant (Estoc courbe)	Moyenne	Permet de frapper par-dessus le bouclier ennemi.
7. Armes Courtes et Furtivité (Aventurier Nomade)
Type de Tête	Allonge (Manche)	Type de Dégât Principal	Vitesse	Spécificité Directionnelle
Katar (Lame poing)	Très Courte	Perçant (Estoc)	Très Rapide	Idéal pour presser l'adversaire ; bloque les armes longues au contact.
Faucille	Très Courte	Tranchant	Rapide	Le coup latéral permet d'accrocher la garde adverse.
Gourdin / Matraque	Courte	Contondant	Rapide	Attaque non-léthale, draine la jauge d'endurance de la cible.
Stylet	Très Courte	Perçant	Très Rapide	Pénètre la maille, bonus critique sur cible inconsciente.
8. Armes Corrompues & Dimensionnelles (Fin de jeu)
Type de Tête	Allonge (Manche)	Type de Dégât Principal	Vitesse	Spécificité Systémique
Lame dentelée	Moyenne	Tranchant (Saignement)	Moyenne	Arme démoniaque. Inflige des dégâts sur la durée (DoT).
Morgenstern	Courte	Contondant / Perçant	Lente	Dégâts partagés. Impossible à parer parfaitement avec une lame.
Fouet épineux	Longue (Flexible)	Tranchant (Taille)	Moyenne	Hitbox complexe (voxels en chaîne). Contourne la garde.
Masse sismique	Moyenne	Contondant (AoE)	Très Lente	L'attaque verticale "Overhead" crée une onde de choc au sol.
Lance-cristal	Longue	Perçant (Énergie)	Rapide	La pointe magique libère des fragments (Bruit de Magie) au coup lourd.

Les armes à distance et style shakram boomerang etc

Voici les catégories pour le combat à distance, en adaptant les colonnes pour la balistique et en gardant les mécaniques systémiques (rebonds sur les voxels, gestion des munitions).
9. Armes de Jet (Retour et Lancer)
Arme	Portée	Type de Dégât Principal	Vitesse de Tir	Spécificité Systémique
Chakram	Moyenne	Tranchant	Très Rapide	Rebondit sur les murs (blocs durs). Dévastateur dans les couloirs de donjons étroits.
Boomerang	Moyenne	Contondant / Tranchant	Rapide	Revient au joueur s'il ne touche pas de bloc. Traverse la végétation sans la détruire.
Hache de jet	Courte	Tranchant (Inertie)	Moyenne	Fort impact. Se plante dans les blocs de bois ou les boucliers, nécessitant de les arracher.
Javelot / Pilum	Longue	Perçant (Lourd)	Lente	Si bloqué par un bouclier, il s'y ancre et draine drastiquement l'endurance du porteur.
Couteau de lancer	Courte	Perçant	Très Rapide	Furtif. Peut être lancé en rafale. Faible pénétration d'armure.
Bolas	Courte	Entrave	Moyenne	N'inflige pas de dégâts. Entrave les jambes de la cible, annulant son "jeu de jambes".
10. Arcs & Arbalètes (Tension et Précision)
Arme	Portée	Type de Dégât Principal	Vitesse de Tir	Spécificité Systémique
Arc court	Moyenne	Perçant	Rapide	Tirable en plein mouvement. La tension rapide permet de harceler l'ennemi.
Arc long	Très Longue	Perçant	Lente	Nécessite d'être immobile ou à couvert. Transperce les armures légères.
Arbalète lourde	Très Longue	Perçant (Massif)	Très Lente	Ignore l'armure moyenne. Le rechargement fige le joueur sur place.
Arbalète de poing	Courte	Perçant	Rapide (1er tir)	Utilisable à une seule main. Permet de garder un bouclier ou une dague dans l'autre main.
Arc composite	Longue	Perçant	Moyenne	Synergie avec la force du personnage. Les dégâts s'adaptent à la densité du bois utilisé pour l'arc.
11. Armes Balistiques et Ingénierie (Moteur Physique et Chimie)
Arme	Portée	Type de Dégât Principal	Vitesse de Tir	Spécificité Systémique
Fronde	Moyenne	Contondant	Moyenne	Munitions virtuellement illimitées (utilise de la terre ou du gravier extrait du monde).
Tromblon	Courte	Perçant (Cône / AoE)	Très Lente	Projette des fragments (shrapnels). Utilise les déchets de l'usinage des métaux comme munitions.
Arquebuse	Longue	Perçant / Contondant	Très Lente	Dégâts extrêmes. Génère un épais nuage de fumée (système de pollution) qui obstrue la vision.
Lance-grenades	Moyenne	Explosion (AoE)	Très Lente	Synergie chimique. Projette des fioles de gaz toxique, d'acide ou des charges explosives.
Sarbacane	Moyenne	Toxique (Poison)	Rapide	Dégâts d'impact nuls, mais applique des effets chimiques (paralysie, poison) issus de la biomasse récoltée.

Donne ma la liste complète, je voudrais qu'il y ait des skills par type d'arme et par type de dégât

L'intégration d'un système de compétences croisées (Type d'Arme + Type de Dégât) est la signature des grands RPG systémiques (comme Morrowind ou Kenshi). L'idée est que chaque coup porté donne de l'expérience dans deux arbres de compétences simultanément. Par exemple, frapper avec une Hallebarde en mode "Taille" monte la compétence Armes d'Hast et la compétence Tranchant.

Voici l'architecture de ce système de compétences, suivie de l'arsenal complet pour le supporter.
1. Arbres de Compétences : Types de Dégâts (Physique Fondamentale)

Ces compétences augmentent peu importe l'arme utilisée, tant que le type de frappe correspond. Elles débloquent des effets passifs systémiques.

    Maîtrise du Tranchant (Slashing) :

        Effet de base : Augmente la largeur des "hitboxes" de balayage (les arcs de cercle sont plus larges).

        Perk (Niveau Avancé) - Hémorragie : Les attaques directionnelles latérales appliquent un saignement qui empêche la cible de régénérer son endurance.

        Perk (Niveau Maître) - Démembrement : Chance de mutiler (réduire la vitesse de déplacement ou d'attaque) sur un coup critique.

    Maîtrise du Perçant (Piercing) :

        Effet de base : Augmente la vitesse du "Wind-up" (préparation) des attaques d'estoc.

        Perk (Niveau Avancé) - Perforation : Ignore un pourcentage fixe de la valeur d'armure de la cible.

        Perk (Niveau Maître) - Point Faible : Les attaques portées de dos ou sur la tête voient leurs dégâts multipliés.

    Maîtrise du Contondant (Blunt) :

        Effet de base : Augmente les dégâts infligés à la jauge d'endurance de l'adversaire (Stamina Drain) lors d'une parade.

        Perk (Niveau Avancé) - Onde de Choc : Les attaques verticales "Overhead" créent un micro-séisme qui repousse les ennemis adjacents.

        Perk (Niveau Maître) - Fracas : Brise instantanément la garde d'un ennemi utilisant un bouclier en bois ou une arme légère.

    Maîtrise Magique / Dimensionnelle (Éther) :

        Effet de base : Réduit le coût en "Bruit Magique" ou en cristaux lors de l'utilisation d'armes canalisées.

        Perk (Niveau Avancé) - Résonance : Les attaques projettent un léger halo qui éclaire les grottes sombres à l'impact.

2. Arbres de Compétences : Types d'Armes (Technique Martiale)

Ces compétences débloquent des mouvements spécifiques (Footwork, Animations) liés à la famille de l'arme.

    Lames (Épées, Rapières, Dagues) : Débloque la "Parade Parfaite" (Chambering) — attaquer dans la même direction que l'ennemi à la dernière seconde dévie son coup et frappe simultanément.

    Haches (Hachettes, Haches d'armes) : Débloque le "Crochetage" (Hooking) — attaquer vers le bas (Overhead) sur un ennemi avec un bouclier permet de lui baisser sa garde temporairement.

    Masses & Marteaux : Débloque "l'Inertie" — rater un coup ne stoppe plus l'animation, le joueur peut enchaîner sur un balayage inversé continu.

    Armes d'Hast (Lances, Hallebardes) : Débloque "l'Ancrage" (Bracing) — s'accroupir avec l'arme fige le joueur mais renvoie 200% des dégâts à toute créature qui charge.

    Armes de Jet (Chakrams, Javelots) : Améliore la récupération (les armes rebondissent vers le joueur ou ont 100% de chance d'être ramassées intactes).

    Tir & Balistique (Arcs, Arbalètes, Armes à feu) : Réduit le tremblement de la caméra (Sway) et augmente la vitesse de rechargement.

3. L'Arsenal Complet (Data-Driven)

Voici la table exhaustive des armes classées par type, prêtes à être intégrées dans ton catalogue JSON.
Lames Longues & Courtes
Arme	Allonge	Dégât Principal	Dégât Secondaire	Vitesse	Synergie Martiale
Dague	Très Courte	Perçant	Tranchant	Très Rapide	Bonus massif en attaque furtive dans le dos.
Stylet	Très Courte	Perçant	Aucun	Très Rapide	Passe à travers les armures de mailles.
Épée Courte	Courte	Tranchant	Perçant	Rapide	Fenêtre de parade allongée.
Coutelas / Machette	Courte	Tranchant	Aucun	Rapide	Dégâts bonus sur la biomasse, fauche les lianes.
Rapière	Moyenne	Perçant	Tranchant	Très Rapide	Estoc quasi-instantané, parade faible.
Épée Longue (1H/2H)	Moyenne	Tranchant	Perçant	Moyenne	L'arme la plus polyvalente.
Espadon (Zweihänder)	Longue	Tranchant	Perçant	Lente	Dégâts de zone, transperce plusieurs cibles.
Lame Dentelée	Moyenne	Tranchant	Aucun	Moyenne	Inflige des dégâts sur la durée (Corrompue).
Haches & Armes d'Hast
Arme	Allonge	Dégât Principal	Dégât Secondaire	Vitesse	Synergie Martiale
Hachette	Courte	Tranchant	Contondant	Rapide	Utilisable en outil de bûcheronnage.
Hache d'Armes	Longue	Tranchant	Contondant	Lente	"Sweet spot" sur la lame, dégâts massifs de haut en bas.
Lance	Très Longue	Perçant	Aucun	Rapide	Garde l'ennemi à distance, excellente en formation.
Pique à Crochet	Longue	Perçant	Tranchant	Lente	Permet de tirer les ennemis hors de leurs montures.
Hallebarde	Longue	Tranchant	Perçant	Lente	Coup latéral (Taille) ou d'Estoc selon la direction.
Faux de Guerre	Longue	Perçant	Tranchant	Moyenne	Contourne les boucliers par-dessus la garde.
Fauchard	Longue	Tranchant	Aucun	Moyenne	Dégâts critiques ciblés sur les jambes.
Masses & Armes Lourdes
Arme	Allonge	Dégât Principal	Dégât Secondaire	Vitesse	Synergie Martiale
Gourdin	Courte	Contondant	Aucun	Rapide	Dégâts non-léthaux, épuise la cible.
Masse à Ailettes	Moyenne	Contondant	Perçant	Moyenne	Détruit les armures lourdes.
Marteau de Guerre	Moyenne	Contondant	Aucun	Lente	Projette les ennemis légers au sol (Ragdoll).
Fléau d'Armes	Moyenne	Contondant	Aucun	Moyenne	Hitbox physique chaotique, ignore la parade directionnelle.
Marteau de Forge	Courte	Contondant	Aucun	Lente	Dégâts structurels immenses contre les blocs/murs.
Morgenstern	Courte	Perçant	Contondant	Lente	Ne peut pas être paré sans subir de dégâts partiels.
Pioche de Combat	Moyenne	Perçant	Contondant	Lente	Perce les golems ou les armures rocheuses.
Armes de Jet (Lancer & Retour)
Arme	Portée	Dégât Principal	Dégât Secondaire	Vitesse	Synergie Martiale
Couteau de Lancer	Courte	Perçant	Aucun	Très Rapide	Tir en rafale, furtif.
Hache de Jet	Courte	Tranchant	Contondant	Moyenne	Se plante dans les boucliers pour les alourdir.
Javelot / Pilum	Longue	Perçant	Aucun	Lente	Dégâts massifs, détruit l'endurance si bloqué.
Chakram	Moyenne	Tranchant	Aucun	Très Rapide	Rebondit mathématiquement sur les voxels durs (Pierre, Acier).
Boomerang	Moyenne	Contondant	Aucun	Rapide	Revient dans la main si aucun bloc n'est percuté.
Bolas	Courte	Aucun	Entrave	Moyenne	Annule les déplacements de la cible pendant X secondes.
Tir Balistique, Arcs & Ingénierie
Arme	Portée	Dégât Principal	Dégât Secondaire	Vitesse	Synergie Martiale
Arc Court	Moyenne	Perçant	Aucun	Rapide	Tirable en plein saut ou en reculant.
Arc Long / Composite	Très Longue	Perçant	Aucun	Lente	Dégâts liés à la solidité du bois utilisé, transperce.
Arbalète Lourde	Très Longue	Perçant	Aucun	Très Lente	Ignore l'armure moyenne, force à s'arrêter pour recharger.
Arbalète de Poing	Courte	Perçant	Aucun	Rapide	Utilisable avec un bouclier ou une torche en main gauche.
Fronde	Moyenne	Contondant	Aucun	Moyenne	Munitions illimitées via extraction de terre/gravier du sol.
Sarbacane	Moyenne	Aucun	Toxique	Rapide	Applique les chimies et poisons récoltés dans le biome.
Tromblon	Courte	Perçant (AoE)	Contondant	Très Lente	Projette un cône de shrapnels (déchets de forge).
Arquebuse	Très Longue	Perçant	Contondant	Très Lente	Coup critique garanti sur cible sans armure, génère un écran de fumée.
Armes Magiques & Dimensionnelles
Arme	Portée	Dégât Principal	Dégât Secondaire	Vitesse	Synergie Martiale
Bâton de Canalisation	Moyenne	Magique	Contondant	Rapide	Projette le fluide ou l'énergie stocké dans l'inventaire.
Dague de Verre Abyssal	Très Courte	Perçant	Magique	Très Rapide	Modèle 3D invisible dans les zones d'ombre du jeu.
Masse Sismique	Courte	Contondant	Magique	Très Lente	Frapper le sol détruit les blocs de terre et renverse les cibles.
Fléau de Chair	Moyenne	Tranchant	Magique	Moyenne	L'allonge augmente si utilisé dans la Dimension Démoniaque.
Lance-Cristal	Longue	Perçant	Magique	Rapide	L'estoc lourd libère des sous-voxels explosifs à l'impact.

Planifier l'intégration Data-Driven des compétences ?

Et si on faisait des animations procédurales, les bras et les jambes ont 2 parties et les 2 pieds sont toujours sur le sol et les bras sont accrochés aux armes

C'est la solution technique parfaite pour un jeu voxel avec un terrain accidenté et un système d'armes modulaires. En développement, cela s'appelle la Cinématique Inverse (Inverse Kinematics ou IK).

Au lieu de créer des centaines d'animations statiques, tu animes uniquement le centre de gravité (le bassin/torse) et tu laisses les mathématiques (la trigonométrie) placer les extrémités (mains et pieds) là où elles doivent être.

Voici comment structurer ce système dans Godot 4 pour ton projet.
1. Les Jambes : L'Ancrage au Sol (Ground IK)

Dans un monde voxel, le terrain est en escalier. Sans IK, un pied flottera dans le vide pendant que l'autre sera enfoncé dans un bloc.

    Le Raycast : À chaque frame, depuis le genou ou la hanche du personnage, le moteur tire un rayon droit vers le bas (Raycast3D).

    L'Ajustement : Le rayon détecte la hauteur exacte du bloc en dessous. Le moteur indique au pied de se placer exactement à ces coordonnées.

    La Flexion (2-Bone IK) : Puisque la distance entre la hanche et le sol a changé, l'algorithme plie automatiquement le genou vers l'avant pour que la jambe garde une longueur physiquement cohérente.

    Le Résultat : Quand ton joueur se tient sur le bord d'un bloc, une jambe est tendue vers le bas (sur le bloc inférieur) et l'autre est pliée (sur le bloc supérieur). C'est extrêmement naturel.

2. Les Bras : La Prise d'Arme (Weapon IK)

Puisque ton système d'armes assemble dynamiquement des manches et des têtes de tailles différentes, créer des animations à la main pour chaque combinaison est impossible. L'IK résout cela.

    Les Marqueurs (Marker3D) : Lorsque tu génères le modèle 3D de l'arme en jeu, tu y attaches virtuellement deux cibles invisibles : une "Cible Main Droite" (près de la garde) et une "Cible Main Gauche" (au milieu du manche).

    L'Aimantation des Mains : Tu configures l'IK des bras pour que les mains "suivent" en permanence ces marqueurs.

    Le Mouvement : Ton animation principale ne fait bouger que l'arme elle-même (le coup de taille, l'estoc, l'overhead). Les bras vont automatiquement se plier, s'étendre et suivre l'arme de manière réaliste, qu'il s'agisse d'une petite dague ou d'une longue pique.

3. Impact sur les Performances (Intel UHD 620)

La Cinématique Inverse demande des calculs trigonométriques. Pour ne pas détruire tes performances, tu dois respecter deux règles architecturales :

    IK Analytique (Two-Bone IK) : N'utilise jamais de solveurs complexes comme le FABRIK ou le CCDIK (qui calculent des chaînes de 10 os par itérations). Pour des bras et des jambes (Cuisse -> Mollet -> Pied), un simple solveur à deux os (Two-Bone IK) calcule l'angle exact en une seule opération mathématique (loi des cosinus). C'est ultra-léger pour le CPU.

    Désactivation par la Distance (Culling) : L'IK ne doit tourner que pour le joueur et les PNJ situés à moins de 15 blocs de distance. Pour les ennemis lointains, l'IK est désactivée et ils utilisent des animations de marche rigides classiques pour économiser des ressources.

Comment envisages-tu la rotation du torse pour la visée : le haut du corps du personnage doit-il physiquement se pencher en avant et en arrière selon là où tu regardes avec la caméra, ou gardes-tu un buste droit avec seulement les bras qui pivotent vers la cible ?

Oui le haut du corps de penche en avant et en arrière selon la caméra, le joueur peut aussi bloquer avec un bouclier ou son arme, animation selon la longueur du manche de l'arme, si c'est 1 main ou 2 et si c'est une arme ou deux

C'est la pièce maîtresse qui va donner à ton jeu l'esthétique et le "game feel" d'un Mordhau ou d'un Chivalry. Le fait de coupler l'orientation du buste à la caméra et d'utiliser l'IK (Cinématique Inverse) pour les parades crée un système de combat 100% physique et réactif, où la position du corps définit réellement les hitboxes (zones de collision).

Voici comment structurer cette logique procédurale dans Godot pour gérer toutes tes variables (longueur, 1 main, 2 mains, bouclier).
1. Le Buste et la Caméra (Spine Bending / Aim Space)

Pour que le joueur puisse viser vers le haut ou regarder ses pieds tout en gardant une posture naturelle, on n'anime pas tout le corps, on manipule directement les os de la colonne vertébrale.

    La Mécanique : Tu lis l'angle de tangage (Pitch) de ta caméra. Tu divises cet angle sur 2 ou 3 os de la colonne (Spine1, Spine2, Neck) pour que la courbure soit fluide.

    L'Impact Gameplay : C'est fondamental pour le combat directionnel. Si un ennemi te fait une attaque "Taille basse" (qui vise tes jambes) et que tu regardes vers le bas, ton torse se penche, abaissant tes bras et ton arme. Ton blocage protégera ainsi tes jambes. Inversement, regarder en l'air lève ton arme pour bloquer un "Overhead".

    Sécurité : Il faut "clamper" (brider) cet angle (par exemple de -60° à +60°) pour éviter que le personnage ne se brise le dos en regardant totalement à la verticale.

2. Le Blocage Procédural via l'IK (Les Positions de Garde)

Au lieu d'avoir une animation "Parade" figée, ton code déplace simplement l'arme (ou le bouclier) dans l'espace devant le joueur. L'IK des bras fait le reste.

    Arme à 2 Mains (Espadon, Lance, Hache d'armes) :

        L'Action : Le clic droit fait pivoter l'arme à l'horizontale (ou en diagonale selon l'attaque adverse) et la rapproche du buste.

        L'Effet IK : Puisque la main droite est attachée à la base du manche et la gauche au milieu, les deux coudes vont naturellement se plier vers l'extérieur pour absorber le choc.

    1 Main + Bouclier :

        L'Action : Le clic droit déplace le marqueur IK du bouclier (attaché à l'avant-bras gauche) devant la caméra.

        L'Effet IK : Le bras gauche se lève et se plie devant le torse. La main droite (avec l'arme) reste en position de repos ou d'attaque, permettant de bloquer ET de frapper (estoc) en même temps (la fameuse formation tortue).

    Deux Armes (Dual Wielding : Dague + Épée courte) :

        L'Action : Le clic droit déplace les deux armes devant le joueur en les croisant (une en diagonale gauche, l'autre droite).

        L'Effet IK : Les deux bras se croisent en "X" devant le visage. C'est une parade extrêmement rapide mais qui consomme énormément d'Endurance car elle manque d'inertie face à une arme lourde.

3. La Magie de la "Longueur du Manche"

C'est ici que ton système de craft modulaire brille de mille feux. Tu n'as rien à animer de plus, les mathématiques gèrent la taille de l'arme.

    Le Calcul de la Prise : Quand le jeu génère le modèle 3D de l'arme, il calcule sa longueur. La "Main Droite" va toujours à la coordonnée Z = 0 (la base du manche). La "Main Gauche" va à la coordonnée Z = (Longueur du Manche / 2).

    Application :

        Si le joueur tient une petite hachette, les deux mains seront très proches. L'IK va garder les deux bras serrés devant le corps du personnage.

        Si le joueur tient une pique de 3 mètres, le marqueur de la main gauche sera projeté 1,5 mètre plus loin. L'IK va automatiquement tendre le bras gauche au maximum vers l'avant, tandis que le bras droit restera plié près de la hanche. La posture s'adapte toute seule au voxel !

4. Le Paramétrage dans Godot 4

Pour implémenter cela de manière propre sans surcharger ton processeur :

    L'Arbre d'Animation (AnimationTree) : Tu utilises de simples animations "Idle", "Marche", "Course" pour les jambes et le balancement naturel du corps.

    Le nœud SkeletonModifier3D : C'est la nouveauté de Godot 4. Tu ajoutes un modificateur pour la colonne vertébrale (qui lit l'angle de la caméra) et deux modificateurs IK (un pour chaque bras).

    Priorité des os : Les nœuds IK écraseront l'animation de base des bras. Donc, même si le joueur est en train de courir (animation de balancement des bras), s'il clique pour bloquer, l'IK prend le relais instantanément pour figer les bras en position de garde, pendant que les jambes continuent de courir via l'animation classique.

En croisant ce système visuel exact avec tes hitbox gérées par raycasts, le joueur devra littéralement regarder la pointe de l'arme ennemie pour la dévier avec le manche de son propre outil. C'est le sommet du gameplay systémique.

Et comment on pourrait faire du combat aux poings ? J'aimerais que le joueur commence sans rien

Commencer l'aventure dans le dénuement le plus total, dans la plus pure tradition d'une progression de type Ironman où chaque ressource et chaque outil doivent être mérités, pose immédiatement les bases d'un univers impitoyable.

Le combat à mains nues ne doit pas être codé comme une simple "épée invisible avec zéro de portée". Il doit avoir sa propre identité mécanique et s'intégrer parfaitement à tes systèmes d'IK et de combat directionnel.

Voici comment concevoir le combat aux poings dans ton moteur.
1. Le Mapping Directionnel (Le Kit de Boxe)

Sans arme, la vitesse est ton seul avantage. Tes bras deviennent les vecteurs de dégâts, exclusivement de type Contondant.

    Estoc (Milieu) — Le Direct (Jab) : Le coup le plus rapide du jeu. L'allonge est maximale pour un bras humain. L'objectif n'est pas de faire de gros dégâts, mais d'interrompre l'animation d'attaque (le Wind-up) d'un monstre lent.

    Taille (Gauche/Droite) — Le Crochet (Hook) : L'animation part sur les côtés. C'est idéal pour contourner le bouclier ou la garde frontale d'un ennemi, en frappant les flancs ou la tête.

    Haut-Bas (Overhead) — Le Coup Marteau (Hammerfist) : Le joueur joint ses deux mains (ou utilise un poing lourd) pour frapper de haut en bas. C'est le seul coup à mains nues capable de drainer sérieusement la jauge d'Endurance de la cible.

    La Garde — La Couverture : Un clic droit lève les deux avant-bras devant le visage (IK croisée). Cela ne bloque pas 100% des dégâts (une épée finira par trancher), mais cela réduit drastiquement les dégâts subis et protège la tête d'un coup critique.

2. Intégration Systémique : La Physique du Corps

Puisque ton jeu gère les matériaux, frapper à mains nues doit obéir aux lois de la physique.

    Le Recul et l'Auto-mutilation : La chair contre l'acier ne gagne jamais. Si le joueur frappe à mains nues une créature faite de roche ou un ennemi en armure de plaques, il doit subir un pourcentage des dégâts en retour (Recoil Damage). Le joueur comprendra très vite qu'il ne peut pas boxer un golem d'obsidienne.

    La Préhension (Le Push) : L'avantage d'avoir les mains libres est de pouvoir interagir avec le monde. Tu peux remplacer l'attaque lourde par une mécanique de "Poussée" (Push/Kick). Dans un environnement voxel accidenté, pousser un monstre dans un ravin, dans une rivière, ou dans un feu de camp compense largement l'absence de lame.

3. Gestion de l'IK (Cinématique Inverse)

Le système d'IK conçu pour les armes s'adapte sans effort au combat à mains nues.

    Suppression des Marqueurs d'Arme : Lorsque le joueur n'équipe rien, le code désactive la recherche des cibles "Main Droite" et "Main Gauche" sur le manche de l'arme.

    Bending du Torse : Le système de visée avec la caméra reste actif. Si le joueur regarde vers le bas pour frapper un petit monstre rampant, sa colonne vertébrale se penche en avant, rapprochant naturellement ses poings de la cible. Les hitboxes des poings suivent parfaitement l'animation.

4. L'Évolution (L'Arsenal du Pugiliste)

Le combat aux poings ne doit pas nécessairement rester une simple phase de survie initiale. Tu peux l'intégrer dans le craft modulaire.

    Les Bandages (Tissu/Cuir) : Première étape de craft. Annule les dégâts de recul sur les cibles modérément dures.

    Les Cestes et Poings Américains (Métal) : Le joueur forge une "tête" d'outil qui s'équipe directement sur les mains. Les dégâts contondants augmentent drastiquement.

    Les Griffes (Os/Verre Abyssal) : Transforme les dégâts contondants des poings en dégâts tranchants ou perçants, permettant d'appliquer des effets de saignement tout en gardant la vitesse extrême de la boxe.

Envisages-tu de faire du combat à mains nues un véritable arbre de compétences viable jusqu'en fin de partie (façon moine martial), ou souhaites-tu que cela reste strictement une option de survie désespérée avant de forger son premier outil ?

Donc au niveau des stats pour le combat on a quoi ?

Pour que ton système de combat à la Mount & Blade fonctionne en synergie parfaite avec ton moteur voxel orienté données et tes matériaux, les statistiques ne peuvent pas se résumer à un simple "Attaque / Défense". Elles doivent refléter la physique, la distance et l'endurance.

Voici la synthèse de toutes les statistiques de combat qui découlent de notre architecture actuelle, réparties en quatre grands piliers.
1. Les Statistiques Vitales du Personnage (Le Corps)

Ce sont les jauges fondamentales qui dictent le rythme du combat et la survie.

    Santé (HP) : Les points de vie globaux. Si elle tombe à zéro, c'est la mort.

    Endurance (Stamina) : La ressource la plus critique. Elle est drainée par les attaques, les parades, les esquives et le sprint. Si un joueur tente de bloquer un coup sans endurance, sa garde est brisée (Stagger) et il encaisse des dégâts critiques.

    Stabilité (Poise / Stagger Resistance) : La capacité à encaisser un coup sans voir sa propre animation d'attaque interrompue. Influencée par l'armure portée et potentiellement la force brute du personnage.

    Charge Maximale (Equip Load) : Détermine les malus de vitesse de déplacement. Porter une armure en plomb et un espadon en acier réduit drastiquement la vitesse de recul (le fameux jeu de jambes).

2. Les Statistiques Offensives (L'Arme et la Frappe)

Ces statistiques sont générées dynamiquement par la combinaison du manche et de la tête de l'outil/arme.

    Dégâts Bruts : Divisés strictement en trois physiques et deux systémiques :

        Tranchant (Slashing) : Dégâts de base, excellents contre la chair.

        Perçant (Piercing) : Dégâts concentrés, excellents contre la maille et le cuir.

        Contondant (Blunt) : Dégâts d'impact, excellents contre la plaque et la roche.

        Magique / Chimique : Dégâts appliqués sur la durée ou par ondes de choc.

    Allonge (Reach) : Une valeur en mètres calculée par la longueur du manche. Elle dicte aux mathématiques (l'IK) jusqu'où les bras s'étendent et où commence la hitbox.

    Vitesse d'Armement (Wind-up) : Le temps en millisecondes entre le clic du joueur et le moment où l'arme inflige réellement des dégâts. Une dague a un wind-up quasi nul, un marteau lourd prendra une seconde complète.

    Dégâts de Garde (Stamina Drain) : La quantité d'endurance que cette arme draine à l'adversaire s'il parvient à bloquer le coup. Un marteau en plomb possède un drain de garde massif.

    Pénétration d'Armure : Un pourcentage brut. Une pioche ou une masse à ailettes ignorera par exemple 40% de l'armure adverse.

3. Les Statistiques Défensives (L'Armure et la Parade)

Elles déterminent comment le joueur survit lorsqu'il ne peut pas esquiver.

    Valeur d'Armure Physique : Réduit les dégâts reçus. Une armure complète en acier absorbe énormément de tranchant, mais beaucoup moins de contondant.

    Fenêtre de Parade (Parry Window) : Une statistique invisible mais cruciale. Une arme légère (épée courte) ou un bouclier offre un arc de cercle généreux devant le joueur pour intercepter l'arme ennemie. Essayer de parer avec une hache lourde exigera de regarder exactement au bon endroit (fenêtre très serrée).

    Résistances Systémiques : Résistance Thermique (contre le feu et la chaleur des abysses), Résistance Chimique (contre l'acide/poison) et Résistance Magique (contre la corruption).

4. Les Statistiques Matérielles et Variables (L'Environnement)

Ce sont les modificateurs qui lient le combat au reste du monde voxel.

    Densité / Poids : Définit l'inertie de l'arme. Dicte directement le coût en Endurance de chaque coup et la force du Stagger infligé.

    Intégrité / Durabilité : La résistance de l'outil. Frapper un golem de pierre avec une lame en fer dégradera l'intégrité de l'arme à chaque coup. Si elle tombe à zéro, l'arme se brise (ou ses dégâts sont divisés par dix).

    Affinités Astrologiques (Wuxing) : Les modificateurs passifs liés à la naissance. Par exemple, un joueur d'affinité Métal verra l'usure de ses armures ralentie, tandis qu'un joueur d'affinité Eau résistera naturellement mieux aux attaques liées aux fluides.

Souhaites-tu que l'interface utilisateur affiche ces statistiques sous forme de chiffres précis pour les "min-maxers" (ex: "Dégâts Tranchants : 45"), ou préfères-tu un système plus cryptique et organique utilisant des jauges ou des lettres (ex: "Tranchant : A", "Vitesse : C") pour encourager l'expérimentation ?

Génère 5 armes avec toutes les stats respectives et 5 pièces d'armure avec toutes les stats respectives

Voici 5 armes et 5 pièces d'armures générées avec l'intégralité des statistiques systémiques de ton moteur. Ces valeurs illustrent comment les matériaux (Plomb, Obsidienne, Cuivre) influencent directement la physique du combat (poids, inertie, pénétration).
Les Armes (Combinaisons Manche + Tête)
Arme (Matériaux)	Allonge	Poids	Dégâts (Type)	Wind-up	Drain de Garde	Pénétration	Parade	Durabilité
Épée Longue (Manche Chêne, Lame Acier)	1.2 m	2.5 kg	40 Tranchant, 25 Perçant	450 ms	20	10%	120°	800
Marteau Lourd (Manche Frêne, Tête Plomb)	1.8 m	14.0 kg	90 Contondant	950 ms	80	50%	45°	1200
Dague de Faille (Manche Os, Lame Verre Abyssal)	0.4 m	0.8 kg	50 Perçant, 20 Magique	150 ms	5	30%	30°	150
Hallebarde Toxique (Manche Pin, Tête Cuivre Oxydé)	2.4 m	4.5 kg	45 Tranchant, 10 Chimique	650 ms	35	15%	90°	600
Pioche de Siège (Manche Chêne, Tête Obsidienne)	1.0 m	3.2 kg	60 Perçant, 30 Contondant	700 ms	50	60%	60°	250

Analyse systémique des armes :

    Le Marteau en Plomb : Avec ses 14 kg, son animation de frappe (Wind-up) dure près d'une seconde, laissant le joueur très vulnérable. En revanche, s'il touche un ennemi qui tente de bloquer, les 80 points de Drain de Garde videront instantanément l'endurance adverse (Stagger garanti).

    La Dague en Verre Abyssal : Extrêmement rapide (150 ms) et dotée de dégâts magiques, mais sa durabilité de 150 signifie qu'elle se brisera très vite si elle frappe une armure lourde ou de la roche.

    La Pioche en Obsidienne : Conçue pour percer les armures (60% de pénétration), elle compense sa courte allonge par sa capacité à ignorer les défenses physiques.

Les Armures (Équipement Localisé)
Pièce d'Armure (Matériau)	Poids	Armure (Tranchant / Perçant / Contondant)	Résistances (Thermique / Chimique / Magique)	Stabilité (Poise)	Malus Régénération Endurance
Plastron de Plates (Acier pur)	18.0 kg	60 / 40 / 20	10 / 0 / 0	+50	-20%
Gambeson Épais (Fibres de Lianes)	4.0 kg	15 / 10 / 30	5 / 20 / 0	+5	0%
Heaume Lourd (Fonte de Fer)	5.0 kg	30 / 30 / 40	20 / 0 / 0	+15	-5%
Bottes de Maraudeur (Cuir et Os traités)	2.0 kg	10 / 5 / 5	0 / 30 / 5	+0	0%
Manteau d'Inquisiteur (Tissu infusé de Cristaux)	1.5 kg	5 / 5 / 5	50 / 10 / 60	+0	+10%

Analyse systémique des armures :

    Le Plastron en Acier : Il offre une protection massive contre les épées (60 Tranchant) et empêche le joueur d'être étourdi (Poise +50), mais son poids pénalise lourdement la régénération d'Endurance. Il est faible face aux armes contondantes (comme le Marteau en Plomb).

    Le Gambeson en Fibres : Fait en biomasse, il absorbe très bien les chocs (30 Contondant) et offre une bonne résistance chimique contre les poisons, le tout sans ralentir le joueur. Idéal pour l'aventurier nomade.

    Le Manteau d'Inquisiteur : Physiquement inutile, ce vêtement sert de bouclier dimensionnel. Il permet de survivre aux environnements altérés par la magie (60 Résistance Magique) ou aux biomes extrêmes (50 Résistance Thermique) tout en accélérant la régénération d'endurance.

Comment structurer le calcul final des dégâts dans le code ?

Sépare les stats qui sont programmé directement et les stats qui en decoulent

C'est la clé de voûte d'une architecture orientée données (Data-Driven). Dans ton code, tes fichiers JSON ne doivent contenir que les données physiques fondamentales. C'est ensuite ton moteur (en GDScript) qui calcule les statistiques de gameplay en combinant ces valeurs.

Voici la séparation exacte entre ce qui est écrit "en dur" dans tes fichiers de configuration et ce qui est calculé dynamiquement par le jeu.
1. Statistiques Programmées (Données Brutes / Les JSON)

Ces valeurs sont les propriétés intrinsèques des matériaux, des formes et du personnage. Elles ne changent jamais à moins que tu ne modifies le fichier de configuration.

Les Matériaux (Ex: Acier, Plomb, Chêne, Obsidienne) :

    Densité : La masse par unité de volume (ex: le plomb est plus dense que le bois).

    Dureté / Cohésion : La résistance fondamentale du matériau avant de se briser.

    Absorptions de base : L'efficacité intrinsèque du matériau contre le Tranchant, le Perçant, et le Contondant.

    Affinités (Thermique, Chimique, Magique) : Les multiplicateurs de résistance aux éléments.

Les Composants d'Armes (Manches et Têtes) :

    Longueur (Manche) : Valeur en mètres du modèle 3D extrudé.

    Volume / Épaisseur (Tête) : La quantité de matière utilisée pour forger la tête.

    Profil de Dégâts (Tête) : Les valeurs nominales brutes fixées par la forme de l'outil (ex: une forme "Hache" a 40 Tranchant brut et 10 Contondant brut).

    Multiplicateur de Pénétration (Tête) : Un bonus inhérent à la forme (ex: une pointe de pioche a un fort multiplicateur, une lame plate a un multiplicateur nul).

Le Personnage :

    Vitalité (HP) de base : Les points de vie physiologiques.

    Endurance de base : Le pool d'énergie maximum.

    Élément Astrologique (Wuxing) : Le tag attribué à la naissance (ex: "Métal", "Feu").

2. Statistiques Dérivées (Calculées en Temps Réel / GDScript)

Ces statistiques n'existent pas dans tes JSON. Elles sont le résultat d'équations mathématiques calculées par ton script lorsque le joueur assemble une arme, s'équipe, ou porte un coup.

L'Arme Assemblée :

    Poids Total : Calculé en multipliant le Volume des composants par la Densité des matériaux choisis. (Ex: Manche court en chêne + Grosse tête en plomb = Poids extrême concentré au bout).

    Allonge (Reach) : Calculée en additionnant la Longueur du manche et la hitbox de la tête. C'est cette valeur qui paramètre la Cinématique Inverse (IK) de tes bras.

    Vitesse d'Attaque (Wind-up) : Dérivée du Poids Total et de la répartition de la masse. Plus l'arme est lourde, plus l'animation est ralentie mathématiquement par ton AnimationTree.

    Drain de Garde (Stagger) : Une équation physique (Énergie cinétique). Calculé par le Poids Total multiplié par la vitesse du coup, avec un bonus selon la valeur de dégât Contondant brut.

    Pénétration d'Armure Finale : La Dureté du matériau de la tête multipliée par le Multiplicateur de Pénétration de sa forme. (Ex: Une pointe de lance en cuivre pénètre mal car le cuivre est mou ; une pointe en acier pénètre parfaitement).

    Durabilité Max : La Dureté globale des matériaux ajustée par le niveau de compétence du joueur en forge au moment de la création.

Les Capacités de Combat du Joueur :

    Charge Maximale (Equip Load) : La somme du Poids Total de toutes les armures et armes portées.

    Régénération d'Endurance : L'Endurance de base moins un malus exponentiel dicté par la Charge Maximale.

    Vitesse de Déplacement (Jeu de jambes) : La vitesse de base du CharacterBody3D réduite par la Charge Maximale.

    Stabilité (Poise) : Calculée en fonction du Poids Total de l'armure portée. Une armure très dense abaisse le centre de gravité et empêche le joueur de vaciller sous les coups.

    Fenêtre de Parade (Parry Window) : Dérivée de l'Allonge et du Poids Total de l'arme. Une arme courte et légère donne une large fenêtre de temps pour bloquer ; une arme longue et lourde nécessite un timing parfait, car elle est difficile à manœuvrer.

    Résistances Finales : La somme des Absorptions de base de chaque pièce d'armure, modulée par l'Élément Astrologique du joueur (un joueur d'élément Feu gagne un bonus multiplicateur sur l'absorption Thermique de son armure).

Le nouveau système d'animation n'est pas trop lourd pour les villes et les donjons ?

C'est une excellente remarque. Sur ta configuration actuelle, calculer des raycasts pour les pieds et de la trigonométrie pour les bras de 50 PNJ dans une ville va provoquer une chute drastique du framerate. Le système est parfait pour le joueur et ses adversaires directs, mais il est mortel s'il est appliqué aveuglément à grande échelle.

Pour que les villes et les donjons restent fluides, l'industrie utilise des techniques de désactivation sélective. Voici comment protéger tes performances :
1. Le Culling par la Distance (LOD d'Animation)

La cinématique inverse (IK) ne doit exister que là où le joueur porte son attention.

    Zone Active (0 à 15 blocs) : Le joueur et les ennemis engagés dans un combat immédiat utilisent le système procédural complet (IK des pieds, orientation de la colonne, parade dynamique).

    Zone Passive (Au-delà de 15 blocs) : Le script désactive purement et simplement les nœuds SkeletonModifier3D des entités. Les PNJ repassent sur des animations statiques et rigides (pré-calculées). À cette distance, le joueur ne remarquera pas que les pieds d'un habitant s'enfoncent légèrement dans une marche.

2. Le Culling de Visibilité (Frustum Culling)

Dans un donjon, l'architecture est fermée par de nombreux murs et portes. Il est inutile de calculer la posture de combat d'un monstre situé dans la pièce voisine.

    L'outil Godot : L'utilisation du nœud VisibleOnScreenNotifier3D attaché à tes entités est redoutable. Dès que le modèle 3D du monstre n'est plus dessiné à l'écran (caché par la géométrie du donjon ou dans le dos du joueur), le script coupe l'alimentation de son arbre d'animation procédurale. L'entité continue de se déplacer via son IA, mais sans calculs articulaires.

3. La Simplification Civile (Villes)

Dans une ville, la majorité des entités n'ont tout simplement pas besoin du système d'armement modulaire.

    PNJ Allégés : Les marchands, les artisans ou les simples habitants utilisent un contrôleur allégé. Ils n'ont pas de marqueurs pour leurs mains, ni de logique de parade.

    Urbanisme Plat : Lors de la génération procédurale des villes de ton monde, tu peux forcer les routes principales à être lisses (sans micro-dénivelés en voxels). Ainsi, les habitants civils se déplacent sur un sol parfaitement plat, rendant l'IK des jambes totalement inutile pour eux.

En limitant les calculs lourds aux 3 ou 4 ennemis qui t'attaquent simultanément, ton processeur ne subira aucune surcharge, même en plein cœur d'une cité générée procéduralement.

Souhaites-tu que nous détaillions le script qui gère cette désactivation automatique des animations basée sur la distance et la visibilité, ou préfères-tu explorer la manière dont l'intelligence artificielle des monstres va exploiter ce système de combat directionnel ?

Oui dis moi comment les PNJ/mobs alliés et ennemis utiliseront ce système

Faire utiliser un système de combat directionnel à une intelligence artificielle est un défi de design passionnant. L'objectif n'est pas de créer une IA omnisciente qui pare 100% des coups (ce qui est frustrant), mais une IA qui lit les animations du joueur et réagit avec ses propres failles.

Pour que cela tourne de manière fluide sur ton processeur sans alourdir le moteur, l'IA ne doit pas utiliser de vision complexe, mais un système de "Télégraphie" (Transmission de données) et de gestion de distance (Spacing).

Voici comment structurer le cerveau de tes PNJ et monstres.
1. La Perception de l'IA (Lire le joueur)

L'IA n'a pas d'yeux, elle lit les variables de ton contrôleur joueur via des Raycasts ou des signaux.

    Détection du Wind-up (Préparation) : Dès que le joueur clique pour attaquer, son arme entre dans la phase de "Wind-up". À cet instant précis, le script du joueur émet un signal invisible contenant la direction de l'attaque (ex: "Taille Gauche") et la cible visée.

    Lecture de la Garde : L'IA lance un Raycast vers le torse du joueur. Si elle détecte que l'angle de la caméra du joueur (le Spine Bending) est orienté vers le haut, l'IA "sait" que les jambes sont exposées.

    Conscience de l'Allonge : L'IA connaît la longueur de sa propre arme et celle du joueur. C'est ce qui définit son cercle d'engagement.

2. Le Jeu de Jambes (Spacing & Footwork)

Le combat de Mount & Blade est basé sur la distance. Ton IA doit utiliser le NavMesh de Godot combiné au système d'Auto-Step que nous avons défini.

    La Danse (Backpedal) : Si l'IA détecte le signal "Wind-up" du joueur et qu'elle a une arme courte (Dague), sa première réaction n'est pas de bloquer, mais de reculer (vitesse négative sur le vecteur Z) pour sortir de la "Hitbox" de l'arme du joueur.

    L'Engagement à la Pointe : Si un PNJ allié ou ennemi possède une Lance (Allonge très longue), son IA le maintiendra délibérément à la limite exacte de cette allonge. Il ne s'approchera jamais au contact. Il reculera si le joueur avance, et frappera en d'Estoc de loin.

3. Les Profils Comportementaux (L'Échelle de Difficulté)

Tous les ennemis ne maîtrisent pas l'art du combat. Tu peux diviser l'IA en trois strates de comportement (Behavior Trees).

    Niveau 1 : La Bête / Le Corrompu (Dimension Démoniaque)

        Comportement : Aucune parade, aucune gestion de la distance.

        Attaque : Ils foncent en ligne droite (Rush) et utilisent exclusivement des attaques Overhead (Haut-Bas) ou des morsures frénétiques.

        Contre : Le joueur doit utiliser le jeu de jambes pour reculer tout en les balayant (Taille) avec une arme longue.

    Niveau 2 : Le Soldat / Le Bandit (PNJ Standard)

        Comportement : Utilise le bouclier. Gère vaguement la distance.

        Défense : S'il reçoit le signal de "Wind-up" du joueur, il a un temps de réaction programmé (ex: 400 ms) pour lever son bouclier ou son épée dans la bonne direction via son IK. S'il est en manque d'Endurance, il panique et recule.

        Attaque : Il attaque les zones non protégées par la garde du joueur.

    Niveau 3 : Le Maître d'Armes / L'Élite (Boss de Donjon)

        Comportement : Combat systémique total.

        La Feinte (Feinting) : L'IA lance une attaque "Overhead", puis l'annule en plein Wind-up pour déclencher un "Estoc", forçant le joueur à se tromper de parade.

        La Parade Parfaite (Chambering) : Si le joueur attaque de la droite, l'IA attaque de sa gauche avec un timing parfait. Les deux armes s'entrechoquent (étincelles, son métallique), et l'attaque de l'IA continue pour frapper le joueur, inversant l'avantage.

4. La Synergie des Alliés (Formations)

Si le joueur est un Aventurier Nomade, il peut recruter des mercenaires. L'IA alliée brille par ses formations systémiques.

    Le Mur de Boucliers (Phalange) : Si deux alliés ont des boucliers, l'IA les force à se coller côte à côte. Ils utilisent le blocage IK en permanence. Si un allié possède une arme d'Hast (Pique/Hallebarde), son IA le positionnera derrière le mur de boucliers, frappant d'Estoc par-dessus les épaules de ses camarades (grâce au ciblage Raycast qui ignore les alliés).

    Le Contournement (Flanking) : Un allié équipé d'une dague en Verre Abyssal refusera le combat frontal. Son IA cherchera le dos de l'ennemi. Dès que l'ennemi déclenche une attaque contre le joueur (ce qui bloque sa rotation), l'allié frappe pour déclencher le multiplicateur de dégâts critiques (Backstab).

La mise en place de ces comportements repose sur des arbres de comportement (Behavior Trees). Godot 4 ne possède pas ce système en natif. Préfères-tu coder l'IA sous forme de machines à états finis (Finite State Machines) directement en GDScript, ou utiliser une structure modulaire de nœuds enfants pour gérer les états du cerveau ?

Imagine un scénario de combat en détaillant toutes les stats et les jets etc

Voici une reconstitution d'un affrontement généré par le moteur du jeu. Le scénario met en évidence la façon dont le code calcule la physique, la trigonométrie (IK) et les statistiques des matériaux en temps réel.
Le Cadre et les Combattants

Environnement : Un couloir de donjon généré procéduralement, avec un sol irrégulier (marches d'un bloc de haut générées par le bruit karstique).

Le Joueur (Aventurier Nomade)

    Arme : Épée Longue (Lame Acier, Manche Chêne). Allonge : 1.2m | Tranchant : 40 | Perçant : 25 | Pénétration : 10% | Wind-up : 450 ms.

    Armure : Gambeson Épais (Biomasse). Armure : 15 Tranchant / 30 Contondant | Mobilité : Maximale.

    Ressources : HP : 100/100 | Endurance : 100/100.

L'Ennemi (Maraudeur Corrompu - IA de Niveau 2)

    Arme : Masse à Ailettes (Fer lourd). Allonge : 0.8m | Contondant : 50 | Pénétration : 40% | Drain de Garde : 50 | Wind-up : 600 ms.

    Armure : Plastron de Plates. Armure : 60 Tranchant / 40 Perçant / 20 Contondant | Stabilité (Poise) : Élevée.

    Ressources : HP : 150/150 | Endurance : 100/100.

Phase 1 : L'Engagement et la Distance (Jeu de jambes)

Le Maraudeur aperçoit le joueur et charge. Le joueur recule en diagonale.
Le terrain voxel présente un dénivelé d'un mètre (un bloc). Le joueur recule dessus.

    Moteur : Le Raycast des pieds du joueur détecte l'obstacle d'un bloc. Le script Auto-Step ajoute instantanément +1 en Y. L'IK plie la jambe droite sur le bloc supérieur, la gauche reste tendue. Le mouvement est fluide, la visée n'est pas interrompue.

    Analyse d'Allonge : Le joueur possède 1.2m d'allonge, le Maraudeur 0.8m. Le joueur a l'avantage de la première frappe s'il gère son "Spacing".

Phase 2 : La Frappe (Collision des Matériaux)

Le joueur déclenche une attaque Taille Latérale (Gauche à Droite) en reculant.

    Moteur (Signal) : Wind-up initié (450 ms). L'animation tourne.

    Impact (Raycast) : À la frame 27, le Raycast de l'épée percute le CharacterBody3D du Maraudeur au niveau du torse.

    Calcul des dégâts :

        Attaque : 40 Tranchant (Épée Acier).

        Défense : 60 Tranchant (Plastron).

        Formule : Dégâts = Attaque - (Armure * (1 - Pénétration))

        Maths : 40 - (60 * 0.90) = 40 - 54 = -14.

    Résultat visuel : L'épée rebondit dans une gerbe d'étincelles. Dégâts infligés : 1 HP (dégât de choc résiduel). Le Maraudeur ne subit aucun "Stagger" car sa Stabilité (Poise) est trop élevée.

Phase 3 : La Contre-attaque et l'IK (Parade Directionnelle)

Ne reculant pas sous le coup, le Maraudeur déclenche une attaque Overhead (Haut-Bas) avec sa Masse.

    Moteur (IA) : Wind-up initié (600 ms). L'arme est lourde.

    Réaction du Joueur : Le joueur comprend que l'esquive est impossible dans ce couloir étroit. Il clique droit (Parade) et regarde vers le haut (Pitch Caméra +45°).

    Trigonométrie (IK) : La colonne vertébrale du joueur (Spine Bending) bascule en arrière. Les mains (guidées par les Marker3D de l'épée à 1.2m d'écart) se lèvent horizontalement au-dessus du visage.

    Choc (Frame 36) : La Masse percute la hitbox de l'épée en position de blocage.

Phase 4 : Le Calcul de Parade et l'Endurance

Le coup n'a pas touché le corps, mais l'énergie cinétique doit être absorbée.

    Drain de Garde : La Masse inflige 50 points de Drain de Garde.

    Endurance du Joueur : 100 - 50 = 50/100 Endurance restante.

    Intégrité Structurelle de l'Arme : Le choc de la fonte contre l'acier draine 15 points de durabilité à l'Épée du joueur (Risque de brisure à long terme).

    Résultat : Le joueur encaisse le choc. Son écran tremble (Camera Shake calculé sur le poids de la masse adverse), mais il n'est pas étourdi (Staggered).

Phase 5 : L'Exploitation du Système (Le Coup de Grâce)

Le Maraudeur vient de rater sa frappe lourde. L'inertie de sa masse en fonte vers le bas l'empêche de lever son arme pour se défendre (Cooldown d'animation). Le joueur comprend que l'armure de plates est invulnérable au Tranchant.

    Input Joueur : Le joueur vise le visage du Maraudeur (non protégé par les plates) et déclenche un Estoc (Poussée droite).

    Moteur : Le bras gauche s'étend via l'IK à la vitesse fulgurante de 300 ms (bonus de vitesse de la compétence "Maîtrise du Perçant").

    Impact (Raycast) : L'arme frappe la "Hitbox Tête" (Zone non armurée).

    Calcul des dégâts :

        Attaque : 25 Perçant.

        Défense de la tête : 0.

        Multiplicateur Point Faible (Tête) : x2.5.

        Maths : 25 * 2.5 = 62.5 dégâts.

    Conséquence : Le Maraudeur perd 62 HP d'un coup sec. Étant frappé à la tête, sa Stabilité est outrepassée. Il subit un "Stagger" complet, l'obligeant à reculer d'un pas en titubant, laissant au joueur le temps de régénérer son Endurance pour le coup final.

    Le code a géré sans aucune allocation mémoire les raycasts de surface, le blending de la colonne vertébrale, l'invalidation de l'armure et l'inertie des matériaux, offrant un combat viscéral sans jamais utiliser de verrouillage de cible "Tab-Targeting".

Planifier le code des calculs de dommages ?

Serait possible de rajouter les démembrement ? Et comment gérer ça avec les modèles fait sur blockbench, idem pour les animations procédurales

C'est une excellente idée qui renforce l'aspect viscéral et punitif de ton système de combat. La bonne nouvelle, c'est qu'avec des modèles conçus sur Blockbench (esthétique low-poly/cubique) et un système d'animation procédurale (IK), le démembrement est techniquement beaucoup plus facile et léger à gérer qu'avec des modèles ultra-réalistes.

Oublie les calculs complexes de découpe de maillage en temps réel (qui tueraient ton Intel UHD 620). L'industrie utilise une astuce redoutable basée sur la manipulation du squelette.

Voici le plan d'implémentation de A à Z.
1. La Préparation dans Blockbench (Le Maillage Segmenté)

Pour que le démembrement soit propre, il ne faut pas qu'un seul gros bloc 3D recouvre plusieurs os (avec des poids de vertex complexes qui s'étirent). Ton modèle Blockbench doit être segmenté.

    Structure Minecraft-like : Le bras n'est pas soudé à l'épaule. L'avant-bras (LowerArm) est un cube distinct du bras (UpperArm). Ils se chevauchent légèrement au niveau du coude.

    Le Squelette (Rigging) : Chaque segment de chair correspond à 100% à un seul os. Le cube de l'avant-bras a un poids (Weight) de 1.0 sur l'os Bone_LowerArm.

    L'Avantage : Quand tu coupes, il n'y a pas de texture étirée à recalculer. C'est propre, géométrique et parfaitement dans le thème Voxel.

2. L'Astuce Godot 4 : Ne pas couper le maillage, couper l'Os

Dans Godot, quand une attaque "Tranchante" (Slashing) atteint un certain seuil de dégâts sur une Hitbox spécifique (ex: Bras Droit), tu déclenches le démembrement via le Skeleton3D.

    La Disparition (Scale à Zéro) : Au lieu de modifier le Mesh, le code cible l'os sectionné (ex: Bone_LowerArm_R) et passe son échelle (Scale) à Vector3(0, 0, 0).

    L'Effet Cascade : Puisque la main et l'arme sont enfants de l'avant-bras, tout disparaît instantanément. L'épaule, elle, reste intacte. Le coût CPU de cette opération est de 0.0001 ms.

    Le Faux Membre (RigidBody) : À la frame exacte où l'os disparaît, tu instancies une scène pré-faite bras_droit_coupe.tscn (un RigidBody3D avec le même modèle Blockbench) aux coordonnées exactes de l'os. Tu lui appliques une impulsion (Knockback) basée sur la direction de ton arme. Le bras vole dans le décor avec la physique de Godot.

    Le Sang Voxel : Tu fais spawner un GPUParticles3D de petits cubes rouges (du sang voxelisé) au niveau de la coupe pour masquer la transition.

3. Comment gérer l'IK (Cinématique Inverse) ?

C'est ici que l'IK montre toute sa supériorité sur les animations traditionnelles. Si tu avais des animations statiques, couper un bras casserait toute la boucle d'animation. Avec l'IK, le code s'adapte.

    Désactivation du Modificateur : Dès que le démembrement est appelé, le code cherche le nœud SkeletonModifier3D responsable du bras coupé et le désactive (modifier.active = false).

    Conséquence immédiate : L'os invisible cesse d'essayer d'atteindre la cible (la poignée de l'arme).

    Réajustement de la Posture :

        Si un ennemi perd son bras gauche (qui tenait le bouclier), ton code supprime le bouclier, coupe l'IK du bras gauche, mais le bras droit continue de te viser parfaitement avec son épée.

        S'il perd son arme à 2 mains, le code bascule l'arme restante en mode "1 main", et l'IK du bras survivant s'adapte instantanément pour tenir l'arme de côté.

4. L'Impact Systémique (Gameplay)

Le démembrement ne doit pas être qu'un effet visuel, il doit affecter la boucle de gameplay (surtout avec tes arbres de compétences "Maîtrise du Tranchant").

    Perte de Jambe : Si la jambe est coupée, l'auto-step et le Ground IK de cette jambe sont désactivés. Le CharacterBody3D de l'ennemi voit sa vitesse réduite de 90%. Il tombe au sol (tu peux activer le mode Ragdoll physique) mais peut encore essayer de ramper vers toi.

    Perte du Bras Armé : Si tu coupes le bras droit du Maraudeur, il lâche sa Masse à Ailettes (qui devient un objet ramassable). S'il survit au choc, l'IA bascule en mode "Fuir" ou tente de te frapper à mains nues (ou avec les dents) avec une allonge ridicule.

    Létalité (Décapitation) : Toucher la Hitbox de la Tête avec suffisamment de dégâts tranchants et le perk "Démembrement" déclenche la mort instantanée (bypass des HP restants) et l'explosion de l'os Bone_Head.

Le Squelette de Code (L'Action de Coupe)

Voici la logique ultra-légère à exécuter lors de l'impact critique :
GDScript

func sever_limb(bone_name: String, hit_direction: Vector3) -> void:
    var bone_idx = skeleton.find_bone(bone_name)
    if bone_idx == -1: return
    
    # 1. Rendre l'os (et ses enfants) invisible
    skeleton.set_bone_pose_scale(bone_idx, Vector3.ZERO)
    
    # 2. Couper le comportement de l'IA et l'IK associé
    _disable_ik_for_bone(bone_name)
    _drop_equipment_from_bone(bone_name)
    
    # 3. Faire spawner le "Gib" (le membre physique)
    var gib_instance = PRELOADED_GIBS[bone_name].instantiate()
    get_tree().current_scene.add_child(gib_instance)
    
    # Placer le membre là où était l'os
    gib_instance.global_transform = skeleton.global_transform * skeleton.get_bone_global_pose(bone_idx)
    
    # Le faire voler
    gib_instance.apply_central_impulse(hit_direction * force_multiplier)
    
    # 4. Particules de sang voxel
    _spawn_voxel_blood(gib_instance.global_position)

En résumé : l'esthétique Blockbench et l'animation procédurale sont les meilleurs alliés du démembrement. C'est peu coûteux en performances, extrêmement satisfaisant visuellement, et ça pousse le joueur à viser des parties du corps spécifiques en fonction de l'équipement de l'adversaire.

Redonne moi les points pour la refonte du système de déplacement/animations/combat

Voici le plan directeur pour la refonte complète de ton système de déplacements, d'animations et de combat. Ce résumé regroupe toutes les solutions techniques validées pour garantir la fluidité sur ton architecture Voxel tout en préservant tes performances (Intel UHD 620).
1. Déplacements et Interactions avec le Terrain (Auto-Step)

L'objectif est d'assurer un "jeu de jambes" fluide, vital pour un combat basé sur la distance, sans détruire les performances avec des sous-voxels.

    Refus du lissage géométrique : Le terrain reste constitué de blocs pleins pour conserver le Greedy Meshing et préserver la RAM et le GPU.

    Implémentation de l'Auto-Step : Le CharacterBody3D utilise des Raycasts (vers l'avant et vers le bas) pour détecter les marches d'un bloc de haut. Le joueur est automatiquement surélevé (+1 en Y) sans avoir à sauter.

    Résultat : Le joueur glisse sur les collines voxelisées, ce qui permet de se concentrer sur la parade et l'esquive (Spacing) sans rester bloqué par le décor.

2. Animations Procédurales (Cinématique Inverse - IK)

L'abandon des animations figées au profit des mathématiques, idéal pour tes modèles low-poly créés sous Blockbench.

    Ground IK (Jambes) : Des Raycasts ajustent dynamiquement la hauteur des pieds pour épouser les blocs inégaux. Si un pied est sur un bloc surélevé, le genou se plie automatiquement.

    Weapon IK (Bras) : Les mains suivent des cibles (Marker3D) placées sur l'arme générée. Si l'arme est une dague, les bras restent serrés. Si c'est une pique de 3 mètres, le bras gauche s'étend au maximum. Un seul set d'animations suffit pour toutes les armes du jeu.

    Spine Bending (Buste) : La colonne vertébrale s'incline mathématiquement selon l'angle de tangage (Pitch) de la caméra. Cela permet de viser les jambes ou la tête, et d'ajuster la hauteur des parades.

3. Système de Combat Directionnel (Type Mount & Blade)

Un gameplay physique, sans ciblage automatique (Tab-Targeting), basé sur l'inertie et la physique des matériaux.

    Attaques Directionnelles : Lecture du mouvement de la souris après le clic pour déterminer le coup (Estoc, Taille, Overhead).

    Hitboxes Dynamiques : Utilisation de Raycasts balayés le long de la lame à chaque frame de l'animation pour une précision absolue (détection des têtes, bras, jambes).

    Parade Active (IK) : Le clic droit déplace l'arme ou le bouclier devant la caméra. L'IK plie les bras en position de garde. L'angle de la caméra détermine la zone protégée.

    Statistiques Systémiques : Le poids, la portée et la vitesse d'attaque (Wind-up) sont calculés dynamiquement selon la densité des matériaux (Acier, Plomb, Bois) et la longueur des manches.

    Gestion de l'Endurance : Bloquer un coup lourd (ex: Masse) avec une arme légère draine massivement l'endurance. Sans endurance, la garde est brisée (Stagger).

4. Démembrement Voxel et Létalité

Une gestion punitive et très peu coûteuse en ressources, s'appuyant sur l'esthétique Blockbench.

    Modèles Segmentés : Les bras et les jambes sont séparés en cubes distincts (un cube = un os), évitant les déformations complexes de textures.

    Mise à l'échelle Zéro : Sur un coup tranchant critique, l'os sectionné passe à Vector3.ZERO (rendant le membre invisible instantanément).

    Désactivation IK : Le système IK du membre coupé est désactivé. S'il s'agit du bras armé, l'entité lâche son arme et son comportement change.

    Gibbing Physique : Instanciation d'un RigidBody3D (le bras coupé) avec une impulsion physique pour le faire voler, masqué par une gerbe de particules de sang voxel.

5. Intelligence Artificielle et Optimisation (Culling)

Garantir que le système tourne même avec des dizaines d'entités affichées (Villes et Donjons).

    Culling de Distance : Au-delà de 15 blocs, les nœuds SkeletonModifier3D (IK) sont totalement désactivés. Les entités lointaines ou pacifiques (citadins) utilisent des animations rigides standards.

    Frustum Culling : Désactivation des animations procédurales pour tout ennemi caché par un mur ou situé dans le dos du joueur (via VisibleOnScreenNotifier3D).

    Télégraphie (IA) : Les ennemis ne "voient" pas les coups, ils interceptent des signaux invisibles émis lors de la phase de "Wind-up" de ton attaque pour décider s'ils doivent bloquer, esquiver (reculer) ou contre-attaquer en fonction de la longueur de leur propre arme.
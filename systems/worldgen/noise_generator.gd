class_name NoiseGenerator
extends RefCounted
## Générateur du monde par couches de bruit (étape D.3.2 — 3.0/E.2/G.4).
## - Une seule génération continue : les couches sont des fonctions f(x, z)
##   sur les coordonnées MONDE en blocs (E.2) — la cellule et la carte ne
##   seront que des fenêtres sur ce champ.
## - Les 8 couches (B.8) viennent de data/noise_layers.json via GameData ;
##   FastNoiseLite natif partout, jamais de bruit en GDScript (G.4).
## - Terrain spectaculaire (E.2) : continentalité + relief ridged masqué
##   (chaînes de montagnes, pics 200-400 au-dessus des plaines) + domain
##   warping à 1 niveau (G.4 : pas de warp imbriqué) + terrasses
##   conditionnelles là où la couche sismique est forte (falaises/mesas).
## - Biomes (B.6) : le biome d'une colonne = biome de priorité la plus haute
##   dont toutes les conditions matchent les valeurs de bruit à ce point.
## - Strates par dureté (G.9/3.2) : data/strata.json, évaluées par colonne,
##   bruit de transition pour des frontières organiques. Interprétation :
##   y_max est exprimé en PROFONDEUR SOUS LA SURFACE LOCALE (convention
##   « Y=0 à la surface », 3.2) — le verrou de progression suit le terrain.
## - Tout est seedé et déterministe (G.1) ; objet immuable après _init →
##   appelable depuis les threads de meshing sans verrou.
## - Lacs/océans (2026-07-20) : niveau de mer global WATER_LEVEL — tout point
##   dont le terrain solide est sous ce niveau se remplit d'eau jusque-là.
## - Transitions de biomes (2026-07-20) : à l'approche d'une frontière, le
##   matériau de surface est mélangé par dithering déterministe avec celui
##   du biome voisin (façon Minecraft) plutôt qu'une coupure nette.
##
## --- Refonte géologique/climatique "réalisme Terre" (2026-07-20, demande
## explicite section 3.0/E.2/B.6) — AJOUTS ci-dessous, avec les
## SIMPLIFICATIONS ASSUMÉES et disclosed explicitement (un monde infini,
## streamé par chunks, en temps réel, sur un iGPU Intel UHD 620 en GDScript
## pur, ne peut PAS faire tourner une simulation hydraulique/gazeuse globale
## à l'échelle réelle de la Terre — l'objectif visé est un réalisme
## PERÇU/PROCÉDURAL crédible, jamais une simulation physique exacte) :
##
## 1. Climat par LATITUDE (_temperature_at) : la température n'est plus un
##    bruit pur mais une bande de latitude (fonction de la coordonnée monde Z,
##    cycle pôle→équateur→pôle) + une perturbation locale (l'ancienne couche
##    "temperature", réutilisée comme bruit de variation) + un refroidissement
##    par altitude (lapse rate, E.2). SIMPLIFICATION : la période pôle-à-pôle
##    (LATITUDE_HALF_PERIOD) est compressée à une échelle JOUABLE (des
##    dizaines de km, pas les ~10 000 km réels) — sinon aucun joueur ne
##    traverserait jamais une seule bande climatique.
## 2. Ombre pluviométrique (_humidity_at) : l'humidité est réduite derrière un
##    grand relief au vent dominant (fixe, +X→-X). SIMPLIFICATION : utilise le
##    bruit de continentalité comme proxy de relief (pas la hauteur exacte
##    warpée/ridged, trop coûteuse à rééchantillonner pour un simple effet
##    d'ombre) — un seul échantillon de bruit supplémentaire.
## 3. Orogenèse (_terrain) : le masque de montagnes combine désormais le pic
##    d'altitude ET le GRADIENT de continentalité (bords de plaques = chaînes
##    côtières, façon Andes/Rocheuses), pas seulement l'intérieur des masses
##    continentales.
## 4. Rivières (_river_*) : sources déterministes en haute altitude, tracées
##    par descente de gradient (steepest descent) jusqu'à la mer ou un lac
##    endoréique, mises en cache (comme les arbres). SIMPLIFICATION ASSUMÉE :
##    recherche de sources bornée à une fenêtre régionale autour du chunk
##    généré (RIVER_SEARCH_RADIUS) — un fleuve dont la source est plus
##    lointaine que cette fenêtre n'est PAS retrouvé (pas de bassin versant
##    global précalculé, incompatible avec un monde infini streamé).
## 5. Littoraux (_coastal_material) : matériau de rivage choisi par PENTE
##    locale (réutilise le gradient déjà calculé pour l'orogenèse, aucun
##    échantillonnage supplémentaire) — plage de sable en pente douce, galets
##    en pente moyenne, falaise en pente forte, marécage si humidité haute.
## 6. Cavernes karstiques (_cave_carve) : REMPLACE le bruit 3D creusé nu par
##    deux bruits "vers" (tunnels sinueux, intersection de 2 champs ridgés) +
##    un bruit de cavité basse fréquence (grandes salles). Bornées en
##    profondeur (jamais proche de la surface ni du plancher du monde).
## 7. Spéléothèmes (_speleothem_pass) : stalactites/stalagmites/colonnes
##    (calcite) posées aux transitions plafond/sol des poches d'air
##    souterraines, densité faible, déterministe. SIMPLIFICATION : détection
##    bornée au chunk courant (une poche à cheval sur 2 chunks peut avoir des
##    spéléothèmes visuellement coupés à la frontière).
## 8. Gaz souterrains : RETIRÉS de la génération (2026-07-20, demande
##    explicite) — la spec E.2.5 (placement règle-basé dans les poches
##    d'air) reste au GDD comme référence si le système revient un jour ;
##    aucune fonction correspondante dans ce fichier actuellement.

const SUBSURFACE_THICKNESS := 3          # Blocs de sous-surface biome sous le bloc de surface.
## Arbres (végétation des biomes, B.6 `vegetation`) — génération procédurale
## complète (TreeGenerator), plusieurs essences par biome, tronc+branches+
## canopée en vrais volumes 3D pouvant déborder sur les colonnes/chunks
## voisins (silhouettes réalistes, pas des poteaux à pompon).
## TREE_MAX_REACH borne la recherche de voisinage (rayon horizontal max
## qu'un arbre peut atteindre depuis sa base — canopée + branches) : doit
## rester ≥ à la plus grande combinaison canopy_radius+branch_length des
## essences de data/trees/*.json.
##
## Porté de 7 à 10 le 2026-08-03 : les charpentières portent désormais des
## rameaux qui repartent de leur dernier tiers, et le pied s'évase en racines.
## Sous-estimer cette borne ne se voit pas à la génération — ça se voit à
## l'ABATTAGE, où la recherche inverse ne retrouve plus l'arbre auquel appartient
## un rameau lointain, et le morceau reste suspendu en l'air.
##
## ---------------------------------------------------------------------------
## LA PORTÉE VIENT DES DONNÉES DEPUIS LE 2026-08-04, ET C'EST UNE CORRECTION
## ---------------------------------------------------------------------------
## Cette constante valait 13 pendant que QUATRE essences allaient plus loin :
## `arbre_geant_songe` (35), `arbre_velours` (20), `platane` (16), `fromager`
## (15) — dont deux dans l'OVERWORLD. Elles étaient donc silencieusement
## TRONQUÉES aux frontières de chunk-colonne : la moitié de la couronne
## n'existait pas, et rien n'échouait. Aucune fiche ne pouvait le dire non plus,
## `canopy_radius` annonçant 14 là où le squelette récursif va chercher 35.
##
## Chaque fiche porte maintenant sa `reach`, MESURÉE sur neuf graines avec deux
## blocs de marge, et `--probe-arbres` échoue si la réalité dépasse la donnée.
##
## LE PLAFOND N'A PAS RENDU LE SCAN PLUS CHER, IL L'A RENDU MOINS CHER : la
## fenêtre s'ouvre à la plus large essence du catalogue, mais chaque candidat
## est écarté d'après SA PROPRE portée avant qu'on ne génère quoi que ce soit.
## Auparavant, un chêne de 10 blocs de portée planté à 13 blocs de la colonne
## était généré intégralement pour être ensuite ignoré.
var _tree_reach := {}        # id d'essence → portée horizontale (blocs)
var _tree_reach_max := 13


## Portées d'essences, lues une fois au démarrage.
func _compile_tree_reach() -> void:
	_tree_reach.clear()
	_tree_reach_max = 1
	for species_id: String in GameData.trees:
		var declared := int((GameData.trees[species_id] as Dictionary).get("reach", 0))
		if declared <= 0:
			# Une fiche sans portée déclarée ne doit PAS être tronquée en
			# silence : on lui prête le maximum du catalogue, quitte à la
			# scanner de trop loin. La sonde, elle, réclamera la vraie valeur.
			push_warning("NoiseGenerator : essence « %s » sans champ `reach`." % species_id)
			declared = 35
		_tree_reach[species_id] = declared
		_tree_reach_max = maxi(_tree_reach_max, declared)


## Portée de la fenêtre de recherche : celle de la plus large essence.
var TREE_MAX_REACH: int:
	get:
		return _tree_reach_max
## Candidats testés par CELLULE (comme les POI, E.2 : « hash(seed, cell_x,
## cell_z) »), pas par bloc individuel — un scan par bloc mesuré au bench
## coûtait ~50 % de fps (900 colonnes/chunk-colonne). Une cellule 4×4 donne
## au plus un arbre ; la densité (probabilité par BLOC dans les données B.6)
## est mise à l'échelle par l'aire de la cellule.
const TREE_CELL_SIZE := 4
const SEED_TREE_PRESENCE := 9105
## Plantes de sol (2026-07-20) : cellule plus fine que les arbres (footprint
## d'un seul bloc, pas de fenêtre de recherche voisine nécessaire).
const PLANT_CELL_SIZE := 2
const SEED_PLANT_PRESENCE := 9108
## Cultures/flore en sous-voxels (2026-07-20, PlantGenerator) — cellule un
## peu plus large que les plantes de sol (structures plus visibles,
## densité naturellement plus faible : blé/safran/etc. ne doivent pas
## saturer chaque bloc).
const CULTURE_CELL_SIZE := 4
const SEED_CULTURE_PRESENCE := 9117
## Budget de sous-grilles PROCÉDURALES par chunk — bien en dessous des 512
## du budget joueur (WorldManager.SUBDIV_BUDGET_PER_CHUNK) pour laisser de
## la marge à la construction après génération.
const CULTURE_SUBDIV_BUDGET := 40
const WARP_AMPLITUDE := 40.0             # Domain warping, 1 niveau (G.4).
const TERRACE_STEP := 40.0               # Hauteur des falaises/mesas (E.2 : 30-80).
const SEISMIC_THRESHOLD := 0.6           # Terrasses seulement où la couche sismique est forte.
## Décalages de graine internes aux composantes du terrain (E.2) — hors des
## 8 couches de données B.8, dérivés de la graine monde (déterministes).
const SEED_RIDGED := 9101
const SEED_WARP_X := 9102
const SEED_WARP_Z := 9103
const SEED_TRANSITION := 9104
## Niveau de mer (blocs) : sous ce niveau, tout terrain plus bas se noie
## (lacs dans les bassins, océans dans les grandes zones basses — E.2 :
## "les minima locaux larges sous le niveau d'eau régional → GRANDS LACS").
const WATER_LEVEL := 2
## Largeur de la zone de mélange entre deux biomes (unités normalisées de
## conditions, 0..1) — au-delà, le biome est pur, pas de dithering.
const BIOME_TRANSITION_MARGIN := 0.05
const SEED_BIOME_DITHER := 9107

## --- Climat (2026-07-20) ---
## Demi-période pôle-à-pôle (blocs) — voir note d'en-tête, échelle JOUABLE,
## pas l'échelle réelle. fz=0 : équateur. fz=±LATITUDE_HALF_PERIOD : pôle.
const LATITUDE_HALF_PERIOD := 12000.0
const TEMPERATURE_LAPSE_RATE := 0.35   # Perte de "chaleur normalisée" au sommet des plus hauts reliefs.
const TEMPERATURE_LAPSE_REF_HEIGHT := 400.0
const RAIN_SHADOW_UPWIND_OFFSET := 250.0
const RAIN_SHADOW_THRESHOLD := 0.6
const RAIN_SHADOW_STRENGTH := 1.2
const OROGENY_GRADIENT_SAMPLE := 40.0

## --- Monde fini : continents / grands océans (2026-07-26) ---
## Le monde n'est plus infini : au-delà de _land_radius, le terrain plonge vers
## l'océan profond, formant une barrière d'eau (« monde entouré d'eau »). La
## génération reste une fonction pure de la graine (aperçu au menu possible).
const DEFAULT_WORLD_RADIUS := 20000      # Rayon du bord extérieur (2026-07-26 : 10000→20000, monde ~4× plus grand ; texture précise même loin de l'origine).
const WORLD_EDGE_OCEAN := 2200           # Largeur de l'anneau océanique de bordure.
## Composition d'altitude recomposée (2026-07-26) — biais PLAINES : base douce,
## collines modestes, MONTAGNES rares (masquées, l'exception, plus le binaire
## plat/montagne d'avant). `cont` = champ de continentalité normalisé [0,1].
## Structure continentale (2026-07-26, refonte « type Terre ») : un champ MACRO
## très basse fréquence décide de PEU de GRANDS continents (pas l'effet éponge de
## blobs uniformes), fortement warpé pour des côtes organiques (presqu'îles,
## golfes), + un détail haute fréquence de faible poids pour la côte et les îles.
const SEED_CONTINENT := 9140
const SEED_CONT_WARP_X := 9141
const SEED_CONT_WARP_Z := 9142
const CONTINENT_FREQ := 0.000115         # Longueur d'onde ~8700 blocs → 3-6 masses majeures.
const CONT_WARP_FREQ := 0.00035
const CONT_WARP_AMP := 900.0             # Déformation forte = côtes découpées, pas des ronds.
const CONT_DETAIL_WEIGHT := 0.14         # Poids du détail de côte (petites îles, dentelure).
const COAST_CONT := 0.47                 # Valeur de `cont` au trait de côte (h = niveau de la mer).
const LAND_GAIN := 46.0                  # Pente des terres émergées (cont → hauteur) — douce, plaines dominantes.
const OCEAN_GAIN := 150.0                # Profondeur des océans (grands océans profonds).
const HILL_AMP := 9.0                    # Amplitude des collines sur les terres (accent, pas la règle).
const MTN_START_CONT := 0.80             # `cont` au-delà duquel les montagnes apparaissent (rare).
const MTN_AMP := 300.0                   # Amplitude des chaînes de montagnes (l'exception).
const SEED_HILLS := 9130
## Élévation de référence (blocs au-dessus de la mer) pour normaliser la
## condition d'ALTITUDE des biomes (2026-07-26). Un biome « montagne » (alt
## 0.62-1.0) ne se déclenche qu'au-delà de ~ELEV_REF×0.62 blocs — sinon
## l'intérieur des continents (continentalité haute mais RELIEF plat) était
## faussement classé montagne, écrasant les bandes climatiques.
const ELEV_REF := 140.0
## --- Types de terrain (2026-07-26) : canyons, volcans, fjords, mesas ---
const SEED_CANYON := 9150
const SEED_FJORD := 9151
const SEED_VOLCANO := 9152
const CANYON_FREQ := 0.004
const CANYON_DEPTH := 58.0                # Profondeur des gorges (zones sèches).
const FJORD_FREQ := 0.006
const FJORD_DEPTH := 62.0                 # Profondeur des bras de mer glaciaires (latitudes froides).
const VOLCANO_CELL := 1500                # Grille de placement des volcans (rare).
const VOLCANO_CHANCE := 0.06              # Proba qu'une cellule porte un volcan.
const VOLCANO_RADIUS := 230.0            # Rayon d'un cône volcanique.
const VOLCANO_HEIGHT := 190.0            # Hauteur du cône (avant cratère).
const MESA_DRY_BONUS := 1.6              # Amplification des terrasses (mesas) en zone aride.
## --- Fertilité (2026-07-26) : module la densité de végétation DANS un biome ---
## fertilité ∈ [0,1] (1 = aussi luxuriant que la densité de base du biome).
## Le joueur prospecte les zones fertiles (humides, tempérées, basses, bon sol).
const SEED_FERTILITY := 9131

## --- Rivières (2026-07-20) ---
const RIVER_CELL_SIZE := 512             # Grille de sources candidates (POI G.4).
const RIVER_MAX_DENSITY_ENVELOPE := 0.05 # Rejet bon marché (même leçon que TREE/PLANT).
const RIVER_MIN_ALTITUDE := 0.68         # Une source doit naître en altitude.
const RIVER_STEP := 12.0                 # Longueur d'un segment de traçage (blocs).
const RIVER_MAX_STEPS := 700             # ~8400 blocs de long au maximum.
const RIVER_SEARCH_RADIUS := 3000        # Fenêtre régionale de recherche de sources (simplification assumée, voir en-tête).
const RIVER_WIDTH_BASE := 2.0
const RIVER_WIDTH_PER_STEP := 0.01       # Élargissement progressif (confluence approximée par la distance parcourue).
const RIVER_WIDTH_MAX := 9.0
const SEED_RIVER_PRESENCE := 9109
const SEED_RIVER_DESCENT := 9110

## --- Cavernes/karst (2026-07-20) ---
## Doit rester synchronisé avec WorldManager.WORLD_Y_MIN (-512, 3.2) — dupliqué
## ici pour éviter une dépendance circulaire (WorldManager crée ce générateur).
const WORLD_FLOOR := -512
## Profondeur mini SOUS la surface (2026-07-26 : 10→22). À 10, les cavernes —
## surtout les « grandes salles » — débouchaient sur les flancs RAIDES des
## montagnes (désormais bien plus hautes) → gros trous visibles. À 22, elles
## restent enfouies et n'éventrent plus les reliefs.
const CAVE_MIN_DEPTH := 22               # Jamais de caverne à moins de 22 blocs de la surface.
const CAVE_MAX_DEPTH_FROM_FLOOR := 24     # Jamais à moins de 24 blocs du plancher du monde.
## Le karst réel ne s'étend pas indéfiniment en profondeur — plafonne aussi le
## COÛT (jusqu'à 3 échantillons de bruit 3D par bloc solide testé, le poste
## le plus cher de tout le générateur). Réduit de 300 à 100 (2026-07-20,
## après mesure) : à 300, le meshing moyen tournait à ~22 ms (bench vol),
## contre ~6-9 ms avant les cavernes — 100 réduit fortement le volume de
## blocs testés (la plupart des chunks n'atteignent pas cette profondeur
## sous leur surface locale) sans éliminer les cavernes profondes utiles.
const CAVE_MAX_DEPTH := 100
const CAVE_TUNNEL_THRESHOLD := 0.05       # |bruit A| et |bruit B| < seuil = tunnel (intersection façon vers).
const CAVE_CAVERN_THRESHOLD := 0.74       # Bruit de cavité > seuil = grande salle (0.62→0.74 : salles plus RARES, moins de gros trous en montagne).
## Rejet bon marché par cellule (2026-07-20, ajouté après mesure perf) : une
## zone de CAVE_CELL_SIZE blocs de côté (2^CAVE_CELL_SHIFT) n'a de chance de
## contenir des cavernes qu'avec probabilité CAVE_CELL_ACCEPT — la vaste
## majorité des colonnes ne paient alors JAMAIS le bruit 3D karstique.
const CAVE_CELL_SHIFT := 4                # 2^4 = 16 blocs de côté (= 1 chunk).
const CAVE_CELL_ACCEPT := 0.4
const SEED_CAVE_CELL := 9116
const SEED_CAVE_A := 9111
const SEED_CAVE_B := 9112
const SEED_CAVERN := 9113

## --- Spéléothèmes (2026-07-20) ---
const SPELEOTHEM_CHANCE := 0.06
const SEED_SPELEOTHEM := 9114

var world_seed: int
## --- Paramètres de monde (2026-07-21, menu « nouvelle partie ») ---
## Fournis par le profil du monde (SaveManager, persistés dans world.json) —
## défauts = le monde standard. Un monde « très plat » ou « tout désert » se
## règle ici, jamais en dur.
var water_level := WATER_LEVEL      # Niveau de la mer effectif (WATER_LEVEL const = défaut).
var _p_relief := 1.0                # Multiplicateur d'amplitude du relief (0.1 = quasi plat).
## Monde fini (2026-07-26) : rayon du bord océanique, réglable par le profil.
var world_radius := DEFAULT_WORLD_RADIUS
var _land_radius := DEFAULT_WORLD_RADIUS - WORLD_EDGE_OCEAN
## Demi-période de latitude = rayon du monde : équateur au CENTRE (fz=0), pôles
## aux BORDS nord/sud (fz=±world_radius) → le monde couvre tout le climat, des
## calottes glaciaires à la jungle équatoriale (style Terre, 2026-07-26).
var _lat_period := float(DEFAULT_WORLD_RADIUS)
var _hills: FastNoiseLite            # Collines de terre (moyenne fréquence, faible amplitude).
var _canyon: FastNoiseLite          # Gorges/canyons (ridged, zones sèches).
var _fjord: FastNoiseLite           # Fjords/bras de mer (ridged, latitudes froides).
var _continent: FastNoiseLite       # Macro-structure des grands continents (très basse fréquence).
var _cont_warp_x: FastNoiseLite     # Déformation basse fréquence des côtes (organiques).
var _cont_warp_z: FastNoiseLite
var _fertility_noise: FastNoiseLite  # Richesse de sol basse fréquence (fertilité).
var _p_temp_offset := 0.0           # Décalage de température normalisée (-0.5..+0.5).
var _p_hum_offset := 0.0            # Décalage d'humidité normalisée.
var _p_tree_mult := 1.0             # Multiplicateur de densité d'arbres (0 = aucun).
var _p_rivers := true
var _p_caves := true
var _p_forced_biome := ""           # Id de biome forcé partout ("" = normal).
## MONDE PLAT (`terrain: "plat"`, 2026-08-06) — le sol du monde VITRINE.
##
## Ce n'est PAS un second générateur, et ça ne doit jamais le devenir : c'est
## une branche de `_terrain` qui rend une hauteur constante. Tout le reste du
## pipeline — biomes, matériaux de surface, chunks, LOD, maillage, éviction —
## continue de tourner sans une ligne de plus, exactement comme l'unification
## des dimensions l'a rendu possible. Écrire un « FlatGenerator » à côté
## reproduirait le doublon de pipeline qui a coûté RiftBuilder.
##
## Les systèmes de l'overworld qui n'ont aucun sens sur une dalle (cavernes,
## rivières, villes, tours, arbres, plantes) se coupent par les interrupteurs
## qui EXISTENT DÉJÀ pour eux — pas par de nouveaux `if _p_flat` semés partout.
var _p_flat := false
## Hauteur du sol plat. AU-DESSUS du niveau de la mer (64 par défaut) : une
## dalle sous l'eau ferait un monde vitrine noyé, et le défaut ne se verrait
## qu'à la première capture.
const FLAT_HEIGHT := 72.0
var _forced_biome_index := -1
var _water_id := 0
## Littoraux (2026-07-20) : ids résolus une fois, sélection par pente locale.
var _sand_id := 0
var _gravel_id := 0
var _cliff_id := 0
var _marsh_id := 0
var _marsh_sub_id := 0
## Spéléothèmes (2026-07-20) : calcite (stalactites/stalagmites/colonnes),
## guano (dépôts organiques au sol des cavernes profondes).
var _calcite_id := 0
var _guano_id := 0
var _herbe_id := 0

## Cache des arbres générés, clé = base (Vector3i) → structure TreeGenerator.
## EXCEPTION au principe "immuable, sans verrou" du reste de la classe : sans
## cache, un même arbre est régénéré par CHAQUE chunk-colonne dans son rayon
## d'atteinte (jusqu'à ~9× redondant avec TREE_MAX_REACH) — mesuré au bench,
## coût réel (49 fps contre ~100 sans arbres). Protégé par mutex car les
## chunk-colonnes se préparent en parallèle (WorkerThreadPool, G.1).
var _tree_cache := {}
var _tree_cache_mutex := Mutex.new()

# Couches de bruit de données (B.8), indexées par nom.
var _layers := {}
# Composantes internes du terrain (E.2).
var _ridged: FastNoiseLite
var _warp_x: FastNoiseLite
var _warp_z: FastNoiseLite
var _transition_noise: FastNoiseLite
var _cave_a: FastNoiseLite
var _cave_b: FastNoiseLite
var _cavern: FastNoiseLite
## Bruit de FILON (2026-07-24) : champ 3D fréquence moyenne — un bloc est dans
## un filon si ce bruit dépasse un seuil (blob cohérent = veine), à l'intérieur
## d'une cellule de minerai acceptée (voir _ore_at).
var _ore_noise: FastNoiseLite

## Cache des rivières tracées (comme _tree_cache) — clé = cellule source
## (Vector2i) → Dictionary {"points": Array[Vector2], "length": int} ou {}
## si aucune rivière (cellule rejetée). Protégé par mutex (chunk-colonnes en
## parallèle, WorkerThreadPool).
var _river_cache := {}
var _river_cache_mutex := Mutex.new()

## Cache des villes (point 5, 2026-07-21) — clé = cellule (128 blocs, comme
## les POI) → layout de ville (CityGenerator + plateau/palette/blocs de
## bâtiments précalculés) ou {} si pas de village ici (rejet mis en cache).
## Protégé par mutex (chunk-colonnes générées en parallèle). Le footprint est
## TOUJOURS centré avec ≥1 tuile de marge → jamais à cheval sur 2 cellules,
## donc le plateau unique ne crée aucune couture de terrassement inter-cellule.
var _city_cache := {}
var _city_cache_mutex := Mutex.new()
var _road_id := 0
## Découpage en cellules (128 blocs) — doit correspondre à ClaimManager.CELL_SIZE
## (dupliqué pour éviter une dépendance d'autoload depuis un RefCounted de thread).
const CITY_CELL_BLOCKS := 128
## Rejet des sites en pente : écart de hauteur max toléré sur les 4 coins du
## footprint (au-delà, pas de village — sélection de site plat, le joueur
## voulait « raser les montagnes », résolu par le CHOIX du site + terrassement).
## Dénivelé maximal d'un site, en blocs. RELEVÉ de 20 à 40 le 2026-08-09 : avec
## un plateau unique, tout ce qui dépassait produisait une falaise artificielle
## et devait être refusé. Les paliers absorbent maintenant la pente, et le
## critère redevient ce qu'il devrait être — « peut-on bâtir ici ? » et non
## « le terrain est-il déjà plat ? ». Un tiers des sites étaient rejetés pour
## cette raison seule.
const CITY_MAX_SLOPE := 40

# Strates précompilées (G.9) : ids runtime, profondeur de fin, transition.
var _strata_ids := PackedInt32Array()
var _strata_end := PackedInt32Array()    # Profondeur (blocs sous la surface) où la strate s'arrête.
var _strata_trans := PackedInt32Array()
var _strata_count := 0

## Bandes de minerais précompilées (G.9, 2026-07-24) — tableaux plats, aucun
## parcours de dictionnaire dans le chemin chaud. Un filon = une cellule de
## minerai acceptée (rejet bon marché par hash) où le bruit de filon dépasse
## un seuil ; le matériau est tiré (pondéré) parmi les bandes éligibles à la
## profondeur du bloc. Profondeur = SOUS LA SURFACE → adapté aux montagnes.
var _ore_ids := PackedInt32Array()
var _ore_depth_min := PackedInt32Array()
var _ore_depth_max := PackedInt32Array()
var _ore_weight := PackedFloat32Array()
var _ore_host := []                # index bande → PackedInt32Array d'ids d'hôte (vide = tout hôte)
var _ore_count := 0
## Placement des filons.
const ORE_CELL_SHIFT := 3          # Cellules de minerai de 8 blocs (2^3) — échelle d'un filon.
const ORE_MIN_DEPTH := 4           # Jamais de minerai dans la sous-surface/terre végétale.
const ORE_CELL_ACCEPT_BASE := 0.10 # Proba de base qu'une cellule porte un filon (peu profond).
const ORE_CELL_ACCEPT_DEEP := 0.22 # Proba à grande profondeur (les filons se densifient, G.9).
const ORE_DEPTH_REF := 320.0       # Profondeur où l'on atteint ~ACCEPT_DEEP.
const ORE_VEIN_THRESHOLD := 0.35   # Bruit de filon > seuil = bloc de minerai (blob).
const SEED_ORE_CELL := 9120
const SEED_ORE_PICK := 9121
const SEED_ORE := 9122

# Biomes précompilés, triés par priorité décroissante, en tableaux plats
# (aucune allocation ni parcours de dictionnaire dans le chemin chaud) :
# conditions par biome = 3 intervalles [altitude, température, humidité]
# (condition absente = intervalle [0,1] ; l'altitude testée est celle du
# terrain APRÈS warp, pour que le biome suive les montagnes réelles).
var _biome_ids: Array[String] = []
var _biome_name_keys: Array[String] = []
var _biome_surface := PackedInt32Array()
var _biome_subsurface := PackedInt32Array()
var _biome_min := PackedFloat32Array()   # n*3 : [alt, temp, hum] par biome
var _biome_max := PackedFloat32Array()
## Végétation par biome (B.6 `vegetation`) : liste de {species_id, density}
## (plusieurs essences possibles par biome, ex. forêt mixte chêne+sapin).
var _biome_veg: Array[Array] = []
var _biome_plants: Array[Array] = []
var _biome_cultures: Array[Array] = []
var _biome_count := 0
## Enveloppes de rejet bon marché (G.1) CALCULÉES depuis les données B.6 à la
## compilation des biomes : probabilité cumulée maximale par CELLULE, toutes
## essences confondues, plafonnée à 1 (un roll est dans [0,1)). BUG RÉEL
## CORRIGÉ (audit 2026-07-21) : l'ancienne constante d'arbres valait
## 0.11 × 16 = 1.76 > 1 — le test `roll >= enveloppe` ne rejetait JAMAIS
## rien, chaque cellule scannée payait le coût plein du bruit (le filtre
## documenté comme « leçon de bench » était du code mort). La valeur est
## désormais dérivée des densités réellement présentes en données — et une
## densité cumulée > 1/cellule est signalée au boot (saturation : le champ
## `density` de B.6 cesserait de piloter quoi que ce soit au-dessus).
var _tree_envelope := 1.0
var _plant_envelope := 1.0
var _culture_envelope := 1.0
## Mana ajouté (2026-07-20) pour les biomes spéciaux du GDD C.7 (Forêt de
## mana, Montagne cristalline) — auparavant seule couche B.6 non échantillonnée.
const _CONDITION_LAYERS: Array[String] = ["altitude", "temperature", "humidite", "mana"]
const _CONDITION_COUNT := 4


# ---------------------------------------------------------------------------
# UNE DIMENSION EST UN JEU DE DONNÉES, PAS UN SECOND GÉNÉRATEUR (2026-08-04)
# ---------------------------------------------------------------------------
# Il a existé ici un doublon coûteux : `RiftBuilder` + `DimensionManager`
# écrivaient les blocs des dimensions UN PAR UN dans le fil principal, pendant
# que ce fichier faisait déjà le même travail pour l'overworld — mais
# multithreadé, chunké, maillé en asynchrone, LODé et borné en budget. Mesuré :
# 738 ms pour une colonne de chunks, 148 après un palliatif, contre un budget
# de frame de 16.
#
# LE PRINCIPE RETENU : l'overworld est une dimension parmi les autres. Ce
# générateur en prend une en paramètre, et c'est la seule chose qui change. Ce
# qui distingue une dimension d'une autre est ENTIÈREMENT dans ses données :
# son jeu de biomes (`data/biomes/<set>/`), ses couches de bruit, l'épaisseur
# de sa croûte, ses cavernes, ses reliefs et ses features (îles suspendues,
# spirales, arbres pendus aux plafonds).
#
# Ce qui reste propre à l'overworld — continents, climat par latitude,
# rivières, villes, tours de donjon, strates, littoraux — est GARDÉ par
# `_is_overworld`. Ce ne sont pas des cas particuliers empilés : ce sont des
# systèmes que les données d'une autre dimension ne réclament simplement pas.

## Dimension générée. `&"overworld"` = le monde de base.
var dimension: StringName = &"overworld"
var _is_overworld := true
## Fiche de dimension (`data/dimensions/<id>.json`), vide pour l'overworld.
var _dim: Dictionary = {}
## Bruits propres à la dimension.
var _dim_relief: FastNoiseLite
var _dim_zone: FastNoiseLite
var _dim_climate: FastNoiseLite
var _dim_warp: FastNoiseLite
var _dim_cave: FastNoiseLite
var _dim_ore: FastNoiseLite
var _dim_spiral: FastNoiseLite
## Terrain de dimension, lu une fois de la fiche (chemin chaud : jamais de
## `Dictionary.get` par colonne).
var _dim_base_y := 64
var _dim_amplitude := 34.0
## Épaisseur de croûte. 0 = croûte infinie (strates de l'overworld) ; > 0 = le
## sol est une dalle posée sur le vide, ce qui rend le lieu praticable ET
## borne le coût : rien n'est écrit sous la croûte.
var _dim_crust := 0
var _dim_cave_freq := 0.0
var _dim_cave_threshold := 0.42
var _dim_spiral_freq := 0.0
var _dim_spiral_threshold := 0.72
## Features de dimension (îles suspendues, arbres pendus). Activées par la
## présence de leur bloc de données, jamais par le nom de la dimension.
var _dim_islands: Dictionary = {}
var _dim_hung: Dictionary = {}
## Relief et accent par biome — le relief façonne l'altitude, l'accent est le
## minerai/cristal qui donne une raison de creuser.
var _biome_relief: Array[String] = []
var _biome_accent := PackedInt32Array()

## Semis des features de dimension : décalages de graine distincts, comme les
## arbres et les rivières de l'overworld.
const SEED_DIM_ISLAND := 9160
const SEED_DIM_HUNG := 9161
const SEED_DIM_CAVE_CELL := 9162
const SEED_DIM_ORE_CELL := 9163
## Même leçon que les arbres, les plantes, les rivières et le karst : un rejet
## PAR CELLULE avant le premier échantillon de bruit 3D. `RiftBuilder` n'en
## avait aucun — chaque bloc de croûte payait deux bruits 3D pleins.
const DIM_CAVE_CELL_SHIFT := 4
const DIM_CAVE_CELL_ACCEPT := 0.55
const DIM_ORE_CELL_SHIFT := 3
const DIM_ORE_CELL_ACCEPT := 0.16
const DIM_ORE_VEIN_THRESHOLD := 0.42
## Une île suspendue par cellule de chunks, en moyenne une sur onze.
const DIM_ISLAND_PERIOD := 11
## Un point d'accroche d'arbre pendu sur vingt-trois.
const DIM_HUNG_PERIOD := 23


func _init(seed_value: int, params: Dictionary = {}, dimension_id: StringName = &"overworld") -> void:
	world_seed = seed_value
	dimension = dimension_id
	_is_overworld = dimension_id == &"overworld"
	_dim = GameData.dimensions.get(String(dimension_id), {})
	# Les royaumes sont dérivés de la graine : un cache survivant d'un monde à
	# l'autre mélangerait deux géographies politiques sans rien signaler.
	# SEUL le générateur de l'overworld le purge : les royaumes sont un système
	# de l'overworld, et entrer dans une dimension construit un second
	# générateur — qui jetterait le travail de préchauffage du premier.
	if _is_overworld:
		KingdomGenerator.clear_cache()
	_p_relief = clampf(float(params.get("relief", 1.0)), 0.0, 4.0)
	world_radius = maxi(int(params.get("rayon_monde", DEFAULT_WORLD_RADIUS)), WORLD_EDGE_OCEAN + 500)
	_land_radius = world_radius - WORLD_EDGE_OCEAN
	_lat_period = float(world_radius)
	water_level = WATER_LEVEL + int(params.get("niveau_mer", 0))
	_p_temp_offset = clampf(float(params.get("temperature", 0.0)), -1.0, 1.0)
	_p_hum_offset = clampf(float(params.get("humidite", 0.0)), -1.0, 1.0)
	_p_tree_mult = clampf(float(params.get("arbres", 1.0)), 0.0, 4.0)
	_p_rivers = bool(params.get("rivieres", true))
	_p_caves = bool(params.get("cavernes", true))
	_p_forced_biome = String(params.get("biome_force", ""))
	# MONDE PLAT : on éteint par les interrupteurs EXISTANTS. Rivières et
	# cavernes ont déjà leur paramètre de monde, les arbres leur multiplicateur.
	# Villes et tours n'en ont pas — leurs deux points d'entrée sont gardés plus
	# bas, à côté du `_is_overworld` qui les garde déjà, et pour la même raison :
	# ce sont des systèmes que ce terrain-là ne réclame pas.
	_p_flat = String(params.get("terrain", "")) == "plat"
	if _p_flat:
		_p_rivers = false
		_p_caves = false
		_p_tree_mult = 0.0

	# Les 8 couches de B.8 : simplex + FBM, seed = graine monde + seed_offset.
	for layer_name in GameData.noise_layers:
		var def: Dictionary = GameData.noise_layers[layer_name]
		var noise := FastNoiseLite.new()
		noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
		noise.seed = world_seed + int(def["seed_offset"])
		noise.frequency = float(def["frequency"])
		var octaves := int(def["octaves"])
		noise.fractal_type = FastNoiseLite.FRACTAL_FBM if octaves > 1 else FastNoiseLite.FRACTAL_NONE
		noise.fractal_octaves = octaves
		_layers[layer_name] = noise

	_ridged = FastNoiseLite.new()
	_ridged.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_ridged.seed = world_seed + SEED_RIDGED
	_ridged.frequency = 0.002
	_ridged.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_ridged.fractal_octaves = 4

	_warp_x = FastNoiseLite.new()
	_warp_x.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_warp_x.seed = world_seed + SEED_WARP_X
	_warp_x.frequency = 0.0015
	_warp_x.fractal_type = FastNoiseLite.FRACTAL_NONE

	_warp_z = FastNoiseLite.new()
	_warp_z.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_warp_z.seed = world_seed + SEED_WARP_Z
	_warp_z.frequency = 0.0015
	_warp_z.fractal_type = FastNoiseLite.FRACTAL_NONE

	_hills = FastNoiseLite.new()
	_hills.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_hills.seed = world_seed + SEED_HILLS
	_hills.frequency = 0.006          # Collines de quelques dizaines de blocs de large.
	_hills.fractal_type = FastNoiseLite.FRACTAL_FBM
	_hills.fractal_octaves = 3

	_canyon = FastNoiseLite.new()
	_canyon.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_canyon.seed = world_seed + SEED_CANYON
	_canyon.frequency = CANYON_FREQ
	_canyon.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_canyon.fractal_octaves = 2

	_fjord = FastNoiseLite.new()
	_fjord.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_fjord.seed = world_seed + SEED_FJORD
	_fjord.frequency = FJORD_FREQ
	_fjord.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_fjord.fractal_octaves = 2

	_continent = FastNoiseLite.new()
	_continent.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_continent.seed = world_seed + SEED_CONTINENT
	_continent.frequency = CONTINENT_FREQ
	_continent.fractal_type = FastNoiseLite.FRACTAL_FBM
	_continent.fractal_octaves = 3    # Structure + quelques harmoniques (golfes, mers).

	_cont_warp_x = FastNoiseLite.new()
	_cont_warp_x.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_cont_warp_x.seed = world_seed + SEED_CONT_WARP_X
	_cont_warp_x.frequency = CONT_WARP_FREQ
	_cont_warp_x.fractal_type = FastNoiseLite.FRACTAL_FBM
	_cont_warp_x.fractal_octaves = 2

	_cont_warp_z = FastNoiseLite.new()
	_cont_warp_z.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_cont_warp_z.seed = world_seed + SEED_CONT_WARP_Z
	_cont_warp_z.frequency = CONT_WARP_FREQ
	_cont_warp_z.fractal_type = FastNoiseLite.FRACTAL_FBM
	_cont_warp_z.fractal_octaves = 2

	_fertility_noise = FastNoiseLite.new()
	_fertility_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_fertility_noise.seed = world_seed + SEED_FERTILITY
	_fertility_noise.frequency = 0.004   # Grandes taches de bon/mauvais sol.
	_fertility_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_fertility_noise.fractal_octaves = 2

	_transition_noise = FastNoiseLite.new()
	_transition_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_transition_noise.seed = world_seed + SEED_TRANSITION
	_transition_noise.frequency = 0.01
	_transition_noise.fractal_type = FastNoiseLite.FRACTAL_NONE

	# Karst : 2 champs "vers" 3D — leur intersection (les deux proches de 0)
	# forme des tunnels sinueux plutôt qu'un bruit 3D creusé nu (E.2.4).
	_cave_a = FastNoiseLite.new()
	_cave_a.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_cave_a.seed = world_seed + SEED_CAVE_A
	_cave_a.frequency = 0.02
	_cave_a.fractal_type = FastNoiseLite.FRACTAL_NONE

	_cave_b = FastNoiseLite.new()
	_cave_b.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_cave_b.seed = world_seed + SEED_CAVE_B
	_cave_b.frequency = 0.023  # Fréquence légèrement différente de A (évite un motif régulier).
	_cave_b.fractal_type = FastNoiseLite.FRACTAL_NONE

	_cavern = FastNoiseLite.new()
	_cavern.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_cavern.seed = world_seed + SEED_CAVERN
	_cavern.frequency = 0.006  # Basse fréquence : grandes salles rares, pas un gruyère.
	_cavern.fractal_type = FastNoiseLite.FRACTAL_NONE

	_ore_noise = FastNoiseLite.new()
	_ore_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_ore_noise.seed = world_seed + SEED_ORE
	_ore_noise.frequency = 0.09  # Fréquence moyenne : blobs de la taille d'un filon.
	_ore_noise.fractal_type = FastNoiseLite.FRACTAL_NONE

	_water_id = GameData.material_runtime_ids.get("eau", 0)
	_sand_id = GameData.material_runtime_ids.get("sable", 0)
	_gravel_id = GameData.material_runtime_ids.get("gravier", 0)
	_cliff_id = GameData.material_runtime_ids.get("pierre", 0)
	_marsh_id = GameData.material_runtime_ids.get("tourbe", 0)
	_marsh_sub_id = GameData.material_runtime_ids.get("argile", 0)
	_calcite_id = GameData.material_runtime_ids.get("calcite", 0)
	_guano_id = GameData.material_runtime_ids.get("guano", 0)
	_herbe_id = GameData.material_runtime_ids.get("herbe", 0)
	_road_id = GameData.material_runtime_ids.get("gravier", 0)  # Route de village (chemin de gravier).
	_compile_strata()
	_compile_ore_bands()
	_compile_dimension()
	_compile_tree_reach()
	_compile_biomes()
	_configure_native_shell()


## COQUILLE NATIVE (GDExtension voxen_native, 2026-08-09). Une instance PAR
## GÉNÉRATEUR (chaque dimension a ses bruits et ses réglages), configurée UNE
## fois ici — thread principal — puis lue seule par les workers. TOUTES les
## constantes partent d'ici : la source unique reste ce fichier, le C++ n'en
## recopie aucune (une dérive se paierait en parois fantômes aux frontières).
## La bascule d'exécution est `ChunkMesher.use_native` : la sonde de parité
## (--probe-mesh-parite) couvre donc AUSSI ce port en basculant le mesher.
var _native_shell: Object = null


func _configure_native_shell() -> void:
	if not (ClassDB.class_exists(&"VoxenNative") and ClassDB.can_instantiate(&"VoxenNative")):
		return
	_native_shell = ClassDB.instantiate(&"VoxenNative")
	_native_shell.configure_shell({
		"is_overworld": _is_overworld,
		"water_id": _water_id,
		"subsurface_thickness": SUBSURFACE_THICKNESS,
		"dim_crust": _dim_crust,
		"world_seed": world_seed,
		"strata_ids": _strata_ids,
		"strata_end": _strata_end,
		"strata_trans": _strata_trans,
		"p_caves": _p_caves,
		"cave_min_depth": CAVE_MIN_DEPTH,
		"cave_max_depth": CAVE_MAX_DEPTH,
		"world_floor": WORLD_FLOOR,
		"cave_max_depth_from_floor": CAVE_MAX_DEPTH_FROM_FLOOR,
		"cave_cell_shift": CAVE_CELL_SHIFT,
		"cave_cell_accept": CAVE_CELL_ACCEPT,
		"seed_cave_cell": SEED_CAVE_CELL,
		"cave_tunnel_threshold": CAVE_TUNNEL_THRESHOLD,
		"cave_cavern_threshold": CAVE_CAVERN_THRESHOLD,
		"dim_cave_cell_shift": DIM_CAVE_CELL_SHIFT,
		"dim_ore_cell_shift": DIM_ORE_CELL_SHIFT,
		"dim_cave_cell_accept": DIM_CAVE_CELL_ACCEPT,
		"dim_ore_cell_accept": DIM_ORE_CELL_ACCEPT,
		"seed_dim_cave_cell": SEED_DIM_CAVE_CELL,
		"seed_dim_ore_cell": SEED_DIM_ORE_CELL,
		"dim_cave_threshold": _dim_cave_threshold,
		"dim_ore_vein_threshold": DIM_ORE_VEIN_THRESHOLD,
		"cave_a": _cave_a,
		"cave_b": _cave_b,
		"cavern": _cavern,
		"dim_cave": _dim_cave,
		"dim_ore": _dim_ore,
	})


## Les bruits et les réglages d'une dimension, lus UNE FOIS de sa fiche.
##
## Ils étaient construits À CHAQUE APPEL dans l'ancien constructeur de faille —
## donc à chaque bloc pour les cavernes et les minerais : quatorze mille
## FastNoiseLite alloués par colonne. Ici c'est le même patron que le reste du
## fichier : tout le bruit est monté une fois, dans `_init`, et le chemin chaud
## ne fait que l'échantillonner.
func _compile_dimension() -> void:
	if _is_overworld or _dim.is_empty():
		return
	var terrain: Dictionary = _dim.get("terrain", {})
	_dim_base_y = int(terrain.get("base_y", 64))
	_dim_amplitude = float(terrain.get("relief", 34.0))
	# La croûte est BORNÉE, et c'est ce qui borne le coût : une dimension sans
	# fond écrirait 512 blocs par colonne pour un sol qu'on ne voit jamais.
	_dim_crust = maxi(int(terrain.get("croute", 18)), 1)

	var layers: Dictionary = _dim.get("noise_layers", {})
	_dim_relief = _dim_layer(layers, "relief", 0.012, 4)
	_dim_zone = _dim_layer(layers, "pays", 0.0016, 1)
	_dim_climate = _dim_layer(layers, "climat", 0.0021, 1)
	_dim_warp = _dim_layer(layers, "torsion", 0.020, 2)

	var caves: Dictionary = terrain.get("cavernes", {})
	if not caves.is_empty():
		_dim_cave_freq = float(caves.get("frequency", 0.028))
		_dim_cave_threshold = float(caves.get("seuil", 0.42))
		_dim_cave = FastNoiseLite.new()
		_dim_cave.noise_type = FastNoiseLite.TYPE_SIMPLEX
		_dim_cave.seed = world_seed ^ int(caves.get("seed_offset", 21001))
		_dim_cave.frequency = _dim_cave_freq
		_dim_cave.fractal_type = FastNoiseLite.FRACTAL_NONE

	var spirals: Dictionary = terrain.get("spirales", {})
	if not spirals.is_empty():
		_dim_spiral_freq = float(spirals.get("frequency", 0.004))
		_dim_spiral_threshold = float(spirals.get("seuil", 0.72))
		_dim_spiral = FastNoiseLite.new()
		_dim_spiral.noise_type = FastNoiseLite.TYPE_SIMPLEX
		_dim_spiral.seed = world_seed ^ int(spirals.get("seed_offset", 31002))
		_dim_spiral.frequency = _dim_spiral_freq
		_dim_spiral.fractal_type = FastNoiseLite.FRACTAL_NONE

	var ores: Dictionary = terrain.get("minerais", {})
	_dim_ore = FastNoiseLite.new()
	_dim_ore.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_dim_ore.seed = world_seed ^ int(ores.get("seed_offset", 55501))
	_dim_ore.frequency = float(ores.get("frequency", 0.09))
	_dim_ore.fractal_type = FastNoiseLite.FRACTAL_NONE

	_dim_islands = terrain.get("iles_suspendues", {})
	_dim_hung = terrain.get("arbres_suspendus", {})


## Une couche de bruit déclarée en données, avec un repli sain si la fiche n'en
## décrit pas — même contrat que `data/noise_layers.json` pour l'overworld.
func _dim_layer(layers: Dictionary, id: String, default_frequency: float,
		default_octaves: int) -> FastNoiseLite:
	var spec: Dictionary = layers.get(id, {})
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.seed = world_seed ^ int(spec.get("seed_offset", 0))
	noise.frequency = float(spec.get("frequency", default_frequency))
	var octaves := int(spec.get("octaves", default_octaves))
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM if octaves > 1 else FastNoiseLite.FRACTAL_NONE
	noise.fractal_octaves = octaves
	return noise


func _compile_strata() -> void:
	# strata.json : liste ordonnée surface → fond ; y_max[i] = début (en
	# profondeur : -y_max). La strate i s'arrête où commence la i+1.
	var n := GameData.strata.size()
	_strata_ids.resize(n)
	_strata_end.resize(n)
	_strata_trans.resize(n)
	for i in n:
		var stratum: Dictionary = GameData.strata[i]
		_strata_ids[i] = GameData.material_runtime_ids.get(stratum["material"], 0)
		_strata_end[i] = (-int(GameData.strata[i + 1]["y_max"])) if i < n - 1 else (1 << 30)
		_strata_trans[i] = int(stratum["transition"])
		if _strata_ids[i] == 0:
			push_error("NoiseGenerator : matériau de strate « %s » sans id runtime." % stratum["material"])
	_strata_count = n


func _compile_ore_bands() -> void:
	var n := GameData.ore_bands.size()
	_ore_ids.resize(n)
	_ore_depth_min.resize(n)
	_ore_depth_max.resize(n)
	_ore_weight.resize(n)
	_ore_host = []
	for i in n:
		var band: Dictionary = GameData.ore_bands[i]
		_ore_ids[i] = GameData.material_runtime_ids.get(band["material"], 0)
		_ore_depth_min[i] = int(band["depth_min"])
		_ore_depth_max[i] = int(band["depth_max"])
		_ore_weight[i] = float(band["weight"])
		var hosts := PackedInt32Array()
		for host in band.get("host", []):
			var hid: int = GameData.material_runtime_ids.get(host, 0)
			if hid != 0:
				hosts.append(hid)
		_ore_host.append(hosts)
	_ore_count = n


## Minerai à placer au bloc (wx,wy,wz), profondeur `depth` sous la surface,
## dans la roche `host_id` — ou 0 si pas de filon ici. Rejet bon marché par
## cellule AVANT tout bruit (même leçon que cavernes/arbres). Un filon = un
## blob du bruit de filon, d'un seul matériau tiré par cellule.
func _ore_at(wx: int, wy: int, wz: int, depth: int, host_id: int) -> int:
	if _ore_count == 0 or depth < ORE_MIN_DEPTH:
		return 0
	# Proba d'acceptation de la cellule, croissante avec la profondeur (G.9).
	var t := clampf(float(depth) / ORE_DEPTH_REF, 0.0, 1.0)
	var accept := lerpf(ORE_CELL_ACCEPT_BASE, ORE_CELL_ACCEPT_DEEP, t)
	var cx := wx >> ORE_CELL_SHIFT
	var cy := wy >> ORE_CELL_SHIFT
	var cz := wz >> ORE_CELL_SHIFT
	# Hash de cellule (combine les 3 axes) → rejet immédiat de la majorité.
	var cell_roll := _pcg_hash(cx, cz, (cy * 2654435761) ^ (world_seed + SEED_ORE_CELL)) / float(1 << 31)
	if cell_roll >= accept:
		return 0
	# Forme du filon : blob du bruit de filon (seuil abaissé en profondeur =
	# veines plus grosses au fond, G.9 « filons GÉANTS »).
	var threshold := ORE_VEIN_THRESHOLD - t * 0.12
	if _ore_noise.get_noise_3d(float(wx), float(wy), float(wz)) < threshold:
		return 0
	# Matériau du filon : tirage pondéré parmi les bandes éligibles à cette
	# profondeur et cet hôte, STABLE par cellule (le blob est monochrome).
	var pick := _pcg_hash(cx, cz, (cy * 40503) ^ (world_seed + SEED_ORE_PICK)) / float(1 << 31)
	var total := 0.0
	for i in _ore_count:
		if depth >= _ore_depth_min[i] and depth <= _ore_depth_max[i] and _ore_host_ok(i, host_id):
			total += _ore_weight[i]
	if total <= 0.0:
		return 0
	var target := pick * total
	var acc := 0.0
	for i in _ore_count:
		if depth >= _ore_depth_min[i] and depth <= _ore_depth_max[i] and _ore_host_ok(i, host_id):
			acc += _ore_weight[i]
			if target < acc:
				return _ore_ids[i]
	return 0


## Bande i acceptée dans l'hôte host_id ? (host vide = tout hôte ; sinon
## l'hôte doit figurer dans la liste — fossiles en roche sédimentaire, G.9).
func _ore_host_ok(i: int, host_id: int) -> bool:
	var hosts: PackedInt32Array = _ore_host[i]
	if hosts.is_empty():
		return true
	return hosts.has(host_id)


func _compile_biomes() -> void:
	# Seuls les biomes de l'OVERWORLD sont générés dans le monde de base. Les
	# biomes d'autres dimensions (magique, enfers…) vivent dans des sous-dossiers
	# data/biomes/<dimension>/ et sont réservés à leur dimension / au système
	# d'infiltration (2026-07-26 : « pas de forêt de mana dans l'overworld »).
	# LE JEU DE BIOMES EST CELUI DE LA DIMENSION GÉNÉRÉE (2026-08-04). Le filtre
	# était écrit en dur sur « overworld », ce qui rendait ce générateur
	# inutilisable ailleurs — et c'est précisément ce qui a fait écrire un second
	# générateur pour les dimensions. La fiche déclare son jeu (`biome_set`) ;
	# à défaut, l'id de la dimension fait office de jeu.
	var wanted := "overworld"
	if not _is_overworld:
		wanted = String(_dim.get("biome_set", String(dimension)))
	var sorted_biomes: Array[Dictionary] = []
	for id in GameData.biomes:
		if String(GameData.biomes[id].get("dimension", "overworld")) == wanted:
			sorted_biomes.append(GameData.biomes[id])
	sorted_biomes.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["priority"]) > int(b["priority"]))
	if sorted_biomes.is_empty():
		push_warning("NoiseGenerator : aucun biome pour le jeu « %s » (dimension « %s »)." % [
				wanted, dimension])

	_biome_count = sorted_biomes.size()
	_biome_ids.clear()
	_biome_name_keys.clear()
	_biome_surface.resize(_biome_count)
	_biome_subsurface.resize(_biome_count)
	_biome_min.resize(_biome_count * _CONDITION_COUNT)
	_biome_max.resize(_biome_count * _CONDITION_COUNT)
	_biome_veg.resize(_biome_count)
	_biome_plants.resize(_biome_count)
	_biome_cultures.resize(_biome_count)
	_biome_relief.clear()
	_biome_accent.resize(_biome_count)
	for b in _biome_count:
		var biome: Dictionary = sorted_biomes[b]
		_biome_ids.append(String(biome["id"]))
		_biome_name_keys.append(String(biome["name_key"]))
		_biome_surface[b] = GameData.material_runtime_ids.get(biome["surface_material"], 0)
		_biome_subsurface[b] = GameData.material_runtime_ids.get(biome["subsurface_material"], 0)
		# RELIEF ET ACCENT : lus pour tout le monde, employés par les dimensions.
		# L'overworld tire son relief de sa géologie (continents, orogenèse) et
		# ses filons des bandes de profondeur ; une dimension n'a ni l'une ni les
		# autres, et déclare à la place la FORME de son sol et le cristal qui
		# l'éclaire.
		_biome_relief.append(String(biome.get("relief", "doux")))
		_biome_accent[b] = GameData.material_runtime_ids.get(
				String(biome.get("accent_material", "")), 0)
		# Végétation (B.6) : plusieurs essences possibles par biome, chacune
		# avec sa propre densité (TreeGenerator, un vrai volume 3D par arbre).
		var vegetation: Array = biome.get("vegetation", [])
		var veg_entries: Array = []
		for entry: Dictionary in vegetation:
			if not GameData.trees.has(entry["id"]):
				push_warning("NoiseGenerator : essence d'arbre inconnue « %s » dans le biome « %s »." % [entry["id"], biome["id"]])
				continue
			veg_entries.append({"species_id": String(entry["id"]), "density": float(entry["density"])})
		_biome_veg[b] = veg_entries
		# Plantes de sol (2026-07-20, ajouté aux arbres) : décor bas niveau,
		# un seul bloc posé sur la surface — pas de structure 3D (TreeGenerator).
		var plantes: Array = biome.get("plantes_sol", [])
		var plant_entries: Array = []
		for entry: Dictionary in plantes:
			var mat_id: int = GameData.material_runtime_ids.get(entry["material_id"], -1)
			if mat_id < 0:
				push_warning("NoiseGenerator : matériau de plante inconnu « %s » dans le biome « %s »." % [entry["material_id"], biome["id"]])
				continue
			plant_entries.append({"material_id": mat_id, "density": float(entry["density"])})
		_biome_plants[b] = plant_entries
		# Cultures/flore en sous-voxels (2026-07-20, PlantGenerator) : structure
		# 3D partielle dans UN bloc (SubdivGrid), pas un simple remplacement de
		# bloc plein — biome field "cultures", même forme que vegetation/
		# plantes_sol.
		var cultures: Array = biome.get("cultures", [])
		var culture_entries: Array = []
		for entry: Dictionary in cultures:
			if not GameData.plants.has(entry["id"]):
				push_warning("NoiseGenerator : plante inconnue « %s » dans le biome « %s »." % [entry["id"], biome["id"]])
				continue
			culture_entries.append({"species_id": String(entry["id"]), "density": float(entry["density"])})
		_biome_cultures[b] = culture_entries
		var conditions: Dictionary = biome["conditions"]
		for i in _CONDITION_COUNT:
			_biome_min[b * _CONDITION_COUNT + i] = 0.0
			_biome_max[b * _CONDITION_COUNT + i] = 1.0
		for layer in conditions:
			var idx := _CONDITION_LAYERS.find(layer)
			if idx < 0:
				push_warning("NoiseGenerator : condition « %s » du biome « %s » ignorée (couche non échantillonnée)." % [layer, biome["id"]])
				continue
			var range_values: Array = conditions[layer]
			_biome_min[b * _CONDITION_COUNT + idx] = float(range_values[0])
			_biome_max[b * _CONDITION_COUNT + idx] = float(range_values[1])

	# Enveloppes de rejet réelles (voir la déclaration de _tree_envelope) :
	# max sur les biomes de la densité cumulée par cellule, plafonné à 1.
	# L'enveloppe d'arbres intègre le multiplicateur de monde (_p_tree_mult).
	_tree_envelope = minf(_compute_envelope(_biome_veg, TREE_CELL_SIZE, "vegetation") * _p_tree_mult, 1.0)
	_plant_envelope = _compute_envelope(_biome_plants, PLANT_CELL_SIZE, "plantes_sol")
	_culture_envelope = _compute_envelope(_biome_cultures, CULTURE_CELL_SIZE, "cultures")
	# MONDE PLAT : semis à zéro. L'enveloppe est le rejet PAR CELLULE, en amont
	# du premier échantillon de bruit — la mettre à zéro ne coupe donc pas
	# seulement le résultat, elle coupe aussi le coût. Les arbres passent déjà
	# par `_p_tree_mult`, les deux autres n'ont pas de paramètre de monde.
	if _p_flat:
		_plant_envelope = 0.0
		_culture_envelope = 0.0

	# Biome forcé (paramètre de monde) : résolu en indice compilé.
	_forced_biome_index = -1
	if _p_forced_biome != "":
		_forced_biome_index = _biome_ids.find(_p_forced_biome)
		if _forced_biome_index < 0:
			push_warning("NoiseGenerator : biome forcé « %s » inconnu — génération normale." % _p_forced_biome)


## Densité cumulée maximale par cellule sur tous les biomes pour une famille
## de végétation (arbres/plantes/cultures), plafonnée à 1. Avertit au boot si
## un biome sature sa cellule (densité data > densité effective possible).
func _compute_envelope(pools: Array[Array], cell_size: int, family: String) -> float:
	var envelope := 0.0
	for b in pools.size():
		var total := 0.0
		for entry: Dictionary in pools[b]:
			total += float(entry["density"])
		var cell_total := total * cell_size * cell_size
		if cell_total > 1.0:
			push_warning("NoiseGenerator : biome « %s », %s : densité cumulée %.2f/cellule > 1 — saturée (1 par cellule max, le surplus de densité est sans effet)." % [_biome_ids[b], family, cell_total])
		envelope = maxf(envelope, minf(cell_total, 1.0))
	return envelope


# --- Échantillonnage par colonne (G.4 : une fois par colonne) ---

## Terrain (composition E.2) : retourne (hauteur, altitude normalisée warpée).
## Retourne (hauteur, altitude normalisée warpée, magnitude du gradient de
## continentalité — 0..~0.3, réutilisé par l'orogenèse ET les littoraux/E.2.5
## sans ré-échantillonnage supplémentaire).
func _terrain(fx: float, fz: float) -> Vector3:
	if _p_flat:
		# Altitude normalisée FIXE (0.5, le milieu de l'échelle) : c'est l'axe
		# vertical de la matrice de biomes B.6. La laisser varier ferait changer
		# de biome d'un bout à l'autre d'une dalle strictement horizontale.
		return Vector3(FLAT_HEIGHT, 0.5, 0.0)
	if not _is_overworld:
		return _dim_terrain(fx, fz)
	# Domain warping fin (détail) : le bruit déforme ses propres coordonnées.
	var wx := fx + _warp_x.get_noise_2d(fx, fz) * WARP_AMPLITUDE
	var wz := fz + _warp_z.get_noise_2d(fx, fz) * WARP_AMPLITUDE
	# --- Structure CONTINENTALE « type Terre » (2026-07-26) ---
	# Macro-champ TRÈS basse fréquence FORTEMENT warpé → PEU de GRANDS continents
	# aux côtes organiques (pas l'effet éponge de blobs uniformes) ; le détail
	# haute fréquence ne fait que dentcler la côte et semer des îles.
	var cwx := fx + _cont_warp_x.get_noise_2d(fx, fz) * CONT_WARP_AMP
	var cwz := fz + _cont_warp_z.get_noise_2d(fx, fz) * CONT_WARP_AMP
	var macro: float = _continent.get_noise_2d(cwx, cwz)
	var detail: float = (_layers["altitude"] as FastNoiseLite).get_noise_2d(wx, wz)
	var continent := macro + detail * CONT_DETAIL_WEIGHT
	# --- Monde FINI : dégradé radial vers l'océan de bordure ---
	# Au-delà de _land_radius, on abaisse `cont` (jusqu'à le rendre nettement
	# négatif au bord extérieur) : le monde est entouré d'un grand océan.
	var radius := sqrt(fx * fx + fz * fz)
	var edge := smoothstep(float(_land_radius), float(world_radius), radius)
	var cont := clampf(continent * 0.5 + 0.5 - edge * 1.3, -1.0, 1.0)
	# Gradient LOCAL (couche détail) pour le choix du matériau de littoral (pente
	# de côte : sable/galets/falaise) — le macro-champ est trop lisse pour ça.
	var c_dx: float = (_layers["altitude"] as FastNoiseLite).get_noise_2d(wx + OROGENY_GRADIENT_SAMPLE, wz) - detail
	var c_dz: float = (_layers["altitude"] as FastNoiseLite).get_noise_2d(wx, wz + OROGENY_GRADIENT_SAMPLE) - detail
	var gradient_mag := sqrt(c_dx * c_dx + c_dz * c_dz)
	# --- Composition d'altitude BIAISÉE PLAINES ---
	# `e` = élévation signée autour du trait de côte : <0 océan, >0 terre.
	var e := cont - COAST_CONT
	# Aridité (bon marché, sans bruit) par latitude : subtropiques + pôles secs →
	# gate les canyons/mesas (features de zones arides, façon Colorado/badlands).
	var lat := clampf(absf(fz) / _lat_period, 0.0, 1.0)
	var dryness := 1.0 - _zonal_precip(lat)
	var coast_fade := smoothstep(0.0, 0.05, e)
	var h: float
	if e < 0.0:
		# Océan : profondeur croissante vers le large (grands océans profonds).
		h = float(water_level) + e * OCEAN_GAIN
	else:
		# Terre : base DOUCE (plaines par défaut) + collines modestes.
		h = float(water_level) + e * LAND_GAIN
		h += _hills.get_noise_2d(wx, wz) * HILL_AMP * coast_fade
		# CHAÎNES de montagnes : arêtes ridgées LINÉAIRES (façon cordillères) sur
		# les terres BIEN à l'intérieur (fondues vers la côte).
		var inland := smoothstep(COAST_CONT + 0.03, COAST_CONT + 0.22, cont)
		var ridge: float = _ridged.get_noise_2d(wx, wz) * 0.5 + 0.5
		var range_mask := smoothstep(0.55, 0.9, ridge) * inland
		h += range_mask * MTN_AMP * coast_fade
		# CANYONS : gorges étroites et profondes creusées en zone SÈCHE (le long
		# des arêtes du bruit ridged), fondues vers la côte.
		var canyon_field: float = _canyon.get_noise_2d(wx, wz) * 0.5 + 0.5
		var canyon := smoothstep(0.80, 0.93, canyon_field) * smoothstep(0.45, 0.75, dryness)
		h -= canyon * CANYON_DEPTH * coast_fade
	# MESAS/terrasses (mesas/falaises étagées) — renforcées en zone aride, sur
	# terre émergée seulement.
	if e > 0.0:
		var seismic: float = (_layers["sismique"] as FastNoiseLite).get_noise_2d(fx, fz) * 0.5 + 0.5
		if seismic > SEISMIC_THRESHOLD:
			var step := floorf(h / TERRACE_STEP) * TERRACE_STEP
			var frac := (h - step) / TERRACE_STEP
			var strength := clampf((seismic - SEISMIC_THRESHOLD) / 0.25, 0.0, 1.0)
			strength = clampf(strength * (1.0 + dryness * MESA_DRY_BONUS), 0.0, 1.0)
			h = lerpf(h, step + smoothstep(0.35, 0.65, frac) * TERRACE_STEP, strength)
	# FJORDS : bras de mer glaciaires aux latitudes FROIDES, près des côtes —
	# vallées en U inondées (on creuse sous le niveau de la mer le long d'arêtes).
	if lat > 0.6 and e > -0.05 and e < 0.14:
		var fjord_field: float = _fjord.get_noise_2d(fx, fz) * 0.5 + 0.5
		var fjord := smoothstep(0.78, 0.92, fjord_field) * smoothstep(0.6, 0.82, lat)
		h -= fjord * FJORD_DEPTH
	# VOLCANS : cônes coniques rares avec cratère (placement cellulaire, façon
	# POI). Peut émerger de l'océan (île volcanique).
	h += _volcano_add(fx, fz)
	# Paramètre de monde « relief » : amplitude scalée autour du niveau de la mer
	# (0.1 = monde quasi plat, 1 = normal), océans compris (mers peu profondes).
	if _p_relief != 1.0:
		h = float(water_level) + (h - float(water_level)) * _p_relief
	# .y = ÉLÉVATION RÉELLE normalisée [0,1] pour la condition d'altitude des
	# biomes (2026-07-26) : « montagne » ne se déclenche qu'en vrai relief, pas
	# sur la continentalité. L'océan → 0.
	var elev_n := clampf((h - float(water_level)) / ELEV_REF, 0.0, 1.0)
	return Vector3(h, elev_n, gradient_mag)


## Cônes volcaniques (2026-07-26) : placement déterministe par cellule (comme les
## POI), cône + cratère creusé au sommet. Retourne la hauteur ajoutée à (fx,fz).
func _volcano_add(fx: float, fz: float) -> float:
	var cs := VOLCANO_CELL
	var ccx := floori(fx / cs)
	var ccz := floori(fz / cs)
	var best := 0.0
	for dx: int in [-1, 0, 1]:
		for dz: int in [-1, 0, 1]:
			var cx := ccx + dx
			var cz := ccz + dz
			if _pcg_hash(cx, cz, world_seed + SEED_VOLCANO) / float(1 << 31) >= VOLCANO_CHANCE:
				continue
			var jx := _pcg_hash(cx, cz, world_seed + SEED_VOLCANO + 1) % cs
			var jz := _pcg_hash(cx, cz, world_seed + SEED_VOLCANO + 2) % cs
			var vx := float(cx * cs + jx)
			var vz := float(cz * cs + jz)
			var d := sqrt((fx - vx) * (fx - vx) + (fz - vz) * (fz - vz))
			var t := d / VOLCANO_RADIUS
			if t >= 1.0:
				continue
			var cone := pow(1.0 - t, 1.3) * VOLCANO_HEIGHT
			if t < 0.16:
				cone -= (1.0 - t / 0.16) * VOLCANO_HEIGHT * 0.38  # cratère creusé
			best = maxf(best, cone)
	return best


## TERRAIN D'UNE DIMENSION — la contrepartie de `_terrain` pour tout ce qui
## n'est pas l'overworld.
##
## Rien ici n'est géologique, et c'est voulu : ni continent, ni latitude, ni
## érosion. Le sol d'une dimension est un CHAMP DE BRUIT MIS EN FORME par le
## `relief` du biome traversé — terrasses franches, dômes qui se recouvrent,
## arêtes acérées. C'est ce qui fait lire le lieu comme un rêve plutôt que
## comme une contrée.
##
## L'ORDRE COMPTE ET IL EST SANS BOUCLE : le biome se résout sur des champs qui
## ne dépendent PAS de l'altitude (les deux bruits « pays » et « climat »), et
## c'est seulement ensuite que son relief façonne la hauteur. L'inverse —
## choisir le biome d'après une altitude qu'il détermine lui-même — n'aurait
## pas de point fixe.
##
## Conséquence assumée et documentée : pour une dimension, la condition
## `altitude` d'un biome porte sur le champ de relief BRUT (0..1), pas sur la
## hauteur mise en forme. Elle reste utilisable, elle ne ment pas — elle
## désigne « le haut du champ », pas « au-dessus de tel palier ».
const DIM_WARP_AMPLITUDE := 18.0


func _dim_terrain(fx: float, fz: float) -> Vector3:
	if _dim_relief == null:
		return Vector3(float(_dim_base_y), 0.5, 0.0)
	# Déformation du domaine : on tord les coordonnées avant d'échantillonner,
	# ce qui courbe les crêtes au lieu de les laisser filer droit.
	var wx := fx + _dim_warp.get_noise_2d(fx, fz) * DIM_WARP_AMPLITUDE
	var wz := fz + _dim_warp.get_noise_2d(fz, fx) * DIM_WARP_AMPLITUDE
	var n := _dim_relief.get_noise_2d(wx, wz)          # -1 .. 1
	var alt_n := clampf(n * 0.5 + 0.5, 0.0, 1.0)
	var b := _biome_index_at(fx, fz, alt_n, _dim_zone_at(fx, fz), _dim_climate_at(fx, fz), 1.0)
	var mode := "doux" if b < 0 else _biome_relief[b]
	return Vector3(_dim_shape(n, mode), alt_n, 0.0)


## La mise en forme du relief, par mode déclaré en données. Chaque mode est une
## SILHOUETTE, pas un réglage : c'est elle qu'on reconnaît en jouant.
func _dim_shape(n: float, mode: String) -> float:
	var base := float(_dim_base_y)
	match mode:
		"tordu":
			# CRÊTES : la valeur absolue du bruit fait des arêtes vives au lieu
			# de collines molles, l'exposant les rend franchement acérées.
			return base + pow(absf(n), 0.55) * _dim_amplitude * 1.5
		"champignon":
			# TERRASSES : altitude quantifiée par paliers de six blocs — les
			# plateaux étagés, et donc les surplombs.
			return base + floorf(n * _dim_amplitude / 6.0) * 6.0
		"bulbeux":
			# DÔMES : le sinus rend des bosses régulières qui se recouvrent, à
			# mi-chemin de la colline et de la bulle de savon.
			return base + sin(n * PI) * _dim_amplitude * 0.8
		_:
			return base + n * _dim_amplitude * 0.6


## Les deux champs qui découpent une dimension en pays. Ils tiennent la place
## que la température et l'humidité tiennent dans l'overworld — donc la matrice
## de conditions des biomes (B.6) s'applique telle quelle, sans une ligne de
## code de sélection en plus.
func _dim_zone_at(fx: float, fz: float) -> float:
	return clampf(_dim_zone.get_noise_2d(fx, fz) * 0.5 + 0.5, 0.0, 1.0)


func _dim_climate_at(fx: float, fz: float) -> float:
	return clampf(_dim_climate.get_noise_2d(fx, fz) * 0.5 + 0.5, 0.0, 1.0)


## Hauteur seule — pour les estimations de plage verticale du streaming.
func _height(fx: float, fz: float) -> float:
	return _terrain(fx, fz).x


## Température normalisée (0=pôle/glacial, 1=équateur/brûlant) — bande de
## LATITUDE (fonction pure de fz, jamais de bruit pour le signal primaire,
## 2026-07-20) + perturbation locale (couche "temperature", réutilisée comme
## variation plutôt que comme signal primaire) + refroidissement par
## altitude (lapse rate, E.2). Voir note d'en-tête (échelle jouable).
func _temperature_at(fx: float, fz: float, h: float) -> float:
	if not _is_overworld:
		return _dim_zone_at(fx, fz)   # Pas de latitude hors du monde : un champ de pays.
	var lat_n := cos((fz / _lat_period) * PI) * 0.5 + 0.5
	var pert: float = (_layers["temperature"] as FastNoiseLite).get_noise_2d(fx, fz) * 0.18
	var lapse := clampf(h, 0.0, TEMPERATURE_LAPSE_REF_HEIGHT) / TEMPERATURE_LAPSE_REF_HEIGHT * TEMPERATURE_LAPSE_RATE
	return clampf(lat_n + pert - lapse + _p_temp_offset, 0.0, 1.0)


## Précipitations ZONALES façon Terre (2026-07-26) en fonction de la latitude :
## humide à l'ÉQUATEUR (ITCZ), SEC vers 30° (hautes pressions subtropicales =
## grands déserts Sahara/Arabie/Australie), humide aux latitudes TEMPÉRÉES
## (~55°, ceinture des vents d'ouest), sec aux PÔLES (désert polaire froid).
## Interpolation lisse entre points de contrôle (fraction de latitude 0=équateur,
## 1=pôle). C'est ce qui place les déserts en CEINTURE, pas au hasard.
func _zonal_precip(lat: float) -> float:
	if lat < 0.33:
		return lerpf(0.95, 0.12, smoothstep(0.0, 0.33, lat))       # équateur → subtropiques
	elif lat < 0.60:
		return lerpf(0.12, 0.80, smoothstep(0.33, 0.60, lat))      # subtropiques → tempéré
	return lerpf(0.80, 0.22, smoothstep(0.60, 1.0, lat))           # tempéré → pôle


## Humidité = précipitations zonales (bandes de latitude, dominant) + variation
## de bruit + ombre pluviométrique + continentalité (intérieurs des continents
## plus secs, façon steppes/grandes plaines). Réécrite « style Terre » 2026-07-26.
func _humidity_at(fx: float, fz: float) -> float:
	if not _is_overworld:
		return _dim_climate_at(fx, fz)
	var lat := clampf(absf(fz) / _lat_period, 0.0, 1.0)
	var zonal := _zonal_precip(lat)
	var noise: float = (_layers["humidite"] as FastNoiseLite).get_noise_2d(fx, fz) * 0.5 + 0.5
	var base := zonal * 0.65 + noise * 0.35
	# Ombre pluviométrique (relief au vent dominant +X → -X).
	var upwind: float = (_layers["altitude"] as FastNoiseLite).get_noise_2d(fx - RAIN_SHADOW_UPWIND_OFFSET, fz) * 0.5 + 0.5
	var shadow := clampf(upwind - RAIN_SHADOW_THRESHOLD, 0.0, 1.0) * RAIN_SHADOW_STRENGTH
	# Continentalité : le cœur des masses terrestres est plus sec (loin de la mer).
	var cont: float = (_layers["altitude"] as FastNoiseLite).get_noise_2d(fx, fz) * 0.5 + 0.5
	var interior := clampf((cont - 0.60) / 0.40, 0.0, 1.0) * 0.22
	return clampf(base - shadow - interior + _p_hum_offset, 0.0, 1.0)


## Hachage entier déterministe (PCG) — placement d'arbres par colonne (G.4 :
## même technique que les POI, hash(seed, x, z), jamais de bruit corrélé qui
## grouperait les arbres en tache au lieu d'un semis).
static func _pcg_hash(a: int, b: int, c: int) -> int:
	var v := (a * 747796405 + 2891336453) ^ (b * 2654435761) ^ (c * 1597334677)
	v = (v ^ (v >> 15)) * 0x85EBCA6B
	v = (v ^ (v >> 13)) * 0xC2B2AE35
	return (v ^ (v >> 16)) & 0x7FFFFFFF


## Enveloppe publique de _pcg_hash — pour les systèmes hors NoiseGenerator qui
## doivent utiliser LE MÊME hachage déterministe (E.2, placement de POI par
## cellule : voir POIGenerator) plutôt que d'en inventer un second.
static func pcg_hash(a: int, b: int, c: int) -> int:
	return _pcg_hash(a, b, c)


## Trouve l'indice de biome à (wx,wz), ou -1. Factorisé car utilisé à la fois
## par _sample_column (chemin chaud) et le scan de candidats d'arbres.
func _biome_index_at(fx: float, fz: float, alt_n: float, temp_n: float, hum_n: float, mana_n: float) -> int:
	if _forced_biome_index >= 0:
		return _forced_biome_index  # Monde mono-biome (paramètre de création).
	for b in _biome_count:
		var o := b * _CONDITION_COUNT
		if alt_n >= _biome_min[o] and alt_n <= _biome_max[o] \
				and temp_n >= _biome_min[o + 1] and temp_n <= _biome_max[o + 1] \
				and hum_n >= _biome_min[o + 2] and hum_n <= _biome_max[o + 2] \
				and mana_n >= _biome_min[o + 3] and mana_n <= _biome_max[o + 3]:
			return b
	return -1


## Mana normalisé (0..1) — échantillonné en plus de alt/temp/hum pour les
## biomes spéciaux (Forêt de mana, Montagne cristalline, C.7).
func _mana_at(fx: float, fz: float) -> float:
	if not _is_overworld:
		return 1.0   # Une dimension magique baigne dedans : l'axe ne discrimine rien.
	return (_layers["mana"] as FastNoiseLite).get_noise_2d(fx, fz) * 0.5 + 0.5


## Fertilité normalisée [0,1] (2026-07-26) — module la densité de végétation
## À L'INTÉRIEUR d'un biome (multiplicateur ≤ 1 : un spot idéal reste aussi
## luxuriant que la densité de base, un spot pauvre s'éclaircit). Facteurs :
## humidité (eau disponible), température (cloche sur la bande tempérée),
## basses terres, et richesse de sol (bruit basse fréquence). Le joueur cherche
## ainsi le meilleur endroit pour cultiver. La température EST déjà simulée.
func _fertility_at(fx: float, fz: float, h: float, temp_n: float, hum_n: float) -> float:
	var wet := hum_n
	var temp_fit := 1.0 - clampf(absf(temp_n - 0.55) / 0.45, 0.0, 1.0)
	var elev := clampf((h - float(water_level)) / 120.0, 0.0, 1.0)
	var low := 1.0 - elev
	var soil := _fertility_noise.get_noise_2d(fx, fz) * 0.5 + 0.5
	var raw := clampf(wet * 0.4 + temp_fit * 0.25 + low * 0.2 + soil * 0.15, 0.0, 1.0)
	# Plancher : même une terre pauvre garde un peu de végétation (pas de désert
	# total involontaire), un spot idéal atteint la densité de base pleine.
	return 0.25 + 0.75 * raw


## Détecte les CONTINENTS et OCÉANS (2026-07-26) par flood-fill sur une grille
## n×n de l'étendue finie : composantes connexes de terre (continents) et d'eau
## (océans/mers), nommées de façon déterministe. Retourne { "continents":[...],
## "oceans":[...] }, chaque région = { "name", "cx","cz" (centre monde), "cells" }.
## Les composantes trop petites (îlots) sont ignorées pour le nommage.
func detect_regions(n: int = 96) -> Dictionary:
	var r := world_radius
	var span := 2.0 * float(r) / float(n)
	# 0 = océan, 1 = terre.
	var land := PackedByteArray()
	land.resize(n * n)
	for gy in n:
		for gx in n:
			var wx := int(-r + gx * span)
			var wz := int(-r + gy * span)
			# Hors du disque du monde = océan de bordure.
			var in_world := (float(wx) * wx + float(wz) * wz) <= float(r) * r
			land[gy * n + gx] = 1 if (in_world and height_at(wx, wz) >= water_level) else 0
	var label := PackedInt32Array()
	label.resize(n * n)
	label.fill(0)
	var continents: Array[Dictionary] = []
	var oceans: Array[Dictionary] = []
	var next_label := 1
	var min_cells := maxi(int(n * n / 400), 6)  # seuil « nommable » (sinon îlot).
	for start in n * n:
		if label[start] != 0:
			continue
		var is_land := land[start] == 1
		# BFS 4-connexe.
		var stack: Array[int] = [start]
		label[start] = next_label
		var cells := 0
		var sum_x := 0.0
		var sum_z := 0.0
		while not stack.is_empty():
			var idx: int = stack.pop_back()
			var gx := idx % n
			var gy := idx / n
			cells += 1
			sum_x += -r + gx * span
			sum_z += -r + gy * span
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nx: int = gx + d.x
				var ny: int = gy + d.y
				if nx < 0 or ny < 0 or nx >= n or ny >= n:
					continue
				var nidx: int = ny * n + nx
				if label[nidx] == 0 and (land[nidx] == 1) == is_land:
					label[nidx] = next_label
					stack.append(nidx)
		next_label += 1
		if cells < min_cells:
			continue
		var region := {"cx": int(sum_x / cells), "cz": int(sum_z / cells), "cells": cells}
		if is_land:
			region["name"] = WorldNamer.land_name(world_seed, continents.size())
			continents.append(region)
		else:
			region["name"] = WorldNamer.ocean_name(world_seed, oceans.size())
			oceans.append(region)
	# Tri par taille décroissante (le plus grand = « principal »).
	continents.sort_custom(func(a, b): return a["cells"] > b["cells"])
	oceans.sort_custom(func(a, b): return a["cells"] > b["cells"])
	return {"continents": continents, "oceans": oceans}


## Nom du monde (déterministe par graine).
func world_name() -> String:
	return WorldNamer.land_name(world_seed, -1)


## Couleur de carte/aperçu à (wx,wz) (2026-07-26) : océan bleu dégradé par
## profondeur, sinon couleur du matériau de surface réel avec un léger ombrage
## par altitude. Source unique de vérité pour l'aperçu du menu ET la mini-carte.
func preview_color(wx: int, wz: int) -> Color:
	var sample := sample_surface(wx, wz)
	var h: int = sample["h"]
	if h < water_level:
		# Océan : plus profond = plus foncé (du turquoise côtier au bleu abyssal).
		var depth := clampf(float(water_level - h) / 90.0, 0.0, 1.0)
		return Color(0.10, 0.32, 0.55).lerp(Color(0.02, 0.06, 0.20), depth)
	var surf: int = sample["surf"]
	var base := Color(0.45, 0.42, 0.40)
	if surf > 0 and surf < GameData.material_by_runtime.size():
		var mat: Dictionary = GameData.materials.get(GameData.material_by_runtime[surf], {})
		if mat.has("color"):
			base = Color.html(String(mat["color"]))
	# Ombrage par altitude : reliefs plus clairs, basses terres plus sombres.
	var shade := 0.75 + clampf(float(h - water_level) / 160.0, 0.0, 1.0) * 0.45
	return base * shade


## Température normalisée publique à (wx,wz) [0=glacial, 1=brûlant] — HUD/carte.
func temperature_at(wx: int, wz: int) -> float:
	var fx := float(wx)
	var fz := float(wz)
	return _temperature_at(fx, fz, _terrain(fx, fz).x)


## Fertilité publique à (wx,wz) — pour la carte/HUD (prospection). Échantillonne
## terrain/température/humidité en interne. 0 sous le niveau de la mer.
func fertility_at(wx: int, wz: int) -> float:
	var fx := float(wx)
	var fz := float(wz)
	var terrain := _terrain(fx, fz)
	if terrain.x < float(water_level):
		return 0.0
	return _fertility_at(fx, fz, terrain.x, _temperature_at(fx, fz, terrain.x), _humidity_at(fx, fz))


## Candidat d'arbre dans la cellule (cell_x,cell_z) [TREE_CELL_SIZE blocs de
## côté] : filtre rapide par hachage AVANT toute évaluation de bruit (G.1 —
## la grande majorité des cellules n'ont pas d'arbre), position jitterée
## déterministe DANS la cellule, puis biome + choix pondéré de l'essence.
## Retourne {} si aucun arbre, sinon {"species_id": String, "base": Vector3i}.
func _tree_candidate_in_cell(cell_x: int, cell_z: int) -> Dictionary:
	var roll := _pcg_hash(cell_x, cell_z, world_seed + SEED_TREE_PRESENCE) / float(1 << 31)
	if roll >= _tree_envelope:
		return {}  # Rejet bon marché : aucun bruit échantillonné pour la majorité des cellules.
	var jitter_x := _pcg_hash(cell_x, cell_z, world_seed + SEED_TREE_PRESENCE + 1) % TREE_CELL_SIZE
	var jitter_z := _pcg_hash(cell_x, cell_z, world_seed + SEED_TREE_PRESENCE + 2) % TREE_CELL_SIZE
	var wx := cell_x * TREE_CELL_SIZE + jitter_x
	var wz := cell_z * TREE_CELL_SIZE + jitter_z
	var fx := float(wx)
	var fz := float(wz)
	var terrain := _terrain(fx, fz)
	var temp_n := _temperature_at(fx, fz, terrain.x)
	var hum_n := _humidity_at(fx, fz)
	var mana_n := _mana_at(fx, fz)
	var b := _biome_index_at(fx, fz, terrain.y, temp_n, hum_n, mana_n)
	if b < 0:
		return {}
	var pool: Array = _biome_veg[b]
	var fertility := _fertility_at(fx, fz, terrain.x, temp_n, hum_n)
	var cumulative := 0.0
	for entry: Dictionary in pool:
		# Densité B.6 = probabilité par BLOC → mise à l'échelle par l'aire
		# de la cellule (une cellule ne produit jamais plus d'un arbre),
		# multipliée par le paramètre de monde « arbres » ET la FERTILITÉ
		# locale (2026-07-26 : plus un endroit est fertile, plus dense).
		cumulative += float(entry["density"]) * TREE_CELL_SIZE * TREE_CELL_SIZE * _p_tree_mult * fertility
		if roll < cumulative:
			var h := int(floorf(terrain.x))
			if h < water_level:
				return {}  # Sous le niveau de mer : pas d'arbre au fond de l'eau.
			return {"species_id": entry["species_id"], "base": Vector3i(wx, h + 1, wz)}
	return {}


## Plante de sol candidate pour une cellule (footprint = 1 bloc, pas de
## fenêtre de recherche : contrairement aux arbres, jamais de débordement
## hors de sa propre cellule).
func _plant_candidate_in_cell(cell_x: int, cell_z: int) -> Dictionary:
	var roll := _pcg_hash(cell_x, cell_z, world_seed + SEED_PLANT_PRESENCE) / float(1 << 31)
	if roll >= _plant_envelope:
		return {}  # Rejet bon marché : aucun bruit échantillonné pour la majorité des cellules.
	var jitter_x := _pcg_hash(cell_x, cell_z, world_seed + SEED_PLANT_PRESENCE + 1) % PLANT_CELL_SIZE
	var jitter_z := _pcg_hash(cell_x, cell_z, world_seed + SEED_PLANT_PRESENCE + 2) % PLANT_CELL_SIZE
	var wx := cell_x * PLANT_CELL_SIZE + jitter_x
	var wz := cell_z * PLANT_CELL_SIZE + jitter_z
	var fx := float(wx)
	var fz := float(wz)
	var terrain := _terrain(fx, fz)
	var h := int(floorf(terrain.x))
	if h < water_level:
		return {}  # Pas de plante sous l'eau.
	var temp_n := _temperature_at(fx, fz, terrain.x)
	var hum_n := _humidity_at(fx, fz)
	var mana_n := _mana_at(fx, fz)
	var b := _biome_index_at(fx, fz, terrain.y, temp_n, hum_n, mana_n)
	if b < 0:
		return {}
	var pool: Array = _biome_plants[b]
	var fertility := _fertility_at(fx, fz, terrain.x, temp_n, hum_n)
	var cumulative := 0.0
	for entry: Dictionary in pool:
		# LA FERTILITÉ COMMANDE LA VÉGÉTATION, ET FRANCHEMENT (2026-08-04).
		#
		# Elle était déjà un facteur, mais LINÉAIRE sur une plage de 0,25 à 1 :
		# entre la pire terre du monde et la meilleure, la densité variait d'un
		# facteur quatre — invisible en jouant. Au CARRÉ, l'écart passe à seize :
		# une terre pauvre est nettement pelée, une terre riche est couverte.
		# C'est ce qui donne au joueur une raison de LIRE le sol avant de
		# s'installer, au lieu de bâtir n'importe où.
		cumulative += float(entry["density"]) * PLANT_CELL_SIZE * PLANT_CELL_SIZE 				* fertility * fertility
		if roll < cumulative:
			return {"material_id": int(entry["material_id"]), "pos": Vector3i(wx, h + 1, wz)}
	return {}


## Plantes de sol dont la position pourrait retomber dans la fenêtre
## [min_x..max_x]×[min_z..max_z] (coordonnées monde).
func _plants_in_window(min_x: int, max_x: int, min_z: int, max_z: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var cell_min_x := floori(float(min_x) / PLANT_CELL_SIZE)
	var cell_max_x := floori(float(max_x) / PLANT_CELL_SIZE)
	var cell_min_z := floori(float(min_z) / PLANT_CELL_SIZE)
	var cell_max_z := floori(float(max_z) / PLANT_CELL_SIZE)
	for cx in range(cell_min_x, cell_max_x + 1):
		for cz in range(cell_min_z, cell_max_z + 1):
			var cand := _plant_candidate_in_cell(cx, cz)
			if not cand.is_empty():
				result.append(cand)
	return result


## Candidat de culture/flore en sous-voxels (PlantGenerator, 2026-07-20) pour
## une cellule — footprint = 1 bloc (comme les plantes de sol), mais génère
## une vraie structure 3D via PlantGenerator plutôt qu'un simple remplacement
## de bloc. Les espèces aquatiques (tag "aquatique") exigent l'INVERSE des
## autres (sous l'eau plutôt qu'au-dessus).
func _culture_candidate_in_cell(cell_x: int, cell_z: int) -> Dictionary:
	var roll := _pcg_hash(cell_x, cell_z, world_seed + SEED_CULTURE_PRESENCE) / float(1 << 31)
	if roll >= _culture_envelope:
		return {}  # Rejet bon marché : aucun bruit échantillonné pour la majorité des cellules.
	var jitter_x := _pcg_hash(cell_x, cell_z, world_seed + SEED_CULTURE_PRESENCE + 1) % CULTURE_CELL_SIZE
	var jitter_z := _pcg_hash(cell_x, cell_z, world_seed + SEED_CULTURE_PRESENCE + 2) % CULTURE_CELL_SIZE
	var wx := cell_x * CULTURE_CELL_SIZE + jitter_x
	var wz := cell_z * CULTURE_CELL_SIZE + jitter_z
	var fx := float(wx)
	var fz := float(wz)
	var terrain := _terrain(fx, fz)
	var h := int(floorf(terrain.x))
	var temp_n := _temperature_at(fx, fz, terrain.x)
	var hum_n := _humidity_at(fx, fz)
	var mana_n := _mana_at(fx, fz)
	var b := _biome_index_at(fx, fz, terrain.y, temp_n, hum_n, mana_n)
	if b < 0:
		return {}
	var pool: Array = _biome_cultures[b]
	var fertility := _fertility_at(fx, fz, terrain.x, temp_n, hum_n)
	var cumulative := 0.0
	for entry: Dictionary in pool:
		cumulative += float(entry["density"]) * CULTURE_CELL_SIZE * CULTURE_CELL_SIZE * fertility
		if roll < cumulative:
			var species: Dictionary = GameData.plants.get(entry["species_id"], {})
			var aquatic: bool = "aquatique" in (species.get("special_tags", []) as Array)
			if aquatic and h >= water_level:
				return {}  # Espèce aquatique hors de l'eau : pas de candidat ici.
			if not aquatic and h < water_level:
				return {}  # Espèce terrestre sous l'eau : pas de candidat ici.
			return {"species_id": entry["species_id"], "base": Vector3i(wx, h + 1, wz)}
	return {}


## Cultures dont la position pourrait retomber dans la fenêtre
## [min_x..max_x]×[min_z..max_z] (coordonnées monde).
func _cultures_in_window(min_x: int, max_x: int, min_z: int, max_z: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var cell_min_x := floori(float(min_x) / CULTURE_CELL_SIZE)
	var cell_max_x := floori(float(max_x) / CULTURE_CELL_SIZE)
	var cell_min_z := floori(float(min_z) / CULTURE_CELL_SIZE)
	var cell_max_z := floori(float(max_z) / CULTURE_CELL_SIZE)
	for cx in range(cell_min_x, cell_max_x + 1):
		for cz in range(cell_min_z, cell_max_z + 1):
			var cand := _culture_candidate_in_cell(cx, cz)
			if not cand.is_empty():
				result.append(cand)
	return result


## Arbres (structures complètes, TreeGenerator) dont l'empreinte peut
## atteindre la fenêtre [min_x..max_x]×[min_z..max_z] (coordonnées monde).
## Scan par CELLULE (voir TREE_CELL_SIZE) ; résultats mis en cache (voir
## _generate_tree_cached) pour éviter la régénération redondante par les
## chunk-colonnes voisines qui partagent une partie de leur fenêtre.
func _trees_in_window(min_x: int, max_x: int, min_z: int, max_z: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var span := _tree_reach_max
	var cell_min_x := floori(float(min_x - span) / TREE_CELL_SIZE)
	var cell_max_x := floori(float(max_x + span) / TREE_CELL_SIZE)
	var cell_min_z := floori(float(min_z - span) / TREE_CELL_SIZE)
	var cell_max_z := floori(float(max_z + span) / TREE_CELL_SIZE)
	for cx in range(cell_min_x, cell_max_x + 1):
		for cz in range(cell_min_z, cell_max_z + 1):
			var cand := _tree_candidate_in_cell(cx, cz)
			if cand.is_empty():
				continue
			# TRI PAR PORTÉE PROPRE, AVANT DE GÉNÉRER. La fenêtre est taillée
			# pour la plus large essence du catalogue ; la plupart des arbres
			# sont bien plus étroits et ne peuvent pas atteindre cette colonne.
			# Les écarter ici évite un `TreeGenerator.generate` complet — c'est
			# le poste le plus cher de la préparation d'une colonne.
			var base: Vector3i = cand["base"]
			var own := int(_tree_reach.get(cand["species_id"], span))
			if base.x + own < min_x or base.x - own > max_x 					or base.z + own < min_z or base.z - own > max_z:
				continue
			result.append(_generate_tree_cached(cand))
	return result


func _generate_tree_cached(cand: Dictionary) -> Dictionary:
	var base: Vector3i = cand["base"]
	_tree_cache_mutex.lock()
	if _tree_cache.has(base):
		var cached: Dictionary = _tree_cache[base]
		_tree_cache_mutex.unlock()
		return cached
	_tree_cache_mutex.unlock()

	var species: Dictionary = GameData.trees[cand["species_id"]]
	var tree := TreeGenerator.generate(base, world_seed, species)

	_tree_cache_mutex.lock()
	# Le cache est régénérable (pur, déterministe) : borné, purgé s'il déborde
	# (G.1). Purge PARTIELLE — moitié la plus ancienne (les Dictionary Godot
	# préservent l'ordre d'insertion : LRU approximé) plutôt qu'un clear()
	# total qui forçait la régénération de TOUT le voisinage chaud d'un coup.
	if _tree_cache.size() > 4096:
		for doomed in _tree_cache.keys().slice(0, _tree_cache.size() / 2):
			_tree_cache.erase(doomed)
	_tree_cache[base] = tree
	_tree_cache_mutex.unlock()
	return tree


# --- Features de dimension (2026-08-04) ---
#
# Îles suspendues, arbres pendus aux plafonds de caverne, rampes en spirale.
# Ce sont les seules choses qu'une dimension ajoute par-dessus le terrain, et
# elles sont DES DONNÉES : chacune n'existe que si sa fiche la déclare.
#
# Toutes sont posées par un SEMIS DÉTERMINISTE, calculé depuis les coordonnées
# et la graine, jamais tiré au hasard. C'est ce qui permet à une colonne
# évincée puis regénérée de retrouver exactement la même île — sans quoi
# revenir sur ses pas ferait pousser une seconde île à côté de la première, un
# défaut qu'on ne voit qu'en marchant longtemps.


## L'île suspendue d'une colonne de chunks, ou {} s'il n'y en a pas.
func sky_island_at(column: Vector2i) -> Dictionary:
	if _dim_islands.is_empty():
		return {}
	var h := _pcg_hash(column.x, column.y, world_seed + SEED_DIM_ISLAND)
	if h % int(_dim_islands.get("periode", DIM_ISLAND_PERIOD)) != 0:
		return {}
	var radius: Array = _dim_islands.get("rayon", [5, 11])
	var thickness: Array = _dim_islands.get("epaisseur", [3, 7])
	var altitude: Array = _dim_islands.get("altitude", [26, 59])
	return {
		"centre": Vector3i(column.x * 16 + 8, 0, column.y * 16 + 8),
		"rayon": int(radius[0]) + (h >> 4) % maxi(int(radius[1]) - int(radius[0]) + 1, 1),
		"epaisseur": int(thickness[0]) + (h >> 12) % maxi(int(thickness[1]) - int(thickness[0]) + 1, 1),
		"hauteur": int(altitude[0]) + (h >> 8) % maxi(int(altitude[1]) - int(altitude[0]) + 1, 1),
	}


## Point d'accroche d'un arbre pendu, par CELLULE d'arbre (comme la végétation
## normale). Retourne l'essence, ou "" s'il n'y en a pas ici.
##
## Les essences suspendues sont déclarées en données : un chêne pendu au
## plafond d'une grotte serait comique, un arbre-lanterne y est chez lui.
func hung_species_at(cell_x: int, cell_z: int) -> String:
	if _dim_hung.is_empty():
		return ""
	var species: Array = _dim_hung.get("essences", [])
	if species.is_empty():
		return ""
	var h := _pcg_hash(cell_x, cell_z, world_seed + SEED_DIM_HUNG)
	if h % int(_dim_hung.get("periode", DIM_HUNG_PERIOD)) != 0:
		return ""
	return String(species[(h >> 8) % species.size()])


## Altitude de la rampe en spirale en (x, z), ou -INF s'il n'y en a pas.
##
## Une hélice qui monte depuis le sol : c'est elle qui rend les niveaux
## praticables. Sans elle, un terrain à étages n'est qu'une pile de plateaux
## qu'on ne peut que survoler, et la verticalité ne sert à rien.
func _dim_spiral_at(x: int, z: int, top: int) -> int:
	if _dim_spiral == null:
		return -(1 << 30)
	if _dim_spiral.get_noise_2d(float(x), float(z)) < _dim_spiral_threshold:
		return -(1 << 30)
	# L'angle autour de l'origine donne la hauteur : un tour complet monte de
	# douze blocs. C'est la définition même d'une hélice.
	var turns := atan2(float(z), float(x)) / TAU + sqrt(float(x * x + z * z)) / 26.0
	return top + int(round(turns * 12.0)) % 40 + 4


## Le survol 3D épars d'une colonne de chunks : tout ce que les features de la
## dimension posent AU-DESSUS (ou en travers) du terrain.
## LES TABLEAUX SONT PASSÉS, JAMAIS RANGÉS DANS L'OBJET. Les colonnes se
## préparent en parallèle sur le WorkerThreadPool : un champ d'instance servant
## de presse-papier entre deux appels serait écrasé par la colonne voisine, et
## le défaut ne se verrait qu'en pièces de terrain mal colorées, au hasard.
func _dim_features(col: Vector2i, heights: PackedInt32Array, surfaces: PackedInt32Array,
		subsurfaces: PackedInt32Array, accents: PackedInt32Array) -> Dictionary:
	var overlay := {}
	var bx := col.x * ChunkData.SIZE
	var bz := col.y * ChunkData.SIZE

	# ÎLE SUSPENDUE : un disque de sol qui s'effile en pointe rocheuse dessous.
	var island := sky_island_at(col)
	if not island.is_empty():
		var centre_i := 9 + 9 * 18   # colonne centrale du contexte (x=8, z=8)
		_carve_sky_island(overlay, island, heights[centre_i], surfaces[centre_i],
				subsurfaces[centre_i], accents[centre_i])

	# SPIRALES et ARBRES PENDUS, colonne par colonne.
	for lz in ChunkData.SIZE:
		for lx in ChunkData.SIZE:
			var icol := (lx + 1) + (lz + 1) * 18
			var top := heights[icol]
			if _dim_spiral != null:
				var ramp := _dim_spiral_at(bx + lx, bz + lz, top)
				if ramp != -(1 << 30):
					overlay[Vector3i(bx + lx, ramp, bz + lz)] = surfaces[icol]

	if not _dim_hung.is_empty():
		var cell_min_x := floori(float(bx) / TREE_CELL_SIZE)
		var cell_max_x := floori(float(bx + ChunkData.SIZE - 1) / TREE_CELL_SIZE)
		var cell_min_z := floori(float(bz) / TREE_CELL_SIZE)
		var cell_max_z := floori(float(bz + ChunkData.SIZE - 1) / TREE_CELL_SIZE)
		for cx in range(cell_min_x, cell_max_x + 1):
			for cz in range(cell_min_z, cell_max_z + 1):
				_hang_cave_tree(overlay, cx, cz, heights, bx, bz)
	return overlay


func _carve_sky_island(overlay: Dictionary, island: Dictionary, ground_y: int,
		surface: int, rock: int, accent: int) -> void:
	if surface == 0 or rock == 0:
		return
	var centre: Vector3i = island["centre"]
	var radius := int(island["rayon"])
	var thickness := maxi(int(island["epaisseur"]), 1)
	var top := ground_y + int(island["hauteur"])
	for depth in thickness:
		# S'effile vers le bas : c'est la pointe qui fait lire un morceau
		# arraché plutôt qu'une galette posée sur rien.
		var level := int(round(float(radius) * (1.0 - float(depth) / float(thickness) * 0.85)))
		for dx in range(-level, level + 1):
			for dz in range(-level, level + 1):
				if dx * dx + dz * dz > level * level:
					continue
				var pos := Vector3i(centre.x + dx, top - depth, centre.z + dz)
				# Bord rongé, sinon l'île a un contour de compas.
				if depth == 0 and dx * dx + dz * dz > (level - 1) * (level - 1) \
						and _pcg_hash(pos.x, pos.z, world_seed + SEED_DIM_ISLAND + 1) \
								/ float(1 << 31) < 0.16:
					continue
				var id := surface if depth == 0 else rock
				if depth > 0 and accent != 0 \
						and _pcg_hash(pos.x, pos.y * 31 + pos.z, world_seed + SEED_DIM_ISLAND + 2) \
								/ float(1 << 31) < 0.06:
					id = accent
				overlay[pos] = id


## UN ARBRE PENDU AU PLAFOND D'UNE CAVERNE (croquis de l'auteur).
##
## Ce n'est PAS un second générateur d'arbre : on prend l'arbre normal et on
## MIROITE ses blocs autour de son point d'accroche. Un générateur inversé
## aurait doublé la maintenance des 57 essences pour un résultat identique.
##
## Le plafond se lit dans le terrain sans l'avoir écrit : c'est un bloc de
## croûte que le bruit de caverne ne creuse pas, avec du vide dessous.
func _hang_cave_tree(overlay: Dictionary, cell_x: int, cell_z: int,
		heights: PackedInt32Array, bx: int, bz: int) -> void:
	var species_id := hung_species_at(cell_x, cell_z)
	if species_id == "" or not GameData.trees.has(species_id):
		return
	var wx := cell_x * TREE_CELL_SIZE + _pcg_hash(cell_x, cell_z,
			world_seed + SEED_DIM_HUNG + 1) % TREE_CELL_SIZE
	var wz := cell_z * TREE_CELL_SIZE + _pcg_hash(cell_x, cell_z,
			world_seed + SEED_DIM_HUNG + 2) % TREE_CELL_SIZE
	var lx := wx - bx
	var lz := wz - bz
	if lx < 0 or lx >= ChunkData.SIZE or lz < 0 or lz >= ChunkData.SIZE:
		return   # L'ancre appartient à une autre colonne : c'est elle qui la pose.
	var top := heights[(lx + 1) + (lz + 1) * 18]
	for depth in range(14, _dim_crust - 6):
		var ceiling := top - depth
		if _dim_is_cave_at(wx, ceiling, wz, top):
			continue                       # Le plafond doit être plein.
		if not _dim_is_cave_at(wx, ceiling - 1, wz, top):
			continue                       # Et le vide, juste dessous.
		var tree := _generate_tree_cached({
			"base": Vector3i(wx, ceiling, wz), "species_id": species_id,
		})
		for pos: Vector3i in (tree["blocks"] as Dictionary):
			# LE MIROIR : on retourne autour du point d'accroche.
			overlay[Vector3i(pos.x, 2 * ceiling - pos.y, pos.z)] = tree["blocks"][pos]
		return


# --- Rivières (2026-07-20, E.2.2) ---

## Candidat de SOURCE de rivière pour une cellule (RIVER_CELL_SIZE blocs) —
## rejet bon marché avant tout bruit (même leçon que les arbres/plantes),
## puis exige une altitude suffisante (un fleuve naît en montagne).
func _river_source_candidate(cell_x: int, cell_z: int) -> Dictionary:
	var roll := _pcg_hash(cell_x, cell_z, world_seed + SEED_RIVER_PRESENCE) / float(1 << 31)
	if roll >= RIVER_MAX_DENSITY_ENVELOPE:
		return {}
	var jitter_x := _pcg_hash(cell_x, cell_z, world_seed + SEED_RIVER_PRESENCE + 1) % RIVER_CELL_SIZE
	var jitter_z := _pcg_hash(cell_x, cell_z, world_seed + SEED_RIVER_PRESENCE + 2) % RIVER_CELL_SIZE
	var wx := cell_x * RIVER_CELL_SIZE + jitter_x
	var wz := cell_z * RIVER_CELL_SIZE + jitter_z
	var terrain := _terrain(float(wx), float(wz))
	if terrain.y < RIVER_MIN_ALTITUDE:
		return {}
	return {"cell": Vector2i(cell_x, cell_z), "start": Vector2(float(wx), float(wz))}


## Trace un fleuve par DESCENTE DE GRADIENT (steepest descent) depuis sa
## source jusqu'à la mer/un lac, ou RIVER_MAX_STEPS (E.2.2). Mis en cache par
## cellule source (comme les arbres, _tree_cache) : tracé pur et déterministe,
## jamais recalculé pour chaque chunk-colonne qu'il traverse.
func _trace_river(cand: Dictionary) -> Dictionary:
	var cell: Vector2i = cand["cell"]
	_river_cache_mutex.lock()
	if _river_cache.has(cell):
		var cached: Dictionary = _river_cache[cell]
		_river_cache_mutex.unlock()
		return cached
	_river_cache_mutex.unlock()

	var points: Array[Vector2] = []
	var pos: Vector2 = cand["start"]
	points.append(pos)
	for step in RIVER_MAX_STEPS:
		var h := _height(pos.x, pos.y)
		if h <= water_level + 1:
			break  # Atteint la mer/un lac (E.2.1) : le fleuve se jette ici.
		var best_dir := Vector2.ZERO
		var best_h := h
		for angle_i in 8:
			var angle := float(angle_i) / 8.0 * TAU
			var dir := Vector2(cos(angle), sin(angle))
			var sample_pos := pos + dir * RIVER_STEP
			var sample_h := _height(sample_pos.x, sample_pos.y)
			if sample_h < best_h:
				best_h = sample_h
				best_dir = dir
		if best_dir == Vector2.ZERO:
			break  # Minimum local : bassin ENDORÉIQUE (E.2.2), le fleuve s'arrête ici (petit lac).
		pos += best_dir * RIVER_STEP
		points.append(pos)

	var result := {"points": points}
	_river_cache_mutex.lock()
	# Cache borné (G.1, même politique que _tree_cache) : régénérable, purge
	# PARTIELLE (moitié la plus ancienne, ordre d'insertion des Dictionary) —
	# un clear() total forçait à retracer TOUTES les rivières du voisinage
	# (~50 000 échantillons de bruit par tracé, le poste le plus cher du
	# générateur sur cache froid — audit 2026-07-21).
	if _river_cache.size() > 512:
		for doomed in _river_cache.keys().slice(0, _river_cache.size() / 2):
			_river_cache.erase(doomed)
	_river_cache[cell] = result
	_river_cache_mutex.unlock()
	return result


## Rivières dont le tracé passe (au moins un point) près de la fenêtre
## [min_x..max_x]×[min_z..max_z] (coordonnées monde). Cherche les sources
## candidates dans un rayon RÉGIONAL borné (RIVER_SEARCH_RADIUS — simplification
## assumée, voir en-tête de fichier : pas de bassin versant global, incompatible
## avec un monde infini streamé) autour du centre de la fenêtre. Ne retourne
## QUE les points de chaque rivière tombant dans la fenêtre élargie (pas le
## tracé entier) : garde le test de distance par colonne, plus loin, bon marché.
func _rivers_near(min_x: int, max_x: int, min_z: int, max_z: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not _is_overworld:
		return result   # Pas d'hydrologie hors du monde.
	if not _p_rivers:
		return result  # Rivières désactivées par le profil du monde.
	var center_x := (min_x + max_x) / 2
	var center_z := (min_z + max_z) / 2
	var cell_min_x := floori(float(center_x - RIVER_SEARCH_RADIUS) / RIVER_CELL_SIZE)
	var cell_max_x := floori(float(center_x + RIVER_SEARCH_RADIUS) / RIVER_CELL_SIZE)
	var cell_min_z := floori(float(center_z - RIVER_SEARCH_RADIUS) / RIVER_CELL_SIZE)
	var cell_max_z := floori(float(center_z + RIVER_SEARCH_RADIUS) / RIVER_CELL_SIZE)
	var margin := RIVER_WIDTH_MAX + 4.0
	for cx in range(cell_min_x, cell_max_x + 1):
		for cz in range(cell_min_z, cell_max_z + 1):
			var cand := _river_source_candidate(cx, cz)
			if cand.is_empty():
				continue
			var river := _trace_river(cand)
			var points: Array = river["points"]
			var local: Array[Vector2] = []
			for i in points.size():
				var p: Vector2 = points[i]
				if p.x >= min_x - margin and p.x <= max_x + margin and p.y >= min_z - margin and p.y <= max_z + margin:
					local.append(p)
			if not local.is_empty():
				result.append({"points": local})
	return result


# --- Villes (point 5, 2026-07-21, E.2/CityGenerator) ---

## Cellule (128 blocs) contenant le bloc monde (wx,wz).
func _city_cell_of(wx: int, wz: int) -> Vector2i:
	return Vector2i(floori(float(wx) / CITY_CELL_BLOCKS), floori(float(wz) / CITY_CELL_BLOCKS))


## VILLE COUVRANT LA COLONNE (wx, wz), ou {} — c est CETTE fonction que les
## chemins de terrain doivent appeler depuis que les capitales debordent de leur
## cellule. La colonne peut etre couverte par le layout de sa propre cellule, ou
## par celui d une ancre en -x/-z/-xz dont la fenetre s etend jusqu ici. Quatre
## sondages de cache au pire, et la fenetre monde tranche.
func city_covering(wx: int, wz: int) -> Dictionary:
	var cell := _city_cell_of(wx, wz)
	for delta: Vector2i in [Vector2i.ZERO, Vector2i(-1, 0), Vector2i(0, -1), Vector2i(-1, -1)]:
		var layout := _city_layout(cell + delta)
		if layout.is_empty():
			continue
		var origin: Vector2i = layout["origin"]
		var span: int = layout["span_blocks"]
		if wx >= origin.x and wx < origin.x + span and wz >= origin.y and wz < origin.y + span:
			return layout
	return {}


## Layout de ville d'une cellule (caché) — {} si aucun village constructible.
func _city_layout(cell: Vector2i) -> Dictionary:
	# Les villes sont un système de l'OVERWORLD (E.2/3.4). Une dimension n'en a
	# pas, et ce court-circuit vaut aussi pour le coût : sans lui, chaque colonne
	# de dimension paierait la recherche de site d'un village qui n'existe pas.
	if not _is_overworld or _p_flat:
		return {}
	_city_cache_mutex.lock()
	if _city_cache.has(cell):
		var cached: Dictionary = _city_cache[cell]
		_city_cache_mutex.unlock()
		return cached
	_city_cache_mutex.unlock()

	var layout := _compute_city_layout(cell)

	_city_cache_mutex.lock()
	if _city_cache.size() > 512:  # Borné, régénérable (G.1) — purge partielle.
		for doomed in _city_cache.keys().slice(0, _city_cache.size() / 2):
			_city_cache.erase(doomed)
	_city_cache[cell] = layout
	_city_cache_mutex.unlock()
	return layout


## Construit le layout : gate village (POI) + palette + plateau + rejet de
## pente + blocs de bâtiments précalculés. Pur/déterministe (thread-safe :
## biome_at/_height ne mutent rien).
## Meilleure implantation du village dans sa cellule : { "offset", "plateau" },
## ou {} si aucune position ne convient.
##
## Critères, dans l'ordre : le site doit être AU SEC (tout le footprint
## au-dessus du niveau de l'eau), puis le plus PLAT possible. La hauteur du
## plateau retenue est la MÉDIANE des sondages et non celle du centre : c'est
## elle qui minimise le déblai et le remblai, donc la falaise artificielle au
## bord du village.
##
## Le footprint peut désormais toucher le bord de cellule (décalage 0 autorisé).
## L'ancienne marge d'au moins une tuile évitait que deux villages voisins
## posent des plateaux d'altitudes différentes bord à bord — mais deux cellules
## adjacentes portant chacune un village représentent moins d'un cas sur mille,
## et on payait ce cas rarissime en refusant les trois quarts des villages.
const CITY_SAMPLES := 4
## Graine DEDIEE au decor. Une graine partagee avec le plan ferait bouger tout le
## village des qu on ajoute une torche : les mondes deja explores changeraient de
## forme a la premiere retouche de decoration.
const SEED_DECOR := 61881


func _best_city_site(cell: Vector2i, t: int, span_cells: int = 1) -> Dictionary:
	var max_offset := CityGenerator.TILES_PER_CELL * span_cells - t
	var best := {}
	var best_spread := 1 << 30
	for oz in range(max_offset + 1):
		for ox in range(max_offset + 1):
			var base_x := cell.x * CITY_CELL_BLOCKS + ox * 16
			var base_z := cell.y * CITY_CELL_BLOCKS + oz * 16
			var span := t * 16 - 1
			var heights: Array[int] = []
			var hmin := 1 << 30
			var hmax := -(1 << 30)
			for sz in CITY_SAMPLES:
				for sx in CITY_SAMPLES:
					@warning_ignore("integer_division")
					var px := base_x + sx * span / (CITY_SAMPLES - 1)
					@warning_ignore("integer_division")
					var pz := base_z + sz * span / (CITY_SAMPLES - 1)
					var h := int(floorf(_height(float(px), float(pz))))
					heights.append(h)
					hmin = mini(hmin, h)
					hmax = maxi(hmax, h)
			var spread := hmax - hmin
			if spread > CITY_MAX_SLOPE:
				continue
			heights.sort()
			@warning_ignore("integer_division")
			var median := heights[heights.size() / 2]
			# AU SEC : c'est le PLATEAU retenu qui doit être hors de l'eau, pas
			# chaque point du terrain brut. Exiger que le point le plus bas soit
			# déjà émergé interdisait tout village côtier — or le site est
			# terrassé de toute façon, et un village de pêcheurs dont un coin
			# est remblayé au-dessus de la grève est parfaitement légitime.
			if median < water_level + 2:
				continue
			# Décalages INDÉPENDANTS sur les deux axes : se limiter aux positions
			# diagonales (ox == oz) diviserait par quatre le nombre de sites
			# examinés, et c'est justement le manque de sites qui faisait
			# disparaître les villages.
			if spread < best_spread:
				best_spread = spread
				best = {"offset": ox, "offset_z": oz, "plateau": median}
	return best


## Site de repli d une capitale : le plus plat, SANS critere d eau ni de pente.
## N est appele que quand la recherche normale n a rien rendu.
func _any_city_site(cell: Vector2i, t: int, span_cells: int) -> Dictionary:
	var max_offset := CityGenerator.TILES_PER_CELL * span_cells - t
	var best := {}
	var best_spread := 1 << 30
	for oz in range(max_offset + 1):
		for ox in range(max_offset + 1):
			var base_x := cell.x * CITY_CELL_BLOCKS + ox * 16
			var base_z := cell.y * CITY_CELL_BLOCKS + oz * 16
			var span := t * 16 - 1
			var hmin := 1 << 30
			var hmax := -(1 << 30)
			var heights: Array[int] = []
			for sz in CITY_SAMPLES:
				for sx in CITY_SAMPLES:
					@warning_ignore("integer_division")
					var px := base_x + sx * span / (CITY_SAMPLES - 1)
					@warning_ignore("integer_division")
					var pz := base_z + sz * span / (CITY_SAMPLES - 1)
					var h := int(floorf(_height(float(px), float(pz))))
					heights.append(h)
					hmin = mini(hmin, h)
					hmax = maxi(hmax, h)
			if hmax - hmin < best_spread:
				best_spread = hmax - hmin
				heights.sort()
				@warning_ignore("integer_division")
				best = {"offset": ox, "offset_z": oz,
					"plateau": maxi(heights[heights.size() / 2], water_level + 2)}
	return best


func _compute_city_layout(cell: Vector2i) -> Dictionary:
	@warning_ignore("integer_division")
	var cx := cell.x * CITY_CELL_BLOCKS + CITY_CELL_BLOCKS / 2
	@warning_ignore("integer_division")
	var cz := cell.y * CITY_CELL_BLOCKS + CITY_CELL_BLOCKS / 2
	var biome := biome_at(cx, cz)
	if biome.is_empty() or not biome.has("village_palette"):
		return {}

	# LA TAILLE SUIT LE ROYAUME (2026-08-09, decision de l auteur). La capitale
	# d un royaume assez grand (cite-etat et plus) devient une VILLE sur 2x2
	# cellules ; celle d un hameau-etat reste un village. Une capitale ne passe
	# PAS par la loterie des POI : un royaume dont la capitale n existerait pas
	# serait un royaume fantome — son identite, ses lois et sa culture pointent
	# deja vers cette cellule.
	var capital_kind := KingdomGenerator.capital_kind_at(cell, world_seed, self)
	var category := ""
	if capital_kind != "":
		category = "capitale" if capital_kind != "hameau_etat" else "village"
	else:
		# UNE CELLULE COUVERTE PAR UNE CAPITALE VOISINE SE TAIT. L ancre est la
		# cellule de la capitale ; sa fenetre s etend vers +x/+z. Sans cette
		# suppression, un village POI pousserait DANS la capitale et les deux
		# s ecriraient l un sur l autre.
		for delta: Vector2i in [Vector2i(-1, 0), Vector2i(0, -1), Vector2i(-1, -1)]:
			var neighbour_kind := KingdomGenerator.capital_kind_at(
				cell + delta, world_seed, self)
			if neighbour_kind != "" and neighbour_kind != "hameau_etat":
				return {}
		if "village" not in POIGenerator.pois_at_cell(cell, world_seed, biome):
			return {}
		category = CityGenerator.size_category(cell, world_seed)
	var plan := CityGenerator.tile_plan(cell, world_seed, category)
	var t: int = plan["T"]

	# RECHERCHE DE SITE (2026-08-01). Avant, le village était posé au CENTRE de
	# la cellule et le centre seul était testé : s'il tombait dans une baie ou
	# sur un versant, le village entier était abandonné. Un recensement sur
	# 39 km² a montré l'ampleur du gâchis — 59 villages tirés, 7 construits.
	# 56 % perdus pour un centre trop bas, 32 % pour une pente, alors que la
	# cellule fait 128 blocs et que l'emprise n'en occupe que 80 : il restait
	# presque toujours de la place ailleurs.
	#
	# On essaie donc TOUTES les positions possibles dans la cellule et on garde
	# la plus plate parmi celles qui sont au sec. C'est aussi meilleur en soi :
	# un village s'installe sur le replat, il ne se plante pas au milieu d'une
	# pente parce qu'un algorithme l'a décidé.
	var span_cells := int(plan.get("span_cells", 1))
	var site := _best_city_site(cell, t, span_cells)
	if site.is_empty() and category == "capitale":
		# UNE CAPITALE NE PEUT PAS NE PAS EXISTER : son royaume est deja nomme,
		# ses lois deja tirees. Si aucun site ne passe les criteres (tout est
		# trop pentu ou trop mouille), on prend le moins mauvais — les paliers
		# absorbent la pente, et les terrasses se calent au-dessus de l eau.
		site = _any_city_site(cell, t, span_cells)
	if site.is_empty():
		return {}
	var plateau: int = site["plateau"]
	plan["offset"] = site["offset"]
	plan["offset_z"] = site["offset_z"]

	var vp: Dictionary = biome["village_palette"]
	# `poutre` : bois de structure des angles et des encadrements. Absent des
	# données de biome (il n'existait pas avant la refonte), il retombe sur le
	# mur — une maison sans chaînage reste correcte, elle est simplement plus
	# plate. `pave` et `terre_labouree` habillent la place et les champs.
	var palette := {
		"mur": GameData.material_runtime_ids.get(vp["mur"], _road_id),
		"toit": GameData.material_runtime_ids.get(vp["toit"], _road_id),
		"sol": GameData.material_runtime_ids.get(vp["sol"], _road_id),
		"poutre": GameData.material_runtime_ids.get(vp.get("poutre", "poutre"),
			GameData.material_runtime_ids.get(vp["mur"], _road_id)),
		"pave": GameData.material_runtime_ids.get(vp.get("pave", "pierre_taillee"),
			GameData.material_runtime_ids.get(vp["sol"], _road_id)),
		"champ": GameData.material_runtime_ids.get("terre", _road_id),
		# DE QUOI DECORER (2026-08-09). La palette ne portait que la matiere des
		# batiments ; hors des murs, un village etait de la matiere nue. Ces ids
		# sont resolus ICI, une seule fois par cellule, et pas dans le decor
		# lui-meme : une recherche de dictionnaire par bloc pose couterait cher
		# sur les milliers de blocs qu un village represente.
		"torche": GameData.material_runtime_ids.get("torche", 0),
		"eau": GameData.material_runtime_ids.get("eau", 0),
		"buisson": GameData.material_runtime_ids.get("buisson", 0),
		# LA CULTURE VIENT DU BIOME. Un village de toundra qui cultiverait la
		# vigne serait un contresens que personne ne raterait ; la fiche de biome
		# porte deja ce qui pousse chez elle.
		"culture": GameData.material_runtime_ids.get(
			String(vp.get("culture", "ble")), 0),
		"tronc": GameData.material_runtime_ids.get(vp.get("tronc", "chene"), 0),
		"feuillage": GameData.material_runtime_ids.get(
			vp.get("feuillage", "feuilles_chene"), 0),
	}
	var building_blocks := {}
	for idx: int in plan["doors"]:
		# VARIANTE DE HAUTEUR, tiree par batiment. La graine melange la cellule ET
		# l index de tuile : deux maisons voisines tirent des hauteurs
		# independantes, alors qu une graine par cellule les aurait toutes
		# alignees sur la meme.
		var variant := int(NoiseGenerator.pcg_hash(cell.x * 131 + idx, cell.y,
			world_seed + SEED_DECOR) % 5) - 1
		building_blocks[idx] = CityGenerator.building_blocks(plan["doors"][idx], palette,
			String((plan["archetypes"] as Dictionary).get(idx, "maison")), variant)
	# DECOR des tuiles NON baties : place, rues, champs. Meme chemin que les
	# batiments — un dictionnaire local par tuile, calcule une fois, cache avec
	# le layout et pose par le meme passage dans generate_chunk.
	var decor_blocks := {}
	var types_all: PackedByteArray = plan["types"]
	for idx in types_all.size():
		var kind := int(types_all[idx])
		if kind == CityGenerator.Tile.BATIMENT or kind == CityGenerator.Tile.VIDE:
			continue
		var decor := CityGenerator.decor_blocks(kind, palette,
			String((plan["services"] as Dictionary).get(idx, "")),
			NoiseGenerator.pcg_hash(cell.x * 97 + idx, cell.y, world_seed + SEED_DECOR))
		if not decor.is_empty():
			decor_blocks[idx] = decor
	plan["cell"] = cell
	# FENETRE MONDE du village : min inclus, exclusif au-dela. C est elle qui
	# fait foi pour « cette colonne est-elle dans ce village ? » — le calcul par
	# cellule ne suffit plus depuis qu une capitale deborde de la sienne.
	plan["origin"] = Vector2i(cell.x * CITY_CELL_BLOCKS + int(plan["offset"]) * 16,
		cell.y * CITY_CELL_BLOCKS + int(plan["offset_z"]) * 16)
	plan["span_blocks"] = int(plan["T"]) * 16
	plan["plateau_y"] = plateau
	plan["terraces"] = _terraces_for(cell, plan, plateau)
	plan["palette"] = palette
	plan["building_blocks"] = building_blocks
	plan["decor_blocks"] = decor_blocks
	return plan


## Écart maximal entre deux paliers de village voisins, en blocs. Le nom porte
## `CITY_` : `TERRACE_STEP` désigne déjà les falaises et mesas du relief (E.2),
## qui n'ont rien à voir — 40 blocs là-bas, un seul ici.
##
## UN BLOC, ET C'EST UN CHOIX DE JOUABILITÉ, pas d'esthétique. Le joueur franchit
## une marche d'un bloc sans sauter (STEP_HEIGHT), et les créatures depuis
## aujourd'hui aussi. À un bloc, TOUT le village reste navigable sans qu'on ait à
## générer le moindre escalier ni la moindre rampe : la contrainte fabrique la
## praticabilité au lieu de la promettre.
const CITY_TERRACE_STEP := 1


## PALIER DE CHAQUE TUILE (2026-08-09, demande de l'auteur : « une génération
## plus organique qui s'adapte au relief du terrain »).
##
## Un village était UN plateau unique : la colline était rasée, et le village
## s'annonçait de loin par une falaise artificielle sur son pourtour. Il est
## maintenant une suite de PALIERS, un par tuile, chacun calé sur le terrain
## qu'il recouvre — un village de coteau descend enfin sa pente.
##
## Ça ne coûte RIEN de plus au monde : le terrassement reste une valeur rendue
## par la fonction de hauteur, jamais des éditions de blocs. On calcule t×t
## médianes une seule fois par cellule, et le résultat est caché avec le layout.
func _terraces_for(cell: Vector2i, plan: Dictionary, fallback: int) -> PackedInt32Array:
	var t: int = plan["T"]
	var ox: int = int(plan["offset"])
	var oz: int = int(plan.get("offset_z", plan["offset"]))
	var out := PackedInt32Array()
	out.resize(t * t)
	# 1. Hauteur BRUTE de chaque tuile : la médiane de quatre sondages. La
	#    médiane et non la moyenne — un rocher isolé dans un coin ne doit pas
	#    soulever la maison entière.
	for tz in t:
		for tx in t:
			var base_x := cell.x * CITY_CELL_BLOCKS + (ox + tx) * 16
			var base_z := cell.y * CITY_CELL_BLOCKS + (oz + tz) * 16
			var samples: Array[int] = []
			for sz in [4, 12]:
				for sx in [4, 12]:
					samples.append(int(floorf(_height(float(base_x + sx), float(base_z + sz)))))
			samples.sort()
			out[tz * t + tx] = maxi(samples[2], water_level + 1)
	# 2. RELAXATION : on rapproche les voisines jusqu'à ce qu'aucune paire ne
	#    dépasse la marche franchissable. Sans elle, deux tuiles mitoyennes
	#    peuvent différer de dix blocs et le village devient une falaise à
	#    escalader. On borne les passes : la convergence est garantie, mais une
	#    boucle non bornée dans la génération de terrain est un risque qu'on ne
	#    prend pas.
	for _pass in t * 2:
		var changed := false
		for tz in t:
			for tx in t:
				var idx := tz * t + tx
				for step: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var nx := tx + step.x
					var nz := tz + step.y
					if nx < 0 or nx >= t or nz < 0 or nz >= t:
						continue
					var other := out[nz * t + nx]
					if out[idx] - other > CITY_TERRACE_STEP:
						out[idx] = other + CITY_TERRACE_STEP
						changed = true
		if not changed:
			break
	if out.is_empty():
		out.append(fallback)
	return out


## LA COLONNE EST-ELLE TERRASSEE ? (2026-08-09, demande de l auteur : « je veux
## des rues etroites et que chaque batiment ait son plateau, les rues connectent
## tout et s adaptent au terrain »).
##
## CE QUE C ETAIT. Toute tuile du village etait aplanie a son palier, sur ses
## seize blocs de cote. Un village restait donc une mosaique de DALLES CARREES,
## paliers ou pas : c est ce qui lui donnait son air de maquette.
##
## CE QUE C EST. Seul ce qui a besoin d etre plat l est :
##   - le PLATEAU D UN BATIMENT, a son emprise plus un bloc de seuil ;
##   - la PLACE, qui est un sol pave et se doit d etre de niveau ;
##   - les CHAMPS, qu on laboure a plat comme partout ou l on cultive.
## Les RUES, elles, SUIVENT LE TERRAIN : elles montent et descendent avec lui.
## C est le point qui change tout — une rue de niveau force le terrain a l etre,
## et de proche en proche c est le village entier qui s aplatit.
##
## Tout le reste — les abords des maisons, les interstices — reste du terrain
## naturel, avec son herbe et ses irregularites.
func _city_terraforms(city: Dictionary, tile: Dictionary, wx: int, wz: int) -> bool:
	var kind := int(tile["type"])
	var lx := wx & 15
	var lz := wz & 15
	match kind:
		CityGenerator.Tile.BATIMENT:
			var archetype := String((city["archetypes"] as Dictionary).get(
				int(tile["idx"]), "maison"))
			return CityGenerator.on_building_pad(lx, lz, archetype)
		CityGenerator.Tile.PLACE:
			return true
		CityGenerator.Tile.CHAMP:
			return true
	return false


## La colonne est-elle sur la CHAUSSEE d une rue ? Sert au seul choix du
## materiau de surface : la rue ne terrasse rien, elle se contente de couvrir le
## sol de gravier la ou elle passe.
func _city_on_street(city: Dictionary, tile: Dictionary, wx: int, wz: int) -> bool:
	var kind := int(tile["type"])
	if kind != CityGenerator.Tile.ROUTE and kind != CityGenerator.Tile.PLACE:
		return false
	var links := int((city.get("links", {}) as Dictionary).get(int(tile["idx"]), 15))
	return CityGenerator.on_street(wx & 15, wz & 15, links)


## Palier de la tuile `idx`, ou le plateau de repli. Le repli existe pour les
## layouts d'AVANT les terrasses qu'une sauvegarde pourrait encore porter : un
## village à demi terrassé serait pire que pas de terrasses du tout.
func _terrace_of(city: Dictionary, idx: int) -> int:
	var terraces: PackedInt32Array = city.get("terraces", PackedInt32Array())
	if idx < 0 or idx >= terraces.size():
		return int(city["plateau_y"])
	return terraces[idx]


## Type de tuile de ville au bloc (wx,wz) dans un layout donné :
## { "in": bool, "type": int (0 place, 1 route, 2 bâtiment), "idx": int }.
func _city_tile_type(wx: int, wz: int, city: Dictionary) -> Dictionary:
	# La FENETRE MONDE fait foi (2026-08-09) : le test par cellule refusait toute
	# colonne hors de la cellule d ancrage, ce qui aurait coupe une capitale au
	# bord de sa premiere cellule.
	var origin: Vector2i = city["origin"]
	var lx := wx - origin.x
	var lz := wz - origin.y
	var span: int = city["span_blocks"]
	if lx < 0 or lx >= span or lz < 0 or lz >= span:
		return {"in": false}
	var ftx := lx >> 4
	var ftz := lz >> 4
	var t: int = city["T"]
	var idx := ftz * t + ftx
	var kind := int((city["types"] as PackedByteArray)[idx])
	# HORS = la tuile est dans la boite englobante mais PAS dans le village
	# (2026-08-09, forme organique). Le terrain y reste intact : ni terrassement,
	# ni interdiction d arbres. C est ce qui fait qu un village est BORDE de
	# nature au lieu d etre pose sur une dalle carree.
	if kind == CityGenerator.Tile.HORS:
		return {"in": false}
	return {"in": true, "type": kind, "idx": idx}


## Bloc de bâtiment au monde (wx,wy,wz), 0 si aucun — pour la coquille du
## mesher et les requêtes ponctuelles (block_at).
func _city_block_at(wx: int, wy: int, wz: int, city: Dictionary) -> int:
	var tile := _city_tile_type(wx, wz, city)
	if not tile.get("in", false):
		return 0
	var bb: Dictionary = (city["building_blocks"] as Dictionary).get(tile["idx"], {})
	if bb.is_empty():
		bb = (city.get("decor_blocks", {}) as Dictionary).get(tile["idx"], {})
	if bb.is_empty():
		return 0
	var local := Vector3i(wx & 15, wy - _terrace_of(city, int(tile["idx"])), wz & 15)
	return int(bb.get(local, 0))


## True si (wx,wz) est dans le footprint d'une ville (toute tuile) — sert à
## interdire arbres/plantes dessus (ils pousseraient à la mauvaise hauteur).
func _in_city_footprint(wx: int, wz: int, city: Dictionary) -> bool:
	return not city.is_empty() and bool(_city_tile_type(wx, wz, city).get("in", false))


# --- Tour de donjon (2026-07-27) ---

## Ids runtime de la palette démoniaque, résolus une seule fois : une
## recherche de dictionnaire par bloc coûterait cher sur une structure de
## cette taille (jusqu'à ~100 000 blocs par cellule).
## Palette de pierres taillées de CETTE cellule (2026-08-02) : chaque tour est
## bâtie dans une roche différente. Le cache vit dans DungeonTower, partagé avec
## DungeonManager — les étages doivent être dans la MÊME pierre que leur tour.
func _tower_palette_ids(cell: Vector2i) -> PackedInt32Array:
	return DungeonTower.palette_for(cell, world_seed)


## Cellule de donjon dont la tour couvre (wx, wz), ou null. Une tour tient
## dans UN chunk au centre de sa cellule : il suffit donc de tester la cellule
## courante, jamais un voisinage.
func _tower_cell_at(wx: int, wz: int) -> Variant:
	var cell := ClaimManager.cell_of_block(wx, wz)
	# RADIUS (56) < demi-cellule (64) : la structure ne déborde jamais chez
	# la voisine, tester la cellule courante suffit.
	if not DungeonTower.contains(cell, wx, wz):
		return null
	return cell if bool(_tower_info(cell)["donjon"]) else null


## Hauteur de base de la tour : le terrain au CENTRE de la cellule, pour que
## la tour soit d'aplomb même sur un relief accidenté.
func _tower_ground(cell: Vector2i) -> int:
	return int(_tower_info(cell)["sol"])


## Bloc de tour en (wx, wy, wz). Retourne -1 si la position n'appartient PAS
## au volume de la tour ; sinon le bloc, **0 compris**.
##
## La distinction est essentielle : l'intérieur de la tour est creux, donc 0.
## Une première version retournait 0 dans les deux cas, si bien que l'appelant
## ne pouvait pas distinguer « pas de tour ici » de « intérieur vide » — le
## terrain reprenait le dessus et la tour se remplissait de roche.
func _tower_block_at(wx: int, wy: int, wz: int) -> int:
	if not _is_overworld:
		return -1
	var cell: Variant = _tower_cell_at(wx, wz)
	if cell == null:
		return -1
	var ground := _tower_ground(cell)
	if wy < ground or float(wy - ground) > DungeonTower.MAX_HEIGHT:
		return -1
	return DungeonTower.block_at(cell, wx, wy, wz, ground, world_seed, _tower_palette_ids(cell))


## Cellule dont la tour recouvre une partie de ce chunk, ou null. L'emprise
## d'une tour (centrée dans sa cellule) n'est PAS alignée sur la grille de
## chunks : elle chevauche jusqu'à 4 chunks. On teste donc les 4 coins.
## Cache par cellule : { cellule -> { "donjon": bool, "sol": int } }.
##
## Sans lui, _tower_in_chunk évaluait `biome_at` (8 couches de bruit) jusqu'à
## 4 fois PAR CHUNK GÉNÉRÉ — un coût payé partout dans le monde, y compris
## très loin du moindre donjon. Mesuré : 245 → 63 fps.
var _tower_cache := {}
var _tower_cache_mutex := Mutex.new()


func _tower_info(cell: Vector2i) -> Dictionary:
	# LE VRAI POINT DE PASSAGE UNIQUE DES TOURS, et il a fallu que
	# `--probe-vitrine` le dise. J'avais coupé dans `_tower_cell_at` en le
	# croyant seul : `tower_top_for_column` et `_tower_in_chunk` appellent
	# `_tower_info` DIRECTEMENT, et une tour continuait donc de pousser au
	# milieu des rangées. Trois appelants, un seul endroit où décider.
	if _p_flat:
		return {"donjon": false, "sol": 0}
	_tower_cache_mutex.lock()
	var cached: Variant = _tower_cache.get(cell)
	_tower_cache_mutex.unlock()
	if cached != null:
		return cached
	var centre := POIGenerator.cell_center_world(cell)
	var ground := int(floorf(_height(float(centre.x), float(centre.y))))
	var biome := biome_at(centre.x, centre.y)
	var is_dungeon := false
	if not biome.is_empty():
		is_dungeon = "donjon" in POIGenerator.pois_at_cell(cell, world_seed, biome)
	# SOL ÉMERGÉ EXIGÉ (2026-08-02). Le tirage de POI ne consulte que le BIOME,
	# jamais l'altitude : une cellule de mangrove ou de côte dont le centre est
	# sous le niveau de la mer décrochait quand même un donjon. Invisible tant
	# que la structure était une termitière basse ; la tour de pierre taillée,
	# haute de 111 blocs, l'a rendu criant — une tour plantée en pleine eau,
	# dont les quatre entrées débouchent sous la surface.
	if is_dungeon and ground <= water_level + 1:
		is_dungeon = false
	var info := {"donjon": is_dungeon, "sol": ground if is_dungeon else 0}
	_tower_cache_mutex.lock()
	if _tower_cache.size() > 512:
		_tower_cache.clear()
	_tower_cache[cell] = info
	_tower_cache_mutex.unlock()
	return info


## Cette cellule porte-t-elle un donjon ? RÈGLE DE RÉFÉRENCE, source unique.
##
## Elle vivait en double : ici (via `_tower_info`, qui décide si la tour est
## bâtie) et dans `DungeonManager._is_donjon_cell`, qui refaisait le tirage de
## POI dans son coin. Les deux s'accordaient tant que la règle se résumait au
## biome. Le jour où l'altitude s'y est ajoutée (2026-08-02, pas de donjon sous
## le niveau de la mer), elles ont divergé : le générateur ne bâtissait plus la
## tour, DungeonManager continuait d'annoncer un donjon — cellule marquée comme
## donjon, mais rigoureusement rien sur le terrain.
##
## `sol` ne vaut pas seulement pour la tour : c'est aussi la garantie que le
## donjon existe à un endroit atteignable à pied.
func has_dungeon(cell: Vector2i) -> bool:
	return bool(_tower_info(cell)["donjon"])


## Altitude de base de la tour d'une cellule (0 si pas de donjon).
func dungeon_ground(cell: Vector2i) -> int:
	return int(_tower_info(cell)["sol"])


## Sommet ABSOLU de la tour recouvrant tout ou partie de la colonne-chunk
## `col` (16×16 blocs), ou -1 s'il n'y en a aucune.
##
## POURQUOI (bug corrigé le 2026-07-28) : la termitière monte à 128 blocs
## (MAX_HEIGHT) au-dessus du sol, mais ni `cy_range` ni
## `prepare_context` ne le savaient — tous deux ne renvoyaient que la hauteur du
## TERRAIN (plus les arbres/plantes/ville). Conséquence en chaîne :
##  - WorldManager._range_for/_missing_cys ne DEMANDAIENT jamais les chunks
##    au-dessus de ~terrain+16 ;
##  - _column_task calcule `cy_hi_exact` depuis `ctx["hmax"]` et sautait donc
##    ces mêmes chunks (`if not requested and not in_exact: continue`).
## La structure était tranchée net une quinzaine de blocs au-dessus du sol, ce
## qui se voyait comme un COUVERCLE PLAT — d'où le « plafond » signalé. Le reste
## du code (`_tower_in_chunk`, `generate_chunk`) gérait déjà correctement toute
## la hauteur : il ne manquait plus que la portée verticale du streaming.
func tower_top_for_column(col: Vector2i) -> int:
	if not _is_overworld:
		return -1
	var t := ChunkData.SIZE
	var x0 := col.x * t
	var z0 := col.y * t
	var top := -1
	# Mêmes 4 cellules candidates et même test de distance que _tower_in_chunk :
	# l'emprise (112 blocs de diamètre) n'est pas alignée sur la grille de chunks.
	var cell := ClaimManager.cell_of_block(x0, z0)
	for candidate: Vector2i in [cell, cell + Vector2i(1, 0), cell + Vector2i(0, 1), cell + Vector2i(1, 1)]:
		var centre := POIGenerator.cell_center_world(candidate)
		var near_x := clampi(centre.x, x0, x0 + t - 1)
		var near_z := clampi(centre.y, z0, z0 + t - 1)
		var dx := float(near_x - centre.x)
		var dz := float(near_z - centre.y)
		if dx * dx + dz * dz > DungeonTower.RADIUS * DungeonTower.RADIUS:
			continue
		var info := _tower_info(candidate)
		if not bool(info["donjon"]):
			continue
		top = maxi(top, int(info["sol"]) + DungeonTower.MAX_HEIGHT)
	return top


func _tower_in_chunk(cpos: Vector3i) -> Variant:
	var t := ChunkData.SIZE
	var y0 := cpos.y * t
	var y1 := y0 + t - 1
	# Test par DISTANCE au centre, pas par coins : l'emprise fait 112 blocs
	# de diamètre et un chunk peut la chevaucher sans qu'aucun de ses 4 coins
	# ne tombe dedans (ni tous, s'il est entièrement dedans).
	var cell := ClaimManager.cell_of_block(cpos.x * t, cpos.z * t)
	for candidate: Vector2i in [cell, cell + Vector2i(1, 0), cell + Vector2i(0, 1), cell + Vector2i(1, 1)]:
		var centre := POIGenerator.cell_center_world(candidate)
		var near_x := clampi(centre.x, cpos.x * t, cpos.x * t + t - 1)
		var near_z := clampi(centre.y, cpos.z * t, cpos.z * t + t - 1)
		var dx := float(near_x - centre.x)
		var dz := float(near_z - centre.y)
		if dx * dx + dz * dz > DungeonTower.RADIUS * DungeonTower.RADIUS:
			continue
		var info := _tower_info(candidate)
		if not bool(info["donjon"]):
			continue
		# Test VERTICAL, indispensable : sans lui, TOUS les chunks de la
		# colonne (64 niveaux, du fond du monde au ciel) étaient considérés
		# comme contenant la structure et perdaient leurs chemins rapides
		# « chunk uniforme ». C'était la cause principale de la chute de
		# performance, bien avant le coût du bruit lui-même.
		var ground := int(info["sol"])
		if y1 < ground or y0 > ground + DungeonTower.MAX_HEIGHT:
			continue
		return candidate
	return null


## Ville présente et son centre (pour la carte 2D / HUD) — {} sinon.
func city_at_cell(cell: Vector2i) -> Dictionary:
	return _city_layout(cell)


## Le plan de cette cellule est-il déjà composé ? Sert au PRÉCHAUFFAGE : c'est
## ce qui permet de le calculer dans une frame plutôt que dans un tick.
func has_city_layout(cell: Vector2i) -> bool:
	_city_cache_mutex.lock()
	var known := _city_cache.has(cell)
	_city_cache_mutex.unlock()
	return known


## Royaume possédant cette cellule (14.4/E.27), ou {} en terre sauvage.
##
## « Hors royaume = aucune loi, aucune douane » : un dictionnaire vide n'est pas
## une absence de donnée, c'est l'anarchie de fait de la wilderness, et le code
## appelant doit la traiter comme un état légitime.
func kingdom_at_cell(cell: Vector2i) -> Dictionary:
	return KingdomGenerator.kingdom_at_cached(cell, world_seed, self)


## Enveloppes publiques de _rivers_near/_river_carve_at (2026-07-21, carte du
## monde 2D — affichage de l'eau) : mêmes fonctions, exposées pour les
## systèmes hors NoiseGenerator (même convention que `pcg_hash`/`_pcg_hash` —
## jamais dupliquer la logique, juste l'exposer proprement).
func rivers_near(min_x: int, max_x: int, min_z: int, max_z: int) -> Array[Dictionary]:
	return _rivers_near(min_x, max_x, min_z, max_z)


func river_carve_at(wx: float, wz: float, rivers: Array[Dictionary]) -> int:
	return _river_carve_at(wx, wz, rivers)


## Profondeur de creusement du lit d'une rivière au point (wx,wz), 0 si aucune
## rivière à proximité — le point le plus proche parmi les segments locaux
## déjà filtrés par _rivers_near (peu nombreux, donc bon marché). La largeur
## s'élargit légèrement avec la distance parcourue (approxime la confluence
## affluent → rivière → fleuve sans vrai calcul de débit, E.2.2).
func _river_carve_at(wx: float, wz: float, rivers: Array[Dictionary]) -> int:
	var best_carve := 0
	for river: Dictionary in rivers:
		var points: Array = river["points"]
		for i in points.size():
			var p: Vector2 = points[i]
			var width := clampf(RIVER_WIDTH_BASE + float(i) * RIVER_WIDTH_PER_STEP, RIVER_WIDTH_BASE, RIVER_WIDTH_MAX)
			var d := Vector2(wx, wz).distance_to(p)
			if d < width:
				var carve := int(clampf(4.0 - d, 1.0, 4.0))
				best_carve = maxi(best_carve, carve)
	return best_carve


## Enveloppe publique de _sample_column (2026-07-21, carte du monde 2D —
## couleur "plus représentative du terrain réel") : UN SEUL appel donne à la
## fois la hauteur ET le matériau de surface RÉEL (littoral inclus), au lieu
## de `height_at()` + `block_at()` séparément (double calcul redondant du
## terrain — bug de perf réel trouvé en testant l'affichage détaillé de la
## carte, la mosaïque bloquait le thread plus de 20 s).
## `city` : layout de village DÉJÀ RÉSOLU, quand l'appelant en échantillonne
## plusieurs points. Sans ce paramètre, chaque échantillon refaisait la
## résolution — qui prend un mutex — alors que tous les points d'une même
## cellule partagent forcément le même village.
##
## Mesuré le 2026-08-01 sur la carte du monde : 21 904 échantillons, 2,5 s
## passées dans cette seule résolution redondante, verrou compris. C'était le
## premier poste de coût de la construction de la carte, devant le terrain
## lui-même.
func sample_surface(wx: int, wz: int, city: Variant = null) -> Dictionary:
	var layout: Dictionary = city if city is Dictionary else city_covering(wx, wz)
	return _sample_column(wx, wz, layout)


## Échantillonne une colonne complète : hauteur, biome, matériaux, transition.
## Retour : { "h", "surf", "sub", "trans" }. Chemin chaud (324 appels par
## colonne-chunk) — un seul Dictionary alloué. Les arbres sont un survol
## SÉPARÉ (voir _trees_in_window) : ce ne sont plus des profils par colonne.
func _sample_column(wx: int, wz: int, city: Dictionary = {}) -> Dictionary:
	var fx := float(wx)
	var fz := float(wz)
	var terrain := _terrain(fx, fz)
	var h := int(floorf(terrain.x))
	var alt_n := terrain.y
	var temp_n := _temperature_at(fx, fz, terrain.x)
	var hum_n := _humidity_at(fx, fz)
	var mana_n := _mana_at(fx, fz)

	# Biome (B.6) : premier match par priorité décroissante, tableaux plats,
	# puis mélange dithéré avec le biome voisin près d'une frontière.
	var surf_pair := _blended_surface(fx, fz, alt_n, temp_n, hum_n, mana_n)
	# Littoral (2026-07-20) : dans la bande côtière, la pente locale (déjà
	# calculée par _terrain, aucun coût supplémentaire) l'emporte sur le
	# matériau de biome — plage/estran/falaise/marécage logiques (E.2.5).
	# UNIQUEMENT DANS L'OVERWORLD : le sable et les galets sont des matériaux de
	# l'overworld, et une dimension n'emploie que les siens (demande de l'auteur
	# du 2026-08-04, verrouillée par `--probe-dimensions`).
	if _is_overworld:
		var coastal := _coastal_override(h, terrain.z, hum_n,
				Vector2i(surf_pair.x, surf_pair.y))
		surf_pair = Vector3i(coastal.x, coastal.y, surf_pair.z)

	var trans := int(_transition_noise.get_noise_2d(fx, fz) * 1000.0)

	# TERRASSEMENT DE VILLE (point 5) : dans le footprint, la colonne est
	# aplatie au plateau (le remplissage sous le plateau = terrain normal, la
	# coupe au-dessus = air, tout ça géré par generate_chunk via h). Le
	# matériau de surface devient la route (gravier) sur une tuile route, ou
	# le sol de la palette (place/plancher de bâtiment) partout ailleurs dans
	# le footprint. Les murs/toits sont un overlay (voir generate_chunk).
	if not city.is_empty():
		var tile := _city_tile_type(wx, wz, city)
		if tile.get("in", false) and _city_terraforms(city, tile, wx, wz):
			h = _terrace_of(city, int(tile["idx"]))
			var palette: Dictionary = city["palette"]
			# UN MATÉRIAU PAR RÔLE. Tout le footprint partageait auparavant le
			# même sol de terre : rues, cours, champs et places se confondaient
			# en un seul disque brun, ce qui était le plus visible des défauts.
			var surface: int = int(palette["sol"])
			match int(tile["type"]):
				CityGenerator.Tile.ROUTE:
					surface = _road_id
				CityGenerator.Tile.PLACE:
					surface = int(palette["pave"])
				CityGenerator.Tile.CHAMP:
					surface = int(palette["champ"])
			# LE VILLAGE NE COUVRE PLUS TOUT SON FOOTPRINT (2026-08-09). Une rue
			# est une bande etroite, un plateau ne fait que l emprise de sa
			# maison : hors de ces surfaces, la colonne redevient du TERRAIN
			# NATUREL, avec son herbe et son relief. C est ce qui remplace la
			# mosaique de dalles carrees par un village pose dans un paysage.
			if _city_on_street(city, tile, wx, wz):
				return {"h": h, "surf": _road_id, "sub": int(palette["sol"]),
					"trans": trans, "acc": 0}
			if _city_terraforms(city, tile, wx, wz):
				return {"h": h, "surf": surface, "sub": int(palette["sol"]),
					"trans": trans, "acc": 0}

	# `acc` : matériau d'accent du biome retenu — le cristal/minerai que les
	# dimensions déposent en veines. Zéro dans l'overworld, qui tire ses filons
	# des bandes de profondeur (G.9) et non du biome de surface.
	var accent := 0
	if not _is_overworld and surf_pair.z >= 0:
		accent = _biome_accent[surf_pair.z]
	return {"h": h, "surf": surf_pair.x, "sub": surf_pair.y, "trans": trans, "acc": accent}


## Bande côtière (WATER_LEVEL à WATER_LEVEL+3) : le matériau de surface/sous-
## surface du BIOME cède la place à un matériau de rivage choisi par pente
## locale — plage de sable (pente douce), estran de galets (pente moyenne),
## falaise (pente forte), marécage côtier (pente très douce + humidité haute).
## Hors de cette bande, retourne le pair de biome inchangé (aucun effet).
func _coastal_override(h: int, gradient_mag: float, hum_n: float, biome_pair: Vector2i) -> Vector2i:
	if h < water_level or h > water_level + 3:
		return biome_pair
	var slope := clampf(gradient_mag * 10.0, 0.0, 1.0)
	if slope < 0.15 and hum_n > 0.6 and _marsh_id != 0:
		return Vector2i(_marsh_id, _marsh_sub_id)
	if slope < 0.35 and _sand_id != 0:
		return Vector2i(_sand_id, _sand_id)
	if slope < 0.6 and _gravel_id != 0:
		return Vector2i(_gravel_id, _gravel_id)
	if _cliff_id != 0:
		return Vector2i(_cliff_id, _cliff_id)
	return biome_pair


## Distance (unités normalisées de conditions) entre le point et le bord le
## plus proche de la "boîte" du biome b, sur les axes RÉELLEMENT contraints
## (les axes 0..1 non bornés par le biome sont ignorés — sans ça, un biome
## sans condition d'altitude serait toujours "près du bord" en altitude).
func _biome_clearance(alt_n: float, temp_n: float, hum_n: float, b: int) -> Dictionary:
	var o := b * _CONDITION_COUNT
	var best := 1.0
	var best_axis := -1
	var values := [alt_n, temp_n, hum_n]
	for axis in 3:
		var lo := _biome_min[o + axis]
		var hi := _biome_max[o + axis]
		if hi - lo >= 0.999:
			continue  # Axe non contraint pour ce biome : ignoré.
		var d := minf(values[axis] - lo, hi - values[axis])
		if d < best:
			best = d
			best_axis = axis
	return {"clearance": best, "axis": best_axis}


## Matériaux de surface/sous-surface au point (fx,fz), mélangés par
## dithering déterministe avec le biome voisin à l'approche d'une frontière
## (façon Minecraft — bande de quelques blocs, pas une coupure nette).
## RETOURNE AUSSI L'INDICE DU BIOME RETENU (`.z`, -1 si aucun). Il était
## recalculé par l'appelant qui en avait besoin — un second parcours complet de
## la matrice de biomes sur le chemin le plus chaud du générateur, pour une
## valeur qu'on venait de choisir ici.
func _blended_surface(fx: float, fz: float, alt_n: float, temp_n: float, hum_n: float, mana_n: float) -> Vector3i:
	var b0 := _biome_index_at(fx, fz, alt_n, temp_n, hum_n, mana_n)
	if b0 < 0:
		return Vector3i(0, 0, -1)
	var info := _biome_clearance(alt_n, temp_n, hum_n, b0)
	var clearance: float = info["clearance"]
	if clearance >= BIOME_TRANSITION_MARGIN or info["axis"] < 0:
		return Vector3i(_biome_surface[b0], _biome_subsurface[b0], b0)

	# Point proche d'un bord : ré-échantillonne légèrement AU-DELÀ de ce bord
	# sur l'axe concerné pour trouver le biome voisin plausible.
	var values := [alt_n, temp_n, hum_n]
	var axis: int = info["axis"]
	var o := b0 * _CONDITION_COUNT
	var lo := _biome_min[o + axis]
	var hi := _biome_max[o + axis]
	var push := BIOME_TRANSITION_MARGIN * 2.0
	values[axis] = (lo - push) if (values[axis] - lo) < (hi - values[axis]) else (hi + push)
	var b1 := _biome_index_at(fx, fz, values[0], values[1], values[2], mana_n)
	if b1 < 0 or b1 == b0:
		return Vector3i(_biome_surface[b0], _biome_subsurface[b0], b0)

	var roll := _pcg_hash(int(fx), int(fz), world_seed + SEED_BIOME_DITHER) / float(1 << 31)
	var b1_chance := clampf(1.0 - clearance / BIOME_TRANSITION_MARGIN, 0.0, 1.0)
	var chosen := b1 if roll < b1_chance else b0
	return Vector3i(_biome_surface[chosen], _biome_subsurface[chosen], chosen)


## Contexte de colonne-chunk : les 18×18 colonnes (16×16 intérieures + la
## coquille de 1) échantillonnées UNE FOIS, partagées entre la génération de
## tous les chunks de la colonne et le meshing (G.4 : cache par chunk-colonne).
## Layout : indice = (x+1) + (z+1)*18 pour x,z dans -1..16.
func prepare_context(col: Vector2i) -> Dictionary:
	var heights := PackedInt32Array()
	heights.resize(324)
	var surfaces := PackedInt32Array()
	surfaces.resize(324)
	var subsurfaces := PackedInt32Array()
	subsurfaces.resize(324)
	var transitions := PackedInt32Array()
	transitions.resize(324)
	var accents := PackedInt32Array()
	accents.resize(324)
	var bx := col.x * ChunkData.SIZE - 1
	var bz := col.y * ChunkData.SIZE - 1
	# Ville (point 5) : layout de la cellule de CE chunk-colonne, calculé UNE
	# fois (mutex) et partagé par les 18×18 colonnes. Le footprint étant centré
	# avec ≥1 tuile de marge, une colonne de coquille ne tombe jamais dans le
	# footprint d'une AUTRE cellule → utiliser ce layout pour toutes est correct.
	# `city_covering` et non le layout de la cellule : une CAPITALE peut
	# recouvrir ce chunk depuis une cellule voisine (2026-08-09). Un chunk-
	# colonne = une tuile, donc UN seul layout vaut pour ses 16x16 colonnes ; la
	# COQUILLE (le rang de bordure) peut en toute rigueur relever d un autre
	# layout au bord exact d une cellule — cas deja rarissime avant les
	# capitales, et la couture qui en resulterait est bornee a un bloc de
	# hauteur sur la ligne de partage. Assumé, documente, mesurable.
	var city := city_covering(col.x * ChunkData.SIZE, col.y * ChunkData.SIZE)
	var h_min := 1 << 30
	var h_max := -(1 << 30)
	var i := 0
	for z in 18:
		for x in 18:
			var r := _sample_column(bx + x, bz + z, city)
			heights[i] = r["h"]
			surfaces[i] = r["surf"]
			subsurfaces[i] = r["sub"]
			transitions[i] = r["trans"]
			accents[i] = r["acc"]
			h_min = mini(h_min, r["h"])
			h_max = maxi(h_max, r["h"])
			i += 1

	# Rivières (2026-07-20, E.2.2) : creusent le lit + EAU LOCALE (pas le
	# niveau de mer global, voir _river_carve_at) — local_water[icol] vaut
	# WATER_LEVEL partout, sauf sur une colonne traversée par un fleuve où il
	# vaut la hauteur de terrain D'ORIGINE (avant creusement) : l'eau remplit
	# le lit creusé jusqu'à ce niveau LOCAL, quelle que soit l'altitude —
	# permet des rivières de montagne, pas seulement au niveau de la mer.
	var local_water := PackedInt32Array()
	local_water.resize(324)
	for k in 324:
		local_water[k] = water_level
	var rivers := _rivers_near(bx - 1, bx + 18, bz - 1, bz + 18)
	if not rivers.is_empty():
		i = 0
		for z in 18:
			for x in 18:
				var carve := _river_carve_at(float(bx + x), float(bz + z), rivers)
				if carve > 0:
					local_water[i] = heights[i]
					heights[i] -= carve
					h_min = mini(h_min, heights[i])
					# Lit de rivière : gravier/sable plutôt que le matériau de
					# biome (herbe, etc.) qui se serait retrouvé sous l'eau.
					if _gravel_id != 0:
						surfaces[i] = _gravel_id
						subsurfaces[i] = _gravel_id
				i += 1

	# Arbres (survol 3D, TreeGenerator) : toute base dont l'empreinte pourrait
	# atteindre ce chunk-colonne (16×16 blocs, TREE_MAX_REACH de marge).
	var col_min_x := col.x * ChunkData.SIZE
	var col_min_z := col.y * ChunkData.SIZE
	var trees := _trees_in_window(col_min_x, col_min_x + ChunkData.SIZE - 1, col_min_z, col_min_z + ChunkData.SIZE - 1)
	# Ville : pas d'arbre/plante DANS le footprint (ils pousseraient sur le
	# terrain naturel à la mauvaise hauteur, en travers des bâtiments/routes).
	if not city.is_empty():
		trees = trees.filter(func(t: Dictionary) -> bool:
			var b: Vector3i = t["base"]
			return not _in_city_footprint(b.x, b.z, city))
	var top_max := maxi(h_max, water_level)  # L'eau peut dépasser le terrain le plus haut du lot (bassin).
	for tree: Dictionary in trees:
		for pos: Vector3i in (tree["blocks"] as Dictionary):
			top_max = maxi(top_max, pos.y)

	# Plantes de sol : même fenêtre que les arbres, footprint d'un seul bloc.
	var plants := _plants_in_window(col_min_x, col_min_x + ChunkData.SIZE - 1, col_min_z, col_min_z + ChunkData.SIZE - 1)
	if not city.is_empty():
		plants = plants.filter(func(p: Dictionary) -> bool:
			var pos: Vector3i = p["pos"]
			return not _in_city_footprint(pos.x, pos.z, city))
	for plant: Dictionary in plants:
		top_max = maxi(top_max, int((plant["pos"] as Vector3i).y))

	# Cultures/flore en sous-voxels (2026-07-20, PlantGenerator) : même
	# fenêtre, footprint d'un bloc (+ éventuellement celui du dessous pour
	# les racines, couvert par la marge -1 déjà présente sur hmin ailleurs).
	var cultures := _cultures_in_window(col_min_x, col_min_x + ChunkData.SIZE - 1, col_min_z, col_min_z + ChunkData.SIZE - 1)
	for culture: Dictionary in cultures:
		top_max = maxi(top_max, int((culture["base"] as Vector3i).y))

	# Les bâtiments montent au-dessus du plateau (B_HEIGHT+2) : élargir hmax
	# pour que leur chunk aérien ne soit pas sauté par le chemin rapide (G.2).
	if not city.is_empty():
		# LE PLUS HAUT DES PALIERS, pas le plateau moyen : sous-estimer cette
		# borne TRONQUE les toits du haut du village, ce qui ne se voit qu'en jeu
		# et de loin.
		var highest: int = int(city["plateau_y"])
		for terrace: int in (city.get("terraces", PackedInt32Array()) as PackedInt32Array):
			highest = maxi(highest, terrace)
		top_max = maxi(top_max, highest + CityGenerator.MAX_BUILD_HEIGHT + 2)

	# Termitière de donjon (2026-07-28) : même raison que les bâtiments de ville
	# juste au-dessus — sa masse dépasse largement le relief, et `hmax` pilote la
	# bande de chunks que _column_task accepte de générer/mailler. Sans ça, la
	# structure était tronquée quelques blocs au-dessus du sol.
	var tower_top := tower_top_for_column(col)
	if tower_top > 0:
		top_max = maxi(top_max, tower_top)

	# FEATURES DE DIMENSION (îles suspendues, arbres pendus aux plafonds,
	# spirales). Elles empruntent le même canal que les arbres : un survol 3D
	# épars calculé UNE FOIS par colonne de chunks, puis estampé chunk par
	# chunk. C'est ce qui les fait passer par le pipeline multithreadé au lieu
	# d'être écrites bloc par bloc dans la frame.
	var overlay := {}
	if not _is_overworld:
		overlay = _dim_features(col, heights, surfaces, subsurfaces, accents)
		for pos: Vector3i in overlay:
			top_max = maxi(top_max, pos.y)

	# Teinte d'herbe du biome (2026-08-09) : grille 3×3 échantillonnée aux MÊMES
	# points monde que l'ancienne texture par chunk (offsets 0/8/16, partagés
	# avec les colonnes voisines — la continuité aux jointures en dépend). Le
	# mesher la cuit PAR SOMMET dans COLOR.gba, ce qui a permis le matériau
	# partagé entre tous les chunks (plus de duplicata ni de rebind par draw).
	var tint := PackedColorArray()
	tint.resize(9)
	for gz in 3:
		for gx in 3:
			var twx := col.x * ChunkData.SIZE + int(round(float(gx) / 2.0 * ChunkData.SIZE))
			var twz := col.y * ChunkData.SIZE + int(round(float(gz) / 2.0 * ChunkData.SIZE))
			var tb: Array = biome_at(twx, twz).get("grass_tint", [1.0, 1.0, 1.0])
			tint[gz * 3 + gx] = Color(tb[0], tb[1], tb[2])

	return {
		"h": heights, "surf": surfaces, "sub": subsurfaces, "trans": transitions,
		"acc": accents, "overlay": overlay,
		"trees": trees, "plants": plants, "cultures": cultures, "hmin": h_min, "hmax": top_max,
		"local_water": local_water, "city": city, "tint": tint,
	}


# --- Spéléologie/géologie souterraine (2026-07-20, E.2.4/E.2.5) ---

## True si (wx,wy,wz) doit être creusé (air) : karst — deux champs "vers" 3D
## dont l'intersection forme des tunnels sinueux, PLUS un bruit de cavité
## basse fréquence pour de grandes salles. Borné en profondeur (jamais près
## de la surface ni du plancher du monde ni au-delà de CAVE_MAX_DEPTH — coût
## et réalisme, le karst ne s'étend pas à l'infini).
func _is_cave_at(wx: int, wy: int, wz: int, h: int) -> bool:
	if not _p_caves:
		return false  # Cavernes désactivées par le profil du monde.
	if not _is_overworld:
		return _dim_is_cave_at(wx, wy, wz, h)
	var depth := h - wy
	if depth < CAVE_MIN_DEPTH or depth > CAVE_MAX_DEPTH:
		return false
	if wy < WORLD_FLOOR + CAVE_MAX_DEPTH_FROM_FLOOR:
		return false
	# Rejet bon marché AVANT tout bruit 3D (même leçon que les arbres/plantes/
	# rivières, 2026-07-20 — celui-ci manquait ici, coût mesuré : meshing
	# moyen ~22 ms au bench de vol, contre ~6-9 ms avant les cavernes) : un
	# hachage PAR CELLULE de CAVE_CELL_SIZE blocs (pas par bloc individuel,
	# pour ne pas fragmenter les tunnels en "sel et poivre") décide si CETTE
	# ZONE peut contenir des cavernes du tout — sinon aucun bruit 3D n'est
	# jamais échantillonné pour elle.
	var cell_roll := _pcg_hash(wx >> CAVE_CELL_SHIFT, wz >> CAVE_CELL_SHIFT, world_seed + SEED_CAVE_CELL) / float(1 << 31)
	if cell_roll >= CAVE_CELL_ACCEPT:
		return false
	var fx := float(wx)
	var fy := float(wy)
	var fz := float(wz)
	var cavern: float = _cavern.get_noise_3d(fx, fy, fz) * 0.5 + 0.5
	if cavern > CAVE_CAVERN_THRESHOLD:
		return true  # Grande salle.
	var a := _cave_a.get_noise_3d(fx, fy, fz)
	if absf(a) > CAVE_TUNNEL_THRESHOLD:
		return false
	var b := _cave_b.get_noise_3d(fx, fy, fz)
	return absf(b) < CAVE_TUNNEL_THRESHOLD  # Intersection des deux champs = tunnel.


## CAVERNES D'UNE DIMENSION : le sol n'est pas une croûte mais un VOLUME.
##
## Un terrain qui n'a qu'une surface et un remplissage plein n'offre ni salle,
## ni surplomb, ni second niveau — on marche dessus et c'est tout. Le bruit 3D
## y creuse des cavernes, des voûtes et des puits qui traversent.
##
## LE REJET PAR CELLULE EST LA RAISON POUR LAQUELLE C'EST ABORDABLE, et c'est ce
## qui manquait à l'ancien constructeur : chaque bloc de croûte y payait un
## échantillon de bruit 3D plein. La leçon est la même que pour les arbres, les
## plantes, les rivières et le karst de l'overworld — un hachage par cellule
## AVANT le premier échantillon, et l'immense majorité des zones ne paie rien.
func _dim_is_cave_at(wx: int, wy: int, wz: int, h: int) -> bool:
	if _dim_cave == null:
		return false
	var depth := h - wy
	# Les premiers blocs restent pleins : une caverne qui débouche au ras du sol
	# ferait un trou dans le paysage, pas une grotte.
	if depth < 8:
		return false
	if _pcg_hash(wx >> DIM_CAVE_CELL_SHIFT, wz >> DIM_CAVE_CELL_SHIFT,
			world_seed + SEED_DIM_CAVE_CELL) / float(1 << 31) >= DIM_CAVE_CELL_ACCEPT:
		return false
	# Le seuil monte avec la profondeur : à peine troué près de la surface, des
	# salles larges plus bas.
	var opening := clampf((float(depth) - 8.0) / 26.0, 0.0, 1.0)
	return absf(_dim_cave.get_noise_3d(float(wx), float(wy) * 1.6, float(wz))) \
			< _dim_cave_threshold * opening


## FILON D'UNE DIMENSION : rare, groupé, jamais en surface — la raison de
## creuser. Le matériau est l'`accent_material` du biome, donc la donnée dit
## quel cristal éclaire quel pays.
func _dim_is_ore_at(wx: int, wy: int, wz: int) -> bool:
	if _dim_ore == null:
		return false
	if _pcg_hash(wx >> DIM_ORE_CELL_SHIFT, wz >> DIM_ORE_CELL_SHIFT,
			world_seed + SEED_DIM_ORE_CELL) / float(1 << 31) >= DIM_ORE_CELL_ACCEPT:
		return false
	return _dim_ore.get_noise_3d(float(wx), float(wy), float(wz)) > DIM_ORE_VEIN_THRESHOLD


## Spéléothèmes (calcite) + dépôts organiques (guano) : passe appliquée APRÈS
## le remplissage principal d'un chunk, sur SES PROPRES blocs uniquement
## (SIMPLIFICATION ASSUMÉE : une poche à cheval sur 2 chunks peut avoir des
## spéléothèmes visuellement coupés à la frontière, E.2.4). Cherche les
## transitions plafond/sol dans les poches d'air souterraines déjà creusées.
## `bx`/`bz` : origine MONDE du chunk — le hachage doit porter sur les
## coordonnées monde (audit 2026-07-21 : hacher les coordonnées LOCALES 0-15
## faisait se répéter le motif de stalactites tous les 16 blocs, deux
## chunk-colonnes à la même altitude tirant exactement les mêmes rolls).
func _speleothem_pass(blocks: PackedByteArray, heights: PackedInt32Array, y0: int, bx: int, bz: int) -> void:
	if _calcite_id == 0:
		return
	for z in ChunkData.SIZE:
		for x in ChunkData.SIZE:
			var icol := (x + 1) + (z + 1) * 18
			var h := heights[icol]
			if h - y0 < CAVE_MIN_DEPTH:
				continue  # Colonne trop proche de la surface pour des cavernes.
			var offset := (x | (z << 4)) << 1
			var wx := bx + x
			var wz := bz + z
			for y in ChunkData.SIZE - 1:
				var here := blocks.decode_u16(offset + (y << 9))
				var above := blocks.decode_u16(offset + ((y + 1) << 9))
				if here == 0 and above != 0 and above != _water_id:
					# Plafond d'une poche d'air : stalactite (pend du plafond).
					var roll := _pcg_hash(wx + (y0 + y) * 4096, wz, world_seed + SEED_SPELEOTHEM) / float(1 << 31)
					if roll < SPELEOTHEM_CHANCE:
						blocks.encode_u16(offset + (y << 9), _calcite_id)
				elif here != 0 and here != _water_id and y > 0:
					var below := blocks.decode_u16(offset + ((y - 1) << 9))
					if below == 0:
						# Sol d'une poche d'air : stalagmite (pousse du sol) ou
						# guano (dépôt organique, chance plus faible) — jamais
						# les deux au même endroit.
						var roll2 := _pcg_hash(wx + (y0 + y) * 4096, wz + 7919, world_seed + SEED_SPELEOTHEM) / float(1 << 31)
						if roll2 < SPELEOTHEM_CHANCE * 0.5 and _guano_id != 0:
							blocks.encode_u16(offset + ((y - 1) << 9), _guano_id)
						elif roll2 < SPELEOTHEM_CHANCE:
							blocks.encode_u16(offset + ((y - 1) << 9), _calcite_id)


# --- Génération de chunk ---

## Génère les données d'un chunk depuis un contexte de colonne préparé.
func generate_chunk(cpos: Vector3i, ctx: Dictionary) -> ChunkData:
	var y0 := cpos.y * ChunkData.SIZE
	var y1 := y0 + ChunkData.SIZE - 1
	# Tour de donjon : elle monte à 96 blocs au-dessus du sol, donc TRÈS
	# au-dessus de `hmax`. Sans ce test, les chemins rapides « chunk
	# uniformément d'air » la feraient disparaître sur toute sa hauteur.
	var tower_cell: Variant = _tower_in_chunk(cpos)
	# Chemins rapides uniformes (G.2) — hmax inclut déjà les cimes d'arbres.
	if y0 > int(ctx["hmax"]) and tower_cell == null:
		return ChunkData.create_uniform(0)
	# (Audit 2026-07-21 : la condition « aucun arbre dans la colonne » a été
	# retirée — un arbre ne descend jamais sous la surface, donc jamais sous
	# hmin-400 ; en forêt, elle désactivait ce fast-path pour TOUS les chunks
	# profonds, qui allouaient leurs 8 Ko au lieu d'être uniformes.)
	if _is_overworld:
		if y1 < int(ctx["hmin"]) - 400 and _strata_count > 0 and tower_cell == null:
			return ChunkData.create_uniform(_strata_ids[_strata_count - 1])
	# SOUS LA CROÛTE D'UNE DIMENSION IL N'Y A RIEN, et c'est ce qui borne le
	# coût : le sol y est une dalle posée sur le vide, pas une planète pleine.
	# Sans ce chemin rapide, chaque colonne écrirait des centaines de blocs de
	# roche que personne ne voit — c'était l'essentiel du coût de l'ancien
	# constructeur, qui remplissait sa croûte bloc par bloc.
	elif y1 < int(ctx["hmin"]) - _dim_crust:
		return ChunkData.create_uniform(0)

	var heights: PackedInt32Array = ctx["h"]
	var surfaces: PackedInt32Array = ctx["surf"]
	var subsurfaces: PackedInt32Array = ctx["sub"]
	var transitions: PackedInt32Array = ctx["trans"]
	var local_water: PackedInt32Array = ctx["local_water"]
	var accents: PackedInt32Array = ctx["acc"]
	var blocks := PackedByteArray()
	blocks.resize(ChunkData.VOLUME * 2)  # zéros = air
	var block_hosts := {}  # indice bloc → roche/terre hôte (masque minerai/herbe).
	var chunk_bx := cpos.x * ChunkData.SIZE
	var chunk_bz := cpos.z * ChunkData.SIZE

	for z in ChunkData.SIZE:
		for x in ChunkData.SIZE:
			var icol := (x + 1) + (z + 1) * 18
			var h := heights[icol]
			var water_level := local_water[icol]
			var col_top := maxi(h, water_level)
			if col_top < y0:
				continue  # Colonne entièrement au-dessus de la surface : air.
			var surface := surfaces[icol]
			var subsurface := subsurfaces[icol]
			var trans := transitions[icol]
			var accent := accents[icol]
			var wx := chunk_bx + x
			var wz := chunk_bz + z
			var top_y := mini(ChunkData.SIZE - 1, col_top - y0)
			var offset := (x | (z << 4)) << 1
			for y in top_y + 1:
				var wy := y0 + y
				var depth := h - wy
				var id := 0
				var host := 0  # Roche/terre hôte (masque minerai/herbe, shader).
				if depth >= 0:
					id = surface
					if depth == 0 and id == _herbe_id:
						host = subsurface  # Herbe = masque vert sur la terre dessous.
					if depth > 0 and not _is_overworld:
						# DIMENSION : la surface, une croûte de roche, puis le vide.
						# Les veines d'accent y remplacent la roche — c'est la seule
						# raison de creuser, une dimension n'ayant ni strates ni
						# bandes de minerais par profondeur.
						# CE BLOC ET `_deep_block` DOIVENT RESTER DES MIROIRS : le
						# second remplit la coquille de voisinage du mailleur, et une
						# divergence entre les deux se voit en parois fantômes aux
						# frontières de chunk.
						if depth > _dim_crust:
							id = 0
						else:
							id = subsurface
							if accent != 0 and _dim_is_ore_at(wx, wy, wz):
								host = id
								id = accent
							if id != 0 and _dim_is_cave_at(wx, wy, wz, h):
								id = 0
								host = 0
					elif depth > 0:
						if depth <= SUBSURFACE_THICKNESS:
							id = subsurface
						else:
							# Strates par profondeur sous la surface (G.9), avec
							# frontières décalées par le bruit de transition.
							for s in _strata_count:
								if depth <= _strata_end[s] + (trans * _strata_trans[s]) / 1000:
									id = _strata_ids[s]
									break
							# Filons de minerai (G.9, 2026-07-24) : remplacent la
							# roche par un minerai/gemme/fossile de la bande de
							# profondeur. Profondeur SOUS la surface → adapté aux
							# montagnes. Placé AVANT le karst (une caverne peut
							# recreuser et exposer un filon).
							if id != 0:
								var ore := _ore_at(wx, wy, wz, depth, id)
								if ore != 0:
									host = id  # roche hôte du filon
									id = ore
							# Karst (E.2.4) : creuse la roche pleine en poche
							# d'air (2026-07-20 : les gaz souterrains ont été
							# retirés de la génération, demande explicite).
							if id != 0 and _is_cave_at(wx, wy, wz, h):
								id = 0
								host = 0
				elif wy <= water_level:
					id = _water_id  # Bassin sous le niveau de mer OU lit de rivière (E.2/E.2.2).
				blocks.encode_u16(offset + (y << 9), id)
				if host != 0:
					block_hosts[x | (z << 4) | (y << 8)] = host

	# Survol des arbres (TreeGenerator) : voxels 3D épars, superposés APRÈS
	# le terrain (une branche/canopée ne remplace jamais un bloc plein sous
	# elle, seulement l'air — évite qu'un arbre s'incruste dans une colline).
	# `extra_subdivs` reçoit aussi les congés de liaison des arbres
	# (SUBDIVIDE_JOINTS, TreeGenerator) ET les cultures (plus bas) —
	# un seul dictionnaire fusionné dans `data.subdivs` à la fin.
	var bx := cpos.x * ChunkData.SIZE
	var bz := cpos.z * ChunkData.SIZE
	var extra_subdivs := {}
	for tree: Dictionary in (ctx["trees"] as Array):
		var trunk_subdivs: Dictionary = tree.get("trunk_subdivs", {})
		for pos: Vector3i in (tree["blocks"] as Dictionary):
			if pos.y < y0 or pos.y > y1:
				continue
			var lx := pos.x - bx
			var lz := pos.z - bz
			if lx < 0 or lx >= ChunkData.SIZE or lz < 0 or lz >= ChunkData.SIZE:
				continue
			var index := ChunkData.index_of(lx, pos.y - y0, lz)
			var existing := blocks.decode_u16(index << 1)
			if existing != 0 and existing != _water_id:
				continue  # Ne recouvre pas un bloc plein déjà posé (terrain), mais l'eau cède la place au tronc.
			blocks.encode_u16(index << 1, tree["blocks"][pos])
			if trunk_subdivs.has(pos):
				extra_subdivs[index] = trunk_subdivs[pos]

	# Plantes de sol : posées seulement sur de l'air (jamais sous un arbre ni
	# dans l'eau) — un simple bloc décoratif au-dessus de la surface.
	for plant: Dictionary in (ctx["plants"] as Array):
		var pos: Vector3i = plant["pos"]
		if pos.y < y0 or pos.y > y1:
			continue
		var lx := pos.x - bx
		var lz := pos.z - bz
		if lx < 0 or lx >= ChunkData.SIZE or lz < 0 or lz >= ChunkData.SIZE:
			continue
		var index := ChunkData.index_of(lx, pos.y - y0, lz)
		if blocks.decode_u16(index << 1) != 0:
			continue
		blocks.encode_u16(index << 1, plant["material_id"])

	# Cultures/flore en sous-voxels (2026-07-20, PlantGenerator) : structure
	# 3D PARTIELLE dans un bloc (SubdivGrid), pas un remplacement de bloc
	# plein. Écrit directement dans `blocks` (id dominant, pour la visée/LOD)
	# + un dictionnaire local de sous-grilles fusionné dans `data.subdivs` à
	# la fin (évite tout risque de copie-sur-écriture en passant par
	# `data.set_subdiv` avant que `data.blocks` soit assigné). Budget propre
	# (CULTURE_SUBDIV_BUDGET), généreusement sous les 512 du budget joueur
	# (WorldManager.SUBDIV_BUDGET_PER_CHUNK) pour laisser de la marge à la
	# construction après génération.
	for culture: Dictionary in (ctx["cultures"] as Array):
		if extra_subdivs.size() >= CULTURE_SUBDIV_BUDGET:
			break
		var base: Vector3i = culture["base"]
		if base.y < y0 or base.y > y1:
			continue
		var clx := base.x - bx
		var clz := base.z - bz
		if clx < 0 or clx >= ChunkData.SIZE or clz < 0 or clz >= ChunkData.SIZE:
			continue
		var cindex := ChunkData.index_of(clx, base.y - y0, clz)
		if blocks.decode_u16(cindex << 1) != 0:
			continue  # Bloc déjà occupé (arbre, plante de sol...) : pas de culture ici.
		var species: Dictionary = GameData.plants.get(culture["species_id"], {})
		if species.is_empty():
			continue
		var stage: int = int((species.get("agriculture", {}) as Dictionary).get("stages", 1)) - 1
		var result := PlantGenerator.generate(base, world_seed, species, stage)
		var grid: PackedInt32Array = result["grid"]
		var dominant := SubdivGrid.dominant_id(grid)
		if dominant == 0:
			continue
		blocks.encode_u16(cindex << 1, dominant)
		extra_subdivs[cindex] = grid
		# Racines (pomme de terre/mandragore) : sous-grille dans le bloc DU
		# DESSOUS, seulement s'il est solide (embarque dans la terre, pas
		# dans l'air/l'eau).
		var root_grid: PackedInt32Array = result.get("root_grid", PackedInt32Array())
		if not root_grid.is_empty() and base.y - 1 >= y0:
			var root_index := ChunkData.index_of(clx, base.y - 1 - y0, clz)
			var root_existing := blocks.decode_u16(root_index << 1)
			if root_existing != 0 and root_existing != _water_id:
				var root_dominant := SubdivGrid.dominant_id(root_grid)
				if root_dominant != 0:
					blocks.encode_u16(root_index << 1, root_dominant)
					extra_subdivs[root_index] = root_grid

	# Bâtiments de ville (point 5) : ce chunk-colonne = UNE tuile ; si c'est
	# une tuile bâtiment, poser ses murs/toit (précalculés) dans la tranche
	# verticale [y0,y1]. Écrit par-dessus l'air au-dessus du plateau terrassé.
	var city: Dictionary = ctx.get("city", {})
	if not city.is_empty():
		var tile := _city_tile_type(chunk_bx, chunk_bz, city)
		if tile.get("in", false):
			# Batiment OU decor : les deux se posent pareil, en surcouche
			# au-dessus du palier terrasse. Le decor n existe que sur les tuiles
			# non baties, les deux dictionnaires ne se marchent donc jamais
			# dessus.
			var bb: Dictionary = (city["building_blocks"] as Dictionary).get(tile["idx"], {})
			if bb.is_empty():
				bb = (city.get("decor_blocks", {}) as Dictionary).get(tile["idx"], {})
			var plateau := _terrace_of(city, int(tile["idx"]))
			for local_pos: Vector3i in bb:
				var wy := plateau + local_pos.y
				if wy < y0 or wy > y1:
					continue
				var index := ChunkData.index_of(local_pos.x, wy - y0, local_pos.z)
				blocks.encode_u16(index << 1, int(bb[local_pos]))

	if _is_overworld:
		_speleothem_pass(blocks, heights, y0, chunk_bx, chunk_bz)
	else:
		# FEATURES DE DIMENSION : îles suspendues, rampes en spirale, arbres
		# pendus aux plafonds. Elles sont AUTORITAIRES sur le terrain — une île
		# doit exister même si le relief remonte dedans, et une rampe qui cède
		# au sol ne mène nulle part.
		var overlay: Dictionary = ctx["overlay"]
		for pos: Vector3i in overlay:
			if pos.y < y0 or pos.y > y1:
				continue
			var olx := pos.x - chunk_bx
			var olz := pos.z - chunk_bz
			if olx < 0 or olx >= ChunkData.SIZE or olz < 0 or olz >= ChunkData.SIZE:
				continue
			blocks.encode_u16(ChunkData.index_of(olx, pos.y - y0, olz) << 1, int(overlay[pos]))

	# Tour de donjon : écrite EN DERNIER et de façon autoritaire — ses murs
	# remplacent le terrain, et son intérieur creux reste creux même si le
	# relief remonte dedans. Sans quoi la tour serait à moitié enterrée.
	if tower_cell != null:
		var cell: Vector2i = tower_cell
		var ground := _tower_ground(cell)
		var palette := _tower_palette_ids(cell)
		var max_height := float(DungeonTower.MAX_HEIGHT)
		var centre := DungeonTower.center_of(cell)
		for lz in ChunkData.SIZE:
			var wz := chunk_bz + lz
			var dz := float(wz - centre.y)
			for lx in ChunkData.SIZE:
				var wx := chunk_bx + lx
				if not DungeonTower.contains(cell, wx, wz):
					continue
				# Hauteur de la masse calculée UNE fois par colonne : elle ne
				# dépend pas de y, et l'évaluer par bloc multiplierait par 16
				# le coût du bruit sur une structure de ~100 000 blocs.
				var top := DungeonTower.height_at(cell, wx, wz, world_seed)
				if top <= 0.0:
					continue
				var dx := float(wx - centre.x)
				for ly in ChunkData.SIZE:
					var wy := y0 + ly
					var local_y := wy - ground
					if local_y < 0 or float(local_y) > top or float(local_y) > max_height:
						continue
					# Creusement (salle, tunnels, puits) puis maçonnerie. Cette
					# boucle DOIT rester le miroir exact de DungeonTower.block_at
					# — elle n'existe que pour hisser `height_at` hors de l'axe Y.
					var id := 0
					if not DungeonTower._is_carved(dx, local_y, dz):
						id = DungeonTower._material_for(wx, wy, wz, local_y, world_seed, palette)
					var index := ChunkData.index_of(lx, ly, lz)
					blocks.encode_u16(index << 1, id)

	var data := ChunkData.new()
	data.blocks = blocks
	data.block_host = block_hosts
	for idx in extra_subdivs:
		data.attach_subdiv(idx, extra_subdivs[idx])
	return data


## Construit la coquille de voisinage (6 dalles) du tableau padded du mesher
## depuis le contexte de colonne. Retourne `[pad, air]` — le pad est ALLOUÉ ici
## (2026-08-09 : le chemin natif ne peut pas muter un paramètre à travers la
## frontière GDExtension, copie-sur-écriture oblige ; rendre le tableau est le
## seul contrat qui vaille pour les deux chemins).
##
## Le TERRAIN des dalles (surface/sous-surface/strates/cavernes) part en C++
## (`fill_shell_terrain`, miroir strict) quand la DLL est là ET que
## `ChunkMesher.use_native` est vrai — même bascule que le mesher, pour que la
## sonde --probe-mesh-parite couvre les DEUX ports d'un seul A/B. Les
## SURCOUCHES (arbres, plantes, features de dimension, bâtiments) restent en
## GDScript ci-dessous, partagées par les deux chemins.
func fill_shell(cpos: Vector3i, ctx: Dictionary) -> Array:
	var pad := PackedInt32Array()
	var air := false

	if _native_shell != null and ChunkMesher.use_native:
		var out: Array = _native_shell.fill_shell_terrain(cpos, ctx["h"],
				ctx["surf"], ctx["sub"], ctx["trans"], ctx["local_water"], ctx["acc"])
		pad = out[0]
		air = out[1]
	else:
		pad.resize(18 * 18 * 18)
		air = _fill_shell_terrain_gd(cpos, pad, ctx)

	_apply_shell_overlays(cpos, pad, ctx)
	return [pad, air]


## Chemin GDScript de RÉFÉRENCE du terrain de coquille — boucles inline, aucun
## appel de méthode par bloc (leçon du bench étape 1 : verrous GDScript
## inter-threads). MIROIR de VoxenNative.fill_shell_terrain : toute divergence
## se paie en parois fantômes aux frontières de chunk, et c'est la sonde de
## parité qui la détecte.
func _fill_shell_terrain_gd(cpos: Vector3i, pad: PackedInt32Array, ctx: Dictionary) -> bool:
	var t := ChunkData.SIZE
	var y0 := cpos.y * t
	var heights: PackedInt32Array = ctx["h"]
	var surfaces: PackedInt32Array = ctx["surf"]
	var subsurfaces: PackedInt32Array = ctx["sub"]
	var transitions: PackedInt32Array = ctx["trans"]
	var local_water: PackedInt32Array = ctx["local_water"]
	var accents: PackedInt32Array = ctx["acc"]
	var air := false

	# Les 6 dalles sont traitées PAR COLONNE de coquille : la résolution
	# surface/sous-surface/strates est 100 % inline — aucun appel de méthode
	# par bloc. Dalles X-/X+/Z-/Z+ : pour chaque colonne latérale, 16 y.
	for side in 4:
		for k in t:
			var icol: int
			var pad_base: int
			var pad_step := 324  # stride vertical du pad
			var wx: int
			var wz: int
			match side:
				0:  # X- : colonne ctx x=-1
					icol = (k + 1) * 18
					pad_base = 324 + (k + 1) * 18
					wx = cpos.x * t - 1
					wz = cpos.z * t + k
				1:  # X+ : colonne ctx x=16
					icol = (k + 1) * 18 + 17
					pad_base = 324 + (k + 1) * 18 + t + 1
					wx = cpos.x * t + t
					wz = cpos.z * t + k
				2:  # Z- : colonne ctx z=-1
					icol = k + 1
					pad_base = 324 + k + 1
					wx = cpos.x * t + k
					wz = cpos.z * t - 1
				_:  # Z+ : colonne ctx z=16
					icol = k + 1 + 17 * 18
					pad_base = 324 + (t + 1) * 18 + k + 1
					wx = cpos.x * t + k
					wz = cpos.z * t + t
			var h := heights[icol]
			var surface := surfaces[icol]
			var subsurface := subsurfaces[icol]
			var trans := transitions[icol]
			var accent := accents[icol]
			var water_level := local_water[icol]
			for y in t:
				var wy := y0 + y
				var v := 0
				if wy <= h:
					var depth := h - wy
					if depth == 0:
						v = surface
					elif depth <= SUBSURFACE_THICKNESS and _is_overworld:
						v = subsurface
					else:
						v = _deep_block(depth, subsurface, trans, accent, wx, wy, wz, h)
				elif wy <= water_level:
					v = _water_id
				else:
					air = true
				pad[pad_base + y * pad_step] = v

	# Dalles Y- (wy = y0-1) et Y+ (wy = y0+16), colonnes intérieures.
	for face in 2:
		var wy := (y0 - 1) if face == 0 else (y0 + t)
		var off_y := 0 if face == 0 else (t + 1) * 324
		for z in t:
			var row := off_y + (z + 1) * 18
			for x in t:
				var icol := (x + 1) + (z + 1) * 18
				var h := heights[icol]
				var v := 0
				if wy <= h:
					var depth := h - wy
					if depth == 0:
						v = surfaces[icol]
					elif depth <= SUBSURFACE_THICKNESS and _is_overworld:
						v = subsurfaces[icol]
					else:
						v = _deep_block(depth, subsurfaces[icol], transitions[icol], accents[icol],
								cpos.x * t + x, wy, cpos.z * t + z, h)
				elif wy <= local_water[icol]:
					v = _water_id
				else:
					air = true
				pad[row + x + 1] = v
	return air


## SURCOUCHES de la coquille — arbres, plantes, features de dimension,
## bâtiments de ville — partagées par les chemins natif et GDScript du terrain
## (elles écrivent le pad EN PLACE, en GDScript : petits dictionnaires épars,
## rien à gagner à les porter, tout à perdre en surface de divergence).
func _apply_shell_overlays(cpos: Vector3i, pad: PackedInt32Array, ctx: Dictionary) -> void:
	var t := ChunkData.SIZE
	var y0 := cpos.y * t
	# Survol des arbres sur la coquille : ne recouvre jamais un bloc plein
	# déjà posé (terrain), seulement de l'air (même règle qu'en génération).
	var bx := cpos.x * t
	var by := cpos.y * t
	var bz := cpos.z * t
	# Features de dimension : mêmes règles que les arbres, mais AUTORITAIRES —
	# une île suspendue est du terrain, pas un survol posé sur de l'air.
	if not _is_overworld:
		var overlay: Dictionary = ctx["overlay"]
		for pos: Vector3i in overlay:
			var ox := pos.x - bx
			var oy := pos.y - by
			var oz := pos.z - bz
			if ox < -1 or ox > t or oy < -1 or oy > t or oz < -1 or oz > t:
				continue
			if ox > -1 and ox < t and oy > -1 and oy < t and oz > -1 and oz < t:
				continue   # Intérieur du chunk : ce n'est pas la coquille.
			pad[(ox + 1) + (oz + 1) * 18 + (oy + 1) * 324] = int(overlay[pos])

	for tree: Dictionary in (ctx["trees"] as Array):
		for pos: Vector3i in (tree["blocks"] as Dictionary):
			var px := pos.x - bx
			var py := pos.y - by
			var pz := pos.z - bz
			if px < -1 or px > t or py < -1 or py > t or pz < -1 or pz > t:
				continue
			# Seule la COQUILLE (bordure, pas l'intérieur) nous concerne ici.
			if px > -1 and px < t and py > -1 and py < t and pz > -1 and pz < t:
				continue
			var index := (px + 1) + (pz + 1) * 18 + (py + 1) * 324
			if pad[index] == 0 or pad[index] == _water_id:
				pad[index] = tree["blocks"][pos]

	for plant: Dictionary in (ctx["plants"] as Array):
		var pos: Vector3i = plant["pos"]
		var px := pos.x - bx
		var py := pos.y - by
		var pz := pos.z - bz
		if px < -1 or px > t or py < -1 or py > t or pz < -1 or pz > t:
			continue
		if px > -1 and px < t and py > -1 and py < t and pz > -1 and pz < t:
			continue
		var index := (px + 1) + (pz + 1) * 18 + (py + 1) * 324
		if pad[index] == 0:
			pad[index] = plant["material_id"]

	# Bâtiments sur les faces Y de la coquille (point 5) : un mur/toit peut
	# traverser une frontière verticale de chunk. X/Z non nécessaires (le
	# bâtiment garde 3 blocs de marge au bord de tuile, il ne touche jamais
	# les frontières horizontales de chunk).
	var city: Dictionary = ctx.get("city", {})
	if not city.is_empty():
		for face in 2:
			var wy := (y0 - 1) if face == 0 else (y0 + t)
			var off_y := 0 if face == 0 else (t + 1) * 324
			for z in t:
				var row := off_y + (z + 1) * 18
				for x in t:
					var bid := _city_block_at(bx + x, wy, bz + z, city)
					if bid != 0:
						pad[row + x + 1] = bid


## Résolution d'un bloc depuis les données de colonne (surface/sous-surface/
## strates). Petite et appelée hors chemins chauds uniquement.
## LE BLOC SOUS LA SOUS-SURFACE, résolu une fois pour tous les chemins FROIDS :
## la coquille de voisinage du mailleur (`fill_shell`, 6 dalles) et les requêtes
## ponctuelles (`_block_from_column`).
##
## Le chemin CHAUD — la boucle de `generate_chunk` — garde sa version inline :
## un appel de méthode par bloc s'y paierait des centaines de milliers de fois
## par colonne. Les deux DOIVENT rester des miroirs ; une divergence se
## traduirait par des parois fantômes aux frontières de chunk, là où la coquille
## et le chunk ne s'accorderaient plus sur ce qui est plein.
func _deep_block(depth: int, subsurface: int, trans: int, accent: int,
		wx: int, wy: int, wz: int, h: int) -> int:
	if not _is_overworld:
		if depth > _dim_crust:
			return 0
		var id := subsurface
		if accent != 0 and _dim_is_ore_at(wx, wy, wz):
			id = accent
		if id != 0 and _dim_is_cave_at(wx, wy, wz, h):
			return 0
		return id
	var v := 0
	for st in _strata_count:
		if depth <= _strata_end[st] + (trans * _strata_trans[st]) / 1000:
			v = _strata_ids[st]
			break
	if v != 0 and _is_cave_at(wx, wy, wz, h):
		return 0
	return v


func _block_from_column(wy: int, h: int, surface: int, subsurface: int, trans: int,
		accent: int = 0, wx: int = 0, wz: int = 0) -> int:
	if wy > h:
		# Pas de niveau de mer dans une dimension : au-dessus du sol, c'est le vide.
		return (_water_id if wy <= water_level else 0) if _is_overworld else 0
	var depth := h - wy
	if depth == 0:
		return surface
	if depth <= SUBSURFACE_THICKNESS and _is_overworld:
		return subsurface
	return _deep_block(depth, subsurface, trans, accent, wx, wy, wz, h)


# --- Accès unitaires (HUD, spawn, futurs systèmes — hors chemins chauds) ---

## Id matériau au bloc monde (wx, wy, wz). 0 = air. Vérifie le terrain PUIS
## un éventuel survol d'arbre (requête ponctuelle, hors chemin chaud — la
## visée/mining passe par le cache de chunks la plupart du temps).
func block_at(wx: int, wy: int, wz: int) -> int:
	var city := city_covering(wx, wz)
	var r := _sample_column(wx, wz, city)
	# Bâtiment de ville : au-dessus du plateau terrassé (terrain = air ici).
	if not city.is_empty():
		var bid := _city_block_at(wx, wy, wz, city)
		if bid != 0:
			return bid
	# Tour de donjon : posée par-dessus le terrain, elle prime (son intérieur
	# creux doit rester creux même si le relief remonte dedans).
	var tower_id := _tower_block_at(wx, wy, wz)
	if tower_id >= 0:
		return tower_id  # 0 = intérieur creux, et c'est une réponse VALIDE.
	var terrain_id := _block_from_column(wy, r["h"], r["surf"], r["sub"], r["trans"],
			int(r["acc"]), wx, wz)
	# Filon de minerai dans la roche (G.9) — cohérent avec generate_chunk :
	# strate résolue puis filon, avant le creusement des cavernes. Une dimension
	# a déjà eu ses veines et ses cavernes dans `_deep_block` : les rejouer ici
	# lui appliquerait EN PLUS les bandes de minerais de l'overworld.
	if _is_overworld:
		if terrain_id != 0 and terrain_id != _water_id:
			var depth := int(r["h"]) - wy
			if depth > SUBSURFACE_THICKNESS:
				var ore := _ore_at(wx, wy, wz, depth, terrain_id)
				if ore != 0:
					terrain_id = ore
		if terrain_id != 0 and terrain_id != _water_id and _is_cave_at(wx, wy, wz, r["h"]):
			terrain_id = 0
	var pos := Vector3i(wx, wy, wz)
	# En ville, pas d'arbre (filtré à la génération) — mais un arbre HORS
	# footprint reste possible juste à côté ; la requête ponctuelle le garde.
	for tree: Dictionary in _trees_in_window(wx, wx, wz, wz):
		if (tree["blocks"] as Dictionary).has(pos):
			return tree["blocks"][pos]
	if terrain_id == 0:
		for plant: Dictionary in _plants_in_window(wx, wx, wz, wz):
			if (plant["pos"] as Vector3i) == pos:
				return int(plant["material_id"])
	return terrain_id


## Cherche une position de spawn SUR LA TERRE FERME (2026-07-26) : avec de
## grands océans, l'origine tombe souvent sous l'eau. Spirale par anneaux depuis
## (px,pz) jusqu'à trouver un point nettement au-dessus du niveau de la mer.
func find_land_spawn(px: int = 0, pz: int = 0) -> Vector2i:
	if height_at(px, pz) > water_level + 1:
		return Vector2i(px, pz)
	var step := 96
	var max_ring := int(_land_radius / step)
	for ring in range(1, max_ring + 1):
		for i in range(-ring, ring + 1):
			for j in range(-ring, ring + 1):
				if absi(i) != ring and absi(j) != ring:
					continue  # bord de l'anneau uniquement
				var x := px + i * step
				var z := pz + j * step
				if height_at(x, z) > water_level + 2:
					return Vector2i(x, z)
	return Vector2i(px, pz)  # Monde entièrement noyé (ne devrait pas arriver).


## Arbre dont la BASE (premier bloc de tronc, au sol) est exactement à
## (wx,wy,wz), ou {} si aucun. Sert au mécanisme « casser la base abat tout
## l'arbre » — génère l'arbre complet à la demande (pur, bon marché).
func tree_at_base(wx: int, wy: int, wz: int) -> Dictionary:
	var cell_x := floori(float(wx) / TREE_CELL_SIZE)
	var cell_z := floori(float(wz) / TREE_CELL_SIZE)
	var cand := _tree_candidate_in_cell(cell_x, cell_z)
	if cand.is_empty():
		return {}
	var base: Vector3i = cand["base"]
	if base.x != wx or base.z != wz or base.y != wy:
		return {}
	return _generate_tree_cached(cand)


## ARBRE CONTENANT le bloc (wx, wy, wz), ou {} si ce bloc n'appartient à aucun
## arbre. Requête INVERSE de `tree_at_base` : on ne part plus du pied mais d'un
## bloc quelconque du feuillage ou du tronc.
##
## Elle est bon marché parce que les arbres sont DÉTERMINISTES : on ne cherche
## pas dans une liste d'entités, on régénère les quelques candidats dont
## l'empreinte peut couvrir ce bloc (fenêtre TREE_MAX_REACH, la même que celle
## du streaming) et on teste l'appartenance. Aucun état à tenir, donc rien à
## sauvegarder ni à synchroniser.
func tree_containing(wx: int, wy: int, wz: int) -> Dictionary:
	var pos := Vector3i(wx, wy, wz)
	for tree: Dictionary in _trees_in_window(wx, wx, wz, wz):
		if (tree["blocks"] as Dictionary).has(pos):
			return tree
	return {}


## Hauteur de la surface à la colonne monde (wx, wz).
func height_at(wx: int, wz: int) -> int:
	return int(floorf(_height(float(wx), float(wz))))


## Biome résolu à la colonne monde (wx, wz) — pour le HUD/la carte.
func biome_at(wx: int, wz: int) -> Dictionary:
	var fx := float(wx)
	var fz := float(wz)
	var terrain := _terrain(fx, fz)
	var alt_n := terrain.y
	var temp_n := _temperature_at(fx, fz, terrain.x)
	var hum_n := _humidity_at(fx, fz)
	var mana_n := _mana_at(fx, fz)
	var b := _biome_index_at(fx, fz, alt_n, temp_n, hum_n, mana_n)
	if b >= 0:
		return GameData.biomes.get(_biome_ids[b], {})
	return {}


## Danger/corruption normalisé (0..1) à la colonne monde (wx, wz) — 3.0/3.1.
## Dérive de la corruption (E.20, mise à jour hebdomadaire par les actes du
## joueur) différée : ceci est la valeur de BASE, avant tout ajustement.
func danger_at(wx: int, wz: int) -> float:
	return (_layers["danger"] as FastNoiseLite).get_noise_2d(float(wx), float(wz)) * 0.5 + 0.5


## Niveau de danger pour la heat-map vague (6.3 : 3 paliers lisibles).
## Seuils = interprétation (le GDD ne fixe pas les bornes exactes) : à
## calibrer avec le contenu réel une fois les créatures par danger définies.
func danger_level(wx: int, wz: int) -> int:
	var d := danger_at(wx, wz)
	if d < 0.4:
		return 0  # paisible
	if d < 0.7:
		return 1  # dangereuse
	return 2  # mortelle


## Plage verticale approchée (en chunks) pour le streaming d'une colonne :
## échantillonne 5 points, marges généreuses (les trous coûtent plus cher
## que quelques chunks enterrés en trop).
func cy_range(col: Vector2i) -> Vector2i:
	var bx := float(col.x * ChunkData.SIZE)
	var bz := float(col.y * ChunkData.SIZE)
	var h_min := 1e9
	var h_max := -1e9
	for p in [[7.5, 7.5], [0.0, 0.0], [15.0, 0.0], [0.0, 15.0], [15.0, 15.0]]:
		var h := _height(bx + p[0], bz + p[1])
		h_min = minf(h_min, h)
		h_max = maxf(h_max, h)
	# Termitière de donjon : elle monte 128 blocs au-dessus du sol, bien plus haut
	# que la marge de 16 ci-dessus. Sans cette extension, le streaming ne demande
	# jamais ses chunks supérieurs et la structure est tranchée (voir
	# tower_top_for_column).
	var tower_top := tower_top_for_column(col)
	if tower_top > 0:
		h_max = maxf(h_max, float(tower_top))
	if not _is_overworld:
		# Une île suspendue vit très au-dessus du sol : sans cette extension, le
		# streaming ne demanderait jamais ses chunks et l'île serait tranchée.
		# En bas, on s'arrête à la croûte — il n'y a rien dessous.
		var island := sky_island_at(col)
		if not island.is_empty():
			h_max = maxf(h_max, float(int(island["hauteur"]) + int(h_min)))
		return Vector2i(floori((h_min - float(_dim_crust) - 16.0) / 16.0),
				floori((h_max + 16.0) / 16.0))
	return Vector2i(floori((h_min - 48.0) / 16.0), floori((h_max + 16.0) / 16.0))

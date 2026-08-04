#!/usr/bin/env python3
"""Genere les gabarits de CORPS non humanoides, en DEUX formats chacun.

  models/creatures/<espece>.glb      -> consomme par Godot (Skeleton3D)
  models/creatures/<espece>.bbmodel  -> OUVRABLE DANS BLOCKBENCH pour editer
  models/creatures/rigs.json         -> famille, calques de couleur, zones de coup

MEME PRINCIPE QUE generate_humanoid_rig.py, et le meme code d'ecriture (importe,
pas recopie) : la geometrie EST la specification, relisible et regenerable.
Ajouter un mob se fait dans la table SPECIES ci-dessous, jamais a la main dans
un binaire.

CE QUI FAIT QU'UN NOUVEAU RIG S'ANIME SANS UNE LIGNE DE CODE. Le pilote
(scenes/entities/creature_body.gd) ne connait AUCUNE espece : il decouvre les
capacites d'un squelette par le NOMMAGE de ses os. Trois conventions, et tout
le reste est libre :

  * PATTE   : `cuisse_<sfx>` -> `mollet_<sfx>` -> `pied_<sfx>` (ou `serre_`,
              `tarse_`). Chaine de 2 os EXACTEMENT — c'est ce qui autorise le
              solveur analytique TwoBoneIK et l'ancrage sur les blocs. Le
              nombre de pattes est libre : 2, 4, 6, 8, ou une paire par
              segment. Le cote et l'ordre de l'allure sont deduits de la
              POSITION des hanches, pas du nom.
  * AILE    : `aile_<sfx>` -> `avantaile_<sfx>` -> `plume_<sfx>`, les deux
              derniers facultatifs. Autant de paires qu'on veut.
  * SOUPLE  : toute suite `<base>_1`, `<base>_2`, ... dont chaque os est parent
              du suivant (`corps_*`, `queue_*`, `cou_*`, `tentacule_*_*`,
              `antenne_*_*`). Animee en ONDE propagee, l'axe etant deduit de
              l'orientation au repos : lacet pour une colonne horizontale,
              balancement radial pour un tentacule qui pend.

Un os isole nomme `nageoire_*`, `pince_*`, `oreille_*` balance doucement.
Un squelette sans patte flotte au lieu de marcher.

CONTRAINTES QUI RESTENT VRAIES POUR TOUS

  * Les os d'une chaine IK pointent vers -Y au repos : les pattes sont donc
    dessinees VERTICALES, jamais pliees.
  * UN maillage par os, poids 1.0 : condition du demembrement (echelle de l'os
    a zero) — un cube a cheval sur deux os s'etirerait au lieu de disparaitre.
  * Pivots AUX ARTICULATIONS, jamais au centre du cube.
  * Bas du modele a y = 0, face vers -Z, 1 unite Godot = 32 px.

Usage :  python tools/generate_creature_rigs.py
Voir models/creatures/LISEZMOI.md pour la specification complete.
"""

import json
import struct
import sys
from math import cos, pi, sin
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

# Ecriture GLB/bbmodel partagee avec le gabarit humanoide : un seul encodeur,
# donc aucun risque que les deux familles de rigs divergent sur le format.
from generate_humanoid_rig import (  # noqa: E402
    ARRAY_BUFFER, ELEMENT_ARRAY_BUFFER, FLOAT, USHORT,
    PX, Buffer, build_cube, uid,
)

SIDES = [("droite", 1), ("gauche", -1)]

# --- Palettes -------------------------------------------------------------
# Quatre calques par espece (dos / ventre / pattes / detail), comme la peau
# procedurale du joueur. Couleurs FRANCHES et peu nombreuses : la recoloration
# des variantes rares se fait par echange de couleurs en shader, ce qui suppose
# des couleurs-cles nettes.
PALETTES = {
    "chat":         ((.42, .36, .32), (.78, .74, .68), (.36, .31, .28), (.90, .60, .62)),
    "loup":         ((.40, .40, .42), (.72, .70, .66), (.33, .33, .35), (.20, .18, .18)),
    "ours":         ((.33, .22, .14), (.44, .31, .20), (.24, .16, .10), (.15, .11, .08)),
    "cerf":         ((.58, .40, .24), (.82, .72, .58), (.44, .30, .18), (.88, .82, .70)),
    "sanglier":     ((.30, .26, .24), (.42, .36, .32), (.22, .19, .18), (.90, .88, .82)),
    "cheval":       ((.45, .29, .18), (.55, .38, .24), (.28, .19, .12), (.16, .12, .10)),
    "rat":          ((.44, .40, .38), (.70, .64, .60), (.38, .34, .32), (.86, .60, .58)),
    "lezard":       ((.36, .52, .28), (.74, .76, .50), (.32, .46, .26), (.88, .70, .20)),
    "crocodile":    ((.30, .38, .26), (.68, .68, .48), (.26, .33, .23), (.85, .80, .30)),
    "serpent":      ((.28, .42, .24), (.78, .75, .48), (.28, .42, .24), (.70, .18, .16)),
    "ver":          ((.72, .54, .48), (.84, .68, .62), (.72, .54, .48), (.50, .32, .30)),
    "poisson":      ((.22, .40, .55), (.82, .84, .80), (.30, .52, .62), (.90, .62, .25)),
    "requin":       ((.34, .38, .42), (.86, .86, .84), (.30, .34, .38), (.14, .14, .16)),
    "raie":         ((.36, .34, .30), (.84, .82, .76), (.36, .34, .30), (.20, .18, .16)),
    "aigle":        ((.35, .25, .17), (.80, .76, .70), (.85, .66, .20), (.92, .78, .30)),
    "chauve_souris": ((.26, .20, .20), (.42, .32, .30), (.30, .24, .24), (.68, .40, .38)),
    "raptor":       ((.48, .38, .22), (.72, .64, .44), (.40, .32, .18), (.80, .24, .18)),
    "autruche":     ((.24, .22, .22), (.86, .84, .78), (.82, .64, .34), (.90, .70, .30)),
    "araignee":     ((.18, .16, .20), (.30, .26, .30), (.16, .14, .18), (.72, .18, .20)),
    "scarabee":     ((.20, .26, .18), (.30, .36, .24), (.16, .20, .14), (.55, .70, .25)),
    "crabe":        ((.66, .26, .20), (.86, .72, .58), (.58, .22, .17), (.92, .84, .70)),
    "abeille":      ((.90, .72, .16), (.30, .26, .18), (.24, .20, .14), (.20, .18, .16)),
    "mille_pattes": ((.42, .22, .16), (.58, .34, .22), (.36, .18, .13), (.88, .74, .20)),
    "pieuvre":      ((.62, .28, .34), (.82, .60, .58), (.62, .28, .34), (.90, .84, .78)),
    "meduse":       ((.62, .58, .82), (.80, .78, .92), (.62, .58, .82), (.90, .70, .88)),
    "spectre":      ((.52, .62, .70), (.72, .82, .88), (.52, .62, .70), (.86, .94, .98)),
    "dragon":       ((.34, .20, .26), (.72, .58, .34), (.28, .16, .21), (.90, .70, .22)),
}
LAYERS = ("dos", "ventre", "pattes", "detail")

# Teinte d'onglet Blockbench par calque (0-7) — confort d'edition uniquement.
BBCOLOR = {"dos": 6, "ventre": 3, "pattes": 5, "detail": 1}


def leg_chain(bones, body, suffix, x, z, hip, knee, ankle, width, layer="pattes",
              tip="pied", parent="bassin", toe=2.2):
    """Une PATTE : chaine de 2 os exactement, dessinee verticale.

    Verticale et non pliee parce que TwoBoneIK suppose des os pointant vers -Y
    au repos ; une patte dessinee flechie donnerait une resolution decalee du
    meme angle a chaque frame."""
    bones.append(("cuisse" + suffix, parent, (x, hip, z)))
    bones.append(("mollet" + suffix, "cuisse" + suffix, (x, knee, z)))
    bones.append((tip + suffix, "mollet" + suffix, (x, ankle, z)))
    w = width / 2.0
    body.append(("mesh_cuisse" + suffix, "cuisse" + suffix,
                 (x - w * 1.2, knee - 1.0, z - w * 1.2), (x + w * 1.2, hip + 1.0, z + w * 1.2), layer))
    # Le recouvrement au genou et a la cheville evite un trou a l'articulation,
    # mais il ne doit JAMAIS descendre sous le sol : sur une patte courte
    # (chauve-souris, insecte) le demi-pixel de marge passerait sous y = 0 et
    # le modele entier serait declare enterre.
    body.append(("mesh_mollet" + suffix, "mollet" + suffix,
                 (x - w, max(0.0, ankle - 0.5), z - w), (x + w, knee + 0.5, z + w), layer))
    # L'extremite deborde vers l'AVANT (-Z) : c'est un pied, pas un cube.
    body.append(("mesh_%s%s" % (tip, suffix), tip + suffix,
                 (x - w, 0.0, z - w * toe), (x + w, ankle + 0.5, z + w), "detail"))


def soft_chain(bones, body, base, parent, count, start, step, thick, taper, layer,
               direction=(0, 0, 1), flat=None):
    """Une chaine SOUPLE `<base>_1..N` : cou, queue, corps, tentacule, nageoire.

    Ce n'est PAS une chaine IK — il n'y a pas de cible a atteindre, seulement une
    trajectoire. Le pilote la fait onduler en propageant une phase d'un segment
    au suivant, ce qui donne une onde et non un balancier rigide.

    `direction` est un axe unitaire (±X, ±Y, ±Z) : une queue part en arriere, un
    tentacule pend, une pectorale de raie s'etale sur le cote. `flat` aplatit la
    section en hauteur — une nageoire est une palette, pas un boudin."""
    for i in range(1, count + 1):
        p = parent if i == 1 else "%s_%d" % (base, i - 1)
        offset = step * (i - 1)
        pivot = tuple(start[a] + direction[a] * offset for a in range(3))
        bones.append(("%s_%d" % (base, i), p, pivot))
        t = thick * (1.0 - taper * (i - 1) / float(count))
        lo, hi = [0.0] * 3, [0.0] * 3
        for a in range(3):
            if direction[a]:
                edge = pivot[a] + direction[a] * step
                lo[a], hi[a] = min(pivot[a], edge), max(pivot[a], edge)
            else:
                half = flat if (a == 1 and flat is not None) else t
                lo[a], hi[a] = pivot[a] - half, pivot[a] + half
        body.append(("mesh_%s_%d" % (base, i), "%s_%d" % (base, i), tuple(lo), tuple(hi), layer))


def head_group(bones, body, parent, pivot, size, muzzle, ears=0.0, layer="dos"):
    """Tete + museau + oreilles, portes par l'os `tete`. Le museau et les
    oreilles sont des objets DISTINCTS sur le meme os : ils doivent pouvoir etre
    recolores a part, comme les cheveux de l'humanoide."""
    x, y, z = pivot
    bones.append(("tete", parent, pivot))
    bones.append(("attach_tete", "tete", (x, y + size * 0.55, z - size * 0.5)))
    body.append(("mesh_tete", "tete",
                 (x - size / 2, y - size * 0.45, z - size), (x + size / 2, y + size * 0.55, z), layer))
    if muzzle > 0.0:
        body.append(("mesh_museau", "tete",
                     (x - size * 0.26, y - size * 0.35, z - size - muzzle),
                     (x + size * 0.26, y + size * 0.05, z - size + 1.0), "detail"))
    if ears > 0.0:
        for side, sx in SIDES:
            body.append(("mesh_oreille_" + side, "tete",
                         (x + sx * size * 0.12, y + size * 0.55, z - size * 0.75),
                         (x + sx * (size * 0.12 + ears), y + size * 0.55 + ears,
                          z - size * 0.75 + ears * 0.7), "detail"))


# --- QUADRUPEDE ------------------------------------------------------------
# Colonne en TROIS os (deux pour l'humanoide) : croupe et poitrail sont portes
# par des pattes DIFFERENTES, ils doivent pouvoir monter et descendre
# independamment sur un terrain en escalier.
def quadruped(p):
    bones, body = [], []
    y0 = p["leg"] - 1.0
    y1 = y0 + p["bh"]
    half = p["bl"] / 2.0
    knee, ankle = p["leg"] * 0.45, p["leg"] * 0.15
    leg_w = p["bw"] * 0.28
    # `splay` ecarte les hanches hors du corps : c'est la silhouette rampante
    # d'un lezard ou d'un crocodile, obtenue sans plier la patte au repos (ce
    # qui casserait la convention IK).
    x_leg = p["bw"] / 2.0 - leg_w / 2.0 + p.get("splay", 0.0)

    bones.append(("racine", None, (0.0, 0.0, 0.0)))
    bones.append(("bassin", "racine", (0.0, y0 + p["bh"] * 0.5, half * 0.55)))
    bones.append(("colonne_1", "bassin", (0.0, y0 + p["bh"] * 0.5, 0.0)))
    bones.append(("colonne_2", "colonne_1", (0.0, y0 + p["bh"] * 0.5, -half * 0.55)))
    bones.append(("attach_dos", "colonne_1", (0.0, y1, 0.0)))
    body.append(("mesh_croupe", "bassin",
                 (-p["bw"] / 2 + 0.5, y0 + 0.5, half * 0.15), (p["bw"] / 2 - 0.5, y1 - 0.5, half), "dos"))
    body.append(("mesh_torse", "colonne_1",
                 (-p["bw"] / 2, y0, -half * 0.2), (p["bw"] / 2, y1, half * 0.2), "dos"))
    body.append(("mesh_ventre", "colonne_1",
                 (-p["bw"] / 2 + 0.5, y0 - 0.5, -half * 0.35), (p["bw"] / 2 - 0.5, y0 + 1.5, half * 0.35), "ventre"))
    body.append(("mesh_poitrail", "colonne_2",
                 (-p["bw"] / 2 + 0.5, y0 - 0.5, -half), (p["bw"] / 2 - 0.5, y1 - 0.5, -half * 0.15), "dos"))

    neck_y = y1 - p["bh"] * 0.25
    head_y = neck_y + p["head_rise"]
    head_z = -half - p["neck"]
    bones.append(("cou", "colonne_2", (0.0, neck_y, -half)))
    nw = p["bw"] * 0.3
    body.append(("mesh_cou", "cou", (-nw, neck_y - nw, head_z), (nw, neck_y + nw, -half + 1.0), "dos"))
    head_group(bones, body, "cou", (0.0, head_y, head_z), p["head"], p["muzzle"], p["ear"])
    # Bois du cerf : deux plaques verticales, un objet distinct par cote pour
    # qu'un coup puisse en trancher un seul.
    if p.get("antler", 0.0) > 0.0:
        a = p["antler"]
        for side, sx in SIDES:
            body.append(("mesh_bois_" + side, "tete",
                         (sx * p["head"] * 0.15, head_y + p["head"] * 0.5, head_z - p["head"] * 0.6),
                         (sx * (p["head"] * 0.15 + 1.5), head_y + p["head"] * 0.5 + a,
                          head_z - p["head"] * 0.6 + a * 0.8), "detail"))
    # Defenses du sanglier.
    if p.get("tusk", 0.0) > 0.0:
        for side, sx in SIDES:
            body.append(("mesh_defense_" + side, "tete",
                         (sx * p["head"] * 0.2, head_y - p["head"] * 0.3, head_z - p["head"] - p["muzzle"]),
                         (sx * (p["head"] * 0.2 + 1.2), head_y - p["head"] * 0.3 + p["tusk"],
                          head_z - p["head"] - p["muzzle"] + 1.2), "detail"))

    soft_chain(bones, body, "queue", "bassin", p["tail_n"],
               (0.0, y1 - p["bh"] * 0.2, half), p["tail_len"] / p["tail_n"],
               p["tail_th"], 0.5, "dos")

    z_of = {"avant": -half + p["bl"] * 0.17, "arriere": half - p["bl"] * 0.17}
    for position in ("avant", "arriere"):
        for side, sx in SIDES:
            leg_chain(bones, body, "_%s_%s" % (position, side), sx * x_leg, z_of[position],
                      p["leg"], knee, ankle, leg_w,
                      parent="colonne_2" if position == "avant" else "bassin")
    return bones, body


# --- BIPEDE ----------------------------------------------------------------
# Bipede DIGITIGRADE a colonne horizontale (rapace terrestre, autruche) : la
# queue fait contrepoids au buste penche en avant. Complementaire de
# l'humanoide, qui couvre deja les bipedes dresses a bras.
def biped(p):
    bones, body = [], []
    y0 = p["leg"] - 1.0
    y1 = y0 + p["bh"]
    half = p["bl"] / 2.0
    knee, ankle = p["leg"] * 0.5, p["leg"] * 0.16

    bones.append(("racine", None, (0.0, 0.0, 0.0)))
    bones.append(("bassin", "racine", (0.0, y0 + p["bh"] * 0.5, half * 0.4)))
    bones.append(("colonne_1", "bassin", (0.0, y0 + p["bh"] * 0.5, 0.0)))
    bones.append(("colonne_2", "colonne_1", (0.0, y0 + p["bh"] * 0.5, -half * 0.5)))
    bones.append(("attach_dos", "colonne_1", (0.0, y1, 0.0)))
    body.append(("mesh_croupe", "bassin",
                 (-p["bw"] / 2 + 0.5, y0 + 0.5, half * 0.1), (p["bw"] / 2 - 0.5, y1 - 0.5, half), "dos"))
    body.append(("mesh_torse", "colonne_1",
                 (-p["bw"] / 2, y0, -half * 0.15), (p["bw"] / 2, y1, half * 0.15), "dos"))
    body.append(("mesh_poitrail", "colonne_2",
                 (-p["bw"] / 2 + 0.5, y0 - 0.5, -half), (p["bw"] / 2 - 0.5, y1, -half * 0.1), "ventre"))

    neck_y = y1 - p["bh"] * 0.1
    head_z = -half - p["neck"]
    # Cou en CHAINE SOUPLE : c'est ce qui donne le mouvement de tete saccade
    # d'un oiseau coureur, sans une ligne de code specifique.
    soft_chain(bones, body, "cou", "colonne_2", p["neck_n"],
               (0.0, neck_y, -half), p["neck"] / p["neck_n"], p["bw"] * 0.18, 0.3, "ventre",
               direction=(0, 0, -1))
    head_group(bones, body, "cou_%d" % p["neck_n"], (0.0, neck_y + p["head_rise"], head_z),
               p["head"], p["muzzle"], 0.0, "ventre")
    soft_chain(bones, body, "queue", "bassin", p["tail_n"],
               (0.0, y1 - p["bh"] * 0.25, half), p["tail_len"] / p["tail_n"],
               p["tail_th"], 0.55, "dos")
    for side, sx in SIDES:
        leg_chain(bones, body, "_" + side, sx * p["bw"] * 0.3, half * 0.15,
                  p["leg"], knee, ankle, p["bw"] * 0.3, tip="serre", toe=2.6)
    return bones, body


# --- SERPENTIN -------------------------------------------------------------
def serpent(p):
    bones, body = [], []
    total = p["segments"] * p["seg_len"]
    z0 = -total / 2.0                      # nez a l'avant (-Z), queue en +Z
    r = p["thick"]
    bones.append(("racine", None, (0.0, 0.0, 0.0)))
    for i in range(1, p["segments"] + 1):
        parent = "racine" if i == 1 else "corps_%d" % (i - 1)
        z = z0 + p["seg_len"] * (i - 1)
        bones.append(("corps_%d" % i, parent, (0.0, r, z)))
        # Effile vers la queue : une epaisseur constante donnerait un tuyau.
        t = r * (1.0 - p["taper"] * (i - 1) / float(p["segments"]))
        body.append(("mesh_corps_%d" % i, "corps_%d" % i,
                     (-t, r - t, z), (t, r + t, z + p["seg_len"]),
                     "ventre" if i % 2 == 0 else "dos"))
    head_group(bones, body, "corps_1", (0.0, r, z0), p["head"], p["head"] * 0.4)
    return bones, body


# --- NAGEUR ----------------------------------------------------------------
def fish(p):
    bones, body = [], []
    total = p["segments"] * p["seg_len"]
    z0 = -total / 2.0
    # Axe du corps. C'est la CAUDALE, plus haute que le corps, qui fixe la garde
    # au sol : centrer l'axe sur le corps seul ferait passer le bas de la
    # nageoire sous y = 0, et le poisson s'enterrerait dans le fond.
    cy = max(p["body_h"], p["caudal_h"]) / 2.0
    bones.append(("racine", None, (0.0, 0.0, 0.0)))
    for i in range(1, p["segments"] + 1):
        parent = "racine" if i == 1 else "corps_%d" % (i - 1)
        z = z0 + p["seg_len"] * (i - 1)
        bones.append(("corps_%d" % i, parent, (0.0, cy, z)))
        k = 1.0 - p["taper"] * (i - 1) / float(p["segments"])
        hh, hw = p["body_h"] / 2 * k, p["body_w"] / 2 * k
        body.append(("mesh_corps_%d" % i, "corps_%d" % i,
                     (-hw, cy - hh, z), (hw, cy + hh, z + p["seg_len"]), "dos"))
    head_group(bones, body, "corps_1", (0.0, cy, z0), p["head"], p["head"] * 0.35, 0.0)

    last = "corps_%d" % p["segments"]
    z_end = z0 + total
    bones.append(("nageoire_caudale", last, (0.0, cy, z_end)))
    body.append(("mesh_nageoire_caudale", "nageoire_caudale",
                 (-0.8, cy - p["caudal_h"] / 2, z_end), (0.8, cy + p["caudal_h"] / 2, z_end + p["caudal"]), "detail"))
    if p["dorsal_h"] > 0.0:
        bones.append(("nageoire_dorsale", "corps_1", (0.0, cy + p["body_h"] / 2, z0 + p["seg_len"] * 0.8)))
        body.append(("mesh_nageoire_dorsale", "nageoire_dorsale",
                     (-0.8, cy + p["body_h"] / 2, z0 + p["seg_len"] * 0.8),
                     (0.8, cy + p["body_h"] / 2 + p["dorsal_h"], z0 + p["seg_len"] * 2.0), "dos"))
    # Pectorales : un seul os quand elles sont courtes, une CHAINE quand elles
    # sont larges (la raie nage avec, elles doivent onduler et pas battre).
    for side, sx in SIDES:
        z = z0 + p["seg_len"] * 0.9
        y = cy - p["body_h"] * 0.2
        if p.get("pect_n", 1) > 1:
            soft_chain(bones, body, "nageoire_pectorale_" + side, "corps_1",
                       p["pect_n"], (sx * p["body_w"] / 2, y, z), p["pect"] / p["pect_n"],
                       p["pect"] * 0.45, 0.55, "ventre",
                       direction=(sx, 0, 0), flat=0.8)
        else:
            bones.append(("nageoire_pectorale_" + side, "corps_1", (sx * p["body_w"] / 2, y, z)))
            body.append(("mesh_nageoire_pectorale_" + side, "nageoire_pectorale_" + side,
                         (sx * p["body_w"] / 2, y - 0.8, z),
                         (sx * (p["body_w"] / 2 + p["pect"]), y + 0.8, z + p["pect"] * 0.8), "ventre"))
    return bones, body


# --- VOLANT ----------------------------------------------------------------
# Deux systemes cohabitent et c'est voulu : les PATTES sont des chaines de 2 os
# (l'oiseau se pose, l'IK de sol s'applique comme a tout marcheur), les AILES
# sont des os libres animes en battement. Une aile en IK n'aurait aucune cible a
# atteindre — l'IK resout une position, un battement est une trajectoire.
def flyer(p):
    bones, body = [], []
    y0 = p["leg"]
    y1 = y0 + p["bh"]
    cy = (y0 + y1) / 2.0
    half = p["bl"] / 2.0
    knee, ankle = p["leg"] * 0.5, p["leg"] * 0.16

    bones.append(("racine", None, (0.0, 0.0, 0.0)))
    bones.append(("bassin", "racine", (0.0, cy, half * 0.4)))
    bones.append(("colonne_1", "bassin", (0.0, cy, 0.0)))
    bones.append(("colonne_2", "colonne_1", (0.0, cy, -half * 0.5)))
    bones.append(("attach_dos", "colonne_1", (0.0, y1, 0.0)))
    body.append(("mesh_croupe", "bassin",
                 (-p["bw"] / 2 + 1, y0 + 1, half * 0.1), (p["bw"] / 2 - 1, y1 - 1, half), "dos"))
    body.append(("mesh_torse", "colonne_1",
                 (-p["bw"] / 2, y0, -half * 0.15), (p["bw"] / 2, y1, half * 0.15), "dos"))
    body.append(("mesh_poitrail", "colonne_2",
                 (-p["bw"] / 2 + 0.5, y0 + 0.5, -half), (p["bw"] / 2 - 0.5, y1, -half * 0.1), "ventre"))

    neck_y = y1 - p["bh"] * 0.2
    head_z = -half - p["neck"]
    bones.append(("cou", "colonne_2", (0.0, neck_y, -half)))
    body.append(("mesh_cou", "cou", (-2.5, neck_y - 2.5, head_z), (2.5, neck_y + 2.5, -half + 1.0), "ventre"))
    head_group(bones, body, "cou", (0.0, neck_y + 3.0, head_z), p["head"], p["beak"],
               p.get("ear", 0.0), "ventre")

    bones.append(("queue", "bassin", (0.0, cy, half)))
    body.append(("mesh_queue", "queue",
                 (-p["bw"] / 2, cy - 0.8, half), (p["bw"] / 2, cy + 0.8, half + p["tail"]), "dos"))

    for side, sx in SIDES:
        wy = y1 - p["bh"] * 0.25
        x0 = sx * p["bw"] / 2
        x1 = x0 + sx * p["wing"]
        x2 = x1 + sx * p["forewing"]
        x3 = x2 + sx * p["feather"]
        bones.append(("aile_" + side, "colonne_1", (x0, wy, 0.0)))
        bones.append(("avantaile_" + side, "aile_" + side, (x1, wy, 0.0)))
        bones.append(("plume_" + side, "avantaile_" + side, (x2, wy, 0.0)))
        for mesh, a, b, layer in (("mesh_aile_" + side, x0, x1, "dos"),
                                  ("mesh_avantaile_" + side, x1, x2, "dos"),
                                  ("mesh_plume_" + side, x2, x3, "detail")):
            body.append((mesh, mesh[len("mesh_"):],
                         (min(a, b), wy - p["wing_h"] / 2, -half * 0.55),
                         (max(a, b), wy + p["wing_h"] / 2, half * 0.35), layer))

    for side, sx in SIDES:
        leg_chain(bones, body, "_" + side, sx * p["bw"] * 0.28, half * 0.15,
                  p["leg"], knee, ankle, 2.8, tip="serre", toe=2.5)
    return bones, body


# --- ARTHROPODE ------------------------------------------------------------
# Trois ou quatre paires de pattes, corps porte haut. RIEN de specifique cote
# code : l'allure se deduit de la position des hanches, donc passer de 6 a 8
# pattes ne demande qu'un changement de parametre ici.
def arthropod(p):
    bones, body = [], []
    hip = p["leg"]
    ty = hip - 1.0
    th = p["thorax_h"]
    bones.append(("racine", None, (0.0, 0.0, 0.0)))
    bones.append(("bassin", "racine", (0.0, ty + th * 0.5, p["abdo_l"] * 0.5)))
    bones.append(("colonne_1", "bassin", (0.0, ty + th * 0.5, -p["thorax_l"] * 0.5)))
    bones.append(("attach_dos", "bassin", (0.0, ty + th, 0.0)))
    body.append(("mesh_abdomen", "bassin",
                 (-p["abdo_w"] / 2, ty, 0.0), (p["abdo_w"] / 2, ty + p["abdo_h"], p["abdo_l"]), "dos"))
    body.append(("mesh_thorax", "colonne_1",
                 (-p["thorax_w"] / 2, ty, -p["thorax_l"]), (p["thorax_w"] / 2, ty + th, 1.0), "dos"))
    head_group(bones, body, "colonne_1", (0.0, ty + th * 0.5, -p["thorax_l"]),
               p["head"], p.get("mandible", 0.0), 0.0, "ventre")

    if p.get("antenna", 0):
        for side, sx in SIDES:
            soft_chain(bones, body, "antenne_" + side, "tete",
                       2, (sx * p["head"] * 0.3, ty + th * 0.5 + p["head"] * 0.4,
                           -p["thorax_l"] - p["head"]), p["head"] * 0.8, 0.7, 0.4, "detail",
                       direction=(0, 0, -1))
    # Pinces du crabe : os isoles, que le pilote fait balancer doucement. Les
    # riggeer en chaine IK n'aurait rien apporte — elles ne visent rien.
    if p.get("pincer", 0.0) > 0.0:
        for side, sx in SIDES:
            x = sx * (p["thorax_w"] / 2)
            bones.append(("pince_" + side, "colonne_1", (x, ty + th * 0.3, -p["thorax_l"])))
            body.append(("mesh_pince_" + side, "pince_" + side,
                         (min(x, x + sx * p["pincer"] * 0.6), ty + th * 0.3 - p["pincer"] * 0.3,
                          -p["thorax_l"] - p["pincer"]),
                         (max(x, x + sx * p["pincer"] * 0.6), ty + th * 0.3 + p["pincer"] * 0.3,
                          -p["thorax_l"]), "detail"))

    knee, ankle = hip * 0.55, hip * 0.18
    for i in range(p["pairs"]):
        z = -p["thorax_l"] + p["thorax_l"] * (i + 0.5) / p["pairs"]
        for side, sx in SIDES:
            leg_chain(bones, body, "_%d_%s" % (i + 1, side),
                      sx * (p["thorax_w"] / 2 + p["leg_out"]), z,
                      hip, knee, ankle, p["leg_w"], parent="colonne_1", toe=1.6)

    # Deux paires d'ailes pour les insectes volants. Elles se plient en un seul
    # os supplementaire : une aile d'insecte n'a pas de coude visible.
    if p.get("wing_pairs", 0):
        for position, zw in (("avant", -p["thorax_l"] * 0.3), ("arriere", p["abdo_l"] * 0.1)):
            for side, sx in SIDES:
                x0 = sx * p["thorax_w"] / 2
                x1 = x0 + sx * p["wing"] * 0.5
                x2 = x0 + sx * p["wing"]
                wy = ty + th
                bones.append(("aile_%s_%s" % (position, side), "colonne_1", (x0, wy, zw)))
                bones.append(("plume_%s_%s" % (position, side), "aile_%s_%s" % (position, side), (x1, wy, zw)))
                body.append(("mesh_aile_%s_%s" % (position, side), "aile_%s_%s" % (position, side),
                             (min(x0, x1), wy - 0.4, zw - p["wing"] * 0.2),
                             (max(x0, x1), wy + 0.4, zw + p["wing"] * 0.2), "ventre"))
                body.append(("mesh_plume_%s_%s" % (position, side), "plume_%s_%s" % (position, side),
                             (min(x1, x2), wy - 0.4, zw - p["wing"] * 0.18),
                             (max(x1, x2), wy + 0.4, zw + p["wing"] * 0.18), "ventre"))
    return bones, body


# --- SEGMENTE --------------------------------------------------------------
# Mille-pattes : colonne ondulante ET une paire de pattes par segment. C'est le
# cas qui prouve que les deux systemes se composent — l'onde du corps et
# l'allure des pattes tournent en meme temps sans se connaitre.
def segmented(p):
    bones, body = [], []
    total = p["segments"] * p["seg_len"]
    z0 = -total / 2.0
    hip = p["leg"]
    cy = hip + p["thick"]
    knee, ankle = hip * 0.5, hip * 0.2
    bones.append(("racine", None, (0.0, 0.0, 0.0)))
    for i in range(1, p["segments"] + 1):
        parent = "racine" if i == 1 else "corps_%d" % (i - 1)
        z = z0 + p["seg_len"] * (i - 1)
        bones.append(("corps_%d" % i, parent, (0.0, cy, z)))
        t = p["thick"] * (1.0 - 0.35 * (i - 1) / float(p["segments"]))
        body.append(("mesh_corps_%d" % i, "corps_%d" % i,
                     (-t, cy - t, z), (t, cy + t, z + p["seg_len"] * 0.92),
                     "dos" if i % 2 else "ventre"))
        for side, sx in SIDES:
            leg_chain(bones, body, "_%d_%s" % (i, side), sx * (t + p["leg_out"]),
                      z + p["seg_len"] * 0.4, hip, knee, ankle, p["leg_w"],
                      parent="corps_%d" % i, toe=1.4)
    head_group(bones, body, "corps_1", (0.0, cy, z0), p["head"], p["head"] * 0.35, 0.0)
    for side, sx in SIDES:
        soft_chain(bones, body, "antenne_" + side, "tete", 2,
                   (sx * p["head"] * 0.3, cy + p["head"] * 0.3, z0 - p["head"]),
                   p["head"] * 0.7, 0.5, 0.4, "detail", direction=(0, 0, -1))
    return bones, body


# --- TENTACULAIRE / FLOTTANT ----------------------------------------------
# Corps porte en hauteur, aucune patte : le pilote le fait planer au lieu de
# marcher (c'est la seule consequence de l'absence de chaine `cuisse_*`). Les
# bras pendent en chaines souples et ondulent radialement.
def tentacular(p):
    bones, body = [], []
    arm_len = p["segs"] * p["seg_len"]
    by = arm_len
    bones.append(("racine", None, (0.0, 0.0, 0.0)))
    bones.append(("corps", "racine", (0.0, by, 0.0)))
    bones.append(("attach_dos", "corps", (0.0, by + p["bell_h"], 0.0)))
    bones.append(("attach_tete", "corps", (0.0, by + p["bell_h"] * 0.6, -p["bell_w"] * 0.4)))
    body.append(("mesh_cloche", "corps",
                 (-p["bell_w"] / 2, by, -p["bell_w"] / 2),
                 (p["bell_w"] / 2, by + p["bell_h"], p["bell_w"] / 2), "dos"))
    if p.get("dome", 0.0) > 0.0:
        body.append(("mesh_dome", "corps",
                     (-p["bell_w"] * 0.34, by + p["bell_h"], -p["bell_w"] * 0.34),
                     (p["bell_w"] * 0.34, by + p["bell_h"] + p["dome"], p["bell_w"] * 0.34), "ventre"))
    if p.get("eye", 0.0) > 0.0:
        body.append(("mesh_oeil", "corps",
                     (-p["eye"] / 2, by + p["bell_h"] * 0.35, -p["bell_w"] / 2 - p["eye"] * 0.4),
                     (p["eye"] / 2, by + p["bell_h"] * 0.35 + p["eye"], -p["bell_w"] / 2 + 0.5), "detail"))
    radius = p["bell_w"] * 0.34
    for i in range(p["arms"]):
        angle = 2.0 * pi * i / p["arms"]
        x, z = radius * cos(angle), radius * sin(angle)
        soft_chain(bones, body, "tentacule_%d" % (i + 1), "corps", p["segs"],
                   (x, by, z), p["seg_len"], p["thick"], 0.6,
                   "ventre" if i % 2 else "dos", direction=(0, -1, 0))
    return bones, body


# --- DRACONIQUE ------------------------------------------------------------
# La composition de tout le reste : quatre pattes IK, deux ailes battantes, un
# cou et une queue ondulants. Aucun code ne lui est propre — c'est la meilleure
# preuve que le pilote est bien generique.
def dragon(p):
    bones, body = [], []
    y0 = p["leg"] - 1.0
    y1 = y0 + p["bh"]
    half = p["bl"] / 2.0
    knee, ankle = p["leg"] * 0.45, p["leg"] * 0.15
    leg_w = p["bw"] * 0.26
    x_leg = p["bw"] / 2.0 - leg_w / 2.0

    bones.append(("racine", None, (0.0, 0.0, 0.0)))
    bones.append(("bassin", "racine", (0.0, y0 + p["bh"] * 0.5, half * 0.55)))
    bones.append(("colonne_1", "bassin", (0.0, y0 + p["bh"] * 0.5, 0.0)))
    bones.append(("colonne_2", "colonne_1", (0.0, y0 + p["bh"] * 0.5, -half * 0.55)))
    bones.append(("attach_dos", "colonne_1", (0.0, y1, 0.0)))
    body.append(("mesh_croupe", "bassin",
                 (-p["bw"] / 2 + 1, y0 + 1, half * 0.15), (p["bw"] / 2 - 1, y1 - 1, half), "dos"))
    body.append(("mesh_torse", "colonne_1",
                 (-p["bw"] / 2, y0, -half * 0.2), (p["bw"] / 2, y1, half * 0.2), "dos"))
    body.append(("mesh_ventre", "colonne_1",
                 (-p["bw"] / 2 + 1, y0 - 0.5, -half * 0.35), (p["bw"] / 2 - 1, y0 + 2.0, half * 0.35), "ventre"))
    body.append(("mesh_poitrail", "colonne_2",
                 (-p["bw"] / 2 + 1, y0 - 0.5, -half), (p["bw"] / 2 - 1, y1 - 1, -half * 0.15), "dos"))

    neck_y = y1 - p["bh"] * 0.2
    soft_chain(bones, body, "cou", "colonne_2", p["neck_n"],
               (0.0, neck_y, -half), p["neck"] / p["neck_n"], p["bw"] * 0.2, 0.35, "dos",
               direction=(0, 0, -1))
    head_z = -half - p["neck"]
    head_group(bones, body, "cou_%d" % p["neck_n"], (0.0, neck_y + p["head_rise"], head_z),
               p["head"], p["muzzle"], 0.0)
    for side, sx in SIDES:
        body.append(("mesh_corne_" + side, "tete",
                     (sx * p["head"] * 0.2, neck_y + p["head_rise"] + p["head"] * 0.45, head_z - p["head"] * 0.4),
                     (sx * (p["head"] * 0.2 + 1.6), neck_y + p["head_rise"] + p["head"] * 0.45 + p["horn"],
                      head_z - p["head"] * 0.4 + p["horn"] * 0.5), "detail"))
    soft_chain(bones, body, "queue", "bassin", p["tail_n"],
               (0.0, y1 - p["bh"] * 0.25, half), p["tail_len"] / p["tail_n"],
               p["tail_th"], 0.7, "dos")

    for side, sx in SIDES:
        wy = y1 - p["bh"] * 0.1
        x0 = sx * p["bw"] / 2
        x1 = x0 + sx * p["wing"]
        x2 = x1 + sx * p["forewing"]
        x3 = x2 + sx * p["membrane"]
        bones.append(("aile_" + side, "colonne_1", (x0, wy, 0.0)))
        bones.append(("avantaile_" + side, "aile_" + side, (x1, wy, 0.0)))
        bones.append(("plume_" + side, "avantaile_" + side, (x2, wy, 0.0)))
        for mesh, a, b, layer in (("mesh_aile_" + side, x0, x1, "dos"),
                                  ("mesh_avantaile_" + side, x1, x2, "dos"),
                                  ("mesh_plume_" + side, x2, x3, "ventre")):
            body.append((mesh, mesh[len("mesh_"):],
                         (min(a, b), wy - 1.0, -half * 0.6), (max(a, b), wy + 1.0, half * 0.5), layer))

    z_of = {"avant": -half + p["bl"] * 0.2, "arriere": half - p["bl"] * 0.2}
    for position in ("avant", "arriere"):
        for side, sx in SIDES:
            leg_chain(bones, body, "_%s_%s" % (position, side), sx * x_leg, z_of[position],
                      p["leg"], knee, ankle, leg_w,
                      parent="colonne_2" if position == "avant" else "bassin")
    return bones, body


# --- Catalogue des especes -------------------------------------------------
# UNE LIGNE PAR MOB. Dupliquer une ligne et changer trois nombres suffit a
# creer une espece de plus : ni geometrie a dessiner, ni code a ecrire.
SPECIES = {
    # --- quadrupedes ---
    "chat": ("quadrupede", quadruped, dict(
        leg=9, bh=6, bw=6, bl=16, neck=2.5, head=6, muzzle=2, ear=2.5,
        tail_n=3, tail_len=9, tail_th=1.6, head_rise=2)),
    "loup": ("quadrupede", quadruped, dict(
        leg=15, bh=11, bw=10, bl=26, neck=4.5, head=9, muzzle=5, ear=3.5,
        tail_n=3, tail_len=11, tail_th=3, head_rise=2.5)),
    # L'ours porte sa tete BAS (head_rise negatif) : c'est sa silhouette, et
    # c'est aussi ce qui met son crane a portee d'arme sans viser en l'air.
    "ours": ("quadrupede", quadruped, dict(
        leg=17, bh=17, bw=16, bl=38, neck=5, head=13, muzzle=5, ear=4,
        tail_n=1, tail_len=4, tail_th=3.5, head_rise=-1)),
    "cerf": ("quadrupede", quadruped, dict(
        leg=19, bh=11, bw=9, bl=28, neck=8, head=8, muzzle=4, ear=4,
        tail_n=1, tail_len=4, tail_th=2, head_rise=7, antler=9)),
    "sanglier": ("quadrupede", quadruped, dict(
        leg=10, bh=12, bw=11, bl=26, neck=2, head=10, muzzle=6, ear=3,
        tail_n=1, tail_len=4, tail_th=1.5, head_rise=-2, tusk=3)),
    "cheval": ("quadrupede", quadruped, dict(
        leg=22, bh=13, bw=11, bl=34, neck=9, head=9, muzzle=6, ear=3.5,
        tail_n=3, tail_len=14, tail_th=2.5, head_rise=8)),
    "rat": ("quadrupede", quadruped, dict(
        leg=4, bh=4, bw=4, bl=10, neck=1.5, head=4, muzzle=2.5, ear=2.5,
        tail_n=3, tail_len=10, tail_th=0.8, head_rise=0.5)),
    # `splay` ecarte les hanches : silhouette rampante, sans plier la patte au
    # repos (ce qui casserait la convention IK).
    "lezard": ("quadrupede", quadruped, dict(
        leg=4, bh=5, bw=6, bl=16, neck=2, head=5, muzzle=3, ear=0,
        tail_n=4, tail_len=16, tail_th=1.6, head_rise=0, splay=2.5)),
    "crocodile": ("quadrupede", quadruped, dict(
        leg=6, bh=8, bw=12, bl=34, neck=2, head=9, muzzle=11, ear=0,
        tail_n=4, tail_len=26, tail_th=3.5, head_rise=-1, splay=4)),

    # --- serpentins ---
    "serpent": ("serpentin", serpent, dict(segments=10, seg_len=6, thick=3.2, head=5, taper=0.55)),
    "ver": ("serpentin", serpent, dict(segments=6, seg_len=5, thick=3.6, head=4, taper=0.3)),

    # --- nageurs ---
    "poisson": ("nageur", fish, dict(segments=4, seg_len=6, body_h=6, body_w=4, head=6,
                                     caudal=6, caudal_h=8, dorsal_h=4, pect=4, taper=0.62)),
    "requin": ("nageur", fish, dict(segments=5, seg_len=11, body_h=11, body_w=8, head=11,
                                    caudal=10, caudal_h=14, dorsal_h=9, pect=9, taper=0.68)),
    # La raie nage AVEC ses pectorales : elles sont donc des chaines souples
    # (elles ondulent) et non des palettes rigides.
    # Corps PLAT : la tete doit rester plus basse que le demi-corps, sinon le
    # museau passe sous le ventre et le modele est declare enterre.
    "raie": ("nageur", fish, dict(segments=3, seg_len=7, body_h=5, body_w=10, head=4,
                                  caudal=2, caudal_h=2, dorsal_h=0, pect=14, pect_n=3, taper=0.5)),

    # --- volants ---
    "aigle": ("volant", flyer, dict(leg=8, bh=9, bw=8, bl=16, neck=4, head=6, beak=3.5,
                                    wing=13, forewing=13, feather=7, wing_h=2, tail=10)),
    "chauve_souris": ("volant", flyer, dict(leg=3, bh=6, bw=5, bl=9, neck=1.5, head=4, beak=1.5,
                                            wing=8, forewing=8, feather=6, wing_h=1.2, tail=3, ear=3)),

    # --- bipedes ---
    "raptor": ("bipede", biped, dict(leg=13, bh=8, bw=7, bl=20, neck=6, neck_n=2, head=7,
                                     muzzle=4, head_rise=5, tail_n=4, tail_len=20, tail_th=2.5)),
    "autruche": ("bipede", biped, dict(leg=20, bh=11, bw=9, bl=16, neck=16, neck_n=3, head=5,
                                       muzzle=3, head_rise=10, tail_n=1, tail_len=6, tail_th=3)),

    # --- arthropodes ---
    "araignee": ("arthropode", arthropod, dict(
        pairs=4, leg=9, leg_w=2, leg_out=3, thorax_l=8, thorax_w=7, thorax_h=5,
        abdo_l=10, abdo_w=9, abdo_h=8, head=4, mandible=2)),
    "scarabee": ("arthropode", arthropod, dict(
        pairs=3, leg=5, leg_w=1.6, leg_out=2, thorax_l=6, thorax_w=6, thorax_h=4,
        abdo_l=9, abdo_w=8, abdo_h=6, head=3.5, mandible=2, antenna=1)),
    "crabe": ("arthropode", arthropod, dict(
        pairs=4, leg=6, leg_w=1.6, leg_out=4, thorax_l=9, thorax_w=12, thorax_h=5,
        abdo_l=3, abdo_w=8, abdo_h=4, head=3, mandible=1, pincer=6)),
    "abeille": ("insecte_volant", arthropod, dict(
        pairs=3, leg=3, leg_w=1.2, leg_out=1.5, thorax_l=5, thorax_w=5, thorax_h=5,
        abdo_l=8, abdo_w=5, abdo_h=5, head=4, mandible=1.5, antenna=1,
        wing_pairs=2, wing=9)),

    # --- segmente ---
    "mille_pattes": ("segmente", segmented, dict(
        segments=8, seg_len=5, thick=2.6, leg=3, leg_w=1.2, leg_out=1.0, head=4)),

    # --- tentaculaires et flottants ---
    "pieuvre": ("tentaculaire", tentacular, dict(
        bell_w=12, bell_h=9, dome=3, arms=8, segs=4, seg_len=4, thick=1.6, eye=2)),
    "meduse": ("flottant", tentacular, dict(
        bell_w=10, bell_h=5, dome=4, arms=6, segs=5, seg_len=5, thick=1.0)),
    "spectre": ("flottant", tentacular, dict(
        bell_w=9, bell_h=11, dome=0, arms=3, segs=3, seg_len=4, thick=1.4, eye=3)),

    # --- draconique ---
    "dragon": ("draconique", dragon, dict(
        leg=16, bh=14, bw=13, bl=34, neck=18, neck_n=3, head=10, muzzle=7, horn=6,
        head_rise=10, tail_n=5, tail_len=34, tail_th=4,
        wing=14, forewing=14, membrane=10)),
}


# --- Zones de coup ---------------------------------------------------------
# CALCULEES SUR LA GEOMETRIE, jamais saisies a la main. Une boite tapee a la
# main pour vingt-sept especes serait fausse quelque part, et surtout elle
# cesserait d'etre vraie a la premiere retouche de proportion. Ici, changer un
# parametre deplace le modele ET sa hitbox du meme geste.
HEAD_PARTS = ("tete", "museau", "oreille", "bec", "mandibule", "bois", "defense", "corne", "oeil")
LIMB_PREFIX = {
    "cuisse": "pattes", "mollet": "pattes", "pied": "pattes", "serre": "pattes", "tarse": "pattes",
    "aile": "ailes", "avantaile": "ailes", "plume": "ailes",
    "tentacule": "tentacules", "nageoire": "nageoires", "pince": "pinces", "antenne": "antennes",
}
## Multiplicateur de degats par zone. La tete recompense la visee ; les
## appendices, faciles a toucher et peu vitaux, la punissent.
ZONE_MULT = {"tete": 2.0, "corps": 1.0, "pattes": 0.6, "ailes": 0.5,
             "tentacules": 0.5, "nageoires": 0.4, "pinces": 0.6, "antennes": 0.3}


def hitboxes(family, body):
    """Zones de coup en espace LOCAL (blocs, y = 0 au bas du modele).

    L'ORDRE COMPTE : le balayage d'arme retient la PREMIERE boite touchee, donc
    les zones specifiques (tete) passent avant les larges (corps)."""
    groups = {}
    for mesh, bone, lo, hi, _ in body:
        short = mesh[len("mesh_"):]
        zone = "corps"
        if bone == "tete" or short.startswith(HEAD_PARTS):
            zone = "tete"
        else:
            for prefix, name in LIMB_PREFIX.items():
                if short.startswith(prefix):
                    zone = name
                    break
        box = groups.setdefault(zone, [[1e9] * 3, [-1e9] * 3])
        for i in range(3):
            box[0][i] = min(box[0][i], lo[i], hi[i])
            box[1][i] = max(box[1][i], lo[i], hi[i])

    zones = []
    order = ["tete"] + [z for z in ZONE_MULT if z not in ("tete", "corps")] + ["corps"]
    for zone in order:
        if zone not in groups:
            continue
        lo, hi = groups[zone]
        size = [round((hi[i] - lo[i]) / PX, 3) for i in range(3)]
        if min(size) <= 0.0:
            continue
        mult = ZONE_MULT[zone]
        # Un serpent n'a presque QUE de la tete a viser : la recompenser
        # davantage est ce qui rend le duel lisible.
        if zone == "tete" and family in ("serpentin", "nageur"):
            mult = 2.5
        zones.append({
            "id": zone,
            "min": [round(lo[i] / PX, 3) for i in range(3)],
            "size": size,
            "mult": mult,
        })
    return zones


# --- Verification avant ecriture ------------------------------------------
def check(family, bones, body):
    """Verifie ce que l'oeil ne verra pas : un os orphelin, une chaine IK a
    trois maillons, un modele qui flotte. Un rig invalide ne doit pas atteindre
    le disque — sinon on ne le decouvre qu'au moment ou l'IK disloque une patte
    en jeu."""
    problems = []
    names = [n for n, _, _ in bones]
    if len(names) != len(set(names)):
        problems.append("os en double")
    known = set(names)
    parent_of = {n: p for n, p, _ in bones}
    for n, parent, _ in bones:
        if parent is not None and parent not in known:
            problems.append("os « %s » : parent « %s » inconnu" % (n, parent))
    mesh_names = [m for m, _, _, _, _ in body]
    if len(mesh_names) != len(set(mesh_names)):
        problems.append("maillages en double")
    for m, bone, _, _, _ in body:
        if bone not in known:
            problems.append("maillage « %s » : os « %s » inconnu" % (m, bone))

    # Chaines IK : 2 os EXACTEMENT, quel que soit le nombre de pattes.
    legs = 0
    for root in names:
        if not root.startswith("cuisse"):
            continue
        suffix = root[len("cuisse"):]
        mid = "mollet" + suffix
        tips = [t + suffix for t in ("pied", "serre", "tarse")]
        tip = next((t for t in tips if t in known), None)
        if mid not in known or tip is None:
            problems.append("patte « %s » incomplete" % root)
            continue
        if parent_of.get(mid) != root or parent_of.get(tip) != mid:
            problems.append("chaine IK cassee : %s -> %s -> %s" % (root, mid, tip))
        legs += 1

    # Chaines souples : chaque maillon doit etre parent du suivant, sinon
    # l'onde se propagerait sur des os independants et ne se verrait pas.
    chains = {}
    for n in names:
        base, _, index = n.rpartition("_")
        if base and index.isdigit():
            chains.setdefault(base, []).append(int(index))
    for base, indices in chains.items():
        for i in sorted(indices)[1:]:
            if parent_of.get("%s_%d" % (base, i)) != "%s_%d" % (base, i - 1):
                problems.append("chaine souple « %s » rompue au maillon %d" % (base, i))

    if "attach_tete" not in known:
        problems.append("os d'attache « attach_tete » absent")
    low = min(min(lo[1], hi[1]) for _, _, lo, hi, _ in body)
    if abs(low) > 0.01:
        problems.append("le bas du modele est a y=%.2f px (attendu 0)" % low)
    high = max(max(lo[1], hi[1]) for _, _, lo, hi, _ in body) / PX
    if high > 2.0:
        problems.append("hauteur %.2f u > 2.0 (le mob traverserait les plafonds)" % high)
    expected = {"quadrupede": 4, "draconique": 4, "volant": 2, "bipede": 2,
                "serpentin": 0, "nageur": 0, "tentaculaire": 0, "flottant": 0}
    if family in expected and legs != expected[family]:
        problems.append("%d patte(s) pour une famille « %s » (attendu %d)" % (
            legs, family, expected[family]))
    return problems


# --- Ecriture --------------------------------------------------------------
def write_bbmodel(path, name, bones, body):
    """Projet Blockbench natif : les GROUPES de l'outliner SONT les os, et leur
    `origin` est le pivot — meme information que les noeuds du glTF, dans le
    format que Blockbench sait rouvrir (il n'importe pas le glTF)."""
    pivot_of = {n: p for n, _, p in bones}
    bone_of = {m: b for m, b, _, _, _ in body}
    layer_of = {m: k for m, _, _, _, k in body}

    elements = []
    for mesh, _, lo, hi, _ in body:
        # Blockbench veut from <= to sur chaque axe (les cotes gauches sont
        # construits avec un signe negatif, donc parfois inverses).
        a = [min(lo[i], hi[i]) for i in range(3)]
        b = [max(lo[i], hi[i]) for i in range(3)]
        elements.append({
            "name": mesh,
            "box_uv": False, "rescale": False, "locked": False,
            "from": a, "to": b,
            "autouv": 0, "color": BBCOLOR[layer_of[mesh]],
            # Pivot du cube = pivot de SON os : une rotation manuelle dans
            # Blockbench se comporte alors comme la rotation en jeu.
            "origin": list(pivot_of[bone_of[mesh]]),
            "faces": {f: {"uv": [0, 0, 16, 16], "texture": None} for f in
                      ("north", "east", "south", "west", "up", "down")},
            "uuid": uid("%s:element:%s" % (name, mesh)),
        })

    children_of = {n: [] for n, _, _ in bones}
    for n, parent, _ in bones:
        if parent is not None:
            children_of[parent].append(n)

    def group(bone_name):
        kids = [uid("%s:element:%s" % (name, m)) for m, b, _, _, _ in body if b == bone_name]
        kids += [group(c) for c in children_of[bone_name]]
        return {
            "name": bone_name, "origin": list(pivot_of[bone_name]), "color": 0,
            "uuid": uid("%s:group:%s" % (name, bone_name)),
            "export": True, "mirror_uv": False, "isOpen": True,
            "visibility": True, "autouv": 0, "children": kids,
        }

    model = {
        "meta": {
            # « free » = Generic Model : le SEUL format Blockbench qui exporte
            # un squelette. Java Block/Item n'en exporte aucun.
            "format_version": "4.5", "model_format": "free", "box_uv": False,
        },
        "name": name, "model_identifier": name,
        "resolution": {"width": 64, "height": 64},
        "elements": elements,
        "outliner": [group("racine")],
        "textures": [],
    }
    path.write_text(json.dumps(model, indent=2), encoding="utf-8")


def write_glb(path, name, bones, body, palette):
    bone_index = {n: i for i, (n, _, _) in enumerate(bones)}
    pivot_of = {n: p for n, _, p in bones}
    buf = Buffer()

    nodes = []
    for n, parent, pivot in bones:
        if parent is None:
            local = pivot
        else:
            q = pivot_of[parent]
            local = (pivot[0] - q[0], pivot[1] - q[1], pivot[2] - q[2])
        nodes.append({"name": n,
                      "translation": [local[0] / PX, local[1] / PX, local[2] / PX],
                      "children": []})
    for n, parent, _ in bones:
        if parent is not None:
            nodes[bone_index[parent]]["children"].append(bone_index[n])

    # Matrices de liaison inverse : les sommets sont ecrits en espace de REPOS,
    # l'IBM est donc la simple translation inverse du pivot.
    ibm = bytearray()
    for _, _, pivot in bones:
        ibm += struct.pack("<16f", 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0,
                           -pivot[0] / PX, -pivot[1] / PX, -pivot[2] / PX, 1)
    ibm_accessor = buf.add(bytes(ibm), None, len(bones), "MAT4", FLOAT, None)

    meshes, mesh_nodes = [], []
    for mesh, bone, lo, hi, layer in body:
        a = tuple(min(lo[i], hi[i]) for i in range(3))
        b = tuple(max(lo[i], hi[i]) for i in range(3))
        pos, nrm, col, jnt, wgt, idx = build_cube(a, b, palette[layer], bone_index[bone])
        p_acc = buf.add(b"".join(struct.pack("<3f", *v) for v in pos), None, len(pos), "VEC3",
                        FLOAT, ARRAY_BUFFER,
                        minmax=([min(v[i] for v in pos) for i in range(3)],
                                [max(v[i] for v in pos) for i in range(3)]))
        n_acc = buf.add(b"".join(struct.pack("<3f", *map(float, v)) for v in nrm), None, len(nrm),
                        "VEC3", FLOAT, ARRAY_BUFFER)
        c_acc = buf.add(b"".join(struct.pack("<4f", *v) for v in col), None, len(col), "VEC4",
                        FLOAT, ARRAY_BUFFER)
        j_acc = buf.add(b"".join(struct.pack("<4H", *v) for v in jnt), None, len(jnt), "VEC4",
                        USHORT, ARRAY_BUFFER)
        w_acc = buf.add(b"".join(struct.pack("<4f", *v) for v in wgt), None, len(wgt), "VEC4",
                        FLOAT, ARRAY_BUFFER)
        i_acc = buf.add(b"".join(struct.pack("<H", v) for v in idx), None, len(idx), "SCALAR",
                        USHORT, ELEMENT_ARRAY_BUFFER)
        meshes.append({"name": mesh, "primitives": [{
            "attributes": {"POSITION": p_acc, "NORMAL": n_acc, "COLOR_0": c_acc,
                           "JOINTS_0": j_acc, "WEIGHTS_0": w_acc},
            "indices": i_acc, "material": 0}]})
        # Un noeud skinne ne doit PAS etre enfant d'un joint et sa transforme est
        # ignoree (glTF 2.0, section skins) : racine de scene, identite.
        nodes.append({"name": mesh, "mesh": len(meshes) - 1, "skin": 0})
        mesh_nodes.append(len(nodes) - 1)

    gltf = {
        "asset": {"version": "2.0", "generator": "Voxen generate_creature_rigs.py"},
        "scene": 0,
        "scenes": [{"name": name, "nodes": [0] + mesh_nodes}],
        "nodes": nodes, "meshes": meshes,
        "skins": [{"name": "squelette", "inverseBindMatrices": ibm_accessor,
                   "skeleton": 0, "joints": list(range(len(bones)))}],
        "materials": [{"name": name, "pbrMetallicRoughness": {
            "baseColorFactor": [1.0, 1.0, 1.0, 1.0],
            "metallicFactor": 0.0, "roughnessFactor": 1.0}}],
        "accessors": buf.accessors, "bufferViews": buf.views,
        "buffers": [{"byteLength": len(buf.data)}],
    }

    json_chunk = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    json_chunk += b" " * ((4 - len(json_chunk) % 4) % 4)
    bin_chunk = bytes(buf.data)
    bin_chunk += b"\x00" * ((4 - len(bin_chunk) % 4) % 4)
    total = 12 + 8 + len(json_chunk) + 8 + len(bin_chunk)
    glb = struct.pack("<III", 0x46546C67, 2, total)
    glb += struct.pack("<II", len(json_chunk), 0x4E4F534A) + json_chunk
    glb += struct.pack("<II", len(bin_chunk), 0x004E4942) + bin_chunk
    path.write_bytes(glb)
    return len(glb)


def main():
    root = Path(__file__).resolve().parent.parent
    out = root / "models" / "creatures"
    out.mkdir(parents=True, exist_ok=True)
    failed = False
    manifest = {}
    for name in sorted(SPECIES):
        family, build, params = SPECIES[name]
        bones, body = build(params)
        problems = check(family, bones, body)
        if problems:
            failed = True
            print("ECHEC %s :" % name)
            for p in problems:
                print("   - " + p)
            continue
        palette = dict(zip(LAYERS, PALETTES[name]))
        write_bbmodel(out / (name + ".bbmodel"), name, bones, body)
        size = write_glb(out / (name + ".glb"), name, bones, body, palette)
        # MANIFESTE. Godot ne reprend pas les couleurs par sommet du .glb (le
        # corps sortirait blanc) : la teinte est reappliquee en jeu par une peau
        # procedurale, qui doit donc savoir quel maillage porte quel calque.
        # Les zones de coup y sont jointes pour la meme raison : elles sont
        # DERIVEES de cette geometrie, elles ne peuvent pas vivre ailleurs sans
        # se desynchroniser a la premiere retouche.
        manifest[name] = {
            "famille": family,
            "palette": {k: list(v) for k, v in palette.items()},
            "calques": {m: layer for m, _, _, _, layer in body},
            "hitboxes": hitboxes(family, body),
        }
        height = max(max(lo[1], hi[1]) for _, _, lo, hi, _ in body) / PX
        length = (max(max(lo[2], hi[2]) for _, _, lo, hi, _ in body)
                  - min(min(lo[2], hi[2]) for _, _, lo, hi, _ in body)) / PX
        width = (max(max(lo[0], hi[0]) for _, _, lo, hi, _ in body)
                 - min(min(lo[0], hi[0]) for _, _, lo, hi, _ in body)) / PX
        print("%-13s %-15s %2d os · %2d maillages · H %.2f L %.2f l %.2f · %2d zone(s) · %d o" % (
            name, family, len(bones), len(body), height, length, width,
            len(manifest[name]["hitboxes"]), size))
    (out / "rigs.json").write_text(json.dumps({
        "_comment": "Genere par tools/generate_creature_rigs.py — NE PAS EDITER A LA MAIN. "
                    "Famille de rig, calques de couleur et zones de coup de chaque modele, "
                    "lus par scenes/entities/creature_body.gd et creature.gd.",
        "especes": manifest,
    }, indent=2, ensure_ascii=False), encoding="utf-8")
    print("\n%d espece(s) — models/creatures/rigs.json ecrit." % len(manifest))
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())

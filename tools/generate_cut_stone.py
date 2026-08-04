#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Génère une variante PIERRE TAILLÉE pour chaque roche du catalogue.

POURQUOI UN SCRIPT. Le catalogue compte 28 roches ; à la main, cela ferait 28
fichiers de matériau, 28 recettes et 112 lignes de traduction à recopier, avec
la garantie statistique d'une coquille quelque part. Le script dérive tout de
la roche source (couleur, dureté, densité), ce qui garantit aussi que la
variante taillée RESSEMBLE à sa roche : le granit taillé reste rosé, l'ardoise
taillée reste bleu-gris. C'est ce qui donne son intérêt à la demande — sans ça
une seule « pierre taillée » grise suffisait, et elle existait déjà.

IDEMPOTENT : relancer le script réécrit les mêmes fichiers et ne duplique
aucune ligne de traduction. À relancer après tout ajout de roche.

Usage :  python tools/generate_cut_stone.py
"""

import json
import glob
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROCK_DIR = os.path.join(ROOT, "data", "materials", "roche")
OUT_DIR = os.path.join(ROOT, "data", "materials", "construction")
TRANSFORM_DIR = os.path.join(ROOT, "data", "transformations")
LOCALE_DIR = os.path.join(ROOT, "locale")

# Base des `seed_offset` des variantes taillées. Choisie au-dessus de tout ce
# qu'utilise le catalogue actuel (max observé ~7100) : deux matériaux qui
# partagent un offset partagent leur grain de texture, ce qui rendrait deux
# roches taillées indiscernables — précisément ce qu'on cherche à éviter ici.
SEED_BASE = 7200

# GENRE GRAMMATICAL FRANÇAIS, à la main et assumé : « ardoise taillée » mais
# « granit taillé ». Aucune règle mécanique ne le devine (ni la terminaison ni
# la catégorie), et l'utilisateur joue en français — un accord faux se lit
# immédiatement. Toute roche absente de cette table est traitée au masculin et
# signalée en fin de script.
FEMININE = {
    "andesite", "ardoise", "breche_volcanique", "calcite", "craie", "diorite",
    "dolomie", "kimberlite", "obsidienne", "peridotite", "pierre",
    "pierre_ponce", "rhyolite", "serpentinite",
}

# La roche « pierre » a DÉJÀ sa variante taillée, historique et référencée par
# les recettes de brique/dalle et par les palettes de ville. On la régénère
# quand même (pour lui donner le même style de texture que les autres) mais
# sous son id d'origine, jamais « pierre_taillee_taillee ».
LEGACY_IDS = {"pierre": "pierre_taillee"}


def cut_id(rock_id):
    return LEGACY_IDS.get(rock_id, rock_id + "_taillee")


def dress_color(hex_color):
    """Teinte de la pierre TAILLÉE dérivée de la roche brute.

    Une face sciée est plus claire et moins colorée qu'une cassure naturelle :
    on désature légèrement vers le gris et on éclaircit. Les deux effets sont
    faibles à dessein — la variante doit rester reconnaissable comme SA roche,
    sinon les 28 variantes convergent vers le même gris et l'exercice n'a plus
    d'objet.
    """
    hex_color = hex_color.lstrip("#")
    r, g, b = (int(hex_color[i:i + 2], 16) for i in (0, 2, 4))
    grey = (r + g + b) / 3.0
    out = []
    for c in (r, g, b):
        c = c + (grey - c) * 0.25        # désaturation partielle
        c = c + (255 - c) * 0.10         # éclaircissement
        out.append(max(0, min(255, int(round(c)))))
    return "#%02X%02X%02X" % tuple(out)


def build_material(rock, index):
    stats = dict(rock["stats"])
    # La pierre taillée garde la DURETÉ de sa roche (un bloc de granit taillé
    # résiste comme du granit — c'est ce qui rend une tour de granit plus
    # coûteuse à percer qu'une tour de craie) mais gagne en VALEUR : le travail
    # de taille est du travail ajouté.
    stats["valeur_base"] = int(stats.get("valeur_base", 1)) + 2
    stats["friction"] = 50
    return {
        "id": cut_id(rock["id"]),
        "name_key": "material.%s.name" % cut_id(rock["id"]),
        "category": "construction",
        "stats": stats,
        "tags": ["pierre_taillee"],
        "color": dress_color(rock["color"]),
        "noise": {
            "type": "procedural",
            "seed_offset": SEED_BASE + index,
            "amplitude": 0.05,
            "scale": 3,
        },
        # `bricks` : le shader dessine des joints d'appareillage. C'est ce qui
        # fait LIRE le bloc comme taillé plutôt que comme un caillou lisse — la
        # différence entre « une tour en pierre » et « une tour en pierre
        # taillée », qui est la demande.
        "texture_style": "bricks",
        "harvest": {"tool_category": "pioche", "skill": "minage"},
        # Jamais générée par le bruit du monde : c'est un matériau ouvragé, il
        # n'apparaît que par la main du joueur ou par une structure (la tour de
        # donjon la pose directement).
        "world_gen": {"mode": "none"},
    }


def build_transform(rock):
    cid = cut_id(rock["id"])
    return {
        "id": "taille_%s" % cid,
        "name_key": "transformation.taille_%s.name" % cid,
        "station": "tailleur",
        "skill": "minage",
        "output": {"material": cid, "amount": 1},
        "input": {"material": rock["id"], "amount": 1},
    }


def localized(lang):
    """Lit un CSV de langue en dict, en préservant l'ordre des lignes."""
    rows = {}
    order = []
    with open(os.path.join(LOCALE_DIR, "%s.csv" % lang), encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            key, _, value = line.partition(",")
            rows[key] = value
            order.append(key)
    return rows, order


def main():
    rocks = []
    for path in sorted(glob.glob(os.path.join(ROCK_DIR, "*.json"))):
        with open(path, encoding="utf-8") as f:
            rocks.append(json.load(f))

    # --- Matériaux + recettes ---
    for index, rock in enumerate(rocks):
        mat = build_material(rock, index)
        with open(os.path.join(OUT_DIR, "%s.json" % mat["id"]), "w",
                  encoding="utf-8", newline="\n") as f:
            json.dump(mat, f, ensure_ascii=False, indent=2)
            f.write("\n")
        tr = build_transform(rock)
        with open(os.path.join(TRANSFORM_DIR, "%s.json" % tr["id"]), "w",
                  encoding="utf-8", newline="\n") as f:
            json.dump(tr, f, ensure_ascii=False, indent=2)
            f.write("\n")

    # L'ancienne recette générique « n'importe quelle roche → pierre taillée »
    # est REMPLACÉE par les recettes par roche : la laisser en place donnerait
    # au joueur deux façons de tailler la même roche, dont une qui perd
    # l'identité du matériau.
    legacy = os.path.join(TRANSFORM_DIR, "taille_pierre.json")
    if os.path.exists(legacy):
        os.remove(legacy)

    # --- Traductions ---
    patterns = {
        "fr": lambda name, fem: "%s taillé%s" % (name, "e" if fem else ""),
        "en": lambda name, fem: "Cut %s" % name[0].lower() + name[1:],
        "ja": lambda name, fem: "%sの切石" % name,
        "zh_Hans": lambda name, fem: "切制%s" % name,
    }
    # Le nom d'une recette désigne la MATIÈRE PREMIÈRE, pas le produit : dans la
    # liste du tailleur de pierre, le joueur cherche « qu'est-ce que je peux
    # faire avec mon granit », pas « comment obtenir du granit taillé ». Écrire
    # la sortie donnait des libellés absurdes du type « Tailler : Granit
    # taillé ».
    recipe_patterns = {
        "fr": lambda name: "Tailler : %s" % name,
        "en": lambda name: "Cut: %s" % name,
        "ja": lambda name: "切り出し：%s" % name,
        "zh_Hans": lambda name: "切制：%s" % name,
    }

    unknown_gender = []
    for lang, pattern in patterns.items():
        rows, order = localized(lang)
        added = 0
        for rock in rocks:
            base = rows.get("material.%s.name" % rock["id"])
            if base is None:
                continue
            fem = rock["id"] in FEMININE
            if lang == "fr" and rock["id"] not in FEMININE:
                unknown_gender.append(rock["id"])
            cid = cut_id(rock["id"])
            mkey = "material.%s.name" % cid
            tkey = "transformation.taille_%s.name" % cid
            mval = pattern(base, fem)
            for key, value in ((mkey, mval), (tkey, recipe_patterns[lang](base))):
                if key not in rows:
                    order.append(key)
                    added += 1
                rows[key] = value
        # L'ancienne recette générique disparaît aussi des traductions.
        for dead in ("transformation.taille_pierre.name",):
            if dead in rows:
                order.remove(dead)
                del rows[dead]
        with open(os.path.join(LOCALE_DIR, "%s.csv" % lang), "w",
                  encoding="utf-8", newline="\n") as f:
            for key in order:
                f.write("%s,%s\n" % (key, rows[key]))
        print("%-8s %d clés ajoutées" % (lang, added))

    print("%d variantes de pierre taillée générées." % len(rocks))
    # Signalé et non tu : un genre deviné au masculin par défaut produit
    # « ardoise taillé », faute visible par le joueur français. Mieux vaut une
    # ligne de sortie à lire qu'une coquille silencieuse dans le catalogue.
    only_masc = sorted(set(unknown_gender))
    if only_masc:
        print("Traitées au MASCULIN (vérifier si l'une est féminine) : %s"
              % ", ".join(only_masc))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Les 14 statuts du GDD F.4, en données (`data/status_effects/`).

Écrits à la main, valeur par valeur — le script ne sert qu'à garantir la
structure identique et les 4 traductions, qu'un oubli ferait tomber sous les
100 % contrôlés au boot.

CONVERSION « PAR TOUR » → TICKS. Le GDD raisonne en tours (« 1d4 feu/tour,
3 tours ») ; le projet compte en ticks (E.1). Un tour vaut 10 ticks, comme la
régénération de mana (A.5). « 3 tours » s'écrit donc 30 ticks.

Usage :  python tools/generate_status_effects.py
"""

import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "data", "status_effects")
LOCALE = os.path.join(ROOT, "locale")

TOUR = 10  # ticks par « tour » du GDD

# (id, durée_ticks, cumule, periodic, modifiers, tags, fr, en, ja, zh)
STATUSES = [
    ("brulure", 3 * TOUR, True, {"degats_des": "1d4"}, {}, ["feu"],
     "Brûlure", "Burning", "燃焼", "灼烧"),
    ("ralentissement", 10 * TOUR, False, {},
     {"vitesse_deplacement": {"mult": 0.7}}, ["entrave"],
     "Ralentissement", "Slowed", "鈍足", "迟缓"),
    ("gel", 3 * TOUR, False, {},
     {"vitesse_deplacement": {"mult": 0.0}}, ["entrave", "glace"],
     "Gel", "Frozen", "凍結", "冰冻"),
    ("poison", 20 * TOUR, True, {"degats_des": "1d3"}, {}, ["poison"],
     "Poison", "Poison", "毒", "中毒"),
    ("saignement", 10 * TOUR, True, {"degats_des": "1d4"}, {}, ["saignement"],
     "Saignement", "Bleeding", "出血", "流血"),
    ("etourdi", 5 * TOUR, False, {},
     {"vitesse_deplacement": {"mult": 0.5}}, ["controle"],
     "Étourdi", "Dazed", "朦朧", "眩晕"),
    ("confusion", 12 * TOUR, False, {}, {}, ["controle"],
     "Confusion", "Confused", "混乱", "混乱"),
    ("terreur", 10 * TOUR, False, {}, {}, ["controle", "mental"],
     "Terreur", "Terror", "恐慌", "恐惧"),
    ("infection", 100 * TOUR, False, {},
     {"endurance": {"add": -2.0}}, ["maladie"],
     "Infection", "Infection", "感染", "感染"),
    ("affaibli", 60 * TOUR, False, {},
     {"force": {"mult": 0.8}, "dexterite": {"mult": 0.8},
      "endurance": {"mult": 0.8}, "volonte": {"mult": 0.8}}, ["malediction"],
     "Affaibli", "Weakened", "衰弱", "虚弱"),
    ("regeneration", 12 * TOUR, False, {"degats_des": "1d4", "soin": True}, {},
     ["soin", "vie"],
     "Régénération", "Regeneration", "再生", "回复"),
    ("peau_de_pierre", 20 * TOUR, False, {},
     {"reduction_degats": {"add": 0.30}}, ["protection", "terre"],
     "Peau de pierre", "Stoneskin", "石の肌", "石肤"),
    ("hate", 10 * TOUR, False, {},
     {"vitesse_deplacement": {"mult": 1.25}}, ["hate"],
     "Hâte", "Haste", "加速", "急速"),
    ("beni", 30 * TOUR, False, {},
     {"perception": {"add": 1.0}, "charisme": {"add": 1.0}}, ["benediction"],
     "Béni", "Blessed", "祝福", "祝福"),
]


def main():
    for (sid, duration, stacks, periodic, modifiers, tags,
         fr, en, ja, zh) in STATUSES:
        data = {
            "id": sid,
            "name_key": "status.%s.name" % sid,
            "duration_ticks": duration,
            "stacks": stacks,
            "tags": tags,
        }
        if periodic:
            data["periodic"] = periodic
        if modifiers:
            data["modifiers"] = modifiers
        with open(os.path.join(OUT, "%s.json" % sid), "w",
                  encoding="utf-8", newline="\n") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")

    columns = {"fr": 6, "en": 7, "ja": 8, "zh_Hans": 9}
    for lang, col in columns.items():
        path = os.path.join(LOCALE, "%s.csv" % lang)
        rows, order = {}, []
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                if not line:
                    continue
                key, _, value = line.partition(",")
                if key not in rows:
                    order.append(key)
                rows[key] = value
        added = 0
        for entry in STATUSES:
            key = "status.%s.name" % entry[0]
            if key not in rows:
                order.append(key)
                added += 1
            rows[key] = entry[col]
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            for key in order:
                f.write("%s,%s\n" % (key, rows[key]))
        print("%-8s %d clés ajoutées" % (lang, added))

    print("%d statuts écrits." % len(STATUSES))


if __name__ == "__main__":
    main()

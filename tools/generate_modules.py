#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Catalogue de modules de sorts et d'attaques spéciales (GDD 5.1 / B.4 / C.6).

POURQUOI UN SCRIPT. Ce n'est pas de la génération procédurale : chaque module
ci-dessous est écrit à la main, valeur par valeur. Le script sert à garantir la
COHÉRENCE de ce qui est répétitif et vérifiable mécaniquement — présence des 12
domaines, structure du JSON, et surtout les 4 traductions par module, qu'un
oubli ferait tomber sous les 100 % que le boot contrôle.

TROIS RÔLES (B.4), et le catalogue en avait un seul avant aujourd'hui :
  - `effet`        : produit quelque chose ;
  - `modificateur` : altère ce qui suit (multi-cast, portée, guidage…) ;
  - `declencheur`  : accroche le reste de l'assemblage comme charge utile.
Sans modificateurs ni déclencheurs, l'assemblage « façon Noita » n'a rien à
assembler : c'est la première chose qui manquait.

Usage :  python tools/generate_modules.py
"""

import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "data", "modules")
LOCALE = os.path.join(ROOT, "locale")

# (id, type, domaines, book_type, cout, puissance, dés, tags, params,
#  fr, en, ja, zh)
MODULES = [
    # --- GRIMOIRES : Feu ---
    ("boule_de_feu", "effet", ["feu", "destruction"], "grimoire", 9, 14, "2d6",
     ["feu", "projectile"], {"vitesse": 18, "portee": 28},
     "Boule de feu", "Fireball", "火球", "火球术"),
    ("nappe_de_flammes", "effet", ["feu"], "grimoire", 12, 10, "1d8",
     ["feu", "zone"], {"rayon": 4, "duree": 6},
     "Nappe de flammes", "Sheet of flame", "焔の絨毯", "烈焰地毯"),
    # --- Eau / Glace ---
    ("eclat_de_glace", "effet", ["eau_glace"], "grimoire", 7, 11, "2d4",
     ["glace", "projectile"], {"vitesse": 24, "portee": 30},
     "Éclat de glace", "Ice shard", "氷の破片", "冰棱"),
    ("emprise_du_gel", "effet", ["eau_glace"], "grimoire", 10, 8, "1d4",
     ["glace", "entrave"], {"rayon": 3, "ralentissement": 50},
     "Emprise du gel", "Frost grip", "氷結の縛め", "寒霜禁锢"),
    # --- Foudre ---
    ("arc_electrique", "effet", ["foudre"], "grimoire", 8, 13, "2d6",
     ["foudre", "projectile"], {"vitesse": 40, "portee": 22},
     "Arc électrique", "Electric arc", "電弧", "电弧"),
    ("fulguration", "effet", ["foudre", "destruction"], "grimoire", 16, 22, "4d6",
     ["foudre", "cible"], {"portee": 35},
     "Fulguration", "Thunderstrike", "雷撃", "落雷术"),
    # --- Terre ---
    ("eclat_de_pierre", "effet", ["terre"], "grimoire", 6, 12, "2d5",
     ["terre", "projectile"], {"vitesse": 15, "portee": 20},
     "Éclat de pierre", "Stone shard", "石の礫", "石弹"),
    ("carapace_de_roche", "effet", ["terre"], "grimoire", 11, 16, "0",
     ["terre", "protection"], {"duree": 20, "reduction": 30},
     "Carapace de roche", "Rock carapace", "岩の甲殻", "岩石甲壳"),
    # --- Vie ---
    ("regeneration", "effet", ["vie"], "grimoire", 14, 18, "0",
     ["vie", "soin"], {"duree": 12, "par_tick": 2},
     "Régénération", "Regeneration", "再生", "回复术"),
    # --- Arcane ---
    ("bouclier_arcane", "effet", ["arcane"], "grimoire", 10, 15, "0",
     ["arcane", "protection"], {"duree": 15, "absorption": 25},
     "Bouclier arcane", "Arcane shield", "秘術の盾", "奥术护盾"),
    # --- Espace ---
    ("clignotement", "effet", ["espace"], "grimoire", 12, 0, "0",
     ["espace", "mobilite"], {"distance": 8},
     "Clignotement", "Blink", "瞬歩", "闪现"),
    ("rappel", "effet", ["espace"], "grimoire", 18, 0, "0",
     ["espace", "mobilite"], {"delai": 6},
     "Rappel", "Recall", "帰還", "回溯"),
    # --- Corruption ---
    ("drain_vital", "effet", ["corruption"], "grimoire", 9, 14, "2d6",
     ["corruption", "projectile", "vol_de_vie"], {"vitesse": 16, "portee": 18, "vol": 40},
     "Drain vital", "Life drain", "生命吸収", "生命汲取"),
    ("offrande_de_sang", "modificateur", ["corruption"], "grimoire", 0, 0, "0",
     ["corruption"], {"mods": {"puissance": 12}, "cout_vie": 8},
     "Offrande de sang", "Blood offering", "血の供物", "血之献祭"),

    # --- MANUELS : Frappes ---
    ("taillade_large", "effet", ["frappes"], "manuel", 7, 12, "2d6",
     ["arme", "zone"], {"arc": 140, "portee": 3},
     "Taillade large", "Wide slash", "薙ぎ払い", "横扫"),
    ("estoc_perforant", "effet", ["frappes"], "manuel", 6, 15, "2d8",
     ["arme", "percant"], {"portee": 4, "penetration": 40},
     "Estoc perforant", "Piercing thrust", "刺突", "穿刺突击"),
    # --- Postures ---
    ("garde_de_fer", "effet", ["postures"], "manuel", 8, 14, "0",
     ["arme", "protection"], {"duree": 14, "reduction": 35},
     "Garde de fer", "Iron guard", "鉄壁の構え", "铁壁架势"),
    ("posture_agile", "effet", ["postures"], "manuel", 6, 10, "0",
     ["arme", "mobilite"], {"duree": 14, "vitesse": 25},
     "Posture agile", "Agile stance", "軽身の構え", "轻捷架势"),
    # --- Techniques ---
    ("charge_epaule", "effet", ["techniques"], "manuel", 9, 13, "2d5",
     ["arme", "mobilite", "recul"], {"distance": 6, "recul": 3},
     "Charge d'épaule", "Shoulder charge", "体当たり", "冲撞"),
    ("contre_riposte", "declencheur", ["techniques"], "manuel", 5, 0, "0",
     ["arme", "contre"], {"trigger": "parade"},
     "Contre-riposte", "Counter-riposte", "返し技", "反击"),

    # --- MAÎTRISE : les modificateurs et déclencheurs, cœur de l'assemblage ---
    ("double_lancer", "modificateur", ["maitrise"], "manuel", 4, 0, "0",
     ["maitrise"], {"multicast": 2},
     "Double lancer", "Double cast", "二重詠唱", "双重施放"),
    ("triple_lancer", "modificateur", ["maitrise"], "manuel", 9, 0, "0",
     ["maitrise"], {"multicast": 3},
     "Triple lancer", "Triple cast", "三重詠唱", "三重施放"),
    ("portee_accrue", "modificateur", ["maitrise", "espace"], "grimoire", 3, 0, "0",
     ["maitrise"], {"mods": {"portee": 12}},
     "Portée accrue", "Extended range", "射程延長", "射程延展"),
    ("projection_rapide", "modificateur", ["maitrise"], "grimoire", 3, 0, "0",
     ["maitrise"], {"mods": {"vitesse": 15}},
     "Projection rapide", "Swift projection", "速射", "疾射"),
    ("guidage", "modificateur", ["espace", "maitrise"], "grimoire", 6, 0, "0",
     ["maitrise", "guidage"], {"mods": {"guidage": 60}},
     "Guidage", "Homing", "誘導", "追踪"),
    ("ricochet", "modificateur", ["maitrise"], "grimoire", 5, 0, "0",
     ["maitrise"], {"mods": {"rebonds": 2}},
     "Ricochet", "Ricochet", "跳弾", "弹射"),
    ("declencheur_impact", "declencheur", ["maitrise"], "grimoire", 6, 0, "0",
     ["maitrise", "declencheur"], {"trigger": "impact"},
     "Déclencheur à l'impact", "Impact trigger", "着弾起動", "撞击触发"),
    ("declencheur_retarde", "declencheur", ["maitrise", "espace"], "grimoire", 7, 0, "0",
     ["maitrise", "declencheur"], {"trigger": "delai", "delay": 1.5},
     "Déclencheur retardé", "Delayed trigger", "遅延起動", "延时触发"),
]


def main():
    for (mid, mtype, domains, book, cost, power, dice, tags, params,
         fr, en, ja, zh) in MODULES:
        data = {
            "id": mid,
            "name_key": "module.%s.name" % mid,
            "module_type": mtype,
            "mana_cost_base": cost,
            "power_base": power,
            "tags": tags,
            "params": params,
            "grimoire_domains": domains,
            "book_type": book,
        }
        if dice != "0":
            data["degats_des"] = dice
        with open(os.path.join(OUT, "%s.json" % mid), "w",
                  encoding="utf-8", newline="\n") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")

    # --- Traductions ---
    columns = {"fr": 9, "en": 10, "ja": 11, "zh_Hans": 12}
    # Libellés d'interface de l'assemblage, dans les mêmes 4 langues.
    ui = {
        "fr": {"ui.module.vide": "(vide)",
               "ui.module.declenche.impact": "à l'impact",
               "ui.module.declenche.delai": "après un délai",
               "ui.module.declenche.parade": "sur parade"},
        "en": {"ui.module.vide": "(empty)",
               "ui.module.declenche.impact": "on impact",
               "ui.module.declenche.delai": "after a delay",
               "ui.module.declenche.parade": "on parry"},
        "ja": {"ui.module.vide": "（空）",
               "ui.module.declenche.impact": "着弾時",
               "ui.module.declenche.delai": "遅延後",
               "ui.module.declenche.parade": "受け流し時"},
        "zh_Hans": {"ui.module.vide": "（空）",
                    "ui.module.declenche.impact": "撞击时",
                    "ui.module.declenche.delai": "延时后",
                    "ui.module.declenche.parade": "招架时"},
    }
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
        for entry in MODULES:
            key = "module.%s.name" % entry[0]
            if key not in rows:
                order.append(key)
                added += 1
            rows[key] = entry[col]
        for key, value in ui[lang].items():
            if key not in rows:
                order.append(key)
                added += 1
            rows[key] = value
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            for key in order:
                f.write("%s,%s\n" % (key, rows[key]))
        print("%-8s %d clés ajoutées" % (lang, added))

    print("%d modules écrits." % len(MODULES))


if __name__ == "__main__":
    main()

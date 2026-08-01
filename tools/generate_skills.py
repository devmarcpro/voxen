#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Génère les fiches de compétences manquantes + leurs clés de langue.

    python tools/generate_skills.py

POURQUOI UN GÉNÉRATEUR. Une compétence, c'est trois lignes de JSON et deux
lignes de CSV, dans trois fichiers différents. Les ajouter à la main garantit
qu'un jour l'un des trois sera oublié — et une compétence sans clé de langue
s'affiche sous son identifiant brut, ce qui ne se voit qu'en jouant dans la
bonne langue au bon endroit.

CE QUI DÉCIDE DE LA LISTE. La classification de la section 6.0 du GDD, citée
mot pour mot :

  combat/survie = toutes les compétences d'armes, Dual Wielding, Bouclier,
                  Deux Mains, tous les domaines de magie, Méditation, Contrôle
                  du Mana, Esquive, Encaissement, Discrétion, Athlétisme
  général       = tout le reste (récolte, artisanat, Lecture, Négociation,
                  Dressage, Leadership, Agriculture, Élevage, Navigation)

La catégorie n'est PAS cosmétique : le niveau de combat et le niveau général
sont la moyenne des 5 meilleures compétences de chaque catégorie (A.1). Classer
une compétence du mauvais côté déplace silencieusement un niveau affiché.

UNE COMPÉTENCE PAR ARME. Le jeu en partageait une pour toute une famille
(espadon, épée courte et rapière comptaient comme « épée »). Demande de
l'auteur du 2026-08-01 : chaque type d'arme a la sienne. C'est aussi ce que
suppose la règle de slots du GDD (5.2) — « slots de compétences par arme =
2 + floor(N_arme/20) » n'a de sens que si N_arme existe par arme.

LES TYPES DE DÉGÂTS SONT DES MAÎTRISES TRANSVERSES. Tranchant, perçant et
contondant progressent avec N'IMPORTE QUELLE arme qui inflige ce type. Un
joueur qui passe de la hache à l'espadon garde donc son acquis de tranchant :
la spécialisation par arme ne punit plus le changement d'outil.
"""

import csv
import io
import json
import os

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKILL_DIR = os.path.join(HERE, "data", "skills")
FUNC_DIR = os.path.join(HERE, "data", "functionalities")
LOCALE_DIR = os.path.join(HERE, "locale")

# --- Compétences hors armes --------------------------------------------------
#
# id → (catégorie, nom français, nom anglais).

SKILLS = {
    # Maîtrises de TYPE DE DÉGÂTS (transverses aux armes).
    "tranchant":       ("combat", "Tranchant", "Cutting"),
    "percant":         ("combat", "Perçant", "Piercing"),
    "contondant":      ("combat", "Contondant", "Blunt"),

    # Styles de combat (GDD 5.6 : ce qu'on tient dans les mains).
    "dual_wielding":   ("combat", "Deux armes", "Dual wielding"),
    "bouclier":        ("combat", "Bouclier", "Shield"),
    "deux_mains":      ("combat", "Deux mains", "Two-handed"),

    # Domaines de magie. Le GDD n'en nomme que deux (6.0) : on s'en tient là
    # plutôt que d'inventer des écoles qu'aucune donnée ne porte encore.
    "magie_offensive": ("combat", "Magie offensive", "Offensive magic"),
    "magie_defensive": ("combat", "Magie défensive", "Defensive magic"),

    # Survie.
    "discretion":      ("combat", "Discrétion", "Stealth"),
    "athletisme":      ("combat", "Athlétisme", "Athletics"),

    # Général — social et savoir.
    "lecture":         ("general", "Lecture", "Reading"),
    "negociation":     ("general", "Négociation", "Bartering"),
    "leadership":      ("general", "Leadership", "Leadership"),
    "dressage":        ("general", "Dressage", "Taming"),

    # Général — production. Les postes de travail du GDD (8.4) attendent
    # chacun une compétence de rendement.
    "agriculture":     ("general", "Agriculture", "Farming"),
    "elevage":         ("general", "Élevage", "Animal husbandry"),
    "navigation":      ("general", "Navigation", "Navigation"),
    "alchimie":        ("general", "Alchimie", "Alchemy"),
    "couture":         ("general", "Couture", "Tailoring"),
}

# Noms des compétences d'ARME, dérivées des fonctionnalités. La clé est l'id de
# la fonctionnalité ; seules celles de `kind: arme` comptent.
WEAPON_NAMES = {
    "arbalete":       ("Arbalète", "Crossbow"),
    "arc":            ("Arc", "Bow"),
    "baton_ferre":    ("Bâton ferré", "Iron-shod staff"),
    "baton_magique":  ("Bâton magique", "Magic staff"),
    "dague":          ("Dague", "Dagger"),
    "epee":           ("Épée", "Sword"),
    "epee_courte":    ("Épée courte", "Short sword"),
    "espadon":        ("Espadon", "Greatsword"),
    "faux_de_guerre": ("Faux de guerre", "War scythe"),
    "gourdin":        ("Gourdin", "Club"),
    "hache_arme":     ("Hache d'armes", "Battle axe"),
    "hache_double":   ("Hache double", "Double axe"),
    "hachette":       ("Hachette", "Hatchet"),
    "hallebarde":     ("Hallebarde", "Halberd"),
    "lance":          ("Lance", "Spear"),
    "mains_nues":     ("Mains nues", "Unarmed"),
    "marteau_guerre": ("Marteau de guerre", "War hammer"),
    "masse":          ("Masse", "Mace"),
    "masse_ailettes": ("Masse à ailettes", "Flanged mace"),
    "pioche_combat":  ("Pioche de combat", "War pick"),
    "rapiere":        ("Rapière", "Rapier"),
    "trident":        ("Trident", "Trident"),
}

## La morsure est l'attaque d'une CRÉATURE, pas une arme que l'on tient : elle
## n'a pas de compétence propre et reste sur les mains nues.
NO_OWN_SKILL = {"morsure"}


def weapon_functionalities():
    """Ids des fonctionnalités de type arme, lus depuis les données."""
    out = {}
    for name in sorted(os.listdir(FUNC_DIR)):
        if not name.endswith(".json"):
            continue
        with open(os.path.join(FUNC_DIR, name), encoding="utf-8") as handle:
            data = json.load(handle)
        if data.get("kind") == "arme":
            out[data["id"]] = data
    return out


def write_skill(skill_id, category):
    """Écrit une fiche de compétence. Ne touche pas à une fiche existante :
    elle peut avoir été enrichie à la main depuis."""
    path = os.path.join(SKILL_DIR, skill_id + ".json")
    if os.path.exists(path):
        return False
    payload = {"id": skill_id, "name_key": "skill.%s.name" % skill_id,
               "category": category}
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(payload, handle, ensure_ascii=False)
        handle.write("\n")
    return True


def add_locale_keys(entries):
    """Ajoute les clés absentes à fr.csv et en.csv, sans toucher aux autres
    langues : elles retombent sur l'anglais, c'est le comportement voulu."""
    added = {}
    for lang, column in (("fr", 0), ("en", 1)):
        path = os.path.join(LOCALE_DIR, lang + ".csv")
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        existing = {row[0] for row in csv.reader(io.StringIO(text)) if row}
        buffer = io.StringIO()
        writer = csv.writer(buffer, lineterminator="\n")
        count = 0
        for key, names in entries.items():
            if key in existing:
                continue
            writer.writerow([key, names[column]])
            count += 1
        if count:
            if not text.endswith("\n"):
                text += "\n"
            with open(path, "w", encoding="utf-8", newline="") as handle:
                handle.write(text + buffer.getvalue())
        added[lang] = count
    return added


def main():
    functionalities = weapon_functionalities()

    # 1. Fiches de compétences : armes puis le reste.
    created = []
    locale_entries = {}
    for func_id in sorted(functionalities):
        if func_id in NO_OWN_SKILL:
            continue
        if func_id not in WEAPON_NAMES:
            raise SystemExit(
                "arme « %s » sans nom déclaré : compléter WEAPON_NAMES." % func_id)
        if write_skill(func_id, "combat"):
            created.append(func_id)
        locale_entries["skill.%s.name" % func_id] = WEAPON_NAMES[func_id]

    for skill_id, (category, fr, en) in SKILLS.items():
        if write_skill(skill_id, category):
            created.append(skill_id)
        locale_entries["skill.%s.name" % skill_id] = (fr, en)

    # 2. Chaque arme pointe vers SA compétence.
    rewired = []
    for func_id, data in functionalities.items():
        wanted = "mains_nues" if func_id in NO_OWN_SKILL else func_id
        if data.get("combat_skill") == wanted:
            continue
        data["combat_skill"] = wanted
        path = os.path.join(FUNC_DIR, func_id + ".json")
        with open(path, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(data, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        rewired.append(func_id)

    added = add_locale_keys(locale_entries)

    total = len([n for n in os.listdir(SKILL_DIR) if n.endswith(".json")])
    print("%d compétence(s) créée(s) : %s" % (len(created), ", ".join(sorted(created)) or "-"))
    print("%d arme(s) recâblée(s) vers leur propre compétence" % len(rewired))
    print("clés de langue ajoutées : fr=%d en=%d" % (added["fr"], added["en"]))
    print("total : %d compétences" % total)


if __name__ == "__main__":
    main()

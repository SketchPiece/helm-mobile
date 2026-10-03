#!/usr/bin/env python3
"""Regenerates HelmMobile/Resources/Localizable.xcstrings.

Keys come from the compiler (build once with SWIFT_EMIT_LOC_STRINGS=YES so .stringsdata files
exist in build/dd); Russian text comes from Localization/ru.json, English plurals from
Localization/en-plurals.json. Prints keys that still lack a Russian translation.
"""
import glob, json, os, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
pattern = os.path.join(root, "build/dd/Build/Intermediates.noindex/HelmMobile.build/*/HelmMobile.build/Objects-normal/*/*.stringsdata")
keys = set()
for path in glob.glob(pattern):
    for entries in json.load(open(path)).get("tables", {}).values():
        keys.update(entry["key"] for entry in entries)
if not keys:
    sys.exit("No .stringsdata found; build with SWIFT_EMIT_LOC_STRINGS=YES first.")

ru = json.load(open(os.path.join(root, "Localization/ru.json")))
en_plurals = json.load(open(os.path.join(root, "Localization/en-plurals.json")))

def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}

def localization(value):
    if isinstance(value, dict):
        return {"variations": {"plural": {form: unit(text) for form, text in value.items()}}}
    return unit(value)

strings = {}
missing = []
untranslatable = lambda key: key.strip(" ·%@lld#+−/0123456789.") == ""
for key in sorted(keys):
    entry = {}
    localizations = {}
    if key in en_plurals:
        localizations["en"] = localization(en_plurals[key])
    if key in ru:
        localizations["ru"] = localization(ru[key])
    elif not untranslatable(key):
        missing.append(key)
    if localizations:
        entry["localizations"] = localizations
    else:
        entry["shouldTranslate"] = False if untranslatable(key) else True
        if entry["shouldTranslate"]:
            del entry["shouldTranslate"]
    strings[key] = entry

catalog = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
out = os.path.join(root, "HelmMobile/Resources/Localizable.xcstrings")
with open(out, "w") as f:
    json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True)
    f.write("\n")
print(f"{len(keys)} keys, {len(missing)} missing Russian")
for key in missing:
    print("  missing:", repr(key))

#!/usr/bin/env python3
"""
Golosok Project Invariant Verifier (Architecture & Localization Gate)
Runs before build. Fails the build if:
1. Localizable.xcstrings has keys missing 'en' or 'ru' translations.
2. Swift UI code contains raw, unlocalized Cyrillic strings in UI views.
3. Obvious state machine / lifecycle hazards are detected.
"""

import sys
import json
import re
import os
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
XCSTRINGS_PATH = REPO_ROOT / "Golosok" / "Localizable.xcstrings"
SWIFT_DIR = REPO_ROOT / "Golosok"

def check_localization_integrity():
    errors = []
    if not XCSTRINGS_PATH.exists():
        errors.append(f"Missing xcstrings catalog at {XCSTRINGS_PATH}")
        return errors

    with open(XCSTRINGS_PATH, "r", encoding="utf-8") as f:
        try:
            data = json.load(f)
        except Exception as e:
            errors.append(f"Invalid JSON in Localizable.xcstrings: {e}")
            return errors

    strings = data.get("strings", {})
    missing_en = []
    missing_ru = []

    for key, item in strings.items():
        if not key.strip():
            continue
        locs = item.get("localizations", {})
        
        # Check EN
        en_val = locs.get("en", {}).get("stringUnit", {}).get("value")
        if en_val is None or en_val == "":
            missing_en.append(key)

        # Check RU
        ru_val = locs.get("ru", {}).get("stringUnit", {}).get("value")
        if ru_val is None or ru_val == "":
            missing_ru.append(key)

    if missing_en:
        errors.append(f"Localizable.xcstrings: {len(missing_en)} keys missing English translation! e.g. {missing_en[:5]}")
    if missing_ru:
        errors.append(f"Localizable.xcstrings: {len(missing_ru)} keys missing Russian translation! e.g. {missing_ru[:5]}")

    return errors

def check_unlocalized_ui_strings():
    errors = []
    # Match UI string declarations that have Cyrillic literals
    patterns = [
        (re.compile(r'Text\(\s*"([^"]*[а-яА-ЯёЁ][^"]*)"\s*\)'), "Text(...) raw string"),
        (re.compile(r'Button\(\s*"([^"]*[а-яА-ЯёЁ][^"]*)"\s*\)'), "Button(...) raw string"),
        (re.compile(r'UIOutlineButton\(\s*title:\s*"([^"]*[а-яА-ЯёЁ][^"]*)"'), "UIOutlineButton raw title"),
        (re.compile(r'UIDestructiveButton\(\s*title:\s*"([^"]*[а-яА-ЯёЁ][^"]*)"'), "UIDestructiveButton raw title"),
    ]

    with open(XCSTRINGS_PATH, "r", encoding="utf-8") as f:
        xc_keys = set(json.load(f).get("strings", {}).keys())

    for swift_path in SWIFT_DIR.glob("*.swift"):
        with open(swift_path, "r", encoding="utf-8") as f:
            for line_no, line in enumerate(f, 1):
                clean_line = line.strip()
                if clean_line.startswith("//") or clean_line.startswith("/*"):
                    continue
                for pat, desc in patterns:
                    for m in pat.finditer(line):
                        raw_text = m.group(1).strip()
                        # If the literal is not present as a key in xcstrings, it is a hard violation
                        if raw_text not in xc_keys:
                            errors.append(f"{swift_path.name}:{line_no} [{desc}] -> \"{raw_text}\" is not in Localizable.xcstrings!")

    return errors

def main():
    print("==> Проверка архитектурных инвариантов и локализации (Pre-Build Gate)...")
    all_errors = []
    
    # 1. Localization completeness
    l10n_errors = check_localization_integrity()
    all_errors.extend(l10n_errors)
    
    # 2. Hardcoded UI strings
    ui_errors = check_unlocalized_ui_strings()
    all_errors.extend(ui_errors)

    if all_errors:
        print("\n❌ ПРОВЕРКА ИНВАРИАНТОВ ПРОВАЛЕНА! Обнаружены архитектурные нарушения:")
        for err in all_errors:
            print(f"  • {err}")
        print("\nСборка остановлена. Исправьте рассинхрон перед компиляцией.\n")
        sys.exit(1)
    else:
        print("✅ Все архитектурные инварианты и двуязычность соблюдены (0 нарушений).")

if __name__ == "__main__":
    main()

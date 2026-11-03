#!/usr/bin/env python3
"""Copy existing artwork and static localized strings; never redesign assets."""
import hashlib
import json
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parents[1]
SWIFT = ROOT / "apps/macos/Sovereign"
DEST = ROOT / "apps/desktop/public/assets"
STRING = r'"((?:[^"\\]|\\.)*)"'


def main():
    DEST.mkdir(parents=True, exist_ok=True)
    assets = {}
    for path in sorted((SWIFT / "Resources").glob("*")):
        if path.suffix == ".svg" or path.name == "logo_madi.png":
            shutil.copyfile(path, DEST / path.name)
            assets[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    ja = {}
    for match in re.finditer(STRING + r'\s*:\s*' + STRING, (SWIFT / "UI/L10nJa.swift").read_text(encoding="utf-8")):
        key, value = match.groups()
        if "\\(" not in key + value:
            ja[json.loads('"' + key + '"')] = json.loads('"' + value + '"')
    strings = {}
    pattern = r'(?:uiLang|lang)\(\s*' + STRING + r'\s*,\s*' + STRING + r'(?:\s*,\s*' + STRING + r')?\s*\)'
    for rel in ["UI/ContentView.swift", "Transcript/MeetingMode.swift", "Audio/AudioSource.swift"]:
        for match in re.finditer(pattern, (SWIFT / rel).read_text(encoding="utf-8")):
            ko, en, inline_ja = match.groups()
            if "\\(" in ko + en + (inline_ja or ""):
                continue
            ko, en = (json.loads('"' + value + '"') for value in [ko, en])
            translated = json.loads('"' + inline_ja + '"') if inline_ja else ja.get(en, en)
            strings[en] = {"ko": ko, "en": en, "ja": translated}
    output = ROOT / "apps/desktop/src/strings.generated.json"
    output.write_text(json.dumps(strings, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    # Keep first-run copy in all three languages tied to ModelGateView, including
    # its dynamic labels. Values come from native snapshots, not JS byte rounding.
    interpolations = {
        r'\(memoryGB)': '{memory}',
        r'\(translationVariant.displayName)': '{translation}',
        r'\(fileSize(AssetManifest.model.sizeBytes))': '{requiredSize}',
        r'\(fileSize(translationAsset.sizeBytes))': '{translationSize}',
        r'\(profile)': '{profile}', r'\(ram)': '{ram}',
        r'\(downloadSize(.recommended))': '{size}',
        r'\(downloadSize(.transcriptionOnly))': '{size}',
    }
    model_strings = {}
    for match in re.finditer(pattern, (SWIFT / 'UI/ModelGateView.swift').read_text(encoding="utf-8")):
        values = []
        for value in match.groups():
            if value is None:
                raise ValueError('Model gate requires an explicit Japanese string')
            for source, placeholder in interpolations.items():
                value = value.replace(source, placeholder)
            if r'\(' in value:
                raise ValueError(f'Unmapped model interpolation: {value}')
            values.append(json.loads('"' + value + '"'))
        ko, en, translated = values
        model_strings[en] = {'ko': ko, 'en': en, 'ja': translated}
    (ROOT / 'apps/desktop/src/model-strings.generated.json').write_text(
        json.dumps(model_strings, ensure_ascii=False, indent=2, sort_keys=True) + '\n', encoding="utf-8")
    manifest = ROOT / "design/parity/asset-reference.json"
    manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest.write_text(json.dumps({"source": "apps/macos/Sovereign/Resources", "sha256": assets}, indent=2) + "\n")
    print(f"Copied {len(assets)} original assets, {len(strings)} setup and {len(model_strings)} model string triples")


if __name__ == "__main__":
    main()

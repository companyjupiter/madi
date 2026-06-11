#!/usr/bin/env python3
"""gen_theme.py — design/tokens.json → app/Sovereign/UI/Theme.swift

The generated Theme is the ONLY place UI constants live; views reference
Theme.* so a designer's token export restyles the whole app without touching
view code. Run after every tokens.json change (design/sync_tokens.sh does
gen + rebuild).
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
TOKENS = os.path.join(HERE, 'tokens.json')
OUT = os.path.join(HERE, '..', 'app', 'Sovereign', 'UI', 'Theme.swift')

t = json.load(open(TOKENS))

def swift_color(tok):
    hexv = tok['value'].lstrip('#')
    r, g, b = (int(hexv[i:i+2], 16) / 255.0 for i in (0, 2, 4))
    a = tok.get('alpha', 1.0)
    return f'Color(red: {r:.4f}, green: {g:.4f}, blue: {b:.4f}, opacity: {a})'

def swift_font(tok):
    w = {'regular': '.regular', 'medium': '.medium', 'semibold': '.semibold',
         'bold': '.bold'}[tok.get('weight', 'regular')]
    f = f'Font.system(size: {tok["size"]}, weight: {w})'
    if tok.get('italic'):
        f += '.italic()'
    return f

L = []
L.append('// Theme.swift — GENERATED from design/tokens.json by design/gen_theme.py.')
L.append('// DO NOT EDIT BY HAND: edit tokens.json (or import the designer\'s Figma')
L.append('// token export) and run design/sync_tokens.sh.')
L.append('')
L.append('import SwiftUI')
L.append('')
L.append('enum Theme {')

L.append('    enum Colors {')
for name, tok in t['color'].items():
    if name == 'speaker':
        continue
    L.append(f'        static let {name} = {swift_color(tok)}')
ids = sorted(t['color']['speaker'].keys(), key=int)
L.append('        static let speakerPalette: [Color] = [')
for i in ids:
    L.append(f'            {swift_color(t["color"]["speaker"][i])},  // {t["color"]["speaker"][i].get("description", i)}')
L.append('        ]')
L.append('        static func speaker(_ id: Int) -> Color {')
L.append('            speakerPalette[((id % speakerPalette.count) + speakerPalette.count) % speakerPalette.count]')
L.append('        }')
L.append('    }')

L.append('    enum Fonts {')
for name, tok in t['font'].items():
    L.append(f'        static let {name} = {swift_font(tok)}')
L.append('    }')

L.append('    enum Space {')
for name, tok in t['space'].items():
    L.append(f'        static let {name}: CGFloat = {tok["value"]}')
L.append('    }')

L.append('    enum Size {')
for name, tok in t['size'].items():
    L.append(f'        static let {name}: CGFloat = {tok["value"]}')
L.append('    }')

L.append('    enum Radius {')
for name, tok in t['radius'].items():
    L.append(f'        static let {name}: CGFloat = {tok["value"]}')
L.append('    }')

L.append('}')
L.append('')

open(OUT, 'w').write('\n'.join(L))
print(f'generated {os.path.relpath(OUT, os.path.join(HERE, ".."))} '
      f'({len(t["color"]) - 1}+{len(ids)} colors, {len(t["font"])} fonts)')

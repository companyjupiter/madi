#!/usr/bin/env bash
# sync_tokens.sh — tokens.json → Theme.swift → rebuilt app, one command.
# Run after editing tokens.json (or dropping in the designer's Figma export).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$HERE/gen_theme.py"
"$HERE/../app/scripts/make_app.sh" | tail -2
echo "→ tokens applied; relaunch the app to see them"

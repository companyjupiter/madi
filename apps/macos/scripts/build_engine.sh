#!/usr/bin/env bash
# build_engine.sh — build the bit-validated engine binary the app embeds.
# Produces engine/metal/out/transcribe (+ engine/metal/whisper.metallib,
# @embedFile'd already).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"   # apps/macos/scripts → repo root
cd "$ROOT/engine/metal"
./build.sh transcribe.zig transcribe
echo "✅ engine → $ROOT/engine/metal/out/transcribe"

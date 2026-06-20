#!/usr/bin/env bash
# build_engine.sh — build the bit-validated engine binary the app embeds.
# Produces metal/out/transcribe (+ metal/whisper.metallib, @embedFile'd already).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT/metal"
./build.sh transcribe.zig transcribe
echo "✅ engine → $ROOT/metal/out/transcribe"

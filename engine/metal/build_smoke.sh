#!/usr/bin/env bash
# build_smoke.sh — Milestone 0 toolchain proof.
# Compiles the smoke kernel → .metallib, the ObjC bridge → .o, the Zig
# harness → .o, then links everything into ./out/smoke and runs it.
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"   # metal/

BUILD=build
OUT=out
mkdir -p "$BUILD" "$OUT"

echo "[1/4] Metal shader → .metallib"
xcrun metal -c kernels/smoke.metal -o "$BUILD/smoke.air" -std=metal3.0 -Wall -Werror
xcrun metallib "$BUILD/smoke.air" -o "$BUILD/smoke.metallib"
# @embedFile must see it next to smoke.zig (Zig forbids embedding outside the pkg dir).
cp "$BUILD/smoke.metallib" smoke.metallib

echo "[2/4] ObjC bridge → .o"
clang -c -fobjc-arc -O2 metal_backend.m -o "$BUILD/metal_backend.o"

echo "[3/4] Zig harness → .o"
zig build-obj -O ReleaseFast -lc \
    --name smoke \
    -femit-bin="$BUILD/smoke_main.o" \
    smoke.zig

echo "[4/4] Link → $OUT/smoke"
clang -O2 -framework Metal -framework Foundation \
    "$BUILD/smoke_main.o" "$BUILD/metal_backend.o" \
    -o "$OUT/smoke"

echo ""
echo "▶ Running $OUT/smoke"
echo "------------------------------------------------------------"
"$OUT/smoke"

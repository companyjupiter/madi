#!/usr/bin/env bash
# build.sh — compile every kernel in kernels/ into whisper.metallib, then
# build+link a named Zig harness/binary against the ObjC bridge.
#
#   ./build.sh <zig_entry> [out_name]
# e.g.
#   ./build.sh test_conv1d.zig         → out/test_conv1d
#   ./build.sh sovereign_whisper.zig   → out/sovereign_whisper   (later milestones)
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"   # metal/

ENTRY="${1:-test_conv1d.zig}"
NAME="${2:-$(basename "$ENTRY" .zig)}"

BUILD=build
OUT=out
mkdir -p "$BUILD" "$OUT"

echo "[1/4] Compile kernels → whisper.metallib"
AIR=()
for m in kernels/*.metal; do
    [ "$(basename "$m")" = "smoke.metal" ] && continue   # smoke has its own lib
    base="$(basename "$m" .metal)"
    case "$base" in
        m4_*) STD=metal4.0 ;;   # Metal 4 tensor-ops kernels
        *)    STD=metal3.0 ;;
    esac
    xcrun metal -c "$m" -o "$BUILD/${base}.air" -std=$STD -Wall -Werror
    AIR+=("$BUILD/${base}.air")
done
xcrun metallib "${AIR[@]}" -o "$BUILD/whisper.metallib"
cp "$BUILD/whisper.metallib" whisper.metallib   # for @embedFile

echo "[2/4] Compile ObjC bridge → .o"
clang -c -fobjc-arc -O2 metal_backend.m -o "$BUILD/metal_backend.o"

echo "[3/4] Compile Zig ($ENTRY) → .o"
zig build-obj -O ReleaseFast -lc \
    --name "$NAME" \
    -femit-bin="$BUILD/${NAME}.o" \
    "$ENTRY"

echo "[4/4] Link → $OUT/$NAME"
clang -O2 -framework Metal -framework Foundation -framework MetalPerformanceShaders -framework Accelerate \
    "$BUILD/${NAME}.o" "$BUILD/metal_backend.o" \
    -o "$OUT/$NAME"

echo "✅ Built $OUT/$NAME"

#!/usr/bin/env bash
# build.sh — compile every kernel in kernels/ into whisper.metallib, then
# build+link a named Zig harness/binary against the ObjC bridge.
#
#   ./build.sh <zig_entry> [out_name]
# e.g.
#   ./build.sh test_conv1d.zig         → out/test_conv1d
#   ./build.sh sovereign_whisper.zig   → out/sovereign_whisper   (later milestones)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"   # metal/

ENTRY="${1:-test_conv1d.zig}"
NAME="${2:-$(basename "$ENTRY" .zig)}"
MACOS_MIN_VERSION="${MADI_MACOS_DEPLOYMENT_TARGET:-14.0}"

[[ "$MACOS_MIN_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || {
    echo "❌ invalid MADI_MACOS_DEPLOYMENT_TARGET: $MACOS_MIN_VERSION" >&2
    exit 1
}
case "$(uname -m)" in
    arm64)  ZIG_ARCH=aarch64 ;;
    x86_64) ZIG_ARCH=x86_64 ;;
    *) echo "❌ unsupported macOS architecture: $(uname -m)" >&2; exit 1 ;;
esac
ZIG_TARGET="$ZIG_ARCH-macos.$MACOS_MIN_VERSION"
export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN_VERSION"

BUILD=build
OUT=out
mkdir -p "$BUILD" "$OUT"

echo "[1/4] Compile kernels → whisper.metallib"
AIR=()
if xcrun metal -E -P -std=metal4.0 kernels/smoke.metal -o /dev/null \
    >/dev/null 2>&1; then
    METAL4_AVAILABLE=1
else
    METAL4_AVAILABLE=0
    echo "⚠️  Metal 4 compiler support unavailable; using the MPS encoder fallback"
fi
for m in kernels/*.metal; do
    [ "$(basename "$m")" = "smoke.metal" ] && continue   # smoke has its own lib
    base="$(basename "$m" .metal)"
    case "$base" in
        m4_*)
            [ "$METAL4_AVAILABLE" = 1 ] || {
                echo "   skip $m (requires Metal 4)"
                continue
            }
            STD=metal4.0
            ;;
        *)    STD=metal3.0 ;;
    esac
    xcrun metal -c "$m" -o "$BUILD/${base}.air" -std=$STD -Wall -Werror
    AIR+=("$BUILD/${base}.air")
done
xcrun metallib "${AIR[@]}" -o "$BUILD/whisper.metallib"
cp "$BUILD/whisper.metallib" whisper.metallib   # for @embedFile

echo "[2/4] Compile ObjC bridge → .o"
clang -c -fobjc-arc -O2 -mmacosx-version-min="$MACOS_MIN_VERSION" \
    -DMADI_HAS_MTL4_SDK="$METAL4_AVAILABLE" \
    metal_backend.m -o "$BUILD/metal_backend.o"

echo "[3/4] Compile Zig ($ENTRY) → .o"
zig build-obj -O ReleaseFast -lc \
    -target "$ZIG_TARGET" \
    --name "$NAME" \
    -femit-bin="$BUILD/${NAME}.o" \
    "$ENTRY"

echo "[4/4] Link → $OUT/$NAME"
clang -O2 -mmacosx-version-min="$MACOS_MIN_VERSION" \
    -framework Metal -framework Foundation -framework MetalPerformanceShaders -framework Accelerate \
    "$BUILD/${NAME}.o" "$BUILD/metal_backend.o" \
    -o "$OUT/$NAME"

ACTUAL_MIN="$(xcrun vtool -show-build "$OUT/$NAME" | awk '$1 == "minos" { print $2; exit }')"
[ "$ACTUAL_MIN" = "$MACOS_MIN_VERSION" ] || {
    echo "❌ $OUT/$NAME targets macOS $ACTUAL_MIN, expected $MACOS_MIN_VERSION" >&2
    exit 1
}

echo "✅ Built $OUT/$NAME (macOS $ACTUAL_MIN+)"

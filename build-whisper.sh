#!/bin/bash
set -euo pipefail

# ============================================================
#  Popy — Build the bundled speech-to-text engine
#
#  Produces a universal `vendor/whisper-cli` from whisper.cpp (MIT).
#  Transcription runs entirely on-device; this binary is the engine.
#
#  Two slices are built and lipo'd together:
#    arm64   — Metal GPU backend (Apple silicon)
#    x86_64  — CPU + Accelerate  (Intel Macs; ggml's Metal backend is
#              unreliable on Intel GPUs, and CPU is fast enough there)
#
#  Run this once. The result is cached in vendor/ and picked up
#  automatically by setup.sh and package.sh.
#
#  Usage:
#    bash build-whisper.sh            # build if missing
#    bash build-whisper.sh --force    # rebuild from scratch
# ============================================================

BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
RESET="\033[0m"

info()  { echo -e "${GREEN}[✓]${RESET} $1"; }
warn()  { echo -e "${YELLOW}[!]${RESET} $1"; }
fail()  { echo -e "${RED}[✗]${RESET} $1"; exit 1; }
step()  { echo -e "\n${BOLD}→ $1${RESET}"; }

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

VENDOR_DIR="$PROJECT_DIR/vendor"
OUTPUT="$VENDOR_DIR/whisper-cli"
WORK_DIR="$PROJECT_DIR/.whisper-build"
WHISPER_REPO="https://github.com/ggml-org/whisper.cpp.git"

# Pin the upstream tag so builds are reproducible and a surprise upstream
# change cannot silently alter the engine we ship.
WHISPER_TAG="v1.8.1"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

if [ -f "$OUTPUT" ] && [ "$FORCE" -eq 0 ]; then
    info "vendor/whisper-cli already present ($(lipo -archs "$OUTPUT" 2>/dev/null || echo unknown))"
    echo "  Use --force to rebuild."
    exit 0
fi

command -v cmake >/dev/null || fail "cmake not found. Install it: brew install cmake"
command -v git   >/dev/null || fail "git not found."

# --------------------------------------------------
# 1. Fetch source
# --------------------------------------------------
step "Fetching whisper.cpp $WHISPER_TAG..."

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
git clone --depth 1 --branch "$WHISPER_TAG" "$WHISPER_REPO" "$WORK_DIR/whisper.cpp" 2>&1 | tail -1
info "Source at $WHISPER_TAG"

cd "$WORK_DIR/whisper.cpp"

# --------------------------------------------------
# 2. Build each slice
# --------------------------------------------------
build_slice() {
    local arch="$1"
    local metal="$2"
    local dir="build-$arch"

    step "Building $arch slice (Metal=$metal)..."

    # CMAKE_SYSTEM_PROCESSOR must be forced: when cross-compiling to x86_64 on
    # an arm64 host it otherwise still reports arm64, and ggml emits ARM CPU
    # flags (-mcpu=apple-a12) for an Intel target, which fails to compile.
    #
    # GGML_NATIVE=OFF stops ggml tuning for *this* machine's CPU. Required for
    # a redistributable binary — a -mcpu=native build can emit instructions
    # that fault on a user's older hardware.
    cmake -B "$dir" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_SYSTEM_PROCESSOR="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
        -DGGML_NATIVE=OFF \
        -DGGML_METAL="$metal" \
        -DGGML_METAL_EMBED_LIBRARY=ON \
        -DWHISPER_BUILD_TESTS=OFF \
        -DWHISPER_BUILD_SERVER=OFF \
        -DBUILD_SHARED_LIBS=OFF \
        > /dev/null 2>&1 || fail "cmake configure failed for $arch"

    cmake --build "$dir" -j"$(sysctl -n hw.ncpu)" --target whisper-cli \
        > "$WORK_DIR/build-$arch.log" 2>&1 \
        || { tail -30 "$WORK_DIR/build-$arch.log"; fail "build failed for $arch (log: $WORK_DIR/build-$arch.log)"; }

    [ -f "$dir/bin/whisper-cli" ] || fail "whisper-cli not produced for $arch"
    info "$arch slice built"
}

# GGML_METAL_EMBED_LIBRARY bakes the shaders into the binary so there is no
# loose .metallib to ship alongside it.
build_slice "arm64"  "ON"
build_slice "x86_64" "OFF"

# --------------------------------------------------
# 3. Combine
# --------------------------------------------------
step "Creating universal binary..."

mkdir -p "$VENDOR_DIR"
lipo -create \
    "build-arm64/bin/whisper-cli" \
    "build-x86_64/bin/whisper-cli" \
    -output "$OUTPUT"
chmod +x "$OUTPUT"

info "Architectures: $(lipo -archs "$OUTPUT")"
info "Size: $(du -h "$OUTPUT" | awk '{print $1}')"

# Confirm we did not pick up any non-system dynamic dependency, which would
# break on a user's machine that lacks Homebrew.
step "Verifying linkage..."
# On a fat binary otool prints one "<path> (architecture X):" header per slice,
# so filter to tab-indented lines — those are the actual dependencies.
NONSYSTEM=$(otool -L "$OUTPUT" | grep $'^\t' | awk '{print $1}' | sort -u \
    | grep -vE '^(/System/|/usr/lib/)' || true)
if [ -n "$NONSYSTEM" ]; then
    warn "Non-system dynamic dependencies found — these will not exist on user machines:"
    echo "$NONSYSTEM"
else
    info "System frameworks only — safe to ship"
fi

cd "$PROJECT_DIR"
rm -rf "$WORK_DIR"

echo ""
echo -e "${BOLD}========================================${RESET}"
echo -e "${BOLD}  Engine ready: vendor/whisper-cli${RESET}"
echo -e "${BOLD}========================================${RESET}"
echo ""
echo "  Next: bash setup.sh    (bundles it into Popy.app)"
echo ""

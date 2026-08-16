#!/bin/bash
set -euo pipefail

# ============================================================
#  Popy — One-line installer
#  Downloads the latest release DMG, mounts it, and copies
#  Popy.app to /Applications.
#
#  Usage:
#    curl -fsSL https://raw.githubusercontent.com/anuragxxd/popy/master/install.sh | bash
# ============================================================

BOLD="\033[1m"
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
RESET="\033[0m"

info() { echo -e "${GREEN}[✓]${RESET} $1"; }
warn() { echo -e "${YELLOW}[!]${RESET} $1"; }
fail() { echo -e "${RED}[✗]${RESET} $1"; exit 1; }
step() { echo -e "\n${BOLD}→ $1${RESET}"; }

# Must be an if-block, NOT `[ -n "$X" ] && echo ...`.
#
# With that form, an unset POPY_DEBUG makes the test fail, `&&` short-circuits,
# and the function returns 1. Under `set -e` a function returning non-zero
# aborts the script — and because the first debug() call happens before any
# output, the installer died silently with exit 1 and printed nothing at all.
debug() {
    if [ -n "${POPY_DEBUG:-}" ]; then
        echo -e "${YELLOW}[debug]${RESET} $1"
    fi
}

# Anything that reaches users as `curl | bash` must never fail silently.
trap 'rc=$?; [ $rc -ne 0 ] && echo -e "\n${RED}[✗]${RESET} Install failed at line ${LINENO} (exit ${rc}). Re-run with POPY_DEBUG=1 for detail, or download the DMG from https://github.com/anuragxxd/popy/releases/latest" >&2; exit $rc' ERR

REPO="anuragxxd/popy"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
debug "TMP_DIR=$TMP_DIR"

# ── 1. Fetch latest release info ──────────────────────────
step "Finding latest Popy release..."

DMG_URL=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*\.dmg"' \
  | head -1 \
  | cut -d'"' -f4)

if [ -z "$DMG_URL" ]; then
    fail "Could not find a DMG in the latest release. Check https://github.com/${REPO}/releases"
fi

DMG_NAME=$(basename "$DMG_URL")
info "Found: $DMG_NAME"
debug "DMG_URL=$DMG_URL"

# ── 2. Download ───────────────────────────────────────────
step "Downloading $DMG_NAME..."

curl -fSL --progress-bar -o "$TMP_DIR/$DMG_NAME" "$DMG_URL"
info "Downloaded to $TMP_DIR/$DMG_NAME"

# ── 3. Mount & copy ──────────────────────────────────────
step "Installing Popy.app to /Applications..."

MOUNT_DIR="$TMP_DIR/mount"
INSTALL_DIR="/Applications"
SUDO=""
MOUNTED=0

mkdir -p "$MOUNT_DIR"

# Mount explicitly so we always know the path
MOUNT_ERR="$TMP_DIR/mount.err"
debug "Mounting DMG to $MOUNT_DIR"
if ! hdiutil attach "$TMP_DIR/$DMG_NAME" -nobrowse -quiet -mountpoint "$MOUNT_DIR" 2>"$MOUNT_ERR"; then
    fail "Failed to mount DMG: $(cat "$MOUNT_ERR")"
fi
MOUNTED=1
debug "Mounted DMG"

if [ ! -d "$MOUNT_DIR" ]; then
    fail "Mountpoint not found: $MOUNT_DIR"
fi

debug "Checking for $MOUNT_DIR/Popy.app"
if [ ! -d "$MOUNT_DIR/Popy.app" ]; then
    hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true
    fail "Popy.app not found inside DMG."
fi

# Use sudo if /Applications is not writable
if [ ! -w "$INSTALL_DIR" ]; then
    SUDO="sudo"
    warn "/Applications is not writable. You'll be prompted for your password."
fi

# Remove old version if present
if [ -d "$INSTALL_DIR/Popy.app" ]; then
    $SUDO rm -rf "$INSTALL_DIR/Popy.app"
    info "Removed previous version"
fi

$SUDO cp -R "$MOUNT_DIR/Popy.app" "$INSTALL_DIR/"
if [ $MOUNTED -eq 1 ]; then
    hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true
fi
info "Installed to $INSTALL_DIR/Popy.app"

# ── 4. Launch ─────────────────────────────────────────────
step "Launching Popy..."
open /Applications/Popy.app
info "Popy is running in your menu bar"

echo ""
echo -e "${BOLD}Done!${RESET} Look for the clipboard icon in the top-right of your screen."
echo ""

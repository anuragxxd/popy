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
RESET="\033[0m"

info() { echo -e "${GREEN}[✓]${RESET} $1"; }
fail() { echo -e "${RED}[✗]${RESET} $1"; exit 1; }
step() { echo -e "\n${BOLD}→ $1${RESET}"; }

REPO="anuragxxd/popy"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

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

# ── 2. Download ───────────────────────────────────────────
step "Downloading $DMG_NAME..."

curl -fSL --progress-bar -o "$TMP_DIR/$DMG_NAME" "$DMG_URL"
info "Downloaded to $TMP_DIR/$DMG_NAME"

# ── 3. Mount & copy ──────────────────────────────────────
step "Installing Popy.app to /Applications..."

MOUNT_DIR=$(hdiutil attach "$TMP_DIR/$DMG_NAME" -nobrowse -quiet 2>&1 | grep "/Volumes/" | sed 's/.*\/Volumes/\/Volumes/')

if [ -z "$MOUNT_DIR" ] || [ ! -d "$MOUNT_DIR" ]; then
    fail "Failed to mount DMG."
fi

if [ ! -d "$MOUNT_DIR/Popy.app" ]; then
    hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true
    fail "Popy.app not found inside DMG."
fi

# Remove old version if present
if [ -d "/Applications/Popy.app" ]; then
    rm -rf "/Applications/Popy.app"
    info "Removed previous version"
fi

cp -R "$MOUNT_DIR/Popy.app" /Applications/
hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true
info "Installed to /Applications/Popy.app"

# ── 4. Launch ─────────────────────────────────────────────
step "Launching Popy..."
open /Applications/Popy.app
info "Popy is running in your menu bar"

echo ""
echo -e "${BOLD}Done!${RESET} Look for the clipboard icon in the top-right of your screen."
echo ""

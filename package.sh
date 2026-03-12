#!/bin/bash
set -euo pipefail

# ============================================================
#  Popy — Package into a distributable DMG
#  Creates a DMG with Popy.app and an Applications symlink
#  so users can drag-to-install.
#
#  Usage:
#    bash package.sh                     # uses default build path
#    bash package.sh /path/to/Popy.app   # use a specific .app
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

# --------------------------------------------------
# 1. Locate Popy.app
# --------------------------------------------------
step "Locating Popy.app..."

if [ -n "${1:-}" ] && [ -d "$1" ]; then
    APP_PATH="$1"
elif [ -d "build/Build/Products/Release/Popy.app" ]; then
    APP_PATH="build/Build/Products/Release/Popy.app"
else
    FOUND_APP=$(find build -name "Popy.app" -type d 2>/dev/null | head -1)
    if [ -n "${FOUND_APP:-}" ]; then
        APP_PATH="$FOUND_APP"
    else
        fail "Popy.app not found. Run 'bash setup.sh' first to build the app."
    fi
fi

info "Found: $APP_PATH"

# Read version from Info.plist
APP_VERSION=$(defaults read "$PROJECT_DIR/$APP_PATH/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "1.0.0")
info "Version: $APP_VERSION"

# --------------------------------------------------
# 2. Prepare staging directory
# --------------------------------------------------
step "Preparing DMG contents..."

DMG_NAME="Popy-${APP_VERSION}"
STAGING_DIR="$PROJECT_DIR/.dmg-staging"
DMG_TEMP="$PROJECT_DIR/${DMG_NAME}-temp.dmg"
DMG_FINAL="$PROJECT_DIR/${DMG_NAME}.dmg"

# Clean previous artifacts
rm -rf "$STAGING_DIR"
rm -f "$DMG_TEMP" "$DMG_FINAL"

mkdir -p "$STAGING_DIR"

# Copy the app
cp -R "$APP_PATH" "$STAGING_DIR/Popy.app"
info "Copied Popy.app"

# Create Applications symlink (drag-to-install target)
ln -s /Applications "$STAGING_DIR/Applications"
info "Created Applications symlink"

# Add a simple README
cat > "$STAGING_DIR/README.txt" << 'EOF'
Popy — Clipboard History Manager
=================================

Installation:
  Drag "Popy.app" into the "Applications" folder.

Usage:
  - Popy lives in your menu bar (top-right of screen).
  - Click the clipboard icon to see your copy history.
  - Click any item to copy it back to your clipboard.
  - Toggle "Launch at Login" to start Popy automatically.

To uninstall:
  - Quit Popy from the menu bar (click icon → Quit Popy).
  - Drag Popy.app from Applications to Trash.
EOF
info "Added README.txt"

# --------------------------------------------------
# 3. Create DMG
# --------------------------------------------------
step "Creating DMG..."

# Create a writable DMG first
hdiutil create \
    -srcfolder "$STAGING_DIR" \
    -volname "Popy" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    "$DMG_TEMP" \
    -quiet

info "Created writable DMG"

# Mount it to apply Finder view settings
MOUNT_DIR=$(hdiutil attach "$DMG_TEMP" -readwrite -noverify -noautoopen 2>&1 | grep "/Volumes/" | sed 's/.*\/Volumes/\/Volumes/')

if [ -n "$MOUNT_DIR" ] && [ -d "$MOUNT_DIR" ]; then
    info "Mounted at: $MOUNT_DIR"

    # Apply Finder window layout (skipped in CI — requires GUI session)
    if [ -z "${CI:-}" ] && [ -z "${GITHUB_ACTIONS:-}" ]; then
        osascript << APPLESCRIPT 2>/dev/null && info "Applied Finder layout" || warn "Finder layout skipped (no GUI)"
        tell application "Finder"
            tell disk "Popy"
                open
                set current view of container window to icon view
                set toolbar visible of container window to false
                set statusbar visible of container window to false
                set bounds of container window to {100, 100, 640, 400}
                set viewOptions to the icon view options of container window
                set arrangement of viewOptions to not arranged
                set icon size of viewOptions to 80
                set position of item "Popy.app" of container window to {140, 140}
                set position of item "Applications" of container window to {400, 140}
                set position of item "README.txt" of container window to {270, 260}
                close
                open
                update without registering applications
                delay 2
                close
            end tell
        end tell
APPLESCRIPT
    else
        info "CI detected — skipping Finder layout (DMG still works fine)"
    fi

    # Unmount
    hdiutil detach "$MOUNT_DIR" -quiet -force 2>/dev/null || true
    sleep 1
else
    warn "Could not mount DMG for layout customization (DMG will still work fine)"
fi

# Convert to compressed read-only DMG
hdiutil convert \
    "$DMG_TEMP" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_FINAL" \
    -quiet

info "Compressed to read-only DMG"

# Clean up
rm -f "$DMG_TEMP"
rm -rf "$STAGING_DIR"
info "Cleaned up temp files"

# --------------------------------------------------
# 4. Generate checksum
# --------------------------------------------------
step "Generating SHA-256 checksum..."

CHECKSUM=$(shasum -a 256 "$DMG_FINAL" | awk '{print $1}')
echo "$CHECKSUM  ${DMG_NAME}.dmg" > "$PROJECT_DIR/${DMG_NAME}.dmg.sha256"
info "Checksum: $CHECKSUM"

# --------------------------------------------------
# 5. Done
# --------------------------------------------------
DMG_SIZE=$(du -h "$DMG_FINAL" | awk '{print $1}')

echo ""
echo -e "${BOLD}========================================${RESET}"
echo -e "${BOLD}  DMG packaged successfully!${RESET}"
echo -e "${BOLD}========================================${RESET}"
echo ""
echo "  File:      $DMG_FINAL"
echo "  Size:      $DMG_SIZE"
echo "  Checksum:  ${DMG_NAME}.dmg.sha256"
echo ""
echo "  Share this DMG with users. They open it,"
echo "  drag Popy.app to Applications, and they're done."
echo ""

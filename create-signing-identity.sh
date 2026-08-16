#!/bin/bash
set -euo pipefail

# ============================================================
#  Popy — Create a stable local code-signing identity
#
#  WHY THIS EXISTS
#
#  macOS TCC (the permissions database) does not record "app X is
#  allowed". It records a *code signature requirement*. For an ad-hoc
#  signed app (`codesign -s -`) that requirement is a content hash:
#
#      cdhash H"401f2025..." or cdhash H"59f1654e..."
#
#  The cdhash is derived from the binary's contents, so it changes on
#  every single rebuild. The moment you rebuild, the stored requirement
#  no longer matches and TCC silently revokes the grant.
#
#  The failure mode is genuinely nasty: System Settings still shows the
#  app ticked (that list is keyed on bundle identifier), while
#  AXIsProcessTrusted() returns false and CGEvent.post() becomes a
#  silent no-op. Paste stops working with no error anywhere.
#
#  Signing with a real certificate — even a self-signed one — changes
#  the requirement to:
#
#      identifier "com.popy.app" and certificate root = H"<cert hash>"
#
#  That is tied to the certificate, not the binary, so it survives every
#  rebuild. Grant Accessibility once and it stays granted.
#
#  Run this once. setup.sh picks the identity up automatically.
#
#  To undo:  bash create-signing-identity.sh --remove
# ============================================================

BOLD="\033[1m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"; RED="\033[0;31m"; RESET="\033[0m"
info()  { echo -e "${GREEN}[✓]${RESET} $1"; }
warn()  { echo -e "${YELLOW}[!]${RESET} $1"; }
fail()  { echo -e "${RED}[✗]${RESET} $1"; exit 1; }
step()  { echo -e "\n${BOLD}→ $1${RESET}"; }

IDENTITY_NAME="Popy Local Code Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# ------------------------------------------------------------
# Removal
# ------------------------------------------------------------
if [ "${1:-}" = "--remove" ]; then
    step "Removing '$IDENTITY_NAME'..."
    security delete-identity -c "$IDENTITY_NAME" "$KEYCHAIN" 2>/dev/null \
        && info "Identity removed" || warn "No identity found to remove"
    echo ""
    echo "  Popy will fall back to ad-hoc signing on the next: bash setup.sh"
    exit 0
fi

# ------------------------------------------------------------
# Already present?
# ------------------------------------------------------------
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    info "'$IDENTITY_NAME' already exists — nothing to do."
    security find-identity -v -p codesigning | grep "$IDENTITY_NAME"
    exit 0
fi

command -v openssl >/dev/null || fail "openssl not found."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ------------------------------------------------------------
# 1. Generate a self-signed code-signing certificate
# ------------------------------------------------------------
step "Generating certificate..."

# extendedKeyUsage=codeSigning is mandatory — without it the identity is
# created but `security find-identity -p codesigning` will not list it,
# and codesign cannot resolve it by name.
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$WORK/popy.key" -out "$WORK/popy.crt" -days 7300 \
    -subj "/CN=$IDENTITY_NAME/O=Popy/C=US" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    >/dev/null 2>&1 || fail "Certificate generation failed"

info "Certificate generated (valid 20 years)"

# ------------------------------------------------------------
# 2. Bundle into a PKCS#12 macOS can actually read
# ------------------------------------------------------------
step "Packaging key..."

# -legacy is required with OpenSSL 3.x. Without it the archive uses a
# SHA-256 MAC that macOS's Security framework cannot verify, and the
# import fails with the misleading "MAC verification failed (wrong
# password?)" even when the password is correct.
openssl pkcs12 -export -legacy \
    -out "$WORK/popy.p12" \
    -inkey "$WORK/popy.key" -in "$WORK/popy.crt" \
    -passout pass:popy -name "$IDENTITY_NAME" \
    >/dev/null 2>&1 || fail "PKCS#12 packaging failed"

info "Packaged"

# ------------------------------------------------------------
# 3. Import and trust
# ------------------------------------------------------------
step "Importing into your login keychain..."

security import "$WORK/popy.p12" -k "$KEYCHAIN" -P "popy" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null 2>&1 \
    || fail "Keychain import failed"

info "Imported"

# User-domain trust only. The system domain would need sudo, and code
# signing for local development does not require it.
step "Trusting for code signing..."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" \
    "$WORK/popy.crt" >/dev/null 2>&1 \
    && info "Trusted" || warn "Trust step reported an issue — continuing"

# Let codesign use the private key without a GUI prompt each build.
# Best-effort: needs the login keychain password, so it may not apply.
# If it does not, macOS shows an "allow access" dialog on first sign —
# click "Always Allow" once.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

# ------------------------------------------------------------
# 4. Verify
# ------------------------------------------------------------
step "Verifying..."

if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    fail "Identity is not visible to codesign. Try Keychain Access → Certificate Assistant instead."
fi

security find-identity -v -p codesigning | grep "$IDENTITY_NAME"
info "Identity is valid for code signing"

echo ""
echo -e "${BOLD}========================================${RESET}"
echo -e "${BOLD}  Signing identity ready${RESET}"
echo -e "${BOLD}========================================${RESET}"
echo ""
echo "  Next:"
echo "    1. bash setup.sh          (rebuilds Popy signed with this identity)"
echo "    2. cp -R build/Build/Products/Release/Popy.app /Applications/"
echo "    3. System Settings → Privacy & Security → Accessibility"
echo "       Remove Popy with the '−' button, then add it back."
echo ""
echo "  Step 3 is needed once, to replace the stale cdhash-based entry."
echo "  After that the grant persists across every rebuild."
echo ""

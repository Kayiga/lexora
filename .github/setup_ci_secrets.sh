#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Lexora — GitHub Actions CI Secrets Setup
# Run this ONCE after:
#   1. Creating the GitHub repo (github.com/kayiga/lexora)
#   2. Running: gh auth login
#   3. Obtaining a paid Apple Developer account
#
# Usage:
#   chmod +x .github/setup_ci_secrets.sh
#   ./.github/setup_ci_secrets.sh
#
# The script will STOP and tell you exactly what to do if a step requires
# external input (developer portal, App Store Connect, Keychain, etc.)
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail
REPO="kayiga/lexora"
TEAM_ID="7AZTZL9VAG"

# ── Pre-generated passwords (safe to keep in this script — they're just
#    local keychain passwords, not Apple/GitHub credentials) ──────────────────
CERT_PASS="kcqThpnRU8xvlN6HS56ohqnCuzc="
KS_PASS="0MXiBGAvago+mE5yNMEmmkcva4w="

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GRN}✅ $1${NC}"; }
warn() { echo -e "${YLW}⚠️  $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; exit 1; }
step() { echo -e "\n${YLW}──── Step $1 ────${NC}"; }

# ── 0. Preflight checks ───────────────────────────────────────────────────────
step "0 — Preflight"
command -v gh   >/dev/null || fail "gh CLI not found. Run: brew install gh"
command -v base64 >/dev/null || fail "base64 not found"
gh auth status  >/dev/null 2>&1 || fail "Not logged into GitHub CLI. Run: gh auth login"
ok "gh CLI authenticated"

CURRENT_REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
if [[ "$CURRENT_REPO" != "$REPO" ]]; then
    warn "cd into the repo root first OR make sure the repo exists at github.com/$REPO"
fi

# ── Helper to set a secret ────────────────────────────────────────────────────
set_secret() {
    local name="$1" value="$2"
    echo -n "  Setting $name … "
    printf '%s' "$value" | gh secret set "$name" --repo "$REPO" --body -
    ok "done"
}

# ── 1. APPLE_TEAM_ID (known) ─────────────────────────────────────────────────
step "1 — APPLE_TEAM_ID"
set_secret "APPLE_TEAM_ID" "$TEAM_ID"

# ── 2. Generated passwords ───────────────────────────────────────────────────
step "2 — Generated passwords"
set_secret "BUILD_CERTIFICATE_PASSWORD" "$CERT_PASS"
set_secret "KEYCHAIN_PASSWORD"          "$KS_PASS"

# ── 3. Distribution certificate ─────────────────────────────────────────────
step "3 — Distribution certificate (BUILD_CERTIFICATE_BASE64)"
echo ""
echo "  You need an 'Apple Distribution' certificate (requires paid account)."
echo ""
echo "  To create one:"
echo "    Xcode → Settings → Accounts → Manage Certificates → + → Apple Distribution"
echo "  Then export it:"
echo "    Keychain Access → My Certificates → right-click 'Apple Distribution: …'"
echo "    → Export … → .p12 format → password: $CERT_PASS"
echo ""
read -rp "  Path to the exported .p12 file: " P12_PATH
[[ -f "$P12_PATH" ]] || fail "File not found: $P12_PATH"

CERT_B64=$(base64 -i "$P12_PATH")
set_secret "BUILD_CERTIFICATE_BASE64" "$CERT_B64"
ok "Certificate encoded and uploaded ($(wc -c < "$P12_PATH" | tr -d ' ') bytes)"

# ── 4. Provisioning profile ──────────────────────────────────────────────────
step "4 — Provisioning profile (BUILD_PROVISION_PROFILE_BASE64)"
echo ""
echo "  Download an 'App Store' distribution profile for com.yiga.Lexora from:"
echo "    developer.apple.com → Certificates, IDs & Profiles → Profiles"
echo "    → + → Distribution → App Store → Bundle ID: com.yiga.Lexora"
echo "  Download the .mobileprovision file."
echo ""
read -rp "  Path to the .mobileprovision file: " PROFILE_PATH
[[ -f "$PROFILE_PATH" ]] || fail "File not found: $PROFILE_PATH"

PROFILE_B64=$(base64 -i "$PROFILE_PATH")
set_secret "BUILD_PROVISION_PROFILE_BASE64" "$PROFILE_B64"
ok "Profile encoded and uploaded ($(wc -c < "$PROFILE_PATH" | tr -d ' ') bytes)"

# ── 5. App Store Connect API key ─────────────────────────────────────────────
step "5 — App Store Connect API key"
echo ""
echo "  Create an API key at:"
echo "    App Store Connect → Users and Access → Integrations → App Store Connect API"
echo "    → + → Name: 'Lexora CI', Role: Developer"
echo "  Note the Key ID and Issuer ID shown on that page."
echo "  Download the .p8 file (you can only download it once)."
echo ""
read -rp "  Key ID (e.g. ABC123DEFG): " ASC_KEY_ID
read -rp "  Issuer ID (UUID format): "  ASC_ISSUER_ID
read -rp "  Path to the AuthKey_*.p8 file: " P8_PATH
[[ -f "$P8_PATH" ]] || fail "File not found: $P8_PATH"

ASC_KEY_B64=$(base64 -i "$P8_PATH")
set_secret "APP_STORE_CONNECT_KEY_ID"        "$ASC_KEY_ID"
set_secret "APP_STORE_CONNECT_ISSUER_ID"     "$ASC_ISSUER_ID"
set_secret "APP_STORE_CONNECT_API_KEY_BASE64" "$ASC_KEY_B64"

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GRN}════════════════════════════════════════════${NC}"
echo -e "${GRN}  All 8 secrets set on kayiga/lexora ✅${NC}"
echo -e "${GRN}════════════════════════════════════════════${NC}"
echo ""
echo "  Trigger the first build:"
echo "    git tag v1.0.0 && git push origin v1.0.0"
echo ""
echo "  Then watch it at: https://github.com/kayiga/lexora/actions"

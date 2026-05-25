# Lexora CI/CD Setup

Two-job pipeline in `.github/workflows/testflight.yml`:

| Job | Trigger | What it does |
|---|---|---|
| **build-and-test** | Every push to `main` | Compiles all 3 targets (no signing, no simulator) |
| **release** | `v*` tags or manual dispatch with `full_pipeline=true` | Signs → archives → exports IPA → uploads to TestFlight |

---

## Required GitHub Secrets

Go to **GitHub → Repository → Settings → Secrets and variables → Actions → New repository secret**.

| Secret name | How to get it |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | Export your **Apple Distribution** certificate from Keychain Access as `.p12`, then `base64 -i cert.p12 \| pbcopy` |
| `BUILD_CERTIFICATE_PASSWORD` | The password you set when exporting the `.p12` |
| `BUILD_PROVISION_PROFILE_BASE64` | Download the **App Store** provisioning profile from developer.apple.com → Profiles, then `base64 -i Lexora_AppStore.mobileprovision \| pbcopy` |
| `KEYCHAIN_PASSWORD` | Any strong random string — `openssl rand -base64 20` |
| `APP_STORE_CONNECT_KEY_ID` | Key ID from App Store Connect → Users → Integrations → API Keys |
| `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID from the same page (a UUID) |
| `APP_STORE_CONNECT_API_KEY_BASE64` | Contents of the `.p8` file, base64 encoded: `base64 -i AuthKey_XXXX.p8 \| pbcopy` |
| `APPLE_TEAM_ID` | Your 10-character Apple Developer Team ID (visible on developer.apple.com) |

**Shortcut:** run the interactive setup script (pre-fills 3 of 8 secrets automatically):

```bash
.github/setup_ci_secrets.sh
```

---

## One-time Xcode setup (after paid account)

1. In Xcode → Signing & Capabilities → set **Manual** signing for **Release** on all 3 targets.
2. Provisioning profile names must match `ExportOptions.plist`:
   - Main app: `"Lexora App Store"`
   - Widget:   `"Lexora Widget App Store"`
   - Keyboard: `"Lexora Keyboard App Store"`
3. Register App Group `group.com.yiga.Lexora` on developer.apple.com → Identifiers → App Groups.
4. Make sure the scheme is Shared: Product → Scheme → Manage Schemes → ✓ Shared (already done).

---

## Trigger a build

```bash
# First TestFlight build:
git tag v1.0.1 && git push origin v1.0.1

# Future builds increment the patch version:
git tag v1.0.2 && git push origin v1.0.2
```

Or: **Actions → Build & Upload to TestFlight → Run workflow → full_pipeline: true**

---

## Artifacts

On success:
- `Lexora-<tag>.ipa` — exported IPA (retained 14 days)

On failure:
- `Lexora-archive-<tag>` — `.xcarchive` for debugging (retained 3 days)

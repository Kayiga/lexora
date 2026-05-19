# Lexora CI/CD Setup

The `testflight.yml` workflow builds and uploads to TestFlight on every push to `main`
and on every `v*` tag. It also runs on manual dispatch from the Actions tab.

---

## Required GitHub Secrets

Go to **GitHub → Repository → Settings → Secrets and variables → Actions → New repository secret**.

| Secret name | How to get it |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | Export your **Apple Distribution** certificate from Keychain Access as `.p12`, then run `base64 -i cert.p12 \| pbcopy` |
| `BUILD_CERTIFICATE_PASSWORD` | The password you set when exporting the `.p12` |
| `BUILD_PROVISION_PROFILE_BASE64` | Download the **App Store** provisioning profile from developer.apple.com → Profiles, then `base64 -i Lexora_AppStore.mobileprovision \| pbcopy` |
| `KEYCHAIN_PASSWORD` | Any strong random string (e.g. `openssl rand -base64 20`) |
| `APP_STORE_CONNECT_KEY_ID` | Key ID from App Store Connect → Users → Integrations → API Keys |
| `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID from the same page (a UUID) |
| `APP_STORE_CONNECT_API_KEY_BASE64` | Contents of the `.p8` file, base64 encoded: `base64 -i AuthKey_XXXX.p8 \| pbcopy` |
| `APPLE_TEAM_ID` | Your 10-character Apple Developer Team ID (visible on developer.apple.com) |

---

## One-time Xcode setup

1. In Xcode → Signing & Capabilities, set **Signing → Manual** for the Release configuration.
2. Set the provisioning profile to **"Lexora App Store"** (must match the name in `ExportOptions.plist`).
3. Make sure the scheme is set to **Shared** (Product → Scheme → Manage Schemes → ✓ Shared).

---

## Trigger a build

```bash
git tag v2.0.0
git push origin v2.0.0
```

Or go to **Actions → Build & Upload to TestFlight → Run workflow**.

---

## Artifacts

Every run uploads:
- `Lexora-archive` — the full `.xcarchive` (kept 7 days, useful for dSYMs and crash symbolication)
- `test-results` — the `.xcresult` bundle and JUnit XML report

---

## xcpretty

The workflow uses `xcpretty` for readable build logs. It is installed automatically via:
```bash
gem install xcpretty
```
If you use a self-hosted runner, install it once and it is cached between runs.

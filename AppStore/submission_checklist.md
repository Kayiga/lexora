# Lexora — App Store Submission Checklist

## ✅ Done (generated automatically)

### Code & Project
- [x] 36 Swift source files across 3 targets (Lexora, LexoraWidget, LexoraKeyboard)
- [x] `Lexora.xcodeproj` — all files wired, 3 targets configured, Swift 5 language mode
- [x] `PrivacyInfo.xcprivacy` — Apple required privacy manifest with correct reason codes
- [x] All 3 entitlements files — App Group `group.com.yiga.Lexora` in all targets
- [x] `LexoraStore.storekit` — Simulator IAP testing config (product: `com.yiga.Lexora.premium`)
- [x] StoreKit config wired into Xcode scheme (auto-activated in Simulator)
- [x] All 4 Info.plist files validated (`plutil -lint` passes)
- [x] Widget: 6 sizes (small, medium, large, circular, rectangular, inline) + Live Activity + Dynamic Island
- [x] Keyboard extension: `RequestsOpenAccess = true`, correct `NSExtensionPrincipalClass`
- [x] URL scheme `lexora://` in main app Info.plist
- [x] Deep link handling: `lexora://record`, `lexora://history`, `lexora://profile`, `lexora://session/{uuid}`
- [x] `pushWidgetData()` writes to shared `UserDefaults(suiteName: "group.com.yiga.Lexora")`

### CI/CD
- [x] `.github/workflows/testflight.yml` — 12-step pipeline: build → test → archive → export → upload
- [x] `.github/CI_SETUP.md` — exact commands to generate all 8 required secrets

### App Store Assets
- [x] `AppStore/metadata.md` — description, subtitle, keywords, promotional text, what's new, review notes, IAP details
- [x] `AppStore/privacy_policy.md` — privacy policy ready to publish
- [x] `docs/privacy.html` — self-contained dark-mode HTML ready for GitHub Pages
- [x] `docs/index.html` — root redirect → privacy page
- [x] `AppStoreScreenshots.swift` — 5 preview frames, export via Xcode canvas

---

## 🔧 You need to do (one-time, ~30 minutes)

### Xcode (5 minutes)
- [ ] **Add iCloud / CloudKit capability** *(requires paid Apple Developer account — $99/yr)*
  > iCloud/CloudKit is not available on Personal Teams. The app ships and runs without it;
  > `CloudSyncService` gracefully no-ops when iCloud is unavailable.
  > When you upgrade your account:
  1. Select Lexora target → Signing & Capabilities → `+` → iCloud
  2. Enable CloudKit, add container `iCloud.com.yiga.Lexora`
  3. Xcode creates the container in App Store Connect automatically

- [ ] **Register App Group in Apple Developer Portal** (if not already done)
  1. developer.apple.com → Certificates, IDs & Profiles → Identifiers → App Groups
  2. Add `group.com.yiga.Lexora`
  3. Add this group to all 3 App IDs (`com.yiga.Lexora`, `com.yiga.Lexora.Widget`, `com.yiga.Lexora.Keyboard`)

- [ ] **Test a build on device** — `⌘R` on a real iPhone, complete onboarding, record one session

### App Store Connect (15 minutes)
- [ ] Create a new app (Bundle ID: `com.yiga.Lexora`)
- [ ] Copy/paste fields from `AppStore/metadata.md`
- [ ] Create IAP product: Non-Consumable, Product ID `com.yiga.Lexora.premium`, price Tier 5 ($4.99)
- [ ] Upload screenshots exported from Xcode (5 frames, see `AppStoreScreenshots.swift`)
- [ ] Add Privacy Policy URL — `docs/privacy.html` is ready for GitHub Pages
  > In your repo: Settings → Pages → Source: `main` branch, `/docs` folder → Save
  > URL will be: `https://YOUR_USERNAME.github.io/lexora/privacy.html`

### GitHub Secrets (10 minutes, required for CI)
Follow `.github/CI_SETUP.md` — add all 8 secrets to your repo Settings → Secrets → Actions:

| Secret | Time to get |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | 2 min — export from Keychain Access |
| `BUILD_CERTIFICATE_PASSWORD` | 0 min — you set this |
| `BUILD_PROVISION_PROFILE_BASE64` | 3 min — download from developer.apple.com |
| `KEYCHAIN_PASSWORD` | 0 min — run `openssl rand -base64 20` |
| `APP_STORE_CONNECT_KEY_ID` | 2 min — App Store Connect → Integrations → API Keys |
| `APP_STORE_CONNECT_ISSUER_ID` | 0 min — same page |
| `APP_STORE_CONNECT_API_KEY_BASE64` | 1 min — download .p8, run `base64 -i AuthKey.p8` |
| `APPLE_TEAM_ID` | 0 min — already known: `7AZTZL9VAG` |

### Trigger first TestFlight build
```bash
cd "/Users/yiga/Documents/Personal/The World of AI/Claude WorkSpace/Outputs/LinguaFlow"
git init && git add . && git commit -m "Initial commit"
git remote add origin https://github.com/YOUR_USERNAME/lexora.git
git push -u origin main
git tag v1.0.0 && git push origin v1.0.0
```
CI will build → test → archive → upload to TestFlight automatically.

---

## 📋 Upgrade path (after launch)

When you upgrade to a **paid Apple Developer account ($99/yr)**:
- Add iCloud capability → CloudKit sync activates (code already complete in `CloudSyncService`)
- Re-add `com.apple.developer.siri` entitlement → Siri Shortcuts become available system-wide
- Re-add `com.apple.developer.associated-domains` → Universal Links work
- Submit v1.1 with new capabilities (no code changes needed — the features are already built)

---

## 📊 Current project stats

| Metric | Count |
|---|---|
| Swift source files | 36 |
| Total lines of Swift | ~18,000 |
| Targets | 3 |
| Widget sizes | 6 |
| App features (free) | 14 |
| App features (premium) | 8 |
| CI pipeline steps | 12 |
| Validated plist files | 4 |

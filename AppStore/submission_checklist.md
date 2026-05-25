# Lexora — App Store Submission Checklist

## ✅ Done

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
- [x] **Archive build validated** — `xcodebuild archive` exits 0, 32 MB `.xcarchive` produced (v1.0 build 1)

### CI/CD
- [x] `.github/workflows/testflight.yml` — 12-step pipeline: build → test → archive → export → upload
- [x] `.github/CI_SETUP.md` — exact commands to generate all 8 required secrets
- [x] `.github/setup_ci_secrets.sh` — interactive script, pre-fills 3 of 8 secrets automatically

### App Store Assets
- [x] `AppStore/metadata.md` — description, subtitle, keywords, promotional text, what's new, review notes, IAP details
- [x] `AppStore/privacy_policy.md` — privacy policy source
- [x] `docs/privacy.html` — dark-mode HTML, **live at https://kayiga.github.io/lexora/privacy.html** ✅
- [x] `docs/index.html` — root redirect → privacy page
- [x] 5 App Store screenshots — `AppStore/Screenshots/` (1.4–1.9 MB each, **1290×2796 6.7" iPhone** — correct App Store format)
- [x] iPhone-only app (`TARGETED_DEVICE_FAMILY = 1`) — no iPad screenshots required

### GitHub
- [x] Repo live: **https://github.com/Kayiga/lexora** (public)
- [x] All 67 files pushed, tag `v1.0.0` pushed
- [x] GitHub Pages enabled → privacy policy serving HTTP 200
- [x] `gh` CLI authenticated with `repo` + `workflow` scopes

---

## 🔧 You need to do (one-time, ~30 minutes)

### Step 1 — Upgrade to Paid Apple Developer Account ($99/yr)
> Required for everything below. Without it: no Distribution cert, no App Store, no TestFlight.
> Enroll at: **developer.apple.com/enroll**

### Step 2 — Xcode capabilities (5 min, after paid account)
- [ ] **Register App Group** — developer.apple.com → Identifiers → App Groups → `group.com.yiga.Lexora`
  Add to all 3 App IDs: `com.yiga.Lexora`, `com.yiga.Lexora.Widget`, `com.yiga.Lexora.Keyboard`
- [ ] **Add iCloud/CloudKit** — Xcode → Lexora target → Signing & Capabilities → `+` → iCloud → container `iCloud.com.yiga.Lexora`
- [ ] **Test on device** — `⌘R` on real iPhone, complete onboarding, record one session

### Step 3 — App Store Connect (15 min)
- [ ] Create new app → Bundle ID: `com.yiga.Lexora`, Name: **Lexora**
- [ ] Copy/paste all fields from `AppStore/metadata.md`
- [ ] Upload 5 screenshots from `AppStore/Screenshots/`
- [ ] Privacy Policy URL: **`https://kayiga.github.io/lexora/privacy.html`** ← live now ✅
- [ ] Support URL: **`https://github.com/Kayiga/lexora/issues`**
- [ ] Create IAP: Non-Consumable · ID `com.yiga.Lexora.premium` · Tier 5 ($4.99)

### Step 4 — CI Secrets (10 min)
```bash
cd "/Users/yiga/Documents/Personal/The World of AI/Claude WorkSpace/Outputs/LinguaFlow"
./.github/setup_ci_secrets.sh
```
The script walks you through each of the 8 secrets step by step. 3 are pre-filled (team ID + 2 passwords).

### Step 5 — Trigger first TestFlight build
```bash
cd "/Users/yiga/Documents/Personal/The World of AI/Claude WorkSpace/Outputs/LinguaFlow"
git tag v1.0.1 && git push origin v1.0.1
```
CI builds → archives → uploads to TestFlight. Watch at: **https://github.com/Kayiga/lexora/actions**

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

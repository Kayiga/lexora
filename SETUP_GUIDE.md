# Lexora — Setup Guide

## What you have

A complete iOS voice-dictation app — 37 Swift files, 3 targets, a full CI/CD pipeline,
App Store screenshots, and a ready-to-open Xcode project.

| File count | Targets | Minimum iOS |
|---|---|---|
| 37 Swift files | Lexora · LexoraWidget · LexoraKeyboard | iOS 18.0 |

---

## Step 1 — Open the project

```bash
open "Lexora.xcodeproj"
```

Xcode will resolve Swift Package dependencies automatically on first open.
No CocoaPods, no Carthage.

---

## Step 2 — Set your Team ID

Your Apple Developer Team ID (`7AZTZL9VAG`) is already baked into the project.
If you need to change it, update it in all three targets under
**Signing & Capabilities → Team**, or do a project-wide find-replace of
`7AZTZL9VAG`.

---

## Step 3 — Configure iCloud / CloudKit

In Xcode → main **Lexora** target → **Signing & Capabilities**:

1. Add capability: **iCloud**
2. Enable **CloudKit**
3. Add container: `iCloud.com.yiga.Lexora`

> This step cannot be scripted — you must do it manually in Xcode.
> Xcode will create the container in App Store Connect automatically.

---

## Step 4 — Verify App Groups (should already be set)

The entitlements files are already written:

| File | Group |
|---|---|
| `Lexora/Lexora.entitlements` | `group.com.yiga.Lexora` |
| `LexoraWidget/LexoraWidget.entitlements` | `group.com.yiga.Lexora` |
| `LexoraKeyboard/LexoraKeyboard.entitlements` | `group.com.yiga.Lexora` |

You still need to **register the App Group in the Apple Developer Portal** once
(Developer.apple.com → Identifiers → App Groups → `group.com.yiga.Lexora`).

---

## Step 5 — In-App Purchase setup

1. In App Store Connect → Your App → In-App Purchases → Create
2. Type: **Non-consumable**
3. Product ID: `com.yiga.Lexora.premium`
4. Reference name: "Lexora Premium"
5. Price: choose your tier (e.g., $4.99 / Tier 5)
6. Add localised display name and description
7. Submit for review along with the app

> In DEBUG builds, `StoreService.isPremium` is auto-set to `true` so you can
> develop without purchasing. No StoreKit configuration file needed for Xcode
> Simulator testing when using this flag.

---

## Step 6 — OpenAI API key (optional)

Users enter their own OpenAI key in Settings → AI Features.
The key is stored in the iOS Keychain, never in iCloud or any server.
The app works fully without a key — AI features gracefully degrade.

---

## Step 7 — Build and run

1. Select a real iPhone (iOS 18+) or a simulator
2. **⌘R**
3. On first launch: grant **Microphone** and **Speech Recognition** permissions
4. Complete the 6-step onboarding

### Enable the keyboard extension on a real device

1. iPhone **Settings → General → Keyboard → Keyboards → Add New Keyboard**
2. Find **Lexora** in the list
3. Tap → enable **Allow Full Access**
4. In any text field → tap 🌐 → select Lexora → tap the mic button

---

## Step 8 — TestFlight / App Store CI

See `.github/CI_SETUP.md` for the full secret-generation commands.

Quick summary — add these 8 secrets to your GitHub repo:

| Secret | Source |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | Export Distribution cert as .p12 → base64 |
| `BUILD_CERTIFICATE_PASSWORD` | Password you set on the .p12 |
| `BUILD_PROVISION_PROFILE_BASE64` | App Store .mobileprovision → base64 |
| `KEYCHAIN_PASSWORD` | Any random string |
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect → Integrations → API Keys |
| `APP_STORE_CONNECT_ISSUER_ID` | Same page (UUID) |
| `APP_STORE_CONNECT_API_KEY_BASE64` | .p8 file → base64 |
| `APPLE_TEAM_ID` | Your 10-char team ID |

Then trigger a build:

```bash
git tag v1.0.0
git push origin v1.0.0
```

---

## Project structure

```
LinguaFlow/
├── Lexora.xcodeproj/          ← open this in Xcode
│   └── project.pbxproj        ← all 37 files wired up, 3 targets configured
│
├── Lexora/                    ← main app target
│   ├── LexoraApp.swift
│   ├── Info.plist
│   ├── Lexora.entitlements    ← App Group + Siri + AppIntents
│   ├── PrivacyInfo.xcprivacy  ← required Apple privacy manifest
│   ├── Assets.xcassets/
│   ├── Models/                ← TranscriptionSession, VocabularyEntry, UserVoiceProfile, RecordingActivityAttributes
│   ├── Services/              ← AppState, SpeechEngine, AIService, StoreService, HTMLExportService, + 8 more
│   ├── Views/
│   │   ├── Dashboard/         ← DashboardView, AnalyticsView
│   │   ├── Recording/         ← RecordingView, WaveformView
│   │   ├── History/           ← TranscriptionHistoryView (+ SessionDetailView)
│   │   ├── Settings/          ← SettingsView
│   │   ├── Onboarding/        ← OnboardingView (6-step)
│   │   ├── Profile/           ← VoiceProfileView
│   │   ├── Premium/           ← PremiumPaywallView + PremiumGateModifier
│   │   └── Screenshots/       ← AppStoreScreenshots (5 preview frames, #if DEBUG)
│   └── Extensions/            ← Color+Extensions, FlowLayout, HapticManager, AppIntents
│
├── LexoraWidget/              ← widget extension target
│   ├── LexoraWidget.swift
│   ├── LexoraWidget.entitlements
│   └── Info.plist
│
├── LexoraKeyboard/            ← keyboard extension target
│   ├── KeyboardViewController.swift
│   ├── LexoraKeyboard.entitlements
│   └── Info.plist
│
├── .github/
│   ├── workflows/testflight.yml   ← 12-step CI pipeline
│   └── CI_SETUP.md                ← secret generation commands
│
└── SETUP_GUIDE.md             ← this file
```

---

## Key architecture decisions

| Decision | Why |
|---|---|
| `@Observable @MainActor` everywhere | No ObservableObject boilerplate; automatic SwiftUI updates |
| On-device speech recognition | Audio never leaves the device |
| CloudKit private DB | End-to-end encrypted; only the user can read their data |
| App Groups for keyboard | Only way for an extension to share a learned profile |
| StoreKit 2 non-consumable | Single purchase, no subscriptions, offline receipt verification |
| Keychain for OpenAI key | Not stored in UserDefaults or iCloud — survives reinstall, stays private |
| `#if DEBUG { isPremium = true }` | Develop all premium features without buying anything |

---

## Troubleshooting

**"Speech recognition unavailable"**
→ Settings → General → Language & Region — download the language for offline use.

**Keyboard mic not working**
→ Settings → General → Keyboard → Keyboards → Lexora → Allow Full Access must be ON.

**Premium paywall showing in debug**
→ Should not happen — `StoreService.isPremium = true` in DEBUG. Rebuild clean.

**CloudKit errors at launch**
→ Sign into iCloud on the device. Create the CloudKit container in App Store Connect
  (CloudKit Dashboard) if it doesn't exist yet.

**AI features returning errors**
→ Check that a valid OpenAI key is saved in Settings → AI Features.
  The key must start with `sk-`.

# Lexora — Voice Dictation & Transcription

[![CI](https://github.com/Kayiga/lexora/actions/workflows/testflight.yml/badge.svg)](https://github.com/Kayiga/lexora/actions/workflows/testflight.yml)
[![Privacy Policy](https://img.shields.io/badge/Privacy-Policy-blue)](https://kayiga.github.io/lexora/privacy.html)

An iOS app that learns how *you* speak.

Dictate in any language, edit transcripts, sync to iCloud, and get smarter with every correction — all on-device, no audio servers.

---

## Features

### Free
- Real-time transcription via on-device `SFSpeechRecognizer` (audio never leaves your device)
- Automatic language detection — switches mid-sentence, infers accent region
- Personal vocabulary: names, jargon, custom terms boosted during recognition
- Learning from corrections — every edit teaches a phoneme substitution
- iCloud sync via CloudKit (private, end-to-end encrypted)
- Export as plain text, PDF, or SRT subtitles
- Home screen widget (small, medium, large, lock screen) — tap to record instantly
- Custom keyboard extension — dictate into any text field system-wide
- Siri Shortcuts: start recordings, query word counts, export transcripts
- Live Activity + Dynamic Island during active recording
- Focus timer (5–60 min countdown, auto-pauses on expire)
- Voice profile: pacing, formality, pause rhythm, filler words

### Lexora Premium (one-time, $4.99)
- Unlimited session history (free: last 10 sessions)
- AI Insights — abstractive summary, action items, follow-up questions (your own OpenAI key, stored in Keychain)
- Reading Mode — distraction-free transcript reader with adjustable font and progress bar
- Share as HTML webpage (dark-mode aware, print-ready)
- Export as Obsidian vault (Markdown + YAML frontmatter + wikilinks)
- Full analytics — language breakdown, words-per-minute history, session heatmaps
- Named chapter markers — divide long recordings into navigable sections

---

## Tech Stack

| Layer | Technology |
|---|---|
| Language | Swift 5, SwiftUI |
| Observation | `@Observable` (iOS 17 Observation framework) |
| Speech | `SFSpeechRecognizer` (on-device) |
| Language detection | `NLLanguageRecognizer` |
| Sentiment | `NLTagger(.sentimentScore)` |
| Named entities | `NLTagger(.joinNames)` |
| IAP | StoreKit 2 (non-consumable) |
| AI | OpenAI Chat Completions API (user's own key) |
| Cloud sync | CloudKit (private database) |
| Widget | WidgetKit + ActivityKit |
| Search | CoreSpotlight |
| Tips | TipKit |
| Export | PDFKit, AVFoundation (SRT timing), custom HTML renderer |
| Keychain | `Security.framework` |
| CI/CD | GitHub Actions → TestFlight |

---

## Project Structure

```
Lexora/
├── LexoraApp.swift           — App entry, delegate, biometric lock, deep links
├── Models/
│   ├── TranscriptionSession  — Core data model (Codable, CloudKit)
│   ├── UserVoiceProfile      — Learned speaker profile
│   ├── VocabularyEntry       — Custom vocabulary terms
│   └── RecordingActivityAttributes — Live Activity content
├── Services/
│   ├── AppState              — Single source of truth (@Observable @MainActor)
│   ├── SpeechEngine          — AVAudioEngine + SFSpeechRecognizer
│   ├── LearningEngine        — Ingests sessions, applies corrections, builds hints
│   ├── LanguageIntelligence  — Language detection + code-switch detection
│   ├── AIService             — OpenAI GPT-4o mini integration (Keychain key)
│   ├── StoreService          — StoreKit 2 purchase/restore flow
│   ├── CloudSyncService      — CloudKit upload/download/sync
│   ├── HTMLExportService     — Self-contained dark-mode HTML renderer
│   ├── PDFExportService      — PDFKit-based transcript PDF
│   ├── SRTExportService      — VTT-compatible SRT subtitle generator
│   ├── SpotlightService      — CoreSpotlight indexing
│   ├── LiveActivityService   — Live Activity / Dynamic Island management
│   ├── NotificationService   — Local notification scheduling
│   └── LexoraTips            — TipKit tip definitions
├── Views/
│   ├── Dashboard/            — DashboardView, AnalyticsView
│   ├── Recording/            — RecordingView, WaveformView
│   ├── History/              — TranscriptionHistoryView (5300+ lines)
│   ├── Profile/              — VoiceProfileView + VocabularyStudyView
│   ├── Settings/             — SettingsView + WhatsNewView
│   ├── Onboarding/           — 6-step OnboardingView
│   ├── Premium/              — PremiumPaywallView + PremiumGateModifier
│   └── Screenshots/          — 5 App Store screenshot frames (#if DEBUG)
├── Extensions/
│   ├── Color+Extensions      — Adaptive colour palette helpers
│   ├── FlowLayout            — Wrapping chip layout
│   └── HapticManager         — Centralised haptic feedback
├── Intents/
│   └── AppIntents            — Siri Shortcuts + AppStateHolder
├── PrivacyInfo.xcprivacy     — Apple required privacy manifest
├── Lexora.entitlements       — App Group
└── LexoraStore.storekit      — Simulator IAP test config

LexoraWidget/
└── LexoraWidget.swift        — 6 widget sizes + Live Activity views

LexoraKeyboard/
└── KeyboardViewController.swift — Standalone dictation keyboard
```

---

## Getting Started

### Prerequisites

- Xcode 16+ (macOS 15 Sequoia)
- iPhone running iOS 18+
- Any Apple ID (free account works for local device testing)

### Run on device today — no paid account needed

The Debug build uses minimal entitlements (`Lexora-LocalDev.entitlements`) that Xcode can sign automatically with any free Apple ID. All core features work immediately.

```bash
open Lexora.xcodeproj
```

1. **Connect your iPhone** via USB
2. **Xcode → Preferences → Accounts** — sign in with your Apple ID if not already
3. In the scheme selector, pick your iPhone as the destination
4. In **Signing & Capabilities**, confirm Team shows your personal team (not 7AZTZL9VAG)
5. Press **⌘R**
6. On first launch, tap **Trust** on the device (Settings → General → VPN & Device Management → your Apple ID → Trust)

Grant microphone and speech recognition permissions when prompted. Complete the 6-step onboarding. Everything works — recording, transcription, history, AI Insights, IAP (free in `#if DEBUG`).

> **What's limited without a paid account:** Widget and keyboard extension won't share data with the main app (they need the registered App Group). The main app is fully functional.

### After your paid account is approved (~48h)

1. Register App Group `group.com.yiga.Lexora` on developer.apple.com → Identifiers
2. In Xcode → Lexora target → Build Settings → **CODE_SIGN_ENTITLEMENTS** → change Debug value from `Lexora/Lexora-LocalDev.entitlements` back to `Lexora/Lexora.entitlements` (same for Widget and Keyboard targets)
3. Add iCloud/CloudKit: Signing & Capabilities → `+` → iCloud → container `iCloud.com.yiga.Lexora`
4. Run `.github/setup_ci_secrets.sh` then `git tag v1.0.1 && git push origin v1.0.1` to trigger TestFlight

### Test IAP in Simulator

### Test IAP in Simulator

The `LexoraStore.storekit` config is wired into the debug scheme. In Simulator, the premium purchase completes instantly and free. In `#if DEBUG`, `StoreService.isPremium = true` is always set.

---

## CI/CD

Every push to `main` and every `v*` tag triggers the GitHub Actions pipeline:

```
checkout → select Xcode → install cert+profile → cache DerivedData
→ resolve SPM → run tests → archive → export IPA → upload to TestFlight
```

See `.github/CI_SETUP.md` for the 8 required secrets and how to generate them.

```bash
# Trigger a TestFlight build
git tag v1.0.0 && git push origin v1.0.0
```

---

## Privacy

Lexora processes speech **entirely on-device**. No audio is ever transmitted. Transcripts live in the user's private iCloud account. The optional AI feature sends transcript *text* to OpenAI at the user's explicit request, using their own API key stored in the iOS Keychain.

Full privacy policy: **https://kayiga.github.io/lexora/privacy.html**

---

## License

Private repository. All rights reserved.

# Lexora — App Store Connect Metadata

Paste each field directly into App Store Connect (appstoreconnect.apple.com).
All character counts are verified against Apple's limits.

---

## Basic Info

| Field | Value |
|---|---|
| **App Name** | Lexora |
| **Subtitle** | Voice Dictation & Transcription |
| **Category (Primary)** | Productivity |
| **Category (Secondary)** | Utilities |
| **Content Rating** | 4+ |
| **Price** | Free — 60-day full trial, then $4.99 one-time (Premium IAP) |
| **Bundle ID** | com.yiga.Lexora |
| **SKU** | LEXORA-1 |

---

## Description  
*(max 4,000 characters — this is ~1,650)*

Lexora is the iOS voice dictation app that learns how *you* speak.

Dictate naturally and watch your words appear in real time. Lexora learns your vocabulary, detects your native language automatically, and adapts to your accent — including code-switching between multiple languages mid-sentence.

**What makes Lexora different**

Unlike basic voice-to-text apps, Lexora gets smarter every time you use it. Every correction you make teaches the engine a new substitution. Every session refines your personal voice profile: pacing, pause rhythm, formality level, and your exact vocabulary — names, places, industry jargon, and more.

**Core features (free)**

• Real-time transcription powered by on-device speech recognition — audio never leaves your iPhone
• Automatic language detection: switches seamlessly between languages mid-sentence
• Personal vocabulary: add custom words, names, and technical terms
• Transcript editing with keyboard or voice
• Export as plain text, PDF, or SRT subtitles
• iCloud sync across all your Apple devices
• Widget: tap to record instantly from your home screen
• Keyboard extension: dictate into any text field, system-wide
• Siri Shortcuts: start recordings, query word counts, and more

**Lexora Premium — one-time purchase**

• Unlimited session history (free trial includes everything for 60 days)
• AI Insights: GPT-4o mini generates abstractive summaries, extracts action items, and suggests follow-up questions — using your own OpenAI key, stored securely in the iOS Keychain
• Reading Mode: distraction-free transcript reader with adjustable font size and a live progress bar
• Export as HTML webpage (dark-mode aware, print-ready, shareable)
• Export as Obsidian vault (Markdown with YAML frontmatter and wikilinks)
• Full Analytics: language breakdown, words-per-minute history, session heatmaps
• Named chapter markers: divide long recordings into navigable sections

**Privacy first**

Lexora processes speech entirely on your device using Apple's on-device Speech Recognition framework. No audio recordings are ever transmitted to any server. The optional AI feature sends transcript *text* (not audio) to OpenAI at your explicit request, using your own API key.

Transcripts, vocabulary, and your voice profile live in your private iCloud account — only you can access them.

---

## Promotional Text  
*(max 170 characters — shown at top of listing, changeable without new build)*

Your voice, learned. Dictate in any language — Lexora adapts to your accent, vocabulary, and speaking style. Get smarter with every recording.

---

## Keywords  
*(max 100 characters, comma-separated)*

voice dictation,transcription,speech to text,recorder,AI,multilingual,dictate,notes,transcript,memo

---

## What's New (Version 1.0)  
*(max 4,000 characters)*

Welcome to Lexora! First release on the App Store.

Lexora learns how you speak — your vocabulary, your accent, your pacing — and gets more accurate with every recording. Dictate in any language, edit transcripts, export to PDF or SRT, sync to iCloud, and dictate system-wide with the included keyboard extension.

Optional: add your OpenAI API key in Settings to unlock AI-powered summaries and action-item extraction (Lexora Premium required).

---

## Support URL

https://github.com/kayiga/lexora/issues

---

## Privacy Policy URL

*(Required for apps that use a keyboard extension or access contacts.)*
https://kayiga.github.io/lexora/privacy.html

**Minimum privacy policy must state:**
- App does not collect personal data on behalf of the developer
- Microphone audio is processed on-device and not transmitted
- Transcripts are stored in the user's private iCloud account
- Optional AI feature transmits transcript text to OpenAI using the user's own API key
- The keyboard extension requires "Allow Full Access" for App Group data sharing (profile.json only)

---

## Age Rating Questionnaire

| Question | Answer |
|---|---|
| Cartoon or fantasy violence | None |
| Realistic violence | None |
| Sexual content or nudity | None |
| Profanity or crude humour | None |
| Mature/suggestive themes | None |
| Simulated gambling | None |
| Horror/fear themes | None |
| Medical/treatment info | None |
| Alcohol, tobacco, drugs | None |
| **Result** | **4+** |

---

## App Review Notes

*(Paste into "Notes for App Review" field in App Store Connect)*

**Test account:** No account required — Lexora uses iCloud (the reviewer's own account).

**Microphone permission:** Required to transcribe speech. The review team can test dictation using the device microphone.

**Speech recognition permission:** Required for on-device transcription. Grant when prompted.

**Premium IAP (com.yiga.Lexora.premium — $4.99):** Can be tested via the "Restore Purchases" button in Settings. In the Sandbox environment, purchases are free.

**Keyboard extension:** To test LexoraKeyboard, go to Settings → General → Keyboard → Keyboards → Add New Keyboard → Lexora → enable Allow Full Access. Then open any text field, tap the globe key, select Lexora, and tap the microphone button.

**OpenAI key:** The AI Insights feature is optional and requires the user to supply their own OpenAI key. It is not required for core functionality.

**iCloud:** The app uses CloudKit private database. It will work in the Sandbox environment — the reviewer will see their own (empty) database, which is expected.

---

## App Store Screenshots Required

Lexora is **iPhone-only** (TARGETED_DEVICE_FAMILY = 1). No iPad screenshots required.

| Device | Format | Status |
|---|---|---|
| iPhone 6.7" | 1290 × 2796 | ✅ All 5 generated — `AppStore/Screenshots/` |

**Screenshots are pre-generated** at the correct App Store size (1290×2796).
Upload from `AppStore/Screenshots/` directly in App Store Connect.

Screenshots depict (in order):
1. Dashboard — streak, word count, smart suggestions
2. Recording — live waveform, real-time transcript, word count HUD
3. AI Insights — summary, action items, follow-up suggestions
4. Analytics — language chart, words-per-minute graph
5. Premium paywall — feature grid, one-time price

---

## In-App Purchase

| Field | Value |
|---|---|
| **Reference Name** | Lexora Premium |
| **Product ID** | com.yiga.Lexora.premium |
| **Type** | Non-Consumable |
| **Price** | Tier 5 — $4.99 |
| **Display Name** | Lexora Premium |
| **Description** | Unlimited history, AI insights, reading mode, HTML & Obsidian export, and full analytics. One-time purchase. |

---

## Localisation Priority

Release initially in **English (US)** only. The app's UI is English-only.
Expand to additional locales in v1.1 if analytics show significant non-English downloads.

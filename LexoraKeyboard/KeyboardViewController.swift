import UIKit
import SwiftUI
import Speech
import AVFoundation
import os

/// Unified-log diagnostics for the keyboard — same subsystem as the app, so one
/// `log collect`/Console.app filter shows both. Search "LexKB".
private let kbLog = Logger(subsystem: "com.yiga.Lexora", category: "Keyboard")
private func klog(_ line: String) { kbLog.notice("[LexKB] \(line, privacy: .public)") }

// MARK: - Lightweight profile (decoded from the App Group — no main-app import needed)

/// A minimal subset of UserVoiceProfile that the keyboard extension can decode
/// independently. Mirrors only the fields it actually uses.
private struct KeyboardProfile: Codable {
    struct VocabEntry: Codable {
        var term: String
        var aliases: [String]
        var relevanceScore: Double
    }

    var displayName: String = "You"
    var detectedPrimaryLanguage: String = "en-US"
    var customVocabulary: [VocabEntry] = []
    var phonemeSubstitutions: [String: String] = [:]
    var hapticFeedbackEnabled: Bool = true
}

// MARK: - Pending session written back to the main app via App Group

private struct PendingSession: Codable {
    var transcript: String
    var language: String
    var createdAt: Date
}

// MARK: - KeyboardViewController

class KeyboardViewController: UIInputViewController {

    private let appGroupID = "group.com.yiga.Lexora"
    private var hostingController: UIHostingController<KeyboardRootView>?

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    // Published state — mutated on main thread, triggers UI rebuild
    private var isListening = false
    private var currentText = ""
    private var selectedLanguage = "en-US"
    private var signalLevel: Float = 0
    /// Latest transcript dictated in the main Lexora app (App Group handoff) —
    /// offered as one-tap insert because iOS's keyboard sandbox blocks the mic.
    private var handoffText: String?

    private lazy var profile: KeyboardProfile = loadProfile()

    /// Shown in the UI so a stale cached keyboard binary is instantly visible.
    static let keyboardBuildTag = "kb-5"

    override func viewDidLoad() {
        super.viewDidLoad()
        // Custom-height keyboards must opt into self-sizing, otherwise the
        // system keeps its own height and the layout renders squashed.
        (view as? UIInputView)?.allowsSelfSizing = true
        klog("viewDidLoad \(Self.keyboardBuildTag) fullAccess=\(hasFullAccess) speechAuth=\(SFSpeechRecognizer.authorizationStatus().rawValue) selfSizing=\((view as? UIInputView)?.allowsSelfSizing ?? false)")
        setupKeyboardUI()
        subscribeToAudioInterruptions()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func subscribeToAudioInterruptions() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        if type == .began { stopDictation() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        profile = loadProfile()
        selectedLanguage = profile.detectedPrimaryLanguage
        handoffText = loadHandoff()
        rebuildUI()
    }

    // MARK: - App → keyboard handoff

    private struct Handoff: Codable {
        var transcript: String
        var language: String
        var createdAt: Date
    }

    private var handoffURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("handoff_latest.json")
    }

    /// Most recent dictation from the main app, if reasonably fresh (< 30 min).
    private func loadHandoff() -> String? {
        guard let url = handoffURL,
              let data = try? Data(contentsOf: url),
              let handoff = try? JSONDecoder().decode(Handoff.self, from: data),
              Date().timeIntervalSince(handoff.createdAt) < 30 * 60,
              !handoff.transcript.isEmpty
        else { return nil }
        return handoff.transcript
    }

    private func insertHandoff() {
        guard let text = handoffText else { return }
        insertText(text + " ")
        handoffText = nil
        if let url = handoffURL { try? FileManager.default.removeItem(at: url) }
        if profile.hapticFeedbackEnabled {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        rebuildUI()
    }

    /// Best-effort jump to the Lexora app (responder-chain openURL — the only
    /// route available to keyboard extensions; harmless no-op if blocked).
    private func openLexoraApp() {
        guard let url = URL(string: "lexora://record") else { return }
        // Keyboard extensions have no UIApplication; walk the responder chain to
        // whatever host object implements openURL: (works on current iOS).
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        while let r = responder {
            if r.responds(to: selector) {
                r.perform(selector, with: url)
                return
            }
            responder = r.next
        }
        extensionContext?.open(url)
    }

    // MARK: - UI

    private var vocabularyChips: [String] {
        profile.customVocabulary
            .filter { $0.relevanceScore > 0.2 }
            .sorted { $0.relevanceScore > $1.relevanceScore }
            .prefix(16)
            .map { $0.term }
    }

    private func setupKeyboardUI() {
        let hc = UIHostingController(rootView: makeRootView())
        hostingController = hc
        addChild(hc)
        view.addSubview(hc.view)
        hc.didMove(toParent: self)
        hc.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hc.view.topAnchor.constraint(equalTo: view.topAnchor),
            hc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func makeRootView() -> KeyboardRootView {
        KeyboardRootView(
            onStartRecording:  { [weak self] in self?.startDictation() },
            onStopRecording:   { [weak self] in self?.stopDictation() },
            onInsertText:      { [weak self] t in self?.insertText(t) },
            onDeleteBackward:  { [weak self] in self?.textDocumentProxy.deleteBackward() },
            onNextKeyboard:    { [weak self] in self?.advanceToNextInputMode() },
            onSaveToLexora:    { [weak self] in self?.saveCurrentToLexora() },
            onLanguageChanged: { [weak self] lang in
                self?.selectedLanguage = lang
                self?.rebuildUI()
            },
            onInsertHandoff:   { [weak self] in self?.insertHandoff() },
            onOpenLexora:      { [weak self] in self?.openLexoraApp() },
            handoffPreview:     handoffText,
            isListening:        Binding(get: { [weak self] in self?.isListening ?? false }, set: { _ in }),
            currentTranscript:  Binding(get: { [weak self] in self?.currentText ?? "" }, set: { _ in }),
            selectedLanguage:   Binding(get: { [weak self] in self?.selectedLanguage ?? "en-US" }, set: { _ in }),
            signalLevel:        Binding(get: { [weak self] in self?.signalLevel ?? 0 }, set: { _ in }),
            vocabularyChips:    vocabularyChips,
            hasUnsavedText:     !currentText.isEmpty || !(textDocumentProxy.documentContextBeforeInput ?? "").isEmpty
        )
    }

    private func rebuildUI() {
        hostingController?.rootView = makeRootView()
    }

    // MARK: - Dictation

    private func startDictation() {
        guard !isListening else { return }
        klog("startDictation fullAccess=\(hasFullAccess) auth=\(SFSpeechRecognizer.authorizationStatus().rawValue) lang=\(selectedLanguage)")

        // The mic and network paths are blocked without "Allow Full Access" —
        // the audio session just throws and the mic appears to do nothing.
        // Tell the user exactly what to enable instead of failing silently.
        guard hasFullAccess else {
            currentText = "Enable Full Access for Lexora: Settings → General → Keyboard → Keyboards → Lexora Keyboard → Allow Full Access."
            rebuildUI()
            return
        }

        // Speech recognition must be authorized. A keyboard extension can't reliably
        // show the system prompt, so if it isn't already authorized (granted via the
        // main Lexora app's onboarding), request it and tell the user where to grant it.
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        guard speechStatus == .authorized else {
            if speechStatus == .notDetermined {
                SFSpeechRecognizer.requestAuthorization { _ in }
            }
            currentText = "Open the Lexora app once and allow Microphone + Speech Recognition, then try again."
            rebuildUI()
            return
        }

        let locale = Locale(identifier: selectedLanguage)
        speechRecognizer = SFSpeechRecognizer(locale: locale)
                        ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            currentText = "Speech recognition isn't available right now."
            rebuildUI()
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            // .playAndRecord, NOT .record: in a keyboard extension a record-only
            // session gets no output route — the IO unit then reports "output HW
            // 0 Hz" and AUIOClient_StartIO fails with 'what' (2003329396), which
            // is exactly what device logs showed. playAndRecord establishes a
            // valid duplex route so the audio unit can start.
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            klog("audio session active (playAndRecord)")

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let request = recognitionRequest else { return }
            // Do NOT force on-device recognition in the keyboard: loading the
            // on-device model blows past a keyboard extension's ~60 MB memory
            // budget and gets the extension killed (mic appears to "not launch").
            // Let the system pick the lighter path.
            request.requiresOnDeviceRecognition = false
            request.shouldReportPartialResults  = true
            request.taskHint = .dictation
            request.contextualStrings = buildHints()

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    let raw       = result.bestTranscription.formattedString
                    let corrected = self.applyCorrections(to: raw)
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.currentText = corrected
                        self.rebuildUI()
                        if result.isFinal {
                            self.insertText(corrected + " ")
                            self.currentText = ""
                            self.rebuildUI()
                        }
                    }
                }
                if error != nil {
                    Task { @MainActor [weak self] in self?.stopDictation() }
                }
            }

            let inputNode = audioEngine.inputNode
            let format    = inputNode.outputFormat(forBus: 0)
            klog("mic format sr=\(format.sampleRate) ch=\(format.channelCount)")
            // In an extension the input can report a 0 Hz / 0-channel format when
            // the mic isn't actually available — installTap with that format
            // CRASHES the keyboard process instantly (keyboard dies/goes blank).
            guard format.sampleRate > 0, format.channelCount > 0 else {
                klog("mic unavailable (zero format) — aborting start")
                currentText = "The microphone isn't available to the keyboard. Open the Lexora app, record once, then try again. (Some apps also block keyboard mic access.)"
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                rebuildUI()
                return
            }
            inputNode.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
                let channelData = buffer.floatChannelData?.pointee
                let frameCount  = Int(buffer.frameLength)
                if let data = channelData, frameCount > 0 {
                    let rms = (0..<frameCount).reduce(0.0) { $0 + Double(data[$1] * data[$1]) }
                    let level = Float(sqrt(rms / Double(frameCount)))
                    Task { @MainActor [weak self] in
                        self?.signalLevel = min(1.0, level * 8)
                        self?.rebuildUI()
                    }
                }
            }

            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            klog("audio engine STARTED — listening")
            if profile.hapticFeedbackEnabled {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            rebuildUI()
        } catch {
            klog("audio start FAILED: \(error.localizedDescription)")
            // 'what' (2003329396) = the keyboard SANDBOX refuses mic IO on this
            // iOS version even though permissions are granted (verified via TCC
            // logs: authValue=2 but "Failed to issue generic sandbox extension").
            // Offer the handoff flow instead of a dead end.
            if (error as NSError).code == 2003329396 {
                currentText = "iOS doesn't allow keyboards to use the microphone on this version. Dictate in the Lexora app — your text will appear here for one-tap insert."
                openLexoraApp()
            } else {
                currentText = "Couldn't start the microphone (\(error.localizedDescription)). Record once in the Lexora app, then try again."
            }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            rebuildUI()
        }
    }

    private func stopDictation() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask    = nil
        isListening        = false
        signalLevel        = 0
        if profile.hapticFeedbackEnabled {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        rebuildUI()
    }

    private func insertText(_ text: String) {
        textDocumentProxy.insertText(text)
        rebuildUI()   // update hasUnsavedText
    }

    // MARK: - Save to Lexora

    /// Writes the dictated text as a pending session in the App Group container.
    /// The main app reads this on next launch and imports it as a new session.
    private func saveCurrentToLexora() {
        let textToSave = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !textToSave.isEmpty else { return }
        guard let container = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return }

        let pending = PendingSession(transcript: textToSave,
                                     language: selectedLanguage,
                                     createdAt: Date())
        let filename = "pending_\(Date().timeIntervalSinceReferenceDate).json"
        let url = container.appendingPathComponent(filename)
        if let data = try? JSONEncoder().encode(pending) {
            try? data.write(to: url)
        }

        // Clear after saving
        currentText = ""
        if profile.hapticFeedbackEnabled {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        rebuildUI()
    }

    // MARK: - App Group profile access

    private func loadProfile() -> KeyboardProfile {
        guard let container = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return KeyboardProfile()
        }
        let url = container.appendingPathComponent("profile.json")
        guard let data = try? Data(contentsOf: url),
              let profile = try? JSONDecoder().decode(KeyboardProfile.self, from: data) else {
            return KeyboardProfile()
        }
        return profile
    }

    private func buildHints() -> [String] {
        profile.customVocabulary
            .filter { $0.relevanceScore > 0.3 }
            .prefix(200)
            .flatMap { [$0.term] + $0.aliases }
    }

    private func applyCorrections(to text: String) -> String {
        var result = text
        for (wrong, correct) in profile.phonemeSubstitutions {
            result = result.replacingOccurrences(
                of: "\\b\(NSRegularExpression.escapedPattern(for: wrong))\\b",
                with: correct,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    // MARK: - Height

    /// Keyboard extensions must declare their height with an Auto Layout
    /// constraint — mutating `view.frame` gets overridden by the system and
    /// the keyboard renders collapsed/mis-sized. Priority 999 (not required)
    /// so the system can still resolve conflicts during rotation.
    private var heightConstraint: NSLayoutConstraint?

    override func updateViewConstraints() {
        super.updateViewConstraints()
        guard heightConstraint == nil else { return }
        // transcript(88) + vocab(42) + divider(1) + toolbar(102)
        let c = view.heightAnchor.constraint(equalToConstant: 233)
        c.priority = UILayoutPriority(999)
        c.isActive = true
        heightConstraint = c
    }
}

// MARK: - Keyboard SwiftUI Root View

struct KeyboardRootView: View {
    var onStartRecording:  () -> Void
    var onStopRecording:   () -> Void
    var onInsertText:      (String) -> Void
    var onDeleteBackward:  () -> Void
    var onNextKeyboard:    () -> Void
    var onSaveToLexora:    () -> Void
    var onLanguageChanged: (String) -> Void
    var onInsertHandoff:   () -> Void
    var onOpenLexora:      () -> Void
    /// Latest dictation from the Lexora app, offered for one-tap insertion.
    var handoffPreview: String?

    @Binding var isListening:       Bool
    @Binding var currentTranscript: String
    @Binding var selectedLanguage:  String
    @Binding var signalLevel:       Float
    var vocabularyChips: [String]
    var hasUnsavedText:  Bool

    private let availableLanguages: [(code: String, label: String)] = [
        ("en-US", "EN"), ("en-GB", "EN-GB"), ("es-ES", "ES"),
        ("fr-FR", "FR"), ("de-DE", "DE"),   ("it-IT", "IT"),
        ("pt-BR", "PT"), ("ja-JP", "JA"),   ("ko-KR", "KO"),
        ("zh-Hans", "ZH"), ("ar-SA", "AR"), ("hi-IN", "HI"),
        ("ru-RU", "RU"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            transcriptPreview
            if !vocabularyChips.isEmpty {
                vocabularyRow
            }
            Divider()
            keyboardToolbar
        }
        .background(Color(.systemBackground))
    }

    // MARK: - Transcript preview with live waveform

    private var transcriptPreview: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.systemGray6))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            // Build tag — proves which keyboard binary iOS actually loaded
            // (keyboards are cached aggressively; stale binaries are common).
            Text(KeyboardViewController.keyboardBuildTag)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 18)
                .padding(.top, 10)

            VStack(alignment: .leading, spacing: 4) {
                if currentTranscript.isEmpty, let handoff = handoffPreview, !isListening {
                    // A dictation from the Lexora app is waiting — one-tap insert.
                    Button(action: onInsertHandoff) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.doc.fill")
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Insert your Lexora dictation")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(handoff)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                } else if currentTranscript.isEmpty {
                    // Placeholder / waveform animation
                    HStack(spacing: 2) {
                        if isListening {
                            // Animated bars
                            ForEach(0..<12, id: \.self) { i in
                                let phase = Double(i) / 12.0
                                let amp = isListening
                                    ? 0.15 + Double(signalLevel) * 0.85 * abs(sin(phase * .pi))
                                    : 0.15
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(Color.accentColor)
                                    .frame(width: 3, height: 8 + 18 * amp)
                                    .animation(.easeInOut(duration: 0.12)
                                               .delay(phase * 0.08), value: signalLevel)
                            }
                        } else {
                            Text("Tap mic to dictate")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isListening ? .center : .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                } else {
                    ScrollView {
                        Text(currentTranscript)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
                }
            }
        }
        .frame(height: 88)
    }

    // MARK: - Vocabulary chips

    private var vocabularyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(vocabularyChips, id: \.self) { term in
                    Button { onInsertText(term + " ") } label: {
                        Text(term)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .frame(height: 42)
        .background(Color(.systemGray6))
    }

    // MARK: - Toolbar

    private var keyboardToolbar: some View {
        VStack(spacing: 0) {
            // ── Row 1: globe · punctuation · mic · save · delete ──────────────
            HStack(spacing: 4) {
                // Switch keyboard
                keyButton(icon: "globe", action: onNextKeyboard)

                // Language picker
                Menu {
                    ForEach(availableLanguages, id: \.code) { lang in
                        Button {
                            onLanguageChanged(lang.code)
                        } label: {
                            HStack {
                                Text(lang.label)
                                if selectedLanguage == lang.code {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(availableLanguages.first { $0.code == selectedLanguage }?.label ?? "EN")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 6))
                }

                Spacer()

                // Punctuation
                HStack(spacing: 5) {
                    punctuationButton(".")
                    punctuationButton(",")
                    punctuationButton("?")
                    punctuationButton("!")
                }

                Spacer()

                // Mic button
                Button {
                    if isListening { onStopRecording() } else { onStartRecording() }
                } label: {
                    ZStack {
                        Circle()
                            .fill(isListening ? Color.red : Color.accentColor)
                            .frame(width: 44, height: 44)
                        if isListening {
                            Circle()
                                .stroke(Color.red.opacity(0.3), lineWidth: 2)
                                .frame(width: 54, height: 54)
                                .scaleEffect(1 + 0.08 * Double(signalLevel))
                                .animation(.easeInOut(duration: 0.15), value: signalLevel)
                        }
                        Image(systemName: isListening ? "stop.fill" : "mic.fill")
                            .foregroundStyle(.white)
                            .font(.headline)
                    }
                }
                .accessibilityLabel(isListening ? "Stop dictation" : "Start dictation")

                Spacer()

                // Save to Lexora (only when there's text to save)
                if !currentTranscript.isEmpty {
                    Button(action: onSaveToLexora) {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.subheadline)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 36, height: 36)
                            .background(Color.accentColor.opacity(0.1),
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("Save to Lexora")
                    .help("Save this dictation as a Lexora session")
                }

                // Delete
                keyButton(icon: "delete.left", action: onDeleteBackward)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            // ── Row 2: space · return ─────────────────────────────────────────
            HStack(spacing: 8) {
                Button { onInsertText(" ") } label: {
                    Text("space")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.primary)
                }

                Button { onInsertText("\n") } label: {
                    Label("return", systemImage: "return")
                        .font(.caption.weight(.medium))
                        .frame(width: 90, height: 36)
                        .background(Color(.systemGray4), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .frame(height: 102)
        .animation(.snappy, value: currentTranscript.isEmpty)
    }

    // MARK: - Helpers

    private func keyButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.primary)
                .frame(width: 38, height: 38)
                .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func punctuationButton(_ char: String) -> some View {
        Button { onInsertText(char) } label: {
            Text(char)
                .font(.body.weight(.medium))
                .frame(width: 30, height: 34)
                .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

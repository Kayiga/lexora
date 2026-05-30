import UIKit
import SwiftUI
import Speech
import AVFoundation

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

    private lazy var profile: KeyboardProfile = loadProfile()

    override func viewDidLoad() {
        super.viewDidLoad()
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
        rebuildUI()
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
        let locale = Locale(identifier: selectedLanguage)
        speechRecognizer = SFSpeechRecognizer(locale: locale)
                        ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer = speechRecognizer, recognizer.isAvailable else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let request = recognitionRequest else { return }
            request.requiresOnDeviceRecognition = true
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
            if profile.hapticFeedbackEnabled {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            rebuildUI()
        } catch {
            // Dictation unavailable in this context
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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // transcript(88) + vocab(42) + divider(1) + toolbar(102)
        view.frame.size.height = 233
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

            VStack(alignment: .leading, spacing: 4) {
                if currentTranscript.isEmpty {
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

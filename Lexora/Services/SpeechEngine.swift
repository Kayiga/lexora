import Foundation
import Observation
import Speech
import AVFoundation
import Combine

// The heart of Lexora. Wraps SFSpeechRecognizer with adaptive intelligence:
// continuous language detection, real-time confidence tracking, and pause-pattern learning.
@Observable @MainActor
final class SpeechEngine {

    // MARK: - Public State
    var isListening = false
    var isPaused = false
    var currentTranscript = ""
    var currentConfidence: Double = 0
    var detectedLanguage: String = "en-US"
    var signalLevel: Float = 0              // -60 dB to 0 dB, normalised 0–1
    var currentWPM: Double = 0
    var errorMessage: String?
    var permissionStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    /// The most recently completed session — read by the recording view to show post-session stats.
    var lastFinishedSession: TranscriptionSession?

    // MARK: - Callbacks
    var onTranscriptUpdate: (@MainActor (String, Double) -> Void)?
    var onLanguageDetected: (@MainActor (String, Double) -> Void)?
    var onSessionFinished: (@MainActor (TranscriptionSession) -> Void)?
    var onPauseDetected: (@MainActor (Double) -> Void)?     // pause duration in ms

    // MARK: - Private
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var currentSession: TranscriptionSession?
    private var languageIntelligence: LanguageIntelligence
    private var learningEngine: LearningEngine

    // Pace tracking
    private var wordTimestamps: [TimeInterval] = []
    private var sessionStartTime: Date?
    private var lastWordTime: Date?
    private var pauseThresholdMS: Double = 500   // Learned dynamically per user

    // Language-switching: try alternate recogniser when confidence drops
    private var secondaryRecognizer: SFSpeechRecognizer?
    private var activeLanguage: String = "en-US"

    // Silence auto-stop
    private var silenceAutoStopEnabled = false
    private var silenceTimeoutSeconds: TimeInterval = 10
    private var lastSignificantSoundDate: Date?
    private var silenceCheckTask: Task<Void, Never>?

    init(languageIntelligence: LanguageIntelligence, learningEngine: LearningEngine) {
        self.languageIntelligence = languageIntelligence
        self.learningEngine = learningEngine
        subscribeToAudioSessionNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - AVAudioSession Interruption Handling

    /// Registers for system audio interruptions (phone calls, Siri, alarms, etc.)
    /// Without this, a call during recording silently breaks the audio engine
    /// and leaves `isListening = true` with no session saved.
    private func subscribeToAudioSessionNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private nonisolated func handleAudioSessionInterruption(_ note: Notification) {
        guard let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            switch type {
            case .began:
                // Phone call / Siri / alarm started — pause and save progress so far
                if isListening {
                    pauseListening()
                }
            case .ended:
                // Interruption over — only auto-resume if the system says it's safe
                let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume), isPaused {
                    try? resumeListening()
                }
            @unknown default:
                break
            }
        }
    }

    @objc private nonisolated func handleAudioRouteChange(_ note: Notification) {
        guard let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        // Headphones unplugged → stop recording to avoid capturing silence or wrong mic
        if reason == .oldDeviceUnavailable {
            Task { @MainActor [weak self] in
                guard let self, isListening else { return }
                pauseListening()
            }
        }
    }

    // MARK: - Silence Auto-Stop

    /// Call this before `startListening` to configure silence-based auto-stop.
    func configureSilenceAutoStop(enabled: Bool, timeout: TimeInterval) {
        silenceAutoStopEnabled = enabled
        silenceTimeoutSeconds = max(3, timeout)
    }

    private func startSilenceTimer() {
        silenceCheckTask?.cancel()
        lastSignificantSoundDate = Date()
        silenceCheckTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, isListening else { break }
                if let lastSound = lastSignificantSoundDate,
                   Date().timeIntervalSince(lastSound) >= silenceTimeoutSeconds {
                    stopListening()
                    break
                }
            }
        }
    }

    // MARK: - Permissions

    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                self?.permissionStatus = status
            }
        }
    }

    // MARK: - Session Control

    func startListening(
        language: String? = nil,
        contextProfileID: UUID? = nil,
        appBundleID: String? = nil
    ) throws {
        // Always query the live status — permissionStatus may be stale if permission
        // was granted from outside the app (e.g. iOS Settings or Onboarding flow).
        let liveStatus = SFSpeechRecognizer.authorizationStatus()
        permissionStatus = liveStatus
        guard liveStatus == .authorized else {
            throw SpeechError.notAuthorized
        }
        guard !isListening else { return }

        let targetLanguage = language ?? learningEngine.profile.detectedPrimaryLanguage
        try configureRecognizer(for: targetLanguage)

        currentSession = TranscriptionSession(
            contextProfileID: contextProfileID,
            appBundleID: appBundleID
        )
        sessionStartTime = Date()
        currentTranscript = ""
        wordTimestamps = []

        try startAudioEngine()
        isListening = true
        if silenceAutoStopEnabled { startSilenceTimer() }
    }

    func stopListening() {
        silenceCheckTask?.cancel()
        silenceCheckTask = nil
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
        isPaused = false

#if !targetEnvironment(macCatalyst)
        // Deactivate audio session so other apps can resume playback.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif

        finaliseSession()
    }

    /// Pauses audio capture without finalising the session.
    /// The transcript accumulated so far is preserved in `currentTranscript`.
    func pauseListening() {
        guard isListening, !isPaused else { return }
        audioEngine.pause()
        recognitionRequest?.endAudio()
        isPaused = true
        isListening = false
    }

    /// Resumes from a paused state by restarting the audio engine.
    func resumeListening() throws {
        guard isPaused else { return }
        // Re-connect the tap and restart
        try startAudioEngine()
        isPaused = false
        isListening = true
    }

    // MARK: - Configuration

    private func configureRecognizer(for language: String) throws {
        let locale = Locale(identifier: language)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            // Fall back to en-US if the locale isn't supported
            self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
            return
        }
        self.recognizer = recognizer
        activeLanguage = language
    }

    private func startAudioEngine() throws {
        // AVAudioSession category/active calls are iOS-only.
        // On Mac Catalyst the framework is a stub and setCategory throws runtime
        // exceptions that bypass Swift's try/catch — skip entirely on Mac.
#if !targetEnvironment(macCatalyst)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
#endif

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { throw SpeechError.engineFailed }

        // On-device recognition: preferred for privacy, but may be unavailable on Mac.
        // Fall back to server-based if the device/OS doesn't support on-device.
        let supportsOnDevice = recognizer?.supportsOnDeviceRecognition ?? false
        request.requiresOnDeviceRecognition = supportsOnDevice
        request.shouldReportPartialResults = true
        request.taskHint = .dictation

        let hints = learningEngine.buildRecognitionHints()
        request.contextualStrings = hints

        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            self?.handleRecognitionResult(result, error: error)
        }

        let inputNode = audioEngine.inputNode

        // Remove any existing tap before installing a new one.
        // Calling installTap while a tap is already installed crashes immediately.
        inputNode.removeTap(onBus: 0)

        // On Mac Catalyst the input node may report 0 channels before a mic is
        // confirmed — fall back to a safe mono 44.1 kHz format.
        let rawFormat = inputNode.outputFormat(forBus: 0)
        let format: AVAudioFormat
        if rawFormat.channelCount > 0 {
            format = rawFormat
        } else {
            guard let safe = AVAudioFormat(
                standardFormatWithSampleRate: 44_100, channels: 1
            ) else { throw SpeechError.engineFailed }
            format = safe
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
            self?.updateSignalLevel(buffer: buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    // MARK: - Result Processing

    private func handleRecognitionResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        guard let result = result else {
            if let error = error {
                DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
            }
            return
        }

        let transcript = result.bestTranscription.formattedString
        let segments = result.bestTranscription.segments

        // Calculate average confidence across all segments
        let confidence: Double = segments.isEmpty ? 0 :
            Double(segments.map { $0.confidence }.reduce(0, +)) / Double(segments.count)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // Run language detection on the growing transcript
            let langResult = languageIntelligence.detect(text: transcript)
            if langResult.language != detectedLanguage && langResult.confidence > 0.7 {
                detectedLanguage = langResult.language
                onLanguageDetected?(langResult.language, langResult.confidence)

                // If a new language is confidently detected, hot-swap recogniser
                if result.isFinal {
                    try? switchRecogniserIfNeeded(to: langResult.language)
                }
            }

            // Track pace
            trackPace(segments: segments)

            // Apply learned corrections (respects user preference)
            let corrected = learningEngine.profile.smartCorrectionEnabled
                ? learningEngine.applySmartCorrections(to: transcript)
                : transcript

            currentTranscript = corrected
            currentConfidence = confidence
            onTranscriptUpdate?(corrected, confidence)

            if result.isFinal {
                currentSession?.rawTranscript = transcript
                currentSession?.finalTranscript = corrected
                currentSession?.confidenceAverage = confidence
                currentSession?.primaryLanguage = detectedLanguage
                // Store per-word segment confidence for the detail view.
                // SFTranscriptionSegment.timestamp is seconds from the start of the utterance.
                let fillerSet: Set<String> = ["um", "uh", "like", "you know", "i mean",
                                              "basically", "literally", "actually", "so"]
                currentSession?.segments = segments.map { seg in
                    TranscriptSegment(
                        text: seg.substring,
                        startTime: seg.timestamp,
                        endTime: seg.timestamp + seg.duration,
                        confidence: Double(seg.confidence),
                        language: self.detectedLanguage,
                        isFiller: fillerSet.contains(seg.substring.lowercased())
                    )
                }
            }
        }
    }

    private func trackPace(segments: [SFTranscriptionSegment]) {
        guard !segments.isEmpty, let start = sessionStartTime else { return }

        let now = Date()
        if let lastWord = lastWordTime {
            let pauseMs = now.timeIntervalSince(lastWord) * 1000
            if pauseMs > pauseThresholdMS {
                onPauseDetected?(pauseMs)
                currentSession?.pausePattern.append(pauseMs)
            }
        }
        lastWordTime = now

        let elapsed = now.timeIntervalSince(start)
        if elapsed > 0 {
            let wordCount = Double(segments.count)
            currentWPM = (wordCount / elapsed) * 60
        }
    }

    private func switchRecogniserIfNeeded(to language: String) throws {
        guard language != activeLanguage else { return }
        // Gracefully swap recogniser mid-stream for code-switching
        stopListening()
        try startListening(language: language)
    }

    // MARK: - Signal Level

    private func updateSignalLevel(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frames = buffer.frameLength
        var rms: Float = 0
        for i in 0..<Int(frames) { rms += channelData[i] * channelData[i] }
        rms = sqrt(rms / Float(frames))
        let db = 20 * log10(rms)
        // Normalise: -60 dB = 0, 0 dB = 1
        let normalised = max(0, min(1, (db + 60) / 60))
        DispatchQueue.main.async {
            self.signalLevel = normalised
            // Any sound above a minimal threshold resets the silence timer.
            if normalised > 0.05 { self.lastSignificantSoundDate = Date() }
        }
    }

    // MARK: - Session Finalisation

    private func finaliseSession() {
        guard var session = currentSession else { return }
        session.finish(with: currentTranscript)
        session.paceWPM = currentWPM
        session.endedAt = Date()

        // Feed session data back to the learning engine
        learningEngine.ingest(session: session)

        lastFinishedSession = session
        onSessionFinished?(session)
        currentSession = nil
    }
}

// MARK: - Errors

enum SpeechError: LocalizedError {
    case notAuthorized
    case engineFailed
    case recognizerUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Microphone access is required. Enable it in Settings."
        case .engineFailed: return "The audio engine failed to start."
        case .recognizerUnavailable(let lang): return "Speech recognition is unavailable for \(lang)."
        }
    }
}

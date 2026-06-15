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

    /// Finalised text from completed recognition segments. The live transcript is
    /// always committedTranscript + the current request's text, so the transcript
    /// can only GROW — never reset — even when the recogniser restarts (segment
    /// boundary, audio-session interruption, or its ~1-minute single-request limit).
    @ObservationIgnored private var committedTranscript = ""
    /// All segment-confidence rows collected across recognition requests.
    @ObservationIgnored private var committedSegments: [TranscriptSegment] = []
    private var languageIntelligence: LanguageIntelligence
    private var learningEngine: LearningEngine

    // Pace tracking
    private var wordTimestamps: [TimeInterval] = []
    private var sessionStartTime: Date?
    private var lastWordTime: Date?
    private var pauseThresholdMS: Double = 500   // Learned dynamically per user

    // Silence auto-stop
    private var silenceAutoStopEnabled = false
    private var silenceTimeoutSeconds: TimeInterval = 10
    private var lastSignificantSoundDate: Date?
    private var silenceCheckTask: Task<Void, Never>?

    // Long-dictation continuity: SFSpeechRecognizer caps a single request at
    // ~1 minute and often stops WITHOUT a final/error callback. We proactively
    // rotate the request before that cap so dictation continues indefinitely.
    private var rotationTask: Task<Void, Never>?
    private let rotationInterval: TimeInterval = 45
    /// The current request's latest hypothesis (committed on rotation so nothing is lost).
    @ObservationIgnored private var latestSegmentText = ""
    @ObservationIgnored private var latestSegments: [TranscriptSegment] = []

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
                    Task { try? await self.resumeListening() }
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

    // MARK: - Long-dictation rotation

    /// Restarts the recognition request every `rotationInterval` seconds so we
    /// stay under SFSpeechRecognizer's ~1-minute single-request cap (which
    /// otherwise silently stops transcription mid-dictation, ~75 words in).
    private func startRotationTimer() {
        rotationTask?.cancel()
        rotationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.rotationInterval ?? 45))
                guard let self, isListening, !Task.isCancelled else { break }
                rotateRecognitionRequest()
            }
        }
    }

    /// Commits the current request's text, then starts a fresh request on the
    /// same audio stream — so long dictations continue past the recogniser's cap
    /// without losing words.
    private func rotateRecognitionRequest() {
        guard isListening else { return }
        // Preserve everything transcribed so far in this request.
        if !latestSegmentText.isEmpty {
            committedTranscript = committedTranscript.isEmpty
                ? latestSegmentText
                : committedTranscript + " " + latestSegmentText
            committedSegments += latestSegments
        }
        latestSegmentText = ""
        latestSegments = []
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        makeRecognitionRequestAndTask()
    }

    // MARK: - Permissions

    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            // Use Task { @MainActor in } instead of DispatchQueue.main.async.
            // On macOS 26 beta, DispatchQueue.main.async bypasses Swift Concurrency's
            // executor tracking, leaving MainActor.assumeIsolated in a bad state that
            // causes EXC_BAD_ACCESS when the next button tap occurs.
            Task { @MainActor [weak self] in
                self?.permissionStatus = status
            }
        }
    }

    // MARK: - Session Control

    func startListening(
        language: String? = nil,
        contextProfileID: UUID? = nil,
        appBundleID: String? = nil
    ) async throws {
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
        committedTranscript = ""
        committedSegments = []
        latestSegmentText = ""
        latestSegments = []
        wordTimestamps = []

        try await startAudioEngine()
        isListening = true
        startRotationTimer()
        if silenceAutoStopEnabled { startSilenceTimer() }
    }

    func stopListening() {
        // Guard against double-stop (e.g. user tap + silence timer firing together),
        // which would finalise the session twice.
        guard isListening || isPaused else { return }

        // Flip the flag FIRST so any in-flight recognition callback bails out
        // (handleRecognitionResult guards on isListening) before we tear down.
        isListening = false
        isPaused = false

        silenceCheckTask?.cancel()
        silenceCheckTask = nil
        rotationTask?.cancel()
        rotationTask = nil
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil

        // Deactivate the audio session off the main thread (otherwise the
        // blocking setActive(false) freezes the UI — this was the stop-hang).
        deactivateRecordingSession()

        finaliseSession()
    }

    /// Pauses audio capture without finalising the session.
    /// The transcript accumulated so far is preserved in `currentTranscript`.
    func pauseListening() {
        guard isListening, !isPaused else { return }
        rotationTask?.cancel()
        rotationTask = nil
        audioEngine.pause()
        recognitionRequest?.endAudio()
        isPaused = true
        isListening = false
    }

    /// Resumes from a paused state by restarting the audio engine.
    func resumeListening() async throws {
        guard isPaused else { return }
        // Re-connect the tap and restart
        try await startAudioEngine()
        isPaused = false
        isListening = true
        startRotationTimer()
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
    }

    // AVAudioSession.setActive / setCategory are BLOCKING calls. On the main
    // thread they freeze the UI (Xcode flags an "AVAudioSession Hang Risk").
    // Run them off the main actor via Task.detached. Activation is awaited so the
    // engine still starts only after the session is ready; the main thread is
    // never blocked (the awaiting actor task just suspends).
    private nonisolated func activateRecordingSession() async throws {
#if !targetEnvironment(macCatalyst)
        try await Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        }.value
#endif
    }

    /// Deactivates the audio session off the main thread (fire-and-forget — nothing
    /// waits on it, and on the main thread it can hang the UI for hundreds of ms).
    private nonisolated func deactivateRecordingSession() {
#if !targetEnvironment(macCatalyst)
        Task.detached(priority: .utility) {
            try? AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
        }
#endif
    }

    /// Creates a fresh recognition request + task. Used both at start and when a
    /// segment finalises / the recogniser hits its single-request limit, so a new
    /// request can keep transcribing the SAME audio stream without losing prior text.
    /// Identifies the current recognition request. Callbacks from a previous
    /// (rotated/cancelled) task carry an older id and are ignored, so a stale
    /// "final" can't trigger a second rotation (which dropped/duplicated words).
    @ObservationIgnored private var currentRequestID = UUID()

    private func makeRecognitionRequestAndTask() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        // On-device recognition preferred; fall back to server-based if unsupported.
        request.requiresOnDeviceRecognition = recognizer?.supportsOnDeviceRecognition ?? false
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = learningEngine.buildRecognitionHints()
        let id = UUID()
        currentRequestID = id
        recognitionRequest = request
        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            self?.handleRecognitionResult(result, error: error, requestID: id)
        }
    }

    private func startAudioEngine() async throws {
        // Configure + activate the audio session off the main thread.
        try await activateRecordingSession()

        makeRecognitionRequestAndTask()

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

    private func handleRecognitionResult(_ result: SFSpeechRecognitionResult?, error: Error?, requestID: UUID) {
        // Ignore callbacks from a previous (rotated/cancelled) request. Only the
        // current request drives the display and rotation — a stale task's final
        // result must NOT re-trigger rotation or it churns and drops words.
        guard requestID == currentRequestID else { return }

        // A nil result with an error means the recognition task ended (transient
        // failure, or it hit its single-request limit). If we're still recording,
        // commit nothing extra and spin up a fresh request to keep transcribing.
        guard let result = result else {
            if error != nil {
                // Task ended (transient failure or single-request cap). Rotate to a
                // fresh request after a short delay; skip if a timer rotation has
                // already spun one up (currentRequestID changed) to avoid tight loops.
                let endedID = requestID
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(300))
                    guard let self, isListening, currentRequestID == endedID else { return }
                    rotateRecognitionRequest()
                }
            }
            return
        }

        let segmentText = result.bestTranscription.formattedString
        let sfSegments = result.bestTranscription.segments
        let confidence: Double = sfSegments.isEmpty ? 0 :
            Double(sfSegments.map { $0.confidence }.reduce(0, +)) / Double(sfSegments.count)
        let isFinal = result.isFinal

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Ignore results that arrive after stop/while paused.
            guard isListening else { return }

            // Live transcript = everything committed so far + this request's text.
            // This is what makes the transcript only ever grow — a new request
            // (restart) starts segmentText fresh but committedTranscript is preserved.
            let live = committedTranscript.isEmpty
                ? segmentText
                : (segmentText.isEmpty ? committedTranscript : committedTranscript + " " + segmentText)

            // Language detection on the live transcript (label + primary language only).
            let langResult = languageIntelligence.detect(text: live)
            if langResult.language != detectedLanguage && langResult.confidence > 0.7 {
                detectedLanguage = langResult.language
                onLanguageDetected?(langResult.language, langResult.confidence)
            }

            trackPace(segments: sfSegments)

            let corrected = learningEngine.profile.smartCorrectionEnabled
                ? learningEngine.applySmartCorrections(to: live)
                : live

            // Monotonic display: SFSpeechRecognizer revises/reformats its live
            // hypothesis mid-sentence (e.g. spoken "one… two…" → "1.… 2.…") and
            // can momentarily emit a SHORTER string — that's the "purge" where
            // dictated text vanishes. Only let the visible transcript shrink when
            // this is the recogniser's FINAL, authoritative result; otherwise keep
            // the longest version seen so far so words never disappear mid-sentence.
            if isFinal || corrected.count >= currentTranscript.count {
                currentTranscript = corrected
                currentConfidence = confidence
                onTranscriptUpdate?(corrected, confidence)
            }

            // Build this request's segment-confidence rows.
            let fillerSet: Set<String> = ["um", "uh", "like", "you know", "i mean",
                                          "basically", "literally", "actually", "so"]
            let theseSegments = sfSegments.map { seg in
                TranscriptSegment(
                    text: seg.substring,
                    startTime: seg.timestamp,
                    endTime: seg.timestamp + seg.duration,
                    confidence: Double(seg.confidence),
                    language: self.detectedLanguage,
                    isFiller: fillerSet.contains(seg.substring.lowercased())
                )
            }

            // Remember this request's latest hypothesis so a rotation (timer,
            // final, or error) can commit it without losing words.
            latestSegmentText = segmentText
            latestSegments = theseSegments

            // Keep the in-progress session in sync with what's actually shown
            // (currentTranscript = the monotonic display), so a stop mid-sentence
            // saves the full text, not a transient shrunk hypothesis.
            currentSession?.rawTranscript = live
            currentSession?.finalTranscript = currentTranscript
            currentSession?.confidenceAverage = confidence
            currentSession?.primaryLanguage = detectedLanguage
            currentSession?.segments = committedSegments + theseSegments

            if isFinal {
                // Final result for this request — commit and start a fresh one so
                // dictation continues past the recogniser's single-request limit.
                rotateRecognitionRequest()
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

    // MARK: - Signal Level

    /// Last time we dispatched a waveform update to the main actor (racy by design —
    /// only used to throttle, exact value doesn't matter).
    @ObservationIgnored private nonisolated(unsafe) var lastSignalDispatch: CFAbsoluteTime = 0

    private func updateSignalLevel(buffer: AVAudioPCMBuffer) {
        // Throttle to ~15 Hz. The audio tap fires ~40×/sec; spawning a main-actor
        // task per buffer floods the main thread and can freeze the UI on long
        // recordings. The waveform doesn't need more than ~15 fps.
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastSignalDispatch >= 0.066 else { return }
        lastSignalDispatch = now

        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frames = buffer.frameLength
        var rms: Float = 0
        for i in 0..<Int(frames) { rms += channelData[i] * channelData[i] }
        rms = sqrt(rms / Float(frames))
        let db = 20 * log10(rms)
        // Normalise: -60 dB = 0, 0 dB = 1
        let normalised = max(0, min(1, (db + 60) / 60))
        Task { @MainActor [weak self] in
            self?.signalLevel = normalised
            // Any sound above a minimal threshold resets the silence timer.
            if normalised > 0.05 { self?.lastSignificantSoundDate = Date() }
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

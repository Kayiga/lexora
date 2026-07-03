import Foundation
import Observation
import Speech
import AVFoundation
import Combine
import os

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
    /// Which transcription engine the current/last session used — surfaced in
    /// Settings → About so engine fallbacks are visible instead of silent.
    var activeEngineDescription: String = "—"

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
    /// From this age on, the request is rotated at the FIRST detected speech pause
    /// (so no words are in flight when the old task is cancelled).
    private let rotationSoftInterval: TimeInterval = 35
    /// Absolute request age limit — rotate even mid-speech rather than risk
    /// SFSpeechRecognizer's silent ~1-minute stop.
    private let rotationHardInterval: TimeInterval = 55
    /// Gap since the last recognised word that counts as a speech pause.
    private let rotationPauseThreshold: TimeInterval = 0.7
    /// The current request's latest hypothesis (used as a fallback when draining).
    @ObservationIgnored private var latestSegmentText = ""
    @ObservationIgnored private var latestSegments: [TranscriptSegment] = []

    // Gapless rotation: the OUTGOING request is drained (endAudio, not cancelled)
    // so its final result — including the half-second tail spoken right before the
    // handoff — gets committed, while a NEW request immediately takes over the
    // live audio. Without this, those tail words were dropped at every rotation.
    /// When the current recognition request started (set at start + each rotation).
    /// Drives the pause-aware rotation timer.
    @ObservationIgnored private var currentRequestStartedAt = Date()

    /// iOS 26+ SpeechAnalyzer/SpeechTranscriber core (type-erased so the class
    /// compiles for iOS 18). Non-nil = the modern engine is driving transcription:
    /// unlimited-length dictation with proper volatile→finalized results — no
    /// 1-minute cap, no rotation, none of SFSpeechRecognizer's silent stalls.
    /// `nonisolated(unsafe)` because the audio tap thread reads it to feed buffers
    /// (same pattern as `recognitionRequest`); it's only written on the main actor.
    @ObservationIgnored nonisolated(unsafe) private var modernCore: AnyObject?

    init(languageIntelligence: LanguageIntelligence, learningEngine: LearningEngine) {
        self.languageIntelligence = languageIntelligence
        self.learningEngine = learningEngine
        subscribeToAudioSessionNotifications()
        runEngineSelfTestIfRequested()
    }

    /// Diagnostics: `LEXORA_ENGINE_SELFTEST=1` in the environment makes the app
    /// try to construct the modern transcription pipeline at launch and log the
    /// outcome to the unified log — readable via `log show` without recording.
    private func runEngineSelfTestIfRequested() {
        guard ProcessInfo.processInfo.environment["LEXORA_ENGINE_SELFTEST"] == "1" else { return }
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            Task { [weak self] in
                self?.slog("SELFTEST: building modern pipeline for en-US…")
                let core = await ModernTranscribeCore.make(
                    localeIdentifier: "en-US",
                    onResult: { _, _ in },
                    log: { [weak self] line in
                        Task { @MainActor in self?.slog("SELFTEST: \(line)") }
                    }
                )
                self?.slog("SELFTEST result: \(core == nil ? "FAILED → would fall back to legacy" : "OK — modern engine constructs")")
                if let core { await core.finishAndTearDown() }
            }
        } else {
            slog("SELFTEST: iOS < 26 — modern engine unavailable")
        }
#else
        slog("SELFTEST: built without iOS 26 SDK — modern engine not compiled in")
#endif
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

    /// Pause-aware rotation loop. SFSpeechRecognizer silently stops a single
    /// request after ~1 minute, so the request must be restarted periodically.
    /// From `rotationSoftInterval` on, we rotate at the FIRST detected pause in
    /// speech (nothing is mid-air, so cancelling the old task loses nothing);
    /// at `rotationHardInterval` we rotate regardless.
    private func startRotationTimer() {
        rotationTask?.cancel()
        rotationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, isListening, !Task.isCancelled else { break }
                let age = Date().timeIntervalSince(currentRequestStartedAt)
                guard age >= rotationSoftInterval else { continue }
                let pausedFor = Date().timeIntervalSince(lastWordTime ?? currentRequestStartedAt)
                if pausedFor >= rotationPauseThreshold || age >= rotationHardInterval {
                    rotateRecognitionRequest()
                }
            }
        }
    }

    /// **Cancel-based rotation with commit-now banking.** One recognition task
    /// exists at any moment — device testing proved that ANY overlap of two
    /// tasks (drain via endAudio, even on separate recognizer instances) starves
    /// or freezes recognition. History:
    ///  - wait-for-final banking → silent task death wiped whole minutes;
    ///  - endAudio drain, shared recognizer → new task never got results;
    ///  - endAudio drain, fresh recognizer → froze after a few rotations.
    /// So: 1) bank the current window synchronously (can never be lost),
    ///     2) CANCEL the old task outright (frees the recognizer immediately),
    ///     3) start the replacement task on the same recognizer.
    /// The pause-aware timer above makes the cancel land in a speech gap, so the
    /// discarded in-flight tail is silence, not words.
    private func rotateRecognitionRequest() {
        guard isListening else { return }
        slog("ROTATE \(currentRequestID.uuidString.prefix(4)) banking=\"\(latestSegmentText.suffix(30))\"")

        appendToCommitted(text: latestSegmentText, segments: latestSegments)
        latestSegmentText = ""
        latestSegments = []

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        makeRecognitionRequestAndTask()
    }

    /// Inserts a bookmark/marker into the transcript at the current spoken point.
    /// Rotating first banks everything said so far, so the marker lands exactly
    /// where the user tapped it — and because it lives in committedTranscript,
    /// subsequent recognition updates can't wipe it (they only append after it).
    func insertMarker(_ marker: String) {
        guard isListening else { return }
        if modernCore == nil {
            // Legacy: rotate first so everything spoken so far is banked and the
            // marker lands at the current spoken point.
            rotateRecognitionRequest()
            appendToCommitted(text: marker, segments: [])
            currentTranscript = committedTranscript
        } else {
            // Modern: append the marker to the committed text only. The volatile
            // window is NOT banked here — its final will arrive from the analyzer
            // (banking it manually would duplicate it). The marker lands at the
            // last finalised point, within a few seconds of the tap.
            appendToCommitted(text: marker, segments: [])
            currentTranscript = committedTranscript.isEmpty
                ? latestSegmentText
                : (latestSegmentText.isEmpty ? committedTranscript
                                             : committedTranscript + " " + latestSegmentText)
        }
        onTranscriptUpdate?(currentTranscript, currentConfidence)
    }

    /// Appends text/segments to the committed (banked) transcript.
    private func appendToCommitted(text: String, segments: [TranscriptSegment]) {
        guard !text.isEmpty else { return }
        committedTranscript = committedTranscript.isEmpty
            ? text
            : committedTranscript + " " + text
        committedSegments += segments
    }

    /// Maps recogniser segments to our model rows.
    private func makeSegments(_ sfSegments: [SFTranscriptionSegment]) -> [TranscriptSegment] {
        let fillerSet: Set<String> = ["um", "uh", "like", "you know", "i mean",
                                      "basically", "literally", "actually", "so"]
        return sfSegments.map { seg in
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

        // Prefer the modern SpeechAnalyzer engine (iOS 26+): purpose-built for
        // unlimited live dictation. Falls back to legacy SFSpeechRecognizer with
        // pause-aware rotation when unavailable (older iOS / unsupported locale).
        modernCore = nil
#if compiler(>=6.2)   // SpeechAnalyzer needs the iOS 26 SDK (Xcode 26+)
        if #available(iOS 26.0, *) {
            modernCore = await ModernTranscribeCore.make(
                localeIdentifier: targetLanguage,
                onResult: { [weak self] text, isFinal in
                    Task { @MainActor [weak self] in
                        self?.handleModernResult(text, isFinal: isFinal)
                    }
                },
                onStreamEnded: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.recoverModernStreamIfNeeded(language: targetLanguage)
                    }
                },
                log: { [weak self] line in
                    Task { @MainActor [weak self] in self?.slog(line) }
                }
            )
        }
#endif
        activeEngineDescription = modernCore != nil
            ? "SpeechAnalyzer (modern)"
            : "SFSpeechRecognizer (legacy)"
        slog("startListening lang=\(targetLanguage) engine=\(activeEngineDescription)")

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
        if modernCore == nil { startRotationTimer() }   // rotation is a legacy-only workaround
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

        // Tear down the modern engine (if active). Finalisation is async but the
        // volatile window is banked synchronously below, so nothing is lost even
        // if the analyzer never delivers another result.
#if compiler(>=6.2)
        if #available(iOS 26.0, *), let core = modernCore as? ModernTranscribeCore {
            modernCore = nil
            Task.detached { await core.finishAndTearDown() }
        }
#endif

        // Bank the current window so the words spoken since the last rotation
        // are part of the final transcript even if no further callback arrives.
        appendToCommitted(text: latestSegmentText, segments: latestSegments)
        latestSegmentText = ""
        latestSegments = []
        if committedTranscript.count > currentTranscript.count {
            currentTranscript = committedTranscript
        }

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
        // Modern engine: just stop feeding audio — the analyzer waits.
        // Legacy: end the request so it finalises what it has.
        if modernCore == nil { recognitionRequest?.endAudio() }
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
        if modernCore == nil { startRotationTimer() }
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

    /// Toggle for verbose recognition diagnostics. Flip to false to silence.
    static let debugLogging = true
    /// os.Logger (not print): lines reach the device's unified log, so they show
    /// in Xcode's console AND can be pulled later via Console.app / `log collect`
    /// even when the app wasn't running under Xcode. Filter: subsystem
    /// "com.yiga.Lexora", category "Speech" (or search "LexSpeech").
    private static let osLog = os.Logger(subsystem: "com.yiga.Lexora", category: "Speech")

    private func slog(_ message: @autoclosure () -> String) {
        guard Self.debugLogging else { return }
        let line = message()
        Self.osLog.notice("[LexSpeech] \(line, privacy: .public)")
    }

    private func makeRecognitionRequestAndTask() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        // On-device recognition preferred; fall back to server-based if unsupported.
        request.requiresOnDeviceRecognition = recognizer?.supportsOnDeviceRecognition ?? false
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = learningEngine.buildRecognitionHints()
        let id = UUID()
        currentRequestID = id
        currentRequestStartedAt = Date()
        recognitionRequest = request
        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            self?.handleRecognitionResult(result, error: error, requestID: id)
        }
        // The single most important diagnostic: did the task actually get created?
        // If this logs "task=nil" on a rotation, the recognizer is refusing a second
        // concurrent task — which would silently stop transcription at the handoff.
        slog("new request \(id.uuidString.prefix(4)) task=\(recognitionTask == nil ? "nil" : "ok") onDevice=\(request.requiresOnDeviceRecognition)")
    }

    private func startAudioEngine() async throws {
        // Configure + activate the audio session off the main thread.
        try await activateRecordingSession()

        // Legacy path only — the modern analyzer receives buffers directly.
        if modernCore == nil { makeRecognitionRequestAndTask() }

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
            guard let self else { return }
#if compiler(>=6.2)
            if #available(iOS 26.0, *), let core = self.modernCore as? ModernTranscribeCore {
                core.feed(buffer)
            } else {
                self.recognitionRequest?.append(buffer)
            }
#else
            self.recognitionRequest?.append(buffer)
#endif
            self.updateSignalLevel(buffer: buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    // MARK: - Result Processing (modern SpeechAnalyzer path, iOS 26+)

    /// The analyzer's result stream died mid-session (error or premature finish).
    /// Without recovery the mic keeps running but no more text ever arrives.
    /// Bank what's showing, then rebuild the pipeline and keep dictating.
    private func recoverModernStreamIfNeeded(language: String) {
#if compiler(>=6.2)
        guard isListening, modernCore != nil else { return }   // normal teardown — ignore
        slog("modern stream died while listening → rebuilding pipeline")
        appendToCommitted(text: latestSegmentText, segments: latestSegments)
        latestSegmentText = ""
        latestSegments = []
        modernCore = nil
        if #available(iOS 26.0, *) {
            Task { @MainActor [weak self] in
                guard let self, isListening else { return }
                modernCore = await ModernTranscribeCore.make(
                    localeIdentifier: language,
                    onResult: { [weak self] text, isFinal in
                        Task { @MainActor [weak self] in
                            self?.handleModernResult(text, isFinal: isFinal)
                        }
                    },
                    onStreamEnded: { [weak self] in
                        Task { @MainActor [weak self] in
                            self?.recoverModernStreamIfNeeded(language: language)
                        }
                    },
                    log: { [weak self] line in
                        Task { @MainActor [weak self] in self?.slog(line) }
                    }
                )
                if modernCore == nil {
                    slog("modern rebuild FAILED → falling back to legacy request")
                    makeRecognitionRequestAndTask()
                    startRotationTimer()
                }
            }
        }
#endif
    }

    /// Handles a result from the SpeechTranscriber stream.
    /// - volatile (isFinal=false): replaces the current in-flight window.
    /// - finalized (isFinal=true): appended permanently to committedTranscript;
    ///   the volatile window resets. Text can never be lost or overwritten.
    private func handleModernResult(_ text: String, isFinal: Bool) {
        guard isListening else { return }

        if isFinal {
            // If the analyzer finalises a range as EMPTY while words were showing
            // as volatile, keep the volatile words — no later result will cover
            // that audio, so discarding them loses a chunk of dictation.
            let finalText = text.trimmingCharacters(in: .whitespaces).isEmpty
                ? latestSegmentText
                : text
            slog("final len=\(text.count) volatile=\(latestSegmentText.count) committed+=\(finalText.suffix(25))")
            appendToCommitted(
                text: finalText,
                segments: finalText.isEmpty ? [] : [TranscriptSegment(
                    text: finalText,
                    startTime: 0, endTime: 0,
                    confidence: 1.0,
                    language: detectedLanguage,
                    isFiller: false
                )]
            )
            latestSegmentText = ""
            latestSegments = []
        } else {
            latestSegmentText = text
        }

        let live = committedTranscript.isEmpty
            ? latestSegmentText
            : (latestSegmentText.isEmpty ? committedTranscript
                                         : committedTranscript + " " + latestSegmentText)

        // Same intelligence pipeline as the legacy path: continuous language
        // detection + the user's learned corrections/style.
        let langResult = languageIntelligence.detect(text: live)
        if langResult.language != detectedLanguage && langResult.confidence > 0.7 {
            detectedLanguage = langResult.language
            onLanguageDetected?(langResult.language, langResult.confidence)
        }

        let corrected = learningEngine.profile.smartCorrectionEnabled
            ? learningEngine.applySmartCorrections(to: live)
            : live

        // Monotonic display: volatile hypotheses may briefly shrink while the
        // model revises — never show a shorter string except on a final.
        if isFinal || corrected.count >= currentTranscript.count {
            currentTranscript = corrected
            currentConfidence = 1.0
            onTranscriptUpdate?(corrected, 1.0)
        }

        lastWordTime = Date()
        if let start = sessionStartTime {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed > 0 {
                let words = Double(live.split(whereSeparator: { $0.isWhitespace }).count)
                currentWPM = (words / elapsed) * 60
            }
        }

        currentSession?.rawTranscript = live
        currentSession?.finalTranscript = currentTranscript
        currentSession?.confidenceAverage = 1.0
        currentSession?.primaryLanguage = detectedLanguage
        currentSession?.segments = committedSegments
    }

    // MARK: - Result Processing (legacy SFSpeechRecognizer path)

    private func handleRecognitionResult(_ result: SFSpeechRecognitionResult?, error: Error?, requestID: UUID) {
        // Snapshot result data, then hop to the main actor for all state changes.
        let segmentText = result?.bestTranscription.formattedString
        let sfSegments = result?.bestTranscription.segments ?? []
        let isFinal = result?.isFinal ?? false
        let endedWithError = (result == nil && error != nil)
        let confidence: Double = sfSegments.isEmpty ? 0 :
            Double(sfSegments.map { $0.confidence }.reduce(0, +)) / Double(sfSegments.count)

        Task { @MainActor [weak self] in
            guard let self else { return }

            // ── Only the CURRENT request drives the display and rotation.
            //    Late callbacks from a cancelled (rotated) task carry an old id
            //    and are dropped here — their window is already banked.
            guard requestID == currentRequestID, isListening else {
                slog("stale \(requestID.uuidString.prefix(4)) ignored (final=\(isFinal) err=\(endedWithError))")
                return
            }

            if endedWithError {
                // Task ended (transient failure / single-request cap). Rotate after a
                // short delay unless a timer rotation already replaced it.
                slog("current \(requestID.uuidString.prefix(4)) ERROR=\(error?.localizedDescription ?? "?") → rotate in 300ms")
                let endedID = requestID
                try? await Task.sleep(for: .milliseconds(300))
                guard isListening, currentRequestID == endedID else { return }
                rotateRecognitionRequest()
                return
            }
            guard let segmentText else { return }

            // Live transcript = committed (drained) text + this request's window.
            let live = committedTranscript.isEmpty
                ? segmentText
                : (segmentText.isEmpty ? committedTranscript : committedTranscript + " " + segmentText)

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
            // hypothesis mid-sentence (e.g. "one… two…" → "1.… 2.…") and can briefly
            // emit a SHORTER string. Only allow a shrink on the final result;
            // otherwise keep the longest text so words never vanish mid-sentence.
            if isFinal || corrected.count >= currentTranscript.count {
                currentTranscript = corrected
                currentConfidence = confidence
                onTranscriptUpdate?(corrected, confidence)
            }

            let theseSegments = makeSegments(sfSegments)
            latestSegmentText = segmentText
            latestSegments = theseSegments

            // Keep the in-progress session in sync with the displayed text so a
            // stop mid-sentence saves everything (not a transient shrunk hypothesis).
            currentSession?.rawTranscript = live
            currentSession?.finalTranscript = currentTranscript
            currentSession?.confidenceAverage = confidence
            currentSession?.primaryLanguage = detectedLanguage
            currentSession?.segments = committedSegments + theseSegments

            if isFinal {
                // Recogniser finalised this request — hand off gaplessly to a new one.
                slog("current \(requestID.uuidString.prefix(4)) FINAL → rotate")
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

// MARK: - Modern Transcription Core (iOS 26+, SpeechAnalyzer / SpeechTranscriber)

#if compiler(>=6.2)   // types exist only in the iOS 26 SDK (Xcode 26+); older toolchains build the legacy engine only
/// Wraps Apple's SpeechAnalyzer pipeline — the API purpose-built for unlimited
/// live dictation. Unlike SFSpeechRecognizer there is NO ~1-minute request cap,
/// no silent stalls at ~180-230 words, and results come as a clean
/// volatile → finalized stream, so no rotation workarounds are needed.
///
/// Threading: `feed(_:)` is called from the audio tap thread; buffers flow
/// through an AsyncStream into the analyzer. Everything else is async/await.
@available(iOS 26.0, *)
final class ModernTranscribeCore: @unchecked Sendable {

    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private let analyzerFormat: AVAudioFormat?
    private var resultsTask: Task<Void, Never>?
    // Converter state — only touched from the audio tap thread.
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?

    private init(analyzer: SpeechAnalyzer,
                 transcriber: SpeechTranscriber,
                 inputBuilder: AsyncStream<AnalyzerInput>.Continuation,
                 analyzerFormat: AVAudioFormat?) {
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.inputBuilder = inputBuilder
        self.analyzerFormat = analyzerFormat
    }

    /// Builds and starts a live transcription pipeline for the locale.
    /// Returns nil when the locale isn't supported (caller falls back to legacy).
    static func make(
        localeIdentifier: String,
        onResult: @escaping @Sendable (String, Bool) -> Void,
        onStreamEnded: @escaping @Sendable () -> Void = {},
        log: @escaping @Sendable (String) -> Void
    ) async -> ModernTranscribeCore? {
        let locale = Locale(identifier: localeIdentifier)

        let supported = await SpeechTranscriber.supportedLocales
        log("SpeechTranscriber: \(supported.count) supported locales: \(supported.prefix(30).map { $0.identifier(.bcp47) }.joined(separator: ","))")

        // Exact match first, then language-only (e.g. "en-GB" → any "en-*").
        let wantedTag = locale.identifier(.bcp47).lowercased()
        let wantedLang = wantedTag.split(separator: "-").first.map(String.init) ?? wantedTag
        let matched = supported.first(where: { $0.identifier(.bcp47).lowercased() == wantedTag })
            ?? supported.first(where: {
                $0.identifier(.bcp47).lowercased().split(separator: "-").first.map(String.init) == wantedLang
            })
        guard let matchedLocale = matched else {
            log("SpeechTranscriber: locale \(localeIdentifier) unsupported → legacy")
            return nil
        }

        let transcriber = SpeechTranscriber(
            locale: matchedLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        do {
            // Download the on-device model if it isn't installed yet (one-time).
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                log("SpeechTranscriber: downloading model assets…")
                try await request.downloadAndInstall()
                log("SpeechTranscriber: model ready")
            }

            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
            try await analyzer.start(inputSequence: inputSequence)

            let core = ModernTranscribeCore(
                analyzer: analyzer,
                transcriber: transcriber,
                inputBuilder: inputBuilder,
                analyzerFormat: format
            )

            core.resultsTask = Task {
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        onResult(text, result.isFinal)
                    }
                    log("SpeechTranscriber results stream finished")
                } catch {
                    log("SpeechTranscriber results stream ERROR: \(error.localizedDescription)")
                }
                onStreamEnded()
            }

            log("SpeechAnalyzer started (format=\(format?.sampleRate ?? 0)Hz)")
            return core
        } catch {
            log("SpeechAnalyzer start failed: \(error.localizedDescription) → legacy")
            return nil
        }
    }

    /// Called from the audio tap thread for every captured buffer.
    nonisolated func feed(_ buffer: AVAudioPCMBuffer) {
        guard let target = analyzerFormat else {
            inputBuilder.yield(AnalyzerInput(buffer: buffer))
            return
        }
        // Fast path — formats already match.
        if buffer.format == target {
            inputBuilder.yield(AnalyzerInput(buffer: buffer))
            return
        }
        // Convert to the analyzer's preferred format.
        if converter == nil || converterSourceFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converterSourceFormat = buffer.format
        }
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var provided = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if provided { status.pointee = .noDataNow; return nil }
            provided = true
            status.pointee = .haveData
            return buffer
        }
        if err == nil, out.frameLength > 0 {
            inputBuilder.yield(AnalyzerInput(buffer: out))
        }
    }

    /// Ends the input stream and lets the analyzer finalise remaining audio.
    func finishAndTearDown() async {
        inputBuilder.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        resultsTask = nil
    }
}
#endif   // compiler(>=6.2)

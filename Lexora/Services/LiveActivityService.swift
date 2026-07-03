// ActivityKit is iOS/iPadOS only — not available on Mac Catalyst
#if !targetEnvironment(macCatalyst)
@preconcurrency import ActivityKit
#endif
import Foundation
import Observation

/// Manages the single in-flight Live Activity for a recording session.
/// All ActivityKit calls are guarded; the service is a safe no-op on Mac Catalyst.
///
/// Staleness lessons baked in:
/// - The elapsed clock is rendered by the widget itself (`Text(timerInterval:)`),
///   never pushed — ActivityKit throttles frequent updates, which froze the
///   Dynamic Island when we pushed `elapsedSeconds` every second.
/// - Updates are deduplicated: identical states are not re-pushed.
/// - `end()` must capture the Activity BEFORE nilling the property. The old code
///   nilled `self.activity` synchronously and the queued Task then saw nil —
///   the activity was never ended and sat stale on the Lock Screen forever.
@Observable @MainActor
final class LiveActivityService {

    var isSupported: Bool {
#if targetEnvironment(macCatalyst)
        return false
#else
        return ActivityAuthorizationInfo().areActivitiesEnabled
#endif
    }

#if !targetEnvironment(macCatalyst)
    private var activity: Activity<RecordingActivityAttributes>?
    private var startedAt: Date?
    private var pausedAt: Date?
    private var lastPushedState: RecordingActivityAttributes.ContentState?
#endif

    func start(sessionID: UUID) {
#if !targetEnvironment(macCatalyst)
        // A previous activity still on screen (e.g. after a crash)? End it first.
        if let stale = activity {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
            activity = nil
        }
        guard isSupported else { return }
        let now = Date()
        startedAt = now
        pausedAt = nil
        let attrs = RecordingActivityAttributes(sessionID: sessionID)
        let initialState = RecordingActivityAttributes.ContentState(
            wordCount: 0, startedAt: now, pausedAt: nil,
            detectedLanguage: "en", isListening: true
        )
        do {
            let content = ActivityContent(state: initialState, staleDate: nil)
            activity = try Activity.request(attributes: attrs, content: content, pushType: nil)
            lastPushedState = initialState
        } catch { }
#endif
    }

    func update(wordCount: Int, detectedLanguage: String, isListening: Bool) {
#if !targetEnvironment(macCatalyst)
        guard let act = activity, var start = startedAt else { return }

        // Track pause/resume so the widget clock freezes and resumes correctly.
        if !isListening, pausedAt == nil {
            pausedAt = Date()
        } else if isListening, let paused = pausedAt {
            // Shift the start forward by the pause duration so elapsed stays true.
            start += Date().timeIntervalSince(paused)
            startedAt = start
            pausedAt = nil
        }

        let state = RecordingActivityAttributes.ContentState(
            wordCount: wordCount, startedAt: start, pausedAt: pausedAt,
            detectedLanguage: shortCode(from: detectedLanguage), isListening: isListening
        )
        // Dedupe — pushing identical state burns the ActivityKit update budget.
        guard state != lastPushedState else { return }
        lastPushedState = state
        Task { await act.update(ActivityContent(state: state, staleDate: nil)) }
#endif
    }

    func end(wordCount: Int, detectedLanguage: String) {
#if !targetEnvironment(macCatalyst)
        // Capture BEFORE clearing — the async end runs after this scope.
        guard let act = activity, let start = startedAt else { return }
        let state = RecordingActivityAttributes.ContentState(
            wordCount: wordCount, startedAt: start, pausedAt: Date(),
            detectedLanguage: shortCode(from: detectedLanguage), isListening: false
        )
        activity = nil
        startedAt = nil
        pausedAt = nil
        lastPushedState = nil
        Task {
            await act.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .after(Date.now.addingTimeInterval(4))
            )
        }
#endif
    }

    private func shortCode(from bcp47: String) -> String {
        String(bcp47.split(separator: "-").first ?? Substring(bcp47))
    }
}

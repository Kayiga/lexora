@preconcurrency import ActivityKit
import Foundation
import Observation

/// Manages the single in-flight Live Activity for a recording session.
/// Called from AppState on the main actor; all mutation stays on the main actor.
@Observable @MainActor
final class LiveActivityService {

    // MARK: - Public state

    /// Whether the current device supports Live Activities at all.
    var isSupported: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    // MARK: - Private

    private var activity: Activity<RecordingActivityAttributes>?
    private var sessionStart: Date?

    // MARK: - Lifecycle

    /// Starts a new Live Activity for the given session.
    /// Safe to call even on devices that do not support Live Activities.
    func start(sessionID: UUID) {
        guard isSupported, activity == nil else { return }

        let attrs = RecordingActivityAttributes(sessionID: sessionID)
        let initialState = RecordingActivityAttributes.ContentState(
            wordCount: 0,
            elapsedSeconds: 0,
            detectedLanguage: "en",
            isListening: true
        )
        do {
            let content = ActivityContent(state: initialState, staleDate: nil)
            activity = try Activity.request(
                attributes: attrs,
                content: content,
                pushType: nil
            )
            sessionStart = Date()
        } catch {
            // Live Activities not authorised or unavailable on this device — silently ignore.
        }
    }

    /// Pushes a state update to the active Live Activity.
    func update(wordCount: Int, detectedLanguage: String, isListening: Bool) {
        guard let activity, let start = sessionStart else { return }
        let elapsed = Int(Date().timeIntervalSince(start))
        let state = RecordingActivityAttributes.ContentState(
            wordCount: wordCount,
            elapsedSeconds: elapsed,
            detectedLanguage: shortCode(from: detectedLanguage),
            isListening: isListening
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.activity?.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    /// Ends the Live Activity, showing final stats for 3 seconds then dismissing.
    func end(wordCount: Int, detectedLanguage: String) {
        guard let activity, let start = sessionStart else { return }
        let elapsed = Int(Date().timeIntervalSince(start))
        let state = RecordingActivityAttributes.ContentState(
            wordCount: wordCount,
            elapsedSeconds: elapsed,
            detectedLanguage: shortCode(from: detectedLanguage),
            isListening: false
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.activity?.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .after(Date.now.addingTimeInterval(4))
            )
        }
        self.activity = nil
        self.sessionStart = nil
    }

    // MARK: - Helpers

    /// Converts a BCP-47 tag like "en-US" to the short form "en".
    private func shortCode(from bcp47: String) -> String {
        String(bcp47.split(separator: "-").first ?? Substring(bcp47))
    }
}

// ActivityKit is iOS/iPadOS only — not available on Mac Catalyst
#if !targetEnvironment(macCatalyst)
@preconcurrency import ActivityKit
#endif
import Foundation
import Observation

/// Manages the single in-flight Live Activity for a recording session.
/// All ActivityKit calls are guarded; the service is a safe no-op on Mac Catalyst.
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
    private var sessionStart: Date?
#endif

    func start(sessionID: UUID) {
#if !targetEnvironment(macCatalyst)
        guard isSupported, activity == nil else { return }
        let attrs = RecordingActivityAttributes(sessionID: sessionID)
        let initialState = RecordingActivityAttributes.ContentState(
            wordCount: 0, elapsedSeconds: 0, detectedLanguage: "en", isListening: true
        )
        do {
            let content = ActivityContent(state: initialState, staleDate: nil)
            activity = try Activity.request(attributes: attrs, content: content, pushType: nil)
            sessionStart = Date()
        } catch { }
#endif
    }

    func update(wordCount: Int, detectedLanguage: String, isListening: Bool) {
#if !targetEnvironment(macCatalyst)
        guard activity != nil, let start = sessionStart else { return }
        let elapsed = Int(Date().timeIntervalSince(start))
        let state = RecordingActivityAttributes.ContentState(
            wordCount: wordCount, elapsedSeconds: elapsed,
            detectedLanguage: shortCode(from: detectedLanguage), isListening: isListening
        )
        Task { @MainActor [weak self] in
            await self?.activity?.update(ActivityContent(state: state, staleDate: nil))
        }
#endif
    }

    func end(wordCount: Int, detectedLanguage: String) {
#if !targetEnvironment(macCatalyst)
        guard activity != nil, let start = sessionStart else { return }
        let elapsed = Int(Date().timeIntervalSince(start))
        let state = RecordingActivityAttributes.ContentState(
            wordCount: wordCount, elapsedSeconds: elapsed,
            detectedLanguage: shortCode(from: detectedLanguage), isListening: false
        )
        Task { @MainActor [weak self] in
            await self?.activity?.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .after(Date.now.addingTimeInterval(4))
            )
        }
        self.activity = nil
        self.sessionStart = nil
#endif
    }

    private func shortCode(from bcp47: String) -> String {
        String(bcp47.split(separator: "-").first ?? Substring(bcp47))
    }
}

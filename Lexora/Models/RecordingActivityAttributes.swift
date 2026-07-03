import Foundation
#if !targetEnvironment(macCatalyst)
import ActivityKit
#endif

/// Shared Live Activity attributes — compiled into the main app and widget extension.
/// On Mac Catalyst the ActivityAttributes conformance is omitted (ActivityKit unavailable).
///
/// The elapsed timer is NOT pushed as state: ActivityKit rate-limits updates, so a
/// once-per-second `elapsedSeconds` push froze the Dynamic Island with stale data.
/// Instead the state carries `startedAt`, and the widget renders a self-ticking
/// `Text(timerInterval:)` that needs no updates at all. State pushes happen only
/// when the word count / language / listening flag actually change.
#if targetEnvironment(macCatalyst)
struct RecordingActivityAttributes {
    struct ContentState: Codable, Hashable {
        var wordCount: Int
        var startedAt: Date
        var pausedAt: Date?
        var detectedLanguage: String
        var isListening: Bool
        var elapsedFormatted: String {
            let end = pausedAt ?? Date()
            let secs = max(0, Int(end.timeIntervalSince(startedAt)))
            return String(format: "%d:%02d", secs / 60, secs % 60)
        }
    }
    var sessionID: UUID
}
#else
struct RecordingActivityAttributes: ActivityAttributes {
    public typealias RecordingState = ContentState

    public struct ContentState: Codable, Hashable {
        var wordCount: Int
        var startedAt: Date
        var pausedAt: Date?
        var detectedLanguage: String
        var isListening: Bool
        var elapsedFormatted: String {
            let end = pausedAt ?? Date()
            let secs = max(0, Int(end.timeIntervalSince(startedAt)))
            return String(format: "%d:%02d", secs / 60, secs % 60)
        }
    }
    var sessionID: UUID
}
#endif

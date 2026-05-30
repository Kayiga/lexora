import Foundation
#if !targetEnvironment(macCatalyst)
import ActivityKit
#endif

/// Shared Live Activity attributes — compiled into the main app and widget extension.
/// On Mac Catalyst the ActivityAttributes conformance is omitted (ActivityKit unavailable).
#if targetEnvironment(macCatalyst)
struct RecordingActivityAttributes {
    struct ContentState: Codable, Hashable {
        var wordCount: Int
        var elapsedSeconds: Int
        var detectedLanguage: String
        var isListening: Bool
        var elapsedFormatted: String {
            let m = elapsedSeconds / 60; let s = elapsedSeconds % 60
            return String(format: "%d:%02d", m, s)
        }
    }
    var sessionID: UUID
}
#else
struct RecordingActivityAttributes: ActivityAttributes {
    public typealias RecordingState = ContentState

    public struct ContentState: Codable, Hashable {
        var wordCount: Int
        var elapsedSeconds: Int
        var detectedLanguage: String
        var isListening: Bool
        var elapsedFormatted: String {
            let m = elapsedSeconds / 60; let s = elapsedSeconds % 60
            return String(format: "%d:%02d", m, s)
        }
    }
    var sessionID: UUID
}
#endif

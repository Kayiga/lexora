import ActivityKit
import Foundation

/// Shared Live Activity attributes — compiled into both the main app and the widget extension.
/// The static `sessionID` is set once when recording starts.
/// `ContentState` is updated live as recording progresses.
struct RecordingActivityAttributes: ActivityAttributes {
    public typealias RecordingState = ContentState

    public struct ContentState: Codable, Hashable {
        /// Current live word count
        var wordCount: Int
        /// Seconds since recording started
        var elapsedSeconds: Int
        /// BCP-47 code of the detected language
        var detectedLanguage: String
        /// Whether the engine is actively listening (vs. paused / finalising)
        var isListening: Bool

        var elapsedFormatted: String {
            let m = elapsedSeconds / 60
            let s = elapsedSeconds % 60
            return String(format: "%d:%02d", m, s)
        }
    }

    /// Stable identifier so the widget can correlate updates with sessions
    var sessionID: UUID
}

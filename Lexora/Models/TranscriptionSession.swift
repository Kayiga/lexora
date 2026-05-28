import Foundation

// One complete recording + transcription event. Value type for safe Swift 6 concurrency.
struct TranscriptionSession: Identifiable, Codable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var durationSeconds: Double {
        guard let ended = endedAt else { return 0 }
        return ended.timeIntervalSince(startedAt)
    }

    var rawTranscript: String
    var finalTranscript: String
    var segments: [TranscriptSegment]

    var detectedLanguages: [LanguageDetection]
    var primaryLanguage: String
    var codeSwitch: Bool
    var formalityDetected: Double

    var wordCount: Int
    var correctionsMade: Int
    var confidenceAverage: Double
    var estimatedAccuracy: Double

    var appBundleID: String?
    var appName: String?
    var contextProfileID: UUID?

    var audioFileURL: URL?
    var audioFileCloudPath: String?

    var paceWPM: Double
    var pausePattern: [Double]
    var fillerWords: [String]

    var isSyncedToCloud: Bool = false
    var isStarred: Bool = false
    var tags: [String] = []
    /// Optional user-defined title. If nil, the UI falls back to a truncation of the transcript.
    var customTitle: String? = nil
    /// Freeform annotation attached to the session (separate from the transcript).
    var notes: String? = nil
    /// When true, the session is floated to the top of the history list regardless of sort order.
    var isPinned: Bool = false
    /// Archived sessions are hidden from the main history list but kept on disk.
    var isArchived: Bool = false
    /// Locked sessions cannot be edited — their transcript, title, and notes are read-only.
    var isLocked: Bool = false

    /// Named chapter markers: character offsets into `finalTranscript`.
    /// Each chapter begins at its `offset` and runs to the start of the next one.
    var chapters: [TranscriptChapter] = []

    init(contextProfileID: UUID? = nil, appBundleID: String? = nil) {
        self.id = UUID()
        self.startedAt = Date()
        self.rawTranscript = ""
        self.finalTranscript = ""
        self.segments = []
        self.detectedLanguages = []
        self.primaryLanguage = "en"
        self.codeSwitch = false
        self.formalityDetected = 0.5
        self.wordCount = 0
        self.correctionsMade = 0
        self.confidenceAverage = 0
        self.estimatedAccuracy = 0
        self.appBundleID = appBundleID
        self.paceWPM = 0
        self.pausePattern = []
        self.fillerWords = []
        self.contextProfileID = contextProfileID
    }

    mutating func finish(with transcript: String) {
        endedAt = Date()
        finalTranscript = transcript
        wordCount = transcript.split(separator: " ").count
        estimatedAccuracy = confidenceAverage * 100
        codeSwitch = detectedLanguages.count > 1

        // Resolve a friendly app name from the bundle ID if we have one
        if appName == nil, let bundleID = appBundleID {
            appName = Self.friendlyName(for: bundleID)
        }
    }

    /// Returns true when this session contains `query` (case-insensitive) in its
    /// transcript, title, notes, or tags. Used by the history search bar.
    func matches(query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        if finalTranscript.lowercased().contains(q) { return true }
        if rawTranscript.lowercased().contains(q)   { return true }
        if let title = customTitle, title.lowercased().contains(q) { return true }
        if let notes = notes, notes.lowercased().contains(q)       { return true }
        return tags.contains { $0.lowercased().contains(q) }
    }

    // Friendly name lookup for common iOS apps
    private static func friendlyName(for bundleID: String) -> String? {
        let known: [String: String] = [
            "com.apple.MobileSMS": "Messages",
            "com.apple.mobilemail": "Mail",
            "com.apple.mobilenotes": "Notes",
            "com.apple.reminders": "Reminders",
            "com.apple.mobileslideshow": "Photos",
            "com.google.Gmail": "Gmail",
            "com.microsoft.Office.Word": "Word",
            "com.microsoft.Office.Outlook": "Outlook",
            "com.slack.Slack": "Slack",
            "com.apple.Pages": "Pages",
            "com.apple.Keynote": "Keynote",
        ]
        return known[bundleID]
    }
}

/// A named section within a transcript, anchored to a character offset.
struct TranscriptChapter: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// Display name for this chapter.
    var title: String
    /// Character offset in `finalTranscript` where this chapter begins.
    var offset: Int
    /// Optional icon name (SF Symbols).
    var icon: String = "bookmark.fill"
}

struct TranscriptSegment: Codable, Identifiable {
    var id: UUID = UUID()
    var text: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var confidence: Double
    var language: String
    var isFiller: Bool = false
}

struct LanguageDetection: Codable, Identifiable {
    var id: UUID = UUID()
    var language: String
    var confidence: Double
    var firstSeenAt: TimeInterval
    var wordCount: Int
}

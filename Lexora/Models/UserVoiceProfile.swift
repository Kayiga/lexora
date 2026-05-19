import Foundation

// The complete model of who the user is as a speaker.
// Struct so Codable synthesis and Swift 6 concurrency work without issues.
// Observed indirectly via LearningEngine (which IS @Observable).
struct UserVoiceProfile: Identifiable, Codable {
    var id: UUID
    var displayName: String
    var createdAt: Date
    var lastUpdatedAt: Date

    // Language intelligence
    var detectedPrimaryLanguage: String
    var detectedSecondaryLanguages: [String]
    var languageConfidenceHistory: [LanguageSnapshot]

    // Speaking style fingerprint
    var averageSpeakingPaceWPM: Double
    var averagePauseMilliseconds: Double
    var fillerWordFrequency: [String: Int]
    var formalityScore: Double
    var sentenceLengthAverage: Double

    // Vocabulary intelligence
    var customVocabulary: [VocabularyEntry]
    var correctionHistory: [CorrectionEvent]
    var contextProfiles: [ContextProfile]

    // Accent and phoneme patterns
    var accentRegion: String?
    var phonemeSubstitutions: [String: String]

    // Stats
    var totalTranscriptionMinutes: Double
    var totalSessionCount: Int
    var accuracyTrend: [AccuracyDataPoint]

    // Preferences
    var preferredOutputFormality: FormalityMode
    var autoPunctuationEnabled: Bool
    var smartCorrectionEnabled: Bool
    var hapticFeedbackEnabled: Bool
    /// Minimum confidence (0–1) below which partial results are dimmed / ignored.
    var confidenceThreshold: Double
    /// Whether transcriptions are indexed in Spotlight for system search.
    var spotlightIndexingEnabled: Bool
    /// Whether the daily recording reminder notification is active.
    var dailyReminderEnabled: Bool
    /// Hour (0–23) for the daily reminder.
    var dailyReminderHour: Int
    /// Minute (0–59) for the daily reminder.
    var dailyReminderMinute: Int
    /// Whether the morning daily digest notification is active.
    var dailyDigestEnabled: Bool
    /// Hour (0–23) for the daily digest notification.
    var dailyDigestHour: Int
    /// Minute (0–59) for the daily digest notification.
    var dailyDigestMinute: Int
    /// Daily word-count goal. 0 = goal disabled.
    var dailyWordGoal: Int
    /// Whether to automatically stop recording after a configurable silence period.
    var silenceAutoStopEnabled: Bool
    /// Duration of silence (seconds) that triggers auto-stop. Effective only when silenceAutoStopEnabled is true.
    var silenceTimeoutSeconds: Double
    /// User-created recording templates that appear alongside the built-in ones.
    var customTemplates: [CustomRecordingTemplate]
    /// Extra filler words the user wants tracked beyond the built-in set.
    var customFillerWords: [String]
    /// Pre-recording prompt or checklist shown before a recording begins (per template support).
    var recordingPromptEnabled: Bool

    init(displayName: String) {
        self.id = UUID()
        self.displayName = displayName
        self.createdAt = Date()
        self.lastUpdatedAt = Date()
        self.detectedPrimaryLanguage = "en"
        self.detectedSecondaryLanguages = []
        self.languageConfidenceHistory = []
        self.averageSpeakingPaceWPM = 130
        self.averagePauseMilliseconds = 500
        self.fillerWordFrequency = [:]
        self.formalityScore = 0.5
        self.sentenceLengthAverage = 12
        self.customVocabulary = []
        self.correctionHistory = []
        self.contextProfiles = [
            ContextProfile(name: "General", bundleIDs: []),
            ContextProfile(name: "Work",    bundleIDs: []),
            ContextProfile(name: "Messages", bundleIDs: ["com.apple.MobileSMS"])
        ]
        self.accentRegion = nil
        self.phonemeSubstitutions = [:]
        self.totalTranscriptionMinutes = 0
        self.totalSessionCount = 0
        self.accuracyTrend = []
        self.preferredOutputFormality = .adaptive
        self.autoPunctuationEnabled = true
        self.smartCorrectionEnabled = true
        self.hapticFeedbackEnabled = true
        self.confidenceThreshold = 0.5
        self.spotlightIndexingEnabled = true
        self.dailyReminderEnabled = false
        self.dailyReminderHour = 9
        self.dailyReminderMinute = 0
        self.dailyDigestEnabled = false
        self.dailyDigestHour = 8
        self.dailyDigestMinute = 30
        self.dailyWordGoal = 0
        self.silenceAutoStopEnabled = false
        self.silenceTimeoutSeconds = 10
        self.customTemplates = []
        self.customFillerWords = []
        self.recordingPromptEnabled = true
    }

    mutating func touch() {
        lastUpdatedAt = Date()
    }
}

// MARK: - Supporting Types

struct LanguageSnapshot: Codable, Identifiable {
    var id: UUID = UUID()
    var timestamp: Date
    var language: String
    var confidence: Double
    var sessionID: UUID
}

struct CorrectionEvent: Codable, Identifiable {
    var id: UUID = UUID()
    var timestamp: Date
    var originalText: String
    var correctedText: String
    var sessionID: UUID
    var appBundleID: String?
    var phonemeContext: String?
}

struct AccuracyDataPoint: Codable, Identifiable {
    var id: UUID = UUID()
    var date: Date
    var sessionID: UUID
    var wordCount: Int
    var correctionCount: Int
    var accuracyPercent: Double {
        guard wordCount > 0 else { return 100 }
        return max(0, 100.0 - (Double(correctionCount) / Double(wordCount) * 100))
    }
}

struct ContextProfile: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var bundleIDs: [String]
    var vocabularyOverrides: [VocabularyEntry] = []
    var formalityOverride: FormalityMode?
    var isActive: Bool = true
}

// MARK: - Custom Recording Template

/// A user-defined recording template that pre-configures language, formality and tags.
struct CustomRecordingTemplate: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    /// SF Symbol name (e.g. "briefcase.fill").
    var icon: String
    /// One of a fixed palette of color names (see `color`).
    var colorName: String
    var formality: FormalityMode?
    var defaultLanguage: String?
    /// Tags automatically applied to every session started with this template.
    var defaultTags: [String]
    /// Optional pre-recording prompt or checklist text shown before the session begins.
    var recordingPrompt: String?

    /// Curated icon options shown in the editor.
    static let availableIcons: [String] = [
        "mic.fill", "briefcase.fill", "graduationcap.fill", "pencil.line",
        "doc.text.fill", "mic.and.signal.meter.fill", "calendar", "clock",
        "map.fill", "phone.fill", "person.2.fill", "brain.head.profile",
        "star.fill", "bookmark.fill", "tag.fill", "folder.fill",
        "message.fill", "chart.bar.fill", "lightbulb.fill", "music.note"
    ]

    /// Fixed color palette (name → SwiftUI Color resolved at runtime).
    static let availableColors: [(name: String, label: String)] = [
        ("blue",   "Blue"),
        ("purple", "Purple"),
        ("green",  "Green"),
        ("orange", "Orange"),
        ("red",    "Red"),
        ("teal",   "Teal"),
        ("pink",   "Pink"),
        ("indigo", "Indigo"),
        ("yellow", "Yellow")
    ]
}

enum FormalityMode: String, Codable, CaseIterable {
    case casual        = "Casual"
    case adaptive      = "Adaptive"
    case professional  = "Professional"
    case verbatim      = "Verbatim"

    var description: String {
        switch self {
        case .casual:       return "Relaxed, conversational output"
        case .adaptive:     return "Matches the context automatically"
        case .professional: return "Formal, punctuated prose"
        case .verbatim:     return "Exactly as spoken, including fillers"
        }
    }
}

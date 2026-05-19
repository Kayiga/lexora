import AppIntents
import SwiftUI

// MARK: - TranscriptionSession AppEntity
// Exposes TranscriptionSession to the Shortcuts app so users can work with
// individual sessions via Siri and the Shortcuts automation editor.

struct SessionEntity: AppEntity {
    nonisolated(unsafe) static var typeDisplayRepresentation: TypeDisplayRepresentation = "Recording Session"
    nonisolated(unsafe) static var defaultQuery = SessionEntityQuery()

    var id: UUID
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(wordCount) words · \(language)"
        )
    }

    let title: String
    let wordCount: Int
    let language: String
    let startedAt: Date
    let transcript: String

    init(session: TranscriptionSession) {
        self.id = session.id
        self.title = session.customTitle
            ?? (session.finalTranscript.prefix(40).isEmpty ? "Recording" : String(session.finalTranscript.prefix(40)))
        self.wordCount = session.wordCount
        self.language = session.primaryLanguage
        self.startedAt = session.startedAt
        self.transcript = session.finalTranscript
    }
}

struct SessionEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [SessionEntity] {
        guard let appState = AppStateHolder.shared else { return [] }
        return appState.sessions
            .filter { identifiers.contains($0.id) }
            .map { SessionEntity(session: $0) }
    }

    @MainActor
    func suggestedEntities() async throws -> [SessionEntity] {
        guard let appState = AppStateHolder.shared else { return [] }
        return appState.sessions.prefix(5).map { SessionEntity(session: $0) }
    }
}

/// Weak bridge so App Intents (which run outside the main app lifecycle)
/// can still access the shared AppState after the app has launched.
/// Populated once in `AppState.init()`.
@MainActor
final class AppStateHolder {
    static weak var shared: AppState?
}

// MARK: - Get Latest Session Intent

struct GetLatestSessionIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Get Latest Recording"
    nonisolated(unsafe) static var description = IntentDescription(
        "Returns the most recent Lexora recording session.",
        categoryName: "History"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<SessionEntity?> {
        guard let appState = AppStateHolder.shared,
              let latest = appState.sessions.first else {
            return .result(value: nil, dialog: "You don't have any Lexora recordings yet.")
        }
        let entity = SessionEntity(session: latest)
        return .result(value: entity, dialog: "Your most recent session had \(entity.wordCount) words.")
    }
}

// MARK: - Notification Name (shared across all intents)

extension Notification.Name {
    static let lexoraStartRecording    = Notification.Name("com.yiga.Lexora.startRecording")
    static let lexoraOpenHistory       = Notification.Name("com.yiga.Lexora.openHistory")
    static let lexoraOpenProfile       = Notification.Name("com.yiga.Lexora.openProfile")
    /// Posted with `userInfo: ["query": String]` to pre-fill the history search box.
    static let lexoraSearchHistory     = Notification.Name("com.yiga.Lexora.searchHistory")
    /// Posted after a session ends so the app delegate can refresh dynamic Quick Actions.
    static let lexoraRefreshQuickActions = Notification.Name("com.yiga.Lexora.refreshQuickActions")
}

// MARK: - Start Recording Intent

/// "Hey Siri, start a Lexora recording"
struct StartRecordingIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Start Recording"
    nonisolated(unsafe) static var description = IntentDescription(
        "Opens Lexora and starts a new voice recording session.",
        categoryName: "Recording"
    )
    nonisolated(unsafe) static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NotificationCenter.default.post(name: .lexoraStartRecording, object: nil)
        return .result(dialog: "Starting a new Lexora recording.")
    }
}

// MARK: - Show History Intent

/// "Hey Siri, show my Lexora history"
struct ShowHistoryIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Show Recording History"
    nonisolated(unsafe) static var description = IntentDescription(
        "Opens Lexora and navigates to your recording history.",
        categoryName: "History"
    )
    nonisolated(unsafe) static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NotificationCenter.default.post(name: .lexoraOpenHistory, object: nil)
        return .result(dialog: "Here's your Lexora recording history.")
    }
}

// MARK: - Open Voice Profile Intent

/// "Hey Siri, open my Lexora profile"
struct OpenVoiceProfileIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Open Voice Profile"
    nonisolated(unsafe) static var description = IntentDescription(
        "Opens Lexora and shows your learned voice profile and vocabulary.",
        categoryName: "Profile"
    )
    nonisolated(unsafe) static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NotificationCenter.default.post(name: .lexoraOpenProfile, object: nil)
        return .result(dialog: "Opening your Lexora voice profile.")
    }
}

// MARK: - Copy Latest Transcript Intent

/// Copies the transcript of the most recent session to the clipboard — very
/// handy as the last step in a Shortcuts workflow.
struct CopyLatestTranscriptIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Copy Latest Transcript"
    nonisolated(unsafe) static var description = IntentDescription(
        "Copies the text of the most recent Lexora recording to the clipboard.",
        categoryName: "History"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String?> {
        guard let appState = AppStateHolder.shared,
              let latest = appState.sessions.first,
              !latest.finalTranscript.isEmpty else {
            return .result(value: nil, dialog: "No recent transcript found.")
        }
        UIPasteboard.general.string = latest.finalTranscript
        return .result(
            value: latest.finalTranscript,
            dialog: "Copied \(latest.wordCount) words to the clipboard."
        )
    }
}

// MARK: - Start Recording in Language Intent

/// Starts a recording session pre-locked to a specific BCP-47 language code.
/// Useful for users who regularly dictate in multiple languages.
struct StartRecordingInLanguageIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Start Recording in Language"
    nonisolated(unsafe) static var description = IntentDescription(
        "Opens Lexora and starts recording pre-set to a specific language.",
        categoryName: "Recording"
    )
    nonisolated(unsafe) static var openAppWhenRun: Bool = true

    @Parameter(title: "Language code", description: "BCP-47 code, e.g. es-ES, fr-FR, ja-JP")
    var languageCode: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // `openAppWhenRun = true` guarantees the app is foreground before this runs.
        // Post the standard start-recording notification with the language in userInfo.
        NotificationCenter.default.post(
            name: .lexoraStartRecording,
            object: nil,
            userInfo: ["language": languageCode]
        )
        return .result(dialog: "Starting a Lexora recording in \(languageCode).")
    }
}

// MARK: - Search Sessions Intent

/// Returns sessions whose transcript or title contains the given search text.
struct SearchSessionsIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Search Recordings"
    nonisolated(unsafe) static var description = IntentDescription(
        "Returns Lexora sessions whose transcript contains the search text.",
        categoryName: "History"
    )

    @Parameter(title: "Search text")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[SessionEntity]> {
        guard let appState = AppStateHolder.shared else {
            return .result(value: [], dialog: "Lexora is not running.")
        }
        let q = query.lowercased()
        let matches = appState.sessions
            .filter {
                $0.finalTranscript.lowercased().contains(q)
                || ($0.customTitle ?? "").lowercased().contains(q)
                || $0.tags.contains { $0.lowercased().contains(q) }
            }
            .prefix(10)
            .map { SessionEntity(session: $0) }

        return .result(
            value: Array(matches),
            dialog: "\(matches.count) recording\(matches.count == 1 ? "" : "s") matched \"\(query)\"."
        )
    }
}

// MARK: - Get Today's Stats Intent

struct GetTodayStatsIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Get Today's Stats"
    nonisolated(unsafe) static var description = IntentDescription(
        "Returns today's word count, session count, and goal progress.",
        categoryName: "Statistics"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appState = AppStateHolder.shared else {
            return .result(dialog: "Lexora couldn't load your data.")
        }
        let cal = Calendar.current
        let todaySessions = appState.sessions.filter { cal.isDateInToday($0.startedAt) }
        let todayWords = todaySessions.reduce(0) { $0 + $1.wordCount }
        let goal = appState.profile.dailyWordGoal
        var dialog = "Today you have \(todayWords) word\(todayWords == 1 ? "" : "s") across \(todaySessions.count) session\(todaySessions.count == 1 ? "" : "s")."
        if goal > 0 {
            let pct = min(100, Int((Double(todayWords) / Double(goal)) * 100))
            dialog += " That's \(pct)% of your \(goal)-word daily goal."
        }
        return .result(dialog: "\(dialog)")
    }
}

// MARK: - Add Quick Note Intent

struct AddQuickNoteIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Add Quick Note"
    nonisolated(unsafe) static var description = IntentDescription(
        "Saves a text note as a Lexora session.",
        categoryName: "Recording"
    )

    @Parameter(title: "Note text")
    var noteText: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appState = AppStateHolder.shared else {
            return .result(dialog: "Lexora couldn't save your note.")
        }
        guard !noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .result(dialog: "The note was empty.")
        }
        appState.addManualSession(text: noteText)
        let words = noteText.split(separator: " ").count
        return .result(dialog: "Saved your note — \(words) word\(words == 1 ? "" : "s").")
    }
}

// MARK: - Star / Unstar Session Intent

/// Toggles the starred (bookmarked) flag on the most recent session, or a
/// named session resolved from the AppEntity query.
struct StarSessionIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Star a Recording"
    nonisolated(unsafe) static var description = IntentDescription(
        "Toggles the star on a Lexora recording. If no session is provided, stars the most recent one.",
        categoryName: "History"
    )

    @Parameter(title: "Recording")
    var session: SessionEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appState = AppStateHolder.shared else {
            return .result(dialog: "Lexora couldn't access your recordings.")
        }
        let target: TranscriptionSession?
        if let entity = session {
            target = appState.sessions.first { $0.id == entity.id }
        } else {
            target = appState.sessions.first
        }
        guard let s = target else {
            return .result(dialog: "No recording found.")
        }
        let wasStarred = s.isStarred
        appState.toggleStar(s)
        let title = s.customTitle ?? String(s.finalTranscript.prefix(30))
        let action = wasStarred ? "Unstarred" : "Starred"
        return .result(dialog: "\(action) \"\(title)\".")
    }
}

// MARK: - Set Daily Goal Intent

struct SetDailyGoalIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Set Daily Word Goal"
    nonisolated(unsafe) static var description = IntentDescription(
        "Updates your Lexora daily word-count goal.",
        categoryName: "Statistics"
    )

    @Parameter(title: "Words", description: "Target word count per day (0 = no goal)", inclusiveRange: (0, 50000))
    var words: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appState = AppStateHolder.shared else {
            return .result(dialog: "Lexora couldn't update your goal.")
        }
        appState.profile.dailyWordGoal = words
        if words == 0 {
            return .result(dialog: "Daily word goal removed.")
        } else {
            return .result(dialog: "Daily goal set to \(words) words.")
        }
    }
}

// MARK: - Get Word Count for a Session Intent

struct GetSessionWordCountIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Get Recording Word Count"
    nonisolated(unsafe) static var description = IntentDescription(
        "Returns the word count for a specific Lexora recording.",
        categoryName: "Statistics"
    )

    @Parameter(title: "Recording")
    var session: SessionEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        guard let appState = AppStateHolder.shared,
              let s = appState.sessions.first(where: { $0.id == session.id }) else {
            return .result(value: 0, dialog: "Recording not found.")
        }
        return .result(
            value: s.wordCount,
            dialog: "That recording has \(s.wordCount) word\(s.wordCount == 1 ? "" : "s")."
        )
    }
}

// MARK: - Export Latest Transcript Intent

/// Returns the full text of the most recent (or a specified) session as a
/// plain String for use in downstream Shortcuts actions (e.g. send via Mail).
struct ExportTranscriptIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Export Transcript Text"
    nonisolated(unsafe) static var description = IntentDescription(
        "Returns the full transcript text of a Lexora recording for use in other Shortcuts actions.",
        categoryName: "History"
    )

    @Parameter(title: "Recording")
    var session: SessionEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String?> {
        guard let appState = AppStateHolder.shared else {
            return .result(value: nil, dialog: "Lexora couldn't access your recordings.")
        }
        let target: TranscriptionSession?
        if let entity = session {
            target = appState.sessions.first { $0.id == entity.id }
        } else {
            target = appState.sessions.first
        }
        guard let s = target, !s.finalTranscript.isEmpty else {
            return .result(value: nil, dialog: "No transcript found.")
        }
        return .result(
            value: s.finalTranscript,
            dialog: "Here's the transcript — \(s.wordCount) words."
        )
    }
}

// MARK: - App Shortcuts Provider

struct LexoraShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Start a \(.applicationName) recording",
                "Record with \(.applicationName)",
                "Open \(.applicationName) and record",
                "Start recording in \(.applicationName)",
                "New \(.applicationName) session"
            ],
            shortTitle: "Start Recording",
            systemImageName: "mic.fill"
        )

        AppShortcut(
            intent: ShowHistoryIntent(),
            phrases: [
                "Show my \(.applicationName) history",
                "Open \(.applicationName) history",
                "View \(.applicationName) recordings",
                "Recent \(.applicationName) sessions"
            ],
            shortTitle: "Show History",
            systemImageName: "clock.fill"
        )

        AppShortcut(
            intent: OpenVoiceProfileIntent(),
            phrases: [
                "Open my \(.applicationName) profile",
                "Show \(.applicationName) voice profile",
                "My \(.applicationName) vocabulary"
            ],
            shortTitle: "Voice Profile",
            systemImageName: "person.wave.2.fill"
        )

        AppShortcut(
            intent: GetLatestSessionIntent(),
            phrases: [
                "Get my latest \(.applicationName) session",
                "What did I last record in \(.applicationName)",
                "Show my last \(.applicationName) recording"
            ],
            shortTitle: "Latest Recording",
            systemImageName: "clock.badge.checkmark"
        )

        AppShortcut(
            intent: CopyLatestTranscriptIntent(),
            phrases: [
                "Copy my latest \(.applicationName) transcript",
                "Copy last \(.applicationName) recording text",
                "Get \(.applicationName) transcript"
            ],
            shortTitle: "Copy Transcript",
            systemImageName: "doc.on.clipboard"
        )

        AppShortcut(
            intent: SearchSessionsIntent(),
            phrases: [
                "Search my \(.applicationName) recordings",
                "Find a \(.applicationName) recording"
            ],
            shortTitle: "Search Recordings",
            systemImageName: "magnifyingglass"
        )

        AppShortcut(
            intent: GetTodayStatsIntent(),
            phrases: [
                "What did I record today in \(.applicationName)",
                "My \(.applicationName) stats today",
                "How many words in \(.applicationName) today"
            ],
            shortTitle: "Today's Stats",
            systemImageName: "chart.bar.fill"
        )

        AppShortcut(
            intent: AddQuickNoteIntent(),
            phrases: [
                "Add a note to \(.applicationName)",
                "Save a note in \(.applicationName)"
            ],
            shortTitle: "Add Quick Note",
            systemImageName: "square.and.pencil"
        )

        AppShortcut(
            intent: StarSessionIntent(),
            phrases: [
                "Star my latest \(.applicationName) recording",
                "Bookmark the last \(.applicationName) session"
            ],
            shortTitle: "Star Recording",
            systemImageName: "star.fill"
        )

        AppShortcut(
            intent: SetDailyGoalIntent(),
            phrases: [
                "Set my \(.applicationName) daily goal",
                "Change my \(.applicationName) word goal"
            ],
            shortTitle: "Set Daily Goal",
            systemImageName: "target"
        )

    }
}

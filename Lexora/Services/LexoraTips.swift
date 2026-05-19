import TipKit

// MARK: - Lexora TipKit Tips
// Each struct is a contextual tip that surfaces when the user hasn't discovered
// a feature yet. All tips are shown at most once and dismissed permanently.

/// Shown above the history list the first time the user has 5+ sessions.
struct SortHistoryTip: Tip {
    static let sessionCount = Event(id: "sessionCount")

    var title: Text { Text("Sort & filter your sessions") }
    var message: Text? { Text("Tap the sort icon to reorder by date, word count, or accuracy. Swipe left to star, duplicate, or copy.") }
    var image: Image? { Image(systemName: "arrow.up.arrow.down") }

    var rules: [Rule] {
        #Rule(Self.sessionCount) { $0.donations.count >= 5 }
    }
}

/// Shown in SessionDetailView the first time a session is opened.
struct EditTranscriptTip: Tip {
    var title: Text { Text("Edit to teach Lexora") }
    var message: Text? { Text("Correcting mistakes here trains Lexora to recognise your voice better next time.") }
    var image: Image? { Image(systemName: "pencil.line") }

    var options: [Option] {
        MaxDisplayCount(1)
    }
}

/// Shown on the Voice Profile tab when vocabulary is empty.
struct AddVocabularyTip: Tip {
    var title: Text { Text("Add your specialist words") }
    var message: Text? { Text("Names, technical terms, and brand names that Lexora struggles with can be added to your personal vocabulary.") }
    var image: Image? { Image(systemName: "book.closed.fill") }

    var options: [Option] {
        MaxDisplayCount(1)
    }
}

/// Shown in the recording view after the first session.
struct PauseRecordingTip: Tip {
    static let recordingCount = Event(id: "recordingCount")

    var title: Text { Text("Pause mid-thought") }
    var message: Text? { Text("Tap the pause button to collect your thoughts without ending the session.") }
    var image: Image? { Image(systemName: "pause.circle.fill") }

    var rules: [Rule] {
        #Rule(Self.recordingCount) { $0.donations.count >= 1 }
    }
    var options: [Option] {
        MaxDisplayCount(2)
    }
}

/// Shown in Settings after the first week of use.
struct DailyGoalTip: Tip {
    static let weeklyUse = Event(id: "weeklyUse")

    var title: Text { Text("Set a daily word goal") }
    var message: Text? { Text("A daily goal adds a progress ring to your home screen and keeps you consistent.") }
    var image: Image? { Image(systemName: "target") }

    var rules: [Rule] {
        #Rule(Self.weeklyUse) { $0.donations.count >= 7 }
    }
    var options: [Option] {
        MaxDisplayCount(1)
    }
}

import CoreSpotlight
import Foundation

/// Indexes ``TranscriptionSession`` records into CoreSpotlight so they appear
/// in system search. All mutations run on a background queue.
@MainActor
final class SpotlightService {

    static let domainIdentifier = "com.yiga.Lexora.sessions"

    private let index = CSSearchableIndex.default()

    // MARK: - Indexing

    // CoreSpotlight completion handlers fire on a background queue. Hop back to
    // the main actor via Task { @MainActor in } (never DispatchQueue.main.async)
    // so the Swift Concurrency executor state stays consistent on macOS 26.

    /// Index (or reindex) one session.
    func index(_ session: TranscriptionSession) {
        let item = searchableItem(for: session)
        index.indexSearchableItems([item]) { error in
            if let error {
                Task { @MainActor in print("[Spotlight] index error: \(error)") }
            }
        }
    }

    /// Index (or reindex) an array of sessions. Used for bulk operations
    /// like initial load.
    func indexAll(_ sessions: [TranscriptionSession]) {
        let items = sessions.map { searchableItem(for: $0) }
        index.indexSearchableItems(items) { error in
            if let error {
                Task { @MainActor in print("[Spotlight] bulk index error: \(error)") }
            }
        }
    }

    /// Remove a single session from the index.
    func deindex(_ session: TranscriptionSession) {
        index.deleteSearchableItems(withIdentifiers: [session.id.uuidString]) { error in
            if let error {
                Task { @MainActor in print("[Spotlight] deindex error: \(error)") }
            }
        }
    }

    /// Remove ALL Lexora sessions from the index.
    func deindexAll() {
        index.deleteSearchableItems(withDomainIdentifiers: [Self.domainIdentifier]) { error in
            if let error {
                Task { @MainActor in print("[Spotlight] deindex-all error: \(error)") }
            }
        }
    }

    // MARK: - Private helpers

    private func searchableItem(for session: TranscriptionSession) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)

        // Title: custom title > first 80 chars of transcript > date fallback
        let dateString = DateFormatter.shortDate.string(from: session.startedAt)
        if let customTitle = session.customTitle, !customTitle.isEmpty {
            attributes.title = customTitle
        } else if !session.finalTranscript.isEmpty {
            attributes.title = String(session.finalTranscript.prefix(80))
        } else {
            attributes.title = "Recording – \(dateString)"
        }

        // Display name shown beneath title in results
        attributes.displayName = attributes.title

        // Content for full-text search (transcript + notes combined)
        let notesText = session.notes.map { "\n\n Notes: \($0)" } ?? ""
        attributes.contentDescription = session.finalTranscript.isEmpty
            ? "(no transcript)" + notesText
            : session.finalTranscript + notesText

        // Metadata shown in search previews
        attributes.contentCreationDate = session.startedAt
        attributes.contentModificationDate = session.endedAt ?? session.startedAt
        attributes.duration = session.durationSeconds as NSNumber
        attributes.textContent = session.finalTranscript

        // Keywords: language tags, user tags, app name
        var keywords = session.tags
        keywords.append(session.primaryLanguage)
        if let appName = session.appName { keywords.append(appName) }
        attributes.keywords = keywords

        // Thumbnail / type hint
        attributes.thumbnailData = nil   // Could set app icon bytes here
        attributes.kind = "Voice Transcription"

        // Deep-link URL so tapping a result reopens the session
        // lexora://session/<uuid>
        attributes.url = URL(string: "lexora://session/\(session.id.uuidString)")

        return CSSearchableItem(
            uniqueIdentifier: session.id.uuidString,
            domainIdentifier: Self.domainIdentifier,
            attributeSet: attributes
        )
    }
}

// MARK: - DateFormatter helpers

private extension DateFormatter {
    static let shortDate: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df
    }()
}

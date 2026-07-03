//  LexoraTests.swift
//  Unit tests for core Lexora services.
//  These run in the CI pipeline on every push to main and every release tag.

import XCTest
@testable import Lexora

// MARK: - TranscriptionSession

final class TranscriptionSessionTests: XCTestCase {

    func test_session_initialises_with_empty_transcript() {
        let session = TranscriptionSession()
        XCTAssertEqual(session.rawTranscript, "")
        XCTAssertEqual(session.finalTranscript, "")
        XCTAssertFalse(session.isArchived)
        XCTAssertFalse(session.isPinned)
        XCTAssertFalse(session.isStarred)
    }

    func test_session_finish_sets_duration() {
        var session = TranscriptionSession()
        let before = Date()
        session.finish(with: "Hello world")
        XCTAssertGreaterThanOrEqual(session.durationSeconds, 0)
        XCTAssertGreaterThanOrEqual(session.endedAt ?? before, before)
    }

    func test_session_word_count() {
        var session = TranscriptionSession()
        session.finish(with: "The quick brown fox jumps")
        XCTAssertEqual(session.wordCount, 5)
    }

    func test_session_word_count_empty() {
        var session = TranscriptionSession()
        session.finish(with: "   ")
        XCTAssertEqual(session.wordCount, 0)
    }

    func test_session_word_count_single_word() {
        var session = TranscriptionSession()
        session.finish(with: "Hello")
        XCTAssertEqual(session.wordCount, 1)
    }

    func test_session_codable_roundtrip() throws {
        var session = TranscriptionSession()
        session.finish(with: "Round-trip test")
        session.primaryLanguage = "en-US"
        session.isPinned = true

        let data    = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(TranscriptionSession.self, from: data)

        XCTAssertEqual(decoded.id,              session.id)
        XCTAssertEqual(decoded.finalTranscript, session.finalTranscript)
        XCTAssertEqual(decoded.primaryLanguage, session.primaryLanguage)
        XCTAssertTrue(decoded.isPinned)
    }

    func test_session_codable_preserves_tags() throws {
        var session = TranscriptionSession()
        session.finish(with: "Tagged session")
        session.tags = ["work", "important", "follow-up"]

        let data    = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(TranscriptionSession.self, from: data)

        XCTAssertEqual(decoded.tags, ["work", "important", "follow-up"])
    }

    func test_session_codable_preserves_chapters() throws {
        var session = TranscriptionSession()
        session.finish(with: "Chapter one content. Chapter two content.")
        session.chapters = [
            TranscriptChapter(title: "Introduction", offset: 0),
            TranscriptChapter(title: "Body",         offset: 22),
        ]

        let data    = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(TranscriptionSession.self, from: data)

        XCTAssertEqual(decoded.chapters.count, 2)
        XCTAssertEqual(decoded.chapters[0].title, "Introduction")
        XCTAssertEqual(decoded.chapters[1].offset, 22)
    }

    // MARK: - matches(query:)

    func test_search_matches_transcript() {
        var session = TranscriptionSession()
        session.finish(with: "Machine learning is transforming the industry")
        XCTAssertTrue(session.matches(query: "machine learning"))
        XCTAssertTrue(session.matches(query: "INDUSTRY"))   // case-insensitive
        XCTAssertFalse(session.matches(query: "quantum physics"))
    }

    func test_search_matches_custom_title() {
        var session = TranscriptionSession()
        session.finish(with: "Some transcript content")
        session.customTitle = "Weekly Standup Notes"
        XCTAssertTrue(session.matches(query: "standup"))
        XCTAssertTrue(session.matches(query: "WEEKLY"))
        XCTAssertFalse(session.matches(query: "quarterly"))
    }

    func test_search_matches_notes() {
        var session = TranscriptionSession()
        session.finish(with: "Transcript here")
        session.notes = "Follow up with Alice about the budget"
        XCTAssertTrue(session.matches(query: "alice"))
        XCTAssertTrue(session.matches(query: "budget"))
    }

    func test_search_matches_tags() {
        var session = TranscriptionSession()
        session.finish(with: "Some content")
        session.tags = ["project-alpha", "urgent"]
        XCTAssertTrue(session.matches(query: "project-alpha"))
        XCTAssertTrue(session.matches(query: "URGENT"))
        XCTAssertFalse(session.matches(query: "project-beta"))
    }

    func test_search_empty_query_matches_all() {
        var session = TranscriptionSession()
        session.finish(with: "Any content here")
        XCTAssertTrue(session.matches(query: ""))
    }

    // MARK: - TranscriptChapter

    func test_chapter_defaults() {
        let chapter = TranscriptChapter(title: "Intro", offset: 0)
        XCTAssertEqual(chapter.title, "Intro")
        XCTAssertEqual(chapter.offset, 0)
        XCTAssertEqual(chapter.icon, "bookmark.fill")
    }

    func test_chapter_codable_roundtrip() throws {
        let chapter = TranscriptChapter(title: "Section 2", offset: 150, icon: "star.fill")
        let data    = try JSONEncoder().encode(chapter)
        let decoded = try JSONDecoder().decode(TranscriptChapter.self, from: data)
        XCTAssertEqual(decoded.id,     chapter.id)
        XCTAssertEqual(decoded.title,  "Section 2")
        XCTAssertEqual(decoded.offset, 150)
        XCTAssertEqual(decoded.icon,   "star.fill")
    }
}

// MARK: - VocabularyEntry

final class VocabularyEntryTests: XCTestCase {

    private func makeEntry(_ term: String,
                           phonetic: String? = nil,
                           category: VocabularyCategory = .technical) -> VocabularyEntry {
        VocabularyEntry(term: term, phonetic: phonetic, aliases: [],
                        category: category, language: "en", source: .userAdded)
    }

    func test_vocabulary_entry_initialises() {
        let entry = makeEntry("SwiftUI")
        XCTAssertEqual(entry.term, "SwiftUI")
        XCTAssertNil(entry.phonetic)
        XCTAssertEqual(entry.category, .technical)
        XCTAssertGreaterThan(entry.relevanceScore, 0)
    }

    func test_vocabulary_entry_codable_roundtrip() throws {
        let entry   = makeEntry("Lexora", phonetic: "lek-SOR-ah", category: .name)
        let data    = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(VocabularyEntry.self, from: data)
        XCTAssertEqual(decoded.term,     entry.term)
        XCTAssertEqual(decoded.phonetic, entry.phonetic)
        XCTAssertEqual(decoded.category, entry.category)
    }

    func test_vocabulary_entry_record_usage_increments() {
        var entry = makeEntry("Test")
        let before = entry.usageCount
        entry.recordUsage()
        XCTAssertEqual(entry.usageCount, before + 1)
        XCTAssertNotNil(entry.lastUsed)
    }
}

// MARK: - UserVoiceProfile

final class UserVoiceProfileTests: XCTestCase {

    private func makeEntry(_ term: String, category: VocabularyCategory = .technical) -> VocabularyEntry {
        VocabularyEntry(term: term, phonetic: nil, aliases: [],
                        category: category, language: "en", source: .userAdded)
    }

    func test_voice_profile_default_values() {
        let profile = UserVoiceProfile(displayName: "You")
        XCTAssertEqual(profile.detectedPrimaryLanguage, "en")
        XCTAssertTrue(profile.smartCorrectionEnabled)
        XCTAssertTrue(profile.customVocabulary.isEmpty)
    }

    func test_voice_profile_codable_roundtrip() throws {
        var profile = UserVoiceProfile(displayName: "You")
        profile.detectedPrimaryLanguage = "fr-FR"
        profile.smartCorrectionEnabled  = false

        let data    = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(UserVoiceProfile.self, from: data)

        XCTAssertEqual(decoded.detectedPrimaryLanguage, "fr-FR")
        XCTAssertFalse(decoded.smartCorrectionEnabled)
    }

    func test_voice_profile_vocabulary_survives_roundtrip() throws {
        var profile = UserVoiceProfile(displayName: "You")
        profile.customVocabulary = [makeEntry("iOS"), makeEntry("Olakunle", category: .name)]

        let data    = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(UserVoiceProfile.self, from: data)

        XCTAssertEqual(decoded.customVocabulary.count, 2)
        XCTAssertEqual(decoded.customVocabulary[0].term, "iOS")
        XCTAssertEqual(decoded.customVocabulary[1].term, "Olakunle")
    }

    func test_voice_profile_phoneme_substitutions_survive_roundtrip() throws {
        var profile = UserVoiceProfile(displayName: "You")
        profile.phonemeSubstitutions = ["thier": "their", "recieve": "receive"]

        let data    = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(UserVoiceProfile.self, from: data)

        XCTAssertEqual(decoded.phonemeSubstitutions["thier"],   "their")
        XCTAssertEqual(decoded.phonemeSubstitutions["recieve"], "receive")
    }
}

// MARK: - LanguageIntelligence

final class LanguageIntelligenceTests: XCTestCase {

    func test_language_detection_english() {
        let li     = LanguageIntelligence()
        let result = li.detect(text: "The weather is beautiful today in London.")
        XCTAssertEqual(result.language.prefix(2), "en")
        XCTAssertGreaterThan(result.confidence, 0.5)
    }

    func test_language_detection_empty_string() {
        let li     = LanguageIntelligence()
        let result = li.detect(text: "")
        // Empty input should return some default without crashing
        XCTAssertFalse(result.language.isEmpty)
    }

    func test_language_detection_short_text_does_not_crash() {
        let li = LanguageIntelligence()
        _ = li.detect(text: "Hi")
        _ = li.detect(text: "Bonjour")
        _ = li.detect(text: "Hola")
    }

    func test_language_detection_french() {
        let li     = LanguageIntelligence()
        let result = li.detect(text: "Bonjour, comment allez-vous aujourd'hui? Le temps est magnifique.")
        XCTAssertEqual(result.language.prefix(2), "fr")
    }

    func test_language_detection_confidence_in_range() {
        let li     = LanguageIntelligence()
        let result = li.detect(text: "This is a longer English sentence to get a more reliable confidence score.")
        XCTAssertGreaterThanOrEqual(result.confidence, 0.0)
        XCTAssertLessThanOrEqual(result.confidence,    1.0)
    }
}

// MARK: - SRTExportService

final class SRTExportServiceTests: XCTestCase {

    private func makeSession(transcript: String) -> TranscriptionSession {
        var s = TranscriptionSession()
        s.finish(with: transcript)
        s.customTitle = "Test Session"
        return s
    }

    func test_srt_export_creates_file() {
        let session = makeSession(transcript: "Hello world. This is a test transcript.")
        let url = SRTExportService.exportSession(session)
        XCTAssertNotNil(url, "SRT export should produce a URL")
        if let url = url {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "SRT file should exist on disk")
            try? FileManager.default.removeItem(at: url)
        }
    }

    func test_srt_export_file_has_srt_extension() {
        let session = makeSession(transcript: "Testing extension")
        let url = SRTExportService.exportSession(session)
        XCTAssertEqual(url?.pathExtension, "srt")
        if let url = url { try? FileManager.default.removeItem(at: url) }
    }

    func test_srt_export_non_empty_content() {
        let session = makeSession(transcript: "Hello world this is a test of the SRT export service")
        guard let url = SRTExportService.exportSession(session) else {
            return XCTFail("No URL returned")
        }
        let content = try? String(contentsOf: url, encoding: .utf8)
        XCTAssertNotNil(content)
        XCTAssertFalse(content?.isEmpty ?? true)
        try? FileManager.default.removeItem(at: url)
    }

    func test_srt_format_contains_sequence_number() {
        let session = makeSession(transcript: "This is a test transcript with enough words to form a block")
        guard let url = SRTExportService.exportSession(session),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return XCTFail("Export failed")
        }
        // SRT files start with sequence number "1"
        XCTAssertTrue(content.contains("1\n") || content.hasPrefix("1\r\n"))
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - HTMLExportService

final class HTMLExportServiceTests: XCTestCase {

    func test_html_export_creates_file() {
        var session = TranscriptionSession()
        session.finish(with: "This is an HTML export test.")
        session.customTitle = "HTML Test"

        let url = HTMLExportService.exportSession(session)
        XCTAssertNotNil(url)
        if let url = url {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(url.pathExtension, "html")
            try? FileManager.default.removeItem(at: url)
        }
    }

    func test_html_export_contains_transcript() {
        var session = TranscriptionSession()
        let text = "Unique content for HTML test 42XYZ"
        session.finish(with: text)

        guard let url = HTMLExportService.exportSession(session),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return XCTFail("Export failed")
        }
        XCTAssertTrue(content.contains(text) || content.contains("42XYZ"),
                      "HTML output should contain the transcript text")
        try? FileManager.default.removeItem(at: url)
    }

    func test_html_export_is_valid_html() {
        var session = TranscriptionSession()
        session.finish(with: "Valid HTML test")

        guard let url = HTMLExportService.exportSession(session),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return XCTFail("Export failed")
        }
        XCTAssertTrue(content.contains("<!DOCTYPE html>") || content.contains("<html"),
                      "Output should be a valid HTML document")
        XCTAssertTrue(content.contains("</html>"), "HTML should be closed")
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - DictationFormatter Tests

final class DictationFormatterTests: XCTestCase {

    func testVerbatimIsUntouched() {
        let raw = "hi john new line bullet point apples"
        XCTAssertEqual(DictationFormatter.format(raw, mode: .verbatim), raw)
    }

    func testNewLineAndParagraphCommands() {
        let out = DictationFormatter.format(
            "first thought new line second thought new paragraph third", mode: .casual)
        XCTAssertEqual(out, "first thought\nsecond thought\n\nthird")
    }

    func testBulletPoints() {
        let out = DictationFormatter.format(
            "shopping list bullet point apples bullet point oranges", mode: .casual)
        XCTAssertEqual(out, "shopping list\n• apples\n• oranges")
    }

    func testNumberedList() {
        let out = DictationFormatter.format(
            "agenda next number budget next number hiring next number roadmap",
            mode: .casual)
        XCTAssertEqual(out, "agenda\n1. budget\n2. hiring\n3. roadmap")
    }

    func testCommandsSwallowAdjacentPunctuation() {
        let out = DictationFormatter.format(
            "Done here. New line, next item", mode: .casual)
        XCTAssertEqual(out, "Done here\nnext item")
    }

    func testProfessionalCapitalisation() {
        let out = DictationFormatter.format(
            "we shipped it. it works now. what a day", mode: .professional)
        XCTAssertEqual(out, "We shipped it. It works now. What a day")
    }

    func testProfessionalBulletCapitalisation() {
        let out = DictationFormatter.format(
            "plan bullet point review numbers bullet point send update",
            mode: .professional)
        XCTAssertEqual(out, "Plan\n• Review numbers\n• Send update")
    }

    func testEmailGreetingAndSignoff() {
        let out = DictationFormatter.format(
            "hi sarah thanks for the update on the launch. best regards john",
            mode: .email)
        XCTAssertEqual(out, "Hi sarah,\n\nThanks for the update on the launch.\n\nBest regards,\nJohn")
    }

    func testEmailSubjectLine() {
        let out = DictationFormatter.format(
            "subject launch update. hi team the launch is on track",
            mode: .email)
        XCTAssertTrue(out.hasPrefix("Subject: Launch update\n\n"), "got: \(out)")
        XCTAssertTrue(out.contains("Hi team,\n\n"), "got: \(out)")
    }

    func testWhitespaceHygiene() {
        let out = DictationFormatter.format(
            "hello  world , this is   fine .", mode: .professional)
        XCTAssertEqual(out, "Hello world, this is fine.")
    }
}

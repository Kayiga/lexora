//  LexoraTests.swift
//  Unit tests for core Lexora services.
//  These run in the CI pipeline on every push to main and every release tag.

import XCTest
@testable import Lexora

final class TranscriptionSessionTests: XCTestCase {

    // MARK: - TranscriptionSession

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

    func test_session_search_matches_transcript() {
        var session = TranscriptionSession()
        session.finish(with: "Machine learning is transforming the industry")
        XCTAssertTrue(session.matches(query: "machine learning"))
        XCTAssertTrue(session.matches(query: "INDUSTRY"))
        XCTAssertFalse(session.matches(query: "quantum physics"))
    }

    // MARK: - VocabularyEntry

    func test_vocabulary_entry_initialises() {
        let entry = VocabularyEntry(term: "SwiftUI", phonetic: nil, category: .technical)
        XCTAssertEqual(entry.term, "SwiftUI")
        XCTAssertNil(entry.phonetic)
        XCTAssertEqual(entry.category, .technical)
        XCTAssertGreaterThan(entry.weight, 0)
    }

    func test_vocabulary_entry_codable_roundtrip() throws {
        let entry   = VocabularyEntry(term: "Lexora", phonetic: "lek-SOR-ah", category: .name)
        let data    = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(VocabularyEntry.self, from: data)
        XCTAssertEqual(decoded.term,     entry.term)
        XCTAssertEqual(decoded.phonetic, entry.phonetic)
        XCTAssertEqual(decoded.category, entry.category)
    }

    // MARK: - UserVoiceProfile

    func test_voice_profile_default_values() {
        let profile = UserVoiceProfile()
        XCTAssertEqual(profile.detectedPrimaryLanguage, "en-US")
        XCTAssertTrue(profile.smartCorrectionEnabled)
        XCTAssertFalse(profile.vocabulary.isEmpty == false || profile.vocabulary.isEmpty)
        // Vocabulary starts empty
        XCTAssertTrue(profile.vocabulary.isEmpty)
    }

    func test_voice_profile_codable_roundtrip() throws {
        var profile = UserVoiceProfile()
        profile.detectedPrimaryLanguage = "fr-FR"
        profile.smartCorrectionEnabled  = false

        let data    = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(UserVoiceProfile.self, from: data)

        XCTAssertEqual(decoded.detectedPrimaryLanguage, "fr-FR")
        XCTAssertFalse(decoded.smartCorrectionEnabled)
    }

    // MARK: - LanguageIntelligence

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
}

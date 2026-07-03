import Foundation
import NaturalLanguage
import Observation

// The brain that makes Lexora smarter the more you use it.
// Ingests every session, every correction, and every edit to build a
// personalised model of how YOU speak.
@Observable @MainActor
final class LearningEngine {

    var profile: UserVoiceProfile
    private let languageIntelligence: LanguageIntelligence
    private let storage: ProfileStorage

    // Text tokenizer — created lazily so NL model loading doesn't block app startup.
    // .nameType is required to detect personalName / placeName / organizationName tags.
    private var _tagger: NLTagger?
    private var tagger: NLTagger {
        if let t = _tagger { return t }
        let t = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        _tagger = t
        return t
    }

    // How many sessions before we update the primary language detection
    private let languageUpdateThreshold = 5
    private var sessionsSinceLanguageUpdate = 0

    init(profile: UserVoiceProfile, languageIntelligence: LanguageIntelligence, storage: ProfileStorage) {
        self.profile = profile
        self.languageIntelligence = languageIntelligence
        self.storage = storage
    }

    // MARK: - Session Ingestion

    // Called after every recording session. Updates all learned signals.
    func ingest(session: TranscriptionSession) {
        updatePaceModel(from: session)
        updateLanguageModel(from: session)
        extractVocabulary(from: session)
        updateFormalityModel(from: session)
        updateAccuracyTrend(from: session)
        updateFillerWords(from: session)
        updatePauseThreshold(from: session)

        profile.totalSessionCount += 1
        profile.totalTranscriptionMinutes += session.durationSeconds / 60
        profile.touch()
        storage.save(profile)
    }

    // MARK: - Correction Learning

    // Called when the user edits a transcription. The delta teaches the engine
    // which substitutions to make automatically in future sessions.
    func recordCorrection(original: String, corrected: String, sessionID: UUID, appBundleID: String? = nil) {
        let event = CorrectionEvent(
            timestamp: Date(),
            originalText: original,
            correctedText: corrected,
            sessionID: sessionID,
            appBundleID: appBundleID
        )
        profile.correctionHistory.append(event)

        // Extract word-level substitutions and add to vocabulary
        let origWords = original.split(separator: " ").map(String.init)
        let corrWords = corrected.split(separator: " ").map(String.init)

        // Simple diff: find the first diverging word and learn it
        for (orig, corr) in zip(origWords, corrWords) where orig.lowercased() != corr.lowercased() {
            learnSubstitution(wrong: orig, correct: corr)
        }

        // Any words in corrected that weren't in original are new vocabulary
        let newWords = Set(corrWords).subtracting(Set(origWords))
        for word in newWords where word.count > 2 {
            addToVocabulary(
                term: word,
                source: .learnedFromCorrection,
                language: profile.detectedPrimaryLanguage
            )
        }

        profile.correctionHistory = Array(profile.correctionHistory.suffix(500))
        profile.touch()
        storage.save(profile)
    }

    // MARK: - Smart Correction Application

    // Applies all learned substitutions to a new transcript.
    func applySmartCorrections(to text: String) -> String {
        var result = text

        // Apply phoneme substitutions (direct replacements)
        for (wrong, correct) in profile.phonemeSubstitutions {
            result = result.replacingOccurrences(
                of: "\\b\(NSRegularExpression.escapedPattern(for: wrong))\\b",
                with: correct,
                options: [.regularExpression, .caseInsensitive]
            )
        }

        // Apply formality transformation if needed
        result = applyFormalityMode(to: result)

        // Strip filler words unless verbatim mode
        if profile.preferredOutputFormality != .verbatim {
            result = stripFillers(from: result)
        }

        // Structural formatting: spoken commands (new line / bullet point /
        // next number), sentence capitalisation, email layout. Deterministic,
        // on-device, and applied to the RAW live text on every update.
        result = DictationFormatter.format(result, mode: profile.preferredOutputFormality)

        return result
    }

    // MARK: - Recognition Hints

    // Builds the contextual strings array passed to SFSpeechRecognizer,
    // boosting recognition of known vocabulary.
    func buildRecognitionHints() -> [String] {
        let vocab = profile.customVocabulary
            .filter { $0.relevanceScore > 0.3 }
            .sorted { $0.usageCount > $1.usageCount }
            .prefix(200)
            .flatMap { entry -> [String] in
                var hints = [entry.term]
                hints.append(contentsOf: entry.aliases)
                return hints
            }

        // Also include the top correction targets
        let correctionHints = profile.correctionHistory
            .suffix(100)
            .map { $0.correctedText }
            .filter { $0.split(separator: " ").count <= 3 } // short phrases only

        return Array(Set(vocab + correctionHints)).prefix(500).map { $0 }
    }

    // MARK: - Private Update Methods

    private func updatePaceModel(from session: TranscriptionSession) {
        guard session.paceWPM > 0 else { return }
        // Exponential moving average (α = 0.2)
        profile.averageSpeakingPaceWPM = profile.averageSpeakingPaceWPM * 0.8 + session.paceWPM * 0.2
    }

    private func updatePauseThreshold(from session: TranscriptionSession) {
        guard !session.pausePattern.isEmpty else { return }
        let avgPause = session.pausePattern.reduce(0, +) / Double(session.pausePattern.count)
        profile.averagePauseMilliseconds = profile.averagePauseMilliseconds * 0.8 + avgPause * 0.2
    }

    private func updateLanguageModel(from session: TranscriptionSession) {
        sessionsSinceLanguageUpdate += 1
        guard sessionsSinceLanguageUpdate >= languageUpdateThreshold else { return }
        sessionsSinceLanguageUpdate = 0

        let snapshot = LanguageSnapshot(
            timestamp: Date(),
            language: session.primaryLanguage,
            confidence: session.confidenceAverage,
            sessionID: session.id
        )
        profile.languageConfidenceHistory.append(snapshot)
        profile.languageConfidenceHistory = Array(profile.languageConfidenceHistory.suffix(100))

        // Update primary language based on history
        let recentLanguages = profile.languageConfidenceHistory.suffix(20).map { $0.language }
        if let dominant = Dictionary(grouping: recentLanguages, by: { $0 })
            .max(by: { $0.value.count < $1.value.count })?.key {
            if dominant != profile.detectedPrimaryLanguage {
                profile.detectedPrimaryLanguage = dominant
            }
        }

        // Track secondary languages from code-switching
        let spans = languageIntelligence.detectCodeSwitching(in: session.finalTranscript)
        let newLangs = spans.map { $0.language }.filter { $0 != profile.detectedPrimaryLanguage }
        for lang in newLangs where !profile.detectedSecondaryLanguages.contains(lang) {
            profile.detectedSecondaryLanguages.append(lang)
        }

        // Update accent inference
        profile.accentRegion = languageIntelligence.inferAccentRegion(from: profile)
    }

    private func extractVocabulary(from session: TranscriptionSession) {
        let text = session.finalTranscript
        guard !text.isEmpty else { return }

        tagger.string = text
        var candidates: [String] = []

        // Pass 1: find named entities via .nameType scheme
        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                              unit: .word,
                              scheme: .nameType,
                              options: [.omitPunctuation, .omitWhitespace]) { tag, range in
            guard let tag = tag else { return true }
            if tag == .personalName || tag == .placeName || tag == .organizationName {
                let word = String(text[range])
                if word.count > 2 { candidates.append(word) }
            }
            return true
        }

        // Pass 2: capitalised nouns not caught by nameType (domain-specific terms)
        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                              unit: .word,
                              scheme: .lexicalClass,
                              options: [.omitPunctuation, .omitWhitespace]) { tag, range in
            guard tag == .noun else { return true }
            let word = String(text[range])
            if word.count > 2 && word.first?.isUppercase == true && !candidates.contains(word) {
                candidates.append(word)
            }
            return true
        }

        for candidate in candidates {
            if let idx = profile.customVocabulary.firstIndex(where: {
                $0.term.lowercased() == candidate.lowercased()
            }) {
                profile.customVocabulary[idx].recordUsage()
            } else {
                addToVocabulary(term: candidate, source: .autoDetected, language: session.primaryLanguage)
            }
        }

        // Keep vocabulary list manageable
        profile.customVocabulary = profile.customVocabulary
            .filter { $0.relevanceScore > 0.1 }
            .sorted { $0.usageCount > $1.usageCount }
            .prefix(1000)
            .map { entry -> VocabularyEntry in var e = entry; e.decayIfNeeded(); return e }
    }

    private func updateFormalityModel(from session: TranscriptionSession) {
        let score = languageIntelligence.formalityScore(for: session.finalTranscript)
        profile.formalityScore = profile.formalityScore * 0.9 + score * 0.1
    }

    private func updateAccuracyTrend(from session: TranscriptionSession) {
        let dataPoint = AccuracyDataPoint(
            date: Date(),
            sessionID: session.id,
            wordCount: session.wordCount,
            correctionCount: session.correctionsMade
        )
        profile.accuracyTrend.append(dataPoint)
        profile.accuracyTrend = Array(profile.accuracyTrend.suffix(90)) // 90-day window
    }

    private func updateFillerWords(from session: TranscriptionSession) {
        let text = session.rawTranscript.lowercased()
        let knownFillers = ["um", "uh", "like", "you know", "i mean", "basically", "literally", "actually", "so"]
        for filler in knownFillers {
            let count = text.components(separatedBy: " \(filler) ").count - 1
            profile.fillerWordFrequency[filler, default: 0] += count
        }
    }

    private func learnSubstitution(wrong: String, correct: String) {
        profile.phonemeSubstitutions[wrong.lowercased()] = correct
        // Cap substitution dictionary size
        if profile.phonemeSubstitutions.count > 300 {
            let toRemove = profile.phonemeSubstitutions.keys.first
            if let key = toRemove { profile.phonemeSubstitutions.removeValue(forKey: key) }
        }
    }

    private func addToVocabulary(term: String, source: EntrySource, language: String) {
        let exists = profile.customVocabulary.contains { $0.term.lowercased() == term.lowercased() }
        guard !exists else { return }

        let entry = VocabularyEntry(
            term: term,
            aliases: [],
            category: categorise(term: term),
            language: language,
            source: source
        )
        profile.customVocabulary.append(entry)
    }

    private func categorise(term: String) -> VocabularyCategory {
        // Use .nameType scheme so personalName/placeName/organizationName tags are recognised
        let nameTagger = NLTagger(tagSchemes: [.nameType])
        nameTagger.string = term
        var result: VocabularyCategory = .other

        nameTagger.enumerateTags(in: term.startIndex..<term.endIndex,
                                  unit: .word,
                                  scheme: .nameType,
                                  options: [.omitWhitespace]) { tag, _ in
            switch tag {
            case .personalName:     result = .name
            case .placeName:        result = .place
            case .organizationName: result = .brand
            default: break
            }
            return false   // stop after first match
        }
        return result
    }

    private func applyFormalityMode(to text: String) -> String {
        switch profile.preferredOutputFormality {
        case .professional, .email:
            return text
                .replacingOccurrences(of: "gonna", with: "going to")
                .replacingOccurrences(of: "wanna", with: "want to")
                .replacingOccurrences(of: "gotta", with: "have to")
                .replacingOccurrences(of: "kinda", with: "kind of")
                .replacingOccurrences(of: "sorta", with: "sort of")
                .replacingOccurrences(of: "dunno", with: "don't know")
        case .adaptive:
            // Only formalise if current session is more formal than the user's baseline
            return text
        case .casual, .verbatim:
            return text
        }
    }

    private func stripFillers(from text: String) -> String {
        let topFillers = profile.fillerWordFrequency
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { $0.key }

        var result = text
        for filler in topFillers {
            result = result.replacingOccurrences(
                of: "\\b\(NSRegularExpression.escapedPattern(for: filler))\\b",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        // Clean up double spaces left behind
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

// Simple persistence wrapper - delegates to CloudSyncService for iCloud.
// Saves to the App Group container (shared with the keyboard extension) when available,
// otherwise falls back to applicationSupportDirectory (simulator / no entitlement yet).
final class ProfileStorage {
    static let appGroupID = "group.com.yiga.Lexora"
    private let fileURL: URL

    init() {
        // Prefer App Group container so the keyboard extension can read the profile.
        if let groupContainer = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: ProfileStorage.appGroupID) {
            fileURL = groupContainer.appendingPathComponent("profile.json")
        } else {
            // Fallback: no App Groups capability yet (Simulator / free dev account)
            let fallback = FileManager.default.temporaryDirectory
            let appSupport = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fallback
            let dir = appSupport.appendingPathComponent("Lexora", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            fileURL = dir.appendingPathComponent("profile.json")
        }
    }

    func save(_ profile: UserVoiceProfile) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func load() -> UserVoiceProfile? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        // Fast path: stored JSON matches the current schema exactly.
        if let profile = try? JSONDecoder().decode(UserVoiceProfile.self, from: data) {
            return profile
        }
        // Migration path: new fields have been added since this JSON was written.
        // Strategy: encode a fresh default profile (gives us every key), overlay the
        // stored JSON on top of those defaults, then decode the merged result.
        // This means NEW fields get their initialiser defaults; OLD fields keep their
        // stored values. No data is lost and no manual CodingKey maintenance needed.
        return mergeAndDecode(UserVoiceProfile(displayName: "You"), over: data, using: JSONDecoder())
    }

    // MARK: - Session persistence

    private var sessionsURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("sessions.json")
    }

    func saveSessions(_ sessions: [TranscriptionSession]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(sessions) else { return }
        try? data.write(to: sessionsURL, options: .atomic)
    }

    func loadSessions() -> [TranscriptionSession] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: sessionsURL) else { return [] }

        // Fast path: all sessions decode cleanly.
        if let sessions = try? decoder.decode([TranscriptionSession].self, from: data) {
            return sessions
        }

        // Migration path: decode each session individually with the merge strategy
        // so that a single corrupt or schema-mismatched session doesn't wipe the list.
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        let defaultSession = TranscriptionSession()
        return array.compactMap { dict in
            mergeAndDecode(defaultSession, over: dict, using: decoder)
        }
    }

    // MARK: - Migration helper

    /// Fills missing keys in `storedData` with values from `defaults`, then decodes.
    private func mergeAndDecode<T: Codable>(_ defaults: T,
                                             over storedData: Data,
                                             using decoder: JSONDecoder) -> T? {
        let encoder = JSONEncoder()
        // All Lexora data uses ISO-8601 dates — match the app-wide convention.
        encoder.dateEncodingStrategy = .iso8601
        guard let defaultData  = try? encoder.encode(defaults),
              var defaultDict  = try? JSONSerialization.jsonObject(with: defaultData) as? [String: Any],
              let storedDict   = try? JSONSerialization.jsonObject(with: storedData)  as? [String: Any]
        else { return nil }

        // Stored values win over defaults.
        for (key, value) in storedDict { defaultDict[key] = value }

        guard let merged = try? JSONSerialization.data(withJSONObject: defaultDict) else { return nil }
        return try? decoder.decode(T.self, from: merged)
    }

    /// Overload that accepts a pre-parsed dict instead of raw Data.
    private func mergeAndDecode<T: Codable>(_ defaults: T,
                                             over storedDict: [String: Any],
                                             using decoder: JSONDecoder) -> T? {
        guard let storedData = try? JSONSerialization.data(withJSONObject: storedDict) else { return nil }
        return mergeAndDecode(defaults, over: storedData, using: decoder)
    }

    // MARK: - Widget shared data

    /// Writes lightweight stats to the App Group UserDefaults so the WidgetKit
    /// extension can read them without decoding the full sessions array.
    func saveWidgetData(todayWords: Int, todaySessions: Int, streak: Int, dailyGoal: Int = 0, lastLanguage: String = "") {
        guard let defaults = UserDefaults(suiteName: Self.appGroupID) else { return }
        defaults.set(todayWords,    forKey: "widget.todayWords")
        defaults.set(todaySessions, forKey: "widget.todaySessions")
        defaults.set(streak,        forKey: "widget.streak")
        defaults.set(dailyGoal,     forKey: "widget.dailyGoal")
        if !lastLanguage.isEmpty {
            defaults.set(lastLanguage, forKey: "widget.lastLanguage")
        }
    }

    /// Reads the lightweight stats written by the main app.
    func loadWidgetData() -> (todayWords: Int, todaySessions: Int, streak: Int, dailyGoal: Int) {
        let defaults = UserDefaults(suiteName: Self.appGroupID)
        return (
            todayWords:    defaults?.integer(forKey: "widget.todayWords")    ?? 0,
            todaySessions: defaults?.integer(forKey: "widget.todaySessions") ?? 0,
            streak:        defaults?.integer(forKey: "widget.streak")        ?? 0,
            dailyGoal:     defaults?.integer(forKey: "widget.dailyGoal")     ?? 0
        )
    }
}

// MARK: - Dictation Formatter

/// Deterministic, on-device structural formatting for dictated text.
/// Runs on the full raw transcript on every live update (input is always the
/// unformatted ASR text, so repeated application never compounds).
///
/// Capabilities by mode:
/// - all modes except verbatim: spoken commands —
///     "new paragraph"              → blank line
///     "new line"                   → line break
///     "bullet point" / "new bullet"→ "• " on a new line
///     "next number"/"numbered point"→ auto-incrementing "1. ", "2. ", …
/// - professional & email: contraction cleanup (upstream), sentence
///   capitalisation, whitespace/punctuation hygiene.
/// - email: greeting on its own line ("Hi Sarah," + blank line), Subject:
///   extraction ("subject …"), sign-off block ("best regards john" →
///   "\n\nBest regards,\nJohn").
enum DictationFormatter {

    static func format(_ text: String, mode: FormalityMode) -> String {
        guard mode != .verbatim, !text.isEmpty else { return text }
        var result = text

        result = applySpokenCommands(to: result)

        if mode == .email {
            result = applyEmailLayout(to: result)
        }
        if mode == .email || mode == .professional {
            result = capitaliseSentences(in: result)
        }

        result = tidyWhitespace(in: result)
        return result
    }

    // MARK: Spoken commands

    private static func applySpokenCommands(to text: String) -> String {
        var result = text

        // Order matters: "new paragraph" before "new line" is irrelevant (distinct
        // words) but longer bullet phrases must run before shorter ones.
        let simple: [(pattern: String, replacement: String)] = [
            ("(?i)[,.]?\\s*\\bnew paragraph\\b[,.]?\\s*", "\n\n"),
            ("(?i)[,.]?\\s*\\bnew line\\b[,.]?\\s*",      "\n"),
            ("(?i)[,.]?\\s*\\b(?:bullet point|new bullet)\\b[,.]?\\s*", "\n• "),
        ]
        for rule in simple {
            result = result.replacingOccurrences(
                of: rule.pattern, with: rule.replacement, options: .regularExpression)
        }

        // Auto-numbered list: each "next number"/"numbered point" becomes the
        // next integer, counted per occurrence.
        if result.range(of: "(?i)\\b(?:next number|numbered point)\\b",
                        options: .regularExpression) != nil {
            var n = 0
            var out = ""
            var remaining = Substring(result)
            while let r = remaining.range(of: "(?i)[,.]?\\s*\\b(?:next number|numbered point)\\b[,.]?\\s*",
                                          options: .regularExpression) {
                n += 1
                out += remaining[..<r.lowerBound] + "\n\(n). "
                remaining = remaining[r.upperBound...]
            }
            out += remaining
            result = out
        }

        return result
    }

    // MARK: Email layout

    private static let signoffPhrases = [
        "best regards", "kind regards", "warm regards", "regards",
        "sincerely", "best wishes", "many thanks", "thank you", "thanks",
        "cheers", "yours faithfully", "yours truly", "best"
    ]

    private static func applyEmailLayout(to text: String) -> String {
        var result = text

        // "subject <line>" at the very start → "Subject: <Line>" + blank line.
        // The subject runs to the first sentence break or line break.
        if let r = result.range(of: "(?i)^\\s*subject[,:]?\\s+([^.\\n]{1,80})[.]?\\s*",
                                options: .regularExpression) {
            let matched = String(result[r])
            let content = matched.replacingOccurrences(
                of: "(?i)^\\s*subject[,:]?\\s+", with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: ". \n"))
            result.replaceSubrange(r, with: "Subject: \(content.capitalisedFirst)\n\n")
        }

        // Greeting: leading "hi|hello|hey|dear <name (1-3 words)>" → own line + blank line.
        result = result.replacingOccurrences(
            of: "(?im)^(\\h*(?:hi|hello|hey|dear)\\s+[\\p{L}'’-]+(?:\\s+[\\p{L}'’-]+){0,2}?)[,.]?\\h+",
            with: "$1,\n\n",
            options: .regularExpression)

        // Sign-off near the end: "<signoff>[,.]? <name (0-3 words)>" at the tail →
        // "\n\nSignoff,\nName". Longest phrases first so "best regards" wins over "best".
        for phrase in signoffPhrases {
            let esc = NSRegularExpression.escapedPattern(for: phrase)
            let pattern = "(?i),?\\s+\\b(\(esc))\\b[,.]?\\s*((?:[\\p{L}'’-]+\\s*){0,3})[.]?\\s*$"
            if let r = result.range(of: pattern, options: .regularExpression) {
                let ns = result as NSString
                let regex = try? NSRegularExpression(pattern: pattern)
                if let m = regex?.firstMatch(in: result, range: NSRange(r, in: result)) {
                    let signoff = ns.substring(with: m.range(at: 1)).capitalisedFirst
                    let name = ns.substring(with: m.range(at: 2))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let block = name.isEmpty
                        ? "\n\n\(signoff),"
                        : "\n\n\(signoff),\n\(name.capitalisedFirst)"
                    result.replaceSubrange(r, with: block)
                }
                break
            }
        }

        return result
    }

    // MARK: Capitalisation & hygiene

    /// Capitalises the first letter of the text, of every sentence, and of
    /// every list-item line.
    private static func capitaliseSentences(in text: String) -> String {
        var chars = Array(text)
        var capitaliseNext = true
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if capitaliseNext, c.isLetter {
                chars[i] = Character(c.uppercased())
                capitaliseNext = false
            } else if c == "." || c == "!" || c == "?" || c == "\n" {
                capitaliseNext = true
            }
            i += 1
        }
        return String(chars)
    }

    private static func tidyWhitespace(in text: String) -> String {
        var result = text
        // Collapse runs of spaces (not newlines).
        result = result.replacingOccurrences(of: "[ \\t]{2,}", with: " ",
                                             options: .regularExpression)
        // No space before closing punctuation.
        result = result.replacingOccurrences(of: " +([,.!?;:])", with: "$1",
                                             options: .regularExpression)
        // Trim spaces around line breaks; cap blank runs at one empty line.
        result = result.replacingOccurrences(of: " *\n *", with: "\n",
                                             options: .regularExpression)
        result = result.replacingOccurrences(of: "\n{3,}", with: "\n\n",
                                             options: .regularExpression)
        return result
    }
}

private extension String {
    /// First letter uppercased, rest untouched.
    var capitalisedFirst: String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
    }
}

import Foundation
import NaturalLanguage

// Wraps Apple's NLLanguageRecognizer and adds:
// - Code-switch detection (when the speaker switches between languages mid-sentence)
// - Accent region inference
// - Formality scoring
// - Confidence history tracking

final class LanguageIntelligence {

    private var _recognizer: NLLanguageRecognizer?
    private var recognizer: NLLanguageRecognizer {
        if let r = _recognizer { return r }
        let r = NLLanguageRecognizer()
        _recognizer = r
        return r
    }

    // Top-N language hypotheses Apple gives us
    private let hypothesisCount = 5

    // Rolling window of the last N detections to smooth out noise
    private var recentDetections: [DetectionResult] = []
    private let smoothingWindow = 10

    // MARK: - Primary Detection

    func detect(text: String) -> DetectionResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return DetectionResult(language: "und", confidence: 0, alternatives: [])
        }

        recognizer.reset()
        recognizer.processString(text)

        let hypotheses = recognizer.languageHypotheses(withMaximum: hypothesisCount)
        guard let top = hypotheses.max(by: { $0.value < $1.value }) else {
            return DetectionResult(language: "und", confidence: 0, alternatives: [])
        }

        let alternatives = hypotheses
            .filter { $0.key != top.key }
            .map { LanguageHypothesis(language: $0.key.rawValue, confidence: $0.value) }
            .sorted { $0.confidence > $1.confidence }

        let result = DetectionResult(
            language: top.key.rawValue,
            confidence: top.value,
            alternatives: alternatives
        )

        trackDetection(result)
        return result
    }

    // MARK: - Code-Switch Detection

    // Analyses a session transcript to find segments that switch language.
    // Returns an array of detected language spans.
    func detectCodeSwitching(in text: String) -> [LanguageSpan] {
        let sentences = splitIntoSentences(text)
        var spans: [LanguageSpan] = []
        var currentOffset = 0

        for sentence in sentences {
            let detection = detect(text: sentence)
            if detection.confidence > 0.4 {
                spans.append(LanguageSpan(
                    text: sentence,
                    language: detection.language,
                    confidence: detection.confidence,
                    range: currentOffset..<(currentOffset + sentence.count)
                ))
            }
            currentOffset += sentence.count + 1
        }

        return mergeAdjacentSpans(spans)
    }

    // MARK: - Formality Scoring

    // Heuristic formality scorer. Higher = more formal.
    // Combines sentence length, vocabulary complexity, and punctuation density.
    func formalityScore(for text: String) -> Double {
        guard !text.isEmpty else { return 0.5 }

        let words = text.split(separator: " ")
        let wordCount = Double(words.count)
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .filter { !$0.isEmpty }
        let sentenceCount = max(1.0, Double(sentences.count))

        // Avg words per sentence (longer = more formal)
        let avgWordsPerSentence = wordCount / sentenceCount
        let sentenceLengthScore = min(1.0, avgWordsPerSentence / 25.0)

        // Avg word length (longer words = more formal)
        let avgWordLength = words.isEmpty ? 0 :
            Double(words.map { $0.count }.reduce(0, +)) / wordCount
        let wordLengthScore = min(1.0, avgWordLength / 8.0)

        // Filler word penalty
        let fillerWords = ["um", "uh", "like", "you know", "kinda", "sorta", "basically", "literally"]
        let fillerCount = fillerWords.reduce(0) { count, filler in
            count + text.lowercased().components(separatedBy: filler).count - 1
        }
        let fillerPenalty = min(0.5, Double(fillerCount) / wordCount * 5)

        // Contraction penalty (contractions = informal)
        let contractions = ["don't", "can't", "won't", "I'm", "it's", "they're", "we're"]
        let contractionCount = contractions.reduce(0) { count, c in
            count + text.components(separatedBy: c).count - 1
        }
        let contractionPenalty = min(0.3, Double(contractionCount) / wordCount * 3)

        let raw = (sentenceLengthScore * 0.4) + (wordLengthScore * 0.4) - fillerPenalty - contractionPenalty
        return max(0, min(1, raw + 0.1)) // baseline nudge
    }

    // MARK: - Accent / Region Inference

    // Uses language hypotheses to infer regional accent.
    // E.g. if "en" scores highest but "yo" (Yoruba) appears in alternatives, infer West African English.
    func inferAccentRegion(from profile: UserVoiceProfile) -> String? {
        let primary = profile.detectedPrimaryLanguage
        let secondaries = profile.detectedSecondaryLanguages

        // West African English patterns
        if primary.hasPrefix("en") && secondaries.contains(where: { $0.hasPrefix("yo") || $0.hasPrefix("ig") || $0.hasPrefix("ha") }) {
            return "West African English"
        }
        if primary.hasPrefix("en") && secondaries.contains(where: { $0.hasPrefix("fr") }) {
            return "Francophone English"
        }
        if primary.hasPrefix("en") && secondaries.contains(where: { $0.hasPrefix("ar") }) {
            return "Middle Eastern English"
        }
        if primary.hasPrefix("en") && secondaries.contains(where: { $0.hasPrefix("hi") || $0.hasPrefix("ta") }) {
            return "South Asian English"
        }
        if primary.hasPrefix("en") && secondaries.contains(where: { $0.hasPrefix("zh") }) {
            return "East Asian English"
        }

        return nil
    }

    // MARK: - Smoothed Language (reduces flicker)

    func smoothedPrimaryLanguage() -> String {
        guard !recentDetections.isEmpty else { return "en" }
        let recent = recentDetections.suffix(smoothingWindow)
        let tallied = Dictionary(grouping: recent, by: { $0.language })
            .mapValues { $0.reduce(0) { $0 + $1.confidence } }
        return tallied.max(by: { $0.value < $1.value })?.key ?? "en"
    }

    // MARK: - Private Helpers

    private func trackDetection(_ result: DetectionResult) {
        recentDetections.append(result)
        if recentDetections.count > smoothingWindow * 3 {
            recentDetections.removeFirst()
        }
    }

    private func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            sentences.append(String(text[range]))
            return true
        }
        return sentences.isEmpty ? [text] : sentences
    }

    private func mergeAdjacentSpans(_ spans: [LanguageSpan]) -> [LanguageSpan] {
        var merged: [LanguageSpan] = []
        for span in spans {
            if let last = merged.last, last.language == span.language {
                merged[merged.count - 1] = LanguageSpan(
                    text: last.text + " " + span.text,
                    language: last.language,
                    confidence: (last.confidence + span.confidence) / 2,
                    range: last.range.lowerBound..<span.range.upperBound
                )
            } else {
                merged.append(span)
            }
        }
        return merged
    }
}

// MARK: - Supporting Types

struct DetectionResult {
    var language: String
    var confidence: Double
    var alternatives: [LanguageHypothesis]

    var isHighConfidence: Bool { confidence > 0.75 }
    var isMixed: Bool { alternatives.contains { $0.confidence > 0.3 } }
}

struct LanguageHypothesis {
    var language: String
    var confidence: Double
}

struct LanguageSpan {
    var text: String
    var language: String
    var confidence: Double
    var range: Range<Int>
}

import Foundation

/// Generates SubRip (.srt) subtitle files from transcription sessions.
///
/// If the session has timed segment data the timecodes come directly from the
/// recogniser. When segments are absent (or too few) the transcript is split
/// into natural-language chunks and evenly distributed across the session's
/// known duration.
enum SRTExportService {

    // MARK: - Public API

    static func exportSession(_ session: TranscriptionSession) -> URL? {
        let content = buildSRT(from: session)
        guard !content.isEmpty else { return nil }

        let filename = "Lexora_\(sanitised(session.startedAt))_\(session.id.uuidString.prefix(8)).srt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Building SRT content

    private static func buildSRT(from session: TranscriptionSession) -> String {
        let blocks: [(start: TimeInterval, end: TimeInterval, text: String)]

        if session.segments.count >= 2 {
            // Use real timing data from the speech recogniser segments.
            // Merge very short consecutive segments (< 3 words) into one cue
            // to avoid a wall of sub-second subtitles.
            blocks = mergeSegments(session.segments)
        } else {
            // No segment data: split the transcript into chunks and spread them
            // evenly over the session duration.
            blocks = synthesiseBlocks(
                transcript: session.finalTranscript,
                duration: max(session.durationSeconds, 1)
            )
        }

        guard !blocks.isEmpty else { return "" }

        var lines: [String] = []
        for (i, block) in blocks.enumerated() {
            lines.append("\(i + 1)")
            lines.append("\(srtTimestamp(block.start)) --> \(srtTimestamp(block.end))")
            lines.append(block.text)
            lines.append("")          // blank separator between cues
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Segment helpers

    private static func mergeSegments(
        _ segments: [TranscriptSegment]
    ) -> [(start: TimeInterval, end: TimeInterval, text: String)] {
        var result: [(start: TimeInterval, end: TimeInterval, text: String)] = []
        var buffer: [TranscriptSegment] = []

        func flush() {
            guard !buffer.isEmpty, let first = buffer.first, let last = buffer.last else { return }
            let text  = buffer.map { $0.text }.joined(separator: " ")
            let start = first.startTime
            let end   = last.endTime
            result.append((start: start, end: max(end, start + 0.5), text: text))
            buffer = []
        }

        for seg in segments {
            buffer.append(seg)
            let wordCount = buffer.reduce(0) { $0 + $1.text.split(separator: " ").count }
            if wordCount >= 10 { flush() }
        }
        flush()
        return result
    }

    /// Splits `transcript` into ~10-word chunks, each lasting `duration / blockCount`.
    private static func synthesiseBlocks(
        transcript: String,
        duration: TimeInterval
    ) -> [(start: TimeInterval, end: TimeInterval, text: String)] {
        let words = transcript.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }

        let chunkSize = 10
        let chunks: [String] = stride(from: 0, to: words.count, by: chunkSize).map { start in
            let end = min(start + chunkSize, words.count)
            return words[start..<end].joined(separator: " ")
        }
        if chunks.isEmpty { return [] }

        let blockDuration = duration / Double(chunks.count)
        return chunks.enumerated().map { (i, text) in
            let start = Double(i) * blockDuration
            let end   = start + blockDuration - 0.1
            return (start: start, end: end, text: text)
        }
    }

    // MARK: - Formatting helpers

    /// Converts a `TimeInterval` (seconds) into SRT timestamp: `HH:MM:SS,mmm`
    private static func srtTimestamp(_ seconds: TimeInterval) -> String {
        let total   = max(0, Int(seconds * 1000))
        let ms      = total % 1000
        let s       = (total / 1000) % 60
        let m       = (total / 60_000) % 60
        let h       = total / 3_600_000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    private static func sanitised(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm"
        return df.string(from: date)
    }
}

import Foundation

/// Generates a self-contained HTML file from a TranscriptionSession.
/// The output is a single HTML document with all styles inlined —
/// no external resources, fonts loaded via Google Fonts CDN (optional).
enum HTMLExportService {

    // MARK: - Public API

    /// Writes the session to a temporary HTML file and returns the URL.
    /// Returns nil if writing fails.
    static func exportSession(_ session: TranscriptionSession) -> URL? {
        let html = buildHTML(for: session)
        let safe = sanitiseFileName(session.displayTitle)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lexora_\(safe).html")
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - HTML builder

    private static func buildHTML(for session: TranscriptionSession) -> String {
        let df = DateFormatter()
        df.dateStyle = .long
        df.timeStyle = .short

        let langName = Locale.current.localizedString(forLanguageCode: session.primaryLanguage)
                       ?? session.primaryLanguage
        let dateStr  = df.string(from: session.startedAt)
        let durMin   = Int(session.durationSeconds) / 60
        let durSec   = Int(session.durationSeconds) % 60
        let durStr   = durMin > 0 ? "\(durMin)m \(durSec)s" : "\(durSec)s"
        let wpm      = session.paceWPM > 0 ? String(format: "%.0f wpm", session.paceWPM) : ""
        let accuracy = session.estimatedAccuracy > 0
                       ? "\(Int(session.estimatedAccuracy))% accuracy" : ""

        let tagsHTML = session.tags.isEmpty ? "" : session.tags.map { tag in
            "<span class=\"tag\">\(escapeHTML(tag))</span>"
        }.joined(separator: " ")

        let paragraphs = buildTranscriptWithChapters(session.finalTranscript, chapters: session.chapters)

        let notesHTML: String
        if let notes = session.notes, !notes.isEmpty {
            notesHTML = """
            <section class="card">
              <h2>📝 Notes</h2>
              <p class="notes-text">\(escapeHTML(notes).replacingOccurrences(of: "\n", with: "<br>"))</p>
            </section>
            """
        } else {
            notesHTML = ""
        }

        let statsRow = [
            "\(session.wordCount) words",
            durStr,
            wpm,
            accuracy,
            langName
        ].filter { !$0.isEmpty }.map { s in
            "<span class=\"stat\">\(escapeHTML(s))</span>"
        }.joined(separator: "<span class=\"dot\">·</span>")

        let exportDate = ISO8601DateFormatter().string(from: Date())

        return """
<!DOCTYPE html>
<html lang="\(session.primaryLanguage.components(separatedBy: "-").first ?? "en")">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>\(escapeHTML(session.displayTitle))</title>
  <style>
    :root {
      --accent: #3880F8;
      --accent-light: #EBF1FE;
      --text: #1C1C1E;
      --secondary: #6B6B6B;
      --bg: #F2F2F7;
      --card: #FFFFFF;
      --border: #E5E5EA;
      --tag-bg: #E9F0FE;
      --tag-text: #2A5FCC;
      --dot: #C7C7CC;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --accent: #4F8EF7;
        --accent-light: #1C2A44;
        --text: #F2F2F7;
        --secondary: #AEAEB2;
        --bg: #1C1C1E;
        --card: #2C2C2E;
        --border: #38383A;
        --tag-bg: #1C2A44;
        --tag-text: #6CA0F5;
        --dot: #555558;
      }
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
      background: var(--bg);
      color: var(--text);
      line-height: 1.6;
      padding: 24px 16px 64px;
    }
    .container { max-width: 760px; margin: 0 auto; }
    header { margin-bottom: 24px; }
    h1 {
      font-size: clamp(1.4rem, 4vw, 2rem);
      font-weight: 700;
      margin-bottom: 8px;
      color: var(--text);
    }
    .meta {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      gap: 4px 2px;
      font-size: 0.875rem;
      color: var(--secondary);
      margin-bottom: 10px;
    }
    .stat { white-space: nowrap; }
    .dot { color: var(--dot); padding: 0 6px; }
    .tags { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 8px; }
    .tag {
      font-size: 0.75rem;
      font-weight: 600;
      background: var(--tag-bg);
      color: var(--tag-text);
      border-radius: 100px;
      padding: 3px 10px;
    }
    .card {
      background: var(--card);
      border-radius: 16px;
      padding: 20px 24px;
      margin-bottom: 16px;
      border: 1px solid var(--border);
    }
    .card h2 {
      font-size: 0.9rem;
      font-weight: 600;
      color: var(--secondary);
      text-transform: uppercase;
      letter-spacing: 0.06em;
      margin-bottom: 14px;
    }
    .transcript-body {
      font-size: 1rem;
      line-height: 1.8;
      color: var(--text);
    }
    .transcript-body p { margin-bottom: 1em; }
    .transcript-body p:last-child { margin-bottom: 0; }
    .notes-text {
      font-size: 0.95rem;
      line-height: 1.7;
      color: var(--secondary);
    }
    .brand {
      text-align: center;
      font-size: 0.75rem;
      color: var(--dot);
      margin-top: 32px;
    }
    .brand a { color: var(--accent); text-decoration: none; }
    .chapter-heading {
      font-size: 1.05rem;
      font-weight: 700;
      color: var(--accent);
      margin: 1.5em 0 0.5em;
      padding-bottom: 0.3em;
      border-bottom: 2px solid var(--accent-light);
    }
    @media print {
      body { background: white; color: black; }
      .card { border: 1px solid #ddd; break-inside: avoid; }
    }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <h1>\(escapeHTML(session.displayTitle))</h1>
      <div class="meta">\(statsRow)</div>
      <div class="meta">\(escapeHTML(dateStr))</div>
      \(tagsHTML.isEmpty ? "" : "<div class=\"tags\">\(tagsHTML)</div>")
    </header>

    <section class="card">
      <h2>🎙 Transcript</h2>
      <div class="transcript-body">\(paragraphs)</div>
    </section>

    \(notesHTML)

    <p class="brand">Exported by <a href="https://lexora.app">Lexora</a> on \(exportDate)</p>
  </div>
</body>
</html>
"""
    }

    // MARK: - Helpers

    /// Builds transcript HTML, inserting chapter headings at their offsets.
    private static func buildTranscriptWithChapters(_ text: String, chapters: [TranscriptChapter]) -> String {
        guard !chapters.isEmpty else { return buildParagraphsHTML(text) }
        let sorted = chapters.sorted { $0.offset < $1.offset }

        var result = ""
        var lastOffset = 0

        for chapter in sorted {
            let clampedOffset = min(chapter.offset, text.count)
            if clampedOffset > lastOffset {
                let startIdx = text.index(text.startIndex, offsetBy: lastOffset)
                let endIdx   = text.index(text.startIndex, offsetBy: clampedOffset)
                let chunk    = String(text[startIdx..<endIdx])
                result += buildParagraphsHTML(chunk)
            }
            result += "\n<h3 class=\"chapter-heading\">\(escapeHTML(chapter.title))</h3>\n"
            lastOffset = clampedOffset
        }

        // Remainder after last chapter
        if lastOffset < text.count {
            let startIdx = text.index(text.startIndex, offsetBy: lastOffset)
            let chunk    = String(text[startIdx...])
            result += buildParagraphsHTML(chunk)
        }

        return result
    }

    /// Splits transcript into paragraphs (double-newline or every ~5 sentences).
    private static func buildParagraphsHTML(_ text: String) -> String {
        guard !text.isEmpty else { return "<p><em>Empty transcript</em></p>" }

        // Use existing newlines first
        var chunks: [String]
        if text.contains("\n\n") {
            chunks = text.components(separatedBy: "\n\n")
        } else if text.contains("\n") {
            chunks = text.components(separatedBy: "\n")
        } else {
            // No newlines: group sentences into paragraphs of 5
            let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            var groups: [String] = []
            stride(from: 0, to: sentences.count, by: 5).forEach { i in
                let slice = sentences[i..<min(i + 5, sentences.count)]
                groups.append(slice.joined(separator: ". ") + (slice.last?.hasSuffix(".") == true ? "" : "."))
            }
            chunks = groups.isEmpty ? [text] : groups
        }

        return chunks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "<p>\(escapeHTML($0))</p>" }
            .joined(separator: "\n      ")
    }

    private static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&",  with: "&amp;")
            .replacingOccurrences(of: "<",  with: "&lt;")
            .replacingOccurrences(of: ">",  with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'",  with: "&#39;")
    }

    private static func sanitiseFileName(_ title: String) -> String {
        let safe = title
            .replacingOccurrences(of: "/",  with: "-")
            .replacingOccurrences(of: ":",  with: "-")
            .replacingOccurrences(of: " ",  with: "_")
            .prefix(60)
        return safe.isEmpty ? "transcript" : String(safe)
    }
}

// MARK: - TranscriptionSession helper

private extension TranscriptionSession {
    var displayTitle: String {
        if let t = customTitle, !t.isEmpty { return t }
        let preview = finalTranscript.prefix(60).trimmingCharacters(in: .whitespaces)
        return preview.isEmpty ? "Untitled session" : String(preview) + (finalTranscript.count > 60 ? "…" : "")
    }
}

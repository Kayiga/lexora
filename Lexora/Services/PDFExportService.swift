import PDFKit
import UIKit
import Foundation

/// Generates nicely formatted PDF documents from transcription sessions.
enum PDFExportService {

    // MARK: - Public API

    /// Creates a single-session PDF and returns a temporary file URL.
    static func exportSession(_ session: TranscriptionSession) -> URL? {
        let renderer = UIGraphicsPDFRenderer(bounds: .init(x: 0, y: 0, width: 595, height: 842)) // A4
        let filename = "Lexora_\(sanitised(session.startedAt))_\(session.id.uuidString.prefix(8)).pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        do {
            try renderer.writePDF(to: url) { ctx in
                ctx.beginPage()
                drawSession(session, context: ctx)
            }
            return url
        } catch {
            return nil
        }
    }

    /// Creates a multi-session PDF (all passed sessions, one per page).
    static func exportSessions(_ sessions: [TranscriptionSession]) -> URL? {
        guard !sessions.isEmpty else { return nil }
        let renderer = UIGraphicsPDFRenderer(bounds: .init(x: 0, y: 0, width: 595, height: 842))
        let filename = "Lexora_Transcripts_\(sanitised(Date())).pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        do {
            try renderer.writePDF(to: url) { ctx in
                for session in sessions {
                    ctx.beginPage()
                    drawSession(session, context: ctx)
                }
            }
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Drawing

    private static func drawSession(_ session: TranscriptionSession, context: UIGraphicsPDFRendererContext) {
        let margin: CGFloat = 56
        let pageW: CGFloat = 595
        var y: CGFloat = margin

        // ── Header gradient bar ────────────────────────────────────────────
        let headerRect = CGRect(x: 0, y: 0, width: pageW, height: 80)
        let colours: [CGColor] = [
            UIColor(red: 0.29, green: 0.11, blue: 0.78, alpha: 1).cgColor,
            UIColor(red: 0.56, green: 0.18, blue: 0.82, alpha: 1).cgColor
        ]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colours as CFArray,
                                     locations: [0, 1]) {
            let ctx = context.cgContext
            ctx.saveGState()
            ctx.clip(to: headerRect)
            ctx.drawLinearGradient(gradient,
                                   start: .init(x: 0, y: 0),
                                   end: .init(x: pageW, y: 0),
                                   options: [])
            ctx.restoreGState()
        }

        // App name in header
        draw("Lexora", at: CGPoint(x: margin, y: 24),
             font: .boldSystemFont(ofSize: 22), color: .white)

        y = 100

        // ── Date & Duration row ────────────────────────────────────────────
        let df = DateFormatter()
        df.dateStyle = .long
        df.timeStyle = .short
        let dateStr = df.string(from: session.startedAt)
        let durStr = formatDuration(session.durationSeconds)
        let lang = Locale.current.localizedString(forLanguageCode: session.primaryLanguage) ?? session.primaryLanguage

        draw(dateStr, at: CGPoint(x: margin, y: y),
             font: .systemFont(ofSize: 12, weight: .medium), color: .darkGray)
        y += 20

        draw("\(durStr) · \(session.wordCount) words · \(lang)",
             at: CGPoint(x: margin, y: y),
             font: .systemFont(ofSize: 11), color: UIColor(white: 0.4, alpha: 1))
        y += 8

        // Tags
        if !session.tags.isEmpty {
            let tagStr = session.tags.map { "#\($0)" }.joined(separator: "  ")
            draw(tagStr, at: CGPoint(x: margin, y: y),
                 font: .systemFont(ofSize: 10), color: UIColor(red: 0.29, green: 0.11, blue: 0.78, alpha: 1))
            y += 18
        }

        // Divider
        y += 8
        UIColor(white: 0.85, alpha: 1).setStroke()
        let path = UIBezierPath()
        path.move(to: .init(x: margin, y: y))
        path.addLine(to: .init(x: pageW - margin, y: y))
        path.stroke()
        y += 16

        // ── Custom title ───────────────────────────────────────────────────
        if let title = session.customTitle, !title.isEmpty {
            draw(title, at: CGPoint(x: margin, y: y),
                 font: .boldSystemFont(ofSize: 15), color: .darkText)
            y += 22
        }

        // ── Notes ──────────────────────────────────────────────────────────
        if let notes = session.notes, !notes.isEmpty {
            draw("Notes", at: CGPoint(x: margin, y: y),
                 font: .boldSystemFont(ofSize: 11), color: UIColor(white: 0.45, alpha: 1))
            y += 15
            let notesRect = CGRect(x: margin, y: y, width: pageW - 2 * margin, height: 80)
            let notesStyle = NSMutableParagraphStyle()
            notesStyle.lineSpacing = 3
            let notesAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.italicSystemFont(ofSize: 11),
                .foregroundColor: UIColor(white: 0.35, alpha: 1),
                .paragraphStyle: notesStyle
            ]
            NSAttributedString(string: notes, attributes: notesAttrs).draw(in: notesRect)
            y += min(80, CGFloat(notes.components(separatedBy: "\n").count + 1) * 15) + 10

            // Notes divider
            UIColor(white: 0.90, alpha: 1).setStroke()
            let nPath = UIBezierPath()
            nPath.move(to: .init(x: margin, y: y))
            nPath.addLine(to: .init(x: pageW - margin, y: y))
            nPath.setLineDash([3, 3], count: 2, phase: 0)
            nPath.stroke()
            y += 12
        }

        // ── Transcript body ────────────────────────────────────────────────
        let bodyText = session.finalTranscript.isEmpty ? "(Empty session)" : session.finalTranscript
        let bodyRect = CGRect(x: margin, y: y, width: pageW - 2 * margin, height: 842 - y - margin)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 5
        paragraphStyle.paragraphSpacing = 8

        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 13),
            .foregroundColor: UIColor.darkText,
            .paragraphStyle: paragraphStyle
        ]
        let bodyAS = NSAttributedString(string: bodyText, attributes: attrs)
        bodyAS.draw(in: bodyRect)

        // ── Footer ─────────────────────────────────────────────────────────
        let footerY: CGFloat = 810
        draw("Generated by Lexora  ·  \(session.id.uuidString)",
             at: CGPoint(x: margin, y: footerY),
             font: .systemFont(ofSize: 8), color: UIColor(white: 0.6, alpha: 1))
    }

    // MARK: - Helpers

    private static func draw(_ text: String, at point: CGPoint, font: UIFont, color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        NSAttributedString(string: text, attributes: attrs).draw(at: point)
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }

    private static func sanitised(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm"
        return df.string(from: date)
    }
}

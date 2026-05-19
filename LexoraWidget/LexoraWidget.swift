import WidgetKit
import SwiftUI
import ActivityKit

// MARK: - Shared gradient

private let lexoraGradient = LinearGradient(
    colors: [Color(red: 0.29, green: 0.11, blue: 0.78),
             Color(red: 0.56, green: 0.18, blue: 0.82)],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
)

// MARK: - App Group shared data reader

private struct WidgetData {
    let todayWords: Int
    let todaySessions: Int
    let streak: Int
    let dailyGoal: Int

    /// 0…1 progress toward the daily goal. Returns nil when no goal is set.
    var goalProgress: Double? {
        guard dailyGoal > 0 else { return nil }
        return min(1.0, Double(todayWords) / Double(dailyGoal))
    }

    static func load() -> WidgetData {
        let defaults = UserDefaults(suiteName: "group.com.yiga.Lexora")
        return WidgetData(
            todayWords:    defaults?.integer(forKey: "widget.todayWords")    ?? 0,
            todaySessions: defaults?.integer(forKey: "widget.todaySessions") ?? 0,
            streak:        defaults?.integer(forKey: "widget.streak")        ?? 0,
            dailyGoal:     defaults?.integer(forKey: "widget.dailyGoal")     ?? 0
        )
    }
}

// MARK: - Timeline Provider

struct LexoraProvider: TimelineProvider {
    func placeholder(in context: Context) -> LexoraEntry {
        LexoraEntry(date: Date(), todayWords: 142, todaySessions: 3, streak: 5, dailyGoal: 500)
    }
    func getSnapshot(in context: Context, completion: @escaping (LexoraEntry) -> Void) {
        let data = WidgetData.load()
        completion(LexoraEntry(date: Date(),
                               todayWords: data.todayWords,
                               todaySessions: data.todaySessions,
                               streak: data.streak,
                               dailyGoal: data.dailyGoal))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LexoraEntry>) -> Void) {
        let data = WidgetData.load()
        let entry = LexoraEntry(date: Date(),
                                todayWords: data.todayWords,
                                todaySessions: data.todaySessions,
                                streak: data.streak,
                                dailyGoal: data.dailyGoal)
        // Reload at midnight so the "today" counters reset correctly.
        let midnight = Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        )
        completion(Timeline(entries: [entry], policy: .after(midnight)))
    }
}

struct LexoraEntry: TimelineEntry {
    let date: Date
    let todayWords: Int
    let todaySessions: Int
    let streak: Int
    let dailyGoal: Int

    /// 0…1 progress toward the daily goal; nil when no goal is set.
    var goalProgress: Double? {
        guard dailyGoal > 0 else { return nil }
        return min(1.0, Double(todayWords) / Double(dailyGoal))
    }
    var goalMet: Bool { (goalProgress ?? 0) >= 1.0 }
}

// MARK: - Home Screen Widget Views

struct LexoraWidgetEntryView: View {
    var entry: LexoraEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:              smallView
        case .systemMedium:             mediumView
        case .systemLarge:              largeView
        case .accessoryCircular:        circularView
        case .accessoryRectangular:     rectangularView
        case .accessoryInline:          inlineView
        default:                        smallView
        }
    }

    // Small: mic button + goal ring (when goal set) + today word count
    private var smallView: some View {
        Link(destination: URL(string: "lexora://record")!) {
            VStack(spacing: 8) {
                ZStack {
                    // Goal ring sits behind the mic circle when a goal is set
                    if let progress = entry.goalProgress {
                        Circle()
                            .stroke(.white.opacity(0.15),
                                    style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .frame(width: 62, height: 62)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(
                                entry.goalMet
                                    ? LinearGradient(colors: [.green, .mint], startPoint: .topLeading, endPoint: .bottomTrailing)
                                    : LinearGradient(colors: [.white, .white.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 62, height: 62)
                    }
                    Circle().fill(.white.opacity(0.18)).frame(width: 54, height: 54)
                    Image(systemName: entry.goalMet ? "checkmark" : "mic.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }
                if entry.todayWords > 0 {
                    Text("\(entry.todayWords)w today")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                } else {
                    Text("Record")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .widgetURL(URL(string: "lexora://record"))
        .containerBackground(for: .widget) { lexoraGradient }
    }

    // Medium: mic button + today stats + streak
    private var mediumView: some View {
        HStack(spacing: 0) {
            // Left: big record button
            Link(destination: URL(string: "lexora://record")!) {
                VStack(spacing: 8) {
                    ZStack {
                        Circle().fill(.white.opacity(0.18)).frame(width: 60, height: 60)
                        Image(systemName: "mic.fill").font(.system(size: 26)).foregroundStyle(.white)
                    }
                    Text("Record")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .padding(.leading, 18)

            Divider()
                .background(.white.opacity(0.25))
                .frame(height: 60)
                .padding(.horizontal, 16)

            // Right: today stats
            VStack(alignment: .leading, spacing: 10) {
                statRow(icon: "text.word.spacing",
                        label: "\(entry.todayWords) words today")
                statRow(icon: "waveform",
                        label: "\(entry.todaySessions) session\(entry.todaySessions == 1 ? "" : "s")")
                if entry.streak > 0 {
                    statRow(icon: "flame.fill",
                            label: "\(entry.streak)-day streak",
                            iconColor: .orange)
                }
                // Goal progress bar — only shown when a goal is set
                if let progress = entry.goalProgress {
                    VStack(alignment: .leading, spacing: 3) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.15))
                                    .frame(width: geo.size.width, height: 4)
                                Capsule()
                                    .fill(entry.goalMet ? Color.green : Color.white)
                                    .frame(width: geo.size.width * progress, height: 4)
                            }
                        }
                        .frame(height: 4)
                        Text(entry.goalMet ? "Goal reached! 🎉" : "\(entry.dailyGoal - entry.todayWords) left")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }

            Spacer()
        }
        .widgetURL(URL(string: "lexora://record"))
        .containerBackground(for: .widget) { lexoraGradient }
    }

    // Large: mic button + today stats (bigger layout)
    private var largeView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: "waveform.and.person.filled")
                    .font(.title3)
                    .foregroundStyle(.white)
                Text("Lexora")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text(Date(), style: .date)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }

            // Big record button
            Link(destination: URL(string: "lexora://record")!) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(.white.opacity(0.18)).frame(width: 52, height: 52)
                        Image(systemName: "mic.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start Recording")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("Tap to begin dictating")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(14)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            }

            Divider().background(.white.opacity(0.2))

            // Today stats grid
            HStack(spacing: 0) {
                // Word count cell — replaced by goal ring when a goal is set
                if let progress = entry.goalProgress {
                    VStack(spacing: 4) {
                        ZStack {
                            Circle()
                                .stroke(.white.opacity(0.15),
                                        style: StrokeStyle(lineWidth: 5, lineCap: .round))
                                .frame(width: 44, height: 44)
                            Circle()
                                .trim(from: 0, to: progress)
                                .stroke(
                                    entry.goalMet
                                        ? LinearGradient(colors: [.green, .mint], startPoint: .topLeading, endPoint: .bottomTrailing)
                                        : LinearGradient(colors: [.white, .white.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                    style: StrokeStyle(lineWidth: 5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .frame(width: 44, height: 44)
                            Text(entry.goalMet ? "✓" : "\(Int(progress * 100))%")
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundStyle(.white)
                        }
                        Text(entry.goalMet ? "Goal met!" : "\(entry.todayWords)w")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    largeStatCell(value: "\(entry.todayWords)", label: "words today")
                }
                largeStatCell(value: "\(entry.todaySessions)", label: "session\(entry.todaySessions == 1 ? "" : "s")")
                largeStatCell(value: "\(entry.streak)", label: "day streak", icon: "flame.fill", iconColor: entry.streak > 0 ? .orange : .white)
            }

            // Goal progress bar — only in large view when goal is set and not yet met
            if let progress = entry.goalProgress, !entry.goalMet {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Daily goal")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white.opacity(0.7))
                        Spacer()
                        Text("\(entry.todayWords) / \(entry.dailyGoal)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.15))
                                .frame(width: geo.size.width, height: 5)
                            Capsule().fill(Color.white)
                                .frame(width: geo.size.width * progress, height: 5)
                        }
                    }
                    .frame(height: 5)
                    Text("\(entry.dailyGoal - entry.todayWords) words to reach your goal")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(.top, 4)
            } else if entry.goalMet {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text("Daily goal reached! 🎉")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.top, 4)
            }

            Spacer()

            // Quick-link row: History + Profile
            HStack(spacing: 12) {
                Link(destination: URL(string: "lexora://history")!) {
                    HStack(spacing: 5) {
                        Image(systemName: "clock.fill")
                            .font(.caption2)
                        Text("History")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.1), in: Capsule())
                }

                Link(destination: URL(string: "lexora://profile")!) {
                    HStack(spacing: 5) {
                        Image(systemName: "person.wave.2.fill")
                            .font(.caption2)
                        Text("Profile")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.1), in: Capsule())
                }
            }
        }
        .padding(16)
        .widgetURL(URL(string: "lexora://record"))
        .containerBackground(for: .widget) { lexoraGradient }
    }

    // Lock Screen – circular: mic + goal arc (real goal if set, relative activity if not)
    private var circularView: some View {
        ZStack {
            if let progress = entry.goalProgress {
                // Track ring
                Circle()
                    .stroke(style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .foregroundStyle(.secondary.opacity(0.3))
                // Progress arc — full circle animates to green when goal met
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .foregroundStyle(entry.goalMet ? .green : .primary)
            } else if entry.todayWords > 0 {
                // No goal set — show a relative activity arc (capped at a nominal 500w)
                let fraction = min(1.0, Double(entry.todayWords) / 500.0)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .foregroundStyle(.primary.opacity(0.5))
            }
            VStack(spacing: 0) {
                Image(systemName: entry.goalMet ? "checkmark" : "mic.fill")
                    .font(.system(size: 14, weight: .semibold))
                if let progress = entry.goalProgress {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                } else if entry.todayWords > 0 {
                    Text("\(entry.todayWords)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
            }
        }
        .widgetURL(URL(string: "lexora://record"))
        .containerBackground(for: .widget) { Color.clear }
    }

    // Lock Screen – rectangular: mic + compact stats
    private var rectangularView: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Lexora")
                    .font(.caption.weight(.semibold))
                if entry.todayWords > 0 {
                    Text("\(entry.todayWords)w · \(entry.todaySessions) sessions")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Tap to record")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if entry.streak > 1 {
                    Label("\(entry.streak) day streak", systemImage: "flame.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .widgetURL(URL(string: "lexora://record"))
        .containerBackground(for: .widget) { Color.clear }
    }

    // Lock Screen – inline: single line summary
    private var inlineView: some View {
        Label(
            entry.todayWords > 0 ? "\(entry.todayWords)w · \(entry.streak)d streak" : "Tap to record",
            systemImage: "mic.fill"
        )
        .widgetURL(URL(string: "lexora://record"))
        .containerBackground(for: .widget) { Color.clear }
    }

    private func largeStatCell(value: String, label: String, icon: String? = nil, iconColor: Color = .white) -> some View {
        VStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(iconColor.opacity(0.8))
            }
            Text(value)
                .font(.title2.bold().monospacedDigit())
                .foregroundStyle(.white)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func statRow(icon: String, label: String, iconColor: Color = .white) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(iconColor.opacity(0.9))
                .frame(width: 14)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.88))
        }
    }
}

struct LexoraWidget: Widget {
    let kind: String = "LexoraWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LexoraProvider()) { entry in
            LexoraWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Lexora")
        .description("Tap to start a new voice recording instantly.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryRectangular, .accessoryInline
        ])
    }
}

// MARK: - Live Activity Views

struct RecordingLockScreenView: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        HStack(spacing: 16) {
            // Animated mic indicator
            ZStack {
                Circle()
                    .fill(context.state.isListening ? Color.red.opacity(0.2) : Color.white.opacity(0.1))
                    .frame(width: 44, height: 44)
                Image(systemName: context.state.isListening ? "mic.fill" : "mic.slash.fill")
                    .foregroundStyle(context.state.isListening ? .red : .white)
                    .font(.system(size: 20))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(context.state.isListening ? "Recording…" : "Paused")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                HStack(spacing: 8) {
                    Label("\(context.state.wordCount) words", systemImage: "text.word.spacing")
                    Text("·")
                    Text(context.state.elapsedFormatted)
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
            }

            Spacer()

            // Language pill
            Text(languageName(context.state.detectedLanguage))
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.white.opacity(0.15), in: Capsule())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .containerBackground(for: .widget) { lexoraGradient }
    }

    private func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
    }
}

// MARK: - Live Activity Configuration

struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            RecordingLockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill")
                            .foregroundStyle(context.state.isListening ? .red : .secondary)
                            .font(.system(size: 16, weight: .semibold))
                        Text(context.state.isListening ? "Recording" : "Paused")
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.elapsedFormatted)
                        .font(.subheadline.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 20) {
                        Label("\(context.state.wordCount) words", systemImage: "text.word.spacing")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Label(languageName(context.state.detectedLanguage), systemImage: "globe")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Link(destination: URL(string: "lexora://record")!) {
                            Text("Open")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .background(Color(red: 0.29, green: 0.11, blue: 0.78), in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 4)
                }
            } compactLeading: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(context.state.isListening ? .red : .white)
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.leading, 4)
            } compactTrailing: {
                Text(context.state.elapsedFormatted)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.trailing, 4)
            } minimal: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(context.state.isListening ? .red : .white)
                    .font(.system(size: 12))
            }
            .keylineTint(Color(red: 0.56, green: 0.18, blue: 0.82))
            .contentMargins(.horizontal, 16, for: .expanded)
        }
    }

    private func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
    }
}

// MARK: - Widget Bundle

@main
struct LexoraWidgetBundle: WidgetBundle {
    var body: some Widget {
        LexoraWidget()
        RecordingLiveActivity()
    }
}

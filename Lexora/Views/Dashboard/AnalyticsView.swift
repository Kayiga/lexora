import SwiftUI
import Charts
import NaturalLanguage

// Full-screen analytics sheet — pushed from DashboardView via a "See analytics" button.
struct AnalyticsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    // MARK: - Period picker

    enum AnalyticsPeriod: String, CaseIterable, Identifiable {
        case week  = "Week"
        case month = "Month"
        case all   = "All Time"
        var id: String { rawValue }
    }

    @State private var period: AnalyticsPeriod = .week
    @State private var showExportSheet = false
    @State private var exportItems: [Any] = []

    // Heatmap day-tap popover
    @State private var tappedDay: Date? = nil
    @State private var showDayPopover = false

    // MARK: - Computed Data

    private var sessions: [TranscriptionSession] { appState.sessions }

    /// Sessions within the selected period window.
    private var scopedSessions: [TranscriptionSession] {
        let cal = Calendar.current
        let now = Date()
        switch period {
        case .week:
            let cutoff = cal.date(byAdding: .day, value: -7, to: now) ?? now
            return sessions.filter { $0.startedAt >= cutoff }
        case .month:
            let cutoff = cal.date(byAdding: .day, value: -30, to: now) ?? now
            return sessions.filter { $0.startedAt >= cutoff }
        case .all:
            return sessions
        }
    }

    /// Sessions from the equivalent prior period (used for delta badges).
    private var previousPeriodSessions: [TranscriptionSession] {
        let cal = Calendar.current
        let now = Date()
        switch period {
        case .week:
            let end   = cal.date(byAdding: .day, value: -7,  to: now) ?? now
            let start = cal.date(byAdding: .day, value: -14, to: now) ?? now
            return sessions.filter { $0.startedAt >= start && $0.startedAt < end }
        case .month:
            let end   = cal.date(byAdding: .day, value: -30, to: now) ?? now
            let start = cal.date(byAdding: .day, value: -60, to: now) ?? now
            return sessions.filter { $0.startedAt >= start && $0.startedAt < end }
        case .all:
            return []
        }
    }

    // Total stats (scoped to selected period)
    private var totalWords: Int { scopedSessions.reduce(0) { $0 + $1.wordCount } }
    private var totalMinutes: Double { scopedSessions.reduce(0) { $0 + $1.durationSeconds } / 60 }
    private var avgWPM: Double {
        let valid = scopedSessions.filter { $0.paceWPM > 0 }
        guard !valid.isEmpty else { return 0 }
        return valid.reduce(0) { $0 + $1.paceWPM } / Double(valid.count)
    }
    private var avgConfidence: Double {
        let valid = scopedSessions.filter { $0.confidenceAverage > 0 }
        guard !valid.isEmpty else { return 0 }
        return valid.reduce(0) { $0 + $1.confidenceAverage } / Double(valid.count)
    }

    // Streak
    private var currentStreak: Int {
        var streak = 0
        var date = Calendar.current.startOfDay(for: Date())
        while true {
            let hasSession = sessions.contains { Calendar.current.isDate($0.startedAt, inSameDayAs: date) }
            if hasSession { streak += 1 } else { break }
            guard let prev = Calendar.current.date(byAdding: .day, value: -1, to: date) else { break }
            date = prev
        }
        return streak
    }

    // Filler word aggregation (scoped; profile aggregate added only for All Time)
    private var fillerFrequency: [(word: String, count: Int)] {
        var freq: [String: Int] = [:]
        for session in scopedSessions {
            for word in session.fillerWords { freq[word.lowercased(), default: 0] += 1 }
        }
        // Profile aggregate is all-time, so only blend it in when not period-scoped
        if period == .all {
            for (word, count) in appState.profile.fillerWordFrequency {
                freq[word.lowercased(), default: 0] += count
            }
        }
        return freq.map { (word: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
            .prefix(6)
            .map { $0 }
    }

    // Top content words (scoped to selected period)
    private var topWords: [(word: String, count: Int)] {
        let allText = scopedSessions.map { $0.finalTranscript }.joined(separator: " ")
        guard !allText.isEmpty else { return [] }
        var freq: [String: Int] = [:]
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = allText
        tagger.enumerateTags(in: allText.startIndex..<allText.endIndex,
                             unit: .word,
                             scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            if let tag, [.noun, .verb, .adjective].contains(tag) {
                let word = String(allText[range]).lowercased()
                if word.count > 3 { freq[word, default: 0] += 1 }
            }
            return true
        }
        return freq.sorted { $0.value > $1.value }.prefix(24).map { (word: $0.key, count: $0.value) }
    }

    // Language distribution (scoped)
    private var languageBreakdown: [(code: String, count: Int)] {
        var freq: [String: Int] = [:]
        for session in scopedSessions { freq[session.primaryLanguage, default: 0] += 1 }
        return freq.map { (code: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
            .prefix(5)
            .map { $0 }
    }

    private var languageWordBreakdown: [(code: String, words: Int, avgWPM: Double)] {
        var wordsByLang: [String: Int] = [:]
        var wpmByLang:   [String: [Double]] = [:]
        for session in scopedSessions {
            wordsByLang[session.primaryLanguage, default: 0] += session.wordCount
            if session.paceWPM > 0 {
                wpmByLang[session.primaryLanguage, default: []].append(session.paceWPM)
            }
        }
        return wordsByLang.map { code, words in
            let wpms = wpmByLang[code] ?? []
            let avg  = wpms.isEmpty ? 0 : wpms.reduce(0, +) / Double(wpms.count)
            return (code: code, words: words, avgWPM: avg)
        }
        .sorted { $0.words > $1.words }
        .prefix(5)
        .map { $0 }
    }

    /// Top tags by session count, capped at 10, for the period in scope.
    private struct TagBucket: Identifiable {
        let id: String   // tag name
        let count: Int
        let avgWords: Int
    }

    private var tagBreakdown: [TagBucket] {
        var tagSessions: [String: [TranscriptionSession]] = [:]
        for session in scopedSessions {
            for tag in session.tags {
                tagSessions[tag, default: []].append(session)
            }
        }
        return tagSessions.map { tag, sessions in
            let avg = sessions.isEmpty ? 0 : sessions.reduce(0) { $0 + $1.wordCount } / sessions.count
            return TagBucket(id: tag, count: sessions.count, avgWords: avg)
        }
        .sorted { $0.count > $1.count }
        .prefix(10)
        .map { $0 }
    }

    // Daily word-count series (last 14 days)
    private struct DayPoint: Identifiable {
        let id = UUID()
        let date: Date
        let words: Int
        let sessions: Int
    }

    private var dailySeriesDayCount: Int {
        switch period {
        case .week:  return 14
        case .month: return 30
        case .all:   return 90
        }
    }

    private var dailySeries: [DayPoint] {
        (0..<dailySeriesDayCount).compactMap { daysAgo -> DayPoint? in
            guard let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) else { return nil }
            let day = Calendar.current.startOfDay(for: date)
            let matching = sessions.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: day) }
            return DayPoint(date: day, words: matching.reduce(0) { $0 + $1.wordCount }, sessions: matching.count)
        }.reversed()
    }

    // WPM trend (last 20 sessions within period)
    private var wpmSeries: [(index: Int, wpm: Double)] {
        scopedSessions.filter { $0.paceWPM > 0 }
            .prefix(20)
            .reversed()
            .enumerated()
            .map { (index: $0.offset, wpm: $0.element.paceWPM) }
    }

    // Confidence trend (last 20 sessions within period)
    private var confidenceSeries: [(index: Int, pct: Double)] {
        scopedSessions.filter { $0.confidenceAverage > 0 }
            .prefix(20)
            .reversed()
            .enumerated()
            .map { (index: $0.offset, pct: $0.element.confidenceAverage * 100) }
    }

    // MARK: - Period Comparison

    private var previousWords: Int    { previousPeriodSessions.reduce(0) { $0 + $1.wordCount } }
    private var previousMinutes: Double { previousPeriodSessions.reduce(0) { $0 + $1.durationSeconds } / 60 }
    private var previousAvgWPM: Double {
        let valid = previousPeriodSessions.filter { $0.paceWPM > 0 }
        return valid.isEmpty ? 0 : valid.reduce(0) { $0 + $1.paceWPM } / Double(valid.count)
    }
    private var previousAvgConfidence: Double {
        let valid = previousPeriodSessions.filter { $0.confidenceAverage > 0 }
        return valid.isEmpty ? 0 : valid.reduce(0) { $0 + $1.confidenceAverage } / Double(valid.count)
    }

    /// Returns a formatted "+12% vs last week/month" badge, or nil for All Time / no data.
    private func periodDeltaLabel(current: Double, previous: Double) -> String? {
        guard period != .all, previous > 0, current > 0 else { return nil }
        let pct = ((current - previous) / previous) * 100
        let sign = pct >= 0 ? "+" : ""
        let label = period == .week ? "last week" : "last month"
        return "\(sign)\(Int(pct))% vs \(label)"
    }

    // MARK: - Personal Records

    private var bestWordSession: TranscriptionSession? {
        sessions.max(by: { $0.wordCount < $1.wordCount })
    }
    private var longestSession: TranscriptionSession? {
        sessions.max(by: { $0.durationSeconds < $1.durationSeconds })
    }
    private var bestAccuracySession: TranscriptionSession? {
        sessions.filter { $0.estimatedAccuracy > 0 }.max(by: { $0.estimatedAccuracy < $1.estimatedAccuracy })
    }

    /// Longest consecutive calendar-day streak across all-time session history.
    private var longestStreakEver: Int {
        guard !sessions.isEmpty else { return 0 }
        let cal = Calendar.current
        let activeDays = Set(sessions.map { cal.startOfDay(for: $0.startedAt) })
            .sorted()
        var best = 0, current = 0
        var prev: Date? = nil
        for day in activeDays {
            if let p = prev,
               cal.dateComponents([.day], from: p, to: day).day == 1 {
                current += 1
            } else {
                current = 1
            }
            if current > best { best = current }
            prev = day
        }
        return best
    }

    // MARK: - Time-of-day distribution (bucket into 6-hour blocks)

    private struct HourBucket: Identifiable {
        let id: String
        let label: String
        let count: Int
        let color: Color
    }

    private struct DayBucket: Identifiable {
        let id: Int          // weekday index 1 = Sunday … 7 = Saturday
        let label: String
        let avgWords: Double // average words on this day-of-week
    }

    /// Average word count per day-of-week, computed from all-time sessions so the
    /// comparison is meaningful regardless of the selected period.
    private var dayOfWeekBuckets: [DayBucket] {
        let cal = Calendar.current
        // Group by weekday (1 = Sunday, 2 = Monday … 7 = Saturday)
        var totalWords = [Int: Int]()
        var dayCounts  = [Int: Int]()
        for s in sessions {
            let wd = cal.component(.weekday, from: s.startedAt)
            totalWords[wd, default: 0] += s.wordCount
            dayCounts[wd, default: 0]  += 1
        }
        // Build ordered Mon–Sun buckets
        let orderedWeekdays: [(wday: Int, label: String)] = [
            (2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"),
            (6, "Fri"), (7, "Sat"), (1, "Sun")
        ]
        return orderedWeekdays.map { item in
            let avg = dayCounts[item.wday].map {
                Double(totalWords[item.wday] ?? 0) / Double(max(1, $0))
            } ?? 0
            return DayBucket(id: item.wday, label: item.label, avgWords: avg)
        }
    }

    private var timeOfDayBuckets: [HourBucket] {
        var buckets = [0: 0, 6: 0, 12: 0, 18: 0]   // midnight, morning, afternoon, evening
        for s in scopedSessions {
            let hour = Calendar.current.component(.hour, from: s.startedAt)
            switch hour {
            case 0..<6:   buckets[0,  default: 0] += 1
            case 6..<12:  buckets[6,  default: 0] += 1
            case 12..<18: buckets[12, default: 0] += 1
            default:      buckets[18, default: 0] += 1
            }
        }
        return [
            HourBucket(id: "night",     label: "Night\n12–6am",  count: buckets[0,  default: 0], color: .indigo),
            HourBucket(id: "morning",   label: "Morning\n6–12",  count: buckets[6,  default: 0], color: .orange),
            HourBucket(id: "afternoon", label: "Afternoon\n12–6",count: buckets[12, default: 0], color: .yellow),
            HourBucket(id: "evening",   label: "Evening\n6–12",  count: buckets[18, default: 0], color: .purple),
        ]
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            if sessions.isEmpty {
                ContentUnavailableView(
                    "No data yet",
                    systemImage: "chart.bar.xaxis",
                    description: Text("Record at least one session to see your analytics.")
                )
                .navigationTitle("Analytics")
            } else {
                ScrollView {
                    LazyVStack(spacing: 20) {
                        // Period segmented picker
                        Picker("Period", selection: $period) {
                            ForEach(AnalyticsPeriod.allCases) { p in
                                Text(p.rawValue).tag(p)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 2)
                        .padding(.top, 4)

                        summaryCards
                        personalRecordsCard
                        timeSavingsCard
                        wordVolumeChart
                        durationHistogramChart
                        timeOfDayChart
                        dayOfWeekChart
                        wpmTrendChart
                        confidenceChart
                        if !languageBreakdown.isEmpty { languageChart }
                        if !languageWordBreakdown.isEmpty { languageWordChart }
                        if !fillerFrequency.isEmpty { fillerWordsChart }
                        if !topWords.isEmpty { topWordsCloud }
                        tagsChart
                        if !templatePerformanceData.isEmpty { templatePerformanceChart }
                        activityCalendar    // always shows full history
                        recordingStreakCard  // always shows full streak
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
                .navigationTitle("Analytics")
                .navigationBarTitleDisplayMode(.large)
                .animation(.easeInOut(duration: 0.25), value: period)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            exportAnalyticsJSON()
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
                .sheet(isPresented: $showExportSheet) {
                    ShareSheet(items: exportItems)
                }
            }
        }
    }

    // MARK: - Summary Cards

    private var summaryCards: some View {
        let periodLabel: String = {
            switch period {
            case .week:  return "This week"
            case .month: return "This month"
            case .all:   return "All time"
            }
        }()
        let columns = horizontalSizeClass == .regular
            ? Array(repeating: GridItem(.flexible()), count: 4)
            : [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, spacing: 12) {
            statCard(
                value: "\(totalWords.formatted())",
                label: "\(periodLabel) words",
                icon: "text.word.spacing",
                color: .blue,
                weeklyDelta: periodDeltaLabel(
                    current: Double(totalWords),
                    previous: Double(previousWords)
                )
            )
            statCard(
                value: String(format: "%.0fm", totalMinutes),
                label: "\(periodLabel) recorded",
                icon: "timer",
                color: .purple,
                weeklyDelta: periodDeltaLabel(
                    current: totalMinutes,
                    previous: previousMinutes
                )
            )
            statCard(
                value: scopedSessions.isEmpty ? "–" : String(format: "%.0f WPM", avgWPM),
                label: "Avg pace",
                icon: "gauge.with.needle",
                color: .orange,
                weeklyDelta: period != .all ? periodDeltaLabel(current: avgWPM, previous: previousAvgWPM) : nil
            )
            statCard(
                value: scopedSessions.isEmpty ? "–" : String(format: "%.0f%%", avgConfidence * 100),
                label: "Avg confidence",
                icon: "checkmark.seal",
                color: .green,
                weeklyDelta: period != .all ? periodDeltaLabel(current: avgConfidence * 100, previous: previousAvgConfidence * 100) : nil
            )
        }
    }

    private func statCard(
        value: String,
        label: String,
        icon: String,
        color: Color,
        weeklyDelta: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(color)
                Spacer()
                if let delta = weeklyDelta {
                    let isPositive = delta.hasPrefix("+")
                    Text(delta)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isPositive ? Color.green : Color.red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            (isPositive ? Color.green : Color.red).opacity(0.12),
                            in: Capsule()
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            Text(value)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Typing Time Savings

    /// Shows how much time the user saved by dictating instead of typing (40 WPM baseline).
    @ViewBuilder
    private var timeSavingsCard: some View {
        // Use all-time words so the insight is always meaningful regardless of period
        let allTimeWords = sessions.reduce(0) { $0 + $1.wordCount }
        let allTimeMinutes = sessions.reduce(0.0) { $0 + $1.durationSeconds } / 60.0
        let typingMinutes = Double(allTimeWords) / 40.0   // 40 WPM typing baseline
        let savedMinutes  = typingMinutes - allTimeMinutes

        if allTimeWords >= 100, savedMinutes > 1 {
            let savedStr: String = savedMinutes >= 60
                ? String(format: "%.1f hrs", savedMinutes / 60.0)
                : "\(Int(savedMinutes)) min"
            let efficiencyPct = Int((savedMinutes / typingMinutes) * 100)

            VStack(alignment: .leading, spacing: 12) {
                Label("Dictation efficiency", systemImage: "bolt.fill")
                    .font(.headline)
                    .foregroundStyle(.yellow)

                HStack(spacing: 0) {
                    VStack(spacing: 4) {
                        Text(savedStr)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.green)
                        Text("saved vs typing")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)

                    Divider().frame(height: 44)

                    VStack(spacing: 4) {
                        Text("\(efficiencyPct)%")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.green)
                        Text("faster than typing")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)

                    Divider().frame(height: 44)

                    VStack(spacing: 4) {
                        Text("\(allTimeWords.formatted())")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.primary)
                        Text("words all time")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }

                Text("Compared to average typing speed of 40 WPM")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: - Personal Records

    /// Days in the scoped period where the daily word goal was met (0 if no goal set).
    private var goalMetDays: (met: Int, total: Int) {
        let goal = appState.profile.dailyWordGoal
        guard goal > 0, !scopedSessions.isEmpty else { return (0, 0) }
        let cal = Calendar.current
        let byDay = Dictionary(grouping: scopedSessions) { cal.startOfDay(for: $0.startedAt) }
        let met = byDay.filter { _, daySessions in
            daySessions.reduce(0) { $0 + $1.wordCount } >= goal
        }.count
        return (met, byDay.count)
    }

    @ViewBuilder
    private var personalRecordsCard: some View {
        if sessions.count >= 3 {
            VStack(alignment: .leading, spacing: 12) {
                Label("Personal Records", systemImage: "trophy.fill")
                    .font(.headline)
                    .foregroundStyle(.yellow)

                HStack(spacing: 10) {
                    if let best = bestWordSession {
                        recordPill(icon: "text.word.spacing", color: .blue,
                                   value: "\(best.wordCount)w",
                                   label: "Most words",
                                   date: best.startedAt)
                    }
                    if let longest = longestSession {
                        recordPill(icon: "timer", color: .purple,
                                   value: "\(Int(longest.durationSeconds))s",
                                   label: "Longest",
                                   date: longest.startedAt)
                    }
                    if let accurate = bestAccuracySession {
                        recordPill(icon: "checkmark.seal.fill", color: .green,
                                   value: "\(Int(accurate.estimatedAccuracy))%",
                                   label: "Accuracy",
                                   date: accurate.startedAt)
                    }
                    let streak = longestStreakEver
                    if streak > 1 {
                        recordPill(icon: "flame.fill", color: .orange,
                                   value: "\(streak)d",
                                   label: "Best streak",
                                   footnote: "all time")
                    }
                }

                // Goal achievement rate for the selected period
                let (metDays, totalDays) = goalMetDays
                if totalDays > 0 {
                    let pct = Int((Double(metDays) / Double(totalDays)) * 100)
                    HStack(spacing: 8) {
                        Image(systemName: "target")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                        Text("Goal met \(metDays)/\(totalDays) active days (\(pct)%)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if pct >= 80 {
                            Text("🏆")
                        } else if pct >= 50 {
                            Text("💪")
                        }
                    }
                    .padding(10)
                    .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(16)
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func recordPill(icon: String, color: Color, value: String, label: String,
                            date: Date? = nil, footnote: String? = nil) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(color)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let date {
                Text(date, format: .dateTime.month(.abbreviated).day())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            } else if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Time-of-day Chart

    @ViewBuilder
    private var timeOfDayChart: some View {
        let buckets = timeOfDayBuckets
        if buckets.contains(where: { $0.count > 0 }) {
            chartCard(title: "When you record", subtitle: "Sessions by time of day", icon: "clock.fill") {
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(buckets) { bucket in
                        let maxCount = max(1, buckets.map { $0.count }.max() ?? 1)
                        let barH = CGFloat(bucket.count) / CGFloat(maxCount) * 90 + 4
                        VStack(spacing: 4) {
                            Text("\(bucket.count)")
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .foregroundStyle(bucket.count > 0 ? bucket.color : .clear)
                            RoundedRectangle(cornerRadius: 6)
                                .fill(bucket.color.opacity(0.75).gradient)
                                .frame(height: barH)
                            Text(bucket.label)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .animation(.spring(response: 0.5), value: bucket.count)
                    }
                }
                .frame(height: 130)
            }
        }
    }

    // MARK: - Day of Week chart

    @ViewBuilder
    private var dayOfWeekChart: some View {
        let buckets = dayOfWeekBuckets
        let maxAvg = max(1.0, buckets.map { $0.avgWords }.max() ?? 1.0)
        if buckets.contains(where: { $0.avgWords > 0 }) {
            chartCard(title: "Best day to record", subtitle: "Avg words · all-time · Mon–Sun",
                      icon: "calendar.badge.clock") {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(buckets) { bucket in
                        let ratio = CGFloat(bucket.avgWords / maxAvg)
                        let barH  = max(4, ratio * 90)
                        let isPeak = bucket.avgWords == buckets.map(\.avgWords).max()
                        VStack(spacing: 4) {
                            if isPeak {
                                Image(systemName: "crown.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.yellow)
                            } else {
                                Spacer().frame(height: 13)
                            }
                            Text(bucket.avgWords > 0
                                 ? "\(Int(bucket.avgWords))" : "")
                                .font(.system(size: 8).monospacedDigit())
                                .foregroundStyle(isPeak ? Color.accentColor : .secondary)
                            RoundedRectangle(cornerRadius: 5)
                                .fill((isPeak ? Color.accentColor : Color.secondary).opacity(0.65).gradient)
                                .frame(height: barH)
                            Text(bucket.label)
                                .font(.system(size: 10, weight: isPeak ? .semibold : .regular))
                                .foregroundStyle(isPeak ? .primary : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .animation(.spring(response: 0.5), value: bucket.avgWords)
                    }
                }
                .frame(height: 140)
            }
        }
    }

    // MARK: - Word Volume (last 14 days)

    private var wordVolumeChart: some View {
        let subtitle: String = {
            switch period {
            case .week:  return "Last 14 days"
            case .month: return "Last 30 days"
            case .all:   return "Last 90 days"
            }
        }()
        let goal = appState.profile.dailyWordGoal
        let goalMet = dailySeries.filter { goal > 0 && $0.words >= goal }.count
        let subtitleSuffix = goal > 0 ? " · \(goalMet) goal days" : ""
        return chartCard(title: "Word volume", subtitle: subtitle + subtitleSuffix, icon: "text.word.spacing") {
            Chart {
                ForEach(dailySeries) { point in
                    BarMark(
                        x: .value("Date", point.date, unit: .day),
                        y: .value("Words", point.words)
                    )
                    .foregroundStyle(
                        goal > 0 && point.words >= goal
                            ? Color.green.gradient
                            : Color.accentColor.opacity(0.7).gradient
                    )
                    .cornerRadius(4)
                }
                // Goal line
                if goal > 0 {
                    RuleMark(y: .value("Goal", goal))
                        .foregroundStyle(Color.green.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .annotation(position: .trailing, alignment: .leading) {
                            Text("Goal")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.green)
                        }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.day(.twoDigits), centered: true)
                }
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 150)
        }
    }

    // MARK: - WPM Trend

    @ViewBuilder
    private var wpmTrendChart: some View {
        if wpmSeries.count >= 2 {
            chartCard(title: "Speaking pace", subtitle: "Words per minute · recent sessions", icon: "gauge.with.needle") {
                Chart(wpmSeries, id: \.index) { point in
                    LineMark(
                        x: .value("Session", point.index),
                        y: .value("WPM", point.wpm)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Color.orange.gradient)

                    AreaMark(
                        x: .value("Session", point.index),
                        y: .value("WPM", point.wpm)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Color.orange.opacity(0.12).gradient)
                }
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 130)
            }
        }
    }

    // MARK: - Confidence Trend

    @ViewBuilder
    private var confidenceChart: some View {
        if confidenceSeries.count >= 2 {
            chartCard(title: "Recognition confidence", subtitle: "Percentage · recent sessions", icon: "checkmark.seal") {
                Chart(confidenceSeries, id: \.index) { point in
                    LineMark(
                        x: .value("Session", point.index),
                        y: .value("Confidence %", point.pct)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Color.green.gradient)

                    AreaMark(
                        x: .value("Session", point.index),
                        y: .value("Confidence %", point.pct)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Color.green.opacity(0.12).gradient)

                    // 80% reference line
                    RuleMark(y: .value("Target", 80))
                        .lineStyle(StrokeStyle(dash: [4]))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .annotation(position: .trailing, alignment: .leading) {
                            Text("80%").font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartYScale(domain: 0...100)
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 130)
            }
        }
    }

    // MARK: - Language Breakdown

    private var languageChart: some View {
        let total = Double(sessions.count)
        // Precompute avg accuracy per language for annotations
        let accuracyByLang: [String: Double] = {
            var result: [String: Double] = [:]
            for item in languageBreakdown {
                let matching = scopedSessions.filter { $0.primaryLanguage == item.code && $0.estimatedAccuracy > 0 }
                if !matching.isEmpty {
                    result[item.code] = matching.reduce(0) { $0 + $1.estimatedAccuracy } / Double(matching.count)
                }
            }
            return result
        }()

        return chartCard(title: "Languages used", subtitle: "By session count · with avg accuracy", icon: "globe") {
            VStack(spacing: 8) {
                ForEach(languageBreakdown, id: \.code) { item in
                    let fraction = total > 0 ? Double(item.count) / total : 0
                    HStack(spacing: 10) {
                        Text(Locale.current.localizedString(forLanguageCode: item.code) ?? item.code)
                            .font(.subheadline)
                            .frame(width: 90, alignment: .leading)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.accentColor.opacity(0.2 + fraction * 0.8))
                                .frame(width: geo.size.width * fraction)
                        }
                        .frame(height: 18)
                        HStack(spacing: 4) {
                            Text("\(item.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            if let acc = accuracyByLang[item.code] {
                                let color: Color = acc > 90 ? .green : acc > 75 ? .orange : .red
                                Text("\(Int(acc))%")
                                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(color)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(color.opacity(0.12), in: Capsule())
                            }
                        }
                        .frame(width: 58, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Language Word Volume

    private var languageWordChart: some View {
        let maxWords = languageWordBreakdown.map(\.words).max() ?? 1
        return chartCard(
            title: "Words by language",
            subtitle: "Total words dictated · with avg WPM",
            icon: "character.book.closed.fill"
        ) {
            VStack(spacing: 8) {
                ForEach(languageWordBreakdown, id: \.code) { item in
                    let fraction = maxWords > 0 ? Double(item.words) / Double(maxWords) : 0
                    HStack(spacing: 10) {
                        Text(Locale.current.localizedString(forLanguageCode: item.code) ?? item.code)
                            .font(.subheadline)
                            .frame(width: 90, alignment: .leading)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)

                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(
                                    LinearGradient(
                                        colors: [Color(red: 0.22, green: 0.49, blue: 0.98),
                                                 Color(red: 0.55, green: 0.35, blue: 0.95)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .opacity(0.2 + fraction * 0.8)
                                .frame(width: geo.size.width * max(0.03, fraction))
                        }
                        .frame(height: 18)

                        HStack(spacing: 4) {
                            Text(item.words >= 1000
                                 ? String(format: "%.1fk", Double(item.words) / 1000)
                                 : "\(item.words)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            if item.avgWPM > 0 {
                                Text("\(Int(item.avgWPM)) wpm")
                                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(.blue.opacity(0.8))
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Color.blue.opacity(0.10), in: Capsule())
                            }
                        }
                        .frame(width: 72, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Filler Words

    private var fillerWordsChart: some View {
        chartCard(title: "Filler words", subtitle: "All-time frequency", icon: "ellipsis.bubble") {
            Chart(fillerFrequency, id: \.word) { item in
                BarMark(
                    x: .value("Count", item.count),
                    y: .value("Word", item.word)
                )
                .foregroundStyle(Color.purple.gradient)
                .cornerRadius(4)
                .annotation(position: .trailing) {
                    Text("\(item.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks { AxisValueLabel() }
            }
            .frame(height: CGFloat(fillerFrequency.count * 36))
        }
    }

    // MARK: - Streak Card

    // MARK: - Activity Calendar Heatmap

    private struct ActivityDay: Identifiable {
        let id: Date
        let date: Date
        let count: Int
    }

    /// Last 15 weeks of recording activity, organised into week columns.
    private var activityWeeks: [[ActivityDay]] {
        let cal  = Calendar.current
        let today = cal.startOfDay(for: Date())
        // Pad so the grid starts on a Sunday (or whatever first weekday the locale uses)
        let weekday = cal.component(.weekday, from: today)   // 1 = Sun … 7 = Sat
        let daysBack = (15 * 7 - 1) + (weekday - cal.firstWeekday + 7) % 7

        let days: [ActivityDay] = (0...daysBack).reversed().compactMap { offset in
            guard let date = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let count = sessions.filter { cal.isDate($0.startedAt, inSameDayAs: date) }.count
            return ActivityDay(id: date, date: date, count: count)
        }
        // Split into chunks of 7 (week columns)
        return stride(from: 0, to: days.count, by: 7).map { i in
            Array(days[i..<min(i + 7, days.count)])
        }
    }

    private var activityCalendar: some View {
        let weeks = activityWeeks
        let maxCount = weeks.flatMap { $0 }.map { $0.count }.max() ?? 1

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "calendar.badge.checkmark")
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording activity").font(.headline)
                    Text("Last 15 weeks").font(.caption).foregroundStyle(.secondary)
                }
            }

            // Month header — show month name at the start of each new month column
            let monthLabels = buildMonthLabels(weeks: weeks)
            HStack(spacing: 0) {
                // Offset for the day-label column
                Spacer().frame(width: 24)
                ForEach(0..<weeks.count, id: \.self) { wi in
                    Text(monthLabels[wi] ?? "")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // Grid
            HStack(alignment: .top, spacing: 3) {
                // Day-of-week labels (Mon, Wed, Fri only to save space)
                VStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { d in
                        let label: String = {
                            switch d { case 1: return "M"; case 3: return "W"; case 5: return "F"; default: return "" }
                        }()
                        Text(label)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 12, height: 11)
                    }
                }

                // Week columns
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(weeks.indices, id: \.self) { wi in
                            VStack(spacing: 3) {
                                ForEach(weeks[wi]) { day in
                                    let intensity = day.count == 0
                                        ? 0.0
                                        : 0.25 + 0.75 * (Double(day.count) / Double(max(maxCount, 1)))
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(day.count > 0
                                              ? Color.accentColor.opacity(intensity)
                                              : Color(.systemGray4))
                                        .frame(width: 11, height: 11)
                                        .accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted)): \(day.count) session\(day.count == 1 ? "" : "s")")
                                        .onTapGesture {
                                            guard day.count > 0 else { return }
                                            tappedDay = day.date
                                            showDayPopover = true
                                        }
                                        .popover(isPresented: Binding(
                                            get: { showDayPopover && tappedDay == day.date },
                                            set: { if !$0 { showDayPopover = false } }
                                        )) {
                                            dayPopoverContent(for: day.date, count: day.count)
                                        }
                                }
                            }
                        }
                    }
                }
            }

            // Legend
            HStack(spacing: 6) {
                Text("Less")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                ForEach([0, 0.3, 0.55, 0.8, 1.0], id: \.self) { v in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(v > 0 ? Color.accentColor.opacity(v) : Color(.systemGray4))
                        .frame(width: 11, height: 11)
                }
                Text("More")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 14))
    }

    /// Returns a dictionary mapping week-column index → month abbreviation,
    /// only at the first column of a new month.
    private func buildMonthLabels(weeks: [[ActivityDay]]) -> [Int: String] {
        var result: [Int: String] = [:]
        var lastMonth = -1
        for (wi, week) in weeks.enumerated() {
            guard let first = week.first else { continue }
            let month = Calendar.current.component(.month, from: first.date)
            if month != lastMonth {
                result[wi] = first.date.formatted(.dateTime.month(.abbreviated))
                lastMonth = month
            }
        }
        return result
    }

    // MARK: - Streak Card

    private var recordingStreakCard: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.yellow.opacity(0.15))
                    .frame(width: 56, height: 56)
                Image(systemName: "flame.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Recording streak")
                    .font(.subheadline.weight(.semibold))
                Text(currentStreak == 0
                     ? "Record today to start a streak!"
                     : "\(currentStreak) day\(currentStreak == 1 ? "" : "s") in a row")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(currentStreak)")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(currentStreak > 0 ? .orange : .secondary)
        }
        .padding(16)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Top Words Cloud

    private var topWordsCloud: some View {
        let words = topWords
        let maxCount = Double(words.first?.count ?? 1)
        return chartCard(title: "Most spoken words", subtitle: "Tap a word to find sessions", icon: "text.bubble.fill") {
            FlowLayout(spacing: 8) {
                ForEach(words, id: \.word) { item in
                    let scale = 0.5 + 0.5 * (Double(item.count) / maxCount)
                    Button {
                        NotificationCenter.default.post(
                            name: .lexoraSearchHistory,
                            object: nil,
                            userInfo: ["query": item.word]
                        )
                    } label: {
                        Text(item.word)
                            .font(.system(size: 13 + 6 * scale, weight: scale > 0.7 ? .semibold : .regular))
                            .foregroundStyle(Color.accentColor.opacity(0.5 + 0.5 * scale))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.accentColor.opacity(0.07 + 0.1 * scale), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Search sessions for \"\(item.word)\"")
                }
            }
        }
    }

    // MARK: - Tags Breakdown

    @ViewBuilder
    private var tagsChart: some View {
        let tags = tagBreakdown
        if !tags.isEmpty {
            chartCard(title: "Tag breakdown", subtitle: "Sessions per tag this period", icon: "tag.fill") {
                VStack(spacing: 0) {
                    Chart(tags) { tag in
                        BarMark(
                            x: .value("Sessions", tag.count),
                            y: .value("Tag", tag.id)
                        )
                        .foregroundStyle(Color.accentColor.gradient)
                        .cornerRadius(4)
                        .annotation(position: .trailing, alignment: .leading) {
                            Text("\(tag.count)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks { v in
                            if let label = v.as(String.self) {
                                AxisValueLabel {
                                    Text(label)
                                        .font(.system(size: 11))
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    .frame(height: CGFloat(tags.count) * 32 + 16)

                    // Avg words per tag footnote
                    let topTag = tags.first
                    if let top = topTag {
                        Divider().padding(.top, 8)
                        HStack {
                            Image(systemName: "text.word.spacing")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("\"\(top.id)\" sessions avg \(top.avgWords) words")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.top, 8)
                    }
                }
            }
        }
    }

    // MARK: - Template Performance

    private struct TemplateStat: Identifiable {
        var id: String { tag }
        let tag: String
        let count: Int
        let avgWords: Int
        let avgConfidence: Double
    }

    private var templatePerformanceData: [TemplateStat] {
        let knownTemplates: Set<String> = ["Meeting", "Journal", "Quick note", "Interview", "Lecture", "Draft"]
        var byTag: [String: [TranscriptionSession]] = [:]
        for session in scopedSessions {
            let templateTag = session.tags.first(where: { knownTemplates.contains($0) })
            guard let tag = templateTag else { continue }
            byTag[tag, default: []].append(session)
        }
        return byTag
            .filter { $0.value.count >= 2 }
            .map { tag, sessions in
                let avgWords = sessions.reduce(0) { $0 + $1.wordCount } / sessions.count
                let avgConf = sessions.isEmpty ? 0.0 : sessions.reduce(0.0) { $0 + $1.confidenceAverage } / Double(sessions.count)
                return TemplateStat(tag: tag, count: sessions.count, avgWords: avgWords, avgConfidence: avgConf)
            }
            .sorted { $0.avgWords > $1.avgWords }
    }

    @ViewBuilder
    private var templatePerformanceChart: some View {
        let data = templatePerformanceData
        chartCard(title: "Template performance", subtitle: "Average words by template type", icon: "doc.badge.gearshape") {
            Chart(data) { stat in
                BarMark(
                    x: .value("Template", stat.tag),
                    y: .value("Avg words", stat.avgWords)
                )
                .foregroundStyle(Color.purple.gradient)
                .cornerRadius(6)
                .annotation(position: .top) {
                    Text("\(stat.avgWords)w")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .chartXAxis {
                AxisMarks { v in
                    if let label = v.as(String.self) {
                        AxisValueLabel {
                            Text(label).font(.system(size: 10)).lineLimit(1)
                        }
                    }
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 120)

            // Confidence footnote for each template
            HStack(spacing: 12) {
                ForEach(data.prefix(4)) { stat in
                    HStack(spacing: 3) {
                        Text(stat.tag)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text("\(Int(stat.avgConfidence * 100))%")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(stat.avgConfidence > 0.8 ? Color.green : Color.orange)
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    // MARK: - Session Duration Histogram

    private struct DurationBucket: Identifiable {
        let id: String
        let label: String
        let count: Int
        let color: Color
    }

    private var durationBuckets: [DurationBucket] {
        let src = scopedSessions
        func n(_ pred: (Double) -> Bool) -> Int { src.filter { pred($0.durationSeconds) }.count }
        return [
            DurationBucket(id: "u1m",  label: "<1m",    count: n { $0 < 60 },                  color: .teal),
            DurationBucket(id: "1m",   label: "1-3m",   count: n { $0 >= 60  && $0 < 180 },    color: .blue),
            DurationBucket(id: "3m",   label: "3-5m",   count: n { $0 >= 180 && $0 < 300 },    color: .indigo),
            DurationBucket(id: "5m",   label: "5-10m",  count: n { $0 >= 300 && $0 < 600 },    color: .purple),
            DurationBucket(id: "10m",  label: "10-20m", count: n { $0 >= 600 && $0 < 1200 },   color: .pink),
            DurationBucket(id: "20mp", label: ">20m",   count: n { $0 >= 1200 },               color: .red),
        ]
    }

    @ViewBuilder
    private var durationHistogramChart: some View {
        if !scopedSessions.isEmpty {
            let buckets = durationBuckets
            let avgSecs = scopedSessions.reduce(0.0) { $0 + $1.durationSeconds }
                / Double(scopedSessions.count)
            let longestSecs = scopedSessions.map { $0.durationSeconds }.max() ?? 0

            chartCard(
                title: "Session lengths",
                subtitle: "Distribution of recording durations",
                icon: "timer"
            ) {
                Chart(buckets) { bucket in
                    BarMark(
                        x: .value("Range", bucket.label),
                        y: .value("Sessions", bucket.count)
                    )
                    .foregroundStyle(bucket.color.opacity(0.8).gradient)
                    .cornerRadius(5)
                    .annotation(position: .top) {
                        if bucket.count > 0 {
                            Text("\(bucket.count)")
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let s = value.as(String.self) {
                                Text(s).font(.caption2)
                            }
                        }
                    }
                }
                .chartYAxis(.hidden)
                .frame(height: 130)

                Divider()
                    .padding(.top, 4)

                HStack(spacing: 0) {
                    VStack(spacing: 3) {
                        let m = Int(avgSecs / 60)
                        let s = Int(avgSecs.truncatingRemainder(dividingBy: 60))
                        Text(m > 0 ? "\(m)m \(s)s" : "\(s)s")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                        Text("avg length")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)

                    Divider().frame(height: 32)

                    VStack(spacing: 3) {
                        let lm = Int(longestSecs / 60)
                        let ls = Int(longestSecs.truncatingRemainder(dividingBy: 60))
                        Text(lm > 0 ? "\(lm)m \(ls)s" : "\(ls)s")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                        Text("longest")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)

                    Divider().frame(height: 32)

                    VStack(spacing: 3) {
                        let totalSecs = scopedSessions.reduce(0.0) { $0 + $1.durationSeconds }
                        let tm = Int(totalSecs / 60)
                        Text("\(tm)m")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                        Text("total")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.top, 8)
            }
        }
    }

    // MARK: - Chart Card Helper

    // MARK: - JSON Export

    private func exportAnalyticsJSON() {
        let isoDF = ISO8601DateFormatter()
        let periodLabel = period.rawValue.lowercased()

        // Aggregate the same stats as shown in the summary cards
        let stats: [String: Any] = [
            "exportedAt": isoDF.string(from: Date()),
            "period": periodLabel,
            "sessions": scopedSessions.count,
            "totalWords": totalWords,
            "totalMinutes": Int(totalMinutes),
            "avgWPM": Int(avgWPM),
            "avgConfidencePct": Int(avgConfidence * 100),
            "currentStreakDays": currentStreak,
            "longestStreakDays": longestStreakEver,
            "fillerWords": fillerFrequency.map { ["word": $0.word, "count": $0.count] },
            "topWords": topWords.map { ["word": $0.word, "count": $0.count] },
            "languageBreakdown": languageBreakdown.map { ["code": $0.code, "sessions": $0.count] },
            "dayOfWeekAvgWords": dayOfWeekBuckets.map { ["day": $0.label, "avgWords": Int($0.avgWords)] },
            "timeOfDay": timeOfDayBuckets.map { ["period": $0.label.replacingOccurrences(of: "\n", with: " "), "sessions": $0.count] },
            "tagBreakdown": tagBreakdown.map { ["tag": $0.id, "sessions": $0.count, "avgWords": $0.avgWords] }
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: stats, options: .prettyPrinted),
              let json = String(data: data, encoding: .utf8) else { return }

        let stamp = Date().formatted(.dateTime.year().month().day())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lexora_analytics_\(periodLabel)_\(stamp).json")
        try? json.write(to: url, atomically: true, encoding: .utf8)
        exportItems = [url]
        showExportSheet = true
    }

    // MARK: - Chart Card Helper

    private func chartCard<Content: View>(
        title: String,
        subtitle: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(16)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Heatmap Day Popover

    @ViewBuilder
    private func dayPopoverContent(for date: Date, count: Int) -> some View {
        let cal = Calendar.current
        let daySessions = sessions.filter { cal.isDate($0.startedAt, inSameDayAs: date) }
            .sorted { $0.startedAt > $1.startedAt }

        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .foregroundStyle(Color.accentColor)
                    .font(.subheadline)
                VStack(alignment: .leading, spacing: 1) {
                    Text(date.formatted(date: .complete, time: .omitted))
                        .font(.subheadline.weight(.semibold))
                    Text("\(count) session\(count == 1 ? "" : "s") · \(daySessions.reduce(0) { $0 + $1.wordCount }) words")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            // Session list
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(daySessions) { s in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(s.customTitle
                                     ?? (s.finalTranscript.isEmpty ? "Empty" : String(s.finalTranscript.prefix(35))))
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Spacer()
                                Text(s.startedAt, style: .time)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 6) {
                                Text("\(s.wordCount)w")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                if s.durationSeconds > 0 {
                                    let m = Int(s.durationSeconds / 60)
                                    let sec = Int(s.durationSeconds) % 60
                                    Text(m > 0 ? "\(m)m \(sec)s" : "\(sec)s")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if s.isStarred {
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.yellow)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        if s.id != daySessions.last?.id { Divider().padding(.leading, 16) }
                    }
                }
            }
            .frame(maxHeight: 200)
        }
        .frame(minWidth: 260)
        .presentationCompactAdaptation(.popover)
    }
}

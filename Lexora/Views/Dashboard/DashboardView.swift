import SwiftUI
import Charts
import StoreKit

struct DashboardView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.requestReview) private var requestReview
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingRecorder = false
    @State private var showingAnalytics = false
    @State private var selectedSession: TranscriptionSession? = nil
    @State private var showingQuickNote = false
    /// Language pre-selected for the next recording (nil = auto-detect).
    @State private var quickRecordLanguage: String? = nil
    /// Controls the goal-celebration banner (auto-dismisses after 4 s).
    @State private var showGoalCelebration = false
    /// Tracks whether the goal was already celebrated this calendar day.
    @AppStorage("goalCelebratedDate") private var goalCelebratedDateStr: String = ""
    /// ISO-8601 date string when the app was first launched (used for review prompt timing).
    @AppStorage("firstLaunchDate") private var firstLaunchDateStr: String = ""
    /// Whether we've already requested a review in this version cycle.
    @AppStorage("reviewRequestedVersion") private var reviewRequestedVersion: String = ""
    /// ISO week string (e.g. "2026-W20") of the last dismissed weekly digest.
    @AppStorage("weeklyDigestDismissedWeek") private var digestDismissedWeek: String = ""
    /// ISO date string when the vocab insight card was last dismissed.
    @AppStorage("vocabInsightDismissedDate") private var vocabInsightDismissedDate: String = ""
    /// The word surfaced today as vocab insight (persisted so it doesn't re-roll during the session).
    @AppStorage("vocabInsightWord") private var vocabInsightWordStored: String = ""

    private var profile: UserVoiceProfile { appState.profile }

    var body: some View {
        NavigationStack {
            ScrollView {
                if horizontalSizeClass == .regular {
                    // iPad: two-column layout
                    HStack(alignment: .top, spacing: 20) {
                        // Left column — identity, goal, daily stats
                        VStack(spacing: 20) {
                            greetingHeader
                            if appState.sessions.isEmpty {
                                firstTimeBanner
                            } else {
                                streakAtRiskBanner
                                archiveSuggestionBanner
                                weeklyDigestCard
                                goalProgressHero
                                if !todaySessions.isEmpty { todayAtAGlance }
                                quickLanguagesBar
                                smartSuggestionCard
                                if shouldShowVocabInsight { vocabInsightCard }
                                voiceProfileCard
                                achievementBadgesRow
                            }
                        }
                        .frame(maxWidth: .infinity)

                        // Right column — charts and history
                        VStack(spacing: 20) {
                            if !appState.sessions.isEmpty {
                                statsGrid
                                weeklySummaryCard
                                activityHeatmapCard
                                wordCountChart
                                accuracyChart
                            }
                            recentSessions
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                } else {
                    // iPhone: single-column layout
                    VStack(spacing: 20) {
                        greetingHeader
                        trialCountdownBanner
                        if appState.sessions.isEmpty {
                            firstTimeBanner
                        } else {
                            streakAtRiskBanner
                            archiveSuggestionBanner
                            weeklyDigestCard
                            goalProgressHero
                            if !todaySessions.isEmpty { todayAtAGlance }
                            quickLanguagesBar
                            smartSuggestionCard
                            if shouldShowVocabInsight { vocabInsightCard }
                            voiceProfileCard
                            achievementBadgesRow
                            statsGrid
                            weeklySummaryCard
                            activityHeatmapCard
                            wordCountChart
                            accuracyChart
                            if !pinnedSessions.isEmpty { pinnedSessionsCarousel }
                        }
                        recentSessions
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Lexora")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 4) {
                        Button {
                            showingQuickNote = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .help("Type a quick note")
                        Button {
                            showingAnalytics = true
                        } label: {
                            Image(systemName: "chart.bar.xaxis")
                        }
                        syncButton
                    }
                }
            }
        }
        .sheet(isPresented: $showingRecorder, onDismiss: { quickRecordLanguage = nil }) {
            RecordingView(initialLanguage: quickRecordLanguage)
                .environment(appState)
        }
        .sheet(isPresented: $showingAnalytics) {
            AnalyticsView()
                .environment(appState)
        }
        .sheet(isPresented: $showingQuickNote) {
            QuickNoteView()
                .environment(appState)
        }
        .sheet(item: $selectedSession) { session in
            SessionSwipeBrowserView(
                sessions: appState.sessions,
                initialID: session.id
            )
                .environment(appState)
        }
        .overlay(alignment: .top) {
            if showGoalCelebration {
                goalCelebrationBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100)
            }
        }
        .onChange(of: appState.sessions.count) { _, _ in
            maybeRequestReview()
        }
        .onChange(of: todayWordCount) { _, newCount in
            let goal = profile.dailyWordGoal
            guard goal > 0, newCount >= goal else { return }
            let todayStr = Calendar.current.startOfDay(for: Date()).formatted(.iso8601)
            guard goalCelebratedDateStr != todayStr else { return }
            goalCelebratedDateStr = todayStr
            HapticManager.wordMilestone()
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                showGoalCelebration = true
            }
            Task {
                try? await Task.sleep(for: .seconds(4))
                withAnimation(.easeOut(duration: 0.4)) { showGoalCelebration = false }
            }
        }
    }

    // MARK: - Recording entry point

    /// Routes all "start recording" taps. Recording works on both iPhone and Mac;
    /// the macOS 26 executor crash is mitigated by the legacy-executor override
    /// set in the "Lexora Mac" scheme (SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE).
    private func macSafeRecord() {
        showingRecorder = true
    }

    // MARK: - Review Prompt

    /// Requests an App Store review when the user has:
    /// - recorded ≥ 10 sessions
    /// - used the app for ≥ 7 days since first launch
    /// - not yet been shown the prompt in this app version
    private func maybeRequestReview() {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        guard reviewRequestedVersion != currentVersion else { return }
        guard appState.sessions.count >= 10 else { return }

        // Record first launch date if not already set
        if firstLaunchDateStr.isEmpty {
            firstLaunchDateStr = Date().formatted(.iso8601)
            return
        }
        guard let firstLaunch = try? Date(firstLaunchDateStr, strategy: .iso8601) else { return }
        let daysSinceFirstLaunch = Calendar.current.dateComponents([.day], from: firstLaunch, to: Date()).day ?? 0
        guard daysSinceFirstLaunch >= 7 else { return }

        reviewRequestedVersion = currentVersion
        requestReview()
    }

    // MARK: - Achievements

    private struct Achievement: Identifiable {
        var id: String { label }
        var label: String
        var icon: String
        var tint: Color
        var unlocked: Bool
    }

    private var achievements: [Achievement] {
        let sessions = appState.sessions.count
        let words    = totalLifetimeWords
        let vocab    = appState.profile.customVocabulary.count
        let streak   = currentStreakLength
        return [
            Achievement(label: "First steps",   icon: "figure.walk",              tint: .green,  unlocked: sessions >= 1),
            Achievement(label: "10 sessions",   icon: "10.circle.fill",           tint: .blue,   unlocked: sessions >= 10),
            Achievement(label: "50 sessions",   icon: "50.circle.fill",           tint: .indigo, unlocked: sessions >= 50),
            Achievement(label: "100 sessions",  icon: "100.circle.fill",          tint: .purple, unlocked: sessions >= 100),
            Achievement(label: "1 K words",     icon: "1.k.circle.fill",          tint: .orange, unlocked: words >= 1_000),
            Achievement(label: "10 K words",    icon: "10.k.circle.fill",         tint: .red,    unlocked: words >= 10_000),
            Achievement(label: "Wordsmith",     icon: "book.closed.fill",         tint: .teal,   unlocked: words >= 50_000),
            Achievement(label: "7-day streak",  icon: "flame.fill",               tint: .orange, unlocked: streak >= 7),
            Achievement(label: "30-day streak", icon: "flame.circle.fill",        tint: .red,    unlocked: streak >= 30),
            Achievement(label: "Vocab 10+",     icon: "character.book.closed",    tint: .cyan,   unlocked: vocab >= 10),
            Achievement(label: "Vocab 50+",     icon: "book.fill",                tint: .mint,   unlocked: vocab >= 50),
        ].filter { $0.unlocked }
    }

    @ViewBuilder
    private var achievementBadgesRow: some View {
        let earned = achievements
        if !earned.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Achievements", systemImage: "rosette")
                    .font(.headline)
                    .padding(.horizontal, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(earned) { badge in
                            VStack(spacing: 6) {
                                Image(systemName: badge.icon)
                                    .font(.title3)
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(badge.tint.gradient, in: Circle())
                                Text(badge.label)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .frame(width: 54)
                            }
                            .accessibilityLabel("Achievement: \(badge.label)")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Header

    private var totalLifetimeWords: Int { appState.sessions.reduce(0) { $0 + $1.wordCount } }

    private var greetingHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(profile.displayName)
                    .font(.title2.bold())
                if totalLifetimeWords > 0 {
                    Text("\(totalLifetimeWords.formatted()) words spoken")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
                }
            }
            Spacer()
            Button {
                macSafeRecord()
            } label: {
                Label("Record", systemImage: "mic.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.top, 8)
    }

    // MARK: - First-time Welcome Banner

    /// Rich empty-state card shown on the first launch before any sessions exist.
    /// Highlights the app's core value props and provides a prominent CTA.
    @ViewBuilder
    private var firstTimeBanner: some View {
        VStack(spacing: 24) {
            // Hero icon
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.18), Color.accentColor.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)

                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            // Headlines
            VStack(spacing: 6) {
                Text("Welcome to Lexora")
                    .font(.title2.bold())
                Text("Voice dictation that learns how you speak.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Feature highlights grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                featureHighlight(
                    icon: "brain.head.profile",
                    color: .purple,
                    title: "Learns your voice",
                    subtitle: "Gets smarter with every session"
                )
                featureHighlight(
                    icon: "chart.bar.fill",
                    color: .blue,
                    title: "Track progress",
                    subtitle: "Words, pace and accuracy trends"
                )
                featureHighlight(
                    icon: "book.closed.fill",
                    color: .orange,
                    title: "Custom vocabulary",
                    subtitle: "Teach it names & terminology"
                )
                featureHighlight(
                    icon: "mic.fill",
                    color: .red,
                    title: "Siri shortcuts",
                    subtitle: "Record with just your voice"
                )
            }

            // Primary CTA
            Button {
                macSafeRecord()
            } label: {
                Label("Start your first recording", systemImage: "mic.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)

            // Secondary: quick note
            Button {
                showingQuickNote = true
            } label: {
                Label("Or type a quick note instead", systemImage: "square.and.pencil")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Color.accentColor.opacity(0.15), lineWidth: 1)
        )
    }

    private func featureHighlight(icon: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Goal Progress Hero Ring

    /// Prominent circular progress ring toward the daily word goal.
    /// Shown whenever the user has set a non-zero daily word goal.
    @ViewBuilder
    private var goalProgressHero: some View {
        let goal = profile.dailyWordGoal
        if goal > 0 {
            let words    = todayWordCount
            let progress = min(1.0, Double(words) / Double(goal))
            let completed = words >= goal
            let wordsLeft = max(0, goal - words)

            VStack(spacing: 16) {
                // ── Large ring ──────────────────────────────────────────────
                ZStack {
                    // Track
                    Circle()
                        .stroke(
                            completed
                                ? Color.green.opacity(0.15)
                                : Color.accentColor.opacity(0.12),
                            style: StrokeStyle(lineWidth: 14, lineCap: .round)
                        )
                        .frame(width: 130, height: 130)

                    // Fill arc
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            LinearGradient(
                                colors: completed
                                    ? [.green, .mint]
                                    : [Color.accentColor, Color.accentColor.opacity(0.6)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 14, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: 130, height: 130)
                        .animation(.spring(response: 0.8, dampingFraction: 0.75), value: progress)

                    // Center label
                    VStack(spacing: 3) {
                        if completed {
                            Image(systemName: "checkmark")
                                .font(.system(size: 30, weight: .bold))
                                .foregroundStyle(.green)
                        } else {
                            Text("\(words)")
                                .font(.system(.title2, design: .rounded).bold())
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                            Text("/ \(goal)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(completed
                    ? "Daily goal achieved: \(words) words"
                    : "Daily goal progress: \(words) of \(goal) words")
                .accessibilityValue("\(Int(progress * 100)) percent")

                // ── Caption ─────────────────────────────────────────────────
                VStack(spacing: 8) {
                    if completed {
                        Label("Daily goal achieved! 🎉", systemImage: "star.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.green)
                    } else {
                        Text(wordsLeft == 1
                             ? "1 more word to reach your goal"
                             : "\(wordsLeft) words to reach your goal")
                            .font(.subheadline.weight(.medium))

                        Button {
                            macSafeRecord()
                        } label: {
                            Label("Record now", systemImage: "mic.fill")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }

                    Text("\(Int(progress * 100))% of \(goal)-word daily goal")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(
                        completed ? Color.green.opacity(0.3) : Color.accentColor.opacity(0.15),
                        lineWidth: 1
                    )
            )
        }
    }

    // MARK: - Quick Languages bar

    /// Shows the top-3 most-recently-used languages as one-tap record shortcuts.
    /// Hidden when the user only ever speaks one language (or has no sessions yet).
    @ViewBuilder
    private var quickLanguagesBar: some View {
        // Collect ordered-unique languages from recent sessions
        var seen = Set<String>()
        let langs: [String] = appState.sessions.prefix(50).compactMap { session in
            let lang = session.primaryLanguage
            guard !seen.contains(lang) else { return nil }
            seen.insert(lang)
            return lang
        }
        let topLangs = Array(langs.prefix(4))   // at most 4 chips to avoid crowding

        if topLangs.count >= 2 {               // only show when there's genuine variety
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // "Auto" chip — always first
                    quickLangChip(code: nil, label: "Auto-detect", icon: "globe")

                    ForEach(topLangs, id: \.self) { code in
                        let name = Locale.current
                            .localizedString(forLanguageCode: code) ?? code
                        quickLangChip(code: code, label: name, icon: "mic.fill")
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }
        }
    }

    private func quickLangChip(code: String?, label: String, icon: String) -> some View {
        Button {
            quickRecordLanguage = code
            macSafeRecord()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption2)
                Text(label).font(.caption.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(.secondarySystemGroupedBackground), in: Capsule())
            .foregroundStyle(Color.accentColor)
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Smart Suggestion Card

    @ViewBuilder
    private var smartSuggestionCard: some View {
        let suggestion = buildSuggestion()
        if let s = suggestion {
            Button {
                s.action()
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: s.icon)
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(s.color, in: RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(s.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
        }
    }

    private struct Suggestion {
        let icon: String
        let color: Color
        let title: String
        let subtitle: String
        let action: () -> Void
    }

    private func buildSuggestion() -> Suggestion? {
        let hour = Calendar.current.component(.hour, from: Date())
        let lastSession = appState.sessions.first

        // 1. Haven't recorded today — nudge to record
        if todaySessions.isEmpty {
            if let last = lastSession {
                let daysSince = Calendar.current.dateComponents([.day], from: last.startedAt, to: Date()).day ?? 0
                if daysSince >= 2 {
                    return Suggestion(
                        icon: "mic.fill",
                        color: .red,
                        title: "Time to record!",
                        subtitle: "You last recorded \(daysSince) days ago. Keep your streak going.",
                        action: { macSafeRecord() }
                    )
                }
            }
            if hour >= 6 && hour < 22 {
                return Suggestion(
                    icon: "mic.fill",
                    color: .accentColor,
                    title: "Start your first session today",
                    subtitle: "Tap to begin recording.",
                    action: { macSafeRecord() }
                )
            }
        }

        // 2. Goal reached today — celebrate
        if profile.dailyWordGoal > 0 && todayWordCount >= profile.dailyWordGoal {
            return Suggestion(
                icon: "star.fill",
                color: .yellow,
                title: "Goal achieved! 🎉",
                subtitle: "\(todayWordCount) words today — you hit your \(profile.dailyWordGoal)-word goal.",
                action: { showingAnalytics = true }
            )
        }

        // 2.5. Nearing daily goal — show projection with nudge to record
        if profile.dailyWordGoal > 0,
           !todaySessions.isEmpty,
           todayWordCount < profile.dailyWordGoal {
            let wordsLeft = profile.dailyWordGoal - todayWordCount
            let pct = Int(Double(todayWordCount) / Double(profile.dailyWordGoal) * 100)
            let avgWordsPerSession = max(1, todayWordCount / todaySessions.count)
            let sessionsNeeded = max(1, Int(ceil(Double(wordsLeft) / Double(avgWordsPerSession))))
            if pct >= 40 {
                return Suggestion(
                    icon: "chart.line.uptrend.xyaxis",
                    color: .green,
                    title: "\(pct)% of your daily goal",
                    subtitle: "\(wordsLeft) more words — about \(sessionsNeeded == 1 ? "one more session" : "\(sessionsNeeded) more sessions") at your current pace.",
                    action: { macSafeRecord() }
                )
            }
        }

        // 3. Vocabulary is empty — suggest adding words
        if appState.profile.customVocabulary.isEmpty && !appState.sessions.isEmpty {
            return Suggestion(
                icon: "book.closed.fill",
                color: .purple,
                title: "Add specialist vocabulary",
                subtitle: "Help Lexora recognise names and technical terms.",
                action: {
                    NotificationCenter.default.post(name: .lexoraOpenProfile, object: nil)
                }
            )
        }

        // 4. Many uncorrected sessions — suggest reviewing
        let uncorrected = appState.sessions.filter { $0.estimatedAccuracy < 80 && !$0.finalTranscript.isEmpty }
        if uncorrected.count >= 3 {
            return Suggestion(
                icon: "pencil.line",
                color: .orange,
                title: "Review & correct transcripts",
                subtitle: "\(uncorrected.count) sessions have accuracy below 80%. Editing teaches Lexora.",
                action: {
                    NotificationCenter.default.post(name: .lexoraOpenHistory, object: nil)
                }
            )
        }

        // 5. Last session was short and recent — suggest continuing it
        if let last = lastSession, !last.finalTranscript.isEmpty {
            let minutesAgo = Calendar.current.dateComponents([.minute], from: last.startedAt, to: Date()).minute ?? 999
            if minutesAgo < 90 && last.wordCount < 80 {
                return Suggestion(
                    icon: "arrow.counterclockwise.circle.fill",
                    color: .teal,
                    title: "Continue your last session",
                    subtitle: "You recorded \(last.wordCount) words \(minutesAgo)m ago. Keep going?",
                    action: { macSafeRecord() }
                )
            }
        }

        // 6. Peak recording hour approaching — nudge to record before the window passes
        if todaySessions.isEmpty, let peak = peakRecordingHour,
           appState.sessions.count >= 5 {
            // Check if we're within ±1 hour of the peak
            if let comps = Calendar.current.date(from: {
                var c = DateComponents()
                // Parse the formatted "9 AM" / "3 PM" string back to hour
                let df = DateFormatter(); df.dateFormat = "h a"
                if let d = df.date(from: peak) {
                    c.hour = Calendar.current.component(.hour, from: d)
                }
                return c
            }()).map({ Calendar.current.component(.hour, from: $0) }) {
                if abs(hour - comps) <= 1 {
                    return Suggestion(
                        icon: "clock.badge.checkmark.fill",
                        color: .indigo,
                        title: "Your best time to record is now",
                        subtitle: "You typically record around \(peak). Tap to start a session.",
                        action: { macSafeRecord() }
                    )
                }
            }
        }

        // 7. Best session this week — celebrate a personal record
        let cal = Calendar.current
        if let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())) {
            let weekSessions = appState.sessions.filter { $0.startedAt >= weekStart }
            if let best = weekSessions.max(by: { $0.wordCount < $1.wordCount }),
               let last = appState.sessions.first,
               best.id == last.id,
               best.wordCount > 0,
               weekSessions.count >= 3 {
                return Suggestion(
                    icon: "trophy.fill",
                    color: .yellow,
                    title: "Your best session this week!",
                    subtitle: "\(best.wordCount) words — a new weekly high. Great momentum.",
                    action: { selectedSession = best }
                )
            }
        }

        return nil
    }

    // MARK: - Voice Profile Card

    private var voiceProfileCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Your Voice Profile", systemImage: "person.wave.2.fill")
                .font(.headline)

            HStack(spacing: 12) {
                profilePill(
                    icon: "globe",
                    label: languageName(profile.detectedPrimaryLanguage),
                    subtitle: "Primary language",
                    color: .blue
                )
                profilePill(
                    icon: "speedometer",
                    label: "\(Int(profile.averageSpeakingPaceWPM)) wpm",
                    subtitle: "Speaking pace",
                    color: .green
                )
            }

            HStack(spacing: 12) {
                profilePill(
                    icon: "text.bubble.fill",
                    label: formalityLabel,
                    subtitle: "Typical formality",
                    color: .orange
                )
                profilePill(
                    icon: "book.closed.fill",
                    label: "\(profile.customVocabulary.count) words",
                    subtitle: "Learned vocabulary",
                    color: .purple
                )
            }

            if let accent = profile.accentRegion {
                HStack(spacing: 8) {
                    Image(systemName: "map.fill")
                        .foregroundStyle(.teal)
                        .font(.caption)
                    Text("Accent detected: **\(accent)**")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if !profile.detectedSecondaryLanguages.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Code-switching detected:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        ForEach(profile.detectedSecondaryLanguages.prefix(4), id: \.self) { lang in
                            Text(languageName(lang))
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            // Peak recording hour insight (shown once enough history exists)
            if let peak = peakRecordingHour, profile.totalSessionCount >= 5 {
                HStack(spacing: 8) {
                    Image(systemName: "clock.badge.checkmark.fill")
                        .foregroundStyle(.indigo)
                        .font(.caption)
                    Text("Peak recording time: **\(peak)**")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    /// The hour-of-day label when the user most frequently starts recordings.
    private var peakRecordingHour: String? {
        guard !appState.sessions.isEmpty else { return nil }
        let cal = Calendar.current
        var hourCounts = [Int: Int]()
        for session in appState.sessions {
            let hour = cal.component(.hour, from: session.startedAt)
            hourCounts[hour, default: 0] += 1
        }
        guard let peakHour = hourCounts.max(by: { $0.value < $1.value })?.key else { return nil }
        var comps = DateComponents()
        comps.hour = peakHour
        comps.minute = 0
        guard let date = cal.date(from: comps) else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "h a"
        return fmt.string(from: date)
    }

    // MARK: - Stats Grid

    private var statsGrid: some View {
        let deltas = weekOverWeekDeltas
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            statCard(
                value: formatMinutes(profile.totalTranscriptionMinutes),
                label: "Recorded",
                icon: "mic.circle.fill",
                color: .red,
                delta: deltas.minutes
            )
            statCard(
                value: "\(profile.totalSessionCount)",
                label: "Sessions",
                icon: "waveform.circle.fill",
                color: .blue,
                delta: deltas.sessions
            )
            statCard(
                value: "\(profile.correctionHistory.count)",
                label: "Corrections learned",
                icon: "brain.head.profile",
                color: .purple
            )
            statCard(
                value: currentAccuracy,
                label: "Accuracy",
                icon: "checkmark.circle.fill",
                color: .green,
                delta: deltas.accuracy
            )
        }
    }

    // MARK: - Accuracy Chart

    @ViewBuilder
    private var accuracyChart: some View {
        if !profile.accuracyTrend.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label("Accuracy over time", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.headline)

                Chart {
                    ForEach(profile.accuracyTrend.suffix(30)) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Accuracy", point.accuracyPercent)
                        )
                        .foregroundStyle(Color.accentColor)
                        .interpolationMethod(.catmullRom)

                        AreaMark(
                            x: .value("Date", point.date),
                            y: .value("Accuracy", point.accuracyPercent)
                        )
                        .foregroundStyle(Color.accentColor.opacity(0.15))
                        .interpolationMethod(.catmullRom)
                    }
                    // 90% accuracy target line
                    RuleMark(y: .value("Target", 90.0))
                        .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                        .foregroundStyle(Color.green.opacity(0.6))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("Target 90%")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Color.green.opacity(0.75))
                        }
                }
                .chartYScale(domain: 60...100)
                .chartYAxis {
                    AxisMarks(values: [70, 80, 90, 100]) { value in
                        AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%").font(.caption2) }
                        AxisGridLine()
                    }
                }
                .frame(height: 120)
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Recent Sessions

    @State private var showMoreSessions = false

    private var recentSessions: some View {
        let limit = showMoreSessions ? 8 : 3
        let visible = Array(appState.sessions.prefix(limit))

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Recent sessions", systemImage: "clock.fill")
                    .font(.headline)
                Spacer()
                NavigationLink("See all") {
                    HistoryListContent()
                }
                .font(.subheadline)
            }

            if appState.sessions.isEmpty {
                Text("No recordings yet. Tap Record to start.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                ForEach(visible) { session in
                    Button {
                        selectedSession = session
                    } label: {
                        SessionRowView(session: session)
                    }
                    .buttonStyle(.plain)
                    if session.id != visible.last?.id {
                        Divider()
                    }
                }

                // "Show more / less" toggle
                if appState.sessions.count > 3 {
                    Button {
                        withAnimation(.snappy) { showMoreSessions.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(showMoreSessions ? "Show less" : "Show \(min(8, appState.sessions.count) - 3) more")
                                .font(.caption.weight(.medium))
                            Image(systemName: showMoreSessions ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Pinned sessions

    private var pinnedSessions: [TranscriptionSession] {
        appState.sessions.filter { $0.isPinned }
    }

    private var pinnedSessionsCarousel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Pinned", systemImage: "pin.fill")
                .font(.headline)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(pinnedSessions) { session in
                        Button {
                            selectedSession = session
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: "pin.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                    Spacer()
                                    Text(session.startedAt.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(session.customTitle ?? String(session.finalTranscript.prefix(50)))
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 0)
                                HStack(spacing: 8) {
                                    Label("\(session.wordCount)w", systemImage: "text.word.spacing")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    if !session.tags.isEmpty {
                                        Text(session.tags.first ?? "")
                                            .font(.caption2)
                                            .foregroundStyle(Color.accentColor)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .frame(width: 180, height: 110)
                            .padding(14)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Pinned session: \(session.customTitle ?? String(session.finalTranscript.prefix(40)))")
                        .accessibilityHint("Opens this session — \(session.wordCount) words, recorded \(session.startedAt.formatted(date: .abbreviated, time: .omitted))")
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Today at a glance

    private var todaySessions: [TranscriptionSession] {
        let cal = Calendar.current
        return appState.sessions.filter { cal.isDateInToday($0.startedAt) }
    }

    private var todayWordCount: Int { todaySessions.reduce(0) { $0 + $1.wordCount } }

    /// Recording streak as of yesterday (consecutive days with at least one session).
    /// Used for the streak-at-risk banner — only counts completed days.
    private var currentStreakLength: Int {
        let cal = Calendar.current
        let sessions = appState.sessions.filter { !$0.isArchived }
        let days = Set(sessions.map { cal.startOfDay(for: $0.startedAt) }).sorted(by: >)
        var streak = 0
        var check = cal.startOfDay(for: cal.date(byAdding: .day, value: -1, to: Date()) ?? Date())
        for day in days {
            if day == check {
                streak += 1
                check = cal.date(byAdding: .day, value: -1, to: check) ?? check
            } else if day < check { break }
        }
        return streak
    }

    /// True when it's after 6 PM, the user has an active streak, but hasn't recorded today.
    private var shouldShowStreakAtRiskBanner: Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour >= 18 && todaySessions.isEmpty && currentStreakLength > 0
    }

    @ViewBuilder
    // MARK: - Goal Celebration Banner

    private var goalCelebrationBanner: some View {
        HStack(spacing: 12) {
            Text("🎉")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Daily goal reached!")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Text("\(todayWordCount) words today — great work.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer()
            Button {
                withAnimation(.easeOut(duration: 0.3)) { showGoalCelebration = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                colors: [Color.green, Color.teal],
                startPoint: .leading,
                endPoint: .trailing
            ),
            in: RoundedRectangle(cornerRadius: 0)
        )
        .padding(.top, 0)
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }

    // MARK: - Trial Countdown Banner

    @State private var showPaywallFromBanner = false

    /// Shows a gentle trial countdown during the last 14 days.
    /// Hidden when paid or when > 14 days remain (no nagging during the full trial).
    @ViewBuilder
    private var trialCountdownBanner: some View {
        let days = appState.store.trialDaysRemaining
        let isTrialActive = appState.store.isInFreeTrial
        let isExpired = !appState.store.isUnlocked   // expired & not paid

        if isExpired {
            // Trial ended — persistent upgrade prompt
            Button {
                showPaywallFromBanner = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "crown.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your 60-day free trial has ended")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("Upgrade for $4.99 to keep all features.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(14)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.45, green: 0.10, blue: 0.65),
                                 Color(red: 0.56, green: 0.18, blue: 0.82)],
                        startPoint: .leading, endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 14)
                )
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showPaywallFromBanner) {
                PremiumPaywallView()
                    .environment(appState)
            }
        } else if isTrialActive && days <= 14 {
            // Gentle nudge in the last 14 days
            Button {
                showPaywallFromBanner = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.title3)
                        .foregroundStyle(days <= 3 ? .red : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(days == 1
                             ? "Last day of your free trial"
                             : "\(days) days left in your free trial")
                            .font(.subheadline.weight(.semibold))
                        Text("Upgrade once to keep everything, forever.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("$4.99")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background((days <= 3 ? Color.red : Color.orange).opacity(0.15),
                                    in: Capsule())
                        .foregroundStyle(days <= 3 ? .red : .orange)
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke((days <= 3 ? Color.red : Color.orange).opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showPaywallFromBanner) {
                PremiumPaywallView()
                    .environment(appState)
            }
        }
    }

    @ViewBuilder private var streakAtRiskBanner: some View {
        if shouldShowStreakAtRiskBanner {
            HStack(spacing: 12) {
                Text("🔥")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your \(currentStreakLength)-day streak is at risk")
                        .font(.subheadline.weight(.semibold))
                    Text("Record something before midnight to keep it alive.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    macSafeRecord()
                } label: {
                    Image(systemName: "mic.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.orange)
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Smart Archive Suggestion

    /// Sessions that are unarchived, not pinned or starred, and older than 60 days without recent access.
    private var sessionsToArchiveSuggestion: [TranscriptionSession] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -60, to: Date()) ?? Date()
        return appState.sessions.filter {
            !$0.isArchived &&
            !$0.isPinned &&
            !$0.isStarred &&
            !$0.isLocked &&
            $0.startedAt < cutoff
        }
    }

    /// Show the banner only when there are ≥3 archivable sessions and the user hasn't dismissed it today.
    @AppStorage("archiveSuggestionDismissedDate") private var archiveSuggestionDismissedDate: String = ""

    private var shouldShowArchiveSuggestion: Bool {
        guard sessionsToArchiveSuggestion.count >= 3 else { return false }
        let today = Date().formatted(.dateTime.year().month().day())
        return archiveSuggestionDismissedDate != today
    }

    @ViewBuilder
    private var archiveSuggestionBanner: some View {
        if shouldShowArchiveSuggestion {
            let count = sessionsToArchiveSuggestion.count
            HStack(spacing: 12) {
                Image(systemName: "archivebox")
                    .font(.title3)
                    .foregroundStyle(Color.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Archive \(count) old sessions")
                        .font(.subheadline.weight(.semibold))
                    Text("\(count) sessions from 60+ days ago are taking up space.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    withAnimation {
                        for session in sessionsToArchiveSuggestion where !session.isArchived {
                            appState.toggleArchive(session)
                        }
                        archiveSuggestionDismissedDate = Date().formatted(.dateTime.year().month().day())
                    }
                } label: {
                    Text("Archive")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.teal, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                Button {
                    archiveSuggestionDismissedDate = Date().formatted(.dateTime.year().month().day())
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.teal.opacity(0.25), lineWidth: 1)
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Number of distinct days this calendar month that have at least one session.
    private var monthActiveDays: Int {
        let cal = Calendar.current
        let now = Date()
        let comps = cal.dateComponents([.year, .month], from: now)
        guard let monthStart = cal.date(from: comps) else { return 0 }
        let days = Set(
            appState.sessions
                .filter { $0.startedAt >= monthStart && $0.startedAt <= now }
                .map { cal.startOfDay(for: $0.startedAt) }
        )
        return days.count
    }

    private var todayAtAGlance: some View {
        let words = todayWordCount
        let duration = todaySessions.reduce(0) { $0 + $1.durationSeconds }
        let cal = Calendar.current
        let daysInMonth = cal.range(of: .day, in: .month, for: Date())?.count ?? 30
        let active = monthActiveDays

        return HStack(spacing: 0) {
            glancePill(value: "\(todaySessions.count)",
                       label: todaySessions.count == 1 ? "session" : "sessions",
                       color: .blue)
            Divider().frame(height: 36)
            glancePill(value: "\(words)",
                       label: "words today",
                       color: .purple)
            Divider().frame(height: 36)
            glancePill(value: formatSeconds(duration),
                       label: "recorded",
                       color: .orange)
            Divider().frame(height: 36)
            glancePill(value: "\(active)/\(daysInMonth)",
                       label: "days this month",
                       color: active > daysInMonth / 2 ? .green : .teal)
        }
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.accentColor.opacity(0.15), lineWidth: 1)
        )
    }

    private func glancePill(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Word Count Chart

    @ViewBuilder
    private var wordCountChart: some View {
        let sessions = Array(appState.sessions.prefix(14).reversed())
        if sessions.count >= 2 {
            VStack(alignment: .leading, spacing: 12) {
                Label("Words per session", systemImage: "text.word.spacing")
                    .font(.headline)

                let goal = profile.dailyWordGoal
                Chart {
                    ForEach(sessions) { session in
                        BarMark(
                            x: .value("Date", session.startedAt, unit: .day),
                            y: .value("Words", session.wordCount)
                        )
                        .foregroundStyle(
                            session.wordCount >= goal && goal > 0
                                ? LinearGradient(colors: [Color.green, Color.green.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                                : LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                        )
                        .cornerRadius(4)
                    }
                    // Daily goal reference line
                    if goal > 0 {
                        RuleMark(y: .value("Goal", goal))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                            .foregroundStyle(Color.green.opacity(0.7))
                            .annotation(position: .top, alignment: .trailing) {
                                Text("Goal \(goal)w")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(Color.green.opacity(0.8))
                            }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.day())
                            .font(.caption2)
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisValueLabel { Text("\(value.as(Int.self) ?? 0)").font(.caption2) }
                        AxisGridLine()
                    }
                }
                .frame(height: 110)
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Weekly Summary Card

    private struct WeeklySummary {
        let headline: String
        let sessionsThis: Int
        let sessionsLast: Int
        let wordsThis: Int
        let wordsLast: Int
        let minutesThis: Int
        let minutesLast: Int
    }

    private func buildWeeklySummary() -> WeeklySummary? {
        let cal = Calendar.current
        let now = Date()
        guard let sevenDaysAgo = cal.date(byAdding: .day, value: -7, to: now),
              let fourteenDaysAgo = cal.date(byAdding: .day, value: -14, to: now) else { return nil }

        let thisWeek = appState.sessions.filter { $0.startedAt >= sevenDaysAgo }
        let lastWeek = appState.sessions.filter { $0.startedAt >= fourteenDaysAgo && $0.startedAt < sevenDaysAgo }

        // Need enough data to make the card meaningful
        guard appState.sessions.count >= 3, !thisWeek.isEmpty || !lastWeek.isEmpty else { return nil }

        let sessionsThis = thisWeek.count
        let sessionsLast = lastWeek.count
        let wordsThis    = thisWeek.reduce(0) { $0 + $1.wordCount }
        let wordsLast    = lastWeek.reduce(0) { $0 + $1.wordCount }
        let minutesThis  = Int(thisWeek.reduce(0.0) { $0 + $1.durationSeconds } / 60)
        let minutesLast  = Int(lastWeek.reduce(0.0) { $0 + $1.durationSeconds } / 60)

        let headline: String
        if sessionsLast == 0 {
            headline = "You have \(sessionsThis) session\(sessionsThis == 1 ? "" : "s") so far this week."
        } else {
            let diff = sessionsThis - sessionsLast
            if diff > 0 {
                headline = "Up \(diff) session\(diff == 1 ? "" : "s") vs. last week — great work!"
            } else if diff < 0 {
                headline = "Down \(abs(diff)) session\(abs(diff) == 1 ? "" : "s") from last week. Keep going!"
            } else {
                headline = "Same pace as last week — \(sessionsThis) session\(sessionsThis == 1 ? "" : "s")."
            }
        }

        return WeeklySummary(
            headline: headline,
            sessionsThis: sessionsThis, sessionsLast: sessionsLast,
            wordsThis: wordsThis, wordsLast: wordsLast,
            minutesThis: minutesThis, minutesLast: minutesLast
        )
    }

    @ViewBuilder
    private var weeklySummaryCard: some View {
        if let s = buildWeeklySummary() {
            VStack(alignment: .leading, spacing: 12) {
                Label("Week in review", systemImage: "calendar.badge.clock")
                    .font(.headline)

                Text(s.headline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 0) {
                    weeklyMetricPill(value: s.sessionsThis, prior: s.sessionsLast, label: "Sessions")
                    Divider().frame(height: 40).padding(.horizontal, 4)
                    weeklyMetricPill(value: s.wordsThis, prior: s.wordsLast, label: "Words")
                    Divider().frame(height: 40).padding(.horizontal, 4)
                    weeklyMetricPill(value: s.minutesThis, prior: s.minutesLast, label: "Minutes")
                }
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func weeklyMetricPill(value: Int, prior: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(value)")
                .font(.title3.bold())
                .monospacedDigit()

            if prior > 0 {
                let pct = Int(((Double(value) - Double(prior)) / Double(prior)) * 100)
                HStack(spacing: 2) {
                    Image(systemName: pct >= 0 ? "arrow.up" : "arrow.down")
                        .font(.system(size: 8, weight: .bold))
                    Text("\(abs(pct))%")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(pct >= 0 ? Color.green : Color.red)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background((pct >= 0 ? Color.green : Color.red).opacity(0.1), in: Capsule())
            }

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Weekly Digest Card

    private var currentISOWeek: String {
        let cal = Calendar(identifier: .iso8601)
        let week = cal.component(.weekOfYear, from: Date())
        let year = cal.component(.yearForWeekOfYear, from: Date())
        return "\(year)-W\(String(format: "%02d", week))"
    }

    private var shouldShowWeeklyDigest: Bool {
        guard appState.sessions.count >= 3 else { return false }
        return digestDismissedWeek != currentISOWeek
    }

    @ViewBuilder
    private var weeklyDigestCard: some View {
        if shouldShowWeeklyDigest,
           let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()),
           let fourteenDaysAgo = Calendar.current.date(byAdding: .day, value: -14, to: Date()) {
            let lastWeek = appState.sessions.filter { $0.startedAt >= sevenDaysAgo && !$0.isArchived }
            if !lastWeek.isEmpty {
            let prevWeek = appState.sessions.filter {
                $0.startedAt >= fourteenDaysAgo && $0.startedAt < sevenDaysAgo && !$0.isArchived
            }

            let totalWords   = lastWeek.reduce(0) { $0 + $1.wordCount }
            let prevWords    = prevWeek.reduce(0) { $0 + $1.wordCount }
            let sessionCount = lastWeek.count
            let avgWPM       = lastWeek.filter { $0.paceWPM > 0 }.map { $0.paceWPM }.average
            let wordDelta    = prevWords > 0 ? Int(((Double(totalWords) - Double(prevWords)) / Double(prevWords)) * 100) : 0
            let topSession   = lastWeek.max { $0.wordCount < $1.wordCount }

            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack(spacing: 8) {
                    Image(systemName: "newspaper.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                    Text("Last 7 days")
                        .font(.headline)
                    Spacer()
                    Button {
                        withAnimation(.snappy) { digestDismissedWeek = currentISOWeek }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                }

                // Stat row
                HStack(spacing: 0) {
                    digestStat(
                        value: "\(totalWords)",
                        label: "words",
                        icon: "text.word.spacing",
                        delta: wordDelta != 0 ? "\(wordDelta > 0 ? "+" : "")\(wordDelta)%" : nil,
                        deltaUp: wordDelta >= 0
                    )
                    Divider().frame(height: 36)
                    digestStat(
                        value: "\(sessionCount)",
                        label: sessionCount == 1 ? "session" : "sessions",
                        icon: "waveform"
                    )
                    if avgWPM > 0 {
                        Divider().frame(height: 36)
                        digestStat(
                            value: "\(Int(avgWPM))",
                            label: "avg wpm",
                            icon: "hare"
                        )
                    }
                }
                .frame(maxWidth: .infinity)

                // Best session callout
                if let top = topSession {
                    HStack(spacing: 8) {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                        Text("Best session:")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(top.customTitle
                             ?? String(top.finalTranscript.prefix(35))
                                .trimmingCharacters(in: .whitespaces))
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Text("\(top.wordCount)w")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(Color.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor.opacity(0.15), lineWidth: 1)
            )
            .transition(.move(edge: .top).combined(with: .opacity))
            } // end if !lastWeek.isEmpty
        }
    }

    private func digestStat(value: String, label: String, icon: String,
                             delta: String? = nil, deltaUp: Bool = true) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(Color.accentColor)
            Text(value)
                .font(.title3.bold().monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let delta {
                Text(delta)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(deltaUp ? .green : .red)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Activity Heatmap Card (mini, 12-week)

    /// A compact 12-week recording heatmap that taps through to the full AnalyticsView.
    private var activityHeatmapCard: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        // Build a flat list of 12 weeks × 7 days (newest on the right)
        let totalDays = 12 * 7
        let days: [(date: Date, count: Int)] = (0..<totalDays).reversed().compactMap { offset in
            guard let date = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let count = appState.sessions.filter { cal.isDate($0.startedAt, inSameDayAs: date) }.count
            return (date, count)
        }
        // Group into columns of 7 (week columns, oldest first)
        let weeks: [[(date: Date, count: Int)]] = stride(from: 0, to: days.count, by: 7).map { i in
            Array(days[i..<min(i + 7, days.count)])
        }
        let maxCount = max(1, days.map(\.count).max() ?? 1)

        return Button {
            showingAnalytics = true
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                    Text("Recording Activity")
                        .font(.headline)
                    Spacer()
                    Text("12 wks")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // Mini grid
                HStack(alignment: .top, spacing: 2) {
                    ForEach(weeks.indices, id: \.self) { wi in
                        VStack(spacing: 2) {
                            ForEach(weeks[wi].indices, id: \.self) { di in
                                let day = weeks[wi][di]
                                let intensity = day.count == 0
                                    ? 0.0
                                    : 0.25 + 0.75 * (Double(day.count) / Double(maxCount))
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(day.count > 0
                                          ? Color.accentColor.opacity(intensity)
                                          : Color(.systemGray4))
                                    .frame(width: 10, height: 10)
                                    .accessibilityLabel(
                                        "\(day.date.formatted(date: .abbreviated, time: .omitted)): \(day.count) session\(day.count == 1 ? "" : "s")"
                                    )
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Subtle legend
                HStack(spacing: 4) {
                    Text("Less")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    ForEach([0.0, 0.3, 0.6, 1.0], id: \.self) { v in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(v > 0 ? Color.accentColor.opacity(v) : Color(.systemGray4))
                            .frame(width: 8, height: 8)
                    }
                    Text("More")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("Tap to explore")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .italic()
                }
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recording activity heatmap — last 12 weeks. Tap to open full analytics.")
    }

    // MARK: - Vocab Insight Card

    /// The word we surface today (re-computed once per day via AppStorage cache).
    private var todayVocabInsightWord: String? {
        let today = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: Date()))
        // If the stored word is from today, return it
        if vocabInsightDismissedDate != today && !vocabInsightWordStored.isEmpty {
            return vocabInsightWordStored
        }
        // Pick a new word from the last 7 days of sessions
        let stopWords: Set<String> = [
            "the","a","an","and","or","but","in","on","at","to","for","of","with",
            "is","it","this","that","was","are","be","as","by","from","i","we","you",
            "they","he","she","my","our","your","not","have","has","had","do","did",
            "will","would","can","could","should","its","his","her","their","been","so",
            "if","just","also","about","into","than","when","there","what","all","more"
        ]
        let knownTerms = Set(appState.profile.customVocabulary.map { $0.term.lowercased() })
        let cal = Calendar.current
        let cutoff = cal.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let recent = appState.sessions.filter { $0.startedAt >= cutoff }
        var freq: [String: Int] = [:]
        for session in recent {
            let words = session.finalTranscript
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { w in w.count >= 5 && !stopWords.contains(w) && !knownTerms.contains(w) }
            for w in words { freq[w, default: 0] += 1 }
        }
        guard let top = freq.filter({ $0.value >= 3 }).max(by: { $0.value < $1.value })?.key else { return nil }
        return top
    }

    private var shouldShowVocabInsight: Bool {
        let today = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: Date()))
        guard vocabInsightDismissedDate != today else { return false }
        return todayVocabInsightWord != nil
    }

    @ViewBuilder
    private var vocabInsightCard: some View {
        if let word = todayVocabInsightWord {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Word Insight", systemImage: "lightbulb.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button {
                        let today = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: Date()))
                        vocabInsightDismissedDate = today
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Text("You've used \"\(word)\" frequently this week but haven't added it to your vocabulary list.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        let entry = VocabularyEntry(
                            term: word,
                            phonetic: nil,
                            aliases: [],
                            category: .other,
                            language: appState.profile.detectedPrimaryLanguage,
                            source: .userAdded,
                            relevanceScore: 0.8
                        )
                        appState.addVocabularyEntry(entry)
                        let today = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: Date()))
                        vocabInsightDismissedDate = today
                        vocabInsightWordStored = ""
                    } label: {
                        Label("Add to vocabulary", systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.accentColor, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button("Dismiss") {
                        let today = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: Date()))
                        vocabInsightDismissedDate = today
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.orange.opacity(0.2), lineWidth: 1))
            .onAppear {
                // Cache the word for this session
                if vocabInsightWordStored.isEmpty || vocabInsightWordStored != word {
                    vocabInsightWordStored = word
                }
            }
        }
    }

    // MARK: - Sync Button

    private var syncButton: some View {
        Button {
            appState.syncNow()
        } label: {
            Image(systemName: appState.cloudSync.syncState.iconName)
                .symbolEffect(.pulse, isActive: appState.cloudSync.syncState == .syncing)
                .foregroundStyle(appState.cloudSync.syncState.isError ? .red : .accentColor)
        }
    }

    // MARK: - Helpers

    private func profilePill(icon: String, label: String, subtitle: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.title3)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity)
    }

    private func statCard(value: String, label: String, icon: String, color: Color, delta: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.title2)
                Spacer()
                if let d = delta, abs(d) > 0.01 {
                    HStack(spacing: 2) {
                        Image(systemName: d > 0 ? "arrow.up" : "arrow.down")
                            .font(.system(size: 9, weight: .bold))
                        Text("\(Int(abs(d * 100)))%")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(d > 0 ? .green : .red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background((d > 0 ? Color.green : Color.red).opacity(0.1), in: Capsule())
                    .transition(.scale.combined(with: .opacity))
                }
            }

            Text(value)
                .font(.title2.bold())

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)\(delta.map { d in abs(d) > 0.01 ? ", \(d > 0 ? "up" : "down") \(Int(abs(d * 100))) percent from last week" : "" } ?? "")")
    }

    /// Percentage change in minutes, session count, and accuracy vs the prior 7-day window.
    private var weekOverWeekDeltas: (minutes: Double?, sessions: Double?, accuracy: Double?) {
        let cal = Calendar.current
        let now = Date()
        guard let sevenDaysAgo  = cal.date(byAdding: .day, value:  -7, to: now),
              let fourteenDaysAgo = cal.date(byAdding: .day, value: -14, to: now) else {
            return (nil, nil, nil)
        }
        let thisWeek = appState.sessions.filter { $0.startedAt >= sevenDaysAgo }
        let lastWeek = appState.sessions.filter { $0.startedAt >= fourteenDaysAgo && $0.startedAt < sevenDaysAgo }

        let twMin = thisWeek.reduce(0.0) { $0 + $1.durationSeconds } / 60.0
        let lwMin = lastWeek.reduce(0.0) { $0 + $1.durationSeconds } / 60.0
        let minutesDelta: Double? = lwMin > 1 ? (twMin - lwMin) / lwMin : nil

        let twCount = Double(thisWeek.count)
        let lwCount = Double(lastWeek.count)
        let sessionsDelta: Double? = lwCount > 0 ? (twCount - lwCount) / lwCount : nil

        let trend = profile.accuracyTrend
        let currentAcc = trend.last?.accuracyPercent
        let oldAcc = trend.last(where: { $0.date <= sevenDaysAgo })?.accuracyPercent
        let accuracyDelta: Double? = (currentAcc != nil && oldAcc != nil && oldAcc! > 0)
            ? (currentAcc! - oldAcc!) / oldAcc! : nil

        return (minutesDelta, sessionsDelta, accuracyDelta)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var formalityLabel: String {
        switch profile.formalityScore {
        case 0..<0.35: return "Casual"
        case 0.35..<0.65: return "Balanced"
        default: return "Formal"
        }
    }

    private var currentAccuracy: String {
        guard let latest = profile.accuracyTrend.last else { return "—" }
        return "\(Int(latest.accuracyPercent))%"
    }

    private func formatMinutes(_ minutes: Double) -> String {
        if minutes < 60 { return "\(Int(minutes))m" }
        return "\(Int(minutes / 60))h \(Int(minutes.truncatingRemainder(dividingBy: 60)))m"
    }

    private func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    private func formatSeconds(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        let m = Int(seconds / 60)
        let s = Int(seconds.truncatingRemainder(dividingBy: 60))
        return s > 0 ? "\(m)m \(s)s" : "\(m)m"
    }
}

struct SessionRowView: View {
    var session: TranscriptionSession

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "waveform")
                .foregroundStyle(Color.accentColor)
                .font(.title3)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.1), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(session.finalTranscript.isEmpty ? "Empty session" : session.finalTranscript)
                    .font(.subheadline)
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                HStack(spacing: 8) {
                    Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                    Text("·")
                    Text("\(session.wordCount) words")
                    if session.codeSwitch {
                        Text("·")
                        Label("Mixed", systemImage: "globe")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Quick Note Sheet

/// A lightweight text-entry sheet for capturing typed text as a session
/// without opening the full recording UI.
struct QuickNoteView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var wordCount: Int { text.split(separator: " ").count }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Word count badge
                HStack {
                    Spacer()
                    Text("\(wordCount) word\(wordCount == 1 ? "" : "s")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }

                TextEditor(text: $text)
                    .font(.body)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .focused($isFocused)
                    .scrollContentBackground(.hidden)

                if text.isEmpty {
                    // Placeholder
                    VStack(spacing: 8) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 40))
                            .foregroundStyle(Color.accentColor.opacity(0.4))
                        Text("Type or paste your note…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Quick Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        appState.addManualSession(text: text)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear { isFocused = true }
    }
}

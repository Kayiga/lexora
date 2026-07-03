import Foundation
import SwiftUI
import WidgetKit
import StoreKit
import NaturalLanguage

@Observable @MainActor
final class AppState {

    /// Safe static fallback used by the custom environment key on Mac Catalyst.
    /// Mac Catalyst's PresentationHostingController breaks the @Observable environment
    /// chain for sheets/popovers. The custom \.appState EnvironmentKey reads this when
    /// the injected value is absent, avoiding the assertionFailure crash.
    nonisolated(unsafe) private(set) static var _shared: AppState?

    // Single source of truth for each service — initialised once in init()
    let storage: ProfileStorage
    let languageIntelligence: LanguageIntelligence
    var learningEngine: LearningEngine
    var speechEngine: SpeechEngine
    var cloudSync: CloudSyncService
    let spotlight: SpotlightService
    let liveActivity = LiveActivityService()
    let notifications = NotificationService()
    let ai = AIService()
    let store = StoreService()

    /// Background task that pushes Live Activity updates every second while recording.
    private var activityUpdateTask: Task<Void, Never>?

    /// Tags to apply to the next finished session (from the active recording template). Cleared after use.
    private var pendingTemplateTags: [String] = []

    var sessions: [TranscriptionSession] = [] {
        didSet {
            spotlight.indexAll(sessions)
            storage.saveSessions(sessions)
            pushWidgetData()
        }
    }

    // Stored so @Observable can track changes and re-render RootView.
    // A computed UserDefaults property is invisible to the observation system.
    var hasCompletedOnboarding: Bool = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }

    // Convenience accessor — actual storage is in LearningEngine
    var profile: UserVoiceProfile {
        get { learningEngine.profile }
        set { learningEngine.profile = newValue }
    }

    init() {
        let storage = ProfileStorage()
        let li = LanguageIntelligence()
        let loadedProfile = storage.load() ?? UserVoiceProfile(displayName: "You")
        let le = LearningEngine(profile: loadedProfile, languageIntelligence: li, storage: storage)
        let cs = CloudSyncService(storage: storage)
        let se = SpeechEngine(languageIntelligence: li, learningEngine: le)

        self.storage = storage
        self.languageIntelligence = li
        self.learningEngine = le
        self.speechEngine = se
        self.cloudSync = cs
        self.spotlight = SpotlightService()

        // Make this instance accessible to App Intents and Mac Catalyst sheet fallback.
        AppStateHolder.shared = self
        AppState._shared = self

        // Note: SpeechEngine.finaliseSession() already calls learningEngine.ingest() internally.
        // This closure handles UI state and cloud upload only.
        se.onSessionFinished = { [weak self] session in
            guard let self else { return }
            // Apply template auto-tags if a template was active when recording started.
            var taggedSession = session
            for tag in pendingTemplateTags {
                if !taggedSession.tags.contains(tag) {
                    taggedSession.tags.append(tag)
                }
            }
            pendingTemplateTags = []
            // Auto-tag with time of day if the feature is enabled.
            let autoTimeTag = UserDefaults.standard.bool(forKey: "autoTimeTagEnabled")
            if autoTimeTag {
                let hour = Calendar.current.component(.hour, from: taggedSession.startedAt)
                let timeTag: String
                switch hour {
                case 5..<12:  timeTag = "morning"
                case 12..<17: timeTag = "afternoon"
                case 17..<21: timeTag = "evening"
                default:      timeTag = "night"
                }
                if !taggedSession.tags.contains(timeTag) {
                    taggedSession.tags.append(timeTag)
                }
            }
            // Auto-generate a keyword title if the user hasn't set one.
            if taggedSession.customTitle == nil, !taggedSession.finalTranscript.isEmpty {
                taggedSession.customTitle = Self.autoTitle(from: taggedSession.finalTranscript)
            }
            sessions.insert(taggedSession, at: 0)
            Task { await cs.uploadSession(session) }
            // Fire a background notification with session stats.
            notifications.sendSessionSummary(
                wordCount: session.wordCount,
                durationSeconds: Int(session.durationSeconds),
                language: session.primaryLanguage
            )
            // Cancel the streak-at-risk nudge — user has now recorded today.
            notifications.cancelStreakAtRisk()
            // Prompt for App Store review at meaningful milestones.
            requestReviewIfAppropriate()
        }

        // Load persisted sessions from disk (keeps history across app restarts).
        let persisted = storage.loadSessions()
        if !persisted.isEmpty {
            // Assign without triggering didSet (which would immediately re-save)
            sessions = persisted
        }

        // Import any sessions saved by the Lexora Keyboard extension.
        importPendingKeyboardSessions()
    }

    // MARK: - Keyboard Extension Session Import

    /// Reads pending_*.json files written by LexoraKeyboard from the shared App Group
    /// container, converts them to manual sessions, then deletes the source files.
    private func importPendingKeyboardSessions() {
        guard let container = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: "group.com.yiga.Lexora")
        else { return }

        struct PendingSession: Codable {
            var transcript: String
            var language: String
            var createdAt: Date
        }

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: container,
                                                       includingPropertiesForKeys: nil) else { return }
        let pending = files.filter { $0.lastPathComponent.hasPrefix("pending_") && $0.pathExtension == "json" }
        guard !pending.isEmpty else { return }

        for url in pending {
            guard let data = try? Data(contentsOf: url),
                  let item = try? JSONDecoder().decode(PendingSession.self, from: data),
                  !item.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                try? fm.removeItem(at: url)
                continue
            }
            // Build a minimal session from the keyboard transcript
            var session = TranscriptionSession()
            session.finalTranscript = item.transcript
            session.rawTranscript   = item.transcript
            session.primaryLanguage = item.language
            session.startedAt       = item.createdAt
            // durationSeconds is computed from endedAt; leaving endedAt nil gives 0 duration
            session.tags            = ["keyboard"]
            session.customTitle     = Self.autoTitle(from: item.transcript)
            sessions.insert(session, at: 0)
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - Actions

    func startRecording(language: String? = nil, contextProfileID: UUID? = nil, templateTags: [String] = []) async throws {
        pendingTemplateTags = templateTags
        // Apply silence auto-stop settings from the user profile before starting.
        speechEngine.configureSilenceAutoStop(
            enabled: profile.silenceAutoStopEnabled,
            timeout: profile.silenceTimeoutSeconds
        )
        try await speechEngine.startListening(language: language, contextProfileID: contextProfileID)
        // Kick off Live Activity on devices that support it.
        liveActivity.start(sessionID: UUID())
        // Push a state update every second while recording.
        activityUpdateTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, speechEngine.isListening else { break }
                let wordCount = speechEngine.currentTranscript
                    .split(whereSeparator: { $0.isWhitespace }).count
                liveActivity.update(
                    wordCount: wordCount,
                    detectedLanguage: speechEngine.detectedLanguage,
                    isListening: speechEngine.isListening
                )
            }
        }
    }

    func stopRecording() {
        activityUpdateTask?.cancel()
        activityUpdateTask = nil
        // Push final word count before ending.
        let wordCount = speechEngine.currentTranscript
            .split(whereSeparator: { $0.isWhitespace }).count
        liveActivity.end(wordCount: wordCount, detectedLanguage: speechEngine.detectedLanguage)
        speechEngine.stopListening()
    }

    func pauseRecording() {
        speechEngine.pauseListening()
        let wordCount = speechEngine.currentTranscript
            .split(whereSeparator: { $0.isWhitespace }).count
        liveActivity.update(wordCount: wordCount,
                            detectedLanguage: speechEngine.detectedLanguage,
                            isListening: false)
    }

    func resumeRecording() {
        Task { @MainActor in
            try? await speechEngine.resumeListening()
            let wordCount = speechEngine.currentTranscript
                .split(whereSeparator: { $0.isWhitespace }).count
            liveActivity.update(wordCount: wordCount,
                                detectedLanguage: speechEngine.detectedLanguage,
                                isListening: true)
        }
    }

    func recordCorrection(original: String, corrected: String, sessionID: UUID) {
        learningEngine.recordCorrection(original: original, corrected: corrected, sessionID: sessionID)
        cloudSync.pendingChanges += 1
    }

    func syncNow() {
        Task {
            let merged = await cloudSync.syncChanges(profile: learningEngine.profile)
            learningEngine.profile = merged
        }
        scheduleDigestIfNeeded()
    }

    // MARK: - Quick (typed) Session

    /// Creates a text-only session from manually typed or pasted content.
    /// The session has no audio file, zero duration, and full confidence.
    func addManualSession(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var session = TranscriptionSession()
        session.startedAt    = Date()
        session.endedAt      = Date()         // instant — no real duration
        session.rawTranscript   = trimmed
        session.finalTranscript = trimmed
        session.primaryLanguage = profile.detectedPrimaryLanguage
        session.wordCount       = trimmed.split(separator: " ").count
        session.confidenceAverage = 1.0
        session.estimatedAccuracy = 100.0
        session.formalityDetected = profile.formalityScore
        session.customTitle = Self.autoTitle(from: trimmed)
        session.tags.append("typed")
        let autoTimeTag = UserDefaults.standard.bool(forKey: "autoTimeTagEnabled")
        if autoTimeTag {
            let hour = Calendar.current.component(.hour, from: session.startedAt)
            let tag: String
            switch hour {
            case 5..<12:  tag = "morning"
            case 12..<17: tag = "afternoon"
            case 17..<21: tag = "evening"
            default:      tag = "night"
            }
            session.tags.append(tag)
        }
        sessions.insert(session, at: 0)
        spotlight.index(session)
    }

    // MARK: - Smart Auto-Title

    /// Generates a compact 2–4 word title from the top keywords in a transcript.
    /// Uses NLTagger to prefer proper nouns and high-value nouns.
    /// Returns nil when the transcript is too short or yields no useful keywords.
    nonisolated private static func autoTitle(from transcript: String) -> String? {
        guard transcript.split(separator: " ").count >= 8 else { return nil }

        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        tagger.string = transcript
        let range = transcript.startIndex..<transcript.endIndex

        var scores: [String: Int] = [:]

        // Proper nouns score 4 — most distinctive
        tagger.enumerateTags(in: range, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, r in
            if let tag, [.personalName, .placeName, .organizationName].contains(tag) {
                let w = String(transcript[r])
                if w.count > 2 { scores[w, default: 0] += 4 }
            }
            return true
        }

        // Common nouns score 1, but only if long enough to be meaningful
        tagger.enumerateTags(in: range, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, r in
            if let tag, tag == .noun {
                let w = String(transcript[r])
                if w.count > 4 { scores[w, default: 0] += 1 }
            }
            return true
        }

        guard !scores.isEmpty else { return nil }

        // De-duplicate case-insensitively, keep highest-score variant, take top 3
        var seen = Set<String>()
        let topWords = scores
            .sorted { $0.value > $1.value }
            .filter { seen.insert($0.key.lowercased()).inserted }
            .prefix(3)
            .map { $0.key.prefix(1).uppercased() + $0.key.dropFirst() }

        guard !topWords.isEmpty else { return nil }
        return topWords.joined(separator: " · ")
    }

    /// Reschedules (or cancels) the daily digest notification based on current profile settings
    /// and yesterday's stats. Safe to call on every background transition.
    func scheduleDigestIfNeeded() {
        let p = profile
        guard p.dailyDigestEnabled else {
            notifications.cancelDailyDigest()
            return
        }
        let cal = Calendar.current
        // Compute yesterday's stats
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: Date()) else { return }
        let yesterdaySessions = sessions.filter { cal.isDate($0.startedAt, inSameDayAs: yesterday) }
        let yesterdayWords    = yesterdaySessions.reduce(0) { $0 + $1.wordCount }
        let goalMet = p.dailyWordGoal > 0 && yesterdayWords >= p.dailyWordGoal

        // Compute current streak (counting completed days only)
        var streak = 0
        var check = cal.startOfDay(for: yesterday)
        let activeDays = Set(sessions.map { cal.startOfDay(for: $0.startedAt) })
        while activeDays.contains(check) {
            streak += 1
            check = cal.date(byAdding: .day, value: -1, to: check) ?? check
        }

        // Compute last 7 days stats for weekly digest
        let sevenDaysAgo = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: Date())) ?? Date()
        let weekSessions = sessions.filter { $0.startedAt >= sevenDaysAgo }
        let weekWords    = weekSessions.reduce(0) { $0 + $1.wordCount }

        // Longest streak across last 7 days (re-use activeDays set, look back 7 days)
        var longestStreak = 0, currentRun = 0
        var dayCheck = cal.startOfDay(for: yesterday)
        for _ in 0..<7 {
            if activeDays.contains(dayCheck) {
                currentRun += 1
                longestStreak = max(longestStreak, currentRun)
            } else {
                currentRun = 0
            }
            dayCheck = cal.date(byAdding: .day, value: -1, to: dayCheck) ?? dayCheck
        }

        // Top language last 7 days
        let langCounts = Dictionary(grouping: weekSessions) { $0.primaryLanguage }
            .mapValues { $0.count }
        let topLanguage = langCounts.max(by: { $0.value < $1.value })?.key

        // Peak hour: bucket session start hours across all history, pick the most common
        var hourBuckets = [Int: Int]()
        for s in sessions {
            let h = cal.component(.hour, from: s.startedAt)
            hourBuckets[h, default: 0] += 1
        }
        let peakHour = hourBuckets.max(by: { $0.value < $1.value })?.key ?? 9

        Task {
            await notifications.scheduleDailyDigest(
                yesterdayWords: yesterdayWords,
                yesterdaySessions: yesterdaySessions.count,
                streakDays: streak,
                goalMet: goalMet,
                hour: p.dailyDigestHour,
                minute: p.dailyDigestMinute
            )

            // Weekly digest — reschedule every time so content stays fresh
            notifications.scheduleWeeklyDigest(
                weekWords: weekWords,
                weekSessions: weekSessions.count,
                longestStreak: longestStreak,
                topLanguage: topLanguage
            )

            // Peak-hour nudge — fires at the user's historically most-active hour
            notifications.schedulePeakHourNudge(peakHour: peakHour)
        }
    }

    /// Downloads cloud sessions and merges any that aren't already stored locally.
    /// Returns the count of newly restored sessions.
    @discardableResult
    func restoreSessionsFromCloud() async -> Int {
        let cloudSessions = await cloudSync.fetchRecentSessions(limit: 200)
        let existingIDs = Set(sessions.map { $0.id })
        let newSessions = cloudSessions.filter { !existingIDs.contains($0.id) }
        guard !newSessions.isEmpty else { return 0 }
        // Insert at the correct sorted position (by date descending)
        let merged = (sessions + newSessions).sorted { $0.startedAt > $1.startedAt }
        sessions = merged
        return newSessions.count
    }

    func addVocabularyEntry(_ entry: VocabularyEntry) {
        learningEngine.profile.customVocabulary.append(entry)
        storage.save(learningEngine.profile)
        cloudSync.pendingChanges += 1
    }

    func deleteVocabularyEntry(id: UUID) {
        learningEngine.profile.customVocabulary.removeAll { $0.id == id }
        storage.save(learningEngine.profile)
    }

    func recordVocabularyUsage(id: UUID) {
        guard let idx = learningEngine.profile.customVocabulary.firstIndex(where: { $0.id == id }) else { return }
        learningEngine.profile.customVocabulary[idx].recordUsage()
        storage.save(learningEngine.profile)
    }

    func deleteSession(_ session: TranscriptionSession) {
        spotlight.deindex(session)
        sessions.removeAll { $0.id == session.id }
    }

    /// Merges two or more sessions into a single new session, then removes the originals.
    /// The combined transcript prepends a short header line for each source session.
    func mergeSessions(_ sessionsToMerge: [TranscriptionSession]) {
        guard sessionsToMerge.count >= 2 else { return }
        let sorted = sessionsToMerge.sorted { $0.startedAt < $1.startedAt }

        // Build combined transcript — each section starts with a bracketed time label.
        let combinedTranscript = sorted.map { s in
            let label = s.customTitle
                ?? s.startedAt.formatted(.dateTime.hour().minute())
            return "[\(label)]\n\(s.finalTranscript)"
        }.joined(separator: "\n\n")

        let totalWords    = sessionsToMerge.reduce(0) { $0 + $1.wordCount }
        let totalDuration = sessionsToMerge.reduce(0.0) { $0 + $1.durationSeconds }
        let allTags       = Array(Set(sessionsToMerge.flatMap { $0.tags })).sorted()
        let allFillers    = sessionsToMerge.flatMap { $0.fillerWords }
        let accuracyValid = sessionsToMerge.filter { $0.estimatedAccuracy > 0 }
        let avgAccuracy   = accuracyValid.isEmpty ? 0.0
            : accuracyValid.reduce(0) { $0 + $1.estimatedAccuracy } / Double(accuracyValid.count)

        guard let firstSession = sorted.first else { return }
        var merged = TranscriptionSession()
        merged.startedAt        = firstSession.startedAt
        // Set endedAt so durationSeconds equals the sum of all source durations.
        merged.endedAt          = merged.startedAt.addingTimeInterval(totalDuration)
        merged.finalTranscript  = combinedTranscript
        merged.rawTranscript    = combinedTranscript
        merged.primaryLanguage  = firstSession.primaryLanguage
        merged.wordCount        = totalWords
        merged.estimatedAccuracy = avgAccuracy
        merged.paceWPM          = totalDuration > 0 ? Double(totalWords) / (totalDuration / 60) : 0
        merged.fillerWords      = allFillers
        merged.tags             = allTags
        merged.customTitle      = "Merged (\(sessionsToMerge.count) sessions)"
        merged.codeSwitch       = sessionsToMerge.contains { $0.codeSwitch }
            || Set(sessionsToMerge.map { $0.primaryLanguage }).count > 1

        // Remove originals, insert merged at the front.
        let idsToRemove = Set(sessionsToMerge.map { $0.id })
        for s in sessionsToMerge { spotlight.deindex(s) }
        sessions.removeAll { idsToRemove.contains($0.id) }
        sessions.insert(merged, at: 0)
        spotlight.index(merged)
    }

    /// Creates a copy of the session with a new UUID and "Copy of" title.
    func duplicateSession(_ session: TranscriptionSession) {
        var copy = session
        copy.id = UUID()
        copy.startedAt = Date()
        copy.endedAt = Date()
        copy.customTitle = "Copy of \(session.customTitle ?? String(session.finalTranscript.prefix(40)))"
        copy.isSyncedToCloud = false
        sessions.insert(copy, at: 0)
    }

    func toggleStar(_ session: TranscriptionSession) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[idx].isStarred.toggle()
        spotlight.index(sessions[idx])
    }

    /// Pins (or unpins) a session to the top of the history list.
    func togglePin(_ session: TranscriptionSession) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[idx].isPinned.toggle()
        spotlight.index(sessions[idx])
    }

    /// Locks (or unlocks) a session so its transcript and title become read-only.
    func toggleLock(_ session: TranscriptionSession) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[idx].isLocked.toggle()
    }

    /// Archives (or unarchives) a session, hiding it from the main history list.
    /// Pre-populates tags that will be applied to the next session when it finalises.
    /// Called by SessionDetailView's "Continue this topic" action.
    func primeNextSessionTags(_ tags: [String]) {
        pendingTemplateTags = tags
    }

    func toggleArchive(_ session: TranscriptionSession) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[idx].isArchived.toggle()
        if sessions[idx].isArchived {
            spotlight.deindex(sessions[idx])
        } else {
            spotlight.index(sessions[idx])
        }
    }

    /// Archives all non-archived sessions older than `days` days.
    /// Returns the count of sessions newly archived.
    @discardableResult
    func autoArchiveSessions(olderThan days: Int) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        var count = 0
        for idx in sessions.indices {
            guard !sessions[idx].isArchived,
                  sessions[idx].startedAt < cutoff else { continue }
            sessions[idx].isArchived = true
            spotlight.deindex(sessions[idx])
            count += 1
        }
        if count > 0 {
            // Reassign to trigger didSet → spotlight index + storage save + widget push
            sessions = sessions
        }
        return count
    }

    /// Replace the tags on a session and re-index it in Spotlight.
    func updateTags(sessionID: UUID, tags: [String]) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[idx].tags = tags
        spotlight.index(sessions[idx])
    }

    /// Set (or clear) a custom title on a session.
    func updateTitle(sessionID: UUID, title: String?) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[idx].customTitle = title?.isEmpty == true ? nil : title
        spotlight.index(sessions[idx])
    }

    /// Set (or clear) freeform notes on a session.
    func updateNotes(sessionID: UUID, notes: String?) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[idx].notes = notes?.isEmpty == true ? nil : notes
    }

    func updateChapters(sessionID: UUID, chapters: [TranscriptChapter]) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[idx].chapters = chapters
    }

    // MARK: - Widget

    /// Computes today's word count, session count, and streak, persists them
    /// to the App Group UserDefaults, then asks WidgetKit to reload.
    private func pushWidgetData() {
        let cal = Calendar.current
        let today = sessions.filter { cal.isDateInToday($0.startedAt) }
        let todayWords = today.reduce(0) { $0 + $1.wordCount }
        let todaySessions = today.count

        // Streak: consecutive days with at least one session
        var streak = 0
        var date = cal.startOfDay(for: Date())
        while true {
            let hasSession = sessions.contains { cal.isDate($0.startedAt, inSameDayAs: date) }
            if hasSession { streak += 1 } else { break }
            guard let prev = cal.date(byAdding: .day, value: -1, to: date) else { break }
            date = prev
        }

        let lastLang = sessions.first?.primaryLanguage ?? ""
        storage.saveWidgetData(todayWords: todayWords, todaySessions: todaySessions, streak: streak,
                               dailyGoal: profile.dailyWordGoal, lastLanguage: lastLang)
        WidgetCenter.shared.reloadAllTimelines()
        // Ask the app delegate to refresh the dynamic Quick Action for the last-used language
        NotificationCenter.default.post(name: .lexoraRefreshQuickActions, object: nil)
        updateBadge(todaySessions: todaySessions)

        // Fire a celebration notification the first time the daily goal is met each day.
        notifications.sendGoalAchievedIfNeeded(
            totalWordsToday: todayWords,
            goal: profile.dailyWordGoal,
            goalDate: cal.startOfDay(for: Date())
        )
    }

    /// Updates the app icon badge to reflect today's session count.
    /// The badge is cleared when the user opens the app (handled in RootView).
    private func updateBadge(todaySessions: Int) {
        Task { @MainActor in
            do {
                try await UNUserNotificationCenter.current()
                    .setBadgeCount(todaySessions > 0 ? todaySessions : 0)
            } catch {
                // Badge setting failed — permission may not be granted
            }
        }
    }

    // MARK: - App Store Review

    /// Requests a review at natural "feel-good" moments: 5th, 25th, and 100th session,
    /// and whenever the total word count crosses a big round number.
    /// StoreKit rate-limits actual dialog presentation to ~3× per year regardless.
    private func requestReviewIfAppropriate() {
        let count = sessions.count
        let totalWords = sessions.reduce(0) { $0 + $1.wordCount }

        let sessionMilestones: Set<Int> = [5, 25, 100, 250]
        let wordMilestones: Set<Int>    = [1_000, 5_000, 10_000, 50_000]

        // Newest session is inserted at index 0 (sessions.last is the OLDEST).
        let lastSessionWords = sessions.first?.wordCount ?? 0
        guard sessionMilestones.contains(count)
              || wordMilestones.contains(where: { totalWords >= $0 && totalWords - lastSessionWords < $0 })
        else { return }

        // Find the foreground scene and request the review (modern API,
        // replaces the deprecated SKStoreReviewController.requestReview(in:)).
        if let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            AppStore.requestReview(in: scene)
        }
    }

    /// Call when the app comes to the foreground to clear the badge and
    /// refresh the streak-at-risk notification based on today's activity.
    func clearBadge() {
        Task { @MainActor in
            try? await UNUserNotificationCenter.current().setBadgeCount(0)
            refreshStreakAtRiskNotification()
        }
    }

    /// Schedules the streak-at-risk 8 PM nudge if the user has a streak but
    /// hasn't yet recorded today; cancels it if they already have.
    func refreshStreakAtRiskNotification() {
        let cal = Calendar.current
        let recordedToday = sessions.contains { cal.isDateInToday($0.startedAt) }

        if recordedToday {
            notifications.cancelStreakAtRisk()
        } else {
            // Compute streak length up to yesterday
            var streak = 0
            var date = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date())) ?? Date()
            while true {
                let has = sessions.contains { cal.isDate($0.startedAt, inSameDayAs: date) }
                guard has else { break }
                streak += 1
                guard let prev = cal.date(byAdding: .day, value: -1, to: date) else { break }
                date = prev
            }
            if streak > 0 {
                notifications.scheduleStreakAtRisk(currentStreak: streak)
            } else {
                notifications.cancelStreakAtRisk()
            }
        }
    }
}

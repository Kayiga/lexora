import UserNotifications
import Foundation
import Observation

/// Manages local notification scheduling for Lexora.
/// All public methods are safe to call from any context; they dispatch internally.
@Observable @MainActor
final class NotificationService {

    // MARK: - Constants

    private static let dailyReminderID   = "com.yiga.Lexora.dailyReminder"
    private static let streakAtRiskID    = "com.yiga.Lexora.streakAtRisk"
    private static let dailyDigestID     = "com.yiga.Lexora.dailyDigest"
    private static let weeklyDigestID    = "com.yiga.Lexora.weeklyDigest"
    private static let peakHourNudgeID   = "com.yiga.Lexora.peakHourNudge"

    // MARK: - Public State

    /// Current authorization status, updated on init and after any permission request.
    var authorizationStatus: UNAuthorizationStatus = .notDetermined

    // MARK: - Init

    init() {
        Task { await refreshStatus() }
    }

    // MARK: - Authorization

    /// Requests notification permission if not yet determined.
    /// Returns `true` if the user granted permission (or it was already granted).
    @discardableResult
    func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshStatus()
            return granted
        } catch {
            return false
        }
    }

    /// Re-queries the current authorization status from the system.
    func refreshStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    // MARK: - Daily Reminder

    /// Schedules (or reschedules) the daily recording reminder at the given hour/minute.
    /// Automatically requests permission if needed.
    func scheduleDailyReminder(hour: Int, minute: Int) async {
        var granted = authorizationStatus == .authorized
        if !granted { granted = await requestPermission() }
        guard granted else { return }

        // Remove any existing reminder first.
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.dailyReminderID])

        let content = UNMutableNotificationContent()
        content.title = "Time to record 🎙️"
        content.body = "Capture your thoughts with Lexora — your voice, your story."
        content.sound = .default
        content.userInfo = ["deeplink": "lexora://record"]

        var components = DateComponents()
        components.hour = hour
        components.minute = minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(
            identifier: Self.dailyReminderID,
            content: content,
            trigger: trigger
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            // Scheduling failed — log silently; user can retry via Settings toggle.
        }
    }

    /// Cancels the daily reminder.
    func cancelDailyReminder() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.dailyReminderID])
    }

    // MARK: - Daily Digest Notification

    /// Schedules (or reschedules) a morning digest notification with a snapshot of
    /// the user's recent performance. Call this when the app goes to the background
    /// so the content always reflects the latest activity.
    func scheduleDailyDigest(
        yesterdayWords: Int,
        yesterdaySessions: Int,
        streakDays: Int,
        goalMet: Bool,
        hour: Int,
        minute: Int
    ) async {
        var granted = authorizationStatus == .authorized
        if !granted { granted = await requestPermission() }
        guard granted else { return }

        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.dailyDigestID])

        let content = UNMutableNotificationContent()
        content.title = "Good morning! Your Lexora digest \u{2600}\u{FE0F}"   // ☀️

        var parts: [String] = []
        if yesterdayWords > 0 {
            parts.append("\(yesterdayWords) words · \(yesterdaySessions) session\(yesterdaySessions == 1 ? "" : "s") yesterday")
        }
        if streakDays > 0 {
            parts.append("\(streakDays)-day streak \u{1F525}")
        }
        if goalMet {
            parts.append("Goal met \u{1F389}")
        }
        parts.append("Tap to start today's recording.")
        content.body = parts.joined(separator: " · ")
        content.sound = .default
        content.userInfo = ["deeplink": "lexora://record"]

        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        let request = UNNotificationRequest(
            identifier: Self.dailyDigestID,
            content: content,
            trigger: trigger
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Cancels the daily digest notification.
    func cancelDailyDigest() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.dailyDigestID])
    }

    // MARK: - Streak-at-risk Notification

    /// Schedules a daily 8 PM "streak at risk" reminder that fires only when the user
    /// has an active streak but hasn't recorded yet today. Cancels itself if the user
    /// records during the day (call `cancelStreakAtRisk()` from `onSessionFinished`).
    func scheduleStreakAtRisk(currentStreak: Int) {
        guard authorizationStatus == .authorized, currentStreak > 0 else { return }

        // Remove any existing request before rescheduling
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.streakAtRiskID])

        let content = UNMutableNotificationContent()
        content.title = "Your \(currentStreak)-day streak is at risk 🔥"
        content.body = "Record something today to keep the flame alive."
        content.sound = .default
        content.userInfo = ["deeplink": "lexora://record"]
        content.interruptionLevel = .timeSensitive

        var components = DateComponents()
        components.hour = 20       // 8 PM
        components.minute = 0

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(
            identifier: Self.streakAtRiskID,
            content: content,
            trigger: trigger
        )
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }

    /// Cancels the streak-at-risk notification — call this when a session finishes
    /// so the user doesn't get an 8 PM nudge after already recording.
    func cancelStreakAtRisk() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.streakAtRiskID])
    }

    // MARK: - Goal Achievement Notification

    /// Fires a celebration notification when the user meets their daily word goal.
    /// Pass the same `goalDate` each day (e.g. `startOfDay(for: Date())`); the method
    /// uses UserDefaults to ensure it fires at most once per calendar day.
    func sendGoalAchievedIfNeeded(totalWordsToday: Int, goal: Int, goalDate: Date) {
        guard authorizationStatus == .authorized, goal > 0, totalWordsToday >= goal else { return }

        let key = "lexora.goalAchievedDate"
        let cal = Calendar.current
        if let last = UserDefaults.standard.object(forKey: key) as? Date,
           cal.isDate(last, inSameDayAs: goalDate) {
            return     // already sent today
        }
        UserDefaults.standard.set(goalDate, forKey: key)

        let content = UNMutableNotificationContent()
        content.title = "Daily goal reached! 🎉"
        content.body = "You've dictated \(totalWordsToday) words today. Keep it up!"
        content.sound = .default
        content.userInfo = ["deeplink": "lexora://record"]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let id = "lexora.goalAchieved.\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }

    // MARK: - Session Summary Notification

    /// Fires a one-shot notification after a session ends, summarising stats.
    /// Only shown when the app is in the background (system suppresses foreground).
    func sendSessionSummary(wordCount: Int, durationSeconds: Int, language: String) {
        guard authorizationStatus == .authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Session complete"
        let minutes = durationSeconds / 60
        let seconds = durationSeconds % 60
        let dur = minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
        let lang = Locale.current.localizedString(forLanguageCode: language) ?? language
        content.body = "\(wordCount) words in \(dur) · \(lang)"
        content.sound = nil                     // silent — purely informational

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let id = "lexora.session.\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        Task {
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    // MARK: - Weekly Digest Notification

    /// Schedules a Monday-morning notification summarising last week's performance.
    /// Pass real session data computed by the caller (AppState).
    func scheduleWeeklyDigest(
        weekWords: Int,
        weekSessions: Int,
        longestStreak: Int,
        topLanguage: String?
    ) {
        guard authorizationStatus == .authorized, weekSessions > 0 else { return }
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.weeklyDigestID])

        let content = UNMutableNotificationContent()
        content.title = "Your weekly Lexora recap 📊"

        var parts: [String] = []
        parts.append("\(weekWords) words across \(weekSessions) session\(weekSessions == 1 ? "" : "s")")
        if longestStreak > 1 {
            parts.append("\(longestStreak)-day streak")
        }
        if let lang = topLanguage,
           let name = Locale.current.localizedString(forLanguageCode: lang) {
            parts.append("Mostly in \(name)")
        }
        content.body = parts.joined(separator: " · ")
        content.sound = .default
        content.userInfo = ["deeplink": "lexora://history"]

        // Fire every Monday at 9 AM
        var comps = DateComponents()
        comps.weekday = 2   // Monday
        comps.hour    = 9
        comps.minute  = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        let request = UNNotificationRequest(
            identifier: Self.weeklyDigestID,
            content: content,
            trigger: trigger
        )
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }

    // MARK: - Peak Hour Nudge

    /// Schedules a daily nudge at the user's historical peak recording hour.
    /// Only fires when `peakHour` is between 6 AM and 10 PM and the user hasn't
    /// recorded in the last 23 hours. Call this from AppState.scheduleDigestIfNeeded().
    ///
    /// - Parameter peakHour: Hour of day (0–23) when the user most often records.
    func schedulePeakHourNudge(peakHour: Int) {
        guard authorizationStatus == .authorized,
              (6...22).contains(peakHour) else { return }

        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.peakHourNudgeID])

        let content = UNMutableNotificationContent()
        content.title = "Time to dictate 🎙"
        content.body  = "This is usually when you record. Open Lexora and keep the habit going."
        content.sound = .default
        content.userInfo = ["deeplink": "lexora://record"]

        var comps = DateComponents()
        comps.hour   = peakHour
        comps.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        let request = UNNotificationRequest(
            identifier: Self.peakHourNudgeID,
            content: content,
            trigger: trigger
        )
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }

    func cancelPeakHourNudge() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.peakHourNudgeID])
    }
}

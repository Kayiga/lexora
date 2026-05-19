import UIKit

/// Centralised haptic feedback helper.
///
/// Marked `@MainActor` because UIKit feedback generators are main actor-isolated
/// in iOS 18 / Swift 6. All call sites are already on the main actor (SwiftUI
/// view bodies, button actions, onChange handlers), so this adds no extra hops.
///
/// Callers gate on `profile.hapticFeedbackEnabled` before calling; this
/// class itself has no dependency on `UserVoiceProfile` so it can be used
/// from any layer without a circular import.
@MainActor
enum HapticManager {

    // MARK: - Shared generators (created once, reused to avoid first-play latency)

    private static let impact  = UIImpactFeedbackGenerator(style: .medium)
    private static let heavy   = UIImpactFeedbackGenerator(style: .heavy)
    private static let light   = UIImpactFeedbackGenerator(style: .light)
    private static let notify  = UINotificationFeedbackGenerator()
    private static let select  = UISelectionFeedbackGenerator()

    // MARK: - Recording lifecycle

    /// Firm tap — recording begins.
    static func recordingStarted() {
        heavy.prepare()
        heavy.impactOccurred()
    }

    /// Double tap — recording stops.
    static func recordingStopped() {
        heavy.prepare()
        heavy.impactOccurred(intensity: 0.8)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.12))
            heavy.impactOccurred(intensity: 0.4)
        }
    }

    /// Soft bump — recording paused.
    static func recordingPaused() {
        light.prepare()
        light.impactOccurred()
    }

    /// Soft bump — recording resumed.
    static func recordingResumed() {
        light.prepare()
        light.impactOccurred()
    }

    // MARK: - Milestone & success

    /// Celebratory triple-tap when the user hits a word-count milestone.
    static func wordMilestone() {
        notify.prepare()
        notify.notificationOccurred(.success)
    }

    /// Gentle tick for interactive list selection or language lock.
    static func selectionChanged() {
        select.prepare()
        select.selectionChanged()
    }

    /// Error shake — e.g. permission denied.
    static func error() {
        notify.prepare()
        notify.notificationOccurred(.error)
    }

    // MARK: - Goal & achievement

    /// Celebratory burst — user just crossed their daily word goal.
    static func goalAchieved() {
        notify.prepare()
        notify.notificationOccurred(.success)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.18))
            heavy.prepare()
            heavy.impactOccurred(intensity: 0.9)
            try? await Task.sleep(for: .seconds(0.16))
            heavy.impactOccurred(intensity: 0.5)
        }
    }

    /// Subtle confirmation — e.g. star toggled, tag added.
    static func softConfirm() {
        light.prepare()
        light.impactOccurred(intensity: 0.6)
    }
}

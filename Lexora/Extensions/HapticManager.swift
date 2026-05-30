import UIKit

/// Centralised haptic feedback helper.
/// All haptic calls are no-ops on Mac Catalyst (no Taptic Engine).
@MainActor
enum HapticManager {

#if !targetEnvironment(macCatalyst)
    // Shared generators (iOS only — UIFeedbackGenerator unavailable on Mac)
    private static let impact  = UIImpactFeedbackGenerator(style: .medium)
    private static let heavy   = UIImpactFeedbackGenerator(style: .heavy)
    private static let light   = UIImpactFeedbackGenerator(style: .light)
    private static let notify  = UINotificationFeedbackGenerator()
    private static let select  = UISelectionFeedbackGenerator()
#endif

    // MARK: - Recording lifecycle

    static func recordingStarted() {
#if !targetEnvironment(macCatalyst)
        heavy.prepare(); heavy.impactOccurred()
#endif
    }

    static func recordingStopped() {
#if !targetEnvironment(macCatalyst)
        heavy.prepare()
        heavy.impactOccurred(intensity: 0.8)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.12))
            heavy.impactOccurred(intensity: 0.4)
        }
#endif
    }

    static func recordingPaused() {
#if !targetEnvironment(macCatalyst)
        light.prepare(); light.impactOccurred()
#endif
    }

    static func recordingResumed() {
#if !targetEnvironment(macCatalyst)
        light.prepare(); light.impactOccurred()
#endif
    }

    // MARK: - Milestone & success

    static func wordMilestone() {
#if !targetEnvironment(macCatalyst)
        notify.prepare(); notify.notificationOccurred(.success)
#endif
    }

    static func selectionChanged() {
#if !targetEnvironment(macCatalyst)
        select.prepare(); select.selectionChanged()
#endif
    }

    static func error() {
#if !targetEnvironment(macCatalyst)
        notify.prepare(); notify.notificationOccurred(.error)
#endif
    }

    // MARK: - Goal & achievement

    static func goalAchieved() {
#if !targetEnvironment(macCatalyst)
        notify.prepare()
        notify.notificationOccurred(.success)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.18))
            heavy.prepare()
            heavy.impactOccurred(intensity: 0.9)
            try? await Task.sleep(for: .seconds(0.16))
            heavy.impactOccurred(intensity: 0.5)
        }
#endif
    }

    static func softConfirm() {
#if !targetEnvironment(macCatalyst)
        light.prepare(); light.impactOccurred(intensity: 0.6)
#endif
    }
}

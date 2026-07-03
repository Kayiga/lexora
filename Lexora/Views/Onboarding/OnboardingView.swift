import SwiftUI
import Speech
import AVFoundation
import UserNotifications

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @State private var currentStep = 0
    @State private var displayName = ""
    @State private var speechAuthGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
    @State private var micAuthGranted = AVAudioApplication.shared.recordPermission == .granted
    @State private var notifAuthGranted = false

    private let steps = ["Welcome", "Permissions", "Your Name", "Daily Goal", "AI (Optional)", "Ready"]
    @State private var onboardingAPIKey = ""
    @State private var showOnboardingAPIKey = false

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [Color.accentColor.opacity(0.15), Color(.systemBackground)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Progress dots + Skip button
                ZStack {
                    HStack(spacing: 8) {
                        ForEach(0..<steps.count, id: \.self) { i in
                            Capsule()
                                .fill(i <= currentStep ? Color.accentColor : Color(.systemGray4))
                                .frame(width: i == currentStep ? 24 : 8, height: 8)
                                .animation(.spring(response: 0.3), value: currentStep)
                        }
                    }
                    // Skip button — only before the final step
                    if currentStep < steps.count - 1 {
                        HStack {
                            Spacer()
                            Button("Skip") {
                                withAnimation(.spring(response: 0.4)) {
                                    appState.hasCompletedOnboarding = true
                                }
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 60)
                .padding(.horizontal, 28)

                Spacer()

                // Step content
                Group {
                    switch currentStep {
                    case 0: welcomeStep
                    case 1: permissionsStep
                    case 2: nameStep
                    case 3: dailyGoalStep
                    case 4: aiKeyStep
                    default: readyStep
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .id(currentStep)

                Spacer()

                // Navigation
                VStack(spacing: 12) {
                    Button {
                        withAnimation(.spring(response: 0.4)) {
                            if currentStep < steps.count - 1 {
                                // On AI step advance: save key if entered
                                if currentStep == 4 {
                                    let trimmed = onboardingAPIKey.trimmingCharacters(in: .whitespaces)
                                    if !trimmed.isEmpty {
                                        appState.ai.saveKey(trimmed)
                                    }
                                }
                                currentStep += 1
                            } else {
                                if !displayName.isEmpty {
                                    appState.profile.displayName = displayName
                                }
                                appState.hasCompletedOnboarding = true
                            }
                        }
                    } label: {
                        Text(currentStep == steps.count - 1 ? "Start using Lexora" : "Continue")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .disabled(currentStep == 2 && displayName.isEmpty)
                    // Name step requires a non-empty name before advancing

                    if currentStep > 0 {
                        Button("Back") {
                            withAnimation(.spring(response: 0.4)) { currentStep -= 1 }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 48)
            }
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Image(systemName: "waveform.and.person.filled")
                .font(.system(size: 80))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse)

            VStack(spacing: 12) {
                Text("Lexora")
                    .font(.largeTitle.bold())

                Text("Dictation that learns *you*")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    featureBullet(icon: "brain.head.profile", text: "Detects your native language and accent automatically")
                    featureBullet(icon: "globe", text: "Handles code-switching between languages mid-sentence")
                    featureBullet(icon: "sparkles", text: "Gets smarter with every correction you make")
                    // NOTE: switch back to the iCloud-sync bullet once CloudSyncService.cloudSyncEnabled is true.
                    featureBullet(icon: "lock.shield.fill", text: "Private by design — everything stays on your device")
                }
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 32)
    }

    private var permissionsStep: some View {
        VStack(spacing: 24) {
            // Icon — switches to checkmark when all required permissions are granted
            ZStack {
                Circle()
                    .fill(micAuthGranted && speechAuthGranted ? Color.green.opacity(0.12) : Color.accentColor.opacity(0.1))
                    .frame(width: 100, height: 100)
                    .animation(.spring(response: 0.4), value: micAuthGranted && speechAuthGranted)
                Image(systemName: micAuthGranted && speechAuthGranted ? "checkmark.circle.fill" : "mic.badge.plus")
                    .font(.system(size: 48))
                    .foregroundStyle(micAuthGranted && speechAuthGranted ? Color.green : Color.accentColor)
                    .symbolEffect(.bounce, value: micAuthGranted && speechAuthGranted)
                    .contentTransition(.symbolEffect(.replace))
            }

            VStack(spacing: 8) {
                Text("A few permissions needed")
                    .font(.title2.bold())
                Text("All audio processing stays on your device — nothing leaves without your permission.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                permissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    subtitle: "To listen to your voice",
                    granted: micAuthGranted,
                    action: {
                        AVAudioApplication.requestRecordPermission { granted in
                            Task { @MainActor in micAuthGranted = granted }
                        }
                    }
                )

                permissionRow(
                    icon: "waveform",
                    title: "Speech Recognition",
                    subtitle: "To transcribe your words on-device",
                    granted: speechAuthGranted,
                    action: {
                        SFSpeechRecognizer.requestAuthorization { status in
                            Task { @MainActor in speechAuthGranted = status == .authorized }
                        }
                    }
                )

                permissionRow(
                    icon: "bell.fill",
                    title: "Notifications",
                    subtitle: "Optional: daily reminders & session summaries",
                    granted: notifAuthGranted,
                    optional: true,
                    action: {
                        Task {
                            let granted = try? await UNUserNotificationCenter.current()
                                .requestAuthorization(options: [.alert, .sound, .badge])
                            await MainActor.run { notifAuthGranted = granted ?? false }
                        }
                    }
                )
            }

            // Readiness banner — shown only when both required permissions are granted
            if micAuthGranted && speechAuthGranted {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("You're ready to record! Tap Continue.")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                // Progress indicator: X of 2 required permissions granted
                let granted = (micAuthGranted ? 1 : 0) + (speechAuthGranted ? 1 : 0)
                HStack(spacing: 6) {
                    ForEach(0..<2, id: \.self) { i in
                        Capsule()
                            .fill(i < granted ? Color.accentColor : Color(.systemGray4))
                            .frame(height: 4)
                            .animation(.snappy, value: granted)
                    }
                }
                .frame(maxWidth: 80)

                Text("\(granted) of 2 required permissions granted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.4), value: micAuthGranted && speechAuthGranted)
        .padding(.horizontal, 32)
        .task {
            // Re-check statuses in case the user already granted them before onboarding.
            micAuthGranted    = AVAudioApplication.shared.recordPermission == .granted
            speechAuthGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notifAuthGranted = settings.authorizationStatus == .authorized
        }
    }

    private var nameStep: some View {
        VStack(spacing: 28) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 8) {
                Text("What should we call you?")
                    .font(.title2.bold())
                Text("Used to personalise your experience.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            TextField("Your name", text: $displayName)
                .font(.title3)
                .multilineTextAlignment(.center)
                .textContentType(.name)
                .autocorrectionDisabled()
                .padding(.vertical, 16)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 8)
        }
        .padding(.horizontal, 32)
    }

    private var dailyGoalStep: some View {
        VStack(spacing: 28) {
            Image(systemName: "target")
                .font(.system(size: 72))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse)

            VStack(spacing: 12) {
                Text("Set a daily word goal")
                    .font(.title2.bold())

                Text("A daily target gives you a visual progress ring and keeps you on track. You can change this anytime in Settings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Goal slider
            VStack(spacing: 16) {
                // Quick-select buttons
                HStack(spacing: 10) {
                    ForEach([0, 100, 250, 500, 1000], id: \.self) { goal in
                        Button {
                            withAnimation(.snappy) {
                                appState.profile.dailyWordGoal = goal
                            }
                        } label: {
                            Text(goal == 0 ? "None" : "\(goal)")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    appState.profile.dailyWordGoal == goal
                                        ? Color.accentColor
                                        : Color(.systemGray5),
                                    in: Capsule()
                                )
                                .foregroundStyle(
                                    appState.profile.dailyWordGoal == goal ? .white : .primary
                                )
                        }
                        .buttonStyle(.plain)
                        .animation(.snappy, value: appState.profile.dailyWordGoal)
                    }
                }

                if appState.profile.dailyWordGoal > 0 {
                    Slider(
                        value: Binding(
                            get: { Double(appState.profile.dailyWordGoal) },
                            set: { appState.profile.dailyWordGoal = Int($0) }
                        ),
                        in: 50...2000,
                        step: 50
                    )
                    Text("\(appState.profile.dailyWordGoal) words / day")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .monospacedDigit()
                }
            }
            .padding(20)
            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(.horizontal, 32)
    }

    private var aiKeyStep: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 100, height: 100)
                Image(systemName: "sparkles")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.pulse)
            }

            VStack(spacing: 8) {
                Text("Optional: AI Insights")
                    .font(.title2.bold())
                Text("Add your OpenAI API key to unlock abstractive summaries, action-item extraction, and follow-up suggestions for your transcripts.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if showOnboardingAPIKey {
                        TextField("sk-...", text: $onboardingAPIKey)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        SecureField("sk-...", text: $onboardingAPIKey)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(.body, design: .monospaced))
                    }
                    Button {
                        showOnboardingAPIKey.toggle()
                    } label: {
                        Image(systemName: showOnboardingAPIKey ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 14))

                Text("Your key is stored in the iOS Keychain and only ever sent to OpenAI when you request an AI action.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Link("Get a free API key at platform.openai.com →",
                     destination: URL(string: "https://platform.openai.com/api-keys")!)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }

            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text("All core features work without a key. You can add one later in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(.horizontal, 32)
    }

    private var readyStep: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green)
                .symbolEffect(.bounce)

            VStack(spacing: 12) {
                Text("You're all set\(displayName.isEmpty ? "" : ", \(displayName)")!")
                    .font(.title2.bold())

                Text("Lexora will get smarter the more you use it. Start by hitting the mic button and speaking naturally.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 8) {
                    tipRow("Speak naturally — don't adjust for the microphone")
                    tipRow("Edit transcripts to teach it your corrections")
                    tipRow("Mix languages freely — it will follow")
                    if appState.ai.hasAPIKey {
                        tipRow("Tap ✦ AI Insights in any session for smart summaries")
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Helpers

    private func featureBullet(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            Text(text).font(.subheadline)
            Spacer()
        }
    }

    private func permissionRow(
        icon: String,
        title: String,
        subtitle: String,
        granted: Bool,
        optional: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .foregroundStyle(optional ? Color.orange : Color.accentColor)
                .frame(width: 32, height: 32)
                .background((optional ? Color.orange : Color.accentColor).opacity(0.1), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title).font(.subheadline.weight(.semibold))
                    if optional {
                        Text("Optional")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button(optional ? "Enable" : "Allow") { action() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 14))
    }

    private func tipRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("·").foregroundStyle(Color.accentColor)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

import SwiftUI
import TipKit
import LocalAuthentication
import Security

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("appLockEnabled") private var appLockEnabled = false
    @AppStorage("recordingCountdownEnabled") private var recordingCountdownEnabled = true
    /// Number of days after which sessions are auto-archived. 0 = disabled.
    @AppStorage("autoArchiveDays") private var autoArchiveDays: Int = 0
    @AppStorage("autoTimeTagEnabled") private var autoTimeTagEnabled = true
    private let dailyGoalTip = DailyGoalTip()
    @AppStorage("transcriptFontSize") private var transcriptFontSize: Double = 16.0
    @State private var showDeleteConfirm = false
    @State private var showFilesExporter = false
    @State private var fileToExport: URL? = nil
    @State private var showClearSessionsConfirm = false
    @State private var showExportSheet = false
    @State private var exportItems: [Any] = []
    @State private var cloudAccountStatus = ""
    @State private var showPaywall = false
    @State private var showRestoreAlert = false
    @State private var restoreMessage = ""
    @State private var isRestoring = false
    @State private var showRedeemSheet = false
    @State private var redeemCode = ""
    @State private var redeemResult: RedeemResultState = .idle

    enum RedeemResultState { case idle, success, alreadyUnlocked, invalid }
    @State private var showProfileImporter = false
    @State private var showImportResultAlert = false
    @State private var importResultMessage = ""

    // AI Features
    @State private var apiKeyInput = ""
    @State private var showAPIKey = false
    @State private var aiKeySaved = false

    private var profile: UserVoiceProfile { appState.profile }
    @AppStorage("accentColorName") private var accentColorName = "default"

    /// When this binary was compiled — read from the executable's modification
    /// date. Lets you verify the device is running a fresh build (key for the
    /// recurring "is my phone on the latest code?" question).
    static let buildDateString: String = {
        let url = Bundle.main.executableURL
        let date = (try? url?.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
            ?? (url.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date })
            ?? Date()
        let df = DateFormatter()
        df.dateFormat = "MMM d, HH:mm"
        return df.string(from: date)
    }()

    var body: some View {
        NavigationStack {
            Form {
                premiumSection
                profileSection
                appearanceSection
                outputSection
                privacySection
                spotlightSection
                notificationsSection
                iCloudSection
                aiSection
                dataSection
                aboutSection
            }
            .sheet(isPresented: $showPaywall) {
                PremiumPaywallView()
                    .environment(appState)
            }
            .navigationTitle("Settings")
            .task {
                // No @MainActor annotation — SwiftUI .task on a @MainActor view already
                // runs on the main actor. Explicit @MainActor in .task {} triggers the
                // same MainActor.assumeIsolated executor bug on macOS 26 beta.
                await DailyGoalTip.weeklyUse.donate()
                guard CloudSyncService.cloudSyncEnabled else {
                    cloudAccountStatus = "Not available yet"
                    return
                }
                let sync = appState.cloudSync
                let status = await sync.checkAccountStatus()
                switch status {
                case .available: cloudAccountStatus = "Signed in"
                case .noAccount: cloudAccountStatus = "No iCloud account"
                case .restricted: cloudAccountStatus = "Restricted"
                case .couldNotDetermine: cloudAccountStatus = "Unknown"
                case .temporarilyUnavailable: cloudAccountStatus = "Temporarily unavailable"
                @unknown default: cloudAccountStatus = "Unknown"
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var premiumSection: some View {
        let store = appState.store
        let isPaid     = store.isPremium
        let inTrial    = store.isInFreeTrial
        let daysLeft   = store.trialDaysRemaining

        if !StoreService.monetizationEnabled {
            // Monetization suspended — every feature is free. Show a simple note,
            // no upgrade / trial / restore / unlock-code UI.
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color(red: 0.56, green: 0.18, blue: 0.82))
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("All features included")
                            .font(.subheadline.weight(.semibold))
                        Text("Everything is unlocked and free.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            } header: {
                Text("Features")
            }
        } else {
        Section {
            if isPaid {
                // Paid subscriber
                HStack(spacing: 12) {
                    Image(systemName: "crown.fill")
                        .foregroundStyle(Color(red: 0.56, green: 0.18, blue: 0.82))
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lexora Premium")
                            .font(.subheadline.weight(.semibold))
                        Text("All features unlocked. Thank you!")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            } else if inTrial {
                // In free trial — show days remaining
                HStack(spacing: 12) {
                    Image(systemName: "gift.fill")
                        .foregroundStyle(daysLeft <= 7 ? .orange : Color(red: 0.56, green: 0.18, blue: 0.82))
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Free trial active")
                            .font(.subheadline.weight(.semibold))
                        Text(daysLeft == 1
                             ? "Last day — all features unlocked"
                             : "\(daysLeft) days remaining — all features unlocked")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if daysLeft <= 14 {
                        // Show upgrade prompt only when getting close
                        Button("Upgrade") { showPaywall = true }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(red: 0.56, green: 0.18, blue: 0.82))
                    }
                }
            } else {
                // Trial expired
                Button {
                    showPaywall = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "crown.fill")
                            .foregroundStyle(Color(red: 0.56, green: 0.18, blue: 0.82))
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Upgrade to Lexora Premium")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("60-day free trial ended · One-time $4.99")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }

            if !isPaid && !store.promoUnlocked {
                Button {
                    Task { await appState.store.restore() }
                } label: {
                    Label("Restore purchase", systemImage: "arrow.clockwise")
                        .foregroundStyle(Color.accentColor)
                }
                .disabled(store.purchaseInProgress)
            }

            // Promo / unlock code entry
            if !isPaid && !store.promoUnlocked {
                Button {
                    redeemCode = ""
                    redeemResult = .idle
                    showRedeemSheet = true
                } label: {
                    Label("Enter unlock code", systemImage: "key.fill")
                        .foregroundStyle(Color.accentColor)
                }
            } else if store.promoUnlocked && !isPaid {
                HStack(spacing: 12) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.orange)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Unlock code active")
                            .font(.subheadline.weight(.semibold))
                        Text("All features permanently unlocked via promo code.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Subscription")
        }
        .sheet(isPresented: $showRedeemSheet) {
            redeemSheet
                .environment(appState)
        }
        }   // end else (monetizationEnabled)
    }

    // MARK: - Redeem Sheet

    private var redeemSheet: some View {
        NavigationStack {
            VStack(spacing: 28) {
                // Icon
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.15))
                        .frame(width: 80, height: 80)
                    Image(systemName: "key.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)
                }
                .padding(.top, 16)

                VStack(spacing: 8) {
                    Text("Enter Unlock Code")
                        .font(.title2.bold())
                    Text("A valid code unlocks all premium features permanently — no payment needed.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                // Input field
                VStack(spacing: 8) {
                    TextField("Unlock code", text: $redeemCode)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .onChange(of: redeemCode) { _, _ in redeemResult = .idle }

                    // Feedback
                    switch redeemResult {
                    case .idle:
                        Color.clear.frame(height: 20)
                    case .success:
                        Label("Code accepted — all features unlocked!", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    case .alreadyUnlocked:
                        Label("Already unlocked with this code.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .invalid:
                        Label("Invalid code. Check for typos and try again.", systemImage: "xmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                }

                // Redeem button
                Button {
                    let result = appState.store.redeemCode(redeemCode)
                    switch result {
                    case .success:        redeemResult = .success
                    case .alreadyUnlocked: redeemResult = .alreadyUnlocked
                    case .invalid:        redeemResult = .invalid
                    }
                    if result == .success {
                        // Auto-dismiss after a short delay on success
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.5))
                            showRedeemSheet = false
                        }
                    }
                } label: {
                    Text("Redeem")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(redeemCode.isEmpty ? Color(.systemGray4) : Color.orange,
                                    in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(redeemCode.isEmpty ? Color(.systemGray) : .white)
                }
                .disabled(redeemCode.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.horizontal, 32)
                .buttonStyle(.plain)

                Spacer()
            }
            .navigationTitle("Unlock Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showRedeemSheet = false }
                }
            }
        }
    }

    private var profileSection: some View {
        Section("Profile") {
            HStack {
                Text("Display name")
                Spacer()
                // Inline editable name
                TextField("Your name", text: Binding(
                    get: { profile.displayName },
                    set: { appState.profile.displayName = $0 }
                ))
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
            }

            LabeledContent("Primary language") {
                Text(Locale.current.localizedString(forLanguageCode: profile.detectedPrimaryLanguage) ?? profile.detectedPrimaryLanguage)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Sessions recorded") {
                Text("\(profile.totalSessionCount)").foregroundStyle(.secondary)
            }

            LabeledContent("Corrections learned") {
                Text("\(profile.correctionHistory.count)").foregroundStyle(.secondary)
            }
        }
    }

    private var appearanceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Accent color")
                    .font(.subheadline)
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5),
                    spacing: 10
                ) {
                    ForEach(accentColorPalette, id: \.name) { pair in
                        Button {
                            accentColorName = pair.name
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(resolveAccentColor(pair.name))
                                    .frame(width: 38, height: 38)
                                if accentColorName == pair.name {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(pair.label)\(accentColorName == pair.name ? ", selected" : "")")
                    }
                }
                .padding(.vertical, 4)

                Text("Tap a color to instantly update the app's accent throughout Lexora.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Appearance")
        }
    }

    private var outputSection: some View {
        Section("Transcription output") {
            Picker("Formality mode", selection: Binding(
                get: { profile.preferredOutputFormality },
                set: { appState.profile.preferredOutputFormality = $0 }
            )) {
                ForEach(FormalityMode.allCases, id: \.self) { mode in
                    VStack(alignment: .leading) {
                        Text(mode.rawValue)
                        Text(mode.description).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(mode)
                }
            }
            .pickerStyle(.navigationLink)

            Toggle("Auto punctuation", isOn: Binding(
                get: { profile.autoPunctuationEnabled },
                set: { appState.profile.autoPunctuationEnabled = $0 }
            ))

            Toggle("Smart correction", isOn: Binding(
                get: { profile.smartCorrectionEnabled },
                set: { appState.profile.smartCorrectionEnabled = $0 }
            ))

            Toggle("Haptic feedback", isOn: Binding(
                get: { profile.hapticFeedbackEnabled },
                set: { appState.profile.hapticFeedbackEnabled = $0 }
            ))

            Toggle("3-2-1 countdown before recording", isOn: $recordingCountdownEnabled)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Confidence threshold")
                    Spacer()
                    Text("\(Int(profile.confidenceThreshold * 100))%")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { profile.confidenceThreshold },
                        set: { appState.profile.confidenceThreshold = $0 }
                    ),
                    in: 0.1...0.9,
                    step: 0.05
                )
                let belowThreshold = appState.sessions.filter {
                    !$0.finalTranscript.isEmpty && $0.confidenceAverage < profile.confidenceThreshold
                }.count
                if belowThreshold > 0 {
                    Text("\(belowThreshold) session\(belowThreshold == 1 ? "" : "s") currently fall below this threshold.")
                        .font(.caption)
                        .foregroundStyle(.orange.opacity(0.9))
                } else {
                    Text("Results below this confidence are flagged as uncertain.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Transcript font size")
                    Spacer()
                    Text("\(Int(transcriptFontSize))pt")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $transcriptFontSize, in: 12...24, step: 1)
                Text("Applies to live transcription and session detail view.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Toggle("Auto-tag with time of day", isOn: $autoTimeTagEnabled)

            NavigationLink {
                CustomTemplatesView()
            } label: {
                HStack {
                    Label("Custom templates", systemImage: "rectangle.3.group.fill")
                    Spacer()
                    let count = profile.customTemplates.count
                    if count > 0 {
                        Text("\(count)").foregroundStyle(.secondary).font(.subheadline)
                    }
                }
            }

            NavigationLink {
                FillerWordsManagerView()
            } label: {
                HStack {
                    Label("Filler words to track", systemImage: "waveform.badge.exclamationmark")
                    Spacer()
                    let total = 9 + profile.customFillerWords.count
                    Text("\(total) words")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            }

            Toggle("Auto-stop on silence", isOn: Binding(
                get: { profile.silenceAutoStopEnabled },
                set: { appState.profile.silenceAutoStopEnabled = $0 }
            ))

            if profile.silenceAutoStopEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Silence timeout")
                        Spacer()
                        Text("\(Int(profile.silenceTimeoutSeconds))s")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: Binding(
                            get: { profile.silenceTimeoutSeconds },
                            set: { appState.profile.silenceTimeoutSeconds = $0 }
                        ),
                        in: 3...60,
                        step: 1
                    )
                    Text("Recording stops automatically after this many seconds of silence.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var spotlightSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { profile.spotlightIndexingEnabled },
                set: { enabled in
                    appState.profile.spotlightIndexingEnabled = enabled
                    if enabled {
                        appState.spotlight.indexAll(appState.sessions)
                    } else {
                        appState.spotlight.deindexAll()
                    }
                }
            )) {
                Label("Spotlight search", systemImage: "magnifyingglass")
            }

            if profile.spotlightIndexingEnabled && !appState.sessions.isEmpty {
                let indexed = appState.sessions.filter { !$0.isArchived && !$0.finalTranscript.isEmpty }.count
                LabeledContent("Indexed sessions") {
                    Text("\(indexed)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } header: {
            Text("Search")
        } footer: {
            Text("When enabled, your transcripts appear in iOS Spotlight search. All indexing is local — no data leaves your device.")
        }
    }

    private var privacySection: some View {
        Section {
            // Biometric app lock
            let ctx = LAContext()
            let canEvaluate = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
            let biometricName: String = {
                switch ctx.biometryType {
                case .faceID:   return "Face ID"
                case .touchID:  return "Touch ID"
                case .opticID:  return "Optic ID"
                default:        return "Biometrics"
                }
            }()

            if canEvaluate {
                Toggle(isOn: $appLockEnabled) {
                    Label("Require \(biometricName) to open", systemImage: "faceid")
                }
            }

            NavigationLink {
                PrivacyDetailView()
            } label: {
                Label("Privacy & data use", systemImage: "lock.shield.fill")
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text("All speech recognition and learning happens on-device. Audio is never sent to a server.")
        }
    }

    private var notificationsSection: some View {
        Section {
            TipView(dailyGoalTip)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

            // Daily word goal
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Daily word goal")
                    Spacer()
                    if profile.dailyWordGoal > 0 {
                        Text("\(profile.dailyWordGoal) words")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        Text("Off")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Slider(
                    value: Binding(
                        get: { Double(profile.dailyWordGoal) },
                        set: { appState.profile.dailyWordGoal = Int($0) }
                    ),
                    in: 0...2000,
                    step: 50
                )
                Text("Get a visual progress ring when you hit your daily target.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Toggle(isOn: Binding(
                get: { profile.dailyReminderEnabled },
                set: { enabled in
                    appState.profile.dailyReminderEnabled = enabled
                    if enabled {
                        Task {
                            await appState.notifications.scheduleDailyReminder(
                                hour: profile.dailyReminderHour,
                                minute: profile.dailyReminderMinute
                            )
                        }
                    } else {
                        appState.notifications.cancelDailyReminder()
                    }
                }
            )) {
                Label("Daily reminder", systemImage: "bell.fill")
            }

            if profile.dailyReminderEnabled {
                DatePicker(
                    "Reminder time",
                    selection: Binding(
                        get: {
                            Calendar.current.date(
                                bySettingHour: profile.dailyReminderHour,
                                minute: profile.dailyReminderMinute,
                                second: 0,
                                of: Date()
                            ) ?? Date()
                        },
                        set: { date in
                            let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                            appState.profile.dailyReminderHour = comps.hour ?? 9
                            appState.profile.dailyReminderMinute = comps.minute ?? 0
                            Task {
                                await appState.notifications.scheduleDailyReminder(
                                    hour: appState.profile.dailyReminderHour,
                                    minute: appState.profile.dailyReminderMinute
                                )
                            }
                        }
                    ),
                    displayedComponents: .hourAndMinute
                )

                // Suggest setting the reminder to the user's most frequent recording hour
                if let label = peakHourLabel, let peak = peakReminderSuggestion {
                    Button {
                        appState.profile.dailyReminderHour = peak
                        appState.profile.dailyReminderMinute = 0
                        Task {
                            await appState.notifications.scheduleDailyReminder(
                                hour: peak, minute: 0
                            )
                        }
                    } label: {
                        Label("Use my peak hour (\(label))", systemImage: "sparkles")
                            .font(.subheadline)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }

            // Daily morning digest
            Toggle(isOn: Binding(
                get: { profile.dailyDigestEnabled },
                set: { enabled in
                    appState.profile.dailyDigestEnabled = enabled
                    if enabled {
                        appState.scheduleDigestIfNeeded()
                    } else {
                        appState.notifications.cancelDailyDigest()
                    }
                }
            )) {
                Label("Morning digest", systemImage: "newspaper.fill")
            }

            if profile.dailyDigestEnabled {
                DatePicker(
                    "Digest time",
                    selection: Binding(
                        get: {
                            Calendar.current.date(
                                bySettingHour: profile.dailyDigestHour,
                                minute: profile.dailyDigestMinute,
                                second: 0,
                                of: Date()
                            ) ?? Date()
                        },
                        set: { date in
                            let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                            appState.profile.dailyDigestHour = comps.hour ?? 8
                            appState.profile.dailyDigestMinute = comps.minute ?? 30
                            appState.scheduleDigestIfNeeded()
                        }
                    ),
                    displayedComponents: .hourAndMinute
                )
            }

            if appState.notifications.authorizationStatus == .denied {
                Label("Notifications are disabled in Settings", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Daily reminder: nudges you to record. Morning digest: a brief summary of yesterday's activity with a link to record.")
        }
    }

    private var iCloudSection: some View {
        Section {
            HStack {
                Label("iCloud status", systemImage: appState.cloudSync.syncState.iconName)
                    .symbolEffect(.pulse, isActive: appState.cloudSync.syncState == .syncing)
                Spacer()
                Text(cloudAccountStatus.isEmpty ? appState.cloudSync.syncState.label : cloudAccountStatus)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let lastSync = appState.cloudSync.lastSyncDate {
                LabeledContent("Last synced") {
                    Text(lastSync.formatted(.relative(presentation: .named)))
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                appState.syncNow()
            } label: {
                Label("Sync now", systemImage: "arrow.triangle.2.circlepath.icloud")
            }
            .disabled(appState.cloudSync.syncState == .syncing)

            Button {
                isRestoring = true
                Task {
                    let count = await appState.restoreSessionsFromCloud()
                    restoreMessage = count == 0
                        ? "All cloud sessions are already on this device."
                        : "Restored \(count) session\(count == 1 ? "" : "s") from iCloud."
                    isRestoring = false
                    showRestoreAlert = true
                }
            } label: {
                HStack {
                    Label("Restore sessions from iCloud", systemImage: "icloud.and.arrow.down")
                    if isRestoring {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(isRestoring || appState.cloudSync.syncState == .syncing)
            .alert("iCloud Restore", isPresented: $showRestoreAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(restoreMessage)
            }
        } header: {
            Text("iCloud Backup")
        } footer: {
            Text("Your voice profile, vocabulary, and correction history sync automatically across your Apple devices.")
        }
    }

    // MARK: - AI Features Section

    private var aiSection: some View {
        let hasKey = appState.ai.hasAPIKey
        return Section {
            // Status row
            HStack(spacing: 10) {
                Image(systemName: hasKey ? "checkmark.seal.fill" : "sparkles")
                    .foregroundStyle(hasKey ? .green : Color.accentColor)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(hasKey ? "AI features enabled" : "Optional: AI-powered summaries")
                        .font(.subheadline.weight(.semibold))
                    Text(hasKey
                         ? "GPT-4o mini — your key, your data"
                         : "Add your OpenAI key to unlock abstractive summaries, action-item extraction, and follow-up suggestions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)

            // Key input
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if showAPIKey {
                        TextField("sk-...", text: $apiKeyInput)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(.subheadline, design: .monospaced))
                    } else {
                        SecureField("sk-...", text: $apiKeyInput)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(.subheadline, design: .monospaced))
                    }
                    Button {
                        showAPIKey.toggle()
                    } label: {
                        Image(systemName: showAPIKey ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 8) {
                    Button {
                        guard !apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        appState.ai.saveKey(apiKeyInput)
                        apiKeyInput = ""
                        aiKeySaved = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            aiKeySaved = false
                        }
                    } label: {
                        Label(aiKeySaved ? "Saved!" : "Save key", systemImage: aiKeySaved ? "checkmark" : "key.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    .tint(aiKeySaved ? .green : .accentColor)

                    if hasKey {
                        Button(role: .destructive) {
                            appState.ai.deleteKey()
                            apiKeyInput = ""
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }
            }

            // Get-a-key link
            if !hasKey {
                Link(destination: URL(string: "https://platform.openai.com/api-keys")!) {
                    Label("Get an OpenAI API key →", systemImage: "arrow.up.right.square")
                        .font(.subheadline)
                }
            }
        } header: {
            Text("AI Features")
        } footer: {
            Text(hasKey
                 ? "Your key is stored in the iOS Keychain. Transcript text is sent to OpenAI only when you explicitly trigger an AI action — never automatically."
                 : "This is entirely optional. All core Lexora features are on-device. AI features send transcript text to OpenAI over TLS. Usage is billed to your own API key at OpenAI's standard rate (~$0.00015 / 1K tokens).")
        }
    }

    private var dataSection: some View {
        Section("Data") {
            LabeledContent("Transcript storage") {
                Text(estimatedStorageLabel)
                    .foregroundStyle(.secondary)
            }

            Button {
                exportData()
            } label: {
                Label("Export voice profile", systemImage: "square.and.arrow.up")
            }

            Button {
                showProfileImporter = true
            } label: {
                Label("Import voice profile", systemImage: "square.and.arrow.down")
            }

            Button {
                exportTranscripts()
            } label: {
                Label("Export transcripts (.txt)", systemImage: "doc.text")
            }
            .disabled(appState.sessions.isEmpty)

            Button {
                if appState.store.isUnlocked { exportTranscriptsPDF() } else { showPaywall = true }
            } label: {
                Label("Export transcripts (PDF)", systemImage: "doc.richtext")
            }
            .disabled(appState.sessions.isEmpty)

            Button {
                exportTranscriptsMarkdown()
            } label: {
                Label("Export transcripts (Markdown)", systemImage: "doc.badge.ellipsis")
            }
            .disabled(appState.sessions.isEmpty)

            Button {
                exportTranscriptsHTML()
            } label: {
                Label("Export transcripts (HTML webpages)", systemImage: "globe")
            }
            .disabled(appState.sessions.isEmpty)

            Button {
                exportObsidianVault()
            } label: {
                Label("Export for Obsidian (Markdown)", systemImage: "note.text")
            }
            .disabled(appState.sessions.isEmpty)

            Button {
                exportTranscriptsSRT()
            } label: {
                Label("Export transcripts (SRT subtitles)", systemImage: "captions.bubble")
            }
            .disabled(appState.sessions.isEmpty)

            Button {
                exportTranscriptsCSV()
            } label: {
                Label("Export sessions (CSV)", systemImage: "tablecells")
            }
            .disabled(appState.sessions.isEmpty)

            Button {
                saveAllTranscriptsToFiles()
            } label: {
                Label("Save all transcripts to Files", systemImage: "folder.badge.plus")
            }
            .disabled(appState.sessions.isEmpty)

            Picker("Auto-archive after", selection: $autoArchiveDays) {
                Text("Never").tag(0)
                Text("30 days").tag(30)
                Text("60 days").tag(60)
                Text("90 days").tag(90)
                Text("180 days").tag(180)
                Text("1 year").tag(365)
            }
            .onChange(of: autoArchiveDays) { _, newDays in
                if newDays > 0 {
                    let archived = appState.autoArchiveSessions(olderThan: newDays)
                    _ = archived   // count available if we want a banner later
                }
            }

            NavigationLink {
                CorrectionsManagerView()
            } label: {
                Label("Manage learned corrections", systemImage: "wand.and.rays")
            }

            Button(role: .destructive) {
                showClearSessionsConfirm = true
            } label: {
                Label("Clear session history", systemImage: "clock.badge.xmark")
                    .foregroundStyle(.red)
            }
            .disabled(appState.sessions.isEmpty)

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Reset voice profile", systemImage: "trash")
                    .foregroundStyle(.red)
            }
        }
        .confirmationDialog(
            "Clear all sessions?",
            isPresented: $showClearSessionsConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear all sessions", role: .destructive) {
                appState.spotlight.deindexAll()
                appState.sessions.removeAll()
            }
        } message: {
            Text("All recorded sessions will be removed from this device. Your voice profile and learned vocabulary are not affected.")
        }
        .confirmationDialog(
            "Reset your voice profile?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset everything", role: .destructive) {
                resetProfile()
            }
        } message: {
            Text("This will delete all learned vocabulary, corrections, and speaking insights. This cannot be undone.")
        }
        .sheet(isPresented: $showExportSheet) {
            ShareSheet(items: exportItems)
                .environment(appState)
        }
        .sheet(isPresented: $showFilesExporter) {
            if let url = fileToExport {
                FilesExporter(url: url) { showFilesExporter = false }
                    .environment(appState)
            }
        }
        .fileImporter(
            isPresented: $showProfileImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importProfile(from: url)
            case .failure:
                importResultMessage = "Could not open file."
                showImportResultAlert = true
            }
        }
        .alert("Profile Import", isPresented: $showImportResultAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importResultMessage)
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version") {
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Build") {
                Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                    .foregroundStyle(.secondary)
            }
            // Compiled-date stamp so you can confirm the device is running a
            // fresh build (reflects when this binary was actually built).
            LabeledContent("Built") {
                Text(Self.buildDateString)
                    .foregroundStyle(.secondary)
                    .font(.caption.monospacedDigit())
            }
            NavigationLink {
                WhatsNewView()
            } label: {
                Label("What's New", systemImage: "sparkles")
            }
            NavigationLink {
                PrivacyDetailView()
            } label: {
                Label("Privacy policy", systemImage: "lock.shield.fill")
            }
            Button {
                let text = "Check out Lexora — voice dictation that learns how you speak!"
                let items: [Any] = [text]
                exportItems = items
                showExportSheet = true
            } label: {
                Label("Share Lexora", systemImage: "heart.fill")
            }
            .foregroundStyle(.pink)
        }
    }

    // MARK: - Actions

    private func exportData() {
        guard let data = try? JSONEncoder().encode(appState.profile),
              let json = String(data: data, encoding: .utf8) else { return }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lexora_profile_\(Date().formatted(.iso8601)).json")
        try? json.write(to: url, atomically: true, encoding: .utf8)
        exportItems = [url]
        showExportSheet = true
    }

    private func exportObsidianVault() {
        let isoDate = ISO8601DateFormatter()
        isoDate.formatOptions = [.withFullDate]
        let humanDF = DateFormatter()
        humanDF.dateStyle = .medium; humanDF.timeStyle = .short

        var urls: [URL] = []
        for s in appState.sessions {
            let dateStr = isoDate.string(from: s.startedAt)
            let titleStr: String
            if let t = s.customTitle, !t.isEmpty {
                titleStr = t
            } else {
                titleStr = String(s.finalTranscript.prefix(50))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
            }

            // Obsidian YAML frontmatter
            let lang = Locale.current.localizedString(forLanguageCode: s.primaryLanguage) ?? s.primaryLanguage
            let tagsYAML = s.tags.map { "  - \($0)" }.joined(separator: "\n")
            let frontmatter = """
            ---
            created: \(dateStr)
            source: Lexora
            language: \(lang)
            words: \(s.wordCount)
            duration: \(Int(s.durationSeconds))s
            tags:
            \(tagsYAML.isEmpty ? "  - lexora" : tagsYAML)
            ---
            """

            // Wikilink tag line (Obsidian style)
            let tagLine = s.tags.isEmpty ? "#lexora" : s.tags.map { "#\($0)" }.joined(separator: " ")
            let chapterLines: String
            if !s.chapters.isEmpty {
                let sorted = s.chapters.sorted { $0.offset < $1.offset }
                chapterLines = "\n## Table of Contents\n" + sorted.enumerated().map { i, ch in
                    "- [[#\(ch.title)]]"
                }.joined(separator: "\n")
            } else { chapterLines = "" }

            let notesSection = s.notes.map { "\n## Notes\n\($0)" } ?? ""

            let md = """
            \(frontmatter)

            # \(titleStr)

            \(tagLine)\(chapterLines)

            ## Transcript

            \(s.finalTranscript.isEmpty ? "_Empty transcript_" : s.finalTranscript)
            \(notesSection)
            """

            let fileName = "\(dateStr) \(titleStr.prefix(40)).md"
                .replacingOccurrences(of: ":", with: "-")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            if (try? md.write(to: url, atomically: true, encoding: .utf8)) != nil {
                urls.append(url)
            }
        }
        guard !urls.isEmpty else { return }
        exportItems = urls
        showExportSheet = true
    }

    private func exportTranscriptsHTML() {
        // Export each session as its own .html file and share them all together
        var urls: [URL] = []
        for session in appState.sessions {
            if let url = HTMLExportService.exportSession(session) {
                urls.append(url)
            }
        }
        guard !urls.isEmpty else { return }
        exportItems = urls
        showExportSheet = true
    }

    private func exportTranscriptsSRT() {
        // Each session becomes a separate SRT file; zip them together if there are multiple.
        // For simplicity, export a single concatenated SRT with session-title comments.
        let df = DateFormatter()
        df.dateStyle = .medium; df.timeStyle = .short

        var allCues: [String] = []
        var globalIndex = 1

        for session in appState.sessions.sorted(by: { $0.startedAt > $1.startedAt }) {
            guard let url = SRTExportService.exportSession(session),
                  let content = try? String(contentsOf: url, encoding: .utf8),
                  !content.isEmpty else { continue }

            let header = "NOTE \(session.customTitle ?? df.string(from: session.startedAt))\n"
            // Re-number cues to be globally sequential
            let renumbered = content.components(separatedBy: "\n\n").compactMap { block -> String? in
                guard !block.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                var lines = block.components(separatedBy: "\n")
                if let _ = Int(lines.first ?? "") {
                    lines[0] = "\(globalIndex)"
                    globalIndex += 1
                }
                return lines.joined(separator: "\n")
            }.joined(separator: "\n\n")

            allCues.append(header + renumbered)
        }

        guard !allCues.isEmpty else { return }
        let combined = allCues.joined(separator: "\n\n")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lexora_subtitles_\(Date().formatted(.iso8601)).srt")
        try? combined.write(to: url, atomically: true, encoding: .utf8)
        exportItems = [url]
        showExportSheet = true
    }

    private func exportTranscriptsPDF() {
        guard let url = PDFExportService.exportSessions(appState.sessions) else { return }
        exportItems = [url]
        showExportSheet = true
    }

    private func exportTranscriptsMarkdown() {
        let isoDF = ISO8601DateFormatter()
        isoDF.formatOptions = [.withFullDate]       // YYYY-MM-DD for frontmatter
        let humanDF = DateFormatter()
        humanDF.dateStyle = .medium
        humanDF.timeStyle = .short

        let pages: [String] = appState.sessions.map { session in
            let title = session.customTitle?.isEmpty == false
                ? session.customTitle!
                : String(session.finalTranscript.prefix(60))
            let tagsYAML = session.tags.isEmpty
                ? "[]"
                : "[" + session.tags.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
            let accLine = session.estimatedAccuracy > 0
                ? "\naccuracy: \(Int(session.estimatedAccuracy))" : ""
            let wpmLine = session.paceWPM > 0
                ? "\nwpm: \(Int(session.paceWPM))" : ""

            // YAML frontmatter
            let frontmatter = """
            ---
            title: "\(title.replacingOccurrences(of: "\"", with: "'"))"
            date: \(isoDF.string(from: session.startedAt))
            language: \(session.primaryLanguage)
            words: \(session.wordCount)
            duration: \(Int(session.durationSeconds))
            tags: \(tagsYAML)\(accLine)\(wpmLine)
            ---
            """

            let body = session.finalTranscript.isEmpty ? "\n*(empty)*" : "\n\n" + session.finalTranscript
            return frontmatter + body
        }

        let header = "# Lexora Transcripts\n\n> Exported \(humanDF.string(from: Date()))\n\n"
        let md = header + pages.joined(separator: "\n\n---\n\n")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lexora_transcripts_\(Date().formatted(.iso8601)).md")
        try? md.write(to: url, atomically: true, encoding: .utf8)
        exportItems = [url]
        showExportSheet = true
    }

    /// Exports all sessions as a single CSV file with one row per session.
    private func exportTranscriptsCSV() {
        var rows: [String] = [
            "\"Date\",\"Title\",\"Language\",\"Words\",\"Duration (s)\",\"WPM\",\"Accuracy (%)\",\"Tags\",\"Transcript\""
        ]
        let df = ISO8601DateFormatter()
        for s in appState.sessions {
            func csvEscape(_ str: String) -> String {
                let escaped = str.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\""
            }
            let lang = Locale.current.localizedString(forLanguageCode: s.primaryLanguage) ?? s.primaryLanguage
            let wpm  = s.paceWPM > 0 ? String(format: "%.0f", s.paceWPM) : ""
            let acc  = s.estimatedAccuracy > 0 ? "\(Int(s.estimatedAccuracy))" : ""
            let tags = s.tags.joined(separator: "; ")
            let row = [
                csvEscape(df.string(from: s.startedAt)),
                csvEscape(s.customTitle ?? ""),
                csvEscape(lang),
                "\(s.wordCount)",
                String(format: "%.0f", s.durationSeconds),
                wpm,
                acc,
                csvEscape(tags),
                csvEscape(s.finalTranscript)
            ].joined(separator: ",")
            rows.append(row)
        }
        let csv = rows.joined(separator: "\n")
        let stamp = Date().formatted(.dateTime.year().month().day())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lexora_sessions_\(stamp).csv")
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        exportItems = [url]
        showExportSheet = true
    }

    private func exportTranscripts() {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short

        let lines: [String] = appState.sessions.map { session in
            let date = df.string(from: session.startedAt)
            let words = session.wordCount
            let lang = Locale.current.localizedString(forLanguageCode: session.primaryLanguage)
                       ?? session.primaryLanguage
            return "[\(date)] [\(lang)] [\(words) words]\n\(session.finalTranscript.isEmpty ? "(empty)" : session.finalTranscript)"
        }

        let text = lines.joined(separator: "\n\n---\n\n")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lexora_transcripts_\(Date().formatted(.iso8601)).txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        exportItems = [url]
        showExportSheet = true
    }

    /// Saves all transcripts as a single .txt file and opens the Files picker.
    private func saveAllTranscriptsToFiles() {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short

        let lines: [String] = appState.sessions.map { s in
            let date = df.string(from: s.startedAt)
            let lang = Locale.current.localizedString(forLanguageCode: s.primaryLanguage) ?? s.primaryLanguage
            let header = "[\(date)] [\(lang)] [\(s.wordCount) words]"
            let body   = s.finalTranscript.isEmpty ? "(empty)" : s.finalTranscript
            return "\(header)\n\(body)"
        }
        let text = lines.joined(separator: "\n\n---\n\n")
        let stamp = Date().formatted(.dateTime.year().month().day())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lexora_Transcripts_\(stamp).txt")
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        fileToExport = url
        showFilesExporter = true
    }

    private func importProfile(from url: URL) {
        // Security-scoped resource access is required for files opened via the importer
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url),
              let imported = try? JSONDecoder().decode(UserVoiceProfile.self, from: data) else {
            importResultMessage = "The file doesn't appear to be a valid Lexora profile."
            showImportResultAlert = true
            return
        }

        // Merge: imported profile wins for display name and preferences,
        // but we union the vocabulary and correction history.
        var current = appState.profile
        let existingTerms = Set(current.customVocabulary.map { $0.term.lowercased() })
        let newEntries = imported.customVocabulary.filter { !existingTerms.contains($0.term.lowercased()) }
        current.customVocabulary.append(contentsOf: newEntries)

        let existingIDs = Set(current.correctionHistory.map { $0.id })
        let newCorrections = imported.correctionHistory.filter { !existingIDs.contains($0.id) }
        current.correctionHistory.append(contentsOf: newCorrections)

        for (k, v) in imported.phonemeSubstitutions { current.phonemeSubstitutions[k] = v }

        current.touch()
        appState.learningEngine.profile = current
        appState.storage.save(current)

        let added = newEntries.count
        importResultMessage = added == 0
            ? "Profile imported. No new vocabulary to add — your current profile is already up to date."
            : "Profile imported successfully. Added \(added) new vocabulary entr\(added == 1 ? "y" : "ies")."
        showImportResultAlert = true
    }

    /// The hour-of-day the user most frequently starts recordings (nil if < 5 sessions).
    private var peakReminderSuggestion: Int? {
        guard appState.sessions.count >= 5 else { return nil }
        let cal = Calendar.current
        var hourCounts = [Int: Int]()
        for session in appState.sessions {
            let h = cal.component(.hour, from: session.startedAt)
            hourCounts[h, default: 0] += 1
        }
        return hourCounts.max(by: { $0.value < $1.value })?.key
    }

    /// Formatted label for the peak recording hour (e.g. "9 AM").
    /// Computed outside @ViewBuilder to avoid statement restrictions.
    private var peakHourLabel: String? {
        guard let peak = peakReminderSuggestion, peak != profile.dailyReminderHour else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "h a"
        var c = DateComponents(); c.hour = peak; c.minute = 0
        return fmt.string(from: Calendar.current.date(from: c) ?? Date())
    }

    /// Estimated bytes of transcript text stored locally across all sessions.
    private var estimatedStorageLabel: String {
        let bytes = appState.sessions.reduce(0) { total, s in
            let a = s.finalTranscript.data(using: .utf8)?.count ?? 0
            let b = s.rawTranscript.data(using: .utf8)?.count ?? 0
            let c = s.notes?.data(using: .utf8)?.count ?? 0
            return total + a + b + c
        }
        if bytes == 0 { return "0 KB" }
        let mb = Double(bytes) / 1_048_576.0
        if mb >= 1.0 { return String(format: "%.1f MB", mb) }
        let kb = max(1, bytes / 1024)
        return "\(kb) KB"
    }

    private func resetProfile() {
        let fresh = UserVoiceProfile(displayName: appState.profile.displayName)
        appState.learningEngine.profile.customVocabulary = []
        appState.learningEngine.profile.correctionHistory = []
        appState.learningEngine.profile.phonemeSubstitutions = [:]
        appState.learningEngine.profile.accuracyTrend = []
        appState.learningEngine.profile.totalSessionCount = 0
        appState.learningEngine.profile.totalTranscriptionMinutes = 0
        appState.learningEngine.profile.touch()
        _ = fresh
    }
}

struct PrivacyDetailView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                privacyItem(
                    icon: "mic.slash.fill",
                    title: "Audio never leaves your device",
                    body: "Speech recognition runs entirely on-device using Apple's Speech framework. Your audio is never sent to any server."
                )
                privacyItem(
                    icon: "brain.head.profile",
                    title: "Learning happens locally",
                    body: "The learning engine stores your vocabulary and corrections in a local database. It never sends your speech patterns to the cloud."
                )
                privacyItem(
                    icon: "icloud.fill",
                    title: "iCloud stores only metadata",
                    body: "When you back up to iCloud, only your vocabulary list, correction events, and profile preferences are synced — never audio recordings."
                )
                privacyItem(
                    icon: "lock.fill",
                    title: "iCloud data is end-to-end encrypted",
                    body: "Your profile data in CloudKit's private database is encrypted at rest and in transit. Apple cannot read it."
                )
                privacyItem(
                    icon: "key.fill",
                    title: "Optional AI features are opt-in only",
                    body: "If you choose to enable AI summaries, transcript text is sent to OpenAI over TLS using your own API key. No audio is ever sent. This feature is never active without your explicit action."
                )
            }
            .padding(24)
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.large)
    }

    private func privacyItem(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(body).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - What's New

private struct WhatsNewEntry: Identifiable {
    var id: String { version + title }
    var version: String
    var title: String
    var body: String
    var icon: String
    var tint: Color
}

struct WhatsNewView: View {
    private static let entries: [WhatsNewEntry] = [
        WhatsNewEntry(version: "2.0", title: "AI Insights", body: "Optional GPT-4o mini integration delivers abstractive summaries, action-item extraction, and follow-up suggestions for any transcript. Bring your own OpenAI key — stored securely in the iOS Keychain.", icon: "sparkles", tint: .indigo),
        WhatsNewEntry(version: "2.0", title: "Share as Webpage", body: "Export any transcript as a beautiful, self-contained HTML file — dark-mode aware, print-ready, and shareable via any app.", icon: "globe", tint: .blue),
        WhatsNewEntry(version: "2.0", title: "Smart Notifications", body: "Weekly digest every Monday morning, peak-hour nudge at your historically most active time, and a richer daily morning brief.", icon: "bell.badge.fill", tint: .orange),
        WhatsNewEntry(version: "2.0", title: "Reading Mode", body: "Open any transcript in a distraction-free reader with adjustable font size, line spacing, and a reading-progress bar.", icon: "text.magnifyingglass", tint: .teal),
        WhatsNewEntry(version: "2.0", title: "Focus Timer", body: "Set a 5–60 minute countdown in the recording screen. Lexora pauses automatically when time is up.", icon: "timer", tint: .red),
        WhatsNewEntry(version: "2.0", title: "Keyboard Extension", body: "Dictate directly from any text field system-wide using the Lexora keyboard. Sessions save back to the app automatically.", icon: "keyboard.fill", tint: .green),
        WhatsNewEntry(version: "2.0", title: "Siri Shortcuts", body: "Star sessions, set your daily goal, query word counts, and export transcripts — all from Siri or the Shortcuts app.", icon: "mic.badge.plus", tint: .purple),
        WhatsNewEntry(version: "1.5", title: "Vocabulary Study Mode", body: "Flashcard-style practice for your custom vocabulary, complete with 3D flip animations and a session score.", icon: "rectangle.on.rectangle.angled", tint: .purple),
        WhatsNewEntry(version: "1.5", title: "Bulk Paste Import", body: "Paste a comma- or line-separated word list to import your vocabulary in seconds.", icon: "doc.on.clipboard", tint: .teal),
        WhatsNewEntry(version: "1.5", title: "Vocabulary Pronunciation Preview", body: "Tap the speaker icon on any vocabulary entry to hear it spoken in the correct language.", icon: "speaker.wave.2.fill", tint: .blue),
        WhatsNewEntry(version: "1.4", title: "Session Comparison", body: "Select exactly two sessions in History and compare them side-by-side — words, pace, confidence, and more.", icon: "chart.bar.xaxis.ascending.badge.clock", tint: .indigo),
        WhatsNewEntry(version: "1.4", title: "Transcript Bookmarks", body: "Tap the bookmark button during recording to drop a timestamped marker. They appear as a scannable panel in the session detail.", icon: "bookmark.fill", tint: .yellow),
        WhatsNewEntry(version: "1.4", title: "CSV & JSON Bulk Export", body: "Select multiple sessions in History and export them as a spreadsheet or structured JSON file.", icon: "tablecells", tint: .green),
        WhatsNewEntry(version: "1.3", title: "Live Filler Word Counter", body: "The recording screen now shows a real-time count of filler words (um, uh, like…) so you can self-correct on the fly.", icon: "waveform.badge.exclamationmark", tint: .orange),
        WhatsNewEntry(version: "1.3", title: "Smart Recurrence Suggestions", body: "Lexora detects your regular recording habits and suggests the right template before you even tap Record.", icon: "sparkles", tint: .purple),
        WhatsNewEntry(version: "1.3", title: "Pinned Sessions Carousel", body: "Pin your most important sessions and access them instantly from the Dashboard home screen.", icon: "pin.fill", tint: .orange),
        WhatsNewEntry(version: "1.2", title: "Goal Visualisation in Analytics", body: "A dashed goal line now appears on the Word Volume chart, and goal-achievement days are highlighted in green.", icon: "target", tint: .green),
        WhatsNewEntry(version: "1.2", title: "Template Performance Chart", body: "See average word count and confidence per recording template to find your most productive contexts.", icon: "chart.bar.fill", tint: .blue),
        WhatsNewEntry(version: "1.2", title: "iPad Split-View Layout", body: "Lexora now adapts to a sidebar + detail navigation on iPad for a more spacious, keyboard-friendly experience.", icon: "sidebar.leading", tint: .indigo),
        WhatsNewEntry(version: "1.1", title: "iCloud Backup & Restore", body: "Your voice profile, vocabulary, and learned corrections sync seamlessly across all your Apple devices.", icon: "icloud.fill", tint: .blue),
        WhatsNewEntry(version: "1.1", title: "Biometric App Lock", body: "Protect your transcripts with Face ID, Touch ID, or Optic ID.", icon: "faceid", tint: .teal),
        WhatsNewEntry(version: "1.0", title: "Lexora Launches", body: "On-device voice dictation that learns your vocabulary, corrects itself over time, and never sends your audio to a server.", icon: "waveform.and.person.filled", tint: .purple),
    ]

    private var entriesByVersion: [(version: String, entries: [WhatsNewEntry])] {
        let grouped = Dictionary(grouping: Self.entries) { $0.version }
        return grouped
            .map { (version: $0.key, entries: $0.value) }
            .sorted { lhs, rhs in
                let l = lhs.version.split(separator: ".").compactMap { Int($0) }
                let r = rhs.version.split(separator: ".").compactMap { Int($0) }
                return (l.first ?? 0, l.last ?? 0) > (r.first ?? 0, r.last ?? 0)
            }
    }

    var body: some View {
        List {
            ForEach(entriesByVersion, id: \.version) { group in
                Section {
                    ForEach(group.entries) { entry in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: entry.icon)
                                .font(.title3)
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(entry.tint, in: RoundedRectangle(cornerRadius: 10))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.title)
                                    .font(.subheadline.weight(.semibold))
                                Text(entry.body)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Version \(group.version)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("What's New")
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - Corrections Manager

/// Lists every word substitution the learning engine has picked up, lets users
/// delete individual entries or wipe all corrections in one tap.
struct CorrectionsManagerView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var showClearConfirm = false

    private var substitutions: [(wrong: String, correct: String)] {
        appState.profile.phonemeSubstitutions
            .filter { pair in
                searchText.isEmpty
                    || pair.key.localizedCaseInsensitiveContains(searchText)
                    || pair.value.localizedCaseInsensitiveContains(searchText)
            }
            .map { (wrong: $0.key, correct: $0.value) }
            .sorted { $0.wrong < $1.wrong }
    }

    var body: some View {
        List {
            if substitutions.isEmpty && appState.profile.phonemeSubstitutions.isEmpty {
                ContentUnavailableView(
                    "No corrections yet",
                    systemImage: "wand.and.rays",
                    description: Text("When you correct a transcript, Lexora learns the substitution and applies it automatically in future sessions.")
                )
            } else if substitutions.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                Section {
                    ForEach(substitutions, id: \.wrong) { pair in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pair.wrong)
                                    .font(.subheadline)
                                    .foregroundStyle(.red.opacity(0.85))
                                    .strikethrough(true, color: .red.opacity(0.5))
                                Text(pair.correct)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                            }
                            Spacer()
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                appState.profile.phonemeSubstitutions.removeValue(forKey: pair.wrong)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("\(appState.profile.phonemeSubstitutions.count) learned substitution\(appState.profile.phonemeSubstitutions.count == 1 ? "" : "s")")
                } footer: {
                    Text("Swipe left to remove a substitution. Removed substitutions won't be re-applied, but won't be re-learned until you make the same correction again.")
                }
            }
        }
        .navigationTitle("Learned Corrections")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "Search corrections")
        .toolbar {
            if !appState.profile.phonemeSubstitutions.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Text("Clear all")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .confirmationDialog(
            "Clear all learned corrections?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear all corrections", role: .destructive) {
                appState.profile.phonemeSubstitutions = [:]
            }
        } message: {
            Text("Lexora will stop auto-applying these corrections. This cannot be undone.")
        }
    }
}

// MARK: - Custom Templates View

/// Lists user-defined recording templates and lets the user add, edit, or delete them.
struct CustomTemplatesView: View {
    @Environment(AppState.self) private var appState
    @State private var showingEditor = false
    @State private var templateToEdit: CustomRecordingTemplate? = nil

    var body: some View {
        List {
            if appState.profile.customTemplates.isEmpty {
                ContentUnavailableView(
                    "No custom templates",
                    systemImage: "rectangle.3.group.fill",
                    description: Text("Create templates to pre-configure language, formality, and tags for your most common recording situations.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(appState.profile.customTemplates) { template in
                        Button {
                            templateToEdit = template
                            showingEditor = true
                        } label: {
                            CustomTemplateRow(template: template)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                appState.profile.customTemplates.removeAll { $0.id == template.id }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onMove { from, to in
                        appState.profile.customTemplates.move(fromOffsets: from, toOffset: to)
                    }
                } footer: {
                    Text("These templates appear in the recording screen alongside the built-in ones. Swipe to delete; drag to reorder.")
                }
            }
        }
        .navigationTitle("Custom Templates")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    templateToEdit = nil
                    showingEditor = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingEditor) {
            CustomTemplateEditView(existingTemplate: templateToEdit)
                .environment(appState)
        }
    }
}

struct CustomTemplateRow: View {
    var template: CustomRecordingTemplate

    private var chipColor: Color { CustomTemplateEditView.color(for: template.colorName) }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: template.icon)
                .font(.body)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(chipColor, in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 3) {
                Text(template.name)
                    .font(.subheadline.weight(.semibold))

                HStack(spacing: 6) {
                    if let formality = template.formality {
                        Text(formality.rawValue)
                            .font(.caption2)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color(.systemGray5), in: Capsule())
                    }
                    if let lang = template.defaultLanguage,
                       let name = Locale.current.localizedString(forLanguageCode: lang) {
                        Text(name)
                            .font(.caption2)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color(.systemGray5), in: Capsule())
                    }
                    if !template.defaultTags.isEmpty {
                        Text(template.defaultTags.prefix(2).joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Custom Template Editor

struct CustomTemplateEditView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var existingTemplate: CustomRecordingTemplate?

    @State private var name: String
    @State private var icon: String
    @State private var colorName: String
    @State private var formality: FormalityMode?
    @State private var defaultLanguage: String?
    @State private var tagInput: String
    @State private var defaultTags: [String]
    @State private var recordingPrompt: String

    init(existingTemplate: CustomRecordingTemplate?) {
        self.existingTemplate = existingTemplate
        _name            = State(initialValue: existingTemplate?.name             ?? "")
        _icon            = State(initialValue: existingTemplate?.icon             ?? "mic.fill")
        _colorName       = State(initialValue: existingTemplate?.colorName        ?? "blue")
        _formality       = State(initialValue: existingTemplate?.formality)
        _defaultLanguage = State(initialValue: existingTemplate?.defaultLanguage)
        _tagInput        = State(initialValue: "")
        _defaultTags     = State(initialValue: existingTemplate?.defaultTags      ?? [])
        _recordingPrompt = State(initialValue: existingTemplate?.recordingPrompt  ?? "")
    }

    private let availableLanguages: [(code: String, label: String)] = [
        ("en-US", "English (US)"), ("en-GB", "English (UK)"),
        ("es-ES", "Spanish"), ("fr-FR", "French"), ("de-DE", "German"),
        ("it-IT", "Italian"), ("pt-BR", "Portuguese"), ("ja-JP", "Japanese"),
        ("zh-CN", "Chinese (Simplified)"), ("ko-KR", "Korean"),
        ("ar-SA", "Arabic"), ("ru-RU", "Russian")
    ]

    static func color(for name: String) -> Color {
        switch name {
        case "red":    return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green":  return .green
        case "teal":   return .teal
        case "blue":   return .blue
        case "indigo": return .indigo
        case "purple": return .purple
        case "pink":   return .pink
        default:       return .accentColor
        }
    }

    private var isValid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                // Preview chip
                Section {
                    HStack {
                        Spacer()
                        HStack(spacing: 6) {
                            Image(systemName: icon).font(.caption2)
                            Text(name.isEmpty ? "Template name" : name)
                                .font(.caption.weight(.medium))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Self.color(for: colorName), in: Capsule())
                        .foregroundStyle(.white)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                Section("Name") {
                    TextField("Template name", text: $name)
                        .autocorrectionDisabled()
                }

                Section("Icon") {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5),
                        spacing: 8
                    ) {
                        ForEach(CustomRecordingTemplate.availableIcons, id: \.self) { sym in
                            Button {
                                icon = sym
                            } label: {
                                Image(systemName: sym)
                                    .font(.body)
                                    .frame(width: 44, height: 44)
                                    .background(
                                        icon == sym
                                            ? Self.color(for: colorName)
                                            : Color(.systemGray5),
                                        in: RoundedRectangle(cornerRadius: 10)
                                    )
                                    .foregroundStyle(icon == sym ? Color.white : Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Color") {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5),
                        spacing: 8
                    ) {
                        ForEach(CustomRecordingTemplate.availableColors, id: \.name) { pair in
                            Button {
                                colorName = pair.name
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(Self.color(for: pair.name))
                                        .frame(width: 36, height: 36)
                                    if colorName == pair.name {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Formality override") {
                    Picker("Formality", selection: $formality) {
                        Text("Use profile default").tag(Optional<FormalityMode>.none)
                        ForEach(FormalityMode.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(Optional(m))
                        }
                    }
                }

                Section("Language override") {
                    Picker("Language", selection: $defaultLanguage) {
                        Text("Auto-detect").tag(Optional<String>.none)
                        ForEach(availableLanguages, id: \.code) { lang in
                            Text(lang.label).tag(Optional(lang.code))
                        }
                    }
                }

                Section {
                    HStack {
                        TextField("Add tag…", text: $tagInput)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit { addTag() }
                        Button("Add", action: addTag)
                            .disabled(tagInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if !defaultTags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(defaultTags, id: \.self) { tag in
                                    HStack(spacing: 4) {
                                        Text(tag)
                                            .font(.caption.weight(.medium))
                                        Button {
                                            defaultTags.removeAll { $0 == tag }
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 8, weight: .bold))
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color(.systemGray5), in: Capsule())
                                    .foregroundStyle(.primary)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Auto-apply tags")
                } footer: {
                    Text("These tags are automatically added to every session recorded with this template.")
                }

                Section {
                    TextEditor(text: $recordingPrompt)
                        .frame(minHeight: 80)
                        .font(.subheadline)
                } header: {
                    Text("Pre-recording prompt (optional)")
                } footer: {
                    Text("This text appears as a checklist or reminder before you tap Record. Leave blank to skip.")
                }
            }
            .navigationTitle(existingTemplate == nil ? "New Template" : "Edit Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isValid)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func addTag() {
        let trimmed = tagInput.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty, !defaultTags.contains(trimmed) else { return }
        defaultTags.append(trimmed)
        tagInput = ""
    }

    private func save() {
        var template = existingTemplate ?? CustomRecordingTemplate(
            name: "", icon: "mic.fill", colorName: "blue", defaultTags: []
        )
        template.name            = name.trimmingCharacters(in: .whitespaces)
        template.icon            = icon
        template.colorName       = colorName
        template.formality       = formality
        template.defaultLanguage = defaultLanguage
        template.defaultTags     = defaultTags
        let promptTrimmed = recordingPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        template.recordingPrompt = promptTrimmed.isEmpty ? nil : promptTrimmed

        if let existing = existingTemplate,
           let idx = appState.profile.customTemplates.firstIndex(where: { $0.id == existing.id }) {
            appState.profile.customTemplates[idx] = template
        } else {
            appState.profile.customTemplates.append(template)
        }
        dismiss()
    }
}

// MARK: - Filler Words Manager

/// Shows built-in filler words (read-only) and lets the user add/remove custom ones.
struct FillerWordsManagerView: View {
    @Environment(AppState.self) private var appState
    @State private var newWord = ""
    @FocusState private var fieldFocused: Bool

    private let builtIn = ["um", "uh", "like", "you know", "i mean",
                           "basically", "literally", "actually", "so"]

    var body: some View {
        List {
            Section {
                ForEach(builtIn, id: \.self) { word in
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text(word)
                            .font(.subheadline)
                        Spacer()
                        Text("built-in")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Built-in (\(builtIn.count))")
            } footer: {
                Text("These are always tracked. They cannot be removed.")
            }

            Section {
                HStack {
                    TextField("Add word or phrase…", text: $newWord)
                        .focused($fieldFocused)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { addWord() }
                    Button("Add", action: addWord)
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                ForEach(appState.profile.customFillerWords, id: \.self) { word in
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .font(.caption)
                        Text(word)
                            .font(.subheadline)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            appState.profile.customFillerWords.removeAll { $0 == word }
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                }

                if appState.profile.customFillerWords.isEmpty {
                    Text("No custom words yet.")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            } header: {
                Text("Custom (\(appState.profile.customFillerWords.count))")
            } footer: {
                Text("These are counted alongside the built-in list during recording and in session stats. Phrases with spaces are supported.")
            }
        }
        .navigationTitle("Filler Words")
        .navigationBarTitleDisplayMode(.large)
    }

    private func addWord() {
        let trimmed = newWord.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty,
              !builtIn.contains(trimmed),
              !appState.profile.customFillerWords.contains(trimmed) else {
            newWord = ""
            return
        }
        appState.profile.customFillerWords.append(trimmed)
        newWord = ""
    }
}

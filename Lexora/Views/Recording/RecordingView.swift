import SwiftUI
import TipKit

struct RecordingView: View {
    @Environment(AppState.self) private var appState
    @State private var showCopiedFeedback = false
    @State private var editedTranscript = ""
    @State private var showCorrectionsSheet = false
    @State private var showDraftRecoveryBanner = false
    @State private var lastFinalTranscript = ""
    @State private var showPermissionAlert = false
    @State private var showShareSheet = false
    @State private var showPostRecordingActions = false
    @State private var showSessionStats = false
    @State private var lastMilestoneWords = 0
    /// Optional per-session word target (set by the user before recording). 0 = not set.
    @State private var sessionWordTarget: Int = 0
    @State private var showSessionTargetPicker = false
    /// Tracks whether the daily goal was already reached before this session started,
    /// so we only fire the goal-achieved haptic once per crossing event.
    @State private var goalAlreadyMetAtStart = false
    @State private var goalAchievedThisSession = false
    /// Countdown value: 3 → 2 → 1 → 0 (recording starts). nil = no countdown active.
    @State private var countdownValue: Int? = nil
    @FocusState private var isEditingTranscript: Bool

    private let milestones = [100, 250, 500, 1000, 2000, 5000]
    private let pauseTip = PauseRecordingTip()
    /// nil = auto-detect (default). Set to lock to a specific BCP-47 language code.
    @AppStorage("transcriptFontSize") private var transcriptFontSize: Double = 16.0
    @AppStorage("recordingCountdownEnabled") private var recordingCountdownEnabled: Bool = true
    @State private var lockedLanguage: String? = nil
    /// Active context profile UUID. nil = no context override.
    @State private var selectedContextProfileID: UUID? = nil
    /// Built-in recording template applied at session start.
    @State private var selectedTemplate: RecordingTemplate? = nil
    /// User-defined custom template applied at session start.
    @State private var selectedCustomTemplate: CustomRecordingTemplate? = nil
    /// Recurrence-pattern suggestion derived from past sessions.
    @State private var recurrenceSuggestion: RecurrenceSuggestion? = nil
    /// Whether the pre-recording prompt overlay is visible.
    @State private var showPreRecordingPrompt = false
    /// Focus mode: hides all UI except waveform + mic button.
    @State private var isFocusMode = false

    // ── Focus Timer ──────────────────────────────────────────────────────────
    /// Selected duration in minutes. 0 = no timer.
    @State private var focusTimerMinutes: Int = 0
    /// Remaining seconds; counts down from focusTimerMinutes × 60 once recording starts.
    @State private var focusTimerRemaining: Int = 0
    /// Whether the focus timer is actively counting down.
    @State private var focusTimerActive = false

    struct RecurrenceSuggestion {
        var label: String
        var template: RecordingTemplate?
        var customTemplate: CustomRecordingTemplate?
    }

    init(initialLanguage: String? = nil) {
        _lockedLanguage = State(initialValue: initialLanguage)
    }

    // Common languages offered in the picker; user can always rely on auto-detect.
    private let availableLanguages: [(code: String, name: String)] = [
        ("en-US", "English (US)"),
        ("en-GB", "English (UK)"),
        ("es-ES", "Spanish"),
        ("fr-FR", "French"),
        ("de-DE", "German"),
        ("it-IT", "Italian"),
        ("pt-BR", "Portuguese (Brazil)"),
        ("zh-Hans", "Mandarin (Simplified)"),
        ("ja-JP", "Japanese"),
        ("ko-KR", "Korean"),
        ("ar-SA", "Arabic"),
        ("hi-IN", "Hindi"),
        ("ru-RU", "Russian"),
        ("nl-NL", "Dutch"),
        ("pl-PL", "Polish"),
        ("tr-TR", "Turkish"),
        ("sv-SE", "Swedish"),
        ("yo-NG", "Yoruba"),
    ]

    private var engine: SpeechEngine { appState.speechEngine }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            // ── 3-2-1 countdown overlay ──────────────────────────────────────
            if let countdown = countdownValue {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .transition(.opacity)

                VStack(spacing: 16) {
                    Text("\(countdown)")
                        .font(.system(size: 120, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: countdown)

                    Text("Get ready…")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .transition(.scale(scale: 0.8).combined(with: .opacity))
                .zIndex(10)
            }

            VStack(spacing: 0) {
                // Language banner
                languageBanner

                // Focus timer progress bar (shown when timer is set and recording is active)
                if focusTimerMinutes > 0 {
                    focusTimerBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Draft recovery banner
                if showDraftRecoveryBanner {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.orange)
                        Text("Draft recovered from previous session")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                        Spacer()
                        Button {
                            withAnimation(.snappy) {
                                showDraftRecoveryBanner = false
                                editedTranscript = ""
                                UserDefaults.standard.removeObject(forKey: "lexora.draft.transcript")
                                UserDefaults.standard.removeObject(forKey: "lexora.draft.timestamp")
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                Spacer()

                // Live transcript (hidden in focus mode)
                if !isFocusMode {
                    transcriptArea
                }

                Spacer()

                // Waveform
                waveformSection

                // Contextual tip: pause recording (hidden in focus mode)
                if !isFocusMode {
                    TipView(pauseTip, arrowEdge: .bottom)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 4)
                }

                // Post-recording quick actions (hidden in focus mode)
                if showPostRecordingActions && !editedTranscript.isEmpty && !isFocusMode {
                    postRecordingActions
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Controls
                controlBar
                    .padding(.bottom, 12)
            }
        }
        .onChange(of: engine.currentTranscript) { _, new in
            if !new.isEmpty {
                editedTranscript = new
                // Auto-save draft every ~15 words so a crash never loses progress.
                let words = new.split(whereSeparator: { $0.isWhitespace }).count
                if words % 15 == 0 && words > 0 {
                    UserDefaults.standard.set(new, forKey: "lexora.draft.transcript")
                    UserDefaults.standard.set(Date(), forKey: "lexora.draft.timestamp")
                }
            }
            checkWordMilestone(transcript: new)
            checkGoalCrossing()
            checkSessionTargetReached()
        }
        .onAppear {
            // Restore crash-recovery draft if it exists and is recent (< 24 h).
            if let draft = UserDefaults.standard.string(forKey: "lexora.draft.transcript"),
               let ts = UserDefaults.standard.object(forKey: "lexora.draft.timestamp") as? Date,
               Date().timeIntervalSince(ts) < 86_400,
               !draft.isEmpty,
               editedTranscript.isEmpty {
                editedTranscript = draft
                showDraftRecoveryBanner = true
            }
            recurrenceSuggestion = buildRecurrenceSuggestion()
        }
        .onChange(of: engine.isListening) { _, listening in
            if !listening {
                // Clear the draft once the session finalises cleanly.
                UserDefaults.standard.removeObject(forKey: "lexora.draft.transcript")
                UserDefaults.standard.removeObject(forKey: "lexora.draft.timestamp")
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [editedTranscript])
        }
        .sheet(isPresented: $showSessionStats) {
            if let session = engine.lastFinishedSession {
                SessionStatsSheet(session: session)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showCorrectionsSheet) {
            CorrectionSheet(
                original: lastFinalTranscript,
                corrected: editedTranscript
            )
        }
        .alert("Permissions needed", isPresented: $showPermissionAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Lexora needs microphone and speech recognition access. Please enable them in Settings → Privacy.")
        }
    }

    // MARK: - Sub-views

    private var languageBanner: some View {
        VStack(spacing: 0) {
            // ── Prominent lock banner — only visible when a language is locked ──
            if let locked = lockedLanguage {
                let langName = availableLanguages.first { $0.code == locked }?.name ?? locked
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.caption2.weight(.semibold))
                    Text("Locked: \(langName)")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    if !engine.isListening {
                        Button {
                            lockedLanguage = nil
                            if appState.profile.hapticFeedbackEnabled { HapticManager.selectionChanged() }
                        } label: {
                            Text("Unlock")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.white.opacity(0.25), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 7)
                .background(Color.accentColor)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // ── Secondary row: language picker + confidence + WPM ──
            HStack(spacing: 8) {
                // Language selector: disabled while recording (can't switch mid-session)
                Menu {
                    Button {
                        lockedLanguage = nil
                    } label: {
                        HStack {
                            Text("Auto-detect")
                            if lockedLanguage == nil { Image(systemName: "checkmark") }
                        }
                    }
                    Divider()
                    ForEach(availableLanguages, id: \.code) { lang in
                        Button {
                            lockedLanguage = lang.code
                            if appState.profile.hapticFeedbackEnabled { HapticManager.selectionChanged() }
                        } label: {
                            HStack {
                                Text(lang.name)
                                if lockedLanguage == lang.code { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: lockedLanguage == nil ? "globe" : "lock.fill")
                            .font(.caption)
                            .foregroundStyle(lockedLanguage == nil ? Color.secondary : Color.accentColor)
                        Text(lockedLanguage == nil
                             ? languageDisplayName(engine.detectedLanguage)
                             : (availableLanguages.first { $0.code == lockedLanguage }?.name ?? lockedLanguage!))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(lockedLanguage == nil ? Color.secondary : Color.accentColor)
                        if !engine.isListening {
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .disabled(engine.isListening || engine.isPaused)

                Spacer()

                // Confidence indicator
                confidencePill(engine.currentConfidence)

                if engine.currentWPM > 0 {
                    Text("\(Int(engine.currentWPM)) wpm")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // Live filler word count (only during active recording, non-zero)
                if engine.isListening && liveFillerCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "bubble.left.fill")
                            .font(.system(size: 9))
                        Text("\(liveFillerCount) filler\(liveFillerCount == 1 ? "" : "s")")
                            .font(.caption2)
                    }
                    .foregroundStyle(liveFillerCount >= 5 ? Color.orange : Color.secondary)
                    .transition(.opacity)
                }

                // Focus mode toggle
                Button {
                    withAnimation(.snappy) { isFocusMode.toggle() }
                    if appState.profile.hapticFeedbackEnabled { HapticManager.selectionChanged() }
                } label: {
                    Image(systemName: isFocusMode ? "eye.slash" : "eye")
                        .font(.caption)
                        .foregroundStyle(isFocusMode ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isFocusMode ? "Exit focus mode" : "Enter focus mode")
                .accessibilityHint(isFocusMode ? "Shows transcript and template options" : "Hides UI — only waveform and mic button remain")

                // Focus timer button — shows a countdown ring when active
                focusTimerButton
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.thinMaterial)
        }
        .animation(.snappy, value: lockedLanguage != nil)
    }

    private var transcriptArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if editedTranscript.isEmpty && !engine.isListening {
                    placeholderText
                } else {
                    let isLowConfidence = engine.isListening
                        && engine.currentConfidence > 0
                        && engine.currentConfidence < appState.profile.confidenceThreshold
                    TextEditor(text: $editedTranscript)
                        .font(.system(size: transcriptFontSize))
                        .scrollContentBackground(.hidden)
                        .focused($isEditingTranscript)
                        .frame(minHeight: 120)
                        .opacity(isLowConfidence ? 0.45 : 1.0)
                        .animation(.easeInOut(duration: 0.2), value: isLowConfidence)
                        .overlay(alignment: .topTrailing) {
                            if isLowConfidence {
                                Label("Low confidence", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .padding(6)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .padding(8)
                            }
                        }
                        .onChange(of: isEditingTranscript) { _, editing in
                            if !editing && editedTranscript != lastFinalTranscript && !lastFinalTranscript.isEmpty {
                                // User edited the transcript — learn from it
                                appState.recordCorrection(
                                    original: lastFinalTranscript,
                                    corrected: editedTranscript,
                                    sessionID: UUID()
                                )
                                lastFinalTranscript = editedTranscript
                            }
                        }
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity)
    }

    private var placeholderText: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 56))
                .foregroundStyle(.quaternary)
                .symbolEffect(.pulse, isActive: engine.isListening)

            Text("Tap the mic to start")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("Lexora learns your voice, language, and style as you speak.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private var waveformSection: some View {
        VStack(spacing: 8) {
            // Use rolling history waveform while recording for genuine audio feedback;
            // fall back to the decorative animated bars when idle/paused.
            if engine.isListening {
                RollingWaveformView(
                    signalLevel: engine.signalLevel,
                    isActive: true,
                    color: .red
                )
                .frame(height: 50)
                .padding(.horizontal, 24)
                .transition(.opacity)
            } else {
                WaveformView(
                    signalLevel: engine.signalLevel,
                    isActive: engine.isPaused,
                    color: engine.isPaused ? .orange : .accentColor
                )
                .frame(height: 50)
                .padding(.horizontal, 24)
                .transition(.opacity)
            }

            HStack(spacing: 16) {
                if engine.isListening || engine.isPaused {
                    // Live word count + character count (+ session target progress)
                    let liveWords = editedTranscript.split(whereSeparator: { $0.isWhitespace }).count
                    let targetMet = sessionWordTarget > 0 && liveWords >= sessionWordTarget
                    Group {
                        if sessionWordTarget > 0 {
                            Label("\(liveWords) / \(sessionWordTarget)w",
                                  systemImage: targetMet ? "checkmark.circle.fill" : "target")
                                .foregroundStyle(targetMet ? Color.green : (engine.isPaused ? Color.secondary : Color.red))
                        } else {
                            Label("\(liveWords)w · \(editedTranscript.count)c",
                                  systemImage: "text.word.spacing")
                                .foregroundStyle(engine.isPaused ? Color.secondary : Color.red)
                        }
                    }
                    .font(.caption.monospacedDigit())

                    // Live WPM with pace comparison vs user's baseline
                    if engine.currentWPM > 0 {
                        let avg = appState.profile.averageSpeakingPaceWPM
                        let ratio = avg > 0 ? engine.currentWPM / avg : 1.0
                        let paceIcon  = ratio > 1.15 ? "hare.fill"
                                      : ratio < 0.85 ? "tortoise.fill"
                                      : "speedometer"
                        let paceColor: Color = ratio > 1.15 ? .orange
                                             : ratio < 0.85 ? .blue
                                             : .secondary

                        Label(String(format: "%.0f wpm", engine.currentWPM), systemImage: paceIcon)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(paceColor)
                            .accessibilityLabel(
                                ratio > 1.15 ? "Speaking fast at \(Int(engine.currentWPM)) WPM"
                              : ratio < 0.85 ? "Speaking slowly at \(Int(engine.currentWPM)) WPM"
                              : "\(Int(engine.currentWPM)) words per minute"
                            )
                    }

                    if engine.isPaused {
                        Text("Paused")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                }
            }
            .frame(height: 16)
            .animation(.snappy, value: engine.isListening)
        }
        .frame(height: 82)
    }

    private var postRecordingActions: some View {
        HStack(spacing: 12) {
            postActionButton(
                icon: showCopiedFeedback ? "checkmark.circle.fill" : "doc.on.doc",
                label: showCopiedFeedback ? "Copied!" : "Copy",
                color: showCopiedFeedback ? .green : .secondary
            ) {
                UIPasteboard.general.string = editedTranscript
                withAnimation { showCopiedFeedback = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation { showCopiedFeedback = false }
                }
            }
            .sensoryFeedback(.success, trigger: showCopiedFeedback)

            postActionButton(icon: "square.and.arrow.up", label: "Share", color: .secondary) {
                showShareSheet = true
            }

            // Quick restart — clears the current transcript and begins a new session
            postActionButton(icon: "arrow.trianglehead.counterclockwise", label: "Again", color: Color.accentColor) {
                withAnimation { showPostRecordingActions = false }
                editedTranscript = ""
                startCountdown()
            }

            postActionButton(icon: "xmark.circle", label: "Discard", color: .red.opacity(0.7)) {
                withAnimation {
                    showPostRecordingActions = false
                    editedTranscript = ""
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func postActionButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private var controlBar: some View {
        VStack(spacing: 10) {
            // Template selector (only when idle, hidden in focus mode)
            if !engine.isListening && !engine.isPaused && !isFocusMode {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // Recurrence suggestion chip (shown before built-ins when detected)
                        if let sug = recurrenceSuggestion,
                           selectedTemplate == nil && selectedCustomTemplate == nil {
                            Button {
                                if let ct = sug.customTemplate {
                                    selectedCustomTemplate = ct
                                    selectedTemplate = nil
                                } else {
                                    selectedTemplate = sug.template
                                    selectedCustomTemplate = nil
                                }
                                recurrenceSuggestion = nil
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "sparkles")
                                        .font(.caption2)
                                    Text(sug.label)
                                        .font(.caption.weight(.semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.purple.gradient, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .transition(.scale.combined(with: .opacity))
                            Divider()
                                .frame(height: 20)
                                .padding(.horizontal, 2)
                        }
                        // Built-in templates
                        ForEach(RecordingTemplate.allCases, id: \.self) { template in
                            templateChip(template)
                        }
                        // User-defined custom templates (if any)
                        if !appState.profile.customTemplates.isEmpty {
                            Divider()
                                .frame(height: 20)
                                .padding(.horizontal, 2)
                            ForEach(appState.profile.customTemplates) { template in
                                customTemplateChip(template)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Pre-recording prompt card (shown when a custom template with a prompt is selected)
            if let prompt = selectedCustomTemplate?.recordingPrompt,
               !prompt.isEmpty,
               !engine.isListening,
               !engine.isPaused,
               !isFocusMode,
               showPreRecordingPrompt {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Before you start", systemImage: "checklist")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        Button {
                            withAnimation { showPreRecordingPrompt = false }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                        .buttonStyle(.plain)
                    }
                    Text(prompt)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1))
                .padding(.horizontal, 24)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Session word target chip (only when idle)
            if !engine.isListening && !engine.isPaused {
                HStack(spacing: 8) {
                    Menu {
                        Button("No target") { sessionWordTarget = 0 }
                        Divider()
                        ForEach([50, 100, 200, 300, 500, 750, 1000, 1500, 2000], id: \.self) { n in
                            Button("\(n) words") { sessionWordTarget = n }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: sessionWordTarget > 0 ? "target" : "scope")
                                .font(.caption2)
                            Text(sessionWordTarget > 0 ? "Target: \(sessionWordTarget)w" : "Set target")
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(sessionWordTarget > 0 ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            sessionWordTarget > 0
                                ? Color.accentColor.opacity(0.1)
                                : Color(.systemGray5),
                            in: Capsule()
                        )
                    }
                }
                .padding(.horizontal, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Context profile selector (only when idle)
            if !engine.isListening && !engine.isPaused {
                let profiles = appState.profile.contextProfiles.filter { $0.isActive }
                if profiles.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            contextChip(nil, label: "Auto")
                            ForEach(profiles) { ctx in
                                contextChip(ctx.id, label: ctx.name)
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            HStack(spacing: 32) {
            // Copy button
            Button {
                UIPasteboard.general.string = editedTranscript
                withAnimation { showCopiedFeedback = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation { showCopiedFeedback = false }
                }
            } label: {
                Image(systemName: showCopiedFeedback ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.title2)
                    .foregroundStyle(editedTranscript.isEmpty ? .quaternary : .secondary)
            }
            .disabled(editedTranscript.isEmpty)
            .accessibilityLabel(showCopiedFeedback ? "Copied" : "Copy transcript")
            .accessibilityHint("Copies the current transcript text to the clipboard")
            .sensoryFeedback(
                .success,
                trigger: showCopiedFeedback,
                condition: { _, new in new && appState.profile.hapticFeedbackEnabled }
            )

            // Bookmark button (active during recording — inserts a marker in transcript)
            if engine.isListening {
                Button {
                    let marker = "\n[★ \(Date().formatted(date: .omitted, time: .shortened))]"
                    editedTranscript += marker
                    if appState.profile.hapticFeedbackEnabled {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                } label: {
                    Image(systemName: "bookmark.fill")
                        .font(.title2)
                        .foregroundStyle(Color.yellow)
                }
                .accessibilityLabel("Add bookmark")
                .accessibilityHint("Inserts a timestamped bookmark marker at this point in the transcript")
                .transition(.scale.combined(with: .opacity))
            }

            // Pause / Resume button (only visible when actively recording or paused)
            if engine.isListening || engine.isPaused {
                Button {
                    if engine.isListening {
                        appState.pauseRecording()
                        if appState.profile.hapticFeedbackEnabled { HapticManager.recordingPaused() }
                    } else {
                        appState.resumeRecording()
                        if appState.profile.hapticFeedbackEnabled { HapticManager.recordingResumed() }
                    }
                } label: {
                    Image(systemName: engine.isPaused ? "play.circle.fill" : "pause.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(engine.isPaused ? "Resume recording" : "Pause recording")
                .accessibilityHint(engine.isPaused ? "Resumes the paused recording" : "Pauses the recording without stopping it")
            }

            // Main record button
            recordButton

            // Share
            Button {
                showShareSheet = true
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.title2)
                    .foregroundStyle(editedTranscript.isEmpty ? .quaternary : .secondary)
            }
            .disabled(editedTranscript.isEmpty)
            .accessibilityLabel("Share transcript")
            .accessibilityHint("Opens the share sheet for the current transcript")
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
        .padding(.horizontal, 24)
        } // end VStack
    } // end controlBar

    /// Total words spoken today = completed sessions + live session (if recording).
    private var todayWordCount: Int {
        let completedToday = appState.sessions
            .filter { Calendar.current.isDateInToday($0.startedAt) }
            .reduce(0) { $0 + $1.wordCount }
        let liveWords = engine.isListening
            ? editedTranscript.split(whereSeparator: { $0.isWhitespace }).count
            : 0
        return completedToday + liveWords
    }

    /// 0…1 progress toward the daily word goal, or nil when no goal is set.
    private var dailyGoalProgress: Double? {
        let goal = appState.profile.dailyWordGoal
        guard goal > 0 else { return nil }
        return min(1.0, Double(todayWordCount) / Double(goal))
    }

    private var recordButton: some View {
        Button {
            if engine.isListening {
                appState.stopRecording()
                if appState.profile.hapticFeedbackEnabled { HapticManager.recordingStopped() }
                lastFinalTranscript = editedTranscript
                lastMilestoneWords = 0       // reset for next session
                withAnimation(.spring(response: 0.4)) {
                    showPostRecordingActions = true
                }
                // Donate TipKit event so the pause tip can surface next session
                Task { await PauseRecordingTip.recordingCount.donate() }
                // Show stats sheet after a brief delay so session is finalised
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if engine.lastFinishedSession != nil {
                        showSessionStats = true
                    }
                }
            } else {
                withAnimation { showPostRecordingActions = false }
                editedTranscript = ""
                // 3-2-1 countdown before recording starts
                startCountdown()
            }
        } label: {
            ZStack {
                // Daily goal progress ring — shown when goal is set
                if let progress = dailyGoalProgress {
                    let ringColor: Color = progress >= 1.0 ? .green : Color.accentColor
                    // Track ring
                    Circle()
                        .stroke(ringColor.opacity(0.18),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 88, height: 88)
                    // Progress arc
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(ringColor,
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 88, height: 88)
                        .animation(.spring(response: 0.5), value: progress)
                }

                Circle()
                    .fill(engine.isListening ? Color.red : Color.accentColor)
                    .frame(width: 72, height: 72)
                    .shadow(color: engine.isListening ? .red.opacity(0.5) : .accentColor.opacity(0.3),
                            radius: engine.isListening ? 12 : 6)

                Image(systemName: engine.isListening ? "stop.fill" : "mic.fill")
                    .font(.title)
                    .foregroundStyle(.white)
            }
        }
        .sensoryFeedback(
            .impact(weight: .medium),
            trigger: engine.isListening,
            condition: { _, _ in appState.profile.hapticFeedbackEnabled }
        )
        .scaleEffect(engine.isListening ? 1.05 : 1.0)
        .disabled(countdownValue != nil)
        .animation(.spring(response: 0.3), value: engine.isListening)
        .accessibilityLabel(engine.isListening ? "Stop recording" : "Start recording")
        .accessibilityHint(engine.isListening
            ? "Stops the current recording and shows session stats"
            : "Begins a new voice recording session")
    }

    private func templateChip(_ template: RecordingTemplate) -> some View {
        let selected = selectedTemplate == template
        return Button {
            withAnimation(.snappy) {
                if selected {
                    selectedTemplate = nil
                    // Revert language/formality to profile defaults
                    lockedLanguage = nil
                } else {
                    selectedTemplate = template
                    // Apply template overrides
                    if let lang = template.defaultLanguage { lockedLanguage = lang }
                    if let formality = template.formality {
                        appState.profile.preferredOutputFormality = formality
                    }
                }
                HapticManager.selectionChanged()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: template.icon).font(.caption2)
                Text(template.title).font(.caption.weight(.medium))
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(selected ? template.color : Color(.systemGray5), in: Capsule())
            .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: selected)
    }

    /// Tags that will be applied to the session when recording starts.
    private var activatedTemplateTags: [String] {
        var tags: [String] = []
        if let t = selectedTemplate { tags.append(t.title) }
        if let ct = selectedCustomTemplate {
            tags.append(ct.name)
            tags.append(contentsOf: ct.defaultTags)
        }
        return tags
    }

    private func customTemplateChip(_ template: CustomRecordingTemplate) -> some View {
        let selected = selectedCustomTemplate?.id == template.id
        let chipColor = customTemplateColor(template.colorName)
        return Button {
            withAnimation(.snappy) {
                if selected {
                    selectedCustomTemplate = nil
                    lockedLanguage = nil
                    showPreRecordingPrompt = false
                } else {
                    selectedCustomTemplate = template
                    selectedTemplate = nil   // deselect any built-in
                    if let lang = template.defaultLanguage { lockedLanguage = lang }
                    if let formality = template.formality {
                        appState.profile.preferredOutputFormality = formality
                    }
                    // Show prompt card if this template has one
                    if template.recordingPrompt?.isEmpty == false {
                        withAnimation { showPreRecordingPrompt = true }
                    }
                }
                HapticManager.selectionChanged()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: template.icon).font(.caption2)
                Text(template.name).font(.caption.weight(.medium))
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(selected ? chipColor : Color(.systemGray5), in: Capsule())
            .foregroundStyle(selected ? Color.white : Color.primary)
            .overlay(
                Capsule()
                    .strokeBorder(selected ? Color.clear : chipColor.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: selected)
    }

    private func customTemplateColor(_ name: String) -> Color {
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

    private var liveFillerCount: Int {
        let text = engine.currentTranscript.lowercased()
        let builtIn = ["um", "uh", "like", "you know", "i mean", "basically", "literally", "actually", "so"]
        let custom  = appState.profile.customFillerWords.map { $0.lowercased() }
        let fillers = Array(Set(builtIn + custom))
        return fillers.reduce(0) { count, filler in
            count + max(0, text.components(separatedBy: " \(filler) ").count - 1
                        + (text.hasPrefix("\(filler) ") ? 1 : 0)
                        + (text.hasSuffix(" \(filler)") ? 1 : 0))
        }
    }

    private func buildRecurrenceSuggestion() -> RecurrenceSuggestion? {
        let sessions = appState.sessions
        guard sessions.count >= 5 else { return nil }
        let calendar = Calendar.current
        let now = Date()
        let fourWeeksAgo = calendar.date(byAdding: .day, value: -28, to: now) ?? now
        let recent = sessions.filter { $0.startedAt >= fourWeeksAgo }
        guard recent.count >= 3 else { return nil }

        let currentWeekday = calendar.component(.weekday, from: now)
        let currentHour = calendar.component(.hour, from: now)
        let currentBucket = hourBucket(currentHour)

        // Count sessions per (weekday, hourBucket) slot
        var slotCounts: [String: (count: Int, tags: [String: Int])] = [:]
        for session in recent {
            let wday = calendar.component(.weekday, from: session.startedAt)
            let hour = calendar.component(.hour, from: session.startedAt)
            let bucket = hourBucket(hour)
            let key = "\(wday)-\(bucket)"
            var entry = slotCounts[key] ?? (count: 0, tags: [:])
            entry.count += 1
            for tag in session.tags { entry.tags[tag, default: 0] += 1 }
            slotCounts[key] = entry
        }

        let matchKey = "\(currentWeekday)-\(currentBucket)"
        guard let match = slotCounts[matchKey], match.count >= 3 else { return nil }

        // Most common tag in this slot
        let topTag = match.tags.max(by: { $0.value < $1.value })?.key

        // Try to match tag to a built-in template
        let matchedBuiltIn = RecordingTemplate.allCases.first {
            topTag?.localizedCaseInsensitiveContains($0.title) == true
        }
        // Try to match to a custom template
        let matchedCustom: CustomRecordingTemplate? = topTag == nil ? nil :
            appState.profile.customTemplates.first {
                $0.name.localizedCaseInsensitiveContains(topTag ?? "") ||
                $0.defaultTags.contains { $0.localizedCaseInsensitiveContains(topTag ?? "") }
            }

        let dayName = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][currentWeekday]
        let bucketName = currentBucket == "morning" ? "morning" : currentBucket == "afternoon" ? "afternoon" : "evening"
        let label: String
        if let tag = topTag {
            label = "\(dayName) \(bucketName) · \(tag)"
        } else {
            label = "Usual \(dayName) \(bucketName) session"
        }

        return RecurrenceSuggestion(label: label, template: matchedBuiltIn, customTemplate: matchedCustom)
    }

    private func hourBucket(_ hour: Int) -> String {
        switch hour {
        case 5..<12: return "morning"
        case 12..<17: return "afternoon"
        default: return "evening"
        }
    }

    private func contextChip(_ id: UUID?, label: String) -> some View {
        let selected = selectedContextProfileID == id
        return Button {
            selectedContextProfileID = id
        } label: {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(selected ? Color.accentColor : Color(.systemGray5), in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: selected)
    }

    // MARK: - Focus Timer

    private let focusTimerOptions = [5, 10, 15, 25, 30, 45, 60]

    /// Thin progress bar banner shown below the language strip when a timer is set.
    private var focusTimerBanner: some View {
        let total = focusTimerMinutes * 60
        let fraction = total > 0 ? Double(focusTimerRemaining) / Double(total) : 1.0
        let isUrgent = focusTimerRemaining > 0 && focusTimerRemaining <= 30
        let mins  = focusTimerRemaining / 60
        let secs  = focusTimerRemaining % 60
        let label = focusTimerRemaining > 0
            ? (mins > 0 ? "\(mins)m \(String(format: "%02d", secs))s left" : "\(secs)s left")
            : (focusTimerMinutes > 0 && !focusTimerActive ? "Timer ready — starts with recording" : "Time's up!")

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "timer")
                    .font(.caption2)
                    .foregroundStyle(isUrgent ? .red : Color.accentColor)
                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(isUrgent ? .red : Color.primary)
                    .animation(.none, value: focusTimerRemaining)   // prevent text flash
                Spacer()
                Button {
                    stopFocusTimer()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption2)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 5)

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color(.systemGray5))
                        .frame(height: 2)
                    Rectangle()
                        .fill(isUrgent ? Color.red : Color.accentColor)
                        .frame(width: geo.size.width * max(0, fraction), height: 2)
                        .animation(.linear(duration: 1), value: focusTimerRemaining)
                }
            }
            .frame(height: 2)
        }
        .background(.thinMaterial)
    }

    @ViewBuilder
    private var focusTimerButton: some View {
        let isRunning = focusTimerActive && focusTimerRemaining > 0
        let total = focusTimerMinutes * 60
        let progress = total > 0 ? Double(total - focusTimerRemaining) / Double(total) : 0

        Menu {
            if focusTimerMinutes > 0 {
                Button(role: .destructive) {
                    stopFocusTimer()
                } label: {
                    Label("Clear timer", systemImage: "xmark.circle")
                }
                Divider()
            }
            ForEach(focusTimerOptions, id: \.self) { mins in
                Button {
                    setFocusTimer(minutes: mins)
                } label: {
                    HStack {
                        Text("\(mins) min")
                        if focusTimerMinutes == mins { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            ZStack {
                // Background track
                Circle()
                    .stroke(Color(.systemGray5), lineWidth: 2)
                    .frame(width: 18, height: 18)
                    .opacity(focusTimerMinutes > 0 ? 1 : 0)

                // Progress arc
                if isRunning {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 18, height: 18)
                        .animation(.linear(duration: 1), value: focusTimerRemaining)
                }

                // Icon / time label
                if isRunning && focusTimerRemaining <= 30 {
                    // Urgent: show remaining seconds
                    Text("\(focusTimerRemaining)")
                        .font(.system(size: 8, weight: .bold).monospacedDigit())
                        .foregroundStyle(.red)
                } else if isRunning {
                    Image(systemName: "timer")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor)
                } else if focusTimerMinutes > 0 {
                    Image(systemName: "timer")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor.opacity(0.6))
                } else {
                    Image(systemName: "timer")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondary)
                }
            }
            .frame(width: 22, height: 22)
        }
        .accessibilityLabel(isRunning
            ? "Focus timer: \(focusTimerRemaining / 60)m \(focusTimerRemaining % 60)s remaining"
            : (focusTimerMinutes > 0 ? "Focus timer: \(focusTimerMinutes) min set" : "Set focus timer"))
        .onChange(of: engine.isListening) { _, listening in
            if listening && focusTimerMinutes > 0 && !focusTimerActive {
                startFocusTimer()
            } else if !listening && focusTimerActive {
                pauseFocusTimer()
            }
        }
        .onReceive(
            Timer.publish(every: 1, on: .main, in: .common).autoconnect()
        ) { _ in
            guard focusTimerActive, focusTimerRemaining > 0 else { return }
            focusTimerRemaining -= 1
            if focusTimerRemaining == 0 {
                focusTimerFired()
            }
        }
    }

    private func setFocusTimer(minutes: Int) {
        focusTimerMinutes  = minutes
        focusTimerRemaining = minutes * 60
        focusTimerActive   = false       // will start when recording begins
        if appState.profile.hapticFeedbackEnabled { HapticManager.selectionChanged() }
    }

    private func startFocusTimer() {
        guard focusTimerMinutes > 0, focusTimerRemaining > 0 else { return }
        focusTimerActive = true
    }

    private func pauseFocusTimer() {
        focusTimerActive = false
    }

    private func stopFocusTimer() {
        focusTimerActive    = false
        focusTimerMinutes   = 0
        focusTimerRemaining = 0
    }

    /// Called when the countdown reaches zero — pauses recording and notifies the user.
    private func focusTimerFired() {
        focusTimerActive = false
        // Pause the recording engine
        if engine.isListening {
            appState.pauseRecording()
        }
        if appState.profile.hapticFeedbackEnabled { HapticManager.recordingPaused() }
        // Second haptic burst to signal the end of the focus block
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if appState.profile.hapticFeedbackEnabled { HapticManager.wordMilestone() }
        }
    }

    // MARK: - Helpers

    private func confidencePill(_ confidence: Double) -> some View {
        let color: Color = confidence > 0.85 ? .green : confidence > 0.65 ? .orange : .red
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(Int(confidence * 100))%")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .opacity(confidence > 0 ? 1 : 0)
    }

    private func languageDisplayName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    // MARK: - Countdown

    /// Runs a 3-2-1 countdown (if enabled in settings), then starts the recording engine.
    private func startCountdown() {
        // Snapshot whether the goal is already met *before* this session starts,
        // so we only fire the goal-achieved haptic for words added *this* session.
        let goal = appState.profile.dailyWordGoal
        goalAlreadyMetAtStart = goal > 0 && todayWordCount >= goal
        goalAchievedThisSession = false
        sessionTargetReachedFired = false

        guard recordingCountdownEnabled else {
            // Instant start when countdown is disabled
            do {
                try appState.startRecording(
                    language: lockedLanguage,
                    contextProfileID: selectedContextProfileID,
                    templateTags: activatedTemplateTags
                )
                if appState.profile.hapticFeedbackEnabled { HapticManager.recordingStarted() }
            } catch {
                if appState.profile.hapticFeedbackEnabled { HapticManager.error() }
                showPermissionAlert = true
            }
            return
        }

        countdownValue = 3
        Task { @MainActor in
            for tick in stride(from: 3, through: 1, by: -1) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                    countdownValue = tick
                }
                if appState.profile.hapticFeedbackEnabled { HapticManager.selectionChanged() }
                try? await Task.sleep(for: .seconds(1))
            }
            withAnimation(.easeOut(duration: 0.2)) { countdownValue = nil }
            do {
                try appState.startRecording(
                    language: lockedLanguage,
                    contextProfileID: selectedContextProfileID,
                    templateTags: activatedTemplateTags
                )
                if appState.profile.hapticFeedbackEnabled { HapticManager.recordingStarted() }
            } catch {
                if appState.profile.hapticFeedbackEnabled { HapticManager.error() }
                showPermissionAlert = true
            }
        }
    }

    // MARK: - Word milestones

    private func checkWordMilestone(transcript: String) {
        guard engine.isListening else { return }
        let wordCount = transcript.split(whereSeparator: { $0.isWhitespace }).count
        guard let milestone = milestones.first(where: { $0 > lastMilestoneWords && wordCount >= $0 }) else { return }
        lastMilestoneWords = milestone
        if appState.profile.hapticFeedbackEnabled { HapticManager.wordMilestone() }
    }

    // MARK: - Session target milestone

    @State private var sessionTargetReachedFired = false

    private func checkSessionTargetReached() {
        guard sessionWordTarget > 0, engine.isListening, !sessionTargetReachedFired else { return }
        let liveWords = editedTranscript.split(whereSeparator: { $0.isWhitespace }).count
        if liveWords >= sessionWordTarget {
            sessionTargetReachedFired = true
            if appState.profile.hapticFeedbackEnabled { HapticManager.wordMilestone() }
        }
    }

    // MARK: - Daily goal crossing detection

    /// Fire the goal-achieved haptic exactly once when todayWordCount first crosses
    /// the daily goal threshold during the current recording session.
    private func checkGoalCrossing() {
        let goal = appState.profile.dailyWordGoal
        guard goal > 0, engine.isListening, !goalAchievedThisSession else { return }
        // todayWordCount already includes in-progress live words via `todayWordCount`
        if todayWordCount >= goal && !goalAlreadyMetAtStart {
            goalAchievedThisSession = true
            if appState.profile.hapticFeedbackEnabled { HapticManager.goalAchieved() }
        }
    }
}

// MARK: - Session Stats Sheet

struct SessionStatsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var session: TranscriptionSession

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Headline numbers
                    HStack(spacing: 0) {
                        statPill(value: "\(session.wordCount)", label: "words")
                        Divider().frame(height: 36)
                        statPill(value: formatDuration(session.durationSeconds), label: "duration")
                        Divider().frame(height: 36)
                        statPill(value: paceLabel, label: "pace")
                        Divider().frame(height: 36)
                        statPill(value: "\(Int(session.estimatedAccuracy))%", label: "accuracy")
                    }
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 14))

                    if session.codeSwitch {
                        infoRow(
                            icon: "globe",
                            color: .blue,
                            title: "Language mixing detected",
                            detail: "You switched between \(session.detectedLanguages.count) languages in this session."
                        )
                    }

                    // Filler words
                    if !session.fillerWords.isEmpty {
                        let freq = Dictionary(grouping: session.fillerWords) { $0 }
                            .mapValues { $0.count }
                            .sorted { $0.value > $1.value }
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Filler words", systemImage: "bubble.left.and.bubble.right")
                                .font(.subheadline.weight(.semibold))
                            FlowLayout(spacing: 8) {
                                ForEach(freq.prefix(6), id: \.key) { word, count in
                                    Text("\"\(word)\" ×\(count)")
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(Color.orange.opacity(0.1), in: Capsule())
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        .padding(14)
                        .background(Color(.secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 12))
                    }

                    infoRow(
                        icon: "waveform.badge.magnifyingglass",
                        color: .purple,
                        title: "Confidence",
                        detail: confidenceDescription
                    )

                    infoRow(
                        icon: "brain.head.profile",
                        color: .green,
                        title: "Learning",
                        detail: "This session has been added to your voice profile."
                    )
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Session Complete")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var paceLabel: String {
        let wpm = session.paceWPM
        if wpm < 10 { return "—" }
        return "\(Int(wpm)) wpm"
    }

    private var confidenceDescription: String {
        let pct = Int(session.confidenceAverage * 100)
        switch pct {
        case 86...: return "Excellent — \(pct)% confidence. Lexora understood you clearly."
        case 70...85: return "Good — \(pct)% confidence. A few uncertain words may need review."
        case 50...69: return "Fair — \(pct)% confidence. Consider speaking closer to the mic."
        default: return "Low — \(pct)% confidence. Background noise may have affected recognition."
        }
    }

    private func statPill(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func infoRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.title3)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        return "\(Int(seconds / 60))m \(Int(seconds.truncatingRemainder(dividingBy: 60)))s"
    }
}

// MARK: - Correction Sheet

struct CorrectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    var original: String
    var corrected: String

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("Lexora learned from your edit")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    Label("What it heard", systemImage: "waveform")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(original).font(.body).padding(12)
                        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("What you meant", systemImage: "checkmark.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                    Text(corrected).font(.body).padding(12)
                        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }

                Text("These corrections improve future transcriptions automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(24)
            .navigationTitle("Correction Learned")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Recording Templates

/// Pre-defined recording modes that pre-configure language and formality.
enum RecordingTemplate: String, CaseIterable, Equatable {
    case meeting    = "Meeting"
    case lecture    = "Lecture"
    case note       = "Quick note"
    case dictation  = "Dictation"
    case interview  = "Interview"

    var title: String { rawValue }

    var icon: String {
        switch self {
        case .meeting:   return "person.3.fill"
        case .lecture:   return "book.fill"
        case .note:      return "note.text"
        case .dictation: return "text.cursor"
        case .interview: return "mic.and.signal.meter.fill"
        }
    }

    var color: Color {
        switch self {
        case .meeting:   return .blue
        case .lecture:   return .purple
        case .note:      return .green
        case .dictation: return .orange
        case .interview: return .red
        }
    }

    /// BCP-47 language override, if any (nil = keep user default).
    var defaultLanguage: String? { nil }

    var formality: FormalityMode? {
        switch self {
        case .meeting:   return .professional
        case .lecture:   return .professional
        case .note:      return .casual
        case .dictation: return .verbatim
        case .interview: return .adaptive
        }
    }
}

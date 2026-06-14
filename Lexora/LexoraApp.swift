import SwiftUI
import TipKit
import LocalAuthentication
@preconcurrency import UserNotifications

@main
struct LexoraApp: App {
    @State private var appState: AppState? = nil
    @UIApplicationDelegateAdaptor private var appDelegate: LexoraAppDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Configure TipKit for contextual in-app tips.
        // Use .production mode in release; switch to resetDatastore() during debugging.
        try? Tips.configure([
            .displayFrequency(.immediate),
            .datastoreLocation(.applicationDefault)
        ])
    }

    var body: some Scene {
        WindowGroup {
            if let appState {
                RootView()
                    .environment(appState)
            } else {
                SplashView()
                    .task {
                        appState = AppState()
                    }
            }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Start Recording") {
                    NotificationCenter.default.post(name: .lexoraStartRecording, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Open History") {
                    NotificationCenter.default.post(name: .lexoraOpenHistory, object: nil)
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])

                Button("Open Voice Profile") {
                    NotificationCenter.default.post(name: .lexoraOpenProfile, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Trigger an iCloud sync whenever the app moves to the background
            // so the latest sessions and profile are always backed up.
            if newPhase == .background, let appState {
                appState.syncNow()
            }
        }
    }
}

// MARK: - App Delegate

@MainActor
final class LexoraAppDelegate: NSObject, UIApplicationDelegate {
    private let notificationDelegate = LexoraNotificationDelegate()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = notificationDelegate
        registerQuickActions()
        // Refresh Quick Actions whenever a session completes
        NotificationCenter.default.addObserver(
            forName: .lexoraRefreshQuickActions,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.registerQuickActions()
        }
        return true
    }

    // Called when a Quick Action shortcut is tapped.
    func application(_ application: UIApplication,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        switch shortcutItem.type {
        case "com.yiga.Lexora.record":
            NotificationCenter.default.post(name: .lexoraStartRecording, object: nil)
        case "com.yiga.Lexora.history":
            if let url = URL(string: "lexora://history") { application.open(url) }
        case "com.yiga.Lexora.record.language":
            let lang = shortcutItem.userInfo?["language"] as? String
            NotificationCenter.default.post(
                name: .lexoraStartRecording,
                object: nil,
                userInfo: lang.map { ["language": $0] }
            )
        default:
            break
        }
        completionHandler(true)
    }

    func registerQuickActions() {
        var items: [UIApplicationShortcutItem] = [
            UIApplicationShortcutItem(
                type: "com.yiga.Lexora.record",
                localizedTitle: "New Recording",
                localizedSubtitle: "Start dictating immediately",
                icon: UIApplicationShortcutIcon(systemImageName: "mic.fill")
            ),
            UIApplicationShortcutItem(
                type: "com.yiga.Lexora.history",
                localizedTitle: "Recent Sessions",
                localizedSubtitle: "View your recordings",
                icon: UIApplicationShortcutIcon(systemImageName: "clock.fill")
            ),
        ]

        // Dynamic shortcut: record in the user's most-recently-used language (skip default en-US)
        if let langCode = UserDefaults(suiteName: "group.com.yiga.Lexora")?
                .string(forKey: "widget.lastLanguage"),
           !langCode.isEmpty, langCode != "en-US" {
            let base = langCode.components(separatedBy: "-").first ?? langCode
            let langName = Locale.current.localizedString(forLanguageCode: base) ?? langCode
            items.append(UIApplicationShortcutItem(
                type: "com.yiga.Lexora.record.language",
                localizedTitle: "Record in \(langName)",
                localizedSubtitle: "Continue dictating in \(langName)",
                icon: UIApplicationShortcutIcon(systemImageName: "globe"),
                userInfo: ["language": langCode as NSSecureCoding]
            ))
        }

        UIApplication.shared.shortcutItems = items
    }
}

// MARK: - Notification Delegate (non-isolated so it can conform to UNUserNotificationCenterDelegate)

final class LexoraNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    /// Foreground notifications — show as banner with sound.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 willPresent notification: UNNotification,
                                 withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound])
    }

    /// Notification tap — open the deep-link URL if present.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 didReceive response: UNNotificationResponse,
                                 withCompletionHandler handler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let deeplink = info["deeplink"] as? String,
           let url = URL(string: deeplink) {
            Task { @MainActor in UIApplication.shared.open(url) }
        }
        handler()
    }
}

struct SplashView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.29, green: 0.11, blue: 0.78),
                         Color(red: 0.56, green: 0.18, blue: 0.82)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "waveform.and.person.filled")
                    .font(.system(size: 72))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse)
                Text("Lexora")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
            }
        }
    }
}

// MARK: - Accent Color Resolution

/// Resolves an AppStorage color name to a SwiftUI Color.
/// Defaults to the asset-catalog AccentColor when the name is unrecognised.
func resolveAccentColor(_ name: String) -> Color {
    switch name {
    case "indigo":  return Color(red: 0.35, green: 0.34, blue: 0.84)
    case "teal":    return Color(red: 0.18, green: 0.68, blue: 0.68)
    case "orange":  return Color(red: 0.98, green: 0.55, blue: 0.14)
    case "coral":   return Color(red: 0.95, green: 0.35, blue: 0.35)
    case "green":   return Color(red: 0.20, green: 0.73, blue: 0.42)
    case "pink":    return Color(red: 0.95, green: 0.28, blue: 0.60)
    case "slate":   return Color(red: 0.38, green: 0.48, blue: 0.62)
    case "gold":    return Color(red: 0.88, green: 0.67, blue: 0.08)
    default:        return Color.accentColor          // asset-catalog purple
    }
}

let accentColorPalette: [(name: String, label: String)] = [
    ("default", "Lexora Purple"),
    ("indigo",  "Indigo"),
    ("teal",    "Teal"),
    ("orange",  "Orange"),
    ("coral",   "Coral"),
    ("green",   "Emerald"),
    ("pink",    "Pink"),
    ("slate",   "Slate"),
    ("gold",    "Gold"),
]

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appLockEnabled") private var appLockEnabled = false
    @AppStorage("accentColorName") private var accentColorName = "default"
    @State private var isLocked = false
    @State private var authError: String? = nil

    private var chosenAccent: Color { resolveAccentColor(accentColorName) }

    var body: some View {
        ZStack {
            if appState.hasCompletedOnboarding {
                MainTabView()
            } else {
                OnboardingView()
            }

            // ── Biometric lock screen overlay ─────────────────────────────────
            if isLocked {
                Color(.systemBackground).ignoresSafeArea()
                VStack(spacing: 28) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Color.accentColor)
                    Text("Lexora is locked")
                        .font(.title2.weight(.semibold))
                    if let err = authError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    Button {
                        authenticate()
                    } label: {
                        Label("Unlock", systemImage: "faceid")
                            .font(.headline)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 14)
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                }
                .transition(.opacity)
            }
        }
        .tint(chosenAccent)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, appLockEnabled, isLocked {
                authenticate()
            }
            if phase == .background, appLockEnabled {
                isLocked = true
            }
        }
        .onAppear {
            if appLockEnabled { isLocked = true }
        }
    }

    private func authenticate() {
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            // Biometrics unavailable — unlock without challenge
            withAnimation { isLocked = false }
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication,
                           localizedReason: "Unlock Lexora") { success, err in
            Task { @MainActor in
                if success {
                    authError = nil
                    withAnimation { isLocked = false }
                } else {
                    authError = err?.localizedDescription
                }
            }
        }
    }
}

struct MainTabView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("autoArchiveDays") private var autoArchiveDays: Int = 0

    @State private var selectedTab = 0
    @State private var showingRecorder = false
    @State private var deepLinkedSessionID: UUID? = nil
    @State private var deepLinkedLanguage: String? = nil
    @State private var deepLinkedSearchQuery: String? = nil

    /// Timestamp of the last time the user opened the History tab.
    @AppStorage("lastHistoryVisit") private var lastHistoryVisitInterval: Double = 0

    /// Number of sessions added since the History tab was last opened.
    private var newSessionsBadge: Int {
        guard lastHistoryVisitInterval > 0 else { return 0 }
        let lastVisit = Date(timeIntervalSinceReferenceDate: lastHistoryVisitInterval)
        return appState.sessions.filter { !$0.isArchived && $0.startedAt > lastVisit }.count
    }

    // MARK: - Body

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                iPadLayout
            } else {
                iPhoneLayout
            }
        }
        // ── All deep-link / sheet modifiers live here once, shared by both layouts ──
        .sheet(isPresented: $showingRecorder, onDismiss: { deepLinkedLanguage = nil }) {
            RecordingView(initialLanguage: deepLinkedLanguage)
                .presentationDetents(horizontalSizeClass == .regular ? [.large] : [.medium, .large])
                .presentationDragIndicator(.visible)
                .environment(appState)
        }
        .sheet(isPresented: Binding(
            get: { deepLinkedSessionID != nil },
            set: { if !$0 { deepLinkedSessionID = nil } }
        )) {
            if let id = deepLinkedSessionID,
               let session = appState.sessions.first(where: { $0.id == id }) {
                NavigationStack { SessionDetailView(session: session) }
                    .environment(appState)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lexoraStartRecording)) { note in
            deepLinkedLanguage = note.userInfo?["language"] as? String
            showingRecorder = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .lexoraOpenHistory)) { _ in
            selectedTab = 3
        }
        .onReceive(NotificationCenter.default.publisher(for: .lexoraSearchHistory)) { note in
            deepLinkedSearchQuery = note.userInfo?["query"] as? String
            selectedTab = 3
        }
        .onReceive(NotificationCenter.default.publisher(for: .lexoraOpenProfile)) { _ in
            selectedTab = 2
        }
        .onAppear {
            appState.clearBadge()
            // Run auto-archive silently on every launch if the user configured a threshold.
            if autoArchiveDays > 0 {
                appState.autoArchiveSessions(olderThan: autoArchiveDays)
            }
        }
        .onOpenURL { url in
            guard url.scheme == "lexora" else { return }
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            switch url.host {
            case "record":
                deepLinkedLanguage = comps?.queryItems?.first(where: { $0.name == "language" })?.value
                showingRecorder = true
            case "history":
                selectedTab = 3
            case "profile":
                selectedTab = 2
            case "session":
                if let uuidStr = url.pathComponents.dropFirst().first,
                   let id = UUID(uuidString: uuidStr) {
                    deepLinkedSessionID = id
                    selectedTab = 3
                }
            default: break
            }
        }
    }

    // MARK: - iPhone / Compact layout (original TabView)

    @ViewBuilder
    private var iPhoneLayout: some View {
        TabView(selection: $selectedTab) {
            DashboardView()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)

            Color.clear
                .tabItem { Label("Record", systemImage: "mic.circle.fill") }
                .tag(1)

            VoiceProfileView()
                .tabItem { Label("Profile", systemImage: "person.wave.2.fill") }
                .tag(2)

            TranscriptionHistoryView(initialSearch: deepLinkedSearchQuery ?? "")
                .tabItem { Label("History", systemImage: "clock.fill") }
                .tag(3)
                .badge(newSessionsBadge > 0 ? newSessionsBadge : 0)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(4)
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == 1 {
                showingRecorder = true
                Task { @MainActor in try? await Task.sleep(for: .milliseconds(50)); selectedTab = 0 }
            }
            if tab == 3 {
                // Record visit time so the badge can clear
                lastHistoryVisitInterval = Date().timeIntervalSinceReferenceDate
            }
        }
    }

    // MARK: - iPad / Regular layout (NavigationSplitView sidebar)

    @ViewBuilder
    private var iPadLayout: some View {
        NavigationSplitView {
            List(selection: Binding<Int?>(
                get: { selectedTab },
                set: { selectedTab = $0 ?? selectedTab }
            )) {
                Section {
                    Label("Home", systemImage: "house.fill")
                        .tag(0)
                    Label("Profile", systemImage: "person.wave.2.fill")
                        .tag(2)
                    Label("History", systemImage: "clock.fill")
                        .tag(3)
                    Label("Settings", systemImage: "gearshape.fill")
                        .tag(4)
                }
            }
            .navigationTitle("Lexora")
            .listStyle(.sidebar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingRecorder = true
                    } label: {
                        Label("Record", systemImage: "mic.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color.accentColor)
                    }
                    .help("Start a new recording")
                }
            }
        } detail: {
            iPadDetailView
        }
        .onAppear {
            // Ensure a valid non-modal tab is selected on launch
            if selectedTab == 1 { selectedTab = 0 }
        }
    }

    @ViewBuilder
    private var iPadDetailView: some View {
        switch selectedTab {
        case 2:  VoiceProfileView()
        case 3:  TranscriptionHistoryView(initialSearch: deepLinkedSearchQuery ?? "")
        case 4:  SettingsView()
        default: DashboardView()
        }
    }
}

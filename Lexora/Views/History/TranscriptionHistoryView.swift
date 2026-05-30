import SwiftUI
import Charts
import TipKit
import NaturalLanguage
import UIKit
import AVFoundation

// ── Tab entry-point: adds NavigationStack so the view works as a standalone tab ──
struct TranscriptionHistoryView: View {
    var initialSearch: String = ""
    var body: some View {
        NavigationStack {
            HistoryListContent(initialSearch: initialSearch)
        }
    }
}

// ── Reusable content (no NavigationStack): also pushed from DashboardView ────
enum HistorySortOrder: String, CaseIterable {
    case dateDesc  = "Newest first"
    case dateAsc   = "Oldest first"
    case wordCount = "Most words"
    case duration  = "Longest"
    case accuracy  = "Highest accuracy"

    var systemImage: String {
        switch self {
        case .dateDesc, .dateAsc: return "calendar"
        case .wordCount: return "text.word.spacing"
        case .duration:  return "timer"
        case .accuracy:  return "checkmark.seal"
        }
    }
}

struct HistoryListContent: View {
    @Environment(AppState.self) private var appState
    var initialSearch: String = ""
    @State private var searchText = ""
    @State private var selectedSession: TranscriptionSession?
    @State private var showingDeleteConfirm = false
    @State private var sessionToDelete: TranscriptionSession?
    @State private var showExportSheet = false
    @State private var exportItems: [Any] = []
    @State private var filterStarred = false
    @State private var filterTag: String? = nil
    @State private var filterHasAudio = false
    @State private var filterHasNotes = false
    @State private var showArchived = false
    @State private var showDateFilter = false
    @State private var filterFromDate: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var filterToDate: Date = Date()
    @State private var filterLanguage: String? = nil
    @AppStorage("history.sortOrder") private var sortOrderRaw: String = HistorySortOrder.dateDesc.rawValue
    private let sortTip = SortHistoryTip()

    // Swipe browser — snapshot of the filtered list at tap time
    @State private var browserSessions: [TranscriptionSession] = []

    // Bulk selection
    @State private var isSelectMode = false
    @State private var selectedIDs = Set<UUID>()
    @State private var showBulkDeleteConfirm = false
    @State private var showBulkTagSheet = false
    @State private var bulkTagInput = ""
    @State private var showMergeConfirm = false
    @State private var showBulkShareSheet = false
    @State private var bulkShareItems: [Any] = []
    @State private var showComparisonSheet = false

    // Tag bulk management
    @State private var showTagRenameAlert = false
    @State private var tagToRename: String = ""
    @State private var tagRenameInput: String = ""

    // Premium
    @State private var showPaywall = false

    private var sortOrder: HistorySortOrder { HistorySortOrder(rawValue: sortOrderRaw) ?? .dateDesc }
    private var sortOrderBinding: Binding<HistorySortOrder> {
        Binding(
            get: { HistorySortOrder(rawValue: sortOrderRaw) ?? .dateDesc },
            set: { sortOrderRaw = $0.rawValue }
        )
    }

    /// All unique tags across all sessions, sorted by frequency.
    private var allTags: [String] {
        var freq: [String: Int] = [:]
        for session in appState.sessions {
            for tag in session.tags { freq[tag, default: 0] += 1 }
        }
        return freq.keys.sorted { freq[$0]! > freq[$1]! }
    }

    /// All unique primary languages used across sessions, sorted by frequency.
    /// Only returned when there are at least 2 distinct languages.
    private var allLanguages: [(code: String, count: Int)] {
        var freq: [String: Int] = [:]
        for s in appState.sessions { freq[s.primaryLanguage, default: 0] += 1 }
        let sorted = freq.map { (code: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
        return sorted.count >= 2 ? sorted : []
    }

    /// Today's word count across all non-archived sessions.
    private var todayWordCount: Int {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        return appState.sessions
            .filter { !$0.isArchived && $0.startedAt >= startOfToday }
            .reduce(0) { $0 + $1.wordCount }
    }

    /// Returns a short label like "347 / 500w" when a daily goal is set, nil otherwise.
    private var todayGoalLabel: String? {
        let goal = appState.profile.dailyWordGoal
        guard goal > 0 else { return nil }
        return "\(todayWordCount) / \(goal)w"
    }

    /// True when today's word count meets or exceeds the daily goal.
    private var todayGoalMet: Bool {
        let goal = appState.profile.dailyWordGoal
        return goal > 0 && todayWordCount >= goal
    }

    var filteredSessions: [TranscriptionSession] {
        let dateEnd = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: filterToDate)) ?? filterToDate
        let filtered = appState.sessions.filter { session in
            // Archive filter: by default hide archived sessions; showArchived shows ONLY archived
            let matchesArchive = showArchived ? session.isArchived : !session.isArchived
            let matchesSearch = searchText.isEmpty
                || session.finalTranscript.localizedCaseInsensitiveContains(searchText)
                || (session.customTitle ?? "").localizedCaseInsensitiveContains(searchText)
                || session.primaryLanguage.localizedCaseInsensitiveContains(searchText)
                || session.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
                || (session.notes ?? "").localizedCaseInsensitiveContains(searchText)
            let matchesStarred   = !filterStarred   || session.isStarred
            let matchesTag       = filterTag == nil  || session.tags.contains(filterTag!)
            let matchesAudio     = !filterHasAudio   || session.audioFileURL != nil
            let matchesNotes     = !filterHasNotes   || (session.notes?.isEmpty == false)
            let matchesDate      = !showDateFilter
                || (session.startedAt >= filterFromDate && session.startedAt < dateEnd)
            let matchesLanguage  = filterLanguage == nil || session.primaryLanguage == filterLanguage
            return matchesArchive && matchesSearch && matchesStarred && matchesTag
                && matchesAudio && matchesNotes && matchesDate && matchesLanguage
        }
        let sorted: [TranscriptionSession]
        switch sortOrder {
        case .dateDesc:  sorted = filtered.sorted { $0.startedAt > $1.startedAt }
        case .dateAsc:   sorted = filtered.sorted { $0.startedAt < $1.startedAt }
        case .wordCount: sorted = filtered.sorted { $0.wordCount > $1.wordCount }
        case .duration:  sorted = filtered.sorted { $0.durationSeconds > $1.durationSeconds }
        case .accuracy:  sorted = filtered.sorted { $0.estimatedAccuracy > $1.estimatedAccuracy }
        }
        // Swift's sort is stable: this single-pass partition preserves the existing order
        // within pinned and within unpinned groups.
        return sorted.sorted { $0.isPinned && !$1.isPinned }
    }

    var body: some View {
        List {
            // Filter chips row — hidden while in select mode to keep the UI uncluttered
            if !isSelectMode && (!appState.sessions.isEmpty || filterStarred || filterTag != nil) {
                filterBar
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 4, trailing: 12))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                // Date range pickers — inline, only when date chip is active
                if showDateFilter {
                    dateRangePicker
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .animation(.snappy, value: showDateFilter)
                }
            }

            if filteredSessions.isEmpty && !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .listRowBackground(Color.clear)
            } else if !searchText.isEmpty {
                // Rich search results showing match context
                ForEach(filteredSessions) { session in
                    Button {
                        if isSelectMode { toggleSelect(session) } else { openSession(session) }
                    } label: {
                        selectableRow(for: session) { SearchResultRow(session: session, query: searchText) }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !isSelectMode {
                            Button(role: .destructive) {
                                sessionToDelete = session; showingDeleteConfirm = true
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: !isSelectMode) {
                        if !isSelectMode {
                            Button {
                                appState.toggleStar(session)
                                if appState.profile.hapticFeedbackEnabled { HapticManager.softConfirm() }
                            } label: {
                                Label(session.isStarred ? "Unstar" : "Star",
                                      systemImage: session.isStarred ? "star.slash" : "star.fill")
                            }
                            .tint(.yellow)
                        }
                    }
                }
            } else if appState.sessions.isEmpty {
                ContentUnavailableView(
                    "No recordings yet",
                    systemImage: "waveform.circle",
                    description: Text("Tap the mic button to start your first session.")
                )
            } else {
                ForEach(groupedSessions, id: \.key) { group in
                    Section(group.key) {
                        ForEach(group.sessions) { session in
                            Button {
                                if isSelectMode { toggleSelect(session) } else { openSession(session) }
                            } label: {
                                selectableRow(for: session) { SessionDetailRow(session: session) }
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if !isSelectMode {
                                    Button(role: .destructive) {
                                        sessionToDelete = session; showingDeleteConfirm = true
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }

                                    Button { appState.duplicateSession(session) } label: {
                                        Label("Duplicate", systemImage: "doc.on.doc.fill")
                                    }
                                    .tint(.indigo)

                                    Button {
                                        appState.toggleArchive(session)
                                    } label: {
                                        Label(session.isArchived ? "Unarchive" : "Archive",
                                              systemImage: session.isArchived ? "archivebox.fill" : "archivebox")
                                    }
                                    .tint(.gray)

                                    Button {
                                        UIPasteboard.general.string = session.finalTranscript
                                    } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                    }
                                    .tint(.blue)

                                    Button {
                                        if let url = PDFExportService.exportSession(session) {
                                            exportItems = [url]; showExportSheet = true
                                        }
                                    } label: {
                                        Label("PDF", systemImage: "doc.richtext")
                                    }
                                    .tint(.teal)
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: !isSelectMode) {
                                if !isSelectMode {
                                    let pinLabel = session.isPinned ? "Unpin" : "Pin"
                                    let pinIcon  = session.isPinned ? "pin.slash" : "pin.fill"
                                    Button { appState.togglePin(session) } label: {
                                        Label(pinLabel, systemImage: pinIcon)
                                    }
                                    .tint(.orange)

                                    let starLabel = session.isStarred ? "Unstar" : "Star"
                                    let starIcon  = session.isStarred ? "star.slash" : "star.fill"
                                    Button { appState.toggleStar(session) } label: {
                                        Label(starLabel, systemImage: starIcon)
                                    }
                                    .tint(.yellow)

                                    let lockLabel = session.isLocked ? "Unlock" : "Lock"
                                    let lockIcon  = session.isLocked ? "lock.open" : "lock.fill"
                                    Button { appState.toggleLock(session) } label: {
                                        Label(lockLabel, systemImage: lockIcon)
                                    }
                                    .tint(.gray)
                                }
                            }
                            .contextMenu {
                                // Primary actions
                                Button { openSession(session) } label: {
                                    Label("Open", systemImage: "doc.text.magnifyingglass")
                                }
                                Button { UIPasteboard.general.string = session.finalTranscript } label: {
                                    Label("Copy transcript", systemImage: "doc.on.doc")
                                }
                                Divider()
                                // Toggles
                                Button { appState.toggleStar(session) } label: {
                                    Label(session.isStarred ? "Remove star" : "Star",
                                          systemImage: session.isStarred ? "star.slash" : "star.fill")
                                }
                                Button { appState.togglePin(session) } label: {
                                    Label(session.isPinned ? "Unpin" : "Pin to top",
                                          systemImage: session.isPinned ? "pin.slash" : "pin.fill")
                                }
                                Divider()
                                // Export
                                Button {
                                    if let url = PDFExportService.exportSession(session) {
                                        exportItems = [url]; showExportSheet = true
                                    }
                                } label: {
                                    Label("Export PDF", systemImage: "doc.richtext")
                                }
                                Button { appState.duplicateSession(session) } label: {
                                    Label("Duplicate", systemImage: "doc.on.doc.fill")
                                }
                                Divider()
                                Button { appState.toggleArchive(session) } label: {
                                    Label(session.isArchived ? "Unarchive" : "Archive",
                                          systemImage: "archivebox")
                                }
                                Button(role: .destructive) {
                                    sessionToDelete = session; showingDeleteConfirm = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            } preview: {
                                // Peek preview: compact session card shown while long-pressing
                                let previewTitle = session.customTitle.flatMap { $0.isEmpty ? nil : $0 }
                                let previewText  = session.finalTranscript.isEmpty ? "(empty)" : session.finalTranscript
                                VStack(alignment: .leading, spacing: 10) {
                                    if let title = previewTitle {
                                        Text(title).font(.headline)
                                    }
                                    Text(previewText)
                                        .font(.body)
                                        .lineLimit(8)
                                        .foregroundStyle(.primary)
                                    HStack(spacing: 10) {
                                        Label("\(session.wordCount) words", systemImage: "text.word.spacing")
                                        Label("\(Int(session.durationSeconds))s", systemImage: "timer")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                .padding(20)
                                .frame(width: 300)
                            }
                        }
                    }
                }
            }
        }
        .refreshable {
            // Pull-to-refresh triggers an iCloud sync to pick up changes from other devices.
            await appState.restoreSessionsFromCloud()
        }
        .searchable(text: $searchText, prompt: "Search transcripts")
        .navigationTitle(isSelectMode && !selectedIDs.isEmpty
            ? "\(selectedIDs.count) selected"
            : showArchived ? "Archive" : "History")
        .safeAreaInset(edge: .top, spacing: 0) {
            if !isSelectMode {
                TipView(sortTip, arrowEdge: .top)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelectMode && !selectedIDs.isEmpty {
                bulkActionBar
            } else if !appState.store.isUnlocked && filteredSessions.count > 10 {
                // Upgrade prompt when free users have hidden sessions
                let hiddenCount = filteredSessions.count - 10
                let sessionNoun = hiddenCount == 1 ? "session" : "sessions"
                let upgradeLabel = "\(hiddenCount) older \(sessionNoun) hidden · Upgrade to see all"
                Button {
                    showPaywall = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "crown.fill")
                            .foregroundStyle(Color(red: 0.56, green: 0.18, blue: 0.82))
                        Text(upgradeLabel)
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showPaywall) {
            PremiumPaywallView()
                .environment(appState)
        }
        .task {
            await SortHistoryTip.sessionCount.donate()
            // Apply deep-linked search query on first appearance
            if !initialSearch.isEmpty && searchText.isEmpty {
                searchText = initialSearch
            }
        }
        .toolbar {
            // Leading: Cancel when in select mode; goal progress badge otherwise
            ToolbarItem(placement: .topBarLeading) {
                if isSelectMode {
                    Button("Cancel") {
                        withAnimation(.snappy) {
                            isSelectMode = false
                            selectedIDs = []
                        }
                    }
                } else if let label = todayGoalLabel {
                    todayGoalBadge(label: label)
                }
            }
            // Trailing: Sort + Select button, or Select All when selecting
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isSelectMode {
                    Button(selectedIDs.count == filteredSessions.count ? "Deselect All" : "Select All") {
                        withAnimation(.snappy) {
                            if selectedIDs.count == filteredSessions.count {
                                selectedIDs = []
                            } else {
                                selectedIDs = Set(filteredSessions.map { $0.id })
                            }
                        }
                    }
                } else {
                    Button {
                        withAnimation(.snappy) {
                            isSelectMode = true
                            selectedIDs = []
                        }
                    } label: {
                        Text("Select")
                    }

                    NavigationLink {
                        TagManagementView()
                    } label: {
                        Image(systemName: "tag")
                    }

                    Menu {
                        Picker("Sort", selection: sortOrderBinding) {
                            ForEach(HistorySortOrder.allCases, id: \.self) { order in
                                Label(order.rawValue, systemImage: order.systemImage).tag(order)
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                }
            }
        }
        .sheet(item: $selectedSession) { session in
            SessionSwipeBrowserView(
                sessions: browserSessions.isEmpty ? [session] : browserSessions,
                initialID: session.id
            )
                .environment(appState)
        }
        .confirmationDialog("Delete this session?", isPresented: $showingDeleteConfirm) {
            Button("Delete", role: .destructive) {
                if let s = sessionToDelete { appState.deleteSession(s) }
            }
        }
        .confirmationDialog(
            "Delete \(selectedIDs.count) session\(selectedIDs.count == 1 ? "" : "s")?",
            isPresented: $showBulkDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete \(selectedIDs.count) session\(selectedIDs.count == 1 ? "" : "s")",
                   role: .destructive) {
                bulkDelete()
            }
        } message: {
            Text("This cannot be undone.")
        }
        .confirmationDialog(
            "Merge \(selectedIDs.count) sessions?",
            isPresented: $showMergeConfirm,
            titleVisibility: .visible
        ) {
            Button("Merge into one session") {
                bulkMerge()
            }
        } message: {
            Text("The selected sessions will be combined into a single session. The originals will be removed.")
        }
        .sheet(isPresented: $showExportSheet) {
            ShareSheet(items: exportItems)
                .environment(appState)
        }
        .alert("Rename tag", isPresented: $showTagRenameAlert) {
            TextField("New tag name", text: $tagRenameInput)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Rename") {
                let oldTag = tagToRename
                let newTag = tagRenameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !newTag.isEmpty, newTag != oldTag else { return }
                for session in appState.sessions where session.tags.contains(oldTag) {
                    let updated = session.tags.map { $0 == oldTag ? newTag : $0 }
                    appState.updateTags(sessionID: session.id, tags: updated)
                }
                if filterTag == oldTag { filterTag = newTag }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rename #\(tagToRename) across all sessions that use it.")
        }
    }

    // MARK: - Select-mode helpers

    @ViewBuilder
    private func selectableRow<Content: View>(
        for session: TranscriptionSession,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            if isSelectMode {
                Image(systemName: selectedIDs.contains(session.id)
                      ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selectedIDs.contains(session.id)
                                     ? Color.accentColor : Color(.tertiaryLabel))
                    .animation(.snappy, value: selectedIDs.contains(session.id))
                    .transition(.scale.combined(with: .opacity))
            }
            content()
        }
        .animation(.snappy, value: isSelectMode)
    }

    /// Snapshot filtered sessions then open the swipe browser at the given session.
    private func openSession(_ session: TranscriptionSession) {
        browserSessions = filteredSessions
        selectedSession = session
    }

    private func toggleSelect(_ session: TranscriptionSession) {
        withAnimation(.snappy) {
            if selectedIDs.contains(session.id) {
                selectedIDs.remove(session.id)
            } else {
                selectedIDs.insert(session.id)
            }
        }
    }

    // MARK: - Bulk actions

    private var bulkActionBar: some View {
        HStack(spacing: 0) {
            bulkActionButton(icon: "trash.fill", label: "Delete", tint: .red) {
                showBulkDeleteConfirm = true
            }
            Divider().frame(height: 36).padding(.horizontal, 8)
            bulkActionButton(icon: "doc.richtext.fill", label: "PDF", tint: Color.accentColor) {
                bulkExportPDF()
            }
            Divider().frame(height: 36).padding(.horizontal, 8)
            bulkActionButton(icon: "tag.fill", label: "Tag", tint: .purple) {
                bulkTagInput = ""
                showBulkTagSheet = true
            }
            Divider().frame(height: 36).padding(.horizontal, 8)
            Menu {
                Button {
                    bulkCopy()
                } label: {
                    Label("Copy text", systemImage: "doc.on.doc")
                }
                Divider()
                Button {
                    bulkShareText()
                } label: {
                    Label("Share as plain text", systemImage: "square.and.arrow.up")
                }
                Button {
                    bulkShareMarkdown()
                } label: {
                    Label("Share as Markdown", systemImage: "doc.badge.ellipsis")
                }
                Button {
                    bulkExportCSV()
                } label: {
                    Label("Export as CSV", systemImage: "tablecells")
                }
                Button {
                    bulkExportJSON()
                } label: {
                    Label("Export as JSON", systemImage: "curlybraces")
                }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up.fill")
                        .font(.title3)
                    Text("Export")
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity)
            }
            Divider().frame(height: 36).padding(.horizontal, 8)
            bulkActionButton(icon: "archivebox.fill", label: "Archive", tint: .gray) {
                bulkArchive()
            }
            Divider().frame(height: 36).padding(.horizontal, 8)
            bulkActionButton(icon: "star.fill", label: "Star", tint: .yellow) {
                bulkStar()
            }
            // Compare & Merge — only available when 2+ sessions are selected
            if selectedIDs.count >= 2 {
                Divider().frame(height: 36).padding(.horizontal, 8)
                bulkActionButton(icon: "arrow.triangle.merge", label: "Merge", tint: .teal) {
                    showMergeConfirm = true
                }
                .transition(.scale.combined(with: .opacity))
            }
            if selectedIDs.count == 2 {
                Divider().frame(height: 36).padding(.horizontal, 8)
                bulkActionButton(icon: "chart.bar.xaxis.ascending.badge.clock", label: "Compare", tint: .indigo) {
                    showComparisonSheet = true
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy, value: selectedIDs.count)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
        .sheet(isPresented: $showComparisonSheet) {
            let pair = appState.sessions.filter { selectedIDs.contains($0.id) }
            if pair.count == 2 {
                SessionComparisonView(sessionA: pair[0], sessionB: pair[1])
                    .environment(appState)
            }
        }
        .sheet(isPresented: $showBulkShareSheet) {
            ShareSheet(items: bulkShareItems)
                .environment(appState)
        }
        .sheet(isPresented: $showBulkTagSheet) {
            NavigationStack {
                Form {
                    Section {
                        TextField("Tag name", text: $bulkTagInput)
                            .autocorrectionDisabled()
                    } header: {
                        Text("Apply tag to \(selectedIDs.count) session\(selectedIDs.count == 1 ? "" : "s")")
                    } footer: {
                        Text("The tag will be added to all selected sessions. Existing tags are preserved.")
                    }

                    // Existing tags as quick-select chips
                    let existingTags = Array(Set(appState.sessions.flatMap { $0.tags })).sorted()
                    if !existingTags.isEmpty {
                        Section("Existing tags") {
                            FlowLayout(spacing: 8) {
                                ForEach(existingTags, id: \.self) { tag in
                                    Button(tag) {
                                        bulkTagInput = tag
                                    }
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(bulkTagInput == tag ? Color.purple : Color(.systemGray5),
                                                in: Capsule())
                                    .foregroundStyle(bulkTagInput == tag ? .white : .primary)
                                }
                            }
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        }
                    }
                }
                .navigationTitle("Add Tag")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showBulkTagSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Apply") {
                            bulkApplyTag()
                            showBulkTagSheet = false
                        }
                        .disabled(bulkTagInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium, .large])
                .environment(appState)
        }
    }

    private func bulkActionButton(icon: String, label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                Text(label)
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func bulkDelete() {
        let toDelete = appState.sessions.filter { selectedIDs.contains($0.id) }
        for session in toDelete { appState.deleteSession(session) }
        selectedIDs = []
        withAnimation(.snappy) { isSelectMode = false }
    }

    private func bulkArchive() {
        for i in appState.sessions.indices {
            if selectedIDs.contains(appState.sessions[i].id) {
                appState.sessions[i].isArchived = true
            }
        }
        selectedIDs = []
        withAnimation(.snappy) { isSelectMode = false }
    }

    private func bulkStar() {
        // If any selected session is unstarred, star all. Otherwise unstar all.
        let allStarred = selectedIDs.allSatisfy { id in
            appState.sessions.first(where: { $0.id == id })?.isStarred == true
        }
        for i in appState.sessions.indices {
            if selectedIDs.contains(appState.sessions[i].id) {
                appState.sessions[i].isStarred = !allStarred
            }
        }
        if appState.profile.hapticFeedbackEnabled { HapticManager.softConfirm() }
        selectedIDs = []
        withAnimation(.snappy) { isSelectMode = false }
    }

    private func bulkExportPDF() {
        let sessions = appState.sessions
            .filter { selectedIDs.contains($0.id) }
            .sorted { $0.startedAt > $1.startedAt }
        if let url = PDFExportService.exportSessions(sessions) {
            exportItems = [url]
            showExportSheet = true
        }
    }

    private func bulkCopy() {
        let text = appState.sessions
            .filter { selectedIDs.contains($0.id) }
            .sorted { $0.startedAt > $1.startedAt }
            .map { $0.finalTranscript.isEmpty ? "(empty)" : $0.finalTranscript }
            .joined(separator: "\n\n---\n\n")
        UIPasteboard.general.string = text
    }

    private func bulkShareText() {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        let text = appState.sessions
            .filter { selectedIDs.contains($0.id) }
            .sorted { $0.startedAt > $1.startedAt }
            .map { s in
                let header = "[\(df.string(from: s.startedAt))] [\(s.wordCount) words]"
                let body   = s.finalTranscript.isEmpty ? "(empty)" : s.finalTranscript
                return "\(header)\n\(body)"
            }
            .joined(separator: "\n\n---\n\n")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lexora_selected_\(Date().formatted(.iso8601)).txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        bulkShareItems = [url]
        showBulkShareSheet = true
    }

    private func bulkShareMarkdown() {
        let isoDF = ISO8601DateFormatter(); isoDF.formatOptions = [.withFullDate]
        let pages = appState.sessions
            .filter { selectedIDs.contains($0.id) }
            .sorted { $0.startedAt > $1.startedAt }
            .map { s -> String in
                let title = s.customTitle ?? String(s.finalTranscript.prefix(60))
                let tags  = s.tags.isEmpty ? "[]" : "[" + s.tags.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
                let fm = "---\ntitle: \"\(title)\"\ndate: \(isoDF.string(from: s.startedAt))\nwords: \(s.wordCount)\ntags: \(tags)\n---"
                return fm + "\n\n" + (s.finalTranscript.isEmpty ? "*(empty)*" : s.finalTranscript)
            }
        let md = pages.joined(separator: "\n\n---\n\n")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lexora_selected_\(Date().formatted(.iso8601)).md")
        try? md.write(to: url, atomically: true, encoding: .utf8)
        bulkShareItems = [url]
        showBulkShareSheet = true
    }

    private func bulkExportCSV() {
        let isoDF = ISO8601DateFormatter(); isoDF.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        func esc(_ s: String) -> String { "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" }
        var rows = ["date,title,words,confidence,language,tags,notes,transcript"]
        let selected = appState.sessions.filter { selectedIDs.contains($0.id) }.sorted { $0.startedAt > $1.startedAt }
        for s in selected {
            let date = isoDF.string(from: s.startedAt)
            let title = esc(s.customTitle ?? "")
            let words = "\(s.wordCount)"
            let confidence = String(format: "%.2f", s.confidenceAverage)
            let lang = esc(s.primaryLanguage)
            let tags = esc(s.tags.joined(separator: "; "))
            let notes = esc(s.notes ?? "")
            let transcript = esc(s.finalTranscript)
            rows.append([date, title, words, confidence, lang, tags, notes, transcript].joined(separator: ","))
        }
        let csv = rows.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lexora_export_\(Date().formatted(.iso8601)).csv")
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        bulkShareItems = [url]
        showBulkShareSheet = true
    }

    private func bulkExportJSON() {
        let isoDF = ISO8601DateFormatter(); isoDF.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let selected = appState.sessions.filter { selectedIDs.contains($0.id) }.sorted { $0.startedAt > $1.startedAt }
        let array: [[String: Any]] = selected.map { s in
            var dict: [String: Any] = [
                "id": s.id.uuidString,
                "date": isoDF.string(from: s.startedAt),
                "wordCount": s.wordCount,
                "averageConfidence": s.confidenceAverage,
                "primaryLanguage": s.primaryLanguage,
                "tags": s.tags,
                "transcript": s.finalTranscript,
                "isStarred": s.isStarred,
                "isPinned": s.isPinned,
                "isLocked": s.isLocked
            ]
            if let title = s.customTitle { dict["title"] = title }
            if let notes = s.notes { dict["notes"] = notes }
            return dict
        }
        guard let data = try? JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lexora_export_\(Date().formatted(.iso8601)).json")
        try? json.write(to: url, atomically: true, encoding: .utf8)
        bulkShareItems = [url]
        showBulkShareSheet = true
    }

    private func bulkMerge() {
        let toMerge = appState.sessions.filter { selectedIDs.contains($0.id) }
        guard toMerge.count >= 2 else { return }
        appState.mergeSessions(toMerge)
        withAnimation(.snappy) {
            selectedIDs = []
            isSelectMode = false
        }
    }

    private func bulkApplyTag() {
        let tag = bulkTagInput.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty else { return }
        for session in appState.sessions where selectedIDs.contains(session.id) {
            var newTags = session.tags
            if !newTags.contains(tag) { newTags.append(tag) }
            appState.updateTags(sessionID: session.id, tags: newTags)
        }
        withAnimation(.snappy) {
            isSelectMode = false
            selectedIDs = []
        }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(
                    label: "All",
                    icon: "list.bullet",
                    isActive: !filterStarred && filterTag == nil && !filterHasAudio && !filterHasNotes
                ) {
                    filterStarred = false
                    filterTag = nil
                    filterHasAudio = false
                    filterHasNotes = false
                }

                filterChip(
                    label: "Starred",
                    icon: "star.fill",
                    isActive: filterStarred
                ) {
                    filterStarred.toggle()
                    if filterStarred { filterTag = nil; showArchived = false }
                }

                let archivedCount = appState.sessions.filter { $0.isArchived }.count
                if archivedCount > 0 {
                    filterChip(
                        label: "Archived (\(archivedCount))",
                        icon: "archivebox.fill",
                        isActive: showArchived
                    ) {
                        showArchived.toggle()
                        if showArchived { filterStarred = false; filterTag = nil }
                    }
                }

                // Has audio chip (only when some sessions have recordings)
                if appState.sessions.contains(where: { $0.audioFileURL != nil }) {
                    filterChip(
                        label: "Has audio",
                        icon: "waveform.and.mic",
                        isActive: filterHasAudio
                    ) {
                        filterHasAudio.toggle()
                    }
                }

                // Has notes chip
                if appState.sessions.contains(where: { $0.notes?.isEmpty == false }) {
                    filterChip(
                        label: "Has notes",
                        icon: "note.text",
                        isActive: filterHasNotes
                    ) {
                        filterHasNotes.toggle()
                    }
                }

                // Date range chip
                filterChip(
                    label: showDateFilter ? dateRangeLabel : "Date range",
                    icon: "calendar",
                    isActive: showDateFilter
                ) {
                    withAnimation(.snappy) { showDateFilter.toggle() }
                }

                // Language filter chips (only when sessions span ≥ 2 languages)
                if !allLanguages.isEmpty {
                    ForEach(allLanguages, id: \.code) { lang in
                        let name = Locale.current.localizedString(forLanguageCode: lang.code)
                               ?? lang.code.uppercased()
                        filterChip(
                            label: "\(name) (\(lang.count))",
                            icon: "globe",
                            isActive: filterLanguage == lang.code
                        ) {
                            filterLanguage = (filterLanguage == lang.code) ? nil : lang.code
                        }
                    }
                }

                if !allTags.isEmpty {
                    Divider()
                        .frame(height: 20)
                        .padding(.horizontal, 2)

                    ForEach(allTags.prefix(8), id: \.self) { tag in
                        filterChip(
                            label: "#\(tag)",
                            icon: nil,
                            isActive: filterTag == tag
                        ) {
                            if filterTag == tag {
                                filterTag = nil
                            } else {
                                filterTag = tag
                                filterStarred = false
                            }
                        }
                        .contextMenu {
                            // Count sessions with this tag
                            let count = appState.sessions.filter { $0.tags.contains(tag) }.count
                            Text("\(count) session\(count == 1 ? "" : "s") with #\(tag)")

                            Button {
                                tagToRename = tag
                                tagRenameInput = tag
                                showTagRenameAlert = true
                            } label: {
                                Label("Rename tag", systemImage: "pencil")
                            }

                            Button(role: .destructive) {
                                // Remove this tag from all sessions
                                for session in appState.sessions where session.tags.contains(tag) {
                                    let updated = session.tags.filter { $0 != tag }
                                    appState.updateTags(sessionID: session.id, tags: updated)
                                }
                                if filterTag == tag { filterTag = nil }
                            } label: {
                                Label("Remove tag from all sessions", systemImage: "tag.slash")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
    }

    private var dateRangeLabel: String {
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        return "\(df.string(from: filterFromDate)) – \(df.string(from: filterToDate))"
    }

    /// Expanded date picker shown inline below the filter bar when date filter is active.
    @ViewBuilder
    var dateRangePicker: some View {
        if showDateFilter {
            VStack(spacing: 4) {
                DatePicker(
                    "From",
                    selection: $filterFromDate,
                    in: ...filterToDate,
                    displayedComponents: .date
                )
                DatePicker(
                    "To",
                    selection: $filterToDate,
                    in: filterFromDate...,
                    displayedComponents: .date
                )
            }
            .datePickerStyle(.compact)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemGroupedBackground))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func filterChip(label: String, icon: String?, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption2)
                }
                Text(label)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isActive ? Color.accentColor : Color(.systemGray5), in: Capsule())
            .foregroundStyle(isActive ? .white : .primary)
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: isActive)
    }

    // MARK: - Grouping

    private struct SessionGroup {
        var key: String
        var sessions: [TranscriptionSession]
    }

    /// Free users see their 10 most recent sessions; premium users see all.
    private var visibleSessions: [TranscriptionSession] {
        guard !appState.store.isUnlocked else { return filteredSessions }
        return Array(filteredSessions.prefix(10))
    }

    private var groupedSessions: [SessionGroup] {
        let sessions = visibleSessions
        let pinned   = sessions.filter { $0.isPinned }
        let unpinned = sessions.filter { !$0.isPinned }

        var groups: [SessionGroup] = []
        if !pinned.isEmpty {
            groups.append(SessionGroup(key: "📌 Pinned", sessions: pinned))
        }

        // For non-date sorts, show a single flat section
        guard sortOrder == .dateDesc || sortOrder == .dateAsc else {
            if !unpinned.isEmpty {
                groups.append(SessionGroup(key: "All Results", sessions: unpinned))
            }
            return groups
        }

        // Bucket sessions into meaningful time ranges
        let cal      = Calendar.current
        let now      = Date()
        let today    = cal.startOfDay(for: now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
        let weekStart = cal.date(byAdding: .day, value: -7, to: today) ?? today
        let monthStart = cal.date(byAdding: .day, value: -30, to: today) ?? today
        let lastMonthStart = cal.date(byAdding: .day, value: -60, to: today) ?? today

        func bucket(_ s: TranscriptionSession) -> (key: String, order: Int) {
            let d = s.startedAt
            if cal.isDateInToday(d)                                  { return ("Today",      0) }
            if cal.isDateInYesterday(d)                              { return ("Yesterday",  1) }
            if d >= weekStart && d < yesterday                       { return ("This Week",  2) }
            if d >= monthStart && d < weekStart                      { return ("This Month", 3) }
            if d >= lastMonthStart && d < monthStart                 { return ("Last Month", 4) }
            return ("Earlier", 5)
        }

        let bucketedDict = Dictionary(grouping: unpinned) { bucket($0).key }
        let bucketOrder: [String] = ["Today", "Yesterday", "This Week", "This Month", "Last Month", "Earlier"]
        let ascending = sortOrder == .dateAsc

        let orderedBuckets = bucketOrder.compactMap { key -> SessionGroup? in
            guard let sessions = bucketedDict[key], !sessions.isEmpty else { return nil }
            let sorted = sessions.sorted { ascending ? $0.startedAt < $1.startedAt : $0.startedAt > $1.startedAt }
            return SessionGroup(key: key, sessions: sorted)
        }

        // For ascending date sort, reverse the bucket order so earliest bucket comes first
        groups.append(contentsOf: ascending ? orderedBuckets.reversed() : orderedBuckets)
        return groups
    }

    @ViewBuilder
    private func todayGoalBadge(label: String) -> some View {
        let goalColor: Color = todayGoalMet ? .green : .accentColor
        let goalIcon  = todayGoalMet ? "checkmark.circle.fill" : "target"
        HStack(spacing: 4) {
            Image(systemName: goalIcon)
                .font(.system(size: 12, weight: .semibold))
            Text(label)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(goalColor)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background { Capsule().fill(goalColor.opacity(0.12)) }
        .contentTransition(.numericText())
        .animation(.snappy, value: todayWordCount)
    }
}

// MARK: - Session row

struct SessionDetailRow: View {
    var session: TranscriptionSession

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 4) {
                Image(systemName: "waveform")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.1), in: Circle())

                HStack(spacing: 3) {
                    if session.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if session.isStarred {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    if session.isLocked {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                if let title = session.customTitle, !title.isEmpty {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(session.finalTranscript.isEmpty ? "(empty)" : session.finalTranscript)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text(session.finalTranscript.isEmpty ? "(empty)" : session.finalTranscript)
                        .font(.subheadline)
                        .lineLimit(3)
                }

                HStack(spacing: 6) {
                    Text(session.startedAt.formatted(date: .omitted, time: .shortened))
                    Text("·")
                    Text("\(Int(session.durationSeconds))s")
                    Text("·")
                    Text("\(session.wordCount)w")
                    if session.wordCount > 0 {
                        let readSecs = max(1, Int((Double(session.wordCount) / 238.0) * 60))
                        Text("·")
                        Label(readSecs >= 60 ? "\(readSecs / 60)m read" : "\(readSecs)s read",
                              systemImage: "book.pages")
                            .labelStyle(.titleOnly)
                    }
                    if session.codeSwitch {
                        Text("·")
                        Image(systemName: "globe").font(.caption2).foregroundStyle(.blue)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let app = session.appName {
                    Text("via \(app)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if !session.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(session.tags.prefix(3), id: \.self) { tag in
                            let color = templateTagColor(tag)
                            Text(tag)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(color.opacity(0.12), in: Capsule())
                                .foregroundStyle(color)
                        }
                        if session.tags.count > 3 {
                            Text("+\(session.tags.count - 3)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                languageBadge(session.primaryLanguage)
                accuracyBadge(session.estimatedAccuracy)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel({
            let title = session.customTitle ?? String(session.finalTranscript.prefix(60))
            let words = "\(session.wordCount) words"
            let duration = "\(Int(session.durationSeconds)) seconds"
            let accuracy = session.estimatedAccuracy > 0 ? ", \(Int(session.estimatedAccuracy)) percent accuracy" : ""
            return "\(title). \(words), \(duration)\(accuracy)"
        }())
        .accessibilityHint("Tap to open session detail")
    }

    /// Returns a template-specific accent color when the tag name matches a recording template.
    /// Falls back to the app accent color for generic tags.
    private func templateTagColor(_ tag: String) -> Color {
        switch tag.lowercased() {
        case "meeting":                 return .blue
        case "lecture":                 return .purple
        case "quick note", "note":      return .green
        case "dictation":               return .orange
        case "interview":               return .red
        case "typed":                   return .teal
        case "morning", "afternoon",
             "evening", "night":        return .indigo
        default:                        return .accentColor
        }
    }

    private func accuracyBadge(_ accuracy: Double) -> some View {
        let color: Color = accuracy > 90 ? .green : accuracy > 75 ? .orange : .red
        return Text("\(Int(accuracy))%")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
            .opacity(accuracy > 0 ? 1 : 0)
            .accessibilityLabel(accuracy > 0 ? "Accuracy: \(Int(accuracy)) percent" : "")
    }

    /// Color-coded language badge — each language code maps to a consistent hue.
    private func languageBadge(_ code: String) -> some View {
        let label = code.components(separatedBy: "-").first?.uppercased() ?? code.uppercased()
        // Hash the language prefix to pick a consistent color
        let colors: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .mint, .cyan]
        let idx = abs(label.hashValue) % colors.count
        let color = colors[idx]
        return Text(label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - Search Result Row (shows transcript excerpt around the match)

struct SearchResultRow: View {
    var session: TranscriptionSession
    var query: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: session.isStarred ? "star.fill" : "waveform")
                .foregroundStyle(session.isStarred ? Color.yellow : Color.accentColor)
                .font(.body)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.08), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                // Title or date
                Text(session.customTitle ?? session.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                // Excerpt highlighting where the match occurs
                if let excerpt = matchExcerpt(in: session.finalTranscript, query: query) {
                    Text(excerpt)
                        .font(.subheadline)
                        .lineLimit(3)
                } else if let notes = session.notes,
                          let notesExcerpt = matchExcerpt(in: notes, query: query) {
                    // Match found in notes — show a badge and the notes excerpt
                    HStack(spacing: 5) {
                        Text("Notes")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.orange, in: Capsule())
                        Text(notesExcerpt)
                            .font(.subheadline)
                            .lineLimit(2)
                    }
                } else {
                    Text(session.finalTranscript.isEmpty ? "(empty)" : session.finalTranscript)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    Text("\(session.wordCount)w")
                    Text("·")
                    Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    /// Returns an `AttributedString` excerpt centred around the first match of `query`.
    private func matchExcerpt(in text: String, query: String) -> AttributedString? {
        guard !query.isEmpty,
              let matchRange = text.range(of: query, options: .caseInsensitive) else { return nil }

        // Take up to 120 characters around the match
        let start = text.index(matchRange.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end   = text.index(matchRange.upperBound,  offsetBy:  80,  limitedBy: text.endIndex)   ?? text.endIndex
        let excerpt = String(text[start..<end])
        let prefix  = start > text.startIndex ? "…" : ""
        let suffix  = end   < text.endIndex   ? "…" : ""
        let display = prefix + excerpt + suffix

        var attributed = AttributedString(display)
        // Highlight the query substring
        if let range = attributed.range(of: query, options: .caseInsensitive) {
            attributed[range].foregroundColor = UIColor.tintColor.swiftUIColor
            attributed[range].font = .subheadline.weight(.semibold)
        }
        return attributed
    }
}

// UIColor → SwiftUI Color bridge
extension UIColor {
    var swiftUIColor: Color { Color(uiColor: self) }
}

// Numeric clamping utility used by readability score display
extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Session detail sheet

struct SessionDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    var session: TranscriptionSession

    @State private var editedText: String
    @State private var customTitle: String
    @State private var notes: String
    @State private var didEdit = false
    @State private var showingShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var showFilesExporter = false
    @State private var filesToExport: URL? = nil
    @State private var isRenderingCard = false
    @State private var tags: [String]
    @State private var newTag = ""
    @FocusState private var tagFieldFocused: Bool
    private let editTip = EditTranscriptTip()

    // Font size preference (shared with SettingsView)
    @AppStorage("transcriptFontSize") private var transcriptFontSize: Double = 16.0

    // Similar sessions navigation
    @State private var selectedSimilarSession: TranscriptionSession? = nil

    // Audio playback
    @State private var audioPlayer: AVAudioPlayer? = nil
    @State private var isPlayingAudio = false
    @State private var audioProgress: Double = 0         // 0…1
    @State private var audioDuration: Double = 0
    @State private var audioCurrentTime: Double = 0
    @State private var playbackRate: Float = 1.0          // 0.5 / 1 / 1.5 / 2
    private let audioTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    // Diff view
    @State private var showDiffSheet = false
    // Find & Replace
    @State private var showFindReplace = false
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var matchRanges: [Range<String.Index>] = []
    @State private var currentMatchIndex = 0
    @FocusState private var findFieldFocused: Bool

    // Smart tag suggestions
    @State private var suggestedTags: [String] = []
    // Auto-generated summary (computed lazily on first appearance)
    @State private var autoSummary: String? = nil
    // Named entities extracted from the transcript
    @State private var namedEntities: [(text: String, type: String)] = []
    // Auto-title suggestion (shown when no custom title is set)
    @State private var suggestedTitle: String? = nil
    // Quick "record follow-up" sheet
    @State private var showingRecorder = false
    // Text-to-speech
    @State private var speechSynthesizer = AVSpeechSynthesizer()
    @State private var isSpeaking = false
    // Spell-check
    @State private var spellingMisspellings: [String] = []
    @State private var showSpellPanel = false
    @State private var spellCheckAllClear = false

    // Vocabulary suggestions
    @State private var vocabSuggestExpanded = true
    @State private var dismissedVocabSuggestions = Set<String>()

    // Reading mode
    @State private var showReadingMode = false

    // Premium
    @State private var showPaywall = false

    // Sentiment
    @State private var sentimentScore: Double? = nil   // -1 (negative) … +1 (positive)

    // Chapters
    @State private var chapters: [TranscriptChapter] = []
    @State private var showChapterEditor = false
    @State private var newChapterTitle = ""
    @State private var newChapterOffset = 0

    // AI features
    @State private var aiSummary: String? = nil
    @State private var aiActionItems: [String] = []
    @State private var aiFollowUps: [String] = []
    @State private var isLoadingAI = false
    @State private var aiError: String? = nil
    @State private var aiPanelExpanded = false

    /// Live lock state, reflecting changes made through AppState.toggleLock.
    private var isLocked: Bool {
        appState.sessions.first { $0.id == session.id }?.isLocked ?? session.isLocked
    }

    /// Estimated reading time in minutes (at 238 wpm average).
    private var readingTimeMinutes: Int {
        max(1, session.wordCount / 238)
    }

    init(session: TranscriptionSession) {
        self.session = session
        _editedText  = State(initialValue: session.finalTranscript)
        _customTitle = State(initialValue: session.customTitle ?? "")
        _notes       = State(initialValue: session.notes ?? "")
        _tags        = State(initialValue: session.tags)
        _chapters    = State(initialValue: session.chapters)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Locked banner
                    if isLocked {
                        HStack(spacing: 10) {
                            Image(systemName: "lock.fill")
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Session locked")
                                    .font(.subheadline.weight(.semibold))
                                Text("Tap the lock icon to enable editing.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.25), lineWidth: 1))
                    }

                    // Editable session title
                    TextField(
                        "Session title (optional)",
                        text: $customTitle,
                        axis: .vertical
                    )
                    .font(.title3.weight(.semibold))
                    .submitLabel(.done)
                    .disabled(isLocked)
                    .onChange(of: customTitle) { _, _ in
                        didEdit = true
                        // Dismiss suggestion once user types something
                        if !customTitle.isEmpty { suggestedTitle = nil }
                    }

                    // Smart title suggestion (only when no title set)
                    if let suggestion = suggestedTitle, customTitle.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                            Text("Suggested: \"\(suggestion)\"")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Button("Apply") {
                                withAnimation(.snappy) {
                                    customTitle = suggestion
                                    suggestedTitle = nil
                                    didEdit = true
                                }
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            Button {
                                withAnimation(.snappy) { suggestedTitle = nil }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    sessionStatsCard

                    pacingChart

                    sessionMeta

                    if session.audioFileURL != nil {
                        audioPlaybackCard
                    }

                    if let summary = autoSummary {
                        summaryCard(summary)
                    }

                    // AI panel — premium + API key required
                    if appState.store.isUnlocked {
                        if appState.ai.hasAPIKey {
                            aiPanel
                        }
                    } else {
                        // Teaser: show panel header with upgrade prompt
                        PremiumUpgradeBanner(showPaywall: $showPaywall)
                    }

                    sessionTopWordsCard

                    if !extractedBookmarks.isEmpty {
                        bookmarksPanel
                    }

                    // Chapters panel — always show when long enough or chapters exist
                    if !chapters.isEmpty || editedText.split(separator: " ").count > 300 {
                        chaptersPanel
                    }

                    if !session.fillerWords.isEmpty {
                        fillerWordsBanner
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 14) {
                            Label("Transcript", systemImage: "doc.text")
                                .font(.headline)
                            Spacer()
                            // Copy all transcript to clipboard
                            Button {
                                UIPasteboard.general.string = editedText
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .foregroundStyle(Color.accentColor)
                                    .font(.subheadline)
                            }
                            .buttonStyle(.plain)
                            .help("Copy transcript")
                            // Format into paragraphs (only available when segment timing data exists)
                            if !session.segments.isEmpty {
                                Button {
                                    formatTranscriptParagraphs()
                                } label: {
                                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                                        .foregroundStyle(Color.accentColor)
                                        .font(.subheadline)
                                }
                                .buttonStyle(.plain)
                                .help("Auto-format into paragraphs based on pauses")
                            }
                            // Show diff vs original (only when the transcript has been edited)
                            if !session.rawTranscript.isEmpty && session.rawTranscript != editedText {
                                Button {
                                    showDiffSheet = true
                                } label: {
                                    Image(systemName: "arrow.left.arrow.right")
                                        .foregroundStyle(Color.orange)
                                        .font(.subheadline)
                                }
                                .buttonStyle(.plain)
                                .help("Show changes vs original transcript")
                            }
                            Button {
                                withAnimation(.snappy) {
                                    showFindReplace.toggle()
                                    if showFindReplace { findFieldFocused = true }
                                    else { findText = ""; matchRanges = [] }
                                }
                            } label: {
                                Image(systemName: showFindReplace ? "xmark.circle.fill" : "magnifyingglass")
                                    .foregroundStyle(showFindReplace ? .secondary : Color.accentColor)
                                    .font(.subheadline)
                            }
                            .buttonStyle(.plain)
                            .help("Find & replace text")

                            // Spell-check button
                            Button {
                                if showSpellPanel {
                                    withAnimation(.snappy) { showSpellPanel = false }
                                } else {
                                    runSpellCheck()
                                }
                            } label: {
                                Group {
                                    if spellCheckAllClear {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    } else if showSpellPanel {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.red.opacity(0.7))
                                    } else {
                                        Image(systemName: "checkmark.circle")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .font(.subheadline)
                            }
                            .buttonStyle(.plain)
                            .help(showSpellPanel ? "Hide spell-check results" : "Check spelling")
                            .accessibilityLabel(showSpellPanel ? "Hide spelling panel" : "Run spell check")
                            .animation(.easeInOut(duration: 0.2), value: spellCheckAllClear)
                            .animation(.easeInOut(duration: 0.2), value: showSpellPanel)

                            // Reading mode button (premium)
                            Button {
                                if appState.store.isUnlocked {
                                    showReadingMode = true
                                } else {
                                    showPaywall = true
                                }
                            } label: {
                                ZStack(alignment: .topTrailing) {
                                    Image(systemName: "text.magnifyingglass")
                                        .foregroundStyle(Color.accentColor)
                                        .font(.subheadline)
                                    if !appState.store.isUnlocked {
                                        Image(systemName: "crown.fill")
                                            .font(.system(size: 7))
                                            .foregroundStyle(Color(red: 0.56, green: 0.18, blue: 0.82))
                                            .offset(x: 6, y: -4)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .help(appState.store.isUnlocked ? "Open in reading mode" : "Reading mode requires Premium")
                            .disabled(editedText.isEmpty)
                        }

                        if showFindReplace {
                            findReplaceBar
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        if showSpellPanel && !spellingMisspellings.isEmpty {
                            spellingPanel
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        TipView(editTip)
                            .padding(.bottom, 4)

                        TextEditor(text: $editedText)
                            .font(.system(size: transcriptFontSize))
                            .frame(minHeight: 200)
                            .padding(12)
                            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
                            .disabled(isLocked)
                            .opacity(isLocked ? 0.65 : 1)
                            .onChange(of: editedText) { _, _ in
                                didEdit = true
                                recomputeMatches()
                            }

                        // Readability indicator (shown when there's enough text to be meaningful)
                        if session.wordCount > 50 {
                            let re = fleschReadabilityScore(text: editedText)
                            HStack(spacing: 6) {
                                Image(systemName: "chart.bar.doc.horizontal")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text("Readability: \(readabilityLabel(re))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text("(\(Int(re.clamped(to: 0...100))))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                Spacer()
                            }
                        }
                    }

                    tagEditorSection

                    notesSection

                    vocabSuggestSection

                    confidenceHighlightSection

                    if session.codeSwitch {
                        languageSpansView
                    }

                    similarSessionsSection

                    Text("Editing this transcript teaches Lexora your corrections.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .navigationTitle("Session")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selectedSimilarSession) { s in
                NavigationStack { SessionDetailView(session: s) }
                    .environment(appState)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            shareItems = [editedText]
                            showingShareSheet = true
                        } label: {
                            Label("Share text", systemImage: "doc.text")
                        }
                        Button {
                            if let pdfURL = PDFExportService.exportSession(session) {
                                shareItems = [pdfURL]
                                showingShareSheet = true
                            }
                        } label: {
                            Label("Export as PDF", systemImage: "doc.richtext")
                        }
                        Button {
                            if let srtURL = SRTExportService.exportSession(session) {
                                shareItems = [srtURL]
                                showingShareSheet = true
                            }
                        } label: {
                            Label("Export as SRT subtitles", systemImage: "captions.bubble")
                        }
                        Button {
                            if let mdURL = exportSessionAsMarkdown(session: session, text: editedText) {
                                shareItems = [mdURL]
                                showingShareSheet = true
                            }
                        } label: {
                            Label("Export as Markdown", systemImage: "doc.plaintext")
                        }
                        Button {
                            filesToExport = saveTranscriptToTemp(session: session, text: editedText)
                            if filesToExport != nil { showFilesExporter = true }
                        } label: {
                            Label("Save to Files", systemImage: "folder.badge.plus")
                        }
                        Button {
                            shareSessionCard()
                        } label: {
                            if isRenderingCard {
                                Label("Rendering…", systemImage: "arrow.triangle.2.circlepath")
                            } else {
                                Label("Share as image", systemImage: "photo")
                            }
                        }
                        .disabled(isRenderingCard)
                        Button {
                            shareWordCloudCard()
                        } label: {
                            Label("Share word cloud", systemImage: "cloud.fill")
                        }
                        .disabled(editedText.split(separator: " ").count < 5)
                        Button {
                            UIPasteboard.general.string = editedText
                        } label: {
                            Label("Copy text", systemImage: "doc.on.doc")
                        }
                        Divider()
                        Button {
                            toggleReadAloud()
                        } label: {
                            Label(isSpeaking ? "Stop reading" : "Read aloud",
                                  systemImage: isSpeaking ? "stop.circle" : "text.and.command.macwindow")
                        }
                        Divider()
                        // AI Insights — only when key is set
                        if appState.ai.hasAPIKey {
                            Button {
                                withAnimation(.spring(response: 0.35)) {
                                    aiPanelExpanded = true
                                }
                                if aiSummary == nil && !isLoadingAI {
                                    fetchAIContent()
                                }
                            } label: {
                                Label("AI Insights", systemImage: "sparkles")
                            }
                            Divider()
                        }
                        // Continue this topic — opens recorder pre-tagged with this session's tags
                        Button {
                            continueThisTopic()
                        } label: {
                            Label("Continue this topic", systemImage: "arrow.right.circle")
                        }
                        // Share as webpage
                        Button {
                            if let url = HTMLExportService.exportSession(session) {
                                shareItems = [url]
                                showingShareSheet = true
                            }
                        } label: {
                            Label("Share as webpage", systemImage: "globe")
                        }
                        // Remind me to revisit — schedules a notification
                        Menu {
                            ForEach([1, 3, 7, 14], id: \.self) { days in
                                Button {
                                    scheduleRevisitReminder(inDays: days)
                                } label: {
                                    Text(days == 1 ? "Tomorrow" : "In \(days) days")
                                }
                            }
                        } label: {
                            Label("Remind me to revisit", systemImage: "bell.badge.clock")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(editedText.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        appState.toggleLock(session)
                        if appState.profile.hapticFeedbackEnabled { HapticManager.softConfirm() }
                    } label: {
                        Image(systemName: isLocked ? "lock.fill" : "lock.open")
                            .foregroundStyle(isLocked ? .orange : .secondary)
                    }
                    .help(isLocked ? "Unlock session" : "Lock session to prevent editing")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if didEdit {
                            appState.recordCorrection(
                                original: session.finalTranscript,
                                corrected: editedText,
                                sessionID: session.id
                            )
                        }
                        // Persist tag, title, notes, and chapter changes
                        appState.updateTags(sessionID: session.id, tags: tags)
                        appState.updateTitle(sessionID: session.id,
                                             title: customTitle.isEmpty ? nil : customTitle)
                        appState.updateNotes(sessionID: session.id,
                                             notes: notes.isEmpty ? nil : notes)
                        appState.updateChapters(sessionID: session.id, chapters: chapters)
                        dismiss()
                    }
                    .bold(didEdit || tags != session.tags || customTitle != (session.customTitle ?? "") || notes != (session.notes ?? "") || chapters != session.chapters)
                    .disabled(isLocked)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        showingRecorder = true
                    } label: {
                        Label("Record follow-up", systemImage: "mic.badge.plus")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Color.accentColor.opacity(0.85))
                }
            }
            .sheet(isPresented: $showingRecorder) {
                RecordingView()
                    .environment(appState)
            }
            .sheet(isPresented: $showReadingMode) {
                TranscriptReadingView(text: editedText, session: session, sentimentScore: sentimentScore)
                    .environment(appState)
            }
            .sheet(isPresented: $showPaywall) {
                PremiumPaywallView()
                    .environment(appState)
            }
            .sheet(isPresented: $showingShareSheet) {
                ShareSheet(items: shareItems)
                    .environment(appState)
            }
            .sheet(isPresented: $showFilesExporter) {
                if let url = filesToExport {
                    FilesExporter(url: url) { showFilesExporter = false }
                        .environment(appState)
                }
            }
            .sheet(isPresented: $showDiffSheet) {
                TranscriptDiffView(original: session.rawTranscript, edited: editedText)
                    .environment(appState)
            }
            .task {
                // Compute keyword suggestions, auto-summary, and named entities concurrently.
                try? await Task.sleep(for: .milliseconds(200))
                async let keywords  = extractKeywordsAsync(from: editedText)
                async let summary   = buildSummaryAsync(from: editedText)
                async let entities  = extractNamedEntitiesAsync(from: editedText)
                async let sentiment = computeSentimentAsync(from: editedText)
                suggestedTags   = await keywords
                autoSummary     = await summary
                namedEntities   = await entities
                sentimentScore  = await sentiment

                // Suggest a title from the first sentence when none is set.
                if session.customTitle == nil, !editedText.isEmpty {
                    let firstSentence = editedText
                        .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
                        .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if firstSentence.count > 6 {
                        let maxLen = 55
                        let raw = firstSentence.count > maxLen
                            ? String(firstSentence.prefix(maxLen)).trimmingCharacters(in: .whitespaces) + "…"
                            : firstSentence
                        // Title-case first character
                        suggestedTitle = raw.prefix(1).uppercased() + raw.dropFirst()
                    }
                }

                // Pre-load audio player if an audio file is attached.
                if let url = session.audioFileURL,
                   let player = try? AVAudioPlayer(contentsOf: url) {
                    player.enableRate = true          // required for variable-speed playback
                    player.rate = playbackRate
                    audioPlayer = player
                    player.prepareToPlay()
                    audioDuration = player.duration
                }
            }
            .onDisappear {
                audioPlayer?.stop()
                audioPlayer = nil
                if isSpeaking {
                    speechSynthesizer.stopSpeaking(at: .immediate)
                    isSpeaking = false
                }
            }
            .onReceive(audioTimer) { _ in
                guard let player = audioPlayer, isPlayingAudio else { return }
                audioCurrentTime = player.currentTime
                audioProgress = audioDuration > 0 ? player.currentTime / audioDuration : 0
                if !player.isPlaying {
                    isPlayingAudio = false
                    audioProgress = 0
                    audioCurrentTime = 0
                }
            }
        }
    }

    // MARK: - Template tag color helper (mirrors SessionDetailRow.templateTagColor)

    private func templateTagColor(_ tag: String) -> Color {
        switch tag.lowercased() {
        case "meeting":             return .blue
        case "lecture":             return .purple
        case "quick note", "note":  return .green
        case "dictation":           return .orange
        case "interview":           return .red
        default:                    return .accentColor
        }
    }

    // MARK: - Follow-up Actions

    /// Opens the recorder sheet pre-tagged with the current session's tags, so the user
    /// can continue dictating on the same topic without manually re-tagging.
    private func continueThisTopic() {
        // Post the standard start-recording notification with tags in userInfo.
        // RecordingView doesn't have a direct `pendingTags` param yet, so we
        // wire it via AppState's `pendingTemplateTags` which are applied when the
        // session finalises.
        appState.primeNextSessionTags(session.tags)
        showingRecorder = true
    }

    /// Schedules a local notification `days` from now reminding the user to revisit
    /// this specific session via a deep-link.
    private func scheduleRevisitReminder(inDays days: Int) {
        let content = UNMutableNotificationContent()
        let title = session.customTitle ?? String(session.finalTranscript.prefix(40))
        content.title = "Revisit: \(title)"
        content.body  = "You asked to be reminded to review this session."
        content.sound = .default
        content.userInfo = ["deeplink": "lexora://session/\(session.id.uuidString)"]

        var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute],
                                                     from: Date())
        comps.day = (comps.day ?? 0) + days
        comps.hour   = 9
        comps.minute = 0

        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(
            identifier: "revisit-\(session.id.uuidString)",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
        if appState.profile.hapticFeedbackEnabled { HapticManager.softConfirm() }
    }

    // MARK: - Confidence Highlighting

    /// Words from session.segments whose confidence is below the "uncertain" threshold.
    private var lowConfidenceWords: [TranscriptSegment] {
        session.segments
            .filter { $0.confidence > 0 && $0.confidence < 0.72 && $0.text.count > 1 }
            .sorted { $0.confidence < $1.confidence }
    }

    @ViewBuilder
    private var confidenceHighlightSection: some View {
        let uncertain = lowConfidenceWords
        if !uncertain.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    Text("Low-confidence words")
                        .font(.headline)
                    Text("(\(uncertain.count))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Tap to find & fix")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .italic()
                }

                Text("These words had lower transcription confidence. Tap any to search and correct.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                FlowLayout(spacing: 8) {
                    ForEach(uncertain.prefix(20)) { seg in
                        Button {
                            // Jump to find & replace with this word
                            findText = seg.text
                            showFindReplace = true
                            findFieldFocused = true
                            recomputeMatches()
                        } label: {
                            HStack(spacing: 4) {
                                // Confidence dot
                                Circle()
                                    .fill(confidenceColor(seg.confidence))
                                    .frame(width: 6, height: 6)
                                Text(seg.text)
                                    .font(.subheadline)
                                Text("\(Int(seg.confidence * 100))%")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                confidenceColor(seg.confidence).opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(confidenceColor(seg.confidence).opacity(0.35), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(seg.text), \(Int(seg.confidence * 100)) percent confidence. Tap to find and replace.")
                    }
                }
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func confidenceColor(_ confidence: Double) -> Color {
        if confidence < 0.5  { return .red }
        if confidence < 0.65 { return .orange }
        return .yellow
    }

    // MARK: - Vocabulary Suggestions

    /// Candidate terms from the transcript that are worth adding to the user's vocabulary.
    /// Strategy: words ≥4 chars, not common stop-words, not already in vocab, sorted by
    /// descending frequency. Capped at 12 candidates.
    private var vocabSuggestions: [String] {
        let text = editedText.lowercased()
        let stopWords: Set<String> = [
            "this","that","with","from","have","been","they","will","were","what",
            "when","your","more","into","than","also","about","would","could",
            "their","there","these","those","which","other","being","after","before",
            "should","where","while","every","some","only","over","then","just",
            "because","through","during","between","against","without","within"
        ]
        let knownTerms = Set(appState.profile.customVocabulary.map { $0.term.lowercased() })
        let words = text.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count >= 4 && !stopWords.contains($0) && !knownTerms.contains($0) }

        // Count frequency
        var freq: [String: Int] = [:]
        for w in words { freq[w, default: 0] += 1 }

        // Prefer medium-frequency words (appear 2–6×) — too-frequent words are likely
        // common but not in the stop list; hapax legomena may be transcription noise
        return freq
            .filter { $0.value >= 2 && $0.value <= 10 }
            .sorted { $0.value > $1.value }
            .map(\.key)
            .filter { !dismissedVocabSuggestions.contains($0) }
            .prefix(12)
            .map { $0 }
    }

    @ViewBuilder
    private var vocabSuggestSection: some View {
        let suggestions = vocabSuggestions
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                // Header row with expand/collapse
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        vocabSuggestExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "text.badge.plus")
                            .font(.subheadline)
                            .foregroundStyle(Color.accentColor)
                        Text("Vocabulary Suggestions")
                            .font(.headline)
                        Text("(\(suggestions.count))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: vocabSuggestExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if vocabSuggestExpanded {
                    Text("Words from this session worth teaching Lexora. Tap ＋ to add, ✕ to skip.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Chip cloud
                    FlowLayout(spacing: 8) {
                        ForEach(suggestions, id: \.self) { word in
                            HStack(spacing: 4) {
                                Text(word)
                                    .font(.subheadline)
                                    .padding(.leading, 8)

                                // Add button
                                Button {
                                    let entry = VocabularyEntry(
                                        term: word,
                                        phonetic: nil,
                                        aliases: [],
                                        category: .other,
                                        language: session.primaryLanguage,
                                        source: .learnedFromCorrection
                                    )
                                    appState.addVocabularyEntry(entry)
                                    dismissedVocabSuggestions.insert(word)
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .help("Add \"\(word)\" to your vocabulary")

                                // Dismiss button
                                Button {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        _ = dismissedVocabSuggestions.insert(word)
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .padding(.trailing, 6)
                                .help("Skip \"\(word)\"")
                            }
                            .padding(.vertical, 5)
                            .background { Capsule().fill(Color(uiColor: .systemGray6)) }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(word) — suggested vocabulary term")
                        }
                    }
                }
            }
            .padding(14)
            .background { RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)) }
        }
    }

    // MARK: - Spelling Panel

    @ViewBuilder
    private var spellingPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "text.badge.xmark")
                    .foregroundStyle(.red)
                Text("Possible misspellings")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(spellingMisspellings.count) word\(spellingMisspellings.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    withAnimation(.snappy) { showSpellPanel = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            ForEach(spellingMisspellings, id: \.self) { (word: String) in
                spellingWordRow(word: word)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.red.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Spell Check Helpers

    private func spellingGuesses(for word: String) -> [String] {
        let checker = UITextChecker()
        let language = session.primaryLanguage.components(separatedBy: "-").first ?? "en"
        return checker.guesses(
            forWordRange: NSRange(location: 0, length: (word as NSString).length),
            in: word,
            language: language
        ) ?? []
    }

    @ViewBuilder
    private func spellingWordRow(word: String) -> some View {
        let guesses = spellingGuesses(for: word)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(word)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.red)
                    .strikethrough(false)
                Spacer()
                // Add to vocabulary
                Button {
                    let entry = VocabularyEntry(
                        term: word,
                        phonetic: nil,
                        aliases: [],
                        category: .other,
                        language: session.primaryLanguage,
                        source: .userAdded
                    )
                    appState.addVocabularyEntry(entry)
                    spellingMisspellings.removeAll { $0 == word }
                    if spellingMisspellings.isEmpty { withAnimation { showSpellPanel = false } }
                } label: {
                    Label("Add to vocab", systemImage: "plus.circle")
                        .font(.caption)
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Add \"\(word)\" to your vocabulary so it won't be flagged again")
            }
            // Suggestion chips (top 4)
            if !guesses.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(guesses.prefix(4), id: \.self) { (suggestion: String) in
                            Button {
                                if let range = editedText.range(of: word) {
                                    editedText.replaceSubrange(range, with: suggestion)
                                    didEdit = true
                                    spellingMisspellings.removeAll { $0 == word }
                                    if spellingMisspellings.isEmpty { withAnimation { showSpellPanel = false } }
                                }
                            } label: {
                                Text(suggestion)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                Text("No suggestions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
        .padding(10)
        .background(Color(uiColor: .systemGray6), in: RoundedRectangle(cornerRadius: 10))
        if word != spellingMisspellings.last {
            Divider()
        }
    }

    /// Runs UITextChecker on the edited transcript and collects unique misspelled words.
    private func runSpellCheck() {
        let checker = UITextChecker()
        let text = editedText as NSString
        let language = session.primaryLanguage.components(separatedBy: "-").first ?? "en"
        var misspelled: [String] = []
        var offset = 0
        let length = text.length
        while offset < length {
            let range = checker.rangeOfMisspelledWord(
                in: editedText,
                range: NSRange(location: offset, length: length - offset),
                startingAt: offset,
                wrap: false,
                language: language
            )
            guard range.location != NSNotFound else { break }
            let word = text.substring(with: range)
            if !misspelled.contains(word) { misspelled.append(word) }
            offset = range.location + max(1, range.length)
        }
        // Filter out words already in the user's custom vocabulary
        let knownTerms = Set(session.rawTranscript.isEmpty ? [] :
            appState.profile.customVocabulary.map { $0.term.lowercased() })
        spellingMisspellings = misspelled.filter { !knownTerms.contains($0.lowercased()) }
        withAnimation {
            if spellingMisspellings.isEmpty {
                spellCheckAllClear = true
                showSpellPanel = false
                // Auto-hide the all-clear badge after 2 s
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { spellCheckAllClear = false }
                }
            } else {
                spellCheckAllClear = false
                showSpellPanel = true
            }
        }
    }

    // MARK: - Find & Replace Bar

    private var findReplaceBar: some View {
        VStack(spacing: 8) {
            // Find row
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)

                TextField("Find…", text: $findText)
                    .font(.subheadline)
                    .focused($findFieldFocused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: findText) { _, _ in recomputeMatches() }

                if !matchRanges.isEmpty {
                    Text("\(currentMatchIndex + 1)/\(matchRanges.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }

                if !findText.isEmpty {
                    // Previous / Next navigation
                    Button {
                        guard !matchRanges.isEmpty else { return }
                        currentMatchIndex = (currentMatchIndex - 1 + matchRanges.count) % matchRanges.count
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(matchRanges.isEmpty)

                    Button {
                        guard !matchRanges.isEmpty else { return }
                        currentMatchIndex = (currentMatchIndex + 1) % matchRanges.count
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(matchRanges.isEmpty)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 10))

            // Replace row
            HStack(spacing: 8) {
                Image(systemName: "arrow.2.squarepath")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)

                TextField("Replace with…", text: $replaceText)
                    .font(.subheadline)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Spacer()

                Button("Next") {
                    replaceNext()
                }
                .font(.caption.weight(.semibold))
                .disabled(matchRanges.isEmpty || findText.isEmpty)
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)

                Button("All") {
                    replaceAll()
                }
                .font(.caption.weight(.semibold))
                .disabled(matchRanges.isEmpty || findText.isEmpty)
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 10))

            if !findText.isEmpty && matchRanges.isEmpty {
                Text("No matches found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Find & Replace Logic

    private func recomputeMatches() {
        guard !findText.isEmpty else { matchRanges = []; return }
        var ranges: [Range<String.Index>] = []
        var searchStart = editedText.startIndex
        while searchStart < editedText.endIndex,
              let range = editedText.range(
                of: findText,
                options: .caseInsensitive,
                range: searchStart..<editedText.endIndex
              ) {
            ranges.append(range)
            searchStart = range.upperBound
            // Avoid infinite loop on empty match
            if range.isEmpty { searchStart = editedText.index(after: searchStart) }
        }
        matchRanges = ranges
        if currentMatchIndex >= ranges.count { currentMatchIndex = 0 }
    }

    /// Replace the occurrence at `currentMatchIndex` and advance to the next.
    private func replaceNext() {
        guard !matchRanges.isEmpty,
              currentMatchIndex < matchRanges.count else { return }
        let range = matchRanges[currentMatchIndex]
        editedText.replaceSubrange(range, with: replaceText)
        didEdit = true
        recomputeMatches()
        if !matchRanges.isEmpty {
            currentMatchIndex = min(currentMatchIndex, matchRanges.count - 1)
        }
    }

    /// Replace all occurrences at once.
    private func replaceAll() {
        guard !findText.isEmpty else { return }
        let new = editedText.replacingOccurrences(
            of: findText,
            with: replaceText,
            options: .caseInsensitive
        )
        guard new != editedText else { return }
        editedText = new
        didEdit = true
        matchRanges = []
        currentMatchIndex = 0
    }

    // MARK: - Tag editor

    private var tagEditorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Tags", systemImage: "tag")
                .font(.headline)

            // Existing tags as chips — template tags are color-coded
            if !tags.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(tags, id: \.self) { tag in
                        let tagColor = templateTagColor(tag)
                        HStack(spacing: 4) {
                            Text(tag)
                                .font(.caption.weight(.medium))
                            Button {
                                tags.removeAll { $0 == tag }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(tagColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(tagColor)
                    }
                }
            }

            // Smart suggestion chips
            let displaySuggestions = suggestedTags
                .filter { !tags.contains($0) && !tags.contains($0.lowercased()) }
                .prefix(5)
            if !displaySuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Suggested")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(displaySuggestions), id: \.self) { suggestion in
                                Button {
                                    withAnimation(.snappy) {
                                        tags.append(suggestion)
                                        suggestedTags.removeAll { $0 == suggestion }
                                    }
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: "plus")
                                            .font(.caption2)
                                        Text(suggestion)
                                            .font(.caption.weight(.medium))
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.accentColor.opacity(0.07), in: Capsule())
                                    .foregroundStyle(Color.accentColor)
                                    .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            // Add tag text field
            HStack(spacing: 8) {
                TextField("Add tag…", text: $newTag)
                    .font(.subheadline)
                    .focused($tagFieldFocused)
                    .submitLabel(.done)
                    .onSubmit { commitTag() }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))

                if !newTag.isEmpty {
                    Button(action: commitTag) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.snappy, value: newTag.isEmpty)
        }
        .padding(14)
        .background(Color(.systemGray6).opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Notes section

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Notes", systemImage: "note.text")
                    .font(.headline)
                Spacer()
                // Template suggestion based on session tags
                if notes.isEmpty, let template = notesTemplate(for: session.tags) {
                    Button {
                        notes = template
                    } label: {
                        Label("Use template", systemImage: "wand.and.stars")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }

            TextEditor(text: $notes)
                .font(.subheadline)
                .frame(minHeight: 80, maxHeight: 200)
                .scrollContentBackground(.hidden)
                .padding(10)
                .disabled(isLocked)
                .opacity(isLocked ? 0.65 : 1)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    if notes.isEmpty {
                        Text("Add a note about this session…")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .padding(14)
                            .allowsHitTesting(false)
                    }
                }

            // Live notes stats footer
            if !notes.isEmpty {
                let noteWords = notes.split(whereSeparator: { $0.isWhitespace }).count
                let noteChars = notes.count
                HStack(spacing: 6) {
                    Text("\(noteWords)w · \(noteChars)c")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Spacer()
                    // Rough reading time (250 wpm average silent reading speed)
                    if noteWords >= 30 {
                        let readSecs = max(1, noteWords * 60 / 250)
                        Text("~\(readSecs < 60 ? "\(readSecs)s" : "\(readSecs / 60)m") read")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 4)
                .animation(.snappy, value: noteWords)
            }
        }
        .padding(14)
        .background(Color(.systemGray6).opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Returns a structured notes template based on the session's tags, or nil when no match.
    private func notesTemplate(for tags: [String]) -> String? {
        let lower = tags.map { $0.lowercased() }
        if lower.contains("meeting") || lower.contains("standup") {
            return "## Attendees:\n\n## Key points:\n- \n\n## Decisions:\n- \n\n## Action items:\n- [ ] "
        }
        if lower.contains("lecture") || lower.contains("class") || lower.contains("seminar") {
            return "## Summary:\n\n## Key concepts:\n- \n\n## Questions:\n- \n\n## Follow-up reading:\n- "
        }
        if lower.contains("interview") {
            return "## Candidate / Subject:\n\n## Impressions:\n\n## Strengths:\n- \n\n## Concerns:\n- \n\n## Next steps:\n- "
        }
        if lower.contains("dictation") || lower.contains("draft") {
            return "## Context:\n\n## To review:\n- \n\n## Revisions needed:\n- "
        }
        if lower.contains("quick note") || lower.contains("note") {
            return "## Summary:\n\n## Reference:\n"
        }
        return nil
    }

    /// Renders a `SessionShareCardView` to a PNG and presents it via the share sheet.
    @MainActor
    private func shareSessionCard() {
        isRenderingCard = true
        let card = SessionShareCardView(session: session)
        let renderer = ImageRenderer(content: card)
        renderer.scale = UIScreen.main.scale
        guard let image = renderer.uiImage else { isRenderingCard = false; return }
        shareItems = [image]
        showingShareSheet = true
        isRenderingCard = false
    }

    /// Renders a word-frequency cloud card and presents it via the share sheet.
    @MainActor
    private func shareWordCloudCard() {
        let card = WordCloudCardView(session: session, text: editedText)
        let renderer = ImageRenderer(content: card)
        renderer.scale = UIScreen.main.scale
        guard let image = renderer.uiImage else { return }
        shareItems = [image]
        showingShareSheet = true
    }

    /// Writes the transcript to a temporary .txt file for use with the Files picker.
    /// The filename uses the session title or a sanitised date string.
    /// Builds a Markdown document from the session and writes it to a temp file.
    private func exportSessionAsMarkdown(session: TranscriptionSession, text: String) -> URL? {
        let title = session.customTitle
            ?? session.startedAt.formatted(.dateTime.year().month().day().hour().minute())
        let lang = Locale.current.localizedString(forLanguageCode: session.primaryLanguage)
            ?? session.primaryLanguage
        let totalSec = Int(session.durationSeconds)
        let durStr   = totalSec >= 60
            ? "\(totalSec / 60)m \(totalSec % 60)s"
            : "\(totalSec)s"
        let isoDate = ISO8601DateFormatter().string(from: session.startedAt)

        // ── YAML frontmatter (Obsidian / Notion / Jekyll compatible) ──────────
        var md = "---\n"
        md += "title: \"\(title)\"\n"
        md += "date: \(isoDate)\n"
        md += "language: \(lang)\n"
        md += "duration: \"\(durStr)\"\n"
        md += "words: \(session.wordCount)\n"
        if session.paceWPM > 0 { md += "pace_wpm: \(Int(session.paceWPM))\n" }
        if session.estimatedAccuracy > 0 { md += "accuracy: \(Int(session.estimatedAccuracy))\n" }
        if !session.tags.isEmpty {
            md += "tags:\n" + session.tags.map { "  - \($0)" }.joined(separator: "\n") + "\n"
        }
        md += "source: Lexora\n"
        md += "---\n\n"

        // ── Title + metadata table ────────────────────────────────────────────
        md += "# \(title)\n\n"
        md += "| Field | Value |\n|---|---|\n"
        md += "| Date | \(session.startedAt.formatted(date: .abbreviated, time: .shortened)) |\n"
        md += "| Language | \(lang) |\n"
        md += "| Duration | \(durStr) |\n"
        md += "| Words | \(session.wordCount) |\n"
        if session.paceWPM > 0 { md += "| Pace | \(Int(session.paceWPM)) WPM |\n" }
        if session.estimatedAccuracy > 0 { md += "| Accuracy | \(Int(session.estimatedAccuracy))% |\n" }
        if !session.tags.isEmpty { md += "| Tags | \(session.tags.map { "#\($0)" }.joined(separator: " ")) |\n" }
        if session.isStarred { md += "| Starred | ⭐ |\n" }
        md += "\n"

        // ── Auto summary (extractive, generated from the transcript) ─────────
        if text.split(separator: " ").count >= 30,
           let auto = SessionDetailView.extractiveSummary(from: text, sentenceCount: 2),
           !auto.isEmpty {
            md += "## Summary\n\n> \(auto)\n\n"
        }

        // ── Transcript ────────────────────────────────────────────────────────
        md += "## Transcript\n\n\(text)\n"

        // ── Notes ─────────────────────────────────────────────────────────────
        if let notes = session.notes, !notes.isEmpty {
            md += "\n## Notes\n\n\(notes)\n"
        }

        // ── Top words (mini word-frequency footer) ────────────────────────────
        let wordFreq = buildWordFrequency(from: text)
        if !wordFreq.isEmpty {
            let topStr = wordFreq.prefix(10)
                .map { "\($0.word) ×\($0.count)" }
                .joined(separator: " · ")
            md += "\n---\n*Top words: \(topStr)*\n"
        }

        md += "\n*Exported from Lexora on \(Date().formatted(date: .abbreviated, time: .shortened))*\n"

        let safeName = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
            .trimmingCharacters(in: .whitespaces)
        let filename = (safeName.isEmpty ? "Transcript" : safeName) + ".md"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try md.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch { return nil }
    }

    /// Builds a sorted word-frequency list from plain text, excluding common stop-words.
    private func buildWordFrequency(from text: String) -> [(word: String, count: Int)] {
        let stopWords: Set<String> = ["the","a","an","and","or","but","in","on","at","to","for",
                                      "of","with","is","it","i","you","we","they","he","she","was",
                                      "be","are","as","this","that","by","from","have","not","do",
                                      "my","me","your","our","their","his","her","its","so","if",
                                      "but","just","up","out","all","about","what","when","there"]
        var freq: [String: Int] = [:]
        text.components(separatedBy: .whitespacesAndNewlines).forEach { raw in
            let word = raw.lowercased()
                .trimmingCharacters(in: .punctuationCharacters)
            if word.count > 3, !stopWords.contains(word) {
                freq[word, default: 0] += 1
            }
        }
        return freq.filter { $0.value > 1 }
            .sorted { $0.value > $1.value }
            .map { (word: $0.key, count: $0.value) }
    }

    private func saveTranscriptToTemp(session: TranscriptionSession, text: String) -> URL? {
        let rawName = session.customTitle
            ?? session.startedAt.formatted(.dateTime.year().month().day().hour().minute())
        // Sanitise filename: replace slashes/colons
        let safeName = rawName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
            .trimmingCharacters(in: .whitespaces)
        let filename = (safeName.isEmpty ? "Transcript" : safeName) + ".txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private func commitTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !tags.contains(trimmed) else {
            newTag = ""
            return
        }
        withAnimation(.snappy) { tags.append(trimmed) }
        newTag = ""
    }

    // MARK: - Keyword / Tag Suggestion

    /// Extracts proper nouns and high-frequency content words from the transcript
    /// and returns them as candidate tag strings (title-cased, deduplicated).
    private func extractKeywords(from text: String) -> [String] {
        guard !text.isEmpty else { return [] }

        var keywords: [String: Int] = [:]
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        tagger.string = text

        // Collect proper nouns with high weight
        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word,
                             scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            if let tag, [.personalName, .placeName, .organizationName].contains(tag) {
                let word = String(text[range]).lowercased()
                if word.count > 2 { keywords[word, default: 0] += 3 }
            }
            return true
        }

        // Collect nouns and verbs with lower weight
        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word,
                             scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            if let tag, [.noun, .verb].contains(tag) {
                let word = String(text[range]).lowercased()
                if word.count > 3 {
                    keywords[word, default: 0] += 1
                }
            }
            return true
        }

        return keywords
            .sorted { $0.value > $1.value }
            .prefix(10)
            .map { $0.key.prefix(1).uppercased() + $0.key.dropFirst() }
            .filter { !tags.contains($0.lowercased()) && !tags.contains($0) }
    }

    // MARK: - Filler words banner

    private var fillerWordsBanner: some View {
        let topFillers = session.fillerWords
            .reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            .sorted { $0.value > $1.value }
            .prefix(5)

        return VStack(alignment: .leading, spacing: 8) {
            Label("Filler words detected", systemImage: "exclamationmark.bubble")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(topFillers, id: \.key) { word, count in
                        HStack(spacing: 4) {
                            Text("\"\(word)\"")
                                .font(.caption.weight(.semibold))
                            Text("×\(count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                        .foregroundStyle(.orange)
                    }
                }
            }
            Text("Tap a word in the transcript to correct or remove it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Summary card

    private func summaryCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Auto-summary", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(red: 0.29, green: 0.11, blue: 0.78),
                                     Color(red: 0.56, green: 0.18, blue: 0.82)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                Spacer()
                // Sentiment badge
                if let score = sentimentScore {
                    let (icon, label, color) = sentimentDetails(score)
                    HStack(spacing: 3) {
                        Image(systemName: icon).font(.system(size: 9))
                        Text(label).font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(color.opacity(0.12), in: Capsule())
                }
            }

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            // Named entities row — only shown when entities are found
            if !namedEntities.isEmpty {
                Divider()
                    .background(Color(red: 0.29, green: 0.11, blue: 0.78).opacity(0.2))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Mentioned")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    FlowLayout(spacing: 6) {
                        ForEach(namedEntities.prefix(10), id: \.text) { entity in
                            HStack(spacing: 3) {
                                Image(systemName: entityIcon(entity.type))
                                    .font(.system(size: 9))
                                    .foregroundStyle(entityColor(entity.type))
                                Text(entity.text)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(entityColor(entity.type).opacity(0.1), in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(red: 0.29, green: 0.11, blue: 0.78).opacity(0.08),
                         Color(red: 0.56, green: 0.18, blue: 0.82).opacity(0.08)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Auto-summary: \(text)\(namedEntities.isEmpty ? "" : ". Mentioned: \(namedEntities.prefix(5).map(\.text).joined(separator: ", "))")")
    }

    // MARK: - AI Panel

    @ViewBuilder
    private var aiPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row — always visible
            Button {
                withAnimation(.spring(response: 0.35)) {
                    aiPanelExpanded.toggle()
                }
                // Auto-fetch on first expand
                if aiPanelExpanded && aiSummary == nil && !isLoadingAI {
                    fetchAIContent()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(red: 0.55, green: 0.35, blue: 0.95),
                                         Color(red: 0.22, green: 0.49, blue: 0.98)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                    Text("AI Insights")
                        .font(.headline)
                    Spacer()
                    if isLoadingAI {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: aiPanelExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(14)

            if aiPanelExpanded {
                Divider().padding(.horizontal, 14)

                if let error = aiError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                } else if isLoadingAI {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("Asking AI…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 20)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        // Abstractive summary
                        if let sum = aiSummary {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Summary", systemImage: "text.quote")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(sum)
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        // Action items
                        if !aiActionItems.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Action Items", systemImage: "checklist")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(aiActionItems.indices, id: \.self) { i in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "circle")
                                            .font(.caption2)
                                            .foregroundStyle(Color.accentColor)
                                            .padding(.top, 3)
                                        Text(aiActionItems[i])
                                            .font(.subheadline)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }

                        // Follow-up suggestions
                        if !aiFollowUps.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Explore Further", systemImage: "arrow.triangle.branch")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(aiFollowUps.indices, id: \.self) { i in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "questionmark.circle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.purple.opacity(0.7))
                                            .padding(.top, 3)
                                        Text(aiFollowUps[i])
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }

                        // Refresh button
                        if aiSummary != nil {
                            Button {
                                fetchAIContent()
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .background(
            LinearGradient(
                colors: [Color(red: 0.55, green: 0.35, blue: 0.95).opacity(0.07),
                         Color(red: 0.22, green: 0.49, blue: 0.98).opacity(0.07)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color(red: 0.55, green: 0.35, blue: 0.95).opacity(0.25),
                                 Color(red: 0.22, green: 0.49, blue: 0.98).opacity(0.25)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }

    private func fetchAIContent() {
        guard !isLoadingAI else { return }
        let text = editedText
        let lang = session.primaryLanguage
        isLoadingAI = true
        aiError = nil
        aiSummary = nil
        aiActionItems = []
        aiFollowUps = []

        Task {
            do {
                async let summary    = appState.ai.summarise(transcript: text, language: lang)
                async let actions    = appState.ai.extractActionItems(transcript: text)
                async let followUps  = appState.ai.suggestFollowUps(transcript: text)
                let (s, a, f) = try await (summary, actions, followUps)
                aiSummary      = s
                aiActionItems  = a
                aiFollowUps    = f
            } catch {
                aiError = error.localizedDescription
            }
            isLoadingAI = false
        }
    }

    /// Returns (SF Symbol name, label, colour) for a sentiment score.
    private func sentimentDetails(_ score: Double) -> (String, String, Color) {
        switch score {
        case 0.2...:  return ("face.smiling",         "Positive",  .green)
        case -0.2..<0.2: return ("face.smiling.inverse", "Neutral",   .secondary)
        default:      return ("exclamationmark.bubble","Negative", .orange)
        }
    }

    private func entityIcon(_ type: String) -> String {
        switch type {
        case "PersonalName":        return "person.fill"
        case "PlaceName":           return "mappin.fill"
        case "OrganizationName":    return "building.2.fill"
        default:                    return "tag.fill"
        }
    }

    private func entityColor(_ type: String) -> Color {
        switch type {
        case "PersonalName":        return .blue
        case "PlaceName":           return .green
        case "OrganizationName":    return .orange
        default:                    return .purple
        }
    }

    // MARK: - Async wrappers (off main thread for NLTagger work)

    // extractKeywords accesses self.tags (@State) so it must stay on MainActor.
    // NLTagger work on transcript-sized text is fast enough not to stall the UI.
    private func extractKeywordsAsync(from text: String) async -> [String] {
        extractKeywords(from: text)
    }

    /// Returns overall NLTagger sentiment score: -1 (very negative) … +1 (very positive).
    /// Returns nil if the text is too short or no score is available for the language.
    private func computeSentimentAsync(from text: String) async -> Double? {
        guard text.split(separator: " ").count >= 10 else { return nil }
        return await Task.detached(priority: .utility) {
            let tagger = NLTagger(tagSchemes: [.sentimentScore])
            tagger.string = text
            var scores: [Double] = []
            tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                                  unit: .sentence,
                                  scheme: .sentimentScore,
                                  options: [.omitWhitespace]) { tag, _ in
                if let raw = tag?.rawValue, let score = Double(raw) {
                    scores.append(score)
                }
                return true
            }
            guard !scores.isEmpty else { return nil }
            return scores.reduce(0, +) / Double(scores.count)
        }.value
    }

    private func buildSummaryAsync(from text: String) async -> String? {
        guard text.count > 60 else { return nil }
        // extractiveSummary is nonisolated static — safe to call from a detached task.
        return await Task.detached(priority: .userInitiated) {
            SessionDetailView.extractiveSummary(from: text, sentenceCount: 2)
        }.value
    }

    private func extractNamedEntitiesAsync(from text: String) async -> [(text: String, type: String)] {
        guard text.count > 30 else { return [] }
        return await Task.detached(priority: .utility) {
            SessionDetailView.extractNamedEntities(from: text)
        }.value
    }

    /// Extracts unique named entities (people, places, organizations) using NLTagger.
    /// Returns up to 15 entities, sorted by type priority then alphabetically.
    nonisolated private static func extractNamedEntities(from text: String) -> [(text: String, type: String)] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var seen = Set<String>()
        var results: [(text: String, type: String)] = []

        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            guard let tag,
                  [.personalName, .placeName, .organizationName].contains(tag) else { return true }
            let entity = String(text[range]).trimmingCharacters(in: .whitespaces)
            guard entity.count > 1, !seen.contains(entity.lowercased()) else { return true }
            seen.insert(entity.lowercased())
            results.append((text: entity, type: tag.rawValue))
            return true
        }

        // Sort: PersonalName first, then PlaceName, OrganizationName; alpha within groups
        let order: [String: Int] = ["PersonalName": 0, "PlaceName": 1, "OrganizationName": 2]
        return results
            .sorted { (a, b) -> Bool in
                let oa = order[a.type] ?? 3
                let ob = order[b.type] ?? 3
                if oa != ob { return oa < ob }
                return a.text < b.text
            }
            .prefix(15)
            .map { $0 }
    }

    /// Scores sentences by content-word density and returns the top `sentenceCount`.
    /// Uses NLTagger to identify nouns, verbs, and proper names — those carry meaning.
    nonisolated private static func extractiveSummary(from text: String, sentenceCount: Int) -> String? {
        // Tokenise into sentences
        var sentences: [String] = []
        let tokeniser = NLTokenizer(unit: .sentence)
        tokeniser.string = text
        tokeniser.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = String(text[range]).trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { sentences.append(s) }
            return true
        }
        guard sentences.count > sentenceCount else {
            return sentences.isEmpty ? nil : sentences.joined(separator: " ")
        }

        // Score each sentence by content-word density
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        var scores = [(index: Int, score: Int, text: String)]()

        for (i, sentence) in sentences.enumerated() {
            var score = 0
            tagger.string = sentence

            tagger.enumerateTags(in: sentence.startIndex..<sentence.endIndex,
                                 unit: .word,
                                 scheme: .nameType,
                                 options: [.omitWhitespace, .omitPunctuation]) { tag, _ in
                if let tag, [.personalName, .placeName, .organizationName].contains(tag) { score += 3 }
                return true
            }
            tagger.enumerateTags(in: sentence.startIndex..<sentence.endIndex,
                                 unit: .word,
                                 scheme: .lexicalClass,
                                 options: [.omitWhitespace, .omitPunctuation]) { tag, _ in
                if let tag, [.noun, .verb].contains(tag) { score += 1 }
                return true
            }
            // Boost first & last sentences slightly (they tend to be topic-setting)
            if i == 0 || i == sentences.count - 1 { score += 2 }
            scores.append((index: i, score: score, text: sentence))
        }

        // Pick top N by score, then re-order by original position for coherence
        let top = scores.sorted { $0.score > $1.score }.prefix(sentenceCount)
                        .sorted { $0.index < $1.index }
        return top.map { $0.text }.joined(separator: " ")
    }

    // MARK: - Session Top Words

    /// Top 8 content words for this session — shown as a flow of tappable chips.
    @ViewBuilder
    private var sessionTopWordsCard: some View {
        let text = editedText
        if !text.isEmpty {
            let words = topWordsFor(text: text, limit: 8)
            if !words.isEmpty {
                let maxCount = Double(words.first?.count ?? 1)
                VStack(alignment: .leading, spacing: 10) {
                    Label("Key words", systemImage: "text.bubble.fill")
                        .font(.headline)
                    FlowLayout(spacing: 6) {
                        ForEach(words, id: \.word) { item in
                            let scale = 0.4 + 0.6 * (Double(item.count) / maxCount)
                            Button {
                                NotificationCenter.default.post(
                                    name: .lexoraSearchHistory,
                                    object: nil,
                                    userInfo: ["query": item.word]
                                )
                            } label: {
                                Text(item.word)
                                    .font(.system(size: 12 + 5 * scale,
                                                  weight: scale > 0.6 ? .semibold : .regular))
                                    .foregroundStyle(Color.accentColor.opacity(0.5 + 0.5 * scale))
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color.accentColor.opacity(0.07 + 0.08 * scale),
                                                in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var extractedBookmarks: [String] {
        let text = editedText
        guard text.contains("[★") else { return [] }
        return text.components(separatedBy: "\n")
            .filter { $0.contains("[★") }
            .compactMap { line -> String? in
                guard let start = line.range(of: "[★") else { return nil }
                let raw = String(line[start.lowerBound...])
                    .trimmingCharacters(in: .whitespaces)
                // Strip outer brackets: "[★ 10:34 AM]" → "★ 10:34 AM"
                if raw.hasPrefix("[") && raw.hasSuffix("]") {
                    return String(raw.dropFirst().dropLast())
                }
                return raw
            }
    }

    @ViewBuilder
    private var bookmarksPanel: some View {
        let bookmarks = extractedBookmarks
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Bookmarks", systemImage: "bookmark.fill")
                    .font(.headline)
                    .foregroundStyle(.yellow)
                Spacer()
                Text("\(bookmarks.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(bookmarks.enumerated()), id: \.offset) { _, bookmark in
                    HStack(spacing: 8) {
                        Image(systemName: "bookmark.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                        Text(bookmark)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(16)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Chapters Panel

    @ViewBuilder
    private var chaptersPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Chapters", systemImage: "list.number")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
                Spacer()
                if !isLocked {
                    Button {
                        newChapterTitle = ""
                        newChapterOffset = 0
                        showChapterEditor = true
                    } label: {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }

            if chapters.isEmpty {
                Text("No chapters yet. Tap + to mark a section in your transcript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let sorted = chapters.sorted { $0.offset < $1.offset }
                ForEach(sorted) { chapter in
                    HStack(spacing: 10) {
                        Image(systemName: chapter.icon)
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(chapter.title)
                                .font(.subheadline.weight(.medium))
                            // Show the first ~60 chars starting at this offset
                            let snippet = transcriptSnippet(at: chapter.offset)
                            if !snippet.isEmpty {
                                Text(snippet)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        if !isLocked {
                            Button(role: .destructive) {
                                chapters.removeAll { $0.id == chapter.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Color(.systemGray4))
                                    .font(.subheadline)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(16)
        .background(Color(.systemGray6).opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(.systemGray4).opacity(0.4), lineWidth: 1))
        .sheet(isPresented: $showChapterEditor) {
            chapterEditorSheet
                .environment(appState)
        }
    }

    private func transcriptSnippet(at offset: Int) -> String {
        guard offset < editedText.count else { return "" }
        let startIdx = editedText.index(editedText.startIndex, offsetBy: offset)
        let endIdx   = editedText.index(startIdx, offsetBy: min(60, editedText.count - offset))
        return String(editedText[startIdx..<endIdx]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    @ViewBuilder
    private var chapterEditorSheet: some View {
        NavigationStack {
            Form {
                Section("Chapter title") {
                    TextField("e.g. Introduction, Key points…", text: $newChapterTitle)
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Start position")
                            Spacer()
                            Text("char \(newChapterOffset)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(
                            value: Binding(
                                get: { Double(newChapterOffset) },
                                set: { newChapterOffset = Int($0) }
                            ),
                            in: 0...max(1, Double(editedText.count - 1)),
                            step: 1
                        )
                        if !editedText.isEmpty {
                            Text(transcriptSnippet(at: newChapterOffset))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                } header: {
                    Text("Where does this chapter start?")
                } footer: {
                    Text("Drag the slider to the word where this chapter begins in the transcript.")
                }
            }
            .navigationTitle("Add Chapter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showChapterEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let trimmed = newChapterTitle.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        let chapter = TranscriptChapter(title: trimmed, offset: newChapterOffset)
                        chapters.append(chapter)
                        showChapterEditor = false
                    }
                    .disabled(newChapterTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func topWordsFor(text: String, limit: Int) -> [(word: String, count: Int)] {
        guard !text.isEmpty else { return [] }
        var freq: [String: Int] = [:]
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            if let tag, [.noun, .verb, .adjective].contains(tag) {
                let w = String(text[range]).lowercased()
                if w.count > 3 { freq[w, default: 0] += 1 }
            }
            return true
        }
        return freq.sorted { $0.value > $1.value }.prefix(limit).map { (word: $0.key, count: $0.value) }
    }

    // MARK: - Pacing Sparkline

    private struct PaceBucket: Identifiable {
        let id: Int     // bucket index
        let words: Int
    }

    /// Computes per-30-second word buckets from sorted segment list. Pure computation — no actor state.
    private func pacingBuckets(segs: [TranscriptSegment], duration: Double) -> [PaceBucket] {
        let bucketSize: Double = 30.0
        let numBuckets = max(2, Int(ceil(duration / bucketSize)))
        var bucketWords = Array(repeating: 0, count: numBuckets)
        for seg in segs {
            let idx = min(numBuckets - 1, Int(seg.startTime / bucketSize))
            bucketWords[idx] += seg.text.split(whereSeparator: { $0.isWhitespace }).count
        }
        return bucketWords.enumerated().map { PaceBucket(id: $0.offset, words: $0.element) }
    }

    /// Bar chart showing words per 30-second bucket, built from segment timing data.
    @ViewBuilder
    private var pacingChart: some View {
        let segs = session.segments.sorted { $0.startTime < $1.startTime }
        if segs.count >= 5, session.durationSeconds > 10 {
            let data = pacingBuckets(segs: segs, duration: session.durationSeconds)
            let numBuckets = data.count
            let maxW = max(1, data.map(\.words).max() ?? 1)
            if maxW > 0 {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Speaking pace", systemImage: "chart.bar.fill")
                        .font(.headline)
                    Chart(data) { b in
                        BarMark(
                            x: .value("Time", b.id),
                            y: .value("Words", b.words)
                        )
                        .foregroundStyle(
                            LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.5)],
                                           startPoint: .top, endPoint: .bottom)
                        )
                        .cornerRadius(3)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: Double(max(1, data.count / 5)))) { v in
                            if let idx = v.as(Int.self) {
                                let sec = idx * 30   // bucketSize is always 30 seconds
                                let m = sec / 60; let s = sec % 60
                                AxisValueLabel {
                                    Text(m > 0 ? "\(m)m\(String(format: "%02d", s))s" : "\(s)s")
                                        .font(.system(size: 9))
                                }
                            }
                            AxisGridLine()
                        }
                    }
                    .chartYAxis(.hidden)
                    .frame(height: 90)
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    // MARK: - Session Stats Summary Card

    /// Prominent stat grid shown at the top of the detail view.
    private var sessionStatsCard: some View {
        let totalSec     = Int(session.durationSeconds)
        let minutes      = totalSec / 60
        let seconds      = totalSec % 60
        let durStr       = minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
        let hasWPM       = session.paceWPM > 0
        let hasAcc       = session.estimatedAccuracy > 0
        let transcript   = session.finalTranscript
        let uniqueWords  = transcript.isEmpty ? 0 :
            Set(transcript.lowercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                .filter { !$0.isEmpty }
            ).count
        let sentences    = transcript.isEmpty ? 0 :
            transcript.components(separatedBy: CharacterSet(charactersIn: ".!?"))
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count

        // Silence ratio: total pause time / session duration (only when both are meaningful)
        let totalPause   = session.pausePattern.reduce(0, +)
        let silenceRatio = session.durationSeconds > 5 && totalPause > 0
            ? min(1.0, totalPause / session.durationSeconds)
            : 0.0
        let hasSilence   = silenceRatio > 0.01

        // Compare word count to user's average across all sessions
        let allSessions = appState.sessions
        let avgWordCount = allSessions.isEmpty ? 0 :
            allSessions.reduce(0) { $0 + $1.wordCount } / allSessions.count
        let wordDeltaPct: Int? = avgWordCount > 0 && allSessions.count >= 3 ?
            Int(round(Double(session.wordCount - avgWordCount) / Double(avgWordCount) * 100)) : nil

        return VStack(spacing: 0) {
            // Row 1: words + duration
            HStack(spacing: 0) {
                VStack(spacing: 6) {
                    Image(systemName: "text.word.spacing")
                        .font(.subheadline)
                        .foregroundStyle(Color.blue)
                    Text("\(session.wordCount)")
                        .font(.title2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    HStack(spacing: 4) {
                        Text("words")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let delta = wordDeltaPct, abs(delta) >= 5 {
                            Text(delta > 0 ? "+\(delta)%" : "\(delta)%")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(delta > 0 ? .green : .red)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background((delta > 0 ? Color.green : Color.red).opacity(0.12),
                                            in: Capsule())
                        }
                    }
                    if session.wordCount >= 50 {
                        Text("~\(readingTimeMinutes) min read")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                statCellDivider()
                statCell(value: durStr, label: "duration",
                         icon: "timer", color: .purple)
            }

            // Row 2: WPM + accuracy (only when available)
            if hasWPM || hasAcc {
                Divider().padding(.horizontal, 16)
                HStack(spacing: 0) {
                    if hasWPM {
                        statCell(value: String(format: "%.0f", session.paceWPM), label: "WPM",
                                 icon: "gauge.with.needle", color: .orange)
                    }
                    if hasWPM && hasAcc { statCellDivider() }
                    if hasAcc {
                        statCell(value: "\(Int(session.estimatedAccuracy))%", label: "accuracy",
                                 icon: "checkmark.seal.fill", color: .green)
                    }
                    if hasWPM != hasAcc { Spacer() }
                }
            }

            // Row 3: unique words + sentences (only when transcript is non-empty)
            if !transcript.isEmpty {
                Divider().padding(.horizontal, 16)
                HStack(spacing: 0) {
                    statCell(value: "\(uniqueWords)", label: "unique words",
                             icon: "character.book.closed", color: .teal)
                    statCellDivider()
                    statCell(value: "\(sentences)", label: "sentences",
                             icon: "list.number", color: .indigo)
                }
            }

            // Row 4: silence ratio (only when pause data is available)
            if hasSilence {
                Divider().padding(.horizontal, 16)
                HStack(spacing: 0) {
                    statCell(value: "\(Int(silenceRatio * 100))%", label: "silence",
                             icon: "waveform.slash", color: .gray)
                    statCellDivider()
                    statCell(
                        value: "\(session.pausePattern.count)",
                        label: "pauses",
                        icon: "pause.circle", color: .secondary
                    )
                }
            }

            // Row 5: reading time + character count (only for non-empty transcripts)
            if !transcript.isEmpty {
                let readSec = Int(ceil(Double(session.wordCount) / 250.0 * 60.0))
                let readStr = readSec < 60
                    ? "~\(readSec)s"
                    : "~\(Int(ceil(Double(readSec) / 60.0)))m"
                let charCount = transcript.count
                Divider().padding(.horizontal, 16)
                HStack(spacing: 0) {
                    statCell(value: readStr, label: "read time",
                             icon: "book.pages", color: .brown)
                    statCellDivider()
                    statCell(value: "\(charCount)", label: "characters",
                             icon: "character.cursor.ibeam", color: .pink)
                }
            }

            // Row 6: vocabulary richness + readability (only when ≥ 80 words)
            if session.wordCount >= 80, !transcript.isEmpty {
                let ttr = uniqueWords > 0 && session.wordCount > 0
                    ? Int(round(Double(uniqueWords) / Double(session.wordCount) * 100))
                    : 0
                let readScore = fleschReadabilityScore(text: transcript)
                Divider().padding(.horizontal, 16)
                HStack(spacing: 0) {
                    statCell(value: "\(ttr)%", label: "vocab richness",
                             icon: "textformat.abc", color: .cyan)
                    statCellDivider()
                    statCell(value: readabilityLabel(readScore), label: "readability",
                             icon: "chart.bar.doc.horizontal", color: .indigo)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(.systemGray4), lineWidth: 0.5))
    }

    private func statCell(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(color)
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func statCellDivider() -> some View {
        Rectangle()
            .fill(Color(.systemGray4))
            .frame(width: 0.5)
            .padding(.vertical, 12)
    }

    private var sessionMeta: some View {
        // Average adult reading speed ≈ 238 wpm (source: multiple studies)
        let readSecs = session.wordCount > 0 ? max(1, Int((Double(session.wordCount) / 238.0) * 60)) : 0
        let readLabel = readSecs >= 60
            ? "\(readSecs / 60)m \(readSecs % 60)s read"
            : "\(readSecs)s read"

        return HStack(spacing: 0) {
            metaItem(icon: "clock",
                     label: session.startedAt.formatted(date: .abbreviated, time: .shortened))
            metaItem(icon: "timer",
                     label: "\(Int(session.durationSeconds))s")
            metaItem(icon: "text.word.spacing",
                     label: "\(session.wordCount)w")
            if session.wordCount > 0 {
                metaItem(icon: "book.pages",
                         label: readLabel)
            }
            metaItem(icon: "globe",
                     label: Locale.current.localizedString(forLanguageCode: session.primaryLanguage)
                            ?? session.primaryLanguage)
        }
        .padding(14)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
    }

    private func metaItem(icon: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.caption).foregroundStyle(Color.accentColor)
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var languageSpansView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Language mixing detected", systemImage: "globe")
                .font(.subheadline.weight(.semibold))
            Text("You switched languages during this session.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Audio Playback Card

    private var audioPlaybackCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Recorded audio", systemImage: "waveform.and.mic")
                .font(.headline)

            // Playback progress bar — draggable scrubber
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.systemGray4))
                        .frame(height: 4)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * audioProgress, height: 4)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let pct = max(0, min(1, value.location.x / geo.size.width))
                            audioPlayer?.currentTime = pct * audioDuration
                            audioCurrentTime = pct * audioDuration
                            audioProgress = pct
                        }
                )
            }
            .frame(height: 20)

            // Transport controls row
            HStack {
                Text(formatAudioTime(audioCurrentTime))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .leading)

                Spacer()

                // Skip back 10 s
                Button {
                    let newTime = max(0, (audioPlayer?.currentTime ?? 0) - 10)
                    audioPlayer?.currentTime = newTime
                    audioCurrentTime = newTime
                    audioProgress = audioDuration > 0 ? newTime / audioDuration : 0
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skip back 10 seconds")

                // Play / Pause
                Button { toggleAudioPlayback() } label: {
                    Image(systemName: isPlayingAudio ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.bounce, value: isPlayingAudio)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlayingAudio ? "Pause" : "Play")

                // Skip forward 10 s
                Button {
                    let newTime = min(audioDuration, (audioPlayer?.currentTime ?? 0) + 10)
                    audioPlayer?.currentTime = newTime
                    audioCurrentTime = newTime
                    audioProgress = audioDuration > 0 ? newTime / audioDuration : 0
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skip forward 10 seconds")

                Spacer()

                Text(formatAudioTime(audioDuration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }

            // Playback speed selector
            HStack(spacing: 6) {
                Image(systemName: "speedometer")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ForEach([Float(0.5), 1.0, 1.5, 2.0], id: \.self) { rate in
                    let label = rate == 1.0 ? "1×" : rate == 0.5 ? "0.5×" : "\(rate)×"
                    Button {
                        playbackRate = rate
                        audioPlayer?.rate = rate
                    } label: {
                        Text(label)
                            .font(.caption.weight(playbackRate == rate ? .semibold : .regular))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                playbackRate == rate ? Color.accentColor : Color(.systemGray5),
                                in: Capsule()
                            )
                            .foregroundStyle(playbackRate == rate ? .white : .secondary)
                    }
                    .buttonStyle(.plain)
                    .animation(.snappy, value: playbackRate)
                }

                Spacer()
            }
        }
        .padding(14)
        .background(Color(.systemGray6).opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }

    private func toggleAudioPlayback() {
        guard let player = audioPlayer else { return }
        if isPlayingAudio {
            player.pause()
            isPlayingAudio = false
        } else {
            // Restart from beginning if finished
            if player.currentTime >= player.duration { player.currentTime = 0 }
            player.rate = playbackRate          // apply current speed before resuming
            player.play()
            isPlayingAudio = true
        }
    }

    private func formatAudioTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Read Aloud

    private func toggleReadAloud() {
        if isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
            isSpeaking = false
        } else {
            let utterance = AVSpeechUtterance(string: editedText)
            utterance.voice = AVSpeechSynthesisVoice(language: session.primaryLanguage)
                ?? AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            speechSynthesizer.speak(utterance)
            isSpeaking = true
            // Auto-reset flag when speech finishes
            Task { @MainActor in
                while speechSynthesizer.isSpeaking {
                    try? await Task.sleep(for: .seconds(0.5))
                }
                isSpeaking = false
            }
        }
    }

    // MARK: - Readability

    /// Simplified Flesch Reading Ease score (0–100; higher = easier to read).
    private func fleschReadabilityScore(text: String) -> Double {
        let sentenceBreakers = CharacterSet(charactersIn: ".!?")
        let sentences = max(1, text
            .components(separatedBy: sentenceBreakers)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count)
        let wordTokens = text.split(whereSeparator: { $0.isWhitespace })
        let wordCount = wordTokens.count
        guard wordCount > 0 else { return 100 }

        let syllables = wordTokens.reduce(0) { total, token in
            let cleaned = String(token).lowercased()
            var syl = 0, prevVowel = false
            for ch in cleaned where ch.isLetter {
                let isVowel = "aeiou".contains(ch)
                if isVowel, !prevVowel { syl += 1 }
                prevVowel = isVowel
            }
            return total + max(1, syl)
        }

        let wps = Double(wordCount) / Double(sentences)
        let spw = Double(syllables) / Double(wordCount)
        return 206.835 - 1.015 * wps - 84.6 * spw
    }

    private func readabilityLabel(_ score: Double) -> String {
        switch score {
        case 90...:       return "Very Easy"
        case 70..<90:     return "Easy"
        case 60..<70:     return "Standard"
        case 50..<60:     return "Fairly Hard"
        case 30..<50:     return "Hard"
        default:          return "Very Hard"
        }
    }

    // MARK: - Paragraph Formatting

    /// Reconstructs the transcript with paragraph breaks inserted wherever consecutive
    /// segments are separated by a pause of ≥ 2.5 seconds.
    private func formatTranscriptParagraphs() {
        let sorted = session.segments.sorted { $0.startTime < $1.startTime }
        guard !sorted.isEmpty else { return }

        let gapThreshold: TimeInterval = 2.5
        var paragraphs: [String] = []
        var current: [String] = []

        for i in sorted.indices {
            let seg = sorted[i]
            let word = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !word.isEmpty { current.append(word) }

            if i + 1 < sorted.count {
                let gap = sorted[i + 1].startTime - seg.endTime
                if gap >= gapThreshold, !current.isEmpty {
                    paragraphs.append(current.joined(separator: " "))
                    current = []
                }
            }
        }
        if !current.isEmpty {
            paragraphs.append(current.joined(separator: " "))
        }

        let formatted = paragraphs.joined(separator: "\n\n")
        guard !formatted.isEmpty, formatted != editedText else { return }
        withAnimation(.snappy) {
            editedText = formatted
            didEdit = true
        }
    }

    // MARK: - Similar Sessions

    /// Sessions related by shared tags, language, and similar word count.
    /// Scored: +2 per shared tag, −1 per 50 words of word-count distance.
    /// Falls back to word-count proximity when there are no shared tags.
    private var similarSessions: [TranscriptionSession] {
        let wc        = session.wordCount
        let lang      = session.primaryLanguage
        let myTags    = Set(session.tags.map { $0.lowercased() })
        let tolerance = max(wc / 2, 30)

        return appState.sessions
            .filter { s in
                s.id != session.id
                && !s.isArchived
                && s.primaryLanguage == lang
                && !s.finalTranscript.isEmpty
                && (wc == 0 || abs(s.wordCount - wc) <= tolerance)
            }
            .sorted { a, b in
                let sharedA = Set(a.tags.map { $0.lowercased() }).intersection(myTags).count
                let sharedB = Set(b.tags.map { $0.lowercased() }).intersection(myTags).count
                let scoreA  = Double(sharedA) * 2.0 - Double(abs(a.wordCount - wc)) / 50.0
                let scoreB  = Double(sharedB) * 2.0 - Double(abs(b.wordCount - wc)) / 50.0
                return scoreA > scoreB
            }
            .prefix(3)
            .map { $0 }
    }

    @ViewBuilder
    private var similarSessionsSection: some View {
        let similar = similarSessions
        if !similar.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label("Related sessions", systemImage: "square.stack")
                    .font(.headline)

                ForEach(similar) { s in
                    Button {
                        selectedSimilarSession = s
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: s.isStarred ? "star.fill" : "waveform")
                                .font(.body)
                                .foregroundStyle(s.isStarred ? Color.yellow : Color.accentColor)
                                .frame(width: 34, height: 34)
                                .background(Color.accentColor.opacity(0.1), in: Circle())

                            VStack(alignment: .leading, spacing: 3) {
                                Text(s.customTitle ?? String(s.finalTranscript.prefix(70)))
                                    .font(.subheadline)
                                    .lineLimit(2)
                                    .foregroundStyle(.primary)
                                HStack(spacing: 5) {
                                    Text(s.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    Text("·")
                                    Text("\(s.wordCount) words")
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if s.id != similar.last?.id {
                        Divider().padding(.leading, 46)
                    }
                }
            }
            .padding(14)
            .background(Color(.systemGray6).opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - UIActivityViewController wrapper

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Session Share Card (rendered to PNG via ImageRenderer)

/// A fixed-size view used as the source for "Share as image".
/// Designed to look great as a standalone card when shared to social media or messages.
struct SessionShareCardView: View {
    let session: TranscriptionSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header gradient band
            LinearGradient(
                colors: [Color(red: 0.1, green: 0.3, blue: 0.9),
                         Color(red: 0.4, green: 0.1, blue: 0.8)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(height: 8)

            VStack(alignment: .leading, spacing: 16) {
                // App watermark
                HStack {
                    Image(systemName: "waveform")
                        .font(.headline)
                        .foregroundStyle(Color(red: 0.25, green: 0.35, blue: 0.9))
                    Text("Lexora")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Color(red: 0.25, green: 0.35, blue: 0.9))
                    Spacer()
                    Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Transcript excerpt
                Text(session.finalTranscript.isEmpty ? "(empty session)" : session.finalTranscript)
                    .font(.body)
                    .lineLimit(5)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                // Stats row
                HStack(spacing: 0) {
                    cardStat(value: "\(session.wordCount)", label: "words")
                    Divider().frame(height: 32)
                    cardStat(value: durationString, label: "duration")
                    Divider().frame(height: 32)
                    cardStat(
                        value: Locale.current.localizedString(forLanguageCode: session.primaryLanguage)
                               ?? session.primaryLanguage.uppercased(),
                        label: "language"
                    )
                    if session.estimatedAccuracy > 0 {
                        Divider().frame(height: 32)
                        cardStat(value: "\(Int(session.estimatedAccuracy))%", label: "accuracy")
                    }
                }
            }
            .padding(20)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
        .frame(width: 340)
    }

    private func cardStat(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.subheadline, design: .rounded).bold())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var durationString: String {
        let s = Int(session.durationSeconds)
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m\(s % 60 > 0 ? " \(s % 60)s" : "")"
    }
}

// MARK: - Word Cloud Share Card

struct WordCloudCardView: View {
    let session: TranscriptionSession
    let text: String

    private static let stopWords: Set<String> = [
        "the","a","an","and","or","but","in","on","at","to","for","of","with","by","from",
        "is","are","was","were","be","been","being","have","has","had","do","does","did",
        "will","would","could","should","may","might","shall","this","that","these","those",
        "i","my","me","we","our","you","your","he","his","she","her","it","its","they","their",
        "what","which","who","when","where","how","not","no","nor","so","yet","both","either",
        "as","if","then","than","also","just","about","up","out","can","there","here","all",
        "each","every","some","any","most","more","other","into","over","after","before","while"
    ]

    /// Top N words ranked by frequency, filtering stop words and very short words.
    private var topWords: [(word: String, count: Int)] {
        let raw = text
            .lowercased()
            .components(separatedBy: .init(charactersIn: " \n\t.,!?;:'\"()[]{}—–-"))
            .filter { $0.count > 2 && !Self.stopWords.contains($0) }
        var freq = [String: Int]()
        for w in raw { freq[w, default: 0] += 1 }
        return freq
            .sorted { $0.value > $1.value }
            .prefix(28)
            .map { (word: $0.key, count: $0.value) }
    }

    private var maxCount: Int { topWords.first?.count ?? 1 }

    private func fontSize(for count: Int) -> CGFloat {
        let ratio = CGFloat(count) / CGFloat(max(maxCount, 1))
        return 13 + ratio * 26  // 13pt … 39pt
    }

    private let palette: [Color] = [
        Color(red: 0.29, green: 0.11, blue: 0.78),
        Color(red: 0.56, green: 0.18, blue: 0.82),
        Color(red: 0.15, green: 0.45, blue: 0.90),
        Color(red: 0.05, green: 0.65, blue: 0.72),
        Color(red: 0.40, green: 0.28, blue: 0.90),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header band
            LinearGradient(
                colors: [Color(red: 0.29, green: 0.11, blue: 0.78),
                         Color(red: 0.56, green: 0.18, blue: 0.82)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(height: 6)

            VStack(alignment: .leading, spacing: 12) {
                // App watermark row
                HStack {
                    Image(systemName: "waveform")
                        .font(.subheadline)
                        .foregroundStyle(Color(red: 0.29, green: 0.11, blue: 0.78))
                    Text("Lexora · Word Cloud")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color(red: 0.29, green: 0.11, blue: 0.78))
                    Spacer()
                    Text(session.startedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if topWords.isEmpty {
                    Text("Not enough words to generate a cloud.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                } else {
                    // Word cloud using a wrapping flow
                    CloudFlowLayout(spacing: 6) {
                        ForEach(topWords.shuffled(), id: \.word) { item in
                            Text(item.word)
                                .font(.system(size: fontSize(for: item.count), weight: fontSize(for: item.count) > 28 ? .bold : .medium, design: .rounded))
                                .foregroundStyle(palette[abs(item.word.hashValue) % palette.count])
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                        }
                    }
                }

                Divider()

                // Footer stats
                HStack(spacing: 16) {
                    Label("\(session.wordCount) words", systemImage: "text.word.spacing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Label("\(topWords.count) unique top words", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.10), radius: 10, x: 0, y: 4)
        .frame(width: 340)
    }
}

/// Simple wrapping layout for the word cloud — similar to FlowLayout but centered.
private struct CloudFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 340
        var height: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width + spacing > width && rowWidth > 0 {
                height += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        height += rowHeight
        return CGSize(width: width, height: max(height, 60))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var rows: [[LayoutSubviews.Element]] = []
        var row: [LayoutSubviews.Element] = []
        var rowWidth: CGFloat = 0
        let width = bounds.width
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width + spacing > width && rowWidth > 0 {
                rows.append(row)
                row = []
                rowWidth = 0
            }
            row.append(subview)
            rowWidth += size.width + spacing
        }
        if !row.isEmpty { rows.append(row) }

        var y = bounds.minY
        for row in rows {
            let sizes = row.map { $0.sizeThatFits(.unspecified) }
            let totalW = sizes.map(\.width).reduce(0, +) + CGFloat(sizes.count - 1) * spacing
            var x = bounds.minX + (bounds.width - totalW) / 2
            let rowH = sizes.map(\.height).max() ?? 0
            for (subview, size) in zip(row, sizes) {
                subview.place(at: CGPoint(x: x, y: y + (rowH - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += rowH + spacing
        }
    }
}

// MARK: - Files app (iCloud Drive / local) export picker

struct FilesExporter: UIViewControllerRepresentable {
    let url: URL
    var onDismiss: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // .moveToService gives the user a "copy" of the file to a chosen location
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onDismiss: (() -> Void)?
        init(onDismiss: (() -> Void)?) { self.onDismiss = onDismiss }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onDismiss?()
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onDismiss?()
        }
    }
}

// MARK: - Tag Management

/// Per-tag summary computed from the full session list.
struct TagSummary: Identifiable {
    var id: String { tag }
    let tag: String
    let sessionCount: Int
    let totalWords: Int
    let lastUsed: Date?
}

/// Full CRUD management for tags across all sessions:
/// rename, delete, and merge with swipe or tap gestures.
struct TagManagementView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var showRenameAlert = false
    @State private var tagToRename = ""
    @State private var renameInput = ""
    @State private var showMergeSheet = false
    @State private var tagToMerge = ""
    @State private var mergeTarget = ""

    private var tagSummaries: [TagSummary] {
        var freq: [String: (count: Int, words: Int, last: Date?)] = [:]
        for s in appState.sessions {
            for tag in s.tags {
                let current = freq[tag] ?? (0, 0, nil)
                let newLast: Date? = {
                    guard let prev = current.last else { return s.startedAt }
                    return s.startedAt > prev ? s.startedAt : prev
                }()
                freq[tag] = (current.count + 1, current.words + s.wordCount, newLast)
            }
        }
        return freq
            .filter { searchText.isEmpty || $0.key.localizedCaseInsensitiveContains(searchText) }
            .map { TagSummary(tag: $0.key, sessionCount: $0.value.count, totalWords: $0.value.words, lastUsed: $0.value.last) }
            .sorted { $0.sessionCount > $1.sessionCount }
    }

    private var allTagNames: [String] {
        var seen = Set<String>()
        return appState.sessions.flatMap { $0.tags }.filter { seen.insert($0).inserted }.sorted()
    }

    var body: some View {
        List {
            if tagSummaries.isEmpty && !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else if tagSummaries.isEmpty {
                ContentUnavailableView(
                    "No tags yet",
                    systemImage: "tag",
                    description: Text("Tags are added when you record with a template, or manually in session detail.")
                )
            } else {
                Section {
                    ForEach(tagSummaries) { summary in
                        TagManagementRow(summary: summary)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    deleteTag(summary.tag)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    tagToRename  = summary.tag
                                    renameInput  = summary.tag
                                    showRenameAlert = true
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    tagToMerge  = summary.tag
                                    mergeTarget = ""
                                    showMergeSheet = true
                                } label: {
                                    Label("Merge into…", systemImage: "arrow.triangle.merge")
                                }
                                .tint(.orange)
                            }
                    }
                } header: {
                    Text("\(tagSummaries.count) tag\(tagSummaries.count == 1 ? "" : "s")")
                } footer: {
                    Text("Swipe left to rename or delete · Swipe right to merge into another tag")
                }
            }
        }
        .navigationTitle("Manage Tags")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "Search tags")
        .alert("Rename tag", isPresented: $showRenameAlert) {
            TextField("New name", text: $renameInput)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Rename") { renameTag(from: tagToRename, to: renameInput.trimmingCharacters(in: .whitespaces)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rename \"\(tagToRename)\" across all sessions.")
        }
        .sheet(isPresented: $showMergeSheet) {
            mergePicker
                .environment(appState)
        }
    }

    // MARK: Actions

    private func deleteTag(_ tag: String) {
        for i in appState.sessions.indices {
            appState.sessions[i].tags.removeAll { $0 == tag }
        }
    }

    private func renameTag(from old: String, to new: String) {
        guard !new.isEmpty, new != old else { return }
        for i in appState.sessions.indices {
            if let idx = appState.sessions[i].tags.firstIndex(of: old) {
                appState.sessions[i].tags[idx] = new
            }
        }
    }

    private func mergeTag(_ source: String, into target: String) {
        guard !target.isEmpty, source != target else { return }
        for i in appState.sessions.indices {
            if appState.sessions[i].tags.contains(source) {
                appState.sessions[i].tags.removeAll { $0 == source }
                if !appState.sessions[i].tags.contains(target) {
                    appState.sessions[i].tags.append(target)
                }
            }
        }
    }

    // MARK: Merge Picker Sheet

    private var mergePicker: some View {
        NavigationStack {
            List(allTagNames.filter { $0 != tagToMerge }, id: \.self) { tag in
                Button {
                    mergeTag(tagToMerge, into: tag)
                    showMergeSheet = false
                } label: {
                    HStack {
                        Text(tag)
                        Spacer()
                        Image(systemName: "arrow.triangle.merge")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }
                .foregroundStyle(.primary)
            }
            .navigationTitle("Merge \"\(tagToMerge)\" into\u{2026}")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showMergeSheet = false }
                }
            }
        }
    }
}

struct TagManagementRow: View {
    var summary: TagSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tag.fill")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(summary.tag)
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 8) {
                    Text("\(summary.sessionCount) session\(summary.sessionCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("\(summary.totalWords) words")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let last = summary.lastUsed {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(last.formatted(.relative(presentation: .named)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Session Swipe Browser

/// A full-screen pager that lets the user swipe horizontally between sessions.
/// Each page is a complete `SessionDetailView` with its own navigation stack.
/// Shown as a sheet; the position pill at the top tells the user where they are.
struct SessionSwipeBrowserView: View {
    var sessions: [TranscriptionSession]
    var initialID: UUID
    @State private var currentID: UUID

    init(sessions: [TranscriptionSession], initialID: UUID) {
        self.sessions = sessions
        self.initialID = initialID
        self._currentID = State(initialValue: initialID)
    }

    private var currentIndex: Int {
        sessions.firstIndex { $0.id == currentID } ?? 0
    }

    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $currentID) {
                ForEach(sessions) { session in
                    SessionDetailView(session: session)
                        .tag(session.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea(edges: .bottom)

            // ── Position pill (only when there's more than one session) ──
            if sessions.count > 1 {
                HStack(spacing: 6) {
                    if currentIndex > 0 {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    Text("\(currentIndex + 1) of \(sessions.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if currentIndex < sessions.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                .padding(.top, 8)
                .allowsHitTesting(false)
                .zIndex(10)
            }
        }
    }
}

// MARK: - Transcript Diff View

/// Word-level diff between the original (raw) transcript and the edited version.
struct TranscriptDiffView: View {
    let original: String
    let edited:   String
    @Environment(\.dismiss) private var dismiss

    // Segment types
    private enum DiffType { case same, added, removed }
    private struct DiffSegment: Identifiable {
        let id = UUID()
        let text: String
        let type: DiffType
    }

    /// Naive word-level longest-common-subsequence diff.
    private var segments: [DiffSegment] {
        let origWords = original.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let editWords = edited.components(separatedBy:  .whitespaces).filter { !$0.isEmpty }

        // Build LCS table
        let m = origWords.count, n = editWords.count
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 1...max(1, m) {
            for j in 1...max(1, n) {
                if i > m || j > n { break }
                dp[i][j] = origWords[i-1] == editWords[j-1]
                    ? dp[i-1][j-1] + 1
                    : max(dp[i-1][j], dp[i][j-1])
            }
        }

        // Traceback
        var result: [DiffSegment] = []
        var i = m, j = n
        var pending: [(String, DiffType)] = []
        while i > 0 || j > 0 {
            if i > 0, j > 0, origWords[i-1] == editWords[j-1] {
                pending.append((origWords[i-1], .same))
                i -= 1; j -= 1
            } else if j > 0, (i == 0 || dp[i][j-1] >= dp[i-1][j]) {
                pending.append((editWords[j-1], .added))
                j -= 1
            } else {
                pending.append((origWords[i-1], .removed))
                i -= 1
            }
        }
        result = pending.reversed().map { DiffSegment(text: $0.0, type: $0.1) }
        return result
    }

    private var addedCount:   Int { segments.filter { $0.type == .added   }.count }
    private var removedCount: Int { segments.filter { $0.type == .removed }.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Summary chips
                    HStack(spacing: 10) {
                        chip("+\(addedCount) added",    .green)
                        chip("-\(removedCount) removed", .red)
                        chip("\(segments.filter { $0.type == .same }.count) unchanged", .secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                    // Legend
                    HStack(spacing: 16) {
                        legendItem(color: .green, label: "Added")
                        legendItem(color: .red,   label: "Removed")
                        legendItem(color: .clear, label: "Unchanged")
                    }
                    .padding(.horizontal, 20)

                    // Diff text — word-by-word chips laid out in a wrapping flow
                    FlowLayout(spacing: 4) {
                        ForEach(segments) { seg in
                            switch seg.type {
                            case .same:
                                Text(seg.text)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                            case .added:
                                Text(seg.text)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 3)
                                    .padding(.vertical, 1)
                                    .background(Color.green.opacity(0.80), in: RoundedRectangle(cornerRadius: 3))
                            case .removed:
                                Text(seg.text)
                                    .font(.body)
                                    .foregroundStyle(Color.red.opacity(0.75))
                                    .strikethrough(true, color: .red)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func chip(_ label: String, _ color: Color) -> some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color == .secondary ? Color(.systemGray5) : color.opacity(0.15), in: Capsule())
            .foregroundStyle(color == .secondary ? Color.secondary : color)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color == .clear ? Color(.systemGray5) : color.opacity(0.8))
                .frame(width: 12, height: 12)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Session Comparison View

struct SessionComparisonView: View {
    var sessionA: TranscriptionSession
    var sessionB: TranscriptionSession
    @Environment(\.dismiss) private var dismiss

    private struct Metric: Identifiable {
        var id: String { label }
        var label: String
        var icon: String
        var valueA: Double
        var valueB: Double
        var formatA: String
        var formatB: String
        var higherIsBetter: Bool = true
    }

    private var metrics: [Metric] {
        let durA = sessionA.durationSeconds, durB = sessionB.durationSeconds
        let durStrA = durA >= 60 ? "\(Int(durA/60))m \(Int(durA)%60)s" : "\(Int(durA))s"
        let durStrB = durB >= 60 ? "\(Int(durB/60))m \(Int(durB)%60)s" : "\(Int(durB))s"
        let fillerA = Double(countFillers(sessionA.finalTranscript))
        let fillerB = Double(countFillers(sessionB.finalTranscript))
        return [
            Metric(label: "Words", icon: "text.word.spacing",
                   valueA: Double(sessionA.wordCount), valueB: Double(sessionB.wordCount),
                   formatA: "\(sessionA.wordCount)", formatB: "\(sessionB.wordCount)"),
            Metric(label: "Duration", icon: "clock",
                   valueA: durA, valueB: durB,
                   formatA: durStrA, formatB: durStrB),
            Metric(label: "Pace (WPM)", icon: "hare",
                   valueA: sessionA.paceWPM, valueB: sessionB.paceWPM,
                   formatA: "\(Int(sessionA.paceWPM))", formatB: "\(Int(sessionB.paceWPM))"),
            Metric(label: "Confidence", icon: "checkmark.seal",
                   valueA: sessionA.confidenceAverage, valueB: sessionB.confidenceAverage,
                   formatA: "\(Int(sessionA.confidenceAverage * 100))%",
                   formatB: "\(Int(sessionB.confidenceAverage * 100))%"),
            Metric(label: "Filler words", icon: "bubble.left",
                   valueA: fillerA, valueB: fillerB,
                   formatA: "\(Int(fillerA))", formatB: "\(Int(fillerB))",
                   higherIsBetter: false),
        ]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Session header row
                    HStack(alignment: .top, spacing: 16) {
                        sessionHeader(sessionA, side: .leading)
                        Divider()
                        sessionHeader(sessionB, side: .trailing)
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))

                    // Metrics
                    VStack(spacing: 12) {
                        ForEach(metrics) { metric in
                            metricRow(metric)
                        }
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))

                    // Tags comparison
                    if !sessionA.tags.isEmpty || !sessionB.tags.isEmpty {
                        tagsComparison
                    }
                }
                .padding()
            }
            .navigationTitle("Compare Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func sessionHeader(_ session: TranscriptionSession, side: HorizontalAlignment) -> some View {
        VStack(alignment: side, spacing: 4) {
            Text(session.startedAt.formatted(date: .abbreviated, time: .omitted))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(session.customTitle ?? session.startedAt.formatted(date: .omitted, time: .shortened))
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(side == .leading ? .leading : .trailing)
            if !session.tags.isEmpty {
                Text(session.tags.prefix(2).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: side, vertical: .top))
    }

    private func metricRow(_ metric: Metric) -> some View {
        let total = metric.valueA + metric.valueB
        let fracA = total > 0 ? metric.valueA / total : 0.5
        let winnerA = metric.higherIsBetter ? metric.valueA >= metric.valueB : metric.valueA <= metric.valueB
        let winnerB = metric.higherIsBetter ? metric.valueB > metric.valueA : metric.valueB < metric.valueA

        return VStack(spacing: 6) {
            HStack {
                Text(metric.formatA)
                    .font(.subheadline.weight(winnerA ? .bold : .regular))
                    .foregroundStyle(winnerA ? Color.accentColor : .primary)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: metric.icon)
                        .font(.caption2)
                    Text(metric.label)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                Spacer()
                Text(metric.formatB)
                    .font(.subheadline.weight(winnerB ? .bold : .regular))
                    .foregroundStyle(winnerB ? Color.accentColor : .primary)
            }

            // Visual bar
            GeometryReader { geo in
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(winnerA ? Color.accentColor : Color.accentColor.opacity(0.3))
                        .frame(width: geo.size.width * fracA - 1)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(winnerB ? Color.indigo : Color.indigo.opacity(0.3))
                        .frame(width: geo.size.width * (1 - fracA) - 1)
                }
            }
            .frame(height: 6)
        }
    }

    private var tagsComparison: some View {
        let onlyA = Set(sessionA.tags).subtracting(sessionB.tags)
        let shared = Set(sessionA.tags).intersection(sessionB.tags)
        let onlyB = Set(sessionB.tags).subtracting(sessionA.tags)
        return VStack(alignment: .leading, spacing: 10) {
            Label("Tags", systemImage: "tag.fill")
                .font(.subheadline.weight(.semibold))
            if !shared.isEmpty {
                tagRow("Shared", Array(shared), color: .green)
            }
            if !onlyA.isEmpty {
                tagRow("Only in A", Array(onlyA), color: Color.accentColor)
            }
            if !onlyB.isEmpty {
                tagRow("Only in B", Array(onlyB), color: .indigo)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func tagRow(_ label: String, _ tags: [String], color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            FlowLayout(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(color)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(color.opacity(0.12), in: Capsule())
                }
            }
        }
    }

    private func countFillers(_ text: String) -> Int {
        let lower = text.lowercased()
        let fillers = ["um", "uh", "like", "you know", "i mean", "basically", "literally", "actually", "so"]
        return fillers.reduce(0) { $0 + max(0, lower.components(separatedBy: " \($1) ").count - 1) }
    }
}

// MARK: - Transcript Reading View

/// Distraction-free full-screen reading mode for a transcript.
/// Supports adjustable font size, line spacing, and a reading-progress bar.
struct TranscriptReadingView: View {
    let text: String
    let session: TranscriptionSession
    var sentimentScore: Double? = nil

    @Environment(\.dismiss) private var dismiss
    @AppStorage("readerFontSize")    private var fontSize: Double = 18
    @AppStorage("readerLineSpacing") private var lineSpacing: Double = 8
    @AppStorage("readerFontDesign")  private var fontDesignRaw: String = "default"
    @State private var showControls = true
    @State private var scrollProgress: Double = 0

    private var fontDesign: Font.Design {
        switch fontDesignRaw {
        case "serif":     return .serif
        case "monospaced": return .monospaced
        default:          return .default
        }
    }

    private var readingTime: Int {
        max(1, text.split(separator: " ").count / 238)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Reading progress bar
            GeometryReader { outer in
                VStack(spacing: 0) {
                    // Thin progress strip
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: outer.size.width * scrollProgress, height: 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .animation(.linear(duration: 0.05), value: scrollProgress)

                    // Scrollable content
                    ScrollView {
                        GeometryReader { inner in
                            Color.clear
                                .preference(
                                    key: ScrollOffsetKey.self,
                                    value: -inner.frame(in: .named("scroll")).minY
                                )
                        }
                        .frame(height: 0)

                        VStack(alignment: .leading, spacing: 24) {
                            // Session header
                            VStack(alignment: .leading, spacing: 4) {
                                if let title = session.customTitle {
                                    Text(title)
                                        .font(.system(size: fontSize + 4, weight: .bold, design: fontDesign))
                                }
                                HStack(spacing: 8) {
                                    Text(session.startedAt, style: .date)
                                    Text("·")
                                    Text("\(session.wordCount) words")
                                    Text("·")
                                    Text("\(readingTime) min read")
                                    if let score = sentimentScore {
                                        Text("·")
                                        let emoji: String = score > 0.2 ? "😊" : score < -0.2 ? "😐" : "🙂"
                                        Text(emoji)
                                    }
                                }
                                .font(.system(size: fontSize - 4, design: fontDesign))
                                .foregroundStyle(.secondary)
                            }

                            Divider()

                            // Transcript body
                            Text(text)
                                .font(.system(size: fontSize, design: fontDesign))
                                .lineSpacing(lineSpacing)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, showControls ? 60 : 20)
                        .padding(.bottom, 60)
                    }
                    .coordinateSpace(name: "scroll")
                    .onPreferenceChange(ScrollOffsetKey.self) { offset in
                        // Estimate total content height
                        let approxHeight = CGFloat(text.count / 4) * (fontSize + lineSpacing)
                        let viewH = outer.size.height
                        if approxHeight > viewH {
                            scrollProgress = min(1.0, max(0, offset / (approxHeight - viewH)))
                        }
                    }
                }
            }

            // Controls overlay
            if showControls {
                VStack(spacing: 0) {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        // Font controls
                        HStack(spacing: 12) {
                            Button { fontSize = max(12, fontSize - 2) } label: {
                                Image(systemName: "textformat.size.smaller")
                                    .font(.subheadline)
                            }
                            Button { fontSize = min(32, fontSize + 2) } label: {
                                Image(systemName: "textformat.size.larger")
                                    .font(.subheadline)
                            }
                            Menu {
                                Button("Default") { fontDesignRaw = "default" }
                                Button("Serif")   { fontDesignRaw = "serif" }
                                Button("Mono")    { fontDesignRaw = "monospaced" }
                            } label: {
                                Image(systemName: "textformat")
                                    .font(.subheadline)
                            }
                            Button {
                                lineSpacing = lineSpacing > 4 ? 4 : 12
                            } label: {
                                Image(systemName: lineSpacing > 4 ? "line.3.horizontal.decrease" : "line.3.horizontal")
                                    .font(.subheadline)
                            }
                            .help("Toggle line spacing")
                        }
                        .foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.thinMaterial)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(Color(.systemBackground))
        .onTapGesture {
            withAnimation(.snappy) { showControls.toggle() }
        }
        .statusBar(hidden: !showControls)
        .ignoresSafeArea(edges: showControls ? [] : .all)
    }
}

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

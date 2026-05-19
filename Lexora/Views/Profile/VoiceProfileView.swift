import SwiftUI
import TipKit
import Contacts
import UIKit
import NaturalLanguage
import AVFoundation
import Charts

struct VoiceProfileView: View {
    @Environment(AppState.self) private var appState
    @State private var showAddVocabulary = false
    @State private var showImportContacts = false
    @State private var showBulkPasteImport = false
    @State private var bulkPasteText = ""
    @State private var contactImportStatus = ""
    @State private var searchVocab = ""
    @State private var selectedCategory: VocabularyCategory? = nil
    @State private var showAddContextProfile = false
    @State private var showDictionarySheet = false
    @State private var dictionaryTerm = ""
    @State private var showVocabExportSheet = false
    @State private var vocabExportItems: [Any] = []
    @State private var showSmartLearnSheet = false
    @State private var smartLearnSuggestions: [String] = []
    @State private var showStudyMode = false
    private let addVocabTip = AddVocabularyTip()

    enum VocabSortOrder: String, CaseIterable, Identifiable {
        case usage       = "Most used"
        case alphabetical = "A–Z"
        case score       = "Confidence score"
        case recent      = "Recently added"
        var id: String { rawValue }
    }
    @State private var vocabSort: VocabSortOrder = .usage

    enum ConfidenceFilter: String, CaseIterable, Identifiable {
        case all    = "All"
        case high   = "High"
        case medium = "Medium"
        case low    = "Low"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .all:    return "line.3.horizontal.decrease.circle"
            case .high:   return "checkmark.seal.fill"
            case .medium: return "minus.circle.fill"
            case .low:    return "exclamationmark.circle.fill"
            }
        }
        var color: Color {
            switch self {
            case .all: return .accentColor
            case .high: return .green
            case .medium: return .orange
            case .low: return .red
            }
        }
    }
    @State private var confidenceFilter: ConfidenceFilter = .all

    enum SourceFilter: String, CaseIterable, Identifiable {
        case all       = "All sources"
        case userAdded = "Added manually"
        case autoDetected = "Auto-detected"
        case contacts  = "From Contacts"
        var id: String { rawValue }
        var entrySource: EntrySource? {
            switch self {
            case .all:          return nil
            case .userAdded:    return .userAdded
            case .autoDetected: return .autoDetected
            case .contacts:     return .importedFromContacts
            }
        }
    }
    @State private var sourceFilter: SourceFilter = .all

    private var profile: UserVoiceProfile { appState.profile }

    var filteredVocabulary: [VocabularyEntry] {
        let base = profile.customVocabulary.filter { entry in
            let matchesSearch = searchVocab.isEmpty ||
                entry.term.localizedCaseInsensitiveContains(searchVocab)
            let matchesCategory = selectedCategory == nil ||
                entry.category == selectedCategory
            let matchesConfidence: Bool = {
                switch confidenceFilter {
                case .all:    return true
                case .high:   return entry.relevanceScore > 0.7
                case .medium: return entry.relevanceScore >= 0.4 && entry.relevanceScore <= 0.7
                case .low:    return entry.relevanceScore < 0.4
                }
            }()
            let matchesSource = sourceFilter.entrySource == nil || entry.source == sourceFilter.entrySource!
            return matchesSearch && matchesCategory && matchesConfidence && matchesSource
        }
        switch vocabSort {
        case .usage:        return base.sorted { $0.usageCount > $1.usageCount }
        case .alphabetical: return base.sorted { $0.term.localizedCompare($1.term) == .orderedAscending }
        case .score:        return base.sorted { $0.relevanceScore > $1.relevanceScore }
        case .recent:       return base.reversed()
        }
    }

    var body: some View {
        NavigationStack {
            List {
                sessionStatsSection
                speakingInsightsSection
                languageSection
                contextProfilesSection
                vocabularySection
                correctionsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Voice Profile")
            .searchable(text: $searchVocab, prompt: "Search vocabulary")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Confidence + source filter picker
                    Menu {
                        Picker("Confidence", selection: $confidenceFilter) {
                            ForEach(ConfidenceFilter.allCases) { f in
                                Label(f.rawValue, systemImage: f.icon).tag(f)
                            }
                        }
                        Divider()
                        Picker("Source", selection: $sourceFilter) {
                            ForEach(SourceFilter.allCases) { s in
                                Text(s.rawValue).tag(s)
                            }
                        }
                    } label: {
                        let isFiltered = confidenceFilter != .all || sourceFilter != .all
                        Image(systemName: isFiltered
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                        .foregroundStyle(isFiltered ? Color.accentColor : .primary)
                    }

                    // Vocabulary sort order picker
                    Menu {
                        Picker("Sort vocabulary", selection: $vocabSort) {
                            ForEach(VocabSortOrder.allCases) { order in
                                Text(order.rawValue).tag(order)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }

                    Menu {
                        Button {
                            showAddVocabulary = true
                        } label: {
                            Label("Add manually", systemImage: "plus")
                        }
                        Button {
                            importFromContacts()
                        } label: {
                            Label("Import from Contacts", systemImage: "person.crop.circle.fill.badge.plus")
                        }
                        Button {
                            bulkPasteText = UIPasteboard.general.string ?? ""
                            showBulkPasteImport = true
                        } label: {
                            Label("Paste word list", systemImage: "doc.on.clipboard")
                        }
                        Divider()
                        Button {
                            exportVocabularyCSV()
                        } label: {
                            Label("Export as CSV", systemImage: "square.and.arrow.up")
                        }
                        .disabled(profile.customVocabulary.isEmpty)
                        Button {
                            exportVocabularyAnki()
                        } label: {
                            Label("Export for Anki", systemImage: "rectangle.stack.fill")
                        }
                        .disabled(profile.customVocabulary.isEmpty)
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showAddVocabulary) {
            AddVocabularyView()
        }
        .sheet(isPresented: $showDictionarySheet) {
            NavigationStack {
                DictionaryLookupView(term: dictionaryTerm)
                    .navigationTitle("Definition")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showDictionarySheet = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .alert("Contacts import", isPresented: $showImportContacts) {
            Button("OK") { contactImportStatus = "" }
        } message: {
            Text(contactImportStatus)
        }
        .sheet(isPresented: $showVocabExportSheet) {
            ShareSheet(items: vocabExportItems)
        }
        .sheet(isPresented: $showBulkPasteImport) {
            BulkPasteImportView(pasteText: $bulkPasteText)
                .environment(appState)
        }
    }

    // MARK: - Sections

    private var speakingInsightsSection: some View {
        Section("Speaking insights") {
            insightRow(
                icon: "speedometer",
                color: .green,
                title: "Speaking pace",
                value: "\(Int(profile.averageSpeakingPaceWPM)) words/min",
                note: paceDescription
            )
            insightRow(
                icon: "timer",
                color: .blue,
                title: "Natural pause",
                value: "\(Int(profile.averagePauseMilliseconds)) ms",
                note: "Average pause — used to avoid cutting you off mid-thought"
            )
            insightRow(
                icon: "text.alignleft",
                color: .orange,
                title: "Avg sentence length",
                value: "\(Int(profile.sentenceLengthAverage)) words",
                note: nil
            )
            insightRow(
                icon: "waveform.badge.magnifyingglass",
                color: .purple,
                title: "Formality",
                value: formalityLabel,
                note: "Learned from your speaking patterns"
            )

            // Top filler words
            if !profile.fillerWordFrequency.isEmpty {
                let top = profile.fillerWordFrequency.sorted { $0.value > $1.value }.prefix(3)
                VStack(alignment: .leading, spacing: 6) {
                    Label("Your filler words", systemImage: "bubble.left")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack {
                        ForEach(top, id: \.key) { filler, count in
                            Text("\"\(filler)\" ×\(count)")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Color.orange.opacity(0.12), in: Capsule())
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var languageSection: some View {
        Section("Language") {
            LabeledContent("Primary language") {
                Text(languageName(profile.detectedPrimaryLanguage))
                    .foregroundStyle(.secondary)
            }

            if let accent = profile.accentRegion {
                LabeledContent("Accent region") {
                    Text(accent).foregroundStyle(.secondary)
                }
            }

            if !profile.detectedSecondaryLanguages.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Code-switching detected")
                        .font(.subheadline)
                    Text("You switch between languages naturally. Lexora handles this automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(profile.detectedSecondaryLanguages, id: \.self) { lang in
                                Text(languageName(lang))
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // Vocabulary category breakdown — only when ≥ 5 words across ≥ 2 categories.
    private var vocabCategoryBreakdown: [(category: VocabularyCategory, count: Int)] {
        let grouped = Dictionary(grouping: profile.customVocabulary) { $0.category }
        return grouped
            .map { (category: $0.key, count: $0.value.count) }
            .filter { $0.count > 0 }
            .sorted { $0.count > $1.count }
    }

    private var vocabCategoryColors: [VocabularyCategory: Color] {
        let colors: [Color] = [.blue, .purple, .teal, .orange, .green, .red, .indigo, .pink]
        var map = [VocabularyCategory: Color]()
        for (i, cat) in VocabularyCategory.allCases.enumerated() {
            map[cat] = colors[i % colors.count]
        }
        return map
    }

    @ViewBuilder
    private var vocabularyCategoryChart: some View {
        let breakdown = vocabCategoryBreakdown
        let colorMap  = vocabCategoryColors
        if profile.customVocabulary.count >= 5, breakdown.count >= 2 {
            VStack(alignment: .leading, spacing: 8) {
                Label("By category", systemImage: "chart.bar.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Chart(breakdown, id: \.category) { item in
                    BarMark(
                        x: .value("Count", item.count),
                        y: .value("Category", item.category.rawValue.capitalized)
                    )
                    .foregroundStyle(colorMap[item.category] ?? Color.accentColor)
                    .cornerRadius(4)
                    .annotation(position: .trailing, alignment: .leading) {
                        Text("\(item.count)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks { v in
                        if let label = v.as(String.self) {
                            AxisValueLabel {
                                Text(label)
                                    .font(.system(size: 11))
                            }
                        }
                    }
                }
                .frame(height: CGFloat(breakdown.count) * 28 + 16)
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        }
    }

    private var vocabularySection: some View {
        Section {
            vocabularyCategoryChart

            // Category filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    categoryChip(nil, label: "All")
                    ForEach(VocabularyCategory.allCases, id: \.self) { cat in
                        categoryChip(cat, label: cat.rawValue)
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))

            if filteredVocabulary.isEmpty {
                TipView(addVocabTip)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                ContentUnavailableView(
                    "No vocabulary yet",
                    systemImage: "book.closed",
                    description: Text("Lexora learns new words automatically as you speak, or add them manually.")
                )
            } else {
                ForEach(filteredVocabulary) { entry in
                    VocabularyRowView(entry: entry)
                        .contextMenu {
                            // "Look Up" — shows native iOS dictionary if a definition exists
                            if UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: entry.term) {
                                Button {
                                    dictionaryTerm = entry.term
                                    showDictionarySheet = true
                                } label: {
                                    Label("Look Up \"\(entry.term)\"", systemImage: "character.book.closed")
                                }
                            }
                            // Find sessions that contain this word
                            NavigationLink {
                                HistoryListContent(initialSearch: entry.term)
                            } label: {
                                Label("Find in sessions", systemImage: "magnifyingglass")
                            }
                            Button {
                                UIPasteboard.general.string = entry.term
                            } label: {
                                Label("Copy term", systemImage: "doc.on.doc")
                            }
                            Button(role: .destructive) {
                                appState.deleteVocabularyEntry(id: entry.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                .onDelete { indexSet in
                    for i in indexSet {
                        appState.deleteVocabularyEntry(id: filteredVocabulary[i].id)
                    }
                }
                .onMove { from, to in
                    // Map filtered indices → raw array, reorder, then write back.
                    var raw = appState.learningEngine.profile.customVocabulary
                    let filteredIDs = filteredVocabulary.map { $0.id }
                    // Collect the IDs being moved in filtered order
                    let movedIDs = from.sorted().map { filteredIDs[$0] }
                    // Build reordered filtered ID list
                    var reorderedFiltered = filteredIDs
                    reorderedFiltered.move(fromOffsets: from, toOffset: to)
                    // Reconstruct raw array: replace slots that belong to filteredVocabulary
                    // in the new filtered order while leaving unfiltered items in place.
                    var filteredCursor = 0
                    for i in raw.indices {
                        if filteredIDs.contains(raw[i].id) {
                            let newID = reorderedFiltered[filteredCursor]
                            raw[i] = appState.learningEngine.profile.customVocabulary
                                .first(where: { $0.id == newID }) ?? raw[i]
                            filteredCursor += 1
                        }
                    }
                    appState.learningEngine.profile.customVocabulary = raw
                    appState.storage.save(appState.learningEngine.profile)
                    _ = movedIDs  // suppress unused-variable warning
                }
            }
        } header: {
            HStack {
                Text("Learned vocabulary (\(profile.customVocabulary.count))")
                Spacer()
                if profile.customVocabulary.count >= 3 {
                    Button {
                        showStudyMode = true
                    } label: {
                        Image(systemName: "rectangle.on.rectangle.angled")
                            .font(.caption)
                            .foregroundStyle(Color.purple)
                    }
                    .buttonStyle(.plain)
                }
                if !appState.sessions.isEmpty {
                    Button {
                        smartLearnSuggestions = buildSmartLearnSuggestions()
                        if !smartLearnSuggestions.isEmpty { showSmartLearnSheet = true }
                    } label: {
                        Label("Smart learn", systemImage: "sparkles")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(isPresented: $showSmartLearnSheet) {
            SmartLearnSheet(suggestions: smartLearnSuggestions)
        }
        .sheet(isPresented: $showStudyMode) {
            VocabularyStudyView(vocabulary: filteredVocabulary.filter { $0.phonetic != nil || !$0.aliases.isEmpty })
                .environment(appState)
        }
    }

    /// Scans recent transcripts using NLTagger to find proper nouns not yet in vocabulary.
    private func buildSmartLearnSuggestions() -> [String] {
        let existingTerms = Set(profile.customVocabulary.map { $0.term.lowercased() })
        let recentText = appState.sessions.prefix(20)
            .map { $0.finalTranscript }
            .joined(separator: " ")

        guard !recentText.isEmpty else { return [] }

        var candidates: [String: Int] = [:]
        let tagger = NLTagger(tagSchemes: [.nameType, .lexicalClass])
        tagger.string = recentText

        let range = recentText.startIndex..<recentText.endIndex
        tagger.enumerateTags(in: range, unit: .word, scheme: .nameType) { tag, tokenRange in
            guard let tag else { return true }
            guard tag == .personalName || tag == .organizationName || tag == .placeName else { return true }
            let word = String(recentText[tokenRange])
            guard word.count >= 3,
                  !word.lowercased().contains("'s"),
                  !existingTerms.contains(word.lowercased()),
                  word.first?.isUppercase == true else { return true }
            candidates[word, default: 0] += 1
            return true
        }

        return candidates
            .filter { $0.value >= 2 }           // must appear at least twice
            .sorted { $0.value > $1.value }      // most frequent first
            .prefix(20)
            .map { $0.key }
    }

    private var correctionsSection: some View {
        let recent = Array(profile.correctionHistory.suffix(8).reversed())
        return Section {
            if profile.correctionHistory.isEmpty {
                Text("No corrections yet. Edit transcripts to teach Lexora.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recent) { event in
                    correctionRow(event)
                }
                .onDelete { indexSet in
                    // Map visible-list indices back to the full correctionHistory indices
                    let allCount = profile.correctionHistory.count
                    let offset = allCount - min(8, allCount)
                    let toRemove = indexSet.map { allCount - 1 - $0 }   // reversed suffix
                    for i in toRemove.sorted(by: >) {
                        if i >= offset { appState.profile.correctionHistory.remove(at: i) }
                    }
                    appState.storage.save(appState.profile)
                }

                if profile.correctionHistory.count > 8 {
                    NavigationLink {
                        AllCorrectionsView()
                    } label: {
                        Text("See all \(profile.correctionHistory.count) corrections…")
                            .font(.subheadline)
                            .foregroundStyle(Color.accentColor)
                    }
                }

                Button(role: .destructive) {
                    appState.profile.correctionHistory.removeAll()
                    appState.storage.save(appState.profile)
                } label: {
                    Label("Clear correction history", systemImage: "trash")
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("Recent corrections (\(profile.correctionHistory.count))")
        } footer: {
            Text("Each correction teaches Lexora your preferred phrasing. Swipe left to delete a specific entry.")
        }
    }

    private func correctionRow(_ event: CorrectionEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(event.originalText.prefix(40))
                    .strikethrough()
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .lineLimit(1)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(event.correctedText.prefix(40))
                    .font(.subheadline)
                    .lineLimit(1)
            }
            Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Contact import

    private func importFromContacts() {
        let store = CNContactStore()
        store.requestAccess(for: .contacts) { granted, error in
            guard granted else {
                DispatchQueue.main.async {
                    contactImportStatus = "Contacts access was not granted. Enable it in Settings → Privacy → Contacts."
                    showImportContacts = true
                }
                return
            }

            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey,
                        CNContactNicknameKey, CNContactOrganizationNameKey] as [CNKeyDescriptor]
            let request = CNContactFetchRequest(keysToFetch: keys)
            var importedNames: [String] = []
            let existingTerms = Set(appState.profile.customVocabulary.map { $0.term.lowercased() })

            do {
                try store.enumerateContacts(with: request) { contact, _ in
                    let parts = [contact.givenName, contact.familyName,
                                 contact.nickname, contact.organizationName]
                        .filter { !$0.isEmpty }
                    for name in parts {
                        guard !name.isEmpty, !existingTerms.contains(name.lowercased()) else { continue }
                        importedNames.append(name)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    contactImportStatus = "Could not read contacts: \(error.localizedDescription)"
                    showImportContacts = true
                }
                return
            }

            DispatchQueue.main.async {
                var addedCount = 0
                for name in importedNames {
                    let entry = VocabularyEntry(
                        term: name,
                        phonetic: nil,
                        aliases: [],
                        category: .name,
                        language: appState.profile.detectedPrimaryLanguage,
                        source: .importedFromContacts
                    )
                    appState.addVocabularyEntry(entry)
                    addedCount += 1
                }
                contactImportStatus = addedCount == 0
                    ? "All contact names are already in your vocabulary."
                    : "Added \(addedCount) name\(addedCount == 1 ? "" : "s") from Contacts."
                showImportContacts = true
            }
        }
    }

    // MARK: - Vocabulary CSV Export

    private func exportVocabularyCSV() {
        let vocab = profile.customVocabulary
        var lines: [String] = ["term,phonetic,aliases,category,source,usageCount,relevanceScore,language,addedAt"]

        for entry in vocab {
            let phonetic  = entry.phonetic ?? ""
            let aliases   = entry.aliases.joined(separator: ";")
            let category  = entry.category.rawValue
            let source    = entry.source.rawValue
            let usage     = String(entry.usageCount)
            let score     = String(format: "%.2f", entry.relevanceScore)
            let language  = entry.language ?? ""
            let addedStr  = ISO8601DateFormatter().string(from: entry.addedAt)
            // CSV-escape a field: wrap in quotes if it contains commas/quotes
            func esc(_ s: String) -> String {
                s.contains(",") || s.contains("\"")
                    ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
                    : s
            }
            lines.append([esc(entry.term), esc(phonetic), esc(aliases),
                          esc(category), esc(source), usage, score,
                          esc(language), addedStr].joined(separator: ","))
        }

        let csv = lines.joined(separator: "\n")
        let stamp = Date().formatted(.dateTime.year().month().day())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lexora_vocabulary_\(stamp).csv")
        guard (try? csv.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        vocabExportItems = [url]
        showVocabExportSheet = true
    }

    /// Exports vocabulary as Anki-importable tab-separated values.
    /// Anki tab-separated format: Front[TAB]Back[TAB]Tags
    /// Front = term (+ phonetic if available)
    /// Back  = category, aliases, usage count
    /// Tags  = category name for Anki deck organisation
    private func exportVocabularyAnki() {
        var lines: [String] = []
        // Anki TSV header comment (optional — Anki ignores lines starting with #)
        lines.append("#separator:tab")
        lines.append("#html:false")
        lines.append("#notetype:Basic")

        for entry in profile.customVocabulary {
            // Front card: term and optional phonetic pronunciation
            var front = entry.term
            if let ph = entry.phonetic, !ph.isEmpty {
                front += " [\(ph)]"
            }

            // Back card: category, aliases, and a usage note
            var backParts: [String] = [entry.category.rawValue.capitalized]
            if !entry.aliases.isEmpty {
                backParts.append("Also: " + entry.aliases.joined(separator: ", "))
            }
            if entry.usageCount > 0 {
                backParts.append("Used \(entry.usageCount) time\(entry.usageCount == 1 ? "" : "s") in transcripts")
            }
            let back = backParts.joined(separator: "\n")

            // Tags for deck organisation (Anki uses spaces as delimiters, spaces within tags → underscores)
            let tag = "Lexora::" + entry.category.rawValue
                .replacingOccurrences(of: " ", with: "_")

            // Escape tabs within fields
            func esc(_ s: String) -> String { s.replacingOccurrences(of: "\t", with: " ") }
            lines.append([esc(front), esc(back), tag].joined(separator: "\t"))
        }

        let tsv = lines.joined(separator: "\n")
        let stamp = Date().formatted(.dateTime.year().month().day())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lexora_vocabulary_anki_\(stamp).txt")
        guard (try? tsv.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        vocabExportItems = [url]
        showVocabExportSheet = true
    }

    // MARK: - Session stats

    private var sessionStatsSection: some View {
        let sessions = appState.sessions
        let totalWords = sessions.reduce(0) { $0 + $1.wordCount }
        let avgWords = sessions.isEmpty ? 0 : totalWords / sessions.count
        let avgDuration = sessions.isEmpty ? 0.0 : sessions.reduce(0.0) { $0 + $1.durationSeconds } / Double(sessions.count)
        let streak = currentRecordingStreak(sessions)
        let gStreak = goalStreak(sessions, goal: profile.dailyWordGoal)

        // Personal records
        let bestWPM = sessions.filter { $0.paceWPM > 0 }.max(by: { $0.paceWPM < $1.paceWPM })?.paceWPM ?? 0
        let bestSingleSessionWords = sessions.map { $0.wordCount }.max() ?? 0
        let cal = Calendar.current
        // Most words in a single calendar day
        let byDay = Dictionary(grouping: sessions) { cal.startOfDay(for: $0.startedAt) }
        let bestDayWords = byDay.values.map { $0.reduce(0) { $0 + $1.wordCount } }.max() ?? 0

        return Section("Session stats") {
            HStack(spacing: 0) {
                statPill(value: "\(sessions.count)", label: "Sessions")
                Divider().frame(height: 32)
                statPill(value: "\(totalWords)", label: "Total words")
                Divider().frame(height: 32)
                statPill(value: "\(avgWords)", label: "Avg words")
                Divider().frame(height: 32)
                statPill(value: "\(streak)d", label: "Streak")
                if gStreak > 0 {
                    Divider().frame(height: 32)
                    statPill(value: "\(gStreak)d 🎯", label: "Goal streak")
                }
            }
            .padding(.vertical, 4)

            if avgDuration > 0 {
                insightRow(
                    icon: "timer",
                    color: .teal,
                    title: "Avg session length",
                    value: formatDuration(avgDuration),
                    note: nil
                )
            }

            if bestWPM > 0 {
                insightRow(
                    icon: "gauge.with.needle.fill",
                    color: .orange,
                    title: "Best pace",
                    value: "\(Int(bestWPM)) WPM",
                    note: "Your fastest single-session speaking rate"
                )
            }

            if bestSingleSessionWords > 0 {
                insightRow(
                    icon: "text.word.spacing",
                    color: .blue,
                    title: "Best single session",
                    value: "\(bestSingleSessionWords) words",
                    note: nil
                )
            }

            if bestDayWords > 0 {
                insightRow(
                    icon: "star.fill",
                    color: .yellow,
                    title: "Best day",
                    value: "\(bestDayWords) words",
                    note: "Most words dictated in one calendar day"
                )
            }

            let totalMins = profile.totalTranscriptionMinutes
            if totalMins >= 1 {
                let totalHours = totalMins / 60.0
                let timeValue = totalHours >= 1.0
                    ? String(format: "%.1f hrs", totalHours)
                    : "\(Int(totalMins)) min"
                insightRow(
                    icon: "clock.fill",
                    color: .green,
                    title: "Total recorded time",
                    value: timeValue,
                    note: "Lifetime speaking time across all sessions"
                )
            }

            if totalWords >= 250 {
                let readMins = Double(totalWords) / 250.0
                let readValue = readMins >= 60
                    ? String(format: "%.1f hrs", readMins / 60.0)
                    : "\(Int(ceil(readMins))) min"
                insightRow(
                    icon: "book.pages.fill",
                    color: .brown,
                    title: "Equivalent reading time",
                    value: readValue,
                    note: "Time to read all your transcripts at 250 wpm"
                )
            }

            // Vocabulary library size
            let vocabCount = profile.customVocabulary.count
            if vocabCount > 0 {
                let autoCount = profile.customVocabulary.filter { $0.source == .autoDetected }.count
                let lastAdded = profile.customVocabulary.compactMap { $0.addedAt }.max()
                let lastNote: String? = lastAdded.map { date in
                    let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
                    if days == 0 { return "last word added today" }
                    if days == 1 { return "last word added yesterday" }
                    return "last word added \(days) days ago"
                }
                insightRow(
                    icon: "text.book.closed.fill",
                    color: .purple,
                    title: "Vocabulary library",
                    value: "\(vocabCount) terms",
                    note: lastNote ?? ("\(autoCount) auto-detected")
                )
            }

            // Correction accuracy trend
            let correctionCount = profile.phonemeSubstitutions.count
            if correctionCount > 0 {
                insightRow(
                    icon: "wand.and.rays",
                    color: .cyan,
                    title: "Auto-corrections active",
                    value: "\(correctionCount) rule\(correctionCount == 1 ? "" : "s")",
                    note: "Applied automatically to future transcripts"
                )
            }

            // Vocabulary activity this week
            let cal = Calendar.current
            let newThisWeek = profile.customVocabulary.filter {
                (cal.dateComponents([.day], from: $0.addedAt, to: Date()).day ?? 99) <= 7
            }.count
            let usedThisWeek = profile.customVocabulary.filter {
                guard let used = $0.lastUsed else { return false }
                return (cal.dateComponents([.day], from: used, to: Date()).day ?? 99) <= 7
            }.count
            if newThisWeek > 0 || usedThisWeek > 0 {
                insightRow(
                    icon: "chart.line.uptrend.xyaxis",
                    color: .teal,
                    title: "Vocabulary activity",
                    value: "+\(newThisWeek) this week",
                    note: "\(usedThisWeek) term\(usedThisWeek == 1 ? "" : "s") recognised in the last 7 days"
                )
            }
        }
    }

    private func statPill(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func currentRecordingStreak(_ sessions: [TranscriptionSession]) -> Int {
        guard !sessions.isEmpty else { return 0 }
        let cal = Calendar.current
        var streak = 0
        var checkDate = Date()
        let sortedDates = Set(sessions.map { cal.startOfDay(for: $0.startedAt) })
        while sortedDates.contains(cal.startOfDay(for: checkDate)) {
            streak += 1
            checkDate = cal.date(byAdding: .day, value: -1, to: checkDate) ?? checkDate
        }
        return streak
    }

    /// Consecutive days on which today's word goal was met (requires dailyWordGoal > 0).
    private func goalStreak(_ sessions: [TranscriptionSession], goal: Int) -> Int {
        guard goal > 0, !sessions.isEmpty else { return 0 }
        let cal = Calendar.current
        let byDay = Dictionary(grouping: sessions) { cal.startOfDay(for: $0.startedAt) }
        var streak = 0
        var checkDate = cal.startOfDay(for: Date())
        while true {
            let dayTotal = byDay[checkDate]?.reduce(0) { $0 + $1.wordCount } ?? 0
            if dayTotal >= goal {
                streak += 1
                guard let prev = cal.date(byAdding: .day, value: -1, to: checkDate) else { break }
                checkDate = prev
            } else {
                break
            }
        }
        return streak
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        return "\(Int(seconds / 60))m \(Int(seconds.truncatingRemainder(dividingBy: 60)))s"
    }

    // MARK: - Context profiles

    @ViewBuilder
    private var contextProfilesSection: some View {
        let profiles = profile.contextProfiles
        Section {
            ForEach(profiles) { ctx in
                HStack(spacing: 12) {
                    Image(systemName: contextIcon(ctx.name))
                        .foregroundStyle(ctx.isActive ? Color.accentColor : .secondary)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(ctx.name).font(.subheadline)
                        if !ctx.bundleIDs.isEmpty {
                            Text("\(ctx.bundleIDs.count) app(s) linked")
                                .font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Text("General").font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { ctx.isActive },
                        set: { newVal in
                            if let i = appState.profile.contextProfiles.firstIndex(where: { $0.id == ctx.id }) {
                                appState.profile.contextProfiles[i].isActive = newVal
                            }
                        }
                    ))
                    .labelsHidden()
                }
            }
            .onDelete { indexSet in
                appState.profile.contextProfiles.remove(atOffsets: indexSet)
            }

            Button {
                showAddContextProfile = true
            } label: {
                Label("Add context profile", systemImage: "plus.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        } header: {
            Text("Context profiles")
        } footer: {
            Text("Context profiles let Lexora adjust its vocabulary and formality based on which app you're dictating into.")
        }
        .sheet(isPresented: $showAddContextProfile) {
            AddContextProfileView()
        }
    }

    private func contextIcon(_ name: String) -> String {
        switch name.lowercased() {
        case "work": return "briefcase.fill"
        case "messages": return "message.fill"
        case "notes": return "note.text"
        case "email": return "envelope.fill"
        default: return "square.grid.2x2.fill"
        }
    }

    // MARK: - Helpers

    private func insightRow(icon: String, color: Color, title: String, value: String, note: String?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.title3)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                if let note = note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func categoryChip(_ category: VocabularyCategory?, label: String) -> some View {
        let selected = selectedCategory == category
        return Button {
            selectedCategory = selected ? nil : category
        } label: {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? Color.accentColor : Color(.systemGray5), in: Capsule())
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private var paceDescription: String {
        let wpm = profile.averageSpeakingPaceWPM
        switch wpm {
        case 0..<100: return "Slow and deliberate"
        case 100..<130: return "Conversational pace"
        case 130..<160: return "Average speaking pace"
        case 160..<200: return "Fast speaker"
        default: return "Very fast speaker"
        }
    }

    private var formalityLabel: String {
        switch profile.formalityScore {
        case 0..<0.35: return "Casual"
        case 0.35..<0.65: return "Balanced"
        default: return "Formal"
        }
    }

    private func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
    }
}

struct VocabularyRowView: View {
    var entry: VocabularyEntry
    @State private var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.category.icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.term).font(.subheadline)
                    if let phonetic = entry.phonetic, !phonetic.isEmpty {
                        Text("/\(phonetic)/")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .italic()
                    }
                    // Speak button — appears on every row, uses language BCP-47
                    Button {
                        let utterance = AVSpeechUtterance(string: entry.term)
                        utterance.voice = AVSpeechSynthesisVoice(language: entry.language)
                        utterance.rate = 0.45
                        synthesizer.speak(utterance)
                        isSpeaking = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { isSpeaking = false }
                    } label: {
                        Image(systemName: isSpeaking ? "speaker.wave.2.fill" : "speaker.wave.1")
                            .font(.caption2)
                            .foregroundStyle(isSpeaking ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 6) {
                    Text(entry.category.rawValue)
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("·")
                    Text(entry.source.rawValue)
                        .font(.caption2).foregroundStyle(.secondary)
                    if entry.usageCount > 0 {
                        Text("·")
                        Text("used \(entry.usageCount)×")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    if !entry.aliases.isEmpty {
                        Text("·")
                        Text("\(entry.aliases.count) alias\(entry.aliases.count == 1 ? "" : "es")")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                // Relevance bar
                RelevanceBar(score: entry.relevanceScore)
                // Confidence score badge (only when non-trivial)
                if entry.relevanceScore > 0 {
                    let color: Color = entry.relevanceScore > 0.7 ? .green : entry.relevanceScore > 0.4 ? .orange : .red
                    Text("\(Int(entry.relevanceScore * 100))%")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(color.opacity(0.12), in: Capsule())
                }
                // Activity trend badge
                ActivityBadge(entry: entry)
            }
        }
    }
}

struct RelevanceBar: View {
    var score: Double
    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color(.systemGray5))
            .frame(width: 40, height: 4)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor)
                    .frame(width: 40 * score)
            }
    }
    private var barColor: Color {
        score > 0.7 ? .green : score > 0.4 ? .orange : .red
    }
}

/// Shows a compact activity badge: "NEW", "↑ Active", or "↓ Stale" based on
/// when the vocabulary entry was added and when it was last matched.
struct ActivityBadge: View {
    var entry: VocabularyEntry

    private enum Badge {
        case new, active, cooling, stale
        var label: String {
            switch self {
            case .new:     return "NEW"
            case .active:  return "↑ Active"
            case .cooling: return "~"
            case .stale:   return "↓ Stale"
            }
        }
        var color: Color {
            switch self {
            case .new:     return .blue
            case .active:  return .green
            case .cooling: return .secondary
            case .stale:   return .secondary
            }
        }
    }

    private var badge: Badge? {
        let cal = Calendar.current
        let now = Date()
        // "New" if added within the last 7 days
        let daysAdded = cal.dateComponents([.day], from: entry.addedAt, to: now).day ?? 99
        if daysAdded <= 7 { return .new }

        // Activity based on lastUsed
        if let used = entry.lastUsed {
            let days = cal.dateComponents([.day], from: used, to: now).day ?? 999
            if days <= 7  { return .active }
            if days <= 30 { return .cooling }
            if entry.usageCount > 0 { return .stale }
        } else if entry.usageCount == 0, daysAdded > 14 {
            // Never recognised and entry is old
            return .stale
        }
        return nil
    }

    var body: some View {
        if let b = badge, b != .cooling {
            Text(b.label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(b == .new ? Color.white : b.color)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(b == .new ? b.color : b.color.opacity(0.12), in: Capsule())
        }
    }
}

// MARK: - Add Context Profile

struct AddContextProfileView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var formality: FormalityMode = .adaptive

    private let presetNames = ["Work", "Messages", "Email", "Notes", "Medical", "Legal", "Technical"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile name") {
                    TextField("e.g. Work, Medical, Podcast", text: $name)
                        .autocorrectionDisabled()

                    // Quick presets
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(presetNames, id: \.self) { preset in
                                Button {
                                    name = preset
                                } label: {
                                    Text(preset)
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .background(name == preset ? Color.accentColor : Color(.systemGray5),
                                                    in: Capsule())
                                        .foregroundStyle(name == preset ? Color.white : Color.primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }

                Section("Formality") {
                    Picker("Output formality", selection: $formality) {
                        ForEach(FormalityMode.allCases, id: \.self) { mode in
                            VStack(alignment: .leading) {
                                Text(mode.rawValue)
                                Text(mode.description).font(.caption).foregroundStyle(.secondary)
                            }.tag(mode)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                Section {
                    Text("You can add specific vocabulary to this profile after creating it by editing your vocabulary list and assigning words to this context.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New Context Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        var ctx = ContextProfile(
                            name: name.trimmingCharacters(in: .whitespaces),
                            bundleIDs: []
                        )
                        ctx.formalityOverride = formality
                        appState.profile.contextProfiles.append(ctx)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Add Vocabulary

struct AddVocabularyView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var term = ""
    @State private var phonetic = ""
    @State private var aliases = ""
    @State private var category: VocabularyCategory = .other

    var body: some View {
        NavigationStack {
            Form {
                Section("Word or phrase") {
                    TextField("e.g. Olakunle, DeepSeek, Yoruba", text: $term)
                    TextField("Phonetic hint (optional)", text: $phonetic)
                }
                Section("Category") {
                    Picker("Category", selection: $category) {
                        ForEach(VocabularyCategory.allCases, id: \.self) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .pickerStyle(.wheel)
                }
                Section("Alternate spellings (comma-separated)") {
                    TextField("e.g. olakunle, OLAKUNLE", text: $aliases)
                }
            }
            .navigationTitle("Add Vocabulary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let entry = VocabularyEntry(
                            term: term.trimmingCharacters(in: .whitespaces),
                            phonetic: phonetic.isEmpty ? nil : phonetic,
                            aliases: aliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                            category: category,
                            language: appState.profile.detectedPrimaryLanguage,
                            source: .userAdded
                        )
                        appState.addVocabularyEntry(entry)
                        dismiss()
                    }
                    .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Native dictionary lookup

/// Wraps UIReferenceLibraryViewController so SwiftUI can present it inside a sheet.
struct DictionaryLookupView: UIViewControllerRepresentable {
    let term: String

    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController {
        UIReferenceLibraryViewController(term: term)
    }

    func updateUIViewController(_ uiViewController: UIReferenceLibraryViewController, context: Context) {}
}

// MARK: - All Corrections fullscreen list

struct AllCorrectionsView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""

    private var filtered: [CorrectionEvent] {
        let all = appState.profile.correctionHistory.reversed()
        guard !searchText.isEmpty else { return Array(all) }
        return all.filter {
            $0.originalText.localizedCaseInsensitiveContains(searchText)
            || $0.correctedText.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        List {
            ForEach(filtered) { event in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(event.originalText)
                            .strikethrough()
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                            .lineLimit(2)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(event.correctedText)
                            .font(.subheadline)
                            .lineLimit(2)
                    }
                    Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            }
            .onDelete { indexSet in
                // filtered may differ from full array, so map by ID
                let idsToRemove = Set(indexSet.map { filtered[$0].id })
                appState.profile.correctionHistory.removeAll { idsToRemove.contains($0.id) }
                appState.storage.save(appState.profile)
            }
        }
        .searchable(text: $searchText, prompt: "Search corrections")
        .navigationTitle("Correction history")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            EditButton()
            Button(role: .destructive) {
                appState.profile.correctionHistory.removeAll()
                appState.storage.save(appState.profile)
            } label: {
                Image(systemName: "trash")
            }
            .tint(.red)
        }
    }
}

// MARK: - Smart Learn Sheet

/// Shows a list of candidate vocabulary words extracted from recent transcripts.
/// The user can accept all, accept individual words, or dismiss.
struct SmartLearnSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var suggestions: [String]

    @State private var selected: Set<String>
    @State private var categoryForAll: VocabularyCategory = .other

    init(suggestions: [String]) {
        self.suggestions = suggestions
        self._selected = State(initialValue: Set(suggestions))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("These words appear frequently in your recent recordings but aren't in your vocabulary yet. Select the ones you'd like Lexora to learn.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)

                    Picker("Category for new words", selection: $categoryForAll) {
                        ForEach(VocabularyCategory.allCases, id: \.self) { cat in
                            Text(cat.rawValue).tag(cat)
                        }
                    }
                }

                Section("\(selected.count) selected of \(suggestions.count)") {
                    ForEach(suggestions, id: \.self) { word in
                        Button {
                            if selected.contains(word) { selected.remove(word) }
                            else { selected.insert(word) }
                        } label: {
                            HStack {
                                Image(systemName: selected.contains(word)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(word)
                                                     ? Color.accentColor : Color.secondary)
                                Text(word)
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Smart Learn")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(selected.count == suggestions.count ? "Deselect all" : "Select all") {
                        if selected.count == suggestions.count {
                            selected = []
                        } else {
                            selected = Set(suggestions)
                        }
                    }
                    .font(.subheadline)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(selected.count)") { addSelected() }
                        .disabled(selected.isEmpty)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func addSelected() {
        let existingTerms = Set(appState.profile.customVocabulary.map { $0.term.lowercased() })
        for word in selected where !existingTerms.contains(word.lowercased()) {
            var entry = VocabularyEntry(
                term: word,
                phonetic: nil,
                aliases: [],
                category: categoryForAll,
                language: appState.profile.detectedPrimaryLanguage,
                source: .autoDetected,
                relevanceScore: 0.7
            )
            entry.addedAt = Date()
            appState.addVocabularyEntry(entry)
        }
        dismiss()
    }
}

// MARK: - Bulk Paste Import

struct BulkPasteImportView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Binding var pasteText: String

    @State private var selectedCategory: VocabularyCategory = .other
    @State private var parsedWords: [String] = []
    @State private var excluded: Set<String> = []

    private var wordsToAdd: [String] {
        let existing = Set(appState.profile.customVocabulary.map { $0.term.lowercased() })
        return parsedWords.filter { !excluded.contains($0) && !existing.contains($0.lowercased()) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $pasteText)
                        .frame(minHeight: 100, maxHeight: 200)
                        .onChange(of: pasteText) { _, _ in parseWords() }
                } header: {
                    Text("Paste words (one per line, or comma-separated)")
                } footer: {
                    Text("Duplicate and existing vocabulary entries will be skipped automatically.")
                }

                if !parsedWords.isEmpty {
                    Section {
                        Picker("Category", selection: $selectedCategory) {
                            ForEach(VocabularyCategory.allCases, id: \.self) { cat in
                                Text(cat.rawValue).tag(cat)
                            }
                        }
                    }

                    Section("\(wordsToAdd.count) new words to add") {
                        ForEach(parsedWords, id: \.self) { word in
                            let existing = appState.profile.customVocabulary.map { $0.term.lowercased() }.contains(word.lowercased())
                            HStack {
                                Image(systemName: excluded.contains(word) ? "circle" : (existing ? "checkmark.circle.fill" : "checkmark.circle.fill"))
                                    .foregroundStyle(existing ? Color.secondary : (excluded.contains(word) ? Color.secondary : Color.green))
                                Text(word)
                                    .foregroundStyle(existing || excluded.contains(word) ? .secondary : .primary)
                                Spacer()
                                if existing {
                                    Text("Already exists")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if !existing {
                                    if excluded.contains(word) { excluded.remove(word) }
                                    else { excluded.insert(word) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Paste Word List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(wordsToAdd.count)") { addWords() }
                        .disabled(wordsToAdd.isEmpty)
                        .fontWeight(.semibold)
                }
            }
            .onAppear { parseWords() }
        }
    }

    private func parseWords() {
        let raw = pasteText
            .components(separatedBy: CharacterSet(charactersIn: "\n,;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
        // Deduplicate while preserving order
        var seen = Set<String>()
        parsedWords = raw.filter { seen.insert($0.lowercased()).inserted }
    }

    private func addWords() {
        let lang = appState.profile.detectedPrimaryLanguage
        for word in wordsToAdd {
            let entry = VocabularyEntry(
                term: word,
                phonetic: nil,
                aliases: [],
                category: selectedCategory,
                language: lang,
                source: .userAdded,
                relevanceScore: 1.0
            )
            appState.addVocabularyEntry(entry)
        }
        dismiss()
    }
}

// MARK: - Vocabulary Study Mode

struct VocabularyStudyView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var vocabulary: [VocabularyEntry]

    @State private var deck: [VocabularyEntry] = []
    @State private var currentIndex = 0
    @State private var isFlipped = false
    @State private var correctCount = 0
    @State private var sessionDone = false
    @State private var rotation: Double = 0

    var body: some View {
        NavigationStack {
            Group {
                if vocabulary.isEmpty {
                    ContentUnavailableView(
                        "No entries to study",
                        systemImage: "rectangle.on.rectangle.angled",
                        description: Text("Add phonetic hints or aliases to vocabulary entries to unlock Study Mode.")
                    )
                } else if sessionDone {
                    summaryView
                } else {
                    studyCardView
                }
            }
            .navigationTitle("Study Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if !sessionDone && !deck.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Text("\(currentIndex + 1) of \(deck.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onAppear {
                deck = vocabulary.shuffled()
            }
        }
    }

    private var studyCardView: some View {
        VStack(spacing: 32) {
            // Progress bar
            ProgressView(value: Double(currentIndex), total: Double(deck.count))
                .padding(.horizontal)

            Spacer()

            // Flashcard
            ZStack {
                // Front face (term)
                cardFace(isBack: false)
                    .opacity(rotation < 90 ? 1 : 0)
                // Back face (details)
                cardFace(isBack: true)
                    .opacity(rotation >= 90 ? 1 : 0)
                    .scaleEffect(x: -1)
            }
            .rotation3DEffect(.degrees(rotation), axis: (x: 0, y: 1, z: 0))
            .onTapGesture { flip() }

            Text(isFlipped ? "Mark your recall below" : "Tap card to reveal")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            // Action buttons (visible after flip)
            if isFlipped {
                HStack(spacing: 20) {
                    Button {
                        advance(correct: false)
                    } label: {
                        Label("Miss", systemImage: "xmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red.gradient, in: RoundedRectangle(cornerRadius: 14))
                    }
                    Button {
                        advance(correct: true)
                        appState.recordVocabularyUsage(id: deck[currentIndex].id)
                    } label: {
                        Label("Got it", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green.gradient, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(.horizontal)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: isFlipped)
        .padding(.bottom, 24)
    }

    private func cardFace(isBack: Bool) -> some View {
        let entry = deck.isEmpty ? nil : deck[currentIndex]
        return VStack(spacing: 16) {
            if !isBack {
                // Front: term + category
                VStack(spacing: 8) {
                    if let cat = entry?.category {
                        Label(cat.rawValue, systemImage: cat.icon)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(entry?.term ?? "")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                }
            } else {
                // Back: phonetic + aliases + usage count
                VStack(spacing: 12) {
                    Text(entry?.term ?? "")
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    if let phonetic = entry?.phonetic, !phonetic.isEmpty {
                        Text("/" + phonetic + "/")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .italic()
                    }
                    if let aliases = entry?.aliases, !aliases.isEmpty {
                        Text("Also: " + aliases.joined(separator: ", "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let usage = entry?.usageCount, usage > 0 {
                        Label("Used \(usage) time\(usage == 1 ? "" : "s")", systemImage: "mic.fill")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .padding(24)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .padding(.horizontal, 24)
    }

    private func flip() {
        withAnimation(.interpolatingSpring(stiffness: 180, damping: 20)) {
            rotation = isFlipped ? 0 : 180
            isFlipped.toggle()
        }
    }

    private func advance(correct: Bool) {
        if correct { correctCount += 1 }
        withAnimation(.snappy) {
            if currentIndex < deck.count - 1 {
                currentIndex += 1
                rotation = 0
                isFlipped = false
            } else {
                sessionDone = true
            }
        }
    }

    private var summaryView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: correctCount == deck.count ? "trophy.fill" : "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(correctCount == deck.count ? Color.yellow : Color.green)
                .symbolEffect(.bounce)

            Text("Session complete!")
                .font(.title.weight(.bold))
            Text("\(correctCount) of \(deck.count) correct")
                .font(.title3)
                .foregroundStyle(.secondary)

            if correctCount < deck.count {
                Text("Study the missed entries and try again to reinforce them.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Spacer()
            Button {
                // Restart with missed entries only
                let missed = deck.filter { _ in true } // restart all for now
                deck = missed.shuffled()
                currentIndex = 0
                correctCount = 0
                sessionDone = false
                rotation = 0
                isFlipped = false
            } label: {
                Label("Study again", systemImage: "arrow.clockwise")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal)
            Button("Done") { dismiss() }
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 32)
    }
}

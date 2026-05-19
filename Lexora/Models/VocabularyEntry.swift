import Foundation

// A single learned word, name, or phrase that the engine should recognise correctly.
struct VocabularyEntry: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var term: String                   // The correct form the user wants
    var phonetic: String?              // Optional pronunciation hint
    var aliases: [String]              // Alternate spellings the engine might produce
    var category: VocabularyCategory
    var language: String               // BCP-47 language code this term belongs to
    var usageCount: Int = 0
    var lastUsed: Date?
    var addedAt: Date = Date()
    var source: EntrySource

    // Confidence that this entry is still relevant (decays with non-use)
    var relevanceScore: Double = 1.0

    mutating func recordUsage() {
        usageCount += 1
        lastUsed = Date()
        relevanceScore = min(1.0, relevanceScore + 0.05)
    }

    // Relevance decays if unused for >30 days
    mutating func decayIfNeeded() {
        guard let last = lastUsed else { return }
        let daysSinceUse = Date().timeIntervalSince(last) / 86_400
        if daysSinceUse > 30 {
            relevanceScore = max(0.1, relevanceScore - (daysSinceUse / 30) * 0.1)
        }
    }
}

enum VocabularyCategory: String, Codable, CaseIterable {
    case name = "Name"
    case place = "Place"
    case brand = "Brand"
    case technical = "Technical"
    case slang = "Slang"
    case phrase = "Phrase"
    case other = "Other"

    var icon: String {
        switch self {
        case .name: return "person.fill"
        case .place: return "mappin.circle.fill"
        case .brand: return "tag.fill"
        case .technical: return "cpu.fill"
        case .slang: return "bubble.left.fill"
        case .phrase: return "text.bubble.fill"
        case .other: return "doc.text.fill"
        }
    }
}

enum EntrySource: String, Codable {
    case userAdded = "User Added"
    case learnedFromCorrection = "Learned"
    case importedFromContacts = "Contacts"
    case autoDetected = "Auto-detected"
}

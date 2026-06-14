import Foundation
import CloudKit
import Observation

// Handles all iCloud sync via CloudKit.
// - Profile (vocabulary, corrections, speaking model) syncs to private database
// - Session history syncs with optional per-session privacy control
// - Conflict resolution: last-write-wins on profile, append-only on sessions
@Observable @MainActor
final class CloudSyncService {

    var syncState: SyncState = .idle
    var lastSyncDate: Date?
    var pendingChanges: Int = 0

    private var _container: CKContainer?
    private var _privateDB: CKDatabase?
    private var changeToken: CKServerChangeToken?
    private let storage: ProfileStorage

    private let profileRecordType = "UserVoiceProfile"
    private let sessionRecordType = "TranscriptionSession"
    private let zoneID = CKRecordZone.ID(zoneName: "LexoraZone", ownerName: CKCurrentUserDefaultName)

    // Lazily resolved. Returns nil if iCloud is unavailable or entitlement is missing.
    private var privateDB: CKDatabase? {
        // ubiquityIdentityToken is nil when iCloud is signed out or entitlement is absent
        guard FileManager.default.ubiquityIdentityToken != nil else { return nil }
        if let db = _privateDB { return db }
        let c = CKContainer(identifier: "iCloud.com.yiga.Lexora")
        _container = c
        _privateDB = c.privateCloudDatabase
        return _privateDB
    }

    init(storage: ProfileStorage) {
        self.storage = storage
        // Do NOT touch CKContainer here — deferred to first sync attempt.
    }

    // MARK: - Setup

    func setupZoneIfNeeded() async {
        guard let db = privateDB else { return }
        let zone = CKRecordZone(zoneID: zoneID)
        do {
            _ = try await db.save(zone)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Zone already exists — that's fine
        } catch {
            setError(error.localizedDescription)
        }
    }

    // MARK: - Profile Sync

    func uploadProfile(_ profile: UserVoiceProfile) async {
        guard let db = privateDB else { syncState = .idle; return }
        syncState = .syncing
        do {
            let record = try profileToRecord(profile)
            _ = try await db.save(record)
            lastSyncDate = Date()
            syncState = .synced
        } catch {
            setError(error.localizedDescription)
        }
    }

    func downloadProfile() async -> UserVoiceProfile? {
        guard let db = privateDB else { syncState = .idle; return nil }
        syncState = .syncing
        let query = CKQuery(recordType: profileRecordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "lastUpdatedAt", ascending: false)]

        do {
            let results = try await db.records(matching: query,
                                               inZoneWith: zoneID,
                                               desiredKeys: nil,
                                               resultsLimit: 1)
            let records = results.matchResults.compactMap { try? $0.1.get() }
            let profile = try records.first.map { try profileFromRecord($0) }
            syncState = .synced
            lastSyncDate = Date()
            return profile
        } catch {
            setError(error.localizedDescription)
            return nil
        }
    }

    // MARK: - Session Sync

    func uploadSession(_ session: TranscriptionSession) async {
        guard let db = privateDB else { return }
        do {
            let record = try sessionToRecord(session)
            _ = try await db.save(record)
        } catch {
            // Non-fatal — session history upload failures are silent
        }
    }

    func fetchRecentSessions(limit: Int = 50) async -> [TranscriptionSession] {
        guard let db = privateDB else { return [] }
        let query = CKQuery(recordType: sessionRecordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: false)]

        do {
            let results = try await db.records(matching: query,
                                               inZoneWith: zoneID,
                                               desiredKeys: nil,
                                               resultsLimit: limit)
            return results.matchResults
                .compactMap { try? $0.1.get() }
                .compactMap { try? sessionFromRecord($0) }
        } catch {
            return []
        }
    }

    // MARK: - Incremental Sync (push/pull deltas)

    func syncChanges(profile: UserVoiceProfile) async -> UserVoiceProfile {
        guard syncState != .syncing else { return profile }
        syncState = .syncing
        var local = profile
        let remoteProfile = await downloadProfile()
        if let remote = remoteProfile, remote.lastUpdatedAt > local.lastUpdatedAt {
            mergeIntoLocal(remote: remote, local: &local)
        }
        await uploadProfile(local)
        pendingChanges = 0
        syncState = .synced
        lastSyncDate = Date()
        return local
    }

    // MARK: - Conflict Resolution

    // Merges remote profile into local and saves. Returns the merged result.
    @discardableResult
    func mergeIntoLocal(remote: UserVoiceProfile, local: inout UserVoiceProfile) -> UserVoiceProfile {
        let existingTerms = Set(local.customVocabulary.map { $0.term.lowercased() })
        let newEntries = remote.customVocabulary.filter { !existingTerms.contains($0.term.lowercased()) }
        local.customVocabulary.append(contentsOf: newEntries)

        let existingIDs = Set(local.correctionHistory.map { $0.id })
        let newCorrections = remote.correctionHistory.filter { !existingIDs.contains($0.id) }
        local.correctionHistory.append(contentsOf: newCorrections)

        for (key, value) in remote.phonemeSubstitutions { local.phonemeSubstitutions[key] = value }

        for lang in remote.detectedSecondaryLanguages where !local.detectedSecondaryLanguages.contains(lang) {
            local.detectedSecondaryLanguages.append(lang)
        }

        if remote.lastUpdatedAt > local.lastUpdatedAt {
            local.formalityScore = remote.formalityScore
            local.averageSpeakingPaceWPM = remote.averageSpeakingPaceWPM
            local.preferredOutputFormality = remote.preferredOutputFormality
            local.autoPunctuationEnabled = remote.autoPunctuationEnabled
            local.smartCorrectionEnabled = remote.smartCorrectionEnabled
        }

        local.touch()
        storage.save(local)
        return local
    }

    // MARK: - Account Status

    func checkAccountStatus() async -> CKAccountStatus {
        // Trigger the lazy init so _container is populated, then query it.
        _ = privateDB
        guard let c = _container else { return .noAccount }
        return (try? await c.accountStatus()) ?? .couldNotDetermine
    }

    // MARK: - Helpers

    private func profileToRecord(_ profile: UserVoiceProfile) throws -> CKRecord {
        let recordID = CKRecord.ID(recordName: profile.id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: profileRecordType, recordID: recordID)
        record["data"] = try JSONEncoder().encode(profile) as NSData
        record["displayName"] = profile.displayName as NSString
        record["lastUpdatedAt"] = profile.lastUpdatedAt as NSDate
        return record
    }

    private func profileFromRecord(_ record: CKRecord) throws -> UserVoiceProfile {
        guard let data = record["data"] as? Data else { throw SyncError.invalidRecord }
        return try JSONDecoder().decode(UserVoiceProfile.self, from: data)
    }

    private func sessionToRecord(_ session: TranscriptionSession) throws -> CKRecord {
        let recordID = CKRecord.ID(recordName: session.id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: sessionRecordType, recordID: recordID)
        record["data"] = try JSONEncoder().encode(session) as NSData
        record["startedAt"] = session.startedAt as NSDate
        record["primaryLanguage"] = session.primaryLanguage as NSString
        return record
    }

    private func sessionFromRecord(_ record: CKRecord) throws -> TranscriptionSession {
        guard let data = record["data"] as? Data else { throw SyncError.invalidRecord }
        return try JSONDecoder().decode(TranscriptionSession.self, from: data)
    }

    private func setError(_ message: String) {
        syncState = .error(message)
    }

    enum SyncError: Error {
        case invalidRecord
    }
}

enum SyncState: Equatable {
    case idle
    case syncing
    case synced
    case error(String)

    var label: String {
        switch self {
        case .idle: return "Not synced"
        case .syncing: return "Syncing…"
        case .synced: return "Synced to iCloud"
        case .error(let msg): return "Sync error: \(msg)"
        }
    }

        var iconName: String {
        switch self {
        case .idle: return "icloud.slash"
        case .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .synced: return "checkmark.icloud"
        case .error: return "exclamationmark.icloud"
        }
    }

    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

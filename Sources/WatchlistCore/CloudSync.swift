#if canImport(CloudKit)
import CloudKit
import Foundation
import os

// icloud sync, cloudkit side. sends sync_outbox to the private database and applies what other devices
// sent. CKSyncEngine handles scheduling, retries, push notifications and change tokens; its state is
// kept in meta so a relaunch picks up where it left off.

public final class CloudSync: CKSyncEngineDelegate, @unchecked Sendable {
    public static let containerID = "iCloud.io.github.jonathangarro.screenbook"
    static let zoneID = CKRecordZone.ID(zoneName: "Screenbook", ownerName: CKCurrentUserDefaultName)

    public struct Status: Sendable, Equatable {
        public var lastSynced: Date?
        public var pending: Int = 0
        public var problem: String?
        public init() {}
    }

    private let log = Logger(subsystem: "io.github.jonathangarro.screenbook", category: "sync")
    private let db: Database
    private let today: @Sendable () -> String
    private var engine: CKSyncEngine!
    private let lock = NSLock()
    private var _status = Status()

    /// called after changes from another device were written, with titles that arrived new
    public var onRemoteChange: (@Sendable ([Title]) -> Void)?
    public var onStatus: (@Sendable (Status) -> Void)?

    public var status: Status {
        lock.lock(); defer { lock.unlock() }
        return _status
    }

    /// true when this build is allowed to use icloud. dev builds without the entitlement skip sync
    /// instead of crashing in CloudKit.
    public static var isAvailable: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil)
        return value != nil
        #else
        return true
        #endif
    }

    /// Development or Production. dev builds and release builds talk to separate icloud databases.
    public static var environment: String {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-environment" as CFString, nil)
        else { return "Development" }
        return (value as? String) ?? (value as? [String])?.first ?? "Development"
        #elseif DEBUG
        return "Development"
        #else
        return "Production"
        #endif
    }

    public init(db: Database, today: @escaping @Sendable () -> String) {
        self.db = db
        self.today = today
        // what we know about one environment means nothing in the other: start over when it changes
        if (try? db.meta("sync_env")) != Self.environment {
            try? db.resetSyncState()
            try? db.setMeta("sync_env", Self.environment)
        }
        var saved: CKSyncEngine.State.Serialization?
        if let text = try? db.meta("sync_state"), let data = Data(base64Encoded: text) {
            saved = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        }
        let container = CKContainer(identifier: Self.containerID)
        let config = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                                                stateSerialization: saved, delegate: self)
        engine = CKSyncEngine(config)
    }

    /// queues everything the first time, then hands local changes to the engine
    public func start() {
        if (try? db.meta("sync_seeded")) == nil {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
            try? db.seedOutbox()
            try? db.setMeta("sync_seeded", "1")
        }
        pushLocalChanges()
    }

    /// moves new outbox entries into the engine, which sends them shortly after
    public func pushLocalChanges() {
        guard let entries = try? db.outbox() else { return }
        var adds: [CKSyncEngine.PendingRecordZoneChange] = []
        var removes: [CKSyncEngine.PendingRecordZoneChange] = []
        for e in entries {
            let id = Self.recordID(e.recordName)
            adds.append(e.isDelete ? .deleteRecord(id) : .saveRecord(id))
            removes.append(e.isDelete ? .saveRecord(id) : .deleteRecord(id))
        }
        engine.state.remove(pendingRecordZoneChanges: removes)
        engine.state.add(pendingRecordZoneChanges: adds)
        updateStatus { $0.pending = entries.count }
    }

    /// asks icloud for other devices' changes
    public func fetchNow() async {
        log.info("fetch requested")
        do {
            // ask for the zone itself: the database level summary can skip changes made from this mac,
            // and it costs the same single request
            try await engine.fetchChanges(.init(scope: .zoneIDs([Self.zoneID])))
            updateStatus { $0.lastSynced = Date(); if $0.problem != nil { $0.problem = nil } }
        } catch {
            log.error("fetch failed: \(error.localizedDescription, privacy: .public)")
            updateStatus { $0.problem = Self.describe(error) }
        }
    }

    /// fetches and sends right away instead of waiting for the engine's schedule
    public func syncNow() async {
        pushLocalChanges()
        do {
            try await engine.fetchChanges()
            try await engine.fetchChanges(.init(scope: .zoneIDs([Self.zoneID])))
            try await engine.sendChanges()
            updateStatus { $0.lastSynced = Date(); $0.problem = nil }
        } catch {
            updateStatus { $0.problem = Self.describe(error) }
        }
    }

    // records

    static func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    private func blankRecord(_ id: CKRecord.ID, type: String) -> CKRecord {
        if let data = try? db.systemFields(id.recordName), let coder = try? NSKeyedUnarchiver(forReadingFrom: data) {
            coder.requiresSecureCoding = true
            defer { coder.finishDecoding() }
            if let record = CKRecord(coder: coder), record.recordType == type { return record }
        }
        return CKRecord(recordType: type, recordID: id)
    }

    private func saveSystemFields(_ record: CKRecord) {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        try? db.setSystemFields(record.recordID.recordName, coder.encodedData)
    }

    /// the record to upload for a pending save, or nil when the row is gone (the engine then drops it)
    func record(for id: CKRecord.ID) -> CKRecord? {
        switch SyncName.parse(id.recordName) {
        case .title(let tmdbId, let type):
            guard let t = try? db.syncTitle(tmdbId, type) else { return nil }
            let r = blankRecord(id, type: "Title")
            r["tmdbId"] = t.tmdbId
            r["mediaType"] = t.mediaType.rawValue
            r["title"] = t.title
            r["year"] = t.year
            r["posterPath"] = t.posterPath
            r["regionReleaseDate"] = t.regionReleaseDate
            r["addedOn"] = t.addedOn
            r["watchedOn"] = t.watchedOn
            r["stoppedOn"] = t.stoppedOn
            r["allAvailable"] = t.allAvailable ? 1 : 0
            r["modifiedAt"] = t.modifiedAt
            return r
        case .episode(let tmdbId, let s, let e):
            guard let ep = try? db.syncEpisode(tmdbId, s, e) else { return nil }
            let r = blankRecord(id, type: "WatchedEpisode")
            r["tmdbId"] = ep.tmdbId
            r["season"] = ep.season
            r["episode"] = ep.episode
            r["watchedOn"] = ep.watchedOn
            return r
        case nil:
            return nil
        }
    }

    static func change(from r: CKRecord) -> RemoteChange? {
        switch r.recordType {
        case "Title":
            guard let id = r["tmdbId"] as? Int, let type = (r["mediaType"] as? String).flatMap(MediaType.init(rawValue:)) else { return nil }
            return .title(SyncTitle(
                tmdbId: id, mediaType: type, title: r["title"] as? String ?? "", year: r["year"] as? Int,
                posterPath: r["posterPath"] as? String, regionReleaseDate: r["regionReleaseDate"] as? String,
                addedOn: r["addedOn"] as? String ?? "", watchedOn: r["watchedOn"] as? String,
                stoppedOn: r["stoppedOn"] as? String, allAvailable: (r["allAvailable"] as? Int ?? 0) != 0,
                modifiedAt: r["modifiedAt"] as? String ?? SyncName.seedTime))
        case "WatchedEpisode":
            guard let id = r["tmdbId"] as? Int, let s = r["season"] as? Int, let e = r["episode"] as? Int else { return nil }
            return .episode(SyncEpisode(tmdbId: id, season: s, episode: e, watchedOn: r["watchedOn"] as? String))
        default:
            return nil
        }
    }

    // engine delegate

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        log.debug("event: \(String(describing: event).prefix(300), privacy: .public)")
        switch event {
        case .stateUpdate(let e):
            if let data = try? JSONEncoder().encode(e.stateSerialization) {
                try? db.setMeta("sync_state", data.base64EncodedString())
            }

        case .accountChange(let e):
            switch e.changeType {
            case .signIn:
                reseed()
            case .switchAccounts:
                try? db.resetSyncState()
                reseed()
            case .signOut:
                try? db.resetSyncState()
                updateStatus { $0.problem = "Not signed in to iCloud" }
            @unknown default:
                break
            }

        case .fetchedDatabaseChanges(let e):
            // the zone was deleted elsewhere (for example icloud data was reset): upload everything again
            if e.deletions.contains(where: { $0.zoneID == Self.zoneID }) {
                try? db.resetSyncState()
                reseed()
            }

        case .fetchedRecordZoneChanges(let e):
            var changes: [RemoteChange] = []
            for m in e.modifications {
                saveSystemFields(m.record)
                if let c = Self.change(from: m.record) { changes.append(c) }
            }
            changes += e.deletions.map { .deleted($0.recordID.recordName) }
            guard !changes.isEmpty else { break }
            do {
                let added = try db.applyRemote(changes, today: today())
                onRemoteChange?(added)
            } catch {
                updateStatus { $0.problem = Self.describe(error) }
            }

        case .sentRecordZoneChanges(let e):
            for record in e.savedRecords {
                saveSystemFields(record)
                try? db.clearOutbox(record.recordID.recordName, sentAt: record["modifiedAt"] as? String)
            }
            for id in e.deletedRecordIDs {
                try? db.setSystemFields(id.recordName, nil)
                try? db.clearOutbox(id.recordName)
            }
            var retry: [CKSyncEngine.PendingRecordZoneChange] = []
            var needsZone = false
            for failure in e.failedRecordSaves {
                let id = failure.record.recordID
                switch failure.error.code {
                case .serverRecordChanged:
                    // someone else saved first: keep their system fields, then the newer change wins
                    guard let server = failure.error.serverRecord else { break }
                    saveSystemFields(server)
                    if case .title(let remote)? = Self.change(from: server),
                       let local = try? db.outboxEntry(id.recordName), local.changedAt > remote.modifiedAt {
                        retry.append(.saveRecord(id))
                    } else if let c = Self.change(from: server) {
                        _ = try? db.applyRemote([c], today: today())
                        try? db.clearOutbox(id.recordName)
                        onRemoteChange?([])
                    }
                case .zoneNotFound:
                    needsZone = true
                    retry.append(.saveRecord(id))
                case .unknownItem:
                    // deleted on the server since we last saw it: save it fresh
                    try? db.setSystemFields(id.recordName, nil)
                    retry.append(.saveRecord(id))
                default:
                    updateStatus { $0.problem = Self.describe(failure.error) }
                }
            }
            for (id, error) in e.failedRecordDeletes {
                // already gone from icloud is as good as deleted
                if error.code == .unknownItem {
                    try? db.setSystemFields(id.recordName, nil)
                    try? db.clearOutbox(id.recordName)
                } else {
                    updateStatus { $0.problem = Self.describe(error) }
                }
            }
            if needsZone {
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
            }
            if !retry.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: retry) }
            let pending = (try? db.outbox().count) ?? 0
            updateStatus {
                $0.pending = pending
                $0.lastSynced = Date()
                if e.failedRecordSaves.isEmpty { $0.problem = nil }
            }

        case .didFetchChanges:
            updateStatus { $0.lastSynced = Date() }

        default:
            break
        }
    }

    public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                          syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { id in
            self.record(for: id)
        }
    }

    // helpers

    private func reseed() {
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        try? db.seedOutbox()
        try? db.setMeta("sync_seeded", "1")
        pushLocalChanges()
    }

    private func updateStatus(_ change: (inout Status) -> Void) {
        lock.lock()
        change(&_status)
        let s = _status
        lock.unlock()
        onStatus?(s)
    }

    static func describe(_ error: Error) -> String {
        guard let ck = error as? CKError else { return error.localizedDescription }
        switch ck.code {
        case .notAuthenticated: return "Not signed in to iCloud"
        case .networkUnavailable, .networkFailure: return "Offline, will retry"
        case .quotaExceeded: return "iCloud storage is full"
        default: return ck.localizedDescription
        }
    }
}
#endif

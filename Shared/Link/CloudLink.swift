#if COMPANION_CLOUD
import CloudKit
import Foundation
import OfficeCore

/// The away-from-home link, through a custom zone in your own iCloud private database. Nothing passes through
/// a server of ours: Apple stores the records, only your iCloud account can reach them, and commands are still signed.
///
/// Built only with the `COMPANION_CLOUD` flag, because CloudKit needs an iCloud entitlement, and an app signed without
/// a team can't carry one. See Docs/Companion.md.
actor CloudLink {
    static let containerID = "iCloud.nz.hamish.TheCity"

    private let database = CKContainer(identifier: CloudLink.containerID).privateCloudDatabase
    private let zone = CKRecordZone.ID(zoneName: "City")
    private var zoneReady = false

    enum RecordType {
        static let snapshot = "Snapshot"
        static let command = "Command"
        static let receipt = "Receipt"
        static let alert = "Alert"
    }

    static func isSignedIn() async -> Bool {
        (try? await CKContainer(identifier: containerID).accountStatus()) == .available
    }

    private func prepare() async throws {
        guard !zoneReady else { return }
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zone)], deleting: [])
        zoneReady = true
    }

    private func id(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zone) }

    // MARK: The Mac

    /// Overwrites the one snapshot record; the phone only ever wants the latest.
    func publish(_ snapshot: CitySnapshot, hostID: UUID) async throws {
        try await prepare()
        let record = CKRecord(recordType: RecordType.snapshot, recordID: id("snapshot-\(hostID.uuidString)"))
        record["payload"] = try CompanionCoding.encoder.encode(snapshot)
        record["waiting"] = snapshot.waitingCount
        _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
    }

    /// One record per question, which the phone's subscription turns into a notification even when the app isn't open.
    func raiseAlert(requestID: String, title: String, body: String) async throws {
        try await prepare()
        let record = CKRecord(recordType: RecordType.alert, recordID: id("alert-\(requestID)"))
        record["title"] = title
        record["body"] = body
        _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
    }

    func clearAlert(requestID: String) async {
        _ = try? await database.modifyRecords(saving: [], deleting: [id("alert-\(requestID)")])
    }

    private var changeToken: CKServerChangeToken? = CloudLink.loadToken()

    /// Commands the phone has written since the last look.
    func takeCommands() async throws -> [(record: CKRecord.ID, command: SealedCommand)] {
        try await prepare()
        var found: [(CKRecord.ID, SealedCommand)] = []
        var more = true
        while more {
            let changes = try await database.recordZoneChanges(inZoneWith: zone, since: changeToken)
            for (recordID, result) in changes.modificationResultsByID {
                guard case .success(let modification) = result, modification.record.recordType == RecordType.command,
                      let payload = modification.record["payload"] as? Data, let tag = modification.record["tag"] as? Data else { continue }
                found.append((recordID, SealedCommand(payload: payload, tag: tag)))
            }
            changeToken = changes.changeToken
            more = changes.moreComing
        }
        Self.saveToken(changeToken)
        return found
    }

    /// Answers the phone and removes the command, so it can't be picked up twice.
    func finish(_ record: CKRecord.ID, receipt: CommandReceipt?) async {
        var saving: [CKRecord] = []
        if let receipt, let data = try? CompanionCoding.encoder.encode(receipt) {
            let answer = CKRecord(recordType: RecordType.receipt, recordID: id("receipt-\(receipt.commandID.uuidString)"))
            answer["payload"] = data
            saving.append(answer)
        }
        _ = try? await database.modifyRecords(saving: saving, deleting: [record], savePolicy: .allKeys)
    }

    private static func loadToken() -> CKServerChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: "companionCloudToken") else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private static func saveToken(_ token: CKServerChangeToken?) {
        let data = token.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        UserDefaults.standard.set(data, forKey: "companionCloudToken")
    }

    // MARK: The phone

    func latestSnapshot(hostID: UUID) async throws -> CitySnapshot? {
        try await prepare()
        do {
            let record = try await database.record(for: id("snapshot-\(hostID.uuidString)"))
            guard let data = record["payload"] as? Data else { return nil }
            return try CompanionCoding.decoder.decode(CitySnapshot.self, from: data)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    func send(_ sealed: SealedCommand, id commandID: UUID) async throws {
        try await prepare()
        let record = CKRecord(recordType: RecordType.command, recordID: id("command-\(commandID.uuidString)"))
        record["payload"] = sealed.payload
        record["tag"] = sealed.tag
        _ = try await database.modifyRecords(saving: [record], deleting: [])
    }

    /// The Mac's answer to a command, once there is one. Reading it also tidies it away.
    func receipt(for commandID: UUID) async -> CommandReceipt? {
        let recordID = id("receipt-\(commandID.uuidString)")
        guard let record = try? await database.record(for: recordID), let data = record["payload"] as? Data,
              let receipt = try? CompanionCoding.decoder.decode(CommandReceipt.self, from: data) else { return nil }
        _ = try? await database.modifyRecords(saving: [], deleting: [recordID])
        return receipt
    }

    /// Asks CloudKit to notify the phone whenever the Mac raises an alert, whether or not the app is running.
    func subscribeToAlerts() async throws {
        try await prepare()
        let subscription = CKQuerySubscription(recordType: RecordType.alert, predicate: NSPredicate(value: true),
                                               subscriptionID: "alerts", options: [.firesOnRecordCreation])
        subscription.zoneID = zone
        let info = CKSubscription.NotificationInfo()
        info.titleLocalizationKey = "%1$@"
        info.titleLocalizationArgs = ["title"]
        info.alertLocalizationKey = "%1$@"
        info.alertLocalizationArgs = ["body"]
        info.soundName = "default"
        subscription.notificationInfo = info
        _ = try await database.modifySubscriptions(saving: [subscription], deleting: [])
    }
}
#endif

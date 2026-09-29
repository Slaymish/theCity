import Network
import Observation
import OfficeCore
import UIKit

/// The phone's connection to its Mac: the latest snapshot of the city, and the commands it has sent that are still out.
/// It prefers the local network and falls back to iCloud when the app is built with `COMPANION_CLOUD`.
@MainActor
@Observable
final class CityLink {
    enum Route: Equatable {
        case none, local, cloud
    }

    private(set) var pairing: PairingRecord? = LinkKeychain.load()
    private(set) var snapshot: CitySnapshot?
    private(set) var route: Route = .none
    /// Commands sent and not yet answered.
    private(set) var outstanding: Set<UUID> = []
    /// The latest thing the Mac refused, said plainly, until it's dismissed.
    var notice: String?

    @ObservationIgnored private let browser = LinkBrowser()
    @ObservationIgnored private var link: LinkConnection?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var transcripts: [UUID: CheckedContinuation<String, Error>] = [:]
    #if COMPANION_CLOUD
    @ObservationIgnored private let cloud = CloudLink()
    @ObservationIgnored private var cloudTask: Task<Void, Never>?
    #endif

    static let cloudInterval: Duration = .seconds(3)
    /// A snapshot this old means the Mac is asleep or out of reach; it republishes at least once a minute.
    static let stale: TimeInterval = 3 * 60

    var isStale: Bool { snapshot.map { Date.now.timeIntervalSince($0.takenAt) > Self.stale } ?? true }

    // MARK: Pairing

    @discardableResult
    func pair(with url: URL) -> Bool {
        guard let code = PairingCode(url: url) else { return false }
        let record = PairingRecord(code)
        LinkKeychain.save(record)
        stop()
        pairing = record
        snapshot = nil
        start()
        return true
    }

    func unpair() {
        stop()
        LinkKeychain.clear()
        pairing = nil
        snapshot = nil
    }

    // MARK: Connecting

    /// Called when the app comes to the front. iOS suspends the app in the background, which ends the connection anyway.
    func start() {
        guard let pairing, !active else { return }
        active = true
        browser.start(hostID: pairing.hostID, key: pairing.key) { [weak self] endpoint in self?.connect(to: endpoint) }
        startCloud()
    }

    func stop() {
        active = false
        browser.stop()
        link?.close()
        link = nil
        route = .none
        failTranscripts(DictationFailure.lost)
        #if COMPANION_CLOUD
        cloudTask?.cancel()
        cloudTask = nil
        #endif
    }

    private func connect(to endpoint: NWEndpoint) {
        guard link == nil, let pairing else { return }
        let link = LinkConnection(NWConnection(to: endpoint, using: LinkTLS.parameters(key: pairing.key)))
        self.link = link
        link.onReady = { [weak self, weak link] in
            link?.send(.hello(version: CitySnapshot.protocolVersion, device: UIDevice.current.name))
            self?.route = .local
        }
        link.onMessage = { [weak self] message in self?.received(message) }
        link.onClose = { [weak self, weak link] in
            guard let self, self.link === link else { return }
            self.link = nil
            if self.route == .local { self.route = .none }
            self.failTranscripts(DictationFailure.lost)
            // The browser reports the Mac again when it's back, and this reconnects then.
        }
        link.start()
    }

    private func received(_ message: LinkMessage) {
        switch message {
        case .snapshot(let snapshot): accept(snapshot)
        case .receipt(let receipt): settle(receipt)
        case .transcript(let result): finish(result)
        case .command, .hello, .dictation: break
        }
    }

    // MARK: Dictation

    enum DictationFailure: LocalizedError {
        case offline, lost, timedOut

        var errorDescription: String? {
            switch self {
            case .offline: "Dictation needs your Mac on this network."
            case .lost: "Lost your Mac before it sent the words back."
            case .timedOut: "Your Mac took too long to answer."
            }
        }
    }

    /// Sends speech to the Mac and waits for its dictation model to send the words back. Local network only.
    func dictate(_ clip: DictationClip) async throws -> String {
        guard let link, route == .local else { throw DictationFailure.offline }
        return try await withCheckedThrowingContinuation { continuation in
            transcripts[clip.id] = continuation
            link.send(.dictation(clip))
            Task {
                try? await Task.sleep(for: .seconds(90))
                transcripts.removeValue(forKey: clip.id)?.resume(throwing: DictationFailure.timedOut)
            }
        }
    }

    private func finish(_ result: DictationResult) {
        guard let continuation = transcripts.removeValue(forKey: result.clipID) else { return }
        switch result.outcome {
        case .text(let text): continuation.resume(returning: text)
        case .failed(let reason): continuation.resume(throwing: DictationRefused(reason: reason))
        }
    }

    private func failTranscripts(_ error: Error) {
        let waiting = transcripts
        transcripts = [:]
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }

    struct DictationRefused: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    private func accept(_ new: CitySnapshot) {
        guard new.version == CitySnapshot.protocolVersion else {
            notice = "Your Mac has a different version of The City. Update both to the same version."
            return
        }
        if let current = snapshot, new.takenAt < current.takenAt { return }
        snapshot = new
    }

    private func settle(_ receipt: CommandReceipt) {
        guard outstanding.remove(receipt.commandID) != nil else { return }
        if case .refused(let reason) = receipt.outcome { notice = reason }
    }

    // MARK: Commands

    func send(_ action: CompanionCommand.Action) {
        guard let pairing else { return }
        let command = CompanionCommand(issuedAt: .now, device: UIDevice.current.name, action: action)
        guard let sealed = try? SealedCommand.seal(command, with: LinkSigner(key: pairing.key)) else { return }
        outstanding.insert(command.id)
        let local = link != nil && route == .local
        Task {
            // The Mac drops a command it gets after the gate's lifetime, so there's no point waiting longer than that.
            try? await Task.sleep(for: .seconds(local ? 20 : CommandGate().lifetime))
            if outstanding.remove(command.id) != nil { notice = "Your Mac didn’t answer. Check that it’s awake and The City is open." }
        }
        if let link, local {
            link.send(.command(sealed))
            return
        }
        #if COMPANION_CLOUD
        Task {
            do {
                try await cloud.send(sealed, id: command.id)
            } catch {
                outstanding.remove(command.id)
                notice = "Couldn’t reach iCloud. Try again when you’re online."
            }
        }
        #else
        outstanding.remove(command.id)
        notice = "Your Mac isn’t on this network."
        #endif
    }

    // MARK: iCloud

    private func startCloud() {
        #if COMPANION_CLOUD
        guard cloudTask == nil, let hostID = pairing?.hostID else { return }
        cloudTask = Task { [cloud] in
            guard await CloudLink.isSignedIn() else { return }
            try? await cloud.subscribeToAlerts()
            while !Task.isCancelled {
                if route != .local, let latest = try? await cloud.latestSnapshot(hostID: hostID) {
                    accept(latest)
                    if route == .none { route = .cloud }
                }
                for id in outstanding {
                    if let receipt = await cloud.receipt(for: id) { settle(receipt) }
                }
                try? await Task.sleep(for: Self.cloudInterval)
            }
        }
        #endif
    }
}

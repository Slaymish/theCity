import AppKit
import Observation
import OfficeCore

/// Serves the city to the companion app on your iPhone: a snapshot whenever something changes, and the phone's
/// answers and jobs carried out as if typed here. Off until you turn it on in Settings › iPhone.
@MainActor
@Observable
final class CompanionHost {
    static let shared = CompanionHost()

    var isOn = UserDefaults.app.bool(forKey: "companionOn") {
        didSet {
            UserDefaults.app.set(isOn, forKey: "companionOn")
            isOn ? start() : stop()
        }
    }

    private(set) var pairing: PairingRecord? = LinkKeychain.load()
    /// Phones connected over the local network now, by name.
    private(set) var phones: [String] = []

    @ObservationIgnored private let listener = LinkListener()
    @ObservationIgnored private var links: [ObjectIdentifier: (link: LinkConnection, device: String?)] = [:]
    @ObservationIgnored private var gate = CommandGate()
    @ObservationIgnored private var published: CitySnapshot?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var watching = false
    #if COMPANION_CLOUD
    @ObservationIgnored private let cloud = CloudLink()
    @ObservationIgnored private var cloudTask: Task<Void, Never>?
    @ObservationIgnored private var cloudPublished: CitySnapshot?
    @ObservationIgnored private var cloudPublishedAt = Date.distantPast
    @ObservationIgnored private var alerted: Set<String> = []
    #endif

    /// Coalesces a burst of stream lines into one snapshot. The local link is cheap; CloudKit writes are rate limited.
    static let localDelay: Duration = .milliseconds(300)
    static let cloudInterval: Duration = .seconds(3)
    /// Republished even when nothing changes, so the phone can tell a quiet city from a Mac that's asleep or offline.
    static let heartbeat: TimeInterval = 60

    static var hostID: UUID {
        if let saved = UserDefaults.app.string(forKey: "companionHostID").flatMap(UUID.init(uuidString:)) { return saved }
        let id = UUID()
        UserDefaults.app.set(id.uuidString, forKey: "companionHostID")
        return id
    }

    static var hostName: String { Host.current().localizedName ?? "Mac" }

    var code: PairingCode? { pairing?.code }

    func start() {
        guard isOn, !MainWindow.offscreen else { return }
        let record = pairing ?? makePairing()
        listener.onConnection = { [weak self] link in self?.adopt(link) }
        listener.start(key: record.key, name: Self.hostName, hostID: record.hostID)
        if !watching {
            watching = true
            watch()
        }
        startCloud()
    }

    func stop() {
        listener.stop()
        links.values.forEach { $0.link.close() }
        links = [:]
        phones = []
        #if COMPANION_CLOUD
        cloudTask?.cancel()
        cloudTask = nil
        #endif
    }

    /// A new key unpairs every phone; each one has to scan the new code.
    func pairAgain() {
        stop()
        pairing = nil
        LinkKeychain.clear()
        start()
    }

    private func makePairing() -> PairingRecord {
        let record = PairingRecord(PairingCode(hostID: Self.hostID, host: Self.hostName, key: LinkSigner.newKey()))
        LinkKeychain.save(record)
        pairing = record
        return record
    }

    // MARK: Snapshots

    private func watch() {
        guard isOn else {
            watching = false
            return
        }
        let snapshot = withObservationTracking { Self.snapshot(of: CityStore.shared) } onChange: {
            Task { @MainActor in CompanionHost.shared.changed() }
        }
        publish(snapshot)
    }

    private func changed() {
        guard pending == nil else { return }
        pending = Task {
            try? await Task.sleep(for: Self.localDelay)
            pending = nil
            watch()
        }
    }

    static func snapshot(of city: CityStore) -> CitySnapshot {
        CitySnapshot(host: hostName, takenAt: .distantPast, buildings: city.buildings.map { building in
            BuildingSnapshot(id: building.id, name: building.name, title: building.title, style: building.style, floors: building.floors.map { floor in
                guard let session = city.sessions[floor.id] else {
                    return FloorSnapshot(id: floor.id, name: floor.name, hires: floor.hires, request: floor.lastRequest, phase: .idle, startedAt: nil)
                }
                let colours = Dictionary(session.catalogueNames.enumerated().map { ($1, $0) }) { first, _ in first }
                return session.mirror.snapshot(id: floor.id, name: floor.name, hires: floor.hires, colours: colours,
                                               request: session.request.isEmpty ? floor.lastRequest : session.request,
                                               state: session.state, startedAt: session.startedAt)
            })
        })
    }

    private func publish(_ snapshot: CitySnapshot) {
        guard snapshot != published else { return }
        published = snapshot
        var stamped = snapshot
        stamped.takenAt = .now
        for (_, entry) in links where entry.device != nil { entry.link.send(.snapshot(stamped)) }
    }

    // MARK: Local network

    private func adopt(_ link: LinkConnection) {
        let key = ObjectIdentifier(link)
        links[key] = (link, nil)
        link.onMessage = { [weak self, weak link] message in
            guard let self, let link else { return }
            self.received(message, on: link)
        }
        link.onClose = { [weak self] in
            guard let self else { return }
            self.links[key] = nil
            self.phones = self.links.values.compactMap(\.device).sorted()
        }
    }

    private func received(_ message: LinkMessage, on link: LinkConnection) {
        switch message {
        case .hello(let version, let device):
            guard version == CitySnapshot.protocolVersion else { return link.close() }
            links[ObjectIdentifier(link)]?.device = device
            phones = links.values.compactMap(\.device).sorted()
            if var snapshot = published {
                snapshot.takenAt = .now
                link.send(.snapshot(snapshot))
            }
        case .command(let sealed):
            if let receipt = handle(sealed) { link.send(.receipt(receipt)) }
        case .dictation(let clip):
            // Only a phone that has said hello, like a snapshot.
            guard links[ObjectIdentifier(link)]?.device != nil else { return }
            transcribe(clip, for: link)
        case .snapshot, .receipt, .transcript:
            break
        }
    }

    private func transcribe(_ clip: DictationClip, for link: LinkConnection) {
        Task { [weak link] in
            let outcome: DictationResult.Outcome
            do {
                guard let samples = clip.floats else { throw DictationClipFailure.unreadable }
                let text = try await DictationStore.shared.transcribe(phoneSamples: samples)
                outcome = text.isEmpty ? .failed("Your Mac didn’t hear any words.") : .text(text)
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            link?.send(.transcript(DictationResult(clipID: clip.id, outcome: outcome)))
        }
    }

    private enum DictationClipFailure: LocalizedError {
        case unreadable
        var errorDescription: String? { "The recording was empty or too long. Keep it under \(DictationClip.maximumSeconds) seconds." }
    }

    // MARK: Commands

    /// Nil when the command isn't from a paired phone, which gets no answer at all.
    private func handle(_ sealed: SealedCommand) -> CommandReceipt? {
        guard let pairing else { return nil }
        switch gate.admit(sealed, now: .now, signer: LinkSigner(key: pairing.key)) {
        case .success(let command):
            return CommandReceipt(commandID: command.id, outcome: perform(command))
        case .failure(.badSignature), .failure(.unreadable):
            return nil
        case .failure(let rejection):
            guard let id = (try? CompanionCoding.decoder.decode(CompanionCommand.self, from: sealed.payload))?.id else { return nil }
            let reason = switch rejection {
            case .expired: "It took too long to reach your Mac, so it was dropped."
            case .fromTheFuture: "Your phone’s clock doesn’t match your Mac’s."
            default: "It had already been done."
            }
            return CommandReceipt(commandID: id, outcome: .refused(reason))
        }
    }

    private func perform(_ command: CompanionCommand) -> CommandReceipt.Outcome {
        let city = CityStore.shared
        func waiting(_ floor: UUID, _ requestID: String) -> (RunController, PendingRequest)? {
            guard let session = city.sessions[floor], let request = session.state.pendingRequests.first(where: { $0.id == requestID }) else { return nil }
            return (session, request)
        }
        let answered = CommandReceipt.Outcome.refused("That was already answered on your Mac.")
        switch command.action {
        case .answer(let floor, let requestID, let answers):
            guard let (session, request) = waiting(floor, requestID) else { return answered }
            guard case .question = request.request.kind else { return .refused("That’s an approval, not a question.") }
            session.answer(request, answers: answers)
        case .allow(let floor, let requestID):
            guard let (session, request) = waiting(floor, requestID) else { return answered }
            guard case .approval = request.request.kind else { return .refused("That’s a question; answer it instead.") }
            session.allow(request)
        case .deny(let floor, let requestID):
            guard let (session, request) = waiting(floor, requestID) else { return answered }
            session.deny(request)
        case .newJob(let building, let request):
            let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .refused("The request was empty.") }
            guard city.building(building) != nil else { return .refused("That project is no longer in your city.") }
            guard city.askReception(text, in: building) else { return .refused("Reception is still placing another request in that project.") }
        case .cancel(let floor):
            guard let session = city.sessions[floor], session.isRunning else { return .refused("Nothing is running on that floor.") }
            session.cancel()
        }
        return .done
    }

    // MARK: iCloud

    private func startCloud() {
        #if COMPANION_CLOUD
        guard cloudTask == nil, let hostID = pairing?.hostID else { return }
        cloudTask = Task { [cloud] in
            guard await CloudLink.isSignedIn() else { return }
            while !Task.isCancelled {
                if let commands = try? await cloud.takeCommands() {
                    for (record, sealed) in commands {
                        let receipt = handle(sealed)
                        await cloud.finish(record, receipt: receipt)
                    }
                }
                if let snapshot = published, snapshot != cloudPublished || Date.now.timeIntervalSince(cloudPublishedAt) > Self.heartbeat {
                    var stamped = snapshot
                    stamped.takenAt = .now
                    if (try? await cloud.publish(stamped, hostID: hostID)) != nil {
                        cloudPublished = snapshot
                        cloudPublishedAt = stamped.takenAt
                    }
                    await raiseAlerts(for: snapshot)
                }
                try? await Task.sleep(for: Self.cloudInterval)
            }
        }
        #endif
    }

    #if COMPANION_CLOUD
    /// The phone's subscription turns each new alert record into a notification, so it hears about questions while closed.
    private func raiseAlerts(for snapshot: CitySnapshot) async {
        var open: Set<String> = []
        for building in snapshot.buildings {
            for floor in building.floors {
                for question in floor.questions {
                    open.insert(question.id)
                    guard !alerted.contains(question.id) else { continue }
                    alerted.insert(question.id)
                    let who = question.room == "manager" ? "The manager" : question.room.capitalized
                    let title = question.questions == nil ? "\(who) needs approval" : "\(who) has a question"
                    let body = "\(building.displayName) · \(floor.name): " + (question.questions?.first?.question ?? question.summary ?? question.toolName)
                    try? await cloud.raiseAlert(requestID: question.id, title: title, body: body)
                }
            }
        }
        for gone in alerted.subtracting(open) {
            alerted.remove(gone)
            await cloud.clearAlert(requestID: gone)
        }
    }
    #endif
}

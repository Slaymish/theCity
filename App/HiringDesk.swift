import Foundation
import FoundationModels
import OfficeCore

@Generable
struct HiringPlan {
    @Guide(description: "The departments this request needs, in the order they should work. Leave out any it does not need.")
    var hires: [Hire]
    @Guide(description: "Names of services from the list that the job needs. Leave out the rest.")
    var services: [String]
    @Guide(description: "Names of skills from the list that the job needs. Leave out the rest.")
    var skills: [String]
}

@Generable
struct Hire {
    @Guide(description: "A department name copied exactly from the list")
    var department: String
    @Guide(description: "Why this department is needed, in under twelve words")
    var reason: String
}

struct Candidate: Identifiable, Equatable {
    var id: String { department.name }
    var department: Department
    var reason: String?
    var hired: Bool
}

struct KitPlan {
    var servers: Set<String>
    var skills: Set<String>
    var reasons: [String: String]
}

enum HiringDesk {
    enum Outcome {
        case proposed([Candidate], KitPlan?)
        case unavailable(String, [Candidate])
    }

    /// The on-device model often restates the description; a reason that mostly reuses its words adds nothing.
    static func repeats(_ reason: String, _ description: String) -> Bool {
        let words = { (text: String) in Set(text.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count > 3 }) }
        let said = words(reason)
        guard !said.isEmpty else { return true }
        return Double(said.intersection(words(description)).count) / Double(said.count) >= 0.6
    }

    static func propose(request: String, catalogue: [Department], kit: Kit?) async -> Outcome {
        let everyone = catalogue.map { Candidate(department: $0, reason: nil, hired: false) }
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            return .unavailable("The on-device model isn’t available on this Mac (\(model.availability)). Choose departments yourself.", everyone)
        }
        let departments = catalogue.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
        let services = (kit?.usableServers ?? []).map { "- \($0.name)" }.joined(separator: "\n")
        let skills = (kit?.skills ?? []).map { "- \($0.name): \($0.description.prefix(90))" }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: """
        You are the receptionist of an office. You read a job request and decide which departments to hire, \
        and which services and skills the job needs. Hire the fewest departments that can finish the job, \
        in the order they should work. A department that only reviews or designs is not needed for a small, \
        clear task. Examples: for "fix a typo in the README", hire only the department that writes or changes files. \
        For "research three options and write a recommendation", hire the researching department first, \
        then the one that writes. Give each reason in your own words; do not repeat the department's description.
        Departments:
        \(departments)
        Services:
        \(services.isEmpty ? "(none)" : services)
        Skills:
        \(skills.isEmpty ? "(none)" : skills)
        Only use names from these lists.
        """)
        do {
            let plan = try await session.respond(to: request, generating: HiringPlan.self).content
            var seen = Set<String>()
            let hires = plan.hires.filter { hire in
                catalogue.contains { $0.name == hire.department } && seen.insert(hire.department).inserted
            }
            let hired = hires.compactMap { hire in
                catalogue.first { $0.name == hire.department }.map {
                    Candidate(department: $0, reason: Self.repeats(hire.reason, $0.description) ? nil : hire.reason, hired: true)
                }
            }
            let rest = everyone.filter { !seen.contains($0.department.name) }
            let kitPlan = kit.map { kit in
                KitPlan(
                    servers: Set(plan.services).intersection(kit.usableServers.map(\.name)),
                    skills: Set(plan.skills).intersection(kit.skills.map(\.name)),
                    reasons: [:]
                )
            }
            return .proposed(hired + rest, kitPlan)
        } catch {
            return .unavailable("The on-device model couldn’t make a plan: \(error.localizedDescription). Choose departments yourself.", everyone)
        }
    }

    /// Hires the preset's team in its order; the model's services and skills still apply, and the team stays editable.
    static func staff(_ outcome: Outcome, with preset: FloorPreset, catalogue: [Department]) -> Outcome {
        let team = preset.roles.compactMap { role in catalogue.first { $0.name == role } }
        guard !team.isEmpty else { return outcome }
        let hired = team.map { Candidate(department: $0, reason: "Part of the \(preset.name) team", hired: true) }
        let rest = catalogue.filter { !team.contains($0) }.map { Candidate(department: $0, reason: nil, hired: false) }
        switch outcome {
        case .proposed(_, let kitPlan): return .proposed(hired + rest, kitPlan)
        case .unavailable: return .proposed(hired + rest, nil)
        }
    }
}

@Generable
struct Routing {
    @Guide(description: "Exact name of the existing floor whose kind of work matches this request, or an empty string if none does")
    var floor: String
    @Guide(description: "If no floor matches: a name for a new floor describing the kind of work, two or three words, e.g. 'Slide decks' or 'Payments'")
    var newFloorName: String
}

struct RoutingSuggestion: Equatable {
    var floorID: UUID?
    var newFloorName: String
    var reason: String
    var presetID: String? = nil
}

/// The building's receptionist: decides whether a request belongs on an existing floor or a new one.
@MainActor
enum ReceptionDesk {
    static func route(request: String, floors: [CityStore.Floor]) async -> RoutingSuggestion {
        let fallbackName = CityStore.floorName(for: request, existing: floors.map(\.name))
        let guess = FloorPreset.match(request)
        guard !floors.isEmpty else {
            return newFloor(for: request, preset: guess, proposed: "", floors: floors, reason: "There are no floors yet, so this needs a new one.")
        }
        guard case .available = SystemLanguageModel.default.availability else {
            return newFloor(for: request, preset: guess, proposed: "", floors: floors, reason: "Choose a floor, or set up a new one.")
        }
        let session = takeSession(for: floors)
        do {
            guard let routing = try await withTimeout(seconds: 12, { try await session.respond(to: request, generating: Routing.self).content }) else {
                return newFloor(for: request, preset: guess, proposed: "", floors: floors, reason: "Reception is taking too long. Choose a floor, or set up a new one.")
            }
            let named = floors.first { $0.name.caseInsensitiveCompare(routing.floor.trimmingCharacters(in: .whitespaces)) == .orderedSame }
            if let match = (named ?? closest(to: request, proposed: routing.newFloorName, in: floors))
                .flatMap({ supports($0, request: request, preset: guess) ? $0 : nil }) {
                let last = match.lastRequest.map { " Its last job: “\($0.prefix(80))”." } ?? ""
                return RoutingSuggestion(floorID: match.id, newFloorName: fallbackName,
                                         reason: "\(match.name) looks like the right team.\(last)")
            }
            return newFloor(for: request, preset: guess, proposed: routing.newFloorName, floors: floors,
                            reason: "None of the floors does this kind of work yet.")
        } catch {
            return newFloor(for: request, preset: guess, proposed: "", floors: floors, reason: "Choose a floor, or set up a new one.")
        }
    }

    /// "@Floor name request" skips routing; the longest matching floor name wins.
    static func directFloor(in text: String, floors: [CityStore.Floor]) -> (CityStore.Floor, String)? {
        guard text.hasPrefix("@") else { return nil }
        let body = text.dropFirst()
        let match = floors
            .filter { body.lowercased().hasPrefix($0.name.lowercased()) }
            .max { $0.name.count < $1.name.count }
        return match.map { ($0, body.dropFirst($0.name.count).trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// What reception routes and names a floor on: a slash command's arguments, or the command's name when it has none.
    static func topic(of request: String, commands: [CommandInfo]) -> String {
        guard let (command, arguments) = SlashCommand.parse(request, commands: commands) else { return request }
        guard arguments.isEmpty else { return arguments }
        return String(command.name.split(separator: ":").last ?? "").replacingOccurrences(of: "-", with: " ")
    }

    /// A preset's existing floor takes the work instead of a new one: always for one-off jobs, and for long ones when it has done related work.
    private static func newFloor(for request: String, preset: FloorPreset?, proposed: String, floors: [CityStore.Floor], reason: String) -> RoutingSuggestion {
        let fallbackName = CityStore.floorName(for: request, existing: floors.map(\.name))
        guard let preset else {
            return RoutingSuggestion(floorID: nil, newFloorName: usableName(proposed, floors: floors) ?? fallbackName, reason: reason)
        }
        if let standing = floors.first(where: { presetOf($0) == preset && (preset.session == .fresh || supports($0, request: request, preset: nil)) }) {
            return RoutingSuggestion(floorID: standing.id, newFloorName: fallbackName,
                                     reason: "\(standing.name) is set up for this: \(preset.purpose.prefix(1).lowercased() + preset.purpose.dropFirst())")
        }
        let name = preset.session == .fresh || words(proposed).isDisjoint(with: words(request))
            ? CityStore.floorName(for: preset.name, existing: floors.map(\.name))
            : usableName(proposed, floors: floors) ?? fallbackName
        return RoutingSuggestion(floorID: nil, newFloorName: name,
                                 reason: "\(reason) It suits a \(preset.name) team: \(preset.roles.joined(separator: ", ")).",
                                 presetID: preset.id)
    }

    private static var warm: (key: String, session: LanguageModelSession)?

    /// Loads the model while the request is still being typed, so asking doesn't wait for it.
    static func prewarm(floors: [CityStore.Floor]) {
        guard !floors.isEmpty, case .available = SystemLanguageModel.default.availability else { return }
        let key = instructions(for: floors)
        guard warm?.key != key else { return }
        let session = LanguageModelSession(instructions: key)
        session.prewarm()
        warm = (key, session)
    }

    private static func takeSession(for floors: [CityStore.Floor]) -> LanguageModelSession {
        let key = instructions(for: floors)
        defer { warm = nil }
        if let warm, warm.key == key { return warm.session }
        return LanguageModelSession(instructions: key)
    }

    private static func instructions(for floors: [CityStore.Floor]) -> String {
        let list = floors.map { floor in
            let purpose = floor.purpose.map { " Set up for: \($0.prefix(120))." } ?? ""
            let recent = recentRequests(floor).map { "“\($0.prefix(80))”" }.joined(separator: ", ")
            return "- \(floor.name) (team: \(floor.hires.joined(separator: ", "))).\(purpose) Recent jobs: \(recent.isEmpty ? "none" : recent)"
        }.joined(separator: "\n")
        return """
        You are the receptionist of an office building. Each floor is a team that does one kind of work. \
        Pick the floor whose kind of work matches the request. If none matches, leave the floor empty and name a new floor.
        Examples: a request to fix or extend the sign-in page goes to a login or authentication floor. \
        A request for a presentation goes to a new floor called "Slide decks" when no floor makes presentations.
        Floors:
        \(list)
        """
    }

    private static func recentRequests(_ floor: CityStore.Floor) -> [String] {
        let asked = FloorHistory.load(floor.id).filter { $0.kind == .request }.suffix(3).map(\.text)
        return asked.isEmpty ? floor.lastRequest.map { [$0] } ?? [] : Array(asked.reversed())
    }

    // A task group would wait for the model, which ignores cancellation, so race unstructured tasks instead.
    private static func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T? {
        let race = Race<T>()
        return try await withCheckedThrowingContinuation { continuation in
            race.continuation = continuation
            let job = Task { do { race.finish(.success(try await work())) } catch { race.finish(.failure(error)) } }
            Task { try? await Task.sleep(for: .seconds(seconds)); job.cancel(); race.finish(.success(nil)) }
        }
    }

    private static func words(_ text: String) -> Set<String> {
        let stop: Set<String> = ["the", "and", "for", "with", "add", "make", "fix", "our", "this", "that", "into", "from", "about", "update", "new", "please"]
        return Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 && !stop.contains($0) })
    }

    /// The small model often picks an unrelated floor, so its pick needs a shared word or a matching preset to stand.
    private static func supports(_ floor: CityStore.Floor, request: String, preset: FloorPreset?) -> Bool {
        if let preset, presetOf(floor) == preset { return true }
        let known = ([floor.name, floor.purpose ?? ""] + recentRequests(floor)).joined(separator: " ")
        return !words(request).isDisjoint(with: words(known))
    }

    /// Floors set up before presets existed are matched by what they are called and for.
    private static func presetOf(_ floor: CityStore.Floor) -> FloorPreset? {
        FloorPreset.named(floor.presetID) ?? FloorPreset.match(floor.name + " " + (floor.purpose ?? ""))
    }

    /// Backs up the small on-device model: a proposed name that repeats a floor's name, or a request sharing
    /// two meaningful words with a floor's name or last job, means that floor already does this work.
    private static func closest(to request: String, proposed: String, in floors: [CityStore.Floor]) -> CityStore.Floor? {
        let proposedWords = words(proposed)
        if let byName = floors.first(where: { !proposedWords.isDisjoint(with: words($0.name)) }) { return byName }
        let asked = words(request)
        let scored = floors.map { ($0, asked.intersection(words($0.name + " " + ($0.lastRequest ?? ""))).count) }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= 2 else { return nil }
        return best.0
    }

    /// Rejects names that echo the prompt or are too vague to tell floors apart.
    private static func usableName(_ raw: String, floors: [CityStore.Floor]) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let words = name.split(separator: " ")
        let vague: Set<String> = ["routing", "floor", "new floor", "team", "office", "general", "task", "request", "work"]
        guard (1...4).contains(words.count), !vague.contains(name.lowercased()),
              !floors.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

private final class Race<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<T?, Error>?

    func finish(_ result: Result<T?, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

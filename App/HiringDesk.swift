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
}

/// The building's receptionist: decides whether a request belongs on an existing floor or a new one.
@MainActor
enum ReceptionDesk {
    static func route(request: String, floors: [CityStore.Floor]) async -> RoutingSuggestion {
        let fallbackName = CityStore.floorName(for: request, existing: floors.map(\.name))
        guard !floors.isEmpty else {
            return RoutingSuggestion(floorID: nil, newFloorName: fallbackName, reason: "There are no floors yet, so this needs a new one.")
        }
        guard case .available = SystemLanguageModel.default.availability else {
            return RoutingSuggestion(floorID: nil, newFloorName: fallbackName, reason: "Choose a floor, or set up a new one.")
        }
        let list = floors.map { floor in
            "- \(floor.name) (team: \(floor.hires.joined(separator: ", "))). Last job: \(floor.lastRequest?.prefix(120) ?? "none")"
        }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: """
        You are the receptionist of an office building. Each floor is a team that does one kind of work. \
        Pick the floor whose kind of work matches the request. If none matches, leave the floor empty and name a new floor.
        Examples: a request to fix or extend the sign-in page goes to a login or authentication floor. \
        A request for a presentation goes to a new floor called "Slide decks" when no floor makes presentations.
        Floors:
        \(list)
        """)
        do {
            let routing = try await session.respond(to: request, generating: Routing.self).content
            let named = floors.first { $0.name.caseInsensitiveCompare(routing.floor.trimmingCharacters(in: .whitespaces)) == .orderedSame }
            if let match = named ?? closest(to: request, proposed: routing.newFloorName, in: floors) {
                let last = match.lastRequest.map { " Its last job: “\($0.prefix(80))”." } ?? ""
                return RoutingSuggestion(floorID: match.id, newFloorName: fallbackName,
                                         reason: "\(match.name) looks like the right team.\(last)")
            }
            return RoutingSuggestion(floorID: nil, newFloorName: usableName(routing.newFloorName, floors: floors) ?? fallbackName,
                                     reason: "None of the floors does this kind of work yet.")
        } catch {
            return RoutingSuggestion(floorID: nil, newFloorName: fallbackName, reason: "Choose a floor, or set up a new one.")
        }
    }

    /// Backs up the small on-device model: a proposed name that repeats a floor's name, or a request sharing
    /// two meaningful words with a floor's name or last job, means that floor already does this work.
    private static func closest(to request: String, proposed: String, in floors: [CityStore.Floor]) -> CityStore.Floor? {
        let stop: Set<String> = ["the", "and", "for", "with", "add", "make", "fix", "our", "this", "that", "into", "from", "about", "update", "new", "please"]
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 && !stop.contains($0) })
        }
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

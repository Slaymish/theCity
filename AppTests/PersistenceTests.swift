import Foundation
import Testing
import OfficeCore
@testable import TheCity

/// The saved files outlive every build, so these pin their formats: a file written by an earlier build must still load.
@MainActor
struct PersistenceTests {
    /// A `city.json` as the app writes it, with every field set, and a floor saved before most fields existed.
    static let city = """
    [
      {
        "createdAt" : "2026-09-01T09:00:00Z",
        "floors" : [
          {
            "allowedServers" : ["github"],
            "allowedSkills" : ["pdf"],
            "branch" : "main",
            "budgetUSD" : 2,
            "configDirectory" : "/Users/someone/.claude-work",
            "createdAt" : "2026-09-01T09:05:00Z",
            "hires" : ["research", "build"],
            "id" : "11111111-1111-1111-1111-111111111111",
            "jobDirectory" : "/tmp/project/.claude/worktrees/login",
            "lastOutcome" : "completed",
            "lastRequest" : "Fix the login page",
            "model" : "sonnet",
            "name" : "Login Page",
            "nameIsCustom" : true,
            "presetID" : "frontend",
            "purpose" : "Builds screens",
            "queued" : [
              { "continues" : true, "place" : { "branch" : { "_0" : "main" } }, "text" : "and the logout page" },
              { "continues" : false, "place" : { "newWorktree" : { } }, "text" : "try another way" },
              { "continues" : false, "text" : "no place" }
            ],
            "sessionID" : "7e3ba2bb-10c0-4853-a62b-c6d8a0ddd7bd",
            "unseen" : true
          },
          {
            "budgetUSD" : 5,
            "createdAt" : "2026-08-01T09:05:00Z",
            "hires" : [],
            "id" : "22222222-2222-2222-2222-222222222222",
            "name" : "Old floor"
          }
        ],
        "id" : "33333333-3333-3333-3333-333333333333",
        "name" : "project",
        "path" : "/tmp/project",
        "style" : 3,
        "title" : "The Project"
      },
      {
        "createdAt" : "2026-08-01T09:00:00Z",
        "floors" : [],
        "id" : "44444444-4444-4444-4444-444444444444",
        "name" : "old",
        "path" : "/tmp/old",
        "style" : 0
      }
    ]
    """

    static let journal = """
    [
      {
        "budgetUSD" : 5, "buildingID" : "33333333-3333-3333-3333-333333333333", "costUSD" : 0.25,
        "date" : "2026-09-01T10:00:00Z", "duration" : 90, "files" : ["/tmp/project/hello.txt"],
        "floorID" : "11111111-1111-1111-1111-111111111111", "hires" : ["build"], "id" : "55555555-5555-5555-5555-555555555555",
        "outcome" : "completed", "request" : "Write hello", "sessionID" : "abc", "tokens" : 1200, "workingDirectory" : "/tmp/project"
      },
      {
        "budgetUSD" : 1, "date" : "2026-08-01T10:00:00Z", "duration" : 30, "files" : [], "hires" : [],
        "id" : "66666666-6666-6666-6666-666666666666", "outcome" : "cancelled", "request" : "Old job", "workingDirectory" : "/tmp/old"
      }
    ]
    """

    static let floorID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    @Test func aCityFileWithEveryFieldLoads() throws {
        let buildings = try DataFiles.decoder.decode([CityStore.Building].self, from: Data(Self.city.utf8))
        #expect(buildings.map(\.name) == ["project", "old"])
        let floor = try #require(buildings.first?.floors.first)
        #expect(floor.id == Self.floorID)
        #expect(floor.allowedServers == ["github"])
        #expect(floor.allowedSkills == ["pdf"])
        #expect(floor.branch == "main")
        #expect(floor.budgetUSD == 2)
        #expect(floor.configDirectory == "/Users/someone/.claude-work")
        #expect(floor.createdAt == ISO8601DateFormatter().date(from: "2026-09-01T09:05:00Z"))
        #expect(floor.jobDirectory == "/tmp/project/.claude/worktrees/login")
        #expect(floor.lastOutcome == "completed")
        #expect(floor.model == "sonnet")
        #expect(floor.nameIsCustom == true)
        #expect(floor.presetID == "frontend")
        #expect(floor.purpose == "Builds screens")
        #expect(floor.sessionID == "7e3ba2bb-10c0-4853-a62b-c6d8a0ddd7bd")
        #expect(floor.unseen == true)
        #expect(floor.queued == [
            QueuedJob(text: "and the logout page", continues: true, place: .branch("main")),
            QueuedJob(text: "try another way", continues: false, place: .newWorktree),
            QueuedJob(text: "no place", continues: false, place: nil),
        ])
        #expect(buildings[0].title == "The Project")
        #expect(buildings[0].style == 3)
    }

    @Test func aFloorSavedBeforeMostFieldsExistedStillLoads() throws {
        let buildings = try DataFiles.decoder.decode([CityStore.Building].self, from: Data(Self.city.utf8))
        let old = try #require(buildings.first?.floors.last)
        #expect(old.name == "Old floor")
        #expect(old.queued == nil && old.unseen == nil && old.sessionID == nil && old.allowedServers == nil && old.presetID == nil)
        #expect(buildings.last?.title == nil)
    }

    @Test func savingAndLoadingKeepsEverything() throws {
        let buildings = try DataFiles.decoder.decode([CityStore.Building].self, from: Data(Self.city.utf8))
        let url = Scratch.folder("save").appendingPathComponent("nested/city.json")
        DataFiles.save(buildings, to: url)
        #expect(DataFiles.load([CityStore.Building].self, from: url) == buildings)
    }

    /// Renaming a field or making one required breaks everyone's saved city, so the key list is pinned.
    @Test func savedFloorKeysAreStable() throws {
        let floor = CityStore.Floor(name: "n", hires: [], model: "m", budgetUSD: 1, allowedServers: [], allowedSkills: [], lastRequest: "r",
                                    sessionID: "s", lastOutcome: "o", nameIsCustom: true, configDirectory: "c", presetID: "p",
                                    purpose: "p", jobDirectory: "j", branch: "b", unseen: true,
                                    queued: [QueuedJob(text: "t", continues: false, place: .branch("x"))])
        let json = try #require(try JSONSerialization.jsonObject(with: DataFiles.encoder.encode(floor)) as? [String: Any])
        #expect(Set(json.keys) == ["id", "name", "hires", "model", "budgetUSD", "allowedServers", "allowedSkills", "createdAt", "lastRequest",
                                   "sessionID", "lastOutcome", "nameIsCustom", "configDirectory", "presetID", "purpose", "jobDirectory",
                                   "branch", "unseen", "queued"])
        let building = CityStore.Building(name: "n", path: "/p", style: 0, title: "t")
        let buildingJSON = try #require(try JSONSerialization.jsonObject(with: DataFiles.encoder.encode(building)) as? [String: Any])
        #expect(Set(buildingJSON.keys) == ["id", "name", "path", "style", "floors", "createdAt", "title"])
        #expect(String(decoding: try DataFiles.encoder.encode(JobPlace.branch("main")), as: UTF8.self).filter { !$0.isWhitespace }
                == #"{"branch":{"_0":"main"}}"#)
    }

    @Test func aJournalWithOldAndNewRecordsLoads() throws {
        let records = try DataFiles.decoder.decode([JobRecord].self, from: Data(Self.journal.utf8))
        #expect(records.count == 2)
        #expect(records[0].floorID == Self.floorID)
        #expect(records[0].tokens == 1200)
        #expect(records[0].folderName == "project")
        #expect(records[1].floorID == nil && records[1].costUSD == nil && records[1].sessionID == nil)
    }

    @Test func historyEntriesRoundTrip() throws {
        let entries = [
            HistoryEntry(date: Date(timeIntervalSince1970: 1_800_000_000), job: UUID(), kind: .request, text: "Do it"),
            HistoryEntry(date: Date(timeIntervalSince1970: 1_800_000_100), job: UUID(), kind: .outcome, title: "Delivered", text: "Done."),
        ]
        let data = try DataFiles.encoder.encode(entries)
        #expect(String(decoding: data, as: UTF8.self).contains(#""kind" : "followUp""#) == false)
        #expect(try DataFiles.decoder.decode([HistoryEntry].self, from: data) == entries)
        #expect(try DataFiles.decoder.decode(HistoryEntry.Kind.self, from: Data(#""followUp""#.utf8)) == .followUp)
    }

    @Test func aMissingFileIsNilAndNothingIsCreated() {
        let url = Scratch.folder("missing").appendingPathComponent("city.json")
        #expect(DataFiles.load([CityStore.Building].self, from: url) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func anUnreadableFileIsMovedAsideSoTheNextSaveCantOverwriteIt() throws {
        let folder = Scratch.folder("unreadable")
        let url = folder.appendingPathComponent("city.json")
        try Data("{ not json".utf8).write(to: url)

        #expect(DataFiles.load([CityStore.Building].self, from: url) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let kept = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(kept.count == 1)
        let name = try #require(kept.first)
        #expect(name.hasPrefix("city.unreadable-") && name.hasSuffix(".json") && !name.contains(":"))
        #expect(try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) == "{ not json")
        #expect(DataFiles.unreadable.contains(folder.appendingPathComponent(name)))
    }

    @Test func aFileMissingARequiredKeyIsUnreadableNotEmpty() throws {
        let folder = Scratch.folder("required")
        let url = folder.appendingPathComponent("city.json")
        try Data(#"[{"id":"44444444-4444-4444-4444-444444444444","name":"x","path":"/x","style":0,"floors":[]}]"#.utf8).write(to: url)
        #expect(DataFiles.load([CityStore.Building].self, from: url) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).first?.hasPrefix("city.unreadable-") == true)
    }

    @Test func theJournalKeepsTheLatest200() throws {
        let records = (0..<250).map { i in
            JobRecord(id: UUID(), date: .now, request: "job \(i)", workingDirectory: "/tmp", hires: [], costUSD: nil, budgetUSD: 1,
                      duration: 1, files: [], sessionID: nil, outcome: "completed", buildingID: nil, floorID: nil, tokens: nil)
        }
        let saved = CityStore.shared.journal
        defer { JobJournal.save(saved) }
        JobJournal.save(records)
        let loaded = JobJournal.load()
        #expect(loaded.count == 200)
        #expect(loaded.first?.request == "job 50")
        #expect(loaded.last?.request == "job 249")
    }

    @Test func totalsAreSavedAsTheirOwnFileAndSeedFromTheJournalOnce() throws {
        let records = try DataFiles.decoder.decode([JobRecord].self, from: Data(Self.journal.utf8))
        let saved = CityStore.shared.totals
        defer { JobTotals.save(saved) }
        try? FileManager.default.removeItem(at: JobTotals.url)

        let seeded = JobTotals.load(seed: records)
        #expect(seeded.count == 1)
        #expect(seeded[Self.floorID] == JobTotals(jobs: 1, succeeded: 1, cancelled: 0, spendUSD: 0.25, tokens: 1200, duration: 90))

        var changed = seeded
        changed[Self.floorID]?.jobs = 7
        JobTotals.save(changed)
        #expect(JobTotals.load(seed: records) == changed)
        #expect(JobTotals.load(seed: []) == changed)
    }
}

struct JobTotalsTests {
    @Test func successRateLeavesCancelledJobsOut() {
        var totals = JobTotals()
        #expect(totals.successRate == nil)
        totals.add(isNew: true, outcome: "cancelled", replacing: nil, costUSD: 0.1, tokens: 10, duration: 5)
        #expect(totals.successRate == nil)
        totals.add(isNew: true, outcome: "completed", replacing: nil, costUSD: 0.2, tokens: 20, duration: 10)
        totals.add(isNew: true, outcome: "failed", replacing: nil, costUSD: 0.3, tokens: 30, duration: 15)
        #expect(totals.successRate == 0.5)
        #expect(totals.jobs == 3)
        #expect(abs(totals.spendUSD - 0.6) < 1e-9)
        #expect(totals.tokens == 60)
        #expect(totals.averageDuration == 10)
    }

    @Test func aFollowUpThatRescuesACancelledJobRescoresIt() {
        var totals = JobTotals()
        totals.add(isNew: true, outcome: "cancelled", replacing: nil, costUSD: 1, tokens: 1, duration: 1)
        totals.add(isNew: false, outcome: "completed", replacing: "cancelled", costUSD: 1, tokens: 1, duration: 1)
        #expect(totals == JobTotals(jobs: 1, succeeded: 1, cancelled: 0, spendUSD: 2, tokens: 2, duration: 2))
        totals.add(isNew: false, outcome: "failed", replacing: "completed", costUSD: 0, tokens: 0, duration: 0)
        #expect(totals.succeeded == 0)
        #expect(totals.successRate == 0)
    }

    @Test func totalsAddUp() {
        let a = JobTotals(jobs: 1, succeeded: 1, cancelled: 0, spendUSD: 1, tokens: 10, duration: 5)
        let b = JobTotals(jobs: 2, succeeded: 0, cancelled: 1, spendUSD: 2, tokens: 20, duration: 7)
        #expect(a + b == JobTotals(jobs: 3, succeeded: 1, cancelled: 1, spendUSD: 3, tokens: 30, duration: 12))
        #expect(a + JobTotals() == a)
    }
}

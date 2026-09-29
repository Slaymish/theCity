import AppKit
import Foundation
import Testing
import OfficeCore
@testable import TheCity

@MainActor
struct OutcomeWordingTests {
    static let gone = RunOutcome.failed(.runError(terminalReason: nil), message: "No conversation found with session ID: abc")

    @Test func titles() {
        #expect(RunController.title(for: .completed(summary: nil, costUSD: nil)) == "Delivered")
        #expect(RunController.title(for: .cancelled(costUSD: nil)) == "Cancelled")
        #expect(RunController.title(for: .failed(.budgetExhausted, message: nil)) == "Budget reached")
        #expect(RunController.title(for: .failed(.processCrashed(code: 1), message: nil)) == "The job stopped")
    }

    @Test func messagesExplainWhatToDoNext() {
        #expect(RunController.message(for: .completed(summary: "Wrote it.", costUSD: 1), budget: 5) == "Wrote it.")
        #expect(RunController.message(for: .completed(summary: nil, costUSD: nil), budget: 5) == "Done.")
        #expect(RunController.message(for: .failed(.budgetExhausted, message: nil), budget: 2) == "The job reached its US$2.00 budget."
                || RunController.message(for: .failed(.budgetExhausted, message: nil), budget: 2) == "The job reached its $2.00 budget.")
        #expect(RunController.message(for: .failed(.runError(terminalReason: nil), message: "Boom"), budget: 5) == "Boom")
        #expect(RunController.message(for: .failed(.processCrashed(code: 9), message: "oops"), budget: 5) == "Claude Code stopped without finishing (exit 9). oops")
        #expect(RunController.message(for: .failed(.couldNotStart, message: "no folder"), budget: 5) == "Claude Code couldn’t start: no folder")
        #expect(RunController.message(for: Self.gone, budget: 5).hasPrefix("This floor’s last session is gone."))
        #expect(RunController.message(for: .failed(.notLoggedIn, message: nil), budget: 5).contains("not signed in"))
    }

    @Test func onlyAMissingConversationForgetsTheSession() {
        #expect(RunController.sessionIsGone(Self.gone))
        #expect(!RunController.sessionIsGone(.failed(.runError(terminalReason: nil), message: "Rate limited")))
        #expect(!RunController.sessionIsGone(.failed(.runError(terminalReason: nil), message: nil)))
        #expect(!RunController.sessionIsGone(.cancelled(costUSD: nil)))
    }

    @Test func shellQuotingSurvivesQuotes() throws {
        let quoted = RunController.shellQuoted("it's a \"path\" with $HOME")
        #expect(quoted == #"'it'\''s a "path" with $HOME'"#)
        let echo = Process()
        echo.executableURL = URL(fileURLWithPath: "/bin/sh")
        echo.arguments = ["-c", "printf %s \(quoted)"]
        let pipe = Pipe()
        echo.standardOutput = pipe
        try echo.run()
        echo.waitUntilExit()
        #expect(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "it's a \"path\" with $HOME")
    }
}

@MainActor
struct WordingTests {
    @Test func toolsReadAsVerbs() {
        #expect(Wording.verb("Read") == "Reading")
        #expect(Wording.verb("Grep") == "Searching")
        #expect(Wording.verb("MultiEdit") == "Writing")
        #expect(Wording.verb("Bash") == "Running a command")
        #expect(Wording.verb("Task") == "Delegating")
        #expect(Wording.verb("mcp__github__create_issue") == "Calling github")
        #expect(Wording.verb("mcp__plugin_x_y__do") .hasPrefix("Calling "))
        #expect(Wording.verb("SomethingNew") == "SomethingNew")
    }

    @Test func serverNamesAreShortened() {
        #expect(OfficeScene.shortName("claude.ai Gmail") == "Gmail")
        #expect(OfficeScene.shortName("plugin:chrome-devtools-mcp:chrome-devtools") == "chrome-devtools")
        #expect(OfficeScene.shortName("github") == "github")
    }

    @Test func clocksRoundToTheSecond() {
        #expect(Wording.clock(0) == "0:00")
        #expect(Wording.clock(59.6) == "1:00")
        #expect(Wording.clock(61) == "1:01")
        #expect(Wording.clock(3600) == "60:00")
    }

    @Test func accountNamesComeFromTheirFolders() {
        #expect(Preferences.accountName(nil) == "Default")
        #expect(Preferences.accountName(URL(fileURLWithPath: "/Users/x/.claude")) == "Default")
        #expect(Preferences.accountName(URL(fileURLWithPath: "/Users/x/.claude-work-stuff")) == "Work Stuff")
    }

    @Test func statusFormats() {
        #expect(StatusFormat.jobs(1) == "1 job")
        #expect(StatusFormat.jobs(2) == "2 jobs")
        #expect(StatusFormat.dollars(1.5, onPlan: true).hasSuffix(" API-equivalent"))
        #expect(!StatusFormat.dollars(1.5).contains("API"))
        #expect(StatusFormat.spend(2, tokens: 1500, onPlan: true).hasSuffix(" tokens"))
        #expect(StatusFormat.spend(2, tokens: 1500, onPlan: false) == StatusFormat.dollars(2))
    }

    @Test func floorNamerCleansUpHaikusAnswer() {
        #expect(FloorNamer.usable("“Login Page Fixes.”\nBecause it fixes things", existing: []) == "Login Page Fixes")
        #expect(FloorNamer.usable("'Docs'", existing: ["Docs"]) == "Docs 2")
        #expect(FloorNamer.usable("   ", existing: []) == nil)
        #expect(FloorNamer.usable(String(repeating: "x", count: 41), existing: []) == nil)
    }

    @Test func graphicsLevelsAreNamedCaseInsensitively() {
        #expect(GraphicsQuality.named("ULTRA") == .ultra)
        #expect(GraphicsQuality.named("low") == .low)
        #expect(GraphicsQuality.named("max") == nil)
        #expect(!GraphicsQuality.low.depthOfField && GraphicsQuality.low.focus == nil)
        #expect(GraphicsQuality.allCases.dropFirst().allSatisfy { $0.depthOfField && $0.focus != nil })
    }
}

@MainActor
struct TimingTests {
    @Test func waitingIsTakenOffWorkingTime() {
        let start = Date(timeIntervalSince1970: 1000)
        var timing = HandoffTiming(startedAt: start)
        #expect(timing.worked(now: start.addingTimeInterval(10)) == 10)
        timing.waitingSince = start.addingTimeInterval(4)
        #expect(timing.waiting(now: start.addingTimeInterval(10)) == 6)
        #expect(timing.worked(now: start.addingTimeInterval(10)) == 4)
        timing.waited = 6
        timing.waitingSince = nil
        timing.endedAt = start.addingTimeInterval(20)
        #expect(timing.worked(now: start.addingTimeInterval(99)) == 14)
        #expect(HandoffTiming().worked(now: start) == 0)
    }

    @Test func stepsAddTheirRunningTime() {
        let now = Date(timeIntervalSince1970: 1000)
        let step = Step(room: "build", colour: .white, isContractor: false, status: .working, workedFor: 5, startedAt: now.addingTimeInterval(-3))
        #expect(StepPill.worked(step, now: now) == 8)
    }

    @Test func longLogLinesArePreviewedNotLaidOutInFull() {
        let long = LogEntry(elapsed: 0, kind: .app, text: String(repeating: "a", count: 700))
        #expect(long.preview.count == 601)
        #expect(long.preview.hasSuffix("…"))
        #expect(LogEntry(elapsed: 0, kind: .app, text: "short").preview == "short")
    }
}

@MainActor
struct SceneMathsTests {
    @Test func daylightEasesThroughDawnAndDusk() {
        #expect(DayCycle(hour: 3).daylight == 0)
        #expect(DayCycle(hour: 6).daylight == 0)
        #expect(DayCycle(hour: 6.5).daylight == 0.5)
        #expect(DayCycle(hour: 7).daylight == 1)
        #expect(DayCycle(hour: 13).daylight == 1)
        #expect(DayCycle(hour: 18).daylight == 1)
        #expect(DayCycle(hour: 18.75).daylight == 0.5)
        #expect(DayCycle(hour: 19.5).daylight == 0)
        #expect(DayCycle(hour: 23).daylight == 0)
        #expect(DayCycle(hour: 6.25).daylight < DayCycle(hour: 6.75).daylight)
    }

    @Test func lampsComeOnBeforeFullDark() {
        #expect(DayCycle(hour: 13).lamps == 0)
        #expect(DayCycle(hour: 18.75).lamps == 1)
        #expect(DayCycle(hour: 2).lamps == 1)
        #expect(DayCycle(hour: 6.5).twilight == 1)
        #expect(DayCycle(hour: 13).twilight == 0)
        #expect(DayCycle(hour: 13).mix(day: 2, night: -3) == 2)
        #expect(DayCycle(hour: 1).mix(day: 2, night: -3) == -3)
    }

    @Test func theSunIsHighestAtNoonAndTheMoonTakesOverAtNight() {
        let midday: SIMD3<Float> = [0, 10, 5]
        let noon = DayCycle(hour: 12.75).sun(midday)
        #expect(abs(noon.y - 10) < 0.001)
        #expect(DayCycle(hour: 8).sun(midday).y < noon.y)
        #expect(DayCycle(hour: 2).sun(midday) == [0, 9, -5])
    }

    @Test func seededRandomnessRepeats() {
        var a = SeededGenerator(seed: 42), b = SeededGenerator(seed: 42), c = SeededGenerator(seed: 43)
        let first = (0..<5).map { _ in a.next() }
        #expect(first == (0..<5).map { _ in b.next() })
        #expect(first != (0..<5).map { _ in c.next() })
        #expect(Set(first).count == 5)
    }

    @Test func theCameraSpringSettlesWithoutOvershooting() {
        var velocity: Float = 0, value: Float = 0
        var previous = value
        for _ in 0..<300 {
            value = CameraRig.damp(value, 10, &velocity, 0.3, 1 / 60)
            #expect(value >= previous && value <= 10)
            previous = value
        }
        #expect(abs(value - 10) < 0.01)
        #expect(5.clamped(to: 0...3) == 3)
        #expect((-1).clamped(to: 0...3) == 0)
    }
}

@MainActor
struct BrandTests {
    static var bundled: [Brand] {
        get throws {
            let folder = try #require(Bundle.main.url(forResource: "Brands", withExtension: nil))
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter(\.hasDirectoryPath).map {
                try JSONDecoder().decode(Brand.self, from: Data(contentsOf: $0.appendingPathComponent("brand.json")))
            }
        }
    }

    @Test func everyBundledBrandLoads() throws {
        let brands = try Self.bundled
        #expect(Set(brands.map(\.id)).isSuperset(of: ["the-city", "alphero"]))
        for brand in brands {
            #expect(!brand.departments.isEmpty, "\(brand.id) has no department colours")
            for colour in [brand.light.background, brand.light.text, brand.manager, brand.onAccent] + brand.departments {
                #expect(colour.hasPrefix("#") && [7, 9].contains(colour.count), "\(brand.id): \(colour)")
            }
        }
    }

    @Test func theFallbackMatchesTheBundledCityBrand() throws {
        let city = try #require(try Self.bundled.first { $0.id == "the-city" })
        #expect(Brand.fallback.light == city.light)
        #expect(Brand.fallback.departments == city.departments)
        #expect(Brand.fallback.manager == city.manager)
        #expect(Brand.fallback.name == city.name)
    }

    @Test func aBrandWithoutDarkOrGrassFallsBack() throws {
        var brand = Brand.fallback
        brand.light.grass = nil
        brand.light.cloud = nil
        #expect(!brand.supportsDark)
        #expect(brand.tokens(dark: true) == brand.tokens(dark: false))
        #expect(brand.tokens(dark: true).grass == Brand.defaultGrass.light)
        var dark = brand.light
        dark.background = "#000000"
        brand.dark = dark
        #expect(brand.tokens(dark: true).background == "#000000")
        #expect(brand.tokens(dark: true).grass == Brand.defaultGrass.dark)
        #expect(brand.tokens(dark: false).cloud == Brand.defaultCloud.light)
    }

    @Test func hexColoursReadWithAndWithoutAlpha() {
        let solid = NSColor(hex: "#FF8000")
        #expect(solid.redComponent == 1 && abs(solid.greenComponent - 128 / 255) < 0.001 && solid.blueComponent == 0 && solid.alphaComponent == 1)
        let clear = NSColor(hex: "#00000080")
        #expect(abs(clear.alphaComponent - 128 / 255) < 0.001)
    }
}

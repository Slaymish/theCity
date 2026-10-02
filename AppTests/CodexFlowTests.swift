import Foundation
import Testing
import OfficeCore
@testable import TheCity

extension WithFakeCLI {
    @Suite
    @MainActor
    struct CodexFlowTests {
        @Test func codexRunsApprovalsAndFollowUpsAndProviderSwitchClearsTheSession() async throws {
            let claude = try FakeCLI()
            let directory = Scratch.folder("codex")
            let executable = directory.appendingPathComponent("codex")
            let script = #"""
            #!/usr/bin/python3
            import json, sys
            def send(data):
                print(json.dumps(data), flush=True)
            for line in sys.stdin:
                msg = json.loads(line)
                method = msg.get('method')
                ident = msg.get('id')
                if method == 'initialize':
                    send({'id': ident, 'result': {}})
                elif method == 'account/read':
                    send({'id': ident, 'result': {'account': {'type': 'chatgpt'}, 'requiresOpenaiAuth': True}})
                elif method == 'model/list':
                    send({'id': ident, 'result': {'data': [{'model': 'test-codex', 'displayName': 'Test Codex'}]}})
                elif method in ('thread/start', 'thread/resume'):
                    send({'id': ident, 'result': {'thread': {'id': msg['params'].get('threadId', 'codex-test-thread')}, 'model': 'test-codex'}})
                elif method == 'turn/start':
                    send({'id': ident, 'result': {'turn': {'id': 'turn-1', 'status': 'inProgress'}}})
                    send({'id': 88, 'method': 'item/commandExecution/requestApproval', 'params': {'itemId': 'cmd-1', 'command': 'make test'}})
                elif ident == 88:
                    if msg.get('result', {}).get('decision') != 'accept':
                        sys.exit(2)
                    send({'method': 'item/completed', 'params': {'item': {'id': 'reply-1', 'type': 'agentMessage', 'phase': 'final_answer', 'text': 'Codex finished'}}})
                    send({'method': 'turn/completed', 'params': {'turn': {'status': 'completed'}}})
            """#
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let previousProvider = Preferences.shared.provider
            Preferences.shared.provider = .codex
            Preferences.shared.codexCLIPath = executable.path
            defer { Preferences.shared.provider = previousProvider; Preferences.shared.codexCLIPath = nil }
            let floor = try TestFloor(request: "Test Codex", hires: [])
            #expect(floor.floor?.provider == .codex)
            #expect(await eventually("Codex approval") { !floor.session.state.pendingRequests.isEmpty })
            let approval = try #require(floor.session.state.pendingRequests.first)
            floor.session.allow(approval)
            #expect(await floor.finished())
            #expect(floor.session.canContinue)
            #expect(floor.session.state.sessionID == "codex-test-thread")
            #expect(floor.session.kit?.models.first?.value == "test-codex")
            floor.session.followUp("Continue")
            #expect(await eventually("follow-up approval") { !floor.session.state.pendingRequests.isEmpty })
            let next = try #require(floor.session.state.pendingRequests.first)
            floor.session.allow(next)
            #expect(await floor.finished())
            #expect(floor.session.state.sessionID == "codex-test-thread")
            floor.session.setProvider(.claude)
            #expect(!floor.session.canContinue)
            #expect(floor.floor?.provider == .claude)
            #expect(floor.floor?.sessionID == nil)
            #expect(claude.jobs.isEmpty)
        }

        @Test func olderFloorsKeepClaudeEvenWhenCodexIsTheDefault() throws {
            let _ = try FakeCLI()
            let old = Preferences.shared.provider
            Preferences.shared.provider = .codex
            defer { Preferences.shared.provider = old }
            let building = CityStore.Building(name: "Legacy", path: Scratch.folder().path, style: 0)
            let floor = CityStore.Floor(name: "Old floor", hires: [], model: "sonnet", budgetUSD: 5, sessionID: "claude-session")
            let session = RunController(building: building, floor: floor)
            #expect(session.provider == .claude)
            #expect(session.model == "sonnet")
            #expect(session.canContinue)
        }
    }
}

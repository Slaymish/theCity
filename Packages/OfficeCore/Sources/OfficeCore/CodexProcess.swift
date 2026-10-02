import Foundation

#if os(macOS)
public final class CodexProcess: AgentProcess, @unchecked Sendable {
    public let output: AsyncStream<RunnerOutput>
    private let transport: ClaudeProcess
    private let lock = NSLock()
    private var protocolState: CodexProtocol

    public init(executable: URL, config: RunConfig, environment: [String: String]) throws {
        protocolState = CodexProtocol(config: config)
        transport = try ClaudeProcess(executable: executable, arguments: ["app-server"], environment: environment,
                                      workingDirectory: config.workingDirectory, keepInputOpen: true)
        let (stream, continuation) = AsyncStream.makeStream(of: RunnerOutput.self)
        output = stream
        transport.send(CodexProtocol.initialize)
        Task { [self] in
            var index = 0
            for await output in transport.output {
                switch output {
                case .line(let line):
                    let update = lock.withLock { protocolState.receive(line.raw) }
                    for message in update.messages { transport.send(message) }
                    for event in update.events {
                        continuation.yield(.line(StreamLine(index: index, raw: line.raw, parsed: .event(event))))
                        index += 1
                    }
                    if update.finished { transport.closeInput() }
                case .exited:
                    continuation.yield(output)
                }
            }
            continuation.finish()
        }
    }
    @discardableResult public func send(_ line: Data) -> Bool {
        guard let response = lock.withLock({ protocolState.respond(line) }) else { return false }
        return transport.send(response)
    }
    public func closeInput() { transport.closeInput() }
    public func cancel() { transport.cancel() }
}
#endif

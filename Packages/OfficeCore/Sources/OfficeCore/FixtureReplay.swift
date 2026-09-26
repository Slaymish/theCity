import Foundation

public enum FixtureReplay {
    public static func stream(contentsOf url: URL, interval: Duration = .milliseconds(350)) throws -> AsyncStream<RunnerOutput> {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return AsyncStream { continuation in
            let task = Task.detached {
                for (index, raw) in lines.enumerated() {
                    try? await Task.sleep(for: interval)
                    if Task.isCancelled { break }
                    continuation.yield(.line(StreamParser.parse(raw, index: index)))
                }
                continuation.yield(.exited(code: 0, stderr: ""))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

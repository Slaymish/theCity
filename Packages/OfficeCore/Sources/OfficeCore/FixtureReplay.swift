import Foundation

public enum FixtureReplay {
    public static func stream(contentsOf url: URL, workingDirectory: URL? = nil,
                              interval: Duration = .milliseconds(350)) throws -> AsyncStream<RunnerOutput> {
        let lines = relocated(try String(contentsOf: url, encoding: .utf8), to: workingDirectory)
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

    static func relocated(_ text: String, to workingDirectory: URL?) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let workingDirectory,
              let initLine = lines.first(where: { $0.contains(#""subtype":"init""#) }),
              let data = initLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recorded = json["cwd"] as? String, recorded != workingDirectory.path else { return lines }
        return lines.map { $0.replacingOccurrences(of: recorded, with: workingDirectory.path) }
    }
}

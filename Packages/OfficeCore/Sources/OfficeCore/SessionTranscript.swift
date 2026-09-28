import Foundation

/// Reads the transcript Claude Code saves for an interactive session, so work done in the kiosk can join the floor's history.
public enum SessionTranscript {
    public struct Turn: Equatable, Sendable {
        public var date: Date
        public var prompt: String
        public var reply: String?

        public init(date: Date, prompt: String, reply: String? = nil) {
            self.date = date
            self.prompt = prompt
            self.reply = reply
        }
    }

    /// Transcripts sit in `<config>/projects/<encoded folder>/<session>.jsonl`; the folder encoding isn't documented, so this searches.
    public static func file(for sessionID: String, configDirectory: URL?, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let config = configDirectory
            ?? environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let projects = config.appendingPathComponent("projects")
        let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return folders.lazy
            .map { $0.appendingPathComponent("\(sessionID).jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The prompts typed from `since` on, each with the last text Claude replied before the next prompt.
    public static func turns(in data: Data, since: Date) -> [Turn] {
        var turns: [Turn] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["isSidechain"] as? Bool != true, object["isMeta"] as? Bool != true,
                  let stamp = object["timestamp"] as? String, let date = parseDate(stamp), date >= since,
                  let message = object["message"] as? [String: Any] else { continue }
            switch object["type"] as? String {
            case "user":
                guard let prompt = text(of: message["content"]), !prompt.hasPrefix("<") else { continue }
                turns.append(Turn(date: date, prompt: prompt))
            case "assistant":
                guard !turns.isEmpty, let reply = text(of: message["content"]) else { continue }
                turns[turns.count - 1].reply = reply
            default:
                continue
            }
        }
        return turns
    }

    private static func text(of content: Any?) -> String? {
        let text: String
        if let string = content as? String {
            text = string
        } else if let blocks = content as? [[String: Any]] {
            text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseDate(_ text: String) -> Date? {
        (try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: .iso8601))
    }
}

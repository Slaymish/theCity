import Foundation

/// The city's saved files: one folder (`-data <dir>` gives a dev build its own), read and written only through here.
enum DataFiles {
    static let directory: URL = LaunchArgument.value("-data").map { URL(fileURLWithPath: $0) }
        ?? (TestHost.isActive ? FileManager.default.temporaryDirectory.appendingPathComponent("TheCityTests-\(UUID().uuidString)") : nil)
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("The City")

    /// Renders load the real city to draw it, but must never write it back over the running app's.
    private static let isReadOnly = ["-render-preview", "-render-icon", "-render-reel"].contains { ProcessInfo.processInfo.arguments.contains($0) }

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Nil when there's no file yet. A file that won't decode is moved aside first, so the next save can't overwrite it.
    static func load<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder = decoder) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            NSLog("The City couldn't read \(url.path): \(error)")
            guard !isReadOnly else { return nil }
            let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
            let kept = url.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: url, to: kept)
            unreadable.append(kept)
            return nil
        }
    }

    static func save<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder = encoder) {
        guard !isReadOnly, let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Files set aside this launch, for the city to tell the user about.
    nonisolated(unsafe) private(set) static var unreadable: [URL] = []
}

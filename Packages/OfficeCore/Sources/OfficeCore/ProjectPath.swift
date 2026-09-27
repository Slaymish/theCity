import Foundation

public enum ProjectPath {
    public static func relative(_ path: String, to directory: URL?) -> String {
        guard let directory else { return path }
        let file = canonical(path), base = canonical(directory.path)
        guard file.hasPrefix(base + "/") else { return path }
        return String(file.dropFirst(base.count + 1))
    }

    /// Foundation only drops `/private` from paths that exist, so strip it by hand too.
    static func canonical(_ path: String) -> String {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        for root in ["/private/tmp", "/private/var", "/private/etc"] where resolved == root || resolved.hasPrefix(root + "/") {
            return String(resolved.dropFirst("/private".count))
        }
        return resolved
    }
}

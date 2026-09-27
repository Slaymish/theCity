import Foundation

/// Carries data over from when the app was called The Office (`nz.hamish.theoffice`).
enum LegacyData {
    static func migrate() {
        let files = FileManager.default
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appendingPathComponent("The Office"), new = support.appendingPathComponent("The City")
        if files.fileExists(atPath: old.path), !files.fileExists(atPath: new.path) {
            try? files.moveItem(at: old, to: new)
        }

        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromTheOffice") else { return }
        for (key, value) in defaults.persistentDomain(forName: "nz.hamish.theoffice") ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        if defaults.string(forKey: "brand") == "the-office" { defaults.set("the-city", forKey: "brand") }
        defaults.set(true, forKey: "migratedFromTheOffice")
    }
}

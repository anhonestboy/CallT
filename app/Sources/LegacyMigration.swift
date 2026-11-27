import Foundation

/// L'app si chiamava CallT (bundle com.werootbox.callt). Al primo avvio come
/// Recap importa impostazioni e registro dei file elaborati, così non si
/// perde nulla. Le chiavi API nel Portachiavi vengono riprese al primo uso
/// (vedi KeychainStore): macOS può chiedere una volta il permesso.
enum LegacyMigration {
    static let legacyBundleID = "com.werootbox.callt"
    private static let doneKey = "migratedFromCallT"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }

        if let old = defaults.persistentDomain(forName: legacyBundleID), !old.isEmpty {
            let current = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
            var imported = 0
            for (key, value) in old where current[key] == nil {
                defaults.set(value, forKey: key)
                imported += 1
            }
            appLog("↪︎ Imported \(imported) settings from CallT")
        }

        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldDir = base.appendingPathComponent("CallT", isDirectory: true)
        let newDir = base.appendingPathComponent("Recap", isDirectory: true)
        let oldRegistry = oldDir.appendingPathComponent("registry.json")
        let newRegistry = newDir.appendingPathComponent("registry.json")
        if fm.fileExists(atPath: oldRegistry.path), !fm.fileExists(atPath: newRegistry.path) {
            try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)
            if (try? fm.copyItem(at: oldRegistry, to: newRegistry)) != nil {
                appLog("↪︎ Imported the processed-files registry from CallT")
            }
        }
    }
}

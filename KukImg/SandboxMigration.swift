import Foundation

/// Up to 1.7 Kuk ran sandboxed, so its preferences and content index live in
/// the app container. The first launch without the sandbox copies them to the
/// regular locations; the container itself is left untouched.
nonisolated enum SandboxMigration {
    private static let doneKey = "migratedFromSandboxContainer"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey),
              let bundleID = Bundle.main.bundleIdentifier else { return }
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(bundleID)/Data/Library", isDirectory: true)
        migratePreferences(
            from: library.appendingPathComponent("Preferences/\(bundleID).plist"),
            bundleID: bundleID
        )
        migrateContentIndex(
            from: library.appendingPathComponent("Application Support/Kuk/ContentIndex.json"),
            to: ContentIndex.defaultStoreURL,
            oldPhotosCache: library.appendingPathComponent("Caches/Kuk/Photos", isDirectory: true),
            newPhotosCache: PhotosMaterializer.cacheRoot
        )
        defaults.set(true, forKey: doneKey)
    }

    /// Copies every stored setting that the new location doesn't have yet.
    private static func migratePreferences(from plist: URL, bundleID: String) {
        guard let old = NSDictionary(contentsOf: plist) as? [String: Any] else { return }
        let defaults = UserDefaults.standard
        let current = defaults.persistentDomain(forName: bundleID) ?? [:]
        for (key, value) in old where current[key] == nil {
            defaults.set(value, forKey: key)
        }
    }

    /// Moves the index over. Photos records are keyed by their path in the
    /// export cache, which moves out of the container too; rewriting the
    /// prefix keeps them instead of re-analyzing the whole library.
    static func migrateContentIndex(from source: URL, to destination: URL, oldPhotosCache: URL, newPhotosCache: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path),
              let data = try? Data(contentsOf: source),
              var json = String(data: data, encoding: .utf8) else { return }
        let oldPrefix = oldPhotosCache.path + "/"
        let newPrefix = newPhotosCache.path + "/"
        // JSONEncoder writes slashes escaped ("\/").
        func escaped(_ path: String) -> String { path.replacingOccurrences(of: "/", with: "\\/") }
        json = json.replacingOccurrences(of: escaped(oldPrefix), with: escaped(newPrefix))
        json = json.replacingOccurrences(of: oldPrefix, with: newPrefix)
        try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(json.utf8).write(to: destination, options: .atomic)
    }
}

nonisolated enum AppEnvironment {
    /// True inside the unit-test host: the app then skips work that touches
    /// the user's data (migration, restoring folders, content indexing,
    /// update checks).
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}

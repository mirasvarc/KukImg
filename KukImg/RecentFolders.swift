import Foundation

struct RecentFolder: Codable, Identifiable, Hashable, Sendable {
    let bookmark: Data
    let path: String
    let name: String
    let lastOpened: Date
    var id: String { path }
}

nonisolated enum RecentFolders {
    private static let key = "recentFolders"
    private static let maxCount = 10

    static func all() -> [RecentFolder] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([RecentFolder].self, from: data)
        else { return [] }
        return list
    }

    @discardableResult
    static func add(_ url: URL) -> [RecentFolder] {
        // A plain bookmark still follows the folder when it is moved or renamed.
        let bookmark = (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? Data()
        var list = all().filter { $0.path != url.path }
        list.insert(
            RecentFolder(
                bookmark: bookmark,
                path: url.path,
                name: url.lastPathComponent,
                lastOpened: Date()
            ),
            at: 0
        )
        if list.count > maxCount { list = Array(list.prefix(maxCount)) }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
        return list
    }

    @discardableResult
    static func remove(_ recent: RecentFolder) -> [RecentFolder] {
        let list = all().filter { $0.path != recent.path }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
        return list
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Follows the bookmark (security-scoped ones from the sandboxed versions
    /// resolve too), falling back to the stored path.
    static func resolve(_ recent: RecentFolder) -> URL? {
        var stale = false
        if let url = try? URL(
            resolvingBookmarkData: recent.bookmark,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) {
            return url
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: recent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: recent.path, isDirectory: true)
    }
}

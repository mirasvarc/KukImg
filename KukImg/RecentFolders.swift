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
        guard let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return all() }
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

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func resolve(_ recent: RecentFolder) -> URL? {
        var stale = false
        return try? URL(
            resolvingBookmarkData: recent.bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }
}

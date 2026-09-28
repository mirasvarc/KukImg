import Foundation
import UniformTypeIdentifiers

/// Walks the folder trees of the open roots in sidebar order (depth-first,
/// subfolders sorted like Finder) to find the next or previous folder worth
/// showing, so a whole tree can be browsed from the keyboard.
nonisolated enum FolderNavigator {
    /// - Parameters:
    ///   - descend: step into subfolders (off when the grid already includes
    ///     them, then only siblings and ancestors' siblings are visited).
    /// - Returns: the next folder that has images, nil at the end.
    static func step(from current: URL, roots: [URL], forward: Bool, descend: Bool) -> URL? {
        var walker = Walker(roots: roots, descend: descend)
        var node = current
        // Bounded so a pathological tree can't stall the search.
        for _ in 0..<5000 {
            if Task.isCancelled { return nil }
            guard let next = forward ? walker.successor(of: node) : walker.predecessor(of: node) else {
                return nil
            }
            let hasImages = descend
                ? FolderListing.containsImagesDirectly(next)
                : FolderIndex.subtreeContainsImages(next)
            if hasImages { return next }
            node = next
        }
        return nil
    }

    private struct Walker {
        let roots: [URL]
        let descend: Bool
        private var listings: [String: [URL]] = [:]

        init(roots: [URL], descend: Bool) {
            self.roots = roots
            self.descend = descend
        }

        mutating func subfolders(of url: URL) -> [URL] {
            if let cached = listings[url.path] { return cached }
            let list = FolderListing.subfolders(of: url)
            listings[url.path] = list
            return list
        }

        func isRoot(_ url: URL) -> Int? {
            roots.firstIndex { $0.path == url.path }
        }

        func isInsideRoot(_ url: URL) -> Bool {
            roots.contains { url.path == $0.path || url.path.hasPrefix($0.path + "/") }
        }

        mutating func successor(of url: URL) -> URL? {
            if descend, let first = subfolders(of: url).first { return first }
            var node = url
            while isInsideRoot(node) {
                if let rootIndex = isRoot(node) {
                    return rootIndex + 1 < roots.count ? roots[rootIndex + 1] : nil
                }
                let parent = node.deletingLastPathComponent()
                let siblings = subfolders(of: parent)
                if let i = siblings.firstIndex(where: { $0.path == node.path }), i + 1 < siblings.count {
                    return siblings[i + 1]
                }
                node = parent
            }
            return nil
        }

        mutating func predecessor(of url: URL) -> URL? {
            if let rootIndex = isRoot(url) {
                return rootIndex > 0 ? deepestLast(roots[rootIndex - 1]) : nil
            }
            guard isInsideRoot(url) else { return nil }
            let parent = url.deletingLastPathComponent()
            let siblings = subfolders(of: parent)
            if let i = siblings.firstIndex(where: { $0.path == url.path }), i > 0 {
                return deepestLast(siblings[i - 1])
            }
            return parent
        }

        /// The last folder of `url`'s subtree in depth-first order.
        private mutating func deepestLast(_ url: URL) -> URL {
            guard descend else { return url }
            var node = url
            for _ in 0..<64 {
                guard let last = subfolders(of: node).last else { break }
                node = last
            }
            return node
        }
    }
}

nonisolated enum FolderListing {
    /// Visible, non-package subfolders sorted like the sidebar shows them.
    static func subfolders(of url: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        return contents
            .filter { item in
                let values = try? item.resourceValues(forKeys: Set(keys))
                return values?.isDirectory == true && values?.isPackage != true
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
    }

    /// Stops at the first image directly inside `url`.
    static func containsImagesDirectly(_ url: URL) -> Bool {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentTypeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
        ) else { return false }
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  values.contentType?.conforms(to: .image) == true
            else { continue }
            return true
        }
        return false
    }
}

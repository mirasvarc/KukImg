import SwiftUI
import AppKit
import UniformTypeIdentifiers

nonisolated struct ImageItem: Identifiable, Hashable, Sendable {
    let url: URL
    let modifiedAt: Date
    let fileSize: Int64
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

enum SortOrder: String, CaseIterable, Codable, Sendable {
    case nameAsc, nameDesc, modifiedDesc, modifiedAsc, sizeDesc, sizeAsc

    var label: String {
        switch self {
        case .nameAsc:      "Name (A → Z)"
        case .nameDesc:     "Name (Z → A)"
        case .modifiedDesc: "Newest First"
        case .modifiedAsc:  "Oldest First"
        case .sizeDesc:     "Largest First"
        case .sizeAsc:      "Smallest First"
        }
    }
}

@Observable
final class AppModel {
    var folder: URL?
    var items: [ImageItem] = []
    var selection: ImageItem.ID?
    var isLoading = false
    var isFullscreen = false
    var showInfoPanel = false
    var sortOrder: SortOrder {
        didSet {
            UserDefaults.standard.set(sortOrder.rawValue, forKey: "sortOrder")
            applySort()
        }
    }
    var recents: [RecentFolder] = []

    private var accessedURL: URL?

    init() {
        let raw = UserDefaults.standard.string(forKey: "sortOrder") ?? SortOrder.nameAsc.rawValue
        self.sortOrder = SortOrder(rawValue: raw) ?? .nameAsc
        self.recents = RecentFolders.all()
    }

    deinit {
        accessedURL?.stopAccessingSecurityScopedResource()
    }

    var currentItem: ImageItem? {
        guard let id = selection else { return nil }
        return items.first(where: { $0.id == id })
    }

    var currentIndex: Int? {
        guard let id = selection else { return nil }
        return items.firstIndex(where: { $0.id == id })
    }

    // MARK: - Navigation

    func move(by offset: Int) {
        guard !items.isEmpty else { return }
        let cur = currentIndex ?? 0
        let new = (cur + offset).clamped(to: 0...(items.count - 1))
        selection = items[new].id
    }

    func selectFirst() { selection = items.first?.id }
    func selectLast()  { selection = items.last?.id }

    // MARK: - Folders

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(folder: url, isSecurityScoped: false)
    }

    func restoreLastFolder() {
        guard folder == nil,
              let recent = recents.first,
              let url = RecentFolders.resolve(recent) else { return }
        load(folder: url, isSecurityScoped: true)
    }

    func openRecent(_ recent: RecentFolder) {
        guard let url = RecentFolders.resolve(recent) else { return }
        load(folder: url, isSecurityScoped: true)
    }

    func clearRecents() {
        RecentFolders.clear()
        recents = []
    }

    func handleDroppedFolder(_ url: URL) {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return }
        load(folder: url, isSecurityScoped: false)
    }

    func load(folder url: URL, isSecurityScoped: Bool) {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
        if isSecurityScoped {
            guard url.startAccessingSecurityScopedResource() else { return }
            accessedURL = url
        }

        recents = RecentFolders.add(url)
        self.folder = url
        self.items = []
        self.selection = nil
        self.isLoading = true

        let order = sortOrder
        Task.detached(priority: .userInitiated) {
            let scanned = ImageScanner.scan(url)
            let sorted = AppModel.sorted(scanned, by: order)
            await MainActor.run {
                self.items = sorted
                self.selection = sorted.first?.id
                self.isLoading = false
            }
        }
    }

    // MARK: - Item operations

    func deleteCurrent() { if let item = currentItem { delete(item) } }
    func revealCurrent() { if let item = currentItem { reveal(item) } }
    func copyCurrent()   { if let item = currentItem { copy(item) } }

    func reveal(_ item: ImageItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func copy(_ item: ImageItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item.url as NSURL])
    }

    func delete(_ item: ImageItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            let wasSelected = selection == item.id
            items.remove(at: idx)
            if wasSelected {
                selection = items.isEmpty ? nil : items[min(idx, items.count - 1)].id
            }
        } catch {
            NSSound.beep()
        }
    }

    // MARK: - Prefetching

    func prefetchNeighbors(thumbSize: CGFloat, scale: CGFloat, radius: Int = 2) {
        guard let center = currentIndex else { return }
        let lo = max(0, center - radius)
        let hi = min(items.count - 1, center + radius)
        guard lo <= hi else { return }
        for i in lo...hi where i != center {
            let url = items[i].url
            Task.detached(priority: .utility) {
                _ = await ThumbnailCache.shared.thumbnail(for: url, pixelSize: thumbSize, scale: scale)
                _ = await ThumbnailCache.shared.thumbnail(for: url, pixelSize: 2048, scale: scale)
            }
        }
    }

    // MARK: - Sorting

    private func applySort() {
        items = Self.sorted(items, by: sortOrder)
    }

    nonisolated static func sorted(_ items: [ImageItem], by order: SortOrder) -> [ImageItem] {
        switch order {
        case .nameAsc:      items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameDesc:     items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .modifiedDesc: items.sorted { $0.modifiedAt > $1.modifiedAt }
        case .modifiedAsc:  items.sorted { $0.modifiedAt < $1.modifiedAt }
        case .sizeDesc:     items.sorted { $0.fileSize > $1.fileSize }
        case .sizeAsc:      items.sorted { $0.fileSize < $1.fileSize }
        }
    }
}

nonisolated enum ImageScanner {
    static func scan(_ url: URL) -> [ImageItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .contentTypeKey,
            .contentModificationDateKey, .fileSizeKey
        ]
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var result: [ImageItem] = []
        result.reserveCapacity(1024)

        for case let fileURL as URL in enumerator {
            // Shallow scan: skip into subfolders. Remove this block to recurse.
            if fileURL.deletingLastPathComponent() != url {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let type = values.contentType,
                  type.conforms(to: .image)
            else { continue }
            let mod = values.contentModificationDate ?? .distantPast
            let size = Int64(values.fileSize ?? 0)
            result.append(ImageItem(url: fileURL, modifiedAt: mod, fileSize: size))
        }
        return result
    }
}

nonisolated extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

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
    var items: [ImageItem] = [] { didSet { updateVisibleItems() } }
    private(set) var visibleItems: [ImageItem] = []
    var selection: ImageItem.ID?
    var isLoading = false
    var isFullscreen = false
    var showInfoPanel = false
    var filterText: String = "" { didSet { updateVisibleItems() } }
    var sortOrder: SortOrder {
        didSet {
            UserDefaults.standard.set(sortOrder.rawValue, forKey: "sortOrder")
            applySort()
        }
    }
    var includeSubfolders: Bool {
        didSet {
            UserDefaults.standard.set(includeSubfolders, forKey: "includeSubfolders")
            rescan()
        }
    }
    var recents: [RecentFolder] = []

    private var accessedURL: URL?
    private let prefetcher = Prefetcher()
    private var scanGeneration = 0
    /// File to select once the next scan finishes (used when an image is dropped).
    private var pendingSelection: URL?

    private var folderMonitor: DispatchSourceFileSystemObject?
    private var rescanDebounce: Task<Void, Never>?

    init() {
        let raw = UserDefaults.standard.string(forKey: "sortOrder") ?? SortOrder.nameAsc.rawValue
        self.sortOrder = SortOrder(rawValue: raw) ?? .nameAsc
        self.includeSubfolders = UserDefaults.standard.bool(forKey: "includeSubfolders")
        self.recents = RecentFolders.all()
    }

    deinit {
        folderMonitor?.cancel()
        accessedURL?.stopAccessingSecurityScopedResource()
    }

    var currentItem: ImageItem? {
        guard let id = selection else { return nil }
        return visibleItems.first(where: { $0.id == id })
    }

    var currentIndex: Int? {
        guard let id = selection else { return nil }
        return visibleItems.firstIndex(where: { $0.id == id })
    }

    // MARK: - Filtering

    private func updateVisibleItems() {
        visibleItems = filterText.isEmpty
            ? items
            : items.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
        if let id = selection, !visibleItems.contains(where: { $0.id == id }) {
            selection = visibleItems.first?.id
        }
    }

    // MARK: - Navigation

    func move(by offset: Int) {
        guard !visibleItems.isEmpty else { return }
        let cur = currentIndex ?? 0
        let new = (cur + offset).clamped(to: 0...(visibleItems.count - 1))
        selection = visibleItems[new].id
    }

    func selectFirst() { selection = visibleItems.first?.id }
    func selectLast()  { selection = visibleItems.last?.id }

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

    func handleDrop(_ url: URL) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
        if values?.isDirectory == true {
            load(folder: url, isSecurityScoped: false)
        } else if values?.contentType?.conforms(to: .image) == true {
            pendingSelection = url
            load(folder: url.deletingLastPathComponent(), isSecurityScoped: false)
        }
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
        prefetcher.cancelAll()
        startMonitoring(url)
        rescan()
    }

    // MARK: - Scanning

    /// Rescans the current folder off the main thread. Keeps the current
    /// selection when the file still exists (used by the folder watcher).
    func rescan() {
        guard let url = folder else { return }
        scanGeneration += 1
        let generation = scanGeneration
        let order = sortOrder
        let recursive = includeSubfolders
        if items.isEmpty { isLoading = true }

        Task.detached(priority: .userInitiated) {
            let scanned = ImageScanner.scan(url, recursive: recursive)
            let sorted = AppModel.sorted(scanned, by: order)
            await MainActor.run {
                guard generation == self.scanGeneration else { return }
                self.applyScanResult(sorted)
            }
        }
    }

    private func applyScanResult(_ sorted: [ImageItem]) {
        var result = sorted
        // A dropped image grants sandbox access to the file, not its folder —
        // if the folder scan came back empty, still show the dropped file.
        if let pending = pendingSelection, result.isEmpty {
            let values = try? pending.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            result = [ImageItem(
                url: pending,
                modifiedAt: values?.contentModificationDate ?? .distantPast,
                fileSize: Int64(values?.fileSize ?? 0)
            )]
        }
        items = result
        isLoading = false
        if let pending = pendingSelection, result.contains(where: { $0.id == pending }) {
            selection = pending
        } else if selection == nil || !result.contains(where: { $0.id == selection }) {
            selection = visibleItems.first?.id
        }
        pendingSelection = nil
    }

    // MARK: - Folder watching

    private func startMonitoring(_ url: URL) {
        folderMonitor?.cancel()
        folderMonitor = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleRescan()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        folderMonitor = source
    }

    private func scheduleRescan() {
        rescanDebounce?.cancel()
        rescanDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.rescan()
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
        let visibleIdx = visibleItems.firstIndex(where: { $0.id == item.id })
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            let wasSelected = selection == item.id
            items.remove(at: idx)
            if wasSelected {
                if visibleItems.isEmpty {
                    selection = nil
                } else if let vIdx = visibleIdx {
                    selection = visibleItems[min(vIdx, visibleItems.count - 1)].id
                } else {
                    selection = visibleItems.first?.id
                }
            }
        } catch {
            NSSound.beep()
        }
    }

    // MARK: - Prefetching

    func prefetchNeighbors(thumbSize: CGFloat, scale: CGFloat) {
        guard let center = currentIndex else { return }
        prefetcher.update(around: center, in: visibleItems, thumbSize: thumbSize, scale: scale)
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

/// Warms the thumbnail/preview caches around the selection and — unlike a
/// fire-and-forget Task per neighbor — cancels work that falls out of the
/// window, so holding an arrow key doesn't queue hundreds of stale decodes.
@MainActor
final class Prefetcher {
    private var tasks: [URL: Task<Void, Never>] = [:]

    func update(around index: Int, in items: [ImageItem], thumbSize: CGFloat, scale: CGFloat) {
        guard items.indices.contains(index) else { return }
        // Bias forward: browsing mostly moves ahead.
        let lo = max(0, index - 1)
        let hi = min(items.count - 1, index + 2)
        let wanted = Set(items[lo...hi].map(\.url)).subtracting([items[index].url])

        for (url, task) in tasks where !wanted.contains(url) {
            task.cancel()
            tasks[url] = nil
        }
        for url in wanted where tasks[url] == nil {
            tasks[url] = Task(priority: .utility) {
                _ = await ThumbnailCache.shared.thumbnail(for: url, pixelSize: thumbSize, scale: scale)
                _ = await ThumbnailCache.shared.thumbnail(for: url, pixelSize: 2048, scale: scale)
            }
        }
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }
}

nonisolated enum ImageScanner {
    static func scan(_ url: URL, recursive: Bool) -> [ImageItem] {
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
            if !recursive, fileURL.deletingLastPathComponent() != url {
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

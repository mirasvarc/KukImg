import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Where an item's pixels come from. Photos assets keep a stable placeholder
/// URL in the app cache; the file only appears once something materializes it
/// (see `ImageLoading.fileURL`), which lets the rest of the app stay URL-based.
nonisolated enum ImageOrigin: Hashable, Sendable {
    case file
    case asset(String)  // PHAsset.localIdentifier
}

nonisolated struct ImageItem: Identifiable, Hashable, Sendable {
    let url: URL
    let modifiedAt: Date
    let fileSize: Int64
    var origin: ImageOrigin = .file
    var id: URL { url }
    var name: String { url.lastPathComponent }

    var isAsset: Bool {
        switch origin {
        case .file: false
        case .asset: true
        }
    }

    var assetIdentifier: String? {
        switch origin {
        case .file: nil
        case .asset(let id): id
        }
    }
}

/// Images sharing a parent folder, used when subfolders are included and the
/// grid is grouped so each folder gets its own labelled section.
nonisolated struct ImageGroup: Identifiable, Hashable, Sendable {
    let folder: URL
    let title: String
    let items: [ImageItem]
    var id: URL { folder }
}

/// A pending "Convert…" sheet. `id` is fresh per request so asking twice for
/// the same images still re-presents the sheet.
nonisolated struct ConvertRequest: Identifiable, Sendable {
    let id = UUID()
    let items: [ImageItem]
}

enum ZoomCommand: Equatable, Sendable { case zoomIn, zoomOut, actualSize, fit }

/// A one-shot zoom request from the menu bar; `id` makes repeated identical
/// commands distinct so `onChange` in DetailView fires every time.
struct ZoomRequest: Equatable, Sendable {
    let command: ZoomCommand
    let id: Int
}

enum SortOrder: String, CaseIterable, Codable, Sendable {
    case nameAsc, nameDesc, modifiedDesc, modifiedAsc, sizeDesc, sizeAsc, dateTakenDesc, dateTakenAsc

    var label: String {
        switch self {
        case .nameAsc:       "Name (A → Z)"
        case .nameDesc:      "Name (Z → A)"
        case .modifiedDesc:  "Newest First"
        case .modifiedAsc:   "Oldest First"
        case .sizeDesc:      "Largest First"
        case .sizeAsc:       "Smallest First"
        case .dateTakenDesc: "Date Taken (Newest)"
        case .dateTakenAsc:  "Date Taken (Oldest)"
        }
    }

    /// These orders need EXIF dates read from the files before sorting.
    var needsDateTaken: Bool { self == .dateTakenDesc || self == .dateTakenAsc }
}

/// Culling flags — session-only, keyed by file URL so they survive switching
/// between folders.
nonisolated enum ImageFlag: String, Sendable {
    case pick, reject
}

nonisolated enum FlagFilter: String, CaseIterable, Sendable {
    case all, picked, rejected

    var label: String {
        switch self {
        case .all:      "All Images"
        case .picked:   "Picked"
        case .rejected: "Rejected"
        }
    }
}

/// A pending "Rename…" sheet; fresh `id` re-presents on repeat requests.
nonisolated struct RenameRequest: Identifiable, Sendable {
    let id = UUID()
    let items: [ImageItem]
}

@Observable
final class AppModel {
    /// Folder whose images are currently shown (a root or any of its subfolders).
    var folder: URL?
    /// Photos album being shown; mutually exclusive with `folder`.
    private(set) var photoAlbum: PhotoAlbum?
    /// Root folders shown as trees in the sidebar.
    private(set) var openFolders: [URL] = []
    var items: [ImageItem] = [] { didSet { updateVisibleItems() } }
    private(set) var visibleItems: [ImageItem] = []
    /// Non-empty only while the grid is split into per-folder sections.
    private(set) var groups: [ImageGroup] = []
    /// The focused item — drives the detail view, fullscreen and the status bar.
    var selection: ImageItem.ID? {
        didSet {
            guard !isSyncingSelection else { return }
            selectedIDs = selection.map { [$0] } ?? []
            selectionAnchor = selection
        }
    }
    /// Everything currently selected; always contains `selection` when non-nil.
    private(set) var selectedIDs: Set<ImageItem.ID> = []
    /// iPhone-style tap-to-select mode; plain clicks toggle instead of replace.
    var isSelectMode = false { didSet { if !isSelectMode { collapseSelection() } } }
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
            // The watcher's scope (whole tree vs. direct children) follows the
            // setting, so restart it alongside the rescan.
            if let url = folder { startMonitoring(url) }
            rescan()
        }
    }
    var groupByFolder: Bool {
        didSet {
            UserDefaults.standard.set(groupByFolder, forKey: "groupByFolder")
            updateVisibleItems()
        }
    }
    var recents: [RecentFolder] = []
    let photos = PhotosLibraryModel()
    /// Non-nil while the conversion sheet should be up.
    var convertRequest: ConvertRequest?
    /// Non-nil while the rename sheet should be up.
    var renameRequest: RenameRequest?
    /// Culling flags by file URL (session-only).
    private(set) var flags: [URL: ImageFlag] = [:]
    var flagFilter: FlagFilter = .all { didSet { updateVisibleItems() } }
    private(set) var zoomRequest: ZoomRequest?
    /// The focused window's undo manager, attached by ContentView so that
    /// Move to Trash can be undone via the standard Edit → Undo.
    weak var undoManager: UndoManager?

    private var zoomRequestCount = 0
    /// Roots we hold a security scope for; released on close/deinit.
    private var securityScopedRoots: [URL] = []
    private let prefetcher = Prefetcher()
    private var scanGeneration = 0
    private var scanTask: Task<Void, Never>?
    /// File to select once the next scan finishes (used when an image is dropped).
    private var pendingSelection: URL?
    /// Last selection per folder path / album id, so switching back to a
    /// source restores the position (session-only).
    private var rememberedSelections: [String: ImageItem.ID] = [:]
    private var selectionAnchor: ImageItem.ID?
    /// Suppresses `selection`'s collapse-to-one behaviour during multi-select edits.
    private var isSyncingSelection = false

    private var folderWatcher: FolderWatcher?
    private var rescanDebounce: Task<Void, Never>?

    init() {
        let raw = UserDefaults.standard.string(forKey: "sortOrder") ?? SortOrder.nameAsc.rawValue
        self.sortOrder = SortOrder(rawValue: raw) ?? .nameAsc
        self.includeSubfolders = UserDefaults.standard.bool(forKey: "includeSubfolders")
        // Default is true; bool(forKey:) alone would default to false.
        self.groupByFolder = UserDefaults.standard.object(forKey: "groupByFolder") as? Bool ?? true
        self.recents = RecentFolders.all()
    }

    deinit {
        for url in securityScopedRoots { url.stopAccessingSecurityScopedResource() }
    }

    var currentItem: ImageItem? {
        guard let id = selection else { return nil }
        return visibleItems.first(where: { $0.id == id })
    }

    var currentIndex: Int? {
        guard let id = selection else { return nil }
        return visibleItems.firstIndex(where: { $0.id == id })
    }

    /// Title of whatever is being browsed — a folder or a Photos album.
    var sourceTitle: String? {
        folder?.lastPathComponent ?? photoAlbum?.title
    }

    // MARK: - Filtering & grouping

    private func updateVisibleItems() {
        var filtered = filterText.isEmpty
            ? items
            : items.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
        switch flagFilter {
        case .all:      break
        case .picked:   filtered = filtered.filter { flags[$0.url] == .pick }
        case .rejected: filtered = filtered.filter { flags[$0.url] == .reject }
        }

        if includeSubfolders, groupByFolder, photoAlbum == nil {
            let built = Self.group(filtered, relativeTo: folder)
            groups = built.count > 1 ? built : []
        } else {
            groups = []
        }
        // Keep the flat order identical to the rendered order so index-based
        // navigation (arrows, slideshow, "3 / 42") stays truthful.
        visibleItems = groups.isEmpty ? filtered : groups.flatMap(\.items)

        // Nothing left to show (deleted the last image, emptied the filter,
        // switched source) — leave fullscreen instead of keeping the flag set,
        // which would make it pop back on the next selection.
        if visibleItems.isEmpty { isFullscreen = false }

        if let id = selection, !visibleItems.contains(where: { $0.id == id }) {
            selection = visibleItems.first?.id
        }
        let valid = Set(visibleItems.map(\.id))
        withoutSyncing {
            selectedIDs.formIntersection(valid)
            if selectedIDs.isEmpty, let sel = selection { selectedIDs = [sel] }
            if let anchor = selectionAnchor, !valid.contains(anchor) { selectionAnchor = selection }
        }
    }

    private nonisolated static func group(_ items: [ImageItem], relativeTo root: URL?) -> [ImageGroup] {
        var order: [URL] = []
        var buckets: [URL: [ImageItem]] = [:]
        for item in items {
            let dir = item.url.deletingLastPathComponent()
            if buckets[dir] == nil {
                order.append(dir)
                buckets[dir] = []
            }
            buckets[dir]?.append(item)
        }
        let rootPath = root?.path
        return order
            .map { ImageGroup(folder: $0, title: title(for: $0, rootPath: rootPath), items: buckets[$0] ?? []) }
            .sorted { a, b in
                // The browsed folder's own images come first, then subfolders A→Z.
                if a.folder.path == rootPath { return true }
                if b.folder.path == rootPath { return false }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
    }

    private nonisolated static func title(for dir: URL, rootPath: String?) -> String {
        guard let rootPath, dir.path != rootPath else { return dir.lastPathComponent }
        guard dir.path.hasPrefix(rootPath + "/") else { return dir.lastPathComponent }
        return String(dir.path.dropFirst(rootPath.count + 1))
            .split(separator: "/")
            .joined(separator: " / ")
    }

    // MARK: - Selection

    /// Items acted on by Share/Convert/Trash — the multi-selection, or just the
    /// focused item when nothing is explicitly selected.
    var selectedItems: [ImageItem] {
        let picked = visibleItems.filter { selectedIDs.contains($0.id) }
        if !picked.isEmpty { return picked }
        return currentItem.map { [$0] } ?? []
    }

    var hasMultipleSelected: Bool { selectedIDs.count > 1 }

    private func withoutSyncing(_ body: () -> Void) {
        let previous = isSyncingSelection
        isSyncingSelection = true
        body()
        isSyncingSelection = previous
    }

    /// Click handling: plain replaces, ⌘ toggles, ⇧ extends from the anchor.
    func select(_ id: ImageItem.ID, extending: Bool = false, toggling: Bool = false) {
        if extending {
            let anchor = selectionAnchor ?? selection
            guard let anchor,
                  let a = visibleItems.firstIndex(where: { $0.id == anchor }),
                  let b = visibleItems.firstIndex(where: { $0.id == id })
            else { selection = id; return }
            withoutSyncing {
                selectedIDs = Set(visibleItems[min(a, b)...max(a, b)].map(\.id))
                selection = id
            }
        } else if toggling {
            withoutSyncing {
                if selectedIDs.contains(id) {
                    selectedIDs.remove(id)
                    if selection == id {
                        selection = visibleItems.last(where: { selectedIDs.contains($0.id) })?.id
                    }
                } else {
                    selectedIDs.insert(id)
                    selection = id
                }
                selectionAnchor = id
            }
        } else {
            selection = id
        }
    }

    func selectAll() {
        guard !visibleItems.isEmpty else { return }
        withoutSyncing {
            selectedIDs = Set(visibleItems.map(\.id))
            if selection == nil { selection = visibleItems.first?.id }
        }
    }

    /// Drops back to a single selected item (Escape, or leaving Select mode).
    func collapseSelection() {
        withoutSyncing {
            selectedIDs = selection.map { [$0] } ?? []
            selectionAnchor = selection
        }
    }

    // MARK: - Navigation

    func move(by offset: Int) {
        guard !visibleItems.isEmpty else { return }
        let cur = currentIndex ?? 0
        let new = (cur + offset).clamped(to: 0...(visibleItems.count - 1))
        selection = visibleItems[new].id
    }

    func extendSelection(by offset: Int) {
        guard !visibleItems.isEmpty else { return }
        let cur = currentIndex ?? 0
        let new = (cur + offset).clamped(to: 0...(visibleItems.count - 1))
        select(visibleItems[new].id, extending: true)
    }

    func selectFirst() { selection = visibleItems.first?.id }
    func selectLast()  { selection = visibleItems.last?.id }

    // MARK: - Folders

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            openRoot(url, isSecurityScoped: false)
        }
    }

    func restoreLastFolder() {
        // Preference default is true; bool(forKey:) alone would default to false.
        let wanted = UserDefaults.standard.object(forKey: "restoreLastFolder") as? Bool ?? true
        guard wanted,
              openFolders.isEmpty,
              let recent = recents.first,
              let url = RecentFolders.resolve(recent) else { return }
        openRoot(url, isSecurityScoped: true)
    }

    func openRecent(_ recent: RecentFolder) {
        guard let url = RecentFolders.resolve(recent) else { return }
        openRoot(url, isSecurityScoped: true)
    }

    func removeRecent(_ recent: RecentFolder) {
        recents = RecentFolders.remove(recent)
    }

    func clearRecents() {
        RecentFolders.clear()
        recents = []
    }

    func handleDrop(_ url: URL) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
        if values?.isDirectory == true {
            openRoot(url, isSecurityScoped: false)
        } else if values?.contentType?.conforms(to: .image) == true {
            pendingSelection = url
            let parent = url.deletingLastPathComponent()
            // Reuse a stored bookmark when the parent folder is in Recents —
            // that grants sandbox access to the whole folder, not just the file.
            if let scoped = recents.lazy.compactMap(RecentFolders.resolve).first(where: { $0.path == parent.path }) {
                openRoot(scoped, isSecurityScoped: true)
            } else if (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) != nil {
                openRoot(parent, isSecurityScoped: false)
            } else if let granted = requestFolderAccess(for: parent) {
                openRoot(granted, isSecurityScoped: false)
            } else {
                // Declined — applyScanResult falls back to showing just this file.
                openRoot(parent, isSecurityScoped: false)
            }
        }
    }

    /// The sandbox only grants access to the opened file itself, so browsing
    /// its siblings needs the user to grant folder access once (a bookmark is
    /// stored afterwards). Returns nil when the user declines.
    private func requestFolderAccess(for parent: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = parent
        panel.message = "Kuk can only see the opened image. Grant access to “\(parent.lastPathComponent)” to browse all images in it."
        panel.prompt = "Grant Access"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    /// Opens a folder as a sidebar root (keeping any already open roots) and
    /// shows its contents. Security scopes are held per root until closed.
    func openRoot(_ url: URL, isSecurityScoped: Bool) {
        if !openFolders.contains(where: { $0.path == url.path }) {
            if isSecurityScoped {
                guard url.startAccessingSecurityScopedResource() else { return }
                securityScopedRoots.append(url)
            }
            openFolders.append(url)
        }
        recents = RecentFolders.add(url)
        display(folder: url)
    }

    /// Shows the contents of a folder — a root or any subfolder from the tree.
    /// Sandbox access to subfolders flows from their root's active scope.
    func display(folder url: URL) {
        rememberCurrentSelection()
        self.photoAlbum = nil
        self.folder = url
        self.items = []
        self.selection = nil
        self.isLoading = true
        // A dropped file's explicit selection wins over the remembered one.
        if pendingSelection == nil { pendingSelection = rememberedSelections[url.path] }
        prefetcher.cancelAll()
        startMonitoring(url)
        rescan()
    }

    private func rememberCurrentSelection() {
        guard let sel = selection else { return }
        if let folder {
            rememberedSelections[folder.path] = sel
        } else if let album = photoAlbum {
            rememberedSelections[album.id] = sel
        }
    }

    /// Removes a root from the sidebar and releases its security scope.
    func closeRoot(_ url: URL) {
        openFolders.removeAll { $0.path == url.path }
        if let idx = securityScopedRoots.firstIndex(where: { $0.path == url.path }) {
            securityScopedRoots[idx].stopAccessingSecurityScopedResource()
            securityScopedRoots.remove(at: idx)
        }
        // If the displayed folder lived under the closed root, switch away.
        guard let current = folder,
              current.path == url.path || current.path.hasPrefix(url.path + "/")
        else { return }
        if let next = openFolders.first {
            display(folder: next)
        } else {
            clearContents()
        }
    }

    private func clearContents() {
        scanGeneration += 1  // invalidate any in-flight scan
        scanTask?.cancel()
        folder = nil
        photoAlbum = nil
        items = []
        selection = nil
        isLoading = false
        prefetcher.cancelAll()
        folderWatcher = nil
    }

    // MARK: - Photos

    /// Switches the grid over to a Photos album. Assets are read-only here:
    /// trashing and renaming stay disabled, everything else materializes a
    /// cached copy on demand.
    func displayPhotos(_ album: PhotoAlbum) {
        rememberCurrentSelection()
        folderWatcher = nil
        folder = nil
        photoAlbum = album
        items = []
        selection = nil
        isLoading = true
        prefetcher.cancelAll()
        scanGeneration += 1
        scanTask?.cancel()
        let generation = scanGeneration
        let order = sortOrder

        Task { @MainActor in
            let fetched = await self.photos.items(in: album)
            guard generation == self.scanGeneration else { return }
            self.items = Self.sorted(fetched, by: order)
            self.isLoading = false
            if let remembered = self.rememberedSelections[album.id],
               self.visibleItems.contains(where: { $0.id == remembered }) {
                self.selection = remembered
            } else {
                self.selection = self.visibleItems.first?.id
            }
        }
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

        // Cancel the previous walk — switching away from a huge tree should
        // stop the old scan, not let it run to completion for nothing.
        scanTask?.cancel()
        scanTask = Task.detached(priority: .userInitiated) {
            let scanned = ImageScanner.scan(url, recursive: recursive)
            guard !Task.isCancelled else { return }
            let dates = order.needsDateTaken ? MetadataReader.dateTakenMap(for: scanned) : [:]
            guard !Task.isCancelled else { return }
            let sorted = AppModel.sorted(scanned, by: order, dateTaken: dates)
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
        folderWatcher = FolderWatcher(url: url, recursive: includeSubfolders) { [weak self] in
            self?.scheduleRescan()
        }
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

    func deleteCurrent()  { delete(selectedItems) }
    func revealCurrent()  { reveal(selectedItems) }
    func copyCurrent()    { copy(selectedItems) }
    func shareCurrent()   { Sharing.share(selectedItems) }
    func convertCurrent() { requestConvert(selectedItems) }

    func requestConvert(_ targets: [ImageItem]) {
        guard !targets.isEmpty else { return }
        convertRequest = ConvertRequest(items: targets)
    }

    func reveal(_ item: ImageItem) { reveal([item]) }

    func reveal(_ targets: [ImageItem]) {
        Task {
            var urls: [URL] = []
            for item in targets {
                if let url = await ImageLoading.fileURL(for: item) { urls.append(url) }
            }
            guard !urls.isEmpty else { return }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    func copy(_ item: ImageItem) { copy([item]) }

    /// Puts the file URLs — and for a single image also the decoded bitmap — on
    /// the pasteboard, so pasting works in Finder as well as Mail/editors.
    func copy(_ targets: [ImageItem]) {
        guard !targets.isEmpty else { return }
        Task {
            var objects: [NSPasteboardWriting] = []
            for item in targets {
                if let url = await ImageLoading.fileURL(for: item) { objects.append(url as NSURL) }
            }
            if targets.count == 1, let image = await ImageLoading.fullImage(for: targets[0]) {
                objects.append(image)
            }
            guard !objects.isEmpty else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(objects)
        }
    }

    func delete(_ item: ImageItem) { delete([item]) }

    func delete(_ targets: [ImageItem]) {
        // Photos assets live in the system library — Kuk never deletes those.
        let deletable = targets.filter { !$0.isAsset }
        guard !deletable.isEmpty else { NSSound.beep(); return }

        let ids = Set(deletable.map(\.id))
        let firstIdx = visibleItems.firstIndex { ids.contains($0.id) }
        let actionName = deletable.count == 1
            ? "Move to Trash"
            : "Move \(deletable.count) Images to Trash"
        performTrash(deletable.map(\.url), actionName: actionName)

        items.removeAll { ids.contains($0.id) }
        withoutSyncing { selectedIDs = [] }
        if let firstIdx, !visibleItems.isEmpty {
            selection = visibleItems.indices.contains(firstIdx)
                ? visibleItems[firstIdx].id
                : visibleItems.last?.id
        } else {
            selection = visibleItems.first?.id
        }
    }

    struct TrashedItem: Sendable {
        let originalURL: URL
        let trashURL: URL
    }

    /// Trashes the files and registers the inverse (restore) with the undo
    /// manager. Restore registers a re-trash in turn, so undo/redo cycles work.
    private func performTrash(_ urls: [URL], actionName: String) {
        var restores: [TrashedItem] = []
        var failed = false
        for url in urls {
            do {
                var trashed: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
                if let trashURL = trashed as URL? {
                    restores.append(TrashedItem(originalURL: url, trashURL: trashURL))
                }
            } catch {
                failed = true
            }
        }
        if !restores.isEmpty {
            let payload = restores
            undoManager?.registerUndo(withTarget: self) { model in
                model.restoreFromTrash(payload, actionName: actionName)
            }
            undoManager?.setActionName(actionName)
        }
        if failed { NSSound.beep() }
    }

    private func restoreFromTrash(_ restores: [TrashedItem], actionName: String) {
        var restoredURLs: [URL] = []
        var failed = false
        for entry in restores {
            do {
                try FileManager.default.moveItem(at: entry.trashURL, to: entry.originalURL)
                restoredURLs.append(entry.originalURL)
            } catch {
                failed = true
            }
        }
        if !restoredURLs.isEmpty {
            let payload = restoredURLs
            undoManager?.registerUndo(withTarget: self) { model in
                model.retrash(payload, actionName: actionName)
            }
            undoManager?.setActionName(actionName)
        }
        pendingSelection = restoredURLs.first
        rescan()
        if failed { NSSound.beep() }
    }

    /// Redo of a trash operation. The rescan restores selection sensibly.
    private func retrash(_ urls: [URL], actionName: String) {
        performTrash(urls, actionName: actionName)
        let paths = Set(urls.map(\.path))
        items.removeAll { paths.contains($0.url.path) }
        withoutSyncing { selectedIDs = [] }
        rescan()
    }

    // MARK: - Zoom

    func requestZoom(_ command: ZoomCommand) {
        zoomRequestCount += 1
        zoomRequest = ZoomRequest(command: command, id: zoomRequestCount)
    }

    // MARK: - Prefetching

    func prefetchNeighbors(thumbSize: CGFloat, scale: CGFloat) {
        guard let center = currentIndex else { return }
        prefetcher.update(around: center, in: visibleItems, thumbSize: thumbSize, scale: scale)
    }

    // MARK: - Sorting

    private var sortToken = 0

    private func applySort() {
        let order = sortOrder
        guard order.needsDateTaken else {
            items = Self.sorted(items, by: order)
            return
        }
        // EXIF dates are read off the main thread first; the result is only
        // applied if nothing changed the list or the order in the meantime.
        sortToken += 1
        let token = sortToken
        let snapshot = items
        Task.detached(priority: .userInitiated) {
            let dates = MetadataReader.dateTakenMap(for: snapshot)
            let sorted = AppModel.sorted(snapshot, by: order, dateTaken: dates)
            await MainActor.run {
                guard token == self.sortToken, order == self.sortOrder,
                      self.items == snapshot else { return }
                self.items = sorted
            }
        }
    }

    nonisolated static func sorted(
        _ items: [ImageItem], by order: SortOrder, dateTaken: [URL: Date] = [:]
    ) -> [ImageItem] {
        // Photos assets already carry their capture date as modifiedAt.
        func taken(_ item: ImageItem) -> Date { dateTaken[item.url] ?? item.modifiedAt }
        switch order {
        case .nameAsc:       return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameDesc:      return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .modifiedDesc:  return items.sorted { $0.modifiedAt > $1.modifiedAt }
        case .modifiedAsc:   return items.sorted { $0.modifiedAt < $1.modifiedAt }
        case .sizeDesc:      return items.sorted { $0.fileSize > $1.fileSize }
        case .sizeAsc:       return items.sorted { $0.fileSize < $1.fileSize }
        case .dateTakenDesc: return items.sorted { taken($0) > taken($1) }
        case .dateTakenAsc:  return items.sorted { taken($0) < taken($1) }
        }
    }

    // MARK: - Culling

    func flag(for item: ImageItem) -> ImageFlag? { flags[item.url] }

    var hasPickedInCurrent: Bool { items.contains { flags[$0.url] == .pick } }
    var hasRejectedInCurrent: Bool { items.contains { flags[$0.url] == .reject } }

    /// Sets (nil clears) a flag; setting the flag every target already has
    /// toggles it off, so `P` `P` un-picks.
    func setFlag(_ flag: ImageFlag?, for targets: [ImageItem]) {
        guard !targets.isEmpty else { return }
        if let flag, targets.allSatisfy({ flags[$0.url] == flag }) {
            for target in targets { flags[target.url] = nil }
        } else {
            for target in targets { flags[target.url] = flag }
        }
        if flagFilter != .all { updateVisibleItems() }
    }

    /// Copies (or moves) all picked images in the current folder to a folder
    /// the user chooses. Photos assets can be copied (via their export) but
    /// never moved — they stay in the library.
    func exportPicked(move: Bool) {
        let picked = items.filter { flags[$0.url] == .pick }
        let targets = move ? picked.filter { !$0.isAsset } : picked
        guard !targets.isEmpty else { NSSound.beep(); return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = move ? "Move" : "Copy"
        panel.message = move
            ? "Choose where to move the \(targets.count) picked image(s)."
            : "Choose where to copy the \(targets.count) picked image(s)."
        guard panel.runModal() == .OK, let dir = panel.url else { return }

        Task {
            let fm = FileManager.default
            var failed = false
            for item in targets {
                guard let source = await ImageLoading.fileURL(for: item) else {
                    failed = true
                    continue
                }
                let destination = Self.uniqueDestination(for: source.lastPathComponent, in: dir)
                do {
                    if move, !item.isAsset {
                        try fm.moveItem(at: source, to: destination)
                        flags[item.url] = nil
                    } else {
                        try fm.copyItem(at: source, to: destination)
                    }
                } catch {
                    failed = true
                }
            }
            if failed { NSSound.beep() }
            if move { rescan() }
        }
    }

    func trashRejected() {
        let rejected = items.filter { flags[$0.url] == .reject }
        guard !rejected.isEmpty else { NSSound.beep(); return }
        delete(rejected)
        for item in rejected { flags[item.url] = nil }
    }

    nonisolated private static func uniqueDestination(for filename: String, in dir: URL) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = dir.appendingPathComponent(filename)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            candidate = dir.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }

    // MARK: - Rotation

    func rotateCurrent(clockwise: Bool) { rotate(selectedItems, clockwise: clockwise) }

    /// Lossless rotation via the EXIF orientation tag. The rescan afterwards
    /// refreshes mtime-keyed caches, so thumbnails and the detail update.
    func rotate(_ targets: [ImageItem], clockwise: Bool) {
        let rotatable = targets.filter { !$0.isAsset }
        guard !rotatable.isEmpty else { NSSound.beep(); return }
        Task {
            var failed = false
            for item in rotatable {
                let url = item.url
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try ImageRotator.rotateByExif(url, clockwise: clockwise)
                    }.value
                } catch {
                    failed = true
                }
            }
            if failed { NSSound.beep() }
            rescan()
        }
    }

    // MARK: - Renaming

    func renameCurrent() { requestRename(selectedItems) }

    func requestRename(_ targets: [ImageItem]) {
        // Photos assets have no file of their own to rename.
        let renamable = targets.filter { !$0.isAsset }
        guard !renamable.isEmpty else { NSSound.beep(); return }
        renameRequest = RenameRequest(items: renamable)
    }

    /// Renames a single file, keeping its extension. Returns an error message
    /// to show in the sheet, or nil on success.
    func rename(_ item: ImageItem, to newBase: String) -> String? {
        let clean = PhotosLibraryModel.sanitize(newBase).trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return "The name is empty." }
        let ext = item.url.pathExtension
        let destination = item.url.deletingLastPathComponent()
            .appendingPathComponent(ext.isEmpty ? clean : "\(clean).\(ext)")
        guard destination.path != item.url.path else { return nil }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            return "A file with this name already exists."
        }
        do {
            try FileManager.default.moveItem(at: item.url, to: destination)
        } catch {
            return error.localizedDescription
        }
        flags[destination] = flags[item.url]
        flags[item.url] = nil
        pendingSelection = destination
        rescan()
        return nil
    }

    /// Batch rename: a run of `#` in the pattern becomes a zero-padded counter
    /// ("Trip-###" → Trip-001, Trip-002, …). Returns the number of failures.
    func renameBatch(_ targets: [ImageItem], pattern: String, start: Int) -> Int {
        let hashes = pattern.filter { $0 == "#" }.count
        var counter = start
        var failures = 0
        var firstRenamed: URL?
        for item in targets {
            let number = String(format: "%0\(max(hashes, 1))d", counter)
            counter += 1
            var base = hashes > 0
                ? pattern.replacingOccurrences(of: String(repeating: "#", count: hashes), with: number)
                : "\(pattern)-\(number)"
            base = PhotosLibraryModel.sanitize(base)
            let ext = item.url.pathExtension
            let destination = item.url.deletingLastPathComponent()
                .appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
            if destination.path == item.url.path { continue }
            if FileManager.default.fileExists(atPath: destination.path) {
                failures += 1
                continue
            }
            do {
                try FileManager.default.moveItem(at: item.url, to: destination)
                flags[destination] = flags[item.url]
                flags[item.url] = nil
                firstRenamed = firstRenamed ?? destination
            } catch {
                failures += 1
            }
        }
        pendingSelection = firstRenamed
        rescan()
        return failures
    }
}

/// Warms the thumbnail/preview caches around the selection and — unlike a
/// fire-and-forget Task per neighbor — cancels work that falls out of the
/// window, so holding an arrow key doesn't queue hundreds of stale decodes.
@MainActor
final class Prefetcher {
    private var tasks: [ImageItem.ID: Task<Void, Never>] = [:]

    func update(around index: Int, in items: [ImageItem], thumbSize: CGFloat, scale: CGFloat) {
        guard items.indices.contains(index) else { return }
        // Bias forward: browsing mostly moves ahead.
        let lo = max(0, index - 1)
        let hi = min(items.count - 1, index + 2)
        let window = items[lo...hi].filter { $0.id != items[index].id }
        let wanted = Set(window.map(\.id))

        for (id, task) in tasks where !wanted.contains(id) {
            task.cancel()
            tasks[id] = nil
        }
        for item in window where tasks[item.id] == nil {
            tasks[item.id] = Task(priority: .utility) {
                _ = await ImageLoading.thumbnail(for: item, pixelSize: thumbSize, scale: scale)
                _ = await ImageLoading.thumbnail(for: item, pixelSize: 2048, scale: scale)
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
            // The walk of a huge tree must die with its task — the result of a
            // cancelled scan is discarded by the generation check anyway.
            if Task.isCancelled { return [] }
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

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

/// A folder tile shown above the images when "Show folders in the grid" is on:
/// either a subfolder of the displayed folder or the ".." tile leading up.
nonisolated struct GridFolder: Identifiable, Hashable, Sendable {
    let url: URL
    let isParent: Bool
    var id: URL { url }
    var name: String { isParent ? ".." : url.lastPathComponent }
}

/// A pending "Convert…" sheet. `id` is fresh per request so asking twice for
/// the same images still re-presents the sheet.
nonisolated struct ConvertRequest: Identifiable, Sendable {
    let id = UUID()
    let items: [ImageItem]
}

nonisolated enum ZoomCommand: Equatable, Sendable { case zoomIn, zoomOut, actualSize, fit }

/// A one-shot zoom request from the menu bar; `id` makes repeated identical
/// commands distinct so `onChange` in DetailView fires every time.
nonisolated struct ZoomRequest: Equatable, Sendable {
    let command: ZoomCommand
    let id: Int
}

nonisolated enum SortOrder: String, CaseIterable, Codable, Sendable {
    case nameAsc, nameDesc, modifiedDesc, modifiedAsc, sizeDesc, sizeAsc, dateTakenDesc, dateTakenAsc

    var label: String {
        switch self {
        case .nameAsc:       String(localized: "Name (A → Z)")
        case .nameDesc:      String(localized: "Name (Z → A)")
        case .modifiedDesc:  String(localized: "Newest First")
        case .modifiedAsc:   String(localized: "Oldest First")
        case .sizeDesc:      String(localized: "Largest First")
        case .sizeAsc:       String(localized: "Smallest First")
        case .dateTakenDesc: String(localized: "Date Taken (Newest)")
        case .dateTakenAsc:  String(localized: "Date Taken (Oldest)")
        }
    }

    /// These orders need EXIF dates read from the files before sorting.
    var needsDateTaken: Bool { self == .dateTakenDesc || self == .dateTakenAsc }

    /// Photos assets carry no file size, so size orders make no sense there.
    var isSizeBased: Bool { self == .sizeDesc || self == .sizeAsc }
}

/// Culling flags. Files keep them as Finder tags, Photos assets in the app's
/// defaults (see `FinderTags` / `AssetFlagStore`).
nonisolated enum ImageFlag: String, Sendable {
    case pick, reject
}

nonisolated enum FlagFilter: String, CaseIterable, Sendable {
    case all, picked, rejected

    var label: String {
        switch self {
        case .all:      String(localized: "All Images")
        case .picked:   String(localized: "Picked")
        case .rejected: String(localized: "Rejected")
        }
    }
}

/// A pending "Rename…" sheet; fresh `id` re-presents on repeat requests.
nonisolated struct RenameRequest: Identifiable, Sendable {
    let id = UUID()
    let items: [ImageItem]
}

/// A long-running file operation, shown with its progress in the status bar.
nonisolated struct Activity: Equatable, Sendable {
    let title: String
    var completed: Int
    let total: Int
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
            if selection != nil { focusedFolder = nil }
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
    var showFoldersInGrid: Bool {
        didSet {
            UserDefaults.standard.set(showFoldersInGrid, forKey: "showFoldersInGrid")
            reloadGridFolders()
        }
    }
    /// Folder tile focused in the grid. Mutually exclusive with `selection`,
    /// so a focused folder leaves the detail view empty.
    var focusedFolder: URL?
    /// Folder tiles of the displayed folder, before the name filter.
    private(set) var folderTiles: [GridFolder] = []
    var recents: [RecentFolder] = []
    let photos = PhotosLibraryModel()
    /// Non-nil while the conversion sheet should be up.
    var convertRequest: ConvertRequest?
    /// Non-nil while the rename sheet should be up.
    var renameRequest: RenameRequest?
    /// Culling flags by item URL, mirrored from Finder tags / the asset store.
    private(set) var flags: [URL: ImageFlag] = [:]
    var flagFilter: FlagFilter = .all { didSet { updateVisibleItems() } }
    private(set) var zoomRequest: ZoomRequest?
    /// Sidebar folders that are expanded, by path. Lives here (not in the
    /// rows) so folder navigation can reveal where it went.
    var expandedPaths: Set<String> = []
    /// Copy/move of picked images in progress.
    private(set) var activity: Activity?
    /// The focused window's undo manager, attached by ContentView so that
    /// Move to Trash can be undone via the standard Edit → Undo.
    weak var undoManager: UndoManager?

    /// Flat index of every visible item, so lookups by ID stay O(1) even in
    /// folders with tens of thousands of images. Rebuilt with `visibleItems`.
    @ObservationIgnored private var indexByID: [ImageItem.ID: Int] = [:]
    /// Flat index where each rendered section starts (just [0] ungrouped).
    @ObservationIgnored private var groupStarts: [Int] = [0]

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
    /// Files whose tags are being written in the background; a scan that read
    /// them mid-write must not overwrite the in-memory flag.
    private var flagWritesInFlight: Set<URL> = []
    /// Folder navigation requests run one after another, each starting from
    /// wherever the previous one went.
    private var folderNavigation: Task<Void, Never>?

    private var folderTilesTask: Task<Void, Never>?

    private var folderWatcher: FolderWatcher?
    private var rescanDebounce: Task<Void, Never>?

    init() {
        let raw = UserDefaults.standard.string(forKey: "sortOrder") ?? SortOrder.nameAsc.rawValue
        self.sortOrder = SortOrder(rawValue: raw) ?? .nameAsc
        self.includeSubfolders = UserDefaults.standard.bool(forKey: "includeSubfolders")
        // Default is true; bool(forKey:) alone would default to false.
        self.groupByFolder = UserDefaults.standard.object(forKey: "groupByFolder") as? Bool ?? true
        self.showFoldersInGrid = UserDefaults.standard.bool(forKey: "showFoldersInGrid")
        self.recents = RecentFolders.all()
        photos.onLibraryChange = { [weak self] in self?.refreshPhotoAlbum() }
    }

    isolated deinit {
        for url in securityScopedRoots { url.stopAccessingSecurityScopedResource() }
    }

    var currentItem: ImageItem? {
        guard let id = selection, let index = index(of: id) else { return nil }
        return visibleItems[index]
    }

    var currentIndex: Int? {
        guard let id = selection else { return nil }
        return index(of: id)
    }

    /// Position of an item in `visibleItems`, in constant time.
    func index(of id: ImageItem.ID) -> Int? {
        // Reading visibleItems registers the observation dependency that the
        // (ignored) index itself can't.
        let count = visibleItems.count
        guard let index = indexByID[id], index < count else { return nil }
        return index
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
        let flat = groups.isEmpty ? filtered : groups.flatMap(\.items)

        var index: [ImageItem.ID: Int] = [:]
        index.reserveCapacity(flat.count)
        for (position, item) in flat.enumerated() { index[item.id] = position }
        indexByID = index
        var starts: [Int] = []
        var offset = 0
        for group in groups {
            starts.append(offset)
            offset += group.items.count
        }
        groupStarts = starts.isEmpty ? [0] : starts
        visibleItems = flat

        // Nothing left to show (deleted the last image, emptied the filter)
        // — leave fullscreen instead of keeping the flag set, which would make
        // it pop back on the next selection. A folder switch in progress
        // (isLoading) keeps it: the next folder's images take over.
        if visibleItems.isEmpty, !isLoading { isFullscreen = false }

        if let id = selection, indexByID[id] == nil {
            selection = visibleItems.first?.id
        }
        withoutSyncing {
            if !selectedIDs.isEmpty {
                selectedIDs = selectedIDs.filter { indexByID[$0] != nil }
            }
            if selectedIDs.isEmpty, let sel = selection { selectedIDs = [sel] }
            if let anchor = selectionAnchor, indexByID[anchor] == nil { selectionAnchor = selection }
        }
    }

    nonisolated static func group(_ items: [ImageItem], relativeTo root: URL?) -> [ImageGroup] {
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
        if selectedIDs.count > 1 {
            return selectedIDs.compactMap { index(of: $0) }.sorted().map { visibleItems[$0] }
        }
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
            guard let anchor, let a = index(of: anchor), let b = index(of: id)
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
                        selection = selectedIDs.compactMap { index(of: $0) }.max().map { visibleItems[$0].id }
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

    func selectFirst() { selection = visibleItems.first?.id }
    func selectLast()  { selection = visibleItems.last?.id }

    // MARK: - Grid navigation

    /// Folder tiles as the grid shows them: the name filter applies to
    /// subfolders, the ".." tile always stays.
    var gridFolders: [GridFolder] {
        guard !filterText.isEmpty else { return folderTiles }
        return folderTiles.filter { $0.isParent || $0.name.localizedCaseInsensitiveContains(filterText) }
    }

    /// Position in the grid's tile sequence: folder tiles first, then images.
    private var gridPosition: Int? {
        let folders = gridFolders
        if let focused = focusedFolder, let i = folders.firstIndex(where: { $0.url == focused }) {
            return i
        }
        return currentIndex.map { $0 + folders.count }
    }

    private func focusGridTile(at position: Int, extending: Bool) {
        let folders = gridFolders
        if position < folders.count {
            focusFolder(folders[position].url)
        } else {
            // A range can't start on a folder tile, so from there it's a plain move.
            select(visibleItems[position - folders.count].id, extending: extending && focusedFolder == nil)
        }
    }

    /// Arrow keys in the grid walk folder tiles and images as one sequence.
    /// With nothing focused (after Escape) any move starts at the first tile.
    func moveInGrid(by offset: Int, extend: Bool = false) {
        let total = gridFolders.count + visibleItems.count
        guard total > 0 else { return }
        guard let current = gridPosition else {
            focusGridTile(at: 0, extending: false)
            return
        }
        focusGridTile(at: (current + offset).clamped(to: 0...(total - 1)), extending: extend)
    }

    /// Moves one visual row up or down in a grid of `columns`, keeping the
    /// column. Folder tiles and section headers restart the rows, so the math
    /// runs per section.
    func moveVerticallyInGrid(by direction: Int, columns: Int, extend: Bool) {
        let folderCount = gridFolders.count
        let total = folderCount + visibleItems.count
        guard total > 0 else { return }
        guard let current = gridPosition else {
            focusGridTile(at: 0, extending: false)
            return
        }
        var starts = folderCount > 0 ? [0] : []
        if !visibleItems.isEmpty { starts += groupStarts.map { $0 + folderCount } }
        let target = GridMath.verticalTarget(
            from: current, direction: direction, columns: columns,
            groupStarts: starts, total: total
        )
        focusGridTile(at: target, extending: extend)
    }

    func selectFirstInGrid() {
        guard !gridFolders.isEmpty || !visibleItems.isEmpty else { return }
        focusGridTile(at: 0, extending: false)
    }

    func selectLastInGrid() {
        let total = gridFolders.count + visibleItems.count
        guard total > 0 else { return }
        focusGridTile(at: total - 1, extending: false)
    }

    /// Focuses a folder tile; the detail view goes empty meanwhile.
    func focusFolder(_ url: URL) {
        selection = nil
        focusedFolder = url
    }

    /// Return / Space in the grid: opens the focused folder, or the viewer.
    func openFocusedTile() {
        // A folder hidden by the name filter stays focused but isn't opened.
        if let focused = focusedFolder, gridFolders.contains(where: { $0.url == focused }) {
            display(folder: focused)
        } else if currentItem != nil {
            isFullscreen = true
        }
    }

    /// Escape steps back one level at a time: leaves the viewer, then drops a
    /// multi-selection, then Select mode, and finally closes the open photo.
    /// Returns false when there was nothing left to close.
    func handleEscape() -> Bool {
        if isFullscreen {
            isFullscreen = false
        } else if hasMultipleSelected {
            collapseSelection()
        } else if isSelectMode {
            isSelectMode = false
        } else if selection != nil || focusedFolder != nil {
            selection = nil
            focusedFolder = nil
        } else {
            return false
        }
        return true
    }

    /// Lists the folder tiles for the displayed folder off the main thread.
    /// Follows the sidebar's "Hide folders without images" preference.
    func reloadGridFolders() {
        folderTilesTask?.cancel()
        guard showFoldersInGrid, let url = folder else {
            folderTiles = []
            focusedFolder = nil
            return
        }
        let parent = canGoToEnclosingFolder ? url.deletingLastPathComponent() : nil
        let hideEmpty = UserDefaults.standard.bool(forKey: "hideEmptyFolders")
        folderTilesTask = Task {
            var subfolders = await Task.detached(priority: .userInitiated) {
                FolderListing.subfolders(of: url)
            }.value
            if hideEmpty {
                var kept: [URL] = []
                for sub in subfolders {
                    if await FolderIndex.shared.containsImages(sub) { kept.append(sub) }
                }
                subfolders = kept
            }
            guard !Task.isCancelled, self.folder == url else { return }
            var tiles = parent.map { [GridFolder(url: $0, isParent: true)] } ?? []
            tiles += subfolders.map { GridFolder(url: $0, isParent: false) }
            if tiles != self.folderTiles { self.folderTiles = tiles }
            if let focused = self.focusedFolder, !tiles.contains(where: { $0.url == focused }) {
                self.focusedFolder = nil
            }
        }
    }

    // MARK: - Folders

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Open")
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
            if let recent = recents.first(where: { $0.path == parent.path }),
               let scoped = RecentFolders.resolve(recent) {
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
        let name = parent.lastPathComponent
        panel.message = String(localized: "Kuk can only see the opened image. Grant access to “\(name)” to browse all images in it.")
        panel.prompt = String(localized: "Grant Access")
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
        // Re-created on every open, which also refreshes a stale bookmark.
        recents = RecentFolders.add(url)
        display(folder: url)
    }

    /// Shows the contents of a folder — a root or any subfolder from the tree.
    /// Sandbox access to subfolders flows from their root's active scope.
    func display(folder url: URL) {
        rememberCurrentSelection()
        // Set before emptying the list so fullscreen survives the switch.
        self.isLoading = true
        self.photoAlbum = nil
        self.folder = url
        self.items = []
        self.selection = nil
        self.focusedFolder = nil
        self.folderTiles = []
        // A dropped file's explicit selection wins over the remembered one.
        if pendingSelection == nil { pendingSelection = rememberedSelections[url.path] }
        prefetcher.cancelAll()
        revealInSidebar(url)
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
        isLoading = false
        folder = nil
        photoAlbum = nil
        items = []
        selection = nil
        reloadGridFolders()
        prefetcher.cancelAll()
        folderWatcher = nil
    }

    // MARK: - Folder navigation

    /// Next folder with images, in sidebar order (depth-first, continuing into
    /// the next open root).
    func goToNextFolder() { navigateFolder(forward: true) }

    /// Previous folder with images, in sidebar order.
    func goToPreviousFolder() { navigateFolder(forward: false) }

    var canNavigateFolders: Bool { folder != nil }

    /// True when the displayed folder sits below one of the open roots.
    var canGoToEnclosingFolder: Bool {
        guard let folder else { return false }
        return openFolders.contains { folder.path.hasPrefix($0.path + "/") }
    }

    func goToEnclosingFolder() {
        guard canGoToEnclosingFolder, let folder else { NSSound.beep(); return }
        pendingSelection = nil
        display(folder: folder.deletingLastPathComponent())
    }

    private func navigateFolder(forward: Bool) {
        guard folder != nil else { NSSound.beep(); return }
        let previous = folderNavigation
        folderNavigation = Task {
            await previous?.value
            guard let current = self.folder else { return }
            let roots = self.openFolders
            let descend = !self.includeSubfolders
            let target = await Task.detached(priority: .userInitiated) {
                FolderNavigator.step(from: current, roots: roots, forward: forward, descend: descend)
            }.value
            // The user went somewhere else meanwhile.
            guard self.folder == current else { return }
            guard let target else { NSSound.beep(); return }
            self.display(folder: target)
        }
    }

    /// Expands the sidebar tree down to `url`.
    private func revealInSidebar(_ url: URL) {
        guard let root = openFolders.first(where: { url.path.hasPrefix($0.path + "/") }) else { return }
        var dir = url.deletingLastPathComponent()
        var paths = expandedPaths
        while dir.path.count >= root.path.count {
            paths.insert(dir.path)
            if dir.path == root.path { break }
            dir = dir.deletingLastPathComponent()
        }
        if paths != expandedPaths { expandedPaths = paths }
    }

    // MARK: - Photos

    /// Switches the grid over to a Photos album. Assets are read-only here:
    /// trashing and renaming stay disabled, everything else materializes a
    /// cached copy on demand.
    func displayPhotos(_ album: PhotoAlbum) {
        rememberCurrentSelection()
        isLoading = true
        folderWatcher = nil
        folder = nil
        photoAlbum = album
        items = []
        selection = nil
        reloadGridFolders()
        prefetcher.cancelAll()
        loadPhotos(album, keeping: rememberedSelections[album.id])
    }

    /// Refetches the displayed album after the library changed, keeping the
    /// selection (by asset, since an edit gives an asset a new URL).
    private func refreshPhotoAlbum() {
        guard let album = photoAlbum else { return }
        loadPhotos(album, keeping: selection)
    }

    private func loadPhotos(_ album: PhotoAlbum, keeping wanted: ImageItem.ID?) {
        scanGeneration += 1
        scanTask?.cancel()
        let generation = scanGeneration
        let order = sortOrder
        let wantedAsset = wanted.flatMap { id in items.first { $0.id == id }?.assetIdentifier }

        Task { @MainActor in
            let fetched = await self.photos.items(in: album)
            let sorted = await Task.detached(priority: .userInitiated) {
                AppModel.sorted(fetched, by: order)
            }.value
            guard generation == self.scanGeneration else { return }

            let stored = AssetFlagStore.all()
            var updated = self.flags
            for item in sorted {
                if let id = item.assetIdentifier { updated[item.url] = stored[id] }
            }
            self.flags = updated

            // Only a fresh load picks the first image; a library refresh
            // keeps "nothing selected" after Escape.
            let initialLoad = self.isLoading
            self.isLoading = false
            self.items = sorted
            if let wanted, self.index(of: wanted) != nil {
                self.selection = wanted
            } else if let wantedAsset,
                      let match = sorted.first(where: { $0.assetIdentifier == wantedAsset }) {
                self.selection = match.id
            } else if self.selection == nil, initialLoad {
                self.selection = self.visibleItems.first?.id
            }
            if order != self.sortOrder { self.applySort() }
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
        reloadGridFolders()

        // Cancel the previous walk — switching away from a huge tree should
        // stop the old scan, not let it run to completion for nothing.
        scanTask?.cancel()
        scanTask = Task.detached(priority: .userInitiated) {
            guard let scanned = ImageScanner.scan(url, recursive: recursive) else { return }
            let dates = order.needsDateTaken ? MetadataReader.dateTakenMap(for: scanned.items) : [:]
            guard !Task.isCancelled else { return }
            let sorted = AppModel.sorted(scanned.items, by: order, dateTaken: dates)
            await MainActor.run {
                guard generation == self.scanGeneration else { return }
                self.applyScanResult(sorted, flags: scanned.flags, order: order)
            }
        }
    }

    private func applyScanResult(_ sorted: [ImageItem], flags scannedFlags: [URL: ImageFlag], order: SortOrder) {
        var result = sorted
        // A dropped image grants sandbox access to the file, not its folder —
        // if the folder scan came back empty, still show the dropped file.
        if let pending = pendingSelection, result.isEmpty {
            let values = try? pending.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .tagNamesKey])
            result = [ImageItem(
                url: pending,
                modifiedAt: values?.contentModificationDate ?? .distantPast,
                fileSize: Int64(values?.fileSize ?? 0)
            )]
        }

        // Tags on disk are the source of truth, except for files whose new tag
        // is still being written.
        var updated = flags
        for item in result where !flagWritesInFlight.contains(item.url) {
            updated[item.url] = scannedFlags[item.url]
        }
        if updated != flags { flags = updated }

        // Only a fresh load picks the first image; a rescan from the folder
        // watcher keeps "nothing selected" after Escape. A selection whose
        // file disappeared is already moved on by updateVisibleItems.
        let initialLoad = isLoading
        isLoading = false
        items = result
        if let pending = pendingSelection, index(of: pending) != nil {
            selection = pending
        } else if selection == nil, initialLoad, focusedFolder == nil {
            selection = visibleItems.first?.id
        }
        pendingSelection = nil
        // The order was changed while this scan ran; its sort is stale.
        if order != sortOrder { applySort() }
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
            let urls = await ImageLoading.fileURLs(for: targets)
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
            let urls = await ImageLoading.fileURLs(for: targets)
            var objects: [NSPasteboardWriting] = urls.map { $0 as NSURL }
            if targets.count == 1, let url = urls.first {
                // Decoded straight from the file, bypassing the viewer cache: a
                // one-off native decode shouldn't evict what's being browsed.
                let image = await Task.detached(priority: .userInitiated) {
                    ImageDecoder.decode(url: url)
                }.value
                if let image { objects.append(image) }
            }
            guard !objects.isEmpty else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(objects)
        }
    }

    func delete(_ item: ImageItem) { delete([item]) }

    /// Moves files to the Trash. The grid updates at once; the file operations
    /// run in the background, and anything that couldn't be trashed comes back
    /// with the rescan that follows a failure.
    func delete(_ targets: [ImageItem]) {
        // Photos assets live in the system library — Kuk never deletes those.
        let deletable = targets.filter { !$0.isAsset }
        guard !deletable.isEmpty else { NSSound.beep(); return }

        let ids = Set(deletable.map(\.id))
        let firstIdx = deletable.compactMap { index(of: $0.id) }.min()
        let actionName = deletable.count == 1
            ? String(localized: "Move to Trash")
            : String(localized: "Move \(deletable.count) Images to Trash")
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

    /// Filled in once the background trash finishes; the undo action holds it
    /// from the start, because undo registration has to happen synchronously.
    final class TrashBatch {
        var entries: [TrashedItem] = []
    }

    nonisolated struct TrashedItem: Sendable {
        let originalURL: URL
        let trashURL: URL
    }

    /// Trashes the files and registers the inverse (restore) with the undo
    /// manager. Restore registers a re-trash in turn, so undo/redo cycles work.
    private func performTrash(_ urls: [URL], actionName: String) {
        let batch = TrashBatch()
        undoManager?.registerUndo(withTarget: self) { model in
            model.restoreFromTrash(batch, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                FileOperations.trash(urls)
            }.value
            batch.entries = result.trashed
            if result.failures > 0 {
                NSSound.beep()
                rescan()
            }
        }
    }

    private func restoreFromTrash(_ batch: TrashBatch, actionName: String) {
        let entries = batch.entries
        guard !entries.isEmpty else { return }
        let originals = entries.map(\.originalURL)
        undoManager?.registerUndo(withTarget: self) { model in
            model.retrash(originals, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        pendingSelection = originals.first
        Task {
            let failures = await Task.detached(priority: .userInitiated) {
                FileOperations.restore(entries)
            }.value
            if failures > 0 { NSSound.beep() }
            rescan()
        }
    }

    /// Redo of a trash operation. The rescan restores selection sensibly.
    private func retrash(_ urls: [URL], actionName: String) {
        performTrash(urls, actionName: actionName)
        let paths = Set(urls.map(\.path))
        items.removeAll { paths.contains($0.url.path) }
        withoutSyncing { selectedIDs = [] }
    }

    // MARK: - Zoom

    func requestZoom(_ command: ZoomCommand) {
        zoomRequestCount += 1
        zoomRequest = ZoomRequest(command: command, id: zoomRequestCount)
    }

    // MARK: - Prefetching

    /// Warms grid thumbnails around the selection; the viewer prefetches its
    /// own full-size neighbours.
    func prefetchNeighbors(thumbSize: CGFloat, scale: CGFloat) {
        guard let center = currentIndex else { return }
        let lo = max(0, center - 1)
        let hi = min(visibleItems.count - 1, center + 3)
        guard lo <= hi else { return }
        prefetcher.prefetch(Array(visibleItems[lo...hi]), pointSize: thumbSize, scale: scale)
    }

    // MARK: - Sorting

    private var sortToken = 0

    /// Sorting thousands of names takes long enough to drop frames, so it
    /// always runs off the main thread; the result is only applied if nothing
    /// changed the list or the order in the meantime.
    private func applySort() {
        let order = sortOrder
        sortToken += 1
        let token = sortToken
        let snapshot = items
        Task.detached(priority: .userInitiated) {
            let dates = order.needsDateTaken ? MetadataReader.dateTakenMap(for: snapshot) : [:]
            let sorted = AppModel.sorted(snapshot, by: order, dateTaken: dates)
            await MainActor.run {
                guard token == self.sortToken, order == self.sortOrder,
                      self.items == snapshot else { return }
                self.items = sorted
            }
        }
    }

    /// Ties (same date, same size) fall back to the name, so the order is
    /// stable across rescans.
    nonisolated static func sorted(
        _ items: [ImageItem], by order: SortOrder, dateTaken: [URL: Date] = [:]
    ) -> [ImageItem] {
        // lastPathComponent is costly enough to precompute once per item.
        let names = items.map(\.name)
        func nameOrder(_ a: Int, _ b: Int) -> ComparisonResult {
            names[a].localizedStandardCompare(names[b])
        }
        // Photos assets already carry their capture date as modifiedAt.
        func taken(_ i: Int) -> Date { dateTaken[items[i].url] ?? items[i].modifiedAt }

        var indices = Array(items.indices)
        switch order {
        case .nameAsc:
            indices.sort { nameOrder($0, $1) == .orderedAscending }
        case .nameDesc:
            indices.sort { nameOrder($0, $1) == .orderedDescending }
        case .modifiedDesc, .modifiedAsc:
            let dates = items.map(\.modifiedAt)
            let newest = order == .modifiedDesc
            indices.sort { a, b in
                if dates[a] != dates[b] { return newest ? dates[a] > dates[b] : dates[a] < dates[b] }
                return nameOrder(a, b) == .orderedAscending
            }
        case .sizeDesc, .sizeAsc:
            let largest = order == .sizeDesc
            indices.sort { a, b in
                let sa = items[a].fileSize, sb = items[b].fileSize
                if sa != sb { return largest ? sa > sb : sa < sb }
                return nameOrder(a, b) == .orderedAscending
            }
        case .dateTakenDesc, .dateTakenAsc:
            let dates = items.indices.map(taken)
            let newest = order == .dateTakenDesc
            indices.sort { a, b in
                if dates[a] != dates[b] { return newest ? dates[a] > dates[b] : dates[a] < dates[b] }
                return nameOrder(a, b) == .orderedAscending
            }
        }
        return indices.map { items[$0] }
    }

    // MARK: - Culling

    func flag(for item: ImageItem) -> ImageFlag? { flags[item.url] }

    var hasPickedInCurrent: Bool { items.contains { flags[$0.url] == .pick } }
    var hasRejectedInCurrent: Bool { items.contains { flags[$0.url] == .reject } }

    /// Sets (nil clears) a flag; setting the flag every target already has
    /// toggles it off, so `P` `P` un-picks. Persisted as Finder tags on files
    /// and in the asset store for Photos items.
    func setFlag(_ flag: ImageFlag?, for targets: [ImageItem]) {
        guard !targets.isEmpty else { return }
        let newFlag: ImageFlag? = if let flag, targets.allSatisfy({ flags[$0.url] == flag }) {
            nil
        } else {
            flag
        }
        var updated = flags
        for target in targets { updated[target.url] = newFlag }
        flags = updated
        persist(newFlag, for: targets)
        if flagFilter != .all { updateVisibleItems() }
    }

    private func persist(_ flag: ImageFlag?, for targets: [ImageItem]) {
        let assetIDs = targets.compactMap(\.assetIdentifier)
        if !assetIDs.isEmpty { AssetFlagStore.set(flag, for: assetIDs) }

        let files = targets.filter { !$0.isAsset }.map(\.url)
        guard !files.isEmpty else { return }
        // A few tags are microseconds of work; thousands go to the background.
        // A read-only volume simply keeps the flag for this session.
        if files.count <= 64 {
            for url in files { FinderTags.write(flag, to: url) }
            return
        }
        flagWritesInFlight.formUnion(files)
        Task {
            await Task.detached(priority: .userInitiated) {
                for url in files { FinderTags.write(flag, to: url) }
            }.value
            flagWritesInFlight.subtract(files)
        }
    }

    /// Copies (or moves) all picked images in the current folder to a folder
    /// the user chooses. Photos assets can be copied (via their export) but
    /// never moved — they stay in the library. Runs in the background with its
    /// progress in the status bar.
    func exportPicked(move: Bool) {
        guard activity == nil else { NSSound.beep(); return }
        let picked = items.filter { flags[$0.url] == .pick }
        let targets = move ? picked.filter { !$0.isAsset } : picked
        guard !targets.isEmpty else { NSSound.beep(); return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = move ? String(localized: "Move") : String(localized: "Copy")
        panel.message = move
            ? String(localized: "Choose where to move the \(targets.count) picked image(s).")
            : String(localized: "Choose where to copy the \(targets.count) picked image(s).")
        guard panel.runModal() == .OK, let dir = panel.url else { return }

        activity = Activity(
            title: move ? String(localized: "Moving") : String(localized: "Copying"),
            completed: 0,
            total: targets.count
        )
        Task {
            var failed = false
            for (index, item) in targets.enumerated() {
                if let source = await ImageLoading.fileURL(for: item) {
                    let moves = move && !item.isAsset
                    let ok = await Task.detached(priority: .userInitiated) {
                        FileOperations.transfer(source, into: dir, move: moves)
                    }.value
                    if ok, moves { flags[item.url] = nil }
                    failed = failed || !ok
                } else {
                    failed = true
                }
                activity?.completed = index + 1
            }
            activity = nil
            if failed { NSSound.beep() }
            if move { rescan() }
        }
    }

    func trashRejected() {
        let rejected = items.filter { flags[$0.url] == .reject && !$0.isAsset }
        guard !rejected.isEmpty else { NSSound.beep(); return }
        delete(rejected)
        for item in rejected { flags[item.url] = nil }
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
        guard !clean.isEmpty else { return String(localized: "The name is empty.") }
        let ext = item.url.pathExtension
        let destination = item.url.deletingLastPathComponent()
            .appendingPathComponent(ext.isEmpty ? clean : "\(clean).\(ext)")
        guard destination.path != item.url.path else { return nil }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            return String(localized: "A file with this name already exists.")
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
    /// ("Trip-###" → Trip-001, Trip-002, …). Files are first moved to temporary
    /// names, so the batch may reuse names its own files currently hold (e.g.
    /// renumbering). Returns the number of failures.
    func renameBatch(_ targets: [ImageItem], pattern: String, start: Int) -> Int {
        let fm = FileManager.default
        let plan = RenamePattern.plan(targets.map(\.url), pattern: pattern, start: start)
        let sources = Set(targets.map(\.url.path))
        var failures = 0
        var staged: [(temp: URL, original: URL, destination: URL)] = []

        for (source, destination) in plan where destination.path != source.path {
            // Taken by a file outside this batch: skip rather than overwrite.
            if fm.fileExists(atPath: destination.path), !sources.contains(destination.path) {
                failures += 1
                continue
            }
            let temp = source.deletingLastPathComponent()
                .appendingPathComponent(".kuk-rename-\(UUID().uuidString)")
            do {
                try fm.moveItem(at: source, to: temp)
                staged.append((temp, source, destination))
            } catch {
                failures += 1
            }
        }

        var renamed: [(original: URL, destination: URL)] = []
        for entry in staged {
            do {
                try fm.moveItem(at: entry.temp, to: entry.destination)
                renamed.append((entry.original, entry.destination))
            } catch {
                // Put it back where it came from.
                try? fm.moveItem(at: entry.temp, to: entry.original)
                failures += 1
            }
        }
        // Tags travel with the files; mirror that in memory until the rescan.
        let before = flags
        var updated = flags
        for entry in renamed { updated[entry.original] = nil }
        for entry in renamed { updated[entry.destination] = before[entry.original] }
        flags = updated
        pendingSelection = renamed.first?.destination
        rescan()
        return failures
    }

    nonisolated static func uniqueDestination(for filename: String, in dir: URL) -> URL {
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
}

/// Row arithmetic for the grid: sections restart the rows, so moving up or
/// down one row depends on where each section starts.
nonisolated enum GridMath {
    static func verticalTarget(
        from index: Int, direction: Int, columns: Int, groupStarts: [Int], total: Int
    ) -> Int {
        let cols = max(1, columns)
        let starts = groupStarts.isEmpty ? [0] : groupStarts
        // Section containing `index`: the last start at or before it.
        var group = 0
        var lo = 0, hi = starts.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= index { group = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        func bounds(_ g: Int) -> (start: Int, count: Int) {
            let start = starts[g]
            let end = g + 1 < starts.count ? starts[g + 1] : total
            return (start, end - start)
        }
        let (start, count) = bounds(group)
        let position = index - start
        let row = position / cols
        let column = position % cols

        if direction < 0 {
            if row > 0 { return start + (row - 1) * cols + column }
            guard group > 0 else { return 0 }
            let previous = bounds(group - 1)
            let lastRow = (previous.count - 1) / cols
            return previous.start + min(lastRow * cols + column, previous.count - 1)
        } else {
            let lastRow = (count - 1) / cols
            if row < lastRow { return start + min((row + 1) * cols + column, count - 1) }
            guard group + 1 < starts.count else { return max(0, total - 1) }
            let next = bounds(group + 1)
            return next.start + min(column, next.count - 1)
        }
    }
}

/// Batch rename naming: a run of `#` becomes a zero-padded counter; without
/// one the counter is appended ("Trip" → Trip-1, Trip-2, …).
nonisolated enum RenamePattern {
    static func name(pattern: String, number: Int) -> String {
        let chars = Array(pattern)
        guard let run = longestHashRun(in: chars) else {
            return PhotosLibraryModel.sanitize("\(pattern)-\(number)")
        }
        let formatted = String(format: "%0\(run.count)d", number)
        let name = String(chars[..<run.lowerBound]) + formatted + String(chars[run.upperBound...])
        return PhotosLibraryModel.sanitize(name)
    }

    static func plan(_ urls: [URL], pattern: String, start: Int) -> [(source: URL, destination: URL)] {
        urls.enumerated().map { offset, url in
            let base = name(pattern: pattern, number: start + offset)
            let ext = url.pathExtension
            let destination = url.deletingLastPathComponent()
                .appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
            return (url, destination)
        }
    }

    /// The longest run of "#" (the first one on ties).
    private static func longestHashRun(in chars: [Character]) -> Range<Int>? {
        var best: Range<Int>?
        var index = 0
        while index < chars.count {
            guard chars[index] == "#" else { index += 1; continue }
            var end = index
            while end < chars.count, chars[end] == "#" { end += 1 }
            if (best?.count ?? 0) < end - index { best = index..<end }
            index = end
        }
        return best
    }
}

/// File operations that run off the main thread.
nonisolated enum FileOperations {
    struct TrashResult: Sendable {
        let trashed: [AppModel.TrashedItem]
        let failures: Int
    }

    static func trash(_ urls: [URL]) -> TrashResult {
        var trashed: [AppModel.TrashedItem] = []
        var failures = 0
        for url in urls {
            do {
                var result: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &result)
                if let trashURL = result as URL? {
                    trashed.append(AppModel.TrashedItem(originalURL: url, trashURL: trashURL))
                }
            } catch {
                failures += 1
            }
        }
        return TrashResult(trashed: trashed, failures: failures)
    }

    static func restore(_ entries: [AppModel.TrashedItem]) -> Int {
        var failures = 0
        for entry in entries {
            do {
                try FileManager.default.moveItem(at: entry.trashURL, to: entry.originalURL)
            } catch {
                failures += 1
            }
        }
        return failures
    }

    /// Copies or moves a file into `dir` under a free name.
    static func transfer(_ source: URL, into dir: URL, move: Bool) -> Bool {
        let destination = AppModel.uniqueDestination(for: source.lastPathComponent, in: dir)
        do {
            if move {
                try FileManager.default.moveItem(at: source, to: destination)
            } else {
                try FileManager.default.copyItem(at: source, to: destination)
            }
            return true
        } catch {
            return false
        }
    }
}

/// Warms thumbnail caches for a window of items and — unlike a fire-and-forget
/// Task per item — cancels work that falls out of the window, so holding an
/// arrow key or flinging the grid doesn't queue hundreds of stale decodes.
@MainActor
final class Prefetcher {
    private var tasks: [ImageItem.ID: Task<Void, Never>] = [:]

    func prefetch(_ window: [ImageItem], pointSize: CGFloat, scale: CGFloat) {
        let wanted = Set(window.map(\.id))
        for (id, task) in tasks where !wanted.contains(id) {
            task.cancel()
            tasks[id] = nil
        }
        for item in window where tasks[item.id] == nil {
            tasks[item.id] = Task(priority: .utility) {
                _ = await ImageLoading.thumbnail(for: item, pointSize: pointSize, scale: scale)
            }
        }
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }
}

nonisolated struct ScanResult: Sendable {
    var items: [ImageItem]
    /// Flags read from the files' Finder tags.
    var flags: [URL: ImageFlag]
}

nonisolated enum ImageScanner {
    /// Returns nil when the scan was cancelled.
    static func scan(_ url: URL, recursive: Bool) -> ScanResult? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .contentTypeKey,
            .contentModificationDateKey, .fileSizeKey, .tagNamesKey
        ]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        // Without this the enumerator still lists every subfolder's contents.
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: options)
        else { return ScanResult(items: [], flags: [:]) }

        var result: [ImageItem] = []
        var flags: [URL: ImageFlag] = [:]
        result.reserveCapacity(1024)
        let keySet = Set(keys)

        for case let fileURL as URL in enumerator {
            // The walk of a huge tree must die with its task — the result of a
            // cancelled scan is discarded by the generation check anyway.
            if Task.isCancelled { return nil }
            guard let values = try? fileURL.resourceValues(forKeys: keySet),
                  values.isRegularFile == true,
                  let type = values.contentType,
                  type.conforms(to: .image)
            else { continue }
            let mod = values.contentModificationDate ?? .distantPast
            let size = Int64(values.fileSize ?? 0)
            result.append(ImageItem(url: fileURL, modifiedAt: mod, fileSize: size))
            if let flag = FinderTags.flag(fromTagNames: values.tagNames) { flags[fileURL] = flag }
        }
        return ScanResult(items: result, flags: flags)
    }
}

nonisolated extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// One folder row in the sidebar tree. Subfolders and the image count are
/// listed lazily — a row scans when it appears (to know whether to show a
/// chevron) and re-scans on every expansion so the tree stays reasonably fresh.
struct FolderTreeRow: View {
    @Environment(AppModel.self) private var model
    let url: URL
    let isRoot: Bool

    @State private var info: FolderInfo?
    /// Images in the whole subtree; only loaded when that count is shown.
    @State private var total: ImageTotal?
    @AppStorage("hideEmptyFolders") private var hideEmptyFolders = false
    @AppStorage("countSubfolderImages") private var countSubfolderImages = false

    nonisolated struct Subfolder: Hashable, Sendable {
        let url: URL
        /// True when this folder or anything below it holds at least one image.
        let hasImages: Bool
    }

    nonisolated struct FolderInfo: Sendable {
        let subfolders: [Subfolder]
        let imageCount: Int
    }

    private var visibleSubfolders: [Subfolder] {
        guard let info else { return [] }
        return hideEmptyFolders ? info.subfolders.filter(\.hasImages) : info.subfolders
    }

    var body: some View {
        Group {
            if info != nil, visibleSubfolders.isEmpty {
                label
            } else {
                DisclosureGroup(isExpanded: expandedBinding) {
                    ForEach(visibleSubfolders, id: \.self) { sub in
                        FolderTreeRow(url: sub.url, isRoot: false)
                    }
                } label: {
                    label
                }
            }
        }
        // Keyed on items.count for the displayed folder, so deleting or adding
        // images refreshes this row's count right away — and on the hide flag,
        // which changes how much of the subtree has to be inspected.
        .task(id: "\(url.path)|\(isCurrent ? model.items.count : -1)|\(hideEmptyFolders)|\(countSubfolderImages)") {
            info = await Self.scan(url, deep: hideEmptyFolders)
            // The displayed folder's total bypasses the cache so a delete shows at once.
            total = countSubfolderImages
                ? await FolderIndex.shared.imageTotal(url, fresh: isCurrent)
                : nil
        }
        .onChange(of: isExpanded) { _, open in
            guard open else { return }
            Task { info = await Self.scan(url, deep: hideEmptyFolders) }
        }
        .id(url.path)
    }

    private var isCurrent: Bool { model.folder?.path == url.path }

    /// Images directly in the folder, or in its whole subtree when the
    /// "count images in subfolders" preference is on. Nil hides the badge.
    private var countText: String? {
        if countSubfolderImages {
            guard let total, total.count > 0 else { return nil }
            return total.isCapped ? "\(total.count)+" : "\(total.count)"
        }
        guard let count = info?.imageCount, count > 0 else { return nil }
        return "\(count)"
    }

    /// Expansion lives in the model so folder navigation can reveal a folder.
    private var isExpanded: Bool { model.expandedPaths.contains(url.path) }

    private var expandedBinding: Binding<Bool> {
        Binding(
            get: { model.expandedPaths.contains(url.path) },
            set: { open in
                if open { model.expandedPaths.insert(url.path) } else { model.expandedPaths.remove(url.path) }
            }
        )
    }

    private var label: some View {
        Button {
            model.display(folder: url)
        } label: {
            HStack(spacing: 4) {
                Label(url.lastPathComponent, systemImage: isRoot ? "folder.fill" : "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let countText {
                    Text(verbatim: countText)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .help(url.path)
        .foregroundStyle(isCurrent ? Color.accentColor : .primary)
        .contextMenu {
            if isRoot {
                Button("Close Folder") { model.closeRoot(url) }
                Divider()
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
        }
    }

    /// One directory pass: collects subfolders and counts images directly in
    /// this folder (not recursive — the tree shows per-folder counts). With
    /// `deep`, each subfolder is additionally probed for images anywhere below
    /// it, so empty branches can be hidden without losing access to nested ones.
    nonisolated static func scan(_ url: URL, deep: Bool) async -> FolderInfo {
        let listing = await Task.detached(priority: .utility) { () -> (subfolders: [URL], imageCount: Int) in
            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentTypeKey]
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else { return ([], 0) }

            var subfolders: [URL] = []
            var imageCount = 0
            for item in contents {
                guard let values = try? item.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isDirectory == true {
                    if values.isPackage != true { subfolders.append(item) }
                } else if values.contentType?.conforms(to: .image) == true {
                    imageCount += 1
                }
            }
            subfolders.sort {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            return (subfolders, imageCount)
        }.value

        guard deep else {
            return FolderInfo(
                subfolders: listing.subfolders.map { Subfolder(url: $0, hasImages: true) },
                imageCount: listing.imageCount
            )
        }

        var probed: [Subfolder] = []
        probed.reserveCapacity(listing.subfolders.count)
        for sub in listing.subfolders {
            probed.append(Subfolder(url: sub, hasImages: await FolderIndex.shared.containsImages(sub)))
        }
        return FolderInfo(subfolders: probed, imageCount: listing.imageCount)
    }
}

/// Number of images in a folder's whole subtree. `isCapped` means the walk
/// stopped early on a huge tree and the real number is higher.
nonisolated struct ImageTotal: Equatable, Sendable {
    let count: Int
    let isCapped: Bool
}

/// Remembers whether a folder's subtree holds any image at all. The walk is far
/// too expensive to redo every time the sidebar redraws, and answers stay valid
/// for a couple of minutes — the tree re-scans on expansion anyway.
actor FolderIndex {
    static let shared = FolderIndex()

    private static let ttl: TimeInterval = 120

    private struct Entry: Sendable {
        let value: Bool
        let checked: Date
    }

    private var cache: [URL: Entry] = [:]
    private var inFlight: [URL: Task<Bool, Never>] = [:]

    private struct TotalEntry: Sendable {
        let value: ImageTotal
        let checked: Date
    }

    private var totals: [URL: TotalEntry] = [:]
    private var totalsInFlight: [URL: Task<ImageTotal, Never>] = [:]

    func containsImages(_ url: URL) async -> Bool {
        if let entry = cache[url], Date().timeIntervalSince(entry.checked) < Self.ttl {
            return entry.value
        }
        if let running = inFlight[url] { return await running.value }

        let task = Task.detached(priority: .utility) { Self.subtreeContainsImages(url) }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        cache[url] = Entry(value: result, checked: Date())
        return result
    }

    /// Counts the images in the subtree, cached like `containsImages`.
    /// `fresh` skips the cache (the displayed folder after a change).
    func imageTotal(_ url: URL, fresh: Bool = false) async -> ImageTotal {
        if !fresh, let entry = totals[url], Date().timeIntervalSince(entry.checked) < Self.ttl {
            return entry.value
        }
        if let running = totalsInFlight[url] { return await running.value }

        let task = Task.detached(priority: .utility) { Self.countImages(in: url) }
        totalsInFlight[url] = task
        let result = await task.value
        totalsInFlight[url] = nil
        totals[url] = TotalEntry(value: result, checked: Date())
        return result
    }

    /// Walks the whole subtree counting images. Gives up after a large number
    /// of entries so a pathological tree can't keep the sidebar busy forever.
    nonisolated static func countImages(in url: URL, limit: Int = 200_000) -> ImageTotal {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentTypeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return ImageTotal(count: 0, isCapped: false) }

        var count = 0
        var examined = 0
        for case let fileURL as URL in enumerator {
            examined += 1
            if examined > limit { return ImageTotal(count: count, isCapped: true) }
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  values.contentType?.conforms(to: .image) == true
            else { continue }
            count += 1
        }
        return ImageTotal(count: count, isCapped: false)
    }

    /// Walks the subtree and stops at the first image. Deliberately gives up
    /// after a large number of entries and answers "yes" rather than stalling
    /// the sidebar on a pathological directory.
    nonisolated static func subtreeContainsImages(_ url: URL) -> Bool {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentTypeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return false }

        var examined = 0
        for case let fileURL as URL in enumerator {
            examined += 1
            if examined > 20_000 { return true }
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  values.contentType?.conforms(to: .image) == true
            else { continue }
            return true
        }
        return false
    }
}

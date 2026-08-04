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

    @State private var isExpanded = false
    @State private var info: FolderInfo?
    @AppStorage("hideEmptyFolders") private var hideEmptyFolders = false

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
                DisclosureGroup(isExpanded: $isExpanded) {
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
        .task(id: "\(url.path)|\(isCurrent ? model.items.count : -1)|\(hideEmptyFolders)") {
            info = await Self.scan(url, deep: hideEmptyFolders)
        }
        .onChange(of: isExpanded) { _, open in
            guard open else { return }
            Task { info = await Self.scan(url, deep: hideEmptyFolders) }
        }
    }

    private var isCurrent: Bool { model.folder?.path == url.path }

    private var label: some View {
        Button {
            model.display(folder: url)
        } label: {
            HStack(spacing: 4) {
                Label(url.lastPathComponent, systemImage: isRoot ? "folder.fill" : "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let count = info?.imageCount, count > 0 {
                    Text("\(count)")
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

    func containsImages(_ url: URL) async -> Bool {
        if let entry = cache[url], Date().timeIntervalSince(entry.checked) < Self.ttl {
            return entry.value
        }
        if let running = inFlight[url] { return await running.value }

        let task = Task.detached(priority: .utility) { Self.probe(url) }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        cache[url] = Entry(value: result, checked: Date())
        return result
    }

    /// Walks the subtree and stops at the first image. Deliberately gives up
    /// after a large number of entries and answers "yes" rather than stalling
    /// the sidebar on a pathological directory.
    nonisolated private static func probe(_ url: URL) -> Bool {
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

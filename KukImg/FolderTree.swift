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

    nonisolated struct FolderInfo: Sendable {
        let subfolders: [URL]
        let imageCount: Int
    }

    var body: some View {
        Group {
            if let info, info.subfolders.isEmpty {
                label
            } else {
                DisclosureGroup(isExpanded: $isExpanded) {
                    ForEach(info?.subfolders ?? [], id: \.self) { sub in
                        FolderTreeRow(url: sub, isRoot: false)
                    }
                } label: {
                    label
                }
            }
        }
        // Keyed on items.count for the displayed folder, so deleting or adding
        // images refreshes this row's count right away.
        .task(id: "\(url.path)|\(isCurrent ? model.items.count : -1)") {
            info = await Self.scan(url)
        }
        .onChange(of: isExpanded) { _, open in
            guard open else { return }
            Task { info = await Self.scan(url) }
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
    /// this folder (not recursive — the tree shows per-folder counts).
    nonisolated static func scan(_ url: URL) async -> FolderInfo {
        let task = Task.detached(priority: .utility) { () -> FolderInfo in
            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentTypeKey]
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else { return FolderInfo(subfolders: [], imageCount: 0) }

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
            return FolderInfo(subfolders: subfolders, imageCount: imageCount)
        }
        return await task.value
    }
}

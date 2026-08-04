import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ImageGridView: View {
    @Environment(AppModel.self) private var model
    let thumbSize: CGFloat

    @State private var containerWidth: CGFloat = 0
    @State private var visibleRect: CGRect = .zero
    @State private var lastScroll = Date.distantPast
    @FocusState private var focused: Bool
    @Environment(\.displayScale) private var scale
    @AppStorage("showFilenames") private var showFilenames = false

    private let spacing: CGFloat = 8
    private let padding: CGFloat = 8
    /// Extra cell height when filename labels are shown (label + its spacing).
    static let nameLabelHeight: CGFloat = 18

    private var cellHeight: CGFloat {
        thumbSize + (showFilenames ? Self.nameLabelHeight : 0)
    }

    /// Explicit column count shared by layout AND arrow-key navigation, so
    /// up/down always moves exactly one visual row.
    private var columnCount: Int {
        let usable = max(0, containerWidth - padding * 2 + spacing)
        return max(1, Int(usable / (thumbSize + spacing)))
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount)
    }

    private var isGrouped: Bool { !model.groups.isEmpty }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: spacing, pinnedViews: [.sectionHeaders]) {
                    if isGrouped {
                        ForEach(model.groups) { group in
                            Section {
                                cells(for: group.items)
                            } header: {
                                sectionHeader(group)
                            }
                        }
                    } else {
                        cells(for: model.visibleItems)
                    }
                }
                .padding(padding)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onAppear { focused = true }
            .onKeyPress(.leftArrow, phases: .down)  { press in
                horizontal(-1, extend: press.modifiers.contains(.shift))
            }
            .onKeyPress(.rightArrow, phases: .down) { press in
                horizontal(1, extend: press.modifiers.contains(.shift))
            }
            .onKeyPress(.upArrow, phases: .down)    { press in
                vertical(-1, extend: press.modifiers.contains(.shift))
            }
            .onKeyPress(.downArrow, phases: .down)  { press in
                vertical(1, extend: press.modifiers.contains(.shift))
            }
            .onKeyPress(.home)       { model.selectFirst(); return .handled }
            .onKeyPress(.end)        { model.selectLast();  return .handled }
            .onKeyPress(.pageUp)     { page(-1) }
            .onKeyPress(.pageDown)   { page(1) }
            .onKeyPress(.escape)     { escape() }
            .onKeyPress("p") { model.setFlag(.pick, for: model.selectedItems); return .handled }
            .onKeyPress("x") { model.setFlag(.reject, for: model.selectedItems); return .handled }
            .onKeyPress("u") { model.setFlag(nil, for: model.selectedItems); return .handled }
            .onKeyPress(.delete)        { model.deleteCurrent(); return .handled }
            .onKeyPress(.deleteForward) { model.deleteCurrent(); return .handled }
            .onKeyPress(.return)     {
                if model.currentItem != nil { model.isFullscreen = true }
                return .handled
            }
            .onKeyPress(.space)      {
                if model.currentItem != nil { model.isFullscreen = true }
                return .handled
            }
            .onChange(of: model.selection) { _, new in
                guard let new else { return }
                ensureVisible(new, proxy: proxy)
                model.prefetchNeighbors(thumbSize: thumbSize, scale: scale)
            }
            .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, new in
                visibleRect = new
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                containerWidth = $0
            }
        }
    }

    @ViewBuilder
    private func cells(for items: [ImageItem]) -> some View {
        ForEach(items) { item in
            ThumbnailCell(
                item: item,
                size: thumbSize,
                focused: model.selection == item.id,
                marked: model.selectedIDs.contains(item.id),
                selectMode: model.isSelectMode,
                showName: showFilenames,
                flag: model.flag(for: item),
                onToggle: { model.select(item.id, toggling: true) }
            )
            .id(item.id)
            // A plain `.onTapGesture(count: 2)` above a single-tap gesture makes
            // SwiftUI hold every click for the double-click interval before
            // delivering it. Running them simultaneously keeps selection instant;
            // the first click of a double-click selects, the second opens.
            .onTapGesture {
                click(item)
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                model.select(item.id)
                model.isFullscreen = true
            })
            .contextMenu {
                contextMenu(for: item)
            }
        }
    }

    private func sectionHeader(_ group: ImageGroup) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
            Text(group.title)
                .lineLimit(1)
                .truncationMode(.head)
            Text("\(group.items.count)")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .contentShape(.rect)
        .onTapGesture { model.display(folder: group.folder) }
        .help(group.folder.path)
    }

    @ViewBuilder
    private func contextMenu(for item: ImageItem) -> some View {
        let targets = targets(for: item)
        let label = targets.count == 1 ? "" : " (\(targets.count))"

        Button {
            model.select(item.id)
            model.isFullscreen = true
        } label: {
            Label("Open", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        Button { Sharing.share(targets) } label: {
            Label("Share\(label)", systemImage: "square.and.arrow.up")
        }
        Button { model.requestConvert(targets) } label: {
            Label("Convert\(label)…", systemImage: "arrow.triangle.2.circlepath")
        }
        Menu {
            OpenWithMenu(items: targets)
        } label: {
            Label("Open With", systemImage: "arrow.up.forward.app")
        }
        Divider()
        Button { model.rotate(targets, clockwise: false) } label: {
            Label("Rotate Left\(label)", systemImage: "rotate.left")
        }
        .disabled(targets.allSatisfy(\.isAsset))
        Button { model.rotate(targets, clockwise: true) } label: {
            Label("Rotate Right\(label)", systemImage: "rotate.right")
        }
        .disabled(targets.allSatisfy(\.isAsset))
        Button { model.requestRename(targets) } label: {
            Label("Rename\(label)…", systemImage: "pencil")
        }
        .disabled(targets.allSatisfy(\.isAsset))
        Divider()
        Button { model.reveal(targets) } label: {
            Label("Show in Finder", systemImage: "folder")
        }
        Button { model.copy(targets) } label: {
            Label("Copy\(label)", systemImage: "doc.on.doc")
        }
        Divider()
        Button(role: .destructive) { model.delete(targets) } label: {
            Label("Move to Trash\(label)", systemImage: "trash")
        }
        .disabled(targets.allSatisfy(\.isAsset))
    }

    /// A context menu acts on the whole selection when the clicked item is part
    /// of it, and on just that item otherwise — the standard Finder behaviour.
    private func targets(for item: ImageItem) -> [ImageItem] {
        model.selectedIDs.contains(item.id) && model.selectedIDs.count > 1
            ? model.selectedItems
            : [item]
    }

    // MARK: - Selection & navigation

    private func click(_ item: ImageItem) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) {
            model.select(item.id, extending: true)
        } else if flags.contains(.command) || model.isSelectMode {
            model.select(item.id, toggling: true)
        } else {
            model.select(item.id)
        }
        focused = true
    }

    private func horizontal(_ offset: Int, extend: Bool) -> KeyPress.Result {
        if extend { model.extendSelection(by: offset) } else { model.move(by: offset) }
        return .handled
    }

    /// First Escape collapses a multi-selection, the next one leaves Select mode.
    private func escape() -> KeyPress.Result {
        if model.hasMultipleSelected {
            model.collapseSelection()
        } else if model.isSelectMode {
            model.isSelectMode = false
        } else {
            return .ignored
        }
        return .handled
    }

    /// Moves roughly one viewport of rows; with grouped sections this is an
    /// approximation (headers aren't counted), which is fine for paging.
    private func page(_ direction: Int) -> KeyPress.Result {
        let rowHeight = cellHeight + spacing
        let rowsPerPage = max(1, Int(visibleRect.height / rowHeight) - 1)
        model.move(by: direction * rowsPerPage * columnCount)
        return .handled
    }

    /// Moves one visual row, keeping the column — section headers mean rows
    /// can't be derived from a flat index once the grid is grouped.
    private func vertical(_ direction: Int, extend: Bool) -> KeyPress.Result {
        let rows = makeRows()
        guard let current = model.selection,
              let rowIndex = rows.firstIndex(where: { $0.contains(current) })
        else {
            model.selectFirst()
            return .handled
        }
        let column = rows[rowIndex].firstIndex(of: current) ?? 0
        let target = rowIndex + direction
        guard rows.indices.contains(target) else {
            let edge = direction < 0 ? model.visibleItems.first?.id : model.visibleItems.last?.id
            if let edge { model.select(edge, extending: extend) }
            return .handled
        }
        let row = rows[target]
        model.select(row[min(column, row.count - 1)], extending: extend)
        return .handled
    }

    private func makeRows() -> [[ImageItem.ID]] {
        let cols = max(1, columnCount)
        let blocks = isGrouped ? model.groups.map(\.items) : [model.visibleItems]
        var rows: [[ImageItem.ID]] = []
        for block in blocks {
            var index = 0
            while index < block.count {
                let end = min(index + cols, block.count)
                rows.append(block[index..<end].map(\.id))
                index = end
            }
        }
        return rows
    }

    /// Scrolls only when the selected cell is outside the viewport, and skips
    /// the animation while an arrow key is held down (rapid successive moves).
    /// With sections the exact row offsets are unknown, so the proxy's own
    /// minimal scrolling takes over.
    private func ensureVisible(_ id: ImageItem.ID, proxy: ScrollViewProxy) {
        if !isGrouped {
            guard let idx = model.visibleItems.firstIndex(where: { $0.id == id }) else { return }
            let row = idx / columnCount
            let rowHeight = cellHeight + spacing
            let minY = padding + CGFloat(row) * rowHeight
            let maxY = minY + cellHeight
            if visibleRect.height > 0, minY >= visibleRect.minY, maxY <= visibleRect.maxY {
                return
            }
        }
        let now = Date()
        let animate = now.timeIntervalSince(lastScroll) > 0.25
        lastScroll = now
        if animate {
            withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id) }
        } else {
            proxy.scrollTo(id)
        }
    }
}

struct ThumbnailCell: View {
    let item: ImageItem
    let size: CGFloat
    /// The keyboard/detail focus — exactly one cell at a time.
    let focused: Bool
    /// Part of the multi-selection.
    let marked: Bool
    let selectMode: Bool
    let showName: Bool
    let flag: ImageFlag?
    let onToggle: () -> Void

    @State private var image: NSImage?
    @State private var hovering = false
    @Environment(\.displayScale) private var scale

    private var bucket: CGFloat { ThumbnailCache.bucket(for: size) }
    private var showsCheckbox: Bool { selectMode || marked || hovering }

    var body: some View {
        VStack(spacing: 2) {
            thumbnail
            if showName {
                Text(item.name)
                    .font(.caption2)
                    .foregroundStyle(focused || marked ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: size, height: 16)
            }
        }
        .modifier(DraggableIfFile(item: item, preview: dragPreview))
        .help(item.name)
        // Keyed on the bucket too: moving the size slider re-fetches a sharper
        // version while the old image stays visible (no flash back to spinner).
        // And on modifiedAt, so an externally overwritten file re-renders.
        .task(id: "\(item.id.path)|\(item.modifiedAt.timeIntervalSince1970)|\(bucket)") {
            if let img = await ImageLoading.thumbnail(for: item, pixelSize: bucket, scale: scale) {
                image = img
            }
        }
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
                    .padding(3)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(borderColor, lineWidth: 3)
        )
        .overlay(alignment: .topLeading) {
            if showsCheckbox { checkbox }
        }
        .overlay(alignment: .bottomLeading) {
            if let flag {
                Image(systemName: flag == .pick ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, flag == .pick ? Color.green : Color.red)
                    .shadow(radius: 1)
                    .padding(6)
                    .help(flag == .pick ? "Picked" : "Rejected")
            }
        }
        .scaleEffect(hovering ? 1.03 : 1)
        .brightness(hovering && !focused ? 0.05 : 0)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: marked)
        .onHover { hovering = $0 }
    }

    private var borderColor: Color {
        if focused { .accentColor }
        else if marked { .accentColor.opacity(0.55) }
        else { .clear }
    }

    private var checkbox: some View {
        Button(action: onToggle) {
            Image(systemName: marked ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .symbolRenderingMode(marked ? .palette : .monochrome)
                .foregroundStyle(marked ? Color.white : Color.white.opacity(0.9), Color.accentColor)
                .background(Circle().fill(.black.opacity(marked ? 0 : 0.25)).padding(2))
                .shadow(radius: 1)
        }
        .buttonStyle(.plain)
        .padding(6)
        .help(marked ? "Deselect" : "Select")
    }

    @ViewBuilder
    private var dragPreview: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
        } else {
            Image(systemName: "photo")
                .font(.largeTitle)
                .frame(width: 96, height: 96)
        }
    }
}

/// "Open With" submenu: applications registered for the item's type, default
/// app first. Opening materializes Photos assets on demand.
struct OpenWithMenu: View {
    let items: [ImageItem]

    var body: some View {
        let apps = applications
        if apps.isEmpty {
            Button("No Applications Available") {}.disabled(true)
        } else {
            ForEach(apps, id: \.self) { app in
                Button(FileManager.default.displayName(atPath: app.path)) {
                    open(with: app)
                }
            }
        }
    }

    private var applications: [URL] {
        guard let url = items.first?.url else { return [] }
        let type = UTType(filenameExtension: url.pathExtension) ?? .image
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: type)
            .filter { $0 != Bundle.main.bundleURL }
        apps.sort {
            FileManager.default.displayName(atPath: $0.path)
                .localizedStandardCompare(FileManager.default.displayName(atPath: $1.path)) == .orderedAscending
        }
        if let preferred = NSWorkspace.shared.urlForApplication(toOpen: type),
           let idx = apps.firstIndex(of: preferred) {
            apps.move(fromOffsets: IndexSet(integer: idx), toOffset: 0)
        }
        return apps
    }

    private func open(with app: URL) {
        let targets = items
        Task {
            let urls = await ImageLoading.fileURLs(for: targets)
            guard !urls.isEmpty else { NSSound.beep(); return }
            do {
                try await NSWorkspace.shared.open(
                    urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()
                )
            } catch {
                NSSound.beep()
            }
        }
    }
}

/// Photos assets have no file on disk until they are exported, so only real
/// files are draggable out of the grid.
private struct DraggableIfFile<Preview: View>: ViewModifier {
    let item: ImageItem
    let preview: Preview

    func body(content: Content) -> some View {
        if item.isAsset {
            content
        } else {
            content.draggable(item.url) { preview }
        }
    }
}

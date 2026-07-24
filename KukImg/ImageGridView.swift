import SwiftUI

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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: spacing) {
                    ForEach(model.visibleItems) { item in
                        ThumbnailCell(
                            item: item,
                            size: thumbSize,
                            selected: model.selection == item.id,
                            showName: showFilenames
                        )
                        .id(item.id)
                        .onTapGesture(count: 2) {
                            model.selection = item.id
                            model.isFullscreen = true
                        }
                        .onTapGesture {
                            model.selection = item.id
                            focused = true
                        }
                        .contextMenu {
                            Button {
                                model.selection = item.id
                                model.isFullscreen = true
                            } label: {
                                Label("Open", systemImage: "arrow.up.left.and.arrow.down.right")
                            }
                            Divider()
                            Button { model.reveal(item) } label: {
                                Label("Show in Finder", systemImage: "folder")
                            }
                            Button { model.copy(item) } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            Divider()
                            Button(role: .destructive) { model.delete(item) } label: {
                                Label("Move to Trash", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(padding)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onAppear { focused = true }
            .onKeyPress(.leftArrow)  { model.move(by: -1); return .handled }
            .onKeyPress(.rightArrow) { model.move(by:  1); return .handled }
            .onKeyPress(.upArrow)    { model.move(by: -columnCount); return .handled }
            .onKeyPress(.downArrow)  { model.move(by:  columnCount); return .handled }
            .onKeyPress(.home)       { model.selectFirst(); return .handled }
            .onKeyPress(.end)        { model.selectLast();  return .handled }
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

    /// Scrolls only when the selected cell is outside the viewport, and skips
    /// the animation while an arrow key is held down (rapid successive moves).
    private func ensureVisible(_ id: ImageItem.ID, proxy: ScrollViewProxy) {
        guard let idx = model.visibleItems.firstIndex(where: { $0.id == id }) else { return }
        let row = idx / columnCount
        let rowHeight = cellHeight + spacing
        let minY = padding + CGFloat(row) * rowHeight
        let maxY = minY + cellHeight

        if visibleRect.height > 0, minY >= visibleRect.minY, maxY <= visibleRect.maxY {
            return
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
    let selected: Bool
    let showName: Bool

    @State private var image: NSImage?
    @State private var hovering = false
    @Environment(\.displayScale) private var scale

    private var bucket: CGFloat { ThumbnailCache.bucket(for: size) }

    var body: some View {
        VStack(spacing: 2) {
            thumbnail
            if showName {
                Text(item.name)
                    .font(.caption2)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: size, height: 16)
            }
        }
        .draggable(item.url) { dragPreview }
        .help(item.name)
        // Keyed on the bucket too: moving the size slider re-fetches a sharper
        // version while the old image stays visible (no flash back to spinner).
        .task(id: "\(item.url.path)|\(bucket)") {
            if let img = await ThumbnailCache.shared.thumbnail(
                for: item.url, pixelSize: bucket, scale: scale
            ) {
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
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3)
        )
        .scaleEffect(hovering ? 1.03 : 1)
        .brightness(hovering && !selected ? 0.05 : 0)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
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

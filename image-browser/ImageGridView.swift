import SwiftUI

struct ImageGridView: View {
    @Environment(AppModel.self) private var model
    let thumbSize: CGFloat

    @State private var containerWidth: CGFloat = 0
    @FocusState private var focused: Bool
    @Environment(\.displayScale) private var scale

    private var columnCount: Int {
        let spacing: CGFloat = 8
        let padding: CGFloat = 16
        let usable = max(0, containerWidth - padding + spacing)
        return max(1, Int(usable / (thumbSize + spacing)))
    }

    var body: some View {
        @Bindable var model = model
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: thumbSize), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(model.items) { item in
                        ThumbnailCell(
                            item: item,
                            size: thumbSize,
                            selected: model.selection == item.id
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
                            Button("Open") {
                                model.selection = item.id
                                model.isFullscreen = true
                            }
                            Divider()
                            Button("Show in Finder") { model.reveal(item) }
                            Button("Copy") { model.copy(item) }
                            Divider()
                            Button("Move to Trash") { model.delete(item) }
                        }
                    }
                }
                .padding(8)
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
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(new, anchor: .center)
                }
                model.prefetchNeighbors(thumbSize: thumbSize, scale: scale)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                containerWidth = $0
            }
        }
    }
}

struct ThumbnailCell: View {
    let item: ImageItem
    let size: CGFloat
    let selected: Bool

    @State private var image: NSImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
                    .padding(2)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Color.accentColor : .clear, lineWidth: 3)
        )
        .task(id: item.id) {
            self.image = await ThumbnailCache.shared.thumbnail(
                for: item.url, pixelSize: size, scale: scale
            )
        }
    }
}

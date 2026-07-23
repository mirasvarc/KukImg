import SwiftUI
import AppKit
import ImageIO

struct DetailView: View {
    let item: ImageItem
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var scale

    @State private var fullImage: NSImage?
    @State private var preview: NSImage?
    @State private var zoom: CGFloat = 1.0

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                if let img = fullImage ?? preview {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: img)
                            .resizable()
                            .interpolation(fullImage == nil ? .low : .high)
                            .scaledToFit()
                            .scaleEffect(zoom)
                            .frame(
                                minWidth: img.size.width * zoom,
                                minHeight: img.size.height * zoom
                            )
                    }
                    .overlay(alignment: .topTrailing) {
                        if fullImage == nil {
                            ProgressView()
                                .controlSize(.small)
                                .padding(8)
                                .background(.thinMaterial, in: Capsule())
                                .padding(8)
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            if model.showInfoPanel {
                Divider()
                InfoPanel(item: item)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.showInfoPanel)
        .toolbar {
            ToolbarItemGroup {
                Button { zoom = max(0.1, zoom / 1.25) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                Button { zoom = 1.0 } label: { Text("\(Int(zoom * 100))%") }
                Button { zoom = min(20, zoom * 1.25) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
            }
        }
        .navigationTitle(item.name)
        .task(id: item.id) {
            zoom = 1.0
            fullImage = nil
            preview = await ThumbnailCache.shared.thumbnail(
                for: item.url, pixelSize: 1024, scale: scale
            )
            let url = item.url
            let img = await Task.detached(priority: .userInitiated) {
                FullImageLoader.load(url: url)
            }.value
            if !Task.isCancelled { fullImage = img }
        }
    }
}

nonisolated enum FullImageLoader {
    static func load(url: URL) -> NSImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts as CFDictionary),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
    }
}

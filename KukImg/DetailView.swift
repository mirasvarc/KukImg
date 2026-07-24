import SwiftUI
import AppKit

struct DetailView: View {
    let item: ImageItem
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var scale

    @State private var fullImage: NSImage?
    @State private var preview: NSImage?
    @State private var pixelSize: CGSize?
    @State private var zoomMode: ZoomMode = .fit
    @State private var containerSize: CGSize = .zero
    @State private var magnifyBase: CGFloat?

    enum ZoomMode: Equatable {
        case fit
        case zoom(CGFloat) // 1.0 = one image pixel per screen pixel
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                if let img = fullImage ?? preview {
                    imageView(img)
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
            .onGeometryChange(for: CGSize.self) { $0.size } action: { containerSize = $0 }

            if model.showInfoPanel {
                Divider()
                InfoPanel(item: item)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.showInfoPanel)
        .toolbar {
            ToolbarItemGroup {
                Button { setZoom(currentZoom / 1.25) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                Button { setZoom(1.0) } label: { Text(zoomLabel) }
                Button { setZoom(currentZoom * 1.25) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                Button { zoomMode = .fit } label: { Text("Fit") }
                    .disabled(zoomMode == .fit)
            }
        }
        .navigationTitle(item.name)
        .onChange(of: model.zoomRequest) { _, request in
            guard let request else { return }
            switch request.command {
            case .zoomIn:     setZoom(currentZoom * 1.25)
            case .zoomOut:    setZoom(currentZoom / 1.25)
            case .actualSize: setZoom(1.0)
            case .fit:        zoomMode = .fit
            }
        }
        .task(id: item.id) {
            zoomMode = .fit
            fullImage = nil
            preview = nil

            async let meta = MetadataCache.shared.metadata(for: item.url)
            preview = await ThumbnailCache.shared.thumbnail(
                for: item.url, pixelSize: 2048, scale: scale
            )
            if let w = await meta.pixelWidth, let h = await meta.pixelHeight {
                pixelSize = CGSize(width: w, height: h)
            } else {
                pixelSize = nil
            }

            let img = await FullImageCache.shared.image(for: item.url)
            if !Task.isCancelled, let img {
                fullImage = img
                if pixelSize == nil { pixelSize = img.size }
            }
        }
    }

    @ViewBuilder
    private func imageView(_ img: NSImage) -> some View {
        switch zoomMode {
        case .fit:
            Image(nsImage: img)
                .resizable()
                .interpolation(fullImage == nil ? .medium : .high)
                .scaledToFit()
                .padding(4)
                .gesture(magnifyGesture)
                .onTapGesture(count: 2) { zoomMode = .zoom(1.0) }
        case .zoom(let z):
            let size = displaySize(zoom: z)
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(fullImage == nil ? .medium : .high)
                    .frame(width: size.width, height: size.height)
                    .gesture(magnifyGesture)
                    .onTapGesture(count: 2) { zoomMode = .fit }
            }
        }
    }

    // MARK: - Zoom

    private var imagePointSize: CGSize {
        guard let px = pixelSize, px.width > 0, px.height > 0 else {
            return CGSize(width: 1, height: 1)
        }
        return CGSize(width: px.width / scale, height: px.height / scale)
    }

    private func displaySize(zoom: CGFloat) -> CGSize {
        let pts = imagePointSize
        return CGSize(width: pts.width * zoom, height: pts.height * zoom)
    }

    /// Zoom factor that fits the image into the current container.
    private var fittedZoom: CGFloat {
        let pts = imagePointSize
        guard containerSize.width > 0, containerSize.height > 0 else { return 1 }
        return min(containerSize.width / pts.width, containerSize.height / pts.height)
    }

    private var currentZoom: CGFloat {
        switch zoomMode {
        case .fit: fittedZoom
        case .zoom(let z): z
        }
    }

    private var zoomLabel: String {
        switch zoomMode {
        case .fit: "Fit · \(Int((fittedZoom * 100).rounded()))%"
        case .zoom(let z): "\(Int((z * 100).rounded()))%"
        }
    }

    private func setZoom(_ z: CGFloat) {
        zoomMode = .zoom(z.clamped(to: 0.05...20))
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = magnifyBase ?? currentZoom
                magnifyBase = base
                setZoom(base * value.magnification)
            }
            .onEnded { _ in magnifyBase = nil }
    }
}

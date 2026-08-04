import SwiftUI
import AppKit
import ImageIO

enum ZoomMode: Equatable {
    case fit
    case zoom(CGFloat)  // 1.0 = one image pixel per screen pixel
}

/// Zoom arithmetic shared by the detail view and the fullscreen viewer.
struct ZoomMath {
    let containerSize: CGSize
    let pixelSize: CGSize?
    let displayScale: CGFloat

    var imagePointSize: CGSize {
        guard let px = pixelSize, px.width > 0, px.height > 0 else {
            return CGSize(width: 1, height: 1)
        }
        return CGSize(width: px.width / displayScale, height: px.height / displayScale)
    }

    /// Zoom factor that fits the image into the current container.
    var fittedZoom: CGFloat {
        let pts = imagePointSize
        guard containerSize.width > 0, containerSize.height > 0 else { return 1 }
        return min(containerSize.width / pts.width, containerSize.height / pts.height)
    }

    func zoomValue(of mode: ZoomMode) -> CGFloat {
        switch mode {
        case .fit: fittedZoom
        case .zoom(let z): z
        }
    }

    func apply(_ command: ZoomCommand, to mode: ZoomMode) -> ZoomMode {
        switch command {
        case .zoomIn:     .zoom((zoomValue(of: mode) * 1.25).clamped(to: 0.05...20))
        case .zoomOut:    .zoom((zoomValue(of: mode) / 1.25).clamped(to: 0.05...20))
        case .actualSize: .zoom(1.0)
        case .fit:        .fit
        }
    }

    func label(for mode: ZoomMode) -> String {
        switch mode {
        case .fit: "Fit · \(Int((fittedZoom * 100).rounded()))%"
        case .zoom(let z): "\(Int((z * 100).rounded()))%"
        }
    }
}

/// The image surface shared by DetailView and FullscreenView: progressive
/// loading (instant 2048px preview → debounced display-size decode → lazy
/// native decode once zoom needs it), animated GIF playback, zoom & pan, and
/// display-size prefetching of the neighbours.
struct PhotoCanvas: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var scale
    let item: ImageItem
    @Binding var zoomMode: ZoomMode
    /// Native pixel dimensions, reported for the parent's zoom label.
    @Binding var pixelSize: CGSize?
    let backgroundColor: NSColor

    @State private var fullImage: NSImage?
    @State private var preview: NSImage?
    /// Set for multi-frame images (GIF); playback happens in the AppKit layer.
    @State private var animatedURL: URL?
    /// True while `fullImage` is a display-size decode of a larger original.
    @State private var fullImageIsCapped = false
    /// Set when the current zoom outresolves the capped decode; drives the
    /// lazy native-size decode task.
    @State private var nativeRequest: ImageItem?

    var body: some View {
        ZStack {
            Color(nsColor: backgroundColor)
            if let image = fullImage ?? preview {
                ZoomableImageView(
                    image: image,
                    animatedURL: animatedURL,
                    pointSize: documentPointSize(fallback: image),
                    backgroundColor: backgroundColor,
                    zoom: $zoomMode
                )
                .overlay(alignment: .topTrailing) {
                    if fullImage == nil && animatedURL == nil {
                        ProgressView()
                            .controlSize(.small)
                            .padding(8)
                            .background(.thinMaterial, in: Capsule())
                            .padding(8)
                    }
                }
            } else {
                ProgressView()
                    .tint(backgroundColor == .black ? Color.white : nil)
            }
        }
        .onChange(of: zoomMode) { _, _ in requestNativeIfNeeded() }
        .task(id: nativeRequest) {
            guard let target = nativeRequest else { return }
            let img = await ImageLoading.fullImage(for: target)
            if !Task.isCancelled, let img {
                fullImage = img
                fullImageIsCapped = false
            }
        }
        // Keyed on the whole item (not just the URL) so an externally modified
        // file reloads — the item's modifiedAt changes on rescan.
        .task(id: item) { await load() }
    }

    private func documentPointSize(fallback image: NSImage) -> CGSize {
        if let px = pixelSize, px.width > 0, px.height > 0 {
            return CGSize(width: px.width / scale, height: px.height / scale)
        }
        return image.size
    }

    private func load() async {
        zoomMode = .fit
        fullImage = nil
        preview = nil
        pixelSize = nil
        animatedURL = nil
        fullImageIsCapped = false
        nativeRequest = nil

        preview = await ImageLoading.thumbnail(for: item, pixelSize: 2048, scale: scale)

        // Debounce the expensive part: while an arrow key is held, skim on the
        // instant previews instead of decoding (and for Photos assets
        // exporting) every photo the selection merely passes.
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }

        if let meta = await ImageLoading.metadata(for: item),
           let w = meta.pixelWidth, let h = meta.pixelHeight {
            pixelSize = CGSize(width: w, height: h)
        }

        // Photos assets are exported on first use; everything after this point
        // works on a real file just like a folder item does.
        guard let url = await ImageLoading.fileURL(for: item), !Task.isCancelled else { return }

        // Multi-frame images go to the AppKit layer as a file URL — NSImageView
        // plays GIF frames itself; a single decoded frame would freeze them.
        if await Self.isAnimated(url) {
            animatedURL = url
            return
        }

        let budget = DisplayBudget.maxPixelSize
        let img = await FullImageCache.shared.image(
            for: url, modifiedAt: item.modifiedAt, maxPixelSize: budget
        )
        if !Task.isCancelled, let img {
            fullImage = img
            if let px = pixelSize {
                fullImageIsCapped = max(px.width, px.height) > budget
            } else {
                pixelSize = img.size
            }
            // The user may have zoomed in while the decode was running.
            requestNativeIfNeeded()
        }

        // Warm the neighbours at display size so the next arrow press is
        // instant — forward first, since browsing mostly moves ahead.
        guard !Task.isCancelled, let idx = model.currentIndex else { return }
        if idx + 1 < model.visibleItems.count {
            _ = await ImageLoading.fullImage(for: model.visibleItems[idx + 1], maxPixelSize: budget)
        }
        if idx > 0 {
            _ = await ImageLoading.fullImage(for: model.visibleItems[idx - 1], maxPixelSize: budget)
        }
    }

    /// The capped display-size decode ran out of pixels for the current zoom —
    /// fetch the native-size decode lazily.
    private func requestNativeIfNeeded() {
        guard fullImageIsCapped, case .zoom(let z) = zoomMode, let px = pixelSize else { return }
        if z * max(px.width, px.height) > DisplayBudget.maxPixelSize {
            nativeRequest = item
        }
    }

    nonisolated private static func isAnimated(_ url: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
            return CGImageSourceGetCount(src) > 1
        }.value
    }
}

// MARK: - AppKit zoom & pan

/// NSScrollView-backed image view: native pinch zoom anchored at the cursor,
/// two-finger scroll and drag-to-pan when zoomed, double-click to toggle
/// fit ↔ 100 %. The document is sized so magnification 1.0 means one image
/// pixel per screen pixel, matching `ZoomMode.zoom`'s semantics.
private struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    let animatedURL: URL?
    /// Document size in points (native pixels / screen scale).
    let pointSize: CGSize
    let backgroundColor: NSColor
    @Binding var zoom: ZoomMode

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.005
        scroll.maxMagnification = 20
        scroll.drawsBackground = true
        scroll.contentView = CenteringClipView()
        scroll.postsFrameChangedNotifications = true
        scroll.contentView.postsBoundsChangedNotifications = true

        let imageView = PannableImageView()
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        scroll.documentView = imageView

        context.coordinator.attach(to: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(scroll: scroll, view: self)
    }

    final class Coordinator: NSObject {
        private var view: ZoomableImageView?
        private weak var scroll: NSScrollView?
        private var contentKey: AnyHashable?
        private var isFit = true
        /// Viewport size at the moment fit was last applied. A different size
        /// in `scrollContentChanged` means layout resized the viewport (e.g.
        /// the initial zero → real size pass), not a user zoom.
        private var fitContentSize: CGSize = .zero
        /// Non-zero while the coordinator itself changes the scroll view, so
        /// the resulting notifications aren't echoed back into the binding.
        private var programmaticDepth = 0

        func attach(to scroll: NSScrollView) {
            self.scroll = scroll
            (scroll.documentView as? PannableImageView)?.onDoubleClick = { [weak self] point in
                self?.toggleZoom(at: point)
            }
            let center = NotificationCenter.default
            center.addObserver(
                self, selector: #selector(scrollContentChanged),
                name: NSView.boundsDidChangeNotification, object: scroll.contentView
            )
            center.addObserver(
                self, selector: #selector(containerResized),
                name: NSView.frameDidChangeNotification, object: scroll
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func update(scroll: NSScrollView, view: ZoomableImageView) {
            self.view = view
            self.scroll = scroll
            guard let imageView = scroll.documentView as? PannableImageView else { return }
            programmaticDepth += 1
            defer { programmaticDepth -= 1 }

            scroll.backgroundColor = view.backgroundColor

            // Swapping preview → full decode keeps the zoom; only a genuinely
            // different content (new item, animation) resets anything.
            let key: AnyHashable = view.animatedURL.map(AnyHashable.init)
                ?? AnyHashable(ObjectIdentifier(view.image))
            if contentKey != key {
                contentKey = key
                if let url = view.animatedURL, let animated = NSImage(contentsOf: url) {
                    imageView.image = animated
                } else {
                    imageView.image = view.image
                }
            }
            if imageView.frame.size != view.pointSize {
                imageView.frame = NSRect(origin: .zero, size: view.pointSize)
                if isFit { applyFit() }
            }

            switch view.zoom {
            case .fit:
                if !isFit { applyFit() }
            case .zoom(let z):
                isFit = false
                if abs(scroll.magnification - z) > 0.005 {
                    scroll.setMagnification(z, centeredAt: visibleCenter)
                }
            }
        }

        private func applyFit() {
            guard let scroll, let doc = scroll.documentView,
                  doc.frame.width > 0, doc.frame.height > 0,
                  scroll.contentSize.width > 0, scroll.contentSize.height > 0 else { return }
            programmaticDepth += 1
            defer { programmaticDepth -= 1 }
            scroll.magnify(toFit: doc.frame)
            isFit = true
            fitContentSize = scroll.contentSize
        }

        private func toggleZoom(at point: NSPoint) {
            guard let scroll else { return }
            if isFit {
                programmaticDepth += 1
                scroll.setMagnification(1.0, centeredAt: point)
                programmaticDepth -= 1
                isFit = false
                view?.zoom = .zoom(1.0)
            } else {
                view?.zoom = .fit
                applyFit()
            }
        }

        /// Fires on every scroll/pan/magnification change; forwards genuine
        /// zoom changes (live pinch included) into the SwiftUI binding.
        @objc private func scrollContentChanged(_ note: Notification) {
            guard programmaticDepth == 0, let scroll, view != nil else { return }
            let mag = scroll.magnification
            if isFit {
                if scroll.contentSize != fitContentSize {
                    applyFit()
                    return
                }
                guard let fitMag = fitMagnification, abs(mag - fitMag) > 0.005 else { return }
                isFit = false
            }
            if case .zoom(let z) = view!.zoom, abs(z - mag) < 0.001 { return }
            view?.zoom = .zoom(mag)
        }

        @objc private func containerResized(_ note: Notification) {
            if isFit { applyFit() }
        }

        private var fitMagnification: CGFloat? {
            guard let scroll, let doc = scroll.documentView,
                  doc.frame.width > 0, doc.frame.height > 0,
                  scroll.contentSize.width > 0, scroll.contentSize.height > 0 else { return nil }
            return min(
                scroll.contentSize.width / doc.frame.width,
                scroll.contentSize.height / doc.frame.height
            )
        }

        private var visibleCenter: NSPoint {
            guard let scroll else { return .zero }
            let bounds = scroll.contentView.bounds
            return NSPoint(x: bounds.midX, y: bounds.midY)
        }
    }
}

/// Keeps a document smaller than the viewport centered instead of pinned to
/// the bottom-left corner.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if doc.frame.width < rect.width {
            rect.origin.x = (doc.frame.width - rect.width) / 2
        }
        if doc.frame.height < rect.height {
            rect.origin.y = (doc.frame.height - rect.height) / 2
        }
        return rect
    }
}

/// Grab-and-drag panning plus double-click zoom toggling on the document view.
private final class PannableImageView: NSImageView {
    var onDoubleClick: ((NSPoint) -> Void)?
    private var lastWindowPoint: NSPoint?

    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?(convert(event.locationInWindow, from: nil))
        } else {
            lastWindowPoint = event.locationInWindow
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = lastWindowPoint,
              let clip = superview as? NSClipView,
              let scroll = enclosingScrollView else { return }
        let current = event.locationInWindow
        lastWindowPoint = current
        let magnification = max(scroll.magnification, 0.001)
        var origin = clip.bounds.origin
        origin.x -= (current.x - last.x) / magnification
        origin.y -= (current.y - last.y) / magnification
        clip.setBoundsOrigin(
            clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        )
        scroll.reflectScrolledClipView(clip)
    }

    override func mouseUp(with event: NSEvent) {
        lastWindowPoint = nil
    }
}

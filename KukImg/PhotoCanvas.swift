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
        case .fit:
            let percent = Int((fittedZoom * 100).rounded())
            return String(localized: "Fit · \(percent)%")
        case .zoom(let z):
            return "\(Int((z * 100).rounded()))%"
        }
    }
}

/// The image surface shared by DetailView and FullscreenView: progressive
/// loading, animation playback, zoom & pan, and prefetching of the neighbours.
///
/// Loading, cheapest first:
/// 1. a decode already in memory (stepping back, or a prefetched neighbour)
///    is shown at once, with no debounce;
/// 2. otherwise the sharpest grid thumbnail in memory bridges the gap;
/// 3. after a short debounce (so a held arrow key skims instead of decoding
///    every photo it passes) the photo is decoded to the viewport's size;
/// 4. the native-resolution decode happens only once zoom needs its pixels.
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
    /// Set for animations; playback happens in the AppKit layer.
    @State private var animatedURL: URL?
    @State private var animationChecked = false
    /// Longest side, in pixels, that `fullImage` resolves; infinite once native.
    @State private var decodedLongest: CGFloat = 0
    /// Decode size the viewport calls for (0 until it has been laid out).
    @State private var tier = 0
    /// The item the current state belongs to.
    @State private var loadedItem: ImageItem?
    /// Set when the current zoom outresolves the decode; drives the lazy
    /// native-size decode task.
    @State private var nativeRequest: ImageItem?

    private struct LoadKey: Hashable {
        let item: ImageItem
        let tier: Int
    }

    private static let native = CGFloat.greatestFiniteMagnitude

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
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            tier = DecodeTier.forViewport(size, scale: scale)
        }
        .onChange(of: zoomMode) { _, _ in requestNativeIfNeeded() }
        .task(id: nativeRequest) {
            guard let target = nativeRequest else { return }
            let img = await ImageLoading.fullImage(for: target)
            if !Task.isCancelled, let img, loadedItem == target {
                fullImage = img
                decodedLongest = Self.native
            }
        }
        // Keyed on the whole item (not just the URL) so an externally modified
        // file reloads — the item's modifiedAt changes on rescan — and on the
        // tier, so growing the window (or entering fullscreen) sharpens it.
        .task(id: LoadKey(item: item, tier: tier)) { await load() }
    }

    private func documentPointSize(fallback image: NSImage) -> CGSize {
        if let px = pixelSize, px.width > 0, px.height > 0 {
            return CGSize(width: px.width / scale, height: px.height / scale)
        }
        // Pixel dimensions not known yet: size the document from the bitmap.
        let px = image.pixelLongestSide
        let pts = max(image.size.width, image.size.height)
        guard px > 0, pts > 0 else { return image.size }
        let factor = px / pts / scale
        return CGSize(width: image.size.width * factor, height: image.size.height * factor)
    }

    private func load() async {
        let target = item
        let cap = tier
        if loadedItem != target {
            loadedItem = target
            zoomMode = .fit
            fullImage = nil
            preview = nil
            pixelSize = nil
            animatedURL = nil
            animationChecked = false
            decodedLongest = 0
            nativeRequest = nil
        }
        guard animatedURL == nil else { return }

        // 1. Already decoded: show it right away.
        if cap > 0, !isResolved(cap),
           let cached = await ImageLoading.cachedDisplayImage(for: target, cap: cap) {
            guard !Task.isCancelled else { return }
            show(cached, cap: cap)
        }
        // 2. Nothing big enough yet: a smaller decode or the best thumbnail
        //    in memory, or a quick thumbnail.
        if fullImage == nil, preview == nil {
            var thumb = await ImageLoading.largestCachedDisplayImage(for: target)
            if thumb == nil {
                thumb = await ImageLoading.cachedThumbnail(for: target, scale: scale)
            }
            if thumb == nil {
                thumb = await ImageLoading.thumbnail(for: target, pointSize: 512, scale: scale)
            }
            guard !Task.isCancelled else { return }
            preview = thumb
        }
        if pixelSize == nil, let meta = await ImageLoading.metadata(for: target),
           let w = meta.pixelWidth, let h = meta.pixelHeight {
            guard !Task.isCancelled else { return }
            pixelSize = CGSize(width: w, height: h)
        }
        guard cap > 0 else { return }

        let needsDecode = !isResolved(cap)
        if needsDecode {
            // 3. Debounce, then decode at viewport size.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
        }
        // Checked even when a decode came from the cache: the neighbour
        // prefetch decodes an animation's first frame like any still image.
        if !animationChecked {
            let url = await ImageLoading.animationURL(for: target)
            guard !Task.isCancelled else { return }
            animationChecked = true
            if let url {
                animatedURL = url
                return
            }
        }
        if needsDecode {
            guard let img = await ImageLoading.displayImage(for: target, cap: cap),
                  !Task.isCancelled else { return }
            show(img, cap: cap)
        }
        // The user may have zoomed in while the decode was running.
        requestNativeIfNeeded()
        await prefetchNeighbours(of: target, cap: cap)
    }

    private func show(_ image: NSImage, cap: Int) {
        fullImage = image
        let longest = image.pixelLongestSide
        // A decode that came out smaller than asked for is the whole image.
        decodedLongest = longest < CGFloat(cap) - 1 ? Self.native : longest
        if pixelSize == nil, decodedLongest == Self.native {
            pixelSize = image.pixelDimensions
        }
    }

    private func isResolved(_ cap: Int) -> Bool {
        fullImage != nil && decodedLongest >= CGFloat(cap) - 1
    }

    /// Warms the neighbours at the same size so the next arrow press is
    /// instant, forward first since browsing mostly moves ahead.
    private func prefetchNeighbours(of target: ImageItem, cap: Int) async {
        guard let idx = model.index(of: target.id) else { return }
        let items = model.visibleItems
        for offset in [1, 2, -1] {
            guard !Task.isCancelled else { return }
            let neighbour = idx + offset
            guard items.indices.contains(neighbour) else { continue }
            _ = await ImageLoading.displayImage(for: items[neighbour], cap: cap)
        }
    }

    /// The decode ran out of pixels for the current zoom — fetch the
    /// native-size decode lazily.
    private func requestNativeIfNeeded() {
        guard fullImage != nil, decodedLongest < Self.native,
              case .zoom(let z) = zoomMode, let px = pixelSize else { return }
        if z * max(px.width, px.height) > decodedLongest * 1.05 {
            nativeRequest = item
        }
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
        imageView.animates = false
        scroll.documentView = imageView

        context.coordinator.attach(to: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(scroll: scroll, view: self)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.stopAnimation()
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
        private var animation: AnimationPlayer?

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
                stopAnimation()
                imageView.image = view.image
                if let url = view.animatedURL { startAnimation(url, in: imageView) }
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

        /// Plays GIF, APNG and animated WebP/HEICS frame by frame. ImageIO
        /// decodes the frames itself, so even a huge animation never loads on
        /// the main thread in one go.
        private func startAnimation(_ url: URL, in imageView: NSImageView) {
            let player = AnimationPlayer(imageView: imageView)
            animation = player
            CGAnimateImageAtURLWithBlock(url as CFURL, nil) { _, frame, stop in
                if !player.show(frame) { stop.pointee = true }
            }
        }

        func stopAnimation() {
            animation?.stop()
            animation = nil
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
            guard programmaticDepth == 0, let scroll, let view else { return }
            let mag = scroll.magnification
            if isFit {
                if scroll.contentSize != fitContentSize {
                    applyFit()
                    return
                }
                guard let fitMag = fitMagnification, abs(mag - fitMag) > 0.005 else { return }
                isFit = false
            }
            if case .zoom(let z) = view.zoom, abs(z - mag) < 0.001 { return }
            view.zoom = .zoom(mag)
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

/// Receives animation frames from ImageIO and tells it to stop once the view
/// shows something else.
nonisolated private final class AnimationPlayer: @unchecked Sendable {
    private weak var imageView: NSImageView?
    private var stopped = false
    private let lock = NSLock()

    init(imageView: NSImageView) {
        self.imageView = imageView
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    /// Returns false when playback should end.
    func show(_ frame: CGImage) -> Bool {
        lock.lock()
        let isStopped = stopped
        lock.unlock()
        guard !isStopped else { return false }
        let image = NSImage(cgImage: frame, size: .zero)
        let apply: @Sendable () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                guard let view = self?.imageView else { return }
                view.image = image
            }
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
        return true
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

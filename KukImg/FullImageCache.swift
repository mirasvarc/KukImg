import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Decode sizes for on-screen viewing. A photo is decoded to the viewport it is
/// shown in (rounded up to a 512 px step so the detail pane and a slightly
/// resized window share entries), not to its native resolution: that is what
/// keeps stepping through 50-megapixel files quick. Native decode happens only
/// when zoom actually needs the extra pixels.
nonisolated enum DecodeTier {
    static let step = 512
    static let minimum = 1024
    static let maximum = 8192

    /// The longest side, in pixels, an image fitted into `viewport` can have.
    static func forViewport(_ viewport: CGSize, scale: CGFloat) -> Int {
        let longest = max(viewport.width, viewport.height) * scale
        guard longest > 0 else { return 0 }
        let rounded = Int((longest / CGFloat(step)).rounded(.up)) * step
        return min(maximum, max(minimum, rounded))
    }

    /// Tiers at or above `cap`, used to find a cached decode that is big enough.
    static func tiers(atLeast cap: Int) -> [Int] {
        guard cap <= maximum else { return [] }
        return Array(stride(from: max(cap, minimum), through: maximum, by: step))
    }
}

/// Cache of decoded images so stepping back to a recent photo is instant.
/// Entries are keyed by their decode cap; a native decode (cap 0) satisfies
/// any request.
actor FullImageCache {
    static let shared = FullImageCache()

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 16
        c.totalCostLimit = 768 * 1024 * 1024
        return c
    }()

    /// Decodes started but not finished, so the viewer and the neighbour
    /// prefetch asking for the same photo share one decode instead of racing.
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    private static func baseKey(_ item: ImageItem) -> String {
        switch item.origin {
        case .file:          "f|\(item.url.path)|\(item.modifiedAt.timeIntervalSince1970)"
        case .asset:         "a|\(item.url.path)"
        }
    }

    /// A decode already in memory that is at least `cap` pixels on its longest
    /// side (nil `cap` asks for native only).
    func cached(for item: ImageItem, cap: Int?) -> NSImage? {
        let base = Self.baseKey(item)
        if let native = cache.object(forKey: "\(base)|0" as NSString) { return native }
        guard let cap else { return nil }
        for tier in DecodeTier.tiers(atLeast: cap) {
            if let image = cache.object(forKey: "\(base)|\(tier)" as NSString) { return image }
        }
        return nil
    }

    /// The sharpest decode of the item in memory at any size — a good
    /// stand-in while a bigger one is decoded (e.g. entering fullscreen).
    func largestCached(for item: ImageItem) -> NSImage? {
        let base = Self.baseKey(item)
        if let native = cache.object(forKey: "\(base)|0" as NSString) { return native }
        for tier in DecodeTier.tiers(atLeast: DecodeTier.minimum).reversed() {
            if let image = cache.object(forKey: "\(base)|\(tier)" as NSString) { return image }
        }
        return nil
    }

    /// `cap` limits the decode's longest side; nil decodes natively.
    func image(for item: ImageItem, cap: Int?) async -> NSImage? {
        if let hit = cached(for: item, cap: cap) { return hit }
        let key = "\(Self.baseKey(item))|\(cap ?? 0)"
        if let running = inFlight[key] { return await running.value }

        // Deliberately not tied to the caller's cancellation: other waiters
        // may join, and a finished decode is cached for the next arrow-key hit.
        let task = Task.detached(priority: .userInitiated) {
            await Self.load(item, cap: cap)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            cache.setObject(image, forKey: key as NSString, cost: image.estimatedByteCost)
        }
        return image
    }

    private nonisolated static func load(_ item: ImageItem, cap: Int?) async -> NSImage? {
        switch item.origin {
        case .file:
            return ImageDecoder.decode(url: item.url, maxPixelSize: cap.map(CGFloat.init))
        case .asset(let id):
            // PhotoKit renders a display-size image from its own derivatives
            // (often without touching iCloud); only deep zoom needs the export.
            if let cap, let image = await PhotosImages.image(for: id, pixelSize: CGFloat(cap), quality: .display) {
                return image
            }
            guard let url = await PhotosMaterializer.shared.fileURL(for: id, cachedAt: item.url) else {
                return nil
            }
            return ImageDecoder.decode(url: url, maxPixelSize: cap.map(CGFloat.init))
        }
    }
}

nonisolated enum ImageDecoder {
    /// Full-image decode. Uses CGImageSourceCreateThumbnailAtIndex even for the
    /// native size because, unlike CGImageSourceCreateImageAtIndex, it applies
    /// the EXIF orientation, so portrait photos aren't shown rotated.
    ///
    /// Camera RAW files carry a large embedded JPEG preview; when it is close
    /// to the requested size it is used instead of demosaicing the raw data,
    /// which is what makes stepping through RAW folders fast.
    static func decode(url: URL, maxPixelSize: CGFloat? = nil) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? CGFloat ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? CGFloat ?? 0
        let native = max(w, h, 1)
        let target = maxPixelSize.map { min($0, native) } ?? native

        if maxPixelSize != nil, isRaw(src), let embedded = thumbnail(src, maxPixelSize: target, fromImage: false),
           CGFloat(max(embedded.width, embedded.height)) >= target * 0.8 {
            return NSImage(cgImage: embedded, size: CGSize(width: embedded.width, height: embedded.height))
        }
        guard let cg = thumbnail(src, maxPixelSize: target, fromImage: true) else { return nil }
        return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
    }

    /// Small thumbnail for the grid when QuickLook can't make one. RAW files
    /// use their embedded preview; other formats decode the image (a JPEG's
    /// embedded EXIF thumbnail is far too small for a grid cell).
    static func thumbnail(url: URL, maxPixelSize: CGFloat) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let cg = thumbnail(src, maxPixelSize: maxPixelSize, fromImage: !isRaw(src))
            ?? thumbnail(src, maxPixelSize: maxPixelSize, fromImage: true)
        else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    private static func thumbnail(_ src: CGImageSource, maxPixelSize: CGFloat, fromImage: Bool) -> CGImage? {
        if Task.isCancelled { return nil }
        let opts: [CFString: Any] = [
            fromImage ? kCGImageSourceCreateThumbnailFromImageAlways
                      : kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 1)
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func isRaw(_ src: CGImageSource) -> Bool {
        guard let type = CGImageSourceGetType(src) as String?, let uti = UTType(type) else { return false }
        return uti.conforms(to: .rawImage)
    }

    /// True only for genuinely animated formats. Multi-image containers such
    /// as multi-page TIFF, ICO or RAW files with previews are not animations.
    static func isAnimated(url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(src) > 1,
              let type = CGImageSourceGetType(src) as String?,
              let uti = UTType(type)
        else { return false }
        return uti.conforms(to: .gif) || uti.conforms(to: .png) || uti.conforms(to: .webP)
            || uti.identifier == "public.heics"
    }
}

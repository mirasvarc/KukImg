import AppKit
import ImageIO

/// Decode target for on-screen viewing: the longest attached-display side in
/// device pixels with 1.5× headroom, so "Fit" and moderate zooms stay
/// pixel-perfect while 100-megapixel originals aren't fully decoded just to be
/// shown scaled down. Native-resolution decode happens lazily on deep zoom.
enum DisplayBudget {
    static var maxPixelSize: CGFloat {
        let longest = NSScreen.screens
            .map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }
            .max()
        return ((longest ?? 3456) * 1.5).rounded()
    }
}

/// Cache of decoded images so stepping back to a recent photo is instant.
/// Entries are keyed by their decode cap — display-size and native-size
/// versions of the same photo are distinct entries.
actor FullImageCache {
    static let shared = FullImageCache()

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        // Display-size images are a fraction of a native decode, so more of
        // them fit — the cost limit keeps huge native decodes in check.
        c.countLimit = 12
        c.totalCostLimit = 1024 * 1024 * 1024
        return c
    }()

    /// Decodes started but not finished, so DetailView and FullscreenView
    /// asking for the same photo share one decode instead of racing.
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    /// `modifiedAt` keys the cache entry, so an externally overwritten file is
    /// re-decoded after the next rescan instead of served stale.
    /// `maxPixelSize` caps the decode (longest side); nil decodes natively.
    func image(for url: URL, modifiedAt: Date, maxPixelSize: CGFloat? = nil) async -> NSImage? {
        let cap = maxPixelSize.map { Int($0) } ?? 0
        let key = "\(url.path)|\(modifiedAt.timeIntervalSince1970)|\(cap)"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let running = inFlight[key] { return await running.value }

        // Deliberately not tied to the caller's cancellation: other waiters
        // may join, and a finished decode is cached for the next arrow-key hit.
        let task = Task.detached(priority: .userInitiated) {
            FullImageLoader.load(url: url, maxPixelSize: maxPixelSize)
        }
        inFlight[key] = task
        let img = await task.value
        inFlight[key] = nil
        if let img {
            cache.setObject(img, forKey: key as NSString, cost: img.estimatedByteCost)
        }
        return img
    }
}

nonisolated enum FullImageLoader {
    /// Uses CGImageSourceCreateThumbnailAtIndex even for the native size
    /// because — unlike CGImageSourceCreateImageAtIndex — it can apply the EXIF
    /// orientation transform, so portrait photos aren't shown rotated.
    static func load(url: URL, maxPixelSize: CGFloat? = nil) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? CGFloat ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? CGFloat ?? 0
        let native = max(w, h, 1)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize.map { min($0, native) } ?? native
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
    }
}

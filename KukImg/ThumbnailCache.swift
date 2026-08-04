import AppKit
import QuickLookThumbnailing
import ImageIO

/// Memory cache + QuickLook/CGImageSource backed thumbnail generator.
/// QuickLook reuses macOS's system thumbnail cache (the same one Finder uses),
/// so repeat loads of common formats are essentially free.
actor ThumbnailCache {
    static let shared = ThumbnailCache()

    /// Requested sizes are quantized to these point-size buckets so a moving
    /// zoom slider doesn't generate dozens of variants per image.
    static let buckets: [CGFloat] = [128, 256, 512, 1024, 2048]

    nonisolated static func bucket(for pointSize: CGFloat) -> CGFloat {
        buckets.first { $0 >= pointSize } ?? buckets[buckets.count - 1]
    }

    /// Grid thumbnails (buckets ≤ 512).
    private let thumbs: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 4000
        c.totalCostLimit = 192 * 1024 * 1024
        return c
    }()

    /// Large previews (1024/2048), kept apart so they don't evict grid thumbnails.
    private let previews: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 48
        c.totalCostLimit = 512 * 1024 * 1024
        return c
    }()

    /// `modifiedAt` is part of the cache key, so a file overwritten on disk
    /// gets a fresh thumbnail after the next rescan instead of a stale one.
    func thumbnail(for url: URL, modifiedAt: Date, pixelSize: CGFloat, scale: CGFloat) async -> NSImage? {
        let bucket = Self.bucket(for: pixelSize)
        let cache = bucket > 512 ? previews : thumbs
        let key = "\(url.path)|\(modifiedAt.timeIntervalSince1970)|\(Int(bucket))|\(Int(scale))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        if Task.isCancelled { return nil }

        var generated = await Self.quickLook(url: url, pixelSize: bucket, scale: scale)
        if generated == nil {
            generated = await Self.imageIOOffActor(url: url, pixelSize: bucket * scale)
        }
        guard let img = generated else { return nil }
        cache.setObject(img, forKey: key, cost: img.estimatedByteCost)
        return img
    }

    private static func quickLook(url: URL, pixelSize: CGFloat, scale: CGFloat) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: pixelSize, height: pixelSize),
            scale: scale,
            representationTypes: .thumbnail
        )
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                    cont.resume(returning: rep?.nsImage)
                }
            }
        } onCancel: {
            QLThumbnailGenerator.shared.cancel(request)
        }
    }

    /// Runs the ImageIO decode on the global pool so it neither blocks the
    /// actor (serializing all lookups) nor ignores caller cancellation.
    private static func imageIOOffActor(url: URL, pixelSize: CGFloat) async -> NSImage? {
        let task = Task.detached(priority: .userInitiated) {
            imageIO(url: url, pixelSize: pixelSize)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func imageIO(url: URL, pixelSize: CGFloat) -> NSImage? {
        if Task.isCancelled { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

}

nonisolated extension NSImage {
    /// Approximate decoded size in bytes for NSCache cost accounting. Uses the
    /// representations' real pixel dimensions — `size` is in points, which
    /// undercounts Retina bitmaps 4×.
    var estimatedByteCost: Int {
        let pixels = representations.reduce(0) { max($0, $1.pixelsWide * $1.pixelsHigh) }
        return pixels > 0 ? pixels * 4 : Int(size.width * size.height * 4)
    }
}

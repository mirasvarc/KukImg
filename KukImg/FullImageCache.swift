import AppKit
import ImageIO

/// Small cache of fully decoded images so stepping back to a recent photo is instant.
actor FullImageCache {
    static let shared = FullImageCache()

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 4
        c.totalCostLimit = 1024 * 1024 * 1024
        return c
    }()

    func image(for url: URL) async -> NSImage? {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let img = await FullImageLoader.load(url: url) else { return nil }
        let cost = Int(img.size.width * img.size.height * 4)
        cache.setObject(img, forKey: key, cost: cost)
        return img
    }
}

nonisolated enum FullImageLoader {
    /// Full-size decode. Uses CGImageSourceCreateThumbnailAtIndex at native size
    /// because — unlike CGImageSourceCreateImageAtIndex — it can apply the EXIF
    /// orientation transform, so portrait photos aren't shown rotated.
    static func load(url: URL) async -> NSImage? {
        let task = Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard !Task.isCancelled,
                  let src = CGImageSourceCreateWithURL(url as CFURL, nil)
            else { return nil }
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            let w = props?[kCGImagePropertyPixelWidth] as? CGFloat ?? 0
            let h = props?[kCGImagePropertyPixelHeight] as? CGFloat ?? 0
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1)
            ]
            guard !Task.isCancelled,
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            else { return nil }
            return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

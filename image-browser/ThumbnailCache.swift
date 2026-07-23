import AppKit
import QuickLookThumbnailing
import ImageIO

/// Memory cache + QuickLook/CGImageSource backed thumbnail generator.
/// QuickLook reuses macOS's system thumbnail cache (the same one Finder uses),
/// so repeat loads of common formats are essentially free.
actor ThumbnailCache {
    static let shared = ThumbnailCache()

    private let memory: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 2000
        c.totalCostLimit = 256 * 1024 * 1024 // ~256 MB
        return c
    }()

    func thumbnail(for url: URL, pixelSize: CGFloat, scale: CGFloat) async -> NSImage? {
        let key = "\(url.path)|\(Int(pixelSize))|\(Int(scale))" as NSString
        if let cached = memory.object(forKey: key) { return cached }

        if let img = await Self.quickLook(url: url, pixelSize: pixelSize, scale: scale)
            ?? Self.imageIO(url: url, pixelSize: pixelSize * scale)
        {
            memory.setObject(img, forKey: key, cost: Self.cost(of: img))
            return img
        }
        return nil
    }

    private static func quickLook(url: URL, pixelSize: CGFloat, scale: CGFloat) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: pixelSize, height: pixelSize),
            scale: scale,
            representationTypes: .thumbnail
        )
        return await withCheckedContinuation { cont in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                cont.resume(returning: rep?.nsImage)
            }
        }
    }

    private static func imageIO(url: URL, pixelSize: CGFloat) -> NSImage? {
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

    private static func cost(of image: NSImage) -> Int {
        let s = image.size
        return Int(s.width * s.height * 4)
    }
}

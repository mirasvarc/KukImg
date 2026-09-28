import AppKit
import QuickLookThumbnailing
import ImageIO
import UniformTypeIdentifiers

/// Memory cache for thumbnails of both origins: files go through QuickLook
/// (which reuses the system thumbnail cache Finder uses) with an ImageIO
/// fallback, Photos assets through PhotoKit.
///
/// Concurrent requests for the same thumbnail share one generation, and that
/// generation is only cancelled once every caller waiting on it has gone.
actor ThumbnailCache {
    static let shared = ThumbnailCache()

    /// Requested point sizes are quantized to these buckets so a moving size
    /// slider doesn't generate dozens of variants per image. Neighbouring steps
    /// are about 1.5× apart, so a cell never gets much more than it needs.
    static let buckets: [CGFloat] = [96, 128, 192, 256, 384, 512, 768, 1024]

    nonisolated static func bucket(for pointSize: CGFloat) -> CGFloat {
        buckets.first { $0 >= pointSize } ?? buckets[buckets.count - 1]
    }

    /// Grid thumbnails (buckets ≤ 512).
    private let thumbs: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 6000
        c.totalCostLimit = 256 * 1024 * 1024
        return c
    }()

    /// Larger previews, kept apart so they don't evict grid thumbnails.
    private let previews: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 64
        c.totalCostLimit = 256 * 1024 * 1024
        return c
    }()

    private struct Pending {
        let id: Int
        let task: Task<NSImage?, Never>
        var waiters: Int
    }

    private var inFlight: [String: Pending] = [:]
    private var nextID = 0

    private func cache(for bucket: CGFloat) -> NSCache<NSString, NSImage> {
        bucket > 512 ? previews : thumbs
    }

    /// `modifiedAt` is part of a file's key, so a file overwritten on disk gets
    /// a fresh thumbnail after the next rescan instead of a stale one.
    private static func key(_ item: ImageItem, bucket: CGFloat, scale: CGFloat) -> String {
        switch item.origin {
        case .file:
            "f|\(item.url.path)|\(item.modifiedAt.timeIntervalSince1970)|\(Int(bucket))|\(Int(scale))"
        case .asset:
            "a|\(item.url.path)|\(Int(bucket))|\(Int(scale))"
        }
    }

    func thumbnail(for item: ImageItem, pointSize: CGFloat, scale: CGFloat) async -> NSImage? {
        let bucket = Self.bucket(for: pointSize)
        let key = Self.key(item, bucket: bucket, scale: scale)
        if let cached = cache(for: bucket).object(forKey: key as NSString) { return cached }
        if Task.isCancelled { return nil }

        let pending: Pending
        if var existing = inFlight[key] {
            existing.waiters += 1
            inFlight[key] = existing
            pending = existing
        } else {
            nextID += 1
            let id = nextID
            let task = Task { () -> NSImage? in
                let image = await Self.generate(item, bucket: bucket, scale: scale)
                self.finish(key: key, id: id, image: image, bucket: bucket)
                return image
            }
            pending = Pending(id: id, task: task, waiters: 1)
            inFlight[key] = pending
        }

        let id = pending.id
        return await withTaskCancellationHandler {
            await pending.task.value
        } onCancel: {
            Task { await self.release(key: key, id: id) }
        }
    }

    /// The largest thumbnail of this item already in memory, if any. Lets the
    /// viewer show something sharp-ish the instant the selection lands.
    func bestCached(for item: ImageItem, scale: CGFloat) -> NSImage? {
        for bucket in Self.buckets.reversed() {
            let key = Self.key(item, bucket: bucket, scale: scale) as NSString
            if let image = cache(for: bucket).object(forKey: key) { return image }
        }
        return nil
    }

    private func finish(key: String, id: Int, image: NSImage?, bucket: CGFloat) {
        if let image {
            cache(for: bucket).setObject(image, forKey: key as NSString, cost: image.estimatedByteCost)
        }
        if inFlight[key]?.id == id { inFlight[key] = nil }
    }

    private func release(key: String, id: Int) {
        guard var pending = inFlight[key], pending.id == id else { return }
        pending.waiters -= 1
        if pending.waiters <= 0 {
            pending.task.cancel()
            inFlight[key] = nil
        } else {
            inFlight[key] = pending
        }
    }

    // MARK: - Generation

    private nonisolated static func generate(_ item: ImageItem, bucket: CGFloat, scale: CGFloat) async -> NSImage? {
        switch item.origin {
        case .file:
            if let image = await quickLook(url: item.url, pointSize: bucket, scale: scale) { return image }
            if Task.isCancelled { return nil }
            let url = item.url
            return await offActor { ImageDecoder.thumbnail(url: url, maxPixelSize: bucket * scale) }
        case .asset(let id):
            return await PhotosImages.image(for: id, pixelSize: bucket * scale, quality: .thumbnail)
        }
    }

    /// `size` is in points: QuickLook multiplies it by `scale`.
    private nonisolated static func quickLook(url: URL, pointSize: CGFloat, scale: CGFloat) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: pointSize, height: pointSize),
            scale: scale,
            representationTypes: .thumbnail
        )
        // QLThumbnailGenerator is thread-safe, its requests just aren't
        // annotated Sendable.
        let box = UncheckedSendable(request)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                QLThumbnailGenerator.shared.generateBestRepresentation(for: box.value) { rep, _ in
                    cont.resume(returning: rep?.nsImage)
                }
            }
        } onCancel: {
            QLThumbnailGenerator.shared.cancel(box.value)
        }
    }

    /// Runs a synchronous decode on the global pool, forwarding cancellation.
    private nonisolated static func offActor(_ work: @escaping @Sendable () -> NSImage?) async -> NSImage? {
        let task = Task.detached(priority: .userInitiated) { work() }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

nonisolated struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

nonisolated extension NSImage {
    /// Real bitmap dimensions. Taken from the backing CGImage: for images made
    /// from a CGImage, `representations` report pixel sizes scaled by the
    /// screen's backing factor (2× on Retina), and `size` is in points.
    var pixelDimensions: CGSize {
        if let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return CGSize(width: cg.width, height: cg.height)
        }
        let rep = representations.max { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }
        if let rep, rep.pixelsWide > 0 {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return size
    }

    /// Approximate decoded size in bytes for NSCache cost accounting.
    var estimatedByteCost: Int {
        let px = pixelDimensions
        return max(1, Int(px.width * px.height * 4))
    }

    /// Longest side in real pixels.
    var pixelLongestSide: CGFloat {
        let px = pixelDimensions
        return max(px.width, px.height)
    }
}

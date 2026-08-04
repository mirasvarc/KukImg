import AppKit

/// Single entry point for turning an `ImageItem` into pixels or a real file on
/// disk. Plain files go straight to the existing URL-based caches; Photos
/// assets get their thumbnails from PhotoKit and are only exported to the cache
/// directory when something genuinely needs a file (full view, share, convert,
/// copy, metadata).
nonisolated enum ImageLoading {
    static func thumbnail(for item: ImageItem, pixelSize: CGFloat, scale: CGFloat) async -> NSImage? {
        switch item.origin {
        case .file:
            await ThumbnailCache.shared.thumbnail(
                for: item.url, modifiedAt: item.modifiedAt, pixelSize: pixelSize, scale: scale
            )
        case .asset(let id):
            await PhotosThumbnailCache.shared.thumbnail(for: id, pixelSize: pixelSize, scale: scale)
        }
    }

    /// `maxPixelSize` caps the decode (longest side); nil decodes natively —
    /// viewing passes `DisplayBudget.maxPixelSize`, copy/deep-zoom pass nil.
    static func fullImage(for item: ImageItem, maxPixelSize: CGFloat? = nil) async -> NSImage? {
        guard let url = await fileURL(for: item) else { return nil }
        return await FullImageCache.shared.image(
            for: url, modifiedAt: item.modifiedAt, maxPixelSize: maxPixelSize
        )
    }

    /// Metadata without forcing a Photos export: assets answer from PhotoKit
    /// (dimensions, capture date, GPS) until a cached file exists; real files
    /// read their EXIF from disk as before.
    static func metadata(for item: ImageItem) async -> ImageMetadata? {
        switch item.origin {
        case .file:
            return await MetadataCache.shared.metadata(for: item.url, modifiedAt: item.modifiedAt)
        case .asset(let id):
            if FileManager.default.fileExists(atPath: item.url.path) {
                return await MetadataCache.shared.metadata(for: item.url, modifiedAt: item.modifiedAt)
            }
            return await PhotosMetadata.metadata(for: id, fileSize: item.fileSize)
        }
    }

    /// A URL that really exists on disk, materializing a Photos asset first.
    /// Returns nil when the export fails (asset missing, iCloud unreachable).
    static func fileURL(for item: ImageItem) async -> URL? {
        switch item.origin {
        case .file:
            return item.url
        case .asset(let id):
            return await PhotosMaterializer.shared.fileURL(for: id, cachedAt: item.url)
        }
    }

    /// Materializes many items at once, skipping any that fail.
    static func fileURLs(for items: [ImageItem]) async -> [URL] {
        var urls: [URL] = []
        for item in items {
            if let url = await fileURL(for: item) { urls.append(url) }
        }
        return urls
    }
}

/// Presents the standard macOS share sheet. Anchoring on the mouse location
/// keeps it usable from the toolbar, a context menu and the fullscreen overlay
/// without each call site having to hand over an NSView.
enum Sharing {
    static func share(_ items: [ImageItem]) {
        guard !items.isEmpty else { NSSound.beep(); return }
        Task {
            let urls = await ImageLoading.fileURLs(for: items)
            guard !urls.isEmpty, let view = NSApp.keyWindow?.contentView else {
                NSSound.beep()
                return
            }
            let picker = NSSharingServicePicker(items: urls)
            picker.show(relativeTo: anchorRect(in: view), of: view, preferredEdge: .minY)
        }
    }

    private static func anchorRect(in view: NSView) -> CGRect {
        guard let window = view.window else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = view.convert(inWindow, from: nil)
        guard view.bounds.contains(point) else {
            return CGRect(x: view.bounds.midX, y: view.bounds.maxY - 1, width: 1, height: 1)
        }
        return CGRect(x: point.x, y: point.y, width: 1, height: 1)
    }
}

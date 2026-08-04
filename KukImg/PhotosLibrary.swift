import AppKit
import Photos

/// A browsable collection in the system Photos library. Only the identifier is
/// kept — fetches are re-run on demand so the list never goes stale.
nonisolated struct PhotoAlbum: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case allPhotos
        case favorites
        case recents
        case collection(String)
    }

    let kind: Kind
    let title: String
    let symbol: String
    let count: Int

    var id: String {
        switch kind {
        case .allPhotos:          "kuk.allPhotos"
        case .favorites:          "kuk.favorites"
        case .recents:            "kuk.recents"
        case .collection(let id): id
        }
    }
}

@Observable
final class PhotosLibraryModel {
    /// Albums past this many images are truncated so a huge library can't
    /// stall the grid with an enormous item list.
    static let assetLimit = 50_000

    private(set) var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var albums: [PhotoAlbum] = []
    private(set) var isLoadingAlbums = false
    /// Total asset count of the last album when it exceeded `assetLimit`.
    private(set) var truncatedFrom: Int?

    var isAuthorized: Bool { status == .authorized || status == .limited }
    var isDenied: Bool { status == .denied || status == .restricted }

    func requestAccess() async {
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if isAuthorized { await loadAlbums() }
    }

    func loadAlbums() async {
        guard isAuthorized, !isLoadingAlbums else { return }
        isLoadingAlbums = true
        albums = await Task.detached(priority: .userInitiated) { Self.fetchAlbums() }.value
        isLoadingAlbums = false
    }

    func items(in album: PhotoAlbum) async -> [ImageItem] {
        let limit = Self.assetLimit
        let kind = album.kind
        let result = await Task.detached(priority: .userInitiated) {
            Self.fetchItems(kind: kind, limit: limit)
        }.value
        truncatedFrom = result.total > result.items.count ? result.total : nil
        return result.items
    }

    // MARK: - Fetching

    nonisolated private static func fetchAlbums() -> [PhotoAlbum] {
        var result: [PhotoAlbum] = []

        let allCount = PHAsset.fetchAssets(with: .image, options: nil).count
        result.append(PhotoAlbum(
            kind: .allPhotos, title: "All Photos", symbol: "photo.on.rectangle", count: allCount
        ))

        let smart: [(PHAssetCollectionSubtype, PhotoAlbum.Kind, String, String)] = [
            (.smartAlbumFavorites, .favorites, "Favorites", "heart"),
            (.smartAlbumRecentlyAdded, .recents, "Recents", "clock")
        ]
        for (subtype, kind, title, symbol) in smart {
            let collections = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum, subtype: subtype, options: nil
            )
            guard let collection = collections.firstObject else { continue }
            let count = PHAsset.fetchAssets(in: collection, options: imageOptions()).count
            guard count > 0 else { continue }
            result.append(PhotoAlbum(kind: kind, title: title, symbol: symbol, count: count))
        }

        let userAlbums = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .any, options: nil
        )
        var albums: [PhotoAlbum] = []
        userAlbums.enumerateObjects { collection, _, _ in
            let count = PHAsset.fetchAssets(in: collection, options: imageOptions()).count
            guard count > 0 else { return }
            albums.append(PhotoAlbum(
                kind: .collection(collection.localIdentifier),
                title: collection.localizedTitle ?? "Album",
                symbol: "rectangle.stack",
                count: count
            ))
        }
        albums.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return result + albums
    }

    nonisolated private static func imageOptions(sorted: Bool = false) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        if sorted {
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        }
        return options
    }

    nonisolated private struct FetchResult: Sendable {
        let items: [ImageItem]
        let total: Int
    }

    nonisolated private static func fetchItems(kind: PhotoAlbum.Kind, limit: Int) -> FetchResult {
        let options = imageOptions(sorted: true)
        let assets: PHFetchResult<PHAsset>
        switch kind {
        case .allPhotos:
            assets = PHAsset.fetchAssets(with: .image, options: options)
        case .favorites, .recents, .collection:
            guard let collection = collection(for: kind) else {
                return FetchResult(items: [], total: 0)
            }
            assets = PHAsset.fetchAssets(in: collection, options: options)
        }

        let total = assets.count
        var items: [ImageItem] = []
        items.reserveCapacity(min(total, limit))
        assets.enumerateObjects { asset, index, stop in
            if index >= limit { stop.pointee = true; return }
            let filename = sanitize(originalFilename(of: asset) ?? "\(asset.localIdentifier).jpg")
            let url = PhotosMaterializer.cacheURL(assetID: asset.localIdentifier, filename: filename)
            items.append(ImageItem(
                url: url,
                modifiedAt: asset.creationDate ?? asset.modificationDate ?? .distantPast,
                fileSize: 0,
                origin: .asset(asset.localIdentifier)
            ))
        }
        return FetchResult(items: items, total: total)
    }

    /// The original filename via the long-stable "filename" KVC key on PHAsset.
    /// Unlike `PHAssetResource.assetResources` — one XPC round-trip per asset,
    /// tens of seconds over a big library — this is served straight from the
    /// fetch result. Guarded so a macOS that drops the key degrades gracefully.
    nonisolated private static func originalFilename(of asset: PHAsset) -> String? {
        guard asset.responds(to: NSSelectorFromString("filename")) else { return nil }
        return asset.value(forKey: "filename") as? String
    }

    nonisolated private static func collection(for kind: PhotoAlbum.Kind) -> PHAssetCollection? {
        switch kind {
        case .allPhotos:
            return nil
        case .favorites:
            return PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum, subtype: .smartAlbumFavorites, options: nil
            ).firstObject
        case .recents:
            return PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum, subtype: .smartAlbumRecentlyAdded, options: nil
            ).firstObject
        case .collection(let id):
            return PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [id], options: nil
            ).firstObject
        }
    }

    nonisolated static func sanitize(_ component: String) -> String {
        let cleaned = component
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return cleaned.isEmpty ? "photo" : cleaned
    }
}

// MARK: - Metadata

/// Lightweight metadata straight from PhotoKit — dimensions, capture date and
/// GPS — so the status bar and info panel don't force an export (and possibly
/// an iCloud download) of every asset the selection lands on.
nonisolated enum PhotosMetadata {
    static func metadata(for id: String, fileSize: Int64) async -> ImageMetadata? {
        await Task.detached(priority: .userInitiated) { () -> ImageMetadata? in
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
            else { return nil }
            var meta = ImageMetadata()
            meta.pixelWidth = asset.pixelWidth
            meta.pixelHeight = asset.pixelHeight
            meta.dateTaken = asset.creationDate
            meta.fileSize = fileSize > 0 ? fileSize : nil
            if let location = asset.location {
                meta.latitude = location.coordinate.latitude
                meta.longitude = location.coordinate.longitude
            }
            return meta
        }.value
    }
}

// MARK: - Thumbnails

/// Grid thumbnails for Photos assets. Kept separate from `ThumbnailCache`
/// because PhotoKit serves these straight from the library's own cache, with no
/// need to export the original file first.
actor PhotosThumbnailCache {
    static let shared = PhotosThumbnailCache()

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 2000
        c.totalCostLimit = 192 * 1024 * 1024
        return c
    }()

    func thumbnail(for localIdentifier: String, pixelSize: CGFloat, scale: CGFloat) async -> NSImage? {
        let bucket = ThumbnailCache.bucket(for: pixelSize)
        let key = "\(localIdentifier)|\(Int(bucket))|\(Int(scale))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        if Task.isCancelled { return nil }
        guard let image = await Self.request(id: localIdentifier, pixelSize: bucket * scale) else {
            return nil
        }
        cache.setObject(image, forKey: key, cost: image.estimatedByteCost)
        return image
    }

    nonisolated private static func request(id: String, pixelSize: CGFloat) async -> NSImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        else { return nil }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isSynchronous = false

        return await withCheckedContinuation { continuation in
            let box = ContinuationBox(continuation)
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: pixelSize, height: pixelSize),
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                box.resume(image)
            }
        }
    }
}

/// PhotoKit may invoke a request handler more than once (degraded then final);
/// this makes sure the continuation is resumed exactly once.
nonisolated private final class ContinuationBox: @unchecked Sendable {
    private var continuation: CheckedContinuation<NSImage?, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<NSImage?, Never>) {
        self.continuation = continuation
    }

    func resume(_ image: NSImage?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: image)
    }
}

// MARK: - Materialization

/// Exports Photos assets to a cache directory so the rest of Kuk — full-size
/// decoding, metadata, share, convert, copy — keeps working on plain file URLs.
actor PhotosMaterializer {
    static let shared = PhotosMaterializer()

    private var inFlight: [String: Task<URL?, Never>] = [:]

    nonisolated static var cacheRoot: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Kuk/Photos", isDirectory: true)
    }

    nonisolated static func cacheURL(assetID: String, filename: String) -> URL {
        cacheRoot
            .appendingPathComponent(PhotosLibraryModel.sanitize(assetID), isDirectory: true)
            .appendingPathComponent(filename)
    }

    func fileURL(for id: String, cachedAt url: URL) async -> URL? {
        if FileManager.default.fileExists(atPath: url.path) { return url }
        if let existing = inFlight[id] { return await existing.value }

        let task = Task.detached(priority: .userInitiated) {
            await Self.export(id: id, to: url)
        }
        inFlight[id] = task
        let result = await task.value
        inFlight[id] = nil
        return result
    }

    nonisolated private static func export(id: String, to url: URL) async -> URL? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .photo })
                ?? resources.first(where: { $0.type == .fullSizePhoto })
                ?? resources.first
        else { return nil }

        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // writeData refuses to overwrite, and a partial file from an interrupted
        // export would otherwise poison the cache entry forever.
        if fm.fileExists(atPath: url.path) { return url }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        let succeeded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                continuation.resume(returning: error == nil)
            }
        }
        if !succeeded {
            try? fm.removeItem(at: url)
            return nil
        }
        return url
    }

    /// Drops the least recently used exports once the cache grows past `maxBytes`.
    nonisolated static func trimCache(maxBytes: Int64 = 2 * 1024 * 1024 * 1024) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .totalFileAllocatedSizeKey, .contentAccessDateKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: cacheRoot, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return }

        var folders: [(url: URL, size: Int64, accessed: Date)] = []
        var total: Int64 = 0
        for folder in entries {
            guard let files = try? fm.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            ) else { continue }
            var size: Int64 = 0
            var accessed = Date.distantPast
            for file in files {
                let values = try? file.resourceValues(forKeys: Set(keys))
                size += Int64(values?.totalFileAllocatedSize ?? 0)
                accessed = max(accessed, values?.contentAccessDate ?? .distantPast)
            }
            folders.append((folder, size, accessed))
            total += size
        }
        guard total > maxBytes else { return }

        for folder in folders.sorted(by: { $0.accessed < $1.accessed }) {
            guard total > maxBytes else { break }
            try? fm.removeItem(at: folder.url)
            total -= folder.size
        }
    }
}

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

    /// Called (coalesced, on the main actor) after the library changed, so the
    /// displayed album can be refetched.
    @ObservationIgnored var onLibraryChange: (() -> Void)?
    @ObservationIgnored private var changeObserver: PhotosChangeObserver?

    var isAuthorized: Bool { status == .authorized || status == .limited }
    var isDenied: Bool { status == .denied || status == .restricted }

    func requestAccess() async {
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if isAuthorized { await loadAlbums() }
    }

    func loadAlbums() async {
        guard isAuthorized, !isLoadingAlbums else { return }
        if changeObserver == nil {
            changeObserver = PhotosChangeObserver { [weak self] in
                guard let self else { return }
                Task { await self.reloadAlbums() }
                self.onLibraryChange?()
            }
        }
        await reloadAlbums()
    }

    private func reloadAlbums() async {
        guard !isLoadingAlbums else { return }
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

    /// Every image in the library, for the content index. Unlike
    /// `items(in:)` it doesn't touch the album truncation shown in the sidebar.
    func allImageItems() async -> [ImageItem] {
        guard isAuthorized else { return [] }
        return await Task.detached(priority: .utility) {
            Self.fetchItems(kind: .allPhotos, limit: .max).items
        }.value
    }

    // MARK: - Fetching

    nonisolated private static func fetchAlbums() -> [PhotoAlbum] {
        var result: [PhotoAlbum] = []

        let allCount = PHAsset.fetchAssets(with: .image, options: nil).count
        result.append(PhotoAlbum(
            kind: .allPhotos, title: String(localized: "All Photos"), symbol: "photo.on.rectangle", count: allCount
        ))

        let smart: [(PHAssetCollectionSubtype, PhotoAlbum.Kind, String, String)] = [
            (.smartAlbumFavorites, .favorites, String(localized: "Favorites"), "heart"),
            (.smartAlbumRecentlyAdded, .recents, String(localized: "Recents"), "clock")
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
                title: collection.localizedTitle ?? String(localized: "Album"),
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
        var fetched: [PHAsset] = []
        items.reserveCapacity(min(total, limit))
        fetched.reserveCapacity(min(total, limit))
        assets.enumerateObjects { asset, index, stop in
            if index >= limit { stop.pointee = true; return }
            fetched.append(asset)
            let filename = sanitize(originalFilename(of: asset) ?? "\(asset.localIdentifier).jpg")
            let url = PhotosMaterializer.cacheURL(
                assetID: asset.localIdentifier, version: asset.modificationDate, filename: filename
            )
            items.append(ImageItem(
                url: url,
                modifiedAt: asset.creationDate ?? asset.modificationDate ?? .distantPast,
                fileSize: 0,
                origin: .asset(asset.localIdentifier)
            ))
        }
        PhotosAssetRegistry.shared.register(fetched)
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
            guard let asset = PhotosAssetRegistry.shared.asset(for: id) else { return nil }
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

// MARK: - Images

/// PHAsset objects by local identifier, filled from album fetches so image
/// requests don't pay a library query per grid cell.
nonisolated final class PhotosAssetRegistry: @unchecked Sendable {
    static let shared = PhotosAssetRegistry()

    private let lock = NSLock()
    private var assets: [String: PHAsset] = [:]

    func register(_ list: [PHAsset]) {
        lock.lock()
        for asset in list { assets[asset.localIdentifier] = asset }
        lock.unlock()
    }

    func asset(for id: String) -> PHAsset? {
        lock.lock()
        let known = assets[id]
        lock.unlock()
        if let known { return known }
        guard let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        else { return nil }
        register([fetched])
        return fetched
    }
}

/// Rendered images straight from PhotoKit, cancellable with the calling task.
nonisolated enum PhotosImages {
    enum Quality: Sendable {
        /// Grid cells: fast resize, may be served from small local derivatives.
        case thumbnail
        /// The viewer: exact size from the best available local rendition.
        case display
    }

    /// `allowsNetwork: false` returns nil for assets with no local rendition
    /// instead of downloading them from iCloud.
    static func image(
        for id: String, pixelSize: CGFloat, quality: Quality, allowsNetwork: Bool = true
    ) async -> NSImage? {
        guard let asset = PhotosAssetRegistry.shared.asset(for: id) else { return nil }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = allowsNetwork
        options.deliveryMode = .highQualityFormat
        options.resizeMode = quality == .thumbnail ? .fast : .exact
        options.isSynchronous = false

        let box = ImageRequestBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.start(continuation) {
                    PHImageManager.default().requestImage(
                        for: asset,
                        targetSize: CGSize(width: pixelSize, height: pixelSize),
                        contentMode: .aspectFit,
                        options: options
                    ) { image, info in
                        if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                        box.finish(image)
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// Animated GIFs in the library; those are exported and played as files.
    static func isAnimated(_ id: String) -> Bool {
        PhotosAssetRegistry.shared.asset(for: id)?.playbackStyle == .imageAnimated
    }
}

/// Resumes a PhotoKit request's continuation exactly once — on the result, on
/// cancellation, whichever comes first — and cancels the request itself when
/// the waiting task goes away.
nonisolated private final class ImageRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NSImage?, Never>?
    private var requestID: PHImageRequestID?
    private var cancelled = false

    func start(_ continuation: CheckedContinuation<NSImage?, Never>, request: () -> PHImageRequestID) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation
        lock.unlock()

        let id = request()
        lock.lock()
        requestID = id
        let cancelNow = cancelled
        lock.unlock()
        if cancelNow { PHImageManager.default().cancelImageRequest(id) }
    }

    func finish(_ image: NSImage?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: image)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let id = requestID
        lock.unlock()
        if let id { PHImageManager.default().cancelImageRequest(id) }
        finish(nil)
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

    /// The asset's modification date is part of the path: editing a photo in
    /// Photos gives it a new URL, so no cache (in memory or this export
    /// folder) serves the pre-edit version.
    nonisolated static func cacheURL(assetID: String, version: Date?, filename: String) -> URL {
        let stamp = Int(version?.timeIntervalSince1970 ?? 0)
        return cacheRoot
            .appendingPathComponent("\(PhotosLibraryModel.sanitize(assetID))-\(stamp)", isDirectory: true)
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

    nonisolated private static let exportCount = Counter()

    nonisolated private static func export(id: String, to url: URL) async -> URL? {
        guard let asset = PhotosAssetRegistry.shared.asset(for: id) else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        // `.fullSizePhoto` exists only for edited photos and is the version
        // Photos (and Kuk's thumbnails) show; `.photo` is the unedited original.
        guard let resource = resources.first(where: { $0.type == .fullSizePhoto })
                ?? resources.first(where: { $0.type == .photo })
                ?? resources.first
        else { return nil }

        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) { return url }

        // Written under a temporary name and moved into place only when
        // complete, so an export interrupted by quitting never leaves a
        // truncated file that would later pass for a finished one.
        let partial = folder.appendingPathComponent(".partial-\(UUID().uuidString)")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        let succeeded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: partial, options: options) { error in
                continuation.resume(returning: error == nil)
            }
        }
        defer { try? fm.removeItem(at: partial) }
        guard succeeded else { return nil }
        do {
            try fm.moveItem(at: partial, to: url)
        } catch {
            // Another export of the same asset may have won the race.
            return fm.fileExists(atPath: url.path) ? url : nil
        }
        // Browsing a big album exports a lot; keep the cache capped during
        // the session too, not only at launch.
        if exportCount.increment() % 100 == 0 {
            Task.detached(priority: .background) { trimCache() }
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
                at: folder, includingPropertiesForKeys: keys, options: []
            ) else { continue }
            // Leftovers of exports interrupted by quitting.
            for file in files where file.lastPathComponent.hasPrefix(".partial-") {
                try? fm.removeItem(at: file)
            }
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

/// A thread-safe counter.
nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Returns the new count.
    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

// MARK: - Change observation

/// Forwards Photos library changes (new photos, edits, album changes) to the
/// main actor, coalesced so a burst of changes triggers one refresh.
nonisolated final class PhotosChangeObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let onChange: @MainActor @Sendable () -> Void
    private let lock = NSLock()
    private var scheduled = false

    init(onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        let alreadyScheduled = lock.withLock {
            let was = scheduled
            scheduled = true
            return was
        }
        guard !alreadyScheduled else { return }
        let callback = onChange
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            self.lock.withLock { self.scheduled = false }
            callback()
        }
    }
}

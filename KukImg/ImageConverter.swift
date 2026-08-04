import AppKit
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ConversionFormat: String, CaseIterable, Identifiable, Sendable {
    case png, jpeg, heic, tiff, webp, gif, bmp

    var id: String { rawValue }

    var utType: UTType {
        switch self {
        case .png:  .png
        case .jpeg: .jpeg
        case .heic: .heic
        case .tiff: .tiff
        case .webp: .webP
        case .gif:  .gif
        case .bmp:  .bmp
        }
    }

    var label: String {
        switch self {
        case .png:  "PNG"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .tiff: "TIFF"
        case .webp: "WebP"
        case .gif:  "GIF"
        case .bmp:  "BMP"
        }
    }

    var fileExtension: String {
        switch self {
        case .png:  "png"
        case .jpeg: "jpg"
        case .heic: "heic"
        case .tiff: "tiff"
        case .webp: "webp"
        case .gif:  "gif"
        case .bmp:  "bmp"
        }
    }

    var supportsQuality: Bool { self == .jpeg || self == .heic }
    var supportsAlpha: Bool { self == .png || self == .tiff || self == .webp || self == .gif }

    /// Only the formats this macOS build can actually *write* — ImageIO's
    /// encoder list differs between releases, so it is queried at runtime.
    static let available: [ConversionFormat] = {
        let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).map { $0.lowercased() })
        return allCases.filter { writable.contains($0.utType.identifier.lowercased()) }
    }()
}

nonisolated struct ConversionOptions: Sendable {
    var format: ConversionFormat = .png
    /// 0…1, only used by JPEG and HEIC.
    var quality: Double = 0.85
    /// Longest edge in pixels; nil keeps the original size.
    var maxPixelSize: Int?
    /// nil writes next to the original file.
    var destination: URL?
    var deleteOriginals = false
}

nonisolated struct ConversionResult: Identifiable, Sendable {
    let source: URL
    let output: URL?
    let error: String?
    var id: URL { source }
    var succeeded: Bool { output != nil }
}

nonisolated enum ConversionError: LocalizedError {
    case unreadable
    case encodingFailed
    case noDestination

    var errorDescription: String? {
        switch self {
        case .unreadable:     "Could not read the image."
        case .encodingFailed: "Could not write the converted image."
        case .noDestination:  "The destination folder is not writable."
        }
    }
}

nonisolated enum ImageConverter {
    /// Converts one file and returns the URL it was written to.
    static func convert(_ source: URL, options: ConversionOptions) throws -> URL {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(imageSource) > 0
        else { throw ConversionError.unreadable }

        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let hasAlpha = properties?[kCGImagePropertyHasAlpha] as? Bool ?? false
        let needsFlattening = hasAlpha && !options.format.supportsAlpha

        let folder = options.destination ?? source.deletingLastPathComponent()
        let output = uniqueURL(
            in: folder,
            baseName: source.deletingPathExtension().lastPathComponent,
            extension: options.format.fileExtension
        )

        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, options.format.utType.identifier as CFString, 1, nil
        ) else { throw ConversionError.noDestination }

        var destinationProperties: [CFString: Any] = [:]
        if options.format.supportsQuality {
            destinationProperties[kCGImageDestinationLossyCompressionQuality] = options.quality
        }

        if options.maxPixelSize == nil && !needsFlattening {
            // Straight re-encode: this carries EXIF/GPS/ICC across for free.
            CGImageDestinationAddImageFromSource(
                destination, imageSource, 0, destinationProperties as CFDictionary
            )
        } else {
            let maxPixel = options.maxPixelSize.map(CGFloat.init)
                ?? CGFloat(max(properties?[kCGImagePropertyPixelWidth] as? Int ?? 1,
                               properties?[kCGImagePropertyPixelHeight] as? Int ?? 1))
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 1)
            ]
            guard var cgImage = CGImageSourceCreateThumbnailAtIndex(
                imageSource, 0, thumbnailOptions as CFDictionary
            ) else { throw ConversionError.unreadable }

            if needsFlattening, let flattened = flatten(cgImage) { cgImage = flattened }

            if let metadata = properties {
                for (key, value) in normalized(metadata) where destinationProperties[key] == nil {
                    destinationProperties[key] = value
                }
            }
            CGImageDestinationAddImage(destination, cgImage, destinationProperties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: output)
            throw ConversionError.encodingFailed
        }
        return output
    }

    /// Strips the tags that describe the *old* pixels. The resize path hands
    /// ImageIO an already-rotated, already-scaled bitmap, so carrying the
    /// original orientation over would rotate the photo a second time — and it
    /// hides in three places: the top level, the TIFF dictionary and the EXIF
    /// dimensions. Everything else (camera, GPS, dates) is kept.
    private static func normalized(_ properties: [CFString: Any]) -> [CFString: Any] {
        var metadata = properties
        metadata[kCGImagePropertyPixelWidth] = nil
        metadata[kCGImagePropertyPixelHeight] = nil
        metadata[kCGImagePropertyHasAlpha] = nil
        metadata[kCGImagePropertyOrientation] = 1

        if var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            metadata[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = metadata[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = nil
            exif[kCGImagePropertyExifPixelYDimension] = nil
            metadata[kCGImagePropertyExifDictionary] = exif
        }
        return metadata
    }

    /// Composites onto white so transparent areas don't turn black in JPEG/BMP.
    private static func flatten(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    private static func uniqueURL(in folder: URL, baseName: String, extension ext: String) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent("\(baseName).\(ext)")
        var counter = 1
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName)-\(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    /// Number of selected images that hold more than one frame — only the first
    /// one survives a conversion, which is worth warning about.
    static func animatedCount(in urls: [URL]) -> Int {
        urls.reduce(into: 0) { count, url in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
            if CGImageSourceGetCount(source) > 1 { count += 1 }
        }
    }
}

/// Lossless rotation: rewrites the EXIF orientation tag while copying the
/// compressed pixel data untouched (`CGImageDestinationCopyImageSource`), so
/// no generation loss and near-instant even for huge files.
nonisolated enum ImageRotator {
    private static let clockwise: [UInt32: UInt32] = [1: 6, 2: 7, 3: 8, 4: 5, 5: 2, 6: 3, 7: 4, 8: 1]
    private static let counterclockwise: [UInt32: UInt32] = [6: 1, 7: 2, 8: 3, 5: 4, 2: 5, 3: 6, 4: 7, 1: 8]

    static func rotateByExif(_ url: URL, clockwise rotateCW: Bool) throws {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(src)
        else { throw ConversionError.unreadable }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let current = props?[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let map = rotateCW ? clockwise : counterclockwise
        let next = map[current] ?? (rotateCW ? 6 : 8)

        // Written next to the original so the final swap stays on one volume.
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".kuk-rotate-\(UUID().uuidString).\(url.pathExtension)")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else {
            throw ConversionError.noDestination
        }
        let options = [kCGImageDestinationOrientation: next] as CFDictionary
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, src, options, &error) else {
            try? FileManager.default.removeItem(at: tmp)
            throw ConversionError.encodingFailed
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}

/// Runs a batch conversion with bounded concurrency and live progress.
@Observable
final class ConversionJob {
    private(set) var total = 0
    private(set) var completed = 0
    private(set) var results: [ConversionResult] = []
    private(set) var isRunning = false
    private(set) var isFinished = false
    private var task: Task<Void, Never>?

    var succeeded: [ConversionResult] { results.filter(\.succeeded) }
    var failed: [ConversionResult] { results.filter { !$0.succeeded } }
    var progress: Double { total == 0 ? 0 : Double(completed) / Double(total) }

    func start(items: [ImageItem], options: ConversionOptions) {
        guard !isRunning else { return }
        isRunning = true
        isFinished = false
        results = []
        completed = 0
        total = items.count

        task = Task { [weak self] in
            guard let self else { return }
            // Photos assets need a real file on disk before ImageIO can read
            // them — but that file is only a cached copy, never an "original"
            // worth trashing.
            var sources: [(url: URL, isOriginal: Bool)] = []
            for item in items {
                if Task.isCancelled { break }
                if let url = await ImageLoading.fileURL(for: item) {
                    sources.append((url, !item.isAsset))
                } else {
                    self.record(ConversionResult(
                        source: item.url, output: nil, error: "Could not export from Photos."
                    ))
                }
            }

            let limit = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 1))
            await withTaskGroup(of: ConversionResult.self) { group in
                var index = 0
                func addNext() {
                    guard index < sources.count else { return }
                    let source = sources[index]
                    index += 1
                    group.addTask(priority: .userInitiated) {
                        Self.convertOne(source.url, options: options, canTrashSource: source.isOriginal)
                    }
                }
                for _ in 0..<min(limit, sources.count) { addNext() }
                while let result = await group.next() {
                    if Task.isCancelled { group.cancelAll(); break }
                    self.record(result)
                    addNext()
                }
            }

            self.isRunning = false
            self.isFinished = true
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        isFinished = true
    }

    private func record(_ result: ConversionResult) {
        results.append(result)
        completed += 1
    }

    nonisolated private static func convertOne(
        _ url: URL, options: ConversionOptions, canTrashSource: Bool
    ) -> ConversionResult {
        do {
            let output = try ImageConverter.convert(url, options: options)
            if options.deleteOriginals, canTrashSource {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            return ConversionResult(source: url, output: output, error: nil)
        } catch {
            return ConversionResult(
                source: url,
                output: nil,
                error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }
}

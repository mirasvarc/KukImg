import Foundation
import ImageIO

nonisolated struct ImageMetadata: Sendable {
    var pixelWidth: Int?
    var pixelHeight: Int?
    var fileSize: Int64?
    var dateTaken: Date?
    var camera: String?
    var lens: String?
    var iso: Int?
    var shutterSpeed: String?
    var aperture: Double?
    var focalLength: Double?
    var latitude: Double?
    var longitude: Double?
    var colorModel: String?

    var megapixels: Double? {
        guard let w = pixelWidth, let h = pixelHeight else { return nil }
        return (Double(w) * Double(h)) / 1_000_000
    }
}

/// Deduplicates metadata reads (StatusBar and InfoPanel ask for the same file)
/// and remembers results so re-selecting a photo is free.
actor MetadataCache {
    static let shared = MetadataCache()

    private var cache: [URL: ImageMetadata] = [:]
    private var inFlight: [URL: Task<ImageMetadata, Never>] = [:]

    func metadata(for url: URL) async -> ImageMetadata {
        if let cached = cache[url] { return cached }
        if let task = inFlight[url] { return await task.value }
        let task = Task.detached(priority: .userInitiated) {
            MetadataReader.read(url: url)
        }
        inFlight[url] = task
        let meta = await task.value
        inFlight[url] = nil
        if cache.count > 10_000 { cache.removeAll() }
        cache[url] = meta
        return meta
    }
}

nonisolated enum MetadataReader {
    static func read(url: URL) -> ImageMetadata {
        var meta = ImageMetadata()

        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber {
            meta.fileSize = size.int64Value
        }

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return meta }

        meta.pixelWidth = props[kCGImagePropertyPixelWidth] as? Int
        meta.pixelHeight = props[kCGImagePropertyPixelHeight] as? Int
        meta.colorModel = props[kCGImagePropertyColorModel] as? String

        // Stored dimensions are pre-rotation; report what the viewer sees.
        if let o = props[kCGImagePropertyOrientation] as? UInt32, (5...8).contains(o) {
            swap(&meta.pixelWidth, &meta.pixelHeight)
        }

        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let str = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                meta.dateTaken = Self.parseExifDate(str)
            }
            meta.iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
            if let exp = exif[kCGImagePropertyExifExposureTime] as? Double {
                meta.shutterSpeed = Self.formatShutter(exp)
            }
            meta.aperture = exif[kCGImagePropertyExifFNumber] as? Double
            meta.focalLength = exif[kCGImagePropertyExifFocalLength] as? Double
            meta.lens = exif[kCGImagePropertyExifLensModel] as? String
        }

        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let make = (tiff[kCGImagePropertyTIFFMake] as? String) ?? ""
            let model = (tiff[kCGImagePropertyTIFFModel] as? String) ?? ""
            let combined = [make, model].filter { !$0.isEmpty }.joined(separator: " ")
            if !combined.isEmpty { meta.camera = combined }
        }

        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String) ?? "N"
            let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E"
            meta.latitude = lat * (latRef == "S" ? -1 : 1)
            meta.longitude = lon * (lonRef == "W" ? -1 : 1)
        }

        return meta
    }

    private static func parseExifDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: s)
    }

    private static func formatShutter(_ seconds: Double) -> String {
        if seconds >= 1 { return String(format: "%.1fs", seconds) }
        let denom = Int((1.0 / seconds).rounded())
        return "1/\(denom)s"
    }
}

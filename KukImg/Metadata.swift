import Foundation
import ImageIO
import AppKit

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

    private var cache: [String: ImageMetadata] = [:]
    private var inFlight: [String: Task<ImageMetadata, Never>] = [:]

    /// `modifiedAt` keys the entry, so metadata of an externally overwritten
    /// file is re-read after the next rescan instead of served stale.
    func metadata(for url: URL, modifiedAt: Date) async -> ImageMetadata {
        let key = "\(url.path)|\(modifiedAt.timeIntervalSince1970)"
        if let cached = cache[key] { return cached }
        if let task = inFlight[key] { return await task.value }
        let task = Task.detached(priority: .userInitiated) {
            MetadataReader.read(url: url)
        }
        inFlight[key] = task
        let meta = await task.value
        inFlight[key] = nil
        if cache.count > 10_000 { cache.removeAll() }
        cache[key] = meta
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

    /// EXIF dates carry no time zone; like every photo app, read them as
    /// local time.
    private static let exifCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    /// Parses "yyyy:MM:dd HH:mm:ss" by hand: creating a DateFormatter per
    /// file dominated the Date Taken sort of big folders.
    static func parseExifDate(_ s: String) -> Date? {
        var numbers: [Int] = []
        numbers.reserveCapacity(6)
        var current = 0
        var digits = 0
        for byte in s.utf8 {
            if byte >= 48 && byte <= 57 {
                current = current * 10 + Int(byte - 48)
                digits += 1
            } else if digits > 0 {
                numbers.append(current)
                current = 0
                digits = 0
                if numbers.count == 6 { break }
            }
        }
        if digits > 0, numbers.count < 6 { numbers.append(current) }
        guard numbers.count >= 6, numbers[0] > 0, (1...12).contains(numbers[1]), (1...31).contains(numbers[2])
        else { return nil }
        let components = DateComponents(
            year: numbers[0], month: numbers[1], day: numbers[2],
            hour: numbers[3], minute: numbers[4], second: numbers[5]
        )
        return exifCalendar.date(from: components)
    }

    private static func formatShutter(_ seconds: Double) -> String {
        if seconds >= 1 { return String(format: "%.1fs", seconds) }
        let denom = Int((1.0 / seconds).rounded())
        return "1/\(denom)s"
    }

    /// EXIF capture dates for many files at once, read concurrently — used by
    /// the "Date Taken" sort. Photos assets are skipped (their capture date is
    /// already the item's modifiedAt).
    static func dateTakenMap(for items: [ImageItem]) -> [URL: Date] {
        let files = items.filter { !$0.isAsset }
        guard !files.isEmpty else { return [:] }
        // Rescans (every folder change) re-sort the whole folder; only files
        // that are new or changed since the last read hit the disk.
        var result = [URL: Date](minimumCapacity: files.count)
        var missing: [ImageItem] = []
        for item in files {
            switch DateTakenCache.shared.lookup(item) {
            case .some(.some(let date)): result[item.url] = date
            case .some(.none): break
            case .none: missing.append(item)
            }
        }
        guard !missing.isEmpty else { return result }

        let toRead = missing
        DispatchQueue.concurrentPerform(iterations: toRead.count) { index in
            let item = toRead[index]
            DateTakenCache.shared.store(readDateTaken(item.url), for: item)
        }
        for item in toRead {
            if case .some(.some(let date)) = DateTakenCache.shared.lookup(item) { result[item.url] = date }
        }
        return result
    }

    private static func readDateTaken(_ url: URL) -> Date? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, options),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, options) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        return parseExifDate(raw)
    }

    /// Every property ImageIO knows about the file, grouped into sections
    /// (General, Exif, TIFF, GPS, …) for the "All Metadata" panel.
    static func allMetadata(url: URL) -> [MetadataSection] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return [] }

        var general: [MetadataSection.Entry] = []
        var sections: [MetadataSection] = []
        for (key, value) in props {
            if let dict = value as? [CFString: Any] {
                let name = (key as String).trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                let entries = dict
                    .map { MetadataSection.Entry(key: $0.key as String, value: stringify($0.value)) }
                    .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                sections.append(MetadataSection(name: name, entries: entries))
            } else {
                general.append(MetadataSection.Entry(key: key as String, value: stringify(value)))
            }
        }
        general.sort { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        sections.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !general.isEmpty {
            sections.insert(MetadataSection(name: "General", entries: general), at: 0)
        }
        return sections
    }

    private static func stringify(_ value: Any) -> String {
        if let array = value as? [Any] {
            return array.map(stringify).joined(separator: ", ")
        }
        return "\(value)"
    }
}

/// EXIF capture dates by path + mtime, including "has none", so a rescan
/// doesn't reopen every file of the folder.
nonisolated final class DateTakenCache: @unchecked Sendable {
    static let shared = DateTakenCache()

    private let lock = NSLock()
    private var dates: [String: Date?] = [:]

    private static func key(_ item: ImageItem) -> String {
        "\(item.url.path)|\(item.modifiedAt.timeIntervalSince1970)"
    }

    /// nil: not read yet; .some(nil): the file has no capture date.
    func lookup(_ item: ImageItem) -> Date?? {
        let key = Self.key(item)
        return lock.withLock { dates[key] }
    }

    func store(_ date: Date?, for item: ImageItem) {
        let key = Self.key(item)
        lock.withLock {
            if dates.count > 200_000 { dates.removeAll() }
            dates[key] = .some(date)
        }
    }
}

nonisolated struct MetadataSection: Identifiable, Sendable {
    nonisolated struct Entry: Identifiable, Sendable {
        let key: String
        let value: String
        var id: String { key }
    }

    let name: String
    let entries: [Entry]
    var id: String { name }
}

// MARK: - Histogram

nonisolated struct Histogram: Sendable {
    let red: [CGFloat]
    let green: [CGFloat]
    let blue: [CGFloat]  // 64 bins each, normalized to 0…1
}

nonisolated enum HistogramBuilder {
    /// Builds an RGB histogram from a small resample of the image — a 96×96
    /// grid is plenty for the panel-sized curve and costs well under a
    /// millisecond on an already decoded thumbnail.
    static func build(from image: NSImage) -> Histogram? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 96
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))

        var red = [Int](repeating: 0, count: 64)
        var green = red
        var blue = red
        var index = 0
        while index < pixels.count {
            red[Int(pixels[index]) >> 2] += 1
            green[Int(pixels[index + 1]) >> 2] += 1
            blue[Int(pixels[index + 2]) >> 2] += 1
            index += 4
        }
        let peak = CGFloat(max(red.max() ?? 1, green.max() ?? 1, blue.max() ?? 1, 1))
        return Histogram(
            red: red.map { CGFloat($0) / peak },
            green: green.map { CGFloat($0) / peak },
            blue: blue.map { CGFloat($0) / peak }
        )
    }
}

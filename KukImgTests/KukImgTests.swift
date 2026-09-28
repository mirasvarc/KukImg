//
//  KukImgTests.swift
//  KukImgTests
//
//  Created by Miroslav Švarc on 03.05.2026.
//

import Foundation
import CoreServices
import CoreGraphics
import ImageIO
import AppKit
import Testing
@testable import Kuk

// MARK: - Helpers

private func item(_ name: String, in dir: String = "/tmp/kuk", modified: TimeInterval = 0, size: Int64 = 0) -> ImageItem {
    ImageItem(
        url: URL(fileURLWithPath: dir).appendingPathComponent(name),
        modifiedAt: Date(timeIntervalSince1970: modified),
        fileSize: size
    )
}

/// A scratch directory tree, removed when the test ends.
private final class TempTree {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kuk-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func file(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data([0]).write(to: url)
        return url
    }

    @discardableResult
    func folder(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Grid navigation

struct GridMathTests {
    @Test func movesOneRowKeepingTheColumn() {
        // 10 items, 4 columns: rows [0-3] [4-7] [8-9]
        #expect(GridMath.verticalTarget(from: 1, direction: 1, columns: 4, groupStarts: [0], total: 10) == 5)
        #expect(GridMath.verticalTarget(from: 5, direction: -1, columns: 4, groupStarts: [0], total: 10) == 1)
    }

    @Test func clampsIntoAShortLastRow() {
        #expect(GridMath.verticalTarget(from: 7, direction: 1, columns: 4, groupStarts: [0], total: 10) == 9)
    }

    @Test func edgesGoToFirstAndLast() {
        #expect(GridMath.verticalTarget(from: 2, direction: -1, columns: 4, groupStarts: [0], total: 10) == 0)
        #expect(GridMath.verticalTarget(from: 9, direction: 1, columns: 4, groupStarts: [0], total: 10) == 9)
    }

    @Test func sectionsRestartRows() {
        // Sections of 3 and 5 items, 4 columns: [0-2] | [3-6] [7]
        let starts = [0, 3]
        #expect(GridMath.verticalTarget(from: 1, direction: 1, columns: 4, groupStarts: starts, total: 8) == 4)
        #expect(GridMath.verticalTarget(from: 4, direction: -1, columns: 4, groupStarts: starts, total: 8) == 1)
        // Column 3 doesn't exist in the 3-item section above: clamp to its end.
        #expect(GridMath.verticalTarget(from: 6, direction: -1, columns: 4, groupStarts: starts, total: 8) == 2)
        #expect(GridMath.verticalTarget(from: 5, direction: 1, columns: 4, groupStarts: starts, total: 8) == 7)
    }
}

// MARK: - Renaming

struct RenamePatternTests {
    @Test func replacesTheHashRunWithAPaddedCounter() {
        #expect(RenamePattern.name(pattern: "Trip-###", number: 7) == "Trip-007")
        #expect(RenamePattern.name(pattern: "Trip-#", number: 12) == "Trip-12")
    }

    @Test func appendsACounterWithoutHashes() {
        #expect(RenamePattern.name(pattern: "Trip", number: 3) == "Trip-3")
    }

    @Test func usesTheLongestRunAndKeepsOtherHashes() {
        #expect(RenamePattern.name(pattern: "A#B###", number: 5) == "A#B005")
    }

    @Test func sanitizesSlashes() {
        #expect(RenamePattern.name(pattern: "a/b-##", number: 1) == "a_b-01")
    }

    @Test func planKeepsExtensionsAndFolders() {
        let urls = [URL(fileURLWithPath: "/x/IMG_1.JPG"), URL(fileURLWithPath: "/x/IMG_2.heic")]
        let plan = RenamePattern.plan(urls, pattern: "Day-##", start: 1)
        #expect(plan.map(\.destination.path) == ["/x/Day-01.JPG", "/x/Day-02.heic"])
    }
}

// MARK: - Sorting & grouping

struct SortingTests {
    @Test func namesSortNaturally() {
        let items = [item("img10.jpg"), item("img2.jpg"), item("IMG1.jpg")]
        #expect(AppModel.sorted(items, by: .nameAsc).map(\.name) == ["IMG1.jpg", "img2.jpg", "img10.jpg"])
        #expect(AppModel.sorted(items, by: .nameDesc).map(\.name) == ["img10.jpg", "img2.jpg", "IMG1.jpg"])
    }

    @Test func tiesFallBackToTheName() {
        let items = [item("b.jpg", modified: 5), item("a.jpg", modified: 5), item("c.jpg", modified: 9)]
        #expect(AppModel.sorted(items, by: .modifiedDesc).map(\.name) == ["c.jpg", "a.jpg", "b.jpg"])
        let sized = [item("b.jpg"), item("a.jpg")]
        #expect(AppModel.sorted(sized, by: .sizeDesc).map(\.name) == ["a.jpg", "b.jpg"])
    }

    @Test func dateTakenFallsBackToModificationDate() {
        let a = item("a.jpg", modified: 100)
        let b = item("b.jpg", modified: 50)
        let dates = [b.url: Date(timeIntervalSince1970: 500)]
        #expect(AppModel.sorted([a, b], by: .dateTakenDesc, dateTaken: dates).map(\.name) == ["b.jpg", "a.jpg"])
    }

    @Test func groupsPutTheRootFirstThenSubfoldersAlphabetically() {
        let items = [
            item("1.jpg", in: "/r/zeta"),
            item("2.jpg", in: "/r"),
            item("3.jpg", in: "/r/alpha/deep"),
        ]
        let groups = AppModel.group(items, relativeTo: URL(fileURLWithPath: "/r"))
        #expect(groups.map(\.title) == ["r", "alpha / deep", "zeta"])
    }
}

// MARK: - Metadata

struct ExifDateTests {
    @Test func parsesExifDates() throws {
        let date = try #require(MetadataReader.parseExifDate("2024:07:23 14:05:09"))
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        #expect(parts.year == 2024 && parts.month == 7 && parts.day == 23)
        #expect(parts.hour == 14 && parts.minute == 5 && parts.second == 9)
    }

    @Test func rejectsEmptyAndZeroDates() {
        #expect(MetadataReader.parseExifDate("0000:00:00 00:00:00") == nil)
        #expect(MetadataReader.parseExifDate("") == nil)
        #expect(MetadataReader.parseExifDate("2024:07") == nil)
    }
}

// MARK: - Finder tags

struct FinderTagsTests {
    @Test func readsFlagsFromTagNames() {
        #expect(FinderTags.flag(fromTagNames: ["Work", "Pick"]) == .pick)
        #expect(FinderTags.flag(fromTagNames: ["Reject"]) == .reject)
        #expect(FinderTags.flag(fromTagNames: ["Work"]) == nil)
        #expect(FinderTags.flag(fromTagNames: nil) == nil)
    }

    @Test func tagEntriesRoundTrip() throws {
        let entries = ["Pick\n2", "Work"]
        let data = try #require(FinderTags.encode(entries))
        #expect(FinderTags.decode(data) == entries)
        #expect(FinderTags.tagName(of: "Pick\n2") == "Pick")
        #expect(FinderTags.tagName(of: "Work") == "Work")
    }

    @Test func writingReplacesOnlyCullingTags() throws {
        let tree = try TempTree()
        let url = try tree.file("photo.jpg")
        try (url as NSURL).setResourceValue(["Work"], forKey: .tagNamesKey)

        #expect(FinderTags.write(.pick, to: url))
        #expect(Set(try tagNames(url)) == ["Work", "Pick"])

        #expect(FinderTags.write(.reject, to: url))
        #expect(Set(try tagNames(url)) == ["Work", "Reject"])

        #expect(FinderTags.write(nil, to: url))
        #expect(try tagNames(url) == ["Work"])
    }

    private func tagNames(_ url: URL) throws -> [String] {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return try fresh.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
    }
}

// MARK: - Decode sizes

@MainActor
struct DecodeTierTests {
    @Test func roundsTheViewportUpToAStep() {
        #expect(DecodeTier.forViewport(CGSize(width: 1000, height: 700), scale: 2) == 2048)
        #expect(DecodeTier.forViewport(CGSize(width: 1512, height: 982), scale: 2) == 3072)
    }

    @Test func clampsToTheLimits() {
        #expect(DecodeTier.forViewport(.zero, scale: 2) == 0)
        #expect(DecodeTier.forViewport(CGSize(width: 100, height: 100), scale: 1) == DecodeTier.minimum)
        #expect(DecodeTier.forViewport(CGSize(width: 9000, height: 100), scale: 2) == DecodeTier.maximum)
    }

    @Test func largerTiersSatisfySmallerRequests() {
        #expect(DecodeTier.tiers(atLeast: 7680) == [7680, 8192])
        #expect(DecodeTier.tiers(atLeast: 9000).isEmpty)
    }

    @Test func thumbnailBuckets() {
        #expect(ThumbnailCache.bucket(for: 160) == 192)
        #expect(ThumbnailCache.bucket(for: 257) == 384)
        #expect(ThumbnailCache.bucket(for: 5000) == 1024)
    }

    @Test func zoomMath() {
        let math = ZoomMath(
            containerSize: CGSize(width: 500, height: 500),
            pixelSize: CGSize(width: 2000, height: 1000),
            displayScale: 2
        )
        #expect(math.fittedZoom == 0.5)
        #expect(math.apply(.zoomIn, to: .fit) == .zoom(0.625))
        #expect(math.apply(.actualSize, to: .fit) == .zoom(1))
    }
}

// MARK: - Scanning & folder navigation

struct ScannerTests {
    @Test func nonRecursiveScanIgnoresSubfolders() throws {
        let tree = try TempTree()
        try tree.file("a.jpg")
        try tree.file("notes.txt")
        try tree.file("sub/b.jpg")
        try tree.file("sub/deep/c.png")

        let flat = try #require(ImageScanner.scan(tree.root, recursive: false))
        #expect(flat.items.map(\.name) == ["a.jpg"])

        let all = try #require(ImageScanner.scan(tree.root, recursive: true))
        #expect(Set(all.items.map(\.name)) == ["a.jpg", "b.jpg", "c.png"])
    }

    @Test func scanReadsFlagsFromTags() throws {
        let tree = try TempTree()
        let picked = try tree.file("picked.jpg")
        try tree.file("plain.jpg")
        FinderTags.write(.pick, to: picked)

        let result = try #require(ImageScanner.scan(tree.root, recursive: false))
        #expect(result.flags.count == 1)
        #expect(result.flags.first?.value == .pick)
        #expect(result.flags.first?.key.lastPathComponent == "picked.jpg")
    }
}

struct FolderNavigatorTests {
    /// root/ a/ (a1/ img) b/ (empty) c/ img
    private func makeTree() throws -> TempTree {
        let tree = try TempTree()
        try tree.file("root/a/a1/1.jpg")
        try tree.folder("root/b")
        try tree.file("root/c/2.jpg")
        return tree
    }

    @Test func nextSkipsFoldersWithoutImages() throws {
        let tree = try makeTree()
        let root = tree.root.appendingPathComponent("root")
        let a1 = FolderNavigator.step(from: root, roots: [root], forward: true, descend: true)
        #expect(a1?.lastPathComponent == "a1")
        let c = FolderNavigator.step(from: try #require(a1), roots: [root], forward: true, descend: true)
        #expect(c?.lastPathComponent == "c")
        #expect(FolderNavigator.step(from: try #require(c), roots: [root], forward: true, descend: true) == nil)
    }

    @Test func previousWalksBackDepthFirst() throws {
        let tree = try makeTree()
        let root = tree.root.appendingPathComponent("root")
        let c = root.appendingPathComponent("c")
        let back = FolderNavigator.step(from: c, roots: [root], forward: false, descend: true)
        #expect(back?.lastPathComponent == "a1")
    }

    @Test func withSubfoldersIncludedOnlySiblingsAreVisited() throws {
        let tree = try makeTree()
        let root = tree.root.appendingPathComponent("root")
        let a = root.appendingPathComponent("a")
        // "a" has images below it, "b" none at all, so the next stop is "c".
        let next = FolderNavigator.step(from: a, roots: [root], forward: true, descend: false)
        #expect(next?.lastPathComponent == "c")
    }
}

// MARK: - Decoding pipeline

/// Writes a solid-colour image (optionally several frames) with ImageIO.
private func writeImage(_ url: URL, type: String, width: Int, height: Int, frames: Int = 1) throws {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, frames, nil))
    for _ in 0..<frames { CGImageDestinationAddImage(destination, image, nil) }
    #expect(CGImageDestinationFinalize(destination))
}

struct DecodingTests {
    @Test func decodesToTheRequestedSizeOrNative() throws {
        let tree = try TempTree()
        let url = tree.root.appendingPathComponent("big.jpg")
        try writeImage(url, type: "public.jpeg", width: 3000, height: 2000)

        let capped = try #require(ImageDecoder.decode(url: url, maxPixelSize: 1024))
        #expect(capped.pixelLongestSide == 1024)
        let native = try #require(ImageDecoder.decode(url: url))
        #expect(native.pixelLongestSide == 3000)
        // A cap above the native size never upscales.
        let small = try #require(ImageDecoder.decode(url: url, maxPixelSize: 8192))
        #expect(small.pixelLongestSide == 3000)
    }

    @Test func onlyRealAnimationsCountAsAnimated() throws {
        let tree = try TempTree()
        let gif = tree.root.appendingPathComponent("anim.gif")
        let tiff = tree.root.appendingPathComponent("pages.tiff")
        let still = tree.root.appendingPathComponent("still.gif")
        try writeImage(gif, type: "com.compuserve.gif", width: 20, height: 20, frames: 3)
        try writeImage(tiff, type: "public.tiff", width: 20, height: 20, frames: 3)
        try writeImage(still, type: "com.compuserve.gif", width: 20, height: 20)

        #expect(ImageDecoder.isAnimated(url: gif))
        #expect(!ImageDecoder.isAnimated(url: tiff))
        #expect(!ImageDecoder.isAnimated(url: still))
    }

    @Test func aBiggerCachedDecodeServesSmallerRequests() async throws {
        let tree = try TempTree()
        let url = tree.root.appendingPathComponent("photo.jpg")
        try writeImage(url, type: "public.jpeg", width: 4000, height: 3000)
        let photo = ImageItem(url: url, modifiedAt: Date(), fileSize: 0)
        let cache = FullImageCache()

        #expect(await cache.cached(for: photo, cap: 2048) == nil)
        let decoded = try #require(await cache.image(for: photo, cap: 3072))
        #expect(decoded.pixelLongestSide == 3072)
        let reused = await cache.cached(for: photo, cap: 2048)
        #expect(reused === decoded)
        #expect(await cache.cached(for: photo, cap: 3584) == nil)
        #expect(await cache.largestCached(for: photo) === decoded)
    }

    @Test func concurrentThumbnailRequestsShareOneResult() async throws {
        let tree = try TempTree()
        let url = tree.root.appendingPathComponent("thumb.png")
        try writeImage(url, type: "public.png", width: 1200, height: 800)
        let photo = ImageItem(url: url, modifiedAt: Date(), fileSize: 0)
        let cache = ThumbnailCache()

        async let first = cache.thumbnail(for: photo, pointSize: 200, scale: 2)
        async let second = cache.thumbnail(for: photo, pointSize: 250, scale: 2)  // same bucket
        let (a, b) = await (first, second)
        let image = try #require(a)
        #expect(image === b)
        #expect(await cache.bestCached(for: photo, scale: 2) === image)
    }
}

// MARK: - Folder watching

@MainActor
struct FolderWatcherTests {
    private func event(_ path: String, _ flags: Int) -> FolderWatcher.Event {
        FolderWatcher.Event(path: path, flags: FSEventStreamEventFlags(flags))
    }

    @Test func ignoresAttributeOnlyChanges() {
        let tagged = event("/r/a.jpg", kFSEventStreamEventFlagItemXattrMod | kFSEventStreamEventFlagItemIsFile)
        #expect(!FolderWatcher.isRelevant(tagged, root: "/r", recursive: false))
    }

    @Test func ignoresHiddenFiles() {
        let store = event("/r/.DS_Store", kFSEventStreamEventFlagItemModified)
        #expect(!FolderWatcher.isRelevant(store, root: "/r", recursive: true))
    }

    @Test func nonRecursiveOnlyCaresAboutDirectChildren() {
        let direct = event("/r/a.jpg", kFSEventStreamEventFlagItemCreated)
        let nested = event("/r/sub/a.jpg", kFSEventStreamEventFlagItemCreated)
        #expect(FolderWatcher.isRelevant(direct, root: "/r", recursive: false))
        #expect(!FolderWatcher.isRelevant(nested, root: "/r", recursive: false))
        #expect(FolderWatcher.isRelevant(nested, root: "/r", recursive: true))
    }

    @Test func droppedEventsAlwaysRescan() {
        let dropped = event("/r/sub", kFSEventStreamEventFlagMustScanSubDirs)
        #expect(FolderWatcher.isRelevant(dropped, root: "/r", recursive: false))
    }
}

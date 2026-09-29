import AppKit
import Vision

/// What Vision found in one image. Kept small because the whole index is
/// loaded into memory: labels are Vision's English classification identifiers
/// ("dog", "blue_sky") with their confidence, text is the recognized text,
/// already folded for matching (lowercase, no diacritics).
nonisolated struct ContentRecord: Codable, Equatable, Sendable {
    /// File modification time (Photos: creation date) the record was made from.
    var modified: Double
    var size: Int64
    /// PHAsset.localIdentifier for Photos items, nil for files.
    var asset: String?
    var labels: [String: Float]
    var text: String

    private enum CodingKeys: String, CodingKey {
        case modified = "m", size = "s", asset = "a", labels = "l", text = "t"
    }

    /// True when the record still describes `item` as it is now.
    func isCurrent(for item: ImageItem) -> Bool {
        modified == item.modifiedAt.timeIntervalSince1970 && size == item.fileSize
    }
}

/// A search query in English: every word has to be found in the image's
/// labels, its recognized text or its filename ("dog beach" = both).
nonisolated struct ContentQuery: Sendable {
    /// Labels below this confidence don't count as a match. Vision reports
    /// parent labels too, so "animal" finds dogs, owls and zebras alike.
    static let minimumConfidence: Float = 0.3

    let terms: [String]

    init(_ text: String) {
        terms = Self.fold(text)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    var isEmpty: Bool { terms.isEmpty }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    func matches(name: String, record: ContentRecord?) -> Bool {
        guard !terms.isEmpty else { return false }
        let foldedName = Self.fold(name)
        return terms.allSatisfy { term in
            foldedName.contains(term)
                || (record.map { Self.labelsMatch(term, $0.labels) || $0.text.contains(term) } ?? false)
        }
    }

    /// A term matches a whole word of a label, also in plural ("dogs" finds
    /// "dog", "puppies" finds "puppy"), so "car" doesn't find "cardigan".
    private static func labelsMatch(_ term: String, _ labels: [String: Float]) -> Bool {
        let forms = singularForms(of: term)
        for (label, confidence) in labels where confidence >= minimumConfidence {
            for word in label.split(separator: "_") where forms.contains(String(word)) {
                return true
            }
        }
        return false
    }

    static func singularForms(of term: String) -> Set<String> {
        var forms: Set<String> = [term]
        if term.hasSuffix("ies"), term.count > 4 { forms.insert(String(term.dropLast(3)) + "y") }
        if term.hasSuffix("es"), term.count > 3 { forms.insert(String(term.dropLast(2))) }
        if term.hasSuffix("s"), term.count > 2 { forms.insert(String(term.dropLast())) }
        return forms
    }
}

/// Runs Vision on one image: classification always, text recognition only
/// when a cheap text detector finds something to read (most photos have none).
nonisolated enum ContentAnalyzer {
    /// Longest side of the image Vision gets; enough for labels and for
    /// reading receipts or signs, and quick to decode.
    static let pixelSize: CGFloat = 1024
    /// Labels weaker than this aren't stored at all.
    static let storedConfidence: Float = 0.15

    /// Nil when the image can't be reached right now (folder closed, Photos
    /// item not on this Mac); it is tried again the next time it's queued.
    static func analyze(_ item: ImageItem) async -> ContentRecord? {
        var record = ContentRecord(
            modified: item.modifiedAt.timeIntervalSince1970,
            size: item.fileSize,
            asset: item.assetIdentifier,
            labels: [:],
            text: ""
        )
        guard let image = await cgImage(for: item) else {
            // A readable file that doesn't decode keeps an empty record, so it
            // isn't retried on every launch; a change to the file indexes it again.
            if !item.isAsset, FileManager.default.isReadableFile(atPath: item.url.path) { return record }
            return nil
        }

        if let observations = try? await ClassifyImageRequest().perform(on: image) {
            for observation in observations where observation.confidence >= storedConfidence {
                record.labels[observation.identifier] = observation.confidence
            }
        }
        if let regions = try? await DetectTextRectanglesRequest().perform(on: image), !regions.isEmpty {
            var request = RecognizeTextRequest()
            request.automaticallyDetectsLanguage = true
            if let lines = try? await request.perform(on: image) {
                let text = lines
                    .compactMap { $0.topCandidates(1).first }
                    .filter { $0.confidence >= 0.3 }
                    .map(\.string)
                    .joined(separator: " ")
                record.text = ContentQuery.fold(text)
            }
        }
        return record
    }

    private static func cgImage(for item: ImageItem) async -> CGImage? {
        let image: NSImage?
        switch item.origin {
        case .file:
            image = ImageDecoder.decode(url: item.url, maxPixelSize: pixelSize)
        case .asset(let id):
            // Local renditions only: indexing must not download the library.
            image = await PhotosImages.image(for: id, pixelSize: pixelSize, quality: .thumbnail, allowsNetwork: false)
        }
        return image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

/// The on-disk content index plus the queue of images waiting for analysis.
/// Records are keyed by the item's URL path (Photos items have a placeholder
/// path that changes when the asset is edited, so edits get re-indexed).
actor ContentIndex {
    nonisolated struct Progress: Equatable, Sendable {
        let done: Int
        let total: Int
    }

    /// Status updates for the UI: progress while working (nil when idle), the
    /// number of indexed images, and whether new results arrived.
    nonisolated struct Status: Sendable {
        let progress: Progress?
        let indexedCount: Int
    }

    private static let concurrency = 4
    private static let saveInterval = 200

    private let storeURL: URL
    private var records: [String: ContentRecord] = [:]
    private var isLoaded = false
    private var queue: [ImageItem] = []
    private var queuedKeys: Set<String> = []
    private var worker: Task<Void, Never>?
    /// Counts for the progress bar; reset whenever the queue drains.
    private var doneInRun = 0
    private var unsavedChanges = 0
    private var onStatus: (@Sendable (Status) -> Void)?

    init(storeURL: URL = ContentIndex.defaultStoreURL) {
        self.storeURL = storeURL
    }

    nonisolated static var defaultStoreURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Kuk/ContentIndex.json")
    }

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        onStatus = handler
    }

    // MARK: - Storage

    func load() {
        guard !isLoaded else { return }
        isLoaded = true
        if let data = try? Data(contentsOf: storeURL),
           let decoded = try? JSONDecoder().decode([String: ContentRecord].self, from: data) {
            records = decoded
        }
        report()
    }

    func save() {
        guard unsavedChanges > 0 else { return }
        unsavedChanges = 0
        let snapshot = records
        let url = storeURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Stops indexing and forgets everything, on disk too.
    func clear() {
        stop()
        records = [:]
        unsavedChanges = 0
        try? FileManager.default.removeItem(at: storeURL)
        report()
    }

    // MARK: - Queue

    /// Queues the items whose record is missing or outdated. `first` puts them
    /// ahead of everything else (the folder the user is looking at).
    func enqueue(_ items: [ImageItem], first: Bool = false) {
        load()
        let needed = items.filter { item in
            !(records[item.url.path]?.isCurrent(for: item) ?? false)
        }
        guard !needed.isEmpty else { return }
        if first {
            let keys = Set(needed.map(\.url.path))
            queue.removeAll { keys.contains($0.url.path) }
            queue.insert(contentsOf: needed, at: 0)
            queuedKeys.formUnion(keys)
        } else {
            for item in needed where queuedKeys.insert(item.url.path).inserted {
                queue.append(item)
            }
        }
        startWorker()
        report()
    }

    /// Drops records of files that no longer exist below `root`, given the
    /// complete list of images a fresh scan found there.
    func prune(under root: URL, keeping items: [ImageItem]) {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let alive = Set(items.map(\.url.path))
        let before = records.count
        records = records.filter { key, record in
            record.asset != nil || !key.hasPrefix(prefix) || alive.contains(key)
        }
        if records.count != before { unsavedChanges += 1 }
    }

    /// Same for the Photos library: removes assets that are gone or edited
    /// (an edit changes the placeholder path).
    func prunePhotos(keeping items: [ImageItem]) {
        let alive = Set(items.map(\.url.path))
        let before = records.count
        records = records.filter { key, record in record.asset == nil || alive.contains(key) }
        if records.count != before { unsavedChanges += 1 }
    }

    /// Stores a record directly; used by tests.
    func insert(_ record: ContentRecord, at path: String) {
        load()
        records[path] = record
        unsavedChanges += 1
    }

    /// Carries records over to the new paths of renamed files.
    func move(_ pairs: [(String, String)]) {
        load()
        for (old, new) in pairs {
            guard let record = records.removeValue(forKey: old) else { continue }
            records[new] = record
            unsavedChanges += 1
        }
    }

    /// Forgets queued images below a folder that was closed; Kuk can't read
    /// them anymore.
    func dequeue(under root: URL) {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        queue.removeAll { $0.url.path.hasPrefix(prefix) }
        queuedKeys = queuedKeys.filter { !$0.hasPrefix(prefix) }
        report()
    }

    /// Nothing queued or being analyzed.
    var isIdle: Bool { queue.isEmpty && worker == nil }

    func stop() {
        worker?.cancel()
        worker = nil
        queue = []
        queuedKeys = []
        doneInRun = 0
        save()
        report()
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task(priority: .utility) { await self.work() }
    }

    private func work() async {
        while !Task.isCancelled, !queue.isEmpty {
            let batch = Array(queue.prefix(Self.concurrency))
            queue.removeFirst(batch.count)
            let results = await withTaskGroup(of: (String, ContentRecord?).self) { group in
                for item in batch {
                    group.addTask { (item.url.path, await ContentAnalyzer.analyze(item)) }
                }
                var collected: [(String, ContentRecord?)] = []
                for await result in group { collected.append(result) }
                return collected
            }
            guard !Task.isCancelled else { break }
            for (key, record) in results {
                queuedKeys.remove(key)
                guard let record else { continue }
                records[key] = record
                unsavedChanges += 1
            }
            doneInRun += results.count
            if unsavedChanges >= Self.saveInterval { save() }
            report()
        }
        guard !Task.isCancelled else { return }
        worker = nil
        doneInRun = 0
        save()
        report()
    }

    private func report() {
        let progress = queue.isEmpty && worker == nil
            ? nil
            : Progress(done: doneInRun, total: doneInRun + queue.count)
        onStatus?(Status(progress: progress, indexedCount: records.count))
    }

    // MARK: - Search

    /// The items (from the displayed folder or album) whose name or content
    /// matches the query.
    func matches(_ query: ContentQuery, among items: [ImageItem]) -> Set<URL> {
        load()
        var result: Set<URL> = []
        for item in items where query.matches(name: item.name, record: records[item.url.path]) {
            result.insert(item.id)
        }
        return result
    }

    /// Searches every indexed image below the open folders (and in the Photos
    /// library when `includePhotos`), returning them as grid items.
    func search(_ query: ContentQuery, roots: [URL], includePhotos: Bool) -> [ImageItem] {
        load()
        let prefixes = roots.map { $0.path.hasSuffix("/") ? $0.path : $0.path + "/" }
        var found: [ImageItem] = []
        for (key, record) in records {
            if let asset = record.asset {
                guard includePhotos else { continue }
                let url = URL(fileURLWithPath: key)
                guard query.matches(name: url.lastPathComponent, record: record) else { continue }
                found.append(ImageItem(
                    url: url,
                    modifiedAt: Date(timeIntervalSince1970: record.modified),
                    fileSize: 0,
                    origin: .asset(asset)
                ))
            } else {
                guard prefixes.contains(where: { key.hasPrefix($0) }) else { continue }
                let url = URL(fileURLWithPath: key)
                guard query.matches(name: url.lastPathComponent, record: record) else { continue }
                found.append(ImageItem(
                    url: url,
                    modifiedAt: Date(timeIntervalSince1970: record.modified),
                    fileSize: record.size
                ))
            }
        }
        return found
    }
}

/// Re-reads the files behind "Everywhere" results: drops files that are gone,
/// picks up current dates, sizes and Finder tag flags, and returns the items
/// whose record is outdated so they can be indexed again.
nonisolated enum SearchResultCheck {
    struct Result: Sendable {
        var items: [ImageItem] = []
        var flags: [(URL, ImageFlag?)] = []
        var outdated: [ImageItem] = []
    }

    /// Runs off the main actor but keeps the caller's cancellation, so a new
    /// keystroke stops checking a huge result list.
    @concurrent
    static func run(_ found: [ImageItem], order: SortOrder) async -> Result {
        var result = Result()
        let assetFlags = AssetFlagStore.all()
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .tagNamesKey]
        result.items.reserveCapacity(found.count)
        for item in found {
            if Task.isCancelled { return Result() }
            if let id = item.assetIdentifier {
                result.items.append(item)
                result.flags.append((item.url, assetFlags[id]))
                continue
            }
            guard let values = try? item.url.resourceValues(forKeys: keys) else { continue }
            let current = ImageItem(
                url: item.url,
                modifiedAt: values.contentModificationDate ?? item.modifiedAt,
                fileSize: Int64(values.fileSize ?? Int(item.fileSize))
            )
            if current.modifiedAt != item.modifiedAt || current.fileSize != item.fileSize {
                result.outdated.append(current)
            }
            result.items.append(current)
            result.flags.append((item.url, FinderTags.flag(fromTagNames: values.tagNames)))
        }
        result.items = AppModel.sorted(result.items, by: order)
        return result
    }
}

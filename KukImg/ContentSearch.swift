import Foundation

/// Where the search field looks: the displayed folder or album, or every
/// indexed image in the open folders and the Photos library.
nonisolated enum SearchScope: String, CaseIterable, Sendable {
    case current, everywhere

    func label(inAlbum: Bool) -> String {
        switch self {
        case .current:    inAlbum ? String(localized: "This Album") : String(localized: "This Folder")
        case .everywhere: String(localized: "Everywhere")
        }
    }
}

/// UI state of content search: the opt-in setting, indexing progress and the
/// size of the index. The index itself lives in the `ContentIndex` actor.
@Observable
final class ContentSearchModel {
    /// Off by default: indexing reads every image once, which takes a while
    /// on big libraries.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: "contentSearchEnabled")
            onEnabledChange?(isEnabled)
        }
    }
    /// Non-nil while images are being analyzed.
    private(set) var progress: ContentIndex.Progress?
    private(set) var indexedCount = 0

    let index = ContentIndex()

    /// Set by AppModel: starts or stops feeding the index.
    @ObservationIgnored var onEnabledChange: ((Bool) -> Void)?
    /// Called (throttled) while indexing adds records, so an active search
    /// can pick up new matches.
    @ObservationIgnored var onIndexUpdate: (() -> Void)?
    @ObservationIgnored private var lastUpdateNotice = Date.distantPast

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: "contentSearchEnabled")
        let index = index
        Task {
            await index.setStatusHandler { [weak self] status in
                Task { @MainActor in self?.apply(status) }
            }
        }
    }

    private func apply(_ status: ContentIndex.Status) {
        let wasWorking = progress != nil
        if status.progress != progress { progress = status.progress }
        if status.indexedCount != indexedCount { indexedCount = status.indexedCount }
        // Refresh results every couple of seconds while indexing and once at the end.
        let finished = wasWorking && status.progress == nil
        if finished || Date().timeIntervalSince(lastUpdateNotice) > 2 {
            lastUpdateNotice = Date()
            onIndexUpdate?()
        }
    }

    /// True when there is an index to clear, loaded or only on disk.
    var hasIndex: Bool {
        indexedCount > 0 || FileManager.default.fileExists(atPath: ContentIndex.defaultStoreURL.path)
    }

    /// Forgets the whole index; with search still on, indexing starts over.
    func clearIndex() {
        Task {
            await index.clear()
            // Observation fires on every assignment, even of an unchanged 0,
            // so views asking `hasIndex` see the file is gone.
            indexedCount = 0
            if isEnabled { onEnabledChange?(true) }
        }
    }
}

import Foundation
import CoreServices

/// Watches the displayed folder for changes via FSEvents. Unlike the previous
/// single-file-descriptor DispatchSource, FSEvents sees the whole subtree, so
/// changes inside subfolders trigger a rescan when "Include Subfolders" is on.
/// In non-recursive mode, events from deeper levels are filtered out.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let root: String
    private let recursive: Bool
    private let onChange: () -> Void

    init?(url: URL, recursive: Bool, onChange: @escaping () -> Void) {
        self.root = url.path
        self.recursive = recursive
        self.onChange = onChange
        self.stream = nil

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.eventCallback,
            &context,
            [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,  // seconds of coalescing; AppModel debounces on top
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            )
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        // The stream delivers on the main queue and the watcher is owned by the
        // main-actor AppModel, so no callback can race this teardown.
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private nonisolated static let eventCallback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
        guard let info else { return }
        // With kFSEventStreamCreateFlagUseCFTypes the paths arrive as a CFArray
        // of CFStrings.
        let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
        MainActor.assumeIsolated {
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().handle(paths)
        }
    }

    private func handle(_ paths: [String]) {
        if !recursive {
            let relevant = paths.contains { path in
                path == root || (path as NSString).deletingLastPathComponent == root
            }
            guard relevant else { return }
        }
        onChange()
    }
}

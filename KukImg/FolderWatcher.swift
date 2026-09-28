import Foundation
import CoreServices

/// Watches the displayed folder for changes via FSEvents. Unlike a single
/// file-descriptor DispatchSource, FSEvents sees the whole subtree, so changes
/// inside subfolders trigger a rescan when "Include Subfolders" is on. In
/// non-recursive mode, events from deeper levels are filtered out.
///
/// Events that can't change the image list are ignored: attribute-only
/// changes (Kuk's own Finder tag writes, Spotlight, xattrs) and hidden files
/// such as .DS_Store or Kuk's temporary files.
final class FolderWatcher {
    /// Only touched on the main actor and in deinit, when nothing else can
    /// reach the watcher any more.
    nonisolated(unsafe) private var stream: FSEventStreamRef?
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

    nonisolated struct Event: Sendable {
        let path: String
        let flags: FSEventStreamEventFlags
    }

    private nonisolated static let eventCallback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
        guard let info else { return }
        // With kFSEventStreamCreateFlagUseCFTypes the paths arrive as a CFArray
        // of CFStrings.
        let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
        let events = paths.prefix(count).enumerated().map { index, path in
            Event(path: path, flags: eventFlags[index])
        }
        // Delivered on the main queue (see FSEventStreamSetDispatchQueue).
        let address = UInt(bitPattern: info)
        MainActor.assumeIsolated {
            guard let pointer = UnsafeRawPointer(bitPattern: address) else { return }
            Unmanaged<FolderWatcher>.fromOpaque(pointer).takeUnretainedValue().handle(events)
        }
    }

    private func handle(_ events: [Event]) {
        if events.contains(where: { Self.isRelevant($0, root: root, recursive: recursive) }) {
            onChange()
        }
    }

    /// Flags meaning the set of files (or their contents) changed.
    private nonisolated static let contentFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
            | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified
            | kFSEventStreamEventFlagItemCloned
    )

    /// Flags meaning FSEvents lost track and the tree has to be rescanned.
    private nonisolated static let rescanFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
    )

    nonisolated static func isRelevant(_ event: Event, root: String, recursive: Bool) -> Bool {
        if event.flags & rescanFlags != 0 { return true }
        // Attribute-only changes (tags, xattrs, permissions) never add or
        // remove an image.
        guard event.flags & contentFlags != 0 else { return false }
        let name = (event.path as NSString).lastPathComponent
        if name.hasPrefix(".") { return false }
        if !recursive {
            let parent = (event.path as NSString).deletingLastPathComponent
            return event.path == root || parent == root
        }
        return true
    }
}

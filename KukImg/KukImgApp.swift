import SwiftUI
import Sparkle

/// Receives file-open events from Finder ("Open With", double-click when Kuk
/// is the default app). Events can arrive before the SwiftUI scene exists, so
/// URLs are buffered until the model is attached.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel? { didSet { openPending() } }
    private var pendingURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        pendingURLs.append(contentsOf: urls)
        openPending()
    }

    private func openPending() {
        guard let model, !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs.removeAll()
        for url in urls { model.handleDrop(url) }
    }
}

@main
struct KukImgApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @AppStorage("showFilenames") private var showFilenames = false
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )

    var body: some Scene {
        // A single Window (not WindowGroup): the whole app shares one AppModel,
        // so a second window would just mirror the first one's selection.
        Window("Kuk", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 800, minHeight: 600)
                .task {
                    appDelegate.model = model
                    model.restoreLastFolder()
                    // Exported Photos copies pile up over time; prune them once
                    // per launch, off the main thread.
                    Task.detached(priority: .background) {
                        PhotosMaterializer.trimCache()
                    }
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { model.pickFolder() }
                    .keyboardShortcut("o", modifiers: .command)

                Menu("Open Recent") {
                    ForEach(model.recents) { recent in
                        Button(recent.name) { model.openRecent(recent) }
                    }
                    if !model.recents.isEmpty {
                        Divider()
                        Button("Clear Menu") { model.clearRecents() }
                    }
                }
                .disabled(model.recents.isEmpty)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Copy Image") { model.copyCurrent() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.currentItem == nil)
                Button("Move to Trash") { model.deleteCurrent() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.currentItem == nil)
                Button("Show in Finder") { model.revealCurrent() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.currentItem == nil)
                Divider()
                Button("Select All") { model.selectAll() }
                    .keyboardShortcut("a", modifiers: .command)
                    .disabled(model.visibleItems.isEmpty)
                Button("Deselect") { model.collapseSelection() }
                    .disabled(!model.hasMultipleSelected)
                Toggle("Selection Mode", isOn: Binding(
                    get: { model.isSelectMode },
                    set: { model.isSelectMode = $0 }
                ))
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(after: .importExport) {
                Button(shareLabel) { model.shareCurrent() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(model.currentItem == nil)
                Button(convertLabel) { model.convertCurrent() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.currentItem == nil)
            }
            CommandGroup(before: .toolbar) {
                Button("Zoom In") { model.requestZoom(.zoomIn) }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(zoomUnavailable)
                Button("Zoom Out") { model.requestZoom(.zoomOut) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(zoomUnavailable)
                Button("Actual Size") { model.requestZoom(.actualSize) }
                    .keyboardShortcut("1", modifiers: .command)
                    .disabled(zoomUnavailable)
                Button("Zoom to Fit") { model.requestZoom(.fit) }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(zoomUnavailable)
                Divider()
                Toggle("Show Filenames", isOn: $showFilenames)
                Toggle("Group by Folder", isOn: Binding(
                    get: { model.groupByFolder },
                    set: { model.groupByFolder = $0 }
                ))
                .disabled(!model.includeSubfolders)
            }
            CommandMenu("Image") {
                Button("Rotate Left") { model.rotateCurrent(clockwise: false) }
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(model.currentItem == nil)
                Button("Rotate Right") { model.rotateCurrent(clockwise: true) }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.currentItem == nil)
                Button("Rename…") { model.renameCurrent() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(model.currentItem == nil)
                Divider()
                // Flag keys (P / X / U) live in the grid and fullscreen views;
                // bare-letter menu shortcuts would swallow typing in search.
                Button("Pick (P)") { model.setFlag(.pick, for: model.selectedItems) }
                    .disabled(model.currentItem == nil)
                Button("Reject (X)") { model.setFlag(.reject, for: model.selectedItems) }
                    .disabled(model.currentItem == nil)
                Button("Clear Flag (U)") { model.setFlag(nil, for: model.selectedItems) }
                    .disabled(model.currentItem == nil)
                Divider()
                Button("Copy Picked to Folder…") { model.exportPicked(move: false) }
                    .disabled(!model.hasPickedInCurrent)
                Button("Move Picked to Folder…") { model.exportPicked(move: true) }
                    .disabled(!model.hasPickedInCurrent)
                Button("Move Rejected to Trash") { model.trashRejected() }
                    .disabled(!model.hasRejectedInCurrent)
            }
            CommandMenu("Sort") {
                ForEach(SortOrder.allCases, id: \.self) { order in
                    Button {
                        model.sortOrder = order
                    } label: {
                        if model.sortOrder == order {
                            Label(order.label, systemImage: "checkmark")
                        } else {
                            Text(order.label)
                        }
                    }
                }
                Divider()
                Toggle("Include Subfolders", isOn: Binding(
                    get: { model.includeSubfolders },
                    set: { model.includeSubfolders = $0 }
                ))
            }
        }

        Settings {
            SettingsView(updater: updaterController.updater)
                .environment(model)
        }
    }

    /// Zoom commands go to the fullscreen viewer when it is up, otherwise to
    /// the detail view — each consumes `zoomRequest` behind its own gate.
    private var zoomUnavailable: Bool {
        model.currentItem == nil
    }

    private var shareLabel: String {
        model.hasMultipleSelected ? "Share \(model.selectedIDs.count) Images…" : "Share…"
    }

    private var convertLabel: String {
        model.hasMultipleSelected ? "Convert \(model.selectedIDs.count) Images…" : "Convert…"
    }
}

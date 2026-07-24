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
        guard let model, let url = pendingURLs.last else { return }
        pendingURLs.removeAll()
        model.handleDrop(url)
    }
}

@main
struct KukImgApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 800, minHeight: 600)
                .task {
                    appDelegate.model = model
                    model.restoreLastFolder()
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
    }
}

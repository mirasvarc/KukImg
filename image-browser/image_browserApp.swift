import SwiftUI

@main
struct image_browserApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 800, minHeight: 600)
                .task { model.restoreLastFolder() }
        }
        .windowToolbarStyle(.unified)
        .commands {
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
            }
        }
    }
}

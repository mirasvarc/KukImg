import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @State private var thumbSize: CGFloat = 160
    @AppStorage("showFilenames") private var showFilenames = false

    var body: some View {
        @Bindable var model = model
        ZStack {
            NavigationSplitView {
                sidebar
            } content: {
                grid
            } detail: {
                detail
            }
            .navigationTitle(model.folder?.lastPathComponent ?? "Kuk")
            .toolbar { toolbar }
            .searchable(text: $model.filterText, placement: .toolbar, prompt: "Filter by name")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                StatusBar(item: model.currentItem)
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                model.handleDrop(url)
                return true
            }

            if model.isFullscreen, let item = model.currentItem {
                FullscreenView(item: item)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: model.isFullscreen)
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, new in model.undoManager = new }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.pickFolder() } label: {
                Label("Open Folder", systemImage: "folder")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Sort By", selection: sortBinding) {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        Text(order.label).tag(order)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Include Subfolders", isOn: subfoldersBinding)
                Toggle("Show Filenames", isOn: $showFilenames)
            } label: {
                Label("View", systemImage: "arrow.up.arrow.down")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.showInfoPanel.toggle()
            } label: {
                Label("Info", systemImage: "info.circle")
            }
            .disabled(model.currentItem == nil)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                if model.currentItem != nil { model.isFullscreen = true }
            } label: {
                Label("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .disabled(model.currentItem == nil)
        }
        ToolbarItem(placement: .primaryAction) {
            Slider(value: $thumbSize, in: 80...320)
                .frame(width: 140)
                .help("Thumbnail size")
        }
    }

    private var sortBinding: Binding<SortOrder> {
        Binding(get: { model.sortOrder }, set: { model.sortOrder = $0 })
    }

    private var subfoldersBinding: Binding<Bool> {
        Binding(get: { model.includeSubfolders }, set: { model.includeSubfolders = $0 })
    }

    private var sidebar: some View {
        List {
            if !model.openFolders.isEmpty {
                Section("Folders") {
                    ForEach(model.openFolders, id: \.self) { root in
                        FolderTreeRow(url: root, isRoot: true)
                    }
                    if model.folder != nil {
                        Text(countLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Button { model.pickFolder() } label: {
                    Label(
                        model.openFolders.isEmpty ? "Open Folder…" : "Add Folder…",
                        systemImage: "plus"
                    )
                }
                .buttonStyle(.plain)
            }
            if !model.recents.isEmpty {
                Section("Recent") {
                    ForEach(model.recents) { recent in
                        Button {
                            model.openRecent(recent)
                        } label: {
                            Label(recent.name, systemImage: "clock")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                        .help(recent.path)
                        .foregroundStyle(
                            recent.path == model.folder?.path ? Color.accentColor : .primary
                        )
                        .contextMenu {
                            Button("Remove from Recents") { model.removeRecent(recent) }
                        }
                    }
                }
            }
            if model.openFolders.isEmpty && model.recents.isEmpty {
                ContentUnavailableView(
                    "No Folder",
                    systemImage: "photo.on.rectangle",
                    description: Text("Open a folder, drop one onto the window, or pick from File → Open Recent.")
                )
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180)
    }

    private var countLabel: String {
        if model.visibleItems.count == model.items.count {
            "\(model.items.count) images"
        } else {
            "\(model.visibleItems.count) of \(model.items.count) images"
        }
    }

    private var grid: some View {
        Group {
            if model.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.visibleItems.isEmpty {
                ContentUnavailableView(
                    "No Images",
                    systemImage: "photo",
                    description: Text(emptyDescription)
                )
            } else {
                ImageGridView(thumbSize: thumbSize)
            }
        }
        .frame(minWidth: 400)
    }

    private var emptyDescription: String {
        if model.folder == nil {
            "Choose a folder via ⌘O or drop one here."
        } else if !model.filterText.isEmpty {
            "No images match “\(model.filterText)”."
        } else {
            "This folder has no images."
        }
    }

    private var detail: some View {
        Group {
            if let item = model.currentItem {
                DetailView(item: item)
            } else {
                ContentUnavailableView("No Selection", systemImage: "photo")
            }
        }
        .frame(minWidth: 300)
    }
}

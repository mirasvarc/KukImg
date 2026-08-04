import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @State private var thumbSize: CGFloat = 160
    @AppStorage("showFilenames") private var showFilenames = false
    @AppStorage("systemFullscreen") private var systemFullscreen = false

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
            .navigationTitle(model.sourceTitle ?? "Kuk")
            .toolbar { toolbar }
            .searchable(text: $model.filterText, placement: .toolbar, prompt: "Filter by name")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                StatusBar(item: model.currentItem, selectedCount: model.selectedIDs.count)
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !urls.isEmpty else { return false }
                for url in urls { model.handleDrop(url) }
                return true
            }

            if model.isFullscreen, let item = model.currentItem {
                FullscreenView(item: item)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: model.isFullscreen)
        .onChange(of: model.isFullscreen) { _, active in
            // Optionally mirror the immersive view into macOS full screen.
            guard systemFullscreen,
                  let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible)
            else { return }
            let inSystemFullscreen = window.styleMask.contains(.fullScreen)
            if active != inSystemFullscreen { window.toggleFullScreen(nil) }
        }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, new in model.undoManager = new }
        .sheet(item: $model.convertRequest) { request in
            ConvertSheet(items: request.items)
        }
        .sheet(item: $model.renameRequest) { request in
            RenameSheet(items: request.items)
        }
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
                Picker("Show", selection: flagFilterBinding) {
                    ForEach(FlagFilter.allCases, id: \.self) { filter in
                        Text(filter.label).tag(filter)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Include Subfolders", isOn: subfoldersBinding)
                Toggle("Group by Folder", isOn: groupBinding)
                    .disabled(!model.includeSubfolders)
                Toggle("Show Filenames", isOn: $showFilenames)
            } label: {
                Label("View", systemImage: "arrow.up.arrow.down")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: selectModeBinding) {
                Label("Select", systemImage: "checkmark.circle")
            }
            .help("Select multiple images")
            .disabled(model.visibleItems.isEmpty)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.shareCurrent() } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .help(shareHelp)
            .disabled(model.currentItem == nil)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.convertCurrent() } label: {
                Label("Convert", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("Convert to another format")
            .disabled(model.currentItem == nil)
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

    private var shareHelp: String {
        model.selectedIDs.count > 1 ? "Share \(model.selectedIDs.count) images" : "Share"
    }

    private var sortBinding: Binding<SortOrder> {
        Binding(get: { model.sortOrder }, set: { model.sortOrder = $0 })
    }

    private var subfoldersBinding: Binding<Bool> {
        Binding(get: { model.includeSubfolders }, set: { model.includeSubfolders = $0 })
    }

    private var groupBinding: Binding<Bool> {
        Binding(get: { model.groupByFolder }, set: { model.groupByFolder = $0 })
    }

    private var selectModeBinding: Binding<Bool> {
        Binding(get: { model.isSelectMode }, set: { model.isSelectMode = $0 })
    }

    private var flagFilterBinding: Binding<FlagFilter> {
        Binding(get: { model.flagFilter }, set: { model.flagFilter = $0 })
    }

    private var sidebar: some View {
        List {
            if !model.openFolders.isEmpty {
                Section("Folders") {
                    ForEach(model.openFolders, id: \.self) { root in
                        FolderTreeRow(url: root, isRoot: true)
                    }
                }
            }
            if model.folder != nil || model.photoAlbum != nil {
                Section {
                    Text(countLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            PhotosSidebarSection()
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
        var text = model.visibleItems.count == model.items.count
            ? "\(model.items.count) images"
            : "\(model.visibleItems.count) of \(model.items.count) images"
        if let total = model.photos.truncatedFrom, model.photoAlbum != nil {
            text += " of \(total) in the album"
        }
        if model.selectedIDs.count > 1 {
            text += " · \(model.selectedIDs.count) selected"
        }
        return text
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
        if model.folder == nil && model.photoAlbum == nil {
            "Choose a folder via ⌘O or drop one here."
        } else if !model.filterText.isEmpty {
            "No images match “\(model.filterText)”."
        } else if model.photoAlbum != nil {
            "This album has no images."
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

/// Albums from the system Photos library. Hidden until the user asks for
/// access, so Kuk never triggers the privacy prompt on its own.
private struct PhotosSidebarSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("Photos") {
            if model.photos.isAuthorized {
                if model.photos.albums.isEmpty {
                    Text(model.photos.isLoadingAlbums ? "Loading…" : "No albums")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.photos.albums) { album in
                    Button {
                        model.displayPhotos(album)
                    } label: {
                        HStack(spacing: 4) {
                            Label(album.title, systemImage: album.symbol)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text("\(album.count)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        model.photoAlbum?.id == album.id ? Color.accentColor : .primary
                    )
                }
            } else if model.photos.isDenied {
                Text("Access denied. Enable Kuk under Privacy & Security → Photos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    Task { await model.photos.requestAccess() }
                } label: {
                    Label("Connect Photos…", systemImage: "photo.stack")
                }
                .buttonStyle(.plain)
            }
        }
        .task {
            if model.photos.isAuthorized { await model.photos.loadAlbums() }
        }
    }
}

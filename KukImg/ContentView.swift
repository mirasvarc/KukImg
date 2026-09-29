import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @AppStorage("thumbSize") private var thumbSize: Double = 160
    @AppStorage("showFilenames") private var showFilenames = false
    @AppStorage("systemFullscreen") private var systemFullscreen = false
    @AppStorage("hideEmptyFolders") private var hideEmptyFolders = false

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
            .searchable(text: $model.filterText, placement: .toolbar, prompt: searchPrompt)
            .modifier(SearchScopePicker(
                isEnabled: model.contentSearch.isEnabled,
                inAlbum: model.photoAlbum != nil,
                scope: $model.searchScope
            ))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                StatusBar(
                    item: model.currentItem,
                    selectedCount: model.selectedIDs.count,
                    activity: model.activity,
                    indexing: indexingActivity
                )
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !urls.isEmpty else { return false }
                for url in urls { model.handleDrop(url) }
                return true
            }

            // Stays up (without an item) while folder navigation loads the
            // next folder, so the slideshow and chrome state carry over.
            if model.isFullscreen {
                FullscreenView(item: model.currentItem)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: model.isFullscreen)
        // Escape works wherever the focus is: over the viewer, the grid, the
        // detail view or the sidebar. The filter field keeps it for clearing
        // its text, except while the viewer is up.
        .background(EscapeKeyMonitor { isEditingText in
            if isEditingText, !model.isFullscreen { return false }
            return model.handleEscape()
        })
        .onChange(of: hideEmptyFolders) { model.reloadGridFolders() }
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
                            // Photos assets report no file size.
                            .disabled(order.isSizeBased && model.photoAlbum != nil)
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
            Slider(value: $thumbSize, in: 80...360)
                .frame(width: 140)
                .help("Thumbnail size")
        }
    }

    private var searchPrompt: LocalizedStringKey {
        model.contentSearch.isEnabled ? "Search names and contents" : "Filter by name"
    }

    private var indexingActivity: Activity? {
        guard let progress = model.contentSearch.progress else { return nil }
        return Activity(
            title: String(localized: "Indexing"),
            completed: progress.done,
            total: progress.total
        )
    }

    private var shareHelp: String {
        let count = model.selectedIDs.count
        return count > 1 ? String(localized: "Share \(count) images") : String(localized: "Share")
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
        ScrollViewReader { proxy in
            sidebarList
                // Folder navigation lands on folders that may be far down the
                // tree; keep the highlighted row in view.
                .onChange(of: model.folder) { _, folder in
                    guard let path = folder?.path else { return }
                    Task {
                        // Let freshly expanded rows appear first.
                        try? await Task.sleep(for: .milliseconds(80))
                        withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(path) }
                    }
                }
        }
    }

    private var sidebarList: some View {
        List {
            if !model.openFolders.isEmpty {
                Section("Folders") {
                    ForEach(model.openFolders, id: \.self) { root in
                        FolderTreeRow(url: root, isRoot: true)
                    }
                }
            }
            if model.folder != nil || model.photoAlbum != nil || model.searchResults != nil {
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
        let shown = model.visibleItems.count
        let total = model.items.count
        var text = model.searchResults != nil
            ? String(localized: "\(shown) results")
            : shown == total
            ? String(localized: "\(total) images")
            : String(localized: "\(shown) of \(total) images")
        if let albumTotal = model.photos.truncatedFrom, model.photoAlbum != nil {
            text += " " + String(localized: "of \(albumTotal) in the album")
        }
        let selected = model.selectedIDs.count
        if selected > 1 {
            text += " · " + String(localized: "\(selected) selected")
        }
        return text
    }

    private var grid: some View {
        Group {
            if model.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.visibleItems.isEmpty && model.gridFolders.isEmpty {
                ContentUnavailableView(
                    "No Images",
                    systemImage: "photo",
                    description: Text(emptyDescription)
                )
            } else {
                ImageGridView(thumbSize: CGFloat(thumbSize))
            }
        }
        .frame(minWidth: 400)
    }

    private var emptyDescription: String {
        let filter = model.filterText
        return if model.folder == nil && model.photoAlbum == nil {
            String(localized: "Choose a folder via ⌘O or drop one here.")
        } else if !filter.isEmpty, model.contentSearch.isEnabled {
            String(localized: "Nothing found for “\(filter)”. Content search understands English words, like dog, beach or car.")
        } else if !filter.isEmpty {
            String(localized: "No images match “\(filter)”.")
        } else if model.flagFilter != .all {
            String(localized: "No images with this flag.")
        } else if model.photoAlbum != nil {
            String(localized: "This album has no images.")
        } else {
            String(localized: "This folder has no images.")
        }
    }

    private var detail: some View {
        Group {
            // Hidden under fullscreen, so the two viewers don't both decode.
            if let item = model.currentItem, !model.isFullscreen {
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

/// The "This Folder / Everywhere" scope bar under the search field, shown only
/// while content search is on (there is nothing to search everywhere without
/// the index).
private struct SearchScopePicker: ViewModifier {
    let isEnabled: Bool
    let inAlbum: Bool
    @Binding var scope: SearchScope

    func body(content: Content) -> some View {
        if isEnabled {
            content.searchScopes($scope) {
                ForEach(SearchScope.allCases, id: \.self) { scope in
                    Text(scope.label(inAlbum: inAlbum)).tag(scope)
                }
            }
        } else {
            content
        }
    }
}

/// Hands Escape key presses in its window to `action`, which returns whether it
/// used the key. A local event monitor sees the key before any view does, so
/// it works no matter which view has focus. Sheets keep Escape for Cancel.
private struct EscapeKeyMonitor: NSViewRepresentable {
    let action: (_ isEditingText: Bool) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.action = action
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.action = action
    }

    final class MonitorView: NSView {
        var action: ((Bool) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window,
                      event.window === window,
                      window.attachedSheet == nil,
                      event.keyCode == 53,  // Escape
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                      !event.isARepeat,
                      let action = self.action
                else { return event }
                return action(window.firstResponder is NSText) ? nil : event
            }
        }
    }
}

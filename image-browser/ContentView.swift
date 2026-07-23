import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var thumbSize: CGFloat = 160

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
            .navigationTitle(model.folder?.lastPathComponent ?? "Image Browser")
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                StatusBar(item: model.currentItem)
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                model.handleDroppedFolder(url)
                return true
            }

            if model.isFullscreen, let item = model.currentItem {
                FullscreenView(item: item)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: model.isFullscreen)
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
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
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
            Slider(value: .init(get: { thumbSize }, set: { thumbSize = $0 }), in: 80...320)
                .frame(width: 140)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let folder = model.folder {
                Label(folder.lastPathComponent, systemImage: "folder.fill")
                    .padding(.horizontal)
                Text("\(model.items.count) images")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                ContentUnavailableView(
                    "No Folder",
                    systemImage: "photo.on.rectangle",
                    description: Text("Open a folder, drop one onto the window, or pick from File → Open Recent.")
                )
            }
            Spacer()
        }
        .padding(.top)
        .frame(minWidth: 180)
    }

    private var grid: some View {
        Group {
            if model.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty {
                ContentUnavailableView(
                    "No Images",
                    systemImage: "photo",
                    description: Text(model.folder == nil
                                      ? "Choose a folder via ⌘O or drop one here."
                                      : "This folder has no images.")
                )
            } else {
                ImageGridView(thumbSize: thumbSize)
            }
        }
        .frame(minWidth: 400)
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

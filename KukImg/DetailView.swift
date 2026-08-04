import SwiftUI
import AppKit

struct DetailView: View {
    let item: ImageItem
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var scale

    @State private var zoomMode: ZoomMode = .fit
    @State private var pixelSize: CGSize?
    @State private var containerSize: CGSize = .zero

    private var math: ZoomMath {
        ZoomMath(containerSize: containerSize, pixelSize: pixelSize, displayScale: scale)
    }

    var body: some View {
        HStack(spacing: 0) {
            PhotoCanvas(
                item: item,
                zoomMode: $zoomMode,
                pixelSize: $pixelSize,
                backgroundColor: .windowBackgroundColor
            )
            .onGeometryChange(for: CGSize.self) { $0.size } action: { containerSize = $0 }

            if model.showInfoPanel {
                Divider()
                InfoPanel(item: item)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.showInfoPanel)
        .toolbar {
            ToolbarItemGroup {
                Button { zoomMode = math.apply(.zoomOut, to: zoomMode) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                Button { zoomMode = math.apply(.actualSize, to: zoomMode) } label: {
                    Text(math.label(for: zoomMode))
                }
                Button { zoomMode = math.apply(.zoomIn, to: zoomMode) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                Button { zoomMode = .fit } label: { Text("Fit") }
                    .disabled(zoomMode == .fit)
            }
        }
        .navigationTitle(item.name)
        .onChange(of: model.zoomRequest) { _, request in
            // The fullscreen viewer consumes zoom commands while it is up.
            guard let request, !model.isFullscreen else { return }
            zoomMode = math.apply(request.command, to: zoomMode)
        }
    }
}

import SwiftUI
import AppKit

struct FullscreenView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var scale
    let item: ImageItem

    @State private var fullImage: NSImage?
    @State private var preview: NSImage?
    @State private var hovering = false
    @State private var isPlaying = false
    @State private var slideshowTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private let interval: TimeInterval = 4.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let img = fullImage ?? preview {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(fullImage == nil ? .low : .high)
                    .scaledToFit()
                    .padding(8)
            } else {
                ProgressView().tint(.white)
            }

            VStack {
                HStack {
                    Spacer()
                    chromeButton(systemName: isPlaying ? "pause.fill" : "play.fill") {
                        toggleSlideshow()
                    }
                    chromeButton(systemName: "xmark") {
                        model.isFullscreen = false
                    }
                }
                .padding()
                .opacity(hovering || isPlaying ? 1 : 0)

                Spacer()

                HStack {
                    Text(item.name)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.4), in: Capsule())
                    if isPlaying {
                        Label("Slideshow", systemImage: "play.fill")
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.4), in: Capsule())
                    }
                    Spacer()
                    if let idx = model.currentIndex {
                        Text("\(idx + 1) / \(model.items.count)")
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.4), in: Capsule())
                    }
                }
                .padding()
                .opacity(hovering ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.2), value: hovering)
            .animation(.easeInOut(duration: 0.2), value: isPlaying)
        }
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onDisappear { stopSlideshow() }
        .onHover { hovering = $0 }
        .onKeyPress(.leftArrow)  { model.move(by: -1); return .handled }
        .onKeyPress(.rightArrow) { model.move(by:  1); return .handled }
        .onKeyPress(.escape)     { model.isFullscreen = false; return .handled }
        .onKeyPress(.return)     { model.isFullscreen = false; return .handled }
        .onKeyPress(.space)      { toggleSlideshow(); return .handled }
        .onKeyPress("p")         { toggleSlideshow(); return .handled }
        .task(id: item.id) {
            fullImage = nil
            preview = await ThumbnailCache.shared.thumbnail(
                for: item.url, pixelSize: 2048, scale: scale
            )
            let url = item.url
            let img = await Task.detached(priority: .userInitiated) {
                FullImageLoader.load(url: url)
            }.value
            if !Task.isCancelled { fullImage = img }
            model.prefetchNeighbors(thumbSize: 256, scale: scale)
        }
    }

    private func chromeButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.4), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func toggleSlideshow() {
        if isPlaying { stopSlideshow() } else { startSlideshow() }
    }

    private func startSlideshow() {
        isPlaying = true
        slideshowTask?.cancel()
        slideshowTask = Task { @MainActor [weak model = model] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { break }
                guard let model else { break }
                if let idx = model.currentIndex, idx >= model.items.count - 1 {
                    break
                }
                model.move(by: 1)
            }
            self.isPlaying = false
        }
    }

    private func stopSlideshow() {
        isPlaying = false
        slideshowTask?.cancel()
        slideshowTask = nil
    }
}

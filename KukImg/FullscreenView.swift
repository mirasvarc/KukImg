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
    @AppStorage("slideshowInterval") private var interval: Double = 4.0
    @AppStorage("slideshowLoop") private var loops = false

    private static let intervals: [Double] = [2, 4, 8, 15]

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
                    slideshowSettingsMenu
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
                    chromeLabel { Text(item.name) }
                    if isPlaying {
                        chromeLabel { Label("Slideshow", systemImage: "play.fill") }
                    }
                    Spacer()
                    if let idx = model.currentIndex {
                        chromeLabel { Text("\(idx + 1) / \(model.visibleItems.count)") }
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
        .onKeyPress(.upArrow)    { model.move(by: -1); return .handled }
        .onKeyPress(.downArrow)  { model.move(by:  1); return .handled }
        .onKeyPress(.home)       { model.selectFirst(); return .handled }
        .onKeyPress(.end)        { model.selectLast();  return .handled }
        .onKeyPress(.escape)     { model.isFullscreen = false; return .handled }
        .onKeyPress(.return)     { model.isFullscreen = false; return .handled }
        .onKeyPress(.space)      { toggleSlideshow(); return .handled }
        .onKeyPress("p")         { toggleSlideshow(); return .handled }
        .onKeyPress(.delete)     { model.deleteCurrent(); return .handled }
        .task(id: item.id) {
            fullImage = nil
            preview = await ThumbnailCache.shared.thumbnail(
                for: item.url, pixelSize: 2048, scale: scale
            )
            let img = await FullImageCache.shared.image(for: item.url)
            if !Task.isCancelled, let img { fullImage = img }
            model.prefetchNeighbors(thumbSize: 256, scale: scale)

            // Warm the neighboring full images so arrow keys and the slideshow
            // are instant in both directions.
            if let idx = model.currentIndex, idx + 1 < model.visibleItems.count {
                let next = model.visibleItems[idx + 1].url
                _ = await FullImageCache.shared.image(for: next)
            }
            if let idx = model.currentIndex, idx > 0, idx - 1 < model.visibleItems.count {
                let previous = model.visibleItems[idx - 1].url
                _ = await FullImageCache.shared.image(for: previous)
            }
        }
    }

    private var slideshowSettingsMenu: some View {
        Menu {
            Picker("Interval", selection: $interval) {
                ForEach(Self.intervals, id: \.self) { value in
                    Text("\(Int(value)) s").tag(value)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Loop", isOn: $loops)
        } label: {
            Image(systemName: "timer")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .glassEffect(.regular.interactive(), in: .circle)
        .help("Slideshow settings")
    }

    private func chromeButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
    }

    private func chromeLabel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
    }

    private func toggleSlideshow() {
        if isPlaying { stopSlideshow() } else { startSlideshow() }
    }

    private func startSlideshow() {
        isPlaying = true
        NSCursor.setHiddenUntilMouseMoves(true)
        slideshowTask?.cancel()
        slideshowTask = Task { @MainActor [weak model = model] in
            while !Task.isCancelled {
                // Read settings each round so changes apply mid-slideshow.
                let defaults = UserDefaults.standard
                let stored = defaults.double(forKey: "slideshowInterval")
                try? await Task.sleep(for: .seconds(stored > 0 ? stored : 4.0))
                if Task.isCancelled { break }
                guard let model else { break }
                let atEnd = (model.currentIndex ?? 0) >= model.visibleItems.count - 1
                if atEnd {
                    guard defaults.bool(forKey: "slideshowLoop"),
                          model.visibleItems.count > 1 else { break }
                    NSCursor.setHiddenUntilMouseMoves(true)
                    model.selectFirst()
                } else {
                    NSCursor.setHiddenUntilMouseMoves(true)
                    model.move(by: 1)
                }
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

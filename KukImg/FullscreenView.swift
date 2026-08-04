import SwiftUI
import AppKit

struct FullscreenView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var scale
    let item: ImageItem

    @State private var zoomMode: ZoomMode = .fit
    @State private var pixelSize: CGSize?
    @State private var containerSize: CGSize = .zero
    @State private var chromeVisible = true
    /// True while the pointer rests on a chrome bar — blocks auto-hide.
    @State private var overChrome = false
    @State private var hideChromeTask: Task<Void, Never>?
    @State private var isPlaying = false
    @State private var slideshowTask: Task<Void, Never>?
    /// Local monitor for trackpad swipes and mouse back/forward buttons.
    @State private var eventMonitor: Any?
    @FocusState private var focused: Bool
    @AppStorage("slideshowInterval") private var interval: Double = 4.0
    @AppStorage("slideshowLoop") private var loops = false
    @AppStorage("slideshowShuffle") private var shuffle = false

    private static let intervals: [Double] = [2, 4, 8, 15]

    private var math: ZoomMath {
        ZoomMath(containerSize: containerSize, pixelSize: pixelSize, displayScale: scale)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PhotoCanvas(
                item: item,
                zoomMode: $zoomMode,
                pixelSize: $pixelSize,
                backgroundColor: .black
            )
            .ignoresSafeArea()
            chrome
        }
        .ignoresSafeArea()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { containerSize = $0 }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onContinuousHover { phase in
            guard case .active = phase else { return }
            showChrome()
        }
        .onAppear {
            focused = true
            showChrome()
            installEventMonitor()
        }
        .onDisappear {
            stopSlideshow()
            hideChromeTask?.cancel()
            removeEventMonitor()
        }
        .onKeyPress(.leftArrow)  { navigate { model.move(by: -1) } }
        .onKeyPress(.rightArrow) { navigate { model.move(by:  1) } }
        .onKeyPress(.upArrow)    { navigate { model.move(by: -1) } }
        .onKeyPress(.downArrow)  { navigate { model.move(by:  1) } }
        .onKeyPress(.home)       { navigate { model.selectFirst() } }
        .onKeyPress(.end)        { navigate { model.selectLast() } }
        .onKeyPress(.escape)     { model.isFullscreen = false; return .handled }
        .onKeyPress(.return)     { model.isFullscreen = false; return .handled }
        .onKeyPress(.space)      { toggleSlideshow(); return .handled }
        .onKeyPress("p")         { model.setFlag(.pick, for: [item]); return .handled }
        .onKeyPress("x")         { model.setFlag(.reject, for: [item]); return .handled }
        .onKeyPress("u")         { model.setFlag(nil, for: [item]); return .handled }
        // Only the image on screen — never a wider selection made in the grid.
        .onKeyPress(.delete)     { model.delete([item]); return .handled }
        .onChange(of: model.zoomRequest) { _, request in
            guard let request else { return }
            zoomMode = math.apply(request.command, to: zoomMode)
        }
    }

    // MARK: - Chrome

    private var chrome: some View {
        VStack {
            HStack {
                Spacer()
                chromeButton(systemName: "square.and.arrow.up") {
                    Sharing.share([item])
                }
                slideshowSettingsMenu
                chromeButton(systemName: isPlaying ? "pause.fill" : "play.fill") {
                    toggleSlideshow()
                }
                chromeButton(systemName: "xmark") {
                    model.isFullscreen = false
                }
            }
            .padding()
            .onHover { overChrome = $0 }

            Spacer()

            VStack(spacing: 10) {
                if model.visibleItems.count > 1 {
                    filmstrip
                }
                HStack {
                    chromeLabel { Text(item.name) }
                    if let flag = model.flag(for: item) {
                        chromeLabel {
                            Label(
                                flag == .pick ? "Picked" : "Rejected",
                                systemImage: flag == .pick ? "checkmark.circle.fill" : "xmark.circle.fill"
                            )
                            .foregroundStyle(flag == .pick ? Color.green : Color.red)
                        }
                    }
                    if isPlaying {
                        chromeLabel { Label("Slideshow", systemImage: "play.fill") }
                    }
                    if case .zoom = zoomMode {
                        chromeLabel { Text(math.label(for: zoomMode)) }
                    }
                    Spacer()
                    if let idx = model.currentIndex {
                        chromeLabel { Text("\(idx + 1) / \(model.visibleItems.count)") }
                    }
                }
            }
            .padding()
            .onHover { overChrome = $0 }
        }
        .opacity(chromeVisible ? 1 : 0)
        .allowsHitTesting(chromeVisible)
        .animation(.easeInOut(duration: 0.2), value: chromeVisible)
        .animation(.easeInOut(duration: 0.2), value: isPlaying)
    }

    /// Chrome shows on any mouse movement and hides again after two idle
    /// seconds (unless the pointer rests on a control), Preview-style.
    private func showChrome() {
        if !chromeVisible { chromeVisible = true }
        hideChromeTask?.cancel()
        hideChromeTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, !overChrome else { return }
            chromeVisible = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(model.visibleItems) { thumb in
                        FilmstripThumb(item: thumb, isCurrent: thumb.id == model.selection)
                            .id(thumb.id)
                            .onTapGesture {
                                navigate { model.select(thumb.id) }
                            }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .frame(height: 68)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            .onChange(of: model.selection) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onAppear {
                if let id = model.selection { proxy.scrollTo(id, anchor: .center) }
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
            Toggle("Shuffle", isOn: $shuffle)
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

    // MARK: - Navigation

    /// Manual navigation during a slideshow restarts its timer, so the next
    /// automatic advance comes a full interval after the interaction.
    @discardableResult
    private func navigate(_ move: () -> Void) -> KeyPress.Result {
        move()
        if isPlaying { startSlideshow() }
        return .handled
    }

    /// Trackpad two-finger swipes and mouse back/forward buttons page through
    /// the photos — SwiftUI exposes neither, so a local monitor fills in.
    private func installEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.swipe, .otherMouseUp]) { event in
            switch event.type {
            case .swipe where event.deltaX > 0:
                navigate { model.move(by: -1) }
                return nil
            case .swipe where event.deltaX < 0:
                navigate { model.move(by: 1) }
                return nil
            case .otherMouseUp where event.buttonNumber == 3:
                navigate { model.move(by: -1) }
                return nil
            case .otherMouseUp where event.buttonNumber == 4:
                navigate { model.move(by: 1) }
                return nil
            default:
                return event
            }
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }

    // MARK: - Slideshow

    private func toggleSlideshow() {
        if isPlaying { stopSlideshow() } else { startSlideshow() }
    }

    private func startSlideshow() {
        isPlaying = true
        NSCursor.setHiddenUntilMouseMoves(true)
        slideshowTask?.cancel()
        slideshowTask = Task { @MainActor [weak model = model] in
            // Shuffle plays every image exactly once per pass in random order.
            var shuffleQueue: [ImageItem.ID] = []
            var playedFullPass = false
            while !Task.isCancelled {
                // Read settings each round so changes apply mid-slideshow.
                let defaults = UserDefaults.standard
                let stored = defaults.double(forKey: "slideshowInterval")
                try? await Task.sleep(for: .seconds(stored > 0 ? stored : 4.0))
                if Task.isCancelled { break }
                guard let model else { break }
                let looping = defaults.bool(forKey: "slideshowLoop")

                if defaults.bool(forKey: "slideshowShuffle") {
                    if shuffleQueue.isEmpty {
                        if playedFullPass, !looping { break }
                        shuffleQueue = model.visibleItems.map(\.id).shuffled()
                            .filter { $0 != model.selection }
                        playedFullPass = true
                        guard !shuffleQueue.isEmpty else { break }
                    }
                    let next = shuffleQueue.removeFirst()
                    guard model.visibleItems.contains(where: { $0.id == next }) else { continue }
                    NSCursor.setHiddenUntilMouseMoves(true)
                    model.selection = next
                } else {
                    let atEnd = (model.currentIndex ?? 0) >= model.visibleItems.count - 1
                    if atEnd {
                        guard looping, model.visibleItems.count > 1 else { break }
                        NSCursor.setHiddenUntilMouseMoves(true)
                        model.selectFirst()
                    } else {
                        NSCursor.setHiddenUntilMouseMoves(true)
                        model.move(by: 1)
                    }
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

/// One thumbnail in the fullscreen filmstrip.
private struct FilmstripThumb: View {
    let item: ImageItem
    let isCurrent: Bool
    @Environment(\.displayScale) private var scale
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(.white.opacity(0.08))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .frame(width: 52, height: 52)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isCurrent ? Color.white : .clear, lineWidth: 2)
        )
        .help(item.name)
        .task(id: "\(item.id.path)|\(item.modifiedAt.timeIntervalSince1970)") {
            image = await ImageLoading.thumbnail(for: item, pixelSize: 128, scale: scale)
        }
    }
}

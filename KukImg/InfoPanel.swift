import SwiftUI
import AppKit

struct InfoPanel: View {
    let item: ImageItem
    @Environment(\.displayScale) private var scale
    @State private var meta: ImageMetadata?
    @State private var histogram: Histogram?
    @State private var showAllMetadata = false
    @State private var allSections: [MetadataSection] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Info").font(.headline)

                section {
                    row("File", item.name)
                    if let size = meta?.fileSize {
                        row("Size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                    if let w = meta?.pixelWidth, let h = meta?.pixelHeight {
                        row("Dimensions", "\(w) × \(h)")
                    }
                    if let mp = meta?.megapixels {
                        row("Megapixels", String(format: "%.1f MP", mp))
                    }
                    if let color = meta?.colorModel {
                        row("Color", color)
                    }
                }

                if let histogram {
                    Divider()
                    HistogramView(histogram: histogram)
                        .frame(height: 56)
                        .help("RGB histogram")
                }

                if hasCameraInfo {
                    Divider()
                    section {
                        if let camera = meta?.camera { row("Camera", camera) }
                        if let lens = meta?.lens { row("Lens", lens) }
                        if let iso = meta?.iso { row("ISO", "\(iso)") }
                        if let s = meta?.shutterSpeed { row("Shutter", s) }
                        if let a = meta?.aperture { row("Aperture", String(format: "ƒ/%.1f", a)) }
                        if let f = meta?.focalLength { row("Focal", String(format: "%.0f mm", f)) }
                        if let d = meta?.dateTaken {
                            row("Taken", d.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                }

                if let lat = meta?.latitude, let lon = meta?.longitude {
                    Divider()
                    section {
                        row("GPS", String(format: "%.5f, %.5f", lat, lon))
                        Button {
                            openInMaps(latitude: lat, longitude: lon)
                        } label: {
                            Label("Open in Maps", systemImage: "map")
                                .font(.caption)
                        }
                        .buttonStyle(.link)
                    }
                }

                if fileAvailable {
                    Divider()
                    DisclosureGroup("All Metadata", isExpanded: $showAllMetadata) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(allSections) { section in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(section.name)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    ForEach(section.entries) { entry in
                                        row(entry.key, entry.value)
                                    }
                                }
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(.caption)
                }

                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 240)
        .background(.regularMaterial)
        .task(id: item) {
            meta = nil
            histogram = nil
            allSections = []
            // Never materializes a Photos asset — PhotoKit answers dimensions,
            // date and GPS directly; full EXIF appears once a file exists.
            self.meta = await ImageLoading.metadata(for: item)
            if let thumb = await ImageLoading.thumbnail(for: item, pixelSize: 256, scale: scale),
               !Task.isCancelled {
                histogram = HistogramBuilder.build(from: thumb)
            }
            if showAllMetadata { await loadAllMetadata() }
        }
        .onChange(of: showAllMetadata) { _, expanded in
            guard expanded, allSections.isEmpty else { return }
            Task { await loadAllMetadata() }
        }
    }

    /// The raw property dump needs a real file; un-materialized Photos assets
    /// only get it after something exports them (opening the photo suffices).
    private var fileAvailable: Bool {
        FileManager.default.fileExists(atPath: item.url.path)
    }

    private func loadAllMetadata() async {
        guard fileAvailable else { return }
        let url = item.url
        allSections = await Task.detached(priority: .userInitiated) {
            MetadataReader.allMetadata(url: url)
        }.value
    }

    private func openInMaps(latitude: Double, longitude: Double) {
        var components = URLComponents(string: "https://maps.apple.com/")!
        components.queryItems = [
            URLQueryItem(name: "ll", value: "\(latitude),\(longitude)"),
            URLQueryItem(name: "q", value: item.name)
        ]
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    private var hasCameraInfo: Bool {
        guard let m = meta else { return false }
        return m.camera != nil || m.lens != nil || m.iso != nil || m.shutterSpeed != nil
            || m.aperture != nil || m.focalLength != nil || m.dateTaken != nil
    }

    @ViewBuilder
    private func section<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) { content() }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).font(.caption)
            Spacer(minLength: 8)
            Text(value).font(.caption).multilineTextAlignment(.trailing).lineLimit(2)
        }
        .contextMenu {
            Button("Copy Value") { copyToPasteboard(value) }
            Button("Copy \"\(label): \(value)\"") { copyToPasteboard("\(label): \(value)") }
        }
    }

    private func copyToPasteboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}

/// Filled RGB curves, overlaid with partial opacity like every photo editor.
struct HistogramView: View {
    let histogram: Histogram

    var body: some View {
        Canvas { context, size in
            for (bins, color) in [
                (histogram.red, Color.red),
                (histogram.green, Color.green),
                (histogram.blue, Color.blue)
            ] {
                context.fill(path(for: bins, in: size), with: .color(color.opacity(0.45)))
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private func path(for bins: [CGFloat], in size: CGSize) -> Path {
        var path = Path()
        guard bins.count > 1 else { return path }
        path.move(to: CGPoint(x: 0, y: size.height))
        for (index, value) in bins.enumerated() {
            let x = size.width * CGFloat(index) / CGFloat(bins.count - 1)
            path.addLine(to: CGPoint(x: x, y: size.height * (1 - value)))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        return path
    }
}

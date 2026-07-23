import SwiftUI

struct InfoPanel: View {
    let item: ImageItem
    @State private var meta: ImageMetadata?

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
                    section { row("GPS", String(format: "%.5f, %.5f", lat, lon)) }
                }

                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 240)
        .background(.regularMaterial)
        .task(id: item.id) {
            let url = item.url
            self.meta = await Task.detached(priority: .userInitiated) {
                MetadataReader.read(url: url)
            }.value
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
    }
}

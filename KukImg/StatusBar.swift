import SwiftUI

struct StatusBar: View {
    let item: ImageItem?
    var selectedCount: Int = 0
    @State private var meta: ImageMetadata?

    var body: some View {
        HStack(spacing: 16) {
            if let item {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                if selectedCount > 1 {
                    Text("\(selectedCount) selected")
                        .foregroundStyle(.tint)
                }
                Spacer()
                if let w = meta?.pixelWidth, let h = meta?.pixelHeight {
                    Text("\(w) × \(h)")
                }
                if let mp = meta?.megapixels {
                    Text(String(format: "%.1f MP", mp))
                }
                if let size = meta?.fileSize {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
            } else {
                Text(" ")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .task(id: item) {
            meta = nil
            guard let item else { return }
            // Never materializes a Photos asset — PhotoKit answers directly.
            self.meta = await ImageLoading.metadata(for: item)
        }
    }
}

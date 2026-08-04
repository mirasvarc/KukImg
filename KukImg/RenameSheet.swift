import SwiftUI

/// Rename for the current selection: a plain name field for a single file, a
/// numbering pattern for a batch (`#` runs become zero-padded counters).
struct RenameSheet: View {
    let items: [ImageItem]
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var pattern = ""
    @State private var start = 1
    @State private var error: String?
    @FocusState private var fieldFocused: Bool

    private var isBatch: Bool { items.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "pencil")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isBatch ? "Rename \(items.count) Images" : "Rename Image")
                        .font(.headline)
                    Text(isBatch ? "A run of # becomes a counter." : items[0].name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(16)
            Divider()

            Form {
                if isBatch {
                    TextField("Pattern", text: $pattern)
                        .focused($fieldFocused)
                    Stepper("Start at \(start)", value: $start, in: 0...99_999)
                    LabeledContent("Preview", value: batchPreview)
                } else {
                    TextField("Name", text: $name)
                        .focused($fieldFocused)
                    if !items[0].url.pathExtension.isEmpty {
                        LabeledContent("Extension", value: ".\(items[0].url.pathExtension) (kept)")
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 220)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename") { perform() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBatch ? pattern.isEmpty : name.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 420)
        .onAppear {
            name = items[0].url.deletingPathExtension().lastPathComponent
            pattern = "\(model.sourceTitle ?? "Image")-###"
            fieldFocused = true
        }
    }

    private var batchPreview: String {
        let hashes = pattern.filter { $0 == "#" }.count
        let number = String(format: "%0\(max(hashes, 1))d", start)
        let base = hashes > 0
            ? pattern.replacingOccurrences(of: String(repeating: "#", count: hashes), with: number)
            : "\(pattern)-\(number)"
        let ext = items[0].url.pathExtension
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    private func perform() {
        if isBatch {
            let failures = model.renameBatch(items, pattern: pattern, start: start)
            if failures > 0 {
                error = "\(failures) file(s) could not be renamed (name in use?)."
            } else {
                dismiss()
            }
        } else {
            if let message = model.rename(items[0], to: name) {
                error = message
            } else {
                dismiss()
            }
        }
    }
}

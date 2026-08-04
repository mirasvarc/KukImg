import SwiftUI
import AppKit

/// Batch format conversion for the current selection.
struct ConvertSheet: View {
    let items: [ImageItem]
    @Environment(\.dismiss) private var dismiss

    @AppStorage("convertFormat") private var formatRaw = ConversionFormat.png.rawValue
    @AppStorage("convertQuality") private var quality = 0.85
    @AppStorage("convertMaxPixelSize") private var maxPixelSize = 0  // 0 = original
    @AppStorage("convertDeleteOriginals") private var deleteOriginals = false

    @State private var destination: URL?
    @State private var animatedCount = 0
    @State private var job = ConversionJob()

    private static let sizes: [Int] = [0, 4096, 2048, 1024, 512]

    private var format: ConversionFormat {
        ConversionFormat(rawValue: formatRaw) ?? ConversionFormat.available.first ?? .png
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Group {
                if job.isFinished {
                    summary
                } else if job.isRunning {
                    progress
                } else {
                    form
                }
            }
            Divider()
            footer
        }
        .frame(width: 440)
        .task {
            let urls = items.filter { !$0.isAsset }.map(\.url)
            animatedCount = await Task.detached(priority: .utility) {
                ImageConverter.animatedCount(in: urls)
            }.value
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Convert Images").font(.headline)
                Text(items.count == 1 ? items[0].name : "\(items.count) images selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(16)
    }

    private var form: some View {
        Form {
            Section {
                Picker("Format", selection: $formatRaw) {
                    ForEach(ConversionFormat.available) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                if format.supportsQuality {
                    LabeledContent("Quality") {
                        HStack {
                            Slider(value: $quality, in: 0.2...1.0)
                            Text("\(Int(quality * 100))%")
                                .monospacedDigit()
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                }
                Picker("Maximum size", selection: $maxPixelSize) {
                    ForEach(Self.sizes, id: \.self) { size in
                        Text(size == 0 ? "Original" : "\(size) px").tag(size)
                    }
                }
            }
            Section {
                LabeledContent("Save to") {
                    HStack {
                        Text(destination?.lastPathComponent ?? "Same folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if destination != nil {
                            Button("Reset") { destination = nil }
                        }
                        Button("Choose…") { pickDestination() }
                    }
                }
                Toggle("Move originals to Trash", isOn: $deleteOriginals)
            }
            if !warnings.isEmpty {
                Section {
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxHeight: 380)
    }

    private var progress: some View {
        VStack(spacing: 12) {
            ProgressView(value: job.progress)
            Text("\(job.completed) of \(job.total)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "\(job.succeeded.count) converted" + (job.failed.isEmpty ? "" : ", \(job.failed.count) failed"),
                systemImage: job.failed.isEmpty ? "checkmark.circle" : "exclamationmark.circle"
            )
            .font(.headline)
            .foregroundStyle(job.failed.isEmpty ? Color.green : .orange)

            if !job.failed.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(job.failed) { result in
                            Text("\(result.source.lastPathComponent) — \(result.error ?? "failed")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            if job.isFinished, let first = job.succeeded.first?.output {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(job.succeeded.compactMap(\.output))
                }
                .help(first.deletingLastPathComponent().path)
            }
            Spacer()
            if job.isRunning {
                Button("Stop") { job.cancel() }
            } else if job.isFinished {
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Convert") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(items.isEmpty || ConversionFormat.available.isEmpty)
            }
        }
        .padding(16)
    }

    // MARK: - Actions

    private var warnings: [String] {
        var result: [String] = []
        if animatedCount > 0 {
            result.append(
                animatedCount == 1
                    ? "One image is animated — only its first frame is converted."
                    : "\(animatedCount) images are animated — only their first frame is converted."
            )
        }
        if !format.supportsAlpha {
            result.append("\(format.label) has no transparency; transparent areas become white.")
        }
        if deleteOriginals {
            result.append("Originals are moved to the Trash after a successful conversion.")
        }
        if items.contains(where: \.isAsset) {
            result.append("Photos items are exported to a temporary copy before converting.")
        }
        return result
    }

    private func pickDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where the converted images are saved."
        guard panel.runModal() == .OK else { return }
        destination = panel.url
    }

    private func start() {
        // Photos assets have no home folder to write next to — only a cache
        // copy — so any selection containing one needs an explicit destination.
        var target = destination
        if target == nil, items.contains(where: \.isAsset) {
            pickDestination()
            target = destination
            guard target != nil else { return }
        }
        job.start(items: items, options: ConversionOptions(
            format: format,
            quality: quality,
            maxPixelSize: maxPixelSize == 0 ? nil : maxPixelSize,
            destination: target,
            deleteOriginals: deleteOriginals
        ))
    }
}

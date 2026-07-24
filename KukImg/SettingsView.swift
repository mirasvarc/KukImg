import SwiftUI
import AppKit
import Sparkle

/// App settings, opened from the Kuk menu (Settings…, ⌘,).
struct SettingsView: View {
    let updater: SPUUpdater

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            AboutView(updater: updater)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 440)
    }
}

private struct GeneralSettingsView: View {
    @AppStorage("restoreLastFolder") private var restoreLastFolder = true
    @AppStorage("showFilenames") private var showFilenames = false
    @AppStorage("slideshowInterval") private var slideshowInterval = 4.0
    @AppStorage("slideshowLoop") private var slideshowLoop = false

    private static let intervals: [Double] = [2, 4, 8, 15]

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Reopen last folder at launch", isOn: $restoreLastFolder)
            }
            Section("Browsing") {
                Toggle("Show filenames under thumbnails", isOn: $showFilenames)
            }
            Section("Slideshow") {
                Picker("Interval", selection: $slideshowInterval) {
                    ForEach(Self.intervals, id: \.self) { value in
                        Text("\(Int(value)) seconds").tag(value)
                    }
                }
                Toggle("Loop at the end", isOn: $slideshowLoop)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutView: View {
    let updater: SPUUpdater

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return build == short ? short : "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            Text("Kuk")
                .font(.title.bold())
            Text("Version \(version)")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("A fast, native macOS image viewer.")
                .font(.callout)
                .multilineTextAlignment(.center)

            CheckForUpdatesView(updater: updater)
                .padding(.top, 4)

            HStack(spacing: 16) {
                Link("GitHub", destination: URL(string: "https://github.com/mirasvarc/KukImg")!)
                Link("Report an Issue", destination: URL(string: "https://github.com/mirasvarc/KukImg/issues")!)
            }
            .font(.callout)

            Text("MIT License")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

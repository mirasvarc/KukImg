import Foundation

/// Culling flags persisted as Finder tags on the files themselves: a green
/// "Pick" and a red "Reject" tag. They show up in Finder, travel with the file
/// when it is moved or copied and are searchable in Spotlight.
///
/// The tag list is written straight into the `_kMDItemUserTags` extended
/// attribute (the same binary plist Finder writes) because that is the only
/// way to give a tag its colour; other tags on the file are left untouched.
nonisolated enum FinderTags {
    static let pickName = "Pick"
    static let rejectName = "Reject"

    private static let attribute = "com.apple.metadata:_kMDItemUserTags"
    /// Finder's colour indices: 2 = green, 6 = red.
    private static let pickEntry = "\(pickName)\n2"
    private static let rejectEntry = "\(rejectName)\n6"

    /// The flag encoded in a file's tag names (as returned by `.tagNamesKey`).
    static func flag(fromTagNames names: [String]?) -> ImageFlag? {
        guard let names, !names.isEmpty else { return nil }
        if names.contains(pickName) { return .pick }
        if names.contains(rejectName) { return .reject }
        return nil
    }

    /// Replaces any Pick/Reject tag on the file with `flag` (nil removes both).
    @discardableResult
    static func write(_ flag: ImageFlag?, to url: URL) -> Bool {
        var entries = readEntries(url).filter { entry in
            let name = tagName(of: entry)
            return name != pickName && name != rejectName
        }
        switch flag {
        case .pick:   entries.append(pickEntry)
        case .reject: entries.append(rejectEntry)
        case nil:     break
        }
        return writeEntries(entries, to: url)
    }

    /// Tag entries are "Name" or "Name\n<colour index>".
    static func tagName(of entry: String) -> String {
        entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? entry
    }

    static func encode(_ entries: [String]) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
    }

    static func decode(_ data: Data) -> [String] {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String] ?? []
    }

    private static func readEntries(_ url: URL) -> [String] {
        url.withUnsafeFileSystemRepresentation { path -> [String] in
            guard let path else { return [] }
            let size = getxattr(path, attribute, nil, 0, 0, 0)
            guard size > 0 else { return [] }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { buffer in
                getxattr(path, attribute, buffer.baseAddress, size, 0, 0)
            }
            guard read > 0 else { return [] }
            return decode(data.prefix(read))
        }
    }

    private static func writeEntries(_ entries: [String], to url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            if entries.isEmpty {
                return removexattr(path, attribute, 0) == 0 || errno == ENOATTR
            }
            guard let data = encode(entries) else { return false }
            return data.withUnsafeBytes { buffer in
                setxattr(path, attribute, buffer.baseAddress, data.count, 0, 0) == 0
            }
        }
    }
}

/// Photos assets have no file Kuk may tag, so their flags live in the app's
/// defaults, keyed by the asset's local identifier.
nonisolated enum AssetFlagStore {
    private static let key = "assetFlags"

    static func all() -> [String: ImageFlag] {
        let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        return raw.compactMapValues(ImageFlag.init(rawValue:))
    }

    static func set(_ flag: ImageFlag?, for ids: [String]) {
        var raw = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        for id in ids { raw[id] = flag?.rawValue }
        UserDefaults.standard.set(raw, forKey: key)
    }
}

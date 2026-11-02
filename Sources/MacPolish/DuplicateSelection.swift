import Foundation

enum DuplicateSelection {
    /// Keep the first path alphabetically, independent of previous selections.
    static func extras(in files: [DuplicateFile]) -> Set<UUID> {
        Set(Dictionary(grouping: files, by: \.fingerprint).values.flatMap { group in
            group.sorted { $0.url.path < $1.url.path }.dropFirst().map(\.id)
        })
    }
}

import Foundation

struct DestinationBookmarkStore {
    private let defaults: UserDefaults
    private let key = "ColdShot.SprintZero.DestinationBookmark"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(url: URL) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(data, forKey: key)
    }

    func resolve() throws -> URL? {
        guard let data = defaults.data(forKey: key) else { return nil }
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        if isStale {
            try save(url: url)
        }
        return url
    }
}


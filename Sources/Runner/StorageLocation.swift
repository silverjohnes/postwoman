import Foundation

/// Where collections, globals and history live.
/// The app is sandboxed, so a folder chosen by the user is remembered as a security-scoped bookmark
/// (a plain path would stop being accessible after a restart). Default: Application Support inside the app container.
enum StorageLocation {
    private static let bookmarkKey = "storageBookmark"
    nonisolated(unsafe) private static var cached: URL?
    nonisolated(unsafe) private static var accessing: URL?

    static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Postwoman")
    }
    static var isDefault: Bool { UserDefaults.standard.data(forKey: bookmarkKey) == nil }

    /// Current storage folder (security scope is opened on first use and stays open while the app runs).
    static var current: URL {
        if let c = cached { return c }
        var url = defaultFolder
        if let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) {
                _ = u.startAccessingSecurityScopedResource(); accessing = u; url = u
                if stale, let fresh = try? u.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    UserDefaults.standard.set(fresh, forKey: bookmarkKey)
                }
            }
        }
        cached = url
        return url
    }

    /// `url` comes from NSOpenPanel, so the sandbox grants access to it right now.
    @discardableResult
    static func choose(_ url: URL) -> Bool {
        guard let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else { return false }
        release()
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        cached = nil
        return true
    }
    static func reset() { release(); UserDefaults.standard.removeObject(forKey: bookmarkKey); cached = nil }

    private static func release() { accessing?.stopAccessingSecurityScopedResource(); accessing = nil }
}

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

    // MARK: Backup folder
    // A second folder that gets every change as well (for cloud storage, if needed). Same mechanism: a security-scoped bookmark.
    private static let backupKey = "backupBookmark", backupPathKey = "backupPath", backupOnKey = "backupEnabled"
    nonisolated(unsafe) private static var backupCached: URL?
    nonisolated(unsafe) private static var backupAccessing: URL?

    static var backupEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: backupOnKey) }
        set { UserDefaults.standard.set(newValue, forKey: backupOnKey) }
    }
    static var backupIsSet: Bool { UserDefaults.standard.data(forKey: backupKey) != nil }
    /// Last known path of the backup folder (also when it cannot be opened right now).
    static var backupPath: String { UserDefaults.standard.string(forKey: backupPathKey) ?? "" }
    /// The backup folder with its security scope open; nil when none is set or the bookmark no longer resolves (folder deleted, volume missing).
    static var backup: URL? {
        if let c = backupCached { return c }
        guard let data = UserDefaults.standard.data(forKey: backupKey) else { return nil }
        var stale = false
        guard let u = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        _ = u.startAccessingSecurityScopedResource(); backupAccessing = u
        if stale, let fresh = try? u.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: backupKey)
        }
        UserDefaults.standard.set(u.path, forKey: backupPathKey)
        backupCached = u
        return u
    }
    @discardableResult
    static func chooseBackup(_ url: URL) -> Bool {
        guard let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else { return false }
        backupAccessing?.stopAccessingSecurityScopedResource(); backupAccessing = nil
        UserDefaults.standard.set(data, forKey: backupKey)
        UserDefaults.standard.set(url.path, forKey: backupPathKey)
        backupCached = nil
        return true
    }
    static func resetBackup() {
        backupAccessing?.stopAccessingSecurityScopedResource(); backupAccessing = nil
        UserDefaults.standard.removeObject(forKey: backupKey); UserDefaults.standard.removeObject(forKey: backupPathKey)
        backupCached = nil; backupEnabled = false
    }
}

// MARK: - Mirror: main folder → backup folder
enum StorageMirror {
    struct Outcome { var copied = 0, removed = 0; var error: String? }
    private static let files = ["globals.json", "collections-order.json"]
    private static let dirs = ["collections", "history"]

    /// Makes the backup folder match the main one (collections, history, globals, order). Runs off the main thread.
    /// Only files that differ are copied (size / modification time); files that are gone from the main folder are removed from the backup.
    nonisolated static func sync(from src: URL, to dst: URL) -> Outcome {
        var out = Outcome()
        let fm = FileManager.default
        let a = src.standardizedFileURL.path, b = dst.standardizedFileURL.path
        guard a != b, !b.hasPrefix(a + "/"), !a.hasPrefix(b + "/") else { out.error = "the backup folder must be a different folder, not inside the main one (or the other way round)"; return out }
        do { try fm.createDirectory(at: dst, withIntermediateDirectories: true) }
        catch { out.error = error.localizedDescription; return out }
        guard fm.isWritableFile(atPath: dst.path) else { out.error = "the folder is not writable"; return out }

        func meta(_ u: URL) -> (Int, Date)? {
            guard let at = try? fm.attributesOfItem(atPath: u.path) else { return nil }
            return ((at[.size] as? NSNumber)?.intValue ?? -1, at[.modificationDate] as? Date ?? .distantPast)
        }
        func copy(_ s: URL, _ d: URL) throws {
            guard let ms = meta(s) else { return }
            if let md = meta(d), md.0 == ms.0, abs(md.1.timeIntervalSince(ms.1)) < 1 { return }
            let tmp = d.deletingLastPathComponent().appendingPathComponent(".pw-" + d.lastPathComponent + ".tmp")
            try? fm.removeItem(at: tmp)
            try fm.copyItem(at: s, to: tmp)
            try? fm.setAttributes([.modificationDate: ms.1], ofItemAtPath: tmp.path)
            if fm.fileExists(atPath: d.path) { _ = try fm.replaceItemAt(d, withItemAt: tmp) } else { try fm.moveItem(at: tmp, to: d) }
            out.copied += 1
        }
        do {
            for f in files {
                let s = src.appendingPathComponent(f), d = dst.appendingPathComponent(f)
                if fm.fileExists(atPath: s.path) { try copy(s, d) }
                else if fm.fileExists(atPath: d.path) { try fm.removeItem(at: d); out.removed += 1 }
            }
            for name in dirs {
                let s = src.appendingPathComponent(name), d = dst.appendingPathComponent(name)
                guard let mine = try? fm.contentsOfDirectory(atPath: s.path) else { continue }       // nothing in the main folder yet: leave the backup alone
                try fm.createDirectory(at: d, withIntermediateDirectories: true)
                for f in mine where !f.hasPrefix(".") { try copy(s.appendingPathComponent(f), d.appendingPathComponent(f)) }
                for g in (try? fm.contentsOfDirectory(atPath: d.path)) ?? [] where !g.hasPrefix(".") && !mine.contains(g) {
                    try fm.removeItem(at: d.appendingPathComponent(g)); out.removed += 1
                }
            }
        } catch { out.error = error.localizedDescription }
        return out
    }

    /// Can files be created in this folder right now? (a probe file is written and removed)
    nonisolated static func probe(_ dir: URL) -> String? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = dir.appendingPathComponent(".pw-probe-\(UUID().uuidString)")
            try Data("ok".utf8).write(to: f); try fm.removeItem(at: f)
            return nil
        } catch { return error.localizedDescription }
    }
}

import UniformTypeIdentifiers
import SwiftUI
import AppKit
import Combine
import CryptoKit

struct InheritedHeader: Identifiable { let h: KV; let from: String; var id: UUID { h.id } }

enum DropPos { case before, after, inside }
struct DropHint: Equatable { let id: UUID; let pos: DropPos }

enum MainTab: String, CaseIterable { case request = "Request", runner = "Runner", globals = "Globals", log = "Log" }

@MainActor
final class Store: ObservableObject {
    @Published var roots: [Node] = []
    @Published var globals: [Var] = []
    @Published var selected: Set<Node> = []
    @Published var primary: Node?                 // last clicked; the Runner target
    @Published var query = "" { didSet { recompute(); if !queryTrimmed.isEmpty { log("search", "'\(queryTrimmed)' (also as \(Node.layoutVariants(queryTrimmed).dropFirst().joined(separator: " / "))) → \(matches.count) match(es)", .debug) } } }
    @Published var expanded: Set<UUID> = []
    @Published var tab: MainTab = .request { didSet { log("ui", "Tab → \(tab.rawValue)", .debug) } }
    @Published var focusSearch = 0
    @Published var focusFind = 0                  // ⌘F: focus the find field of the visible result pane
    var findPanes = 0                             // number of visible result panes that have a find field
    /// false: the sidebar search looks at names only; true: also at URLs, headers, bodies and scripts
    @Published var searchContent = UserDefaults.standard.bool(forKey: "searchContent") {
        didSet { UserDefaults.standard.set(searchContent, forKey: "searchContent"); recompute() }
    }
    @Published var dropHint: DropHint?
    @Published var unsavedIDs: Set<UUID> = []       // requests with changes that are not on disk (shown with a dot)
    var savedSkeleton: [UUID: Data] = [:]           // collection → its file content (requests as last saved) at the last write
    var savedGlobals = Data()
    var undoStack: [Data] = []
    var redoStack: [Data] = []
    var lastSnap = Data()
    static weak var current: Store?
    var autosave: Bool { UserDefaults.standard.object(forKey: "autosave") as? Bool ?? true }
    @Published var authAlert: UUID?               // a run was refused because of an Authorization problem: the Headers tab highlights it
    @Published var showCurlImport = false
    var dragging: [Node] = []
    var clipboard: [Node] = []
    var clipboardCut = false
    @Published var matches: [Node] = []           // nodes that themselves match the query (tree order)
    @Published var matchIDs: Set<UUID> = []
    @Published var matchIndex = -1
    @Published var scrollTick = 0
    var scrollID: UUID?
    @Published var dataURL: URL?
    @Published var iterations = 1                 // 0 = one pass over all data rows
    @Published var interval = 0
    @Published var error: String? { didSet { if let e = error { log("error", e, .error) } } }
    let logStore = LogStore()
    let runner = Runner()
    let history = HistoryStore(dir: { StorageLocation.current.appendingPathComponent("history") })
    @Published var autoPickResult = false         // running a single request → Runner selects its result (Res body)
    private var lastPruneAt = Date.distantPast
    private var visible: Set<UUID>?
    private var bag = Set<AnyCancellable>()
    var queryTrimmed: String { query.trimmingCharacters(in: .whitespaces) }
    var counter: String { matches.isEmpty ? "0" : (matchIndex < 0 ? "\(matches.count)" : "\(matchIndex + 1)/\(matches.count)") }

    var folder: URL { StorageLocation.current }
    var collectionsDir: URL { folder.appendingPathComponent("collections") }
    var globalsFile: URL { folder.appendingPathComponent("globals.json") }

    func log(_ cat: String, _ msg: String, _ level: LogLevel = .info) { logStore.add(LogEntry(level: level, cat: cat, msg: msg)) }
    let vault = SecretVault.shared
    private var runUsedData = false
    private var preparingRun = false          // a run is waiting for Touch ID: ignore a second ⌘R
    var timeoutSec: Int { UserDefaults.standard.object(forKey: "requestTimeout") as? Int ?? 10 }

    init() {
        runner.sink = { [weak self] l, c, m in self?.log(c, m, l) }
        runner.historySink = { [weak self] r in self?.history.append(r) }
        runner.varsSink = { [weak self] c in self?.applyScriptVars(c) }
        history.log = { [weak self] l, m in self?.log("history", m, l) }
        vault.log = { [weak self] m, l in self?.log("vault", m, l) }
        log("app", "Postwoman started; storage folder \(folder.path)")
        Store.current = self
        load()
        // Autosave: any edit (nodes, tree, globals) → write after 1 s of quiet (see Store+Saving.swift for what is held back); undo snapshots after 0.5 s.
        Publishers.Merge3(Node.changed, $globals.dropFirst().map { _ in () }, $roots.dropFirst().map { _ in () })
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.autosaveTick() } }.store(in: &bag)
        Publishers.Merge3(Node.changed, $globals.dropFirst().map { _ in () }, $roots.dropFirst().map { _ in () })
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.recordUndo() } }.store(in: &bag)
        Node.changed.debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] in MainActor.assumeIsolated { if self?.visible != nil { self?.recompute(keepIndex: true) } } }.store(in: &bag)
        runner.$state.dropFirst().removeDuplicates().sink { [weak self] s in
            guard let self, s == .idle else { return }
            self.pruneHistory(reason: "after run")
            if self.runUsedData, self.runner.completed {                // the list of a finished run is used up: later runs start without it
                self.dataURL = nil; self.iterations = 1
                self.log("run", "Data file cleared after a successful run")
            }
            self.runUsedData = false
        }.store(in: &bag)
        pruneHistory(reason: "startup")
    }

    // MARK: Persistence
    func load() {
        roots = []; globals = []; selected = []; primary = nil
        let fm = FileManager.default
        try? fm.createDirectory(at: collectionsDir, withIntermediateDirectories: true)
        let files = (try? fm.contentsOfDirectory(atPath: collectionsDir.path))?.filter { $0.hasSuffix(".json") }.sorted() ?? []
        var converted = false
        for f in files {
            if let d = try? Data(contentsOf: collectionsDir.appendingPathComponent(f)), let j = JSON.parse(d) {
                let need = j["_postwoman"]?["authConverted"]?.flag != true   // older files: move auth into Headers once
                if need { converted = true }
                let n = Node(json: j, root: true, convert: need); n.file = f; roots.append(n)
            }
        }
        if let d = try? Data(contentsOf: globalsFile), let j = JSON.parse(d) {
            globals = (j["values"]?.list ?? []).map {
                Var(key: $0["key"]?.text ?? "", value: $0["value"]?.text ?? "", enabled: $0["enabled"]?.flag ?? true,
                    secret: $0["type"]?.text == "secret")
            }
        }
        expanded = Set(roots.map(\.id)); recompute()
        for r in roots { for q in r.requests() { q.savedItem = q.toJSON() }; savedSkeleton[r.id] = skeleton(r) }
        savedGlobals = globalsJSON().compactData()
        undoStack = []; redoStack = []; lastSnap = snapshot(); refreshKnownVars()
        log("storage", "Loaded \(roots.count) collection(s), \(globals.count) global(s) from \(folder.path)")
        if converted { log("storage", "Authorization converted to Headers for older collections (one-time migration)", .warn); saveAll() }
        if roots.contains(where: { $0.requests().contains { !$0.hadStoredID } }) {
            log("storage", "Gave history ids to requests of older collection files (one-time; the files stay valid Postman collections)")
            saveAll()
        }
    }

    func globalsJSON() -> JSON {
        .obj(["id": .str("globals"), "name": .str("Globals"), "_postman_variable_scope": .str("globals"),
              "values": .arr(globals.map { .obj(["key": .str($0.key), "value": .str($0.value), "enabled": .bool($0.enabled),
                                                "type": .str($0.secret ? "secret" : "default")]) })])
    }

    // MARK: Import / export
    func importCollections() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.json]; p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        for u in p.urls {
            guard let d = try? Data(contentsOf: u), let j = JSON.parse(d), j["info"] != nil else { error = L("Not a Postman collection: %@", u.lastPathComponent); continue }
            let n = Node(json: j, root: true, convert: true)
            for v in j["variable"]?.list ?? [] {          // all collection variables → Globals
                let k = v["key"]?.text ?? ""
                guard !k.isEmpty else { continue }
                let nv = Var(key: k, value: v["value"]?.text ?? "", enabled: !(v["disabled"]?.flag ?? false), secret: v["type"]?.text == "secret")
                if let i = globals.firstIndex(where: { $0.key == k }) { globals[i] = nv } else { globals.append(nv) }
            }
            roots.append(n); expanded.insert(n.id)
            log("import", "Imported \"\(n.name)\" from \(u.lastPathComponent): \(n.requests().count) request(s), \(j["variable"]?.list.count ?? 0) variable(s) → Globals")
        }
        saveAll()
    }

    func exportSelected() {
        guard let p = primary, let root = root(of: p) else { return }
        let sp = NSSavePanel(); sp.allowedContentTypes = [.json]
        sp.nameFieldStringValue = root.name + ".postman_collection.json"
        guard sp.runModal() == .OK, let u = sp.url else { return }
        do { try root.toJSON(variables: globals, bake: true).data().write(to: u); log("export", "Exported \"\(root.name)\" to \(u.path)") } catch { self.error = error.localizedDescription }
    }

    // MARK: Tree lookups
    func root(of n: Node) -> Node? { roots.first { $0.path(to: n) != nil } }
    func parent(of n: Node) -> Node? {
        func f(_ p: Node) -> Node? { for c in p.children ?? [] { if c === n { return p }; if let r = f(c) { return r } }; return nil }
        for r in roots { if let p = f(r) { return p } }; return nil
    }
    func requests(in ns: [Node]) -> [Node] {
        var seen = Set<UUID>(); return ns.flatMap { $0.requests() }.filter { seen.insert($0.id).inserted }
    }

    // MARK: Search + visible rows
    func recompute(keepIndex: Bool = false) {
        let q = queryTrimmed.lowercased(); let qs = Node.layoutVariants(q)
        let old = (keepIndex && matchIndex >= 0 && matchIndex < matches.count) ? matches[matchIndex] : nil
        matches = []; matchIDs = []; matchIndex = -1
        guard !q.isEmpty else { visible = nil; return }
        var v = Set<UUID>()
        // Shown: matches, their ancestors, and the whole contents of a folder whose NAME matches.
        func mark(_ n: Node, _ anc: Bool) -> Bool {
            let m = n.matches(qs, content: searchContent); let nameHit = qs.contains { n.name.lowercased().contains($0) }; var any = false
            if m { matches.append(n); matchIDs.insert(n.id) }
            for c in n.children ?? [] { if mark(c, anc || nameHit) { any = true } }
            if anc || m || any { v.insert(n.id); return true }
            return false
        }
        roots.forEach { _ = mark($0, false) }
        visible = v
        if let old, let i = matches.firstIndex(of: old) { matchIndex = i }
    }
    func jump(_ d: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = matchIndex < 0 ? (d > 0 ? 0 : matches.count - 1) : (matchIndex + d + matches.count) % matches.count
        let n = matches[matchIndex]
        selected = [n]; primary = n; scrollID = n.id; scrollTick += 1
    }
    /// Headers a request gets from its parent folders / collection (read-only in the request editor).
    func inherited(for n: Node) -> [InheritedHeader] {
        guard let r = root(of: n), let p = r.path(to: n) else { return [] }
        var out: [InheritedHeader] = []
        for a in p.dropLast() {
            for h in a.folderHeaders {
                out.removeAll { $0.h.key.caseInsensitiveCompare(h.key) == .orderedSame }
                if h.enabled { out.append(InheritedHeader(h: h, from: a.name)) }
            }
        }
        return out
    }
    func rename() {
        guard let n = primary else { return }
        let a = NSAlert(); a.messageText = L("Rename"); a.addButton(withTitle: L("OK")); a.addButton(withTitle: L("Cancel"))
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); f.stringValue = n.name; a.accessoryView = f
        a.window.initialFirstResponder = f
        if a.runModal() == .alertFirstButtonReturn, !f.stringValue.isEmpty { log("tree", "Renamed \"\(n.name)\" → \"\(f.stringValue)\""); n.name = f.stringValue; recompute() }
    }
    func duplicate() {
        guard let n = primary else { return }
        let c = n.copy()
        if n.isRoot, let i = roots.firstIndex(of: n) { roots.insert(c, at: i + 1); expanded.insert(c.id) }
        else if let p = parent(of: n), let i = p.children?.firstIndex(where: { $0 === n }) { p.children?.insert(c, at: i + 1) }
        else { return }
        selected = [c]; primary = c; objectWillChange.send(); recompute()
        log("tree", "Duplicated \"\(n.name)\"")
    }
    func rows() -> [(node: Node, depth: Int)] {
        var out: [(node: Node, depth: Int)] = []
        func walk(_ n: Node, _ d: Int) {
            if let v = visible, !v.contains(n.id) { return }
            out.append((n, d))
            if visible != nil || expanded.contains(n.id) { (n.children ?? []).forEach { walk($0, d + 1) } }
        }
        roots.forEach { walk($0, 0) }
        return out
    }
    func isOpen(_ n: Node) -> Bool { visible != nil || expanded.contains(n.id) }
    func toggle(_ n: Node) { if expanded.contains(n.id) { expanded.remove(n.id) } else { expanded.insert(n.id) } }

    // MARK: Selection
    func select(_ n: Node) { if !selected.contains(n) { selected = [n] }; primary = n }
    func click(_ n: Node, rows: [Node]) {
        let f = NSEvent.modifierFlags
        if f.contains(.command) { if selected.contains(n) { selected.remove(n) } else { selected.insert(n) }; primary = n }
        else if f.contains(.shift), let p = primary, let a = rows.firstIndex(of: p), let b = rows.firstIndex(of: n) {
            selected = Set(rows[min(a, b)...max(a, b)])
        } else { selected = [n]; primary = n; if tab != .request { tab = .request } }      // a plain click opens the item in the Request tab
        log("ui", "Selected \(selected.count) item(s), primary \"\(primary?.name ?? "-")\"", .debug)
    }

    // MARK: Keyboard navigation, clipboard, drag & drop
    func moveSelection(_ d: Int, extend: Bool, rows: [Node]) {
        guard !rows.isEmpty else { return }
        let cur = primary.flatMap { rows.firstIndex(of: $0) } ?? (d > 0 ? -1 : rows.count)
        let n = min(rows.count - 1, max(0, cur + d)); let t = rows[n]
        if extend, let p = primary, let a = rows.firstIndex(of: p) { selected = Set(rows[min(a, n)...max(a, n)]) }
        else { selected = [t]; primary = t }
        scrollID = t.id; scrollTick += 1
    }
    func collapseOrParent(rows: [Node]) {
        guard let n = primary else { return }
        if n.children != nil, isOpen(n), visible == nil { expanded.remove(n.id) }
        else if let p = parent(of: n) { selected = [p]; primary = p; scrollID = p.id; scrollTick += 1 }
    }
    func expandPrimary() { if let n = primary, n.children != nil { expanded.insert(n.id) } }
    func topLevel(_ ns: [Node]) -> [Node] { ns.filter { n in !ns.contains { $0 !== n && $0.path(to: n) != nil } } }

    func copySelected(cut: Bool) {
        let items = topLevel(Array(selected)).filter { !$0.isRoot }
        guard !items.isEmpty else { return }
        clipboard = items; clipboardCut = cut
        log("tree", (cut ? "Cut " : "Copied ") + items.map(\.name).joined(separator: ", "), .debug)
    }
    func paste() {
        if let s = NSPasteboard.general.string(forType: .string), s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("curl"), CurlImport.parse(s) != nil {
            _ = importCurl(s); return                                       // ⌘V with a curl command on the clipboard
        }
        guard !clipboard.isEmpty else { return }
        let target = primary ?? roots.first
        guard let target else { return }
        var moved: [Node] = []
        for n in clipboard {
            if clipboardCut {
                if n === target || n.path(to: target) != nil { continue }          // not into itself
                moved.append(n)
            } else {
                let c = n.copy(); c.name = n.name; moved.append(c)
            }
        }
        guard !moved.isEmpty else { return }
        if clipboardCut { for n in moved { roots.forEach { $0.remove(n) } } }
        insert(moved, near: target, pos: target.children != nil ? .inside : .after)
        if clipboardCut { clipboard = []; clipboardCut = false }
        selected = Set(moved); primary = moved.last
        scrollID = moved.first?.id; scrollTick += 1
        log("tree", "Pasted \(moved.count) item(s)")
    }
    /// Puts `nodes` before / after / inside `target`. Returns false when that place does not exist (e.g. a request next to a collection root).
    @discardableResult
    func insert(_ nodes: [Node], near target: Node, pos: DropPos) -> Bool {
        var p = pos
        if p == .inside && target.children == nil { p = .after }
        if p == .inside {
            target.children?.insert(contentsOf: nodes, at: 0); expanded.insert(target.id)
        } else {
            guard let par = parent(of: target), let i = par.children?.firstIndex(where: { $0 === target }) else { return false }
            par.children?.insert(contentsOf: nodes, at: p == .before ? i : i + 1)
        }
        objectWillChange.send(); recompute()
        return true
    }
    func beginDrag(_ n: Node) {
        if !selected.contains(n) { selected = [n]; primary = n }
        dragging = topLevel(Array(selected))
    }
    func drop(onto target: Node, pos: DropPos) {
        defer { dropHint = nil; dragging = [] }
        let moving = dragging
        guard !moving.isEmpty else { return }
        if moving.contains(where: { $0 === target || $0.path(to: target) != nil }) { return }      // not into itself
        if moving.contains(where: \.isRoot) {                                                     // collections only reorder among collections
            guard moving.allSatisfy(\.isRoot), target.isRoot, pos != .inside else { return }
            roots.removeAll { r in moving.contains { $0 === r } }
            guard let i = roots.firstIndex(of: target) else { return }
            roots.insert(contentsOf: moving, at: pos == .before ? i : i + 1)
        } else {
            if target.isRoot && pos != .inside { return }
            for n in moving { roots.forEach { $0.remove(n) } }
            if !insert(moving, near: target, pos: pos) { return }
        }
        objectWillChange.send(); recompute(); autosaveTick()
        log("tree", "Moved " + moving.map(\.name).joined(separator: ", ") + " → \"\(target.name)\" (\(pos))")
    }

    // MARK: Edit tree
    /// Where a new item goes: the selected folder (or the folder of the selected request), else the first collection (created when there is none).
    func container() -> Node {
        if let p = primary, let c = p.children != nil ? p : parent(of: p) { return c }
        if let r = roots.first { return r }
        let r = Node(name: "Collection", folder: true); r.isRoot = true
        roots.append(r); expanded.insert(r.id)
        return r
    }
    /// Creates a request from a pasted curl command. Returns an error text or nil.
    func importCurl(_ text: String) -> String? {
        guard let n = CurlImport.parse(text) else { return L("No curl command found") }
        let parent = container()
        n.neverSaved = true                                                      // not written to disk until saved explicitly
        parent.children?.insert(n, at: 0); expanded.insert(parent.id)
        selected = [n]; primary = n; tab = .request; n.uiTab = 1
        objectWillChange.send(); recompute(); scrollID = n.id; scrollTick += 1
        log("import", "Request \"\(n.name)\" created from a curl command (\(n.method) \(n.url))")
        return nil
    }
    func add(folder: Bool) {
        let parent = container()
        let n = Node(name: folder ? "New Folder" : "New Request", folder: folder)
        n.uiFocusURL = !folder; n.uiTab = 0
        tab = .request
        parent.children?.insert(n, at: 0); expanded.insert(parent.id)            // on top: visible at once in a long list
        selected = [n]; primary = n; objectWillChange.send(); recompute()
        scrollID = n.id; scrollTick += 1
        log("tree", "Created \(folder ? "folder" : "request") in \"\(parent.name)\"")
    }
    func deleteSelected() {
        if NSApp.keyWindow?.firstResponder is NSTextView { return }     // ⌘⌫ while typing must not delete items
        let items = Array(selected); guard !items.isEmpty else { return }
        let a = NSAlert(); a.messageText = L("Delete %ld item(s)?", items.count); a.informativeText = L("This cannot be undone.")
        a.addButton(withTitle: L("Delete")); a.addButton(withTitle: L("Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        log("tree", "Deleted: " + items.map(\.name).joined(separator: ", "), .warn)
        let doomed = items.flatMap { $0.requests().map(\.stableID) }        // their history goes with them
        for n in items {
            if n.isRoot { roots.removeAll { $0 === n }; if let f = n.file { try? FileManager.default.removeItem(at: collectionsDir.appendingPathComponent(f)) } }
            else { roots.forEach { $0.remove(n) } }
        }
        history.remove(doomed)
        selected = []; primary = nil; objectWillChange.send(); recompute(); autosaveTick()
    }

    /// Bulk edit: upsert headers, remove headers by key, optionally replace the body.
    func applyBulk(_ ts: [Node], set: [KV], remove: [String], body: String?, json: Bool) {
        log("bulk", "Applied to \(ts.count) request(s): set \(set.filter { !$0.key.isEmpty }.map(\.key)), remove \(remove), body \(body == nil ? "unchanged" : "replaced (\(json ? "JSON" : "text"))")")
        for n in ts {
            for h in set where !h.key.isEmpty {
                if let i = n.headers.firstIndex(where: { $0.key.caseInsensitiveCompare(h.key) == .orderedSame }) {
                    n.headers[i].value = h.value; n.headers[i].enabled = true
                } else { n.headers.append(KV(key: h.key, value: h.value)) }
            }
            n.headers.removeAll { h in remove.contains { $0.caseInsensitiveCompare(h.key) == .orderedSame } }
            if let b = body { n.body = b; n.bodyMode = "raw"; n.bodyIsJSON = json }
        }
    }

    // MARK: Run
    func run(force: Bool = false) {
        guard let n = primary, let root = root(of: n) else { return }
        if !force, n.children == nil, let problem = n.authProblem {                  // refuse and show where the problem is
            authAlert = n.id; n.uiTab = 1; tab = .request; NSSound.beep()
            log("run", "Not sent: \(problem)", .warn)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in if self?.authAlert == n.id { self?.authAlert = nil } }
            return
        }
        if tab == .request, let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isEditable, !tv.isFieldEditor { n.uiRefocus = true }   // back in the Request tab the text editor gets the cursor again
        autosaveTick()
        autoPickResult = n.children == nil
        // A single request started from the Request tab is just that request: the data list / iterations of the Runner tab are not applied to it.
        let single = tab == .request && n.children == nil
        let data = single ? nil : dataURL
        let iters = single ? 1 : iterations
        tab = .runner
        let rows = data.map { Runner.loadRows($0).count } ?? 0
        let count = iters == 0 ? max(1, rows) : iters
        if let why = EmbeddedRuntime.problem() { error = why; return }
        let col = Node.scoped(root: root, target: n)
        let secretCount = globals.filter { $0.enabled && $0.secret && !$0.value.isEmpty }.count
        log("run", "Run \"\(n.name)\" (\(n.children == nil ? "request" : n.isRoot ? "collection" : "folder"), \(col.dict["item"]?.list.count ?? 0) top-level item(s)); data: \(data?.lastPathComponent ?? "none"), \(globals.filter(\.enabled).count) global(s), \(secretCount) secret")
        guard runner.state == .idle, !preparingRun else { return }
        preparingRun = true
        // Secret variables: authenticate once per launch, decrypt in memory, hand them to node through a pipe (never a file).
        Task {
            defer { preparingRun = false }
            var secrets: [String: String] = [:]
            if secretCount > 0 {
                do { secrets = try await decryptedSecrets(reason: L("Unlock secret variables")) }
                catch { self.error = error.localizedDescription; log("vault", "Run not started: \(error.localizedDescription)", .error); return }
            }
            runUsedData = data != nil
            runner.start(collection: col, globals: globals, secrets: secrets, dataURL: data,
                         iterations: count, intervalMs: interval, timeoutSec: timeoutSec)
        }
    }

    // MARK: Variables written by scripts (pm.globals / pm.environment / pm.collectionVariables .set / .unset)
    /// Everything a script sets lands in Globals (one scope for the whole app). Secret values are sealed with the vault key; the log gets names only for them.
    func applyScriptVars(_ changes: [Runner.VarChange]) {
        var plain: [String] = [], removed: [String] = [], pending: [(key: String, value: String)] = []
        for c in changes {
            if c.remove {
                if let i = globals.firstIndex(where: { $0.key == c.key }) { globals.remove(at: i); removed.append(c.key) }
            } else if c.secret || globals.first(where: { $0.key == c.key })?.secret == true {
                pending.append((c.key, c.value))
            } else if let i = globals.firstIndex(where: { $0.key == c.key }) {
                globals[i].value = c.value; globals[i].enabled = true; plain.append(c.key)
            } else {
                globals.append(Var(key: c.key, value: c.value)); plain.append(c.key)
            }
        }
        var parts: [String] = []
        if !plain.isEmpty { parts.append("set: " + plain.joined(separator: ", ")) }
        if !removed.isEmpty { parts.append("removed: " + removed.joined(separator: ", ")) }
        if !pending.isEmpty { parts.append("secret (value hidden): " + pending.map(\.key).joined(separator: ", ")) }
        if !parts.isEmpty { log("vars", "Written to Globals by scripts — " + parts.joined(separator: "; ")) }
        guard !pending.isEmpty else { return }
        Task {
            do {
                let key = try await vault.unlock(reason: L("Unlock secret variables"))
                for p in pending {
                    guard let i = globals.firstIndex(where: { $0.key == p.key }) else { continue }
                    globals[i].value = p.value.isEmpty ? "" : try SecretBox.seal(p.value, with: key); globals[i].secret = true
                }
                log("vars", "Secret variable(s) saved encrypted: " + pending.map(\.key).joined(separator: ", "))
            } catch {
                log("vars", "Secret variable(s) changed by a script were NOT saved (\(error.localizedDescription)): " + pending.map(\.key).joined(separator: ", "), .error)
            }
        }
    }

    // MARK: Secret variables (see SecretVault.swift)
    private func index(of id: UUID) -> Int? { globals.firstIndex { $0.id == id } }

    /// Cancelling Touch ID is not an error worth an alert; everything else is shown.
    func vaultError(_ e: Error) {
        if case SecretVault.Failure.cancelled = e { log("vault", "Authentication cancelled", .info); return }
        log("vault", e.localizedDescription, .error)
        error = e.localizedDescription
    }

    /// name → plaintext for every enabled secret variable. Values that are still plaintext in the file are encrypted now.
    func decryptedSecrets(reason: String) async throws -> [String: String] {
        let key = try await vault.unlock(reason: reason)
        sealPending(with: key)
        var out: [String: String] = [:]
        for v in globals where v.enabled && v.secret && !v.value.isEmpty && !v.key.isEmpty {
            do { out[v.key] = try SecretBox.open(v.value, with: key) }
            catch { throw SecretError.variable(v.key, error.localizedDescription) }
        }
        return out
    }
    enum SecretError: LocalizedError {
        case variable(String, String)
        var errorDescription: String? { if case .variable(let k, let m) = self { return "\(k): \(m)" }; return nil }
    }

    /// Secret variables loaded from an older file or from a Postman import hold plaintext: encrypt them as soon as the key is available.
    private func sealPending(with key: SymmetricKey) {
        var n = 0
        for i in globals.indices where globals[i].secret && !globals[i].value.isEmpty && !SecretBox.isSealed(globals[i].value) {
            if let s = try? SecretBox.seal(globals[i].value, with: key) { globals[i].value = s; n += 1 }
        }
        if n > 0 { log("vault", "Encrypted \(n) secret variable(s) that were stored as plain text") }
    }

    /// Lock button on a normal variable: its value becomes encrypted.
    func makeSecret(_ id: UUID) async throws {
        let key = try await vault.unlock(reason: L("Unlock secret variables"))
        guard let i = index(of: id) else { return }
        if !globals[i].value.isEmpty { globals[i].value = try SecretBox.seal(globals[i].value, with: key) }
        globals[i].secret = true
        log("vault", "Variable \"\(globals[i].key)\" is now secret (stored encrypted)")
    }
    /// Plaintext of a secret. Always asks for authentication.
    func revealSecret(_ id: UUID) async throws -> String {
        guard let i0 = index(of: id) else { return "" }
        let sealed = globals[i0].value
        let key = try await vault.unlock(reason: L("Show a secret variable"), fresh: true)
        sealPending(with: key)
        guard !sealed.isEmpty else { return "" }
        if !SecretBox.isSealed(sealed) { return sealed }
        log("vault", "Secret \"\(globals[i0].key)\" revealed", .info)
        return try SecretBox.open(sealed, with: key)
    }
    /// A revealed secret was edited: encrypt the new value.
    func updateSecret(_ id: UUID, plain: String) async throws {
        let key = try await vault.unlock(reason: L("Unlock secret variables"))
        guard let i = index(of: id) else { return }
        globals[i].value = plain.isEmpty ? "" : try SecretBox.seal(plain, with: key)
    }
    /// Lock button on a secret variable: becomes a normal variable again (asks for authentication).
    func makePlain(_ id: UUID) async throws {
        let plain = try await revealSecret(id)
        guard let i = index(of: id) else { return }
        globals[i].value = plain; globals[i].secret = false
        log("vault", "Variable \"\(globals[i].key)\" is no longer secret", .warn)
    }
    // MARK: History retention (default: 6 months)
    var retentionCutoff: Date {
        let d = UserDefaults.standard
        let n = max(1, d.object(forKey: "historyRetentionValue") as? Int ?? 6)
        let unit: Calendar.Component = d.string(forKey: "historyRetentionUnit") == "days" ? .day : .month
        return Calendar.current.date(byAdding: unit, value: -n, to: Date()) ?? .distantPast
    }
    func pruneHistory(reason: String, force: Bool = false) {
        if !force && reason != "startup" && reason != "settings closed" && Date().timeIntervalSince(lastPruneAt) < 6 * 3600 { return }
        lastPruneAt = Date()
        let dir = history.directory, cutoff = retentionCutoff
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let r = HistoryStore.prune(dir: dir, cutoff: cutoff)
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self?.log("history", "Cleanup (\(reason)): kept \(r.kept) execution(s); removed \(r.removedEntries) older than \(cutoff.formatted(date: .abbreviated, time: .omitted)), \(r.removedFiles) file(s) emptied",
                          r.removedEntries > 0 ? .info : .debug)
            } }
        }
    }

    func pickData() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.json, .commaSeparatedText]
        if p.runModal() == .OK { dataURL = p.url; iterations = 0; log("run", "Data file: \(p.url?.path ?? "")") }
    }
}

import Foundation
import AppKit

// MARK: Saving policy, quit confirmation, undo / redo, known variables
//
// • Autosave ON  : every edit is written ~1 s later, except requests created from a curl command: they stay out of the files until saved explicitly.
// • Autosave OFF : nothing is written by itself. Each request keeps the version of its last save (`Node.savedItem`); ⌘S saves the selected
//                  request(s), ⌥⌘S everything. On quit every unsaved item is offered: Save / Discard / Save All / Discard All.
// • Undo / redo  : snapshots of all collections + globals, taken 0.5 s after an edit. Text fields and editors keep their own typing undo while focused.
@MainActor
extension Store {
    // MARK: Writing
    func skeleton(_ r: Node) -> Data { r.toJSON(saveFilter: { _ in .baseline }).compactData() }

    func autosaveTick() {
        if autosave { writeCollections() }
        refreshUnsaved(); refreshKnownVars()
    }
    /// ⌥⌘S: everything.
    func saveAll() { writeCollections(all: true); refreshUnsaved() }
    /// ⌘S: the selected requests (a folder or collection → all requests inside); nothing selected → everything.
    func saveSelected() {
        // a brand-new request still has the default name: ask for one first (cancel = nothing is saved)
        if selected.count == 1, let n = primary, n.children == nil, n.needsName, n.name == "New Request" {
            let a = NSAlert(); a.messageText = L("Rename"); a.addButton(withTitle: L("Save")); a.addButton(withTitle: L("Cancel"))
            let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); f.stringValue = n.name; a.accessoryView = f
            a.window.initialFirstResponder = f
            guard a.runModal() == .alertFirstButtonReturn else { return }
            let name = f.stringValue.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { log("tree", "Renamed \"\(n.name)\" → \"\(name)\""); n.name = name; recompute() }
        }
        if let n = primary { n.needsName = false }
        let ids = Set(requests(in: Array(selected)).map(\.id))
        if ids.isEmpty { saveAll() } else { writeCollections(explicit: ids, globalsToo: false); refreshUnsaved() }
    }

    func writeCollections(explicit: Set<UUID> = [], all: Bool = false, only: Set<UUID>? = nil, globalsToo: Bool? = nil) {
        let auto = autosave
        let filter: (Node) -> Node.SaveChoice = { n in
            if all || explicit.contains(n.id) { return .current }
            if n.neverSaved { return .baseline }
            return auto ? .current : .baseline
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: collectionsDir, withIntermediateDirectories: true)
        for r in roots {
            if let only, !only.contains(r.id) { continue }
            let want = r.name.replacingOccurrences(of: "/", with: "-") + ".postman_collection.json"
            if let old = r.file, old != want { try? fm.removeItem(at: collectionsDir.appendingPathComponent(old)) }
            r.file = want
            do { try r.toJSON(saveFilter: filter).data().write(to: collectionsDir.appendingPathComponent(want)) }
            catch { self.error = error.localizedDescription }
        }
        for r in roots where only == nil || only!.contains(r.id) {
            for q in r.requests() where filter(q) == .current { q.savedItem = q.toJSON(); q.neverSaved = false }
            savedSkeleton[r.id] = skeleton(r)
        }
        if globalsToo ?? (all || auto) {
            try? globalsJSON().data().write(to: globalsFile)
            savedGlobals = globalsJSON().compactData()
        }
        log("storage", "Saved collections (\(all ? "all" : explicit.isEmpty ? "autosave" : "\(explicit.count) request(s)"))", .debug)
    }

    func refreshUnsaved() {
        var s = Set<UUID>()
        let auto = autosave
        for r in roots { for q in r.requests() where auto ? q.neverSaved : q.isDirty() { s.insert(q.id) } }
        if s != unsavedIDs { unsavedIDs = s }
    }

    // MARK: Quit
    private enum Unit { case request(Node), root(Node), globals }

    /// Called when the app is about to quit. Returns false when quitting must not go on.
    func confirmQuit() -> Bool {
        if autosave { writeCollections() }
        var units: [Unit] = []
        for r in roots {
            for q in r.requests() where autosave ? q.neverSaved : q.isDirty() { units.append(.request(q)) }
            if !autosave && savedSkeleton[r.id] != skeleton(r) { units.append(.root(r)) }
        }
        if !autosave && savedGlobals != globalsJSON().compactData() { units.append(.globals) }
        if units.isEmpty { return true }

        var saveReq = Set<UUID>(), saveRoots = Set<UUID>(), saveGlobals = false
        var mode = 0                                                          // 0 ask, 1 save all, 2 discard all
        for u in units {
            var save = mode == 1
            if mode == 0 {
                let title: String
                switch u {
                case .request(let n): title = n.name
                case .root(let r): title = L("Collection “%@” (structure and folders)", r.name)
                case .globals: title = L("Globals")
                }
                let a = NSAlert()
                a.messageText = L("Save changes to “%@”?", title)
                a.informativeText = L("Your changes will be lost if you don’t save them.")
                a.addButton(withTitle: L("Save")); a.addButton(withTitle: L("Discard")); a.addButton(withTitle: L("Save All")); a.addButton(withTitle: L("Discard All"))
                switch a.runModal() {
                case .alertFirstButtonReturn: save = true
                case .alertSecondButtonReturn: save = false
                case .alertThirdButtonReturn: save = true; mode = 1
                default: save = false; mode = 2
                }
            }
            if save {
                switch u {
                case .request(let n): saveReq.insert(n.id)
                case .root(let r): saveRoots.insert(r.id)
                case .globals: saveGlobals = true
                }
            }
        }
        let rootsToWrite = Set(roots.filter { r in saveRoots.contains(r.id) || r.requests().contains { saveReq.contains($0.id) } }.map(\.id))
        writeCollections(explicit: saveReq, only: rootsToWrite, globalsToo: saveGlobals)
        return true
    }

    // MARK: Undo / redo
    func snapshot() -> Data {
        JSON.obj(["roots": .arr(roots.map { $0.toJSON() }), "globals": globalsJSON()]).compactData()
    }
    func recordUndo() {
        let now = snapshot()
        guard now != lastSnap else { return }
        undoStack.append(lastSnap); redoStack = []; lastSnap = now
        var total = undoStack.reduce(0) { $0 + $1.count }
        while undoStack.count > 100 || (total > 80_000_000 && undoStack.count > 1) { total -= undoStack.removeFirst().count }
    }
    func undo() {
        recordUndo()                                                            // edits of the last half second count too
        guard let d = undoStack.popLast() else { NSSound.beep(); return }
        redoStack.append(lastSnap); restore(d); log("undo", "Undo", .debug)
    }
    func redo() {
        guard let d = redoStack.popLast() else { NSSound.beep(); return }
        undoStack.append(lastSnap); restore(d); log("undo", "Redo", .debug)
    }

    private func indexPath(_ n: Node) -> [Int]? {
        func f(_ p: Node, _ path: [Int]) -> [Int]? {
            if p === n { return path }
            for (i, c) in (p.children ?? []).enumerated() { if let r = f(c, path + [i]) { return r } }
            return nil
        }
        for (i, r) in roots.enumerated() { if let p = f(r, [i]) { return p } }
        return nil
    }
    private func node(at path: [Int], in rs: [Node]) -> Node? {
        guard let f = path.first, f < rs.count else { return nil }
        var n = rs[f]
        for i in path.dropFirst() { guard let c = n.children, i < c.count else { return nil }; n = c[i] }
        return n
    }

    private func restore(_ d: Data) {
        guard let j = JSON.parse(d) else { return }
        let oldRoots = roots
        var oldReq: [String: Node] = [:]
        for r in oldRoots { for q in r.requests() { oldReq[q.stableID] = q } }
        let selPaths = selected.compactMap { indexPath($0) }
        let primaryPath = primary.flatMap { indexPath($0) }
        var openPaths: [[Int]] = []
        func collect(_ n: Node, _ p: [Int]) { if expanded.contains(n.id) { openPaths.append(p) }; for (i, c) in (n.children ?? []).enumerated() { collect(c, p + [i]) } }
        for (i, r) in oldRoots.enumerated() { collect(r, [i]) }

        let newRoots = (j["roots"]?.list ?? []).map { Node(json: $0, root: true, convert: false) }
        for (i, r) in newRoots.enumerated() {                                    // keep the file names, saved versions and open tabs
            let pid = r.extras["info"]?["_postman_id"]?.text
            let o = oldRoots.first { pid != nil && $0.extras["info"]?["_postman_id"]?.text == pid } ?? (oldRoots.count == newRoots.count ? oldRoots[i] : nil)
            r.file = o?.file
            for q in r.requests() {
                if let oq = oldReq[q.stableID] { q.savedItem = oq.savedItem; q.neverSaved = oq.neverSaved; q.uiTab = oq.uiTab; q.uiScriptTab = oq.uiScriptTab }
            }
        }
        globals = (j["globals"]?["values"]?.list ?? []).map {
            Var(key: $0["key"]?.text ?? "", value: $0["value"]?.text ?? "", enabled: $0["enabled"]?.flag ?? true, secret: $0["type"]?.text == "secret")
        }
        roots = newRoots
        expanded = Set(openPaths.compactMap { node(at: $0, in: newRoots)?.id })
        for r in newRoots { expanded.insert(r.id) }
        selected = Set(selPaths.compactMap { node(at: $0, in: newRoots) })
        primary = primaryPath.flatMap { node(at: $0, in: newRoots) } ?? selected.first
        if primary != nil && selected.isEmpty { selected = [primary!] }
        objectWillChange.send(); recompute()
        lastSnap = snapshot()
        autosaveTick()
    }

    // MARK: Variables known to the highlighter
    /// Globals plus every name a script sets (`pm.globals.set("x", …)`): other {{names}} are drawn as undefined.
    func refreshKnownVars() {
        var k = Set(globals.filter(\.enabled).map(\.key))
        if let re = try? NSRegularExpression(pattern: #"pm\.(?:globals|variables|environment|collectionVariables)\.set\(\s*["']([^"']+)["']"#) {
            for r in roots { for q in r.requests() {
                for src in [q.preScript, q.testScript] where src.contains(".set(") {
                    for m in re.matches(in: src, range: NSRange(location: 0, length: (src as NSString).length)) {
                        k.insert((src as NSString).substring(with: m.range(at: 1)))
                    }
                }
            } }
        }
        Highlighter.known = k
    }
}

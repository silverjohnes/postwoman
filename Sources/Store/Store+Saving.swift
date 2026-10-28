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
        saveOrder()
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

    /// What an undo / redo changed in one request: the editor tab to show and the text to select there.
    struct ChangeTarget { var tab: Int; var script = 0; var text: String?; var range = NSRange(location: 0, length: 0) }
    private func changedRange(_ old: String, _ new: String) -> NSRange {
        let a = Array(old.utf16), b = Array(new.utf16)
        var pre = 0
        while pre < a.count, pre < b.count, a[pre] == b[pre] { pre += 1 }
        var suf = 0
        while suf < a.count - pre, suf < b.count - pre, a[a.count - 1 - suf] == b[b.count - 1 - suf] { suf += 1 }
        return NSRange(location: pre, length: b.count - pre - suf)
    }
    private func diffRequest(old o: Node, new q: Node) -> ChangeTarget? {
        func text(_ tab: Int, _ script: Int = 0, _ a: String, _ b: String) -> ChangeTarget? {
            a == b ? nil : ChangeTarget(tab: tab, script: script, text: b.isEmpty ? nil : b, range: changedRange(a, b))
        }
        func rows(_ tab: Int, _ a: [KV], _ b: [KV]) -> ChangeTarget? {
            for i in 0..<max(a.count, b.count) {
                let x = i < a.count ? a[i] : nil, y = i < b.count ? b[i] : nil
                if let x, let y {
                    if x.key != y.key { return ChangeTarget(tab: tab, text: y.key.isEmpty ? nil : y.key, range: changedRange(x.key, y.key)) }
                    if x.value != y.value { return ChangeTarget(tab: tab, text: y.value.isEmpty ? nil : y.value, range: changedRange(x.value, y.value)) }
                    if x.enabled != y.enabled { return ChangeTarget(tab: tab) }
                } else { return ChangeTarget(tab: tab, text: y.map { $0.key.isEmpty ? $0.value : $0.key }, range: NSRange(location: 0, length: 0)) }
            }
            return nil
        }
        if let t = text(q.uiTab, 0, o.name, q.name) { return t }
        if o.method != q.method { return ChangeTarget(tab: q.uiTab) }
        if let t = text(q.uiTab, 0, o.url, q.url) { return t }
        if let t = rows(0, o.params, q.params) { return t }
        if let t = rows(1, o.headers, q.headers) { return t }
        if o.bodyMode != q.bodyMode || o.rawLang != q.rawLang || o.binaryPath != q.binaryPath || o.formData.count != q.formData.count { return ChangeTarget(tab: 2) }
        if let t = text(2, 0, o.body, q.body) { return t }
        if let t = rows(2, o.urlencoded, q.urlencoded) { return t }
        if let t = text(3, 0, o.preScript, q.preScript) { return t }
        if let t = text(3, 1, o.testScript, q.testScript) { return t }
        return o.toJSON() != q.toJSON() ? ChangeTarget(tab: q.uiTab) : nil
    }

    /// After undo / redo: open the request that changed, on the tab with the change, and select the changed text.
    private func showChange(from oldReq: [String: Node], in newRoots: [Node]) {
        var found: (Node, ChangeTarget)?
        search: for r in newRoots { for q in r.requests() {
            guard let o = oldReq[q.stableID], let t = diffRequest(old: o, new: q) else { continue }
            found = (q, t); break search
        } }
        guard let (q, t) = found else { return }
        q.uiTab = t.tab; q.uiScriptTab = t.script
        func openParents(_ n: Node, _ chain: [Node]) -> [Node]? {
            if n === q { return chain }
            for c in n.children ?? [] { if let r = openParents(c, chain + [n]) { return r } }
            return nil
        }
        for r in newRoots { if let ps = openParents(r, []) { ps.forEach { expanded.insert($0.id) }; break } }
        tab = .request; selected = [q]; primary = q
        objectWillChange.send(); recompute(); scrollID = q.id; scrollTick += 1
        guard let text = t.text else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { Self.selectText(text, range: t.range) }
    }
    /// Finds the field / editor that shows exactly `text` and selects the range in it.
    @MainActor private static func selectText(_ text: String, range: NSRange) {
        guard let win = NSApp.keyWindow, let root = win.contentView else { return }
        func visit(_ v: NSView) -> NSView? {
            if let tv = v as? NSTextView, !tv.isFieldEditor, tv.string == text { return tv }
            if let tf = v as? NSTextField, tf.isEditable, tf.stringValue == text { return tf }
            for c in v.subviews { if let r = visit(c) { return r } }
            return nil
        }
        guard let v = visit(root) else { return }
        let len = (text as NSString).length
        let r = NSRange(location: min(range.location, len), length: min(range.length, max(0, len - range.location)))
        if let tv = v as? NSTextView { win.makeFirstResponder(tv); tv.setSelectedRange(r); tv.scrollRangeToVisible(r) }
        else if let tf = v as? NSTextField { win.makeFirstResponder(tf); (tf.currentEditor() as? NSTextView)?.setSelectedRange(r) }
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
        autosaveTick(); saveOrder()
        showChange(from: oldReq, in: newRoots)
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

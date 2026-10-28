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
        var failed: String?
        do { try fm.createDirectory(at: collectionsDir, withIntermediateDirectories: true) } catch { failed = error.localizedDescription }
        for r in roots {
            if let only, !only.contains(r.id) { continue }
            let want = r.name.replacingOccurrences(of: "/", with: "-") + ".postman_collection.json"
            if let old = r.file, old != want { try? fm.removeItem(at: collectionsDir.appendingPathComponent(old)) }
            r.file = want
            do { try r.toJSON(saveFilter: filter).data().write(to: collectionsDir.appendingPathComponent(want)) }
            catch { self.error = error.localizedDescription; failed = error.localizedDescription }
        }
        for r in roots where only == nil || only!.contains(r.id) {
            for q in r.requests() where filter(q) == .current { q.savedItem = q.toJSON(); q.neverSaved = false }
            savedSkeleton[r.id] = skeleton(r)
        }
        if globalsToo ?? (all || auto) {
            do { try globalsJSON().data().write(to: globalsFile) } catch { failed = error.localizedDescription }
            savedGlobals = globalsJSON().compactData()
        }
        saveOrder()
        let mainProblem = failed.map { _ in L("Main storage folder is unavailable: %@", folder.path) }
        if mainProblem != primaryProblem {
            primaryProblem = mainProblem
            if let failed { log("storage", "Write to the main folder failed (\(folder.path)): \(failed)", .error) } else { log("storage", "Main folder is writable again", .info) }
        }
        scheduleMirror()
        log("storage", "Saved collections (\(all ? "all" : explicit.isEmpty ? "autosave" : "\(explicit.count) request(s)"))", .debug)
    }

    // MARK: Backup folder (second storage path)
    var storageProblems: [String] { [primaryProblem, backupProblem].compactMap { $0 } }

    /// Copies the changes of the main folder to the backup folder (after 1.5 s of quiet, or at once).
    func scheduleMirror(now: Bool = false) {
        guard StorageLocation.backupEnabled, StorageLocation.backupIsSet else { if backupProblem != nil { backupProblem = nil }; return }
        mirrorTask?.cancel()
        mirrorTask = Task { [weak self] in
            if !now { try? await Task.sleep(for: .seconds(1.5)) }
            guard !Task.isCancelled, let self else { return }
            await self.runMirror()
        }
    }
    private func runMirror() async {
        if mirrorRunning { mirrorAgain = true; return }
        mirrorRunning = true
        defer { mirrorRunning = false }
        repeat {
            mirrorAgain = false
            let src = folder
            guard StorageLocation.backupEnabled, StorageLocation.backupIsSet else { backupProblem = nil; return }
            guard let dst = StorageLocation.backup else {
                setBackupProblem(StorageLocation.backupPath, "the saved folder cannot be opened (deleted, moved or its disk is not connected)"); return
            }
            let out = await Task.detached(priority: .utility) { StorageMirror.sync(from: src, to: dst) }.value
            if let e = out.error { setBackupProblem(dst.path, e) }
            else {
                if backupProblem != nil { log("storage", "Backup folder is available again: \(dst.path)", .info) }
                backupProblem = nil
                if out.copied + out.removed > 0 { log("storage", "Backup: \(out.copied) file(s) written, \(out.removed) removed → \(dst.path)", .debug) }
            }
        } while mirrorAgain
    }
    private func setBackupProblem(_ path: String, _ why: String) {
        let msg = L("Backup folder is unavailable: %@", path)
        if backupProblem != msg { log("storage", "Backup folder is unavailable (\(path)): \(why)", .error) }
        backupProblem = msg
    }

    /// Settings ▸ "Check all paths": writes a probe file into every configured folder, updates the notification and re-syncs the backup.
    func checkStoragePaths() async -> [(label: String, path: String, problem: String?)] {
        var rows: [(label: String, path: String, problem: String?)] = []
        let main = folder
        let mainProblem = await Task.detached { StorageMirror.probe(main) }.value
        rows.append((L("Main folder"), main.path, mainProblem))
        primaryProblem = mainProblem == nil ? nil : L("Main storage folder is unavailable: %@", main.path)
        if StorageLocation.backupEnabled, StorageLocation.backupIsSet {
            if let b = StorageLocation.backup {
                let p = await Task.detached { StorageMirror.probe(b) }.value
                rows.append((L("Backup folder"), b.path, p))
                if p == nil { scheduleMirror(now: true) } else { setBackupProblem(b.path, p!) }
            } else {
                rows.append((L("Backup folder"), StorageLocation.backupPath, "cannot be opened"))
                setBackupProblem(StorageLocation.backupPath, "the saved folder cannot be opened")
            }
        }
        log("storage", "Paths checked: " + rows.map { "\($0.label) \($0.path) — " + ($0.problem ?? "OK") }.joined(separator: "; "), rows.contains { $0.problem != nil } ? .warn : .info)
        return rows
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
        recordScoped()
        var total = undoStack.reduce(0) { $0 + $1.count }
        while undoStack.count > 100 || (total > 80_000_000 && undoStack.count > 1) { total -= undoStack.removeFirst().count }
    }
    func undo() {
        recordUndo()                                                            // edits of the last half second count too
        guard let d = undoStack.popLast() else { NSSound.beep(); log("undo", "Undo (whole app): nothing to undo", .warn); return }
        redoStack.append(lastSnap); restore(d)
        log("undo", "Undo (whole app) done: \(undoStack.count) step(s) left to undo, \(redoStack.count) to redo", .info)
    }
    func redo() {
        guard let d = redoStack.popLast() else { NSSound.beep(); log("undo", "Redo (whole app): nothing to redo", .warn); return }
        undoStack.append(lastSnap); restore(d)
        log("undo", "Redo (whole app) done: \(undoStack.count) step(s) to undo, \(redoStack.count) left to redo", .info)
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
    struct ChangeTarget { var tab: Int; var script = 0; var text: String?; var range = NSRange(location: 0, length: 0); var field = ""; var from: String?; var to: String? }
    private func changedRange(_ old: String, _ new: String) -> NSRange {
        let a = Array(old.utf16), b = Array(new.utf16)
        var pre = 0
        while pre < a.count, pre < b.count, a[pre] == b[pre] { pre += 1 }
        var suf = 0
        while suf < a.count - pre, suf < b.count - pre, a[a.count - 1 - suf] == b[b.count - 1 - suf] { suf += 1 }
        return NSRange(location: pre, length: b.count - pre - suf)
    }
    private func diffRequest(old o: Node, new q: Node) -> ChangeTarget? {
        func text(_ f: String, _ tab: Int, _ script: Int = 0, _ a: String, _ b: String) -> ChangeTarget? {
            a == b ? nil : ChangeTarget(tab: tab, script: script, text: b.isEmpty ? nil : b, range: changedRange(a, b), field: f, from: Self.fragment(a, b).0, to: Self.fragment(a, b).1)
        }
        func rows(_ f: String, _ tab: Int, _ a: [KV], _ b: [KV]) -> ChangeTarget? {
            for i in 0..<max(a.count, b.count) {
                let x = i < a.count ? a[i] : nil, y = i < b.count ? b[i] : nil
                if let x, let y {
                    if x.key != y.key { return ChangeTarget(tab: tab, text: y.key.isEmpty ? nil : y.key, range: changedRange(x.key, y.key), field: "\(f) #\(i + 1) key", from: x.key, to: y.key) }
                    if x.value != y.value { return ChangeTarget(tab: tab, text: y.value.isEmpty ? nil : y.value, range: changedRange(x.value, y.value), field: "\(f) #\(i + 1) value", from: Self.hideIfSensitive(x.value, key: x.key), to: Self.hideIfSensitive(y.value, key: y.key)) }
                    if x.enabled != y.enabled { return ChangeTarget(tab: tab, field: "\(f) #\(i + 1) on/off", from: x.enabled ? "on" : "off", to: y.enabled ? "on" : "off") }
                } else { return ChangeTarget(tab: tab, text: y.map { $0.key.isEmpty ? $0.value : $0.key }, range: NSRange(location: 0, length: 0), field: "\(f) #\(i + 1) " + (y == nil ? "removed" : "added"), from: x.map { Self.hideIfSensitive("\($0.key): \($0.value)", key: $0.key) }, to: y.map { Self.hideIfSensitive("\($0.key): \($0.value)", key: $0.key) }) }
            }
            return nil
        }
        if let t = text("name", q.uiTab, 0, o.name, q.name) { return t }
        if o.method != q.method { return ChangeTarget(tab: q.uiTab, field: "method", from: o.method, to: q.method) }
        if let t = text("URL", q.uiTab, 0, o.url, q.url) { return t }
        if let t = rows("param", 0, o.params, q.params) { return t }
        if let t = rows("header", 1, o.headers, q.headers) { return t }
        if o.bodyMode != q.bodyMode || o.rawLang != q.rawLang || o.binaryPath != q.binaryPath || o.formData.count != q.formData.count { return ChangeTarget(tab: 2, field: "body type / form-data") }
        if let t = text("body", 2, 0, o.body, q.body) { return t }
        if let t = rows("urlencoded", 2, o.urlencoded, q.urlencoded) { return t }
        if let t = text("PreScript", 3, 0, o.preScript, q.preScript) { return t }
        if let t = text("PostScript", 3, 1, o.testScript, q.testScript) { return t }
        return o.toJSON() != q.toJSON() ? ChangeTarget(tab: q.uiTab, field: "other settings") : nil
    }
    /// A line for the log: what changed in which request. Never the values themselves (they may be sensitive), only where and how much.
    private func describe(_ t: ChangeTarget, in q: Node) -> String {
        let tabs = ["Params", "Headers", "Body", "Scripts", "History"]
        let where_ = tabs.indices.contains(t.tab) ? tabs[t.tab] : "?"
        let sel = t.text != nil ? ", selected \(t.range.length) character(s) at \(t.range.location)" : ""
        var s = "request \"\(q.name)\": \(t.field) (tab \(where_))\(sel)"
        if t.from != nil || t.to != nil { s += ": " + Self.clip(t.from) + " → " + Self.clip(t.to) }
        return s
    }
    /// Whole values when they are short, otherwise only the part that differs (marked with …).
    static func fragment(_ a: String, _ b: String) -> (String, String) {
        if a.count <= 200 && b.count <= 200 { return (a, b) }
        let x = Array(a), y = Array(b)
        var pre = 0
        while pre < x.count, pre < y.count, x[pre] == y[pre] { pre += 1 }
        var suf = 0
        while suf < x.count - pre, suf < y.count - pre, x[x.count - 1 - suf] == y[y.count - 1 - suf] { suf += 1 }
        let lead = pre > 0 ? "…" : "", tail = suf > 0 ? "…" : ""
        return (lead + String(x[pre..<(x.count - suf)]) + tail, lead + String(y[pre..<(y.count - suf)]) + tail)
    }
    /// A value for the log: one line, at most 200 characters.
    static func clip(_ v: String?) -> String {
        guard let v else { return "∅" }
        let one = v.replacingOccurrences(of: "\r\n", with: "⏎").replacingOccurrences(of: "\n", with: "⏎")
        return "\"" + (one.count > 200 ? String(one.prefix(200)) + "…(+\(one.count - 200))" : one) + "\""
    }
    /// Credentials sent in these headers are not copied into the log.
    static func hideIfSensitive(_ value: String, key: String) -> String {
        let k = key.lowercased()
        return ["authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key", "api-key"].contains(k) ? "‹hidden›" : value
    }

    /// After undo / redo: open the request that changed, on the tab with the change, and select the changed text.
    private func showChange(from oldReq: [String: Node], in newRoots: [Node]) {
        var found: (Node, ChangeTarget)?
        search: for r in newRoots { for q in r.requests() {
            guard let o = oldReq[q.stableID], let t = diffRequest(old: o, new: q) else { continue }
            found = (q, t); break search
        } }
        guard let (q, t) = found else { return }
        reveal(q, t)
    }
    /// Opens request `q` on the tab of the change and selects the changed text.
    private func reveal(_ q: Node, _ t: ChangeTarget) {
        guard let root = roots.first(where: { $0.path(to: q) != nil }) else { return }
        q.uiTab = t.tab; q.uiScriptTab = t.script
        log("undo", "Changed → " + describe(t, in: q), .info)
        func openParents(_ n: Node, _ chain: [Node]) -> [Node]? {
            if n === q { return chain }
            for c in n.children ?? [] { if let r = openParents(c, chain + [n]) { return r } }
            return nil
        }
        if let ps = openParents(root, []) { ps.forEach { expanded.insert($0.id) } }
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

    /// Globals changed by an undo / redo: names only, never values.
    private func logGlobalsChange(from old: [Var]) {
        let o = Dictionary(old.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a }), n = Dictionary(globals.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let added = n.keys.filter { o[$0] == nil }.sorted(), removed = o.keys.filter { n[$0] == nil }.sorted()
        let changed = n.keys.filter { k in o[k].map { $0.value != n[k]!.value || $0.enabled != n[k]!.enabled || $0.secret != n[k]!.secret } ?? false }.sorted()
        func val(_ v: Var) -> String { v.secret ? "‹secret, value hidden›" : Self.clip(v.value) }
        var parts: [String] = []
        if !added.isEmpty { parts.append("restored: " + added.map { "\($0) = " + val(n[$0]!) }.joined(separator: ", ")) }
        if !removed.isEmpty { parts.append("removed: " + removed.map { "\($0) (was " + val(o[$0]!) + ")" }.joined(separator: ", ")) }
        if !changed.isEmpty {
            parts.append("changed: " + changed.map { k in
                let a = o[k]!, b = n[k]!
                var d: [String] = []
                if a.value != b.value || a.secret != b.secret { d.append(val(a) + " → " + val(b)) }
                if a.enabled != b.enabled { d.append(a.enabled ? "enabled → disabled" : "disabled → enabled") }
                return k + ": " + d.joined(separator: ", ")
            }.joined(separator: "; "))
        }
        if !parts.isEmpty { log("undo", "Globals → " + parts.joined(separator: "; "), .info) }
    }

    // MARK: Scoped undo (⌘Z / ⇧⌘Z)
    func reqMap() -> [String: Data] {
        var m: [String: Data] = [:]
        for r in roots { for q in r.requests() { m[q.stableID] = q.toJSON().compactData() } }
        return m
    }
    private func snode(_ n: Node) -> SNode { SNode(ref: n, name: n.name, kids: n.children?.map { snode($0) }) }
    func structSnap() -> [SNode] { roots.map { snode($0) } }
    func resetScoped() { lastReq = reqMap(); lastStruct = structSnap(); structUndo = []; structRedo = [] }
    /// Called with every whole-app snapshot: what changed in each request / in the tree goes on its own stack.
    func recordScoped() {
        let m = reqMap()
        for (id, d) in m { if let o = lastReq[id], o != d {
            reqUndo[id, default: []].append(o); if reqUndo[id]!.count > 100 { reqUndo[id]!.removeFirst() }
            reqRedo[id] = []
        } }
        lastReq = m
        let s = structSnap()
        if s != lastStruct {
            structUndo.append(lastStruct); if structUndo.count > 100 { structUndo.removeFirst() }
            structRedo = []; lastStruct = s
        }
    }
    /// Which part of the window has the keyboard focus: the request list (left) or everything else (the editor).
    func focusedPane() -> Pane {
        guard let win = NSApp.keyWindow, let fr = win.firstResponder as? NSView, let content = win.contentView else { return .sidebar }
        func split(_ v: NSView) -> NSSplitView? {
            if let s = v as? NSSplitView { return s }
            for c in v.subviews { if let r = split(c) { return r } }
            return nil
        }
        if let sv = split(content), let side = sv.arrangedSubviews.first { return fr.isDescendant(of: side) ? .sidebar : .editor }
        return .sidebar
    }

    /// Undo / redo inside the open request only.
    func undoRequest(redo: Bool) {
        recordUndo()
        guard let q = primary, q.children == nil else { NSSound.beep(); log("undo", (redo ? "Redo" : "Undo") + " in the request editor: no request is open", .warn); return }
        let id = q.stableID
        guard var st = redo ? reqRedo[id] : reqUndo[id], let d = st.popLast(), let j = JSON.parse(d) else {
            NSSound.beep(); log("undo", (redo ? "Redo" : "Undo") + " in request \"\(q.name)\": nothing to " + (redo ? "redo" : "undo"), .warn); return
        }
        if redo { reqRedo[id] = st } else { reqUndo[id] = st }
        let cur = q.toJSON()
        if redo { reqUndo[id, default: []].append(cur.compactData()) } else { reqRedo[id, default: []].append(cur.compactData()) }
        let before = Node(json: cur, convert: false)
        q.assign(from: Node(json: j, convert: false))
        lastReq = reqMap()
        refreshUnsaved(); refreshKnownVars()
        log("undo", (redo ? "Redo" : "Undo") + " in request \"\(q.name)\" done: \(reqUndo[id]?.count ?? 0) step(s) to undo, \(reqRedo[id]?.count ?? 0) to redo", .info)
        if let t = diffRequest(old: before, new: q) { reveal(q, t) }
    }

    /// What differs between two states of the tree: added / removed / renamed / moved items (by name).
    private func describeStruct(from a: [SNode], to b: [SNode]) -> String {
        struct Info { let name: String; let parent: ObjectIdentifier?; let index: Int }
        func flat(_ l: [SNode], _ parent: ObjectIdentifier?, _ out: inout [ObjectIdentifier: Info]) {
            for (i, s) in l.enumerated() {
                let id = ObjectIdentifier(s.ref); out[id] = Info(name: s.name, parent: parent, index: i)
                if let k = s.kids { flat(k, id, &out) }
            }
        }
        var x: [ObjectIdentifier: Info] = [:], y: [ObjectIdentifier: Info] = [:]
        flat(a, nil, &x); flat(b, nil, &y)
        var parts: [String] = []
        let added = y.filter { x[$0.key] == nil }.map { $0.value.name }.sorted(), removed = x.filter { y[$0.key] == nil }.map { $0.value.name }.sorted()
        if !added.isEmpty { parts.append("restored: " + added.joined(separator: ", ")) }
        if !removed.isEmpty { parts.append("removed: " + removed.joined(separator: ", ")) }
        let renamed = y.compactMap { k, v in x[k].flatMap { $0.name != v.name ? "\"\($0.name)\" → \"\(v.name)\"" : nil } }.sorted()
        if !renamed.isEmpty { parts.append("renamed: " + renamed.joined(separator: ", ")) }
        let moved = y.compactMap { k, v in x[k].flatMap { ($0.parent != v.parent || $0.index != v.index) && $0.name == v.name ? v.name : nil } }.sorted()
        if !moved.isEmpty { parts.append("moved: " + moved.prefix(10).joined(separator: ", ") + (moved.count > 10 ? " …(+\(moved.count - 10))" : "")) }
        return parts.isEmpty ? "no visible change" : parts.joined(separator: "; ")
    }

    /// Undo / redo of the structure of the list: create, delete, move, rename of requests and folders. Request contents are not touched.
    func undoStructure(redo: Bool) {
        recordUndo()
        guard let target = redo ? structRedo.popLast() : structUndo.popLast() else {
            NSSound.beep(); log("undo", (redo ? "Redo" : "Undo") + " in the request list: nothing to " + (redo ? "redo" : "undo"), .warn); return
        }
        let summary = describeStruct(from: lastStruct, to: target)
        if redo { structUndo.append(lastStruct) } else { structRedo.append(lastStruct) }
        func apply(_ s: SNode) {
            s.ref.name = s.name
            if let k = s.kids { k.forEach(apply); s.ref.children = k.map(\.ref) }
        }
        target.forEach(apply)
        roots = target.map(\.ref)
        selected = selected.filter { n in roots.contains { $0 === n || $0.path(to: n) != nil } }
        if let p = primary, !selected.contains(p) { primary = selected.first }
        lastStruct = structSnap(); lastReq = reqMap()
        log("undo", (redo ? "Redo" : "Undo") + " in the request list done: " + summary + " (\(structUndo.count) step(s) to undo, \(structRedo.count) to redo)", .info)
        objectWillChange.send(); recompute(); autosaveTick(); saveOrder()
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
        // log what the whole-app step changes: request names only (never contents)
        var newReq: [String: Node] = [:]
        for r in newRoots { for q in r.requests() { newReq[q.stableID] = q } }
        func names(_ l: [String]) -> String { l.prefix(10).joined(separator: ", ") + (l.count > 10 ? " …(+\(l.count - 10))" : "") }
        let addedReq = newReq.filter { oldReq[$0.key] == nil }.map { "\"\($0.value.name)\"" }.sorted()
        let removedReq = oldReq.filter { newReq[$0.key] == nil }.map { "\"\($0.value.name)\"" }.sorted()
        let changedReq = newReq.compactMap { k, q in oldReq[k].flatMap { $0.toJSON().compactData() != q.toJSON().compactData() ? "\"\(q.name)\"" : nil } }.sorted()
        var reqParts: [String] = []
        if !changedReq.isEmpty { reqParts.append("changed: " + names(changedReq)) }
        if !addedReq.isEmpty { reqParts.append("restored: " + names(addedReq)) }
        if !removedReq.isEmpty { reqParts.append("removed: " + names(removedReq)) }
        if !reqParts.isEmpty { log("undo", "Requests → " + reqParts.joined(separator: "; "), .info) }
        for (k, q) in newReq.sorted(by: { $0.value.name < $1.value.name }).prefix(10) {
            if let o = oldReq[k], let t = diffRequest(old: o, new: q) { log("undo", "  " + describe(t, in: q), .info) }
        }
        let oldGlobals = globals
        defer { logGlobalsChange(from: oldGlobals) }
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
        lastSnap = snapshot(); resetScoped()
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

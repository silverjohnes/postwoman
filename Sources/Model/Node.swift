import Foundation
import Combine

/// Tree node: collection root, folder (children != nil) or request.
final class Node: ObservableObject, Identifiable, Hashable {
    let id = UUID()
    @Published var name: String
    @Published var children: [Node]?
    @Published var method = "GET"
    private var syncing = false
    /// Full URL; editing it re-parses the query into `params`.
    @Published var url = "" {
        didSet { if !syncing && url != oldValue { syncing = true; params = Node.parseQuery(url, keeping: params); syncing = false } }
    }
    /// Query parameters; editing them rewrites the query part of `url`. Disabled ones live only here.
    @Published var params: [KV] = [] {
        didSet { if !syncing { syncing = true; url = Node.applyQuery(url, params); syncing = false } }
    }
    @Published var headers: [KV] = []
    @Published var folderHeaders: [KV] = []      // folders/collections: inherited by every nested request
    @Published var body = ""
    /// Body type, as in Postman: none · formdata · urlencoded · raw · binary (anything else, e.g. graphql, is kept as imported).
    @Published var bodyMode = "none"
    /// Language of a raw body: text · json · javascript · html · xml
    @Published var rawLang = "json"
    @Published var formData: [FormRow] = []
    @Published var urlencoded: [KV] = []
    @Published var binaryPath = ""
    var bodyIsJSON: Bool {
        get { rawLang == "json" }
        set { rawLang = newValue ? "json" : "text" }
    }
    /// Request scripts (Postman `event` → prerequest / test). Edited in the Pre-request / Post-response tabs, run by newman as they are.
    @Published var preScript = ""
    @Published var testScript = ""
    private var eventKeep: [JSON] = []                       // all other events: kept untouched
    private var eventMeta: [String: [String: JSON]] = [:]    // listen → event keys except listen/script (id…)
    private var scriptMeta: [String: [String: JSON]] = [:]   // listen → script keys except exec (id, type, packages…)
    static let changed = PassthroughSubject<Void, Never>()   // fires on any node edit → autosave
    private var bag: AnyCancellable?
    var isRoot = false
    // what the request editor showed last (not saved): returning to the Request tab restores it
    var uiTab = 1, uiScriptTab = 0
    var uiRefocus = false
    var uiFocusURL = false
    enum SaveChoice { case current, baseline }
    /// JSON of this request as last written to disk; nil = never written. `neverSaved`: created by a curl import, stays out of the
    /// files until it is saved explicitly (even with autosave on).
    var savedItem: JSON?
    var neverSaved = false
    func isDirty() -> Bool { children == nil && (neverSaved || savedItem != toJSON()) }
    /// System headers the user switched off (Postman: protocolProfileBehavior.disabledSystemHeaders). Lower-case names.
    @Published var disabledAuto: Set<String> = []
    var file: String?                 // file name inside storage folder (roots only)
    var extras: [String: JSON] = [:]  // untouched Postman keys (event, auth, info…)
    var requestExtras: [String: JSON] = [:]
    /// Persistent id of a request: kept in the collection file as `_postwoman_id` (never exported); history files are named after it.
    var stableID = UUID().uuidString.lowercased()
    var hadStoredID = true            // false → generated on load, the collection file must be saved once

    static func == (a: Node, b: Node) -> Bool { a === b }
    func hash(into h: inout Hasher) { h.combine(id) }

    init(name: String, folder: Bool) {
        self.name = name; if folder { children = [] }
        bag = objectWillChange.sink { Node.changed.send() }
    }

    // MARK: Scripts ⇄ Postman `event`
    private func loadScripts() {
        guard let evs = extras.removeValue(forKey: "event") else { return }
        var seen = Set<String>()
        for e in evs.list {
            guard let listen = e["listen"]?.text, listen == "prerequest" || listen == "test", !seen.contains(listen) else { eventKeep.append(e); continue }
            seen.insert(listen)
            var text = ""
            if let ex = e["script"]?["exec"] {
                if let s = ex.text { text = s } else { text = ex.list.compactMap { $0.text }.joined(separator: "\n") }
            }
            if listen == "prerequest" { preScript = text } else { testScript = text }
            eventMeta[listen] = e.dict.filter { $0.key != "listen" && $0.key != "script" }
            scriptMeta[listen] = (e["script"]?.dict ?? [:]).filter { $0.key != "exec" }
        }
    }
    private func scriptEvents() -> JSON? {
        var ev = eventKeep
        for (listen, text) in [("prerequest", preScript), ("test", testScript)] where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var o = eventMeta[listen] ?? [:]
            var sc = scriptMeta[listen] ?? [:]
            if sc["type"] == nil { sc["type"] = .str("text/javascript") }
            sc["exec"] = .arr(text.components(separatedBy: "\n").map { .str($0) })
            o["listen"] = .str(listen); o["script"] = .obj(sc)
            ev.append(.obj(o))
        }
        return ev.isEmpty ? nil : .arr(ev)
    }

    // MARK: URL ⇄ params
    static func parseQuery(_ url: String, keeping old: [KV] = []) -> [KV] {
        var s = url
        if let h = s.firstIndex(of: "#") { s = String(s[..<h]) }
        var pairs: [(String, String)] = []
        if let q = s.firstIndex(of: "?") {
            for seg in s[s.index(after: q)...].split(separator: "&", omittingEmptySubsequences: true) {
                let p = seg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                pairs.append((String(p[0]), p.count > 1 ? String(p[1]) : ""))
            }
        }
        var out: [KV] = []; var it = pairs.makeIterator()
        for o in old {                                   // keep row identity (focus) and disabled rows
            if !o.enabled { out.append(o) }
            else if let p = it.next() { out.append(KV(id: o.id, key: p.0, value: p.1, enabled: true)) }
        }
        while let p = it.next() { out.append(KV(key: p.0, value: p.1)) }
        return out
    }
    static func applyQuery(_ url: String, _ params: [KV]) -> String {
        var rest = url, frag = ""
        if let h = rest.firstIndex(of: "#") { frag = String(rest[h...]); rest = String(rest[..<h]) }
        let base = rest.firstIndex(of: "?").map { String(rest[..<$0]) } ?? rest
        let q = params.filter { $0.enabled && !($0.key.isEmpty && $0.value.isEmpty) }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return base + (q.isEmpty ? "" : "?" + q) + frag
    }

    static func bodyKeeping(_ b: JSON?, dropping: Set<String>) -> JSON {
        .obj((b?.dict ?? [:]).filter { !dropping.contains($0.key) })
    }
    static func kv(_ j: JSON) -> KV { KV(key: j["key"]?.text ?? "", value: j["value"]?.text ?? "", enabled: !(j["disabled"]?.flag ?? false)) }
    static func hdrJSON(_ hs: [KV]) -> JSON {
        .arr(hs.map { var h: [String: JSON] = ["key": .str($0.key), "value": .str($0.value)]; if !$0.enabled { h["disabled"] = .bool(true) }; return .obj(h) })
    }
    /// request/folder's own headers override inherited ones with the same name
    static func merge(_ parent: [KV], _ own: [KV]) -> [KV] {
        let keys = Set(own.map { $0.key.lowercased() })
        return parent.filter { $0.enabled && !keys.contains($0.key.lowercased()) } + own
    }

    /// Postman auth (bearer / basic / apikey-in-header) → an ordinary header, so it is visible, editable and what actually runs.
    static func authHeader(_ a: JSON) -> KV? {
        func p(_ t: String, _ k: String) -> String? {
            guard let v = a[t] else { return nil }
            if case .obj(let o) = v { return o[k]?.text }
            return v.list.first { $0["key"]?.text == k }?["value"]?.text
        }
        switch a["type"]?.text {
        case "bearer":
            guard let t = p("bearer", "token"), !t.isEmpty else { return nil }
            return KV(key: "Authorization", value: "Bearer \(t)")
        case "basic":
            guard let u = p("basic", "username"), let pw = p("basic", "password"), !u.contains("{{"), !pw.contains("{{") else { return nil }
            return KV(key: "Authorization", value: "Basic " + Data("\(u):\(pw)".utf8).base64EncodedString())
        case "apikey":
            guard (p("apikey", "in") ?? "header") == "header", let k = p("apikey", "key"), !k.isEmpty else { return nil }
            return KV(key: k, value: p("apikey", "value") ?? "")
        default: return nil
        }
    }

    private static func authParam(_ a: JSON, _ t: String, _ k: String) -> String? {
        guard let v = a[t] else { return nil }
        if case .obj(let o) = v { return o[k]?.text }
        return v.list.first { $0["key"]?.text == k }?["value"]?.text
    }
    /// Import: as much of the Authorization tab as possible becomes a visible header (even an empty token, which is then flagged).
    static func importHeader(_ a: JSON) -> KV? {
        func p(_ t: String, _ k: String) -> String? { authParam(a, t, k) }
        switch a["type"]?.text {
        case "bearer": return KV(key: "Authorization", value: "Bearer \(p("bearer", "token") ?? "")")
        case "basic":
            let u = p("basic", "username") ?? "", pw = p("basic", "password") ?? ""
            // With variables the base64 cannot be computed now: the header shows readable credentials ("Basic user:{{password}}") and the
            // runner encodes them when the request is sent (see runner.js); export turns them back into an Authorization tab.
            if u.contains("{{") || pw.contains("{{") { return KV(key: "Authorization", value: "Basic \(u):\(pw)") }
            if u.isEmpty && pw.isEmpty { return KV(key: "Authorization", value: "Basic ") }
            return KV(key: "Authorization", value: "Basic " + Data("\(u):\(pw)".utf8).base64EncodedString())
        case "apikey":
            guard (p("apikey", "in") ?? "header") == "header", let k = p("apikey", "key"), !k.isEmpty else { return nil }
            return KV(key: k, value: p("apikey", "value") ?? "")
        case "oauth2":
            guard let t = p("oauth2", "accessToken"), !t.isEmpty, (p("oauth2", "addTokenTo") ?? "header") == "header" else { return nil }
            let prefix = p("oauth2", "headerPrefix") ?? "Bearer"
            return KV(key: "Authorization", value: (prefix.isEmpty ? "" : prefix + " ") + t)
        default: return nil
        }
    }
    /// "Basic user:password" with readable credentials (real base64 never contains ':') → (user, password).
    static func plainBasic(_ h: KV) -> (user: String, password: String)? {
        guard h.key.caseInsensitiveCompare("Authorization") == .orderedSame else { return nil }
        let v = h.value.trimmingCharacters(in: .whitespaces)
        guard v.lowercased().hasPrefix("basic ") else { return nil }
        let c = v.dropFirst(6).trimmingCharacters(in: .whitespaces)
        guard let i = c.firstIndex(of: ":") else { return nil }
        return (String(c[..<i]), String(c[c.index(after: i)...]))
    }
    static func importQuery(_ a: JSON) -> KV? {
        guard a["type"]?.text == "apikey", authParam(a, "apikey", "in") == "query", let k = authParam(a, "apikey", "key"), !k.isEmpty else { return nil }
        return KV(key: k, value: authParam(a, "apikey", "value") ?? "")
    }

    /// Parse a Postman item (v2.x). root=true for the whole collection object. convert=true turns auth into headers.
    init(json j: JSON, root: Bool = false, convert: Bool = false, parentAuth: JSON? = nil) {
        isRoot = root
        name = root ? (j["info"]?["name"]?.text ?? "Collection") : (j["name"]?.text ?? "Untitled")
        var skip: Set<String> = ["name", "item", "request", "response"]
        if root { skip = ["item", "variable"] }
        extras = j.dict.filter { !skip.contains($0.key) }
        if let fh = extras.removeValue(forKey: "_postwoman_headers") { folderHeaders = fh.list.map(Node.kv) }
        if let d = extras["protocolProfileBehavior"]?["disabledSystemHeaders"]?.dict {
            disabledAuto = Set(d.filter { $0.value.flag == true }.keys.map { $0.lowercased() })
        }
        if let sid = extras.removeValue(forKey: "_postwoman_id")?.text, !sid.isEmpty { stableID = sid }
        else if !root && j["item"] == nil { hadStoredID = false }
        let auth = extras["auth"] ?? parentAuth
        if root && convert { extras["_postwoman"] = .obj(["authConverted": .bool(true)]) }
        if let items = j["item"] {
            children = items.list.map { Node(json: $0, convert: convert, parentAuth: auth) }
        } else if var r = j["request"] {
            if case .str(let s) = r { r = .obj(["method": .str("GET"), "url": .str(s)]) }
            method = r["method"]?.text ?? "GET"
            url = r["url"]?.text ?? r["url"]?["raw"]?.text ?? ""
            headers = (r["header"]?.list ?? []).map(Node.kv)
            let bj = r["body"]
            body = bj?["raw"]?.text ?? ""
            rawLang = bj?["options"]?["raw"]?["language"]?.text ?? "json"
            switch bj?["mode"]?.text {
            case nil: bodyMode = body.isEmpty ? "none" : "raw"
            case "file": bodyMode = "binary"
            case let m?: bodyMode = m
            }
            formData = (bj?["formdata"]?.list ?? []).map { j in
                FormRow(key: j["key"]?.text ?? "", value: j["value"]?.text ?? "", enabled: !(j["disabled"]?.flag ?? false),
                        isFile: j["type"]?.text == "file", src: j["src"]?.text ?? "", contentType: j["contentType"]?.text ?? "")
            }
            urlencoded = (bj?["urlencoded"]?.list ?? []).map(Node.kv)
            binaryPath = bj?["file"]?["src"]?.text ?? ""
            requestExtras = r.dict.filter { !["method", "url", "header"].contains($0.key) }
            var disabled: [KV] = []
            if let dp = requestExtras.removeValue(forKey: "_postwoman_disabled_params") { disabled = dp.list.map(Node.kv).map { var k = $0; k.enabled = false; return k } }
            params = Node.parseQuery(url) + disabled
            loadScripts()
            // convert: first import. Also older files: a Basic tab with {{variables}} used to stay hidden, now it is shown in Headers.
            if let a = r["auth"] ?? auth, convert || (a["type"]?.text == "basic" && Node.importHeader(a).flatMap({ Node.plainBasic($0) }) != nil) {
                if let h = Node.importHeader(a) {
                    if !headers.contains(where: { $0.key.caseInsensitiveCompare(h.key) == .orderedSame }) { headers.append(h) }
                    requestExtras["auth"] = .obj(["type": .str("noauth")])   // header is the single source of truth, even if one already existed
                } else if let q = Node.importQuery(a) {                      // API key sent in the query string → a parameter
                    if !params.contains(where: { $0.key == q.key }) { params.append(q) }
                    requestExtras["auth"] = .obj(["type": .str("noauth")])
                }                                                            // anything else stays as imported: newman applies it when sending
            }
        }
        bag = objectWillChange.sink { Node.changed.send() }
    }

    /// bake=true (run / export): inherited folder headers are written into each request and internal keys are dropped.
    /// run=true (execution only): requests get `id` = stableID (newman reports it back) and `//` comments are removed from JSON bodies.
    func toJSON(variables: [Var] = [], bake: Bool = false, run: Bool = false, inherited: [KV] = [], saveFilter: ((Node) -> SaveChoice)? = nil) -> JSON {
        var o = extras
        if bake {
            o["_postwoman"] = nil
            // Headers are the single source of truth: drop collection/folder auth that is representable as a header
            if let a = o["auth"], Node.authHeader(a) != nil { o["auth"] = nil }
        }
        if let ch = children {
            let inh = bake ? Node.merge(inherited, folderHeaders) : []
            if !bake && !folderHeaders.isEmpty { o["_postwoman_headers"] = Node.hdrJSON(folderHeaders) }
            let items = JSON.arr(ch.compactMap { c -> JSON? in
                if c.children == nil, let f = saveFilter, f(c) == .baseline { return c.savedItem }      // not saved yet: the file keeps its old version
                return c.toJSON(bake: bake, run: run, inherited: inh, saveFilter: saveFilter)
            })
            if isRoot {
                var info = extras["info"] ?? .obj([:])
                info.setKey("name", .str(name))
                if info["schema"] == nil { info.setKey("schema", .str("https://schema.getpostman.com/json/collection/v2.1.0/collection.json")) }
                if info["_postman_id"] == nil { info.setKey("_postman_id", .str(UUID().uuidString.lowercased())) }
                o["info"] = info
                if !variables.isEmpty {
                    // secret variables are exported by name only: neither the value nor its ciphertext leaves the app
                    o["variable"] = .arr(variables.filter(\.enabled).map {
                        $0.secret ? .obj(["key": .str($0.key), "value": .str(""), "type": .str("secret")])
                                  : .obj(["key": .str($0.key), "value": .str($0.value)])
                    })
                }
            } else { o["name"] = .str(name) }
            o["item"] = items
        } else {
            o["name"] = .str(name)
            if !bake { o["_postwoman_id"] = .str(stableID) }       // internal: not exported
            if run { o["id"] = .str(stableID) }                    // links the execution to this request (history)
            var r = requestExtras
            let off = params.filter { !$0.enabled }
            if !bake && !off.isEmpty { r["_postwoman_disabled_params"] = Node.hdrJSON(off) }
            // run/export: a request's own bearer/basic/apikey auth must never override or duplicate what is in Headers
            if bake, let a = r["auth"], Node.authHeader(a) != nil { r["auth"] = .obj(["type": .str("noauth")]) }
            r["method"] = .str(method)
            r["url"] = .str(url)
            var hs = bake ? Node.merge(inherited, headers) : headers
            if run, !disabledAuto.contains("user-agent"), !hs.contains(where: { $0.enabled && $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame }) {
                hs.append(KV(key: "User-Agent", value: Node.userAgent))              // Postwoman/<version> instead of PostmanRuntime/…
            }
            if bake && !run, let i = hs.firstIndex(where: { $0.enabled && Node.plainBasic($0) != nil }), let c = Node.plainBasic(hs[i]) {
                hs.remove(at: i)                                                       // export: back to a real Authorization tab
                r["auth"] = .obj(["type": .str("basic"), "basic": .arr([
                    .obj(["key": .str("password"), "value": .str(c.password), "type": .str("string")]),
                    .obj(["key": .str("username"), "value": .str(c.user), "type": .str("string")])])])
            }
            r["header"] = Node.hdrJSON(hs)
            var ppb = o["protocolProfileBehavior"]?.dict ?? [:]
            var dis = ppb["disabledSystemHeaders"]?.dict ?? [:]
            for k in Node.removableAuto { dis[k] = nil }
            for k in disabledAuto { dis[k] = .bool(true) }
            ppb["disabledSystemHeaders"] = dis.isEmpty ? nil : .obj(dis)
            o["protocolProfileBehavior"] = ppb.isEmpty ? nil : .obj(ppb)
            switch bodyMode {
            case "none": r["body"] = nil
            case "raw":
                var b = Node.bodyKeeping(r["body"], dropping: ["formdata", "urlencoded", "file"])
                b.setKey("mode", .str("raw")); b.setKey("raw", .str(run && bodyIsJSON ? JSONFormat.withoutComments(body) : body))
                var opts = b["options"] ?? .obj([:]); var raw = opts["raw"] ?? .obj([:])
                raw.setKey("language", .str(rawLang)); opts.setKey("raw", raw); b.setKey("options", opts)
                r["body"] = b
            case "formdata":
                var b = Node.bodyKeeping(r["body"], dropping: ["raw", "urlencoded", "file"])
                b.setKey("mode", .str("formdata"))
                b.setKey("formdata", .arr(formData.map { f in
                    var d: [String: JSON] = ["key": .str(f.key), "type": .str(f.isFile ? "file" : "text")]
                    if f.isFile { d["src"] = .str(f.src) } else { d["value"] = .str(f.value) }
                    if !f.contentType.isEmpty { d["contentType"] = .str(f.contentType) }
                    if !f.enabled { d["disabled"] = .bool(true) }
                    return .obj(d)
                }))
                r["body"] = b
            case "urlencoded":
                var b = Node.bodyKeeping(r["body"], dropping: ["raw", "formdata", "file"])
                b.setKey("mode", .str("urlencoded")); b.setKey("urlencoded", Node.hdrJSON(urlencoded))
                r["body"] = b
            case "binary":
                var b = Node.bodyKeeping(r["body"], dropping: ["raw", "formdata", "urlencoded"])
                b.setKey("mode", .str("file")); b.setKey("file", .obj(["src": .str(binaryPath)]))
                r["body"] = b
            default: break                      // graphql etc.: kept untouched
            }
            o["request"] = .obj(r)
            o["event"] = scriptEvents()
        }
        return .obj(o)
    }

    func path(to t: Node) -> [Node]? {
        if self === t { return [self] }
        for c in children ?? [] { if let p = c.path(to: t) { return [self] + p } }
        return nil
    }
    /// Collection containing only `target` (wrapped in its ancestor folders, keeping their scripts) with inherited headers applied.
    static func scoped(root: Node, target: Node) -> JSON {
        guard let p = root.path(to: target), p.count > 1 else { return root.toJSON(bake: true, run: true) }
        var chain: [KV] = []
        for a in p.dropLast() { chain = merge(chain, a.folderHeaders) }
        var inner = target.toJSON(bake: true, run: true, inherited: chain)
        for a in p.dropFirst().dropLast().reversed() { var j = a.toJSON(bake: true); j.setKey("item", .arr([inner])); inner = j }
        var col = root.toJSON(bake: true); col.setKey("item", .arr([inner])); return col
    }
    func requests() -> [Node] { children == nil ? [self] : children!.flatMap { $0.requests() } }
    /// A copy must not share history with the original.
    func regenerateIDs() {
        if children == nil && !isRoot { stableID = UUID().uuidString.lowercased() }
        children?.forEach { $0.regenerateIDs() }
    }

    func copy() -> Node {
        var j = toJSON()
        if isRoot, var info = j["info"] { info.setKey("_postman_id", .str(UUID().uuidString.lowercased())); j.setKey("info", info) }
        let n = Node(json: j, root: isRoot); n.name = name + " Copy"; n.regenerateIDs(); return n
    }

    /// Same text typed on the other keyboard layout (RU ↔ EN): "gjbcr" ↔ "поиск".
    static func layoutVariants(_ q: String) -> [String] {
        let en = Array("`qwertyuiop[]asdfghjkl;'zxcvbnm,./"), ru = Array("ёйцукенгшщзхъфывапролджэячсмитьбю.")
        let toRU = Dictionary(uniqueKeysWithValues: zip(en, ru)), toEN = Dictionary(uniqueKeysWithValues: zip(ru, en))
        let low = q.lowercased()
        let a = String(low.map { toRU[$0] ?? $0 }), b = String(low.map { toEN[$0] ?? $0 })
        var out = [low]; for v in [a, b] where !out.contains(v) { out.append(v) }
        return out
    }

    /// qs: lowercased query variants (see layoutVariants). Searches every text field.
    func matches(_ qs: [String], content: Bool = true) -> Bool {
        func hit(_ s: String) -> Bool { let l = s.lowercased(); return qs.contains { l.contains($0) } }
        if hit(name) { return true }
        if !content { return false }
        let hs = children == nil ? headers : folderHeaders
        if hs.contains(where: { hit($0.key) || hit($0.value) }) { return true }
        return children == nil && (hit(method) || hit(url) || hit(body) || formData.contains(where: { hit($0.key) || hit($0.value) }) || urlencoded.contains(where: { hit($0.key) || hit($0.value) }) || hit(preScript) || hit(testScript))
    }

    func remove(_ n: Node) {
        children?.removeAll { $0 === n }
        children?.forEach { $0.remove(n) }
    }
}


/// One row of a form-data body: text value or a file.
struct FormRow: Identifiable, Hashable {
    var id = UUID()
    var key = ""
    var value = ""
    var enabled = true
    var isFile = false
    var src = ""
    var contentType = ""
}

// MARK: Headers added by the runtime, and the curl command
extension Node {
    static var userAgent: String { "Postwoman/" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.8") }
    static let calculated = "<calculated when request is sent>"
    /// Auto headers that can be switched off (newman: disabledSystemHeaders). Host and the body headers cannot.
    static let removableAuto: Set<String> = ["user-agent", "accept", "cache-control", "postman-token", "accept-encoding", "connection"]

    /// Content-Type the runtime derives from the body type (nil: none is added).
    var autoContentType: String? {
        switch bodyMode {
        case "raw":
            switch rawLang { case "json": return "application/json"; case "javascript": return "application/javascript"
            case "html": return "text/html"; case "xml": return "application/xml"; default: return "text/plain" }
        case "urlencoded": return "application/x-www-form-urlencoded"
        case "binary": return "text/plain"
        case "formdata": return "multipart/form-data; boundary=" + Node.calculated
        default: return nil
        }
    }
    /// What newman adds to every request on top of Headers (Postman shows them as "hidden" headers). Same names in Headers override these.
    /// Rows the user switched off come back with `enabled == false`.
    func autoHeaders(effective own: [KV]) -> [KV] {
        var out: [KV] = []
        func add(_ k: String, _ v: String) { out.append(KV(key: k, value: v, enabled: !disabledAuto.contains(k.lowercased()))) }
        if let ct = autoContentType { add("Content-Type", ct) }
        add("User-Agent", Node.userAgent)
        add("Accept", "*/*")
        add("Cache-Control", "no-cache")
        add("Postman-Token", Node.calculated)
        var host = ""
        if let u = URL(string: url.replacingOccurrences(of: "{{", with: "").replacingOccurrences(of: "}}", with: "")), let h = u.host { host = h + (u.port.map { ":\($0)" } ?? "") }
        add("Host", host.isEmpty ? Node.calculated : host)
        add("Accept-Encoding", "gzip, deflate, br")
        add("Connection", "keep-alive")
        if bodyMode != "none" && bodyMode != "" && method != "GET" && method != "HEAD" { add("Content-Length", Node.calculated) }
        let have = Set(own.filter(\.enabled).map { $0.key.lowercased() })
        return out.filter { $0.enabled && !have.contains($0.key.lowercased()) }       // removed ones are simply gone from the list (see HeadersEditor.removed)
    }

    // MARK: Authorization hints for the Headers tab
    /// Set when the Authorization tab (or header) cannot work as it is.
    var authProblem: String? {
        guard children == nil else { return nil }
        for h in headers where h.enabled && h.key.caseInsensitiveCompare("Authorization") == .orderedSame {
            let v = h.value.trimmingCharacters(in: .whitespaces).lowercased()
            if v.isEmpty || v == "bearer" || v == "basic" || v == "token" { return L("The Authorization header has no credentials (the token is empty).") }
        }
        if let a = requestExtras["auth"], let t = a["type"]?.text, t != "noauth" {
            func p(_ k: String) -> String { Node.authParam(a, t, k) ?? "" }
            switch t {
            case "bearer" where p("token").isEmpty: return L("The Authorization tab has no credentials (%@).", t)
            case "basic" where p("username").isEmpty && p("password").isEmpty: return L("The Authorization tab has no credentials (%@).", t)
            case "apikey" where p("key").isEmpty: return L("The Authorization tab has no credentials (%@).", t)
            default: break
            }
        }
        return nil
    }
    /// An Authorization tab that stays as imported: newman applies it itself when the request is sent.
    var authNote: String? {
        guard let a = requestExtras["auth"], let t = a["type"]?.text, t != "noauth" else { return nil }
        return L("Authorization tab: %@ — applied by newman when the request is sent", t)
    }

    /// curl command of this request. `vars` (when given) are substituted into {{name}}; secret ones stay as {{name}}.
    func curl(headers inherited: [KV], vars: [Var]?) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        func sub(_ s: String) -> String {
            guard let vars else { return s }
            var r = s
            for v in vars where v.enabled && !v.secret && !v.key.isEmpty { r = r.replacingOccurrences(of: "{{\(v.key)}}", with: v.value) }
            return r
        }
        var parts: [String] = ["curl"]
        if method != "GET" { parts.append("--request \(method)") }
        parts.append("--url " + q(sub(url)))
        let hs = Node.merge(inherited, headers).filter { $0.enabled && !$0.key.isEmpty }
        for h in hs {
            if let c = Node.plainBasic(h) { parts.append("--user " + q(sub("\(c.user):\(c.password)"))); continue }      // readable Basic credentials → curl encodes them
            parts.append("--header " + q(sub("\(h.key): \(h.value)")))
        }
        if let ct = autoContentType, bodyMode != "formdata", !hs.contains(where: { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
            parts.append("--header " + q("Content-Type: " + ct))
        }
        switch bodyMode {
        case "raw": if !body.isEmpty { parts.append("--data-raw " + q(sub(rawLang == "json" ? JSONFormat.withoutComments(body) : body))) }
        case "urlencoded": for r in urlencoded where r.enabled && !r.key.isEmpty { parts.append("--data-urlencode " + q(sub("\(r.key)=\(r.value)"))) }
        case "formdata":
            for r in formData where r.enabled && !r.key.isEmpty {
                parts.append("--form " + q(r.isFile ? "\(sub(r.key))=@\(r.src)" : sub("\(r.key)=\(r.value)")))
            }
        case "binary": if !binaryPath.isEmpty { parts.append("--data-binary " + q("@" + binaryPath)) }
        default: break
        }
        return parts.joined(separator: " \\\n  ")
    }
}

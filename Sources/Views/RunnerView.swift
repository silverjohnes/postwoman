import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: Runner
struct RunnerView: View {
    @EnvironmentObject var store: Store
    var body: some View { RunnerInner(runner: store.runner) }
}

struct RunnerInner: View {
    @EnvironmentObject var store: Store
    @ObservedObject var runner: Runner
    @State private var picked: ExecResult.ID?
    @State private var showPreview = false
    @State private var detailGen = 0          // bumped when a result is picked automatically → ResultDetail starts on "Res body" again

    // While a single request (sent from the Request tab) occupies the runner, this tab keeps showing the last mass run.
    private var shownResults: [ExecResult] { store.lastRunSingle ? (store.massSnapshot?.results ?? []) : runner.results }
    private var shownLog: String { store.lastRunSingle ? (store.massSnapshot?.log ?? "") : runner.log }
    private var shownProgress: String { store.lastRunSingle ? (store.massSnapshot?.progress ?? "") : runner.progress }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(store.primary.map { L("Target: %@", $0.name) + ($0.children != nil ? ($0.isRoot ? L(" (collection)") : L(" (folder)")) : "") } ?? L("Select a collection, folder or request in the sidebar")).bold()
                Spacer()
                Text(shownProgress).foregroundStyle(.secondary)
            }
            HStack {
                Stepper(store.iterations == 0 ? L("Iterations: all rows") : L("Iterations: %ld", store.iterations), value: $store.iterations, in: (store.dataURL == nil ? 1 : 0)...100000)
                Stepper(L("Interval: %ld ms", store.interval), value: $store.interval, in: 0...3_600_000, step: 100)
                Button(store.dataURL?.lastPathComponent ?? L("Data file (CSV/JSON)…")) { store.pickData() }
                if store.dataURL != nil { CloseButton(help: "Remove") { store.dataURL = nil; if store.iterations == 0 { store.iterations = 1 } } }
                if store.dataURL != nil { Button(L("Preview")) { showPreview = true } }
                if runner.hasErrorRows { Button(L("Errors CSV")) { runner.saveErrorsCSV() }.help(L("Data rows of failed requests, without duplicates")) }
                Spacer()
                switch runner.state {
                case .idle: Button("Run") { store.run() }.buttonStyle(.borderedProminent).disabled(store.primary == nil)
                case .running: Button("Pause") { runner.pause() }; Button("Stop", role: .destructive) { runner.stop() }
                case .paused: Button("Resume") { runner.resume() }; Button("Stop", role: .destructive) { runner.stop() }
                }
            }
            HSplitView {
                // both panels follow new lines while scrolled to the bottom and stay put once you scroll up
                ResultsList(results: shownResults, picked: $picked, onUserPick: { store.autoPickResult = false })
                    .frame(minWidth: 320)
                if let r = shownResults.first(where: { $0.id == picked }) { ResultDetail(r: r).id(detailGen) }
                else { PinnedText(text: shownLog) }
            }
        }
        .padding()
        .onAppear { autoPick() }
        .onChange(of: runner.results.count) { if !store.lastRunSingle { autoPick() } }
        .sheet(isPresented: $showPreview) {
            if let u = store.dataURL { DataPreview(url: u, target: store.primary).environmentObject(store) }
        }
    }

    /// A single request was run → show its result right away (Res body tab), not the run log.
    private func autoPick() {
        if store.autoPickResult, !store.lastRunSingle, let last = runner.results.last, picked != last.id { picked = last.id; detailGen += 1 }
    }
}

struct ResultDetail: View {
    let r: ExecResult
    @State private var t: Int            // 0 Request, 1 Response, 2 Visualize
    @AppStorage("showReqHeaders") private var reqHeadersOn = true      // "Headers" check box: remembered separately for Request and Response
    @AppStorage("showResHeaders") private var resHeadersOn = true
    @State private var reqBodyP: String              // bodies as shown (JSON indented)
    @State private var resBodyP: String
    @State private var reqText: String
    @State private var resText: String
    @State private var formatting = false
    init(r: ExecResult) {
        self.r = r; _t = State(initialValue: r.visual != nil ? 2 : 1)   // Visualize when the scripts made one, else Response
        // small bodies are formatted at once; big ones show raw first and are formatted off the main thread (see .task below)
        let rb = HTTPText.pretty(r.reqBody), sb = HTTPText.pretty(r.resBody)
        let rh = UserDefaults.standard.object(forKey: "showReqHeaders") as? Bool ?? true, sh = UserDefaults.standard.object(forKey: "showResHeaders") as? Bool ?? true
        _reqBodyP = State(initialValue: rb); _resBodyP = State(initialValue: sb)
        _reqText = State(initialValue: HTTPText.request(method: r.method, url: r.url, headers: r.reqHeaders, body: rb, limit: 0, withHeaders: rh))
        _resText = State(initialValue: HTTPText.response(code: r.code, status: r.status, headers: r.resHeaders, body: sb, error: r.failures, limit: 0, withHeaders: sh))
    }
    private func rebuild() {
        reqText = HTTPText.request(method: r.method, url: r.url, headers: r.reqHeaders, body: reqBodyP, limit: 0, withHeaders: reqHeadersOn)
        resText = HTTPText.response(code: r.code, status: r.status, headers: r.resHeaders, body: resBodyP, error: r.failures, limit: 0, withHeaders: resHeadersOn)
    }
    static let stamp: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()
    private var tabs: [(Int, String)] {
        var a = [(0, L("Request")), (1, L("Response"))]
        if r.visual != nil { a.append((2, L("Visualize"))) }
        return a
    }
    private var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(r.resBody.utf8.count), countStyle: .file) }

    private func saveBody() {
        let p = NSSavePanel()
        let looksJSON = r.resBody.drop { $0.isWhitespace }.first.map { $0 == "{" || $0 == "[" } ?? false
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy.MM.dd HH.mm.ss"
        // characters that Windows, macOS or Linux do not allow in a file name (and control characters) become "_"
        let bad = CharacterSet(charactersIn: "<>:\"/\\|?*").union(.controlCharacters)
        let clean = r.name.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        p.nameFieldStringValue = L("Response") + (clean.isEmpty ? "" : " " + clean) + " " + f.string(from: r.started) + "." + (looksJSON ? "json" : "txt")
        guard p.runModal() == .OK, let u = p.url else { return }
        let body = r.resBody
        Task.detached {
            let text = HTTPText.pretty(body, limit: HTTPText.maxPretty)
            try? text.data(using: .utf8)?.write(to: u)
        }
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text("\(r.method) \(r.url)").font(.system(.body, design: .monospaced)).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
            HStack(alignment: .center, spacing: 6) {
                StatusBadge(code: r.code, large: true)                                  // the same coloured code as in History
                Text(L("%@ %@ · %ld ms · %@", "", r.status, r.time, Self.stamp.string(from: r.started)).trimmingCharacters(in: .whitespaces) + (r.iteration > 0 ? L(" · iteration %ld", r.iteration) : "") + (r.resBody.isEmpty ? "" : " · " + sizeText))
                    .foregroundStyle(.secondary)
            }
            if !r.dataRow.isEmpty {
                Text(L("data: ") + r.dataRow.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            ForEach(r.failures, id: \.self) { Text($0).foregroundStyle(.red).font(.caption) }
            HStack {
                TabStrip(items: tabs, selection: $t); Spacer(minLength: 0)
                if formatting { ProgressView().controlSize(.small); Text("Formatting…").font(.caption).foregroundStyle(.secondary) }
                if t == 0 || t == 1 {
                    Toggle("Headers", isOn: t == 0 ? $reqHeadersOn : $resHeadersOn).toggleStyle(.checkbox).controlSize(.small)
                }
                if t == 0 {
                    CopyButton(curl: true) { CurlBuilder.build(method: r.method, url: r.url, headers: r.reqHeaders, body: r.reqBody) }.controlSize(.small)
                } else if t == 1 {
                    CopyButton { resText }.controlSize(.small)
                    if !r.resBody.isEmpty {
                        Button { saveBody() } label: { Image(systemName: "square.and.arrow.down") }.controlSize(.small).help("Save response body…")
                    }
                }
            }
            switch t {
            case 2 where r.visual != nil: VisualizePane(html: r.visual ?? "", data: r.visualData, error: r.visualError)
            case 0: FoundText(text: reqText, syntax: .http)
            default: FoundText(text: resText, syntax: .http)       // no Visualize tab without a visualizer script
            }
        }
        .frame(minWidth: 260)
        .onChange(of: r.visual != nil) { _, has in t = has ? 2 : (t == 2 ? 1 : t) }
        .onChange(of: r.id) { t = r.visual != nil ? 2 : 1 }
        .onChange(of: reqHeadersOn) { rebuild() }
        .onChange(of: resHeadersOn) { rebuild() }
        .task(id: r.id) {
            // bodies above the quick limit: format JSON off the main thread, then swap the text in
            guard r.resBody.utf8.count >= HTTPText.quickPretty || r.reqBody.utf8.count >= HTTPText.quickPretty else { return }
            formatting = true
            let rq = r.reqBody, rs = r.resBody
            let (a, b) = await Task.detached(priority: .userInitiated) {
                (HTTPText.pretty(rq, limit: HTTPText.maxPretty), HTTPText.pretty(rs, limit: HTTPText.maxPretty))
            }.value
            if !Task.isCancelled { reqBodyP = a; resBodyP = b; rebuild() }
            formatting = false
        }
    }
}

struct HeaderText: View { let h: [KV]; var body: some View { LogView(text: h.map { "\($0.key): \($0.value)" }.joined(separator: "\n")) } }

struct LogView: View {
    let text: String
    var body: some View { ScrollView { Text(text.isEmpty ? " " : text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(6) }
        .background(Color.secondary.opacity(0.08)) }
}


// MARK: Data file preview (Runner tab): the variables of the file, and the requests as they will be sent for a chosen row
struct DataPreview: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let target: Node?
    @State private var tab = 0
    @State private var columns: [String] = []
    @State private var rows: [[String: String]] = []
    @State private var row = 0
    private static let shown = 500

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(url.lastPathComponent).font(.title3.bold())
                Text(L("%ld row(s), %ld variable(s)", rows.count, columns.count)).foregroundStyle(.secondary)
                Spacer()
                Button(L("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TabStrip(items: [(0, L("Variables")), (1, L("Requests"))], selection: $tab)
            if tab == 0 { variables } else { requests }
        }
        .padding().frame(minWidth: 760, minHeight: 520)
        .onAppear {
            columns = Runner.loadColumns(url); rows = Runner.loadRows(url)
            if columns.isEmpty { columns = Array(Set(rows.flatMap { $0.keys })).sorted() }
        }
    }

    private var variables: some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("#").foregroundStyle(.secondary)
                    ForEach(columns, id: \.self) { Text($0).bold() }
                }
                Divider()
                ForEach(Array(rows.prefix(Self.shown).enumerated()), id: \.offset) { i, r in
                    GridRow {
                        Text("\(i + 1)").foregroundStyle(.secondary)
                        ForEach(columns, id: \.self) { Text(r[$0] ?? "").textSelection(.enabled) }
                    }
                }
            }
            .font(.system(.body, design: .monospaced)).padding(6)
            if rows.count > Self.shown { Text(L("First %ld rows shown", Self.shown)).font(.caption).foregroundStyle(.secondary) }
        }
        .background(Color.secondary.opacity(0.08))
    }

    /// {{name}} → value of the data row, else a plain Globals value; secrets are never decrypted here; unknown names stay as they are.
    private func substitute(_ s: String, _ vars: [String: String]) -> String {
        guard s.contains("{{"), let re = try? NSRegularExpression(pattern: "\\{\\{([^{}\\n]+)\\}\\}") else { return s }
        let ns = s as NSString
        var out = "", last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            out += vars[name.lowercased()] ?? ns.substring(with: m.range)
            last = NSMaxRange(m.range)
        }
        return out + ns.substring(from: last)
    }
    private func text(for q: Node, _ vars: [String: String]) -> String {
        let inherited = store.inherited(for: q).map(\.h)
        let headers = Node.merge(inherited, q.headers).filter(\.enabled)
            .map { KV(key: substitute($0.key, vars), value: substitute($0.value, vars)) }
        var body = ""
        switch q.bodyMode {
        case "raw": body = q.body
        case "urlencoded": body = q.urlencoded.filter(\.enabled).map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        default: break
        }
        return HTTPText.request(method: q.method, url: substitute(q.url, vars), headers: headers, body: substitute(body, vars))
    }
    private var requests: some View {
        let reqs = target?.requests() ?? []
        var vars: [String: String] = [:]          // keys are lower-cased: variable names are not case sensitive
        for g in store.globals where g.enabled && !g.key.isEmpty { vars[g.key.lowercased()] = g.secret ? "‹secret: \(g.key)›" : g.value }
        if rows.indices.contains(row) { for (k, v) in rows[row] { vars[k.lowercased()] = v } }
        return VStack(alignment: .leading, spacing: 8) {
            if !rows.isEmpty {
                Stepper(L("Row %ld of %ld", row + 1, rows.count), value: $row, in: 0...(rows.count - 1))
            }
            if reqs.isEmpty { Text(L("Select a collection, folder or request in the sidebar")).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(reqs.prefix(200)) { q in
                        GroupBox(q.name) {
                            Text(text(for: q, vars)).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.padding(2)
            }
        }
    }
}

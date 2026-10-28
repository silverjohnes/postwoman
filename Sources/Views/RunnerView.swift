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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(store.primary.map { L("Target: %@", $0.name) + ($0.children != nil ? ($0.isRoot ? L(" (collection)") : L(" (folder)")) : "") } ?? L("Select a collection, folder or request in the sidebar")).bold()
                Spacer()
                Text(runner.progress).foregroundStyle(.secondary)
            }
            HStack {
                Stepper(store.iterations == 0 ? L("Iterations: all rows") : L("Iterations: %ld", store.iterations), value: $store.iterations, in: (store.dataURL == nil ? 1 : 0)...100000)
                Stepper(L("Interval: %ld ms", store.interval), value: $store.interval, in: 0...3_600_000, step: 100)
                Button(store.dataURL?.lastPathComponent ?? L("Data file (CSV/JSON)…")) { store.pickData() }
                if store.dataURL != nil { Button { store.dataURL = nil; if store.iterations == 0 { store.iterations = 1 } } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless) }
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
                ResultsList(results: runner.results, picked: $picked, onUserPick: { store.autoPickResult = false })
                    .frame(minWidth: 320)
                if let r = runner.results.first(where: { $0.id == picked }) { ResultDetail(r: r).id(detailGen) }
                else { PinnedText(text: runner.log) }
            }
        }
        .padding()
        .onAppear { autoPick() }
        .onChange(of: runner.results.count) { autoPick() }
        .sheet(isPresented: $showPreview) {
            if let u = store.dataURL { DataPreview(url: u, target: store.primary).environmentObject(store) }
        }
    }

    /// A single request was run → show its result right away (Res body tab), not the run log.
    private func autoPick() {
        if store.autoPickResult, let last = runner.results.last, picked != last.id { picked = last.id; detailGen += 1 }
    }
}

struct ResultDetail: View {
    let r: ExecResult
    @State private var t: Int            // 0 Request, 1 Response, 2 Visualize
    private let reqText: String
    private let resText: String
    init(r: ExecResult) {
        self.r = r; _t = State(initialValue: r.visual != nil ? 2 : 1)   // Visualize when the scripts made one, else Response
        reqText = HTTPText.request(method: r.method, url: r.url, headers: r.reqHeaders, body: r.reqBody)
        resText = HTTPText.response(code: r.code, status: r.status, headers: r.resHeaders, body: r.resBody, error: r.failures)
    }
    static let stamp: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()
    private var tabs: [(Int, String)] {
        var a = [(0, L("Request")), (1, L("Response"))]
        if r.visual != nil { a.append((2, L("Visualize"))) }
        return a
    }
    var body: some View {
        VStack(alignment: .leading) {
            Text("\(r.method) \(r.url)").font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Text(L("%@ %@ · %ld ms · %@", "\(r.code)", r.status, r.time, Self.stamp.string(from: r.started)) + (r.iteration > 0 ? L(" · iteration %ld", r.iteration) : "")).foregroundStyle(.secondary)
            if !r.dataRow.isEmpty {
                Text(L("data: ") + r.dataRow.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            ForEach(r.failures, id: \.self) { Text($0).foregroundStyle(.red).font(.caption) }
            HStack {
                TabStrip(items: tabs, selection: $t); Spacer(minLength: 0)
                if t == 0 {
                    CopyButton(title: "Copy as curl") { CurlBuilder.build(method: r.method, url: r.url, headers: r.reqHeaders, body: r.reqBody) }.controlSize(.small)
                }
            }
            switch t {
            case 2 where r.visual != nil: VisualizePane(html: r.visual ?? "", data: r.visualData, error: r.visualError)
            case 0: FoundText(text: reqText, syntax: .http)
            default: FoundText(text: resText, syntax: .http)       // no Visualize tab without a visualizer script
            }
        }
        .frame(minWidth: 380)
        .onChange(of: r.visual != nil) { _, has in t = has ? 2 : (t == 2 ? 1 : t) }
        .onChange(of: r.id) { t = r.visual != nil ? 2 : 1 }
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
            out += vars[name] ?? ns.substring(with: m.range)
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
        var vars: [String: String] = [:]
        for g in store.globals where g.enabled && !g.key.isEmpty { vars[g.key] = g.secret ? "‹secret: \(g.key)›" : g.value }
        if rows.indices.contains(row) { for (k, v) in rows[row] { vars[k] = v } }
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

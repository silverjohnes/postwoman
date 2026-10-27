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

import SwiftUI
import AppKit

// MARK: History tab of one request
//
// Layout rules (why this view cannot "run away"):
//  • no HSplitView, no minWidth on content: a fixed-width list column + a flexible detail column;
//  • every container is bounded with maxWidth/maxHeight = .infinity and clipped, so the tab bar above is never pushed out;
//  • request/response texts live in an NSTextView (handles megabytes, wraps, selectable) and are capped at `CodeText.cap`.
// Selection works like Finder: click, ⇧-click (range), ⌘-click (add/remove), ⌘A, ↑/↓; Delete / ⌘⌫ or the context menu removes the selected executions.
struct HistoryTab: View {
    @ObservedObject var history: HistoryStore
    let node: Node
    @State private var entries: [HistoryEntry] = []
    @State private var total = 0
    @State private var selection: Set<String> = []
    @State private var picked: String?              // the one shown on the right
    @State private var anchor: String?              // start of a ⇧ range
    @FocusState private var focused: Bool
    @AppStorage("historyRetentionValue") private var keepValue = 6
    @AppStorage("historyRetentionUnit") private var keepUnit = "months"

    static let stamp: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()

    private var keepText: String { keepUnit == "days" ? L("%ld day(s)", keepValue) : L("%ld month(s)", keepValue) }
    private var current: HistoryEntry? { entries.first { $0.id == picked } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if entries.isEmpty {
                Placeholder("No executions recorded yet.\nRun the request and it will appear here.")
                    .multilineTextAlignment(.center)
            } else {
                HStack(spacing: 0) {
                    list.frame(width: 270).frame(maxHeight: .infinity)
                    Divider()
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onAppear(perform: reload)
        .onChange(of: history.tick) { reload() }
    }

    @ViewBuilder private var detail: some View {
        if selection.count > 1 {
            VStack(spacing: 10) {
                Text(L("%ld executions selected", selection.count)).font(.title3).foregroundStyle(.secondary)
                Button(role: .destructive) { askDelete(selection) } label: { Label("Delete…", systemImage: "trash") }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let e = current { HistoryDetail(entry: e).id(e.id) }
        else { Placeholder("Select an execution") }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(total == 0 ? L("History") : L("%ld execution(s)", total) + (total > entries.count ? L(", latest %ld shown", entries.count) : "")).bold()
            Text(L("kept for %@ · Settings → History", keepText)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if selection.count > 0 { Button("Delete…") { askDelete(selection) } }
            Button("Clear…") { confirmClear() }.disabled(total == 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(entries) { e in
                    HistoryRow(entry: e, selected: selection.contains(e.id))
                        .contentShape(Rectangle())
                        .onTapGesture { click(e); focused = true }
                        .contextMenu {
                            let targets = selection.contains(e.id) ? selection : [e.id]
                            Button(targets.count > 1 ? L("Delete %ld executions…", targets.count) : L("Delete…"), role: .destructive) { askDelete(targets) }
                            Divider()
                            Button("Select all") { selectAll() }
                        }
                    Divider()
                }
            }
        }
        .background(Color.secondary.opacity(0.05))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { press in
            switch press.key {
            case .delete, .deleteForward: askDelete(selection); return .handled
            case .upArrow: move(-1, extend: press.modifiers.contains(.shift)); return .handled
            case .downArrow: move(1, extend: press.modifiers.contains(.shift)); return .handled
            default:
                if press.characters.lowercased() == "a", press.modifiers.contains(.command) { selectAll(); return .handled }
                return .ignored
            }
        }
    }

    // MARK: selection
    private func click(_ e: HistoryEntry) {
        let f = NSEvent.modifierFlags
        if f.contains(.shift), let a = anchor, let ai = entries.firstIndex(where: { $0.id == a }), let bi = entries.firstIndex(where: { $0.id == e.id }) {
            let ids = entries[min(ai, bi)...max(ai, bi)].map(\.id)
            if f.contains(.command) { selection.formUnion(ids) } else { selection = Set(ids) }
            picked = e.id
        } else if f.contains(.command) {
            if selection.contains(e.id) { selection.remove(e.id); picked = selection.first } else { selection.insert(e.id); picked = e.id }
            anchor = e.id
        } else {
            selection = [e.id]; picked = e.id; anchor = e.id
        }
    }
    private func move(_ d: Int, extend: Bool) {
        guard !entries.isEmpty else { return }
        let cur = entries.firstIndex { $0.id == picked } ?? 0
        let n = min(entries.count - 1, max(0, cur + d))
        let id = entries[n].id
        if extend, let a = anchor, let ai = entries.firstIndex(where: { $0.id == a }) {
            selection = Set(entries[min(ai, n)...max(ai, n)].map(\.id))
        } else { selection = [id]; anchor = id }
        picked = id
    }
    private func selectAll() { selection = Set(entries.map(\.id)); if picked == nil { picked = entries.first?.id } }

    private func reload() {
        let r = history.load(node.stableID, limit: 200)
        entries = r.entries; total = r.total
        let ids = Set(entries.map(\.id))
        selection = selection.intersection(ids)
        if picked == nil || !ids.contains(picked!) { picked = selection.first ?? entries.first?.id; if selection.isEmpty, let p = picked { selection = [p] } }
        if let a = anchor, !ids.contains(a) { anchor = picked }
    }
    private func askDelete(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let a = NSAlert()
        a.messageText = ids.count == 1 ? L("Delete the selected execution?") : L("Delete %ld selected executions?", ids.count)
        a.informativeText = L("This cannot be undone. The request itself is not changed.")
        a.addButton(withTitle: L("Delete")); a.addButton(withTitle: L("Cancel"))
        if a.runModal() == .alertFirstButtonReturn {
            let keepPos = entries.firstIndex { ids.contains($0.id) } ?? 0
            history.removeEntries(node.stableID, ids: ids)
            selection = []; picked = nil
            reload()
            if selection.isEmpty, !entries.isEmpty { let id = entries[min(keepPos, entries.count - 1)].id; selection = [id]; picked = id; anchor = id }
        }
    }
    private func confirmClear() {
        let a = NSAlert(); a.messageText = L("Clear the history of \"%@\"?", node.name)
        a.informativeText = L("%ld recorded execution(s) will be deleted. The request itself is not changed.", total)
        a.addButton(withTitle: L("Clear")); a.addButton(withTitle: L("Cancel"))
        if a.runModal() == .alertFirstButtonReturn { history.clear(node.stableID) }
    }
}

// MARK: One row of the list
private struct HistoryRow: View {
    let entry: HistoryEntry
    let selected: Bool
    private var ok: Bool { entry.code >= 200 && entry.code < 400 }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(entry.code == 0 ? "ERR" : "\(entry.code)")
                    .font(.system(.caption, design: .monospaced).bold())
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background((ok ? Color.green : Color.red).opacity(selected ? 0.9 : 0.2), in: Capsule())
                    .foregroundStyle(selected ? Color.white : (ok ? Color.green : Color.red))
                Text("\(entry.timeMs) ms").font(.caption).foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                Spacer(minLength: 0)
                if !entry.dataRow.isEmpty { Image(systemName: "tablecells").font(.caption) }
                if !entry.failures.isEmpty { Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(selected ? Color.white : Color.orange) }
            }
            Text(HistoryTab.stamp.string(from: entry.ts)).font(.system(.caption, design: .monospaced))
                .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor : Color.clear)
        .foregroundStyle(selected ? Color.white : Color.primary)
    }
}

// MARK: Detail of one execution: Request (line + headers + body) and Response (status + headers + body), formatted
private struct HistoryDetail: View {
    let entry: HistoryEntry
    @State private var section = 1                 // Response first
    @State private var reqText = ""                // formatted once per execution, not on every redraw
    @State private var resText = ""

    private var sections: [(Int, String)] {
        var s: [(Int, String)] = [(0, L("Request")), (1, L("Response"))]
        if !entry.failures.isEmpty { s.append((2, L("Failures (%ld)", entry.failures.count))) }
        if !entry.dataRow.isEmpty { s.append((3, L("Data"))) }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(entry.method) \(entry.url)")
                .font(.system(.callout, design: .monospaced)).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            Text(L("%@ %@ · %ld ms · %@", entry.code == 0 ? "ERR" : "\(entry.code)", entry.status, entry.timeMs, HistoryTab.stamp.string(from: entry.ts))
                 + (entry.iteration > 0 ? L(" · iteration %ld", entry.iteration) : ""))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack {
                TabStrip(items: sections, selection: $section); Spacer(minLength: 0)
                if section == 0 {
                    CopyButton(title: "Copy as curl") { CurlBuilder.build(method: entry.method, url: entry.url, headers: entry.reqHeaders, body: entry.reqBody) }.controlSize(.small)
                }
            }
            switch section {
            case 0: FoundText(text: reqText, syntax: .http).frame(maxWidth: .infinity, maxHeight: .infinity)
            case 1: FoundText(text: resText, syntax: .http).frame(maxWidth: .infinity, maxHeight: .infinity)
            case 2: CodeText(text: entry.failures.joined(separator: "\n")).frame(maxWidth: .infinity, maxHeight: .infinity)
            default: CodeText(text: entry.dataRow.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }.joined(separator: "\n")).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: entry.id) {
            reqText = HTTPText.request(method: entry.method, url: entry.url, headers: entry.reqHeaders, body: entry.reqBody)
            resText = HTTPText.response(code: entry.code, status: entry.status, headers: entry.resHeaders, body: entry.resBody, error: entry.failures)
        }
    }
}

import SwiftUI
import AppKit

// MARK: Text of one HTTP message, ready to read
enum HTTPText {
    /// JSON bodies are re-indented (key order kept); everything else is shown as received.
    static func pretty(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.utf8.count < 150_000, t.hasPrefix("{") || t.hasPrefix("[") else { return s }
        return JSONFormat.beautify(t) ?? s
    }
    private static func lines(_ h: [KV]) -> String { h.map { "\($0.key): \($0.value)" }.joined(separator: "\n") }

    static func request(method: String, url: String, headers: [KV], body: String) -> String {
        var s = "\(method) \(url)"
        if !headers.isEmpty { s += "\n" + lines(headers) }
        if !body.isEmpty { s += "\n\n" + pretty(body) }
        return s
    }
    static func response(code: Int, status: String, headers: [KV], body: String, error: [String] = []) -> String {
        var s = code == 0 ? "ERR" : "HTTP \(code) \(status)"
        if !headers.isEmpty { s += "\n" + lines(headers) }
        if !body.isEmpty { s += "\n\n" + pretty(body) }
        else if code == 0 && !error.isEmpty { s += "\n\n" + error.joined(separator: "\n") }
        return s
    }
}

// MARK: Read-only selectable text (NSTextView) with syntax colours: fast for large bodies, wraps, never grows its container
struct CodeText: NSViewRepresentable {
    let text: String
    var syntax: Syntax = .plain
    var size: CGFloat = 11
    var find = ""                                 // case-insensitive; all hits are marked, the current one is scrolled to
    var findIndex = 0
    var onCount: ((Int) -> Void)? = nil
    static let cap = 300_000                      // characters shown; the full body stays in the history file

    final class Coord { var last: String?; var lastSyntax: Syntax?; var lastFind = ""; var lastIdx = -1 }
    func makeCoordinator() -> Coord { Coord() }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSTextView.scrollableTextView()
        sv.hasHorizontalScroller = false; sv.drawsBackground = true
        sv.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.08)
        sv.borderType = .noBorder
        let tv = sv.documentView as! NSTextView
        tv.isEditable = false; tv.isSelectable = true; tv.isRichText = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 6, height: 6)
        return sv
    }
    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? NSTextView else { return }
        let c = context.coordinator
        let changed = c.last != text || c.lastSyntax != syntax
        if changed {
            c.last = text; c.lastSyntax = syntax
            var shown = text
            if shown.count > Self.cap {
                shown = String(shown.prefix(Self.cap)) + L("\n\n… truncated: showing %ld of %ld characters", Self.cap, text.count)
            }
            tv.string = shown.isEmpty ? " " : shown
            if let st = tv.textStorage { Highlighter.apply(to: st, syntax: syntax, size: size) }
            tv.scrollToBeginningOfDocument(nil)
        }
        if changed || c.lastFind != find || c.lastIdx != findIndex {
            let textOnly = !changed
            c.lastFind = find; c.lastIdx = findIndex
            mark(tv, clear: textOnly)
        }
    }

    /// Marks every hit of `find`; the current one is orange and scrolled into view.
    private func mark(_ tv: NSTextView, clear: Bool) {
        guard let st = tv.textStorage else { return }
        let ns = st.string as NSString
        if clear { st.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: ns.length)) }
        var hits: [NSRange] = []
        if !find.isEmpty {
            var loc = 0
            while loc < ns.length, hits.count < 5000 {
                let r = ns.range(of: find, options: .caseInsensitive, range: NSRange(location: loc, length: ns.length - loc))
                if r.location == NSNotFound || r.length == 0 { break }
                hits.append(r); loc = NSMaxRange(r)
            }
        }
        for r in hits { st.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.45), range: r) }
        if !hits.isEmpty {
            let cur = hits[min(max(0, findIndex), hits.count - 1)]
            st.addAttribute(.backgroundColor, value: NSColor.systemOrange.withAlphaComponent(0.85), range: cur)
            tv.scrollRangeToVisible(cur)
        }
        let n = hits.count
        if let onCount { DispatchQueue.main.async { onCount(n) } }
    }
}

/// Text of a result with a find field above it (⌘F focuses the field).
struct FoundText: View {
    @EnvironmentObject var store: Store
    let text: String
    var syntax: Syntax = .http
    @State private var q = ""
    @State private var idx = 0
    @State private var count = 0
    @FocusState private var fieldFocus: Bool

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in text", text: $q).textFieldStyle(.plain).focused($fieldFocus)
                    .onSubmit { step(1); fieldFocus = true }
                if !q.isEmpty {
                    Text(count == 0 ? "0" : "\(idx + 1)/\(count)").font(.caption.monospacedDigit()).foregroundStyle(count == 0 ? Color.red : Color.secondary)
                    Button { step(-1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled(count == 0)
                    Button { step(1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).disabled(count == 0)
                    Button { q = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .padding(5).background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
            CodeText(text: text, syntax: syntax, size: 12, find: q, findIndex: idx, onCount: { n in
                count = n; if idx >= n { idx = 0 }
            })
        }
        .onChange(of: q) { idx = 0 }
        .onChange(of: store.focusFind) { fieldFocus = true }
        .onAppear { store.findPanes += 1 }
        .onDisappear { store.findPanes -= 1 }
    }
    private func step(_ d: Int) { guard count > 0 else { return }; idx = (idx + d + count) % count }
}

/// Kept for older call sites.
typealias HistoryText = CodeText

// MARK: Copyable text block with a button (curl panel)
struct CopyButton: View {
    var title: LocalizedStringKey = "Copy"
    let text: () -> String
    @State private var done = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text(), forType: .string)
            done = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { done = false }
        } label: { Label(done ? LocalizedStringKey("Copied") : title, systemImage: done ? "checkmark" : "doc.on.doc") }
    }
}

// MARK: Tabs sized to their text: never wider than the space they get (scrolls instead of running out of the window)
struct TabStrip<T: Hashable>: View {
    let items: [(T, String)]
    @Binding var selection: T
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(items, id: \.0) { item in
                    let on = item.0 == selection
                    Button { selection = item.0 } label: {
                        Text(item.1).lineLimit(1).fixedSize()
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(on ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            .padding(2)
        }
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .frame(height: 28)
        .fixedSize(horizontal: false, vertical: true)
    }
}

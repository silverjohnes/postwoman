import SwiftUI
import AppKit

// MARK: Text of one HTTP message, ready to read
enum HTTPText {
    /// Bodies up to this size are formatted on the spot (instant); bigger ones are formatted off the main thread with `limit: maxPretty`.
    static let quickPretty = 150_000, maxPretty = 40_000_000
    /// JSON bodies are re-indented (key order kept); everything else is shown as received.
    static func pretty(_ s: String, limit: Int = quickPretty) -> String {
        guard s.utf8.count < limit else { return s }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{") || t.hasPrefix("[") else { return s }
        // invalid JSON (cut off, a stray comma or quote…) is still indented wherever it is correct
        return JSONFormat.beautify(t) ?? JSONFormat.beautify(t, lenient: true) ?? s
    }
    private static func lines(_ h: [KV]) -> String { h.map { "\($0.key): \($0.value)" }.joined(separator: "\n") }

    /// `limit: 0` = the body is already formatted. `withHeaders: false` = only the body.
    static func request(method: String, url: String, headers: [KV], body: String, limit: Int = quickPretty, withHeaders: Bool = true) -> String {
        guard withHeaders else { return pretty(body, limit: limit) }
        var s = "\(method) \(url)"
        if !headers.isEmpty { s += "\n" + lines(headers) }
        if !body.isEmpty { s += "\n\n" + pretty(body, limit: limit) }
        return s
    }
    static func response(code: Int, status: String, headers: [KV], body: String, error: [String] = [], limit: Int = quickPretty, withHeaders: Bool = true) -> String {
        guard withHeaders else {
            if !body.isEmpty { return pretty(body, limit: limit) }
            return code == 0 ? error.joined(separator: "\n") : ""
        }
        var s = code == 0 ? "ERR" : "HTTP \(code) \(status)"
        if !headers.isEmpty { s += "\n" + lines(headers) }
        if !body.isEmpty { s += "\n\n" + pretty(body, limit: limit) }
        else if code == 0 && !error.isEmpty { s += "\n\n" + error.joined(separator: "\n") }
        return s
    }
}

/// Marks every hit of `find` (yellow, the current one orange) with layout-manager temporary attributes and scrolls to the current one.
/// `previous` holds the ranges marked last time: only those are cleared (other temporary colours, e.g. {{variables}}, stay).
enum FindMarks {
    @MainActor static func apply(_ tv: NSTextView, find: String, index: Int, scroll: Bool, previous: inout [NSRange]) -> Int {
        guard let lm = tv.layoutManager else { return 0 }
        let ns = tv.string as NSString
        for r in previous where NSMaxRange(r) <= ns.length { lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r) }
        var hits: [NSRange] = []
        if !find.isEmpty {
            var loc = 0
            while loc < ns.length, hits.count < 5000 {
                let r = ns.range(of: find, options: .caseInsensitive, range: NSRange(location: loc, length: ns.length - loc))
                if r.location == NSNotFound || r.length == 0 { break }
                hits.append(r); loc = NSMaxRange(r)
            }
        }
        for r in hits { lm.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.45), forCharacterRange: r) }
        if !hits.isEmpty {
            let cur = hits[min(max(0, index), hits.count - 1)]
            lm.addTemporaryAttribute(.backgroundColor, value: NSColor.systemOrange.withAlphaComponent(0.85), forCharacterRange: cur)
            if scroll { tv.scrollRangeToVisible(cur) }
        }
        previous = hits
        return hits.count
    }
}

// MARK: Read-only selectable text for big responses
// TextKit 1 with non-contiguous layout: only what is on screen is laid out, so a multi-megabyte body opens at once and scrolls smoothly.
// Colours are layout-manager "temporary attributes" (no text-storage edits, no re-layout) and are computed off the main thread, then
// applied only to the part around the viewport as you scroll. Spell checking, link / data detection are off (they crawl on big texts).
struct CodeText: NSViewRepresentable {
    let text: String
    var syntax: Syntax = .plain
    var size: CGFloat = 11
    var find = ""                                 // case-insensitive; all hits are marked, the current one is scrolled to
    var findIndex = 0
    var onCount: ((Int) -> Void)? = nil
    static let cap = 40_000_000                   // bytes shown at most (the runner hands over up to 32 M characters)
    static let colourCap = 8_000_000              // longer texts are shown without syntax colours

    final class Coord: NSObject, @unchecked Sendable {
        var last: String?; var lastSyntax: Syntax?; var lastFind = ""; var lastIdx = -1
        var marks: [NSRange] = []                 // ranges of the current find hits
        var spans: [(NSRange, NSColor)] = []      // sorted by location
        var applied = Set<Int>()                  // chunks (of `chunk` characters) that are coloured already
        var gen = 0                               // bumped with every new text: late results of the colouring task are dropped
        static let chunk = 30_000
        weak var scroll: NSScrollView?

        @objc func scrolled() { applyVisible() }

        /// Colours the chunks around the visible part (one chunk of margin on both sides).
        func applyVisible() {
            guard !spans.isEmpty, let sv = scroll, let tv = sv.documentView as? NSTextView,
                  let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            let o = tv.textContainerOrigin
            let rect = sv.documentVisibleRect.offsetBy(dx: -o.x, dy: -o.y)
            let g = lm.glyphRange(forBoundingRect: rect, in: tc)
            let chars = lm.characterRange(forGlyphRange: g, actualGlyphRange: nil)
            let first = max(0, chars.location / Self.chunk - 1), last = NSMaxRange(chars) / Self.chunk + 1
            let total = (tv.string as NSString).length
            for k in first...max(first, last) where !applied.contains(k) && k * Self.chunk < total {
                applied.insert(k)
                let lo = k * Self.chunk, hi = lo + Self.chunk
                // first span that starts in this chunk (binary search)
                var a = 0, b = spans.count
                while a < b { let m = (a + b) / 2; if spans[m].0.location < lo { a = m + 1 } else { b = m } }
                var i = a
                while i < spans.count, spans[i].0.location < hi {
                    let (r, c) = spans[i]
                    if NSMaxRange(r) <= total { lm.addTemporaryAttribute(.foregroundColor, value: c, forCharacterRange: r) }
                    i += 1
                }
            }
        }
    }
    func makeCoordinator() -> Coord { Coord() }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let lm = NSLayoutManager()
        lm.allowsNonContiguousLayout = true
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        tc.widthTracksTextView = true
        lm.addTextContainer(tc)
        let tv = NSTextView(frame: .zero, textContainer: tc)
        tv.isEditable = false; tv.isSelectable = true; tv.isRichText = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.isVerticallyResizable = true; tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.isContinuousSpellCheckingEnabled = false; tv.isGrammarCheckingEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false; tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false; tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false; tv.isAutomaticDashSubstitutionEnabled = false
        tv.smartInsertDeleteEnabled = false; tv.usesFindBar = false
        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true; sv.hasHorizontalScroller = false; sv.autohidesScrollers = true
        sv.drawsBackground = true; sv.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.08)
        sv.borderType = .noBorder
        sv.contentView.postsBoundsChangedNotifications = true
        context.coordinator.scroll = sv
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coord.scrolled), name: NSView.boundsDidChangeNotification, object: sv.contentView)
        return sv
    }
    static func dismantleNSView(_ sv: NSScrollView, coordinator: Coord) {
        NotificationCenter.default.removeObserver(coordinator)
        coordinator.gen += 1
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? NSTextView, let lm = tv.layoutManager, let storage = tv.textStorage else { return }
        let c = context.coordinator
        let changed = c.last != text || c.lastSyntax != syntax
        if changed {
            c.last = text; c.lastSyntax = syntax
            c.gen += 1; c.spans = []; c.applied = []; c.marks = []
            lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: (tv.string as NSString).length))
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: (tv.string as NSString).length))
            var shown = text
            if shown.utf8.count > Self.cap {
                shown = String(shown.prefix(Self.cap)) + L("\n\n… truncated: showing %ld of %ld characters", Self.cap, text.utf16.count)
            }
            tv.string = shown.isEmpty ? " " : shown
            storage.setAttributes([.font: Highlighter.font(size), .foregroundColor: NSColor.labelColor], range: NSRange(location: 0, length: storage.length))
            tv.scrollToBeginningOfDocument(nil)
            if storage.length <= Highlighter.cap, shown.contains("{{"), let re = try? NSRegularExpression(pattern: "\\{\\{([^}\\n]*)\\}\\}") {
                let ns = shown as NSString          // {{variables}}: orange when known, red when not
                for m in re.matches(in: shown, range: NSRange(location: 0, length: ns.length)) {
                    let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                    let ok = name.hasPrefix("$") || Highlighter.knownLower.contains(name.lowercased())
                    let fg = ok ? Highlighter.cVar : NSColor.systemRed
                    lm.addTemporaryAttributes([.foregroundColor: fg, .backgroundColor: fg.withAlphaComponent(ok ? 0.16 : 0.12)], forCharacterRange: m.range)
                }
            }
            if syntax != .plain, storage.length <= Self.colourCap {
                let g = c.gen, t = shown, s = syntax
                Task.detached(priority: .userInitiated) {
                    let sp = Highlighter.spans(t, s).enumerated().sorted {
                        $0.element.0.location != $1.element.0.location ? $0.element.0.location < $1.element.0.location : $0.offset < $1.offset
                    }.map { $0.element }
                    await MainActor.run { guard c.gen == g else { return }; c.spans = sp; c.applyVisible() }
                }
            }
        }
        if changed || c.lastFind != find || c.lastIdx != findIndex {
            c.lastFind = find; c.lastIdx = findIndex
            let n = FindMarks.apply(tv, find: find, index: findIndex, scroll: true, previous: &c.marks)
            if let onCount { DispatchQueue.main.async { onCount(n) } }
        }
    }
}

/// The find field: text, "n/m", previous / next, clear.
struct FindBar: View {
    @Binding var q: String
    @Binding var idx: Int
    let count: Int
    var focus: FocusState<Bool>.Binding
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in text", text: $q).textFieldStyle(.plain).focused(focus)
                .onSubmit { step(1); focus.wrappedValue = true }
            if !q.isEmpty {
                Text(count == 0 ? "0" : "\(idx + 1)/\(count)").font(.caption.monospacedDigit()).foregroundStyle(count == 0 ? Color.red : Color.secondary)
                Button { step(-1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled(count == 0)
                Button { step(1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).disabled(count == 0)
                CloseButton(help: "Clear") { q = "" }
            }
        }
        .padding(5).background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
    }
    private func step(_ d: Int) { guard count > 0 else { return }; idx = (idx + d + count) % count }
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
            FindBar(q: $q, idx: $idx, count: count, focus: $fieldFocus)
            CodeText(text: text, syntax: syntax, size: 12, find: q, findIndex: idx, onCount: { n in
                count = n; if idx >= n { idx = 0 }
            })
        }
        .onChange(of: q) { idx = 0 }
        .onChange(of: store.focusFind) {
            // ⌘F inside the body editor belongs to the editor's own find field
            if store.bodyFinds > 0, NSApp.keyWindow?.firstResponder is CommentTextView { return }
            fieldFocus = true
        }
        .onAppear { store.findPanes += 1 }
        .onDisappear { store.findPanes -= 1 }
    }
}

/// The editable raw body with a find field above it.
struct FoundEditor: View {
    @EnvironmentObject var store: Store
    @Binding var text: String
    var syntax: Syntax = .plain
    var autofocus = false
    @State private var q = ""
    @State private var idx = 0
    @State private var count = 0
    @FocusState private var fieldFocus: Bool

    var body: some View {
        VStack(spacing: 4) {
            FindBar(q: $q, idx: $idx, count: count, focus: $fieldFocus)
            CodeEditor(text: $text, syntax: syntax, autofocus: autofocus, find: q, findIndex: idx, onCount: { n in
                count = n; if idx >= n { idx = 0 }
            }).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: q) { idx = 0 }
        .onChange(of: store.focusFind) {
            if NSApp.keyWindow?.firstResponder is CommentTextView || store.findPanes == 1 { fieldFocus = true }
        }
        .onAppear { store.findPanes += 1; store.bodyFinds += 1 }
        .onDisappear { store.findPanes -= 1; store.bodyFinds -= 1 }
    }
}

/// Kept for older call sites.
typealias HistoryText = CodeText

// MARK: Copyable text block with a button (curl panel)
/// The one close / clear cross used everywhere (result pane, curl panel, search fields, file and folder fields).
struct CloseButton: View {
    var help: LocalizedStringKey = "Close"
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.borderless).foregroundStyle(.secondary).help(help)
    }
}

struct CopyButton: View {
    var title: LocalizedStringKey = "Copy"
    var curl = false                       // "Copy as curl": shown as </>
    let text: () -> String
    @State private var done = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text(), forType: .string)
            done = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { done = false }
        } label: {
            if curl { if done { Image(systemName: "checkmark") } else { Text("</>").font(.system(.body, design: .monospaced).bold()) } }
            else { Label(done ? LocalizedStringKey("Copied") : title, systemImage: done ? "checkmark" : "doc.on.doc") }
        }
        .help(curl ? LocalizedStringKey("Copy as curl") : "")
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

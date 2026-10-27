import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: Pin-to-bottom behaviour shared by all log-like panels
//
// • The user is at the bottom → the view follows new lines.
// • The user scrolls up → the visible section stays exactly where it is; new lines are appended below the viewport.
// • The user scrolls back to the bottom → following resumes.

@MainActor
class PinCoordinator: NSObject {
    private(set) var pinned = true
    private var programmatic = false          // our own scrolling must not be mistaken for the user's
    private var lastY: CGFloat = 0
    private weak var scroll: NSScrollView?

    var offsetY: CGFloat { scroll?.contentView.bounds.origin.y ?? 0 }

    func attach(_ sv: NSScrollView) {
        scroll = sv
        sv.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: sv.contentView)
    }
    func detach() { NotificationCenter.default.removeObserver(self) }
    func repin() { pinned = true }            // new run / cleared log: start following again

    @objc private func boundsChanged(_ note: Notification) {
        guard !programmatic, let sv = scroll, let doc = sv.documentView else { return }
        let b = sv.contentView.bounds
        guard abs(b.origin.y - lastY) > 0.5 else { return }            // resizing the window is not a scroll
        lastY = b.origin.y
        pinned = b.maxY >= doc.frame.height - 4
    }
    func scrollToBottom(_ tv: NSTextView) {
        scrollNow(tv)
        // TextKit lays out the appended text lazily: once more on the next run-loop turn, when the real height is known,
        // otherwise the view can stay one step behind the newest line.
        DispatchQueue.main.async { [weak self, weak tv] in
            guard let self, let tv, self.pinned else { return }
            self.scrollNow(tv)
        }
    }
    private func scrollNow(_ tv: NSTextView) {
        programmatic = true
        tv.scrollToEndOfDocument(nil)
        lastY = offsetY
        programmatic = false
    }
    func restoreOffset(_ y: CGFloat) {
        guard let sv = scroll else { return }
        programmatic = true
        sv.contentView.scroll(to: NSPoint(x: sv.contentView.bounds.origin.x, y: y))
        sv.reflectScrolledClipView(sv.contentView)
        lastY = y
        programmatic = false
    }
}

@MainActor
private func makeLogScrollView() -> NSScrollView {
    let sv = NSTextView.scrollableTextView()
    let tv = sv.documentView as! NSTextView
    tv.isEditable = false; tv.isSelectable = true; tv.isRichText = true
    tv.drawsBackground = false; sv.drawsBackground = false
    tv.textContainerInset = NSSize(width: 6, height: 6)
    return sv
}

/// Global log: one NSTextView, so any range of lines can be selected and copied (⌘A, ⌘C).
struct SelectableLog: NSViewRepresentable {
    let items: [LogEntry]
    final class Coord: PinCoordinator { var rendered: [UUID] = [] }
    func makeCoordinator() -> Coord { Coord() }
    func makeNSView(context: Context) -> NSScrollView {
        let sv = makeLogScrollView(); context.coordinator.attach(sv); return sv
    }
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coord) { coordinator.detach() }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? NSTextView, let ts = tv.textStorage else { return }
        let c = context.coordinator
        let ids = items.map(\.id)
        if ids == c.rendered { return }
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        func attr(_ e: LogEntry) -> NSAttributedString {
            NSAttributedString(string: e.line + "\n", attributes: [.font: font, .foregroundColor: Self.color(e.level)])
        }
        if ids.count >= c.rendered.count, Array(ids.prefix(c.rendered.count)) == c.rendered {
            for e in items[c.rendered.count...] { ts.append(attr(e)) }       // append only: selection and scroll position survive
        } else {
            let y = c.offsetY
            if ids.isEmpty { c.repin() }
            ts.setAttributedString(NSAttributedString()); items.forEach { ts.append(attr($0)) }
            if !c.pinned { c.restoreOffset(y) }                              // filter changed: stay on the same section
        }
        c.rendered = ids
        if c.pinned { c.scrollToBottom(tv) }
    }
    static func color(_ l: LogLevel) -> NSColor {
        switch l { case .debug: .secondaryLabelColor; case .info: .labelColor; case .warn: .systemOrange; case .error: .systemRed }
    }
}

/// Plain growing text (the Runner's live output) with the same pin-to-bottom behaviour.
struct PinnedText: NSViewRepresentable {
    let text: String
    final class Coord: PinCoordinator { var rendered = "" }
    func makeCoordinator() -> Coord { Coord() }
    func makeNSView(context: Context) -> NSScrollView {
        let sv = makeLogScrollView(); context.coordinator.attach(sv); return sv
    }
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coord) { coordinator.detach() }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? NSTextView, let ts = tv.textStorage else { return }
        let c = context.coordinator
        if text == c.rendered { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                                                    .foregroundColor: NSColor.labelColor]
        if !c.rendered.isEmpty, text.hasPrefix(c.rendered) {
            ts.append(NSAttributedString(string: String(text.dropFirst(c.rendered.count)), attributes: attrs))
        } else {
            let y = c.offsetY
            if text.isEmpty { c.repin() }
            ts.setAttributedString(NSAttributedString(string: text, attributes: attrs))
            if !c.pinned { c.restoreOffset(y) }
        }
        c.rendered = text
        if c.pinned { c.scrollToBottom(tv) }
    }
}

// MARK: Runner results list (SwiftUI ScrollView, macOS 15 scroll APIs)

struct ScrollMetrics: Equatable { var maxY: CGFloat; var content: CGFloat }

struct ResultsList: View {
    let results: [ExecResult]
    @Binding var picked: ExecResult.ID?
    var onUserPick: () -> Void = {}
    @State private var pinned = true
    @State private var position = ScrollPosition(edge: .bottom)

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(results) { r in row(r) }
            }
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: ScrollMetrics.self, of: { g in
            ScrollMetrics(maxY: g.visibleRect.maxY, content: g.contentSize.height)
        }, action: { old, new in
            // content grew → keep following if we were pinned; otherwise this is the user scrolling
            if new.content != old.content { if pinned { position.scrollTo(edge: .bottom) } }
            else { pinned = new.maxY >= new.content - 12 }
        })
        .onChange(of: results.isEmpty) { if results.isEmpty { pinned = true } }       // a new run starts pinned
        .background(Color.secondary.opacity(0.06))
    }

    @ViewBuilder private func row(_ r: ExecResult) -> some View {
        let sel = picked == r.id
        HStack {
            Text("#\(r.iteration)").foregroundStyle(.secondary)
            Text(r.method).font(.caption.monospaced()).frame(width: 44, alignment: .leading)
            Text(r.name).lineLimit(1)
            Spacer()
            if !r.failures.isEmpty { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            Text(r.code == 0 ? "ERR" : "\(r.code)").foregroundStyle(r.code >= 200 && r.code < 400 ? Color.green : Color.red).monospacedDigit()
            Text("\(r.time) ms").foregroundStyle(.secondary).font(.caption)
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(sel ? Color.accentColor.opacity(0.25) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { picked = r.id; onUserPick() }
    }
}

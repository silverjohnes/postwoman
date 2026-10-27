import SwiftUI
import AppKit

/// Plain-text code editor (NSTextView): no smart quotes/dashes/autocorrect (they break JavaScript), monospaced, undo, wraps lines.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var syntax: Syntax = .plain
    var autofocus = false

    final class Coord: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        var shown: Syntax?
        /// Each editor owns its undo stack. With the window's shared manager, entries of an editor that SwiftUI has already destroyed
        /// (switching requests, ⌘Z of the request tree) pointed at freed memory and crashed on the next ⌘Z.
        let undo = UndoManager()
        init(_ p: CodeEditor) { parent = p }
        func undoManager(for view: NSTextView) -> UndoManager? { undo }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            if parent.text != tv.string { parent.text = tv.string }
            if !tv.hasMarkedText(), let st = tv.textStorage { Highlighter.apply(to: st, syntax: parent.syntax, size: 12) }
        }
    }
    func makeCoordinator() -> Coord { Coord(self) }
    static func dismantleNSView(_ sv: NSScrollView, coordinator: Coord) {
        coordinator.undo.removeAllActions()
        (sv.documentView as? NSTextView)?.delegate = nil
    }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true; sv.hasHorizontalScroller = false; sv.autohidesScrollers = true; sv.borderType = .lineBorder
        let tv = CommentTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        tv.minSize = NSSize(width: 0, height: 0); tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true; tv.isHorizontallyResizable = false; tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true; tv.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        sv.documentView = tv
        tv.commentable = syntax == .javascript
        tv.delegate = context.coordinator
        tv.isRichText = false; tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textColor = .labelColor
        tv.drawsBackground = true; tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.string = text
        if let st = tv.textStorage { Highlighter.apply(to: st, syntax: syntax, size: 12) }
        if autofocus {
            DispatchQueue.main.async { sv.window?.makeFirstResponder(tv); tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0)) }
        }
        return sv
    }
    func updateNSView(_ sv: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = sv.documentView as? NSTextView else { return }
        (tv as? CommentTextView)?.commentable = syntax == .javascript
        if tv.string == text {
            if context.coordinator.shown != syntax, let st = tv.textStorage { context.coordinator.shown = syntax; Highlighter.apply(to: st, syntax: syntax, size: 12) }
            return
        }
        context.coordinator.shown = syntax
        context.coordinator.undo.removeAllActions()                // the text was replaced from outside: old typing history no longer matches
        let sel = tv.selectedRange()
        tv.string = text
        if let st = tv.textStorage { Highlighter.apply(to: st, syntax: syntax, size: 12) }
        tv.setSelectedRange(NSRange(location: min(sel.location, (text as NSString).length), length: 0))
    }
}

/// NSTextView that toggles `//` comments on the selected lines with ⌘/ (in scripts). Handled here, as a key equivalent, so the system never sees the shortcut
/// (it must not leave full-screen mode). Works on any keyboard layout: the physical "/" key is matched by key code.
final class CommentTextView: NSTextView {
    var commentable = false
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if commentable, mods == .command, e.keyCode == 44 || e.charactersIgnoringModifiers == "/", window?.firstResponder === self {
            toggleComment(); return true
        }
        return super.performKeyEquivalent(with: e)
    }
    func toggleComment() {
        let ns = string as NSString
        let sel = selectedRange()
        var probe = sel
        if sel.length > 0, ns.character(at: NSMaxRange(sel) - 1) == 10 { probe.length -= 1 }      // a selection that ends right after a line break does not include the next line
        let lr = ns.lineRange(for: probe)
        let hadNewline = lr.length > 0 && ns.character(at: NSMaxRange(lr) - 1) == 10
        var lines = ns.substring(with: lr).components(separatedBy: "\n")
        if hadNewline { lines.removeLast() }
        func lead(_ l: String) -> Int { l.prefix { $0 == " " || $0 == "\t" }.count }
        let filled = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        let allCommented = !filled.isEmpty && filled.allSatisfy { lines[$0].dropFirst(lead(lines[$0])).hasPrefix("//") }
        if allCommented {
            for i in filled {
                var l = lines[i]; let at = l.index(l.startIndex, offsetBy: lead(l))
                var end = l.index(at, offsetBy: 2)
                if end < l.endIndex, l[end] == " " { end = l.index(after: end) }
                l.removeSubrange(at..<end); lines[i] = l
            }
        } else if !filled.isEmpty {
            let indent = filled.map { lead(lines[$0]) }.min() ?? 0
            for i in filled { var l = lines[i]; l.insert(contentsOf: "// ", at: l.index(l.startIndex, offsetBy: indent)); lines[i] = l }
        } else { return }
        let new = lines.joined(separator: "\n") + (hadNewline ? "\n" : "")
        guard shouldChangeText(in: lr, replacementString: new) else { return }
        replaceCharacters(in: lr, with: new)                      // goes through the undo manager: ⌘Z reverts the whole toggle
        didChangeText()
        let newLen = (new as NSString).length
        if sel.length == 0 { setSelectedRange(NSRange(location: max(lr.location, min(lr.location + newLen, sel.location + newLen - lr.length)), length: 0)) }
        else { setSelectedRange(NSRange(location: lr.location, length: newLen - (hadNewline ? 1 : 0))) }
    }
}

/// One script tab: explanation line + editor.
struct ScriptPane: View {
    @Binding var text: String
    let title: String
    let hint: LocalizedStringKey
    var autofocus = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title).bold()
                Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Text(L("%ld line(s)", text.isEmpty ? 0 : text.components(separatedBy: "\n").count)).font(.caption).foregroundStyle(.secondary)
            }
            CodeEditor(text: $text, syntax: .javascript, autofocus: autofocus).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

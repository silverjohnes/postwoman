import SwiftUI
import AppKit

/// Single-line text field (URL, header and parameter rows) that draws {{variables}} on a coloured background:
/// orange = defined (Globals, a script sets it, or a {{$dynamic}} one), red = not found anywhere.
struct VarField: NSViewRepresentable {
    @Binding var text: String
    var placeholder = ""
    var mono = false
    var autofocus = false

    final class Coord: NSObject, NSTextFieldDelegate {
        var parent: VarField
        var known: Set<String> = []
        var focused = false
        init(_ p: VarField) { parent = p }
        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            if parent.text != f.stringValue { parent.text = f.stringValue }
            restyle(f)
        }
        func restyle(_ f: NSTextField) {
            if let ed = f.currentEditor() as? NSTextView, let st = ed.textStorage {
                let full = NSRange(location: 0, length: st.length)
                st.removeAttribute(.backgroundColor, range: full)
                st.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
                Highlighter.styleVars(st)
            } else {
                let m = NSMutableAttributedString(string: f.stringValue, attributes: [.font: f.font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
                Highlighter.styleVars(m)
                f.attributedStringValue = m
            }
            known = Highlighter.known
        }
    }
    func makeCoordinator() -> Coord { Coord(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = true; f.bezelStyle = .roundedBezel; f.isEditable = true
        f.usesSingleLineMode = true; f.cell?.wraps = false; f.cell?.isScrollable = true; f.lineBreakMode = .byTruncatingTail
        f.placeholderString = placeholder
        f.font = mono ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) : NSFont.systemFont(ofSize: 13)
        f.delegate = context.coordinator
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        f.stringValue = text
        context.coordinator.restyle(f)
        return f
    }
    func updateNSView(_ f: NSTextField, context: Context) {
        let c = context.coordinator
        c.parent = self
        if f.stringValue != text { f.stringValue = text; c.restyle(f) }
        else if c.known != Highlighter.known { c.restyle(f) }
        if autofocus && !c.focused {
            c.focused = true
            DispatchQueue.main.async { f.window?.makeFirstResponder(f) }
        }
    }
}

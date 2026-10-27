import AppKit

/// What a text view shows: decides how it is coloured.
enum Syntax {
    case plain, json, javascript, headers, curl
    case http        // request/response: first line, `Name: value` headers, blank line, body (JSON is coloured)
}

/// Small hand-written tokenizer (no dependencies): colours JSON, JavaScript, HTTP headers and curl.
/// Colours are system colours, so they follow light/dark mode. Very large texts stay uncoloured (speed).
enum Highlighter {
    static let cap = 250_000
    /// Variable names that exist (Globals + names set by scripts); {{others}} are drawn red. Maintained by the Store.
    static var known: Set<String> = []
    static func font(_ size: CGFloat) -> NSFont { NSFont.monospacedSystemFont(ofSize: size, weight: .regular) }

    private static let cKeyword = NSColor.systemPink
    private static let cString = NSColor.systemGreen
    private static let cNumber = NSColor.systemBlue
    private static let cComment = NSColor.secondaryLabelColor
    private static let cKey = NSColor.systemTeal
    private static let cBuiltin = NSColor.systemPurple
    private static let cVar = NSColor.systemOrange
    private static let cFlag = NSColor.systemIndigo

    private static let jsKeywords: Set<String> = ["const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "break", "continue",
        "new", "try", "catch", "finally", "throw", "typeof", "instanceof", "in", "of", "async", "await", "class", "extends", "true", "false", "null", "undefined",
        "this", "delete", "void", "yield", "import", "export", "default"]
    private static let builtins: Set<String> = ["pm", "console", "JSON", "Math", "Object", "Array", "Date", "Promise", "require", "String", "Number", "Boolean", "atob", "btoa", "encodeURIComponent", "decodeURIComponent", "parseInt", "parseFloat"]
    private static let methods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "HTTP"]

    /// Re-colours the whole storage. Selection and text are untouched.
    static func apply(to storage: NSTextStorage, syntax: Syntax, size: CGFloat) {
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        storage.beginEditing()
        storage.setAttributes([.font: font(size), .foregroundColor: NSColor.labelColor], range: full)
        if syntax != .plain && ns.length <= cap {
            for (r, c) in spans(storage.string, syntax) where NSMaxRange(r) <= ns.length { storage.addAttribute(.foregroundColor, value: c, range: r) }
        }
        if ns.length <= cap { styleVars(storage) }
        storage.endEditing()
    }

    static func spans(_ text: String, _ syntax: Syntax) -> [(NSRange, NSColor)] {
        let u = Array(text.utf16)
        var out: [(NSRange, NSColor)] = []
        switch syntax {
        case .plain: break
        case .json: code(u, 0, u.count, js: false, &out)
        case .javascript: code(u, 0, u.count, js: true, &out)
        case .headers: headerLines(u, 0, u.count, &out)
        case .curl: curl(u, &out)
        case .http: http(u, &out)
        }
        return out
    }

    /// {{name}} on a tinted background: orange when the variable exists, red when it does not.
    static func styleVars(_ m: NSMutableAttributedString) {
        let s = m.string
        guard s.contains("{{"), let re = try? NSRegularExpression(pattern: "\\{\\{([^}\\n]*)\\}\\}") else { return }
        let ns = s as NSString
        for r in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: r.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let ok = name.hasPrefix("$") || known.contains(name)
            let fg = ok ? cVar : NSColor.systemRed
            m.addAttributes([.foregroundColor: fg, .backgroundColor: fg.withAlphaComponent(ok ? 0.16 : 0.12)], range: r.range)
        }
    }

    // MARK: helpers
    private static func isIdentStart(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 }
    private static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    private static func isIdent(_ c: UInt16) -> Bool { isIdentStart(c) || isDigit(c) }
    private static func str(_ u: [UInt16], _ a: Int, _ b: Int) -> String { String(decoding: u[a..<b], as: UTF16.self) }

    // MARK: JSON / JavaScript
    private static func code(_ u: [UInt16], _ from: Int, _ to: Int, js: Bool, _ out: inout [(NSRange, NSColor)]) {
        var i = from
        while i < to {
            let c = u[i]
            if c == 47, i + 1 < to, u[i + 1] == 47 {                       // // comment
                var j = i; while j < to, u[j] != 10 { j += 1 }
                out.append((NSRange(location: i, length: j - i), cComment)); i = j
            } else if c == 47, i + 1 < to, u[i + 1] == 42 {                // /* comment */
                var j = i + 2; while j + 1 < to, !(u[j] == 42 && u[j + 1] == 47) { j += 1 }
                j = min(to, j + 2)
                out.append((NSRange(location: i, length: j - i), cComment)); i = j
            } else if c == 34 || c == 39 || c == 96 {                      // string
                var j = i + 1
                while j < to {
                    if u[j] == 92 { j += 2; continue }
                    if u[j] == c { j += 1; break }
                    if u[j] == 10 && c != 96 { break }
                    j += 1
                }
                j = min(j, to)
                var color = cString
                if !js {                                                    // JSON object key: a string followed by ':'
                    var k = j; while k < to, u[k] == 32 || u[k] == 9 { k += 1 }
                    if k < to, u[k] == 58 { color = cKey }
                }
                out.append((NSRange(location: i, length: j - i), color)); i = j
            } else if isDigit(c) || (c == 45 && i + 1 < to && isDigit(u[i + 1])) {
                var j = i + 1; while j < to, isIdent(u[j]) || u[j] == 46 { j += 1 }
                out.append((NSRange(location: i, length: j - i), cNumber)); i = j
            } else if isIdentStart(c) {
                var j = i + 1; while j < to, isIdent(u[j]) { j += 1 }
                let w = str(u, i, j)
                if jsKeywords.contains(w) { out.append((NSRange(location: i, length: j - i), cKeyword)) }
                else if js, builtins.contains(w) { out.append((NSRange(location: i, length: j - i), cBuiltin)) }
                else if !js {                                               // bare word in JSON: only a {{var}} or a typo
                } else {
                    var k = j; while k < to, u[k] == 32 { k += 1 }
                    if k < to, u[k] == 40 { out.append((NSRange(location: i, length: j - i), cKey)) }   // function call
                }
                i = j
            } else { i += 1 }
        }
    }

    // MARK: `Name: value` lines
    private static func headerLines(_ u: [UInt16], _ from: Int, _ to: Int, _ out: inout [(NSRange, NSColor)]) {
        var i = from
        while i < to {
            var e = i; while e < to, u[e] != 10 { e += 1 }
            var k = i; while k < e, u[k] != 58 { k += 1 }
            if k < e, k > i { out.append((NSRange(location: i, length: k - i), cKey)) }
            i = e + 1
        }
    }

    // MARK: HTTP message
    private static func http(_ u: [UInt16], _ out: inout [(NSRange, NSColor)]) {
        var i = 0, first = true
        while i < u.count {
            var e = i; while e < u.count, u[e] != 10 { e += 1 }
            if e == i {                                                     // blank line → body
                var b = e + 1; while b < u.count, u[b] == 10 || u[b] == 13 || u[b] == 32 { b += 1 }
                if b < u.count, u[b] == 123 || u[b] == 91 { code(u, b, u.count, js: false, &out) }
                return
            }
            if first {
                var w = i; while w < e, u[w] != 32 { w += 1 }
                if methods.contains(str(u, i, w)) { out.append((NSRange(location: i, length: w - i), cKeyword)) }
                if w < e { out.append((NSRange(location: w, length: e - w), cNumber)) }
                first = false
            } else {
                var k = i; while k < e, u[k] != 58 { k += 1 }
                if k < e, k > i { out.append((NSRange(location: i, length: k - i), cKey)) }
            }
            i = e + 1
        }
    }

    // MARK: curl
    private static func curl(_ u: [UInt16], _ out: inout [(NSRange, NSColor)]) {
        var i = 0
        while i < u.count {
            let c = u[i]
            if c == 39 {                                                    // '…'
                var j = i + 1; while j < u.count, u[j] != 39 { j += 1 }
                j = min(u.count, j + 1)
                out.append((NSRange(location: i, length: j - i), cString)); i = j
            } else if c == 45, i == 0 || u[i - 1] == 32 {                   // --flag / -X
                var j = i; while j < u.count, u[j] != 32, u[j] != 10 { j += 1 }
                out.append((NSRange(location: i, length: j - i), cFlag)); i = j
            } else if isIdentStart(c), i == 0 || u[i - 1] == 10 || u[i - 1] == 32 {
                var j = i; while j < u.count, isIdent(u[j]) { j += 1 }
                if str(u, i, j) == "curl" { out.append((NSRange(location: i, length: j - i), cKeyword)) }
                i = j
            } else { i += 1 }
        }
    }
}

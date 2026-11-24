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
    static var known: Set<String> = [] { didSet { knownLower = Set(known.map { $0.lowercased() }) } }
    private(set) static var knownLower: Set<String> = []          // variable names are not case sensitive
    static func font(_ size: CGFloat) -> NSFont { NSFont.monospacedSystemFont(ofSize: size, weight: .regular) }

    /// Colours of the current code theme (Settings → Appearance). Set by `setTheme`; the colours are dynamic: they follow light / dark mode.
    static var palette = CodePalette.named(UserDefaults.standard.string(forKey: "codeTheme") ?? "default")
    static func setTheme(_ id: String) { palette = CodePalette.named(id) }
    private static var cKeyword: NSColor { palette.keyword }
    private static var cString: NSColor { palette.string }
    private static var cNumber: NSColor { palette.number }
    private static var cComment: NSColor { palette.comment }
    private static var cKey: NSColor { palette.key }
    private static var cBuiltin: NSColor { palette.builtin }
    static var cVar: NSColor { palette.variable }
    private static var cFlag: NSColor { palette.flag }

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
        if ns.length <= cap {
            styleVars(storage)
            for r in linkRanges(storage.string) { storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r) }      // links (⌘-click opens them)
        }
        storage.endEditing()
    }

    /// http(s) links in the text (not before a {{variable}}, without trailing punctuation). Same rules as ⌘-click.
    static func linkRanges(_ text: String) -> [NSRange] {
        guard text.contains("http"), let re = try? NSRegularExpression(pattern: "https?://[^\\s\"'<>`{}|\\\\^]+") else { return [] }
        let ns = text as NSString
        var out: [NSRange] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).prefix(5000) {
            var r = m.range
            while r.length > 0, ".,;:!?)]".contains(Character(UnicodeScalar(ns.character(at: NSMaxRange(r) - 1)) ?? " ")) { r.length -= 1 }
            if r.length <= 8 || (NSMaxRange(r) < ns.length && ns.character(at: NSMaxRange(r)) == 0x7B) { continue }
            out.append(r)
        }
        return out
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
            let ok = name.hasPrefix("$") || knownLower.contains(name.lowercased())
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

extension Notification.Name { static let codeThemeChanged = Notification.Name("PostwomanCodeThemeChanged") }

/// Light / Dark / System for the whole app (native NSAppearance, so menus, dialogs and scrollers follow too).
enum AppAppearance {
    static func apply(_ raw: String) {
        NSApp?.appearance = raw == "light" ? NSAppearance(named: .aqua) : raw == "dark" ? NSAppearance(named: .darkAqua) : nil
    }
    static func applySaved() { apply(UserDefaults.standard.string(forKey: "appearance") ?? "system") }
}

/// Colours of one code theme: every colour has a light and a dark variant.
struct CodePalette: Identifiable {
    let id: String, title: String
    let keyword, string, number, comment, key, builtin, variable, flag: NSColor

    private static func dyn(_ light: UInt32, _ dark: UInt32) -> NSColor {
        func c(_ h: UInt32) -> NSColor { NSColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: 1) }
        let l = c(light), d = c(dark)
        return NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l }
    }
    static let all: [CodePalette] = [
        CodePalette(id: "default", title: "Default", keyword: .systemPink, string: .systemGreen, number: .systemBlue, comment: .secondaryLabelColor,
                    key: .systemTeal, builtin: .systemPurple, variable: .systemOrange, flag: .systemIndigo),
        CodePalette(id: "xcode", title: "Xcode",
                    keyword: dyn(0xAD3DA4, 0xFC5FA3), string: dyn(0xD12F1B, 0xFC6A5D), number: dyn(0x272AD8, 0xD0BF69), comment: dyn(0x707F8C, 0x7F8C98),
                    key: dyn(0x3E8087, 0x67B7A4), builtin: dyn(0x4B21B0, 0xA167E6), variable: dyn(0x9B5A1A, 0xFD8F3F), flag: dyn(0x6C36A9, 0xD0A8FF)),
        CodePalette(id: "solarized", title: "Solarized",
                    keyword: dyn(0x859900, 0x859900), string: dyn(0x2AA198, 0x2AA198), number: dyn(0xD33682, 0xD33682), comment: dyn(0x93A1A1, 0x657B83),
                    key: dyn(0x268BD2, 0x268BD2), builtin: dyn(0x6C71C4, 0x6C71C4), variable: dyn(0xCB4B16, 0xCB4B16), flag: dyn(0xB58900, 0xB58900)),
        CodePalette(id: "dracula", title: "Dracula",
                    keyword: dyn(0xA3144D, 0xFF79C6), string: dyn(0x846E15, 0xF1FA8C), number: dyn(0x644AC9, 0xBD93F9), comment: dyn(0x6C664B, 0x6272A4),
                    key: dyn(0x036A96, 0x8BE9FD), builtin: dyn(0x14710A, 0x50FA7B), variable: dyn(0xA34D14, 0xFFB86C), flag: dyn(0xCB3A2A, 0xFF5555)),
        CodePalette(id: "monokai", title: "Monokai",
                    keyword: dyn(0xD6246E, 0xF92672), string: dyn(0x998A00, 0xE6DB74), number: dyn(0x7E57C2, 0xAE81FF), comment: dyn(0x8A8A7A, 0x88846F),
                    key: dyn(0x0B8FB0, 0x66D9EF), builtin: dyn(0x5E9E00, 0xA6E22E), variable: dyn(0xD17000, 0xFD971F), flag: dyn(0xC75D00, 0xE69F66)),
    ]
    static func named(_ id: String) -> CodePalette { all.first { $0.id == id } ?? all[0] }
}

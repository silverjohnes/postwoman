import Foundation

/// Pretty-printer that keeps key order and leaves {{variables}} (even unquoted) untouched.
/// `//` comments (whole lines and trailing ones) are copied exactly as written: they are never re-indented,
/// never changed and never reported as errors.
enum JSONFormat {
    /// The text without `//` comments (outside of strings and {{variables}}). Used for validation and when a request is sent;
    /// the stored body keeps its comments.
    static func withoutComments(_ s: String) -> String {
        let ch = Array(s); var out = "", inString = false, escaped = false, i = 0
        while i < ch.count {
            let c = ch[i]
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true; out.append(c)
            } else if c == "{", i + 1 < ch.count, ch[i + 1] == "{" {      // {{variable}}: copied as is
                var j = i + 2
                while j + 1 < ch.count, !(ch[j] == "}" && ch[j + 1] == "}") { j += 1 }
                if j + 1 < ch.count { out += String(ch[i...(j + 1)]); i = j + 2; continue }
                out.append(c)
            } else if c == "/", i + 1 < ch.count, ch[i + 1] == "/" {
                while i < ch.count, !ch[i].isNewline { i += 1 }       // skip to the end of the line (\n, \r or \r\n), keep the newline
                continue
            } else {
                out.append(c)
            }
            i += 1
        }
        return out
    }

    static func beautify(_ s: String, indent: Int = 4) -> String? {
        let ch = Array(s); var out = "", level = 0, i = 0
        var stack: [Character] = []
        var afterComment = false                                     // a comment was just written: the next token starts on a new line
        func nl() { out += "\n" + String(repeating: " ", count: max(0, level) * indent) }
        func nextNonSpace(_ from: Int) -> Character? { var j = from; while j < ch.count { if !ch[j].isWhitespace { return ch[j] }; j += 1 }; return nil }
        func atLineStart(_ idx: Int) -> Bool {                       // only whitespace before idx on its line?
            var j = idx - 1
            while j >= 0, !ch[j].isNewline { if !ch[j].isWhitespace { return false }; j -= 1 }
            return true
        }
        func lineStart(_ idx: Int) -> Int { var j = idx; while j > 0, !ch[j - 1].isNewline { j -= 1 }; return j }
        while i < ch.count {
            let c = ch[i]
            if c == "/", i + 1 < ch.count, ch[i + 1] == "/" {        // comment: verbatim
                var e = i; while e < ch.count, !ch[e].isNewline { e += 1 }
                if atLineStart(i) {
                    while let l = out.last, l == " " || l == "\t" { out.removeLast() }   // drop the indent nl() has just added
                    if let l = out.last, !l.isNewline { out.append("\n") }
                    out += String(ch[lineStart(i)..<e])                                  // the whole line, with its own indentation
                } else {
                    while let l = out.last, l.isWhitespace { out.removeLast() }          // trailing comment stays on its line
                    out += " " + String(ch[i..<e])
                }
                afterComment = true
                i = e; continue
            }
            if afterComment && !c.isWhitespace {
                afterComment = false
                if c != "}" && c != "]" { nl() }                     // closing brackets start their own line anyway
            }
            if c == "\"" {                                           // string literal, copied verbatim
                var j = i + 1; out.append(c); var closed = false
                while j < ch.count {
                    out.append(ch[j])
                    if ch[j] == "\\", j + 1 < ch.count { out.append(ch[j + 1]); j += 2; continue }
                    if ch[j] == "\"" { closed = true; break }
                    j += 1
                }
                if !closed { return nil }
                i = j + 1; continue
            }
            if c == "{", i + 1 < ch.count, ch[i + 1] == "{" {         // {{variable}}
                var j = i + 2
                while j + 1 < ch.count, !(ch[j] == "}" && ch[j + 1] == "}") { j += 1 }
                if j + 1 < ch.count { out += String(ch[i...(j + 1)]); i = j + 2; continue }
            }
            switch c {
            case "{", "[":
                let close: Character = c == "{" ? "}" : "]"
                if nextNonSpace(i + 1) == close {                      // empty {} / []
                    var j = i + 1; while ch[j] != close { j += 1 }
                    out.append(c); out.append(close); i = j + 1; continue
                }
                stack.append(c); out.append(c); level += 1; nl()
            case "}", "]":
                guard let top = stack.popLast(), (top == "{") == (c == "}") else { return nil }
                level -= 1; nl(); out.append(c)
            case ",": out.append(c); nl()
            case ":": out += ": "
            default: if !c.isWhitespace { out.append(c) }
            }
            i += 1
        }
        return stack.isEmpty ? out : nil
    }
}

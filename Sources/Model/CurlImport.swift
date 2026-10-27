import Foundation

/// cURL ⇄ request. Understands what browsers and tools produce: bash (`\` line breaks, '…', "…", $'…'), Windows cmd (`^` escapes),
/// short options glued together (`-sSLk`, `-XPOST`), `--opt=value`, -H/-d/--data-raw/--data-binary/--data-urlencode/-F/-u/-b/-A/-e/-G/-I/-T/--json/--url.
enum CurlImport {
    // MARK: tokenizer
    static func tokenize(_ input: String) -> [String] {
        var s = input.replacingOccurrences(of: "\r\n", with: "\n")
        if s.contains("^\"") || s.contains("^\n") {                           // Windows cmd: "Copy as cURL (cmd)"
            s = s.replacingOccurrences(of: "^\n", with: " ")
            var o = ""; var it = s.makeIterator()
            while let c = it.next() { if c == "^" { if let n = it.next() { o.append(n) } } else { o.append(c) } }
            s = o
        }
        let ch = Array(s); var out: [String] = []; var cur = ""; var has = false; var i = 0
        func flush() { if has { out.append(cur) }; cur = ""; has = false }
        while i < ch.count {
            let c = ch[i]
            if c == "\\", i + 1 < ch.count {                                  // unquoted escape / line continuation
                if ch[i + 1] == "\n" { i += 2; continue }
                cur.append(ch[i + 1]); has = true; i += 2; continue
            }
            if c == "'" {
                i += 1; has = true
                while i < ch.count, ch[i] != "'" { cur.append(ch[i]); i += 1 }
                i += 1; continue
            }
            if c == "$", i + 1 < ch.count, ch[i + 1] == "'" {                 // $'…' (ANSI-C quoting, used by Chrome for bodies with \n)
                i += 2; has = true
                while i < ch.count, ch[i] != "'" {
                    if ch[i] == "\\", i + 1 < ch.count {
                        let n = ch[i + 1]; i += 2
                        switch n {
                        case "n": cur.append("\n"); case "t": cur.append("\t"); case "r": cur.append("\r")
                        case "x", "u":
                            let len = n == "x" ? 2 : 4; var hex = ""
                            while hex.count < len, i < ch.count, ch[i].isHexDigit { hex.append(ch[i]); i += 1 }
                            if let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) { cur.unicodeScalars.append(u) }
                        default: cur.append(n)
                        }
                    } else { cur.append(ch[i]); i += 1 }
                }
                i += 1; continue
            }
            if c == "\"" {
                i += 1; has = true
                while i < ch.count, ch[i] != "\"" {
                    if ch[i] == "\\", i + 1 < ch.count, "\"\\$`\n".contains(ch[i + 1]) {
                        if ch[i + 1] != "\n" { cur.append(ch[i + 1]) }
                        i += 2
                    } else { cur.append(ch[i]); i += 1 }
                }
                i += 1; continue
            }
            if c == " " || c == "\t" || c == "\n" { flush(); i += 1; continue }
            cur.append(c); has = true; i += 1
        }
        flush()
        return out
    }

    // options that take a value
    private static let longWithArg: Set<String> = ["request", "header", "data", "data-raw", "data-binary", "data-ascii", "data-urlencode", "form", "form-string", "user", "cookie",
        "user-agent", "referer", "url", "output", "max-time", "connect-timeout", "proxy", "proxy-user", "cacert", "cert", "key", "resolve", "retry", "upload-file", "write-out",
        "json", "config", "cookie-jar", "dump-header", "limit-rate", "range", "interface", "capath", "pass", "oauth2-bearer", "aws-sigv4", "retry-delay", "retry-max-time", "max-redirs", "http-version", "ciphers", "tls-max", "tlsv1.3", "dns-servers", "expect100-timeout", "keepalive-time", "local-port", "netrc-file", "noproxy", "preproxy", "request-target", "socks5", "unix-socket", "variable"]
    private static let shortWithArg: Set<Character> = ["X", "H", "d", "F", "u", "b", "A", "e", "o", "m", "x", "w", "T", "c", "K", "E", "y", "Y", "z", "C", "r", "U", "D", "P", "t", "Q", "B"]

    /// The request described by a curl command, or nil when there is none.
    static func parse(_ text: String) -> Node? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("$ ") { t.removeFirst(2) }
        var toks = tokenize(t)
        guard let ci = toks.firstIndex(where: { $0 == "curl" || $0 == "curl.exe" }) else { return nil }
        toks = Array(toks[(ci + 1)...])

        var method: String?, url: String?, user: String?, cookie: String?, ua: String?, referer: String?
        var headers: [(String, String)] = []
        var data: [String] = [], urlenc: [String] = [], forms: [(String, String, Bool)] = []
        var json: String?, upload: String?, get = false, head = false, binaryData = false
        var i = 0
        func next() -> String? { i += 1; return i < toks.count ? toks[i] : nil }
        func apply(_ name: String, _ v: String) {
            switch name {
            case "X", "request": method = v.uppercased()
            case "H", "header":
                if let c = v.firstIndex(of: ":") {
                    let k = String(v[..<c]).trimmingCharacters(in: .whitespaces), val = String(v[v.index(after: c)...]).trimmingCharacters(in: .whitespaces)
                    if !k.isEmpty { headers.append((k, val)) }
                }
            case "d", "data", "data-raw", "data-ascii": data.append(v)
            case "data-binary": data.append(v); binaryData = true
            case "data-urlencode": urlenc.append(v)
            case "F", "form", "form-string":
                if let e = v.firstIndex(of: "=") {
                    let k = String(v[..<e]); var val = String(v[v.index(after: e)...])
                    var file = false
                    if name != "form-string", val.hasPrefix("@") || val.hasPrefix("<") {
                        file = true; val.removeFirst()
                        if let sc = val.firstIndex(of: ";") { val = String(val[..<sc]) }              // ;type=…
                    }
                    forms.append((k, val, file))
                }
            case "u", "user": user = v
            case "b", "cookie": cookie = v
            case "A", "user-agent": ua = v
            case "e", "referer": referer = v
            case "url": url = v
            case "T", "upload-file": upload = v
            case "json": json = v
            default: break
            }
        }
        while i < toks.count {
            let tk = toks[i]
            if tk.hasPrefix("--") && tk.count > 2 {
                var name = String(tk.dropFirst(2)); var val: String?
                if let e = name.firstIndex(of: "=") { val = String(name[name.index(after: e)...]); name = String(name[..<name.firstIndex(of: "=")!]) }
                if longWithArg.contains(name) { if val == nil { val = next() }; if let v = val { apply(name, v) } }
                else if name == "get" { get = true } else if name == "head" { head = true }
            } else if tk.hasPrefix("-") && tk.count > 1 {
                let cs = Array(tk.dropFirst()); var j = 0
                while j < cs.count {
                    let c = cs[j]
                    if shortWithArg.contains(c) {
                        let rest = String(cs[(j + 1)...])
                        if let v = rest.isEmpty ? next() : rest { apply(String(c), v) }
                        break
                    }
                    if c == "G" { get = true } else if c == "I" { head = true }
                    j += 1
                }
            } else if url == nil { url = tk }
            i += 1
        }
        guard var u = url, !u.isEmpty else { return nil }
        if !u.contains("://"), !u.hasPrefix("{{") { u = "http://" + u }

        func header(_ k: String) -> String? { headers.first { $0.0.caseInsensitiveCompare(k) == .orderedSame }?.1 }
        let hasBody = !data.isEmpty || !urlenc.isEmpty || !forms.isEmpty || json != nil || upload != nil
        if get, !data.isEmpty || !urlenc.isEmpty {                                             // -G: data goes to the query string
            let q = (data + urlenc).joined(separator: "&"); u += (u.contains("?") ? "&" : "?") + q
            data = []; urlenc = []
        }
        let m = method ?? (head ? "HEAD" : (upload != nil ? "PUT" : (hasBody && !get ? "POST" : "GET")))
        let n = Node(name: "", folder: false)
        n.method = m; n.url = u
        n.headers = headers.map { KV(key: $0.0, value: $0.1) }
        if let user { n.headers.append(KV(key: "Authorization", value: "Basic " + Data((user.contains(":") ? user : user + ":").utf8).base64EncodedString())) }
        if let cookie, header("Cookie") == nil { n.headers.append(KV(key: "Cookie", value: cookie)) }
        if let ua, header("User-Agent") == nil { n.headers.append(KV(key: "User-Agent", value: ua)) }
        if let referer, header("Referer") == nil { n.headers.append(KV(key: "Referer", value: referer)) }

        let ct = (header("Content-Type") ?? "").lowercased()
        if !forms.isEmpty {
            n.bodyMode = "formdata"
            n.formData = forms.map { FormRow(key: $0.0, value: $0.2 ? "" : $0.1, enabled: true, isFile: $0.2, src: $0.2 ? $0.1 : "") }
            n.headers.removeAll { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame && $0.value.lowercased().hasPrefix("multipart/") }
        } else if let j = json {
            n.bodyMode = "raw"; n.rawLang = "json"; n.body = j
            if header("Content-Type") == nil { n.headers.append(KV(key: "Content-Type", value: "application/json")) }
            if header("Accept") == nil { n.headers.append(KV(key: "Accept", value: "application/json")) }
        } else if let up = upload {
            n.bodyMode = "binary"; n.binaryPath = up
        } else if !urlenc.isEmpty || (!data.isEmpty && ct.hasPrefix("application/x-www-form-urlencoded")) {
            n.bodyMode = "urlencoded"
            var rows: [KV] = []
            for d in data { for pair in d.split(separator: "&", omittingEmptySubsequences: true) { rows.append(decodedPair(String(pair))) } }
            for d in urlenc {
                if let e = d.firstIndex(of: "=") { rows.append(KV(key: String(d[..<e]), value: String(d[d.index(after: e)...]))) } else { rows.append(KV(key: d, value: "")) }
            }
            n.urlencoded = rows
            n.headers.removeAll { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame && $0.value.lowercased().hasPrefix("application/x-www-form-urlencoded") }
        } else if !data.isEmpty {
            let joined = data.joined(separator: "&")
            if binaryData, joined.hasPrefix("@") { n.bodyMode = "binary"; n.binaryPath = String(joined.dropFirst()) }
            else {
                n.bodyMode = "raw"; n.body = joined
                let tr = joined.trimmingCharacters(in: .whitespacesAndNewlines)
                if ct.contains("json") || ((tr.hasPrefix("{") || tr.hasPrefix("[")) && (try? JSONSerialization.jsonObject(with: Data(JSONFormat.withoutComments(tr).utf8))) != nil) { n.rawLang = "json" }
                else if ct.contains("xml") { n.rawLang = "xml" } else if ct.contains("html") { n.rawLang = "html" }
                else if ct.contains("javascript") { n.rawLang = "javascript" } else { n.rawLang = "text" }
            }
        }
        if n.bodyMode == "raw", n.rawLang == "json", let b = JSONFormat.beautify(n.body) { n.body = b }
        n.name = name(for: m, u)
        return n
    }

    private static func decodedPair(_ p: String) -> KV {
        func dec(_ s: String) -> String { (s.replacingOccurrences(of: "+", with: " ")).removingPercentEncoding ?? s }
        let kv = p.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        return KV(key: dec(String(kv[0])), value: kv.count > 1 ? dec(String(kv[1])) : "")
    }
    private static func name(for method: String, _ url: String) -> String {
        if let c = URLComponents(string: url.replacingOccurrences(of: "{{", with: "").replacingOccurrences(of: "}}", with: "")) {
            let path = c.path.isEmpty || c.path == "/" ? (c.host ?? url) : c.path
            return "\(method) \(path)"
        }
        return "\(method) \(url)"
    }
}

/// A curl command for something that was sent (history / result). Headers curl sets itself are left out.
enum CurlBuilder {
    private static let skip: Set<String> = ["host", "content-length", "connection", "accept-encoding", "postman-token"]
    private static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func build(method: String, url: String, headers: [KV], body: String) -> String {
        var parts = ["curl"]
        if method != "GET" { parts.append("--request \(method)") }
        parts.append("--url " + q(url))
        var multipart = false
        for h in headers where !skip.contains(h.key.lowercased()) {
            if h.key.lowercased() == "content-type", h.value.lowercased().hasPrefix("multipart/form-data") { multipart = true; continue }
            parts.append("--header " + q("\(h.key): \(h.value)"))
        }
        if multipart {                                                       // the stored body is the field list: `name: value` / `name: <file path>`
            for line in body.split(separator: "\n") {
                guard let c = line.range(of: ": ") else { continue }
                let k = String(line[..<c.lowerBound]); let v = String(line[c.upperBound...])
                if v.hasPrefix("<file "), v.hasSuffix(">") { parts.append("--form " + q("\(k)=@" + String(v.dropFirst(6).dropLast()))) }
                else { parts.append("--form " + q("\(k)=\(v)")) }
            }
        } else if body.hasPrefix("<binary file "), body.hasSuffix(">") {
            parts.append("--data-binary " + q("@" + String(body.dropFirst(13).dropLast())))
        } else if !body.isEmpty {
            parts.append("--data-raw " + q(body))
        }
        return parts.joined(separator: " \\\n  ")
    }
}

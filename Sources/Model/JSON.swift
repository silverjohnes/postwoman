import Foundation

// Generic JSON so unknown Postman fields (scripts, auth, events) survive import → export.
enum JSON: Codable, Hashable {
    case null, bool(Bool), num(Double), str(String), arr([JSON]), obj([String: JSON])

    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .num(v) }
        else if let v = try? c.decode(String.self) { self = .str(v) }
        else if let v = try? c.decode([JSON].self) { self = .arr(v) }
        else { self = .obj(try c.decode([String: JSON].self)) }
    }
    func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .num(let v): if v == v.rounded(), abs(v) < 1e15 { try c.encode(Int(v)) } else { try c.encode(v) }
        case .str(let v): try c.encode(v)
        case .arr(let v): try c.encode(v)
        case .obj(let v): try c.encode(v)
        }
    }
    subscript(k: String) -> JSON? { if case .obj(let o) = self { return o[k] }; return nil }
    var text: String? { if case .str(let s) = self { return s }; if case .num(let n) = self { return String(Int(n)) }; return nil }
    var list: [JSON] { if case .arr(let a) = self { return a }; return [] }
    var flag: Bool? { if case .bool(let b) = self { return b }; return nil }
    var dict: [String: JSON] { if case .obj(let o) = self { return o }; return [:] }
    var number: Double? { if case .num(let n) = self { return n }; return nil }

    static func parse(_ data: Data) -> JSON? { try? JSONDecoder().decode(JSON.self, from: data) }
    func data() -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(self)) ?? Data()
    }
    /// Single-line encoding (no pretty printing): one document per line, as used by the history files.
    func compactData() -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(self)) ?? Data()
    }
}

struct KV: Identifiable, Hashable {
    var id = UUID()
    var key = ""
    var value = ""
    var enabled = true
}

struct Var: Identifiable, Hashable {
    var id = UUID()
    var key = ""
    var value = ""                 // secret variables: `pwenc:1:…` ciphertext (see SecretVault), never the plain value
    var enabled = true
    var secret = false
}


extension JSON {
    mutating func setKey(_ k: String, _ v: JSON) {
        var o = dict; o[k] = v; self = .obj(o)
    }
}

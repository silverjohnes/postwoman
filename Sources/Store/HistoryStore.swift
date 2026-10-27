import Foundation
import Combine

/// One recorded execution of a request: everything that was sent and received.
struct HistoryEntry: Identifiable {
    var id = UUID().uuidString.lowercased()
    var ts = Date()                       // when the request was sent
    var runID = ""
    var iteration = 0
    var name = "", method = "", url = ""
    var reqHeaders: [KV] = [], reqBody = ""
    var code = 0, status = "", timeMs = 0
    var resHeaders: [KV] = [], resBody = ""
    var failures: [String] = []           // failed tests / transport errors
    var dataRow: [String: String] = [:]   // iteration data (CSV/JSON row), if any

    init(result r: ExecResult) {
        ts = r.started; runID = r.runID; iteration = r.iteration
        name = r.name; method = r.method; url = r.url
        reqHeaders = r.reqHeaders; reqBody = r.reqBody
        code = r.code; status = r.status; timeMs = r.time
        resHeaders = r.resHeaders; resBody = r.resBody
        failures = r.failures; dataRow = r.dataRow
    }

    /// Tolerant reader: every field except the timestamp is optional, so future versions can add fields freely.
    init?(json j: JSON) {
        guard let t = j["ts"]?.number else { return nil }
        ts = Date(timeIntervalSince1970: t)
        id = j["id"]?.text ?? id
        runID = j["runID"]?.text ?? ""
        iteration = Int(j["iteration"]?.number ?? 0)
        name = j["name"]?.text ?? ""; method = j["method"]?.text ?? ""; url = j["url"]?.text ?? ""
        reqHeaders = Self.headers(j["reqHeaders"]); reqBody = j["reqBody"]?.text ?? ""
        code = Int(j["code"]?.number ?? 0); status = j["status"]?.text ?? ""; timeMs = Int(j["timeMs"]?.number ?? 0)
        resHeaders = Self.headers(j["resHeaders"]); resBody = j["resBody"]?.text ?? ""
        failures = (j["failures"]?.list ?? []).compactMap { $0.text }
        dataRow = (j["data"]?.dict ?? [:]).mapValues { $0.text ?? "" }
    }

    private static func headers(_ j: JSON?) -> [KV] {
        (j?.list ?? []).map { KV(key: $0["k"]?.text ?? "", value: $0["v"]?.text ?? "") }
    }
    private static func headersJSON(_ hs: [KV]) -> JSON {
        .arr(hs.map { .obj(["k": .str($0.key), "v": .str($0.value)]) })
    }
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    func toJSON() -> JSON {
        var o: [String: JSON] = [:]
        o["v"] = .num(1)                                                    // history line format version
        o["id"] = .str(id)
        o["ts"] = .num((ts.timeIntervalSince1970 * 1000).rounded() / 1000)  // machine-readable
        o["at"] = .str(Self.iso.string(from: ts))                           // human-readable duplicate
        o["runID"] = .str(runID); o["iteration"] = .num(Double(iteration))
        o["name"] = .str(name); o["method"] = .str(method); o["url"] = .str(url)
        o["reqHeaders"] = Self.headersJSON(reqHeaders); o["reqBody"] = .str(reqBody)
        o["code"] = .num(Double(code)); o["status"] = .str(status); o["timeMs"] = .num(Double(timeMs))
        o["resHeaders"] = Self.headersJSON(resHeaders); o["resBody"] = .str(resBody)
        o["failures"] = .arr(failures.map { .str($0) })
        if !dataRow.isEmpty { o["data"] = .obj(dataRow.mapValues { .str($0) }) }
        return .obj(o)
    }

    var asResult: ExecResult {
        var r = ExecResult(iteration: iteration)
        r.name = name; r.method = method; r.url = url; r.status = status
        r.code = code; r.time = timeMs
        r.reqHeaders = reqHeaders; r.reqBody = reqBody
        r.resHeaders = resHeaders; r.resBody = resBody
        r.failures = failures; r.started = ts; r.runID = runID; r.dataRow = dataRow
        return r
    }
}

/// History lives next to the collections: `<storage folder>/history/<request id>.jsonl`, one JSON document per line.
/// Collection files are not touched (apart from the internal request id), so older data stays fully compatible.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var tick = 0                 // bumps after every change; views reload on it
    var log: (@MainActor (LogLevel, String) -> Void)?
    private let dirProvider: () -> URL
    init(dir: @escaping () -> URL) { dirProvider = dir }

    var directory: URL { dirProvider() }
    nonisolated static func fileName(_ nodeID: String) -> String {
        String(nodeID.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }) + ".jsonl"
    }
    private func file(_ nodeID: String) -> URL { directory.appendingPathComponent(Self.fileName(nodeID)) }

    func append(_ r: ExecResult) {
        guard !r.nodeID.isEmpty else {
            log?(.warn, "execution of \"\(r.name)\" has no request id — not recorded in history"); return
        }
        var line = HistoryEntry(result: r).toJSON().compactData(); line.append(0x0A)
        let url = file(r.nodeID)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let h = try FileHandle(forWritingTo: url)
                defer { try? h.close() }
                try h.seekToEnd(); try h.write(contentsOf: line)
            } else {
                try line.write(to: url)
            }
            tick += 1
            log?(.debug, "history: recorded \(r.method) \"\(r.name)\" → \(r.code), \(max(1, line.count / 1024)) KB → \(url.lastPathComponent)")
        } catch {
            log?(.error, "cannot write history (\(url.path)): \(error.localizedDescription)")
        }
    }

    /// Newest first. Only the latest `limit` entries are parsed; `total` is the number of lines in the file.
    func load(_ nodeID: String, limit: Int = 500) -> (entries: [HistoryEntry], total: Int) {
        let url = file(nodeID)
        guard let data = try? Data(contentsOf: url) else { return ([], 0) }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        var out: [HistoryEntry] = []; var bad = 0
        for l in lines.suffix(limit) {
            if let j = JSON.parse(Data(l)), let e = HistoryEntry(json: j) { out.append(e) } else { bad += 1 }
        }
        if bad > 0 { log?(.warn, "history file \(url.lastPathComponent): \(bad) unreadable line(s) skipped") }
        return (out.reversed(), lines.count)
    }

    func clear(_ nodeID: String) {
        try? FileManager.default.removeItem(at: file(nodeID)); tick += 1
        log?(.info, "history cleared for request \(nodeID)")
    }
    /// Deletes the chosen executions of one request (their lines in its history file); unreadable lines are kept.
    func removeEntries(_ nodeID: String, ids: Set<String>) {
        let url = file(nodeID)
        guard !ids.isEmpty, let data = try? Data(contentsOf: url) else { return }
        var keep = Data(); var dropped = 0
        for l in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let j = JSON.parse(Data(l)), let id = j["id"]?.text, ids.contains(id) { dropped += 1 }
            else { keep.append(contentsOf: l); keep.append(0x0A) }
        }
        guard dropped > 0 else { return }
        if keep.isEmpty { try? FileManager.default.removeItem(at: url) } else { try? keep.write(to: url, options: .atomic) }
        tick += 1
        log?(.info, "history: deleted \(dropped) execution(s) of request \(nodeID)")
    }
    func remove(_ nodeIDs: [String]) {
        guard !nodeIDs.isEmpty else { return }
        for id in nodeIDs { try? FileManager.default.removeItem(at: file(id)) }
        tick += 1
    }

    // MARK: Retention
    struct PruneResult { var files = 0, removedFiles = 0, removedEntries = 0, kept = 0 }

    /// Removes executions older than `cutoff`. Runs on a background queue. Unreadable lines are never deleted.
    nonisolated static func prune(dir: URL, cutoff: Date) -> PruneResult {
        var res = PruneResult()
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return res }
        let cut = cutoff.timeIntervalSince1970
        for n in names where n.hasSuffix(".jsonl") {
            let url = dir.appendingPathComponent(n)
            guard let data = try? Data(contentsOf: url) else { continue }
            res.files += 1
            var keep: [Data] = []; var dropped = 0
            for l in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                if let t = timestamp(of: l), t < cut { dropped += 1 } else { keep.append(Data(l)) }
            }
            res.kept += keep.count; res.removedEntries += dropped
            guard dropped > 0 else { continue }
            if keep.isEmpty {
                try? fm.removeItem(at: url); res.removedFiles += 1
            } else {
                var out = Data(); for k in keep { out.append(k); out.append(0x0A) }
                try? out.write(to: url, options: .atomic)
            }
        }
        return res
    }

    /// Timestamp of one history line without parsing its (possibly huge) bodies: with sorted keys `"ts":` sits near the end.
    nonisolated static func timestamp(of line: Data) -> Double? {
        let tail = line.suffix(2000)
        guard let r = tail.range(of: Data("\"ts\":".utf8)) else { return JSON.parse(Data(line))?["ts"]?.number }
        var num = ""
        for b in tail[r.upperBound...] {
            if (b >= 48 && b <= 57) || b == 46 || b == 45 || b == 43 || b == 101 || b == 69 { num.append(Character(UnicodeScalar(b))) } else { break }
        }
        return Double(num)
    }
}

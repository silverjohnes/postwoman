import AppKit
import Combine
import UniformTypeIdentifiers
import Foundation

@MainActor
final class Runner: ObservableObject {
    @Published var results: [ExecResult] = []
    @Published var state: RunState = .idle
    @Published var log = ""
    @Published var progress = ""
    var sink: (@MainActor (LogLevel, String, String) -> Void)?     // → global Log tab
    var historySink: (@MainActor (ExecResult) -> Void)?            // → request history
    /// A variable written (or removed) by a script during the run: the Store keeps it in Globals.
    struct VarChange { var key: String; var value: String; var secret: Bool; var remove: Bool }
    var varsSink: (@MainActor ([VarChange]) -> Void)?
    private var workVars: [(key: String, value: String)] = []          // plain globals as the NEXT iteration must see them (scripts change them)
    private var globalsFile: URL?
    private func note(_ m: String, _ l: LogLevel = .info, _ cat: String = "runner") { sink?(l, cat, m) }
    private func fail(_ m: String) { log = m + "\n"; state = .idle }
    private var proc: Process?
    private var stopped = false
    private var gen = 0                         // run counter: delayed stop handling must not touch a newer run
    private var finishExec: (() -> Void)?       // releases the awaiting `exec` (used when the process cannot be stopped)
    private(set) var completed = false          // the last run reached its end (not stopped, not failed)

    // MARK: App lifecycle
    nonisolated(unsafe) static var liveProcess: Process?
    /// Called on app quit so a running node/newman process is never orphaned.
    nonisolated static func killChild() {
        guard let p = liveProcess, p.isRunning else { return }
        kill(p.processIdentifier, SIGCONT)      // a paused (SIGSTOP) process would ignore SIGTERM
        p.terminate()
    }

    // MARK: Control
    func pause() {
        guard state == .running else { return }
        if let p = proc, p.isRunning { p.suspend() }
        state = .paused; note("Paused (newman process suspended)")
    }
    func resume() {
        guard state == .paused else { return }
        if let p = proc, p.isRunning { p.resume() }
        state = .running; note("Resumed")
    }
    func stop() {
        guard state != .idle else { return }
        stopped = true; note("Stop requested", .warn)
        let g = gen
        if let p = proc, p.isRunning { kill(p.processIdentifier, SIGCONT); p.terminate() }
        if state == .paused { state = .running }          // the loop sees `stopped` and finishes
        // A run must never stay "busy" after Stop. Watch it with plain main-queue timers (independent of the process's termination callback):
        // every 0.25 s: process gone → release; after 2 s: SIGKILL; after 3.5 s: give up on the process and make the runner idle.
        let t0 = Date()
        func tick() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { MainActor.assumeIsolated { [weak self] in
                guard let s = self, s.gen == g, s.state != .idle else { return }
                let age = Date().timeIntervalSince(t0)
                if let p = s.proc, p.isRunning {
                    if age >= 2, !s.killSent { s.killSent = true; s.note("Process did not stop: sending SIGKILL", .warn); kill(p.processIdentifier, SIGKILL) }
                } else if let f = s.finishExec {
                    s.note("Process is gone: releasing the run", .debug); f()          // terminationHandler did not report it
                }
                if age >= 3.5 { s.forceIdle(); return }
                tick()
            } }
        }
        killSent = false
        tick()
    }
    private var killSent = false
    /// Last resort after Stop: the run is over whatever the process or its callback does.
    private func forceIdle() {
        note("Run released after Stop (the process did not report that it finished)", .warn)
        finishExec?()
        gen += 1                                          // the old run loop can no longer touch the state of a new one
        state = .idle; proc = nil; progress = L("Stopped")
        secretValues = [:]; redactor = Redactor(secrets: [:])
    }

    // MARK: Run
    private var buf = Data()
    private var scanned = 0                     // bytes of `buf` already searched for a line break
    private var secretValues: [String: String] = [:]     // decrypted secrets, kept in memory only for the duration of a run
    private var redactor = Redactor(secrets: [:])
    private var iterNo = 0
    private var execIndex: [String: Int] = [:]
    private var launchedAt = Date()
    private var firstOutputAt: Date?
    private var lastEvent = ""
    private var lastEventAt = Date()
    private var runID = ""
    private var currentRow: [String: String] = [:]
    /// Column order of the data file used by the last run (the rows are dictionaries, so the order is kept here): for "Errors CSV".
    var dataColumns: [String] = []
    var dataFileName = ""                       // name of that data file without extension (the file may be cleared from the tab after a run)
    private var pendingHistory = Set<Int>()        // indexes of results not yet written to the history

    func start(collection col: JSON, globals: [Var], secrets: [String: String] = [:], dataURL: URL?, iterations: Int, intervalMs: Int, timeoutSec: Int) {
        guard state == .idle else { note("Start ignored: the previous run is still \(state == .paused ? "paused" : "running")", .warn, "runner"); return }
        // The newman wrapper ships inside the app bundle (Contents/Resources/runner.js).
        guard let jsURL = Bundle.main.url(forResource: "runner", withExtension: "js") else {
            note("runner.js is missing from the app bundle (Contents/Resources) — rebuild the app", .error, "prepare")
            progress = L("runner.js missing"); return
        }
        if let problem = EmbeddedRuntime.problem() {
            note(problem, .error, "prepare"); progress = L("Runtime missing"); fail(problem); return
        }
        gen += 1; results = []; log = ""; stopped = false; completed = false; state = .running; execIndex = [:]
        secretValues = secrets; redactor = Redactor(secrets: secrets)
        runID = UUID().uuidString.lowercased(); pendingHistory = []
        let t0 = Date()
        let total = max(1, iterations)
        note("Start: \(total) iteration(s), interval \(intervalMs) ms, request timeout \(timeoutSec > 0 ? "\(timeoutSec) s" : "none"), embedded newman \(EmbeddedRuntime.newmanDir.path)", .info, "prepare")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("postwoman-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var staged = 0
        let colStaged = Runner.stageFiles(col, into: dir.appendingPathComponent("files"), count: &staged)      // form-data / binary files: a copy next to the collection
        if staged > 0 { note("Copied \(staged) attached file(s) for this run", .debug, "prepare") }
        // Variable names are not case sensitive: {{TOKEN}} is rewritten to the name that exists (Globals, data columns, names set by scripts).
        var canon: [String] = globals.filter(\.enabled).map(\.key) + (dataURL.map { Self.loadColumns($0) } ?? []) + Array(Highlighter.known)
        canon += (col["variable"]?.list ?? []).compactMap { $0["key"]?.text }
        let (colCased, fixedNames) = Self.canonicalizeVars(colStaged, names: canon.filter { !$0.isEmpty })
        if !fixedNames.isEmpty { note("Variable names matched ignoring case: " + fixedNames.sorted().joined(separator: ", "), .info, "prepare") }
        let colData = colCased.data()
        let colURL = dir.appendingPathComponent("collection.json"); try? colData.write(to: colURL)
        let gURL = dir.appendingPathComponent("globals.json")
        let enabledGlobals = globals.filter { $0.enabled && !$0.secret }            // secrets never touch the disk: they go through stdin
        workVars = enabledGlobals.map { ($0.key, $0.value) }; globalsFile = gURL
        writeWorkGlobals()
        note("Prepared \(dir.path): collection \(colData.count) bytes, \(col["item"]?.list.count ?? 0) top-level item(s), \(enabledGlobals.count) global(s) + \(secrets.count) secret(s) via stdin (\(Int(Date().timeIntervalSince(t0) * 1000)) ms)", .debug, "prepare")

        let rows = dataURL.flatMap { Self.loadRows($0) } ?? []
        dataColumns = dataURL.map { Self.loadColumns($0) } ?? []
        dataFileName = dataURL?.deletingPathExtension().lastPathComponent ?? ""
        if let u = dataURL {
            note("Data file \(u.lastPathComponent): \(rows.count) row(s), columns: \((rows.first?.keys.sorted() ?? []).joined(separator: ", "))", rows.isEmpty ? .warn : .info, "prepare")
        }

        let myGen = gen
        Task {
            for i in 0..<total {
                if stopped || gen != myGen { break }
                iterNo = i + 1
                currentRow = rows.isEmpty ? [:] : rows[i % rows.count]
                progress = L("Iteration %ld / %ld", i + 1, total)
                note("── Iteration \(i + 1)/\(total) ──", .info, "iteration")
                var dataArg = "-"
                if !rows.isEmpty {
                    let ri = i % rows.count, row = rows[ri]
                    let dURL = dir.appendingPathComponent("data.json")
                    try? JSON.arr([.obj(row.mapValues { .str($0) })]).data().write(to: dURL)
                    dataArg = dURL.path
                    note("Data row \(ri + 1)/\(rows.count): " + row.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "), .debug, "iteration")
                }
                let args = [jsURL.path, EmbeddedRuntime.newmanDir.path, colURL.path, gURL.path, dataArg, "\(intervalMs)", "\(max(0, timeoutSec) * 1000)", secretValues.isEmpty ? "-" : "stdin"]
                note("node \(args.joined(separator: " "))", .debug, "launch")
                await exec(args)
                flushHistory()
                if i < total - 1 && !stopped {
                    note("Waiting \(intervalMs) ms before next iteration", .debug, "iteration")
                    await wait(ms: intervalMs)
                }
            }
            progress = stopped ? L("Stopped") : L("Done")
            note(stopped ? "Run stopped by user" : "Run finished: \(results.count) request(s) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms", stopped ? .warn : .info, "runner")
            try? FileManager.default.removeItem(at: dir)
            guard gen == myGen else { return }                // released by Stop's watchdog (a new run may be going)
            completed = !stopped
            state = .idle; proc = nil
            secretValues = [:]; redactor = Redactor(secrets: [:])
        }
    }

    private func wait(ms: Int) async {
        var left = ms
        while left > 0 && !stopped { try? await Task.sleep(for: .milliseconds(100)); if state != .paused { left -= 100 } }
        while state == .paused && !stopped { try? await Task.sleep(for: .milliseconds(100)) }
    }

    private func exec(_ args: [String]) async {
        let p = Process()
        p.executableURL = EmbeddedRuntime.nodeURL      // the node binary that ships inside the app: no shell, no PATH, no external newman
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        let inPipe = Pipe()
        let wantsSecrets = (p.arguments?.last == "stdin")
        p.standardInput = wantsSecrets ? inPipe : FileHandle.nullDevice
        p.environment = EmbeddedRuntime.environment()
        buf = Data(); scanned = 0; firstOutputAt = nil; launchedAt = Date(); lastEvent = "process launched"; lastEventAt = Date()
        // Output is delivered to the main queue in order (FIFO) so lines never interleave.
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }      // EOF: stop, otherwise the source keeps firing
            DispatchQueue.main.async { MainActor.assumeIsolated { self.ingest(d) } }
        }
        proc = p
        Runner.liveProcess = p
        let watchdog = Task { @MainActor [weak self] in
            var n = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let s = self, !Task.isCancelled else { return }
                n += 5
                if s.state == .paused { s.note("Paused: process suspended (\(n) s since launch)", .debug, "watchdog"); continue }
                let idle = Int(Date().timeIntervalSince(s.lastEventAt))
                if s.firstOutputAt == nil {
                    s.note("No output from the process \(n) s after launch: node failed to start or is stuck", .warn, "watchdog")
                } else {
                    s.note("Still running: \(n) s since launch, \(idle) s since last event (\(s.lastEvent))", idle >= 10 ? .warn : .debug, "watchdog")
                }
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            var done = false
            let finish: () -> Void = { if !done { done = true; c.resume() } }
            self.finishExec = finish
            p.terminationHandler = { pr in
                pipe.fileHandleForReading.readabilityHandler = nil
                // Never readDataToEndOfFile() here: a grandchild holding the pipe open would block it forever.
                let rest = EmbeddedRuntime.drain(pipe.fileHandleForReading)
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    if !rest.isEmpty { self.ingest(rest) }
                    self.flushBuffer()
                    let ms = Int(Date().timeIntervalSince(self.launchedAt) * 1000)
                    let how = pr.terminationReason == .exit ? "exit code \(pr.terminationStatus)" : "signal \(pr.terminationStatus)"
                    self.note("Process finished: \(how), \(ms) ms after launch", pr.terminationStatus == 0 ? .info : .warn, "launch")
                    finish()
                } }
            }
            do {
                try p.run(); note("Process started, pid \(p.processIdentifier)", .debug, "launch")
                if wantsSecrets {                                    // secrets travel through a pipe, not through a file
                    signal(SIGPIPE, SIG_IGN)
                    let payload = (try? JSONSerialization.data(withJSONObject: secretValues)) ?? Data("{}".utf8)
                    let h = inPipe.fileHandleForWriting
                    DispatchQueue.global(qos: .userInitiated).async { try? h.write(contentsOf: payload); try? h.close() }
                }
            }
            catch { log += "Failed to launch: \(error)\n"; note("Failed to launch \(EmbeddedRuntime.nodeURL.path): \(error)", .error, "launch"); finish() }
        }
        watchdog.cancel(); finishExec = nil
        Runner.liveProcess = nil
    }

    private func writeWorkGlobals() {
        guard let u = globalsFile else { return }
        let g: JSON = .obj(["values": .arr(workVars.map { .obj(["key": .str($0.key), "value": .str($0.value), "enabled": .bool(true)]) })])
        try? g.data().write(to: u)
    }

    // MARK: Output from the node wrapper (lines starting with "@@PW " are JSON events)
    private func ingest(_ data: Data) {
        if firstOutputAt == nil {
            firstOutputAt = Date()
            note("First output \(Int(Date().timeIntervalSince(launchedAt) * 1000)) ms after launch (node startup)", .debug, "launch")
        }
        buf.append(data)
        // A response body can be tens of MB in ONE line: look for the line break only in what is new, never rescan the whole buffer.
        while true {
            let from = buf.startIndex + min(scanned, buf.count)
            guard let nl = buf[from...].firstIndex(of: 0x0A) else { scanned = buf.count; break }
            let line = String(decoding: buf[buf.startIndex..<nl], as: UTF8.self)
            buf.removeSubrange(buf.startIndex...nl); scanned = 0
            handle(line)
        }
    }
    private func flushBuffer() {
        if !buf.isEmpty { handle(String(decoding: buf, as: UTF8.self)); buf = Data(); scanned = 0 }
    }
    /// Writes executions whose item never reported "done" (process killed, script crash…), so none is lost.
    private func flushHistory() {
        for i in pendingHistory.sorted() where i < results.count { historySink?(results[i]) }
        pendingHistory = []
    }
    private func lvl(_ s: String?) -> LogLevel {
        switch s { case "debug": .debug; case "warn": .warn; case "error": .error; default: .info }
    }
    private func handle(_ raw: String) {
        let line = raw.trimmingCharacters(in: .newlines)
        if line.trimmingCharacters(in: .whitespaces).isEmpty { return }
        guard line.hasPrefix("@@PW "), let j = JSON.parse(Data(line.dropFirst(5).utf8)) else {
            let line = redactor.mask(line)
            log += line + "\n"
            let l = line.lowercased()
            note(line, l.contains("error") || l.contains("not found") ? .error : .debug, "node")
            lastEvent = line; lastEventAt = Date(); return
        }
        lastEventAt = Date()
        switch j["e"]?.text {
        case "log":
            let m = redactor.mask(j["m"]?.text ?? ""), c = j["c"]?.text ?? "stage"
            log += "[\(c)] \(m)\n"; lastEvent = m
            note(m, lvl(j["l"]?.text), c)
        case "item":
            progress = L("Iteration %ld · %@", iterNo, j["name"]?.text ?? "")
        case "exec":
            var r = ExecResult(iteration: iterNo)
            r.nodeID = j["id"]?.text ?? ""; r.runID = runID; r.dataRow = currentRow
            r.name = j["name"]?.text ?? ""; r.method = j["method"]?.text ?? ""; r.url = redactor.mask(j["url"]?.text ?? "")
            r.code = Int(j["code"]?.text ?? "") ?? 0; r.status = j["status"]?.text ?? ""; r.time = Int(j["time"]?.text ?? "") ?? 0
            r.reqHeaders = (j["reqH"]?.list ?? []).map { KV(key: $0["k"]?.text ?? "", value: redactor.mask($0["v"]?.text ?? "")) }
            r.resHeaders = (j["resH"]?.list ?? []).map { KV(key: $0["k"]?.text ?? "", value: redactor.mask($0["v"]?.text ?? "")) }
            r.reqBody = redactor.mask(j["reqB"]?.text ?? ""); r.resBody = redactor.mask(j["resB"]?.text ?? "")
            if let err = j["error"]?.text { r.failures.append(redactor.mask(err)) }
            // exact moment the request was sent (ms since epoch, from the wrapper); fall back to "now minus response time"
            if let ts = j["ts"]?.number, ts > 0 { r.started = Date(timeIntervalSince1970: ts / 1000) }
            else { r.started = Date().addingTimeInterval(-Double(r.time) / 1000) }
            execIndex["\(iterNo)|\(j["id"]?.text ?? "")"] = results.count
            pendingHistory.insert(results.count)
            results.append(r)
            lastEvent = "\(r.method) \(r.name)"
        case "assert":
            let name = redactor.mask(j["name"]?.text ?? ""), ok = j["ok"]?.flag ?? false, msg = redactor.mask(j["msg"]?.text ?? "failed")
            if !ok, let i = execIndex["\(iterNo)|\(j["id"]?.text ?? "")"] { results[i].failures.append("\(name): \(msg)") }
            note(ok ? "✓ \(name)" : "✗ \(name): \(msg)", ok ? .debug : .warn, "test")
            lastEvent = "test \(name)"
        case "visual":
            if let i = execIndex["\(iterNo)|\(j["id"]?.text ?? "")"] {
                results[i].visual = redactor.mask(j["html"]?.text ?? "")
                results[i].visualData = redactor.mask(j["data"]?.text ?? "null")
                results[i].visualError = j["error"]?.text ?? ""
            }
        case "vars":                      // variables written by scripts: later iterations see them, the Store persists them in Globals
            var ch: [VarChange] = []
            for s in j["set"]?.list ?? [] {
                guard let k = s["k"]?.text, !k.isEmpty else { continue }
                let v = s["v"]?.text ?? "", sec = (s["s"]?.flag ?? false) || secretValues[k] != nil
                if sec { secretValues[k] = v; workVars.removeAll { $0.key == k } }
                else if let i = workVars.firstIndex(where: { $0.key == k }) { workVars[i].value = v } else { workVars.append((k, v)) }
                ch.append(VarChange(key: k, value: v, secret: sec, remove: false))
            }
            for k in (j["unset"]?.list ?? []).compactMap({ $0.text }) {
                workVars.removeAll { $0.key == k }; secretValues[k] = nil
                ch.append(VarChange(key: k, value: "", secret: false, remove: true))
            }
            redactor = Redactor(secrets: secretValues)       // a changed secret must be masked from now on
            writeWorkGlobals()
            if !ch.isEmpty { varsSink?(ch) }
        case "itemDone":                  // tests finished → the execution is complete, write it to the history
            if let i = execIndex["\(iterNo)|\(j["id"]?.text ?? "")"], pendingHistory.remove(i) != nil { historySink?(results[i]) }
        default: break
        }
    }


    // MARK: Data files (CSV / JSON)
    nonisolated static func loadRows(_ url: URL) -> [[String: String]] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        if url.pathExtension.lowercased() == "json" {
            return (JSON.parse(d)?.list ?? []).map { $0.dict.mapValues { $0.text ?? "" } }
        }
        let table = csv(String(decoding: d, as: UTF8.self))
        guard let head = table.first else { return [] }
        return table.dropFirst().filter { $0.count > 1 || $0.first?.isEmpty == false }
            .map { row in Dictionary(uniqueKeysWithValues: head.enumerated().map { ($1, $0 < row.count ? row[$0] : "") }) }
    }
    /// Rewrites `{{name}}` in every string of the collection (scripts excluded) to the existing variable that has the same name ignoring case.
    /// A name that exists exactly as written is never touched. Returns the new collection and the list of "wrong → right" pairs.
    nonisolated static func canonicalizeVars(_ j: JSON, names: [String]) -> (JSON, Set<String>) {
        let exact = Set(names)
        var ci: [String: String] = [:]
        for n in names where ci[n.lowercased()] == nil { ci[n.lowercased()] = n }
        guard let re = try? NSRegularExpression(pattern: "\\{\\{\\s*([^{}\\s$][^{}\\n]*?)\\s*\\}\\}") else { return (j, []) }
        var fixed = Set<String>()
        func fix(_ s: String) -> String {
            guard s.contains("{{") else { return s }
            let ns = s as NSString
            var out = "", last = 0
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range(at: 1))
                guard !exact.contains(name), let right = ci[name.lowercased()], right != name else { continue }
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + "{{" + right + "}}"
                last = NSMaxRange(m.range); fixed.insert("\(name) → \(right)")
            }
            return last == 0 ? s : out + ns.substring(from: last)
        }
        func walk(_ v: JSON, _ key: String) -> JSON {
            switch v {
            case .str(let t): return key == "exec" ? v : .str(fix(t))
            case .arr(let a): return .arr(a.map { walk($0, key) })
            case .obj(let o): return .obj(o.reduce(into: [:]) { $0[$1.key] = ($1.key == "event") ? $1.value : walk($1.value, $1.key) })
            default: return v
            }
        }
        return (walk(j, ""), fixed)
    }
    /// Column names of a data file in file order (CSV header; JSON: sorted union of keys).
    nonisolated static func loadColumns(_ url: URL) -> [String] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        if url.pathExtension.lowercased() == "json" {
            return Array(Set((JSON.parse(d)?.list ?? []).flatMap { $0.dict.keys })).sorted()
        }
        return csv(String(decoding: d, as: UTF8.self)).first ?? []
    }
    nonisolated static func csv(_ s: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], f = "", quoted = false
        let ch = Array(s.replacingOccurrences(of: "\r\n", with: "\n")); var i = 0
        let sep: Character = (s.prefix(while: { $0 != "\n" }).contains(";") && !s.prefix(while: { $0 != "\n" }).contains(",")) ? ";" : ","
        while i < ch.count {
            let c = ch[i]
            if quoted { if c == "\"" { if i + 1 < ch.count, ch[i + 1] == "\"" { f.append("\""); i += 1 } else { quoted = false } } else { f.append(c) } }
            else if c == "\"" { quoted = true }
            else if c == sep { row.append(f); f = "" }
            else if c == "\n" { row.append(f); rows.append(row); row = []; f = "" }
            else { f.append(c) }
            i += 1
        }
        if !f.isEmpty || !row.isEmpty { row.append(f); rows.append(row) }
        return rows
    }
}

extension Runner {
    /// Files of form-data / binary bodies are copied into `dir` and the collection points at the copies, so newman always reads files the app can open.
    static func stageFiles(_ j: JSON, into dir: URL, count: inout Int, key: String = "") -> JSON {
        switch j {
        case .arr(let a): return .arr(a.map { stageFiles($0, into: dir, count: &count, key: key) })
        case .obj(var o):
            if let src = o["src"]?.text, !src.isEmpty, o["type"]?.text == "file" || key == "file" {
                let fm = FileManager.default
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                count += 1
                let dest = dir.appendingPathComponent("\(count)-" + (src as NSString).lastPathComponent)
                if (try? fm.copyItem(at: URL(fileURLWithPath: src), to: dest)) != nil { o["src"] = .str(dest.path) }
            }
            for (k, v) in o where k != "src" { o[k] = stageFiles(v, into: dir, count: &count, key: k) }
            return .obj(o)
        default: return j
        }
    }
}


// MARK: Errors → CSV
extension ExecResult {
    /// A failed assertion / script error / network error (no response) / HTTP 4xx-5xx.
    var isError: Bool { !failures.isEmpty || code == 0 || code >= 400 }
}
extension Runner {
    /// Data rows of the executions that ended with an error, without duplicates (same values in every column), in run order.
    func errorRows() -> (columns: [String], rows: [[String]]) {
        let failed = results.filter { $0.isError && !$0.dataRow.isEmpty }
        var cols = dataColumns
        for k in Set(failed.flatMap { $0.dataRow.keys }).subtracting(cols).sorted() { cols.append(k) }
        var seen = Set<[String]>(), rows: [[String]] = []
        for r in failed {
            let row = cols.map { r.dataRow[$0] ?? "" }
            if seen.insert(row).inserted { rows.append(row) }
        }
        return (cols, rows)
    }
    var hasErrorRows: Bool { results.contains { $0.isError && !$0.dataRow.isEmpty } }

    func errorsCSV() -> String {
        func q(_ f: String) -> String {
            f.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) || f.hasPrefix(" ") || f.hasSuffix(" ")
                ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f
        }
        let (cols, rows) = errorRows()
        return ([cols] + rows).map { $0.map(q).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }
    @MainActor func saveErrorsCSV() {
        let (_, rows) = errorRows()
        let p = NSSavePanel(); p.allowedContentTypes = [.commaSeparatedText]; p.nameFieldStringValue = (dataFileName.isEmpty ? "" : dataFileName + "_") + "errors.csv"
        p.message = L("Data rows of failed requests, without duplicates")
        guard p.runModal() == .OK, let u = p.url else { return }
        do {
            try errorsCSV().data(using: .utf8)?.write(to: u)
            note("Errors CSV saved: \(rows.count) unique row(s) → \(u.lastPathComponent)", .info, "runner")
        } catch { note("Errors CSV not saved: \(error.localizedDescription)", .error, "runner") }
    }
}

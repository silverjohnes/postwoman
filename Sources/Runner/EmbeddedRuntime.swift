import Foundation

struct ProbeResult {
    var status: Int32 = -1
    var output = ""
    var timedOut = false
    var launchError: String?
    var elapsedMs = 0
}

/// Thread-safe state of one probe run.
private final class ProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var eof = false
    private var done = false
    let started = Date()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    func markEOF() { lock.lock(); eof = true; lock.unlock() }
    var sawEOF: Bool { lock.lock(); defer { lock.unlock() }; return eof }
    var bytes: Int { lock.lock(); defer { lock.unlock() }; return data.count }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }
    /// true only for the first caller: the result is delivered exactly once
    func finish() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    var elapsedMs: Int { Int(Date().timeIntervalSince(started) * 1000) }
}

/// The Node.js binary and the Newman package that ship INSIDE the app bundle:
///   Postwoman.app/Contents/Helpers/node                         (signed helper, inherits the app sandbox)
///   Postwoman.app/Contents/Resources/newman/node_modules/newman (JavaScript only)
/// Nothing is looked up through PATH, the shell profile or an external installation.
enum EmbeddedRuntime {
    nonisolated static var nodeURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/node") }
    nonisolated static var newmanDir: URL {
        (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("newman/node_modules/newman")
    }

    /// nil when everything is in place, otherwise a human-readable reason.
    nonisolated static func problem() -> String? {
        let fm = FileManager.default
        if !fm.isExecutableFile(atPath: nodeURL.path) {
            return L("Embedded node is missing or not executable: %@. Rebuild the app (scripts/embed-runtime.sh puts it there).", nodeURL.path)
        }
        if !fm.fileExists(atPath: newmanDir.appendingPathComponent("package.json").path) {
            return L("Embedded newman is missing: %@. Rebuild the app (scripts/embed-runtime.sh puts it there).", newmanDir.path)
        }
        return nil
    }

    /// Minimal, fixed environment: the result never depends on the user's shell or on what launched the app.
    nonisolated static func environment() -> [String: String] {
        [
            "PATH": "/usr/bin:/bin",
            "HOME": NSHomeDirectory(),            // inside the sandbox container
            "TMPDIR": NSTemporaryDirectory(),
            "NO_COLOR": "1",
            "LANG": "en_US.UTF-8",
            "NODE_OPTIONS": "--use-system-ca",    // trust certificates from the macOS keychain (corporate / local CAs)
        ]
    }

    /// Reads whatever is already in the pipe WITHOUT waiting for EOF
    /// (readDataToEndOfFile() would wait for every process holding the pipe open).
    nonisolated static func drain(_ h: FileHandle) -> Data {
        let fd = h.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        let cap = buf.count
        while true {
            let n = read(fd, &buf, cap)
            if n > 0 { out.append(contentsOf: buf[0..<n]) } else { break }          // 0 = EOF, -1 = nothing more right now
        }
        return out
    }

    /// Runs the embedded node with `arguments`. Never blocks the UI and never waits forever;
    /// every stage is reported through `log` (used by Settings → Test).
    nonisolated static func run(arguments: [String], timeout: TimeInterval = 20,
                                log: @escaping @Sendable (LogLevel, String) -> Void) async -> ProbeResult {
        await withCheckedContinuation { (cont: CheckedContinuation<ProbeResult, Never>) in
            let st = ProbeState()
            let finish: @Sendable (ProbeResult) -> Void = { r in
                guard st.finish() else { return }
                var r = r; r.output = st.text; r.elapsedMs = st.elapsedMs
                cont.resume(returning: r)
            }
            if let why = problem() { log(.error, why); finish(ProbeResult(status: -1, launchError: why)); return }
            let p = Process()
            p.executableURL = nodeURL
            p.arguments = arguments
            p.standardInput = FileHandle.nullDevice
            let env = environment(); p.environment = env
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            let rd = pipe.fileHandleForReading

            log(.info, "starting \(nodeURL.path), timeout \(Int(timeout)) s")
            log(.debug, "arguments: \(arguments.joined(separator: " "))")
            log(.debug, "environment: " + env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))

            rd.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { st.markEOF(); h.readabilityHandler = nil; return }       // EOF: stop, otherwise the source keeps firing
                st.append(d)
            }
            p.terminationHandler = { pr in
                let signalled = pr.terminationReason != .exit
                let how = signalled ? "killed by signal \(pr.terminationStatus)" : "exit status \(pr.terminationStatus)"
                log(.debug, "node exited: \(how) after \(st.elapsedMs) ms; \(st.bytes) byte(s) of output")
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                    rd.readabilityHandler = nil
                    st.append(EmbeddedRuntime.drain(rd))
                    finish(ProbeResult(status: signalled ? 128 + pr.terminationStatus : pr.terminationStatus))
                }
            }
            do { try p.run() } catch {
                log(.error, "cannot start node: \(error.localizedDescription)")
                finish(ProbeResult(status: -1, launchError: error.localizedDescription)); return
            }
            let pid = p.processIdentifier
            log(.debug, "started, pid \(pid)")

            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + 3, repeating: 3)
            timer.setEventHandler {
                if st.isDone { timer.cancel(); return }
                log(.debug, "still running after \(st.elapsedMs / 1000) s; \(st.bytes) byte(s) of output")
            }
            timer.resume()

            // hard timeout: kill and return — the UI is never left waiting
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard !st.isDone else { return }
                let out = st.text.trimmingCharacters(in: .whitespacesAndNewlines)
                log(.error, "no result after \(Int(timeout)) s. Output so far (\(st.bytes) bytes): \(out.isEmpty ? "(none)" : out)")
                kill(pid, SIGCONT)
                p.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if p.isRunning { log(.warn, "SIGTERM ignored, sending SIGKILL"); kill(pid, SIGKILL) }
                }
                finish(ProbeResult(status: -1, timedOut: true))
            }
        }
    }
}

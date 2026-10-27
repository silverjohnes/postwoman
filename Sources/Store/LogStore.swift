import Foundation
import Combine

enum LogLevel: Int, Comparable { case debug, info, warn, error
    static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
    var label: String { ["DEBUG", "INFO", "WARN", "ERROR"][rawValue] }
}
struct LogEntry: Identifiable {
    let id = UUID(); let date = Date(); let level: LogLevel; let cat: String; let msg: String
    static let fmt: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm:ss.SSS"; return f }()
    var line: String { "\(Self.fmt.string(from: date)) [\(level.label)] \(cat): \(msg)" }
}
/// Separate object so log traffic does not re-render the whole UI.
@MainActor final class LogStore: ObservableObject {
    @Published var entries: [LogEntry] = []
    func add(_ e: LogEntry) { entries.append(e); if entries.count > 20000 { entries.removeFirst(2000) } }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: Log tab
struct LogTabView: View {
    @ObservedObject var logs: LogStore
    @State private var minLevel = 0
    @State private var filter = ""
    var shown: [LogEntry] {
        let f = filter.lowercased()
        return logs.entries.filter { $0.level.rawValue >= minLevel && (f.isEmpty || $0.line.lowercased().contains(f)) }
    }
    var body: some View {
        let items = shown
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Level", selection: $minLevel) { Text("Debug+").tag(0); Text("Info+").tag(1); Text("Warnings+").tag(2); Text("Errors").tag(3) }.frame(width: 180)
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                Text("\(items.count) / \(logs.entries.count)").foregroundStyle(.secondary).font(.caption.monospacedDigit())
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(items.map(\.line).joined(separator: "\n"), forType: .string) }
                Button("Save…") {
                    let p = NSSavePanel(); p.nameFieldStringValue = "postwoman.log"
                    if p.runModal() == .OK, let u = p.url { try? items.map(\.line).joined(separator: "\n").write(to: u, atomically: true, encoding: .utf8) }
                }
                Button("Clear") { logs.entries = [] }
            }
            // follows new lines while scrolled to the bottom; stays put once you scroll up (see PinnedScroll.swift)
            SelectableLog(items: items).background(Color.secondary.opacity(0.08))
        }.padding()
    }
}

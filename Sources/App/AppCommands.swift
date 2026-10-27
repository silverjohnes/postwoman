import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: Keyboard shortcuts (Postman-style)
struct AppCommands: Commands {
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Request") { store.add(folder: false) }.keyboardShortcut("n")
            Button("New Folder") { store.add(folder: true) }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Import Collection…") { store.importCollections() }.keyboardShortcut("o")
            Button("Import cURL…") { store.showCurlImport = true }.keyboardShortcut("i", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { store.saveSelected() }.keyboardShortcut("s")
            Button("Save All") { store.saveAll() }.keyboardShortcut("s", modifiers: [.command, .option])
            Button("Export Collection…") { store.exportSelected() }.keyboardShortcut("e", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { Self.undoRedo(redo: false, store: store) }.keyboardShortcut("z")
            Button("Redo") { Self.undoRedo(redo: true, store: store) }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(after: .windowArrangement) {
            Divider()
            Button("Keyboard Shortcuts") { openWindow(id: "shortcuts") }
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Rename") { store.rename() }.keyboardShortcut("e").disabled(store.primary == nil)
            Button("Duplicate") { store.duplicate() }.keyboardShortcut("d").disabled(store.primary == nil)
            Button("Delete Selected Items") { store.deleteSelected() }.keyboardShortcut(.delete, modifiers: .command)
        }
        CommandGroup(after: .textEditing) {
            Button("Find") { if store.findPanes > 0 { store.focusFind += 1 } else { store.focusSearch += 1 } }.keyboardShortcut("f")
            Button("Search Collections") { store.focusSearch += 1 }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Next Match") { store.jump(1) }.keyboardShortcut("g").disabled(store.matches.isEmpty)
            Button("Previous Match") { store.jump(-1) }.keyboardShortcut("g", modifiers: [.command, .shift]).disabled(store.matches.isEmpty)
        }
        CommandGroup(after: .toolbar) {
            Button("Request") { store.tab = .request }.keyboardShortcut("1")
            Button("Runner") { store.tab = .runner }.keyboardShortcut("2")
            Button("Globals") { store.tab = .globals }.keyboardShortcut("3")
            Button("Log") { store.tab = .log }.keyboardShortcut("4")
        }
        CommandMenu("Run") {
            Button("Send Request") { store.run() }.keyboardShortcut(.return, modifiers: .command)
                .disabled(store.primary == nil || store.runner.state != .idle || store.tab != .request)
            Button("Run Selected") { store.run() }.keyboardShortcut("r").disabled(store.primary == nil || store.runner.state != .idle)
            Button(store.runner.state == .paused ? L("Resume") : L("Pause")) {
                if store.runner.state == .paused { store.runner.resume() } else { store.runner.pause() }
            }.keyboardShortcut("p", modifiers: [.command, .option]).disabled(store.runner.state == .idle)
            Button("Stop") { store.runner.stop() }.keyboardShortcut(".").disabled(store.runner.state == .idle)
        }
    }

    /// A focused text field / editor undoes its own typing first; otherwise the whole request tree and Globals are rolled back.
    @MainActor static func undoRedo(redo: Bool, store: Store) {
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, let um = tv.undoManager, redo ? um.canRedo : um.canUndo {
            if redo { um.redo() } else { um.undo() }
            return
        }
        if redo { store.redo() } else { store.undo() }
    }
}

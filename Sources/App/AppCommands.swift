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
            Button("Close Request") { if !store.closeRequest() { NSApp.keyWindow?.performClose(nil) } }.keyboardShortcut("w")
            Button("Save All") { store.saveAll() }.keyboardShortcut("s", modifiers: [.command, .option])
            Button("Export Collection…") { store.exportSelected() }.keyboardShortcut("e", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { Self.undoRedo(redo: false, store: store) }.keyboardShortcut("z")
            Button("Redo") { Self.undoRedo(redo: true, store: store) }.keyboardShortcut("z", modifiers: [.command, .shift])
            Divider()
            Button("Undo for the whole app") { Self.wholeAppUndo(redo: false, store: store) }.keyboardShortcut("z", modifiers: [.command, .option])
            Button("Redo for the whole app") { Self.wholeAppUndo(redo: true, store: store) }.keyboardShortcut("z", modifiers: [.command, .option, .shift])
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

    /// ⌘Z / ⇧⌘Z: a focused text field / editor undoes its own typing first; then the part of the window that has the focus is rolled back on its own:
    /// the request list (structure: create, delete, move, rename) or the open request. Other tabs and folders use the whole-app history.
    @MainActor static func undoRedo(redo: Bool, store: Store) {
        let verb = redo ? "Redo" : "Undo"
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, let um = tv.undoManager, redo ? um.canRedo : um.canUndo {
            store.log("undo", "\(verb) (⌘Z): typing in the focused text field / editor", .info)
            if redo { um.redo() } else { um.undo() }
            return
        }
        switch store.focusedPane() {
        case .sidebar:
            store.log("undo", "\(verb) (⌘Z): focus is in the request list", .debug)
            store.undoStructure(redo: redo)
        case .editor:
            if store.tab == .request, let p = store.primary, p.children == nil {
                store.log("undo", "\(verb) (⌘Z): focus is in the request editor", .debug)
                store.undoRequest(redo: redo)
            } else {
                store.log("undo", "\(verb) (⌘Z): focus is in \(store.tab == .request ? "the folder editor" : "the \(store.tab.rawValue) tab") — whole-app history", .debug)
                if redo { store.redo() } else { store.undo() }
            }
        }
    }
    /// ⌥⌘Z / ⇧⌥⌘Z: the old behaviour, one history for the whole app (all requests, the tree and Globals).
    @MainActor static func wholeAppUndo(redo: Bool, store: Store) {
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, let um = tv.undoManager, redo ? um.canRedo : um.canUndo {
            store.log("undo", "\(redo ? "Redo" : "Undo") (⌥⌘Z): typing in the focused text field / editor", .info)
            if redo { um.redo() } else { um.undo() }
            return
        }
        store.log("undo", "\(redo ? "Redo" : "Undo") (⌥⌘Z): whole-app history", .debug)
        if redo { store.redo() } else { store.undo() }
    }
}

import SwiftUI
import AppKit

@main
struct PostwomanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store()
    init() { _ = AppLanguage.launchCode }

    var body: some Scene {
        WindowGroup("Postwoman") { ContentView().environmentObject(store).frame(minWidth: 1000, minHeight: 640) }
            .commands { AppCommands(store: store) }
        Window("Keyboard Shortcuts", id: "shortcuts") { ShortcutsView() }.windowResizability(.contentSize)
        Settings { SettingsView().environmentObject(store) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Autosave is hooked to willTerminate inside Store; here we only make sure no newman process outlives the app.
    func applicationWillTerminate(_ notification: Notification) { Runner.killChild() }
    /// Unsaved requests are offered for saving before the app quits (see Store+Saving.swift).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        (Store.current?.confirmQuit() ?? true) ? .terminateNow : .terminateCancel
    }
}
